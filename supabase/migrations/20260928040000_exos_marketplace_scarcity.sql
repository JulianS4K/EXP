-- ============================================================================
-- Migration 20260928040000 — Exos (Bridge / D4): scarcity mode for
--                            marketplace pools, and the day-of cutoff
--
-- Lane:     d4 (exos / bridge ticketing infra)
-- Touches:  W: exos_distribution_listings (+last_sold_at, +idle_since)
--              FUNCTION exos_channel_pool_plan, exos_pool_state (new)
--              FUNCTION exos_channel_hold_target, exos_sync_channel_hold,
--                exos_refill_channel_pools (replaced)
--              FUNCTION exos_fulfil_marketplace_order,
--                exos_sync_marketplace_distribution (patched in place)
-- Pre-reqs: 20260928010000 (pools) .. 20260928030000
--
-- Pools (20260928010000) keep a seat in exactly one place. This decides WHO
-- holds the last seats (operator, 2026-09-28):
--
--   1. Cutoff: 3 hours before doors (doors_at, else starts_at) every
--      marketplace pool goes to 0. Day-of sales are Exos's: seats with
--      nothing live come back at once; live listings are planned down to 0
--      and their seats come back once the marketplace confirms (as for any
--      live shrink).
--   2. Selling pools are reloaded; stagnant ones aren't. A pool that sold in
--      the last 24 hours (2 hours once the cutoff is less than a day away) is
--      selling: it's topped back up to its full pool, first
--      (exos_refill_channel_pools orders by the last sale), with any free
--      seat above an Exos floor of one order's worth (max per order). A pool
--      that has held seats that long without a sale is stagnant: it drops to
--      one order's worth, and to 0 in scarcity. The clock starts when the
--      pool gets seats, when the event is published, and at every sale; it
--      stops while a pool holds nothing (unless it emptied by stagnating).
--      A stagnant pool only ever shrinks.
--   3. Scarcity: when Exos's own free seats for a ticket type drop below one
--      order's worth per marketplace pool (the scarcity line), pools that
--      aren't selling shrink to one order's worth. Pools that aren't selling
--      never grow past the line, so seats near sellout flow from quiet
--      marketplaces to Exos and to the ones that sell, and nothing grows on
--      one run only to shrink on the next. Near sellout, Exos never sells out while the
--      marketplaces still hold seats, and what's left sits in whole blocks on
--      the marketplaces that sell.
--
-- The one-seat-one-holder rule doesn't change: growth still takes free seats
-- only, under the checkout locks, and a live listing still keeps its seats
-- until the marketplace has the lower number. exos_pool_state(row) is the
-- pool's state for the event editor (PostgREST computed field `exos_pool_state`).
--
-- Re-run safe. D4 authors; applying to prod is operator-gated.
-- ============================================================================

ALTER TABLE public.exos_distribution_listings
  ADD COLUMN IF NOT EXISTS last_sold_at timestamptz,
  ADD COLUMN IF NOT EXISTS idle_since   timestamptz;
COMMENT ON COLUMN public.exos_distribution_listings.last_sold_at IS
  'Allocation rows: the marketplace''s last sale of this ticket type. Selling pools are reloaded first.';
COMMENT ON COLUMN public.exos_distribution_listings.idle_since IS
  'Allocation rows: since when the pool has held seats without a sale (reset when it gets seats, at publish, at each sale). Stagnant after 24 h (2 h on the last day).';

-- Pools that already hold seats start their clock now.
UPDATE public.exos_distribution_listings
   SET idle_since = now()
 WHERE tier_id IS NOT NULL AND idle_since IS NULL AND coalesce(requested_qty, 0) > 0;

