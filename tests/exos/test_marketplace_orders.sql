-- ============================================================================
-- Marketplace sales -> Exos tickets (mig 20260926192000). Self-contained (3d
-- prefix), rolled back at the end.
--   M1 a sale that isn't on an Exos listing is ignored (broker inventory)
--   M2 an Exos-listing sale is recorded once, by our id or the marketplace's
--   M3 fulfil: tickets on the org owner + pending transfer to the buyer,
--      the buyer emailed with claim links, capacity claimed, listing count
--      decremented; idempotent
--   M4 oversold / no email / no tier -> needs_attention, nothing minted
--   M5 cancellations: before tickets -> cancelled; after -> needs a human
--   M6 service_role only
--   psql -d <db> -v ON_ERROR_STOP=1 -f tests/exos/test_marketplace_orders.sql
-- ============================================================================
\set ON_ERROR_STOP on
BEGIN;
INSERT INTO auth.users(id,email,email_confirmed_at) VALUES
  ('3d000000-0000-0000-0000-0000000000a0','3d-owner@x.com',now());
INSERT INTO public.exos_orgs(id,name,slug,owner_uid) VALUES
  ('3d000000-0000-0000-0000-000000000001','3D Org','3d-org','3d000000-0000-0000-0000-0000000000a0');
INSERT INTO public.exos_org_memberships(org_id,user_id,role) VALUES
  ('3d000000-0000-0000-0000-000000000001','3d000000-0000-0000-0000-0000000000a0','owner');
INSERT INTO public.exos_events(id,org_id,name,status,starts_at,venue_name,total_tickets,tickets_sold) VALUES
  ('3d000000-0000-0000-0000-0000000000e1','3d000000-0000-0000-0000-000000000001','Show <b>&</b>','published','2027-01-01T02:00:00Z','Hall',100,0),
  ('3d000000-0000-0000-0000-0000000000e2','3d000000-0000-0000-0000-000000000001','Sold out','published','2027-01-02T02:00:00Z','Hall',100,2);
INSERT INTO public.exos_ticket_tiers(id,event_id,name,price,capacity,sold) VALUES
  ('3d000000-0000-0000-0000-0000000000d1','3d000000-0000-0000-0000-0000000000e1','GA',50,10,0),
  ('3d000000-0000-0000-0000-0000000000d2','3d000000-0000-0000-0000-0000000000e2','VIP',150,2,2);
INSERT INTO public.exos_distribution_listings(id,event_id,org_id,channel,status,tier_id,requested_qty,unit_price,external_listing_id) VALUES
  ('3d000000-0000-0000-0000-0000000000b1','3d000000-0000-0000-0000-0000000000e1','3d000000-0000-0000-0000-000000000001','stubhub','listed','3d000000-0000-0000-0000-0000000000d1',6,60,'SH-L-1'),
  ('3d000000-0000-0000-0000-0000000000b2','3d000000-0000-0000-0000-0000000000e2','3d000000-0000-0000-0000-000000000001','stubhub','listed','3d000000-0000-0000-0000-0000000000d2',2,160,'SH-L-2');

CREATE OR REPLACE FUNCTION pg_temp.rec(p jsonb) RETURNS text LANGUAGE sql AS $$
  SELECT status FROM public.exos_record_marketplace_order(p)
$$;
CREATE OR REPLACE FUNCTION pg_temp.ful(p_ext text) RETURNS record LANGUAGE sql AS $$
  SELECT f FROM public.exos_marketplace_orders m,
         public.exos_fulfil_marketplace_order(m.id, 'https://exos.example.test/bridge/') f
   WHERE m.external_order_id = p_ext
$$;

-- M1 ---------------------------------------------------------------------------
DO $$
BEGIN
  IF pg_temp.rec('{"channel":"stubhub","external_order_id":"B-1","external_listing_id":"broker-listing","quantity":2,"sale_status":"confirmed"}') IS NOT NULL
     OR pg_temp.rec('{"channel":"vivid","external_order_id":"B-2","external_listing_id":"SH-L-1","quantity":1}') IS NOT NULL  -- right id, wrong channel
     OR pg_temp.rec('{"channel":"stubhub","external_order_id":"B-3","quantity":2}') IS NOT NULL THEN
    RAISE EXCEPTION 'M1 FAIL: recorded a sale that is not on an Exos listing';
  END IF;
  IF EXISTS (SELECT 1 FROM public.exos_marketplace_orders) THEN RAISE EXCEPTION 'M1 FAIL: rows written'; END IF;
  RAISE NOTICE 'M1 ok: broker / unknown-listing sales ignored';
END $$;

