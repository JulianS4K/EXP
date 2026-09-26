-- ============================================================================
-- Migration 20260926192000 — Exos (Bridge / D4): marketplace sales become
--                            Exos tickets
--
-- Lane:     d4 (exos / bridge ticketing infra)
-- Touches:  W: exos_marketplace_orders (new)
--              exos_distribution_listings (+tier_id; requested_qty decremented on a sale)
--              exos_tickets, exos_transfers, exos_ticket_tiers.sold, exos_events.tickets_sold,
--                exos_mail ('transfer-initiated' to the buyer) (via exos_fulfil_marketplace_order)
--              exos_marketplace_credentials (new, service_role only)
--              FUNCTION exos_record_marketplace_order, exos_fulfil_marketplace_order (new,
--                service_role only)
--           R: exos_orgs.owner_uid, exos_seats_available (quotas / holds / offers)
-- Pre-reqs: 20260926191000 (links), 20260924210103 (exos_seats_available),
--           20260523190000 (exos_distribution_listings)
--
-- A StubHub sale (webhook / recent updates) comes in through
-- exos-marketplace-sales (StubHub only for now; the table is keyed by channel):
--
--   1. exos_record_marketplace_order(sale jsonb): stores it ONLY if it sold
--      from an Exos listing, matched by the listing id (StubHub external_id =
--      our exos_distribution_listings.id, or the marketplace's listing id we
--      recorded). The same seller accounts also carry broker inventory, so an
--      event match alone is never enough. Idempotent per (channel, order id).
--   2. exos_fulfil_marketplace_order(order, app_base): mints the tickets and
--      parks them on the org owner with a pending claim-by-email transfer to
--      the buyer, the same claim flow comps and transfers use (claiming
--      rotates the barcode secret, so nothing handed to the marketplace scans
--      until the buyer claims it). The tickets reach the buyer two ways:
--        * as an Exos transfer: it shows under their tickets when they sign
--          in with that email, and they're emailed ('transfer-initiated')
--          with one claim link per ticket;
--        * through the marketplace: the same links, handed over by step 3. Capacity is claimed like every other mint (house cap,
--      then tier + exos_seats_available), so a marketplace sale takes the seat
--      from Exos's own storefront and every other channel. If the seat isn't
--      there (oversold), or there's no buyer email / tier / owner, the order
--      goes to 'needs_attention' with the reason instead. Idempotent.
--   3. The edge function plans the marketplace's delivery call with those
--      links (StubHub PATCH /sales/{id}), dry-run.
--
-- A cancellation after tickets were issued isn't undone automatically: the
-- order goes to 'needs_attention' so a human voids the tickets.
--
-- Re-run safe. D4 authors; applying to prod is operator-gated.
-- ============================================================================

-- Which tier a listing sells (sales mint from it).
ALTER TABLE public.exos_distribution_listings
  ADD COLUMN IF NOT EXISTS tier_id uuid REFERENCES public.exos_ticket_tiers (id) ON DELETE SET NULL;