-- ---------------------------------------------------------------------------
-- 1. What a pool should hold, and why.
--    target      seats it should hold
--    state       fixed | closed | stagnant | scarce | selling | normal
--    exos_floor  free seats kept back for Exos when it grows
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.exos_channel_pool_plan(p_alloc uuid)
RETURNS TABLE (target int, state text, exos_floor int)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  d         public.exos_distribution_listings%ROWTYPE;
  e         public.exos_events%ROWTYPE;
  v_mpo     int;
  v_base    int;
  v_cutoff  timestamptz;
  v_window  interval;
  v_selling boolean;
  v_idle    boolean;
  v_free    int;
  v_pools   int;
  v_scarce  boolean;
BEGIN
  SELECT * INTO d FROM public.exos_distribution_listings WHERE id = p_alloc;
  IF d.id IS NULL THEN RETURN; END IF;
  IF d.tier_id IS NULL OR d.status NOT IN ('pending','planned','listing','listed') OR d.sell_cap IS NULL THEN
    RETURN QUERY SELECT coalesce(d.requested_qty, 0), 'fixed'::text, 0;
    RETURN;
  END IF;
  SELECT * INTO e FROM public.exos_events WHERE id = d.event_id;
  v_mpo := CASE WHEN (e.purchase_limits ->> 'maxPerOrder') ~ '^[0-9]{1,4}$'
                 AND (e.purchase_limits ->> 'maxPerOrder')::int > 0
                THEN (e.purchase_limits ->> 'maxPerOrder')::int ELSE 4 END;
  v_base := greatest(0, least(coalesce(d.pool_size, 2 * v_mpo), d.sell_cap - d.sold_qty));

  -- 1. The day-of cutoff: 3 hours before doors, Exos sells the rest.
  v_cutoff := coalesce(e.doors_at, e.starts_at) - interval '3 hours';
  IF v_cutoff IS NOT NULL AND now() >= v_cutoff THEN
    RETURN QUERY SELECT 0, 'closed'::text, 0;
    RETURN;
  END IF;

  -- 2. Selling or stagnant.
  v_window := CASE WHEN v_cutoff IS NOT NULL AND v_cutoff - now() <= interval '24 hours'
                   THEN interval '2 hours' ELSE interval '24 hours' END;
  v_selling := d.last_sold_at IS NOT NULL AND d.last_sold_at > now() - v_window;
  v_idle := NOT v_selling AND e.status = 'published'
            AND d.idle_since IS NOT NULL AND d.idle_since <= now() - v_window;

  -- 3. Scarcity: Exos's free seats (holds excluded) below one order's worth per pool.
  v_free := public.exos_effective_available(d.tier_id);
  SELECT count(*) INTO v_pools FROM public.exos_distribution_listings x
   WHERE x.tier_id = d.tier_id AND x.sell_cap IS NOT NULL AND x.sell_cap > x.sold_qty
     AND x.status IN ('pending','planned','listing','listed');
  v_scarce := v_free IS NOT NULL AND v_free < v_mpo * greatest(v_pools, 1);

  -- Selling pools are reloaded to their full size, leaving Exos one order's
  -- worth. The rest never grow past the scarcity line, shrink to one
  -- order's worth once it's crossed, and stagnant ones give back more.
  IF v_selling THEN
    RETURN QUERY SELECT v_base, 'selling'::text, v_mpo;
  ELSIF v_idle THEN
    -- Never reloaded: it only shrinks.
    RETURN QUERY SELECT CASE WHEN v_scarce THEN 0 ELSE least(coalesce(d.requested_qty, 0), v_base, v_mpo) END,
                        'stagnant'::text, v_mpo * greatest(v_pools, 1);
  ELSIF v_scarce THEN
    RETURN QUERY SELECT least(v_base, v_mpo), 'scarce'::text, v_mpo * greatest(v_pools, 1);
  ELSE
    RETURN QUERY SELECT v_base, 'normal'::text, v_mpo * greatest(v_pools, 1);
  END IF;
END $$;
REVOKE ALL ON FUNCTION public.exos_channel_pool_plan(uuid) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.exos_channel_pool_plan(uuid) TO service_role;

