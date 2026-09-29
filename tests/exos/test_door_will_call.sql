-- ============================================================================
-- Will-call for parked tickets (mig 20260929130000):
--   W1 roster: parked + claim name + masked email; never the full email
--   W2 a scanner can't admit at will-call (needs a manager), ticket untouched
--   W3 only parked tickets: a plain ticket is 'not-parked', a holder's own
--      transfer stays 'in-transfer'
--   W4 wrong event, reason required, outsiders refused
--   W5 owner admits a marketplace-style parking: used, will-call check-in,
--      transfer cancelled (the link is dead); a second admit is 'used'
--   W6 manager admits a box-office parking with a client ref: replay is a
--      duplicate, the ref is bound to its ticket
--   W7 a refused offline replay is a conflict and lands in the scan report
--   W8 grants + pinned search_path
-- Self-contained (BEGIN / ROLLBACK). Org b7…01 owned by …a1; manager …a2,
-- scanner …a3, holder …a5, outsider …a6 (owns org b7…02). Events …e1 (doors
-- open) and …e2 (doors open), …e9 in the other org.
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
  ('b7000000-0000-0000-0000-000000000001','Will Org','will-org-stub','b7000000-0000-0000-0000-0000000000a1'),
  ('b7000000-0000-0000-0000-000000000002','Other Org','will-other-stub','b7000000-0000-0000-0000-0000000000a6');
INSERT INTO public.exos_org_memberships(org_id,user_id,role) VALUES
  ('b7000000-0000-0000-0000-000000000001','b7000000-0000-0000-0000-0000000000a1','owner'),
  ('b7000000-0000-0000-0000-000000000001','b7000000-0000-0000-0000-0000000000a2','manager'),
  ('b7000000-0000-0000-0000-000000000001','b7000000-0000-0000-0000-0000000000a3','scanner'),
  ('b7000000-0000-0000-0000-000000000002','b7000000-0000-0000-0000-0000000000a6','owner');
INSERT INTO public.exos_events(id,org_id,name,slug,status,starts_at,doors_at,total_tickets,created_by) VALUES
  ('b7000000-0000-0000-0000-0000000000e1','b7000000-0000-0000-0000-000000000001','Will One','will-one-stub','published',
   now() + interval '1 hour', now() - interval '1 hour', 0, 'b7000000-0000-0000-0000-0000000000a1'),
  ('b7000000-0000-0000-0000-0000000000e2','b7000000-0000-0000-0000-000000000001','Will Two','will-two-stub','published',
   now() + interval '1 hour', now() - interval '1 hour', 0, 'b7000000-0000-0000-0000-0000000000a1'),
  ('b7000000-0000-0000-0000-0000000000e9','b7000000-0000-0000-0000-000000000002','Elsewhere','will-else-stub','published',
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

CREATE FUNCTION pg_temp.act(p_uid text) RETURNS void LANGUAGE sql AS $$
  SELECT set_config('app.uid', p_uid, false), set_config('app.jwt', '{"email":"will@x.com"}', false);
$$;

-- A box-office issue by the MANAGER to an email with no account: the real
-- mint path (exos_issue_ticket_to_email) parks it on the manager.
SELECT pg_temp.act('b7000000-0000-0000-0000-0000000000a2');
CREATE TEMP TABLE will_box AS
  SELECT unnest(public.exos_issue_ticket_to_email('b7000000-0000-0000-0000-0000000000e1', NULL,
                                                  'Box.Buyer@Mail.com', 1, 'bo-1')) AS id;

-- W1. Roster.
DO $$
DECLARE
  e1 uuid := 'b7000000-0000-0000-0000-0000000000e1';
  c1 uuid := 'b7000000-0000-0000-0000-00000000c001';
  box uuid := (SELECT id FROM will_box);
  r record;
BEGIN
  PERFORM pg_temp.act('b7000000-0000-0000-0000-0000000000a3');   -- a scanner reads the roster
  SELECT * INTO r FROM public.exos_event_checkin_roster(e1) WHERE ticket_id = c1;
  ASSERT r.parked AND r.claim_name = 'Jane Doe' AND r.claim_email_masked = 'j***@gmail.com',
         'W1: marketplace parking shows claim name + masked email, got ' || row_to_json(r)::text;
  ASSERT r.owner_name = 'Jane Doe', 'W1: door name is the buyer, not the org owner, got ' || r.owner_name;
  SELECT * INTO r FROM public.exos_event_checkin_roster(e1) WHERE ticket_id = box;
  ASSERT r.parked AND r.claim_name IS NULL AND r.claim_email_masked = 'b***@mail.com'
         AND r.owner_name = 'b***@mail.com',
         'W1: box-office parking (on the manager) is parked, named by masked email, got ' || row_to_json(r)::text;
  SELECT * INTO r FROM public.exos_event_checkin_roster(e1) WHERE ticket_id = 'b7000000-0000-0000-0000-00000000c003';
  ASSERT NOT r.parked AND r.claim_name IS NULL AND r.claim_email_masked IS NULL AND r.owner_name = 'Hal Holder',
         'W1: a holder''s own transfer is not parked, got ' || row_to_json(r)::text;
  SELECT * INTO r FROM public.exos_event_checkin_roster(e1) WHERE ticket_id = 'b7000000-0000-0000-0000-00000000c002';
  ASSERT NOT r.parked AND r.owner_name = 'Hal Holder', 'W1: plain ticket unchanged';
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_event_checkin_roster(e1) x
                      WHERE row_to_json(x)::text ILIKE '%jane.doe@%'
                         OR row_to_json(x)::text ILIKE '%box.buyer@%'
                         OR row_to_json(x)::text ILIKE '%kim@example%'
                         OR row_to_json(x)::text ~ (SELECT string_agg(claim_key, '|') FROM public.exos_transfers
                                                     WHERE org_id = 'b7000000-0000-0000-0000-000000000001')),
         'W1: no full email or claim key in the roster';
  RAISE NOTICE 'OK  W1 roster: parked + claim name + masked email, never the full email';
