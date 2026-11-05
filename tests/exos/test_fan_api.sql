-- ============================================================================
-- Fan API (/v1/me), account tokens, the gap list's org writes and public
-- discovery (mig 20261105110000). Self-contained (f5 prefix), rolled back.
--   FA1  grants: who may call what (anon: exos_api_public only)
--   FA2  scopes: me:read / me:write are user scopes (every role's tokens,
--        never an org API key, never a role's org-configured set)
--   FA3  token types: only a personal, account or OAuth token acts as a
--        user; an org key, a revoked, expired or unknown token is refused;
--        me:read can't write, me:write covers me:read
--   FA4  cross-user isolation: tickets, orders, bundles, transfers, refund
--        requests, memberships of another user are never seen or touched
--   FA5  barcodes: the live rotating code only (never the secret), none
--        while the ticket is in a transfer or no longer active
--   FA6  transfers keep their rules: the lock, the claim key, cancel
--   FA7  refund requests, profile and marketing preferences
--   FA8  tokens: a token mints at most its own scopes, never outlives
--        itself; account tokens are me:* only; revoke is per user
--   FA9  org writes: the key's org, its scopes NOW, the creator's role NOW,
--        owner-only API keys, the new key's plaintext never logged
--   FA10 public discovery: published only, no counts or capacity, rate
--        limited per network, anon through exos_api_public
-- Users: o1 owner of org A, m1 manager of A, s1 scanner of A, f2 a fan (no
-- org), f3 another fan, b1 owner of org B.
-- ============================================================================
\set ON_ERROR_STOP on
BEGIN;

-- auth.uid() as Supabase defines it (exos_api_me / exos_api_gap_write set the
-- request claims), still honouring the harness's app.uid. Rolled back.
CREATE OR REPLACE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql STABLE AS $$
  SELECT coalesce(nullif(current_setting('app.uid', true), ''),
                  nullif(current_setting('request.jwt.claim.sub', true), ''),
                  nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'sub')::uuid
$$;
SELECT set_config('app.uid', '', false);

INSERT INTO auth.users (id, email, email_confirmed_at) VALUES
  ('f5000000-0000-0000-0000-0000000000a1', 'f5-owner@x.com', now()),
  ('f5000000-0000-0000-0000-0000000000a2', 'f5-manager@x.com', now()),
  ('f5000000-0000-0000-0000-0000000000a3', 'f5-scanner@x.com', now()),
  ('f5000000-0000-0000-0000-0000000000b2', 'f5-fan@x.com', now()),
  ('f5000000-0000-0000-0000-0000000000b3', 'f5-other@x.com', now()),
  ('f5000000-0000-0000-0000-0000000000c1', 'f5-borg@x.com', now());
INSERT INTO public.exos_orgs (id, name, slug, owner_uid) VALUES
  ('f5000000-0000-0000-0000-000000000001', 'F5 Hall', 'f5-hall', 'f5000000-0000-0000-0000-0000000000a1'),
  ('f5000000-0000-0000-0000-000000000002', 'F5 Other', 'f5-other', 'f5000000-0000-0000-0000-0000000000c1');
INSERT INTO public.exos_org_memberships (org_id, user_id, role) VALUES
  ('f5000000-0000-0000-0000-000000000001', 'f5000000-0000-0000-0000-0000000000a1', 'owner'),
  ('f5000000-0000-0000-0000-000000000001', 'f5000000-0000-0000-0000-0000000000a2', 'manager'),
  ('f5000000-0000-0000-0000-000000000001', 'f5000000-0000-0000-0000-0000000000a3', 'scanner'),
  ('f5000000-0000-0000-0000-000000000002', 'f5000000-0000-0000-0000-0000000000c1', 'owner');
INSERT INTO public.exos_events (id, org_id, name, slug, status, starts_at, doors_at, total_tickets, created_by) VALUES
  ('f5000000-0000-0000-0000-0000000000e1', 'f5000000-0000-0000-0000-000000000001', 'F5 Live', 'f5-live', 'published',
   now() + interval '10 days', now() + interval '10 days' - interval '1 hour', 100, 'f5000000-0000-0000-0000-0000000000a1'),
  ('f5000000-0000-0000-0000-0000000000e2', 'f5000000-0000-0000-0000-000000000001', 'F5 Draft', 'f5-draft', 'draft',
   now() + interval '20 days', NULL, 0, 'f5000000-0000-0000-0000-0000000000a1'),
  ('f5000000-0000-0000-0000-0000000000e3', 'f5000000-0000-0000-0000-000000000002', 'F5 Elsewhere', 'f5-elsewhere', 'published',
   now() + interval '12 days', NULL, 50, 'f5000000-0000-0000-0000-0000000000c1');
INSERT INTO public.exos_ticket_tiers (id, event_id, name, price, capacity, sold) VALUES
  ('f5000000-0000-0000-0000-0000000000d1', 'f5000000-0000-0000-0000-0000000000e1', 'GA', 25, 100, 3),
  ('f5000000-0000-0000-0000-0000000000d3', 'f5000000-0000-0000-0000-0000000000e3', 'GA', 30, 50, 1);
INSERT INTO public.exos_checkout_sessions (session_id, event_id, tier_id, org_id, buyer_uid, buyer_email, quantity,
                                           amount_cents, status, guest) VALUES
  ('cs_f5_fan', 'f5000000-0000-0000-0000-0000000000e1', 'f5000000-0000-0000-0000-0000000000d1',
   'f5000000-0000-0000-0000-000000000001', 'f5000000-0000-0000-0000-0000000000b2', 'f5-fan@x.com', 2, 5000, 'fulfilled', false),
  ('cs_f5_other', 'f5000000-0000-0000-0000-0000000000e1', 'f5000000-0000-0000-0000-0000000000d1',
   'f5000000-0000-0000-0000-000000000001', 'f5000000-0000-0000-0000-0000000000b3', 'f5-other@x.com', 1, 2500, 'fulfilled', false);
INSERT INTO public.exos_tickets (id, event_id, org_id, tier_id, tier_name, buyer_id, owner_id, status, barcode_secret,
                                 price_paid, order_ref) VALUES
  ('f5000000-0000-0000-0000-0000000000c1', 'f5000000-0000-0000-0000-0000000000e1', 'f5000000-0000-0000-0000-000000000001',
   'f5000000-0000-0000-0000-0000000000d1', 'GA', 'f5000000-0000-0000-0000-0000000000b2',
   'f5000000-0000-0000-0000-0000000000b2', 'active', 'sek-f5-c1', 25, 'cs_f5_fan'),
  ('f5000000-0000-0000-0000-0000000000c2', 'f5000000-0000-0000-0000-0000000000e1', 'f5000000-0000-0000-0000-000000000001',
   'f5000000-0000-0000-0000-0000000000d1', 'GA', 'f5000000-0000-0000-0000-0000000000b2',
   'f5000000-0000-0000-0000-0000000000b2', 'active', 'sek-f5-c2', 25, 'cs_f5_fan'),
  ('f5000000-0000-0000-0000-0000000000c3', 'f5000000-0000-0000-0000-0000000000e1', 'f5000000-0000-0000-0000-000000000001',
   'f5000000-0000-0000-0000-0000000000d1', 'GA', 'f5000000-0000-0000-0000-0000000000b3',
   'f5000000-0000-0000-0000-0000000000b3', 'active', 'sek-f5-c3', 25, 'cs_f5_other');
-- Org API keys: k1 the owner's (wide), k2 the manager's, k3 B's owner's, k4 a narrow key of the owner.
INSERT INTO public.exos_api_keys (id, org_id, name, key_prefix, key_hash, scopes, created_by) VALUES
  ('f5000000-0000-0000-0000-0000000000f1', 'f5000000-0000-0000-0000-000000000001', 'own', 'sk_live_f5f1',
   encode(extensions.digest('sk_live_f5_k1', 'sha256'), 'hex'),
   ARRAY['events:write', 'tickets:write', 'checkin:write', 'commerce:write', 'org:admin'], 'f5000000-0000-0000-0000-0000000000a1'),
  ('f5000000-0000-0000-0000-0000000000f2', 'f5000000-0000-0000-0000-000000000001', 'mgr', 'sk_live_f5f2',
   encode(extensions.digest('sk_live_f5_k2', 'sha256'), 'hex'),
   ARRAY['events:write', 'commerce:write'], 'f5000000-0000-0000-0000-0000000000a2'),
  ('f5000000-0000-0000-0000-0000000000f3', 'f5000000-0000-0000-0000-000000000002', 'b', 'sk_live_f5f3',
   encode(extensions.digest('sk_live_f5_k3', 'sha256'), 'hex'),
   ARRAY['events:write', 'tickets:write', 'commerce:write', 'org:admin'], 'f5000000-0000-0000-0000-0000000000c1'),
  ('f5000000-0000-0000-0000-0000000000f4', 'f5000000-0000-0000-0000-000000000001', 'narrow', 'sk_live_f5f4',
   encode(extensions.digest('sk_live_f5_k4', 'sha256'), 'hex'),
   ARRAY['events:read'], 'f5000000-0000-0000-0000-0000000000a1');

CREATE TEMP TABLE f5 (k text PRIMARY KEY, v text) ON COMMIT DROP;
CREATE FUNCTION pg_temp.act(p_uid text) RETURNS void LANGUAGE sql AS $$
  SELECT set_config('app.uid', coalesce(p_uid, ''), true);
$$;
CREATE FUNCTION pg_temp.u(p text) RETURNS text LANGUAGE sql IMMUTABLE AS $$
  SELECT 'f5000000-0000-0000-0000-0000000000' || p
$$;
CREATE FUNCTION pg_temp.st(p_sql text) RETURNS text LANGUAGE plpgsql AS $$
BEGIN
  EXECUTE p_sql;
  RETURN 'ok';
EXCEPTION WHEN OTHERS THEN RETURN SQLSTATE || ' ' || SQLERRM;
END $$;
CREATE FUNCTION pg_temp.v(p text) RETURNS text LANGUAGE sql AS $$ SELECT v FROM f5 WHERE k = p $$;
CREATE FUNCTION pg_temp.h(p text) RETURNS text LANGUAGE sql IMMUTABLE AS $$
  SELECT encode(extensions.digest(p, 'sha256'), 'hex')
$$;
-- One /v1/me call with a stored token (by name), as exos-api makes it.
CREATE FUNCTION pg_temp.me(p_tok text, p_action text, p_target text DEFAULT NULL, p_args jsonb DEFAULT '{}'::jsonb,
                           p_kind text DEFAULT 'pat') RETURNS jsonb LANGUAGE sql AS $$
  SELECT public.exos_api_me(pg_temp.h(pg_temp.v(p_tok)), p_kind, p_action, p_target, p_args)
$$;
CREATE FUNCTION pg_temp.mes(p_tok text, p_action text, p_target text DEFAULT NULL, p_args jsonb DEFAULT '{}'::jsonb,
                            p_kind text DEFAULT 'pat') RETURNS text LANGUAGE plpgsql AS $$
BEGIN
  PERFORM pg_temp.me(p_tok, p_action, p_target, p_args, p_kind);
  RETURN 'ok';
EXCEPTION WHEN OTHERS THEN RETURN SQLSTATE || ' ' || SQLERRM;
END $$;
CREATE FUNCTION pg_temp.gap(p_key text, p_action text, p_target text DEFAULT NULL, p_args jsonb DEFAULT '{}'::jsonb,
                            p_idem text DEFAULT NULL) RETURNS jsonb LANGUAGE sql AS $$
  SELECT public.exos_api_gap_write((SELECT id FROM public.exos_api_keys WHERE key_hash = pg_temp.h(p_key)),
                                   p_action, p_target, p_args, p_idem)
$$;
CREATE FUNCTION pg_temp.gaps(p_key text, p_action text, p_target text DEFAULT NULL, p_args jsonb DEFAULT '{}'::jsonb)
RETURNS text LANGUAGE plpgsql AS $$
BEGIN
  PERFORM pg_temp.gap(p_key, p_action, p_target, p_args);
  RETURN 'ok';
EXCEPTION WHEN OTHERS THEN RETURN SQLSTATE || ' ' || SQLERRM;
END $$;
GRANT ALL ON f5 TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION pg_temp.act(text), pg_temp.st(text) TO anon, authenticated, service_role;

-- Tokens: an account token per fan (f2: read + write, 30 days; f2r: read
-- only; f3: read + write), the owner's personal token with me:* and org scopes.
DO $$
DECLARE v jsonb;
BEGIN
  PERFORM pg_temp.act(pg_temp.u('b2'));
  v := public.exos_create_account_token('fan app', ARRAY['me:read', 'me:write'], 30);
  INSERT INTO f5 VALUES ('f2', v->>'token'), ('f2.id', v->>'id');
  v := public.exos_create_account_token('reader', ARRAY['me:read'], 90);
  INSERT INTO f5 VALUES ('f2r', v->>'token');
  PERFORM pg_temp.act(pg_temp.u('b3'));
  v := public.exos_create_account_token('other', ARRAY['me:read', 'me:write'], NULL);
  INSERT INTO f5 VALUES ('f3', v->>'token'), ('f3.id', v->>'id');
  PERFORM pg_temp.act(pg_temp.u('a1'));
  v := public.exos_create_personal_token('f5000000-0000-0000-0000-000000000001', 'owner pat',
                                         ARRAY['me:read', 'me:write', 'events:read', 'tickets:read'], NULL);
  INSERT INTO f5 VALUES ('o1', v->>'token'), ('o1.id', v->>'id');
  v := public.exos_create_personal_token('f5000000-0000-0000-0000-000000000001', 'org only', ARRAY['events:read'], 30);
  INSERT INTO f5 VALUES ('o1org', v->>'token');
  PERFORM pg_temp.act(pg_temp.u('a3'));
  v := public.exos_create_personal_token('f5000000-0000-0000-0000-000000000001', 'door phone', ARRAY['me:read', 'checkin:write'], 30);
  INSERT INTO f5 VALUES ('s1', v->>'token');
  PERFORM pg_temp.act(NULL);
END $$;

-- FA1 ------------------------------------------------------------------------
DO $$
DECLARE f text;
BEGIN
  FOREACH f IN ARRAY ARRAY['public.exos_api_me(text, text, text, text, jsonb)',
                           'public.exos_api_gap_write(uuid, text, text, jsonb, text)',
                           'public.exos_api_account_token_auth(text)', 'public._exos_account_token_revoke_self(uuid)',
                           'public._exos_api_public(text, text, jsonb, text)'] LOOP
    ASSERT NOT has_function_privilege('anon', f, 'EXECUTE'), 'FA1 anon: ' || f;
    ASSERT NOT has_function_privilege('authenticated', f, 'EXECUTE'), 'FA1 authenticated: ' || f;
    ASSERT has_function_privilege('service_role', f, 'EXECUTE'), 'FA1 service_role: ' || f;
  END LOOP;
  FOREACH f IN ARRAY ARRAY['public._exos_api_me_cred(text, text)', 'public._exos_api_me_ticket_json(uuid, uuid, boolean)',
                           'public._exos_api_me_order_json(text, uuid)', 'public._exos_api_gap_membership_json(uuid)',
                           'public._exos_api_public_org_json(uuid)', 'public._exos_api_public_tiers_json(uuid)',
                           'public._exos_api_public_event_full(uuid)'] LOOP
    ASSERT NOT has_function_privilege('anon', f, 'EXECUTE') AND NOT has_function_privilege('authenticated', f, 'EXECUTE'),
      'FA1 internal: ' || f;
  END LOOP;
  FOREACH f IN ARRAY ARRAY['public.exos_create_account_token(text, text[], integer)', 'public.exos_revoke_account_token(uuid)'] LOOP
    ASSERT NOT has_function_privilege('anon', f, 'EXECUTE') AND has_function_privilege('authenticated', f, 'EXECUTE'),
      'FA1 signed in only: ' || f;
  END LOOP;
  ASSERT has_function_privilege('anon', 'public.exos_api_public(text, text, jsonb)', 'EXECUTE'), 'FA1 anon public discovery';
  -- The table: a user reads their own rows, never the hash.
  ASSERT NOT has_column_privilege('authenticated', 'public.exos_account_tokens', 'key_hash', 'SELECT'), 'FA1 no hash';
  ASSERT has_column_privilege('authenticated', 'public.exos_account_tokens', 'key_prefix', 'SELECT'), 'FA1 prefix readable';
  ASSERT NOT has_table_privilege('anon', 'public.exos_account_tokens', 'SELECT'), 'FA1 anon table';
  ASSERT NOT has_table_privilege('authenticated', 'public.exos_account_tokens', 'INSERT'), 'FA1 no direct insert';
  ASSERT (SELECT relrowsecurity FROM pg_class WHERE oid = 'public.exos_account_tokens'::regclass), 'FA1 RLS on';
  ASSERT (SELECT key_hash FROM public.exos_account_tokens WHERE id = pg_temp.v('f2.id')::uuid) = pg_temp.h(pg_temp.v('f2')),
    'FA1 only the hash is stored';
  RAISE NOTICE 'OK  FA1 grants';
END $$;

-- FA2 ------------------------------------------------------------------------
DO $$
DECLARE r text; s text;
BEGIN
  ASSERT public.exos_api_scope_names() @> ARRAY['me:read', 'me:write'], 'FA2 vocabulary';
  ASSERT (public.exos_api_scope_names())[cardinality(public.exos_api_scope_names())] = 'org:admin', 'FA2 org:admin last';
  FOREACH r IN ARRAY ARRAY['owner', 'manager', 'finance', 'content', 'scanner'] LOOP
    ASSERT public.exos_role_token_scopes(r) @> ARRAY['me:read', 'me:write'], 'FA2 every role''s tokens: ' || r;
    ASSERT NOT (public._exos_org_role_scopes('f5000000-0000-0000-0000-000000000001', r, true) && ARRAY['me:read', 'me:write']),
      'FA2 never a key''s: ' || r;
  END LOOP;
  ASSERT NOT (public._exos_org_scope_vocab() && ARRAY['me:read', 'me:write']), 'FA2 not org-configurable';
  s := pg_temp.st($q$INSERT INTO public.exos_api_keys (org_id, name, key_prefix, key_hash, scopes, created_by)
    VALUES ('f5000000-0000-0000-0000-000000000001', 'x', 'sk_live_x', repeat('a', 64), ARRAY['me:read'],
            'f5000000-0000-0000-0000-0000000000a1')$q$);
  ASSERT s LIKE '22023%user tokens%', 'FA2 an org key can''t carry me:read: ' || s;
  s := pg_temp.st($q$UPDATE public.exos_api_keys SET scopes = scopes || ARRAY['me:write'] WHERE id = 'f5000000-0000-0000-0000-0000000000f1'$q$);
  ASSERT s LIKE '22023%', 'FA2 nor gain it: ' || s;
  -- A role's org set built from the token default drops the user scopes.
  PERFORM pg_temp.act(pg_temp.u('a1'));
  PERFORM public.exos_org_role_scopes_set('f5000000-0000-0000-0000-000000000001', 'scanner', public.exos_role_token_scopes('scanner'));
  ASSERT (SELECT scopes FROM public.exos_org_role_scopes WHERE org_id = 'f5000000-0000-0000-0000-000000000001' AND role = 'scanner')
         = ARRAY['events:read', 'tickets:read', 'checkin:write'], 'FA2 configured set holds no me:*';
  ASSERT public._exos_org_role_scopes('f5000000-0000-0000-0000-000000000001', 'scanner') @> ARRAY['me:read', 'me:write'],
    'FA2 a scanner''s token keeps me:*';
  PERFORM public.exos_org_role_scopes_reset('f5000000-0000-0000-0000-000000000001', 'scanner');
  -- Account tokens are me:* only.
  PERFORM pg_temp.act(pg_temp.u('b2'));
  s := pg_temp.st($q$SELECT public.exos_create_account_token('x', ARRAY['events:read'], 30)$q$);
  ASSERT s LIKE '22023%invalid_scope%', 'FA2 account token org scope: ' || s;
  s := pg_temp.st($q$SELECT public.exos_create_account_token('x', ARRAY['me:read'], 7)$q$);
  ASSERT s LIKE '22023%expires_days%', 'FA2 account token expiry: ' || s;
  PERFORM pg_temp.act(NULL);
  s := pg_temp.st($q$SELECT public.exos_create_account_token('x', ARRAY['me:read'], 30)$q$);
  ASSERT s LIKE '42501%', 'FA2 signed out: ' || s;
  RAISE NOTICE 'OK  FA2 me:* are user scopes';
END $$;

-- FA3 ------------------------------------------------------------------------
DO $$
DECLARE v jsonb; s text;
BEGIN
  PERFORM pg_temp.act(NULL);
  -- An org API key has no user, by kind or by hash.
  s := pg_temp.st($q$SELECT public.exos_api_me(encode(extensions.digest('sk_live_f5_k1', 'sha256'), 'hex'), 'api_key', 'profile.get')$q$);
  ASSERT s LIKE '42501%personal access token%', 'FA3 api key kind: ' || s;
  s := pg_temp.st($q$SELECT public.exos_api_me(encode(extensions.digest('sk_live_f5_k1', 'sha256'), 'hex'), 'pat', 'profile.get')$q$);
  ASSERT s LIKE '42501%invalid or revoked%', 'FA3 api key hash: ' || s;
  s := pg_temp.st($q$SELECT public.exos_api_me(repeat('0', 64), 'oauth', 'profile.get')$q$);
  ASSERT s LIKE '42501%', 'FA3 unknown oauth: ' || s;
  s := pg_temp.st($q$SELECT public.exos_api_me('nothex', 'pat', 'profile.get')$q$);
  ASSERT s LIKE '42501%', 'FA3 malformed: ' || s;
  s := pg_temp.mes('f2', 'no.such.action');
  ASSERT s LIKE '22023%unknown action%', 'FA3 unknown action: ' || s;
  -- A fan's account token and the owner's personal token act as their user.
  v := pg_temp.me('f2', 'profile.get');
  ASSERT v->>'id' = pg_temp.u('b2') AND v->>'email' = 'f5-fan@x.com', 'FA3 account token profile: ' || v::text;
  v := pg_temp.me('o1', 'profile.get');
  ASSERT v->>'id' = pg_temp.u('a1'), 'FA3 personal token profile';
  -- Scopes: read-only can't write; a token without me:* can't call /v1/me.
  s := pg_temp.mes('f2r', 'marketing.set', NULL, '{"marketing_emails": false}');
  ASSERT s LIKE '42501%me:write%', 'FA3 me:read can''t write: ' || s;
  ASSERT pg_temp.mes('f2r', 'tickets.list') = 'ok', 'FA3 me:read reads';
  s := pg_temp.mes('o1org', 'profile.get');
  ASSERT s LIKE '42501%me:read%', 'FA3 org-only token: ' || s;
  -- The claims are put back after the call.
  ASSERT coalesce(current_setting('request.jwt.claim.sub', true), '') = '', 'FA3 claims restored';
  -- Revoked and expired tokens stop at once.
  UPDATE public.exos_account_tokens SET expires_at = now() - interval '1 second' WHERE id = (
    SELECT id FROM public.exos_account_tokens WHERE key_hash = pg_temp.h(pg_temp.v('f2r')));
  s := pg_temp.mes('f2r', 'tickets.list');
  ASSERT s LIKE '42501%invalid or revoked%', 'FA3 expired: ' || s;
  ASSERT public.exos_api_account_token_auth(pg_temp.h(pg_temp.v('f2r'))) IS NULL, 'FA3 expired auth';
  v := public.exos_api_account_token_auth(pg_temp.h(pg_temp.v('f2')));
  ASSERT v->>'org_id' IS NULL AND (v->>'account')::boolean AND v->>'user_id' = pg_temp.u('b2'), 'FA3 account auth: ' || v::text;
  -- A personal token's user who left the org is refused (and offboarding
  -- revokes the token for good).
  ASSERT pg_temp.me('s1', 'profile.get')->>'id' = pg_temp.u('a3'), 'FA3 a scanner''s token has me:read';
  UPDATE public.exos_org_memberships SET disabled = true
   WHERE org_id = 'f5000000-0000-0000-0000-000000000001' AND user_id = pg_temp.u('a3')::uuid;
  s := pg_temp.mes('s1', 'profile.get');
  ASSERT s LIKE '42501%', 'FA3 left the org: ' || s;
  UPDATE public.exos_org_memberships SET disabled = false
   WHERE org_id = 'f5000000-0000-0000-0000-000000000001' AND user_id = pg_temp.u('a3')::uuid;
  RAISE NOTICE 'OK  FA3 token types and scopes';
