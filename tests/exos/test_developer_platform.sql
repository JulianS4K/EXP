-- ============================================================================
-- Developer platform (mig 20261031130500). Self-contained (c4 prefix), rolled back.
--   DP1 grants; the role -> scope map and the narrowing rule
--   DP2 personal tokens: shown once, hash only, a confirmed member, within the
--       role, 25 a user
--   DP3 a token follows the live role: a demotion narrows it at once; revoked
--       and expired tokens are refused
--   DP4 offboarding: leaving / disabled revokes tokens and grants; a demotion
--       doesn't (API keys keep their old rule)
--   DP5 apps: redirect URI rules, confidential secret shown once, public none,
--       secret rotation
--   DP6 the consent screen's checks
--   DP7 approve: PKCE required for public apps; scopes narrowed to the role
--   DP8 the code exchange: client auth, PKCE, spent on first use, reuse
--       revokes the first exchange's tokens
--   DP9 refresh rotation; reuse revokes the family
--   DP10 revoke (RFC 7009) and introspect (RFC 7662)
--   DP11 disconnect: the user or an org owner; strangers refused
--   DP12 dynamic registration makes an unverified public app
--   DP13 RLS: own tokens / apps / grants only; owners see their org's grants
--       and audit
-- ============================================================================
\set ON_ERROR_STOP on
BEGIN;
INSERT INTO auth.users(id,email,email_confirmed_at) VALUES
  ('c4000000-0000-0000-0000-0000000000a1','c4-owner@x.com',now()),
  ('c4000000-0000-0000-0000-0000000000a2','c4-manager@x.com',now()),
  ('c4000000-0000-0000-0000-0000000000a3','c4-scanner@x.com',now()),
  ('c4000000-0000-0000-0000-0000000000a4','c4-unconfirmed@x.com',NULL),
  ('c4000000-0000-0000-0000-0000000000a5','c4-dev@x.com',now()),
  ('c4000000-0000-0000-0000-0000000000b1','c4-other@x.com',now());
INSERT INTO public.exos_orgs(id,name,slug,owner_uid) VALUES
  ('c4000000-0000-0000-0000-000000000001','C4 Org','c4-org','c4000000-0000-0000-0000-0000000000a1'),
  ('c4000000-0000-0000-0000-000000000002','C4 Other','c4-other','c4000000-0000-0000-0000-0000000000b1');
INSERT INTO public.exos_org_memberships(org_id,user_id,role) VALUES
  ('c4000000-0000-0000-0000-000000000001','c4000000-0000-0000-0000-0000000000a1','owner'),
  ('c4000000-0000-0000-0000-000000000001','c4000000-0000-0000-0000-0000000000a2','manager'),
  ('c4000000-0000-0000-0000-000000000001','c4000000-0000-0000-0000-0000000000a3','scanner'),
  ('c4000000-0000-0000-0000-000000000001','c4000000-0000-0000-0000-0000000000a4','manager'),
  ('c4000000-0000-0000-0000-000000000002','c4000000-0000-0000-0000-0000000000b1','owner');

CREATE FUNCTION pg_temp.act(p_uid text) RETURNS void LANGUAGE sql AS $$
  SELECT set_config('app.uid', coalesce(p_uid, ''), true);
$$;
CREATE FUNCTION pg_temp.h(p text) RETURNS text LANGUAGE sql IMMUTABLE SECURITY DEFINER AS $$
  SELECT encode(extensions.digest(p, 'sha256'), 'hex');
$$;
CREATE FUNCTION pg_temp.s256(p text) RETURNS text LANGUAGE sql IMMUTABLE SECURITY DEFINER AS $$
  SELECT public._exos_b64url(extensions.digest(p, 'sha256'));
$$;
CREATE TEMP TABLE c4 (name text PRIMARY KEY, val text) ON COMMIT DROP;
GRANT ALL ON c4 TO authenticated;

