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
--              consenting fans and buyers, as SHA-256 hashes only; logged in
--              exos_audience_exports, 3 a minute and 20 a day per org)
--           C: FUNCTION exos_ads_credential_meta (service role: a provider's
--              row without decrypting its secret, for the pinned dry run)
--           C: FUNCTION _exos_consent_grant_ok, _exos_audience_daily_gate,
--              _exos_email_trim (no client EXECUTE)
--           W: FUNCTION exos_org_audience_export (1 counted text patch: the
--              same consent rules, the atomic daily cap)
--           W: FUNCTION exos_order_proof_verify (2 counted marker patches)
--              and _exos_proof_mail_code (1): the email code's own guess
--              budget (T3); TABLE exos_order_proofs + email_attempts
--           C: FUNCTION _exos_account_email_verified (T1; no client EXECUTE)
--           W: FUNCTION exos_delete_my_account (1 counted marker patch: the
--              person's fan profiles go, their earlier finished guest
--              orders get the tombstone address)
--           R: exos_checkout_sessions, exos_order_proofs, exos_fans,
--              exos_mail_prefs, auth.users, exos_rate_windows,
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
--    hash (TS twin: normalizeEmailReddit in _shared/hashedIds.ts; both trim
--    ASCII whitespace only, and both refuse an address with ASCII whitespace
--    left inside or with other than exactly one "@", so the two agree:
--    tests/exos/test_ads.sql AD2 and ads_test.ts share the vectors); a Reddit
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
--    order who granted ADVERTISING consent at checkout, plus the org's fans
--    whose latest advertising choice here (by email or account) is granted
--    on an order that wasn't fully refunded; never anyone unsubscribed from
--    marketing mail, off the org's email list, discarded, deleted or
--    banned. Following the org or joining its email list is NOT advertising
--    consent (operator 2026-09-30). Nothing raw leaves Postgres: each row is
--    the SHA-256 hashes the platforms take (em, em_google, em_reddit, ph,
--    ph_digits; the same helpers as the outbox and exos_org_audience_export).
--    More than 100,000 people: the first 100,000 by email, and the answer
--    says truncated with the total. Every call is logged in
--    exos_audience_exports and counts toward the org's 3 a minute and 20 a
--    day, shared with the hashed CSV export. exos_ads_credential_meta: a
--    provider's row with has_secret instead of the secret, so the pinned
--    dry run decrypts nothing.
-- 5. WHOSE CHOICE COUNTS (review of #138, B2; the same in
--    exos_org_audience_export, live on prod). Anyone can start a guest
--    checkout with anyone's email and tick the box, so a "yes" counts only
--    from an order that was paid or issued (fulfilled, partly or fully
--    refunded), with no open or lost dispute (the payouts set: NULL, 'won'
--    or 'warning_closed'), whose email the person proved
--    (_exos_consent_grant_ok, B2'): an email code for that very address, or
--    no proof row and their own account with the same address and a
--    VERIFIED email (_exos_account_email_verified, T1: a Google / Apple
--    sign-in whose provider says the email is verified, or a confirmation
--    mail Supabase sent and the person answered). email_confirmed_at alone
--    isn't proof: with Supabase Auth's "Confirm email" off (prod today),
--    GoTrue sets it at sign-up and sends nothing, so anyone could sign up as
--    your address, buy, and tick "yes"; and an answered mail proves only the
--    address it went to, which an instant email change can swap. So the
--    confirmation branch counts only with the operator setting
--    auth_confirm_email_on = true (default false), set once "Confirm email"
--    (and "Secure email change") are on; until then an email/password
--    account's "yes" doesn't count, a Google / Apple one does. The ticket-release rule (_exos_uid_email_confirmed /
--    _exos_proof_open, mig 20261105100000) reads email_confirmed_at the same
--    way and is NOT changed here: tightening it would make every current
--    account prove before release, which is Julian's call (docs/security.md).
--    An SMS proof (proves a phone, which a stranger can use on your email)
--    and an organizer's correction (proven_via 'organizer') never make a
--    "yes". An SMS send no longer resets the email code's guesses (T3:
--    email_attempts, 5 per email code, counted on every wrong code).
--    Guest orders from before proofs (mig 20261105100000: no proof row, no
--    account) no longer count as a "yes". A banned account is out while
--    banned_until is in the future; once a ban expires the account counts
--    again. A "no" counts from any checkout: it can only take someone
--    out. The latest counted choice per email (and per account) wins; at
--    the same moment a "no" wins (S2). The buyer rows themselves need the
--    same proof. The daily cap is taken under a per-org advisory lock held
--    to commit, so 20 means 20 under any concurrency (S5).
-- 6. ACCOUNT DELETION (B1). exos_delete_my_account now deletes the person's
--    fan profiles (by account, and by their confirmed email) and those
--    profiles' tags, and gives every guest checkout under that confirmed
--    email (pending ones too) the tombstone address, so neither an export
--    nor an audience finds them again. A
--    tombstoned or banned account is never exported.
--
-- Two existing bodies are text-patched (README rule 4: check each patch's
-- search text on prod's bodies first): exos_org_audience_export (one
-- counted patch, its throttle-to-consent block as written in
-- 20260930101000; the org-audit patch of 20261109100000 is elsewhere in the
-- body) and exos_delete_my_account (one counted marker patch before its
-- "Close the login" line, as written in 20260926010000). Two small provider
-- functions from 20261121162400 are replaced whole, the rest is new.
-- Re-run safe (CREATE OR REPLACE, DROP ... IF EXISTS, marker-skipped
-- patches). Prod apply needs operator OK.
-- ============================================================================

