-- ============================================================================
-- S4K listings for Albert (mig 20261014150000):
--   L1 three listings per ticket type from S4K's pool, each up to the listing
--      quantity (default 8); the linked consumer user reads them, nobody else
--   L2 a sale refills the listing from the pool; the pool running short
--      leaves a short last listing
--   L3 the cron pass rebalances: S4K's pool grows from Exos + Eventbrite's
--      up to three full listings, never below one set left there
--   L4 a quiet refresh writes nothing (diff)
--   L5 the organizer's listing quantity
--   L6 primary source: Eventbrite needs a link; Eventbrite-primary holds the
--      last set off Exos checkout and Eventbrite's capacity includes it;
--      Exos-primary keeps at least one set off Eventbrite
--   L7 leaving the route takes the listings down
--   L8 grants
-- Self-contained (a9 prefix), rolled back. The resale rule is on (250).
-- ============================================================================
\set ON_ERROR_STOP on
BEGIN;
DELETE FROM public.exos_platform_settings WHERE key = 'resale_min_capacity';
INSERT INTO auth.users(id,email,email_confirmed_at) VALUES
  ('a9000000-0000-0000-0000-0000000000a0','a9-owner@x.com',now()),
  ('a9000000-0000-0000-0000-0000000000c0','albert-integration@x.com',now()),
  ('a9000000-0000-0000-0000-0000000000c1','someone-else@x.com',now());
INSERT INTO public.exos_orgs(id,name,slug,owner_uid) VALUES
  ('a9000000-0000-0000-0000-000000000001','A9 Org','a9-org','a9000000-0000-0000-0000-0000000000a0');
INSERT INTO public.exos_org_memberships(org_id,user_id,role) VALUES
  ('a9000000-0000-0000-0000-000000000001','a9000000-0000-0000-0000-0000000000a0','owner');
INSERT INTO public.exos_events(id,org_id,name,status,starts_at,venue_name,total_tickets,tickets_sold,purchase_limits,timezone) VALUES
  ('a9000000-0000-0000-0000-0000000000e1','a9000000-0000-0000-0000-000000000001','Listing Show','published',now() + interval '20 days','Hall',0,0,'{"maxPerOrder":8}','America/New_York');
INSERT INTO public.exos_ticket_tiers(id,event_id,name,price,capacity,sold,visibility,sort_order) VALUES
  ('a9000000-0000-0000-0000-0000000000d1','a9000000-0000-0000-0000-0000000000e1','GA',40,300,0,'public',1);

CREATE FUNCTION pg_temp.act(p_uid text) RETURNS void LANGUAGE sql AS $$
  SELECT set_config('app.uid', coalesce(p_uid, ''), false), set_config('app.jwt', '{"email":"a9@x.com"}', false);
$$;
CREATE FUNCTION pg_temp.u(p text) RETURNS uuid LANGUAGE sql AS $$ SELECT ('a9000000-0000-0000-0000-0000000000' || p)::uuid $$;
CREATE FUNCTION pg_temp.qtys() RETURNS int[] LANGUAGE sql AS $$
  SELECT coalesce(array_agg(quantity ORDER BY slot), '{}') FROM public.exos_s4k_listings WHERE event_id = pg_temp.u('e1')
$$;
CREATE FUNCTION pg_temp.pool() RETURNS public.exos_distribution_listings LANGUAGE sql AS $$
  SELECT * FROM public.exos_distribution_listings WHERE tier_id = pg_temp.u('d1') AND channel = 's4k'
$$;
CREATE FUNCTION pg_temp.refused(p_sql text, p_like text) RETURNS boolean LANGUAGE plpgsql AS $$
BEGIN
  EXECUTE p_sql;
  RETURN false;
EXCEPTION WHEN others THEN
  IF SQLERRM NOT LIKE '%' || p_like || '%' THEN
    RAISE EXCEPTION 'expected "%", got % "%"', p_like, SQLSTATE, SQLERRM;
  END IF;
  RETURN true;
