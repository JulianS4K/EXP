-- ============================================================================
-- Token lineage (mig 20261105160000): tokens minted through the API
-- (exos_api_me 'token.create', exos-api POST /v1/me/personal-access-tokens)
-- record their parent, die with it, always expire and can't mint.
-- Self-contained (e7c prefix), rolled back.
--   TL0  shape: the columns, no client grant on parent_token_id, the
--        trigger functions callable by nobody
--   TL1  a personal token mints a child; revoking the parent revokes the
--        child (revoked_reason parent) and audits it (cascade_from); the
--        child's pat.created row names the parent
--   TL2  the same for account tokens
--   TL3  a child can't mint (42501); it can still revoke
--   TL4  expires_days null through the API is refused (22023); a
--        non-expiring parent's child gets 90 days by default
--   TL5  a child asked for 365 days under a parent expiring in 30 is
--        clamped to the parent (the existing rule)
--   TL6  dashboard-made tokens have no parent and can mint
--   TL7  revoking a child leaves the parent active
--   TL8  every revoke path cascades: self-revoke (DELETE …/current) and
--        offboarding (left_org)
-- Users: o1 owner of org A, f1 a fan (no org).
-- ============================================================================
\set ON_ERROR_STOP on
BEGIN;

-- auth.uid() as Supabase defines it (exos_api_me sets the request claims),
-- still honouring the harness's app.uid. Rolled back.
CREATE OR REPLACE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql STABLE AS $$
  SELECT coalesce(nullif(current_setting('app.uid', true), ''),
                  nullif(current_setting('request.jwt.claim.sub', true), ''),
                  nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'sub')::uuid
$$;
SELECT set_config('app.uid', '', false);

INSERT INTO auth.users (id, email, email_confirmed_at) VALUES
  ('e7c00000-0000-0000-0000-0000000000a1', 'e7c-owner@x.com', now()),
  ('e7c00000-0000-0000-0000-0000000000b1', 'e7c-fan@x.com', now());
INSERT INTO public.exos_orgs (id, name, slug, owner_uid) VALUES
  ('e7c00000-0000-0000-0000-000000000001', 'E7C Hall', 'e7c-hall', 'e7c00000-0000-0000-0000-0000000000a1');
INSERT INTO public.exos_org_memberships (org_id, user_id, role) VALUES
  ('e7c00000-0000-0000-0000-000000000001', 'e7c00000-0000-0000-0000-0000000000a1', 'owner');

CREATE TEMP TABLE e7c (k text PRIMARY KEY, v text) ON COMMIT DROP;
CREATE FUNCTION pg_temp.act(p_uid text) RETURNS void LANGUAGE sql AS $$
  SELECT set_config('app.uid', coalesce(p_uid, ''), true);
$$;
CREATE FUNCTION pg_temp.v(p text) RETURNS text LANGUAGE sql AS $$ SELECT v FROM e7c WHERE k = p $$;
CREATE FUNCTION pg_temp.h(p text) RETURNS text LANGUAGE sql IMMUTABLE AS $$
  SELECT encode(extensions.digest(p, 'sha256'), 'hex')
$$;
-- One /v1/me call with a stored token (by name), as exos-api makes it.
CREATE FUNCTION pg_temp.me(p_tok text, p_action text, p_target text DEFAULT NULL, p_args jsonb DEFAULT '{}'::jsonb)
RETURNS jsonb LANGUAGE sql AS $$
  SELECT public.exos_api_me(pg_temp.h(pg_temp.v(p_tok)), 'pat', p_action, p_target, p_args)
$$;
CREATE FUNCTION pg_temp.mes(p_tok text, p_action text, p_target text DEFAULT NULL, p_args jsonb DEFAULT '{}'::jsonb)
RETURNS text LANGUAGE plpgsql AS $$
BEGIN
  PERFORM pg_temp.me(p_tok, p_action, p_target, p_args);
  RETURN 'ok';
EXCEPTION WHEN OTHERS THEN RETURN SQLSTATE || ' ' || SQLERRM;
END $$;
-- Mint through the API; stores the token and its id under p_as.
CREATE FUNCTION pg_temp.mint(p_tok text, p_as text, p_args jsonb) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE v jsonb;
BEGIN
  v := pg_temp.me(p_tok, 'token.create', NULL, p_args);
  INSERT INTO e7c VALUES (p_as, v->>'token'), (p_as || '.id', v->>'id');
  RETURN v;
END $$;
CREATE FUNCTION pg_temp.pat(p text) RETURNS public.exos_personal_tokens LANGUAGE sql AS $$
  SELECT * FROM public.exos_personal_tokens WHERE id = pg_temp.v(p || '.id')::uuid
