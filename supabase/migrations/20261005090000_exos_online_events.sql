-- ============================================================================
-- Migration 20261005090000 — Exos (Bridge / D4): online + hybrid events,
-- "what to bring", per-event noindex
--
-- Lane:     d4 (exos / bridge ticketing infra)
-- Touches:  W: exos_events (+format, +what_to_bring, +noindex)
--              TABLE exos_event_online (new, private join link per event)
--              FUNCTION exos_set_event_online, exos_event_online_staff,
--                       exos_event_online_access (new)
--              VIEW exos_public_events (columns appended in place)
-- Pre-reqs: 20260929120000 (store content + the view-append pattern)
--
-- What organizers get:
--   * format: in_person (default), online or hybrid. The event page, the
--     Google feed and structured data say how people attend.
--   * A private join link (stream, Zoom, Discord ...) with a short note and
--     an optional "show it N minutes before the start". It lives in its own
--     table with no grants at all: nobody reads it except through
--     exos_event_online_access, which hands it to people holding an active
--     or used ticket for the event (and to the organizer's staff).
--   * what_to_bring: a short public note ("Photo ID, no bags over 12x12")
--     shown on the event page, the ticket and the order confirmation.
--   * noindex: keep the event out of search engines, the sitemap and the
--     public feeds (private parties, test events). The page still opens for
--     anyone with the link; this is not access control.
--
-- Re-run safe. D4 authors; applying to prod is operator-gated.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. Public columns on exos_events
-- ---------------------------------------------------------------------------
ALTER TABLE public.exos_events
  ADD COLUMN IF NOT EXISTS format        text    NOT NULL DEFAULT 'in_person',
  ADD COLUMN IF NOT EXISTS what_to_bring text,
  ADD COLUMN IF NOT EXISTS noindex       boolean NOT NULL DEFAULT false;

DO $$
DECLARE
  r record;
BEGIN
  FOR r IN SELECT * FROM (VALUES
      ('exos_events_format_chk',
       $c$format IN ('in_person', 'online', 'hybrid')$c$),
      ('exos_events_what_to_bring_chk',
       'what_to_bring IS NULL OR char_length(what_to_bring) <= 500')) AS v(name, expr)
  LOOP
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conname = r.name AND conrelid = 'public.exos_events'::regclass) THEN
      EXECUTE format('ALTER TABLE public.exos_events ADD CONSTRAINT %I CHECK (%s)', r.name, r.expr);
    END IF;
  END LOOP;
END $$;

GRANT SELECT (format, what_to_bring, noindex) ON public.exos_events TO anon, authenticated;
GRANT INSERT (format, what_to_bring, noindex),
      UPDATE (format, what_to_bring, noindex)
  ON public.exos_events TO authenticated;