-- DP1 -----------------------------------------------------------------------
DO $$
DECLARE f text;
BEGIN
  FOREACH f IN ARRAY ARRAY['public.exos_api_token_auth(text,text)', 'public.exos_oauth_exchange_code(text,text,text,text,text)',
      'public.exos_oauth_refresh(text,text,text,text[])', 'public.exos_oauth_revoke_token(text,text,text)',
      'public.exos_oauth_introspect(text,text,text)', 'public.exos_oauth_register(text,text[],text[],text,text,text)',
      'public._exos_pat_revoke_self(uuid)', 'public._exos_scopes_for_role(text[],text)'] LOOP
    ASSERT NOT has_function_privilege('anon', f, 'EXECUTE') AND NOT has_function_privilege('authenticated', f, 'EXECUTE')
       AND has_function_privilege('service_role', f, 'EXECUTE'), 'DP1 service only: ' || f;
  END LOOP;
  FOREACH f IN ARRAY ARRAY['public.exos_create_personal_token(uuid,text,text[],integer)', 'public.exos_revoke_personal_token(uuid)',
      'public.exos_oauth_app_create(text,text[],text[],text,text,text)', 'public.exos_oauth_app_update(text,jsonb)',
      'public.exos_oauth_app_rotate_secret(text)', 'public.exos_oauth_app_delete(text)',
      'public.exos_oauth_authorize_info(text,text,text)', 'public.exos_oauth_authorize_approve(text,text,text,uuid,text,text,text)',
      'public.exos_oauth_my_grants()', 'public.exos_oauth_org_grants(uuid)', 'public.exos_oauth_revoke_grant(uuid)'] LOOP
    ASSERT NOT has_function_privilege('anon', f, 'EXECUTE') AND has_function_privilege('authenticated', f, 'EXECUTE'),
      'DP1 authenticated: ' || f;
  END LOOP;
  ASSERT NOT has_column_privilege('authenticated', 'public.exos_personal_tokens', 'key_hash', 'SELECT')
     AND NOT has_column_privilege('authenticated', 'public.exos_oauth_apps', 'secret_hash', 'SELECT'), 'DP1 hashes hidden';
  ASSERT NOT has_table_privilege('authenticated', 'public.exos_oauth_tokens', 'SELECT')
     AND NOT has_table_privilege('authenticated', 'public.exos_oauth_codes', 'SELECT'), 'DP1 tokens/codes hidden';
  ASSERT public.exos_role_token_scopes('owner') = public.exos_api_scope_names(), 'DP1 owner = all';
  ASSERT cardinality(public.exos_role_token_scopes('nobody')) = 0, 'DP1 unknown role';
  ASSERT public._exos_scopes_for_role(ARRAY['events:write','webhooks:write','orders:read'], 'manager')
         = ARRAY['events:read','events:write','orders:read'], 'DP1 manager narrowing';
  ASSERT public._exos_scopes_for_role(ARRAY['events:write','tickets:write'], 'scanner')
         = ARRAY['events:read','tickets:read'], 'DP1 a write the role lacks keeps its read';
  RAISE NOTICE 'OK  DP1 grants and scope map';
END $$;

-- DP2 -----------------------------------------------------------------------
SET LOCAL ROLE authenticated;
SELECT pg_temp.act('c4000000-0000-0000-0000-0000000000a1');
DO $$
DECLARE v jsonb; i int;
BEGIN
  v := public.exos_create_personal_token('c4000000-0000-0000-0000-000000000001', 'Report script',
         ARRAY['events:write','orders:read','org:admin'], 90);
  ASSERT v->>'token' ~ '^exos_pat_[A-Za-z0-9_-]{43}$' AND v->>'key_prefix' = left(v->>'token', 13), 'DP2 token ' || v::text;
  ASSERT (v->>'expires_at')::timestamptz BETWEEN now() + interval '89 days' AND now() + interval '91 days', 'DP2 expiry';
  INSERT INTO c4 VALUES ('owner_pat', v->>'token'), ('owner_pat_id', v->>'id');
  BEGIN
    PERFORM public.exos_create_personal_token('c4000000-0000-0000-0000-000000000001', 'x', ARRAY['events:read'], 7);
    RAISE EXCEPTION 'DP2 7-day expiry';
  EXCEPTION WHEN invalid_parameter_value THEN NULL;
  END;
  BEGIN
    PERFORM public.exos_create_personal_token('c4000000-0000-0000-0000-000000000002', 'x', ARRAY['events:read'], 30);
    RAISE EXCEPTION 'DP2 token for another org';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  BEGIN
    PERFORM public.exos_create_personal_token('c4000000-0000-0000-0000-000000000001', 'x', ARRAY['read'], 30);
    RAISE EXCEPTION 'DP2 legacy read scope';
  EXCEPTION WHEN invalid_parameter_value THEN NULL;
  END;
  ASSERT (SELECT count(*) FROM public.exos_personal_tokens) = 1, 'DP2 owner sees their token';
