-- ============================================================================
-- Door P1s (mig 20261021090000):
--   P1 offline replay stamped a few minutes ahead (fast door phone): taken as
--      now and checked in; further ahead: bad-scan-time with the ref kept free
--   P2 a 'not-assigned' replay keeps its ref free and isn't on the scan report;
--      the right account uploads the same ref later
--   P3 check-in by name replays: the same two rules
--   P4 a parked (unclaimed) ticket checked in by name in the test window is a
--      test: still active, claim still pending, nothing recorded
--   P5 guest arrivals: the replay's scan time (window rules, kept on the row);
--      the five-argument call still works; grants
--   P6 end-of-night summary: guest-list, imported and Eventbrite arrivals
--   P7 roster paged inside the function: keyset pages = the unpaged rows;
--      since form; scope; grants
--   P8 wallet push queue: 100 Apple-pending passes don't starve Google; a pass
--      waiting on Apple leaves the Google window once its object is updated
-- Self-contained (BEGIN / ROLLBACK). Org p1…01 owned by …a1; scanner …a3
-- (unscoped), scanner …a4 (assigned to e2 only), holder …a5.
-- ============================================================================
\set ON_ERROR_STOP on
BEGIN;

CREATE TABLE IF NOT EXISTS public.exos_profiles (
  id uuid PRIMARY KEY, display_name text, updated_at timestamptz NOT NULL DEFAULT now());

INSERT INTO auth.users(id,email,email_confirmed_at) VALUES
  ('e1d00000-0000-0000-0000-0000000000a1','doorp1own@x.com',now()),
  ('e1d00000-0000-0000-0000-0000000000a3','doorp1scan@x.com',now()),
  ('e1d00000-0000-0000-0000-0000000000a4','doorp1scan2@x.com',now()),
  ('e1d00000-0000-0000-0000-0000000000a5','doorp1hold@x.com',now());
INSERT INTO public.exos_orgs(id,name,slug,owner_uid) VALUES
  ('e1d00000-0000-0000-0000-000000000001','P1 Org','door-p1-org-stub','e1d00000-0000-0000-0000-0000000000a1');
INSERT INTO public.exos_org_memberships(org_id,user_id,role) VALUES
  ('e1d00000-0000-0000-0000-000000000001','e1d00000-0000-0000-0000-0000000000a1','owner'),
  ('e1d00000-0000-0000-0000-000000000001','e1d00000-0000-0000-0000-0000000000a3','scanner'),
  ('e1d00000-0000-0000-0000-000000000001','e1d00000-0000-0000-0000-0000000000a4','scanner');
