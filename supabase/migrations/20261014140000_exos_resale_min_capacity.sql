-- ============================================================================
-- Resale unlocks at a max capacity of 250 (operator rule 2026-10-14)
-- ============================================================================
-- Touches:  C: TABLE exos_platform_settings (service role only)
--           C: FUNCTION exos_resale_min_capacity, exos_event_max_capacity,
--              exos_resale_unlocked, _exos_resale_locked_msg (service role),
--              exos_tg_tier_resale_resync (trigger on exos_ticket_tiers)
--           W: FUNCTION exos_set_channel_allocation, exos_request_distribution,
--              exos_sync_marketplace_distribution, _exos_channel_split_plan,
--              exos_channel_pool_plan, exos_set_distribution_route,
--              exos_set_s4k_split, _exos_feed_eligible (patched in place)
--           W: TRIGGER exos_events_marketplace_distribution (+ total_tickets)
-- Pre-reqs: 20261014130000 (S4K pools) and the marketplace chain before it
--
-- StubHub, SeatGeek, Gametime, GoTickets, Vivid Seats, Ticket Evolution (Exos
-- lists directly) and the S4K route (S4K lists on the same marketplaces) are
-- only for events whose max capacity is at least 250:
--
--   max capacity = the overall cap (total_tickets) when set, but never more
--                  than its capped ticket types add up to (unless a ticket
--                  type has no cap, then the overall cap);
--                  with no overall cap, the sum of the capped ticket types.
--   A table counts as its party size (capacity is tables; the cap is people).
--   A ticket type with no cap and no overall cap adds nothing, so an
--   unlimited free RSVP can't unlock resale.
--   250 is the default; the operator can change it with a row in
--   exos_platform_settings ('resale_min_capacity', service role only).
--
-- Below 250: no marketplace event rows are made, no allocation or S4K split
-- can be set, the auto split plans nothing, the S4K route can't be chosen and
-- the feed leaves the event out. An event that drops below 250 later (a cap
-- lowered) has its marketplace pools planned to 0 (a live listing is shrunk
-- once the marketplace has the lower number, as any pool) and its S4K pool
-- released; it stays on the S4K route but off the feed. Eventbrite is not
-- resale and is not affected.
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
-- 1. The rule.
-- ---------------------------------------------------------------------------
-- Operator settings (service role only). No row = the default.
CREATE TABLE IF NOT EXISTS public.exos_platform_settings (
  key         text PRIMARY KEY CHECK (key ~ '^[a-z_]{1,60}$'),
  value       jsonb NOT NULL,
  updated_at  timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.exos_platform_settings ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.exos_platform_settings FROM PUBLIC, anon, authenticated;
GRANT ALL ON TABLE public.exos_platform_settings TO service_role;
COMMENT ON TABLE public.exos_platform_settings IS
  'Operator-set platform rules (resale_min_capacity, default 250). Service role only. mig 20261014140000.';

CREATE OR REPLACE FUNCTION public.exos_resale_min_capacity()
RETURNS integer LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT coalesce((SELECT CASE WHEN jsonb_typeof(value) = 'number' AND (value #>> '{}') ~ '^[0-9]{1,6}$'
                               THEN (value #>> '{}')::int END
                     FROM public.exos_platform_settings WHERE key = 'resale_min_capacity'), 250)
$$;
REVOKE ALL ON FUNCTION public.exos_resale_min_capacity() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.exos_resale_min_capacity() TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.exos_event_max_capacity(p_event_id uuid)
RETURNS integer
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT CASE
           WHEN coalesce(e.total_tickets, 0) > 0 AND coalesce(bool_or(t.capacity = 0), false) THEN e.total_tickets
           WHEN coalesce(e.total_tickets, 0) > 0
             THEN least(e.total_tickets, coalesce(sum(t.capacity * CASE WHEN t.kind = 'table' THEN greatest(coalesce(t.party_size, 1), 1) ELSE 1 END)
                            FILTER (WHERE t.capacity > 0), 0))::int
           ELSE coalesce(sum(t.capacity * CASE WHEN t.kind = 'table' THEN greatest(coalesce(t.party_size, 1), 1) ELSE 1 END)
                            FILTER (WHERE t.capacity > 0), 0)::int
         END
    FROM public.exos_events e
    LEFT JOIN public.exos_ticket_tiers t ON t.event_id = e.id
   WHERE e.id = p_event_id
   GROUP BY e.id, e.total_tickets
$$;
REVOKE ALL ON FUNCTION public.exos_event_max_capacity(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_event_max_capacity(uuid) TO service_role;

CREATE OR REPLACE FUNCTION public.exos_resale_unlocked(p_event_id uuid)
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$ SELECT coalesce(public.exos_event_max_capacity(p_event_id), 0) >= public.exos_resale_min_capacity() $$;
REVOKE ALL ON FUNCTION public.exos_resale_unlocked(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_resale_unlocked(uuid) TO service_role;

CREATE OR REPLACE FUNCTION public._exos_resale_locked_msg(p_event_id uuid)
RETURNS text
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT format('resale marketplaces unlock at a max capacity of %s; this event''s is %s',
                public.exos_resale_min_capacity(), coalesce(public.exos_event_max_capacity(p_event_id), 0))
$$;
REVOKE ALL ON FUNCTION public._exos_resale_locked_msg(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_resale_locked_msg(uuid) TO service_role;

-- ---------------------------------------------------------------------------
-- 2. Direct marketplaces: no allocation, no distribution request, no
--    marketplace event rows, no auto split, pools planned to 0.
-- ---------------------------------------------------------------------------
SELECT pg_temp.exos_patch_n('public.exos_set_channel_allocation(uuid, text, uuid, integer)',
  'exos_resale_unlocked',
  $o$  IF v_ev.status = 'cancelled' AND p_qty > 0 THEN
    RAISE EXCEPTION 'exos_set_channel_allocation: event is cancelled';
  END IF;$o$,
  $n$  IF v_ev.status = 'cancelled' AND p_qty > 0 THEN
    RAISE EXCEPTION 'exos_set_channel_allocation: event is cancelled';
  END IF;
  -- Resale needs a max capacity of 250 (mig 20261014140000).
  IF p_qty > 0 AND NOT public.exos_resale_unlocked(p_event_id) THEN
    RAISE EXCEPTION 'exos_set_channel_allocation: %', public._exos_resale_locked_msg(p_event_id) USING ERRCODE = '22023';
  END IF;$n$, 1);

SELECT pg_temp.exos_patch_n('public.exos_request_distribution(uuid, text[], integer, numeric)',
  'exos_resale_unlocked',
  $o$  IF p_channels IS NULL OR array_length(p_channels, 1) IS NULL THEN$o$,
  $n$  -- Resale needs a max capacity of 250 (mig 20261014140000).
  IF NOT public.exos_resale_unlocked(p_event_id) THEN
    RAISE EXCEPTION 'exos_request_distribution: %', public._exos_resale_locked_msg(p_event_id) USING ERRCODE = '22023';
  END IF;
  IF p_channels IS NULL OR array_length(p_channels, 1) IS NULL THEN$n$, 1);

-- Below 250 a ticked marketplace counts as not ticked: pending event rows go
-- and allocations are pulled, as when it is unticked.
SELECT pg_temp.exos_patch_n('public.exos_sync_marketplace_distribution()',
  'exos_resale_unlocked',
  $o$    v_ticked := v_ch = ANY (coalesce(NEW.distribution_networks, '{}'::text[]));$o$,
  $n$    v_ticked := v_ch = ANY (coalesce(NEW.distribution_networks, '{}'::text[]))
                AND public.exos_resale_unlocked(NEW.id);   -- 250+ capacity (mig 20261014140000)$n$, 1);

SELECT pg_temp.exos_patch_n('public._exos_channel_split_plan(uuid)',
  'exos_resale_unlocked',
  $o$  IF e.id IS NULL OR e.distribution_route = 's4k' THEN   -- S4K lists it
    RETURN;
  END IF;$o$,
  $n$  IF e.id IS NULL OR e.distribution_route = 's4k' THEN   -- S4K lists it
    RETURN;
  END IF;
  IF NOT public.exos_resale_unlocked(p_event_id) THEN       -- under 250 (mig 20261014140000)
    RETURN;
  END IF;$n$, 1);

SELECT pg_temp.exos_patch_n('public.exos_channel_pool_plan(uuid)',
  'exos_resale_unlocked',
  $o$  -- S4K pool (mig 20261014130000): the organizer's split, held whole.$o$,
  $n$  -- Under 250 capacity (mig 20261014140000): no resale, every pool to 0.
  IF NOT public.exos_resale_unlocked(d.event_id) THEN
    RETURN QUERY SELECT 0, 'locked'::text, 0;
    RETURN;
  END IF;
  -- S4K pool (mig 20261014130000): the organizer's split, held whole.$n$, 1);

-- The trigger also re-runs when the overall cap changes.
CREATE OR REPLACE TRIGGER exos_events_marketplace_distribution
  AFTER INSERT OR UPDATE OF status, distribution_networks, exclusivity, name, starts_at, venue_name, venue_location,
                            venue_address, total_tickets
  ON public.exos_events FOR EACH ROW EXECUTE FUNCTION public.exos_sync_marketplace_distribution();

-- A ticket type's capacity moves the event's max capacity: re-run the
-- marketplace sync for the event (it reads the rule above).
CREATE OR REPLACE FUNCTION public.exos_tg_tier_resale_resync()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE v_event uuid := CASE WHEN TG_OP = 'DELETE' THEN OLD.event_id ELSE NEW.event_id END;
BEGIN
  IF TG_OP = 'UPDATE' AND NEW.capacity IS NOT DISTINCT FROM OLD.capacity THEN
    RETURN NULL;
  END IF;
  UPDATE public.exos_events SET distribution_networks = distribution_networks
   WHERE id = v_event AND cardinality(coalesce(distribution_networks, '{}'::text[])) > 0;
  RETURN NULL;
END $$;
REVOKE ALL ON FUNCTION public.exos_tg_tier_resale_resync() FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE TRIGGER exos_tiers_resale_resync
  AFTER INSERT OR DELETE OR UPDATE OF capacity, kind, party_size ON public.exos_ticket_tiers
  FOR EACH ROW EXECUTE FUNCTION public.exos_tg_tier_resale_resync();

-- ---------------------------------------------------------------------------
-- 3. S4K: the route, the split and the feed.
-- ---------------------------------------------------------------------------
SELECT pg_temp.exos_patch_n('public.exos_set_distribution_route(uuid, text)',
  'exos_resale_unlocked',
  $o$    IF NOT coalesce(v_on, false) THEN
      RAISE EXCEPTION 'join the S4K network first (organization settings)' USING ERRCODE = '22023';
    END IF;$o$,
  $n$    IF NOT coalesce(v_on, false) THEN
      RAISE EXCEPTION 'join the S4K network first (organization settings)' USING ERRCODE = '22023';
    END IF;
    IF NOT public.exos_resale_unlocked(p_event_id) THEN    -- 250+ capacity (mig 20261014140000)
      RAISE EXCEPTION '%', public._exos_resale_locked_msg(p_event_id) USING ERRCODE = '22023';
    END IF;$n$, 1);

SELECT pg_temp.exos_patch_n('public.exos_set_s4k_split(uuid, jsonb)',
  'exos_resale_unlocked',
  $o$      IF public.exos_rr_tier_price(t.id) <= 0 THEN
        RAISE EXCEPTION 'exos_set_s4k_split: % is free: resale marketplaces don''t sell free tickets', t.name USING ERRCODE = '22023';
      END IF;$o$,
  $n$      IF public.exos_rr_tier_price(t.id) <= 0 THEN
        RAISE EXCEPTION 'exos_set_s4k_split: % is free: resale marketplaces don''t sell free tickets', t.name USING ERRCODE = '22023';
      END IF;
      IF NOT public.exos_resale_unlocked(p_event_id) THEN    -- 250+ capacity (mig 20261014140000)
        RAISE EXCEPTION 'exos_set_s4k_split: %', public._exos_resale_locked_msg(p_event_id) USING ERRCODE = '22023';
      END IF;$n$, 1);

CREATE OR REPLACE FUNCTION public._exos_feed_eligible(p_event_id uuid)
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.exos_events e JOIN public.exos_orgs o ON o.id = e.org_id
     WHERE e.id = p_event_id AND o.s4k_network AND e.distribution_route = 's4k'
       AND e.status = 'published' AND coalesce(e.doors_at, e.starts_at) > now())
    AND public.exos_resale_unlocked(p_event_id);   -- 250+ capacity (mig 20261014140000)
$$;

-- ROLLBACK (manual): re-create the patched functions from 20261014130000 and
-- earlier; restore the trigger's column list (without total_tickets); drop
-- exos_tiers_resale_resync, exos_tg_tier_resale_resync and the four helpers.