$$;
CREATE FUNCTION pg_temp.acct(p text) RETURNS public.exos_account_tokens LANGUAGE sql AS $$
  SELECT * FROM public.exos_account_tokens WHERE id = pg_temp.v(p || '.id')::uuid
$$;

-- Dashboard tokens: the owner's personal tokens (no expiry; 30 days) and the
-- fan's account tokens (no expiry; 30 days), all with me:write.
DO $$
DECLARE v jsonb;
BEGIN
  PERFORM pg_temp.act('e7c00000-0000-0000-0000-0000000000a1');
  v := public.exos_create_personal_token('e7c00000-0000-0000-0000-000000000001', 'forever',
                                         ARRAY['me:read', 'me:write', 'events:read'], NULL);
  INSERT INTO e7c VALUES ('p', v->>'token'), ('p.id', v->>'id');
  v := public.exos_create_personal_token('e7c00000-0000-0000-0000-000000000001', 'month',
                                         ARRAY['me:read', 'me:write', 'events:read'], 30);
  INSERT INTO e7c VALUES ('p30', v->>'token'), ('p30.id', v->>'id');
  PERFORM pg_temp.act('e7c00000-0000-0000-0000-0000000000b1');
  v := public.exos_create_account_token('forever', ARRAY['me:read', 'me:write'], NULL);
  INSERT INTO e7c VALUES ('a', v->>'token'), ('a.id', v->>'id');
  v := public.exos_create_account_token('month', ARRAY['me:read', 'me:write'], 30);
  INSERT INTO e7c VALUES ('a30', v->>'token'), ('a30.id', v->>'id');
  PERFORM pg_temp.act(NULL);
END $$;

-- TL0 ------------------------------------------------------------------------
DO $$
DECLARE f text; t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['public.exos_personal_tokens', 'public.exos_account_tokens'] LOOP
    ASSERT EXISTS (SELECT 1 FROM pg_attribute WHERE attrelid = t::regclass AND attname = 'parent_token_id'
                     AND atttypid = 'uuid'::regtype AND NOT attnotnull), 'TL0 column: ' || t;
    ASSERT NOT has_column_privilege('authenticated', t, 'parent_token_id', 'SELECT'), 'TL0 no client grant: ' || t;
    ASSERT NOT has_column_privilege('authenticated', t, 'key_hash', 'SELECT'), 'TL0 still no hash grant: ' || t;
    ASSERT has_column_privilege('authenticated', t, 'revoked_reason', 'SELECT'), 'TL0 reason still readable: ' || t;
    ASSERT (SELECT count(*) FROM pg_constraint WHERE conrelid = t::regclass AND contype = 'c'
              AND pg_get_constraintdef(oid) LIKE '%revoked_reason%') = 1, 'TL0 one reason check: ' || t;
  END LOOP;
  FOREACH f IN ARRAY ARRAY['public._exos_tg_pat_revoke_children()', 'public._exos_tg_account_token_revoke_children()'] LOOP
    ASSERT NOT has_function_privilege('anon', f, 'EXECUTE') AND NOT has_function_privilege('authenticated', f, 'EXECUTE'),
      'TL0 trigger function: ' || f;
    ASSERT (SELECT prosecdef AND proconfig @> ARRAY['search_path=public, pg_temp'] FROM pg_proc
             WHERE oid = to_regprocedure(f)), 'TL0 definer + search_path: ' || f;
  END LOOP;
  ASSERT NOT has_function_privilege('authenticated', 'public.exos_api_me(text,text,text,text,jsonb)', 'EXECUTE')
     AND has_function_privilege('service_role', 'public.exos_api_me(text,text,text,text,jsonb)', 'EXECUTE'),
    'TL0 exos_api_me grants unchanged';
  RAISE NOTICE 'OK  TL0 shape and grants';
END $$;