END $$;
SELECT pg_temp.act('c4000000-0000-0000-0000-0000000000a3');
DO $$
DECLARE v jsonb; i int;
BEGIN
  BEGIN
    PERFORM public.exos_create_personal_token('c4000000-0000-0000-0000-000000000001', 'x', ARRAY['org:admin'], NULL);
    RAISE EXCEPTION 'DP2 scanner granted org:admin';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  v := public.exos_create_personal_token('c4000000-0000-0000-0000-000000000001', 'Door', ARRAY['tickets:read','checkin:write'], NULL);
  ASSERT v->>'expires_at' IS NULL, 'DP2 no expiry';
  INSERT INTO c4 VALUES ('scanner_pat', v->>'token');
  ASSERT (SELECT count(*) FROM public.exos_personal_tokens) = 1, 'DP2 scanner sees only theirs';
  FOR i IN 1..24 LOOP
    PERFORM public.exos_create_personal_token('c4000000-0000-0000-0000-000000000001', 't' || i, ARRAY['events:read'], 30);
  END LOOP;
  BEGIN
    PERFORM public.exos_create_personal_token('c4000000-0000-0000-0000-000000000001', 'x', ARRAY['events:read'], 30);
    RAISE EXCEPTION 'DP2 26th token';
  EXCEPTION WHEN program_limit_exceeded THEN NULL;
  END;
END $$;
SELECT pg_temp.act('c4000000-0000-0000-0000-0000000000a4');
DO $$
BEGIN
  PERFORM public.exos_create_personal_token('c4000000-0000-0000-0000-000000000001', 'x', ARRAY['events:read'], 30);
  RAISE EXCEPTION 'DP2 unconfirmed email';
EXCEPTION WHEN insufficient_privilege THEN NULL;
END $$;
RESET ROLE;
DO $$
BEGIN
  ASSERT (SELECT key_hash FROM public.exos_personal_tokens WHERE id = (SELECT val FROM c4 WHERE name = 'owner_pat_id')::uuid)
       = pg_temp.h((SELECT val FROM c4 WHERE name = 'owner_pat')), 'DP2 hash';
  DELETE FROM public.exos_personal_tokens WHERE name ~ '^t[0-9]+$';
  RAISE NOTICE 'OK  DP2 personal tokens';
END $$;

-- DP3 -----------------------------------------------------------------------
DO $$
DECLARE v jsonb; h text := pg_temp.h((SELECT val FROM c4 WHERE name = 'owner_pat'));
BEGIN
  v := public.exos_api_token_auth(h, 'pat');
  ASSERT v->>'role' = 'owner' AND v->'scopes' = '["events:read","events:write","orders:read","org:admin"]'::jsonb,
    'DP3 owner ' || v::text;
  ASSERT (SELECT last_used_at FROM public.exos_personal_tokens WHERE key_hash = h) IS NOT NULL, 'DP3 stamped';
  -- Demoted to scanner: at once, events:read only (no org:admin, no orders).
  UPDATE public.exos_org_memberships SET role = 'scanner'
   WHERE org_id = 'c4000000-0000-0000-0000-000000000001' AND user_id = 'c4000000-0000-0000-0000-0000000000a1';
  v := public.exos_api_token_auth(h, 'pat');
  ASSERT v->>'role' = 'scanner' AND v->'scopes' = '["events:read"]'::jsonb, 'DP3 demoted ' || v::text;
  ASSERT (SELECT revoked_at FROM public.exos_personal_tokens WHERE key_hash = h) IS NULL, 'DP3 demotion keeps the token';
  UPDATE public.exos_org_memberships SET role = 'owner'
   WHERE org_id = 'c4000000-0000-0000-0000-000000000001' AND user_id = 'c4000000-0000-0000-0000-0000000000a1';
  ASSERT public.exos_api_token_auth(h, 'pat')->>'role' = 'owner', 'DP3 promoted back';
  ASSERT public.exos_api_token_auth(h, 'oauth') IS NULL AND public.exos_api_token_auth(repeat('0', 64), 'pat') IS NULL,
    'DP3 wrong kind / unknown';
  UPDATE public.exos_personal_tokens SET expires_at = now() - interval '1 second' WHERE key_hash = h;
  ASSERT public.exos_api_token_auth(h, 'pat') IS NULL, 'DP3 expired';
  UPDATE public.exos_personal_tokens SET expires_at = NULL WHERE key_hash = h;
  ASSERT public._exos_pat_revoke_self((SELECT id FROM public.exos_personal_tokens WHERE key_hash = h)), 'DP3 revoke self';
  ASSERT public.exos_api_token_auth(h, 'pat') IS NULL, 'DP3 revoked';
  RAISE NOTICE 'OK  DP3 tokens follow the live role';
