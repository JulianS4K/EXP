-- ============================================================================
-- Migration 20260928060000 — Exos (Bridge / D4): discount codes that work
--                            (vouchers with % / $ off) and a safe quota editor
--
-- Lane:     d4 (exos / bridge ticketing infra)
-- Touches:  W: exos_vouchers (+discount_percent, +discount_amount, one-price-rule CHECK)
--              FUNCTION exos_issue_voucher (replaced: +p_discount_percent, +p_discount_amount)
--              FUNCTION exos_voucher_discount, exos_event_quotas (new)
--              FUNCTION exos_tg_quota_scope, exos_tg_quota_tier_scope + triggers (new)
--              exos_vouchers rows copied from exos_discount_codes (idempotent)
--           R: exos_events, exos_ticket_tiers, exos_quotas, exos_quota_tiers, exos_tickets
-- Pre-reqs: 20260925012000 (exos_issue_voucher with p_code), 20260702123030 (quotas)
--
-- Discount codes. exos_discount_codes were never redeemed at checkout, so the
-- editor was hidden (SHOW_DISCOUNT_CODES = false). Instead of a second code
-- path, vouchers get pretix's price modes: a voucher pins a price
-- (price_override, as before), takes a percentage off (discount_percent,
-- 0 < p < 100) or takes an amount off (discount_amount > 0), at most one of
-- them. Everything vouchers already enforce applies: one use per ticket
-- (atomic at fulfilment), expiry, a ticket-type restriction, refunds. A 100%
-- code is a comp, not a discount: use comps. exos-checkout prices it with
-- _shared/pricing.ts voucherUnitPrice (the storefront uses the same function).
--
-- Existing exos_discount_codes rows are copied to vouchers when the code is
-- free on the event (percentage 0-100 exclusive, fixed > 0; usage_limit ->
-- max_uses, NULL -> 100000; expires_at -> valid_until; a code unlocking
-- exactly one tier is restricted to it). The old table is left in place,
-- unused.
--
-- Quotas. The table RLS checks a quota's own org_id, and nothing tied that to
-- the event's org: an owner of org A could put a closed quota on org B's event
-- and link B's tiers, stopping B's sales. Now org_id is always the event's
-- org, and a quota only takes tiers of its own event. exos_event_quotas gives
-- the editor each quota's sold / held / available.
--
-- Idempotent. D4 authors; applying to prod is operator-gated.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. Voucher price modes
-- ---------------------------------------------------------------------------
ALTER TABLE public.exos_vouchers ADD COLUMN IF NOT EXISTS discount_percent numeric;
ALTER TABLE public.exos_vouchers ADD COLUMN IF NOT EXISTS discount_amount numeric;
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'exos_vouchers_discount_chk') THEN
    ALTER TABLE public.exos_vouchers ADD CONSTRAINT exos_vouchers_discount_chk CHECK (
      (discount_percent IS NULL OR (discount_percent > 0 AND discount_percent < 100))
      AND (discount_amount IS NULL OR discount_amount > 0)
      AND num_nonnulls(price_override, discount_percent, discount_amount) <= 1);
  END IF;
END $$;
COMMENT ON COLUMN public.exos_vouchers.discount_percent IS
  'Percent off the scheduled ticket price (0 < p < 100). At most one of price_override / discount_percent / discount_amount.';
COMMENT ON COLUMN public.exos_vouchers.discount_amount IS
  'Amount off each ticket, in the event currency. Refused at checkout when it leaves nothing to pay.';

