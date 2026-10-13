-- S4K network feed (docs/marketplace/s4k-feed.md).
--
-- Exos is the box office; S4K mirrors it the way it mirrors its Ticket Desk
-- (Paciolan / Ticketmaster): a read-only, token-gated two-call feed, polled,
-- with a signed webhook as the secondary "something moved" signal. S4K lists
-- through Automatiq on its own accounts. Exos never writes to a marketplace.
-- A marketplace sale comes back as S4K buying from Exos (exos_feed_place_order),
-- which takes seats under the same locks as every other mint, or REJECTS it:
-- no partial fills, no oversold Exos order. A rejected order is logged in
-- exos_feed_rejections; the marketplace-side penalty is S4K's (operator
-- decision 2026-10-13) until the system is further along.
--
--   exos_orgs.s4k_network        per-org opt-in (owner; the consignment flag)
--   exos_events.distribution_route  'direct' (Exos lists per marketplace) or
--                                  's4k' (S4K lists). Feed = s4k route only.
--   exos_feed_consumers          one row per consumer (S4K), token as a SHA-256
--                                 hash, webhook URL + secret + cursor
--   exos_feed_events             per-event feed state: a content hash, so
--                                 updated_at moves only on a real change
--                                 (the desk's "only store a changed pull")
--   exos_feed_rejections         orders refused (sold out, price moved, ...)
--
-- The count per ticket type (one GA line each) is the broadcast count:
--   quantity = max(0, free now − one pack)       pack = max per order, else 8
-- free now = exos_effective_available (quotas, holds and other channels'
-- allocations already out) capped by the event's house cap. Orders may still
-- take the last pack: the buffer is for the lag of S4K's poll and Automatiq's
-- push, not a reserve.
--
-- Touches:  C: TABLE exos_feed_consumers, exos_feed_events, exos_feed_rejections
--           W: exos_orgs (+ s4k_network), exos_events (+ distribution_route),
--              exos_marketplace_orders (channel check + 's4k')
--           C: FUNCTION _exos_feed_*, exos_feed_refresh, exos_feed_events_page,
--              exos_feed_event_tickets, exos_feed_place_order,
--              exos_feed_order_tickets, exos_feed_order_status, exos_feed_cancel_order,
--              exos_feed_webhook_due / _ack, exos_feed_create_consumer
--              (service role); exos_set_s4k_network, exos_set_distribution_route
--              (authenticated, role-checked)
--           W: FUNCTION exos_fulfil_marketplace_order (patched: 'S4K' label),
--              exos_set_channel_allocation + _exos_channel_split_plan (patched:
--              nothing allocated directly on an s4k event)
--           C: cron.schedule (exos-s4k-feed-1min, when pg_cron present)
-- Prod apply needs operator OK.

-- ---------------------------------------------------------------------------
ALTER TABLE public.exos_orgs ADD COLUMN IF NOT EXISTS s4k_network boolean NOT NULL DEFAULT false;
ALTER TABLE public.exos_events ADD COLUMN IF NOT EXISTS distribution_route text NOT NULL DEFAULT 'direct';
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'exos_events_distribution_route_check') THEN
    ALTER TABLE public.exos_events ADD CONSTRAINT exos_events_distribution_route_check
      CHECK (distribution_route IN ('direct','s4k'));
  END IF;
END $$;

-- 's4k' as a marketplace-order channel (the sale comes back through S4K).
-- Same shape as the earlier channel migrations (they re-read it on replay).
DO $$
DECLARE v_def text;
BEGIN
  SELECT pg_get_constraintdef(oid) INTO v_def FROM pg_constraint
   WHERE conname = 'exos_marketplace_orders_channel_check' AND conrelid = 'public.exos_marketplace_orders'::regclass;
  IF v_def IS NOT NULL AND position('''s4k''' in v_def) = 0 THEN
    IF position('ARRAY[' in v_def) = 0 THEN
      RAISE EXCEPTION 's4k: unexpected shape for exos_marketplace_orders_channel_check: %', v_def;
    END IF;
    ALTER TABLE public.exos_marketplace_orders DROP CONSTRAINT exos_marketplace_orders_channel_check;
    EXECUTE 'ALTER TABLE public.exos_marketplace_orders ADD CONSTRAINT exos_marketplace_orders_channel_check '
         || replace(v_def, 'ARRAY[', 'ARRAY[''s4k''::text, ');
  END IF;
END $$;

