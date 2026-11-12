-- ============================================================================
-- Kiosk mode (mig 20261113100000, docs/pos.md "Kiosk mode"):
--   K1  RLS on the two tables, no client writes, no hash readable; the kiosk
--       cores service role only; setup RPCs for signed-in members only
--   K2  the kiosk flag: owner / manager only, an admin PIN (required, not weak,
--       kept as bcrypt), the org's reader and event, the device's own event;
--       pos.kiosk_set audited
--   K3  entering kiosk mode: owner / manager, the credential shown once (only
--       its sha-256 kept), one live session per device; pos.kiosk_enter audited
--   K4  the credential: a bad, ended, expired or replaced one, a disabled
--       device, a demoted starter or a moved kiosk all read as 'kiosk-ended'
--   K5  the kiosk screen: public types only (no hidden, no tables), the
--       event's maxPerOrder, the reader, the questions
--   K6  event lock: another event's type, a hidden type, too many tickets,
--       required questions (never skippable) are refused
--   K7  a kiosk sale: channel 'kiosk', charged on the kiosk's own reader,
--       captured, tickets, the card tender, the journal entry, settlement
--       (with its kiosk block), the order JSON's channel
--   K8  card only: a cash or card door sale on the kiosk device, a comp, a
--       kiosk order completed by cash, a client insert claiming 'kiosk'
--   K9  order keys: the same key replays the same sale in its own session,
--       another session (or the door) can't reuse it
--   K10 hand-over: QR codes and email for the session's own paid sale, for
--       10 minutes; never another session's order
--   K11 the PIN exit: a wrong PIN counts (and the count sticks), 5 wrong lock
--       it for 5 minutes (audited), the right one ends the session (audited)
--   K12 cross-org: another org's owner, device, event or reader; RLS reads
--   K13 a session ends from the dashboard (pos.kiosk_exit via staff) and with
--       the kiosk turned off (pos.kiosk_off); a moved event ends it
--   K14 hidden / staff-only questions: not on the kiosk screen, an answer to
--       one is refused, a hidden required one isn't required at the kiosk
--   K15 one open sale per session (busy while it holds places, released once
--       lapsed), 6 begins a minute per session
--   K16 a charge never extends the hold past 10 minutes from the begin; the
--       card limit counts on the kiosk session, not on its starter
--   K17 hand-over only for the session's most recent paid sale
-- Self-contained (BEGIN / ROLLBACK). Org …01: owner a1, manager a2, scanner a3,
-- finance a4. Org …02: owner b9.
-- ============================================================================
\set ON_ERROR_STOP on
BEGIN;

CREATE FUNCTION pg_temp.u(p text) RETURNS uuid LANGUAGE sql IMMUTABLE AS $$
  SELECT ('c0b10000-0000-0000-0000-0000000000' || p)::uuid $$;
CREATE FUNCTION pg_temp.k(p text) RETURNS uuid LANGUAGE sql IMMUTABLE AS $$
  SELECT ('c0b10000-0000-0000-0000-00000000c0' || p)::uuid $$;
GRANT EXECUTE ON FUNCTION pg_temp.u(text) TO authenticated;
CREATE FUNCTION pg_temp.act(p_uid uuid) RETURNS void LANGUAGE sql AS $$
  SELECT set_config('app.uid', coalesce(p_uid::text, ''), true), set_config('app.jwt', '', true) $$;
GRANT EXECUTE ON FUNCTION pg_temp.act(uuid) TO authenticated;
-- SQLSTATE, or SQLSTATE:hint.
CREATE FUNCTION pg_temp.st(p_sql text) RETURNS text LANGUAGE plpgsql AS $$
DECLARE v_hint text;
BEGIN
  EXECUTE p_sql;
  RETURN 'ok';
EXCEPTION WHEN OTHERS THEN
  GET STACKED DIAGNOSTICS v_hint = PG_EXCEPTION_HINT;
  RETURN SQLSTATE || CASE WHEN coalesce(v_hint, '') <> '' THEN ':' || v_hint ELSE '' END;
END $$;
GRANT EXECUTE ON FUNCTION pg_temp.st(text) TO authenticated;
CREATE TEMP TABLE tk (k text PRIMARY KEY, v text) ON COMMIT DROP;
GRANT SELECT ON tk TO authenticated;
CREATE FUNCTION pg_temp.v(p_k text) RETURNS text LANGUAGE sql AS $$ SELECT v FROM tk WHERE k = p_k $$;
INSERT INTO auth.users (id, email, email_confirmed_at) VALUES
  (pg_temp.u('a1'), 'c0b1-owner@x.com', now()), (pg_temp.u('a2'), 'c0b1-manager@x.com', now()),
  (pg_temp.u('a3'), 'c0b1-scanner@x.com', now()), (pg_temp.u('a4'), 'c0b1-finance@x.com', now()),
  (pg_temp.u('b9'), 'c0b1-other@x.com', now());
INSERT INTO public.exos_orgs (id, name, slug, owner_uid) VALUES
  (pg_temp.u('01'), 'Kiosk Fair', 'c0b1-fair', pg_temp.u('a1')),
  (pg_temp.u('02'), 'Kiosk Other', 'c0b1-other', pg_temp.u('b9'));
INSERT INTO public.exos_org_memberships (org_id, user_id, role) VALUES
  (pg_temp.u('01'), pg_temp.u('a1'), 'owner'), (pg_temp.u('01'), pg_temp.u('a2'), 'manager'),
  (pg_temp.u('01'), pg_temp.u('a3'), 'scanner'), (pg_temp.u('01'), pg_temp.u('a4'), 'finance'),
  (pg_temp.u('02'), pg_temp.u('b9'), 'owner');
-- The harness has no phase-1 exos_org_secrets: its prod shape, rolled back.
CREATE TABLE IF NOT EXISTS public.exos_org_secrets (
  org_id uuid PRIMARY KEY, payments jsonb, updated_at timestamptz NOT NULL DEFAULT now());
INSERT INTO public.exos_org_secrets (org_id, payments) VALUES
  (pg_temp.u('01'), '{"connectedAccountId":"acct_kioskOrgA","chargesEnabled":true}'),
  (pg_temp.u('02'), '{"connectedAccountId":"acct_kioskOrgB","chargesEnabled":true}')
ON CONFLICT (org_id) DO UPDATE SET payments = EXCLUDED.payments;
INSERT INTO public.exos_events (id, org_id, name, slug, status, starts_at, total_tickets, tickets_sold, currency, created_by, purchase_limits) VALUES
  (pg_temp.u('e1'), pg_temp.u('01'), 'County Fair', 'c0b1-fair', 'published', now() + interval '1 hour', 200, 0, 'usd', pg_temp.u('a1'),
   '{"maxPerOrder": 4}'),
  (pg_temp.u('e2'), pg_temp.u('01'), 'County Fair Day 2', 'c0b1-fair2', 'published', now() + interval '1 day', 200, 0, 'usd', pg_temp.u('a1'), NULL),
  (pg_temp.u('e9'), pg_temp.u('02'), 'Other Fair', 'c0b1-else', 'published', now() + interval '1 hour', 60, 0, 'usd', pg_temp.u('b9'), NULL);
INSERT INTO public.exos_ticket_tiers (id, event_id, name, price, capacity, sold, visibility, sort_order, door_price_cents) VALUES
  (pg_temp.u('d1'), pg_temp.u('e1'), 'Adult', 15, 50, 0, 'public', 1, 1500),
  (pg_temp.u('d2'), pg_temp.u('e1'), 'Child', 5, 50, 0, 'public', 2, 500),
  (pg_temp.u('d3'), pg_temp.u('e1'), 'Staff comp', 0, 50, 0, 'hidden', 3, NULL),
  (pg_temp.u('d6'), pg_temp.u('e2'), 'Adult', 15, 50, 0, 'public', 1, NULL),
  (pg_temp.u('d9'), pg_temp.u('e9'), 'Adult', 10, 50, 0, 'public', 1, NULL);
