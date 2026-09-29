-- ============================================================================
-- Migration 20260929150000 — Exos (Bridge / D4): optional refunds when the
--                            organizer changes an event's date
--
-- Lane:     d4 (exos / bridge ticketing infra)
-- Touches:  W: TABLE exos_event_reschedules (created IF NOT EXISTS with the
--              20260703124000 shape; + refunds_offered, refund_deadline,
--              qualifying, notified_at)
--           C: TABLE exos_reschedule_links (per ticket + reschedule bearer
--              tokens for the mail's refund / release links; service role only)
--           C: TABLE exos_reschedule_releases (free tickets given back)
--           W: TABLE exos_refund_requests (+reschedule_id; scope + 'reschedule')
--           W: TRIGGER exos_events_date_guard (a client can't move a sold
--              event's date by a qualifying amount except through the RPC)
--           R: FUNCTION exos_reschedule_event (8 args; the 6-arg version of
--              20260703124000 is dropped: named calls from old clients still
--              resolve, p_offer_refunds defaults to no refunds)
--           C: FUNCTION exos_reschedule_qualifies, exos_reschedule_default_deadline
--              (pure), _exos_resched_ticket_state, _exos_resched_actor_ok,
--              _exos_reschedule_notify, _exos_reschedule_release (internal),
--              exos_request_reschedule_refund, exos_reschedule_release_svc,
--              exos_reschedule_link_info (service role: exos-refund),
--              exos_reschedule_release_mine, exos_my_reschedule_offers,
--              exos_event_reschedule_summary (authenticated)
--           R: exos_events, exos_tickets, exos_checkout_sessions,
--              exos_order_payments, exos_refund_requests(_items),
--              exos_transfers, exos_orgs, exos_org_memberships, auth.users
-- Pre-reqs: 20260926040000 (organizer refunds), 20260929071000 (mail
--           templates: exos_mail_enqueue, _exos_mail_event_json),
--           20260926050000 (exos_tier_is_table)
--
-- Operator ask: "Have to allow for refunds optionally if event date is
-- changed by org". Design (docs/organizer-guide.md "Changing the date"):
--
--   * A date change QUALIFIES when the event moves to another day (in its own
--     time zone) or its start moves by more than 3 hours. On a qualifying
--     change to an event with tickets, the organizer is asked "Offer refunds
--     to ticket holders?" (checked by default in the UI) with a deadline that
--     defaults to the earlier of change + 14 days and new start − 24 h.
--   * exos_reschedule_event moves the times, records the reschedule and
--     queues the 'event-rescheduled' mail to every holder in one
--     transaction, so the notice can't be skipped. A qualifying date change
--     written straight to exos_events by a client is refused (trigger).
--   * Refunds are self-serve and auto-approved until the deadline, per
--     ticket, through the exos-refund edge function (Stripe) with the same
--     exos_refund_finalize as organizer refunds. Free / comp tickets can be
--     released instead (void, no money). Marketplace tickets are refunded by
--     the marketplace; the mail says so.
--   * Who may ask: the person who PAID (checkout buyer account, or the
--     buyer's confirmed email), signed in or through the per-ticket link in
--     their mail. The money goes back to that card, so a ticket someone was
--     given (transferred) can only be refunded by the original buyer, and
--     the refund voids it either way. The holder's mail says so.
--   * Add-ons: a ticket's refund is its share of the ticket part of the order
--     (tax included, the same split as organizer refunds). Add-ons are
--     refunded only with the order's last ticket: when no other ticket of the
--     order has money left, the request takes everything still refundable.
--   * Idempotent: one request per ticket + reschedule (nonce rsr:<r>:<t>); a
--     repeat or a concurrent call returns the same request, so the same
--     Stripe idempotency key (exos_refund_<request id>). Claims serialize on
--     the order row like organizer refunds.
--
-- Re-run safe. D4 authors; applying to prod is operator-gated.
-- ROLLBACK: DROP TRIGGER exos_events_date_guard ON exos_events; DROP the new
--   functions and tables exos_reschedule_links / exos_reschedule_releases;
--   ALTER TABLE exos_refund_requests DROP COLUMN reschedule_id (restore the
--   scope check without 'reschedule' once no such rows exist); re-apply
--   20260703124000 section 3 for the 6-arg exos_reschedule_event.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. Reschedule log (20260703124000 shape, created here when missing) + the
--    refund offer.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.exos_event_reschedules (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  event_id        uuid NOT NULL REFERENCES public.exos_events (id) ON DELETE CASCADE,
  org_id          uuid NOT NULL REFERENCES public.exos_orgs (id) ON DELETE CASCADE,
  old_starts_at   timestamptz,
  new_starts_at   timestamptz NOT NULL,
  reason          text CHECK (reason IS NULL OR char_length(reason) <= 500),
  rescheduled_by  uuid REFERENCES auth.users (id) ON DELETE SET NULL,
  recipient_count integer NOT NULL DEFAULT 0 CHECK (recipient_count >= 0),
  created_at      timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS exos_event_reschedules_event_idx
  ON public.exos_event_reschedules (event_id, created_at DESC);

ALTER TABLE public.exos_event_reschedules ADD COLUMN IF NOT EXISTS refunds_offered boolean NOT NULL DEFAULT false;
ALTER TABLE public.exos_event_reschedules ADD COLUMN IF NOT EXISTS refund_deadline timestamptz;
ALTER TABLE public.exos_event_reschedules ADD COLUMN IF NOT EXISTS qualifying      boolean NOT NULL DEFAULT false;
ALTER TABLE public.exos_event_reschedules ADD COLUMN IF NOT EXISTS notified_at     timestamptz;
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint
                  WHERE conrelid = 'public.exos_event_reschedules'::regclass
                    AND conname = 'exos_event_reschedules_offer_chk') THEN
    ALTER TABLE public.exos_event_reschedules ADD CONSTRAINT exos_event_reschedules_offer_chk
      CHECK (NOT refunds_offered OR refund_deadline IS NOT NULL);
  END IF;
END $$;
COMMENT ON COLUMN public.exos_event_reschedules.refunds_offered IS
  'Holders may ask for a refund (free tickets: release) until refund_deadline (mig 20260929150000). rescheduled_by is who made the change.';

ALTER TABLE public.exos_event_reschedules ENABLE ROW LEVEL SECURITY;
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE schemaname = 'public'
                    AND tablename = 'exos_event_reschedules' AND policyname = 'exos_event_reschedules_staff_sel') THEN
    CREATE POLICY exos_event_reschedules_staff_sel ON public.exos_event_reschedules
      FOR SELECT TO authenticated
      USING (exos_is_admin()
             OR exos_has_org_role(org_id, ARRAY['owner','manager','finance','scanner','content']));
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE schemaname = 'public'
                    AND tablename = 'exos_event_reschedules' AND policyname = 'exos_event_reschedules_holder_sel') THEN
    CREATE POLICY exos_event_reschedules_holder_sel ON public.exos_event_reschedules
      FOR SELECT TO authenticated
      USING (EXISTS (SELECT 1 FROM public.exos_tickets t
                      WHERE t.event_id = exos_event_reschedules.event_id
                        AND t.owner_id = auth.uid() AND t.status <> 'voided'));
  END IF;
END $$;
REVOKE ALL ON public.exos_event_reschedules FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.exos_event_reschedules TO authenticated;
GRANT ALL ON public.exos_event_reschedules TO service_role;

-- ---------------------------------------------------------------------------
-- 2. Mail-link tokens and releases. Service role only (the definer RPCs and
--    the exos-refund edge function read them).
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.exos_reschedule_links (
  token         text PRIMARY KEY CHECK (token ~ '^[0-9a-f]{64}$'),
  reschedule_id uuid NOT NULL REFERENCES public.exos_event_reschedules (id) ON DELETE CASCADE,
  ticket_id     uuid NOT NULL REFERENCES public.exos_tickets (id) ON DELETE CASCADE,
  kind          text NOT NULL CHECK (kind IN ('refund', 'release')),
  created_at    timestamptz NOT NULL DEFAULT now(),
  UNIQUE (reschedule_id, ticket_id, kind)
);
COMMENT ON TABLE public.exos_reschedule_links IS
  'Bearer links in the event-rescheduled mail (mig 20260929150000): 256-bit token per ticket + reschedule, sent to the person who may act (payer for a refund, holder for a release). Valid only for that ticket, that action and the event''s latest reschedule.';

CREATE TABLE IF NOT EXISTS public.exos_reschedule_releases (
  reschedule_id uuid NOT NULL REFERENCES public.exos_event_reschedules (id) ON DELETE CASCADE,
  ticket_id     uuid NOT NULL REFERENCES public.exos_tickets (id) ON DELETE CASCADE,
  released_by   uuid REFERENCES auth.users (id) ON DELETE SET NULL,
  via           text NOT NULL CHECK (via IN ('account', 'link')),
  created_at    timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (reschedule_id, ticket_id)
);

ALTER TABLE public.exos_reschedule_links    ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.exos_reschedule_releases ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.exos_reschedule_links, public.exos_reschedule_releases FROM PUBLIC, anon, authenticated;
GRANT  ALL ON public.exos_reschedule_links, public.exos_reschedule_releases TO service_role;
DO $$
DECLARE r text;
BEGIN
  FOREACH r IN ARRAY ARRAY['coworker_readonly','analyst_ro'] LOOP
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = r) THEN
      EXECUTE format('REVOKE ALL ON public.exos_reschedule_links, public.exos_reschedule_releases FROM %I', r);
    END IF;
  END LOOP;
