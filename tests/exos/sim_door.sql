-- ============================================================================
-- SIM-DOOR: door staff and scanner phones making mistakes (mig 20261104120000)
-- ============================================================================
-- Drives the real door RPCs the way the scanner page and its offline queue
-- call them (exos_check_in_ticket, exos_check_in_offline,
-- exos_door_checkin_by_name, exos_undo_check_in, exos_order_check_out,
-- exos_guest_check_in, exos_guest_undo_arrival, exos_mint_tickets,
-- exos_issue_comp_batch, exos_pos_close_drawer). Each block is one mistake:
--   OK    the outcome is right (and, where it's a judgement call, why)
--   KNOWN a real gap left for a product decision: printed, never fails the
--         run; it prints "now fixed" instead once the behaviour changes
-- The scanner's pure offline logic (clock skew, day keys, wallet epochs,
-- imported codes, the saved-list decision) is in src/lib/sim/door.test.ts;
-- the parallel races are in tests/exos/race_sim_door.sh.
-- Self-contained (BEGIN / ROLLBACK). Org d7d…01: owner a1, manager a2,
-- scanner a3 (any event), scanner a4 (assigned to e1, later moved), holder
-- a5, new holder a7, scanner a8 (disabled later). Org d7d…02: owner a6.
-- ============================================================================
\set ON_ERROR_STOP on
BEGIN;

INSERT INTO auth.users(id,email,email_confirmed_at) VALUES
  ('d7d00000-0000-0000-0000-0000000000a1','sdown@x.com',now()),
  ('d7d00000-0000-0000-0000-0000000000a2','sdmgr@x.com',now()),
  ('d7d00000-0000-0000-0000-0000000000a3','sdscan@x.com',now()),
  ('d7d00000-0000-0000-0000-0000000000a4','sdscan2@x.com',now()),
  ('d7d00000-0000-0000-0000-0000000000a5','sdhold@x.com',now()),
  ('d7d00000-0000-0000-0000-0000000000a6','sdother@x.com',now()),
  ('d7d00000-0000-0000-0000-0000000000a7','sdnew@x.com',now()),
  ('d7d00000-0000-0000-0000-0000000000a8','sdscan3@x.com',now());
INSERT INTO public.exos_orgs(id,name,slug,owner_uid) VALUES
  ('d7d00000-0000-0000-0000-000000000001','Sim Door Org','sim-door-org','d7d00000-0000-0000-0000-0000000000a1'),
  ('d7d00000-0000-0000-0000-000000000002','Sim Other Org','sim-door-other','d7d00000-0000-0000-0000-0000000000a6');
INSERT INTO public.exos_org_memberships(org_id,user_id,role) VALUES
  ('d7d00000-0000-0000-0000-000000000001','d7d00000-0000-0000-0000-0000000000a1','owner'),
  ('d7d00000-0000-0000-0000-000000000001','d7d00000-0000-0000-0000-0000000000a2','manager'),
  ('d7d00000-0000-0000-0000-000000000001','d7d00000-0000-0000-0000-0000000000a3','scanner'),
  ('d7d00000-0000-0000-0000-000000000001','d7d00000-0000-0000-0000-0000000000a4','scanner'),
  ('d7d00000-0000-0000-0000-000000000001','d7d00000-0000-0000-0000-0000000000a8','scanner'),
  ('d7d00000-0000-0000-0000-000000000002','d7d00000-0000-0000-0000-0000000000a6','owner');
-- e1 doors open (tonight), e2 another event of the org, e3 doors in 2 hours,
-- e4 ended 3 hours ago, e9 the other org's.
INSERT INTO public.exos_events(id,org_id,name,slug,status,starts_at,doors_at,ends_at,total_tickets,created_by) VALUES
  ('d7d00000-0000-0000-0000-0000000000e1','d7d00000-0000-0000-0000-000000000001','Sim Door One','sim-door-one','published',
   now() + interval '1 hour', now() - interval '1 hour', now() + interval '6 hours', 0, 'd7d00000-0000-0000-0000-0000000000a1'),
  ('d7d00000-0000-0000-0000-0000000000e2','d7d00000-0000-0000-0000-000000000001','Sim Door Two','sim-door-two','published',
   now() + interval '1 hour', now() - interval '1 hour', NULL, 0, 'd7d00000-0000-0000-0000-0000000000a1'),
  ('d7d00000-0000-0000-0000-0000000000e3','d7d00000-0000-0000-0000-000000000001','Sim Door Early','sim-door-early','published',
   now() + interval '3 hours', now() + interval '2 hours', NULL, 0, 'd7d00000-0000-0000-0000-0000000000a1'),
  ('d7d00000-0000-0000-0000-0000000000e4','d7d00000-0000-0000-0000-000000000001','Sim Door Over','sim-door-over','published',
   now() - interval '8 hours', now() - interval '9 hours', now() - interval '3 hours', 0, 'd7d00000-0000-0000-0000-0000000000a1'),
  ('d7d00000-0000-0000-0000-0000000000e9','d7d00000-0000-0000-0000-000000000002','Sim Door Else','sim-door-else','published',
   now() + interval '1 hour', now() - interval '1 hour', NULL, 0, 'd7d00000-0000-0000-0000-0000000000a6');
INSERT INTO public.exos_ticket_tiers(id,event_id,name,price,capacity) VALUES
  ('d7d00000-0000-0000-0000-0000000000f1','d7d00000-0000-0000-0000-0000000000e1','GA',50,0),
  ('d7d00000-0000-0000-0000-0000000000f2','d7d00000-0000-0000-0000-0000000000e1','VIP',150,0);
-- a4 is assigned to e1 only.
INSERT INTO public.exos_event_staff(event_id, user_id, org_id) VALUES
  ('d7d00000-0000-0000-0000-0000000000e1','d7d00000-0000-0000-0000-0000000000a4','d7d00000-0000-0000-0000-000000000001');
INSERT INTO public.exos_checkin_lists(id,event_id,org_id,name,tier_ids,allow_reentry,sort_order) VALUES
  ('d7d00000-0000-0000-0000-00000000aa01','d7d00000-0000-0000-0000-0000000000e1',NULL,'Main door',NULL,false,0),
  ('d7d00000-0000-0000-0000-00000000aa02','d7d00000-0000-0000-0000-0000000000e1',NULL,'VIP deck',
   ARRAY['d7d00000-0000-0000-0000-0000000000f2']::uuid[],true,1),
  ('d7d00000-0000-0000-0000-00000000aa03','d7d00000-0000-0000-0000-0000000000e1',NULL,'Pass-out',NULL,true,2),
  ('d7d00000-0000-0000-0000-00000000aa09','d7d00000-0000-0000-0000-0000000000e2',NULL,'Two main',NULL,false,0);

-- Tickets c0001-c0099: e1 GA, holder a5, secret 'sd-<n>', unless changed below.
INSERT INTO public.exos_tickets(id,event_id,org_id,tier_id,tier_name,buyer_id,owner_id,buyer_email,status,barcode_secret,price_paid,order_ref,channel_source,attendee_name)
SELECT ('d7d00000-0000-0000-0000-0000000c' || lpad(n::text, 4, '0'))::uuid,
       'd7d00000-0000-0000-0000-0000000000e1', 'd7d00000-0000-0000-0000-000000000001',
       'd7d00000-0000-0000-0000-0000000000f1', 'GA',
       'd7d00000-0000-0000-0000-0000000000a5', 'd7d00000-0000-0000-0000-0000000000a5', 'sdhold@x.com',
       'active', 'sd-' || n, 50, 'web-sd-' || n, 'stripe', 'Holder ' || n
  FROM generate_series(1, 60) n;
-- VIP tickets 40-44; e2 ticket 50; e3 51; e4 52; e9 (other org) 53.
UPDATE public.exos_tickets SET tier_id = 'd7d00000-0000-0000-0000-0000000000f2', tier_name = 'VIP'
 WHERE id IN (SELECT ('d7d00000-0000-0000-0000-0000000c' || lpad(n::text, 4, '0'))::uuid FROM generate_series(40, 44) n);
UPDATE public.exos_tickets SET event_id = 'd7d00000-0000-0000-0000-0000000000e2', tier_id = NULL WHERE id = 'd7d00000-0000-0000-0000-0000000c0050';
UPDATE public.exos_tickets SET event_id = 'd7d00000-0000-0000-0000-0000000000e3', tier_id = NULL WHERE id = 'd7d00000-0000-0000-0000-0000000c0051';
UPDATE public.exos_tickets SET event_id = 'd7d00000-0000-0000-0000-0000000000e4', tier_id = NULL WHERE id = 'd7d00000-0000-0000-0000-0000000c0052';
UPDATE public.exos_tickets SET event_id = 'd7d00000-0000-0000-0000-0000000000e9', tier_id = NULL,
       org_id = 'd7d00000-0000-0000-0000-000000000002' WHERE id = 'd7d00000-0000-0000-0000-0000000c0053';

