-- ============================================================================
-- Migration 20261110120000 — Exos: wave-9 leftovers
-- ============================================================================
-- Branch: claude/exos-leftovers-9
--
-- 1. Partner and organizer reservations take checkout-question answers
--    (docs/partner-sales.md, docs/checkout-questions.md).
--    The reserve call (POST /v1/public/confirms/:id/ticket_reservations,
--    POST …/comps, POST /v1/events/:id/organizer-reservations[/build]) may
--    carry `answers: { order: {...}, tickets: [{...}] }`, checked with the
--    online rules (_exos_validate_answers_core, "show only if" conditions
--    included) before a seat is held, and stored like online answers
--    (_exos_record_answers, order ref 'po:<reservation>', attached to the
--    n-th ticket minted at complete) in the same transaction as the holds.
--    tickets[i] is the i-th ticket of the reservation's order_items, in the
--    order the reservation answers them (the ticket types' order).
--    - Partners (a distribution partner's key, reserve and comps): the
--      event's REQUIRED questions are required, as at online checkout, so a
--      partner learns before charging its buyer. Missing ones refuse the
--      reservation with SQLSTATE EXQRQ (exos-api: 422 reason
--      "questions_required", DETAIL = [{question_id, label, ticket}], labels
--      of this event's own questions only). Nothing is held. Questions hidden
--      from checkout are not asked of partners (answering one is refused as
--      an unknown question, as online).
--    - Organizer reservations (an org credential): checked, never required,
--      hidden questions included (staff), as their complete call already was.
--    - Complete may still send answers when the reserve didn't (partners now
--      too: _exos_partner_reservation_answers, scoped to the partner's own
--      reservation in SQL); answers are kept once per reservation, the first
--      set sent wins.
--    - GET /v1/public/confirms/:id/questions: the questions a partner's buyer
--      is asked (_exos_partner_event_questions; the event must be the
--      partner's organizer's and published, else P0002).
--    Marker patches on _exos_partner_reserve:
--      /* exos: reservation answers check */, /* exos: reservation answers record */
--
-- 2. POST /v1/tickets/:id/undo-check-in takes an add-on pass id
--    (mig 20261108110000 built exos_undo_addon_check_in; the API only routed
--    pass ids for check-in). exos_api_write finds the pass in the key's org
--    and calls exos_undo_addon_check_in as the key's creator: the same role
--    and window rules as the door (the scanner who scanned it, within 10
--    minutes; owner / manager any time; a reason).
--    Marker patches on exos_api_write:
--      /* exos: addon undo api */, /* exos: addon undo api route */
--
-- 3. "N changes since publish" on the event report: exos_event_audit_summary
--    (authenticated; owner / manager / finance of the event's org or a
--    platform admin, the roles that read the org audit log, else 42501 before
--    anything is read; an unknown event is the same 42501). Counts the event's
--    exos_org_audit rows after its latest event.publish row, exports
--    (export.*) left out.
--
-- Touches:  C: FUNCTION _exos_reservation_answer_tiers, _exos_reservation_answers_check,
--              _exos_partner_reservation_answers, _exos_partner_event_questions
--              (service role only), exos_event_audit_summary (authenticated)
--           W: FUNCTION _exos_partner_reserve (2 marker patches),
--              exos_api_write (2 marker patches). Both were created by
--              2026-10/11 migrations (20261031130000, 20261031110000), so
--              prod's bodies are the chain's (supabase/README.md rule 4).
-- Grants:   nothing new for anon (H3 unchanged).
-- Additive, replay-safe (CREATE OR REPLACE, marker-checked patches). No cron.
-- Not applied. Prod apply needs operator OK.
-- ROLLBACK: DROP the five functions above; re-run 20261107120000 (for
--           _exos_partner_reserve's markers it re-applies, after re-creating
--           its base from 20261031130000 and the patches between) and
--           20261107110000's exos_api_write patch the same way.
-- ============================================================================

CREATE OR REPLACE FUNCTION pg_temp.exos_patch_n(p_sig text, p_marker text, p_old text, p_new text, p_hits int)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE p_fn regprocedure := to_regprocedure(p_sig); v_def text; v_hits int;
BEGIN
  IF p_fn IS NULL THEN
    RAISE EXCEPTION '%: not present', p_sig;
  END IF;
  v_def := replace(pg_get_functiondef(p_fn), chr(13), '');
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
-- 1. Reservations take checkout-question answers
-- ===========================================================================
-- A reservation's lines ([{tier_id, quantity}, ...], in its order) as one
-- ticket type per ticket: what tickets[i] of the answers refers to, and the
-- order complete mints in.
CREATE OR REPLACE FUNCTION public._exos_reservation_answer_tiers(p_lines jsonb)
RETURNS uuid[] LANGUAGE sql IMMUTABLE SET search_path = public, pg_temp AS $$
  SELECT coalesce(array_agg((l ->> 'tier_id')::uuid ORDER BY o, g), '{}'::uuid[])
    FROM jsonb_array_elements(CASE WHEN jsonb_typeof(p_lines) = 'array' THEN p_lines ELSE '[]'::jsonb END)
         WITH ORDINALITY AS x(l, o),
         LATERAL generate_series(1, least(greatest(coalesce((l ->> 'quantity')::int, 0), 0), 100)) AS g
$$;

-- Check a reservation's answers before anything is held. Partners: the
-- questions checkout asks, required ones required (EXQRQ with the missing
-- ones in DETAIL). The organizer: hidden ones too, nothing required. An
-- invalid answer is 22023 either way (_exos_raise_answer_problem: only this
-- event's labels, never an unknown question's).
CREATE OR REPLACE FUNCTION public._exos_reservation_answers_check(
  p_event uuid, p_partner boolean, p_lines jsonb, p_answers jsonb)
RETURNS void LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  v_defs  jsonb := public._exos_question_defs(p_event, NOT coalesce(p_partner, true));
  v_tiers uuid[] := public._exos_reservation_answer_tiers(p_lines);
  v_body  jsonb := p_answers;
  v_res   jsonb;
  v_bad   jsonb;
  v_miss  jsonb;
BEGIN
  -- An event that asks nothing: nothing to check (stale answers are dropped,
  -- as _exos_record_answers drops them).
  IF jsonb_array_length(v_defs) = 0 OR coalesce(cardinality(v_tiers), 0) = 0 THEN
    RETURN;
  END IF;
  IF v_body IS NULL OR jsonb_typeof(v_body) = 'null' THEN
    v_body := '{}'::jsonb;
  END IF;
  v_res := public._exos_validate_answers_core(v_defs, v_tiers, v_body, coalesce(p_partner, true));
  IF (v_res ->> 'ok')::boolean IS TRUE THEN
    RETURN;
  END IF;
  SELECT jsonb_agg(p ORDER BY o) FILTER (WHERE p ->> 'code' IS DISTINCT FROM 'required'),
         jsonb_agg(jsonb_build_object(
           'question_id', p ->> 'question_id', 'ticket', p -> 'ticket',
           'label', (SELECT q.label FROM public.exos_event_questions q
                      WHERE q.event_id = p_event AND q.id::text = p ->> 'question_id'))
           ORDER BY o) FILTER (WHERE p ->> 'code' = 'required')
    INTO v_bad, v_miss
    FROM jsonb_array_elements(coalesce(v_res -> 'problems', '[]'::jsonb)) WITH ORDINALITY AS x(p, o);
  IF v_bad IS NOT NULL THEN
    PERFORM public._exos_raise_answer_problem(jsonb_build_object('problems', v_bad), p_event);
  END IF;
  IF v_miss IS NOT NULL THEN
    RAISE EXCEPTION 'answer the event''s required checkout questions (% unanswered, first: "%")',
      jsonb_array_length(v_miss), left(coalesce(v_miss -> 0 ->> 'label', '?'), 120)
      USING ERRCODE = 'EXQRQ', DETAIL = v_miss::text, HINT = 'questions-required';
  END IF;
  -- Not ok but no problem listed: refuse rather than hold.
  PERFORM public._exos_raise_answer_problem(v_res, p_event);
END $$;
REVOKE ALL ON FUNCTION public._exos_reservation_answer_tiers(jsonb) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._exos_reservation_answers_check(uuid, boolean, jsonb, jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_reservation_answer_tiers(jsonb) TO service_role;
GRANT EXECUTE ON FUNCTION public._exos_reservation_answers_check(uuid, boolean, jsonb, jsonb) TO service_role;

-- The reserve checks the answers once every line is known (before the dry
-- run returns, before a hold), and stores them with the reservation.
SELECT pg_temp.exos_patch_n('public._exos_partner_reserve(uuid,uuid,uuid,uuid,jsonb,jsonb,boolean,boolean)',
  '/* exos: reservation answers check */',
  '  IF p_dry_run THEN
',
  '  /* exos: reservation answers check */ -- mig 20261110120000: required ones for partners
  PERFORM public._exos_reservation_answers_check(p_event_id, p_partner_id IS NOT NULL, v_lines, a -> ''answers'');

  IF p_dry_run THEN
', 1);
SELECT pg_temp.exos_patch_n('public._exos_partner_reserve(uuid,uuid,uuid,uuid,jsonb,jsonb,boolean,boolean)',
  '/* exos: reservation answers record */',
  '  RETURN public._exos_partner_reservation_json(v_id);
END',
  '  /* exos: reservation answers record */ -- mig 20261110120000: stored like online answers
  IF jsonb_typeof(a -> ''answers'') = ''object'' THEN
    PERFORM public._exos_record_answers(p_org_id, p_event_id, ''po:'' || v_id,
      public._exos_reservation_answer_tiers(v_lines), a -> ''answers'', false, p_partner_id IS NULL, ''api'', NULL);
  END IF;
  RETURN public._exos_partner_reservation_json(v_id);
END', 1);

-- A partner's complete call with answers: its own active reservation only
-- (P0002 for any other), the questions checkout asks, nothing required (the
-- reserve required them). Returns the number of answers stored (0 when the
-- reserve already stored some: kept once). The row lock orders it against a
-- concurrent complete (which locks the same row): answers either land before
-- the mint (and attach) or see the reservation completed and store nothing,
-- never an unattached set (tests/exos/race_leftovers_9.sh).
CREATE OR REPLACE FUNCTION public._exos_partner_reservation_answers(
  p_org uuid, p_partner uuid, p_token text, p_answers jsonb)
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  r public.exos_partner_reservations%ROWTYPE;
BEGIN
  SELECT * INTO r FROM public.exos_partner_reservations
   WHERE org_id = p_org AND token = p_token AND partner_id IS NOT NULL AND partner_id = p_partner
   FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'reservation not found' USING ERRCODE = 'P0002';
  END IF;
  IF r.status <> 'active' OR p_answers IS NULL OR jsonb_typeof(p_answers) <> 'object' THEN
    RETURN 0;
  END IF;
  RETURN public._exos_record_answers(p_org, r.event_id, 'po:' || r.id, public._exos_reservation_answer_tiers(r.lines),
                                     p_answers, false, false, 'api', NULL);
END $$;
REVOKE ALL ON FUNCTION public._exos_partner_reservation_answers(uuid, uuid, text, jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_partner_reservation_answers(uuid, uuid, text, jsonb) TO service_role;

-- The questions a partner's buyer is asked: the event must be the
-- partner's organizer's and published (else P0002, nothing named).
CREATE OR REPLACE FUNCTION public._exos_partner_event_questions(p_org uuid, p_event uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.exos_events e WHERE e.id = p_event AND e.org_id = p_org AND e.status = 'published') THEN
    RAISE EXCEPTION 'event not found' USING ERRCODE = 'P0002';
  END IF;
  RETURN jsonb_build_object('event_id', p_event, 'questions', (
    SELECT coalesce(jsonb_agg(x - 'event_id' - 'hidden' - 'archived' - 'archived_at' - 'created_at' - 'updated_at'
                              ORDER BY (x ->> 'sort_order')::int, x ->> 'id'), '[]'::jsonb)
      FROM jsonb_array_elements(public._exos_question_defs(p_event, false)) x));
END $$;
REVOKE ALL ON FUNCTION public._exos_partner_event_questions(uuid, uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_partner_event_questions(uuid, uuid) TO service_role;

-- ===========================================================================
-- 2. The API's undo takes an add-on pass id
-- ===========================================================================
SELECT pg_temp.exos_patch_n('public.exos_api_write(uuid, text, text, jsonb, text)', '/* exos: addon undo api */',
  '    IF v_event IS NULL AND p_action = ''ticket.check_in'' THEN /* exos: addon pass api */',
  '    IF v_event IS NULL AND p_action IN (''ticket.check_in'', ''ticket.undo_check_in'') THEN /* exos: addon pass api */ /* exos: addon undo api */',
  1);
SELECT pg_temp.exos_patch_n('public.exos_api_write(uuid, text, text, jsonb, text)', '/* exos: addon undo api route */',
  '    IF p_action = ''ticket.undo_check_in'' THEN
      v_out := public.exos_undo_check_in(v_id, v_event, a ->> ''reason'');',
  '    IF p_action = ''ticket.undo_check_in''
       AND NOT EXISTS (SELECT 1 FROM public.exos_tickets xt WHERE xt.id = v_id AND xt.org_id = v_org) THEN
      /* exos: addon undo api route */ -- mig 20261110120000: an add-on pass of this org (found above)
      v_out := public.exos_undo_addon_check_in(v_id, v_event, a ->> ''reason'', NULL, NULL,
                                               left(coalesce(a ->> ''device'', ''api''), 60));
    ELSIF p_action = ''ticket.undo_check_in'' THEN
      v_out := public.exos_undo_check_in(v_id, v_event, a ->> ''reason'');', 1);

-- ===========================================================================
-- 3. "N changes since publish" (the event report's footer)
-- ===========================================================================
CREATE OR REPLACE FUNCTION public.exos_event_audit_summary(p_event_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  v_org    uuid;
  v_pub_id bigint;
  v_pub_at timestamptz;
  v_since  bigint;
  v_total  bigint;
BEGIN
  SELECT e.org_id INTO v_org FROM public.exos_events e WHERE e.id = p_event_id;
  IF auth.uid() IS NULL OR v_org IS NULL
     OR NOT (public.exos_is_admin() OR public.exos_has_org_role(v_org, ARRAY['owner', 'manager', 'finance'])) THEN
    RAISE EXCEPTION 'not authorized' USING ERRCODE = '42501';
  END IF;
  SELECT x.id, x.at INTO v_pub_id, v_pub_at FROM public.exos_org_audit x
   WHERE x.org_id = v_org AND x.event_id = p_event_id AND x.action = 'event.publish'
   ORDER BY x.id DESC LIMIT 1;
  SELECT count(*) FILTER (WHERE v_pub_id IS NOT NULL AND x.id > v_pub_id), count(*)
    INTO v_since, v_total
    FROM public.exos_org_audit x
   WHERE x.org_id = v_org AND x.event_id = p_event_id AND x.action NOT LIKE 'export.%';
  RETURN jsonb_build_object('event_id', p_event_id, 'org_id', v_org, 'published_at', v_pub_at,
                            'changes_since_publish', CASE WHEN v_pub_id IS NOT NULL THEN v_since END,
                            'changes_total', v_total);
END $$;
REVOKE ALL ON FUNCTION public.exos_event_audit_summary(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_event_audit_summary(uuid) TO authenticated, service_role;