END $$;
CREATE TEMP TABLE tok(token text, hash text);

-- S4K route, a 30-seat split, a consumer with Albert's user linked.
DO $$
BEGIN
  PERFORM pg_temp.act('a9000000-0000-0000-0000-0000000000a0');
  PERFORM public.exos_set_s4k_network('a9000000-0000-0000-0000-000000000001', true);
  PERFORM public.exos_set_distribution_route(pg_temp.u('e1'), 's4k');
  PERFORM public.exos_set_s4k_split(pg_temp.u('e1'), jsonb_build_array(jsonb_build_object('tier_id', pg_temp.u('d1'), 'seats', 30)));
  PERFORM pg_temp.act(NULL);
END $$;
INSERT INTO tok SELECT c.token, encode(extensions.digest(c.token, 'sha256'), 'hex')
  FROM public.exos_feed_create_consumer('Albert', 'fulfil@s4k.example') c;
SELECT public.exos_feed_link_user('Albert', 'ALBERT-integration@x.com');

-- L1. Three listings of 8 (30 held: 8, 8, 8; 6 wait in the pool).
DO $$
BEGIN
  PERFORM public.exos_feed_refresh(pg_temp.u('e1'));
  ASSERT pg_temp.qtys() = '{8,8,8}', 'L1: ' || pg_temp.qtys()::text;
  ASSERT (SELECT bool_and(listing_id = 'exos-' || tier_id || '-' || slot AND max_quantity = 8 AND price = 40
                          AND primary_source = 'exos' AND event_name = 'Listing Show')
            FROM public.exos_s4k_listings WHERE event_id = pg_temp.u('e1')), 'L1: rows';
  ASSERT pg_temp.refused($q$SELECT public.exos_feed_link_user('Albert', 'nobody@x.com')$q$, 'no user'), 'L1: unknown user';
END $$;
SET ROLE authenticated;
SELECT set_config('app.uid', 'a9000000-0000-0000-0000-0000000000c0', false);
DO $$ BEGIN ASSERT (SELECT count(*) FROM public.exos_s4k_listings) = 3, 'L1: Albert reads'; END $$;
SELECT set_config('app.uid', 'a9000000-0000-0000-0000-0000000000c1', false);
DO $$ BEGIN ASSERT (SELECT count(*) FROM public.exos_s4k_listings) = 0, 'L1: another user reads nothing'; END $$;
RESET ROLE;
SELECT pg_temp.act(NULL);

-- L2. Sales refill from the pool.
DO $$
DECLARE r jsonb;
BEGIN
  r := public.exos_feed_place_order((SELECT hash FROM tok), pg_temp.u('e1'), pg_temp.u('d1'), 4, 'L2-1', 'stubhub', 40);
  ASSERT r->>'result' = 'created', 'L2: ' || r::text;
  ASSERT pg_temp.qtys() = '{8,8,8}', 'L2: refilled (26 held) ' || pg_temp.qtys()::text;
  r := public.exos_feed_place_order((SELECT hash FROM tok), pg_temp.u('e1'), pg_temp.u('d1'), 6, 'L2-2', 'vivid', 40);
  ASSERT pg_temp.qtys() = '{8,8,4}', 'L2: 20 held ' || pg_temp.qtys()::text;
END $$;