CREATE TABLE IF NOT EXISTS public.exos_marketplace_orders (
  id                      uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  channel                 text NOT NULL CHECK (channel IN ('stubhub','seatgeek','vivid','tickpick','evo','automatiq')),
  external_order_id       text NOT NULL,
  external_event_id       text,
  external_listing_id     text,
  distribution_listing_id uuid REFERENCES public.exos_distribution_listings (id) ON DELETE SET NULL,
  event_id                uuid NOT NULL REFERENCES public.exos_events (id) ON DELETE CASCADE,
  org_id                  uuid NOT NULL REFERENCES public.exos_orgs (id) ON DELETE CASCADE,
  tier_id                 uuid,
  quantity                integer NOT NULL CHECK (quantity > 0 AND quantity <= 100),
  buyer_email             text,
  proceeds                numeric CHECK (proceeds IS NULL OR proceeds >= 0),
  currency                text,
  sale_status             text NOT NULL DEFAULT 'unknown'
                            CHECK (sale_status IN ('pending','confirmed','delivered','cancelled','unknown')),
  status                  text NOT NULL DEFAULT 'received'
                            CHECK (status IN ('received','needs_attention','fulfilled','delivered','cancelled')),
  attention_reason        text,
  ticket_ids              uuid[] NOT NULL DEFAULT '{}',
  transfer_ids            uuid[] NOT NULL DEFAULT '{}',
  delivery_plan           jsonb,     -- dry-run: the marketplace call that would deliver the claim links
  confirm_by              timestamptz,
  ship_by                 timestamptz,
  sold_at                 timestamptz,
  raw                     jsonb,
  created_at              timestamptz NOT NULL DEFAULT now(),
  updated_at              timestamptz NOT NULL DEFAULT now(),
  UNIQUE (channel, external_order_id)
);
CREATE INDEX IF NOT EXISTS exos_marketplace_orders_event_idx  ON public.exos_marketplace_orders (event_id);
CREATE INDEX IF NOT EXISTS exos_marketplace_orders_status_idx ON public.exos_marketplace_orders (status);

ALTER TABLE public.exos_marketplace_orders ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS exos_marketplace_orders_sel ON public.exos_marketplace_orders;
CREATE POLICY exos_marketplace_orders_sel ON public.exos_marketplace_orders FOR SELECT TO authenticated
  USING (exos_has_org_role(org_id, ARRAY['owner','manager','finance']));
REVOKE ALL ON public.exos_marketplace_orders FROM anon, authenticated;
GRANT  SELECT ON public.exos_marketplace_orders TO authenticated;

