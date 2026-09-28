-- ============================================================================
-- Wallet passes (mig 20260929072000):
--   W1 only the ticket owner creates a pass link (RPC + no client writes)
--   W2 clients see only their own pass rows, never the token hash
--   W3 PassKit web service: token-checked register / fetch, service role only
--   W4 the door accepts the Apple W- code and the Google TOTP code
--   W5 reissue: the old code stops working, the new one admits
--   W6 transfer voids the pass (new holder gets a new serial); the old
--      holder's device still fetches it, voided
--   W7 a refund void invalidates the pass and marks it for a push
--   W8 check-in marks a refresh; updated serials + push queue / done
--   W9 the T- rotating code still works; helper grants are private
-- Self-contained (BEGIN / ROLLBACK). Prefix 8b…: org …01, owner …a1, scanner
-- …a3, holder …a5, other user …a6. Event …e1 (doors open). Tickets …c1–c6.
-- ============================================================================
\set ON_ERROR_STOP on
BEGIN;

INSERT INTO auth.users(id,email,email_confirmed_at) VALUES
  ('8b000000-0000-0000-0000-0000000000a1','8bown@x.com',now()),
  ('8b000000-0000-0000-0000-0000000000a3','8bscan@x.com',now()),
  ('8b000000-0000-0000-0000-0000000000a5','8bhold@x.com',now()),
  ('8b000000-0000-0000-0000-0000000000a6','8bother@x.com',now());
INSERT INTO public.exos_orgs(id,name,slug,owner_uid) VALUES
  ('8b000000-0000-0000-0000-000000000001','Wallet Org','wallet-org-8b','8b000000-0000-0000-0000-0000000000a1');
INSERT INTO public.exos_org_memberships(org_id,user_id,role) VALUES
  ('8b000000-0000-0000-0000-000000000001','8b000000-0000-0000-0000-0000000000a1','owner'),
  ('8b000000-0000-0000-0000-000000000001','8b000000-0000-0000-0000-0000000000a3','scanner');
INSERT INTO public.exos_events(id,org_id,name,slug,status,starts_at,doors_at,timezone,venue_name,total_tickets,created_by) VALUES
  ('8b000000-0000-0000-0000-0000000000e1','8b000000-0000-0000-0000-000000000001','Wallet Night','wallet-night-8b','published',
   now() + interval '1 hour', now() - interval '1 hour', 'America/New_York', 'Pier 17', 0,
   '8b000000-0000-0000-0000-0000000000a1');
INSERT INTO public.exos_tickets(id,event_id,org_id,buyer_id,owner_id,status,barcode_secret,price_paid,order_ref,tier_name)
SELECT ('8b000000-0000-0000-0000-00000000c00' || n)::uuid, '8b000000-0000-0000-0000-0000000000e1',
       '8b000000-0000-0000-0000-000000000001','8b000000-0000-0000-0000-0000000000a5','8b000000-0000-0000-0000-0000000000a5',
       'active','wsek-' || n, 20, 'wallet-seed-' || n, 'GA'
  FROM generate_series(1, 6) n;

CREATE FUNCTION pg_temp.act(p_uid text) RETURNS void LANGUAGE sql AS $$
  SELECT set_config('app.uid', p_uid, false), set_config('app.jwt', '{"email":"w@x.com"}', false);
$$;
CREATE FUNCTION pg_temp.h(p_token text) RETURNS text LANGUAGE sql SECURITY DEFINER AS $$
  SELECT encode(extensions.digest(p_token, 'sha256'), 'hex');
$$;
-- The app's rotating T- code at time p_at.
CREATE FUNCTION pg_temp.t_code(p_ticket uuid, p_at timestamptz) RETURNS text LANGUAGE sql AS $$
  SELECT 'T-' || t.id || ':' || t.owner_id || ':' || b || ':' ||
         rtrim(translate(encode(extensions.hmac(t.id || ':' || t.owner_id || ':' || b, t.barcode_secret, 'sha256'),
                                'base64'), '+/', '-_'), '=')
    FROM public.exos_tickets t,
         LATERAL (SELECT floor(extract(epoch FROM p_at) * 1000 / 30000)::bigint::text AS b) x
   WHERE t.id = p_ticket;
