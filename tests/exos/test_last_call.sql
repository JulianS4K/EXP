-- ============================================================================
-- Last call (mig 20261029100000): at or below the threshold, only the primary
-- checkout sells.
--   L1 remaining: tier sums, the overall cap, an uncapped type (with and
--      without a cap), tables by party size; threshold: event > org >
--      platform (10), 0 = off
--   L2 the boundary: 11 left is not last call, 10 is
--   L3 primary Exos: marketplace pools plan 0 and are released, the auto split
--      plans nothing; Exos keeps selling; Eventbrite and Luma targets are
--      their sold counts (they still count sales); the storefront says exos
--   L4 primary Eventbrite: Exos sells nothing (checkout, public tiers);
--      Eventbrite's target is its sold + every free seat; Luma sold out; the
--      storefront points at Eventbrite's page
--   L5 primary Luma: the same the other way round, with the mirror's URL
--   L6 off again (threshold 0, cancelled): every channel back
--   L7 S4K: off the feed, pool planned 0 and released, listings dropped, no
--      rebalance
--   L8 RPCs: who may read / set; ranges
--   L9 grants: helpers service only; the storefront view is the only anon read
-- Self-contained (d7 prefix), rolled back. The harness turns last call off for
-- older fixtures; this file puts the platform default (10) back first.
-- ============================================================================
\set ON_ERROR_STOP on
BEGIN;
DELETE FROM public.exos_platform_settings
 WHERE key IN ('free_tier_max_capacity', 'resale_consent_required', 'free_tier_fee_bps', 'last_call_threshold');

INSERT INTO auth.users(id,email,email_confirmed_at) VALUES
  ('d7000000-0000-0000-0000-0000000000a0','d7-owner@x.com',now()),
  ('d7000000-0000-0000-0000-0000000000a1','d7-manager@x.com',now()),
  ('d7000000-0000-0000-0000-0000000000a2','d7-finance@x.com',now()),
  ('d7000000-0000-0000-0000-0000000000a3','d7-scanner@x.com',now()),
  ('d7000000-0000-0000-0000-0000000000a4','d7-stranger@x.com',now());
INSERT INTO public.exos_orgs(id,name,slug,owner_uid) VALUES
  ('d7000000-0000-0000-0000-000000000001','D7 Org','d7-org','d7000000-0000-0000-0000-0000000000a0');
INSERT INTO public.exos_org_memberships(org_id,user_id,role) VALUES
  ('d7000000-0000-0000-0000-000000000001','d7000000-0000-0000-0000-0000000000a0','owner'),
  ('d7000000-0000-0000-0000-000000000001','d7000000-0000-0000-0000-0000000000a1','manager'),
  ('d7000000-0000-0000-0000-000000000001','d7000000-0000-0000-0000-0000000000a2','finance'),
  ('d7000000-0000-0000-0000-000000000001','d7000000-0000-0000-0000-0000000000a3','scanner');
-- e1: GA 150 + VIP 50 (direct marketplaces, Eventbrite, Luma). e2: the same on
-- the S4K route. e3: cap 50 with an uncapped type. e4: uncapped, no cap.
-- e5: 10 tables of 4.
INSERT INTO public.exos_events(id,org_id,name,slug,status,starts_at,venue_name,total_tickets,tickets_sold,purchase_limits,timezone,distribution_networks,created_by) VALUES
  ('d7000000-0000-0000-0000-0000000000e1','d7000000-0000-0000-0000-000000000001','Show','d7-show','published',now() + interval '20 days','Hall',0,0,'{"maxPerOrder":4}','America/New_York','{}','d7000000-0000-0000-0000-0000000000a0'),
  ('d7000000-0000-0000-0000-0000000000e2','d7000000-0000-0000-0000-000000000001','S4K Show','d7-s4k','published',now() + interval '20 days','Hall',0,0,'{"maxPerOrder":4}','America/New_York','{}','d7000000-0000-0000-0000-0000000000a0'),
  ('d7000000-0000-0000-0000-0000000000e3','d7000000-0000-0000-0000-000000000001','Capped','d7-cap','published',now() + interval '20 days','Hall',50,8,'{}','America/New_York','{}','d7000000-0000-0000-0000-0000000000a0'),
  ('d7000000-0000-0000-0000-0000000000e4','d7000000-0000-0000-0000-000000000001','Open','d7-open','published',now() + interval '20 days','Hall',0,0,'{}','America/New_York','{}','d7000000-0000-0000-0000-0000000000a0'),
  ('d7000000-0000-0000-0000-0000000000e5','d7000000-0000-0000-0000-000000000001','Tables','d7-tables','published',now() + interval '20 days','Hall',0,0,'{}','America/New_York','{}','d7000000-0000-0000-0000-0000000000a0');
