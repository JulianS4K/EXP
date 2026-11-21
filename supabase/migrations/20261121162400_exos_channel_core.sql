-- ============================================================================
-- Migration 20261121162400 — Exos: the shared channel core (credential store,
-- channel audit, platform usage counters)
-- ============================================================================
-- Touches:  C: FUNCTION _exos_vault_put, _exos_vault_get, _exos_vault_drop
--              (the one Vault seam; no client or service-role EXECUTE)
--           C: FUNCTION _exos_cred_providers, _exos_cred_managed,
--              _exos_integration_put, _exos_integration_drop, _exos_cred_legacy,
--              _exos_cred_copy, _exos_cred_backfill, _exos_tg_cred_mirror,
--              _exos_tg_org_secrets_distribution, _exos_tg_org_secrets_distribution_drop,
--              _exos_tg_integration_vault_drop (internal: no client grant)
--           C: FUNCTION exos_integration_secret (service role: the one decrypt)
--           W: TABLE exos_org_integrations (+ copied_from; the provider CHECK
--              now takes the managed providers too)
--           P: exos_save_integration (1 counted patch: the shared Vault write
--              + an org audit row), exos_remove_integration (1: managed
--              providers refused + an audit row), exos_list_integrations (1:
--              lists the providers Integrations offers, not the copies)
--           W: TRIGGERS on exos_eventbrite_accounts, exos_dice_connections,
--              exos_org_ad_credentials, exos_discord_links (copy into the
--              store), exos_org_secrets (distribution moves to Vault; a
--              deleted row drops it) and exos_org_integrations (a deleted row
--              drops its Vault secret: no secret outlives its row)
--           C: TABLE exos_channel_audit (RLS: owner / manager read their org),
--              FUNCTION _exos_channel_audit_scrub / _scrub_text / _path,
--              exos_channel_audit_record, exos_channel_retention_sweep
--              (service role; a daily cron is wanted, none is scheduled here)
--           C: TABLE exos_channel_usage (RLS on, no client grant), FUNCTION
--              exos_channel_usage_reserve / _read / _release (service role),
--              exos_channel_usage_summary (authenticated, owner / manager)
--           R: vault.secrets / vault.create_secret / vault.update_secret /
--              vault.decrypted_secrets (Supabase Vault), _exos_audit,
--              exos_has_org_role, _exos_integ_role
-- Pre-reqs: 20261016090000 (exos_org_integrations), 20261013100000 /
--           20261029140000 (Eventbrite), 20260930100000 / 20260930102000 (ad
--           credentials), 20261106100000 (DICE), 20261113194000 (Discord),
--           20261109100000 (_exos_audit)
--
-- Operator 2026-11-21: "build and keep read only till build is complete,
-- consolidate where code overlap if it makes sense". Nothing here sends to a
-- third party; no write path or allowlist is added.
--
-- 1. ONE CREDENTIAL STORE. Every per-org third-party credential lives in
--    exos_org_integrations with its secret in Vault
--    (exos_integration:<org>:<provider>), read by the service role through
--    ONE function, exos_integration_secret(org, provider). The providers with
--    their own connect flow (eventbrite, dice, discord, lysted and the six ad
--    platforms as ads_<platform>) are "managed": Integrations' generic save
--    and remove refuse them, and their rows are COPIES kept in step by
--    triggers on the old tables (each old flow writes Vault first, then its
--    row, so the trigger reads the new secret). The old tables, columns and
--    readers stay as they are until a later cleanup; exos_integration_secret
--    reads the store first and falls back to the old table when the store
--    has no secret for a managed provider (_exos_cred_legacy). A failed copy
--    never fails the old flow: it drops the copy (reads fall back) and warns.
--    exos_org_secrets.distribution (plain jsonb, owner / finance readable)
--    is the exception, by priority: its value moves to Vault on every write
--    and the column keeps a stub {in_vault, enabled} (prod had no rows on
--    2026-11-21; nothing server-side reads it).
--    Vault is reached only through _exos_vault_put / _get / _drop, so an
--    install without Vault (or a harness) redefines those three; the SQL
--    harness stubs the vault schema itself (tests/exos/prereq_vault.sql).
-- 2. ONE WRITE PATH. exos_save_integration (owner / manager; never returns
--    the secret, only its last four characters) now writes through
--    _exos_integration_put, the same function the copies use, and records
--    integration.save / integration.remove in the org audit log (provider,
--    whether a new credential was given, the setting names; never a value).
-- 3. CHANNEL AUDIT. exos_channel_audit holds every request the channel core
--    (supabase/functions/_shared/channels/gatedHttp.ts) planned or sent: the
--    channel, op, method, path (query values dropped), live or dry run, the
--    redacted request, a response summary, status and time. Owners and
--    managers read their org's rows (the "What we'd send" panel); only
--    exos_channel_audit_record writes, scrubbing secret-named keys and
--    credential-looking text (the error and warnings too) again and keeping
--    30 days for every org.
-- 4. PLATFORM USAGE. exos_channel_usage counts what a platform's limits count
--    (supabase/functions/_shared/channels/limits.ts: Luma sends, LinkedIn
--    invites, pretix / Ticket Tailor tickets, Eventbrite emails) per org,
--    platform, scope (a calendar, an account) and metric, as rows over
--    rolling windows. Planned (dry-run) usage is kept apart from live usage
--    and counted once per identical request (dedupe), so the preview reads
--    "would use N of M". exos_channel_usage_reserve takes a per-key advisory
--    lock, so two passes can't both spend the last of a budget.
--
-- Built from the live bodies (supabase/README.md rule 4): the three patched
-- bodies were compared with prod's on 2026-11-21 (pg_get_functiondef, CR
-- stripped: same md5 as the chain builds). Re-run safe: each patch skips
-- when its marker is present, CREATE OR REPLACE / IF NOT EXISTS elsewhere.
-- Prod apply needs operator OK.
-- ============================================================================

CREATE OR REPLACE FUNCTION pg_temp.exos_patch_n(p_sig text, p_marker text, p_old text, p_new text, p_hits int)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE p_fn regprocedure := to_regprocedure(p_sig); v_def text; v_hits int;
BEGIN
  IF p_fn IS NULL THEN
    RAISE EXCEPTION '%: not present', p_sig;
  END IF;
  v_def := replace(pg_get_functiondef(p_fn), chr(13), '');
  p_marker := replace(p_marker, chr(13), ''); p_old := replace(p_old, chr(13), ''); p_new := replace(p_new, chr(13), '');
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

-- ===========================================================================
-- 1. The Vault seam
-- ===========================================================================
-- Every Vault call of the store goes through these three. Without Vault,
-- redefine them (same signatures) over any encrypted store.
CREATE OR REPLACE FUNCTION public._exos_vault_put(p_existing uuid, p_name text, p_secret text, p_description text)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE v_id uuid := p_existing;
BEGIN
  IF p_secret IS NULL THEN
    RETURN p_existing;
  END IF;
  IF v_id IS NULL OR NOT EXISTS (SELECT 1 FROM vault.secrets WHERE id = v_id) THEN
    SELECT id INTO v_id FROM vault.secrets WHERE name = p_name;
  END IF;
  IF v_id IS NULL THEN
    v_id := vault.create_secret(p_secret, p_name, coalesce(p_description, ''));
  ELSE
    PERFORM vault.update_secret(v_id, p_secret);
  END IF;
  RETURN v_id;
