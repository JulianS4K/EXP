-- ============================================================================
-- Migration 20260928010000 — Exos (Bridge / D4): small marketplace pools,
--                            topped up automatically; a live listing is only
--                            shrunk once the marketplace has the lower number
--
-- Lane:     d4 (exos / bridge ticketing infra)
-- Touches:  W: exos_distribution_listings (+sell_cap, +sold_qty, +pool_size,
--              +list_qty)
--              FUNCTION exos_channel_hold_target, exos_sync_channel_hold,
--                exos_refill_channel_pools, exos_confirm_channel_listing (new)
--              FUNCTION exos_set_channel_allocation (replaced)
--              FUNCTION exos_fulfil_marketplace_order,
--                exos_pull_channel_allocations (patched in place)
-- Pre-reqs: 20260927030000 .. 20260927050000
--
-- The event is live on every ticked marketplace at once, and a seat is
-- still never in two places. Instead of setting the whole number aside for a
-- marketplace up front, each marketplace HOLDS a small pool and is topped up
-- from Exos's free seats as it sells:
--
--   sell_cap    what the organizer put in the grid: the most this marketplace
--               sells of this ticket type in total.
--   sold_qty    what it has sold so far.
--   pool_size   how many it holds at once. NULL = 2 x the event's max per
--               order (8 without one), never more than what's left to sell.
--   requested_qty  the seats it holds now (unchanged meaning: out of Exos's
--               availability, one internal seat number each).
--
-- exos_sync_channel_hold(allocation) moves the hold toward
-- least(pool_size, sell_cap - sold_qty):
--   * up: only with seats that are free right now, under the same locks as a
--     checkout (quotas, then the tier row), so it can't race an Exos sale. If
--     Exos has sold the rest, the marketplace simply holds less (sell_cap is
--     a ceiling, not a promise).
--   * down: at once when nothing is on the marketplace. When the listing is
--     LIVE, the seats stay held until the marketplace has the lower number
--     (exos_confirm_channel_listing, called after the update went through):
--     releasing them first would let Exos and the marketplace both sell them.
--     list_qty is the number the listings should show meanwhile (the lowest
--     list_qty internal seats; the highest are the ones to be released).
-- It runs when the grid changes, after every marketplace sale (same
-- transaction), and on every exos-distribute run for all allocations
-- (exos_refill_channel_pools), which picks up seats freed later (refunds,
-- released holds).
--
-- Re-run safe. D4 authors; applying to prod is operator-gated.
-- ============================================================================

ALTER TABLE public.exos_distribution_listings
  ADD COLUMN IF NOT EXISTS sell_cap  integer CHECK (sell_cap IS NULL OR sell_cap >= 0),
  ADD COLUMN IF NOT EXISTS sold_qty  integer NOT NULL DEFAULT 0 CHECK (sold_qty >= 0),
  ADD COLUMN IF NOT EXISTS pool_size integer CHECK (pool_size IS NULL OR pool_size > 0),
  ADD COLUMN IF NOT EXISTS list_qty  integer CHECK (list_qty IS NULL OR list_qty >= 0);
COMMENT ON COLUMN public.exos_distribution_listings.sell_cap IS
  'Allocation rows: the most this marketplace sells of this ticket type (the grid). NULL on rows from before pools: requested_qty is fixed.';
COMMENT ON COLUMN public.exos_distribution_listings.sold_qty IS
  'Allocation rows: tickets this marketplace has sold (minted by exos_fulfil_marketplace_order).';
COMMENT ON COLUMN public.exos_distribution_listings.pool_size IS
  'Allocation rows: seats held at once; NULL = 2 x the event max per order (8 without one).';
COMMENT ON COLUMN public.exos_distribution_listings.list_qty IS
  'Allocation rows: what the listings should show. Below requested_qty while a live listing waits to be shrunk.';

-- Rows from before pools: their whole allocation is their cap.
UPDATE public.exos_distribution_listings
   SET sell_cap = coalesce(requested_qty, 0) + sold_qty
 WHERE tier_id IS NOT NULL AND sell_cap IS NULL
   AND status IN ('pending','planned','listing','listed','delisting');