$$;
-- What Google Wallet renders for a pass at time p_at.
CREATE FUNCTION pg_temp.g_code(p_serial text, p_at timestamptz) RETURNS text LANGUAGE sql AS $$
  SELECT replace(p ->> 'google_pattern', '{totp_value_0}',
                 public._exos_wallet_totp(decode(p ->> 'google_key_hex', 'hex'), floor(extract(epoch FROM p_at) / 30)::bigint))
    FROM (SELECT public.exos_wallet_pass_payload(p_serial) AS p) x;
$$;
CREATE TEMP TABLE w8b (k text PRIMARY KEY, v text);
GRANT ALL ON w8b TO authenticated;

-- W0. The derivation matches the TypeScript (src/lib/wallet/fixtures.ts) and RFC 6238.
DO $$
BEGIN
  ASSERT public._exos_wallet_totp(convert_to('12345678901234567890', 'UTF8'), 1) = '94287082', 'W0: RFC 6238 T=59';
  ASSERT public._exos_wallet_totp(convert_to('12345678901234567890', 'UTF8'), 37037036) = '07081804', 'W0: RFC 6238 T=1111111109';
  ASSERT public._exos_wallet_apple_code('11111111-1111-1111-1111-111111111111', '22222222-2222-2222-2222-222222222222', 'sek', 1)
         = 'W-11111111-1111-1111-1111-111111111111:22222222-2222-2222-2222-222222222222:a1:S0zzswPk5LKCbx2nEfnHYRIBNx2fzxSHq0YbSt6jrmM',
         'W0: apple code parity with codes.ts';
  ASSERT encode(public._exos_wallet_google_key('11111111-1111-1111-1111-111111111111', '22222222-2222-2222-2222-222222222222', 'sek', 1), 'hex')
         = '133015cacf7d7a699286a00f41c09045724e85df', 'W0: google key parity with codes.ts';
  RAISE NOTICE 'PASS W0 code derivation matches TypeScript + RFC 6238';
END $$;

-- W1. Only the ticket owner creates a pass link.
SET ROLE authenticated;
DO $$
DECLARE c1 uuid := '8b000000-0000-0000-0000-00000000c001'; r jsonb; raised boolean;
BEGIN
  -- Someone else, for the holder's ticket: refused (and indistinguishable from "no such ticket").
  PERFORM pg_temp.act('8b000000-0000-0000-0000-0000000000a6');
  raised := false;
  BEGIN PERFORM public.exos_wallet_issue_pass(c1, 'apple', pg_temp.h('tok-other-000000000001'), 'pass.com.exos.test');
  EXCEPTION WHEN insufficient_privilege THEN raised := SQLERRM LIKE '%not the ticket owner%'; END;
  ASSERT raised, 'W1: another user cannot create a pass for someone else''s ticket';
  -- The org owner is not the ticket owner either.
  PERFORM pg_temp.act('8b000000-0000-0000-0000-0000000000a1');
  raised := false;
  BEGIN PERFORM public.exos_wallet_issue_pass(c1, 'google');
  EXCEPTION WHEN insufficient_privilege THEN raised := SQLERRM LIKE '%not the ticket owner%'; END;
  ASSERT raised, 'W1: org staff cannot create a holder''s pass';
  -- No direct writes at all.
  raised := false;
  BEGIN
    INSERT INTO public.exos_wallet_passes (serial_number, ticket_id, owner_id)
    VALUES ('exw' || repeat('0', 32), c1, '8b000000-0000-0000-0000-0000000000a6');
  EXCEPTION WHEN insufficient_privilege THEN raised := SQLERRM LIKE 'permission denied for table%'; END;
  ASSERT raised, 'W1: no client INSERT on exos_wallet_passes';

  -- The holder: an Apple pass, then a Google link on the same serial.
  PERFORM pg_temp.act('8b000000-0000-0000-0000-0000000000a5');
  raised := false;
  BEGIN PERFORM public.exos_wallet_issue_pass(c1, 'apple', 'not-a-hash', 'pass.com.exos.test');
  EXCEPTION WHEN invalid_parameter_value THEN raised := true; END;
  ASSERT raised, 'W1: apple needs a real token hash';
  r := public.exos_wallet_issue_pass(c1, 'apple', pg_temp.h('tok-hold-0000000000000001'), 'pass.com.exos.test');
  ASSERT (r ->> 'ok')::boolean AND (r ->> 'created')::boolean AND (r ->> 'code_epoch')::int = 1, 'W1: holder issues, got ' || r;
  INSERT INTO w8b VALUES ('serial1', r ->> 'serial');
  r := public.exos_wallet_issue_pass(c1, 'google');
  ASSERT (r ->> 'ok')::boolean AND NOT (r ->> 'created')::boolean AND r ->> 'serial' = (SELECT v FROM w8b WHERE k = 'serial1'),
         'W1: one live pass per ticket, got ' || r;
  RAISE NOTICE 'PASS W1 only the ticket owner creates a pass link';
