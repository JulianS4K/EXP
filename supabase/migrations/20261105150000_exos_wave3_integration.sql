-- ============================================================================
-- Migration 20261105150000 — Exos: wave 3 integration (2026-11-05)
-- ============================================================================
-- Wave 3 merged #88 sim decisions (20261105100000), #85 fan API
-- (20261105110000), #87 na-build (20261105120000) and #89 promoter events
-- (20261105130000). They were built side by side on the same base, so each
-- one's in-place patches were checked against the others after a full
-- replay (tests/exos/test_wave3_integration.sql W1: every marker is still
-- in the live body). Two rules crossed branches without a patch to carry them:
--
-- 1. A closed ticket type is sold out in public discovery. #88 made
--    capacity 0 mean CLOSED (nothing sells) instead of "uncapped". #85's
--    public discovery (/v1/public/discovery/events, exos_api_public) was
--    written to the old meaning and marks a type sold out only when it has
--    a positive capacity that is used up, so a closed type showed as on
--    sale and counted toward the event's "from" price. Now sold_out is
--    capacity <= 0 OR sold >= capacity, as exos_tier_available answers 0.
--
-- 2. Capacity 0 closes sales on a promoter-run event too (operator rule:
--    there is no unlimited capacity, and 0 means closed). #89 was written
--    when 0 meant unlimited, so it refused 0 on every type of a promoter-run
--    (non-venue_record) event: an organizer couldn't stop sales on a live
--    one, and couldn't publish with a closed type. Now:
--      * the live-event guard (trigger exos_ticket_tiers_location_capacity)
--        refuses only a NULL or negative capacity; 0 is allowed (closed).
--        A NEW type still needs 1 or more wherever #88 asks for it (the
--        app, the API's ticket-type create; CAPACITY_REQUIRED);
--      * the publish blocker capacity_required asks for at least one type
--        with a capacity above 0 (#88 adds no such blocker: the base one
--        is only no_ticket_types), so an event with every type closed
--        still can't go live; a closed type next to an open one is fine.
--
-- Touches:  W: FUNCTION _exos_api_public_tiers_json, _exos_location_blockers_row
--              (patched in place, marker-checked; same signatures, same grants)
--           W: FUNCTION _exos_tg_tier_capacity_location (redefined, same
--              signature; trigger unchanged)
-- Callers:  exos_api_public / _exos_api_public (exos-api /v1/public/…);
--           _exos_event_publish_blockers / exos_publish_event and the
--           exos_events location guard (the blocker); exos_ticket_tiers
--           writes (the trigger).
-- Pre-reqs: every exos migration before this one.
-- Re-run safe: marker-checked patch (pg_temp.exos_patch_n). D4 authors; not
-- applied.
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
-- 1. A closed ticket type (capacity 0, mig 20261105100000) is sold out in
--    public discovery (mig 20261105110000).
-- ===========================================================================
SELECT pg_temp.exos_patch_n('public._exos_api_public_tiers_json(uuid)',
  '/* exos: closed is sold out */',
  $o$'sold_out', t.capacity IS NOT NULL AND t.capacity > 0 AND coalesce(t.sold, 0) >= t.capacity)$o$,
  $n$'sold_out', coalesce(t.capacity, 0) <= 0 /* exos: closed is sold out */ OR coalesce(t.sold, 0) >= t.capacity)$n$, 1);

-- ===========================================================================
-- 2. Capacity 0 closes sales on a promoter-run event (mig 20261105130000
--    read it as unlimited).
-- ===========================================================================
-- 2a. Publish blocker: at least one type that can sell (a type at 0 is closed).
SELECT pg_temp.exos_patch_n('public._exos_location_blockers_row(public.exos_events,boolean)',
  '/* exos: one sellable type */',
  $o$     AND EXISTS (SELECT 1 FROM public.exos_ticket_tiers t WHERE t.event_id = e.id AND coalesce(t.capacity, 0) <= 0) THEN
    v_out := v_out || jsonb_build_object('code', 'capacity_required', 'field', 'ticket_types',
      'message', 'Give every ticket type a capacity (events without a venue on Exos can''t be unlimited).');$o$,
  $n$     AND EXISTS (SELECT 1 FROM public.exos_ticket_tiers t WHERE t.event_id = e.id)
     AND NOT EXISTS (SELECT 1 FROM public.exos_ticket_tiers t WHERE t.event_id = e.id AND t.capacity > 0) /* exos: one sellable type */ THEN
    v_out := v_out || jsonb_build_object('code', 'capacity_required', 'field', 'ticket_types',
      'message', 'Give at least one ticket type a capacity of 1 or more (0 closes sales).');$n$, 1);

-- 2b. Live guard: a capacity is required (never NULL or negative); 0 closes sales.
CREATE OR REPLACE FUNCTION public._exos_tg_tier_capacity_location()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
  /* exos: 0 closes sales (mig 20261105150000) */
  IF (NEW.capacity IS NULL OR NEW.capacity < 0) AND EXISTS (
       SELECT 1 FROM public.exos_events e
        WHERE e.id = NEW.event_id AND e.status = 'published' AND e.location_mode <> 'venue_record'
          AND coalesce(to_jsonb(e) ->> 'ticket_backend', 'exos') = 'exos') THEN
    RAISE EXCEPTION 'capacity_required: every ticket type of this event needs a capacity of 0 or more (0 closes sales)'
      USING ERRCODE = '22023';
  END IF;
  RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION public._exos_tg_tier_capacity_location() FROM PUBLIC, anon, authenticated;