-- TL1 ------------------------------------------------------------------------
DO $$
DECLARE v jsonb; c public.exos_personal_tokens; d jsonb;
BEGIN
  v := pg_temp.mint('p', 'pc', '{"name": "leak child", "scopes": ["me:read", "events:read"], "expires_days": 30}');
  ASSERT v->>'kind' = 'personal', 'TL1 minted: ' || v::text;
  c := pg_temp.pat('pc');
  ASSERT c.parent_token_id = pg_temp.v('p.id')::uuid, 'TL1 parent recorded';
  ASSERT c.org_id = 'e7c00000-0000-0000-0000-000000000001', 'TL1 same org';
  SELECT detail INTO d FROM public.exos_token_audit WHERE action = 'pat.created' AND credential_id = pg_temp.v('pc.id');
  ASSERT d->>'parent_token_id' = pg_temp.v('p.id') AND d->>'via' = 'api' AND d ? 'scopes', 'TL1 created audit: ' || d::text;
  ASSERT (SELECT count(*) FROM public.exos_token_audit WHERE action = 'pat.created' AND credential_id = pg_temp.v('pc.id')) = 1,
    'TL1 one created row';
  ASSERT pg_temp.mes('pc', 'tickets.list') = 'ok', 'TL1 child works';
  -- The owner revokes the (leaked) parent in the dashboard.
  PERFORM pg_temp.act('e7c00000-0000-0000-0000-0000000000a1');
  ASSERT public.exos_revoke_personal_token(pg_temp.v('p.id')::uuid), 'TL1 parent revoked';
  PERFORM pg_temp.act(NULL);
  c := pg_temp.pat('pc');
  ASSERT c.revoked_at IS NOT NULL AND c.revoked_reason = 'parent', 'TL1 child revoked: ' || coalesce(c.revoked_reason, 'null');
  ASSERT (pg_temp.pat('p')).revoked_reason = 'user', 'TL1 parent reason unchanged';
  ASSERT pg_temp.mes('pc', 'tickets.list') LIKE '42501%', 'TL1 child stops working';
  ASSERT EXISTS (SELECT 1 FROM public.exos_token_audit
                  WHERE action = 'pat.revoked' AND credential_id = pg_temp.v('pc.id')
                    AND user_id = 'e7c00000-0000-0000-0000-0000000000a1' AND org_id = 'e7c00000-0000-0000-0000-000000000001'
                    AND detail->>'cascade_from' = pg_temp.v('p.id')), 'TL1 cascade audited';
  RAISE NOTICE 'OK  TL1 a personal token''s child dies with it';
END $$;

-- TL2 ------------------------------------------------------------------------
DO $$
DECLARE v jsonb; c public.exos_account_tokens; d jsonb;
BEGIN
  v := pg_temp.mint('a', 'ac', '{"name": "leak child", "scopes": ["me:read"]}');
  ASSERT v->>'kind' = 'account' AND v->>'org_id' IS NULL, 'TL2 minted: ' || v::text;
  c := pg_temp.acct('ac');
  ASSERT c.parent_token_id = pg_temp.v('a.id')::uuid, 'TL2 parent recorded';
  SELECT detail INTO d FROM public.exos_token_audit WHERE action = 'pat.created' AND credential_id = pg_temp.v('ac.id');
  ASSERT d->>'parent_token_id' = pg_temp.v('a.id') AND d->>'via' = 'api' AND (d->>'account')::boolean,
    'TL2 created audit: ' || d::text;
  ASSERT pg_temp.mes('ac', 'tickets.list') = 'ok', 'TL2 child works';
  PERFORM pg_temp.act('e7c00000-0000-0000-0000-0000000000b1');
  ASSERT public.exos_revoke_account_token(pg_temp.v('a.id')::uuid), 'TL2 parent revoked';
  PERFORM pg_temp.act(NULL);
  c := pg_temp.acct('ac');
  ASSERT c.revoked_at IS NOT NULL AND c.revoked_reason = 'parent', 'TL2 child revoked: ' || coalesce(c.revoked_reason, 'null');
  ASSERT pg_temp.mes('ac', 'tickets.list') LIKE '42501%', 'TL2 child stops working';
  ASSERT EXISTS (SELECT 1 FROM public.exos_token_audit
                  WHERE action = 'pat.revoked' AND credential_id = pg_temp.v('ac.id')
                    AND user_id = 'e7c00000-0000-0000-0000-0000000000b1' AND org_id IS NULL
                    AND detail->>'cascade_from' = pg_temp.v('a.id') AND (detail->>'account')::boolean), 'TL2 cascade audited';
  RAISE NOTICE 'OK  TL2 an account token''s child dies with it';
END $$;

