-- ============================================================================
-- Migration 20261121190500 — Exos: the ads phase, dry run only (Reddit
-- conversions fixes, audience sync, "Boost this event", X conversions)
-- ============================================================================
-- Touches:  C: FUNCTION _exos_email_sha256_reddit (Reddit's email rule; no
--              client EXECUTE)
--           C: FUNCTION _exos_tg_conversions_reddit_email + TRIGGER
--              exos_marketing_conversions_reddit_email (BEFORE INSERT on the
--              outbox: a Reddit row gets payload.em_reddit)
--           W: TABLE exos_marketing_conversions (the platform CHECK takes 'x')
--           C: FUNCTION _exos_tg_conversions_checkout_x + TRIGGER
--              exos_checkout_conversions_x (AFTER on exos_checkout_sessions:
--              an X Purchase row when the org's ads_x store row is on)
--           R: FUNCTION _exos_cred_providers, _exos_cred_managed (CREATE OR
--              REPLACE: + ads_x, ads_meta_api, ads_reddit_api, managed)
--           C: FUNCTION exos_ads_campaign_context (authenticated, owner /
--              manager: the event facts the planner needs, which ad
--              credentials are connected; never a secret)
--           C: FUNCTION exos_ads_audience_source (service role: the
--              consenting fans and buyers' email / phone for the audience
--              builder, which hashes them at once; logged in
--              exos_audience_exports, 20 a day per org)
--           R: exos_checkout_sessions, exos_fans, exos_mail_prefs, auth.users,
--              exos_events, exos_event_geo, exos_ticket_tiers,
--              exos_org_integrations, exos_org_ad_credentials,
--              exos_audience_exports, exos_has_org_role
-- Pre-reqs: 20261121162400 (the channel core: the store, the provider
--           functions replaced here), 20260930100000 (the outbox and its
--           checkout trigger), 20260930101000 (exos_audience_exports),
--           20261031120000 (exos_fans), 20260924230000 (exos_event_geo)
--
-- Operator 2026-11-21: "For the APIs build and keep read only till build is
-- complete". Nothing here sends anything: every ad-platform write is a dry
-- run behind the channel core's GatedHttp (_shared/channels/adapters/
-- metaAds.ts, redditAds.ts, googleCustomerMatch.ts, xAds.ts), and the X
-- conversions rows are drained like the others (dry run unless
-- EXOS_CONVERSIONS_LIVE=true, and then only through the x_ads adapter's
-- GatedHttp with the org's switch and EXOS_X_ADS_WRITES=on).
--
-- 1. REDDIT'S EMAIL. Reddit normalizes an email before hashing: lower case,
--    trimmed, and in the local part everything from the first "+" on dropped
--    and every dot removed (every domain). _exos_email_sha256_reddit is that
--    hash (TS twin: normalizeEmailReddit in _shared/hashedIds.ts); a Reddit
--    outbox row gets it as payload.em_reddit from a BEFORE INSERT trigger on
--    the outbox (the existing checkout trigger is not patched). It never
--    fails the insert.
-- 2. X CONVERSIONS. 'x' joins the outbox's platforms. Its credential is in
--    the channel-core store (provider ads_x: config {pixel_id, event_id},
--    secret {"token", "token_secret"}); a separate AFTER trigger on
--    exos_checkout_sessions queues an X Purchase under the same rules as the
--    others (fulfilled, paid, consent_marketing = 'granted') when that row
--    is on (writes_enabled, not disabled, a secret, both ids). The claim
--    batch is unchanged (it LEFT JOINs the old credentials table); the drain
--    reads an X row's credential from the store.
-- 3. NEW PROVIDERS (managed: the generic Integrations save / remove refuse
--    them; a connect flow, not built yet, writes them): ads_x, ads_meta_api
--    (a Marketing API token with ads_management: custom audiences, campaigns)
--    and ads_reddit_api (a Reddit Ads API OAuth token). The conversions
--    tokens (ads_meta, ads_reddit) can't manage audiences or campaigns.
--    Google Customer Match reuses ads_google_ads (the Data Manager refresh
--    token from exos-oauth-google).
-- 4. THE PLANNER'S READS. exos_ads_campaign_context: owner / manager, the
--    event's name, dates, image, venue, area (lat / lng only for a venue
--    the public can see), cheapest public price and which ad credentials
--    are connected. exos_ads_audience_source: service role only, the people
--    an audience may hold: buyers with a fulfilled (or partly refunded)
--    order who granted ADVERTISING consent at checkout (the latest choice
--    for that email wins, as in exos_org_audience_export), plus the org's
--    fans whose latest advertising choice here (by email or account) is
--    granted; never anyone unsubscribed from marketing mail, off the org's
--    email list, discarded or deleted. Following the org or joining its
--    email list is NOT advertising consent (operator 2026-09-30). The raw
--    email goes only to the service role (exos-ads hashes it at once with
--    hashedIds.ts and drops it); every call is logged in
--    exos_audience_exports and counts toward its 20 a day.
--
-- Nothing in an existing function body is text-patched (README rule 4 does
-- not arise): two small provider functions from 20261121162400 are replaced
-- whole, the rest is new. Re-run safe (CREATE OR REPLACE, DROP ... IF
-- EXISTS). Prod apply needs operator OK.
-- ============================================================================