-- ---------------------------------------------------------------------------
-- 2. Private join link (one row per event, RPC access only)
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.exos_event_online (
  event_id       uuid PRIMARY KEY REFERENCES public.exos_events(id) ON DELETE CASCADE,
  join_url       text NOT NULL
                 CHECK (char_length(join_url) <= 1000 AND join_url ~ '^https://[^\s"<>]+$'),
  join_note      text CHECK (join_note IS NULL OR char_length(join_note) <= 500),
  reveal_minutes integer CHECK (reveal_minutes IS NULL OR reveal_minutes BETWEEN 0 AND 10080),
  updated_by     uuid,
  updated_at     timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.exos_event_online ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.exos_event_online FROM PUBLIC, anon, authenticated;
GRANT ALL ON public.exos_event_online TO service_role;

-- Owner / manager (or admin) for the event's org.
CREATE OR REPLACE FUNCTION public._exos_can_edit_event(p_event_id uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.exos_events e
     WHERE e.id = p_event_id
       AND (public.exos_is_admin() OR public.exos_has_org_role(e.org_id, ARRAY['owner', 'manager'])))
$$;
REVOKE ALL ON FUNCTION public._exos_can_edit_event(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public._exos_can_edit_event(uuid) TO authenticated, service_role;

-- Set (or, with a blank url, remove) the join link.
CREATE OR REPLACE FUNCTION public.exos_set_event_online(
  p_event_id uuid, p_join_url text, p_join_note text DEFAULT NULL, p_reveal_minutes integer DEFAULT NULL)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE
  v_url  text := nullif(btrim(coalesce(p_join_url, '')), '');
  v_note text := nullif(btrim(coalesce(p_join_note, '')), '');
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'exos_set_event_online: not authenticated' USING ERRCODE = '42501';
  END IF;
  IF NOT public._exos_can_edit_event(p_event_id) THEN
    RAISE EXCEPTION 'exos_set_event_online: not authorized for this event' USING ERRCODE = '42501';
  END IF;
  IF v_url IS NULL THEN
    DELETE FROM public.exos_event_online WHERE event_id = p_event_id;
    RETURN;
  END IF;
  IF v_url !~ '^https://[^\s"<>]+$' OR char_length(v_url) > 1000 THEN
    RAISE EXCEPTION 'exos_set_event_online: the join link must be an https:// address' USING ERRCODE = '22023';
  END IF;
  INSERT INTO public.exos_event_online (event_id, join_url, join_note, reveal_minutes, updated_by, updated_at)
  VALUES (p_event_id, v_url, v_note, p_reveal_minutes, auth.uid(), now())
  ON CONFLICT (event_id) DO UPDATE
     SET join_url = EXCLUDED.join_url, join_note = EXCLUDED.join_note,
         reveal_minutes = EXCLUDED.reveal_minutes, updated_by = EXCLUDED.updated_by,
         updated_at = now();
END $$;
REVOKE ALL ON FUNCTION public.exos_set_event_online(uuid, text, text, integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.exos_set_event_online(uuid, text, text, integer) TO authenticated, service_role;

-- Staff read (Edit event form).
CREATE OR REPLACE FUNCTION public.exos_event_online_staff(p_event_id uuid)
RETURNS TABLE (join_url text, join_note text, reveal_minutes integer)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
BEGIN
  IF auth.uid() IS NULL OR NOT public._exos_can_edit_event(p_event_id) THEN
    RAISE EXCEPTION 'exos_event_online_staff: not authorized for this event' USING ERRCODE = '42501';
  END IF;
  RETURN QUERY SELECT o.join_url, o.join_note, o.reveal_minutes
                 FROM public.exos_event_online o WHERE o.event_id = p_event_id;
END $$;
REVOKE ALL ON FUNCTION public.exos_event_online_staff(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.exos_event_online_staff(uuid) TO authenticated, service_role;

-- Holder read (ticket page). state:
--   none        no join link set (or not an online / hybrid event)
--   not_holder  the caller holds no active / used ticket for the event
--   cancelled   the event was cancelled
--   later       held back until available_at (reveal_minutes before start)
--   ready       join_url / join_note returned
-- Staff (owner / manager / scanner, admin) always get it, to test the link.
CREATE OR REPLACE FUNCTION public.exos_event_online_access(p_event_id uuid)
RETURNS TABLE (state text, join_url text, join_note text, available_at timestamptz)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE
  e      record;
  o      record;
  v_at   timestamptz;
  v_staff boolean;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'exos_event_online_access: not authenticated' USING ERRCODE = '42501';
  END IF;
  SELECT id, org_id, format, status, starts_at INTO e
    FROM public.exos_events WHERE id = p_event_id;
  IF e.id IS NULL THEN
    RETURN QUERY SELECT 'not_holder'::text, NULL::text, NULL::text, NULL::timestamptz;
    RETURN;
  END IF;
  v_staff := public.exos_is_admin()
          OR public.exos_has_org_role(e.org_id, ARRAY['owner', 'manager', 'scanner']);
  IF NOT v_staff AND NOT EXISTS (
       SELECT 1 FROM public.exos_tickets t
        WHERE t.event_id = p_event_id AND t.owner_id = auth.uid()
          AND t.status IN ('active', 'used')) THEN
    RETURN QUERY SELECT 'not_holder'::text, NULL::text, NULL::text, NULL::timestamptz;
    RETURN;
  END IF;
  IF e.status = 'cancelled' THEN
    RETURN QUERY SELECT 'cancelled'::text, NULL::text, NULL::text, NULL::timestamptz;
    RETURN;
  END IF;
  SELECT x.join_url, x.join_note, x.reveal_minutes INTO o
    FROM public.exos_event_online x WHERE x.event_id = p_event_id;
  IF o.join_url IS NULL OR e.format = 'in_person' THEN
    RETURN QUERY SELECT 'none'::text, NULL::text, NULL::text, NULL::timestamptz;
    RETURN;
  END IF;
  IF o.reveal_minutes IS NOT NULL AND e.starts_at IS NOT NULL THEN
    v_at := e.starts_at - make_interval(mins => o.reveal_minutes);
  END IF;
  IF NOT v_staff AND v_at IS NOT NULL AND now() < v_at THEN
    RETURN QUERY SELECT 'later'::text, NULL::text, o.join_note, v_at;
    RETURN;
  END IF;
  RETURN QUERY SELECT 'ready'::text, o.join_url, o.join_note, v_at;
END $$;
REVOKE ALL ON FUNCTION public.exos_event_online_access(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.exos_event_online_access(uuid) TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 3. Public view: append the new columns in place (same pattern as
--    20260929120000), keeping the view's options.
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  d text;
  opts text;
  i int;
BEGIN
  IF to_regclass('public.exos_public_events') IS NULL THEN
    RAISE NOTICE 'exos_public_events: view not present here, skipping';   -- stub test schemas
    RETURN;
  END IF;
  d := pg_get_viewdef('public.exos_public_events'::regclass);
  IF position('what_to_bring' || E'\n' in d) > 0 OR position('what_to_bring' || ',' in d) > 0 THEN
    RAISE NOTICE 'exos_public_events: already has the online-event columns, skipping';
    RETURN;
  END IF;
  i := position(E'\n   FROM ' in d);
  IF i = 0 THEN
    RAISE EXCEPTION 'exos_public_events: unexpected view definition';
  END IF;
  d := left(d, i - 1) || ',
    format,
    what_to_bring,
    noindex' || substr(d, i);
  SELECT coalesce(' WITH (' || array_to_string(c.reloptions, ', ') || ')', '') INTO opts
    FROM pg_class c WHERE c.oid = 'public.exos_public_events'::regclass;
  EXECUTE format('CREATE OR REPLACE VIEW public.exos_public_events%s AS %s', opts, d);
  GRANT SELECT ON public.exos_public_events TO anon, authenticated;
END $$;

-- ---------------------------------------------------------------------------
-- 4. Event reminder mail: add "what to bring" and, for online / hybrid
--    events, point holders at the join link on their ticket (the link itself
--    is never emailed: mail can reach a buyer who has since transferred the
--    ticket). Patched in place, one marker.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION pg_temp.exos_patch_n(p_sig text, p_marker text, p_old text, p_new text, p_hits int)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE p_fn regprocedure := to_regprocedure(p_sig); v_def text; v_hits int;
BEGIN
  IF p_fn IS NULL THEN
    RAISE NOTICE '%: not present, skipped', p_sig;
    RETURN;
  END IF;
  v_def := pg_get_functiondef(p_fn);
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

SELECT pg_temp.exos_patch_n('public.exos_queue_event_reminder(uuid,uuid)',
  'exos:online-events',
  $o$'<p><a href="{{app_url}}/my-tickets">Your tickets</a></p>';$o$,
  $n$'<p><a href="{{app_url}}/my-tickets">Your tickets</a></p>' ||
            -- exos:online-events
            CASE WHEN v_ev.format IN ('online', 'hybrid')
                 THEN '<p>Joining online? The join link is on your ticket in the app.</p>'
                 ELSE '' END ||
            CASE WHEN nullif(btrim(coalesce(v_ev.what_to_bring, '')), '') IS NOT NULL
                 THEN '<p><strong>What to bring:</strong> ' ||
                      public.exos_mail_escape(btrim(v_ev.what_to_bring)) || '</p>'
                 ELSE '' END;$n$,
  1);