-- e1: doors open. e2: another event (a4's). e3: doors in 2 h, test window on for 1 h.
INSERT INTO public.exos_events(id,org_id,name,slug,status,starts_at,doors_at,ends_at,total_tickets,created_by,
                               checkin_test_mode,checkin_test_until) VALUES
  ('e1d00000-0000-0000-0000-0000000000e1','e1d00000-0000-0000-0000-000000000001','P1 Night','door-p1-night-stub','published',
   now() + interval '1 hour', now() - interval '2 hours', now() + interval '6 hours', 0, 'e1d00000-0000-0000-0000-0000000000a1', false, NULL),
  ('e1d00000-0000-0000-0000-0000000000e2','e1d00000-0000-0000-0000-000000000001','P1 Two','door-p1-two-stub','published',
   now() + interval '1 hour', now() - interval '2 hours', NULL, 0, 'e1d00000-0000-0000-0000-0000000000a1', false, NULL),
  ('e1d00000-0000-0000-0000-0000000000e3','e1d00000-0000-0000-0000-000000000001','P1 Later','door-p1-later-stub','published',
   now() + interval '3 hours', now() + interval '2 hours', NULL, 0, 'e1d00000-0000-0000-0000-0000000000a1', true, now() + interval '1 hour');
UPDATE public.exos_events SET door_name_checkin = 'staff' WHERE org_id = 'e1d00000-0000-0000-0000-000000000001';
INSERT INTO public.exos_event_staff(event_id, user_id, org_id) VALUES
  ('e1d00000-0000-0000-0000-0000000000e2','e1d00000-0000-0000-0000-0000000000a4','e1d00000-0000-0000-0000-000000000001');
-- c0001..c0012 on e1 (held by a5); c0020 on e3, parked on the org owner for guest@x.com.
INSERT INTO public.exos_tickets(id,event_id,org_id,tier_name,buyer_id,owner_id,buyer_email,status,barcode_secret,price_paid,order_ref,channel_source)
SELECT ('e1d00000-0000-0000-0000-0000000' || lpad(k::text, 5, 'c000'))::uuid, 'e1d00000-0000-0000-0000-0000000000e1',
       'e1d00000-0000-0000-0000-000000000001', 'GA', 'e1d00000-0000-0000-0000-0000000000a5', 'e1d00000-0000-0000-0000-0000000000a5',
       'doorp1hold@x.com', 'active', 'sek-' || k, 50, 'web-' || k, 'stripe'
  FROM generate_series(1, 12) k;
INSERT INTO public.exos_tickets(id,event_id,org_id,tier_name,buyer_id,owner_id,buyer_email,status,barcode_secret,price_paid,order_ref,channel_source)
VALUES ('e1d00000-0000-0000-0000-00000000c020','e1d00000-0000-0000-0000-0000000000e3','e1d00000-0000-0000-0000-000000000001',
        'GA','e1d00000-0000-0000-0000-0000000000a1','e1d00000-0000-0000-0000-0000000000a1','guest@x.com','active','sek-20',50,'box-20','stripe');
INSERT INTO public.exos_transfers(id,ticket_id,org_id,sender_id,receiver_email,receiver_name,status,event_id,created_at,updated_at) VALUES
  ('e1d00000-0000-0000-0000-0000000007a1','e1d00000-0000-0000-0000-00000000c020','e1d00000-0000-0000-0000-000000000001',
   'e1d00000-0000-0000-0000-0000000000a1','guest@x.com','Gail Guest','pending','e1d00000-0000-0000-0000-0000000000e3',now(),now());
UPDATE public.exos_tickets SET pending_transfer_id = 'e1d00000-0000-0000-0000-0000000007a1' WHERE id = 'e1d00000-0000-0000-0000-00000000c020';

CREATE FUNCTION pg_temp.act(p_uid text) RETURNS void LANGUAGE sql AS $$
  SELECT set_config('app.uid', coalesce(p_uid, ''), false), set_config('app.jwt', '{"email":"door@x.com"}', false);
$$;
CREATE FUNCTION pg_temp.tk(p int) RETURNS uuid LANGUAGE sql IMMUTABLE AS $$
  SELECT ('e1d00000-0000-0000-0000-0000000' || lpad(p::text, 5, 'c000'))::uuid;
$$;
CREATE FUNCTION pg_temp.code(p_ticket uuid, p_at timestamptz) RETURNS text LANGUAGE sql STABLE AS $$
  SELECT 'T-' || t.id || ':' || t.owner_id || ':' || floor(extract(epoch FROM p_at) * 1000 / 30000)::bigint || ':' ||
         public._exos_door_code_mac(t.id, t.owner_id, floor(extract(epoch FROM p_at) * 1000 / 30000)::bigint, t.barcode_secret)
    FROM public.exos_tickets t WHERE t.id = p_ticket;
$$;
CREATE FUNCTION pg_temp.replay(p_ref uuid, p_ticket uuid, p_at timestamptz) RETURNS jsonb LANGUAGE sql AS $$
  SELECT public.exos_check_in_offline(p_ref, p_ticket, 'e1d00000-0000-0000-0000-0000000000e1', p_at,
           pg_temp.code(p_ticket, least(p_at, now())), 'camera', NULL, 'Door P', NULL, 'entry');
$$;

-- P1. Fast door phone, offline replay.
DO $$
DECLARE r jsonb; ref uuid := gen_random_uuid(); ref2 uuid := gen_random_uuid();
BEGIN
  PERFORM pg_temp.act('e1d00000-0000-0000-0000-0000000000a3');
  r := pg_temp.replay(ref, pg_temp.tk(1), now() + interval '3 minutes');
  ASSERT r ->> 'reason' = 'checked-in', 'P1 +3 min is checked in: ' || r::text;
  ASSERT (SELECT status FROM public.exos_tickets WHERE id = pg_temp.tk(1)) = 'used', 'P1 ticket used';
  ASSERT (SELECT offline_scanned_at FROM public.exos_event_checkins WHERE ticket_id = pg_temp.tk(1)) <= now(),
    'P1 recorded at now, not in the future';
  r := pg_temp.replay(ref, pg_temp.tk(1), now() + interval '3 minutes');
  ASSERT (r ->> 'duplicate')::boolean AND r ->> 'reason' = 'checked-in', 'P1 same ref again: the first answer stands';
  -- A second person with the same ticket is refused.
  r := pg_temp.replay(gen_random_uuid(), pg_temp.tk(1), now());
  ASSERT r ->> 'reason' = 'used', 'P1 reuse refused: ' || r::text;

  -- 20 minutes ahead: refused, nothing recorded, the ref stays free.
  r := pg_temp.replay(ref2, pg_temp.tk(2), now() + interval '20 minutes');
  ASSERT r ->> 'reason' = 'bad-scan-time' AND NOT r ? 'forced', 'P1 +20 min refused: ' || r::text;
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_checkin_client_refs WHERE client_ref = ref2), 'P1 ref not burned';
  r := pg_temp.replay(ref2, pg_temp.tk(2), now() - interval '1 minute');
  ASSERT r ->> 'reason' = 'checked-in' AND NOT r ? 'duplicate', 'P1 the same ref uploads once the time is right: ' || r::text;
  -- A too-old scan is still recorded as attended (forced) and burns its ref.
  r := pg_temp.replay(ref2, pg_temp.tk(3), now() - interval '9 days');
  ASSERT r ->> 'reason' = 'bad-client-ref', 'P1 a ref belongs to its ticket';
  r := pg_temp.replay(gen_random_uuid(), pg_temp.tk(3), now() - interval '9 days');
  ASSERT r ->> 'reason' = 'bad-scan-time' AND (r ->> 'forced')::boolean, 'P1 too old: forced as before: ' || r::text;
  RAISE NOTICE 'P1 ok: fast-clock replays are taken as now, far-future ones keep their ref';
