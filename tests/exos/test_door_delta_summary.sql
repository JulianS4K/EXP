-- ============================================================================
-- Roster delta + end-of-night door summary (mig 20261008090000):
--   R1 a since with nothing changed returns nothing
--   R2 a ticket update (status, attendee name) is in the delta, and its row
--      matches the full roster's
--   R3 a check-in row alone (an exit on a re-entry list) brings its ticket
--   R4 a profile name change brings the holder's tickets; a pending
--      transfer change brings its ticket
--   R5 since must be set and within 7 days
--   R6 gate: anon, an outsider, a scanner assigned elsewhere, finance are
--      refused; an unscoped scanner and the owner are not
--   S1 tickets: sold, voided, checked in (forced included), no-shows
--   S2 entries: first, re-entries, exits, forced, offline, by verification
--   S3 first / last entry, peak 15 minutes, by hour in the event's zone
--   S4 by ticket type, by list, by staff (entries + refused), overrides,
--      conflicts, refused by reason, inside now
--   S5 gate: owner, manager, finance, unscoped scanner in; scoped scanner
--      elsewhere, outsider, anon out
--   S6 grants
-- Self-contained (BEGIN / ROLLBACK). Org d2…01 owned by …a1; manager …a2,
-- scanner …a3 (unscoped), scanner …a4 (assigned to e2 only), holder …a5,
-- outsider …a6 (owns org d2…02), finance …a8.
-- ============================================================================
\set ON_ERROR_STOP on
BEGIN;

CREATE TABLE IF NOT EXISTS public.exos_profiles (
  id uuid PRIMARY KEY, display_name text, updated_at timestamptz NOT NULL DEFAULT now());

INSERT INTO auth.users(id,email,email_confirmed_at) VALUES
  ('d2000000-0000-0000-0000-0000000000a1','d2own@x.com',now()),
  ('d2000000-0000-0000-0000-0000000000a2','d2mgr@x.com',now()),
  ('d2000000-0000-0000-0000-0000000000a3','d2scan@x.com',now()),
  ('d2000000-0000-0000-0000-0000000000a4','d2scan2@x.com',now()),
  ('d2000000-0000-0000-0000-0000000000a5','d2hold@x.com',now()),
  ('d2000000-0000-0000-0000-0000000000a6','d2out@x.com',now()),
  ('d2000000-0000-0000-0000-0000000000a8','d2fin@x.com',now());
INSERT INTO public.exos_orgs(id,name,slug,owner_uid) VALUES
  ('d2000000-0000-0000-0000-000000000001','Delta Org','delta-org-stub','d2000000-0000-0000-0000-0000000000a1'),
  ('d2000000-0000-0000-0000-000000000002','Other Org','delta-other-stub','d2000000-0000-0000-0000-0000000000a6');
INSERT INTO public.exos_org_memberships(org_id,user_id,role) VALUES
  ('d2000000-0000-0000-0000-000000000001','d2000000-0000-0000-0000-0000000000a1','owner'),
  ('d2000000-0000-0000-0000-000000000001','d2000000-0000-0000-0000-0000000000a2','manager'),
  ('d2000000-0000-0000-0000-000000000001','d2000000-0000-0000-0000-0000000000a3','scanner'),
  ('d2000000-0000-0000-0000-000000000001','d2000000-0000-0000-0000-0000000000a4','scanner'),
  ('d2000000-0000-0000-0000-000000000001','d2000000-0000-0000-0000-0000000000a8','finance'),
  ('d2000000-0000-0000-0000-000000000002','d2000000-0000-0000-0000-0000000000a6','owner');
INSERT INTO public.exos_profiles(id, display_name) VALUES
  ('d2000000-0000-0000-0000-0000000000a3','Sam Scanner'),
  ('d2000000-0000-0000-0000-0000000000a5','Holly Holder')
  ON CONFLICT (id) DO NOTHING;
