-- ============================================================================
-- Connect Eventbrite (OAuth; mig 20261029140000). Self-contained (eb0a
-- prefix), rolled back. Needs tests/exos/prereq_vault.sql, migs
-- 20260930102000 (OAuth states) and 20261013100000 (Eventbrite sync).
--   O1 objects and grants: Eventbrite is a state provider; the log table and
--      the new RPCs are service role only (org status: authenticated);
--      definer functions pin search_path
--   O2 begin: owner / manager only; the return event must be the org's;
--      10-minute expiry; the per-user start cap (shared with Google Ads)
--   O3 return + consume: only the starting user, once, before expiry, only an
--      Eventbrite state (and Google's consume no longer takes one); the code
--      is cleared; an error return burns the state
--   O4 store: OAuth token in the same Vault secret as a private token,
--      auth_method 'oauth', role re-checked, shape checked, writes stay off;
--      a private-token reconnect flips it back (same secret)
--   O5 status: auth_method on the door status; org status for door roles
--      (can_manage only owner / manager), outsiders refused, never the token
--   O6 disconnect: token gone, history kept; nothing logged when not connected
-- ============================================================================
\set ON_ERROR_STOP on
BEGIN;
INSERT INTO auth.users(id,email,email_confirmed_at) VALUES
  ('eb0a0000-0000-0000-0000-0000000000a1','eb0a-owner@x.com',now()),
  ('eb0a0000-0000-0000-0000-0000000000a2','eb0a-manager@x.com',now()),
  ('eb0a0000-0000-0000-0000-0000000000a3','eb0a-scanner@x.com',now()),
  ('eb0a0000-0000-0000-0000-0000000000a4','eb0a-finance@x.com',now()),
  ('eb0a0000-0000-0000-0000-0000000000a6','eb0a-other@x.com',now());
INSERT INTO public.exos_orgs(id,name,slug,owner_uid) VALUES
  ('eb0a0000-0000-0000-0000-000000000001','EB0A Org','eb0a-org','eb0a0000-0000-0000-0000-0000000000a1'),
  ('eb0a0000-0000-0000-0000-000000000002','EB0A Other','eb0a-other','eb0a0000-0000-0000-0000-0000000000a6');
INSERT INTO public.exos_org_memberships(org_id,user_id,role,disabled) VALUES
  ('eb0a0000-0000-0000-0000-000000000001','eb0a0000-0000-0000-0000-0000000000a1','owner',false),
  ('eb0a0000-0000-0000-0000-000000000001','eb0a0000-0000-0000-0000-0000000000a2','manager',false),
  ('eb0a0000-0000-0000-0000-000000000001','eb0a0000-0000-0000-0000-0000000000a3','scanner',false),
  ('eb0a0000-0000-0000-0000-000000000001','eb0a0000-0000-0000-0000-0000000000a4','finance',false),
  ('eb0a0000-0000-0000-0000-000000000002','eb0a0000-0000-0000-0000-0000000000a6','owner',false);
INSERT INTO public.exos_events(id,org_id,name,slug,status,starts_at,doors_at,total_tickets,created_by) VALUES
  ('eb0a0000-0000-0000-0000-0000000000e1','eb0a0000-0000-0000-0000-000000000001','EB0A Night','eb0a-night','draft',
   now() + interval '3 days', now() + interval '3 days', 0, 'eb0a0000-0000-0000-0000-0000000000a1'),
  ('eb0a0000-0000-0000-0000-0000000000e9','eb0a0000-0000-0000-0000-000000000002','EB0A Theirs','eb0a-theirs','draft',
   now() + interval '3 days', now() + interval '3 days', 0, 'eb0a0000-0000-0000-0000-0000000000a6');

CREATE FUNCTION pg_temp.act(p_uid text) RETURNS void LANGUAGE sql AS $$
  SELECT set_config('app.uid', coalesce(p_uid, ''), false), set_config('app.jwt', '{"email":"eb0a@x.com"}', false);
$$;
CREATE FUNCTION pg_temp.u(p text) RETURNS uuid LANGUAGE sql AS $$ SELECT ('eb0a0000-0000-0000-0000-0000000000' || p)::uuid $$;
CREATE FUNCTION pg_temp.org() RETURNS uuid LANGUAGE sql AS $$ SELECT 'eb0a0000-0000-0000-0000-000000000001'::uuid $$;
CREATE FUNCTION pg_temp.h(p text) RETURNS text LANGUAGE sql IMMUTABLE AS $$
  SELECT encode(sha256(convert_to('eb0a-state-' || p, 'UTF8')), 'hex')
$$;
CREATE FUNCTION pg_temp.sqlstate_of(p_sql text) RETURNS text LANGUAGE plpgsql AS $$
BEGIN
  EXECUTE p_sql;
  RETURN '';
EXCEPTION WHEN OTHERS THEN
  RETURN SQLSTATE;
END $$;
GRANT EXECUTE ON FUNCTION pg_temp.sqlstate_of(text) TO anon, authenticated, service_role;

-- O1 -------------------------------------------------------------------------
DO $$
DECLARE r text; f text;
BEGIN
  ASSERT pg_get_constraintdef((SELECT oid FROM pg_constraint WHERE conname = 'exos_oauth_states_provider_chk')) LIKE '%eventbrite%',
         'O1: eventbrite is not a provider';
  ASSERT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = 'exos_oauth_states' AND column_name = 'return_event_id'),
         'O1: return_event_id missing';
  ASSERT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = 'exos_eventbrite_accounts' AND column_name = 'auth_method'
                   AND column_default LIKE '%private_token%'), 'O1: auth_method missing';
  ASSERT (SELECT relrowsecurity FROM pg_class WHERE oid = 'public.exos_eventbrite_connection_log'::regclass), 'O1: log RLS off';
  FOREACH r IN ARRAY ARRAY['anon','authenticated'] LOOP
    ASSERT NOT has_table_privilege(r, 'public.exos_eventbrite_connection_log', 'SELECT,INSERT,UPDATE,DELETE'), 'O1: ' || r || ' touches the log';
    ASSERT NOT has_table_privilege(r, 'public.exos_oauth_states', 'SELECT,INSERT,UPDATE,DELETE'), 'O1: ' || r || ' touches states';
    FOREACH f IN ARRAY ARRAY[
      'public.exos_eventbrite_oauth_begin(uuid,uuid,text,uuid)',
      'public.exos_eventbrite_oauth_consume(text,uuid)',
      'public.exos_eventbrite_connect_oauth(uuid,uuid,text,text)',
      'public._exos_eventbrite_store(uuid,uuid,text,text,text)',
      'public.exos_eventbrite_connect(uuid,uuid,text,text)',
      'public.exos_eventbrite_disconnect(uuid,uuid)',
      'public.exos_oauth_state_begin(text,uuid,uuid,text,integer)',
      'public.exos_oauth_state_consume(text,uuid)'] LOOP
      ASSERT NOT has_function_privilege(r, f, 'EXECUTE'), 'O1: ' || r || ' runs ' || f;
      ASSERT has_function_privilege('service_role', f, 'EXECUTE'), 'O1: service role cannot run ' || f;
    END LOOP;
  END LOOP;
  ASSERT has_function_privilege('authenticated', 'public.exos_eventbrite_org_status(uuid)', 'EXECUTE'), 'O1: org status not callable';
  ASSERT NOT has_function_privilege('anon', 'public.exos_eventbrite_org_status(uuid)', 'EXECUTE'), 'O1: anon org status';
  SELECT string_agg(p.proname, ', ') INTO r FROM pg_proc p
   WHERE p.pronamespace = 'public'::regnamespace AND p.prosecdef
     AND p.proname IN ('exos_eventbrite_oauth_begin','exos_eventbrite_oauth_consume','exos_eventbrite_connect_oauth',
                       '_exos_eventbrite_store','exos_eventbrite_connect','exos_eventbrite_disconnect',
                       'exos_eventbrite_org_status','exos_eventbrite_status','exos_oauth_state_begin','exos_oauth_state_consume')
     AND NOT coalesce(array_to_string(p.proconfig, ',') LIKE '%search_path=public, pg_temp%', false);
  ASSERT r IS NULL, 'O1: search_path not pinned: ' || r;
  RAISE NOTICE 'OK  O1 Eventbrite OAuth objects are service role only';
