-- ============================================================================
-- Two inventory pools (mig 20261014130000):
--   P1 the split's guards: owner / manager only, S4K route only, no free or
--      uncapped ticket types, not below an overall cap's sum, not below what
--      S4K sold, raising it only with seats free now (with how many)
--   P2 the pools: S4K's split is out of what Exos (and so Eventbrite) can
--      sell; Exos's sales never touch S4K's seats; the feed shows S4K's
--   P3 status: both pools per ticket type
--   P4 the pool holds its whole split, with no top-up schedule or cutoff
--   P5 leaving the route releases the unsold seats (sold kept); coming back
--      and splitting again revives the pool
--   P6 the owner leaving the network releases them too
--   P7 a ticket type with no split isn't on the feed
--   P8 grants
-- Self-contained (a7 prefix), rolled back.
-- ============================================================================
\set ON_ERROR_STOP on
BEGIN;
INSERT INTO auth.users(id,email,email_confirmed_at) VALUES
  ('a7000000-0000-0000-0000-0000000000a0','a7-owner@x.com',now()),
  ('a7000000-0000-0000-0000-0000000000a1','a7-manager@x.com',now()),
  ('a7000000-0000-0000-0000-0000000000a2','a7-scanner@x.com',now()),
  ('a7000000-0000-0000-0000-0000000000b0','a7-other@x.com',now());
INSERT INTO public.exos_orgs(id,name,slug,owner_uid) VALUES
  ('a7000000-0000-0000-0000-000000000001','A7 Org','a7-org','a7000000-0000-0000-0000-0000000000a0'),
  ('a7000000-0000-0000-0000-000000000002','A7 Other','a7-other','a7000000-0000-0000-0000-0000000000b0');
INSERT INTO public.exos_org_memberships(org_id,user_id,role) VALUES
  ('a7000000-0000-0000-0000-000000000001','a7000000-0000-0000-0000-0000000000a0','owner'),
  ('a7000000-0000-0000-0000-000000000001','a7000000-0000-0000-0000-0000000000a1','manager'),
  ('a7000000-0000-0000-0000-000000000001','a7000000-0000-0000-0000-0000000000a2','scanner'),
  ('a7000000-0000-0000-0000-000000000002','a7000000-0000-0000-0000-0000000000b0','owner');
-- e1: the split show. e2: overall cap below its ticket types (40 < 60).
INSERT INTO public.exos_events(id,org_id,name,status,starts_at,venue_name,total_tickets,tickets_sold,purchase_limits,timezone) VALUES
  ('a7000000-0000-0000-0000-0000000000e1','a7000000-0000-0000-0000-000000000001','Pool Show','published',now() + interval '20 days','Hall',0,0,'{"maxPerOrder":4}','America/New_York'),
  ('a7000000-0000-0000-0000-0000000000e2','a7000000-0000-0000-0000-000000000001','Capped Show','published',now() + interval '20 days','Hall',40,0,'{}','America/New_York');
INSERT INTO public.exos_ticket_tiers(id,event_id,name,price,capacity,sold,visibility,sort_order) VALUES
  ('a7000000-0000-0000-0000-0000000000d1','a7000000-0000-0000-0000-0000000000e1','GA',40,100,0,'public',1),
  ('a7000000-0000-0000-0000-0000000000d2','a7000000-0000-0000-0000-0000000000e1','VIP',90,20,0,'public',2),
  ('a7000000-0000-0000-0000-0000000000d3','a7000000-0000-0000-0000-0000000000e1','Free',0,50,0,'public',3),
  ('a7000000-0000-0000-0000-0000000000d4','a7000000-0000-0000-0000-0000000000e1','Open',25,0,0,'public',4),
  ('a7000000-0000-0000-0000-0000000000d5','a7000000-0000-0000-0000-0000000000e2','GA',40,30,0,'public',1),
  ('a7000000-0000-0000-0000-0000000000d6','a7000000-0000-0000-0000-0000000000e2','GA2',40,30,0,'public',2);

