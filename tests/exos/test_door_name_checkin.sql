-- ============================================================================
-- Name-based door check-in (mig 20260929130000):
--   N1 roster: parked + claim name + masked email only; the event's
--      door_name_checkin defaults to 'staff' and only takes the three modes
--   N2 'staff': a scanner checks a claimed ticket in by name, note optional;
--      logged as 'name'; a second try is 'used' (with the device)
--   N3 a parked (unclaimed) ticket: checked in by name, its claim link is
--      cancelled, the ticket stays on the org
--   N4 a holder's own pending transfer stays 'in-transfer'
--   N5 'managers': a scanner needs a manager, a manager checks in (no note)
--   N6 'off': nobody checks in by name; the typed override is unchanged
--   N7 scanner scope: a scanner assigned elsewhere gets 'not-assigned'
--   N8 wrong event, voided, doors / test window, outsiders
--   N9 client ref: replay is a duplicate, bound to its ticket, shared with
--      exos_check_in_offline
--   N10 a refused replay is a conflict in the scan report
--   N11 grants + pinned search_path + verification CHECK
-- Self-contained (BEGIN / ROLLBACK). Org b7…01 owned by …a1; manager …a2,
-- scanner …a3, holder …a5, outsider …a6 (owns org b7…02). Events …e1 and
-- …e2 (doors open), …e3 (doors in an hour), …e9 in the other org.
-- ============================================================================
\set ON_ERROR_STOP on
BEGIN;

-- The p0 chain has no exos_profiles (phase 1); the roster LEFT JOINs it.
CREATE TABLE IF NOT EXISTS public.exos_profiles (id uuid PRIMARY KEY, display_name text);

INSERT INTO auth.users(id,email,email_confirmed_at) VALUES
  ('b7000000-0000-0000-0000-0000000000a1','b7own@x.com',now()),
  ('b7000000-0000-0000-0000-0000000000a2','b7mgr@x.com',now()),
  ('b7000000-0000-0000-0000-0000000000a3','b7scan@x.com',now()),
  ('b7000000-0000-0000-0000-0000000000a5','b7hold@x.com',now()),
  ('b7000000-0000-0000-0000-0000000000a6','b7out@x.com',now());
INSERT INTO public.exos_profiles(id, display_name) VALUES
  ('b7000000-0000-0000-0000-0000000000a1','Olive Owner'),
  ('b7000000-0000-0000-0000-0000000000a2','Manny Manager'),
  ('b7000000-0000-0000-0000-0000000000a5','Hal Holder')
ON CONFLICT (id) DO NOTHING;
INSERT INTO public.exos_orgs(id,name,slug,owner_uid) VALUES
  ('b7000000-0000-0000-0000-000000000001','Name Org','name-org-stub','b7000000-0000-0000-0000-0000000000a1'),
  ('b7000000-0000-0000-0000-000000000002','Other Org','name-other-stub','b7000000-0000-0000-0000-0000000000a6');
INSERT INTO public.exos_org_memberships(org_id,user_id,role) VALUES
  ('b7000000-0000-0000-0000-000000000001','b7000000-0000-0000-0000-0000000000a1','owner'),
  ('b7000000-0000-0000-0000-000000000001','b7000000-0000-0000-0000-0000000000a2','manager'),
  ('b7000000-0000-0000-0000-000000000001','b7000000-0000-0000-0000-0000000000a3','scanner'),
  ('b7000000-0000-0000-0000-000000000002','b7000000-0000-0000-0000-0000000000a6','owner');
