-- ============================================================================
-- Per-account limit flags + planned listings (mig 20260926194000).
-- Self-contained (6f prefix), rolled back at the end.
--   F1 a marketplace sale over maxPerAccount flags the buyer's email at once
--   F2 claiming moves the count from incoming to held and ties the account
--   F3 under the limit, no limit, or org staff: no flag; nothing is blocked
--   F4 review closes a flag; going higher again re-opens it
--   F5 planned_listing column; only owner/manager can review
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
INSERT INTO public.exos_events(id,org_id,name,status,starts_at,venue_name,total_tickets,purchase_limits) VALUES
  ('6f000000-0000-0000-0000-0000000000e1','6f000000-0000-0000-0000-000000000001','Capped','published','2027-01-01T02:00:00Z','Hall',100,'{"maxPerOrder":4,"maxPerAccount":3}'),
  ('6f000000-0000-0000-0000-0000000000e2','6f000000-0000-0000-0000-000000000001','Open','published','2027-01-02T02:00:00Z','Hall',100,NULL);
INSERT INTO public.exos_ticket_tiers(id,event_id,name,price,capacity,sold) VALUES
  ('6f000000-0000-0000-0000-0000000000d1','6f000000-0000-0000-0000-0000000000e1','GA',40,100,0),
  ('6f000000-0000-0000-0000-0000000000d2','6f000000-0000-0000-0000-0000000000e2','GA',40,100,0);
INSERT INTO public.exos_distribution_listings(id,event_id,org_id,channel,status,tier_id,requested_qty,external_listing_id) VALUES
  ('6f000000-0000-0000-0000-0000000000c1','6f000000-0000-0000-0000-0000000000e1','6f000000-0000-0000-0000-000000000001','stubhub','listed','6f000000-0000-0000-0000-0000000000d1',10,'SH-6F');

-- F1 ---------------------------------------------------------------------------
-- Two StubHub orders of 2 by the same buyer: each within maxPerOrder, together over 3.
DO $$
DECLARE f record;
BEGIN
  PERFORM public.exos_record_marketplace_order('{"channel":"stubhub","external_order_id":"6F-1","external_listing_id":"SH-6F","quantity":2,"sale_status":"confirmed","buyer_email":"Fan@x.com"}');
  PERFORM public.exos_fulfil_marketplace_order((SELECT id FROM public.exos_marketplace_orders WHERE external_order_id = '6F-1'));
  IF EXISTS (SELECT 1 FROM public.exos_account_limit_flags WHERE org_id = '6f000000-0000-0000-0000-000000000001') THEN RAISE EXCEPTION 'F1 FAIL: flagged at 2 of 3'; END IF;
  PERFORM public.exos_record_marketplace_order('{"channel":"stubhub","external_order_id":"6F-2","external_listing_id":"SH-6F","quantity":2,"sale_status":"confirmed","buyer_email":"fan@x.com"}');
  PERFORM public.exos_fulfil_marketplace_order((SELECT id FROM public.exos_marketplace_orders WHERE external_order_id = '6F-2'));
  IF (SELECT status FROM public.exos_marketplace_orders WHERE external_order_id = '6F-2') <> 'fulfilled' THEN
    RAISE EXCEPTION 'F1 FAIL: the flag blocked the sale';
  END IF;
  SELECT * INTO f FROM public.exos_account_limit_flags WHERE email = 'fan@x.com';
  IF f.id IS NULL OR f.incoming <> 4 OR f.held <> 0 OR f.max_per_account <> 3 OR f.peak <> 4
     OR f.user_id <> '6f000000-0000-0000-0000-0000000000b0' OR f.reviewed_at IS NOT NULL THEN
    RAISE EXCEPTION 'F1 FAIL: %', row_to_json(f);
  END IF;
  -- The org owner holding the parked tickets is not flagged.
  IF EXISTS (SELECT 1 FROM public.exos_account_limit_flags WHERE email = '6f-owner@x.com') THEN
    RAISE EXCEPTION 'F1 FAIL: flagged the org owner for parked tickets';
  END IF;
  RAISE NOTICE 'F1 ok: over-limit marketplace buyer flagged, sale not blocked';
END $$;

-- F2 ---------------------------------------------------------------------------
-- The buyer claims all four (what exos_claim_transfer does to the rows).
UPDATE public.exos_transfers SET status = 'completed'
 WHERE lower(receiver_email) = 'fan@x.com' AND status = 'pending';
UPDATE public.exos_tickets SET owner_id = '6f000000-0000-0000-0000-0000000000b0', pending_transfer_id = NULL
 WHERE order_ref IN ('stubhub:6F-1','stubhub:6F-2');
DO $$
DECLARE f record;
BEGIN
  SELECT * INTO f FROM public.exos_account_limit_flags WHERE email = 'fan@x.com';
  IF f.held <> 4 OR f.incoming <> 0 OR f.peak <> 4 THEN RAISE EXCEPTION 'F2 FAIL: %', row_to_json(f); END IF;
  RAISE NOTICE 'F2 ok: claimed tickets counted as held on the account';