END $$;

-- ---------------------------------------------------------------------------
-- 3. Refund requests: which reschedule a buyer's request answers.
-- ---------------------------------------------------------------------------
ALTER TABLE public.exos_refund_requests
  ADD COLUMN IF NOT EXISTS reschedule_id uuid REFERENCES public.exos_event_reschedules (id) ON DELETE SET NULL;
CREATE INDEX IF NOT EXISTS exos_refund_requests_reschedule_idx
  ON public.exos_refund_requests (reschedule_id) WHERE reschedule_id IS NOT NULL;
DO $$ BEGIN
  IF position('reschedule' in coalesce((SELECT pg_get_constraintdef(c.oid) FROM pg_constraint c
       WHERE c.conrelid = 'public.exos_refund_requests'::regclass
         AND c.conname = 'exos_refund_requests_scope_check'), '')) = 0 THEN
    ALTER TABLE public.exos_refund_requests DROP CONSTRAINT IF EXISTS exos_refund_requests_scope_check;
    ALTER TABLE public.exos_refund_requests ADD CONSTRAINT exos_refund_requests_scope_check
      CHECK (scope IN ('tickets', 'order', 'event_cancel', 'reschedule'));
  END IF;
END $$;

-- ---------------------------------------------------------------------------
-- 4. Pure rules (mirrored in supabase/functions/_shared/reschedule-refund.ts).
-- ---------------------------------------------------------------------------
-- Another day in the event's zone, or the start moved by more than 3 hours.
CREATE OR REPLACE FUNCTION public.exos_reschedule_qualifies(p_old timestamptz, p_new timestamptz, p_tz text)
RETURNS boolean
LANGUAGE plpgsql STABLE
SET search_path = public, pg_temp
AS $$
DECLARE v_tz text := coalesce(nullif(btrim(p_tz), ''), 'UTC');
BEGIN
  IF p_old IS NULL OR p_new IS NULL THEN RETURN false; END IF;
  BEGIN
    PERFORM now() AT TIME ZONE v_tz;
  EXCEPTION WHEN others THEN
    v_tz := 'UTC';
  END;
  RETURN (p_old AT TIME ZONE v_tz)::date <> (p_new AT TIME ZONE v_tz)::date
      OR abs(extract(epoch FROM (p_new - p_old))) > 3 * 3600;
END $$;
REVOKE ALL ON FUNCTION public.exos_reschedule_qualifies(timestamptz, timestamptz, text) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.exos_reschedule_qualifies(timestamptz, timestamptz, text) TO authenticated, service_role;

-- Earlier of change + 14 days and new start − 24 h; when that leaves no time
-- (the new start is less than a day away), until the new start; NULL when the
-- new start isn't in the future (nothing to offer).
CREATE OR REPLACE FUNCTION public.exos_reschedule_default_deadline(p_changed_at timestamptz, p_new_starts_at timestamptz)
RETURNS timestamptz
LANGUAGE sql IMMUTABLE
SET search_path = public, pg_temp
AS $$
  SELECT CASE
    WHEN p_changed_at IS NULL OR p_new_starts_at IS NULL THEN NULL
    WHEN least(p_changed_at + interval '14 days', p_new_starts_at - interval '24 hours') > p_changed_at
      THEN least(p_changed_at + interval '14 days', p_new_starts_at - interval '24 hours')
    WHEN p_new_starts_at > p_changed_at THEN p_new_starts_at
    ELSE NULL END
$$;
REVOKE ALL ON FUNCTION public.exos_reschedule_default_deadline(timestamptz, timestamptz) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.exos_reschedule_default_deadline(timestamptz, timestamptz) TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 5. One ticket against the event's latest reschedule. Internal: says what
--    the ticket may get (kind) and whether it can now (ok / reason), and who
--    may ask; the caller checks the actor. No client grant.
--
--    kind: refund      paid through an Exos checkout (Stripe), money back
--          release     free or comp: give the ticket back, no money
--          marketplace sold on a resale marketplace: refund there
--          none        paid some other way (box office, legacy): organizer
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._exos_resched_ticket_state(p_ticket_id uuid)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  t        public.exos_tickets%ROWTYPE;
  e        public.exos_events%ROWTYPE;
  r        public.exos_event_reschedules%ROWTYPE;
  s        public.exos_checkout_sessions%ROWTYPE;
  tr       public.exos_transfers%ROWTYPE;
  q        public.exos_refund_requests%ROWTYPE;
  st       record;
  v_owner  uuid;
  v_kind   text;
  v_parked boolean := false;
  v_pi     text;
  v_left   int := 0;
  v_rest   int := 0;
  v_amt    int := 0;
  v_share  int := 0;
  v_reason text;
  v_payer_email  text;
  v_holder_email text;
