-- ============================================================================
-- Check-in lists, optional re-entry, forced offline conflicts
-- (mig 20260929140000):
--   L1 lists by tier: wrong-list, unknown-list, a VIP list admits VIP
--   L2 time window: before valid_from / after valid_until is invalid-time
--   L3 re-entry off = today's behaviour: used is refused, exits refused
--   L4 re-entry on: entry / already-inside / exit / entry again; the ticket
--      is used once (check_in_at = first entry), the webhook fires once
--   L5 old calls with no list (the 8 / 8 / 6 argument versions, positional
--      and named) unchanged
--   L6 offline replays the server refuses are recorded as forced (voided,
--      wrong list, too old, post-transfer, by-name voided); used and future
--      scans are not; the widened window (event end + 48 h); an offline
--      entry / exit / entry sequence on a re-entry list
--   L7 scanner scope: a scanner assigned elsewhere gets not-assigned and
--      writes nothing
--   L8 RLS on exos_checkin_lists (owner / manager write, door staff read,
--      scoped scanners and outsiders don't) + the scope trigger
--   L9 roster: tier_id + list_state
--   L10 grants, old signatures kept, overloads without defaults, helpers private
--   L11 reports: analytics counts entries only; _exos_used_answer points at
--       an entry; undo removes exits too
-- Self-contained (BEGIN / ROLLBACK). Org d1…01 owned by …a1; manager …a2,
-- scanner …a3 (unscoped), scanner …a4 (assigned to e2 only), holder …a5,
-- new holder …a7, outsider …a6 (owns org d1…02).
-- ============================================================================
\set ON_ERROR_STOP on
BEGIN;

CREATE TABLE IF NOT EXISTS public.exos_profiles (id uuid PRIMARY KEY, display_name text);

INSERT INTO auth.users(id,email,email_confirmed_at) VALUES
  ('d1000000-0000-0000-0000-0000000000a1','d1own@x.com',now()),
  ('d1000000-0000-0000-0000-0000000000a2','d1mgr@x.com',now()),
  ('d1000000-0000-0000-0000-0000000000a3','d1scan@x.com',now()),
  ('d1000000-0000-0000-0000-0000000000a4','d1scan2@x.com',now()),
  ('d1000000-0000-0000-0000-0000000000a5','d1hold@x.com',now()),
  ('d1000000-0000-0000-0000-0000000000a6','d1out@x.com',now()),
  ('d1000000-0000-0000-0000-0000000000a7','d1new@x.com',now());
INSERT INTO public.exos_orgs(id,name,slug,owner_uid) VALUES
  ('d1000000-0000-0000-0000-000000000001','Lists Org','lists-org-stub','d1000000-0000-0000-0000-0000000000a1'),
  ('d1000000-0000-0000-0000-000000000002','Other Org','lists-other-stub','d1000000-0000-0000-0000-0000000000a6');
INSERT INTO public.exos_org_memberships(org_id,user_id,role) VALUES
  ('d1000000-0000-0000-0000-000000000001','d1000000-0000-0000-0000-0000000000a1','owner'),
  ('d1000000-0000-0000-0000-000000000001','d1000000-0000-0000-0000-0000000000a2','manager'),
  ('d1000000-0000-0000-0000-000000000001','d1000000-0000-0000-0000-0000000000a3','scanner'),
  ('d1000000-0000-0000-0000-000000000001','d1000000-0000-0000-0000-0000000000a4','scanner'),
  ('d1000000-0000-0000-0000-000000000002','d1000000-0000-0000-0000-0000000000a6','owner');
-- e1: doors open, on tonight. e2: another event of the org. e3: ended four
-- days ago. e4: ended an hour ago. e9: the other org's.
INSERT INTO public.exos_events(id,org_id,name,slug,status,starts_at,doors_at,ends_at,total_tickets,created_by) VALUES
  ('d1000000-0000-0000-0000-0000000000e1','d1000000-0000-0000-0000-000000000001','Lists One','lists-one-stub','published',
   now() + interval '1 hour', now() - interval '1 hour', now() + interval '6 hours', 0, 'd1000000-0000-0000-0000-0000000000a1'),
  ('d1000000-0000-0000-0000-0000000000e2','d1000000-0000-0000-0000-000000000001','Lists Two','lists-two-stub','published',
   now() + interval '1 hour', now() - interval '1 hour', NULL, 0, 'd1000000-0000-0000-0000-0000000000a1'),
  ('d1000000-0000-0000-0000-0000000000e3','d1000000-0000-0000-0000-000000000001','Long Gone','lists-gone-stub','published',
   now() - interval '5 days', now() - interval '5 days', now() - interval '4 days', 0, 'd1000000-0000-0000-0000-0000000000a1'),
  ('d1000000-0000-0000-0000-0000000000e4','d1000000-0000-0000-0000-000000000001','Just Ended','lists-ended-stub','published',
   now() - interval '32 hours', now() - interval '32 hours', now() - interval '1 hour', 0, 'd1000000-0000-0000-0000-0000000000a1'),
  ('d1000000-0000-0000-0000-0000000000e9','d1000000-0000-0000-0000-000000000002','Elsewhere','lists-else-stub','published',
   now() + interval '1 hour', now() - interval '1 hour', NULL, 0, 'd1000000-0000-0000-0000-0000000000a6');
INSERT INTO public.exos_ticket_tiers(id,event_id,name,price,capacity) VALUES
  ('d1000000-0000-0000-0000-0000000000f1','d1000000-0000-0000-0000-0000000000e1','GA',50,100),
  ('d1000000-0000-0000-0000-0000000000f2','d1000000-0000-0000-0000-0000000000e1','VIP',150,20),
  ('d1000000-0000-0000-0000-0000000000f9','d1000000-0000-0000-0000-0000000000e2','GA two',50,100);
INSERT INTO public.exos_event_staff(event_id, user_id, org_id) VALUES
  ('d1000000-0000-0000-0000-0000000000e2','d1000000-0000-0000-0000-0000000000a4','d1000000-0000-0000-0000-000000000001');

-- Lists (as the owner would make them; the trigger sets org_id).
INSERT INTO public.exos_checkin_lists(id,event_id,org_id,name,tier_ids,allow_reentry,valid_from,valid_until,sort_order) VALUES
  ('d1000000-0000-0000-0000-00000000aa01','d1000000-0000-0000-0000-0000000000e1',NULL,' Main door ',NULL,false,NULL,NULL,0),
  ('d1000000-0000-0000-0000-00000000aa02','d1000000-0000-0000-0000-0000000000e1',NULL,'VIP deck',
   ARRAY['d1000000-0000-0000-0000-0000000000f2']::uuid[],true,NULL,NULL,1),
  ('d1000000-0000-0000-0000-00000000aa03','d1000000-0000-0000-0000-0000000000e1',NULL,'Late gate',NULL,false,
   now() + interval '2 hours',NULL,2),
  ('d1000000-0000-0000-0000-00000000aa04','d1000000-0000-0000-0000-0000000000e1',NULL,'Early gate',NULL,false,
   NULL,now() - interval '30 minutes',3),
  ('d1000000-0000-0000-0000-00000000aa05','d1000000-0000-0000-0000-0000000000e1',NULL,'Pass-out',NULL,true,NULL,NULL,4),
  ('d1000000-0000-0000-0000-00000000aa09','d1000000-0000-0000-0000-0000000000e2',NULL,'Two main',NULL,false,NULL,NULL,0);

-- Tickets (ids end in the kind): …c1001-c1006 GA on e1, …c2001-c2003 VIP on
-- e1, …c3001 GA voided, …c4001 GA transferred a5 -> a7 (secret rotated),
-- …c5001 on e3 (ended 4 days ago), …c6001 on e4 (ended an hour ago).
INSERT INTO public.exos_tickets(id,event_id,org_id,tier_id,tier_name,buyer_id,owner_id,buyer_email,status,barcode_secret,price_paid,order_ref,channel_source)
SELECT ('d1000000-0000-0000-0000-0000000' || k)::uuid,
       CASE left(k, 2) WHEN 'c5' THEN 'd1000000-0000-0000-0000-0000000000e3'::uuid
                       WHEN 'c6' THEN 'd1000000-0000-0000-0000-0000000000e4'::uuid
                       ELSE 'd1000000-0000-0000-0000-0000000000e1'::uuid END,
       'd1000000-0000-0000-0000-000000000001',
       CASE left(k, 2) WHEN 'c2' THEN 'd1000000-0000-0000-0000-0000000000f2'::uuid
                       WHEN 'c5' THEN NULL WHEN 'c6' THEN NULL
                       ELSE 'd1000000-0000-0000-0000-0000000000f1'::uuid END,
       CASE left(k, 2) WHEN 'c2' THEN 'VIP' ELSE 'GA' END,
       'd1000000-0000-0000-0000-0000000000a5',
       CASE WHEN k = 'c4001' THEN 'd1000000-0000-0000-0000-0000000000a7'::uuid
            ELSE 'd1000000-0000-0000-0000-0000000000a5'::uuid END,
       'd1hold@x.com',
       CASE WHEN k = 'c3001' THEN 'voided' ELSE 'active' END,
       'sek-' || k, 50, 'web-' || k, 'stripe'
  FROM unnest(ARRAY['c1001','c1002','c1003','c1004','c1005','c1006',
                    'c2001','c2002','c2003','c3001','c4001','c5001','c6001']) k;
INSERT INTO public.exos_transfers(id,ticket_id,org_id,sender_id,receiver_email,status,event_id,created_at,updated_at) VALUES
  ('d1000000-0000-0000-0000-0000000007a1','d1000000-0000-0000-0000-0000000c4001','d1000000-0000-0000-0000-000000000001',
   'd1000000-0000-0000-0000-0000000000a5','d1new@x.com','completed','d1000000-0000-0000-0000-0000000000e1',now(),now());

CREATE FUNCTION pg_temp.act(p_uid text) RETURNS void LANGUAGE sql AS $$
  SELECT set_config('app.uid', coalesce(p_uid, ''), false), set_config('app.jwt', '{"email":"door@x.com"}', false);
$$;
-- A signed T- code for (ticket, owner) with a secret, in the window of p_at.
CREATE FUNCTION pg_temp.code(p_ticket uuid, p_owner text, p_secret text, p_at timestamptz) RETURNS text
LANGUAGE sql AS $$
  SELECT 'T-' || p_ticket || ':' || p_owner || ':' || b || ':' ||
         rtrim(translate(encode(extensions.hmac(p_ticket || ':' || p_owner || ':' || b, p_secret, 'sha256'), 'base64'),
                         '+/', '-_'), '=')
    FROM (SELECT floor(extract(epoch FROM p_at) * 1000 / 30000)::bigint::text AS b) x;
$$;
CREATE FUNCTION pg_temp.tk(p_suffix text) RETURNS uuid LANGUAGE sql IMMUTABLE AS $$
  SELECT ('d1000000-0000-0000-0000-0000000' || p_suffix)::uuid;
$$;
CREATE FUNCTION pg_temp.scan(p_suffix text, p_list text DEFAULT NULL, p_dir text DEFAULT 'entry') RETURNS jsonb
LANGUAGE sql AS $$
  SELECT public.exos_check_in_ticket(pg_temp.tk(p_suffix), 'camera', 'verified',
           pg_temp.code(pg_temp.tk(p_suffix), 'd1000000-0000-0000-0000-0000000000a5', 'sek-' || p_suffix, now()),
           (SELECT event_id FROM public.exos_tickets WHERE id = pg_temp.tk(p_suffix)),
           NULL, NULL, 'Door L1',
           CASE WHEN p_list IS NULL THEN NULL ELSE ('d1000000-0000-0000-0000-00000000' || p_list)::uuid END,
           p_dir);
$$;

-- L1. Lists by tier.
DO $$
DECLARE r jsonb;
BEGIN
  PERFORM pg_temp.act('d1000000-0000-0000-0000-0000000000a3');
  ASSERT (SELECT org_id FROM public.exos_checkin_lists WHERE id = 'd1000000-0000-0000-0000-00000000aa01')
         = 'd1000000-0000-0000-0000-000000000001', 'L1: the trigger sets org_id from the event';
  ASSERT (SELECT name FROM public.exos_checkin_lists WHERE id = 'd1000000-0000-0000-0000-00000000aa01') = 'Main door',
         'L1: name trimmed';
  ASSERT NOT (SELECT allow_reentry FROM public.exos_checkin_lists WHERE id = 'd1000000-0000-0000-0000-00000000aa01'),
         'L1: re-entry is off unless turned on';
  r := pg_temp.scan('c1001', 'aa02');
  ASSERT r ->> 'reason' = 'wrong-list' AND r ->> 'list' = 'VIP deck', 'L1: GA on the VIP list is wrong-list, got ' || r::text;
  ASSERT (SELECT status FROM public.exos_tickets WHERE id = pg_temp.tk('c1001')) = 'active', 'L1: not consumed';
  r := pg_temp.scan('c1001', 'aa09');
  ASSERT r ->> 'reason' = 'unknown-list', 'L1: another event''s list is unknown-list, got ' || r::text;
  r := pg_temp.scan('c2001', 'aa02');
  ASSERT r ->> 'reason' = 'checked-in' AND NOT (r ->> 'reentry')::boolean, 'L1: VIP on the VIP list, got ' || r::text;
  ASSERT (SELECT list_id = 'd1000000-0000-0000-0000-00000000aa02' AND gate = 'VIP deck' AND direction = 'entry' AND NOT forced
            FROM public.exos_event_checkins WHERE ticket_id = pg_temp.tk('c2001')),
         'L1: the row carries the list, its name as the gate, entry';
  RAISE NOTICE 'OK  L1 lists by tier';
END $$;

-- L2. Time window (entries).
DO $$
DECLARE r jsonb;
BEGIN
  PERFORM pg_temp.act('d1000000-0000-0000-0000-0000000000a3');
  r := pg_temp.scan('c1002', 'aa03');
  ASSERT r ->> 'reason' = 'invalid-time' AND r ? 'valid_from', 'L2: before valid_from, got ' || r::text;
  r := pg_temp.scan('c1002', 'aa04');
  ASSERT r ->> 'reason' = 'invalid-time' AND r ? 'valid_until', 'L2: after valid_until, got ' || r::text;
  ASSERT (SELECT status FROM public.exos_tickets WHERE id = pg_temp.tk('c1002')) = 'active', 'L2: not consumed';
  RAISE NOTICE 'OK  L2 time window';
END $$;

-- L3. Re-entry off = today's behaviour.
DO $$
DECLARE r jsonb;
BEGIN
  PERFORM pg_temp.act('d1000000-0000-0000-0000-0000000000a3');
  r := pg_temp.scan('c1003', 'aa01');
  ASSERT r ->> 'reason' = 'checked-in' AND NOT (r ? 'reentry'), 'L3: first scan, got ' || r::text;
  ASSERT (SELECT status FROM public.exos_tickets WHERE id = pg_temp.tk('c1003')) = 'used', 'L3: used';
  r := pg_temp.scan('c1003', 'aa01');
  ASSERT r ->> 'reason' = 'used' AND r ->> 'device' = 'Door L1', 'L3: second scan is used, got ' || r::text;
  r := pg_temp.scan('c1003', 'aa01', 'exit');
  ASSERT r ->> 'reason' = 'exit-not-allowed', 'L3: exit on a no-re-entry list, got ' || r::text;
  r := pg_temp.scan('c1003', NULL, 'exit');
  ASSERT r ->> 'reason' = 'exit-not-allowed', 'L3: exit with no list, got ' || r::text;
  r := pg_temp.scan('c1003', 'aa01', 'sideways');
  ASSERT r ->> 'reason' = 'bad-direction', 'L3: unknown direction, got ' || r::text;
  -- A used ticket (any list) is refused on a no-re-entry list.
  r := pg_temp.scan('c2001', 'aa01');
  ASSERT r ->> 'reason' = 'used', 'L3: used elsewhere is used here, got ' || r::text;
  ASSERT (SELECT count(*) FROM public.exos_event_checkins WHERE ticket_id = pg_temp.tk('c1003')) = 1, 'L3: one row';
  RAISE NOTICE 'OK  L3 re-entry off behaves as before';
END $$;

-- L4. Re-entry on.
DO $$
DECLARE r jsonb; v_first timestamptz; n_hooks int;
BEGIN
  INSERT INTO public.exos_webhooks(org_id, url) VALUES ('d1000000-0000-0000-0000-000000000001', 'https://hooks.example/x');
  PERFORM pg_temp.act('d1000000-0000-0000-0000-0000000000a3');
  r := pg_temp.scan('c2002', 'aa02');
  ASSERT r ->> 'reason' = 'checked-in' AND NOT (r ->> 'reentry')::boolean, 'L4: first entry, got ' || r::text;
  v_first := (SELECT check_in_at FROM public.exos_tickets WHERE id = pg_temp.tk('c2002'));
  r := pg_temp.scan('c2002', 'aa02');
  ASSERT r ->> 'reason' = 'already-inside' AND r ->> 'device' = 'Door L1' AND r ->> 'list' = 'VIP deck',
         'L4: second entry without an exit, got ' || r::text;
  r := pg_temp.scan('c2002', 'aa02', 'exit');
  ASSERT r ->> 'reason' = 'checked-out' AND (r ->> 'ok')::boolean, 'L4: exit, got ' || r::text;
  ASSERT (SELECT status FROM public.exos_tickets WHERE id = pg_temp.tk('c2002')) = 'used', 'L4: an exit leaves the ticket used';
  r := pg_temp.scan('c2002', 'aa02');
  ASSERT r ->> 'reason' = 'checked-in' AND (r ->> 'reentry')::boolean, 'L4: entry after exit is a re-entry, got ' || r::text;
  ASSERT (SELECT check_in_at FROM public.exos_tickets WHERE id = pg_temp.tk('c2002')) = v_first,
         'L4: check_in_at stays the first entry';
  ASSERT (SELECT string_agg(direction, ',' ORDER BY scanned_at) FROM public.exos_event_checkins
           WHERE ticket_id = pg_temp.tk('c2002')) = 'entry,exit,entry', 'L4: entry, exit, entry';
  SELECT count(*) INTO n_hooks FROM public.exos_webhook_deliveries
   WHERE event_type = 'ticket.checked_in' AND payload -> 'data' ->> 'ticket_id' = pg_temp.tk('c2002')::text;
  ASSERT n_hooks = 1, 'L4: ticket.checked_in fired once, got ' || n_hooks;
  -- Another re-entry list is independent: a ticket inside the VIP deck may
  -- still enter the pass-out list once.
  r := pg_temp.scan('c2002', 'aa05');
  ASSERT r ->> 'reason' = 'checked-in' AND (r ->> 'reentry')::boolean, 'L4: pass-out list, got ' || r::text;
  r := pg_temp.scan('c2002', 'aa05');
  ASSERT r ->> 'reason' = 'already-inside', 'L4: pass-out list twice, got ' || r::text;
  -- An exit on a re-entry list for a voided ticket is refused.
  r := public.exos_check_in_ticket(pg_temp.tk('c3001'), 'camera', 'verified',
         pg_temp.code(pg_temp.tk('c3001'), 'd1000000-0000-0000-0000-0000000000a5', 'sek-c3001', now()),
         'd1000000-0000-0000-0000-0000000000e1', NULL, NULL, NULL, 'd1000000-0000-0000-0000-00000000aa05', 'exit');
  ASSERT r ->> 'reason' = 'voided', 'L4: voided exit, got ' || r::text;
  -- A camera exit still needs a valid code.
  r := public.exos_check_in_ticket(pg_temp.tk('c2002'), 'camera', 'verified', NULL,
         'd1000000-0000-0000-0000-0000000000e1', NULL, NULL, NULL, 'd1000000-0000-0000-0000-00000000aa02', 'exit');
  ASSERT r ->> 'reason' = 'barcode-rejected', 'L4: exit without a code, got ' || r::text;
  RAISE NOTICE 'OK  L4 re-entry on: entry / already-inside / exit / entry';
END $$;

-- L5. Old calls with no list.
DO $$
DECLARE r jsonb;
BEGIN
  PERFORM pg_temp.act('d1000000-0000-0000-0000-0000000000a3');
  -- 8 positional arguments (the 20260929040000 shape).
  r := public.exos_check_in_ticket(pg_temp.tk('c1004'), 'camera', 'verified',
         pg_temp.code(pg_temp.tk('c1004'), 'd1000000-0000-0000-0000-0000000000a5', 'sek-c1004', now()),
         'd1000000-0000-0000-0000-0000000000e1', NULL, NULL, 'Door old');
  ASSERT r ->> 'reason' = 'checked-in' AND NOT (r ? 'reentry'), 'L5: 8-arg call, got ' || r::text;
  ASSERT (SELECT list_id IS NULL AND gate IS NULL AND direction = 'entry' FROM public.exos_event_checkins
           WHERE ticket_id = pg_temp.tk('c1004')), 'L5: no list on the row';
  -- Named arguments, as PostgREST sends them.
  r := public.exos_check_in_ticket(p_ticket_id => pg_temp.tk('c1004'), p_source => 'camera', p_verification => 'verified',
         p_barcode_payload => pg_temp.code(pg_temp.tk('c1004'), 'd1000000-0000-0000-0000-0000000000a5', 'sek-c1004', now()),
         p_event_id => 'd1000000-0000-0000-0000-0000000000e1', p_reason => NULL, p_device => 'Door old');
  ASSERT r ->> 'reason' = 'used', 'L5: named call, second scan used, got ' || r::text;
  -- A ticket that entered on a re-entry list is still 'used' to an old client.
  r := public.exos_check_in_ticket(pg_temp.tk('c2002'), 'camera', 'verified',
         pg_temp.code(pg_temp.tk('c2002'), 'd1000000-0000-0000-0000-0000000000a5', 'sek-c2002', now()),
         'd1000000-0000-0000-0000-0000000000e1');
  ASSERT r ->> 'reason' = 'used', 'L5: old client sees used, got ' || r::text;
  -- The old by-name call (6 args) and offline call (8 args).
  r := public.exos_door_checkin_by_name(pg_temp.tk('c1005'), 'd1000000-0000-0000-0000-0000000000e1', NULL, 'Door old', NULL, NULL);
  ASSERT r ->> 'reason' = 'checked-in', 'L5: by name, got ' || r::text;
  r := public.exos_check_in_offline('d1000000-0000-0000-0000-0000000f0001', pg_temp.tk('c1006'),
         'd1000000-0000-0000-0000-0000000000e1', now() - interval '3 minutes',
         pg_temp.code(pg_temp.tk('c1006'), 'd1000000-0000-0000-0000-0000000000a5', 'sek-c1006', now() - interval '3 minutes'),
         'camera', NULL, 'Door old');
  ASSERT r ->> 'reason' = 'checked-in', 'L5: offline 8-arg, got ' || r::text;
  -- The old offline version keeps the 24-hour window and never forces.
  r := public.exos_check_in_offline('d1000000-0000-0000-0000-0000000f0002', pg_temp.tk('c6001'),
         'd1000000-0000-0000-0000-0000000000e4', now() - interval '30 hours',
         pg_temp.code(pg_temp.tk('c6001'), 'd1000000-0000-0000-0000-0000000000a5', 'sek-c6001', now() - interval '30 hours'),
         'camera', NULL, 'Door old');
  ASSERT r ->> 'reason' = 'bad-scan-time' AND NOT (r ? 'forced'), 'L5: old window, got ' || r::text;
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_event_checkins WHERE ticket_id = pg_temp.tk('c6001')), 'L5: no forced row';
  RAISE NOTICE 'OK  L5 calls without a list are unchanged';