-- Devices: kiosk tablets (c1, c2 org A; cb org B), one set to e2, a disabled one.
INSERT INTO public.exos_pos_devices (id, org_id, event_id, name, kind, status) VALUES
  (pg_temp.u('c1'), pg_temp.u('01'), NULL, 'Gate kiosk 1', 'register', 'active'),
  (pg_temp.u('c2'), pg_temp.u('01'), NULL, 'Gate kiosk 2', 'register', 'active'),
  (pg_temp.u('c3'), pg_temp.u('01'), pg_temp.u('e2'), 'Day 2 tablet', 'register', 'active'),
  (pg_temp.u('c4'), pg_temp.u('01'), NULL, 'Old tablet', 'register', 'disabled'),
  (pg_temp.u('cb'), pg_temp.u('02'), NULL, 'Other kiosk', 'register', 'active');
DO $$
DECLARE r jsonb;
BEGIN
  PERFORM public._exos_pos_terminal_save_location(pg_temp.u('a1'), pg_temp.u('01'), false, 'tml_KioskA', 'Fair gate', '{"line1":"1 Fair Rd"}');
  PERFORM public._exos_pos_terminal_save_location(pg_temp.u('b9'), pg_temp.u('02'), false, 'tml_KioskB', 'Other gate', '{"line1":"2 Fair Rd"}');
  r := public._exos_pos_terminal_save_reader(pg_temp.u('a1'), pg_temp.u('01'), false, 'tmr_KioskOne', 'Kiosk reader 1', 'stripe_s700', NULL);
  INSERT INTO tk VALUES ('reader', r ->> 'device_id');
  r := public._exos_pos_terminal_save_reader(pg_temp.u('a1'), pg_temp.u('01'), false, 'tmr_KioskTwo', 'Kiosk reader 2', 'stripe_s700', NULL);
  INSERT INTO tk VALUES ('reader2', r ->> 'device_id');
  r := public._exos_pos_terminal_save_reader(pg_temp.u('b9'), pg_temp.u('02'), false, 'tmr_KioskB', 'B reader', NULL, NULL);
  INSERT INTO tk VALUES ('b_reader', r ->> 'device_id');
END $$;

-- ── K1 ──────────────────────────────────────────────────────────────────────
DO $$
DECLARE t text; f text;
BEGIN
  FOREACH t IN ARRAY ARRAY['exos_pos_kiosks', 'exos_pos_kiosk_sessions'] LOOP
    ASSERT (SELECT relrowsecurity FROM pg_class WHERE oid = ('public.' || t)::regclass), 'K1: RLS on ' || t;
    ASSERT NOT has_table_privilege('anon', 'public.' || t, 'SELECT'), 'K1: anon reads nothing of ' || t;
    ASSERT NOT has_table_privilege('authenticated', 'public.' || t, 'INSERT')
       AND NOT has_table_privilege('authenticated', 'public.' || t, 'UPDATE')
       AND NOT has_table_privilege('authenticated', 'public.' || t, 'DELETE'), 'K1: no client writes on ' || t;
  END LOOP;
  ASSERT has_column_privilege('authenticated', 'public.exos_pos_kiosks', 'event_id', 'SELECT')
     AND NOT has_column_privilege('authenticated', 'public.exos_pos_kiosks', 'pin_hash', 'SELECT')
     AND NOT has_column_privilege('authenticated', 'public.exos_pos_kiosks', 'pin_failures', 'SELECT'), 'K1: no PIN hash readable';
  ASSERT has_column_privilege('authenticated', 'public.exos_pos_kiosk_sessions', 'ended_at', 'SELECT')
     AND NOT has_column_privilege('authenticated', 'public.exos_pos_kiosk_sessions', 'token_hash', 'SELECT'), 'K1: no credential hash readable';
  FOREACH f IN ARRAY ARRAY[
      'public._exos_pos_kiosk_pin_ok(text)', 'public._exos_pos_kiosk_resolve(text)', 'public._exos_pos_kiosk_tiers(uuid)',
      'public._exos_pos_kiosk_max(uuid)', 'public._exos_pos_kiosk_state(text,boolean)',
      'public._exos_pos_kiosk_begin(text,uuid,integer,uuid,jsonb,boolean)', 'public._exos_pos_kiosk_order(uuid,uuid)',
      'public._exos_pos_kiosk_charge(text,uuid,boolean)', 'public._exos_pos_kiosk_lookup(text,uuid)',
      'public._exos_pos_kiosk_paid(uuid,uuid)', 'public._exos_pos_kiosk_codes(text,uuid)',
      'public._exos_pos_kiosk_email(text,uuid,text)', 'public._exos_pos_kiosk_exit(text,text)'] LOOP
    ASSERT NOT has_function_privilege('authenticated', f, 'EXECUTE') AND NOT has_function_privilege('anon', f, 'EXECUTE')
       AND has_function_privilege('service_role', f, 'EXECUTE'), 'K1: service role only: ' || f;
    ASSERT (SELECT proconfig::text LIKE '%search_path=public, pg_temp%' FROM pg_proc WHERE oid = f::regprocedure),
      'K1: fixed search_path: ' || f;
  END LOOP;
  FOREACH f IN ARRAY ARRAY['public.exos_pos_kiosk_configure(uuid,uuid,uuid,text,boolean)', 'public.exos_pos_kiosk_enter(uuid)',
                           'public.exos_pos_kiosk_end(uuid)'] LOOP
    ASSERT has_function_privilege('authenticated', f, 'EXECUTE') AND NOT has_function_privilege('anon', f, 'EXECUTE')
       AND (SELECT prosecdef FROM pg_proc WHERE oid = f::regprocedure), 'K1: members (checked inside), never anon: ' || f;
  END LOOP;
  ASSERT NOT has_function_privilege('authenticated', 'public.exos_pos_tg_order_kiosk()', 'EXECUTE'), 'K1: trigger function';
  ASSERT position('/* exos: pos kiosk channel */' in pg_get_functiondef('public._exos_pos_order_json(uuid,uuid)'::regprocedure)) > 0
     AND position('/* exos: pos kiosk card only */' in pg_get_functiondef('public._exos_pos_walkup_complete(uuid,uuid,text,uuid,text)'::regprocedure)) > 0
     AND position('/* exos: pos terminal card tender */' in pg_get_functiondef('public._exos_pos_walkup_complete(uuid,uuid,text,uuid,text)'::regprocedure)) > 0
     AND position('/* exos: pos kiosk settlement */' in pg_get_functiondef('public.exos_pos_settlement_summary(uuid)'::regprocedure)) > 0
     AND position('/* exos: pos kiosk card limit */' in pg_get_functiondef('public._exos_pos_card_begin(uuid,uuid,text,uuid,boolean)'::regprocedure)) > 0,
    'K1: the four patches, earlier markers kept';
  RAISE NOTICE 'OK K1 RLS on, no client writes, no hash readable, cores service role only, patches in place';
END $$;