-- ===========================================================================
-- 1. Reddit's email hash, on Reddit outbox rows
-- ===========================================================================
CREATE OR REPLACE FUNCTION public._exos_email_sha256_reddit(p_email text)
RETURNS text LANGUAGE sql IMMUTABLE
SET search_path TO 'public', 'pg_temp'
AS $$
  SELECT CASE
    WHEN nullif(btrim(p_email), '') IS NULL OR position('@' in p_email) = 0 THEN NULL
    WHEN replace(split_part(split_part(lower(btrim(p_email)), '@', 1), '+', 1), '.', '') = ''
      OR split_part(lower(btrim(p_email)), '@', 2) = '' THEN NULL
    ELSE encode(extensions.digest(convert_to(
           replace(split_part(split_part(lower(btrim(p_email)), '@', 1), '+', 1), '.', '')
           || '@' || split_part(lower(btrim(p_email)), '@', 2), 'UTF8'), 'sha256'), 'hex') END
$$;
REVOKE ALL ON FUNCTION public._exos_email_sha256_reddit(text) FROM PUBLIC, anon, authenticated;
COMMENT ON FUNCTION public._exos_email_sha256_reddit(text) IS
  'SHA-256 hex of an email as Reddit normalizes it (lower case, trimmed, local part without its +tag and dots). TS twin: normalizeEmailReddit (_shared/hashedIds.ts). mig 20261121190500.';

CREATE OR REPLACE FUNCTION public._exos_tg_conversions_reddit_email()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_hash text;
BEGIN
  IF NEW.platform IS DISTINCT FROM 'reddit' OR NEW.session_id IS NULL OR coalesce(NEW.payload, '{}'::jsonb) ? 'em_reddit' THEN
    RETURN NEW;
  END IF;
  BEGIN
    SELECT public._exos_email_sha256_reddit(s.buyer_email) INTO v_hash
      FROM public.exos_checkout_sessions s WHERE s.session_id = NEW.session_id;
    IF v_hash IS NOT NULL THEN
      NEW.payload := coalesce(NEW.payload, '{}'::jsonb) || jsonb_build_object('em_reddit', v_hash);
    END IF;
  EXCEPTION WHEN OTHERS THEN
    RAISE WARNING '_exos_tg_conversions_reddit_email: % (session %)', SQLERRM, NEW.session_id;
  END;
  RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION public._exos_tg_conversions_reddit_email() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS exos_marketing_conversions_reddit_email ON public.exos_marketing_conversions;
CREATE TRIGGER exos_marketing_conversions_reddit_email BEFORE INSERT ON public.exos_marketing_conversions
  FOR EACH ROW EXECUTE FUNCTION public._exos_tg_conversions_reddit_email();

-- ===========================================================================
-- 2. X conversions in the outbox
-- ===========================================================================
ALTER TABLE public.exos_marketing_conversions DROP CONSTRAINT IF EXISTS exos_marketing_conversions_platform_chk;
ALTER TABLE public.exos_marketing_conversions
  ADD CONSTRAINT exos_marketing_conversions_platform_chk
  CHECK (platform IN ('meta','tiktok','ga4','google_ads','reddit','snap','x'));