END $$;

-- P2. Not assigned: kept, not reported, uploaded later by the right account.
DO $$
DECLARE r jsonb; ref uuid := gen_random_uuid(); n0 int := (SELECT count(*) FROM public.exos_scan_rejects);
BEGIN
  PERFORM pg_temp.act('e1d00000-0000-0000-0000-0000000000a4');
  r := pg_temp.replay(ref, pg_temp.tk(4), now() - interval '5 minutes');
  ASSERT r ->> 'reason' = 'not-assigned', 'P2 a4 is not assigned to e1: ' || r::text;
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_checkin_client_refs WHERE client_ref = ref), 'P2 ref not burned';
  ASSERT (SELECT count(*) FROM public.exos_scan_rejects) = n0, 'P2 not on the scan report';
  ASSERT (SELECT status FROM public.exos_tickets WHERE id = pg_temp.tk(4)) = 'active', 'P2 ticket untouched';
  PERFORM pg_temp.act('e1d00000-0000-0000-0000-0000000000a3');
  r := pg_temp.replay(ref, pg_temp.tk(4), now() - interval '5 minutes');
  ASSERT r ->> 'reason' = 'checked-in' AND NOT r ? 'duplicate', 'P2 the door''s own account uploads it: ' || r::text;
  RAISE NOTICE 'P2 ok: not-assigned replays wait for the right account';
END $$;

