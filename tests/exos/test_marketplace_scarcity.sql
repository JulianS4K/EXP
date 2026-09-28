-- ============================================================================
-- Scarcity mode for marketplace pools (mig 20260928040000). Self-contained
-- (5c prefix), rolled back at the end. Max per order 2 throughout, so a
-- full pool is 4 and Exos's floor is 2.
--   C1 cutoff: 3 hours before doors every pool goes to 0; one with nothing
--      live comes back at once, a live one lists 0 and keeps its seats until
--      the marketplace confirms
--   C2 stagnant: no sale in 24 hours -> one order's worth (not reloaded);
--      in scarcity -> 0
--   C3 the last day: 2 hours without a sale is stagnant
--   C4 selling pools are reloaded first, and to their full size, above
--      Exos's floor; quiet pools shrink to one order's worth in scarcity
--   C5 a sale marks the pool selling; publishing restarts the clock
--   C6 exos_pool_state: the org sees the state, a stranger gets NULL
--   psql -d <db> -v ON_ERROR_STOP=1 -f tests/exos/test_marketplace_scarcity.sql
-- ============================================================================
\set ON_ERROR_STOP on
BEGIN;
INSERT INTO auth.users(id,email,email_confirmed_at) VALUES
  ('5c000000-0000-0000-0000-0000000000a0','5c-owner@x.com',now()),
  ('5c000000-0000-0000-0000-0000000000a9','5c-stranger@x.com',now());
INSERT INTO public.exos_orgs(id,name,slug,owner_uid) VALUES
  ('5c000000-0000-0000-0000-000000000001','5C Org','5c-org','5c000000-0000-0000-0000-0000000000a0');
INSERT INTO public.exos_org_memberships(org_id,user_id,role) VALUES
  ('5c000000-0000-0000-0000-000000000001','5c000000-0000-0000-0000-0000000000a0','owner');

-- e1: tonight, doors in 2 hours (inside the 3-hour cutoff).
-- e2: next month.  e3: tomorrow (cutoff less than a day away).  e4: a draft.
INSERT INTO public.exos_events(id,org_id,name,status,starts_at,doors_at,venue_name,total_tickets,tickets_sold,distribution_networks,purchase_limits) VALUES
  ('5c000000-0000-0000-0000-0000000000e1','5c000000-0000-0000-0000-000000000001','Tonight','published',now() + interval '3 hours',now() + interval '2 hours','Hall',20,0,ARRAY['stubhub','seatgeek'],'{"maxPerOrder":2}'),
  ('5c000000-0000-0000-0000-0000000000e2','5c000000-0000-0000-0000-000000000001','Next month','published',now() + interval '30 days',NULL,'Hall',20,0,ARRAY['stubhub','seatgeek'],'{"maxPerOrder":2}'),
  ('5c000000-0000-0000-0000-0000000000e3','5c000000-0000-0000-0000-000000000001','Tomorrow','published',now() + interval '20 hours',NULL,'Hall',20,0,ARRAY['stubhub'],'{"maxPerOrder":2}'),
  ('5c000000-0000-0000-0000-0000000000e4','5c000000-0000-0000-0000-000000000001','Draft','draft',now() + interval '30 days',NULL,'Hall',20,0,ARRAY['stubhub'],'{"maxPerOrder":2}');
INSERT INTO public.exos_ticket_tiers(id,event_id,name,price,capacity,sold) VALUES
  ('5c000000-0000-0000-0000-0000000000d1','5c000000-0000-0000-0000-0000000000e1','GA',40,20,0),
  ('5c000000-0000-0000-0000-0000000000d2','5c000000-0000-0000-0000-0000000000e2','GA',40,20,0),
  ('5c000000-0000-0000-0000-0000000000d3','5c000000-0000-0000-0000-0000000000e3','GA',40,20,0),
  ('5c000000-0000-0000-0000-0000000000d4','5c000000-0000-0000-0000-0000000000e4','GA',40,20,0);

-- cap/sold/held/listed for a marketplace on a ticket type
CREATE OR REPLACE FUNCTION pg_temp.pool(p_ch text, p_tier text) RETURNS text LANGUAGE sql AS $$
  SELECT sell_cap||'/'||sold_qty||'/'||requested_qty||'/'||list_qty FROM public.exos_distribution_listings
   WHERE channel = p_ch AND tier_id = ('5c000000-0000-0000-0000-0000000000' || p_tier)::uuid
