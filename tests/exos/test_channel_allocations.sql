-- ============================================================================
-- Channel seat allocations (mig 20260926193000): Exos and StubHub can't sell
-- the same seat. Self-contained (4e prefix), rolled back at the end.
--   A1 allocated seats leave Exos availability (tier and shared quota)
--   A2 an allocation only takes free seats; shrinking gives them back
--   A3 refused when the house cap is tighter than the ticket types, for
--      table tiers, and for strangers
--   A4 a StubHub sale uses its allocation: it goes through even when Exos
--      has sold everything else, and Exos still can't sell those seats
--   A5 StubHub selling more than allocated goes to a human, nothing changes
--   A6 delisting releases the seats
--   (20260927030000)
--   A7 per ticket type: several tiers per marketplace, both marketplaces; a
--      marketplace that isn't ticked is refused
--   A8 internal seat numbers: one per allocated seat, never shared across
--      marketplaces, grow with new numbers, shrink from the top
--   A9 a marketplace sale gives each ticket an internal seat (the SeatGeek
--      listing's own seats when the order says which)
--   A10 pulling back: unticking / unpublishing releases unsent allocations at
--      once; a live one goes to 'delisting' and keeps its seats until it's down
--   A11 setting 0 on a live listing = delist then release; can't change it
--      while it's being delisted
--   A12 drafts keep their allocations (fill the grid before publishing)
--   (20260927050000)
--   A13 one standard on every marketplace: a StubHub sale records its listing
--       (listing_ref) and gets that block's seats, like SeatGeek and Gametime
--   (20260928010000)
--   A14 small pools: the grid sets a cap; the marketplace holds only 2 x max
--       per order at a time, Exos can sell the rest
--   A15 a sale tops the pool back up, with free seats only; later frees are
--       picked up by the refill run
--   A16 shrinking a LIVE listing keeps the seats held (the listings show the
--       lower number) until the marketplace confirms it
--   psql -d <db> -v ON_ERROR_STOP=1 -f tests/exos/test_channel_allocations.sql
-- ============================================================================
\set ON_ERROR_STOP on
BEGIN;
INSERT INTO auth.users(id,email,email_confirmed_at) VALUES
  ('4e000000-0000-0000-0000-0000000000a0','4e-owner@x.com',now()),
  ('4e000000-0000-0000-0000-0000000000a9','4e-stranger@x.com',now());
INSERT INTO public.exos_orgs(id,name,slug,owner_uid) VALUES
  ('4e000000-0000-0000-0000-000000000001','4E Org','4e-org','4e000000-0000-0000-0000-0000000000a0');
INSERT INTO public.exos_org_memberships(org_id,user_id,role) VALUES
  ('4e000000-0000-0000-0000-000000000001','4e000000-0000-0000-0000-0000000000a0','owner');
INSERT INTO public.exos_events(id,org_id,name,status,starts_at,venue_name,total_tickets,tickets_sold,distribution_networks) VALUES
  ('4e000000-0000-0000-0000-0000000000e1','4e000000-0000-0000-0000-000000000001','Show','published','2027-01-01T02:00:00Z','Hall',15,0,ARRAY['stubhub','seatgeek']),
  ('4e000000-0000-0000-0000-0000000000e2','4e000000-0000-0000-0000-000000000001','Tight cap','published','2027-01-02T02:00:00Z','Hall',5,0,ARRAY['stubhub']);
INSERT INTO public.exos_ticket_tiers(id,event_id,name,price,capacity,sold) VALUES
  ('4e000000-0000-0000-0000-0000000000d1','4e000000-0000-0000-0000-0000000000e1','GA',50,10,0),
  ('4e000000-0000-0000-0000-0000000000d2','4e000000-0000-0000-0000-0000000000e1','VIP',150,5,0),
  ('4e000000-0000-0000-0000-0000000000d3','4e000000-0000-0000-0000-0000000000e2','GA',50,10,0);
INSERT INTO public.exos_quotas(id,event_id,org_id,name,size) VALUES
  ('4e000000-0000-0000-0000-0000000000c1','4e000000-0000-0000-0000-0000000000e1','4e000000-0000-0000-0000-000000000001','Floor',8);
INSERT INTO public.exos_quota_tiers(quota_id,tier_id) VALUES
  ('4e000000-0000-0000-0000-0000000000c1','4e000000-0000-0000-0000-0000000000d1');

-- A1 ---------------------------------------------------------------------------
DO $$
BEGIN
  IF public.exos_set_channel_allocation('4e000000-0000-0000-0000-0000000000e1','stubhub','4e000000-0000-0000-0000-0000000000d1',3) <> 3 THEN
    RAISE EXCEPTION 'A1 FAIL: allocation not set';
  END IF;
  IF public.exos_tier_available('4e000000-0000-0000-0000-0000000000d1') <> 7 THEN
    RAISE EXCEPTION 'A1 FAIL: tier availability % (want 10 - 3)', public.exos_tier_available('4e000000-0000-0000-0000-0000000000d1');
  END IF;
  IF public.exos_quota_available('4e000000-0000-0000-0000-0000000000c1') <> 5 THEN
    RAISE EXCEPTION 'A1 FAIL: quota availability % (want 8 - 3)', public.exos_quota_available('4e000000-0000-0000-0000-0000000000c1');
  END IF;
  -- Every Exos path asks this: 5 left for Exos (the quota binds), not 6.
  IF NOT public.exos_seats_available('4e000000-0000-0000-0000-0000000000d1', 5)
     OR public.exos_seats_available('4e000000-0000-0000-0000-0000000000d1', 6) THEN
    RAISE EXCEPTION 'A1 FAIL: exos_seats_available ignores the allocation';
  END IF;
  -- The event-request row (no ticket type, no quantity) holds nothing.
  IF public.exos_tier_available('4e000000-0000-0000-0000-0000000000d2') <> 5 THEN
    RAISE EXCEPTION 'A1 FAIL: VIP affected';
  END IF;
  RAISE NOTICE 'A1 ok: allocated seats leave Exos tier + quota availability';
END $$;

-- A2 ---------------------------------------------------------------------------
UPDATE public.exos_ticket_tiers SET sold = 4 WHERE id = '4e000000-0000-0000-0000-0000000000d1';  -- Exos sold 4
DO $$
BEGIN
  -- Quota: 8 - 4 sold... tickets count, so mint real ones is not needed here;
  -- the tier has 10 - 4 - 3 = 3 more free. Asking for 3 + 4 = 7 must fail.
  BEGIN
    PERFORM public.exos_set_channel_allocation('4e000000-0000-0000-0000-0000000000e1','stubhub','4e000000-0000-0000-0000-0000000000d1',7);
    RAISE EXCEPTION 'A2 FAIL: allocated seats Exos already sold';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
  -- A cap of 6 fits (3 held + 3 free), but with 3 free the ticket type is
  -- scarce (20260928040000): the pool doesn't grow into Exos's floor of one
  -- order's worth (4), so Exos keeps its 3.
  PERFORM public.exos_set_channel_allocation('4e000000-0000-0000-0000-0000000000e1','stubhub','4e000000-0000-0000-0000-0000000000d1',6);
  IF public.exos_tier_available('4e000000-0000-0000-0000-0000000000d1') <> 3 THEN
    RAISE EXCEPTION 'A2 FAIL: scarce: the pool grew into Exos''s floor (Exos has %)', public.exos_tier_available('4e000000-0000-0000-0000-0000000000d1');
  END IF;
  PERFORM public.exos_set_channel_allocation('4e000000-0000-0000-0000-0000000000e1','stubhub','4e000000-0000-0000-0000-0000000000d1',2);
  IF public.exos_tier_available('4e000000-0000-0000-0000-0000000000d1') <> 4 THEN
    RAISE EXCEPTION 'A2 FAIL: shrinking did not give seats back';
  END IF;
  RAISE NOTICE 'A2 ok: allocations only take free seats; shrinking releases them';
END $$;

-- A3 ---------------------------------------------------------------------------
DO $$
BEGIN
  BEGIN
    PERFORM public.exos_set_channel_allocation('4e000000-0000-0000-0000-0000000000e2','stubhub','4e000000-0000-0000-0000-0000000000d3',1);
    RAISE EXCEPTION 'A3 FAIL: allocated under a house cap tighter than the tiers';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
  BEGIN
    PERFORM public.exos_set_channel_allocation('4e000000-0000-0000-0000-0000000000e1','stubhub','4e000000-0000-0000-0000-0000000000d3',1);
    RAISE EXCEPTION 'A3 FAIL: tier from another event';
  EXCEPTION WHEN raise_exception THEN NULL;
  END;
END $$;
SELECT set_config('app.uid','4e000000-0000-0000-0000-0000000000a9',true);
SET LOCAL ROLE authenticated;
DO $$
BEGIN
  BEGIN
    PERFORM public.exos_set_channel_allocation('4e000000-0000-0000-0000-0000000000e1','stubhub','4e000000-0000-0000-0000-0000000000d1',1);
    RAISE EXCEPTION 'A3 FAIL: stranger set an allocation';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
END $$;
SELECT set_config('app.uid','4e000000-0000-0000-0000-0000000000a0',true);
DO $$
BEGIN
  IF public.exos_set_channel_allocation('4e000000-0000-0000-0000-0000000000e1','stubhub','4e000000-0000-0000-0000-0000000000d1',3) <> 3 THEN
    RAISE EXCEPTION 'A3 FAIL: owner could not set the allocation';
  END IF;
  -- 4 free = Exos's floor (one order's worth per pool): the pool stays at 2.
  IF (SELECT requested_qty FROM public.exos_distribution_listings
       WHERE channel = 'stubhub' AND tier_id = '4e000000-0000-0000-0000-0000000000d1') <> 2 THEN
    RAISE EXCEPTION 'A3 FAIL: the pool grew into Exos''s floor';
  END IF;
  RAISE NOTICE 'A3 ok: tight house cap / wrong tier / strangers refused; owner allowed';
