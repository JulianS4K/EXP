-- ============================================================================
-- Migration 20260928020000 — Exos (Bridge / D4): GoTickets as a marketplace
--
-- Lane:     d4 (exos / bridge ticketing infra)
-- Touches:  W: CHECK constraints on channel: exos_distribution_listings,
--              exos_channel_event_links, exos_marketplace_orders,
--              exos_marketplace_credentials (+ 'gotickets', rebuilt from their
--              live definitions)
--              FUNCTION exos_set_channel_allocation, exos_link_channel_event,
--                exos_sync_marketplace_distribution, exos_fulfil_marketplace_order
--                (patched in place)
-- Pre-reqs: 20260928010000 (marketplace pools)
--
-- GoTickets (Seller Central API, _shared/marketplace/gotickets;
-- docs/marketplace/gotickets/README.md) joins StubHub, SeatGeek and Gametime in
-- the same sync: a Marketplaces grid column with a small pool, publish / pull
-- back, the same Exos listings (blocks, internal seats, "ex…" ids), sales
-- recorded with their listing, and the buyer mail naming "GoTickets".
-- Nothing is sent to GoTickets (dry-run; Hard Rule #2).
--
-- Re-run safe (each patch asserts one match and is skipped once applied).
-- D4 authors; applying to prod is operator-gated.
-- ============================================================================

-- 1. 'gotickets' in every channel CHECK, keeping whatever else prod allows.
DO $$
DECLARE
  c     record;
  v_def text;
BEGIN
  FOR c IN
    SELECT con.conrelid::regclass AS tbl, con.conname, pg_get_constraintdef(con.oid) AS def
      FROM pg_constraint con
     WHERE con.contype = 'c'
       AND con.conname IN ('exos_distribution_listings_channel_check', 'exos_channel_event_links_channel_check',
                           'exos_marketplace_orders_channel_check', 'exos_marketplace_credentials_channel_check')
  LOOP
    CONTINUE WHEN position('''gotickets''' in c.def) > 0;
    IF position('ARRAY[' in c.def) = 0 THEN
      RAISE EXCEPTION 'gotickets: unexpected shape for %: %', c.conname, c.def;
    END IF;
    v_def := replace(c.def, 'ARRAY[', 'ARRAY[''gotickets''::text, ');
    EXECUTE format('ALTER TABLE %s DROP CONSTRAINT %I', c.tbl, c.conname);
    EXECUTE format('ALTER TABLE %s ADD CONSTRAINT %I %s', c.tbl, c.conname, v_def);
  END LOOP;
END $$;

-- 2. In-place patches.
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

SELECT pg_temp.exos_patch('public.exos_set_channel_allocation(uuid, text, uuid, integer)',
  '''gametime'',''gotickets'',''vivid''',
  'IF p_channel NOT IN (''stubhub'',''seatgeek'',''gametime'',''vivid''',
  'IF p_channel NOT IN (''stubhub'',''seatgeek'',''gametime'',''gotickets'',''vivid''');
SELECT pg_temp.exos_patch('public.exos_set_channel_allocation(uuid, text, uuid, integer)',
  'WHEN ''gotickets'' THEN ''GoTickets''',
  'CASE p_channel WHEN ''stubhub'' THEN ''StubHub'' WHEN ''seatgeek'' THEN ''SeatGeek'' ELSE initcap(p_channel) END',
  'CASE p_channel WHEN ''stubhub'' THEN ''StubHub'' WHEN ''seatgeek'' THEN ''SeatGeek'' WHEN ''gotickets'' THEN ''GoTickets'' ELSE initcap(p_channel) END');

SELECT pg_temp.exos_patch('public.exos_link_channel_event(uuid, text, text)',
  '''gametime'',''gotickets'',''vivid''',
  'IF p_channel NOT IN (''stubhub'',''seatgeek'',''gametime'',''vivid''',
  'IF p_channel NOT IN (''stubhub'',''seatgeek'',''gametime'',''gotickets'',''vivid''');
SELECT pg_temp.exos_patch('public.exos_link_channel_event(uuid, text, text)',
  'IF p_channel IN (''stubhub'',''seatgeek'',''gametime'',''gotickets'') THEN',
  'IF p_channel IN (''stubhub'',''seatgeek'',''gametime'') THEN',
  'IF p_channel IN (''stubhub'',''seatgeek'',''gametime'',''gotickets'') THEN');

SELECT pg_temp.exos_patch('public.exos_sync_marketplace_distribution()',
  'ARRAY[''stubhub'',''seatgeek'',''gametime'',''gotickets'']',
  'ARRAY[''stubhub'',''seatgeek'',''gametime'']',
  'ARRAY[''stubhub'',''seatgeek'',''gametime'',''gotickets'']');

-- The buyer mail says "GoTickets", not "Gotickets".
SELECT pg_temp.exos_patch('public.exos_fulfil_marketplace_order(uuid, text)',
  'WHEN ''gotickets'' THEN ''GoTickets''',
  'CASE o.channel WHEN ''stubhub'' THEN ''StubHub'' WHEN ''seatgeek'' THEN ''SeatGeek'' ELSE initcap(o.channel) END',
  'CASE o.channel WHEN ''stubhub'' THEN ''StubHub'' WHEN ''seatgeek'' THEN ''SeatGeek'' WHEN ''gotickets'' THEN ''GoTickets'' ELSE initcap(o.channel) END');
