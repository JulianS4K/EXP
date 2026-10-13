-- ============================================================================
-- Eventbrite inventory: one shared count across Exos and Eventbrite
-- ============================================================================
-- Touches:  C: TABLE exos_eventbrite_ticket_links (service role only)
--           W: exos_eventbrite_accounts (+ writes_enabled)
--           C: FUNCTION exos_eventbrite_map_ticket, exos_eventbrite_set_writes,
--              exos_eventbrite_inventory_apply, exos_eventbrite_inventory_ack
--              (service role); exos_eventbrite_inventory_status (authenticated,
--              role-checked)
--           W: exos_ticket_tiers.sold, exos_events.tickets_sold (Eventbrite
--              sales take seats; refunds give them back)
-- Pre-reqs: 20261013100000 (accounts, links, _exos_eb_role)
--
-- docs/marketplace/eventbrite/README.md "Inventory". An organizer links each
-- Exos ticket type to a ticket class that ALREADY EXISTS on their Eventbrite
-- event; Exos never creates ticket classes (or events) there. Then:
--   1. Eventbrite's quantity_sold for the class (read with
--      GET /events/{id}/ticket_classes/) is counted against the Exos ticket
--      type: new sales take seats from it, refunds give them back. A sale
--      Exos had no seat for is counted as oversold and shown to the organizer.
--   2. The capacity Eventbrite should have is worked out so that what it has
--      left to sell is the shared count: capacity = quantity_sold + shared,
--      shared = max(0, free on Exos now - one pack) (one pack = max per order,
--      else 8: the buffer for the sync's lag). Free ticket types are shared
--      too (Eventbrite may sell them; resale marketplaces don't).
--   3. The edge function sends that capacity with Update a Ticket Class
--      (capacity only), or, unless BOTH the org's writes_enabled switch AND the
--      operator's EXOS_EVENTBRITE_WRITES=on are set, only records the plan
--      (dry run).
-- Classes that live in an Eventbrite inventory tier are skipped: the tier,
-- not the class, holds their quantity (not supported yet).
-- Prod apply needs operator OK.

ALTER TABLE public.exos_eventbrite_accounts ADD COLUMN IF NOT EXISTS writes_enabled boolean NOT NULL DEFAULT false;

CREATE TABLE IF NOT EXISTS public.exos_eventbrite_ticket_links (
  event_id            uuid NOT NULL REFERENCES public.exos_events (id) ON DELETE CASCADE,
  eb_event_id         text NOT NULL CHECK (eb_event_id ~ '^[0-9]{1,24}$'),
  eb_ticket_class_id  text NOT NULL CHECK (eb_ticket_class_id ~ '^[0-9]{1,24}$'),
  eb_ticket_class_name text CHECK (eb_ticket_class_name IS NULL OR length(eb_ticket_class_name) <= 200),
  tier_id             uuid NOT NULL REFERENCES public.exos_ticket_tiers (id) ON DELETE CASCADE,
  active              boolean NOT NULL DEFAULT true,
  -- Eventbrite sales already taken from the Exos ticket type (kept after an
  -- unmap, so mapping the class again doesn't count them twice).
  counted_sold        integer NOT NULL DEFAULT 0 CHECK (counted_sold >= 0),
  -- Of those, the ones Exos had no seat for.
  oversold            integer NOT NULL DEFAULT 0 CHECK (oversold >= 0),
  eb_sold             integer,
  eb_capacity         integer,
  target_capacity     integer,
  pushed_capacity     integer,
  pushed_at           timestamptz,
  plan                jsonb,          -- the last request planned (dry run) or sent
  planned_at          timestamptz,
  last_read_at        timestamptz,
  last_error          text CHECK (last_error IS NULL OR length(last_error) <= 200),
  created_at          timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (event_id, eb_event_id, eb_ticket_class_id)
);
CREATE UNIQUE INDEX IF NOT EXISTS exos_eventbrite_ticket_links_tier_uq
  ON public.exos_eventbrite_ticket_links (event_id, tier_id) WHERE active;
ALTER TABLE public.exos_eventbrite_ticket_links ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.exos_eventbrite_ticket_links FROM PUBLIC, anon, authenticated;
GRANT ALL ON TABLE public.exos_eventbrite_ticket_links TO service_role;
COMMENT ON TABLE public.exos_eventbrite_ticket_links IS
  'Exos ticket type <-> existing Eventbrite ticket class: one shared count. Service role only. mig 20261014110000.';

-- ---------------------------------------------------------------------------
-- Map (or with p_tier_id NULL, unmap) an Eventbrite ticket class. Owner / manager.
CREATE OR REPLACE FUNCTION public.exos_eventbrite_map_ticket(
  p_event_id uuid, p_user_id uuid, p_eb_ticket_class_id text, p_eb_ticket_class_name text, p_tier_id uuid
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_org  uuid;
  lk     public.exos_eventbrite_links%ROWTYPE;
  r      public.exos_eventbrite_ticket_links%ROWTYPE;
  v_tev  uuid;
BEGIN
  SELECT org_id INTO v_org FROM public.exos_events WHERE id = p_event_id;
  IF coalesce(public._exos_eb_role(v_org, p_user_id), '') NOT IN ('owner', 'manager') THEN
    RAISE EXCEPTION 'exos_eventbrite_map_ticket: owner or manager only' USING ERRCODE = '42501';
  END IF;
  SELECT * INTO lk FROM public.exos_eventbrite_links WHERE event_id = p_event_id;
  IF lk.event_id IS NULL THEN
    RAISE EXCEPTION 'exos_eventbrite_map_ticket: link an Eventbrite event first' USING ERRCODE = '22023';
  END IF;
  IF p_eb_ticket_class_id IS NULL OR p_eb_ticket_class_id !~ '^[0-9]{1,24}$' THEN
    RAISE EXCEPTION 'exos_eventbrite_map_ticket: bad ticket class' USING ERRCODE = '22023';
  END IF;
  SELECT * INTO r FROM public.exos_eventbrite_ticket_links
   WHERE event_id = p_event_id AND eb_event_id = lk.eb_event_id AND eb_ticket_class_id = p_eb_ticket_class_id FOR UPDATE;

  IF p_tier_id IS NULL THEN
    UPDATE public.exos_eventbrite_ticket_links SET active = false
     WHERE event_id = p_event_id AND eb_event_id = lk.eb_event_id AND eb_ticket_class_id = p_eb_ticket_class_id;
    RETURN jsonb_build_object('mapped', false);
  END IF;

  SELECT event_id INTO v_tev FROM public.exos_ticket_tiers WHERE id = p_tier_id;
  IF v_tev IS DISTINCT FROM p_event_id THEN
    RAISE EXCEPTION 'exos_eventbrite_map_ticket: ticket type not found for this event' USING ERRCODE = '22023';
  END IF;
  IF public.exos_tier_is_table(p_tier_id) THEN
    RAISE EXCEPTION 'exos_eventbrite_map_ticket: table ticket types can''t be shared with Eventbrite' USING ERRCODE = '22023';
  END IF;
  -- Sales already counted belong to the ticket type they were taken from.
  IF r.eb_ticket_class_id IS NOT NULL AND r.tier_id <> p_tier_id AND r.counted_sold > 0 THEN
    RAISE EXCEPTION 'exos_eventbrite_map_ticket: % Eventbrite sales of this class are already counted against another ticket type', r.counted_sold
      USING ERRCODE = '22023';
  END IF;
  -- One class per ticket type.
  UPDATE public.exos_eventbrite_ticket_links SET active = false
   WHERE event_id = p_event_id AND tier_id = p_tier_id AND active AND eb_ticket_class_id <> p_eb_ticket_class_id;
  INSERT INTO public.exos_eventbrite_ticket_links AS t (event_id, eb_event_id, eb_ticket_class_id, eb_ticket_class_name, tier_id, active)
  VALUES (p_event_id, lk.eb_event_id, p_eb_ticket_class_id, left(p_eb_ticket_class_name, 200), p_tier_id, true)
  ON CONFLICT (event_id, eb_event_id, eb_ticket_class_id) DO UPDATE
    SET tier_id = EXCLUDED.tier_id, active = true,
        eb_ticket_class_name = coalesce(EXCLUDED.eb_ticket_class_name, t.eb_ticket_class_name), last_error = NULL;
  RETURN jsonb_build_object('mapped', true, 'tier_id', p_tier_id, 'eb_ticket_class_id', p_eb_ticket_class_id);
END $$;
REVOKE ALL ON FUNCTION public.exos_eventbrite_map_ticket(uuid, uuid, text, text, uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_eventbrite_map_ticket(uuid, uuid, text, text, uuid) TO service_role;

-- The org's switch for sending capacity to Eventbrite. Owner only. Sending
-- also needs the operator's EXOS_EVENTBRITE_WRITES=on on the edge function.
CREATE OR REPLACE FUNCTION public.exos_eventbrite_set_writes(p_org_id uuid, p_user_id uuid, p_on boolean)
RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF coalesce(public._exos_eb_role(p_org_id, p_user_id), '') <> 'owner' THEN
    RAISE EXCEPTION 'exos_eventbrite_set_writes: owner only' USING ERRCODE = '42501';
  END IF;
  UPDATE public.exos_eventbrite_accounts SET writes_enabled = coalesce(p_on, false) WHERE org_id = p_org_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'exos_eventbrite_set_writes: connect Eventbrite first' USING ERRCODE = '22023';
  END IF;
  RETURN coalesce(p_on, false);
END $$;
REVOKE ALL ON FUNCTION public.exos_eventbrite_set_writes(uuid, uuid, boolean) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_eventbrite_set_writes(uuid, uuid, boolean) TO service_role;

-- ---------------------------------------------------------------------------
-- Apply what Eventbrite reports for an event's ticket classes, and say what
-- capacity each mapped class should have. p_classes: the ticket classes as
-- read, [{id, name, capacity, quantity_sold, inventory_tier_id}, ...].
-- Returns one row per active mapping.
CREATE OR REPLACE FUNCTION public.exos_eventbrite_inventory_apply(p_event_id uuid, p_classes jsonb)
RETURNS TABLE (eb_ticket_class_id text, tier_id uuid, eb_capacity integer, eb_sold integer,
               target_capacity integer, oversold integer, writes_enabled boolean, skip_reason text)
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
#variable_conflict use_column
DECLARE
  lk      public.exos_eventbrite_links%ROWTYPE;
  e       public.exos_events%ROWTYPE;
  m       record;
  c       jsonb;
  v_sold  int;
  v_cap   int;
  v_delta int;
  v_avail int;
  v_house int;
  v_take  int;
  v_back  int;
  v_over  int;
  v_pack  int;
  v_live  boolean;
  v_on    boolean;
  v_why   text;
BEGIN
  SELECT * INTO lk FROM public.exos_eventbrite_links WHERE event_id = p_event_id;
  IF lk.event_id IS NULL THEN RETURN; END IF;
  SELECT coalesce(a.writes_enabled, false) INTO v_on FROM public.exos_eventbrite_accounts a WHERE a.org_id = lk.org_id;

  FOR m IN
    SELECT t.eb_ticket_class_id AS cls, t.tier_id AS tier FROM public.exos_eventbrite_ticket_links t
     WHERE t.event_id = p_event_id AND t.eb_event_id = lk.eb_event_id AND t.active
     ORDER BY t.eb_ticket_class_id
  LOOP
    -- The mapping row first (two syncs at once count a sale once), then the
    -- event and the ticket type: the same order as every other mint.
    PERFORM 1 FROM public.exos_eventbrite_ticket_links t
      WHERE t.event_id = p_event_id AND t.eb_event_id = lk.eb_event_id AND t.eb_ticket_class_id = m.cls FOR UPDATE;
    SELECT x.value INTO c FROM jsonb_array_elements(coalesce(p_classes, '[]'::jsonb)) AS x(value) WHERE x.value ->> 'id' = m.cls LIMIT 1;
    v_why := CASE
      WHEN c IS NULL THEN 'ticket class not found on Eventbrite'
      WHEN nullif(c ->> 'inventory_tier_id', '') IS NOT NULL THEN 'this class is in an Eventbrite inventory tier: not supported yet'
      WHEN (c ->> 'quantity_sold') !~ '^[0-9]{1,9}$' THEN 'Eventbrite gave no quantity sold'
    END;
    IF v_why IS NOT NULL THEN
      UPDATE public.exos_eventbrite_ticket_links t SET last_error = v_why, last_read_at = now()
       WHERE t.event_id = p_event_id AND t.eb_event_id = lk.eb_event_id AND t.eb_ticket_class_id = m.cls;
      eb_ticket_class_id := m.cls; tier_id := m.tier; eb_capacity := NULL; eb_sold := NULL;
      target_capacity := NULL; oversold := NULL; writes_enabled := v_on; skip_reason := v_why;
      RETURN NEXT;
      CONTINUE;
    END IF;
    v_sold := (c ->> 'quantity_sold')::int;
    v_cap  := CASE WHEN (c ->> 'capacity') ~ '^[0-9]{1,9}$' THEN (c ->> 'capacity')::int END;

    SELECT * INTO e FROM public.exos_events WHERE id = p_event_id FOR UPDATE;
    PERFORM 1 FROM public.exos_ticket_tiers WHERE id = m.tier FOR UPDATE;
    SELECT t.counted_sold - v_sold, t.oversold INTO v_delta, v_over FROM public.exos_eventbrite_ticket_links t
     WHERE t.event_id = p_event_id AND t.eb_event_id = lk.eb_event_id AND t.eb_ticket_class_id = m.cls;
    v_delta := -v_delta;   -- new Eventbrite sales (negative: refunds)

    IF v_delta > 0 THEN
      v_avail := public.exos_effective_available(m.tier);
      v_house := CASE WHEN coalesce(e.total_tickets, 0) > 0 THEN greatest(e.total_tickets - e.tickets_sold, 0) END;
      v_take  := least(v_delta, greatest(coalesce(v_avail, v_delta), 0), coalesce(v_house, v_delta));
      UPDATE public.exos_ticket_tiers SET sold = sold + v_take WHERE id = m.tier;
      UPDATE public.exos_events SET tickets_sold = tickets_sold + v_take WHERE id = p_event_id;
      v_over := v_over + (v_delta - v_take);
    ELSIF v_delta < 0 THEN
      -- A refund on Eventbrite: first out of what was oversold, then seats back.
      v_back := least(-v_delta, v_over);
      v_over := v_over - v_back;
      v_back := -v_delta - v_back;
      UPDATE public.exos_ticket_tiers SET sold = greatest(0, sold - v_back) WHERE id = m.tier;
      UPDATE public.exos_events SET tickets_sold = greatest(0, tickets_sold - v_back) WHERE id = p_event_id;
    END IF;

    -- What Eventbrite may sell from here: the shared count, one pack held back.
    SELECT * INTO e FROM public.exos_events WHERE id = p_event_id;
    v_pack := CASE WHEN (e.purchase_limits ->> 'maxPerOrder') ~ '^[0-9]{1,4}$' AND (e.purchase_limits ->> 'maxPerOrder')::int > 0
                   THEN (e.purchase_limits ->> 'maxPerOrder')::int ELSE 8 END;
    v_live := e.status = 'published' AND coalesce(e.ends_at, e.starts_at, now() + interval '1 day') > now();
    v_avail := greatest(coalesce(public.exos_effective_available(m.tier), 0), 0);
    IF coalesce(e.total_tickets, 0) > 0 THEN
      v_avail := least(v_avail, greatest(e.total_tickets - e.tickets_sold, 0));
    END IF;

    UPDATE public.exos_eventbrite_ticket_links t
       SET counted_sold = v_sold, oversold = v_over, eb_sold = v_sold, eb_capacity = v_cap,
           target_capacity = v_sold + CASE WHEN v_live THEN greatest(v_avail - v_pack, 0) ELSE 0 END,
           last_read_at = now(), last_error = NULL
     WHERE t.event_id = p_event_id AND t.eb_event_id = lk.eb_event_id AND t.eb_ticket_class_id = m.cls
    RETURNING t.target_capacity INTO target_capacity;

    eb_ticket_class_id := m.cls; tier_id := m.tier; eb_capacity := v_cap; eb_sold := v_sold;
    oversold := v_over; writes_enabled := v_on; skip_reason := NULL;
    RETURN NEXT;
  END LOOP;
END $$;
REVOKE ALL ON FUNCTION public.exos_eventbrite_inventory_apply(uuid, jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_eventbrite_inventory_apply(uuid, jsonb) TO service_role;

-- Record what was sent (p_sent) or only planned (dry run), and any error.
CREATE OR REPLACE FUNCTION public.exos_eventbrite_inventory_ack(
  p_event_id uuid, p_eb_ticket_class_id text, p_plan jsonb, p_sent boolean, p_capacity integer, p_error text DEFAULT NULL
) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  UPDATE public.exos_eventbrite_ticket_links t
     SET plan = p_plan, planned_at = now(),
         pushed_capacity = CASE WHEN p_sent AND p_error IS NULL THEN p_capacity ELSE t.pushed_capacity END,
         pushed_at       = CASE WHEN p_sent AND p_error IS NULL THEN now() ELSE t.pushed_at END,
         eb_capacity     = CASE WHEN p_sent AND p_error IS NULL THEN p_capacity ELSE t.eb_capacity END,
         last_error      = left(p_error, 200)
    FROM public.exos_eventbrite_links lk
   WHERE lk.event_id = p_event_id AND t.event_id = p_event_id AND t.eb_event_id = lk.eb_event_id
     AND t.eb_ticket_class_id = p_eb_ticket_class_id;
END $$;
REVOKE ALL ON FUNCTION public.exos_eventbrite_inventory_ack(uuid, text, jsonb, boolean, integer, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_eventbrite_inventory_ack(uuid, text, jsonb, boolean, integer, text) TO service_role;

-- ---------------------------------------------------------------------------
-- What the event's Eventbrite panel shows. Owner / manager (or admin).
CREATE OR REPLACE FUNCTION public.exos_eventbrite_inventory_status(p_event_id uuid)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_org uuid;
  lk    public.exos_eventbrite_links%ROWTYPE;
  v_on  boolean;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'exos_eventbrite_inventory_status: not authenticated' USING ERRCODE = '42501';
  END IF;
  SELECT org_id INTO v_org FROM public.exos_events WHERE id = p_event_id;
  IF coalesce(public._exos_eb_role(v_org, auth.uid()), '') NOT IN ('owner', 'manager') AND NOT public.exos_is_admin() THEN
    RAISE EXCEPTION 'exos_eventbrite_inventory_status: owner or manager only' USING ERRCODE = '42501';
  END IF;
  SELECT * INTO lk FROM public.exos_eventbrite_links WHERE event_id = p_event_id;
  SELECT writes_enabled INTO v_on FROM public.exos_eventbrite_accounts WHERE org_id = v_org;
  RETURN jsonb_build_object(
    'linked', lk.event_id IS NOT NULL,
    'writes_enabled', coalesce(v_on, false),
    'can_switch', public._exos_eb_role(v_org, auth.uid()) = 'owner',
    'tiers', coalesce((SELECT jsonb_agg(jsonb_build_object('id', tt.id, 'name', tt.name, 'capacity', tt.capacity, 'sold', tt.sold)
                                        ORDER BY tt.sort_order NULLS LAST, tt.id)
                         FROM public.exos_ticket_tiers tt
                        WHERE tt.event_id = p_event_id AND NOT public.exos_tier_is_table(tt.id)), '[]'::jsonb),
    'mappings', coalesce((SELECT jsonb_agg(jsonb_build_object(
                            'eb_ticket_class_id', t.eb_ticket_class_id, 'eb_ticket_class_name', t.eb_ticket_class_name,
                            'tier_id', t.tier_id, 'eb_sold', t.eb_sold, 'eb_capacity', t.eb_capacity,
                            'target_capacity', t.target_capacity, 'pushed_capacity', t.pushed_capacity,
                            'pushed_at', t.pushed_at, 'planned_at', t.planned_at, 'oversold', t.oversold,
                            'last_read_at', t.last_read_at, 'last_error', t.last_error)
                            ORDER BY t.eb_ticket_class_id)
                           FROM public.exos_eventbrite_ticket_links t
                          WHERE t.event_id = p_event_id AND t.eb_event_id = lk.eb_event_id AND t.active), '[]'::jsonb));
END $$;
REVOKE ALL ON FUNCTION public.exos_eventbrite_inventory_status(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.exos_eventbrite_inventory_status(uuid) TO authenticated, service_role;