CREATE FUNCTION pg_temp.act(p_uid text) RETURNS void LANGUAGE sql AS $$
  SELECT set_config('app.uid', coalesce(p_uid, ''), false),
         set_config('app.jwt', '{"email":"door@x.com"}', false);
$$;
CREATE FUNCTION pg_temp.u(p text) RETURNS uuid LANGUAGE sql IMMUTABLE AS $$
  SELECT ('d7d00000-0000-0000-0000-0000000000' || p)::uuid;
$$;
CREATE FUNCTION pg_temp.tk(n int) RETURNS uuid LANGUAGE sql IMMUTABLE AS $$
  SELECT ('d7d00000-0000-0000-0000-0000000c' || lpad(n::text, 4, '0'))::uuid;
$$;
CREATE FUNCTION pg_temp.lst(p text) RETURNS uuid LANGUAGE sql IMMUTABLE AS $$
  SELECT ('d7d00000-0000-0000-0000-00000000' || p)::uuid;
$$;
CREATE FUNCTION pg_temp.ref(n int) RETURNS uuid LANGUAGE sql IMMUTABLE AS $$
  SELECT ('d7d00000-0000-0000-0000-00000000f' || lpad(n::text, 3, '0'))::uuid;
$$;
-- The holder's live T- code (signed with the day key, as signBarcode does) for
-- the window of p_at, from the ticket's current owner + secret unless given.
CREATE FUNCTION pg_temp.tc(p_n int, p_at timestamptz DEFAULT now(), p_owner uuid DEFAULT NULL, p_secret text DEFAULT NULL)
RETURNS text LANGUAGE sql AS $$
  SELECT 'T-' || t.id || ':' || coalesce(p_owner, t.owner_id) || ':' || b || ':' ||
         public._exos_door_code_mac(t.id, coalesce(p_owner, t.owner_id), b, coalesce(p_secret, t.barcode_secret))
    FROM public.exos_tickets t,
         (SELECT floor(extract(epoch FROM p_at) * 1000 / 30000)::bigint AS b) x
   WHERE t.id = pg_temp.tk(p_n);
$$;
-- A live camera scan at the door (the 10-argument call the scanner makes).
CREATE FUNCTION pg_temp.scan(p_n int, p_device text DEFAULT 'Door A', p_list text DEFAULT NULL,
                             p_dir text DEFAULT 'entry', p_event uuid DEFAULT NULL, p_code text DEFAULT NULL)
RETURNS jsonb LANGUAGE sql AS $$
  SELECT public.exos_check_in_ticket(pg_temp.tk(p_n), 'camera', 'verified',
           coalesce(p_code, pg_temp.tc(p_n)),
           coalesce(p_event, (SELECT event_id FROM public.exos_tickets WHERE id = pg_temp.tk(p_n))),
           NULL, NULL, p_device,
           CASE WHEN p_list IS NULL THEN NULL ELSE pg_temp.lst(p_list) END, p_dir);
$$;
-- An offline scan uploaded later (what lib/tickets checkInOffline sends).
CREATE FUNCTION pg_temp.replay(p_ref int, p_n int, p_at timestamptz, p_device text,
                               p_code text DEFAULT NULL, p_list text DEFAULT NULL, p_dir text DEFAULT 'entry')
RETURNS jsonb LANGUAGE sql AS $$
  SELECT public.exos_check_in_offline(pg_temp.ref(p_ref), pg_temp.tk(p_n),
           (SELECT event_id FROM public.exos_tickets WHERE id = pg_temp.tk(p_n)), p_at,
           coalesce(p_code, pg_temp.tc(p_n, p_at)), 'camera', NULL, p_device,
           CASE WHEN p_list IS NULL THEN NULL ELSE pg_temp.lst(p_list) END, p_dir);
$$;
CREATE FUNCTION pg_temp.entries(p_n int) RETURNS bigint LANGUAGE sql AS $$
  SELECT count(*) FROM public.exos_event_checkins WHERE ticket_id = pg_temp.tk(p_n) AND direction = 'entry';
$$;
CREATE FUNCTION pg_temp.status(p_n int) RETURNS text LANGUAGE sql AS $$
  SELECT status FROM public.exos_tickets WHERE id = pg_temp.tk(p_n);
$$;
-- Did the statement raise with this SQLSTATE?
CREATE FUNCTION pg_temp.raises(p_sql text, p_state text) RETURNS boolean LANGUAGE plpgsql AS $$
BEGIN
  EXECUTE p_sql;
  RETURN false;
EXCEPTION WHEN others THEN
  RETURN SQLSTATE = p_state;
