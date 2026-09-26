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
INSERT INTO public.exos_events(id,org_id,name,status,starts_at,venue_name,total_tickets,tickets_sold) VALUES
  ('4e000000-0000-0000-0000-0000000000e1','4e000000-0000-0000-0000-000000000001','Show','published','2027-01-01T02:00:00Z','Hall',15,0),
  ('4e000000-0000-0000-0000-0000000000e2','4e000000-0000-0000-0000-000000000001','Tight cap','published','2027-01-02T02:00:00Z','Hall',5,0);
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
  PERFORM public.exos_set_channel_allocation('4e000000-0000-0000-0000-0000000000e1','stubhub','4e000000-0000-0000-0000-0000000000d1',6);
  IF public.exos_tier_available('4e000000-0000-0000-0000-0000000000d1') <> 0 THEN
    RAISE EXCEPTION 'A2 FAIL: after allocating 6 with 4 sold, Exos should have 0';
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
  BEGIN
    PERFORM public.exos_set_channel_allocation('4e000000-0000-0000-0000-0000000000e1','stubhub','4e000000-0000-0000-0000-0000000000d2',1);
    RAISE EXCEPTION 'A3 FAIL: switched the listing to another ticket type while it holds seats';
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
  RAISE NOTICE 'A3 ok: tight house cap / wrong tier / strangers refused; owner allowed';
END $$;
RESET ROLE;

-- A4 ---------------------------------------------------------------------------
-- Exos sells everything it can (10 - 4 - 3 = 3 more): now sold 7, allocation 3.
UPDATE public.exos_ticket_tiers SET sold = 7 WHERE id = '4e000000-0000-0000-0000-0000000000d1';
UPDATE public.exos_events SET tickets_sold = 7 WHERE id = '4e000000-0000-0000-0000-0000000000e1';
UPDATE public.exos_distribution_listings SET status = 'listed', external_listing_id = 'SH-A'
 WHERE event_id = '4e000000-0000-0000-0000-0000000000e1' AND channel = 'stubhub';
DO $$
DECLARE o record;
BEGIN
  IF public.exos_seats_available('4e000000-0000-0000-0000-0000000000d1', 1) THEN
    RAISE EXCEPTION 'A4 FAIL: Exos can still sell a StubHub seat';
  END IF;
  PERFORM public.exos_record_marketplace_order('{"channel":"stubhub","external_order_id":"A4","external_listing_id":"SH-A","quantity":2,"sale_status":"confirmed","buyer_email":"sh@x.com"}');
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
ROLLBACK;
