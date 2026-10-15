-- ============================================================================
-- S4K listings for Albert: three listings per ticket type, refilled as they
-- sell, rebalanced from Exos + Eventbrite down to one listing set, the last
-- set kept for the organizer's primary QR source (operator design 2026-10-14)
-- ============================================================================
-- Touches:  W: exos_events (+ resale_listing_qty, primary_source, s4k_rebalance)
--           W: exos_feed_consumers (+ auth_user_id)
--           C: TABLE exos_s4k_listings (Realtime; read by a linked consumer)
--           C: FUNCTION _exos_primary_hold, _exos_tier_free_raw,
--              exos_s4k_listings_sync, exos_s4k_rebalance, exos_feed_link_user
--              (service role); exos_set_resale_options (owner / manager)
--           W: FUNCTION exos_tier_available (patched: the primary hold),
--              exos_eventbrite_inventory_apply (patched: Eventbrite may sell
--              the primary hold; Exos primary keeps one set off Eventbrite),
--              exos_feed_refresh (patched: rebalance on the cron pass, then
--              sync the listings), exos_s4k_pool_status (replaced: + options
--              and listings)
-- Pre-reqs: 20261014140000 (resale rule) and the S4K / Eventbrite chain
--
-- The chain: Exos -> Albert -> S4K -> Automatiq (S4K's account). Exos only
-- publishes; Albert reads exos_s4k_listings (signed in as a consumer's linked
-- integration user, like Terminal-2's N2S feed) and pushes on. Exos never
-- writes to S4K or Automatiq (CLAUDE.md: upstream APIs are read-only).
--
-- Per ticket type in S4K's pool (20261014130000):
--   * THREE listings, each up to the event's listing quantity L
--     (resale_listing_qty, default 8, organizer-set). Listing i shows
--     min(L, held - (i-1) x L): S4K's pool fills them in order, so a sale on
--     one refills it from the pool on the next sync.
--   * When the pool can't fill all three (held < 3L) and rebalancing is on,
--     S4K's split grows with seats free in Exos + Eventbrite's pool, down to
--     one listing set (L seats) left there. Every minute, on the feed cron
--     (never inside an order, so its locks stay pool -> quotas -> tier).
--   * The last set belongs to the PRIMARY QR source (primary_source):
--       'exos'       on an S4K-route event, Eventbrite's capacity sync holds
--                    back at least L (its buffer is max(one pack, L)): Exos
--                    sells the last set. Off the S4K route nothing changes.
--       'eventbrite' on a ticket type mapped to Eventbrite, the last L free
--                    seats are held off Exos checkout (exos_tier_available)
--                    and Eventbrite sells them.
--
-- The listing table syncs by diff, REPLICA IDENTITY FULL, in the
-- supabase_realtime publication when there is one: a quiet minute emits
-- nothing; a DELETE means "take this listing down".
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
-- 1. Options.
-- ---------------------------------------------------------------------------
ALTER TABLE public.exos_events
  ADD COLUMN IF NOT EXISTS resale_listing_qty integer NOT NULL DEFAULT 8,
  ADD COLUMN IF NOT EXISTS primary_source text NOT NULL DEFAULT 'exos',
  ADD COLUMN IF NOT EXISTS s4k_rebalance boolean NOT NULL DEFAULT true;
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'exos_events_resale_listing_qty_check') THEN
    ALTER TABLE public.exos_events ADD CONSTRAINT exos_events_resale_listing_qty_check CHECK (resale_listing_qty BETWEEN 1 AND 50);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'exos_events_primary_source_check') THEN
    ALTER TABLE public.exos_events ADD CONSTRAINT exos_events_primary_source_check CHECK (primary_source IN ('exos', 'eventbrite'));
  END IF;
END $$;

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
  IF p_primary_source IS NOT NULL AND p_primary_source NOT IN ('exos', 'eventbrite') THEN
    RAISE EXCEPTION 'exos_set_resale_options: the primary source is exos or eventbrite' USING ERRCODE = '22023';
  END IF;
  IF p_primary_source = 'eventbrite'
     AND NOT EXISTS (SELECT 1 FROM public.exos_eventbrite_links l WHERE l.event_id = p_event_id) THEN
    RAISE EXCEPTION 'exos_set_resale_options: link this event to Eventbrite first' USING ERRCODE = '22023';
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