-- ---------------------------------------------------------------------------
-- 1. What a marketplace should hold, and moving toward it.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.exos_channel_hold_target(p_alloc uuid)
RETURNS int
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT CASE
           WHEN d.status NOT IN ('pending','planned','listing','listed') THEN coalesce(d.requested_qty, 0)
           WHEN d.sell_cap IS NULL THEN coalesce(d.requested_qty, 0)
           ELSE greatest(0, least(
             coalesce(d.pool_size,
                      2 * CASE WHEN (e.purchase_limits ->> 'maxPerOrder') ~ '^[0-9]{1,4}$'
                                 AND (e.purchase_limits ->> 'maxPerOrder')::int > 0
                               THEN (e.purchase_limits ->> 'maxPerOrder')::int ELSE 4 END),
             d.sell_cap - d.sold_qty))
         END
    FROM public.exos_distribution_listings d
    JOIN public.exos_events e ON e.id = d.event_id
   WHERE d.id = p_alloc
$$;
REVOKE ALL ON FUNCTION public.exos_channel_hold_target(uuid) FROM PUBLIC, anon, authenticated;

-- Move one allocation's hold toward its target. p_confirmed: the marketplace
-- has the listing's current (lower) number, so held seats above it can go.
-- Returns the seats held afterwards.
CREATE OR REPLACE FUNCTION public.exos_sync_channel_hold(p_alloc uuid, p_confirmed boolean DEFAULT false)
RETURNS int
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  d       public.exos_distribution_listings%ROWTYPE;
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
  v_t   := public.exos_channel_hold_target(p_alloc);
  v_cur := greatest(coalesce(d.requested_qty, 0), 0);
  v_live := d.external_listing_id IS NOT NULL OR d.listed_snapshot IS NOT NULL OR d.status IN ('listing','listed');
  v_new := v_cur;

  IF v_t > v_cur THEN
    -- Grow with free seats only, under the checkout locks (quotas, then the
    -- tier row, written so a waiting mint re-checks; see 20260926193000).
    FOR q IN SELECT quota_id FROM public.exos_quota_tiers WHERE tier_id = d.tier_id ORDER BY quota_id LOOP
      PERFORM 1 FROM public.exos_quotas WHERE id = q.quota_id FOR UPDATE;
    END LOOP;
    UPDATE public.exos_ticket_tiers SET sort_order = sort_order WHERE id = d.tier_id;
    v_free := public.exos_effective_available(d.tier_id);   -- already excludes this hold
    v_new := v_cur + greatest(0, least(v_t - v_cur, coalesce(v_free, v_t - v_cur)));
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
         updated_at     = CASE WHEN v_new <> v_cur OR list_qty IS DISTINCT FROM least(v_new, v_t) THEN now() ELSE updated_at END
   WHERE id = d.id;
  RETURN v_new;
END $$;
REVOKE ALL ON FUNCTION public.exos_sync_channel_hold(uuid, boolean) FROM PUBLIC, anon, authenticated;

-- Every active pool below or above its target (exos-distribute, each run).
CREATE OR REPLACE FUNCTION public.exos_refill_channel_pools()
RETURNS int
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE r record; v_n int := 0;
BEGIN
  FOR r IN
    SELECT d.id FROM public.exos_distribution_listings d
     WHERE d.tier_id IS NOT NULL AND d.sell_cap IS NOT NULL
       AND d.status IN ('pending','planned','listing','listed')
       AND (coalesce(d.requested_qty, 0) <> public.exos_channel_hold_target(d.id)
            OR d.list_qty IS DISTINCT FROM least(coalesce(d.requested_qty, 0), public.exos_channel_hold_target(d.id)))
     ORDER BY d.updated_at
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

-- The marketplace has the listing's current number (the live writer calls
-- this after an update went through): held seats above it go back to Exos.
CREATE OR REPLACE FUNCTION public.exos_confirm_channel_listing(p_alloc uuid)
RETURNS int
LANGUAGE sql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$ SELECT public.exos_sync_channel_hold(p_alloc, true) $$;
REVOKE ALL ON FUNCTION public.exos_confirm_channel_listing(uuid) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.exos_confirm_channel_listing(uuid) TO service_role;

