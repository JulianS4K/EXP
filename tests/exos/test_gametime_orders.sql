-- ============================================================================
-- Gametime in the marketplace sync (mig 20260927040000). Self-contained (8e
-- prefix), rolled back at the end.
--   T1 ticking Gametime and publishing queues its event row; the grid takes
--      Gametime seats with internal seat numbers
--   T2 a Gametime purchase on an Exos listing is fulfilled; its tickets get
--      the seats of the listing the purchase names; the mail says Gametime
--   T3 unticking Gametime releases unsent seats at once
--   psql -d <db> -v ON_ERROR_STOP=1 -f tests/exos/test_gametime_orders.sql
-- ============================================================================
\set ON_ERROR_STOP on
BEGIN;
INSERT INTO auth.users(id,email,email_confirmed_at) VALUES
  ('8e000000-0000-0000-0000-0000000000a0','8e-owner@x.com',now());
INSERT INTO public.exos_orgs(id,name,slug,owner_uid) VALUES
  ('8e000000-0000-0000-0000-000000000001','8E Org','8e-org','8e000000-0000-0000-0000-0000000000a0');
INSERT INTO public.exos_org_memberships(org_id,user_id,role) VALUES
  ('8e000000-0000-0000-0000-000000000001','8e000000-0000-0000-0000-0000000000a0','owner');
INSERT INTO public.exos_events(id,org_id,name,status,starts_at,venue_name,total_tickets,tickets_sold,distribution_networks) VALUES
  ('8e000000-0000-0000-0000-0000000000e1','8e000000-0000-0000-0000-000000000001','GT Show','published','2027-01-01T02:00:00Z','Hall',100,0,ARRAY['gametime']);
INSERT INTO public.exos_ticket_tiers(id,event_id,name,price,capacity,sold) VALUES
  ('8e000000-0000-0000-0000-0000000000d1','8e000000-0000-0000-0000-0000000000e1','GA',50,10,0);

-- T1 -------------------------------------------------------------------------
DO $$
BEGIN
  IF (SELECT status FROM public.exos_distribution_listings
       WHERE event_id = '8e000000-0000-0000-0000-0000000000e1' AND channel = 'gametime' AND tier_id IS NULL) IS DISTINCT FROM 'pending' THEN
    RAISE EXCEPTION 'T1 FAIL: no Gametime event row';
  END IF;
  PERFORM public.exos_set_channel_allocation('8e000000-0000-0000-0000-0000000000e1','gametime','8e000000-0000-0000-0000-0000000000d1',6);
  IF public.exos_tier_available('8e000000-0000-0000-0000-0000000000d1') <> 4
     OR (SELECT internal_seats FROM public.exos_distribution_listings WHERE channel = 'gametime' AND tier_id IS NOT NULL) <> '{[1,7)}' THEN
    RAISE EXCEPTION 'T1 FAIL: allocation';
  END IF;
  RAISE NOTICE 'T1 ok: Gametime event row queued; 6 seats (internal 1-6) held for Gametime';
END $$;

-- T2 -------------------------------------------------------------------------
-- exos-distribute planned two listings (max 4 per order): 1-4 and 5-6.
-- The shared plan shape (exosListing.ts).
UPDATE public.exos_distribution_listings
   SET planned_listing = jsonb_build_object('channel','gametime','listings', jsonb_build_array(
         jsonb_build_object('listing_id','exbbbbbbbbbbbbbbbbbbbbbbbbbb1','seat_from',1,'seat_thru',4,'quantity',4),
         jsonb_build_object('listing_id','exbbbbbbbbbbbbbbbbbbbbbbbbbb2','seat_from',5,'seat_thru',6,'quantity',2)))
 WHERE channel = 'gametime' AND tier_id IS NOT NULL;
DO $$
DECLARE alloc uuid; r record; f record; m text;
BEGIN
  SELECT id INTO alloc FROM public.exos_distribution_listings WHERE channel = 'gametime' AND tier_id IS NOT NULL;
  -- What normalizeGametimeSale hands exos-marketplace-sales.
  SELECT * INTO r FROM public.exos_record_marketplace_order(jsonb_build_object(
    'channel','gametime','external_order_id','GT-8E-1','external_listing_id', alloc::text,
    'quantity',2,'sale_status','pending','buyer_email','gtbuyer@x.com','proceeds','90.00','currency','USD',
    'listing_ref','exbbbbbbbbbbbbbbbbbbbbbbbbbb2',
    'raw', jsonb_build_object('id','GT-8E-1','status','unconfirmed','quantity',2)));
  IF r.status IS DISTINCT FROM 'received' THEN RAISE EXCEPTION 'T2 FAIL: record %', r.status; END IF;
  SELECT * INTO f FROM public.exos_fulfil_marketplace_order(r.order_id, 'https://exos.example.test');
  IF f.status <> 'fulfilled' OR cardinality(f.transfer_ids) <> 2 THEN RAISE EXCEPTION 'T2 FAIL: fulfil %', row_to_json(f); END IF;
  IF (SELECT array_agg(internal_seat ORDER BY internal_seat) FROM public.exos_tickets WHERE order_ref = 'gametime:GT-8E-1') <> ARRAY[5,6]
     OR (SELECT internal_seats FROM public.exos_distribution_listings WHERE id = alloc) <> '{[1,5)}' THEN
    RAISE EXCEPTION 'T2 FAIL: internal seats';
  END IF;
  SELECT html INTO m FROM public.exos_mail WHERE to_email = 'gtbuyer@x.com' AND template = 'transfer-initiated';
  IF m NOT LIKE '%Your Gametime order GT-8E-1%' THEN RAISE EXCEPTION 'T2 FAIL: mail %', m; END IF;
  -- A broker listing's purchase is ignored.
  IF EXISTS (SELECT 1 FROM public.exos_record_marketplace_order(jsonb_build_object(
      'channel','gametime','external_order_id','GT-BROKER','external_listing_id','1732272492','quantity',1,'sale_status','pending'))) THEN
    RAISE EXCEPTION 'T2 FAIL: broker purchase recorded';
  END IF;
  RAISE NOTICE 'T2 ok: Gametime purchase fulfilled on listing 2''s seats (5, 6); mail says Gametime; broker purchase ignored';
END $$;

-- T3 -------------------------------------------------------------------------
UPDATE public.exos_events SET distribution_networks = '{}' WHERE id = '8e000000-0000-0000-0000-0000000000e1';
DO $$
BEGIN
  IF (SELECT status||' '||requested_qty FROM public.exos_distribution_listings WHERE channel = 'gametime' AND tier_id IS NOT NULL) <> 'delisted 0'
     OR public.exos_tier_available('8e000000-0000-0000-0000-0000000000d1') <> 8 THEN
    RAISE EXCEPTION 'T3 FAIL: unticking Gametime did not release the seats';
  END IF;
  RAISE NOTICE 'T3 ok: unticking Gametime releases its unsent seats (10 - 2 sold = 8 for Exos)';
END $$;
ROLLBACK;