-- ===========================================================================
-- 1. Reddit's email hash, on Reddit outbox rows
-- ===========================================================================
-- ASCII whitespace off both ends, lower case: the one trim the Reddit hash
-- and its TS twin share (JS trim() also strips Unicode spaces; this doesn't,
-- and neither does normalizeEmailReddit).
CREATE OR REPLACE FUNCTION public._exos_email_trim(p_email text)
RETURNS text LANGUAGE sql IMMUTABLE
SET search_path TO 'public', 'pg_temp'
AS $$
  SELECT lower(btrim(p_email, E' \t\n\r\x0b\x0c'))
$$;
REVOKE ALL ON FUNCTION public._exos_email_trim(text) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public._exos_email_sha256_reddit(p_email text)
RETURNS text LANGUAGE sql IMMUTABLE
SET search_path TO 'public', 'pg_temp'
AS $$
  SELECT CASE
    WHEN e IS NULL OR e = '' OR e ~ E'[ \t\n\r\x0b\x0c]' OR length(e) - length(replace(e, '@', '')) <> 1 THEN NULL
    WHEN replace(split_part(split_part(e, '@', 1), '+', 1), '.', '') = '' OR split_part(e, '@', 2) = '' THEN NULL
    ELSE encode(extensions.digest(convert_to(
           replace(split_part(split_part(e, '@', 1), '+', 1), '.', '') || '@' || split_part(e, '@', 2),
           'UTF8'), 'sha256'), 'hex') END
    FROM (SELECT public._exos_email_trim(p_email) AS e) t
$$;
REVOKE ALL ON FUNCTION public._exos_email_sha256_reddit(text) FROM PUBLIC, anon, authenticated;
COMMENT ON FUNCTION public._exos_email_sha256_reddit(text) IS
  'SHA-256 hex of an email as Reddit normalizes it (lower case, ASCII whitespace trimmed, local part without its +tag and dots; NULL with whitespace inside or not exactly one @). TS twin: normalizeEmailReddit (_shared/hashedIds.ts). mig 20261121190500.';

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

