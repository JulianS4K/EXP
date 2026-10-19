-- ============================================================================
-- Per-day door keys (mig 20261019100000):
--   K1 the SQL functions match the TypeScript vectors (src/lib/doorKeys.test.ts)
--   K2 the door roster carries three days of keys, never the secret; the
--      since form returns only changed tickets
--   K3 the old roster RPCs no longer carry the secret
--   K4 the secret gate: holder yes, door staff no
--   K5 exos_door_ticket_keys: door staff of the event only
--   K6 check-in: a day-key code passes, a secret-signed one still does, a
--      forged one and another ticket's don't
--   K7 an offline scan an hour old is checked with that hour's day key
--   K8 a live wallet pass adds its Apple hash + Google key, for its epoch
--   K9 grants
--   K10 a wallet pass change is in the since form
-- Self-contained (BEGIN / ROLLBACK). Org dk…01 owned by …a1; scanner …a3
-- (unscoped), scanner …a4 (assigned to e2 only), holder …a5, finance …a8.
-- ============================================================================
\set ON_ERROR_STOP on
BEGIN;

CREATE TABLE IF NOT EXISTS public.exos_profiles (
  id uuid PRIMARY KEY, display_name text, updated_at timestamptz NOT NULL DEFAULT now());

INSERT INTO auth.users(id,email,email_confirmed_at) VALUES
  ('d7000000-0000-0000-0000-0000000000a1','dkown@x.com',now()),
  ('d7000000-0000-0000-0000-0000000000a3','dkscan@x.com',now()),
  ('d7000000-0000-0000-0000-0000000000a4','dkscan2@x.com',now()),
  ('aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee','dkhold@x.com',now()),
  ('d7000000-0000-0000-0000-0000000000a8','dkfin@x.com',now());
INSERT INTO public.exos_orgs(id,name,slug,owner_uid) VALUES
  ('d7000000-0000-0000-0000-000000000001','Keys Org','keys-org-stub','d7000000-0000-0000-0000-0000000000a1');
INSERT INTO public.exos_org_memberships(org_id,user_id,role) VALUES
  ('d7000000-0000-0000-0000-000000000001','d7000000-0000-0000-0000-0000000000a1','owner'),
  ('d7000000-0000-0000-0000-000000000001','d7000000-0000-0000-0000-0000000000a3','scanner'),
  ('d7000000-0000-0000-0000-000000000001','d7000000-0000-0000-0000-0000000000a4','scanner'),
  ('d7000000-0000-0000-0000-000000000001','d7000000-0000-0000-0000-0000000000a8','finance');
INSERT INTO public.exos_events(id,org_id,name,slug,status,starts_at,doors_at,ends_at,total_tickets,created_by) VALUES
  ('d7000000-0000-0000-0000-0000000000e1','d7000000-0000-0000-0000-000000000001','Keys Night','keys-night-stub','published',
   now() + interval '1 hour', now() - interval '2 hours', now() + interval '6 hours', 0, 'd7000000-0000-0000-0000-0000000000a1'),
  ('d7000000-0000-0000-0000-0000000000e2','d7000000-0000-0000-0000-000000000001','Keys Two','keys-two-stub','published',
   now() + interval '1 hour', now() - interval '2 hours', NULL, 0, 'd7000000-0000-0000-0000-0000000000a1');
INSERT INTO public.exos_ticket_tiers(id,event_id,name,price,capacity) VALUES
  ('d7000000-0000-0000-0000-0000000000f1','d7000000-0000-0000-0000-0000000000e1','GA',50,100);
INSERT INTO public.exos_event_staff(event_id, user_id, org_id) VALUES
  ('d7000000-0000-0000-0000-0000000000e2','d7000000-0000-0000-0000-0000000000a4','d7000000-0000-0000-0000-000000000001');