INSERT INTO public.exos_ticket_tiers(id,event_id,name,price,capacity,sold,visibility,sort_order,kind,party_size) VALUES
  ('d7000000-0000-0000-0000-0000000000d1','d7000000-0000-0000-0000-0000000000e1','GA',40,150,0,'public',1,'standard',NULL),
  ('d7000000-0000-0000-0000-0000000000d2','d7000000-0000-0000-0000-0000000000e1','VIP',90,50,0,'public',2,'standard',NULL),
  ('d7000000-0000-0000-0000-0000000000d3','d7000000-0000-0000-0000-0000000000e2','GA',40,150,0,'public',1,'standard',NULL),
  ('d7000000-0000-0000-0000-0000000000d4','d7000000-0000-0000-0000-0000000000e2','VIP',90,50,0,'public',2,'standard',NULL),
  ('d7000000-0000-0000-0000-0000000000d5','d7000000-0000-0000-0000-0000000000e3','GA',40,30,0,'public',1,'standard',NULL),
  ('d7000000-0000-0000-0000-0000000000d6','d7000000-0000-0000-0000-0000000000e3','Open',0,0,0,'public',2,'standard',NULL),
  ('d7000000-0000-0000-0000-0000000000d7','d7000000-0000-0000-0000-0000000000e4','Open',40,0,0,'public',1,'standard',NULL),
  ('d7000000-0000-0000-0000-0000000000d8','d7000000-0000-0000-0000-0000000000e5','Table',400,10,2,'public',1,'table',4);

CREATE FUNCTION pg_temp.act(p_uid text) RETURNS void LANGUAGE sql AS $$
  SELECT set_config('app.uid', coalesce(p_uid, ''), false), set_config('app.jwt', '{"email":"d7@x.com"}', false);
$$;
CREATE FUNCTION pg_temp.u(p text) RETURNS uuid LANGUAGE sql AS $$ SELECT ('d7000000-0000-0000-0000-0000000000' || p)::uuid $$;
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
-- Eventbrite reports GA 0 and VIP p_vip sold; Luma the same with its ids.
CREATE FUNCTION pg_temp.eb(p_vip int) RETURNS SETOF record LANGUAGE sql AS $$
  SELECT x.tier_id, x.target_capacity, x.skip_reason FROM public.exos_eventbrite_inventory_apply(pg_temp.u('e1'), jsonb_build_array(
    jsonb_build_object('id', '9101', 'capacity', 100, 'quantity_sold', 0),
    jsonb_build_object('id', '9102', 'capacity', 20, 'quantity_sold', p_vip)), clock_timestamp()) x
$$;
CREATE FUNCTION pg_temp.eb_target(p_vip int) RETURNS int LANGUAGE sql AS $$
  SELECT target FROM pg_temp.eb(p_vip) AS r(tier_id uuid, target int, skip text) WHERE tier_id = pg_temp.u('d2')
$$;
CREATE FUNCTION pg_temp.luma_target(p_vip int) RETURNS int LANGUAGE sql AS $$
  SELECT x.target_capacity FROM public.exos_luma_inventory_apply(pg_temp.u('e1'), jsonb_build_array(
    jsonb_build_object('id', 'lt-ga', 'sold', 0), jsonb_build_object('id', 'lt-vip', 'sold', p_vip)), clock_timestamp()) x
   WHERE x.tier_id = pg_temp.u('d2')