$$;
CREATE OR REPLACE FUNCTION pg_temp.state(p_ch text, p_tier text) RETURNS text LANGUAGE sql AS $$
  SELECT state FROM public.exos_channel_pool_plan((SELECT id FROM public.exos_distribution_listings
   WHERE channel = p_ch AND tier_id = ('5c000000-0000-0000-0000-0000000000' || p_tier)::uuid))
$$;
CREATE OR REPLACE FUNCTION pg_temp.free(p_tier text) RETURNS int LANGUAGE sql AS $$
  SELECT public.exos_tier_available(('5c000000-0000-0000-0000-0000000000' || p_tier)::uuid)
$$;

-- C1 ---------------------------------------------------------------------------
DO $$
BEGIN
  -- Inside the cutoff a pool takes nothing, whatever the cap.
  PERFORM public.exos_set_channel_allocation('5c000000-0000-0000-0000-0000000000e1','stubhub','5c000000-0000-0000-0000-0000000000d1',10);
  IF pg_temp.pool('stubhub','d1') <> '10/0/0/0' OR pg_temp.state('stubhub','d1') <> 'closed' OR pg_temp.free('d1') <> 20 THEN
    RAISE EXCEPTION 'C1 FAIL: a pool filled inside the cutoff: % %', pg_temp.pool('stubhub','d1'), pg_temp.state('stubhub','d1');
  END IF;
  -- A live SeatGeek pool from before the cutoff (4 seats): planned down to 0,
  -- seats held until SeatGeek confirms, then Exos has them for the door.
  INSERT INTO public.exos_distribution_listings (event_id, org_id, channel, status, tier_id, requested_qty, sell_cap, list_qty, internal_seats, external_listing_id)
  VALUES ('5c000000-0000-0000-0000-0000000000e1','5c000000-0000-0000-0000-000000000001','seatgeek','listed',
          '5c000000-0000-0000-0000-0000000000d1',4,10,4,'{[1,5)}','SG-LIVE');
  PERFORM public.exos_refill_channel_pools();
  IF pg_temp.pool('seatgeek','d1') <> '10/0/4/0' OR pg_temp.free('d1') <> 16 THEN
    RAISE EXCEPTION 'C1 FAIL: live pool at the cutoff: % (Exos %)', pg_temp.pool('seatgeek','d1'), pg_temp.free('d1');
  END IF;
  PERFORM public.exos_confirm_channel_listing((SELECT id FROM public.exos_distribution_listings WHERE external_listing_id = 'SG-LIVE'));
  IF pg_temp.pool('seatgeek','d1') <> '10/0/0/0' OR pg_temp.free('d1') <> 20 THEN
    RAISE EXCEPTION 'C1 FAIL: after SeatGeek confirmed: % (Exos %)', pg_temp.pool('seatgeek','d1'), pg_temp.free('d1');
  END IF;
  RAISE NOTICE 'C1 ok: 3 hours before doors pools go to 0 (live ones once the marketplace confirms); Exos sells the rest';
END $$;

-- C2 ---------------------------------------------------------------------------
DO $$
BEGIN
  PERFORM public.exos_set_channel_allocation('5c000000-0000-0000-0000-0000000000e2','stubhub','5c000000-0000-0000-0000-0000000000d2',10);
  PERFORM public.exos_set_channel_allocation('5c000000-0000-0000-0000-0000000000e2','seatgeek','5c000000-0000-0000-0000-0000000000d2',10);
  IF pg_temp.pool('stubhub','d2') <> '10/0/4/4' OR pg_temp.pool('seatgeek','d2') <> '10/0/4/4' OR pg_temp.state('stubhub','d2') <> 'normal' THEN
    RAISE EXCEPTION 'C2 FAIL: fresh pools % %', pg_temp.pool('stubhub','d2'), pg_temp.pool('seatgeek','d2');
  END IF;
  -- A day without a sale: stagnant, down to one order's worth.
  UPDATE public.exos_distribution_listings SET idle_since = now() - interval '25 hours'
   WHERE channel = 'stubhub' AND tier_id = '5c000000-0000-0000-0000-0000000000d2';
  PERFORM public.exos_refill_channel_pools();
  IF pg_temp.pool('stubhub','d2') <> '10/0/2/2' OR pg_temp.state('stubhub','d2') <> 'stagnant' OR pg_temp.free('d2') <> 14 THEN
    RAISE EXCEPTION 'C2 FAIL: stagnant pool % % (Exos %)', pg_temp.pool('stubhub','d2'), pg_temp.state('stubhub','d2'), pg_temp.free('d2');
  END IF;
  -- Exos sells down to 3 free (under 2 pools x 2): scarce, the stagnant pool goes to 0.
  UPDATE public.exos_ticket_tiers SET sold = 11 WHERE id = '5c000000-0000-0000-0000-0000000000d2';
  PERFORM public.exos_refill_channel_pools();
  IF pg_temp.pool('stubhub','d2') <> '10/0/0/0' THEN
    RAISE EXCEPTION 'C2 FAIL: stagnant in scarcity kept %', pg_temp.pool('stubhub','d2');
  END IF;
  -- Settles (SeatGeek may have dipped to 2 while the tier looked scarce):
  -- SeatGeek 4, Exos 5.
  PERFORM public.exos_refill_channel_pools();
  IF pg_temp.pool('seatgeek','d2') <> '10/0/4/4' OR pg_temp.free('d2') <> 5 THEN
    RAISE EXCEPTION 'C2 FAIL: did not settle: % (Exos %)', pg_temp.pool('seatgeek','d2'), pg_temp.free('d2');
  END IF;
  RAISE NOTICE 'C2 ok: a pool without a sale in a day drops to one order''s worth, and to 0 near sellout';
