-- ============================================================================
-- Marketplace sale notes (mig 20260929050000). Self-contained (5a prefix),
-- rolled back at the end.
--   N1 a TEvo order spanning two Exos listings (normalizeTevoOrder: status
--      'unknown' + sale_note) is recorded but never fulfilled: it goes to a
--      person with the note as the reason, and nothing is minted
--   N2 a later report without the note (the order was fixed upstream) clears
--      it and fulfils normally
--   psql -d <db> -v ON_ERROR_STOP=1 -f tests/exos/test_marketplace_sale_note.sql
-- ============================================================================
\set ON_ERROR_STOP on
BEGIN;
INSERT INTO auth.users(id,email,email_confirmed_at) VALUES
  ('5a000000-0000-0000-0000-0000000000a0','5a-owner@x.com',now());
INSERT INTO public.exos_orgs(id,name,slug,owner_uid) VALUES
  ('5a000000-0000-0000-0000-000000000001','5A Org','5a-org','5a000000-0000-0000-0000-0000000000a0');
INSERT INTO public.exos_org_memberships(org_id,user_id,role) VALUES
  ('5a000000-0000-0000-0000-000000000001','5a000000-0000-0000-0000-0000000000a0','owner');
INSERT INTO public.exos_events(id,org_id,name,status,starts_at,venue_name,total_tickets,tickets_sold,distribution_networks) VALUES
  ('5a000000-0000-0000-0000-0000000000e1','5a000000-0000-0000-0000-000000000001','Note Show','published','2027-01-01T02:00:00Z','Hall',100,0,ARRAY['evo']);
INSERT INTO public.exos_ticket_tiers(id,event_id,name,price,capacity,sold) VALUES
  ('5a000000-0000-0000-0000-0000000000d1','5a000000-0000-0000-0000-0000000000e1','GA',50,10,0);
SELECT public.exos_set_channel_allocation('5a000000-0000-0000-0000-0000000000e1','evo','5a000000-0000-0000-0000-0000000000d1',6);

-- N1 -------------------------------------------------------------------------
DO $$
DECLARE alloc uuid; r record; f record; o record;
BEGIN
  SELECT id INTO alloc FROM public.exos_distribution_listings WHERE event_id = '5a000000-0000-0000-0000-0000000000e1' AND channel = 'evo' AND tier_id IS NOT NULL;
  SELECT * INTO r FROM public.exos_record_marketplace_order(jsonb_build_object(
    'channel','evo','external_order_id','5a-1','external_listing_id', alloc::text,
    'quantity',5,'sale_status','unknown','buyer_email','n1@x.com',
    'sale_note','Ticket Evolution order has items from 2 different Exos listings (exa, exb): fulfil each listing''s tickets by hand'));
  SELECT * INTO f FROM public.exos_fulfil_marketplace_order(r.order_id, 'https://exos.example.test');
  IF f.status <> 'needs_attention' OR f.reason NOT LIKE 'Ticket Evolution order has items from 2 different Exos listings%' THEN
    RAISE EXCEPTION 'N1 FAIL: %', row_to_json(f);
  END IF;
  SELECT * INTO o FROM public.exos_marketplace_orders WHERE id = r.order_id;
  IF cardinality(o.ticket_ids) <> 0 OR o.attention_reason IS DISTINCT FROM f.reason
     OR EXISTS (SELECT 1 FROM public.exos_tickets WHERE order_ref = 'evo:5a-1') THEN
    RAISE EXCEPTION 'N1 FAIL: minted or reason not stored';
  END IF;
  -- Length is bounded.
  SELECT * INTO r FROM public.exos_record_marketplace_order(jsonb_build_object(
    'channel','evo','external_order_id','5a-2','external_listing_id', alloc::text,
    'quantity',1,'sale_status','unknown','sale_note', repeat('x', 900)));
  IF (SELECT length(sale_note) FROM public.exos_marketplace_orders WHERE id = r.order_id) <> 300 THEN
    RAISE EXCEPTION 'N1 FAIL: note not bounded';
  END IF;
  RAISE NOTICE 'N1 ok: a multi-listing TEvo order goes to a person with its note as the reason; nothing minted';
END $$;

-- N2 -------------------------------------------------------------------------
DO $$
DECLARE alloc uuid; r record; f record;
BEGIN
  SELECT id INTO alloc FROM public.exos_distribution_listings WHERE event_id = '5a000000-0000-0000-0000-0000000000e1' AND channel = 'evo' AND tier_id IS NOT NULL;
  SELECT * INTO r FROM public.exos_record_marketplace_order(jsonb_build_object(
    'channel','evo','external_order_id','5a-1','external_listing_id', alloc::text,
    'quantity',5,'sale_status','confirmed','buyer_email','n1@x.com','sale_note', NULL));
  IF (SELECT sale_note FROM public.exos_marketplace_orders WHERE id = r.order_id) IS NOT NULL THEN
    RAISE EXCEPTION 'N2 FAIL: note not cleared';
  END IF;
  SELECT * INTO f FROM public.exos_fulfil_marketplace_order(r.order_id, 'https://exos.example.test');
  IF f.status <> 'fulfilled' THEN RAISE EXCEPTION 'N2 FAIL: %', row_to_json(f); END IF;
  RAISE NOTICE 'N2 ok: a later report without the note clears it and fulfils';
END $$;

ROLLBACK;
