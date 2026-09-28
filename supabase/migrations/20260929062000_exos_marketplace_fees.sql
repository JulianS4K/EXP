-- ============================================================================
-- Migration 20260929062000 — Exos (Bridge / D4): what each marketplace sale
-- was listed at, the fee the marketplace took, and the Exos fee
--
-- Lane:     d4 (exos / bridge ticketing infra)
-- Touches:  W: exos_marketplace_orders (+list_unit_price, +marketplace_fee,
--              +exos_fee, +organizer_net, BEFORE trigger)
--           C: TABLE exos_org_billing (+ insert trigger on exos_orgs);
--              FUNCTION exos_platform_fee_bps, exos_org_fee_bps,
--              exos_listing_unit_price, exos_tg_marketplace_fee;
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
-- Exos earns on every sale: 3% of every transaction, net after card
-- processing, paid by the organizer (operator, 2026-09-28;
-- _shared/platformFee.ts). On a marketplace sale the transaction Exos handles
-- is the marketplace's payout and there's no card fee (the marketplace charged
-- the card), so exos_fee = 3% of proceeds (to the cent, half up) and
-- organizer_net = proceeds - exos_fee (40.00 -> 38.80).
-- exos_platform_fee_bps() is the one place the SQL side keeps the rate.
--
-- The first 6 months are free (operator, 2026-09-28): no Exos fee until
-- exos_org_billing.fee_free_until, set to 6 months after the org is created
-- (existing orgs: 6 months from when this migration is applied, since no
-- one has paid a fee yet). Card processing still applies at checkout. The
-- date lives in its own table: org members can read it, only the server can
-- change it (staff extend it for a design partner with an UPDATE), so an
-- organizer can't extend their own free period. exos_org_fee_bps(org, at)
-- is the rate for an org at a moment: 0 inside the window, else 3%.
--
-- Service role only. Re-run safe (IF NOT EXISTS / CREATE OR REPLACE / DROP
-- TRIGGER IF EXISTS). D4 authors; applying to prod is operator-gated.
-- ============================================================================

ALTER TABLE public.exos_marketplace_orders
  ADD COLUMN IF NOT EXISTS list_unit_price numeric CHECK (list_unit_price IS NULL OR list_unit_price >= 0),
  ADD COLUMN IF NOT EXISTS marketplace_fee numeric,
  ADD COLUMN IF NOT EXISTS exos_fee numeric CHECK (exos_fee IS NULL OR exos_fee >= 0),
  ADD COLUMN IF NOT EXISTS organizer_net numeric;

-- The Exos fee rate in basis points (300 = 3%). Keep in step with EXOS_FEE_BPS.
CREATE OR REPLACE FUNCTION public.exos_platform_fee_bps()
RETURNS integer LANGUAGE sql IMMUTABLE AS $$ SELECT 300 $$;

-- Per-org billing terms the organizer can see but not change.
CREATE TABLE IF NOT EXISTS public.exos_org_billing (
  org_id         uuid PRIMARY KEY REFERENCES public.exos_orgs (id) ON DELETE CASCADE,
  fee_free_until timestamptz NOT NULL,
  note           text,
  updated_at     timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.exos_org_billing ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.exos_org_billing FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.exos_org_billing TO authenticated;
GRANT ALL ON public.exos_org_billing TO service_role;
DROP POLICY IF EXISTS exos_org_billing_sel ON public.exos_org_billing;
CREATE POLICY exos_org_billing_sel ON public.exos_org_billing FOR SELECT TO authenticated
  USING (public.exos_is_admin() OR public.exos_has_org_role(org_id, ARRAY['owner','manager','finance']));
COMMENT ON TABLE public.exos_org_billing IS
  'Per-org fee terms (mig 20260929062000): no Exos fee before fee_free_until. Server-written only.';

-- Existing orgs: 6 months from now (no fee has been charged yet). Re-run safe.
INSERT INTO public.exos_org_billing (org_id, fee_free_until)
SELECT o.id, greatest(o.created_at, now()) + interval '6 months' FROM public.exos_orgs o
ON CONFLICT (org_id) DO NOTHING;

-- New orgs: 6 months from signup.
CREATE OR REPLACE FUNCTION public.exos_tg_org_billing()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
  INSERT INTO public.exos_org_billing (org_id, fee_free_until)
  VALUES (NEW.id, coalesce(NEW.created_at, now()) + interval '6 months')
  ON CONFLICT (org_id) DO NOTHING;
  RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION public.exos_tg_org_billing() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS exos_orgs_billing ON public.exos_orgs;
CREATE TRIGGER exos_orgs_billing AFTER INSERT ON public.exos_orgs
  FOR EACH ROW EXECUTE FUNCTION public.exos_tg_org_billing();

-- The Exos fee rate for an org at a moment: 0 during its free months, else 3%.
CREATE OR REPLACE FUNCTION public.exos_org_fee_bps(p_org uuid, p_at timestamptz)
RETURNS integer LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT CASE WHEN EXISTS (SELECT 1 FROM public.exos_org_billing b
                            WHERE b.org_id = p_org AND coalesce(p_at, now()) < b.fee_free_until)
              THEN 0 ELSE public.exos_platform_fee_bps() END;
$$;
REVOKE ALL ON FUNCTION public.exos_org_fee_bps(uuid, timestamptz) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_org_fee_bps(uuid, timestamptz) TO service_role;

COMMENT ON COLUMN public.exos_marketplace_orders.list_unit_price IS
  'Per-ticket price the Exos listing carried when the sale arrived (planned listing entry unit_price). Mig 20260929062000.';
COMMENT ON COLUMN public.exos_marketplace_orders.marketplace_fee IS
  'list_unit_price x quantity - proceeds: what the marketplace kept. Mig 20260929062000.';
COMMENT ON COLUMN public.exos_marketplace_orders.exos_fee IS
  'The Exos fee: exos_platform_fee_bps() of proceeds, to the cent, half up. Mig 20260929062000.';
COMMENT ON COLUMN public.exos_marketplace_orders.organizer_net IS
  'proceeds - exos_fee: what the organizer is owed for the sale. Mig 20260929062000.';

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
  -- The rate when the sale happened (0 during the org's free months).
  NEW.exos_fee := CASE WHEN NEW.proceeds IS NOT NULL
    THEN round(NEW.proceeds * public.exos_org_fee_bps(NEW.org_id, coalesce(NEW.sold_at, NEW.created_at, now())) / 10000.0, 2) END;
  NEW.organizer_net := NEW.proceeds - NEW.exos_fee;
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
