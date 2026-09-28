-- ============================================================================
-- Migration 20260929071000 — Exos (Bridge / D4): transactional + follow-up
--                            mail templates for buyers and organizers
--
-- Lane:     d4 (exos / bridge ticketing infra)
-- Touches:  W: exos_mail (+payload; +attempts/claimed_at/last_attempt_at IF NOT
--              EXISTS, prod has them since 20260523130000; template allowlist
--              + 13 values), exos_orgs (+post_event_emails_enabled)
--           C: TABLE exos_mail_dedupe (once-only ledger)
--              FUNCTION exos_mail_enqueue, exos_org_mail_recipients,
--                _exos_mail_event_json, _exos_org_payments_ready,
--                _exos_is_following, _exos_notify_event_holders,
--                exos_send_mail_followups (cron entry, service_role),
--                exos_queue_payout_mail (service_role),
--                exos_tg_refund_issued_mail, exos_tg_event_published_mail,
--                exos_tg_event_cancelled_mail (triggers)
--           R: FUNCTION exos_mail_claim_batch (4th arg p_render_payload,
--                returns template + payload; the 3-arg form is dropped),
--              exos_notify_event_holders(uuid, text) (same signature, now
--                payload-rendered with refund status; recipients fixed),
--              exos_queue_event_reminder(uuid, uuid) (tickets link; parked
--                tickets no longer mail the org owner),
--              exos_receipt_html(text) (line items, all-in note, tickets link)
--           R: exos_events, exos_orgs, exos_org_memberships, exos_tickets,
--              exos_transfers, exos_checkout_sessions, exos_order_refunds,
--              exos_refund_requests, exos_price_disclosure_lines,
--              exos_ticket_tiers, exos_event_checkins, exos_org_billing,
--              exos_mail_prefs, auth.users; exos_org_secrets and
--              exos_org_follows when present (dynamic SQL)
-- Pre-reqs: 20260926060000 (exos_mail_prefs, list_unsubscribe, allowlist
--           union pattern), 20260926070000 (price disclosure lines),
--           20260927010000 (exos_mail_escape), 20260929030000 (receipt html),
--           20260929051000 (last allowlist change), 20260929062000
--           (exos_org_billing.fee_free_until, exos_platform_fee_bps)
--
-- Until now every mail body was rendered in SQL when it was queued. New
-- templates here carry a small JSON payload instead (exos_mail.payload, html
-- ''), and exos-mail-drain renders subject + html from it with the pure TS
-- renderers in supabase/functions/_shared/mail-templates.ts, where escaping
-- and links are unit-tested. The legacy SQL-rendered rows are untouched.
--
-- Deploy order is safe either way: exos_mail_claim_batch only hands out
-- payload rows to a caller passing p_render_payload => true (the new drain).
-- An old drain keeps sending html rows; payload rows wait for the new one.
--
-- Templates (docs/email.md has the full table):
--   buyer:     event-cancelled (+refund status), event-updated, refund-issued,
--              post-event (marketing); extended in place: order receipt
--              (exos_receipt_html), event-reminder (tickets link)
--   organizer: event-published, inventory-low, inventory-sold-out,
--              payout-sent, payout-pending, fee-free-ending, org-welcome;
--              org-sales-digest, org-weekly-summary, org-first-event,
--              org-connect-stripe (marketing)
--
-- Idempotency: exos_mail_enqueue claims a dedupe key in exos_mail_dedupe
-- (PK, ON CONFLICT DO NOTHING) before queueing, so a re-run, a retried
-- trigger or an overlapping cron never queues the same mail twice. Keys
-- carry ids only (no email addresses), and the ledger outlives exos_mail
-- purges. Marketing mails need an account (the opt-out lives on it), skip
-- opted-out users (exos_mail_prefs.marketing_opt_out) and carry the
-- unsubscribe link + List-Unsubscribe header. Transactional mails always send.
--
-- Organizer mails hold counts, amounts and event facts only: no buyer names
-- or emails. Organizer-written text (event names, cancel reasons) is stored
-- raw in the payload and escaped by the renderer.
--
-- Cron: this migration schedules NOTHING. The operator adds the line in
-- docs/email.md (exos_send_mail_followups, hourly). Until then only the
-- trigger-driven mails (refund, publish, cancel) and the RPCs queue anything.
--
-- Re-run safe (IF NOT EXISTS / CREATE OR REPLACE / allowlist union).
-- D4 authors; applying to prod is operator-gated.
-- ROLLBACK: DROP TRIGGER exos_order_refunds_mail ON exos_order_refunds,
--   exos_events_published_mail, exos_events_cancelled_mail ON exos_events;
--   DROP FUNCTION exos_send_mail_followups(int), exos_queue_payout_mail(uuid,
--   bigint,text,text,text,text), exos_mail_enqueue(text,text,jsonb,text,uuid,
--   boolean,uuid) and the helpers; re-create exos_mail_claim_batch(int,int,int)
--   from 20260523130000; re-apply 20260523220000, 20260911070000 and
--   20260929030000 for the three replaced functions; DROP TABLE
--   exos_mail_dedupe; ALTER TABLE exos_mail DROP COLUMN payload; ALTER TABLE
--   exos_orgs DROP COLUMN post_event_emails_enabled.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. exos_mail: payload + drainer bookkeeping.
-- ---------------------------------------------------------------------------
ALTER TABLE public.exos_mail ADD COLUMN IF NOT EXISTS attempts        int NOT NULL DEFAULT 0;
ALTER TABLE public.exos_mail ADD COLUMN IF NOT EXISTS claimed_at      timestamptz;
ALTER TABLE public.exos_mail ADD COLUMN IF NOT EXISTS last_attempt_at timestamptz;
ALTER TABLE public.exos_mail ADD COLUMN IF NOT EXISTS payload jsonb;
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint
                  WHERE conrelid = 'public.exos_mail'::regclass AND conname = 'exos_mail_payload_chk') THEN
    ALTER TABLE public.exos_mail ADD CONSTRAINT exos_mail_payload_chk
      CHECK (payload IS NULL OR (jsonb_typeof(payload) = 'object' AND octet_length(payload::text) <= 20000));
  END IF;
END $$;
COMMENT ON COLUMN public.exos_mail.payload IS
  'Template data (mig 20260929071000). When set, exos-mail-drain renders subject + html from it (_shared/mail-templates.ts); html is empty.';

-- ---------------------------------------------------------------------------
-- 2. Once-only ledger.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.exos_mail_dedupe (
  dedupe_key text PRIMARY KEY CHECK (char_length(dedupe_key) BETWEEN 1 AND 300),
  template   text NOT NULL,
  mail_id    uuid,
  created_at timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE public.exos_mail_dedupe IS
  'Mails already queued, by dedupe key (template:thing:recipient-id). The PK is the never-twice gate for follow-ups (mig 20260929071000).';
ALTER TABLE public.exos_mail_dedupe ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.exos_mail_dedupe FROM PUBLIC, anon, authenticated;
GRANT ALL ON public.exos_mail_dedupe TO service_role;
DO $$
DECLARE r text;
BEGIN
  FOREACH r IN ARRAY ARRAY['coworker_readonly','analyst_ro'] LOOP
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = r) THEN
      EXECUTE format('REVOKE ALL ON public.exos_mail_dedupe FROM %I', r);
    END IF;
  END LOOP;