END $$;
RESET ROLE;

-- A4 ---------------------------------------------------------------------------
-- Exos sells everything it can (10 - 4 - 2 = 4 more): now sold 8, pool 2.
UPDATE public.exos_ticket_tiers SET sold = 8 WHERE id = '4e000000-0000-0000-0000-0000000000d1';
UPDATE public.exos_events SET tickets_sold = 8 WHERE id = '4e000000-0000-0000-0000-0000000000e1';
UPDATE public.exos_distribution_listings SET status = 'listed', external_listing_id = 'SH-A'
 WHERE event_id = '4e000000-0000-0000-0000-0000000000e1' AND channel = 'stubhub'
   AND tier_id = '4e000000-0000-0000-0000-0000000000d1';
DO $$
DECLARE o record;
BEGIN
  IF public.exos_seats_available('4e000000-0000-0000-0000-0000000000d1', 1) THEN
    RAISE EXCEPTION 'A4 FAIL: Exos can still sell a StubHub seat';
  END IF;
  PERFORM public.exos_record_marketplace_order('{"channel":"stubhub","external_order_id":"A4","external_listing_id":"SH-A","quantity":1,"sale_status":"confirmed","buyer_email":"sh@x.com"}');
  PERFORM public.exos_fulfil_marketplace_order((SELECT id FROM public.exos_marketplace_orders WHERE external_order_id = 'A4'));
  SELECT * INTO o FROM public.exos_marketplace_orders WHERE external_order_id = 'A4';
  IF o.status <> 'fulfilled' THEN RAISE EXCEPTION 'A4 FAIL: StubHub sale refused: %', o.attention_reason; END IF;
  IF (SELECT sold FROM public.exos_ticket_tiers WHERE id = '4e000000-0000-0000-0000-0000000000d1') <> 9
     OR (SELECT requested_qty FROM public.exos_distribution_listings WHERE external_listing_id = 'SH-A') <> 1
     OR public.exos_tier_available('4e000000-0000-0000-0000-0000000000d1') <> 0 THEN
    RAISE EXCEPTION 'A4 FAIL: counts after the StubHub sale';
  END IF;
  RAISE NOTICE 'A4 ok: StubHub sale uses its own seats; Exos never could';