INSERT INTO public.exos_events(id,org_id,name,slug,status,starts_at,doors_at,total_tickets,created_by) VALUES
  ('b7000000-0000-0000-0000-0000000000e1','b7000000-0000-0000-0000-000000000001','Name One','name-one-stub','published',
   now() + interval '1 hour', now() - interval '1 hour', 0, 'b7000000-0000-0000-0000-0000000000a1'),
  ('b7000000-0000-0000-0000-0000000000e2','b7000000-0000-0000-0000-000000000001','Name Two','name-two-stub','published',
   now() + interval '1 hour', now() - interval '1 hour', 0, 'b7000000-0000-0000-0000-0000000000a1'),
  ('b7000000-0000-0000-0000-0000000000e9','b7000000-0000-0000-0000-000000000002','Elsewhere','name-else-stub','published',
   now() + interval '1 hour', now() - interval '1 hour', 0, 'b7000000-0000-0000-0000-0000000000a6');

-- c1: a StubHub sale parked on the org owner, as exos_fulfil_marketplace_order
--     mints it (owner = buyer = org owner, buyer_email = the buyer's).
-- c2: the holder's own ticket, a plain active one.
-- c3: the holder's ticket mid-transfer to a friend (not a parking).
-- c4: another marketplace parking on e1 (for the scanner / replay checks).
INSERT INTO public.exos_tickets(id,event_id,org_id,buyer_id,owner_id,buyer_email,status,barcode_secret,price_paid,order_ref,channel_source,tier_name)
VALUES
  ('b7000000-0000-0000-0000-00000000c001','b7000000-0000-0000-0000-0000000000e1','b7000000-0000-0000-0000-000000000001',
   'b7000000-0000-0000-0000-0000000000a1','b7000000-0000-0000-0000-0000000000a1','jane.doe@gmail.com','active','sek-1',50,'stubhub:991','stubhub','GA'),
  ('b7000000-0000-0000-0000-00000000c002','b7000000-0000-0000-0000-0000000000e1','b7000000-0000-0000-0000-000000000001',
   'b7000000-0000-0000-0000-0000000000a5','b7000000-0000-0000-0000-0000000000a5','b7hold@x.com','active','sek-2',50,'web-2','stripe','GA'),
  ('b7000000-0000-0000-0000-00000000c003','b7000000-0000-0000-0000-0000000000e1','b7000000-0000-0000-0000-000000000001',
   'b7000000-0000-0000-0000-0000000000a5','b7000000-0000-0000-0000-0000000000a5','b7hold@x.com','active','sek-3',50,'web-3','stripe','GA'),
  ('b7000000-0000-0000-0000-00000000c004','b7000000-0000-0000-0000-0000000000e1','b7000000-0000-0000-0000-000000000001',
   'b7000000-0000-0000-0000-0000000000a1','b7000000-0000-0000-0000-0000000000a1','kim@example.org','active','sek-4',50,'stubhub:992','stubhub','GA');
INSERT INTO public.exos_transfers(id,ticket_id,org_id,sender_id,receiver_email,receiver_name,status,event_id,created_at,updated_at) VALUES
  ('b7000000-0000-0000-0000-0000000007a1','b7000000-0000-0000-0000-00000000c001','b7000000-0000-0000-0000-000000000001',
   'b7000000-0000-0000-0000-0000000000a1','jane.doe@gmail.com','Jane Doe','pending','b7000000-0000-0000-0000-0000000000e1',now(),now()),
  ('b7000000-0000-0000-0000-0000000007a3','b7000000-0000-0000-0000-00000000c003','b7000000-0000-0000-0000-000000000001',
   'b7000000-0000-0000-0000-0000000000a5','friend@gmail.com','Fran Friend','pending','b7000000-0000-0000-0000-0000000000e1',now(),now()),
  ('b7000000-0000-0000-0000-0000000007a4','b7000000-0000-0000-0000-00000000c004','b7000000-0000-0000-0000-000000000001',
   'b7000000-0000-0000-0000-0000000000a1','kim@example.org',NULL,'pending','b7000000-0000-0000-0000-0000000000e1',now(),now());
UPDATE public.exos_tickets SET pending_transfer_id = 'b7000000-0000-0000-0000-0000000007a1' WHERE id = 'b7000000-0000-0000-0000-00000000c001';
UPDATE public.exos_tickets SET pending_transfer_id = 'b7000000-0000-0000-0000-0000000007a3' WHERE id = 'b7000000-0000-0000-0000-00000000c003';
UPDATE public.exos_tickets SET pending_transfer_id = 'b7000000-0000-0000-0000-0000000007a4' WHERE id = 'b7000000-0000-0000-0000-00000000c004';

INSERT INTO public.exos_events(id,org_id,name,slug,status,starts_at,doors_at,total_tickets,created_by) VALUES
  ('b7000000-0000-0000-0000-0000000000e3','b7000000-0000-0000-0000-000000000001','Later','name-later-stub','published',
   now() + interval '3 hours', now() + interval '1 hour', 0, 'b7000000-0000-0000-0000-0000000000a1');
-- c5-c7 on e2 (the managers / off modes), c8 voided on e1, c9 on e3 (doors
-- not open), c10 plain on e1 (scanner scope, replay conflict).
INSERT INTO public.exos_tickets(id,event_id,org_id,buyer_id,owner_id,buyer_email,status,barcode_secret,price_paid,order_ref,channel_source,tier_name)
SELECT ('b7000000-0000-0000-0000-00000000c0' || lpad(n::text, 2, '0'))::uuid,
       CASE WHEN n BETWEEN 5 AND 7 THEN 'b7000000-0000-0000-0000-0000000000e2'::uuid
            WHEN n = 9 THEN 'b7000000-0000-0000-0000-0000000000e3'::uuid
            ELSE 'b7000000-0000-0000-0000-0000000000e1'::uuid END,
       'b7000000-0000-0000-0000-000000000001','b7000000-0000-0000-0000-0000000000a5','b7000000-0000-0000-0000-0000000000a5',
       'b7hold@x.com', CASE WHEN n = 8 THEN 'voided' ELSE 'active' END, 'sek-' || n, 50, 'web-' || n, 'stripe', 'GA'
  FROM generate_series(5, 10) n;

CREATE FUNCTION pg_temp.act(p_uid text) RETURNS void LANGUAGE sql AS $$
  SELECT set_config('app.uid', p_uid, false), set_config('app.jwt', '{"email":"door@x.com"}', false);
$$;

-- A box-office issue by the MANAGER to an email with no account: the real
-- mint path (exos_issue_ticket_to_email) parks it on the manager.
SELECT pg_temp.act('b7000000-0000-0000-0000-0000000000a2');
CREATE TEMP TABLE name_box AS
  SELECT unnest(public.exos_issue_ticket_to_email('b7000000-0000-0000-0000-0000000000e1', NULL,
                                                  'Box.Buyer@Mail.com', 1, 'bo-1')) AS id;

-- N1. Roster.
DO $$
DECLARE
  e1 uuid := 'b7000000-0000-0000-0000-0000000000e1';
  c1 uuid := 'b7000000-0000-0000-0000-00000000c001';
  box uuid := (SELECT id FROM name_box);
  r record;
BEGIN
  PERFORM pg_temp.act('b7000000-0000-0000-0000-0000000000a3');   -- a scanner reads the roster
  SELECT * INTO r FROM public.exos_event_checkin_roster(e1) WHERE ticket_id = c1;
  ASSERT r.parked AND r.claim_name = 'Jane Doe' AND r.claim_email_masked = 'j***@gmail.com',
         'N1: marketplace parking shows claim name + masked email, got ' || row_to_json(r)::text;
  ASSERT r.owner_name = 'Jane Doe', 'N1: door name is the buyer, not the org owner, got ' || r.owner_name;
  SELECT * INTO r FROM public.exos_event_checkin_roster(e1) WHERE ticket_id = box;
  ASSERT r.parked AND r.claim_name IS NULL AND r.claim_email_masked = 'b***@mail.com'
         AND r.owner_name = 'b***@mail.com',
         'N1: box-office parking (on the manager) is parked, named by masked email, got ' || row_to_json(r)::text;
  SELECT * INTO r FROM public.exos_event_checkin_roster(e1) WHERE ticket_id = 'b7000000-0000-0000-0000-00000000c003';
  ASSERT NOT r.parked AND r.claim_name IS NULL AND r.claim_email_masked IS NULL AND r.owner_name = 'Hal Holder',
         'N1: a holder''s own transfer is not parked, got ' || row_to_json(r)::text;
  SELECT * INTO r FROM public.exos_event_checkin_roster(e1) WHERE ticket_id = 'b7000000-0000-0000-0000-00000000c002';
  ASSERT NOT r.parked AND r.owner_name = 'Hal Holder', 'N1: plain ticket unchanged';
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_event_checkin_roster(e1) x
                      WHERE row_to_json(x)::text ILIKE '%jane.doe@%'
                         OR row_to_json(x)::text ILIKE '%box.buyer@%'
                         OR row_to_json(x)::text ILIKE '%kim@example%'
                         OR row_to_json(x)::text ~ (SELECT string_agg(claim_key, '|') FROM public.exos_transfers
                                                     WHERE org_id = 'b7000000-0000-0000-0000-000000000001')),
         'N1: no full email or claim key in the roster';
  ASSERT (SELECT door_name_checkin FROM public.exos_events WHERE id = e1) = 'staff', 'N1: default is staff';
  BEGIN
    UPDATE public.exos_events SET door_name_checkin = 'will-call' WHERE id = e1;
    RAISE EXCEPTION 'N1: an unknown mode was accepted';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
  RAISE NOTICE 'OK  N1 roster: parked + claim name + masked email, never the full email; modes checked';