-- ── K2 ──────────────────────────────────────────────────────────────────────
DO $$
DECLARE r jsonb; v_hash text;
BEGIN
  PERFORM pg_temp.act(pg_temp.u('a3'));
  ASSERT pg_temp.st(format('SELECT public.exos_pos_kiosk_configure(%L, %L, %L, %L)', pg_temp.u('c1'), pg_temp.u('e1'),
                           pg_temp.v('reader'), '482913')) = 'P0002', 'K2: a scanner: not found';
  PERFORM pg_temp.act(pg_temp.u('a4'));
  ASSERT pg_temp.st(format('SELECT public.exos_pos_kiosk_configure(%L, %L, %L, %L)', pg_temp.u('c1'), pg_temp.u('e1'),
                           pg_temp.v('reader'), '482913')) = 'P0002', 'K2: finance: not found';
  PERFORM pg_temp.act(NULL);
  ASSERT pg_temp.st(format('SELECT public.exos_pos_kiosk_configure(%L, %L, %L, %L)', pg_temp.u('c1'), pg_temp.u('e1'),
                           pg_temp.v('reader'), '482913')) = '42501', 'K2: signed out';
  PERFORM pg_temp.act(pg_temp.u('a2'));
  ASSERT pg_temp.st(format('SELECT public.exos_pos_kiosk_configure(%L, %L, %L, NULL)', pg_temp.u('c1'), pg_temp.u('e1'),
                           pg_temp.v('reader'))) = '22023:pin-required', 'K2: a PIN is required';
  ASSERT pg_temp.st(format('SELECT public.exos_pos_kiosk_configure(%L, %L, %L, %L)', pg_temp.u('c1'), pg_temp.u('e1'),
                           pg_temp.v('reader'), '1234')) = '22023:pin-weak', 'K2: too short';
  ASSERT pg_temp.st(format('SELECT public.exos_pos_kiosk_configure(%L, %L, %L, %L)', pg_temp.u('c1'), pg_temp.u('e1'),
                           pg_temp.v('reader'), '123456')) = '22023:pin-weak', 'K2: a run';
  ASSERT pg_temp.st(format('SELECT public.exos_pos_kiosk_configure(%L, %L, %L, %L)', pg_temp.u('c1'), pg_temp.u('e1'),
                           pg_temp.v('reader'), '777777')) = '22023:pin-weak', 'K2: one digit';
  ASSERT pg_temp.st(format('SELECT public.exos_pos_kiosk_configure(%L, %L, %L, %L)', pg_temp.u('c1'), pg_temp.u('e1'),
                           pg_temp.v('reader'), '12ab56')) = '22023:pin-weak', 'K2: digits only';
  ASSERT pg_temp.st(format('SELECT public.exos_pos_kiosk_configure(%L, %L, %L, %L)', pg_temp.u('c1'), pg_temp.u('e1'),
                           pg_temp.u('c2'), '482913')) = '22023:no-reader', 'K2: a tablet is not a reader';
  ASSERT pg_temp.st(format('SELECT public.exos_pos_kiosk_configure(%L, %L, %L, %L)', pg_temp.u('c3'), pg_temp.u('e1'),
                           pg_temp.v('reader'), '482913')) = '22023:kiosk-device', 'K2: the device is set to another event';
  ASSERT pg_temp.st(format('SELECT public.exos_pos_kiosk_configure(%L, %L, %L, %L)', pg_temp.u('c4'), pg_temp.u('e1'),
                           pg_temp.v('reader'), '482913')) = '22023:kiosk-device', 'K2: a disabled device';
  ASSERT pg_temp.st(format('SELECT public.exos_pos_kiosk_configure(%L, %L, %L, %L)', pg_temp.v('reader'), pg_temp.u('e1'),
                           pg_temp.v('reader'), '482913')) = '22023:kiosk-device', 'K2: a reader is not a kiosk';
  r := public.exos_pos_kiosk_configure(pg_temp.u('c1'), pg_temp.u('e1'), pg_temp.v('reader')::uuid, '482913', true);
  ASSERT (r ->> 'kiosk')::boolean AND (r ->> 'printer')::boolean AND r ->> 'event_id' = pg_temp.u('e1')::text, 'K2: set ' || r::text;
  SELECT pin_hash INTO v_hash FROM public.exos_pos_kiosks WHERE device_id = pg_temp.u('c1');
  ASSERT v_hash LIKE '$2a$08$%' AND position('482913' in v_hash) = 0 AND extensions.crypt('482913', v_hash) = v_hash,
    'K2: bcrypt, never the PIN';
  -- Re-set without a PIN keeps it.
  r := public.exos_pos_kiosk_configure(pg_temp.u('c1'), pg_temp.u('e1'), pg_temp.v('reader')::uuid, NULL, false);
  ASSERT (SELECT pin_hash = v_hash AND NOT printer FROM public.exos_pos_kiosks WHERE device_id = pg_temp.u('c1')), 'K2: PIN kept';
  PERFORM pg_temp.act(pg_temp.u('a1'));
  PERFORM public.exos_pos_kiosk_configure(pg_temp.u('c2'), pg_temp.u('e1'), pg_temp.v('reader2')::uuid, '905172', false);
  ASSERT (SELECT count(*) FROM public.exos_org_audit WHERE org_id = pg_temp.u('01') AND action = 'pos.kiosk_set') = 3
     AND (SELECT count(*) FROM public.exos_org_audit WHERE org_id = pg_temp.u('01') AND action = 'pos.kiosk_set'
           AND entity_id = pg_temp.u('c1')::text AND actor_uid = pg_temp.u('a2') AND source = 'pos') = 2,
    'K2: pos.kiosk_set audited per change';
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_org_audit WHERE org_id = pg_temp.u('01')
                      AND (changes::text LIKE '%482913%' OR changes::text LIKE '%$2a$%')), 'K2: no PIN or hash in the audit';
  RAISE NOTICE 'OK K2 kiosk flag: owner / manager, PIN required + not weak + bcrypt, org reader, device rules, audited';
END $$;

-- ── K3 ──────────────────────────────────────────────────────────────────────
DO $$
DECLARE r jsonb; r2 jsonb;
BEGIN
  PERFORM pg_temp.act(pg_temp.u('a3'));
  ASSERT pg_temp.st(format('SELECT public.exos_pos_kiosk_enter(%L)', pg_temp.u('c1'))) = 'P0002', 'K3: a scanner can''t start it';
  PERFORM pg_temp.act(pg_temp.u('a2'));
  ASSERT pg_temp.st(format('SELECT public.exos_pos_kiosk_enter(%L)', pg_temp.u('c3'))) = 'P0002', 'K3: not a kiosk';
  r := public.exos_pos_kiosk_enter(pg_temp.u('c1'));
  ASSERT r ->> 'token' ~ '^exk_[0-9a-f]{64}$' AND r ->> 'event_id' = pg_temp.u('e1')::text, 'K3: credential ' || r::text;
  ASSERT (SELECT token_hash = encode(extensions.digest(r ->> 'token', 'sha256'), 'hex') AND position(r ->> 'token' in token_hash) = 0
            AND started_by = pg_temp.u('a2') AND expires_at > now() + interval '23 hours'
            FROM public.exos_pos_kiosk_sessions WHERE id = (r ->> 'session_id')::uuid), 'K3: only the sha-256 is kept';
  -- Started again (another browser): the first one ends.
  r2 := public.exos_pos_kiosk_enter(pg_temp.u('c1'));
  ASSERT (SELECT ended_reason = 'replaced' FROM public.exos_pos_kiosk_sessions WHERE id = (r ->> 'session_id')::uuid), 'K3: replaced';
  ASSERT (SELECT count(*) FROM public.exos_pos_kiosk_sessions WHERE device_id = pg_temp.u('c1') AND ended_at IS NULL) = 1, 'K3: one live';
  INSERT INTO tk VALUES ('old_tok', r ->> 'token'), ('tok', r2 ->> 'token'), ('sess', r2 ->> 'session_id');
  PERFORM pg_temp.act(pg_temp.u('a1'));
  r := public.exos_pos_kiosk_enter(pg_temp.u('c2'));
  INSERT INTO tk VALUES ('tok2', r ->> 'token'), ('sess2', r ->> 'session_id');
  ASSERT (SELECT count(*) FROM public.exos_org_audit WHERE org_id = pg_temp.u('01') AND action = 'pos.kiosk_enter') = 3
     AND NOT EXISTS (SELECT 1 FROM public.exos_org_audit WHERE action = 'pos.kiosk_enter' AND changes::text LIKE '%exk_%'),
    'K3: pos.kiosk_enter audited, no credential in it';
  RAISE NOTICE 'OK K3 enter: owner / manager, credential once (sha-256 kept), one live session per device, audited';
END $$;