END $$;

-- O2 -------------------------------------------------------------------------
DO $$
DECLARE v_exp timestamptz; s public.exos_oauth_states%ROWTYPE; i int;
BEGIN
  PERFORM pg_temp.act(NULL);
  v_exp := public.exos_eventbrite_oauth_begin(pg_temp.org(), pg_temp.u('a1'), pg_temp.h('one'), pg_temp.u('e1'));
  ASSERT v_exp BETWEEN now() + interval '9 minutes' AND now() + interval '10 minutes', 'O2: expiry ' || v_exp;
  SELECT * INTO s FROM public.exos_oauth_states WHERE state_hash = pg_temp.h('one');
  ASSERT s.provider = 'eventbrite' AND s.org_id = pg_temp.org() AND s.user_id = pg_temp.u('a1')
         AND s.return_event_id = pg_temp.u('e1') AND s.code IS NULL, 'O2: state row';
  -- The manager may start one with no event.
  PERFORM public.exos_eventbrite_oauth_begin(pg_temp.org(), pg_temp.u('a2'), pg_temp.h('mgr'), NULL);
  ASSERT (SELECT return_event_id FROM public.exos_oauth_states WHERE state_hash = pg_temp.h('mgr')) IS NULL, 'O2: no event';
  -- Not scanner, finance, or another org's owner.
  ASSERT pg_temp.sqlstate_of(format('SELECT public.exos_eventbrite_oauth_begin(%L, %L, %L, NULL)',
         pg_temp.org(), pg_temp.u('a3'), pg_temp.h('scan'))) = '42501', 'O2: scanner started';
  ASSERT pg_temp.sqlstate_of(format('SELECT public.exos_eventbrite_oauth_begin(%L, %L, %L, NULL)',
         pg_temp.org(), pg_temp.u('a4'), pg_temp.h('fin'))) = '42501', 'O2: finance started';
  ASSERT pg_temp.sqlstate_of(format('SELECT public.exos_eventbrite_oauth_begin(%L, %L, %L, NULL)',
         pg_temp.org(), pg_temp.u('a6'), pg_temp.h('out'))) = '42501', 'O2: outsider started';
  -- Another org's event as the return target.
  ASSERT pg_temp.sqlstate_of(format('SELECT public.exos_eventbrite_oauth_begin(%L, %L, %L, %L)',
         pg_temp.org(), pg_temp.u('a1'), pg_temp.h('theirs'), pg_temp.u('e9'))) = '22023', 'O2: foreign event';
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_oauth_states WHERE state_hash = pg_temp.h('theirs')), 'O2: foreign state kept';
  ASSERT pg_temp.sqlstate_of(format('SELECT public.exos_eventbrite_oauth_begin(%L, %L, %L, NULL)',
         pg_temp.org(), pg_temp.u('a1'), 'not-a-hash')) = '22023', 'O2: bad hash';
  -- Google Ads still starts.
  PERFORM public.exos_oauth_state_begin('google_ads', pg_temp.org(), pg_temp.u('a1'), pg_temp.h('g1'));
  -- The cap: 10 starts a user in 10 minutes, across providers (a1 has 2).
  FOR i IN 1..8 LOOP
    PERFORM public.exos_eventbrite_oauth_begin(pg_temp.org(), pg_temp.u('a1'), pg_temp.h('cap' || i), NULL);
  END LOOP;
  ASSERT pg_temp.sqlstate_of(format('SELECT public.exos_eventbrite_oauth_begin(%L, %L, %L, NULL)',
         pg_temp.org(), pg_temp.u('a1'), pg_temp.h('cap9'))) = '54000', 'O2: start cap';
  RAISE NOTICE 'OK  O2 begin: owner / manager, own event, expiry, rate limit';
