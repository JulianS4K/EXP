-- ============================================================================
-- Parked ticket guard (mig 20261020100000):
--   G1 a manager issues to an email with no account (issue-to-email + comp
--      batch): the tickets are parked on them, held, and the roster says parked
--   G2 the manager is disabled: cancelling the guest's claim, re-sending the
--      ticket to themselves, the claim key, the barcode secret, attendee name,
--      access needs, wallet pass, release, online access and account deletion
--      are all refused; the ticket and the claim are untouched
--   G3 the door still sees the parked tickets and checks one in by name
--   G4 an active manager cancels the claim (the ex-manager still can't touch
--      it) and re-sends it: re-parked on them, parked again; the guest claims
--   G5 the ex-manager hard-removed: still refused; staff still cancel
--   G6 a plain holder's own transfer, name and secret work as before
-- Self-contained (BEGIN / ROLLBACK).
-- ============================================================================
\set ON_ERROR_STOP on
BEGIN;

-- The p0 chain has no exos_profiles (phase 1); the roster LEFT JOINs it.
CREATE TABLE IF NOT EXISTS public.exos_profiles (
  id uuid PRIMARY KEY, display_name text, updated_at timestamptz NOT NULL DEFAULT now());

INSERT INTO auth.users(id,email,email_confirmed_at) VALUES
  ('a9200000-0000-0000-0000-0000000000a1','pkown@x.test',now()),
  ('a9200000-0000-0000-0000-0000000000a2','pkmgr@x.test',now()),
  ('a9200000-0000-0000-0000-0000000000a3','pkmgr2@x.test',now()),
  ('a9200000-0000-0000-0000-0000000000a5','pkhold@x.test',now());
INSERT INTO public.exos_orgs(id,name,slug,owner_uid) VALUES
  ('a9200000-0000-0000-0000-000000000001','Parked Org','parked-org-stub','a9200000-0000-0000-0000-0000000000a1');
INSERT INTO public.exos_org_memberships(org_id,user_id,role) VALUES
  ('a9200000-0000-0000-0000-000000000001','a9200000-0000-0000-0000-0000000000a1','owner'),
  ('a9200000-0000-0000-0000-000000000001','a9200000-0000-0000-0000-0000000000a2','manager'),
  ('a9200000-0000-0000-0000-000000000001','a9200000-0000-0000-0000-0000000000a3','manager');
INSERT INTO public.exos_events(id,org_id,name,slug,status,starts_at,doors_at,timezone,total_tickets,tickets_sold,created_by) VALUES
  ('a9200000-0000-0000-0000-0000000000e1','a9200000-0000-0000-0000-000000000001','Gala','parked-gala-stub','published',
   now() + interval '1 hour', now() - interval '1 hour', 'UTC', 100, 0, 'a9200000-0000-0000-0000-0000000000a1');
INSERT INTO public.exos_ticket_tiers(id,event_id,name,price,capacity,sold) VALUES
  ('a9200000-0000-0000-0000-0000000000d1','a9200000-0000-0000-0000-0000000000e1','VIP',200,100,0);
-- A plain holder's own ticket (G6).
INSERT INTO public.exos_tickets(id,event_id,org_id,tier_name,buyer_id,owner_id,buyer_email,status,barcode_secret,price_paid,order_ref,channel_source)
VALUES ('a9200000-0000-0000-0000-00000000c005','a9200000-0000-0000-0000-0000000000e1','a9200000-0000-0000-0000-000000000001','VIP',
        'a9200000-0000-0000-0000-0000000000a5','a9200000-0000-0000-0000-0000000000a5','pkhold@x.test','active','sek-pk5',0,'web-pk5','stripe');

CREATE FUNCTION pg_temp.act(p_uid text, p_email text) RETURNS void LANGUAGE sql AS $$
  SELECT set_config('app.uid', p_uid, false),
         set_config('app.jwt', json_build_object('email', p_email, 'role', 'authenticated')::text, false);
