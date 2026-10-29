-- ============================================================================
-- Migration 20261029140000 — Exos (Bridge / D4): "Connect Eventbrite" (OAuth)
--
-- Lane:     d4 (exos / bridge ticketing infra)
-- Touches:  W: TABLE exos_oauth_states (+ provider 'eventbrite', + return_event_id)
--              TABLE exos_eventbrite_accounts (+ auth_method)
--           C: TABLE exos_eventbrite_connection_log (new; service role only)
--           C: FUNCTION _exos_eventbrite_store, exos_eventbrite_connect_oauth,
--              exos_eventbrite_oauth_begin, exos_eventbrite_oauth_consume
--              (service role only); exos_eventbrite_org_status
--              (authenticated, role-checked)
--           W: FUNCTION exos_oauth_state_begin (+ provider 'eventbrite'),
--              exos_oauth_state_consume (Google Ads states only now),
--              exos_eventbrite_connect (same checks; records auth_method and
--              the log), exos_eventbrite_disconnect (same; + the log),
--              exos_eventbrite_status (patched in place: + auth_method)
--           R: exos_org_memberships, exos_events, vault.secrets /
--              vault.create_secret / vault.update_secret (Supabase Vault)
-- Pre-reqs: 20260930102000 (exos_oauth_states and its RPCs),
--           20261013100000 (Eventbrite accounts, links, Vault naming
--           exos_eventbrite:<org>), 20261014120000 (exos_eventbrite_status as
--           patched there).
--
-- Spec item 1 of the distribution layer: an organizer connects Eventbrite in
-- one click instead of pasting a private token. The exos-eventbrite-oauth
-- edge function runs the same three steps as exos-oauth-google:
--
--   1. /start   (owner / manager, JWT): a random 256-bit state; only its
--               SHA-256 is stored (exos_eventbrite_oauth_begin -> the shared
--               exos_oauth_state_begin: 10-minute expiry, at most 10 starts a
--               user in 10 minutes), optionally with the Exos event to go
--               back to (it must be the org's). The browser goes to
--               Eventbrite's authorize page.
--   2. /callback (Eventbrite redirects the browser, no JWT): the code is
--               parked on the state (exos_oauth_state_return, first return
--               only) and the browser goes back to the org's settings page.
--   3. /finish  (settings page, JWT): the state is consumed ONLY by the user
--               who started it, once, before expiry, and only an Eventbrite
--               state (exos_eventbrite_oauth_consume). The code is exchanged
--               server side, the token checked with GET /users/me/, then
--               stored in Vault exactly where the pasted private token goes
--               (exos_eventbrite:<org>) with auth_method 'oauth'
--               (exos_eventbrite_connect_oauth).
--
-- Step 3's user check stops login CSRF: an authorize link started by someone
-- else and finished in a victim's browser can't attach the victim's
-- Eventbrite account to the other person's org.
--
-- The pasted private token keeps working (exos_eventbrite_connect, unchanged
-- checks): it is how the pilot runs before Eventbrite approves the app, and
-- what the SPA shows when the OAuth client isn't configured.
--
-- Disconnect stays local: the Vault secret is deleted and the links removed
-- (as before); imported guests stay; a row in exos_eventbrite_connection_log
-- keeps who connected, how, and when it ended. Eventbrite documents no token
-- revocation endpoint, so nothing is sent to Eventbrite.
--
-- Nothing here writes to Eventbrite. writes_enabled stays false for a new
-- account (an OAuth reconnect keeps the org's existing switch, as a private
-- token reconnect does).
--
-- Re-run safe (IF NOT EXISTS, CREATE OR REPLACE, guarded constraints, marker
-- checked patch). D4 authors; applying to prod is operator-gated. NOT applied.
-- ============================================================================

CREATE OR REPLACE FUNCTION pg_temp.exos_patch_n(p_sig text, p_marker text, p_old text, p_new text, p_hits int)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE p_fn regprocedure := to_regprocedure(p_sig); v_def text; v_hits int;
BEGIN
  IF p_fn IS NULL THEN
    RAISE EXCEPTION '%: not present', p_sig;
  END IF;
  v_def := pg_get_functiondef(p_fn);
  IF position(p_marker in v_def) > 0 THEN
    RAISE NOTICE '%: already patched (%)', p_fn, p_marker;
    RETURN;
  END IF;
  v_hits := (length(v_def) - length(replace(v_def, p_old, ''))) / length(p_old);
  IF v_hits <> p_hits THEN
    RAISE EXCEPTION '%: expected % match(es) for patch "%", found %', p_fn, p_hits, p_marker, v_hits;
  END IF;
  EXECUTE replace(v_def, p_old, p_new);
END $$;

-- ---------------------------------------------------------------------------
-- 1. States: Eventbrite as a provider, and the Exos event to go back to.
-- ---------------------------------------------------------------------------
ALTER TABLE public.exos_oauth_states
  ADD COLUMN IF NOT EXISTS return_event_id uuid REFERENCES public.exos_events (id) ON DELETE SET NULL;

DO $c$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint
                  WHERE conname = 'exos_oauth_states_provider_chk'
                    AND pg_get_constraintdef(oid) LIKE '%eventbrite%') THEN
    ALTER TABLE public.exos_oauth_states DROP CONSTRAINT IF EXISTS exos_oauth_states_provider_chk;
    ALTER TABLE public.exos_oauth_states ADD CONSTRAINT exos_oauth_states_provider_chk
      CHECK (provider IN ('google_ads', 'eventbrite'));
  END IF;