CREATE FUNCTION pg_temp.act(p_uid text) RETURNS void LANGUAGE sql AS $$
  SELECT set_config('app.uid', coalesce(p_uid, ''), false), set_config('app.jwt', '{"email":"a7@x.com"}', false);
$$;
CREATE FUNCTION pg_temp.u(p text) RETURNS uuid LANGUAGE sql AS $$ SELECT ('a7000000-0000-0000-0000-0000000000' || p)::uuid $$;
CREATE FUNCTION pg_temp.split(p_event text, p_tier text, p_seats int) RETURNS jsonb LANGUAGE sql AS $$
  SELECT public.exos_set_s4k_split(pg_temp.u(p_event), jsonb_build_array(jsonb_build_object('tier_id', pg_temp.u(p_tier), 'seats', p_seats)))
$$;
CREATE FUNCTION pg_temp.pool(p_tier text) RETURNS public.exos_distribution_listings LANGUAGE sql AS $$
  SELECT * FROM public.exos_distribution_listings WHERE tier_id = pg_temp.u(p_tier) AND channel = 's4k'
$$;
-- Expect an error with this SQLSTATE and (part of) this message.
CREATE FUNCTION pg_temp.refused(p_sql text, p_state text, p_like text) RETURNS boolean LANGUAGE plpgsql AS $$
BEGIN
  EXECUTE p_sql;
  RETURN false;
EXCEPTION WHEN others THEN
  IF SQLSTATE <> p_state OR SQLERRM NOT LIKE '%' || p_like || '%' THEN
    RAISE EXCEPTION 'expected % "%", got % "%"', p_state, p_like, SQLSTATE, SQLERRM;
  END IF;
  RETURN true;
END $$;
CREATE TEMP TABLE tok(token text, hash text);

-- Join the network; e1 and e2 on the S4K route.
DO $$
BEGIN
  PERFORM pg_temp.act('a7000000-0000-0000-0000-0000000000a0');
  PERFORM public.exos_set_s4k_network('a7000000-0000-0000-0000-000000000001', true);
  PERFORM public.exos_set_distribution_route(pg_temp.u('e2'), 's4k');
END $$;
INSERT INTO tok SELECT c.token, encode(extensions.digest(c.token, 'sha256'), 'hex')
  FROM public.exos_feed_create_consumer('S4K pools', 'fulfil@s4k.example') c;

-- P1. Guards.
DO $$
BEGIN
  PERFORM pg_temp.act('a7000000-0000-0000-0000-0000000000a1');
  ASSERT pg_temp.refused($q$SELECT pg_temp.split('e1', 'd1', 10)$q$, '22023', 'S4K network first'), 'P1: direct event';
  PERFORM public.exos_set_distribution_route(pg_temp.u('e1'), 's4k');
  PERFORM pg_temp.act('a7000000-0000-0000-0000-0000000000a2');
  ASSERT pg_temp.refused($q$SELECT pg_temp.split('e1', 'd1', 10)$q$, '42501', 'not allowed'), 'P1: scanner';
  PERFORM pg_temp.act('a7000000-0000-0000-0000-0000000000b0');
  ASSERT pg_temp.refused($q$SELECT pg_temp.split('e1', 'd1', 10)$q$, '42501', 'not allowed'), 'P1: outsider';
  PERFORM pg_temp.act('a7000000-0000-0000-0000-0000000000a1');
  ASSERT pg_temp.refused($q$SELECT pg_temp.split('e1', 'd3', 10)$q$, '22023', 'is free'), 'P1: free tier';
  ASSERT pg_temp.refused($q$SELECT pg_temp.split('e1', 'd4', 10)$q$, '22023', 'capacity'), 'P1: uncapped tier';
  ASSERT pg_temp.refused($q$SELECT pg_temp.split('e2', 'd5', 10)$q$, '23514', 'overall capacity (40)'), 'P1: cap below sum';
  ASSERT pg_temp.refused($q$SELECT pg_temp.split('e1', 'd5', 10)$q$, '22023', 'not found'), 'P1: another event''s tier';
  ASSERT pg_temp.refused($q$SELECT public.exos_set_s4k_split(pg_temp.u('e1'), '[{"tier_id":"x","seats":1}]')$q$, '22023', '{tier_id, seats}'), 'P1: bad payload';
  ASSERT pg_temp.refused($q$SELECT public.exos_set_s4k_split(pg_temp.u('e1'), '{}')$q$, '22023', 'array'), 'P1: not an array';
  -- Exos sells 85 of GA: only 15 can go to S4K.
  UPDATE public.exos_ticket_tiers SET sold = 85 WHERE id = pg_temp.u('d1');
  ASSERT pg_temp.refused($q$SELECT pg_temp.split('e1', 'd1', 20)$q$, '23514', 'only 15 more seat(s) of GA'), 'P1: not free';
  UPDATE public.exos_ticket_tiers SET sold = 0 WHERE id = pg_temp.u('d1');
  -- Zero on a ticket type with no pool is a no-op.
  PERFORM pg_temp.split('e1', 'd3', 0);
  ASSERT (pg_temp.pool('d3')).id IS NULL, 'P1: no row for 0';