END $$;

-- L6. Offline replays the server refuses.
DO $$
DECLARE r jsonb; c record; at timestamptz := now() - interval '10 minutes';
BEGIN
  PERFORM pg_temp.act('d1000000-0000-0000-0000-0000000000a3');
  -- Voided: refused, reject row kept, AND a forced check-in; still voided.
  r := public.exos_check_in_offline('d1000000-0000-0000-0000-0000000f0101', pg_temp.tk('c3001'),
         'd1000000-0000-0000-0000-0000000000e1', at,
         pg_temp.code(pg_temp.tk('c3001'), 'd1000000-0000-0000-0000-0000000000a5', 'sek-c3001', at),
         'camera', NULL, 'Door 7F3A', 'd1000000-0000-0000-0000-00000000aa01', 'entry');
  ASSERT r ->> 'reason' = 'voided' AND (r ->> 'conflict')::boolean AND (r ->> 'forced')::boolean
         AND r ->> 'conflict_reason' = 'voided', 'L6: voided replay, got ' || r::text;
  SELECT * INTO c FROM public.exos_event_checkins WHERE ticket_id = pg_temp.tk('c3001');
  ASSERT c.forced AND c.conflict = 'voided' AND c.direction = 'entry' AND c.offline_scanned_at = at
         AND c.device = 'Door 7F3A' AND c.list_id = 'd1000000-0000-0000-0000-00000000aa01' AND c.gate = 'Main door'
         AND c.verification = 'manual' AND c.override_reason LIKE 'offline conflict: voided%',
         'L6: forced row, got ' || row_to_json(c)::text;
  ASSERT (SELECT status FROM public.exos_tickets WHERE id = pg_temp.tk('c3001')) = 'voided', 'L6: still voided';
  ASSERT EXISTS (SELECT 1 FROM public.exos_scan_rejects WHERE ticket_id_attempted = pg_temp.tk('c3001')::text
                   AND reason = 'voided' AND reason_detail = 'offline-replay:voided'), 'L6: reject row kept';
  -- The same ref again: the first answer, no second row.
  r := public.exos_check_in_offline('d1000000-0000-0000-0000-0000000f0101', pg_temp.tk('c3001'),
         'd1000000-0000-0000-0000-0000000000e1', at, NULL, 'camera', NULL, 'Door 7F3A',
         'd1000000-0000-0000-0000-00000000aa01', 'entry');
  ASSERT (r ->> 'duplicate')::boolean AND (r ->> 'forced')::boolean, 'L6: replayed ref, got ' || r::text;
  ASSERT (SELECT count(*) FROM public.exos_event_checkins WHERE ticket_id = pg_temp.tk('c3001')) = 1, 'L6: one forced row';

  -- Wrong list: GA admitted at the VIP deck.
  r := public.exos_check_in_offline('d1000000-0000-0000-0000-0000000f0102', pg_temp.tk('c1001'),
         'd1000000-0000-0000-0000-0000000000e1', at,
         pg_temp.code(pg_temp.tk('c1001'), 'd1000000-0000-0000-0000-0000000000a5', 'sek-c1001', at),
         'camera', NULL, 'Door 7F3A', 'd1000000-0000-0000-0000-00000000aa02', 'entry');
  ASSERT r ->> 'reason' = 'wrong-list' AND (r ->> 'forced')::boolean, 'L6: wrong-list replay, got ' || r::text;
  ASSERT (SELECT forced AND conflict = 'wrong-list' AND list_id = 'd1000000-0000-0000-0000-00000000aa02'
            FROM public.exos_event_checkins WHERE ticket_id = pg_temp.tk('c1001')), 'L6: forced on the list';
  ASSERT (SELECT status FROM public.exos_tickets WHERE id = pg_temp.tk('c1001')) = 'active',
         'L6: a forced row never changes the ticket';

  -- Too old: e3 ended four days ago, the scan was three days ago.
  r := public.exos_check_in_offline('d1000000-0000-0000-0000-0000000f0103', pg_temp.tk('c5001'),
         'd1000000-0000-0000-0000-0000000000e3', now() - interval '3 days',
         pg_temp.code(pg_temp.tk('c5001'), 'd1000000-0000-0000-0000-0000000000a5', 'sek-c5001', now() - interval '3 days'),
         'camera', NULL, 'Door 7F3A', NULL, 'entry');
  ASSERT r ->> 'reason' = 'bad-scan-time' AND r ->> 'conflict_reason' = 'too-old', 'L6: too old, got ' || r::text;
  -- Future-dated: refused, NOT forced (a wrong clock, not an admission).
  r := public.exos_check_in_offline('d1000000-0000-0000-0000-0000000f0104', pg_temp.tk('c1002'),
         'd1000000-0000-0000-0000-0000000000e1', now() + interval '1 hour', NULL, 'camera', NULL, 'Door 7F3A', NULL, 'entry');
  ASSERT r ->> 'reason' = 'bad-scan-time' AND NOT (r ? 'forced'), 'L6: future scan not forced, got ' || r::text;
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_event_checkins WHERE ticket_id = pg_temp.tk('c1002')), 'L6: no row';

  -- The widened window: e4 ended an hour ago; a scan 30 hours old uploads.
  r := public.exos_check_in_offline('d1000000-0000-0000-0000-0000000f0105', pg_temp.tk('c6001'),
         'd1000000-0000-0000-0000-0000000000e4', now() - interval '30 hours',
         pg_temp.code(pg_temp.tk('c6001'), 'd1000000-0000-0000-0000-0000000000a5', 'sek-c6001', now() - interval '30 hours'),
         'camera', NULL, 'Door 7F3A', NULL, 'entry');
  ASSERT r ->> 'reason' = 'checked-in' AND NOT (r ? 'forced'), 'L6: within event end + 48 h, got ' || r::text;

  -- Post-transfer: the code the door read was signed for a5, who has since
  -- transferred the ticket to a7 (the secret rotated).
  r := public.exos_check_in_offline('d1000000-0000-0000-0000-0000000f0106', pg_temp.tk('c4001'),
         'd1000000-0000-0000-0000-0000000000e1', at,
         pg_temp.code(pg_temp.tk('c4001'), 'd1000000-0000-0000-0000-0000000000a5', 'old-secret', at),
         'camera', NULL, 'Door 7F3A', NULL, 'entry');
  ASSERT r ->> 'reason' = 'barcode-rejected' AND r ->> 'conflict_reason' = 'post-transfer', 'L6: post-transfer, got ' || r::text;
  ASSERT (SELECT status FROM public.exos_tickets WHERE id = pg_temp.tk('c4001')) = 'active', 'L6: the new holder can still enter';
  -- A forged owner (never held the ticket): refused, not forced.
  r := public.exos_check_in_offline('d1000000-0000-0000-0000-0000000f0107', pg_temp.tk('c4001'),
         'd1000000-0000-0000-0000-0000000000e1', at,
         pg_temp.code(pg_temp.tk('c4001'), 'd1000000-0000-0000-0000-0000000000a6', 'x', at),
         'camera', NULL, 'Door 7F3A', NULL, 'entry');
  ASSERT r ->> 'reason' = 'barcode-rejected' AND NOT (r ? 'forced'), 'L6: forged code not forced, got ' || r::text;
  ASSERT (SELECT count(*) FROM public.exos_event_checkins WHERE ticket_id = pg_temp.tk('c4001')) = 1, 'L6: one forced row';

  -- A true double entry stays reject-only.
  r := public.exos_check_in_offline('d1000000-0000-0000-0000-0000000f0108', pg_temp.tk('c1003'),
         'd1000000-0000-0000-0000-0000000000e1', at,
         pg_temp.code(pg_temp.tk('c1003'), 'd1000000-0000-0000-0000-0000000000a5', 'sek-c1003', at),
         'camera', NULL, 'Door 7F3A', 'd1000000-0000-0000-0000-00000000aa01', 'entry');
  ASSERT r ->> 'reason' = 'used' AND NOT (r ? 'forced'), 'L6: used not forced, got ' || r::text;
  ASSERT (SELECT count(*) FROM public.exos_event_checkins WHERE ticket_id = pg_temp.tk('c1003')) = 1, 'L6: still one row';

  -- An offline entry / exit / entry on a re-entry list, replayed in order.
  r := public.exos_check_in_offline('d1000000-0000-0000-0000-0000000f0109', pg_temp.tk('c2003'),
         'd1000000-0000-0000-0000-0000000000e1', now() - interval '9 minutes',
         pg_temp.code(pg_temp.tk('c2003'), 'd1000000-0000-0000-0000-0000000000a5', 'sek-c2003', now() - interval '9 minutes'),
         'camera', NULL, 'Door 7F3A', 'd1000000-0000-0000-0000-00000000aa02', 'entry');
  ASSERT r ->> 'reason' = 'checked-in', 'L6: offline entry, got ' || r::text;
  r := public.exos_check_in_offline('d1000000-0000-0000-0000-0000000f010a', pg_temp.tk('c2003'),
         'd1000000-0000-0000-0000-0000000000e1', now() - interval '8 minutes',
         pg_temp.code(pg_temp.tk('c2003'), 'd1000000-0000-0000-0000-0000000000a5', 'sek-c2003', now() - interval '8 minutes'),
         'camera', NULL, 'Door 7F3A', 'd1000000-0000-0000-0000-00000000aa02', 'exit');
  ASSERT r ->> 'reason' = 'checked-out', 'L6: offline exit, got ' || r::text;
  r := public.exos_check_in_offline('d1000000-0000-0000-0000-0000000f010b', pg_temp.tk('c2003'),
         'd1000000-0000-0000-0000-0000000000e1', now() - interval '5 minutes',
         pg_temp.code(pg_temp.tk('c2003'), 'd1000000-0000-0000-0000-0000000000a5', 'sek-c2003', now() - interval '5 minutes'),
         'camera', NULL, 'Door 7F3A', 'd1000000-0000-0000-0000-00000000aa02', 'entry');
  ASSERT r ->> 'reason' = 'checked-in' AND (r ->> 'reentry')::boolean, 'L6: offline re-entry, got ' || r::text;
  -- A second offline entry in between (another device) is already-inside,
  -- reject-only.
  r := public.exos_check_in_offline('d1000000-0000-0000-0000-0000000f010c', pg_temp.tk('c2003'),
         'd1000000-0000-0000-0000-0000000000e1', now() - interval '4 minutes',
         pg_temp.code(pg_temp.tk('c2003'), 'd1000000-0000-0000-0000-0000000000a5', 'sek-c2003', now() - interval '4 minutes'),
         'camera', NULL, 'Door 9B1C', 'd1000000-0000-0000-0000-00000000aa02', 'entry');
  ASSERT r ->> 'reason' = 'already-inside' AND (r ->> 'conflict')::boolean AND NOT (r ? 'forced'),
         'L6: double offline entry, got ' || r::text;

  -- By-name replay of a voided ticket: forced, verification 'name'.
  UPDATE public.exos_tickets SET status = 'voided' WHERE id = pg_temp.tk('c1002');
  r := public.exos_door_checkin_by_name(pg_temp.tk('c1002'), 'd1000000-0000-0000-0000-0000000000e1', 'dead phone',
         'Door 7F3A', at, 'd1000000-0000-0000-0000-0000000f010d', 'd1000000-0000-0000-0000-00000000aa01', 'entry');
  ASSERT r ->> 'reason' = 'voided' AND (r ->> 'forced')::boolean, 'L6: by-name voided replay, got ' || r::text;
  ASSERT (SELECT forced AND verification = 'name' AND conflict = 'voided' AND override_reason LIKE '%dead phone%'
            FROM public.exos_event_checkins WHERE ticket_id = pg_temp.tk('c1002')), 'L6: by-name forced row';
  -- A forced row is not a ticket.checked_in webhook.
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_webhook_deliveries
                      WHERE payload -> 'data' ->> 'ticket_id' IN (pg_temp.tk('c1002')::text, pg_temp.tk('c3001')::text)),
         'L6: no webhook for forced rows';
  RAISE NOTICE 'OK  L6 refused offline admissions recorded as forced';