$$;
CREATE FUNCTION pg_temp.sales() RETURNS public.exos_public_event_sales LANGUAGE sql AS $$
  SELECT * FROM public.exos_public_event_sales WHERE event_id = pg_temp.u('e1')
$$;

-- Setup: opted in (resale), StubHub ticked with 10 VIP; Eventbrite and Luma
-- mirrors with both ticket types mapped.
DO $$
BEGIN
  PERFORM pg_temp.act('d7000000-0000-0000-0000-0000000000a0');
  PERFORM public.exos_set_resale_consent(pg_temp.u('e1'), true, '2026-10-29');
  PERFORM public.exos_set_resale_consent(pg_temp.u('e2'), true, '2026-10-29');
  UPDATE public.exos_events SET distribution_networks = ARRAY['stubhub'] WHERE id = pg_temp.u('e1');
  ASSERT public.exos_set_channel_allocation(pg_temp.u('e1'), 'stubhub', pg_temp.u('d2'), 10) = 10, 'setup: allocation';
  PERFORM pg_temp.act(NULL);
  PERFORM public.exos_eventbrite_connect('d7000000-0000-0000-0000-000000000001', pg_temp.u('a0'), 'TOKEND700001', 'D7 Room');
  PERFORM public.exos_eventbrite_link(pg_temp.u('e1'), pg_temp.u('a0'), '777001', 'Show on Eventbrite');
  PERFORM public.exos_eventbrite_map_ticket(pg_temp.u('e1'), pg_temp.u('a0'), '9101', 'GA', pg_temp.u('d1'));
  PERFORM public.exos_eventbrite_map_ticket(pg_temp.u('e1'), pg_temp.u('a0'), '9102', 'VIP', pg_temp.u('d2'));
  INSERT INTO public.exos_channel_mirrors (event_id, provider, org_id, mode, external_id, external_url, status)
  VALUES (pg_temp.u('e1'), 'luma', 'd7000000-0000-0000-0000-000000000001', 'link', 'evt-d7show', 'https://luma.com/d7-show', 'synced');
  INSERT INTO public.exos_luma_ticket_links (event_id, luma_event_id, luma_ticket_type_id, luma_ticket_name, tier_id) VALUES
    (pg_temp.u('e1'), 'evt-d7show', 'lt-ga', 'GA', pg_temp.u('d1')),
    (pg_temp.u('e1'), 'evt-d7show', 'lt-vip', 'VIP', pg_temp.u('d2'));
  -- Eventbrite has sold 2 VIP, Luma 1: counted against Exos.
  ASSERT pg_temp.eb_target(2) > 2 AND pg_temp.luma_target(1) > 1, 'setup: both platforms sell';
  ASSERT (SELECT sold FROM public.exos_ticket_tiers WHERE id = pg_temp.u('d2')) = 3, 'setup: counted';
END $$;

-- L1. Remaining and the threshold.
DO $$
BEGIN
  ASSERT public.exos_event_remaining(pg_temp.u('e1')) = 197, 'L1: tier sums';
  ASSERT public.exos_event_remaining(pg_temp.u('e3')) = 42, 'L1: the overall cap with an uncapped type';
  ASSERT public.exos_event_remaining(pg_temp.u('e4')) IS NULL AND NOT public.exos_event_last_call(pg_temp.u('e4')), 'L1: no limit';
  ASSERT public.exos_event_remaining(pg_temp.u('e5')) = 32, 'L1: 8 tables of 4';
  ASSERT public.exos_event_last_call_threshold(pg_temp.u('e1')) = 10, 'L1: platform default 10';
  UPDATE public.exos_orgs SET last_call_threshold = 40 WHERE id = 'd7000000-0000-0000-0000-000000000001';
  ASSERT public.exos_event_last_call_threshold(pg_temp.u('e1')) = 40, 'L1: the org''s';
  ASSERT public.exos_event_last_call(pg_temp.u('e5')) AND public.exos_event_last_call(pg_temp.u('e3')) IS FALSE, 'L1: 32 <= 40, 42 > 40';
  UPDATE public.exos_events SET last_call_threshold = 5 WHERE id = pg_temp.u('e5');
  ASSERT public.exos_event_last_call_threshold(pg_temp.u('e5')) = 5 AND NOT public.exos_event_last_call(pg_temp.u('e5')), 'L1: the event''s';
  UPDATE public.exos_events SET last_call_threshold = 0 WHERE id = pg_temp.u('e5');
  UPDATE public.exos_ticket_tiers SET sold = 10 WHERE id = pg_temp.u('d8');
  ASSERT public.exos_event_remaining(pg_temp.u('e5')) = 0 AND NOT public.exos_event_last_call(pg_temp.u('e5')), 'L1: 0 is off';
  UPDATE public.exos_orgs SET last_call_threshold = NULL WHERE id = 'd7000000-0000-0000-0000-000000000001';
  INSERT INTO public.exos_platform_settings (key, value) VALUES ('last_call_threshold', '25');
  ASSERT public.exos_event_last_call_threshold(pg_temp.u('e1')) = 25, 'L1: the operator setting';
  DELETE FROM public.exos_platform_settings WHERE key = 'last_call_threshold';