END $$;

-- A5 ---------------------------------------------------------------------------
DO $$
DECLARE o record;
BEGIN
  PERFORM public.exos_record_marketplace_order('{"channel":"stubhub","external_order_id":"A5","external_listing_id":"SH-A","quantity":2,"sale_status":"confirmed","buyer_email":"sh2@x.com"}');
  PERFORM public.exos_fulfil_marketplace_order((SELECT id FROM public.exos_marketplace_orders WHERE external_order_id = 'A5'));
  SELECT * INTO o FROM public.exos_marketplace_orders WHERE external_order_id = 'A5';
  IF o.status <> 'needs_attention' OR o.attention_reason NOT LIKE '%only 1 were allocated%' THEN
    RAISE EXCEPTION 'A5 FAIL: %', row_to_json(o);
  END IF;
  IF (SELECT requested_qty FROM public.exos_distribution_listings WHERE external_listing_id = 'SH-A') <> 1
     OR (SELECT sold FROM public.exos_ticket_tiers WHERE id = '4e000000-0000-0000-0000-0000000000d1') <> 9 THEN
    RAISE EXCEPTION 'A5 FAIL: counts changed';
  END IF;
  RAISE NOTICE 'A5 ok: overselling the allocation goes to a human';
END $$;

-- A6 ---------------------------------------------------------------------------
UPDATE public.exos_distribution_listings SET status = 'delisted' WHERE external_listing_id = 'SH-A';
DO $$
BEGIN
  IF public.exos_tier_available('4e000000-0000-0000-0000-0000000000d1') <> 1 THEN
    RAISE EXCEPTION 'A6 FAIL: delisting did not release the seat';
  END IF;
  RAISE NOTICE 'A6 ok: delisting gives the seats back to Exos';
END $$;
-- A7-A12: a fresh event with two ticket types on both marketplaces ----------------
INSERT INTO public.exos_events(id,org_id,name,status,starts_at,venue_name,total_tickets,tickets_sold,distribution_networks) VALUES
  ('4e000000-0000-0000-0000-0000000000e3','4e000000-0000-0000-0000-000000000001','Grid','published','2027-02-01T02:00:00Z','Hall',30,0,ARRAY['stubhub','seatgeek']),
  ('4e000000-0000-0000-0000-0000000000e4','4e000000-0000-0000-0000-000000000001','Draft grid','draft','2027-02-02T02:00:00Z','Hall',10,0,ARRAY['seatgeek']);
INSERT INTO public.exos_ticket_tiers(id,event_id,name,price,capacity,sold) VALUES
  ('4e000000-0000-0000-0000-0000000000d4','4e000000-0000-0000-0000-0000000000e3','GA',40,20,0),
  ('4e000000-0000-0000-0000-0000000000d5','4e000000-0000-0000-0000-0000000000e3','VIP',120,10,0),
  ('4e000000-0000-0000-0000-0000000000d6','4e000000-0000-0000-0000-0000000000e4','GA',40,10,0);
