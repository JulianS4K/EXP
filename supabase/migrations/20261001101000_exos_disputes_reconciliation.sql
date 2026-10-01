-- ============================================================================
-- Migration 20261001101000 — Exos (Bridge / D4): dispute records + organizer
--                            alerts, and the daily Stripe reconciliation
--
-- Lane:     d4 (exos / bridge ticketing infra)
-- Touches:  W: TABLE exos_disputes (new; owner / manager / finance read)
--              TABLE exos_stripe_balance_txns (new; service role only)
--              TABLE exos_reconciliation_issues (new; admin + org owner /
--                finance read)
--              TABLE exos_reconciliation_runs (new; service role only)
--              TABLE exos_org_billing (+recover_lost_disputes, default false)
--              TABLE exos_mail (template allowlist + dispute-opened,
--                dispute-won, dispute-lost)
--              FUNCTION exos_record_dispute_event (new, service role): wraps
--                exos_record_dispute (unchanged, so the session dispute_*
--                columns and payment meta keep working) and upserts the
--                dispute row + queues the organizer mail
--              FUNCTION exos_reconcile_stripe_record (new, service role)
--              FUNCTION exos_reconciliation_issues_for (new, authenticated:
--                platform admin, or org owner / finance for their org)
--              FUNCTION _exos_dispute_raw, _exos_jscalar,
--                _exos_queue_dispute_mail (new, internal)
--           R: exos_checkout_sessions, exos_orgs, exos_org_memberships,
--              exos_org_billing, exos_mail_enqueue, exos_org_mail_recipients,
--              _exos_mail_event_json (mig 20260929071000), exos_has_org_role,
--              exos_is_admin
-- Pre-reqs: 20260925020000 (exos_record_dispute, session dispute_* columns),
--           20260929062000 (exos_org_billing), 20260929070000 (payout
--           ledger), 20260929071000 (mail templates, exos_mail_enqueue),
--           20260929131000 (exos_order_payments fee columns).
--
-- A. Disputes (money audit B13, section 4 item #7). stripe-webhook recorded a
--    chargeback only on the session (dispute_* columns) and the payment's
--    meta; nobody was told, and the fee and deadline weren't kept.
--      * exos_disputes: one row per Stripe dispute (dispute_id unique):
--        session, org, event, PaymentIntent, charge, amount, Stripe's dispute
--        fee (from the dispute's balance transactions), currency, reason,
--        status, evidence deadline, evidence submitted, opened / closed
--        times, and `raw`: an allowlisted copy of the Stripe object with the
--        `evidence` block (buyer name, email, IP, addresses, files) and
--        metadata removed (_exos_dispute_raw; the webhook strips it too).
--      * exos_record_dispute_event(...): what stripe-webhook now calls for
--        charge.dispute.created / .updated / .closed. It runs
--        exos_record_dispute first (same session columns, same finality and
--        return value, so the webhook's "void the order on lost" keeps its
--        exact behavior), then upserts the row. A closed status (won / lost /
--        warning_closed) is final on the row too: a replayed or late earlier
--        event can't reopen it. Replays change nothing.
--      * Mail to the org's owner + active finance members
--        (exos_org_mail_recipients(org, {finance})), transactional:
--        dispute-opened (amount, reason, evidence deadline, a link to the
--        dispute in the Stripe dashboard and to the event's Money section),
--        dispute-lost, dispute-won. Each is once per dispute and person
--        (dedupe key template:dispute_id:user_id), however many events
--        Stripe sends. No buyer data and no order reference in the mail
--        (docs/email.md rule); the event's Money section lists the order.
--        A mail failure is logged (WARNING) and never fails the webhook.
--      * Recovery policy: exos_org_billing.recover_lost_disputes (default
--        false; server-written like the rest of the row). On a lost dispute
--        the row records recovery_candidate_cents = amount + dispute fee and
--        recovery_status 'recovery_pending' (policy on) or 'not_recovered'
--        (policy off). Nothing moves money: reversing the organizer's
--        transfer (transfers.createReversal) is a Stripe write that needs
--        operator sign-off and is NOT built. The payout ledger's clawback
--        line (exos_org_payout_lines) is keyed to a marketplace order
--        (order_id NOT NULL REFERENCES exos_marketplace_orders), so a
--        checkout dispute can't be a line there; the candidate is reported
--        on the dispute row and in the UI only.
--
-- B. Daily Stripe reconciliation (section 4 item #6). exos-reconcile-stripe
--    (cron secret, read-only at Stripe) lists the platform account's
--    balance transactions for the last N days, stores them in
--    exos_stripe_balance_txns (service role only; upsert on the txn id, so
--    a re-run is a no-op), diffs them against exos_order_payments /
--    exos_order_refunds / exos_disputes (supabase/functions/_shared/
--    reconcile.ts) and hands the findings to exos_reconcile_stripe_record:
--      * exos_reconciliation_issues: one row per (kind, key); first_seen,
--        last_seen, seen_days (counted once per run day), resolved_at.
--        Found again -> reopened; an open issue inside the checked window
--        that wasn't found -> resolved.
--      * exos_reconciliation_runs: one row per run day (a second run the
--        same day overwrites it).
--      * Reading: platform admins see everything; org owner / finance see
--        issues on their org's sessions (RLS, and the RPC
--        exos_reconciliation_issues_for). Issues Exos can't tie to an org
--        (a Stripe charge with no Exos row) are admin only.
--
-- Cron: nothing is scheduled. docs/payouts.md has the daily line.
-- Re-run safe (IF NOT EXISTS, CREATE OR REPLACE, guarded constraints,
-- allowlist union). D4 authors; applying to prod is operator-gated. NOT
-- applied.
-- ROLLBACK: DROP FUNCTION exos_record_dispute_event(text,text,text,text,
--   integer,text,text,text,integer,text,timestamptz,boolean,boolean,jsonb),
--   exos_reconcile_stripe_record(date,timestamptz,timestamptz,jsonb,jsonb),
--   exos_reconciliation_issues_for(uuid,boolean,integer),
--   _exos_queue_dispute_mail(uuid,text), _exos_dispute_raw(jsonb),
--   _exos_jscalar(jsonb); DROP TABLE exos_disputes, exos_stripe_balance_txns,
--   exos_reconciliation_issues, exos_reconciliation_runs; ALTER TABLE
--   exos_org_billing DROP COLUMN recover_lost_disputes. (Redeploy the
--   previous stripe-webhook first: it calls exos_record_dispute directly.)
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. Recovery policy switch (per org; default off).
-- ---------------------------------------------------------------------------
ALTER TABLE public.exos_org_billing
  ADD COLUMN IF NOT EXISTS recover_lost_disputes boolean NOT NULL DEFAULT false;
COMMENT ON COLUMN public.exos_org_billing.recover_lost_disputes IS
  'Lost chargebacks: true = recover amount + dispute fee from the organizer (a later payout job would reverse the transfer; NOT built, needs operator sign-off). false = the platform absorbs it. mig 20261001101000.';

-- ---------------------------------------------------------------------------
-- 2. Disputes.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.exos_disputes (
  id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id             uuid NOT NULL REFERENCES public.exos_orgs (id) ON DELETE CASCADE,
  event_id           uuid REFERENCES public.exos_events (id) ON DELETE SET NULL,
  session_id         text REFERENCES public.exos_checkout_sessions (session_id) ON DELETE SET NULL,
  payment_intent     text,
  charge_id          text,
  dispute_id         text NOT NULL,
  amount_cents       int,
  fee_cents          int,
  currency           text NOT NULL DEFAULT 'usd',
  reason             text,
  status             text NOT NULL,
  evidence_due_by    timestamptz,
  evidence_submitted boolean NOT NULL DEFAULT false,
  livemode           boolean,
  created_at         timestamptz NOT NULL DEFAULT now(),
  updated_at         timestamptz NOT NULL DEFAULT now(),
  closed_at          timestamptz,
  last_event_id      text,
  recovery_status    text NOT NULL DEFAULT 'none',
  recovery_candidate_cents int,
  raw                jsonb
);
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'public.exos_disputes'::regclass AND conname = 'exos_disputes_dispute_id_key') THEN
    ALTER TABLE public.exos_disputes ADD CONSTRAINT exos_disputes_dispute_id_key UNIQUE (dispute_id);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'public.exos_disputes'::regclass AND conname = 'exos_disputes_ids_chk') THEN
    ALTER TABLE public.exos_disputes ADD CONSTRAINT exos_disputes_ids_chk CHECK (
      dispute_id ~ '^[a-z]{2,5}_[A-Za-z0-9]{1,200}$'
      AND (charge_id IS NULL OR charge_id ~ '^[a-z]{2,5}_[A-Za-z0-9]{1,200}$')
      AND (payment_intent IS NULL OR payment_intent ~ '^[a-z]{2,5}_[A-Za-z0-9]{1,200}$'));
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'public.exos_disputes'::regclass AND conname = 'exos_disputes_values_chk') THEN
    ALTER TABLE public.exos_disputes ADD CONSTRAINT exos_disputes_values_chk CHECK (
      status ~ '^[a-z_]{1,40}$'
      AND (amount_cents IS NULL OR amount_cents >= 0)
      AND (fee_cents IS NULL OR fee_cents >= 0)
      AND currency ~ '^[a-z]{3}$'
      AND (reason IS NULL OR char_length(reason) <= 60)
      AND recovery_status IN ('none', 'not_recovered', 'recovery_pending', 'recovered')
      AND (raw IS NULL OR (jsonb_typeof(raw) = 'object' AND octet_length(raw::text) <= 8000)));
  END IF;