-- ── K4 ──────────────────────────────────────────────────────────────────────
DO $$
BEGIN
  PERFORM pg_temp.act(NULL);
  ASSERT (public._exos_pos_kiosk_resolve(pg_temp.v('tok')) ->> 'event_id')::uuid = pg_temp.u('e1'), 'K4: live';
  ASSERT pg_temp.st($q$SELECT public._exos_pos_kiosk_resolve('nope')$q$) = '42501:kiosk-ended', 'K4: malformed';
  ASSERT pg_temp.st(format('SELECT public._exos_pos_kiosk_resolve(%L)', 'exk_' || repeat('0', 64))) = '42501:kiosk-ended', 'K4: unknown';
  ASSERT pg_temp.st(format('SELECT public._exos_pos_kiosk_resolve(%L)', pg_temp.v('old_tok'))) = '42501:kiosk-ended', 'K4: replaced';
  -- Expired.
  UPDATE public.exos_pos_kiosk_sessions SET expires_at = now() - interval '1 second' WHERE id = pg_temp.v('sess')::uuid;
  ASSERT pg_temp.st(format('SELECT public._exos_pos_kiosk_resolve(%L)', pg_temp.v('tok'))) = '42501:kiosk-ended', 'K4: expired';
  UPDATE public.exos_pos_kiosk_sessions SET expires_at = now() + interval '1 hour' WHERE id = pg_temp.v('sess')::uuid;
  -- The device disabled.
  UPDATE public.exos_pos_devices SET status = 'disabled' WHERE id = pg_temp.u('c1');
  ASSERT pg_temp.st(format('SELECT public._exos_pos_kiosk_resolve(%L)', pg_temp.v('tok'))) = '42501:kiosk-ended', 'K4: device off';
  UPDATE public.exos_pos_devices SET status = 'active' WHERE id = pg_temp.u('c1');
  -- The member who started it is no longer a manager.
  UPDATE public.exos_org_memberships SET role = 'scanner' WHERE org_id = pg_temp.u('01') AND user_id = pg_temp.u('a2');
  ASSERT pg_temp.st(format('SELECT public._exos_pos_kiosk_resolve(%L)', pg_temp.v('tok'))) = '42501:kiosk-ended', 'K4: starter demoted';
  UPDATE public.exos_org_memberships SET role = 'manager' WHERE org_id = pg_temp.u('01') AND user_id = pg_temp.u('a2');
  ASSERT (public._exos_pos_kiosk_resolve(pg_temp.v('tok')) ->> 'actor')::uuid = pg_temp.u('a2'), 'K4: live again';
  RAISE NOTICE 'OK K4 a bad / replaced / expired credential, a disabled device or a demoted starter ends the kiosk';
END $$;

-- ── K5 ──────────────────────────────────────────────────────────────────────
DO $$
DECLARE r jsonb;
BEGIN
  PERFORM pg_temp.act(NULL);
  r := public._exos_pos_kiosk_state(pg_temp.v('tok'), false);
  ASSERT r -> 'event' ->> 'name' = 'County Fair' AND (r ->> 'max_per_order')::int = 4, 'K5: event + max ' || r::text;
  ASSERT jsonb_array_length(r -> 'tiers') = 2
     AND (SELECT bool_and(x ->> 'name' IN ('Adult', 'Child')) FROM jsonb_array_elements(r -> 'tiers') x)
     AND (r -> 'tiers' -> 0 ->> 'price_cents')::int = 1500 AND r -> 'tiers' -> 0 ->> 'price_source' = 'door', 'K5: public types at the door price';
  ASSERT (r -> 'reader' ->> 'ready')::boolean AND r -> 'reader' ->> 'label' = 'Kiosk reader 1', 'K5: the kiosk''s reader';
  ASSERT NOT (public._exos_pos_kiosk_state(pg_temp.v('tok'), true) -> 'reader' ->> 'ready')::boolean, 'K5: no live reader';
  ASSERT r -> 'kiosk' ->> 'device_name' = 'Gate kiosk 1' AND jsonb_typeof(r -> 'questions') = 'array', 'K5: device + questions';
  ASSERT position('pin' in r::text) = 0 AND position('token' in r::text) = 0, 'K5: no secret in the state';
  RAISE NOTICE 'OK K5 the kiosk screen: public types only, max per order, its reader, questions, no secrets';
END $$;

-- ── K6 ──────────────────────────────────────────────────────────────────────
DO $$
DECLARE q jsonb;
BEGIN
  PERFORM pg_temp.act(NULL);
  ASSERT pg_temp.st(format('SELECT public._exos_pos_kiosk_begin(%L, %L, 1, %L, NULL, false)', pg_temp.v('tok'), pg_temp.u('d6'),
                           pg_temp.k('01'))) = 'P0002', 'K6: another event''s type (same org)';
  ASSERT pg_temp.st(format('SELECT public._exos_pos_kiosk_begin(%L, %L, 1, %L, NULL, false)', pg_temp.v('tok'), pg_temp.u('d9'),
                           pg_temp.k('01'))) = 'P0002', 'K6: another org''s type';
  ASSERT pg_temp.st(format('SELECT public._exos_pos_kiosk_begin(%L, %L, 1, %L, NULL, false)', pg_temp.v('tok'), pg_temp.u('d3'),
                           pg_temp.k('01'))) = 'P0002', 'K6: a hidden type';
  ASSERT pg_temp.st(format('SELECT public._exos_pos_kiosk_begin(%L, %L, 5, %L, NULL, false)', pg_temp.v('tok'), pg_temp.u('d1'),
                           pg_temp.k('01'))) = '22023:max-per-order', 'K6: maxPerOrder 4';
  ASSERT pg_temp.st(format('SELECT public._exos_pos_kiosk_begin(%L, %L, 0, %L, NULL, false)', pg_temp.v('tok'), pg_temp.u('d1'),
                           pg_temp.k('01'))) = '22023:max-per-order', 'K6: at least one';
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_pos_orders WHERE client_ref = pg_temp.k('01')), 'K6: nothing begun';
  -- A required question: answered or refused, never skipped.
  PERFORM pg_temp.act(pg_temp.u('a1'));
  q := public.exos_save_event_question(pg_temp.u('e1'), '{"label":"ZIP code","kind":"text","required":true,"scope":"order"}');
  INSERT INTO tk VALUES ('q_zip', q ->> 'id');
  PERFORM pg_temp.act(NULL);
  ASSERT pg_temp.st(format('SELECT public._exos_pos_kiosk_begin(%L, %L, 1, %L, NULL, false)', pg_temp.v('tok'), pg_temp.u('d1'),
                           pg_temp.k('01'))) = '22023:questions-required', 'K6: required question unanswered';
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_pos_question_skips WHERE event_id = pg_temp.u('e1')), 'K6: no skip logged';
  ASSERT coalesce(current_setting('exos.pos_kiosk_session', true), '') = '', 'K6: the kiosk flag never outlives the call';
  RAISE NOTICE 'OK K6 event lock: other event / org, hidden type, maxPerOrder, required questions never skipped';
END $$;

-- ── K7 ──────────────────────────────────────────────────────────────────────
DO $$
DECLARE r jsonb; v_o uuid; v_sold int; s jsonb; v_ans jsonb;
BEGIN
  v_sold := (SELECT sold FROM public.exos_ticket_tiers WHERE id = pg_temp.u('d1'));
  v_ans := jsonb_build_object('order', jsonb_build_object(pg_temp.v('q_zip'), '86001'));
  PERFORM pg_temp.act(NULL);
  r := public._exos_pos_kiosk_begin(pg_temp.v('tok'), pg_temp.u('d1'), 2, pg_temp.k('02'), v_ans, false);
  v_o := (r ->> 'id')::uuid;
  INSERT INTO tk VALUES ('o1', v_o::text);
  ASSERT r ->> 'status' = 'pending' AND r ->> 'channel' = 'kiosk' AND (r ->> 'total_cents')::int = 3000
     AND r -> 'card' ->> 'status' = 'awaiting' AND NOT (r ->> 'questions_skipped')::boolean, 'K7: pending kiosk sale ' || r::text;
  ASSERT (SELECT channel = 'kiosk' AND kiosk_session_id = pg_temp.v('sess')::uuid AND device_id = pg_temp.u('c1')
            AND rung_by = pg_temp.u('a2') AND buyer_email IS NULL FROM public.exos_pos_orders WHERE id = v_o), 'K7: stamped kiosk';
  -- Charged on the kiosk's own reader.
  s := public._exos_pos_kiosk_charge(pg_temp.v('tok'), v_o, false);
  ASSERT s ->> 'reader_id' = 'tmr_KioskOne' AND (s ->> 'amount_cents')::int = 3000 AND s ->> 'destination' = 'acct_kioskOrgA',
    'K7: plan on the kiosk reader ' || s::text;
  PERFORM public._exos_pos_card_attach(v_o, 'pi_K7kiosk', 3000, 'usd', 140, 90, 50, 300);
  s := public._exos_pos_kiosk_lookup(pg_temp.v('tok'), v_o);
  ASSERT s ->> 'status' = 'processing' AND s ->> 'reader_id' = 'tmr_KioskOne' AND s ->> 'payment_intent_id' = 'pi_K7kiosk', 'K7: lookup';
  ASSERT public._exos_pos_card_capture_prepare(v_o, 'pi_K7kiosk') ->> 'action' = 'capture', 'K7: capture';
  r := public._exos_pos_card_complete(v_o, 'pi_K7kiosk', 3000, 'door', NULL);
  ASSERT r ->> 'status' = 'paid' AND r ->> 'payment_method' = 'card' AND r ->> 'channel' = 'kiosk'
     AND (r -> 'tenders' ->> 'card')::int = 3000, 'K7: paid by card ' || r::text;
  ASSERT (SELECT count(*) FROM public.exos_tickets WHERE order_ref = 'pos:' || v_o AND status = 'active' AND owner_id = pg_temp.u('a2')) = 2
     AND (SELECT sold FROM public.exos_ticket_tiers WHERE id = pg_temp.u('d1')) = v_sold + 2, 'K7: two tickets';
  ASSERT EXISTS (SELECT 1 FROM public.exos_question_answers a WHERE a.order_ref = 'pos:' || v_o), 'K7: the answers kept';
  -- The journal: the same entry as a door card sale.
  ASSERT EXISTS (SELECT 1 FROM public.exos_journal_entries e JOIN public.exos_pos_payments p ON e.source_id = p.id::text
                  WHERE p.order_id = v_o AND p.method = 'card' AND e.kind = 'pos_card_sale'), 'K7: journal pos_card_sale';
  -- Settlement counts it, and shows the kiosk apart.
  PERFORM pg_temp.act(pg_temp.u('a1'));
  s := public.exos_pos_settlement_summary(pg_temp.u('e1'));
  ASSERT (s -> 'tenders' ->> 'card')::int >= 3000 AND (s -> 'kiosk' ->> 'orders')::int = 1 AND (s -> 'kiosk' ->> 'tickets')::int = 2
     AND (s -> 'kiosk' ->> 'gross_cents')::int = 3000, 'K7: settlement ' || (s -> 'kiosk')::text;
  ASSERT (SELECT j ->> 'channel' FROM jsonb_array_elements(public.exos_pos_recent_sales(pg_temp.u('e1'), 10)) j
           WHERE j ->> 'id' = v_o::text) = 'kiosk', 'K7: recent sales show the channel';
  RAISE NOTICE 'OK K7 kiosk sale: channel kiosk, its own reader, card tender, tickets, journal, settlement block';
