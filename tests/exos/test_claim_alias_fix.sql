-- ============================================================================
-- Transfer claims through prod's body (mig 20261108130000). Prod's
-- exos_claim_transfer(uuid) is 20260924200848's, which declares a row variable
-- `t`; 20261105100000's proof check aliased exos_tickets as `t` too, so every
-- claim raised 'column reference "t.order_ref" is ambiguous'. run_p0.sh builds
-- that body since it applies every *exos* migration; this file claims through
-- it. Self-contained ids ca…, rolled back.
-- ============================================================================
\set ON_ERROR_STOP on
BEGIN;

CREATE FUNCTION pg_temp.u(p text) RETURNS uuid LANGUAGE sql IMMUTABLE AS $$
  SELECT ('ca000000-0000-0000-0000-' || lpad(p, 12, '0'))::uuid $$;
CREATE FUNCTION pg_temp.act(p_uid uuid) RETURNS void LANGUAGE sql AS $$
  SELECT set_config('app.uid', coalesce(p_uid::text, ''), true),
         set_config('app.jwt', coalesce((SELECT jsonb_build_object('email', email)::text FROM auth.users WHERE id = p_uid), ''), true) $$;
CREATE FUNCTION pg_temp.err(p_sql text) RETURNS text LANGUAGE plpgsql AS $$
BEGIN
  EXECUTE p_sql;
  RETURN 'ok';
EXCEPTION WHEN OTHERS THEN
  RETURN SQLSTATE || ' ' || SQLERRM;
END $$;
CREATE FUNCTION pg_temp.def() RETURNS text LANGUAGE sql AS $$
  SELECT replace(pg_get_functiondef('public.exos_claim_transfer(uuid)'::regprocedure), chr(13), '') $$;

INSERT INTO auth.users (id, email, email_confirmed_at) VALUES
  (pg_temp.u('a0'), 'ca-owner@x.com', now()),
  (pg_temp.u('b1'), 'ca-sender@x.com', now()),
  (pg_temp.u('b2'), 'ca-friend@x.com', now());
INSERT INTO public.exos_orgs (id, name, slug, owner_uid) VALUES (pg_temp.u('1'), 'CA Org', 'ca-org', pg_temp.u('a0'));
INSERT INTO public.exos_org_memberships (org_id, user_id, role) VALUES (pg_temp.u('1'), pg_temp.u('a0'), 'owner');
INSERT INTO public.exos_events (id, org_id, name, status, starts_at) VALUES
  (pg_temp.u('e1'), pg_temp.u('1'), 'CA Night', 'published', now() + interval '7 days');
INSERT INTO public.exos_ticket_tiers (id, event_id, name, price, capacity) VALUES
  (pg_temp.u('d1'), pg_temp.u('e1'), 'GA', 20, 100);
INSERT INTO public.exos_checkout_sessions (session_id, event_id, tier_id, org_id, buyer_uid, buyer_email, quantity, amount_cents, status) VALUES
  ('cs_ca1', pg_temp.u('e1'), pg_temp.u('d1'), pg_temp.u('1'), pg_temp.u('b1'), 'ca-sender@x.com', 2, 4000, 'fulfilled');
INSERT INTO public.exos_tickets (id, event_id, org_id, tier_id, tier_name, buyer_id, owner_id, buyer_email, status, barcode_secret, price_paid, order_ref) VALUES
  (pg_temp.u('c1'), pg_temp.u('e1'), pg_temp.u('1'), pg_temp.u('d1'), 'GA', pg_temp.u('b1'), pg_temp.u('b1'), 'ca-sender@x.com', 'active', 'ca-s1', 20, 'cs_ca1'),
  (pg_temp.u('c2'), pg_temp.u('e1'), pg_temp.u('1'), pg_temp.u('d1'), 'GA', pg_temp.u('b1'), pg_temp.u('b1'), 'ca-sender@x.com', 'active', 'ca-s2', 20, 'cs_ca1');
INSERT INTO public.exos_transfers (id, ticket_id, org_id, sender_id, receiver_email, status) VALUES
  (pg_temp.u('f1'), pg_temp.u('c1'), pg_temp.u('1'), pg_temp.u('b1'), 'ca-friend@x.com', 'pending'),
  (pg_temp.u('f2'), pg_temp.u('c2'), pg_temp.u('1'), pg_temp.u('b1'), 'ca-friend@x.com', 'pending');
UPDATE public.exos_tickets SET pending_transfer_id = ('ca000000-0000-0000-0000-0000000000f' || right(id::text, 1))::uuid
 WHERE id IN (pg_temp.u('c1'), pg_temp.u('c2'));

