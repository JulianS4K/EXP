-- ============================================================================
-- Migration 20260927040000 — Exos (Bridge / D4): Gametime as a marketplace
--
-- Lane:     d4 (exos / bridge ticketing infra)
-- Touches:  W: CHECK constraints on channel: exos_distribution_listings,
--              exos_channel_event_links, exos_marketplace_orders,
--              exos_marketplace_credentials (+ 'gametime', rebuilt from their
--              live definitions)
--              FUNCTION exos_set_channel_allocation, exos_link_channel_event,
--                exos_sync_marketplace_distribution, exos_claim_internal_seat
--                (patched in place)
-- Pre-reqs: 20260927030000 (marketplace sync)
--
-- Gametime joins StubHub and SeatGeek in the same sync
-- (_shared/marketplace/gametime; docs/marketplace/gametime/README.md):
--   * ticking Gametime and publishing queues its event row; pulling back
--     (untick, primary-market-only, unpublish, cancel, 0) is delist, then
--     release, like the others;
--   * the Marketplaces grid gets a Gametime column
--     (exos_set_channel_allocation accepts 'gametime');
--   * Gametime listings carry internal seat numbers (SeatFrom / SeatThru),
--     and a sale takes the seats of the listing it names (the purchase's
--     listing_reference_id, the webhook's source_id).
-- Nothing is sent to Gametime (dry-run; Hard Rule #2).
--
-- Re-run safe (each patch asserts one match and is skipped once applied).
-- D4 authors; applying to prod is operator-gated.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. 'gametime' in every channel CHECK, keeping whatever else prod allows.
-- ---------------------------------------------------------------------------
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
    CONTINUE WHEN position('''gametime''' in c.def) > 0;
    IF position('ARRAY[' in c.def) = 0 THEN
      RAISE EXCEPTION 'gametime: unexpected shape for %: %', c.conname, c.def;
    END IF;
    v_def := replace(c.def, 'ARRAY[', 'ARRAY[''gametime''::text, ');
    EXECUTE format('ALTER TABLE %s DROP CONSTRAINT %I', c.tbl, c.conname);
    EXECUTE format('ALTER TABLE %s ADD CONSTRAINT %I %s', c.tbl, c.conname, v_def);
  END LOOP;
END $$;

-- ---------------------------------------------------------------------------
-- 2. In-place patches.
-- ---------------------------------------------------------------------------
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

-- The grid: Gametime seats.
SELECT pg_temp.exos_patch('public.exos_set_channel_allocation(uuid, text, uuid, integer)',
  '''stubhub'',''seatgeek'',''gametime'',''vivid''',
  'IF p_channel NOT IN (''stubhub'',''seatgeek'',''vivid''',
  'IF p_channel NOT IN (''stubhub'',''seatgeek'',''gametime'',''vivid''');

-- Links (a staff decision) re-queue the Gametime event row too.
SELECT pg_temp.exos_patch('public.exos_link_channel_event(uuid, text, text)',
  '''stubhub'',''seatgeek'',''gametime'',''vivid''',
  'IF p_channel NOT IN (''stubhub'',''seatgeek'',''vivid''',
  'IF p_channel NOT IN (''stubhub'',''seatgeek'',''gametime'',''vivid''');
SELECT pg_temp.exos_patch('public.exos_link_channel_event(uuid, text, text)',
  'IF p_channel IN (''stubhub'',''seatgeek'',''gametime'') THEN',
  'IF p_channel IN (''stubhub'',''seatgeek'') THEN',
  'IF p_channel IN (''stubhub'',''seatgeek'',''gametime'') THEN');

-- Publish / pull back for Gametime.
SELECT pg_temp.exos_patch('public.exos_sync_marketplace_distribution()',
  'ARRAY[''stubhub'',''seatgeek'',''gametime'']',
  'ARRAY[''stubhub'',''seatgeek'']',
  'ARRAY[''stubhub'',''seatgeek'',''gametime'']');

-- A Gametime sale takes the seats of the listing it names.
SELECT pg_temp.exos_patch('public.exos_claim_internal_seat(uuid, uuid, uuid)',
  'v_chan IN (''seatgeek'',''gametime'')',
  'IF v_chan = ''seatgeek'' AND v_plan IS NOT NULL THEN',
  'IF v_chan IN (''seatgeek'',''gametime'') AND v_plan IS NOT NULL THEN');
SELECT pg_temp.exos_patch('public.exos_claim_internal_seat(uuid, uuid, uuid)',
  'v_raw ->> ''listing_reference_id''',
  'v_lid := coalesce(v_raw #>> ''{listing,id}'', v_raw ->> ''item_id'');',
  'v_lid := coalesce(v_raw #>> ''{listing,id}'', v_raw ->> ''item_id'', v_raw ->> ''listing_reference_id'', v_raw ->> ''source_id'');');