BEGIN
  SELECT * INTO t FROM public.exos_tickets WHERE id = p_ticket_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'not-found', 'ticket_id', p_ticket_id);
  END IF;
  SELECT * INTO e FROM public.exos_events WHERE id = t.event_id;
  SELECT * INTO r FROM public.exos_event_reschedules
   WHERE event_id = t.event_id ORDER BY created_at DESC, id DESC LIMIT 1;
  SELECT owner_uid INTO v_owner FROM public.exos_orgs WHERE id = t.org_id;

  -- What the ticket is.
  IF t.channel_source IN ('gotickets', 'gametime', 'stubhub', 'seatgeek', 'vivid', 'tickpick', 'evo', 'tevo', 'automatiq') THEN
    v_kind := 'marketplace';
  ELSE
    SELECT * INTO s FROM public.exos_checkout_sessions cs
     WHERE cs.session_id = t.order_ref AND cs.event_id = t.event_id;
    IF s.session_id IS NOT NULL AND s.amount_cents > 0 THEN
      v_kind := 'refund';
    ELSIF t.channel_source = 'comp' OR coalesce(t.price_paid, 0) = 0 THEN
      v_kind := 'release';
    ELSE
      v_kind := 'none';
    END IF;
  END IF;

  -- Who holds it. A ticket parked on staff for a pending claim (guest
  -- checkout, emailed comp) belongs to the person the claim is for.
  IF t.pending_transfer_id IS NOT NULL THEN
    SELECT * INTO tr FROM public.exos_transfers WHERE id = t.pending_transfer_id;
    v_parked := tr.status = 'pending'
      AND tr.sender_id IS NOT DISTINCT FROM t.owner_id
      AND coalesce(t.buyer_email, '') <> ''
      AND lower(btrim(coalesce(tr.receiver_email, ''))) = lower(btrim(t.buyer_email))
      AND (t.owner_id IS NOT DISTINCT FROM v_owner
           OR EXISTS (SELECT 1 FROM public.exos_org_memberships m
                       WHERE m.org_id = t.org_id AND m.user_id = t.owner_id
                         AND m.role IN ('owner', 'manager') AND m.disabled IS NOT TRUE));
  END IF;
  IF v_parked THEN
    v_holder_email := lower(btrim(tr.receiver_email));
  ELSE
    SELECT lower(email) INTO v_holder_email FROM auth.users WHERE id = t.owner_id;
  END IF;
  IF v_kind = 'refund' THEN
    v_payer_email := nullif(lower(btrim(coalesce(s.buyer_email, ''))), '');
    IF v_payer_email IS NULL AND s.buyer_uid IS NOT NULL THEN
      SELECT lower(email) INTO v_payer_email FROM auth.users WHERE id = s.buyer_uid;
    END IF;
  END IF;

  -- Can it be done now?
  IF r.id IS NULL THEN
    v_reason := 'no-reschedule';
  ELSIF NOT r.refunds_offered THEN
    v_reason := 'refunds-not-offered';
  ELSIF e.status = 'cancelled' THEN
    v_reason := 'event-cancelled';
  ELSIF r.refund_deadline IS NULL OR now() >= r.refund_deadline THEN
    v_reason := 'deadline-passed';
  ELSIF t.status = 'voided' THEN
    v_reason := 'voided';
  ELSIF t.status = 'used' OR t.check_in_at IS NOT NULL THEN
    v_reason := 'checked-in';
  ELSIF t.status <> 'active' THEN
    v_reason := 'not-active';
  ELSIF coalesce(s.created_at, t.created_at) > r.created_at THEN
    v_reason := 'bought-after-change';
  ELSIF v_kind = 'marketplace' THEN
    v_reason := 'marketplace';
  ELSIF v_kind = 'none' THEN
    v_reason := 'not-exos-paid';
  ELSIF t.pending_transfer_id IS NOT NULL AND NOT v_parked THEN
    v_reason := 'in-transfer';
  ELSIF v_kind = 'release' AND public.exos_tier_is_table(t.tier_id) THEN
    v_reason := 'table';
  END IF;

  IF v_kind = 'refund' THEN
    SELECT * INTO q FROM public.exos_refund_requests rq
     WHERE rq.reschedule_id = r.id
       AND EXISTS (SELECT 1 FROM public.exos_refund_request_items i WHERE i.request_id = rq.id AND i.ticket_id = t.id)
     ORDER BY rq.created_at DESC LIMIT 1;
    SELECT x.share_cents, x.allocated_cents INTO st
      FROM public.exos_refund_ticket_state(s.session_id) x WHERE x.ticket_id = t.id;
    v_share := greatest(coalesce(st.share_cents, 0) - coalesce(st.allocated_cents, 0), 0);
    v_left  := greatest(s.amount_cents - public.exos_refund_order_reserved(s.session_id), 0);
    SELECT coalesce(sum(greatest(x.share_cents - x.allocated_cents, 0)), 0)::int INTO v_rest
      FROM public.exos_refund_ticket_state(s.session_id) x WHERE x.ticket_id <> t.id;
    v_amt := CASE WHEN v_rest = 0 THEN v_left ELSE least(v_share, v_left) END;
    SELECT p.payment_intent INTO v_pi FROM public.exos_order_payments p
     WHERE p.session_id = s.session_id AND p.status = 'succeeded' AND p.payment_intent IS NOT NULL
     ORDER BY p.amount_cents DESC LIMIT 1;
    v_pi := coalesce(v_pi, s.payment_intent);
    IF v_reason IS NULL THEN
      IF q.status IN ('claimed', 'pending') THEN
        v_reason := 'in-progress';
      ELSIF q.status = 'succeeded' OR v_share <= 0 OR v_left <= 0 OR s.status NOT IN ('fulfilled', 'partially_refunded') THEN
        v_reason := 'refunded';
      ELSIF v_pi IS NULL THEN
        v_reason := 'no-card-payment';
      END IF;
    END IF;
  END IF;

  RETURN jsonb_build_object(
    'ok', v_reason IS NULL,
    'reason', v_reason,
    'kind', v_kind,
    'ticket_id', t.id,
    'event_id', t.event_id,
    'org_id', t.org_id,
    'tier_id', t.tier_id,
    'tier_name', t.tier_name,
    'reschedule_id', r.id,
    'refund_deadline', r.refund_deadline,
    'session_id', CASE WHEN v_kind = 'refund' THEN s.session_id END,
    'currency', lower(coalesce(s.currency, e.currency, 'usd')),
    'amount_cents', CASE WHEN v_kind = 'refund' THEN v_amt ELSE 0 END,
    'share_cents', CASE WHEN v_kind = 'refund' THEN least(v_share, v_amt) ELSE 0 END,
    'includes_addons', v_kind = 'refund' AND v_rest = 0 AND v_amt > v_share,
    'payment_intent', v_pi,
    'payer_uid', CASE WHEN v_kind = 'refund' THEN s.buyer_uid END,
    'payer_email', v_payer_email,
    'holder_uid', CASE WHEN v_parked THEN NULL ELSE t.owner_id END,
    'holder_email', v_holder_email,
    'parked', v_parked,
    'pending_transfer_id', t.pending_transfer_id,
    'request_id', q.id,
    'request_status', q.status);
END $$;
REVOKE ALL ON FUNCTION public._exos_resched_ticket_state(uuid) FROM PUBLIC, anon, authenticated;

