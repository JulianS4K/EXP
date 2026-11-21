-- ============================================================================
-- Migration 20261121153700 — Exos: promotion (genre-aware discovery
-- channels, per-placement print QR codes)
-- ============================================================================
-- Touches:  W: exos_discovery_channels (+ seed rows the_skint, allevents,
--              fever, nonsense_nyc, spotify; songkick moved to the lowest
--              sort order; mirrored by
--              supabase/functions/_shared/discovery/channels.ts)
--           C: TABLE exos_print_placements (one row per poster / flyer spot
--              of an event; RLS on, RPCs only)
--           C: FUNCTION exos_print_placements (owner / manager / finance, or
--              admin), exos_print_placement_add, exos_print_placement_remove
--              (owner / manager, or admin); _exos_print_placement_row,
--              _exos_print_placement_slug (internal, no client grant)
--           R: CREATE OR REPLACE _exos_channel_key (pure; + paid_search: google
--              paid_search is "Google ads"; partiful its own key),
--              _exos_channel_label (pure; + 'partiful' -> 'Partiful')
--           R: exos_events, exos_has_org_role, exos_is_admin
-- Pre-reqs: 20261029130000 (discovery publishing), 20261104150000 (posh_link)
--
-- 1. Channels. Five more manual channels, all worked by a person (nothing
--    here calls a third party): The Skint (web form), AllEvents (free
--    posting from the organizer's account), Fever's free listing, Nonsense
--    NYC (no known way to submit: submission_url NULL, the SPA shows "How to
--    submit: unknown"), Spotify concerts (through Bandsintown) and Partiful
--    (operator 2026-11-21, "Also partiful": the organizer makes the invite
--    page on their own Partiful account and links to Exos checkout; Partiful
--    has no public API and its terms bar scraping, so nothing is automated
--    or read). Which
--    channels suit which event category is TypeScript (GENRE_CHANNELS in
--    _shared/discovery/channels.ts); the table only carries the catalog.
--    Songkick moves to the bottom (reports that it is winding down).
--
-- 2. Print placements. An organizer names the spots a poster or flyer goes
--    ("Poster - Bedford Ave", "Flyer - Bar X"); each gets a slug, unique per
--    event, that the Promote page puts in the event's short link as
--    utm_source=print&utm_medium=qr&utm_content=<slug> and in a QR code.
--    Nothing new is needed to count the sales: checkouts keep utm_content in
--    exos_checkout_sessions.attribution (mig 20260924223000), the Sources
--    report groups by it (src/lib/sourceReport.ts, "Placement"), and the
--    channel report credits utm_source=print to "Flyer / QR code"
--    (_exos_channel_key). The slug is made here from the name: lower case,
--    a-z 0-9 and '-', at most 60 characters, '-2', '-3', ... on a clash.
--    At most 200 placements per event.
--
-- 3. One UTM scheme (_shared/marketing/utm.ts): utm_medium is paid_social,
--    paid_search, print, email or organic_social (sms, messaging, referral
--    for the rest), utm_source the platform. Google ads links are now
--    google / paid_search, so _exos_channel_key counts paid_search as Google
--    ads beside cpc / paid / ppc. The rest of its body is unchanged (it is
--    pure and only defined in 20261029120000, so it is replaced whole).
--    Meta paid_social and qr / print (-> flyer) already mapped.
--    Partiful is a recognised source: utm_source=partiful is its own channel
--    key and _exos_channel_label (also pure and only defined in
--    20261029120000, so replaced whole) names it "Partiful" instead of
--    "Other".
--
-- Additive and re-run safe. Prod apply needs operator OK.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. Discovery channels
-- ---------------------------------------------------------------------------
-- Keep in step with DISCOVERY_CHANNELS (channels.ts); a vitest compares them.
INSERT INTO public.exos_discovery_channels (id, name, kind, region, submission_url, verified, sort_order) VALUES
  ('the_skint',        'The Skint',                 'manual', 'NYC',    'https://theskint.com/submit-an-event/', true, 200),
  ('allevents',        'AllEvents',                 'manual', 'global', 'https://allevents.in/pages/publish-events', true, 210),
  ('fever',            'Fever (free listing)',      'manual', 'global', 'https://business.feverup.com', false, 220),
  ('nonsense_nyc',     'Nonsense NYC',              'manual', 'NYC',    NULL, false, 230),
  ('spotify',          'Spotify concerts',          'manual', 'global', 'https://support.spotify.com/artists/article/concerts', true, 240),
  ('partiful',         'Partiful',                  'manual', 'NYC',    'https://partiful.com', false, 250),
  ('songkick',         'Songkick',                  'manual', 'global', 'https://support.songkick.com/hc/en-us/articles/360011925897', true, 900)
ON CONFLICT (id) DO UPDATE SET
  name = EXCLUDED.name, kind = EXCLUDED.kind, region = EXCLUDED.region,
  submission_url = EXCLUDED.submission_url, verified = EXCLUDED.verified, sort_order = EXCLUDED.sort_order;

-- ---------------------------------------------------------------------------
-- 2. Print placements
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.exos_print_placements (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  event_id    uuid NOT NULL REFERENCES public.exos_events (id) ON DELETE CASCADE,
  org_id      uuid NOT NULL REFERENCES public.exos_orgs (id) ON DELETE CASCADE,
  name        text NOT NULL CHECK (length(btrim(name)) BETWEEN 1 AND 80),
  slug        text NOT NULL CHECK (slug ~ '^[a-z0-9]+(-[a-z0-9]+)*$' AND length(slug) <= 60),
  created_by  uuid REFERENCES auth.users (id) ON DELETE SET NULL,
  -- clock_timestamp: placements added in one transaction keep their order.
  created_at  timestamptz NOT NULL DEFAULT clock_timestamp(),
  UNIQUE (event_id, slug)
);
COMMENT ON TABLE public.exos_print_placements IS
  'Poster / flyer spots of an event (mig 20261121153700). The slug is the utm_content of the spot''s QR link (utm_source=print, utm_medium=qr). RPCs only.';
CREATE INDEX IF NOT EXISTS exos_print_placements_org_idx ON public.exos_print_placements (org_id);
ALTER TABLE public.exos_print_placements ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.exos_print_placements FROM PUBLIC, anon, authenticated;
GRANT ALL ON TABLE public.exos_print_placements TO service_role;

-- A name as a slug: lower case, a-z 0-9 and '-', at most 60 characters
-- (src/lib/printPlacements.ts placementSlug does the same for the preview).
CREATE OR REPLACE FUNCTION public._exos_print_placement_slug(p_name text)
RETURNS text LANGUAGE sql IMMUTABLE
SET search_path = public, pg_temp AS $$
  SELECT nullif(btrim(left(btrim(regexp_replace(lower(coalesce(p_name, '')), '[^a-z0-9]+', '-', 'g'), '-'), 60), '-'), '')
$$;
REVOKE ALL ON FUNCTION public._exos_print_placement_slug(text) FROM PUBLIC, anon, authenticated;

-- Shapes a row the caller already holds: no definer rights needed.
CREATE OR REPLACE FUNCTION public._exos_print_placement_row(p public.exos_print_placements)
RETURNS jsonb LANGUAGE sql STABLE SECURITY INVOKER
SET search_path = public, pg_temp AS $$
  SELECT jsonb_build_object('id', p.id, 'event_id', p.event_id, 'name', p.name, 'slug', p.slug, 'created_at', p.created_at)
$$;
REVOKE ALL ON FUNCTION public._exos_print_placement_row(public.exos_print_placements) FROM PUBLIC, anon, authenticated;

-- Owner / manager / finance (or admin): the event's placements, oldest first.
CREATE OR REPLACE FUNCTION public.exos_print_placements(p_event_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp AS $$
DECLARE v_org uuid;
BEGIN
  SELECT e.org_id INTO v_org FROM public.exos_events e WHERE e.id = p_event_id;
  IF v_org IS NULL
     OR NOT (public.exos_is_admin() OR public.exos_has_org_role(v_org, ARRAY['owner', 'manager', 'finance'])) THEN
    RAISE EXCEPTION 'exos_print_placements: not authorized' USING ERRCODE = '42501';
  END IF;
  RETURN coalesce((SELECT jsonb_agg(public._exos_print_placement_row(p) ORDER BY p.created_at, p.slug)
                     FROM public.exos_print_placements p WHERE p.event_id = p_event_id), '[]'::jsonb);
END $$;
REVOKE ALL ON FUNCTION public.exos_print_placements(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.exos_print_placements(uuid) TO authenticated, service_role;

-- Owner / manager (or admin): add a placement. Returns the row.
CREATE OR REPLACE FUNCTION public.exos_print_placement_add(p_event_id uuid, p_name text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp AS $$
DECLARE
  v_org  uuid;
  v_name text := btrim(regexp_replace(coalesce(p_name, ''), '\s+', ' ', 'g'));
  v_base text;
  v_slug text;
  v_n    integer := 1;
  v_row  public.exos_print_placements%ROWTYPE;
BEGIN
  -- The role check first (no lock), then a per-event advisory lock so two
  -- adds can't take the same slug or pass the cap together. Nothing on
  -- exos_events is locked, so tier inserts and other event writes never wait.
  SELECT e.org_id INTO v_org FROM public.exos_events e WHERE e.id = p_event_id;
  IF v_org IS NULL
     OR NOT (public.exos_is_admin() OR public.exos_has_org_role(v_org, ARRAY['owner', 'manager'])) THEN
    RAISE EXCEPTION 'exos_print_placement_add: not authorized' USING ERRCODE = '42501';
  END IF;
  PERFORM pg_advisory_xact_lock(hashtextextended('exos_print_placements:' || p_event_id::text, 0));
  IF length(v_name) < 1 OR length(v_name) > 80 THEN
    RAISE EXCEPTION 'exos_print_placement_add: name the spot (up to 80 characters), e.g. Poster - Bedford Ave' USING ERRCODE = '22023';
  END IF;
  v_base := public._exos_print_placement_slug(v_name);
  IF v_base IS NULL THEN
    RAISE EXCEPTION 'exos_print_placement_add: the name needs a letter or a number' USING ERRCODE = '22023';
  END IF;
  IF (SELECT count(*) FROM public.exos_print_placements WHERE event_id = p_event_id) >= 200 THEN
    RAISE EXCEPTION 'exos_print_placement_add: an event has at most 200 placements' USING ERRCODE = '22023';
  END IF;
  v_slug := v_base;
  WHILE EXISTS (SELECT 1 FROM public.exos_print_placements WHERE event_id = p_event_id AND slug = v_slug) LOOP
    v_n := v_n + 1;
    v_slug := btrim(left(v_base, 60 - length(v_n::text) - 1), '-') || '-' || v_n;
  END LOOP;
  INSERT INTO public.exos_print_placements (event_id, org_id, name, slug, created_by)
  VALUES (p_event_id, v_org, v_name, v_slug, auth.uid())
  RETURNING * INTO v_row;
  RETURN public._exos_print_placement_row(v_row);
END $$;
REVOKE ALL ON FUNCTION public.exos_print_placement_add(uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.exos_print_placement_add(uuid, text) TO authenticated, service_role;

-- Owner / manager (or admin): remove a placement. Its sales stay in the
-- reports (they are keyed by the utm_content on the checkout, not this row).
-- Authorized on the event's CURRENT org (as list and add), not the org_id
-- stamped at insert: after an event moves orgs, the new owner manages it.
CREATE OR REPLACE FUNCTION public.exos_print_placement_remove(p_id uuid)
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp AS $$
DECLARE v_org uuid;
BEGIN
  SELECT e.org_id INTO v_org
    FROM public.exos_print_placements p JOIN public.exos_events e ON e.id = p.event_id
   WHERE p.id = p_id;
  IF v_org IS NULL
     OR NOT (public.exos_is_admin() OR public.exos_has_org_role(v_org, ARRAY['owner', 'manager'])) THEN
    RAISE EXCEPTION 'exos_print_placement_remove: not authorized' USING ERRCODE = '42501';
  END IF;
  DELETE FROM public.exos_print_placements WHERE id = p_id;
  RETURN true;
END $$;
REVOKE ALL ON FUNCTION public.exos_print_placement_remove(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.exos_print_placement_remove(uuid) TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 3. Channel key: paid_search is Google ads
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._exos_channel_key(p_source text, p_medium text DEFAULT NULL)
RETURNS text
LANGUAGE sql IMMUTABLE
SET search_path = public, pg_temp
AS $$
  WITH s AS (
    SELECT regexp_replace(regexp_replace(regexp_replace(lower(btrim(coalesce(p_source, ''))),
             '^(https?://)?(www\.|m\.|l\.|lm\.|mobile\.)?', ''), '(\.com|\.co|\.net|\.ai)?(/.*)?$', ''),
             '[^a-z0-9._-]+', '-', 'g') AS v,
           lower(btrim(coalesce(p_medium, ''))) AS m
  ), k AS (
    SELECT CASE
      WHEN v IN ('instagram', 'ig', 'insta') THEN 'instagram'
      WHEN v IN ('facebook', 'fb') THEN 'facebook'
      WHEN v IN ('tiktok', 'tt') THEN 'tiktok'
      WHEN v IN ('x', 'twitter', 't') THEN 'x'
      WHEN v IN ('email', 'e-mail', 'newsletter', 'mailchimp', 'klaviyo', 'mail') THEN 'email'
      WHEN v IN ('sms', 'text', 'texts') THEN 'sms'
      WHEN v IN ('whatsapp', 'wa') THEN 'whatsapp'
      WHEN v IN ('flyer', 'qr', 'poster', 'print') THEN 'flyer'
      WHEN v IN ('partner', 'partners', 'partner-site') THEN 'partner'
      WHEN v IN ('meta-ads', 'facebook-ads', 'instagram-ads') THEN 'meta-ads'
      WHEN v IN ('google-ads', 'adwords') THEN 'google-ads'
      WHEN v = 'google' THEN 'google'
      WHEN v IN ('chatgpt', 'openai', 'chat.openai', 'claude', 'perplexity', 'gemini', 'gemini.google',
                 'copilot', 'copilot.microsoft', 'grok', 'mistral', 'deepseek', 'ai_assistant', 'ai') THEN 'ai'
      WHEN v = 'meta' THEN 'meta'
      WHEN v IN ('link', 'share_sheet', 'share') THEN 'share'
      WHEN v = 'partiful' THEN 'partiful'
      WHEN v = '' THEN NULL
      -- Anyone can put anything in utm_source: an unknown key keeps only
      -- [a-z0-9_-] (no dots, so no domain), and its label is "Other".
      ELSE left(btrim(regexp_replace(v, '[^a-z0-9_-]+', '', 'g'), '-_'), 40)
    END AS c, m FROM s
  )
  SELECT CASE
    WHEN c IN ('instagram', 'facebook', 'meta') AND m IN ('cpc', 'paid', 'ppc', 'paid_social', 'paidsocial') THEN 'meta-ads'
    WHEN c = 'google' AND m IN ('cpc', 'paid', 'ppc', 'paid_search') THEN 'google-ads'
    ELSE nullif(c, '')
  END FROM k
$$;
REVOKE ALL ON FUNCTION public._exos_channel_key(text, text) FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 4. Channel label: Partiful
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._exos_channel_label(p_channel text)
RETURNS text
LANGUAGE sql IMMUTABLE
SET search_path = public, pg_temp
AS $$
  SELECT CASE p_channel
    WHEN 'direct' THEN 'Direct / unknown'
    WHEN 'instagram' THEN 'Instagram'
    WHEN 'facebook' THEN 'Facebook'
    WHEN 'tiktok' THEN 'TikTok'
    WHEN 'x' THEN 'X / Twitter'
    WHEN 'email' THEN 'Email'
    WHEN 'sms' THEN 'Text message'
    WHEN 'whatsapp' THEN 'WhatsApp'
    WHEN 'flyer' THEN 'Flyer / QR code'
    WHEN 'partner' THEN 'Partner sites'
    WHEN 'meta-ads' THEN 'Meta ads'
    WHEN 'google-ads' THEN 'Google ads'
    WHEN 'google' THEN 'Google'
    WHEN 'meta' THEN 'Meta (Facebook / Instagram)'
    WHEN 'reddit' THEN 'Reddit'
    WHEN 'snapchat' THEN 'Snapchat'
    WHEN 'microsoft' THEN 'Microsoft Ads'
    WHEN 'embed' THEN 'Venue site embed'
    WHEN 'ai' THEN 'AI assistants'
    WHEN 'promo' THEN 'Promo links'
    WHEN 'share' THEN 'Shared links'
    WHEN 'box_office' THEN 'Box office'
    WHEN 'eventbrite' THEN 'Eventbrite'
    WHEN 'luma' THEN 'Luma'
    WHEN 'pretix' THEN 'pretix'
    WHEN 'hievents' THEN 'hi.events'
    WHEN 'stubhub' THEN 'StubHub'
    WHEN 'seatgeek' THEN 'SeatGeek'
    WHEN 'vivid' THEN 'Vivid Seats'
    WHEN 'gametime' THEN 'Gametime'
    WHEN 'tickpick' THEN 'TickPick'
    WHEN 'gotickets' THEN 'GoTickets'
    WHEN 'evo' THEN 'TEvo'
    WHEN 'tevo' THEN 'TEvo'
    WHEN 'automatiq' THEN 'Automatiq'
    WHEN 's4k' THEN 'S4K network'
    WHEN 'comp' THEN 'Comps'
    WHEN 'staff_issued' THEN 'Issued by staff'
    WHEN 'referral_reward' THEN 'Referral rewards'
    WHEN 'guest_list' THEN 'Guest lists'
    WHEN 'posh' THEN 'Posh'
    WHEN 'partiful' THEN 'Partiful'
    WHEN 'import' THEN 'Imported list'
    WHEN 'import:posh' THEN 'Imported list (Posh)'
    ELSE CASE
      WHEN p_channel LIKE 'promoter:%' THEN 'Promoters'
      WHEN p_channel LIKE 'import:%' THEN 'Imported list'
      ELSE 'Other'
    END
  END
$$;
REVOKE ALL ON FUNCTION public._exos_channel_label(text) FROM PUBLIC, anon, authenticated;
