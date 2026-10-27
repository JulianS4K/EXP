-- ============================================================================
-- Partner API scopes (mig 20261027090000). Self-contained (a5 prefix), rolled back.
--   S1 vocabulary: 15 scopes, the same list as _shared/api/scopes.ts
--   S2 create with scopes: cleaned (deduped, vocabulary order); unknown and
--      empty lists refused
--   S3 the old (org, name) form still makes a `read` key
--   S4 only owner / manager may create; scanner and strangers refused
--   S5 at most 10 active keys per org; a revoked key frees a slot
--   S6 set scopes: owner / manager of the key's org only; revoked keys and
--      unknown ids get the same refusal
--   S7 grants: nothing callable by anon; the cleaner is internal
-- ============================================================================
\set ON_ERROR_STOP on
BEGIN;
INSERT INTO auth.users(id,email,email_confirmed_at) VALUES
  ('a5000000-0000-0000-0000-0000000000a1','a5-owner@x.com',now()),
  ('a5000000-0000-0000-0000-0000000000a2','a5-scanner@x.com',now()),
  ('a5000000-0000-0000-0000-0000000000a3','a5-other@x.com',now());
INSERT INTO public.exos_orgs(id,name,slug,owner_uid) VALUES
  ('a5000000-0000-0000-0000-000000000001','A5 Org','a5-org','a5000000-0000-0000-0000-0000000000a1'),
  ('a5000000-0000-0000-0000-000000000002','A5 Other','a5-other','a5000000-0000-0000-0000-0000000000a3');
INSERT INTO public.exos_org_memberships(org_id,user_id,role) VALUES
  ('a5000000-0000-0000-0000-000000000001','a5000000-0000-0000-0000-0000000000a1','owner'),
  ('a5000000-0000-0000-0000-000000000001','a5000000-0000-0000-0000-0000000000a2','scanner'),
  ('a5000000-0000-0000-0000-000000000002','a5000000-0000-0000-0000-0000000000a3','owner');

DO $$
DECLARE
  v_org   uuid := 'a5000000-0000-0000-0000-000000000001';
  v_key   text;
  v_id    uuid;
  v_sc    text[];
  v_ok    boolean;
  i       int;