-- May this signed-in account act on the ticket? A refund: only the payer
-- (the checkout's account, or an account with the buyer's confirmed email).
-- A release: the holder (or, for a parked ticket, the claim's confirmed email).
CREATE OR REPLACE FUNCTION public._exos_resched_actor_ok(p_state jsonb, p_actor uuid)
RETURNS boolean
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE v_email text;
BEGIN
  IF p_actor IS NULL OR p_state IS NULL THEN RETURN false; END IF;
  SELECT lower(email) INTO v_email FROM auth.users WHERE id = p_actor AND email_confirmed_at IS NOT NULL;
  IF p_state->>'kind' = 'refund' THEN
    RETURN p_actor::text = p_state->>'payer_uid'
        OR (p_state->>'payer_uid' IS NULL AND v_email IS NOT NULL AND v_email = p_state->>'payer_email');
  ELSIF p_state->>'kind' = 'release' THEN
    RETURN (NOT coalesce((p_state->>'parked')::boolean, false) AND p_actor::text = p_state->>'holder_uid')
        OR (coalesce((p_state->>'parked')::boolean, false) AND v_email IS NOT NULL AND v_email = p_state->>'holder_email');
  END IF;
  RETURN false;
END $$;
REVOKE ALL ON FUNCTION public._exos_resched_actor_ok(jsonb, uuid) FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 6. The notice: one 'event-rescheduled' mail per address per reschedule.
--    Holders get the new date; when refunds are offered, the payer of each
--    refundable ticket gets its refund link and the holder of each free
--    ticket its release link. Transactional (always sent).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._exos_reschedule_notify(p_reschedule_id uuid, p_actor uuid DEFAULT NULL)
RETURNS int
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  r       public.exos_event_reschedules%ROWTYPE;
  v_ev    jsonb;
  v_rows  jsonb;
  v_n     int := 0;
  x       record;
  m       record;
BEGIN
  SELECT * INTO r FROM public.exos_event_reschedules WHERE id = p_reschedule_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION '_exos_reschedule_notify: unknown reschedule';
  END IF;
  v_ev := public._exos_mail_event_json(r.event_id);

  SELECT coalesce(jsonb_agg(public._exos_resched_ticket_state(t.id) ORDER BY t.created_at, t.id), '[]'::jsonb)
    INTO v_rows
    FROM public.exos_tickets t
   WHERE t.event_id = r.event_id AND t.status <> 'voided';

  -- Links for what can be done (only while offered).
  IF r.refunds_offered THEN
    FOR x IN SELECT j FROM jsonb_array_elements(v_rows) j
              WHERE (j->>'ok')::boolean AND j->>'kind' IN ('refund', 'release') LOOP
      INSERT INTO public.exos_reschedule_links (token, reschedule_id, ticket_id, kind)
      VALUES (encode(extensions.gen_random_bytes(32), 'hex'), r.id, (x.j->>'ticket_id')::uuid, x.j->>'kind')
      ON CONFLICT (reschedule_id, ticket_id, kind) DO NOTHING;
    END LOOP;
  END IF;

  FOR m IN
    WITH st AS (
      SELECT j, l.token FROM jsonb_array_elements(v_rows) j
        LEFT JOIN public.exos_reschedule_links l
          ON r.refunds_offered AND (j->>'ok')::boolean
         AND l.reschedule_id = r.id AND l.ticket_id = (j->>'ticket_id')::uuid AND l.kind = j->>'kind'
    ), roles AS (
      -- the holder of every ticket
      SELECT j->>'holder_email' AS email, nullif(j->>'holder_uid', '')::uuid AS uid, 'hold' AS role, j, token
        FROM st WHERE coalesce(j->>'holder_email', '') <> ''
      UNION ALL
      -- the payer of every refundable ticket (may be the holder too)
      SELECT j->>'payer_email', nullif(j->>'payer_uid', '')::uuid, 'pay', j, token
        FROM st WHERE token IS NOT NULL AND j->>'kind' = 'refund' AND coalesce(j->>'payer_email', '') <> ''
    )
    SELECT email,
           (array_agg(uid) FILTER (WHERE uid IS NOT NULL))[1] AS uid,
           count(*) FILTER (WHERE role = 'hold') AS held,
           count(*) FILTER (WHERE role = 'hold' AND j->>'kind' = 'marketplace') AS marketplace,
           count(*) FILTER (WHERE role = 'hold' AND j->>'kind' = 'none') AS other_paid,
           count(*) FILTER (WHERE role = 'hold' AND j->>'kind' = 'refund'
                              AND coalesce(j->>'payer_email', '') <> email) AS not_buyer,
           count(*) FILTER (WHERE role = 'pay') AS n_refunds,
           count(*) FILTER (WHERE role = 'hold' AND token IS NOT NULL AND j->>'kind' = 'release') AS n_releases,
           coalesce(jsonb_agg(jsonb_build_object(
               'ticket_id', j->>'ticket_id', 'tier_name', j->>'tier_name', 'token', token,
               'amount_cents', (j->>'amount_cents')::int, 'currency', j->>'currency')
             ORDER BY j->>'ticket_id') FILTER (WHERE role = 'pay'), '[]'::jsonb) AS refunds,
           coalesce(jsonb_agg(jsonb_build_object(
               'ticket_id', j->>'ticket_id', 'tier_name', j->>'tier_name', 'token', token)
             ORDER BY j->>'ticket_id') FILTER (WHERE role = 'hold' AND token IS NOT NULL AND j->>'kind' = 'release'),
             '[]'::jsonb) AS releases
      FROM roles GROUP BY email ORDER BY email
  LOOP
    IF public.exos_mail_enqueue(
         'event-rescheduled', m.email,
         jsonb_build_object(
           'event', v_ev,
           'reschedule_id', r.id,
           'old_starts_at', r.old_starts_at,
           'new_starts_at', r.new_starts_at,
           'reason', r.reason,
           'refunds_offered', r.refunds_offered,
           'refund_deadline', r.refund_deadline,
           -- at most 40 links of each kind per mail (payload cap); the rest are on My Tickets
           'refunds',  (SELECT coalesce(jsonb_agg(v), '[]'::jsonb) FROM (SELECT v FROM jsonb_array_elements(m.refunds) v LIMIT 40) a),
           'releases', (SELECT coalesce(jsonb_agg(v), '[]'::jsonb) FROM (SELECT v FROM jsonb_array_elements(m.releases) v LIMIT 40) b),
           'more_links', greatest(m.n_refunds - 40, 0) + greatest(m.n_releases - 40, 0),
           'tickets', m.held,
           'marketplace', m.marketplace,
           'not_buyer', m.not_buyer,
           'other_paid', m.other_paid),
         'event-rescheduled:' || r.id || ':' || md5(m.email),
         m.uid, false, p_actor) IS NOT NULL THEN
      v_n := v_n + 1;
    END IF;
  END LOOP;
  RETURN v_n;
END $$;
REVOKE ALL ON FUNCTION public._exos_reschedule_notify(uuid, uuid) FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 7. exos_reschedule_event: move the event, record it, notify. Owner /
--    manager (or platform admin). p_offer_refunds NULL = no refunds (what an
--    old client that doesn't know the option gets); the SPA always passes it.
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.exos_reschedule_event(uuid, timestamptz, timestamptz, timestamptz, text, text);
CREATE OR REPLACE FUNCTION public.exos_reschedule_event(
  p_event_id        uuid,
  p_new_starts_at   timestamptz,
  p_new_doors_at    timestamptz DEFAULT NULL,
  p_new_ends_at     timestamptz DEFAULT NULL,
  p_occurs_at_local text        DEFAULT NULL,
  p_reason          text        DEFAULT NULL,
  p_offer_refunds   boolean     DEFAULT NULL,
  p_refund_deadline timestamptz DEFAULT NULL
) RETURNS TABLE (reschedule_id uuid, recipient_count int, refunds_offered boolean,
                 refund_deadline timestamptz, qualifying boolean)
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_uid      uuid := auth.uid();
  e          public.exos_events%ROWTYPE;
  v_reason   text;
  v_sold     boolean;
  v_qual     boolean;
  v_offer    boolean;
  v_deadline timestamptz;
  v_id       uuid;
  v_n        int := 0;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'exos_reschedule_event: not authenticated' USING ERRCODE = '42501';
  END IF;
  IF p_new_starts_at IS NULL THEN
    RAISE EXCEPTION 'exos_reschedule_event: new start time is required' USING ERRCODE = '22023';
  END IF;
  v_reason := btrim(coalesce(p_reason, ''));
  IF char_length(v_reason) > 500 THEN
    RAISE EXCEPTION 'exos_reschedule_event: reason too long (max 500)' USING ERRCODE = '22023';
  END IF;

  SELECT * INTO e FROM public.exos_events WHERE id = p_event_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'exos_reschedule_event: event not found' USING ERRCODE = 'P0002';
  END IF;
  IF NOT (exos_is_admin() OR exos_has_org_role(e.org_id, ARRAY['owner','manager'])) THEN
    RAISE EXCEPTION 'exos_reschedule_event: not authorized' USING ERRCODE = '42501';
  END IF;
  IF e.status = 'cancelled' THEN
    RAISE EXCEPTION 'exos_reschedule_event: the event is cancelled' USING ERRCODE = '22023';
  END IF;
  IF e.starts_at IS NOT DISTINCT FROM p_new_starts_at THEN
    RAISE EXCEPTION 'exos_reschedule_event: the start time didn''t change' USING ERRCODE = '22023';
  END IF;

  v_sold := EXISTS (SELECT 1 FROM public.exos_tickets t WHERE t.event_id = p_event_id AND t.status <> 'voided');
  v_qual := public.exos_reschedule_qualifies(e.starts_at, p_new_starts_at, e.timezone);
  v_offer := coalesce(p_offer_refunds, false) AND v_sold;
  IF v_offer THEN
    v_deadline := coalesce(p_refund_deadline, public.exos_reschedule_default_deadline(now(), p_new_starts_at));
    IF v_deadline IS NULL OR v_deadline <= now() THEN
      RAISE EXCEPTION 'exos_reschedule_event: the refund deadline must be in the future' USING ERRCODE = '22023';
    END IF;
    IF v_deadline > p_new_starts_at THEN
      RAISE EXCEPTION 'exos_reschedule_event: the refund deadline can''t be after the new start' USING ERRCODE = '22023';
    END IF;
  END IF;

  -- Our own date change: the client guard (exos_events_date_guard) lets it through.
  PERFORM set_config('exos.reschedule_ok', p_event_id::text, true);
  UPDATE public.exos_events
     SET starts_at       = p_new_starts_at,
         doors_at        = COALESCE(p_new_doors_at, doors_at),
         ends_at         = COALESCE(p_new_ends_at, ends_at),
         occurs_at_local = COALESCE(p_occurs_at_local, occurs_at_local),
         updated_at      = now()
   WHERE id = p_event_id;
  PERFORM set_config('exos.reschedule_ok', '', true);

  INSERT INTO public.exos_event_reschedules
    (event_id, org_id, old_starts_at, new_starts_at, reason, rescheduled_by,
     refunds_offered, refund_deadline, qualifying, created_at)
  VALUES (p_event_id, e.org_id, e.starts_at, p_new_starts_at, NULLIF(v_reason, ''), v_uid,
          v_offer, v_deadline, v_qual, clock_timestamp())   -- "latest" stays unambiguous
  RETURNING id INTO v_id;

  v_n := public._exos_reschedule_notify(v_id, v_uid);
  UPDATE public.exos_event_reschedules r
     SET recipient_count = v_n, notified_at = now()
   WHERE r.id = v_id;

  reschedule_id   := v_id;
  recipient_count := v_n;
  refunds_offered := v_offer;
  refund_deadline := v_deadline;
  qualifying      := v_qual;
  RETURN NEXT;
END $$;
REVOKE ALL ON FUNCTION public.exos_reschedule_event(uuid, timestamptz, timestamptz, timestamptz, text, text, boolean, timestamptz) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.exos_reschedule_event(uuid, timestamptz, timestamptz, timestamptz, text, text, boolean, timestamptz) TO authenticated;
COMMENT ON FUNCTION public.exos_reschedule_event(uuid, timestamptz, timestamptz, timestamptz, text, text, boolean, timestamptz) IS
  'Owner/manager (or admin) moves an event: updates timing, logs old→new (exos_event_reschedules) with the refund offer, and queues event-rescheduled to every holder (mig 20260929150000).';

-- ---------------------------------------------------------------------------
-- 8. Client guard: a signed-in client (the SPA's plain event save) can't make
--    a qualifying date change on an event with tickets; it has to go through
--    exos_reschedule_event, which records it and tells the holders. Staff
--    tools running as the service role, and every other column, are
--    unaffected.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.exos_tg_event_date_guard()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF NEW.starts_at IS DISTINCT FROM OLD.starts_at
     AND coalesce(current_setting('role', true), '') IN ('authenticated', 'anon')
     AND coalesce(current_setting('exos.reschedule_ok', true), '') <> NEW.id::text
     AND public.exos_reschedule_qualifies(OLD.starts_at, NEW.starts_at, coalesce(NEW.timezone, OLD.timezone))
     AND EXISTS (SELECT 1 FROM public.exos_tickets t WHERE t.event_id = NEW.id AND t.status <> 'voided') THEN
    RAISE EXCEPTION 'exos_events: this event has tickets, so a new date goes through exos_reschedule_event (holders are told and may be offered refunds)'
      USING ERRCODE = '42501';
  END IF;
  RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION public.exos_tg_event_date_guard() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS exos_events_date_guard ON public.exos_events;
CREATE TRIGGER exos_events_date_guard BEFORE UPDATE OF starts_at ON public.exos_events
  FOR EACH ROW EXECUTE FUNCTION public.exos_tg_event_date_guard();

-- ---------------------------------------------------------------------------
-- 9. Buyer refund claim (service role: exos-refund's 'reschedule_refund').
--    Signed in (p_actor, the verified JWT user) or with a mail link
--    (p_token): a token acts only on its own ticket. One result per ticket:
--      { ticket_id, ok: true, claim: {...exos_refund_claim shape} }
--      { ticket_id, ok: false, reason }
--    A repeat returns the same request ('existing': true), so the same
--    Stripe idempotency key. Claims lock the order row first, like
--    exos_refund_claim / exos_refund_finalize.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.exos_request_reschedule_refund(
  p_actor      uuid,
  p_ticket_ids uuid[] DEFAULT NULL,
  p_token      text   DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  l        public.exos_reschedule_links%ROWTYPE;
  q        public.exos_refund_requests%ROWTYPE;
  v_ids    uuid[];
  v_tid    uuid;
  v_ref    text;
  st       jsonb;
  v_tok_ok boolean;
  v_n      int;
  v_id     uuid;
  v_nonce  text;
  v_out    jsonb := '[]'::jsonb;
BEGIN
  IF current_user NOT IN ('service_role', 'postgres', 'supabase_admin') THEN
    RAISE EXCEPTION 'exos_request_reschedule_refund: service role only' USING ERRCODE = '42501';
  END IF;
  IF p_token IS NOT NULL THEN
    IF p_token !~ '^[0-9a-f]{64}$' THEN
      RAISE EXCEPTION 'exos_request_reschedule_refund: this refund link is not valid' USING ERRCODE = '42501';
    END IF;
    SELECT * INTO l FROM public.exos_reschedule_links WHERE token = p_token;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'exos_request_reschedule_refund: this refund link is not valid' USING ERRCODE = '42501';
    END IF;
  ELSIF p_actor IS NULL THEN
    RAISE EXCEPTION 'exos_request_reschedule_refund: not authenticated' USING ERRCODE = '42501';
  END IF;
  v_ids := CASE WHEN coalesce(cardinality(p_ticket_ids), 0) > 0 THEN p_ticket_ids
                WHEN p_token IS NOT NULL THEN ARRAY[l.ticket_id] END;
  IF v_ids IS NULL THEN
    RAISE EXCEPTION 'exos_request_reschedule_refund: say which tickets' USING ERRCODE = '22023';
  END IF;
  IF cardinality(v_ids) > 50 THEN
    RAISE EXCEPTION 'exos_request_reschedule_refund: at most 50 tickets at a time' USING ERRCODE = '22023';
  END IF;

  FOREACH v_tid IN ARRAY (SELECT array_agg(DISTINCT x) FROM unnest(v_ids) x) LOOP
    SELECT order_ref INTO v_ref FROM public.exos_tickets WHERE id = v_tid;
    -- Same lock order as exos_refund_claim / finalize: the order, then the rest.
    PERFORM 1 FROM public.exos_checkout_sessions WHERE session_id = v_ref FOR UPDATE;
    PERFORM 1 FROM public.exos_tickets WHERE id = v_tid FOR UPDATE;
    st := public._exos_resched_ticket_state(v_tid);

    v_tok_ok := p_token IS NOT NULL AND l.ticket_id = v_tid AND l.kind = 'refund'
                AND l.reschedule_id IS NOT DISTINCT FROM (st->>'reschedule_id')::uuid;
    IF NOT (v_tok_ok OR (p_token IS NULL AND public._exos_resched_actor_ok(st, p_actor))) THEN
      v_out := v_out || jsonb_build_object('ticket_id', v_tid, 'ok', false,
        'reason', CASE WHEN p_token IS NOT NULL AND l.ticket_id = v_tid AND st->>'reschedule_id' IS DISTINCT FROM l.reschedule_id::text
                       THEN 'link-superseded' ELSE 'not-authorized' END);
      CONTINUE;
    END IF;

    -- Double click / retry / concurrent request: hand back the live request.
    IF st->>'request_status' IN ('claimed', 'pending', 'succeeded') THEN
      SELECT * INTO q FROM public.exos_refund_requests WHERE id = (st->>'request_id')::uuid;
      v_out := v_out || jsonb_build_object('ticket_id', v_tid, 'ok', true, 'claim', jsonb_build_object(
        'request_id', q.id, 'session_id', q.session_id, 'amount_cents', q.amount_cents, 'currency', q.currency,
        'payment_intent', q.payment_intent, 'idempotency_key', 'exos_refund_' || q.id,
        'status', q.status, 'stripe_refund_id', q.stripe_refund_id, 'scope', q.scope, 'existing', true,
        'reschedule_id', q.reschedule_id, 'ticket_id', v_tid));
      CONTINUE;
    END IF;
    IF NOT (st->>'ok')::boolean THEN
      v_out := v_out || jsonb_build_object('ticket_id', v_tid, 'ok', false, 'reason', st->>'reason');
      CONTINUE;
    END IF;
    IF st->>'kind' <> 'refund' THEN
      v_out := v_out || jsonb_build_object('ticket_id', v_tid, 'ok', false, 'reason', 'not-refundable');
      CONTINUE;
    END IF;

    -- A new attempt after a failed / cancelled one gets its own nonce (and so key).
    SELECT count(*) INTO v_n FROM public.exos_refund_requests rq
     WHERE rq.reschedule_id = (st->>'reschedule_id')::uuid
       AND EXISTS (SELECT 1 FROM public.exos_refund_request_items i WHERE i.request_id = rq.id AND i.ticket_id = v_tid);
    v_nonce := 'rsr:' || (st->>'reschedule_id') || ':' || v_tid || CASE WHEN v_n > 0 THEN ':' || (v_n + 1) ELSE '' END;

    INSERT INTO public.exos_refund_requests (
      session_id, org_id, event_id, requested_by, scope, amount_cents, currency,
      reason, nonce, status, payment_intent, reschedule_id
    ) VALUES (
      st->>'session_id', (st->>'org_id')::uuid, (st->>'event_id')::uuid,
      CASE WHEN v_tok_ok THEN NULL ELSE p_actor END, 'reschedule', (st->>'amount_cents')::int, st->>'currency',
      'event date changed', v_nonce, 'claimed', st->>'payment_intent', (st->>'reschedule_id')::uuid
    ) RETURNING id INTO v_id;
    INSERT INTO public.exos_refund_request_items (request_id, ticket_id, amount_cents, covers_full)
    VALUES (v_id, v_tid, (st->>'share_cents')::int, true);

    v_out := v_out || jsonb_build_object('ticket_id', v_tid, 'ok', true, 'claim', jsonb_build_object(
      'request_id', v_id, 'session_id', st->>'session_id', 'amount_cents', (st->>'amount_cents')::int,
      'currency', st->>'currency', 'payment_intent', st->>'payment_intent',
      'idempotency_key', 'exos_refund_' || v_id, 'status', 'claimed', 'stripe_refund_id', NULL,
      'scope', 'reschedule', 'existing', false, 'reschedule_id', st->>'reschedule_id', 'ticket_id', v_tid));
  END LOOP;
  RETURN jsonb_build_object('results', v_out);
END $$;
REVOKE ALL ON FUNCTION public.exos_request_reschedule_refund(uuid, uuid[], text) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.exos_request_reschedule_refund(uuid, uuid[], text) TO service_role;

-- ---------------------------------------------------------------------------
-- 10. Release a free / comp ticket (void, no money). Signed in: the holder
--     (exos_reschedule_release_mine). By mail link: exos-refund calls the
--     service-role wrapper with the token.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._exos_reschedule_release(p_actor uuid, p_ticket_ids uuid[], p_token text)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  l        public.exos_reschedule_links%ROWTYPE;
  t        public.exos_tickets%ROWTYPE;
  v_ids    uuid[];
  v_tid    uuid;
  st       jsonb;
  v_tok_ok boolean;
  v_out    jsonb := '[]'::jsonb;
BEGIN
  IF p_token IS NOT NULL THEN
    IF p_token !~ '^[0-9a-f]{64}$' THEN
      RAISE EXCEPTION 'exos_reschedule_release: this link is not valid' USING ERRCODE = '42501';
    END IF;
    SELECT * INTO l FROM public.exos_reschedule_links WHERE token = p_token;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'exos_reschedule_release: this link is not valid' USING ERRCODE = '42501';
    END IF;
  ELSIF p_actor IS NULL THEN
    RAISE EXCEPTION 'exos_reschedule_release: not authenticated' USING ERRCODE = '42501';
  END IF;
  v_ids := CASE WHEN coalesce(cardinality(p_ticket_ids), 0) > 0 THEN p_ticket_ids
                WHEN p_token IS NOT NULL THEN ARRAY[l.ticket_id] END;
  IF v_ids IS NULL THEN
    RAISE EXCEPTION 'exos_reschedule_release: say which tickets' USING ERRCODE = '22023';
  END IF;
  IF cardinality(v_ids) > 50 THEN
    RAISE EXCEPTION 'exos_reschedule_release: at most 50 tickets at a time' USING ERRCODE = '22023';
  END IF;

  FOREACH v_tid IN ARRAY (SELECT array_agg(DISTINCT x) FROM unnest(v_ids) x) LOOP
    SELECT * INTO t FROM public.exos_tickets WHERE id = v_tid FOR UPDATE;
    st := public._exos_resched_ticket_state(v_tid);
    v_tok_ok := p_token IS NOT NULL AND l.ticket_id = v_tid AND l.kind = 'release'
                AND l.reschedule_id IS NOT DISTINCT FROM (st->>'reschedule_id')::uuid;
    -- Already released through this reschedule (a repeat, a double click): done.
    IF EXISTS (SELECT 1 FROM public.exos_reschedule_releases x
                WHERE x.ticket_id = v_tid AND x.reschedule_id = (st->>'reschedule_id')::uuid
                  AND ((p_token IS NOT NULL AND l.ticket_id = v_tid AND l.kind = 'release')
                       OR (p_token IS NULL AND x.released_by = p_actor))) THEN
      v_out := v_out || jsonb_build_object('ticket_id', v_tid, 'ok', true, 'existing', true);
      CONTINUE;
    END IF;
    IF NOT (v_tok_ok OR (p_token IS NULL AND public._exos_resched_actor_ok(st, p_actor))) THEN
      v_out := v_out || jsonb_build_object('ticket_id', v_tid, 'ok', false, 'reason', 'not-authorized');
      CONTINUE;
    END IF;
    IF NOT (st->>'ok')::boolean THEN
      v_out := v_out || jsonb_build_object('ticket_id', v_tid, 'ok', false, 'reason', st->>'reason');
      CONTINUE;
    END IF;
    IF st->>'kind' <> 'release' THEN
      v_out := v_out || jsonb_build_object('ticket_id', v_tid, 'ok', false,
        'reason', CASE WHEN st->>'kind' = 'refund' THEN 'paid-ticket' ELSE st->>'kind' END);
      CONTINUE;
    END IF;

    UPDATE public.exos_tickets
       SET status = 'voided', released_at = now(), voided_at = now(),
           voided_by = CASE WHEN v_tok_ok THEN NULL ELSE p_actor END,
           voided_reason = 'released: event date changed',
           pending_transfer_id = NULL
     WHERE id = v_tid;
    IF t.pending_transfer_id IS NOT NULL THEN
      UPDATE public.exos_transfers SET status = 'cancelled' WHERE id = t.pending_transfer_id AND status = 'pending';
    END IF;
    IF t.tier_id IS NOT NULL THEN
      UPDATE public.exos_ticket_tiers SET sold = sold - 1 WHERE id = t.tier_id AND sold > 0;
    END IF;
    UPDATE public.exos_events SET tickets_sold = tickets_sold - 1 WHERE id = t.event_id AND tickets_sold > 0;
    INSERT INTO public.exos_reschedule_releases (reschedule_id, ticket_id, released_by, via)
    VALUES ((st->>'reschedule_id')::uuid, v_tid, CASE WHEN v_tok_ok THEN NULL ELSE p_actor END,
            CASE WHEN v_tok_ok THEN 'link' ELSE 'account' END)
    ON CONFLICT DO NOTHING;
    v_out := v_out || jsonb_build_object('ticket_id', v_tid, 'ok', true, 'existing', false);
  END LOOP;
  RETURN jsonb_build_object('results', v_out);
END $$;
REVOKE ALL ON FUNCTION public._exos_reschedule_release(uuid, uuid[], text) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.exos_reschedule_release_mine(p_ticket_ids uuid[])
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'exos_reschedule_release_mine: not authenticated' USING ERRCODE = '42501';
  END IF;
  RETURN public._exos_reschedule_release(auth.uid(), p_ticket_ids, NULL);
END $$;
REVOKE ALL ON FUNCTION public.exos_reschedule_release_mine(uuid[]) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.exos_reschedule_release_mine(uuid[]) TO authenticated;

CREATE OR REPLACE FUNCTION public.exos_reschedule_release_svc(p_actor uuid, p_ticket_ids uuid[] DEFAULT NULL, p_token text DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF current_user NOT IN ('service_role', 'postgres', 'supabase_admin') THEN
    RAISE EXCEPTION 'exos_reschedule_release_svc: service role only' USING ERRCODE = '42501';
  END IF;
  RETURN public._exos_reschedule_release(p_actor, p_ticket_ids, p_token);
END $$;
REVOKE ALL ON FUNCTION public.exos_reschedule_release_svc(uuid, uuid[], text) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.exos_reschedule_release_svc(uuid, uuid[], text) TO service_role;

-- ---------------------------------------------------------------------------
-- 11. What a mail link is for (service role; the /refund page through
--     exos-refund). No emails in the answer.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.exos_reschedule_link_info(p_token text)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  l  public.exos_reschedule_links%ROWTYPE;
  r  public.exos_event_reschedules%ROWTYPE;
  st jsonb;
BEGIN
  IF current_user NOT IN ('service_role', 'postgres', 'supabase_admin') THEN
    RAISE EXCEPTION 'exos_reschedule_link_info: service role only' USING ERRCODE = '42501';
  END IF;
  IF p_token IS NULL OR p_token !~ '^[0-9a-f]{64}$' THEN RETURN NULL; END IF;
  SELECT * INTO l FROM public.exos_reschedule_links WHERE token = p_token;
  IF NOT FOUND THEN RETURN NULL; END IF;
  SELECT * INTO r FROM public.exos_event_reschedules WHERE id = l.reschedule_id;
  st := public._exos_resched_ticket_state(l.ticket_id);
  RETURN jsonb_build_object(
    'kind', l.kind,
    'ticket_id', l.ticket_id,
    'tier_name', st->>'tier_name',
    'ok', (st->>'ok')::boolean AND st->>'kind' = l.kind AND st->>'reschedule_id' = l.reschedule_id::text,
    'reason', CASE WHEN st->>'reschedule_id' IS DISTINCT FROM l.reschedule_id::text THEN 'link-superseded'
                   WHEN st->>'kind' <> l.kind AND (st->>'ok')::boolean THEN 'not-refundable'
                   ELSE st->>'reason' END,
    'request_status', st->>'request_status',
    'amount_cents', (st->>'amount_cents')::int,
    'currency', st->>'currency',
    'refund_deadline', r.refund_deadline,
    'old_starts_at', r.old_starts_at,
    'new_starts_at', r.new_starts_at,
    'event', public._exos_mail_event_json(r.event_id));
END $$;
REVOKE ALL ON FUNCTION public.exos_reschedule_link_info(text) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.exos_reschedule_link_info(text) TO service_role;

-- ---------------------------------------------------------------------------
-- 12. My Tickets: tickets the signed-in account holds or paid for, on events
--     whose latest reschedule offers refunds and is still open.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.exos_my_reschedule_offers()
RETURNS TABLE (ticket_id uuid, event_id uuid, event_name text, timezone text, tier_name text,
               kind text, ok boolean, reason text, amount_cents int, currency text,
               refund_deadline timestamptz, old_starts_at timestamptz, new_starts_at timestamptz,
               request_status text, mine boolean)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_uid   uuid := auth.uid();
  v_email text;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'exos_my_reschedule_offers: not authenticated' USING ERRCODE = '42501';
  END IF;
  SELECT lower(u.email) INTO v_email FROM auth.users u WHERE u.id = v_uid AND u.email_confirmed_at IS NOT NULL;
  RETURN QUERY
  WITH open_r AS (
    SELECT DISTINCT ON (r.event_id) r.*
      FROM public.exos_event_reschedules r
     ORDER BY r.event_id, r.created_at DESC, r.id DESC
  ), cand AS (
    SELECT t.id, o.old_starts_at AS o_old, o.new_starts_at AS o_new, o.refund_deadline AS o_deadline
      FROM open_r o
      JOIN public.exos_tickets t ON t.event_id = o.event_id
     WHERE o.refunds_offered AND o.refund_deadline > now()
       AND t.status <> 'voided'
       AND (t.owner_id = v_uid
            OR EXISTS (SELECT 1 FROM public.exos_checkout_sessions s
                        WHERE s.session_id = t.order_ref
                          AND (s.buyer_uid = v_uid
                               OR (s.buyer_uid IS NULL AND v_email IS NOT NULL AND lower(s.buyer_email) = v_email))))
     LIMIT 500
  ), st AS (
    SELECT c.*, public._exos_resched_ticket_state(c.id) AS j FROM cand c
  )
  SELECT st.id, (st.j->>'event_id')::uuid, e.name, e.timezone, st.j->>'tier_name',
         st.j->>'kind',
         (st.j->>'ok')::boolean AND public._exos_resched_actor_ok(st.j, v_uid),
         CASE WHEN NOT (st.j->>'ok')::boolean THEN st.j->>'reason'
              WHEN NOT public._exos_resched_actor_ok(st.j, v_uid)
                THEN CASE WHEN st.j->>'kind' = 'refund' THEN 'not-buyer' ELSE 'not-holder' END
         END,
         (st.j->>'amount_cents')::int, st.j->>'currency',
         st.o_deadline, st.o_old, st.o_new, st.j->>'request_status',
         coalesce((st.j->>'holder_uid') = v_uid::text
                  OR (coalesce((st.j->>'parked')::boolean, false) AND v_email IS NOT NULL
                      AND st.j->>'holder_email' = v_email), false)
    FROM st JOIN public.exos_events e ON e.id = (st.j->>'event_id')::uuid
   ORDER BY e.starts_at, st.id;
END $$;
REVOKE ALL ON FUNCTION public.exos_my_reschedule_offers() FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.exos_my_reschedule_offers() TO authenticated;

-- ---------------------------------------------------------------------------
-- 13. Organizer view: the event's reschedules, and for the latest one what
--     buyers did with the offer. Owner / manager / finance (or admin).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.exos_event_reschedule_summary(p_event_id uuid)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_org    uuid;
  v_latest public.exos_event_reschedules%ROWTYPE;
  v_stats  jsonb;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'exos_event_reschedule_summary: not authenticated' USING ERRCODE = '42501';
  END IF;
  SELECT org_id INTO v_org FROM public.exos_events WHERE id = p_event_id;
  IF v_org IS NULL OR NOT (exos_is_admin() OR exos_has_org_role(v_org, ARRAY['owner','manager','finance'])) THEN
    RAISE EXCEPTION 'exos_event_reschedule_summary: not authorized' USING ERRCODE = '42501';
  END IF;
  SELECT * INTO v_latest FROM public.exos_event_reschedules
   WHERE event_id = p_event_id ORDER BY created_at DESC, id DESC LIMIT 1;
  IF v_latest.id IS NOT NULL THEN
    SELECT jsonb_build_object(
             'reschedule_id', v_latest.id,
             'refunds_offered', v_latest.refunds_offered,
             'refund_deadline', v_latest.refund_deadline,
             'open', v_latest.refunds_offered AND v_latest.refund_deadline > now(),
             'refunds_requested', (SELECT count(*) FROM public.exos_refund_requests q
                                    WHERE q.reschedule_id = v_latest.id AND q.status IN ('claimed', 'pending', 'succeeded')),
             'refunds_succeeded', (SELECT count(*) FROM public.exos_refund_requests q
                                    WHERE q.reschedule_id = v_latest.id AND q.status = 'succeeded'),
             'refunded_cents', (SELECT coalesce(sum(q.amount_cents), 0) FROM public.exos_refund_requests q
                                 WHERE q.reschedule_id = v_latest.id AND q.status = 'succeeded'),
             'in_flight_cents', (SELECT coalesce(sum(q.amount_cents), 0) FROM public.exos_refund_requests q
                                  WHERE q.reschedule_id = v_latest.id AND q.status IN ('claimed', 'pending')),
             'released', (SELECT count(*) FROM public.exos_reschedule_releases x WHERE x.reschedule_id = v_latest.id),
             'remaining_eligible', CASE WHEN v_latest.refunds_offered AND v_latest.refund_deadline > now() THEN
               (SELECT count(*) FROM public.exos_tickets t
                 WHERE t.event_id = p_event_id AND t.status = 'active'
                   AND (public._exos_resched_ticket_state(t.id)->>'ok')::boolean) ELSE 0 END,
             'currency', (SELECT lower(coalesce(e.currency, 'usd')) FROM public.exos_events e WHERE e.id = p_event_id))
      INTO v_stats;
  END IF;
  RETURN jsonb_build_object(
    'latest', v_stats,
    'reschedules', coalesce((
      SELECT jsonb_agg(jsonb_build_object(
               'id', r.id, 'old_starts_at', r.old_starts_at, 'new_starts_at', r.new_starts_at,
               'reason', r.reason, 'refunds_offered', r.refunds_offered, 'refund_deadline', r.refund_deadline,
               'qualifying', r.qualifying, 'recipient_count', r.recipient_count,
               'notified_at', r.notified_at, 'created_at', r.created_at) ORDER BY r.created_at DESC, r.id DESC)
        FROM public.exos_event_reschedules r WHERE r.event_id = p_event_id), '[]'::jsonb));
END $$;
REVOKE ALL ON FUNCTION public.exos_event_reschedule_summary(uuid) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.exos_event_reschedule_summary(uuid) TO authenticated;
