-- ============================================================================
-- Transfers are claimed into any Exos account (mig 20260927010000).
-- Self-contained (7a prefix), rolled back at the end.
--   L1 a marketplace sale's mail says any Exos account can claim (it doesn't
--      name the order email, which may be a relay)
--   L2 a verified account with a different email claims one; the ticket and
--      its rotated barcode are theirs; a second account can't claim it again
--   L3 an unverified account, or no account, can't claim
--   L4 an Exos-to-Exos transfer is claimed by an account other than the one
--      it was sent to, and then the addressed account can't
--   L5 the preview shows a transfer's display fields, with no emails
--   L6 box-office and comp tickets for someone without an account: the mail
--      says any account and carries one claim link per ticket, each only
--      to that recipient's own transfers
--   L7 sender paper trail: exos_create_transfer mails the sender a receipt
--      (recipient email + typed name, escaped, claim link); the claim mails
--      them who accepted it; a two-argument call still works; comps and
--      marketplace sales don't mail the organizer per ticket
--   L8 a code reserved to one email is redeemed by whoever uses it first,
--      and a single-use code still works once
--   psql -d <db> -v ON_ERROR_STOP=1 -f tests/exos/test_claim_any_account.sql
-- ============================================================================
\set ON_ERROR_STOP on
BEGIN;
INSERT INTO auth.users(id,email,email_confirmed_at) VALUES
  ('7a000000-0000-0000-0000-0000000000a0','7a-owner@x.com',now()),
  ('7a000000-0000-0000-0000-0000000000b1','real-me@x.com',now()),
  ('7a000000-0000-0000-0000-0000000000b2','someone-else@x.com',now()),
  ('7a000000-0000-0000-0000-0000000000b3','unverified@x.com',NULL),
  ('7a000000-0000-0000-0000-0000000000b4','friend@x.com',now()),
  ('7a000000-0000-0000-0000-0000000000b5','friends-other@x.com',now());
INSERT INTO public.exos_orgs(id,name,slug,owner_uid) VALUES
  ('7a000000-0000-0000-0000-000000000001','7A Org','7a-org','7a000000-0000-0000-0000-0000000000a0');
INSERT INTO public.exos_org_memberships(org_id,user_id,role) VALUES
  ('7a000000-0000-0000-0000-000000000001','7a000000-0000-0000-0000-0000000000a0','owner');
INSERT INTO public.exos_events(id,org_id,name,status,starts_at,venue_name,total_tickets,tickets_sold) VALUES
  ('7a000000-0000-0000-0000-0000000000e1','7a000000-0000-0000-0000-000000000001','Link Show','published','2027-01-01T02:00:00Z','Hall',100,0);
INSERT INTO public.exos_ticket_tiers(id,event_id,name,price,capacity,sold) VALUES
  ('7a000000-0000-0000-0000-0000000000d1','7a000000-0000-0000-0000-0000000000e1','GA',50,10,0);
INSERT INTO public.exos_distribution_listings(id,event_id,org_id,channel,status,tier_id,requested_qty,unit_price,external_listing_id) VALUES
  ('7a000000-0000-0000-0000-0000000000c1','7a000000-0000-0000-0000-0000000000e1','7a000000-0000-0000-0000-000000000001','stubhub','listed','7a000000-0000-0000-0000-0000000000d1',4,60,'7A-L-1');

SELECT public.exos_record_marketplace_order('{"channel":"stubhub","external_order_id":"7A-1","external_listing_id":"7A-L-1",
  "quantity":2,"sale_status":"confirmed","buyer_email":"x9f2k@relay.stubhub.example"}');
SELECT public.exos_fulfil_marketplace_order(id, 'https://exos.example.test') FROM public.exos_marketplace_orders WHERE external_order_id = '7A-1';

CREATE OR REPLACE FUNCTION pg_temp.as_user(p_uid text, p_email text) RETURNS void LANGUAGE sql AS $$
  SELECT set_config('app.uid', coalesce(p_uid, ''), true), set_config('app.jwt', json_build_object('email', p_email)::text, true);
$$;
CREATE OR REPLACE FUNCTION pg_temp.claim_fails(p_tr uuid) RETURNS boolean LANGUAGE plpgsql AS $$
BEGIN
  PERFORM public.exos_test_claim(p_tr);
  RETURN false;
EXCEPTION WHEN raise_exception OR insufficient_privilege THEN RETURN true;
END $$;