END $$;


-- N2. 'staff' (the default): a scanner checks a claimed ticket in by name.
DO $$
DECLARE r jsonb; c2 uuid := 'b7000000-0000-0000-0000-00000000c002'; e1 uuid := 'b7000000-0000-0000-0000-0000000000e1';
BEGIN
  PERFORM pg_temp.act('b7000000-0000-0000-0000-0000000000a3');
  r := public.exos_door_checkin_by_name(c2, e1, NULL, 'Door 1');
  ASSERT (r ->> 'ok')::boolean AND r ->> 'reason' = 'checked-in' AND (r ->> 'by_name')::boolean
         AND NOT (r ->> 'parked')::boolean, 'N2: checked in by name, got ' || r;
  ASSERT (SELECT status = 'used' AND check_in_at IS NOT NULL AND owner_id = 'b7000000-0000-0000-0000-0000000000a5'
            FROM public.exos_tickets WHERE id = c2), 'N2: used, still the holder''s';
  ASSERT (SELECT verification || '/' || source || '/' || device || '/' || coalesce(override_reason, '<none>')
            FROM public.exos_event_checkins WHERE ticket_id = c2) = 'name/manual/Door 1/<none>',
         'N2: logged as name, no note';
  r := public.exos_door_checkin_by_name(c2, e1, 'again', 'Door 4');
  ASSERT NOT (r ->> 'ok')::boolean AND r ->> 'reason' = 'used' AND r ->> 'device' = 'Door 1',
         'N2: second try is used, with where, got ' || r;
  ASSERT (SELECT count(*) FROM public.exos_event_checkins WHERE ticket_id = c2) = 1, 'N2: counted once';
  RAISE NOTICE 'OK  N2 staff mode: scanner checks in by name; second try is used';