END $$;

-- L7. Scanner scope.
DO $$
DECLARE r jsonb;
BEGIN
  PERFORM pg_temp.act('d1000000-0000-0000-0000-0000000000a4');   -- assigned to e2 only
  r := pg_temp.scan('c1001', 'aa01');
  ASSERT r ->> 'reason' = 'not-assigned', 'L7: not assigned, got ' || r::text;
  r := public.exos_check_in_offline('d1000000-0000-0000-0000-0000000f0201', pg_temp.tk('c3001'),
         'd1000000-0000-0000-0000-0000000000e1', now() - interval '5 minutes', NULL, 'camera', NULL, 'Door X',
         'd1000000-0000-0000-0000-00000000aa01', 'entry');
  ASSERT r ->> 'reason' = 'not-assigned' AND NOT (r ? 'forced'), 'L7: offline not assigned, got ' || r::text;
  ASSERT (SELECT count(*) FROM public.exos_event_checkins WHERE ticket_id = pg_temp.tk('c3001')) = 1,
         'L7: no forced row for an unassigned scanner';
  ASSERT public._exos_record_forced_checkin(pg_temp.tk('c3001'), 'd1000000-0000-0000-0000-0000000000e1', NULL,
           'camera', 'manual', NULL, now(), 'voided', NULL) IS NULL, 'L7: the helper refuses an unassigned scanner too';
  PERFORM pg_temp.act('d1000000-0000-0000-0000-0000000000a6');   -- another org's owner
  BEGIN
    PERFORM pg_temp.scan('c1001', 'aa01');
    RAISE EXCEPTION 'L7: an outsider checked a ticket in';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  RAISE NOTICE 'OK  L7 scanner scope';