END $$;

-- C4 ---------------------------------------------------------------------------
-- Continues C2: 5 free (20 - 11 sold - SeatGeek 4; the scarcity line is 2
-- pools x 2 = 4). SeatGeek sells 2 and is reloaded to its full 4, above
-- Exos's floor (2); StubHub, not selling, gets none of it.
DO $$
DECLARE alloc uuid;
BEGIN
  SELECT id INTO alloc FROM public.exos_distribution_listings WHERE channel = 'seatgeek' AND tier_id = '5c000000-0000-0000-0000-0000000000d2';
  PERFORM public.exos_record_marketplace_order(jsonb_build_object('channel','seatgeek','external_order_id','C4-1',
    'external_listing_id', alloc::text, 'quantity',2,'sale_status','confirmed','buyer_email','c4@x.com'));
  PERFORM public.exos_fulfil_marketplace_order((SELECT id FROM public.exos_marketplace_orders WHERE external_order_id = 'C4-1'));
  IF pg_temp.pool('seatgeek','d2') <> '10/2/4/4' OR pg_temp.state('seatgeek','d2') <> 'selling' THEN
    RAISE EXCEPTION 'C4 FAIL: selling pool not reloaded: % %', pg_temp.pool('seatgeek','d2'), pg_temp.state('seatgeek','d2');
  END IF;
  IF (SELECT last_sold_at FROM public.exos_distribution_listings WHERE id = alloc) IS NULL THEN
    RAISE EXCEPTION 'C4 FAIL: last_sold_at not set';
  END IF;
  -- Exos sells 2 more (1 free): selling SeatGeek sells 2 again; Exos keeps its last seat.
  UPDATE public.exos_ticket_tiers SET sold = sold + 2 WHERE id = '5c000000-0000-0000-0000-0000000000d2';
  PERFORM public.exos_record_marketplace_order(jsonb_build_object('channel','seatgeek','external_order_id','C4-2',
    'external_listing_id', alloc::text, 'quantity',2,'sale_status','confirmed','buyer_email','c4b@x.com'));
  PERFORM public.exos_fulfil_marketplace_order((SELECT id FROM public.exos_marketplace_orders WHERE external_order_id = 'C4-2'));
  IF pg_temp.pool('seatgeek','d2') <> '10/4/2/2' OR pg_temp.free('d2') <> 1 THEN
    RAISE EXCEPTION 'C4 FAIL: reloaded below Exos''s floor: % (Exos %)', pg_temp.pool('seatgeek','d2'), pg_temp.free('d2');
  END IF;
  -- Refunds free 4 (5 free): the refill reloads SeatGeek first (to 4, Exos
  -- keeps 3); that makes the tier scarce again, so StubHub (not selling)
  -- stays at 0.
  UPDATE public.exos_ticket_tiers SET sold = sold - 4 WHERE id = '5c000000-0000-0000-0000-0000000000d2';
  PERFORM public.exos_refill_channel_pools();
  IF pg_temp.pool('seatgeek','d2') <> '10/4/4/4' OR pg_temp.pool('stubhub','d2') <> '10/0/0/0' OR pg_temp.free('d2') <> 3 THEN
    RAISE EXCEPTION 'C4 FAIL: refill order: SG % SH % (Exos %)', pg_temp.pool('seatgeek','d2'), pg_temp.pool('stubhub','d2'), pg_temp.free('d2');
  END IF;
  RAISE NOTICE 'C4 ok: selling marketplaces are reloaded first and in full, above Exos''s floor; stagnant ones get nothing';