-- ---------------------------------------------------------------------------
-- 2. The grid sets the cap (replaces 20260927030000's, Gametime included).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.exos_set_channel_allocation(
  p_event_id uuid,
  p_channel  text,
  p_tier_id  uuid,
  p_qty      int
) RETURNS int
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_ev     public.exos_events%ROWTYPE;
  d        public.exos_distribution_listings%ROWTYPE;
  v_tev    uuid;
  v_avail  int;
  v_sum    bigint;
  v_uncap  boolean;
  v_live   boolean;
  v_label  text;
  v_sold   int := 0;
  v_held   int := 0;
  q        record;
BEGIN
  SELECT * INTO v_ev FROM public.exos_events WHERE id = p_event_id;
  IF v_ev.id IS NULL THEN
    RAISE EXCEPTION 'exos_set_channel_allocation: event not found';
  END IF;
  -- Only authenticated (always has a uid) and service_role can execute this:
  -- a user must be org owner/manager, no uid = service.
  IF auth.uid() IS NOT NULL
     AND NOT (exos_is_admin() OR exos_has_org_role(v_ev.org_id, ARRAY['owner','manager'])) THEN
    RAISE EXCEPTION 'exos_set_channel_allocation: not authorized' USING ERRCODE = '42501';
  END IF;
  IF p_channel NOT IN ('stubhub','seatgeek','gametime','vivid','tickpick','evo','automatiq') THEN
    RAISE EXCEPTION 'exos_set_channel_allocation: unknown channel %', p_channel;
  END IF;
  v_label := CASE p_channel WHEN 'stubhub' THEN 'StubHub' WHEN 'seatgeek' THEN 'SeatGeek' ELSE initcap(p_channel) END;
  IF p_qty IS NULL OR p_qty < 0 OR p_qty > 10000 THEN
    RAISE EXCEPTION 'exos_set_channel_allocation: quantity must be 0-10000';
  END IF;
  IF v_ev.status = 'cancelled' AND p_qty > 0 THEN
    RAISE EXCEPTION 'exos_set_channel_allocation: event is cancelled';
  END IF;
  IF p_qty > 0 AND (NOT (p_channel = ANY (coalesce(v_ev.distribution_networks, '{}'::text[])))
                    OR coalesce(v_ev.exclusivity ->> 'primaryMarketOnly', 'false') = 'true') THEN
    RAISE EXCEPTION 'exos_set_channel_allocation: tick % under Distribution (with primary market only off) and save the event first', v_label;
  END IF;
  SELECT event_id INTO v_tev FROM public.exos_ticket_tiers WHERE id = p_tier_id;
  IF v_tev IS DISTINCT FROM p_event_id THEN
    RAISE EXCEPTION 'exos_set_channel_allocation: ticket type not found for this event';
  END IF;
  IF public.exos_tier_is_table(p_tier_id) THEN
    RAISE EXCEPTION 'exos_set_channel_allocation: table ticket types can''t be sold on a marketplace';
  END IF;
  SELECT COALESCE(SUM(capacity), 0), bool_or(capacity = 0) INTO v_sum, v_uncap
    FROM public.exos_ticket_tiers WHERE event_id = p_event_id;
  IF p_qty > 0 AND v_ev.total_tickets > 0 AND (v_uncap OR v_ev.total_tickets < v_sum) THEN
    RAISE EXCEPTION 'exos_set_channel_allocation: the event''s overall capacity (%) is lower than its ticket types add up to; give every ticket type a capacity and make the overall cap at least their sum (% ) before selling on a marketplace',
      v_ev.total_tickets, v_sum USING ERRCODE = '23514';
  END IF;

  SELECT * INTO d FROM public.exos_distribution_listings
   WHERE event_id = p_event_id AND channel = p_channel AND tier_id = p_tier_id FOR UPDATE;
  IF d.status = 'delisting' THEN
    RAISE EXCEPTION 'exos_set_channel_allocation: this ticket type is being taken off %; change it once that is done', v_label;
  END IF;
  IF d.id IS NOT NULL THEN
    v_sold := d.sold_qty;
    IF d.status IN ('pending','planned','listing','listed') THEN v_held := greatest(coalesce(d.requested_qty, 0), 0); END IF;
  END IF;
  -- Locks: the allocation row (above), then quotas, then the tier (as a
  -- checkout), before reading what's free, so the check can't race a mint.
  FOR q IN SELECT quota_id FROM public.exos_quota_tiers WHERE tier_id = p_tier_id ORDER BY quota_id LOOP
    PERFORM 1 FROM public.exos_quotas WHERE id = q.quota_id FOR UPDATE;
  END LOOP;
  UPDATE public.exos_ticket_tiers SET sort_order = sort_order WHERE id = p_tier_id;
  -- The cap can't promise seats that are gone: what's left to sell must fit
  -- in what this marketplace holds plus what's free now.
  IF p_qty > v_sold + v_held THEN
    v_avail := public.exos_effective_available(p_tier_id);   -- excludes this hold
    IF v_avail IS NOT NULL AND v_avail < p_qty - v_sold - v_held THEN
      RAISE EXCEPTION 'exos_set_channel_allocation: only % more seat(s) free on this ticket type', v_avail
        USING ERRCODE = '23514';
    END IF;
  END IF;
  v_live := d.id IS NOT NULL
        AND (d.external_listing_id IS NOT NULL OR d.listed_snapshot IS NOT NULL OR d.status IN ('listing','listed'));

  IF d.id IS NULL THEN
    IF p_qty = 0 THEN RETURN 0; END IF;
    INSERT INTO public.exos_distribution_listings
      (event_id, org_id, channel, status, tier_id, requested_qty, sell_cap, internal_seats)
    VALUES (p_event_id, v_ev.org_id, p_channel, 'pending', p_tier_id, 0, p_qty, '{}')
    RETURNING * INTO d;
  ELSIF p_qty = 0 AND v_live THEN
    -- Delist, then release: the seats stay held until it's off the marketplace.
    UPDATE public.exos_distribution_listings SET sell_cap = 0, status = 'delisting', updated_at = now() WHERE id = d.id;
    RETURN 0;
  ELSIF p_qty = 0 THEN
    UPDATE public.exos_distribution_listings
       SET sell_cap = 0, requested_qty = 0, list_qty = 0, internal_seats = '{}', status = 'delisted',
           planned_listing = NULL, error = NULL, updated_at = now()
     WHERE id = d.id;
    RETURN 0;
  ELSE
    UPDATE public.exos_distribution_listings
       SET sell_cap = p_qty,
           requested_qty = CASE WHEN status IN ('failed','delisted') THEN 0 ELSE requested_qty END,
           internal_seats = CASE WHEN status IN ('failed','delisted') THEN '{}'::int4multirange ELSE internal_seats END,
           -- A failed / delisted row holds nothing; allocating again revives it.
           status = CASE WHEN status IN ('failed','delisted') THEN 'pending' ELSE status END,
           error = CASE WHEN status IN ('failed','delisted') THEN NULL ELSE error END,
           updated_at = now()
     WHERE id = d.id;
  END IF;
  -- Hold the pool now (free seats only, under the checkout locks).
  PERFORM public.exos_sync_channel_hold(d.id);
  RETURN p_qty;