-- TL3 ------------------------------------------------------------------------
DO $$
DECLARE s text; n int;
BEGIN
  PERFORM pg_temp.mint('p30', 'p30c', '{"scopes": ["me:read", "me:write"], "expires_days": 30}');
  PERFORM pg_temp.mint('a30', 'a30c', '{"scopes": ["me:read", "me:write"], "expires_days": 30}');
  SELECT count(*) INTO n FROM public.exos_personal_tokens WHERE user_id = 'e7c00000-0000-0000-0000-0000000000a1';
  s := pg_temp.mes('p30c', 'token.create', NULL, '{"scopes": ["me:read"], "expires_days": 30}');
  ASSERT s LIKE '42501%minted through the API can''t mint%', 'TL3 personal child can''t mint: ' || s;
  s := pg_temp.mes('a30c', 'token.create', NULL, '{"scopes": ["me:read"], "expires_days": 30}');
  ASSERT s LIKE '42501%minted through the API can''t mint%', 'TL3 account child can''t mint: ' || s;
  ASSERT (SELECT count(*) FROM public.exos_personal_tokens WHERE user_id = 'e7c00000-0000-0000-0000-0000000000a1') = n,
    'TL3 nothing minted';
  -- It still reads its tokens and can revoke (here: itself).
  ASSERT pg_temp.mes('p30c', 'tokens.list') = 'ok', 'TL3 child lists';
  ASSERT (pg_temp.me('a30c', 'token.revoke', pg_temp.v('a30c.id'))->>'revoked')::boolean, 'TL3 child revokes';
  ASSERT (pg_temp.acct('a30c')).revoked_reason = 'user', 'TL3 revoked as the user';
  RAISE NOTICE 'OK  TL3 a child can''t mint, can still revoke';
END $$;

-- TL4 ------------------------------------------------------------------------
DO $$
DECLARE s text; v jsonb; c public.exos_personal_tokens;
BEGIN
  -- A fresh never-expiring parent (p was revoked in TL1).
  PERFORM pg_temp.act('e7c00000-0000-0000-0000-0000000000a1');
  v := public.exos_create_personal_token('e7c00000-0000-0000-0000-000000000001', 'forever 2',
                                         ARRAY['me:read', 'me:write'], NULL);
  INSERT INTO e7c VALUES ('q', v->>'token'), ('q.id', v->>'id');
  PERFORM pg_temp.act(NULL);
  ASSERT (pg_temp.pat('q')).expires_at IS NULL, 'TL4 parent never expires';
  s := pg_temp.mes('q', 'token.create', NULL, '{"scopes": ["me:read"], "expires_days": null}');
  ASSERT s LIKE '22023%always expires%', 'TL4 null refused: ' || s;
  s := pg_temp.mes('a30', 'token.create', NULL, '{"scopes": ["me:read"], "expires_days": null}');
  ASSERT s LIKE '22023%', 'TL4 null refused for account tokens: ' || s;
  s := pg_temp.mes('q', 'token.create', NULL, '{"scopes": ["me:read"], "expires_days": "never"}');
  ASSERT s LIKE '22023%', 'TL4 a string refused: ' || s;
  s := pg_temp.mes('q', 'token.create', NULL, '{"scopes": ["me:read"], "expires_days": 7}');
  ASSERT s LIKE '22023%', 'TL4 7 days refused: ' || s;
  -- No expires_days: 90 days, though the parent never expires.
  v := pg_temp.mint('q', 'qc', '{"scopes": ["me:read"]}');
  c := pg_temp.pat('qc');
  ASSERT c.expires_at IS NOT NULL AND c.expires_at = now() + interval '90 days', 'TL4 90 by default: ' || coalesce(c.expires_at::text, 'null');
  ASSERT (v->>'expires_at')::timestamptz = c.expires_at, 'TL4 returned expiry';
  -- 365 under a never-expiring parent is kept.
  PERFORM pg_temp.mint('q', 'qy', '{"scopes": ["me:read"], "expires_days": 365}');
  ASSERT (pg_temp.pat('qy')).expires_at = now() + interval '365 days', 'TL4 365 kept';
  RAISE NOTICE 'OK  TL4 an API-minted token always expires (90 days by default)';
END $$;

-- TL5 ------------------------------------------------------------------------
DO $$
DECLARE v jsonb; v_parent timestamptz;
BEGIN
  v_parent := (pg_temp.pat('p30')).expires_at;
  ASSERT v_parent = now() + interval '30 days', 'TL5 parent 30 days';
  v := pg_temp.mint('p30', 'p30y', '{"scopes": ["me:read"], "expires_days": 365}');
  ASSERT (pg_temp.pat('p30y')).expires_at = v_parent, 'TL5 personal clamped to the parent';
  ASSERT (v->>'expires_at')::timestamptz = v_parent, 'TL5 returned clamp';
  v := pg_temp.mint('a30', 'a30y', '{"scopes": ["me:read"], "expires_days": 365}');
  ASSERT (pg_temp.acct('a30y')).expires_at = (pg_temp.acct('a30')).expires_at, 'TL5 account clamped to the parent';
  RAISE NOTICE 'OK  TL5 a child never outlives its parent';
END $$;

