-- ============================================================================
-- Discovery publishing: per-event, per-channel listing status (spec item 8)
-- ============================================================================
-- Touches:  C: TABLE exos_discovery_channels (the channel catalog; seeded here,
--              mirrored by supabase/functions/_shared/discovery/channels.ts)
--           C: TABLE exos_discovery_publications (one row per event + manual
--              channel: queued / submitted / live / rejected / removed)
--           C: FUNCTION exos_discovery_queue, exos_discovery_withdraw,
--              exos_discovery_set_status (owner / manager of the event's org,
--              or a platform admin), exos_discovery_event_channels (owner /
--              manager / finance, or admin), exos_discovery_queue_list
--              (platform admin only: the manual queue across orgs),
--              exos_discovery_minutes (manual minutes per event and per org)
-- Pre-reqs: 20260520120000 (orgs, memberships, events), 20260520130000
--           (exos_is_admin, tiers), 20260703122000 (price_schedule),
--           20260924211840 (exos_tier_exclusive_tax_percent),
--           20260929073000 (exos_calendar_public_feed),
--           20260929120000 (summary, description_md), 20261005090000 (format,
--           noindex), 20261014140000 (exos_event_max_capacity,
--           exos_platform_settings)
--
-- Feed channels (Google events feed, calendar feeds, ad catalogs) have no
-- stored status: whether an event is in a feed is that feed's own rule.
--   * calendar_ics: computed here by asking exos_calendar_public_feed for
--     the org's calendar and looking for the event (the same function the
--     exos-calendar edge function serves), so the rule lives in one place.
--   * google_events / ad_catalog: the rules are TypeScript (feedBlocker,
--     catalogBlocker); exos_discovery_event_channels returns the event and
--     its public ticket types so the SPA runs those same functions.
-- Manual channels are worked by a person: the organizer queues the event,
-- the operator (exos_is_admin, app_metadata.admin) submits it on the
-- channel's form and records submitted / live (URL) / rejected (reason).
-- Organizer staff can record the result too (some channels, e.g. Meetup or
-- RA, only take submissions from the organizer's own account).
-- No channel is written to by Exos: nothing here calls a third party.
--
-- Free-tier cap (operator, spec rev de8877d): an event whose max capacity
-- (exos_event_max_capacity) is at or under the free-tier cutoff can use at
-- most 5 manual channels. The cutoff is exos_platform_settings
-- 'free_tier_max_capacity' (that row comes from another branch), 150 when
-- the row is missing. A channel counts once it has been queued and not
-- withdrawn (queued, submitted, live, rejected, removed); requeueing a
-- counted channel doesn't add one. Feed and API channels never count. An
-- event with no capacity set at all (max capacity 0) is treated as small.
--
-- Minutes (the 60-day discovery pilot measures manual minutes per event):
-- whoever records submitted / live / rejected enters the minutes that step
-- took; they add up on the record (minutes_spent) and are totalled per
-- event and per org by exos_discovery_minutes.
--
-- Additive and re-run safe. Prod apply needs operator OK.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. Channel catalog
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.exos_discovery_channels (
  id             text PRIMARY KEY CHECK (id ~ '^[a-z0-9_]{2,40}$'),
  name           text NOT NULL,
  kind           text NOT NULL CHECK (kind IN ('feed', 'api', 'manual')),
  region         text NOT NULL,
  submission_url text CHECK (submission_url IS NULL OR submission_url ~ '^https://'),
  verified       boolean NOT NULL DEFAULT false,
  notes          text,
  active         boolean NOT NULL DEFAULT true,
  sort_order     integer NOT NULL DEFAULT 0
);
ALTER TABLE public.exos_discovery_channels ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS exos_discovery_channels_read ON public.exos_discovery_channels;
CREATE POLICY exos_discovery_channels_read ON public.exos_discovery_channels
  FOR SELECT TO authenticated USING (true);
REVOKE ALL ON public.exos_discovery_channels FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.exos_discovery_channels TO authenticated;
GRANT ALL ON public.exos_discovery_channels TO service_role;

-- Keep in step with DISCOVERY_CHANNELS (channels.ts); a vitest compares them.
INSERT INTO public.exos_discovery_channels (id, name, kind, region, submission_url, verified, sort_order) VALUES
  ('google_events',    'Google Search & Maps (events feed)',          'feed',   'global', NULL, true, 10),
  ('calendar_ics',     'Calendar feeds (Google / Apple / Outlook)',   'feed',   'global', NULL, true, 20),
  ('ad_catalog',       'Ad catalogs (Meta, TikTok, Google Merchant)', 'feed',   'global', NULL, true, 30),
  ('donyc',            'DoNYC',                     'manual', 'NYC',    'https://donyc.com/p/how-to-nyc', true, 100),
  ('timeout_nyc',      'Time Out New York',         'manual', 'NYC',    'https://www.timeout.com/newyork/get-listed', true, 110),
  ('cityspark',        'CitySpark local calendars', 'manual', 'US',     'https://intercom.help/cityspark/en/articles/12429064-how-to-submit-an-event-to-cityspark', true, 120),
  ('resident_advisor', 'Resident Advisor (RA)',     'manual', 'global', 'https://support.ra.co/article/12-submitting-events', true, 130),
  ('oh_my_rockness',   'Oh My Rockness',            'manual', 'NYC',    'https://www.ohmyrockness.com', false, 140),
  ('edmtrain',         'Edmtrain',                  'manual', 'US',     'https://edmtrain.com', false, 150),
  ('meetup',           'Meetup',                    'manual', 'global', 'https://www.meetup.com', false, 160),
  ('songkick',         'Songkick',                  'manual', 'global', 'https://support.songkick.com/hc/en-us/articles/360011925897', true, 170),
  ('bandsintown',      'Bandsintown',               'manual', 'global', 'https://help.artists.bandsintown.com/en/articles/7039442-add-an-event', true, 180)
ON CONFLICT (id) DO UPDATE SET
  name = EXCLUDED.name, kind = EXCLUDED.kind, region = EXCLUDED.region,
  submission_url = EXCLUDED.submission_url, verified = EXCLUDED.verified, sort_order = EXCLUDED.sort_order;

-- ---------------------------------------------------------------------------
-- 2. Publications (manual / api channels only)
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.exos_discovery_publications (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  event_id         uuid NOT NULL REFERENCES public.exos_events (id) ON DELETE CASCADE,
  org_id           uuid NOT NULL REFERENCES public.exos_orgs (id) ON DELETE CASCADE,
  channel_id       text NOT NULL REFERENCES public.exos_discovery_channels (id),
  status           text NOT NULL DEFAULT 'not_submitted'
                   CHECK (status IN ('not_submitted', 'queued', 'submitted', 'live', 'rejected', 'removed')),
  live_url         text CHECK (live_url IS NULL OR (live_url ~ '^https://' AND length(live_url) <= 2000)),
  rejection_reason text CHECK (rejection_reason IS NULL OR length(rejection_reason) <= 500),
  next_action      text CHECK (next_action IS NULL OR length(next_action) <= 500),
  note             text CHECK (note IS NULL OR length(note) <= 1000),
  minutes_spent    integer NOT NULL DEFAULT 0 CHECK (minutes_spent BETWEEN 0 AND 100000),
  queued_at        timestamptz,
  queued_by        uuid REFERENCES auth.users (id) ON DELETE SET NULL,
  submitted_at     timestamptz,
  submitted_by     uuid REFERENCES auth.users (id) ON DELETE SET NULL,
  decided_at       timestamptz,
  decided_by       uuid REFERENCES auth.users (id) ON DELETE SET NULL,
  created_at       timestamptz NOT NULL DEFAULT now(),
  updated_at       timestamptz NOT NULL DEFAULT now(),
  updated_by       uuid REFERENCES auth.users (id) ON DELETE SET NULL,
  UNIQUE (event_id, channel_id)
);
CREATE INDEX IF NOT EXISTS exos_discovery_publications_org_idx ON public.exos_discovery_publications (org_id);
CREATE INDEX IF NOT EXISTS exos_discovery_publications_queue_idx
  ON public.exos_discovery_publications (status, queued_at) WHERE status IN ('queued', 'submitted');
CREATE INDEX IF NOT EXISTS exos_discovery_publications_channel_idx ON public.exos_discovery_publications (channel_id);
-- Re-run safe if an earlier copy of this file made the table without it.
ALTER TABLE public.exos_discovery_publications
  ADD COLUMN IF NOT EXISTS minutes_spent integer NOT NULL DEFAULT 0 CHECK (minutes_spent BETWEEN 0 AND 100000);

ALTER TABLE public.exos_discovery_publications ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS exos_discovery_publications_read ON public.exos_discovery_publications;
CREATE POLICY exos_discovery_publications_read ON public.exos_discovery_publications
  FOR SELECT TO authenticated
  USING ((SELECT public.exos_is_admin())
         OR public.exos_has_org_role(org_id, ARRAY['owner', 'manager', 'finance']));
-- Writes only through the RPCs below.
REVOKE ALL ON public.exos_discovery_publications FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.exos_discovery_publications TO authenticated;
GRANT ALL ON public.exos_discovery_publications TO service_role;

-- ---------------------------------------------------------------------------
-- 3. Helpers (no client grant)
-- ---------------------------------------------------------------------------
-- The caller may change this event's listings: owner / manager of its org,
-- or a platform admin. Returns the event's org.
CREATE OR REPLACE FUNCTION public._exos_discovery_writer(p_event_id uuid, p_fn text)
RETURNS uuid LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp AS $$
DECLARE v_org uuid;
BEGIN
  SELECT e.org_id INTO v_org FROM public.exos_events e WHERE e.id = p_event_id;
  IF v_org IS NULL
     OR NOT (public.exos_is_admin() OR public.exos_has_org_role(v_org, ARRAY['owner', 'manager'])) THEN
    RAISE EXCEPTION '%: not authorized', p_fn USING ERRCODE = '42501';
  END IF;
  RETURN v_org;
END $$;
REVOKE ALL ON FUNCTION public._exos_discovery_writer(uuid, text) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public._exos_discovery_row(p public.exos_discovery_publications)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp AS $$
  SELECT jsonb_build_object(
    'id', p.id, 'event_id', p.event_id, 'channel_id', p.channel_id, 'status', p.status,
    'live_url', p.live_url, 'rejection_reason', p.rejection_reason, 'next_action', p.next_action, 'note', p.note,
    'minutes_spent', p.minutes_spent,
    'queued_at', p.queued_at, 'submitted_at', p.submitted_at, 'decided_at', p.decided_at, 'updated_at', p.updated_at)
$$;
REVOKE ALL ON FUNCTION public._exos_discovery_row(public.exos_discovery_publications) FROM PUBLIC, anon, authenticated;

-- Free-tier cutoff: exos_platform_settings 'free_tier_max_capacity', else 150.
CREATE OR REPLACE FUNCTION public._exos_discovery_free_tier_max()
RETURNS integer LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp AS $$
  SELECT coalesce((SELECT CASE WHEN jsonb_typeof(value) = 'number' AND (value #>> '{}') ~ '^[0-9]{1,6}$'
                               THEN (value #>> '{}')::int END
                     FROM public.exos_platform_settings WHERE key = 'free_tier_max_capacity'), 150)
$$;
REVOKE ALL ON FUNCTION public._exos_discovery_free_tier_max() FROM PUBLIC, anon, authenticated;

-- How many manual channels this event may use: 5 on the free tier, else NULL (no cap).
CREATE OR REPLACE FUNCTION public._exos_discovery_manual_cap(p_event_id uuid)
RETURNS integer LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp AS $$
  SELECT CASE WHEN coalesce(public.exos_event_max_capacity(p_event_id), 0) <= public._exos_discovery_free_tier_max()
              THEN 5 END
$$;
REVOKE ALL ON FUNCTION public._exos_discovery_manual_cap(uuid) FROM PUBLIC, anon, authenticated;

-- Manual channels this event uses (queued at some point and not withdrawn).
CREATE OR REPLACE FUNCTION public._exos_discovery_manual_used(p_event_id uuid)
RETURNS integer LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp AS $$
  SELECT count(*)::int FROM public.exos_discovery_publications p
    JOIN public.exos_discovery_channels c ON c.id = p.channel_id AND c.kind = 'manual'
   WHERE p.event_id = p_event_id AND p.status <> 'not_submitted'
$$;
REVOKE ALL ON FUNCTION public._exos_discovery_manual_used(uuid) FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 4. Queue / withdraw / record a result
-- ---------------------------------------------------------------------------
-- Queue an upcoming published event for a manual channel. Idempotent: an
-- event already queued, submitted or live is returned unchanged; a rejected,
-- removed or withdrawn one is queued again (the old reason / URL cleared).
CREATE OR REPLACE FUNCTION public.exos_discovery_queue(p_event_id uuid, p_channel_id text, p_note text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp AS $$
DECLARE
  v_org  uuid := public._exos_discovery_writer(p_event_id, 'exos_discovery_queue');
  v_ch   public.exos_discovery_channels%ROWTYPE;
  v_ev   record;
  v_note text := nullif(btrim(coalesce(p_note, '')), '');
  v_row  public.exos_discovery_publications%ROWTYPE;
  v_cap  integer;
BEGIN
  SELECT * INTO v_ch FROM public.exos_discovery_channels WHERE id = p_channel_id AND active;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'exos_discovery_queue: unknown channel' USING ERRCODE = '22023';
  END IF;
  IF v_ch.kind <> 'manual' THEN
    RAISE EXCEPTION 'exos_discovery_queue: % is a feed; its status follows the feed', v_ch.name USING ERRCODE = '22023';
  END IF;
  IF v_note IS NOT NULL AND length(v_note) > 1000 THEN
    RAISE EXCEPTION 'exos_discovery_queue: note is up to 1000 characters' USING ERRCODE = '22023';
  END IF;
  SELECT e.status, e.starts_at, coalesce(e.ends_at, e.starts_at + interval '6 hours') AS ends
    INTO v_ev FROM public.exos_events e WHERE e.id = p_event_id;
  IF v_ev.status <> 'published' OR v_ev.starts_at IS NULL OR v_ev.ends < now() THEN
    RAISE EXCEPTION 'exos_discovery_queue: only upcoming published events can be listed' USING ERRCODE = '22023';
  END IF;
  -- Free-tier cap: only a channel this event isn't already using counts.
  -- Serialize per event so two queue calls can't both take the last slot.
  PERFORM pg_advisory_xact_lock(hashtextextended('exos_discovery_queue:' || p_event_id::text, 0));
  v_cap := public._exos_discovery_manual_cap(p_event_id);
  IF v_cap IS NOT NULL
     AND NOT EXISTS (SELECT 1 FROM public.exos_discovery_publications
                      WHERE event_id = p_event_id AND channel_id = v_ch.id AND status <> 'not_submitted')
     AND public._exos_discovery_manual_used(p_event_id) >= v_cap THEN
    RAISE EXCEPTION 'exos_discovery_queue: free-tier events (capacity % or less) can go to at most % listing sites, and this one already uses %. Withdraw one to queue another.',
      public._exos_discovery_free_tier_max(), v_cap, v_cap USING ERRCODE = 'P0001';
  END IF;

  INSERT INTO public.exos_discovery_publications AS p
    (event_id, org_id, channel_id, status, note, next_action, queued_at, queued_by, updated_by)
  VALUES (p_event_id, v_org, v_ch.id, 'queued', v_note, 'Submit on ' || v_ch.name, now(), auth.uid(), auth.uid())
  ON CONFLICT (event_id, channel_id) DO UPDATE SET
    status = 'queued', note = coalesce(EXCLUDED.note, p.note), next_action = EXCLUDED.next_action,
    live_url = NULL, rejection_reason = NULL, submitted_at = NULL, submitted_by = NULL,
    decided_at = NULL, decided_by = NULL,
    queued_at = now(), queued_by = auth.uid(), updated_at = now(), updated_by = auth.uid()
  WHERE p.status IN ('not_submitted', 'rejected', 'removed');

  SELECT * INTO v_row FROM public.exos_discovery_publications WHERE event_id = p_event_id AND channel_id = v_ch.id;
  RETURN public._exos_discovery_row(v_row);
END $$;
REVOKE ALL ON FUNCTION public.exos_discovery_queue(uuid, text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.exos_discovery_queue(uuid, text, text) TO authenticated;

-- Take a queued event back out of the queue (before anyone submitted it).
CREATE OR REPLACE FUNCTION public.exos_discovery_withdraw(p_event_id uuid, p_channel_id text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp AS $$
DECLARE
  v_org uuid := public._exos_discovery_writer(p_event_id, 'exos_discovery_withdraw');
  v_row public.exos_discovery_publications%ROWTYPE;
BEGIN
  UPDATE public.exos_discovery_publications
     SET status = 'not_submitted', next_action = NULL, updated_at = now(), updated_by = auth.uid()
   WHERE event_id = p_event_id AND channel_id = p_channel_id AND status = 'queued'
  RETURNING * INTO v_row;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'exos_discovery_withdraw: nothing queued for this channel' USING ERRCODE = '22023';
  END IF;
  RETURN public._exos_discovery_row(v_row);
END $$;
REVOKE ALL ON FUNCTION public.exos_discovery_withdraw(uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.exos_discovery_withdraw(uuid, text) TO authenticated;

-- Record what happened on the channel:
--   queued    -> submitted | live | rejected
--   submitted -> live | rejected
--   live      -> removed
-- live needs the listing's https URL; rejected needs the reason. Recording
-- the status a row already has (same URL / reason) is a no-op.
CREATE OR REPLACE FUNCTION public.exos_discovery_set_status(
  p_publication_id uuid, p_status text,
  p_live_url text DEFAULT NULL, p_reason text DEFAULT NULL, p_next_action text DEFAULT NULL,
  p_minutes integer DEFAULT NULL
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp AS $$
DECLARE
  v_row    public.exos_discovery_publications%ROWTYPE;
  v_url    text := nullif(btrim(coalesce(p_live_url, '')), '');
  v_reason text := nullif(btrim(coalesce(p_reason, '')), '');
  v_next   text := nullif(btrim(coalesce(p_next_action, '')), '');
  v_ok     boolean;
BEGIN
  SELECT * INTO v_row FROM public.exos_discovery_publications WHERE id = p_publication_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'exos_discovery_set_status: not authorized' USING ERRCODE = '42501';
  END IF;
  PERFORM public._exos_discovery_writer(v_row.event_id, 'exos_discovery_set_status');

  IF p_status = 'live' AND (v_url IS NULL OR v_url !~ '^https://[^[:space:]]+$' OR length(v_url) > 2000) THEN
    RAISE EXCEPTION 'exos_discovery_set_status: live needs the listing''s https URL' USING ERRCODE = '22023';
  END IF;
  IF p_status = 'rejected' AND (v_reason IS NULL OR length(v_reason) > 500) THEN
    RAISE EXCEPTION 'exos_discovery_set_status: rejected needs a reason (up to 500 characters)' USING ERRCODE = '22023';
  END IF;
  IF v_next IS NOT NULL AND length(v_next) > 500 THEN
    RAISE EXCEPTION 'exos_discovery_set_status: next action is up to 500 characters' USING ERRCODE = '22023';
  END IF;
  IF p_minutes IS NOT NULL AND (p_minutes < 0 OR p_minutes > 600) THEN
    RAISE EXCEPTION 'exos_discovery_set_status: minutes is 0 to 600 per step' USING ERRCODE = '22023';
  END IF;
  IF p_minutes IS NOT NULL AND p_status NOT IN ('submitted', 'live', 'rejected') THEN
    RAISE EXCEPTION 'exos_discovery_set_status: minutes are logged with submitted, live or rejected' USING ERRCODE = '22023';
  END IF;

  IF v_row.status = p_status
     AND (p_status <> 'live' OR v_row.live_url = v_url)
     AND (p_status <> 'rejected' OR v_row.rejection_reason = v_reason) THEN
    -- Same status again: only extra minutes are recorded.
    IF coalesce(p_minutes, 0) > 0 THEN
      UPDATE public.exos_discovery_publications
         SET minutes_spent = least(minutes_spent + p_minutes, 100000), updated_at = now(), updated_by = auth.uid()
       WHERE id = v_row.id RETURNING * INTO v_row;
    END IF;
    RETURN public._exos_discovery_row(v_row);
  END IF;
  v_ok := (v_row.status = 'queued' AND p_status IN ('submitted', 'live', 'rejected'))
       OR (v_row.status = 'submitted' AND p_status IN ('live', 'rejected'))
       OR (v_row.status = 'live' AND p_status IN ('live', 'removed'));   -- live -> live: a corrected URL
  IF NOT v_ok THEN
    RAISE EXCEPTION 'exos_discovery_set_status: can''t go from % to %', v_row.status, coalesce(p_status, 'null') USING ERRCODE = '22023';
  END IF;

  UPDATE public.exos_discovery_publications SET
    status           = p_status,
    live_url         = CASE WHEN p_status = 'live' THEN v_url WHEN p_status = 'removed' THEN live_url ELSE NULL END,
    rejection_reason = CASE WHEN p_status = 'rejected' THEN v_reason ELSE NULL END,
    next_action      = coalesce(v_next, CASE p_status
                         WHEN 'submitted' THEN 'Check the listing went up'
                         WHEN 'rejected'  THEN 'Fix and queue again, or leave it'
                         ELSE NULL END),
    submitted_at     = CASE WHEN p_status = 'submitted' THEN now() ELSE submitted_at END,
    submitted_by     = CASE WHEN p_status = 'submitted' THEN auth.uid() ELSE submitted_by END,
    decided_at       = CASE WHEN p_status IN ('live', 'rejected', 'removed') THEN now() ELSE decided_at END,
    decided_by       = CASE WHEN p_status IN ('live', 'rejected', 'removed') THEN auth.uid() ELSE decided_by END,
    minutes_spent    = least(minutes_spent + coalesce(p_minutes, 0), 100000),
    updated_at       = now(),
    updated_by       = auth.uid()
  WHERE id = v_row.id
  RETURNING * INTO v_row;
  RETURN public._exos_discovery_row(v_row);
END $$;
REVOKE ALL ON FUNCTION public.exos_discovery_set_status(uuid, text, text, text, text, integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.exos_discovery_set_status(uuid, text, text, text, text, integer) TO authenticated;

-- ---------------------------------------------------------------------------
-- 5. Reads
-- ---------------------------------------------------------------------------
-- Copy-ready event fields + public ticket types (the feeds' own columns).
-- Picked by name from to_jsonb(e), so a column a database doesn't have yet
-- is just absent (the TypeScript treats every one as optional).
CREATE OR REPLACE FUNCTION public._exos_discovery_event_json(p_event_id uuid)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp AS $$
  SELECT (SELECT coalesce(jsonb_object_agg(k.key, k.value), '{}'::jsonb)
            FROM jsonb_each(to_jsonb(e)) k
           WHERE k.key = ANY (ARRAY['id', 'slug', 'org_id', 'name', 'status', 'starts_at', 'doors_at', 'ends_at',
                                    'timezone', 'currency', 'venue_address', 'primary_performer_name', 'performer_names',
                                    'category', 'genres', 'image_url', 'tickets_sold', 'description', 'summary',
                                    'description_md', 'lineup', 'min_age', 'format', 'noindex']))
    || jsonb_build_object(
    'venue_name', coalesce(e.venue_name, e.venue_location),
    'org_name', o.name, 'org_slug', o.slug,
    'tiers', coalesce((
      SELECT jsonb_agg(jsonb_build_object(
               'id', t.id, 'event_id', t.event_id, 'name', t.name, 'description', t.description,
               'price', t.price, 'capacity', t.capacity, 'sold', t.sold,
               'sales_start', t.sales_start, 'sales_end', t.sales_end, 'price_schedule', t.price_schedule,
               'exclusive_tax_percent', public.exos_tier_exclusive_tax_percent(t.id))
             ORDER BY t.sort_order, t.id)
        FROM public.exos_ticket_tiers t
       WHERE t.event_id = e.id AND t.visibility = 'public'), '[]'::jsonb))
  FROM public.exos_events e JOIN public.exos_orgs o ON o.id = e.org_id
  WHERE e.id = p_event_id
$$;
REVOKE ALL ON FUNCTION public._exos_discovery_event_json(uuid) FROM PUBLIC, anon, authenticated;

-- The calendar feed's verdict for one event: is it in its org's .ics?
CREATE OR REPLACE FUNCTION public._exos_discovery_calendar_status(p_event_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp AS $$
DECLARE
  v_ev   record;
  v_feed jsonb;
BEGIN
  SELECT e.status, e.noindex, e.tickets_sold, e.starts_at, o.slug INTO v_ev
    FROM public.exos_events e JOIN public.exos_orgs o ON o.id = e.org_id WHERE e.id = p_event_id;
  IF v_ev.slug IS NOT NULL THEN
    v_feed := public.exos_calendar_public_feed('org', v_ev.slug);
    IF v_feed IS NOT NULL AND (v_feed -> 'events') @> jsonb_build_array(jsonb_build_object('id', p_event_id)) THEN
      RETURN jsonb_build_object('status', 'live', 'reason', NULL);
    END IF;
  END IF;
  -- Not in it: say why (explanatory only; the feed decided).
  RETURN jsonb_build_object('status', 'not_eligible', 'reason', CASE
    WHEN v_ev.slug IS NULL THEN 'the organizer has no page address (slug), so no calendar'
    WHEN v_ev.status = 'draft' THEN 'not published'
    WHEN v_ev.status = 'cancelled' AND NOT coalesce(v_ev.tickets_sold, 0) > 0 THEN 'cancelled before any sale'
    WHEN v_ev.noindex THEN 'hidden from search by the organizer'
    WHEN v_ev.starts_at IS NULL THEN 'no start time'
    WHEN v_ev.starts_at < now() - interval '30 days' THEN 'more than 30 days ago'
    ELSE 'outside the calendar''s 500 events' END);
END $$;
REVOKE ALL ON FUNCTION public._exos_discovery_calendar_status(uuid) FROM PUBLIC, anon, authenticated;

-- Organizer screen: the event (with public tiers, for the TypeScript feed
-- rules), every active channel, its publication record, and the calendar
-- verdict. Owner / manager / finance of the event's org, or admin.
CREATE OR REPLACE FUNCTION public.exos_discovery_event_channels(p_event_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp AS $$
DECLARE v_org uuid;
BEGIN
  SELECT e.org_id INTO v_org FROM public.exos_events e WHERE e.id = p_event_id;
  IF v_org IS NULL
     OR NOT (public.exos_is_admin() OR public.exos_has_org_role(v_org, ARRAY['owner', 'manager', 'finance'])) THEN
    RAISE EXCEPTION 'exos_discovery_event_channels: not authorized' USING ERRCODE = '42501';
  END IF;
  RETURN jsonb_build_object(
    'event', public._exos_discovery_event_json(p_event_id),
    'calendar', public._exos_discovery_calendar_status(p_event_id),
    'can_edit', public.exos_is_admin() OR public.exos_has_org_role(v_org, ARRAY['owner', 'manager']),
    'manual_cap', public._exos_discovery_manual_cap(p_event_id),
    'manual_used', public._exos_discovery_manual_used(p_event_id),
    'minutes_spent', (SELECT coalesce(sum(p.minutes_spent), 0) FROM public.exos_discovery_publications p WHERE p.event_id = p_event_id),
    'channels', coalesce((
      SELECT jsonb_agg(jsonb_build_object(
               'id', c.id, 'name', c.name, 'kind', c.kind, 'region', c.region,
               'submission_url', c.submission_url, 'verified', c.verified,
               'publication', CASE WHEN p.id IS NULL THEN NULL ELSE public._exos_discovery_row(p) END)
             ORDER BY c.sort_order, c.id)
        FROM public.exos_discovery_channels c
        LEFT JOIN public.exos_discovery_publications p ON p.channel_id = c.id AND p.event_id = p_event_id
       WHERE c.active), '[]'::jsonb));
END $$;
REVOKE ALL ON FUNCTION public.exos_discovery_event_channels(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.exos_discovery_event_channels(uuid) TO authenticated;

-- Operator queue, across orgs: publications in a status (default queued),
-- optionally one channel, oldest first, with the copy-ready event. Admin only.
CREATE OR REPLACE FUNCTION public.exos_discovery_queue_list(
  p_status text DEFAULT 'queued', p_channel_id text DEFAULT NULL, p_limit integer DEFAULT 100
) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp AS $$
BEGIN
  IF NOT public.exos_is_admin() THEN
    RAISE EXCEPTION 'exos_discovery_queue_list: operator only' USING ERRCODE = '42501';
  END IF;
  IF p_status IS NULL OR p_status NOT IN ('queued', 'submitted', 'live', 'rejected', 'removed', 'not_submitted') THEN
    RAISE EXCEPTION 'exos_discovery_queue_list: unknown status' USING ERRCODE = '22023';
  END IF;
  RETURN coalesce((
    SELECT jsonb_agg(x.j ORDER BY x.k, x.id) FROM (
      SELECT p.id, coalesce(p.queued_at, p.updated_at) AS k,
             public._exos_discovery_row(p)
               || jsonb_build_object('channel_name', c.name, 'submission_url', c.submission_url,
                                     'event', public._exos_discovery_event_json(p.event_id)) AS j
        FROM public.exos_discovery_publications p
        JOIN public.exos_discovery_channels c ON c.id = p.channel_id
       WHERE p.status = p_status AND (p_channel_id IS NULL OR p.channel_id = p_channel_id)
       ORDER BY coalesce(p.queued_at, p.updated_at), p.id
       LIMIT greatest(1, least(coalesce(p_limit, 100), 500))) x), '[]'::jsonb);
END $$;
REVOKE ALL ON FUNCTION public.exos_discovery_queue_list(text, text, integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.exos_discovery_queue_list(text, text, integer) TO authenticated;

-- Manual minutes for the discovery pilot: per event (with the minutes per
-- channel) and the org total, over records updated in [p_since, p_until).
-- Owner / manager / finance of the org, or admin. With p_org_id NULL (admin
-- only) every org, one entry each.
CREATE OR REPLACE FUNCTION public.exos_discovery_minutes(
  p_org_id uuid DEFAULT NULL, p_since timestamptz DEFAULT NULL, p_until timestamptz DEFAULT NULL
) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp AS $$
DECLARE v_admin boolean := public.exos_is_admin();
BEGIN
  IF p_org_id IS NULL AND NOT v_admin THEN
    RAISE EXCEPTION 'exos_discovery_minutes: operator only' USING ERRCODE = '42501';
  END IF;
  IF p_org_id IS NOT NULL AND NOT (v_admin OR public.exos_has_org_role(p_org_id, ARRAY['owner', 'manager', 'finance'])) THEN
    RAISE EXCEPTION 'exos_discovery_minutes: not authorized' USING ERRCODE = '42501';
  END IF;
  RETURN coalesce((
    SELECT jsonb_agg(o.j ORDER BY o.total DESC, o.org_id) FROM (
      SELECT ev.org_id, sum(ev.minutes) AS total,
             jsonb_build_object('org_id', ev.org_id, 'org_name', max(ev.org_name),
               'minutes', sum(ev.minutes), 'events', count(*), 'submissions', sum(ev.submissions),
               'minutes_per_event', round(sum(ev.minutes)::numeric / count(*), 1),
               'by_event', jsonb_agg(jsonb_build_object('event_id', ev.event_id, 'name', ev.name, 'starts_at', ev.starts_at,
                                       'minutes', ev.minutes, 'submissions', ev.submissions, 'channels', ev.channels)
                                     ORDER BY ev.starts_at, ev.event_id)) AS j
        FROM (
          SELECT p.org_id, o.name AS org_name, p.event_id, e.name, e.starts_at,
                 sum(p.minutes_spent)::int AS minutes,
                 (count(*) FILTER (WHERE p.status IN ('submitted', 'live', 'rejected', 'removed')))::int AS submissions,
                 jsonb_object_agg(p.channel_id, p.minutes_spent) AS channels
            FROM public.exos_discovery_publications p
            JOIN public.exos_events e ON e.id = p.event_id
            JOIN public.exos_orgs o ON o.id = p.org_id
           WHERE (p_org_id IS NULL OR p.org_id = p_org_id)
             AND (p_since IS NULL OR p.updated_at >= p_since)
             AND (p_until IS NULL OR p.updated_at < p_until)
             AND p.status <> 'not_submitted'
           GROUP BY p.org_id, o.name, p.event_id, e.name, e.starts_at) ev
       GROUP BY ev.org_id) o), '[]'::jsonb);
END $$;
REVOKE ALL ON FUNCTION public.exos_discovery_minutes(uuid, timestamptz, timestamptz) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.exos_discovery_minutes(uuid, timestamptz, timestamptz) TO authenticated;

-- ROLLBACK (manual): drop the thirteen functions, then exos_discovery_publications
-- and exos_discovery_channels.