END $$;
CREATE FUNCTION pg_temp.known(p_id text, p_ok boolean, p_gap text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  IF p_ok THEN
    RAISE NOTICE 'OK SIM-DOOR-% (was KNOWN, now fixed: %)', p_id, p_gap;
  ELSE
    RAISE NOTICE 'KNOWN SIM-DOOR-%: %', p_id, p_gap;
  END IF;
END $$;

-- ---------------------------------------------------------------------------
-- SIM-DOOR-1. The same ticket scanned twice on one phone, then on another.
-- ---------------------------------------------------------------------------
DO $$
DECLARE r jsonb;
BEGIN
  PERFORM pg_temp.act('d7d00000-0000-0000-0000-0000000000a3');
  r := pg_temp.scan(1, 'Door A');
  ASSERT r ->> 'reason' = 'checked-in', 'SIM-DOOR-1: first scan, got ' || r::text;
  r := pg_temp.scan(1, 'Door A');
  ASSERT r ->> 'reason' = 'used' AND r ->> 'device' = 'Door A' AND r ? 'check_in_at',
         'SIM-DOOR-1: second scan on the same phone says used, and where, got ' || r::text;
  r := pg_temp.scan(1, 'Door B');
  ASSERT r ->> 'reason' = 'used' AND r ->> 'device' = 'Door A',
         'SIM-DOOR-1: the other phone is told it was Door A, got ' || r::text;
  ASSERT pg_temp.entries(1) = 1, 'SIM-DOOR-1: one entry row';
  RAISE NOTICE 'OK SIM-DOOR-1 same ticket twice (one phone, two phones): one entry, "used at Door A"';
END $$;

-- ---------------------------------------------------------------------------
-- SIM-DOOR-2. Two offline phones admit the same ticket, then both upload.
-- ---------------------------------------------------------------------------
DO $$
DECLARE r jsonb; at_a timestamptz := now() - interval '20 minutes'; at_b timestamptz := now() - interval '15 minutes';
BEGIN
  PERFORM pg_temp.act('d7d00000-0000-0000-0000-0000000000a3');
  -- Phone B happens to upload first; the earlier scan (phone A) loses only
  -- because it arrived second: first upload wins.
  r := pg_temp.replay(1, 2, at_b, 'Door B');
  ASSERT r ->> 'reason' = 'checked-in', 'SIM-DOOR-2: first upload wins, got ' || r::text;
  r := pg_temp.replay(2, 2, at_a, 'Door A');
  ASSERT r ->> 'reason' = 'used' AND (r ->> 'conflict')::boolean AND NOT (r ? 'forced'),
         'SIM-DOOR-2: second upload is a conflict, not a second entry, got ' || r::text;
  ASSERT pg_temp.entries(2) = 1, 'SIM-DOOR-2: one entry row';
  ASSERT (SELECT count(*) FROM public.exos_scan_rejects
           WHERE ticket_id_attempted = pg_temp.tk(2)::text AND reason = 'used'
             AND reason_detail = 'offline-replay:used') = 1, 'SIM-DOOR-2: the conflict is in the scan report';
  -- The phone retries the same upload (lost response): same answer, no new rows.
  r := pg_temp.replay(2, 2, at_a, 'Door A');
  ASSERT (r ->> 'duplicate')::boolean AND r ->> 'reason' = 'used', 'SIM-DOOR-2: retry is a duplicate, got ' || r::text;
  ASSERT (SELECT count(*) FROM public.exos_scan_rejects WHERE ticket_id_attempted = pg_temp.tk(2)::text) = 1,
         'SIM-DOOR-2: the retry adds no reject';
  RAISE NOTICE 'OK SIM-DOOR-2 two offline phones: first upload wins, the other is a recorded conflict';
END $$;

-- ---------------------------------------------------------------------------
-- SIM-DOOR-3. Clocks off by 5 minutes, 1 hour, 1 day.
-- ---------------------------------------------------------------------------
DO $$
DECLARE r jsonb; v interval; v_owner uuid := 'd7d00000-0000-0000-0000-0000000000a5'; v_apple text;
BEGIN
  PERFORM pg_temp.act('d7d00000-0000-0000-0000-0000000000a3');
  -- (a) The holder's phone is off (it never reached the server to correct
  -- itself): its rotating code is from the wrong window. Refused, never
  -- burned; a minute either way is fine.
  FOREACH v IN ARRAY ARRAY[interval '5 minutes', interval '1 hour', interval '1 day',
                           interval '-5 minutes', interval '-1 hour', interval '-1 day'] LOOP
    r := pg_temp.scan(3, 'Door A', NULL, 'entry', NULL, pg_temp.tc(3, now() + v));
    ASSERT r ->> 'reason' = 'barcode-expired', 'SIM-DOOR-3a: holder clock ' || v || ', got ' || r::text;
  END LOOP;
  ASSERT pg_temp.status(3) = 'active', 'SIM-DOOR-3a: a refused code never uses the ticket';
  r := pg_temp.scan(3, 'Door A', NULL, 'entry', NULL, pg_temp.tc(3, now() - interval '50 seconds'));
  ASSERT r ->> 'reason' = 'checked-in', 'SIM-DOOR-3a: 50 seconds off is inside the window, got ' || r::text;

  -- (b) Wallet codes. Apple's is static (no clock); Google's TOTP is the
  -- holder phone's clock, so 5 minutes off is refused like a T- code.
  INSERT INTO public.exos_wallet_passes(serial_number, ticket_id, owner_id, code_epoch) VALUES
    ('exw' || md5('sd-pass-4'), pg_temp.tk(4), v_owner, 1), ('exw' || md5('sd-pass-5'), pg_temp.tk(5), v_owner, 1);
  v_apple := public._exos_wallet_apple_code(pg_temp.tk(4), v_owner, 'sd-4', 1);
  r := pg_temp.scan(4, 'Door A', NULL, 'entry', NULL, v_apple);
  ASSERT r ->> 'reason' = 'checked-in', 'SIM-DOOR-3b: Apple wallet code needs no clock, got ' || r::text;
  r := pg_temp.scan(5, 'Door A', NULL, 'entry', NULL,
         'W-' || pg_temp.tk(5) || ':' || v_owner || ':g1:' ||
         public._exos_wallet_totp(public._exos_wallet_google_key(pg_temp.tk(5), v_owner, 'sd-5', 1),
                                  floor(extract(epoch FROM now() + interval '5 minutes') / 30)::bigint));
  ASSERT r ->> 'reason' = 'barcode-rejected', 'SIM-DOOR-3b: Google TOTP 5 minutes ahead, got ' || r::text;
  r := pg_temp.scan(5, 'Door A', NULL, 'entry', NULL,
         'W-' || pg_temp.tk(5) || ':' || v_owner || ':g1:' ||
         public._exos_wallet_totp(public._exos_wallet_google_key(pg_temp.tk(5), v_owner, 'sd-5', 1),
                                  floor(extract(epoch FROM now()) / 30)::bigint));
  ASSERT r ->> 'reason' = 'checked-in', 'SIM-DOOR-3b: Google TOTP on time, got ' || r::text;

  -- (c) The DOOR phone's clock is off and it never synced (offline from the
  -- start). Its offline scans upload with its wrong time.
  --   1 hour ahead: a future scan time, refused 'bad-scan-time', not forced.
  r := pg_temp.replay(10, 6, now() + interval '1 hour', 'Door C', v_apple);
  ASSERT r ->> 'reason' = 'bad-scan-time' AND NOT (r ? 'forced'), 'SIM-DOOR-3c: door 1 h ahead, got ' || r::text;
  --   1 day behind, with a live code from the holder: "expired" at its time.
  r := pg_temp.replay(11, 7, now() - interval '1 day' + interval '5 minutes', 'Door C', pg_temp.tc(7));
  ASSERT r ->> 'reason' = 'barcode-expired' AND NOT (r ? 'forced'), 'SIM-DOOR-3c: door 1 day behind, got ' || r::text;
  -- The door let both in, but nothing records it and both tickets stay usable.
  PERFORM pg_temp.known('3c', pg_temp.status(6) = 'used' OR pg_temp.entries(6) > 0,
    'a door phone with a wrong clock that never synced: its admissions upload as bad-scan-time / '
    'barcode-expired, are not forced, and the tickets stay active (a static Apple code can be reused). '
    'Mitigated in the app: the measured clock offset is now kept across reloads (lib/serverClock).');
  RAISE NOTICE 'OK SIM-DOOR-3 clock skew: holder codes outside +-1 min refused, never burned; Apple static OK, Google TOTP refused';
END $$;

-- ---------------------------------------------------------------------------
-- SIM-DOOR-4. The roster was downloaded yesterday; refunds and transfers since.
-- ---------------------------------------------------------------------------
DO $$
DECLARE r jsonb; at timestamptz := now() - interval '30 minutes'; old_code text;
BEGIN
  PERFORM pg_temp.act('d7d00000-0000-0000-0000-0000000000a3');
  -- Refunded after the download: the stale list admitted them offline.
  UPDATE public.exos_tickets SET status = 'voided', voided_reason = 'refund' WHERE id = pg_temp.tk(8);
  r := pg_temp.replay(20, 8, at, 'Door A');
  ASSERT r ->> 'reason' = 'voided' AND (r ->> 'forced')::boolean,
         'SIM-DOOR-4: refunded since download: conflict, attendance forced, got ' || r::text;
  ASSERT pg_temp.status(8) = 'voided', 'SIM-DOOR-4: still voided';
  -- Transferred after the download: the old holder's code (old owner, old
  -- secret) is admitted offline; the new holder shows up with a fresh code.
  old_code := pg_temp.tc(9, at);
  INSERT INTO public.exos_transfers(id,ticket_id,org_id,sender_id,receiver_email,status,event_id,created_at,updated_at)
  VALUES ('d7d00000-0000-0000-0000-0000000007a9', pg_temp.tk(9), 'd7d00000-0000-0000-0000-000000000001',
          'd7d00000-0000-0000-0000-0000000000a5', 'sdnew@x.com', 'completed', 'd7d00000-0000-0000-0000-0000000000e1', now(), now());
  UPDATE public.exos_tickets SET owner_id = 'd7d00000-0000-0000-0000-0000000000a7', barcode_secret = 'sd-9-new'
   WHERE id = pg_temp.tk(9);
  r := pg_temp.scan(9, 'Door B');
  ASSERT r ->> 'reason' = 'checked-in', 'SIM-DOOR-4: the new holder, online, got ' || r::text;
  r := pg_temp.replay(21, 9, at, 'Door A', old_code);
  ASSERT r ->> 'reason' = 'barcode-rejected' AND r ->> 'conflict_reason' = 'post-transfer' AND (r ->> 'forced')::boolean,
         'SIM-DOOR-4: the old holder upload is a post-transfer conflict, got ' || r::text;
  -- Both people are inside on one ticket. It is recorded (forced row), which
  -- is all an offline door can do once the old holder is in.
  ASSERT pg_temp.entries(9) = 2 AND (SELECT count(*) FROM public.exos_event_checkins
                                     WHERE ticket_id = pg_temp.tk(9) AND forced) = 1,
         'SIM-DOOR-4: both entries recorded, the stale one forced';
  RAISE NOTICE 'OK SIM-DOOR-4 stale roster: refund -> forced conflict; transfer -> new holder in, old holder recorded as post-transfer';
END $$;

-- ---------------------------------------------------------------------------
-- SIM-DOOR-5. Wrong event, wrong list, a list of another event.
-- ---------------------------------------------------------------------------
DO $$
DECLARE r jsonb;
BEGIN
  PERFORM pg_temp.act('d7d00000-0000-0000-0000-0000000000a3');
  -- The scanner is open on e1; the ticket is for e2.
  r := pg_temp.scan(50, 'Door A', NULL, 'entry', pg_temp.u('e1'));
  ASSERT r ->> 'reason' = 'wrong-event', 'SIM-DOOR-5: wrong event, got ' || r::text;
  ASSERT pg_temp.status(50) = 'active' AND pg_temp.entries(50) = 0, 'SIM-DOOR-5: wrong event changes nothing';
  -- GA at the VIP deck.
  r := pg_temp.scan(11, 'Door A', 'aa02');
  ASSERT r ->> 'reason' = 'wrong-list' AND r ->> 'list' = 'VIP deck', 'SIM-DOOR-5: wrong list, got ' || r::text;
  -- The device still has e2's list selected.
  r := pg_temp.scan(11, 'Door A', 'aa09');
  ASSERT r ->> 'reason' = 'unknown-list', 'SIM-DOOR-5: another event''s list, got ' || r::text;
  ASSERT pg_temp.status(11) = 'active' AND pg_temp.entries(11) = 0, 'SIM-DOOR-5: refusals change nothing';
  r := pg_temp.scan(11, 'Door A', 'aa01');
  ASSERT r ->> 'reason' = 'checked-in', 'SIM-DOOR-5: then the right list, got ' || r::text;
  RAISE NOTICE 'OK SIM-DOOR-5 wrong event / wrong list / stale list: refused, nothing burned';