END $$;

-- W2. Reads: own rows only, no token hash, no registrations.
DO $$
DECLARE n int; raised boolean;
BEGIN
  PERFORM pg_temp.act('8b000000-0000-0000-0000-0000000000a6');
  SELECT count(*) INTO n FROM public.exos_wallet_passes;
  ASSERT n = 0, 'W2: another user sees no passes';
  PERFORM pg_temp.act('8b000000-0000-0000-0000-0000000000a5');
  SELECT count(*) INTO n FROM public.exos_wallet_passes;
  ASSERT n = 1, 'W2: the holder sees their pass';
  raised := false;
  BEGIN PERFORM auth_token_hash FROM public.exos_wallet_passes;
  EXCEPTION WHEN insufficient_privilege THEN raised := SQLERRM LIKE 'permission denied for table%'; END;
  ASSERT raised, 'W2: token hash is not readable';
  raised := false;
  BEGIN PERFORM 1 FROM public.exos_wallet_registrations;
  EXCEPTION WHEN insufficient_privilege THEN raised := SQLERRM LIKE 'permission denied for table%'; END;
  ASSERT raised, 'W2: registrations are not readable';
  RAISE NOTICE 'PASS W2 clients read only their own pass rows';
END $$;

-- W3. PassKit web service: clients can't call it; the token gates everything.
DO $$
DECLARE s text := (SELECT v FROM w8b WHERE k = 'serial1'); raised boolean;
BEGIN
  PERFORM pg_temp.act('8b000000-0000-0000-0000-0000000000a6');
  raised := false;
  BEGIN
    INSERT INTO public.exos_wallet_registrations (device_library_id, pass_type_identifier, serial_number, push_token)
    VALUES ('dev-other', 'pass.com.exos.test', s, 'ab');
  EXCEPTION WHEN insufficient_privilege THEN raised := SQLERRM LIKE 'permission denied for table%'; END;
  ASSERT raised, 'W3: another user cannot register a device on someone else''s pass';
  raised := false;
  BEGIN PERFORM public.exos_wallet_register_device('dev-other', 'pass.com.exos.test', s, 'tok-hold-0000000000000001', 'ab');
  EXCEPTION WHEN insufficient_privilege THEN raised := SQLERRM LIKE 'permission denied for function%'; END;
  ASSERT raised, 'W3: the register RPC is service-role only';
  raised := false;
  BEGIN PERFORM public.exos_wallet_fetch_pass('pass.com.exos.test', s, 'tok-hold-0000000000000001');
  EXCEPTION WHEN insufficient_privilege THEN raised := SQLERRM LIKE 'permission denied for function%'; END;
  ASSERT raised, 'W3: the fetch RPC is service-role only';
  raised := false;
  BEGIN PERFORM public.exos_wallet_pass_payload(s);
  EXCEPTION WHEN insufficient_privilege THEN raised := SQLERRM LIKE 'permission denied for function%'; END;
  ASSERT raised, 'W3: the payload RPC is service-role only';
END $$;
RESET ROLE;