END $$;
CREATE INDEX IF NOT EXISTS exos_disputes_org_idx     ON public.exos_disputes (org_id, created_at DESC);
CREATE INDEX IF NOT EXISTS exos_disputes_event_idx   ON public.exos_disputes (event_id);
CREATE INDEX IF NOT EXISTS exos_disputes_session_idx ON public.exos_disputes (session_id);

ALTER TABLE public.exos_disputes ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.exos_disputes FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.exos_disputes TO authenticated;
GRANT ALL ON public.exos_disputes TO service_role;
DROP POLICY IF EXISTS exos_disputes_sel ON public.exos_disputes;
CREATE POLICY exos_disputes_sel ON public.exos_disputes FOR SELECT TO authenticated
  USING (public.exos_is_admin() OR public.exos_has_org_role(org_id, ARRAY['owner','manager','finance']));
COMMENT ON TABLE public.exos_disputes IS
  'One row per Stripe dispute (chargeback) on an Exos checkout. Written only by exos_record_dispute_event (stripe-webhook); owner / manager / finance read. raw has no evidence / buyer data. mig 20261001101000.';

-- Scalar JSON value or NULL (keeps objects / arrays out of the allowlisted raw).
CREATE OR REPLACE FUNCTION public._exos_jscalar(p jsonb)
RETURNS jsonb LANGUAGE sql IMMUTABLE
SET search_path = public, pg_temp
AS $$
  SELECT CASE WHEN jsonb_typeof(p) = 'string' THEN to_jsonb(left(p #>> '{}', 100))
              WHEN jsonb_typeof(p) IN ('number', 'boolean') THEN p END
$$;
REVOKE ALL ON FUNCTION public._exos_jscalar(jsonb) FROM PUBLIC, anon, authenticated;

-- The allowlisted part of a Stripe Dispute. Same list as
-- supabase/functions/_shared/disputes.ts; anything else (evidence, metadata,
-- an expanded charge with billing details) is dropped.
CREATE OR REPLACE FUNCTION public._exos_dispute_raw(p jsonb)
RETURNS jsonb LANGUAGE sql IMMUTABLE
SET search_path = public, pg_temp
AS $$
  SELECT CASE WHEN jsonb_typeof(p) = 'object' THEN jsonb_strip_nulls(jsonb_build_object(
    'id', public._exos_jscalar(p -> 'id'),
    'object', 'dispute',
    'amount', public._exos_jscalar(p -> 'amount'),
    'currency', public._exos_jscalar(p -> 'currency'),
    'reason', public._exos_jscalar(p -> 'reason'),
    'status', public._exos_jscalar(p -> 'status'),
    'created', public._exos_jscalar(p -> 'created'),
    'livemode', public._exos_jscalar(p -> 'livemode'),
    'is_charge_refundable', public._exos_jscalar(p -> 'is_charge_refundable'),
    'network_reason_code', public._exos_jscalar(p -> 'network_reason_code'),
    'charge', public._exos_jscalar(p -> 'charge'),
    'payment_intent', public._exos_jscalar(p -> 'payment_intent'),
    'payment_method_type', public._exos_jscalar(p -> 'payment_method_type'),
    'card_brand', public._exos_jscalar(p -> 'card_brand'),
    'evidence_details', CASE WHEN jsonb_typeof(p -> 'evidence_details') = 'object' THEN jsonb_strip_nulls(jsonb_build_object(
        'due_by', public._exos_jscalar(p -> 'evidence_details' -> 'due_by'),
        'has_evidence', public._exos_jscalar(p -> 'evidence_details' -> 'has_evidence'),
        'past_due', public._exos_jscalar(p -> 'evidence_details' -> 'past_due'),
        'submission_count', public._exos_jscalar(p -> 'evidence_details' -> 'submission_count'))) END,
    'balance_transactions', (
      SELECT jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
               'id', public._exos_jscalar(b -> 'id'), 'amount', public._exos_jscalar(b -> 'amount'),
               'fee', public._exos_jscalar(b -> 'fee'), 'net', public._exos_jscalar(b -> 'net'),
               'type', public._exos_jscalar(b -> 'type'),
               'reporting_category', public._exos_jscalar(b -> 'reporting_category'),
               'created', public._exos_jscalar(b -> 'created'))))
        FROM (SELECT b FROM jsonb_array_elements(CASE WHEN jsonb_typeof(p -> 'balance_transactions') = 'array'
                                                      THEN p -> 'balance_transactions' ELSE '[]'::jsonb END) b
               WHERE jsonb_typeof(b) = 'object' LIMIT 10) x)
  )) END