-- M2 ---------------------------------------------------------------------------
DO $$
DECLARE o record;
BEGIN
  IF pg_temp.rec('{"channel":"stubhub","external_order_id":"555","external_event_id":"104857",
     "external_listing_id":"3d000000-0000-0000-0000-0000000000b1","quantity":2,"sale_status":"confirmed",
     "buyer_email":" Buyer@Example.com ","proceeds":"90.5","currency":"usd","confirm_by":"2027-01-01T00:00:00Z"}') <> 'received' THEN
    RAISE EXCEPTION 'M2 FAIL: not received';
  END IF;
  -- Same sale again (webhook retry): one row, email kept even if absent now.
  PERFORM pg_temp.rec('{"channel":"stubhub","external_order_id":"555","external_listing_id":"SH-L-1","quantity":2,"sale_status":"confirmed"}');
  SELECT * INTO o FROM public.exos_marketplace_orders WHERE external_order_id = '555';
  IF (SELECT count(*) FROM public.exos_marketplace_orders) <> 1 OR o.buyer_email <> 'buyer@example.com'
     OR o.tier_id <> '3d000000-0000-0000-0000-0000000000d1' OR o.proceeds <> 90.5 OR o.currency <> 'USD'
     OR o.event_id <> '3d000000-0000-0000-0000-0000000000e1' THEN
    RAISE EXCEPTION 'M2 FAIL: %', row_to_json(o);
  END IF;
  RAISE NOTICE 'M2 ok: Exos-listing sale recorded once';
END $$;

-- M3 ---------------------------------------------------------------------------
DO $$
DECLARE f record; o record; t record; n int; tr uuid[];
BEGIN
  f := pg_temp.ful('555');
  SELECT * INTO o FROM public.exos_marketplace_orders WHERE external_order_id = '555';
  IF o.status <> 'fulfilled' OR cardinality(o.ticket_ids) <> 2 OR cardinality(o.transfer_ids) <> 2 THEN
    RAISE EXCEPTION 'M3 FAIL: order %', row_to_json(o);
  END IF;
  FOR t IN SELECT * FROM public.exos_tickets WHERE id = ANY (o.ticket_ids) LOOP
    IF t.owner_id <> '3d000000-0000-0000-0000-0000000000a0' OR t.channel_source <> 'stubhub'
       OR t.order_ref <> 'stubhub:555' OR t.price_paid <> 45.25 OR t.pending_transfer_id IS NULL
       OR t.tier_id <> '3d000000-0000-0000-0000-0000000000d1' THEN
      RAISE EXCEPTION 'M3 FAIL: ticket %', row_to_json(t);
    END IF;
  END LOOP;
  SELECT count(*) INTO n FROM public.exos_transfers
   WHERE id = ANY (o.transfer_ids) AND status = 'pending' AND receiver_email = 'buyer@example.com';
  IF n <> 2 THEN RAISE EXCEPTION 'M3 FAIL: % pending transfers to the buyer', n; END IF;
  IF (SELECT sold FROM public.exos_ticket_tiers WHERE id = '3d000000-0000-0000-0000-0000000000d1') <> 2
     OR (SELECT tickets_sold FROM public.exos_events WHERE id = '3d000000-0000-0000-0000-0000000000e1') <> 2
     OR (SELECT requested_qty FROM public.exos_distribution_listings WHERE id = '3d000000-0000-0000-0000-0000000000b1') <> 4 THEN
    RAISE EXCEPTION 'M3 FAIL: capacity / listing counts not updated';
  END IF;
  -- Again: no second mint.
  tr := o.transfer_ids;
  f := pg_temp.ful('555');
  IF (SELECT count(*) FROM public.exos_tickets WHERE order_ref = 'stubhub:555') <> 2
     OR (SELECT transfer_ids FROM public.exos_marketplace_orders WHERE external_order_id = '555') <> tr THEN
    RAISE EXCEPTION 'M3 FAIL: fulfil is not idempotent';
  END IF;
  IF (SELECT count(*) FROM public.exos_mail WHERE to_email = 'buyer@example.com') <> 1 THEN
    RAISE EXCEPTION 'M3 FAIL: buyer emailed twice';
  END IF;
  -- The buyer is told: one email, one claim link per transfer, names escaped.
  SELECT count(*) INTO n FROM public.exos_mail
   WHERE template = 'transfer-initiated' AND to_email = 'buyer@example.com'
     AND html LIKE '%https://exos.example.test/bridge/claim/' || o.transfer_ids[1] || '%'
     AND html LIKE '%https://exos.example.test/bridge/claim/' || o.transfer_ids[2] || '%'
     AND html LIKE '%Show &lt;b&gt;&amp;&lt;/b&gt;%' AND html NOT LIKE '%<b>&</b>%'
     AND subject LIKE 'Your StubHub tickets for %';
  IF n <> 1 THEN RAISE EXCEPTION 'M3 FAIL: % buyer emails with both claim links', n; END IF;
  RAISE NOTICE 'M3 ok: minted to the org owner, transferred + emailed to the buyer; idempotent';