-- Fulfilled paid checkout with marketing consent -> an X Purchase row when
-- the org's ads_x store row is on. Same rules and payload as
-- exos_tg_conversions_checkout (mig 20260930100000). Never fails fulfilment.
CREATE OR REPLACE FUNCTION public._exos_tg_conversions_checkout_x()
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
    IF NOT EXISTS (SELECT 1 FROM public.exos_org_integrations i
                    WHERE i.org_id = NEW.org_id AND i.provider = 'ads_x' AND i.writes_enabled
                      AND i.status <> 'disabled' AND i.secret_id IS NOT NULL
                      AND i.config ? 'pixel_id' AND i.config ? 'event_id') THEN
      RETURN NEW;
    END IF;
    SELECT e.id, e.slug, e.name INTO v_ev FROM public.exos_events e WHERE e.id = NEW.event_id;
    INSERT INTO public.exos_marketing_conversions
           (org_id, event_id, session_id, platform, event_name, event_id_dedupe,
            occurred_at, value_cents, currency, payload)
    VALUES (NEW.org_id, NEW.event_id, NEW.session_id, 'x', 'Purchase', NEW.session_id,
            coalesce(NEW.fulfilled_at, now()), NEW.amount_cents, upper(coalesce(NEW.currency, 'usd')),
            jsonb_strip_nulls(jsonb_build_object(
              'transaction_id', NEW.session_id,
              'em', public._exos_email_sha256(NEW.buyer_email),
              'user_agent', NEW.user_agent,
              'ad_ids', NEW.ad_ids,
              'click_at', NEW.created_at,
              'quantity', NEW.quantity,
              'event', jsonb_strip_nulls(jsonb_build_object('id', NEW.event_id, 'slug', v_ev.slug, 'name', left(v_ev.name, 200))),
              'consent', 'granted')))
    ON CONFLICT ON CONSTRAINT exos_marketing_conversions_dedupe_uq DO NOTHING;
  EXCEPTION WHEN OTHERS THEN
    RAISE WARNING '_exos_tg_conversions_checkout_x: % (session %)', SQLERRM, NEW.session_id;
  END;
  RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION public._exos_tg_conversions_checkout_x() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS exos_checkout_conversions_x ON public.exos_checkout_sessions;
CREATE TRIGGER exos_checkout_conversions_x AFTER INSERT OR UPDATE OF status ON public.exos_checkout_sessions
  FOR EACH ROW EXECUTE FUNCTION public._exos_tg_conversions_checkout_x();

