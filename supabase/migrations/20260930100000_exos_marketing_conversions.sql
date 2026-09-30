-- ============================================================================
-- Migration 20260930100000 — Exos (Bridge / D4): server-side ad conversions —
--                            per-org ad credentials (secrets in Vault) and a
--                            conversions outbox drained by exos-conversions-drain
--
-- Lane:     d4 (exos / bridge ticketing infra)
-- Touches:  W: TABLE exos_org_ad_credentials (new; secret in vault.secrets)
--              TABLE exos_marketing_conversions (new; the outbox)
--              FUNCTION _exos_ad_config_ok (new, CHECK helper)
--              FUNCTION exos_set_ad_credential, exos_list_ad_credentials (new,
--                owner / manager)
--              FUNCTION _exos_email_sha256, _exos_email_sha256_google (new,
--                internal)
--              FUNCTION exos_tg_conversions_checkout, exos_tg_conversions_refund
--                (new triggers) on exos_checkout_sessions / exos_order_refunds
--              FUNCTION exos_conversions_claim_batch, exos_conversions_mark
--                (new, service role only)
--           R: vault.secrets / vault.create_secret / vault.update_secret /
--              vault.decrypted_secrets (Supabase Vault, installed on the
--              shared project: _cron_invoke_edge_fn reads CRON_SECRET from it,
--              see 20260702144637), exos_has_org_role, exos_is_admin
-- Pre-reqs: 20260929131000 (ad_ids, consent_marketing, user_agent on the
--           checkout session), 20260702123100 (exos_order_refunds).
--
-- Marketing audit build list #1 (server-side conversions). The browser pixels
-- (src/lib/pixels.ts) lose Purchases to ad blockers, iOS and the Stripe
-- redirect. Now, when a paid checkout is fulfilled, one outbox row is queued
-- per ad platform the org enabled, and the exos-conversions-drain edge
-- function sends it to that platform's conversions API with the same dedupe
-- id the browser used (the Stripe session id), so the platform counts the
-- purchase once.
--
-- A. exos_org_ad_credentials (org, platform): the NON-secret ids in `config`
--    (pixel id, measurement id, customer id, conversion action), whether it
--    is enabled, an optional test event code, and `secret_id`: the id of the
--    access token / API secret in Supabase Vault. The token itself is never
--    in a public table, never returned to a client, and read only by
--    exos_conversions_claim_batch (service role). RLS on, no client grants:
--    owners / managers go through exos_set_ad_credential (write; the secret
--    is write-only: NULL keeps it, '' removes it) and exos_list_ad_credentials
--    (config + has_secret + enabled + send counts, never the secret).
--    Enabling needs the platform's required ids and a saved secret.
--
-- B. exos_marketing_conversions: the outbox. A row is created only when
--      * the checkout session is fulfilled with amount_cents > 0 (free claims
--        have no value to report and are skipped),
--      * the buyer's consent_marketing = 'granted' at checkout, and
--      * the org has that platform enabled.
--    'Refund' rows: when a refund on such a session succeeds, for platforms
--    that take a refund event (GA4 only; Meta, TikTok, Reddit and Snap have
--    no standard refund event, Google Ads retractions are a separate API) and
--    only if a Purchase row exists for that session and platform.
--    The payload holds hashed user data only: SHA-256 of the normalized email
--    (plus Google's gmail normalization for GA4 / Google Ads), the ad click
--    and browser ids, the user agent, the event id / slug / name and the
--    quantity. No raw email, no IP: the stored client_ip_hash is salted, so it
--    is useless to the platforms and is not sent either (a match-quality cost
--    documented in docs/marketing-conversions.md).
--    Dedupe: unique (platform, event_name, event_id_dedupe); event_id_dedupe
--    is the Stripe session id for Purchase (= the browser pixel's eventID /
--    event_id / transaction_id) and 'refund:<refund row id>' for Refund.
--    The triggers never fail fulfilment or a refund: any error is a WARNING.
--
-- C. exos_conversions_claim_batch: FOR UPDATE SKIP LOCKED + a lease (status
--    'sending', attempts+1, claim_token), like exos_webhook_claim_batch; it
--    returns the credential (config, enabled, test code, the decrypted
--    secret). exos_conversions_mark writes the result only while the caller
--    still holds the lease (claim_token), so it is idempotent: a second mark
--    of the same claim changes nothing. 'retry' backs off 2^attempts minutes
--    (capped at 6 h) and becomes 'failed' at p_max_attempts.
--
-- Re-run safe (IF NOT EXISTS, CREATE OR REPLACE, guarded triggers). D4
-- authors; applying to prod is operator-gated. NOT applied.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- A. Credentials
-- ---------------------------------------------------------------------------

-- Per platform: which config keys exist, and each value's shape. Ids only.
CREATE OR REPLACE FUNCTION public._exos_ad_config_ok(p_platform text, p jsonb)
RETURNS boolean LANGUAGE sql IMMUTABLE
SET search_path TO 'public', 'pg_temp'
AS $$
  SELECT p IS NOT NULL
     AND jsonb_typeof(p) = 'object'
     AND length(p::text) <= 1000
     AND NOT EXISTS (
       SELECT 1 FROM jsonb_each(p) e
        WHERE jsonb_typeof(e.value) <> 'string'
           OR NOT (
             CASE p_platform
               WHEN 'meta'       THEN e.key = 'pixel_id'             AND (e.value #>> '{}') ~ '^[0-9]{5,20}$'
               WHEN 'tiktok'     THEN e.key = 'pixel_code'           AND (e.value #>> '{}') ~ '^[A-Z0-9]{10,40}$'
               WHEN 'ga4'        THEN e.key = 'measurement_id'       AND (e.value #>> '{}') ~ '^G-[A-Z0-9]{4,20}$'
               WHEN 'google_ads' THEN (e.key IN ('customer_id','login_customer_id') AND (e.value #>> '{}') ~ '^[0-9]{10}$')
                                   OR (e.key = 'conversion_action_id' AND (e.value #>> '{}') ~ '^[0-9]{1,20}$')
               WHEN 'reddit'     THEN e.key = 'pixel_id'             AND (e.value #>> '{}') ~ '^(a2|t2)_[A-Za-z0-9]{1,40}$'
               WHEN 'snap'       THEN e.key = 'pixel_id'             AND (e.value #>> '{}') ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
               ELSE false
             END)
     )
$$;
REVOKE ALL ON FUNCTION public._exos_ad_config_ok(text, jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public._exos_ad_config_ok(text, jsonb) TO authenticated, service_role;

CREATE TABLE IF NOT EXISTS public.exos_org_ad_credentials (
  org_id          uuid NOT NULL REFERENCES public.exos_orgs (id) ON DELETE CASCADE,
  platform        text NOT NULL
                    CONSTRAINT exos_org_ad_credentials_platform_chk
                    CHECK (platform IN ('meta','tiktok','ga4','google_ads','reddit','snap')),
  config          jsonb NOT NULL DEFAULT '{}'::jsonb,
  secret_id       uuid,                 -- vault.secrets.id; never the secret
  enabled         boolean NOT NULL DEFAULT false,
  test_event_code text,
  created_by      uuid,
  updated_by      uuid,
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (org_id, platform)
);

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'exos_org_ad_credentials_config_chk') THEN
    ALTER TABLE public.exos_org_ad_credentials
      ADD CONSTRAINT exos_org_ad_credentials_config_chk CHECK (public._exos_ad_config_ok(platform, config));
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'exos_org_ad_credentials_test_code_chk') THEN
    ALTER TABLE public.exos_org_ad_credentials
      ADD CONSTRAINT exos_org_ad_credentials_test_code_chk
      CHECK (test_event_code IS NULL OR test_event_code ~ '^[A-Za-z0-9_-]{1,64}$');
  END IF;
  -- Enabled needs a secret (the RPC also checks the required ids).
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'exos_org_ad_credentials_enabled_chk') THEN
    ALTER TABLE public.exos_org_ad_credentials
      ADD CONSTRAINT exos_org_ad_credentials_enabled_chk CHECK (NOT enabled OR secret_id IS NOT NULL);
  END IF;
END $$;

DROP TRIGGER IF EXISTS exos_org_ad_credentials_touch ON public.exos_org_ad_credentials;
CREATE TRIGGER exos_org_ad_credentials_touch BEFORE UPDATE ON public.exos_org_ad_credentials
  FOR EACH ROW EXECUTE FUNCTION public.exos_touch_updated_at();

ALTER TABLE public.exos_org_ad_credentials ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.exos_org_ad_credentials FROM PUBLIC, anon, authenticated;
GRANT ALL ON TABLE public.exos_org_ad_credentials TO service_role;

COMMENT ON TABLE public.exos_org_ad_credentials IS
  'Per-org ad platform credentials for server-side conversions. config = public ids only; the token is in Supabase Vault (secret_id). No client access: exos_set_ad_credential / exos_list_ad_credentials. mig 20260930100000.';

-- The ids each platform needs before it can be enabled.
CREATE OR REPLACE FUNCTION public._exos_ad_required_keys(p_platform text)
RETURNS text[] LANGUAGE sql IMMUTABLE
SET search_path TO 'public', 'pg_temp'
AS $$
  SELECT CASE p_platform
    WHEN 'meta'       THEN ARRAY['pixel_id']
    WHEN 'tiktok'     THEN ARRAY['pixel_code']
    WHEN 'ga4'        THEN ARRAY['measurement_id']
    WHEN 'google_ads' THEN ARRAY['customer_id','conversion_action_id']
    WHEN 'reddit'     THEN ARRAY['pixel_id']
    WHEN 'snap'       THEN ARRAY['pixel_id']
  END
$$;
REVOKE ALL ON FUNCTION public._exos_ad_required_keys(text) FROM PUBLIC, anon, authenticated;

-- Save one platform's credential. Owner / manager of the org (or a platform
-- admin). p_config replaces the stored ids. p_secret: NULL keeps the saved
-- secret, '' removes it (and disables), anything else replaces it in Vault.
-- Returns what exos_list_ad_credentials returns for the platform.
CREATE OR REPLACE FUNCTION public.exos_set_ad_credential(
  p_org_id          uuid,
  p_platform        text,
  p_config          jsonb,
  p_secret          text    DEFAULT NULL,
  p_enabled         boolean DEFAULT false,
  p_test_event_code text    DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_uid    uuid := auth.uid();
  v_row    public.exos_org_ad_credentials%ROWTYPE;
  v_found  boolean;
  v_secret uuid;
  v_name   text;
  v_config jsonb;
  v_code   text := nullif(btrim(coalesce(p_test_event_code, '')), '');
  v_missing text;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'exos_set_ad_credential: not authenticated' USING ERRCODE = '42501';
  END IF;
  IF p_org_id IS NULL OR NOT (public.exos_has_org_role(p_org_id, ARRAY['owner','manager']) OR public.exos_is_admin()) THEN
    RAISE EXCEPTION 'exos_set_ad_credential: owner or manager only' USING ERRCODE = '42501';
  END IF;
  IF p_platform IS NULL OR p_platform NOT IN ('meta','tiktok','ga4','google_ads','reddit','snap') THEN
    RAISE EXCEPTION 'exos_set_ad_credential: unknown platform %', p_platform USING ERRCODE = '22023';
  END IF;
  -- Drop empty values so a cleared field removes the key.
  SELECT coalesce(jsonb_object_agg(e.key, to_jsonb(btrim(e.value #>> '{}'))), '{}'::jsonb) INTO v_config
    FROM jsonb_each(coalesce(p_config, '{}'::jsonb)) e
   WHERE jsonb_typeof(e.value) = 'string' AND btrim(e.value #>> '{}') <> '';
  IF jsonb_typeof(coalesce(p_config, '{}'::jsonb)) <> 'object' OR NOT public._exos_ad_config_ok(p_platform, v_config) THEN
    RAISE EXCEPTION 'exos_set_ad_credential: invalid ids for %', p_platform USING ERRCODE = '22023';
  END IF;
  IF v_code IS NOT NULL AND v_code !~ '^[A-Za-z0-9_-]{1,64}$' THEN
    RAISE EXCEPTION 'exos_set_ad_credential: invalid test event code' USING ERRCODE = '22023';
  END IF;
  IF p_secret IS NOT NULL AND p_secret <> ''
     AND (length(p_secret) NOT BETWEEN 8 AND 4096 OR p_secret ~ '[[:cntrl:][:space:]]') THEN
    RAISE EXCEPTION 'exos_set_ad_credential: the token must be 8-4096 characters with no spaces' USING ERRCODE = '22023';
  END IF;

  SELECT * INTO v_row FROM public.exos_org_ad_credentials
   WHERE org_id = p_org_id AND platform = p_platform FOR UPDATE;
  v_found := FOUND;
  v_secret := CASE WHEN v_found THEN v_row.secret_id END;
  v_name := 'exos_ad:' || p_org_id::text || ':' || p_platform;

  IF p_secret = '' AND v_secret IS NOT NULL THEN
    -- Remove the secret. If this role can't delete from Vault, overwrite it.
    BEGIN
      DELETE FROM vault.secrets WHERE id = v_secret;
    EXCEPTION WHEN insufficient_privilege THEN
      PERFORM vault.update_secret(v_secret, 'revoked:' || gen_random_uuid()::text);
    END;
    v_secret := NULL;
  ELSIF p_secret IS NOT NULL AND p_secret <> '' THEN
    IF v_secret IS NULL OR NOT EXISTS (SELECT 1 FROM vault.secrets WHERE id = v_secret) THEN
      -- A secret left under this name (row deleted earlier) is reused.
      SELECT id INTO v_secret FROM vault.secrets WHERE name = v_name;
    END IF;
    IF v_secret IS NULL THEN
      v_secret := vault.create_secret(p_secret, v_name, 'Exos ad conversions token (' || p_platform || ')');
    ELSE
      PERFORM vault.update_secret(v_secret, p_secret);
    END IF;
  END IF;

  IF coalesce(p_enabled, false) THEN
    IF v_secret IS NULL THEN
      RAISE EXCEPTION 'exos_set_ad_credential: save the token before enabling %', p_platform USING ERRCODE = '22023';
    END IF;
    SELECT string_agg(k, ', ') INTO v_missing
      FROM unnest(public._exos_ad_required_keys(p_platform)) k WHERE NOT v_config ? k;
    IF v_missing IS NOT NULL THEN
      RAISE EXCEPTION 'exos_set_ad_credential: % needs %', p_platform, v_missing USING ERRCODE = '22023';
    END IF;
  END IF;

  INSERT INTO public.exos_org_ad_credentials AS c
         (org_id, platform, config, secret_id, enabled, test_event_code, created_by, updated_by)
  VALUES (p_org_id, p_platform, v_config, v_secret, coalesce(p_enabled, false), v_code, v_uid, v_uid)
  ON CONFLICT (org_id, platform) DO UPDATE
     SET config = EXCLUDED.config, secret_id = EXCLUDED.secret_id, enabled = EXCLUDED.enabled,
         test_event_code = EXCLUDED.test_event_code, updated_by = v_uid;

  RETURN jsonb_build_object(
    'platform', p_platform, 'config', v_config, 'has_secret', v_secret IS NOT NULL,
    'enabled', coalesce(p_enabled, false), 'test_event_code', v_code);
END $$;
REVOKE ALL ON FUNCTION public.exos_set_ad_credential(uuid, text, jsonb, text, boolean, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_set_ad_credential(uuid, text, jsonb, text, boolean, text) TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- B. Outbox
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.exos_marketing_conversions (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id           uuid NOT NULL REFERENCES public.exos_orgs (id) ON DELETE CASCADE,
  event_id         uuid,                  -- the Exos event (exos_events.id)
  session_id       text,                  -- exos_checkout_sessions.session_id
  refund_id        uuid,                  -- exos_order_refunds.id (Refund rows)
  platform         text NOT NULL
                     CONSTRAINT exos_marketing_conversions_platform_chk
                     CHECK (platform IN ('meta','tiktok','ga4','google_ads','reddit','snap')),
  event_name       text NOT NULL
                     CONSTRAINT exos_marketing_conversions_event_chk
                     CHECK (event_name IN ('Purchase','Refund')),
  event_id_dedupe  text NOT NULL,
  occurred_at      timestamptz NOT NULL,
  value_cents      int NOT NULL CHECK (value_cents >= 0),
  currency         text NOT NULL,
  payload          jsonb NOT NULL DEFAULT '{}'::jsonb,
  payload_planned  jsonb,                 -- the request as built (secret redacted)
  status           text NOT NULL DEFAULT 'pending'
                     CONSTRAINT exos_marketing_conversions_status_chk
                     CHECK (status IN ('pending','sending','sent','failed','skipped')),
  attempts         int NOT NULL DEFAULT 0,
  next_attempt_at  timestamptz NOT NULL DEFAULT now(),
  claimed_at       timestamptz,
  claim_token      uuid,
  last_status_code int,
  last_error       text,
  sent_at          timestamptz,
  created_at       timestamptz NOT NULL DEFAULT now(),
  updated_at       timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT exos_marketing_conversions_dedupe_uq UNIQUE (platform, event_name, event_id_dedupe)
);
CREATE INDEX IF NOT EXISTS exos_marketing_conversions_due_idx
  ON public.exos_marketing_conversions (next_attempt_at) WHERE status = 'pending';
CREATE INDEX IF NOT EXISTS exos_marketing_conversions_lease_idx
  ON public.exos_marketing_conversions (claimed_at) WHERE status = 'sending';
CREATE INDEX IF NOT EXISTS exos_marketing_conversions_org_idx
  ON public.exos_marketing_conversions (org_id, platform, created_at);
CREATE INDEX IF NOT EXISTS exos_marketing_conversions_session_idx
  ON public.exos_marketing_conversions (session_id);

DROP TRIGGER IF EXISTS exos_marketing_conversions_touch ON public.exos_marketing_conversions;
CREATE TRIGGER exos_marketing_conversions_touch BEFORE UPDATE ON public.exos_marketing_conversions
  FOR EACH ROW EXECUTE FUNCTION public.exos_touch_updated_at();

ALTER TABLE public.exos_marketing_conversions ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.exos_marketing_conversions FROM PUBLIC, anon, authenticated;
GRANT ALL ON TABLE public.exos_marketing_conversions TO service_role;

COMMENT ON TABLE public.exos_marketing_conversions IS
  'Server-side ad conversions outbox (Purchase / Refund per platform), drained by exos-conversions-drain. Only with consent_marketing = granted and the platform enabled; hashed user data only. mig 20260930100000.';

-- SHA-256 hex of the email as most platforms normalize it: trimmed, lower case.
CREATE OR REPLACE FUNCTION public._exos_email_sha256(p_email text)
RETURNS text LANGUAGE sql IMMUTABLE
SET search_path TO 'public', 'pg_temp'
AS $$
  SELECT CASE WHEN nullif(btrim(p_email), '') IS NULL OR position('@' in p_email) = 0 THEN NULL
    ELSE encode(extensions.digest(convert_to(lower(btrim(p_email)), 'UTF8'), 'sha256'), 'hex') END
$$;
-- Google's rule (GA4 user_data, Data Manager): also drop the dots in the
-- local part of gmail.com / googlemail.com addresses.
CREATE OR REPLACE FUNCTION public._exos_email_sha256_google(p_email text)
RETURNS text LANGUAGE sql IMMUTABLE
SET search_path TO 'public', 'pg_temp'
AS $$
  SELECT CASE
    WHEN nullif(btrim(p_email), '') IS NULL OR position('@' in p_email) = 0 THEN NULL
    WHEN split_part(lower(btrim(p_email)), '@', 2) IN ('gmail.com', 'googlemail.com') THEN
      encode(extensions.digest(convert_to(
        replace(split_part(lower(btrim(p_email)), '@', 1), '.', '') || '@' || split_part(lower(btrim(p_email)), '@', 2),
        'UTF8'), 'sha256'), 'hex')
    ELSE public._exos_email_sha256(p_email) END
$$;
REVOKE ALL ON FUNCTION public._exos_email_sha256(text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._exos_email_sha256_google(text) FROM PUBLIC, anon, authenticated;

-- Fulfilled paid checkout with marketing consent -> one Purchase row per
-- enabled platform. Never fails the fulfilment.
CREATE OR REPLACE FUNCTION public.exos_tg_conversions_checkout()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_ev  record;
BEGIN
  IF NEW.status IS DISTINCT FROM 'fulfilled'
     OR (TG_OP = 'UPDATE' AND OLD.status IS NOT DISTINCT FROM 'fulfilled')
     OR coalesce(NEW.amount_cents, 0) <= 0
     OR NEW.consent_marketing IS DISTINCT FROM 'granted' THEN
    RETURN NEW;
  END IF;
  BEGIN
    SELECT e.id, e.slug, e.name INTO v_ev FROM public.exos_events e WHERE e.id = NEW.event_id;
    INSERT INTO public.exos_marketing_conversions
           (org_id, event_id, session_id, platform, event_name, event_id_dedupe,
            occurred_at, value_cents, currency, payload)
    SELECT NEW.org_id, NEW.event_id, NEW.session_id, c.platform, 'Purchase', NEW.session_id,
           coalesce(NEW.fulfilled_at, now()), NEW.amount_cents, upper(coalesce(NEW.currency, 'usd')),
           jsonb_strip_nulls(jsonb_build_object(
             'transaction_id', NEW.session_id,
             'em', public._exos_email_sha256(NEW.buyer_email),
             'em_google', public._exos_email_sha256_google(NEW.buyer_email),
             'user_agent', NEW.user_agent,
             'ad_ids', NEW.ad_ids,
             'click_at', NEW.created_at,
             'quantity', NEW.quantity,
             'event', jsonb_strip_nulls(jsonb_build_object('id', NEW.event_id, 'slug', v_ev.slug, 'name', left(v_ev.name, 200))),
             'consent', 'granted'))
      FROM public.exos_org_ad_credentials c
     WHERE c.org_id = NEW.org_id AND c.enabled
    ON CONFLICT ON CONSTRAINT exos_marketing_conversions_dedupe_uq DO NOTHING;
  EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'exos_tg_conversions_checkout: % (session %)', SQLERRM, NEW.session_id;
  END;
  RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION public.exos_tg_conversions_checkout() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS exos_checkout_conversions ON public.exos_checkout_sessions;
CREATE TRIGGER exos_checkout_conversions AFTER INSERT OR UPDATE OF status ON public.exos_checkout_sessions
  FOR EACH ROW EXECUTE FUNCTION public.exos_tg_conversions_checkout();

-- Succeeded refund -> a Refund row for each refund-capable platform (GA4)
-- that got this session's Purchase and is still enabled. Never fails the refund.
CREATE OR REPLACE FUNCTION public.exos_tg_conversions_refund()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF NEW.status IS DISTINCT FROM 'succeeded'
     OR (TG_OP = 'UPDATE' AND OLD.status IS NOT DISTINCT FROM 'succeeded')
     OR coalesce(NEW.amount_cents, 0) <= 0 THEN
    RETURN NEW;
  END IF;
  BEGIN
    INSERT INTO public.exos_marketing_conversions
           (org_id, event_id, session_id, refund_id, platform, event_name, event_id_dedupe,
            occurred_at, value_cents, currency, payload)
    SELECT p.org_id, p.event_id, p.session_id, NEW.id, p.platform, 'Refund', 'refund:' || NEW.id::text,
           now(), NEW.amount_cents, upper(coalesce(NEW.currency, p.currency)),
           (p.payload - 'user_agent') || jsonb_build_object('refund_id', NEW.id, 'partial', NEW.is_partial)
      FROM public.exos_marketing_conversions p
      JOIN public.exos_org_ad_credentials c ON c.org_id = p.org_id AND c.platform = p.platform AND c.enabled
     WHERE p.session_id = NEW.session_id
       AND p.event_name = 'Purchase'
       AND p.platform IN ('ga4')
    ON CONFLICT ON CONSTRAINT exos_marketing_conversions_dedupe_uq DO NOTHING;
  EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'exos_tg_conversions_refund: % (refund %)', SQLERRM, NEW.id;
  END;
  RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION public.exos_tg_conversions_refund() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS exos_order_refunds_conversions ON public.exos_order_refunds;
CREATE TRIGGER exos_order_refunds_conversions AFTER INSERT OR UPDATE OF status ON public.exos_order_refunds
  FOR EACH ROW EXECUTE FUNCTION public.exos_tg_conversions_refund();

-- ---------------------------------------------------------------------------
-- A2. Listing (after B: it counts outbox rows)
-- ---------------------------------------------------------------------------
-- The org's saved platforms: ids, has_secret, enabled, test code and the last
-- 30 days' counts. Never the secret. Owner / manager (or a platform admin).
CREATE OR REPLACE FUNCTION public.exos_list_ad_credentials(p_org_id uuid)
RETURNS TABLE(platform text, config jsonb, has_secret boolean, enabled boolean, test_event_code text,
              updated_at timestamptz, sent_30d int, skipped_30d int, failed_30d int, pending int,
              last_sent_at timestamptz)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
#variable_conflict use_column
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'exos_list_ad_credentials: not authenticated' USING ERRCODE = '42501';
  END IF;
  IF p_org_id IS NULL OR NOT (public.exos_has_org_role(p_org_id, ARRAY['owner','manager']) OR public.exos_is_admin()) THEN
    RAISE EXCEPTION 'exos_list_ad_credentials: owner or manager only' USING ERRCODE = '42501';
  END IF;
  RETURN QUERY
  SELECT c.platform, c.config, c.secret_id IS NOT NULL, c.enabled, c.test_event_code, c.updated_at,
         coalesce(s.sent, 0), coalesce(s.skipped, 0), coalesce(s.failed, 0), coalesce(s.pending, 0),
         s.last_sent_at
    FROM public.exos_org_ad_credentials c
    LEFT JOIN LATERAL (
      SELECT count(*) FILTER (WHERE m.status = 'sent')::int                       AS sent,
             count(*) FILTER (WHERE m.status = 'skipped')::int                    AS skipped,
             count(*) FILTER (WHERE m.status = 'failed')::int                     AS failed,
             count(*) FILTER (WHERE m.status IN ('pending','sending'))::int       AS pending,
             max(m.sent_at)                                                       AS last_sent_at
        FROM public.exos_marketing_conversions m
       WHERE m.org_id = c.org_id AND m.platform = c.platform
         AND m.created_at > now() - interval '30 days') s ON true
   WHERE c.org_id = p_org_id
   ORDER BY c.platform;
END $$;
REVOKE ALL ON FUNCTION public.exos_list_ad_credentials(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_list_ad_credentials(uuid) TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- C. Drain: claim with a lease, mark the result
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.exos_conversions_claim_batch(
  p_limit         integer DEFAULT 25,
  p_max_attempts  integer DEFAULT 6,
  p_lease_minutes integer DEFAULT 10
)
RETURNS TABLE(id uuid, org_id uuid, platform text, event_name text, event_id_dedupe text,
              occurred_at timestamptz, value_cents int, currency text, payload jsonb,
              attempts int, claim_token uuid,
              enabled boolean, config jsonb, test_event_code text, secret text)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
#variable_conflict use_column
BEGIN
  -- A lease that ran out on the final attempt: the run died mid-send; give up.
  UPDATE public.exos_marketing_conversions m
     SET status = 'failed', claim_token = NULL,
         last_error = left(coalesce(m.last_error || '; ', '') || 'lease expired on final attempt', 500)
   WHERE m.status = 'sending'
     AND m.claimed_at < now() - make_interval(mins => p_lease_minutes)
     AND m.attempts >= p_max_attempts;

  RETURN QUERY
  WITH claimable AS (
    SELECT m.id
      FROM public.exos_marketing_conversions m
     WHERE ( (m.status = 'pending' AND m.next_attempt_at <= now())
          OR (m.status = 'sending' AND m.claimed_at < now() - make_interval(mins => p_lease_minutes)) )
       AND m.attempts < p_max_attempts
     ORDER BY m.next_attempt_at
     LIMIT GREATEST(LEAST(p_limit, 200), 1)
     FOR UPDATE OF m SKIP LOCKED
  ), claimed AS (
    UPDATE public.exos_marketing_conversions m
       SET status      = 'sending',
           attempts    = m.attempts + 1,
           claimed_at  = now(),
           claim_token = gen_random_uuid()
      FROM claimable c
     WHERE m.id = c.id
    RETURNING m.*
  )
  SELECT k.id, k.org_id, k.platform, k.event_name, k.event_id_dedupe, k.occurred_at, k.value_cents,
         k.currency, k.payload, k.attempts, k.claim_token,
         coalesce(c.enabled, false), coalesce(c.config, '{}'::jsonb), c.test_event_code,
         (SELECT d.decrypted_secret FROM vault.decrypted_secrets d WHERE d.id = c.secret_id)
    FROM claimed k
    LEFT JOIN public.exos_org_ad_credentials c ON c.org_id = k.org_id AND c.platform = k.platform;
END $function$;
REVOKE ALL ON FUNCTION public.exos_conversions_claim_batch(integer, integer, integer) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_conversions_claim_batch(integer, integer, integer) TO service_role;

-- Record a claimed row's result. Lands only while p_claim_token still holds
-- the lease (status 'sending'), so a replay or a run whose lease was taken
-- over changes nothing (returns NULL). p_result:
--   sent     -> 'sent', sent_at
--   skipped  -> 'skipped' (not sendable, or dry-run; last_error says why)
--   failed   -> 'failed' (permanent, e.g. 400 from the platform)
--   retry    -> 'pending' after 2^attempts minutes (6 h cap), or 'failed'
--               once attempts reached p_max_attempts
--   release  -> 'pending' now, the claim's attempt undone (run out of time)
-- p_planned (the request as built, secret redacted) is kept when given.
CREATE OR REPLACE FUNCTION public.exos_conversions_mark(
  p_id           uuid,
  p_claim_token  uuid,
  p_result       text,
  p_error        text    DEFAULT NULL,
  p_status_code  integer DEFAULT NULL,
  p_planned      jsonb   DEFAULT NULL,
  p_max_attempts integer DEFAULT 6
) RETURNS text
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_row public.exos_marketing_conversions%ROWTYPE;
  v_new text;
BEGIN
  IF p_result IS NULL OR p_result NOT IN ('sent','skipped','failed','retry','release') THEN
    RAISE EXCEPTION 'exos_conversions_mark: unknown result %', p_result USING ERRCODE = '22023';
  END IF;
  SELECT * INTO v_row FROM public.exos_marketing_conversions
   WHERE id = p_id AND status = 'sending' AND claim_token = p_claim_token
   FOR UPDATE;
  IF NOT FOUND THEN
    RETURN NULL;
  END IF;
  v_new := CASE p_result
    WHEN 'retry'   THEN CASE WHEN v_row.attempts >= p_max_attempts THEN 'failed' ELSE 'pending' END
    WHEN 'release' THEN 'pending'
    ELSE p_result END;
  UPDATE public.exos_marketing_conversions SET
    status           = v_new,
    claim_token      = NULL,
    attempts         = CASE WHEN p_result = 'release' THEN GREATEST(v_row.attempts - 1, 0) ELSE v_row.attempts END,
    next_attempt_at  = CASE WHEN p_result = 'retry'
                            THEN now() + LEAST(make_interval(mins => (2 ^ LEAST(v_row.attempts, 10))::int), interval '6 hours')
                            ELSE v_row.next_attempt_at END,
    sent_at          = CASE WHEN v_new = 'sent' THEN now() ELSE v_row.sent_at END,
    last_error       = CASE WHEN p_result IN ('sent','release') THEN v_row.last_error ELSE left(p_error, 500) END,
    last_status_code = coalesce(p_status_code, v_row.last_status_code),
    payload_planned  = coalesce(p_planned, v_row.payload_planned)
  WHERE id = p_id;
  RETURN v_new;
END $$;
REVOKE ALL ON FUNCTION public.exos_conversions_mark(uuid, uuid, text, text, integer, jsonb, integer) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_conversions_mark(uuid, uuid, text, text, integer, jsonb, integer) TO service_role;