END $$;

-- P2. The pools.
DO $$
DECLARE r jsonb; t jsonb;
BEGIN
  PERFORM pg_temp.act('a7000000-0000-0000-0000-0000000000a1');
  r := public.exos_set_s4k_split(pg_temp.u('e1'), jsonb_build_array(
         jsonb_build_object('tier_id', pg_temp.u('d1'), 'seats', 30),
         jsonb_build_object('tier_id', pg_temp.u('d2'), 'seats', 5)));
  ASSERT (pg_temp.pool('d1')).requested_qty = 30 AND (pg_temp.pool('d1')).sell_cap = 30
     AND (pg_temp.pool('d1')).status = 'planned', 'P2: pool holds 30';
  -- Pool 1 (Exos + Eventbrite) is the other 70.
  ASSERT public.exos_effective_available(pg_temp.u('d1')) = 70, 'P2: Exos sees 70';
  ASSERT public.exos_seats_available(pg_temp.u('d1'), 70) AND NOT public.exos_seats_available(pg_temp.u('d1'), 71),
         'P2: a checkout can''t take S4K''s seats';
  -- Exos sells its 70: S4K still has its 30.
  UPDATE public.exos_ticket_tiers SET sold = 70 WHERE id = pg_temp.u('d1');
  ASSERT public.exos_effective_available(pg_temp.u('d1')) = 0, 'P2: Exos sold out';
  PERFORM pg_temp.act(NULL);
  t := public.exos_feed_event_tickets((SELECT hash FROM tok), pg_temp.u('e1'));
  ASSERT (SELECT (l->>'quantity')::int FROM jsonb_array_elements(t->'tickets') l WHERE l->>'tier_id' = pg_temp.u('d1')::text) = 30,
         'P2: feed shows S4K''s 30 ' || t::text;
  ASSERT (SELECT (l->>'quantity')::int FROM jsonb_array_elements(t->'tickets') l WHERE l->>'tier_id' = pg_temp.u('d2')::text) = 5,
         'P2: VIP 5';
  -- S4K buys 4: from its pool only.
  r := public.exos_feed_place_order((SELECT hash FROM tok), pg_temp.u('e1'), pg_temp.u('d1'), 4, 'P2-1', 'stubhub', 40);
  ASSERT r->>'result' = 'created', 'P2: S4K order ' || r::text;
  ASSERT (pg_temp.pool('d1')).requested_qty = 26 AND (pg_temp.pool('d1')).sold_qty = 4, 'P2: taken from the pool';
  ASSERT (SELECT distribution_listing_id FROM public.exos_marketplace_orders WHERE external_order_id = 'P2-1') = (pg_temp.pool('d1')).id,
         'P2: order tied to the pool';
  ASSERT public.exos_effective_available(pg_temp.u('d1')) = 0, 'P2: Exos pool still 0';
  -- More than the pool: rejected, never filled from pool 1.
  UPDATE public.exos_ticket_tiers SET sold = sold - 10 WHERE id = pg_temp.u('d1');   -- Exos refunds 10
  r := public.exos_feed_place_order((SELECT hash FROM tok), pg_temp.u('e1'), pg_temp.u('d2'), 4, 'P2-2', 'stubhub', 90);
  ASSERT r->>'result' = 'created', 'P2: VIP 4 of 5 ' || r::text;
  r := public.exos_feed_place_order((SELECT hash FROM tok), pg_temp.u('e1'), pg_temp.u('d2'), 2, 'P2-3', 'stubhub', 90);
  ASSERT r->>'result' = 'rejected' AND r->>'reason' = 'sold_out' AND (r->>'available')::int = 1, 'P2: over the pool ' || r::text;
  ASSERT (SELECT sold FROM public.exos_ticket_tiers WHERE id = pg_temp.u('d2')) = 4, 'P2: nothing taken from pool 1';
