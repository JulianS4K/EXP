-- ============================================================================
-- Migration 20260927030000 — Exos (Bridge / D4): one marketplace sync for
--                            StubHub and SeatGeek, per ticket type, with
--                            internal seat numbers for GA
--
-- Lane:     d4 (exos / bridge ticketing infra)
-- Touches:  W: exos_distribution_listings (UNIQUE (event_id, channel) replaced by
--              two partial unique indexes; +internal_seats, +listed_snapshot)
--              exos_tickets (+internal_seat)
--              exos_internal_seat_counters (new)
--              FUNCTION exos_seat_count, exos_seats_take, exos_resize_internal_seats,
--                exos_claim_internal_seat, exos_pull_channel_allocations,
--                exos_sync_marketplace_distribution (new)
--              FUNCTION exos_set_channel_allocation, exos_request_distribution (replaced)
--              FUNCTION exos_link_channel_event, exos_fulfil_marketplace_order
--                (patched in place)
--              TRIGGER exos_events_marketplace_distribution ON exos_events (new;
--                replaces exos_events_stubhub_distribution)
--           R: exos_events, exos_ticket_tiers, exos_marketplace_orders
-- Pre-reqs: 20260926190000 .. 20260927020000
--
-- What "seamless" means here: the organizer ticks StubHub and / or SeatGeek,
-- fills in a grid (a row per ticket type, a column per marketplace: how many
-- seats each marketplace sells), and publishes. From then on Exos keeps the
-- marketplaces in step with the event, and takes the seats back when the
-- event stops selling there.
--
-- 1. Rows. Each (event, marketplace) has
--      * one EVENT row (tier_id NULL): the marketplace's copy of the event
--        (StubHub: the event request; SeatGeek: which event the listings
--        attach to), and
--      * one ALLOCATION row per ticket type (tier_id set): the seats set aside
--        for that marketplace, and the listing(s) that sell them.
--    The old UNIQUE (event_id, channel) allowed a single ticket type per
--    marketplace; it becomes two partial unique indexes. An existing row that
--    was both (a StubHub event request that later got an allocation) is split:
--    an event row is added next to it.
--
-- 2. Publishing and pulling back (trigger on exos_events, both marketplaces).
--      * published + ticked (not primary-market-only): the event row is
--        queued, as the StubHub-only trigger did (20260926190000).
--      * unticked, primary-market-only, cancelled, or unpublished: the
--        allocations are pulled back. "Delist, then release": an allocation
--        with nothing on the marketplace gives its seats back to Exos at once;
--        one that is live goes to 'delisting' and keeps its seats (still
--        counted by exos_channel_allocated) until the marketplace has taken
--        the listing down. Nothing is live while writes are dry-run, so today
--        the seats always come back at once.
--    Allocations on a draft stay put: the organizer can fill the grid before
--    publishing, and exos-distribute only plans listings for published events.
--
-- 3. exos_set_channel_allocation(event, channel, tier, qty) is per ticket
--    type (any number of them per marketplace). The marketplace must be
--    ticked. Setting 0 is the same "delist, then release". A listing that is
--    being taken down can't be changed until it's gone.
--
-- 4. Internal seat numbers. SeatGeek requires seat_from / seat_thru whenever
--    a row is given, and general admission has no seats. Every allocated seat
--    now gets an internal number, per ticket type, from a counter that never
--    hands the same number out twice (exos_internal_seat_counters), so two
--    marketplaces never share one. allocation.internal_seats holds the
--    unsold ones (count = requested_qty): growing takes new numbers,
--    shrinking drops the highest. A marketplace sale gives each ticket one of
--    them (exos_tickets.internal_seat): from the SeatGeek listing it sold on
--    when the order says which, else any left, else a new number. The
--    numbers are for Exos staff and the marketplace only: nothing
--    customer-facing shows them, and GA entry doesn't check them.
--
-- 5. listed_snapshot: what the marketplace has now (the listings as last
--    sent). exos-distribute compares its plan against it to plan updates and
--    delists. Stays NULL while writes are dry-run.
--
-- Re-run safe. D4 authors; applying to prod is operator-gated.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. Rows: event row + allocation rows per (event, marketplace).
-- ---------------------------------------------------------------------------
ALTER TABLE public.exos_distribution_listings
  ADD COLUMN IF NOT EXISTS internal_seats  int4multirange NOT NULL DEFAULT '{}',
  ADD COLUMN IF NOT EXISTS listed_snapshot jsonb;
