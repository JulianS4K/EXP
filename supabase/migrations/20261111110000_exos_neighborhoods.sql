-- ============================================================================
-- Migration 20261111110000 — Exos: neighborhood pages ("this week in
--   Bushwick", Phase 1 item 7c) and followers (Phase 1 CRM): the "new event"
--   email to an org's followers, and the follower list for organizers.
--   docs/google-events.md "Neighborhood pages", docs/fans.md "Followers".
--
-- Branch:   claude/exos-neighborhoods
-- Touches:  C: TABLE exos_neighborhoods (reference data, no org: a center
--              point + radius per neighborhood, seeded for NYC; anon /
--              authenticated read the active rows; no client writes)
--           C: FUNCTION exos_geo_distance_m (pure math),
--              _exos_neighborhood_of (service role),
--              _exos_neighborhood_rate_ok (service role),
--              exos_neighborhoods_list, exos_neighborhood_page (anon +
--              authenticated: published, listed, upcoming events only; the
--              "no coordinates" count only for platform admins; 120 a minute
--              per network)
--           C: TABLE exos_follower_notices (one row per event + follower: the
--              idempotency gate), exos_follower_mail_slots (one row per org +
--              follower: the 24-hour limit), exos_follow_tokens (the one-click
--              unfollow link); RLS on, service role only
--           C: FUNCTION _exos_follower_skip_reason, _exos_follower_event_ok,
--              _exos_follower_flush, _exos_follower_notices_on_publish,
--              _exos_tg_follower_new_event (service role / trigger),
--              exos_send_follower_digests (service role; cron
--              exos-follower-digests-hourly, created INACTIVE)
--           C: FUNCTION exos_event_follower_notice (authenticated: owner /
--              manager), exos_org_followers, exos_org_followers_export
--              (authenticated: owner / manager; the export is rate limited
--              and logs export.run), exos_unfollow_by_token (anon +
--              authenticated: 64-hex token)
--           C: TRIGGER exos_events_follower_notices (AFTER INSERT / UPDATE OF
--              status, noindex on exos_events)
--           W: FUNCTION exos_announce_to_followers (redefined: the same
--              owner / manager check, now through the consent-gated,
--              once-per-event-and-follower path; it used to mail every
--              follower with no opt-out check, no unsubscribe link and no
--              dedupe). No other migration patches it.
--           W: TABLE exos_mail (template allowlist + follower-new-event,
--              union pattern)
-- Pre-reqs: 20260520140000 (follows), 20260924230000 (event geo; its public
--           view is wrapped by 20261105130000 to drop secret / tba pins),
--           20260929071000 (exos_mail_enqueue), 20261030150000
--           (_exos_public_event_json), 20261031120000 (exos_fans),
--           20261109100000 (_exos_audit).
--
-- Neighborhoods. No PostGIS in this project (none of the 300+ migrations
-- uses it, and the harness has none): each neighborhood is a center and a
-- radius, compared with a haversine distance in plain SQL. An event belongs
-- to the NEAREST neighborhood whose circle holds its venue, so overlapping
-- circles never list one event twice. Coordinates are the geocoded venue
-- pins the map already uses (exos_public_event_geo: published events, fresh
-- pins only, never a secret_location or tba event). Listed = what public
-- discovery lists: published and not noindex ("hidden from search"). An
-- event without a pin can't be placed: it's left out, and the page tells a
-- platform admin how many there are in the city's time zone.
--
-- Followers. When an event goes live (published and listed, starting in the
-- future; a series announces its first date only), each follower of the org
-- gets one notice row. A notice turns into mail only if the follower may get
-- marketing mail: they still follow, they aren't on the org's team, their
-- account has an email, they haven't opted out of Exos follow-up mail
-- (exos_mail_prefs, the one switch docs/email.md describes), and they haven't
-- unsubscribed from this org's list (exos_fans). At most one such mail per
-- follower per org per 24 hours: a second event inside the window waits as a
-- pending notice and goes out with the next one, batched (the next publish
-- after the window, or exos_send_follower_digests). The mail is a payload
-- row (template follower-new-event, marketing: the global unsubscribe link
-- and List-Unsubscribe header come from exos_mail_enqueue) and carries a
-- one-click unfollow link (/unfollow?t=<64 hex>). It stays queued like every
-- other mail until the drain is deployed with Resend. Republishing never
-- re-sends: the notice row's key is (event, follower).
--
-- The organizer sees counts only: "N followers will be notified" before
-- publishing and "notified N followers" after (exos_event_follower_notice).
-- The follower list (owner / manager) shows only followers the org already
-- sees as fans (a fan profile linked to the follower's account), as the
-- Fans tab would; the rest are a count. Export logs export.run.
--
-- Additive, replay-safe (IF NOT EXISTS, CREATE OR REPLACE, ON CONFLICT, the
-- allowlist union). Not applied. Prod apply needs operator OK.
-- ROLLBACK: DROP TRIGGER exos_events_follower_notices ON exos_events; the
-- functions above; the four tables; cron.unschedule
-- ('exos-follower-digests-hourly'); re-run 20260523200000's
-- exos_announce_to_followers. The allowlist value can stay.
-- ============================================================================

-- ===========================================================================
-- 1. Neighborhoods
-- ===========================================================================
CREATE TABLE IF NOT EXISTS public.exos_neighborhoods (
  slug        text PRIMARY KEY CHECK (slug ~ '^[a-z0-9]+(-[a-z0-9]+)*$' AND char_length(slug) <= 60),
  city        text NOT NULL DEFAULT 'nyc' CHECK (city ~ '^[a-z0-9-]{2,30}$'),
  name        text NOT NULL CHECK (char_length(btrim(name)) BETWEEN 1 AND 60),
  borough     text CHECK (borough IS NULL OR char_length(borough) <= 40),
  center_lat  double precision NOT NULL CHECK (center_lat BETWEEN -90 AND 90),
  center_lng  double precision NOT NULL CHECK (center_lng BETWEEN -180 AND 180),
  radius_m    integer NOT NULL CHECK (radius_m BETWEEN 100 AND 10000),
  timezone    text NOT NULL DEFAULT 'America/New_York' CHECK (char_length(timezone) <= 60),
  sort_order  integer NOT NULL DEFAULT 0,
  active      boolean NOT NULL DEFAULT true,
  created_at  timestamptz NOT NULL DEFAULT now(),
  updated_at  timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS exos_neighborhoods_city_idx ON public.exos_neighborhoods (city, sort_order) WHERE active;
COMMENT ON TABLE public.exos_neighborhoods IS
  'mig 20261111110000: neighborhood pages (/nyc/:slug). Reference data, no org: a center + radius (meters). An event belongs to the nearest active neighborhood whose circle holds its geocoded venue. Edited by the operator (service role); the public reads active rows.';
ALTER TABLE public.exos_neighborhoods ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.exos_neighborhoods FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.exos_neighborhoods TO anon, authenticated;
GRANT ALL ON public.exos_neighborhoods TO service_role;
DROP POLICY IF EXISTS exos_neighborhoods_sel ON public.exos_neighborhoods;
CREATE POLICY exos_neighborhoods_sel ON public.exos_neighborhoods FOR SELECT TO anon, authenticated USING (active);
DROP TRIGGER IF EXISTS exos_neighborhoods_touch ON public.exos_neighborhoods;
CREATE TRIGGER exos_neighborhoods_touch BEFORE UPDATE ON public.exos_neighborhoods
  FOR EACH ROW EXECUTE FUNCTION public.exos_touch_updated_at();

-- Approximate centers; the radius covers the neighborhood's core. Where
-- circles overlap (Bushwick / Ridgewood / Bed-Stuy, LES / East Village) the
-- nearest center wins. A re-run leaves rows the operator edited alone.
INSERT INTO public.exos_neighborhoods (slug, city, name, borough, center_lat, center_lng, radius_m, sort_order) VALUES
  ('bushwick',         'nyc', 'Bushwick',         'Brooklyn',  40.6990, -73.9200, 1800, 10),
  ('williamsburg',     'nyc', 'Williamsburg',     'Brooklyn',  40.7128, -73.9570, 1500, 20),
  ('greenpoint',       'nyc', 'Greenpoint',       'Brooklyn',  40.7290, -73.9510, 1100, 30),
  ('ridgewood',        'nyc', 'Ridgewood',        'Queens',    40.7040, -73.9030, 1200, 40),
  ('lower-east-side',  'nyc', 'Lower East Side',  'Manhattan', 40.7155, -73.9860,  900, 50),
  ('east-village',     'nyc', 'East Village',     'Manhattan', 40.7270, -73.9830,  900, 60),
  ('harlem',           'nyc', 'Harlem',           'Manhattan', 40.8100, -73.9460, 1600, 70),
  ('crown-heights',    'nyc', 'Crown Heights',    'Brooklyn',  40.6700, -73.9440, 1400, 80),
  ('bed-stuy',         'nyc', 'Bed-Stuy',         'Brooklyn',  40.6870, -73.9420, 1400, 90),
  ('astoria',          'nyc', 'Astoria',          'Queens',    40.7640, -73.9230, 1500, 100),
  ('long-island-city', 'nyc', 'Long Island City', 'Queens',    40.7450, -73.9480, 1200, 110),
  ('park-slope',       'nyc', 'Park Slope',       'Brooklyn',  40.6720, -73.9780, 1100, 120),
  ('gowanus',          'nyc', 'Gowanus',          'Brooklyn',  40.6750, -73.9900,  600, 130),
  ('dumbo',            'nyc', 'DUMBO',            'Brooklyn',  40.7030, -73.9890,  500, 140),
  ('west-village',     'nyc', 'West Village',     'Manhattan', 40.7350, -74.0040,  700, 150),
  ('chelsea',          'nyc', 'Chelsea',          'Manhattan', 40.7460, -74.0010,  900, 160),
  ('midtown',          'nyc', 'Midtown',          'Manhattan', 40.7550, -73.9840, 1300, 170),
  ('flatbush',         'nyc', 'Flatbush',         'Brooklyn',  40.6410, -73.9590, 1400, 180),
  ('jackson-heights',  'nyc', 'Jackson Heights',  'Queens',    40.7560, -73.8830, 1100, 190),
  ('mott-haven',       'nyc', 'Mott Haven',       'The Bronx', 40.8090, -73.9230, 1100, 200)
ON CONFLICT (slug) DO NOTHING;

-- Great-circle distance in meters (haversine, mean Earth radius). Must equal
-- distanceMeters in src/lib/neighborhoods.ts (its test checks the same pairs
-- as tests/exos/test_neighborhoods.sql).
CREATE OR REPLACE FUNCTION public.exos_geo_distance_m(p_lat1 double precision, p_lng1 double precision,
                                                      p_lat2 double precision, p_lng2 double precision)
RETURNS double precision LANGUAGE sql IMMUTABLE PARALLEL SAFE
SET search_path = public, pg_temp
AS $$
  SELECT 2 * 6371008.8 * asin(least(1, sqrt(
           power(sin(radians(p_lat2 - p_lat1) / 2), 2)
           + cos(radians(p_lat1)) * cos(radians(p_lat2)) * power(sin(radians(p_lng2 - p_lng1) / 2), 2))))
$$;

-- The neighborhood a point is in: the nearest active one whose circle holds it.
CREATE OR REPLACE FUNCTION public._exos_neighborhood_of(p_lat double precision, p_lng double precision, p_city text DEFAULT 'nyc')
RETURNS text LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT n.slug FROM public.exos_neighborhoods n
   WHERE n.active AND n.city = p_city AND p_lat IS NOT NULL AND p_lng IS NOT NULL
     AND public.exos_geo_distance_m(p_lat, p_lng, n.center_lat, n.center_lng) <= n.radius_m
   ORDER BY public.exos_geo_distance_m(p_lat, p_lng, n.center_lat, n.center_lng), n.slug
   LIMIT 1
$$;
REVOKE ALL ON FUNCTION public._exos_neighborhood_of(double precision, double precision, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_neighborhood_of(double precision, double precision, text) TO service_role;

-- Both public page RPCs: 120 calls a minute per network (the platform-set
-- IP, as exos_api_public), checked before any work; 54000 over it.
CREATE OR REPLACE FUNCTION public._exos_neighborhood_rate_ok()
RETURNS void LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF NOT public.exos_rate_hit('neighborhoods:ip:' || public._exos_request_ip_bucket(), 120) THEN
    RAISE EXCEPTION 'too many requests from this network; try again in a minute' USING ERRCODE = '54000';
  END IF;
END $$;
REVOKE ALL ON FUNCTION public._exos_neighborhood_rate_ok() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_neighborhood_rate_ok() TO service_role;

-- A city's neighborhoods with how many listed events each has in the next
-- p_days (1-14, default 7). Public.
CREATE OR REPLACE FUNCTION public.exos_neighborhoods_list(p_city text DEFAULT 'nyc', p_days integer DEFAULT 7)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE v_out jsonb;
BEGIN
  PERFORM public._exos_neighborhood_rate_ok();
  WITH w AS (
    SELECT lower(btrim(coalesce(p_city, 'nyc'))) AS city,
           now() + make_interval(days => least(greatest(coalesce(p_days, 7), 1), 14)) AS upto
  ), placed AS (
    SELECT public._exos_neighborhood_of(g.lat, g.lng, w.city) AS slug
      FROM w, public.exos_events e
      JOIN public.exos_public_event_geo g ON g.event_id = e.id
     WHERE e.status = 'published' AND NOT coalesce(e.noindex, false)
       AND coalesce(e.ends_at, e.starts_at) >= now() AND e.starts_at < w.upto
  )
  SELECT coalesce(jsonb_agg(jsonb_build_object('slug', n.slug, 'name', n.name, 'borough', n.borough,
                                               'events', (SELECT count(*) FROM placed p WHERE p.slug = n.slug))
                            ORDER BY n.sort_order, n.name), '[]'::jsonb)
    INTO v_out
    FROM w, public.exos_neighborhoods n
   WHERE n.active AND n.city = w.city;
  RETURN v_out;
END $$;
REVOKE ALL ON FUNCTION public.exos_neighborhoods_list(text, integer) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_neighborhoods_list(text, integer) TO anon, authenticated, service_role;

-- One neighborhood's page: its listed events in the next p_days (1-14,
-- default 7), soonest first, at most 100, each as the public event card
-- (_exos_public_event_json) plus the organizer's public name and slug. NULL
-- for an unknown or inactive slug. missing_coordinates (admins only): listed
-- events in the window, in the city's time zone, with no usable pin (secret
-- and tba locations aren't counted: they have no public pin by design).
CREATE OR REPLACE FUNCTION public.exos_neighborhood_page(p_slug text, p_days integer DEFAULT 7)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  n       public.exos_neighborhoods%ROWTYPE;
  v_days  integer := least(greatest(coalesce(p_days, 7), 1), 14);
  v_to    timestamptz := now() + make_interval(days => least(greatest(coalesce(p_days, 7), 1), 14));
  v_evs   jsonb;
  v_out   jsonb;
BEGIN
  PERFORM public._exos_neighborhood_rate_ok();
  SELECT * INTO n FROM public.exos_neighborhoods
   WHERE slug = lower(btrim(coalesce(p_slug, ''))) AND active;
  IF n.slug IS NULL THEN
    RETURN NULL;
  END IF;
  WITH here AS (
    SELECT e.id, e.starts_at, e.org_id
      FROM public.exos_events e
      JOIN public.exos_public_event_geo g ON g.event_id = e.id
     WHERE e.status = 'published' AND NOT coalesce(e.noindex, false)
       AND coalesce(e.ends_at, e.starts_at) >= now() AND e.starts_at < v_to
       AND public._exos_neighborhood_of(g.lat, g.lng, n.city) = n.slug
     ORDER BY e.starts_at, e.id
     LIMIT 100
  )
  SELECT coalesce(jsonb_agg(public._exos_public_event_json(h.id)
                            || jsonb_build_object('org', jsonb_build_object('name', o.name, 'slug', o.slug))
                            ORDER BY h.starts_at, h.id), '[]'::jsonb)
    INTO v_evs
    FROM here h JOIN public.exos_orgs o ON o.id = h.org_id;
  v_out := jsonb_build_object(
    'neighborhood', jsonb_build_object('slug', n.slug, 'name', n.name, 'borough', n.borough, 'city', n.city,
                                       'timezone', n.timezone),
    'days', v_days, 'from', now(), 'to', v_to, 'events', v_evs);
  IF public.exos_is_admin() THEN
    v_out := v_out || jsonb_build_object('missing_coordinates', (
      SELECT count(*) FROM public.exos_events e
       WHERE e.status = 'published' AND NOT coalesce(e.noindex, false)
         AND coalesce(e.ends_at, e.starts_at) >= now() AND e.starts_at < v_to
         AND e.timezone = n.timezone
         AND coalesce(e.location_mode, 'venue_record') NOT IN ('secret_location', 'tba')
         AND coalesce(e.format, 'in_person') <> 'online'
         AND NOT EXISTS (SELECT 1 FROM public.exos_public_event_geo g WHERE g.event_id = e.id)));
  END IF;
  RETURN v_out;
END $$;
REVOKE ALL ON FUNCTION public.exos_neighborhood_page(text, integer) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_neighborhood_page(text, integer) TO anon, authenticated, service_role;

-- ===========================================================================
-- 2. Follower mail: tables
-- ===========================================================================
-- One row per (event, follower): the gate that makes "never twice" hold
-- across republishing, the trigger and the sweep.
CREATE TABLE IF NOT EXISTS public.exos_follower_notices (
  event_id     uuid NOT NULL REFERENCES public.exos_events (id) ON DELETE CASCADE,
  follower_uid uuid NOT NULL REFERENCES auth.users (id) ON DELETE CASCADE,
  org_id       uuid NOT NULL REFERENCES public.exos_orgs (id) ON DELETE CASCADE,
  status       text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'queued', 'skipped')),
  skip_reason  text CHECK (skip_reason IS NULL OR skip_reason IN
                 ('not_following', 'org_staff', 'no_email', 'opted_out', 'org_unsubscribed', 'event_not_listed', 'not_queued')),
  mail_id      uuid,
  created_at   timestamptz NOT NULL DEFAULT now(),
  updated_at   timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (event_id, follower_uid)
);
CREATE INDEX IF NOT EXISTS exos_follower_notices_pending_idx
  ON public.exos_follower_notices (org_id, follower_uid) WHERE status = 'pending';
COMMENT ON TABLE public.exos_follower_notices IS
  'mig 20261111110000: one "new event" notice per event + follower (the never-twice gate). pending = waiting for the 24-hour window; queued = in exos_mail (mail_id); skipped = no consent / not listed (skip_reason). Service role only; organizers see counts (exos_event_follower_notice).';
ALTER TABLE public.exos_follower_notices ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.exos_follower_notices FROM PUBLIC, anon, authenticated;
GRANT ALL ON public.exos_follower_notices TO service_role;
DROP TRIGGER IF EXISTS exos_follower_notices_touch ON public.exos_follower_notices;
CREATE TRIGGER exos_follower_notices_touch BEFORE UPDATE ON public.exos_follower_notices
  FOR EACH ROW EXECUTE FUNCTION public.exos_touch_updated_at();

-- One row per (org, follower): when the last "new event" mail was queued.
CREATE TABLE IF NOT EXISTS public.exos_follower_mail_slots (
  org_id       uuid NOT NULL REFERENCES public.exos_orgs (id) ON DELETE CASCADE,
  follower_uid uuid NOT NULL REFERENCES auth.users (id) ON DELETE CASCADE,
  last_mail_at timestamptz NOT NULL,
  PRIMARY KEY (org_id, follower_uid)
);
COMMENT ON TABLE public.exos_follower_mail_slots IS
  'mig 20261111110000: at most one follower-new-event mail per org + follower per 24 hours. Service role only.';
ALTER TABLE public.exos_follower_mail_slots ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.exos_follower_mail_slots FROM PUBLIC, anon, authenticated;
GRANT ALL ON public.exos_follower_mail_slots TO service_role;

-- The unfollow link's token, one per (org, follower), made when the first
-- mail is queued. Kept after an unfollow so an old link still answers.
CREATE TABLE IF NOT EXISTS public.exos_follow_tokens (
  org_id       uuid NOT NULL REFERENCES public.exos_orgs (id) ON DELETE CASCADE,
  follower_uid uuid NOT NULL REFERENCES auth.users (id) ON DELETE CASCADE,
  token        text NOT NULL UNIQUE
                 DEFAULT replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', '')
                 CHECK (token ~ '^[0-9a-f]{64}$'),
  created_at   timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (org_id, follower_uid)
);
COMMENT ON TABLE public.exos_follow_tokens IS
  'mig 20261111110000: the one-click unfollow token in follower-new-event mail (/unfollow?t=). Service role only.';
ALTER TABLE public.exos_follow_tokens ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.exos_follow_tokens FROM PUBLIC, anon, authenticated;
GRANT ALL ON public.exos_follow_tokens TO service_role;

DO $$
DECLARE r text; t text;
BEGIN
  FOREACH r IN ARRAY ARRAY['coworker_readonly', 'analyst_ro'] LOOP
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = r) THEN
      FOREACH t IN ARRAY ARRAY['exos_follower_notices', 'exos_follower_mail_slots', 'exos_follow_tokens'] LOOP
        EXECUTE format('REVOKE ALL ON public.%I FROM %I', t, r);
      END LOOP;
    END IF;
  END LOOP;