END $$;

-- ── K8 ──────────────────────────────────────────────────────────────────────
DO $$
DECLARE v_o uuid;
BEGIN
  -- A door sale on the kiosk device: refused (cash, and the card path too).
  PERFORM pg_temp.act(pg_temp.u('a2'));
  ASSERT pg_temp.st(format($q$SELECT public.exos_pos_walkup_sell(%L, %L, 1, %L, 0, 'cash', %L, NULL, NULL, NULL, %L::jsonb, NULL)$q$,
                           pg_temp.u('e1'), pg_temp.u('d1'), pg_temp.k('03'), pg_temp.u('c1'),
                           jsonb_build_object('order', jsonb_build_object(pg_temp.v('q_zip'), '1'))))
         = '0A000:kiosk-card-only', 'K8: cash on the kiosk device';
  PERFORM pg_temp.act(NULL);
  ASSERT pg_temp.st(format($q$SELECT public._exos_pos_walkup_begin_card(%L, %L, %L, 1, %L, %L, NULL, NULL, %L::jsonb, false, false)$q$,
                           pg_temp.u('a2'), pg_temp.u('e1'), pg_temp.u('d1'), pg_temp.k('04'), pg_temp.u('c1'),
                           jsonb_build_object('order', jsonb_build_object(pg_temp.v('q_zip'), '1'))))
         = '0A000:kiosk-card-only', 'K8: a door card sale on the kiosk device';
  -- A comp under the kiosk flag (as if a kiosk asked): refused by the trigger.
  ASSERT pg_temp.st(format($q$
    SELECT set_config('exos.pos_kiosk_session', %L, true), set_config('exos.pos_walkup', 'on', true);
    INSERT INTO public.exos_pos_orders (event_id, device_id, client_ref, rung_by, comp_quantity) VALUES (%L, %L, %L, %L, 1)$q$,
                           pg_temp.v('sess'), pg_temp.u('e1'), pg_temp.u('c1'), pg_temp.k('05'), pg_temp.u('a2')))
         = '0A000:kiosk-card-only', 'K8: no comps at a kiosk';
  -- The kiosk flag with another event or device: refused.
  ASSERT pg_temp.st(format($q$
    SELECT set_config('exos.pos_kiosk_session', %L, true);
    INSERT INTO public.exos_pos_orders (event_id, device_id, client_ref, rung_by) VALUES (%L, %L, %L, %L)$q$,
                           pg_temp.v('sess'), pg_temp.u('e2'), pg_temp.u('c1'), pg_temp.k('06'), pg_temp.u('a2')))
         = '42501:kiosk-event', 'K8: another event under the kiosk flag';
  PERFORM set_config('exos.pos_kiosk_session', '', true);
  PERFORM set_config('exos.pos_walkup', '', true);
  -- A pending kiosk order completed by cash: refused.
  v_o := (public._exos_pos_kiosk_begin(pg_temp.v('tok'), pg_temp.u('d2'), 1, pg_temp.k('07'),
          jsonb_build_object('order', jsonb_build_object(pg_temp.v('q_zip'), '86001')), false) ->> 'id')::uuid;
  ASSERT pg_temp.st(format($q$SELECT public._exos_pos_walkup_complete(%L, %L, 'cash', NULL, NULL)$q$, pg_temp.u('a2'), v_o))
         = '0A000:kiosk-card-only', 'K8: a kiosk order completed by cash';
  ASSERT pg_temp.st(format($q$SELECT public._exos_pos_walkup_complete(%L, %L, 'comp', NULL, NULL)$q$, pg_temp.u('a2'), v_o))
         = '0A000:kiosk-card-only', 'K8: ... or a comp';
  INSERT INTO tk VALUES ('o_pending', v_o::text);
END $$;
-- A client insert (door staff, RLS) claiming the kiosk channel: stamped 'door'.
SET ROLE authenticated;
SELECT pg_temp.act(pg_temp.u('a3'));
INSERT INTO public.exos_pos_orders (event_id, client_ref, channel, kiosk_session_id)
VALUES ('c0b10000-0000-0000-0000-0000000000e1', 'c0b10000-0000-0000-0000-00000000c008', 'kiosk',
        (SELECT v FROM tk WHERE k = 'sess')::uuid);
RESET ROLE;
DO $$
BEGIN
  ASSERT (SELECT channel = 'door' AND kiosk_session_id IS NULL FROM public.exos_pos_orders WHERE client_ref = pg_temp.k('08')),
    'K8: a client can''t claim the kiosk channel';
  RAISE NOTICE 'OK K8 card only: no door sale on a kiosk device, no comps, no cash completion, no forged channel';
END $$;

-- ── K9 ──────────────────────────────────────────────────────────────────────
DO $$
DECLARE r jsonb;
BEGIN
  PERFORM pg_temp.act(NULL);
  -- The same key in the same session: the same sale.
  r := public._exos_pos_kiosk_begin(pg_temp.v('tok'), pg_temp.u('d2'), 1, pg_temp.k('07'),
         jsonb_build_object('order', jsonb_build_object(pg_temp.v('q_zip'), '86001')), false);
  ASSERT r ->> 'id' = pg_temp.v('o_pending') AND (r ->> 'replay')::boolean, 'K9: replay ' || r::text;
  -- Another kiosk session with that key: refused, nothing said about the sale.
  ASSERT pg_temp.st(format('SELECT public._exos_pos_kiosk_begin(%L, %L, 1, %L, %L::jsonb, false)', pg_temp.v('tok2'), pg_temp.u('d2'),
                           pg_temp.k('07'), jsonb_build_object('order', jsonb_build_object(pg_temp.v('q_zip'), '1')))) = '23505',
    'K9: another kiosk can''t reuse the key';
  -- A door sale's key: refused at the kiosk.
  ASSERT pg_temp.st(format('SELECT public._exos_pos_kiosk_begin(%L, %L, 1, %L, %L::jsonb, false)', pg_temp.v('tok'), pg_temp.u('d2'),
                           pg_temp.k('08'), jsonb_build_object('order', jsonb_build_object(pg_temp.v('q_zip'), '1')))) = '23505',
    'K9: a door order''s key';
  -- Another session can't charge, poll or hand over this one's orders.
  ASSERT pg_temp.st(format('SELECT public._exos_pos_kiosk_charge(%L, %L, false)', pg_temp.v('tok2'), pg_temp.v('o_pending'))) = 'P0002',
    'K9: charge another kiosk''s order';
  ASSERT pg_temp.st(format('SELECT public._exos_pos_kiosk_lookup(%L, %L)', pg_temp.v('tok2'), pg_temp.v('o1'))) = 'P0002',
    'K9: poll another kiosk''s order';
  ASSERT pg_temp.st(format('SELECT public._exos_pos_kiosk_codes(%L, %L)', pg_temp.v('tok2'), pg_temp.v('o1'))) = 'P0002',
    'K9: codes of another kiosk''s order';
  ASSERT pg_temp.st(format('SELECT public._exos_pos_kiosk_lookup(%L, %L)', pg_temp.v('tok'),
                           (SELECT id FROM public.exos_pos_orders WHERE client_ref = pg_temp.k('08')))) = 'P0002', 'K9: a door order';
  RAISE NOTICE 'OK K9 order keys: replay in its own session; another kiosk or the door can''t reuse or reach it';