END $c$;

COMMENT ON TABLE public.exos_oauth_states IS
  'Single-use OAuth states for exos-oauth-google (Connect Google Ads) and exos-eventbrite-oauth (Connect Eventbrite). SHA-256 of the state only; 10-minute expiry; service role only. migs 20260930102000, 20261029140000.';

-- Same body as 20260930102000, with 'eventbrite' accepted.
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
  IF p_provider IS NULL OR p_provider NOT IN ('google_ads', 'eventbrite') THEN
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

-- Same body as 20260930102000, but only a Google Ads state: exos-oauth-google
-- must not burn (or exchange the code of) an Eventbrite sign-in.
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
   WHERE s.state_hash = p_state_hash AND s.user_id = p_user_id AND s.provider = 'google_ads'
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

-- Start an Eventbrite sign-in: the shared begin (role, rate limit, expiry),
-- plus the Exos event to return to, which must be the org's own.
CREATE OR REPLACE FUNCTION public.exos_eventbrite_oauth_begin(
  p_org_id uuid, p_user_id uuid, p_state_hash text, p_event_id uuid DEFAULT NULL
) RETURNS timestamptz
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_exp timestamptz;
BEGIN
  IF p_event_id IS NOT NULL AND NOT EXISTS (
       SELECT 1 FROM public.exos_events e WHERE e.id = p_event_id AND e.org_id = p_org_id) THEN
    RAISE EXCEPTION 'exos_eventbrite_oauth_begin: that event is not this organization''s' USING ERRCODE = '22023';
  END IF;
  v_exp := public.exos_oauth_state_begin('eventbrite', p_org_id, p_user_id, p_state_hash, 10);
  IF p_event_id IS NOT NULL THEN
    UPDATE public.exos_oauth_states SET return_event_id = p_event_id WHERE state_hash = p_state_hash;
  END IF;
  RETURN v_exp;