COMMENT ON COLUMN public.exos_distribution_listings.internal_seats IS
  'Allocation rows: the internal seat numbers of the unsold allocated seats (count = requested_qty). Exos staff and the marketplace only.';
COMMENT ON COLUMN public.exos_distribution_listings.listed_snapshot IS
  'What the marketplace has now (listings as last sent). NULL while marketplace writes are dry-run.';

ALTER TABLE public.exos_tickets
  ADD COLUMN IF NOT EXISTS internal_seat int;
COMMENT ON COLUMN public.exos_tickets.internal_seat IS
  'Internal seat number for a general-admission ticket sold on a marketplace (listing seat_from/seat_thru). Not shown to customers.';
CREATE UNIQUE INDEX IF NOT EXISTS exos_tickets_internal_seat_uq
  ON public.exos_tickets (tier_id, internal_seat) WHERE internal_seat IS NOT NULL;

DO $$
DECLARE c record;
BEGIN
  FOR c IN
    SELECT con.conname FROM pg_constraint con
     WHERE con.conrelid = 'public.exos_distribution_listings'::regclass
       AND con.contype = 'u'
       AND (SELECT array_agg(a.attname::text ORDER BY a.attname)
              FROM unnest(con.conkey) k JOIN pg_attribute a
                ON a.attrelid = con.conrelid AND a.attnum = k) = ARRAY['channel','event_id']
  LOOP
    EXECUTE format('ALTER TABLE public.exos_distribution_listings DROP CONSTRAINT %I', c.conname);
  END LOOP;
END $$;

-- A row that is both an event request and an allocation: add the event row.
INSERT INTO public.exos_distribution_listings
  (event_id, org_id, channel, status, external_event_id, planned_request, error, last_synced_at)
SELECT DISTINCT ON (d.event_id, d.channel)
       d.event_id, d.org_id, d.channel,
       CASE WHEN d.channel = 'stubhub' AND d.status IN ('pending','planned','failed') THEN d.status ELSE 'pending' END,
       d.external_event_id, d.planned_request,
       CASE WHEN d.channel = 'stubhub' THEN d.error END,
       d.last_synced_at
  FROM public.exos_distribution_listings d
 WHERE d.channel IN ('stubhub','seatgeek')
   AND d.tier_id IS NOT NULL
   AND NOT EXISTS (SELECT 1 FROM public.exos_distribution_listings e
                    WHERE e.event_id = d.event_id AND e.channel = d.channel AND e.tier_id IS NULL)
 ORDER BY d.event_id, d.channel, d.created_at;

CREATE UNIQUE INDEX IF NOT EXISTS exos_distribution_listings_event_row_uq
  ON public.exos_distribution_listings (event_id, channel) WHERE tier_id IS NULL;
CREATE UNIQUE INDEX IF NOT EXISTS exos_distribution_listings_allocation_uq
  ON public.exos_distribution_listings (event_id, channel, tier_id) WHERE tier_id IS NOT NULL;

-- ---------------------------------------------------------------------------
-- 2. Internal seat numbers.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.exos_internal_seat_counters (
  tier_id   uuid PRIMARY KEY REFERENCES public.exos_ticket_tiers (id) ON DELETE CASCADE,
  next_seat integer NOT NULL DEFAULT 1 CHECK (next_seat >= 1)
);
ALTER TABLE public.exos_internal_seat_counters ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.exos_internal_seat_counters FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.exos_seat_count(p_seats int4multirange)
RETURNS int
LANGUAGE sql IMMUTABLE
SET search_path = public, pg_temp
AS $$
  SELECT COALESCE(SUM(upper(r) - lower(r)), 0)::int FROM unnest(coalesce(p_seats, '{}'::int4multirange)) r