END $$;

-- L8. RLS on exos_checkin_lists, as the authenticated role.
SELECT pg_temp.act('d1000000-0000-0000-0000-0000000000a3');
SET LOCAL ROLE authenticated;
DO $$
BEGIN
  ASSERT (SELECT count(*) FROM public.exos_checkin_lists WHERE event_id = 'd1000000-0000-0000-0000-0000000000e1') = 5,
         'L8: an unscoped scanner reads the event''s lists';
  BEGIN
    INSERT INTO public.exos_checkin_lists(event_id, org_id, name) VALUES
      ('d1000000-0000-0000-0000-0000000000e1', 'd1000000-0000-0000-0000-000000000001', 'Scanner list');
    RAISE EXCEPTION 'L8: a scanner created a list';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  UPDATE public.exos_checkin_lists SET allow_reentry = true WHERE id = 'd1000000-0000-0000-0000-00000000aa01';
  DELETE FROM public.exos_checkin_lists WHERE id = 'd1000000-0000-0000-0000-00000000aa01';
END $$;
RESET ROLE;
DO $$
BEGIN
  ASSERT (SELECT NOT allow_reentry FROM public.exos_checkin_lists WHERE id = 'd1000000-0000-0000-0000-00000000aa01'),
         'L8: a scanner can''t turn re-entry on (or delete the list)';