DO $$
DECLARE s text := (SELECT v FROM w8b WHERE k = 'serial1'); p jsonb;
BEGIN
  -- As the service role (the edge function): the ApplePass token decides.
  ASSERT public.exos_wallet_register_device('dev-1', 'pass.com.exos.test', s, 'tok-wrong-000000000000001', 'aa11') = 'unauthorized',
         'W3: wrong token cannot register';
  ASSERT public.exos_wallet_register_device('dev-1', 'pass.other', s, 'tok-hold-0000000000000001', 'aa11') = 'unauthorized',
         'W3: wrong pass type cannot register';
  ASSERT public.exos_wallet_register_device('dev-1', 'pass.com.exos.test', s, 'tok-hold-0000000000000001', 'aa11') = 'created',
         'W3: right token registers';
  ASSERT public.exos_wallet_register_device('dev-1', 'pass.com.exos.test', s, 'tok-hold-0000000000000001', 'aa22') = 'exists',
         'W3: re-register is idempotent';
  ASSERT (SELECT push_token FROM public.exos_wallet_registrations WHERE device_library_id = 'dev-1') = 'aa22',
         'W3: push token refreshed';
  ASSERT public.exos_wallet_unregister_device('dev-1', 'pass.com.exos.test', s, 'tok-wrong-000000000000001') = 'unauthorized',
         'W3: wrong token cannot unregister';
  ASSERT public.exos_wallet_fetch_pass('pass.com.exos.test', s, 'tok-wrong-000000000000001') IS NULL, 'W3: wrong token fetches nothing';
  ASSERT public.exos_wallet_fetch_pass('pass.com.exos.test', s, 'short') IS NULL, 'W3: short token fetches nothing';
  p := public.exos_wallet_fetch_pass('pass.com.exos.test', s, 'tok-hold-0000000000000001');
  ASSERT p ->> 'serial' = s AND p ->> 'apple_code' LIKE 'W-8b000000-0000-0000-0000-00000000c001:8b000000-0000-0000-0000-0000000000a5:a1:%',
         'W3: right token fetches the pass, got ' || p;
  ASSERT p #>> '{event,name}' = 'Wallet Night' AND p #>> '{ticket,tier_name}' = 'GA', 'W3: event + tier in the payload';
  ASSERT position('wsek-' in p::text) = 0 AND NOT (p ? 'barcode_secret'), 'W3: the secret never leaves the database';
  ASSERT position('@' in p::text) = 0, 'W3: no email in the payload';
  RAISE NOTICE 'PASS W3 PassKit web service is token-checked and service-role only';
END $$;

-- W4. The door accepts both wallet codes.
DO $$
DECLARE
  e1 uuid := '8b000000-0000-0000-0000-0000000000e1';
  c1 uuid := '8b000000-0000-0000-0000-00000000c001';
  c2 uuid := '8b000000-0000-0000-0000-00000000c002';
  s1 text := (SELECT v FROM w8b WHERE k = 'serial1');
  s2 text; code text; r jsonb;
BEGIN
  PERFORM pg_temp.act('8b000000-0000-0000-0000-0000000000a5');
  s2 := public.exos_wallet_issue_pass(c2, 'google') ->> 'serial';
  INSERT INTO w8b VALUES ('serial2', s2);

  PERFORM pg_temp.act('8b000000-0000-0000-0000-0000000000a3');
  -- A wallet code for another ticket / a tampered MAC / a wrong epoch are refused.
  code := public.exos_wallet_pass_payload(s1) ->> 'apple_code';
  ASSERT public.exos_check_in_ticket(c2, 'camera', 'verified', code, e1) ->> 'reason' = 'barcode-rejected',
         'W4: a code is bound to its ticket';
  ASSERT public.exos_check_in_ticket(c1, 'camera', 'verified', left(code, -2) || 'AA', e1) ->> 'reason' = 'barcode-rejected',
         'W4: tampered MAC refused';
  ASSERT public.exos_check_in_ticket(c1, 'camera', 'verified', replace(code, ':a1:', ':a2:'), e1) ->> 'reason' = 'barcode-rejected',
         'W4: wrong epoch refused';
  ASSERT public.exos_check_in_ticket(c2, 'camera', 'verified',
           pg_temp.g_code(s2, now() - interval '5 minutes'), e1) ->> 'reason' = 'barcode-rejected',
         'W4: a 5-minute-old TOTP is refused';
  ASSERT (SELECT status FROM public.exos_tickets WHERE id IN (c1, c2) GROUP BY status) = 'active', 'W4: nothing consumed yet';

  r := public.exos_check_in_ticket(c1, 'camera', 'verified', code, e1);
  ASSERT r ->> 'reason' = 'checked-in' AND (r ->> 'verified')::boolean, 'W4: Apple code admits, got ' || r;
  r := public.exos_check_in_ticket(c2, 'camera', 'verified', pg_temp.g_code(s2, now()), e1);
  ASSERT r ->> 'reason' = 'checked-in' AND (r ->> 'verified')::boolean, 'W4: Google TOTP admits, got ' || r;
  ASSERT (SELECT count(*) FROM public.exos_event_checkins WHERE ticket_id IN (c1, c2) AND verification = 'verified') = 2,
         'W4: logged as verified';
  -- Single use still holds.
  ASSERT public.exos_check_in_ticket(c1, 'camera', 'verified', code, e1) ->> 'reason' = 'used', 'W4: second scan is used';
  RAISE NOTICE 'PASS W4 door accepts the Apple code and the Google TOTP';
