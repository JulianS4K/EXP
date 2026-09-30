-- ============================================================================
-- Migration 20260930102000 — Exos (Bridge / D4): "Connect Google Ads" (OAuth)
--                            for server-side conversions
--
-- Lane:     d4 (exos / bridge ticketing infra)
-- Touches:  W: TABLE exos_oauth_states (new; service role only)
--              FUNCTION exos_oauth_state_begin, exos_oauth_state_return,
--                exos_oauth_state_consume, exos_set_google_ads_token (new,
--                service role only)
--              FUNCTION _exos_oauth_can_connect (new, internal)
--           R: exos_org_memberships, exos_org_ad_credentials (mig
--              20260930100000), vault.secrets / vault.create_secret /
--              vault.update_secret (Supabase Vault)
-- Pre-reqs: 20260930100000 (exos_org_ad_credentials, the Vault naming
--           exos_ad:<org>:<platform>).
--
-- The exos-oauth-google edge function runs the Google sign-in that gives an
-- org's Google Ads row its refresh token (Data Manager API scope). Flow:
--
--   1. /start   (signed-in owner / manager, JWT): a random 256-bit state is
--               made; only its SHA-256 is stored here (exos_oauth_state_begin)
--               with the org, the user and a 10-minute expiry. The browser
--               goes to Google's consent page.
--   2. /callback (Google redirects the browser, no JWT): the code is parked on
--               the state row (exos_oauth_state_return; first return only),
--               and the browser goes back to the org settings page.
--   3. /finish  (the settings page, with the user's JWT): the state is
--               consumed (exos_oauth_state_consume: single use, not expired,
--               and ONLY by the user who started it), the code is exchanged
--               at Google, and the refresh token is saved to Vault
--               (exos_set_google_ads_token).
--
-- Step 3 binds the result to the Exos user who started the flow: a consent
-- link started by someone else and completed in a victim's browser can't
-- attach the victim's Google account to the other person's org (login CSRF),
-- because the victim's session is not the state's user.
--
-- Everything here is service role only: RLS on, no client grants. The code
-- is kept at most 10 minutes (it is useless without the client secret) and
-- is cleared when the state is consumed. The refresh token lives only in
-- Vault under the same name exos_set_ad_credential uses
-- (exos_ad:<org>:google_ads), so exos_conversions_claim_batch hands it to the
-- drain unchanged.
--
-- Re-run safe (IF NOT EXISTS, CREATE OR REPLACE, guarded constraints). D4
-- authors; applying to prod is operator-gated. NOT applied.
-- ============================================================================

CREATE TABLE IF NOT EXISTS public.exos_oauth_states (
  state_hash  text PRIMARY KEY
                CONSTRAINT exos_oauth_states_hash_chk CHECK (state_hash ~ '^[0-9a-f]{64}$'),
  provider    text NOT NULL
                CONSTRAINT exos_oauth_states_provider_chk CHECK (provider IN ('google_ads')),
  org_id      uuid NOT NULL REFERENCES public.exos_orgs (id) ON DELETE CASCADE,
  user_id     uuid NOT NULL,
  created_at  timestamptz NOT NULL DEFAULT now(),
  expires_at  timestamptz NOT NULL,
  code        text,              -- the authorization code, between /callback and /finish only
  returned_at timestamptz,       -- when Google sent the browser back
  consumed_at timestamptz        -- used (finished, refused or cancelled); never reusable
);
CREATE INDEX IF NOT EXISTS exos_oauth_states_user_idx ON public.exos_oauth_states (user_id, created_at);
CREATE INDEX IF NOT EXISTS exos_oauth_states_expiry_idx ON public.exos_oauth_states (expires_at);

ALTER TABLE public.exos_oauth_states ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.exos_oauth_states FROM PUBLIC, anon, authenticated;
GRANT ALL ON TABLE public.exos_oauth_states TO service_role;

COMMENT ON TABLE public.exos_oauth_states IS
  'Single-use OAuth states for exos-oauth-google (Connect Google Ads). SHA-256 of the state only; 10-minute expiry; service role only. mig 20260930102000.';

-- Owner or manager (active membership) of the org. The service-role RPCs
-- below take the user id from the edge function's verified JWT, so they
-- can't use exos_has_org_role (auth.uid() is NULL for the service role);
-- this is the same rule for a given user.
CREATE OR REPLACE FUNCTION public._exos_oauth_can_connect(p_org_id uuid, p_user_id uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT p_org_id IS NOT NULL AND p_user_id IS NOT NULL AND EXISTS (
    SELECT 1 FROM public.exos_org_memberships m
     WHERE m.org_id = p_org_id AND m.user_id = p_user_id
       AND m.disabled IS NOT TRUE
       AND m.role IN ('owner','manager'))
$$;
REVOKE ALL ON FUNCTION public._exos_oauth_can_connect(uuid, uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_oauth_can_connect(uuid, uuid) TO service_role;

-- 1. Record a new state (its hash). Owner / manager only; at most 10 states a
-- user in 10 minutes. Old rows (a day past expiry) are cleaned up here.
CREATE OR REPLACE FUNCTION public.exos_oauth_state_begin(
  p_provider    text,
  p_org_id      uuid,
  p_user_id     uuid,
  p_state_hash  text,
  p_ttl_minutes integer DEFAULT 10
) RETURNS timestamptz
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_exp timestamptz;
BEGIN
  IF p_provider IS NULL OR p_provider <> 'google_ads' THEN
    RAISE EXCEPTION 'exos_oauth_state_begin: unknown provider %', p_provider USING ERRCODE = '22023';
  END IF;
  IF p_state_hash IS NULL OR p_state_hash !~ '^[0-9a-f]{64}$' THEN
    RAISE EXCEPTION 'exos_oauth_state_begin: bad state hash' USING ERRCODE = '22023';
  END IF;
  IF NOT public._exos_oauth_can_connect(p_org_id, p_user_id) THEN
    RAISE EXCEPTION 'exos_oauth_state_begin: owner or manager only' USING ERRCODE = '42501';
  END IF;

  DELETE FROM public.exos_oauth_states WHERE expires_at < now() - interval '1 day';

  IF (SELECT count(*) FROM public.exos_oauth_states
       WHERE user_id = p_user_id AND created_at > now() - interval '10 minutes') >= 10 THEN
    RAISE EXCEPTION 'exos_oauth_state_begin: too many attempts, try again in a few minutes' USING ERRCODE = '54000';
  END IF;

  v_exp := now() + make_interval(mins => LEAST(GREATEST(coalesce(p_ttl_minutes, 10), 1), 10));
  INSERT INTO public.exos_oauth_states (state_hash, provider, org_id, user_id, expires_at)
  VALUES (p_state_hash, p_provider, p_org_id, p_user_id, v_exp);
  RETURN v_exp;
END $$;
REVOKE ALL ON FUNCTION public.exos_oauth_state_begin(text, uuid, uuid, text, integer) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_oauth_state_begin(text, uuid, uuid, text, integer) TO service_role;

-- 2. Google sent the browser back. With a code: park it on a live, unused
-- state that has none yet (the first return wins). Without one (the user
-- declined, or Google reported an error): consume the state. Returns the
-- state's org id, or NULL when the state is unknown, expired or used.
CREATE OR REPLACE FUNCTION public.exos_oauth_state_return(p_state_hash text, p_code text)
RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_org uuid;
BEGIN
  IF p_state_hash IS NULL OR p_state_hash !~ '^[0-9a-f]{64}$' THEN
    RETURN NULL;
  END IF;
  IF p_code IS NOT NULL AND (length(p_code) NOT BETWEEN 8 AND 2048 OR p_code ~ '[[:cntrl:][:space:]]') THEN
    p_code := NULL;  -- not a code: treat as an error return
  END IF;
  UPDATE public.exos_oauth_states
     SET code        = p_code,
         returned_at = now(),
         consumed_at = CASE WHEN p_code IS NULL THEN now() END
   WHERE state_hash = p_state_hash
     AND consumed_at IS NULL
     AND returned_at IS NULL
     AND expires_at > now()
  RETURNING org_id INTO v_org;
  RETURN v_org;
END $$;
REVOKE ALL ON FUNCTION public.exos_oauth_state_return(text, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_oauth_state_return(text, text) TO service_role;

-- 3. Use the state: only by the user who started it, once, before it
-- expires, after Google returned a code, and while that user is still an
-- owner / manager. Returns (org_id, code) and clears the stored code, or no
-- row. A refused attempt by the right user still burns the state.
CREATE OR REPLACE FUNCTION public.exos_oauth_state_consume(p_state_hash text, p_user_id uuid)
RETURNS TABLE(org_id uuid, code text)
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
#variable_conflict use_column
DECLARE
  v_row public.exos_oauth_states%ROWTYPE;
BEGIN
  IF p_state_hash IS NULL OR p_state_hash !~ '^[0-9a-f]{64}$' OR p_user_id IS NULL THEN
    RETURN;
  END IF;
  SELECT * INTO v_row FROM public.exos_oauth_states s
   WHERE s.state_hash = p_state_hash AND s.user_id = p_user_id
   FOR UPDATE;
  IF NOT FOUND OR v_row.consumed_at IS NOT NULL THEN
    RETURN;
  END IF;
  UPDATE public.exos_oauth_states s SET consumed_at = now(), code = NULL WHERE s.state_hash = p_state_hash;
  IF v_row.expires_at <= now() OR v_row.code IS NULL
     OR NOT public._exos_oauth_can_connect(v_row.org_id, p_user_id) THEN
    RETURN;
  END IF;
  org_id := v_row.org_id;
  code := v_row.code;
  RETURN NEXT;
END $$;
REVOKE ALL ON FUNCTION public.exos_oauth_state_consume(text, uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_oauth_state_consume(text, uuid) TO service_role;

-- 4. Save the org's Google Ads refresh token in Vault, under the name
-- exos_set_ad_credential uses (exos_ad:<org>:google_ads), and point the
-- credential row at it. The ids, the on/off switch and the test code are
-- kept (a new row starts off with no ids). Re-checks the user's role.
-- Returns has_secret / enabled; never the token.
CREATE OR REPLACE FUNCTION public.exos_set_google_ads_token(
  p_org_id        uuid,
  p_user_id       uuid,
  p_refresh_token text
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_row    public.exos_org_ad_credentials%ROWTYPE;
  v_secret uuid;
  v_name   text := 'exos_ad:' || p_org_id::text || ':google_ads';
BEGIN
  IF NOT public._exos_oauth_can_connect(p_org_id, p_user_id) THEN
    RAISE EXCEPTION 'exos_set_google_ads_token: owner or manager only' USING ERRCODE = '42501';
  END IF;
  IF p_refresh_token IS NULL OR length(p_refresh_token) NOT BETWEEN 8 AND 4096
     OR p_refresh_token ~ '[[:cntrl:][:space:]]' THEN
    RAISE EXCEPTION 'exos_set_google_ads_token: bad token' USING ERRCODE = '22023';
  END IF;

  SELECT * INTO v_row FROM public.exos_org_ad_credentials
   WHERE org_id = p_org_id AND platform = 'google_ads' FOR UPDATE;
  v_secret := v_row.secret_id;
  IF v_secret IS NULL OR NOT EXISTS (SELECT 1 FROM vault.secrets WHERE id = v_secret) THEN
    SELECT id INTO v_secret FROM vault.secrets WHERE name = v_name;
  END IF;
  IF v_secret IS NULL THEN
    v_secret := vault.create_secret(p_refresh_token, v_name, 'Exos ad conversions token (google_ads, OAuth)');
  ELSE
    PERFORM vault.update_secret(v_secret, p_refresh_token);
  END IF;

  INSERT INTO public.exos_org_ad_credentials AS c
         (org_id, platform, config, secret_id, enabled, created_by, updated_by)
  VALUES (p_org_id, 'google_ads', '{}'::jsonb, v_secret, false, p_user_id, p_user_id)
  ON CONFLICT (org_id, platform) DO UPDATE
     SET secret_id = EXCLUDED.secret_id, updated_by = p_user_id;

  SELECT * INTO v_row FROM public.exos_org_ad_credentials
   WHERE org_id = p_org_id AND platform = 'google_ads';
  RETURN jsonb_build_object('platform', 'google_ads', 'has_secret', v_row.secret_id IS NOT NULL,
                            'enabled', v_row.enabled);
END $$;
REVOKE ALL ON FUNCTION public.exos_set_google_ads_token(uuid, uuid, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_set_google_ads_token(uuid, uuid, text) TO service_role;