DROP FUNCTION IF EXISTS public.exos_issue_voucher(uuid, uuid, text, boolean, numeric, integer, integer, text, text);
CREATE OR REPLACE FUNCTION public.exos_issue_voucher(
  p_event_id         uuid,
  p_tier_id          uuid    DEFAULT NULL,
  p_reserved_email   text    DEFAULT NULL,
  p_bypass_capacity  boolean DEFAULT true,
  p_price_override   numeric DEFAULT NULL,
  p_max_uses         integer DEFAULT 1,
  p_valid_hours      integer DEFAULT NULL,
  p_comment          text    DEFAULT NULL,
  p_code             text    DEFAULT NULL,
  p_discount_percent numeric DEFAULT NULL,
  p_discount_amount  numeric DEFAULT NULL
) RETURNS text
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE v_uid uuid := auth.uid(); v_org uuid; v_code text;
BEGIN
  SELECT org_id INTO v_org FROM public.exos_events WHERE id = p_event_id;
  IF v_org IS NULL THEN RAISE EXCEPTION 'exos_issue_voucher: event not found'; END IF;
  IF v_uid IS NULL OR NOT exos_has_org_role(v_org, ARRAY['owner','manager']) THEN
    RAISE EXCEPTION 'exos_issue_voucher: not authorized' USING ERRCODE = '42501';
  END IF;
  IF p_tier_id IS NOT NULL AND NOT EXISTS (
       SELECT 1 FROM public.exos_ticket_tiers WHERE id = p_tier_id AND event_id = p_event_id) THEN
    RAISE EXCEPTION 'exos_issue_voucher: ticket type is not on this event';
  END IF;
  IF num_nonnulls(p_price_override, p_discount_percent, p_discount_amount) > 1 THEN
    RAISE EXCEPTION 'exos_issue_voucher: pick one of a set price, a percent off or an amount off' USING ERRCODE = '22023';
  END IF;
  IF p_discount_percent IS NOT NULL AND NOT (p_discount_percent > 0 AND p_discount_percent < 100) THEN
    RAISE EXCEPTION 'exos_issue_voucher: percent off must be more than 0 and less than 100 (use a comp for free tickets)'
      USING ERRCODE = '22023';
  END IF;
  IF p_discount_amount IS NOT NULL AND p_discount_amount <= 0 THEN
    RAISE EXCEPTION 'exos_issue_voucher: amount off must be more than 0' USING ERRCODE = '22023';
  END IF;
  IF nullif(btrim(p_code), '') IS NOT NULL THEN
    v_code := upper(btrim(p_code));
    IF v_code !~ '^[A-Z0-9_-]{3,32}$' THEN
      RAISE EXCEPTION 'exos_issue_voucher: codes are 3-32 letters, numbers, - or _' USING ERRCODE = '22023';
    END IF;
    IF EXISTS (SELECT 1 FROM public.exos_vouchers WHERE event_id = p_event_id AND upper(code) = v_code) THEN
      RAISE EXCEPTION 'exos_issue_voucher: code % is already used on this event', v_code USING ERRCODE = '23505';
    END IF;
  ELSE
    v_code := upper(encode(extensions.gen_random_bytes(6), 'hex'));   -- 12-char code
  END IF;
  INSERT INTO public.exos_vouchers (event_id, code, tier_id, max_uses, bypass_capacity,
              price_override, discount_percent, discount_amount, reserved_email, valid_until, comment, created_by)
  VALUES (p_event_id, v_code, p_tier_id, greatest(1, coalesce(p_max_uses,1)), p_bypass_capacity,
          p_price_override, p_discount_percent, p_discount_amount, lower(nullif(btrim(p_reserved_email),'')),
          CASE WHEN p_valid_hours IS NOT NULL THEN now() + make_interval(hours => p_valid_hours) END,
          p_comment, v_uid);
  RETURN v_code;
END $$;
REVOKE ALL ON FUNCTION public.exos_issue_voucher(uuid, uuid, text, boolean, numeric, integer, integer, text, text, numeric, numeric) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.exos_issue_voucher(uuid, uuid, text, boolean, numeric, integer, integer, text, text, numeric, numeric) TO authenticated;

-- What a valid code takes off, for the storefront to show the price it will
-- charge. Nothing for an invalid code (same answer as exos_check_voucher).
CREATE OR REPLACE FUNCTION public.exos_voucher_discount(p_event_id uuid, p_code text, p_email text DEFAULT NULL)
RETURNS TABLE (discount_percent numeric, discount_amount numeric)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT v.discount_percent, v.discount_amount
    FROM public.exos_check_voucher(p_event_id, p_code, p_email) c
    JOIN public.exos_vouchers v ON v.id = c.voucher_id
   WHERE c.is_valid
$$;
REVOKE ALL ON FUNCTION public.exos_voucher_discount(uuid, text, text) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.exos_voucher_discount(uuid, text, text) TO anon, authenticated, service_role;