END $$;

-- W5. Reissue: the old code stops working.
DO $$
DECLARE
  e1 uuid := '8b000000-0000-0000-0000-0000000000e1';
  c3 uuid := '8b000000-0000-0000-0000-00000000c003';
  s text; old_code text; new_code text; r jsonb; raised boolean;
BEGIN
  PERFORM pg_temp.act('8b000000-0000-0000-0000-0000000000a5');
  s := public.exos_wallet_issue_pass(c3, 'apple', pg_temp.h('tok-hold-0000000000000003'), 'pass.com.exos.test') ->> 'serial';
  old_code := public.exos_wallet_pass_payload(s) ->> 'apple_code';
  PERFORM pg_temp.act('8b000000-0000-0000-0000-0000000000a6');
  raised := false;
  BEGIN PERFORM public.exos_wallet_reissue(c3);
  EXCEPTION WHEN insufficient_privilege THEN raised := SQLERRM LIKE '%not the ticket owner%'; END;
  ASSERT raised, 'W5: only the holder reissues';
  PERFORM pg_temp.act('8b000000-0000-0000-0000-0000000000a5');
  r := public.exos_wallet_reissue(c3);
  ASSERT (r ->> 'code_epoch')::int = 2, 'W5: epoch bumped, got ' || r;
  ASSERT (SELECT push_pending FROM public.exos_wallet_passes WHERE serial_number = s), 'W5: push pending';
  new_code := public.exos_wallet_pass_payload(s) ->> 'apple_code';
  ASSERT new_code <> old_code AND new_code LIKE '%:a2:%', 'W5: a new code';
  PERFORM pg_temp.act('8b000000-0000-0000-0000-0000000000a3');
  ASSERT public.exos_check_in_ticket(c3, 'camera', 'verified', old_code, e1) ->> 'reason' = 'barcode-rejected',
         'W5: the old (screenshotted) code is refused';
  ASSERT public.exos_check_in_ticket(c3, 'camera', 'verified', new_code, e1) ->> 'reason' = 'checked-in',
         'W5: the new code admits';
  RAISE NOTICE 'PASS W5 reissue retires the old code';
END $$;

-- W6. Transfer: the pass is voided, the new holder gets a new serial.
DO $$
DECLARE
  e1 uuid := '8b000000-0000-0000-0000-0000000000e1';
  c4 uuid := '8b000000-0000-0000-0000-00000000c004';
  s_old text; s_new text; old_code text; p jsonb; w record;