-- e1: the delta event. e2: where scanner a4 is assigned. e3: the summary
-- event, in New York time.
INSERT INTO public.exos_events(id,org_id,name,slug,status,starts_at,doors_at,ends_at,total_tickets,created_by,timezone) VALUES
  ('d2000000-0000-0000-0000-0000000000e1','d2000000-0000-0000-0000-000000000001','Delta One','delta-one-stub','published',
   now() + interval '1 hour', now() - interval '1 hour', now() + interval '6 hours', 0, 'd2000000-0000-0000-0000-0000000000a1', NULL),
  ('d2000000-0000-0000-0000-0000000000e2','d2000000-0000-0000-0000-000000000001','Delta Two','delta-two-stub','published',
   now() + interval '1 hour', now() - interval '1 hour', NULL, 0, 'd2000000-0000-0000-0000-0000000000a1', NULL),
  ('d2000000-0000-0000-0000-0000000000e3','d2000000-0000-0000-0000-000000000001','Summary Night','delta-sum-stub','published',
   '2026-10-03 00:00+00', '2026-10-02 23:00+00', '2026-10-03 04:00+00', 0, 'd2000000-0000-0000-0000-0000000000a1',
   'America/New_York');
INSERT INTO public.exos_ticket_tiers(id,event_id,name,price,capacity) VALUES
  ('d2000000-0000-0000-0000-0000000000f1','d2000000-0000-0000-0000-0000000000e1','GA',50,100),
  ('d2000000-0000-0000-0000-0000000000f3','d2000000-0000-0000-0000-0000000000e3','GA',50,100),
  ('d2000000-0000-0000-0000-0000000000f4','d2000000-0000-0000-0000-0000000000e3','VIP',150,20);
INSERT INTO public.exos_event_staff(event_id, user_id, org_id) VALUES
  ('d2000000-0000-0000-0000-0000000000e2','d2000000-0000-0000-0000-0000000000a4','d2000000-0000-0000-0000-000000000001');
INSERT INTO public.exos_checkin_lists(id,event_id,org_id,name,tier_ids,allow_reentry,sort_order) VALUES
  ('d2000000-0000-0000-0000-00000000aa01','d2000000-0000-0000-0000-0000000000e1',NULL,'Pass-out',NULL,true,0),
  ('d2000000-0000-0000-0000-00000000aa31','d2000000-0000-0000-0000-0000000000e3',NULL,'Main door',NULL,false,0),
  ('d2000000-0000-0000-0000-00000000aa32','d2000000-0000-0000-0000-0000000000e3',NULL,'Smoking deck',NULL,true,1);

-- Tickets: …c1001-c1004 on e1; …e0001-e0004 GA, …e0005-e0006 VIP,
-- …e0007 GA voided, …e0008 GA transferred away (not counted) on e3.
INSERT INTO public.exos_tickets(id,event_id,org_id,tier_id,tier_name,buyer_id,owner_id,buyer_email,status,barcode_secret,price_paid,order_ref,channel_source)
SELECT ('d2000000-0000-0000-0000-0000000' || k)::uuid,
       CASE left(k, 1) WHEN 'c' THEN 'd2000000-0000-0000-0000-0000000000e1'::uuid
                       ELSE 'd2000000-0000-0000-0000-0000000000e3'::uuid END,
       'd2000000-0000-0000-0000-000000000001',
       CASE WHEN left(k, 1) = 'c' THEN 'd2000000-0000-0000-0000-0000000000f1'::uuid
            WHEN k IN ('e0005','e0006') THEN 'd2000000-0000-0000-0000-0000000000f4'::uuid
            ELSE 'd2000000-0000-0000-0000-0000000000f3'::uuid END,
       CASE WHEN k IN ('e0005','e0006') THEN 'VIP' ELSE 'GA' END,
       'd2000000-0000-0000-0000-0000000000a5', 'd2000000-0000-0000-0000-0000000000a5', 'd2hold@x.com',
       CASE k WHEN 'e0007' THEN 'voided' WHEN 'e0008' THEN 'transferred' ELSE 'active' END,
       'sek-' || k, 50, 'web-' || k, 'stripe'
  FROM unnest(ARRAY['c1001','c1002','c1003','c1004',
                    'e0001','e0002','e0003','e0004','e0005','e0006','e0007','e0008']) k;