END $$;

-- O3 -------------------------------------------------------------------------
DO $$
DECLARE v_org uuid; r record; n int;
BEGIN
  v_org := public.exos_oauth_state_return(pg_temp.h('one'), 'EBCODE123456');
  ASSERT v_org = pg_temp.org(), 'O3: return gave ' || coalesce(v_org::text, 'null');
  ASSERT public.exos_oauth_state_return(pg_temp.h('one'), 'EBCODE999999') IS NULL, 'O3: second return accepted';
  ASSERT (SELECT code FROM public.exos_oauth_states WHERE state_hash = pg_temp.h('one')) = 'EBCODE123456', 'O3: first code kept';
  -- Someone else (even the manager) can't use a1's state, and doesn't burn it.
  SELECT count(*) INTO n FROM public.exos_eventbrite_oauth_consume(pg_temp.h('one'), pg_temp.u('a2'));
  ASSERT n = 0, 'O3: another user consumed';
  -- Google's consume refuses an Eventbrite state, and doesn't burn it.
  SELECT count(*) INTO n FROM public.exos_oauth_state_consume(pg_temp.h('one'), pg_temp.u('a1'));
  ASSERT n = 0, 'O3: Google consumed an Eventbrite state';
  ASSERT (SELECT consumed_at FROM public.exos_oauth_states WHERE state_hash = pg_temp.h('one')) IS NULL, 'O3: burned by others';
  -- The starting user, once.
  SELECT * INTO r FROM public.exos_eventbrite_oauth_consume(pg_temp.h('one'), pg_temp.u('a1'));
  ASSERT r.org_id = pg_temp.org() AND r.code = 'EBCODE123456' AND r.return_event_id = pg_temp.u('e1'), 'O3: consume ' || r::text;
  ASSERT (SELECT code IS NULL AND consumed_at IS NOT NULL FROM public.exos_oauth_states WHERE state_hash = pg_temp.h('one')),
         'O3: code not cleared';
  SELECT count(*) INTO n FROM public.exos_eventbrite_oauth_consume(pg_temp.h('one'), pg_temp.u('a1'));
  ASSERT n = 0, 'O3: consumed twice';
  -- Eventbrite's consume refuses a Google state.
  PERFORM public.exos_oauth_state_return(pg_temp.h('g1'), 'GCODE1234567');
  SELECT count(*) INTO n FROM public.exos_eventbrite_oauth_consume(pg_temp.h('g1'), pg_temp.u('a1'));
  ASSERT n = 0, 'O3: Eventbrite consumed a Google state';
  SELECT count(*) INTO n FROM public.exos_oauth_state_consume(pg_temp.h('g1'), pg_temp.u('a1'));
  ASSERT n = 1, 'O3: Google consume broken';
  -- Expired.
  PERFORM public.exos_oauth_state_return(pg_temp.h('cap1'), 'EBCODEEXPIRE');
  UPDATE public.exos_oauth_states SET expires_at = now() - interval '1 second' WHERE state_hash = pg_temp.h('cap1');
  SELECT count(*) INTO n FROM public.exos_eventbrite_oauth_consume(pg_temp.h('cap1'), pg_temp.u('a1'));
  ASSERT n = 0, 'O3: expired consumed';
  ASSERT public.exos_oauth_state_return(pg_temp.h('cap1'), 'EBCODEEXPIRE') IS NULL, 'O3: expired returned';
  -- Declined on Eventbrite: no code, the state is burned.
  ASSERT public.exos_oauth_state_return(pg_temp.h('cap2'), NULL) = pg_temp.org(), 'O3: error return';
  SELECT count(*) INTO n FROM public.exos_eventbrite_oauth_consume(pg_temp.h('cap2'), pg_temp.u('a1'));
  ASSERT n = 0, 'O3: declined state consumed';
  -- A user no longer owner / manager can't finish.
  PERFORM public.exos_oauth_state_return(pg_temp.h('mgr'), 'EBCODEMGR123');
  UPDATE public.exos_org_memberships SET disabled = true WHERE user_id = pg_temp.u('a2');
  SELECT count(*) INTO n FROM public.exos_eventbrite_oauth_consume(pg_temp.h('mgr'), pg_temp.u('a2'));
  ASSERT n = 0, 'O3: disabled manager finished';
  UPDATE public.exos_org_memberships SET disabled = false WHERE user_id = pg_temp.u('a2');
  RAISE NOTICE 'OK  O3 return + consume: starting user, once, Eventbrite states only';