END $$;

-- ---------------------------------------------------------------------------
-- SIM-DOOR-6. Re-entry on a list that doesn't allow it.
-- ---------------------------------------------------------------------------
DO $$
DECLARE r jsonb;
BEGIN
  PERFORM pg_temp.act('d7d00000-0000-0000-0000-0000000000a3');
  r := pg_temp.scan(11, 'Door A', 'aa01', 'exit');
  ASSERT r ->> 'reason' = 'exit-not-allowed', 'SIM-DOOR-6: exit on the main door, got ' || r::text;
  r := pg_temp.scan(11, 'Door A', 'aa01');
  ASSERT r ->> 'reason' = 'used', 'SIM-DOOR-6: back in on the main door, got ' || r::text;
  r := pg_temp.scan(11, 'Door A', NULL, 'exit');
  ASSERT r ->> 'reason' = 'exit-not-allowed', 'SIM-DOOR-6: exit with no list, got ' || r::text;
  ASSERT pg_temp.entries(11) = 1, 'SIM-DOOR-6: one entry';
  RAISE NOTICE 'OK SIM-DOOR-6 no re-entry: exit refused, second entry is "used"';
END $$;

-- ---------------------------------------------------------------------------
-- SIM-DOOR-7. Check-out without check-in (a phone left in Exit mode). FIXED.
-- ---------------------------------------------------------------------------
DO $$
DECLARE r jsonb;
BEGIN
  PERFORM pg_temp.act('d7d00000-0000-0000-0000-0000000000a3');
  r := pg_temp.scan(12, 'Door A', 'aa03', 'exit');
  ASSERT r ->> 'reason' = 'not-inside' AND NOT (r ->> 'ok')::boolean,
         'SIM-DOOR-7: an exit for a ticket never admitted is refused, got ' || r::text;
  r := public.exos_door_checkin_by_name(pg_temp.tk(12), pg_temp.u('e1'), NULL, 'Door A', NULL, NULL, pg_temp.lst('aa03'), 'exit');
  ASSERT r ->> 'reason' = 'not-inside', 'SIM-DOOR-7: by name too, got ' || r::text;
  ASSERT (SELECT count(*) FROM public.exos_event_checkins WHERE ticket_id = pg_temp.tk(12)) = 0, 'SIM-DOOR-7: nothing recorded';
  -- The normal pass-out still works: in, out, in.
  ASSERT pg_temp.scan(12, 'Door A', 'aa03') ->> 'reason' = 'checked-in', 'SIM-DOOR-7: in';
  ASSERT pg_temp.scan(12, 'Door A', 'aa03', 'exit') ->> 'reason' = 'checked-out', 'SIM-DOOR-7: out';
  r := pg_temp.scan(12, 'Door A', 'aa03');
  ASSERT r ->> 'reason' = 'checked-in' AND (r ->> 'reentry')::boolean, 'SIM-DOOR-7: back in, got ' || r::text;
  -- An offline exit upload for a ticket never admitted: a conflict, not forced.
  r := pg_temp.replay(30, 13, now() - interval '10 minutes', 'Door A', NULL, 'aa03', 'exit');
  ASSERT r ->> 'reason' = 'not-inside' AND (r ->> 'conflict')::boolean AND NOT (r ? 'forced'),
         'SIM-DOOR-7: offline exit upload, got ' || r::text;
  RAISE NOTICE 'OK SIM-DOOR-7 check-out without check-in: refused not-inside (fixed), pass-out unchanged';
END $$;

-- ---------------------------------------------------------------------------
-- SIM-DOOR-8. Order check-out (#80) right after a scan on the same order.
-- (The parallel version is tests/exos/race_sim_door.sh.)
-- ---------------------------------------------------------------------------
INSERT INTO public.exos_checkout_sessions(session_id,event_id,org_id,buyer_uid,buyer_email,quantity,amount_cents,status)
VALUES ('cs_simdoor_1','d7d00000-0000-0000-0000-0000000000e1','d7d00000-0000-0000-0000-000000000001',
        'd7d00000-0000-0000-0000-0000000000a5','sdhold@x.com',2,10000,'fulfilled');
UPDATE public.exos_tickets SET order_ref = 'cs_simdoor_1' WHERE id IN (pg_temp.tk(14), pg_temp.tk(15));
DO $$
DECLARE r jsonb;
BEGIN
  PERFORM pg_temp.act('d7d00000-0000-0000-0000-0000000000a3');
  ASSERT pg_temp.scan(14, 'Door A', 'aa03') ->> 'reason' = 'checked-in', 'SIM-DOOR-8: 14 in';
  -- A scanner can't check an order out.
  ASSERT pg_temp.raises($q$SELECT public.exos_order_check_out('cs_simdoor_1')$q$, '42501'), 'SIM-DOOR-8: scanner refused';
  PERFORM pg_temp.act('d7d00000-0000-0000-0000-0000000000a2');
  r := public.exos_order_check_out('cs_simdoor_1');
  ASSERT (r ->> 'checked_out')::int = 1, 'SIM-DOOR-8: only the ticket inside is checked out, got ' || r::text;
  ASSERT (SELECT bool_and(x ->> 'reason' IN ('checked-out', 'not-inside')) FROM jsonb_array_elements(r -> 'results') x),
         'SIM-DOOR-8: 15 was never in: not-inside, got ' || r::text;
  -- The holder walks straight back in at the next scan.
  PERFORM pg_temp.act('d7d00000-0000-0000-0000-0000000000a3');
  r := pg_temp.scan(14, 'Door B', 'aa03');
  ASSERT r ->> 'reason' = 'checked-in' AND (r ->> 'reentry')::boolean, 'SIM-DOOR-8: back in, got ' || r::text;
  -- Checking the order out twice: the second finds nobody new outside.
  PERFORM pg_temp.act('d7d00000-0000-0000-0000-0000000000a2');
  ASSERT (public.exos_order_check_out('cs_simdoor_1') ->> 'checked_out')::int = 1, 'SIM-DOOR-8: out again';
  ASSERT (public.exos_order_check_out('cs_simdoor_1') ->> 'checked_out')::int = 0, 'SIM-DOOR-8: twice is a no-op';
  RAISE NOTICE 'OK SIM-DOOR-8 order check-out next to a scan: only the inside ticket exits, a repeat is a no-op';
END $$;

-- ---------------------------------------------------------------------------
-- SIM-DOOR-9. Imported codes typed with a typo, spaces, other case.
-- ---------------------------------------------------------------------------
DO $$
DECLARE r jsonb; v_list uuid;
BEGIN
  PERFORM pg_temp.act('d7d00000-0000-0000-0000-0000000000a2');
  INSERT INTO public.exos_guest_lists(id, event_id, org_id, name)
  VALUES (pg_temp.u('b1'), pg_temp.u('e1'), pg_temp.u('01')::uuid, 'Eventbrite import')
  RETURNING id INTO v_list;
  r := public.exos_import_guests(v_list, jsonb_build_array(
         jsonb_build_object('name', 'Eb One',  'code', '  eb-1234 5678 ', 'source', 'Eventbrite'),
         jsonb_build_object('name', 'Luma Two', 'code', 'gst-AbC9', 'source', 'Luma'),
         jsonb_build_object('name', 'Eb One again', 'code', 'EB-12345678'),
         jsonb_build_object('name', 'Too long', 'code', repeat('x', 129))));
  ASSERT (r ->> 'inserted')::int = 2 AND (r ->> 'duplicates')::int = 1 AND (r ->> 'invalid')::int = 1,
         'SIM-DOOR-9: the same code in other spacing/case is a duplicate, got ' || r::text;
  ASSERT public._exos_door_code(' eb-1234  5678') = 'EB-12345678', 'SIM-DOOR-9: spaces and case';
  ASSERT public._exos_door_code(E'gst-abc9\t') = 'GST-ABC9', 'SIM-DOOR-9: a tab from a keyboard wedge';
  -- A typo is a different code: no match (the door then offers name search).
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_guest_list_entries
                      WHERE event_id = pg_temp.u('e1') AND external_code = public._exos_door_code('EB-12345679')),
         'SIM-DOOR-9: a one-digit typo matches nobody';
  -- Dropped hyphen: also no match. The door's typed search could ignore
  -- punctuation; it doesn't today.
  PERFORM pg_temp.known('9', EXISTS (SELECT 1 FROM public.exos_guest_list_entries
                      WHERE event_id = pg_temp.u('e1') AND external_code = public._exos_door_code('EB12345678')),
    'an imported code typed without its hyphen (EB12345678 for EB-1234 5678) matches nobody: normalization '
    'drops whitespace and case only. Proposal: also compare with punctuation removed when there is no exact hit.');
  RAISE NOTICE 'OK SIM-DOOR-9 imported codes: spaces / case / tabs normalized, typos refused';