$$;
REVOKE ALL ON FUNCTION public._exos_dispute_raw(jsonb) FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 3. Mail templates: allowlist = live list ∪ last known list ∪ new values.
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_def  text;
  v_live text[];
  v_new  text[] := ARRAY['dispute-opened','dispute-won','dispute-lost'];
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
      'event-reminder','order-failed','checkout-abandoned','marketplace-attention',
      'event-published','inventory-low','inventory-sold-out','payout-sent',
      'payout-pending','fee-free-ending','org-welcome','org-first-event',
      'org-connect-stripe','org-sales-digest','org-weekly-summary',
      'refund-issued','post-event'] || v_new)
  ) u WHERE x <> '';
  ALTER TABLE public.exos_mail DROP CONSTRAINT IF EXISTS exos_mail_template_check;
  EXECUTE format('ALTER TABLE public.exos_mail ADD CONSTRAINT exos_mail_template_check '
                 'CHECK (template = ANY (ARRAY[%s]))',
                 (SELECT string_agg(quote_literal(x), ',' ORDER BY x) FROM unnest(v_vals) x));
END $$;

-- Queue one dispute mail to the org's owner + active finance members, once per
-- dispute and person. Never raises: a mail problem must not fail the webhook.
CREATE OR REPLACE FUNCTION public._exos_queue_dispute_mail(p_dispute uuid, p_template text)
RETURNS int
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  d       public.exos_disputes%ROWTYPE;
  v_org   jsonb;
  v_pay   jsonb;
  v_n     int := 0;
  r       record;