END $$;

-- DP5 / DP6 / DP7 / DP8 ----------------------------------------------------------
SET LOCAL ROLE authenticated;
SELECT pg_temp.act('c4000000-0000-0000-0000-0000000000a5');
DO $$
DECLARE v jsonb; u text;
BEGIN
  FOREACH u IN ARRAY ARRAY['http://evil.example/cb', 'https://a.example/cb#x', 'https://*.example/cb',
                           'https://user:pw@a.example/cb', 'ftp://a.example', 'https://a.example/ cb'] LOOP
    BEGIN
      PERFORM public.exos_oauth_app_create('Bad', ARRAY[u], ARRAY['events:read'], 'public');
      RAISE EXCEPTION 'DP5 accepted redirect %', u;
    EXCEPTION WHEN invalid_parameter_value THEN NULL;
    END;
  END LOOP;
  v := public.exos_oauth_app_create('Sync', ARRAY['https://sync.example/cb', 'http://localhost:8765/cb'],
         ARRAY['events:read','orders:read','webhooks:read'], 'confidential', 'https://sync.example/logo.png', 'https://sync.example');
  ASSERT v->>'client_id' ~ '^exos_app_[0-9a-f]{24}$' AND v->>'client_secret' ~ '^exos_cs_[A-Za-z0-9_-]{43}$', 'DP5 confidential ' || v::text;
  INSERT INTO c4 VALUES ('conf_id', v->>'client_id'), ('conf_secret', v->>'client_secret');
  v := public.exos_oauth_app_create('CLI', ARRAY['http://127.0.0.1:9999/cb'], ARRAY['events:read','tickets:read'], 'public');
  ASSERT v->>'client_secret' IS NULL, 'DP5 public app has no secret';
  INSERT INTO c4 VALUES ('pub_id', v->>'client_id');
  v := public.exos_oauth_app_rotate_secret((SELECT c4.val FROM c4 WHERE name = 'conf_id'));
  ASSERT v->>'client_secret' <> (SELECT c4.val FROM c4 WHERE name = 'conf_secret'), 'DP5 rotated';
  UPDATE c4 SET val = v->>'client_secret' WHERE name = 'conf_secret';
  BEGIN
    PERFORM public.exos_oauth_app_rotate_secret((SELECT c4.val FROM c4 WHERE name = 'pub_id'));
    RAISE EXCEPTION 'DP5 rotated a public app';
  EXCEPTION WHEN invalid_parameter_value THEN NULL;
  END;
  ASSERT (SELECT count(*) FROM public.exos_oauth_apps) = 2, 'DP5 developer sees their apps';
  RAISE NOTICE 'OK  DP5 apps';