END $$;

-- N3. A parked (unclaimed) ticket: checked in by name, link cancelled.
DO $$
DECLARE r jsonb; c1 uuid := 'b7000000-0000-0000-0000-00000000c001'; e1 uuid := 'b7000000-0000-0000-0000-0000000000e1';
BEGIN
  PERFORM pg_temp.act('b7000000-0000-0000-0000-0000000000a1');
  -- A typed override still refuses it as mid-transfer (unchanged).
  ASSERT public.exos_check_in_ticket(c1, 'manual', 'manual', NULL, e1, 'ID checked') ->> 'reason' = 'in-transfer',
         'N3: the typed override path is unchanged';
  PERFORM pg_temp.act('b7000000-0000-0000-0000-0000000000a3');
  r := public.exos_door_checkin_by_name(c1, e1, 'Driver licence matches', 'Door 1');
  ASSERT (r ->> 'ok')::boolean AND r ->> 'reason' = 'checked-in' AND (r ->> 'parked')::boolean
         AND r ->> 'name' = 'Jane Doe', 'N3: parked ticket checked in, got ' || r;
  ASSERT (SELECT status = 'used' AND pending_transfer_id IS NULL
                 AND owner_id = 'b7000000-0000-0000-0000-0000000000a1'
            FROM public.exos_tickets WHERE id = c1), 'N3: used, no pending transfer, still on the org owner';
  ASSERT (SELECT status FROM public.exos_transfers WHERE id = 'b7000000-0000-0000-0000-0000000007a1') = 'cancelled',
         'N3: the claim link is cancelled';
  ASSERT public.exos_transfer_claim_key('b7000000-0000-0000-0000-0000000007a1') IS NULL, 'N3: no claim link';
  ASSERT (SELECT verification || '/' || override_reason FROM public.exos_event_checkins WHERE ticket_id = c1)
         = 'name/Driver licence matches', 'N3: logged as name with the note';
  ASSERT (SELECT status = 'used' AND NOT parked FROM public.exos_event_checkin_roster(e1) WHERE ticket_id = c1),
         'N3: roster shows used, not parked';
  RAISE NOTICE 'OK  N3 parked ticket checked in by name; claim link cancelled';