-- ---------------------------------------------------------------------------
-- 2. The primary hold: on an Eventbrite-primary event, the last L free seats
--    of a ticket type mapped to Eventbrite are off Exos checkout.
--    _exos_tier_free_raw reads the ticket type's free seats with the hold
--    switched off (what Exos + Eventbrite share before the hold).
-- ---------------------------------------------------------------------------
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
       WHERE t.id = p_tier_id AND e.primary_source = 'eventbrite' AND e.status <> 'cancelled'
         AND EXISTS (SELECT 1 FROM public.exos_eventbrite_ticket_links k WHERE k.tier_id = t.id AND k.active)), 0)
  END
$$;
REVOKE ALL ON FUNCTION public._exos_primary_hold(uuid, bigint) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_primary_hold(uuid, bigint) TO service_role;

SELECT pg_temp.exos_patch_n('public.exos_tier_available(uuid)',
  '_exos_primary_hold',
  $o$           ELSE GREATEST(0, t.capacity - t.sold - COALESCE(h.held, 0) - COALESCE(v.blocked, 0) - public.exos_channel_allocated(t.id))$o$,
  $n$           -- The primary hold (mig 20261014150000): the last set is Eventbrite's.
           ELSE GREATEST(0, t.capacity - t.sold - COALESCE(h.held, 0) - COALESCE(v.blocked, 0) - public.exos_channel_allocated(t.id))
                - public._exos_primary_hold(t.id, GREATEST(0, t.capacity - t.sold - COALESCE(h.held, 0) - COALESCE(v.blocked, 0) - public.exos_channel_allocated(t.id)))$n$, 1);

CREATE OR REPLACE FUNCTION public._exos_tier_free_raw(p_tier_id uuid)
RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE v int;
BEGIN
  PERFORM set_config('exos.primary_hold_off', '1', true);
  v := public.exos_effective_available(p_tier_id);
  PERFORM set_config('exos.primary_hold_off', '', true);
  RETURN v;