END $$;

-- O4 -------------------------------------------------------------------------
DO $$
DECLARE r jsonb; v_secret uuid; a public.exos_eventbrite_accounts%ROWTYPE;
BEGIN
  r := public.exos_eventbrite_connect_oauth(pg_temp.org(), pg_temp.u('a1'), 'OAUTHTOKEN0001', 'Blue Room');
  ASSERT r->>'connected' = 'true' AND r->>'account_name' = 'Blue Room' AND r->>'auth_method' = 'oauth', 'O4: ' || r::text;
  SELECT * INTO a FROM public.exos_eventbrite_accounts WHERE org_id = pg_temp.org();
  ASSERT a.auth_method = 'oauth' AND a.writes_enabled = false AND a.connected_by = pg_temp.u('a1'), 'O4: account row';
  ASSERT (SELECT decrypted_secret FROM vault.decrypted_secrets WHERE id = a.secret_id
           AND name = 'exos_eventbrite:' || pg_temp.org()) = 'OAUTHTOKEN0001', 'O4: token not in the org''s Vault secret';
  -- The sync reads it the same way it reads a private token.
  ASSERT public.exos_eventbrite_token(pg_temp.org(), pg_temp.u('a2')) = 'OAUTHTOKEN0001', 'O4: token read back';
  v_secret := a.secret_id;
  ASSERT pg_temp.sqlstate_of(format('SELECT public.exos_eventbrite_connect_oauth(%L, %L, %L, %L)',
         pg_temp.org(), pg_temp.u('a3'), 'OAUTHTOKEN0002', 'x')) = '42501', 'O4: scanner stored';
  ASSERT pg_temp.sqlstate_of(format('SELECT public.exos_eventbrite_connect_oauth(%L, %L, %L, %L)',
         pg_temp.org(), pg_temp.u('a6'), 'OAUTHTOKEN0002', 'x')) = '42501', 'O4: outsider stored';
  ASSERT pg_temp.sqlstate_of(format('SELECT public.exos_eventbrite_connect_oauth(%L, %L, %L, %L)',
         pg_temp.org(), pg_temp.u('a1'), 'bad token!', 'x')) = '22023', 'O4: bad token stored';
  ASSERT pg_temp.sqlstate_of(format('SELECT public._exos_eventbrite_store(%L, %L, %L, %L, %L)',
         pg_temp.org(), pg_temp.u('a1'), 'OAUTHTOKEN0002', 'x', 'magic')) = '22023', 'O4: bad method';
  -- The org's write switch survives a reconnect; a new account starts off.
  UPDATE public.exos_eventbrite_accounts SET writes_enabled = true WHERE org_id = pg_temp.org();
  r := public.exos_eventbrite_connect(pg_temp.org(), pg_temp.u('a2'), 'PRIVATETOKEN01', 'Blue Room');
  SELECT * INTO a FROM public.exos_eventbrite_accounts WHERE org_id = pg_temp.org();
  ASSERT r->>'auth_method' = 'private_token' AND a.auth_method = 'private_token' AND a.secret_id = v_secret
         AND a.writes_enabled = true, 'O4: private reconnect ' || r::text;
  ASSERT (SELECT count(*) FROM vault.secrets WHERE name = 'exos_eventbrite:' || pg_temp.org()) = 1, 'O4: one secret';
  r := public.exos_eventbrite_connect_oauth(pg_temp.org(), pg_temp.u('a1'), 'OAUTHTOKEN0003', 'Blue Room');
  ASSERT public.exos_eventbrite_token(pg_temp.org(), pg_temp.u('a1')) = 'OAUTHTOKEN0003', 'O4: reconnect token';
  ASSERT (SELECT array_agg(auth_method ORDER BY id) FROM public.exos_eventbrite_connection_log WHERE org_id = pg_temp.org())
         = ARRAY['oauth','private_token','oauth'], 'O4: log';
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_eventbrite_connection_log l
                      WHERE to_jsonb(l)::text LIKE '%TOKEN%'), 'O4: token in the log';
  RAISE NOTICE 'OK  O4 OAuth token stored like the private token';
