-- ============================================================================
-- Migration 20261104120000 — Exos: door mistake-simulation fixes (2026-11-04)
-- ============================================================================
-- tests/exos/sim_door.sql drives the door RPCs the way door staff and
-- scanner phones get them wrong. Each fix below is pinned there by a
-- SIM-DOOR-n scenario.
--
-- 1. A replayed offline scan answered 'not-assigned' stays queued
--    (SIM-DOOR-15). exos_check_in_offline and a by-name replay (client ref
--    set) used to record 'not-assigned' as the scan's final answer: the
--    phone dropped it from its queue, nothing was forced, and the ticket the
--    door had admitted stayed active, so it could be used again. That
--    happens when a scanner is re-scoped to other events (exos_event_staff)
--    before their phone uploads. The replay now raises 42501 "not assigned"
--    before anything is written: the phone keeps the scans (its 'auth'
--    class) and a manager signed in on it can upload them.
-- 2. No check-out without a check-in (SIM-DOOR-7). An exit on a re-entry
--    list for a ticket that was never admitted ('active') was recorded as
--    'checked-out', so a phone left in Exit mode let someone in without
--    using the ticket. It is now refused 'not-inside' (exos_check_in_ticket
--    and exos_door_checkin_by_name, the list-aware versions).
-- 3. Guest-list replays that are refused are recorded (SIM-DOOR-12/13).
--    exos_guest_check_in with p_source 'offline-sync' (an arrival the door
--    already let in) now writes an exos_scan_rejects row (reason_detail
--    'guest-replay:<reason>') when the server refuses it: voided on the
--    selling platform, already used by another phone, over the party size.
-- 4. Undo a guest-list arrival (SIM-DOOR-11). Checking in the wrong "Sam
--    Lee" had no way back. exos_guest_undo_arrival(entry, event, count,
--    reason): owner / manager, a reason of 3+ characters, at most what has
--    arrived; logged in exos_guest_checkin_undos (new, RLS: org staff read).
-- 5. The POS drawer counts gift cards sold for cash into it (SIM-DOOR-20).
--    exos_gift_card_issue records the open drawer a box-office card was
--    sold from, but exos_pos_close_drawer only summed POS cash payments, so
--    every cash gift card showed up as an overage. Cash cards sold into the
--    drawer (voided or not: Exos has no cash refund for a card) are now part
--    of cash_taken_cents and expected_cents.
-- 6. A box-office mint retried with the same order_ref returns the first
--    mint (SIM-DOOR-19). exos_mint_tickets minted again on every call, so a
--    retry after a timeout or a double tap at the door issued the comp
--    twice (and spent the comp budget twice). Same event + order_ref + caller
--    now returns the tickets already minted; a different quantity under the
--    same ref is refused. Callers that pass a fresh ref (or none) see no
--    change.
--
-- Touches:  W: FUNCTION exos_check_in_offline (both), exos_door_checkin_by_name
--              (both), exos_check_in_ticket (list-aware), exos_pos_close_drawer,
--              exos_mint_tickets (patched in place, marker-checked)
--           W: FUNCTION exos_guest_check_in (redefined)
--           C: TABLE exos_guest_checkin_undos, FUNCTION exos_guest_undo_arrival
-- Pre-reqs: every exos migration before this one.
-- Re-run safe: marker-checked patches (pg_temp.exos_patch_n), CREATE OR
-- REPLACE, IF NOT EXISTS. Grants on patched functions are kept (CREATE OR
-- REPLACE through pg_get_functiondef). D4 authors; not applied.
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