CREATE FUNCTION pg_temp.act(p_uid text) RETURNS void LANGUAGE sql AS $$
  SELECT set_config('app.uid', coalesce(p_uid, ''), false), set_config('app.jwt', '{"email":"door@x.com"}', false);
$$;
CREATE FUNCTION pg_temp.tk(p_suffix text) RETURNS uuid LANGUAGE sql IMMUTABLE AS $$
  SELECT ('d2000000-0000-0000-0000-0000000' || p_suffix)::uuid;
$$;
CREATE FUNCTION pg_temp.delta(p_since timestamptz) RETURNS SETOF uuid LANGUAGE sql AS $$
  SELECT ticket_id FROM public.exos_event_checkin_roster_since('d2000000-0000-0000-0000-0000000000e1', p_since) ORDER BY 1;
$$;

-- Everything on e1 "happened" two hours ago (the touch trigger would stamp
-- now(), so it is bypassed for the back-dating).
SET LOCAL session_replication_role = replica;
UPDATE public.exos_tickets SET updated_at = now() - interval '2 hours'
 WHERE event_id = 'd2000000-0000-0000-0000-0000000000e1';
UPDATE public.exos_profiles SET updated_at = now() - interval '2 hours'
 WHERE id::text LIKE 'd2000000%';
SET LOCAL session_replication_role = origin;

-- R1. Nothing changed in the last hour.
DO $$
BEGIN
  PERFORM pg_temp.act('d2000000-0000-0000-0000-0000000000a3');
  ASSERT (SELECT count(*) FROM pg_temp.delta(now() - interval '1 hour')) = 0, 'R1: no changes, no rows';
  ASSERT (SELECT count(*) FROM pg_temp.delta(now() - interval '3 hours')) = 4, 'R1: everything since before the sale';
END $$;

-- R2. Ticket updates.
DO $$
DECLARE a record; b record;
BEGIN
  PERFORM pg_temp.act(NULL);
  UPDATE public.exos_tickets SET status = 'voided' WHERE id = pg_temp.tk('c1002');
  PERFORM pg_temp.act('d2000000-0000-0000-0000-0000000000a3');
  ASSERT array(SELECT pg_temp.delta(now() - interval '1 hour')) = ARRAY[pg_temp.tk('c1002')],
         'R2: the voided ticket only, got ' || array(SELECT pg_temp.delta(now() - interval '1 hour'))::text;
  SELECT * INTO a FROM public.exos_event_checkin_roster('d2000000-0000-0000-0000-0000000000e1') WHERE ticket_id = pg_temp.tk('c1002');
  SELECT * INTO b FROM public.exos_event_checkin_roster_since('d2000000-0000-0000-0000-0000000000e1', now() - interval '1 hour');
  ASSERT row_to_json(a)::jsonb = row_to_json(b)::jsonb, 'R2: same row as the full roster: ' || row_to_json(b)::text;
  ASSERT b.status = 'voided' AND b.owner_name = 'Holly Holder' AND b.barcode_secret = 'sek-c1002', 'R2: columns';
END $$;

-- R3. A check-in row alone (no ticket update: an exit on a re-entry list).
SET LOCAL session_replication_role = replica;
INSERT INTO public.exos_event_checkins(event_id,ticket_id,org_id,scanned_by,source,verification,list_id,direction,gate)
VALUES ('d2000000-0000-0000-0000-0000000000e1', pg_temp.tk('c1003'), 'd2000000-0000-0000-0000-000000000001',
        'd2000000-0000-0000-0000-0000000000a3', 'camera', 'verified',
        'd2000000-0000-0000-0000-00000000aa01', 'exit', 'Pass-out');