-- CA1: the body is prod's shape, and fixed.
DO $$
DECLARE d text := pg_temp.def();
BEGIN
  ASSERT d ~ '\n\s+t\s+public\.exos_tickets%ROWTYPE;', 'CA1: prod-like body (20260924200848) declares the row variable t';
  ASSERT position('/* exos: proof before claim */' in d) > 0, 'CA1: the proof check (20261105100000) is there';
  ASSERT position('/* exos: claim proof alias */' in d) > 0, 'CA1: marker';
  ASSERT position('exos_tickets t JOIN public.exos_order_proofs' in d) = 0, 'CA1: no ambiguous alias left';
  ASSERT (length(d) - length(replace(d, 'exos_tickets tk JOIN public.exos_order_proofs', '')))
         / length('exos_tickets tk JOIN public.exos_order_proofs') = 1, 'CA1: renamed exactly once';
  RAISE NOTICE 'OK  CA1 exos_claim_transfer(uuid) is prod''s body with the alias renamed once';
END $$;

-- CA2: a claim works (this raised "t.order_ref is ambiguous" before the fix).
DO $$
DECLARE r uuid; e text;
BEGIN
  PERFORM pg_temp.act(pg_temp.u('b2'));
  r := public.exos_test_claim(pg_temp.u('f1'));
  ASSERT r IS NOT NULL, 'CA2: claim returns the ticket';
  ASSERT (SELECT owner_id = pg_temp.u('b2') AND buyer_id = pg_temp.u('b2') AND status = 'active' AND pending_transfer_id IS NULL
            FROM public.exos_tickets WHERE id = pg_temp.u('c1')), 'CA2: ticket moved to the claimer';
  ASSERT (SELECT status FROM public.exos_transfers WHERE id = pg_temp.u('f1')) = 'completed', 'CA2: transfer completed';
  PERFORM pg_temp.act(NULL);
  RAISE NOTICE 'OK  CA2 a transfer claims through the prod-like body';
END $$;

-- CA3: the proof check itself still works under the new alias.
INSERT INTO public.exos_order_proofs (org_id, event_id, session_id, email, original_email, status, expires_at) VALUES
  (pg_temp.u('1'), pg_temp.u('e1'), 'cs_ca1', 'ca-sender@x.com', 'ca-sender@x.com', 'pending', now() + interval '7 days');
DO $$
DECLARE e text;
BEGIN
  PERFORM pg_temp.act(pg_temp.u('b2'));
  e := pg_temp.err(format('SELECT public.exos_test_claim(%L::uuid)', pg_temp.u('f2')));
  ASSERT e LIKE '42501%waiting for the buyer to confirm%', 'CA3: no claim before proof: ' || e;
  PERFORM pg_temp.act(NULL);
  UPDATE public.exos_order_proofs SET status = 'proven', proven_via = 'organizer', proven_at = now() WHERE session_id = 'cs_ca1';
  PERFORM pg_temp.act(pg_temp.u('b2'));
  ASSERT public.exos_test_claim(pg_temp.u('f2')) IS NOT NULL, 'CA3: claim once proven';
  PERFORM pg_temp.act(NULL);
  RAISE NOTICE 'OK  CA3 a pending proof still blocks the claim; a proven one lets it through';
END $$;

-- CA4: re-run safe, and a no-op where the ambiguous text isn't there.
CREATE TEMP TABLE ca_def AS SELECT pg_temp.def() AS d;
\set QUIET on
SET client_min_messages = warning;
\ir ../../supabase/migrations/20261108130000_exos_claim_alias_fix.sql
RESET client_min_messages;
DO $$
BEGIN
  ASSERT pg_temp.def() = (SELECT d FROM ca_def), 'CA4: replay is a no-op';
END $$;
-- A body without the proof block (as before 20261105100000): skipped, unchanged.
DO $$
DECLARE d text := pg_temp.def();
BEGIN
  d := replace(d, '/* exos: claim proof alias */', '/* (test) */');
  d := regexp_replace(d, '\n  /\* \(test\) \*/[^\n]*\n  IF EXISTS \(SELECT 1 FROM public\.exos_tickets tk[^\n]*\n[^\n]*\n[^\n]*\n[^\n]*\n  END IF;', '');
  ASSERT position('exos_order_proofs' in d) = 0, 'CA4: test body has no proof block';
  EXECUTE d;
  TRUNCATE ca_def;
  INSERT INTO ca_def SELECT pg_temp.def();
END $$;
SET client_min_messages = warning;
\ir ../../supabase/migrations/20261108130000_exos_claim_alias_fix.sql
RESET client_min_messages;
\set QUIET off
DO $$
BEGIN
  ASSERT pg_temp.def() = (SELECT d FROM ca_def), 'CA4: no ambiguous block, nothing patched';
  RAISE NOTICE 'OK  CA4 the fix is replay safe and skips a body without the ambiguous block';
END $$;

ROLLBACK;
