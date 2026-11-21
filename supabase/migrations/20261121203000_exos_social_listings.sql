-- ============================================================================
-- Migration 20261121203000 — Exos: social posting and listing APIs, dry run
-- only (Instagram, TikTok, Meetup, LinkedIn, Google Business Profile)
-- ============================================================================
-- Touches:  R: FUNCTION _exos_cred_providers, _exos_cred_managed (CREATE OR
--              REPLACE whole: + ig_publish, tiktok_publish, meetup, linkedin,
--              google_business, all managed)
--           C: FUNCTION exos_social_post_context (authenticated, owner /
--              manager: the event the post kit composes from, whether the
--              org runs its own venue, booleans for which social credentials
--              are connected and a few non-secret facts; never a secret or a
--              credential's ids)
--           R: exos_orgs, exos_events, exos_venues, exos_org_integrations,
--              exos_has_org_role, _exos_discovery_event_json,
--              _exos_ads_connected
-- Pre-reqs: 20261121190500 (the ads phase: the provider lists replaced here,
--           _exos_ads_connected), 20261121162400 (the channel core: the
--           store), 20261029130000 (_exos_discovery_event_json, patched by
--           20261106130000), 20261030100000 (exos_venues), 20261105130000
--           (exos_events.location_mode)
--
-- Operator 2026-11-21: "For the APIs build and keep read only till build is
-- complete". Nothing here sends anything: every post / listing write is a dry
-- run behind the channel core's GatedHttp (_shared/channels/adapters/
-- instagram.ts, tiktok.ts, meetup.ts, linkedin.ts, googleBusiness.ts), and
-- exos-social pins the org's switch off (SOCIAL_WRITES_PINNED_OFF).
--
-- 1. NEW PROVIDERS (managed: the generic Integrations save / remove refuse
--    them; a connect flow per vendor app writes them, none built yet,
--    _shared/social/apps.ts): ig_publish (an Instagram content-publishing
--    token for the org's professional account; config ig_user_id),
--    tiktok_publish (a TikTok user token with video.publish), meetup (a Meetup
--    OAuth token; config group_urlname, pro_network, plan), linkedin (a
--    LinkedIn token for the org's organization page; config organization_id)
--    and google_business (config account_id, location_id, verified_at; the
--    secret is Business Profile's OWN refresh token, from its own sign-in on
--    the Google client with business.manage alone: never the Google Ads
--    connection's, which never carries that scope; _shared/social/apps.ts).
-- 2. THE POST KIT'S READ. exos_social_post_context: owner / manager of the
--    org (42501 otherwise; 22023 for another org's event). The event as the
--    discovery listings read it (_exos_discovery_event_json: the feed columns
--    and the public tiers) plus location_open and capacity; a secret or TBA
--    location loses its venue name and address here, so they can't reach a
--    post. venue_org: the org owns a venue (exos_venues, relationship
--    'owned'; Google Business Profile posts are for venue orgs only).
--    connected: one boolean per social provider, each its own credential
--    only (google_business never counts the Google Ads connection). facts: the Meetup plan word and
--    whether a Pro network is set, whether a LinkedIn organization page is
--    set, the days since the Business Profile was verified. No secret, no
--    account id, no buyer.
--
-- Nothing in an existing function body is text-patched (README rule 4 does
-- not arise): the two provider functions from 20261121190500 are replaced
-- whole, the rest is new. Re-run safe (CREATE OR REPLACE). Prod apply needs
-- operator OK.
-- ============================================================================

-- ===========================================================================
-- 1. The social providers in the store (replacing 20261121190500's two lists)
-- ===========================================================================
CREATE OR REPLACE FUNCTION public._exos_cred_managed(p_provider text)
RETURNS boolean LANGUAGE sql IMMUTABLE
SET search_path = public, pg_temp
AS $$
  SELECT coalesce(p_provider, '') = ANY (ARRAY['eventbrite', 'dice', 'discord', 'lysted',
    'ads_meta', 'ads_tiktok', 'ads_ga4', 'ads_google_ads', 'ads_reddit', 'ads_snap',
    'ads_x', 'ads_meta_api', 'ads_reddit_api',
    'ig_publish', 'tiktok_publish', 'meetup', 'linkedin', 'google_business']::text[])
$$;
GRANT EXECUTE ON FUNCTION public._exos_cred_managed(text) TO authenticated, service_role;
REVOKE ALL ON FUNCTION public._exos_cred_managed(text) FROM PUBLIC, anon;

CREATE OR REPLACE FUNCTION public._exos_cred_providers()
RETURNS text[] LANGUAGE sql IMMUTABLE
SET search_path = public, pg_temp
AS $$
  SELECT public.exos_integration_providers() || ARRAY['eventbrite', 'dice', 'discord', 'lysted',
    'ads_meta', 'ads_tiktok', 'ads_ga4', 'ads_google_ads', 'ads_reddit', 'ads_snap',
    'ads_x', 'ads_meta_api', 'ads_reddit_api',
    'ig_publish', 'tiktok_publish', 'meetup', 'linkedin', 'google_business']::text[]
$$;
GRANT EXECUTE ON FUNCTION public._exos_cred_providers() TO authenticated, service_role;
REVOKE ALL ON FUNCTION public._exos_cred_providers() FROM PUBLIC, anon;

-- ===========================================================================
-- 2. The post kit's read
-- ===========================================================================
CREATE OR REPLACE FUNCTION public.exos_social_post_context(p_org_id uuid, p_event_id uuid)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_org   record;
  v_ev    record;
  v_open  boolean;
  v_json  jsonb;
  v_cfg   jsonb;
  v_meet  jsonb;
  v_li    jsonb;
  v_gbp   jsonb;
  v_days  int;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'exos_social_post_context: sign in first' USING ERRCODE = '42501';
  END IF;
  IF p_org_id IS NULL OR NOT public.exos_has_org_role(p_org_id, ARRAY['owner', 'manager']) THEN
    RAISE EXCEPTION 'exos_social_post_context: owners and managers only' USING ERRCODE = '42501';
  END IF;
  SELECT o.id, o.name INTO v_org FROM public.exos_orgs o WHERE o.id = p_org_id;
  SELECT e.id, e.total_tickets, coalesce(to_jsonb(e) ->> 'location_mode', 'venue_record') AS location_mode INTO v_ev
    FROM public.exos_events e WHERE e.id = p_event_id AND e.org_id = p_org_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'exos_social_post_context: not one of this organization''s events' USING ERRCODE = '22023';
  END IF;
  -- Only where the public sees the venue (not a secret / TBA location).
  v_open := v_ev.location_mode IN ('venue_record', 'unlisted_venue');
  v_json := public._exos_discovery_event_json(p_event_id);
  IF NOT v_open THEN
    v_json := (v_json - 'venue_address') || jsonb_build_object('venue_name', NULL);
  END IF;
  v_json := v_json || jsonb_build_object('location_open', v_open, 'location_mode', v_ev.location_mode,
                                         'capacity', v_ev.total_tickets);

  SELECT i.config INTO v_meet FROM public.exos_org_integrations i WHERE i.org_id = p_org_id AND i.provider = 'meetup';
  SELECT i.config INTO v_li FROM public.exos_org_integrations i WHERE i.org_id = p_org_id AND i.provider = 'linkedin';
  SELECT i.config INTO v_gbp FROM public.exos_org_integrations i WHERE i.org_id = p_org_id AND i.provider = 'google_business';
  v_cfg := coalesce(v_gbp, '{}'::jsonb);
  IF (v_cfg ->> 'verified_at') ~ '^\d{4}-\d{2}-\d{2}' THEN
    BEGIN
      v_days := (current_date - left(v_cfg ->> 'verified_at', 10)::date);
    EXCEPTION WHEN others THEN
      v_days := NULL;
    END;
  END IF;

  RETURN jsonb_build_object(
    'org', jsonb_build_object('id', v_org.id, 'name', v_org.name,
      'venue_org', EXISTS (SELECT 1 FROM public.exos_venues v WHERE v.org_id = p_org_id AND v.relationship = 'owned')),
    'event', v_json,
    'connected', jsonb_build_object(
      'ig_publish', public._exos_ads_connected(p_org_id, 'ig_publish'),
      'tiktok_publish', public._exos_ads_connected(p_org_id, 'tiktok_publish'),
      'meetup', public._exos_ads_connected(p_org_id, 'meetup'),
      'linkedin', public._exos_ads_connected(p_org_id, 'linkedin'),
      'google_business', public._exos_ads_connected(p_org_id, 'google_business')),
    'facts', jsonb_build_object(
      'meetup_plan', CASE WHEN lower(v_meet ->> 'plan') IN ('starter', 'standard', 'pro') THEN lower(v_meet ->> 'plan') END,
      'meetup_pro_network', coalesce(v_meet ->> 'pro_network', '') <> '',
      'linkedin_org_page', coalesce(v_li ->> 'organization_id', '') ~ '^[0-9]{1,20}$',
      'gbp_verified_days', v_days));
END $$;
REVOKE ALL ON FUNCTION public.exos_social_post_context(uuid, uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_social_post_context(uuid, uuid) TO authenticated, service_role;
COMMENT ON FUNCTION public.exos_social_post_context(uuid, uuid) IS
  'Owner / manager: the event the "Post / list this event" kit composes from (a secret / TBA location without its venue), whether the org runs its own venue, booleans for the social credentials and a few non-secret facts. No secret, no account id. mig 20261121203000.';

-- ROLLBACK (manual): DROP FUNCTION public.exos_social_post_context(uuid, uuid);
-- delete exos_org_integrations rows for ig_publish / tiktok_publish / meetup /
-- linkedin / google_business (and their Vault secrets), then re-create
-- _exos_cred_managed / _exos_cred_providers from 20261121190500.
