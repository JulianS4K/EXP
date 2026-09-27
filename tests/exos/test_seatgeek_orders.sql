-- ============================================================================
-- SeatGeek sales -> Exos tickets (migs 20260926192000/193000 + 20260927020000).
-- Self-contained (7d prefix), rolled back at the end.
--   G1 seats allocated to SeatGeek are held back from Exos's own sale
--   G2 a SeatGeek order on an Exos listing (normalized to the allocation id)
--      is recorded and fulfilled: tickets, link transfers, mail says SeatGeek
--   G3 a broker listing's order is ignored; an unknown status goes to a human
--   psql -d <db> -v ON_ERROR_STOP=1 -f tests/exos/test_seatgeek_orders.sql
-- ============================================================================
\set ON_ERROR_STOP on
BEGIN;
INSERT INTO auth.users(id,email,email_confirmed_at) VALUES
  ('7d000000-0000-0000-0000-0000000000a0','7d-owner@x.com',now());
INSERT INTO public.exos_orgs(id,name,slug,owner_uid) VALUES
  ('7d000000-0000-0000-0000-000000000001','7D Org','7d-org','7d000000-0000-0000-0000-0000000000a0');
INSERT INTO public.exos_org_memberships(org_id,user_id,role) VALUES
  ('7d000000-0000-0000-0000-000000000001','7d000000-0000-0000-0000-0000000000a0','owner');
INSERT INTO public.exos_events(id,org_id,name,status,starts_at,venue_name,total_tickets,tickets_sold) VALUES
  ('7d000000-0000-0000-0000-0000000000e1','7d000000-0000-0000-0000-000000000001','SG Show','published','2027-01-01T02:00:00Z','Hall',100,0);
INSERT INTO public.exos_ticket_tiers(id,event_id,name,price,capacity,sold) VALUES
  ('7d000000-0000-0000-0000-0000000000d1','7d000000-0000-0000-0000-0000000000e1','GA',50,10,0);

-- G1 -------------------------------------------------------------------------
DO $$
BEGIN
  PERFORM set_config('app.uid','7d000000-0000-0000-0000-0000000000a0',true);
  PERFORM set_config('app.jwt','{"email":"7d-owner@x.com"}',true);
  IF public.exos_set_channel_allocation('7d000000-0000-0000-0000-0000000000e1','seatgeek','7d000000-0000-0000-0000-0000000000d1',6) <> 6 THEN
    RAISE EXCEPTION 'G1 FAIL: allocation';
  END IF;
  IF public.exos_tier_available('7d000000-0000-0000-0000-0000000000d1') <> 4 THEN
    RAISE EXCEPTION 'G1 FAIL: Exos can still sell % (want 4)', public.exos_tier_available('7d000000-0000-0000-0000-0000000000d1');
  END IF;
  RAISE NOTICE 'G1 ok: 6 seats held for SeatGeek, Exos sells 4';
END $$;

-- G2 -------------------------------------------------------------------------
DO $$
DECLARE alloc uuid; r record; f record; m text;
BEGIN
  PERFORM set_config('app.uid','',true);
  SELECT id INTO alloc FROM public.exos_distribution_listings
   WHERE event_id = '7d000000-0000-0000-0000-0000000000e1' AND channel = 'seatgeek';
  -- What normalizeSeatGeekOrder hands exos-marketplace-sales for listing exos_<alloc>_1.
  SELECT * INTO r FROM public.exos_record_marketplace_order(jsonb_build_object(
    'channel','seatgeek','external_order_id','SG-7D-1','external_event_id','6123456',
    'external_listing_id', alloc::text, 'quantity', 2, 'sale_status','confirmed',
    'buyer_email','sgbuyer@x.com','proceeds','81.00','currency','USD'));
  IF r.status IS DISTINCT FROM 'received' THEN RAISE EXCEPTION 'G2 FAIL: record %', r.status; END IF;
  SELECT * INTO f FROM public.exos_fulfil_marketplace_order(r.order_id, 'https://exos.example.test');
  IF f.status <> 'fulfilled' OR cardinality(f.transfer_ids) <> 2 THEN RAISE EXCEPTION 'G2 FAIL: fulfil %', row_to_json(f); END IF;
  SELECT html INTO m FROM public.exos_mail WHERE to_email = 'sgbuyer@x.com' AND template = 'transfer-initiated';
  IF m NOT LIKE '%Your SeatGeek order SG-7D-1%' OR m NOT LIKE '%/claim/%/claim/%' THEN RAISE EXCEPTION 'G2 FAIL: mail %', m; END IF;
  IF (SELECT requested_qty FROM public.exos_distribution_listings WHERE id = alloc) <> 4 THEN
    RAISE EXCEPTION 'G2 FAIL: allocation not consumed';
  END IF;
  RAISE NOTICE 'G2 ok: SeatGeek order fulfilled with 2 link transfers; mail says SeatGeek';
END $$;

-- G3 -------------------------------------------------------------------------
DO $$
DECLARE alloc uuid; r record; f record;
BEGIN
  SELECT id INTO alloc FROM public.exos_distribution_listings
   WHERE event_id = '7d000000-0000-0000-0000-0000000000e1' AND channel = 'seatgeek';
  IF EXISTS (SELECT 1 FROM public.exos_record_marketplace_order(jsonb_build_object(
      'channel','seatgeek','external_order_id','SG-BROKER','external_listing_id','abc1234','quantity',1,'sale_status','confirmed'))) THEN
    RAISE EXCEPTION 'G3 FAIL: broker order recorded';
  END IF;
  SELECT * INTO r FROM public.exos_record_marketplace_order(jsonb_build_object(
    'channel','seatgeek','external_order_id','SG-7D-2','external_listing_id', alloc::text,
    'quantity',1,'sale_status','unknown','buyer_email','who@x.com'));
  SELECT * INTO f FROM public.exos_fulfil_marketplace_order(r.order_id, 'https://exos.example.test');
  IF f.status <> 'needs_attention' THEN RAISE EXCEPTION 'G3 FAIL: unknown status fulfilled (%)', f.status; END IF;
  RAISE NOTICE 'G3 ok: broker order ignored; unknown status sent to a human';
END $$;

ROLLBACK;