BEGIN
  IF p_template NOT IN ('dispute-opened', 'dispute-won', 'dispute-lost') THEN
    RAISE EXCEPTION '_exos_queue_dispute_mail: bad template %', p_template;
  END IF;
  SELECT * INTO d FROM public.exos_disputes WHERE id = p_dispute;
  IF NOT FOUND THEN RETURN 0; END IF;
  SELECT jsonb_build_object('id', o.id, 'name', o.name) INTO v_org FROM public.exos_orgs o WHERE o.id = d.org_id;
  v_pay := jsonb_build_object(
    'org', v_org,
    'event', CASE WHEN d.event_id IS NOT NULL THEN public._exos_mail_event_json(d.event_id) END,
    'dispute_id', d.dispute_id,
    'livemode', d.livemode,
    'amount_cents', coalesce(d.amount_cents, 0),
    'fee_cents', d.fee_cents,
    'currency', d.currency,
    'reason', d.reason,
    'status', d.status,
    'evidence_due_by', d.evidence_due_by,
    'evidence_submitted', d.evidence_submitted,
    'recovery_status', d.recovery_status,
    'recovery_candidate_cents', d.recovery_candidate_cents);
  FOR r IN SELECT * FROM public.exos_org_mail_recipients(d.org_id, ARRAY['finance']) LOOP
    IF public.exos_mail_enqueue(p_template, r.email, v_pay,
         p_template || ':' || d.dispute_id || ':' || r.user_id::text, r.user_id, false, NULL) IS NOT NULL THEN
      v_n := v_n + 1;
    END IF;
  END LOOP;
  RETURN v_n;
EXCEPTION WHEN OTHERS THEN
  RAISE WARNING '_exos_queue_dispute_mail(%, %): % (mail skipped)', p_dispute, p_template, SQLERRM;
  RETURN 0;
