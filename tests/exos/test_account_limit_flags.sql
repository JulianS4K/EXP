-- ============================================================================
-- Per-account limit flags (mig 20260926194000): the Exos ACCOUNT is flagged
-- when it holds more of an event's tickets than maxPerAccount; a sale or a
-- pending transfer never is. Self-contained (6f prefix), rolled back.
--   F1 marketplace sales over the limit: no flag while the tickets are only
--      on their way; nothing blocked
--   F2 the account claims them and holds 4 of max 3: flagged, with the
--      promoter code the tickets were sold through
--   F3 no limit on the event, or org staff: no flag
--   F4 the organizer reviews; holding more later re-opens it
--   F5 the promoter sees it (email masked) and leaves a note; another
--      promoter, a paused one and a buyer can't
--   psql -d <db> -v ON_ERROR_STOP=1 -f tests/exos/test_account_limit_flags.sql
-- ============================================================================
\set ON_ERROR_STOP on
BEGIN;
INSERT INTO auth.users(id,email,email_confirmed_at) VALUES
  ('6f000000-0000-0000-0000-0000000000a0','6f-owner@x.com',now()),
  ('6f000000-0000-0000-0000-0000000000a1','6f-staff@x.com',now()),
  ('6f000000-0000-0000-0000-0000000000b0','fan@x.com',now());
INSERT INTO public.exos_orgs(id,name,slug,owner_uid) VALUES
  ('6f000000-0000-0000-0000-000000000001','6F Org','6f-org','6f000000-0000-0000-0000-0000000000a0');
INSERT INTO public.exos_org_memberships(org_id,user_id,role) VALUES
  ('6f000000-0000-0000-0000-000000000001','6f000000-0000-0000-0000-0000000000a0','owner'),
  ('6f000000-0000-0000-0000-000000000001','6f000000-0000-0000-0000-0000000000a1','manager');
INSERT INTO public.exos_promoters(id,org_id,code,name,kit_token,status) VALUES
  ('6f000000-0000-0000-0000-0000000000f1','6f000000-0000-0000-0000-000000000001','6f-nina','Nina','6f000000-0000-0000-0000-00000000aaa1','active'),
  ('6f000000-0000-0000-0000-0000000000f2','6f000000-0000-0000-0000-000000000001','6f-omar','Omar','6f000000-0000-0000-0000-00000000aaa2','active');
INSERT INTO public.exos_events(id,org_id,name,status,starts_at,venue_name,total_tickets,purchase_limits) VALUES
  ('6f000000-0000-0000-0000-0000000000e1','6f000000-0000-0000-0000-000000000001','Capped','published','2027-01-01T02:00:00Z','Hall',100,'{"maxPerOrder":4,"maxPerAccount":3}'),
  ('6f000000-0000-0000-0000-0000000000e2','6f000000-0000-0000-0000-000000000001','Open','published','2027-01-02T02:00:00Z','Hall',100,NULL);
INSERT INTO public.exos_ticket_tiers(id,event_id,name,price,capacity,sold) VALUES
  ('6f000000-0000-0000-0000-0000000000d1','6f000000-0000-0000-0000-0000000000e1','GA',40,100,0),
  ('6f000000-0000-0000-0000-0000000000d2','6f000000-0000-0000-0000-0000000000e2','GA',40,100,0);
INSERT INTO public.exos_distribution_listings(id,event_id,org_id,channel,status,tier_id,requested_qty,external_listing_id) VALUES
  ('6f000000-0000-0000-0000-0000000000c1','6f000000-0000-0000-0000-0000000000e1','6f000000-0000-0000-0000-000000000001','stubhub','listed','6f000000-0000-0000-0000-0000000000d1',10,'SH-6F');

CREATE OR REPLACE FUNCTION pg_temp.flags() RETURNS int LANGUAGE sql AS $$
  SELECT count(*)::int FROM public.exos_account_limit_flags WHERE org_id = '6f000000-0000-0000-0000-000000000001'
$$;