END $$;

-- N4. A holder's own pending transfer (friend-to-friend) is refused.
DO $$
DECLARE r jsonb;
BEGIN
  PERFORM pg_temp.act('b7000000-0000-0000-0000-0000000000a1');
  r := public.exos_door_checkin_by_name('b7000000-0000-0000-0000-00000000c003', 'b7000000-0000-0000-0000-0000000000e1');
  ASSERT NOT (r ->> 'ok')::boolean AND r ->> 'reason' = 'in-transfer', 'N4: in-transfer, got ' || r;
  ASSERT (SELECT status FROM public.exos_tickets WHERE id = 'b7000000-0000-0000-0000-00000000c003') = 'active',
         'N4: not consumed';
  ASSERT (SELECT status FROM public.exos_transfers WHERE id = 'b7000000-0000-0000-0000-0000000007a3') = 'pending',
         'N4: the holder''s transfer is untouched';
  RAISE NOTICE 'OK  N4 a holder''s own transfer stays in-transfer';
END $$;

-- N5. 'managers': scanners are refused, managers check in.
UPDATE public.exos_events SET door_name_checkin = 'managers' WHERE id = 'b7000000-0000-0000-0000-0000000000e2';
DO $$
DECLARE r jsonb; c5 uuid := 'b7000000-0000-0000-0000-00000000c005'; e2 uuid := 'b7000000-0000-0000-0000-0000000000e2';
BEGIN
  PERFORM pg_temp.act('b7000000-0000-0000-0000-0000000000a3');
  r := public.exos_door_checkin_by_name(c5, e2, 'looks right');
  ASSERT NOT (r ->> 'ok')::boolean AND r ->> 'reason' = 'needs-manager', 'N5: scanner needs a manager, got ' || r;
  ASSERT (SELECT status FROM public.exos_tickets WHERE id = c5) = 'active', 'N5: untouched';
  PERFORM pg_temp.act('b7000000-0000-0000-0000-0000000000a2');
  r := public.exos_door_checkin_by_name(c5, e2);
  ASSERT (r ->> 'ok')::boolean AND r ->> 'reason' = 'checked-in', 'N5: manager checks in, got ' || r;
  ASSERT (SELECT override_reason IS NULL AND verification = 'name' FROM public.exos_event_checkins WHERE ticket_id = c5),
         'N5: no note needed';
  RAISE NOTICE 'OK  N5 managers mode: scanner refused, manager admits';