END $$;
REVOKE ALL ON FUNCTION public._exos_queue_dispute_mail(uuid, text) FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 4. The webhook's entry point: exos_record_dispute + the dispute row + mail.
--    Returns what exos_record_dispute returns (the session's stored status),
--    so the webhook's "lost -> exos_refund_checkout" is unchanged.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.exos_record_dispute_event(
  p_session_id         text,
  p_dispute_id         text,
  p_status             text,
  p_reason             text        DEFAULT NULL,
  p_amount_cents       integer     DEFAULT NULL,
  p_provider_event_id  text        DEFAULT NULL,
  p_charge_id          text        DEFAULT NULL,
  p_payment_intent     text        DEFAULT NULL,
  p_fee_cents          integer     DEFAULT NULL,
  p_currency           text        DEFAULT NULL,
  p_evidence_due_by    timestamptz DEFAULT NULL,
  p_evidence_submitted boolean     DEFAULT NULL,
  p_livemode           boolean     DEFAULT NULL,
  p_raw                jsonb       DEFAULT NULL
)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
DECLARE
  v_final   constant text[] := ARRAY['won','lost','warning_closed'];
  v_stored  text;
  v_new     text := lower(btrim(coalesce(p_status, '')));
  v_status  text;
  s         public.exos_checkout_sessions%ROWTYPE;
  d         public.exos_disputes%ROWTYPE;
  v_found   boolean;
  v_id      uuid;
  v_recover boolean;
  v_cur     text;
  v_charge  text := nullif(btrim(coalesce(p_charge_id, '')), '');
  v_pi      text := nullif(btrim(coalesce(p_payment_intent, '')), '');
BEGIN
  -- Session columns + payment meta, finality, validation (raises on a bad
  -- dispute id / status / unknown session): exactly as before.
  v_stored := public.exos_record_dispute(p_session_id, p_dispute_id, p_status, p_reason, p_amount_cents, p_provider_event_id);

  SELECT * INTO s FROM public.exos_checkout_sessions WHERE session_id = p_session_id;
  SELECT * INTO d FROM public.exos_disputes WHERE dispute_id = p_dispute_id FOR UPDATE;
  v_found := FOUND;

  -- A closed dispute stays closed on the row too.
  v_status := CASE WHEN v_found AND d.status = ANY (v_final) AND NOT (v_new = ANY (v_final)) THEN d.status ELSE v_new END;
  v_cur := lower(coalesce(nullif(btrim(p_currency), ''), s.currency, 'usd'));
  IF v_cur !~ '^[a-z]{3}$' THEN v_cur := 'usd'; END IF;
  IF v_charge IS NOT NULL AND v_charge !~ '^[a-z]{2,5}_[A-Za-z0-9]{1,200}$' THEN v_charge := NULL; END IF;
  IF v_pi IS NOT NULL AND v_pi !~ '^[a-z]{2,5}_[A-Za-z0-9]{1,200}$' THEN v_pi := NULL; END IF;

  INSERT INTO public.exos_disputes AS t (
    org_id, event_id, session_id, payment_intent, charge_id, dispute_id, amount_cents, fee_cents, currency,
    reason, status, evidence_due_by, evidence_submitted, livemode, closed_at, last_event_id, raw)
  VALUES (
    s.org_id, s.event_id, s.session_id, coalesce(v_pi, s.payment_intent), v_charge, p_dispute_id,
    CASE WHEN p_amount_cents >= 0 THEN p_amount_cents END,
    CASE WHEN p_fee_cents >= 0 THEN p_fee_cents END,
    v_cur, left(nullif(btrim(p_reason), ''), 60), v_status, p_evidence_due_by,
    coalesce(p_evidence_submitted, false), p_livemode,
    CASE WHEN v_status = ANY (v_final) THEN now() END,
    left(p_provider_event_id, 100), public._exos_dispute_raw(p_raw))
  ON CONFLICT (dispute_id) DO UPDATE SET
    payment_intent     = coalesce(EXCLUDED.payment_intent, t.payment_intent),
    charge_id          = coalesce(EXCLUDED.charge_id, t.charge_id),
    amount_cents       = coalesce(EXCLUDED.amount_cents, t.amount_cents),
    fee_cents          = coalesce(EXCLUDED.fee_cents, t.fee_cents),
    reason             = coalesce(EXCLUDED.reason, t.reason),
    status             = v_status,
    evidence_due_by    = coalesce(EXCLUDED.evidence_due_by, t.evidence_due_by),
    evidence_submitted = t.evidence_submitted OR EXCLUDED.evidence_submitted,
    livemode           = coalesce(EXCLUDED.livemode, t.livemode),
    closed_at          = CASE WHEN v_status = ANY (v_final) THEN coalesce(t.closed_at, now()) ELSE NULL END,
    last_event_id      = coalesce(EXCLUDED.last_event_id, t.last_event_id),
    raw                = coalesce(EXCLUDED.raw, t.raw),
    updated_at         = now()
  RETURNING t.id INTO v_id;

  -- Lost: the recovery candidate (amount + dispute fee) under the org's policy.
  -- Recorded once; nothing is moved (no transfer reversal is built).
  IF v_status = 'lost' THEN
    SELECT coalesce(b.recover_lost_disputes, false) INTO v_recover
      FROM public.exos_org_billing b WHERE b.org_id = s.org_id;
    UPDATE public.exos_disputes
       SET recovery_candidate_cents = coalesce(amount_cents, 0) + coalesce(fee_cents, 0),
           recovery_status = CASE WHEN recovery_status = 'none'
                                  THEN CASE WHEN coalesce(v_recover, false) THEN 'recovery_pending' ELSE 'not_recovered' END
                                  ELSE recovery_status END
     WHERE id = v_id;
  END IF;

  -- Organizer mail, once per dispute and person (dedupe ledger), never raising.
  IF v_status = 'lost' THEN
    PERFORM public._exos_queue_dispute_mail(v_id, 'dispute-lost');
  ELSIF v_status = 'won' THEN
    PERFORM public._exos_queue_dispute_mail(v_id, 'dispute-won');
  ELSIF NOT (v_status = ANY (v_final)) THEN
    PERFORM public._exos_queue_dispute_mail(v_id, 'dispute-opened');
  END IF;

  RETURN v_stored;