END $$;
SELECT pg_temp.act('c4000000-0000-0000-0000-0000000000a2');
DO $$
DECLARE v jsonb; conf text := (SELECT c4.val FROM c4 WHERE name = 'conf_id');
BEGIN
  ASSERT (SELECT count(*) FROM public.exos_oauth_apps) = 0, 'DP13 another user''s apps hidden';
  -- DP6
  v := public.exos_oauth_authorize_info('exos_app_000000000000000000000000', 'https://sync.example/cb', NULL);
  ASSERT NOT (v->>'ok')::boolean AND NOT (v->>'redirect_ok')::boolean AND v->>'error' = 'invalid_client', 'DP6 unknown app';
  v := public.exos_oauth_authorize_info(conf, 'https://sync.example/cb/', NULL);
  ASSERT NOT (v->>'redirect_ok')::boolean AND v->>'error' = 'invalid_redirect_uri', 'DP6 near-miss redirect';
  v := public.exos_oauth_authorize_info(conf, 'https://sync.example/cb', 'events:read finance:write');
  ASSERT (v->>'redirect_ok')::boolean AND v->>'error' = 'invalid_scope', 'DP6 scope the app may not ask';
  v := public.exos_oauth_authorize_info(conf, 'https://sync.example/cb', 'events:read webhooks:read');
  ASSERT (v->>'ok')::boolean AND v->'app'->>'name' = 'Sync' AND v->>'redirect_host' = 'sync.example'
     AND v->'orgs'->0->>'role' = 'manager' AND v->'orgs'->0->'grantable' = '["events:read"]'::jsonb, 'DP6 info ' || v::text;
  -- DP7: the manager can't grant webhooks:read; the grant is narrowed.
  v := public.exos_oauth_authorize_approve(conf, 'https://sync.example/cb', 'events:read orders:read webhooks:read',
         'c4000000-0000-0000-0000-000000000001', pg_temp.s256('v-' || repeat('a', 50)), 'S256', NULL);
  ASSERT v->>'code' ~ '^exos_oac_' AND v->'scopes' = '["events:read","orders:read"]'::jsonb, 'DP7 code ' || v::text;
  INSERT INTO c4 VALUES ('code1', v->>'code');
  BEGIN
    PERFORM public.exos_oauth_authorize_approve((SELECT c4.val FROM c4 WHERE name = 'pub_id'), 'http://127.0.0.1:9999/cb',
              NULL, 'c4000000-0000-0000-0000-000000000001', NULL, NULL, NULL);
    RAISE EXCEPTION 'DP7 public app without PKCE';
  EXCEPTION WHEN invalid_parameter_value THEN NULL;
  END;
  BEGIN
    PERFORM public.exos_oauth_authorize_approve(conf, 'https://sync.example/cb', NULL,
              'c4000000-0000-0000-0000-000000000001', 'x', 'plain', NULL);
    RAISE EXCEPTION 'DP7 plain PKCE';
  EXCEPTION WHEN invalid_parameter_value THEN NULL;
  END;
  BEGIN
    PERFORM public.exos_oauth_authorize_approve(conf, 'https://sync.example/cb', NULL,
              'c4000000-0000-0000-0000-000000000002', NULL, NULL, NULL);
    RAISE EXCEPTION 'DP7 granted another org';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  v := public.exos_oauth_authorize_approve((SELECT c4.val FROM c4 WHERE name = 'pub_id'), 'http://127.0.0.1:9999/cb', NULL,
         'c4000000-0000-0000-0000-000000000001', pg_temp.s256('pub-' || repeat('b', 50)), 'S256', NULL);
  INSERT INTO c4 VALUES ('code_pub', v->>'code');
  ASSERT (SELECT count(*) FROM public.exos_oauth_grants) = 2, 'DP7 one grant per app';
  RAISE NOTICE 'OK  DP6/DP7 consent';
END $$;
RESET ROLE;
DO $$
DECLARE
  conf text := (SELECT val FROM c4 WHERE name = 'conf_id');
  sec  text := pg_temp.h((SELECT val FROM c4 WHERE name = 'conf_secret'));
  code text := (SELECT val FROM c4 WHERE name = 'code1');
  v jsonb; a jsonb;