END $$;

-- FA4 ------------------------------------------------------------------------
DO $$
DECLARE v jsonb; s text;
BEGIN
  v := pg_temp.me('f2', 'tickets.list');
  ASSERT (v->>'total')::int = 2 AND jsonb_array_length(v->'rows') = 2, 'FA4 own tickets: ' || v::text;
  ASSERT NOT (v::text LIKE '%' || pg_temp.u('c3') || '%'), 'FA4 never another''s ticket';
  ASSERT NOT (v::text LIKE '%f5-other@x.com%'), 'FA4 never another''s email';
  v := pg_temp.me('f2', 'tickets.list', NULL, '{"limit": 1, "offset": 1}');
  ASSERT jsonb_array_length(v->'rows') = 1 AND (v->>'total')::int = 2, 'FA4 paged';
  s := pg_temp.mes('f2', 'ticket.get', pg_temp.u('c3'));
  ASSERT s LIKE 'P0002%', 'FA4 another''s ticket: ' || s;
  v := pg_temp.me('f2', 'orders.list');
  ASSERT (v->>'total')::int = 1 AND v #>> '{rows,0,id}' = 'cs_f5_fan', 'FA4 own orders: ' || v::text;
  s := pg_temp.mes('f2', 'order.get', 'cs_f5_other');
  ASSERT s LIKE 'P0002%', 'FA4 another''s order: ' || s;
  s := pg_temp.mes('f2', 'order.transferable', 'cs_f5_other');
  ASSERT s LIKE 'P0002%', 'FA4 another''s order transfers: ' || s;
  s := pg_temp.mes('f2', 'order.refund_asks', 'cs_f5_other');
  ASSERT s LIKE 'P0002%', 'FA4 another''s refund request: ' || s;
  v := pg_temp.me('f2', 'order.get', 'cs_f5_fan');
  ASSERT (v->>'tickets_count')::int = 2 AND jsonb_array_length(v->'tickets_held') = 2, 'FA4 order detail';
  -- A ticket of someone else's order can't ride along on one's own order.
  s := pg_temp.mes('f2', 'order.transfer', 'cs_f5_fan',
    jsonb_build_object('email', 'x@x.com', 'ticket_ids', jsonb_build_array(pg_temp.u('c3'))));
  ASSERT s LIKE '22023%not part of this order%', 'FA4 foreign ticket in an order transfer: ' || s;
  s := pg_temp.mes('f2', 'transfers.create', NULL,
    jsonb_build_object('items', jsonb_build_array(jsonb_build_object('ticket_id', pg_temp.u('c3'), 'email', 'x@x.com'))));
  ASSERT s <> 'ok', 'FA4 transferring another''s ticket: ' || s;
  ASSERT (SELECT owner_id FROM public.exos_tickets WHERE id = pg_temp.u('c3')::uuid) = pg_temp.u('b3')::uuid
     AND (SELECT pending_transfer_id FROM public.exos_tickets WHERE id = pg_temp.u('c3')::uuid) IS NULL, 'FA4 untouched';
  v := pg_temp.me('f3', 'bundles.list');
  ASSERT NOT (v::text LIKE '%' || pg_temp.u('c1') || '%'), 'FA4 bundles are one''s own';
  s := pg_temp.mes('f2', 'refund.withdraw', gen_random_uuid()::text);
  ASSERT s LIKE 'P0002%', 'FA4 someone else''s / no refund request: ' || s;
  ASSERT jsonb_array_length(pg_temp.me('f2', 'memberships.list')) = 0, 'FA4 no memberships';
  s := pg_temp.mes('f2', 'membership.get', gen_random_uuid()::text);
  ASSERT s LIKE 'P0002%', 'FA4 membership not found: ' || s;
  RAISE NOTICE 'OK  FA4 cross-user isolation';