SET LOCAL session_replication_role = origin;
DO $$
DECLARE r record;
BEGIN
  PERFORM pg_temp.act('d2000000-0000-0000-0000-0000000000a3');
  ASSERT (SELECT updated_at FROM public.exos_tickets WHERE id = pg_temp.tk('c1003')) < now() - interval '1 hour',
         'R3: the ticket row did not move';
  ASSERT array(SELECT pg_temp.delta(now() - interval '1 hour')) = ARRAY[pg_temp.tk('c1002'), pg_temp.tk('c1003')],
         'R3: the scanned ticket joins the delta';
  SELECT * INTO r FROM public.exos_event_checkin_roster_since('d2000000-0000-0000-0000-0000000000e1', now() - interval '1 hour')
   WHERE ticket_id = pg_temp.tk('c1003');
  ASSERT r.list_state = jsonb_build_object('d2000000-0000-0000-0000-00000000aa01', 'exit'), 'R3: list state';
END $$;

-- R4. A holder's profile name; a pending transfer.
DO $$
BEGIN
  PERFORM pg_temp.act(NULL);
  -- c1004 moves to a new holder whose profile is stale, so only the
  -- profile and transfer touches can bring it back below.
  SET LOCAL session_replication_role = replica;
  INSERT INTO public.exos_profiles(id, display_name, updated_at)
  VALUES ('d2000000-0000-0000-0000-0000000000a6', 'Other Person', now() - interval '2 hours')
  ON CONFLICT (id) DO UPDATE SET updated_at = now() - interval '2 hours';
  INSERT INTO public.exos_transfers(id,ticket_id,org_id,sender_id,receiver_email,status,event_id,created_at,updated_at) VALUES
    ('d2000000-0000-0000-0000-0000000007a1', pg_temp.tk('c1004'), 'd2000000-0000-0000-0000-000000000001',
     'd2000000-0000-0000-0000-0000000000a5', 'friend@x.com', 'pending', 'd2000000-0000-0000-0000-0000000000e1',
     now() - interval '2 hours', now() - interval '2 hours');
  UPDATE public.exos_tickets SET pending_transfer_id = 'd2000000-0000-0000-0000-0000000007a1',
                                 updated_at = now() - interval '2 hours'
   WHERE id = pg_temp.tk('c1004');
  SET LOCAL session_replication_role = origin;
  PERFORM pg_temp.act('d2000000-0000-0000-0000-0000000000a3');
  ASSERT NOT (pg_temp.tk('c1004') = ANY (array(SELECT pg_temp.delta(now() - interval '1 hour')))), 'R4: not yet';
  PERFORM pg_temp.act(NULL);
  UPDATE public.exos_transfers SET receiver_name = 'Pat Friend' WHERE id = 'd2000000-0000-0000-0000-0000000007a1';
  PERFORM pg_temp.act('d2000000-0000-0000-0000-0000000000a3');
  ASSERT pg_temp.tk('c1004') = ANY (array(SELECT pg_temp.delta(now() - interval '1 hour'))), 'R4: transfer change';
  -- c1001's holder renames themselves.
  ASSERT NOT (pg_temp.tk('c1001') = ANY (array(SELECT pg_temp.delta(now() - interval '1 hour')))), 'R4: c1001 not yet';
  PERFORM pg_temp.act(NULL);
  UPDATE public.exos_profiles SET display_name = 'Holly H.', updated_at = now() WHERE id = 'd2000000-0000-0000-0000-0000000000a5';
  PERFORM pg_temp.act('d2000000-0000-0000-0000-0000000000a3');
  ASSERT pg_temp.tk('c1001') = ANY (array(SELECT pg_temp.delta(now() - interval '1 hour'))), 'R4: profile change';
END $$;