-- t1 is the vector ticket; t2-t4 are ordinary.
INSERT INTO public.exos_tickets(id,event_id,org_id,tier_id,tier_name,buyer_id,owner_id,buyer_email,status,barcode_secret,price_paid,order_ref,channel_source)
VALUES
  ('11111111-2222-3333-4444-555555555555','d7000000-0000-0000-0000-0000000000e1','d7000000-0000-0000-0000-000000000001',
   'd7000000-0000-0000-0000-0000000000f1','GA','aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee','aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee',
   'dkhold@x.com','active','per-ticket-secret-minted-at-fulfillment',50,'web-k1','stripe');
INSERT INTO public.exos_tickets(id,event_id,org_id,tier_id,tier_name,buyer_id,owner_id,buyer_email,status,barcode_secret,price_paid,order_ref,channel_source)
SELECT ('d7000000-0000-0000-0000-0000000' || k)::uuid, 'd7000000-0000-0000-0000-0000000000e1', 'd7000000-0000-0000-0000-000000000001',
       'd7000000-0000-0000-0000-0000000000f1', 'GA', 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee', 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee',
       'dkhold@x.com', 'active', 'sek-' || k, 50, 'web-' || k, 'stripe'
  FROM unnest(ARRAY['c0002','c0003','c0004']) k;

CREATE FUNCTION pg_temp.act(p_uid text) RETURNS void LANGUAGE sql AS $$
  SELECT set_config('app.uid', coalesce(p_uid, ''), false), set_config('app.jwt', '{"email":"door@x.com"}', false);
$$;
CREATE FUNCTION pg_temp.tk(p_suffix text) RETURNS uuid LANGUAGE sql IMMUTABLE AS $$
  SELECT ('d7000000-0000-0000-0000-0000000' || p_suffix)::uuid;
$$;
CREATE FUNCTION pg_temp.bucket(p_at timestamptz) RETURNS bigint LANGUAGE sql STABLE AS $$
  SELECT floor(extract(epoch FROM p_at) * 1000 / 30000)::bigint;
$$;
-- What the holder's app shows now (day key) and what an old app showed (secret).
CREATE FUNCTION pg_temp.code(p_ticket uuid, p_at timestamptz) RETURNS text LANGUAGE sql STABLE AS $$
  SELECT 'T-' || t.id || ':' || t.owner_id || ':' || pg_temp.bucket(p_at) || ':' ||
         public._exos_door_code_mac(t.id, t.owner_id, pg_temp.bucket(p_at), t.barcode_secret)
    FROM public.exos_tickets t WHERE t.id = p_ticket;
$$;
CREATE FUNCTION pg_temp.legacy_code(p_ticket uuid, p_at timestamptz) RETURNS text LANGUAGE sql STABLE AS $$
  SELECT 'T-' || t.id || ':' || t.owner_id || ':' || pg_temp.bucket(p_at) || ':' ||
         public._exos_b64url(extensions.hmac(t.id || ':' || t.owner_id || ':' || pg_temp.bucket(p_at), t.barcode_secret, 'sha256'))
    FROM public.exos_tickets t WHERE t.id = p_ticket;
$$;
CREATE FUNCTION pg_temp.scan(p_ticket uuid, p_code text, p_at timestamptz DEFAULT NULL) RETURNS jsonb LANGUAGE sql AS $$
  SELECT public.exos_check_in_ticket(p_ticket, 'camera', 'verified', p_code,
           'd7000000-0000-0000-0000-0000000000e1', NULL, p_at, 'Door K', NULL, 'entry');
$$;

-- K1. Vectors.
DO $$
DECLARE
  t uuid := '11111111-2222-3333-4444-555555555555';
  o uuid := 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee';
  s text := 'per-ticket-secret-minted-at-fulfillment';