END $$;

-- W2. A scanner can't admit at will-call.
DO $$
DECLARE r jsonb; c1 uuid := 'b7000000-0000-0000-0000-00000000c001';
BEGIN
  PERFORM pg_temp.act('b7000000-0000-0000-0000-0000000000a3');
  r := public.exos_door_admit_parked(c1, 'b7000000-0000-0000-0000-0000000000e1', 'ID checked', 'Door 1');
  ASSERT NOT (r ->> 'ok')::boolean AND r ->> 'reason' = 'needs-manager', 'W2: scanner needs a manager, got ' || r;
  ASSERT (SELECT status = 'active' AND pending_transfer_id IS NOT NULL FROM public.exos_tickets WHERE id = c1),
         'W2: ticket untouched';
  ASSERT (SELECT status FROM public.exos_transfers WHERE id = 'b7000000-0000-0000-0000-0000000007a1') = 'pending',
         'W2: transfer still claimable';
  RAISE NOTICE 'OK  W2 scanner refused (needs-manager)';
END $$;

-- W3. Only parked tickets.
DO $$
DECLARE r jsonb; e1 uuid := 'b7000000-0000-0000-0000-0000000000e1';
BEGIN
  PERFORM pg_temp.act('b7000000-0000-0000-0000-0000000000a1');
  r := public.exos_door_admit_parked('b7000000-0000-0000-0000-00000000c002', e1, 'ID checked');
  ASSERT r ->> 'reason' = 'not-parked', 'W3: plain ticket is not-parked, got ' || r;
  r := public.exos_door_admit_parked('b7000000-0000-0000-0000-00000000c003', e1, 'ID checked');
  ASSERT r ->> 'reason' = 'in-transfer', 'W3: a holder''s own transfer stays in-transfer, got ' || r;
  ASSERT (SELECT count(*) FROM public.exos_tickets WHERE id IN ('b7000000-0000-0000-0000-00000000c002',
          'b7000000-0000-0000-0000-00000000c003') AND status = 'active') = 2, 'W3: neither consumed';
  ASSERT (SELECT status FROM public.exos_transfers WHERE id = 'b7000000-0000-0000-0000-0000000007a3') = 'pending',
         'W3: the holder''s transfer is untouched';
  RAISE NOTICE 'OK  W3 non-parked tickets refused';
END $$;