$$;

-- The lowest (or highest) p_n seats of a set.
CREATE OR REPLACE FUNCTION public.exos_seats_take(p_seats int4multirange, p_n int, p_highest boolean DEFAULT false)
RETURNS int4multirange
LANGUAGE plpgsql IMMUTABLE
SET search_path = public, pg_temp
AS $$
DECLARE
  r      int4range;
  v_out  int4multirange := '{}';
  v_left int := greatest(coalesce(p_n, 0), 0);
  v_len  int;
BEGIN
  IF v_left = 0 THEN RETURN v_out; END IF;
  FOR r IN
    SELECT x FROM unnest(coalesce(p_seats, '{}'::int4multirange)) x
     ORDER BY CASE WHEN p_highest THEN -lower(x) ELSE lower(x) END
  LOOP
    v_len := upper(r) - lower(r);
    IF v_len <= v_left THEN
      v_out := v_out + int4multirange(r);
      v_left := v_left - v_len;
    ELSIF p_highest THEN
      v_out := v_out + int4multirange(int4range(upper(r) - v_left, upper(r)));
      v_left := 0;
    ELSE
      v_out := v_out + int4multirange(int4range(lower(r), lower(r) + v_left));
      v_left := 0;
    END IF;
    EXIT WHEN v_left = 0;
  END LOOP;
  RETURN v_out;
END $$;

-- New numbers for a ticket type, never handed out before.
CREATE OR REPLACE FUNCTION public.exos_new_internal_seats(p_tier_id uuid, p_n int)
RETURNS int4multirange
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE v_next int;
BEGIN
  IF coalesce(p_n, 0) <= 0 THEN RETURN '{}'; END IF;
  INSERT INTO public.exos_internal_seat_counters AS c (tier_id, next_seat)
  VALUES (p_tier_id, 1 + p_n)
  ON CONFLICT (tier_id) DO UPDATE SET next_seat = c.next_seat + p_n
  RETURNING next_seat INTO v_next;
  RETURN int4multirange(int4range(v_next - p_n, v_next));
END $$;
REVOKE ALL ON FUNCTION public.exos_new_internal_seats(uuid, int) FROM PUBLIC, anon, authenticated;

-- An allocation's seats resized to p_qty: new numbers to grow, drop the
-- highest to shrink.
CREATE OR REPLACE FUNCTION public.exos_resize_internal_seats(p_seats int4multirange, p_tier_id uuid, p_qty int)
RETURNS int4multirange
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_have int := public.exos_seat_count(p_seats);
  v_want int := greatest(coalesce(p_qty, 0), 0);
BEGIN
  IF v_want = 0 THEN RETURN '{}'; END IF;
  IF v_have < v_want THEN
    RETURN coalesce(p_seats, '{}') + public.exos_new_internal_seats(p_tier_id, v_want - v_have);
  ELSIF v_have > v_want THEN
    RETURN p_seats - public.exos_seats_take(p_seats, v_have - v_want, true);
  END IF;
  RETURN p_seats;
END $$;
REVOKE ALL ON FUNCTION public.exos_resize_internal_seats(int4multirange, uuid, int) FROM PUBLIC, anon, authenticated;

-- The seat for one ticket of a marketplace sale; takes it off the
-- allocation (whose row the caller has locked). Prefers the seats of the
-- SeatGeek listing the order was placed on ("ex<base32 id><n>", found in the
-- listings as sent, else as planned), then any seat left, then a new number.
-- Always the HIGHEST such seat: a listing sells from the top, so its
-- seat_from, and the blocks the next plan cuts, stay where they were.
CREATE OR REPLACE FUNCTION public.exos_claim_internal_seat(p_order_id uuid, p_listing_id uuid, p_tier_id uuid)
RETURNS int
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_raw    jsonb;
  v_chan   text;
  v_lid    text;
  v_n      int;
  v_plan   jsonb;
  v_l      jsonb;
  v_seats  int4multirange;
  v_pick   int4multirange;
  v_from   int;
  v_thru   int;