CREATE OR REPLACE FUNCTION pg_temp.alloc(p_ch text, p_tier text) RETURNS public.exos_distribution_listings LANGUAGE sql AS $$
  SELECT * FROM public.exos_distribution_listings
   WHERE channel = p_ch AND tier_id = ('4e000000-0000-0000-0000-0000000000' || p_tier)::uuid
$$;

-- A7 ---------------------------------------------------------------------------
DO $$
BEGIN
  PERFORM public.exos_set_channel_allocation('4e000000-0000-0000-0000-0000000000e3','stubhub','4e000000-0000-0000-0000-0000000000d4',4);
  PERFORM public.exos_set_channel_allocation('4e000000-0000-0000-0000-0000000000e3','stubhub','4e000000-0000-0000-0000-0000000000d5',2);
  PERFORM public.exos_set_channel_allocation('4e000000-0000-0000-0000-0000000000e3','seatgeek','4e000000-0000-0000-0000-0000000000d4',6);
  IF (SELECT count(*) FROM public.exos_distribution_listings WHERE event_id = '4e000000-0000-0000-0000-0000000000e3' AND tier_id IS NOT NULL) <> 3
     OR (SELECT count(*) FROM public.exos_distribution_listings WHERE event_id = '4e000000-0000-0000-0000-0000000000e3' AND tier_id IS NULL) <> 2 THEN
    RAISE EXCEPTION 'A7 FAIL: want 3 allocation rows + 2 event rows';
  END IF;
  IF public.exos_tier_available('4e000000-0000-0000-0000-0000000000d4') <> 10
     OR public.exos_tier_available('4e000000-0000-0000-0000-0000000000d5') <> 8 THEN
    RAISE EXCEPTION 'A7 FAIL: availability GA % VIP %', public.exos_tier_available('4e000000-0000-0000-0000-0000000000d4'),
      public.exos_tier_available('4e000000-0000-0000-0000-0000000000d5');
  END IF;
  BEGIN
    PERFORM public.exos_set_channel_allocation('4e000000-0000-0000-0000-0000000000e2','seatgeek','4e000000-0000-0000-0000-0000000000d3',1);
    RAISE EXCEPTION 'A7 FAIL: allocated to a marketplace that is not ticked';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM NOT LIKE '%tick SeatGeek%' THEN RAISE; END IF;
  END;
  RAISE NOTICE 'A7 ok: a row per ticket type per marketplace; unticked marketplaces refused';
END $$;

-- A8 ---------------------------------------------------------------------------
DO $$
DECLARE sh int4multirange; sg int4multirange;
BEGIN
  sh := (pg_temp.alloc('stubhub','d4')).internal_seats;
  sg := (pg_temp.alloc('seatgeek','d4')).internal_seats;
  IF sh <> '{[1,5)}' OR sg <> '{[5,11)}' THEN RAISE EXCEPTION 'A8 FAIL: first blocks % %', sh, sg; END IF;
  IF (pg_temp.alloc('stubhub','d5')).internal_seats <> '{[1,3)}' THEN RAISE EXCEPTION 'A8 FAIL: VIP numbers are per ticket type'; END IF;
  PERFORM public.exos_set_channel_allocation('4e000000-0000-0000-0000-0000000000e3','stubhub','4e000000-0000-0000-0000-0000000000d4',6);
  PERFORM public.exos_set_channel_allocation('4e000000-0000-0000-0000-0000000000e3','seatgeek','4e000000-0000-0000-0000-0000000000d4',4);
  sh := (pg_temp.alloc('stubhub','d4')).internal_seats;
  sg := (pg_temp.alloc('seatgeek','d4')).internal_seats;
  IF sh <> '{[1,5),[11,13)}' OR sg <> '{[5,9)}' THEN RAISE EXCEPTION 'A8 FAIL: after grow/shrink % %', sh, sg; END IF;
  IF NOT isempty(sh * sg) THEN RAISE EXCEPTION 'A8 FAIL: marketplaces share a seat'; END IF;
  IF public.exos_seat_count(sh) <> (pg_temp.alloc('stubhub','d4')).requested_qty THEN RAISE EXCEPTION 'A8 FAIL: count'; END IF;
  RAISE NOTICE 'A8 ok: internal seats per allocated seat, unique across marketplaces';
END $$;

-- A9 ---------------------------------------------------------------------------
-- exos-distribute planned SeatGeek listing 2 as seats 7-8.
UPDATE public.exos_distribution_listings
   SET planned_listing = jsonb_build_object('listings', jsonb_build_array(
         jsonb_build_object('body', jsonb_build_object('seller_listing_id','exaaaaaaaaaaaaaaaaaaaaaaaaaa1','seat_from','5','seat_thru','6')),
         jsonb_build_object('body', jsonb_build_object('seller_listing_id','exaaaaaaaaaaaaaaaaaaaaaaaaaa2','seat_from','7','seat_thru','8'))))
 WHERE id = (pg_temp.alloc('seatgeek','d4')).id;