-- L1 ---------------------------------------------------------------------------
DO $$
DECLARE n int; m text;
BEGIN
  SELECT count(*) INTO n FROM public.exos_transfers
   WHERE event_id = '7a000000-0000-0000-0000-0000000000e1' AND status = 'pending'
     AND receiver_email = 'x9f2k@relay.stubhub.example';
  IF n <> 2 THEN RAISE EXCEPTION 'L1 FAIL: expected 2 pending transfers, got %', n; END IF;
  SELECT html INTO m FROM public.exos_mail WHERE to_email = 'x9f2k@relay.stubhub.example' AND template = 'transfer-initiated';
  IF m NOT LIKE '%any Exos account%' OR m LIKE '%Sign in with x9f2k%' OR m NOT LIKE '%/claim/%' THEN
    RAISE EXCEPTION 'L1 FAIL: mail text %', m;
  END IF;
  RAISE NOTICE 'L1 ok: marketplace mail says any Exos account';
END $$;

-- L2 ---------------------------------------------------------------------------
DO $$
DECLARE tr uuid; tk uuid; old_secret text; t record;
BEGIN
  SELECT id, ticket_id INTO tr, tk FROM public.exos_transfers
   WHERE event_id = '7a000000-0000-0000-0000-0000000000e1' AND status = 'pending' ORDER BY id LIMIT 1;
  SELECT barcode_secret INTO old_secret FROM public.exos_tickets WHERE id = tk;

  PERFORM pg_temp.as_user('7a000000-0000-0000-0000-0000000000b1', 'real-me@x.com');
  IF public.exos_test_claim(tr) <> tk THEN RAISE EXCEPTION 'L2 FAIL: wrong ticket id'; END IF;
  SELECT * INTO t FROM public.exos_tickets WHERE id = tk;
  IF t.owner_id <> '7a000000-0000-0000-0000-0000000000b1' OR t.buyer_id <> t.owner_id
     OR t.pending_transfer_id IS NOT NULL OR t.barcode_secret = old_secret
     OR lower(t.buyer_email) <> 'real-me@x.com' THEN
    RAISE EXCEPTION 'L2 FAIL: ticket after claim %', row_to_json(t);
  END IF;
  IF (SELECT status FROM public.exos_transfers WHERE id = tr) <> 'completed' THEN RAISE EXCEPTION 'L2 FAIL: transfer not completed'; END IF;

  PERFORM pg_temp.as_user('7a000000-0000-0000-0000-0000000000b2', 'someone-else@x.com');
  IF NOT pg_temp.claim_fails(tr) THEN RAISE EXCEPTION 'L2 FAIL: a claimed link was claimed again'; END IF;
  IF (SELECT owner_id FROM public.exos_tickets WHERE id = tk) <> '7a000000-0000-0000-0000-0000000000b1' THEN
    RAISE EXCEPTION 'L2 FAIL: first claimer lost the ticket';
  END IF;
  RAISE NOTICE 'L2 ok: claimed into an account with a different email; first claim wins';
END $$;

-- L3 ---------------------------------------------------------------------------
DO $$
DECLARE tr uuid;
BEGIN
  SELECT id INTO tr FROM public.exos_transfers
   WHERE event_id = '7a000000-0000-0000-0000-0000000000e1' AND status = 'pending' LIMIT 1;
  PERFORM pg_temp.as_user('7a000000-0000-0000-0000-0000000000b3', 'unverified@x.com');
  IF NOT pg_temp.claim_fails(tr) THEN RAISE EXCEPTION 'L3 FAIL: unverified account claimed'; END IF;
  PERFORM pg_temp.as_user('7a000000-0000-0000-0000-0000000000b3', 'x9f2k@relay.stubhub.example');
  IF NOT pg_temp.claim_fails(tr) THEN RAISE EXCEPTION 'L3 FAIL: unverified account claimed with the order email'; END IF;
  PERFORM pg_temp.as_user(NULL, NULL);
  IF NOT pg_temp.claim_fails(tr) THEN RAISE EXCEPTION 'L3 FAIL: anonymous claim'; END IF;
  IF (SELECT status FROM public.exos_transfers WHERE id = tr) <> 'pending' THEN RAISE EXCEPTION 'L3 FAIL: transfer moved'; END IF;
  RAISE NOTICE 'L3 ok: unverified / anonymous callers cannot claim';
END $$;

