-- ============================================================================
-- Marketplace tickets claimed by link (mig 20260927010000). Self-contained
-- (7a prefix), rolled back at the end.
--   L1 a fulfilled marketplace sale issues LINK transfers, and the mail says
--      any Exos account can claim (it doesn't name the order email)
--   L2 a verified account with a different email claims one; the ticket and
--      its rotated barcode are theirs; a second account can't claim it again
--   L3 an unverified account, or no account, can't claim a link transfer
--   L4 an Exos-to-Exos (email) transfer still needs the addressed email
--   L5 the preview shows a link transfer's display fields, no emails, and
--      nothing for an email transfer
--   psql -d <db> -v ON_ERROR_STOP=1 -f tests/exos/test_marketplace_link_claims.sql
-- ============================================================================
\set ON_ERROR_STOP on
BEGIN;
INSERT INTO auth.users(id,email,email_confirmed_at) VALUES
  ('7a000000-0000-0000-0000-0000000000a0','7a-owner@x.com',now()),
  ('7a000000-0000-0000-0000-0000000000b1','real-me@x.com',now()),
  ('7a000000-0000-0000-0000-0000000000b2','someone-else@x.com',now()),
  ('7a000000-0000-0000-0000-0000000000b3','unverified@x.com',NULL),
  ('7a000000-0000-0000-0000-0000000000b4','friend@x.com',now());
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
  PERFORM public.exos_claim_transfer(p_tr);
  RETURN false;
EXCEPTION WHEN raise_exception OR insufficient_privilege THEN RETURN true;
END $$;

-- L1 ---------------------------------------------------------------------------
DO $$
DECLARE n int; m text;
BEGIN
  SELECT count(*) INTO n FROM public.exos_transfers
   WHERE event_id = '7a000000-0000-0000-0000-0000000000e1' AND claim_mode = 'link' AND status = 'pending'
     AND receiver_email = 'x9f2k@relay.stubhub.example';
  IF n <> 2 THEN RAISE EXCEPTION 'L1 FAIL: expected 2 pending link transfers, got %', n; END IF;
  SELECT html INTO m FROM public.exos_mail WHERE to_email = 'x9f2k@relay.stubhub.example' AND template = 'transfer-initiated';
  IF m NOT LIKE '%any Exos account%' OR m LIKE '%Sign in with x9f2k%' OR m NOT LIKE '%/claim/%' THEN
    RAISE EXCEPTION 'L1 FAIL: mail text %', m;
  END IF;
  IF (SELECT count(*) FROM public.exos_transfers WHERE claim_mode IS DISTINCT FROM 'link' AND event_id = '7a000000-0000-0000-0000-0000000000e1') <> 0 THEN
    RAISE EXCEPTION 'L1 FAIL: a marketplace transfer defaulted to email mode';
  END IF;
  RAISE NOTICE 'L1 ok: marketplace sale issued as link transfers; mail says any Exos account';
END $$;

-- L2 ---------------------------------------------------------------------------
DO $$
DECLARE tr uuid; tk uuid; old_secret text; t record;
BEGIN
  SELECT id, ticket_id INTO tr, tk FROM public.exos_transfers
   WHERE event_id = '7a000000-0000-0000-0000-0000000000e1' AND status = 'pending' ORDER BY id LIMIT 1;
  SELECT barcode_secret INTO old_secret FROM public.exos_tickets WHERE id = tk;

  PERFORM pg_temp.as_user('7a000000-0000-0000-0000-0000000000b1', 'real-me@x.com');
  IF public.exos_claim_transfer(tr) <> tk THEN RAISE EXCEPTION 'L2 FAIL: wrong ticket id'; END IF;
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
  PERFORM pg_temp.as_user(NULL, NULL);
  IF NOT pg_temp.claim_fails(tr) THEN RAISE EXCEPTION 'L3 FAIL: anonymous claim'; END IF;
  IF (SELECT status FROM public.exos_transfers WHERE id = tr) <> 'pending' THEN RAISE EXCEPTION 'L3 FAIL: transfer moved'; END IF;
  RAISE NOTICE 'L3 ok: unverified / anonymous callers cannot claim a link';
END $$;

-- L4 ---------------------------------------------------------------------------
DO $$
DECLARE tk uuid; tr uuid;
BEGIN
  SELECT id INTO tk FROM public.exos_tickets WHERE owner_id = '7a000000-0000-0000-0000-0000000000b1';
  -- What exos_create_transfer writes, with claim_mode left NULL the way a
  -- jsonb_populate_record insert leaves it: NULL must behave as 'email'.
  INSERT INTO public.exos_transfers (ticket_id, org_id, sender_id, receiver_email, status, claim_mode, event_id)
    VALUES (tk, '7a000000-0000-0000-0000-000000000001', '7a000000-0000-0000-0000-0000000000b1',
            'friend@x.com', 'pending', NULL, '7a000000-0000-0000-0000-0000000000e1')
    RETURNING id INTO tr;
  UPDATE public.exos_tickets SET pending_transfer_id = tr WHERE id = tk;
  PERFORM pg_temp.as_user('7a000000-0000-0000-0000-0000000000b2', 'someone-else@x.com');
  IF NOT pg_temp.claim_fails(tr) THEN RAISE EXCEPTION 'L4 FAIL: wrong email claimed an email transfer'; END IF;
  PERFORM pg_temp.as_user('7a000000-0000-0000-0000-0000000000b4', 'friend@x.com');
  PERFORM public.exos_claim_transfer(tr);
  IF (SELECT owner_id FROM public.exos_tickets WHERE id = tk) <> '7a000000-0000-0000-0000-0000000000b4' THEN
    RAISE EXCEPTION 'L4 FAIL: addressed friend could not claim';
  END IF;
  RAISE NOTICE 'L4 ok: Exos-to-Exos transfers still need the addressed email';
END $$;

-- L5 ---------------------------------------------------------------------------
DO $$
DECLARE tr_link uuid; tr_mail uuid; p jsonb;
BEGIN
  SELECT id INTO tr_link FROM public.exos_transfers
   WHERE event_id = '7a000000-0000-0000-0000-0000000000e1' AND claim_mode = 'link' AND status = 'pending' LIMIT 1;
  SELECT id INTO tr_mail FROM public.exos_transfers
   WHERE event_id = '7a000000-0000-0000-0000-0000000000e1' AND claim_mode IS DISTINCT FROM 'link' LIMIT 1;
  PERFORM pg_temp.as_user(NULL, NULL);
  SELECT to_jsonb(x) INTO p FROM public.exos_transfer_claim_preview(tr_link) x;
  IF p IS NULL OR p->>'status' <> 'pending' OR p->>'claim_mode' <> 'link' OR p->>'event_title' <> 'Link Show'
     OR p->>'tier_name' <> 'GA' OR p::text LIKE '%@%' OR p ? 'ticket_id' THEN
    RAISE EXCEPTION 'L5 FAIL: preview %', p;
  END IF;
  IF EXISTS (SELECT 1 FROM public.exos_transfer_claim_preview(tr_mail)) THEN
    RAISE EXCEPTION 'L5 FAIL: preview exposed an email transfer';
  END IF;
  IF NOT has_function_privilege('anon', 'public.exos_transfer_claim_preview(uuid)', 'EXECUTE') THEN
    RAISE EXCEPTION 'L5 FAIL: anon cannot preview (claim page before sign-in)';
  END IF;
  RAISE NOTICE 'L5 ok: preview shows link transfers only, without emails';
END $$;

ROLLBACK;