END $$;

-- Template allowlist: live list ∪ the new value (never rebuilt from scratch).
DO $$
DECLARE
  v_def  text;
  v_live text[];
  v_new  text[] := ARRAY['follower-new-event'];
  v_vals text[];
BEGIN
  SELECT pg_get_constraintdef(c.oid) INTO v_def
    FROM pg_constraint c
   WHERE c.conrelid = 'public.exos_mail'::regclass AND c.conname = 'exos_mail_template_check';
  IF v_def IS NULL THEN RETURN; END IF;
  IF strpos(v_def, '''{') > 0 THEN
    v_live := string_to_array(substring(v_def FROM '''\{([^}]*)\}'''), ',');
  ELSE
    SELECT array_agg(m[1]) INTO v_live FROM regexp_matches(v_def, '''([^'']+)''', 'g') AS m;
  END IF;
  IF v_new <@ coalesce(v_live, '{}'::text[]) THEN RETURN; END IF;
  SELECT array_agg(DISTINCT x ORDER BY x) INTO v_vals FROM (
    SELECT btrim(unnest(coalesce(v_live, '{}'::text[])), ' "') AS x
    UNION SELECT unnest(v_new)) u WHERE x <> '';
  ALTER TABLE public.exos_mail DROP CONSTRAINT IF EXISTS exos_mail_template_check;
  EXECUTE format('ALTER TABLE public.exos_mail ADD CONSTRAINT exos_mail_template_check '
                 'CHECK (template = ANY (ARRAY[%s]))',
                 (SELECT string_agg(quote_literal(x), ',' ORDER BY x) FROM unnest(v_vals) x));
END $$;

-- ===========================================================================
-- 3. Follower mail: the rules
-- ===========================================================================
-- Why this follower gets no "new event" mail from this org, or NULL when
-- they may. The same consent rules as every follow-up (docs/email.md: an
-- account, not opted out) plus this org's own list (docs/fans.md).
CREATE OR REPLACE FUNCTION public._exos_follower_skip_reason(p_org uuid, p_uid uuid)
RETURNS text LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT CASE
    WHEN NOT EXISTS (SELECT 1 FROM public.exos_org_follows f WHERE f.org_id = p_org AND f.follower_uid = p_uid)
      THEN 'not_following'
    WHEN p_uid = (SELECT o.owner_uid FROM public.exos_orgs o WHERE o.id = p_org)
      OR EXISTS (SELECT 1 FROM public.exos_org_memberships m
                  WHERE m.org_id = p_org AND m.user_id = p_uid AND m.disabled IS NOT TRUE)
      THEN 'org_staff'
    WHEN coalesce((SELECT u.email FROM auth.users u WHERE u.id = p_uid), '') !~ '^[^@[:space:]]+@[^@[:space:]]+$'
      THEN 'no_email'
    WHEN EXISTS (SELECT 1 FROM public.exos_mail_prefs mp WHERE mp.user_id = p_uid AND mp.marketing_opt_out)
      THEN 'opted_out'
    WHEN EXISTS (SELECT 1 FROM public.exos_fans fa
                  WHERE fa.org_id = p_org AND fa.user_id = p_uid AND fa.email_opt_out_at IS NOT NULL)
      THEN 'org_unsubscribed'
  END
$$;
REVOKE ALL ON FUNCTION public._exos_follower_skip_reason(uuid, uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_follower_skip_reason(uuid, uuid) TO service_role;

-- An event worth announcing: live, listed (as discovery lists it) and ahead.
CREATE OR REPLACE FUNCTION public._exos_follower_event_ok(p_event uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT EXISTS (SELECT 1 FROM public.exos_events e
                  WHERE e.id = p_event AND e.status = 'published' AND NOT coalesce(e.noindex, false)
                    AND e.starts_at > now())
$$;
REVOKE ALL ON FUNCTION public._exos_follower_event_ok(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_follower_event_ok(uuid) TO service_role;

-- Turn one follower's pending notices for one org into one mail, if the
-- 24-hour slot is free. Returns the mail id, or NULL (nothing pending, no
-- consent, or still inside the window: the notices stay pending).
-- Race-safe: the pending rows are locked, and the slot is claimed with an
-- upsert whose WHERE refuses a slot used in the last 24 hours, so two
-- publishes at once queue one mail and leave the other event pending.
CREATE OR REPLACE FUNCTION public._exos_follower_flush(p_org uuid, p_uid uuid)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_reason  text;
  v_ids     uuid[];
  v_claimed boolean;
  v_token   text;
  v_email   text;
  v_events  jsonb;
  v_mail    uuid;
  o         public.exos_orgs%ROWTYPE;
BEGIN
  PERFORM 1 FROM public.exos_follower_notices
    WHERE org_id = p_org AND follower_uid = p_uid AND status = 'pending'
    ORDER BY event_id FOR UPDATE;
  IF NOT FOUND THEN
    RETURN NULL;
  END IF;
  v_reason := public._exos_follower_skip_reason(p_org, p_uid);
  IF v_reason IS NOT NULL THEN
    UPDATE public.exos_follower_notices SET status = 'skipped', skip_reason = v_reason
     WHERE org_id = p_org AND follower_uid = p_uid AND status = 'pending';
    RETURN NULL;
  END IF;
  UPDATE public.exos_follower_notices n SET status = 'skipped', skip_reason = 'event_not_listed'
   WHERE n.org_id = p_org AND n.follower_uid = p_uid AND n.status = 'pending'
     AND NOT public._exos_follower_event_ok(n.event_id);
  SELECT array_agg(n.event_id ORDER BY e.starts_at, e.id) INTO v_ids
    FROM public.exos_follower_notices n JOIN public.exos_events e ON e.id = n.event_id
   WHERE n.org_id = p_org AND n.follower_uid = p_uid AND n.status = 'pending';
  IF v_ids IS NULL THEN
    RETURN NULL;
  END IF;

  INSERT INTO public.exos_follower_mail_slots AS s (org_id, follower_uid, last_mail_at)
  VALUES (p_org, p_uid, now())
  ON CONFLICT (org_id, follower_uid) DO UPDATE SET last_mail_at = now()
    WHERE s.last_mail_at <= now() - interval '24 hours'
  RETURNING true INTO v_claimed;
  IF v_claimed IS NULL THEN
    RETURN NULL;
  END IF;

  INSERT INTO public.exos_follow_tokens (org_id, follower_uid) VALUES (p_org, p_uid)
  ON CONFLICT (org_id, follower_uid) DO NOTHING;
  SELECT t.token INTO v_token FROM public.exos_follow_tokens t WHERE t.org_id = p_org AND t.follower_uid = p_uid;
  SELECT lower(u.email) INTO v_email FROM auth.users u WHERE u.id = p_uid;
  SELECT * INTO o FROM public.exos_orgs WHERE id = p_org;
  -- At most 10 events in one mail; the rest are counted ("and 3 more").
  SELECT jsonb_agg(jsonb_build_object('id', e.id, 'name', e.name, 'starts_at', e.starts_at, 'timezone', e.timezone,
                                      'venue_name', e.venue_name, 'venue_location', e.venue_location)
                   ORDER BY u.ord)
    INTO v_events
    FROM unnest(v_ids[1:10]) WITH ORDINALITY u(id, ord) JOIN public.exos_events e ON e.id = u.id;
  v_mail := public.exos_mail_enqueue('follower-new-event', v_email,
    jsonb_build_object('org', jsonb_build_object('id', o.id, 'name', o.name, 'slug', o.slug),
                       'events', v_events, 'more', greatest(cardinality(v_ids) - 10, 0),
                       'unfollow_token', v_token),
    'follower-new-event:' || v_ids[1] || ':' || p_uid, p_uid, true, NULL);
  UPDATE public.exos_follower_notices
     SET status = CASE WHEN v_mail IS NULL THEN 'skipped' ELSE 'queued' END,
         skip_reason = CASE WHEN v_mail IS NULL THEN 'not_queued' END,
         mail_id = v_mail
   WHERE follower_uid = p_uid AND event_id = ANY (v_ids);
  RETURN v_mail;
END $$;
REVOKE ALL ON FUNCTION public._exos_follower_flush(uuid, uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_follower_flush(uuid, uuid) TO service_role;

-- A listed event went live: one notice per follower (once ever), then try
-- to mail each. Followers in uuid order, so two publishes at once take the
-- slots in the same order. Returns the new notices not skipped (queued now
-- or waiting for the window).
CREATE OR REPLACE FUNCTION public._exos_follower_notices_on_publish(p_event uuid)
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_org  uuid;
  v_uids uuid[];
  v_uid  uuid;
BEGIN
  IF NOT public._exos_follower_event_ok(p_event) THEN
    RETURN 0;
  END IF;
  SELECT org_id INTO v_org FROM public.exos_events WHERE id = p_event;
  WITH ins AS (
    INSERT INTO public.exos_follower_notices (event_id, follower_uid, org_id)
    SELECT p_event, f.follower_uid, v_org FROM public.exos_org_follows f WHERE f.org_id = v_org
    ON CONFLICT (event_id, follower_uid) DO NOTHING
    RETURNING follower_uid)
  SELECT array_agg(follower_uid ORDER BY follower_uid) INTO v_uids FROM ins;
  IF v_uids IS NULL THEN
    RETURN 0;
  END IF;
  FOREACH v_uid IN ARRAY v_uids LOOP
    PERFORM public._exos_follower_flush(v_org, v_uid);
  END LOOP;
  RETURN (SELECT count(*) FROM public.exos_follower_notices n
           WHERE n.event_id = p_event AND n.follower_uid = ANY (v_uids) AND n.status <> 'skipped');
END $$;
REVOKE ALL ON FUNCTION public._exos_follower_notices_on_publish(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_follower_notices_on_publish(uuid) TO service_role;

-- The trigger: the event becomes live and listed (published, not noindex),
-- by insert, publish, or un-hiding. A series announces its first date only
-- (like the organizer's event-published mail). Never blocks the publish.
CREATE OR REPLACE FUNCTION public._exos_tg_follower_new_event()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF NEW.status <> 'published' OR coalesce(NEW.noindex, false) THEN
    RETURN NEW;
  END IF;
  IF TG_OP = 'UPDATE' AND OLD.status = 'published' AND NOT coalesce(OLD.noindex, false) THEN
    RETURN NEW;
  END IF;
  IF coalesce(NEW.series_index, 0) > 0 THEN
    RETURN NEW;
  END IF;
  BEGIN
    PERFORM public._exos_follower_notices_on_publish(NEW.id);
  EXCEPTION WHEN others THEN
    RAISE WARNING '_exos_tg_follower_new_event: event %: % (%)', NEW.id, SQLERRM, SQLSTATE;
  END;
  RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION public._exos_tg_follower_new_event() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS exos_events_follower_notices ON public.exos_events;
CREATE TRIGGER exos_events_follower_notices AFTER INSERT OR UPDATE OF status, noindex ON public.exos_events
  FOR EACH ROW EXECUTE FUNCTION public._exos_tg_follower_new_event();

-- The batch sweep: followers with pending notices whose 24-hour window has
-- passed get one mail with everything waiting. Returns mails queued.
CREATE OR REPLACE FUNCTION public.exos_send_follower_digests(p_limit integer DEFAULT 500)
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  r   record;
  v_n integer := 0;
BEGIN
  IF session_user NOT IN ('service_role', 'postgres', 'supabase_admin') THEN
    RAISE EXCEPTION 'exos_send_follower_digests: service role only' USING ERRCODE = '42501';
  END IF;
  FOR r IN
    SELECT DISTINCT n.org_id, n.follower_uid
      FROM public.exos_follower_notices n
     WHERE n.status = 'pending'
       AND NOT EXISTS (SELECT 1 FROM public.exos_follower_mail_slots s
                        WHERE s.org_id = n.org_id AND s.follower_uid = n.follower_uid
                          AND s.last_mail_at > now() - interval '24 hours')
     ORDER BY n.org_id, n.follower_uid
     LIMIT least(greatest(coalesce(p_limit, 500), 1), 5000)
  LOOP
    BEGIN
      IF public._exos_follower_flush(r.org_id, r.follower_uid) IS NOT NULL THEN
        v_n := v_n + 1;
      END IF;
    EXCEPTION WHEN others THEN
      RAISE WARNING 'exos_send_follower_digests: org % follower %: % (%)', r.org_id, r.follower_uid, SQLERRM, SQLSTATE;
    END;
  END LOOP;
  RETURN v_n;
END $$;
REVOKE ALL ON FUNCTION public.exos_send_follower_digests(integer) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_send_follower_digests(integer) TO service_role;

-- Hourly, created INACTIVE (prod keeps Exos crons off). Turn on with the
-- mail drain:
--   SELECT cron.alter_job((SELECT jobid FROM cron.job WHERE jobname = 'exos-follower-digests-hourly'), active := true);
-- Without it, a held-back event still goes out with the org's next publish
-- after the window. A re-run leaves the job alone.
DO $$
DECLARE v_job bigint;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN RETURN; END IF;
  EXECUTE 'SELECT jobid FROM cron.job WHERE jobname = $1' INTO v_job USING 'exos-follower-digests-hourly';
  IF v_job IS NULL THEN
    EXECUTE 'SELECT cron.schedule($1, $2, $3)' INTO v_job
      USING 'exos-follower-digests-hourly', '41 * * * *', 'SELECT public.exos_send_follower_digests(500);';
    EXECUTE 'SELECT cron.alter_job(job_id := $1, active := false)' USING v_job;
  END IF;
END $$;

-- ===========================================================================
-- 4. Follower mail: what the organizer sees
-- ===========================================================================
-- Counts only. Before publishing (not live and listed yet): will_notify =
-- followers who'd get the mail now. After: notified (queued), waiting
-- (pending: inside a follower's 24-hour window) and not_notified (skipped).
-- eligible false with a reason when the event won't be announced.
CREATE OR REPLACE FUNCTION public.exos_event_follower_notice(p_event_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  e        public.exos_events%ROWTYPE;
  v_reason text;
  v_live   boolean;
  v_total  integer;
BEGIN
  SELECT * INTO e FROM public.exos_events WHERE id = p_event_id;
  IF auth.uid() IS NULL OR NOT FOUND
     OR NOT (public.exos_is_admin() OR public.exos_has_org_role(e.org_id, ARRAY['owner', 'manager', 'finance', 'scanner', 'content'])) THEN
    RAISE EXCEPTION 'exos_event_follower_notice: event not found' USING ERRCODE = 'P0002';
  END IF;
  IF NOT (public.exos_is_admin() OR public.exos_has_org_role(e.org_id, ARRAY['owner', 'manager'])) THEN
    RAISE EXCEPTION 'exos_event_follower_notice: owners and managers only' USING ERRCODE = '42501';
  END IF;
  SELECT count(*) INTO v_total FROM public.exos_org_follows f WHERE f.org_id = e.org_id;
  v_reason := CASE
    WHEN e.status = 'cancelled' THEN 'cancelled'
    WHEN coalesce(e.noindex, false) THEN 'hidden'
    WHEN e.starts_at IS NULL OR e.starts_at <= now() THEN 'started'
    WHEN coalesce(e.series_index, 0) > 0 THEN 'series_date'
  END;
  v_live := e.status = 'published' AND NOT coalesce(e.noindex, false);
  IF v_live OR EXISTS (SELECT 1 FROM public.exos_follower_notices n WHERE n.event_id = e.id) THEN
    RETURN jsonb_build_object('state', 'after', 'followers', v_total, 'eligible', v_reason IS NULL, 'reason', v_reason,
      'notified', (SELECT count(*) FROM public.exos_follower_notices n WHERE n.event_id = e.id AND n.status = 'queued'),
      'waiting', (SELECT count(*) FROM public.exos_follower_notices n WHERE n.event_id = e.id AND n.status = 'pending'),
      'not_notified', (SELECT count(*) FROM public.exos_follower_notices n WHERE n.event_id = e.id AND n.status = 'skipped'));
  END IF;
  RETURN jsonb_build_object('state', 'before', 'followers', v_total, 'eligible', v_reason IS NULL, 'reason', v_reason,
    'will_notify', CASE WHEN v_reason IS NULL THEN
      (SELECT count(*) FROM public.exos_org_follows f
        WHERE f.org_id = e.org_id AND public._exos_follower_skip_reason(e.org_id, f.follower_uid) IS NULL)
      ELSE 0 END);
END $$;
REVOKE ALL ON FUNCTION public.exos_event_follower_notice(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_event_follower_notice(uuid) TO authenticated;

-- Followers the org may see, as rows: those with a fan profile linked to
-- their account (the Fans tab already shows them, with "follows the org").
-- Everyone else is a count. Owner / manager (and platform admins).
CREATE OR REPLACE FUNCTION public._exos_org_follower_rows(p_org uuid)
RETURNS TABLE (fan_id uuid, email text, first_name text, last_name text, followed_at timestamptz,
               email_list text, gets_new_event_mail boolean)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT fa.id, fa.email, fa.first_name, fa.last_name, f.created_at,
         CASE WHEN fa.email_opt_out_at IS NOT NULL THEN 'unsubscribed'
              WHEN fa.email_opt_in_at IS NOT NULL THEN 'subscribed' ELSE 'none' END,
         public._exos_follower_skip_reason(p_org, f.follower_uid) IS NULL
    FROM public.exos_org_follows f
    JOIN public.exos_fans fa ON fa.org_id = f.org_id AND fa.user_id = f.follower_uid AND fa.discarded_at IS NULL
   WHERE f.org_id = p_org
$$;
REVOKE ALL ON FUNCTION public._exos_org_follower_rows(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_org_follower_rows(uuid) TO service_role;

CREATE OR REPLACE FUNCTION public.exos_org_followers(p_org_id uuid, p_limit integer DEFAULT 100, p_offset integer DEFAULT 0)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_lim   integer := least(greatest(coalesce(p_limit, 100), 1), 500);
  v_off   integer := least(greatest(coalesce(p_offset, 0), 0), 1000000);
  v_total integer;
  v_seen  integer;
BEGIN
  IF auth.uid() IS NULL OR NOT (public.exos_is_admin() OR public.exos_has_org_role(p_org_id, ARRAY['owner', 'manager'])) THEN
    RAISE EXCEPTION 'exos_org_followers: owners and managers only' USING ERRCODE = '42501';
  END IF;
  SELECT count(*) INTO v_total FROM public.exos_org_follows f WHERE f.org_id = p_org_id;
  SELECT count(*) INTO v_seen FROM public._exos_org_follower_rows(p_org_id);
  RETURN jsonb_build_object(
    'total', v_total, 'listed', v_seen, 'not_listed', v_total - v_seen,
    'gets_new_event_mail', (SELECT count(*) FROM public.exos_org_follows f
                             WHERE f.org_id = p_org_id AND public._exos_follower_skip_reason(p_org_id, f.follower_uid) IS NULL),
    'rows', coalesce((SELECT jsonb_agg(to_jsonb(r) ORDER BY r.followed_at DESC, r.fan_id)
                        FROM (SELECT * FROM public._exos_org_follower_rows(p_org_id)
                               ORDER BY followed_at DESC, fan_id LIMIT v_lim OFFSET v_off) r), '[]'::jsonb));
END $$;
REVOKE ALL ON FUNCTION public.exos_org_followers(uuid, integer, integer) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_org_followers(uuid, integer, integer) TO authenticated;

-- The CSV (built in the browser, src/lib/csv.ts): the same rows, all of
-- them. 3 a minute and 20 a day per org; each one is an export.run row in
-- the org audit log (wave 8 convention).
CREATE OR REPLACE FUNCTION public.exos_org_followers_export(p_org_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE v_rows jsonb; v_n integer;
BEGIN
  IF auth.uid() IS NULL OR NOT (public.exos_is_admin() OR public.exos_has_org_role(p_org_id, ARRAY['owner', 'manager'])) THEN
    RAISE EXCEPTION 'exos_org_followers_export: owners and managers only' USING ERRCODE = '42501';
  END IF;
  IF NOT public.exos_rate_hit('followers-export:' || p_org_id::text, 3) THEN
    RAISE EXCEPTION 'exos_org_followers_export: too many exports, try again in a minute' USING ERRCODE = '54000';
  END IF;
  IF (SELECT count(*) FROM public.exos_org_audit a
       WHERE a.org_id = p_org_id AND a.action = 'export.run' AND a.entity_id = 'followers'
         AND a.at > now() - interval '1 day') >= 20 THEN
    RAISE EXCEPTION 'exos_org_followers_export: daily export limit reached (20 per organization)' USING ERRCODE = '54000';
  END IF;
  SELECT coalesce(jsonb_agg(to_jsonb(r) - 'fan_id' ORDER BY r.followed_at DESC, r.fan_id), '[]'::jsonb)
    INTO v_rows FROM public._exos_org_follower_rows(p_org_id) r;
  v_n := jsonb_array_length(v_rows);
  /* exos: audit export.run */
  PERFORM public._exos_audit(p_org_id, 'export.run', 'export', 'followers', NULL,
    jsonb_build_object('kind', jsonb_build_array(NULL, 'followers'), 'row_count', jsonb_build_array(NULL, v_n)));
  RETURN jsonb_build_object('count', v_n, 'generated_at', now(), 'rows', v_rows);
END $$;
REVOKE ALL ON FUNCTION public.exos_org_followers_export(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_org_followers_export(uuid) TO authenticated;

-- ===========================================================================
-- 5. Unfollow from the mail (one click on /unfollow?t=, no sign-in)
-- ===========================================================================
-- 64-hex token from follower-new-event mail. Removes that follow (and its
-- waiting notices) and keeps followers_count right, as exos_unfollow_org
-- does. Answers ok and the org's name only; a bad token answers ok: false.
CREATE OR REPLACE FUNCTION public.exos_unfollow_by_token(p_token text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE t public.exos_follow_tokens%ROWTYPE; v_rows integer;
BEGIN
  IF coalesce(p_token, '') !~ '^[0-9a-f]{64}$' THEN
    RETURN jsonb_build_object('ok', false);
  END IF;
  SELECT * INTO t FROM public.exos_follow_tokens WHERE token = p_token;
  IF t.org_id IS NULL THEN
    RETURN jsonb_build_object('ok', false);
  END IF;
  DELETE FROM public.exos_org_follows WHERE follower_uid = t.follower_uid AND org_id = t.org_id;
  GET DIAGNOSTICS v_rows = ROW_COUNT;
  IF v_rows > 0 THEN
    UPDATE public.exos_orgs SET followers_count = greatest(0, followers_count - 1) WHERE id = t.org_id;
  END IF;
  UPDATE public.exos_follower_notices SET status = 'skipped', skip_reason = 'not_following'
   WHERE org_id = t.org_id AND follower_uid = t.follower_uid AND status = 'pending';
  RETURN jsonb_build_object('ok', true, 'org_name', (SELECT o.name FROM public.exos_orgs o WHERE o.id = t.org_id));
END $$;
REVOKE ALL ON FUNCTION public.exos_unfollow_by_token(text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_unfollow_by_token(text) TO anon, authenticated, service_role;

-- ===========================================================================
-- 6. exos_announce_to_followers, through the same path
-- ===========================================================================
-- Same caller check as mig 20260523200000 (owner / manager / admin, a
-- published event). It now queues the consent-gated, once-per-event mail
-- (a follower already told about this event isn't told again) instead of an
-- html row to every follower. Returns the followers notified or waiting.
CREATE OR REPLACE FUNCTION public.exos_announce_to_followers(p_event_id uuid)
RETURNS int
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_org    uuid;
  v_status text;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'exos_announce_to_followers: not authenticated' USING ERRCODE = '42501';
  END IF;
  SELECT org_id, status INTO v_org, v_status FROM public.exos_events WHERE id = p_event_id;
  IF v_org IS NULL THEN
    RAISE EXCEPTION 'exos_announce_to_followers: event not found';
  END IF;
  IF NOT (exos_is_admin() OR exos_has_org_role(v_org, ARRAY['owner','manager'])) THEN
    RAISE EXCEPTION 'exos_announce_to_followers: not authorized' USING ERRCODE = '42501';
  END IF;
  IF v_status <> 'published' THEN
    RAISE EXCEPTION 'exos_announce_to_followers: event must be published (is %)', v_status;
  END IF;
  RETURN public._exos_follower_notices_on_publish(p_event_id); /* exos: follower notices */
END $$;
REVOKE EXECUTE ON FUNCTION public.exos_announce_to_followers(uuid) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.exos_announce_to_followers(uuid) TO authenticated;