END $$;

CREATE OR REPLACE FUNCTION public._exos_vault_get(p_id uuid)
RETURNS text LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT d.decrypted_secret FROM vault.decrypted_secrets d WHERE p_id IS NOT NULL AND d.id = p_id
$$;

CREATE OR REPLACE FUNCTION public._exos_vault_drop(p_id uuid, p_name text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  DELETE FROM vault.secrets WHERE (p_id IS NOT NULL AND id = p_id) OR (p_name IS NOT NULL AND name = p_name);
END $$;

REVOKE ALL ON FUNCTION public._exos_vault_put(uuid, text, text, text) FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public._exos_vault_get(uuid) FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public._exos_vault_drop(uuid, text) FROM PUBLIC, anon, authenticated, service_role;

-- ===========================================================================
-- 2. The store: providers, the write core, the copies
-- ===========================================================================
-- Managed: providers with their own connect flow, copied into the store.
CREATE OR REPLACE FUNCTION public._exos_cred_managed(p_provider text)
RETURNS boolean LANGUAGE sql IMMUTABLE
SET search_path = public, pg_temp
AS $$
  SELECT coalesce(p_provider, '') = ANY (ARRAY['eventbrite', 'dice', 'discord', 'lysted',
    'ads_meta', 'ads_tiktok', 'ads_ga4', 'ads_google_ads', 'ads_reddit', 'ads_snap']::text[])
$$;
GRANT EXECUTE ON FUNCTION public._exos_cred_managed(text) TO authenticated, service_role;
REVOKE ALL ON FUNCTION public._exos_cred_managed(text) FROM PUBLIC, anon;

-- Everything the store may hold: what Integrations offers, plus the managed ones.
CREATE OR REPLACE FUNCTION public._exos_cred_providers()
RETURNS text[] LANGUAGE sql IMMUTABLE
SET search_path = public, pg_temp
AS $$
  SELECT public.exos_integration_providers() || ARRAY['eventbrite', 'dice', 'discord', 'lysted',
    'ads_meta', 'ads_tiktok', 'ads_ga4', 'ads_google_ads', 'ads_reddit', 'ads_snap']::text[]
$$;
GRANT EXECUTE ON FUNCTION public._exos_cred_providers() TO authenticated, service_role;
REVOKE ALL ON FUNCTION public._exos_cred_providers() FROM PUBLIC, anon;

ALTER TABLE public.exos_org_integrations DROP CONSTRAINT IF EXISTS exos_org_integrations_provider_check;
ALTER TABLE public.exos_org_integrations DROP CONSTRAINT IF EXISTS exos_org_integrations_provider_chk;
ALTER TABLE public.exos_org_integrations
  ADD CONSTRAINT exos_org_integrations_provider_chk CHECK (provider = ANY (public._exos_cred_providers()));
ALTER TABLE public.exos_org_integrations ADD COLUMN IF NOT EXISTS copied_from text
  CONSTRAINT exos_org_integrations_copied_from_chk CHECK (copied_from IS NULL OR copied_from ~ '^[a-z_.]{3,60}$');
COMMENT ON COLUMN public.exos_org_integrations.copied_from IS
  'Set on a managed provider''s row: the old table it is copied from (kept in step by a trigger) until the cleanup that retires it. NULL: written to the store directly. mig 20261121162400.';

-- The one write of a store row and its secret. A NULL / empty secret keeps
-- the stored one; p_writes NULL keeps the org switch. No client grant.
CREATE OR REPLACE FUNCTION public._exos_integration_put(
  p_org_id uuid, p_provider text, p_secret text, p_config jsonb, p_label text, p_status text,
  p_actor uuid DEFAULT NULL, p_account_name text DEFAULT NULL, p_writes boolean DEFAULT NULL, p_copied_from text DEFAULT NULL
) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_secret uuid;
  v_new    text := nullif(btrim(coalesce(p_secret, '')), '');
  v_actor  uuid;
BEGIN
  IF p_org_id IS NULL OR p_provider IS NULL OR NOT (p_provider = ANY (public._exos_cred_providers())) THEN
    RAISE EXCEPTION '_exos_integration_put: unknown provider' USING ERRCODE = '22023';
  END IF;
  SELECT u.id INTO v_actor FROM auth.users u WHERE u.id = p_actor;
  SELECT secret_id INTO v_secret FROM public.exos_org_integrations
   WHERE org_id = p_org_id AND provider = p_provider FOR UPDATE;
  IF v_new IS NOT NULL THEN
    v_secret := public._exos_vault_put(v_secret, 'exos_integration:' || p_org_id::text || ':' || p_provider, v_new,
                                       'Exos integration secret (' || p_provider || ')');
  END IF;
  INSERT INTO public.exos_org_integrations AS i
         (org_id, provider, label, config, secret_id, secret_hint, status, account_name, connected_by,
          last_error, writes_enabled, copied_from, updated_at)
  VALUES (p_org_id, p_provider, left(nullif(btrim(coalesce(p_label, '')), ''), 80), coalesce(p_config, '{}'::jsonb), v_secret,
          CASE WHEN v_new IS NOT NULL THEN '…' || right(v_new, 4) END, coalesce(p_status, 'unverified'),
          left(nullif(btrim(coalesce(p_account_name, '')), ''), 120), v_actor, NULL, coalesce(p_writes, false),
          p_copied_from, now())
  ON CONFLICT (org_id, provider) DO UPDATE
     SET label = EXCLUDED.label, config = EXCLUDED.config,
         secret_id = coalesce(EXCLUDED.secret_id, i.secret_id),
         secret_hint = coalesce(EXCLUDED.secret_hint, i.secret_hint),
         status = EXCLUDED.status, account_name = coalesce(EXCLUDED.account_name, i.account_name),
         connected_by = EXCLUDED.connected_by, last_error = NULL,
         writes_enabled = CASE WHEN p_writes IS NULL THEN i.writes_enabled ELSE p_writes END,
         copied_from = EXCLUDED.copied_from, updated_at = now();
  RETURN v_secret;
END $$;
REVOKE ALL ON FUNCTION public._exos_integration_put(uuid, text, text, jsonb, text, text, uuid, text, boolean, text)
  FROM PUBLIC, anon, authenticated, service_role;

-- Drops the store row and, always, its Vault secret (by id and by name):
-- also when the row is already gone (an org delete cascades the store rows
-- before the old tables' triggers get here). True when a row was removed.
CREATE OR REPLACE FUNCTION public._exos_integration_drop(p_org_id uuid, p_provider text)
RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_secret uuid;
  v_found  boolean;
BEGIN
  DELETE FROM public.exos_org_integrations WHERE org_id = p_org_id AND provider = p_provider RETURNING secret_id INTO v_secret;
  v_found := FOUND;
  PERFORM public._exos_vault_drop(v_secret, 'exos_integration:' || p_org_id::text || ':' || p_provider);
  RETURN v_found;
END $$;
REVOKE ALL ON FUNCTION public._exos_integration_drop(uuid, text) FROM PUBLIC, anon, authenticated, service_role;

-- Any store row that goes (a remove, a failed copy, an org delete's cascade)
-- takes its Vault secret with it: no secret outlives its row.
CREATE OR REPLACE FUNCTION public._exos_tg_integration_vault_drop()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  PERFORM public._exos_vault_drop(OLD.secret_id, 'exos_integration:' || OLD.org_id::text || ':' || OLD.provider);
  RETURN NULL;
END $$;
REVOKE ALL ON FUNCTION public._exos_tg_integration_vault_drop() FROM PUBLIC, anon, authenticated, service_role;
DROP TRIGGER IF EXISTS exos_org_integrations_vault_drop ON public.exos_org_integrations;
CREATE TRIGGER exos_org_integrations_vault_drop AFTER DELETE ON public.exos_org_integrations
  FOR EACH ROW EXECUTE FUNCTION public._exos_tg_integration_vault_drop();

-- A managed provider's credential as its OLD table holds it (the fallback
-- and the copy's source). No row: nothing connected there.
CREATE OR REPLACE FUNCTION public._exos_cred_legacy(p_org_id uuid, p_provider text)
RETURNS TABLE (secret text, config jsonb, status text, account_name text, writes_enabled boolean, actor uuid, source text)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF p_provider = 'eventbrite' THEN
    RETURN QUERY
      SELECT public._exos_vault_get(a.secret_id), jsonb_strip_nulls(jsonb_build_object('auth_method', a.auth_method)),
             'connected'::text, a.account_name, coalesce(a.writes_enabled, false), a.connected_by, 'exos_eventbrite_accounts'::text
        FROM public.exos_eventbrite_accounts a WHERE a.org_id = p_org_id;
  ELSIF p_provider = 'dice' THEN
    RETURN QUERY
      SELECT public._exos_vault_get(c.secret_id), jsonb_strip_nulls(jsonb_build_object('account_id', c.account_id)),
             c.status, c.account_name, false, c.connected_by, 'exos_dice_connections'::text
        FROM public.exos_dice_connections c
       WHERE c.org_id = p_org_id AND c.status <> 'disconnected' AND c.secret_id IS NOT NULL;
  ELSIF p_provider = 'discord' THEN
    RETURN QUERY
      SELECT public._exos_vault_get(l.webhook_secret_id), jsonb_build_object('webhook_id', l.webhook_id),
             CASE WHEN l.webhook_broken_at IS NOT NULL THEN 'error' ELSE 'connected' END, l.guild_name,
             coalesce(l.writes_enabled, false), l.webhook_set_by, 'exos_discord_links'::text
        FROM public.exos_discord_links l
       WHERE l.org_id = p_org_id AND l.webhook_secret_id IS NOT NULL;
  ELSIF p_provider LIKE 'ads\_%' THEN
    RETURN QUERY
      SELECT public._exos_vault_get(c.secret_id),
             c.config || jsonb_strip_nulls(jsonb_build_object('test_event_code', c.test_event_code)),
             CASE WHEN c.enabled THEN 'connected' ELSE 'unverified' END, NULL::text,
             c.enabled, c.updated_by, 'exos_org_ad_credentials'::text
        FROM public.exos_org_ad_credentials c
       WHERE c.org_id = p_org_id AND c.platform = substr(p_provider, 5) AND c.secret_id IS NOT NULL;
  ELSIF p_provider = 'lysted' THEN
    -- Only a value written before this migration (or around its trigger):
    -- the trigger below leaves a stub once the value is in Vault.
    RETURN QUERY
      SELECT s.distribution::text, jsonb_strip_nulls(jsonb_build_object('enabled', s.distribution -> 'enabled')),
             'unverified'::text, NULL::text, false, NULL::uuid, 'exos_org_secrets.distribution'::text
        FROM public.exos_org_secrets s
       WHERE s.org_id = p_org_id AND s.distribution IS NOT NULL AND jsonb_typeof(s.distribution) = 'object'
         AND NOT s.distribution ? 'in_vault';
  END IF;
END $$;
REVOKE ALL ON FUNCTION public._exos_cred_legacy(uuid, text) FROM PUBLIC, anon, authenticated, service_role;

-- Bring the store's copy of a managed provider in line with its old table.
-- Never raises: a failure drops the copy (reads fall back) with a WARNING.
CREATE OR REPLACE FUNCTION public._exos_cred_copy(p_org_id uuid, p_provider text)
RETURNS text
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE l record;
BEGIN
  IF p_org_id IS NULL OR NOT public._exos_cred_managed(p_provider) OR p_provider = 'lysted' THEN
    RETURN 'skipped';
  END IF;
  BEGIN
    SELECT * INTO l FROM public._exos_cred_legacy(p_org_id, p_provider) LIMIT 1;
    IF NOT FOUND OR l.secret IS NULL THEN
      PERFORM public._exos_integration_drop(p_org_id, p_provider);
      RETURN 'dropped';
    END IF;
    PERFORM public._exos_integration_put(p_org_id, p_provider, l.secret, l.config, NULL, l.status, l.actor,
                                         l.account_name, l.writes_enabled, l.source);
    RETURN 'copied';
  EXCEPTION WHEN others THEN
    RAISE WARNING 'exos credential copy (%): % (%); the copy is dropped, reads use the old table', p_provider, SQLERRM, SQLSTATE;
    BEGIN
      DELETE FROM public.exos_org_integrations WHERE org_id = p_org_id AND provider = p_provider;
    EXCEPTION WHEN others THEN
      NULL;
    END;
    RETURN 'failed';
  END;
END $$;
REVOKE ALL ON FUNCTION public._exos_cred_copy(uuid, text) FROM PUBLIC, anon, authenticated, service_role;

-- AFTER trigger on the old tables. TG_ARGV[0]: the provider, or 'ads'
-- (the row's platform names it).
CREATE OR REPLACE FUNCTION public._exos_tg_cred_mirror()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE r jsonb;
BEGIN
  r := CASE WHEN TG_OP = 'DELETE' THEN to_jsonb(OLD) ELSE to_jsonb(NEW) END;
  PERFORM public._exos_cred_copy((r ->> 'org_id')::uuid,
    CASE WHEN TG_ARGV[0] = 'ads' THEN 'ads_' || (r ->> 'platform') ELSE TG_ARGV[0] END);
  RETURN NULL;
END $$;
REVOKE ALL ON FUNCTION public._exos_tg_cred_mirror() FROM PUBLIC, anon, authenticated, service_role;

DROP TRIGGER IF EXISTS exos_eventbrite_accounts_cred_mirror ON public.exos_eventbrite_accounts;
CREATE TRIGGER exos_eventbrite_accounts_cred_mirror AFTER INSERT OR UPDATE OR DELETE ON public.exos_eventbrite_accounts
  FOR EACH ROW EXECUTE FUNCTION public._exos_tg_cred_mirror('eventbrite');

DROP TRIGGER IF EXISTS exos_org_ad_credentials_cred_mirror ON public.exos_org_ad_credentials;
CREATE TRIGGER exos_org_ad_credentials_cred_mirror AFTER INSERT OR UPDATE OR DELETE ON public.exos_org_ad_credentials
  FOR EACH ROW EXECUTE FUNCTION public._exos_tg_cred_mirror('ads');

-- DICE and Discord rows change on every sync (cursors, leases, pauses): copy
-- only when the credential side of the row changes.
DROP TRIGGER IF EXISTS exos_dice_connections_cred_mirror ON public.exos_dice_connections;
CREATE TRIGGER exos_dice_connections_cred_mirror AFTER INSERT OR DELETE ON public.exos_dice_connections
  FOR EACH ROW EXECUTE FUNCTION public._exos_tg_cred_mirror('dice');
DROP TRIGGER IF EXISTS exos_dice_connections_cred_mirror_upd ON public.exos_dice_connections;
CREATE TRIGGER exos_dice_connections_cred_mirror_upd AFTER UPDATE ON public.exos_dice_connections
  FOR EACH ROW WHEN (OLD.secret_id IS DISTINCT FROM NEW.secret_id OR OLD.status IS DISTINCT FROM NEW.status
                     OR OLD.connected_at IS DISTINCT FROM NEW.connected_at OR OLD.connected_by IS DISTINCT FROM NEW.connected_by
                     OR OLD.account_id IS DISTINCT FROM NEW.account_id)
  EXECUTE FUNCTION public._exos_tg_cred_mirror('dice');

DROP TRIGGER IF EXISTS exos_discord_links_cred_mirror ON public.exos_discord_links;
CREATE TRIGGER exos_discord_links_cred_mirror AFTER INSERT OR DELETE ON public.exos_discord_links
  FOR EACH ROW EXECUTE FUNCTION public._exos_tg_cred_mirror('discord');
DROP TRIGGER IF EXISTS exos_discord_links_cred_mirror_upd ON public.exos_discord_links;
CREATE TRIGGER exos_discord_links_cred_mirror_upd AFTER UPDATE ON public.exos_discord_links
  FOR EACH ROW WHEN (OLD.webhook_secret_id IS DISTINCT FROM NEW.webhook_secret_id OR OLD.webhook_id IS DISTINCT FROM NEW.webhook_id
                     OR OLD.webhook_set_at IS DISTINCT FROM NEW.webhook_set_at OR OLD.webhook_set_by IS DISTINCT FROM NEW.webhook_set_by
                     OR OLD.webhook_broken_at IS DISTINCT FROM NEW.webhook_broken_at
                     OR OLD.writes_enabled IS DISTINCT FROM NEW.writes_enabled OR OLD.guild_name IS DISTINCT FROM NEW.guild_name)
  EXECUTE FUNCTION public._exos_tg_cred_mirror('discord');

-- exos_org_secrets.distribution (Lysted / Automatiq seller credentials,
-- plain jsonb an owner or finance member can read back): on every write the
-- value goes to Vault (provider 'lysted') and the column keeps a stub
-- {in_vault: true, enabled}. A stub written back (the dashboard saving the
-- org) keeps the stored secret; NULL removes it.
CREATE OR REPLACE FUNCTION public._exos_tg_org_secrets_distribution()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE v_stub jsonb;
BEGIN
  IF NEW.distribution IS NULL OR jsonb_typeof(NEW.distribution) = 'null' THEN
    IF TG_OP = 'UPDATE' AND OLD.distribution IS NOT NULL THEN
      PERFORM public._exos_integration_drop(NEW.org_id, 'lysted');
    END IF;
    RETURN NEW;
  END IF;
  v_stub := jsonb_strip_nulls(jsonb_build_object('in_vault', true,
              'enabled', CASE WHEN jsonb_typeof(NEW.distribution) = 'object' THEN NEW.distribution -> 'enabled' END));
  IF jsonb_typeof(NEW.distribution) = 'object' AND NEW.distribution ? 'in_vault' THEN
    NEW.distribution := v_stub;
    RETURN NEW;
  END IF;
  PERFORM public._exos_integration_put(NEW.org_id, 'lysted', NEW.distribution::text,
    jsonb_strip_nulls(jsonb_build_object('enabled', v_stub -> 'enabled')), NULL, 'unverified', auth.uid(), NULL, false,
    'exos_org_secrets.distribution');
  NEW.distribution := v_stub;
  RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION public._exos_tg_org_secrets_distribution() FROM PUBLIC, anon, authenticated, service_role;
DROP TRIGGER IF EXISTS exos_org_secrets_distribution_vault ON public.exos_org_secrets;
CREATE TRIGGER exos_org_secrets_distribution_vault BEFORE INSERT OR UPDATE OF distribution ON public.exos_org_secrets
  FOR EACH ROW EXECUTE FUNCTION public._exos_tg_org_secrets_distribution();

-- The row itself deleted (by hand, or an org delete): the Lysted value goes
-- too, store row and Vault secret.
CREATE OR REPLACE FUNCTION public._exos_tg_org_secrets_distribution_drop()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  PERFORM public._exos_integration_drop(OLD.org_id, 'lysted');
  RETURN NULL;
END $$;
REVOKE ALL ON FUNCTION public._exos_tg_org_secrets_distribution_drop() FROM PUBLIC, anon, authenticated, service_role;
DROP TRIGGER IF EXISTS exos_org_secrets_distribution_drop ON public.exos_org_secrets;
CREATE TRIGGER exos_org_secrets_distribution_drop AFTER DELETE ON public.exos_org_secrets
  FOR EACH ROW EXECUTE FUNCTION public._exos_tg_org_secrets_distribution_drop();

-- The data copy: every connected credential in the old stores, into the
-- store (Vault copies), and the plain distribution values into Vault. Re-run
-- safe (copies update in place). Returns counts by provider.
CREATE OR REPLACE FUNCTION public._exos_cred_backfill()
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  r record;
  v_out jsonb := '{}'::jsonb;
  v_res text;
BEGIN
  FOR r IN
    SELECT a.org_id, 'eventbrite'::text AS provider FROM public.exos_eventbrite_accounts a
    UNION ALL
    SELECT c.org_id, 'dice' FROM public.exos_dice_connections c WHERE c.status <> 'disconnected' AND c.secret_id IS NOT NULL
    UNION ALL
    SELECT l.org_id, 'discord' FROM public.exos_discord_links l WHERE l.webhook_secret_id IS NOT NULL
    UNION ALL
    SELECT c.org_id, 'ads_' || c.platform FROM public.exos_org_ad_credentials c WHERE c.secret_id IS NOT NULL
  LOOP
    v_res := public._exos_cred_copy(r.org_id, r.provider);
    v_out := jsonb_set(v_out, ARRAY[r.provider || ':' || v_res],
                       to_jsonb(coalesce((v_out ->> (r.provider || ':' || v_res))::int, 0) + 1));
  END LOOP;
  -- distribution: re-writing the value runs the trigger above.
  WITH moved AS (
    UPDATE public.exos_org_secrets s SET distribution = s.distribution
     WHERE s.distribution IS NOT NULL AND jsonb_typeof(s.distribution) <> 'null'
       AND NOT (jsonb_typeof(s.distribution) = 'object' AND s.distribution ? 'in_vault')
    RETURNING 1)
  SELECT v_out || jsonb_build_object('lysted:moved', count(*)) INTO v_out FROM moved;
  RETURN v_out;
END $$;
REVOKE ALL ON FUNCTION public._exos_cred_backfill() FROM PUBLIC, anon, authenticated, service_role;

SELECT public._exos_cred_backfill();

-- ===========================================================================
-- 3. The one decrypt: exos_integration_secret (service role)
-- ===========================================================================
-- {provider, status, config, secret, writes_enabled, account_name, source}
-- or NULL (nothing connected, a disabled row, an unknown provider). source:
-- 'store', or 'legacy:<table>' when a managed provider's copy is missing.
CREATE OR REPLACE FUNCTION public.exos_integration_secret(p_org_id uuid, p_provider text)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  i public.exos_org_integrations%ROWTYPE;
  l record;
BEGIN
  IF p_org_id IS NULL OR p_provider IS NULL OR NOT (p_provider = ANY (public._exos_cred_providers())) THEN
    RETURN NULL;
  END IF;
  SELECT * INTO i FROM public.exos_org_integrations x WHERE x.org_id = p_org_id AND x.provider = p_provider;
  IF FOUND THEN
    IF i.status = 'disabled' THEN
      RETURN NULL;
    END IF;
    IF i.secret_id IS NOT NULL OR NOT public._exos_cred_managed(p_provider) THEN
      RETURN jsonb_build_object('provider', i.provider, 'status', i.status, 'config', i.config,
                                'secret', public._exos_vault_get(i.secret_id), 'writes_enabled', i.writes_enabled,
                                'account_name', i.account_name, 'source', 'store');
    END IF;
  END IF;
  IF NOT public._exos_cred_managed(p_provider) THEN
    RETURN NULL;
  END IF;
  SELECT * INTO l FROM public._exos_cred_legacy(p_org_id, p_provider) LIMIT 1;
  IF NOT FOUND OR l.secret IS NULL THEN
    RETURN NULL;
  END IF;
  RETURN jsonb_build_object('provider', p_provider, 'status', l.status, 'config', l.config, 'secret', l.secret,
                            'writes_enabled', l.writes_enabled, 'account_name', l.account_name, 'source', 'legacy:' || l.source);
END $$;
REVOKE ALL ON FUNCTION public.exos_integration_secret(uuid, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_integration_secret(uuid, text) TO service_role;

-- ===========================================================================
-- 4. The browser's save / remove / list on the store (counted patches)
-- ===========================================================================
SELECT pg_temp.exos_patch_n('public.exos_save_integration(uuid, text, jsonb, text, text)',
  '/* exos: credential store */',
  $old$  SELECT secret_id INTO v_secret FROM public.exos_org_integrations WHERE org_id = p_org_id AND provider = p_provider FOR UPDATE;
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
$old$,
  $new$  /* exos: credential store */
  v_secret := public._exos_integration_put(p_org_id, p_provider, v_new, v_cfg, p_label, 'unverified', v_uid);
  PERFORM public._exos_audit(p_org_id, 'integration.save', 'integration', p_provider, NULL,
    jsonb_build_object('provider', p_provider, 'new_credential', v_new IS NOT NULL,
                       'settings', (SELECT string_agg(k, ',' ORDER BY k) FROM jsonb_object_keys(v_cfg) k)),
    NULL, NULL, NULL, v_uid);
$new$, 1);

SELECT pg_temp.exos_patch_n('public.exos_remove_integration(uuid, text)',
  '/* exos: credential store remove */',
  $old$  DELETE FROM public.exos_org_integrations WHERE org_id = p_org_id AND provider = p_provider RETURNING secret_id INTO v_secret;
  IF NOT FOUND THEN RETURN false; END IF;
$old$,
  $new$  /* exos: credential store remove */
  IF public._exos_cred_managed(p_provider) THEN
    RAISE EXCEPTION 'exos_remove_integration: disconnect it where it was connected' USING ERRCODE = '22023';
  END IF;
  DELETE FROM public.exos_org_integrations WHERE org_id = p_org_id AND provider = p_provider RETURNING secret_id INTO v_secret;
  IF NOT FOUND THEN RETURN false; END IF;
  PERFORM public._exos_audit(p_org_id, 'integration.remove', 'integration', p_provider, NULL,
    jsonb_build_object('provider', p_provider), NULL, NULL, NULL, auth.uid());
$new$, 1);

SELECT pg_temp.exos_patch_n('public.exos_list_integrations(uuid)',
  '/* exos: credential store list */',
  $old$     WHERE i.org_id = p_org_id
     ORDER BY i.provider;$old$,
  $new$     WHERE i.org_id = p_org_id /* exos: credential store list */ AND i.provider = ANY (public.exos_integration_providers())
     ORDER BY i.provider;$new$, 1);

-- ===========================================================================
-- 5. Channel audit
-- ===========================================================================
CREATE TABLE IF NOT EXISTS public.exos_channel_audit (
  id        uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id    uuid NOT NULL REFERENCES public.exos_orgs (id) ON DELETE CASCADE,
  event_id  uuid,                                   -- no FK: the record outlives the event
  channel   text NOT NULL CHECK (channel ~ '^[a-z0-9_]{2,40}$'),
  op        text NOT NULL CHECK (op ~ '^[A-Za-z0-9_.:-]{1,60}$'),
  method    text NOT NULL CHECK (method IN ('GET', 'HEAD', 'POST', 'PUT', 'PATCH', 'DELETE')),
  path      text NOT NULL CHECK (char_length(path) BETWEEN 1 AND 500),
  live      boolean NOT NULL,
  request   jsonb CHECK (request IS NULL OR pg_column_size(request) <= 24000),
  response  jsonb CHECK (response IS NULL OR pg_column_size(response) <= 4000),
  status    integer CHECK (status IS NULL OR status BETWEEN 0 AND 999),
  ok        boolean,
  error     text CHECK (error IS NULL OR char_length(error) <= 200),
  warnings  jsonb CHECK (warnings IS NULL OR (jsonb_typeof(warnings) = 'array' AND pg_column_size(warnings) <= 4000)),
  at        timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS exos_channel_audit_org_idx ON public.exos_channel_audit (org_id, at DESC);
CREATE INDEX IF NOT EXISTS exos_channel_audit_at_idx ON public.exos_channel_audit (at);
ALTER TABLE public.exos_channel_audit ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.exos_channel_audit FROM PUBLIC, anon, authenticated, service_role;
GRANT SELECT ON TABLE public.exos_channel_audit TO authenticated, service_role;
DROP POLICY IF EXISTS exos_channel_audit_sel ON public.exos_channel_audit;
CREATE POLICY exos_channel_audit_sel ON public.exos_channel_audit FOR SELECT TO authenticated
  USING (public.exos_has_org_role(org_id, ARRAY['owner', 'manager']));
COMMENT ON TABLE public.exos_channel_audit IS
  'Every request the channel core planned (dry run) or sent to a channel: method, path (no query values), the redacted payload, a response summary. Owner / manager read their org''s rows; written only by exos_channel_audit_record; 30 days. mig 20261121162400.';

-- Credentials out of free text: auth schemes with their value, JWTs, known
-- token prefixes (Stripe, Slack, GitHub, Google, Meta) and secret-named
-- query parameters, wherever they sit in the string. Best effort: the edge
-- function redacts first (gatedHttp.ts); this is the second pass.
CREATE OR REPLACE FUNCTION public._exos_channel_audit_scrub_text(p text)
RETURNS text LANGUAGE sql IMMUTABLE
SET search_path = public, pg_temp
AS $$
  SELECT CASE WHEN p IS NULL THEN NULL ELSE
    regexp_replace(regexp_replace(regexp_replace(regexp_replace(p,
      '\m(bearer|basic)\s+[^\s",;]{6,}|\m(token|apikey)\s+[A-Za-z0-9._~+/=-]{16,}', '[redacted]', 'gi'),
      'eyJ[A-Za-z0-9_-]{6,}\.[A-Za-z0-9_-]{6,}(\.[A-Za-z0-9_-]*)?', '[redacted]', 'g'),
      '\m((sk|rk|pk)_(live|test)_|whsec_|xox[abprs]-|gh[pousr]_|github_pat_|ya29\.|EAA[A-Za-z0-9]{8}|AKIA)[A-Za-z0-9_.-]{6,}', '[redacted]', 'g'),
      '([?&;]|\m)([A-Za-z0-9_.-]*(token|secret|passw|pwd|signature|credential|jwt|api[_-]?key|apikey|access[_-]?key|private[_-]?key|auth)[A-Za-z0-9_.-]*|key|sig)=[^&\s"#]*',
      '\1\2=[redacted]', 'gi')
  END
$$;
REVOKE ALL ON FUNCTION public._exos_channel_audit_scrub_text(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public._exos_channel_audit_scrub_text(text) TO authenticated, service_role;

-- A path as the audit keeps it: no fragment, no query values (names only;
-- a bare parameter, which could itself be a secret, as …), and credentials
-- in a path segment scrubbed as text.
CREATE OR REPLACE FUNCTION public._exos_channel_audit_path(p text)
RETURNS text LANGUAGE sql IMMUTABLE
SET search_path = public, pg_temp
AS $$
  SELECT left(regexp_replace(regexp_replace(
           public._exos_channel_audit_scrub_text(regexp_replace(coalesce(p, ''), '#.*$', '')),
           '([?&][^=&#]*)=[^&#]*', '\1=…', 'g'),
           '([?&])[^=&#]+(?=&|$)', '\1…', 'g'), 500)
$$;
REVOKE ALL ON FUNCTION public._exos_channel_audit_path(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public._exos_channel_audit_path(text) TO authenticated, service_role;

-- Secret-named keys and auth-looking strings out, at any depth (the edge
-- function redacts first; this is the second pass). The key pattern is
-- gatedHttp.ts SECRET_KEY.
CREATE OR REPLACE FUNCTION public._exos_channel_audit_scrub(p jsonb, p_depth integer DEFAULT 0)
RETURNS jsonb LANGUAGE plpgsql IMMUTABLE
SET search_path = public, pg_temp
AS $$
BEGIN
  IF p IS NULL THEN
    RETURN NULL;
  END IF;
  IF p_depth > 8 THEN
    RETURN to_jsonb('[too deep]'::text);
  END IF;
  CASE jsonb_typeof(p)
    WHEN 'object' THEN
      RETURN coalesce((SELECT jsonb_object_agg(e.k, CASE
                 WHEN e.k ~* '(authorization|cookie|token|secret|password|passwd|passphrase|^pass$|^pwd$|^key$|api[_-]?key|private[_-]?key|access[_-]?key|secret[_-]?key|signing[_-]?key|auth[_-]?key|client[_-]?secret|signature|credential|jwt)'
                   THEN to_jsonb('[redacted]'::text)
                 ELSE public._exos_channel_audit_scrub(e.v, p_depth + 1) END)
               FROM jsonb_each(p) e(k, v)), '{}'::jsonb);
    WHEN 'array' THEN
      RETURN coalesce((SELECT jsonb_agg(public._exos_channel_audit_scrub(a.v, p_depth + 1) ORDER BY a.o)
               FROM jsonb_array_elements(p) WITH ORDINALITY a(v, o)), '[]'::jsonb);
    WHEN 'string' THEN
      RETURN to_jsonb(public._exos_channel_audit_scrub_text(p #>> '{}'));
    ELSE
      RETURN p;
  END CASE;
END $$;
REVOKE ALL ON FUNCTION public._exos_channel_audit_scrub(jsonb, integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public._exos_channel_audit_scrub(jsonb, integer) TO authenticated, service_role;

-- Service role: up to 50 steps [{channel, op, method, path, live, request,
-- response, status, ok, error, warnings, event_id}]; a malformed step is
-- skipped, never raised (an audit write never fails the pass). Returns the
-- rows written.
CREATE OR REPLACE FUNCTION public.exos_channel_audit_record(p_org_id uuid, p_steps jsonb)
RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  s jsonb;
  v_n integer := 0;
  v_req jsonb;
  v_path text;
BEGIN
  IF p_org_id IS NULL OR jsonb_typeof(p_steps) <> 'array' OR NOT EXISTS (SELECT 1 FROM public.exos_orgs o WHERE o.id = p_org_id) THEN
    RETURN 0;
  END IF;
  FOR s IN SELECT v FROM jsonb_array_elements(p_steps) WITH ORDINALITY a(v, o) WHERE a.o <= 50 ORDER BY a.o LOOP
    BEGIN
      v_path := public._exos_channel_audit_path(s ->> 'path');
      v_req := public._exos_channel_audit_scrub(CASE WHEN jsonb_typeof(s -> 'request') IN ('object', 'array') THEN s -> 'request' END);
      IF v_req IS NOT NULL AND pg_column_size(v_req) > 24000 THEN
        v_req := jsonb_build_object('truncated', true, 'bytes', pg_column_size(v_req));
      END IF;
      INSERT INTO public.exos_channel_audit (org_id, event_id, channel, op, method, path, live, request, response,
                                             status, ok, error, warnings)
      VALUES (p_org_id,
              CASE WHEN (s ->> 'event_id') ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' THEN (s ->> 'event_id')::uuid END,
              s ->> 'channel', left(coalesce(s ->> 'op', 'request'), 60), upper(s ->> 'method'), left(v_path, 500),
              coalesce((s ->> 'live')::boolean, false), v_req,
              CASE WHEN jsonb_typeof(s -> 'response') = 'object' AND pg_column_size(s -> 'response') <= 4000
                   THEN public._exos_channel_audit_scrub(s -> 'response') END,
              CASE WHEN (s ->> 'status') ~ '^[0-9]{1,3}$' THEN (s ->> 'status')::int END,
              CASE WHEN jsonb_typeof(s -> 'ok') = 'boolean' THEN (s ->> 'ok')::boolean END,
              left(public._exos_channel_audit_scrub_text(s ->> 'error'), 200),
              CASE WHEN jsonb_typeof(s -> 'warnings') = 'array' AND pg_column_size(s -> 'warnings') <= 4000
                   THEN public._exos_channel_audit_scrub(s -> 'warnings') END);
      v_n := v_n + 1;
    EXCEPTION WHEN others THEN
      RAISE WARNING 'exos_channel_audit_record: step skipped (%)', SQLSTATE;
    END;
  END LOOP;
  -- 30 days, for every org (not only this one): a bounded batch per write;
  -- exos_channel_retention_sweep does the rest from a daily cron.
  DELETE FROM public.exos_channel_audit
   WHERE id IN (SELECT a.id FROM public.exos_channel_audit a WHERE a.at < now() - interval '30 days' ORDER BY a.at LIMIT 500);
  RETURN v_n;
END $$;
REVOKE ALL ON FUNCTION public.exos_channel_audit_record(uuid, jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_channel_audit_record(uuid, jsonb) TO service_role;

-- ===========================================================================
-- 6. Platform usage counters (limits.ts reads and spends them)
-- ===========================================================================
CREATE TABLE IF NOT EXISTS public.exos_channel_usage (
  id        uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id    uuid NOT NULL REFERENCES public.exos_orgs (id) ON DELETE CASCADE,
  platform  text NOT NULL CHECK (platform ~ '^[a-z0-9_]{2,40}$'),
  scope_key text NOT NULL DEFAULT '' CHECK (char_length(scope_key) <= 200),
  metric    text NOT NULL CHECK (metric ~ '^[a-z0-9_]{2,40}$'),
  n         integer NOT NULL CHECK (n BETWEEN 1 AND 100000),
  live      boolean NOT NULL,
  -- Planned rows: one per identical request (method + path + body hash), so
  -- a dry run repeated every pass counts once (its time is refreshed).
  dedupe    text CHECK (dedupe IS NULL OR dedupe ~ '^[0-9a-f]{16,128}$'),
  at        timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX IF NOT EXISTS exos_channel_usage_planned_uq
  ON public.exos_channel_usage (org_id, platform, scope_key, metric, dedupe) WHERE NOT live AND dedupe IS NOT NULL;
CREATE INDEX IF NOT EXISTS exos_channel_usage_key_idx ON public.exos_channel_usage (org_id, platform, metric, scope_key, at DESC);
ALTER TABLE public.exos_channel_usage ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.exos_channel_usage FROM PUBLIC, anon, authenticated, service_role;
GRANT SELECT ON TABLE public.exos_channel_usage TO service_role;
COMMENT ON TABLE public.exos_channel_usage IS
  'Platform usage the channel limits count (limits.ts), per org / platform / scope / metric; live and planned (dry run) apart; rolling windows are sums over at. Written by exos_channel_usage_reserve only; owners / managers read exos_channel_usage_summary. mig 20261121162400.';

CREATE OR REPLACE FUNCTION public._exos_channel_usage_sum(
  p_org_id uuid, p_platform text, p_scope_key text, p_metric text, p_window_seconds integer, p_live boolean)
RETURNS integer LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT coalesce(sum(u.n), 0)::int FROM public.exos_channel_usage u
   WHERE u.org_id = p_org_id AND u.platform = p_platform AND u.scope_key = coalesce(p_scope_key, '')
     AND u.metric = p_metric AND u.live = p_live
     AND (coalesce(p_window_seconds, 0) <= 0 OR u.at > now() - make_interval(secs => p_window_seconds))
$$;
REVOKE ALL ON FUNCTION public._exos_channel_usage_sum(uuid, text, text, text, integer, boolean) FROM PUBLIC, anon, authenticated, service_role;

-- Service role. Live: spends p_n only if it fits under p_threshold (NULL: no
-- limit) in the rolling window; ok false and nothing written otherwise.
-- Planned: always recorded (once per dedupe), ok says whether it would fit
-- next to the live usage. {ok, id, live_used, planned_used, remaining}.
CREATE OR REPLACE FUNCTION public.exos_channel_usage_reserve(
  p_org_id uuid, p_platform text, p_scope_key text, p_metric text, p_n integer,
  p_window_seconds integer, p_threshold integer, p_live boolean, p_dedupe text DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_scope text := coalesce(p_scope_key, '');
  v_live  int;
  v_plan  int;
  v_id    uuid;
  v_fits  boolean;
BEGIN
  IF p_org_id IS NULL OR p_platform !~ '^[a-z0-9_]{2,40}$' OR p_metric !~ '^[a-z0-9_]{2,40}$'
     OR char_length(v_scope) > 200 OR p_n IS NULL OR p_n NOT BETWEEN 1 AND 100000 OR p_live IS NULL
     OR (p_dedupe IS NOT NULL AND p_dedupe !~ '^[0-9a-f]{16,128}$') THEN
    RAISE EXCEPTION 'exos_channel_usage_reserve: bad arguments' USING ERRCODE = '22023';
  END IF;
  -- The sum below must see what committed while this waited for the lock:
  -- only READ COMMITTED gives that (a REPEATABLE READ snapshot would overshoot).
  IF current_setting('transaction_isolation') <> 'read committed' THEN
    RAISE EXCEPTION 'exos_channel_usage_reserve: needs READ COMMITTED' USING ERRCODE = '0A000';
  END IF;
  PERFORM pg_advisory_xact_lock(hashtextextended('exos_channel_usage:' || p_org_id::text || ':' || p_platform || ':'
                                                 || p_metric || ':' || v_scope, 0));
  v_live := public._exos_channel_usage_sum(p_org_id, p_platform, v_scope, p_metric, p_window_seconds, true);
  v_fits := p_threshold IS NULL OR v_live + p_n <= p_threshold;
  IF p_live THEN
    IF NOT v_fits THEN
      RETURN jsonb_build_object('ok', false, 'live_used', v_live,
        'planned_used', public._exos_channel_usage_sum(p_org_id, p_platform, v_scope, p_metric, p_window_seconds, false),
        'remaining', greatest(p_threshold - v_live, 0));
    END IF;
    INSERT INTO public.exos_channel_usage (org_id, platform, scope_key, metric, n, live)
    VALUES (p_org_id, p_platform, v_scope, p_metric, p_n, true) RETURNING id INTO v_id;
    v_live := v_live + p_n;
  ELSIF p_dedupe IS NOT NULL THEN
    INSERT INTO public.exos_channel_usage AS u (org_id, platform, scope_key, metric, n, live, dedupe)
    VALUES (p_org_id, p_platform, v_scope, p_metric, p_n, false, p_dedupe)
    ON CONFLICT (org_id, platform, scope_key, metric, dedupe) WHERE NOT live AND dedupe IS NOT NULL
    DO UPDATE SET n = EXCLUDED.n, at = now()
    RETURNING id INTO v_id;
  ELSE
    INSERT INTO public.exos_channel_usage (org_id, platform, scope_key, metric, n, live)
    VALUES (p_org_id, p_platform, v_scope, p_metric, p_n, false) RETURNING id INTO v_id;
  END IF;
  v_plan := public._exos_channel_usage_sum(p_org_id, p_platform, v_scope, p_metric, p_window_seconds, false);
  DELETE FROM public.exos_channel_usage
   WHERE org_id = p_org_id AND platform = p_platform AND metric = p_metric AND at < now() - interval '400 days';
  RETURN jsonb_build_object('ok', v_fits, 'id', v_id, 'live_used', v_live, 'planned_used', v_plan,
                            'remaining', CASE WHEN p_threshold IS NULL THEN NULL ELSE greatest(p_threshold - v_live, 0) END);
END $$;
REVOKE ALL ON FUNCTION public.exos_channel_usage_reserve(uuid, text, text, text, integer, integer, integer, boolean, text)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_channel_usage_reserve(uuid, text, text, text, integer, integer, integer, boolean, text)
  TO service_role;

-- Service role: {live, planned} in the rolling window (0 / NULL: all time).
CREATE OR REPLACE FUNCTION public.exos_channel_usage_read(
  p_org_id uuid, p_platform text, p_scope_key text, p_metric text, p_window_seconds integer)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT jsonb_build_object(
    'live', public._exos_channel_usage_sum(p_org_id, p_platform, p_scope_key, p_metric, p_window_seconds, true),
    'planned', public._exos_channel_usage_sum(p_org_id, p_platform, p_scope_key, p_metric, p_window_seconds, false))
$$;
REVOKE ALL ON FUNCTION public.exos_channel_usage_read(uuid, text, text, text, integer) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_channel_usage_read(uuid, text, text, text, integer) TO service_role;

-- Service role: give back a live reservation the platform refused outright
-- (a 4xx: nothing was used). Only live rows; true when one was removed.
CREATE OR REPLACE FUNCTION public.exos_channel_usage_release(p_org_id uuid, p_id uuid)
RETURNS boolean LANGUAGE sql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  WITH d AS (DELETE FROM public.exos_channel_usage WHERE id = p_id AND org_id = p_org_id AND live RETURNING 1)
  SELECT EXISTS (SELECT 1 FROM d)
$$;
REVOKE ALL ON FUNCTION public.exos_channel_usage_release(uuid, uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_channel_usage_release(uuid, uuid) TO service_role;

-- Owner / manager: the org's usage per platform / metric / scope over the
-- last day, 7 days and 365 days, live and planned apart (the preview's
-- "would use N of M"; M comes from limits.ts). 42501 for anyone else.
CREATE OR REPLACE FUNCTION public.exos_channel_usage_summary(p_org_id uuid)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF p_org_id IS NULL OR NOT public.exos_has_org_role(p_org_id, ARRAY['owner', 'manager']) THEN
    RAISE EXCEPTION 'exos_channel_usage_summary: owner or manager only' USING ERRCODE = '42501';
  END IF;
  RETURN coalesce((
    SELECT jsonb_agg(jsonb_build_object(
             'platform', g.platform, 'metric', g.metric, 'scope_key', g.scope_key,
             'live_day', g.live_day, 'planned_day', g.planned_day, 'live_week', g.live_week, 'planned_week', g.planned_week,
             'live_year', g.live_year, 'planned_year', g.planned_year) ORDER BY g.platform, g.metric, g.scope_key)
      FROM (SELECT u.platform, u.metric, u.scope_key,
                   coalesce(sum(u.n) FILTER (WHERE u.live AND u.at > now() - interval '1 day'), 0)::int AS live_day,
                   coalesce(sum(u.n) FILTER (WHERE NOT u.live AND u.at > now() - interval '1 day'), 0)::int AS planned_day,
                   coalesce(sum(u.n) FILTER (WHERE u.live AND u.at > now() - interval '7 days'), 0)::int AS live_week,
                   coalesce(sum(u.n) FILTER (WHERE NOT u.live AND u.at > now() - interval '7 days'), 0)::int AS planned_week,
                   coalesce(sum(u.n) FILTER (WHERE u.live), 0)::int AS live_year,
                   coalesce(sum(u.n) FILTER (WHERE NOT u.live), 0)::int AS planned_year
              FROM public.exos_channel_usage u
             WHERE u.org_id = p_org_id AND u.at > now() - interval '365 days'
             GROUP BY u.platform, u.metric, u.scope_key) g), '[]'::jsonb);
END $$;
REVOKE ALL ON FUNCTION public.exos_channel_usage_summary(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.exos_channel_usage_summary(uuid) TO authenticated, service_role;

-- Retention for the whole table, whether or not an org writes again: audit
-- rows 30 days, usage rows 400 days. Service role; meant for a daily cron
-- (none is scheduled here: crons are operator-gated, scripts/rollout-prod.sh).
-- Returns {audit, usage} rows removed.
CREATE OR REPLACE FUNCTION public.exos_channel_retention_sweep()
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE v_a int; v_u int;
BEGIN
  DELETE FROM public.exos_channel_audit WHERE at < now() - interval '30 days';
  GET DIAGNOSTICS v_a = ROW_COUNT;
  DELETE FROM public.exos_channel_usage WHERE at < now() - interval '400 days';
  GET DIAGNOSTICS v_u = ROW_COUNT;
  RETURN jsonb_build_object('audit', v_a, 'usage', v_u);
END $$;
REVOKE ALL ON FUNCTION public.exos_channel_retention_sweep() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_channel_retention_sweep() TO service_role;

-- ROLLBACK (manual): drop the triggers *_cred_mirror*, exos_org_secrets_distribution_vault,
-- exos_org_secrets_distribution_drop, exos_org_integrations_vault_drop;
-- drop the functions above (re-create exos_save_integration / exos_remove_integration /
-- exos_list_integrations from 20261016090000); DELETE FROM exos_org_integrations WHERE
-- copied_from IS NOT NULL (and their Vault secrets exos_integration:<org>:<managed provider>);
-- restore the provider CHECK on exos_integration_providers(); drop exos_channel_audit and
-- exos_channel_usage. Distribution values moved to Vault are in provider 'lysted' rows.