-- P3. Check in by name replays: the same rules.
DO $$
DECLARE r jsonb; ref uuid := gen_random_uuid(); ref2 uuid := gen_random_uuid();
BEGIN
  PERFORM pg_temp.act('e1d00000-0000-0000-0000-0000000000a3');
  r := public.exos_door_checkin_by_name(pg_temp.tk(5), 'e1d00000-0000-0000-0000-0000000000e1', NULL, 'Door P',
         now() + interval '3 minutes', ref, NULL, 'entry');
  ASSERT r ->> 'reason' = 'checked-in', 'P3 by name +3 min: ' || r::text;
  ASSERT (SELECT offline_scanned_at FROM public.exos_event_checkins WHERE ticket_id = pg_temp.tk(5)) <= now(), 'P3 at now';
  r := public.exos_door_checkin_by_name(pg_temp.tk(6), 'e1d00000-0000-0000-0000-0000000000e1', NULL, 'Door P',
         now() + interval '20 minutes', ref2, NULL, 'entry');
  ASSERT r ->> 'reason' = 'bad-scan-time', 'P3 by name +20 min: ' || r::text;
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_checkin_client_refs WHERE client_ref = ref2), 'P3 ref not burned';
  PERFORM pg_temp.act('e1d00000-0000-0000-0000-0000000000a4');
  r := public.exos_door_checkin_by_name(pg_temp.tk(6), 'e1d00000-0000-0000-0000-0000000000e1', NULL, 'Door P',
         now() - interval '1 minute', ref2, NULL, 'entry');
  ASSERT r ->> 'reason' = 'not-assigned', 'P3 a4 by name: ' || r::text;
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_checkin_client_refs WHERE client_ref = ref2), 'P3 still not burned';
  PERFORM pg_temp.act('e1d00000-0000-0000-0000-0000000000a3');
  r := public.exos_door_checkin_by_name(pg_temp.tk(6), 'e1d00000-0000-0000-0000-0000000000e1', NULL, 'Door P',
         now() - interval '1 minute', ref2, NULL, 'entry');
  ASSERT r ->> 'reason' = 'checked-in', 'P3 uploaded by the right account: ' || r::text;
  RAISE NOTICE 'P3 ok: by-name replays follow the same scan-time and ref rules';
END $$;

-- P4. Parked ticket by name inside the test window: a test.
DO $$
DECLARE r jsonb;
BEGIN
  PERFORM pg_temp.act('e1d00000-0000-0000-0000-0000000000a3');
  r := public.exos_door_checkin_by_name('e1d00000-0000-0000-0000-00000000c020', 'e1d00000-0000-0000-0000-0000000000e3',
         NULL, 'Door P', NULL, NULL, NULL, 'entry');
  ASSERT r ->> 'reason' = 'test-scan', 'P4 parked by name in the test window is a test: ' || r::text;
  ASSERT (SELECT status FROM public.exos_tickets WHERE id = 'e1d00000-0000-0000-0000-00000000c020') = 'active', 'P4 still active';
  ASSERT (SELECT pending_transfer_id FROM public.exos_tickets WHERE id = 'e1d00000-0000-0000-0000-00000000c020')
         = 'e1d00000-0000-0000-0000-0000000007a1', 'P4 still parked';
  ASSERT (SELECT status FROM public.exos_transfers WHERE id = 'e1d00000-0000-0000-0000-0000000007a1') = 'pending', 'P4 claim kept';
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_event_checkins WHERE ticket_id = 'e1d00000-0000-0000-0000-00000000c020'),
    'P4 nothing recorded';
  -- Outside the window it is refused before doors, as before.
  UPDATE public.exos_events SET checkin_test_mode = false, checkin_test_until = NULL WHERE id = 'e1d00000-0000-0000-0000-0000000000e3';
  r := public.exos_door_checkin_by_name('e1d00000-0000-0000-0000-00000000c020', 'e1d00000-0000-0000-0000-0000000000e3',
         NULL, 'Door P', NULL, NULL, NULL, 'entry');
  ASSERT r ->> 'reason' = 'doors-not-open', 'P4 no test window: doors-not-open: ' || r::text;
  RAISE NOTICE 'P4 ok: parked tickets are tests in the test window';
END $$;