DO $$
DECLARE o record; v_seats int[];
BEGIN
  PERFORM public.exos_record_marketplace_order(jsonb_build_object(
    'channel','seatgeek','external_order_id','A9-SG','external_listing_id',(pg_temp.alloc('seatgeek','d4')).id::text,
    'quantity',2,'sale_status','confirmed','buyer_email','sg@x.com',
    'raw', jsonb_build_object('id','A9-SG','listing', jsonb_build_object('id','exaaaaaaaaaaaaaaaaaaaaaaaaaa2','quantity',2))));
  PERFORM public.exos_fulfil_marketplace_order((SELECT id FROM public.exos_marketplace_orders WHERE external_order_id = 'A9-SG'));
  SELECT * INTO o FROM public.exos_marketplace_orders WHERE external_order_id = 'A9-SG';
  IF o.status <> 'fulfilled' THEN RAISE EXCEPTION 'A9 FAIL: %', o.attention_reason; END IF;
  SELECT array_agg(internal_seat ORDER BY internal_seat) INTO v_seats FROM public.exos_tickets WHERE id = ANY (o.ticket_ids);
  IF v_seats <> ARRAY[7,8] THEN RAISE EXCEPTION 'A9 FAIL: SeatGeek tickets got seats %', v_seats; END IF;
  IF (pg_temp.alloc('seatgeek','d4')).internal_seats <> '{[5,7)}' OR (pg_temp.alloc('seatgeek','d4')).requested_qty <> 2 THEN
    RAISE EXCEPTION 'A9 FAIL: allocation after the sale %', row_to_json(pg_temp.alloc('seatgeek','d4'));
  END IF;
  -- StubHub (no seats on its listing): a seat from the top.
  PERFORM public.exos_record_marketplace_order(jsonb_build_object(
    'channel','stubhub','external_order_id','A9-SH','external_listing_id',(pg_temp.alloc('stubhub','d4')).id::text,
    'quantity',1,'sale_status','confirmed','buyer_email','sh3@x.com'));
  PERFORM public.exos_fulfil_marketplace_order((SELECT id FROM public.exos_marketplace_orders WHERE external_order_id = 'A9-SH'));
  SELECT * INTO o FROM public.exos_marketplace_orders WHERE external_order_id = 'A9-SH';
  IF (SELECT internal_seat FROM public.exos_tickets WHERE id = o.ticket_ids[1]) IS DISTINCT FROM 12 THEN
    RAISE EXCEPTION 'A9 FAIL: StubHub ticket seat %', (SELECT internal_seat FROM public.exos_tickets WHERE id = o.ticket_ids[1]);
  END IF;
  IF (pg_temp.alloc('stubhub','d4')).internal_seats <> '{[1,5),[11,12)}' THEN RAISE EXCEPTION 'A9 FAIL: StubHub seats left'; END IF;
  RAISE NOTICE 'A9 ok: marketplace tickets get internal seats (the SeatGeek listing''s own when known)';
END $$;

-- A12 --------------------------------------------------------------------------
DO $$
BEGIN
  PERFORM public.exos_set_channel_allocation('4e000000-0000-0000-0000-0000000000e4','seatgeek','4e000000-0000-0000-0000-0000000000d6',3);
  UPDATE public.exos_events SET name = 'Draft grid (edited)' WHERE id = '4e000000-0000-0000-0000-0000000000e4';
  UPDATE public.exos_events SET status = 'published' WHERE id = '4e000000-0000-0000-0000-0000000000e4';
  IF (pg_temp.alloc('seatgeek','d6')).requested_qty <> 3 OR (pg_temp.alloc('seatgeek','d6')).status <> 'pending' THEN
    RAISE EXCEPTION 'A12 FAIL: draft allocation lost: %', row_to_json(pg_temp.alloc('seatgeek','d6'));
  END IF;
  RAISE NOTICE 'A12 ok: the grid can be filled before publishing';
END $$;

-- A10 --------------------------------------------------------------------------
-- StubHub GA went live; StubHub VIP didn't.
UPDATE public.exos_distribution_listings SET status = 'listed', external_listing_id = 'SH-G'
 WHERE id = (pg_temp.alloc('stubhub','d4')).id;
