-- ============================================================================
-- Migration 20261108110000 — Exos: the DICE leftovers (KANBAN "DICE gaps
-- 2026-11-05", the "Left:" parts of items 2, 5 and 6)
-- ============================================================================
-- Branch: claude/exos-dice-leftovers
--
-- 1. Walk-up sales answer checkout questions (item 2).
--    A walk-up mint (_exos_pos_walkup_begin, mig 20261107100000; cash, comp and
--    card through _exos_pos_walkup_begin_card, mig 20261107130000) recorded
--    answers as optional. Now the event's required questions are required at
--    the door too, per order and per ticket, with "show only if" conditions
--    (mig 20261107110000): a question its condition hides is never required.
--    Questions hidden from checkout ("staff fill it at the door") are asked at
--    the door but never required. Answers are stored exactly like online ones
--    (_exos_record_answers, order ref 'pos:<order>', attached to the n-th
--    ticket minted), source 'door'.
--    Keeping the door fast: the seller may SKIP the questions. The skip is an
--    explicit flag on the sale (exos_pos_walkup_sell's 13-argument overload,
--    _exos_pos_walkup_begin_card's 11-argument one, exos-pos
--    `skip_questions: true`); without it a missing required answer refuses the
--    sale (22023, HINT 'questions-required'). With it the sale goes through,
--    whatever answers were given are kept, and one exos_pos_question_skips
--    row records who skipped which required questions (nothing is logged when
--    nothing required was missing). The flag reaches the begin through a
--    transaction-local setting (exos.pos_skip_questions) that only those
--    wrappers set, so no existing signature changes.
--    Marker patch on _exos_pos_walkup_begin (/* exos: pos walkup questions */).
--
-- 2. Manual fee adjustments through the API (item 6).
--    POST /v1/orders/:id/adjustments (finance:write): _exos_api_fee_adjustment
--    checks the key's creator in SQL (_exos_api_key_actor: owner / manager /
--    finance, the dashboard's exos_fee_adjustment_record rule), then the same
--    core (_exos_fee_adjustment_add: integer cents, a note, never below zero,
--    the order looked up in the key's org only). An idempotency key is
--    required (the Idempotency-Key header or the body's idempotency_key): a
--    resend answers the first row (duplicate: true).
--
-- 3. Undo an add-on scan (item 6).
--    exos_undo_addon_check_in(pass, event, reason, client_ref?, undone_at?,
--    device?) mirrors a ticket's undo (exos_undo_check_in: a reason, the
--    scans removed and kept in an audit row, the pass usable again) with one
--    addition: the scanner who made the pass's last entry may undo it within
--    10 minutes of that scan; anyone else needs an owner or manager. The
--    offline door queues the undo with a client ref and the time it was done;
--    the merge replays it through the same function (the same ref twice is one
--    undo; only scans at or before the undo are removed, so a later entry by
--    another door stands). Logged in exos_addon_pass_undos.
--
-- 4. Add-on entry codes in Apple / Google Wallet (item 6).
--    Apple allows one barcode per pass (the `barcodes` array lists formats of
--    the same message), so each add-on unit with its own entry code gets a
--    pass of its own (exos-wallet POST /addon-pass), not a back field on the
--    ticket's. Codes, with the ticket wallet's derivations over the pass's own
--    secret and an epoch (exos_addon_passes.wallet_epoch, set when the first
--    wallet pass is issued):
--      Apple   A-{pass}:{owner}:a{epoch}:{mac}   static
--      Google  A-{pass}:{owner}:g{epoch}:{totp}  rotating (TOTP)
--    The door takes them in _exos_check_in_addon_pass (marker
--    /* exos: addon wallet codes */), so online, offline replay and the API
--    all do; the door's saved keys carry wa / wg / we for them
--    (exos_event_addon_passes, marker /* exos: addon wallet keys */). A new
--    owner rotates the pass secret (mig 20261107110000), which kills every
--    earlier wallet code; a refund voids the pass.
--
-- Touches:  C: TABLE exos_pos_question_skips, exos_addon_pass_undos
--           W: TABLE exos_addon_passes (+wallet_epoch)
--           C: FUNCTION _exos_pos_door_question_defs, _exos_pos_walkup_answers,
--              exos_pos_walkup_sell (13 args), _exos_pos_walkup_begin_card
--              (11 args), _exos_api_fee_adjustment, exos_undo_addon_check_in,
--              _exos_addon_wallet_apple_code, _exos_addon_wallet_check,
--              _exos_addon_door_keys, exos_wallet_addon_pass
--           P: _exos_pos_walkup_begin, _exos_check_in_addon_pass,
--              exos_event_addon_passes
-- Grants:   authenticated: exos_pos_walkup_sell (13 args; role checked in SQL),
--              exos_undo_addon_check_in (door staff; checked inside),
--              exos_wallet_addon_pass (the pass's holder only)
--           service_role: everything; no anon function
-- Pre-reqs: 20261107100000 (walk-up), 20261107110000 (fee log, add-on
--           passes, conditional questions), 20261107130000 (card begin),
--           20260929072000 (wallet code derivations), 20261019100000 (door keys),
--           20261104180000 (_exos_api_key_actor)
-- Additive and re-run safe. No cron.
-- ============================================================================

-- Marker-checked patches (pg_temp.exos_patch_n, as 20261107110000).
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
-- 1. Walk-up sales answer checkout questions
-- ===========================================================================
CREATE TABLE IF NOT EXISTS public.exos_pos_question_skips (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id       uuid NOT NULL REFERENCES public.exos_orgs (id) ON DELETE CASCADE,
  event_id     uuid NOT NULL REFERENCES public.exos_events (id) ON DELETE CASCADE,
  pos_order_id uuid NOT NULL REFERENCES public.exos_pos_orders (id) ON DELETE CASCADE,
  order_ref    text NOT NULL,
  skipped_by   uuid NOT NULL,
  -- The required questions left unanswered: [{question_id, label, ticket}].
  missing      jsonb NOT NULL,
  created_at   timestamptz NOT NULL DEFAULT now(),
  updated_at   timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT exos_pos_question_skips_missing_chk CHECK (jsonb_typeof(missing) = 'array' AND octet_length(missing::text) <= 20000),
  UNIQUE (pos_order_id)
);
CREATE INDEX IF NOT EXISTS exos_pos_question_skips_event_idx ON public.exos_pos_question_skips (event_id, created_at);
CREATE INDEX IF NOT EXISTS exos_pos_question_skips_org_idx ON public.exos_pos_question_skips (org_id);
COMMENT ON TABLE public.exos_pos_question_skips IS
  'A walk-up sale whose seller skipped required checkout questions (mig 20261108110000): who, when, which.';
DROP TRIGGER IF EXISTS exos_pos_question_skips_touch ON public.exos_pos_question_skips;
CREATE TRIGGER exos_pos_question_skips_touch BEFORE UPDATE ON public.exos_pos_question_skips
  FOR EACH ROW EXECUTE FUNCTION public.exos_touch_updated_at();
ALTER TABLE public.exos_pos_question_skips ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS exos_pos_question_skips_sel ON public.exos_pos_question_skips;
CREATE POLICY exos_pos_question_skips_sel ON public.exos_pos_question_skips FOR SELECT TO authenticated
  USING (public.exos_is_admin() OR public.exos_has_org_role(org_id, ARRAY['owner', 'manager', 'finance'])
         OR public.exos_can_door_event(event_id));
REVOKE ALL ON public.exos_pos_question_skips FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.exos_pos_question_skips TO authenticated;
GRANT ALL ON public.exos_pos_question_skips TO service_role;

-- The questions the door asks: every active one, hidden ones included (staff
-- fill those at the door), but a hidden one is never required there.
CREATE OR REPLACE FUNCTION public._exos_pos_door_question_defs(p_event uuid)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT coalesce(jsonb_agg(CASE WHEN (d ->> 'hidden')::boolean IS TRUE THEN d || '{"required": false}'::jsonb ELSE d END
                            ORDER BY o), '[]'::jsonb)
    FROM jsonb_array_elements(public._exos_question_defs(p_event, true)) WITH ORDINALITY x(d, o)
$$;
REVOKE ALL ON FUNCTION public._exos_pos_door_question_defs(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_pos_door_question_defs(uuid) TO service_role;

-- A walk-up sale's answers: required ones (shown, not hidden from checkout)
-- must be there unless the seller skipped them; stored as online answers.
CREATE OR REPLACE FUNCTION public._exos_pos_walkup_answers(
  p_org uuid, p_event uuid, p_order uuid, p_tier uuid, p_qty integer, p_answers jsonb, p_actor uuid)
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  v_skip    boolean := coalesce(current_setting('exos.pos_skip_questions', true), '') = 'on';
  v_tiers   uuid[];
  v_defs    jsonb;
  v_body    jsonb := CASE WHEN p_answers IS NOT NULL AND jsonb_typeof(p_answers) = 'object' THEN p_answers ELSE '{}'::jsonb END;
  v_res     jsonb;
  v_missing jsonb;
  v_first   text;
  v_n       int := 0;
BEGIN
  v_defs := public._exos_pos_door_question_defs(p_event);
  IF jsonb_array_length(v_defs) = 0 OR coalesce(p_qty, 0) < 1 THEN
    RETURN 0;
  END IF;
  v_tiers := array_fill(p_tier, ARRAY[p_qty]);
  v_res := public._exos_validate_answers_core(v_defs, v_tiers, v_body, true);
  SELECT jsonb_agg(jsonb_build_object('question_id', p ->> 'question_id', 'ticket', p -> 'ticket',
                                      'label', (SELECT q.label FROM public.exos_event_questions q
                                                 WHERE q.event_id = p_event AND q.id::text = p ->> 'question_id'))
                   ORDER BY o)
    INTO v_missing
    FROM jsonb_array_elements(coalesce(v_res -> 'problems', '[]'::jsonb)) WITH ORDINALITY x(p, o)
   WHERE p ->> 'code' = 'required';
  IF v_missing IS NOT NULL AND NOT v_skip THEN
    v_first := v_missing -> 0 ->> 'label';
    RAISE EXCEPTION 'answer the required questions or skip them (% unanswered, first: "%")',
      jsonb_array_length(v_missing), left(coalesce(v_first, '?'), 120)
      USING ERRCODE = '22023', HINT = 'questions-required', DETAIL = v_missing::text;
  END IF;
  IF p_answers IS NOT NULL AND jsonb_typeof(p_answers) = 'object' THEN
    v_n := public._exos_record_answers(p_org, p_event, 'pos:' || p_order::text, v_tiers, p_answers, false, true, 'door', p_actor);
  END IF;
  IF v_missing IS NOT NULL THEN
    INSERT INTO public.exos_pos_question_skips (org_id, event_id, pos_order_id, order_ref, skipped_by, missing)
    VALUES (p_org, p_event, p_order, 'pos:' || p_order::text, p_actor, v_missing)
    ON CONFLICT (pos_order_id) DO NOTHING;
  END IF;
  RETURN v_n;
END $$;
REVOKE ALL ON FUNCTION public._exos_pos_walkup_answers(uuid, uuid, uuid, uuid, integer, jsonb, uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_pos_walkup_answers(uuid, uuid, uuid, uuid, integer, jsonb, uuid) TO service_role;

SELECT pg_temp.exos_patch_n(
  'public._exos_pos_walkup_begin(uuid, text, uuid, uuid, integer, integer, uuid, uuid, text, text, jsonb, integer)',
  '/* exos: pos walkup questions */',
  '  -- Checkout questions: optional at the door (never required), hidden ones too.
  IF p_answers IS NOT NULL AND jsonb_typeof(p_answers) = ''object'' THEN
    PERFORM public._exos_record_answers(ev.org_id, p_event, ''pos:'' || v_order::text, array_fill(p_tier, ARRAY[v_qty]),
                                        p_answers, false, true, ''door'', p_actor);
  END IF;',
  '  -- Checkout questions: required ones too, unless the seller skipped them (logged); hidden ones optional.
  /* exos: pos walkup questions */ -- mig 20261108110000
  PERFORM public._exos_pos_walkup_answers(ev.org_id, p_event, v_order, p_tier, v_qty, p_answers, p_actor);', 1);

-- The sale, with the explicit "skip questions" action. Same checks as the
-- 12-argument one (it calls it); the flag lives for this call only.
CREATE OR REPLACE FUNCTION public.exos_pos_walkup_sell(
  p_event_id uuid, p_tier_id uuid, p_quantity integer, p_order_key uuid,
  p_comp_quantity integer, p_payment text, p_device_id uuid,
  p_drawer_id uuid, p_buyer_name text, p_buyer_email text,
  p_answers jsonb, p_comp_reason text, p_skip_questions boolean
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_out jsonb;
BEGIN
  PERFORM set_config('exos.pos_skip_questions', CASE WHEN p_skip_questions THEN 'on' ELSE '' END, true);
  v_out := public._exos_pos_walkup_sell(auth.uid(), public.exos_is_admin(), p_event_id, p_tier_id, p_quantity, p_order_key,
                                        coalesce(p_comp_quantity, 0), coalesce(p_payment, 'cash'), p_device_id, p_drawer_id,
                                        p_buyer_name, p_buyer_email, p_answers, p_comp_reason);
  PERFORM set_config('exos.pos_skip_questions', '', true);
  RETURN v_out || jsonb_build_object('questions_skipped',
    EXISTS (SELECT 1 FROM public.exos_pos_question_skips s WHERE s.pos_order_id = (v_out ->> 'id')::uuid));
END $$;
REVOKE ALL ON FUNCTION public.exos_pos_walkup_sell(uuid, uuid, integer, uuid, integer, text, uuid, uuid, text, text, jsonb, text, boolean)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_pos_walkup_sell(uuid, uuid, integer, uuid, integer, text, uuid, uuid, text, text, jsonb, text, boolean)
  TO authenticated, service_role;

-- Card at the door: the same flag.
CREATE OR REPLACE FUNCTION public._exos_pos_walkup_begin_card(
  p_actor uuid, p_event_id uuid, p_tier_id uuid, p_quantity integer, p_order_key uuid, p_device_id uuid,
  p_buyer_name text, p_buyer_email text, p_answers jsonb, p_live boolean, p_skip_questions boolean
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_out jsonb;
BEGIN
  PERFORM set_config('exos.pos_skip_questions', CASE WHEN p_skip_questions THEN 'on' ELSE '' END, true);
  v_out := public._exos_pos_walkup_begin_card(p_actor, p_event_id, p_tier_id, p_quantity, p_order_key, p_device_id,
                                              p_buyer_name, p_buyer_email, p_answers, p_live);
  PERFORM set_config('exos.pos_skip_questions', '', true);
  RETURN v_out || jsonb_build_object('questions_skipped',
    EXISTS (SELECT 1 FROM public.exos_pos_question_skips s WHERE s.pos_order_id = (v_out ->> 'id')::uuid));
END $$;
REVOKE ALL ON FUNCTION public._exos_pos_walkup_begin_card(uuid, uuid, uuid, integer, uuid, uuid, text, text, jsonb, boolean, boolean)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_pos_walkup_begin_card(uuid, uuid, uuid, integer, uuid, uuid, text, text, jsonb, boolean, boolean)
  TO service_role;

-- ===========================================================================
-- 2. Manual fee adjustments through the API
-- ===========================================================================
-- POST /v1/orders/:id/adjustments (finance:write). The key's creator must be
-- an owner, manager or finance member now (the dashboard's rule); the order
-- is looked up in the key's org only (another org's: 'order not found').
CREATE OR REPLACE FUNCTION public._exos_api_fee_adjustment(
  p_org uuid, p_api_key uuid, p_session_id text, p_cents bigint, p_note text, p_ticket_id uuid, p_idem text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_actor uuid;
BEGIN
  v_actor := public._exos_api_key_actor(p_org, p_api_key, ARRAY['owner', 'manager', 'finance']);
  IF nullif(btrim(coalesce(p_idem, '')), '') IS NULL THEN
    RAISE EXCEPTION 'an idempotency key is required (the Idempotency-Key header or idempotency_key)' USING ERRCODE = '22023';
  END IF;
  RETURN public._exos_fee_adjustment_add(p_org, p_session_id, p_ticket_id, p_cents, p_note, v_actor, p_api_key, p_idem);
END $$;
REVOKE ALL ON FUNCTION public._exos_api_fee_adjustment(uuid, uuid, text, bigint, text, uuid, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_api_fee_adjustment(uuid, uuid, text, bigint, text, uuid, text) TO service_role;

-- ===========================================================================
-- 3. Undo an add-on scan
-- ===========================================================================
CREATE TABLE IF NOT EXISTS public.exos_addon_pass_undos (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id            uuid NOT NULL REFERENCES public.exos_orgs (id) ON DELETE CASCADE,
  event_id          uuid NOT NULL REFERENCES public.exos_events (id) ON DELETE CASCADE,
  pass_id           uuid NOT NULL REFERENCES public.exos_addon_passes (id) ON DELETE CASCADE,
  -- The scans removed, as they were.
  checkins          jsonb NOT NULL DEFAULT '[]'::jsonb,
  reason            text NOT NULL CHECK (char_length(reason) BETWEEN 3 AND 300),
  undone_by         uuid NOT NULL,
  -- 'manager' (an owner / manager) or 'scanner' (their own scan, in the window).
  undone_as         text NOT NULL CHECK (undone_as IN ('manager', 'scanner')),
  -- The offline door's per-undo nonce (the same ref twice is one undo).
  client_ref        uuid UNIQUE,
  offline_undone_at timestamptz,
  device            text,
  undone_at         timestamptz NOT NULL DEFAULT now(),
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS exos_addon_pass_undos_pass_idx ON public.exos_addon_pass_undos (pass_id);
CREATE INDEX IF NOT EXISTS exos_addon_pass_undos_event_idx ON public.exos_addon_pass_undos (event_id, undone_at);
CREATE INDEX IF NOT EXISTS exos_addon_pass_undos_org_idx ON public.exos_addon_pass_undos (org_id);
COMMENT ON TABLE public.exos_addon_pass_undos IS
  'An undone add-on check-in (mig 20261108110000): the scans removed, who, why, online or replayed from an offline door.';
DROP TRIGGER IF EXISTS exos_addon_pass_undos_touch ON public.exos_addon_pass_undos;
CREATE TRIGGER exos_addon_pass_undos_touch BEFORE UPDATE ON public.exos_addon_pass_undos
  FOR EACH ROW EXECUTE FUNCTION public.exos_touch_updated_at();
ALTER TABLE public.exos_addon_pass_undos ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS exos_addon_pass_undos_sel ON public.exos_addon_pass_undos;
CREATE POLICY exos_addon_pass_undos_sel ON public.exos_addon_pass_undos FOR SELECT TO authenticated
  USING (public.exos_is_admin() OR public.exos_has_org_role(org_id, ARRAY['owner', 'manager', 'finance'])
         OR public.exos_can_door_event(event_id));
REVOKE ALL ON public.exos_addon_pass_undos FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.exos_addon_pass_undos TO authenticated;
GRANT ALL ON public.exos_addon_pass_undos TO service_role;
DO $$
DECLARE r text; t text;
BEGIN
  FOREACH r IN ARRAY ARRAY['coworker_readonly', 'analyst_ro'] LOOP
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = r) THEN
      FOREACH t IN ARRAY ARRAY['exos_addon_pass_undos', 'exos_pos_question_skips'] LOOP
        EXECUTE format('REVOKE ALL ON public.%I FROM %I', t, r);
      END LOOP;
    END IF;
  END LOOP;
END $$;

-- Undo an add-on check-in. Owner / manager: any of the pass's scans, with a
-- reason (a ticket's rule). The scanner who made the pass's last entry: that
-- one, within 10 minutes of it. Online: now. Offline merge: p_client_ref +
-- p_undone_at (when the door did it, at most 24 hours ago); only scans at or
-- before that time are removed.
CREATE OR REPLACE FUNCTION public.exos_undo_addon_check_in(
  p_pass_id uuid, p_event_id uuid, p_reason text,
  p_client_ref uuid DEFAULT NULL, p_undone_at timestamptz DEFAULT NULL, p_device text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  v_uid     uuid := auth.uid();
  ps        public.exos_addon_passes%ROWTYPE;
  u         public.exos_addon_pass_undos%ROWTYPE;
  c         public.exos_addon_pass_checkins%ROWTYPE;
  v_manager boolean;
  v_at      timestamptz := coalesce(p_undone_at, clock_timestamp());
  v_rows    jsonb;
  v_n       int;
  v_next    timestamptz;
  v_info    jsonb;
  v_window  CONSTANT interval := interval '10 minutes';  -- ADDON_UNDO_WINDOW_MINUTES (src/lib/addonUndo.ts)
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'exos_undo_addon_check_in: not authenticated' USING ERRCODE = '42501';
  END IF;
  SELECT * INTO ps FROM public.exos_addon_passes WHERE id = p_pass_id FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'not-found', 'kind', 'addon');
  END IF;
  IF NOT (public.exos_is_admin() OR public.exos_has_org_role(ps.org_id, ARRAY['owner', 'manager', 'scanner'])) THEN
    RAISE EXCEPTION 'exos_undo_addon_check_in: not authorized' USING ERRCODE = '42501';
  END IF;
  IF p_event_id IS NULL OR ps.event_id <> p_event_id THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'wrong-event', 'kind', 'addon');
  END IF;
  v_info := jsonb_build_object('kind', 'addon', 'pass_id', ps.id, 'addon_name', ps.addon_name);
  IF NOT public.exos_can_door_event(ps.event_id) THEN
    RETURN v_info || jsonb_build_object('ok', false, 'reason', 'not-assigned');
  END IF;
  v_manager := public.exos_is_admin() OR public.exos_has_org_role(ps.org_id, ARRAY['owner', 'manager']);
  -- A replayed undo: the same answer, once.
  IF p_client_ref IS NOT NULL THEN
    SELECT * INTO u FROM public.exos_addon_pass_undos WHERE client_ref = p_client_ref;
    IF FOUND THEN
      IF u.pass_id <> ps.id THEN
        RETURN v_info || jsonb_build_object('ok', false, 'reason', 'bad-client-ref');
      END IF;
      RETURN v_info || jsonb_build_object('ok', true, 'reason', 'undone', 'duplicate', true, 'status', ps.status);
    END IF;
  END IF;
  IF length(btrim(coalesce(p_reason, ''))) < 3 THEN
    RETURN v_info || jsonb_build_object('ok', false, 'reason', 'reason-required');
  END IF;
  IF p_undone_at IS NOT NULL AND (p_undone_at > now() + interval '5 minutes' OR p_undone_at < now() - interval '24 hours') THEN
    RETURN v_info || jsonb_build_object('ok', false, 'reason', 'bad-undo-time');
  END IF;
  IF ps.status = 'voided' THEN
    RETURN v_info || jsonb_build_object('ok', false, 'reason', 'voided');
  END IF;
  -- The pass's last entry at or before the undo.
  SELECT * INTO c FROM public.exos_addon_pass_checkins
   WHERE pass_id = ps.id AND direction = 'entry' AND coalesce(offline_scanned_at, scanned_at) <= v_at
   ORDER BY coalesce(offline_scanned_at, scanned_at) DESC, scanned_at DESC LIMIT 1;
  IF NOT FOUND THEN
    RETURN v_info || jsonb_build_object('ok', false, 'reason', 'not-checked-in');
  END IF;
  IF NOT v_manager THEN
    IF c.scanned_by IS DISTINCT FROM v_uid THEN
      RETURN v_info || jsonb_build_object('ok', false, 'reason', 'needs-manager');
    END IF;
    IF v_at - coalesce(c.offline_scanned_at, c.scanned_at) > v_window THEN
      RETURN v_info || jsonb_build_object('ok', false, 'reason', 'undo-window-passed', 'window_minutes', 10);
    END IF;
  END IF;

  WITH gone AS (
    DELETE FROM public.exos_addon_pass_checkins
     WHERE pass_id = ps.id AND coalesce(offline_scanned_at, scanned_at) <= v_at RETURNING *
  )
  SELECT count(*), coalesce(jsonb_agg(to_jsonb(gone) ORDER BY gone.scanned_at), '[]'::jsonb) INTO v_n, v_rows FROM gone;
  INSERT INTO public.exos_addon_pass_undos (org_id, event_id, pass_id, checkins, reason, undone_by, undone_as, client_ref,
                                            offline_undone_at, device)
  VALUES (ps.org_id, ps.event_id, ps.id, v_rows, left(btrim(p_reason), 300), v_uid,
          CASE WHEN v_manager THEN 'manager' ELSE 'scanner' END, p_client_ref, p_undone_at,
          nullif(left(btrim(coalesce(p_device, '')), 60), ''));
  -- A later entry (another door, after the undo) still stands.
  SELECT min(coalesce(offline_scanned_at, scanned_at)) INTO v_next FROM public.exos_addon_pass_checkins
   WHERE pass_id = ps.id AND direction = 'entry';
  UPDATE public.exos_addon_passes
     SET status = CASE WHEN v_next IS NULL THEN 'active' ELSE 'used' END, check_in_at = v_next
   WHERE id = ps.id AND status <> 'voided';
  RETURN v_info || jsonb_build_object('ok', true, 'reason', 'undone', 'removed', v_n,
                                      'status', CASE WHEN v_next IS NULL THEN 'active' ELSE 'used' END);
END $$;
REVOKE ALL ON FUNCTION public.exos_undo_addon_check_in(uuid, uuid, text, uuid, timestamptz, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_undo_addon_check_in(uuid, uuid, text, uuid, timestamptz, text) TO authenticated, service_role;

-- ===========================================================================
-- 4. Add-on entry codes in Apple / Google Wallet
-- ===========================================================================
ALTER TABLE public.exos_addon_passes ADD COLUMN IF NOT EXISTS wallet_epoch integer
  CHECK (wallet_epoch IS NULL OR wallet_epoch BETWEEN 1 AND 1000000000);
COMMENT ON COLUMN public.exos_addon_passes.wallet_epoch IS
  'The live wallet code epoch (NULL: no wallet pass issued). A-{pass}:{owner}:a|g{epoch}:… (mig 20261108110000).';

-- The Apple code: the ticket wallet's MAC over the pass's own secret, A- prefix.
CREATE OR REPLACE FUNCTION public._exos_addon_wallet_apple_code(p_pass uuid, p_owner uuid, p_secret text, p_epoch int)
RETURNS text LANGUAGE sql IMMUTABLE SET search_path = public, pg_temp AS $$
  SELECT 'A' || substring(public._exos_wallet_apple_code(p_pass, p_owner, p_secret, p_epoch) FROM 2)
$$;
REVOKE ALL ON FUNCTION public._exos_addon_wallet_apple_code(uuid, uuid, text, int) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_addon_wallet_apple_code(uuid, uuid, text, int) TO service_role;

-- Door check of an add-on wallet code ('ok' or 'barcode-rejected'): the pass's
-- holder, its live epoch, then the MAC (Apple) or the TOTP +-2 steps (Google).
CREATE OR REPLACE FUNCTION public._exos_addon_wallet_check(p_pass uuid, p_payload text, p_at timestamptz)
RETURNS text LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  ps      public.exos_addon_passes%ROWTYPE;
  v_code  text := 'A-' || substring(btrim(coalesce(p_payload, '')) FROM 3);
  v_parts text[] := string_to_array(substring(btrim(coalesce(p_payload, '')) FROM 3), ':');
  v_epoch int;
  v_key   bytea;
  v_cur   bigint;
BEGIN
  SELECT * INTO ps FROM public.exos_addon_passes WHERE id = p_pass;
  IF NOT FOUND OR ps.owner_id IS NULL OR ps.wallet_epoch IS NULL OR ps.barcode_secret IS NULL
     OR upper(left(btrim(coalesce(p_payload, '')), 2)) <> 'A-'
     OR coalesce(array_length(v_parts, 1), 0) <> 4
     OR v_parts[1] <> ps.id::text OR v_parts[2] <> ps.owner_id::text
     OR v_parts[3] !~ '^[ag][0-9]{1,9}$' THEN
    RETURN 'barcode-rejected';
  END IF;
  v_epoch := substring(v_parts[3] FROM 2)::int;
  IF v_epoch <> ps.wallet_epoch THEN
    RETURN 'barcode-rejected';
  END IF;
  IF left(v_parts[3], 1) = 'a' THEN
    RETURN CASE WHEN public._exos_addon_wallet_apple_code(ps.id, ps.owner_id, ps.barcode_secret, v_epoch) = v_code
                THEN 'ok' ELSE 'barcode-rejected' END;
  END IF;
  IF v_parts[4] !~ '^[0-9]{8}$' THEN
    RETURN 'barcode-rejected';
  END IF;
  v_key := public._exos_wallet_google_key(ps.id, ps.owner_id, ps.barcode_secret, v_epoch);
  v_cur := floor(extract(epoch FROM coalesce(p_at, clock_timestamp())) / 30);
  FOR s IN v_cur - 2 .. v_cur + 2 LOOP
    IF public._exos_wallet_totp(v_key, s) = v_parts[4] THEN
      RETURN 'ok';
    END IF;
  END LOOP;
  RETURN 'barcode-rejected';
EXCEPTION WHEN others THEN
  RETURN 'barcode-rejected';
END $$;
REVOKE ALL ON FUNCTION public._exos_addon_wallet_check(uuid, text, timestamptz) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_addon_wallet_check(uuid, text, timestamptz) TO service_role;

SELECT pg_temp.exos_patch_n(
  'public._exos_check_in_addon_pass(uuid, text, text, uuid, text, timestamp with time zone, text, uuid, text)',
  '/* exos: addon wallet codes */',
  '      v_bkt := v_parts[3]::bigint;
      IF abs(v_cur - v_bkt) > 2 THEN
        RETURN v_info || jsonb_build_object(''ok'', false, ''reason'', ''barcode-expired'');
      END IF;
      IF public._exos_door_code_mac(ps.id, ps.owner_id, v_bkt, ps.barcode_secret) IS DISTINCT FROM v_parts[4] THEN
        RETURN v_info || jsonb_build_object(''ok'', false, ''reason'', ''barcode-rejected'');
      END IF;',
  '      /* exos: addon wallet codes */ -- mig 20261108110000: an Apple (a{epoch}) / Google (g{epoch}) wallet pass.
      IF v_parts[3] ~ ''^[ag][0-9]{1,9}$'' THEN
        IF public._exos_addon_wallet_check(ps.id, v_payload, v_scan_at) <> ''ok'' THEN
          RETURN v_info || jsonb_build_object(''ok'', false, ''reason'', ''barcode-rejected'');
        END IF;
      ELSE
      v_bkt := v_parts[3]::bigint;
      IF abs(v_cur - v_bkt) > 2 THEN
        RETURN v_info || jsonb_build_object(''ok'', false, ''reason'', ''barcode-expired'');
      END IF;
      IF public._exos_door_code_mac(ps.id, ps.owner_id, v_bkt, ps.barcode_secret) IS DISTINCT FROM v_parts[4] THEN
        RETURN v_info || jsonb_build_object(''ok'', false, ''reason'', ''barcode-rejected'');
      END IF;
      END IF;', 1);

-- An add-on pass's door keys: the day keys, plus (a wallet pass issued) the
-- Apple code's SHA-256, the Google TOTP key and the epoch. A lost door phone
-- can't make an Apple code from a hash.
CREATE OR REPLACE FUNCTION public._exos_addon_door_keys(p_pass uuid, p_owner uuid, p_secret text, p_epoch int)
RETURNS jsonb LANGUAGE plpgsql STABLE SET search_path = public, pg_temp AS $$
DECLARE v_out jsonb;
BEGIN
  v_out := jsonb_build_object('d', coalesce(public._exos_door_keys(p_pass, NULL, p_secret) -> 'd', '{}'::jsonb));
  IF p_epoch IS NOT NULL AND p_owner IS NOT NULL AND coalesce(p_secret, '') <> '' THEN
    v_out := v_out || jsonb_build_object(
      'we', p_epoch,
      'wa', encode(extensions.digest(public._exos_addon_wallet_apple_code(p_pass, p_owner, p_secret, p_epoch), 'sha256'), 'hex'),
      'wg', encode(public._exos_wallet_google_key(p_pass, p_owner, p_secret, p_epoch), 'hex'));
  END IF;
  RETURN v_out;
END $$;
REVOKE ALL ON FUNCTION public._exos_addon_door_keys(uuid, uuid, text, int) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_addon_door_keys(uuid, uuid, text, int) TO service_role;

SELECT pg_temp.exos_patch_n('public.exos_event_addon_passes(uuid)', '/* exos: addon wallet keys */',
  '                                                   ELSE jsonb_build_object(''d'', public._exos_door_keys(p.id, NULL, p.barcode_secret)->''d'') END,',
  '                                                   ELSE public._exos_addon_door_keys(p.id, p.owner_id, p.barcode_secret, p.wallet_epoch) /* exos: addon wallet keys */ END,', 1);

-- The holder's wallet pass for one add-on unit (exos-wallet POST /addon-pass,
-- with the holder's JWT). Issues the wallet epoch the first time. Only the
-- pass's owner; a voided pass has none. Holder-safe: no secret (the code and
-- the TOTP key are derived here), no email, no price.
CREATE OR REPLACE FUNCTION public.exos_wallet_addon_pass(p_pass_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  v_uid uuid := auth.uid();
  ps    public.exos_addon_passes%ROWTYPE;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'exos_wallet_addon_pass: not authenticated' USING ERRCODE = '42501';
  END IF;
  SELECT * INTO ps FROM public.exos_addon_passes WHERE id = p_pass_id FOR UPDATE;
  IF NOT FOUND OR ps.owner_id IS DISTINCT FROM v_uid THEN
    RAISE EXCEPTION 'exos_wallet_addon_pass: not your add-on pass' USING ERRCODE = '42501';
  END IF;
  IF ps.status = 'voided' THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'voided');
  END IF;
  IF ps.wallet_epoch IS NULL THEN
    UPDATE public.exos_addon_passes SET wallet_epoch = 1 WHERE id = ps.id RETURNING * INTO ps;
  END IF;
  RETURN jsonb_build_object('ok', true, 'payload', (
    SELECT jsonb_build_object(
      'serial', 'addon-' || ps.id,
      'pass_id', ps.id,
      'addon_name', coalesce(ps.addon_name, 'Add-on'),
      'unit_index', ps.unit_index,
      'unit_count', (SELECT count(*) FROM public.exos_addon_passes x WHERE x.order_addon_id = ps.order_addon_id),
      'status', ps.status,
      'code_epoch', ps.wallet_epoch,
      'updated_at', ps.updated_at,
      'event', jsonb_build_object(
        'id', e.id, 'name', e.name, 'status', e.status, 'starts_at', e.starts_at, 'ends_at', e.ends_at,
        'doors_at', e.doors_at, 'timezone', e.timezone, 'venue_name', e.venue_name,
        'venue_location', e.venue_location, 'lat', CASE WHEN e.format = 'online' THEN NULL ELSE g.lat END,
        'lng', CASE WHEN e.format = 'online' THEN NULL ELSE g.lng END, 'format', e.format),
      'org_name', o.name,
      'apple_code', public._exos_addon_wallet_apple_code(ps.id, ps.owner_id, ps.barcode_secret, ps.wallet_epoch),
      'google_key_hex', encode(public._exos_wallet_google_key(ps.id, ps.owner_id, ps.barcode_secret, ps.wallet_epoch), 'hex'),
      'google_pattern', 'A-' || ps.id || ':' || ps.owner_id || ':g' || ps.wallet_epoch || ':{totp_value_0}')
      FROM public.exos_events e
      LEFT JOIN public.exos_orgs o ON o.id = e.org_id
      LEFT JOIN public.exos_event_geo g ON g.event_id = e.id
     WHERE e.id = ps.event_id));
END $$;
REVOKE ALL ON FUNCTION public.exos_wallet_addon_pass(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_wallet_addon_pass(uuid) TO authenticated, service_role;