-- P5. Guest arrivals with a scan time.
INSERT INTO public.exos_guest_lists(id,event_id,org_id,name) VALUES
  ('e1d00000-0000-0000-0000-0000000000b1','e1d00000-0000-0000-0000-0000000000e1','e1d00000-0000-0000-0000-000000000001','VIP'),
  ('e1d00000-0000-0000-0000-0000000000b2','e1d00000-0000-0000-0000-0000000000e1','e1d00000-0000-0000-0000-000000000001','Imported');
INSERT INTO public.exos_guest_list_entries(id,list_id,event_id,org_id,guest_name,plus_ones,source,external_code) VALUES
  ('e1d00000-0000-0000-0000-0000000000d1','e1d00000-0000-0000-0000-0000000000b1','e1d00000-0000-0000-0000-0000000000e1',
   'e1d00000-0000-0000-0000-000000000001','Gina Guest',1,NULL,NULL),
  ('e1d00000-0000-0000-0000-0000000000d2','e1d00000-0000-0000-0000-0000000000b2','e1d00000-0000-0000-0000-0000000000e1',
   'e1d00000-0000-0000-0000-000000000001','Dee Dice',0,'DICE','DICE-1'),
  ('e1d00000-0000-0000-0000-0000000000d3','e1d00000-0000-0000-0000-0000000000b2','e1d00000-0000-0000-0000-0000000000e1',
   'e1d00000-0000-0000-0000-000000000001','Eve Bright',0,'Eventbrite','EB-1'),
  ('e1d00000-0000-0000-0000-0000000000d4','e1d00000-0000-0000-0000-0000000000b2','e1d00000-0000-0000-0000-0000000000e1',
   'e1d00000-0000-0000-0000-000000000001','Val Void',0,'DICE','DICE-2'),
  ('e1d00000-0000-0000-0000-0000000000d5','e1d00000-0000-0000-0000-0000000000b2','e1d00000-0000-0000-0000-0000000000e1',
   'e1d00000-0000-0000-0000-000000000001','Olly Offline',0,'DICE','DICE-3');
UPDATE public.exos_guest_list_entries SET voided_at = now(), void_reason = 'refunded' WHERE id = 'e1d00000-0000-0000-0000-0000000000d4';
INSERT INTO public.exos_eventbrite_attendees(event_id, eb_attendee_id, entry_id, checked_in, checked_in_at, checkin_method) VALUES
  ('e1d00000-0000-0000-0000-0000000000e1','1001','e1d00000-0000-0000-0000-0000000000d3', true, now() - interval '30 minutes', 'scan');