END $$;

-- N6. 'off': QR only. The typed override (owner / manager + reason) is separate.
UPDATE public.exos_events SET door_name_checkin = 'off' WHERE id = 'b7000000-0000-0000-0000-0000000000e2';
DO $$
DECLARE r jsonb; c6 uuid := 'b7000000-0000-0000-0000-00000000c006'; e2 uuid := 'b7000000-0000-0000-0000-0000000000e2';
BEGIN
  PERFORM pg_temp.act('b7000000-0000-0000-0000-0000000000a1');
  r := public.exos_door_checkin_by_name(c6, e2, 'ID checked');
  ASSERT NOT (r ->> 'ok')::boolean AND r ->> 'reason' = 'name-checkin-off', 'N6: owner refused when off, got ' || r;
  PERFORM pg_temp.act('b7000000-0000-0000-0000-0000000000a3');
  r := public.exos_door_checkin_by_name(c6, e2);
  ASSERT r ->> 'reason' = 'name-checkin-off', 'N6: scanner refused when off, got ' || r;
  ASSERT (SELECT status FROM public.exos_tickets WHERE id = c6) = 'active', 'N6: untouched';
  PERFORM pg_temp.act('b7000000-0000-0000-0000-0000000000a1');
  r := public.exos_check_in_ticket(c6, 'manual', 'manual', NULL, e2, 'Phone died, ID checked');
  ASSERT (r ->> 'ok')::boolean, 'N6: the typed override still works, got ' || r;
  ASSERT (SELECT verification FROM public.exos_event_checkins WHERE ticket_id = c6) = 'manual', 'N6: logged as manual';
  RAISE NOTICE 'OK  N6 off: nobody checks in by name; typed override unchanged';
END $$;

-- N7. Scanner scope: a scanner assigned only to e2 can't work e1.
INSERT INTO public.exos_event_staff(event_id, user_id, org_id) VALUES
  ('b7000000-0000-0000-0000-0000000000e2','b7000000-0000-0000-0000-0000000000a3','b7000000-0000-0000-0000-000000000001');
DO $$
DECLARE r jsonb; c10 uuid := 'b7000000-0000-0000-0000-00000000c010';
BEGIN
  PERFORM pg_temp.act('b7000000-0000-0000-0000-0000000000a3');
  r := public.exos_door_checkin_by_name(c10, 'b7000000-0000-0000-0000-0000000000e1');
  ASSERT NOT (r ->> 'ok')::boolean AND r ->> 'reason' = 'not-assigned', 'N7: not assigned, got ' || r;
  ASSERT (SELECT status FROM public.exos_tickets WHERE id = c10) = 'active', 'N7: untouched';
  RAISE NOTICE 'OK  N7 scanner scope respected';
END $$;
DELETE FROM public.exos_event_staff WHERE user_id = 'b7000000-0000-0000-0000-0000000000a3';