END $$;

-- O5 -------------------------------------------------------------------------
DO $$
DECLARE r jsonb;
BEGIN
  PERFORM pg_temp.act('eb0a0000-0000-0000-0000-0000000000a3');
  r := public.exos_eventbrite_status(pg_temp.u('e1'));
  ASSERT r->>'auth_method' = 'oauth' AND r->>'connected' = 'true' AND r->>'can_manage' = 'false', 'O5: door status ' || r::text;
  r := public.exos_eventbrite_org_status(pg_temp.org());
  ASSERT r->>'connected' = 'true' AND r->>'auth_method' = 'oauth' AND r->>'can_manage' = 'false'
         AND r->>'account_name' = 'Blue Room' AND jsonb_array_length(r->'history') = 3
         AND (r->'history'->0->>'by_you')::boolean = false, 'O5: scanner org status ' || r::text;
  ASSERT position('TOKEN' in r::text) = 0 AND position('eb0a0000' in (r->'history')::text) = 0, 'O5: leaked ' || r::text;
  PERFORM pg_temp.act('eb0a0000-0000-0000-0000-0000000000a1');
  r := public.exos_eventbrite_org_status(pg_temp.org());
  ASSERT r->>'can_manage' = 'true' AND (r->'history'->0->>'by_you')::boolean
         AND r->'history'->0->>'auth_method' = 'oauth', 'O5: owner org status ' || r::text;
  PERFORM pg_temp.act('eb0a0000-0000-0000-0000-0000000000a6');
  ASSERT pg_temp.sqlstate_of(format('SELECT public.exos_eventbrite_org_status(%L)', pg_temp.org())) = '42501', 'O5: outsider read';
  PERFORM pg_temp.act('eb0a0000-0000-0000-0000-0000000000a4');
  ASSERT pg_temp.sqlstate_of(format('SELECT public.exos_eventbrite_org_status(%L)', pg_temp.org())) = '42501', 'O5: finance read';
  PERFORM pg_temp.act(NULL);
  ASSERT pg_temp.sqlstate_of(format('SELECT public.exos_eventbrite_org_status(%L)', pg_temp.org())) = '42501', 'O5: no user read';
  RAISE NOTICE 'OK  O5 status shows how it is connected, never the token';
