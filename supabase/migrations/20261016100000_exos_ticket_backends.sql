-- ============================================================================
-- Ticket backends: sell on Exos, or on Eventbrite / pretix / hi.events
-- ============================================================================
-- Touches:  W: TABLE exos_events (+ ticket_backend, external_ticket_url)
--           W: VIEW exos_public_events (+ ticket_backend, external_ticket_url)
--           C: TABLE exos_backend_links (service role only)
--           C: FUNCTION exos_set_ticket_backend, exos_backend_link,
--              exos_backend_unlink, exos_backend_status (authenticated),
--              exos_backend_sync_claim, exos_backend_apply (service role),
--              exos_tg_cart_holds_backend (trigger on exos_cart_holds)
--           C: cron.schedule (exos-integrations-sync-2min, when pg_cron present)
--           W: FUNCTION exos_claim_free_tickets (patched in place: refused
--              when another platform sells the event)
-- Pre-reqs: 20261016090000 (org integrations), 20261013090000 (door codes),
--           20261013100000 (Eventbrite sync), 20261005090000 (view columns)
--
-- An organizer picks, per event, where tickets are sold:
--   exos       Exos checkout (default; everything as before)
--   eventbrite the organizer's Eventbrite event
--   pretix     the organizer's pretix shop (pretix.eu or self-hosted)
--   hievents   the organizer's hi.events (hosted or self-hosted)
-- With another backend, the event page's buy button links to that shop
-- (external_ticket_url) and Exos's own sale paths refuse the event (cart
-- holds, free claims; exos-checkout checks too). Exos still runs the event
-- page, marketing, door and reports.
--
-- The door: pretix and hi.events attendees are synced read-only into a guest
-- list ("pretix" / "hi.events"), with their QR code, like the Eventbrite sync
-- (which keeps its own tables). pretix reads orders with the org's API token
-- (Integrations); hi.events reads a check-in list's public attendee feed
-- (the list's short id from its share link; no account password is stored).
-- A cancelled / refunded order voids its guests. Nothing is written back.
--
-- Re-run safe. Prod apply needs operator OK.
-- ============================================================================

ALTER TABLE public.exos_events
  ADD COLUMN IF NOT EXISTS ticket_backend text NOT NULL DEFAULT 'exos',
  ADD COLUMN IF NOT EXISTS external_ticket_url text;
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'exos_events_ticket_backend_chk') THEN
    ALTER TABLE public.exos_events ADD CONSTRAINT exos_events_ticket_backend_chk
      CHECK (ticket_backend IN ('exos', 'eventbrite', 'pretix', 'hievents'));
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'exos_events_external_ticket_url_chk') THEN
    ALTER TABLE public.exos_events ADD CONSTRAINT exos_events_external_ticket_url_chk
      CHECK (external_ticket_url IS NULL OR (external_ticket_url ~ '^https://[^\s/]+\.[^\s]+$' AND length(external_ticket_url) <= 500));
  END IF;
END $$;

-- The public view shows where to buy.
DO $$
DECLARE d text; opts text; i int;
BEGIN
  IF to_regclass('public.exos_public_events') IS NULL THEN
    RAISE NOTICE 'exos_public_events: view not present here, skipping';
    RETURN;
  END IF;
  d := pg_get_viewdef('public.exos_public_events'::regclass);
  IF position('external_ticket_url' in d) > 0 THEN
    RAISE NOTICE 'exos_public_events: already has the backend columns, skipping';
    RETURN;
  END IF;
  i := position(E'\n   FROM ' in d);
  IF i = 0 THEN
    RAISE EXCEPTION 'exos_public_events: unexpected view definition';
  END IF;
  d := left(d, i - 1) || ',
    ticket_backend,
    external_ticket_url' || substr(d, i);
  SELECT coalesce(' WITH (' || array_to_string(c.reloptions, ', ') || ')', '') INTO opts
    FROM pg_class c WHERE c.oid = 'public.exos_public_events'::regclass;
  EXECUTE format('CREATE OR REPLACE VIEW public.exos_public_events%s AS %s', opts, d);
  GRANT SELECT ON public.exos_public_events TO anon, authenticated;
END $$;