-- L3. The cron pass rebalances: up to 24 held, from Exos + Eventbrite's pool.
DO $$
DECLARE v_before int;
BEGIN
  v_before := public.exos_effective_available(pg_temp.u('d1'));
  PERFORM public.exos_feed_refresh(NULL);
  ASSERT (pg_temp.pool()).requested_qty = 24 AND (pg_temp.pool()).sell_cap = 34, 'L3: pool ' || (pg_temp.pool())::text;
  ASSERT pg_temp.qtys() = '{8,8,8}', 'L3: full again ' || pg_temp.qtys()::text;
  ASSERT public.exos_effective_available(pg_temp.u('d1')) = v_before - 4, 'L3: taken from the shared pool';
  -- Exos sells all but 11 of its pool: S4K can take 3 more, never the last 8.
  UPDATE public.exos_ticket_tiers SET sold = sold + (public.exos_effective_available(pg_temp.u('d1')) - 11) WHERE id = pg_temp.u('d1');
  PERFORM public.exos_feed_place_order((SELECT hash FROM tok), pg_temp.u('e1'), pg_temp.u('d1'), 8, 'L3-1', 'stubhub', 40);
  PERFORM public.exos_feed_refresh(NULL);
  ASSERT (pg_temp.pool()).requested_qty = 19, 'L3: 16 + 3 ' || (pg_temp.pool())::text;
  ASSERT public.exos_effective_available(pg_temp.u('d1')) = 8, 'L3: one set left for the primary';
  PERFORM public.exos_feed_refresh(NULL);
  ASSERT (pg_temp.pool()).requested_qty = 19, 'L3: nothing more to take';
END $$;

-- L4. A quiet refresh writes nothing.
DO $$
DECLARE v_at timestamptz;
BEGIN
  UPDATE public.exos_s4k_listings SET updated_at = now() - interval '1 hour' WHERE event_id = pg_temp.u('e1');
  SELECT max(updated_at) INTO v_at FROM public.exos_s4k_listings WHERE event_id = pg_temp.u('e1');
  PERFORM public.exos_feed_refresh(pg_temp.u('e1'));
  ASSERT (SELECT max(updated_at) FROM public.exos_s4k_listings WHERE event_id = pg_temp.u('e1')) = v_at, 'L4: no write';
END $$;

-- L5. The organizer's listing quantity.
DO $$
DECLARE o jsonb;
BEGIN
  PERFORM pg_temp.act('a9000000-0000-0000-0000-0000000000a0');
  ASSERT pg_temp.refused($q$SELECT public.exos_set_resale_options(pg_temp.u('e1'), 0)$q$, '1 to 50'), 'L5: 0 refused';
  o := public.exos_set_resale_options(pg_temp.u('e1'), 5);
  ASSERT o->>'listing_qty' = '5' AND o->>'primary_source' = 'exos' AND o->>'rebalance' = 'true', 'L5: ' || o::text;
  PERFORM pg_temp.act(NULL);
  PERFORM public.exos_feed_refresh(pg_temp.u('e1'));
  ASSERT pg_temp.qtys() = '{5,5,5}', 'L5: listings of 5 ' || pg_temp.qtys()::text;
  ASSERT (SELECT bool_and(max_quantity = 5) FROM public.exos_s4k_listings WHERE event_id = pg_temp.u('e1')), 'L5: max 5';
END $$;