-- R5. since must be set and recent.
DO $$
BEGIN
  PERFORM pg_temp.act('d2000000-0000-0000-0000-0000000000a3');
  BEGIN
    PERFORM pg_temp.delta(NULL);
    RAISE EXCEPTION 'R5: a NULL since was accepted';
  EXCEPTION WHEN invalid_parameter_value THEN NULL;
  END;
  BEGIN
    PERFORM pg_temp.delta(now() - interval '8 days');
    RAISE EXCEPTION 'R5: an 8-day since was accepted';
  EXCEPTION WHEN invalid_parameter_value THEN NULL;
  END;
END $$;

-- R6. Gate.
DO $$
DECLARE u text;
BEGIN
  FOREACH u IN ARRAY ARRAY['', 'd2000000-0000-0000-0000-0000000000a6', 'd2000000-0000-0000-0000-0000000000a4',
                           'd2000000-0000-0000-0000-0000000000a8'] LOOP
    PERFORM pg_temp.act(nullif(u, ''));
    BEGIN
      PERFORM pg_temp.delta(now() - interval '1 hour');
      RAISE EXCEPTION 'R6: % read the delta', coalesce(nullif(u, ''), 'anon');
    EXCEPTION WHEN insufficient_privilege THEN NULL;
    END;
  END LOOP;
  PERFORM pg_temp.act('d2000000-0000-0000-0000-0000000000a1');
  ASSERT (SELECT count(*) FROM pg_temp.delta(now() - interval '1 hour')) >= 2, 'R6: the owner reads it';
END $$;

-- Summary night (e3, New York; 2026-10-02 20:00 EDT = 2026-10-03 00:00Z):
--   e0001 GA   entry 23:10Z Main door (verified, scanner a3)
--   e0002 GA   entry 23:20Z Main door (manual "Phone died", manager a2)
--   e0003 GA   entry 23:22Z Main door (name, a3, offline scan time 23:21Z)
--   e0005 VIP  entry 23:25Z Smoking deck (verified, a3), exit 00:30Z, entry 00:45Z
--   e0007 GA   (voided) forced entry 23:24Z conflict 'voided' (a3, offline)
--   e0004, e0006: no-shows. e0008 transferred: not counted.
--   refused: 2 'used' (a3), 1 'invalid-barcode' (a2).
SET LOCAL session_replication_role = replica;
INSERT INTO public.exos_event_checkins(event_id,ticket_id,org_id,scanned_by,scanned_by_email,source,verification,
                                       scanned_at,offline_scanned_at,override_reason,list_id,direction,gate,forced,conflict)
SELECT 'd2000000-0000-0000-0000-0000000000e3', pg_temp.tk(k), 'd2000000-0000-0000-0000-000000000001',
       by::uuid, em, src, ver, at::timestamptz, off::timestamptz, why, lst::uuid, dir, gate, f, cf
  FROM (VALUES
    ('e0001','d2000000-0000-0000-0000-0000000000a3','d2scan@x.com','camera','verified','2026-10-02 23:10+00',NULL,NULL,
     'd2000000-0000-0000-0000-00000000aa31','entry','Main door',false,NULL),
    ('e0002','d2000000-0000-0000-0000-0000000000a2','d2mgr@x.com','manual','manual','2026-10-02 23:20+00',NULL,'Phone died',
     'd2000000-0000-0000-0000-00000000aa31','entry','Main door',false,NULL),
    ('e0003','d2000000-0000-0000-0000-0000000000a3','d2scan@x.com','manual','name','2026-10-02 23:40+00','2026-10-02 23:21+00',NULL,
     'd2000000-0000-0000-0000-00000000aa31','entry','Main door',false,NULL),
    ('e0005','d2000000-0000-0000-0000-0000000000a3','d2scan@x.com','camera','verified','2026-10-02 23:25+00',NULL,NULL,
     'd2000000-0000-0000-0000-00000000aa32','entry','Smoking deck',false,NULL),
    ('e0005','d2000000-0000-0000-0000-0000000000a3','d2scan@x.com','camera','verified','2026-10-03 00:30+00',NULL,NULL,
     'd2000000-0000-0000-0000-00000000aa32','exit','Smoking deck',false,NULL),
    ('e0005','d2000000-0000-0000-0000-0000000000a3','d2scan@x.com','camera','verified','2026-10-03 00:45+00',NULL,NULL,
     'd2000000-0000-0000-0000-00000000aa32','entry','Smoking deck',false,NULL),
    ('e0007','d2000000-0000-0000-0000-0000000000a3','d2scan@x.com','camera','verified','2026-10-02 23:50+00','2026-10-02 23:24+00',NULL,
     'd2000000-0000-0000-0000-00000000aa31','entry','Main door',true,'voided')
  ) v(k, by, em, src, ver, at, off, why, lst, dir, gate, f, cf);