-- W4. Wrong event, reason required, outsiders.
DO $$
DECLARE r jsonb; c1 uuid := 'b7000000-0000-0000-0000-00000000c001';
BEGIN
  PERFORM pg_temp.act('b7000000-0000-0000-0000-0000000000a1');
  r := public.exos_door_admit_parked(c1, 'b7000000-0000-0000-0000-0000000000e2', 'ID checked');
  ASSERT r ->> 'reason' = 'wrong-event', 'W4: wrong event, got ' || r;
  r := public.exos_door_admit_parked(c1, 'b7000000-0000-0000-0000-0000000000e1', ' x ');
  ASSERT r ->> 'reason' = 'reason-required', 'W4: reason required, got ' || r;
  -- The other org's owner, using their own event id: the ticket isn't theirs.
  PERFORM pg_temp.act('b7000000-0000-0000-0000-0000000000a6');
  r := public.exos_door_admit_parked(c1, 'b7000000-0000-0000-0000-0000000000e9', 'ID checked');
  ASSERT r ->> 'reason' = 'wrong-event', 'W4: another org''s event, got ' || r;
  BEGIN
    PERFORM public.exos_door_admit_parked(c1, 'b7000000-0000-0000-0000-0000000000e1', 'ID checked');
    RAISE EXCEPTION 'W4: an outsider was not refused';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  PERFORM pg_temp.act('b7000000-0000-0000-0000-0000000000a5');
  BEGIN
    PERFORM public.exos_door_admit_parked(c1, 'b7000000-0000-0000-0000-0000000000e1', 'ID checked');
    RAISE EXCEPTION 'W4: a ticket holder was not refused';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  ASSERT (SELECT status FROM public.exos_tickets WHERE id = c1) = 'active', 'W4: still unused';
  RAISE NOTICE 'OK  W4 wrong event / reason / outsiders refused';
END $$;

-- W5. The owner admits a marketplace parking.
DO $$
DECLARE r jsonb; c1 uuid := 'b7000000-0000-0000-0000-00000000c001'; e1 uuid := 'b7000000-0000-0000-0000-0000000000e1';
BEGIN
  PERFORM pg_temp.act('b7000000-0000-0000-0000-0000000000a1');
  -- A normal typed override still refuses it as mid-transfer (unchanged).
  ASSERT public.exos_check_in_ticket(c1, 'manual', 'manual', NULL, e1, 'ID checked') ->> 'reason' = 'in-transfer',
         'W5: the normal check-in path is unchanged';
  r := public.exos_door_admit_parked(c1, e1, 'Driver licence matches Jane Doe', 'Door 1');
  ASSERT (r ->> 'ok')::boolean AND r ->> 'reason' = 'checked-in' AND (r ->> 'will_call')::boolean
         AND r ->> 'claim_name' = 'Jane Doe', 'W5: admitted, got ' || r;
  ASSERT (SELECT status = 'used' AND pending_transfer_id IS NULL AND check_in_at IS NOT NULL
                 AND owner_id = 'b7000000-0000-0000-0000-0000000000a1'
            FROM public.exos_tickets WHERE id = c1), 'W5: used, no pending transfer, still on the org owner';
  ASSERT (SELECT status FROM public.exos_transfers WHERE id = 'b7000000-0000-0000-0000-0000000007a1') = 'cancelled',
         'W5: the pending transfer is cancelled';
  ASSERT (SELECT verification || '/' || source || '/' || device || '/' || override_reason
            FROM public.exos_event_checkins WHERE ticket_id = c1)
         = 'will-call/manual/Door 1/Driver licence matches Jane Doe', 'W5: will-call check-in with the reason';
  -- The sender's link getter and the claim both see a dead link now.
  ASSERT public.exos_transfer_claim_key('b7000000-0000-0000-0000-0000000007a1') IS NULL, 'W5: no claim link';
  -- Second admit: already used, says where.
  r := public.exos_door_admit_parked(c1, e1, 'ID checked again');
  ASSERT NOT (r ->> 'ok')::boolean AND r ->> 'reason' = 'used' AND r ->> 'device' = 'Door 1',
         'W5: second admit is used, got ' || r;
  ASSERT (SELECT count(*) FROM public.exos_event_checkins WHERE ticket_id = c1) = 1, 'W5: counted once';
  -- The roster now shows it used and no longer parked.
  ASSERT (SELECT status = 'used' AND NOT parked FROM public.exos_event_checkin_roster(e1) WHERE ticket_id = c1),
         'W5: roster shows used, not parked';
  RAISE NOTICE 'OK  W5 owner admits at will-call; transfer cancelled; second admit is used';
END $$;

-- W6. The manager admits the box-office parking with a client ref (offline replay).
DO $$
DECLARE
  r jsonb; e1 uuid := 'b7000000-0000-0000-0000-0000000000e1';
  box uuid := (SELECT id FROM will_box);
  ref uuid := 'b7000000-0000-0000-0000-0000000000f1';
  at timestamptz := now() - interval '10 minutes';
