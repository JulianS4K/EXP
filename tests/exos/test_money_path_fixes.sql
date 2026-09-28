-- ============================================================================
-- Money path fixes (mig 20260929030000). Self-contained (6f prefix), rolled
-- back at the end.
--   H1 a hold can't take more than is left of the house (event total_tickets),
--      counting sold, live holds and marketplace allocations across tiers;
--      guest holds too
--   H2 purchase mails carry the amount paid, the tax in it and the order ref
--   (pending refunds keeping their tickets: test_organizer_refunds.sql M5)
-- ============================================================================
\set ON_ERROR_STOP on
BEGIN;
INSERT INTO auth.users(id,email,email_confirmed_at) VALUES
  ('6f000000-0000-0000-0000-0000000000a0','6f-owner@x.com',now()),
  ('6f000000-0000-0000-0000-0000000000b1','6f-fan@x.com',now());
INSERT INTO public.exos_orgs(id,name,slug,owner_uid) VALUES
  ('6f000000-0000-0000-0000-000000000001','6F Org','6f-org','6f000000-0000-0000-0000-0000000000a0');
INSERT INTO public.exos_org_memberships(org_id,user_id,role) VALUES
  ('6f000000-0000-0000-0000-000000000001','6f000000-0000-0000-0000-0000000000a0','owner');
-- A 12-person room sold as two ticket types of 10 each.
INSERT INTO public.exos_events(id,org_id,name,slug,status,starts_at,venue_name,total_tickets,tickets_sold) VALUES
  ('6f000000-0000-0000-0000-0000000000e1','6f000000-0000-0000-0000-000000000001','6F Room','6f-room','published',now() + interval '10 days','Room',12,0);
INSERT INTO public.exos_ticket_tiers(id,event_id,name,price,capacity,sold) VALUES
  ('6f000000-0000-0000-0000-0000000000d1','6f000000-0000-0000-0000-0000000000e1','Early',20,10,0),
  ('6f000000-0000-0000-0000-0000000000d2','6f000000-0000-0000-0000-0000000000e1','GA',30,10,0);

-- H1 -------------------------------------------------------------------------
DO $$
DECLARE e text;
BEGIN
  -- 9 sold on Early; GA alone has 10, but the room has 3 left.
  UPDATE public.exos_ticket_tiers SET sold = 9 WHERE id = '6f000000-0000-0000-0000-0000000000d1';
  UPDATE public.exos_events SET tickets_sold = 9 WHERE id = '6f000000-0000-0000-0000-0000000000e1';
  IF public.exos_event_house_available('6f000000-0000-0000-0000-0000000000e1') <> 3 THEN
    RAISE EXCEPTION 'H1 FAIL: house left %', public.exos_event_house_available('6f000000-0000-0000-0000-0000000000e1');
  END IF;
  PERFORM set_config('app.uid', '6f000000-0000-0000-0000-0000000000b1', true);
  PERFORM set_config('app.jwt', '{"email":"6f-fan@x.com"}', true);
  BEGIN
    PERFORM public.exos_create_hold('6f000000-0000-0000-0000-0000000000e1', '6f000000-0000-0000-0000-0000000000d2', 4);
  EXCEPTION WHEN others THEN e := SQLERRM;
  END;
  IF e IS NULL OR e NOT LIKE '%not enough tickets%' THEN RAISE EXCEPTION 'H1 FAIL: hold past the house cap (%)', e; END IF;
  PERFORM public.exos_create_hold('6f000000-0000-0000-0000-0000000000e1', '6f000000-0000-0000-0000-0000000000d2', 2);
  -- That live hold counts: a guest can take 1, not 2.
  PERFORM set_config('app.uid', '', true);
  e := NULL;
  BEGIN
    PERFORM public.exos_create_guest_hold('6f000000-0000-0000-0000-0000000000e1', '6f000000-0000-0000-0000-0000000000d2', 2, '6f-guest@x.com', 'ip-6f');
  EXCEPTION WHEN others THEN e := SQLERRM;
  END;
  IF e IS NULL OR e NOT LIKE '%not enough tickets%' THEN RAISE EXCEPTION 'H1 FAIL: guest hold past the house cap (%)', e; END IF;
  PERFORM public.exos_create_guest_hold('6f000000-0000-0000-0000-0000000000e1', '6f000000-0000-0000-0000-0000000000d2', 1, '6f-guest@x.com', 'ip-6f');
  -- No house cap: only the tier counts.
  UPDATE public.exos_events SET total_tickets = 0 WHERE id = '6f000000-0000-0000-0000-0000000000e1';
  IF public.exos_event_house_available('6f000000-0000-0000-0000-0000000000e1') IS NOT NULL THEN RAISE EXCEPTION 'H1 FAIL: uncapped'; END IF;
  RAISE NOTICE 'H1 ok: holds stop at the house cap (sold + live holds), signed in or guest';
END $$;

-- H2 -------------------------------------------------------------------------
DO $$
DECLARE r text;
BEGIN
  INSERT INTO public.exos_checkout_sessions(session_id,event_id,tier_id,org_id,buyer_uid,buyer_email,quantity,amount_cents,tax_cents,currency,status)
  VALUES ('cs_6f_<x>','6f000000-0000-0000-0000-0000000000e1','6f000000-0000-0000-0000-0000000000d2','6f000000-0000-0000-0000-000000000001',
          '6f000000-0000-0000-0000-0000000000b1','6f-fan@x.com',2,6532,532,'usd','pending');
  r := public.exos_receipt_html('cs_6f_<x>');
  IF r NOT LIKE '%Paid: <strong>65.32 USD</strong> (including 5.32 tax)%' OR r NOT LIKE '%cs_6f_&lt;x&gt;%' THEN
    RAISE EXCEPTION 'H2 FAIL: %', r;
  END IF;
  IF public.exos_receipt_html('nope') <> '' THEN RAISE EXCEPTION 'H2 FAIL: unknown session'; END IF;
  RAISE NOTICE 'H2 ok: receipts show the amount, tax and escaped order reference';
END $$;

ROLLBACK;