-- Platform-level marketplace credentials that rotate (StubHub refresh tokens
-- are single-use, so each refresh stores the new one). Service role only: no
-- grants, RLS on with no policy. Env secrets bootstrap the first value.
CREATE TABLE IF NOT EXISTS public.exos_marketplace_credentials (
  channel       text PRIMARY KEY CHECK (channel IN ('stubhub','seatgeek','vivid','tickpick','evo','automatiq')),
  refresh_token text,
  updated_at    timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.exos_marketplace_credentials ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.exos_marketplace_credentials FROM anon, authenticated;

-- ---------------------------------------------------------------------------
-- 1. Record (service_role). Returns nothing when the sale isn't on an Exos listing.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.exos_record_marketplace_order(p_sale jsonb)
RETURNS TABLE (order_id uuid, status text)
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_channel text := p_sale ->> 'channel';
  v_order   text := nullif(btrim(coalesce(p_sale ->> 'external_order_id', '')), '');
  v_listing text := nullif(btrim(coalesce(p_sale ->> 'external_listing_id', '')), '');
  v_sale    text := coalesce(p_sale ->> 'sale_status', 'unknown');
  v_qty     int;
  v_email   text := lower(nullif(btrim(coalesce(p_sale ->> 'buyer_email', '')), ''));
  d         public.exos_distribution_listings%ROWTYPE;
  o         public.exos_marketplace_orders%ROWTYPE;
BEGIN
  IF v_order IS NULL OR v_listing IS NULL THEN
    RETURN;
  END IF;
  IF v_sale NOT IN ('pending','confirmed','delivered','cancelled','unknown') THEN
    v_sale := 'unknown';
  END IF;
  IF v_email IS NOT NULL AND (length(v_email) > 320 OR v_email !~ '^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$') THEN
    v_email := NULL;
  END IF;
  BEGIN
    v_qty := (p_sale ->> 'quantity')::int;
  EXCEPTION WHEN others THEN
    v_qty := NULL;
  END;
  IF v_qty IS NULL OR v_qty < 1 OR v_qty > 100 THEN
    RETURN;
  END IF;

  -- Exos listings only: external_id = our row id, or the marketplace's listing id we stored.
  SELECT * INTO d FROM public.exos_distribution_listings dl
   WHERE dl.channel = v_channel
     AND (dl.id::text = v_listing OR dl.external_listing_id = v_listing)
   LIMIT 1;
  IF d.id IS NULL THEN
    RETURN;
  END IF;

  INSERT INTO public.exos_marketplace_orders AS m (
    channel, external_order_id, external_event_id, external_listing_id, distribution_listing_id,
    event_id, org_id, tier_id, quantity, buyer_email, proceeds, currency, sale_status,
    confirm_by, ship_by, sold_at, raw
  ) VALUES (
    v_channel, v_order, p_sale ->> 'external_event_id', v_listing, d.id,
    d.event_id, d.org_id, d.tier_id, v_qty, v_email,
    CASE WHEN (p_sale ->> 'proceeds') ~ '^[0-9]+(\.[0-9]+)?$' THEN (p_sale ->> 'proceeds')::numeric END,
    upper(nullif(p_sale ->> 'currency', '')), v_sale,
    CASE WHEN p_sale ? 'confirm_by' THEN (p_sale ->> 'confirm_by')::timestamptz END,
    CASE WHEN p_sale ? 'ship_by'    THEN (p_sale ->> 'ship_by')::timestamptz END,
    CASE WHEN p_sale ? 'sold_at'    THEN (p_sale ->> 'sold_at')::timestamptz END,
    p_sale -> 'raw'
  )
  ON CONFLICT (channel, external_order_id) DO UPDATE
    SET sale_status = EXCLUDED.sale_status,
        buyer_email = coalesce(m.buyer_email, EXCLUDED.buyer_email),
        confirm_by  = coalesce(EXCLUDED.confirm_by, m.confirm_by),
        ship_by     = coalesce(EXCLUDED.ship_by, m.ship_by),
        raw         = coalesce(EXCLUDED.raw, m.raw),
        updated_at  = now()
  RETURNING * INTO o;

  -- The marketplace cancelled it.
  IF v_sale = 'cancelled' THEN
    IF o.status IN ('received','needs_attention') AND cardinality(o.ticket_ids) = 0 THEN
      UPDATE public.exos_marketplace_orders SET status = 'cancelled', attention_reason = NULL, updated_at = now()
       WHERE id = o.id RETURNING * INTO o;
    ELSIF o.status IN ('fulfilled','delivered') THEN
      UPDATE public.exos_marketplace_orders
         SET status = 'needs_attention',
             attention_reason = 'cancelled on the marketplace after tickets were issued: void them',
             updated_at = now()
       WHERE id = o.id RETURNING * INTO o;
    END IF;
  END IF;

  order_id := o.id; status := o.status;
  RETURN NEXT;
END $$;
REVOKE ALL ON FUNCTION public.exos_record_marketplace_order(jsonb) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.exos_record_marketplace_order(jsonb) TO service_role;

-- ---------------------------------------------------------------------------
-- 2. Fulfil (service_role): mint + claim-by-email transfer per ticket.
-- ---------------------------------------------------------------------------
-- p_app_base: the public SPA base URL (https, path included, e.g.
-- https://host/bridge) for the claim links in the buyer's email; without it
-- the email says to sign in instead.
DROP FUNCTION IF EXISTS public.exos_fulfil_marketplace_order(uuid);
CREATE OR REPLACE FUNCTION public.exos_fulfil_marketplace_order(p_order_id uuid, p_app_base text DEFAULT NULL)
RETURNS TABLE (status text, transfer_ids uuid[], reason text)
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  o         public.exos_marketplace_orders%ROWTYPE;
  v_ev      public.exos_events%ROWTYPE;
  v_owner   uuid;
  v_tier    text;
  v_tier_ev uuid;
  v_price   numeric := 0;
  v_ref     text;
  v_ids     uuid[] := '{}';
  v_trs     uuid[] := '{}';
  v_id      uuid;
  v_tr      uuid;
  v_n       int;
  v_why     text;
  v_label   text;
  v_safe    text;
  v_base    text;
  v_links   text := '';
  i         int;
BEGIN
  SELECT * INTO o FROM public.exos_marketplace_orders WHERE id = p_order_id FOR UPDATE;
  IF o.id IS NULL THEN
    RAISE EXCEPTION 'exos_fulfil_marketplace_order: order not found';
  END IF;
  IF o.status <> 'received' THEN
    status := o.status; transfer_ids := o.transfer_ids; reason := o.attention_reason;
    RETURN NEXT; RETURN;
  END IF;

  SELECT * INTO v_ev FROM public.exos_events WHERE id = o.event_id;
  SELECT owner_uid INTO v_owner FROM public.exos_orgs WHERE id = o.org_id;
  IF o.tier_id IS NOT NULL THEN
    SELECT name, event_id INTO v_tier, v_tier_ev FROM public.exos_ticket_tiers WHERE id = o.tier_id;
  END IF;

  v_why := CASE
    WHEN o.sale_status = 'cancelled' THEN NULL
    WHEN o.sale_status NOT IN ('pending','confirmed') THEN 'marketplace status is ' || o.sale_status || ': check the sale'
    WHEN v_ev.status IS DISTINCT FROM 'published' THEN 'event is ' || coalesce(v_ev.status, 'missing')
    WHEN o.tier_id IS NULL OR v_tier_ev IS DISTINCT FROM o.event_id THEN 'the listing has no ticket type: set one, then retry'
    WHEN o.buyer_email IS NULL THEN 'no buyer email from the marketplace: deliver by hand'
    WHEN v_owner IS NULL THEN 'the organization has no owner to hold the tickets'
  END;
  IF o.sale_status = 'cancelled' THEN
    UPDATE public.exos_marketplace_orders SET status = 'cancelled', updated_at = now() WHERE id = o.id;
    status := 'cancelled'; transfer_ids := '{}'; reason := NULL;
    RETURN NEXT; RETURN;
  END IF;

  IF v_why IS NULL THEN
    -- House cap first (trigger-free counter, safe to undo), then the tier with
    -- quotas / holds / offers, as every other mint.
    UPDATE public.exos_events
       SET tickets_sold = tickets_sold + o.quantity
     WHERE id = o.event_id
       AND (total_tickets = 0 OR tickets_sold + o.quantity <= total_tickets);
    GET DIAGNOSTICS v_n = ROW_COUNT;
    IF v_n = 0 THEN
      v_why := 'oversold: the event is at capacity';
    ELSE
      UPDATE public.exos_ticket_tiers
         SET sold = sold + o.quantity
       WHERE id = o.tier_id
         AND (capacity = 0 OR sold + o.quantity <= capacity)
         AND public.exos_seats_available(o.tier_id, o.quantity);
      GET DIAGNOSTICS v_n = ROW_COUNT;
      IF v_n = 0 THEN
        UPDATE public.exos_events SET tickets_sold = greatest(tickets_sold - o.quantity, 0) WHERE id = o.event_id;
        v_why := 'oversold: ' || coalesce(v_tier, 'the ticket type') || ' has no seats left';
      END IF;
    END IF;
  END IF;

  IF v_why IS NOT NULL THEN
    UPDATE public.exos_marketplace_orders
       SET status = 'needs_attention', attention_reason = v_why, updated_at = now()
     WHERE id = o.id;
    status := 'needs_attention'; transfer_ids := '{}'; reason := v_why;
    RETURN NEXT; RETURN;
  END IF;

  IF o.proceeds IS NOT NULL THEN
    v_price := round(o.proceeds / o.quantity, 2);
  END IF;
  v_ref := o.channel || ':' || o.external_order_id;
  FOR i IN 1..o.quantity LOOP
    INSERT INTO public.exos_tickets (
      event_id, org_id, tier_id, tier_name, buyer_id, owner_id, buyer_email,
      status, barcode_secret, price_paid, order_ref, channel_source
    ) VALUES (
      o.event_id, o.org_id, o.tier_id, v_tier, v_owner, v_owner, o.buyer_email,
      'active', gen_random_uuid()::text, v_price, v_ref, o.channel
    ) RETURNING id INTO v_id;
    v_ids := array_append(v_ids, v_id);

    INSERT INTO public.exos_transfers
    SELECT * FROM jsonb_populate_record(NULL::public.exos_transfers, jsonb_build_object(
      'id', gen_random_uuid(), 'ticket_id', v_id, 'org_id', o.org_id,
      'sender_id', v_owner, 'receiver_email', o.buyer_email,
      'status', 'pending', 'event_id', o.event_id, 'event_title', v_ev.name,
      'event_image', v_ev.image_url, 'tier_name', v_tier, 'organizer_id', v_ev.created_by,
      -- jsonb_populate_record yields NULL (not DEFAULT) for absent keys.
      'created_at', now(), 'updated_at', now()))
    RETURNING id INTO v_tr;
    v_trs := array_append(v_trs, v_tr);
    UPDATE public.exos_tickets SET pending_transfer_id = v_tr, last_reissue_at = now() WHERE id = v_id;
  END LOOP;

  -- Issue them to the buyer as a transfer they're told about, not only as the
  -- links the marketplace passes on. Server-built body; names are escaped.
  v_label := CASE o.channel WHEN 'stubhub' THEN 'StubHub' ELSE initcap(o.channel) END;
  v_safe := replace(replace(replace(coalesce(v_ev.name, 'your event'), '&', '&amp;'), '<', '&lt;'), '>', '&gt;');
  IF p_app_base ~ '^https://[A-Za-z0-9.-]+(:[0-9]{1,5})?(/[A-Za-z0-9._~/-]*)?$' THEN
    v_base := rtrim(p_app_base, '/');
    FOR i IN 1..cardinality(v_trs) LOOP
      v_links := v_links || '<li><a href="' || v_base || '/claim/' || v_trs[i] || '">Claim ticket ' || i || '</a></li>';
    END LOOP;
    v_links := '<ul>' || v_links || '</ul>';
  END IF;
  INSERT INTO public.exos_mail (template, to_email, subject, html, created_by, status)
  VALUES ('transfer-initiated', o.buyer_email,
          left('Your ' || v_label || ' ticket' || CASE WHEN o.quantity > 1 THEN 's' ELSE '' END || ' for ' || v_safe, 200),
          '<p>Your ' || v_label || ' order ' ||
          replace(replace(replace(o.external_order_id, '&', '&amp;'), '<', '&lt;'), '>', '&gt;') ||
          ' is ' || o.quantity || ' ticket' || CASE WHEN o.quantity > 1 THEN 's' ELSE '' END ||
          ' for <strong>' || v_safe || '</strong>. ' ||
          CASE WHEN o.quantity > 1 THEN 'They have' ELSE 'It has' END ||
          ' been transferred to you on Exos. Sign in with ' || o.buyer_email || ' to claim ' ||
          CASE WHEN o.quantity > 1 THEN 'them' ELSE 'it' END ||
          ' and get your entry QR code.</p>' || v_links,
          v_owner, 'pending');

  -- The marketplace took these off its listing; keep our count in step.
  UPDATE public.exos_distribution_listings
     SET requested_qty = greatest(coalesce(requested_qty, 0) - o.quantity, 0), updated_at = now()
   WHERE id = o.distribution_listing_id AND requested_qty IS NOT NULL;

  UPDATE public.exos_marketplace_orders
     SET status = 'fulfilled', ticket_ids = v_ids, transfer_ids = v_trs, attention_reason = NULL, updated_at = now()
   WHERE id = o.id;
  status := 'fulfilled'; transfer_ids := v_trs; reason := NULL;
  RETURN NEXT;
END $$;
REVOKE ALL ON FUNCTION public.exos_fulfil_marketplace_order(uuid, text) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.exos_fulfil_marketplace_order(uuid, text) TO service_role;
