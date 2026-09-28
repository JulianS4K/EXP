-- ============================================================================
-- Ticket Evolution orders (mig 20260928070000). Self-contained (8e prefix),
-- rolled back at the end.
--   E1 an 'evo' allocation holds seats like any marketplace
--   E2 a TEvo order on an Exos listing is recorded and fulfilled on that
--      listing's seats; the mail says Ticket Evolution; a broker order is ignored
--   E3 a TEvo sale to TEvo itself carries no buyer email: it goes to a human
--      (the email arrives with the shipment, fulfilment.ts)
--   E4 listings (mig 20260928080000): publishing with Ticket Evolution ticked
--      queues its event row; each Exos listing gets one remote_id, for good,
--      from 1,900,000,001 up; only an 'evo' allocation, only the service role
--   E5 a staff link re-queues the TEvo event row (its event id goes on the listings)
--   psql -d <db> -v ON_ERROR_STOP=1 -f tests/exos/test_tevo_orders.sql
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
  ('8e000000-0000-0000-0000-0000000000e1','8e000000-0000-0000-0000-000000000001','TE Show','published','2027-01-01T02:00:00Z','Hall',100,0,ARRAY['evo']);
INSERT INTO public.exos_ticket_tiers(id,event_id,name,price,capacity,sold) VALUES
  ('8e000000-0000-0000-0000-0000000000d1','8e000000-0000-0000-0000-0000000000e1','GA',50,10,0);

-- E1 -------------------------------------------------------------------------
DO $$
DECLARE e text;
BEGIN
  PERFORM public.exos_set_channel_allocation('8e000000-0000-0000-0000-0000000000e1','evo','8e000000-0000-0000-0000-0000000000d1',6);
  IF public.exos_tier_available('8e000000-0000-0000-0000-0000000000d1') <> 4
     OR (SELECT internal_seats FROM public.exos_distribution_listings WHERE channel = 'evo' AND tier_id IS NOT NULL) <> '{[1,7)}' THEN
    RAISE EXCEPTION 'E1 FAIL: allocation';
  END IF;
  BEGIN
    PERFORM public.exos_set_channel_allocation('8e000000-0000-0000-0000-0000000000e1','evo','8e000000-0000-0000-0000-0000000000d1',50);
  EXCEPTION WHEN others THEN e := SQLERRM;
  END;
  IF e IS NULL OR e LIKE '%Evo %' THEN RAISE EXCEPTION 'E1 FAIL: error names %', coalesce(e, 'nothing'); END IF;
  RAISE NOTICE 'E1 ok: 6 seats (internal 1-6) held for Ticket Evolution; errors name it properly';
END $$;

-- E2 -------------------------------------------------------------------------
UPDATE public.exos_distribution_listings
   SET planned_listing = jsonb_build_object('channel','evo','listings', jsonb_build_array(
         jsonb_build_object('listing_id','exeeeeeeeeeeeeeeeeeeeeeeeee1','seat_from',1,'seat_thru',4,'quantity',4),
         jsonb_build_object('listing_id','exeeeeeeeeeeeeeeeeeeeeeeeee2','seat_from',5,'seat_thru',6,'quantity',2)))
 WHERE channel = 'evo' AND tier_id IS NOT NULL;