-- Carry over promo codes that were saved but never redeemable (when the old
-- table exists: it's from 20260520120000, which scratch harnesses skip).
DO $carry$
BEGIN
  IF to_regclass('public.exos_discount_codes') IS NULL THEN
    RETURN;
  END IF;
  EXECUTE $sql$
  INSERT INTO public.exos_vouchers (event_id, code, tier_id, max_uses, used_count, bypass_capacity,
              discount_percent, discount_amount, valid_until, comment)
  SELECT d.event_id, upper(btrim(d.code)),
         CASE WHEN cardinality(d.unlocks_tier_ids) = 1
               AND EXISTS (SELECT 1 FROM public.exos_ticket_tiers t
                            WHERE t.id = d.unlocks_tier_ids[1] AND t.event_id = d.event_id)
              THEN d.unlocks_tier_ids[1] END,
         greatest(1, coalesce(d.usage_limit, 100000)), least(d.used_count, greatest(1, coalesce(d.usage_limit, 100000))), false,
         CASE WHEN d.type = 'percentage' THEN d.value END,
         CASE WHEN d.type = 'fixed' THEN d.value END,
         d.expires_at, 'promo code (moved from discount codes)'
    FROM public.exos_discount_codes d
   WHERE btrim(d.code) <> ''
     AND ((d.type = 'percentage' AND d.value > 0 AND d.value < 100) OR (d.type = 'fixed' AND d.value > 0))
  ON CONFLICT (event_id, upper(code)) DO NOTHING
  $sql$;
END $carry$;

-- ---------------------------------------------------------------------------
-- 2. Quotas stay inside their event's org
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.exos_tg_quota_scope()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE v_org uuid;
BEGIN
  SELECT org_id INTO v_org FROM public.exos_events WHERE id = NEW.event_id;
  IF v_org IS NULL THEN
    RAISE EXCEPTION 'quota: event not found' USING ERRCODE = '23503';
  END IF;
  IF TG_OP = 'UPDATE' AND NEW.event_id IS DISTINCT FROM OLD.event_id THEN
    RAISE EXCEPTION 'quota: a quota can''t move to another event' USING ERRCODE = '42501';
  END IF;
  -- The event decides the org; RLS then checks the caller's role in it.
  NEW.org_id := v_org;
  IF NEW.name IS NULL OR btrim(NEW.name) = '' THEN
    RAISE EXCEPTION 'quota: give it a name' USING ERRCODE = '22023';
  END IF;
  NEW.name := left(btrim(NEW.name), 80);
  RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION public.exos_tg_quota_scope() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS exos_quotas_scope ON public.exos_quotas;
CREATE TRIGGER exos_quotas_scope BEFORE INSERT OR UPDATE ON public.exos_quotas
  FOR EACH ROW EXECUTE FUNCTION public.exos_tg_quota_scope();

CREATE OR REPLACE FUNCTION public.exos_tg_quota_tier_scope()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF NOT EXISTS (
       SELECT 1 FROM public.exos_quotas q JOIN public.exos_ticket_tiers t ON t.event_id = q.event_id
        WHERE q.id = NEW.quota_id AND t.id = NEW.tier_id) THEN
    RAISE EXCEPTION 'quota: the ticket type is not on the quota''s event' USING ERRCODE = '42501';
  END IF;
  RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION public.exos_tg_quota_tier_scope() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS exos_quota_tiers_scope ON public.exos_quota_tiers;
CREATE TRIGGER exos_quota_tiers_scope BEFORE INSERT OR UPDATE ON public.exos_quota_tiers
  FOR EACH ROW EXECUTE FUNCTION public.exos_tg_quota_tier_scope();

-- The editor's view: each quota of an event with what's sold, held and left.
CREATE OR REPLACE FUNCTION public.exos_event_quotas(p_event_id uuid)
RETURNS TABLE (id uuid, name text, size int, closed boolean, tier_ids uuid[], sold int, held int, available int)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE v_org uuid;
BEGIN
  SELECT e.org_id INTO v_org FROM public.exos_events e WHERE e.id = p_event_id;
  IF v_org IS NULL THEN
    RAISE EXCEPTION 'exos_event_quotas: event not found';
  END IF;
  IF NOT (exos_is_admin() OR exos_has_org_role(v_org, ARRAY['owner','manager','finance','content'])) THEN
    RAISE EXCEPTION 'exos_event_quotas: not authorized' USING ERRCODE = '42501';
  END IF;
  RETURN QUERY
  SELECT q.id, q.name, q.size, q.closed,
         coalesce((SELECT array_agg(qt.tier_id ORDER BY qt.tier_id) FROM public.exos_quota_tiers qt WHERE qt.quota_id = q.id), '{}'),
         (SELECT count(*)::int FROM public.exos_tickets t
           WHERE t.tier_id IN (SELECT qt.tier_id FROM public.exos_quota_tiers qt WHERE qt.quota_id = q.id)
             AND t.status IN ('active','used','transferred')),
         (SELECT coalesce(sum(h.quantity * public.exos_tier_party_size(h.tier_id)), 0)::int FROM public.exos_cart_holds h
           WHERE h.tier_id IN (SELECT qt.tier_id FROM public.exos_quota_tiers qt WHERE qt.quota_id = q.id)
             AND h.status = 'active' AND h.expires_at > now()),
         public.exos_quota_available(q.id)
    FROM public.exos_quotas q
   WHERE q.event_id = p_event_id
   ORDER BY q.created_at, q.id;
END $$;
REVOKE ALL ON FUNCTION public.exos_event_quotas(uuid) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.exos_event_quotas(uuid) TO authenticated;