END $$;
SELECT pg_temp.act('d1000000-0000-0000-0000-0000000000a4');
SET LOCAL ROLE authenticated;
DO $$
BEGIN
  ASSERT (SELECT count(*) FROM public.exos_checkin_lists WHERE event_id = 'd1000000-0000-0000-0000-0000000000e1') = 0,
         'L8: a scanner assigned elsewhere doesn''t see e1''s lists';
  ASSERT (SELECT count(*) FROM public.exos_checkin_lists WHERE event_id = 'd1000000-0000-0000-0000-0000000000e2') = 1,
         'L8: …but sees its own event''s';
END $$;
RESET ROLE;
SELECT pg_temp.act('d1000000-0000-0000-0000-0000000000a6');
SET LOCAL ROLE authenticated;
DO $$
BEGIN
  ASSERT (SELECT count(*) FROM public.exos_checkin_lists) = 0, 'L8: an outsider sees no lists';
  BEGIN
    INSERT INTO public.exos_checkin_lists(event_id, org_id, name) VALUES
      ('d1000000-0000-0000-0000-0000000000e1', 'd1000000-0000-0000-0000-000000000002', 'Sneaky');
    RAISE EXCEPTION 'L8: an outsider created a list on e1';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
END $$;
RESET ROLE;
SELECT pg_temp.act('d1000000-0000-0000-0000-0000000000a2');
SET LOCAL ROLE authenticated;
DO $$
DECLARE v_id uuid;
BEGIN
  INSERT INTO public.exos_checkin_lists(event_id, org_id, name, tier_ids)
  VALUES ('d1000000-0000-0000-0000-0000000000e1', 'd1000000-0000-0000-0000-000000000002', 'Balcony',
          ARRAY['d1000000-0000-0000-0000-0000000000f2', 'd1000000-0000-0000-0000-0000000000f2']::uuid[])
  RETURNING id INTO v_id;
  ASSERT (SELECT org_id = 'd1000000-0000-0000-0000-000000000001' AND cardinality(tier_ids) = 1 AND NOT allow_reentry
            FROM public.exos_checkin_lists WHERE id = v_id),
         'L8: a manager creates a list; the event decides the org, tiers de-duplicated, re-entry off';
  UPDATE public.exos_checkin_lists SET name = 'Balcony bar', allow_reentry = true WHERE id = v_id;
  ASSERT (SELECT name = 'Balcony bar' AND allow_reentry FROM public.exos_checkin_lists WHERE id = v_id), 'L8: manager edits';
  BEGIN
    UPDATE public.exos_checkin_lists SET tier_ids = ARRAY['d1000000-0000-0000-0000-0000000000f9']::uuid[] WHERE id = v_id;
    RAISE EXCEPTION 'L8: another event''s ticket type was accepted';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  BEGIN
    UPDATE public.exos_checkin_lists SET event_id = 'd1000000-0000-0000-0000-0000000000e2' WHERE id = v_id;
    RAISE EXCEPTION 'L8: a list moved events';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  BEGIN
    UPDATE public.exos_checkin_lists SET tier_ids = '{}'::uuid[] WHERE id = v_id;
    RAISE EXCEPTION 'L8: an empty ticket-type list was accepted';
  EXCEPTION WHEN invalid_parameter_value OR check_violation THEN NULL;
  END;
  BEGIN
    UPDATE public.exos_checkin_lists SET valid_from = now(), valid_until = now() - interval '1 hour' WHERE id = v_id;
    RAISE EXCEPTION 'L8: a window ending before it starts was accepted';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
  DELETE FROM public.exos_checkin_lists WHERE id = v_id;
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_checkin_lists WHERE id = v_id), 'L8: manager deletes';
END $$;
RESET ROLE;
DO $$
BEGIN
  ASSERT NOT has_table_privilege('anon', 'public.exos_checkin_lists', 'SELECT'), 'L8: anon has no access';
  ASSERT (SELECT relrowsecurity FROM pg_class WHERE oid = 'public.exos_checkin_lists'::regclass), 'L8: RLS on';
  RAISE NOTICE 'OK  L8 RLS on check-in lists';
