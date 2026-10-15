-- ============================================================================
-- Bring your own credentials: one place per org for third-party accounts
-- ============================================================================
-- Touches:  C: TABLE exos_org_integrations (RLS on, no policies: RPCs only)
--           C: FUNCTION exos_integration_providers, _exos_integ_role,
--              exos_list_integrations, exos_save_integration,
--              exos_remove_integration (authenticated, owner / manager),
--              exos_integration_secret, exos_integration_mark,
--              exos_integration_config (service role)
--           R: vault.secrets / vault.create_secret / vault.update_secret /
--              vault.decrypted_secrets (Supabase Vault)
-- Pre-reqs: the org + membership tables; Supabase Vault
--
-- Exos is open source: whoever runs it (or each organizer on a shared
-- install) brings their own accounts. An owner / manager pastes a provider's
-- token or key in Org settings -> Integrations. The secret goes to Vault
-- (exos_integration:<org>:<provider>) and is never read back by the browser;
-- only the service role (edge functions) reads it. Non-secret settings
-- (a self-hosted pretix URL and organizer slug, a sending phone number, an
-- account id) live in `config`, readable by the org.
--
-- Providers (each a read or a send the org itself owns):
--   ticket backends (read-only sync): pretix, hievents
--   SMS: twilio, telnyx (the org's own sender; Exos sends only with consent)
--   resale marketplaces (reads only; writes stay dry-run, CLAUDE.md):
--     stubhub, seatgeek, vivid, tickpick, gametime, tevo
-- Eventbrite keeps its own connect flow (exos_eventbrite_accounts).
--
-- A save marks the integration 'unverified'; the exos-integrations edge
-- function tests it against the provider (a read) and marks it
-- 'connected' or 'error' (exos_integration_mark).
--
-- Re-run safe. Prod apply needs operator OK.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.exos_integration_providers()
RETURNS text[]
LANGUAGE sql IMMUTABLE
SET search_path = public, pg_temp
AS $$
  SELECT ARRAY['pretix', 'hievents', 'twilio', 'telnyx',
               'stubhub', 'seatgeek', 'vivid', 'tickpick', 'gametime', 'tevo']::text[]
$$;
GRANT EXECUTE ON FUNCTION public.exos_integration_providers() TO anon, authenticated, service_role;

CREATE TABLE IF NOT EXISTS public.exos_org_integrations (
  org_id          uuid NOT NULL REFERENCES public.exos_orgs (id) ON DELETE CASCADE,
  provider        text NOT NULL CHECK (provider = ANY (public.exos_integration_providers())),
  label           text CHECK (label IS NULL OR length(label) <= 80),
  config          jsonb NOT NULL DEFAULT '{}'::jsonb
                    CHECK (jsonb_typeof(config) = 'object' AND length(config::text) <= 4000),
  secret_id       uuid,                    -- vault.secrets id; never the secret
  secret_hint     text CHECK (secret_hint IS NULL OR length(secret_hint) <= 12),
  status          text NOT NULL DEFAULT 'unverified'
                    CHECK (status IN ('unverified', 'connected', 'error', 'disabled')),
  account_name    text CHECK (account_name IS NULL OR length(account_name) <= 120),
  last_checked_at timestamptz,
  last_error      text CHECK (last_error IS NULL OR length(last_error) <= 200),
  connected_by    uuid REFERENCES auth.users (id) ON DELETE SET NULL,
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (org_id, provider)
);
ALTER TABLE public.exos_org_integrations ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.exos_org_integrations FROM PUBLIC, anon, authenticated;

-- The caller's role in the org (owner / manager / finance), or NULL.
CREATE OR REPLACE FUNCTION public._exos_integ_role(p_org_id uuid, p_user_id uuid)
RETURNS text LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT m.role FROM public.exos_org_memberships m
   WHERE p_org_id IS NOT NULL AND p_user_id IS NOT NULL
     AND m.org_id = p_org_id AND m.user_id = p_user_id AND m.disabled IS NOT TRUE
     AND m.role IN ('owner', 'manager', 'finance')
   ORDER BY CASE m.role WHEN 'owner' THEN 0 WHEN 'manager' THEN 1 ELSE 2 END
   LIMIT 1
$$;
REVOKE ALL ON FUNCTION public._exos_integ_role(uuid, uuid) FROM PUBLIC, anon, authenticated;

-- Owner / manager / finance: what's connected (never a secret).
CREATE OR REPLACE FUNCTION public.exos_list_integrations(p_org_id uuid)
RETURNS TABLE (provider text, label text, config jsonb, secret_hint text, has_secret boolean, status text,
               account_name text, last_checked_at timestamptz, last_error text, updated_at timestamptz)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF public._exos_integ_role(p_org_id, auth.uid()) IS NULL THEN
    RAISE EXCEPTION 'exos_list_integrations: not authorized' USING ERRCODE = '42501';
  END IF;
  RETURN QUERY
    SELECT i.provider, i.label, i.config, i.secret_hint, i.secret_id IS NOT NULL, i.status,
           i.account_name, i.last_checked_at, i.last_error, i.updated_at
      FROM public.exos_org_integrations i
     WHERE i.org_id = p_org_id
     ORDER BY i.provider;
END $$;
REVOKE ALL ON FUNCTION public.exos_list_integrations(uuid) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.exos_list_integrations(uuid) TO authenticated, service_role;

-- Owner / manager: save settings and (optionally) a new secret. A NULL or
-- empty secret keeps the stored one, so settings can change without
-- re-pasting the token. Returns the row as listed.
CREATE OR REPLACE FUNCTION public.exos_save_integration(
  p_org_id uuid, p_provider text, p_config jsonb DEFAULT '{}'::jsonb, p_secret text DEFAULT NULL, p_label text DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_uid    uuid := auth.uid();
  v_role   text := public._exos_integ_role(p_org_id, auth.uid());
  v_name   text := 'exos_integration:' || p_org_id::text || ':' || coalesce(p_provider, '');
  v_secret uuid;
  v_new    text := nullif(btrim(coalesce(p_secret, '')), '');
  v_cfg    jsonb := coalesce(p_config, '{}'::jsonb);
BEGIN
  IF coalesce(v_role, '') NOT IN ('owner', 'manager') THEN
    RAISE EXCEPTION 'exos_save_integration: owner or manager only' USING ERRCODE = '42501';
  END IF;
  IF p_provider IS NULL OR NOT (p_provider = ANY (public.exos_integration_providers())) THEN
    RAISE EXCEPTION 'exos_save_integration: unknown provider' USING ERRCODE = '22023';
  END IF;
  IF jsonb_typeof(v_cfg) <> 'object' OR length(v_cfg::text) > 4000 THEN
    RAISE EXCEPTION 'exos_save_integration: settings must be a small object' USING ERRCODE = '22023';
  END IF;
  -- Settings are plain values: a secret pasted into a settings field is refused.
  IF EXISTS (SELECT 1 FROM jsonb_each(v_cfg) x
              WHERE jsonb_typeof(x.value) NOT IN ('string', 'number', 'boolean')
                 OR x.key ~* '(token|secret|password|key)$') THEN
    RAISE EXCEPTION 'exos_save_integration: settings hold plain values; put the token in the secret field' USING ERRCODE = '22023';
  END IF;
  IF v_new IS NOT NULL AND length(v_new) > 4000 THEN
    RAISE EXCEPTION 'exos_save_integration: that secret is too long' USING ERRCODE = '22023';
  END IF;

  SELECT secret_id INTO v_secret FROM public.exos_org_integrations WHERE org_id = p_org_id AND provider = p_provider FOR UPDATE;
  IF v_new IS NOT NULL THEN
    IF v_secret IS NULL OR NOT EXISTS (SELECT 1 FROM vault.secrets WHERE id = v_secret) THEN
      SELECT id INTO v_secret FROM vault.secrets WHERE name = v_name;
    END IF;
    IF v_secret IS NULL THEN
      v_secret := vault.create_secret(v_new, v_name, 'Exos integration secret (' || p_provider || ')');
    ELSE
      PERFORM vault.update_secret(v_secret, v_new);
    END IF;
  END IF;

  INSERT INTO public.exos_org_integrations AS i
         (org_id, provider, label, config, secret_id, secret_hint, status, connected_by, last_error, updated_at)
  VALUES (p_org_id, p_provider, left(nullif(btrim(coalesce(p_label, '')), ''), 80), v_cfg, v_secret,
          CASE WHEN v_new IS NOT NULL THEN '…' || right(v_new, 4) END, 'unverified', v_uid, NULL, now())
  ON CONFLICT (org_id, provider) DO UPDATE
     SET label = EXCLUDED.label, config = EXCLUDED.config,
         secret_id = coalesce(EXCLUDED.secret_id, i.secret_id),
         secret_hint = coalesce(EXCLUDED.secret_hint, i.secret_hint),
         status = 'unverified', connected_by = EXCLUDED.connected_by, last_error = NULL, updated_at = now();

  RETURN (SELECT jsonb_build_object('provider', i.provider, 'status', i.status, 'has_secret', i.secret_id IS NOT NULL,
                                    'secret_hint', i.secret_hint, 'config', i.config)
            FROM public.exos_org_integrations i WHERE i.org_id = p_org_id AND i.provider = p_provider);
END $$;
REVOKE ALL ON FUNCTION public.exos_save_integration(uuid, text, jsonb, text, text) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.exos_save_integration(uuid, text, jsonb, text, text) TO authenticated, service_role;

-- Owner / manager: disconnect (the secret is deleted from Vault).
CREATE OR REPLACE FUNCTION public.exos_remove_integration(p_org_id uuid, p_provider text)
RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE v_secret uuid;
BEGIN
  IF coalesce(public._exos_integ_role(p_org_id, auth.uid()), '') NOT IN ('owner', 'manager') THEN
    RAISE EXCEPTION 'exos_remove_integration: owner or manager only' USING ERRCODE = '42501';
  END IF;
  DELETE FROM public.exos_org_integrations WHERE org_id = p_org_id AND provider = p_provider RETURNING secret_id INTO v_secret;
  IF NOT FOUND THEN RETURN false; END IF;
  DELETE FROM vault.secrets
   WHERE id = v_secret OR name = 'exos_integration:' || p_org_id::text || ':' || p_provider;
  RETURN true;
END $$;
REVOKE ALL ON FUNCTION public.exos_remove_integration(uuid, text) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.exos_remove_integration(uuid, text) TO authenticated, service_role;

-- Service role: the settings and the secret, for an edge function to use.
CREATE OR REPLACE FUNCTION public.exos_integration_config(p_org_id uuid, p_provider text)
RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT jsonb_build_object('provider', i.provider, 'status', i.status, 'config', i.config,
                            'secret', (SELECT d.decrypted_secret FROM vault.decrypted_secrets d WHERE d.id = i.secret_id))
    FROM public.exos_org_integrations i
   WHERE i.org_id = p_org_id AND i.provider = p_provider AND i.status <> 'disabled'
$$;
REVOKE ALL ON FUNCTION public.exos_integration_config(uuid, text) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.exos_integration_config(uuid, text) TO service_role;

-- Service role: the result of a test against the provider.
CREATE OR REPLACE FUNCTION public.exos_integration_mark(
  p_org_id uuid, p_provider text, p_ok boolean, p_error text DEFAULT NULL, p_account_name text DEFAULT NULL
) RETURNS boolean
LANGUAGE sql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  UPDATE public.exos_org_integrations
     SET status = CASE WHEN p_ok THEN 'connected' ELSE 'error' END,
         last_error = CASE WHEN p_ok THEN NULL ELSE left(coalesce(nullif(btrim(p_error), ''), 'test failed'), 200) END,
         account_name = CASE WHEN p_ok THEN coalesce(left(nullif(btrim(p_account_name), ''), 120), account_name) ELSE account_name END,
         last_checked_at = now(), updated_at = now()
   WHERE org_id = p_org_id AND provider = p_provider AND status <> 'disabled'
  RETURNING true
$$;
REVOKE ALL ON FUNCTION public.exos_integration_mark(uuid, text, boolean, text, text) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.exos_integration_mark(uuid, text, boolean, text, text) TO service_role;

-- ROLLBACK (manual): drop the functions above and exos_org_integrations;
-- delete vault.secrets named 'exos_integration:%'.
