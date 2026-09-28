-- ============================================================================
-- Security hardening (mig 20260929010000). Self-contained (5e prefix),
-- rolled back at the end.
--   S1 a voucher can't name another event's ticket type, and one already there
--      doesn't hold that tier's seats (the cross-org sell-out)
--   S2 finance reads vouchers but can't delete them
--   S3 guessing codes is throttled: 10 misses per account, 60 per event anon
--   S4 claim links: staff can't read claim keys; without the key only the
--      addressed account claims; a wrong key is refused; the right key works
--      for any account; the sender can read their own key, nobody else
--   S5 removing a manager revokes their API keys and switches off their webhooks
--   S6 an add-on's tax rate must be on its own event
--   S7 new custom codes are at least 6 characters
-- ============================================================================
\set ON_ERROR_STOP on
BEGIN;
INSERT INTO auth.users(id,email,email_confirmed_at) VALUES
  ('5e000000-0000-0000-0000-0000000000a0','5e-owner@x.com',now()),
  ('5e000000-0000-0000-0000-0000000000a1','5e-rival@x.com',now()),
  ('5e000000-0000-0000-0000-0000000000a2','5e-finance@x.com',now()),
  ('5e000000-0000-0000-0000-0000000000a3','5e-door@x.com',now()),
  ('5e000000-0000-0000-0000-0000000000a4','5e-manager@x.com',now()),
  ('5e000000-0000-0000-0000-0000000000b1','5e-fan@x.com',now()),
  ('5e000000-0000-0000-0000-0000000000b2','5e-friend@x.com',now());
INSERT INTO public.exos_orgs(id,name,slug,owner_uid) VALUES
  ('5e000000-0000-0000-0000-000000000001','5E Org','5e-org','5e000000-0000-0000-0000-0000000000a0'),
  ('5e000000-0000-0000-0000-000000000002','5E Rival','5e-rival','5e000000-0000-0000-0000-0000000000a1');
INSERT INTO public.exos_org_memberships(org_id,user_id,role) VALUES
  ('5e000000-0000-0000-0000-000000000001','5e000000-0000-0000-0000-0000000000a0','owner'),
  ('5e000000-0000-0000-0000-000000000001','5e000000-0000-0000-0000-0000000000a2','finance'),
  ('5e000000-0000-0000-0000-000000000001','5e000000-0000-0000-0000-0000000000a3','scanner'),
  ('5e000000-0000-0000-0000-000000000001','5e000000-0000-0000-0000-0000000000a4','manager'),
  ('5e000000-0000-0000-0000-000000000002','5e000000-0000-0000-0000-0000000000a1','owner');
INSERT INTO public.exos_events(id,org_id,name,slug,status,starts_at,venue_name,total_tickets,tickets_sold) VALUES
  ('5e000000-0000-0000-0000-0000000000e1','5e000000-0000-0000-0000-000000000001','5E Show','5e-show','published',now() + interval '10 days','Hall',0,0),
  ('5e000000-0000-0000-0000-0000000000e2','5e000000-0000-0000-0000-000000000002','Rival Show','5e-rival-show','published',now() + interval '10 days','Hall',0,0);
INSERT INTO public.exos_ticket_tiers(id,event_id,name,price,capacity,sold) VALUES
  ('5e000000-0000-0000-0000-0000000000d1','5e000000-0000-0000-0000-0000000000e1','GA',40,500,0),
  ('5e000000-0000-0000-0000-0000000000d2','5e000000-0000-0000-0000-0000000000e2','GA',40,500,0);

-- Prod grants signed-in users SELECT on events (RLS decides the rows); the
-- harness schema doesn't, and the voucher policies read the event.
GRANT SELECT ON public.exos_events TO authenticated;
-- Prod's ticket column grant (mig 20260702123000: everything but barcode_secret).
GRANT SELECT (id, event_id, org_id, tier_id, tier_name, buyer_id, owner_id, status,
              pending_transfer_id, transfer_id, check_in_at, created_at) ON public.exos_tickets TO authenticated;

CREATE OR REPLACE FUNCTION pg_temp.as_user(p_uid text, p_email text) RETURNS void LANGUAGE sql AS $$
  SELECT set_config('app.uid', coalesce(p_uid, ''), true), set_config('app.jwt', json_build_object('email', p_email)::text, true);
$$;