BEGIN
  -- S1
  IF cardinality(public.exos_api_scope_names()) <> 15
     OR (public.exos_api_scope_names())[1] <> 'events:read'
     OR (public.exos_api_scope_names())[15] <> 'org:admin' THEN
    RAISE EXCEPTION 'S1 FAIL: %', public.exos_api_scope_names();
  END IF;
  RAISE NOTICE 'S1 ok: 15 scopes';

  -- S2
  PERFORM set_config('app.uid', 'a5000000-0000-0000-0000-0000000000a1', true);
  v_key := public.exos_create_api_key(v_org, 'Box office', ARRAY['tickets:read','events:read','tickets:read']);
  IF v_key !~ '^sk_live_[0-9a-f]{48}$' THEN RAISE EXCEPTION 'S2 FAIL: key %', v_key; END IF;
  SELECT scopes INTO v_sc FROM public.exos_api_keys
   WHERE key_hash = encode(extensions.digest(v_key, 'sha256'), 'hex');
  IF v_sc <> ARRAY['events:read','tickets:read'] THEN RAISE EXCEPTION 'S2 FAIL: scopes %', v_sc; END IF;
  BEGIN
    PERFORM public.exos_create_api_key(v_org, 'x', ARRAY['events:read','admin:everything']);
    RAISE EXCEPTION 'S2 FAIL: unknown scope accepted';
  EXCEPTION WHEN invalid_parameter_value THEN NULL;
  END;
  BEGIN
    PERFORM public.exos_create_api_key(v_org, 'x', ARRAY[]::text[]);
    RAISE EXCEPTION 'S2 FAIL: empty scope list accepted';
  EXCEPTION WHEN invalid_parameter_value THEN NULL;
  END;
  BEGIN
    PERFORM public.exos_create_api_key(v_org, 'x', ARRAY[NULL]::text[]);
    RAISE EXCEPTION 'S2 FAIL: null scope accepted';
  EXCEPTION WHEN invalid_parameter_value THEN NULL;
  END;
  RAISE NOTICE 'S2 ok: scopes cleaned; unknown, empty and null refused';

  -- S3
  v_key := public.exos_create_api_key(v_org, 'Legacy');
  SELECT scopes INTO v_sc FROM public.exos_api_keys
   WHERE key_hash = encode(extensions.digest(v_key, 'sha256'), 'hex');
  IF v_sc <> ARRAY['read'] THEN RAISE EXCEPTION 'S3 FAIL: %', v_sc; END IF;
  v_key := public.exos_create_api_key(v_org);
  RAISE NOTICE 'S3 ok: old form makes a read key';

  -- S4
  PERFORM set_config('app.uid', 'a5000000-0000-0000-0000-0000000000a2', true);
  BEGIN
    PERFORM public.exos_create_api_key(v_org, 'x', ARRAY['events:read']);
    RAISE EXCEPTION 'S4 FAIL: scanner created a key';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  PERFORM set_config('app.uid', 'a5000000-0000-0000-0000-0000000000a3', true);
  BEGIN
    PERFORM public.exos_create_api_key(v_org, 'x', ARRAY['events:read']);
    RAISE EXCEPTION 'S4 FAIL: another org''s owner created a key';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  PERFORM set_config('app.uid', '', true);
  BEGIN
    PERFORM public.exos_create_api_key(v_org, 'x', ARRAY['events:read']);
    RAISE EXCEPTION 'S4 FAIL: signed-out caller created a key';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  RAISE NOTICE 'S4 ok: owner / manager only';

  -- S5: 3 active so far; 7 more reach the cap.
  PERFORM set_config('app.uid', 'a5000000-0000-0000-0000-0000000000a1', true);
  FOR i IN 1..7 LOOP
    PERFORM public.exos_create_api_key(v_org, 'k' || i, ARRAY['events:read']);
  END LOOP;
  BEGIN
    PERFORM public.exos_create_api_key(v_org, 'eleventh', ARRAY['events:read']);
    RAISE EXCEPTION 'S5 FAIL: eleventh active key created';
  EXCEPTION WHEN program_limit_exceeded THEN NULL;
  END;
  SELECT id INTO v_id FROM public.exos_api_keys WHERE org_id = v_org AND name = 'k1';
  PERFORM public.exos_revoke_api_key(v_id);
  PERFORM public.exos_create_api_key(v_org, 'after revoke', ARRAY['events:read']);
  RAISE NOTICE 'S5 ok: 10 active keys at most';

  -- S6
  SELECT id INTO v_id FROM public.exos_api_keys WHERE org_id = v_org AND name = 'Box office';
  v_sc := public.exos_set_api_key_scopes(v_id, ARRAY['orders:read','read']);
  IF v_sc <> ARRAY['read','orders:read']
     OR (SELECT scopes FROM public.exos_api_keys WHERE id = v_id) <> v_sc THEN
    RAISE EXCEPTION 'S6 FAIL: %', v_sc;
  END IF;
  PERFORM set_config('app.uid', 'a5000000-0000-0000-0000-0000000000a3', true);
  BEGIN
    PERFORM public.exos_set_api_key_scopes(v_id, ARRAY['org:admin']);
    RAISE EXCEPTION 'S6 FAIL: another org changed the scopes';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  PERFORM set_config('app.uid', 'a5000000-0000-0000-0000-0000000000a1', true);
  SELECT id INTO v_id FROM public.exos_api_keys WHERE org_id = v_org AND name = 'k1';
  BEGIN
    PERFORM public.exos_set_api_key_scopes(v_id, ARRAY['events:read']);
    RAISE EXCEPTION 'S6 FAIL: revoked key changed';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  BEGIN
    PERFORM public.exos_set_api_key_scopes(gen_random_uuid(), ARRAY['events:read']);
    RAISE EXCEPTION 'S6 FAIL: unknown key did not get the same refusal';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  RAISE NOTICE 'S6 ok: set scopes, own org only';

  -- S7
  SELECT bool_or(has_function_privilege('anon', p.oid, 'EXECUTE')) INTO v_ok
  FROM pg_proc p WHERE p.proname IN ('exos_create_api_key','exos_set_api_key_scopes','exos_api_scope_names','_exos_api_clean_scopes');
  IF v_ok THEN RAISE EXCEPTION 'S7 FAIL: anon can execute a key function'; END IF;
  IF has_function_privilege('authenticated', 'public._exos_api_clean_scopes(text[])', 'EXECUTE') THEN
    RAISE EXCEPTION 'S7 FAIL: the cleaner is client-callable';
  END IF;
  RAISE NOTICE 'S7 ok: grants';
END $$;

SELECT '*** API SCOPES PASSED ***' AS result;
ROLLBACK;