BEGIN
  IF p_tier_id IS NULL THEN RETURN NULL; END IF;
  SELECT raw, channel INTO v_raw, v_chan FROM public.exos_marketplace_orders WHERE id = p_order_id;
  SELECT internal_seats, coalesce(listed_snapshot, planned_listing) INTO v_seats, v_plan
    FROM public.exos_distribution_listings WHERE id = p_listing_id AND tier_id = p_tier_id;
  v_seats := coalesce(v_seats, '{}');

  IF v_chan = 'seatgeek' AND v_plan IS NOT NULL THEN
    v_lid := coalesce(v_raw #>> '{listing,id}', v_raw ->> 'item_id');
    IF v_lid ~ '^ex[a-z2-7]{26}[1-9][0-9]{0,3}$' THEN
      v_n := substring(v_lid from 29)::int;
      SELECT l INTO v_l FROM jsonb_array_elements(coalesce(v_plan -> 'listings', '[]')) l
       WHERE l #>> '{body,seller_listing_id}' = v_lid LIMIT 1;
      IF v_l IS NULL THEN
        v_l := v_plan -> 'listings' -> (v_n - 1);
      END IF;
      IF (v_l #>> '{body,seat_from}') ~ '^[0-9]{1,9}$' AND (v_l #>> '{body,seat_thru}') ~ '^[0-9]{1,9}$' THEN
        v_from := (v_l #>> '{body,seat_from}')::int;
        v_thru := (v_l #>> '{body,seat_thru}')::int;
        IF v_thru >= v_from THEN
          v_pick := public.exos_seats_take(v_seats * int4multirange(int4range(v_from, v_thru, '[]')), 1, true);
        END IF;
      END IF;
    END IF;
  END IF;
  IF v_pick IS NULL OR isempty(v_pick) THEN
    v_pick := public.exos_seats_take(v_seats, 1, true);
  END IF;
  IF isempty(v_pick) THEN
    v_pick := public.exos_new_internal_seats(p_tier_id, 1);
  ELSE
    UPDATE public.exos_distribution_listings
       SET internal_seats = internal_seats - v_pick
     WHERE id = p_listing_id;
  END IF;
  RETURN lower(v_pick);
END $$;
REVOKE ALL ON FUNCTION public.exos_claim_internal_seat(uuid, uuid, uuid) FROM PUBLIC, anon, authenticated;

-- Existing allocations get their numbers.
UPDATE public.exos_distribution_listings d
   SET internal_seats = public.exos_resize_internal_seats(d.internal_seats, d.tier_id, d.requested_qty)
 WHERE d.tier_id IS NOT NULL
   AND d.status IN ('pending','planned','listing','listed','delisting')
   AND coalesce(d.requested_qty, 0) > 0
   AND public.exos_seat_count(d.internal_seats) <> d.requested_qty;

-- ---------------------------------------------------------------------------
-- 3. Pull back: delist, then release.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.exos_pull_channel_allocations(p_event_id uuid, p_channel text)
RETURNS int
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE v_n int; v_m int;
BEGIN
  -- Nothing on the marketplace: the seats go back to Exos now.
  UPDATE public.exos_distribution_listings
     SET requested_qty = 0, internal_seats = '{}', status = 'delisted',
         planned_listing = NULL, error = NULL, updated_at = now()
   WHERE event_id = p_event_id AND channel = p_channel AND tier_id IS NOT NULL
     AND external_listing_id IS NULL AND listed_snapshot IS NULL
     AND status IN ('pending','planned','failed');
  GET DIAGNOSTICS v_n = ROW_COUNT;
  -- Live: take the listing down first; the seats stay set aside until then.
  UPDATE public.exos_distribution_listings
     SET status = 'delisting', updated_at = now()
   WHERE event_id = p_event_id AND channel = p_channel AND tier_id IS NOT NULL
     AND status NOT IN ('delisting','delisted')
     AND (external_listing_id IS NOT NULL OR listed_snapshot IS NOT NULL OR status IN ('listing','listed'));
  GET DIAGNOSTICS v_m = ROW_COUNT;
  RETURN v_n + v_m;
END $$;
REVOKE ALL ON FUNCTION public.exos_pull_channel_allocations(uuid, text) FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 4. The event trigger, for both marketplaces (replaces the StubHub-only one).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.exos_sync_marketplace_distribution()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_ch      text;
  v_ticked  boolean;
  v_primary boolean := coalesce(NEW.exclusivity ->> 'primaryMarketOnly', 'false') = 'true';
BEGIN
  FOREACH v_ch IN ARRAY ARRAY['stubhub','seatgeek'] LOOP
    v_ticked := v_ch = ANY (coalesce(NEW.distribution_networks, '{}'::text[]));
    IF NEW.status = 'published' AND v_ticked AND NOT v_primary THEN
      INSERT INTO public.exos_distribution_listings (event_id, org_id, channel, status)
      VALUES (NEW.id, NEW.org_id, v_ch, 'pending')
      ON CONFLICT (event_id, channel) WHERE tier_id IS NULL DO UPDATE
        SET status = 'pending', error = NULL, planned_request = NULL, updated_at = now()
        WHERE exos_distribution_listings.external_event_id IS NULL
          AND exos_distribution_listings.external_listing_id IS NULL
          AND exos_distribution_listings.status IN ('pending','planned','failed','delisted');
    ELSE
      DELETE FROM public.exos_distribution_listings
       WHERE event_id = NEW.id AND channel = v_ch AND tier_id IS NULL
         AND external_event_id IS NULL AND external_listing_id IS NULL
         AND status IN ('pending','planned','failed');
    END IF;

    IF NOT v_ticked OR v_primary OR NEW.status = 'cancelled'
       OR (TG_OP = 'UPDATE' AND OLD.status = 'published' AND NEW.status IS DISTINCT FROM 'published') THEN
      PERFORM public.exos_pull_channel_allocations(NEW.id, v_ch);
    END IF;
  END LOOP;
  RETURN NULL;
END $$;
REVOKE EXECUTE ON FUNCTION public.exos_sync_marketplace_distribution() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS exos_events_stubhub_distribution ON public.exos_events;
DROP FUNCTION IF EXISTS public.exos_sync_stubhub_distribution();
DROP TRIGGER IF EXISTS exos_events_marketplace_distribution ON public.exos_events;
CREATE TRIGGER exos_events_marketplace_distribution
  AFTER INSERT OR UPDATE OF status, distribution_networks, exclusivity, name, starts_at,
                            venue_name, venue_location, venue_address
  ON public.exos_events
  FOR EACH ROW EXECUTE FUNCTION public.exos_sync_marketplace_distribution();

-- ---------------------------------------------------------------------------
-- 5. Allocations per ticket type (replaces 20260926193000's).
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
  v_cur    int := 0;
  v_avail  int;
  v_sum    bigint;
  v_uncap  boolean;
  v_live   boolean;
  v_label  text;
  q        record;
BEGIN
  SELECT * INTO v_ev FROM public.exos_events WHERE id = p_event_id;
  IF v_ev.id IS NULL THEN
    RAISE EXCEPTION 'exos_set_channel_allocation: event not found';
  END IF;
  -- Only authenticated (always has a uid) and service_role can execute this;
  -- current_user is the owner inside SECURITY DEFINER, so the caller is told
  -- apart by auth.uid(): a user must be org owner/manager, no uid = service.
  IF auth.uid() IS NOT NULL
     AND NOT (exos_is_admin() OR exos_has_org_role(v_ev.org_id, ARRAY['owner','manager'])) THEN
    RAISE EXCEPTION 'exos_set_channel_allocation: not authorized' USING ERRCODE = '42501';
  END IF;
  IF p_channel NOT IN ('stubhub','seatgeek','vivid','tickpick','evo','automatiq') THEN
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

  -- The house cap must not be tighter than the ticket types, or a tier-level
  -- allocation can't protect it (20260926193000).
  SELECT COALESCE(SUM(capacity), 0), bool_or(capacity = 0) INTO v_sum, v_uncap
    FROM public.exos_ticket_tiers WHERE event_id = p_event_id;
  IF p_qty > 0 AND v_ev.total_tickets > 0 AND (v_uncap OR v_ev.total_tickets < v_sum) THEN
    RAISE EXCEPTION 'exos_set_channel_allocation: the event''s overall capacity (%) is lower than its ticket types add up to; give every ticket type a capacity and make the overall cap at least their sum (% ) before selling on a marketplace',
      v_ev.total_tickets, v_sum USING ERRCODE = '23514';
  END IF;

  -- Locks: the allocation row, then quotas, then the tier (as exos_create_hold
  -- and a marketplace fulfil), so this can't race a checkout.
  SELECT * INTO d FROM public.exos_distribution_listings
   WHERE event_id = p_event_id AND channel = p_channel AND tier_id = p_tier_id FOR UPDATE;
  IF d.status = 'delisting' THEN
    RAISE EXCEPTION 'exos_set_channel_allocation: this ticket type is being taken off %; change it once that is done', v_label;
  END IF;
  FOR q IN SELECT quota_id FROM public.exos_quota_tiers WHERE tier_id = p_tier_id ORDER BY quota_id LOOP
    PERFORM 1 FROM public.exos_quotas WHERE id = q.quota_id FOR UPDATE;
  END LOOP;
  -- WRITE the tier row, not just lock it (see 20260926193000): a concurrent
  -- mint waiting on it must re-check its availability.
  UPDATE public.exos_ticket_tiers SET sort_order = sort_order WHERE id = p_tier_id;

  IF d.id IS NOT NULL AND d.status IN ('pending','planned','listing','listed') THEN
    v_cur := greatest(coalesce(d.requested_qty, 0), 0);
  END IF;
  IF p_qty > v_cur THEN
    v_avail := public.exos_effective_available(p_tier_id);   -- already excludes v_cur
    IF v_avail IS NOT NULL AND v_avail < p_qty - v_cur THEN
      RAISE EXCEPTION 'exos_set_channel_allocation: only % more seat(s) free on this ticket type', v_avail
        USING ERRCODE = '23514';
    END IF;
  END IF;

  v_live := d.id IS NOT NULL
        AND (d.external_listing_id IS NOT NULL OR d.listed_snapshot IS NOT NULL OR d.status IN ('listing','listed'));

  IF d.id IS NULL THEN
    IF p_qty = 0 THEN RETURN 0; END IF;
    INSERT INTO public.exos_distribution_listings
      (event_id, org_id, channel, status, tier_id, requested_qty, internal_seats)
    VALUES (p_event_id, v_ev.org_id, p_channel, 'pending', p_tier_id, p_qty,
            public.exos_new_internal_seats(p_tier_id, p_qty));
  ELSIF p_qty = 0 AND v_live THEN
    -- Delist, then release: the seats stay set aside until it's off the marketplace.
    UPDATE public.exos_distribution_listings SET status = 'delisting', updated_at = now() WHERE id = d.id;
  ELSIF p_qty = 0 THEN
    UPDATE public.exos_distribution_listings
       SET requested_qty = 0, internal_seats = '{}', status = 'delisted',
           planned_listing = NULL, error = NULL, updated_at = now()
     WHERE id = d.id;
  ELSE
    UPDATE public.exos_distribution_listings
       SET requested_qty = p_qty,
           internal_seats = public.exos_resize_internal_seats(
             CASE WHEN v_cur > 0 THEN d.internal_seats ELSE '{}'::int4multirange END, p_tier_id, p_qty),
           -- A failed / delisted row holds nothing; allocating again revives it.
           status = CASE WHEN status IN ('failed','delisted') THEN 'pending' ELSE status END,
           error = CASE WHEN status IN ('failed','delisted') THEN NULL ELSE error END,
           updated_at = now()
     WHERE id = d.id;
  END IF;
  RETURN p_qty;
END $$;
REVOKE ALL ON FUNCTION public.exos_set_channel_allocation(uuid, text, uuid, int) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.exos_set_channel_allocation(uuid, text, uuid, int) TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 6. The older request RPC (20260523190000) writes event rows only.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.exos_request_distribution(
  p_event_id  uuid,
  p_channels  text[],
  p_qty       int     DEFAULT NULL,
  p_unit_price numeric DEFAULT NULL
) RETURNS int
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_org    uuid;
  v_status text;
  v_chan   text;
  v_n      int := 0;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'exos_request_distribution: not authenticated' USING ERRCODE = '42501';
  END IF;
  SELECT org_id, status INTO v_org, v_status FROM public.exos_events WHERE id = p_event_id;
  IF v_org IS NULL THEN
    RAISE EXCEPTION 'exos_request_distribution: event not found';
  END IF;
  IF NOT (exos_is_admin() OR exos_has_org_role(v_org, ARRAY['owner','manager'])) THEN
    RAISE EXCEPTION 'exos_request_distribution: not authorized' USING ERRCODE = '42501';
  END IF;
  IF v_status <> 'published' THEN
    RAISE EXCEPTION 'exos_request_distribution: event must be published (is %)', v_status;
  END IF;
  IF p_channels IS NULL OR array_length(p_channels, 1) IS NULL THEN
    RAISE EXCEPTION 'exos_request_distribution: no channels specified';
  END IF;

  FOREACH v_chan IN ARRAY p_channels LOOP
    INSERT INTO public.exos_distribution_listings (event_id, org_id, channel, status, requested_qty, unit_price)
    VALUES (p_event_id, v_org, v_chan, 'pending', p_qty, p_unit_price)
    ON CONFLICT (event_id, channel) WHERE tier_id IS NULL DO UPDATE
      SET status = 'pending', requested_qty = EXCLUDED.requested_qty,
          unit_price = EXCLUDED.unit_price, error = NULL, updated_at = now();
    v_n := v_n + 1;
  END LOOP;

  UPDATE public.exos_events
     SET distribution_networks = p_channels, sync_status = 'pending', updated_at = now()
   WHERE id = p_event_id;

  RETURN v_n;
END $$;
REVOKE EXECUTE ON FUNCTION public.exos_request_distribution(uuid, text[], int, numeric) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.exos_request_distribution(uuid, text[], int, numeric) TO authenticated;

-- ---------------------------------------------------------------------------
-- 7. In-place patches (assert one match; skipped once applied).
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

-- A staff link decision re-queues the marketplace's event row (both
-- marketplaces), never the allocation rows.
SELECT pg_temp.exos_patch('public.exos_link_channel_event(uuid, text, text)',
  'IF p_channel IN (''stubhub'',''seatgeek'') THEN',
  'IF p_channel = ''stubhub'' THEN',
  'IF p_channel IN (''stubhub'',''seatgeek'') THEN');
SELECT pg_temp.exos_patch('public.exos_link_channel_event(uuid, text, text)',
  'channel = p_channel AND tier_id IS NULL',
  'WHERE event_id = p_event_id AND channel = ''stubhub''',
  'WHERE event_id = p_event_id AND channel = p_channel AND tier_id IS NULL');

-- Each marketplace ticket gets its internal seat.
SELECT pg_temp.exos_patch('public.exos_fulfil_marketplace_order(uuid, text)',
  'order_ref, channel_source, internal_seat',
  'order_ref, channel_source',
  'order_ref, channel_source, internal_seat');
SELECT pg_temp.exos_patch('public.exos_fulfil_marketplace_order(uuid, text)',
  'public.exos_claim_internal_seat(o.id',
  'v_price, v_ref, o.channel',
  'v_price, v_ref, o.channel, public.exos_claim_internal_seat(o.id, o.distribution_listing_id, o.tier_id)');