END $$;

-- L2. The boundary: GA sold out, 11 VIP left, then 10.
DO $$
DECLARE p record;
BEGIN
  UPDATE public.exos_ticket_tiers SET sold = 150 WHERE id = pg_temp.u('d1');
  UPDATE public.exos_ticket_tiers SET sold = 39 WHERE id = pg_temp.u('d2');
  ASSERT public.exos_event_remaining(pg_temp.u('e1')) = 11 AND NOT public.exos_event_last_call(pg_temp.u('e1')), 'L2: 11 left';
  SELECT * INTO p FROM public.exos_channel_pool_plan((SELECT id FROM public.exos_distribution_listings
                                                       WHERE tier_id = pg_temp.u('d2') AND channel = 'stubhub'));
  ASSERT p.state <> 'last_call', 'L2: pool not last call yet ' || p::text;
  UPDATE public.exos_ticket_tiers SET sold = 40 WHERE id = pg_temp.u('d2');
  ASSERT public.exos_event_remaining(pg_temp.u('e1')) = 10 AND public.exos_event_last_call(pg_temp.u('e1')), 'L2: 10 left';
END $$;

-- L3. Primary Exos.
DO $$
DECLARE p record; v_alloc uuid; s public.exos_public_event_sales;
BEGIN
  SELECT id INTO v_alloc FROM public.exos_distribution_listings WHERE tier_id = pg_temp.u('d2') AND channel = 'stubhub';
  SELECT * INTO p FROM public.exos_channel_pool_plan(v_alloc);
  ASSERT p.target = 0 AND p.state = 'last_call', 'L3: pool plan ' || p::text;
  ASSERT NOT EXISTS (SELECT 1 FROM public._exos_channel_split_plan(pg_temp.u('e1'))), 'L3: no auto split';
  PERFORM public.exos_refill_channel_pools();
  ASSERT (SELECT requested_qty FROM public.exos_distribution_listings WHERE id = v_alloc) = 0, 'L3: released';
  ASSERT public.exos_tier_available(pg_temp.u('d2')) = 10, 'L3: Exos sells the last 10';
  ASSERT pg_temp.eb_target(2) = 2, 'L3: Eventbrite sold out';
  ASSERT pg_temp.luma_target(1) = 1, 'L3: Luma sold out';
  -- They still count: a Luma refund gives the seat back, a new Eventbrite sale takes one.
  PERFORM pg_temp.luma_target(0);
  PERFORM pg_temp.eb_target(3);
  ASSERT (SELECT sold FROM public.exos_ticket_tiers WHERE id = pg_temp.u('d2')) = 40, 'L3: counted (+1 -1)';
  ASSERT pg_temp.eb_target(3) = 3 AND pg_temp.luma_target(0) = 0, 'L3: targets follow the counts';
  s := pg_temp.sales();
  ASSERT s.last_call AND s.sells_on = 'exos' AND s.sells_on_url IS NULL, 'L3: storefront ' || s::text;
END $$;