UPDATE public.exos_events SET distribution_networks = ARRAY['seatgeek'] WHERE id = '4e000000-0000-0000-0000-0000000000e3';
DO $$
BEGIN
  IF (pg_temp.alloc('stubhub','d5')).status <> 'delisted' OR (pg_temp.alloc('stubhub','d5')).requested_qty <> 0
     OR NOT isempty((pg_temp.alloc('stubhub','d5')).internal_seats) THEN
    RAISE EXCEPTION 'A10 FAIL: unsent allocation not released: %', row_to_json(pg_temp.alloc('stubhub','d5'));
  END IF;
  IF public.exos_tier_available('4e000000-0000-0000-0000-0000000000d5') <> 10 THEN RAISE EXCEPTION 'A10 FAIL: VIP seats not back'; END IF;
  IF (pg_temp.alloc('stubhub','d4')).status <> 'delisting' OR (pg_temp.alloc('stubhub','d4')).requested_qty <> 5 THEN
    RAISE EXCEPTION 'A10 FAIL: live listing should be delisting with its seats: %', row_to_json(pg_temp.alloc('stubhub','d4'));
  END IF;
  -- GA: 20 - 3 sold - 5 (StubHub, delisting) - 2 (SeatGeek) = 10.
  IF public.exos_tier_available('4e000000-0000-0000-0000-0000000000d4') <> 10 THEN
    RAISE EXCEPTION 'A10 FAIL: GA available % (want 10)', public.exos_tier_available('4e000000-0000-0000-0000-0000000000d4');
  END IF;
  IF (pg_temp.alloc('seatgeek','d4')).requested_qty <> 2 THEN RAISE EXCEPTION 'A10 FAIL: SeatGeek touched'; END IF;
  IF EXISTS (SELECT 1 FROM public.exos_distribution_listings WHERE event_id = '4e000000-0000-0000-0000-0000000000e3'
              AND channel = 'stubhub' AND tier_id IS NULL) THEN
    RAISE EXCEPTION 'A10 FAIL: StubHub event row kept';
  END IF;
END $$;
-- StubHub confirms the delist: the seats come back.
UPDATE public.exos_distribution_listings SET status = 'delisted' WHERE id = (pg_temp.alloc('stubhub','d4')).id;
-- Unpublishing pulls SeatGeek back too.
UPDATE public.exos_events SET status = 'draft' WHERE id = '4e000000-0000-0000-0000-0000000000e3';
DO $$
BEGIN
  IF (pg_temp.alloc('seatgeek','d4')).status <> 'delisted' THEN RAISE EXCEPTION 'A10 FAIL: unpublish kept SeatGeek seats'; END IF;
  IF public.exos_tier_available('4e000000-0000-0000-0000-0000000000d4') <> 17 THEN
    RAISE EXCEPTION 'A10 FAIL: GA available % (want 20 - 3 sold)', public.exos_tier_available('4e000000-0000-0000-0000-0000000000d4');
  END IF;
  RAISE NOTICE 'A10 ok: pull back = release unsent now, delist live first';
END $$;

-- A11 --------------------------------------------------------------------------
UPDATE public.exos_events SET status = 'published', distribution_networks = ARRAY['stubhub'] WHERE id = '4e000000-0000-0000-0000-0000000000e3';
DO $$
BEGIN
  PERFORM public.exos_set_channel_allocation('4e000000-0000-0000-0000-0000000000e3','stubhub','4e000000-0000-0000-0000-0000000000d5',3);
  IF (pg_temp.alloc('stubhub','d5')).status <> 'pending' OR (pg_temp.alloc('stubhub','d5')).internal_seats <> '{[3,6)}' THEN
    RAISE EXCEPTION 'A11 FAIL: revived allocation %', row_to_json(pg_temp.alloc('stubhub','d5'));
  END IF;
  UPDATE public.exos_distribution_listings SET status = 'listed', external_listing_id = 'SH-V' WHERE id = (pg_temp.alloc('stubhub','d5')).id;
  PERFORM public.exos_set_channel_allocation('4e000000-0000-0000-0000-0000000000e3','stubhub','4e000000-0000-0000-0000-0000000000d5',0);
  IF (pg_temp.alloc('stubhub','d5')).status <> 'delisting' OR public.exos_tier_available('4e000000-0000-0000-0000-0000000000d5') <> 7 THEN
    RAISE EXCEPTION 'A11 FAIL: 0 on a live listing should delist first';
  END IF;
  BEGIN
    PERFORM public.exos_set_channel_allocation('4e000000-0000-0000-0000-0000000000e3','stubhub','4e000000-0000-0000-0000-0000000000d5',2);
    RAISE EXCEPTION 'A11 FAIL: changed a listing being delisted';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM NOT LIKE '%being taken off StubHub%' THEN RAISE; END IF;
  END;
  RAISE NOTICE 'A11 ok: setting 0 on a live listing delists first; no changes mid-delist';
END $$;
-- A13 --------------------------------------------------------------------------
INSERT INTO public.exos_events(id,org_id,name,status,starts_at,venue_name,total_tickets,tickets_sold,distribution_networks) VALUES
  ('4e000000-0000-0000-0000-0000000000e5','4e000000-0000-0000-0000-000000000001','Std','published','2027-03-01T02:00:00Z','Hall',10,0,ARRAY['stubhub']);
INSERT INTO public.exos_ticket_tiers(id,event_id,name,price,capacity,sold) VALUES
  ('4e000000-0000-0000-0000-0000000000d7','4e000000-0000-0000-0000-0000000000e5','GA',40,10,0);