END $$;

-- FA5 ------------------------------------------------------------------------
DO $$
DECLARE v jsonb; b bigint;
BEGIN
  v := pg_temp.me('f2', 'ticket.get', pg_temp.u('c1'));
  b := floor(extract(epoch FROM clock_timestamp()) / 30)::bigint;
  ASSERT v #>> '{barcode,value}' LIKE 'T-' || pg_temp.u('c1') || ':' || pg_temp.u('b2') || ':%', 'FA5 rotating code: ' || v::text;
  ASSERT split_part(v #>> '{barcode,value}', ':', 3)::bigint BETWEEN b - 1 AND b, 'FA5 the current 30-second bucket';
  ASSERT split_part(v #>> '{barcode,value}', ':', 4) = public._exos_door_code_mac(pg_temp.u('c1')::uuid, pg_temp.u('b2')::uuid,
           split_part(v #>> '{barcode,value}', ':', 3)::bigint, 'sek-f5-c1'), 'FA5 signed with the day key';
  ASSERT NOT (v::text LIKE '%sek-f5%'), 'FA5 never the barcode secret';
  ASSERT NOT (pg_temp.me('f2', 'tickets.list')::text LIKE '%sek-f5%') AND NOT (pg_temp.me('f2', 'tickets.list')::text LIKE '%"barcode"%'),
    'FA5 lists carry no code';
  ASSERT NOT (pg_temp.me('f2', 'order.get', 'cs_f5_fan')::text LIKE '%sek-f5%'), 'FA5 orders carry no secret';
  UPDATE public.exos_tickets SET status = 'used' WHERE id = pg_temp.u('c2')::uuid;
  v := pg_temp.me('f2', 'ticket.get', pg_temp.u('c2'));
  ASSERT v->'barcode' = 'null'::jsonb AND v->>'barcode_unavailable' = 'not_active', 'FA5 used ticket: ' || v::text;
  UPDATE public.exos_tickets SET status = 'active' WHERE id = pg_temp.u('c2')::uuid;
  RAISE NOTICE 'OK  FA5 barcodes';
END $$;

-- FA6 ------------------------------------------------------------------------
DO $$
DECLARE v jsonb; s text; v_tr uuid; v_key text;
BEGIN
  v := pg_temp.me('f2', 'transfers.create', NULL, jsonb_build_object('items', jsonb_build_array(
         jsonb_build_object('ticket_id', pg_temp.u('c1'), 'email', 'f5-other@x.com', 'name', 'Other'))));
  v_tr := (v #>> '{transfers,0,transfer_id}')::uuid;
  v_key := v #>> '{transfers,0,claim_key}';
  ASSERT v_tr IS NOT NULL AND v_key IS NOT NULL, 'FA6 started: ' || v::text;
  -- The lock: in a transfer, no barcode and no second transfer.
  v := pg_temp.me('f2', 'ticket.get', pg_temp.u('c1'));
  ASSERT (v->>'in_transfer')::boolean AND v->>'barcode_unavailable' = 'in_transfer', 'FA6 locked: ' || v::text;
  s := pg_temp.mes('f2', 'transfers.create', NULL, jsonb_build_object('items', jsonb_build_array(
         jsonb_build_object('ticket_id', pg_temp.u('c1'), 'email', 'z@x.com'))));
  ASSERT s <> 'ok', 'FA6 a second transfer: ' || s;
  BEGIN
    v := pg_temp.me('f2', 'wallet.ticket', pg_temp.u('c1'), '{"kind": "apple"}');
    ASSERT NOT coalesce((v->>'ok')::boolean, false), 'FA6 no wallet pass in a transfer: ' || v::text;
  EXCEPTION WHEN assert_failure THEN RAISE;
            WHEN others THEN NULL;  -- refused outright is fine too
  END;
  -- The receiver sees it; a stranger can't cancel it; a wrong key can't claim it.
  v := pg_temp.me('f3', 'transfers.list');
  ASSERT v @> jsonb_build_array(jsonb_build_object('id', v_tr, 'direction', 'received')), 'FA6 received: ' || v::text;
  ASSERT NOT (v::text LIKE '%claim_key%'), 'FA6 the list never carries a claim key';
  s := pg_temp.mes('f3', 'transfer.cancel', v_tr::text);
  ASSERT s LIKE 'P0002%', 'FA6 only the sender cancels: ' || s;
  s := pg_temp.mes('f3', 'transfer.claim', v_tr::text, jsonb_build_object('key', 'wrong-key-0123456789'));
  ASSERT s <> 'ok', 'FA6 wrong claim key: ' || s;
  ASSERT (SELECT owner_id FROM public.exos_tickets WHERE id = pg_temp.u('c1')::uuid) = pg_temp.u('b2')::uuid, 'FA6 still the sender''s';
  -- Cancel, start again, then the receiver claims with the key.
  v := pg_temp.me('f2', 'transfer.cancel', v_tr::text);
  ASSERT v->>'status' = 'cancelled', 'FA6 cancelled';
  ASSERT (SELECT pending_transfer_id FROM public.exos_tickets WHERE id = pg_temp.u('c1')::uuid) IS NULL, 'FA6 unlocked';
  v := pg_temp.me('f2', 'order.transfer', 'cs_f5_fan', jsonb_build_object('email', 'f5-other@x.com',
         'ticket_ids', jsonb_build_array(pg_temp.u('c1'))));
  v_tr := (v #>> '{transfers,0,transfer_id}')::uuid;
  v_key := v #>> '{transfers,0,claim_key}';
  v := pg_temp.me('f3', 'transfer.claim', v_tr::text, jsonb_build_object('key', v_key));
  ASSERT v->>'id' = pg_temp.u('c1'), 'FA6 claimed: ' || coalesce(v::text, 'null');
  ASSERT (SELECT owner_id FROM public.exos_tickets WHERE id = pg_temp.u('c1')::uuid) = pg_temp.u('b3')::uuid, 'FA6 now the receiver''s';
  ASSERT (pg_temp.me('f2', 'tickets.list')->>'total')::int = 1, 'FA6 gone from the sender';
  s := pg_temp.mes('f2', 'ticket.get', pg_temp.u('c1'));
  ASSERT s LIKE 'P0002%', 'FA6 the sender can''t read it any more: ' || s;
  -- The buyer's order still lists it as sold, not held.
  v := pg_temp.me('f2', 'order.get', 'cs_f5_fan');
  ASSERT (v->>'tickets_count')::int = 2 AND jsonb_array_length(v->'tickets_held') = 1, 'FA6 order after: ' || v::text;
  RAISE NOTICE 'OK  FA6 transfers keep their rules';
END $$;

-- FA7 ------------------------------------------------------------------------
DO $$
DECLARE v jsonb; s text;
BEGIN
  v := pg_temp.me('f2', 'refund.ask', NULL, jsonb_build_object('ticket_ids', jsonb_build_array(pg_temp.u('c3')), 'reason', 'x'));
  ASSERT v->0->>'reason' = 'not-buyer' AND NOT (v->0->>'ok')::boolean, 'FA7 not one''s own: ' || v::text;
  s := pg_temp.mes('f2', 'order.refund_ask', 'cs_f5_other', '{}');
  ASSERT s LIKE 'P0002%', 'FA7 another''s order: ' || s;
  s := pg_temp.mes('f2', 'refund.ask', NULL, '{}');
  ASSERT s LIKE '22023%ticket_ids%', 'FA7 says which tickets: ' || s;
  v := pg_temp.me('f2', 'order.refund_ask', 'cs_f5_fan', '{"reason": "can''t go"}');
  ASSERT jsonb_typeof(v) = 'array' AND v->0->>'ticket_id' = pg_temp.u('c2'), 'FA7 the order''s held tickets: ' || v::text;
  ASSERT jsonb_typeof(pg_temp.me('f2', 'refund_asks.list')) = 'array', 'FA7 list';
  -- Profile and marketing preferences.
  v := pg_temp.me('f2', 'marketing.set', NULL, '{"marketing_emails": false}');
  ASSERT v->>'marketing_emails' = 'false', 'FA7 opted out: ' || v::text;
  ASSERT (pg_temp.me('f2', 'profile.get')->>'marketing_emails')::boolean = false, 'FA7 profile shows it';
  ASSERT (pg_temp.me('f3', 'profile.get')->>'marketing_emails')::boolean = true, 'FA7 nobody else''s';
  s := pg_temp.mes('f2', 'marketing.set', NULL, '{"marketing_emails": "no"}');
  ASSERT s LIKE '22023%', 'FA7 a boolean: ' || s;
  s := pg_temp.mes('f2', 'profile.update', NULL, '{"email": "evil@x.com"}');
  ASSERT s LIKE '22023%display_name%', 'FA7 email isn''t changed here: ' || s;
  ASSERT (SELECT email FROM auth.users WHERE id = pg_temp.u('b2')::uuid) = 'f5-fan@x.com', 'FA7 email kept';
  RAISE NOTICE 'OK  FA7 refund requests and preferences';
END $$;

-- FA8 ------------------------------------------------------------------------
DO $$
DECLARE v jsonb; s text; v_exp timestamptz;
BEGIN
  -- An account token mints an account token within its own scopes and life.
  v := pg_temp.me('f2', 'token.create', NULL, '{"name": "phone", "scopes": ["me:read"], "expires_days": 365}');
  ASSERT v->>'kind' = 'account' AND v->>'token' LIKE 'exos_pat_%', 'FA8 minted: ' || v::text;
  INSERT INTO f5 VALUES ('f2m', v->>'token');
  SELECT expires_at INTO v_exp FROM public.exos_account_tokens WHERE key_hash = pg_temp.h(pg_temp.v('f2'));
  ASSERT (v->>'expires_at')::timestamptz <= v_exp, 'FA8 never outlives its maker';
  ASSERT (SELECT expires_at FROM public.exos_account_tokens WHERE key_hash = pg_temp.h(v->>'token')) <= v_exp, 'FA8 stored clamp';
  ASSERT pg_temp.mes('f2m', 'tickets.list') = 'ok', 'FA8 new token reads';
  s := pg_temp.mes('f2m', 'marketing.set', NULL, '{"marketing_emails": true}');
  ASSERT s LIKE '42501%', 'FA8 new token can''t write: ' || s;
  s := pg_temp.mes('f2m', 'token.create', NULL, '{"scopes": ["me:write"]}');
  ASSERT s LIKE '42501%', 'FA8 a read token can''t mint (me:write): ' || s;
  s := pg_temp.mes('f2', 'token.create', NULL, '{"scopes": ["events:read"]}');
  ASSERT s LIKE '42501%can''t grant%', 'FA8 above its scopes: ' || s;
  -- A personal token mints a personal token for its org, within its scopes.
  v := pg_temp.me('o1', 'token.create', NULL, '{"name": "ci", "scopes": ["events:read", "me:read"], "expires_days": 30}');
  ASSERT v->>'kind' = 'personal' AND v->>'org_id' = 'f5000000-0000-0000-0000-000000000001', 'FA8 personal: ' || v::text;
  ASSERT (SELECT org_id FROM public.exos_personal_tokens WHERE key_hash = pg_temp.h(v->>'token'))
         = 'f5000000-0000-0000-0000-000000000001', 'FA8 same org';
  s := pg_temp.mes('o1', 'token.create', NULL, '{"scopes": ["org:admin"]}');
  ASSERT s LIKE '42501%org:admin%', 'FA8 personal above its scopes: ' || s;
  -- An app (OAuth kind) never manages tokens.
  s := pg_temp.mes('o1', 'token.create', NULL, '{"scopes": ["me:read"]}', 'oauth');
  ASSERT s LIKE '42501%', 'FA8 oauth: ' || s;
  -- Listing and revoking: one's own only, never a hash.
  v := pg_temp.me('f2', 'tokens.list');
  ASSERT jsonb_array_length(v) >= 2 AND NOT (v::text LIKE '%key_hash%') AND NOT (v::text LIKE '%' || pg_temp.v('f2') || '%'),
    'FA8 list: ' || v::text;
  ASSERT v @> jsonb_build_array(jsonb_build_object('id', pg_temp.v('f2.id'), 'current', true)), 'FA8 current marked';
  s := pg_temp.mes('f2', 'token.revoke', pg_temp.v('f3.id'));
  ASSERT s LIKE 'P0002%', 'FA8 another user''s token: ' || s;
  ASSERT (SELECT revoked_at FROM public.exos_account_tokens WHERE id = pg_temp.v('f3.id')::uuid) IS NULL, 'FA8 untouched';
  s := pg_temp.mes('f2', 'token.revoke', pg_temp.v('o1.id'));
  ASSERT s LIKE 'P0002%', 'FA8 another user''s personal token: ' || s;
  v := pg_temp.me('f2', 'token.revoke', (SELECT id::text FROM public.exos_account_tokens WHERE key_hash = pg_temp.h(pg_temp.v('f2m'))));
  ASSERT (v->>'revoked')::boolean, 'FA8 revoked';
  s := pg_temp.mes('f2m', 'tickets.list');
  ASSERT s LIKE '42501%', 'FA8 revoked token stops: ' || s;
  -- Self-revoke (DELETE /v1/personal-access-tokens/current) for an account token.
  ASSERT public._exos_account_token_revoke_self(pg_temp.v('f3.id')::uuid), 'FA8 self revoke';
  ASSERT NOT public._exos_account_token_revoke_self(pg_temp.v('f3.id')::uuid), 'FA8 twice';
  s := pg_temp.mes('f3', 'tickets.list');
  ASSERT s LIKE '42501%', 'FA8 after self revoke: ' || s;
  -- At most 10 active account tokens.
  PERFORM pg_temp.act(pg_temp.u('b2'));
  FOR i IN 1..10 LOOP
    s := pg_temp.st($q$SELECT public.exos_create_account_token('n', ARRAY['me:read'], 30)$q$);
  END LOOP;
  ASSERT s LIKE '54000%', 'FA8 cap: ' || s;
  PERFORM pg_temp.act(NULL);
  RAISE NOTICE 'OK  FA8 tokens';
END $$;

-- FA9 ------------------------------------------------------------------------
DO $$
DECLARE v jsonb; s text; v_sid uuid; v_rule uuid; v_n int;
BEGIN
  PERFORM pg_temp.act(NULL);
  ASSERT public._exos_api_gap_action_roles('api_key.create') = ARRAY['owner'], 'FA9 keys: owner';
  ASSERT public._exos_api_gap_action_roles('membership.scan') = ARRAY['owner', 'manager', 'scanner'], 'FA9 scans: door';
  ASSERT public._exos_api_gap_action_roles('series.create') = ARRAY['owner', 'manager'], 'FA9 series';
  ASSERT public._exos_api_gap_action_roles('nope') IS NULL, 'FA9 unknown';
  -- Series on the key's org only.
  v := pg_temp.gap('sk_live_f5_k1', 'series.create', NULL, jsonb_build_object('template_event_id', pg_temp.u('e1'),
         'name', 'F5 Fridays', 'rule', jsonb_build_object('freq', 'weekly', 'startDate', to_char(current_date + 14, 'YYYY-MM-DD'), 'time', '20:00')));
  v_sid := (v->>'id')::uuid;
  ASSERT v_sid IS NOT NULL AND v->>'org_id' = 'f5000000-0000-0000-0000-000000000001', 'FA9 series created: ' || v::text;
  s := pg_temp.gaps('sk_live_f5_k3', 'series.update', v_sid::text, '{"name": "Mine now"}');
  ASSERT s LIKE 'P0002%', 'FA9 another org''s series: ' || s;
  s := pg_temp.gaps('sk_live_f5_k1', 'series.create', NULL, jsonb_build_object('template_event_id', pg_temp.u('e3'),
         'name', 'X', 'rule', '{"freq": "weekly"}'::jsonb));
  ASSERT s LIKE 'P0002%', 'FA9 another org''s event: ' || s;
  s := pg_temp.gaps('sk_live_f5_k4', 'series.update', v_sid::text, '{"name": "x"}');
  ASSERT s LIKE '42501%events:write%', 'FA9 the key''s scope: ' || s;
  v := pg_temp.gap('sk_live_f5_k2', 'series.update', v_sid::text, '{"name": "F5 Fridays Live"}');
  ASSERT v #>> '{series,name}' = 'F5 Fridays Live', 'FA9 manager key updates: ' || v::text;
  -- The key's scopes NOW: the owner takes events:write from managers.
  PERFORM pg_temp.act(pg_temp.u('a1'));
  PERFORM public.exos_org_role_scopes_set('f5000000-0000-0000-0000-000000000001', 'manager', ARRAY['events:read', 'commerce:write']);
  PERFORM pg_temp.act(NULL);
  s := pg_temp.gaps('sk_live_f5_k2', 'series.update', v_sid::text, '{"name": "x"}');
  ASSERT s LIKE '42501%events:write%', 'FA9 narrowed at once: ' || s;
  PERFORM pg_temp.act(pg_temp.u('a1'));
  PERFORM public.exos_org_role_scopes_reset('f5000000-0000-0000-0000-000000000001', 'manager');
  PERFORM pg_temp.act(NULL);
  -- The creator's role NOW: demoted to scanner, the key can't run a series write.
  UPDATE public.exos_org_memberships SET role = 'scanner'
   WHERE org_id = 'f5000000-0000-0000-0000-000000000001' AND user_id = pg_temp.u('a2')::uuid;
  s := pg_temp.gaps('sk_live_f5_k2', 'series.update', v_sid::text, '{"name": "x"}');
  ASSERT s LIKE '42501%', 'FA9 a demoted creator: ' || s;
  UPDATE public.exos_org_memberships SET role = 'manager'
   WHERE org_id = 'f5000000-0000-0000-0000-000000000001' AND user_id = pg_temp.u('a2')::uuid;
  -- Fee rules (Opendate organizer_fee_components) on the key's event.
  v := pg_temp.gap('sk_live_f5_k1', 'fee_rule.create', pg_temp.u('e1'),
         '{"name": "Facility", "calc": "fixed", "amount_cents": 150, "kind": "passed_on"}');
  v_rule := (v->>'id')::uuid;
  ASSERT v->>'amount_cents' = '150' AND v->>'event_id' = pg_temp.u('e1'), 'FA9 fee rule: ' || v::text;
  v := pg_temp.gap('sk_live_f5_k1', 'fee_rule.update', pg_temp.u('e1'), jsonb_build_object('rule_id', v_rule, 'amount_cents', 200));
  ASSERT v->>'amount_cents' = '200' AND v->>'name' = 'Facility', 'FA9 fee rule updated: ' || v::text;
  s := pg_temp.gaps('sk_live_f5_k1', 'fee_rule.update', pg_temp.u('e1'), jsonb_build_object('rule_id', v_rule, 'org_id', gen_random_uuid()));
  ASSERT s LIKE '22023%read-only%', 'FA9 fee rule org can''t move: ' || s;
  s := pg_temp.gaps('sk_live_f5_k3', 'fee_rule.delete', pg_temp.u('e1'), jsonb_build_object('rule_id', v_rule));
  ASSERT s LIKE 'P0002%', 'FA9 another org''s fee rule: ' || s;
  v := pg_temp.gap('sk_live_f5_k1', 'fee_rule.delete', pg_temp.u('e1'), jsonb_build_object('rule_id', v_rule));
  ASSERT (v->>'deleted')::boolean AND NOT EXISTS (SELECT 1 FROM public.exos_fee_rules WHERE id = v_rule), 'FA9 deleted';
  -- API keys: owner keys only, never above the making key, plaintext never logged.
  s := pg_temp.gaps('sk_live_f5_k2', 'api_key.create', NULL, '{"scopes": ["events:read"]}');
  ASSERT s LIKE '42501%', 'FA9 a manager''s key can''t mint keys: ' || s;
  s := pg_temp.gaps('sk_live_f5_k1', 'api_key.create', NULL, '{"scopes": ["finance:write"]}');
  ASSERT s LIKE '42501%can''t grant%', 'FA9 above the making key: ' || s;
  s := pg_temp.gaps('sk_live_f5_k1', 'api_key.create', NULL, '{"scopes": ["me:read"]}');
  ASSERT s LIKE '42501%', 'FA9 never a user scope: ' || s;
  v := pg_temp.gap('sk_live_f5_k1', 'api_key.create', NULL, '{"name": "ci", "scopes": ["events:read"]}', 'f5-key-create-1');
  ASSERT v->>'key' LIKE 'sk_live_%' AND v->>'org_id' IS NULL, 'FA9 key minted: ' || v::text;
  INSERT INTO f5 VALUES ('newkey', v->>'key'), ('newkey.id', v->>'id');
  ASSERT (SELECT org_id FROM public.exos_api_keys WHERE id = (v->>'id')::uuid) = 'f5000000-0000-0000-0000-000000000001', 'FA9 in the org';
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_api_writes WHERE api_key_id = 'f5000000-0000-0000-0000-0000000000f1'
                       AND result::text LIKE '%' || pg_temp.v('newkey') || '%'), 'FA9 the plaintext is never logged';
  v := pg_temp.gap('sk_live_f5_k1', 'api_key.create', NULL, '{"name": "ci", "scopes": ["events:read"]}', 'f5-key-create-1');
  ASSERT (v->>'idempotent_replay')::boolean AND v->>'key' IS NULL, 'FA9 a replay never shows the key again: ' || v::text;
  s := pg_temp.gaps('sk_live_f5_k3', 'api_key.revoke', pg_temp.v('newkey.id'));
  ASSERT s LIKE 'P0002%', 'FA9 another org''s key: ' || s;
  v := pg_temp.gap('sk_live_f5_k1', 'api_key.revoke', pg_temp.v('newkey.id'));
  ASSERT (v->>'revoked')::boolean, 'FA9 revoked';
  -- Seats, migrated attendees, scans, gifts, donations stay pinned to the org.
  s := pg_temp.gaps('sk_live_f5_k3', 'seats.release_orphans', pg_temp.u('e1'), '{"seat_ids": ["A-1"]}');
  ASSERT s LIKE 'P0002%', 'FA9 another org''s seats: ' || s;
  s := pg_temp.gaps('sk_live_f5_k1', 'migrated_attendees.bulk', NULL, jsonb_build_object('list_id', gen_random_uuid(),
         'rows', '[{"name": "A"}]'::jsonb));
  ASSERT s LIKE 'P0002%', 'FA9 a guest list of the org: ' || s;
  s := pg_temp.gaps('sk_live_f5_k1', 'membership.gift', gen_random_uuid()::text, '{"to_email": "g@x.com"}');
  ASSERT s LIKE 'P0002%', 'FA9 membership product: ' || s;
  s := pg_temp.gaps('sk_live_f5_k1', 'donation.offline', gen_random_uuid()::text, '{"amount_cents": 500}');
  ASSERT s LIKE 'P0002%', 'FA9 giving campaign: ' || s;
  s := pg_temp.gaps('sk_live_f5_k1', 'gift_card.issue', gen_random_uuid()::text, '{"amount_cents": 500, "recipient_email": "g@x.com"}');
  ASSERT s LIKE 'P0002%', 'FA9 gift card product: ' || s;
  s := pg_temp.gaps('sk_live_f5_k1', 'nope');
  ASSERT s LIKE '22023%unknown action%', 'FA9 unknown action: ' || s;
  -- Every write is logged against the key.
  SELECT count(*) INTO v_n FROM public.exos_api_writes WHERE api_key_id = 'f5000000-0000-0000-0000-0000000000f1';
  ASSERT v_n >= 5, 'FA9 logged: ' || v_n;
  RAISE NOTICE 'OK  FA9 org writes';
END $$;

-- FA10 -----------------------------------------------------------------------
DO $$
DECLARE v jsonb; s text;
BEGIN
  v := public._exos_api_public('events.list', NULL, '{}', 'net:f5');
  ASSERT v->'rows' @> jsonb_build_array(jsonb_build_object('id', pg_temp.u('e1'))), 'FA10 published listed: ' || v::text;
  ASSERT NOT (v::text LIKE '%' || pg_temp.u('e2') || '%'), 'FA10 never a draft';
  ASSERT NOT (v::text ~ '"(capacity|sold|tickets_sold|total_tickets|buyer_email|status)"'), 'FA10 no counts: ' || v::text;
  v := public._exos_api_public('events.list', NULL, jsonb_build_object('venue', 'f5-hall'), 'net:f5');
  ASSERT (v->>'total')::int = 1 AND v #>> '{rows,0,org,slug}' = 'f5-hall', 'FA10 by organizer: ' || v::text;
  v := public._exos_api_public('event.get', pg_temp.u('e1'), '{}', 'net:f5');
  ASSERT v #>> '{ticket_types,0,name}' = 'GA' AND (v #>> '{ticket_types,0,price}')::numeric = 25, 'FA10 detail: ' || v::text;
  ASSERT NOT ((v->'ticket_types'->0) ?| ARRAY['capacity', 'sold']), 'FA10 no tier counts';
  s := pg_temp.st(format($q$SELECT public._exos_api_public('event.get', %L, '{}', 'net:f5')$q$, pg_temp.u('e2')));
  ASSERT s LIKE 'P0002%', 'FA10 draft detail: ' || s;
  v := public._exos_api_public('venues.list', NULL, '{}', 'net:f5');
  ASSERT v->'rows' @> jsonb_build_array(jsonb_build_object('slug', 'f5-hall')) AND NOT (v::text LIKE '%owner_uid%'), 'FA10 venues: ' || v::text;
  v := public._exos_api_public('venue.get', 'f5-hall', '{}', 'net:f5');
  ASSERT v->>'id' = 'f5000000-0000-0000-0000-000000000001' AND jsonb_array_length(v->'upcoming_events') = 1, 'FA10 venue: ' || v::text;
  v := public._exos_api_public('search', NULL, '{"q": "F5 Li"}', 'net:f5');
  ASSERT v->'events' @> jsonb_build_array(jsonb_build_object('id', pg_temp.u('e1'))), 'FA10 search: ' || v::text;
  s := pg_temp.st($q$SELECT public._exos_api_public('search', NULL, '{"q": "%"}', 'net:f5')$q$);
  ASSERT s LIKE '22023%', 'FA10 a wildcard isn''t a search: ' || s;
  v := public._exos_api_public('search', NULL, '{"q": "F5_%Li"}', 'net:f5');
  ASSERT jsonb_typeof(v->'events') = 'array', 'FA10 LIKE characters are dropped';
  ASSERT public._exos_api_public('series.list', NULL, '{"venue": "f5-hall"}', 'net:f5') IS NOT NULL, 'FA10 series';
  s := pg_temp.st($q$SELECT public._exos_api_public('series.list', NULL, '{}', 'net:f5')$q$);
  ASSERT s LIKE '22023%venue_id%', 'FA10 series need an organizer: ' || s;
  s := pg_temp.st($q$SELECT public._exos_api_public('venue.get', 'no-such-org', '{}', 'net:f5')$q$);
  ASSERT s LIKE 'P0002%', 'FA10 unknown venue: ' || s;
  -- 60 a minute per network: the 61st is refused, another network is not.
  INSERT INTO public.exos_rate_windows (bucket, window_start, hits)
  VALUES ('api-public:net:f5-busy', date_trunc('minute', now()), 60)
  ON CONFLICT (bucket, window_start) DO UPDATE SET hits = 60;
  s := pg_temp.st($q$SELECT public._exos_api_public('venues.list', NULL, '{}', 'net:f5-busy')$q$);
  ASSERT s LIKE '54000%', 'FA10 rate limited: ' || s;
  ASSERT pg_temp.st($q$SELECT public._exos_api_public('venues.list', NULL, '{}', 'net:f5-calm')$q$) = 'ok', 'FA10 other network';
  RAISE NOTICE 'OK  FA10 public discovery (core)';
END $$;

-- Anon through the Data API: the bucket is the platform-set IP, not the caller's word.
SELECT set_config('request.headers', '{"cf-connecting-ip": "203.0.113.9"}', true);
SET LOCAL ROLE anon;
DO $$
DECLARE v jsonb; s text;
BEGIN
  v := public.exos_api_public('event.get', 'f5000000-0000-0000-0000-0000000000e1', '{}');
  ASSERT v->>'name' = 'F5 Live', 'FA10 anon detail';
  s := pg_temp.st($q$SELECT public._exos_api_public('events.list', NULL, '{}', 'net:spoof')$q$);
  ASSERT s LIKE '42501%', 'FA10 anon can''t name a bucket: ' || s;
  s := pg_temp.st($q$SELECT public.exos_api_me(repeat('0', 64), 'pat', 'profile.get')$q$);
  ASSERT s LIKE '42501%', 'FA10 anon can''t call /v1/me SQL: ' || s;
END $$;
RESET ROLE;
DO $$
BEGIN
  ASSERT EXISTS (SELECT 1 FROM public.exos_rate_windows WHERE bucket = 'api-public:ip:203.0.113.9'), 'FA10 anon bucket by IP';
  RAISE NOTICE 'OK  FA10 public discovery (anon)';
END $$;

\echo 'test_fan_api: all passed'
ROLLBACK;