END $$;

-- C3 ---------------------------------------------------------------------------
DO $$
BEGIN
  PERFORM public.exos_set_channel_allocation('5c000000-0000-0000-0000-0000000000e3','stubhub','5c000000-0000-0000-0000-0000000000d3',10);
  UPDATE public.exos_distribution_listings SET idle_since = now() - interval '3 hours'
   WHERE channel = 'stubhub' AND tier_id = '5c000000-0000-0000-0000-0000000000d3';
  IF pg_temp.state('stubhub','d3') <> 'stagnant' OR public.exos_channel_hold_target(
       (SELECT id FROM public.exos_distribution_listings WHERE channel = 'stubhub' AND tier_id = '5c000000-0000-0000-0000-0000000000d3')) <> 2 THEN
    RAISE EXCEPTION 'C3 FAIL: 3 idle hours on the last day: %', pg_temp.state('stubhub','d3');
  END IF;
  -- The same 3 hours a month out is fine.
  UPDATE public.exos_distribution_listings SET idle_since = now() - interval '3 hours'
   WHERE channel = 'seatgeek' AND tier_id = '5c000000-0000-0000-0000-0000000000d2';
  UPDATE public.exos_distribution_listings SET last_sold_at = now() - interval '3 hours'
   WHERE channel = 'seatgeek' AND tier_id = '5c000000-0000-0000-0000-0000000000d2';
  IF pg_temp.state('seatgeek','d2') <> 'selling' THEN RAISE EXCEPTION 'C3 FAIL: a month out, 3 hours is still selling'; END IF;
  RAISE NOTICE 'C3 ok: on the last day 2 hours without a sale is stagnant (24 hours before that)';
END $$;

-- C5 ---------------------------------------------------------------------------
DO $$
BEGIN
  PERFORM public.exos_set_channel_allocation('5c000000-0000-0000-0000-0000000000e4','stubhub','5c000000-0000-0000-0000-0000000000d4',6);
  UPDATE public.exos_distribution_listings SET idle_since = now() - interval '10 days'
   WHERE channel = 'stubhub' AND tier_id = '5c000000-0000-0000-0000-0000000000d4';
  -- Filled before going on sale: not stagnant while a draft...
  IF pg_temp.state('stubhub','d4') <> 'normal' THEN RAISE EXCEPTION 'C5 FAIL: a draft''s pool is %', pg_temp.state('stubhub','d4'); END IF;
  -- ...and publishing restarts the clock.
  UPDATE public.exos_events SET status = 'published' WHERE id = '5c000000-0000-0000-0000-0000000000e4';
  IF (SELECT idle_since FROM public.exos_distribution_listings WHERE channel = 'stubhub' AND tier_id = '5c000000-0000-0000-0000-0000000000d4') < now() - interval '1 minute'
     OR pg_temp.state('stubhub','d4') <> 'normal' THEN
    RAISE EXCEPTION 'C5 FAIL: publishing did not restart the clock';
  END IF;
  RAISE NOTICE 'C5 ok: the clock starts at publish (and at every sale, C4)';
END $$;

-- C6 ---------------------------------------------------------------------------
SELECT set_config('app.uid','5c000000-0000-0000-0000-0000000000a0',true);
SET LOCAL ROLE authenticated;
DO $$
BEGIN
  IF (SELECT public.exos_pool_state(d) FROM public.exos_distribution_listings d
       WHERE channel = 'seatgeek' AND tier_id = '5c000000-0000-0000-0000-0000000000d2') IS DISTINCT FROM 'selling' THEN
    RAISE EXCEPTION 'C6 FAIL: the owner can''t see the pool state';
  END IF;
END $$;
RESET ROLE;
DO $$
DECLARE r public.exos_distribution_listings;
BEGIN
  SELECT * INTO r FROM public.exos_distribution_listings WHERE channel = 'seatgeek' AND tier_id = '5c000000-0000-0000-0000-0000000000d2';
  PERFORM set_config('app.uid','5c000000-0000-0000-0000-0000000000a9',true);
  SET LOCAL ROLE authenticated;
  IF public.exos_pool_state(r) IS NOT NULL THEN RAISE EXCEPTION 'C6 FAIL: a stranger read the pool state'; END IF;
  RESET ROLE;
  RAISE NOTICE 'C6 ok: the org sees each pool''s state; strangers get nothing';
END $$;
ROLLBACK;