DO $$
DECLARE alloc uuid; o record;
BEGIN
  PERFORM public.exos_set_channel_allocation('4e000000-0000-0000-0000-0000000000e5','stubhub','4e000000-0000-0000-0000-0000000000d7',6);
  SELECT id INTO alloc FROM public.exos_distribution_listings WHERE tier_id = '4e000000-0000-0000-0000-0000000000d7';
  -- exos-distribute's StubHub plan in the shared shape: blocks 1-4 and 5-6.
  UPDATE public.exos_distribution_listings
     SET planned_listing = jsonb_build_object('channel','stubhub','listings', jsonb_build_array(
           jsonb_build_object('listing_id','excccccccccccccccccccccccccc1','seat_from',1,'seat_thru',4,'quantity',4),
           jsonb_build_object('listing_id','excccccccccccccccccccccccccc2','seat_from',5,'seat_thru',6,'quantity',2)))
   WHERE id = alloc;
  PERFORM public.exos_record_marketplace_order(jsonb_build_object(
    'channel','stubhub','external_order_id','A13','external_listing_id', alloc::text, 'listing_ref','excccccccccccccccccccccccccc1',
    'quantity',2,'sale_status','confirmed','buyer_email','std@x.com'));
  SELECT * INTO o FROM public.exos_marketplace_orders WHERE external_order_id = 'A13';
  IF o.listing_ref IS DISTINCT FROM 'excccccccccccccccccccccccccc1' THEN RAISE EXCEPTION 'A13 FAIL: listing_ref not recorded'; END IF;
  PERFORM public.exos_fulfil_marketplace_order(o.id);
  IF (SELECT array_agg(internal_seat ORDER BY internal_seat) FROM public.exos_tickets WHERE order_ref = 'stubhub:A13') <> ARRAY[3,4]
     OR (SELECT internal_seats FROM public.exos_distribution_listings WHERE id = alloc) <> '{[1,3),[5,7)}' THEN
    RAISE EXCEPTION 'A13 FAIL: StubHub sale did not take listing 1''s seats';
  END IF;
  RAISE NOTICE 'A13 ok: StubHub records its listing and takes that block''s seats (3, 4), like SeatGeek and Gametime';
END $$;
-- A14-A16: pools ------------------------------------------------------------------
INSERT INTO public.exos_events(id,org_id,name,status,starts_at,venue_name,total_tickets,tickets_sold,distribution_networks,purchase_limits) VALUES
  ('4e000000-0000-0000-0000-0000000000e6','4e000000-0000-0000-0000-000000000001','Pools','published','2027-04-01T02:00:00Z','Hall',20,0,ARRAY['stubhub','gametime'],'{"maxPerOrder":2}');
INSERT INTO public.exos_ticket_tiers(id,event_id,name,price,capacity,sold) VALUES
  ('4e000000-0000-0000-0000-0000000000d8','4e000000-0000-0000-0000-0000000000e6','GA',40,20,0);
CREATE OR REPLACE FUNCTION pg_temp.pool(p_ch text) RETURNS text LANGUAGE sql AS $$
  SELECT sell_cap||'/'||sold_qty||'/'||requested_qty||'/'||list_qty FROM public.exos_distribution_listings
   WHERE channel = p_ch AND tier_id = '4e000000-0000-0000-0000-0000000000d8'
$$;

-- A14 --------------------------------------------------------------------------
DO $$
BEGIN
  PERFORM public.exos_set_channel_allocation('4e000000-0000-0000-0000-0000000000e6','stubhub','4e000000-0000-0000-0000-0000000000d8',10);
  PERFORM public.exos_set_channel_allocation('4e000000-0000-0000-0000-0000000000e6','gametime','4e000000-0000-0000-0000-0000000000d8',6);
  -- cap / sold / held / listed: each holds 2 x max per order (2) = 4.
  IF pg_temp.pool('stubhub') <> '10/0/4/4' OR pg_temp.pool('gametime') <> '6/0/4/4' THEN
    RAISE EXCEPTION 'A14 FAIL: pools % %', pg_temp.pool('stubhub'), pg_temp.pool('gametime');
  END IF;
  IF public.exos_tier_available('4e000000-0000-0000-0000-0000000000d8') <> 12 THEN
    RAISE EXCEPTION 'A14 FAIL: Exos can sell % (want 20 - 4 - 4)', public.exos_tier_available('4e000000-0000-0000-0000-0000000000d8');
  END IF;
  -- The cap can't promise seats that are gone.
  BEGIN
    PERFORM public.exos_set_channel_allocation('4e000000-0000-0000-0000-0000000000e6','stubhub','4e000000-0000-0000-0000-0000000000d8',17);
    RAISE EXCEPTION 'A14 FAIL: a cap beyond the free seats was accepted';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
  RAISE NOTICE 'A14 ok: both marketplaces live with 4 seats each; Exos sells the other 12';
END $$;