END $$;

-- L9. Roster.
DO $$
DECLARE r record;
BEGIN
  PERFORM pg_temp.act('d1000000-0000-0000-0000-0000000000a3');
  SELECT * INTO r FROM public.exos_event_checkin_roster('d1000000-0000-0000-0000-0000000000e1') WHERE ticket_id = pg_temp.tk('c2002');
  ASSERT r.tier_id = 'd1000000-0000-0000-0000-0000000000f2', 'L9: tier id';
  ASSERT r.list_state = jsonb_build_object('d1000000-0000-0000-0000-00000000aa02', 'entry', 'd1000000-0000-0000-0000-00000000aa05', 'entry'),
         'L9: last direction per re-entry list, got ' || coalesce(r.list_state::text, 'null');
  SELECT * INTO r FROM public.exos_event_checkin_roster('d1000000-0000-0000-0000-0000000000e1') WHERE ticket_id = pg_temp.tk('c2003');
  ASSERT r.list_state = jsonb_build_object('d1000000-0000-0000-0000-00000000aa02', 'entry'), 'L9: after offline replays';
  SELECT * INTO r FROM public.exos_event_checkin_roster('d1000000-0000-0000-0000-0000000000e1') WHERE ticket_id = pg_temp.tk('c1003');
  ASSERT r.list_state IS NULL, 'L9: no-re-entry lists carry no state (used says it)';
  PERFORM pg_temp.act('d1000000-0000-0000-0000-0000000000a4');
  BEGIN
    PERFORM 1 FROM public.exos_event_checkin_roster('d1000000-0000-0000-0000-0000000000e1');
    RAISE EXCEPTION 'L9: a scanner assigned elsewhere read the roster';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  RAISE NOTICE 'OK  L9 roster carries tier + list state';