END $$;

-- ---------------------------------------------------------------------------
-- 3. Template allowlist: live list ∪ last known list ∪ the new values.
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_def  text;
  v_live text[];
  v_new  text[] := ARRAY['event-published','inventory-low','inventory-sold-out','payout-sent',
                         'payout-pending','fee-free-ending','org-welcome','org-first-event',
                         'org-connect-stripe','org-sales-digest','org-weekly-summary',
                         'refund-issued','post-event'];
  v_vals text[];
BEGIN
  SELECT pg_get_constraintdef(c.oid) INTO v_def
    FROM pg_constraint c
   WHERE c.conrelid = 'public.exos_mail'::regclass AND c.conname = 'exos_mail_template_check';
  IF strpos(coalesce(v_def, ''), '''{') > 0 THEN
    v_live := string_to_array(substring(v_def FROM '''\{([^}]*)\}'''), ',');
  ELSE
    SELECT array_agg(m[1]) INTO v_live
      FROM regexp_matches(coalesce(v_def, ''), '''([^'']+)''', 'g') AS m;
  END IF;
  IF v_new <@ coalesce(v_live, '{}'::text[]) THEN
    RETURN;  -- already allowed; leave the live list alone
  END IF;
  SELECT array_agg(DISTINCT x ORDER BY x) INTO v_vals FROM (
    SELECT btrim(unnest(coalesce(v_live, '{}'::text[])), ' "') AS x
    UNION
    SELECT unnest(ARRAY[
      'transfer-initiated','transfer-claimed','org-invite','event-cancelled','event-updated',
      'event-announce','ticket-issued','waitlist-open','event-announcement','event-rescheduled',
      'event-reminder','order-failed','checkout-abandoned','marketplace-attention'] || v_new)
  ) u WHERE x <> '';
  ALTER TABLE public.exos_mail DROP CONSTRAINT IF EXISTS exos_mail_template_check;
  EXECUTE format('ALTER TABLE public.exos_mail ADD CONSTRAINT exos_mail_template_check '
                 'CHECK (template = ANY (ARRAY[%s]))',
                 (SELECT string_agg(quote_literal(x), ',' ORDER BY x) FROM unnest(v_vals) x));
END $$;

-- ---------------------------------------------------------------------------
-- 4. Org toggle for the after-show mail (owner-writable via exos_orgs RLS).
-- ---------------------------------------------------------------------------
ALTER TABLE public.exos_orgs
  ADD COLUMN IF NOT EXISTS post_event_emails_enabled boolean NOT NULL DEFAULT true;
COMMENT ON COLUMN public.exos_orgs.post_event_emails_enabled IS
  'Send attendees one "thanks + follow + next events" mail after each event (exos_send_mail_followups). Default on.';

-- ---------------------------------------------------------------------------
-- 5. Queue one payload mail. Returns the mail id, or NULL when it was not
--    queued (bad address, opted out, no account for a marketing mail, or the
--    dedupe key was already used). Internal: callers are SECURITY DEFINER.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.exos_mail_enqueue(
  p_template   text,
  p_to_email   text,
  p_payload    jsonb,
  p_dedupe_key text    DEFAULT NULL,
  p_user_id    uuid    DEFAULT NULL,
  p_marketing  boolean DEFAULT false,
  p_created_by uuid    DEFAULT NULL
) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_to      text := lower(btrim(coalesce(p_to_email, '')));
  v_payload jsonb := CASE WHEN jsonb_typeof(p_payload) = 'object' THEN p_payload ELSE '{}'::jsonb END;
  v_token   text;
  v_unsub   text;
  v_key     text := nullif(btrim(coalesce(p_dedupe_key, '')), '');
  v_id      uuid;
BEGIN
  IF v_to !~ '^[^@[:space:]]+@[^@[:space:]]+$' OR char_length(v_to) > 320 THEN
    RETURN NULL;
  END IF;
  IF coalesce(p_marketing, false) THEN
    -- The opt-out lives on the account; without one there's no way to stop it.
    IF p_user_id IS NULL THEN RETURN NULL; END IF;
    IF EXISTS (SELECT 1 FROM public.exos_mail_prefs WHERE user_id = p_user_id AND marketing_opt_out) THEN
      RETURN NULL;
    END IF;
  END IF;
  IF v_key IS NOT NULL THEN
    INSERT INTO public.exos_mail_dedupe (dedupe_key, template) VALUES (left(v_key, 300), p_template)
    ON CONFLICT DO NOTHING;
    IF NOT FOUND THEN RETURN NULL; END IF;
  END IF;
  IF coalesce(p_marketing, false) THEN
    INSERT INTO public.exos_mail_prefs (user_id) VALUES (p_user_id) ON CONFLICT (user_id) DO NOTHING;
    SELECT unsubscribe_token INTO v_token FROM public.exos_mail_prefs WHERE user_id = p_user_id;
    v_unsub   := '{{app_url}}/unsubscribe?t=' || v_token;
    v_payload := v_payload || jsonb_build_object('unsubscribe_token', v_token);
  END IF;
  v_payload := v_payload || jsonb_build_object('marketing', coalesce(p_marketing, false));

  INSERT INTO public.exos_mail (template, to_email, subject, html, created_by, status, list_unsubscribe, payload)
  VALUES (p_template, v_to, left('[' || p_template || ']', 200), '', p_created_by, 'pending', v_unsub, v_payload)
  RETURNING id INTO v_id;
  IF v_key IS NOT NULL THEN
    UPDATE public.exos_mail_dedupe SET mail_id = v_id WHERE dedupe_key = left(v_key, 300);
  END IF;
  RETURN v_id;
END $$;
REVOKE ALL ON FUNCTION public.exos_mail_enqueue(text, text, jsonb, text, uuid, boolean, uuid) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.exos_mail_enqueue(text, text, jsonb, text, uuid, boolean, uuid) TO service_role;

-- ---------------------------------------------------------------------------
-- 6. Helpers.
-- ---------------------------------------------------------------------------
-- Org staff to mail: the owner plus active members in p_roles, one row per address.
CREATE OR REPLACE FUNCTION public.exos_org_mail_recipients(p_org_id uuid, p_roles text[])
RETURNS TABLE (user_id uuid, email text)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT DISTINCT ON (lower(u.email)) u.id, lower(u.email)
    FROM auth.users u
   WHERE coalesce(u.email, '') <> ''
     AND (u.id = (SELECT o.owner_uid FROM public.exos_orgs o WHERE o.id = p_org_id)
          OR u.id IN (SELECT m.user_id FROM public.exos_org_memberships m
                       WHERE m.org_id = p_org_id AND m.role = ANY (p_roles) AND m.disabled IS NOT TRUE))
   ORDER BY lower(u.email), u.id
$$;
REVOKE ALL ON FUNCTION public.exos_org_mail_recipients(uuid, text[]) FROM PUBLIC, anon, authenticated;

-- The event facts every template shows. Raw text: the renderer escapes.
CREATE OR REPLACE FUNCTION public._exos_mail_event_json(p_event_id uuid)
RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT jsonb_build_object(
           'id', e.id, 'name', e.name, 'starts_at', e.starts_at, 'doors_at', e.doors_at,
           'ends_at', e.ends_at, 'timezone', e.timezone, 'venue_name', e.venue_name,
           'venue_location', e.venue_location, 'org_id', e.org_id, 'org_name', o.name)
    FROM public.exos_events e
    LEFT JOIN public.exos_orgs o ON o.id = e.org_id
   WHERE e.id = p_event_id
$$;
REVOKE ALL ON FUNCTION public._exos_mail_event_json(uuid) FROM PUBLIC, anon, authenticated;

-- Stripe Connect can take payments (exos_org_secrets.payments, written by
-- exos_record_org_stripe). Dynamic: a scratch database may not have the table.
CREATE OR REPLACE FUNCTION public._exos_org_payments_ready(p_org_id uuid)
RETURNS boolean
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE v boolean;
BEGIN
  IF to_regclass('public.exos_org_secrets') IS NULL THEN RETURN false; END IF;
  EXECUTE 'SELECT (payments->>''chargesEnabled'') = ''true'' FROM public.exos_org_secrets WHERE org_id = $1'
     INTO v USING p_org_id;
  RETURN coalesce(v, false);
END $$;
REVOKE ALL ON FUNCTION public._exos_org_payments_ready(uuid) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public._exos_is_following(p_user_id uuid, p_org_id uuid)
RETURNS boolean
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE v boolean;
BEGIN
  IF to_regclass('public.exos_org_follows') IS NULL THEN RETURN false; END IF;
  EXECUTE 'SELECT EXISTS (SELECT 1 FROM public.exos_org_follows WHERE follower_uid = $1 AND org_id = $2)'
     INTO v USING p_user_id, p_org_id;
  RETURN coalesce(v, false);
END $$;
REVOKE ALL ON FUNCTION public._exos_is_following(uuid, uuid) FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 7. Drainer claim: payload rows only for a drain that renders them.
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.exos_mail_claim_batch(int, int, int);
CREATE OR REPLACE FUNCTION public.exos_mail_claim_batch(
  p_limit          int     DEFAULT 20,
  p_max_attempts   int     DEFAULT 5,
  p_stuck_minutes  int     DEFAULT 10,
  p_render_payload boolean DEFAULT false
) RETURNS TABLE (id uuid, to_email text, subject text, html text, attempts int, template text, payload jsonb)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp
AS $$
BEGIN
  RETURN QUERY
  WITH claimable AS (
    SELECT m.id
    FROM public.exos_mail m
    WHERE (
            m.status = 'pending'
            OR (m.status = 'sending'
                AND m.claimed_at < now() - make_interval(mins => p_stuck_minutes))
          )
      AND m.attempts < p_max_attempts
      AND (p_render_payload OR m.payload IS NULL)
    ORDER BY m.created_at
    LIMIT GREATEST(p_limit, 1)
    FOR UPDATE SKIP LOCKED
  )
  UPDATE public.exos_mail m
     SET status          = 'sending',
         attempts        = m.attempts + 1,
         claimed_at      = now(),
         last_attempt_at = now()
    FROM claimable c
   WHERE m.id = c.id
  RETURNING m.id, m.to_email, m.subject, m.html, m.attempts, m.template, m.payload;
END $$;
REVOKE ALL ON FUNCTION public.exos_mail_claim_batch(int, int, int, boolean) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.exos_mail_claim_batch(int, int, int, boolean) TO service_role;

-- ---------------------------------------------------------------------------
-- 8. Buyer: event cancelled / updated.
--
-- Recipients: every current holder, except that a ticket parked on the org
-- owner for a pending claim (guest checkout, comps, marketplace orders) is
-- mailed to the person it's waiting for, not to the owner. A cancellation
-- also reaches holders whose tickets were already voided by a refund.
--
-- Cancellation carries each recipient's refund status, over the orders they
-- paid for: none (free / comp), not_buyer (someone else paid), refunded,
-- partial, processing (a refund is in flight) or pending (not started yet;
-- refund-issued follows when it is). Once per event per address.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._exos_notify_event_holders(
  p_event_id uuid,
  p_template text,
  p_actor    uuid DEFAULT NULL
) RETURNS int
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_ev     jsonb := public._exos_mail_event_json(p_event_id);
  v_owner  uuid;
  v_reason text;
  v_n      int := 0;
  v_refund jsonb;
  r        record;
BEGIN
  IF v_ev IS NULL THEN
    RAISE EXCEPTION '_exos_notify_event_holders: event not found';
  END IF;
  IF p_template NOT IN ('event-cancelled', 'event-updated') THEN
    RAISE EXCEPTION '_exos_notify_event_holders: template must be event-cancelled|event-updated';
  END IF;
  SELECT o.owner_uid, left(nullif(btrim(to_jsonb(e)->>'cancel_reason'), ''), 500)
    INTO v_owner, v_reason
    FROM public.exos_events e JOIN public.exos_orgs o ON o.id = e.org_id
   WHERE e.id = p_event_id;

  FOR r IN
    WITH tk AS (
      SELECT t.owner_id, t.order_ref, t.pending_transfer_id
        FROM public.exos_tickets t
       WHERE t.event_id = p_event_id
         AND (p_template = 'event-cancelled' OR t.status <> 'voided')
    ), rcpt AS (
      SELECT lower(u.email) AS email, u.id AS user_id, tk.order_ref
        FROM tk JOIN auth.users u ON u.id = tk.owner_id
       WHERE coalesce(u.email, '') <> ''
         AND NOT (tk.pending_transfer_id IS NOT NULL AND tk.owner_id IS NOT DISTINCT FROM v_owner)
      UNION ALL
      SELECT lower(btrim(tr.receiver_email)), NULL::uuid, tk.order_ref
        FROM tk JOIN public.exos_transfers tr ON tr.id = tk.pending_transfer_id AND tr.status = 'pending'
       WHERE coalesce(tr.receiver_email, '') <> ''
    )
    SELECT email, (array_agg(user_id) FILTER (WHERE user_id IS NOT NULL))[1] AS user_id,
           array_agg(DISTINCT order_ref) FILTER (WHERE order_ref IS NOT NULL) AS refs
      FROM rcpt GROUP BY email ORDER BY email
  LOOP
    v_refund := NULL;
    IF p_template = 'event-cancelled' THEN
      SELECT jsonb_build_object(
               'status', CASE
                 WHEN count(s.session_id) = 0 AND coalesce(r.refs, '{}') <> '{}'
                      AND EXISTS (SELECT 1 FROM public.exos_checkout_sessions s2
                                   WHERE s2.session_id = ANY (r.refs) AND s2.amount_cents > 0) THEN 'not_buyer'
                 WHEN coalesce(sum(s.amount_cents), 0) = 0 THEN 'none'
                 WHEN coalesce(sum(x.refunded), 0) >= sum(s.amount_cents) THEN 'refunded'
                 WHEN bool_or(x.in_flight) THEN 'processing'
                 WHEN coalesce(sum(x.refunded), 0) > 0 THEN 'partial'
                 ELSE 'pending' END,
               'paid_cents', coalesce(sum(s.amount_cents), 0),
               'refunded_cents', coalesce(sum(x.refunded), 0),
               'currency', coalesce(max(s.currency), 'usd'))
        INTO v_refund
        FROM public.exos_checkout_sessions s
        CROSS JOIN LATERAL (
          SELECT (SELECT coalesce(sum(f.amount_cents), 0) FROM public.exos_order_refunds f
                   WHERE f.session_id = s.session_id AND f.status = 'succeeded') AS refunded,
                 (EXISTS (SELECT 1 FROM public.exos_order_refunds f
                           WHERE f.session_id = s.session_id AND f.status = 'pending')
                  OR EXISTS (SELECT 1 FROM public.exos_refund_requests q
                              WHERE q.session_id = s.session_id AND q.status IN ('claimed', 'pending'))) AS in_flight
        ) x
       WHERE s.session_id = ANY (coalesce(r.refs, '{}'))
         AND s.status IN ('fulfilled', 'refunded', 'partially_refunded')
         AND (s.buyer_uid = r.user_id OR lower(s.buyer_email) = r.email);
    END IF;

    IF public.exos_mail_enqueue(
         p_template, r.email,
         jsonb_build_object('event', v_ev)
           || CASE WHEN p_template = 'event-cancelled'
                   THEN jsonb_build_object('reason', v_reason, 'refund', v_refund) ELSE '{}'::jsonb END,
         CASE WHEN p_template = 'event-cancelled'
              THEN 'event-cancelled:' || p_event_id || ':' || md5(r.email) END,
         r.user_id, false, p_actor) IS NOT NULL THEN
      v_n := v_n + 1;
    END IF;
  END LOOP;
  RETURN v_n;
END $$;
REVOKE ALL ON FUNCTION public._exos_notify_event_holders(uuid, text, uuid) FROM PUBLIC, anon, authenticated;

-- Same signature as 20260523220000 (the SPA calls it); staff only.
CREATE OR REPLACE FUNCTION public.exos_notify_event_holders(
  p_event_id uuid,
  p_template text
) RETURNS int
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE v_org uuid;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'exos_notify_event_holders: not authenticated' USING ERRCODE = '42501';
  END IF;
  IF p_template NOT IN ('event-cancelled', 'event-updated') THEN
    RAISE EXCEPTION 'exos_notify_event_holders: template must be event-cancelled|event-updated';
  END IF;
  SELECT org_id INTO v_org FROM public.exos_events WHERE id = p_event_id;
  IF v_org IS NULL THEN
    RAISE EXCEPTION 'exos_notify_event_holders: event not found';
  END IF;
  IF NOT (public.exos_is_admin() OR public.exos_has_org_role(v_org, ARRAY['owner','manager'])) THEN
    RAISE EXCEPTION 'exos_notify_event_holders: not authorized' USING ERRCODE = '42501';
  END IF;
  RETURN public._exos_notify_event_holders(p_event_id, p_template, auth.uid());
END $$;
REVOKE ALL ON FUNCTION public.exos_notify_event_holders(uuid, text) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.exos_notify_event_holders(uuid, text) TO authenticated;

-- Any path that cancels an event (SPA, API, MCP) tells holders. The SPA's own
-- follow-up call is then a no-op (same dedupe key).
CREATE OR REPLACE FUNCTION public.exos_tg_event_cancelled_mail()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
  IF NEW.status = 'cancelled' AND OLD.status IS DISTINCT FROM 'cancelled' THEN
    BEGIN
      PERFORM public._exos_notify_event_holders(NEW.id, 'event-cancelled', auth.uid());
    EXCEPTION WHEN others THEN
      RAISE WARNING 'exos_tg_event_cancelled_mail: event %: % (%)', NEW.id, SQLERRM, SQLSTATE;
    END;
  END IF;
  RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION public.exos_tg_event_cancelled_mail() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS exos_events_cancelled_mail ON public.exos_events;
CREATE TRIGGER exos_events_cancelled_mail AFTER UPDATE OF status ON public.exos_events
  FOR EACH ROW EXECUTE FUNCTION public.exos_tg_event_cancelled_mail();

-- ---------------------------------------------------------------------------
-- 9. Buyer: refund issued (every succeeded refund, once per refund row).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.exos_tg_refund_issued_mail()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  s      public.exos_checkout_sessions%ROWTYPE;
  v_to   text;
  v_done int;
BEGIN
  IF NEW.status <> 'succeeded' OR (TG_OP = 'UPDATE' AND OLD.status = 'succeeded') THEN
    RETURN NEW;
  END IF;
  BEGIN
    SELECT * INTO s FROM public.exos_checkout_sessions WHERE session_id = NEW.session_id;
    IF s.session_id IS NULL THEN RETURN NEW; END IF;
    v_to := nullif(lower(btrim(coalesce(s.buyer_email, ''))), '');
    IF v_to IS NULL AND s.buyer_uid IS NOT NULL THEN
      SELECT lower(email) INTO v_to FROM auth.users WHERE id = s.buyer_uid;
    END IF;
    IF v_to IS NULL THEN RETURN NEW; END IF;
    SELECT coalesce(sum(amount_cents), 0) INTO v_done
      FROM public.exos_order_refunds WHERE session_id = NEW.session_id AND status = 'succeeded';
    PERFORM public.exos_mail_enqueue('refund-issued', v_to,
      jsonb_build_object(
        'event', public._exos_mail_event_json(s.event_id),
        'amount_cents', NEW.amount_cents,
        'currency', coalesce(NEW.currency, s.currency, 'usd'),
        'order_ref', NEW.session_id,
        'paid_cents', s.amount_cents,
        'refunded_total_cents', v_done,
        'partial', v_done < s.amount_cents),
      'refund-issued:' || NEW.id, s.buyer_uid, false, NULL);
  EXCEPTION WHEN others THEN
    -- A mail problem never blocks recording a refund.
    RAISE WARNING 'exos_tg_refund_issued_mail: refund %: % (%)', NEW.id, SQLERRM, SQLSTATE;
  END;
  RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION public.exos_tg_refund_issued_mail() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS exos_order_refunds_mail ON public.exos_order_refunds;
CREATE TRIGGER exos_order_refunds_mail AFTER INSERT OR UPDATE OF status ON public.exos_order_refunds
  FOR EACH ROW EXECUTE FUNCTION public.exos_tg_refund_issued_mail();

-- ---------------------------------------------------------------------------
-- 10. Buyer: order receipt, extended in place (still appended by
--     exos_fulfill_checkout to 'ticket-issued' and the guest claim mail).
--     First sentence unchanged; adds the line items the buyer was shown, the
--     all-in note and, when the tickets are already in a wallet, a link.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.exos_receipt_html(p_session_id text)
RETURNS text
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT coalesce((
    SELECT '<p>Paid: <strong>' || to_char(s.amount_cents / 100.0, 'FM999,999,990.00') || ' ' ||
           upper(coalesce(s.currency, 'usd')) || '</strong>' ||
           CASE WHEN coalesce(s.tax_cents, 0) > 0
                THEN ' (including ' || to_char(s.tax_cents / 100.0, 'FM999,999,990.00') || ' tax)' ELSE '' END ||
           '. Order reference: ' || public.exos_mail_escape(s.session_id) || '.</p>' ||
           coalesce((
             SELECT '<table style="border-collapse:collapse;font-size:14px">' ||
                    string_agg('<tr><td style="padding:2px 12px 2px 0">' || l.quantity || ' &times; ' ||
                               public.exos_mail_escape(coalesce(l.item_name, 'Ticket')) ||
                               '</td><td style="padding:2px 0;text-align:right">' ||
                               to_char(l.line_total_cents / 100.0, 'FM999,999,990.00') || '</td></tr>',
                               '' ORDER BY l.line_no) ||
                    '</table>'
               FROM public.exos_price_disclosure_lines l
              WHERE l.session_id = s.session_id), '') ||
           '<p style="color:#666;font-size:13px">All-in price: no fees were added at checkout' ||
           CASE WHEN coalesce(s.tax_cents, 0) > 0 THEN ' and tax is included' ELSE '' END || '.</p>' ||
           CASE WHEN EXISTS (SELECT 1 FROM public.exos_tickets t
                              WHERE t.order_ref = s.session_id AND t.pending_transfer_id IS NOT NULL)
                THEN ''
                ELSE '<p><a href="{{app_url}}/my-tickets">View your tickets</a></p>' END
      FROM public.exos_checkout_sessions s
     WHERE s.session_id = p_session_id AND coalesce(s.amount_cents, 0) > 0), '');
$$;
REVOKE ALL ON FUNCTION public.exos_receipt_html(text) FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 11. Buyer: event reminder, extended in place (body of 20260911051000 kept;
--     the cron + stamps in exos_send_event_reminders are unchanged). Adds a
--     link to the tickets, and a ticket parked on the org owner for a
--     pending claim no longer sends the owner a reminder for it.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.exos_queue_event_reminder(p_event_id uuid, p_created_by uuid DEFAULT NULL)
RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE
  v_ev      public.exos_events%ROWTYPE;
  v_owner   uuid;
  v_tz      text;
  v_safe    text;
  v_when    text;
  v_doors   text := '';
  v_venue   text := '';
  v_subj    text;
  v_body    text;
  v_n       int := 0;
BEGIN
  SELECT * INTO v_ev FROM public.exos_events WHERE id = p_event_id;
  IF v_ev.id IS NULL OR v_ev.starts_at IS NULL THEN
    RAISE EXCEPTION 'exos_queue_event_reminder: event % not found or has no starts_at', p_event_id;
  END IF;
  SELECT owner_uid INTO v_owner FROM public.exos_orgs WHERE id = v_ev.org_id;

  v_tz := coalesce(nullif(v_ev.timezone, ''), 'UTC');
  BEGIN
    v_when := to_char(v_ev.starts_at AT TIME ZONE v_tz, 'FMDay, FMMonth FMDD "at" FMHH12:MI AM');
    IF v_ev.doors_at IS NOT NULL THEN
      v_doors := ' Doors open at ' || to_char(v_ev.doors_at AT TIME ZONE v_tz, 'FMHH12:MI AM') || '.';
    END IF;
  EXCEPTION WHEN invalid_parameter_value THEN
    RAISE WARNING 'exos_queue_event_reminder: event % has invalid timezone %; falling back to UTC',
      p_event_id, v_ev.timezone;
    v_tz   := 'UTC';
    v_when := to_char(v_ev.starts_at AT TIME ZONE 'UTC', 'FMDay, FMMonth FMDD "at" FMHH12:MI AM');
    v_doors := '';
  END;

  -- HTML body: escaped. The subject is a plain-text header: RAW name.
  v_safe := public.exos_mail_escape(coalesce(v_ev.name, 'your event'));
  IF v_ev.venue_name IS NOT NULL AND v_ev.venue_name <> '' THEN
    v_venue := ' at ' || public.exos_mail_escape(v_ev.venue_name);
  END IF;

  v_subj := left('Reminder: ' || coalesce(v_ev.name, 'your event') || ' — ' || v_when, 200);
  v_body := '<p>Your ticket for <strong>' || v_safe || '</strong>' || v_venue ||
            ' is coming up: <strong>' || v_when || '</strong> (' || v_tz || ').' || v_doors ||
            '</p><p>Open the app to show your ticket at the door. Your entry code rotates, so ' ||
            'use the live pass rather than a screenshot.</p>' ||
            '<p><a href="{{app_url}}/my-tickets">Your tickets</a></p>';

  INSERT INTO public.exos_mail (template, to_email, subject, html, created_by, status)
  SELECT 'event-reminder', lower(u.email), v_subj, v_body, p_created_by, 'pending'
  FROM (SELECT DISTINCT owner_id FROM public.exos_tickets
         WHERE event_id = p_event_id AND status <> 'voided'
           AND NOT (pending_transfer_id IS NOT NULL AND owner_id IS NOT DISTINCT FROM v_owner)) h
  JOIN auth.users u ON u.id = h.owner_id
  WHERE u.email IS NOT NULL;

  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN v_n;
END $$;
REVOKE ALL ON FUNCTION public.exos_queue_event_reminder(uuid, uuid) FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 12. Organizer: event published (owner + managers). The first event of a
--     series only, so creating 20 dates doesn't send 20 mails.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.exos_tg_event_published_mail()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  u    record;
  v_ev jsonb;
BEGIN
  IF NEW.status <> 'published' OR (TG_OP = 'UPDATE' AND OLD.status = 'published') THEN
    RETURN NEW;
  END IF;
  IF coalesce((to_jsonb(NEW)->>'series_index')::int, 0) > 0 THEN
    RETURN NEW;
  END IF;
  BEGIN
    v_ev := public._exos_mail_event_json(NEW.id);
    FOR u IN SELECT * FROM public.exos_org_mail_recipients(NEW.org_id, ARRAY['owner','manager']) LOOP
      PERFORM public.exos_mail_enqueue('event-published', u.email, jsonb_build_object('event', v_ev),
        'event-published:' || NEW.id || ':' || u.user_id, u.user_id, false, NULL);
    END LOOP;
  EXCEPTION WHEN others THEN
    RAISE WARNING 'exos_tg_event_published_mail: event %: % (%)', NEW.id, SQLERRM, SQLSTATE;
  END;
  RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION public.exos_tg_event_published_mail() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS exos_events_published_mail ON public.exos_events;
CREATE TRIGGER exos_events_published_mail AFTER INSERT OR UPDATE OF status ON public.exos_events
  FOR EACH ROW EXECUTE FUNCTION public.exos_tg_event_published_mail();

-- ---------------------------------------------------------------------------
-- 13. Organizer: payout sent / pending. For the payout ledger (built
--     separately) to call; takes plain values so it doesn't depend on those
--     tables. Owner + managers + finance, once per org + status + reference
--     (or period when there's no reference). Returns mails queued.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.exos_queue_payout_mail(
  p_org_id       uuid,
  p_amount_cents bigint,
  p_currency     text,
  p_period       text,
  p_status       text DEFAULT 'sent',
  p_reference    text DEFAULT NULL
) RETURNS int
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_cur  text := lower(btrim(coalesce(p_currency, '')));
  v_per  text := btrim(coalesce(p_period, ''));
  v_ref  text := nullif(btrim(coalesce(p_reference, '')), '');
  v_org  text;
  v_n    int := 0;
  u      record;
BEGIN
  IF p_status NOT IN ('sent', 'pending') THEN
    RAISE EXCEPTION 'exos_queue_payout_mail: status must be sent or pending';
  END IF;
  IF p_amount_cents IS NULL OR p_amount_cents < 0 THEN
    RAISE EXCEPTION 'exos_queue_payout_mail: amount must be zero or more';
  END IF;
  IF v_cur !~ '^[a-z]{3}$' THEN
    RAISE EXCEPTION 'exos_queue_payout_mail: currency must be a 3-letter code';
  END IF;
  IF v_per = '' OR char_length(v_per) > 100 OR char_length(coalesce(v_ref, '')) > 200 THEN
    RAISE EXCEPTION 'exos_queue_payout_mail: period is required (max 100), reference max 200';
  END IF;
  SELECT name INTO v_org FROM public.exos_orgs WHERE id = p_org_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'exos_queue_payout_mail: org not found';
  END IF;
  FOR u IN SELECT * FROM public.exos_org_mail_recipients(p_org_id, ARRAY['owner','manager','finance']) LOOP
    IF public.exos_mail_enqueue('payout-' || p_status, u.email,
         jsonb_build_object('org', jsonb_build_object('id', p_org_id, 'name', v_org),
                            'amount_cents', p_amount_cents, 'currency', v_cur,
                            'period', v_per, 'reference', v_ref),
         'payout-' || p_status || ':' || p_org_id || ':' || md5(coalesce(v_ref, 'period:' || v_per)) || ':' || u.user_id,
         u.user_id, false, NULL) IS NOT NULL THEN
      v_n := v_n + 1;
    END IF;
  END LOOP;
  RETURN v_n;
END $$;
REVOKE ALL ON FUNCTION public.exos_queue_payout_mail(uuid, bigint, text, text, text, text) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.exos_queue_payout_mail(uuid, bigint, text, text, text, text) TO service_role;

-- ---------------------------------------------------------------------------
-- 14. Scheduled follow-ups (one cron entry point; hourly is plenty). Every
--     mail is once-only by its dedupe key, and every window is bounded so the
--     first run after deploy doesn't mail about the distant past.
--
--   post-event          buyer, marketing. Event ended 12h..3d ago, published,
--                       org toggle on. Holders with an account; org staff
--                       excluded. Thanks + follow + up to 3 next events.
--   org-welcome         owner, transactional. Org created < 2 days ago.
--   org-first-event     owner, marketing. Day 3..7, only if the org has no event.
--   org-connect-stripe  owner, marketing. Day 7..14, only if Stripe can't take
--                       payments yet.
--   fee-free-ending     owner/manager/finance, transactional. 14 days and 1 day
--                       before exos_org_billing.fee_free_until.
--   inventory-low       owner/manager, transactional. A tier on a published,
--   inventory-sold-out  upcoming event with <= 10% (min 1) left, or none left.
--                       Once per tier + capacity (raising capacity re-arms it).
--   org-sales-digest    owner/manager, marketing. Yesterday (UTC), only orgs
--                       that sold something.
--   org-weekly-summary  owner/manager, marketing. Last Mon-Sun week (UTC), orgs
--                       with sales that week or an event in the next 14 days.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.exos_send_mail_followups(p_limit int DEFAULT 500)
RETURNS TABLE (out_template text, out_queued int)
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_start   timestamptz := clock_timestamp();
  v_limit   int := greatest(coalesce(p_limit, 500), 1);
  v_counts  jsonb := '{}'::jsonb;
  v_failed  int := 0;
  v_budget  boolean := false;
  r         record;
  u         record;
  v_tpl     text;
  v_key     text;
  v_payload jsonb;
  v_next    jsonb;
  v_ev      jsonb;
  v_org     jsonb;
  v_age     interval;
  v_left    int;
  v_thresh  int;
  v_stage   text;
  v_from    timestamptz;
  v_to      timestamptz;
  v_mk      boolean;
BEGIN
  IF session_user NOT IN ('service_role','postgres','supabase_admin') THEN
    RAISE EXCEPTION 'exos_send_mail_followups: service role only' USING ERRCODE = '42501';
  END IF;
  IF NOT public.cron_should_fire('exos_send_mail_followups') THEN
    RETURN;
  END IF;

  -- post-event ---------------------------------------------------------------
  FOR r IN
    SELECT e.id, e.org_id, o.name AS org_name, o.owner_uid
      FROM public.exos_events e
      JOIN public.exos_orgs o ON o.id = e.org_id
     WHERE e.status = 'published' AND o.post_event_emails_enabled
       AND e.starts_at IS NOT NULL
       AND coalesce(e.ends_at, e.starts_at + interval '4 hours') <= now() - interval '12 hours'
       AND coalesce(e.ends_at, e.starts_at + interval '4 hours') >  now() - interval '3 days'
     ORDER BY e.starts_at
     LIMIT 100
  LOOP
    v_ev := public._exos_mail_event_json(r.id);
    SELECT coalesce(jsonb_agg(jsonb_build_object('id', n.id, 'name', n.name, 'starts_at', n.starts_at,
                                                 'timezone', n.timezone, 'venue_name', n.venue_name)
                              ORDER BY n.starts_at), '[]'::jsonb)
      INTO v_next
      FROM (SELECT * FROM public.exos_events n
             WHERE n.org_id = r.org_id AND n.status = 'published' AND n.starts_at > now()
             ORDER BY n.starts_at LIMIT 3) n;
    FOR u IN
      SELECT DISTINCT t.owner_id AS user_id, lower(au.email) AS email
        FROM public.exos_tickets t
        JOIN auth.users au ON au.id = t.owner_id
       WHERE t.event_id = r.id AND t.status <> 'voided' AND t.pending_transfer_id IS NULL
         AND coalesce(au.email, '') <> ''
         AND t.owner_id IS DISTINCT FROM r.owner_uid
         AND NOT EXISTS (SELECT 1 FROM public.exos_org_memberships m
                          WHERE m.org_id = r.org_id AND m.user_id = t.owner_id AND m.disabled IS NOT TRUE)
       LIMIT v_limit
    LOOP
      BEGIN
        IF public.exos_mail_enqueue('post-event', u.email,
             jsonb_build_object('event', v_ev,
                                'org', jsonb_build_object('id', r.org_id, 'name', r.org_name),
                                'following', public._exos_is_following(u.user_id, r.org_id),
                                'next_events', v_next),
             'post-event:' || r.id || ':' || u.user_id, u.user_id, true, NULL) IS NOT NULL THEN
          v_counts := v_counts || jsonb_build_object('post-event', coalesce((v_counts->>'post-event')::int, 0) + 1);
        END IF;
      EXCEPTION WHEN others THEN
        v_failed := v_failed + 1;
        RAISE WARNING 'exos_send_mail_followups: post-event % / %: % (%)', r.id, u.user_id, SQLERRM, SQLSTATE;
      END;
    END LOOP;
    IF clock_timestamp() - v_start > interval '20 seconds' THEN v_budget := true; EXIT; END IF;
  END LOOP;

  -- onboarding: welcome (day 0), first event (day 3), connect Stripe (day 7) -
  IF NOT v_budget THEN
    FOR r IN
      SELECT o.id, o.name, o.owner_uid, o.created_at, lower(au.email) AS email,
             (SELECT b.fee_free_until FROM public.exos_org_billing b WHERE b.org_id = o.id) AS fee_free_until
        FROM public.exos_orgs o
        JOIN auth.users au ON au.id = o.owner_uid
       WHERE o.created_at > now() - interval '14 days' AND coalesce(au.email, '') <> ''
       ORDER BY o.created_at
       LIMIT v_limit
    LOOP
      v_age := now() - r.created_at;
      v_tpl := CASE
        WHEN v_age < interval '2 days' THEN 'org-welcome'
        WHEN v_age >= interval '3 days' AND v_age < interval '7 days'
             AND NOT EXISTS (SELECT 1 FROM public.exos_events e WHERE e.org_id = r.id) THEN 'org-first-event'
        WHEN v_age >= interval '7 days'
             AND NOT public._exos_org_payments_ready(r.id) THEN 'org-connect-stripe'
      END;
      CONTINUE WHEN v_tpl IS NULL;
      BEGIN
        IF public.exos_mail_enqueue(v_tpl, r.email,
             jsonb_build_object('org', jsonb_build_object('id', r.id, 'name', r.name),
                                'fee_free_until', r.fee_free_until,
                                'has_event', EXISTS (SELECT 1 FROM public.exos_events e WHERE e.org_id = r.id)),
             v_tpl || ':' || r.id || ':' || r.owner_uid, r.owner_uid, v_tpl <> 'org-welcome', NULL) IS NOT NULL THEN
          v_counts := v_counts || jsonb_build_object(v_tpl, coalesce((v_counts->>v_tpl)::int, 0) + 1);
        END IF;
      EXCEPTION WHEN others THEN
        v_failed := v_failed + 1;
        RAISE WARNING 'exos_send_mail_followups: % for org %: % (%)', v_tpl, r.id, SQLERRM, SQLSTATE;
      END;
    END LOOP;
    IF clock_timestamp() - v_start > interval '20 seconds' THEN v_budget := true; END IF;
  END IF;

  -- fee-free months ending (14 days and 1 day before) ------------------------
  IF NOT v_budget THEN
    FOR r IN
      SELECT b.org_id, b.fee_free_until, o.name
        FROM public.exos_org_billing b
        JOIN public.exos_orgs o ON o.id = b.org_id
       WHERE b.fee_free_until > now() AND b.fee_free_until <= now() + interval '14 days'
       ORDER BY b.fee_free_until
       LIMIT v_limit
    LOOP
      v_stage := CASE WHEN r.fee_free_until <= now() + interval '1 day' THEN '1d' ELSE '14d' END;
      FOR u IN SELECT * FROM public.exos_org_mail_recipients(r.org_id, ARRAY['owner','manager','finance']) LOOP
        BEGIN
          IF public.exos_mail_enqueue('fee-free-ending', u.email,
               jsonb_build_object('org', jsonb_build_object('id', r.org_id, 'name', r.name),
                                  'fee_free_until', r.fee_free_until, 'stage', v_stage,
                                  'days_left', greatest(ceil(extract(epoch FROM r.fee_free_until - now()) / 86400)::int, 1),
                                  'fee_bps', public.exos_platform_fee_bps()),
               'fee-free-ending:' || r.org_id || ':' || to_char(r.fee_free_until AT TIME ZONE 'UTC', 'YYYYMMDD') ||
                 ':' || v_stage || ':' || u.user_id,
               u.user_id, false, NULL) IS NOT NULL THEN
            v_counts := v_counts || jsonb_build_object('fee-free-ending', coalesce((v_counts->>'fee-free-ending')::int, 0) + 1);
          END IF;
        EXCEPTION WHEN others THEN
          v_failed := v_failed + 1;
          RAISE WARNING 'exos_send_mail_followups: fee-free-ending org %: % (%)', r.org_id, SQLERRM, SQLSTATE;
        END;
      END LOOP;
    END LOOP;
    IF clock_timestamp() - v_start > interval '20 seconds' THEN v_budget := true; END IF;
  END IF;

  -- inventory low / sold out ---------------------------------------------------
  IF NOT v_budget THEN
    FOR r IN
      SELECT t.id AS tier_id, t.name AS tier_name, t.capacity, t.sold, e.id AS event_id, e.org_id
        FROM public.exos_ticket_tiers t
        JOIN public.exos_events e ON e.id = t.event_id
       WHERE e.status = 'published' AND e.starts_at > now()
         AND t.capacity > 0 AND t.sold > 0
         AND t.capacity - t.sold <= greatest(ceil(t.capacity * 0.1)::int, 1)
       ORDER BY e.starts_at, t.sort_order, t.id
       LIMIT v_limit
    LOOP
      v_left := greatest(r.capacity - r.sold, 0);
      v_tpl  := CASE WHEN v_left = 0 THEN 'inventory-sold-out' ELSE 'inventory-low' END;
      v_ev   := public._exos_mail_event_json(r.event_id);
      FOR u IN SELECT * FROM public.exos_org_mail_recipients(r.org_id, ARRAY['owner','manager']) LOOP
        BEGIN
          IF public.exos_mail_enqueue(v_tpl, u.email,
               jsonb_build_object('event', v_ev,
                                  'tier', jsonb_build_object('id', r.tier_id, 'name', r.tier_name,
                                                             'capacity', r.capacity, 'sold', r.sold, 'remaining', v_left)),
               v_tpl || ':' || r.tier_id || ':' || r.capacity || ':' || u.user_id,
               u.user_id, false, NULL) IS NOT NULL THEN
            v_counts := v_counts || jsonb_build_object(v_tpl, coalesce((v_counts->>v_tpl)::int, 0) + 1);
          END IF;
        EXCEPTION WHEN others THEN
          v_failed := v_failed + 1;
          RAISE WARNING 'exos_send_mail_followups: % tier %: % (%)', v_tpl, r.tier_id, SQLERRM, SQLSTATE;
        END;
      END LOOP;
    END LOOP;
    IF clock_timestamp() - v_start > interval '20 seconds' THEN v_budget := true; END IF;
  END IF;

  -- daily sales digest (yesterday, UTC) and weekly summary (last Mon-Sun, UTC)
  FOREACH v_tpl IN ARRAY ARRAY['org-sales-digest', 'org-weekly-summary'] LOOP
    EXIT WHEN v_budget;
    IF v_tpl = 'org-sales-digest' THEN
      v_to   := date_trunc('day', now() AT TIME ZONE 'UTC') AT TIME ZONE 'UTC';
      v_from := v_to - interval '1 day';
    ELSE
      v_to   := date_trunc('week', now() AT TIME ZONE 'UTC') AT TIME ZONE 'UTC';
      v_from := v_to - interval '7 days';
    END IF;
    FOR r IN
      WITH sales AS (
        SELECT s.org_id, s.event_id, e.name, lower(coalesce(s.currency, 'usd')) AS currency,
               count(*)::int AS orders, sum(s.quantity)::int AS tickets, sum(s.amount_cents)::bigint AS gross_cents
          FROM public.exos_checkout_sessions s
          JOIN public.exos_events e ON e.id = s.event_id
         WHERE s.fulfilled_at >= v_from AND s.fulfilled_at < v_to
           AND s.status IN ('fulfilled', 'refunded', 'partially_refunded')
         GROUP BY 1, 2, 3, 4
      ), orgs AS (
        SELECT org_id FROM sales
        UNION
        SELECT e.org_id FROM public.exos_events e
         WHERE v_tpl = 'org-weekly-summary' AND e.status = 'published'
           AND e.starts_at > now() AND e.starts_at <= now() + interval '14 days'
      )
      SELECT g.org_id, o.name AS org_name,
             (SELECT coalesce(jsonb_agg(jsonb_build_object('id', x.event_id, 'name', x.name, 'currency', x.currency,
                                                           'orders', x.orders, 'tickets', x.tickets,
                                                           'gross_cents', x.gross_cents)
                                        ORDER BY x.gross_cents DESC, x.event_id), '[]'::jsonb)
                FROM sales x WHERE x.org_id = g.org_id) AS events,
             (SELECT coalesce(jsonb_agg(jsonb_build_object('currency', y.currency, 'orders', y.orders,
                                                           'tickets', y.tickets, 'gross_cents', y.gross_cents)
                                        ORDER BY y.currency), '[]'::jsonb)
                FROM (SELECT currency, sum(orders)::int AS orders, sum(tickets)::int AS tickets,
                             sum(gross_cents)::bigint AS gross_cents
                        FROM sales WHERE sales.org_id = g.org_id GROUP BY currency) y) AS totals
        FROM orgs g
        JOIN public.exos_orgs o ON o.id = g.org_id
       ORDER BY g.org_id
       LIMIT v_limit
    LOOP
      v_payload := jsonb_build_object('org', jsonb_build_object('id', r.org_id, 'name', r.org_name),
                                      'from', v_from, 'to', v_to,
                                      'events', r.events, 'totals', r.totals);
      IF v_tpl = 'org-weekly-summary' THEN
        v_payload := v_payload || jsonb_build_object(
          'checkins', (SELECT count(*) FROM public.exos_event_checkins c
                        WHERE c.org_id = r.org_id AND c.scanned_at >= v_from AND c.scanned_at < v_to),
          'upcoming', (SELECT coalesce(jsonb_agg(jsonb_build_object('id', e.id, 'name', e.name, 'starts_at', e.starts_at,
                                                                    'timezone', e.timezone, 'sold', e.tickets_sold,
                                                                    'capacity', e.total_tickets) ORDER BY e.starts_at), '[]'::jsonb)
                         FROM (SELECT * FROM public.exos_events e
                                WHERE e.org_id = r.org_id AND e.status = 'published'
                                  AND e.starts_at > now() AND e.starts_at <= now() + interval '14 days'
                                ORDER BY e.starts_at LIMIT 5) e));
      END IF;
      FOR u IN SELECT * FROM public.exos_org_mail_recipients(r.org_id, ARRAY['owner','manager']) LOOP
        BEGIN
          IF public.exos_mail_enqueue(v_tpl, u.email, v_payload,
               v_tpl || ':' || r.org_id || ':' || to_char(v_from AT TIME ZONE 'UTC', 'YYYYMMDD') || ':' || u.user_id,
               u.user_id, true, NULL) IS NOT NULL THEN
            v_counts := v_counts || jsonb_build_object(v_tpl, coalesce((v_counts->>v_tpl)::int, 0) + 1);
          END IF;
        EXCEPTION WHEN others THEN
          v_failed := v_failed + 1;
          RAISE WARNING 'exos_send_mail_followups: % org %: % (%)', v_tpl, r.org_id, SQLERRM, SQLSTATE;
        END;
      END LOOP;
      IF clock_timestamp() - v_start > interval '20 seconds' THEN v_budget := true; EXIT; END IF;
    END LOOP;
  END LOOP;

  IF v_budget THEN
    RAISE WARNING 'exos_send_mail_followups: 20s budget hit; the rest goes out next run';
  END IF;
  IF v_failed > 0 THEN
    v_counts := v_counts || jsonb_build_object('failed', v_failed);
  END IF;
  RETURN QUERY SELECT k, v::int FROM jsonb_each_text(v_counts) AS j(k, v) ORDER BY k;
END $$;
REVOKE ALL ON FUNCTION public.exos_send_mail_followups(int) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.exos_send_mail_followups(int) TO service_role;