BEGIN
  PERFORM pg_temp.act('8b000000-0000-0000-0000-0000000000a5');
  s_old := public.exos_wallet_issue_pass(c4, 'apple', pg_temp.h('tok-hold-0000000000000004'), 'pass.com.exos.test') ->> 'serial';
  old_code := public.exos_wallet_pass_payload(s_old) ->> 'apple_code';
  PERFORM public.exos_wallet_register_device('dev-4', 'pass.com.exos.test', s_old, 'tok-hold-0000000000000004', 'bb44');
  UPDATE public.exos_wallet_passes SET push_pending = false WHERE serial_number = s_old;

  -- The claim (exos_claim_transfer) moves the owner and rotates the secret.
  UPDATE public.exos_tickets SET owner_id = '8b000000-0000-0000-0000-0000000000a6', buyer_id = '8b000000-0000-0000-0000-0000000000a6',
         barcode_secret = 'wsek-rotated-4' WHERE id = c4;
  SELECT * INTO w FROM public.exos_wallet_passes WHERE serial_number = s_old;
  ASSERT w.status = 'voided' AND w.void_reason = 'transferred' AND w.code_epoch = 2 AND w.push_pending,
         'W6: transfer voids the pass and queues a push';

  -- The old holder's device still fetches it (to show it voided), without a code.
  p := public.exos_wallet_fetch_pass('pass.com.exos.test', s_old, 'tok-hold-0000000000000004');
  ASSERT p ->> 'status' = 'voided' AND p ->> 'apple_code' IS NULL AND p ->> 'google_key_hex' IS NULL,
         'W6: voided payload has no code, got ' || p;
  ASSERT (public.exos_wallet_updated_serials('dev-4', 'pass.com.exos.test', NULL) -> 'serials') ? s_old,
         'W6: the device is told to update';

  -- The old holder can't re-issue it; the new holder gets a fresh serial.
  PERFORM pg_temp.act('8b000000-0000-0000-0000-0000000000a5');
  BEGIN
    PERFORM public.exos_wallet_issue_pass(c4, 'google');
    RAISE EXCEPTION 'W6: old holder re-issued';
  EXCEPTION WHEN insufficient_privilege THEN NULL; END;
  PERFORM pg_temp.act('8b000000-0000-0000-0000-0000000000a6');
  s_new := public.exos_wallet_issue_pass(c4, 'apple', pg_temp.h('tok-new-00000000000000004'), 'pass.com.exos.test') ->> 'serial';
  ASSERT s_new IS NOT NULL AND s_new <> s_old, 'W6: new holder, new serial';
  ASSERT (SELECT status FROM public.exos_wallet_passes WHERE serial_number = s_old) = 'voided', 'W6: the old pass stays voided';
  ASSERT public.exos_wallet_fetch_pass('pass.com.exos.test', s_new, 'tok-hold-0000000000000004') IS NULL,
         'W6: the old token does not open the new pass';

  PERFORM pg_temp.act('8b000000-0000-0000-0000-0000000000a3');
  ASSERT public.exos_check_in_ticket(c4, 'camera', 'verified', old_code, e1) ->> 'reason' = 'barcode-rejected',
         'W6: the old holder''s wallet code is refused';
  ASSERT public.exos_check_in_ticket(c4, 'camera', 'verified', public.exos_wallet_pass_payload(s_new) ->> 'apple_code', e1)
         ->> 'reason' = 'checked-in', 'W6: the new holder''s pass admits';
  RAISE NOTICE 'PASS W6 transfer voids the pass; new holder, new serial';
END $$;

-- W7. A refund void invalidates the pass.
DO $$
DECLARE
  e1 uuid := '8b000000-0000-0000-0000-0000000000e1';
  c5 uuid := '8b000000-0000-0000-0000-00000000c005';
  s text; code text; w record;
BEGIN
  PERFORM pg_temp.act('8b000000-0000-0000-0000-0000000000a5');
  s := public.exos_wallet_issue_pass(c5, 'google') ->> 'serial';
  code := pg_temp.g_code(s, now());
  UPDATE public.exos_tickets SET status = 'voided', voided_at = now(), voided_reason = 'refund' WHERE id = c5;
  SELECT * INTO w FROM public.exos_wallet_passes WHERE serial_number = s;
  ASSERT w.status = 'voided' AND w.void_reason = 'ticket-voided' AND w.code_epoch = 2 AND w.push_pending,
         'W7: void invalidates the pass';
  ASSERT (SELECT p ->> 'google_key_hex' IS NULL FROM (SELECT public.exos_wallet_pass_payload(s) p) x), 'W7: no key after a void';
  PERFORM pg_temp.act('8b000000-0000-0000-0000-0000000000a3');
  ASSERT public.exos_check_in_ticket(c5, 'camera', 'verified', code, e1) ->> 'reason' = 'barcode-rejected',
         'W7: the voided pass''s code is refused';
  PERFORM pg_temp.act('8b000000-0000-0000-0000-0000000000a5');
  ASSERT public.exos_wallet_issue_pass(c5, 'google') ->> 'reason' = 'not-active', 'W7: no new pass for a voided ticket';
  RAISE NOTICE 'PASS W7 voiding a ticket invalidates its pass';