-- N8. Wrong event, voided, doors / test window, outsiders.
DO $$
DECLARE r jsonb; c10 uuid := 'b7000000-0000-0000-0000-00000000c010'; c9 uuid := 'b7000000-0000-0000-0000-00000000c009';
BEGIN
  PERFORM pg_temp.act('b7000000-0000-0000-0000-0000000000a3');
  r := public.exos_door_checkin_by_name(c10, 'b7000000-0000-0000-0000-0000000000e3');
  ASSERT r ->> 'reason' = 'wrong-event', 'N8: wrong event, got ' || r;
  r := public.exos_door_checkin_by_name('b7000000-0000-0000-0000-00000000c008', 'b7000000-0000-0000-0000-0000000000e1');
  ASSERT r ->> 'reason' = 'voided', 'N8: voided, got ' || r;
  r := public.exos_door_checkin_by_name(c9, 'b7000000-0000-0000-0000-0000000000e3');
  ASSERT r ->> 'reason' = 'doors-not-open' AND r ? 'opens_at', 'N8: doors not open, got ' || r;
  UPDATE public.exos_events SET checkin_test_mode = true, checkin_test_until = now() + interval '2 hours'
   WHERE id = 'b7000000-0000-0000-0000-0000000000e3';
  r := public.exos_door_checkin_by_name(c9, 'b7000000-0000-0000-0000-0000000000e3');
  ASSERT (r ->> 'ok')::boolean AND r ->> 'reason' = 'test-scan', 'N8: test window is a test scan, got ' || r;
  ASSERT (SELECT status FROM public.exos_tickets WHERE id = c9) = 'active', 'N8: a test scan changes nothing';
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_event_checkins WHERE ticket_id = c9), 'N8: no check-in row';
  -- The other org's owner, with their own event id: the ticket isn't theirs.
  PERFORM pg_temp.act('b7000000-0000-0000-0000-0000000000a6');
  r := public.exos_door_checkin_by_name(c10, 'b7000000-0000-0000-0000-0000000000e9');
  ASSERT r ->> 'reason' = 'wrong-event', 'N8: another org''s event, got ' || r;
  BEGIN
    PERFORM public.exos_door_checkin_by_name(c10, 'b7000000-0000-0000-0000-0000000000e1');
    RAISE EXCEPTION 'N8: an outsider was not refused';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  PERFORM pg_temp.act('b7000000-0000-0000-0000-0000000000a5');
  BEGIN
    PERFORM public.exos_door_checkin_by_name(c10, 'b7000000-0000-0000-0000-0000000000e1');
    RAISE EXCEPTION 'N8: a ticket holder was not refused';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  ASSERT (SELECT status FROM public.exos_tickets WHERE id = c10) = 'active', 'N8: still unused';
  RAISE NOTICE 'OK  N8 wrong event / voided / doors / test window / outsiders';
END $$;

-- N9. Client ref (offline replay): the box-office parking, by the scanner.
DO $$
DECLARE
  r jsonb; e1 uuid := 'b7000000-0000-0000-0000-0000000000e1';
  box uuid := (SELECT id FROM name_box);
  ref uuid := 'b7000000-0000-0000-0000-0000000000f1';
  at timestamptz := now() - interval '10 minutes';
BEGIN
  PERFORM pg_temp.act('b7000000-0000-0000-0000-0000000000a3');
  r := public.exos_door_checkin_by_name(box, e1, NULL, 'Door 2', at, ref);
  ASSERT (r ->> 'ok')::boolean AND r ->> 'reason' = 'checked-in' AND (r ->> 'parked')::boolean,
         'N9: checked in, got ' || r;
  ASSERT (SELECT check_in_at FROM public.exos_tickets WHERE id = box) = at, 'N9: check_in_at is the scan time';
  ASSERT (SELECT offline_scanned_at FROM public.exos_event_checkins WHERE ticket_id = box) = at, 'N9: offline time kept';
  r := public.exos_door_checkin_by_name(box, e1, NULL, 'Door 2', at, ref);
  ASSERT (r ->> 'ok')::boolean AND (r ->> 'duplicate')::boolean, 'N9: same ref is a duplicate, got ' || r;
  ASSERT (SELECT count(*) FROM public.exos_event_checkins WHERE ticket_id = box) = 1, 'N9: counted once';
  r := public.exos_door_checkin_by_name('b7000000-0000-0000-0000-00000000c004', e1, NULL, 'Door 2', at, ref);
  ASSERT r ->> 'reason' = 'bad-client-ref', 'N9: a ref is bound to its ticket, got ' || r;
  ASSERT public.exos_check_in_offline(ref, 'b7000000-0000-0000-0000-00000000c010', e1, at) ->> 'reason' = 'bad-client-ref',
         'N9: refs are shared with exos_check_in_offline';
  ASSERT (SELECT count(*) FROM public.exos_transfers tr JOIN name_box b ON b.id = tr.ticket_id
           WHERE tr.status = 'pending') = 0, 'N9: box-office claim link cancelled';
  RAISE NOTICE 'OK  N9 client ref is idempotent and shared';
