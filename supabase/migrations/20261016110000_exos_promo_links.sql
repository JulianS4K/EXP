-- ============================================================================
-- Promo links: a direct promotion URL per channel, with a redemption limit
-- ============================================================================
-- Touches:  W: TABLE exos_vouchers (+ link_label, link_channel, link_clicks)
--           C: FUNCTION exos_create_promo_link, exos_promo_links (owner /
--              manager / finance read), exos_promo_link_hit (anon: counts a
--              visit, returns nothing)
-- Pre-reqs: 20260928060000 (voucher discounts), 20260925012000 (chosen codes)
--
-- A promo link is a voucher with a label and a channel ("Instagram story",
-- "SMS blast", "DJ Kay"): the link opens the event page with the code
-- applied (?code=…), so a fan sees the deal before checkout. The voucher's
-- max_uses is the redemption limit (tickets), valid_until the expiry, and
-- discount / price / tier the deal; everything else (one use per ticket,
-- refused when used up, codes need an account) is the voucher's own rules.
-- Visits are counted per link (link_clicks) by an anon RPC that only
-- increments a known code and answers nothing, so it can't be used to test
-- codes. Redemptions are the voucher's used_count.
--
-- Re-run safe. Prod apply needs operator OK.
-- ============================================================================

ALTER TABLE public.exos_vouchers
  ADD COLUMN IF NOT EXISTS link_label   text,
  ADD COLUMN IF NOT EXISTS link_channel text,
  ADD COLUMN IF NOT EXISTS link_clicks  integer NOT NULL DEFAULT 0;
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'exos_vouchers_link_chk') THEN
    ALTER TABLE public.exos_vouchers ADD CONSTRAINT exos_vouchers_link_chk CHECK (
      (link_label IS NULL OR length(link_label) BETWEEN 1 AND 80)
      AND (link_channel IS NULL OR link_channel ~ '^[a-z0-9_-]{1,40}$')
      AND link_clicks >= 0);
  END IF;
END $$;

-- Owner / manager: make a promo link. Returns the code.
CREATE OR REPLACE FUNCTION public.exos_create_promo_link(
  p_event_id uuid, p_label text, p_channel text, p_max_uses integer,
  p_valid_hours integer DEFAULT NULL, p_code text DEFAULT NULL,
  p_discount_percent numeric DEFAULT NULL, p_discount_amount numeric DEFAULT NULL,
  p_tier_id uuid DEFAULT NULL
) RETURNS text
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_label   text := nullif(btrim(coalesce(p_label, '')), '');
  v_channel text := lower(nullif(btrim(coalesce(p_channel, '')), ''));
  v_code    text;
BEGIN
  IF v_label IS NULL OR length(v_label) > 80 THEN
    RAISE EXCEPTION 'exos_create_promo_link: give the link a name (up to 80 characters)' USING ERRCODE = '22023';
  END IF;
  IF v_channel IS NOT NULL AND v_channel !~ '^[a-z0-9_-]{1,40}$' THEN
    RAISE EXCEPTION 'exos_create_promo_link: channel: lowercase letters, numbers, - and _' USING ERRCODE = '22023';
  END IF;
  IF p_max_uses IS NULL OR p_max_uses < 1 OR p_max_uses > 100000 THEN
    RAISE EXCEPTION 'exos_create_promo_link: the limit is 1 to 100000 tickets' USING ERRCODE = '22023';
  END IF;
  -- exos_issue_voucher checks the role (owner / manager) and the deal.
  -- A promo link never jumps a sold-out event.
  v_code := public.exos_issue_voucher(
    p_event_id, p_tier_id, NULL, false, NULL, p_max_uses, p_valid_hours,
    'Promo link: ' || v_label, nullif(btrim(coalesce(p_code, '')), ''), p_discount_percent, p_discount_amount);
  UPDATE public.exos_vouchers
     SET link_label = v_label, link_channel = v_channel
   WHERE event_id = p_event_id AND code = v_code;
  RETURN v_code;
END $$;
REVOKE ALL ON FUNCTION public.exos_create_promo_link(uuid, text, text, integer, integer, text, numeric, numeric, uuid) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.exos_create_promo_link(uuid, text, text, integer, integer, text, numeric, numeric, uuid) TO authenticated;

-- Owner / manager / finance: the event's promo links with visits and redemptions.
CREATE OR REPLACE FUNCTION public.exos_promo_links(p_event_id uuid)
RETURNS TABLE (voucher_id uuid, code text, label text, channel text, clicks integer, used integer, max_uses integer,
               valid_until timestamptz, discount_percent numeric, discount_amount numeric, tier_id uuid, created_at timestamptz)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE v_org uuid;
BEGIN
  SELECT org_id INTO v_org FROM public.exos_events WHERE id = p_event_id;
  IF v_org IS NULL OR NOT EXISTS (
       SELECT 1 FROM public.exos_org_memberships m
        WHERE m.org_id = v_org AND m.user_id = auth.uid() AND m.disabled IS NOT TRUE
          AND m.role IN ('owner', 'manager', 'finance')) THEN
    RAISE EXCEPTION 'exos_promo_links: not authorized' USING ERRCODE = '42501';
  END IF;
  RETURN QUERY
    SELECT v.id, v.code, v.link_label, v.link_channel, v.link_clicks, v.used_count, v.max_uses,
           v.valid_until, v.discount_percent, v.discount_amount, v.tier_id, v.created_at
      FROM public.exos_vouchers v
     WHERE v.event_id = p_event_id AND v.link_label IS NOT NULL
     ORDER BY v.created_at DESC
     LIMIT 200;
END $$;
REVOKE ALL ON FUNCTION public.exos_promo_links(uuid) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.exos_promo_links(uuid) TO authenticated, service_role;

-- Anyone landing from a promo link: count the visit. Answers nothing (so it
-- can't tell a real code from a guess) and only touches promo-link codes.
CREATE OR REPLACE FUNCTION public.exos_promo_link_hit(p_event_id uuid, p_code text)
RETURNS void
LANGUAGE sql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  UPDATE public.exos_vouchers
     SET link_clicks = least(link_clicks + 1, 2000000000)
   WHERE event_id = p_event_id
     AND link_label IS NOT NULL
     AND upper(code) = upper(left(btrim(coalesce(p_code, '')), 64))
$$;
REVOKE ALL ON FUNCTION public.exos_promo_link_hit(uuid, text) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.exos_promo_link_hit(uuid, text) TO anon, authenticated;

-- ROLLBACK (manual): drop the three functions and the three columns.
