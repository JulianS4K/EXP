-- ============================================================================
-- Gaps integration (mig 20261102160000). Self-contained (9a… ids), rolled back.
--   G1 an unconfirmed account that shares a victim's email deletes itself:
--      none of the victim's email-keyed rows (transfer receiver_email, promoter
--      email, unclaimed org invite, pending and sent mail, waitlist row)
--      changes; the account's own uid-keyed rows still go
--   G2 a confirmed account deletes itself: its email-keyed rows are handled as
--      before (the fix doesn't switch the erasure off)
--   G3 both patches are in the function (this one and the orders branch's),
--      and a replay of the migration is a no-op
--   psql -d <db> -v ON_ERROR_STOP=1 -f tests/exos/test_gaps_integration.sql
-- ============================================================================
\set ON_ERROR_STOP on
BEGIN;

-- The test chain lacks some of prod's tables exos_delete_my_account touches:
-- minimal stand-ins (rolled back with everything else).
ALTER TABLE auth.users ADD COLUMN IF NOT EXISTS phone text, ADD COLUMN IF NOT EXISTS raw_user_meta_data jsonb,
  ADD COLUMN IF NOT EXISTS banned_until timestamptz, ADD COLUMN IF NOT EXISTS updated_at timestamptz;
CREATE TABLE IF NOT EXISTS auth.identities (user_id uuid);
CREATE TABLE IF NOT EXISTS auth.sessions (user_id uuid);
CREATE TABLE IF NOT EXISTS auth.refresh_tokens (user_id text);
CREATE TABLE IF NOT EXISTS public.exos_org_invites (org_id uuid, role text, email text, claimed_by uuid);
CREATE TABLE IF NOT EXISTS public.exos_org_follows (follower_uid uuid);
CREATE TABLE IF NOT EXISTS public.exos_event_saves (user_id uuid);
CREATE TABLE IF NOT EXISTS public.exos_notification_reads (uid uuid);
CREATE TABLE IF NOT EXISTS public.exos_profiles (id uuid);

-- o0 owns the org. x1 signed up with the victim's address and never confirmed
-- it (the victim, a guest, has no account). c1 is a confirmed account.
INSERT INTO auth.users (id, email, email_confirmed_at) VALUES
  ('9a000000-0000-0000-0000-0000000000a0', 'gx-owner@x.com', now()),
  ('9a000000-0000-0000-0000-0000000000b1', 'Victim@X.com', NULL),
  ('9a000000-0000-0000-0000-0000000000c1', 'gx-confirmed@x.com', now());
INSERT INTO public.exos_orgs (id, name, slug, owner_uid) VALUES
  ('9a000000-0000-0000-0000-000000000001', 'GX Org', 'gx-org', '9a000000-0000-0000-0000-0000000000a0');
INSERT INTO public.exos_events (id, org_id, name, slug, status, starts_at, timezone, total_tickets, created_by) VALUES
  ('9a000000-0000-0000-0000-0000000000e1', '9a000000-0000-0000-0000-000000000001', 'GX Show', 'gx-show', 'published',
   now() + interval '9 days', 'America/New_York', 100, '9a000000-0000-0000-0000-0000000000a0');
-- Fixture tickets (they only carry the transfers' foreign key) and a cart
-- hold: skip the insert triggers (presale, capacity, comps, hold caps) that
-- aren't under test.
SET LOCAL session_replication_role = replica;
INSERT INTO public.exos_tickets (id, event_id, org_id, buyer_id, owner_id, status, barcode_secret, price_paid, order_ref) VALUES
  ('9a000000-0000-0000-0000-000000000101', '9a000000-0000-0000-0000-0000000000e1', '9a000000-0000-0000-0000-000000000001',
   '9a000000-0000-0000-0000-0000000000a0', '9a000000-0000-0000-0000-0000000000a0', 'active', 's', 0, 'gx1'),
  ('9a000000-0000-0000-0000-000000000102', '9a000000-0000-0000-0000-0000000000e1', '9a000000-0000-0000-0000-000000000001',
   '9a000000-0000-0000-0000-0000000000a0', '9a000000-0000-0000-0000-0000000000a0', 'active', 's', 0, 'gx2');
-- The unconfirmed account's own cart hold (by uid; the tier is a stand-in).
INSERT INTO public.exos_cart_holds (event_id, tier_id, org_id, buyer_uid, quantity, expires_at) VALUES
  ('9a000000-0000-0000-0000-0000000000e1', '9a000000-0000-0000-0000-0000000000d1', '9a000000-0000-0000-0000-000000000001',
   '9a000000-0000-0000-0000-0000000000b1', 1, now() + interval '10 minutes');
SET LOCAL session_replication_role = origin;

-- The victim's email-keyed rows, and the same for the confirmed account.
INSERT INTO public.exos_transfers (id, ticket_id, org_id, sender_id, receiver_email, status) VALUES
  ('9a000000-0000-0000-0000-000000000201', '9a000000-0000-0000-0000-000000000101', '9a000000-0000-0000-0000-000000000001',
   '9a000000-0000-0000-0000-0000000000a0', 'victim@x.com', 'completed'),
  ('9a000000-0000-0000-0000-000000000202', '9a000000-0000-0000-0000-000000000102', '9a000000-0000-0000-0000-000000000001',
   '9a000000-0000-0000-0000-0000000000a0', 'gx-confirmed@x.com', 'completed');   -- claimed (status is pending / completed / cancelled)
INSERT INTO public.exos_promoters (id, org_id, code, name, email) VALUES
  ('9a000000-0000-0000-0000-000000000301', '9a000000-0000-0000-0000-000000000001', 'GXVIC', 'Victim', 'victim@x.com'),
  ('9a000000-0000-0000-0000-000000000302', '9a000000-0000-0000-0000-000000000001', 'GXCON', 'Confirmed', 'gx-confirmed@x.com');
INSERT INTO public.exos_org_invites (org_id, role, email, claimed_by) VALUES   -- org_id / role: phase-1's table where it exists
  ('9a000000-0000-0000-0000-000000000001', 'scanner', 'victim@x.com', NULL),
  ('9a000000-0000-0000-0000-000000000001', 'scanner', 'gx-confirmed@x.com', NULL);
INSERT INTO public.exos_mail (id, to_email, template, subject, html, status) VALUES
  ('9a000000-0000-0000-0000-000000000401', 'victim@x.com', 'event-reminder', 's', 'h', 'pending'),
  ('9a000000-0000-0000-0000-000000000402', 'victim@x.com', 'event-reminder', 's', 'h', 'sent'),
  ('9a000000-0000-0000-0000-000000000403', 'gx-confirmed@x.com', 'event-reminder', 's', 'h', 'pending'),
  ('9a000000-0000-0000-0000-000000000404', 'gx-confirmed@x.com', 'event-reminder', 's', 'h', 'sent');
INSERT INTO public.exos_waitlist (id, event_id, user_id, email, status) VALUES
  ('9a000000-0000-0000-0000-000000000501', '9a000000-0000-0000-0000-0000000000e1', NULL, 'victim@x.com', 'waiting'),
  ('9a000000-0000-0000-0000-000000000502', '9a000000-0000-0000-0000-0000000000e1', '9a000000-0000-0000-0000-0000000000b1', 'other-1@x.com', 'waiting'),
  ('9a000000-0000-0000-0000-000000000503', '9a000000-0000-0000-0000-0000000000e1', NULL, 'gx-confirmed@x.com', 'waiting');
-- G1 --------------------------------------------------------------------------
DO $$
DECLARE v_tomb text := 'deleted+9a000000-0000-0000-0000-0000000000b1@deleted.invalid';
BEGIN
  PERFORM set_config('app.uid', '9a000000-0000-0000-0000-0000000000b1', true);
  PERFORM public.exos_delete_my_account();
  PERFORM set_config('app.uid', '', true);

  IF (SELECT receiver_email FROM public.exos_transfers WHERE id = '9a000000-0000-0000-0000-000000000201') IS DISTINCT FROM 'victim@x.com' THEN
    RAISE EXCEPTION 'G1 FAIL: an unconfirmed account rewrote the victim''s transfer';
  END IF;
  IF (SELECT email FROM public.exos_promoters WHERE id = '9a000000-0000-0000-0000-000000000301') IS DISTINCT FROM 'victim@x.com' THEN
    RAISE EXCEPTION 'G1 FAIL: an unconfirmed account cleared the victim''s promoter email';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.exos_org_invites WHERE email = 'victim@x.com') THEN
    RAISE EXCEPTION 'G1 FAIL: an unconfirmed account deleted the victim''s org invite';
  END IF;
  IF (SELECT count(*) FROM public.exos_mail WHERE to_email = 'victim@x.com'
         AND id IN ('9a000000-0000-0000-0000-000000000401', '9a000000-0000-0000-0000-000000000402')) <> 2 THEN
    RAISE EXCEPTION 'G1 FAIL: an unconfirmed account deleted or tombstoned the victim''s mail';
  END IF;
  IF EXISTS (SELECT 1 FROM public.exos_mail WHERE to_email = v_tomb) THEN
    RAISE EXCEPTION 'G1 FAIL: mail tombstoned for an unconfirmed address';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.exos_waitlist WHERE id = '9a000000-0000-0000-0000-000000000501') THEN
    RAISE EXCEPTION 'G1 FAIL: an unconfirmed account deleted the victim''s waitlist row';
  END IF;
  -- The account's own rows (by uid) still go, and the login is closed.
  IF EXISTS (SELECT 1 FROM public.exos_waitlist WHERE id = '9a000000-0000-0000-0000-000000000502') THEN
    RAISE EXCEPTION 'G1 FAIL: the account''s own waitlist row (by uid) survived';
  END IF;
  IF EXISTS (SELECT 1 FROM public.exos_cart_holds WHERE buyer_uid = '9a000000-0000-0000-0000-0000000000b1') THEN
    RAISE EXCEPTION 'G1 FAIL: the account''s own cart hold (by uid) survived';
  END IF;
  IF (SELECT email FROM auth.users WHERE id = '9a000000-0000-0000-0000-0000000000b1') IS DISTINCT FROM v_tomb THEN
    RAISE EXCEPTION 'G1 FAIL: the login was not tombstoned';
  END IF;
  RAISE NOTICE 'OK G1 unconfirmed email: none of the victim''s email-keyed rows changed; uid-keyed rows and the login still go';
END $$;

-- G2 --------------------------------------------------------------------------
DO $$
DECLARE v_tomb text := 'deleted+9a000000-0000-0000-0000-0000000000c1@deleted.invalid';
BEGIN
  PERFORM set_config('app.uid', '9a000000-0000-0000-0000-0000000000c1', true);
  PERFORM public.exos_delete_my_account();
  PERFORM set_config('app.uid', '', true);
  IF (SELECT receiver_email FROM public.exos_transfers WHERE id = '9a000000-0000-0000-0000-000000000202') IS DISTINCT FROM v_tomb
     OR (SELECT email FROM public.exos_promoters WHERE id = '9a000000-0000-0000-0000-000000000302') IS NOT NULL
     OR EXISTS (SELECT 1 FROM public.exos_org_invites WHERE email = 'gx-confirmed@x.com')
     OR EXISTS (SELECT 1 FROM public.exos_mail WHERE id = '9a000000-0000-0000-0000-000000000403')
     OR (SELECT to_email FROM public.exos_mail WHERE id = '9a000000-0000-0000-0000-000000000404') IS DISTINCT FROM v_tomb
     OR EXISTS (SELECT 1 FROM public.exos_waitlist WHERE id = '9a000000-0000-0000-0000-000000000503') THEN
    RAISE EXCEPTION 'G2 FAIL: a confirmed account''s email-keyed rows were not erased';
  END IF;
  -- And still none of the victim's.
  IF (SELECT receiver_email FROM public.exos_transfers WHERE id = '9a000000-0000-0000-0000-000000000201') IS DISTINCT FROM 'victim@x.com'
     OR NOT EXISTS (SELECT 1 FROM public.exos_waitlist WHERE id = '9a000000-0000-0000-0000-000000000501') THEN
    RAISE EXCEPTION 'G2 FAIL: the victim''s rows changed';
  END IF;
  RAISE NOTICE 'OK G2 confirmed email: transfers, promoter, invite, mail and waitlist handled as before';
END $$;

-- G3 --------------------------------------------------------------------------
DO $$
DECLARE v_def text := pg_get_functiondef('public.exos_delete_my_account()'::regprocedure);
BEGIN
  IF position('/* exos: confirmed email only */' IN v_def) = 0 THEN RAISE EXCEPTION 'G3 FAIL: confirmed-email patch missing'; END IF;
  IF position('exos_order_details' IN v_def) = 0 THEN RAISE EXCEPTION 'G3 FAIL: the orders branch''s patch was lost'; END IF;
  IF position('WHERE u.id = v_uid;' IN v_def) > 0 THEN RAISE EXCEPTION 'G3 FAIL: an unchecked email read is left'; END IF;
  IF has_function_privilege('anon', 'public.exos_delete_my_account()', 'EXECUTE') THEN
    RAISE EXCEPTION 'G3 FAIL: anon can call it';
  END IF;
  IF NOT has_function_privilege('authenticated', 'public.exos_delete_my_account()', 'EXECUTE') THEN
    RAISE EXCEPTION 'G3 FAIL: authenticated lost EXECUTE';
  END IF;
  RAISE NOTICE 'OK G3 both patches present; grants kept';
END $$;

ROLLBACK;