END $$;

-- W8. Check-in refreshes the pass; updated serials; push queue / done.
DO $$
DECLARE
  e1 uuid := '8b000000-0000-0000-0000-0000000000e1';
  c6 uuid := '8b000000-0000-0000-0000-00000000c006';
  s text; tag text; q jsonb; before timestamptz; r jsonb;
BEGIN
  PERFORM pg_temp.act('8b000000-0000-0000-0000-0000000000a5');
  s := public.exos_wallet_issue_pass(c6, 'apple', pg_temp.h('tok-hold-0000000000000006'), 'pass.com.exos.test') ->> 'serial';
  PERFORM public.exos_wallet_register_device('dev-6', 'pass.com.exos.test', s, 'tok-hold-0000000000000006', 'cc66');
  r := public.exos_wallet_updated_serials('dev-6', 'pass.com.exos.test', NULL);
  ASSERT r -> 'serials' = jsonb_build_array(s), 'W8: first sync lists the pass, got ' || r;
  tag := r ->> 'last_updated';
  ASSERT jsonb_array_length(public.exos_wallet_updated_serials('dev-6', 'pass.com.exos.test', tag) -> 'serials') = 0,
         'W8: nothing new since the tag';
  ASSERT jsonb_array_length(public.exos_wallet_updated_serials('dev-x', 'pass.com.exos.test', NULL) -> 'serials') = 0,
         'W8: an unknown device gets nothing';

  before := (SELECT updated_at FROM public.exos_wallet_passes WHERE serial_number = s);
  PERFORM pg_temp.act('8b000000-0000-0000-0000-0000000000a3');
  PERFORM public.exos_check_in_ticket(c6, 'camera', 'verified', public.exos_wallet_pass_payload(s) ->> 'apple_code', e1);
  ASSERT (SELECT status = 'active' AND push_pending AND updated_at > before FROM public.exos_wallet_passes WHERE serial_number = s),
         'W8: check-in refreshes (still active)';
  ASSERT public.exos_wallet_updated_serials('dev-6', 'pass.com.exos.test', tag) -> 'serials' = jsonb_build_array(s),
         'W8: the device sees the change';
  ASSERT public.exos_wallet_pass_payload(s) #>> '{ticket,status}' = 'used', 'W8: payload says used';

  q := public.exos_wallet_push_queue(500);
  ASSERT EXISTS (SELECT 1 FROM jsonb_array_elements(q -> 'passes') e
                  WHERE e ->> 'serial' = s AND e -> 'push_tokens' = '["cc66"]'::jsonb), 'W8: queued with its push token';
  -- A change after the queue read is not cleared by the push-done.
  UPDATE public.exos_wallet_passes SET updated_at = clock_timestamp() + interval '1 second' WHERE serial_number = s;
  ASSERT public.exos_wallet_push_done(ARRAY[s], (q ->> 'queued_at')::timestamptz) = 0, 'W8: newer change stays pending';
  ASSERT public.exos_wallet_push_done(ARRAY[s], clock_timestamp() + interval '1 minute') = 1, 'W8: push done clears';
  ASSERT NOT (SELECT push_pending FROM public.exos_wallet_passes WHERE serial_number = s), 'W8: cleared';
  ASSERT public.exos_wallet_drop_push_tokens(ARRAY['cc66']) = 1, 'W8: gone tokens dropped';
  RAISE NOTICE 'PASS W8 refresh on check-in, updated serials, push queue';
END $$;