END $$;

-- L10. Grants and signatures.
DO $$
DECLARE f text;
BEGIN
  FOREACH f IN ARRAY ARRAY[
    'public.exos_check_in_ticket(uuid,text,text,text,uuid,text,timestamptz,text,uuid,text)',
    'public.exos_check_in_offline(uuid,uuid,uuid,timestamptz,text,text,text,text,uuid,text)',
    'public.exos_door_checkin_by_name(uuid,uuid,text,text,timestamptz,uuid,uuid,text)'] LOOP
    ASSERT has_function_privilege('authenticated', f, 'EXECUTE'), 'L10: authenticated calls ' || f;
    ASSERT NOT has_function_privilege('anon', f, 'EXECUTE'), 'L10: anon may not call ' || f;
  END LOOP;
  FOREACH f IN ARRAY ARRAY[
    'public._exos_scan_time_ok(uuid,timestamptz)',
    'public._exos_checkin_list_refusal(uuid,uuid,uuid,text,timestamptz)',
    'public._exos_list_inside(uuid,uuid,timestamptz)',
    'public._exos_post_transfer_code(uuid,text)',
    'public._exos_record_forced_checkin(uuid,uuid,uuid,text,text,text,timestamptz,text,text)',
    'public.exos_tg_checkin_list_scope()'] LOOP
    ASSERT NOT has_function_privilege('authenticated', f, 'EXECUTE'), 'L10: internal ' || f;
    ASSERT NOT has_function_privilege('anon', f, 'EXECUTE'), 'L10: internal (anon) ' || f;
  END LOOP;
  -- The old versions stay for old clients; the new overloads take no
  -- defaults, so no call can match both ("function is not unique").
  ASSERT to_regprocedure('public.exos_check_in_ticket(uuid,text,text,text,uuid,text,timestamptz,text)') IS NOT NULL
     AND to_regprocedure('public.exos_check_in_offline(uuid,uuid,uuid,timestamptz,text,text,text,text)') IS NOT NULL
     AND to_regprocedure('public.exos_door_checkin_by_name(uuid,uuid,text,text,timestamptz,uuid)') IS NOT NULL,
         'L10: the old signatures are kept';
  ASSERT (SELECT bool_and(pronargdefaults = 0) FROM pg_proc
           WHERE oid IN ('public.exos_check_in_ticket(uuid,text,text,text,uuid,text,timestamptz,text,uuid,text)'::regprocedure,
                         'public.exos_check_in_offline(uuid,uuid,uuid,timestamptz,text,text,text,text,uuid,text)'::regprocedure,
                         'public.exos_door_checkin_by_name(uuid,uuid,text,text,timestamptz,uuid,uuid,text)'::regprocedure)),
         'L10: the list overloads have no defaults';
  ASSERT (SELECT bool_and(array_to_string(proconfig, ',') LIKE '%search_path=public, pg_temp%')
            FROM pg_proc WHERE pronamespace = 'public'::regnamespace
             AND proname IN ('exos_check_in_ticket', 'exos_check_in_offline', 'exos_door_checkin_by_name',
                             '_exos_scan_time_ok', '_exos_checkin_list_refusal', '_exos_list_inside',
                             '_exos_post_transfer_code', '_exos_record_forced_checkin', 'exos_tg_checkin_list_scope')),
         'L10: search_path pinned';
  RAISE NOTICE 'OK  L10 grants';