END $$;
REVOKE ALL ON FUNCTION public.exos_set_channel_allocation(uuid, text, uuid, int) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.exos_set_channel_allocation(uuid, text, uuid, int) TO authenticated, service_role;

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

-- After a marketplace sale: count it and top the pool back up, in the same
-- transaction (locks: the allocation row and the tier are already held).
SELECT pg_temp.exos_patch('public.exos_fulfil_marketplace_order(uuid, text)',
  'exos_sync_channel_hold(o.distribution_listing_id)',
  '  UPDATE public.exos_marketplace_orders
     SET status = ''fulfilled'', ticket_ids = v_ids',
  '  UPDATE public.exos_distribution_listings
     SET sold_qty = sold_qty + o.quantity
   WHERE id = o.distribution_listing_id AND tier_id = o.tier_id;
  PERFORM public.exos_sync_channel_hold(o.distribution_listing_id);

  UPDATE public.exos_marketplace_orders
     SET status = ''fulfilled'', ticket_ids = v_ids');

-- Pulled back with nothing live: the grid cell goes to 0 too.
SELECT pg_temp.exos_patch('public.exos_pull_channel_allocations(uuid, text)',
  'SET sell_cap = 0, requested_qty = 0',
  'SET requested_qty = 0, internal_seats = ''{}'', status = ''delisted'',',
  'SET sell_cap = 0, requested_qty = 0, list_qty = 0, internal_seats = ''{}'', status = ''delisted'',');