END $$;

-- ---------------------------------------------------------------------------
-- SIM-DOOR-10. By name: the wrong "Alex Kim" is checked in, then undone.
-- ---------------------------------------------------------------------------
UPDATE public.exos_tickets SET attendee_name = 'Alex Kim' WHERE id IN (pg_temp.tk(16), pg_temp.tk(17));
DO $$
DECLARE r jsonb;
BEGIN
  PERFORM pg_temp.act('d7d00000-0000-0000-0000-0000000000a3');
  r := public.exos_door_checkin_by_name(pg_temp.tk(16), pg_temp.u('e1'), 'ID checked', 'Door A');
  ASSERT r ->> 'reason' = 'checked-in' AND r ->> 'name' = 'Alex Kim', 'SIM-DOOR-10: wrong Alex in, got ' || r::text;
  -- The scanner who made the mistake can't undo it.
  r := public.exos_undo_check_in(pg_temp.tk(16), pg_temp.u('e1'), 'wrong Alex Kim');
  ASSERT r ->> 'reason' = 'needs-manager', 'SIM-DOOR-10: scanner undo, got ' || r::text;
  PERFORM pg_temp.act('d7d00000-0000-0000-0000-0000000000a2');
  ASSERT public.exos_undo_check_in(pg_temp.tk(16), pg_temp.u('e1'), 'x') ->> 'reason' = 'reason-required', 'SIM-DOOR-10: reason';
  r := public.exos_undo_check_in(pg_temp.tk(16), pg_temp.u('e1'), 'wrong Alex Kim');
  ASSERT r ->> 'reason' = 'undone' AND pg_temp.status(16) = 'active' AND pg_temp.entries(16) = 0,
         'SIM-DOOR-10: undone, got ' || r::text;
  ASSERT (SELECT count(*) FROM public.exos_checkin_undos WHERE ticket_id = pg_temp.tk(16)) = 1, 'SIM-DOOR-10: audited';
  PERFORM pg_temp.act('d7d00000-0000-0000-0000-0000000000a3');
  ASSERT public.exos_door_checkin_by_name(pg_temp.tk(17), pg_temp.u('e1'), NULL, 'Door A') ->> 'reason' = 'checked-in',
         'SIM-DOOR-10: the right Alex';
  -- Undo is owner / manager only, by design (it re-opens a ticket for entry).
  RAISE NOTICE 'OK SIM-DOOR-10 wrong same-name ticket: manager undo restores it (scanners need a manager, intended)';
END $$;

-- ---------------------------------------------------------------------------
-- SIM-DOOR-11. Guest list: the wrong "Sam Lee" arrives, then undone. FIXED.
-- ---------------------------------------------------------------------------
INSERT INTO public.exos_guest_lists(id, event_id, org_id, name)
VALUES (pg_temp.u('b2'), pg_temp.u('e1'), pg_temp.u('01')::uuid, 'Friends');
INSERT INTO public.exos_guest_list_entries(id, list_id, event_id, org_id, guest_name, plus_ones) VALUES
  (pg_temp.u('c1'), pg_temp.u('b2'), pg_temp.u('e1'), pg_temp.u('01')::uuid, 'Sam Lee', 1),
  (pg_temp.u('c2'), pg_temp.u('b2'), pg_temp.u('e1'), pg_temp.u('01')::uuid, 'Sam Lee', 0);
DO $$
DECLARE r jsonb;
BEGIN
  PERFORM pg_temp.act('d7d00000-0000-0000-0000-0000000000a3');
  ASSERT public.exos_guest_check_in(pg_temp.u('c1'), 2, pg_temp.u('e1')) ->> 'reason' = 'checked-in', 'SIM-DOOR-11: wrong Sam +1';
  r := public.exos_guest_undo_arrival(pg_temp.u('c1'), pg_temp.u('e1'), NULL, 'wrong Sam Lee');
  ASSERT r ->> 'reason' = 'needs-manager', 'SIM-DOOR-11: a scanner needs a manager, got ' || r::text;
  PERFORM pg_temp.act('d7d00000-0000-0000-0000-0000000000a6');
  ASSERT pg_temp.raises($q$SELECT public.exos_guest_undo_arrival('d7d00000-0000-0000-0000-0000000000c1',
           'd7d00000-0000-0000-0000-0000000000e1', NULL, 'not mine')$q$, '42501'), 'SIM-DOOR-11: another org';
  PERFORM pg_temp.act('d7d00000-0000-0000-0000-0000000000a2');
  ASSERT public.exos_guest_undo_arrival(pg_temp.u('c1'), pg_temp.u('e1'), 3, 'wrong Sam') ->> 'reason' = 'bad-count',
         'SIM-DOOR-11: more than arrived';
  ASSERT public.exos_guest_undo_arrival(pg_temp.u('c1'), pg_temp.u('e2'), NULL, 'wrong Sam') ->> 'reason' = 'wrong-event',
         'SIM-DOOR-11: wrong event';
  r := public.exos_guest_undo_arrival(pg_temp.u('c1'), pg_temp.u('e1'), NULL, 'wrong Sam Lee');
  ASSERT r ->> 'reason' = 'undone' AND (r ->> 'arrived')::int = 0, 'SIM-DOOR-11: undone, got ' || r::text;
  ASSERT (SELECT arrived = 0 AND arrived_at IS NULL FROM public.exos_guest_list_entries WHERE id = pg_temp.u('c1')),
         'SIM-DOOR-11: entry back to expected';
  ASSERT (SELECT count = 2 AND arrived_was = 2 AND reason = 'wrong Sam Lee' FROM public.exos_guest_checkin_undos
           WHERE entry_id = pg_temp.u('c1')), 'SIM-DOOR-11: audited';
  ASSERT public.exos_guest_undo_arrival(pg_temp.u('c1'), pg_temp.u('e1'), NULL, 'again') ->> 'reason' = 'not-checked-in',
         'SIM-DOOR-11: twice';
  PERFORM pg_temp.act('d7d00000-0000-0000-0000-0000000000a3');
  ASSERT public.exos_guest_check_in(pg_temp.u('c2'), 1, pg_temp.u('e1')) ->> 'reason' = 'checked-in', 'SIM-DOOR-11: the right Sam';
  ASSERT public.exos_guest_check_in(pg_temp.u('c1'), 2, pg_temp.u('e1')) ->> 'reason' = 'checked-in',
         'SIM-DOOR-11: the first Sam can still arrive later';
  -- Undo log: door staff read their org's, nobody else.
  SET LOCAL ROLE authenticated;
  ASSERT (SELECT count(*) FROM public.exos_guest_checkin_undos) = 1, 'SIM-DOOR-11: scanner reads the undo';
  PERFORM pg_temp.act('d7d00000-0000-0000-0000-0000000000a6');
  ASSERT (SELECT count(*) FROM public.exos_guest_checkin_undos) = 0, 'SIM-DOOR-11: another org reads nothing';
  RESET ROLE;
  ASSERT NOT has_function_privilege('anon', 'public.exos_guest_undo_arrival(uuid,uuid,integer,text)', 'EXECUTE'),
         'SIM-DOOR-11: not for anon';
  RAISE NOTICE 'OK SIM-DOOR-11 guest-list wrong person: manager undo (fixed), audited, cross-org refused';
END $$;

-- ---------------------------------------------------------------------------
-- SIM-DOOR-12. A voided Eventbrite attendee is admitted offline. FIXED (logged).
-- ---------------------------------------------------------------------------
INSERT INTO public.exos_guest_list_entries(id, list_id, event_id, org_id, guest_name, external_code, source, voided_at, void_reason) VALUES
  (pg_temp.u('c3'), pg_temp.u('b1'), pg_temp.u('e1'), pg_temp.u('01')::uuid, 'Eb Refunded', 'EB-REF-1', 'Eventbrite', now(), 'refunded');