DO $$
DECLARE alloc uuid; r record; f record; m text;
BEGIN
  SELECT id INTO alloc FROM public.exos_distribution_listings WHERE channel = 'evo' AND tier_id IS NOT NULL;
  -- What normalizeTevoOrder hands exos-marketplace-sales (a Client sale, with an email).
  SELECT * INTO r FROM public.exos_record_marketplace_order(jsonb_build_object(
    'channel','evo','external_order_id','190840','external_listing_id', alloc::text,
    'quantity',2,'sale_status','pending','buyer_email','tebuyer@x.com','proceeds','90.00','currency','USD',
    'listing_ref','exeeeeeeeeeeeeeeeeeeeeeeeee2',
    'raw', jsonb_build_object('id',190840,'state','pending','buyer',jsonb_build_object('type','Client','id',55))));
  IF r.status IS DISTINCT FROM 'received' THEN RAISE EXCEPTION 'E2 FAIL: record %', r.status; END IF;
  SELECT * INTO f FROM public.exos_fulfil_marketplace_order(r.order_id, 'https://exos.example.test');
  IF f.status <> 'fulfilled' OR cardinality(f.transfer_ids) <> 2 THEN RAISE EXCEPTION 'E2 FAIL: fulfil %', row_to_json(f); END IF;
  IF (SELECT array_agg(internal_seat ORDER BY internal_seat) FROM public.exos_tickets WHERE order_ref = 'evo:190840') <> ARRAY[5,6] THEN
    RAISE EXCEPTION 'E2 FAIL: internal seats';
  END IF;
  SELECT html INTO m FROM public.exos_mail WHERE to_email = 'tebuyer@x.com' AND template = 'transfer-initiated';
  IF m NOT LIKE '%Your Ticket Evolution order 190840%' THEN RAISE EXCEPTION 'E2 FAIL: mail %', m; END IF;
  IF EXISTS (SELECT 1 FROM public.exos_record_marketplace_order(jsonb_build_object(
      'channel','evo','external_order_id','190999','external_listing_id','BROKER-77','quantity',1,'sale_status','pending'))) THEN
    RAISE EXCEPTION 'E2 FAIL: broker order recorded';
  END IF;
  RAISE NOTICE 'E2 ok: TEvo order fulfilled on listing 2''s seats (5, 6); mail says Ticket Evolution; broker order ignored';
END $$;

-- E3 -------------------------------------------------------------------------
DO $$
DECLARE alloc uuid; r record; f record;
BEGIN
  SELECT id INTO alloc FROM public.exos_distribution_listings WHERE channel = 'evo' AND tier_id IS NOT NULL;
  SELECT * INTO r FROM public.exos_record_marketplace_order(jsonb_build_object(
    'channel','evo','external_order_id','190841','external_listing_id', alloc::text,
    'quantity',1,'sale_status','pending','listing_ref','exeeeeeeeeeeeeeeeeeeeeeeeee1',
    'raw', jsonb_build_object('id',190841,'state','pending','buyer',jsonb_build_object('type','Office','id',6))));
  SELECT * INTO f FROM public.exos_fulfil_marketplace_order(r.order_id, 'https://exos.example.test');
  IF f.status <> 'needs_attention' THEN RAISE EXCEPTION 'E3 FAIL: %', row_to_json(f); END IF;
  RAISE NOTICE 'E3 ok: a sale to TEvo without an email goes to a human (%)', f.reason;
END $$;