END $function$;
REVOKE ALL ON FUNCTION public.exos_record_dispute_event(text, text, text, text, integer, text, text, text, integer, text, timestamptz, boolean, boolean, jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_record_dispute_event(text, text, text, text, integer, text, text, text, integer, text, timestamptz, boolean, boolean, jsonb) TO service_role;

-- ---------------------------------------------------------------------------
-- 5. Reconciliation: the Stripe snapshot, the issues, the runs.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.exos_stripe_balance_txns (
  id                 text PRIMARY KEY,           -- txn_…
  type               text NOT NULL,
  reporting_category text,
  amount_cents       bigint NOT NULL,
  fee_cents          bigint NOT NULL DEFAULT 0,
  net_cents          bigint NOT NULL,
  currency           text NOT NULL,
  source_id          text,                       -- ch_ / re_ / du_ / tr_ / po_ …
  payment_intent     text,                       -- from the expanded source, when it has one
  status             text,
  created            timestamptz NOT NULL,
  available_on       timestamptz,
  first_seen_at      timestamptz NOT NULL DEFAULT now(),
  snapshot_at        timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS exos_stripe_balance_txns_created_idx ON public.exos_stripe_balance_txns (created);
CREATE INDEX IF NOT EXISTS exos_stripe_balance_txns_source_idx  ON public.exos_stripe_balance_txns (source_id);
ALTER TABLE public.exos_stripe_balance_txns ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.exos_stripe_balance_txns FROM PUBLIC, anon, authenticated;
GRANT ALL ON public.exos_stripe_balance_txns TO service_role;
COMMENT ON TABLE public.exos_stripe_balance_txns IS
  'Snapshot of the platform Stripe account''s balance transactions (exos-reconcile-stripe, daily, read-only at Stripe). Service role only. mig 20261001101000.';

CREATE TABLE IF NOT EXISTS public.exos_reconciliation_issues (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  kind         text NOT NULL,
  key          text NOT NULL,
  stripe_id    text,
  session_id   text,
  org_id       uuid REFERENCES public.exos_orgs (id) ON DELETE CASCADE,
  occurred_at  timestamptz NOT NULL,
  detail       jsonb NOT NULL DEFAULT '{}'::jsonb,
  first_seen   timestamptz NOT NULL DEFAULT now(),
  last_seen    timestamptz NOT NULL DEFAULT now(),
  last_run_day date,
  seen_days    int NOT NULL DEFAULT 1,
  resolved_at  timestamptz
);
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'public.exos_reconciliation_issues'::regclass AND conname = 'exos_reconciliation_issues_kind_key') THEN
    ALTER TABLE public.exos_reconciliation_issues ADD CONSTRAINT exos_reconciliation_issues_kind_key UNIQUE (kind, key);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'public.exos_reconciliation_issues'::regclass AND conname = 'exos_reconciliation_issues_chk') THEN
    ALTER TABLE public.exos_reconciliation_issues ADD CONSTRAINT exos_reconciliation_issues_chk CHECK (
      kind IN ('stripe_payment_missing','exos_payment_missing','payment_status_mismatch','amount_mismatch',
               'fee_mismatch','stripe_refund_missing','exos_refund_missing','refund_amount_mismatch',
               'stripe_dispute_missing')
      AND char_length(key) BETWEEN 1 AND 300
      AND jsonb_typeof(detail) = 'object' AND octet_length(detail::text) <= 4000);
  END IF;