DO $$
DECLARE r jsonb;
BEGIN
  PERFORM pg_temp.act('d7d00000-0000-0000-0000-0000000000a3');
  -- Online the door refuses (the guest list it holds is current).
  r := public.exos_guest_check_in(pg_temp.u('c3'), 1, pg_temp.u('e1'), NULL);
  ASSERT r ->> 'reason' = 'voided' AND r ->> 'source' = 'Eventbrite' AND NOT (r ? 'conflict'),
         'SIM-DOOR-12: online voided, got ' || r::text;
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_scan_rejects WHERE ticket_id_attempted = pg_temp.u('c3')::text),
         'SIM-DOOR-12: an online refusal is the door''s to log';
  -- Offline the door's list predates the void: it let them in; the upload
  -- is refused AND now goes to the scan report.
  r := public.exos_guest_check_in(pg_temp.u('c3'), 1, pg_temp.u('e1'), pg_temp.ref(40), 'offline-sync');
  ASSERT r ->> 'reason' = 'voided' AND (r ->> 'conflict')::boolean, 'SIM-DOOR-12: offline replay, got ' || r::text;
  ASSERT (SELECT reason = 'voided' AND reason_detail = 'guest-replay:voided:1' FROM public.exos_scan_rejects
           WHERE ticket_id_attempted = pg_temp.u('c3')::text), 'SIM-DOOR-12: in the scan report';
  ASSERT (SELECT arrived FROM public.exos_guest_list_entries WHERE id = pg_temp.u('c3')) = 0, 'SIM-DOOR-12: not counted';
  RAISE NOTICE 'OK SIM-DOOR-12 voided Eventbrite attendee admitted offline: refused on upload and logged (fixed)';
END $$;

-- ---------------------------------------------------------------------------
-- SIM-DOOR-13. Two offline phones admit the same guest-list guest. FIXED (logged).
-- ---------------------------------------------------------------------------
INSERT INTO public.exos_guest_list_entries(id, list_id, event_id, org_id, guest_name) VALUES
  (pg_temp.u('c4'), pg_temp.u('b2'), pg_temp.u('e1'), pg_temp.u('01')::uuid, 'Solo Guest');
DO $$
DECLARE r jsonb;
BEGIN
  PERFORM pg_temp.act('d7d00000-0000-0000-0000-0000000000a3');
  ASSERT public.exos_guest_check_in(pg_temp.u('c4'), 1, pg_temp.u('e1'), pg_temp.ref(41), 'offline-sync') ->> 'reason' = 'checked-in',
         'SIM-DOOR-13: phone A';
  r := public.exos_guest_check_in(pg_temp.u('c4'), 1, pg_temp.u('e1'), pg_temp.ref(42), 'offline-sync');
  ASSERT r ->> 'reason' = 'used' AND (r ->> 'conflict')::boolean, 'SIM-DOOR-13: phone B, got ' || r::text;
  ASSERT (SELECT arrived FROM public.exos_guest_list_entries WHERE id = pg_temp.u('c4')) = 1, 'SIM-DOOR-13: counted once';
  ASSERT (SELECT count(*) FROM public.exos_scan_rejects WHERE ticket_id_attempted = pg_temp.u('c4')::text
             AND reason = 'used' AND reason_detail = 'guest-replay:used:1') = 1, 'SIM-DOOR-13: the conflict is logged';
  -- Phone A retries its own upload: a duplicate, not a conflict.
  r := public.exos_guest_check_in(pg_temp.u('c4'), 1, pg_temp.u('e1'), pg_temp.ref(41), 'offline-sync');
  ASSERT r ->> 'reason' = 'duplicate' AND (r ->> 'ok')::boolean, 'SIM-DOOR-13: retry, got ' || r::text;
  RAISE NOTICE 'OK SIM-DOOR-13 two offline phones, one guest: counted once, the other upload logged (fixed)';
END $$;

-- ---------------------------------------------------------------------------
-- SIM-DOOR-14. Doors not open yet; the event has ended.
-- ---------------------------------------------------------------------------
DO $$
DECLARE r jsonb;
BEGIN
  PERFORM pg_temp.act('d7d00000-0000-0000-0000-0000000000a3');
  r := pg_temp.scan(51);
  ASSERT r ->> 'reason' = 'doors-not-open' AND r ? 'opens_at' AND pg_temp.status(51) = 'active',
         'SIM-DOOR-14: before doors, got ' || r::text;
  r := public.exos_door_checkin_by_name(pg_temp.tk(51), pg_temp.u('e3'), NULL, 'Door A');
  ASSERT r ->> 'reason' = 'doors-not-open', 'SIM-DOOR-14: by name before doors, got ' || r::text;
  -- After the end the door still admits (a late arrival, a long night): no
  -- end-of-event gate, the same as pretix's default. Intended.
  r := pg_temp.scan(52);
  ASSERT r ->> 'reason' = 'checked-in', 'SIM-DOOR-14: after the end, got ' || r::text;
  RAISE NOTICE 'OK SIM-DOOR-14 doors not open: refused, nothing used; after the end: admitted (no end gate, intended)';
END $$;

-- ---------------------------------------------------------------------------
-- SIM-DOOR-15. Another org's ticket; a disabled or re-scoped scanner keeps
-- scanning offline. FIXED (re-scoped uploads stay queued).
-- ---------------------------------------------------------------------------
DO $$
DECLARE r jsonb; at timestamptz := now() - interval '40 minutes';
BEGIN
  -- Org 1's scanner reads org 2's ticket: refused as an auth error, nothing written.
  PERFORM pg_temp.act('d7d00000-0000-0000-0000-0000000000a3');
  ASSERT pg_temp.raises($q$SELECT pg_temp.scan(53, 'Door A', NULL, 'entry', 'd7d00000-0000-0000-0000-0000000000e9')$q$, '42501'),
         'SIM-DOOR-15: other org ticket';
  ASSERT pg_temp.raises($q$SELECT pg_temp.replay(50, 53, now() - interval '5 minutes', 'Door A')$q$, '42501'),
         'SIM-DOOR-15: other org replay';
  ASSERT pg_temp.status(53) = 'active' AND NOT EXISTS (SELECT 1 FROM public.exos_checkin_client_refs WHERE client_ref = pg_temp.ref(50)),
         'SIM-DOOR-15: nothing written for another org';

  -- a8 is disabled while their phone holds offline admits.
  UPDATE public.exos_org_memberships SET disabled = true
   WHERE org_id = pg_temp.u('01')::uuid AND user_id = pg_temp.u('a8');
  PERFORM pg_temp.act('d7d00000-0000-0000-0000-0000000000a8');
  ASSERT pg_temp.raises($q$SELECT pg_temp.replay(51, 18, now() - interval '40 minutes', 'Door Z')$q$, '42501'),
         'SIM-DOOR-15: disabled scanner upload is an auth error (kept on the phone)';
  -- a4 is moved from e1 to e2 before uploading e1 scans.
  UPDATE public.exos_event_staff SET event_id = pg_temp.u('e2') WHERE user_id = pg_temp.u('a4');
  PERFORM pg_temp.act('d7d00000-0000-0000-0000-0000000000a4');
  ASSERT pg_temp.raises(format('SELECT pg_temp.replay(52, 19, %L, %L)', at, 'Door Y'), '42501'),
         'SIM-DOOR-15: re-scoped scanner upload raises (kept), not a final not-assigned';
  ASSERT pg_temp.raises(format($q$SELECT public.exos_door_checkin_by_name(%L, %L, NULL, 'Door Y', %L, %L, NULL, 'entry')$q$,
           pg_temp.tk(20), pg_temp.u('e1'), at, pg_temp.ref(53)), '42501'), 'SIM-DOOR-15: re-scoped by-name upload raises';
  ASSERT pg_temp.raises(format($q$SELECT public.exos_guest_check_in(%L, 1, %L, %L, 'offline-sync')$q$,
           pg_temp.u('c2'), pg_temp.u('e1'), pg_temp.ref(54)), '42501'), 'SIM-DOOR-15: re-scoped guest upload raises';
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_checkin_client_refs WHERE client_ref IN (pg_temp.ref(51), pg_temp.ref(52), pg_temp.ref(53)))
         AND pg_temp.status(19) = 'active' AND pg_temp.status(20) = 'active', 'SIM-DOOR-15: no answer recorded for the refs';
  -- A manager signs in on that phone and the same scans upload.
  PERFORM pg_temp.act('d7d00000-0000-0000-0000-0000000000a2');
  r := pg_temp.replay(52, 19, at, 'Door Y');
  ASSERT r ->> 'reason' = 'checked-in', 'SIM-DOOR-15: a manager uploads the kept scan, got ' || r::text;
  r := public.exos_door_checkin_by_name(pg_temp.tk(20), pg_temp.u('e1'), NULL, 'Door Y', at, pg_temp.ref(53), NULL, 'entry');
  ASSERT r ->> 'reason' = 'checked-in', 'SIM-DOOR-15: and the by-name one, got ' || r::text;
  -- A signed-out phone (no session) is refused outright.
  PERFORM pg_temp.act(NULL);
  ASSERT pg_temp.raises($q$SELECT pg_temp.replay(55, 21, now() - interval '5 minutes', 'Door Z')$q$, '42501'),
         'SIM-DOOR-15: signed out';
  RAISE NOTICE 'OK SIM-DOOR-15 other org / disabled / re-scoped / signed-out phones: refused as auth, scans kept for a manager (fixed)';
