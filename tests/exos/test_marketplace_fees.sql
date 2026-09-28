-- ============================================================================
-- Listed price and marketplace fee on each sale (mig 20260929062000).
-- Self-contained (7e prefix), rolled back.
--   F1 a sale takes its listing's unit_price (by listing_ref) and the fee is
--      price x qty - proceeds
--   F2 a later re-plan at a new price doesn't rewrite a past sale
--   F3 exos_marketplace_fee_rates: the realized rate per store; service role only
-- ============================================================================
\set ON_ERROR_STOP on
BEGIN;
INSERT INTO auth.users(id,email,email_confirmed_at) VALUES ('7e000000-0000-0000-0000-0000000000a0','7e-owner@x.com',now());
INSERT INTO public.exos_orgs(id,name,slug,owner_uid) VALUES
  ('7e000000-0000-0000-0000-000000000001','7E Org','7e-org','7e000000-0000-0000-0000-0000000000a0');
INSERT INTO public.exos_events(id,org_id,name,status,starts_at,venue_name,total_tickets,tickets_sold,distribution_networks) VALUES
  ('7e000000-0000-0000-0000-0000000000e1','7e000000-0000-0000-0000-000000000001','7E Show','published','2027-01-01T02:00:00Z','Hall',100,0,ARRAY['seatgeek']);
INSERT INTO public.exos_ticket_tiers(id,event_id,name,price,capacity,sold) VALUES
  ('7e000000-0000-0000-0000-0000000000d1','7e000000-0000-0000-0000-0000000000e1','GA',40,20,0);
SELECT public.exos_set_channel_allocation('7e000000-0000-0000-0000-0000000000e1','seatgeek','7e000000-0000-0000-0000-0000000000d1',10);
-- The plan exos-distribute stores: 40.00 net on SeatGeek (5%) lists at 42.11.
UPDATE public.exos_distribution_listings
   SET planned_listing = jsonb_build_object('channel','seatgeek','listings', jsonb_build_array(
         jsonb_build_object('listing_id','ex7etest1','seat_from',1,'seat_thru',4,'quantity',4,'unit_price',42.11)))
 WHERE event_id = '7e000000-0000-0000-0000-0000000000e1' AND channel = 'seatgeek';

CREATE OR REPLACE FUNCTION pg_temp.sale(p_id text, p_qty int, p_proceeds text) RETURNS uuid LANGUAGE sql AS $$
  SELECT order_id FROM public.exos_record_marketplace_order(jsonb_build_object(
    'channel','seatgeek','external_order_id', p_id, 'listing_ref','ex7etest1',
    'external_listing_id', (SELECT id::text FROM public.exos_distribution_listings
                             WHERE event_id = '7e000000-0000-0000-0000-0000000000e1' AND channel = 'seatgeek' AND tier_id IS NOT NULL),
    'quantity', p_qty, 'sale_status','confirmed', 'proceeds', p_proceeds, 'currency','USD'));
$$;

DO $$
DECLARE o uuid; m record; r record;
BEGIN
  -- F1: 2 x 42.11 = 84.22 gross, SeatGeek pays 80.01 (5% = 4.211 off, to the cent).
  o := pg_temp.sale('7e-1', 2, '80.01');
  SELECT * INTO m FROM public.exos_marketplace_orders WHERE id = o;
  IF m.list_unit_price IS DISTINCT FROM 42.11 OR m.marketplace_fee IS DISTINCT FROM 4.21 THEN
    RAISE EXCEPTION 'F1 FAIL: list % fee %', m.list_unit_price, m.marketplace_fee;
  END IF;
  RAISE NOTICE 'F1 PASS: listed price and fee on the sale';

  -- F2: re-planned at 45.00; the past sale keeps 42.11, a new one takes 45.00.
  UPDATE public.exos_distribution_listings
     SET planned_listing = jsonb_set(planned_listing, '{listings,0,unit_price}', '45.0')
   WHERE event_id = '7e000000-0000-0000-0000-0000000000e1' AND channel = 'seatgeek';
  UPDATE public.exos_marketplace_orders SET proceeds = proceeds WHERE id = o;
  SELECT * INTO m FROM public.exos_marketplace_orders WHERE id = o;
  IF m.list_unit_price IS DISTINCT FROM 42.11 THEN RAISE EXCEPTION 'F2 FAIL: past sale rewritten to %', m.list_unit_price; END IF;
  o := pg_temp.sale('7e-2', 1, '42.75');
  SELECT * INTO m FROM public.exos_marketplace_orders WHERE id = o;
  IF m.list_unit_price IS DISTINCT FROM 45.0 OR m.marketplace_fee IS DISTINCT FROM 2.25 THEN
    RAISE EXCEPTION 'F2 FAIL: new sale list % fee %', m.list_unit_price, m.marketplace_fee;
  END IF;
  RAISE NOTICE 'F2 PASS: a past sale keeps the price it sold at';

  -- F3: (4.21 + 2.25) / (84.22 + 45.00) = 4.999% (5%, less the payout's rounding to the cent).
  SELECT * INTO r FROM public.exos_marketplace_fee_rates WHERE channel = 'seatgeek';
  IF r.orders <> 2 OR r.fee_pct IS DISTINCT FROM 4.999 THEN RAISE EXCEPTION 'F3 FAIL: %', row_to_json(r); END IF;
  IF has_table_privilege('authenticated', 'public.exos_marketplace_fee_rates', 'SELECT')
     OR has_function_privilege('authenticated', 'public.exos_listing_unit_price(uuid, text)', 'EXECUTE') THEN
    RAISE EXCEPTION 'F3 FAIL: readable by app users';
  END IF;
  RAISE NOTICE 'F3 PASS: realized rate per store, service role only';
END $$;
ROLLBACK;