END $$;

-- P3. Status.
DO $$
DECLARE s jsonb; g jsonb;
BEGIN
  PERFORM pg_temp.act('a7000000-0000-0000-0000-0000000000a0');
  s := public.exos_s4k_pool_status(pg_temp.u('e1'));
  ASSERT s->>'route' = 's4k' AND (s->>'on_feed')::boolean, 'P3: route ' || s::text;
  SELECT value INTO g FROM jsonb_array_elements(s->'tiers') WHERE value->>'name' = 'GA';
  ASSERT (g->>'s4k_split')::int = 30 AND (g->>'s4k_sold')::int = 4 AND (g->>'s4k_held')::int = 26
     AND (g->>'shared_free')::int = 10 AND (g->>'splittable')::boolean, 'P3: GA ' || g::text;
  SELECT value INTO g FROM jsonb_array_elements(s->'tiers') WHERE value->>'name' = 'Free';
  ASSERT NOT (g->>'splittable')::boolean AND (g->>'s4k_split')::int = 0, 'P3: Free ' || g::text;
  PERFORM pg_temp.act('a7000000-0000-0000-0000-0000000000a2');
  ASSERT pg_temp.refused($q$SELECT public.exos_s4k_pool_status(pg_temp.u('e1'))$q$, '42501', 'not allowed'), 'P3: scanner';
END $$;

-- P4. The whole split, no schedule: idle, scarce or near the day, it stays.
DO $$
DECLARE p record;
BEGIN
  UPDATE public.exos_distribution_listings SET idle_since = now() - interval '10 days' WHERE id = (pg_temp.pool('d1')).id;
  SELECT * INTO p FROM public.exos_channel_pool_plan((pg_temp.pool('d1')).id);
  ASSERT p.target = 26 AND p.state = 'split', 'P4: plan ' || p::text;
  PERFORM public.exos_refill_channel_pools();
  ASSERT (pg_temp.pool('d1')).requested_qty = 26, 'P4: refill leaves it';
  -- Lowering it below what S4K sold is refused; to exactly that is fine.
  PERFORM pg_temp.act('a7000000-0000-0000-0000-0000000000a1');
  ASSERT pg_temp.refused($q$SELECT pg_temp.split('e1', 'd1', 3)$q$, '22023', 'already sold 4'), 'P4: below sold';
  PERFORM pg_temp.split('e1', 'd1', 4);
  ASSERT (pg_temp.pool('d1')).requested_qty = 0 AND public.exos_effective_available(pg_temp.u('d1')) = 36, 'P4: all unsold back to Exos';
  PERFORM pg_temp.split('e1', 'd1', 20);
  ASSERT (pg_temp.pool('d1')).requested_qty = 16 AND public.exos_effective_available(pg_temp.u('d1')) = 20, 'P4: raised again';