END $$;

-- ---------------------------------------------------------------------------
-- SIM-DOOR-16. A forced offline admission leaves the ticket usable.
-- ---------------------------------------------------------------------------
DO $$
DECLARE r jsonb;
BEGIN
  PERFORM pg_temp.act('d7d00000-0000-0000-0000-0000000000a3');
  -- The phone's saved list didn't know the VIP deck admits VIP only (the
  -- list was edited after the download): a GA ticket went in offline.
  r := pg_temp.replay(60, 22, now() - interval '25 minutes', 'Door A', NULL, 'aa02', 'entry');
  ASSERT r ->> 'reason' = 'wrong-list' AND (r ->> 'forced')::boolean, 'SIM-DOOR-16: forced, got ' || r::text;
  -- Same ticket at the main door, online, later.
  r := pg_temp.scan(22, 'Door B', 'aa01');
  PERFORM pg_temp.known('16', r ->> 'reason' = 'used',
    'an entry the server refused but forced (wrong-list, invalid-time, doors-not-open, too-old) never uses the '
    'ticket (mig 20260929140000 "a forced row never changes the ticket"), so the same ticket gets in again: '
    'second scan answered ' || coalesce(r ->> 'reason', '?') || '. Proposal: for those four conflicts on an '
    'active ticket with no pending transfer, also set status used (keep voided / transfer conflicts as they are).');
  RAISE NOTICE 'OK SIM-DOOR-16 checked (see KNOWN above)';
END $$;

-- ---------------------------------------------------------------------------
-- SIM-DOOR-17. A wallet pass from before the latest epoch.
-- ---------------------------------------------------------------------------
DO $$
DECLARE r jsonb; v_owner uuid := 'd7d00000-0000-0000-0000-0000000000a5'; v_old text; v_new text; k jsonb;
BEGIN
  INSERT INTO public.exos_wallet_passes(serial_number, ticket_id, owner_id, code_epoch) VALUES ('exw' || md5('sd-pass-23'), pg_temp.tk(23), v_owner, 1);
  v_old := public._exos_wallet_apple_code(pg_temp.tk(23), v_owner, 'sd-23', 1);
  PERFORM pg_temp.act('d7d00000-0000-0000-0000-0000000000a5');
  ASSERT (public.exos_wallet_reissue(pg_temp.tk(23)) ->> 'code_epoch')::int = 2, 'SIM-DOOR-17: reissued';
  v_new := public._exos_wallet_apple_code(pg_temp.tk(23), v_owner, 'sd-23', 2);
  PERFORM pg_temp.act('d7d00000-0000-0000-0000-0000000000a3');
  -- The door's keys are for the live epoch only.
  k := public.exos_door_ticket_keys(pg_temp.tk(23));
  ASSERT (k ->> 'we')::int = 2 AND k ->> 'wa' = encode(extensions.digest(v_new, 'sha256'), 'hex'),
         'SIM-DOOR-17: door keys follow the epoch';
  r := pg_temp.scan(23, 'Door A', NULL, 'entry', NULL, v_old);
  ASSERT r ->> 'reason' = 'barcode-rejected' AND pg_temp.status(23) = 'active', 'SIM-DOOR-17: old pass, got ' || r::text;
  -- An old pass a stale phone admitted offline: refused, not forced (not proof of a valid code).
  r := pg_temp.replay(61, 23, now() - interval '5 minutes', 'Door C', v_old);
  ASSERT r ->> 'reason' = 'barcode-rejected' AND NOT (r ? 'forced'), 'SIM-DOOR-17: old pass offline, got ' || r::text;
  r := pg_temp.scan(23, 'Door A', NULL, 'entry', NULL, v_new);
  ASSERT r ->> 'reason' = 'checked-in', 'SIM-DOOR-17: the reissued pass, got ' || r::text;
  RAISE NOTICE 'OK SIM-DOOR-17 pre-epoch wallet pass: refused online and on upload; the live pass works';
END $$;

-- ---------------------------------------------------------------------------
-- SIM-DOOR-18. A T- code signed with yesterday's day key around midnight.
-- ---------------------------------------------------------------------------
DO $$
DECLARE r jsonb; utc0 timestamptz := date_trunc('day', now() AT TIME ZONE 'UTC') AT TIME ZONE 'UTC';
        ny0 timestamptz := date_trunc('day', now() AT TIME ZONE 'America/New_York') AT TIME ZONE 'America/New_York';
        k jsonb; today int := floor(extract(epoch FROM now()) / 86400)::int;
