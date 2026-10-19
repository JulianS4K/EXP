-- ============================================================================
-- Channels: one Exos event, mirrored 1-1 on Eventbrite and Luma
-- ============================================================================
-- Touches:  C: TABLE exos_channel_mirrors, exos_luma_ticket_links, exos_luma_comp_queue
--           W: exos_org_integrations (+ writes_enabled)
--              exos_events.primary_source (+ 'luma')
--              exos_ticket_tiers.sold, exos_events.tickets_sold (Luma sales take
--                seats, refunds give them back, like Eventbrite's)
--              exos_eventbrite_links / exos_eventbrite_ticket_links, exos_backend_links
--                (rows for the events Exos creates, so the door + inventory syncs
--                that already exist pick them up)
--           C: FUNCTION exos_channel_set, exos_channel_remove, exos_channel_status,
--              exos_channel_connections, exos_channel_queue_comps, exos_integration_set_writes (authenticated,
--              role-checked); exos_channel_claim, exos_channel_mark,
--              exos_luma_inventory_apply, exos_luma_inventory_ack, exos_luma_comp_claim,
--              exos_luma_comp_mark (service role)
--           R: CREATE OR REPLACE exos_set_resale_options, _exos_primary_hold
--           P: exos_eventbrite_inventory_apply (the primary hold is Eventbrite's
--              only when Eventbrite is primary)
-- Pre-reqs: 20261013100000 (Eventbrite links), 20261014110000 (Eventbrite
--           inventory), 20261014150000 (primary_source, primary hold),
--           20261016090000 (integrations), 20261016100000 (backend links)
--
-- docs/organizer-guide.md "Selling on Eventbrite and Luma too". Exos is the
-- source: the organizer creates the event in Exos and picks, per event,
--   * which platforms also sell it (Eventbrite, Luma): Exos creates the event
--     there (or links one that exists) and keeps its details, ticket types and
--     prices in step with Exos. An edit made directly on Eventbrite or Luma is
--     overwritten by the next change in Exos.
--   * the PRIMARY ticketing system (primary_source: exos | eventbrite | luma):
--     the platform whose QR codes the last listing set is sold with when the
--     event is shared on other markets (the S4K route, mig 20261014150000), and
--     where comps are issued (Luma: guests added there; Eventbrite can't add
--     attendees through its API, so comps stay Exos tickets).
-- One shared count: every platform's sales come off the Exos ticket type, and
-- each platform's capacity is set so that what it has left is what Exos has
-- free (less one pack, the buffer for the sync's lag). Eventbrite's count is
-- the inventory sync that already exists (20261014110000); Luma's is new here
-- and works the same way, from the guests Luma reports.
-- Writing to Eventbrite or Luma needs the org's switch (Eventbrite:
-- exos_eventbrite_accounts.writes_enabled; Luma: exos_org_integrations.writes_enabled)
-- AND the operator's EXOS_EVENTBRITE_WRITES / EXOS_LUMA_WRITES=on. Otherwise the
-- sync records what it would send (dry run) and nothing leaves Exos.
--
-- Re-run safe. Prod apply needs operator OK.
-- ============================================================================

CREATE OR REPLACE FUNCTION pg_temp.exos_patch_n(p_sig text, p_marker text, p_old text, p_new text, p_hits int)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE p_fn regprocedure := to_regprocedure(p_sig); v_def text; v_hits int;
BEGIN
  IF p_fn IS NULL THEN
    RAISE EXCEPTION '%: not present', p_sig;
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

-- ---------------------------------------------------------------------------
-- 1. The org's Luma write switch, and Luma as a primary source.
-- ---------------------------------------------------------------------------
ALTER TABLE public.exos_org_integrations ADD COLUMN IF NOT EXISTS writes_enabled boolean NOT NULL DEFAULT false;

-- Owner only. Luma for now (Eventbrite's switch is exos_eventbrite_set_writes).
CREATE OR REPLACE FUNCTION public.exos_integration_set_writes(p_org_id uuid, p_provider text, p_on boolean)
RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF coalesce(public._exos_integ_role(p_org_id, auth.uid()), '') <> 'owner' THEN
    RAISE EXCEPTION 'exos_integration_set_writes: owner only' USING ERRCODE = '42501';
  END IF;
  IF p_provider IS DISTINCT FROM 'luma' THEN
    RAISE EXCEPTION 'exos_integration_set_writes: luma only' USING ERRCODE = '22023';
  END IF;
  UPDATE public.exos_org_integrations SET writes_enabled = coalesce(p_on, false)
   WHERE org_id = p_org_id AND provider = p_provider;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'exos_integration_set_writes: connect Luma first' USING ERRCODE = '22023';
  END IF;
  RETURN coalesce(p_on, false);
END $$;
REVOKE ALL ON FUNCTION public.exos_integration_set_writes(uuid, text, boolean) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.exos_integration_set_writes(uuid, text, boolean) TO authenticated, service_role;

ALTER TABLE public.exos_events DROP CONSTRAINT IF EXISTS exos_events_primary_source_check;
ALTER TABLE public.exos_events ADD CONSTRAINT exos_events_primary_source_check
  CHECK (primary_source IN ('exos', 'eventbrite', 'luma'));

-- ---------------------------------------------------------------------------
-- 2. Mirrors: one row per (event, platform).
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.exos_channel_mirrors (
  event_id      uuid NOT NULL REFERENCES public.exos_events (id) ON DELETE CASCADE,
  provider      text NOT NULL CHECK (provider IN ('eventbrite', 'luma')),
  org_id        uuid NOT NULL REFERENCES public.exos_orgs (id) ON DELETE CASCADE,
  -- create: Exos creates the event there; link: an event that exists (external_id).
  mode          text NOT NULL DEFAULT 'create' CHECK (mode IN ('create', 'link')),
  external_id   text CHECK (external_id IS NULL OR external_id ~ '^(evt-[A-Za-z0-9]{4,40}|[0-9]{1,24})$'),
  external_url  text CHECK (external_url IS NULL OR (external_url ~ '^https://' AND length(external_url) <= 500)),
  -- Provider ids the sync keeps (Eventbrite organization + venue).
  external_meta jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(external_meta) = 'object' AND length(external_meta::text) <= 2000),
  status        text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'synced', 'dry_run', 'error')),
  -- Bumped by every change to the event or its ticket types; a pass clears
  -- "dirty" only if nothing changed while it ran.
  change_seq    bigint NOT NULL DEFAULT 1,
  synced_seq    bigint NOT NULL DEFAULT 0,
  last_hash     text CHECK (last_hash IS NULL OR length(last_hash) <= 128),
  plan          jsonb,
  planned_at    timestamptz,
  synced_at     timestamptz,
  attempts      integer NOT NULL DEFAULT 0,
  next_try_at   timestamptz NOT NULL DEFAULT now(),
  lease_id      uuid,
  lease_until   timestamptz,
  last_error    text CHECK (last_error IS NULL OR length(last_error) <= 300),
  created_by    uuid,
  created_at    timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (event_id, provider)
);
CREATE UNIQUE INDEX IF NOT EXISTS exos_channel_mirrors_external_uq
  ON public.exos_channel_mirrors (org_id, provider, external_id) WHERE external_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS exos_channel_mirrors_due_idx ON public.exos_channel_mirrors (next_try_at);