-- F1 ---------------------------------------------------------------------------
-- Two StubHub orders of 2 by the same buyer, each within maxPerOrder.
DO $$
BEGIN
  PERFORM public.exos_record_marketplace_order('{"channel":"stubhub","external_order_id":"6F-1","external_listing_id":"SH-6F","quantity":2,"sale_status":"confirmed","buyer_email":"fan@x.com"}');
  PERFORM public.exos_fulfil_marketplace_order((SELECT id FROM public.exos_marketplace_orders WHERE external_order_id = '6F-1'));
  PERFORM public.exos_record_marketplace_order('{"channel":"stubhub","external_order_id":"6F-2","external_listing_id":"SH-6F","quantity":2,"sale_status":"confirmed","buyer_email":"fan@x.com"}');
  PERFORM public.exos_fulfil_marketplace_order((SELECT id FROM public.exos_marketplace_orders WHERE external_order_id = '6F-2'));
  IF (SELECT count(*) FROM public.exos_marketplace_orders WHERE external_order_id IN ('6F-1','6F-2') AND status = 'fulfilled') <> 2 THEN
    RAISE EXCEPTION 'F1 FAIL: a sale was blocked';
  END IF;
  IF pg_temp.flags() <> 0 THEN
    RAISE EXCEPTION 'F1 FAIL: flagged the sale / pending transfers, not an account holding tickets';
  END IF;
  RAISE NOTICE 'F1 ok: sales over the limit are not flagged while tickets are only on their way';
END $$;

-- F2 ---------------------------------------------------------------------------
-- The buyer claims all four (what exos_claim_transfer does to the rows); two
-- were sold through Nina's link.
UPDATE public.exos_transfers SET status = 'completed'
 WHERE lower(receiver_email) = 'fan@x.com' AND status = 'pending';
UPDATE public.exos_tickets SET promoter_id = '6f-nina'
 WHERE order_ref = 'stubhub:6F-1';
UPDATE public.exos_tickets SET owner_id = '6f000000-0000-0000-0000-0000000000b0', pending_transfer_id = NULL
 WHERE order_ref IN ('stubhub:6F-1','stubhub:6F-2');
DO $$
DECLARE f record;
BEGIN
  SELECT * INTO f FROM public.exos_account_limit_flags WHERE user_id = '6f000000-0000-0000-0000-0000000000b0';
  IF f.id IS NULL OR f.held <> 4 OR f.peak <> 4 OR f.max_per_account <> 3 OR f.email <> 'fan@x.com'
     OR f.promoter_codes <> ARRAY['6f-nina'] OR f.reviewed_at IS NOT NULL THEN
    RAISE EXCEPTION 'F2 FAIL: %', row_to_json(f);
  END IF;
  IF pg_temp.flags() <> 1 THEN RAISE EXCEPTION 'F2 FAIL: % flags (the org owner parked them first)', pg_temp.flags(); END IF;
  RAISE NOTICE 'F2 ok: the account holding 4 of max 3 is flagged, with its promoter';
END $$;

-- F3 ---------------------------------------------------------------------------
INSERT INTO public.exos_tickets(event_id,org_id,tier_id,buyer_id,owner_id,status,barcode_secret)
SELECT '6f000000-0000-0000-0000-0000000000e2','6f000000-0000-0000-0000-000000000001','6f000000-0000-0000-0000-0000000000d2',
       '6f000000-0000-0000-0000-0000000000b0','6f000000-0000-0000-0000-0000000000b0','active','o'||g
  FROM generate_series(1,5) g;   -- no maxPerAccount on this event
INSERT INTO public.exos_tickets(event_id,org_id,tier_id,buyer_id,owner_id,status,barcode_secret)
SELECT '6f000000-0000-0000-0000-0000000000e1','6f000000-0000-0000-0000-000000000001','6f000000-0000-0000-0000-0000000000d1',
       '6f000000-0000-0000-0000-0000000000a1','6f000000-0000-0000-0000-0000000000a1','active','s'||g
  FROM generate_series(1,5) g;   -- box office stock on a manager
DO $$
BEGIN
  IF pg_temp.flags() <> 1 THEN RAISE EXCEPTION 'F3 FAIL: flagged an uncapped event or org staff'; END IF;
  RAISE NOTICE 'F3 ok: no limit / staff -> no flag';
END $$;