BEGIN
  -- DP8
  v := public.exos_oauth_exchange_code(pg_temp.h(code), conf, pg_temp.h('wrong'), 'https://sync.example/cb',
         pg_temp.s256('v-' || repeat('a', 50)));
  ASSERT v->>'error' = 'invalid_client', 'DP8 bad secret';
  v := public.exos_oauth_exchange_code(pg_temp.h(code), conf, sec, 'https://sync.example/cb', pg_temp.s256('wrong-verifier'));
  ASSERT v->>'error' = 'invalid_grant', 'DP8 wrong verifier';
  v := public.exos_oauth_exchange_code(pg_temp.h(code), conf, sec, 'https://sync.example/cb', pg_temp.s256('v-' || repeat('a', 50)));
  ASSERT v->>'error' = 'invalid_grant', 'DP8 a spent code can''t be retried';
  -- The public app's code: client_id only, right verifier.
  v := public.exos_oauth_exchange_code(pg_temp.h((SELECT c4.val FROM c4 WHERE name = 'code_pub')), (SELECT c4.val FROM c4 WHERE name = 'pub_id'),
         NULL, 'http://127.0.0.1:9999/cb', pg_temp.s256('pub-' || repeat('b', 50)));
  ASSERT v->>'access_token' ~ '^exos_oat_' AND v->>'refresh_token' ~ '^exos_ort_' AND (v->>'expires_in')::int = 3600
     AND v->>'scope' = 'events:read tickets:read' AND v->>'token_type' = 'Bearer', 'DP8 tokens ' || v::text;
  a := public.exos_api_token_auth(pg_temp.h(v->>'access_token'), 'oauth');
  ASSERT a->>'kind' = 'oauth' AND a->>'role' = 'manager' AND a->'scopes' = '["events:read","tickets:read"]'::jsonb, 'DP8 auth ' || a::text;
  INSERT INTO c4 VALUES ('at1', v->>'access_token'), ('rt1', v->>'refresh_token');
  -- The same code again: the tokens of the first exchange die.
  v := public.exos_oauth_exchange_code(pg_temp.h((SELECT c4.val FROM c4 WHERE name = 'code_pub')), (SELECT c4.val FROM c4 WHERE name = 'pub_id'),
         NULL, 'http://127.0.0.1:9999/cb', pg_temp.s256('pub-' || repeat('b', 50)));
  ASSERT v->>'error' = 'invalid_grant', 'DP8 code reuse';
  ASSERT public.exos_api_token_auth(pg_temp.h((SELECT c4.val FROM c4 WHERE name = 'at1')), 'oauth') IS NULL, 'DP8 reuse revoked tokens';
  ASSERT EXISTS (SELECT 1 FROM public.exos_token_audit WHERE action = 'code.reuse_detected'), 'DP8 audited';
  RAISE NOTICE 'OK  DP8 code exchange';
END $$;

-- DP9 / DP10 ------------------------------------------------------------------
DO $$
DECLARE
  pub text := (SELECT val FROM c4 WHERE name = 'pub_id');
  v jsonb; r1 jsonb; r2 jsonb; code jsonb;