-- S1 -------------------------------------------------------------------------
-- The rival owner tries to hold the victim's tier with a blocking voucher on
-- their own event.
SELECT pg_temp.as_user('5e000000-0000-0000-0000-0000000000a1', '5e-rival@x.com');
SET LOCAL ROLE authenticated;
DO $$
DECLARE refused boolean := false;
BEGIN
  BEGIN
    INSERT INTO public.exos_vouchers(event_id, code, tier_id, max_uses, block_quota)
    VALUES ('5e000000-0000-0000-0000-0000000000e2', 'HOLDALL', '5e000000-0000-0000-0000-0000000000d1', 100000, true);
  EXCEPTION WHEN others THEN refused := true;
  END;
  IF NOT refused THEN RAISE EXCEPTION 'S1 FAIL: cross-event voucher accepted'; END IF;
END $$;
RESET ROLE;
DO $$
BEGIN
  -- A row from before the fix (trigger off to plant it) no longer counts.
  ALTER TABLE public.exos_vouchers DISABLE TRIGGER exos_vouchers_scope;
  INSERT INTO public.exos_vouchers(event_id, code, tier_id, max_uses, block_quota)
  VALUES ('5e000000-0000-0000-0000-0000000000e2', 'LEGACYHOLD', '5e000000-0000-0000-0000-0000000000d1', 100000, true);
  ALTER TABLE public.exos_vouchers ENABLE TRIGGER exos_vouchers_scope;
  IF public.exos_tier_available('5e000000-0000-0000-0000-0000000000d1') <> 500 THEN
    RAISE EXCEPTION 'S1 FAIL: another event''s voucher still holds seats (%)', public.exos_tier_available('5e000000-0000-0000-0000-0000000000d1');
  END IF;
  -- The organizer's own blocking voucher still holds them.
  INSERT INTO public.exos_vouchers(event_id, code, tier_id, max_uses, block_quota)
  VALUES ('5e000000-0000-0000-0000-0000000000e1', 'VIPHOLD', '5e000000-0000-0000-0000-0000000000d1', 20, true);
  IF public.exos_tier_available('5e000000-0000-0000-0000-0000000000d1') <> 480 THEN
    RAISE EXCEPTION 'S1 FAIL: own blocking voucher ignored';
  END IF;
  RAISE NOTICE 'S1 ok: no cross-event voucher; a planted one holds nothing';
END $$;

-- S2 -------------------------------------------------------------------------
SELECT pg_temp.as_user('5e000000-0000-0000-0000-0000000000a2', '5e-finance@x.com');
SET LOCAL ROLE authenticated;
DO $$
DECLARE n int;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.exos_vouchers WHERE code = 'VIPHOLD') THEN RAISE EXCEPTION 'S2 FAIL: finance cannot read'; END IF;
  DELETE FROM public.exos_vouchers WHERE code = 'VIPHOLD';
  GET DIAGNOSTICS n = ROW_COUNT;
  IF n <> 0 THEN RAISE EXCEPTION 'S2 FAIL: finance deleted a voucher'; END IF;
END $$;
RESET ROLE;
DO $$ BEGIN RAISE NOTICE 'S2 ok: finance reads vouchers, cannot delete them'; END $$;

-- S3 -------------------------------------------------------------------------
DO $$
DECLARE r record; i int;
BEGIN
  PERFORM pg_temp.as_user('5e000000-0000-0000-0000-0000000000b1', '5e-fan@x.com');
  FOR i IN 1..10 LOOP
    SELECT * INTO r FROM public.exos_check_voucher('5e000000-0000-0000-0000-0000000000e1', 'GUESS' || i);
    IF r.reason <> 'invalid code' THEN RAISE EXCEPTION 'S3 FAIL: miss % said %', i, r.reason; END IF;
  END LOOP;
  SELECT * INTO r FROM public.exos_check_voucher('5e000000-0000-0000-0000-0000000000e1', 'VIPHOLD');
  IF r.is_valid OR r.reason <> 'too many attempts' THEN RAISE EXCEPTION 'S3 FAIL: account not throttled (%)', r.reason; END IF;
  -- Anonymous callers share a per-event budget.
  PERFORM pg_temp.as_user(NULL, NULL);
  FOR i IN 1..60 LOOP PERFORM public.exos_check_voucher('5e000000-0000-0000-0000-0000000000e1', 'ANON' || i); END LOOP;
  SELECT * INTO r FROM public.exos_check_voucher('5e000000-0000-0000-0000-0000000000e1', 'VIPHOLD');
  IF r.reason IS DISTINCT FROM 'too many attempts' THEN RAISE EXCEPTION 'S3 FAIL: anonymous not throttled'; END IF;
  -- Other events and other accounts are unaffected.
  PERFORM pg_temp.as_user('5e000000-0000-0000-0000-0000000000b2', '5e-friend@x.com');
  SELECT * INTO r FROM public.exos_check_voucher('5e000000-0000-0000-0000-0000000000e1', 'VIPHOLD');
  IF NOT r.is_valid THEN RAISE EXCEPTION 'S3 FAIL: a fresh account was blocked (%)', r.reason; END IF;
  RAISE NOTICE 'S3 ok: 10 misses per account, 60 per event anonymous, then "too many attempts"';
