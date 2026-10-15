-- ============================================================================
-- Two inventory pools: Exos + Eventbrite share one, S4K holds the other, and
-- the organizer picks the split
-- ============================================================================
-- Touches:  W: exos_distribution_listings (channel check + 's4k': an S4K pool
--              is an allocation row, like a marketplace's)
--           C: FUNCTION _exos_s4k_pool, exos_set_s4k_split, exos_s4k_pool_status
--              (authenticated, owner / manager), exos_tg_s4k_route_release
--              (trigger on exos_events)
--           W: FUNCTION exos_channel_pool_plan (patched: an S4K pool holds its
--              whole split), _exos_feed_lines (patched: the feed shows the S4K
--              pool, not Exos's free seats), exos_feed_place_order (patched:
--              an S4K order takes seats from the S4K pool only),
--              exos_feed_cancel_order (patched: seats back to S4K's pool),
--              exos_set_distribution_route, exos_set_s4k_network (patched:
--              lock the S4K pools before the event, as an S4K order does)
-- Pre-reqs: 20261014100000 (S4K feed), 20260928010000 (marketplace pools),
--           20261014110000 (Eventbrite inventory)
--
-- Before this, an event on the S4K route showed S4K everything Exos had free
-- (less one pack), so Exos, Eventbrite and S4K all sold from one count. Now,
-- per ticket type, the organizer says how many seats S4K gets:
--
--   Pool 1, Exos + Eventbrite: capacity - the S4K split. Every Exos sale
--     (checkout, free claims, comps, box office) and the Eventbrite capacity
--     sync (20261014110000) read exos_effective_available, which already
--     leaves allocated seats out, so both sell from this pool and never from
--     S4K's.
--   Pool 2, S4K: the split. It is an allocation row (channel 's4k') that
--     holds all of its seats at once: no top-up schedule, no day-of cutoff,
--     no "stagnant" shrink (those are for direct marketplaces). The feed's
--     count for the ticket type is what the pool holds, with no buffer, since
--     nothing else can sell those seats; an S4K order takes seats from the
--     pool under its row lock, and an order bigger than the pool is
--     rejected as sold_out. It never spills into pool 1.
--
-- The split is the S4K total for the ticket type, sold included (sell_cap):
-- lowering it gives unsold seats back to pool 1 at once; raising it takes
-- seats only if they're free right now in pool 1 (refused with how many
-- are). A seat S4K sold and then cancelled goes back to S4K's pool (it's
-- still S4K's share). Leaving the S4K route (or the network) releases every
-- unsold S4K seat to pool 1; S4K's sold count is kept for when it comes back.
--
-- Not splittable (as for marketplaces): table ticket types, free ticket
-- types (resale marketplaces don't sell them), ticket types with no
-- capacity, and events whose overall cap is below the ticket types' sum (a
-- per-type reserve can't protect it).
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
-- 1. 's4k' as an allocation channel. Same shape as the earlier channel
--    migrations (they re-read the live list on replay).
-- ---------------------------------------------------------------------------
DO $$
DECLARE v_def text;
BEGIN
  SELECT pg_get_constraintdef(oid) INTO v_def FROM pg_constraint
   WHERE conname = 'exos_distribution_listings_channel_check' AND conrelid = 'public.exos_distribution_listings'::regclass;
  IF v_def IS NOT NULL AND position('''s4k''' in v_def) = 0 THEN
    IF position('ARRAY[' in v_def) = 0 THEN
      RAISE EXCEPTION 's4k pools: unexpected shape for exos_distribution_listings_channel_check: %', v_def;
    END IF;
    ALTER TABLE public.exos_distribution_listings DROP CONSTRAINT exos_distribution_listings_channel_check;
    EXECUTE 'ALTER TABLE public.exos_distribution_listings ADD CONSTRAINT exos_distribution_listings_channel_check '
         || replace(v_def, 'ARRAY[', 'ARRAY[''s4k''::text, ');
  END IF;
END $$;

-- ---------------------------------------------------------------------------
-- 2. An S4K pool holds its whole split until it's sold.
-- ---------------------------------------------------------------------------
SELECT pg_temp.exos_patch_n('public.exos_channel_pool_plan(uuid)',
  'S4K pool (mig 20261014130000)',
  $o$  SELECT * INTO e FROM public.exos_events WHERE id = d.event_id;
  v_mpo := CASE$o$,
  $n$  -- S4K pool (mig 20261014130000): the organizer's split, held whole.
  IF d.channel = 's4k' THEN
    RETURN QUERY SELECT greatest(0, d.sell_cap - d.sold_qty), 'split'::text, 0;
    RETURN;
  END IF;
  SELECT * INTO e FROM public.exos_events WHERE id = d.event_id;
  v_mpo := CASE$n$, 1);

-- The S4K pool row for a ticket type (live statuses only).
CREATE OR REPLACE FUNCTION public._exos_s4k_pool(p_tier_id uuid)
RETURNS public.exos_distribution_listings
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT d.* FROM public.exos_distribution_listings d
   WHERE d.tier_id = p_tier_id AND d.channel = 's4k'
     AND d.status IN ('pending', 'planned', 'listing', 'listed')
   LIMIT 1
$$;
REVOKE ALL ON FUNCTION public._exos_s4k_pool(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_s4k_pool(uuid) TO service_role;

-- ---------------------------------------------------------------------------
-- 3. Set the split. p_splits: [{tier_id, seats}], seats = S4K's total for the
--    ticket type (sold included). One transaction: all or none.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.exos_set_s4k_split(p_event_id uuid, p_splits jsonb)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  e       public.exos_events%ROWTYPE;
  v_on    boolean;
  s       jsonb;
  v_tier  uuid;
  v_seats int;
  t       public.exos_ticket_tiers%ROWTYPE;
  d       public.exos_distribution_listings%ROWTYPE;
  v_sum   int;
  v_uncap boolean;
  v_held  int;
  v_avail int;
  q       record;
  v_tiers uuid[] := '{}';
BEGIN
  -- The same lock as a route change: a split can't race the event leaving S4K.
  PERFORM pg_advisory_xact_lock(hashtextextended('exos_route:' || p_event_id::text, 0));
  SELECT * INTO e FROM public.exos_events WHERE id = p_event_id;
  IF e.id IS NULL OR NOT (public.exos_is_admin() OR public.exos_has_org_role(e.org_id, ARRAY['owner', 'manager'])) THEN
    RAISE EXCEPTION 'exos_set_s4k_split: not allowed' USING ERRCODE = '42501';
  END IF;
  -- The owner leaving the network takes the org row first: hold it (shared)
  -- so the two can't interleave, then re-read the route under it.
  SELECT s4k_network INTO v_on FROM public.exos_orgs WHERE id = e.org_id FOR SHARE;
  SELECT * INTO e FROM public.exos_events WHERE id = p_event_id;
  IF NOT coalesce(v_on, false) OR e.distribution_route IS DISTINCT FROM 's4k' THEN
    RAISE EXCEPTION 'exos_set_s4k_split: put this event on the S4K network first' USING ERRCODE = '22023';
  END IF;
  IF e.status = 'cancelled' THEN
    RAISE EXCEPTION 'exos_set_s4k_split: event is cancelled' USING ERRCODE = '22023';
  END IF;
  IF jsonb_typeof(p_splits) IS DISTINCT FROM 'array' OR jsonb_array_length(p_splits) > 100 THEN
    RAISE EXCEPTION 'exos_set_s4k_split: splits must be an array of at most 100' USING ERRCODE = '22023';
  END IF;
  SELECT coalesce(sum(capacity), 0), bool_or(capacity = 0) INTO v_sum, v_uncap
    FROM public.exos_ticket_tiers WHERE event_id = p_event_id;

  -- Shape first, then every lock up front in one order (the pools, then
  -- their quotas, then the ticket types: an S4K order's pool -> quota ->
  -- tier, a checkout's quota -> tier), so a split over several ticket types
  -- can't deadlock with a sale on one of them.
  FOR s IN SELECT value FROM jsonb_array_elements(p_splits) LOOP
    IF jsonb_typeof(s) <> 'object' OR coalesce(s->>'tier_id', '') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
       OR coalesce(s->>'seats', '') !~ '^[0-9]{1,5}$' THEN
      RAISE EXCEPTION 'exos_set_s4k_split: each split is {tier_id, seats} with seats 0-99999' USING ERRCODE = '22023';
    END IF;
    v_tiers := v_tiers || (s->>'tier_id')::uuid;
  END LOOP;
  PERFORM 1 FROM public.exos_distribution_listings
   WHERE event_id = p_event_id AND channel = 's4k' AND tier_id = ANY (v_tiers)
   ORDER BY tier_id FOR UPDATE;
  PERFORM 1 FROM public.exos_quotas
   WHERE id IN (SELECT quota_id FROM public.exos_quota_tiers WHERE tier_id = ANY (v_tiers))
   ORDER BY id FOR UPDATE;
  PERFORM 1 FROM public.exos_ticket_tiers
   WHERE event_id = p_event_id AND id = ANY (v_tiers)
   ORDER BY id FOR UPDATE;

  -- Ticket types in a fixed order, so two splits on one event lock alike.
  FOR s IN SELECT value FROM jsonb_array_elements(p_splits) ORDER BY value->>'tier_id' LOOP
    v_tier := (s->>'tier_id')::uuid;
    v_seats := (s->>'seats')::int;
    SELECT * INTO t FROM public.exos_ticket_tiers WHERE id = v_tier AND event_id = p_event_id;
    IF t.id IS NULL THEN
      RAISE EXCEPTION 'exos_set_s4k_split: ticket type not found for this event' USING ERRCODE = '22023';
    END IF;
    IF v_seats > 0 THEN
      IF public.exos_tier_is_table(t.id) THEN
        RAISE EXCEPTION 'exos_set_s4k_split: % is a table ticket type: tables aren''t sold through S4K', t.name USING ERRCODE = '22023';
      END IF;
      IF t.capacity = 0 THEN
        RAISE EXCEPTION 'exos_set_s4k_split: give % a capacity before splitting it', t.name USING ERRCODE = '22023';
      END IF;
      IF public.exos_rr_tier_price(t.id) <= 0 THEN
        RAISE EXCEPTION 'exos_set_s4k_split: % is free: resale marketplaces don''t sell free tickets', t.name USING ERRCODE = '22023';
      END IF;
      IF e.total_tickets > 0 AND (v_uncap OR e.total_tickets < v_sum) THEN
        RAISE EXCEPTION 'exos_set_s4k_split: the event''s overall capacity (%) is lower than its ticket types add up to (%); raise it to at least their sum first',
          e.total_tickets, v_sum USING ERRCODE = '23514';
      END IF;
    END IF;

    SELECT * INTO d FROM public.exos_distribution_listings
     WHERE event_id = p_event_id AND channel = 's4k' AND tier_id = t.id FOR UPDATE;
    IF d.id IS NOT NULL AND v_seats < d.sold_qty THEN
      RAISE EXCEPTION 'exos_set_s4k_split: S4K has already sold % of %; the split can''t go below that', d.sold_qty, t.name
        USING ERRCODE = '22023';
    END IF;
    v_held := CASE WHEN d.status IN ('pending', 'planned', 'listing', 'listed') THEN greatest(coalesce(d.requested_qty, 0), 0) ELSE 0 END;
    -- Raising it: the extra must be free in pool 1 now, read under the
    -- checkout locks taken above, so it can't race a sale.
    UPDATE public.exos_ticket_tiers SET sort_order = sort_order WHERE id = t.id;
    IF v_seats - coalesce(d.sold_qty, 0) > v_held THEN
      v_avail := greatest(coalesce(public.exos_effective_available(t.id), 0), 0);   -- excludes this pool
      IF v_avail < v_seats - coalesce(d.sold_qty, 0) - v_held THEN
        RAISE EXCEPTION 'exos_set_s4k_split: only % more seat(s) of % are free to give S4K', v_avail, t.name
          USING ERRCODE = '23514';
      END IF;
    END IF;

    IF d.id IS NULL THEN
      CONTINUE WHEN v_seats = 0;
      INSERT INTO public.exos_distribution_listings
        (event_id, org_id, channel, status, tier_id, requested_qty, sell_cap, pool_size, internal_seats)
      VALUES (p_event_id, e.org_id, 's4k', 'planned', t.id, 0, v_seats, NULL, '{}')
      RETURNING * INTO d;
    ELSE
      UPDATE public.exos_distribution_listings
         SET sell_cap = v_seats,
             status = 'planned',
             requested_qty = CASE WHEN status IN ('failed', 'delisted', 'delisting') THEN 0 ELSE requested_qty END,
             internal_seats = CASE WHEN status IN ('failed', 'delisted', 'delisting') THEN '{}'::int4multirange ELSE internal_seats END,
             error = NULL, updated_at = now()
       WHERE id = d.id;
    END IF;
    -- 'planned' with no marketplace listing: the hold moves at once both ways.
    PERFORM public.exos_sync_channel_hold(d.id, true);
  END LOOP;

  PERFORM public.exos_feed_refresh(p_event_id);
  RETURN public.exos_s4k_pool_status(p_event_id);
END $$;
REVOKE ALL ON FUNCTION public.exos_set_s4k_split(uuid, jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.exos_set_s4k_split(uuid, jsonb) TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 4. The two pools, per ticket type.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.exos_s4k_pool_status(p_event_id uuid)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  e  public.exos_events%ROWTYPE;
BEGIN
  SELECT * INTO e FROM public.exos_events WHERE id = p_event_id;
  IF e.id IS NULL OR NOT (public.exos_is_admin()
                          OR public.exos_has_org_role(e.org_id, ARRAY['owner', 'manager', 'finance'])
                          OR auth.uid() IS NULL) THEN   -- the service role (no grant to anon)
    RAISE EXCEPTION 'exos_s4k_pool_status: not allowed' USING ERRCODE = '42501';
  END IF;
  RETURN jsonb_build_object(
    'route', e.distribution_route,
    'on_feed', public._exos_feed_eligible(p_event_id),
    'tiers', coalesce((
      SELECT jsonb_agg(jsonb_build_object(
               'tier_id', t.id, 'name', t.name, 'capacity', t.capacity, 'sold', t.sold,
               'splittable', t.capacity > 0 AND NOT public.exos_tier_is_table(t.id) AND public.exos_rr_tier_price(t.id) > 0,
               -- S4K: its split (sold included), sold, and the seats it holds now.
               's4k_split', coalesce(p.sell_cap, 0),
               's4k_sold', coalesce(p.sold_qty, d.sold_qty, 0),
               's4k_held', coalesce(p.requested_qty, 0),
               -- Exos + Eventbrite: what's free for them now.
               'shared_free', public.exos_effective_available(t.id),
               'eventbrite_mapped', EXISTS (SELECT 1 FROM public.exos_eventbrite_ticket_links k
                                             WHERE k.tier_id = t.id AND k.active))
             ORDER BY t.sort_order NULLS LAST, t.id)
        FROM public.exos_ticket_tiers t
        LEFT JOIN LATERAL (SELECT * FROM public._exos_s4k_pool(t.id)) p ON p.id IS NOT NULL
        LEFT JOIN public.exos_distribution_listings d
          ON d.tier_id = t.id AND d.channel = 's4k' AND d.event_id = t.event_id
       WHERE t.event_id = p_event_id), '[]'::jsonb));
END $$;
REVOKE ALL ON FUNCTION public.exos_s4k_pool_status(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.exos_s4k_pool_status(uuid) TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 5. Leaving the S4K route releases S4K's unsold seats to pool 1 (sold count
--    kept). Fires for both ways out: exos_set_distribution_route and the
--    owner leaving the network (exos_set_s4k_network).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.exos_tg_s4k_route_release()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF OLD.distribution_route = 's4k' AND NEW.distribution_route IS DISTINCT FROM 's4k' THEN
    UPDATE public.exos_distribution_listings
       SET sell_cap = sold_qty, requested_qty = 0, list_qty = 0, internal_seats = '{}', status = 'delisted',
           updated_at = now()
     WHERE event_id = NEW.id AND channel = 's4k' AND tier_id IS NOT NULL
       AND status <> 'delisted';
  END IF;
  RETURN NULL;
END $$;
REVOKE ALL ON FUNCTION public.exos_tg_s4k_route_release() FROM PUBLIC, anon, authenticated;

-- Lock order: an S4K order locks its pool row, then the event (house
-- counter). Both ways out lock the event and then (in the trigger) the pool
-- rows, so they take the pool rows first, in ticket-type order as the split
-- does.
SELECT pg_temp.exos_patch_n('public.exos_set_distribution_route(uuid, text)',
  'S4K pools first (mig 20261014130000)',
  $o$  PERFORM pg_advisory_xact_lock(hashtextextended('exos_route:' || p_event_id::text, 0));
  SELECT * INTO e FROM public.exos_events WHERE id = p_event_id FOR UPDATE;$o$,
  $n$  PERFORM pg_advisory_xact_lock(hashtextextended('exos_route:' || p_event_id::text, 0));
  -- S4K pools first (mig 20261014130000), then the event, as an S4K order;
  -- only for a caller who may change the route (checked again below).
  IF EXISTS (SELECT 1 FROM public.exos_events x WHERE x.id = p_event_id
              AND public.exos_has_org_role(x.org_id, ARRAY['owner','manager'])) THEN
    PERFORM 1 FROM public.exos_distribution_listings d
     WHERE d.event_id = p_event_id AND d.channel = 's4k' AND d.tier_id IS NOT NULL
     ORDER BY d.tier_id FOR UPDATE;
  END IF;
  SELECT * INTO e FROM public.exos_events WHERE id = p_event_id FOR UPDATE;$n$, 1);

SELECT pg_temp.exos_patch_n('public.exos_set_s4k_network(uuid, boolean)',
  'S4K pools first (mig 20261014130000)',
  $o$  IF NOT coalesce(p_on, false) THEN
    UPDATE public.exos_events SET distribution_route = 'direct' WHERE org_id = p_org_id AND distribution_route = 's4k';$o$,
  $n$  IF NOT coalesce(p_on, false) THEN
    -- S4K pools first (mig 20261014130000), then the events, as an S4K order.
    PERFORM 1 FROM public.exos_distribution_listings d
     WHERE d.org_id = p_org_id AND d.channel = 's4k' AND d.tier_id IS NOT NULL
     ORDER BY d.event_id, d.tier_id FOR UPDATE;
    UPDATE public.exos_events SET distribution_route = 'direct' WHERE org_id = p_org_id AND distribution_route = 's4k';$n$, 1);

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'exos_events_s4k_route_release'
                  AND tgrelid = 'public.exos_events'::regclass) THEN
    CREATE TRIGGER exos_events_s4k_route_release AFTER UPDATE OF distribution_route ON public.exos_events
      FOR EACH ROW EXECUTE FUNCTION public.exos_tg_s4k_route_release();
  END IF;
END $$;

-- ---------------------------------------------------------------------------
-- 6. The feed shows the S4K pool. A ticket type with no split isn't on it.
-- ---------------------------------------------------------------------------
SELECT pg_temp.exos_patch_n('public._exos_feed_lines(uuid)',
  'p       public.exos_distribution_listings%ROWTYPE;',
  $o$  v_free  int;
BEGIN$o$,
  $n$  v_free  int;
  p       public.exos_distribution_listings%ROWTYPE;
BEGIN$n$, 1);

SELECT pg_temp.exos_patch_n('public._exos_feed_lines(uuid)',
  'S4K pool (mig 20261014130000)',
  $o$    v_free := greatest(coalesce(public.exos_effective_available(t.id), 0), 0);
    IF v_house IS NOT NULL THEN v_free := least(v_free, v_house); END IF;
    tier_id := t.id; name := t.name; sort_order := t.sort_order;
    free_now := v_free;
    quantity := greatest(v_free - v_pack, 0);
    capacity := t.capacity;$o$,
  $n$    -- S4K pool (mig 20261014130000): what the pool holds, no buffer (only
    -- S4K sells it); the split is the capacity S4K sees.
    SELECT * INTO p FROM public._exos_s4k_pool(t.id);
    CONTINUE WHEN p.id IS NULL OR coalesce(p.sell_cap, 0) = 0;
    v_free := greatest(coalesce(p.requested_qty, 0), 0);
    IF v_house IS NOT NULL THEN v_free := least(v_free, v_house); END IF;
    tier_id := t.id; name := t.name; sort_order := t.sort_order;
    free_now := v_free;
    quantity := v_free;
    capacity := p.sell_cap;$n$, 1);

-- ---------------------------------------------------------------------------
-- 7. An S4K order takes seats from the S4K pool, under the pool row's lock
--    (taken before anything else, as exos_fulfil_marketplace_order then
--    locks it again), or it is rejected: never from pool 1.
-- ---------------------------------------------------------------------------
SELECT pg_temp.exos_patch_n('public.exos_feed_place_order(text, uuid, uuid, integer, text, text, numeric, text, text)',
  'v_pool   uuid;',
  $o$  f        record;
BEGIN$o$,
  $n$  f        record;
  v_pool   uuid;
  v_held   int;
BEGIN$n$, 1);

SELECT pg_temp.exos_patch_n('public.exos_feed_place_order(text, uuid, uuid, integer, text, text, numeric, text, text)',
  'S4K pool (mig 20261014130000)',
  $o$  SELECT * INTO e FROM public.exos_events WHERE id = p_event_id;
  SELECT * INTO l FROM public._exos_feed_lines(p_event_id) x WHERE x.tier_id = p_tier_id;
  v_avail := l.free_now;$o$,
  $n$  SELECT * INTO e FROM public.exos_events WHERE id = p_event_id;
  -- S4K pool (mig 20261014130000): lock it, then read what it holds.
  SELECT d.id, greatest(coalesce(d.requested_qty, 0), 0) INTO v_pool, v_held
    FROM public.exos_distribution_listings d
   WHERE d.event_id = p_event_id AND d.channel = 's4k' AND d.tier_id = p_tier_id
     AND d.status IN ('pending', 'planned', 'listing', 'listed')
   FOR UPDATE;
  SELECT * INTO l FROM public._exos_feed_lines(p_event_id) x WHERE x.tier_id = p_tier_id;
  v_avail := l.free_now;$n$, 1);

SELECT pg_temp.exos_patch_n('public.exos_feed_place_order(text, uuid, uuid, integer, text, text, numeric, text, text)',
  $m$coalesce(v_held, 0) < p_quantity THEN 'sold_out'$m$,
  $o$    WHEN p_unit_price IS NULL OR p_unit_price < l.price - 0.005 THEN 'price_changed'
  END;$o$,
  $n$    WHEN p_unit_price IS NULL OR p_unit_price < l.price - 0.005 THEN 'price_changed'
    WHEN v_pool IS NULL OR coalesce(v_held, 0) < p_quantity THEN 'sold_out'
  END;$n$, 1);

SELECT pg_temp.exos_patch_n('public.exos_feed_place_order(text, uuid, uuid, integer, text, text, numeric, text, text)',
  'distribution_listing_id, raw)',
  $o$        proceeds, list_unit_price, currency, sale_status, sold_at, raw)
      VALUES ('s4k', v_ref, e.id, e.org_id, p_tier_id, p_quantity, v_email,
              round(p_unit_price * p_quantity, 2), p_unit_price, l.currency, 'confirmed', now(),
              jsonb_build_object('consumer_id', v_cons, 'marketplace', v_mkt))$o$,
  $n$        proceeds, list_unit_price, currency, sale_status, sold_at, distribution_listing_id, raw)
      VALUES ('s4k', v_ref, e.id, e.org_id, p_tier_id, p_quantity, v_email,
              round(p_unit_price * p_quantity, 2), p_unit_price, l.currency, 'confirmed', now(), v_pool,
              jsonb_build_object('consumer_id', v_cons, 'marketplace', v_mkt))$n$, 1);

SELECT pg_temp.exos_patch_n('public.exos_feed_place_order(text, uuid, uuid, integer, text, text, numeric, text, text)',
  'were allocated to it%',
  $o$        v_why := CASE WHEN f.reason LIKE 'oversold%' THEN 'sold_out' ELSE 'not_fillable: ' || coalesce(f.reason, f.status) END;$o$,
  $n$        v_why := CASE WHEN f.reason LIKE 'oversold%' OR f.reason LIKE '%were allocated to it%' THEN 'sold_out'
                      ELSE 'not_fillable: ' || coalesce(f.reason, f.status) END;$n$, 1);

-- ---------------------------------------------------------------------------
-- 8. An S4K cancel gives the seats back to S4K's pool (still S4K's share).
--    The pool row is locked first, as for an order (pool, event, tier).
-- ---------------------------------------------------------------------------
SELECT pg_temp.exos_patch_n('public.exos_feed_cancel_order(text, uuid)',
  'S4K pool (mig 20261014130000)',
  $o$  -- Lock order as the mint: event, then tier.
  SELECT * INTO e FROM public.exos_events WHERE id = o.event_id FOR UPDATE;$o$,
  $n$  -- S4K pool (mig 20261014130000) first, then as the mint: event, then tier.
  PERFORM 1 FROM public.exos_distribution_listings WHERE id = o.distribution_listing_id FOR UPDATE;
  SELECT * INTO e FROM public.exos_events WHERE id = o.event_id FOR UPDATE;$n$, 1);

SELECT pg_temp.exos_patch_n('public.exos_feed_cancel_order(text, uuid)',
  'quotas before the tier (mig 20261014130000)',
  $o$  PERFORM 1 FROM public.exos_ticket_tiers WHERE id = o.tier_id FOR UPDATE;$o$,
  $n$  -- The seats go back into S4K's hold, which locks quotas: quotas before the tier (mig 20261014130000), as a checkout.
  PERFORM 1 FROM public.exos_quotas
   WHERE id IN (SELECT quota_id FROM public.exos_quota_tiers WHERE tier_id = o.tier_id)
   ORDER BY id FOR UPDATE;
  PERFORM 1 FROM public.exos_ticket_tiers WHERE id = o.tier_id FOR UPDATE;$n$, 1);

SELECT pg_temp.exos_patch_n('public.exos_feed_cancel_order(text, uuid)',
  'sold_qty = greatest(0, sold_qty - v_n)',
  $o$  UPDATE public.exos_events SET tickets_sold = greatest(0, tickets_sold - v_n) WHERE id = o.event_id;$o$,
  $n$  UPDATE public.exos_events SET tickets_sold = greatest(0, tickets_sold - v_n) WHERE id = o.event_id;
  -- The freed seats go back into S4K's hold (its split is unchanged).
  UPDATE public.exos_distribution_listings
     SET sold_qty = greatest(0, sold_qty - v_n), updated_at = now()
   WHERE id = o.distribution_listing_id AND channel = 's4k';
  PERFORM public.exos_sync_channel_hold(o.distribution_listing_id, true) WHERE o.distribution_listing_id IS NOT NULL;$n$, 1);

-- ROLLBACK (manual): DROP TRIGGER exos_events_s4k_route_release ON exos_events;
-- re-create exos_channel_pool_plan, _exos_feed_lines and exos_feed_place_order
-- from 20261014090000 / 20261014100000; drop exos_set_s4k_split,
-- exos_s4k_pool_status, _exos_s4k_pool, exos_tg_s4k_route_release; set the
-- 's4k' allocation rows to 'delisted' (they then hold nothing).