END $$;

-- M4 ---------------------------------------------------------------------------
DO $$
DECLARE o record;
BEGIN
  -- VIP is full (2/2): selling it on StubHub is an oversell. Matched by StubHub's listing id.
  PERFORM pg_temp.rec('{"channel":"stubhub","external_order_id":"SH-9","external_listing_id":"SH-L-2","quantity":1,"sale_status":"confirmed","buyer_email":"b@x.com"}');
  PERFORM pg_temp.ful('SH-9');
  SELECT * INTO o FROM public.exos_marketplace_orders WHERE external_order_id = 'SH-9';
  IF o.status <> 'needs_attention' OR o.attention_reason NOT LIKE 'oversold:%' OR cardinality(o.ticket_ids) <> 0 THEN
    RAISE EXCEPTION 'M4 FAIL: oversell %', row_to_json(o);
  END IF;
  IF (SELECT tickets_sold FROM public.exos_events WHERE id = '3d000000-0000-0000-0000-0000000000e2') <> 2 THEN
    RAISE EXCEPTION 'M4 FAIL: house cap claim not undone';
  END IF;
  -- No buyer email from StubHub.
  PERFORM pg_temp.rec('{"channel":"stubhub","external_order_id":"556","external_listing_id":"SH-L-1","quantity":1,"sale_status":"confirmed"}');
  PERFORM pg_temp.ful('556');
  IF (SELECT attention_reason FROM public.exos_marketplace_orders WHERE external_order_id = '556') NOT LIKE 'no buyer email%' THEN
    RAISE EXCEPTION 'M4 FAIL: missing email not flagged';
  END IF;
  -- Listing without a tier.
  UPDATE public.exos_distribution_listings SET tier_id = NULL WHERE id = '3d000000-0000-0000-0000-0000000000b1';
  PERFORM pg_temp.rec('{"channel":"stubhub","external_order_id":"557","external_listing_id":"SH-L-1","quantity":1,"sale_status":"confirmed","buyer_email":"c@x.com"}');
  PERFORM pg_temp.ful('557');
  IF (SELECT attention_reason FROM public.exos_marketplace_orders WHERE external_order_id = '557') NOT LIKE '%no ticket type%' THEN
    RAISE EXCEPTION 'M4 FAIL: missing tier not flagged';
  END IF;
  IF (SELECT count(*) FROM public.exos_tickets WHERE channel_source = 'stubhub') <> 2
     OR (SELECT count(*) FROM public.exos_mail WHERE to_email IN ('b@x.com','c@x.com')) <> 0 THEN
    RAISE EXCEPTION 'M4 FAIL: minted or emailed on a refused order';
  END IF;
  RAISE NOTICE 'M4 ok: oversold / no email / no tier go to a human, nothing minted';
END $$;

-- M5 ---------------------------------------------------------------------------
DO $$
BEGIN
  IF pg_temp.rec('{"channel":"stubhub","external_order_id":"557","external_listing_id":"SH-L-1","quantity":1,"sale_status":"cancelled"}') <> 'cancelled' THEN
    RAISE EXCEPTION 'M5 FAIL: cancel before tickets not cancelled';
  END IF;
  IF pg_temp.rec('{"channel":"stubhub","external_order_id":"555","external_listing_id":"SH-L-1","quantity":2,"sale_status":"cancelled"}') <> 'needs_attention' THEN
    RAISE EXCEPTION 'M5 FAIL: cancel after tickets not flagged';
  END IF;
  IF (SELECT attention_reason FROM public.exos_marketplace_orders WHERE external_order_id = '555') NOT LIKE '%void them%' THEN
    RAISE EXCEPTION 'M5 FAIL: reason missing';
  END IF;
  RAISE NOTICE 'M5 ok: cancellations handled';
END $$;

-- M6 ---------------------------------------------------------------------------
SELECT set_config('app.uid','3d000000-0000-0000-0000-0000000000a0',true);
SET LOCAL ROLE authenticated;
DO $$
BEGIN
  BEGIN
    PERFORM public.exos_record_marketplace_order('{"channel":"stubhub","external_order_id":"X","external_listing_id":"SH-L-1","quantity":1}');
    RAISE EXCEPTION 'M6 FAIL: organizer recorded an order';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  BEGIN
    PERFORM public.exos_fulfil_marketplace_order((SELECT id FROM public.exos_marketplace_orders LIMIT 1));
    RAISE EXCEPTION 'M6 FAIL: organizer fulfilled an order';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  RAISE NOTICE 'M6 ok: service_role only';
END $$;
RESET ROLE;
ROLLBACK;