-- F4 ---------------------------------------------------------------------------
SELECT set_config('app.uid','6f000000-0000-0000-0000-0000000000a0',true);
SET LOCAL ROLE authenticated;
SELECT public.exos_review_account_limit_flag((SELECT id FROM public.exos_account_limit_flags WHERE user_id = '6f000000-0000-0000-0000-0000000000b0'), 'Group booking, fine');
RESET ROLE;
DO $$
BEGIN
  IF (SELECT reviewed_at FROM public.exos_account_limit_flags WHERE user_id = '6f000000-0000-0000-0000-0000000000b0') IS NULL THEN
    RAISE EXCEPTION 'F4 FAIL: review not recorded';
  END IF;
  -- Voiding one: back to 3, the flag stays (history), reviewed.
  UPDATE public.exos_tickets SET status = 'voided'
   WHERE id = (SELECT id FROM public.exos_tickets WHERE order_ref = 'stubhub:6F-2' LIMIT 1);
  IF (SELECT held FROM public.exos_account_limit_flags WHERE user_id = '6f000000-0000-0000-0000-0000000000b0') <> 3
     OR (SELECT reviewed_at FROM public.exos_account_limit_flags WHERE user_id = '6f000000-0000-0000-0000-0000000000b0') IS NULL THEN
    RAISE EXCEPTION 'F4 FAIL: void not reflected';
  END IF;
  -- A friend transfers them two more: 5, a new high, re-opened.
  INSERT INTO public.exos_tickets(event_id,org_id,tier_id,buyer_id,owner_id,status,barcode_secret)
  SELECT '6f000000-0000-0000-0000-0000000000e1','6f000000-0000-0000-0000-000000000001','6f000000-0000-0000-0000-0000000000d1',
         '6f000000-0000-0000-0000-0000000000b0','6f000000-0000-0000-0000-0000000000b0','active','t'||g FROM generate_series(1,2) g;
  IF (SELECT reviewed_at FROM public.exos_account_limit_flags WHERE user_id = '6f000000-0000-0000-0000-0000000000b0') IS NOT NULL
     OR (SELECT peak FROM public.exos_account_limit_flags WHERE user_id = '6f000000-0000-0000-0000-0000000000b0') <> 5 THEN
    RAISE EXCEPTION 'F4 FAIL: a new high did not re-open the flag';
  END IF;
  RAISE NOTICE 'F4 ok: reviews stick until the account holds more than ever';
END $$;

-- F5 ---------------------------------------------------------------------------
SET LOCAL ROLE anon;
DO $$
DECLARE j jsonb; fid uuid;
BEGIN
  j := public.exos_promoter_limit_flags('6f000000-0000-0000-0000-00000000aaa1');
  IF jsonb_array_length(j) <> 1 OR j -> 0 ->> 'buyer' <> 'f***@x.com' OR (j -> 0 ->> 'from_you')::int <> 2
     OR j::text LIKE '%fan@x.com%' THEN
    RAISE EXCEPTION 'F5 FAIL: promoter view %', j;
  END IF;
  fid := (j -> 0 ->> 'id')::uuid;
  PERFORM public.exos_promoter_note_limit_flag('6f000000-0000-0000-0000-00000000aaa1', fid, 'My cousin, buying for family');
  -- Omar sold none of those tickets.
  IF jsonb_array_length(public.exos_promoter_limit_flags('6f000000-0000-0000-0000-00000000aaa2')) <> 0 THEN
    RAISE EXCEPTION 'F5 FAIL: another promoter sees the flag';
  END IF;
  BEGIN
    PERFORM public.exos_promoter_note_limit_flag('6f000000-0000-0000-0000-00000000aaa2', fid, 'not mine');
    RAISE EXCEPTION 'F5 FAIL: another promoter wrote a note';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
END $$;
RESET ROLE;
UPDATE public.exos_promoters SET status = 'paused' WHERE code = '6f-nina';
DO $$
BEGIN
  IF (SELECT promoter_note FROM public.exos_account_limit_flags WHERE user_id = '6f000000-0000-0000-0000-0000000000b0') <> 'My cousin, buying for family'
     OR (SELECT promoter_noted_by FROM public.exos_account_limit_flags WHERE user_id = '6f000000-0000-0000-0000-0000000000b0') <> '6f-nina' THEN
    RAISE EXCEPTION 'F5 FAIL: promoter note not stored';
  END IF;
  IF jsonb_array_length(public.exos_promoter_limit_flags('6f000000-0000-0000-0000-00000000aaa1')) <> 0 THEN
    RAISE EXCEPTION 'F5 FAIL: a paused promoter still sees flags';
  END IF;
END $$;
SELECT set_config('app.uid','6f000000-0000-0000-0000-0000000000b0',true);
SET LOCAL ROLE authenticated;
DO $$
BEGIN
  BEGIN
    PERFORM public.exos_review_account_limit_flag((SELECT id FROM public.exos_account_limit_flags LIMIT 1), 'mine');
    RAISE EXCEPTION 'F5 FAIL: a buyer reviewed a flag';
  EXCEPTION WHEN insufficient_privilege OR raise_exception THEN NULL;
  END;
  RAISE NOTICE 'F5 ok: promoters see their flags masked and can note them; only the organizer reviews';
END $$;
RESET ROLE;
ROLLBACK;