CREATE OR REPLACE FUNCTION public.exos_channel_hold_target(p_alloc uuid)
RETURNS int
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$ SELECT target FROM public.exos_channel_pool_plan(p_alloc) $$;
REVOKE ALL ON FUNCTION public.exos_channel_hold_target(uuid) FROM PUBLIC, anon, authenticated;

-- The pool's state for the event editor: select=…,exos_pool_state. The row
-- a caller passes could be made up, so the org is re-read and checked (the
-- same roles as the table's SELECT policy); anyone else gets NULL.
CREATE OR REPLACE FUNCTION public.exos_pool_state(r public.exos_distribution_listings)
RETURNS text
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE v_org uuid;
BEGIN
  SELECT org_id INTO v_org FROM public.exos_distribution_listings WHERE id = r.id;
  IF v_org IS NULL THEN RETURN NULL; END IF;
  IF auth.uid() IS NOT NULL AND NOT (exos_is_admin() OR exos_has_org_role(v_org, ARRAY['owner','manager','finance'])) THEN
    RETURN NULL;
  END IF;
  RETURN (SELECT state FROM public.exos_channel_pool_plan(r.id));
END $$;
REVOKE ALL ON FUNCTION public.exos_pool_state(public.exos_distribution_listings) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.exos_pool_state(public.exos_distribution_listings) TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 2. Moving a pool toward its target (replaces 20260928010000's): growth
--    leaves the Exos floor free; the stagnant clock starts when it gets seats.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.exos_sync_channel_hold(p_alloc uuid, p_confirmed boolean DEFAULT false)
RETURNS int
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  d       public.exos_distribution_listings%ROWTYPE;
  p       record;
  v_t     int;
  v_cur   int;
  v_new   int;
  v_free  int;
  v_live  boolean;
  q       record;
BEGIN
  SELECT * INTO d FROM public.exos_distribution_listings WHERE id = p_alloc AND tier_id IS NOT NULL FOR UPDATE;
  IF d.id IS NULL THEN RETURN NULL; END IF;
  IF d.status NOT IN ('pending','planned','listing','listed') OR d.sell_cap IS NULL THEN
    RETURN coalesce(d.requested_qty, 0);
  END IF;
  SELECT * INTO p FROM public.exos_channel_pool_plan(p_alloc);
  v_t   := p.target;
  v_cur := greatest(coalesce(d.requested_qty, 0), 0);
  v_live := d.external_listing_id IS NOT NULL OR d.listed_snapshot IS NOT NULL OR d.status IN ('listing','listed');
  v_new := v_cur;

  IF v_t > v_cur THEN
    -- Grow with free seats only, under the checkout locks (quotas, then the
    -- tier row, written so a waiting mint re-checks; see 20260926193000),
    -- leaving the Exos floor free.
    FOR q IN SELECT quota_id FROM public.exos_quota_tiers WHERE tier_id = d.tier_id ORDER BY quota_id LOOP
      PERFORM 1 FROM public.exos_quotas WHERE id = q.quota_id FOR UPDATE;
    END LOOP;
    UPDATE public.exos_ticket_tiers SET sort_order = sort_order WHERE id = d.tier_id;
    v_free := public.exos_effective_available(d.tier_id);   -- already excludes this hold
    v_new := v_cur + greatest(0, least(v_t - v_cur, coalesce(v_free - p.exos_floor, v_t - v_cur)));
  ELSIF v_t < v_cur AND (NOT v_live OR p_confirmed) THEN
    v_new := v_t;
  END IF;

  UPDATE public.exos_distribution_listings
     SET requested_qty  = v_new,
         internal_seats = CASE WHEN v_new <> v_cur
                               THEN public.exos_resize_internal_seats(internal_seats, tier_id, v_new)
                               ELSE internal_seats END,
         -- Live and waiting to shrink: list the lower number meanwhile.
         list_qty       = least(v_new, v_t),
         -- The stagnant clock runs while the pool holds seats (and keeps
         -- running for a stagnant pool that shrank to 0); it stops while the
         -- pool holds nothing for any other reason, and restarts with seats.
         idle_since     = CASE WHEN v_new = 0 AND p.state <> 'stagnant' THEN NULL
                               WHEN v_new > 0 AND idle_since IS NULL THEN now()
                               ELSE idle_since END,
         updated_at     = CASE WHEN v_new <> v_cur OR list_qty IS DISTINCT FROM least(v_new, v_t) THEN now() ELSE updated_at END
   WHERE id = d.id;
  RETURN v_new;
END $$;
REVOKE ALL ON FUNCTION public.exos_sync_channel_hold(uuid, boolean) FROM PUBLIC, anon, authenticated;

-- Every pool off its target (exos-distribute, each run): shrinking ones first
-- (their seats go back to Exos before anyone grows), then the ones selling
-- most recently, so freed seats reload the marketplaces that sell.
CREATE OR REPLACE FUNCTION public.exos_refill_channel_pools()
RETURNS int
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE r record; v_n int := 0;
BEGIN
  FOR r IN
    SELECT x.id FROM (
      SELECT d.id, d.last_sold_at, d.updated_at, coalesce(d.requested_qty, 0) AS held, d.list_qty,
             public.exos_channel_hold_target(d.id) AS target
        FROM public.exos_distribution_listings d
       WHERE d.tier_id IS NOT NULL AND d.sell_cap IS NOT NULL
         AND d.status IN ('pending','planned','listing','listed')
    ) x
     WHERE x.held <> x.target OR x.list_qty IS DISTINCT FROM least(x.held, x.target)
     ORDER BY (x.held > x.target) DESC, x.last_sold_at DESC NULLS LAST, x.updated_at
     LIMIT 500
  LOOP
    BEGIN
      PERFORM public.exos_sync_channel_hold(r.id);
      v_n := v_n + 1;
    EXCEPTION WHEN others THEN
      RAISE WARNING 'exos_refill_channel_pools(%): %', r.id, SQLERRM;
    END;
  END LOOP;
  RETURN v_n;
END $$;
REVOKE ALL ON FUNCTION public.exos_refill_channel_pools() FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.exos_refill_channel_pools() TO service_role;

-- ---------------------------------------------------------------------------
-- 3. In-place patches (assert one match; skipped once applied).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION pg_temp.exos_patch(p_sig text, p_marker text, p_old text, p_new text)
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
  IF v_hits <> 1 THEN
    RAISE EXCEPTION '%: expected one match for patch "%", found %', p_fn, p_marker, v_hits;
  END IF;
  EXECUTE replace(v_def, p_old, p_new);
END $$;

-- A marketplace sale marks the pool as selling (and restarts its clock)
-- before it's topped up in the same transaction.
SELECT pg_temp.exos_patch('public.exos_fulfil_marketplace_order(uuid, text)',
  'last_sold_at = now()',
  'SET sold_qty = sold_qty + o.quantity',
  'SET sold_qty = sold_qty + o.quantity, last_sold_at = now(), idle_since = now()');

-- Publishing starts every pool's stagnant clock (a pool filled before the
-- event went on sale hasn't had a chance to sell).
SELECT pg_temp.exos_patch('public.exos_sync_marketplace_distribution()',
  'SET idle_since = now()',
  '  FOREACH v_ch IN ARRAY ARRAY[',
  '  IF NEW.status = ''published'' AND (TG_OP = ''INSERT'' OR OLD.status IS DISTINCT FROM ''published'') THEN
    UPDATE public.exos_distribution_listings SET idle_since = now()
     WHERE event_id = NEW.id AND tier_id IS NOT NULL AND coalesce(requested_qty, 0) > 0;
  END IF;
  FOREACH v_ch IN ARRAY ARRAY[');