END $$;

-- S4 -------------------------------------------------------------------------
DO $$
BEGIN
  PERFORM pg_temp.as_user('5e000000-0000-0000-0000-0000000000a0', '5e-owner@x.com');
  -- A comp to someone without an account: pending transfer, claim link mailed.
  PERFORM public.exos_issue_ticket_to_email('5e000000-0000-0000-0000-0000000000e1', '5e000000-0000-0000-0000-0000000000d1',
                                            '5e-guest@x.com', 1, 'comp');
  IF (SELECT count(*) FROM public.exos_transfers WHERE receiver_email = '5e-guest@x.com' AND status = 'pending') <> 1 THEN
    RAISE EXCEPTION 'S4 FAIL: no pending transfer';
  END IF;
  IF (SELECT html FROM public.exos_mail WHERE to_email = '5e-guest@x.com' ORDER BY created_at DESC LIMIT 1)
     NOT LIKE '%/claim/' || (SELECT id FROM public.exos_transfers WHERE receiver_email = '5e-guest@x.com') || '?k='
              || public.exos_test_claim_key((SELECT id FROM public.exos_transfers WHERE receiver_email = '5e-guest@x.com')) || '"%' THEN
    RAISE EXCEPTION 'S4 FAIL: the mailed link has no key';
  END IF;
END $$;
-- Door staff see the transfer id but not the key, and the id alone doesn't claim.
SELECT pg_temp.as_user('5e000000-0000-0000-0000-0000000000a3', '5e-door@x.com');
SET LOCAL ROLE authenticated;
DO $$
DECLARE tr uuid; e text; denied boolean := false;
BEGIN
  SELECT pending_transfer_id INTO tr FROM public.exos_tickets WHERE event_id = '5e000000-0000-0000-0000-0000000000e1' AND pending_transfer_id IS NOT NULL LIMIT 1;
  IF tr IS NULL THEN RAISE EXCEPTION 'S4 FAIL: fixture (staff should see the ticket)'; END IF;
  BEGIN
    PERFORM claim_key FROM public.exos_transfers WHERE id = tr;
  EXCEPTION WHEN insufficient_privilege THEN denied := true;
  END;
  IF NOT denied THEN RAISE EXCEPTION 'S4 FAIL: staff can read claim_key'; END IF;
  BEGIN
    PERFORM public.exos_claim_transfer(tr);
  EXCEPTION WHEN others THEN e := SQLERRM;
  END;
  IF e IS NULL OR e NOT LIKE '%claim link%' THEN RAISE EXCEPTION 'S4 FAIL: staff claimed without the key (%)', e; END IF;
  e := NULL;
  BEGIN
    PERFORM public.exos_claim_transfer(tr, 'deadbeefdeadbeefdeadbeefdeadbeef');
  EXCEPTION WHEN others THEN e := SQLERRM;
  END;
  IF e IS NULL OR e NOT LIKE '%not valid%' THEN RAISE EXCEPTION 'S4 FAIL: wrong key accepted (%)', e; END IF;
  IF public.exos_transfer_claim_key(tr) IS NOT NULL THEN RAISE EXCEPTION 'S4 FAIL: non-sender read the key'; END IF;
  IF (SELECT owner_id FROM public.exos_tickets WHERE pending_transfer_id = tr) = '5e000000-0000-0000-0000-0000000000a3' THEN
    RAISE EXCEPTION 'S4 FAIL: staff own it';
  END IF;
END $$;
RESET ROLE;
-- With the key from the link, any verified account claims it (the id and key
-- come from the URL, not from a table the friend can read).
SELECT set_config('test.tr', (SELECT id::text FROM public.exos_transfers WHERE receiver_email = '5e-guest@x.com'), true);
SELECT pg_temp.as_user('5e000000-0000-0000-0000-0000000000b2', '5e-friend@x.com');
SET LOCAL ROLE authenticated;
DO $$
DECLARE tr uuid := current_setting('test.tr')::uuid; tk uuid;
BEGIN
  tk := public.exos_claim_transfer(tr, public.exos_test_claim_key(tr));
  IF (SELECT owner_id FROM public.exos_tickets WHERE id = tk) <> '5e000000-0000-0000-0000-0000000000b2' THEN
    RAISE EXCEPTION 'S4 FAIL: keyed claim';
  END IF;