-- ---------------------------------------------------------------------------
-- 1. 'not-assigned' on a replay keeps the scan queued.
-- ---------------------------------------------------------------------------
DO $p1$
DECLARE s text;
BEGIN
  FOREACH s IN ARRAY ARRAY[
    'public.exos_check_in_offline(uuid,uuid,uuid,timestamptz,text,text,text,text)',
    'public.exos_check_in_offline(uuid,uuid,uuid,timestamptz,text,text,text,text,uuid,text)'] LOOP
    PERFORM pg_temp.exos_patch_n(s, '/* exos: replay not-assigned */',
      $o$  SELECT org_id, event_id INTO v_org, v_event FROM public.exos_tickets WHERE id = p_ticket_id;$o$,
      $n$  /* exos: replay not-assigned */ -- mig 20261104120000. Not this scanner's event
  -- (any more): an auth answer, so the phone keeps the scan for a manager.
  IF r ->> 'reason' = 'not-assigned' THEN
    RAISE EXCEPTION 'exos_check_in_offline: not assigned to this event' USING ERRCODE = '42501';
  END IF;
  SELECT org_id, event_id INTO v_org, v_event FROM public.exos_tickets WHERE id = p_ticket_id;$n$, 1);
  END LOOP;
  FOREACH s IN ARRAY ARRAY[
    'public.exos_door_checkin_by_name(uuid,uuid,text,text,timestamptz,uuid)',
    'public.exos_door_checkin_by_name(uuid,uuid,text,text,timestamptz,uuid,uuid,text)'] LOOP
    PERFORM pg_temp.exos_patch_n(s, '/* exos: replay not-assigned */',
      $o$  IF p_client_ref IS NOT NULL THEN
    -- An offline replay the server refused$o$,
      $n$  /* exos: replay not-assigned */ -- mig 20261104120000 (see exos_check_in_offline).
  IF p_client_ref IS NOT NULL AND r ->> 'reason' = 'not-assigned' THEN
    RAISE EXCEPTION 'exos_door_checkin_by_name: not assigned to this event' USING ERRCODE = '42501';
  END IF;
  IF p_client_ref IS NOT NULL THEN
    -- An offline replay the server refused$n$, 1);
  END LOOP;
END $p1$;

-- ---------------------------------------------------------------------------
-- 2. No check-out without a check-in.
-- ---------------------------------------------------------------------------
SELECT pg_temp.exos_patch_n(
  'public.exos_check_in_ticket(uuid,text,text,text,uuid,text,timestamptz,text,uuid,text)',
  '/* exos: exit needs an entry */',
  $o$    PERFORM 1 FROM public.exos_tickets WHERE id = p_ticket_id FOR UPDATE;
    INSERT INTO public.exos_event_checkins$o$,
  $n$    PERFORM 1 FROM public.exos_tickets WHERE id = p_ticket_id FOR UPDATE;
    /* exos: exit needs an entry */ -- mig 20261104120000. Never admitted: an
    -- exit would let them in without using the ticket.
    IF (SELECT status FROM public.exos_tickets WHERE id = p_ticket_id) = 'active' THEN
      RETURN jsonb_build_object('ok', false, 'reason', 'not-inside');
    END IF;
    INSERT INTO public.exos_event_checkins$n$, 1);

SELECT pg_temp.exos_patch_n(
  'public.exos_door_checkin_by_name(uuid,uuid,text,text,timestamptz,uuid,uuid,text)',
  '/* exos: exit needs an entry */',
  $o$    IF v_dir = 'exit' THEN
      INSERT INTO public.exos_event_checkins$o$,
  $n$    IF v_dir = 'exit' THEN
      /* exos: exit needs an entry */ -- mig 20261104120000
      IF t.status = 'active' THEN
        r := jsonb_build_object('ok', false, 'reason', 'not-inside'); EXIT decide;
      END IF;
      INSERT INTO public.exos_event_checkins$n$, 1);

