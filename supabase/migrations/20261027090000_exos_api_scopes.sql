-- ============================================================================
-- Partner API scopes (2026-10-27). Port of the Firebase build's scopes
-- (Exos-Bridge PR #1, server/apiScopes.ts) onto exos_api_keys.scopes.
--
-- exos_api_keys has had `scopes text[] DEFAULT ARRAY['read']` since
-- 20260616200000, but nothing set or checked it. Now:
--   * exos_api_scope_names(): the scope vocabulary. Must equal SCOPES in
--     supabase/functions/_shared/api/scopes.ts (src/lib/apiScopes.test.ts).
--   * exos_create_api_key(org, name, scopes): a key held to those scopes.
--     The old (org, name) form still works and makes a `read` key, as before.
--   * exos_set_api_key_scopes(key, scopes): narrow or widen a live key.
--   * At most 10 active keys per organization.
-- The exos-api edge function enforces the scopes per route. `read` (every
-- key made before today) keeps covering every `:read` scope there.
--
-- Additive: no table change, no data change. Re-run safe.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.exos_api_scope_names()
RETURNS text[]
LANGUAGE sql IMMUTABLE
SET search_path = public, pg_temp
AS $$
  SELECT ARRAY[
    'events:read', 'events:write', 'orders:read', 'tickets:read', 'tickets:write',
    'checkin:write', 'booking:read', 'booking:write', 'finance:read', 'finance:write',
    'commerce:read', 'commerce:write', 'webhooks:read', 'webhooks:write', 'org:admin'
  ]::text[]
$$;
REVOKE ALL ON FUNCTION public.exos_api_scope_names() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.exos_api_scope_names() TO authenticated, service_role;

-- Validate and normalize a scope list: known names (or the legacy `read`)
-- only, no duplicates, in vocabulary order with `read` first. Internal.
CREATE OR REPLACE FUNCTION public._exos_api_clean_scopes(p_scopes text[])
RETURNS text[]
LANGUAGE plpgsql IMMUTABLE
SET search_path = public, pg_temp
AS $$
DECLARE
  v_names text[] := ARRAY['read'] || public.exos_api_scope_names();
  v_bad   text;
  v_out   text[];
BEGIN
  IF p_scopes IS NULL OR cardinality(p_scopes) = 0 THEN
    RAISE EXCEPTION 'exos_api_scopes: a key needs at least one scope' USING ERRCODE = '22023';
  END IF;
  IF cardinality(p_scopes) > 2 * cardinality(v_names) THEN
    RAISE EXCEPTION 'exos_api_scopes: too many scopes' USING ERRCODE = '22023';
  END IF;
  SELECT s INTO v_bad FROM unnest(p_scopes) s WHERE s IS NULL OR NOT (s = ANY (v_names)) LIMIT 1;
  IF FOUND THEN
    RAISE EXCEPTION 'exos_api_scopes: unknown scope %', left(coalesce(v_bad, 'null'), 40) USING ERRCODE = '22023';
  END IF;
  SELECT array_agg(n ORDER BY i) INTO v_out
  FROM unnest(v_names) WITH ORDINALITY AS t(n, i)
  WHERE n = ANY (p_scopes);
  RETURN v_out;
END $$;
REVOKE ALL ON FUNCTION public._exos_api_clean_scopes(text[]) FROM PUBLIC, anon, authenticated;

-- Create a key held to p_scopes. Plaintext returned ONCE, as before.
CREATE OR REPLACE FUNCTION public.exos_create_api_key(p_org_id uuid, p_name text, p_scopes text[])
RETURNS text
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_uid    uuid := auth.uid();
  v_scopes text[];
  v_key    text;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'exos_create_api_key: not authenticated' USING ERRCODE = '42501';
  END IF;
  IF NOT exos_has_org_role(p_org_id, ARRAY['owner','manager']) THEN
    RAISE EXCEPTION 'exos_create_api_key: not authorized' USING ERRCODE = '42501';
  END IF;
  v_scopes := public._exos_api_clean_scopes(p_scopes);
  -- Serialize creates per org so two at once can't both pass the cap.
  PERFORM pg_advisory_xact_lock(hashtextextended('exos_api_keys:' || p_org_id::text, 0));
  IF (SELECT count(*) FROM public.exos_api_keys WHERE org_id = p_org_id AND revoked_at IS NULL) >= 10 THEN
    RAISE EXCEPTION 'exos_create_api_key: at most 10 active keys per organization; revoke one first'
      USING ERRCODE = '54000';
  END IF;
  v_key := 'sk_live_' || encode(extensions.gen_random_bytes(24), 'hex');
  INSERT INTO public.exos_api_keys (org_id, name, key_prefix, key_hash, scopes, created_by)
  VALUES (p_org_id, nullif(btrim(p_name), ''), left(v_key, 16),
          encode(extensions.digest(v_key, 'sha256'), 'hex'), v_scopes, v_uid);
  RETURN v_key;   -- shown to the user ONCE; never recoverable
END $$;
REVOKE ALL ON FUNCTION public.exos_create_api_key(uuid, text, text[]) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.exos_create_api_key(uuid, text, text[]) TO authenticated;

-- The original form: a `read` key, now through the same checks and cap.
CREATE OR REPLACE FUNCTION public.exos_create_api_key(p_org_id uuid, p_name text DEFAULT NULL)
RETURNS text
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  RETURN public.exos_create_api_key(p_org_id, p_name, ARRAY['read']::text[]);
END $$;
REVOKE ALL ON FUNCTION public.exos_create_api_key(uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.exos_create_api_key(uuid, text) TO authenticated;

-- Change a live key's scopes. Owner / manager of the key's org.
CREATE OR REPLACE FUNCTION public.exos_set_api_key_scopes(p_key_id uuid, p_scopes text[])
RETURNS text[]
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_org    uuid;
  v_scopes text[];
BEGIN
  SELECT org_id INTO v_org FROM public.exos_api_keys WHERE id = p_key_id AND revoked_at IS NULL;
  IF v_org IS NULL OR NOT exos_has_org_role(v_org, ARRAY['owner','manager']) THEN
    -- Same answer for "no such key" and "not yours": ids can't be probed.
    RAISE EXCEPTION 'exos_set_api_key_scopes: not authorized' USING ERRCODE = '42501';
  END IF;
  v_scopes := public._exos_api_clean_scopes(p_scopes);
  UPDATE public.exos_api_keys SET scopes = v_scopes, updated_at = now() WHERE id = p_key_id;
  RETURN v_scopes;
END $$;
REVOKE ALL ON FUNCTION public.exos_set_api_key_scopes(uuid, text[]) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.exos_set_api_key_scopes(uuid, text[]) TO authenticated;

COMMENT ON COLUMN public.exos_api_keys.scopes IS
  'mig 20261027090000: what the key may call in exos-api, one scope per route
   (_shared/api/routes.ts). Vocabulary: exos_api_scope_names(), plus the legacy
   `read` = every :read scope. Set only by exos_create_api_key /
   exos_set_api_key_scopes.';