END $$;
RESET ROLE;
-- The addressed account still claims from My Tickets without a key, and a
-- sender reads their own transfer's key.
DO $$
DECLARE tk uuid; tr uuid;
BEGIN
  PERFORM pg_temp.as_user('5e000000-0000-0000-0000-0000000000a0', '5e-owner@x.com');
  PERFORM public.exos_issue_ticket_to_email('5e000000-0000-0000-0000-0000000000e1', '5e000000-0000-0000-0000-0000000000d1',
                                            '5e-later@x.com', 1, 'comp');
  SELECT id INTO tr FROM public.exos_transfers WHERE receiver_email = '5e-later@x.com' AND status = 'pending';
  -- They sign up with that address afterwards and claim from My Tickets.
  INSERT INTO auth.users(id,email,email_confirmed_at) VALUES ('5e000000-0000-0000-0000-0000000000b3','5e-later@x.com',now());
  PERFORM pg_temp.as_user('5e000000-0000-0000-0000-0000000000b3', '5e-later@x.com');
  tk := public.exos_claim_transfer(tr);
  IF (SELECT owner_id FROM public.exos_tickets WHERE id = tk) <> '5e000000-0000-0000-0000-0000000000b3' THEN
    RAISE EXCEPTION 'S4 FAIL: addressed claim';
  END IF;
  tr := public.exos_create_transfer(tk, '5e-friend@x.com', NULL);
  IF public.exos_transfer_claim_key(tr) IS DISTINCT FROM public.exos_test_claim_key(tr) THEN
    RAISE EXCEPTION 'S4 FAIL: sender cannot read their own key';
  END IF;
  RAISE NOTICE 'S4 ok: claim links need their key; staff can''t read it; the addressed account and the sender still can';
END $$;

-- S5 -------------------------------------------------------------------------
DO $$
BEGIN
  INSERT INTO public.exos_api_keys(id, org_id, name, key_prefix, key_hash, created_by)
  VALUES ('5e000000-0000-0000-0000-0000000000c1', '5e000000-0000-0000-0000-000000000001', 'mgr', 'sk_5e', 'hash-5e', '5e000000-0000-0000-0000-0000000000a4');
  INSERT INTO public.exos_webhooks(id, org_id, url, secret, event_types, enabled, created_by)
  VALUES ('5e000000-0000-0000-0000-0000000000c2', '5e000000-0000-0000-0000-000000000001', 'https://hooks.example.test/x', 's', ARRAY['ticket.created'], true, '5e000000-0000-0000-0000-0000000000a4');
  DELETE FROM public.exos_org_memberships WHERE user_id = '5e000000-0000-0000-0000-0000000000a4';
  IF (SELECT revoked_at FROM public.exos_api_keys WHERE id = '5e000000-0000-0000-0000-0000000000c1') IS NULL
     OR (SELECT enabled FROM public.exos_webhooks WHERE id = '5e000000-0000-0000-0000-0000000000c2') THEN
    RAISE EXCEPTION 'S5 FAIL: key or webhook survived offboarding';
  END IF;
  RAISE NOTICE 'S5 ok: offboarding revokes the member''s API keys and webhooks';
END $$;

-- S6 -------------------------------------------------------------------------
DO $$
DECLARE refused boolean := false; rid uuid;
BEGIN
  INSERT INTO public.exos_tax_rules(id, event_id, name, rate_percent) VALUES
    (gen_random_uuid(), '5e000000-0000-0000-0000-0000000000e2', 'Rival tax', 99) RETURNING id INTO rid;
  BEGIN
    INSERT INTO public.exos_event_addons(event_id, name, price, capacity, tax_rate_id)
    VALUES ('5e000000-0000-0000-0000-0000000000e1', 'Poster', 10, 10, rid);
  EXCEPTION WHEN others THEN refused := true;
  END;
  IF NOT refused THEN RAISE EXCEPTION 'S6 FAIL: add-on took another event''s tax rate'; END IF;
  RAISE NOTICE 'S6 ok: an add-on''s tax rate is on its own event';
END $$;

-- S7 -------------------------------------------------------------------------
DO $$
DECLARE e text;
BEGIN
  PERFORM pg_temp.as_user('5e000000-0000-0000-0000-0000000000a0', '5e-owner@x.com');
  BEGIN
    PERFORM public.exos_issue_voucher('5e000000-0000-0000-0000-0000000000e1', NULL, NULL, false, NULL, 1, NULL, NULL, 'VIP', 10, NULL);
  EXCEPTION WHEN others THEN e := SQLERRM;
  END;
  IF e IS NULL THEN RAISE EXCEPTION 'S7 FAIL: 3-character code accepted'; END IF;
  PERFORM public.exos_issue_voucher('5e000000-0000-0000-0000-0000000000e1', NULL, NULL, false, NULL, 1, NULL, NULL, 'VIPNIGHT', 10, NULL);
  RAISE NOTICE 'S7 ok: custom codes are at least 6 characters';
END $$;

ROLLBACK;
