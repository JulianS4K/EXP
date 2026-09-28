-- ============================================================================
-- Migration 20260929062000 — Exos (Bridge / D4): what each marketplace sale
-- was listed at, and the fee the marketplace took
--
-- Lane:     d4 (exos / bridge ticketing infra)
-- Touches:  W: exos_marketplace_orders (+list_unit_price, +marketplace_fee,
--              BEFORE trigger)
--           C: FUNCTION exos_listing_unit_price, exos_tg_marketplace_fee;
--              VIEW exos_marketplace_fee_rates
-- Pre-reqs: 20260929061000, 20260927050000 (listing_ref)
--
-- Exos lists each marketplace at a net-equal price: grossed up for that
-- store's seller fee so the organizer nets the Exos price wherever it sells
-- (_shared/marketplace/fees.ts). TEvo (3%) and SeatGeek (5%) fees are
-- confirmed from real orders; StubHub, Gametime, GoTickets and Vivid report
-- only the payout, so their rate is unknown until Exos sells there.
--
-- So every sale now records the per-ticket price its listing carried
-- (list_unit_price, from the allocation's listed / planned listings by
-- listing_ref, set once when the sale arrives) and the fee:
-- marketplace_fee = list_unit_price x quantity - proceeds. The view
-- exos_marketplace_fee_rates gives each store's realized rate over the last
-- 180 days, to confirm the known rates and learn the others. The buyer's
-- price (the marketplace's own markup on top) isn't visible and isn't needed.
--
-- Service role only. Re-run safe (IF NOT EXISTS / CREATE OR REPLACE / DROP
-- TRIGGER IF EXISTS). D4 authors; applying to prod is operator-gated.
-- ============================================================================

ALTER TABLE public.exos_marketplace_orders
  ADD COLUMN IF NOT EXISTS list_unit_price numeric CHECK (list_unit_price IS NULL OR list_unit_price >= 0),
  ADD COLUMN IF NOT EXISTS marketplace_fee numeric;

COMMENT ON COLUMN public.exos_marketplace_orders.list_unit_price IS
  'Per-ticket price the Exos listing carried when the sale arrived (planned listing entry unit_price). Mig 20260929062000.';
COMMENT ON COLUMN public.exos_marketplace_orders.marketplace_fee IS
  'list_unit_price x quantity - proceeds: what the marketplace kept. Mig 20260929062000.';

-- The unit_price of the listing entry `p_ref` in an allocation's live (else planned) listings.
CREATE OR REPLACE FUNCTION public.exos_listing_unit_price(p_allocation uuid, p_ref text)
RETURNS numeric LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT CASE WHEN (e ->> 'unit_price') ~ '^[0-9]+(\.[0-9]+)?$' THEN (e ->> 'unit_price')::numeric END
    FROM public.exos_distribution_listings d,
         LATERAL jsonb_array_elements(
           CASE WHEN jsonb_typeof(coalesce(d.listed_snapshot, d.planned_listing) -> 'listings') = 'array'
                THEN coalesce(d.listed_snapshot, d.planned_listing) -> 'listings' ELSE '[]'::jsonb END) e
   WHERE d.id = p_allocation AND p_ref IS NOT NULL AND e ->> 'listing_id' = p_ref
   LIMIT 1;
$$;
REVOKE ALL ON FUNCTION public.exos_listing_unit_price(uuid, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_listing_unit_price(uuid, text) TO service_role;

CREATE OR REPLACE FUNCTION public.exos_tg_marketplace_fee()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
  -- The listed price is read once: a later re-plan (new price) doesn't rewrite a past sale.
  IF NEW.list_unit_price IS NULL AND NEW.distribution_listing_id IS NOT NULL AND NEW.listing_ref IS NOT NULL THEN
    NEW.list_unit_price := public.exos_listing_unit_price(NEW.distribution_listing_id, NEW.listing_ref);
  END IF;
  NEW.marketplace_fee := CASE
    WHEN NEW.list_unit_price IS NOT NULL AND NEW.proceeds IS NOT NULL AND NEW.quantity > 0
    THEN round(NEW.list_unit_price * NEW.quantity - NEW.proceeds, 4) END;
  RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION public.exos_tg_marketplace_fee() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS exos_marketplace_orders_fee ON public.exos_marketplace_orders;
CREATE TRIGGER exos_marketplace_orders_fee
  BEFORE INSERT OR UPDATE OF listing_ref, proceeds, quantity, list_unit_price, distribution_listing_id
  ON public.exos_marketplace_orders
  FOR EACH ROW EXECUTE FUNCTION public.exos_tg_marketplace_fee();

-- Realized seller fee per marketplace (last 180 days, sales with both prices known).
CREATE OR REPLACE VIEW public.exos_marketplace_fee_rates WITH (security_invoker = true) AS
  SELECT channel,
         count(*)                                                        AS orders,
         sum(list_unit_price * quantity)                                 AS gross,
         sum(marketplace_fee)                                            AS fees,
         round(100 * sum(marketplace_fee) / nullif(sum(list_unit_price * quantity), 0), 3) AS fee_pct,
         round(100 * min(marketplace_fee / nullif(list_unit_price * quantity, 0)), 3)     AS min_order_pct,
         round(100 * max(marketplace_fee / nullif(list_unit_price * quantity, 0)), 3)     AS max_order_pct,
         max(created_at)                                                 AS last_sale_at
    FROM public.exos_marketplace_orders
   WHERE marketplace_fee IS NOT NULL AND created_at > now() - interval '180 days'
     AND sale_status <> 'cancelled'
   GROUP BY channel;
REVOKE ALL ON public.exos_marketplace_fee_rates FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.exos_marketplace_fee_rates TO service_role;