END $$;
CREATE INDEX IF NOT EXISTS exos_reconciliation_issues_open_idx ON public.exos_reconciliation_issues (org_id, occurred_at DESC) WHERE resolved_at IS NULL;
ALTER TABLE public.exos_reconciliation_issues ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.exos_reconciliation_issues FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.exos_reconciliation_issues TO authenticated;
GRANT ALL ON public.exos_reconciliation_issues TO service_role;
DROP POLICY IF EXISTS exos_reconciliation_issues_sel ON public.exos_reconciliation_issues;
CREATE POLICY exos_reconciliation_issues_sel ON public.exos_reconciliation_issues FOR SELECT TO authenticated
  USING (public.exos_is_admin()
         OR (org_id IS NOT NULL AND public.exos_has_org_role(org_id, ARRAY['owner','finance'])));
COMMENT ON TABLE public.exos_reconciliation_issues IS
  'Differences between Stripe balance transactions and the Exos ledger (exos-reconcile-stripe). Platform admins read all; org owner / finance their org''s. No client writes. mig 20261001101000.';

CREATE TABLE IF NOT EXISTS public.exos_reconciliation_runs (
  run_day      date PRIMARY KEY,
  window_from  timestamptz NOT NULL,
  window_to    timestamptz NOT NULL,
  started_at   timestamptz NOT NULL DEFAULT now(),
  finished_at  timestamptz,
  txns         int NOT NULL DEFAULT 0,
  issues_found int NOT NULL DEFAULT 0,
  issues_resolved int NOT NULL DEFAULT 0,
  stats        jsonb
);
ALTER TABLE public.exos_reconciliation_runs ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.exos_reconciliation_runs FROM PUBLIC, anon, authenticated;
GRANT ALL ON public.exos_reconciliation_runs TO service_role;

-- Record one run's findings (service role: exos-reconcile-stripe). p_from /
-- p_to is the CHECKED window (margins already applied): open issues that
-- happened inside it and weren't found again are resolved. Re-running the
-- same day is a no-op apart from timestamps.
CREATE OR REPLACE FUNCTION public.exos_reconcile_stripe_record(
  p_run_day date,
  p_from    timestamptz,
  p_to      timestamptz,
  p_issues  jsonb,
  p_stats   jsonb DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_found    int := 0;
  v_resolved int := 0;
  v_issues   jsonb := CASE WHEN jsonb_typeof(p_issues) = 'array' THEN p_issues ELSE '[]'::jsonb END;
BEGIN
  IF p_run_day IS NULL OR p_from IS NULL OR p_to IS NULL OR p_to <= p_from THEN
    RAISE EXCEPTION 'exos_reconcile_stripe_record: bad window';
  END IF;
  IF jsonb_array_length(v_issues) > 5000 THEN
    RAISE EXCEPTION 'exos_reconcile_stripe_record: too many issues in one call';
  END IF;

  WITH src AS (
    SELECT DISTINCT ON (i ->> 'kind', left(i ->> 'key', 300))
           i ->> 'kind' AS kind, left(i ->> 'key', 300) AS key,
           left(nullif(i ->> 'stripe_id', ''), 300) AS stripe_id,
           left(nullif(i ->> 'session_id', ''), 300) AS session_id,
           CASE WHEN (i ->> 'org_id') ~ '^[0-9a-f-]{36}$' THEN (i ->> 'org_id')::uuid END AS org_id,
           coalesce((i ->> 'occurred_at')::timestamptz, now()) AS occurred_at,
           CASE WHEN jsonb_typeof(i -> 'detail') = 'object' AND octet_length((i -> 'detail')::text) <= 4000
                THEN i -> 'detail' ELSE '{}'::jsonb END AS detail
      FROM jsonb_array_elements(v_issues) i
     WHERE jsonb_typeof(i) = 'object' AND coalesce(i ->> 'key', '') <> ''
       AND i ->> 'kind' IN ('stripe_payment_missing','exos_payment_missing','payment_status_mismatch',
                            'amount_mismatch','fee_mismatch','stripe_refund_missing','exos_refund_missing',
                            'refund_amount_mismatch','stripe_dispute_missing')
     ORDER BY i ->> 'kind', left(i ->> 'key', 300)
  ), up AS (
    INSERT INTO public.exos_reconciliation_issues AS t
      (kind, key, stripe_id, session_id, org_id, occurred_at, detail, last_run_day)
    SELECT src.kind, src.key, src.stripe_id, src.session_id,
           -- Org: only ever the session's own org (or the one sent when there's no session row).
           coalesce((SELECT cs.org_id FROM public.exos_checkout_sessions cs WHERE cs.session_id = src.session_id),
                    CASE WHEN src.session_id IS NULL AND EXISTS (SELECT 1 FROM public.exos_orgs o WHERE o.id = src.org_id)
                         THEN src.org_id END),
           src.occurred_at, src.detail, p_run_day
      FROM src
    ON CONFLICT (kind, key) DO UPDATE SET
      stripe_id    = coalesce(EXCLUDED.stripe_id, t.stripe_id),
      session_id   = coalesce(EXCLUDED.session_id, t.session_id),
      org_id       = coalesce(EXCLUDED.org_id, t.org_id),
      detail       = EXCLUDED.detail,
      last_seen    = now(),
      seen_days    = t.seen_days + CASE WHEN t.last_run_day IS DISTINCT FROM EXCLUDED.last_run_day THEN 1 ELSE 0 END,
      last_run_day = EXCLUDED.last_run_day,
      resolved_at  = NULL
    RETURNING t.kind, t.key
  )
  SELECT count(*) INTO v_found FROM up;

  UPDATE public.exos_reconciliation_issues t
     SET resolved_at = now()
   WHERE t.resolved_at IS NULL
     AND t.occurred_at >= p_from AND t.occurred_at < p_to
     AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_issues) i
                      WHERE i ->> 'kind' = t.kind AND left(i ->> 'key', 300) = t.key);
  GET DIAGNOSTICS v_resolved = ROW_COUNT;

  INSERT INTO public.exos_reconciliation_runs AS r
    (run_day, window_from, window_to, started_at, finished_at, txns, issues_found, issues_resolved, stats)
  VALUES (p_run_day, p_from, p_to, now(), now(), coalesce((p_stats ->> 'txns')::int, 0), v_found, v_resolved,
          CASE WHEN jsonb_typeof(p_stats) = 'object' THEN p_stats END)
  ON CONFLICT (run_day) DO UPDATE SET
    window_from = EXCLUDED.window_from, window_to = EXCLUDED.window_to, finished_at = now(),
    txns = EXCLUDED.txns, issues_found = EXCLUDED.issues_found,
    issues_resolved = r.issues_resolved + EXCLUDED.issues_resolved, stats = EXCLUDED.stats;

  RETURN jsonb_build_object('found', v_found, 'resolved', v_resolved,
    'open', (SELECT count(*) FROM public.exos_reconciliation_issues WHERE resolved_at IS NULL));