-- ===========================================================================
-- 3. The ad providers in the store (replacing 20261121162400's two lists)
-- ===========================================================================
CREATE OR REPLACE FUNCTION public._exos_cred_managed(p_provider text)
RETURNS boolean LANGUAGE sql IMMUTABLE
SET search_path = public, pg_temp
AS $$
  SELECT coalesce(p_provider, '') = ANY (ARRAY['eventbrite', 'dice', 'discord', 'lysted',
    'ads_meta', 'ads_tiktok', 'ads_ga4', 'ads_google_ads', 'ads_reddit', 'ads_snap',
    'ads_x', 'ads_meta_api', 'ads_reddit_api']::text[])
$$;
GRANT EXECUTE ON FUNCTION public._exos_cred_managed(text) TO authenticated, service_role;
REVOKE ALL ON FUNCTION public._exos_cred_managed(text) FROM PUBLIC, anon;

CREATE OR REPLACE FUNCTION public._exos_cred_providers()
RETURNS text[] LANGUAGE sql IMMUTABLE
SET search_path = public, pg_temp
AS $$
  SELECT public.exos_integration_providers() || ARRAY['eventbrite', 'dice', 'discord', 'lysted',
    'ads_meta', 'ads_tiktok', 'ads_ga4', 'ads_google_ads', 'ads_reddit', 'ads_snap',
    'ads_x', 'ads_meta_api', 'ads_reddit_api']::text[]
$$;
GRANT EXECUTE ON FUNCTION public._exos_cred_providers() TO authenticated, service_role;
REVOKE ALL ON FUNCTION public._exos_cred_providers() FROM PUBLIC, anon;

-- ===========================================================================
-- 4. The planner's reads
-- ===========================================================================
-- Is a provider connected (a secret saved, not disabled), store or old table.
CREATE OR REPLACE FUNCTION public._exos_ads_connected(p_org_id uuid, p_provider text)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT EXISTS (SELECT 1 FROM public.exos_org_integrations i
                  WHERE i.org_id = p_org_id AND i.provider = p_provider AND i.secret_id IS NOT NULL AND i.status <> 'disabled')
      OR (p_provider IN ('ads_meta', 'ads_tiktok', 'ads_ga4', 'ads_google_ads', 'ads_reddit', 'ads_snap')
          AND EXISTS (SELECT 1 FROM public.exos_org_ad_credentials c
                       WHERE c.org_id = p_org_id AND c.platform = substr(p_provider, 5) AND c.secret_id IS NOT NULL))
$$;
REVOKE ALL ON FUNCTION public._exos_ads_connected(uuid, text) FROM PUBLIC, anon, authenticated, service_role;

-- Owner / manager: what the campaign planner needs about the event (or, with
-- no event, the org only) and which ad credentials are connected. Never a
-- secret, an id from a credential's config, or a buyer.
CREATE OR REPLACE FUNCTION public.exos_ads_campaign_context(p_org_id uuid, p_event_id uuid DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_org  record;
  v_ev   record;
  v_geo  record;
  v_tier record;
  v_out  jsonb;
  v_open boolean;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'exos_ads_campaign_context: sign in first' USING ERRCODE = '42501';
  END IF;
  IF p_org_id IS NULL OR NOT public.exos_has_org_role(p_org_id, ARRAY['owner', 'manager']) THEN
    RAISE EXCEPTION 'exos_ads_campaign_context: owners and managers only' USING ERRCODE = '42501';
  END IF;
  SELECT o.id, o.name INTO v_org FROM public.exos_orgs o WHERE o.id = p_org_id;
  v_out := jsonb_build_object(
    'org', jsonb_build_object('id', v_org.id, 'name', v_org.name),
    'connected', jsonb_build_object(
      'ads_meta_api', public._exos_ads_connected(p_org_id, 'ads_meta_api'),
      'ads_meta', public._exos_ads_connected(p_org_id, 'ads_meta'),
      'ads_reddit_api', public._exos_ads_connected(p_org_id, 'ads_reddit_api'),
      'ads_reddit', public._exos_ads_connected(p_org_id, 'ads_reddit'),
      'ads_google_ads', public._exos_ads_connected(p_org_id, 'ads_google_ads'),
      'ads_x', public._exos_ads_connected(p_org_id, 'ads_x')),
    'event', NULL);
  IF p_event_id IS NULL THEN
    RETURN v_out;
  END IF;
  SELECT e.* INTO v_ev FROM public.exos_events e WHERE e.id = p_event_id AND e.org_id = p_org_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'exos_ads_campaign_context: not one of this organization''s events' USING ERRCODE = '22023';
  END IF;
  -- The pin only where the public sees the venue (not a secret / TBA location).
  v_open := coalesce(to_jsonb(v_ev) ->> 'location_mode', 'venue_record') IN ('venue_record', 'unlisted_venue');
  SELECT g.lat, g.lng INTO v_geo FROM public.exos_event_geo g
   WHERE g.event_id = p_event_id AND g.status = 'ok' AND g.lat IS NOT NULL AND v_open;
  SELECT min(t.price) FILTER (WHERE t.price > 0) AS min_price, count(*) AS n,
         count(*) FILTER (WHERE t.visibility = 'public') AS n_public,
         bool_and(t.price = 0) AS all_free
    INTO v_tier
    FROM public.exos_ticket_tiers t WHERE t.event_id = p_event_id;
  RETURN v_out || jsonb_build_object('event', jsonb_strip_nulls(jsonb_build_object(
    'id', v_ev.id, 'name', left(v_ev.name, 200), 'slug', v_ev.slug, 'status', v_ev.status,
    'starts_at', v_ev.starts_at, 'ends_at', v_ev.ends_at, 'timezone', v_ev.timezone, 'currency', v_ev.currency,
    'image_url', v_ev.image_url, 'description', left(v_ev.description, 500), 'venue_name', v_ev.venue_name,
    'venue_location', v_ev.venue_location,
    'venue_address', CASE WHEN v_open THEN v_ev.venue_address END,
    'location_mode', coalesce(to_jsonb(v_ev) ->> 'location_mode', 'venue_record'),
    'lat', v_geo.lat, 'lng', v_geo.lng,
    'min_price_cents', CASE WHEN v_tier.min_price IS NOT NULL THEN round(v_tier.min_price * 100)::int END,
    'free', coalesce(v_tier.all_free, false) AND coalesce(v_tier.n, 0) > 0,
    'hidden', coalesce(v_tier.n, 0) > 0 AND coalesce(v_tier.n_public, 0) = 0)));
END $$;
REVOKE ALL ON FUNCTION public.exos_ads_campaign_context(uuid, uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_ads_campaign_context(uuid, uuid) TO authenticated, service_role;
COMMENT ON FUNCTION public.exos_ads_campaign_context(uuid, uuid) IS
  'Owner / manager: the event facts the "Boost this event" planner needs and which ad credentials are connected (booleans). No secret, no buyer. mig 20261121190500.';

-- Service role: the people an ad audience may hold, raw email / phone for
-- the audience builder to hash at once. Consenting buyers and fans only.
CREATE OR REPLACE FUNCTION public.exos_ads_audience_source(p_org_id uuid, p_event_id uuid DEFAULT NULL, p_actor uuid DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_rows  jsonb;
  v_n     integer;
  v_actor uuid;
BEGIN
  IF p_org_id IS NULL OR NOT EXISTS (SELECT 1 FROM public.exos_orgs o WHERE o.id = p_org_id) THEN
    RAISE EXCEPTION 'exos_ads_audience_source: unknown organization' USING ERRCODE = '22023';
  END IF;
  IF p_event_id IS NOT NULL
     AND NOT EXISTS (SELECT 1 FROM public.exos_events e WHERE e.id = p_event_id AND e.org_id = p_org_id) THEN
    RAISE EXCEPTION 'exos_ads_audience_source: not one of this organization''s events' USING ERRCODE = '22023';
  END IF;
  IF (SELECT count(*) FROM public.exos_audience_exports x
       WHERE x.org_id = p_org_id AND x.created_at > now() - interval '1 day') >= 20 THEN
    RAISE EXCEPTION 'exos_ads_audience_source: daily audience limit reached (20 per organization)' USING ERRCODE = 'P0001';
  END IF;
  SELECT u.id INTO v_actor FROM auth.users u WHERE u.id = p_actor;

  WITH sess AS (
    SELECT s.session_id, s.event_id, s.buyer_uid, s.status, s.consent_marketing, s.created_at,
           lower(btrim(coalesce(nullif(btrim(s.buyer_email), ''), u.email))) AS email,
           regexp_replace(regexp_replace(coalesce(to_jsonb(u) ->> 'phone', ''), '\D', '', 'g'), '^0+', '') AS phone_digits,
           (s.buyer_uid IS NOT NULL AND u.id IS NULL) AS account_gone
      FROM public.exos_checkout_sessions s
      LEFT JOIN auth.users u ON u.id = s.buyer_uid
     WHERE s.org_id = p_org_id
  ),
  -- The latest advertising choice at this org's checkouts, by email and by account.
  by_email AS (
    SELECT DISTINCT ON (x.email) x.email, x.consent_marketing AS choice
      FROM sess x
     WHERE x.email IS NOT NULL AND x.consent_marketing IN ('granted', 'denied')
     ORDER BY x.email, x.created_at DESC, x.session_id DESC
  ),
  by_uid AS (
    SELECT DISTINCT ON (x.buyer_uid) x.buyer_uid, x.consent_marketing AS choice
      FROM sess x
     WHERE x.buyer_uid IS NOT NULL AND x.consent_marketing IN ('granted', 'denied')
     ORDER BY x.buyer_uid, x.created_at DESC, x.session_id DESC
  ),
  buyers AS (
    SELECT b.email, b.buyer_uid AS uid, b.phone_digits, 'buyer'::text AS source
      FROM sess b
      LEFT JOIN by_email l ON l.email = b.email
      LEFT JOIN by_uid lu ON lu.buyer_uid = b.buyer_uid
     WHERE b.status IN ('fulfilled', 'partially_refunded')
       AND (p_event_id IS NULL OR b.event_id = p_event_id)
       AND NOT b.account_gone
       AND b.consent_marketing = 'granted'
       AND coalesce(l.choice, '') <> 'denied'
       AND coalesce(lu.choice, '') <> 'denied'
  ),
  fans AS (
    SELECT f.email, f.user_id AS uid,
           regexp_replace(regexp_replace(coalesce(to_jsonb(u) ->> 'phone', ''), '\D', '', 'g'), '^0+', '') AS phone_digits,
           'fan'::text AS source
      FROM public.exos_fans f
      LEFT JOIN auth.users u ON u.id = f.user_id
      LEFT JOIN by_email l ON l.email = f.email
      LEFT JOIN by_uid lu ON lu.buyer_uid = f.user_id
     WHERE p_event_id IS NULL
       AND f.org_id = p_org_id
       AND f.discarded_at IS NULL
       AND (f.user_id IS NULL OR u.id IS NOT NULL)
       AND (l.choice = 'granted' OR lu.choice = 'granted')
       AND coalesce(l.choice, '') <> 'denied'
       AND coalesce(lu.choice, '') <> 'denied'
  ),
  everyone AS (
    SELECT * FROM buyers UNION ALL SELECT * FROM fans
  ),
  eligible AS (
    SELECT e.email, CASE WHEN e.phone_digits ~ '^[1-9][0-9]{7,14}$' THEN e.phone_digits END AS phone_digits, e.source
      FROM everyone e
     WHERE e.email ~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$'
       AND e.email NOT LIKE 'deleted+%@deleted.invalid'
       -- Unsubscribed from marketing mail: this account, or any account with this email.
       AND NOT EXISTS (SELECT 1 FROM public.exos_mail_prefs mp WHERE mp.user_id = e.uid AND mp.marketing_opt_out)
       AND NOT EXISTS (SELECT 1 FROM auth.users ou
                         JOIN public.exos_mail_prefs mp ON mp.user_id = ou.id AND mp.marketing_opt_out
                        WHERE lower(btrim(ou.email)) = e.email)
       -- Off (or removed from) the org's own list: left out of its ads too.
       AND NOT EXISTS (SELECT 1 FROM public.exos_fans f2
                        WHERE f2.org_id = p_org_id AND f2.email = e.email
                          AND (f2.email_opt_out_at IS NOT NULL OR f2.discarded_at IS NOT NULL))
  ),
  per_email AS (
    SELECT g.email, max(g.phone_digits) AS phone_digits, min(g.source) AS source
      FROM eligible g
     GROUP BY g.email
     ORDER BY g.email
     LIMIT 100000
  )
  SELECT coalesce(jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
           'email', p.email,
           'phone', CASE WHEN p.phone_digits IS NOT NULL THEN '+' || p.phone_digits END,
           'source', p.source,
           'ad_consent', 'granted')) ORDER BY p.email), '[]'::jsonb)
    INTO v_rows
    FROM per_email p;
  v_n := jsonb_array_length(v_rows);

  INSERT INTO public.exos_audience_exports (org_id, event_id, exported_by, row_count)
  VALUES (p_org_id, p_event_id, v_actor, v_n);
  RETURN jsonb_build_object('count', v_n, 'generated_at', now(), 'rows', v_rows);
END $$;
REVOKE ALL ON FUNCTION public.exos_ads_audience_source(uuid, uuid, uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_ads_audience_source(uuid, uuid, uuid) TO service_role;
COMMENT ON FUNCTION public.exos_ads_audience_source(uuid, uuid, uuid) IS
  'Service role (exos-ads): email / phone of the org''s buyers and fans who granted advertising consent (latest choice wins; mail opt-outs, the org list''s opt-outs, discarded and deleted left out), for hashing at once by the audience builder. Logged in exos_audience_exports, 20 a day per org. mig 20261121190500.';

-- ROLLBACK (manual): DROP TRIGGER exos_marketing_conversions_reddit_email ON
-- exos_marketing_conversions; DROP TRIGGER exos_checkout_conversions_x ON
-- exos_checkout_sessions; drop the functions created above; DELETE FROM
-- exos_marketing_conversions WHERE platform = 'x' and restore the six-platform
-- CHECK; re-create _exos_cred_managed / _exos_cred_providers from
-- 20261121162400 (after deleting exos_org_integrations rows for ads_x /
-- ads_meta_api / ads_reddit_api and their Vault secrets).