ALTER TABLE public.exos_channel_mirrors ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.exos_channel_mirrors FROM PUBLIC, anon, authenticated;
GRANT ALL ON TABLE public.exos_channel_mirrors TO service_role;
COMMENT ON TABLE public.exos_channel_mirrors IS
  'An Exos event mirrored on Eventbrite / Luma (Exos is the source). Service role only; exos_channel_* RPCs. mig 20261019090000.';

-- Luma ticket type <-> Exos ticket type: one shared count (like
-- exos_eventbrite_ticket_links).
CREATE TABLE IF NOT EXISTS public.exos_luma_ticket_links (
  event_id            uuid NOT NULL REFERENCES public.exos_events (id) ON DELETE CASCADE,
  luma_event_id       text NOT NULL CHECK (luma_event_id ~ '^evt-[A-Za-z0-9]{4,40}$'),
  luma_ticket_type_id text NOT NULL CHECK (luma_ticket_type_id ~ '^[A-Za-z0-9_-]{1,64}$'),
  luma_ticket_name    text CHECK (luma_ticket_name IS NULL OR length(luma_ticket_name) <= 200),
  tier_id             uuid NOT NULL REFERENCES public.exos_ticket_tiers (id) ON DELETE CASCADE,
  active              boolean NOT NULL DEFAULT true,
  counted_sold        integer NOT NULL DEFAULT 0 CHECK (counted_sold >= 0),
  oversold            integer NOT NULL DEFAULT 0 CHECK (oversold >= 0),
  luma_sold           integer,
  luma_capacity       integer,
  target_capacity     integer,
  pushed_capacity     integer,
  pushed_at           timestamptz,
  plan                jsonb,
  planned_at          timestamptz,
  last_read_at        timestamptz,
  last_error          text CHECK (last_error IS NULL OR length(last_error) <= 200),
  created_at          timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (event_id, luma_event_id, luma_ticket_type_id)
);
CREATE UNIQUE INDEX IF NOT EXISTS exos_luma_ticket_links_tier_uq
  ON public.exos_luma_ticket_links (event_id, tier_id) WHERE active;
ALTER TABLE public.exos_luma_ticket_links ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.exos_luma_ticket_links FROM PUBLIC, anon, authenticated;
GRANT ALL ON TABLE public.exos_luma_ticket_links TO service_role;
COMMENT ON TABLE public.exos_luma_ticket_links IS
  'Exos ticket type <-> Luma ticket type: one shared count. Service role only. mig 20261019090000.';

