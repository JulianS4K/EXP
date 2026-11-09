-- ============================================================================
-- Posh "Third-Party Links" as a discovery channel (posh_link)
-- ============================================================================
-- Touches:  W: exos_discovery_channels (+ seed row posh_link; mirrored by
--              supabase/functions/_shared/discovery/channels.ts)
--           C: TABLE exos_discovery_posh_stats (organizer-entered Posh page
--              views + ticket-link clicks, several readings per listing)
--           C: FUNCTION exos_posh_link_record_stats, exos_posh_link_delete_stats
--              (owner / manager of the event's org, or admin),
--              exos_posh_link_funnel (owner / manager / finance, or admin);
--              _exos_posh_link_blocked, _exos_posh_link_facts (no client grant)
--           W: FUNCTION exos_discovery_queue (patched in place, marker
--              _exos_posh_link_blocked: posh_link refused for link-out events)
--           W: FUNCTION exos_discovery_event_channels (patched in place, marker
--              _exos_posh_link_facts: + 'posh_link' facts for the Promote page)
--           R: exos_events, exos_event_imports, exos_posh_hooks,
--              exos_posh_event_links, exos_posh_caps, exos_posh_orders,
--              exos_checkout_sessions, exos_order_refunds, exos_tickets
-- Pre-reqs: 20261029130000 (discovery publishing), 20261029150000 (Posh
--           webhooks), 20261029170500 (link-out events), 20260924223000
--           (checkout attribution)
--
-- What Posh shipped (2026-10-05): "Third-Party Links" gives an event a Posh
-- page whose Get Tickets button opens an external ticket page. Free to list,
-- created on Posh web only (Create Event -> External tickets, next to Sell
-- tickets and RSVP). Posh counts page views and ticket-link clicks on its side.
--
-- There is no Posh API for it. The organizer makes the Posh page by hand in
-- their own Posh account and pastes the Exos ticket link (utm_source=posh_link,
-- utm_medium=listing, utm_campaign=discovery) as the external URL. Exos never
-- writes to Posh; nothing here calls a third party.
--
--   * posh_link is a manual, organizer-account, global channel. It goes
--     through the same queue -> submitted -> live records as RA or Meetup, so
--     it counts toward the free tier's 5 manual channels like any other.
--   * A link-out event (exos_events.link_out: sold on Posh, Eventbrite or
--     Luma) can't use it: a Posh-sold event already has a Posh page, and a
--     Posh page that sends buyers to Exos, which only links on, is a detour.
--     exos_discovery_queue refuses it with a message saying why.
--   * An event with Posh webhooks connected (an active hook for the org and
--     the event linked, capped or with Posh orders) only gets a warning on
--     the Promote page: third-party link mode is for events sold on Exos.
--   * Stats: once the listing is live (or removed), the organizer records
--     Posh's own page views and ticket-link clicks as of a date, as many
--     readings as they like (one per day; recording a day again replaces it).
--     exos_posh_link_funnel returns the readings with the Exos orders whose
--     checkout carried utm_source=posh_link; the rates are worked out in
--     src/lib/discovery/poshLink.ts.
--
-- Additive and re-run safe. Prod apply needs operator OK.
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

-- ---------------------------------------------------------------------------
-- 1. The channel
-- ---------------------------------------------------------------------------
-- Keep in step with DISCOVERY_CHANNELS (channels.ts); a vitest compares them.
-- No Posh help page for Third-Party Links was found from the build session,
-- so the link is the site and it is not verified.
INSERT INTO public.exos_discovery_channels (id, name, kind, region, submission_url, verified, sort_order) VALUES
  ('posh_link',        'Posh (third-party link)',   'manual', 'global', 'https://posh.vip', false, 190)
ON CONFLICT (id) DO UPDATE SET
  name = EXCLUDED.name, kind = EXCLUDED.kind, region = EXCLUDED.region,
  submission_url = EXCLUDED.submission_url, verified = EXCLUDED.verified, sort_order = EXCLUDED.sort_order;

-- ---------------------------------------------------------------------------
-- 2. Eligibility helpers (no client grant)
-- ---------------------------------------------------------------------------
-- Why this event can't use posh_link (NULL = it can). Mirrored by
-- poshLinkEligibility (src/lib/discovery/poshLink.ts).
CREATE OR REPLACE FUNCTION public._exos_posh_link_blocked(p_event_id uuid)
RETURNS text LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp AS $$
  SELECT CASE
           WHEN NOT coalesce(e.link_out, false) THEN NULL
           WHEN coalesce(i.platform, e.ticket_backend) = 'posh'
             THEN 'this event is sold on Posh, so it already has a Posh page. Posh (third-party link) is for events sold on Exos.'
           ELSE 'this event is sold on '
                || CASE coalesce(i.platform, e.ticket_backend) WHEN 'eventbrite' THEN 'Eventbrite' WHEN 'luma' THEN 'Luma'
                                                                ELSE 'another platform' END
                || ' (a link-out event), so Posh (third-party link) isn''t offered: it is for events sold on Exos.'
         END
    FROM public.exos_events e
    LEFT JOIN public.exos_event_imports i ON i.event_id = e.id
   WHERE e.id = p_event_id
$$;
REVOKE ALL ON FUNCTION public._exos_posh_link_blocked(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_posh_link_blocked(uuid) TO service_role;

-- The facts the Promote page needs to offer, refuse or warn.
CREATE OR REPLACE FUNCTION public._exos_posh_link_facts(p_event_id uuid)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp AS $$
  SELECT jsonb_build_object(
    'link_out', coalesce(e.link_out, false),
    'link_out_platform', CASE WHEN coalesce(e.link_out, false) THEN coalesce(i.platform, e.ticket_backend) END,
    'ticket_backend', e.ticket_backend,
    'posh_webhooks', EXISTS (
      SELECT 1 FROM public.exos_posh_hooks h
       WHERE h.org_id = e.org_id AND h.status = 'active'
         AND (EXISTS (SELECT 1 FROM public.exos_posh_event_links l WHERE l.event_id = e.id)
              OR EXISTS (SELECT 1 FROM public.exos_posh_caps c WHERE c.event_id = e.id)
              OR EXISTS (SELECT 1 FROM public.exos_posh_orders o WHERE o.event_id = e.id))),
    'blocked', public._exos_posh_link_blocked(e.id))
    FROM public.exos_events e
    LEFT JOIN public.exos_event_imports i ON i.event_id = e.id
   WHERE e.id = p_event_id
$$;
REVOKE ALL ON FUNCTION public._exos_posh_link_facts(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_posh_link_facts(uuid) TO service_role;

-- exos_discovery_queue: refuse posh_link for a link-out event.
SELECT pg_temp.exos_patch_n('public.exos_discovery_queue(uuid,text,text)', '_exos_posh_link_blocked',
$o$  IF v_note IS NOT NULL AND length(v_note) > 1000 THEN
$o$,
$n$  IF v_ch.id = 'posh_link' AND public._exos_posh_link_blocked(p_event_id) IS NOT NULL THEN
    RAISE EXCEPTION 'exos_discovery_queue: %', public._exos_posh_link_blocked(p_event_id) USING ERRCODE = '22023';
  END IF;
  IF v_note IS NOT NULL AND length(v_note) > 1000 THEN
$n$, 1);

-- exos_discovery_event_channels: + the posh_link facts.
SELECT pg_temp.exos_patch_n('public.exos_discovery_event_channels(uuid)', '_exos_posh_link_facts',
$o$    'minutes_spent', (SELECT$o$,
$n$    'posh_link', public._exos_posh_link_facts(p_event_id),
    'minutes_spent', (SELECT$n$, 1);

-- ---------------------------------------------------------------------------
-- 3. Organizer-entered Posh stats
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.exos_discovery_posh_stats (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  publication_id uuid NOT NULL REFERENCES public.exos_discovery_publications (id) ON DELETE CASCADE,
  event_id       uuid NOT NULL REFERENCES public.exos_events (id) ON DELETE CASCADE,
  org_id         uuid NOT NULL REFERENCES public.exos_orgs (id) ON DELETE CASCADE,
  -- Posh's own totals as of this day (cumulative, as Posh shows them).
  as_of          date NOT NULL,
  page_views     integer NOT NULL CHECK (page_views BETWEEN 0 AND 100000000),
  link_clicks    integer NOT NULL CHECK (link_clicks BETWEEN 0 AND 100000000),
  created_by     uuid REFERENCES auth.users (id) ON DELETE SET NULL,
  created_at     timestamptz NOT NULL DEFAULT now(),
  updated_by     uuid REFERENCES auth.users (id) ON DELETE SET NULL,
  updated_at     timestamptz NOT NULL DEFAULT now(),
  UNIQUE (publication_id, as_of)
);
CREATE INDEX IF NOT EXISTS exos_discovery_posh_stats_event_idx ON public.exos_discovery_posh_stats (event_id, as_of);
CREATE INDEX IF NOT EXISTS exos_discovery_posh_stats_org_idx ON public.exos_discovery_posh_stats (org_id);
ALTER TABLE public.exos_discovery_posh_stats ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS exos_discovery_posh_stats_read ON public.exos_discovery_posh_stats;
CREATE POLICY exos_discovery_posh_stats_read ON public.exos_discovery_posh_stats
  FOR SELECT TO authenticated
  USING ((SELECT public.exos_is_admin())
         OR public.exos_has_org_role(org_id, ARRAY['owner', 'manager', 'finance']));
-- Writes only through the RPCs below.
REVOKE ALL ON public.exos_discovery_posh_stats FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.exos_discovery_posh_stats TO authenticated;
GRANT ALL ON public.exos_discovery_posh_stats TO service_role;
DROP TRIGGER IF EXISTS exos_discovery_posh_stats_touch ON public.exos_discovery_posh_stats;
CREATE TRIGGER exos_discovery_posh_stats_touch BEFORE UPDATE ON public.exos_discovery_posh_stats
  FOR EACH ROW EXECUTE FUNCTION public.exos_touch_updated_at();
COMMENT ON TABLE public.exos_discovery_posh_stats IS
  'Posh (third-party link) page views and ticket-link clicks as the organizer read them on Posh, one reading per listing per day. Written by exos_posh_link_record_stats / exos_posh_link_delete_stats only. mig 20261104150000.';

CREATE OR REPLACE FUNCTION public._exos_posh_stat_row(s public.exos_discovery_posh_stats)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp AS $$
  SELECT jsonb_build_object('id', s.id, 'publication_id', s.publication_id, 'event_id', s.event_id,
                            'as_of', s.as_of, 'page_views', s.page_views, 'link_clicks', s.link_clicks,
                            'updated_at', s.updated_at)
$$;
REVOKE ALL ON FUNCTION public._exos_posh_stat_row(public.exos_discovery_posh_stats) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_posh_stat_row(public.exos_discovery_posh_stats) TO service_role;

-- Record Posh's numbers for a live (or removed) posh_link listing. One
-- reading per day: recording the same day again replaces it.
CREATE OR REPLACE FUNCTION public.exos_posh_link_record_stats(
  p_publication_id uuid, p_as_of date, p_page_views integer, p_link_clicks integer
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp AS $$
DECLARE
  v_pub public.exos_discovery_publications%ROWTYPE;
  v_row public.exos_discovery_posh_stats%ROWTYPE;
BEGIN
  -- Lock the listing so a status change can't race the reading.
  SELECT * INTO v_pub FROM public.exos_discovery_publications WHERE id = p_publication_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'exos_posh_link_record_stats: not authorized' USING ERRCODE = '42501';
  END IF;
  PERFORM public._exos_discovery_writer(v_pub.event_id, 'exos_posh_link_record_stats');
  IF v_pub.channel_id <> 'posh_link' THEN
    RAISE EXCEPTION 'exos_posh_link_record_stats: Posh stats are only for the Posh (third-party link) listing' USING ERRCODE = '22023';
  END IF;
  IF v_pub.status NOT IN ('live', 'removed') THEN
    RAISE EXCEPTION 'exos_posh_link_record_stats: mark the Posh page live first' USING ERRCODE = '22023';
  END IF;
  IF p_page_views IS NULL OR p_link_clicks IS NULL OR p_page_views < 0 OR p_link_clicks < 0
     OR p_page_views > 100000000 OR p_link_clicks > 100000000 THEN
    RAISE EXCEPTION 'exos_posh_link_record_stats: views and clicks are whole numbers from 0' USING ERRCODE = '22023';
  END IF;
  -- Posh launched Third-Party Links on 2026-10-05; a day ahead of UTC allows
  -- for the organizer's time zone.
  IF p_as_of IS NULL OR p_as_of < date '2026-10-05' OR p_as_of > (now() AT TIME ZONE 'UTC')::date + 1 THEN
    RAISE EXCEPTION 'exos_posh_link_record_stats: the "as of" date must be a day from 2026-10-05 to today' USING ERRCODE = '22023';
  END IF;

  INSERT INTO public.exos_discovery_posh_stats AS s
    (publication_id, event_id, org_id, as_of, page_views, link_clicks, created_by, updated_by)
  VALUES (v_pub.id, v_pub.event_id, v_pub.org_id, p_as_of, p_page_views, p_link_clicks, auth.uid(), auth.uid())
  ON CONFLICT (publication_id, as_of) DO UPDATE SET
    page_views = EXCLUDED.page_views, link_clicks = EXCLUDED.link_clicks, updated_by = auth.uid()
  RETURNING * INTO v_row;
  RETURN public._exos_posh_stat_row(v_row);
END $$;
REVOKE ALL ON FUNCTION public.exos_posh_link_record_stats(uuid, date, integer, integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.exos_posh_link_record_stats(uuid, date, integer, integer) TO authenticated, service_role;

-- Remove a reading entered by mistake.
CREATE OR REPLACE FUNCTION public.exos_posh_link_delete_stats(p_stat_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp AS $$
DECLARE v_row public.exos_discovery_posh_stats%ROWTYPE;
BEGIN
  SELECT * INTO v_row FROM public.exos_discovery_posh_stats WHERE id = p_stat_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'exos_posh_link_delete_stats: not authorized' USING ERRCODE = '42501';
  END IF;
  PERFORM public._exos_discovery_writer(v_row.event_id, 'exos_posh_link_delete_stats');
  DELETE FROM public.exos_discovery_posh_stats WHERE id = v_row.id;
  RETURN jsonb_build_object('id', v_row.id, 'deleted', true);
END $$;
REVOKE ALL ON FUNCTION public.exos_posh_link_delete_stats(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.exos_posh_link_delete_stats(uuid) TO authenticated, service_role;

-- The funnel's inputs for one event: the listing, Posh's readings (oldest
-- first) and the Exos orders whose checkout carried utm_source=posh_link
-- (fulfilled or partly refunded; tickets still valid; money net of refunds,
-- integer cents). Owner / manager / finance of the event's org, or admin.
CREATE OR REPLACE FUNCTION public.exos_posh_link_funnel(p_event_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp AS $$
DECLARE
  v_org uuid;
  v_pub public.exos_discovery_publications%ROWTYPE;
  v_exos jsonb;
BEGIN
  SELECT e.org_id INTO v_org FROM public.exos_events e WHERE e.id = p_event_id;
  IF v_org IS NULL
     OR NOT (public.exos_is_admin() OR public.exos_has_org_role(v_org, ARRAY['owner', 'manager', 'finance'])) THEN
    RAISE EXCEPTION 'exos_posh_link_funnel: not authorized' USING ERRCODE = '42501';
  END IF;
  SELECT * INTO v_pub FROM public.exos_discovery_publications WHERE event_id = p_event_id AND channel_id = 'posh_link';

  SELECT jsonb_build_object(
           'orders', count(*),
           'tickets', coalesce(sum(x.live), 0),
           'gross_cents', coalesce(sum(x.amount_cents - x.refunded), 0),
           'currency', coalesce(min(x.currency), (SELECT lower(coalesce(nullif(e.currency, ''), 'usd')) FROM public.exos_events e WHERE e.id = p_event_id)))
    INTO v_exos
    FROM (
      SELECT s.amount_cents, lower(coalesce(nullif(s.currency, ''), 'usd')) AS currency,
             (SELECT count(*) FROM public.exos_tickets t
               WHERE t.order_ref = s.session_id AND t.event_id = s.event_id AND t.status <> 'voided')::int AS live,
             coalesce((SELECT sum(rf.amount_cents) FROM public.exos_order_refunds rf
                        WHERE rf.session_id = s.session_id AND rf.status = 'succeeded'), 0)::bigint AS refunded
        FROM public.exos_checkout_sessions s
       WHERE s.event_id = p_event_id
         AND s.status IN ('fulfilled', 'partially_refunded')
         AND lower(s.attribution ->> 'utm_source') = 'posh_link') x;

  RETURN jsonb_build_object(
    'event_id', p_event_id,
    'publication', CASE WHEN v_pub.id IS NULL THEN NULL ELSE public._exos_discovery_row(v_pub) END,
    'readings', coalesce((
      SELECT jsonb_agg(public._exos_posh_stat_row(s) ORDER BY s.as_of, s.id)
        FROM public.exos_discovery_posh_stats s WHERE s.event_id = p_event_id), '[]'::jsonb),
    'exos', v_exos);
END $$;
REVOKE ALL ON FUNCTION public.exos_posh_link_funnel(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.exos_posh_link_funnel(uuid) TO authenticated, service_role;

-- ROLLBACK (manual): drop the seven functions above and exos_discovery_posh_stats,
-- delete the posh_link publications and channel row, and re-run
-- 20261029130000 to restore exos_discovery_queue / exos_discovery_event_channels.