-- ---------------------------------------------------------------------------
-- 3. Guest-list check-in: a refused offline replay is recorded.
--    (Body of mig 20261014120000's version, the decision moved into a block so
--    every refusal reaches the logging at the end.)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.exos_guest_check_in(
  p_entry_id uuid, p_count integer, p_event_id uuid,
  p_client_ref uuid DEFAULT NULL, p_source text DEFAULT 'online')
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  en      public.exos_guest_list_entries%ROWTYPE;
  v_left  int;
  v_open  timestamptz;
  v_test  boolean;
  v_evst  text;
  v_else  jsonb;
  r       jsonb;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'exos_guest_check_in: not authenticated' USING ERRCODE = '42501';
  END IF;
  SELECT * INTO en FROM public.exos_guest_list_entries WHERE id = p_entry_id FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'not-found');
  END IF;
  IF NOT (public.exos_is_admin() OR public.exos_has_org_role(en.org_id, ARRAY['owner', 'manager', 'scanner'])) THEN
    RAISE EXCEPTION 'exos_guest_check_in: not authorized' USING ERRCODE = '42501';
  END IF;

  <<decide>>
  BEGIN
    IF p_event_id IS NULL OR en.event_id <> p_event_id THEN
      r := jsonb_build_object('ok', false, 'reason', 'wrong-event'); EXIT decide;
    END IF;
    -- door: voided on the platform that sold it (mig 20261013100000)
    IF en.voided_at IS NOT NULL THEN
      r := jsonb_build_object('ok', false, 'reason', 'voided', 'source', en.source,
                              'void_reason', en.void_reason, 'arrived', en.arrived, 'party', en.plus_ones + 1);
      EXIT decide;
    END IF;
    -- door: scanner event scope (exos_event_staff, mig 20260929041000)
    IF NOT public.exos_can_door_event(en.event_id) THEN
      r := jsonb_build_object('ok', false, 'reason', 'not-assigned'); EXIT decide;
    END IF;
    IF p_client_ref IS NOT NULL AND EXISTS (SELECT 1 FROM public.exos_guest_list_checkins WHERE client_ref = p_client_ref) THEN
      RETURN jsonb_build_object('ok', true, 'reason', 'duplicate', 'arrived', en.arrived, 'party', en.plus_ones + 1);
    END IF;
    SELECT e.status, coalesce(e.doors_at, e.starts_at),
           (coalesce(e.checkin_test_mode, false) AND e.checkin_test_until IS NOT NULL AND now() < e.checkin_test_until)
      INTO v_evst, v_open, v_test
      FROM public.exos_events e WHERE e.id = en.event_id;
    IF v_evst = 'cancelled' THEN
      r := jsonb_build_object('ok', false, 'reason', 'event-cancelled'); EXIT decide;
    END IF;
    IF v_open IS NOT NULL AND now() < v_open THEN
      IF v_test THEN
        RETURN jsonb_build_object('ok', true, 'reason', 'test-scan', 'test', true,
                                  'arrived', en.arrived, 'party', en.plus_ones + 1);
      END IF;
      r := jsonb_build_object('ok', false, 'reason', 'doors-not-open', 'opens_at', v_open); EXIT decide;
    END IF;
    -- door: a guest Eventbrite's own app checked in counts as one in
    -- (mig 20261014120000; read from Eventbrite, never written back).
    SELECT jsonb_build_object('where', 'Eventbrite', 'at', a.checked_in_at, 'method', a.checkin_method)
      INTO v_else
      FROM public.exos_eventbrite_attendees a
     WHERE a.entry_id = en.id AND a.checked_in;
    v_left := greatest(0, en.plus_ones + 1 - en.arrived - CASE WHEN v_else IS NULL THEN 0 ELSE 1 END);
    IF coalesce(p_count, 0) < 1 THEN
      r := jsonb_build_object('ok', false, 'reason', 'bad-count'); EXIT decide;
    END IF;
    IF p_count > v_left THEN
      r := jsonb_build_object('ok', false,
                              'reason', CASE WHEN v_left = 0 AND v_else IS NOT NULL AND en.arrived = 0 THEN 'checked-in-elsewhere'
                                             WHEN v_left = 0 THEN 'used' ELSE 'over' END,
                              'remaining', v_left, 'arrived', en.arrived, 'party', en.plus_ones + 1,
                              'elsewhere', v_else);
      EXIT decide;
    END IF;
    UPDATE public.exos_guest_list_entries
       SET arrived = arrived + p_count, arrived_at = coalesce(arrived_at, now())
     WHERE id = en.id;
    INSERT INTO public.exos_guest_list_checkins (entry_id, event_id, org_id, count, client_ref, source, scanned_by)
    VALUES (en.id, en.event_id, en.org_id, p_count, p_client_ref,
            CASE WHEN p_source = 'offline-sync' THEN 'offline-sync' ELSE 'online' END, auth.uid());
    RETURN jsonb_build_object('ok', true, 'reason', 'checked-in',
                              'arrived', en.arrived + p_count, 'party', en.plus_ones + 1);
  END decide;

  -- exos: guest replay conflict (mig 20261104120000). The door already let
  -- them in while offline: the refusal goes to the scan report. A scanner
  -- no longer on the event is an auth answer (the arrival stays queued).
  IF p_source = 'offline-sync' THEN
    IF r ->> 'reason' = 'not-assigned' THEN
      RAISE EXCEPTION 'exos_guest_check_in: not assigned to this event' USING ERRCODE = '42501';
    END IF;
    IF p_event_id = en.event_id THEN
      INSERT INTO public.exos_scan_rejects
        (event_id, org_id, rejected_by, reason, source, ticket_id_attempted, reason_detail)
      VALUES (en.event_id, en.org_id, auth.uid(),
              CASE r ->> 'reason' WHEN 'voided' THEN 'voided'
                                  WHEN 'used' THEN 'used'
                                  WHEN 'checked-in-elsewhere' THEN 'used'
                                  ELSE 'not-found' END,
              'manual', en.id::text,
              left('guest-replay:' || coalesce(r ->> 'reason', 'unknown') || ':' || coalesce(p_count, 0), 200));
    END IF;
    r := r || jsonb_build_object('conflict', true);
  END IF;
  RETURN r;
