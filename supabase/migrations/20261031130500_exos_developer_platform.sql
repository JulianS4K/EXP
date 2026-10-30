-- ============================================================================
-- Developer platform: personal access tokens and OAuth 2 apps over the partner
-- API (exos-api) and the MCP server (exos-mcp). docs/developer-platform.md.
-- Opendate parity, wave 2.
-- ============================================================================
-- Touches:  C: TABLE exos_personal_tokens (RLS: the user reads their own; no
--              key_hash column grant)
--           C: TABLE exos_oauth_apps (RLS: the developer reads their own; no
--              secret_hash column grant), exos_oauth_grants (RLS: the user
--              reads theirs, org owners their org's), exos_oauth_codes and
--              exos_oauth_tokens (service role only), exos_token_audit (RLS:
--              the user reads theirs, org owners their org's)
--           C: FUNCTION exos_role_token_scopes, _exos_scopes_for_role,
--              _exos_redirect_uri_ok, _exos_mint_secret, _exos_token_audit
--              (internal); exos_create_personal_token, exos_revoke_personal_token,
--              exos_oauth_app_create, exos_oauth_app_update,
--              exos_oauth_app_rotate_secret, exos_oauth_app_delete,
--              exos_oauth_authorize_info, exos_oauth_authorize_approve,
--              exos_oauth_my_grants, exos_oauth_org_grants, exos_oauth_revoke_grant
--              (authenticated, checked against auth.uid()); exos_api_token_auth,
--              exos_oauth_exchange_code, exos_oauth_refresh, exos_oauth_revoke_token,
--              exos_oauth_introspect, exos_oauth_register (service role:
--              exos-api, exos-mcp, exos-oauth)
--           R: FUNCTION exos_tg_membership_offboard (CREATE OR REPLACE: the
--              20260929010000 body, plus a member who leaves or is disabled
--              loses their tokens and OAuth grants for that org)
--           R: exos_org_memberships, exos_orgs, auth.users,
--              exos_api_scope_names / _exos_api_clean_scopes (20261027090000)
-- Pre-reqs: 20261027090000 (scopes), 20260929010000 (offboarding trigger)
--
-- Credentials (prefix + 43 base64url characters = 256 random bits, so an
-- unsalted SHA-256 is enough at rest; the plaintext is shown once):
--   exos_pat_   personal access token: a user, pinned to ONE organization
--   exos_oat_   OAuth access token, 1 hour
--   exos_ort_   OAuth refresh token, 60 days, single use, rotated
--   exos_oac_   OAuth authorization code, 10 minutes, single use
--   exos_cs_    OAuth client secret (confidential apps)
--   exos_app_   OAuth client id (public, not a secret)
--
-- Scopes follow the user's LIVE org role. Every request recomputes what the
-- token may do: its own scopes narrowed to what the user's current role may
-- grant (exos_role_token_scopes; must equal ROLE_SCOPES in
-- supabase/functions/_shared/api/credentials.ts, src/lib/credentials.test.ts
-- checks it). A demotion narrows every token at once; a member who is
-- removed or disabled has their tokens and grants for that org revoked by
-- the offboarding trigger, and until then the membership check refuses them.
--
-- OAuth: authorization code + PKCE (S256; required for public clients),
-- exact redirect URI match, one grant per app x user x org, refresh-token
-- rotation with reuse detection (a refresh token presented twice revokes its
-- whole family), a code presented twice revokes the tokens of its first
-- exchange. Dynamic client registration (RFC 7591) is in SQL here but the
-- exos-oauth function answers it only with EXOS_OAUTH_DCR=on (off by default).
--
-- Re-run safe. Prod apply needs operator OK.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. Shared pieces.
-- ---------------------------------------------------------------------------
-- The most a user in each role can grant a token. Must equal ROLE_SCOPES in
-- _shared/api/credentials.ts.
CREATE OR REPLACE FUNCTION public.exos_role_token_scopes(p_role text)
RETURNS text[] LANGUAGE sql IMMUTABLE SET search_path = public, pg_temp AS $$
  SELECT CASE p_role
    WHEN 'owner' THEN ARRAY['events:read', 'events:write', 'orders:read', 'tickets:read', 'tickets:write',
                            'checkin:write', 'booking:read', 'booking:write', 'finance:read', 'finance:write',
                            'commerce:read', 'commerce:write', 'webhooks:read', 'webhooks:write', 'org:admin']
    WHEN 'manager' THEN ARRAY['events:read', 'events:write', 'orders:read', 'tickets:read', 'tickets:write',
                              'checkin:write', 'booking:read', 'booking:write', 'finance:read', 'finance:write',
                              'commerce:read', 'commerce:write']
    WHEN 'finance' THEN ARRAY['events:read', 'orders:read', 'tickets:read', 'booking:read', 'finance:read',
                              'finance:write', 'commerce:read']
    WHEN 'content' THEN ARRAY['events:read', 'events:write', 'booking:read']
    WHEN 'scanner' THEN ARRAY['events:read', 'tickets:read', 'checkin:write']
    ELSE ARRAY[]::text[]
  END
$$;
REVOKE ALL ON FUNCTION public.exos_role_token_scopes(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.exos_role_token_scopes(text) TO authenticated, service_role;

-- A token's scopes narrowed to a role: kept when the role may use it; a
-- :write the role can't use still gives its :read when the role has that.
CREATE OR REPLACE FUNCTION public._exos_scopes_for_role(p_scopes text[], p_role text)
RETURNS text[] LANGUAGE sql IMMUTABLE SET search_path = public, pg_temp AS $$
  SELECT coalesce(array_agg(n ORDER BY i), '{}')
    FROM unnest(public.exos_api_scope_names()) WITH ORDINALITY v(n, i)
   WHERE n = ANY (public.exos_role_token_scopes(p_role))
     AND (n = ANY (p_scopes) OR (n LIKE '%:read' AND replace(n, ':read', ':write') = ANY (p_scopes)))
$$;
REVOKE ALL ON FUNCTION public._exos_scopes_for_role(text[], text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_scopes_for_role(text[], text) TO service_role;

-- A scope list for a token or an app: the vocabulary only (no legacy `read`).
CREATE OR REPLACE FUNCTION public._exos_token_clean_scopes(p_scopes text[])
RETURNS text[] LANGUAGE plpgsql IMMUTABLE SET search_path = public, pg_temp AS $$
BEGIN
  IF p_scopes IS NOT NULL AND 'read' = ANY (p_scopes) THEN
    RAISE EXCEPTION 'invalid_scope: name scopes such as events:read' USING ERRCODE = '22023';
  END IF;
  RETURN public._exos_api_clean_scopes(p_scopes);
END $$;
REVOKE ALL ON FUNCTION public._exos_token_clean_scopes(text[]) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public._exos_mint_secret(p_prefix text)
RETURNS text LANGUAGE sql VOLATILE SET search_path = public, pg_temp AS $$
  SELECT p_prefix || public._exos_b64url(extensions.gen_random_bytes(32))
$$;
REVOKE ALL ON FUNCTION public._exos_mint_secret(text) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public._exos_sha256(p text)
RETURNS text LANGUAGE sql IMMUTABLE STRICT SET search_path = public, pg_temp AS $$
  SELECT encode(extensions.digest(p, 'sha256'), 'hex')
$$;
REVOKE ALL ON FUNCTION public._exos_sha256(text) FROM PUBLIC, anon, authenticated;

-- Redirect URIs: https, or http on a loopback host; no fragment, credentials
-- or wildcards; at most 500 characters. Must agree with redirectUriProblem()
-- in _shared/api/credentials.ts.
CREATE OR REPLACE FUNCTION public._exos_redirect_uri_ok(p_uri text)
RETURNS boolean LANGUAGE sql IMMUTABLE SET search_path = public, pg_temp AS $$
  SELECT p_uri IS NOT NULL AND length(p_uri) BETWEEN 1 AND 500
     AND position('#' in p_uri) = 0 AND position('*' in p_uri) = 0 AND p_uri !~ '\s'
     AND (p_uri ~ '^https://[A-Za-z0-9.-]+(:[0-9]{1,5})?(/[^?#]*)?(\?[^#]*)?$'
          OR p_uri ~ '^http://(localhost|127\.0\.0\.1|\[::1\])(:[0-9]{1,5})?(/[^?#]*)?(\?[^#]*)?$')
$$;
REVOKE ALL ON FUNCTION public._exos_redirect_uri_ok(text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_redirect_uri_ok(text) TO service_role;

-- The caller's live role in an org (NULL: not a member or disabled).
CREATE OR REPLACE FUNCTION public._exos_member_role(p_org_id uuid, p_user_id uuid)
RETURNS text LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT m.role FROM public.exos_org_memberships m
   WHERE m.org_id = p_org_id AND m.user_id = p_user_id AND m.disabled IS NOT TRUE
$$;
REVOKE ALL ON FUNCTION public._exos_member_role(uuid, uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_member_role(uuid, uuid) TO service_role;

-- ---------------------------------------------------------------------------
-- 2. The audit log.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.exos_token_audit (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  action        text NOT NULL CHECK (action IN (
                  'pat.created', 'pat.revoked', 'app.created', 'app.updated', 'app.secret_rotated', 'app.deleted',
                  'app.registered', 'grant.created', 'grant.updated', 'grant.revoked',
                  'refresh.reuse_detected', 'code.reuse_detected', 'member.offboarded')),
  actor_uid     uuid,
  user_id       uuid,
  org_id        uuid REFERENCES public.exos_orgs (id) ON DELETE CASCADE,
  app_id        uuid,
  credential_id text,
  detail        jsonb CHECK (detail IS NULL OR (jsonb_typeof(detail) = 'object' AND octet_length(detail::text) <= 2000)),
  at            timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS exos_token_audit_user_idx ON public.exos_token_audit (user_id, at DESC);
CREATE INDEX IF NOT EXISTS exos_token_audit_org_idx ON public.exos_token_audit (org_id, at DESC);
ALTER TABLE public.exos_token_audit ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS exos_token_audit_read ON public.exos_token_audit;
CREATE POLICY exos_token_audit_read ON public.exos_token_audit FOR SELECT TO authenticated
  USING (user_id = auth.uid() OR (org_id IS NOT NULL AND public.exos_has_org_role(org_id, ARRAY['owner'])));
REVOKE ALL ON public.exos_token_audit FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.exos_token_audit TO authenticated;
GRANT ALL ON public.exos_token_audit TO service_role;

CREATE OR REPLACE FUNCTION public._exos_token_audit(
  p_action text, p_actor uuid, p_user uuid, p_org uuid, p_app uuid, p_cred text, p_detail jsonb DEFAULT NULL)
RETURNS void LANGUAGE sql SECURITY DEFINER SET search_path = public, pg_temp AS $$
  INSERT INTO public.exos_token_audit (action, actor_uid, user_id, org_id, app_id, credential_id, detail)
  VALUES (p_action, p_actor, p_user, p_org, p_app, p_cred, p_detail)
$$;
REVOKE ALL ON FUNCTION public._exos_token_audit(text, uuid, uuid, uuid, uuid, text, jsonb) FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 3. Personal access tokens.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.exos_personal_tokens (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id        uuid NOT NULL REFERENCES auth.users (id) ON DELETE CASCADE,
  org_id         uuid NOT NULL REFERENCES public.exos_orgs (id) ON DELETE CASCADE,
  name           text NOT NULL CHECK (length(btrim(name)) BETWEEN 1 AND 80),
  key_prefix     text NOT NULL,
  key_hash       text NOT NULL UNIQUE CHECK (key_hash ~ '^[0-9a-f]{64}$'),
  scopes         text[] NOT NULL CHECK (cardinality(scopes) >= 1),
  expires_at     timestamptz,
  last_used_at   timestamptz,
  revoked_at     timestamptz,
  revoked_reason text CHECK (revoked_reason IS NULL OR revoked_reason IN ('user', 'left_org', 'api')),
  created_at     timestamptz NOT NULL DEFAULT now(),
  updated_at     timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS exos_personal_tokens_user_idx ON public.exos_personal_tokens (user_id, org_id);
DROP TRIGGER IF EXISTS exos_personal_tokens_touch ON public.exos_personal_tokens;
CREATE TRIGGER exos_personal_tokens_touch BEFORE UPDATE ON public.exos_personal_tokens
  FOR EACH ROW EXECUTE FUNCTION public.exos_touch_updated_at();
ALTER TABLE public.exos_personal_tokens ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS exos_personal_tokens_own ON public.exos_personal_tokens;
CREATE POLICY exos_personal_tokens_own ON public.exos_personal_tokens FOR SELECT TO authenticated
  USING (user_id = auth.uid());
REVOKE ALL ON public.exos_personal_tokens FROM PUBLIC, anon, authenticated;
GRANT SELECT (id, user_id, org_id, name, key_prefix, scopes, expires_at, last_used_at, revoked_at, revoked_reason,
              created_at, updated_at) ON public.exos_personal_tokens TO authenticated;
GRANT ALL ON public.exos_personal_tokens TO service_role;
COMMENT ON TABLE public.exos_personal_tokens IS
  'Personal access tokens (exos_pat_…, hash only), one org each; scopes narrowed to the live role per request. mig 20261031130500.';

CREATE OR REPLACE FUNCTION public.exos_create_personal_token(
  p_org_id uuid, p_name text, p_scopes text[], p_expires_days integer DEFAULT 90)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  v_uid    uuid := auth.uid();
  v_role   text;
  v_scopes text[];
  v_over   text;
  v_tok    text;
  v_id     uuid;
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'not authenticated' USING ERRCODE = '42501'; END IF;
  IF NOT EXISTS (SELECT 1 FROM auth.users WHERE id = v_uid AND email_confirmed_at IS NOT NULL) THEN
    RAISE EXCEPTION 'confirm your email address before creating a token' USING ERRCODE = '42501';
  END IF;
  v_role := public._exos_member_role(p_org_id, v_uid);
  IF v_role IS NULL THEN RAISE EXCEPTION 'not a member of this organization' USING ERRCODE = '42501'; END IF;
  IF p_expires_days IS NOT NULL AND p_expires_days NOT IN (30, 90, 365) THEN
    RAISE EXCEPTION 'expires_days must be 30, 90, 365 or none' USING ERRCODE = '22023';
  END IF;
  v_scopes := public._exos_token_clean_scopes(p_scopes);
  SELECT s INTO v_over FROM unnest(v_scopes) s
   WHERE NOT (s = ANY (public._exos_scopes_for_role(ARRAY[s], v_role))) LIMIT 1;
  IF v_over IS NOT NULL THEN
    RAISE EXCEPTION 'your role (%) can''t grant %', v_role, v_over USING ERRCODE = '42501';
  END IF;
  PERFORM pg_advisory_xact_lock(hashtextextended('exos_pat:' || v_uid::text, 0));
  IF (SELECT count(*) FROM public.exos_personal_tokens
       WHERE user_id = v_uid AND revoked_at IS NULL AND (expires_at IS NULL OR expires_at > now())) >= 25 THEN
    RAISE EXCEPTION 'at most 25 active tokens; revoke one first' USING ERRCODE = '54000';
  END IF;
  v_tok := public._exos_mint_secret('exos_pat_');
  INSERT INTO public.exos_personal_tokens (user_id, org_id, name, key_prefix, key_hash, scopes, expires_at)
  VALUES (v_uid, p_org_id, left(btrim(coalesce(nullif(btrim(p_name), ''), 'Token')), 80), left(v_tok, 13),
          public._exos_sha256(v_tok), v_scopes,
          CASE WHEN p_expires_days IS NULL THEN NULL ELSE now() + make_interval(days => p_expires_days) END)
  RETURNING id INTO v_id;
  PERFORM public._exos_token_audit('pat.created', v_uid, v_uid, p_org_id, NULL, v_id::text,
                                   jsonb_build_object('scopes', to_jsonb(v_scopes)));
  RETURN jsonb_build_object('id', v_id, 'token', v_tok, 'key_prefix', left(v_tok, 13), 'scopes', to_jsonb(v_scopes),
    'expires_at', (SELECT expires_at FROM public.exos_personal_tokens WHERE id = v_id));
END $$;
REVOKE ALL ON FUNCTION public.exos_create_personal_token(uuid, text, text[], integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.exos_create_personal_token(uuid, text, text[], integer) TO authenticated;

-- Revoke one of your tokens (dashboard), or the calling token itself
-- (exos-api DELETE /personal-access-tokens/current, service role, p_user set).
CREATE OR REPLACE FUNCTION public.exos_revoke_personal_token(p_id uuid)
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_uid uuid := auth.uid(); v_org uuid;
BEGIN
  UPDATE public.exos_personal_tokens SET revoked_at = now(), revoked_reason = 'user'
   WHERE id = p_id AND user_id = v_uid AND revoked_at IS NULL
  RETURNING org_id INTO v_org;
  IF v_org IS NULL THEN RETURN false; END IF;
  PERFORM public._exos_token_audit('pat.revoked', v_uid, v_uid, v_org, NULL, p_id::text, NULL);
  RETURN true;
END $$;
REVOKE ALL ON FUNCTION public.exos_revoke_personal_token(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.exos_revoke_personal_token(uuid) TO authenticated;

CREATE OR REPLACE FUNCTION public._exos_pat_revoke_self(p_id uuid)
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE r record;
BEGIN
  UPDATE public.exos_personal_tokens SET revoked_at = now(), revoked_reason = 'api'
   WHERE id = p_id AND revoked_at IS NULL RETURNING user_id, org_id INTO r;
  IF r.user_id IS NULL THEN RETURN false; END IF;
  PERFORM public._exos_token_audit('pat.revoked', r.user_id, r.user_id, r.org_id, NULL, p_id::text,
                                   '{"via":"api"}'::jsonb);
  RETURN true;
END $$;
REVOKE ALL ON FUNCTION public._exos_pat_revoke_self(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_pat_revoke_self(uuid) TO service_role;

-- ---------------------------------------------------------------------------
-- 4. OAuth apps, grants, codes, tokens.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.exos_oauth_apps (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  client_id         text NOT NULL UNIQUE CHECK (client_id ~ '^exos_app_[0-9a-f]{24}$'),
  name              text NOT NULL CHECK (length(btrim(name)) BETWEEN 1 AND 80),
  logo_url          text CHECK (logo_url IS NULL OR (length(logo_url) <= 500 AND logo_url ~ '^https://')),
  homepage_url      text CHECK (homepage_url IS NULL OR (length(homepage_url) <= 500 AND homepage_url ~ '^https?://')),
  redirect_uris     text[] NOT NULL CHECK (cardinality(redirect_uris) BETWEEN 1 AND 10),
  scopes            text[] NOT NULL CHECK (cardinality(scopes) >= 1),
  client_type       text NOT NULL CHECK (client_type IN ('confidential', 'public')),
  secret_hash       text CHECK (secret_hash IS NULL OR secret_hash ~ '^[0-9a-f]{64}$'),
  secret_prefix     text,
  secret_rotated_at timestamptz,
  owner_uid         uuid REFERENCES auth.users (id) ON DELETE CASCADE,
  source            text NOT NULL DEFAULT 'developer' CHECK (source IN ('developer', 'dcr')),
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now(),
  deleted_at        timestamptz,
  CHECK ((client_type = 'confidential') = (secret_hash IS NOT NULL)),
  CHECK (source = 'dcr' OR owner_uid IS NOT NULL)
);
CREATE INDEX IF NOT EXISTS exos_oauth_apps_owner_idx ON public.exos_oauth_apps (owner_uid);
DROP TRIGGER IF EXISTS exos_oauth_apps_touch ON public.exos_oauth_apps;
CREATE TRIGGER exos_oauth_apps_touch BEFORE UPDATE ON public.exos_oauth_apps
  FOR EACH ROW EXECUTE FUNCTION public.exos_touch_updated_at();
ALTER TABLE public.exos_oauth_apps ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS exos_oauth_apps_own ON public.exos_oauth_apps;
CREATE POLICY exos_oauth_apps_own ON public.exos_oauth_apps FOR SELECT TO authenticated
  USING (owner_uid = auth.uid() AND deleted_at IS NULL);
REVOKE ALL ON public.exos_oauth_apps FROM PUBLIC, anon, authenticated;
GRANT SELECT (id, client_id, name, logo_url, homepage_url, redirect_uris, scopes, client_type, secret_prefix,
              secret_rotated_at, owner_uid, source, created_at, updated_at) ON public.exos_oauth_apps TO authenticated;
GRANT ALL ON public.exos_oauth_apps TO service_role;

CREATE TABLE IF NOT EXISTS public.exos_oauth_grants (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  app_id       uuid NOT NULL REFERENCES public.exos_oauth_apps (id) ON DELETE CASCADE,
  user_id      uuid NOT NULL REFERENCES auth.users (id) ON DELETE CASCADE,
  org_id       uuid NOT NULL REFERENCES public.exos_orgs (id) ON DELETE CASCADE,
  scopes       text[] NOT NULL,
  created_at   timestamptz NOT NULL DEFAULT now(),
  updated_at   timestamptz NOT NULL DEFAULT now(),
  last_used_at timestamptz,
  revoked_at   timestamptz,
  revoked_by   uuid,
  revoked_reason text
);
CREATE UNIQUE INDEX IF NOT EXISTS exos_oauth_grants_live_uq ON public.exos_oauth_grants (app_id, user_id, org_id)
  WHERE revoked_at IS NULL;
CREATE INDEX IF NOT EXISTS exos_oauth_grants_org_idx ON public.exos_oauth_grants (org_id);
CREATE INDEX IF NOT EXISTS exos_oauth_grants_user_idx ON public.exos_oauth_grants (user_id);
DROP TRIGGER IF EXISTS exos_oauth_grants_touch ON public.exos_oauth_grants;
CREATE TRIGGER exos_oauth_grants_touch BEFORE UPDATE ON public.exos_oauth_grants
  FOR EACH ROW EXECUTE FUNCTION public.exos_touch_updated_at();
ALTER TABLE public.exos_oauth_grants ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS exos_oauth_grants_read ON public.exos_oauth_grants;
CREATE POLICY exos_oauth_grants_read ON public.exos_oauth_grants FOR SELECT TO authenticated
  USING (user_id = auth.uid() OR public.exos_has_org_role(org_id, ARRAY['owner']));
REVOKE ALL ON public.exos_oauth_grants FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.exos_oauth_grants TO authenticated;
GRANT ALL ON public.exos_oauth_grants TO service_role;

CREATE TABLE IF NOT EXISTS public.exos_oauth_codes (
  code_hash      text PRIMARY KEY CHECK (code_hash ~ '^[0-9a-f]{64}$'),
  app_id         uuid NOT NULL REFERENCES public.exos_oauth_apps (id) ON DELETE CASCADE,
  grant_id       uuid NOT NULL REFERENCES public.exos_oauth_grants (id) ON DELETE CASCADE,
  user_id        uuid NOT NULL,
  org_id         uuid NOT NULL,
  scopes         text[] NOT NULL,
  redirect_uri   text NOT NULL,
  code_challenge text CHECK (code_challenge IS NULL OR code_challenge ~ '^[A-Za-z0-9_-]{43}$'),
  resource       text CHECK (resource IS NULL OR length(resource) <= 500),
  expires_at     timestamptz NOT NULL,
  used_at        timestamptz,
  created_at     timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE IF NOT EXISTS public.exos_oauth_tokens (
  token_hash text PRIMARY KEY CHECK (token_hash ~ '^[0-9a-f]{64}$'),
  id         uuid NOT NULL DEFAULT gen_random_uuid() UNIQUE,
  kind       text NOT NULL CHECK (kind IN ('access', 'refresh')),
  app_id     uuid NOT NULL REFERENCES public.exos_oauth_apps (id) ON DELETE CASCADE,
  grant_id   uuid NOT NULL REFERENCES public.exos_oauth_grants (id) ON DELETE CASCADE,
  family_id  uuid NOT NULL,
  user_id    uuid NOT NULL,
  org_id     uuid NOT NULL,
  scopes     text[] NOT NULL,
  resource   text,
  code_hash  text,
  expires_at timestamptz NOT NULL,
  used_at    timestamptz,
  revoked_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS exos_oauth_tokens_family_idx ON public.exos_oauth_tokens (family_id);
CREATE INDEX IF NOT EXISTS exos_oauth_tokens_grant_idx ON public.exos_oauth_tokens (grant_id);
CREATE INDEX IF NOT EXISTS exos_oauth_tokens_code_idx ON public.exos_oauth_tokens (code_hash) WHERE code_hash IS NOT NULL;
ALTER TABLE public.exos_oauth_codes ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.exos_oauth_tokens ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.exos_oauth_codes, public.exos_oauth_tokens FROM PUBLIC, anon, authenticated;
GRANT ALL ON public.exos_oauth_codes, public.exos_oauth_tokens TO service_role;

-- Revoke a grant and everything issued under it. Internal.
CREATE OR REPLACE FUNCTION public._exos_oauth_grant_revoke(p_grant_id uuid, p_actor uuid, p_reason text)
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE g record;
BEGIN
  UPDATE public.exos_oauth_grants SET revoked_at = now(), revoked_by = p_actor, revoked_reason = p_reason
   WHERE id = p_grant_id AND revoked_at IS NULL RETURNING * INTO g;
  UPDATE public.exos_oauth_tokens SET revoked_at = now() WHERE grant_id = p_grant_id AND revoked_at IS NULL;
  IF g.id IS NULL THEN RETURN false; END IF;
  PERFORM public._exos_token_audit('grant.revoked', p_actor, g.user_id, g.org_id, g.app_id, g.id::text,
                                   jsonb_build_object('reason', p_reason));
  RETURN true;
END $$;
REVOKE ALL ON FUNCTION public._exos_oauth_grant_revoke(uuid, uuid, text) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public._exos_oauth_app_view(a public.exos_oauth_apps)
RETURNS jsonb LANGUAGE sql STABLE SET search_path = public, pg_temp AS $$
  SELECT jsonb_build_object('client_id', a.client_id, 'name', a.name, 'logo_url', a.logo_url,
    'homepage_url', a.homepage_url, 'redirect_uris', to_jsonb(a.redirect_uris), 'scopes', to_jsonb(a.scopes),
    'client_type', a.client_type, 'secret_prefix', a.secret_prefix, 'source', a.source,
    'verified', a.source = 'developer', 'created_at', a.created_at)
$$;
REVOKE ALL ON FUNCTION public._exos_oauth_app_view(public.exos_oauth_apps) FROM PUBLIC, anon, authenticated;

-- Validate app fields; returns the cleaned redirect list. Internal.
CREATE OR REPLACE FUNCTION public._exos_oauth_clean_redirects(p_uris text[])
RETURNS text[] LANGUAGE plpgsql IMMUTABLE SET search_path = public, pg_temp AS $$
DECLARE v_bad text; v text[];
BEGIN
  IF p_uris IS NULL OR cardinality(p_uris) NOT BETWEEN 1 AND 10 THEN
    RAISE EXCEPTION 'invalid_redirect_uri: register 1-10 redirect URIs' USING ERRCODE = '22023';
  END IF;
  SELECT u INTO v_bad FROM unnest(p_uris) u WHERE NOT public._exos_redirect_uri_ok(u) LIMIT 1;
  IF FOUND THEN
    RAISE EXCEPTION 'invalid_redirect_uri: % must be https (http only for localhost), with no fragment, credentials or wildcards',
      left(coalesce(v_bad, 'null'), 100) USING ERRCODE = '22023';
  END IF;
  SELECT array_agg(DISTINCT u) INTO v FROM unnest(p_uris) u;
  RETURN v;
END $$;
REVOKE ALL ON FUNCTION public._exos_oauth_clean_redirects(text[]) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public._exos_oauth_app_insert(
  p_owner uuid, p_name text, p_redirect_uris text[], p_scopes text[], p_client_type text,
  p_logo_url text, p_homepage_url text, p_source text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  v_secret text;
  a public.exos_oauth_apps%ROWTYPE;
BEGIN
  IF p_client_type NOT IN ('confidential', 'public') THEN
    RAISE EXCEPTION 'invalid_client_metadata: client_type is confidential or public' USING ERRCODE = '22023';
  END IF;
  IF length(btrim(coalesce(p_name, ''))) NOT BETWEEN 1 AND 80 THEN
    RAISE EXCEPTION 'invalid_client_metadata: name is 1-80 characters' USING ERRCODE = '22023';
  END IF;
  IF p_logo_url IS NOT NULL AND (length(p_logo_url) > 500 OR p_logo_url !~ '^https://[^\s]+$') THEN
    RAISE EXCEPTION 'invalid_client_metadata: logo_url must be https' USING ERRCODE = '22023';
  END IF;
  IF p_homepage_url IS NOT NULL AND (length(p_homepage_url) > 500 OR p_homepage_url !~ '^https?://[^\s]+$') THEN
    RAISE EXCEPTION 'invalid_client_metadata: homepage_url must be a URL' USING ERRCODE = '22023';
  END IF;
  IF p_client_type = 'confidential' THEN v_secret := public._exos_mint_secret('exos_cs_'); END IF;
  INSERT INTO public.exos_oauth_apps (client_id, name, logo_url, homepage_url, redirect_uris, scopes, client_type,
                                      secret_hash, secret_prefix, owner_uid, source)
  VALUES ('exos_app_' || encode(extensions.gen_random_bytes(12), 'hex'), btrim(p_name), p_logo_url, p_homepage_url,
          public._exos_oauth_clean_redirects(p_redirect_uris), public._exos_token_clean_scopes(p_scopes), p_client_type,
          public._exos_sha256(v_secret), left(v_secret, 12), p_owner, p_source)
  RETURNING * INTO a;
  PERFORM public._exos_token_audit(CASE p_source WHEN 'dcr' THEN 'app.registered' ELSE 'app.created' END,
                                   p_owner, p_owner, NULL, a.id, a.client_id, NULL);
  RETURN public._exos_oauth_app_view(a) || CASE WHEN v_secret IS NULL THEN '{}'::jsonb
                                                ELSE jsonb_build_object('client_secret', v_secret) END;
END $$;
REVOKE ALL ON FUNCTION public._exos_oauth_app_insert(uuid, text, text[], text[], text, text, text, text) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.exos_oauth_app_create(
  p_name text, p_redirect_uris text[], p_scopes text[], p_client_type text DEFAULT 'confidential',
  p_logo_url text DEFAULT NULL, p_homepage_url text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_uid uuid := auth.uid();
BEGIN
  IF v_uid IS NULL OR NOT EXISTS (SELECT 1 FROM auth.users WHERE id = v_uid AND email_confirmed_at IS NOT NULL) THEN
    RAISE EXCEPTION 'sign in with a confirmed email to register apps' USING ERRCODE = '42501';
  END IF;
  PERFORM pg_advisory_xact_lock(hashtextextended('exos_oauth_apps:' || v_uid::text, 0));
  IF (SELECT count(*) FROM public.exos_oauth_apps WHERE owner_uid = v_uid AND deleted_at IS NULL) >= 20 THEN
    RAISE EXCEPTION 'at most 20 apps per developer' USING ERRCODE = '54000';
  END IF;
  RETURN public._exos_oauth_app_insert(v_uid, p_name, p_redirect_uris, p_scopes, p_client_type,
                                       nullif(btrim(p_logo_url), ''), nullif(btrim(p_homepage_url), ''), 'developer');
END $$;
REVOKE ALL ON FUNCTION public.exos_oauth_app_create(text, text[], text[], text, text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.exos_oauth_app_create(text, text[], text[], text, text, text) TO authenticated;

-- An app of the caller's, locked (unknown and not yours look the same).
CREATE OR REPLACE FUNCTION public._exos_oauth_my_app(p_client_id text)
RETURNS public.exos_oauth_apps LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE a public.exos_oauth_apps%ROWTYPE;
BEGIN
  SELECT * INTO a FROM public.exos_oauth_apps
   WHERE client_id = p_client_id AND owner_uid = auth.uid() AND deleted_at IS NULL FOR UPDATE;
  IF a.id IS NULL OR auth.uid() IS NULL THEN RAISE EXCEPTION 'app not found' USING ERRCODE = 'P0002'; END IF;
  RETURN a;
END $$;
REVOKE ALL ON FUNCTION public._exos_oauth_my_app(text) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.exos_oauth_app_update(p_client_id text, p_patch jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE a public.exos_oauth_apps%ROWTYPE; v text[];
BEGIN
  a := public._exos_oauth_my_app(p_client_id);
  IF jsonb_typeof(p_patch) IS DISTINCT FROM 'object' THEN
    RAISE EXCEPTION 'send name, logo_url, homepage_url, redirect_uris or scopes' USING ERRCODE = '22023';
  END IF;
  IF p_patch ? 'name' THEN
    IF length(btrim(coalesce(p_patch->>'name', ''))) NOT BETWEEN 1 AND 80 THEN
      RAISE EXCEPTION 'name is 1-80 characters' USING ERRCODE = '22023';
    END IF;
    a.name := btrim(p_patch->>'name');
  END IF;
  IF p_patch ? 'logo_url' THEN
    a.logo_url := nullif(btrim(coalesce(p_patch->>'logo_url', '')), '');
    IF a.logo_url IS NOT NULL AND (length(a.logo_url) > 500 OR a.logo_url !~ '^https://[^\s]+$') THEN
      RAISE EXCEPTION 'logo_url must be https' USING ERRCODE = '22023';
    END IF;
  END IF;
  IF p_patch ? 'homepage_url' THEN
    a.homepage_url := nullif(btrim(coalesce(p_patch->>'homepage_url', '')), '');
    IF a.homepage_url IS NOT NULL AND (length(a.homepage_url) > 500 OR a.homepage_url !~ '^https?://[^\s]+$') THEN
      RAISE EXCEPTION 'homepage_url must be a URL' USING ERRCODE = '22023';
    END IF;
  END IF;
  IF p_patch ? 'redirect_uris' THEN
    SELECT array_agg(x) INTO v FROM jsonb_array_elements_text(CASE WHEN jsonb_typeof(p_patch->'redirect_uris') = 'array'
                                                                    THEN p_patch->'redirect_uris' ELSE '[]' END) x;
    a.redirect_uris := public._exos_oauth_clean_redirects(v);
  END IF;
  IF p_patch ? 'scopes' THEN
    SELECT array_agg(x) INTO v FROM jsonb_array_elements_text(CASE WHEN jsonb_typeof(p_patch->'scopes') = 'array'
                                                                    THEN p_patch->'scopes' ELSE '[]' END) x;
    a.scopes := public._exos_token_clean_scopes(v);
  END IF;
  UPDATE public.exos_oauth_apps SET name = a.name, logo_url = a.logo_url, homepage_url = a.homepage_url,
         redirect_uris = a.redirect_uris, scopes = a.scopes WHERE id = a.id RETURNING * INTO a;
  PERFORM public._exos_token_audit('app.updated', auth.uid(), auth.uid(), NULL, a.id, a.client_id, NULL);
  RETURN public._exos_oauth_app_view(a);
END $$;
REVOKE ALL ON FUNCTION public.exos_oauth_app_update(text, jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.exos_oauth_app_update(text, jsonb) TO authenticated;

-- A new client secret; the old one stops working at once (issued tokens keep working).
CREATE OR REPLACE FUNCTION public.exos_oauth_app_rotate_secret(p_client_id text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE a public.exos_oauth_apps%ROWTYPE; v_secret text := public._exos_mint_secret('exos_cs_');
BEGIN
  a := public._exos_oauth_my_app(p_client_id);
  IF a.client_type <> 'confidential' THEN
    RAISE EXCEPTION 'a public app has no secret' USING ERRCODE = '22023';
  END IF;
  UPDATE public.exos_oauth_apps SET secret_hash = public._exos_sha256(v_secret), secret_prefix = left(v_secret, 12),
         secret_rotated_at = now() WHERE id = a.id;
  PERFORM public._exos_token_audit('app.secret_rotated', auth.uid(), auth.uid(), NULL, a.id, a.client_id, NULL);
  RETURN jsonb_build_object('client_id', a.client_id, 'client_secret', v_secret, 'secret_prefix', left(v_secret, 12));
END $$;
REVOKE ALL ON FUNCTION public.exos_oauth_app_rotate_secret(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.exos_oauth_app_rotate_secret(text) TO authenticated;

-- Delete an app: every grant and token it has is revoked.
CREATE OR REPLACE FUNCTION public.exos_oauth_app_delete(p_client_id text)
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE a public.exos_oauth_apps%ROWTYPE; g record;
BEGIN
  a := public._exos_oauth_my_app(p_client_id);
  FOR g IN SELECT id FROM public.exos_oauth_grants WHERE app_id = a.id AND revoked_at IS NULL LOOP
    PERFORM public._exos_oauth_grant_revoke(g.id, auth.uid(), 'app_deleted');
  END LOOP;
  UPDATE public.exos_oauth_tokens SET revoked_at = now() WHERE app_id = a.id AND revoked_at IS NULL;
  UPDATE public.exos_oauth_apps SET deleted_at = now(), secret_hash = CASE WHEN client_type = 'confidential'
         THEN repeat('0', 64) ELSE NULL END WHERE id = a.id;
  PERFORM public._exos_token_audit('app.deleted', auth.uid(), auth.uid(), NULL, a.id, a.client_id, NULL);
  RETURN true;
END $$;
REVOKE ALL ON FUNCTION public.exos_oauth_app_delete(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.exos_oauth_app_delete(text) TO authenticated;

-- ---------------------------------------------------------------------------
-- 5. The consent screen (signed-in user).
-- ---------------------------------------------------------------------------
-- Validate an authorization request and describe it. A bad client_id or an
-- unregistered redirect URI is answered without redirect_ok (the page shows it
-- and never redirects); other problems come back as an OAuth error to send to
-- the app.
CREATE OR REPLACE FUNCTION public.exos_oauth_authorize_info(p_client_id text, p_redirect_uri text, p_scope text)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  v_uid    uuid := auth.uid();
  a        public.exos_oauth_apps%ROWTYPE;
  v_req    text[];
  v_bad    text;
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'not authenticated' USING ERRCODE = '42501'; END IF;
  SELECT * INTO a FROM public.exos_oauth_apps WHERE client_id = p_client_id AND deleted_at IS NULL;
  IF a.id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'redirect_ok', false, 'error', 'invalid_client',
                              'error_description', 'Unknown app.');
  END IF;
  IF p_redirect_uri IS NULL OR NOT (p_redirect_uri = ANY (a.redirect_uris)) THEN
    RETURN jsonb_build_object('ok', false, 'redirect_ok', false, 'error', 'invalid_redirect_uri',
                              'error_description', 'This redirect URI is not registered for the app.');
  END IF;
  v_req := CASE WHEN btrim(coalesce(p_scope, '')) = '' THEN a.scopes
                ELSE regexp_split_to_array(btrim(p_scope), '\s+') END;
  SELECT s INTO v_bad FROM unnest(v_req) s WHERE NOT (s = ANY (a.scopes)) LIMIT 1;
  IF v_bad IS NOT NULL THEN
    RETURN jsonb_build_object('ok', false, 'redirect_ok', true, 'error', 'invalid_scope',
                              'error_description', 'The app may not ask for ' || left(v_bad, 40) || '.');
  END IF;
  RETURN jsonb_build_object(
    'ok', true, 'redirect_ok', true,
    'app', public._exos_oauth_app_view(a) - 'secret_prefix' - 'redirect_uris',
    'redirect_host', substring(p_redirect_uri from '^[a-z]+://([^/:?]+)'),
    'scopes', to_jsonb(v_req),
    'orgs', (SELECT coalesce(jsonb_agg(jsonb_build_object(
               'org_id', o.id, 'name', o.name, 'role', m.role,
               'grantable', to_jsonb(public._exos_scopes_for_role(v_req, m.role))) ORDER BY o.name), '[]'::jsonb)
               FROM public.exos_org_memberships m JOIN public.exos_orgs o ON o.id = m.org_id
              WHERE m.user_id = v_uid AND m.disabled IS NOT TRUE));
END $$;
REVOKE ALL ON FUNCTION public.exos_oauth_authorize_info(text, text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.exos_oauth_authorize_info(text, text, text) TO authenticated;

-- Allow: create / update the grant (scopes narrowed to the role), mint a
-- single-use code for 10 minutes. Returns { code }.
CREATE OR REPLACE FUNCTION public.exos_oauth_authorize_approve(
  p_client_id text, p_redirect_uri text, p_scope text, p_org_id uuid,
  p_code_challenge text, p_code_challenge_method text, p_resource text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  v_uid    uuid := auth.uid();
  a        public.exos_oauth_apps%ROWTYPE;
  v_info   jsonb;
  v_role   text;
  v_scopes text[];
  g        public.exos_oauth_grants%ROWTYPE;
  v_code   text;
BEGIN
  v_info := public.exos_oauth_authorize_info(p_client_id, p_redirect_uri, p_scope);
  IF NOT (v_info->>'ok')::boolean THEN
    RAISE EXCEPTION '%: %', v_info->>'error', v_info->>'error_description' USING ERRCODE = '22023';
  END IF;
  SELECT * INTO a FROM public.exos_oauth_apps WHERE client_id = p_client_id AND deleted_at IS NULL;
  IF p_code_challenge IS NOT NULL OR p_code_challenge_method IS NOT NULL THEN
    IF p_code_challenge_method IS DISTINCT FROM 'S256' OR p_code_challenge IS NULL
       OR p_code_challenge !~ '^[A-Za-z0-9_-]{43}$' THEN
      RAISE EXCEPTION 'invalid_request: code_challenge must be an S256 challenge' USING ERRCODE = '22023';
    END IF;
  ELSIF a.client_type = 'public' THEN
    RAISE EXCEPTION 'invalid_request: public apps must use PKCE (S256)' USING ERRCODE = '22023';
  END IF;
  IF p_resource IS NOT NULL AND (length(p_resource) > 500 OR p_resource !~ '^https://') THEN
    RAISE EXCEPTION 'invalid_target: resource must be an https URL' USING ERRCODE = '22023';
  END IF;
  v_role := public._exos_member_role(p_org_id, v_uid);
  IF v_role IS NULL THEN
    RAISE EXCEPTION 'access_denied: not a member of that organization' USING ERRCODE = '42501';
  END IF;
  v_scopes := public._exos_scopes_for_role(ARRAY(SELECT jsonb_array_elements_text(v_info->'scopes')), v_role);
  IF cardinality(v_scopes) = 0 THEN
    RAISE EXCEPTION 'invalid_scope: your role (%) can''t grant any of these scopes', v_role USING ERRCODE = '22023';
  END IF;

  SELECT * INTO g FROM public.exos_oauth_grants
   WHERE app_id = a.id AND user_id = v_uid AND org_id = p_org_id AND revoked_at IS NULL FOR UPDATE;
  IF g.id IS NULL THEN
    INSERT INTO public.exos_oauth_grants (app_id, user_id, org_id, scopes)
    VALUES (a.id, v_uid, p_org_id, v_scopes) RETURNING * INTO g;
    PERFORM public._exos_token_audit('grant.created', v_uid, v_uid, p_org_id, a.id, g.id::text,
                                     jsonb_build_object('scopes', to_jsonb(v_scopes)));
  ELSIF g.scopes IS DISTINCT FROM v_scopes THEN
    UPDATE public.exos_oauth_grants SET scopes = v_scopes WHERE id = g.id;
    PERFORM public._exos_token_audit('grant.updated', v_uid, v_uid, p_org_id, a.id, g.id::text,
                                     jsonb_build_object('scopes', to_jsonb(v_scopes)));
  END IF;
  v_code := public._exos_mint_secret('exos_oac_');
  INSERT INTO public.exos_oauth_codes (code_hash, app_id, grant_id, user_id, org_id, scopes, redirect_uri,
                                       code_challenge, resource, expires_at)
  VALUES (public._exos_sha256(v_code), a.id, g.id, v_uid, p_org_id, v_scopes, p_redirect_uri,
          p_code_challenge, p_resource, now() + interval '10 minutes');
  RETURN jsonb_build_object('code', v_code, 'scopes', to_jsonb(v_scopes));
END $$;
REVOKE ALL ON FUNCTION public.exos_oauth_authorize_approve(text, text, text, uuid, text, text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.exos_oauth_authorize_approve(text, text, text, uuid, text, text, text) TO authenticated;

-- ---------------------------------------------------------------------------
-- 6. Connected apps.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._exos_grant_view(g public.exos_oauth_grants)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT jsonb_build_object('grant_id', g.id, 'org_id', g.org_id, 'org_name', o.name, 'user_id', g.user_id,
    'user_email', u.email, 'scopes', to_jsonb(g.scopes), 'created_at', g.created_at, 'last_used_at', g.last_used_at,
    'app', jsonb_build_object('client_id', a.client_id, 'name', a.name, 'logo_url', a.logo_url,
                              'homepage_url', a.homepage_url, 'verified', a.source = 'developer'))
    FROM public.exos_oauth_apps a, public.exos_orgs o, auth.users u
   WHERE a.id = g.app_id AND o.id = g.org_id AND u.id = g.user_id
$$;
REVOKE ALL ON FUNCTION public._exos_grant_view(public.exos_oauth_grants) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.exos_oauth_my_grants()
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT coalesce(jsonb_agg(public._exos_grant_view(g) - 'user_email' ORDER BY g.created_at DESC), '[]'::jsonb)
    FROM public.exos_oauth_grants g
   WHERE g.user_id = auth.uid() AND g.revoked_at IS NULL
$$;
REVOKE ALL ON FUNCTION public.exos_oauth_my_grants() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.exos_oauth_my_grants() TO authenticated;

CREATE OR REPLACE FUNCTION public.exos_oauth_org_grants(p_org_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
  IF NOT public.exos_has_org_role(p_org_id, ARRAY['owner']) THEN
    RAISE EXCEPTION 'owner only' USING ERRCODE = '42501';
  END IF;
  RETURN (SELECT coalesce(jsonb_agg(public._exos_grant_view(g) ORDER BY g.created_at DESC), '[]'::jsonb)
            FROM public.exos_oauth_grants g WHERE g.org_id = p_org_id AND g.revoked_at IS NULL);
END $$;
REVOKE ALL ON FUNCTION public.exos_oauth_org_grants(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.exos_oauth_org_grants(uuid) TO authenticated;

-- Disconnect: the grant's user, or an owner of its org.
CREATE OR REPLACE FUNCTION public.exos_oauth_revoke_grant(p_grant_id uuid)
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE g public.exos_oauth_grants%ROWTYPE;
BEGIN
  SELECT * INTO g FROM public.exos_oauth_grants WHERE id = p_grant_id;
  IF g.id IS NULL OR auth.uid() IS NULL
     OR NOT (g.user_id = auth.uid() OR public.exos_has_org_role(g.org_id, ARRAY['owner'])) THEN
    RAISE EXCEPTION 'not authorized' USING ERRCODE = '42501';
  END IF;
  RETURN public._exos_oauth_grant_revoke(g.id, auth.uid(), 'disconnected');
END $$;
REVOKE ALL ON FUNCTION public.exos_oauth_revoke_grant(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.exos_oauth_revoke_grant(uuid) TO authenticated;

-- ---------------------------------------------------------------------------
-- 7. The token endpoint and friends (exos-oauth, service role). Every answer
--    is jsonb: either the tokens or { error, error_description } (RFC 6749).
-- ---------------------------------------------------------------------------
-- Client authentication: confidential apps present their secret, public apps
-- none. Returns the app or NULL.
CREATE OR REPLACE FUNCTION public._exos_oauth_client(p_client_id text, p_secret_hash text)
RETURNS public.exos_oauth_apps LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT a.* FROM public.exos_oauth_apps a
   WHERE a.client_id = p_client_id AND a.deleted_at IS NULL
     AND ((a.client_type = 'public' AND p_secret_hash IS NULL)
          OR (a.client_type = 'confidential' AND p_secret_hash IS NOT NULL AND a.secret_hash = p_secret_hash))
$$;
REVOKE ALL ON FUNCTION public._exos_oauth_client(text, text) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public._exos_oauth_err(p_code text, p_desc text)
RETURNS jsonb LANGUAGE sql IMMUTABLE SET search_path = public, pg_temp AS $$
  SELECT jsonb_build_object('error', p_code, 'error_description', p_desc)
$$;
REVOKE ALL ON FUNCTION public._exos_oauth_err(text, text) FROM PUBLIC, anon, authenticated;

-- A new access + refresh pair in a family.
CREATE OR REPLACE FUNCTION public._exos_oauth_issue(
  p_app uuid, p_grant uuid, p_family uuid, p_user uuid, p_org uuid, p_scopes text[], p_resource text, p_code_hash text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_at text := public._exos_mint_secret('exos_oat_'); v_rt text := public._exos_mint_secret('exos_ort_');
BEGIN
  INSERT INTO public.exos_oauth_tokens (token_hash, kind, app_id, grant_id, family_id, user_id, org_id, scopes, resource,
                                        code_hash, expires_at)
  VALUES (public._exos_sha256(v_at), 'access', p_app, p_grant, p_family, p_user, p_org, p_scopes, p_resource,
          p_code_hash, now() + interval '1 hour'),
         (public._exos_sha256(v_rt), 'refresh', p_app, p_grant, p_family, p_user, p_org, p_scopes, p_resource,
          p_code_hash, now() + interval '60 days');
  UPDATE public.exos_oauth_grants SET last_used_at = now() WHERE id = p_grant;
  RETURN jsonb_build_object('access_token', v_at, 'token_type', 'Bearer', 'expires_in', 3600,
                            'refresh_token', v_rt, 'scope', array_to_string(p_scopes, ' '));
END $$;
REVOKE ALL ON FUNCTION public._exos_oauth_issue(uuid, uuid, uuid, uuid, uuid, text[], text, text) FROM PUBLIC, anon, authenticated;

-- grant_type=authorization_code. p_verifier_s256: base64url(SHA-256(verifier))
-- computed by the edge function (NULL when no verifier was sent).
CREATE OR REPLACE FUNCTION public.exos_oauth_exchange_code(
  p_code_hash text, p_client_id text, p_secret_hash text, p_redirect_uri text, p_verifier_s256 text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  a   public.exos_oauth_apps%ROWTYPE;
  c   public.exos_oauth_codes%ROWTYPE;
  g   public.exos_oauth_grants%ROWTYPE;
  v_role text;
  v_scopes text[];
BEGIN
  a := public._exos_oauth_client(p_client_id, p_secret_hash);
  IF a.id IS NULL THEN RETURN public._exos_oauth_err('invalid_client', 'Client authentication failed.'); END IF;
  SELECT * INTO c FROM public.exos_oauth_codes WHERE code_hash = p_code_hash FOR UPDATE;
  IF c.code_hash IS NULL OR c.app_id <> a.id THEN
    RETURN public._exos_oauth_err('invalid_grant', 'Unknown authorization code.');
  END IF;
  IF c.used_at IS NOT NULL THEN
    -- Presented twice: whoever has the first exchange's tokens loses them.
    UPDATE public.exos_oauth_tokens SET revoked_at = now() WHERE code_hash = c.code_hash AND revoked_at IS NULL;
    PERFORM public._exos_token_audit('code.reuse_detected', NULL, c.user_id, c.org_id, a.id, c.grant_id::text, NULL);
    RETURN public._exos_oauth_err('invalid_grant', 'This authorization code was already used.');
  END IF;
  -- Spent whatever happens next: a wrong verifier can't be retried.
  UPDATE public.exos_oauth_codes SET used_at = now() WHERE code_hash = c.code_hash;
  IF c.expires_at <= now() THEN RETURN public._exos_oauth_err('invalid_grant', 'The authorization code expired.'); END IF;
  IF p_redirect_uri IS DISTINCT FROM c.redirect_uri THEN
    RETURN public._exos_oauth_err('invalid_grant', 'redirect_uri does not match the authorization request.');
  END IF;
  IF c.code_challenge IS NULL THEN
    IF p_verifier_s256 IS NOT NULL THEN
      RETURN public._exos_oauth_err('invalid_grant', 'No code_challenge was sent, so no code_verifier may be.');
    END IF;
  ELSIF p_verifier_s256 IS DISTINCT FROM c.code_challenge THEN
    RETURN public._exos_oauth_err('invalid_grant', 'code_verifier does not match the code_challenge.');
  END IF;
  SELECT * INTO g FROM public.exos_oauth_grants WHERE id = c.grant_id AND revoked_at IS NULL;
  v_role := public._exos_member_role(c.org_id, c.user_id);
  IF g.id IS NULL OR v_role IS NULL THEN
    RETURN public._exos_oauth_err('invalid_grant', 'The grant was revoked.');
  END IF;
  v_scopes := public._exos_scopes_for_role(c.scopes, v_role);
  IF cardinality(v_scopes) = 0 THEN RETURN public._exos_oauth_err('invalid_scope', 'No scope left for this role.'); END IF;
  RETURN public._exos_oauth_issue(a.id, g.id, gen_random_uuid(), c.user_id, c.org_id, v_scopes, c.resource, c.code_hash);
END $$;
REVOKE ALL ON FUNCTION public.exos_oauth_exchange_code(text, text, text, text, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_oauth_exchange_code(text, text, text, text, text) TO service_role;

-- grant_type=refresh_token: single use, rotated; reuse revokes the family.
-- p_scopes may narrow, never widen.
CREATE OR REPLACE FUNCTION public.exos_oauth_refresh(p_refresh_hash text, p_client_id text, p_secret_hash text, p_scopes text[])
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  a   public.exos_oauth_apps%ROWTYPE;
  t   public.exos_oauth_tokens%ROWTYPE;
  g   public.exos_oauth_grants%ROWTYPE;
  v_role text;
  v_scopes text[];
BEGIN
  a := public._exos_oauth_client(p_client_id, p_secret_hash);
  IF a.id IS NULL THEN RETURN public._exos_oauth_err('invalid_client', 'Client authentication failed.'); END IF;
  SELECT * INTO t FROM public.exos_oauth_tokens WHERE token_hash = p_refresh_hash AND kind = 'refresh' FOR UPDATE;
  IF t.token_hash IS NULL OR t.app_id <> a.id THEN
    RETURN public._exos_oauth_err('invalid_grant', 'Unknown refresh token.');
  END IF;
  IF t.revoked_at IS NOT NULL THEN RETURN public._exos_oauth_err('invalid_grant', 'The refresh token was revoked.'); END IF;
  IF t.used_at IS NOT NULL THEN
    -- A copy leaked: the whole family goes, both parties re-authorize.
    UPDATE public.exos_oauth_tokens SET revoked_at = now() WHERE family_id = t.family_id AND revoked_at IS NULL;
    PERFORM public._exos_token_audit('refresh.reuse_detected', NULL, t.user_id, t.org_id, a.id, t.grant_id::text,
                                     jsonb_build_object('family', t.family_id));
    RETURN public._exos_oauth_err('invalid_grant', 'This refresh token was already used; the session was revoked.');
  END IF;
  IF t.expires_at <= now() THEN RETURN public._exos_oauth_err('invalid_grant', 'The refresh token expired.'); END IF;
  SELECT * INTO g FROM public.exos_oauth_grants WHERE id = t.grant_id AND revoked_at IS NULL;
  v_role := public._exos_member_role(t.org_id, t.user_id);
  IF g.id IS NULL OR v_role IS NULL THEN RETURN public._exos_oauth_err('invalid_grant', 'The grant was revoked.'); END IF;
  v_scopes := t.scopes;
  IF p_scopes IS NOT NULL AND cardinality(p_scopes) > 0 THEN
    IF EXISTS (SELECT 1 FROM unnest(p_scopes) s WHERE NOT (s = ANY (t.scopes))) THEN
      RETURN public._exos_oauth_err('invalid_scope', 'A refresh may narrow the scopes, not widen them.');
    END IF;
    v_scopes := p_scopes;
  END IF;
  v_scopes := public._exos_scopes_for_role(v_scopes, v_role);
  IF cardinality(v_scopes) = 0 THEN RETURN public._exos_oauth_err('invalid_scope', 'No scope left for this role.'); END IF;
  UPDATE public.exos_oauth_tokens SET used_at = now() WHERE token_hash = t.token_hash;
  -- The access token issued with it is done too.
  UPDATE public.exos_oauth_tokens SET revoked_at = now()
   WHERE family_id = t.family_id AND kind = 'access' AND revoked_at IS NULL;
  RETURN public._exos_oauth_issue(a.id, g.id, t.family_id, t.user_id, t.org_id, v_scopes, t.resource, NULL);
END $$;
REVOKE ALL ON FUNCTION public.exos_oauth_refresh(text, text, text, text[]) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_oauth_refresh(text, text, text, text[]) TO service_role;

-- RFC 7009: always "ok" for an authenticated client; a refresh token takes
-- its family with it.
CREATE OR REPLACE FUNCTION public.exos_oauth_revoke_token(p_hash text, p_client_id text, p_secret_hash text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE a public.exos_oauth_apps%ROWTYPE; t public.exos_oauth_tokens%ROWTYPE;
BEGIN
  a := public._exos_oauth_client(p_client_id, p_secret_hash);
  IF a.id IS NULL THEN RETURN public._exos_oauth_err('invalid_client', 'Client authentication failed.'); END IF;
  SELECT * INTO t FROM public.exos_oauth_tokens WHERE token_hash = p_hash AND app_id = a.id;
  IF t.token_hash IS NOT NULL THEN
    IF t.kind = 'refresh' THEN
      UPDATE public.exos_oauth_tokens SET revoked_at = now() WHERE family_id = t.family_id AND revoked_at IS NULL;
    ELSE
      UPDATE public.exos_oauth_tokens SET revoked_at = now() WHERE token_hash = t.token_hash AND revoked_at IS NULL;
    END IF;
  END IF;
  RETURN '{}'::jsonb;
END $$;
REVOKE ALL ON FUNCTION public.exos_oauth_revoke_token(text, text, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_oauth_revoke_token(text, text, text) TO service_role;

-- RFC 7662, for the app's own tokens; includes the user's current role.
CREATE OR REPLACE FUNCTION public.exos_oauth_introspect(p_hash text, p_client_id text, p_secret_hash text)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE a public.exos_oauth_apps%ROWTYPE; t public.exos_oauth_tokens%ROWTYPE; v_role text;
BEGIN
  a := public._exos_oauth_client(p_client_id, p_secret_hash);
  IF a.id IS NULL THEN RETURN public._exos_oauth_err('invalid_client', 'Client authentication failed.'); END IF;
  SELECT * INTO t FROM public.exos_oauth_tokens WHERE token_hash = p_hash AND app_id = a.id;
  v_role := public._exos_member_role(t.org_id, t.user_id);
  IF t.token_hash IS NULL OR t.revoked_at IS NOT NULL OR t.expires_at <= now() OR (t.kind = 'refresh' AND t.used_at IS NOT NULL)
     OR v_role IS NULL
     OR NOT EXISTS (SELECT 1 FROM public.exos_oauth_grants WHERE id = t.grant_id AND revoked_at IS NULL) THEN
    RETURN jsonb_build_object('active', false);
  END IF;
  RETURN jsonb_build_object('active', true, 'client_id', a.client_id, 'token_type', t.kind,
    'scope', array_to_string(public._exos_scopes_for_role(t.scopes, v_role), ' '),
    'sub', t.user_id, 'org_id', t.org_id, 'role', v_role,
    'exp', floor(extract(epoch FROM t.expires_at))::bigint, 'iat', floor(extract(epoch FROM t.created_at))::bigint);
END $$;
REVOKE ALL ON FUNCTION public.exos_oauth_introspect(text, text, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_oauth_introspect(text, text, text) TO service_role;

-- RFC 7591 dynamic registration (the edge function answers it only with
-- EXOS_OAUTH_DCR=on). Unverified on the consent screen.
CREATE OR REPLACE FUNCTION public.exos_oauth_register(
  p_name text, p_redirect_uris text[], p_scopes text[], p_client_type text, p_logo_url text, p_homepage_url text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
  RETURN public._exos_oauth_app_insert(NULL, p_name, p_redirect_uris,
    coalesce(p_scopes, public.exos_api_scope_names()), coalesce(p_client_type, 'public'),
    nullif(btrim(p_logo_url), ''), nullif(btrim(p_homepage_url), ''), 'dcr');
END $$;
REVOKE ALL ON FUNCTION public.exos_oauth_register(text, text[], text[], text, text, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_oauth_register(text, text[], text[], text, text, text) TO service_role;

-- ---------------------------------------------------------------------------
-- 8. Using a token (exos-api, exos-mcp): who it is and what it may do now.
--    p_kind 'pat' | 'oauth'. NULL: unknown, revoked or expired (401).
--    { error: 'membership' }: valid, but the user isn't an active member of
--    the org any more (403). Else { kind, credential_id, user_id, org_id,
--    role, scopes (effective), token_scopes, client_id? }.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.exos_api_token_auth(p_hash text, p_kind text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  p    public.exos_personal_tokens%ROWTYPE;
  t    public.exos_oauth_tokens%ROWTYPE;
  v_role text;
  v_client text;
BEGIN
  IF p_hash IS NULL OR p_hash !~ '^[0-9a-f]{64}$' THEN RETURN NULL; END IF;
  IF p_kind = 'pat' THEN
    SELECT * INTO p FROM public.exos_personal_tokens
     WHERE key_hash = p_hash AND revoked_at IS NULL AND (expires_at IS NULL OR expires_at > now());
    IF p.id IS NULL THEN RETURN NULL; END IF;
    v_role := public._exos_member_role(p.org_id, p.user_id);
    IF v_role IS NULL THEN RETURN jsonb_build_object('error', 'membership'); END IF;
    IF p.last_used_at IS NULL OR p.last_used_at < now() - interval '1 minute' THEN
      UPDATE public.exos_personal_tokens SET last_used_at = now() WHERE id = p.id;
    END IF;
    RETURN jsonb_build_object('kind', 'pat', 'credential_id', p.id, 'name', p.name, 'key_prefix', p.key_prefix,
      'user_id', p.user_id, 'org_id', p.org_id, 'role', v_role,
      'scopes', to_jsonb(public._exos_scopes_for_role(p.scopes, v_role)), 'token_scopes', to_jsonb(p.scopes));
  ELSIF p_kind = 'oauth' THEN
    SELECT tk.* INTO t FROM public.exos_oauth_tokens tk
      JOIN public.exos_oauth_grants g ON g.id = tk.grant_id AND g.revoked_at IS NULL
      JOIN public.exos_oauth_apps a ON a.id = tk.app_id AND a.deleted_at IS NULL
     WHERE tk.token_hash = p_hash AND tk.kind = 'access' AND tk.revoked_at IS NULL AND tk.expires_at > now();
    IF t.token_hash IS NULL THEN RETURN NULL; END IF;
    v_role := public._exos_member_role(t.org_id, t.user_id);
    IF v_role IS NULL THEN RETURN jsonb_build_object('error', 'membership'); END IF;
    SELECT client_id INTO v_client FROM public.exos_oauth_apps WHERE id = t.app_id;
    UPDATE public.exos_oauth_grants SET last_used_at = now()
     WHERE id = t.grant_id AND (last_used_at IS NULL OR last_used_at < now() - interval '1 minute');
    RETURN jsonb_build_object('kind', 'oauth', 'credential_id', t.grant_id, 'name', v_client,
      'key_prefix', NULL, 'user_id', t.user_id, 'org_id', t.org_id, 'role', v_role, 'client_id', v_client,
      'resource', t.resource,
      'scopes', to_jsonb(public._exos_scopes_for_role(t.scopes, v_role)), 'token_scopes', to_jsonb(t.scopes));
  END IF;
  RETURN NULL;
END $$;
REVOKE ALL ON FUNCTION public.exos_api_token_auth(text, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_api_token_auth(text, text) TO service_role;

-- ---------------------------------------------------------------------------
-- 9. Offboarding: the 20260929010000 body, plus a member who leaves or is
--    disabled loses their tokens and grants for that org. A demotion keeps
--    them: their scopes narrow on the next request (_exos_scopes_for_role).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.exos_tg_membership_offboard()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE r record; g record; v_n int;
BEGIN
  r := CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
  IF TG_OP = 'DELETE' OR NEW.disabled IS TRUE OR NEW.role NOT IN ('owner','manager') THEN
    UPDATE public.exos_api_keys SET revoked_at = now(), updated_at = now()
     WHERE org_id = r.org_id AND created_by = r.user_id AND revoked_at IS NULL;
    UPDATE public.exos_webhooks SET enabled = false, updated_at = now()
     WHERE org_id = r.org_id AND created_by = r.user_id AND enabled;
  END IF;
  -- Personal tokens and OAuth grants (mig 20261031130500).
  IF TG_OP = 'DELETE' OR NEW.disabled IS TRUE THEN
    UPDATE public.exos_personal_tokens SET revoked_at = now(), revoked_reason = 'left_org'
     WHERE org_id = r.org_id AND user_id = r.user_id AND revoked_at IS NULL;
    GET DIAGNOSTICS v_n = ROW_COUNT;
    FOR g IN SELECT id FROM public.exos_oauth_grants
              WHERE org_id = r.org_id AND user_id = r.user_id AND revoked_at IS NULL LOOP
      PERFORM public._exos_oauth_grant_revoke(g.id, NULL, 'left_org');
      v_n := v_n + 1;
    END LOOP;
    IF v_n > 0 THEN
      PERFORM public._exos_token_audit('member.offboarded', NULL, r.user_id, r.org_id, NULL, NULL,
                                       jsonb_build_object('revoked', v_n));
    END IF;
  END IF;
  RETURN NULL;
END $$;
REVOKE ALL ON FUNCTION public.exos_tg_membership_offboard() FROM PUBLIC, anon, authenticated;

-- ROLLBACK (manual): restore exos_tg_membership_offboard from 20260929010000,
--   then DROP the functions above and the tables exos_oauth_tokens,
--   exos_oauth_codes, exos_oauth_grants, exos_oauth_apps, exos_personal_tokens,
--   exos_token_audit.