END $$;

-- L11. Reports and undo.
DO $$
DECLARE a jsonb; r jsonb; n int;
BEGIN
  PERFORM pg_temp.act('d1000000-0000-0000-0000-0000000000a1');
  a := public.exos_event_analytics('d1000000-0000-0000-0000-0000000000e1');
  SELECT count(*) INTO n FROM public.exos_event_checkins
   WHERE event_id = 'd1000000-0000-0000-0000-0000000000e1' AND direction = 'entry';
  ASSERT (a -> 'scans' ->> 'total')::int = n, 'L11: analytics counts entry rows, got ' || (a -> 'scans')::text;
  ASSERT n < (SELECT count(*) FROM public.exos_event_checkins WHERE event_id = 'd1000000-0000-0000-0000-0000000000e1'),
         'L11: (there are exit rows to leave out)';
  -- 'used' after an exit points at an entry, not the exit.
  PERFORM pg_temp.act('d1000000-0000-0000-0000-0000000000a3');
  r := pg_temp.scan('c2002', 'aa05', 'exit');
  ASSERT r ->> 'reason' = 'checked-out', 'L11: exit, got ' || r::text;
  r := public._exos_used_answer(pg_temp.tk('c2002'));
  ASSERT r ->> 'reason' = 'used' AND r ->> 'source' = 'camera', 'L11: used answer, got ' || r::text;
  -- Undo removes every row, exits too, and re-opens the ticket.
  PERFORM pg_temp.act('d1000000-0000-0000-0000-0000000000a2');
  r := public.exos_undo_check_in(pg_temp.tk('c2002'), 'd1000000-0000-0000-0000-0000000000e1', 'scanned the wrong pass');
  ASSERT r ->> 'reason' = 'undone', 'L11: undo, got ' || r::text;
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_event_checkins WHERE ticket_id = pg_temp.tk('c2002')), 'L11: all rows gone';
  ASSERT (SELECT status FROM public.exos_tickets WHERE id = pg_temp.tk('c2002')) = 'active', 'L11: re-opened';
  RAISE NOTICE 'OK  L11 reports count entries; undo clears exits';
END $$;

ROLLBACK;