-- L6. The primary source.
DO $$
DECLARE v_raw int; c record;
BEGIN
  PERFORM pg_temp.act('a9000000-0000-0000-0000-0000000000a0');
  ASSERT pg_temp.refused($q$SELECT public.exos_set_resale_options(pg_temp.u('e1'), NULL, 'eventbrite')$q$, 'link this event to Eventbrite'), 'L6: needs a link';
  PERFORM pg_temp.act(NULL);
  PERFORM public.exos_eventbrite_connect('a9000000-0000-0000-0000-000000000001', pg_temp.u('a0'), 'TOKENLIST0001', 'Room');
  PERFORM public.exos_eventbrite_link(pg_temp.u('e1'), pg_temp.u('a0'), '777', 'Listing Show on Eventbrite');
  PERFORM public.exos_eventbrite_map_ticket(pg_temp.u('e1'), pg_temp.u('a0'), '7001', 'General Admission', pg_temp.u('d1'));
  -- Exos primary: Eventbrite holds back max(one pack 8, one set 5) = 8 of the 8 free.
  SELECT * INTO c FROM public.exos_eventbrite_inventory_apply(pg_temp.u('e1'), '[{"id":"7001","quantity_sold":"0","capacity":"10"}]'::jsonb, now());
  ASSERT c.target_capacity = 0, 'L6: Exos primary keeps the last set ' || c::text;
  PERFORM pg_temp.act('a9000000-0000-0000-0000-0000000000a0');
  ASSERT public.exos_set_resale_options(pg_temp.u('e1'), NULL, 'eventbrite')->>'primary_source' = 'eventbrite', 'L6: set';
  PERFORM pg_temp.act(NULL);
  v_raw := public._exos_tier_free_raw(pg_temp.u('d1'));
  ASSERT v_raw = 8, 'L6: raw ' || v_raw;
  ASSERT public.exos_effective_available(pg_temp.u('d1')) = 3, 'L6: Exos checkout stops at the last set (8 - 5)';
  ASSERT NOT public.exos_seats_available(pg_temp.u('d1'), 4), 'L6: a checkout can''t take the hold';
  SELECT * INTO c FROM public.exos_eventbrite_inventory_apply(pg_temp.u('e1'), '[{"id":"7001","quantity_sold":"0","capacity":"10"}]'::jsonb, now() + interval '1 second');
  ASSERT c.target_capacity = 5, 'L6: Eventbrite gets the held set (3 free - pack 8 -> 0, + 5) ' || c::text;
  -- An Eventbrite sale of the held seats is counted, not oversold.
  SELECT * INTO c FROM public.exos_eventbrite_inventory_apply(pg_temp.u('e1'), '[{"id":"7001","quantity_sold":"5","capacity":"5"}]'::jsonb, now() + interval '2 seconds');
  ASSERT c.oversold = 0, 'L6: counted ' || c::text;
  ASSERT public._exos_tier_free_raw(pg_temp.u('d1')) = 3 AND public.exos_effective_available(pg_temp.u('d1')) = 0,
         'L6: 3 left, all Eventbrite''s now';
  PERFORM public.exos_feed_refresh(pg_temp.u('e1'));
  ASSERT (SELECT bool_and(primary_source = 'eventbrite') FROM public.exos_s4k_listings WHERE event_id = pg_temp.u('e1')), 'L6: listings say so';
END $$;

-- L7. Off the route: the listings come down.
DO $$
BEGIN
  PERFORM pg_temp.act('a9000000-0000-0000-0000-0000000000a0');
  PERFORM public.exos_set_distribution_route(pg_temp.u('e1'), 'direct');
  PERFORM pg_temp.act(NULL);
  PERFORM public.exos_feed_refresh(NULL);
  ASSERT pg_temp.qtys() = '{}', 'L7: taken down ' || pg_temp.qtys()::text;
END $$;

-- L8. Grants.
DO $$
BEGIN
  ASSERT has_table_privilege('authenticated', 'public.exos_s4k_listings', 'SELECT')
     AND NOT has_table_privilege('authenticated', 'public.exos_s4k_listings', 'INSERT')
     AND NOT has_table_privilege('anon', 'public.exos_s4k_listings', 'SELECT'), 'L8: listings';
  ASSERT NOT has_function_privilege('authenticated', 'public.exos_s4k_rebalance(uuid)', 'EXECUTE'), 'L8: rebalance';
  ASSERT NOT has_function_privilege('authenticated', 'public.exos_feed_link_user(text, text)', 'EXECUTE'), 'L8: link user';
  ASSERT NOT has_function_privilege('authenticated', 'public._exos_tier_free_raw(uuid)', 'EXECUTE'), 'L8: raw';
  ASSERT has_function_privilege('authenticated', 'public.exos_set_resale_options(uuid, integer, text, boolean)', 'EXECUTE')
     AND NOT has_function_privilege('anon', 'public.exos_set_resale_options(uuid, integer, text, boolean)', 'EXECUTE'), 'L8: options';
END $$;

\echo 'test_s4k_listings: all passed'
ROLLBACK;