-- L4. Primary Eventbrite.
DO $$
DECLARE s public.exos_public_event_sales;
BEGIN
  UPDATE public.exos_events SET primary_source = 'eventbrite' WHERE id = pg_temp.u('e1');
  ASSERT public.exos_tier_available(pg_temp.u('d2')) = 0 AND public.exos_effective_available(pg_temp.u('d2')) = 0, 'L4: Exos closed';
  ASSERT (SELECT available FROM public.exos_public_tiers WHERE id = pg_temp.u('d2')) = 0, 'L4: public tiers say 0';
  ASSERT public._exos_tier_free_raw(pg_temp.u('d2')) = 10, 'L4: still 10 unsold';
  ASSERT pg_temp.eb_target(3) = 3 + 10, 'L4: Eventbrite gets every free seat';
  ASSERT pg_temp.luma_target(0) = 0, 'L4: Luma sold out';
  s := pg_temp.sales();
  ASSERT s.last_call AND s.sells_on = 'eventbrite' AND s.sells_on_url = 'https://www.eventbrite.com/e/777001', 'L4: storefront ' || s::text;
  -- The mirror's URL wins when there is one.
  INSERT INTO public.exos_channel_mirrors (event_id, provider, org_id, mode, external_id, external_url, status)
  VALUES (pg_temp.u('e1'), 'eventbrite', 'd7000000-0000-0000-0000-000000000001', 'link', '777001', 'https://www.eventbrite.com/e/show-777001', 'synced');
  ASSERT (pg_temp.sales()).sells_on_url = 'https://www.eventbrite.com/e/show-777001', 'L4: mirror URL';
  -- An Exos hold can't be made.
  PERFORM pg_temp.act('d7000000-0000-0000-0000-0000000000a4');
  ASSERT pg_temp.refused($q$SELECT public.exos_create_hold(pg_temp.u('e1'), pg_temp.u('d2'), 1, 600, NULL)$q$, ''), 'L4: no hold';
  PERFORM pg_temp.act(NULL);
END $$;

-- L5. Primary Luma.
DO $$
DECLARE s public.exos_public_event_sales;
BEGIN
  UPDATE public.exos_events SET primary_source = 'luma' WHERE id = pg_temp.u('e1');
  ASSERT public.exos_tier_available(pg_temp.u('d2')) = 0, 'L5: Exos closed';
  ASSERT pg_temp.luma_target(0) = 10, 'L5: Luma gets every free seat';
  ASSERT pg_temp.eb_target(3) = 3, 'L5: Eventbrite sold out';
  s := pg_temp.sales();
  ASSERT s.sells_on = 'luma' AND s.sells_on_url = 'https://luma.com/d7-show', 'L5: storefront ' || s::text;
END $$;

-- L6. Off again.
DO $$
BEGIN
  UPDATE public.exos_events SET last_call_threshold = 0 WHERE id = pg_temp.u('e1');
  ASSERT NOT public.exos_event_last_call(pg_temp.u('e1')) AND NOT (pg_temp.sales()).last_call, 'L6: off';
  ASSERT (pg_temp.sales()).sells_on = 'exos', 'L6: sells on Exos';
  -- Luma primary outside last call: the usual primary hold (one set of 8).
  ASSERT public.exos_tier_available(pg_temp.u('d2')) = 2, 'L6: Exos sells again, less the hold';
  ASSERT pg_temp.eb_target(3) = 3, 'L6: Eventbrite: 2 free less its pack of 4 = 0 more';
  UPDATE public.exos_events SET last_call_threshold = NULL, primary_source = 'exos' WHERE id = pg_temp.u('e1');
  ASSERT public.exos_event_last_call(pg_temp.u('e1')), 'L6: on with the default';
  UPDATE public.exos_events SET status = 'cancelled' WHERE id = pg_temp.u('e1');
  ASSERT NOT public.exos_event_last_call(pg_temp.u('e1')), 'L6: cancelled is not last call';
  UPDATE public.exos_events SET status = 'published' WHERE id = pg_temp.u('e1');
END $$;

