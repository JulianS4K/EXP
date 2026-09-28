-- ============================================================================
-- Migration 20260928030000 — Exos (Bridge / D4): Vivid Seats as a marketplace
--
-- Lane:     d4 (exos / bridge ticketing infra)
-- Touches:  W: FUNCTION exos_set_channel_allocation, exos_link_channel_event,
--                exos_sync_marketplace_distribution, exos_fulfil_marketplace_order
--                (patched in place)
-- Pre-reqs: 20260928020000 (GoTickets)
--
-- Vivid Seats (Broker Portal API, _shared/marketplace/vivid;
-- docs/marketplace/vivid/README.md) joins StubHub, SeatGeek, Gametime and
-- GoTickets in the same sync: a Marketplaces grid column with a small pool,
-- publish / pull back, the same Exos listings (blocks, internal seats, "ex…"
-- ids), sales recorded with their listing, and the buyer mail naming
-- "Vivid Seats". 'vivid' has been in every channel CHECK and in
-- exos_set_channel_allocation / exos_link_channel_event since the first
-- distribution migrations, so no constraint changes here.
--
-- Publishing with Vivid Seats ticked now queues its event row like the other
-- four, and pulling back (unticking, primary market only, unpublishing)
-- releases its allocations. Vivid event rows exos_request_distribution made
-- for the old Automatiq route follow the same rules; exos-distribute no
-- longer hands 'vivid' rows to Automatiq.
-- Nothing is sent to Vivid Seats (dry-run; Hard Rule #2).
--
-- Re-run safe (each patch asserts one match and is skipped once applied).
-- D4 authors; applying to prod is operator-gated.
-- ============================================================================

CREATE OR REPLACE FUNCTION pg_temp.exos_patch(p_sig text, p_marker text, p_old text, p_new text)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE p_fn regprocedure := to_regprocedure(p_sig); v_def text; v_hits int;
BEGIN
  IF p_fn IS NULL THEN
    RAISE NOTICE '%: not present, skipped', p_sig;
    RETURN;
  END IF;
  v_def := pg_get_functiondef(p_fn);
  IF position(p_marker in v_def) > 0 THEN
    RAISE NOTICE '%: already patched (%)', p_fn, p_marker;
    RETURN;
  END IF;
  v_hits := (length(v_def) - length(replace(v_def, p_old, ''))) / length(p_old);
  IF v_hits <> 1 THEN
    RAISE EXCEPTION '%: expected one match for patch "%", found %', p_fn, p_marker, v_hits;
  END IF;
  EXECUTE replace(v_def, p_old, p_new);
END $$;

-- The allocation errors say "Vivid Seats", not "Vivid".
SELECT pg_temp.exos_patch('public.exos_set_channel_allocation(uuid, text, uuid, integer)',
  'WHEN ''vivid'' THEN ''Vivid Seats''',
  'WHEN ''gotickets'' THEN ''GoTickets'' ELSE initcap(p_channel) END',
  'WHEN ''gotickets'' THEN ''GoTickets'' WHEN ''vivid'' THEN ''Vivid Seats'' ELSE initcap(p_channel) END');

-- A staff link decision re-queues the Vivid event row too (its productionId).
SELECT pg_temp.exos_patch('public.exos_link_channel_event(uuid, text, text)',
  'IF p_channel IN (''stubhub'',''seatgeek'',''gametime'',''gotickets'',''vivid'') THEN',
  'IF p_channel IN (''stubhub'',''seatgeek'',''gametime'',''gotickets'') THEN',
  'IF p_channel IN (''stubhub'',''seatgeek'',''gametime'',''gotickets'',''vivid'') THEN');

SELECT pg_temp.exos_patch('public.exos_sync_marketplace_distribution()',
  'ARRAY[''stubhub'',''seatgeek'',''gametime'',''gotickets'',''vivid'']',
  'ARRAY[''stubhub'',''seatgeek'',''gametime'',''gotickets'']',
  'ARRAY[''stubhub'',''seatgeek'',''gametime'',''gotickets'',''vivid'']');

-- The buyer mail says "Vivid Seats".
SELECT pg_temp.exos_patch('public.exos_fulfil_marketplace_order(uuid, text)',
  'WHEN ''vivid'' THEN ''Vivid Seats''',
  'WHEN ''gotickets'' THEN ''GoTickets'' ELSE initcap(o.channel) END',
  'WHEN ''gotickets'' THEN ''GoTickets'' WHEN ''vivid'' THEN ''Vivid Seats'' ELSE initcap(o.channel) END');