END $$;

-- F3 ---------------------------------------------------------------------------
INSERT INTO public.exos_tickets(event_id,org_id,tier_id,buyer_id,owner_id,status,barcode_secret) VALUES
  -- no maxPerAccount on this event
  ('6f000000-0000-0000-0000-0000000000e2','6f000000-0000-0000-0000-000000000001','6f000000-0000-0000-0000-0000000000d2','6f000000-0000-0000-0000-0000000000b0','6f000000-0000-0000-0000-0000000000b0','active','x1'),
  ('6f000000-0000-0000-0000-0000000000e2','6f000000-0000-0000-0000-000000000001','6f000000-0000-0000-0000-0000000000d2','6f000000-0000-0000-0000-0000000000b0','6f000000-0000-0000-0000-0000000000b0','active','x2'),
  ('6f000000-0000-0000-0000-0000000000e2','6f000000-0000-0000-0000-000000000001','6f000000-0000-0000-0000-0000000000d2','6f000000-0000-0000-0000-0000000000b0','6f000000-0000-0000-0000-0000000000b0','active','x3'),
  ('6f000000-0000-0000-0000-0000000000e2','6f000000-0000-0000-0000-000000000001','6f000000-0000-0000-0000-0000000000d2','6f000000-0000-0000-0000-0000000000b0','6f000000-0000-0000-0000-0000000000b0','active','x4');
INSERT INTO public.exos_tickets(event_id,org_id,tier_id,buyer_id,owner_id,status,barcode_secret)
SELECT '6f000000-0000-0000-0000-0000000000e1','6f000000-0000-0000-0000-000000000001','6f000000-0000-0000-0000-0000000000d1',
       '6f000000-0000-0000-0000-0000000000a1','6f000000-0000-0000-0000-0000000000a1','active','s'||g
  FROM generate_series(1,5) g;   -- box office stock on a manager
DO $$
BEGIN
  IF (SELECT count(*) FROM public.exos_account_limit_flags WHERE org_id = '6f000000-0000-0000-0000-000000000001') <> 1 THEN
    RAISE EXCEPTION 'F3 FAIL: flagged an uncapped event or org staff';
  END IF;
  RAISE NOTICE 'F3 ok: no limit / staff -> no flag';
END $$;

-- F4 ---------------------------------------------------------------------------
SELECT set_config('app.uid','6f000000-0000-0000-0000-0000000000a0',true);
SET LOCAL ROLE authenticated;
SELECT public.exos_review_account_limit_flag((SELECT id FROM public.exos_account_limit_flags WHERE email = 'fan@x.com'), 'Group booking, fine');
RESET ROLE;
DO $$
BEGIN
  IF (SELECT reviewed_at FROM public.exos_account_limit_flags WHERE email = 'fan@x.com') IS NULL
     OR (SELECT review_note FROM public.exos_account_limit_flags WHERE email = 'fan@x.com') <> 'Group booking, fine' THEN
    RAISE EXCEPTION 'F4 FAIL: review not recorded';
  END IF;
  -- A third StubHub order: a new high re-opens it.
  PERFORM public.exos_record_marketplace_order('{"channel":"stubhub","external_order_id":"6F-3","external_listing_id":"SH-6F","quantity":1,"sale_status":"confirmed","buyer_email":"fan@x.com"}');
  PERFORM public.exos_fulfil_marketplace_order((SELECT id FROM public.exos_marketplace_orders WHERE external_order_id = '6F-3'));
  IF (SELECT reviewed_at FROM public.exos_account_limit_flags WHERE email = 'fan@x.com') IS NOT NULL
     OR (SELECT peak FROM public.exos_account_limit_flags WHERE email = 'fan@x.com') <> 5 THEN
    RAISE EXCEPTION 'F4 FAIL: going higher did not re-open the flag';
  END IF;
  RAISE NOTICE 'F4 ok: reviewed flags close, a new high re-opens them';
END $$;

-- F5 ---------------------------------------------------------------------------
UPDATE public.exos_distribution_listings SET planned_listing = '{"display_cap":4}' WHERE id = '6f000000-0000-0000-0000-0000000000c1';
SELECT set_config('app.uid','6f000000-0000-0000-0000-0000000000b0',true);
SET LOCAL ROLE authenticated;
DO $$
BEGIN
  BEGIN
    PERFORM public.exos_review_account_limit_flag((SELECT id FROM public.exos_account_limit_flags WHERE email = 'fan@x.com'), 'mine');
    RAISE EXCEPTION 'F5 FAIL: a buyer reviewed a flag';
  EXCEPTION WHEN insufficient_privilege OR raise_exception THEN NULL;
  END;
  RAISE NOTICE 'F5 ok: only the organizer reviews flags';
END $$;
RESET ROLE;
ROLLBACK;
