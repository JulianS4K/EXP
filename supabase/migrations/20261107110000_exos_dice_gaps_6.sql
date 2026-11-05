-- ============================================================================
-- Migration 20261107110000 — Exos: DICE gaps 6 (KANBAN "DICE gaps 2026-11-05"
-- item 6): a fee-change log, a separate entry barcode for an add-on, and
-- conditional checkout questions
-- ============================================================================
-- 1. Fee-change log (DICE Adjustment { reason, processedAt, ticket, feesChange }).
--    exos_fee_adjustments: one append-only row per change to the fees of an
--    order that was already placed: org, event, order (session_id), ticket
--    (optional), a reason code plus free text, fees_change_cents (signed,
--    integer cents), the actor (user, API key), processed_at. Rows are never
--    updated or deleted (trigger; only a cascade from deleting the org, the
--    event or the order removes them). Read: owner / manager / finance (RLS).
--
--    Where fees on an existing order change today (every path looked at):
--      * exos_order_fees is a snapshot written once, when the order is
--        fulfilled (exos_tg_checkout_fees, mig 20261027100000). Nothing
--        updates or deletes it afterwards.
--      * A refund (exos_record_refund, the one SQL entry for every refund:
--        Stripe webhook, exos-refund's exos_refund_finalize, PayPal,
--        reconcilers) does NOT reverse exos_order_fees. Settlements prorate
--        the snapshot by the share of the order still valid
--        (_exos_box_office). The money is unchanged here. What this migration
--        logs for a refund is the buyer-fee part of the money returned: the
--        order's passed-on fees x refunded / paid, cumulative per order, so a
--        retried or partial refund never logs twice and a full refund logs
--        exactly the order's passed-on fees. A refund that fails after it
--        succeeded logs the reversal (reason 'refund_reversed'). Marker patch
--        on exos_record_refund (/* exos: fee adjustments */).
--      * Order edits (exos_order_update, mig 20261102140000) change the
--        buyer's contact details only, never a price, a quantity or a fee, and
--        there is no upgrade or exchange path: nothing to log (the harness
--        checks an edit writes no row).
--      * Fee-rule changes never touch placed orders (the snapshot above):
--        nothing to log.
--      * Manual adjustments by finance: new, exos_fee_adjustment_record (owner
--        / manager / finance, a note, idempotent on a client key, the order's
--        net fees never go below zero). It records the change; it moves no
--        money (a refund or payout is still done where it is done today).
--    Exposed: GET /v1/orders/:id/adjustments (orders:read),
--    GET /v1/events/:id/fee-adjustments (finance:read), the order's "Fee
--    changes" panel on the Orders page, and the settlement inputs
--    (fee_adjustments: count, net, per reason; marker patch on
--    _exos_settlement_inputs). The settlement's own fee lines are unchanged.
--
-- 2. A separate entry barcode for an add-on (DICE Extra.hasSeparateAccessBarcode).
--    exos_event_addons.separate_access_barcode (default false). When it is on,
--    every unit bought (exos_order_addons.quantity) gets an exos_addon_passes
--    row with its own barcode_secret, scanned with the ticket scheme:
--      code = 'A-{passId}:{ownerId}:{bucket}:{mac}', mac = _exos_door_code_mac
--      (the per-day door key of mig 20261019100000, same HMAC, same 30-second
--      buckets and +-2 bucket window).
--    Passes are minted by a trigger on exos_order_addons (every purchase path:
--    paid fulfilment, free extras, guest checkout), so no mint function is
--    patched. They follow the add-on line: refunded / voided voids them; a
--    new owner (proof of email, guest claim) takes them and the secret
--    rotates. Add-ons are order lines, not tied to a ticket, so a ticket
--    transfer does not move them. Turning the setting on for an add-on
--    already sold issues passes for its live lines; turning it off leaves
--    issued passes as they are.
--    Check-in lists get admits ('tickets' default | 'addons' | 'both') and
--    addon_ids (NULL = every add-on with a separate barcode). The door:
--      * an add-on code is checked by _exos_check_in_addon_pass, reached from
--        exos_check_in_ticket (10 arguments; marker /* exos: addon pass codes */),
--        so online, offline replay (exos_check_in_offline, which reuses it;
--        marker /* exos: addon pass refs */) and API check-ins all take it;
--      * an add-on code needs a list that admits add-ons ('tickets-only-list'
--        otherwise, also with no list) and that names its add-on
--        ('wrong-list');
--      * a ticket at a list that admits add-ons only is 'addon-only-list'
--        (_exos_checkin_list_refusal, marker /* exos: addon lists */): every
--        ticket path (online, offline, by name, order check-out) goes through
--        it. An offline replay refused this way records the reject only, no
--        forced entry: the ticket stays good for its own door.
--    The holder reads their passes with the secret (exos_my_addon_passes);
--    door staff never get the secret. Wallet passes stay per ticket.
--
-- 3. Conditional checkout questions ("show B only if A is ...").
--    exos_event_questions.parent_question_id + parent_values: B is shown when
--    A is shown and A's answer is one of the values (a choice; any picked one
--    of a multiple choice; 'true' for a checkbox). Rules
--    (_exos_question_apply_condition, run by _exos_question_upsert):
--    the parent is a single / multiple choice or checkbox question of the
--    same event, not archived; an order question's parent asks per order; a
--    ticket question's parent asks per order or per ticket (the same
--    ticket); the values are the parent's options; no cycles (and at most 10
--    levels). A parent with active children can't be archived, change kind or
--    scope, or drop an option a child uses.
--    Validation (_exos_question_hidden, mirrored by hiddenQuestions in
--    supabase/functions/_shared/questions.ts): a hidden question is never
--    required and its answer is dropped server-side, whatever it was; a shown
--    one follows every usual rule. _exos_validate_answers_core is
--    marker-patched (/* exos: conditional questions 1..4 */);
--    _exos_required_questions_for counts unconditional required questions
--    only (/* exos: conditional questions */). The public questions RPC
--    carries the condition through _exos_question_def.
--
-- Touches:  C: TABLE exos_fee_adjustments, exos_addon_passes,
--              exos_addon_pass_checkins
--           W: TABLE exos_event_addons (+separate_access_barcode),
--              exos_checkin_lists (+admits, +addon_ids),
--              exos_event_questions (+parent_question_id, +parent_values)
--           C: FUNCTION _exos_fee_adj_sync_refunds, _exos_fee_adjustment_add,
--              exos_fee_adjustment_record, _exos_fee_adjustment_summary,
--              _exos_fee_adjustments_guard (trigger),
--              _exos_tg_order_addon_passes, _exos_tg_order_addon_passes_upd,
--              _exos_tg_addon_passes_enable, _exos_tg_checkin_list_addons,
--              _exos_addon_pass_issue, _exos_check_in_addon_pass,
--              exos_my_addon_passes, exos_event_addon_passes,
--              _exos_condition_met, _exos_question_shown, _exos_question_hidden,
--              _exos_question_condition_problem, _exos_question_apply_condition
--           R: FUNCTION _exos_question_def (CREATE OR REPLACE: + the condition)
--           P: exos_record_refund, exos_check_in_ticket (10 args),
--              exos_check_in_offline (10 args), _exos_checkin_list_refusal,
--              exos_api_write (add-on field; a pass id at ticket.check_in),
--              _exos_settlement_inputs,
--              _exos_validate_answers_core, _exos_question_upsert,
--              _exos_required_questions_for
-- Grants:   authenticated: exos_fee_adjustment_record (owner / manager /
--              finance, checked inside), exos_my_addon_passes (own passes),
--              exos_event_addon_passes (owner / manager / finance / door staff)
--           service_role: everything; no anon function
-- Pre-reqs: 20261027100000 (exos_order_fees), 20261031220000
--           (exos_record_refund), 20261019100000 (door day keys),
--           20260929140000 (check-in lists), 20261105120000 (print codes in
--           exos_check_in_ticket), 20261106110000 (checkout questions),
--           20261031100500 (settlements), 20261031110000 (exos_api_write)
-- Additive and re-run safe. No cron.
-- ============================================================================

-- Marker-checked patches (pg_temp.exos_patch_n, as 20261106110000).
CREATE OR REPLACE FUNCTION pg_temp.exos_patch_n(p_sig text, p_marker text, p_old text, p_new text, p_hits int)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE p_fn regprocedure := to_regprocedure(p_sig); v_def text; v_hits int;
BEGIN
  IF p_fn IS NULL THEN
    RAISE EXCEPTION '%: not present', p_sig;
  END IF;
  v_def := replace(pg_get_functiondef(p_fn), chr(13), '');
  p_marker := replace(p_marker, chr(13), ''); p_old := replace(p_old, chr(13), ''); p_new := replace(p_new, chr(13), '');
  IF position(p_marker in v_def) > 0 THEN
    RAISE NOTICE '%: already patched (%)', p_fn, p_marker;
    RETURN;
  END IF;
  v_hits := (length(v_def) - length(replace(v_def, p_old, ''))) / length(p_old);
  IF v_hits <> p_hits THEN
    RAISE EXCEPTION '%: expected % match(es) for patch "%", found %', p_fn, p_hits, p_marker, v_hits;
  END IF;
  EXECUTE replace(v_def, p_old, p_new);
END $$;