-- L4 ---------------------------------------------------------------------------
DO $$
DECLARE tk uuid; tr uuid;
BEGIN
  SELECT id INTO tk FROM public.exos_tickets WHERE owner_id = '7a000000-0000-0000-0000-0000000000b1';
  -- What exos_create_transfer writes: a friend transfer to friend@x.com.
  INSERT INTO public.exos_transfers (ticket_id, org_id, sender_id, receiver_email, status, event_id)
    VALUES (tk, '7a000000-0000-0000-0000-000000000001', '7a000000-0000-0000-0000-0000000000b1',
            'friend@x.com', 'pending', '7a000000-0000-0000-0000-0000000000e1')
    RETURNING id INTO tr;
  UPDATE public.exos_tickets SET pending_transfer_id = tr WHERE id = tk;
  -- The friend signs in with a different account of theirs.
  PERFORM pg_temp.as_user('7a000000-0000-0000-0000-0000000000b5', 'friends-other@x.com');
  PERFORM public.exos_test_claim(tr);
  IF (SELECT owner_id FROM public.exos_tickets WHERE id = tk) <> '7a000000-0000-0000-0000-0000000000b5' THEN
    RAISE EXCEPTION 'L4 FAIL: a different account could not claim a friend transfer';
  END IF;
  PERFORM pg_temp.as_user('7a000000-0000-0000-0000-0000000000b4', 'friend@x.com');
  IF NOT pg_temp.claim_fails(tr) THEN RAISE EXCEPTION 'L4 FAIL: the addressed email claimed after it was claimed'; END IF;
  RAISE NOTICE 'L4 ok: a friend transfer is claimed into any account; first claim wins';
END $$;

-- L5 ---------------------------------------------------------------------------
DO $$
DECLARE tr uuid; p jsonb;
BEGIN
  SELECT id INTO tr FROM public.exos_transfers
   WHERE event_id = '7a000000-0000-0000-0000-0000000000e1' AND status = 'pending' LIMIT 1;
  PERFORM pg_temp.as_user(NULL, NULL);
  SELECT to_jsonb(x) INTO p FROM public.exos_transfer_claim_preview(tr) x;
  IF p IS NULL OR p->>'status' <> 'pending' OR p->>'event_title' <> 'Link Show'
     OR p->>'tier_name' <> 'GA' OR p::text LIKE '%@%' OR p ? 'ticket_id' THEN
    RAISE EXCEPTION 'L5 FAIL: preview %', p;
  END IF;
  IF EXISTS (SELECT 1 FROM public.exos_transfer_claim_preview(gen_random_uuid())) THEN
    RAISE EXCEPTION 'L5 FAIL: preview for an unknown id';
  END IF;
  IF NOT has_function_privilege('anon', 'public.exos_transfer_claim_preview(uuid)', 'EXECUTE') THEN
    RAISE EXCEPTION 'L5 FAIL: anon cannot preview (claim page before sign-in)';
  END IF;
  RAISE NOTICE 'L5 ok: preview shows display fields, no emails';
END $$;

-- L6 ---------------------------------------------------------------------------
DO $$
DECLARE m text; n int;
BEGIN
  PERFORM pg_temp.as_user('7a000000-0000-0000-0000-0000000000a0', '7a-owner@x.com');
  PERFORM public.exos_issue_comp_batch('7a000000-0000-0000-0000-0000000000e1', '7a000000-0000-0000-0000-0000000000d1',
                                       ARRAY['guest-a@x.com','guest-b@x.com'], 2, NULL);
  PERFORM public.exos_issue_ticket_to_email('7a000000-0000-0000-0000-0000000000e1', '7a000000-0000-0000-0000-0000000000d1',
                                            'door@x.com', 1, NULL);
  FOR m, n IN
    SELECT ml.html, (SELECT count(*) FROM public.exos_transfers tr
                      WHERE tr.receiver_email = ml.to_email AND tr.status = 'pending'
                        AND ml.html LIKE '%href="{{app_url}}/claim/' || tr.id || '?k=' || public.exos_test_claim_key(tr.id) || '"%')
      FROM public.exos_mail ml
     WHERE ml.to_email IN ('guest-a@x.com','guest-b@x.com','door@x.com') AND ml.template = 'transfer-initiated'
  LOOP
    IF m NOT LIKE '%any Exos account%' OR m LIKE '%with this email address%' THEN RAISE EXCEPTION 'L6 FAIL: copy %', m; END IF;
    IF n <> (length(m) - length(replace(m, '/claim/', ''))) / 7 OR n = 0 THEN
      RAISE EXCEPTION 'L6 FAIL: links % vs own pending transfers in %', n, m;
    END IF;
  END LOOP;
  SELECT count(*) INTO n FROM public.exos_mail WHERE to_email IN ('guest-a@x.com','guest-b@x.com','door@x.com') AND template = 'transfer-initiated';
  IF n <> 3 THEN RAISE EXCEPTION 'L6 FAIL: expected 3 mails, got %', n; END IF;
  IF (SELECT html FROM public.exos_mail WHERE to_email = 'guest-a@x.com') NOT LIKE '%/claim/%/claim/%' THEN
    RAISE EXCEPTION 'L6 FAIL: 2 comps should carry 2 links';
  END IF;
  RAISE NOTICE 'L6 ok: box-office / comp mail says any account, links only to the recipient''s own tickets';
END $$;