BEGIN
  PERFORM pg_temp.act('c4000000-0000-0000-0000-0000000000a2');
  code := public.exos_oauth_authorize_approve(pub, 'http://127.0.0.1:9999/cb', 'events:read', 'c4000000-0000-0000-0000-000000000001',
            pg_temp.s256('pub-' || repeat('c', 50)), 'S256', 'https://exos.example/functions/v1/exos-mcp');
  PERFORM pg_temp.act(NULL);
  r1 := public.exos_oauth_exchange_code(pg_temp.h(code->>'code'), pub, NULL, 'http://127.0.0.1:9999/cb', pg_temp.s256('pub-' || repeat('c', 50)));
  ASSERT r1->>'scope' = 'events:read', 'DP9 narrowed grant ' || r1::text;
  ASSERT public.exos_api_token_auth(pg_temp.h(r1->>'access_token'), 'oauth')->>'resource' = 'https://exos.example/functions/v1/exos-mcp',
    'DP9 resource kept';
  r2 := public.exos_oauth_refresh(pg_temp.h(r1->>'refresh_token'), pub, NULL, NULL);
  ASSERT r2->>'access_token' IS NOT NULL AND r2->>'refresh_token' <> r1->>'refresh_token', 'DP9 rotated ' || r2::text;
  ASSERT public.exos_api_token_auth(pg_temp.h(r1->>'access_token'), 'oauth') IS NULL, 'DP9 old access token retired';
  ASSERT public.exos_api_token_auth(pg_temp.h(r2->>'access_token'), 'oauth') IS NOT NULL, 'DP9 new access token works';
  v := public.exos_oauth_refresh(pg_temp.h(r2->>'refresh_token'), pub, NULL, ARRAY['events:read','orders:read']);
  ASSERT v->>'error' = 'invalid_scope', 'DP9 a refresh can''t widen';
  -- r1's refresh token again: leaked copy -> the family dies.
  v := public.exos_oauth_refresh(pg_temp.h(r1->>'refresh_token'), pub, NULL, NULL);
  ASSERT v->>'error' = 'invalid_grant', 'DP9 reuse refused';
  ASSERT public.exos_api_token_auth(pg_temp.h(r2->>'access_token'), 'oauth') IS NULL, 'DP9 family revoked';
  ASSERT (public.exos_oauth_refresh(pg_temp.h(r2->>'refresh_token'), pub, NULL, NULL))->>'error' = 'invalid_grant', 'DP9 r2 dead';
  ASSERT EXISTS (SELECT 1 FROM public.exos_token_audit WHERE action = 'refresh.reuse_detected'), 'DP9 audited';
  RAISE NOTICE 'OK  DP9 refresh rotation and reuse detection';

  -- DP10
  PERFORM pg_temp.act('c4000000-0000-0000-0000-0000000000a2');
  code := public.exos_oauth_authorize_approve(pub, 'http://127.0.0.1:9999/cb', NULL, 'c4000000-0000-0000-0000-000000000001',
            pg_temp.s256('pub-' || repeat('d', 50)), 'S256', NULL);
  PERFORM pg_temp.act(NULL);
  r1 := public.exos_oauth_exchange_code(pg_temp.h(code->>'code'), pub, NULL, 'http://127.0.0.1:9999/cb', pg_temp.s256('pub-' || repeat('d', 50)));
  v := public.exos_oauth_introspect(pg_temp.h(r1->>'access_token'), pub, NULL);
  ASSERT (v->>'active')::boolean AND v->>'role' = 'manager' AND v->>'scope' = 'events:read tickets:read', 'DP10 introspect ' || v::text;
  ASSERT NOT (public.exos_oauth_introspect(pg_temp.h(r1->>'access_token'), (SELECT c4.val FROM c4 WHERE name = 'conf_id'),
              pg_temp.h((SELECT c4.val FROM c4 WHERE name = 'conf_secret')))->>'active')::boolean, 'DP10 other app''s token';
  ASSERT public.exos_oauth_revoke_token(pg_temp.h(r1->>'refresh_token'), pub, NULL) = '{}'::jsonb, 'DP10 revoke ok';
  ASSERT public.exos_api_token_auth(pg_temp.h(r1->>'access_token'), 'oauth') IS NULL, 'DP10 refresh revoke takes the family';
  ASSERT public.exos_oauth_revoke_token(repeat('0', 64), pub, NULL) = '{}'::jsonb, 'DP10 unknown token still ok';
  PERFORM pg_temp.act('c4000000-0000-0000-0000-0000000000a2');
  code := public.exos_oauth_authorize_approve(pub, 'http://127.0.0.1:9999/cb', NULL, 'c4000000-0000-0000-0000-000000000001',
            pg_temp.s256('pub-' || repeat('e', 50)), 'S256', NULL);
  PERFORM pg_temp.act(NULL);
  r1 := public.exos_oauth_exchange_code(pg_temp.h(code->>'code'), pub, NULL, 'http://127.0.0.1:9999/cb', pg_temp.s256('pub-' || repeat('e', 50)));
  INSERT INTO c4 VALUES ('code_live', r1->>'access_token');
  RAISE NOTICE 'OK  DP10 revoke and introspect';
END $$;

-- DP11 / DP13 -------------------------------------------------------------------
SET LOCAL ROLE authenticated;
SELECT pg_temp.act('c4000000-0000-0000-0000-0000000000b1');
DO $$
BEGIN
  ASSERT (SELECT count(*) FROM public.exos_oauth_grants) = 0, 'DP13 stranger sees no grants';
  BEGIN
    PERFORM public.exos_oauth_revoke_grant((SELECT id FROM public.exos_oauth_grants LIMIT 1));
    RAISE EXCEPTION 'DP11 stranger revoked';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  BEGIN
    PERFORM public.exos_oauth_org_grants('c4000000-0000-0000-0000-000000000001');
    RAISE EXCEPTION 'DP13 stranger listed org grants';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