END $$;

-- ---------------------------------------------------------------------------
-- 4. Undo a guest-list arrival.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.exos_guest_checkin_undos (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  entry_id    uuid NOT NULL REFERENCES public.exos_guest_list_entries (id) ON DELETE CASCADE,
  event_id    uuid NOT NULL REFERENCES public.exos_events (id) ON DELETE CASCADE,
  org_id      uuid NOT NULL REFERENCES public.exos_orgs (id) ON DELETE CASCADE,
  count       int  NOT NULL CHECK (count BETWEEN 1 AND 21),
  arrived_was int  NOT NULL,
  reason      text NOT NULL CHECK (length(reason) BETWEEN 3 AND 300),
  undone_by   uuid NOT NULL,
  undone_at   timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS exos_guest_checkin_undos_event_idx ON public.exos_guest_checkin_undos (event_id);
CREATE INDEX IF NOT EXISTS exos_guest_checkin_undos_entry_idx ON public.exos_guest_checkin_undos (entry_id);
ALTER TABLE public.exos_guest_checkin_undos ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.exos_guest_checkin_undos FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.exos_guest_checkin_undos TO authenticated;
GRANT ALL ON public.exos_guest_checkin_undos TO service_role;
DROP POLICY IF EXISTS exos_guest_checkin_undos_sel ON public.exos_guest_checkin_undos;
CREATE POLICY exos_guest_checkin_undos_sel ON public.exos_guest_checkin_undos
  FOR SELECT TO authenticated
  USING (public.exos_is_admin() OR public.exos_has_org_role(org_id, ARRAY['owner', 'manager', 'scanner']));

CREATE OR REPLACE FUNCTION public.exos_guest_undo_arrival(
  p_entry_id uuid, p_event_id uuid, p_count integer DEFAULT NULL, p_reason text DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  en  public.exos_guest_list_entries%ROWTYPE;
  v_n int;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'exos_guest_undo_arrival: not authenticated' USING ERRCODE = '42501';
  END IF;
  SELECT * INTO en FROM public.exos_guest_list_entries WHERE id = p_entry_id FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'not-found');
  END IF;
  IF NOT (public.exos_is_admin() OR public.exos_has_org_role(en.org_id, ARRAY['owner', 'manager', 'scanner'])) THEN
    RAISE EXCEPTION 'exos_guest_undo_arrival: not authorized' USING ERRCODE = '42501';
  END IF;
  -- Same rule as a ticket's undo (exos_undo_check_in): owners and managers.
  IF NOT (public.exos_is_admin() OR public.exos_has_org_role(en.org_id, ARRAY['owner', 'manager'])) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'needs-manager');
  END IF;
  IF p_event_id IS NULL OR en.event_id <> p_event_id THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'wrong-event');
  END IF;
  IF length(btrim(coalesce(p_reason, ''))) < 3 THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'reason-required');
  END IF;
  IF en.arrived = 0 THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'not-checked-in');
  END IF;
  v_n := coalesce(p_count, en.arrived);
  IF v_n < 1 OR v_n > en.arrived THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'bad-count', 'arrived', en.arrived);
  END IF;
  UPDATE public.exos_guest_list_entries
     SET arrived = arrived - v_n,
         arrived_at = CASE WHEN arrived - v_n = 0 THEN NULL ELSE arrived_at END
   WHERE id = en.id;
  INSERT INTO public.exos_guest_checkin_undos (entry_id, event_id, org_id, count, arrived_was, reason, undone_by)
  VALUES (en.id, en.event_id, en.org_id, v_n, en.arrived, left(btrim(p_reason), 300), auth.uid());
  RETURN jsonb_build_object('ok', true, 'reason', 'undone', 'arrived', en.arrived - v_n, 'party', en.plus_ones + 1);