-- L7. S4K.
DO $$
DECLARE p record; v_pool uuid;
BEGIN
  PERFORM pg_temp.act('d7000000-0000-0000-0000-0000000000a0');
  PERFORM public.exos_set_s4k_network('d7000000-0000-0000-0000-000000000001', true);
  PERFORM public.exos_set_distribution_route(pg_temp.u('e2'), 's4k');
  PERFORM public.exos_set_s4k_split(pg_temp.u('e2'), jsonb_build_array(jsonb_build_object('tier_id', pg_temp.u('d3'), 'seats', 20)));
  PERFORM public.exos_s4k_listings_sync(pg_temp.u('e2'));
  ASSERT public._exos_feed_eligible(pg_temp.u('e2')) AND EXISTS (SELECT 1 FROM public.exos_s4k_listings WHERE event_id = pg_temp.u('e2')), 'L7: listed';
  SELECT id INTO v_pool FROM public.exos_distribution_listings WHERE tier_id = pg_temp.u('d3') AND channel = 's4k';
  -- Last call by threshold: 200 left, threshold 200.
  PERFORM public.exos_set_last_call_threshold(pg_temp.u('e2'), 200);
  PERFORM pg_temp.act(NULL);
  ASSERT public.exos_event_remaining(pg_temp.u('e2')) = 200 AND public.exos_event_last_call(pg_temp.u('e2')), 'L7: last call';
  ASSERT NOT public._exos_feed_eligible(pg_temp.u('e2')), 'L7: off the feed';
  ASSERT NOT EXISTS (SELECT 1 FROM public._exos_feed_lines(pg_temp.u('e2')) WHERE quantity > 0)
      OR NOT public._exos_feed_eligible(pg_temp.u('e2')), 'L7: nothing to sell';
  SELECT * INTO p FROM public.exos_channel_pool_plan(v_pool);
  ASSERT p.target = 0 AND p.state = 'last_call', 'L7: plan ' || p::text;
  ASSERT public.exos_s4k_rebalance(pg_temp.u('e2')) = 0, 'L7: no rebalance';
  PERFORM public.exos_refill_channel_pools();
  ASSERT (SELECT requested_qty FROM public.exos_distribution_listings WHERE id = v_pool) = 0, 'L7: S4K pool released';
  ASSERT public.exos_event_remaining(pg_temp.u('e2')) = 200, 'L7: releasing doesn''t move remaining';
  PERFORM public.exos_s4k_listings_sync(pg_temp.u('e2'));
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_s4k_listings WHERE event_id = pg_temp.u('e2')), 'L7: listings dropped';
END $$;