-- Comps on a Luma-primary event: guests to add on Luma (they come back through
-- the door sync and the shared count like any Luma guest).
CREATE TABLE IF NOT EXISTS public.exos_luma_comp_queue (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  event_id    uuid NOT NULL REFERENCES public.exos_events (id) ON DELETE CASCADE,
  tier_id     uuid NOT NULL REFERENCES public.exos_ticket_tiers (id) ON DELETE CASCADE,
  email       text NOT NULL CHECK (email ~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' AND length(email) <= 254),
  name        text CHECK (name IS NULL OR length(name) <= 80),
  send_email  boolean NOT NULL DEFAULT true,
  status      text NOT NULL DEFAULT 'queued' CHECK (status IN ('queued', 'sending', 'added', 'planned', 'skipped', 'failed')),
  attempts    integer NOT NULL DEFAULT 0,
  claimed_at  timestamptz,
  last_error  text CHECK (last_error IS NULL OR length(last_error) <= 200),
  created_by  uuid,
  created_at  timestamptz NOT NULL DEFAULT now(),
  done_at     timestamptz
);
CREATE UNIQUE INDEX IF NOT EXISTS exos_luma_comp_queue_once_uq
  ON public.exos_luma_comp_queue (event_id, tier_id, lower(email)) WHERE status IN ('queued', 'sending', 'added', 'planned');
CREATE INDEX IF NOT EXISTS exos_luma_comp_queue_due_idx ON public.exos_luma_comp_queue (created_at) WHERE status IN ('queued', 'sending');
ALTER TABLE public.exos_luma_comp_queue ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.exos_luma_comp_queue FROM PUBLIC, anon, authenticated;
GRANT ALL ON TABLE public.exos_luma_comp_queue TO service_role;

-- A change to the event or its ticket types marks its mirrors for a pass.
-- Sales alone don't (the inventory passes follow them); neither do the
-- columns other syncs and reminders keep.
CREATE OR REPLACE FUNCTION public.exos_tg_channel_dirty()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_event uuid;
  v_skip  text[] := ARRAY['sold', 'tickets_sold', 'updated_at', 'sync_status', 'reminder_24h_sent_at',
                          'reminder_2h_sent_at', 'reminder_manual_sent_at', 'checkin_test_until', 'checkin_test_mode'];
BEGIN
  IF TG_OP = 'UPDATE' AND (to_jsonb(NEW) - v_skip) = (to_jsonb(OLD) - v_skip) THEN
    RETURN NULL;
  END IF;
  IF TG_OP = 'DELETE' THEN
    v_event := (to_jsonb(OLD) ->> CASE WHEN TG_TABLE_NAME = 'exos_events' THEN 'id' ELSE 'event_id' END)::uuid;
  ELSE
    v_event := (to_jsonb(NEW) ->> CASE WHEN TG_TABLE_NAME = 'exos_events' THEN 'id' ELSE 'event_id' END)::uuid;
  END IF;
  UPDATE public.exos_channel_mirrors SET change_seq = change_seq + 1, next_try_at = least(next_try_at, now())
   WHERE event_id = v_event;
  RETURN NULL;
END $$;
REVOKE ALL ON FUNCTION public.exos_tg_channel_dirty() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS exos_events_channel_dirty ON public.exos_events;
CREATE TRIGGER exos_events_channel_dirty AFTER UPDATE ON public.exos_events
  FOR EACH ROW EXECUTE FUNCTION public.exos_tg_channel_dirty();
DROP TRIGGER IF EXISTS exos_ticket_tiers_channel_dirty ON public.exos_ticket_tiers;
CREATE TRIGGER exos_ticket_tiers_channel_dirty AFTER INSERT OR UPDATE OR DELETE ON public.exos_ticket_tiers
  FOR EACH ROW EXECUTE FUNCTION public.exos_tg_channel_dirty();

-- ---------------------------------------------------------------------------
-- 3. Organizer RPCs.
-- ---------------------------------------------------------------------------
-- Turn a platform on for an event (create there, or link an event that exists).
CREATE OR REPLACE FUNCTION public.exos_channel_set(
  p_event_id uuid, p_provider text, p_mode text DEFAULT 'create', p_external_id text DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  e      public.exos_events%ROWTYPE;
  v_ext  text := nullif(btrim(coalesce(p_external_id, '')), '');
BEGIN
  SELECT * INTO e FROM public.exos_events WHERE id = p_event_id;
  IF e.id IS NULL OR coalesce(public._exos_integ_role(e.org_id, auth.uid()), '') NOT IN ('owner', 'manager') THEN
    RAISE EXCEPTION 'exos_channel_set: owner or manager only' USING ERRCODE = '42501';
  END IF;
  IF p_provider IS NULL OR p_provider NOT IN ('eventbrite', 'luma') THEN
    RAISE EXCEPTION 'exos_channel_set: eventbrite or luma' USING ERRCODE = '22023';
  END IF;
  IF coalesce(p_mode, 'create') NOT IN ('create', 'link') THEN
    RAISE EXCEPTION 'exos_channel_set: create or link' USING ERRCODE = '22023';
  END IF;
  IF e.status = 'cancelled' THEN
    RAISE EXCEPTION 'exos_channel_set: the event was cancelled' USING ERRCODE = '22023';
  END IF;
  IF p_provider = 'eventbrite' AND NOT EXISTS (SELECT 1 FROM public.exos_eventbrite_accounts a WHERE a.org_id = e.org_id) THEN
    RAISE EXCEPTION 'exos_channel_set: connect Eventbrite first (the door app)' USING ERRCODE = '22023';
  END IF;
  IF p_provider = 'luma' AND NOT EXISTS (SELECT 1 FROM public.exos_org_integrations i
                                          WHERE i.org_id = e.org_id AND i.provider = 'luma' AND i.status <> 'disabled') THEN
    RAISE EXCEPTION 'exos_channel_set: connect Luma in Integrations first' USING ERRCODE = '22023';
  END IF;
  IF p_mode = 'link' THEN
    IF v_ext IS NULL
       OR (p_provider = 'eventbrite' AND v_ext !~ '^[0-9]{1,24}$')
       OR (p_provider = 'luma' AND v_ext !~ '^evt-[A-Za-z0-9]{4,40}$') THEN
      RAISE EXCEPTION 'exos_channel_set: that % event id doesn''t look right', p_provider USING ERRCODE = '22023';
    END IF;
  ELSE
    v_ext := NULL;
  END IF;
  IF v_ext IS NOT NULL AND EXISTS (SELECT 1 FROM public.exos_channel_mirrors m
                                    WHERE m.org_id = e.org_id AND m.provider = p_provider AND m.external_id = v_ext
                                      AND m.event_id <> p_event_id) THEN
    RAISE EXCEPTION 'exos_channel_set: that % event is already linked to another event', p_provider USING ERRCODE = '23505';
  END IF;

  INSERT INTO public.exos_channel_mirrors AS m (event_id, provider, org_id, mode, external_id, created_by)
  VALUES (p_event_id, p_provider, e.org_id, coalesce(p_mode, 'create'), v_ext, auth.uid())
  ON CONFLICT (event_id, provider) DO UPDATE
     SET mode = CASE WHEN m.external_id IS NOT NULL AND EXCLUDED.mode = 'create' THEN m.mode ELSE EXCLUDED.mode END,
         external_id = coalesce(m.external_id, EXCLUDED.external_id),
         change_seq = m.change_seq + 1, next_try_at = now(), attempts = 0, last_error = NULL;
  RETURN jsonb_build_object('ok', true, 'provider', p_provider);
END $$;
REVOKE ALL ON FUNCTION public.exos_channel_set(uuid, text, text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.exos_channel_set(uuid, text, text, text) TO authenticated, service_role;

-- Stop mirroring (the event on Eventbrite / Luma is left as it is; its sales
-- already counted stay counted). Not while it is the primary source.
CREATE OR REPLACE FUNCTION public.exos_channel_remove(p_event_id uuid, p_provider text)
RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE e public.exos_events%ROWTYPE;
BEGIN
  SELECT * INTO e FROM public.exos_events WHERE id = p_event_id;
  IF e.id IS NULL OR coalesce(public._exos_integ_role(e.org_id, auth.uid()), '') NOT IN ('owner', 'manager') THEN
    RAISE EXCEPTION 'exos_channel_remove: owner or manager only' USING ERRCODE = '42501';
  END IF;
  IF e.primary_source = p_provider THEN
    RAISE EXCEPTION 'exos_channel_remove: % is the primary ticketing system; pick another first', p_provider USING ERRCODE = '22023';
  END IF;
  DELETE FROM public.exos_channel_mirrors WHERE event_id = p_event_id AND provider = p_provider;
  RETURN FOUND;
END $$;
REVOKE ALL ON FUNCTION public.exos_channel_remove(uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.exos_channel_remove(uuid, text) TO authenticated, service_role;

-- The primary ticketing system: exos always; eventbrite / luma once that
-- platform sells the event (a mirror, or Eventbrite's door link).
CREATE OR REPLACE FUNCTION public.exos_set_resale_options(
  p_event_id uuid, p_listing_qty integer DEFAULT NULL, p_primary_source text DEFAULT NULL, p_rebalance boolean DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE e public.exos_events%ROWTYPE;
BEGIN
  SELECT * INTO e FROM public.exos_events WHERE id = p_event_id FOR UPDATE;
  IF e.id IS NULL OR NOT (public.exos_is_admin() OR public.exos_has_org_role(e.org_id, ARRAY['owner', 'manager'])) THEN
    RAISE EXCEPTION 'exos_set_resale_options: not allowed' USING ERRCODE = '42501';
  END IF;
  IF p_listing_qty IS NOT NULL AND (p_listing_qty < 1 OR p_listing_qty > 50) THEN
    RAISE EXCEPTION 'exos_set_resale_options: a listing holds 1 to 50 tickets' USING ERRCODE = '22023';
  END IF;
  IF p_primary_source IS NOT NULL AND p_primary_source NOT IN ('exos', 'eventbrite', 'luma') THEN
    RAISE EXCEPTION 'exos_set_resale_options: the primary source is exos, eventbrite or luma' USING ERRCODE = '22023';
  END IF;
  IF p_primary_source = 'eventbrite'
     AND NOT EXISTS (SELECT 1 FROM public.exos_eventbrite_links l WHERE l.event_id = p_event_id)
     AND NOT EXISTS (SELECT 1 FROM public.exos_channel_mirrors m WHERE m.event_id = p_event_id AND m.provider = 'eventbrite') THEN
    RAISE EXCEPTION 'exos_set_resale_options: link this event to Eventbrite first' USING ERRCODE = '22023';
  END IF;
  IF p_primary_source = 'luma'
     AND NOT EXISTS (SELECT 1 FROM public.exos_channel_mirrors m WHERE m.event_id = p_event_id AND m.provider = 'luma') THEN
    RAISE EXCEPTION 'exos_set_resale_options: sell this event on Luma first' USING ERRCODE = '22023';
  END IF;
  UPDATE public.exos_events
     SET resale_listing_qty = coalesce(p_listing_qty, resale_listing_qty),
         primary_source     = coalesce(p_primary_source, primary_source),
         s4k_rebalance      = coalesce(p_rebalance, s4k_rebalance)
   WHERE id = p_event_id
   RETURNING * INTO e;
  RETURN jsonb_build_object('listing_qty', e.resale_listing_qty, 'primary_source', e.primary_source,
                            'rebalance', e.s4k_rebalance);
END $$;
REVOKE ALL ON FUNCTION public.exos_set_resale_options(uuid, integer, text, boolean) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.exos_set_resale_options(uuid, integer, text, boolean) TO authenticated, service_role;

-- The primary hold (mig 20261014150000) for Luma too: the last set of a
-- ticket type mapped to the primary platform is off Exos checkout (and so off
-- the other platforms, which share Exos's count).
CREATE OR REPLACE FUNCTION public._exos_primary_hold(p_tier_id uuid, p_free bigint)
RETURNS integer
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT CASE
    WHEN coalesce(current_setting('exos.primary_hold_off', true), '') = '1' THEN 0
    ELSE coalesce((
      SELECT least(e.resale_listing_qty, greatest(coalesce(p_free, 0), 0))::int
        FROM public.exos_ticket_tiers t
        JOIN public.exos_events e ON e.id = t.event_id
       WHERE t.id = p_tier_id AND e.status <> 'cancelled'
         AND ((e.primary_source = 'eventbrite'
               AND EXISTS (SELECT 1 FROM public.exos_eventbrite_ticket_links k WHERE k.tier_id = t.id AND k.active))
           OR (e.primary_source = 'luma'
               AND EXISTS (SELECT 1 FROM public.exos_luma_ticket_links k WHERE k.tier_id = t.id AND k.active)))), 0)
  END
$$;
REVOKE ALL ON FUNCTION public._exos_primary_hold(uuid, bigint) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_primary_hold(uuid, bigint) TO service_role;

-- Eventbrite gets the held seats only when it is the primary.
SELECT pg_temp.exos_patch_n('public.exos_eventbrite_inventory_apply(uuid, jsonb, timestamp with time zone)',
  'the hold is the primary platform''s',
  $o$    v_share := CASE WHEN v_live THEN greatest(v_avail - v_pack, 0) + v_hold ELSE 0 END;$o$,
  $n$    -- the hold is the primary platform's (mig 20261019090000)
    v_share := CASE WHEN v_live THEN greatest(v_avail - v_pack, 0)
                                     + CASE WHEN e.primary_source = 'eventbrite' THEN v_hold ELSE 0 END ELSE 0 END;$n$, 1);

-- What the event's Channels panel shows. Owner / manager / finance.
CREATE OR REPLACE FUNCTION public.exos_channel_status(p_event_id uuid)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE e public.exos_events%ROWTYPE; v_role text;
BEGIN
  SELECT * INTO e FROM public.exos_events WHERE id = p_event_id;
  v_role := public._exos_integ_role(e.org_id, auth.uid());
  IF e.id IS NULL OR v_role IS NULL THEN
    RAISE EXCEPTION 'exos_channel_status: not authorized for this event' USING ERRCODE = '42501';
  END IF;
  RETURN jsonb_build_object(
    'primary_source', e.primary_source,
    'can_manage', v_role IN ('owner', 'manager'),
    'can_switch', v_role = 'owner',
    'connected', jsonb_build_object(
      'eventbrite', EXISTS (SELECT 1 FROM public.exos_eventbrite_accounts a WHERE a.org_id = e.org_id),
      'luma', EXISTS (SELECT 1 FROM public.exos_org_integrations i WHERE i.org_id = e.org_id AND i.provider = 'luma' AND i.status <> 'disabled')),
    'writes', jsonb_build_object(
      'eventbrite', coalesce((SELECT a.writes_enabled FROM public.exos_eventbrite_accounts a WHERE a.org_id = e.org_id), false),
      'luma', coalesce((SELECT i.writes_enabled FROM public.exos_org_integrations i WHERE i.org_id = e.org_id AND i.provider = 'luma'), false)),
    'mirrors', coalesce((SELECT jsonb_agg(jsonb_build_object(
        'provider', m.provider, 'mode', m.mode, 'external_id', m.external_id, 'external_url', m.external_url,
        'status', m.status, 'in_step', m.synced_seq >= m.change_seq, 'synced_at', m.synced_at,
        'planned_at', m.planned_at, 'last_error', m.last_error,
        'plan_steps', CASE WHEN m.status = 'dry_run' THEN jsonb_array_length(coalesce(m.plan -> 'steps', '[]'::jsonb)) END)
        ORDER BY m.provider) FROM public.exos_channel_mirrors m WHERE m.event_id = p_event_id), '[]'::jsonb),
    'luma_tickets', coalesce((SELECT jsonb_agg(jsonb_build_object(
        'tier_id', k.tier_id, 'name', k.luma_ticket_name, 'luma_sold', k.luma_sold, 'luma_capacity', k.luma_capacity,
        'target_capacity', k.target_capacity, 'pushed_capacity', k.pushed_capacity, 'oversold', k.oversold,
        'last_error', k.last_error) ORDER BY k.luma_ticket_name)
        FROM public.exos_luma_ticket_links k WHERE k.event_id = p_event_id AND k.active), '[]'::jsonb),
    'comps_queued', (SELECT count(*) FROM public.exos_luma_comp_queue q WHERE q.event_id = p_event_id AND q.status IN ('queued', 'sending')));
END $$;
REVOKE ALL ON FUNCTION public.exos_channel_status(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.exos_channel_status(uuid) TO authenticated, service_role;

-- Which platforms an org can sell on (the create-event form). Owner / manager / finance.
CREATE OR REPLACE FUNCTION public.exos_channel_connections(p_org_id uuid)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE v_role text := public._exos_integ_role(p_org_id, auth.uid());
BEGIN
  IF v_role IS NULL THEN
    RAISE EXCEPTION 'exos_channel_connections: not a member of this org' USING ERRCODE = '42501';
  END IF;
  RETURN jsonb_build_object(
    'eventbrite', EXISTS (SELECT 1 FROM public.exos_eventbrite_accounts a WHERE a.org_id = p_org_id),
    'luma', EXISTS (SELECT 1 FROM public.exos_org_integrations i WHERE i.org_id = p_org_id AND i.provider = 'luma' AND i.status <> 'disabled'),
    'writes', jsonb_build_object(
      'eventbrite', coalesce((SELECT a.writes_enabled FROM public.exos_eventbrite_accounts a WHERE a.org_id = p_org_id), false),
      'luma', coalesce((SELECT i.writes_enabled FROM public.exos_org_integrations i WHERE i.org_id = p_org_id AND i.provider = 'luma'), false)),
    'can_switch', v_role = 'owner');
END $$;
REVOKE ALL ON FUNCTION public.exos_channel_connections(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.exos_channel_connections(uuid) TO authenticated, service_role;

-- Comps on a Luma-primary event: queue guests to add on Luma. Owner / manager.
-- p_guests: [{email, name?}], at most 200.
CREATE OR REPLACE FUNCTION public.exos_channel_queue_comps(p_event_id uuid, p_tier_id uuid, p_guests jsonb, p_send_email boolean DEFAULT true)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  e        public.exos_events%ROWTYPE;
  g        jsonb;
  v_email  text;
  v_added  int := 0;
  v_bad    int := 0;
  v_dupe   int := 0;
BEGIN
  SELECT * INTO e FROM public.exos_events WHERE id = p_event_id;
  IF e.id IS NULL OR coalesce(public._exos_integ_role(e.org_id, auth.uid()), '') NOT IN ('owner', 'manager') THEN
    RAISE EXCEPTION 'exos_channel_queue_comps: owner or manager only' USING ERRCODE = '42501';
  END IF;
  IF e.primary_source <> 'luma' THEN
    RAISE EXCEPTION 'exos_channel_queue_comps: comps go on Luma only when Luma is the primary ticketing system' USING ERRCODE = '22023';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.exos_luma_ticket_links k WHERE k.event_id = p_event_id AND k.tier_id = p_tier_id AND k.active) THEN
    RAISE EXCEPTION 'exos_channel_queue_comps: that ticket type isn''t on Luma yet' USING ERRCODE = '22023';
  END IF;
  IF p_guests IS NULL OR jsonb_typeof(p_guests) <> 'array' OR jsonb_array_length(p_guests) > 200 THEN
    RAISE EXCEPTION 'exos_channel_queue_comps: up to 200 guests' USING ERRCODE = '22023';
  END IF;
  FOR g IN SELECT value FROM jsonb_array_elements(p_guests) LOOP
    v_email := lower(btrim(coalesce(g ->> 'email', '')));
    IF v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' OR length(v_email) > 254 THEN
      v_bad := v_bad + 1;
      CONTINUE;
    END IF;
    BEGIN
      INSERT INTO public.exos_luma_comp_queue (event_id, tier_id, email, name, send_email, created_by)
      VALUES (p_event_id, p_tier_id, v_email, left(nullif(btrim(coalesce(g ->> 'name', '')), ''), 80), coalesce(p_send_email, true), auth.uid());
      v_added := v_added + 1;
    EXCEPTION WHEN unique_violation THEN
      v_dupe := v_dupe + 1;
    END;
  END LOOP;
  UPDATE public.exos_channel_mirrors SET next_try_at = now() WHERE event_id = p_event_id AND provider = 'luma';
  RETURN jsonb_build_object('queued', v_added, 'invalid', v_bad, 'already', v_dupe);
END $$;
REVOKE ALL ON FUNCTION public.exos_channel_queue_comps(uuid, uuid, jsonb, boolean) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.exos_channel_queue_comps(uuid, uuid, jsonb, boolean) TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 4. The sync (service role): claim, mark, Luma inventory, Luma comps.
-- ---------------------------------------------------------------------------
-- Mirrors due a pass, each with a 2-minute lease and everything the edge
-- function needs: the event and its ticket types as Exos has them, the
-- existing ticket mappings, the org's credential and switches.
-- Due: changed since the last pass, a pass that failed (backoff), or a Luma
-- mirror's inventory every 2 minutes while the event is on sale.
CREATE OR REPLACE FUNCTION public.exos_channel_claim(p_limit int DEFAULT 10, p_event_id uuid DEFAULT NULL)
RETURNS TABLE (event_id uuid, provider text, org_id uuid, lease_id uuid, change_seq bigint, payload jsonb)
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
#variable_conflict use_column
BEGIN
  RETURN QUERY
  WITH due AS (
    SELECT m.event_id, m.provider
      FROM public.exos_channel_mirrors m
      JOIN public.exos_events e ON e.id = m.event_id
     WHERE (m.lease_until IS NULL OR m.lease_until < now())
       AND coalesce(e.ends_at, e.starts_at, now()) > now() - interval '2 days'
       AND (p_event_id IS NULL OR m.event_id = p_event_id)
       AND (m.synced_seq < m.change_seq AND m.next_try_at <= now()
            OR m.provider = 'luma' AND m.external_id IS NOT NULL AND e.status = 'published'
               AND (m.synced_at IS NULL OR m.synced_at < now() - interval '100 seconds')
            OR p_event_id IS NOT NULL)
     ORDER BY m.next_try_at
     LIMIT greatest(1, least(coalesce(p_limit, 10), 50))
     FOR UPDATE OF m SKIP LOCKED
  ), leased AS (
    UPDATE public.exos_channel_mirrors m
       SET lease_id = gen_random_uuid(), lease_until = now() + interval '2 minutes'
      FROM due
     WHERE m.event_id = due.event_id AND m.provider = due.provider
    RETURNING m.*
  )
  SELECT l.event_id, l.provider, l.org_id, l.lease_id, l.change_seq,
         jsonb_build_object(
           'mirror', jsonb_build_object('mode', l.mode, 'external_id', l.external_id, 'external_url', l.external_url,
                                        'external_meta', l.external_meta, 'last_hash', l.last_hash, 'status', l.status),
           'event', (SELECT to_jsonb(ev) - 'branding' - 'exclusivity' - 'faq' - 'gallery' - 'lineup'
                       FROM public.exos_events ev WHERE ev.id = l.event_id),
           'tiers', coalesce((SELECT jsonb_agg(jsonb_build_object(
                       'id', t.id, 'name', t.name, 'description', t.description, 'price', t.price,
                       'capacity', t.capacity, 'sold', t.sold, 'visibility', t.visibility,
                       'sales_start', t.sales_start, 'sales_end', t.sales_end, 'sort_order', t.sort_order,
                       'is_table', public.exos_tier_is_table(t.id),
                       'in_quota', EXISTS (SELECT 1 FROM public.exos_quota_tiers q WHERE q.tier_id = t.id),
                       'free_now', greatest(coalesce(public.exos_effective_available(t.id), 0), 0))
                       ORDER BY t.sort_order NULLS LAST, t.id)
                       FROM public.exos_ticket_tiers t WHERE t.event_id = l.event_id), '[]'::jsonb),
           'maps', CASE l.provider
             WHEN 'eventbrite' THEN coalesce((SELECT jsonb_agg(jsonb_build_object('tier_id', k.tier_id, 'external_ticket_id', k.eb_ticket_class_id))
                                       FROM public.exos_eventbrite_ticket_links k
                                       JOIN public.exos_eventbrite_links lk ON lk.event_id = k.event_id AND lk.eb_event_id = k.eb_event_id
                                      WHERE k.event_id = l.event_id AND k.active), '[]'::jsonb)
             ELSE coalesce((SELECT jsonb_agg(jsonb_build_object('tier_id', k.tier_id, 'external_ticket_id', k.luma_ticket_type_id))
                              FROM public.exos_luma_ticket_links k
                             WHERE k.event_id = l.event_id AND k.luma_event_id = l.external_id AND k.active), '[]'::jsonb) END,
           'secret', CASE l.provider
             WHEN 'eventbrite' THEN (SELECT d.decrypted_secret FROM public.exos_eventbrite_accounts a
                                       JOIN vault.decrypted_secrets d ON d.id = a.secret_id WHERE a.org_id = l.org_id)
             ELSE (SELECT d.decrypted_secret FROM public.exos_org_integrations i
                     JOIN vault.decrypted_secrets d ON d.id = i.secret_id
                    WHERE i.org_id = l.org_id AND i.provider = 'luma' AND i.status <> 'disabled') END,
           'writes_enabled', CASE l.provider
             WHEN 'eventbrite' THEN coalesce((SELECT a.writes_enabled FROM public.exos_eventbrite_accounts a WHERE a.org_id = l.org_id), false)
             ELSE coalesce((SELECT i.writes_enabled FROM public.exos_org_integrations i WHERE i.org_id = l.org_id AND i.provider = 'luma'), false) END)
    FROM leased l;
END $$;
REVOKE ALL ON FUNCTION public.exos_channel_claim(int, uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_channel_claim(int, uuid) TO service_role;

-- Record a pass. p_result: {state: synced | dry_run | error, external_id?,
-- external_url?, external_meta?, hash?, plan?, error?, tickets?: [{tier_id,
-- external_ticket_id, name}]}. Refused without the lease. The ticket mappings
-- go where the door and inventory syncs read them: Eventbrite's link + class
-- mappings, or Luma's ticket links + the door's backend link.
CREATE OR REPLACE FUNCTION public.exos_channel_mark(
  p_event_id uuid, p_provider text, p_lease uuid, p_change_seq bigint, p_result jsonb
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  m        public.exos_channel_mirrors%ROWTYPE;
  e        public.exos_events%ROWTYPE;
  v_state  text := p_result ->> 'state';
  v_ext    text := nullif(p_result ->> 'external_id', '');
  v_url    text := nullif(p_result ->> 'external_url', '');
  v_list   uuid;
  t        jsonb;
  v_tier   uuid;
  v_tid    text;
  v_maps   int := 0;
BEGIN
  SELECT * INTO m FROM public.exos_channel_mirrors WHERE event_id = p_event_id AND provider = p_provider FOR UPDATE;
  IF m.event_id IS NULL OR m.lease_id IS DISTINCT FROM p_lease OR p_lease IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'lease-lost');
  END IF;
  IF v_state IS NULL OR v_state NOT IN ('synced', 'dry_run', 'error') THEN
    RAISE EXCEPTION 'exos_channel_mark: bad state %', v_state USING ERRCODE = '22023';
  END IF;
  SELECT * INTO e FROM public.exos_events WHERE id = p_event_id;
  IF v_url IS NOT NULL AND (v_url !~ '^https://' OR length(v_url) > 500) THEN v_url := NULL; END IF;

  IF v_state = 'synced' AND v_ext IS NOT NULL AND m.external_id IS DISTINCT FROM v_ext THEN
    IF m.external_id IS NOT NULL THEN
      RAISE EXCEPTION 'exos_channel_mark: the mirror is already % on %', m.external_id, p_provider USING ERRCODE = '22023';
    END IF;
    m.external_id := v_ext;
  END IF;

  -- Where the door and inventory syncs read the platform.
  IF v_state = 'synced' AND m.external_id IS NOT NULL THEN
    IF p_provider = 'eventbrite' THEN
      SELECT id INTO v_list FROM public.exos_guest_lists WHERE event_id = p_event_id AND name = 'Eventbrite' ORDER BY created_at LIMIT 1;
      IF v_list IS NULL THEN
        INSERT INTO public.exos_guest_lists (event_id, org_id, name, max_plus_ones, counts_toward_capacity, created_by)
        VALUES (p_event_id, e.org_id, 'Eventbrite', 0, false, m.created_by) RETURNING id INTO v_list;
      END IF;
      INSERT INTO public.exos_eventbrite_links (event_id, org_id, eb_event_id, eb_event_name, list_id, linked_by, linked_at)
      VALUES (p_event_id, e.org_id, m.external_id, left(e.name, 200), v_list, m.created_by, now())
      ON CONFLICT (event_id) DO NOTHING;
    ELSE
      SELECT id INTO v_list FROM public.exos_guest_lists WHERE event_id = p_event_id AND name = 'Luma' ORDER BY created_at LIMIT 1;
      IF v_list IS NULL THEN
        INSERT INTO public.exos_guest_lists (event_id, org_id, name, max_plus_ones, counts_toward_capacity, created_by)
        VALUES (p_event_id, e.org_id, 'Luma', 0, false, m.created_by) RETURNING id INTO v_list;
      END IF;
      INSERT INTO public.exos_backend_links (event_id, org_id, provider, external_ref, external_name, list_id, linked_by)
      VALUES (p_event_id, e.org_id, 'luma', m.external_id, left(e.name, 200), v_list, m.created_by)
      ON CONFLICT (event_id) DO NOTHING;
    END IF;

    FOR t IN SELECT value FROM jsonb_array_elements(coalesce(p_result -> 'tickets', '[]'::jsonb)) LOOP
      v_tier := CASE WHEN (t ->> 'tier_id') ~* '^[0-9a-f-]{36}$' THEN (t ->> 'tier_id')::uuid END;
      v_tid  := t ->> 'external_ticket_id';
      CONTINUE WHEN v_tier IS NULL OR v_tid IS NULL
                 OR NOT EXISTS (SELECT 1 FROM public.exos_ticket_tiers x WHERE x.id = v_tier AND x.event_id = p_event_id);
      IF p_provider = 'eventbrite' THEN
        CONTINUE WHEN v_tid !~ '^[0-9]{1,24}$'
                   OR NOT EXISTS (SELECT 1 FROM public.exos_eventbrite_links lk WHERE lk.event_id = p_event_id AND lk.eb_event_id = m.external_id);
        UPDATE public.exos_eventbrite_ticket_links SET active = false
         WHERE event_id = p_event_id AND tier_id = v_tier AND active AND eb_ticket_class_id <> v_tid;
        INSERT INTO public.exos_eventbrite_ticket_links AS k (event_id, eb_event_id, eb_ticket_class_id, eb_ticket_class_name, tier_id, active)
        VALUES (p_event_id, m.external_id, v_tid, left(t ->> 'name', 200), v_tier, true)
        ON CONFLICT (event_id, eb_event_id, eb_ticket_class_id) DO UPDATE
          SET tier_id = CASE WHEN k.counted_sold > 0 THEN k.tier_id ELSE EXCLUDED.tier_id END, active = true,
              eb_ticket_class_name = coalesce(EXCLUDED.eb_ticket_class_name, k.eb_ticket_class_name);
      ELSE
        CONTINUE WHEN v_tid !~ '^[A-Za-z0-9_-]{1,64}$';
        UPDATE public.exos_luma_ticket_links SET active = false
         WHERE event_id = p_event_id AND tier_id = v_tier AND active AND luma_ticket_type_id <> v_tid;
        INSERT INTO public.exos_luma_ticket_links AS k (event_id, luma_event_id, luma_ticket_type_id, luma_ticket_name, tier_id, active)
        VALUES (p_event_id, m.external_id, v_tid, left(t ->> 'name', 200), v_tier, true)
        ON CONFLICT (event_id, luma_event_id, luma_ticket_type_id) DO UPDATE
          SET tier_id = CASE WHEN k.counted_sold > 0 THEN k.tier_id ELSE EXCLUDED.tier_id END, active = true,
              luma_ticket_name = coalesce(EXCLUDED.luma_ticket_name, k.luma_ticket_name);
      END IF;
      v_maps := v_maps + 1;
    END LOOP;
  END IF;

  UPDATE public.exos_channel_mirrors
     SET external_id   = m.external_id,
         external_url  = coalesce(v_url, external_url),
         external_meta = CASE WHEN jsonb_typeof(p_result -> 'external_meta') = 'object' AND length((p_result -> 'external_meta')::text) <= 2000
                              THEN external_meta || (p_result -> 'external_meta') ELSE external_meta END,
         status        = v_state,
         -- In step up to what the pass read, unless the plan was only recorded.
         synced_seq    = CASE WHEN v_state = 'synced' THEN greatest(synced_seq, coalesce(p_change_seq, 0)) ELSE synced_seq END,
         last_hash     = CASE WHEN v_state = 'synced' THEN coalesce(left(p_result ->> 'hash', 128), last_hash) ELSE last_hash END,
         plan          = CASE WHEN p_result ? 'plan' THEN p_result -> 'plan' ELSE plan END,
         planned_at    = CASE WHEN p_result ? 'plan' THEN now() ELSE planned_at END,
         synced_at     = CASE WHEN v_state = 'synced' THEN now() ELSE synced_at END,
         attempts      = CASE WHEN v_state = 'error' THEN attempts + 1 ELSE 0 END,
         -- Errors back off (1, 2, 4 ... 60 minutes); a dry run waits for the next change.
         next_try_at   = CASE WHEN v_state = 'error' THEN now() + least(make_interval(mins => (2 ^ least(attempts, 6))::int), interval '60 minutes')
                              WHEN v_state = 'dry_run' THEN now() + interval '10 minutes'
                              ELSE now() END,
         last_error    = CASE WHEN v_state = 'error' THEN left(coalesce(p_result ->> 'error', 'sync failed'), 300) END,
         lease_id = NULL, lease_until = NULL
   WHERE event_id = p_event_id AND provider = p_provider;
  RETURN jsonb_build_object('ok', true, 'state', v_state, 'tickets_mapped', v_maps);
END $$;
REVOKE ALL ON FUNCTION public.exos_channel_mark(uuid, text, uuid, bigint, jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_channel_mark(uuid, text, uuid, bigint, jsonb) TO service_role;

-- Apply what Luma reports (tickets held per ticket type, counted from the
-- guest list: approved guests' tickets) and say what capacity each mapped
-- Luma ticket type should have. Same rules as Eventbrite's
-- (exos_eventbrite_inventory_apply): new sales take seats from the Exos
-- ticket type, refunds give them back (oversold first), and Luma may sell the
-- shared count less one pack, plus the primary hold when Luma is primary.
-- p_counts: [{id, sold}]; p_read_at: when the guest read began.
CREATE OR REPLACE FUNCTION public.exos_luma_inventory_apply(p_event_id uuid, p_counts jsonb, p_read_at timestamptz DEFAULT NULL)
RETURNS TABLE (luma_ticket_type_id text, tier_id uuid, luma_sold integer, target_capacity integer, oversold integer,
               writes_enabled boolean, skip_reason text)
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
#variable_conflict use_column
DECLARE
  m        public.exos_channel_mirrors%ROWTYPE;
  e        public.exos_events%ROWTYPE;
  t        public.exos_luma_ticket_links%ROWTYPE;
  c        jsonb;
  v_read   timestamptz := coalesce(p_read_at, clock_timestamp());
  v_sold   int;
  v_delta  int;
  v_avail  int;
  v_house  int;
  v_take   int;
  v_back   int;
  v_over   int;
  v_pack   int;
  v_hold   int;
  v_live   boolean;
  v_on     boolean;
  v_why    text;
  v_share  int;
  v_promised int := 0;
  v_target int;
BEGIN
  SELECT * INTO m FROM public.exos_channel_mirrors WHERE event_id = p_event_id AND provider = 'luma';
  IF m.event_id IS NULL OR m.external_id IS NULL THEN RETURN; END IF;
  SELECT coalesce(i.writes_enabled, false) INTO v_on FROM public.exos_org_integrations i WHERE i.org_id = m.org_id AND i.provider = 'luma';
  v_on := coalesce(v_on, false);
  PERFORM 1 FROM public.exos_luma_ticket_links x
    WHERE x.event_id = p_event_id ORDER BY x.luma_event_id, x.luma_ticket_type_id FOR UPDATE;

  FOR t IN
    SELECT * FROM public.exos_luma_ticket_links x
     WHERE x.event_id = p_event_id AND x.luma_event_id = m.external_id AND x.active
     ORDER BY x.luma_ticket_type_id
  LOOP
    SELECT y.value INTO c FROM jsonb_array_elements(coalesce(p_counts, '[]'::jsonb)) AS y(value)
     WHERE y.value ->> 'id' = t.luma_ticket_type_id LIMIT 1;
    v_why := CASE
      WHEN t.last_read_at IS NOT NULL AND v_read <= t.last_read_at THEN 'stale'
      WHEN c IS NULL THEN 'ticket type not found on Luma'
      WHEN (c ->> 'sold') !~ '^[0-9]{1,9}$' THEN 'Luma gave no count'
      WHEN coalesce((SELECT capacity FROM public.exos_ticket_tiers WHERE id = t.tier_id), 0) <= 0 THEN 'set a capacity on the Exos ticket type'
      WHEN EXISTS (SELECT 1 FROM public.exos_quota_tiers q WHERE q.tier_id = t.tier_id) THEN 'ticket types in a shared capacity group can''t be shared yet'
    END;
    IF v_why IS NOT NULL THEN
      IF v_why <> 'stale' THEN
        UPDATE public.exos_luma_ticket_links x SET last_error = v_why, last_read_at = v_read
         WHERE x.event_id = t.event_id AND x.luma_event_id = t.luma_event_id AND x.luma_ticket_type_id = t.luma_ticket_type_id;
      END IF;
      luma_ticket_type_id := t.luma_ticket_type_id; tier_id := t.tier_id; luma_sold := NULL; target_capacity := NULL;
      oversold := NULL; writes_enabled := v_on; skip_reason := v_why;
      RETURN NEXT;
      CONTINUE;
    END IF;
    v_sold := (c ->> 'sold')::int;

    -- Checkout's order: the ticket type, then the event.
    PERFORM 1 FROM public.exos_ticket_tiers WHERE id = t.tier_id FOR UPDATE;
    SELECT * INTO e FROM public.exos_events WHERE id = p_event_id FOR UPDATE;
    v_delta := v_sold - t.counted_sold;
    v_over  := t.oversold;
    IF v_delta > 0 THEN
      v_avail := public._exos_tier_free_raw(t.tier_id);   -- the primary hold may be Luma's to sell
      v_house := CASE WHEN coalesce(e.total_tickets, 0) > 0 THEN greatest(e.total_tickets - e.tickets_sold, 0) END;
      v_take  := least(v_delta, greatest(coalesce(v_avail, v_delta), 0), coalesce(v_house, v_delta));
      UPDATE public.exos_ticket_tiers SET sold = sold + v_take WHERE id = t.tier_id;
      UPDATE public.exos_events SET tickets_sold = tickets_sold + v_take WHERE id = p_event_id;
      v_over := v_over + (v_delta - v_take);
    ELSIF v_delta < 0 THEN
      v_back := least(-v_delta, v_over);
      v_over := v_over - v_back;
      v_back := -v_delta - v_back;
      UPDATE public.exos_ticket_tiers SET sold = greatest(0, sold - v_back) WHERE id = t.tier_id;
      UPDATE public.exos_events SET tickets_sold = greatest(0, tickets_sold - v_back) WHERE id = p_event_id;
    END IF;

    SELECT * INTO e FROM public.exos_events WHERE id = p_event_id;
    v_pack := CASE WHEN (e.purchase_limits ->> 'maxPerOrder') ~ '^[0-9]{1,4}$' AND (e.purchase_limits ->> 'maxPerOrder')::int > 0
                   THEN (e.purchase_limits ->> 'maxPerOrder')::int ELSE 8 END;
    IF e.primary_source = 'exos' AND e.distribution_route = 's4k' THEN
      v_pack := greatest(v_pack, e.resale_listing_qty);
    END IF;
    v_live := e.status = 'published' AND coalesce(e.ends_at, e.starts_at, now() + interval '1 day') > now();
    v_avail := greatest(coalesce(public.exos_effective_available(t.tier_id), 0), 0);
    v_hold := CASE WHEN e.primary_source = 'luma' THEN greatest(coalesce(public._exos_tier_free_raw(t.tier_id), 0), 0) - v_avail ELSE 0 END;
    IF coalesce(e.total_tickets, 0) > 0 THEN
      v_avail := least(v_avail, greatest(e.total_tickets - e.tickets_sold - v_promised, 0));
    END IF;
    v_share := CASE WHEN v_live THEN greatest(v_avail - v_pack, 0) + greatest(v_hold, 0) ELSE 0 END;
    IF coalesce(e.total_tickets, 0) > 0 THEN
      v_share := least(v_share, greatest(e.total_tickets - e.tickets_sold - v_promised, 0));
    END IF;
    v_promised := v_promised + v_share;
    v_target := v_sold + v_share;

    UPDATE public.exos_luma_ticket_links x
       SET counted_sold = v_sold, oversold = v_over, luma_sold = v_sold,
           target_capacity = v_target, last_read_at = v_read, last_error = NULL
     WHERE x.event_id = t.event_id AND x.luma_event_id = t.luma_event_id AND x.luma_ticket_type_id = t.luma_ticket_type_id;

    luma_ticket_type_id := t.luma_ticket_type_id; tier_id := t.tier_id; luma_sold := v_sold;
    target_capacity := v_target; oversold := v_over; writes_enabled := v_on; skip_reason := NULL;
    RETURN NEXT;
  END LOOP;
END $$;
REVOKE ALL ON FUNCTION public.exos_luma_inventory_apply(uuid, jsonb, timestamptz) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_luma_inventory_apply(uuid, jsonb, timestamptz) TO service_role;

CREATE OR REPLACE FUNCTION public.exos_luma_inventory_ack(
  p_event_id uuid, p_ticket_type_id text, p_plan jsonb, p_sent boolean, p_capacity integer, p_error text DEFAULT NULL
) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  UPDATE public.exos_luma_ticket_links t
     SET plan = p_plan, planned_at = now(),
         pushed_capacity = CASE WHEN p_sent AND p_error IS NULL THEN p_capacity ELSE t.pushed_capacity END,
         pushed_at       = CASE WHEN p_sent AND p_error IS NULL THEN now() ELSE t.pushed_at END,
         luma_capacity   = CASE WHEN p_sent AND p_error IS NULL THEN p_capacity ELSE t.luma_capacity END,
         last_error      = left(p_error, 200)
    FROM public.exos_channel_mirrors m
   WHERE m.event_id = p_event_id AND m.provider = 'luma' AND t.event_id = p_event_id
     AND t.luma_event_id = m.external_id AND t.luma_ticket_type_id = p_ticket_type_id;
END $$;
REVOKE ALL ON FUNCTION public.exos_luma_inventory_ack(uuid, text, jsonb, boolean, integer, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_luma_inventory_ack(uuid, text, jsonb, boolean, integer, text) TO service_role;

-- Comps to add on Luma for one event (a lease of 5 minutes on each).
CREATE OR REPLACE FUNCTION public.exos_luma_comp_claim(p_event_id uuid, p_limit int DEFAULT 50)
RETURNS TABLE (id uuid, email text, name text, send_email boolean, luma_ticket_type_id text)
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
#variable_conflict use_column
BEGIN
  RETURN QUERY
  WITH due AS (
    SELECT q.id FROM public.exos_luma_comp_queue q
     WHERE q.event_id = p_event_id
       AND (q.status = 'queued' OR q.status = 'sending' AND q.claimed_at < now() - interval '5 minutes')
       AND q.attempts < 5
     ORDER BY q.created_at
     LIMIT greatest(1, least(coalesce(p_limit, 50), 100))
     FOR UPDATE SKIP LOCKED
  ), c AS (
    UPDATE public.exos_luma_comp_queue q SET status = 'sending', claimed_at = now(), attempts = q.attempts + 1
      FROM due WHERE q.id = due.id
    RETURNING q.*
  )
  SELECT c.id, c.email, c.name, c.send_email, k.luma_ticket_type_id
    FROM c
    LEFT JOIN public.exos_luma_ticket_links k ON k.event_id = c.event_id AND k.tier_id = c.tier_id AND k.active;
END $$;
REVOKE ALL ON FUNCTION public.exos_luma_comp_claim(uuid, int) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_luma_comp_claim(uuid, int) TO service_role;

-- p_status: added (sent), planned (dry run), skipped (Luma refused the
-- address), failed (retried up to 5 times, then left failed), retry.
CREATE OR REPLACE FUNCTION public.exos_luma_comp_mark(p_id uuid, p_status text, p_error text DEFAULT NULL)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF p_status IS NULL OR p_status NOT IN ('added', 'planned', 'skipped', 'failed', 'retry') THEN
    RAISE EXCEPTION 'exos_luma_comp_mark: bad status %', p_status USING ERRCODE = '22023';
  END IF;
  UPDATE public.exos_luma_comp_queue
     SET status = CASE WHEN p_status = 'retry' THEN CASE WHEN attempts >= 5 THEN 'failed' ELSE 'queued' END
                       WHEN p_status = 'planned' THEN 'queued' ELSE p_status END,
         last_error = left(p_error, 200),
         done_at = CASE WHEN p_status IN ('added', 'skipped', 'failed') THEN now() END,
         -- A dry run leaves the comp queued (it is sent once writes are on) without using up tries.
         attempts = CASE WHEN p_status = 'planned' THEN greatest(attempts - 1, 0) ELSE attempts END
   WHERE id = p_id AND status = 'sending';
END $$;
REVOKE ALL ON FUNCTION public.exos_luma_comp_mark(uuid, text, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_luma_comp_mark(uuid, text, text) TO service_role;

-- ---------------------------------------------------------------------------
-- 5. Schedule: every 2 minutes (odd minutes; the integrations sync runs even).
-- ---------------------------------------------------------------------------
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron')
     AND to_regprocedure('public._cron_invoke_edge_fn(text, jsonb)') IS NOT NULL THEN
    IF EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'exos-channel-sync-2min') THEN
      PERFORM cron.unschedule('exos-channel-sync-2min');
    END IF;
    PERFORM cron.schedule('exos-channel-sync-2min', '1-59/2 * * * *', $cron$
      SELECT public._cron_invoke_edge_fn(
        coalesce(nullif(current_setting('app.exos_functions_url', true), ''),
                 'https://hzrizjeaxlqcxfrtczpq.supabase.co/functions/v1') || '/exos-channel-sync/cron', '{}'::jsonb);
    $cron$);
  END IF;
END $$;

-- ROLLBACK (manual): unschedule exos-channel-sync-2min; drop the exos_channel_* /
-- exos_luma_* functions and tables, the two exos_*_channel_dirty triggers and
-- exos_tg_channel_dirty; restore _exos_primary_hold, exos_set_resale_options and the
-- primary_source check from 20261014150000; drop exos_org_integrations.writes_enabled.
