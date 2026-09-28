-- ============================================================================
-- Migration 20260929052000 — Exos (Bridge / D4): organizer price per
-- marketplace
--
-- Lane:     d4 (exos / bridge ticketing infra)
-- Touches:  W: exos_distribution_listings (price-floor trigger)
--           C: exos_tg_channel_price_floor(),
--              exos_set_channel_price(uuid, text, uuid, numeric)
-- Pre-reqs: 20260929051000, 20260926030000 (exos_rr_tier_price)
--
-- Allocation rows (one per marketplace x ticket type) never had unit_price
-- set, so every marketplace listing went out at the ticket type's price. The
-- Marketplaces grid now has an optional price per cell, saved here:
--
--   exos_set_channel_price(event, channel, tier, price)  owner/manager;
--     NULL (blank in the grid) = the ticket type's price. The allocation row
--     must exist (set seats first).
--
-- Marketplace listings must never undercut the Exos price: the price can't
-- be below what Exos charges for the ticket type now (exos_rr_tier_price:
-- the base price or the scheduled step in force). A trigger enforces it for every
-- writer, service role included; and planExosListings (exos-distribute)
-- lists at max(unit_price, the Exos price now), so a later price rise (or a
-- scheduled step) also lifts a lower marketplace price.
--
-- Re-run safe (CREATE OR REPLACE / DROP TRIGGER IF EXISTS). D4 authors;
-- applying to prod is operator-gated.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.exos_tg_channel_price_floor()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_price numeric;
BEGIN
  IF NEW.tier_id IS NULL OR NEW.unit_price IS NULL THEN
    RETURN NEW;
  END IF;
  -- What Exos charges for it now (scheduled price steps included).
  v_price := public.exos_rr_tier_price(NEW.tier_id);
  IF v_price IS NOT NULL AND NEW.unit_price < v_price THEN
    RAISE EXCEPTION 'exos_distribution_listings: a marketplace price (%) can''t be below the ticket type''s Exos price (%)',
      NEW.unit_price, v_price USING ERRCODE = '23514';
  END IF;
  RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION public.exos_tg_channel_price_floor() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS exos_distribution_listings_price_floor ON public.exos_distribution_listings;
CREATE TRIGGER exos_distribution_listings_price_floor
  BEFORE INSERT OR UPDATE OF unit_price, tier_id ON public.exos_distribution_listings
  FOR EACH ROW EXECUTE FUNCTION public.exos_tg_channel_price_floor();

CREATE OR REPLACE FUNCTION public.exos_set_channel_price(
  p_event_id uuid, p_channel text, p_tier_id uuid, p_unit_price numeric
) RETURNS numeric
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  v_org   uuid;
  v_tier  public.exos_ticket_tiers%ROWTYPE;
  v_id    uuid;
  v_price numeric := CASE WHEN p_unit_price IS NULL THEN NULL ELSE round(p_unit_price, 2) END;
  v_exos  numeric;
BEGIN
  SELECT org_id INTO v_org FROM public.exos_events WHERE id = p_event_id;
  IF v_org IS NULL THEN
    RAISE EXCEPTION 'exos_set_channel_price: event not found';
  END IF;
  -- A signed-in user must be org owner/manager; no uid = service role.
  IF auth.uid() IS NOT NULL
     AND NOT (public.exos_is_admin() OR public.exos_has_org_role(v_org, ARRAY['owner','manager'])) THEN
    RAISE EXCEPTION 'exos_set_channel_price: not authorized' USING ERRCODE = '42501';
  END IF;
  SELECT * INTO v_tier FROM public.exos_ticket_tiers WHERE id = p_tier_id;
  IF v_tier.id IS NULL OR v_tier.event_id IS DISTINCT FROM p_event_id THEN
    RAISE EXCEPTION 'exos_set_channel_price: ticket type not found for this event';
  END IF;
  v_exos := public.exos_rr_tier_price(p_tier_id);
  IF v_price IS NOT NULL AND (v_price <= 0 OR v_price > 100000) THEN
    RAISE EXCEPTION 'exos_set_channel_price: price must be between 0 and 100000';
  END IF;
  IF v_price IS NOT NULL AND v_price < v_exos THEN
    RAISE EXCEPTION 'exos_set_channel_price: % can''t be below the ticket type''s Exos price (%): marketplace listings never undercut Exos',
      v_price, v_exos USING ERRCODE = '23514';
  END IF;
  -- Blank, or the same as the ticket type: follow the ticket type.
  IF v_price = v_exos THEN
    v_price := NULL;
  END IF;
  UPDATE public.exos_distribution_listings
     SET unit_price = v_price, updated_at = now()
   WHERE event_id = p_event_id AND channel = p_channel AND tier_id = p_tier_id
  RETURNING id INTO v_id;
  IF v_id IS NULL THEN
    RAISE EXCEPTION 'exos_set_channel_price: give this ticket type seats on that marketplace first';
  END IF;
  RETURN coalesce(v_price, v_exos);
END $$;
REVOKE ALL ON FUNCTION public.exos_set_channel_price(uuid, text, uuid, numeric) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.exos_set_channel_price(uuid, text, uuid, numeric) TO authenticated, service_role;