DO $$
DECLARE r jsonb; ref uuid := gen_random_uuid();
BEGIN
  PERFORM pg_temp.act('e1d00000-0000-0000-0000-0000000000a3');
  r := public.exos_guest_check_in('e1d00000-0000-0000-0000-0000000000d5', 1, 'e1d00000-0000-0000-0000-0000000000e1',
         ref, 'offline-sync', now() - interval '40 minutes');
  ASSERT r ->> 'reason' = 'checked-in', 'P5 offline arrival: ' || r::text;
  ASSERT (SELECT arrived_at FROM public.exos_guest_list_entries WHERE id = 'e1d00000-0000-0000-0000-0000000000d5')
         < now() - interval '39 minutes', 'P5 arrived_at is when they came in';
  ASSERT (SELECT offline_scanned_at FROM public.exos_guest_list_checkins WHERE client_ref = ref)
         < now() - interval '39 minutes', 'P5 scan time kept on the arrival';
  r := public.exos_guest_check_in('e1d00000-0000-0000-0000-0000000000d1', 1, 'e1d00000-0000-0000-0000-0000000000e1',
         gen_random_uuid(), 'offline-sync', now() + interval '20 minutes');
  ASSERT r ->> 'reason' = 'bad-scan-time', 'P5 far future refused: ' || r::text;
  r := public.exos_guest_check_in('e1d00000-0000-0000-0000-0000000000d1', 1, 'e1d00000-0000-0000-0000-0000000000e1',
         gen_random_uuid(), 'offline-sync', now() - interval '9 days');
  ASSERT r ->> 'reason' = 'bad-scan-time', 'P5 too old refused: ' || r::text;
  r := public.exos_guest_check_in('e1d00000-0000-0000-0000-0000000000d1', 1, 'e1d00000-0000-0000-0000-0000000000e1',
         gen_random_uuid(), 'offline-sync', now() + interval '3 minutes');
  ASSERT r ->> 'reason' = 'checked-in', 'P5 fast clock taken as now: ' || r::text;
  -- The five named arguments (deployed clients) still resolve.
  r := public.exos_guest_check_in(p_entry_id => 'e1d00000-0000-0000-0000-0000000000d1', p_count => 1,
         p_event_id => 'e1d00000-0000-0000-0000-0000000000e1', p_client_ref => gen_random_uuid(), p_source => 'online');
  ASSERT r ->> 'reason' = 'checked-in' AND (r ->> 'arrived')::int = 2, 'P5 five-argument call: ' || r::text;
  PERFORM pg_temp.act('e1d00000-0000-0000-0000-0000000000a4');
  r := public.exos_guest_check_in('e1d00000-0000-0000-0000-0000000000d2', 1, 'e1d00000-0000-0000-0000-0000000000e1',
         gen_random_uuid(), 'offline-sync', now());
  ASSERT r ->> 'reason' = 'not-assigned', 'P5 scope kept: ' || r::text;
  ASSERT (SELECT count(*) FROM pg_proc WHERE proname = 'exos_guest_check_in' AND pronamespace = 'public'::regnamespace) = 1,
    'P5 one exos_guest_check_in';
  ASSERT NOT has_function_privilege('anon', 'public.exos_guest_check_in(uuid, integer, uuid, uuid, text, timestamptz)', 'EXECUTE'), 'P5 anon';
  ASSERT has_function_privilege('authenticated', 'public.exos_guest_check_in(uuid, integer, uuid, uuid, text, timestamptz)', 'EXECUTE'), 'P5 grant';
  RAISE NOTICE 'P5 ok: guest arrivals replay with their scan time';
END $$;