END $$;

-- N10. A refused replay is a conflict in the scan report.
UPDATE public.exos_events SET door_name_checkin = 'managers' WHERE id = 'b7000000-0000-0000-0000-0000000000e2';
DO $$
DECLARE r jsonb; c7 uuid := 'b7000000-0000-0000-0000-00000000c007';
BEGIN
  PERFORM pg_temp.act('b7000000-0000-0000-0000-0000000000a3');
  r := public.exos_door_checkin_by_name(c7, 'b7000000-0000-0000-0000-0000000000e2', NULL, 'Door 3',
                                        now() - interval '1 minute', 'b7000000-0000-0000-0000-0000000000f7');
  ASSERT NOT (r ->> 'ok')::boolean AND r ->> 'reason' = 'needs-manager' AND (r ->> 'conflict')::boolean,
         'N10: refused replay is a conflict, got ' || r;
  ASSERT (SELECT reason_detail FROM public.exos_scan_rejects WHERE ticket_id_attempted = c7::text)
         = 'name-replay:needs-manager', 'N10: logged for the scan report';
  ASSERT (SELECT status FROM public.exos_tickets WHERE id = c7) = 'active', 'N10: not consumed';
  RAISE NOTICE 'OK  N10 refused replay is a logged conflict';
END $$;

-- N11. Grants, search_path, verification CHECK.
DO $$
DECLARE f regprocedure := 'public.exos_door_checkin_by_name(uuid, uuid, text, text, timestamptz, uuid)'::regprocedure;
BEGIN
  ASSERT has_function_privilege('authenticated', f, 'EXECUTE'), 'N11: authenticated may call it';
  ASSERT NOT has_function_privilege('anon', f, 'EXECUTE'), 'N11: anon may not';
  ASSERT NOT has_function_privilege('anon', 'public.exos_event_checkin_roster(uuid)'::regprocedure, 'EXECUTE'),
         'N11: anon may not read the roster';
  ASSERT NOT has_function_privilege('authenticated',
           'public._exos_ticket_parked(public.exos_tickets, public.exos_transfers)'::regprocedure, 'EXECUTE'),
         'N11: the parked helper is internal';
  ASSERT (SELECT bool_and(array_to_string(proconfig, ',') LIKE '%search_path=public, pg_temp%')
            FROM pg_proc WHERE proname IN ('exos_door_checkin_by_name', 'exos_event_checkin_roster', '_exos_ticket_parked')),
         'N11: search_path pinned';
  ASSERT to_regprocedure('public.exos_door_admit_parked(uuid, uuid, text, text, timestamptz, uuid)') IS NULL,
         'N11: the will-call draft is gone';
  ASSERT has_column_privilege('authenticated', 'public.exos_events', 'door_name_checkin', 'SELECT')
     AND has_column_privilege('authenticated', 'public.exos_events', 'door_name_checkin', 'UPDATE'),
         'N11: org editors can read and set the mode (RLS decides rows)';
  ASSERT NOT has_column_privilege('anon', 'public.exos_events', 'door_name_checkin', 'UPDATE'),
         'N11: anon can''t set it';
  BEGIN
    INSERT INTO public.exos_event_checkins (event_id, ticket_id, org_id, scanned_by, source, verification)
    VALUES ('b7000000-0000-0000-0000-0000000000e1', 'b7000000-0000-0000-0000-00000000c010',
            'b7000000-0000-0000-0000-000000000001', 'b7000000-0000-0000-0000-0000000000a1', 'manual', 'will-call');
    RAISE EXCEPTION 'N11: verification will-call was accepted';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
  RAISE NOTICE 'OK  N11 grants + search_path + verification CHECK';
END $$;

SELECT set_config('app.uid', '', false), set_config('app.jwt', '', false);
ROLLBACK;