END $$;
REVOKE ALL ON FUNCTION public.exos_guest_undo_arrival(uuid, uuid, integer, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_guest_undo_arrival(uuid, uuid, integer, text) TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 5. POS drawer: cash gift cards sold into it.
-- ---------------------------------------------------------------------------
SELECT pg_temp.exos_patch_n(
  'public.exos_pos_close_drawer(uuid,integer,jsonb,text)',
  '/* exos: drawer gift card cash */',
  $o$   WHERE drawer_session_id = p_session_id AND method = 'cash' AND status = 'succeeded';$o$,
  $n$   WHERE drawer_session_id = p_session_id AND method = 'cash' AND status = 'succeeded';
  /* exos: drawer gift card cash */ -- mig 20261104120000. Box-office gift
  -- cards sold for cash from this drawer (exos_gift_card_issue p_drawer_id).
  v_cash := v_cash + (SELECT coalesce(sum(g.initial_cents), 0)::int FROM public.exos_gift_cards g
                       WHERE g.pos_drawer_id = p_session_id AND g.payment_method = 'cash');$n$, 1);

-- ---------------------------------------------------------------------------
-- 6. Box-office mint: the same order_ref twice is one mint.
-- ---------------------------------------------------------------------------
SELECT pg_temp.exos_patch_n(
  'public.exos_mint_tickets(uuid,uuid,integer,text,numeric,text)',
  '/* exos: mint order_ref once */',
  $o$  -- p1: a free staff mint is a comp: it counts against the org's comp budget.$o$,
  $n$  /* exos: mint order_ref once */ -- mig 20261104120000. A retry (timeout, a
  -- double tap) with the same ref returns the first mint instead of a second.
  IF nullif(btrim(coalesce(p_order_ref, '')), '') IS NOT NULL THEN
    PERFORM pg_advisory_xact_lock(hashtextextended('exos_mint:' || p_event_id::text || ':' || p_order_ref, 0));
    SELECT array_agg(t.id ORDER BY t.created_at, t.id) INTO v_ids
      FROM public.exos_tickets t
     WHERE t.event_id = p_event_id AND t.order_ref = p_order_ref AND t.buyer_id = v_uid
       AND t.channel_source IN ('boxoffice', 'vibepass');
    IF v_ids IS NOT NULL THEN
      IF array_length(v_ids, 1) <> p_quantity THEN
        RAISE EXCEPTION 'exos_mint_tickets: order ref % was already used for % ticket(s)', p_order_ref, array_length(v_ids, 1)
          USING ERRCODE = '23505';
      END IF;
      RETURN v_ids;
    END IF;
    v_ids := '{}';
  END IF;
  -- p1: a free staff mint is a comp: it counts against the org's comp budget.$n$, 1);