-- P6. The summary counts guests.
DO $$
DECLARE s jsonb; g jsonb;
BEGIN
  PERFORM pg_temp.act('e1d00000-0000-0000-0000-0000000000a1');
  s := public.exos_event_door_summary('e1d00000-0000-0000-0000-0000000000e1');
  g := s -> 'guests';
  -- Gina 2/2, Dee 0/1, Eve 1/1 (on Eventbrite's app), Olly 1/1; Val voided, never came: left out.
  ASSERT (g ->> 'entries')::int = 4, 'P6 entries ' || g::text;
  ASSERT (g ->> 'expected')::int = 5, 'P6 expected ' || g::text;
  ASSERT (g ->> 'arrived')::int = 4, 'P6 arrived ' || g::text;
  ASSERT (g ->> 'eventbrite_app')::int = 1, 'P6 eventbrite app ' || g::text;
  ASSERT (g ->> 'offline')::int = 2, 'P6 offline heads (Olly, and Gina''s fast-clock one) ' || g::text;
  ASSERT (SELECT (x ->> 'arrived')::int FROM jsonb_array_elements(g -> 'by_source') x WHERE x ->> 'source' = 'Guest list') = 2, 'P6 list';
  ASSERT (SELECT (x ->> 'expected')::int FROM jsonb_array_elements(g -> 'by_source') x WHERE x ->> 'source' = 'DICE') = 2, 'P6 DICE';
  ASSERT (SELECT (x ->> 'arrived')::int FROM jsonb_array_elements(g -> 'by_source') x WHERE x ->> 'source' = 'Eventbrite') = 1, 'P6 EB';
  -- An event with no guest lists: null, and the ticket numbers are as before.
  s := public.exos_event_door_summary('e1d00000-0000-0000-0000-0000000000e2');
  ASSERT s -> 'guests' = 'null'::jsonb OR NOT s ? 'guests', 'P6 no lists: null';
  ASSERT NOT has_function_privilege('authenticated', 'public._exos_door_guest_summary(uuid)', 'EXECUTE'), 'P6 helper internal';
  RAISE NOTICE 'P6 ok: guest-list, imported and Eventbrite arrivals in the summary';
END $$;

-- P7. Roster pages.
DO $$
DECLARE a uuid; pg uuid[]; pages int := 0; ids uuid[] := '{}'; full_ids uuid[];
BEGIN
  PERFORM pg_temp.act('e1d00000-0000-0000-0000-0000000000a3');
  SELECT array_agg(ticket_id ORDER BY ticket_id) INTO full_ids
    FROM public.exos_event_door_roster('e1d00000-0000-0000-0000-0000000000e1');
  ASSERT array_length(full_ids, 1) = 12, 'P7 unpaged form: every ticket';
  LOOP
    pg := ARRAY(SELECT ticket_id FROM public.exos_event_door_roster_page('e1d00000-0000-0000-0000-0000000000e1', NULL, a, 5));
    EXIT WHEN coalesce(array_length(pg, 1), 0) = 0;
    pages := pages + 1;
    ids := ids || pg;
    a := pg[array_length(pg, 1)];
  END LOOP;
  ASSERT pages = 3 AND array_length(ids, 1) = 12, 'P7 3 pages of 5/5/2: ' || pages;
  ASSERT ids = full_ids, 'P7 pages = the unpaged rows, in order';
  ASSERT (SELECT door_keys IS NOT NULL AND NOT door_keys::text ILIKE '%sek-%'
            FROM public.exos_event_door_roster_page('e1d00000-0000-0000-0000-0000000000e1', NULL, NULL, 1)), 'P7 keys, never the secret';
  ASSERT (SELECT count(*) FROM public.exos_event_door_roster_page('e1d00000-0000-0000-0000-0000000000e1', now() + interval '1 minute', NULL, 100)) = 0,
    'P7 since form: nothing changed';
  UPDATE public.exos_tickets SET tier_name = 'GA+' WHERE id = pg_temp.tk(12);
  ASSERT (SELECT array_agg(ticket_id) FROM public.exos_event_door_roster_page('e1d00000-0000-0000-0000-0000000000e1', now() - interval '1 second', NULL, 100))
         @> ARRAY[pg_temp.tk(12)], 'P7 since form: the changed ticket';
  PERFORM pg_temp.act('e1d00000-0000-0000-0000-0000000000a4');
  BEGIN
    PERFORM * FROM public.exos_event_door_roster_page('e1d00000-0000-0000-0000-0000000000e1', NULL, NULL, 5);
    RAISE EXCEPTION 'P7 a4 should be refused';
  EXCEPTION WHEN insufficient_privilege THEN
    ASSERT SQLERRM ILIKE '%not assigned%', 'P7 not assigned: ' || SQLERRM;
  END;
  ASSERT NOT has_function_privilege('anon', 'public.exos_event_door_roster_page(uuid, timestamptz, uuid, integer)', 'EXECUTE'), 'P7 anon';
  ASSERT has_function_privilege('authenticated', 'public.exos_event_door_roster_page(uuid, timestamptz, uuid, integer)', 'EXECUTE'), 'P7 grant';
  RAISE NOTICE 'P7 ok: the roster pages inside the function';
END $$;

-- P8. Wallet push queue: Apple and Google apart.
INSERT INTO public.exos_tickets(id,event_id,org_id,tier_name,buyer_id,owner_id,buyer_email,status,barcode_secret,price_paid,order_ref,channel_source)
SELECT ('e1d00000-0000-0000-0000-' || lpad(k::text, 12, '0'))::uuid, 'e1d00000-0000-0000-0000-0000000000e2',
       'e1d00000-0000-0000-0000-000000000001', 'GA', 'e1d00000-0000-0000-0000-0000000000a5', 'e1d00000-0000-0000-0000-0000000000a5',
       'doorp1hold@x.com', 'active', 'wsek-' || k, 50, 'w-' || k, 'stripe'
  FROM generate_series(100001, 100103) k;
-- 101 Apple passes with a device (oldest), one Google pass, one Apple + Google pass.
INSERT INTO public.exos_wallet_passes(serial_number, ticket_id, owner_id, pass_type_identifier, apple_issued_at, google_issued_at,
                                      push_pending, updated_at)
SELECT 'exw' || md5('p1w' || k), ('e1d00000-0000-0000-0000-' || lpad(k::text, 12, '0'))::uuid, 'e1d00000-0000-0000-0000-0000000000a5',
       CASE WHEN k <= 100101 OR k = 100103 THEN 'pass.com.exos.test' END,
       CASE WHEN k <= 100101 OR k = 100103 THEN now() END,
       CASE WHEN k >= 100102 THEN now() END,
       true, now() - make_interval(mins => 200 - (k - 100000))
  FROM generate_series(100001, 100103) k;
INSERT INTO public.exos_wallet_registrations(device_library_id, pass_type_identifier, serial_number, push_token)
SELECT 'dev-' || k, 'pass.com.exos.test', 'exw' || md5('p1w' || k), 'tok-' || k
  FROM generate_series(100001, 100103) k WHERE k <= 100101 OR k = 100103;
DO $$
DECLARE q jsonb; g_only text := 'exw' || md5('p1w' || 100102); both_ text := 'exw' || md5('p1w' || 100103);
BEGIN
  q := public.exos_wallet_push_queue(100);
  ASSERT EXISTS (SELECT 1 FROM jsonb_array_elements(q -> 'passes') x WHERE x ->> 'serial' = g_only AND (x ->> 'google')::boolean),
    'P8 the Google pass behind 101 Apple ones is in the queue';
  ASSERT EXISTS (SELECT 1 FROM jsonb_array_elements(q -> 'passes') x WHERE x ->> 'serial' = both_ AND (x ->> 'google')::boolean),
    'P8 the Apple + Google pass is in the Google window';
  ASSERT (SELECT count(*) FROM jsonb_array_elements(q -> 'passes') x
           WHERE jsonb_array_length(x -> 'push_tokens') > 0 AND NOT (x ->> 'google')::boolean) = 100,
    'P8 Apple window still 100';
  ASSERT (SELECT count(*) FROM jsonb_array_elements(q -> 'passes') x WHERE NOT (x ->> 'google')::boolean
            AND x ->> 'serial' IN (g_only, both_)) = 0, 'P8 google flag';
  -- Google done for the Apple + Google pass (Apple still dry run): it leaves the Google window, stays pending.
  ASSERT public.exos_wallet_google_done(ARRAY[both_], (q ->> 'queued_at')::timestamptz) = 1, 'P8 google done';
  q := public.exos_wallet_push_queue(100);
  ASSERT NOT EXISTS (SELECT 1 FROM jsonb_array_elements(q -> 'passes') x WHERE x ->> 'serial' = both_ AND (x ->> 'google')::boolean),
    'P8 not due for Google any more';
  ASSERT (SELECT push_pending FROM public.exos_wallet_passes WHERE serial_number = both_), 'P8 still waits for Apple';
  -- A later change makes Google due again.
  UPDATE public.exos_wallet_passes SET updated_at = clock_timestamp() + interval '1 second' WHERE serial_number = both_;
  q := public.exos_wallet_push_queue(100);
  ASSERT EXISTS (SELECT 1 FROM jsonb_array_elements(q -> 'passes') x WHERE x ->> 'serial' = both_ AND (x ->> 'google')::boolean),
    'P8 due again after a change';
  -- push_done clears it and stamps Google too.
  ASSERT public.exos_wallet_push_done(ARRAY[g_only], clock_timestamp()) = 1, 'P8 push done';
  ASSERT (SELECT NOT push_pending AND google_pushed_at IS NOT NULL FROM public.exos_wallet_passes WHERE serial_number = g_only), 'P8 cleared';
  ASSERT NOT has_function_privilege('authenticated', 'public.exos_wallet_google_done(text[], timestamptz)', 'EXECUTE'), 'P8 grants';
  ASSERT has_function_privilege('service_role', 'public.exos_wallet_google_done(text[], timestamptz)', 'EXECUTE'), 'P8 service';
  RAISE NOTICE 'P8 ok: Apple dry run no longer starves Google wallet updates';
END $$;

\echo test_door_p1: all passed
ROLLBACK;