BEGIN
  PERFORM pg_temp.act('b7000000-0000-0000-0000-0000000000a2');
  r := public.exos_door_admit_parked(box, e1, 'Passport checked', 'Door 2', at, ref);
  ASSERT (r ->> 'ok')::boolean AND r ->> 'reason' = 'checked-in', 'W6: admitted, got ' || r;
  ASSERT (SELECT check_in_at FROM public.exos_tickets WHERE id = box) = at, 'W6: check_in_at is the scan time';
  ASSERT (SELECT offline_scanned_at FROM public.exos_event_checkins WHERE ticket_id = box) = at, 'W6: offline time kept';
  r := public.exos_door_admit_parked(box, e1, 'Passport checked', 'Door 2', at, ref);
  ASSERT (r ->> 'ok')::boolean AND (r ->> 'duplicate')::boolean, 'W6: same ref is a duplicate, got ' || r;
  ASSERT (SELECT count(*) FROM public.exos_event_checkins WHERE ticket_id = box) = 1, 'W6: counted once';
  r := public.exos_door_admit_parked('b7000000-0000-0000-0000-00000000c004', e1, 'Passport checked', 'Door 2', at, ref);
  ASSERT r ->> 'reason' = 'bad-client-ref', 'W6: a ref is bound to its ticket, got ' || r;
  -- The same ref can't be reused by the ticket path either (shared ref table).
  ASSERT public.exos_check_in_offline(ref, 'b7000000-0000-0000-0000-00000000c002', e1, at) ->> 'reason' = 'bad-client-ref',
         'W6: refs are shared with exos_check_in_offline';
  ASSERT (SELECT count(*) FROM public.exos_transfers tr JOIN will_box b ON b.id = tr.ticket_id
           WHERE tr.status = 'pending') = 0, 'W6: box-office transfer cancelled';
  RAISE NOTICE 'OK  W6 manager admit with client ref is idempotent';
END $$;

-- W7. A refused replay (queued by a scanner) is a conflict in the scan report.
DO $$
DECLARE r jsonb; c4 uuid := 'b7000000-0000-0000-0000-00000000c004';
BEGIN
  PERFORM pg_temp.act('b7000000-0000-0000-0000-0000000000a3');
  r := public.exos_door_admit_parked(c4, 'b7000000-0000-0000-0000-0000000000e1', 'ID checked', 'Door 3',
                                     now() - interval '1 minute', 'b7000000-0000-0000-0000-0000000000f7');
  ASSERT NOT (r ->> 'ok')::boolean AND r ->> 'reason' = 'needs-manager' AND (r ->> 'conflict')::boolean,
         'W7: refused replay is a conflict, got ' || r;
  ASSERT (SELECT reason_detail FROM public.exos_scan_rejects WHERE ticket_id_attempted = c4::text)
         = 'will-call-replay:needs-manager', 'W7: logged for the scan report';
  ASSERT (SELECT status FROM public.exos_tickets WHERE id = c4) = 'active', 'W7: not consumed';
  RAISE NOTICE 'OK  W7 refused replay is a logged conflict';
END $$;

-- W8. Grants and search_path.
DO $$
DECLARE f regprocedure := 'public.exos_door_admit_parked(uuid, uuid, text, text, timestamptz, uuid)'::regprocedure;
BEGIN
  ASSERT has_function_privilege('authenticated', f, 'EXECUTE'), 'W8: authenticated may call it';
  ASSERT NOT has_function_privilege('anon', f, 'EXECUTE'), 'W8: anon may not';
  ASSERT NOT has_function_privilege('anon', 'public.exos_event_checkin_roster(uuid)'::regprocedure, 'EXECUTE'),
         'W8: anon may not read the roster';
  ASSERT NOT has_function_privilege('authenticated',
           'public._exos_ticket_parked(public.exos_tickets, public.exos_transfers)'::regprocedure, 'EXECUTE'),
         'W8: the parked helper is internal';
  ASSERT (SELECT bool_and(array_to_string(proconfig, ',') LIKE '%search_path=public, pg_temp%')
            FROM pg_proc WHERE proname IN ('exos_door_admit_parked', 'exos_event_checkin_roster', '_exos_ticket_parked')),
         'W8: search_path pinned';
  RAISE NOTICE 'OK  W8 grants + search_path';
END $$;

SELECT set_config('app.uid', '', false), set_config('app.jwt', '', false);
ROLLBACK;