END $$;
REVOKE ALL ON FUNCTION public._exos_tier_free_raw(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_tier_free_raw(uuid) TO service_role;

-- Eventbrite: its sales may take the hold; its capacity adds the hold when
-- it is primary, and holds back at least one set when Exos is.
SELECT pg_temp.exos_patch_n('public.exos_eventbrite_inventory_apply(uuid, jsonb, timestamp with time zone)',
  'v_hold   int;',
  $o$  v_target int;
BEGIN$o$,
  $n$  v_target int;
  v_hold   int;
BEGIN$n$, 1);

SELECT pg_temp.exos_patch_n('public.exos_eventbrite_inventory_apply(uuid, jsonb, timestamp with time zone)',
  'v_avail := public._exos_tier_free_raw(t.tier_id);',
  $o$      v_avail := public.exos_effective_available(t.tier_id);$o$,
  $n$      v_avail := public._exos_tier_free_raw(t.tier_id);   -- the primary hold is Eventbrite's to sell$n$, 1);

SELECT pg_temp.exos_patch_n('public.exos_eventbrite_inventory_apply(uuid, jsonb, timestamp with time zone)',
  'primary source (mig 20261014150000)',
  $o$    v_avail := greatest(coalesce(public.exos_effective_available(t.tier_id), 0), 0);$o$,
  $n$    v_avail := greatest(coalesce(public.exos_effective_available(t.tier_id), 0), 0);
    -- The primary source (mig 20261014150000): Eventbrite primary adds the
    -- seats held off Exos; Exos primary keeps at least one listing set.
    v_hold := greatest(coalesce(public._exos_tier_free_raw(t.tier_id), 0), 0) - v_avail;
    IF e.primary_source = 'exos' AND e.distribution_route = 's4k' THEN
      v_pack := greatest(v_pack, e.resale_listing_qty);
    END IF;$n$, 1);

SELECT pg_temp.exos_patch_n('public.exos_eventbrite_inventory_apply(uuid, jsonb, timestamp with time zone)',
  'greatest(v_avail - v_pack, 0) + v_hold',
  $o$    v_share := CASE WHEN v_live THEN greatest(v_avail - v_pack, 0) ELSE 0 END;$o$,
  $n$    v_share := CASE WHEN v_live THEN greatest(v_avail - v_pack, 0) + v_hold ELSE 0 END;
    IF coalesce(e.total_tickets, 0) > 0 THEN
      v_share := least(v_share, greatest(e.total_tickets - e.tickets_sold - v_promised, 0));
    END IF;$n$, 1);

-- ---------------------------------------------------------------------------
-- 3. Albert's access: a consumer's linked integration user reads the
--    listings (the token stays for the pull API and orders).
-- ---------------------------------------------------------------------------
ALTER TABLE public.exos_feed_consumers ADD COLUMN IF NOT EXISTS auth_user_id uuid;
CREATE UNIQUE INDEX IF NOT EXISTS exos_feed_consumers_auth_user_uq
  ON public.exos_feed_consumers (auth_user_id) WHERE auth_user_id IS NOT NULL;

CREATE OR REPLACE FUNCTION public.exos_feed_link_user(p_consumer_name text, p_email text)
RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE v_user uuid; v_cons uuid;
BEGIN
  SELECT id INTO v_user FROM auth.users WHERE lower(email) = lower(btrim(p_email));
  IF v_user IS NULL THEN
    RAISE EXCEPTION 'exos_feed_link_user: no user with that email (create the integration user first)' USING ERRCODE = '22023';
  END IF;
  UPDATE public.exos_feed_consumers SET auth_user_id = v_user
   WHERE name = btrim(p_consumer_name) AND revoked_at IS NULL
  RETURNING id INTO v_cons;
  IF v_cons IS NULL THEN
    RAISE EXCEPTION 'exos_feed_link_user: no live consumer named %', p_consumer_name USING ERRCODE = '22023';
  END IF;
  RETURN v_cons;
END $$;
REVOKE ALL ON FUNCTION public.exos_feed_link_user(text, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_feed_link_user(text, text) TO service_role;

-- ---------------------------------------------------------------------------
-- 4. The listings.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.exos_s4k_listings (
  listing_id     text PRIMARY KEY,          -- 'exos-<tier id>-<slot>': stable across refills
  event_id       uuid NOT NULL REFERENCES public.exos_events (id) ON DELETE CASCADE,
  tier_id        uuid NOT NULL REFERENCES public.exos_ticket_tiers (id) ON DELETE CASCADE,
  slot           smallint NOT NULL CHECK (slot BETWEEN 1 AND 3),
  quantity       integer NOT NULL CHECK (quantity > 0),
  max_quantity   integer NOT NULL,
  max_per_order  integer,
  split          text,
  price          numeric(12, 2) NOT NULL,
  net            numeric(12, 2) NOT NULL,
  currency       text NOT NULL,
  ticket_name    text NOT NULL,
  event_name     text NOT NULL,
  starts_at      timestamptz,
  doors_at       timestamptz,
  timezone       text,
  venue_name     text,
  primary_source text NOT NULL,
  updated_at     timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS exos_s4k_listings_event_idx ON public.exos_s4k_listings (event_id);
ALTER TABLE public.exos_s4k_listings REPLICA IDENTITY FULL;
ALTER TABLE public.exos_s4k_listings ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.exos_s4k_listings FROM PUBLIC, anon, authenticated;
GRANT SELECT ON TABLE public.exos_s4k_listings TO authenticated;
GRANT ALL ON TABLE public.exos_s4k_listings TO service_role;
-- Is the signed-in user a live consumer's linked user? (The consumers
-- table stays closed to clients.)
CREATE OR REPLACE FUNCTION public._exos_is_feed_reader()
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT auth.uid() IS NOT NULL AND EXISTS (SELECT 1 FROM public.exos_feed_consumers c
                                             WHERE c.auth_user_id = auth.uid() AND c.revoked_at IS NULL)
$$;
REVOKE ALL ON FUNCTION public._exos_is_feed_reader() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public._exos_is_feed_reader() TO authenticated, service_role;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE tablename = 'exos_s4k_listings' AND policyname = 'exos_s4k_listings_consumer_sel') THEN
    CREATE POLICY exos_s4k_listings_consumer_sel ON public.exos_s4k_listings FOR SELECT TO authenticated
      USING (public._exos_is_feed_reader());
  END IF;
  IF EXISTS (SELECT 1 FROM pg_publication WHERE pubname = 'supabase_realtime')
     AND NOT EXISTS (SELECT 1 FROM pg_publication_tables
                      WHERE pubname = 'supabase_realtime' AND schemaname = 'public' AND tablename = 'exos_s4k_listings') THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.exos_s4k_listings;
  END IF;
END $$;
COMMENT ON TABLE public.exos_s4k_listings IS
  'S4K listings for Albert: three per ticket type in S4K''s pool, refilled as they sell. Diff-synced, Realtime. A linked consumer user reads it. mig 20261014150000.';

-- One event's listings, written by diff (an unchanged row emits nothing).
CREATE OR REPLACE FUNCTION public.exos_s4k_listings_sync(p_event_id uuid)
RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  e    public.exos_events%ROWTYPE;
  v_n  int := 0;
  v_k  int;
BEGIN
  SELECT * INTO e FROM public.exos_events WHERE id = p_event_id;
  CREATE TEMP TABLE IF NOT EXISTS pg_temp.exos_want_listings (LIKE public.exos_s4k_listings) ON COMMIT DROP;
  TRUNCATE pg_temp.exos_want_listings;
  IF e.id IS NOT NULL AND public._exos_feed_eligible(p_event_id) THEN
    INSERT INTO pg_temp.exos_want_listings
    SELECT 'exos-' || l.tier_id || '-' || s.slot, e.id, l.tier_id, s.slot,
           least(e.resale_listing_qty, l.quantity - (s.slot - 1) * e.resale_listing_qty),
           e.resale_listing_qty, l.max_per_order, l.split, l.price, l.net, l.currency, l.name,
           e.name, e.starts_at, e.doors_at, e.timezone, e.venue_name, e.primary_source, now()
      FROM public._exos_feed_lines(p_event_id) l
      CROSS JOIN generate_series(1, 3) AS s(slot)
     WHERE l.quantity - (s.slot - 1) * e.resale_listing_qty > 0;
  END IF;

  DELETE FROM public.exos_s4k_listings x
   WHERE x.event_id = p_event_id
     AND NOT EXISTS (SELECT 1 FROM pg_temp.exos_want_listings w WHERE w.listing_id = x.listing_id);
  GET DIAGNOSTICS v_k = ROW_COUNT;
  v_n := v_n + v_k;
  INSERT INTO public.exos_s4k_listings AS x
  SELECT * FROM pg_temp.exos_want_listings
  ON CONFLICT (listing_id) DO UPDATE
     SET quantity = EXCLUDED.quantity, max_quantity = EXCLUDED.max_quantity, max_per_order = EXCLUDED.max_per_order,
         split = EXCLUDED.split, price = EXCLUDED.price, net = EXCLUDED.net, currency = EXCLUDED.currency,
         ticket_name = EXCLUDED.ticket_name, event_name = EXCLUDED.event_name, starts_at = EXCLUDED.starts_at,
         doors_at = EXCLUDED.doors_at, timezone = EXCLUDED.timezone, venue_name = EXCLUDED.venue_name,
         primary_source = EXCLUDED.primary_source, updated_at = now()
   WHERE (x.quantity, x.max_quantity, x.max_per_order, x.split, x.price, x.net, x.currency, x.ticket_name,
          x.event_name, x.starts_at, x.doors_at, x.timezone, x.venue_name, x.primary_source)
         IS DISTINCT FROM
         (EXCLUDED.quantity, EXCLUDED.max_quantity, EXCLUDED.max_per_order, EXCLUDED.split, EXCLUDED.price, EXCLUDED.net,
          EXCLUDED.currency, EXCLUDED.ticket_name, EXCLUDED.event_name, EXCLUDED.starts_at, EXCLUDED.doors_at,
          EXCLUDED.timezone, EXCLUDED.venue_name, EXCLUDED.primary_source);
  GET DIAGNOSTICS v_k = ROW_COUNT;
  RETURN v_n + v_k;
END $$;
REVOKE ALL ON FUNCTION public.exos_s4k_listings_sync(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_s4k_listings_sync(uuid) TO service_role;

-- ---------------------------------------------------------------------------
-- 5. Rebalance: refill S4K's pool from Exos + Eventbrite's, down to one set.
--    Locks: the pool row, the ticket type's quotas, the ticket type (an S4K
--    order's and a checkout's order). Returns the seats moved.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.exos_s4k_rebalance(p_event_id uuid DEFAULT NULL)
RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  r       record;
  d       public.exos_distribution_listings%ROWTYPE;
  v_held  int;
  v_need  int;
  v_free  int;
  v_take  int;
  v_moved int := 0;
BEGIN
  FOR r IN
    SELECT p.id AS pool_id, p.tier_id, e.id AS event_id, e.resale_listing_qty AS l
      FROM public.exos_distribution_listings p
      JOIN public.exos_events e ON e.id = p.event_id
     WHERE p.channel = 's4k' AND p.tier_id IS NOT NULL AND p.status IN ('pending', 'planned', 'listing', 'listed')
       AND e.s4k_rebalance AND (p_event_id IS NULL OR e.id = p_event_id)
     ORDER BY p.event_id, p.tier_id
  LOOP
    CONTINUE WHEN NOT public._exos_feed_eligible(r.event_id);
    SELECT * INTO d FROM public.exos_distribution_listings WHERE id = r.pool_id FOR UPDATE;
    CONTINUE WHEN d.status NOT IN ('pending', 'planned', 'listing', 'listed');
    v_held := greatest(coalesce(d.requested_qty, 0), 0);
    v_need := 3 * r.l - v_held;
    CONTINUE WHEN v_need <= 0;
    PERFORM 1 FROM public.exos_quotas
     WHERE id IN (SELECT quota_id FROM public.exos_quota_tiers WHERE tier_id = r.tier_id)
     ORDER BY id FOR UPDATE;
    UPDATE public.exos_ticket_tiers SET sort_order = sort_order WHERE id = r.tier_id;
    -- What Exos + Eventbrite share (the primary hold included), less one set.
    v_free := greatest(coalesce(public._exos_tier_free_raw(r.tier_id), 0), 0);
    v_take := least(v_need, greatest(v_free - r.l, 0));
    CONTINUE WHEN v_take <= 0;
    UPDATE public.exos_distribution_listings
       SET sell_cap = coalesce(sell_cap, 0) + v_take, updated_at = now()
     WHERE id = d.id;
    PERFORM public.exos_sync_channel_hold(d.id, true);
    v_moved := v_moved + v_take;
  END LOOP;
  RETURN v_moved;
END $$;
REVOKE ALL ON FUNCTION public.exos_s4k_rebalance(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_s4k_rebalance(uuid) TO service_role;

-- The feed cron (exos_feed_refresh(NULL), every minute) rebalances first;
-- every refresh then syncs that event's listings (an order's refresh too,
-- so a sale shows within the order's own transaction).
SELECT pg_temp.exos_patch_n('public.exos_feed_refresh(uuid)',
  'exos_s4k_rebalance',
  $o$  IF p_event_id IS NULL AND NOT pg_try_advisory_xact_lock(hashtext('exos_feed_refresh')) THEN
    RETURN 0;
  END IF;$o$,
  $n$  IF p_event_id IS NULL AND NOT pg_try_advisory_xact_lock(hashtext('exos_feed_refresh')) THEN
    RETURN 0;
  END IF;
  -- S4K listings (mig 20261014150000): the cron pass refills S4K's pools
  -- first, and drops listings of events no longer on the route.
  IF p_event_id IS NULL THEN
    PERFORM public.exos_s4k_rebalance(NULL);
    PERFORM public.exos_s4k_listings_sync(x.event_id)
       FROM (SELECT DISTINCT l.event_id FROM public.exos_s4k_listings l) x;
  END IF;$n$, 1);

SELECT pg_temp.exos_patch_n('public.exos_feed_refresh(uuid)',
  'PERFORM public.exos_s4k_listings_sync(r.id);',
  $o$    v_n := v_n + v_rows;$o$,
  $n$    v_n := v_n + v_rows;
    PERFORM public.exos_s4k_listings_sync(r.id);$n$, 1);

-- ---------------------------------------------------------------------------
-- 6. The pools panel: + the options and the listings.
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
    'listing_qty', e.resale_listing_qty,
    'primary_source', e.primary_source,
    'rebalance', e.s4k_rebalance,
    'eventbrite_linked', EXISTS (SELECT 1 FROM public.exos_eventbrite_links l WHERE l.event_id = p_event_id),
    'tiers', coalesce((
      SELECT jsonb_agg(jsonb_build_object(
               'tier_id', t.id, 'name', t.name, 'capacity', t.capacity, 'sold', t.sold,
               'splittable', t.capacity > 0 AND NOT public.exos_tier_is_table(t.id) AND public.exos_rr_tier_price(t.id) > 0,
               's4k_split', coalesce(p.sell_cap, 0),
               's4k_sold', coalesce(p.sold_qty, d.sold_qty, 0),
               's4k_held', coalesce(p.requested_qty, 0),
               'shared_free', public.exos_effective_available(t.id),
               'eventbrite_mapped', EXISTS (SELECT 1 FROM public.exos_eventbrite_ticket_links k
                                             WHERE k.tier_id = t.id AND k.active),
               'listings', coalesce((SELECT jsonb_agg(x.quantity ORDER BY x.slot)
                                       FROM public.exos_s4k_listings x WHERE x.tier_id = t.id), '[]'::jsonb))
             ORDER BY t.sort_order NULLS LAST, t.id)
        FROM public.exos_ticket_tiers t
        LEFT JOIN LATERAL (SELECT * FROM public._exos_s4k_pool(t.id)) p ON p.id IS NOT NULL
        LEFT JOIN public.exos_distribution_listings d
          ON d.tier_id = t.id AND d.channel = 's4k' AND d.event_id = t.event_id
       WHERE t.event_id = p_event_id), '[]'::jsonb));
END $$;

-- ROLLBACK (manual): re-create exos_tier_available, exos_eventbrite_inventory_apply,
-- exos_feed_refresh and exos_s4k_pool_status from their earlier sources; drop
-- exos_s4k_listings, the new functions and the three exos_events columns and
-- exos_feed_consumers.auth_user_id.