BEGIN
  ASSERT public._exos_door_day_key(t, s, 20745) = 'Q8rqdCNy6LtJFyJy7sLh1LD4hNYqu4qNzn7k6s0ajXs', 'K1 day key';
  ASSERT public._exos_door_code_mac(t, o, 59745600, s) = 'fE-2zQxd3t7ygpBwIdDVCq0zlc6V5JL9rK1Aspdmolk', 'K1 code mac';
  ASSERT floor(59745600 / 2880.0)::int = 20745 AND floor(59745599 / 2880.0)::int = 20744, 'K1 day boundary';
  ASSERT encode(extensions.digest(public._exos_wallet_apple_code(t, o, s, 3), 'sha256'), 'hex')
         = '3f2e7820181bdb370b180ef5115c271091e6acb3e827f2f50f918ab9a3bca55b', 'K1 apple hash';
  ASSERT encode(public._exos_wallet_google_key(t, o, s, 3), 'hex') = '8a59a0c916387a0565275cefa7d2c5a56466510b', 'K1 google key';
  RAISE NOTICE 'K1 ok: SQL matches the TypeScript vectors';
END $$;

-- K2. The door roster.
DO $$
DECLARE
  v_today int := floor(extract(epoch FROM now()) / 86400)::int;
  r record;
  n int := 0;
BEGIN
  PERFORM pg_temp.act('d7000000-0000-0000-0000-0000000000a3');
  FOR r IN SELECT * FROM public.exos_event_door_roster('d7000000-0000-0000-0000-0000000000e1') LOOP
    n := n + 1;
    ASSERT (SELECT array_agg(k ORDER BY k) FROM jsonb_object_keys(r.door_keys -> 'd') k)
           = ARRAY[(v_today - 1)::text, v_today::text, (v_today + 1)::text], 'K2 three days';
    ASSERT r.door_keys -> 'd' ->> v_today::text
           = public._exos_door_day_key(r.ticket_id, (SELECT barcode_secret FROM public.exos_tickets WHERE id = r.ticket_id), v_today),
           'K2 today''s key';
    ASSERT position((SELECT barcode_secret FROM public.exos_tickets WHERE id = r.ticket_id) IN r.door_keys::text) = 0, 'K2 no secret';
    ASSERT NOT (r.door_keys ? 'wa'), 'K2 no wallet keys without a pass';
  END LOOP;
  ASSERT n = 4, format('K2 four tickets, got %s', n);
  ASSERT (SELECT count(*) FROM public.exos_event_door_roster('d7000000-0000-0000-0000-0000000000e1', now() + interval '1 minute')) = 0,
         'K2 since: nothing changed';
  BEGIN
    PERFORM * FROM public.exos_event_door_roster('d7000000-0000-0000-0000-0000000000e1', now() - interval '8 days');
    RAISE EXCEPTION 'K2 since 8 days back accepted';
  EXCEPTION WHEN invalid_parameter_value THEN NULL;
  END;
  -- Gate: scoped scanner elsewhere, finance, anon.
  PERFORM pg_temp.act('d7000000-0000-0000-0000-0000000000a4');
  BEGIN
    PERFORM * FROM public.exos_event_door_roster('d7000000-0000-0000-0000-0000000000e1');
    RAISE EXCEPTION 'K2 scoped scanner got the roster';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  PERFORM pg_temp.act('d7000000-0000-0000-0000-0000000000a8');
  BEGIN
    PERFORM * FROM public.exos_event_door_roster('d7000000-0000-0000-0000-0000000000e1');
    RAISE EXCEPTION 'K2 finance got the roster';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  PERFORM pg_temp.act(NULL);
  BEGIN
    PERFORM * FROM public.exos_event_door_roster('d7000000-0000-0000-0000-0000000000e1');
    RAISE EXCEPTION 'K2 anon got the roster';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  RAISE NOTICE 'K2 ok: roster carries keys for three days, never the secret; gated';
END $$;

-- K3. The old roster RPCs.
DO $$
BEGIN
  PERFORM pg_temp.act('d7000000-0000-0000-0000-0000000000a3');
  ASSERT (SELECT count(*) FROM public.exos_event_checkin_roster('d7000000-0000-0000-0000-0000000000e1')) = 4, 'K3 rows';
  ASSERT (SELECT count(*) FROM public.exos_event_checkin_roster('d7000000-0000-0000-0000-0000000000e1')
           WHERE barcode_secret IS NOT NULL) = 0, 'K3 roster secret';
  ASSERT (SELECT count(*) FROM public.exos_event_checkin_roster_since('d7000000-0000-0000-0000-0000000000e1', now() - interval '1 hour')
           WHERE barcode_secret IS NOT NULL) = 0, 'K3 since secret';
  RAISE NOTICE 'K3 ok: old roster RPCs return no secrets';