UPDATE public.exos_tickets SET status = 'used' WHERE id IN (pg_temp.tk('e0001'), pg_temp.tk('e0002'), pg_temp.tk('e0003'), pg_temp.tk('e0005'));
INSERT INTO public.exos_scan_rejects(event_id,org_id,rejected_by,reason,source,rejected_at) VALUES
  ('d2000000-0000-0000-0000-0000000000e3','d2000000-0000-0000-0000-000000000001','d2000000-0000-0000-0000-0000000000a3','used','camera','2026-10-02 23:30+00'),
  ('d2000000-0000-0000-0000-0000000000e3','d2000000-0000-0000-0000-000000000001','d2000000-0000-0000-0000-0000000000a3','used','camera','2026-10-02 23:31+00'),
  ('d2000000-0000-0000-0000-0000000000e3','d2000000-0000-0000-0000-000000000001','d2000000-0000-0000-0000-0000000000a2','invalid-barcode','camera','2026-10-02 23:32+00');
SET LOCAL session_replication_role = origin;

CREATE FUNCTION pg_temp.sum() RETURNS jsonb LANGUAGE sql AS $$
  SELECT public.exos_event_door_summary('d2000000-0000-0000-0000-0000000000e3');
$$;

-- S1-S4.
DO $$
DECLARE s jsonb;
BEGIN
  PERFORM pg_temp.act('d2000000-0000-0000-0000-0000000000a1');
  s := pg_temp.sum();
  ASSERT s->'event'->>'timezone' = 'America/New_York', 'S1: zone';
  ASSERT s->'tickets' = '{"sold":6,"voided":1,"checked_in":4,"no_shows":2,"voided_entered":1}'::jsonb,
         'S1: tickets ' || (s->'tickets')::text;
  ASSERT s->'entries' = '{"total":6,"first":5,"reentries":1,"exits":1,"forced":1,"offline":2,
                          "by_verification":{"verified":3,"manual":1,"name":1}}'::jsonb,
         'S2: entries ' || (s->'entries')::text;
  ASSERT (s->>'first_entry_at')::timestamptz = '2026-10-02 23:10+00', 'S3: first entry';
  ASSERT (s->>'last_entry_at')::timestamptz = '2026-10-03 00:45+00', 'S3: last entry';
  ASSERT (s->'peak'->>'start')::timestamptz = '2026-10-02 23:15+00' AND (s->'peak'->>'entries')::int = 4,
         'S3: peak ' || (s->'peak')::text;
  ASSERT s->'by_hour' = '[{"hour":"2026-10-02T19:00","entries":5},{"hour":"2026-10-02T20:00","entries":1}]'::jsonb,
         'S3: by hour (New York) ' || (s->'by_hour')::text;
  ASSERT s->'by_tier' = '[{"tier":"GA","sold":4,"checked_in":3},{"tier":"VIP","sold":2,"checked_in":1}]'::jsonb,
         'S4: by tier ' || (s->'by_tier')::text;
  ASSERT s->'by_list' = '[{"list":"Main door","entries":4,"exits":0},{"list":"Smoking deck","entries":2,"exits":1}]'::jsonb,
         'S4: by list ' || (s->'by_list')::text;
  ASSERT s->'by_staff' = '[{"staff":"Sam Scanner","entries":5,"refused":2},{"staff":"d***@x.com","entries":1,"refused":1}]'::jsonb,
         'S4: by staff ' || (s->'by_staff')::text;
  ASSERT s->'overrides' = '[{"reason":"Phone died","count":1}]'::jsonb, 'S4: overrides';
  ASSERT s->'conflicts' = '[{"reason":"voided","count":1}]'::jsonb, 'S4: conflicts';
  ASSERT s->'refused' = '{"total":3,"by_reason":[{"reason":"used","count":2},{"reason":"invalid-barcode","count":1}]}'::jsonb,
         'S4: refused ' || (s->'refused')::text;
  ASSERT (s->>'inside_now')::int = 1, 'S4: inside now (re-entry list) ' || coalesce(s->>'inside_now', 'null');
  ASSERT position('d2hold' in s::text) = 0 AND position('Holly' in s::text) = 0, 'S4: no buyer data';