-- ---------------------------------------------------------------------------
-- 1. Choosing the backend (owner / manager).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.exos_set_ticket_backend(p_event_id uuid, p_backend text, p_url text DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  e     public.exos_events%ROWTYPE;
  v_url text := nullif(btrim(coalesce(p_url, '')), '');
BEGIN
  SELECT * INTO e FROM public.exos_events WHERE id = p_event_id FOR UPDATE;
  IF NOT FOUND OR coalesce(public._exos_integ_role(e.org_id, auth.uid()), '') NOT IN ('owner', 'manager') THEN
    RAISE EXCEPTION 'exos_set_ticket_backend: owner or manager only' USING ERRCODE = '42501';
  END IF;
  IF p_backend IS NULL OR p_backend NOT IN ('exos', 'eventbrite', 'pretix', 'hievents') THEN
    RAISE EXCEPTION 'exos_set_ticket_backend: unknown backend' USING ERRCODE = '22023';
  END IF;
  IF p_backend <> 'exos' AND (v_url IS NULL OR v_url !~ '^https://[^\s/]+\.[^\s]+$' OR length(v_url) > 500) THEN
    RAISE EXCEPTION 'exos_set_ticket_backend: give the https link where buyers get tickets' USING ERRCODE = '22023';
  END IF;
  IF p_backend <> 'exos' AND e.tickets_sold > 0 AND e.ticket_backend = 'exos' THEN
    RAISE EXCEPTION 'exos_set_ticket_backend: % tickets were already sold on Exos; keep Exos as the backend for this event', e.tickets_sold
      USING ERRCODE = '22023';
  END IF;
  UPDATE public.exos_events
     SET ticket_backend = p_backend, external_ticket_url = CASE WHEN p_backend = 'exos' THEN NULL ELSE v_url END
   WHERE id = p_event_id;
  RETURN jsonb_build_object('ticket_backend', p_backend, 'external_ticket_url', CASE WHEN p_backend = 'exos' THEN NULL ELSE v_url END);
END $$;
REVOKE ALL ON FUNCTION public.exos_set_ticket_backend(uuid, text, text) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.exos_set_ticket_backend(uuid, text, text) TO authenticated, service_role;

-- Exos's own sale paths refuse an event another platform sells.
CREATE OR REPLACE FUNCTION public.exos_tg_cart_holds_backend()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE v_backend text;
BEGIN
  SELECT ticket_backend INTO v_backend FROM public.exos_events WHERE id = NEW.event_id;
  IF coalesce(v_backend, 'exos') <> 'exos' THEN
    RAISE EXCEPTION 'tickets for this event are sold on %', v_backend USING ERRCODE = '42501';
  END IF;
  RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION public.exos_tg_cart_holds_backend() FROM PUBLIC, anon, authenticated;
CREATE OR REPLACE TRIGGER exos_cart_holds_backend
  BEFORE INSERT ON public.exos_cart_holds
  FOR EACH ROW EXECUTE FUNCTION public.exos_tg_cart_holds_backend();

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

SELECT pg_temp.exos_patch_n(
  (SELECT p.oid::regprocedure::text FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.proname = 'exos_claim_free_tickets' ORDER BY p.oid DESC LIMIT 1),
  'exos:ticket-backend',
  $o$RAISE EXCEPTION 'exos_claim_free_tickets: event not on sale' USING ERRCODE = '42501';
  END IF;$o$,
  $n$RAISE EXCEPTION 'exos_claim_free_tickets: event not on sale' USING ERRCODE = '42501';
  END IF;
  -- exos:ticket-backend: another platform sells this event.
  IF EXISTS (SELECT 1 FROM public.exos_events WHERE id = p_event_id AND ticket_backend <> 'exos') THEN
    RAISE EXCEPTION 'exos_claim_free_tickets: tickets for this event are on another site' USING ERRCODE = '42501';
  END IF;$n$,
  1);

-- ---------------------------------------------------------------------------
-- 2. pretix / hi.events attendee sync (read-only) for the door.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.exos_backend_links (
  event_id       uuid PRIMARY KEY REFERENCES public.exos_events (id) ON DELETE CASCADE,
  org_id         uuid NOT NULL REFERENCES public.exos_orgs (id) ON DELETE CASCADE,
  provider       text NOT NULL CHECK (provider IN ('pretix', 'hievents')),
  -- pretix: the event slug; hi.events: the check-in list short id (from its share link).
  external_ref   text NOT NULL CHECK (external_ref ~ '^[A-Za-z0-9._-]{1,64}$'),
  external_name  text CHECK (external_name IS NULL OR length(external_name) <= 200),
  list_id        uuid NOT NULL REFERENCES public.exos_guest_lists (id) ON DELETE CASCADE,
  linked_by      uuid,
  linked_at      timestamptz NOT NULL DEFAULT now(),
  sync_cursor    text CHECK (sync_cursor IS NULL OR length(sync_cursor) <= 200),  -- pretix modified_since / hi.events page
  pass_started_at timestamptz,
  lease_id       uuid,
  lease_until    timestamptz,
  row_errors     integer NOT NULL DEFAULT 0,
  synced_count   integer NOT NULL DEFAULT 0,
  last_synced_at timestamptz,
  last_ok_at     timestamptz,
  last_error     text CHECK (last_error IS NULL OR length(last_error) <= 200)
);
CREATE INDEX IF NOT EXISTS exos_backend_links_due_idx ON public.exos_backend_links (last_synced_at NULLS FIRST);
ALTER TABLE public.exos_backend_links ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.exos_backend_links FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.exos_backend_link(p_event_id uuid, p_provider text, p_ref text, p_name text DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  e       public.exos_events%ROWTYPE;
  v_list  uuid;
  v_lname text := CASE p_provider WHEN 'pretix' THEN 'pretix' ELSE 'hi.events' END;
  v_ref   text := btrim(coalesce(p_ref, ''));
BEGIN
  SELECT * INTO e FROM public.exos_events WHERE id = p_event_id;
  IF NOT FOUND OR coalesce(public._exos_integ_role(e.org_id, auth.uid()), '') NOT IN ('owner', 'manager') THEN
    RAISE EXCEPTION 'exos_backend_link: owner or manager only' USING ERRCODE = '42501';
  END IF;
  IF p_provider IS NULL OR p_provider NOT IN ('pretix', 'hievents') THEN
    RAISE EXCEPTION 'exos_backend_link: pretix or hievents' USING ERRCODE = '22023';
  END IF;
  IF v_ref !~ '^[A-Za-z0-9._-]{1,64}$' THEN
    RAISE EXCEPTION 'exos_backend_link: that % id doesn''t look right', v_lname USING ERRCODE = '22023';
  END IF;
  IF e.status = 'cancelled' THEN
    RAISE EXCEPTION 'exos_backend_link: the event was cancelled' USING ERRCODE = '22023';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.exos_org_integrations i
                  WHERE i.org_id = e.org_id AND i.provider = p_provider AND i.status <> 'disabled') THEN
    RAISE EXCEPTION 'exos_backend_link: connect % in Integrations first', v_lname USING ERRCODE = '22023';
  END IF;

  SELECT id INTO v_list FROM public.exos_guest_lists WHERE event_id = p_event_id AND name = v_lname ORDER BY created_at LIMIT 1;
  IF v_list IS NULL THEN
    INSERT INTO public.exos_guest_lists (event_id, org_id, name, max_plus_ones, counts_toward_capacity, created_by)
    VALUES (p_event_id, e.org_id, v_lname, 0, false, auth.uid())
    RETURNING id INTO v_list;
  END IF;

  INSERT INTO public.exos_backend_links AS l (event_id, org_id, provider, external_ref, external_name, list_id, linked_by, linked_at)
  VALUES (p_event_id, e.org_id, p_provider, v_ref, left(nullif(btrim(coalesce(p_name, '')), ''), 200), v_list, auth.uid(), now())
  ON CONFLICT (event_id) DO UPDATE
     SET provider = EXCLUDED.provider, external_ref = EXCLUDED.external_ref, external_name = EXCLUDED.external_name,
         list_id = EXCLUDED.list_id, linked_by = EXCLUDED.linked_by, linked_at = EXCLUDED.linked_at,
         sync_cursor = CASE WHEN l.provider = EXCLUDED.provider AND l.external_ref = EXCLUDED.external_ref THEN l.sync_cursor END,
         lease_id = NULL, lease_until = NULL, last_synced_at = NULL, last_error = NULL;
  RETURN jsonb_build_object('linked', true, 'list_id', v_list);
END $$;
REVOKE ALL ON FUNCTION public.exos_backend_link(uuid, text, text, text) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.exos_backend_link(uuid, text, text, text) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.exos_backend_unlink(p_event_id uuid)
RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE v_org uuid;
BEGIN
  SELECT org_id INTO v_org FROM public.exos_events WHERE id = p_event_id;
  IF coalesce(public._exos_integ_role(v_org, auth.uid()), '') NOT IN ('owner', 'manager') THEN
    RAISE EXCEPTION 'exos_backend_unlink: owner or manager only' USING ERRCODE = '42501';
  END IF;
  -- The guests already synced stay on their list (the door keeps working).
  DELETE FROM public.exos_backend_links WHERE event_id = p_event_id;
  RETURN FOUND;
END $$;
REVOKE ALL ON FUNCTION public.exos_backend_unlink(uuid) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.exos_backend_unlink(uuid) TO authenticated, service_role;

-- What the event editor and door show (never a token).
CREATE OR REPLACE FUNCTION public.exos_backend_status(p_event_id uuid)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE e public.exos_events%ROWTYPE; lk public.exos_backend_links%ROWTYPE; v_role text;
BEGIN
  SELECT * INTO e FROM public.exos_events WHERE id = p_event_id;
  v_role := public._exos_eb_role(e.org_id, auth.uid(), p_event_id);
  IF v_role IS NULL AND public._exos_integ_role(e.org_id, auth.uid()) IS NULL THEN
    RAISE EXCEPTION 'exos_backend_status: not authorized for this event' USING ERRCODE = '42501';
  END IF;
  SELECT * INTO lk FROM public.exos_backend_links WHERE event_id = p_event_id;
  RETURN jsonb_build_object(
    'ticket_backend', e.ticket_backend,
    'external_ticket_url', e.external_ticket_url,
    'can_manage', coalesce(public._exos_integ_role(e.org_id, auth.uid()), '') IN ('owner', 'manager'),
    'connected', (SELECT jsonb_agg(i.provider) FROM public.exos_org_integrations i
                   WHERE i.org_id = e.org_id AND i.provider IN ('pretix', 'hievents') AND i.status <> 'disabled'),
    'link', CASE WHEN lk.event_id IS NULL THEN NULL ELSE jsonb_build_object(
              'provider', lk.provider, 'external_name', lk.external_name,
              'external_ref', CASE WHEN lk.provider = 'pretix' THEN lk.external_ref END,
              'synced_count', lk.synced_count, 'row_errors', lk.row_errors,
              'last_synced_at', lk.last_synced_at, 'last_ok_at', lk.last_ok_at, 'last_error', lk.last_error) END);
END $$;
REVOKE ALL ON FUNCTION public.exos_backend_status(uuid) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.exos_backend_status(uuid) TO authenticated, service_role;

-- Service role: links due a sync, each with a 2-minute lease. Every 2
-- minutes from two days before the start, every 30 minutes before that,
-- never once the event is two days past.
CREATE OR REPLACE FUNCTION public.exos_backend_sync_claim(p_limit int DEFAULT 10, p_event_id uuid DEFAULT NULL)
RETURNS TABLE (event_id uuid, org_id uuid, provider text, external_ref text, sync_cursor text, lease_id uuid)
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  RETURN QUERY
  WITH due AS (
    SELECT l.event_id
      FROM public.exos_backend_links l
      JOIN public.exos_events e ON e.id = l.event_id
     WHERE e.status <> 'cancelled'
       AND (e.starts_at IS NULL OR e.starts_at > now() - interval '2 days')
       AND (l.lease_until IS NULL OR l.lease_until < now())
       AND (p_event_id IS NOT NULL AND l.event_id = p_event_id AND (l.last_synced_at IS NULL OR l.last_synced_at < now() - interval '20 seconds')
            OR p_event_id IS NULL AND (l.last_synced_at IS NULL
                OR l.last_synced_at < now() - CASE WHEN e.starts_at IS NULL OR e.starts_at < now() + interval '2 days'
                                                   THEN interval '2 minutes' ELSE interval '30 minutes' END))
     ORDER BY l.last_synced_at NULLS FIRST
     LIMIT greatest(1, least(coalesce(p_limit, 10), 50))
     FOR UPDATE OF l SKIP LOCKED
  )
  UPDATE public.exos_backend_links l
     SET lease_id = gen_random_uuid(), lease_until = now() + interval '2 minutes', last_synced_at = now(),
         pass_started_at = coalesce(l.pass_started_at, now())
    FROM due
   WHERE l.event_id = due.event_id
  RETURNING l.event_id, l.org_id, l.provider, l.external_ref, l.sync_cursor, l.lease_id;
END $$;
REVOKE ALL ON FUNCTION public.exos_backend_sync_claim(int, uuid) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.exos_backend_sync_claim(int, uuid) TO service_role;

-- Service role: one page of attendees. Rows: { ref, code, name, email,
-- ticket, void, reason }. p_state: 'more' (another page now; p_cursor is the
-- next page), 'done' (pass finished; p_cursor is the next pass's start),
-- 'error'.
CREATE OR REPLACE FUNCTION public.exos_backend_apply(
  p_event_id uuid, p_lease uuid, p_rows jsonb, p_state text, p_cursor text DEFAULT NULL, p_error text DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  lk        public.exos_backend_links%ROWTYPE;
  l         public.exos_guest_lists%ROWTYPE;
  r         jsonb;
  g         public.exos_guest_list_entries%ROWTYPE;
  v_prefix  text;
  v_source  text;
  v_ref     text;
  v_code    text;
  v_name    text;
  v_email   text;
  v_void    boolean;
  v_id      uuid;
  v_added   int := 0;
  v_updated int := 0;
  v_voided  int := 0;
  v_restored int := 0;
  v_skipped int := 0;
  v_errors  int := 0;
  v_invalid int := 0;
BEGIN
  SELECT * INTO lk FROM public.exos_backend_links WHERE event_id = p_event_id FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'not-linked');
  END IF;
  IF lk.lease_id IS NULL OR p_lease IS DISTINCT FROM lk.lease_id THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'lease-lost');
  END IF;
  IF p_state IS NULL OR p_state NOT IN ('more', 'done', 'error') THEN
    RAISE EXCEPTION 'exos_backend_apply: bad state %', p_state USING ERRCODE = '22023';
  END IF;
  IF p_rows IS NOT NULL AND (jsonb_typeof(p_rows) <> 'array' OR jsonb_array_length(p_rows) > 2000) THEN
    RAISE EXCEPTION 'exos_backend_apply: rows must be an array of at most 2000' USING ERRCODE = '22023';
  END IF;
  SELECT * INTO l FROM public.exos_guest_lists WHERE id = lk.list_id;
  v_prefix := CASE lk.provider WHEN 'pretix' THEN 'px:' ELSE 'he:' END;
  v_source := CASE lk.provider WHEN 'pretix' THEN 'pretix' ELSE 'hi.events' END;

  FOR r IN SELECT value FROM jsonb_array_elements(coalesce(p_rows, '[]'::jsonb)) LOOP
    IF jsonb_typeof(r) <> 'object' OR coalesce(r->>'ref', '') !~ '^[A-Za-z0-9._-]{1,64}$' THEN
      v_invalid := v_invalid + 1;
      CONTINUE;
    END IF;
    v_ref   := v_prefix || (r->>'ref');
    v_code  := public._exos_door_code(r->>'code');
    v_name  := left(nullif(btrim(coalesce(r->>'name', '')), ''), 80);
    v_email := nullif(lower(btrim(coalesce(r->>'email', ''))), '');
    v_email := CASE WHEN v_email ~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' AND length(v_email) <= 254 THEN v_email END;
    v_void  := (r->'void') = 'true'::jsonb;

    BEGIN
      SELECT * INTO g FROM public.exos_guest_list_entries x
       WHERE x.event_id = p_event_id
         AND (x.external_ref = v_ref OR (v_code IS NOT NULL AND x.external_code = v_code AND x.external_ref IS NULL))
       ORDER BY (x.external_ref = v_ref) DESC NULLS LAST
       LIMIT 1
       FOR UPDATE;

      IF g.id IS NULL THEN
        IF v_void THEN
          v_skipped := v_skipped + 1;
        ELSE
          v_id := public._exos_guest_insert(l.id, coalesce(v_name, v_source || ' guest'), v_email, NULL, 0, NULL, lk.linked_by, NULL);
          UPDATE public.exos_guest_list_entries
             SET external_ref = v_ref, external_code = v_code,
                 ticket_label = left(nullif(btrim(coalesce(r->>'ticket', '')), ''), 80),
                 source = v_source
           WHERE id = v_id;
          v_added := v_added + 1;
        END IF;
      ELSE
        UPDATE public.exos_guest_list_entries
           SET external_ref  = v_ref,
               external_code = coalesce(v_code, external_code),
               guest_name    = coalesce(v_name, guest_name),
               ticket_label  = coalesce(left(nullif(btrim(coalesce(r->>'ticket', '')), ''), 80), ticket_label),
               source        = coalesce(source, v_source),
               voided_at     = CASE WHEN v_void THEN coalesce(voided_at, now()) END,
               void_reason   = CASE WHEN v_void THEN left(coalesce(nullif(btrim(r->>'reason'), ''), 'cancelled'), 40) END
         WHERE id = g.id;
        IF v_void AND g.voided_at IS NULL THEN
          v_voided := v_voided + 1;
        ELSIF NOT v_void AND g.voided_at IS NOT NULL THEN
          v_restored := v_restored + 1;
        ELSE
          v_updated := v_updated + 1;
        END IF;
      END IF;
    EXCEPTION
      WHEN unique_violation OR check_violation OR raise_exception THEN
        v_errors := v_errors + 1;
    END;
    g := NULL;
  END LOOP;

  UPDATE public.exos_backend_links
     SET lease_until     = CASE WHEN p_state = 'more' THEN now() + interval '2 minutes' END,
         lease_id        = CASE WHEN p_state = 'more' THEN lease_id END,
         sync_cursor     = CASE WHEN p_state IN ('more', 'done') THEN left(p_cursor, 200) ELSE sync_cursor END,
         pass_started_at = CASE WHEN p_state IN ('done', 'error') THEN NULL ELSE pass_started_at END,
         row_errors      = CASE WHEN p_state = 'done' THEN v_errors ELSE row_errors + v_errors END,
         synced_count    = (SELECT count(*) FROM public.exos_guest_list_entries x
                             WHERE x.list_id = lk.list_id AND x.voided_at IS NULL),
         last_ok_at      = CASE WHEN p_state = 'done' THEN now() ELSE last_ok_at END,
         last_error      = CASE WHEN p_state = 'error' THEN left(coalesce(nullif(btrim(p_error), ''), 'sync failed'), 200) ELSE NULL END
   WHERE event_id = p_event_id;

  RETURN jsonb_build_object('ok', true, 'added', v_added, 'updated', v_updated, 'voided', v_voided,
                            'restored', v_restored, 'skipped', v_skipped, 'errors', v_errors, 'invalid', v_invalid);
END $$;
REVOKE ALL ON FUNCTION public.exos_backend_apply(uuid, uuid, jsonb, text, text, text) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.exos_backend_apply(uuid, uuid, jsonb, text, text, text) TO service_role;

-- ---------------------------------------------------------------------------
-- 3. Cron: every 2 minutes, even minutes (Eventbrite runs on the odd ones).
-- The function decides which links are due. Self-hosted: set
-- app.exos_functions_url (ALTER DATABASE … SET app.exos_functions_url =
-- 'https://<project>.supabase.co/functions/v1') or edit the job.
-- ---------------------------------------------------------------------------
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron')
     AND to_regprocedure('public._cron_invoke_edge_fn(text, jsonb)') IS NOT NULL THEN
    IF EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'exos-integrations-sync-2min') THEN
      PERFORM cron.unschedule('exos-integrations-sync-2min');
    END IF;
    PERFORM cron.schedule('exos-integrations-sync-2min', '*/2 * * * *', $cron$
      SELECT public._cron_invoke_edge_fn(
        coalesce(nullif(current_setting('app.exos_functions_url', true), ''),
                 'https://hzrizjeaxlqcxfrtczpq.supabase.co/functions/v1') || '/exos-integrations/cron', '{}'::jsonb);
    $cron$);
  END IF;
END $$;

-- ROLLBACK (manual): SELECT cron.unschedule('exos-integrations-sync-2min'); drop the trigger and functions above, exos_backend_links,
-- the two exos_events columns (re-create exos_public_events without them first).