END $$;

-- K4. The secret gate (exos_can_read_ticket_secret, behind the
-- exos_ticket_barcode_secrets view).
DO $$
BEGIN
  PERFORM pg_temp.act('d7000000-0000-0000-0000-0000000000a3');
  ASSERT NOT public.exos_can_read_ticket_secret(pg_temp.tk('c0002')), 'K4 scanner';
  PERFORM pg_temp.act('d7000000-0000-0000-0000-0000000000a1');
  ASSERT NOT public.exos_can_read_ticket_secret(pg_temp.tk('c0002')), 'K4 org owner';
  PERFORM pg_temp.act('aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee');
  ASSERT public.exos_can_read_ticket_secret(pg_temp.tk('c0002')), 'K4 holder';
  ASSERT NOT has_function_privilege('anon', 'public.exos_can_read_ticket_secret(uuid)', 'EXECUTE'), 'K4 anon';
  RAISE NOTICE 'K4 ok: only the holder (and buyer, admin) reads the secret';
END $$;

-- K5. One ticket's keys.
DO $$
DECLARE k jsonb;
BEGIN
  PERFORM pg_temp.act('d7000000-0000-0000-0000-0000000000a3');
  k := public.exos_door_ticket_keys(pg_temp.tk('c0002'));
  ASSERT k -> 'd' ->> floor(extract(epoch FROM now()) / 86400)::int::text
         = public._exos_door_day_key(pg_temp.tk('c0002'), 'sek-c0002', floor(extract(epoch FROM now()) / 86400)::int), 'K5 key';
  ASSERT public.exos_door_ticket_keys('d7000000-0000-0000-0000-00000000ffff') IS NULL, 'K5 unknown ticket';
  FOREACH k IN ARRAY ARRAY['"d7000000-0000-0000-0000-0000000000a4"', '"d7000000-0000-0000-0000-0000000000a8"']::jsonb[] LOOP
    PERFORM pg_temp.act(k #>> '{}');
    BEGIN
      PERFORM public.exos_door_ticket_keys(pg_temp.tk('c0002'));
      RAISE EXCEPTION 'K5 % got keys', k;
    EXCEPTION WHEN insufficient_privilege THEN NULL;
    END;
  END LOOP;
  RAISE NOTICE 'K5 ok: door staff of the event only';
END $$;

-- K6. Check-in.
DO $$
DECLARE r jsonb;
BEGIN
  PERFORM pg_temp.act('d7000000-0000-0000-0000-0000000000a3');
  r := pg_temp.scan(pg_temp.tk('c0002'), pg_temp.code(pg_temp.tk('c0002'), now()));
  ASSERT r ->> 'reason' = 'checked-in' AND (r ->> 'verified')::boolean, format('K6 day-key code: %s', r);
  r := pg_temp.scan(pg_temp.tk('c0003'), pg_temp.legacy_code(pg_temp.tk('c0003'), now()));
  ASSERT r ->> 'reason' = 'checked-in', format('K6 secret-signed code: %s', r);
  -- c0004 with c0002's MAC, and with a made-up one.
  r := pg_temp.scan(pg_temp.tk('c0004'),
         replace(pg_temp.code(pg_temp.tk('c0002'), now()), pg_temp.tk('c0002')::text, pg_temp.tk('c0004')::text));
  ASSERT r ->> 'reason' = 'barcode-rejected', format('K6 other ticket''s mac: %s', r);
  r := pg_temp.scan(pg_temp.tk('c0004'), 'T-' || pg_temp.tk('c0004') || ':aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee:'
         || pg_temp.bucket(now()) || ':AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA');
  ASSERT r ->> 'reason' = 'barcode-rejected', format('K6 forged: %s', r);
  ASSERT (SELECT status FROM public.exos_tickets WHERE id = pg_temp.tk('c0004')) = 'active', 'K6 c0004 untouched';
  RAISE NOTICE 'K6 ok: day-key and secret-signed codes pass, forged ones do not';
END $$;

-- K7. Offline, an hour ago.
DO $$
DECLARE r jsonb;
BEGIN
  PERFORM pg_temp.act('d7000000-0000-0000-0000-0000000000a3');
  r := pg_temp.scan(pg_temp.tk('c0004'), pg_temp.code(pg_temp.tk('c0004'), now() - interval '1 hour'), now() - interval '1 hour');
  ASSERT r ->> 'reason' = 'checked-in', format('K7 offline: %s', r);
  RAISE NOTICE 'K7 ok: offline scan checked with its own hour''s key';
END $$;

-- K8. A live wallet pass.
DO $$
DECLARE
  t uuid := '11111111-2222-3333-4444-555555555555';
  o uuid := 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee';
  k jsonb;
BEGIN
  INSERT INTO public.exos_wallet_passes(serial_number, ticket_id, owner_id, code_epoch)
  VALUES ('exw' || repeat('d7', 16), t, o, 3);
  PERFORM pg_temp.act('d7000000-0000-0000-0000-0000000000a3');
  k := public.exos_door_ticket_keys(t);
  ASSERT (k ->> 'we')::int = 3, 'K8 epoch';
  ASSERT k ->> 'wa' = '3f2e7820181bdb370b180ef5115c271091e6acb3e827f2f50f918ab9a3bca55b', 'K8 apple hash';
  ASSERT k ->> 'wg' = '8a59a0c916387a0565275cefa7d2c5a56466510b', 'K8 google key';
  UPDATE public.exos_wallet_passes SET owner_id = 'd7000000-0000-0000-0000-0000000000a1' WHERE ticket_id = t;
  ASSERT NOT (public.exos_door_ticket_keys(t) ? 'wa'), 'K8 a pass for another holder adds nothing';
  RAISE NOTICE 'K8 ok: wallet keys for the live pass';
END $$;

-- K9. Grants.
DO $$
BEGIN
  ASSERT NOT has_function_privilege('authenticated', 'public._exos_door_day_key(uuid, text, int)', 'EXECUTE'), 'K9 day key';
  ASSERT NOT has_function_privilege('authenticated', 'public._exos_door_code_mac(uuid, uuid, bigint, text)', 'EXECUTE'), 'K9 mac';
  ASSERT NOT has_function_privilege('authenticated', 'public._exos_door_keys(uuid, uuid, text)', 'EXECUTE'), 'K9 keys';
  ASSERT NOT has_function_privilege('anon', 'public.exos_event_door_roster(uuid, timestamptz)', 'EXECUTE'), 'K9 anon roster';
  ASSERT has_function_privilege('authenticated', 'public.exos_event_door_roster(uuid, timestamptz)', 'EXECUTE'), 'K9 roster';
  ASSERT has_function_privilege('authenticated', 'public.exos_door_ticket_keys(uuid)', 'EXECUTE'), 'K9 ticket keys';
  RAISE NOTICE 'K9 ok: grants';
END $$;

-- K10. A wallet pass issued since the last pull is in the delta (mig 20261019120000).
DO $$
BEGIN
  PERFORM pg_temp.act('d7000000-0000-0000-0000-0000000000a3');
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_event_door_roster('d7000000-0000-0000-0000-0000000000e1', now() + interval '1 minute')),
         'K10 nothing changed after now';
  UPDATE public.exos_wallet_passes SET updated_at = now() + interval '2 minutes'
   WHERE ticket_id = '11111111-2222-3333-4444-555555555555';
  ASSERT (SELECT array_agg(ticket_id) FROM public.exos_event_door_roster('d7000000-0000-0000-0000-0000000000e1', now() + interval '1 minute'))
         = ARRAY['11111111-2222-3333-4444-555555555555'::uuid], 'K10 the pass change brings its ticket';
  RAISE NOTICE 'K10 ok: wallet pass changes are in the delta';
END $$;

SELECT '*** door day keys: ALL ASSERTIONS PASSED ***' AS result;
ROLLBACK;