END $$;

-- P5. Leaving the route releases; coming back revives.
DO $$
BEGIN
  PERFORM pg_temp.act('a7000000-0000-0000-0000-0000000000a1');
  PERFORM public.exos_set_distribution_route(pg_temp.u('e1'), 'direct');
  ASSERT (pg_temp.pool('d1')).status = 'delisted' AND (pg_temp.pool('d1')).requested_qty = 0
     AND (pg_temp.pool('d1')).sold_qty = 4, 'P5: released, sold kept';
  ASSERT public.exos_effective_available(pg_temp.u('d1')) = 36, 'P5: all back to Exos';
  ASSERT pg_temp.refused($q$SELECT pg_temp.split('e1', 'd1', 10)$q$, '22023', 'S4K network first'), 'P5: no split off the route';
  PERFORM public.exos_set_distribution_route(pg_temp.u('e1'), 's4k');
  ASSERT public.exos_effective_available(pg_temp.u('d1')) = 36, 'P5: back on the route: nothing held until split';
  PERFORM pg_temp.split('e1', 'd1', 10);
  ASSERT (pg_temp.pool('d1')).status = 'planned' AND (pg_temp.pool('d1')).requested_qty = 6, 'P5: revived (10 − 4 sold)';
END $$;

-- P6. The owner leaves the network.
DO $$
BEGIN
  PERFORM pg_temp.act('a7000000-0000-0000-0000-0000000000a0');
  PERFORM public.exos_set_s4k_network('a7000000-0000-0000-0000-000000000001', false);
  ASSERT (pg_temp.pool('d1')).status = 'delisted' AND (pg_temp.pool('d2')).status = 'delisted', 'P6: released';
  ASSERT public.exos_effective_available(pg_temp.u('d2')) = 16, 'P6: VIP back (20 − 4 sold)';
END $$;

-- P7. No split, not on the feed.
DO $$
DECLARE t jsonb; r jsonb;
BEGIN
  PERFORM pg_temp.act('a7000000-0000-0000-0000-0000000000a0');
  PERFORM public.exos_set_s4k_network('a7000000-0000-0000-0000-000000000001', true);
  PERFORM public.exos_set_distribution_route(pg_temp.u('e1'), 's4k');
  PERFORM pg_temp.split('e1', 'd2', 6);
  PERFORM pg_temp.act(NULL);
  t := public.exos_feed_event_tickets((SELECT hash FROM tok), pg_temp.u('e1'));
  ASSERT jsonb_array_length(t->'tickets') = 1 AND t->'tickets'->0->>'tier_id' = pg_temp.u('d2')::text, 'P7: only VIP ' || t::text;
  r := public.exos_feed_place_order((SELECT hash FROM tok), pg_temp.u('e1'), pg_temp.u('d1'), 1, 'P7-1', NULL, 40);
  ASSERT r->>'reason' = 'ticket_not_on_feed', 'P7: GA order ' || r::text;
END $$;

-- P8. Grants.
DO $$
BEGIN
  ASSERT has_function_privilege('authenticated', 'public.exos_set_s4k_split(uuid, jsonb)', 'EXECUTE'), 'P8: split';
  ASSERT NOT has_function_privilege('anon', 'public.exos_set_s4k_split(uuid, jsonb)', 'EXECUTE'), 'P8: split anon';
  ASSERT NOT has_function_privilege('anon', 'public.exos_s4k_pool_status(uuid)', 'EXECUTE'), 'P8: status anon';
  ASSERT NOT has_function_privilege('authenticated', 'public._exos_s4k_pool(uuid)', 'EXECUTE'), 'P8: pool helper';
  ASSERT NOT has_function_privilege('authenticated', 'public.exos_tg_s4k_route_release()', 'EXECUTE'), 'P8: trigger fn';
END $$;

\echo 'test_s4k_pools: all passed'
ROLLBACK;