END $$;

-- ── K10 ─────────────────────────────────────────────────────────────────────
DO $$
DECLARE r jsonb; v_mail int;
BEGIN
  PERFORM pg_temp.act(NULL);
  ASSERT pg_temp.st(format('SELECT public._exos_pos_kiosk_codes(%L, %L)', pg_temp.v('tok'), pg_temp.v('o_pending'))) = '55000',
    'K10: a pending sale has no codes';
  r := public._exos_pos_kiosk_codes(pg_temp.v('tok'), pg_temp.v('o1')::uuid);
  ASSERT jsonb_array_length(r -> 'tickets') = 2 AND (r -> 'tickets' -> 0 ->> 'print_code') LIKE 'P-%', 'K10: two QR codes ' || r::text;
  ASSERT (SELECT count(*) FROM public.exos_ticket_print_codes c JOIN public.exos_tickets t ON t.id = c.ticket_id
           WHERE t.order_ref = 'pos:' || pg_temp.v('o1') AND c.printed_via = 'pos' AND c.voided_at IS NULL) = 2, 'K10: print codes';
  v_mail := (SELECT count(*) FROM public.exos_mail WHERE to_email = 'fan.c0b1@example.com');
  r := public._exos_pos_kiosk_email(pg_temp.v('tok'), pg_temp.v('o1')::uuid, 'Fan.C0B1@example.com');
  ASSERT (r ->> 'emailed')::int = 2 AND (SELECT count(*) FROM public.exos_mail WHERE to_email = 'fan.c0b1@example.com') = v_mail + 1
     AND (SELECT status FROM public.exos_mail WHERE to_email = 'fan.c0b1@example.com' ORDER BY created_at DESC LIMIT 1) = 'pending',
    'K10: email queued ' || r::text;
  ASSERT pg_temp.st(format('SELECT public._exos_pos_kiosk_email(%L, %L, %L)', pg_temp.v('tok'), pg_temp.v('o1'), 'x@example.com'))
         = '55000:handed-over', 'K10: a second address gets nothing (already in a claim link)';
  -- Ten minutes later: no hand-over at the kiosk.
  UPDATE public.exos_pos_orders SET paid_at = now() - interval '11 minutes' WHERE id = pg_temp.v('o1')::uuid;
  ASSERT pg_temp.st(format('SELECT public._exos_pos_kiosk_codes(%L, %L)', pg_temp.v('tok'), pg_temp.v('o1'))) = '55000:kiosk-too-late',
    'K10: too late for codes';
  ASSERT pg_temp.st(format('SELECT public._exos_pos_kiosk_email(%L, %L, %L)', pg_temp.v('tok'), pg_temp.v('o1'), 'y@example.com'))
         = '55000:kiosk-too-late', 'K10: too late for email';
  RAISE NOTICE 'OK K10 hand-over: QR codes and queued email for the session''s own paid sale, 10 minutes';
END $$;

-- ── K11 ─────────────────────────────────────────────────────────────────────
DO $$
DECLARE r jsonb; i int;
BEGIN
  PERFORM pg_temp.act(NULL);
  r := public._exos_pos_kiosk_exit(pg_temp.v('tok'), '000001');
  ASSERT r ->> 'error' = 'wrong-pin' AND (r ->> 'attempts_left')::int = 4, 'K11: wrong PIN ' || r::text;
  ASSERT (SELECT pin_failures FROM public.exos_pos_kiosks WHERE device_id = pg_temp.u('c1')) = 1, 'K11: the count sticks';
  ASSERT (SELECT ended_at IS NULL FROM public.exos_pos_kiosk_sessions WHERE id = pg_temp.v('sess')::uuid), 'K11: still a kiosk';
  FOR i IN 1..3 LOOP
    PERFORM public._exos_pos_kiosk_exit(pg_temp.v('tok'), 'garbage');
  END LOOP;
  r := public._exos_pos_kiosk_exit(pg_temp.v('tok'), '999999');
  ASSERT r ->> 'error' = 'locked' AND (r ->> 'retry_after_seconds')::int = 300, 'K11: 5 wrong: locked ' || r::text;
  ASSERT EXISTS (SELECT 1 FROM public.exos_org_audit WHERE org_id = pg_temp.u('01') AND action = 'pos.kiosk_lockout'
                  AND entity_id = pg_temp.u('c1')::text), 'K11: lockout audited';
  -- Locked: even the right PIN waits.
  r := public._exos_pos_kiosk_exit(pg_temp.v('tok'), '482913');
  ASSERT r ->> 'error' = 'locked' AND (SELECT ended_at IS NULL FROM public.exos_pos_kiosk_sessions WHERE id = pg_temp.v('sess')::uuid),
    'K11: locked out ' || r::text;
  UPDATE public.exos_pos_kiosks SET pin_locked_until = now() - interval '1 second' WHERE device_id = pg_temp.u('c1');
  r := public._exos_pos_kiosk_exit(pg_temp.v('tok'), '482913');
  ASSERT (r ->> 'ok')::boolean AND r ->> 'ended' IS NULL AND (r ->> 'actor')::uuid = pg_temp.u('a2')
     AND r -> 'pending' = jsonb_build_array(pg_temp.v('o_pending')), 'K11: the right PIN, the pending sale to cancel ' || r::text;
  ASSERT (SELECT ended_reason = 'pin' FROM public.exos_pos_kiosk_sessions WHERE id = pg_temp.v('sess')::uuid), 'K11: ended by PIN';
  ASSERT EXISTS (SELECT 1 FROM public.exos_org_audit WHERE org_id = pg_temp.u('01') AND action = 'pos.kiosk_exit'
                  AND entity_id = pg_temp.u('c1')::text AND changes ->> 'via' = 'pin' AND source = 'pos'), 'K11: exit audited';
  ASSERT pg_temp.st(format('SELECT public._exos_pos_kiosk_state(%L, false)', pg_temp.v('tok'))) = '42501:kiosk-ended', 'K11: dead';
  ASSERT (public._exos_pos_kiosk_exit(pg_temp.v('tok'), NULL) ->> 'ended')::boolean, 'K11: nothing left to leave';
  RAISE NOTICE 'OK K11 PIN exit: wrong ones count, 5 lock for 5 minutes (audited), the right one ends it (audited)';
END $$;