-- ===========================================================================
-- 1. Fee-change log
-- ===========================================================================
CREATE TABLE IF NOT EXISTS public.exos_fee_adjustments (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id            uuid NOT NULL REFERENCES public.exos_orgs (id) ON DELETE CASCADE,
  event_id          uuid NOT NULL REFERENCES public.exos_events (id) ON DELETE CASCADE,
  session_id        text NOT NULL REFERENCES public.exos_checkout_sessions (session_id) ON DELETE CASCADE,
  -- A ticket of the order, when the change is about one (no FK: a deleted
  -- ticket would need an UPDATE, and the log is never updated).
  ticket_id         uuid,
  reason            text NOT NULL,
  note              text,
  fees_change_cents bigint NOT NULL,
  currency          text NOT NULL DEFAULT 'usd',
  -- The exos_order_refunds row a refund adjustment came from.
  refund_id         uuid,
  actor             uuid,
  api_key_id        uuid,
  idempotency_key   text,
  detail            jsonb NOT NULL DEFAULT '{}'::jsonb,
  processed_at      timestamptz NOT NULL DEFAULT now(),
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT exos_fee_adjustments_reason_chk CHECK (reason IN ('refund', 'refund_reversed', 'order_edit', 'fee_rule', 'manual')),
  CONSTRAINT exos_fee_adjustments_note_chk CHECK (note IS NULL OR char_length(note) <= 500),
  CONSTRAINT exos_fee_adjustments_cents_chk CHECK (fees_change_cents <> 0 AND abs(fees_change_cents) <= 100000000),
  CONSTRAINT exos_fee_adjustments_currency_chk CHECK (currency ~ '^[a-z]{3}$'),
  CONSTRAINT exos_fee_adjustments_key_chk CHECK (idempotency_key IS NULL OR idempotency_key ~ '^[A-Za-z0-9:_.-]{8,200}$'),
  CONSTRAINT exos_fee_adjustments_detail_chk CHECK (jsonb_typeof(detail) = 'object' AND octet_length(detail::text) <= 4000)
);
CREATE INDEX IF NOT EXISTS exos_fee_adjustments_session_idx ON public.exos_fee_adjustments (session_id, processed_at);
CREATE INDEX IF NOT EXISTS exos_fee_adjustments_event_idx ON public.exos_fee_adjustments (event_id, processed_at);
CREATE INDEX IF NOT EXISTS exos_fee_adjustments_org_idx ON public.exos_fee_adjustments (org_id, processed_at);
CREATE UNIQUE INDEX IF NOT EXISTS exos_fee_adjustments_key_uq
  ON public.exos_fee_adjustments (org_id, idempotency_key) WHERE idempotency_key IS NOT NULL;
COMMENT ON TABLE public.exos_fee_adjustments IS
  'Append-only log of fee changes on placed orders (DICE Adjustment; mig 20261107110000). fees_change_cents is '
  'signed integer cents. A refund row is the buyer-fee part of the money returned; exos_order_fees is never changed.';

-- Append-only: no UPDATE, no DELETE, no TRUNCATE. A DELETE that comes from a
-- foreign-key cascade (the org, the event or the order deleted) is let through.
CREATE OR REPLACE FUNCTION public._exos_fee_adjustments_guard()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
  IF TG_OP = 'DELETE' AND pg_trigger_depth() > 1 THEN
    RETURN OLD;
  END IF;
  RAISE EXCEPTION 'exos_fee_adjustments is append-only: add a new adjustment instead' USING ERRCODE = '55000';
END $$;
REVOKE ALL ON FUNCTION public._exos_fee_adjustments_guard() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS exos_fee_adjustments_append_only ON public.exos_fee_adjustments;
CREATE TRIGGER exos_fee_adjustments_append_only BEFORE UPDATE OR DELETE ON public.exos_fee_adjustments
  FOR EACH ROW EXECUTE FUNCTION public._exos_fee_adjustments_guard();
DROP TRIGGER IF EXISTS exos_fee_adjustments_no_truncate ON public.exos_fee_adjustments;
CREATE TRIGGER exos_fee_adjustments_no_truncate BEFORE TRUNCATE ON public.exos_fee_adjustments
  FOR EACH STATEMENT EXECUTE FUNCTION public._exos_fee_adjustments_guard();
-- Convention (every exos table); never reached: the guard refuses updates first.
DROP TRIGGER IF EXISTS exos_fee_adjustments_touch ON public.exos_fee_adjustments;
CREATE TRIGGER exos_fee_adjustments_touch BEFORE UPDATE ON public.exos_fee_adjustments
  FOR EACH ROW EXECUTE FUNCTION public.exos_touch_updated_at();

ALTER TABLE public.exos_fee_adjustments ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS exos_fee_adjustments_sel ON public.exos_fee_adjustments;
CREATE POLICY exos_fee_adjustments_sel ON public.exos_fee_adjustments FOR SELECT TO authenticated
  USING (public.exos_is_admin() OR public.exos_has_org_role(org_id, ARRAY['owner', 'manager', 'finance']));
REVOKE ALL ON public.exos_fee_adjustments FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.exos_fee_adjustments TO authenticated;
GRANT SELECT, INSERT ON public.exos_fee_adjustments TO service_role;
DO $$
DECLARE r text;
BEGIN
  FOREACH r IN ARRAY ARRAY['coworker_readonly', 'analyst_ro'] LOOP
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = r) THEN
      EXECUTE format('REVOKE ALL ON public.exos_fee_adjustments FROM %I', r);
    END IF;
  END LOOP;
END $$;

-- Refunds: the buyer-fee part of every refund of an order, kept in step with
-- the order's succeeded refunds. Called by exos_record_refund, which holds the
-- order row (FOR UPDATE), so two refunds of one order log one after the other.
-- Idempotent: the same refunds give the same total, so a retry logs nothing.
CREATE OR REPLACE FUNCTION public._exos_fee_adj_sync_refunds(p_session_id text, p_refund uuid)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  s        public.exos_checkout_sessions%ROWTYPE;
  v_fees   bigint;
  v_paid   bigint;
  v_ref    bigint;
  v_target bigint;
  v_logged bigint;
  v_delta  bigint;
  v_rf     public.exos_order_refunds%ROWTYPE;
  v_actor  uuid := auth.uid();
  v_id     uuid;
BEGIN
  SELECT * INTO s FROM public.exos_checkout_sessions WHERE session_id = p_session_id;
  IF NOT FOUND THEN RETURN NULL; END IF;
  v_paid := greatest(coalesce(s.amount_cents, 0), 0);
  IF v_paid = 0 THEN RETURN NULL; END IF;
  SELECT coalesce(sum(f.amount_cents), 0) INTO v_fees FROM public.exos_order_fees f
   WHERE f.session_id = p_session_id AND f.kind = 'passed_on';
  IF v_fees = 0 THEN RETURN NULL; END IF;
  SELECT least(coalesce(sum(r.amount_cents), 0), v_paid) INTO v_ref FROM public.exos_order_refunds r
   WHERE r.session_id = p_session_id AND r.status = 'succeeded';
  -- Half-up rounding; a full refund is exactly -v_fees.
  v_target := -((v_fees * v_ref * 2 + v_paid) / (v_paid * 2));
  SELECT coalesce(sum(a.fees_change_cents), 0) INTO v_logged FROM public.exos_fee_adjustments a
   WHERE a.session_id = p_session_id AND a.reason IN ('refund', 'refund_reversed');
  v_delta := v_target - v_logged;
  IF v_delta = 0 THEN RETURN NULL; END IF;
  IF p_refund IS NOT NULL THEN
    SELECT * INTO v_rf FROM public.exos_order_refunds WHERE id = p_refund AND session_id = p_session_id;
  END IF;
  IF v_actor IS NULL AND v_rf.refund_id IS NOT NULL THEN
    SELECT q.requested_by INTO v_actor FROM public.exos_refund_requests q
     WHERE q.stripe_refund_id = v_rf.refund_id AND q.session_id = p_session_id;
  END IF;
  INSERT INTO public.exos_fee_adjustments (org_id, event_id, session_id, reason, note, fees_change_cents, currency,
                                           refund_id, actor, detail)
  VALUES (s.org_id, s.event_id, s.session_id, CASE WHEN v_delta < 0 THEN 'refund' ELSE 'refund_reversed' END,
          left(nullif(btrim(coalesce(v_rf.reason, '')), ''), 500), v_delta, lower(coalesce(s.currency, 'usd')),
          v_rf.id, v_actor,
          jsonb_build_object('basis', 'refund_share', 'passed_on_fees_cents', v_fees, 'paid_cents', v_paid,
                             'refunded_cents', v_ref, 'refund_status', v_rf.status))
  RETURNING id INTO v_id;
  RETURN v_id;