END $$;
SELECT pg_temp.act('c4000000-0000-0000-0000-0000000000a1');
DO $$
DECLARE v jsonb;
BEGIN
  v := public.exos_oauth_org_grants('c4000000-0000-0000-0000-000000000001');
  ASSERT jsonb_array_length(v) = 2 AND v->0->>'user_email' = 'c4-manager@x.com', 'DP13 owner sees org grants ' || v::text;
  ASSERT (SELECT count(*) FROM public.exos_token_audit WHERE user_id = 'c4000000-0000-0000-0000-0000000000a2') > 0, 'DP13 owner reads org audit';
  -- An owner disconnects the manager's CLI app.
  ASSERT public.exos_oauth_revoke_grant((SELECT (g->>'grant_id')::uuid FROM jsonb_array_elements(v) g
                                          WHERE g->'app'->>'name' = 'CLI')), 'DP11 owner disconnect';
END $$;
RESET ROLE;
DO $$
BEGIN
  ASSERT public.exos_api_token_auth(pg_temp.h((SELECT val FROM c4 WHERE name = 'code_live')), 'oauth') IS NULL, 'DP11 token dead';
  RAISE NOTICE 'OK  DP11/DP13 connected apps and RLS';
END $$;

-- DP4 -----------------------------------------------------------------------
DO $$
DECLARE conf text := (SELECT val FROM c4 WHERE name = 'conf_id'); v jsonb; h text;
BEGIN
  -- The scanner leaves: their PAT goes. The manager is demoted: their Sync grant stays.
  h := pg_temp.h((SELECT val FROM c4 WHERE name = 'scanner_pat'));
  ASSERT public.exos_api_token_auth(h, 'pat') IS NOT NULL, 'DP4 scanner token live';
  DELETE FROM public.exos_org_memberships
   WHERE org_id = 'c4000000-0000-0000-0000-000000000001' AND user_id = 'c4000000-0000-0000-0000-0000000000a3';
  ASSERT (SELECT revoked_reason FROM public.exos_personal_tokens WHERE key_hash = h) = 'left_org', 'DP4 left -> revoked';
  UPDATE public.exos_org_memberships SET role = 'content'
   WHERE org_id = 'c4000000-0000-0000-0000-000000000001' AND user_id = 'c4000000-0000-0000-0000-0000000000a2';
  ASSERT EXISTS (SELECT 1 FROM public.exos_oauth_grants g JOIN public.exos_oauth_apps a ON a.id = g.app_id
                  WHERE a.client_id = conf AND g.revoked_at IS NULL), 'DP4 demotion keeps the grant';
  UPDATE public.exos_org_memberships SET disabled = true
   WHERE org_id = 'c4000000-0000-0000-0000-000000000001' AND user_id = 'c4000000-0000-0000-0000-0000000000a2';
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_oauth_grants WHERE user_id = 'c4000000-0000-0000-0000-0000000000a2'
                      AND revoked_at IS NULL), 'DP4 disabled -> grants revoked';
  ASSERT EXISTS (SELECT 1 FROM public.exos_token_audit WHERE action = 'member.offboarded'), 'DP4 audited';
  RAISE NOTICE 'OK  DP4 offboarding';
END $$;

-- DP12 ----------------------------------------------------------------------
DO $$
DECLARE v jsonb;
BEGIN
  v := public.exos_oauth_register('Claude', ARRAY['https://claude.ai/api/mcp/auth_callback'], NULL, 'public', NULL, NULL);
  ASSERT v->>'source' = 'dcr' AND NOT (v->>'verified')::boolean AND v->>'client_secret' IS NULL
     AND jsonb_array_length(v->'scopes') = cardinality(public.exos_api_scope_names()), 'DP12 registered ' || v::text;
  BEGIN
    PERFORM public.exos_oauth_register('x', ARRAY['http://attacker.example/cb'], NULL, 'public', NULL, NULL);
    RAISE EXCEPTION 'DP12 bad redirect registered';
  EXCEPTION WHEN invalid_parameter_value THEN NULL;
  END;
  RAISE NOTICE 'OK  DP12 dynamic registration';
END $$;

SELECT '*** DEVELOPER PLATFORM PASSED ***' AS result;
ROLLBACK;