-- E4 -------------------------------------------------------------------------
DO $$
DECLARE alloc uuid; a bigint; b bigint; c bigint; n int; e text;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.exos_distribution_listings
                  WHERE event_id = '8e000000-0000-0000-0000-0000000000e1' AND channel = 'evo' AND tier_id IS NULL AND status = 'pending') THEN
    RAISE EXCEPTION 'E4 FAIL: no queued Ticket Evolution event row';
  END IF;
  SELECT id INTO alloc FROM public.exos_distribution_listings WHERE channel = 'evo' AND tier_id IS NOT NULL;
  SELECT remote_id INTO a FROM public.exos_tevo_remote_ids(alloc, ARRAY['exryaaaaaaaaaaaaaaaaaaaaakxq1','exryaaaaaaaaaaaaaaaaaaaaakxq2'])
   WHERE listing_id = 'exryaaaaaaaaaaaaaaaaaaaaakxq1';
  IF a IS NULL OR a < 1900000001 THEN RAISE EXCEPTION 'E4 FAIL: remote_id %', a; END IF;
  -- Again, plus a new listing: the old ones keep their numbers.
  SELECT count(*), max(remote_id) FILTER (WHERE listing_id = 'exryaaaaaaaaaaaaaaaaaaaaakxq1'),
         max(remote_id) FILTER (WHERE listing_id = 'exryaaaaaaaaaaaaaaaaaaaaakxq3')
    INTO n, b, c
    FROM public.exos_tevo_remote_ids(alloc, ARRAY['exryaaaaaaaaaaaaaaaaaaaaakxq1','exryaaaaaaaaaaaaaaaaaaaaakxq3']);
  IF n <> 2 OR b <> a OR c <> a + 2 THEN RAISE EXCEPTION 'E4 FAIL: renumbered (% % % %)', n, a, b, c; END IF;
  IF (SELECT count(*) FROM public.exos_tevo_remote_ids WHERE allocation_id = alloc) <> 3 THEN RAISE EXCEPTION 'E4 FAIL: count'; END IF;
  -- Not a TEvo allocation.
  BEGIN
    PERFORM public.exos_tevo_remote_ids((SELECT id FROM public.exos_distribution_listings WHERE channel = 'evo' AND tier_id IS NULL), ARRAY['exryaaaaaaaaaaaaaaaaaaaaakxq9']);
  EXCEPTION WHEN others THEN e := SQLERRM;
  END;
  IF e IS NULL OR e NOT LIKE '%not a Ticket Evolution allocation%' THEN RAISE EXCEPTION 'E4 FAIL: event row numbered (%)', e; END IF;
  -- Not an Exos listing id.
  e := NULL;
  BEGIN
    PERFORM public.exos_tevo_remote_ids(alloc, ARRAY['BROKER-1']);
  EXCEPTION WHEN check_violation THEN e := 'refused';
  END;
  IF e IS NULL THEN RAISE EXCEPTION 'E4 FAIL: broker id numbered'; END IF;
  IF has_function_privilege('authenticated', 'public.exos_tevo_remote_ids(uuid, text[])', 'EXECUTE')
     OR has_function_privilege('anon', 'public.exos_tevo_remote_ids(uuid, text[])', 'EXECUTE')
     OR has_table_privilege('authenticated', 'public.exos_tevo_remote_ids', 'SELECT')
     OR NOT has_function_privilege('service_role', 'public.exos_tevo_remote_ids(uuid, text[])', 'EXECUTE') THEN
    RAISE EXCEPTION 'E4 FAIL: grants';
  END IF;
  RAISE NOTICE 'E4 ok: TEvo event row queued; remote_ids % and % (stable, never reused); service role only', a, c;
END $$;

-- E5 -------------------------------------------------------------------------
UPDATE public.exos_distribution_listings SET status = 'failed', error = 'Ticket Evolution: waiting for Exos staff to link this event'
 WHERE event_id = '8e000000-0000-0000-0000-0000000000e1' AND channel = 'evo' AND tier_id IS NULL;
INSERT INTO public.exos_channel_event_links(event_id,org_id,channel,status,method,confidence,candidates)
VALUES ('8e000000-0000-0000-0000-0000000000e1','8e000000-0000-0000-0000-000000000001','evo','review','auto_match',0.7,
  '[{"external_event_id":"2204331","name":"TE Show","score":0.9}]');
SELECT set_config('app.uid','8e000000-0000-0000-0000-0000000000a0',true);
SET LOCAL ROLE authenticated;
DO $$
BEGIN
  IF public.exos_link_channel_event('8e000000-0000-0000-0000-0000000000e1','evo','2204331') <> 'linked' THEN
    RAISE EXCEPTION 'E5 FAIL: not linked';
  END IF;
END $$;
RESET ROLE;
DO $$
BEGIN
  IF (SELECT status FROM public.exos_distribution_listings
       WHERE event_id = '8e000000-0000-0000-0000-0000000000e1' AND channel = 'evo' AND tier_id IS NULL) <> 'pending' THEN
    RAISE EXCEPTION 'E5 FAIL: TEvo event row not re-queued';
  END IF;
  RAISE NOTICE 'E5 ok: linking the TEvo event re-queues its row';
END $$;

ROLLBACK;