-- ── K12 ─────────────────────────────────────────────────────────────────────
DO $$
BEGIN
  PERFORM pg_temp.act(pg_temp.u('b9'));
  ASSERT pg_temp.st(format('SELECT public.exos_pos_kiosk_configure(%L, %L, NULL, %L)', pg_temp.u('c1'), pg_temp.u('e9'), '482913')) = 'P0002',
    'K12: another org''s device';
  ASSERT pg_temp.st(format('SELECT public.exos_pos_kiosk_enter(%L)', pg_temp.u('c2'))) = 'P0002', 'K12: another org''s kiosk';
  ASSERT pg_temp.st(format('SELECT public.exos_pos_kiosk_end(%L)', pg_temp.u('c2'))) = 'P0002', 'K12: end another org''s kiosk';
  ASSERT pg_temp.st(format('SELECT public.exos_pos_kiosk_configure(%L, %L, NULL, %L)', pg_temp.u('cb'), pg_temp.u('e1'), '482913')) = 'P0002',
    'K12: another org''s event';
  ASSERT pg_temp.st(format('SELECT public.exos_pos_kiosk_configure(%L, %L, %L, %L)', pg_temp.u('cb'), pg_temp.u('e9'),
                           pg_temp.v('reader'), '482913')) = '22023:no-reader', 'K12: another org''s reader';
  PERFORM public.exos_pos_kiosk_configure(pg_temp.u('cb'), pg_temp.u('e9'), pg_temp.v('b_reader')::uuid, '615283', false);
  INSERT INTO tk VALUES ('tokb', public.exos_pos_kiosk_enter(pg_temp.u('cb')) ->> 'token');
  PERFORM pg_temp.act(NULL);
  ASSERT pg_temp.st(format('SELECT public._exos_pos_kiosk_begin(%L, %L, 1, %L, NULL, false)', pg_temp.v('tokb'), pg_temp.u('d1'),
                           pg_temp.k('09'))) = 'P0002', 'K12: org B''s kiosk can''t sell org A''s type';
  ASSERT pg_temp.st(format('SELECT public._exos_pos_kiosk_lookup(%L, %L)', pg_temp.v('tokb'), pg_temp.v('o_pending'))) = 'P0002',
    'K12: nor reach org A''s order';
END $$;
SET ROLE authenticated;
SELECT pg_temp.act(pg_temp.u('b9'));
DO $$
BEGIN
  ASSERT (SELECT count(*) FROM public.exos_pos_kiosks) = 1 AND (SELECT count(*) FROM public.exos_pos_kiosk_sessions) = 1,
    'K12: org B reads its own kiosk only';
END $$;
SELECT pg_temp.act(pg_temp.u('a3'));
DO $$
BEGIN
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_pos_kiosks) AND NOT EXISTS (SELECT 1 FROM public.exos_pos_kiosk_sessions),
    'K12: a scanner reads no kiosk setup';
END $$;
SELECT pg_temp.act(pg_temp.u('a2'));
DO $$
BEGIN
  ASSERT (SELECT count(*) FROM public.exos_pos_kiosks WHERE org_id = 'c0b10000-0000-0000-0000-000000000001') = 2
     AND (SELECT count(*) FROM public.exos_pos_kiosks WHERE org_id <> 'c0b10000-0000-0000-0000-000000000001') = 0,
    'K12: a manager reads the org''s kiosks only';
  ASSERT (SELECT count(*) FROM public.exos_pos_kiosk_sessions WHERE org_id = 'c0b10000-0000-0000-0000-000000000001') = 3,
    'K12: a manager reads the org''s sessions';
END $$;
RESET ROLE;
DO $$ BEGIN RAISE NOTICE 'OK K12 cross-org: another org''s device, event, reader, kiosk, orders; RLS reads per org, owner / manager only'; END $$;

-- ── K13 ─────────────────────────────────────────────────────────────────────
DO $$
DECLARE r jsonb;
BEGIN
  -- Ended from the dashboard (the setup stays).
  PERFORM pg_temp.act(pg_temp.u('a1'));
  r := public.exos_pos_kiosk_end(pg_temp.u('c2'));
  ASSERT (r ->> 'ended')::boolean AND EXISTS (SELECT 1 FROM public.exos_pos_kiosks WHERE device_id = pg_temp.u('c2')), 'K13: ended, kept';
  ASSERT EXISTS (SELECT 1 FROM public.exos_org_audit WHERE action = 'pos.kiosk_exit' AND entity_id = pg_temp.u('c2')::text
                  AND changes ->> 'via' = 'staff' AND actor_uid = pg_temp.u('a1')), 'K13: audited (staff)';
  PERFORM pg_temp.act(NULL);
  ASSERT pg_temp.st(format('SELECT public._exos_pos_kiosk_resolve(%L)', pg_temp.v('tok2'))) = '42501:kiosk-ended', 'K13: dead';
  -- Moved to another event: the live session ends.
  PERFORM pg_temp.act(pg_temp.u('a1'));
  INSERT INTO tk VALUES ('tok3', public.exos_pos_kiosk_enter(pg_temp.u('c2')) ->> 'token');
  r := public.exos_pos_kiosk_configure(pg_temp.u('c2'), pg_temp.u('e2'), NULL, NULL, false);
  ASSERT (r ->> 'sessions_ended')::int = 1, 'K13: moved ' || r::text;
  PERFORM pg_temp.act(NULL);
  ASSERT pg_temp.st(format('SELECT public._exos_pos_kiosk_resolve(%L)', pg_temp.v('tok3'))) = '42501:kiosk-ended', 'K13: moved: dead';
  -- No reader on the kiosk: charging is refused before any card call.
  PERFORM pg_temp.act(pg_temp.u('a1'));
  INSERT INTO tk VALUES ('tok4', public.exos_pos_kiosk_enter(pg_temp.u('c2')) ->> 'token');
  PERFORM pg_temp.act(NULL);
  ASSERT NOT (public._exos_pos_kiosk_state(pg_temp.v('tok4'), false) -> 'reader' ->> 'ready')::boolean, 'K13: no reader: not ready';
  r := public._exos_pos_kiosk_begin(pg_temp.v('tok4'), pg_temp.u('d6'), 1, pg_temp.k('10'), NULL, false);
  ASSERT pg_temp.st(format('SELECT public._exos_pos_kiosk_charge(%L, %L, false)', pg_temp.v('tok4'), r ->> 'id')) = '55000:no-reader',
    'K13: no reader, no charge';
  -- Turned off: sessions end, the flag goes, audited.
  PERFORM pg_temp.act(pg_temp.u('a1'));
  r := public.exos_pos_kiosk_configure(pg_temp.u('c2'), NULL);
  ASSERT NOT (r ->> 'kiosk')::boolean AND NOT EXISTS (SELECT 1 FROM public.exos_pos_kiosks WHERE device_id = pg_temp.u('c2')), 'K13: off';
  ASSERT EXISTS (SELECT 1 FROM public.exos_org_audit WHERE action = 'pos.kiosk_off' AND entity_id = pg_temp.u('c2')::text), 'K13: off audited';
  PERFORM pg_temp.act(NULL);
  ASSERT pg_temp.st(format('SELECT public._exos_pos_kiosk_resolve(%L)', pg_temp.v('tok4'))) = '42501:kiosk-ended', 'K13: off: dead';
  -- The device sells at the door again once it's no kiosk.
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_pos_kiosks WHERE device_id = pg_temp.u('c2')), 'K13: a plain device again';
  RAISE NOTICE 'OK K13 ended from the dashboard (audited), by a move to another event, and by turning it off (audited)';
END $$;


-- ── K14 ─────────────────────────────────────────────────────────────────────
DO $$
DECLARE q jsonb; r jsonb; v_o uuid;
BEGIN
  PERFORM pg_temp.act(pg_temp.u('a1'));
  q := public.exos_save_event_question(pg_temp.u('e1'), '{"label":"Wristband #","kind":"text","required":true,"scope":"order","hidden":true}');
  INSERT INTO tk VALUES ('q_band', q ->> 'id');
  PERFORM pg_temp.act(pg_temp.u('a2'));
  INSERT INTO tk VALUES ('tok5', public.exos_pos_kiosk_enter(pg_temp.u('c1')) ->> 'token');
  PERFORM pg_temp.act(NULL);
  r := public._exos_pos_kiosk_state(pg_temp.v('tok5'), false);
  ASSERT NOT EXISTS (SELECT 1 FROM jsonb_array_elements(r -> 'questions') x WHERE x ->> 'id' = pg_temp.v('q_band'))
     AND EXISTS (SELECT 1 FROM jsonb_array_elements(r -> 'questions') x WHERE x ->> 'id' = pg_temp.v('q_zip')),
    'K14: the hidden question is not on the kiosk screen ' || (r -> 'questions')::text;
  ASSERT pg_temp.st(format('SELECT public._exos_pos_kiosk_begin(%L, %L, 1, %L, %L::jsonb, false)', pg_temp.v('tok5'), pg_temp.u('d1'),
                           pg_temp.k('11'), jsonb_build_object('order', jsonb_build_object(pg_temp.v('q_zip'), '86001', pg_temp.v('q_band'), 'W-77'))))
         = '22023:kiosk-answers', 'K14: an answer to a hidden question is refused';
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_question_answers WHERE question_id = pg_temp.v('q_band')::uuid), 'K14: no hidden answer kept';
  ASSERT pg_temp.st(format('SELECT public._exos_pos_kiosk_begin(%L, %L, 1, %L, %L::jsonb, false)', pg_temp.v('tok5'), pg_temp.u('d1'),
                           pg_temp.k('11'), jsonb_build_object('order', jsonb_build_object('c0b10000-0000-0000-0000-0000000000ff', 'x'))))
         = '22023:kiosk-answers', 'K14: an answer to a question nobody asked';
  -- The visible required one answered: sold; the hidden required one isn't asked here.
  r := public._exos_pos_kiosk_begin(pg_temp.v('tok5'), pg_temp.u('d1'), 1, pg_temp.k('11'),
         jsonb_build_object('order', jsonb_build_object(pg_temp.v('q_zip'), '86001')), false);
  INSERT INTO tk VALUES ('oA', r ->> 'id');
  ASSERT r ->> 'status' = 'pending', 'K14: begun ' || r::text;
  RAISE NOTICE 'OK K14 hidden questions: not shown, an answer to one refused, not required at the kiosk';