-- A15 --------------------------------------------------------------------------
DO $$
DECLARE alloc uuid;
BEGIN
  SELECT id INTO alloc FROM public.exos_distribution_listings WHERE channel = 'stubhub' AND tier_id = '4e000000-0000-0000-0000-0000000000d8';
  PERFORM public.exos_record_marketplace_order(jsonb_build_object('channel','stubhub','external_order_id','A15-1',
    'external_listing_id', alloc::text, 'quantity',2,'sale_status','confirmed','buyer_email','p1@x.com'));
  PERFORM public.exos_fulfil_marketplace_order((SELECT id FROM public.exos_marketplace_orders WHERE external_order_id = 'A15-1'));
  IF pg_temp.pool('stubhub') <> '10/2/4/4' THEN RAISE EXCEPTION 'A15 FAIL: not topped up: %', pg_temp.pool('stubhub'); END IF;
  -- Exos sells all but 1 of its free seats; StubHub then sells its 4. It's
  -- selling, so it's reloaded, but only above Exos's floor of one order's
  -- worth (2): with 1 free, it gets nothing and Exos keeps its last seat.
  UPDATE public.exos_ticket_tiers SET sold = sold + 9 WHERE id = '4e000000-0000-0000-0000-0000000000d8';
  UPDATE public.exos_events SET tickets_sold = tickets_sold + 9 WHERE id = '4e000000-0000-0000-0000-0000000000e6';
  PERFORM public.exos_record_marketplace_order(jsonb_build_object('channel','stubhub','external_order_id','A15-2',
    'external_listing_id', alloc::text, 'quantity',4,'sale_status','confirmed','buyer_email','p2@x.com'));
  PERFORM public.exos_fulfil_marketplace_order((SELECT id FROM public.exos_marketplace_orders WHERE external_order_id = 'A15-2'));
  IF pg_temp.pool('stubhub') <> '10/6/0/0' OR public.exos_tier_available('4e000000-0000-0000-0000-0000000000d8') <> 1 THEN
    RAISE EXCEPTION 'A15 FAIL: refill beyond free seats: % (Exos %)', pg_temp.pool('stubhub'), public.exos_tier_available('4e000000-0000-0000-0000-0000000000d8');
  END IF;
  -- A refund frees 3 (4 free). The refill run reloads selling StubHub down
  -- to Exos's floor (2 left); that makes the tier scarce, so Gametime (not
  -- selling, not live) drops to one order's worth, and those 2 go to StubHub
  -- on the next run: StubHub 4, Gametime 2, Exos 2.
  UPDATE public.exos_ticket_tiers SET sold = sold - 3 WHERE id = '4e000000-0000-0000-0000-0000000000d8';
  PERFORM public.exos_refill_channel_pools();
  PERFORM public.exos_refill_channel_pools();
  IF pg_temp.pool('stubhub') <> '10/6/4/4' OR pg_temp.pool('gametime') <> '6/0/2/2'
     OR public.exos_tier_available('4e000000-0000-0000-0000-0000000000d8') <> 2 THEN
    RAISE EXCEPTION 'A15 FAIL: refill run: % (Exos %)', pg_temp.pool('stubhub'), public.exos_tier_available('4e000000-0000-0000-0000-0000000000d8');
  END IF;
  -- Stable: another run changes nothing.
  PERFORM public.exos_refill_channel_pools();
  IF pg_temp.pool('stubhub') <> '10/6/4/4' OR pg_temp.pool('gametime') <> '6/0/2/2' THEN
    RAISE EXCEPTION 'A15 FAIL: another refill moved: % %', pg_temp.pool('stubhub'), pg_temp.pool('gametime');
  END IF;
  RAISE NOTICE 'A15 ok: sales top the pool back up, only with free seats; the refill run catches later frees';
END $$;

-- A16 --------------------------------------------------------------------------
UPDATE public.exos_distribution_listings SET status = 'listed', external_listing_id = 'GT-LIVE'
 WHERE channel = 'gametime' AND tier_id = '4e000000-0000-0000-0000-0000000000d8';
DO $$
DECLARE alloc uuid; v_before int4multirange;
BEGIN
  SELECT id, internal_seats INTO alloc, v_before FROM public.exos_distribution_listings
   WHERE channel = 'gametime' AND tier_id = '4e000000-0000-0000-0000-0000000000d8';
  PERFORM public.exos_set_channel_allocation('4e000000-0000-0000-0000-0000000000e6','gametime','4e000000-0000-0000-0000-0000000000d8',1);
  -- Live: still holds its 2 (scarcity took it to 2 in A15), the listings should show 1.
  IF pg_temp.pool('gametime') <> '1/0/2/1' THEN RAISE EXCEPTION 'A16 FAIL: live shrink released early: %', pg_temp.pool('gametime'); END IF;
  PERFORM public.exos_refill_channel_pools();
  IF pg_temp.pool('gametime') <> '1/0/2/1' THEN RAISE EXCEPTION 'A16 FAIL: refill run released a live hold'; END IF;
  -- Gametime has the new quantity: the highest seat goes back to Exos.
  PERFORM public.exos_confirm_channel_listing(alloc);
  IF pg_temp.pool('gametime') <> '1/0/1/1'
     OR (SELECT internal_seats FROM public.exos_distribution_listings WHERE id = alloc) <> public.exos_seats_take(v_before, 1) THEN
    RAISE EXCEPTION 'A16 FAIL: after confirm: %', pg_temp.pool('gametime');
  END IF;
  RAISE NOTICE 'A16 ok: a live listing is shrunk only once the marketplace has the lower number';
END $$;
ROLLBACK;