-- ===========================================================================
-- 5. Whose advertising choice counts, the shared daily cap
-- ===========================================================================
-- May a checkout's "yes" count? Only from an order that was paid or issued
-- (fulfilled, partly or fully refunded), not lost to a dispute, whose email
-- the person themselves proved: a guest can start a checkout with anyone's
-- email (review of #138, B2 / B2'). Proved means exactly one of
--   * an email code: exos_order_proofs proven via 'email_code' for this very
--     address (an SMS proof proves a phone, not the email: anyone can start a
--     checkout with your email and prove their own phone; an organizer's
--     correction ('organizer') proves nothing about either address);
--   * no proof row, and a signed-in account whose email is VERIFIED
--     (_exos_account_email_verified: an OAuth identity whose provider says
--     so, or a confirmation mail sent and answered; email_confirmed_at alone
--     is set at sign-up while "Confirm email" is off), the same address as
--     the checkout's, and not deleted or banned.
-- And no open or lost dispute: dispute_status NULL, 'won' or
-- 'warning_closed', as payouts read it (T2).
-- A guest order from before proofs existed (mig 20261105100000) has no proof
-- row and no account: its "yes" no longer counts (it can't be told apart
-- from a stranger's). A "no" from any checkout still counts (it only ever
-- takes someone out).
-- Is this account's email VERIFIED, not just marked confirmed (review of
-- #138, T1)? True when either
--   * a Google or Apple identity (an allowlist: provider IN ('google',
--     'apple')) carries this address and its provider says email_verified (a
--     JSON boolean or a string 'true'). Not any other provider: with Azure AD
--     the tenant admin sets the mail claim (the nOAuth class of bug), and an
--     SSO provider's claim is the customer IdP's say-so (review of #138, U3).
--     Add a provider here only once its verified flag is shown to be the
--     provider's own; or
--   * Supabase sent a confirmation mail and the person answered it
--     (confirmation_sent_at set, email_confirmed_at at or after it), AND the
--     operator has said Supabase Auth's "Confirm email" is on
--     (exos_platform_settings auth_confirm_email_on = true; default false).
-- With "Confirm email" off GoTrue sets email_confirmed_at at sign-up and
-- sends nothing (confirmation_sent_at stays NULL), so that alone proves
-- nothing. And a mail answered once proves the address it went to, not the
-- account's address now: while "Confirm email" is off an email change is
-- applied at once, with no mail to the new address, so an account that
-- answered a mail for its own address could switch to yours and still pass
-- (security review of ea13aaa). The confirmation branch is trusted only
-- while every email change needs a confirmation too, i.e. "Confirm email"
-- is on (and "Secure email change", which also mails the old address); the
-- operator sets auth_confirm_email_on only then, and unsets it if Confirm
-- email is ever turned off. Until then only a provider-verified identity
-- counts. Columns are read through to_jsonb and auth.identities through a
-- guarded dynamic query, so a Supabase without either still answers (false).
CREATE OR REPLACE FUNCTION public._exos_account_email_verified(p_uid uuid, p_email text)
RETURNS boolean LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_email text := lower(btrim(coalesce(p_email, '')));
  v_u     jsonb;
  v_ok    boolean := false;
BEGIN
  IF p_uid IS NULL OR v_email = '' THEN
    RETURN false;
  END IF;
  SELECT to_jsonb(u) INTO v_u FROM auth.users u WHERE u.id = p_uid;
  IF v_u IS NULL THEN
    RETURN false;
  END IF;
  IF public._exos_setting_bool('auth_confirm_email_on', false)
     AND (v_u ->> 'confirmation_sent_at') IS NOT NULL AND (v_u ->> 'email_confirmed_at') IS NOT NULL
     AND (v_u ->> 'email_confirmed_at')::timestamptz >= (v_u ->> 'confirmation_sent_at')::timestamptz
     AND lower(btrim(coalesce(v_u ->> 'email', ''))) = v_email THEN
    RETURN true;
  END IF;
  IF to_regclass('auth.identities') IS NOT NULL THEN
    EXECUTE $q$
      SELECT EXISTS (
        SELECT 1 FROM auth.identities i
         WHERE i.user_id = $1
           AND coalesce(to_jsonb(i) ->> 'provider', '') IN ('google', 'apple')
           AND lower(btrim(coalesce(to_jsonb(i) -> 'identity_data' ->> 'email', ''))) = $2
           AND lower(coalesce(to_jsonb(i) -> 'identity_data' ->> 'email_verified', 'false')) = 'true')
    $q$ INTO v_ok USING p_uid, v_email;
  END IF;
  RETURN coalesce(v_ok, false);
END $$;
REVOKE ALL ON FUNCTION public._exos_account_email_verified(uuid, text) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public._exos_consent_grant_ok(p_status text, p_session_id text)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT coalesce(p_status, '') IN ('fulfilled', 'partially_refunded', 'refunded')
     AND EXISTS (
       SELECT 1
         FROM public.exos_checkout_sessions s
         LEFT JOIN public.exos_order_proofs p ON p.session_id = s.session_id
         LEFT JOIN auth.users u ON u.id = s.buyer_uid
        WHERE s.session_id = p_session_id
          AND (s.dispute_status IS NULL OR s.dispute_status IN ('won', 'warning_closed'))
          AND (
                (p.id IS NOT NULL AND p.status = 'proven' AND p.proven_via = 'email_code'
                 AND p.email = lower(btrim(s.buyer_email)))
             OR (p.id IS NULL AND u.id IS NOT NULL
                 AND public._exos_account_email_verified(u.id, u.email)
                 AND u.email NOT LIKE 'deleted+%'
                 AND (to_jsonb(u) ->> 'deleted_at') IS NULL
                 AND NOT coalesce((to_jsonb(u) ->> 'banned_until')::timestamptz > now(), false)
                 AND lower(btrim(coalesce(nullif(btrim(s.buyer_email), ''), u.email))) = lower(btrim(u.email)))
              ))
$$;
REVOKE ALL ON FUNCTION public._exos_consent_grant_ok(text, text) FROM PUBLIC, anon, authenticated;

-- 20 audience pulls a day per org (ads and the hashed CSV export together),
-- counted under a per-org advisory lock held to commit: a second caller
-- waits for the first to commit its log row, then counts it.
CREATE OR REPLACE FUNCTION public._exos_audience_daily_gate(p_org_id uuid, p_message text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  PERFORM pg_advisory_xact_lock(hashtextextended('exos_audience_exports:' || p_org_id::text, 0));
  IF (SELECT count(*) FROM public.exos_audience_exports x
       WHERE x.org_id = p_org_id AND x.created_at > now() - interval '1 day') >= 20 THEN
    RAISE EXCEPTION '%', p_message USING ERRCODE = 'P0001';
  END IF;
END $$;
REVOKE ALL ON FUNCTION public._exos_audience_daily_gate(uuid, text) FROM PUBLIC, anon, authenticated;

-- Service role: the people an ad audience may hold, as hashes only.
-- Consenting buyers and fans (section 4 / 5 of the header).
CREATE OR REPLACE FUNCTION public.exos_ads_audience_source(p_org_id uuid, p_event_id uuid DEFAULT NULL, p_actor uuid DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_rows  jsonb;
  v_n     integer;
  v_total integer;
  v_cap   constant integer := 100000;
  v_actor uuid;
BEGIN
  IF p_org_id IS NULL OR NOT EXISTS (SELECT 1 FROM public.exos_orgs o WHERE o.id = p_org_id) THEN
    RAISE EXCEPTION 'exos_ads_audience_source: unknown organization' USING ERRCODE = '22023';
  END IF;
  IF p_event_id IS NOT NULL
     AND NOT EXISTS (SELECT 1 FROM public.exos_events e WHERE e.id = p_event_id AND e.org_id = p_org_id) THEN
    RAISE EXCEPTION 'exos_ads_audience_source: not one of this organization''s events' USING ERRCODE = '22023';
  END IF;
  -- 3 a minute per org (the export's bucket), then 20 a day (shared, atomic).
  IF NOT public.exos_rate_hit('audience:' || p_org_id::text, 3) THEN
    RAISE EXCEPTION 'exos_ads_audience_source: too many audience pulls, try again in a minute' USING ERRCODE = 'P0001';
  END IF;
  PERFORM public._exos_audience_daily_gate(p_org_id, 'exos_ads_audience_source: daily audience limit reached (20 per organization)');
  SELECT u.id INTO v_actor FROM auth.users u WHERE u.id = p_actor;

  WITH sess AS (
    SELECT s.session_id, s.event_id, s.buyer_uid, s.status, s.consent_marketing, s.created_at,
           lower(btrim(coalesce(nullif(btrim(s.buyer_email), ''), u.email))) AS email,
           regexp_replace(regexp_replace(coalesce(to_jsonb(u) ->> 'phone', ''), '\D', '', 'g'), '^0+', '') AS phone_digits,
           -- Gone, tombstoned (exos_delete_my_account) or banned.
           (s.buyer_uid IS NOT NULL AND (u.id IS NULL OR u.email LIKE 'deleted+%'
              OR (to_jsonb(u) ->> 'deleted_at') IS NOT NULL
              OR coalesce((to_jsonb(u) ->> 'banned_until')::timestamptz > now(), false))) AS account_gone,
           public._exos_consent_grant_ok(s.status, s.session_id) AS trusted
      FROM public.exos_checkout_sessions s
      LEFT JOIN auth.users u ON u.id = s.buyer_uid
     WHERE s.org_id = p_org_id
  ),
  -- The choices that count: a "no" from any checkout, a "yes" only from a
  -- trusted one. live: that "yes" came with an order not fully refunded.
  counted AS (
    SELECT x.*, (x.consent_marketing = 'granted' AND x.status <> 'refunded') AS live
      FROM sess x
     WHERE x.consent_marketing = 'denied' OR (x.consent_marketing = 'granted' AND x.trusted)
  ),
  -- The latest counted choice at this org's checkouts, by email and by
  -- account; at the same moment a "no" wins.
  by_email AS (
    SELECT DISTINCT ON (x.email) x.email, x.consent_marketing AS choice,
           bool_or(x.live) OVER (PARTITION BY x.email) AS any_live
      FROM counted x
     WHERE x.email IS NOT NULL
     ORDER BY x.email, x.created_at DESC, (x.consent_marketing = 'denied') DESC, x.session_id DESC
  ),
  by_uid AS (
    SELECT DISTINCT ON (x.buyer_uid) x.buyer_uid, x.consent_marketing AS choice,
           bool_or(x.live) OVER (PARTITION BY x.buyer_uid) AS any_live
      FROM counted x
     WHERE x.buyer_uid IS NOT NULL
     ORDER BY x.buyer_uid, x.created_at DESC, (x.consent_marketing = 'denied') DESC, x.session_id DESC
  ),
  buyers AS (
    SELECT b.email, b.buyer_uid AS uid, b.phone_digits, 'buyer'::text AS source
      FROM sess b
      LEFT JOIN by_email l ON l.email = b.email
      LEFT JOIN by_uid lu ON lu.buyer_uid = b.buyer_uid
     WHERE b.status IN ('fulfilled', 'partially_refunded')
       AND b.trusted
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
       AND (f.user_id IS NULL
            OR (u.id IS NOT NULL AND u.email NOT LIKE 'deleted+%'
                AND (to_jsonb(u) ->> 'deleted_at') IS NULL
                AND NOT coalesce((to_jsonb(u) ->> 'banned_until')::timestamptz > now(), false)))
       -- A "yes" that came with an order still standing (S1: a fully
       -- refunded buyer's automatic fan row doesn't bring them back).
       AND ((l.choice = 'granted' AND l.any_live) OR (lu.choice = 'granted' AND lu.any_live))
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
  )
  -- Only hashes leave: the platforms' forms (hashedIds.ts names them), from
  -- the same SQL helpers as the outbox and exos_org_audience_export.
  SELECT (SELECT count(*) FROM per_email),
         (SELECT coalesce(jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
           'em', public._exos_email_sha256(p.email),
           'em_google', public._exos_email_sha256_google(p.email),
           'em_reddit', public._exos_email_sha256_reddit(p.email),
           'ph', CASE WHEN p.phone_digits IS NOT NULL THEN encode(extensions.digest(convert_to('+' || p.phone_digits, 'UTF8'), 'sha256'), 'hex') END,
           'ph_digits', CASE WHEN p.phone_digits IS NOT NULL THEN encode(extensions.digest(convert_to(p.phone_digits, 'UTF8'), 'sha256'), 'hex') END,
           'source', p.source,
           'ad_consent', 'granted')) ORDER BY p.email), '[]'::jsonb)
            FROM (SELECT * FROM per_email ORDER BY email LIMIT v_cap) p)
    INTO v_total, v_rows;
  v_n := jsonb_array_length(v_rows);

  INSERT INTO public.exos_audience_exports (org_id, event_id, exported_by, row_count)
  VALUES (p_org_id, p_event_id, v_actor, v_n);
  -- truncated: more people than one pull carries (v_cap); total says how many.
  RETURN jsonb_build_object('count', v_n, 'total', v_total, 'truncated', v_total > v_n,
                            'generated_at', now(), 'rows', v_rows);
END $$;
REVOKE ALL ON FUNCTION public.exos_ads_audience_source(uuid, uuid, uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_ads_audience_source(uuid, uuid, uuid) TO service_role;
COMMENT ON FUNCTION public.exos_ads_audience_source(uuid, uuid, uuid) IS
  'Service role (exos-ads): SHA-256 hashes (em, em_google, em_reddit, ph, ph_digits) of the org''s buyers and fans who granted advertising consent on a paid / issued order with a proven (or no) email proof (latest counted choice wins, a "no" from any checkout; mail opt-outs, the org list''s opt-outs, discarded, deleted and banned left out). No raw email or phone. Logged in exos_audience_exports; 3 a minute and 20 a day per org, shared with exos_org_audience_export. mig 20261121190500.';

-- Service role: a provider's row as exos_integration_secret gives it, but
-- with has_secret instead of the secret (nothing is decrypted). The pinned
-- dry run (exos-ads, ADS_WRITES_PINNED_OFF) plans from this.
CREATE OR REPLACE FUNCTION public.exos_ads_credential_meta(p_org_id uuid, p_provider text)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  i public.exos_org_integrations%ROWTYPE;
  c record;
BEGIN
  IF p_org_id IS NULL OR p_provider IS NULL OR p_provider NOT LIKE 'ads\_%' OR NOT (p_provider = ANY (public._exos_cred_providers())) THEN
    RETURN NULL;
  END IF;
  SELECT * INTO i FROM public.exos_org_integrations x WHERE x.org_id = p_org_id AND x.provider = p_provider;
  IF FOUND THEN
    IF i.status = 'disabled' THEN
      RETURN NULL;
    END IF;
    IF i.secret_id IS NOT NULL THEN
      RETURN jsonb_build_object('provider', i.provider, 'status', i.status, 'config', i.config,
                                'has_secret', true, 'writes_enabled', i.writes_enabled,
                                'account_name', i.account_name, 'source', 'store');
    END IF;
  END IF;
  SELECT * INTO c FROM public.exos_org_ad_credentials a
   WHERE a.org_id = p_org_id AND a.platform = substr(p_provider, 5) AND a.secret_id IS NOT NULL;
  IF NOT FOUND THEN
    RETURN NULL;
  END IF;
  RETURN jsonb_build_object('provider', p_provider, 'status', CASE WHEN c.enabled THEN 'connected' ELSE 'unverified' END,
                            'config', c.config || jsonb_strip_nulls(jsonb_build_object('test_event_code', c.test_event_code)),
                            'has_secret', true, 'writes_enabled', c.enabled, 'account_name', NULL,
                            'source', 'legacy:exos_org_ad_credentials');
END $$;
REVOKE ALL ON FUNCTION public.exos_ads_credential_meta(uuid, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_ads_credential_meta(uuid, text) TO service_role;

-- ===========================================================================
-- 6. The live export and account deletion (counted patches, rule 4)
-- ===========================================================================
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

-- exos_org_audience_export: the daily cap under the shared lock, and the
-- same rules for whose "yes" counts (B2, S2), tombstoned / banned accounts
-- out (B1). Its throttle-to-consent block, as written in 20260930101000.
SELECT pg_temp.exos_patch_n('public.exos_org_audience_export(uuid,uuid)',
  'exos: audience consent (mig 20261121190500)',
$o$  IF (SELECT count(*) FROM public.exos_audience_exports x
       WHERE x.org_id = p_org_id AND x.created_at > now() - interval '1 day') >= 20 THEN
    RAISE EXCEPTION 'exos_org_audience_export: daily export limit reached (20 per organization)' USING ERRCODE = 'P0001';
  END IF;

  WITH sess AS (
    -- Every checkout of this org, with the email it belongs to (normalized).
    SELECT s.session_id, s.event_id, s.buyer_uid, s.status, s.consent_marketing, s.created_at,
           lower(btrim(coalesce(nullif(btrim(s.buyer_email), ''), u.email))) AS email,
           -- auth.users.phone (Supabase stores the digits with the country code).
           regexp_replace(regexp_replace(coalesce(to_jsonb(u) ->> 'phone', ''), '\D', '', 'g'), '^0+', '') AS phone_digits,
           (s.buyer_uid IS NOT NULL AND u.id IS NULL) AS account_gone
      FROM public.exos_checkout_sessions s
      LEFT JOIN auth.users u ON u.id = s.buyer_uid
     WHERE s.org_id = p_org_id
  ),
  latest AS (
    -- The most recent consent choice per email at this org's checkouts.
    SELECT DISTINCT ON (x.email) x.email, x.consent_marketing AS choice
      FROM sess x
     WHERE x.email IS NOT NULL AND x.consent_marketing IN ('granted', 'denied')
     ORDER BY x.email, x.created_at DESC, x.session_id DESC
  ),
  eligible AS (
    SELECT b.email,
           CASE WHEN b.phone_digits ~ '^[1-9][0-9]{7,14}$' THEN b.phone_digits END AS phone_digits
      FROM sess b
      LEFT JOIN latest l ON l.email = b.email
     WHERE b.status IN ('fulfilled', 'partially_refunded')
       AND (p_event_id IS NULL OR b.event_id = p_event_id)
       AND NOT b.account_gone
       AND b.email ~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$'
       AND b.email NOT LIKE 'deleted+%@deleted.invalid'
       -- Advertising consent at checkout; never when the latest choice was "no".
       AND coalesce(l.choice, '') <> 'denied'
       AND b.consent_marketing = 'granted'
$o$,
$n$  /* exos: audience consent (mig 20261121190500) */ -- 20 a day, under the
  -- per-org lock shared with exos_ads_audience_source (atomic).
  PERFORM public._exos_audience_daily_gate(p_org_id, 'exos_org_audience_export: daily export limit reached (20 per organization)');

  WITH sess AS (
    -- Every checkout of this org, with the email it belongs to (normalized).
    SELECT s.session_id, s.event_id, s.buyer_uid, s.status, s.consent_marketing, s.created_at,
           lower(btrim(coalesce(nullif(btrim(s.buyer_email), ''), u.email))) AS email,
           -- auth.users.phone (Supabase stores the digits with the country code).
           regexp_replace(regexp_replace(coalesce(to_jsonb(u) ->> 'phone', ''), '\D', '', 'g'), '^0+', '') AS phone_digits,
           -- Gone, tombstoned (exos_delete_my_account) or banned.
           (s.buyer_uid IS NOT NULL AND (u.id IS NULL OR u.email LIKE 'deleted+%'
              OR (to_jsonb(u) ->> 'deleted_at') IS NOT NULL
              OR coalesce((to_jsonb(u) ->> 'banned_until')::timestamptz > now(), false))) AS account_gone,
           -- A "yes" counts only from a paid / issued order whose email the person proved
           -- (an email code, or their own confirmed account): _exos_consent_grant_ok.
           public._exos_consent_grant_ok(s.status, s.session_id) AS trusted
      FROM public.exos_checkout_sessions s
      LEFT JOIN auth.users u ON u.id = s.buyer_uid
     WHERE s.org_id = p_org_id
  ),
  latest AS (
    -- The most recent counted choice per email: a "no" from any checkout, a
    -- "yes" only from a trusted one; at the same moment a "no" wins.
    SELECT DISTINCT ON (x.email) x.email, x.consent_marketing AS choice
      FROM sess x
     WHERE x.email IS NOT NULL
       AND (x.consent_marketing = 'denied' OR (x.consent_marketing = 'granted' AND x.trusted))
     ORDER BY x.email, x.created_at DESC, (x.consent_marketing = 'denied') DESC, x.session_id DESC
  ),
  eligible AS (
    SELECT b.email,
           CASE WHEN b.phone_digits ~ '^[1-9][0-9]{7,14}$' THEN b.phone_digits END AS phone_digits
      FROM sess b
      LEFT JOIN latest l ON l.email = b.email
     WHERE b.status IN ('fulfilled', 'partially_refunded')
       AND b.trusted
       AND (p_event_id IS NULL OR b.event_id = p_event_id)
       AND NOT b.account_gone
       AND b.email ~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$'
       AND b.email NOT LIKE 'deleted+%@deleted.invalid'
       -- Advertising consent at checkout; never when the latest choice was "no".
       AND coalesce(l.choice, '') <> 'denied'
       AND b.consent_marketing = 'granted'
$n$, 1);

-- exos_delete_my_account: the person's fan profiles go (by account, and by
-- the confirmed email), and their earlier finished guest checkouts under that
-- confirmed email get the tombstone address, so no export or audience finds
-- them again.
SELECT pg_temp.exos_patch_n('public.exos_delete_my_account()',
  'exos: fans and guest orders (mig 20261121190500)',
$o$  -- Close the login for good (the row stays so order history keeps its keys).
$o$,
$n$  /* exos: fans and guest orders (mig 20261121190500) */ -- fan profiles
  -- are personal data (signup answers cascade with them; their tags go too,
  -- as _exos_fan_discard does); every guest checkout under the confirmed
  -- email gets the tombstone address (a guest row must keep an address;
  -- exports skip the tombstone), pending ones included: one paid after this
  -- still reaches its buyer through the paying page (phone proof) or the
  -- organizer's resend to a corrected address.
  DELETE FROM public.exos_tagged_items t
   USING public.exos_fans f
   WHERE t.taggable_type = 'fan' AND t.taggable_id = f.id AND t.org_id = f.org_id
     AND (f.user_id = v_uid OR (v_email IS NOT NULL AND v_email <> '' AND lower(btrim(f.email)) = v_email));
  DELETE FROM public.exos_fans
   WHERE user_id = v_uid OR (v_email IS NOT NULL AND v_email <> '' AND lower(btrim(email)) = v_email);
  IF v_email IS NOT NULL AND v_email <> '' THEN
    UPDATE public.exos_checkout_sessions SET buyer_email = v_tomb
     WHERE buyer_uid IS NULL AND lower(btrim(buyer_email)) = v_email;
  END IF;

  -- Close the login for good (the row stays so order history keeps its keys).
$n$, 1);

-- An email code's guesses (review of #138, T3; pre-existing, live): one
-- code box checks the email code and the SMS code, and every wrong code
-- counts on exos_order_proofs.attempts (5, then locked). An SMS send resets
-- attempts to 0 (a new phone code gets its own 5), and that also reopened
-- the email code to 5 more guesses, one SMS to the guesser's own phone at a
-- time (about 40 per order). email_attempts counts wrong codes against the
-- email code only: the SMS send leaves it alone, a new email code
-- (_exos_proof_mail_code) starts it again, and at 5 the email code stops
-- matching, so only the phone code (with its own budget) can still prove.
ALTER TABLE public.exos_order_proofs ADD COLUMN IF NOT EXISTS email_attempts integer NOT NULL DEFAULT 0;
SELECT pg_temp.exos_patch_n('public.exos_order_proof_verify(text,text,text)',
  'exos: email code budget, check (mig 20261121190500)',
$o$  IF p.email_code_hash IS NOT NULL AND p.email_code_hash = public._exos_proof_hash(p.id, 'email', v_code) THEN$o$,
$n$  IF p.email_code_hash IS NOT NULL AND coalesce(p.email_attempts, 0) < 5 /* exos: email code budget, check (mig 20261121190500) */
     AND p.email_code_hash = public._exos_proof_hash(p.id, 'email', v_code) THEN$n$, 1);
SELECT pg_temp.exos_patch_n('public.exos_order_proof_verify(text,text,text)',
  'exos: email code budget, count (mig 20261121190500)',
$o$    UPDATE public.exos_order_proofs SET attempts = attempts + 1 WHERE id = p.id;$o$,
$n$    UPDATE public.exos_order_proofs
       SET attempts = attempts + 1,
           email_attempts = email_attempts + 1 /* exos: email code budget, count (mig 20261121190500) */
     WHERE id = p.id;$n$, 1);
SELECT pg_temp.exos_patch_n('public._exos_proof_mail_code(uuid)',
  'exos: email code budget, new code (mig 20261121190500)',
$o$         email_sends = email_sends + 1, attempts = 0, last_sent_at = now()$o$,
$n$         email_sends = email_sends + 1, attempts = 0, last_sent_at = now(),
         email_attempts = 0 /* exos: email code budget, new code (mig 20261121190500) */$n$, 1);

-- ROLLBACK (manual): restore exos_org_audience_export, exos_delete_my_account,
-- exos_order_proof_verify and _exos_proof_mail_code from their
-- pg_get_functiondef taken before the apply (the last two: 20261105100000;
-- exos_order_proofs.email_attempts can stay) (or 20260930101000 +
-- 20261109100000's audit patch, and the deletion body's latest migrations);
-- DROP TRIGGER exos_marketing_conversions_reddit_email ON
-- exos_marketing_conversions; DROP TRIGGER exos_checkout_conversions_x ON
-- exos_checkout_sessions; drop the functions created above; DELETE FROM
-- exos_marketing_conversions WHERE platform = 'x' and restore the six-platform
-- CHECK; re-create _exos_cred_managed / _exos_cred_providers from
-- 20261121162400 (after deleting exos_org_integrations rows for ads_x /
-- ads_meta_api / ads_reddit_api and their Vault secrets).