-- L7 ---------------------------------------------------------------------------
DO $$
DECLARE tk uuid; tr uuid; tr2 uuid; m text; n int;
BEGIN
  SELECT id INTO tk FROM public.exos_tickets WHERE owner_id = '7a000000-0000-0000-0000-0000000000b5';
  PERFORM pg_temp.as_user('7a000000-0000-0000-0000-0000000000b5', 'friends-other@x.com');
  tr := public.exos_create_transfer(tk, '  Pal@X.com ', '  <b>Pal</b>   O''Neil ');
  SELECT html INTO m FROM public.exos_mail WHERE template = 'transfer-sent' AND to_email = 'friends-other@x.com';
  IF m IS NULL OR m NOT LIKE '%&lt;b&gt;Pal&lt;/b&gt; O''Neil%' OR m NOT LIKE '%(pal@x.com)%'
     OR m NOT LIKE '%href="{{app_url}}/claim/' || tr || '?k=' || public.exos_test_claim_key(tr) || '"%' OR m NOT LIKE '%Link Show%' OR m LIKE '%<b>Pal%' THEN
    RAISE EXCEPTION 'L7 FAIL: sent receipt %', m;
  END IF;
  IF (SELECT notify_sender AND receiver_name = '<b>Pal</b> O''Neil' FROM public.exos_transfers WHERE id = tr) IS NOT TRUE THEN
    RAISE EXCEPTION 'L7 FAIL: transfer row';
  END IF;

  -- someone-else claims it from their own account
  PERFORM pg_temp.as_user('7a000000-0000-0000-0000-0000000000b2', 'someone-else@x.com');
  PERFORM public.exos_test_claim(tr);
  SELECT html INTO m FROM public.exos_mail WHERE template = 'transfer-claimed' AND to_email = 'friends-other@x.com';
  IF m IS NULL OR m NOT LIKE '%accepted on%' OR m NOT LIKE '%<strong>someone-else@x.com</strong>%'
     OR m NOT LIKE '%sent to &lt;b&gt;Pal&lt;/b&gt; O''Neil (pal@x.com)%' OR m NOT LIKE '%' || tr || '%' THEN
    RAISE EXCEPTION 'L7 FAIL: accepted receipt %', m;
  END IF;

  -- a two-argument call (an older SPA) still works; the receipt has no name
  tr2 := public.exos_create_transfer(tk, 'next@x.com');
  SELECT html INTO m FROM public.exos_mail WHERE template = 'transfer-sent' AND to_email = 'someone-else@x.com';
  IF m IS NULL OR m NOT LIKE '%<strong>next@x.com</strong>%' THEN RAISE EXCEPTION 'L7 FAIL: 2-arg receipt %', m; END IF;

  -- the organizer isn't mailed per claimed marketplace / comp ticket
  SELECT count(*) INTO n FROM public.exos_mail WHERE template = 'transfer-claimed' AND to_email = '7a-owner@x.com';
  IF n <> 0 THEN RAISE EXCEPTION 'L7 FAIL: organizer got % claimed mails', n; END IF;
  RAISE NOTICE 'L7 ok: sender receipts on send (name + email) and on accept (who claimed it)';
END $$;

-- L8 ---------------------------------------------------------------------------
DO $$
DECLARE v_code text; r record;
BEGIN
  PERFORM pg_temp.as_user('7a000000-0000-0000-0000-0000000000a0', '7a-owner@x.com');
  v_code := public.exos_issue_voucher('7a000000-0000-0000-0000-0000000000e1', NULL, 'vip@x.com', false, NULL, 1, NULL, 'for vip');
  SELECT * INTO r FROM public.exos_check_voucher('7a000000-0000-0000-0000-0000000000e1', v_code, 'someone-else@x.com');
  IF NOT r.is_valid THEN RAISE EXCEPTION 'L8 FAIL: reserved code refused another email (%)', r.reason; END IF;
  IF NOT public.exos_consume_voucher(r.voucher_id) THEN RAISE EXCEPTION 'L8 FAIL: consume'; END IF;
  SELECT * INTO r FROM public.exos_check_voucher('7a000000-0000-0000-0000-0000000000e1', v_code, 'vip@x.com');
  IF r.is_valid OR r.reason <> 'already used' THEN RAISE EXCEPTION 'L8 FAIL: single-use code reused (%)', r.reason; END IF;
  IF position('reserved_email IS NULL' in pg_get_functiondef('public.exos_fulfill_checkout(text)'::regprocedure)) > 0 THEN
    RAISE EXCEPTION 'L8 FAIL: fulfillment still checks the reserved email';
  END IF;
  RAISE NOTICE 'L8 ok: reserved code, first redeemer wins; single use holds';
END $$;

ROLLBACK;