$$;
-- The SQLSTATE a statement fails with ('ok' when it doesn't).
CREATE FUNCTION pg_temp.try(p_sql text) RETURNS text LANGUAGE plpgsql AS $$
BEGIN EXECUTE p_sql; RETURN 'ok'; EXCEPTION WHEN others THEN RETURN SQLSTATE || ' ' || SQLERRM; END $$;
CREATE TEMP TABLE pk(k text PRIMARY KEY, id uuid);

-- G1. The manager issues: one to an email (exos_issue_ticket_to_email), one
--     comp batch, one more to a second guest (G5).
SELECT pg_temp.act('a9200000-0000-0000-0000-0000000000a2', 'pkmgr@x.test');
INSERT INTO pk SELECT 'tk', (public.exos_issue_ticket_to_email('a9200000-0000-0000-0000-0000000000e1',
  'a9200000-0000-0000-0000-0000000000d1', 'VIPGuest@else.test', 1))[1];
INSERT INTO pk SELECT 'tk2', b.ticket_ids[1] FROM public.exos_issue_comp_batch('a9200000-0000-0000-0000-0000000000e1',
  'a9200000-0000-0000-0000-0000000000d1', ARRAY['comp.guest@else.test']) b;
INSERT INTO pk SELECT 'tk3', (public.exos_issue_ticket_to_email('a9200000-0000-0000-0000-0000000000e1',
  'a9200000-0000-0000-0000-0000000000d1', 'third@else.test', 1))[1];
INSERT INTO pk SELECT 'tr', pending_transfer_id FROM public.exos_tickets WHERE id = (SELECT id FROM pk WHERE k = 'tk');
INSERT INTO pk SELECT 'tr3', pending_transfer_id FROM public.exos_tickets WHERE id = (SELECT id FROM pk WHERE k = 'tk3');

DO $$
DECLARE t public.exos_tickets; tr public.exos_transfers;
BEGIN
  SELECT * INTO t FROM public.exos_tickets WHERE id = (SELECT id FROM pk WHERE k = 'tk');
  SELECT * INTO tr FROM public.exos_transfers WHERE id = t.pending_transfer_id;
  ASSERT t.owner_id = 'a9200000-0000-0000-0000-0000000000a2' AND t.buyer_id = t.owner_id AND tr.status = 'pending',
         'G1 parked on the issuing manager: ' || row_to_json(t)::text;
  ASSERT public._exos_ticket_held(t.id) AND public._exos_ticket_parked(t, tr), 'G1 held + parked';
  ASSERT public._exos_ticket_held((SELECT id FROM pk WHERE k = 'tk2')), 'G1 comp batch held';
  ASSERT NOT public._exos_ticket_held('a9200000-0000-0000-0000-00000000c005'), 'G1 plain ticket not held';
  -- Even while active, the parker's holder path doesn't get the guest's secret.
  ASSERT NOT public.exos_can_read_ticket_secret(t.id), 'G1 parker reads no secret';
  ASSERT NOT has_function_privilege('authenticated', 'public._exos_ticket_held(uuid)', 'EXECUTE')
     AND NOT has_function_privilege('authenticated', 'public._exos_parked_ok(uuid)', 'EXECUTE')
     AND NOT has_function_privilege('authenticated', 'public._exos_parked_guard(uuid, text)', 'EXECUTE'), 'G1 helpers internal';
  ASSERT has_function_privilege('authenticated', 'public.exos_cancel_transfer(uuid)', 'EXECUTE')
     AND NOT has_function_privilege('anon', 'public.exos_cancel_transfer(uuid)', 'EXECUTE'), 'G1 cancel grants';
  RAISE NOTICE 'OK  G1 issued tickets are parked on the manager and held';
END $$;

-- G2. The owner disables the manager (the UI's "remove").
UPDATE public.exos_org_memberships SET disabled = true
 WHERE org_id = 'a9200000-0000-0000-0000-000000000001' AND user_id = 'a9200000-0000-0000-0000-0000000000a2';
SELECT pg_temp.act('a9200000-0000-0000-0000-0000000000a2', 'pkmgr@x.test');
DO $$
DECLARE
  tk uuid := (SELECT id FROM pk WHERE k = 'tk');
  tr uuid := (SELECT id FROM pk WHERE k = 'tr');
  r text;
BEGIN
  r := pg_temp.try(format('SELECT public.exos_cancel_transfer(%L)', tr));
  ASSERT r LIKE '42501%', 'G2 ex-manager cancels the guest''s claim: ' || r;
  r := pg_temp.try(format('SELECT public.exos_create_transfer(%L, %L)', tk, 'alt@mine.test'));
  ASSERT r <> 'ok', 'G2 ex-manager re-sends it: ' || r;
  ASSERT public.exos_transfer_claim_key(tr) IS NULL, 'G2 no claim key for the ex-manager';
  ASSERT NOT public.exos_can_read_ticket_secret(tk), 'G2 no barcode secret';
  r := pg_temp.try(format('SELECT public.exos_set_ticket_attendee(%L, %L)', tk, 'Me'));
  ASSERT r <> 'ok', 'G2 attendee name: ' || r;
  r := pg_temp.try(format('SELECT public.exos_set_ticket_access_needs(%L, %L::text[])', tk, '{}'));
  ASSERT r LIKE '42501%', 'G2 access needs: ' || r;
  r := pg_temp.try(format('SELECT public.exos_wallet_issue_pass(%L, %L)', tk, 'google'));
  ASSERT r LIKE '42501%', 'G2 wallet pass: ' || r;
  r := pg_temp.try(format('SELECT public.exos_wallet_reissue(%L)', tk));
  ASSERT r LIKE '42501%', 'G2 wallet reissue: ' || r;
  r := pg_temp.try(format('SELECT public.exos_release_ticket(%L)', tk));
  ASSERT r <> 'ok', 'G2 release: ' || r;
  ASSERT (SELECT state FROM public.exos_event_online_access('a9200000-0000-0000-0000-0000000000e1')) = 'not_holder',
         'G2 online access: not a holder';
  r := pg_temp.try('SELECT public.exos_delete_my_account()');
  ASSERT r <> 'ok', 'G2 account deletion: ' || r;
  ASSERT (SELECT owner_id = 'a9200000-0000-0000-0000-0000000000a2' AND pending_transfer_id = tr AND status = 'active'
                 AND buyer_email = 'vipguest@else.test'
            FROM public.exos_tickets WHERE id = tk), 'G2 ticket untouched';
  ASSERT (SELECT status FROM public.exos_transfers WHERE id = tr) = 'pending', 'G2 claim untouched';
  RAISE NOTICE 'OK  G2 the disabled ex-manager is refused end to end';
END $$;

-- G3. The door (the org owner) sees the parked tickets and checks one in by name.
SELECT pg_temp.act('a9200000-0000-0000-0000-0000000000a1', 'pkown@x.test');
DO $$
DECLARE r record; j jsonb;
BEGIN
  SELECT * INTO r FROM public.exos_event_door_roster('a9200000-0000-0000-0000-0000000000e1')
   WHERE ticket_id = (SELECT id FROM pk WHERE k = 'tk');
  ASSERT r.parked AND r.claim_email_masked IS NOT NULL, 'G3 roster: parked ' || row_to_json(r)::text;
  SELECT * INTO r FROM public.exos_event_door_roster('a9200000-0000-0000-0000-0000000000e1')
   WHERE ticket_id = (SELECT id FROM pk WHERE k = 'tk2');
  ASSERT r.parked, 'G3 roster: comp parked ' || row_to_json(r)::text;
  j := public.exos_door_checkin_by_name((SELECT id FROM pk WHERE k = 'tk2'), 'a9200000-0000-0000-0000-0000000000e1', NULL, 'Door 1');
  ASSERT (j ->> 'ok')::boolean, 'G3 by-name check-in of a parked comp: ' || j::text;
  ASSERT (SELECT status FROM public.exos_tickets WHERE id = (SELECT id FROM pk WHERE k = 'tk2')) = 'used', 'G3 used';
  RAISE NOTICE 'OK  G3 the door sees parked tickets and checks them in by name';
END $$;

-- G4. An active manager cancels the claim, then re-sends it; the guest claims.
SELECT pg_temp.act('a9200000-0000-0000-0000-0000000000a3', 'pkmgr2@x.test');
SELECT public.exos_cancel_transfer((SELECT id FROM pk WHERE k = 'tr'));
DO $$
DECLARE tk uuid := (SELECT id FROM pk WHERE k = 'tk'); r text;
BEGIN
  ASSERT (SELECT status FROM public.exos_transfers WHERE id = (SELECT id FROM pk WHERE k = 'tr')) = 'cancelled', 'G4 cancelled';
  ASSERT (SELECT pending_transfer_id IS NULL FROM public.exos_tickets WHERE id = tk), 'G4 lock cleared';
  ASSERT public._exos_ticket_held(tk), 'G4 still held after the cancel';
  -- The ex-manager still can't take it.
  PERFORM pg_temp.act('a9200000-0000-0000-0000-0000000000a2', 'pkmgr@x.test');
  r := pg_temp.try(format('SELECT public.exos_create_transfer(%L, %L)', tk, 'alt@mine.test'));
  ASSERT r LIKE '42501%', 'G4 ex-manager sends the cancelled claim''s ticket: ' || r;
  r := pg_temp.try(format('SELECT public.exos_set_ticket_attendee(%L, %L)', tk, 'Me'));
  ASSERT r LIKE '42501%', 'G4 ex-manager names it: ' || r;
  r := pg_temp.try(format('SELECT public.exos_wallet_issue_pass(%L, %L)', tk, 'google'));
  ASSERT r LIKE '42501%', 'G4 ex-manager wallet: ' || r;
  ASSERT NOT public.exos_can_read_ticket_secret(tk), 'G4 ex-manager secret';
  PERFORM pg_temp.act('a9200000-0000-0000-0000-0000000000a3', 'pkmgr2@x.test');
END $$;
INSERT INTO pk SELECT 'tr4', public.exos_create_transfer((SELECT id FROM pk WHERE k = 'tk'), 'VIPGuest@else.test');
DO $$
DECLARE t public.exos_tickets; tr public.exos_transfers; r record;
BEGIN
  SELECT * INTO t FROM public.exos_tickets WHERE id = (SELECT id FROM pk WHERE k = 'tk');
  SELECT * INTO tr FROM public.exos_transfers WHERE id = t.pending_transfer_id;
  ASSERT t.owner_id = 'a9200000-0000-0000-0000-0000000000a3' AND t.buyer_id = t.owner_id
     AND tr.id = (SELECT id FROM pk WHERE k = 'tr4') AND tr.sender_id = t.owner_id,
         'G4 re-parked on the active manager: ' || row_to_json(t)::text;
  ASSERT public._exos_ticket_parked(t, tr), 'G4 parked again';
  PERFORM pg_temp.act('a9200000-0000-0000-0000-0000000000a1', 'pkown@x.test');
  SELECT * INTO r FROM public.exos_event_door_roster('a9200000-0000-0000-0000-0000000000e1') WHERE ticket_id = t.id;
  ASSERT r.parked, 'G4 roster: parked again ' || row_to_json(r)::text;
END $$;
-- The guest signs up and claims with the link.
INSERT INTO auth.users(id,email,email_confirmed_at) VALUES ('a9200000-0000-0000-0000-0000000000a4','vipguest@else.test',now());
SELECT pg_temp.act('a9200000-0000-0000-0000-0000000000a4', 'vipguest@else.test');
SELECT public.exos_test_claim((SELECT id FROM pk WHERE k = 'tr4'));
DO $$
DECLARE tk uuid := (SELECT id FROM pk WHERE k = 'tk');
BEGIN
  ASSERT (SELECT owner_id = 'a9200000-0000-0000-0000-0000000000a4' AND pending_transfer_id IS NULL
            FROM public.exos_tickets WHERE id = tk), 'G4 the guest holds it';
  ASSERT NOT public._exos_ticket_held(tk), 'G4 claimed: not held';
  ASSERT public.exos_can_read_ticket_secret(tk), 'G4 the guest reads their secret';
  ASSERT public.exos_set_ticket_attendee(tk, 'Vip Guest') = 'Vip Guest', 'G4 the guest names it';
  RAISE NOTICE 'OK  G4 staff cancel and re-send a parked claim; the guest claims it';
END $$;

-- G5. Hard removal: the ex-manager's other parked claim stays out of reach.
DELETE FROM public.exos_org_memberships
 WHERE org_id = 'a9200000-0000-0000-0000-000000000001' AND user_id = 'a9200000-0000-0000-0000-0000000000a2';
SELECT pg_temp.act('a9200000-0000-0000-0000-0000000000a2', 'pkmgr@x.test');
DO $$
DECLARE tk3 uuid := (SELECT id FROM pk WHERE k = 'tk3'); tr3 uuid := (SELECT id FROM pk WHERE k = 'tr3'); r text;
BEGIN
  ASSERT public._exos_ticket_held(tk3), 'G5 still held';
  r := pg_temp.try(format('SELECT public.exos_cancel_transfer(%L)', tr3));
  ASSERT r LIKE '42501%', 'G5 removed ex-manager cancels: ' || r;
  ASSERT public.exos_transfer_claim_key(tr3) IS NULL, 'G5 no claim key';
  ASSERT NOT public.exos_can_read_ticket_secret(tk3), 'G5 no secret';
  PERFORM pg_temp.act('a9200000-0000-0000-0000-0000000000a1', 'pkown@x.test');
  PERFORM public.exos_cancel_transfer(tr3);
  ASSERT (SELECT status FROM public.exos_transfers WHERE id = tr3) = 'cancelled', 'G5 the owner cancels it';
  RAISE NOTICE 'OK  G5 a hard-removed parker is refused too; staff still cancel';
END $$;

-- G6. A plain holder: own transfer cancelled, name set, secret read, as before.
SELECT pg_temp.act('a9200000-0000-0000-0000-0000000000a5', 'pkhold@x.test');
DO $$
DECLARE c5 uuid := 'a9200000-0000-0000-0000-00000000c005'; tr uuid;
BEGIN
  tr := public.exos_create_transfer(c5, 'friend@else.test');
  ASSERT NOT public._exos_ticket_held(c5), 'G6 a friend transfer is not a parking';
  ASSERT public.exos_transfer_claim_key(tr) IS NOT NULL, 'G6 sender gets the claim key';
  PERFORM public.exos_cancel_transfer(tr);
  ASSERT (SELECT status FROM public.exos_transfers WHERE id = tr) = 'cancelled', 'G6 cancelled';
  ASSERT public.exos_set_ticket_attendee(c5, 'Hal') = 'Hal', 'G6 name';
  ASSERT public.exos_can_read_ticket_secret(c5), 'G6 secret';
  -- Someone else can't cancel a holder's transfer.
  tr := public.exos_create_transfer(c5, 'friend@else.test');
  PERFORM pg_temp.act('a9200000-0000-0000-0000-0000000000a3', 'pkmgr2@x.test');
  ASSERT pg_temp.try(format('SELECT public.exos_cancel_transfer(%L)', tr)) LIKE '42501%not the sender%', 'G6 not the sender';
  RAISE NOTICE 'OK  G6 plain holders are unchanged';
END $$;

SELECT '*** parked ticket guard: ALL ASSERTIONS PASSED ***' AS result;
ROLLBACK;