-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.exos_feed_consumers (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name                text NOT NULL UNIQUE CHECK (length(name) BETWEEN 1 AND 80),
  token_hash          text NOT NULL UNIQUE CHECK (token_hash ~ '^[0-9a-f]{64}$'),
  token_prefix        text NOT NULL,
  -- Where an order's claim links are mailed when the order names no buyer.
  delivery_email      text CHECK (delivery_email IS NULL OR delivery_email ~ '^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$'),
  webhook_url         text CHECK (webhook_url IS NULL OR webhook_url ~ '^https://'),
  webhook_secret      text NOT NULL DEFAULT encode(extensions.gen_random_bytes(24), 'hex'),
  webhook_cursor      timestamptz,
  webhook_cursor_id   uuid,
  webhook_failures    integer NOT NULL DEFAULT 0,
  webhook_next_at     timestamptz,
  webhook_last_ok_at  timestamptz,
  webhook_last_error  text,
  last_used_at        timestamptz,
  revoked_at          timestamptz,
  created_at          timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.exos_feed_consumers ADD COLUMN IF NOT EXISTS webhook_cursor_id uuid;
ALTER TABLE public.exos_feed_consumers ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.exos_feed_consumers FROM PUBLIC, anon, authenticated;

CREATE TABLE IF NOT EXISTS public.exos_feed_events (
  event_id        uuid PRIMARY KEY REFERENCES public.exos_events (id) ON DELETE CASCADE,
  org_id          uuid NOT NULL REFERENCES public.exos_orgs (id) ON DELETE CASCADE,
  status          text NOT NULL CHECK (status IN ('active','withdrawn')),
  available       integer NOT NULL DEFAULT 0,
  total_capacity  integer NOT NULL DEFAULT 0,
  content_hash    text NOT NULL,
  updated_at      timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS exos_feed_events_updated_idx ON public.exos_feed_events (updated_at, event_id);
ALTER TABLE public.exos_feed_events ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.exos_feed_events FROM PUBLIC, anon, authenticated;

CREATE TABLE IF NOT EXISTS public.exos_feed_rejections (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  consumer_id   uuid NOT NULL REFERENCES public.exos_feed_consumers (id) ON DELETE CASCADE,
  event_id      uuid REFERENCES public.exos_events (id) ON DELETE SET NULL,
  tier_id       uuid,
  quantity      integer,
  available     integer,
  reason        text NOT NULL,
  external_ref  text,
  marketplace   text,
  created_at    timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS exos_feed_rejections_event_idx ON public.exos_feed_rejections (event_id, created_at);
ALTER TABLE public.exos_feed_rejections ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.exos_feed_rejections FROM PUBLIC, anon, authenticated;
DROP POLICY IF EXISTS exos_feed_rejections_sel ON public.exos_feed_rejections;
CREATE POLICY exos_feed_rejections_sel ON public.exos_feed_rejections FOR SELECT TO authenticated
  USING (EXISTS (SELECT 1 FROM public.exos_events e WHERE e.id = event_id
                  AND public.exos_has_org_role(e.org_id, ARRAY['owner','manager','finance'])));
GRANT SELECT ON public.exos_feed_rejections TO authenticated;

-- ---------------------------------------------------------------------------
-- The consumer behind a token hash, or NULL. Touches last_used_at at most once a minute.
CREATE OR REPLACE FUNCTION public._exos_feed_consumer(p_token_hash text)
RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE v_id uuid; v_used timestamptz;
BEGIN
  SELECT id, last_used_at INTO v_id, v_used FROM public.exos_feed_consumers
   WHERE token_hash = lower(coalesce(p_token_hash, '')) AND revoked_at IS NULL;
  IF v_id IS NOT NULL AND (v_used IS NULL OR v_used < now() - interval '1 minute') THEN
    UPDATE public.exos_feed_consumers SET last_used_at = now() WHERE id = v_id;
  END IF;
  RETURN v_id;
END $$;
REVOKE ALL ON FUNCTION public._exos_feed_consumer(text) FROM PUBLIC, anon, authenticated;

-- Max per order / buffer pack for an event.
CREATE OR REPLACE FUNCTION public._exos_feed_pack(p_limits jsonb)
RETURNS integer LANGUAGE sql IMMUTABLE
SET search_path = public, pg_temp
AS $$
  SELECT CASE WHEN (p_limits ->> 'maxPerOrder') ~ '^[0-9]{1,4}$' AND (p_limits ->> 'maxPerOrder')::int > 0
              THEN (p_limits ->> 'maxPerOrder')::int ELSE 8 END;
$$;

REVOKE ALL ON FUNCTION public._exos_feed_pack(jsonb) FROM PUBLIC, anon, authenticated;

-- Is this event on the feed right now?
CREATE OR REPLACE FUNCTION public._exos_feed_eligible(p_event_id uuid)
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.exos_events e JOIN public.exos_orgs o ON o.id = e.org_id
     WHERE e.id = p_event_id AND o.s4k_network AND e.distribution_route = 's4k'
       AND e.status = 'published' AND coalesce(e.doors_at, e.starts_at) > now());
$$;
REVOKE ALL ON FUNCTION public._exos_feed_eligible(uuid) FROM PUBLIC, anon, authenticated;

-- The feed lines of one event, live: one per sellable GA ticket type.
-- Not sellable: free (resale marketplaces don't get free tickets), hidden,
-- table, outside its sales window, or no capacity set.
CREATE OR REPLACE FUNCTION public._exos_feed_lines(p_event_id uuid)
RETURNS TABLE (tier_id uuid, name text, sort_order integer, quantity integer, free_now integer,
               capacity integer, max_per_order integer, split text, price numeric, net numeric, currency text)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
#variable_conflict use_column
DECLARE
  e       public.exos_events%ROWTYPE;
  v_pack  int;
  v_house int;
  v_bps   int;
  t       record;
  v_free  int;
BEGIN
  SELECT * INTO e FROM public.exos_events WHERE id = p_event_id;
  IF e.id IS NULL THEN RETURN; END IF;
  v_pack  := public._exos_feed_pack(e.purchase_limits);
  v_house := CASE WHEN coalesce(e.total_tickets, 0) > 0 THEN greatest(e.total_tickets - e.tickets_sold, 0) END;
  v_bps   := public.exos_org_fee_bps(e.org_id, now());
  FOR t IN
    SELECT tt.id, tt.name, tt.sort_order, tt.capacity, coalesce(tt.market_split, 'any') AS split
      FROM public.exos_ticket_tiers tt
     WHERE tt.event_id = p_event_id AND tt.capacity > 0 AND tt.visibility = 'public'
       AND NOT public.exos_tier_is_table(tt.id)
       AND (tt.sales_start IS NULL OR tt.sales_start <= now())
       AND (tt.sales_end IS NULL OR tt.sales_end > now())
       AND public.exos_rr_tier_price(tt.id) > 0
     ORDER BY tt.sort_order NULLS LAST, tt.id
  LOOP
    v_free := greatest(coalesce(public.exos_effective_available(t.id), 0), 0);
    IF v_house IS NOT NULL THEN v_free := least(v_free, v_house); END IF;
    tier_id := t.id; name := t.name; sort_order := t.sort_order;
    free_now := v_free;
    quantity := greatest(v_free - v_pack, 0);
    capacity := t.capacity;
    max_per_order := CASE WHEN (e.purchase_limits ->> 'maxPerOrder') ~ '^[0-9]{1,4}$'
                            AND (e.purchase_limits ->> 'maxPerOrder')::int > 0
                          THEN (e.purchase_limits ->> 'maxPerOrder')::int END;
    split := t.split;
    price := round(public.exos_rr_tier_price(t.id), 2);
    net   := round(price - round(price * v_bps / 10000.0, 2), 2);
    currency := upper(coalesce(e.currency, 'USD'));
    RETURN NEXT;
  END LOOP;
END $$;
REVOKE ALL ON FUNCTION public._exos_feed_lines(uuid) FROM PUBLIC, anon, authenticated;

-- Record the feed state: updated_at moves only when an event's content
-- changes; an event that drops off is marked withdrawn once. Stamped with
-- the wall clock (not the transaction start), and readers stay 15 s behind
-- it, so a change committing while someone reads is never skipped. NULL = every
-- event (skipped when another refresh holds the lock); an id = that event.
CREATE OR REPLACE FUNCTION public.exos_feed_refresh(p_event_id uuid DEFAULT NULL)
RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  r       record;
  v_hash  text;
  v_avail int;
  v_cap   int;
  v_n     int := 0;
  v_rows  int;
BEGIN
  IF p_event_id IS NULL AND NOT pg_try_advisory_xact_lock(hashtext('exos_feed_refresh')) THEN
    RETURN 0;
  END IF;
  FOR r IN
    SELECT e.id, e.org_id, e.name, e.starts_at, e.doors_at, e.timezone, e.venue_name, e.venue_address, e.status
      FROM public.exos_events e JOIN public.exos_orgs o ON o.id = e.org_id
     WHERE (p_event_id IS NULL OR e.id = p_event_id)
       AND ((o.s4k_network AND e.distribution_route = 's4k')
            OR EXISTS (SELECT 1 FROM public.exos_feed_events f WHERE f.event_id = e.id AND f.status = 'active'))
  LOOP
    IF public._exos_feed_eligible(r.id) THEN
      SELECT coalesce(sum(l.quantity), 0), coalesce(sum(l.capacity), 0),
             md5(concat_ws('|', r.name, r.starts_at, r.doors_at, r.timezone, r.venue_name, r.venue_address::text,
                 coalesce(string_agg(concat_ws(':', l.tier_id, l.name, l.quantity, l.max_per_order, l.split, l.price, l.net),
                                     ',' ORDER BY l.tier_id), '')))
        INTO v_avail, v_cap, v_hash
        FROM public._exos_feed_lines(r.id) l;
      INSERT INTO public.exos_feed_events AS f (event_id, org_id, status, available, total_capacity, content_hash, updated_at)
      VALUES (r.id, r.org_id, 'active', v_avail, v_cap, v_hash, clock_timestamp())
      ON CONFLICT (event_id) DO UPDATE
        SET status = 'active', available = EXCLUDED.available, total_capacity = EXCLUDED.total_capacity,
            content_hash = EXCLUDED.content_hash, updated_at = clock_timestamp()
        WHERE f.content_hash IS DISTINCT FROM EXCLUDED.content_hash OR f.status <> 'active';
    ELSE
      UPDATE public.exos_feed_events
         SET status = 'withdrawn', available = 0, content_hash = 'withdrawn', updated_at = clock_timestamp()
       WHERE event_id = r.id AND status = 'active';
    END IF;
    GET DIAGNOSTICS v_rows = ROW_COUNT;
    v_n := v_n + v_rows;
  END LOOP;
  RETURN v_n;
END $$;
REVOKE ALL ON FUNCTION public.exos_feed_refresh(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_feed_refresh(uuid) TO service_role;

-- ---------------------------------------------------------------------------
-- Call 1: events on the feed (active, plus withdrawn ones changed since p_since).
CREATE OR REPLACE FUNCTION public.exos_feed_events_page(p_token_hash text, p_since timestamptz DEFAULT NULL,
                                                        p_limit integer DEFAULT 200, p_offset integer DEFAULT 0)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  -- Pass generatedAt back as updatedSince: it is 15 s behind the clock, so a
  -- change committing during this call shows up next time (perhaps twice).
  v_now    timestamptz := now() - interval '15 seconds';
  v_limit  int := least(greatest(coalesce(p_limit, 200), 1), 1000);
  v_offset int := greatest(coalesce(p_offset, 0), 0);
  v_total  int;
  v_rows   jsonb;
BEGIN
  IF public._exos_feed_consumer(p_token_hash) IS NULL THEN
    RETURN jsonb_build_object('error', 'unauthorized');
  END IF;
  PERFORM public.exos_feed_refresh(NULL);

  SELECT count(*) INTO v_total FROM public.exos_feed_events f
   WHERE (p_since IS NULL AND f.status = 'active') OR (p_since IS NOT NULL AND f.updated_at >= p_since);

  SELECT coalesce(jsonb_agg(row ORDER BY ord_starts, ord_id), '[]'::jsonb) INTO v_rows FROM (
    SELECT e.starts_at AS ord_starts, e.id AS ord_id, jsonb_build_object(
      'event_id', e.id, 'status', f.status, 'organizer', o.name, 'name', e.name,
      'venue_name', e.venue_name, 'venue_address', e.venue_address, 'timezone', e.timezone,
      'starts_at', e.starts_at, 'doors_at', e.doors_at, 'occurs_at_local', e.occurs_at_local,
      'slug', e.slug, 'available', f.available, 'total_capacity', f.total_capacity,
      'updated_at', f.updated_at) AS row
      FROM public.exos_feed_events f
      JOIN public.exos_events e ON e.id = f.event_id
      JOIN public.exos_orgs o ON o.id = e.org_id
     WHERE (p_since IS NULL AND f.status = 'active') OR (p_since IS NOT NULL AND f.updated_at >= p_since)
     ORDER BY e.starts_at, e.id
     LIMIT v_limit OFFSET v_offset) s;

  RETURN jsonb_build_object('generated_at', v_now, 'total', v_total, 'limit', v_limit, 'offset', v_offset, 'events', v_rows);
END $$;
REVOKE ALL ON FUNCTION public.exos_feed_events_page(text, timestamptz, integer, integer) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_feed_events_page(text, timestamptz, integer, integer) TO service_role;

-- Call 2: one event's lines, live. NULL when unknown / not on the feed.
CREATE OR REPLACE FUNCTION public.exos_feed_event_tickets(p_token_hash text, p_event_id uuid)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  e      public.exos_events%ROWTYPE;
  v_rows jsonb;
BEGIN
  IF public._exos_feed_consumer(p_token_hash) IS NULL THEN
    RETURN jsonb_build_object('error', 'unauthorized');
  END IF;
  IF NOT public._exos_feed_eligible(p_event_id) THEN
    RETURN NULL;
  END IF;
  SELECT * INTO e FROM public.exos_events WHERE id = p_event_id;
  SELECT coalesce(jsonb_agg(jsonb_build_object(
           'tier_id', l.tier_id, 'name', l.name, 'quantity', l.quantity, 'max_per_order', l.max_per_order,
           'split', l.split, 'price', l.price, 'net', l.net, 'currency', l.currency)
           ORDER BY l.sort_order NULLS LAST, l.tier_id) FILTER (WHERE l.quantity > 0), '[]'::jsonb)
    INTO v_rows FROM public._exos_feed_lines(p_event_id) l;
  RETURN jsonb_build_object('generated_at', now(), 'event_id', e.id, 'name', e.name,
                            'starts_at', e.starts_at, 'timezone', e.timezone, 'tickets', v_rows);
END $$;
REVOKE ALL ON FUNCTION public.exos_feed_event_tickets(text, uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_feed_event_tickets(text, uuid) TO service_role;

-- ---------------------------------------------------------------------------
-- S4K buys from Exos to fill a marketplace sale. All or nothing:
--   result 'created'  : tickets minted, claim links returned
--   result 'existing' : the same external_ref was placed before (idempotent)
--   result 'rejected' : nothing taken; logged in exos_feed_rejections
-- p_unit_price is what S4K pays Exos per ticket; below the current price → rejected.
CREATE OR REPLACE FUNCTION public.exos_feed_place_order(
  p_token_hash text, p_event_id uuid, p_tier_id uuid, p_quantity integer, p_external_ref text,
  p_marketplace text DEFAULT NULL, p_unit_price numeric DEFAULT NULL, p_buyer_email text DEFAULT NULL,
  p_app_base text DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_cons   uuid := public._exos_feed_consumer(p_token_hash);
  c        public.exos_feed_consumers%ROWTYPE;
  e        public.exos_events%ROWTYPE;
  l        record;
  o        public.exos_marketplace_orders%ROWTYPE;
  v_ref    text := nullif(btrim(coalesce(p_external_ref, '')), '');
  v_mkt    text := left(nullif(lower(btrim(coalesce(p_marketplace, ''))), ''), 40);
  v_email  text := lower(nullif(btrim(coalesce(p_buyer_email, '')), ''));
  v_why    text;
  v_avail  int;
  f        record;
BEGIN
  IF v_cons IS NULL THEN
    RETURN jsonb_build_object('result', 'unauthorized');
  END IF;
  SELECT * INTO c FROM public.exos_feed_consumers WHERE id = v_cons;
  IF v_ref IS NULL OR length(v_ref) > 100 THEN
    RETURN jsonb_build_object('result', 'invalid', 'error', 'externalRef is required (at most 100 characters)');
  END IF;
  IF v_email IS NOT NULL AND (length(v_email) > 320 OR v_email !~ '^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$') THEN
    RETURN jsonb_build_object('result', 'invalid', 'error', 'buyerEmail is not an email address');
  END IF;
  v_email := coalesce(v_email, c.delivery_email);

  -- Idempotent on externalRef: retries in flight wait here for the first one.
  PERFORM pg_advisory_xact_lock(hashtextextended('exos_feed_order:' || v_ref, 0));
  SELECT * INTO o FROM public.exos_marketplace_orders WHERE channel = 's4k' AND external_order_id = v_ref;
  IF o.id IS NOT NULL THEN
    IF (o.raw ->> 'consumer_id') IS DISTINCT FROM v_cons::text THEN
      RETURN jsonb_build_object('result', 'invalid', 'error', 'externalRef already used');
    END IF;
    RETURN jsonb_build_object('result', 'existing', 'order_id', o.id, 'status', o.status,
                              'transfer_ids', to_jsonb(o.transfer_ids), 'reason', o.attention_reason);
  END IF;

  SELECT * INTO e FROM public.exos_events WHERE id = p_event_id;
  SELECT * INTO l FROM public._exos_feed_lines(p_event_id) x WHERE x.tier_id = p_tier_id;
  v_avail := l.free_now;
  v_why := CASE
    WHEN e.id IS NULL OR NOT public._exos_feed_eligible(p_event_id) THEN 'not_on_feed'
    WHEN l.tier_id IS NULL THEN 'ticket_not_on_feed'
    WHEN p_quantity IS NULL OR p_quantity < 1 OR p_quantity > 100 THEN 'bad_quantity'
    WHEN l.max_per_order IS NOT NULL AND p_quantity > l.max_per_order THEN 'over_max_per_order'
    WHEN v_email IS NULL THEN 'no_delivery_email'
    WHEN p_unit_price IS NULL OR p_unit_price < l.price - 0.005 THEN 'price_changed'
  END;

  IF v_why IS NULL THEN
    -- A subtransaction: when the order can't be filled, everything it did
    -- (the order row, the organizer's "action needed" alert and mail, the
    -- counters) is rolled back, so a rejection leaves no trace but its log row.
    BEGIN
      INSERT INTO public.exos_marketplace_orders (
        channel, external_order_id, event_id, org_id, tier_id, quantity, buyer_email,
        proceeds, list_unit_price, currency, sale_status, sold_at, raw)
      VALUES ('s4k', v_ref, e.id, e.org_id, p_tier_id, p_quantity, v_email,
              round(p_unit_price * p_quantity, 2), p_unit_price, l.currency, 'confirmed', now(),
              jsonb_build_object('consumer_id', v_cons, 'marketplace', v_mkt))
      RETURNING * INTO o;
      SELECT * INTO f FROM public.exos_fulfil_marketplace_order(o.id, p_app_base);
      IF f.status IS DISTINCT FROM 'fulfilled' THEN
        v_why := CASE WHEN f.reason LIKE 'oversold%' THEN 'sold_out' ELSE 'not_fillable: ' || coalesce(f.reason, f.status) END;
        RAISE EXCEPTION 'exos_feed_place_order: rejected' USING ERRCODE = 'P0S4K';
      END IF;
      PERFORM public.exos_feed_refresh(p_event_id);
      RETURN jsonb_build_object('result', 'created', 'order_id', o.id, 'status', 'fulfilled',
                                'transfer_ids', to_jsonb(f.transfer_ids));
    EXCEPTION WHEN SQLSTATE 'P0S4K' THEN
      NULL;   -- v_why is set; the rejection is logged below
    END;
    SELECT x.free_now INTO v_avail FROM public._exos_feed_lines(p_event_id) x WHERE x.tier_id = p_tier_id;
  END IF;

  INSERT INTO public.exos_feed_rejections (consumer_id, event_id, tier_id, quantity, available, reason, external_ref, marketplace)
  VALUES (v_cons, e.id, p_tier_id, p_quantity, v_avail, left(v_why, 300), v_ref, v_mkt);
  PERFORM public.exos_feed_refresh(p_event_id) WHERE e.id IS NOT NULL;
  RETURN jsonb_build_object('result', 'rejected', 'reason', v_why, 'available', coalesce(v_avail, 0),
                            'price', l.price);
END $$;
REVOKE ALL ON FUNCTION public.exos_feed_place_order(text, uuid, uuid, integer, text, text, numeric, text, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_feed_place_order(text, uuid, uuid, integer, text, text, numeric, text, text) TO service_role;

-- The claim links of an order this consumer placed (transfer id + key + internal seat).
CREATE OR REPLACE FUNCTION public.exos_feed_order_tickets(p_token_hash text, p_order_id uuid)
RETURNS TABLE (transfer_id uuid, claim_key text, internal_seat integer, ticket_status text)
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE v_cons uuid := public._exos_feed_consumer(p_token_hash);
BEGIN
  IF v_cons IS NULL THEN RETURN; END IF;
  RETURN QUERY
    SELECT x.id, x.claim_key, t.internal_seat, t.status
      FROM public.exos_marketplace_orders o
      JOIN public.exos_tickets t ON t.id = ANY (o.ticket_ids)
      LEFT JOIN public.exos_transfers x ON x.ticket_id = t.id AND x.id = ANY (o.transfer_ids)
     WHERE o.id = p_order_id AND o.channel = 's4k' AND o.raw ->> 'consumer_id' = v_cons::text
     ORDER BY t.internal_seat NULLS LAST, t.id;
END $$;
REVOKE ALL ON FUNCTION public.exos_feed_order_tickets(text, uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_feed_order_tickets(text, uuid) TO service_role;

-- One order this consumer placed: status and when it changed.
CREATE OR REPLACE FUNCTION public.exos_feed_order_status(p_token_hash text, p_order_id uuid)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE v_cons uuid := public._exos_feed_consumer(p_token_hash); o public.exos_marketplace_orders%ROWTYPE;
BEGIN
  IF v_cons IS NULL THEN RETURN jsonb_build_object('result', 'unauthorized'); END IF;
  SELECT * INTO o FROM public.exos_marketplace_orders
   WHERE id = p_order_id AND channel = 's4k' AND raw ->> 'consumer_id' = v_cons::text;
  IF o.id IS NULL THEN RETURN jsonb_build_object('result', 'not_found'); END IF;
  RETURN jsonb_build_object('result', 'existing', 'order_id', o.id, 'status', o.status,
                            'reason', o.attention_reason, 'external_ref', o.external_order_id,
                            'event_id', o.event_id, 'ticket_id', o.tier_id, 'quantity', o.quantity,
                            'updated_at', o.updated_at);
END $$;
REVOKE ALL ON FUNCTION public.exos_feed_order_status(text, uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_feed_order_status(text, uuid) TO service_role;

-- S4K cancels an order (the marketplace cancelled its sale) before doors:
-- tickets voided, seats back into the shared count. Refused once a ticket
-- was scanned or doors opened.
CREATE OR REPLACE FUNCTION public.exos_feed_cancel_order(p_token_hash text, p_order_id uuid)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_cons uuid := public._exos_feed_consumer(p_token_hash);
  o      public.exos_marketplace_orders%ROWTYPE;
  e      public.exos_events%ROWTYPE;
  v_n    int;
BEGIN
  IF v_cons IS NULL THEN RETURN jsonb_build_object('result', 'unauthorized'); END IF;
  SELECT * INTO o FROM public.exos_marketplace_orders
   WHERE id = p_order_id AND channel = 's4k' AND raw ->> 'consumer_id' = v_cons::text FOR UPDATE;
  IF o.id IS NULL THEN RETURN jsonb_build_object('result', 'not_found'); END IF;
  IF o.status = 'cancelled' THEN RETURN jsonb_build_object('result', 'cancelled', 'order_id', o.id); END IF;
  -- Lock order as the mint: event, then tier.
  SELECT * INTO e FROM public.exos_events WHERE id = o.event_id FOR UPDATE;
  IF coalesce(e.doors_at, e.starts_at) <= now() THEN
    RETURN jsonb_build_object('result', 'refused', 'reason', 'doors_open');
  END IF;
  IF EXISTS (SELECT 1 FROM public.exos_tickets t WHERE t.id = ANY (o.ticket_ids) AND t.status = 'used') THEN
    RETURN jsonb_build_object('result', 'refused', 'reason', 'ticket_scanned');
  END IF;
  PERFORM 1 FROM public.exos_ticket_tiers WHERE id = o.tier_id FOR UPDATE;

  UPDATE public.exos_transfers x SET status = 'cancelled', updated_at = now()
   WHERE x.ticket_id = ANY (o.ticket_ids) AND x.status = 'pending';
  UPDATE public.exos_tickets t
     SET status = 'voided', voided_at = now(), pending_transfer_id = NULL,
         voided_reason = left('cancelled by S4K: order ' || o.external_order_id, 500)
   WHERE t.id = ANY (o.ticket_ids) AND t.status = 'active';
  GET DIAGNOSTICS v_n = ROW_COUNT;
  UPDATE public.exos_ticket_tiers SET sold = greatest(0, sold - v_n) WHERE id = o.tier_id;
  UPDATE public.exos_events SET tickets_sold = greatest(0, tickets_sold - v_n) WHERE id = o.event_id;
  UPDATE public.exos_marketplace_orders
     SET status = 'cancelled', sale_status = 'cancelled', attention_reason = NULL, updated_at = now()
   WHERE id = o.id;
  PERFORM public.exos_feed_refresh(o.event_id);
  RETURN jsonb_build_object('result', 'cancelled', 'order_id', o.id, 'released', v_n);
END $$;
REVOKE ALL ON FUNCTION public.exos_feed_cancel_order(text, uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_feed_cancel_order(text, uuid) TO service_role;

-- ---------------------------------------------------------------------------
-- Webhook (secondary to polling): one coalesced, signed POST per consumer
-- listing the events whose feed state moved since its cursor. The edge
-- function claims, sends, then acks; a failed send keeps the cursor, so the
-- next run re-sends (retry with backoff, capped at 30 minutes).
DROP FUNCTION IF EXISTS public.exos_feed_webhook_due(integer);
CREATE OR REPLACE FUNCTION public.exos_feed_webhook_due(p_limit integer DEFAULT 500)
RETURNS TABLE (consumer_id uuid, url text, secret text, cursor_to timestamptz, cursor_id uuid, events jsonb)
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE c record; v_ev jsonb; v_to timestamptz; v_id uuid;
BEGIN
  FOR c IN SELECT * FROM public.exos_feed_consumers
            WHERE revoked_at IS NULL AND webhook_url IS NOT NULL
              AND (webhook_next_at IS NULL OR webhook_next_at <= now())
  LOOP
    -- Keyset on (updated_at, event_id), 15 s behind the clock (see refresh).
    SELECT jsonb_agg(jsonb_build_object('event_id', d.event_id, 'status', d.status, 'available', d.available,
                                        'updated_at', d.updated_at) ORDER BY d.updated_at, d.event_id),
           (array_agg(d.updated_at ORDER BY d.updated_at DESC, d.event_id DESC))[1],
           (array_agg(d.event_id ORDER BY d.updated_at DESC, d.event_id DESC))[1]
      INTO v_ev, v_to, v_id
      FROM (SELECT f.updated_at, f.event_id, f.status, f.available FROM public.exos_feed_events f
             WHERE f.updated_at <= clock_timestamp() - interval '15 seconds'
               AND (c.webhook_cursor IS NULL
                    OR (f.updated_at, f.event_id) > (c.webhook_cursor, coalesce(c.webhook_cursor_id, '00000000-0000-0000-0000-000000000000'::uuid)))
             ORDER BY f.updated_at, f.event_id
             LIMIT least(greatest(coalesce(p_limit, 500), 1), 1000)) d;
    IF v_id IS NOT NULL THEN
      consumer_id := c.id; url := c.webhook_url; secret := c.webhook_secret;
      cursor_to := v_to; cursor_id := v_id; events := v_ev;
      RETURN NEXT;
    END IF;
  END LOOP;
END $$;
REVOKE ALL ON FUNCTION public.exos_feed_webhook_due(integer) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_feed_webhook_due(integer) TO service_role;

DROP FUNCTION IF EXISTS public.exos_feed_webhook_ack(uuid, timestamptz, boolean, text);
CREATE OR REPLACE FUNCTION public.exos_feed_webhook_ack(p_consumer_id uuid, p_cursor_to timestamptz, p_cursor_id uuid,
                                                        p_ok boolean, p_error text DEFAULT NULL)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF p_ok THEN
    -- The cursor only moves forward (a late ack of an older batch can't rewind it).
    UPDATE public.exos_feed_consumers c
       SET webhook_cursor    = CASE WHEN adv THEN p_cursor_to ELSE c.webhook_cursor END,
           webhook_cursor_id = CASE WHEN adv THEN p_cursor_id ELSE c.webhook_cursor_id END,
           webhook_failures = 0, webhook_next_at = NULL, webhook_last_ok_at = now(), webhook_last_error = NULL
      FROM (SELECT x.webhook_cursor IS NULL
                   OR (p_cursor_to, p_cursor_id) > (x.webhook_cursor, coalesce(x.webhook_cursor_id, '00000000-0000-0000-0000-000000000000'::uuid)) AS adv
              FROM public.exos_feed_consumers x WHERE x.id = p_consumer_id) a
     WHERE c.id = p_consumer_id;
  ELSE
    UPDATE public.exos_feed_consumers
       SET webhook_failures = webhook_failures + 1,
           webhook_next_at = now() + least(interval '30 minutes', interval '1 minute' * power(2, least(webhook_failures, 5))),
           webhook_last_error = left(coalesce(p_error, 'failed'), 300)
     WHERE id = p_consumer_id;
  END IF;
END $$;
REVOKE ALL ON FUNCTION public.exos_feed_webhook_ack(uuid, timestamptz, uuid, boolean, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_feed_webhook_ack(uuid, timestamptz, uuid, boolean, text) TO service_role;

-- ---------------------------------------------------------------------------
-- Operator: mint a consumer token (returned once; only its hash is stored).
CREATE OR REPLACE FUNCTION public.exos_feed_create_consumer(p_name text, p_delivery_email text DEFAULT NULL,
                                                            p_webhook_url text DEFAULT NULL)
RETURNS TABLE (consumer_id uuid, token text, webhook_secret text)
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, extensions, pg_temp
AS $$
DECLARE v_tok text := 'exf_' || encode(extensions.gen_random_bytes(30), 'hex');
BEGIN
  INSERT INTO public.exos_feed_consumers (name, token_hash, token_prefix, delivery_email, webhook_url)
  VALUES (btrim(p_name), encode(extensions.digest(v_tok, 'sha256'), 'hex'), left(v_tok, 10),
          lower(nullif(btrim(coalesce(p_delivery_email, '')), '')), nullif(btrim(coalesce(p_webhook_url, '')), ''))
  RETURNING id, exos_feed_consumers.webhook_secret INTO consumer_id, webhook_secret;
  token := v_tok;
  RETURN NEXT;
END $$;
REVOKE ALL ON FUNCTION public.exos_feed_create_consumer(text, text, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_feed_create_consumer(text, text, text) TO service_role;

-- ---------------------------------------------------------------------------
-- Organizer switches.
CREATE OR REPLACE FUNCTION public.exos_set_s4k_network(p_org_id uuid, p_on boolean)
RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF NOT public.exos_has_org_role(p_org_id, ARRAY['owner']) THEN
    RAISE EXCEPTION 'only the organization owner can join or leave the S4K network' USING ERRCODE = '42501';
  END IF;
  PERFORM set_config('exos.s4k_switch', '1', true);
  UPDATE public.exos_orgs SET s4k_network = coalesce(p_on, false), updated_at = now() WHERE id = p_org_id;
  IF NOT coalesce(p_on, false) THEN
    UPDATE public.exos_events SET distribution_route = 'direct' WHERE org_id = p_org_id AND distribution_route = 's4k';
  END IF;
  PERFORM set_config('exos.s4k_switch', '', true);
  RETURN coalesce(p_on, false);
END $$;
REVOKE ALL ON FUNCTION public.exos_set_s4k_network(uuid, boolean) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.exos_set_s4k_network(uuid, boolean) TO authenticated;

-- The two switches change only through the RPCs above and below (a direct
-- table update by a signed-in user would skip their checks).
CREATE OR REPLACE FUNCTION public.exos_tg_s4k_switch_guard()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF auth.uid() IS NOT NULL AND current_setting('exos.s4k_switch', true) IS DISTINCT FROM '1' THEN
    -- Separate IFs: PL/pgSQL resolves every NEW field in an expression.
    IF TG_OP = 'INSERT' THEN
      -- A new row starts off the network; the RPCs switch it on.
      IF TG_TABLE_NAME = 'exos_orgs' THEN
        NEW.s4k_network := false;
      ELSE
        NEW.distribution_route := 'direct';
      END IF;
    ELSIF TG_TABLE_NAME = 'exos_orgs' THEN
      IF NEW.s4k_network IS DISTINCT FROM OLD.s4k_network THEN
        RAISE EXCEPTION 'use exos_set_s4k_network' USING ERRCODE = '42501';
      END IF;
    ELSIF NEW.distribution_route IS DISTINCT FROM OLD.distribution_route THEN
      RAISE EXCEPTION 'use exos_set_distribution_route' USING ERRCODE = '42501';
    END IF;
  END IF;
  RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION public.exos_tg_s4k_switch_guard() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS exos_orgs_s4k_guard ON public.exos_orgs;
CREATE TRIGGER exos_orgs_s4k_guard BEFORE INSERT OR UPDATE OF s4k_network ON public.exos_orgs
  FOR EACH ROW EXECUTE FUNCTION public.exos_tg_s4k_switch_guard();
DROP TRIGGER IF EXISTS exos_events_s4k_guard ON public.exos_events;
CREATE TRIGGER exos_events_s4k_guard BEFORE INSERT OR UPDATE OF distribution_route ON public.exos_events
  FOR EACH ROW EXECUTE FUNCTION public.exos_tg_s4k_switch_guard();

-- An event goes to S4K only from an opted-in org and with nothing listed
-- directly (one route at a time, or a seat could sell twice).
CREATE OR REPLACE FUNCTION public.exos_set_distribution_route(p_event_id uuid, p_route text)
RETURNS text
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE e public.exos_events%ROWTYPE; v_on boolean;
BEGIN
  PERFORM pg_advisory_xact_lock(hashtextextended('exos_route:' || p_event_id::text, 0));
  SELECT * INTO e FROM public.exos_events WHERE id = p_event_id FOR UPDATE;
  IF e.id IS NULL OR NOT public.exos_has_org_role(e.org_id, ARRAY['owner','manager']) THEN
    RAISE EXCEPTION 'not allowed' USING ERRCODE = '42501';
  END IF;
  IF p_route NOT IN ('direct','s4k') THEN
    RAISE EXCEPTION 'route must be direct or s4k' USING ERRCODE = '22023';
  END IF;
  IF p_route = 's4k' THEN
    SELECT s4k_network INTO v_on FROM public.exos_orgs WHERE id = e.org_id;
    IF NOT coalesce(v_on, false) THEN
      RAISE EXCEPTION 'join the S4K network first (organization settings)' USING ERRCODE = '22023';
    END IF;
    IF EXISTS (SELECT 1 FROM public.exos_distribution_listings d WHERE d.event_id = p_event_id
                AND d.status IN ('pending','planned','listing','listed','delisting')
                AND coalesce(d.requested_qty, 0) + coalesce(d.list_qty, 0) > 0) THEN
      RAISE EXCEPTION 'this event still has marketplace listings: set every marketplace to 0 first' USING ERRCODE = '22023';
    END IF;
  END IF;
  PERFORM set_config('exos.s4k_switch', '1', true);
  UPDATE public.exos_events SET distribution_route = p_route WHERE id = p_event_id;
  PERFORM set_config('exos.s4k_switch', '', true);
  RETURN p_route;
END $$;
REVOKE ALL ON FUNCTION public.exos_set_distribution_route(uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.exos_set_distribution_route(uuid, text) TO authenticated;

-- ---------------------------------------------------------------------------
-- The fulfil mail names S4K properly.
CREATE OR REPLACE FUNCTION pg_temp.exos_patch(p_fn regprocedure, p_marker text, p_old text, p_new text)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE v_def text; v_hits int;
BEGIN
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

SELECT pg_temp.exos_patch('public.exos_fulfil_marketplace_order(uuid, text)',
  'WHEN ''s4k'' THEN ''S4K''',
  'WHEN ''evo'' THEN ''Ticket Evolution'' ELSE initcap(o.channel) END',
  'WHEN ''evo'' THEN ''Ticket Evolution'' WHEN ''s4k'' THEN ''S4K'' ELSE initcap(o.channel) END');

-- The organizer-facing label (alerts, payouts).
SELECT pg_temp.exos_patch('public.exos_channel_label(text)',
  'WHEN ''s4k'' THEN ''S4K''',
  'WHEN ''automatiq'' THEN ''Automatiq'' ELSE',
  'WHEN ''automatiq'' THEN ''Automatiq'' WHEN ''s4k'' THEN ''S4K'' ELSE');

-- One route at a time: an S4K event gets no direct marketplace allocation,
-- by hand or from the auto split.
SELECT pg_temp.exos_patch('public.exos_set_channel_allocation(uuid, text, uuid, integer)',
  'is on the S4K network',
  E'  IF v_ev.status = ''cancelled'' AND p_qty > 0 THEN',
  E'  IF v_ev.distribution_route = ''s4k'' AND p_qty > 0 THEN\n' ||
  E'    RAISE EXCEPTION ''exos_set_channel_allocation: this event is on the S4K network (S4K lists it): switch it to direct first'';\n' ||
  E'  END IF;\n' ||
  E'  IF v_ev.status = ''cancelled'' AND p_qty > 0 THEN');
-- Route changes and allocations for one event take the same advisory lock
-- first, so a switch to s4k and a new direct allocation can't both pass their
-- checks (neither may lock the event row: see exos_apply_channel_split).
SELECT pg_temp.exos_patch('public.exos_set_channel_allocation(uuid, text, uuid, integer)',
  'exos_route:',
  E'  SELECT * INTO v_ev FROM public.exos_events WHERE id = p_event_id;',
  E'  PERFORM pg_advisory_xact_lock(hashtextextended(''exos_route:'' || p_event_id::text, 0));\n' ||
  E'  SELECT * INTO v_ev FROM public.exos_events WHERE id = p_event_id;');
SELECT pg_temp.exos_patch('public.exos_apply_channel_split(uuid)',
  'exos_route:',
  E'  SELECT * INTO e FROM public.exos_events WHERE id = p_event_id;\n  IF e.id IS NULL THEN\n    RETURN jsonb_build_object(''applied'', false, ''reason'', ''not-found'');',
  E'  PERFORM pg_advisory_xact_lock(hashtextextended(''exos_route:'' || p_event_id::text, 0));\n' ||
  E'  SELECT * INTO e FROM public.exos_events WHERE id = p_event_id;\n  IF e.id IS NULL THEN\n    RETURN jsonb_build_object(''applied'', false, ''reason'', ''not-found'');');
SELECT pg_temp.exos_patch('public.exos_apply_channel_split(uuid)',
  'S4K lists it (apply)',
  E'  IF e.channel_split_mode <> ''auto'' THEN',
  E'  IF e.distribution_route = ''s4k'' THEN   -- S4K lists it (apply)\n' ||
  E'    RETURN jsonb_build_object(''applied'', false, ''reason'', ''s4k'');\n' ||
  E'  END IF;\n' ||
  E'  IF e.channel_split_mode <> ''auto'' THEN');
SELECT pg_temp.exos_patch('public._exos_channel_split_plan(uuid)',
  'S4K lists it',
  E'  IF e.id IS NULL THEN\n    RETURN;\n  END IF;',
  E'  IF e.id IS NULL OR e.distribution_route = ''s4k'' THEN   -- S4K lists it\n    RETURN;\n  END IF;');

-- ---------------------------------------------------------------------------
-- Every minute: refresh the feed state and send the webhook. Guarded so CI
-- Postgres without pg_cron applies. Deploy exos-s4k-feed first; prod
-- scheduling needs operator OK.
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron')
     AND to_regprocedure('public._cron_invoke_edge_fn(text, jsonb)') IS NOT NULL THEN
    IF EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'exos-s4k-feed-1min') THEN
      PERFORM cron.unschedule('exos-s4k-feed-1min');
    END IF;
    PERFORM cron.schedule('exos-s4k-feed-1min', '* * * * *', $cron$
      SELECT public._cron_invoke_edge_fn(
        'https://hzrizjeaxlqcxfrtczpq.supabase.co/functions/v1/exos-s4k-feed/cron', '{}'::jsonb);
    $cron$);
  END IF;
END $$;