END $$;
REVOKE ALL ON FUNCTION public.exos_reconcile_stripe_record(date, timestamptz, timestamptz, jsonb, jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_reconcile_stripe_record(date, timestamptz, timestamptz, jsonb, jsonb) TO service_role;

-- Read the issues: a platform admin (any org, or all with p_org_id NULL), or
-- the org's owner / finance for that org only.
CREATE OR REPLACE FUNCTION public.exos_reconciliation_issues_for(
  p_org_id           uuid    DEFAULT NULL,
  p_include_resolved boolean DEFAULT false,
  p_limit            integer DEFAULT 200
) RETURNS TABLE (
  id uuid, kind text, stripe_id text, session_id text, org_id uuid, occurred_at timestamptz,
  detail jsonb, first_seen timestamptz, last_seen timestamptz, seen_days int, resolved_at timestamptz
)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'sign in required' USING ERRCODE = 'insufficient_privilege';
  END IF;
  IF NOT public.exos_is_admin()
     AND (p_org_id IS NULL OR NOT public.exos_has_org_role(p_org_id, ARRAY['owner','finance'])) THEN
    RAISE EXCEPTION 'not allowed' USING ERRCODE = 'insufficient_privilege';
  END IF;
  RETURN QUERY
    SELECT i.id, i.kind, i.stripe_id, i.session_id, i.org_id, i.occurred_at, i.detail,
           i.first_seen, i.last_seen, i.seen_days, i.resolved_at
      FROM public.exos_reconciliation_issues i
     WHERE (p_org_id IS NULL OR i.org_id = p_org_id)
       AND (p_include_resolved OR i.resolved_at IS NULL)
     ORDER BY i.occurred_at DESC, i.kind, i.key
     LIMIT least(greatest(coalesce(p_limit, 200), 1), 1000);
END $$;
REVOKE ALL ON FUNCTION public.exos_reconciliation_issues_for(uuid, boolean, integer) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_reconciliation_issues_for(uuid, boolean, integer) TO authenticated, service_role;