BEGIN
  PERFORM pg_temp.act('d7d00000-0000-0000-0000-0000000000a3');
  -- Signed 15 s before UTC midnight (yesterday's key), scanned 15 s after.
  ASSERT floor(floor(extract(epoch FROM utc0 - interval '15 seconds') * 1000 / 30000) / 2880) = today - 1,
         'SIM-DOOR-18: the code is from yesterday''s key day';
  r := pg_temp.replay(70, 24, utc0 + interval '15 seconds', 'Door A', pg_temp.tc(24, utc0 - interval '15 seconds'));
  ASSERT r ->> 'reason' = 'checked-in', 'SIM-DOOR-18: across UTC midnight, got ' || r::text;
  -- The event's local midnight (New York) is not a key boundary at all.
  r := pg_temp.replay(71, 25, ny0 + interval '15 seconds', 'Door A', pg_temp.tc(25, ny0 - interval '15 seconds'));
  ASSERT r ->> 'reason' = 'checked-in', 'SIM-DOOR-18: across New York midnight, got ' || r::text;
  -- What the door downloads: yesterday's, today's and tomorrow's keys.
  k := public.exos_door_ticket_keys(pg_temp.tk(26));
  ASSERT (SELECT array_agg(x::int ORDER BY x::int) FROM jsonb_object_keys(k -> 'd') x) = ARRAY[today - 1, today, today + 1],
         'SIM-DOOR-18: three day keys, got ' || k::text;
  ASSERT k -> 'd' ->> (today - 1)::text = public._exos_door_day_key(pg_temp.tk(26), 'sd-26', today - 1),
         'SIM-DOOR-18: yesterday''s key matches the holder''s';
  ASSERT NOT (k::text LIKE '%sd-26%'), 'SIM-DOOR-18: never the secret';
  RAISE NOTICE 'OK SIM-DOOR-18 day keys: codes from yesterday''s key accepted across UTC and local midnight';
END $$;

-- ---------------------------------------------------------------------------
-- SIM-DOOR-19. A comp issued at the door twice. FIXED for the mint; the email
-- batch is KNOWN.
-- ---------------------------------------------------------------------------
DO $$
DECLARE a uuid[]; b uuid[]; n0 int; n1 int; r record; c int;
BEGIN
  PERFORM pg_temp.act('d7d00000-0000-0000-0000-0000000000a2');
  n0 := (SELECT tickets_sold FROM public.exos_events WHERE id = pg_temp.u('e1'));
  -- The mint call timed out and the box office tapped again (same ref).
  a := public.exos_mint_tickets(pg_temp.u('e1'), pg_temp.u('f1'), 2, 'door-comp-7f3a', 0);
  b := public.exos_mint_tickets(pg_temp.u('e1'), pg_temp.u('f1'), 2, 'door-comp-7f3a', 0);
  ASSERT a @> b AND b @> a AND array_length(b, 1) = 2, 'SIM-DOOR-19: same ref, same tickets';
  ASSERT (SELECT count(*) FROM public.exos_tickets WHERE order_ref = 'door-comp-7f3a') = 2, 'SIM-DOOR-19: two tickets, not four';
  n1 := (SELECT tickets_sold FROM public.exos_events WHERE id = pg_temp.u('e1'));
  ASSERT n1 = n0 + 2, 'SIM-DOOR-19: capacity counted once';
  ASSERT pg_temp.raises($q$SELECT public.exos_mint_tickets('d7d00000-0000-0000-0000-0000000000e1',
           'd7d00000-0000-0000-0000-0000000000f1', 3, 'door-comp-7f3a', 0)$q$, '23505'), 'SIM-DOOR-19: same ref, other quantity';
  -- Another staff member using the same ref string is a different request.
  PERFORM pg_temp.act('d7d00000-0000-0000-0000-0000000000a1');
  b := public.exos_mint_tickets(pg_temp.u('e1'), pg_temp.u('f1'), 2, 'door-comp-7f3a', 0);
  ASSERT NOT (a && b), 'SIM-DOOR-19: the owner''s own mint is separate';
  -- A fresh ref per mint (what the app sends today) is unchanged.
  PERFORM pg_temp.act('d7d00000-0000-0000-0000-0000000000a2');
  a := public.exos_mint_tickets(pg_temp.u('e1'), pg_temp.u('f1'), 1, NULL, 0);
  b := public.exos_mint_tickets(pg_temp.u('e1'), pg_temp.u('f1'), 1, NULL, 0);
  ASSERT a <> b, 'SIM-DOOR-19: no ref, two mints';

  -- The email comp batch has no request key: sending the same guest twice
  -- issues twice.
  FOR r IN SELECT * FROM public.exos_issue_comp_batch(pg_temp.u('e1'), pg_temp.u('f1'), ARRAY['sdhold@x.com'], 1) LOOP END LOOP;
  FOR r IN SELECT * FROM public.exos_issue_comp_batch(pg_temp.u('e1'), pg_temp.u('f1'), ARRAY['SDHold@x.com '], 1) LOOP END LOOP;
  c := (SELECT count(*) FROM public.exos_tickets WHERE event_id = pg_temp.u('e1') AND channel_source = 'comp'
          AND buyer_email = 'sdhold@x.com');
  PERFORM pg_temp.known('19', c = 1,
    'exos_issue_comp_batch run twice for the same guest (a retry, or two staff) issues ' || c || ' comps: no '
    'request key and no "already comped" check across calls. Proposal: an optional p_request_key (same key '
    '= same result), or an "already-comped" outcome when the email already holds a live comp for the event.');
  RAISE NOTICE 'OK SIM-DOOR-19 box-office mint retried with the same ref: one comp (fixed)';
END $$;

-- ---------------------------------------------------------------------------
-- SIM-DOOR-20. A walk-up sale and a cash drawer that doesn't match. FIXED for
-- gift cards; a miscounted close is KNOWN.
-- ---------------------------------------------------------------------------
INSERT INTO public.exos_pos_items(id,org_id,event_id,category,name,price_cents) VALUES
  ('d7d00000-0000-0000-0000-000000000ff1','d7d00000-0000-0000-0000-000000000001','d7d00000-0000-0000-0000-0000000000e1','bar','Soda',500);
DO $$
DECLARE r jsonb; g jsonb; v_drawer uuid := 'd7d00000-0000-0000-0000-000000000dd1'; v_order uuid := 'd7d00000-0000-0000-0000-000000000dd2';
BEGIN
  PERFORM pg_temp.act('d7d00000-0000-0000-0000-0000000000a2');
  INSERT INTO public.exos_pos_drawer_sessions(id, event_id, open_float_cents) VALUES (v_drawer, pg_temp.u('e1'), 10000);
  INSERT INTO public.exos_pos_orders(id, event_id) VALUES (v_order, pg_temp.u('e1'));
  INSERT INTO public.exos_pos_order_lines(order_id,item_id,category,name,quantity,unit_price_cents)
  VALUES (v_order, 'd7d00000-0000-0000-0000-000000000ff1', 'bar', 'x', 2, 1);
  INSERT INTO public.exos_pos_payments(order_id, method, amount_cents, drawer_session_id)
  VALUES (v_order, 'cash', (SELECT total_cents FROM public.exos_pos_orders WHERE id = v_order), v_drawer);
  -- A $50 gift card sold for cash at the same window.
  g := public.exos_gift_card_issue(pg_temp.u('01')::uuid, 5000, 'cash', NULL, 'usd', NULL, NULL, NULL, NULL,
         'till-sd-1', 'box_office', v_drawer);
  ASSERT g ->> 'pos_drawer_id' = v_drawer::text, 'SIM-DOOR-20: card tied to the drawer, got ' || g::text;
  -- A $50 card on the card terminal is not drawer cash.
  PERFORM public.exos_gift_card_issue(pg_temp.u('01')::uuid, 5000, 'card', NULL, 'usd', NULL, NULL, NULL, NULL,
         'till-sd-2', 'box_office', v_drawer);
  -- The till really holds float + sodas + the cash card.
  r := public.exos_pos_close_drawer(v_drawer, 10000 + (SELECT total_cents FROM public.exos_pos_orders WHERE id = v_order) + 5000);
  ASSERT (r ->> 'variance_cents')::int = 0 AND (r ->> 'cash_taken_cents')::int
           = (SELECT total_cents FROM public.exos_pos_orders WHERE id = v_order) + 5000,
         'SIM-DOOR-20: cash gift card counted in the drawer, got ' || r::text;
  -- Closing a drawer twice (a second staff member, a double tap) is refused.
  ASSERT pg_temp.raises(format('SELECT public.exos_pos_close_drawer(%L, 0)', v_drawer), '22023'), 'SIM-DOOR-20: closed once';
  -- A drawer closed with a miscount ($10 short) is recorded as counted.
  INSERT INTO public.exos_pos_drawer_sessions(id, event_id, open_float_cents)
  VALUES ('d7d00000-0000-0000-0000-000000000dd3', pg_temp.u('e1'), 10000);
  r := public.exos_pos_close_drawer('d7d00000-0000-0000-0000-000000000dd3', 9000, '{"2000": 4, "1000": 1}'::jsonb, 'short');
  ASSERT (r ->> 'variance_cents')::int = -1000, 'SIM-DOOR-20: the shortfall is recorded, got ' || r::text;
  ASSERT pg_temp.raises($q$SELECT public.exos_pos_close_drawer('d7d00000-0000-0000-0000-000000000dd3', 9000, '{"2000": 4}'::jsonb)$q$, '22023'),
         'SIM-DOOR-20: denomination counts must add up';
  PERFORM pg_temp.known('20', false,
    'a closed drawer can''t be recounted or corrected: a miscount (the $10 was under the tray) stays the '
    'night''s variance. Proposal: exos_pos_recount_drawer(session, counted, reason) for owner / manager, '
    'keeping the first count in an audit row.');
  RAISE NOTICE 'OK SIM-DOOR-20 drawer: cash gift cards counted (fixed), shortfall recorded, double close refused';
END $$;

-- ---------------------------------------------------------------------------
-- SIM-DOOR-21. A typed ticket id (no code) and a camera read of a bare id.
-- ---------------------------------------------------------------------------
DO $$
DECLARE r jsonb;
BEGIN
  PERFORM pg_temp.act('d7d00000-0000-0000-0000-0000000000a3');
  -- A camera read of a bare id (a screenshot of the ticket number) is refused.
  r := public.exos_check_in_ticket(pg_temp.tk(27), 'camera', 'verified', pg_temp.tk(27)::text, pg_temp.u('e1'),
         NULL, NULL, 'Door A', NULL, 'entry');
  ASSERT r ->> 'reason' = 'barcode-rejected', 'SIM-DOOR-21: bare id on camera, got ' || r::text;
  -- Typed by a scanner: needs a manager.
  r := public.exos_check_in_ticket(pg_temp.tk(27), 'manual', 'manual', NULL, pg_temp.u('e1'), 'lost phone', NULL, 'Door A', NULL, 'entry');
  ASSERT r ->> 'reason' = 'needs-manager', 'SIM-DOOR-21: scanner override, got ' || r::text;
  -- A code with the owner segment edited (someone else's id): refused.
  r := pg_temp.scan(27, 'Door A', NULL, 'entry', NULL, pg_temp.tc(27, now(), pg_temp.u('a7')));
  ASSERT r ->> 'reason' = 'barcode-rejected', 'SIM-DOOR-21: edited owner, got ' || r::text;
  -- A reader that lower-cases the payload ("t-..."): the server takes the
  -- prefix in any case (the scanner page's own parse doesn't: lib/sim/door.test.ts).
  r := pg_temp.scan(27, 'Door A', NULL, 'entry', NULL, 't-' || substring(pg_temp.tc(27) FROM 3));
  ASSERT r ->> 'reason' = 'checked-in', 'SIM-DOOR-21: lower-case prefix, got ' || r::text;
  RAISE NOTICE 'OK SIM-DOOR-21 typed / bare / edited codes refused; a lower-cased prefix still verifies';
END $$;

ROLLBACK;