-- L8. RPCs.
DO $$
DECLARE r jsonb;
BEGIN
  PERFORM pg_temp.act('d7000000-0000-0000-0000-0000000000a2');   -- finance reads
  r := public.exos_last_call_status(pg_temp.u('e1'));
  ASSERT (r ->> 'active')::boolean AND (r ->> 'remaining')::int = 10 AND (r ->> 'threshold')::int = 10
     AND r ->> 'threshold_source' = 'platform' AND r ->> 'primary_source' = 'exos' AND NOT (r ->> 'can_manage')::boolean, 'L8: status ' || r::text;
  ASSERT pg_temp.refused($q$SELECT public.exos_set_last_call_threshold(pg_temp.u('e1'), 5)$q$, 'not allowed'), 'L8: finance can''t set';
  ASSERT pg_temp.refused($q$SELECT public.exos_set_org_last_call_threshold('d7000000-0000-0000-0000-000000000001', 5)$q$, 'not allowed'), 'L8: finance org';
  PERFORM pg_temp.act('d7000000-0000-0000-0000-0000000000a3');
  ASSERT pg_temp.refused($q$SELECT public.exos_last_call_status(pg_temp.u('e1'))$q$, 'not allowed'), 'L8: scanner can''t read';
  ASSERT pg_temp.refused($q$SELECT public.exos_set_last_call_threshold(pg_temp.u('e1'), 5)$q$, 'not allowed'), 'L8: scanner can''t set';
  PERFORM pg_temp.act('d7000000-0000-0000-0000-0000000000a4');
  ASSERT pg_temp.refused($q$SELECT public.exos_last_call_status(pg_temp.u('e1'))$q$, 'not allowed'), 'L8: stranger';
  PERFORM pg_temp.act(NULL);
  ASSERT pg_temp.refused($q$SELECT public.exos_set_last_call_threshold(pg_temp.u('e1'), 5)$q$, 'not allowed'), 'L8: no user';
  PERFORM pg_temp.act('d7000000-0000-0000-0000-0000000000a1');   -- a manager sets
  ASSERT pg_temp.refused($q$SELECT public.exos_set_last_call_threshold(pg_temp.u('e1'), -1)$q$, '0 (off) to 10000'), 'L8: range low';
  ASSERT pg_temp.refused($q$SELECT public.exos_set_last_call_threshold(pg_temp.u('e1'), 10001)$q$, '0 (off) to 10000'), 'L8: range high';
  r := public.exos_set_last_call_threshold(pg_temp.u('e1'), 5);
  ASSERT NOT (r ->> 'active')::boolean AND r ->> 'threshold_source' = 'event', 'L8: set 5 ' || r::text;
  ASSERT public.exos_set_org_last_call_threshold('d7000000-0000-0000-0000-000000000001', 12) = 12, 'L8: org set';
  r := public.exos_set_last_call_threshold(pg_temp.u('e1'), NULL);
  ASSERT (r ->> 'active')::boolean AND (r ->> 'threshold')::int = 12 AND r ->> 'threshold_source' = 'org', 'L8: back to the org''s ' || r::text;
END $$;

-- L9. Grants.
DO $$
DECLARE f text;
BEGIN
  FOREACH f IN ARRAY ARRAY['public.exos_last_call_status(uuid)', 'public.exos_set_last_call_threshold(uuid, integer)',
                           'public.exos_set_org_last_call_threshold(uuid, integer)'] LOOP
    ASSERT NOT has_function_privilege('anon', f, 'EXECUTE') AND has_function_privilege('authenticated', f, 'EXECUTE'), 'L9: ' || f;
  END LOOP;
  FOREACH f IN ARRAY ARRAY['public.exos_last_call_default()', 'public.exos_event_last_call_threshold(uuid)',
                           'public.exos_event_remaining(uuid)', 'public.exos_event_last_call(uuid)',
                           'public.exos_last_call_closes(uuid, text)', 'public._exos_primary_url(uuid)',
                           'public._exos_primary_hold(uuid, bigint)'] LOOP
    ASSERT NOT has_function_privilege('anon', f, 'EXECUTE') AND NOT has_function_privilege('authenticated', f, 'EXECUTE'), 'L9: service only ' || f;
  END LOOP;
  ASSERT has_function_privilege('anon', 'public.exos_public_event_sale(uuid)', 'EXECUTE'), 'L9: the view''s function is the public one';
  ASSERT has_table_privilege('anon', 'public.exos_public_event_sales', 'SELECT')
     AND NOT has_table_privilege('anon', 'public.exos_public_event_sales', 'INSERT'), 'L9: the storefront view';
END $$;
-- The view as anon: published events only, and no more than where to buy.
DO $$ BEGIN PERFORM pg_temp.act(NULL); END $$;
UPDATE public.exos_events SET status = 'draft' WHERE id = pg_temp.u('e4');
SET ROLE anon;
DO $$ BEGIN
  ASSERT (SELECT last_call FROM public.exos_public_event_sales WHERE event_id = 'd7000000-0000-0000-0000-0000000000e1'), 'L9: anon reads it';
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_public_event_sales WHERE event_id = 'd7000000-0000-0000-0000-0000000000e4'), 'L9: drafts hidden';
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_public_event_sale('d7000000-0000-0000-0000-0000000000e4')), 'L9: the function hides drafts too';
  ASSERT (SELECT sells_on FROM public.exos_public_event_sale('d7000000-0000-0000-0000-0000000000e1')) = 'exos', 'L9: anon calls it';
END $$;
RESET ROLE;

\echo 'test_last_call: all passed'
ROLLBACK;