END $$;

-- S4b. No re-entry list: inside_now is null; an empty night is all zeros.
DO $$
DECLARE s jsonb;
BEGIN
  PERFORM pg_temp.act('d2000000-0000-0000-0000-0000000000a1');
  s := public.exos_event_door_summary('d2000000-0000-0000-0000-0000000000e2');
  ASSERT s->'inside_now' = 'null'::jsonb, 'S4b: no re-entry list';
  ASSERT s->'tickets' = '{"sold":0,"voided":0,"checked_in":0,"no_shows":0,"voided_entered":0}'::jsonb, 'S4b: empty';
  ASSERT s->'peak' = 'null'::jsonb AND s->'by_hour' = '[]'::jsonb AND s->'by_staff' = '[]'::jsonb, 'S4b: empty lists';
  ASSERT s->'event'->>'timezone' = 'UTC', 'S4b: no zone = UTC';
END $$;

-- S5. Gate.
DO $$
DECLARE u text;
BEGIN
  FOREACH u IN ARRAY ARRAY['d2000000-0000-0000-0000-0000000000a1','d2000000-0000-0000-0000-0000000000a2',
                           'd2000000-0000-0000-0000-0000000000a3','d2000000-0000-0000-0000-0000000000a8'] LOOP
    PERFORM pg_temp.act(u);
    ASSERT (pg_temp.sum()->'tickets'->>'sold')::int = 6, 'S5: ' || u || ' reads it';
  END LOOP;
  FOREACH u IN ARRAY ARRAY['', 'd2000000-0000-0000-0000-0000000000a4', 'd2000000-0000-0000-0000-0000000000a6'] LOOP
    PERFORM pg_temp.act(nullif(u, ''));
    BEGIN
      PERFORM pg_temp.sum();
      RAISE EXCEPTION 'S5: % read the summary', coalesce(nullif(u, ''), 'anon');
    EXCEPTION WHEN insufficient_privilege THEN NULL;
    END;
  END LOOP;
END $$;

-- S6. Grants.
DO $$
DECLARE f text;
BEGIN
  FOREACH f IN ARRAY ARRAY['public.exos_event_checkin_roster_since(uuid,timestamptz)',
                           'public.exos_event_door_summary(uuid)'] LOOP
    ASSERT has_function_privilege('authenticated', f, 'EXECUTE'), 'S6: authenticated calls ' || f;
    ASSERT NOT has_function_privilege('anon', f, 'EXECUTE'), 'S6: anon may not call ' || f;
  END LOOP;
  ASSERT EXISTS (SELECT 1 FROM pg_trigger WHERE tgrelid = 'public.exos_tickets'::regclass AND tgname = 'exos_tickets_touch'),
         'S6: ticket touch trigger';
END $$;

\echo 'test_door_delta_summary: all passed'
ROLLBACK;