END $$;

-- The client roles can't reach the RPCs or tables directly either.
SET LOCAL ROLE authenticated;
SELECT set_config('app.uid', 'eb0a0000-0000-0000-0000-0000000000a1', false);
DO $$
BEGIN
  ASSERT pg_temp.sqlstate_of(format('SELECT public.exos_eventbrite_connect_oauth(%L, %L, %L, %L)',
         'eb0a0000-0000-0000-0000-000000000001', 'eb0a0000-0000-0000-0000-0000000000a1', 'OAUTHTOKEN0009', 'x')) = '42501',
         'O5: authenticated stored a token';
  ASSERT pg_temp.sqlstate_of('SELECT * FROM public.exos_eventbrite_connection_log') = '42501', 'O5: authenticated read the log';
  ASSERT (public.exos_eventbrite_org_status('eb0a0000-0000-0000-0000-000000000001'))->>'connected' = 'true', 'O5: owner via RPC';
END $$;
RESET ROLE;

-- O6 -------------------------------------------------------------------------
DO $$
DECLARE r jsonb;
BEGIN
  PERFORM pg_temp.act(NULL);
  ASSERT pg_temp.sqlstate_of(format('SELECT public.exos_eventbrite_disconnect(%L, %L)',
         pg_temp.org(), pg_temp.u('a3'))) = '42501', 'O6: scanner disconnected';
  r := public.exos_eventbrite_disconnect(pg_temp.org(), pg_temp.u('a2'));
  ASSERT r->>'connected' = 'false' AND r->>'auth_method' = 'oauth', 'O6: ' || r::text;
  ASSERT NOT EXISTS (SELECT 1 FROM vault.secrets WHERE name = 'exos_eventbrite:' || pg_temp.org()), 'O6: secret kept';
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_eventbrite_accounts WHERE org_id = pg_temp.org()), 'O6: account kept';
  ASSERT public.exos_eventbrite_token(pg_temp.org(), pg_temp.u('a1')) IS NULL, 'O6: token readable';
  ASSERT (SELECT action || '/' || auth_method FROM public.exos_eventbrite_connection_log
           WHERE org_id = pg_temp.org() ORDER BY id DESC LIMIT 1) = 'disconnect/oauth', 'O6: no history row';
  -- Not connected: nothing to log.
  PERFORM public.exos_eventbrite_disconnect(pg_temp.org(), pg_temp.u('a1'));
  ASSERT (SELECT count(*) FROM public.exos_eventbrite_connection_log WHERE org_id = pg_temp.org()) = 4, 'O6: logged a no-op';
  PERFORM pg_temp.act('eb0a0000-0000-0000-0000-0000000000a1');
  r := public.exos_eventbrite_org_status(pg_temp.org());
  ASSERT r->>'connected' = 'false' AND r->>'auth_method' IS NULL AND jsonb_array_length(r->'history') = 4
         AND r->'history'->0->>'action' = 'disconnect', 'O6: org status ' || r::text;
  RAISE NOTICE 'OK  O6 disconnect: token deleted locally, history kept';
END $$;

\echo 'test_eventbrite_oauth: all passed'
ROLLBACK;