-- W9. The T- code is untouched; helpers stay private.
DO $$
DECLARE e1 uuid := '8b000000-0000-0000-0000-0000000000e1'; t uuid := '8b000000-0000-0000-0000-00000000c0aa';
BEGIN
  INSERT INTO public.exos_tickets(id,event_id,org_id,buyer_id,owner_id,status,barcode_secret,price_paid,order_ref)
  VALUES (t, e1, '8b000000-0000-0000-0000-000000000001','8b000000-0000-0000-0000-0000000000a5',
          '8b000000-0000-0000-0000-0000000000a5','active','wsek-aa',20,'wallet-seed-aa');
  PERFORM pg_temp.act('8b000000-0000-0000-0000-0000000000a3');
  ASSERT public.exos_check_in_ticket(t, 'camera', 'verified', pg_temp.t_code(t, now() - interval '10 minutes'), e1) ->> 'reason'
         = 'barcode-expired', 'W9: old T- code still expires';
  ASSERT public.exos_check_in_ticket(t, 'camera', 'verified', 'W-' || t || ':8b000000-0000-0000-0000-0000000000a5:a1:xyz', e1)
         ->> 'reason' = 'barcode-rejected', 'W9: a W- code without a pass is refused';
  ASSERT public.exos_check_in_ticket(t, 'camera', 'verified', pg_temp.t_code(t, now()), e1) ->> 'reason' = 'checked-in',
         'W9: T- code admits';
  ASSERT NOT has_function_privilege('authenticated', 'public._exos_wallet_check_code(uuid, uuid, text, text, timestamptz)', 'EXECUTE'), 'W9: check helper private';
  ASSERT NOT has_function_privilege('authenticated', 'public._exos_wallet_apple_code(uuid, uuid, text, int)', 'EXECUTE'), 'W9: code helper private';
  ASSERT NOT has_function_privilege('authenticated', 'public.exos_wallet_push_queue(int)', 'EXECUTE'), 'W9: push queue private';
  ASSERT NOT has_function_privilege('anon', 'public.exos_wallet_issue_pass(uuid, text, text, text)', 'EXECUTE'), 'W9: anon cannot issue';
  ASSERT has_function_privilege('authenticated', 'public.exos_wallet_issue_pass(uuid, text, text, text)', 'EXECUTE'), 'W9: holders can issue';
  RAISE NOTICE 'PASS W9 T- codes unchanged, helpers private';
END $$;

-- W10. Offline replay of a Google code checks the TOTP at the scan time.
DO $$
DECLARE e1 uuid := '8b000000-0000-0000-0000-0000000000e1'; t uuid := '8b000000-0000-0000-0000-00000000c0bb'; s text; r jsonb;
BEGIN
  INSERT INTO public.exos_tickets(id,event_id,org_id,buyer_id,owner_id,status,barcode_secret,price_paid,order_ref)
  VALUES (t, e1, '8b000000-0000-0000-0000-000000000001','8b000000-0000-0000-0000-0000000000a5',
          '8b000000-0000-0000-0000-0000000000a5','active','wsek-bb',20,'wallet-seed-bb');
  PERFORM pg_temp.act('8b000000-0000-0000-0000-0000000000a5');
  s := public.exos_wallet_issue_pass(t, 'google') ->> 'serial';
  PERFORM pg_temp.act('8b000000-0000-0000-0000-0000000000a3');
  r := public.exos_check_in_offline('8b000000-0000-0000-0000-0000000000f1', t, e1, now() - interval '3 minutes',
                                    pg_temp.g_code(s, now() - interval '20 minutes'), 'camera');
  ASSERT NOT (r ->> 'ok')::boolean AND (r ->> 'conflict')::boolean, 'W10: code from another time is a conflict, got ' || r;
  r := public.exos_check_in_offline('8b000000-0000-0000-0000-0000000000f2', t, e1, now() - interval '3 minutes',
                                    pg_temp.g_code(s, now() - interval '3 minutes'), 'camera');
  ASSERT (r ->> 'ok')::boolean AND r ->> 'reason' = 'checked-in', 'W10: offline replay admits, got ' || r;
  RAISE NOTICE 'PASS W10 offline replay verifies the TOTP at the scan time';
END $$;

ROLLBACK;
SELECT '*** wallet passes: ALL ASSERTIONS PASSED ***' AS result;