END $$;
REVOKE ALL ON FUNCTION public.exos_eventbrite_oauth_begin(uuid, uuid, text, uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_eventbrite_oauth_begin(uuid, uuid, text, uuid) TO service_role;

-- Use an Eventbrite state: only by the user who started it, once, before it
-- expires, after Eventbrite returned a code, while that user is still an
-- owner / manager. Returns (org_id, code, return_event_id) and clears the
-- stored code, or no row. A refused attempt by the right user still burns it.
CREATE OR REPLACE FUNCTION public.exos_eventbrite_oauth_consume(p_state_hash text, p_user_id uuid)
RETURNS TABLE(org_id uuid, code text, return_event_id uuid)
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
   WHERE s.state_hash = p_state_hash AND s.user_id = p_user_id AND s.provider = 'eventbrite'
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
  return_event_id := v_row.return_event_id;
  RETURN NEXT;
END $$;
REVOKE ALL ON FUNCTION public.exos_eventbrite_oauth_consume(text, uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_eventbrite_oauth_consume(text, uuid) TO service_role;

-- ---------------------------------------------------------------------------
-- 2. Accounts: how the token was obtained, and a connection history.
-- ---------------------------------------------------------------------------
ALTER TABLE public.exos_eventbrite_accounts
  ADD COLUMN IF NOT EXISTS auth_method text NOT NULL DEFAULT 'private_token';
DO $c$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'exos_eventbrite_accounts_auth_method_chk') THEN
    ALTER TABLE public.exos_eventbrite_accounts ADD CONSTRAINT exos_eventbrite_accounts_auth_method_chk
      CHECK (auth_method IN ('private_token', 'oauth'));
  END IF;
END $c$;

CREATE TABLE IF NOT EXISTS public.exos_eventbrite_connection_log (
  id           bigserial PRIMARY KEY,
  org_id       uuid NOT NULL REFERENCES public.exos_orgs (id) ON DELETE CASCADE,
  action       text NOT NULL CONSTRAINT exos_eb_conn_log_action_chk CHECK (action IN ('connect', 'disconnect')),
  auth_method  text CONSTRAINT exos_eb_conn_log_method_chk CHECK (auth_method IS NULL OR auth_method IN ('private_token', 'oauth')),
  account_name text CHECK (account_name IS NULL OR length(account_name) <= 120),
  user_id      uuid,
  at           timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS exos_eb_conn_log_org_idx ON public.exos_eventbrite_connection_log (org_id, at DESC);
ALTER TABLE public.exos_eventbrite_connection_log ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.exos_eventbrite_connection_log FROM PUBLIC, anon, authenticated;
GRANT ALL ON TABLE public.exos_eventbrite_connection_log TO service_role;
REVOKE ALL ON SEQUENCE public.exos_eventbrite_connection_log_id_seq FROM PUBLIC, anon, authenticated;
GRANT USAGE, SELECT ON SEQUENCE public.exos_eventbrite_connection_log_id_seq TO service_role;
COMMENT ON TABLE public.exos_eventbrite_connection_log IS
  'Exos Door: who connected / disconnected an org''s Eventbrite account, how (private token or OAuth) and when. No tokens. Service role only. mig 20261029140000.';

-- The one place a token is stored: Vault exos_eventbrite:<org>, the account
-- row, the log. Role checked by the callers AND here. Every link's next pass
-- starts over (another account may see other events), as before.
CREATE OR REPLACE FUNCTION public._exos_eventbrite_store(
  p_org_id uuid, p_user_id uuid, p_token text, p_account_name text, p_method text
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_secret uuid;
  v_name   text := 'exos_eventbrite:' || p_org_id::text;
  v_acct   text := left(nullif(btrim(coalesce(p_account_name, '')), ''), 120);
BEGIN
  IF coalesce(public._exos_eb_role(p_org_id, p_user_id), '') NOT IN ('owner', 'manager') THEN
    RAISE EXCEPTION '_exos_eventbrite_store: owner or manager only' USING ERRCODE = '42501';
  END IF;
  IF p_method IS NULL OR p_method NOT IN ('private_token', 'oauth') THEN
    RAISE EXCEPTION '_exos_eventbrite_store: bad method' USING ERRCODE = '22023';
  END IF;
  IF p_token IS NULL OR p_token !~ '^[A-Za-z0-9_-]{8,255}$' THEN
    RAISE EXCEPTION '_exos_eventbrite_store: bad token' USING ERRCODE = '22023';
  END IF;

  SELECT secret_id INTO v_secret FROM public.exos_eventbrite_accounts WHERE org_id = p_org_id FOR UPDATE;
  IF v_secret IS NULL OR NOT EXISTS (SELECT 1 FROM vault.secrets WHERE id = v_secret) THEN
    SELECT id INTO v_secret FROM vault.secrets WHERE name = v_name;
  END IF;
  IF v_secret IS NULL THEN
    v_secret := vault.create_secret(p_token, v_name,
      CASE p_method WHEN 'oauth' THEN 'Exos Door: Eventbrite OAuth token (read-only sync)'
                    ELSE 'Exos Door: Eventbrite private token (read-only sync)' END);
  ELSE
    PERFORM vault.update_secret(v_secret, p_token);
  END IF;

  INSERT INTO public.exos_eventbrite_accounts AS a (org_id, secret_id, account_name, connected_by, connected_at, auth_method)
  VALUES (p_org_id, v_secret, v_acct, p_user_id, now(), p_method)
  ON CONFLICT (org_id) DO UPDATE
     SET secret_id = EXCLUDED.secret_id, account_name = EXCLUDED.account_name,
         connected_by = EXCLUDED.connected_by, connected_at = EXCLUDED.connected_at,
         auth_method = EXCLUDED.auth_method;
  UPDATE public.exos_eventbrite_links
     SET sync_cursor = NULL, continuation = NULL, pass_started_at = NULL, last_error = NULL,
         pass_errors = 0, lease_id = NULL, lease_until = NULL
   WHERE org_id = p_org_id;
  INSERT INTO public.exos_eventbrite_connection_log (org_id, action, auth_method, account_name, user_id)
  VALUES (p_org_id, 'connect', p_method, v_acct, p_user_id);
  RETURN jsonb_build_object('connected', true, 'account_name', v_acct, 'auth_method', p_method);
END $$;
REVOKE ALL ON FUNCTION public._exos_eventbrite_store(uuid, uuid, text, text, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_eventbrite_store(uuid, uuid, text, text, text) TO service_role;

-- Pasted private token (unchanged contract; the error prefix is kept).
CREATE OR REPLACE FUNCTION public.exos_eventbrite_connect(
  p_org_id uuid, p_user_id uuid, p_token text, p_account_name text
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF coalesce(public._exos_eb_role(p_org_id, p_user_id), '') NOT IN ('owner', 'manager') THEN
    RAISE EXCEPTION 'exos_eventbrite_connect: owner or manager only' USING ERRCODE = '42501';
  END IF;
  IF p_token IS NULL OR p_token !~ '^[A-Za-z0-9_-]{8,255}$' THEN
    RAISE EXCEPTION 'exos_eventbrite_connect: bad token' USING ERRCODE = '22023';
  END IF;
  RETURN public._exos_eventbrite_store(p_org_id, p_user_id, p_token, p_account_name, 'private_token');
END $$;
REVOKE ALL ON FUNCTION public.exos_eventbrite_connect(uuid, uuid, text, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_eventbrite_connect(uuid, uuid, text, text) TO service_role;

-- OAuth token from /finish (the edge function exchanged the code and checked
-- the token with GET /users/me/).
CREATE OR REPLACE FUNCTION public.exos_eventbrite_connect_oauth(
  p_org_id uuid, p_user_id uuid, p_token text, p_account_name text
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF coalesce(public._exos_eb_role(p_org_id, p_user_id), '') NOT IN ('owner', 'manager') THEN
    RAISE EXCEPTION 'exos_eventbrite_connect_oauth: owner or manager only' USING ERRCODE = '42501';
  END IF;
  IF p_token IS NULL OR p_token !~ '^[A-Za-z0-9_-]{8,255}$' THEN
    RAISE EXCEPTION 'exos_eventbrite_connect_oauth: bad token' USING ERRCODE = '22023';
  END IF;
  RETURN public._exos_eventbrite_store(p_org_id, p_user_id, p_token, p_account_name, 'oauth');
END $$;
REVOKE ALL ON FUNCTION public.exos_eventbrite_connect_oauth(uuid, uuid, text, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_eventbrite_connect_oauth(uuid, uuid, text, text) TO service_role;

-- Disconnect: as 20261013100000 (token deleted from Vault, links removed,
-- imported guests kept), plus a log row. Local only.
CREATE OR REPLACE FUNCTION public.exos_eventbrite_disconnect(p_org_id uuid, p_user_id uuid)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_secret uuid;
  v_method text;
  v_acct   text;
  v_links  int;
BEGIN
  IF coalesce(public._exos_eb_role(p_org_id, p_user_id), '') NOT IN ('owner', 'manager') THEN
    RAISE EXCEPTION 'exos_eventbrite_disconnect: owner or manager only' USING ERRCODE = '42501';
  END IF;
  DELETE FROM public.exos_eventbrite_accounts WHERE org_id = p_org_id
  RETURNING secret_id, auth_method, account_name INTO v_secret, v_method, v_acct;
  DELETE FROM vault.secrets WHERE id = v_secret OR name = 'exos_eventbrite:' || p_org_id::text;
  DELETE FROM public.exos_eventbrite_links WHERE org_id = p_org_id;
  GET DIAGNOSTICS v_links = ROW_COUNT;
  IF v_method IS NOT NULL THEN
    INSERT INTO public.exos_eventbrite_connection_log (org_id, action, auth_method, account_name, user_id)
    VALUES (p_org_id, 'disconnect', v_method, v_acct, p_user_id);
  END IF;
  RETURN jsonb_build_object('connected', false, 'unlinked', v_links, 'auth_method', v_method);
END $$;
REVOKE ALL ON FUNCTION public.exos_eventbrite_disconnect(uuid, uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_eventbrite_disconnect(uuid, uuid) TO service_role;

-- ---------------------------------------------------------------------------
-- 3. The door page says how the account is connected (never the token).
-- ---------------------------------------------------------------------------
SELECT pg_temp.exos_patch_n('public.exos_eventbrite_status(uuid)',
  '''auth_method''',
  $o$'account_name', a.account_name,$o$,
  $n$'account_name', a.account_name,
    'auth_method', a.auth_method,$n$, 1);

-- ---------------------------------------------------------------------------
-- 4. Org settings → Integrations: the org's Eventbrite connection and its
-- history (door roles, scanner included; can_manage for owner / manager).
-- Never the token, never who (user ids) beyond "you or someone else".
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.exos_eventbrite_org_status(p_org_id uuid)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_role text;
  a      public.exos_eventbrite_accounts%ROWTYPE;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'exos_eventbrite_org_status: not authenticated' USING ERRCODE = '42501';
  END IF;
  v_role := public._exos_eb_role(p_org_id, auth.uid());
  IF v_role IS NULL AND NOT public.exos_is_admin() THEN
    RAISE EXCEPTION 'exos_eventbrite_org_status: not authorized for this organization' USING ERRCODE = '42501';
  END IF;
  SELECT * INTO a FROM public.exos_eventbrite_accounts WHERE org_id = p_org_id;
  RETURN jsonb_build_object(
    'can_manage', v_role IN ('owner', 'manager') OR public.exos_is_admin(),
    'connected', a.org_id IS NOT NULL,
    'account_name', a.account_name,
    'auth_method', a.auth_method,
    'connected_at', a.connected_at,
    'linked_events', (SELECT count(*) FROM public.exos_eventbrite_links l WHERE l.org_id = p_org_id),
    'history', coalesce((SELECT jsonb_agg(jsonb_build_object(
                 'action', h.action, 'auth_method', h.auth_method, 'account_name', h.account_name,
                 'at', h.at, 'by_you', h.user_id = auth.uid()) ORDER BY h.at DESC, h.id DESC)
               FROM (SELECT * FROM public.exos_eventbrite_connection_log
                      WHERE org_id = p_org_id ORDER BY at DESC, id DESC LIMIT 10) h), '[]'::jsonb));
END $$;
REVOKE ALL ON FUNCTION public.exos_eventbrite_org_status(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.exos_eventbrite_org_status(uuid) TO authenticated, service_role;