END $$;

-- ── K15 ─────────────────────────────────────────────────────────────────────
DO $$
DECLARE r jsonb; n int := 0; v_st text; v_ans jsonb;
BEGIN
  PERFORM pg_temp.act(NULL);
  v_ans := jsonb_build_object('order', jsonb_build_object(pg_temp.v('q_zip'), '86001'));
  ASSERT pg_temp.st(format('SELECT public._exos_pos_kiosk_begin(%L, %L, 1, %L, %L::jsonb, false)', pg_temp.v('tok5'), pg_temp.u('d1'),
                           pg_temp.k('12'), v_ans)) = '55000:kiosk-busy', 'K15: a second open sale is refused';
  -- The first one's hold lapses: the next begin releases it.
  UPDATE public.exos_cart_holds SET expires_at = now() - interval '1 second' WHERE pos_order_id = pg_temp.v('oA')::uuid;
  r := public._exos_pos_kiosk_begin(pg_temp.v('tok5'), pg_temp.u('d1'), 1, pg_temp.k('12'), v_ans, false);
  INSERT INTO tk VALUES ('oB', r ->> 'id');
  ASSERT (SELECT status = 'void' FROM public.exos_pos_orders WHERE id = pg_temp.v('oA')::uuid)
     AND (SELECT status = 'canceled' FROM public.exos_pos_card_payments WHERE order_id = pg_temp.v('oA')::uuid)
     AND (SELECT count(*) FROM public.exos_pos_orders WHERE kiosk_session_id = (SELECT id FROM public.exos_pos_kiosk_sessions
            WHERE token_hash = encode(extensions.digest(pg_temp.v('tok5'), 'sha256'), 'hex')) AND status = 'open') = 1,
    'K15: the lapsed sale released, one open sale';
  -- 6 begins a minute per session (replays count): 2 so far.
  LOOP
    v_st := pg_temp.st(format('SELECT public._exos_pos_kiosk_begin(%L, %L, 1, %L, %L::jsonb, false)', pg_temp.v('tok5'), pg_temp.u('d1'),
                              pg_temp.k('12'), v_ans));
    EXIT WHEN v_st <> 'ok' OR n > 10;
    n := n + 1;
  END LOOP;
  ASSERT v_st = '54000' AND n = 4, format('K15: 6 begins a minute, then 54000 (%s more, then %s)', n, v_st);
  RAISE NOTICE 'OK K15 one open sale per session (busy, released once lapsed), 6 begins a minute';
END $$;

-- ── K16 ─────────────────────────────────────────────────────────────────────
DO $$
DECLARE v_o uuid := pg_temp.v('oB')::uuid; v_cap timestamptz; v_sess text;
BEGIN
  PERFORM pg_temp.act(NULL);
  SELECT kiosk_session_id::text INTO v_sess FROM public.exos_pos_orders WHERE id = v_o;
  UPDATE public.exos_pos_orders SET created_at = now() - interval '8 minutes' WHERE id = v_o;
  v_cap := now() - interval '8 minutes' + interval '10 minutes';
  PERFORM public._exos_pos_kiosk_charge(pg_temp.v('tok5'), v_o, false);
  PERFORM public._exos_pos_kiosk_charge(pg_temp.v('tok5'), v_o, false);
  PERFORM public._exos_pos_kiosk_charge(pg_temp.v('tok5'), v_o, false);
  ASSERT (SELECT max(expires_at) FROM public.exos_cart_holds WHERE pos_order_id = v_o AND status = 'active') <= v_cap
     AND (SELECT hold_expires_at <= v_cap FROM public.exos_pos_orders WHERE id = v_o),
    'K16: three charges, the hold still ends 10 minutes after the begin';
  ASSERT (SELECT hits FROM public.exos_rate_windows WHERE bucket = 'pos:card:kiosk:' || v_sess AND window_start = date_trunc('minute', now())) = 3
     AND NOT EXISTS (SELECT 1 FROM public.exos_rate_windows WHERE bucket = 'pos:card:' || pg_temp.u('a2')),
    'K16: the card limit counts on the kiosk session, not on the manager who started it';
  UPDATE public.exos_pos_orders SET created_at = now() - interval '11 minutes' WHERE id = v_o;
  ASSERT pg_temp.st(format('SELECT public._exos_pos_kiosk_charge(%L, %L, false)', pg_temp.v('tok5'), v_o)) = '55000:expired',
    'K16: no charge 10 minutes after the begin';
  PERFORM public._exos_pos_card_fail(v_o, NULL, 'canceled', NULL, 'door', 'test');
  RAISE NOTICE 'OK K16 a charge never holds past 10 minutes from the begin; card limit per kiosk session';
END $$;

-- ── K17 ─────────────────────────────────────────────────────────────────────
DO $$
DECLARE v_c uuid; v_d uuid; v_ans jsonb; k text; v_o uuid;
BEGIN
  PERFORM pg_temp.act(NULL);
  DELETE FROM public.exos_rate_windows WHERE bucket LIKE 'pos:kiosk:begin:%';
  v_ans := jsonb_build_object('order', jsonb_build_object(pg_temp.v('q_zip'), '86001'));
  FOREACH k IN ARRAY ARRAY['13', '14'] LOOP
    v_o := (public._exos_pos_kiosk_begin(pg_temp.v('tok5'), pg_temp.u('d2'), 1, pg_temp.k(k), v_ans, false) ->> 'id')::uuid;
    PERFORM public._exos_pos_kiosk_charge(pg_temp.v('tok5'), v_o, false);
    PERFORM public._exos_pos_card_attach(v_o, 'pi_K17s' || k, 500, 'usd', 50, 15, 35, 300);
    PERFORM public._exos_pos_card_capture_prepare(v_o, 'pi_K17s' || k);
    PERFORM public._exos_pos_card_complete(v_o, 'pi_K17s' || k, 500, 'door', NULL);
    IF k = '13' THEN v_c := v_o; ELSE v_d := v_o; END IF;
  END LOOP;
  UPDATE public.exos_pos_orders SET paid_at = now() - interval '1 minute' WHERE id = v_c;
  ASSERT pg_temp.st(format('SELECT public._exos_pos_kiosk_codes(%L, %L)', pg_temp.v('tok5'), v_c)) = '55000:kiosk-too-late',
    'K17: an earlier buyer''s sale can''t be called back';
  ASSERT pg_temp.st(format('SELECT public._exos_pos_kiosk_email(%L, %L, %L)', pg_temp.v('tok5'), v_c, 'z@example.com')) = '55000:kiosk-too-late',
    'K17: nor emailed';
  ASSERT jsonb_array_length(public._exos_pos_kiosk_codes(pg_temp.v('tok5'), v_d) -> 'tickets') = 1, 'K17: the latest sale''s QR';
  RAISE NOTICE 'OK K17 hand-over only for the session''s most recent paid sale';
END $$;

ROLLBACK;