END $$;
REVOKE ALL ON FUNCTION public._exos_fee_adj_sync_refunds(text, uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_fee_adj_sync_refunds(text, uuid) TO service_role;

SELECT pg_temp.exos_patch_n('public.exos_record_refund(text, text, integer, text, text, text, text, text, jsonb)',
  '/* exos: fee adjustments */',
  '  RETURNING id INTO v_id;',
  '  RETURNING id INTO v_id;
  /* exos: fee adjustments */ -- mig 20261107110000: the buyer-fee part of the refunds, logged.
  PERFORM public._exos_fee_adj_sync_refunds(p_session_id, v_id);', 1);

-- Manual adjustments (core): the caller's role is checked by the wrapper.
-- The order's net fees (passed-on fees + every adjustment) never go below
-- zero. Idempotent on (org, key): the same key returns the first row.
CREATE OR REPLACE FUNCTION public._exos_fee_adjustment_add(
  p_org uuid, p_session_id text, p_ticket_id uuid, p_cents bigint, p_note text,
  p_actor uuid, p_key_id uuid, p_idem text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  s      public.exos_checkout_sessions%ROWTYPE;
  v_note text := btrim(regexp_replace(coalesce(p_note, ''), '\s+', ' ', 'g'));
  v_key  text := nullif(btrim(coalesce(p_idem, '')), '');
  v_net  bigint;
  a      public.exos_fee_adjustments%ROWTYPE;
BEGIN
  SELECT * INTO s FROM public.exos_checkout_sessions WHERE session_id = p_session_id AND org_id = p_org FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'order not found' USING ERRCODE = 'P0002';
  END IF;
  IF v_key IS NOT NULL THEN
    IF v_key !~ '^[A-Za-z0-9:_.-]{8,200}$' THEN
      RAISE EXCEPTION 'the idempotency key is 8 to 200 letters, digits or :_.-' USING ERRCODE = '22023';
    END IF;
    SELECT * INTO a FROM public.exos_fee_adjustments WHERE org_id = p_org AND idempotency_key = v_key;
    IF FOUND THEN
      IF a.session_id <> p_session_id OR a.fees_change_cents <> p_cents THEN
        RAISE EXCEPTION 'this idempotency key was used for another adjustment' USING ERRCODE = '22023';
      END IF;
      RETURN to_jsonb(a) || jsonb_build_object('duplicate', true);
    END IF;
  END IF;
  IF s.status NOT IN ('fulfilled', 'partially_refunded', 'refunded') THEN
    RAISE EXCEPTION 'only a placed order has fees to adjust' USING ERRCODE = '55000';
  END IF;
  IF p_cents IS NULL OR p_cents = 0 OR abs(p_cents) > 10000000 THEN
    RAISE EXCEPTION 'the change is a whole number of cents, not 0, at most 10,000,000 either way' USING ERRCODE = '22023';
  END IF;
  IF char_length(v_note) < 3 OR char_length(v_note) > 500 THEN
    RAISE EXCEPTION 'say why in 3 to 500 characters' USING ERRCODE = '22023';
  END IF;
  IF p_ticket_id IS NOT NULL AND NOT EXISTS (
       SELECT 1 FROM public.exos_tickets t WHERE t.id = p_ticket_id AND t.org_id = p_org AND t.order_ref = p_session_id) THEN
    RAISE EXCEPTION 'that ticket is not on this order' USING ERRCODE = '22023';
  END IF;
  SELECT coalesce((SELECT sum(f.amount_cents) FROM public.exos_order_fees f
                    WHERE f.session_id = p_session_id AND f.kind = 'passed_on'), 0)
       + coalesce((SELECT sum(x.fees_change_cents) FROM public.exos_fee_adjustments x
                    WHERE x.session_id = p_session_id), 0)
    INTO v_net;
  IF v_net + p_cents < 0 THEN
    RAISE EXCEPTION 'that would take the order''s fees below zero (% cents left)', v_net USING ERRCODE = '22023';
  END IF;
  INSERT INTO public.exos_fee_adjustments (org_id, event_id, session_id, ticket_id, reason, note, fees_change_cents,
                                           currency, actor, api_key_id, idempotency_key, detail)
  VALUES (p_org, s.event_id, s.session_id, p_ticket_id, 'manual', v_note, p_cents, lower(coalesce(s.currency, 'usd')),
          p_actor, p_key_id, v_key, jsonb_build_object('basis', 'manual', 'net_before_cents', v_net))
  ON CONFLICT (org_id, idempotency_key) WHERE idempotency_key IS NOT NULL DO NOTHING
  RETURNING * INTO a;
  IF a.id IS NULL THEN
    SELECT * INTO a FROM public.exos_fee_adjustments WHERE org_id = p_org AND idempotency_key = v_key;
    RETURN to_jsonb(a) || jsonb_build_object('duplicate', true);
  END IF;
  RETURN to_jsonb(a) || jsonb_build_object('duplicate', false);
END $$;
REVOKE ALL ON FUNCTION public._exos_fee_adjustment_add(uuid, text, uuid, bigint, text, uuid, uuid, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_fee_adjustment_add(uuid, text, uuid, bigint, text, uuid, uuid, text) TO service_role;

-- Dashboard: owner / manager / finance of the order's org.
CREATE OR REPLACE FUNCTION public.exos_fee_adjustment_record(
  p_session_id text, p_fees_change_cents bigint, p_note text,
  p_ticket_id uuid DEFAULT NULL, p_idempotency_key text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_org uuid;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'exos_fee_adjustment_record: not authenticated' USING ERRCODE = '42501';
  END IF;
  SELECT org_id INTO v_org FROM public.exos_checkout_sessions WHERE session_id = p_session_id;
  IF v_org IS NULL OR NOT (public.exos_is_admin() OR public.exos_has_org_role(v_org, ARRAY['owner', 'manager', 'finance'])) THEN
    RAISE EXCEPTION 'exos_fee_adjustment_record: owners, managers and finance only' USING ERRCODE = '42501';
  END IF;
  RETURN public._exos_fee_adjustment_add(v_org, p_session_id, p_ticket_id, p_fees_change_cents, p_note,
                                         auth.uid(), NULL, p_idempotency_key);
END $$;
REVOKE ALL ON FUNCTION public.exos_fee_adjustment_record(text, bigint, text, uuid, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_fee_adjustment_record(text, bigint, text, uuid, text) TO authenticated, service_role;

-- An event's fee changes, summed (settlement inputs).
CREATE OR REPLACE FUNCTION public._exos_fee_adjustment_summary(p_event uuid)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT jsonb_build_object(
    'count', count(*),
    'net_cents', coalesce(sum(a.fees_change_cents), 0),
    'by_reason', coalesce((SELECT jsonb_object_agg(x.reason, x.cents)
                             FROM (SELECT b.reason, sum(b.fees_change_cents) AS cents
                                     FROM public.exos_fee_adjustments b WHERE b.event_id = p_event
                                    GROUP BY b.reason) x), '{}'::jsonb),
    'last_at', max(a.processed_at))
    FROM public.exos_fee_adjustments a WHERE a.event_id = p_event
$$;
REVOKE ALL ON FUNCTION public._exos_fee_adjustment_summary(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_fee_adjustment_summary(uuid) TO service_role;

SELECT pg_temp.exos_patch_n('public._exos_settlement_inputs(uuid)', '/* exos: fee adjustments */',
  '    ''sold_elsewhere'', public._exos_sold_elsewhere(e.id),',
  '    ''sold_elsewhere'', public._exos_sold_elsewhere(e.id),
    /* exos: fee adjustments */ ''fee_adjustments'', public._exos_fee_adjustment_summary(e.id),', 1);

-- ===========================================================================
-- 2. A separate entry barcode for an add-on
-- ===========================================================================
ALTER TABLE public.exos_event_addons ADD COLUMN IF NOT EXISTS separate_access_barcode boolean NOT NULL DEFAULT false;
COMMENT ON COLUMN public.exos_event_addons.separate_access_barcode IS
  'Each unit bought gets its own entry code (exos_addon_passes), scanned at a check-in list that admits add-ons '
  '(DICE Extra.hasSeparateAccessBarcode; mig 20261107110000).';

ALTER TABLE public.exos_checkin_lists ADD COLUMN IF NOT EXISTS admits text NOT NULL DEFAULT 'tickets';
ALTER TABLE public.exos_checkin_lists ADD COLUMN IF NOT EXISTS addon_ids uuid[];
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'exos_checkin_lists_admits_chk') THEN
    ALTER TABLE public.exos_checkin_lists ADD CONSTRAINT exos_checkin_lists_admits_chk
      CHECK (admits IN ('tickets', 'addons', 'both'));
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'exos_checkin_lists_addons_chk') THEN
    ALTER TABLE public.exos_checkin_lists ADD CONSTRAINT exos_checkin_lists_addons_chk
      CHECK (addon_ids IS NULL OR (cardinality(addon_ids) BETWEEN 1 AND 200 AND admits <> 'tickets'));
  END IF;
END $$;
COMMENT ON COLUMN public.exos_checkin_lists.admits IS
  'tickets (default): ticket codes only; addons: add-on entry codes only (a VIP lounge); both. mig 20261107110000.';

-- A list's add-ons must be the event's.
CREATE OR REPLACE FUNCTION public._exos_tg_checkin_list_addons()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
  IF NEW.admits = 'tickets' THEN
    NEW.addon_ids := NULL;
  ELSIF NEW.addon_ids IS NOT NULL THEN
    NEW.addon_ids := ARRAY(SELECT DISTINCT x FROM unnest(NEW.addon_ids) x WHERE x IS NOT NULL ORDER BY x);
    IF cardinality(NEW.addon_ids) = 0 THEN
      NEW.addon_ids := NULL;
    ELSIF EXISTS (SELECT 1 FROM unnest(NEW.addon_ids) x
                   WHERE NOT EXISTS (SELECT 1 FROM public.exos_event_addons a WHERE a.id = x AND a.event_id = NEW.event_id)) THEN
      RAISE EXCEPTION 'check-in list: an add-on is not on this event' USING ERRCODE = '42501';
    END IF;
  END IF;
  RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION public._exos_tg_checkin_list_addons() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS exos_checkin_lists_addons ON public.exos_checkin_lists;
CREATE TRIGGER exos_checkin_lists_addons BEFORE INSERT OR UPDATE ON public.exos_checkin_lists
  FOR EACH ROW EXECUTE FUNCTION public._exos_tg_checkin_list_addons();

CREATE TABLE IF NOT EXISTS public.exos_addon_passes (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id         uuid NOT NULL REFERENCES public.exos_orgs (id) ON DELETE CASCADE,
  event_id       uuid NOT NULL REFERENCES public.exos_events (id) ON DELETE CASCADE,
  order_addon_id uuid NOT NULL REFERENCES public.exos_order_addons (id) ON DELETE CASCADE,
  addon_id       uuid REFERENCES public.exos_event_addons (id) ON DELETE SET NULL,
  addon_name     text,
  unit_index     integer NOT NULL CHECK (unit_index BETWEEN 1 AND 50),
  owner_id       uuid,
  order_ref      text,
  status         text NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'used', 'voided')),
  barcode_secret text NOT NULL,
  check_in_at    timestamptz,
  created_at     timestamptz NOT NULL DEFAULT now(),
  updated_at     timestamptz NOT NULL DEFAULT now(),
  UNIQUE (order_addon_id, unit_index)
);
CREATE INDEX IF NOT EXISTS exos_addon_passes_event_idx ON public.exos_addon_passes (event_id, status);
CREATE INDEX IF NOT EXISTS exos_addon_passes_owner_idx ON public.exos_addon_passes (owner_id) WHERE owner_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS exos_addon_passes_org_idx ON public.exos_addon_passes (org_id);
CREATE INDEX IF NOT EXISTS exos_addon_passes_addon_idx ON public.exos_addon_passes (addon_id);
COMMENT ON TABLE public.exos_addon_passes IS
  'One entry code per add-on unit when the add-on has separate_access_barcode (mig 20261107110000). Code: '
  '''A-{id}:{owner}:{bucket}:{mac}'', the ticket scheme (_exos_door_code_mac). barcode_secret: holder only (exos_my_addon_passes).';
DROP TRIGGER IF EXISTS exos_addon_passes_touch ON public.exos_addon_passes;
CREATE TRIGGER exos_addon_passes_touch BEFORE UPDATE ON public.exos_addon_passes
  FOR EACH ROW EXECUTE FUNCTION public.exos_touch_updated_at();
ALTER TABLE public.exos_addon_passes ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS exos_addon_passes_owner_read ON public.exos_addon_passes;
CREATE POLICY exos_addon_passes_owner_read ON public.exos_addon_passes FOR SELECT TO authenticated
  USING (owner_id IS NOT NULL AND owner_id = auth.uid());
DROP POLICY IF EXISTS exos_addon_passes_staff_read ON public.exos_addon_passes;
CREATE POLICY exos_addon_passes_staff_read ON public.exos_addon_passes FOR SELECT TO authenticated
  USING (public.exos_is_admin() OR public.exos_has_org_role(org_id, ARRAY['owner', 'manager', 'finance'])
         OR public.exos_can_door_event(event_id));
REVOKE ALL ON public.exos_addon_passes FROM PUBLIC, anon, authenticated;
-- Never the secret: the holder gets it from exos_my_addon_passes.
GRANT SELECT (id, org_id, event_id, order_addon_id, addon_id, addon_name, unit_index, owner_id, order_ref, status,
              check_in_at, created_at, updated_at) ON public.exos_addon_passes TO authenticated;
GRANT ALL ON public.exos_addon_passes TO service_role;

CREATE TABLE IF NOT EXISTS public.exos_addon_pass_checkins (
  id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id             uuid NOT NULL REFERENCES public.exos_orgs (id) ON DELETE CASCADE,
  event_id           uuid NOT NULL REFERENCES public.exos_events (id) ON DELETE CASCADE,
  pass_id            uuid NOT NULL REFERENCES public.exos_addon_passes (id) ON DELETE CASCADE,
  list_id            uuid REFERENCES public.exos_checkin_lists (id) ON DELETE SET NULL,
  gate               text,
  direction          text NOT NULL DEFAULT 'entry' CHECK (direction IN ('entry', 'exit')),
  scanned_by         uuid,
  scanned_by_email   text,
  source             text NOT NULL DEFAULT 'manual' CHECK (source IN ('camera', 'manual')),
  verification       text NOT NULL DEFAULT 'manual' CHECK (verification IN ('verified', 'manual')),
  device             text,
  override_reason    text,
  offline_scanned_at timestamptz,
  scanned_at         timestamptz NOT NULL DEFAULT clock_timestamp(),
  created_at         timestamptz NOT NULL DEFAULT now(),
  updated_at         timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS exos_addon_pass_checkins_pass_idx ON public.exos_addon_pass_checkins (pass_id, list_id, scanned_at);
CREATE INDEX IF NOT EXISTS exos_addon_pass_checkins_event_idx ON public.exos_addon_pass_checkins (event_id, scanned_at);
CREATE INDEX IF NOT EXISTS exos_addon_pass_checkins_org_idx ON public.exos_addon_pass_checkins (org_id);
CREATE INDEX IF NOT EXISTS exos_addon_pass_checkins_list_idx ON public.exos_addon_pass_checkins (list_id) WHERE list_id IS NOT NULL;
DROP TRIGGER IF EXISTS exos_addon_pass_checkins_touch ON public.exos_addon_pass_checkins;
CREATE TRIGGER exos_addon_pass_checkins_touch BEFORE UPDATE ON public.exos_addon_pass_checkins
  FOR EACH ROW EXECUTE FUNCTION public.exos_touch_updated_at();
ALTER TABLE public.exos_addon_pass_checkins ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS exos_addon_pass_checkins_sel ON public.exos_addon_pass_checkins;
CREATE POLICY exos_addon_pass_checkins_sel ON public.exos_addon_pass_checkins FOR SELECT TO authenticated
  USING (public.exos_is_admin() OR public.exos_has_org_role(org_id, ARRAY['owner', 'manager', 'finance'])
         OR public.exos_can_door_event(event_id));
REVOKE ALL ON public.exos_addon_pass_checkins FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.exos_addon_pass_checkins TO authenticated;
GRANT ALL ON public.exos_addon_pass_checkins TO service_role;
DO $$
DECLARE r text; t text;
BEGIN
  FOREACH r IN ARRAY ARRAY['coworker_readonly', 'analyst_ro'] LOOP
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = r) THEN
      FOREACH t IN ARRAY ARRAY['exos_addon_passes', 'exos_addon_pass_checkins'] LOOP
        EXECUTE format('REVOKE ALL ON public.%I FROM %I', t, r);
      END LOOP;
    END IF;
  END LOOP;
END $$;

-- Issue the passes of one add-on line (once per unit; a re-run adds nothing).
CREATE OR REPLACE FUNCTION public._exos_addon_pass_issue(p_order_addon uuid)
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  o   public.exos_order_addons%ROWTYPE;
  v_n int;
BEGIN
  SELECT * INTO o FROM public.exos_order_addons WHERE id = p_order_addon;
  IF NOT FOUND OR o.status <> 'active' OR o.addon_id IS NULL THEN RETURN 0; END IF;
  IF NOT EXISTS (SELECT 1 FROM public.exos_event_addons a WHERE a.id = o.addon_id AND a.separate_access_barcode) THEN
    RETURN 0;
  END IF;
  INSERT INTO public.exos_addon_passes (org_id, event_id, order_addon_id, addon_id, addon_name, unit_index, owner_id,
                                        order_ref, barcode_secret)
  SELECT o.org_id, o.event_id, o.id, o.addon_id, o.addon_name, g, coalesce(o.owner_id, o.buyer_id), o.order_ref,
         gen_random_uuid()::text
    FROM generate_series(1, o.quantity) g
  ON CONFLICT (order_addon_id, unit_index) DO NOTHING;
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN v_n;
END $$;
REVOKE ALL ON FUNCTION public._exos_addon_pass_issue(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_addon_pass_issue(uuid) TO service_role;

CREATE OR REPLACE FUNCTION public._exos_tg_order_addon_passes()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
  PERFORM public._exos_addon_pass_issue(NEW.id);
  RETURN NULL;
END $$;
REVOKE ALL ON FUNCTION public._exos_tg_order_addon_passes() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS exos_order_addons_passes ON public.exos_order_addons;
CREATE TRIGGER exos_order_addons_passes AFTER INSERT ON public.exos_order_addons
  FOR EACH ROW WHEN (NEW.status = 'active' AND NEW.addon_id IS NOT NULL)
  EXECUTE FUNCTION public._exos_tg_order_addon_passes();

-- The passes follow their line: refunded / voided voids them; a new owner
-- takes them, and their secrets rotate (the old holder can't sign for the new).
CREATE OR REPLACE FUNCTION public._exos_tg_order_addon_passes_upd()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
  IF NEW.status IS DISTINCT FROM OLD.status AND NEW.status IN ('refunded', 'voided') THEN
    UPDATE public.exos_addon_passes SET status = 'voided' WHERE order_addon_id = NEW.id AND status <> 'voided';
  END IF;
  IF coalesce(NEW.owner_id, NEW.buyer_id) IS DISTINCT FROM coalesce(OLD.owner_id, OLD.buyer_id) THEN
    UPDATE public.exos_addon_passes
       SET owner_id = coalesce(NEW.owner_id, NEW.buyer_id), barcode_secret = gen_random_uuid()::text
     WHERE order_addon_id = NEW.id;
  END IF;
  RETURN NULL;
END $$;
REVOKE ALL ON FUNCTION public._exos_tg_order_addon_passes_upd() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS exos_order_addons_passes_upd ON public.exos_order_addons;
CREATE TRIGGER exos_order_addons_passes_upd AFTER UPDATE OF status, owner_id, buyer_id ON public.exos_order_addons
  FOR EACH ROW EXECUTE FUNCTION public._exos_tg_order_addon_passes_upd();

-- Turned on for an add-on already sold: its live lines get their passes.
CREATE OR REPLACE FUNCTION public._exos_tg_addon_passes_enable()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE r record;
BEGIN
  FOR r IN SELECT o.id FROM public.exos_order_addons o WHERE o.addon_id = NEW.id AND o.status = 'active' LOOP
    PERFORM public._exos_addon_pass_issue(r.id);
  END LOOP;
  RETURN NULL;
END $$;
REVOKE ALL ON FUNCTION public._exos_tg_addon_passes_enable() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS exos_event_addons_passes_enable ON public.exos_event_addons;
CREATE TRIGGER exos_event_addons_passes_enable AFTER UPDATE OF separate_access_barcode ON public.exos_event_addons
  FOR EACH ROW WHEN (NEW.separate_access_barcode AND NOT OLD.separate_access_barcode)
  EXECUTE FUNCTION public._exos_tg_addon_passes_enable();

-- Scan one add-on code. Called by exos_check_in_ticket (10 arguments) for an
-- A- code, or a typed id that is a pass's. The same rules as a ticket, in
-- the same order: role, direction, scan time, event, doors, the code, the
-- list, status, re-entry.
CREATE OR REPLACE FUNCTION public._exos_check_in_addon_pass(
  p_pass_id uuid, p_source text, p_payload text, p_event_id uuid, p_reason text,
  p_scanned_at timestamptz, p_device text, p_list_id uuid, p_direction text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  v_uid      uuid := auth.uid();
  ps         public.exos_addon_passes%ROWTYPE;
  l          public.exos_checkin_lists%ROWTYPE;
  v_dir      text := lower(coalesce(nullif(btrim(p_direction), ''), 'entry'));
  v_scan_at  timestamptz := coalesce(p_scanned_at, clock_timestamp());
  v_manager  boolean;
  v_verified boolean := false;
  v_open_at  timestamptz;
  v_test     boolean := false;
  v_payload  text := btrim(coalesce(p_payload, ''));
  v_last     text;
  v_cancel   boolean;
  v_n        int;
  v_info     jsonb;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'exos_check_in_ticket: not authenticated' USING ERRCODE = '42501';
  END IF;
  SELECT * INTO ps FROM public.exos_addon_passes WHERE id = p_pass_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'not-found', 'kind', 'addon');
  END IF;
  IF NOT (public.exos_is_admin() OR public.exos_has_org_role(ps.org_id, ARRAY['owner', 'manager', 'scanner'])) THEN
    RAISE EXCEPTION 'exos_check_in_ticket: not authorized' USING ERRCODE = '42501';
  END IF;
  v_manager := public.exos_is_admin() OR public.exos_has_org_role(ps.org_id, ARRAY['owner', 'manager']);
  v_info := jsonb_build_object('kind', 'addon', 'pass_id', ps.id, 'addon_name', ps.addon_name);
  IF v_dir NOT IN ('entry', 'exit') THEN
    RETURN v_info || jsonb_build_object('ok', false, 'reason', 'bad-direction');
  END IF;
  IF NOT public._exos_scan_time_ok(ps.event_id, p_scanned_at) THEN
    RETURN v_info || jsonb_build_object('ok', false, 'reason', 'bad-scan-time');
  END IF;
  IF p_event_id IS NULL OR ps.event_id <> p_event_id THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'wrong-event', 'kind', 'addon');
  END IF;
  IF NOT public.exos_can_door_event(ps.event_id) THEN
    RETURN v_info || jsonb_build_object('ok', false, 'reason', 'not-assigned');
  END IF;
  SELECT coalesce(e.doors_at, e.starts_at),
         (coalesce(e.checkin_test_mode, false) AND e.checkin_test_until IS NOT NULL AND now() < e.checkin_test_until),
         e.status = 'cancelled'
    INTO v_open_at, v_test, v_cancel
    FROM public.exos_events e WHERE e.id = ps.event_id;
  IF v_cancel THEN
    RETURN v_info || jsonb_build_object('ok', false, 'reason', 'event-cancelled');
  END IF;
  IF v_dir = 'entry' AND NOT v_test AND v_open_at IS NOT NULL AND now() < v_open_at THEN
    RETURN v_info || jsonb_build_object('ok', false, 'reason', 'doors-not-open', 'opens_at', v_open_at);
  END IF;

  -- The code: 'A-{pass}:{owner}:{bucket}:{mac}' signed with the pass's day key.
  IF upper(left(v_payload, 2)) = 'A-' THEN
    DECLARE
      v_parts text[] := string_to_array(substring(v_payload FROM 3), ':');
      v_cur   bigint := floor(extract(epoch FROM v_scan_at) * 1000 / 30000);
      v_bkt   bigint;
    BEGIN
      IF array_length(v_parts, 1) <> 4 OR v_parts[1] <> ps.id::text OR ps.owner_id IS NULL
         OR v_parts[2] <> ps.owner_id::text THEN
        RETURN v_info || jsonb_build_object('ok', false, 'reason', 'barcode-rejected');
      END IF;
      v_bkt := v_parts[3]::bigint;
      IF abs(v_cur - v_bkt) > 2 THEN
        RETURN v_info || jsonb_build_object('ok', false, 'reason', 'barcode-expired');
      END IF;
      IF public._exos_door_code_mac(ps.id, ps.owner_id, v_bkt, ps.barcode_secret) IS DISTINCT FROM v_parts[4] THEN
        RETURN v_info || jsonb_build_object('ok', false, 'reason', 'barcode-rejected');
      END IF;
      v_verified := true;
    EXCEPTION WHEN others THEN
      RETURN v_info || jsonb_build_object('ok', false, 'reason', 'barcode-rejected');
    END;
  ELSIF v_payload <> '' OR p_source = 'camera' THEN
    -- A ticket's code (T-, W-, P-) never admits an add-on, and a camera read needs a code.
    RETURN v_info || jsonb_build_object('ok', false, 'reason', 'barcode-rejected');
  ELSE
    -- Typed pass id: an owner / manager override with a reason, as for tickets.
    IF NOT v_manager THEN
      RETURN v_info || jsonb_build_object('ok', false, 'reason', 'needs-manager');
    END IF;
    IF length(btrim(coalesce(p_reason, ''))) < 3 THEN
      RETURN v_info || jsonb_build_object('ok', false, 'reason', 'reason-required');
    END IF;
  END IF;

  -- The list: it must admit add-ons, and this one.
  IF p_list_id IS NULL THEN
    RETURN v_info || jsonb_build_object('ok', false, 'reason', 'tickets-only-list');
  END IF;
  SELECT * INTO l FROM public.exos_checkin_lists WHERE id = p_list_id;
  IF NOT FOUND OR l.event_id <> ps.event_id THEN
    RETURN v_info || jsonb_build_object('ok', false, 'reason', 'unknown-list');
  END IF;
  IF l.admits = 'tickets' THEN
    RETURN v_info || jsonb_build_object('ok', false, 'reason', 'tickets-only-list', 'list', l.name);
  END IF;
  IF l.addon_ids IS NOT NULL AND (ps.addon_id IS NULL OR NOT (ps.addon_id = ANY (l.addon_ids))) THEN
    RETURN v_info || jsonb_build_object('ok', false, 'reason', 'wrong-list', 'list', l.name);
  END IF;
  IF v_dir = 'exit' AND NOT l.allow_reentry THEN
    RETURN v_info || jsonb_build_object('ok', false, 'reason', 'exit-not-allowed', 'list', l.name);
  END IF;
  IF v_dir = 'entry' AND ((l.valid_from IS NOT NULL AND v_scan_at < l.valid_from)
                          OR (l.valid_until IS NOT NULL AND v_scan_at > l.valid_until)) THEN
    RETURN v_info || jsonb_build_object('ok', false, 'reason', 'invalid-time', 'list', l.name);
  END IF;

  -- One gate at a time per pass.
  SELECT status INTO ps.status FROM public.exos_addon_passes WHERE id = ps.id FOR UPDATE;
  IF ps.status = 'voided' THEN
    RETURN v_info || jsonb_build_object('ok', false, 'reason', 'voided');
  END IF;
  IF v_test AND v_open_at IS NOT NULL AND now() < v_open_at THEN
    RETURN v_info || jsonb_build_object('ok', true, 'reason', 'test-scan', 'test', true);
  END IF;
  -- The last scan of this pass on this list, at or before the scan time.
  SELECT c.direction INTO v_last FROM public.exos_addon_pass_checkins c
   WHERE c.pass_id = ps.id AND c.list_id = l.id AND coalesce(c.offline_scanned_at, c.scanned_at) <= v_scan_at
   ORDER BY coalesce(c.offline_scanned_at, c.scanned_at) DESC, c.scanned_at DESC LIMIT 1;
  IF v_dir = 'exit' THEN
    IF coalesce(v_last, 'exit') <> 'entry' THEN
      RETURN v_info || jsonb_build_object('ok', false, 'reason', 'not-inside', 'list', l.name);
    END IF;
  ELSIF l.allow_reentry THEN
    IF v_last = 'entry' THEN
      RETURN v_info || jsonb_build_object('ok', false, 'reason', 'already-inside', 'list', l.name);
    END IF;
  ELSIF ps.status = 'used' THEN
    RETURN v_info || jsonb_build_object('ok', false, 'reason', 'used',
             'check_in_at', (SELECT check_in_at FROM public.exos_addon_passes WHERE id = ps.id));
  END IF;
  IF v_dir = 'entry' THEN
    UPDATE public.exos_addon_passes SET status = 'used', check_in_at = v_scan_at WHERE id = ps.id AND status = 'active';
    GET DIAGNOSTICS v_n = ROW_COUNT;
  END IF;
  INSERT INTO public.exos_addon_pass_checkins (org_id, event_id, pass_id, list_id, gate, direction, scanned_by,
                                               scanned_by_email, source, verification, device, override_reason,
                                               offline_scanned_at)
  VALUES (ps.org_id, ps.event_id, ps.id, l.id, l.name, v_dir, v_uid, lower(coalesce(auth.jwt() ->> 'email', '')),
          CASE WHEN v_verified AND p_source = 'camera' THEN 'camera' ELSE 'manual' END,
          CASE WHEN v_verified THEN 'verified' ELSE 'manual' END,
          nullif(left(btrim(coalesce(p_device, '')), 60), ''),
          CASE WHEN v_verified THEN NULL ELSE left(btrim(p_reason), 300) END, p_scanned_at);
  IF v_dir = 'exit' THEN
    RETURN v_info || jsonb_build_object('ok', true, 'reason', 'checked-out', 'direction', 'exit',
                                        'scanned_at', v_scan_at, 'verified', v_verified, 'list', l.name);
  END IF;
  RETURN v_info || jsonb_build_object('ok', true, 'reason', 'checked-in', 'check_in_at', v_scan_at,
                                      'verified', v_verified, 'list', l.name,
                                      'reentry', coalesce(v_n, 0) = 0);
END $$;
REVOKE ALL ON FUNCTION public._exos_check_in_addon_pass(uuid, text, text, uuid, text, timestamptz, text, uuid, text)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_check_in_addon_pass(uuid, text, text, uuid, text, timestamptz, text, uuid, text)
  TO service_role;

-- The door's check-in: an add-on code goes to the pass check-in. Only the
-- 10-argument version (the one the door and the API call); the old 8-argument
-- one knows tickets only.
SELECT pg_temp.exos_patch_n(
  'public.exos_check_in_ticket(uuid, text, text, text, uuid, text, timestamp with time zone, text, uuid, text)',
  '/* exos: addon pass codes */',
  '  SELECT org_id, event_id, status, pending_transfer_id, owner_id, barcode_secret, tier_id
    INTO v_org, v_event, v_prev, v_pending, v_owner, v_secret, v_tier
    FROM public.exos_tickets WHERE id = p_ticket_id;',
  '  /* exos: addon pass codes */ -- mig 20261107110000: an add-on''s own entry code.
  IF upper(left(btrim(coalesce(p_barcode_payload, '''')), 2)) = ''A-''
     OR (NOT EXISTS (SELECT 1 FROM public.exos_tickets WHERE id = p_ticket_id)
         AND EXISTS (SELECT 1 FROM public.exos_addon_passes WHERE id = p_ticket_id)) THEN
    RETURN public._exos_check_in_addon_pass(p_ticket_id, p_source, p_barcode_payload, p_event_id, p_reason,
                                            p_scanned_at, p_device, p_list_id, p_direction);
  END IF;
  SELECT org_id, event_id, status, pending_transfer_id, owner_id, barcode_secret, tier_id
    INTO v_org, v_event, v_prev, v_pending, v_owner, v_secret, v_tier
    FROM public.exos_tickets WHERE id = p_ticket_id;', 1);

-- Offline replay: a pass's scan writes its client ref and its reject under
-- the pass's org and event.
SELECT pg_temp.exos_patch_n(
  'public.exos_check_in_offline(uuid, uuid, uuid, timestamp with time zone, text, text, text, text, uuid, text)',
  '/* exos: addon pass refs */',
  '  SELECT org_id, event_id INTO v_org, v_event FROM public.exos_tickets WHERE id = p_ticket_id;',
  '  SELECT org_id, event_id INTO v_org, v_event FROM public.exos_tickets WHERE id = p_ticket_id;
  /* exos: addon pass refs */ -- mig 20261107110000
  IF v_org IS NULL THEN
    SELECT org_id, event_id INTO v_org, v_event FROM public.exos_addon_passes WHERE id = p_ticket_id;
  END IF;', 1);

-- A list that admits add-on codes only refuses tickets (every ticket path).
SELECT pg_temp.exos_patch_n(
  'public._exos_checkin_list_refusal(uuid, uuid, uuid, text, timestamp with time zone)',
  '/* exos: addon lists */',
  '  IF l.tier_ids IS NOT NULL AND (p_tier_id IS NULL OR NOT (p_tier_id = ANY (l.tier_ids))) THEN',
  '  /* exos: addon lists */ -- mig 20261107110000
  IF l.admits = ''addons'' THEN
    RETURN jsonb_build_object(''ok'', false, ''reason'', ''addon-only-list'', ''list'', l.name);
  END IF;
  IF l.tier_ids IS NOT NULL AND (p_tier_id IS NULL OR NOT (p_tier_id = ANY (l.tier_ids))) THEN', 1);

-- The API's add-on writes take the new setting.
SELECT pg_temp.exos_patch_n('public.exos_api_write(uuid, text, text, jsonb, text)', '/* exos: addon access barcode */',
  '    ''image_url'', ''sort_order''];',
  '    ''image_url'', ''sort_order'', ''separate_access_barcode'' /* exos: addon access barcode */];', 1);

-- The API's check-in (POST /v1/tickets/:id/check-in) takes a pass id too:
-- the same exos_check_in_ticket call, which hands it to the pass check-in.
SELECT pg_temp.exos_patch_n('public.exos_api_write(uuid, text, text, jsonb, text)', '/* exos: addon pass api */',
  '    SELECT t.event_id INTO v_event FROM public.exos_tickets t WHERE t.id = v_id AND t.org_id = v_org;',
  '    SELECT t.event_id INTO v_event FROM public.exos_tickets t WHERE t.id = v_id AND t.org_id = v_org;
    IF v_event IS NULL AND p_action = ''ticket.check_in'' THEN /* exos: addon pass api */
      SELECT ps.event_id INTO v_event FROM public.exos_addon_passes ps WHERE ps.id = v_id AND ps.org_id = v_org;
    END IF;', 1);

-- The holder's passes, with the secret to draw the rotating code.
CREATE OR REPLACE FUNCTION public.exos_my_addon_passes(p_event_id uuid DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'exos_my_addon_passes: not authenticated' USING ERRCODE = '42501';
  END IF;
  RETURN coalesce((
    SELECT jsonb_agg(jsonb_build_object(
             'id', p.id, 'event_id', p.event_id, 'addon_id', p.addon_id, 'addon_name', p.addon_name,
             'unit_index', p.unit_index, 'status', p.status, 'check_in_at', p.check_in_at,
             'owner_id', p.owner_id, 'barcode_secret', CASE WHEN p.status = 'voided' THEN NULL ELSE p.barcode_secret END,
             'event_name', e.name, 'starts_at', e.starts_at)
             ORDER BY e.starts_at, p.addon_name, p.created_at, p.unit_index)
      FROM public.exos_addon_passes p
      JOIN public.exos_events e ON e.id = p.event_id
     WHERE p.owner_id = auth.uid() AND (p_event_id IS NULL OR p.event_id = p_event_id)), '[]'::jsonb);
END $$;
REVOKE ALL ON FUNCTION public.exos_my_addon_passes(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_my_addon_passes(uuid) TO authenticated, service_role;

-- Staff: an event's passes and their door keys (never the secret), for the
-- door's saved list. Door roles of the event only.
CREATE OR REPLACE FUNCTION public.exos_event_addon_passes(p_event_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_org uuid;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'exos_event_addon_passes: not authenticated' USING ERRCODE = '42501';
  END IF;
  SELECT org_id INTO v_org FROM public.exos_events WHERE id = p_event_id;
  IF v_org IS NULL OR NOT (public.exos_is_admin()
       OR (public.exos_has_org_role(v_org, ARRAY['owner', 'manager', 'scanner']) AND public.exos_can_door_event(p_event_id))) THEN
    RAISE EXCEPTION 'exos_event_addon_passes: not authorized for this event' USING ERRCODE = '42501';
  END IF;
  RETURN coalesce((
    SELECT jsonb_agg(jsonb_build_object(
             'id', p.id, 'addon_id', p.addon_id, 'addon_name', p.addon_name, 'owner_id', p.owner_id,
             'status', p.status, 'door_keys', CASE WHEN p.status = 'voided' THEN jsonb_build_object('d', '{}'::jsonb)
                                                   ELSE jsonb_build_object('d', public._exos_door_keys(p.id, NULL, p.barcode_secret)->'d') END,
             'list_state', (SELECT jsonb_object_agg(x.list_id, x.direction)
                              FROM (SELECT DISTINCT ON (c.list_id) c.list_id, c.direction
                                      FROM public.exos_addon_pass_checkins c
                                     WHERE c.pass_id = p.id AND c.list_id IS NOT NULL
                                     ORDER BY c.list_id, coalesce(c.offline_scanned_at, c.scanned_at) DESC, c.scanned_at DESC) x))
             ORDER BY p.created_at, p.unit_index)
      FROM public.exos_addon_passes p WHERE p.event_id = p_event_id), '[]'::jsonb);
END $$;
REVOKE ALL ON FUNCTION public.exos_event_addon_passes(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_event_addon_passes(uuid) TO authenticated, service_role;

-- ===========================================================================
-- 3. Conditional checkout questions
-- ===========================================================================
ALTER TABLE public.exos_event_questions ADD COLUMN IF NOT EXISTS parent_question_id uuid
  REFERENCES public.exos_event_questions (id) ON DELETE SET NULL;
ALTER TABLE public.exos_event_questions ADD COLUMN IF NOT EXISTS parent_values text[];
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'exos_event_questions_condition_chk') THEN
    ALTER TABLE public.exos_event_questions ADD CONSTRAINT exos_event_questions_condition_chk CHECK (
      (parent_question_id IS NULL AND parent_values IS NULL)
      OR (parent_question_id IS NOT NULL AND parent_question_id <> id
          AND cardinality(parent_values) BETWEEN 1 AND 50));
  END IF;
END $$;
CREATE INDEX IF NOT EXISTS exos_event_questions_parent_idx ON public.exos_event_questions (parent_question_id)
  WHERE parent_question_id IS NOT NULL;

-- The question as jsonb: + its condition (mig 20261107110000).
CREATE OR REPLACE FUNCTION public._exos_question_def(q public.exos_event_questions)
RETURNS jsonb LANGUAGE sql STABLE SET search_path = public, pg_temp AS $$
  SELECT jsonb_build_object(
    'id', q.id, 'event_id', q.event_id, 'label', q.label, 'help_text', q.help_text, 'kind', q.kind,
    'options', to_jsonb(q.options), 'required', q.required, 'scope', q.scope,
    'tier_ids', CASE WHEN q.tier_ids IS NULL THEN NULL ELSE to_jsonb(q.tier_ids) END,
    'max_length', q.max_length, 'min_choices', q.min_choices, 'max_choices', q.max_choices,
    'min_value', q.min_value, 'max_value', q.max_value, 'sort_order', q.sort_order,
    'hidden', q.hidden, 'archived', q.archived_at IS NOT NULL, 'archived_at', q.archived_at,
    'created_at', q.created_at, 'updated_at', q.updated_at,
    'parent_question_id', q.parent_question_id,
    'parent_values', CASE WHEN q.parent_values IS NULL THEN NULL ELSE to_jsonb(q.parent_values) END)
$$;
REVOKE ALL ON FUNCTION public._exos_question_def(public.exos_event_questions) FROM PUBLIC, anon, authenticated;

-- Does the parent's raw answer meet the condition? Empty or invalid: no.
-- A choice matches one of the values; a multiple choice when any picked one
-- does; a checkbox when ticked and the values hold 'true'.
CREATE OR REPLACE FUNCTION public._exos_condition_met(p_parent jsonb, p_raw jsonb, p_values jsonb)
RETURNS boolean LANGUAGE plpgsql IMMUTABLE SET search_path = public, pg_temp AS $$
DECLARE
  r jsonb;
  v jsonb;
  vals text[];
BEGIN
  IF jsonb_typeof(p_values) IS DISTINCT FROM 'array' OR public._exos_answer_is_empty(p_raw) THEN
    RETURN false;
  END IF;
  vals := ARRAY(SELECT jsonb_array_elements_text(p_values));
  r := public._exos_normalize_answer(p_parent, p_raw);
  IF r ? 'problem' THEN RETURN false; END IF;
  v := r->'value';
  IF jsonb_typeof(v) = 'array' THEN
    RETURN EXISTS (SELECT 1 FROM jsonb_array_elements_text(v) x WHERE x = ANY (vals));
  ELSIF jsonb_typeof(v) = 'boolean' THEN
    RETURN v = 'true'::jsonb AND 'true' = ANY (vals);
  END IF;
  RETURN (v #>> '{}') = ANY (vals);
END $$;

-- Is question p_q shown, for the order (p_ticket NULL) or for ticket p_ticket?
-- A question with no parent is; otherwise its parent must be one of p_qs,
-- asked here (its ticket types), shown itself, and answered with one of the
-- values. More than 10 levels: hidden.
CREATE OR REPLACE FUNCTION public._exos_question_shown(
  p_qs jsonb, p_q jsonb, p_ticket int, p_ticket_tiers uuid[], p_order jsonb, p_tickets jsonb, p_depth int)
RETURNS boolean LANGUAGE plpgsql IMMUTABLE SET search_path = public, pg_temp AS $$
DECLARE
  v_pid text := nullif(p_q->>'parent_question_id', '');
  p     jsonb;
  v_t   jsonb;
BEGIN
  IF v_pid IS NULL THEN RETURN true; END IF;
  IF p_depth >= 10 THEN RETURN false; END IF;
  p := (SELECT x FROM jsonb_array_elements(p_qs) x WHERE x->>'id' = v_pid LIMIT 1);
  IF p IS NULL THEN RETURN false; END IF;
  IF p->>'scope' = 'order' THEN
    IF NOT EXISTS (SELECT 1 FROM unnest(p_ticket_tiers) tt WHERE public._exos_question_applies(p, tt)) THEN
      RETURN false;
    END IF;
    IF NOT public._exos_question_shown(p_qs, p, NULL, p_ticket_tiers, p_order, p_tickets, p_depth + 1) THEN
      RETURN false;
    END IF;
    RETURN public._exos_condition_met(p, p_order->v_pid, p_q->'parent_values');
  END IF;
  -- A per-ticket parent: only for the same ticket.
  IF p_ticket IS NULL OR NOT public._exos_question_applies(p, p_ticket_tiers[p_ticket]) THEN
    RETURN false;
  END IF;
  IF NOT public._exos_question_shown(p_qs, p, p_ticket, p_ticket_tiers, p_order, p_tickets, p_depth + 1) THEN
    RETURN false;
  END IF;
  v_t := p_tickets->(p_ticket - 1);
  IF v_t IS NULL OR jsonb_typeof(v_t) <> 'object' THEN RETURN false; END IF;
  RETURN public._exos_condition_met(p, v_t->v_pid, p_q->'parent_values');
END $$;

-- The questions hidden by their conditions: {"order": {<id>: true},
-- "tickets": [{<id>: true}, ...]} (one object per ticket).
CREATE OR REPLACE FUNCTION public._exos_question_hidden(
  p_qs jsonb, p_ticket_tiers uuid[], p_order jsonb, p_tickets jsonb)
RETURNS jsonb LANGUAGE plpgsql IMMUTABLE SET search_path = public, pg_temp AS $$
DECLARE
  v_qs    jsonb := CASE WHEN jsonb_typeof(p_qs) = 'array' THEN p_qs ELSE '[]'::jsonb END;
  v_ord   jsonb := CASE WHEN jsonb_typeof(p_order) = 'object' THEN p_order ELSE '{}'::jsonb END;
  v_tix   jsonb := CASE WHEN jsonb_typeof(p_tickets) = 'array' THEN p_tickets ELSE '[]'::jsonb END;
  v_n     int := coalesce(cardinality(p_ticket_tiers), 0);
  v_hid_o jsonb := '{}'::jsonb;
  v_hid_t jsonb := '[]'::jsonb;
  v_row   jsonb;
  q       jsonb;
  i       int;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_qs) x WHERE nullif(x->>'parent_question_id', '') IS NOT NULL) THEN
    RETURN jsonb_build_object('order', '{}'::jsonb, 'tickets', '[]'::jsonb);
  END IF;
  FOR q IN SELECT x FROM jsonb_array_elements(v_qs) x WHERE x->>'scope' = 'order' AND nullif(x->>'parent_question_id', '') IS NOT NULL LOOP
    IF NOT public._exos_question_shown(v_qs, q, NULL, p_ticket_tiers, v_ord, v_tix, 0) THEN
      v_hid_o := v_hid_o || jsonb_build_object(q->>'id', true);
    END IF;
  END LOOP;
  FOR i IN 1..v_n LOOP
    v_row := '{}'::jsonb;
    FOR q IN SELECT x FROM jsonb_array_elements(v_qs) x WHERE x->>'scope' = 'ticket' AND nullif(x->>'parent_question_id', '') IS NOT NULL LOOP
      IF NOT public._exos_question_shown(v_qs, q, i, p_ticket_tiers, v_ord, v_tix, 0) THEN
        v_row := v_row || jsonb_build_object(q->>'id', true);
      END IF;
    END LOOP;
    v_hid_t := v_hid_t || jsonb_build_array(v_row);
  END LOOP;
  RETURN jsonb_build_object('order', v_hid_o, 'tickets', v_hid_t);
END $$;

REVOKE ALL ON FUNCTION public._exos_condition_met(jsonb, jsonb, jsonb) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._exos_question_shown(jsonb, jsonb, int, uuid[], jsonb, jsonb, int) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._exos_question_hidden(jsonb, uuid[], jsonb, jsonb) FROM PUBLIC, anon, authenticated;

-- The rules: hidden questions are skipped (never required, answer dropped).
SELECT pg_temp.exos_patch_n('public._exos_validate_answers_core(jsonb, uuid[], jsonb, boolean)',
  '/* exos: conditional questions 1 */',
  '  bad     CONSTANT jsonb := ''{"ok": false, "answers": null}''::jsonb;',
  '  bad     CONSTANT jsonb := ''{"ok": false, "answers": null}''::jsonb;
  /* exos: conditional questions 1 */ -- mig 20261107110000: what conditions hide.
  v_hid_o jsonb := ''{}''::jsonb;
  v_hid_t jsonb := ''[]''::jsonb;
  v_hid   jsonb;', 1);
SELECT pg_temp.exos_patch_n('public._exos_validate_answers_core(jsonb, uuid[], jsonb, boolean)',
  '/* exos: conditional questions 2 */',
  '  -- Order-wide questions.',
  '  /* exos: conditional questions 2 */
  v_hid := public._exos_question_hidden(v_qs, p_ticket_tiers, v_order, v_tix);
  v_hid_o := coalesce(v_hid->''order'', ''{}''::jsonb);
  v_hid_t := coalesce(v_hid->''tickets'', ''[]''::jsonb);

  -- Order-wide questions.', 1);
SELECT pg_temp.exos_patch_n('public._exos_validate_answers_core(jsonb, uuid[], jsonb, boolean)',
  '/* exos: conditional questions 3 */',
  '    CONTINUE WHEN q->>''scope'' <> ''order''
               OR NOT EXISTS (SELECT 1 FROM unnest(p_ticket_tiers) tt WHERE public._exos_question_applies(q, tt));',
  '    CONTINUE WHEN q->>''scope'' <> ''order''
               OR NOT EXISTS (SELECT 1 FROM unnest(p_ticket_tiers) tt WHERE public._exos_question_applies(q, tt))
               OR v_hid_o ? (q->>''id'') /* exos: conditional questions 3 */;', 1);
SELECT pg_temp.exos_patch_n('public._exos_validate_answers_core(jsonb, uuid[], jsonb, boolean)',
  '/* exos: conditional questions 4 */',
  '      CONTINUE WHEN q->>''scope'' <> ''ticket'' OR NOT public._exos_question_applies(q, p_ticket_tiers[i]);',
  '      CONTINUE WHEN q->>''scope'' <> ''ticket'' OR NOT public._exos_question_applies(q, p_ticket_tiers[i])
                 OR coalesce((v_hid_t->(i - 1)) ? (q->>''id''), false) /* exos: conditional questions 4 */;', 1);

-- A question's condition, or the first problem with it (NULL: fine).
CREATE OR REPLACE FUNCTION public._exos_question_condition_problem(q public.exos_event_questions)
RETURNS text LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  p     public.exos_event_questions%ROWTYPE;
  v_cur uuid;
  v_n   int := 0;
BEGIN
  IF q.parent_question_id IS NULL THEN RETURN NULL; END IF;
  IF q.parent_question_id = q.id THEN RETURN 'a question can''t depend on itself'; END IF;
  SELECT * INTO p FROM public.exos_event_questions WHERE id = q.parent_question_id;
  IF NOT FOUND OR p.event_id <> q.event_id OR p.org_id <> q.org_id THEN
    RETURN 'the question it depends on is not one of this event''s';
  END IF;
  IF p.archived_at IS NOT NULL THEN
    RETURN 'the question it depends on is archived';
  END IF;
  IF p.kind NOT IN ('single_choice', 'multiple_choice', 'checkbox') THEN
    RETURN 'it can depend only on a choice or checkbox question';
  END IF;
  IF q.scope = 'order' AND p.scope <> 'order' THEN
    RETURN 'a question asked once per order can depend only on another per-order question';
  END IF;
  IF q.parent_values IS NULL OR cardinality(q.parent_values) = 0 THEN
    RETURN 'pick the answer that shows it';
  END IF;
  IF p.kind = 'checkbox' THEN
    IF q.parent_values <> ARRAY['true'] THEN RETURN 'a checkbox shows it when ticked (true)'; END IF;
  ELSIF EXISTS (SELECT 1 FROM unnest(q.parent_values) x WHERE NOT (x = ANY (p.options))) THEN
    RETURN 'show it for one of the other question''s options';
  END IF;
  -- No cycles: walking up from the parent never comes back, within 10 levels.
  v_cur := p.id;
  WHILE v_cur IS NOT NULL LOOP
    v_n := v_n + 1;
    IF v_cur = q.id THEN RETURN 'that would make a loop of questions'; END IF;
    IF v_n > 10 THEN RETURN 'at most 10 levels of questions'; END IF;
    SELECT parent_question_id INTO v_cur FROM public.exos_event_questions WHERE id = v_cur;
  END LOOP;
  RETURN NULL;
END $$;
REVOKE ALL ON FUNCTION public._exos_question_condition_problem(public.exos_event_questions) FROM PUBLIC, anon, authenticated;

-- Set (keys present in p) and check a question's condition, and check the
-- questions that depend on it still can. Run by _exos_question_upsert, inside
-- its transaction (a problem undoes the whole save).
CREATE OR REPLACE FUNCTION public._exos_question_apply_condition(p_id uuid, p jsonb)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  q      public.exos_event_questions%ROWTYPE;
  c      public.exos_event_questions%ROWTYPE;
  v_pid  uuid;
  v_vals text[];
  v_prob text;
BEGIN
  SELECT * INTO q FROM public.exos_event_questions WHERE id = p_id FOR UPDATE;
  IF NOT FOUND THEN RETURN; END IF;
  IF p ? 'parent_question_id' OR p ? 'parent_values' THEN
    v_pid := q.parent_question_id;
    v_vals := q.parent_values;
    IF p ? 'parent_question_id' THEN
      IF jsonb_typeof(p->'parent_question_id') = 'null' OR btrim(coalesce(p->>'parent_question_id', '')) = '' THEN
        v_pid := NULL;
      ELSE
        BEGIN
          v_pid := (p->>'parent_question_id')::uuid;
        EXCEPTION WHEN invalid_text_representation THEN
          RAISE EXCEPTION 'parent_question_id must be a question id' USING ERRCODE = '22023';
        END;
      END IF;
    END IF;
    IF p ? 'parent_values' THEN
      IF jsonb_typeof(p->'parent_values') = 'null' THEN
        v_vals := NULL;
      ELSIF jsonb_typeof(p->'parent_values') <> 'array'
            OR EXISTS (SELECT 1 FROM jsonb_array_elements(p->'parent_values') e WHERE jsonb_typeof(e) NOT IN ('string', 'boolean')) THEN
        RAISE EXCEPTION 'parent_values must be a list of the other question''s options' USING ERRCODE = '22023';
      ELSE
        v_vals := ARRAY(SELECT DISTINCT btrim(x, E' \t\r\n') FROM jsonb_array_elements_text(p->'parent_values') x
                         WHERE btrim(x, E' \t\r\n') <> '' ORDER BY 1);
        IF cardinality(v_vals) > 50 OR EXISTS (SELECT 1 FROM unnest(v_vals) x WHERE char_length(x) > 200) THEN
          RAISE EXCEPTION 'parent_values: at most 50 values of 1 to 200 characters' USING ERRCODE = '22023';
        END IF;
      END IF;
    END IF;
    IF v_pid IS NULL THEN
      v_vals := NULL;
    ELSIF v_pid = q.id THEN
      RAISE EXCEPTION 'show only if: a question can''t depend on itself' USING ERRCODE = '22023';
    ELSIF v_vals IS NULL OR cardinality(v_vals) = 0 THEN
      RAISE EXCEPTION 'pick the answer that shows this question' USING ERRCODE = '22023';
    END IF;
    IF v_pid IS NOT NULL AND NOT EXISTS (SELECT 1 FROM public.exos_event_questions x
                                          WHERE x.id = v_pid AND x.event_id = q.event_id AND x.org_id = q.org_id) THEN
      -- Never echo another event's (or org's) question.
      RAISE EXCEPTION 'the question it depends on is not one of this event''s' USING ERRCODE = '22023';
    END IF;
    IF v_pid IS DISTINCT FROM q.parent_question_id OR v_vals IS DISTINCT FROM q.parent_values THEN
      UPDATE public.exos_event_questions SET parent_question_id = v_pid, parent_values = v_vals WHERE id = q.id;
      SELECT * INTO q FROM public.exos_event_questions WHERE id = p_id;
    END IF;
  END IF;
  IF q.archived_at IS NULL THEN
    v_prob := public._exos_question_condition_problem(q);
    IF v_prob IS NOT NULL THEN
      RAISE EXCEPTION 'show only if: %', v_prob USING ERRCODE = '22023';
    END IF;
  END IF;
  FOR c IN SELECT * FROM public.exos_event_questions WHERE parent_question_id = p_id AND archived_at IS NULL ORDER BY sort_order, id LOOP
    v_prob := public._exos_question_condition_problem(c);
    IF v_prob IS NOT NULL THEN
      RAISE EXCEPTION 'question "%" is shown by this one (%): change or remove its condition first', left(c.label, 80), v_prob
        USING ERRCODE = '22023';
    END IF;
  END LOOP;
END $$;
REVOKE ALL ON FUNCTION public._exos_question_apply_condition(uuid, jsonb) FROM PUBLIC, anon, authenticated;

SELECT pg_temp.exos_patch_n('public._exos_question_upsert(uuid, uuid, uuid, jsonb, uuid)',
  '/* exos: conditional questions */',
  '''hidden'', ''archived'', ''sort_order''];',
  '''hidden'', ''archived'', ''sort_order'',
    ''parent_question_id'', ''parent_values'' /* exos: conditional questions */];', 1);
SELECT pg_temp.exos_patch_n('public._exos_question_upsert(uuid, uuid, uuid, jsonb, uuid)',
  '/* exos: conditional questions apply */',
  '  SELECT * INTO q FROM public.exos_event_questions WHERE id = q.id;',
  '  PERFORM public._exos_question_apply_condition(q.id, p); /* exos: conditional questions apply */
  SELECT * INTO q FROM public.exos_event_questions WHERE id = q.id;', 1);

-- The free-claim guard: only questions every buyer is asked can be required
-- of a claim with no answers (a conditional one is hidden then).
SELECT pg_temp.exos_patch_n('public._exos_required_questions_for(uuid, uuid[])', '/* exos: conditional questions */',
  'AND NOT q.hidden AND q.required',
  'AND NOT q.hidden AND q.required AND q.parent_question_id IS NULL /* exos: conditional questions */', 1);