-- TL6 ------------------------------------------------------------------------
DO $$
DECLARE r record;
BEGIN
  FOR r IN SELECT k FROM unnest(ARRAY['p', 'p30', 'q']) k LOOP
    ASSERT (pg_temp.pat(r.k)).parent_token_id IS NULL, 'TL6 dashboard personal token: ' || r.k;
  END LOOP;
  FOR r IN SELECT k FROM unnest(ARRAY['a', 'a30']) k LOOP
    ASSERT (pg_temp.acct(r.k)).parent_token_id IS NULL, 'TL6 dashboard account token: ' || r.k;
  END LOOP;
  -- They minted above (TL1-TL5): p30, q, a30 are still live and mint again.
  PERFORM pg_temp.mint('p30', 'p30z', '{"scopes": ["me:read"], "expires_days": 30}');
  PERFORM pg_temp.mint('a30', 'a30z', '{"scopes": ["me:read"], "expires_days": 30}');
  ASSERT (pg_temp.pat('p30z')).parent_token_id = pg_temp.v('p30.id')::uuid, 'TL6 personal mints';
  ASSERT (pg_temp.acct('a30z')).parent_token_id = pg_temp.v('a30.id')::uuid, 'TL6 account mints';
  RAISE NOTICE 'OK  TL6 dashboard tokens have no parent and can mint';
END $$;

-- TL7 ------------------------------------------------------------------------
DO $$
BEGIN
  -- p30's children: p30c, p30y, p30z. Revoke one (from the parent, through the API).
  ASSERT (pg_temp.me('p30', 'token.revoke', pg_temp.v('p30y.id'))->>'revoked')::boolean, 'TL7 child revoked';
  ASSERT (pg_temp.pat('p30y')).revoked_reason = 'user', 'TL7 the child''s own reason';
  ASSERT (pg_temp.pat('p30')).revoked_at IS NULL, 'TL7 parent still active';
  ASSERT (pg_temp.pat('p30c')).revoked_at IS NULL AND (pg_temp.pat('p30z')).revoked_at IS NULL, 'TL7 siblings still active';
  ASSERT pg_temp.mes('p30', 'tickets.list') = 'ok', 'TL7 parent works';
  -- An account child revoked in the dashboard: the parent stays.
  PERFORM pg_temp.act('e7c00000-0000-0000-0000-0000000000b1');
  ASSERT public.exos_revoke_account_token(pg_temp.v('a30y.id')::uuid), 'TL7 account child revoked';
  PERFORM pg_temp.act(NULL);
  ASSERT (pg_temp.acct('a30')).revoked_at IS NULL AND pg_temp.mes('a30', 'tickets.list') = 'ok', 'TL7 account parent works';
  ASSERT (pg_temp.acct('a30z')).revoked_at IS NULL, 'TL7 account sibling active';
  RAISE NOTICE 'OK  TL7 revoking a child leaves the parent active';
END $$;

-- TL8 ------------------------------------------------------------------------
DO $$
BEGIN
  -- DELETE /v1/personal-access-tokens/current on an account parent.
  ASSERT public._exos_account_token_revoke_self(pg_temp.v('a30.id')::uuid), 'TL8 account self revoke';
  ASSERT (pg_temp.acct('a30z')).revoked_reason = 'parent', 'TL8 account child follows the self revoke';
  ASSERT (pg_temp.acct('a30y')).revoked_reason = 'user', 'TL8 an already revoked child keeps its reason';
  -- The same for a personal parent (q: children qc, qy).
  ASSERT public._exos_pat_revoke_self(pg_temp.v('q.id')::uuid), 'TL8 personal self revoke';
  ASSERT (pg_temp.pat('qc')).revoked_reason = 'parent' AND (pg_temp.pat('qy')).revoked_reason = 'parent',
    'TL8 personal children follow the self revoke';
  -- Offboarding: the member leaves; p30 goes with left_org, its children with it.
  DELETE FROM public.exos_org_memberships
   WHERE org_id = 'e7c00000-0000-0000-0000-000000000001' AND user_id = 'e7c00000-0000-0000-0000-0000000000a1';
  ASSERT (pg_temp.pat('p30')).revoked_reason = 'left_org', 'TL8 parent offboarded';
  ASSERT (pg_temp.pat('p30c')).revoked_at IS NOT NULL AND (pg_temp.pat('p30z')).revoked_at IS NOT NULL,
    'TL8 children revoked on offboarding';
  ASSERT (pg_temp.pat('p30y')).revoked_reason = 'user', 'TL8 the earlier revoke stands';
  RAISE NOTICE 'OK  TL8 self revoke and offboarding cascade too';
END $$;

\echo 'test_token_lineage: all passed'
ROLLBACK;
