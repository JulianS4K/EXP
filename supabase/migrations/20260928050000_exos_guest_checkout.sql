-- ============================================================================
-- Migration 20260928050000 — Exos (Bridge / D4): guest checkout
--
-- Lane:     d4 (exos / bridge ticketing infra)
-- Touches:  W: exos_checkout_sessions (buyer_uid nullable, +guest)
--              exos_cart_holds (+ip_hash)
--              FUNCTION exos_assert_purchase_limit_email, exos_create_guest_hold,
--                exos_guest_owner, exos_tg_guest_addons_follow (new)
--              FUNCTION exos_fulfill_checkout (replaced, from the current body)
--              FUNCTION exos_release_hold (replaced: NULL-safe owner check)
--              TRIGGER exos_tickets_guest_addons_follow (new)
--           R: auth.users, exos_orgs, exos_events, exos_ticket_tiers, exos_quotas
-- Pre-reqs: 20260926090000 (last fulfil patch), 20260927010000 (claim any account)
--
-- Fans rank "check out without making an account" second only to the all-in
-- price (reports/Organizer and fan ticketing needs.md). A buyer can now pay with
-- just an email; exos-checkout calls the service-role guest hold instead of the
-- JWT one.
--
-- Where guest tickets go at fulfilment:
--   * An Exos account with that email, confirmed: straight into its wallet.
--     An unconfirmed account doesn't count (anyone can sign up with any email).
--   * Otherwise they're parked on the org owner with a pending transfer to the
--     email, the same as marketplace orders and email comps, and the buyer is
--     mailed one claim link per ticket. Claiming signs in with a one-time code,
--     so "an account" is created at the door of the wallet, not at checkout.
--     Add-ons stay unowned until the first ticket of the order is claimed, then
--     follow it (trigger below).
--
-- Bots. A signed-in hold costs a confirmed inbox (20260924205916); a guest hold
-- costs nothing but an email string, so it's bounded differently:
--   * one live hold per email per event (a new one replaces the old cart),
--   * the event's maxPerOrder, and maxPerAccount counted per email (tickets
--     bought with it plus tickets owned by the confirmed account with it),
--   * at most 5 guest holds per network (hashed IP) per 10 minutes,
--   * live guest holds may reserve at most a quarter of what's left for the
--     event (never fewer than 10 seats), so a script can't park a sellout,
--   * organizers switch guest checkout off per event with
--     purchase_limits.guestCheckout = false (high-demand drops).
-- The 30-minute TTL stays: it matches Stripe's minimum session expiry.
--
-- Idempotent. D4 authors; applying to prod is operator-gated.
-- ============================================================================

ALTER TABLE public.exos_checkout_sessions ALTER COLUMN buyer_uid DROP NOT NULL;
ALTER TABLE public.exos_checkout_sessions ADD COLUMN IF NOT EXISTS guest boolean NOT NULL DEFAULT false;
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'exos_checkout_sessions_buyer_chk') THEN
    ALTER TABLE public.exos_checkout_sessions ADD CONSTRAINT exos_checkout_sessions_buyer_chk
      CHECK (buyer_uid IS NOT NULL OR (guest AND coalesce(buyer_email, '') LIKE '%_@_%'));
  END IF;
END $$;
COMMENT ON COLUMN public.exos_checkout_sessions.guest IS
  'Guest checkout (mig 20260928050000): paid with an email only; buyer_uid is NULL.';

ALTER TABLE public.exos_cart_holds ADD COLUMN IF NOT EXISTS ip_hash text;
CREATE INDEX IF NOT EXISTS exos_cart_holds_ip_hash_idx
  ON public.exos_cart_holds (ip_hash, created_at) WHERE ip_hash IS NOT NULL;
COMMENT ON COLUMN public.exos_cart_holds.ip_hash IS
  'Guest holds only: salted SHA-256 of the client IP, for the per-network rate limit. Never the IP.';

-- The confirmed account a guest email belongs to, if any.
CREATE OR REPLACE FUNCTION public.exos_guest_owner(p_email text)
RETURNS uuid
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT u.id FROM auth.users u
   WHERE lower(u.email) = lower(btrim(p_email)) AND u.email_confirmed_at IS NOT NULL
   ORDER BY u.email_confirmed_at, u.id LIMIT 1
$$;
REVOKE ALL ON FUNCTION public.exos_guest_owner(text) FROM PUBLIC, anon, authenticated;

-- maxPerOrder / maxPerAccount for a guest: "account" is the email.
CREATE OR REPLACE FUNCTION public.exos_assert_purchase_limit_email(p_event_id uuid, p_email text, p_qty int)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_email     text := lower(btrim(coalesce(p_email, '')));
  v_lim       jsonb;
  v_max_order int;
  v_max_acct  int;
  v_acct      uuid;
  v_have      int;
BEGIN
  SELECT purchase_limits INTO v_lim FROM public.exos_events WHERE id = p_event_id;
  IF v_lim IS NULL THEN
    RETURN;
  END IF;
  v_max_order := nullif(v_lim ->> 'maxPerOrder', '')::int;
  v_max_acct  := nullif(v_lim ->> 'maxPerAccount', '')::int;

  IF v_max_order IS NOT NULL AND v_max_order > 0 AND p_qty > v_max_order THEN
    RAISE EXCEPTION 'exos: exceeds max per order (% requested, limit %)', p_qty, v_max_order
      USING ERRCODE = '23514';
  END IF;

  IF v_max_acct IS NOT NULL AND v_max_acct > 0 THEN
    PERFORM pg_advisory_xact_lock(hashtextextended(p_event_id::text || ':email:' || v_email, 0));
    v_acct := public.exos_guest_owner(v_email);
    SELECT count(*) INTO v_have
      FROM public.exos_tickets
     WHERE event_id = p_event_id AND status <> 'voided'
       AND (lower(buyer_email) = v_email OR (v_acct IS NOT NULL AND owner_id = v_acct));
    IF v_have + p_qty > v_max_acct THEN
      RAISE EXCEPTION 'exos: exceeds max per account (hold %, +% would exceed limit %)',
        v_have, p_qty, v_max_acct USING ERRCODE = '23514';
    END IF;
  END IF;
END $$;
REVOKE ALL ON FUNCTION public.exos_assert_purchase_limit_email(uuid, text, int) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.exos_assert_purchase_limit_email(uuid, text, int) TO service_role;

-- The guest twin of exos_create_hold. Service role only: exos-checkout calls
-- it after validating the email and hashing the client IP.
CREATE OR REPLACE FUNCTION public.exos_create_guest_hold(
  p_event_id     uuid,
  p_tier_id      uuid,
  p_quantity     int,
  p_email        text,
  p_ip_hash      text DEFAULT NULL,
  p_voucher_code text DEFAULT NULL
) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_email  text := lower(btrim(coalesce(p_email, '')));
  v_ip     text := nullif(btrim(coalesce(p_ip_hash, '')), '');
  v_org    uuid;
  v_status text;
  v_lim    jsonb;
  v_sstart timestamptz;
  v_send   timestamptz;
  v_vis    text;
  v_avail  int;
  v_ev_left int;
  v_guest  int;
  v_recent int;
  v_id     uuid;
  q        record;
BEGIN
  IF current_user NOT IN ('service_role', 'postgres', 'supabase_admin') THEN
    RAISE EXCEPTION 'exos_create_guest_hold: service role only' USING ERRCODE = '42501';
  END IF;
  IF v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' OR length(v_email) > 254 THEN
    RAISE EXCEPTION 'exos_create_guest_hold: enter a valid email' USING ERRCODE = '22023';
  END IF;
  IF p_quantity < 1 OR p_quantity > 10 THEN
    RAISE EXCEPTION 'exos_create_guest_hold: quantity must be 1-10';
  END IF;

  SELECT org_id, status, purchase_limits INTO v_org, v_status, v_lim
    FROM public.exos_events WHERE id = p_event_id;
  IF v_org IS NULL THEN
    RAISE EXCEPTION 'exos_create_guest_hold: event not found';
  END IF;
  IF v_status <> 'published' THEN
    RAISE EXCEPTION 'exos_create_guest_hold: event not on sale' USING ERRCODE = '23514';
  END IF;
  IF lower(coalesce(v_lim ->> 'guestCheckout', '')) = 'false' THEN
    RAISE EXCEPTION 'exos_create_guest_hold: sign in to buy tickets for this event' USING ERRCODE = '42501';
  END IF;

  -- Per-network rate limit (hashed IP; the edge function never stores the IP).
  IF v_ip IS NOT NULL THEN
    PERFORM pg_advisory_xact_lock(hashtextextended('exos_guest_ip:' || v_ip, 0));
    SELECT count(*) INTO v_recent FROM public.exos_cart_holds
     WHERE ip_hash = v_ip AND created_at > now() - interval '10 minutes';
    IF v_recent >= 5 THEN
      RAISE EXCEPTION 'exos_create_guest_hold: too many checkouts from this network, try again in a few minutes'
        USING ERRCODE = '53400';
    END IF;
  END IF;

  -- One live cart per email per event.
  PERFORM pg_advisory_xact_lock(hashtextextended('exos_hold:' || p_event_id::text || ':email:' || v_email, 0));
  UPDATE public.exos_cart_holds
     SET status = 'released', released_at = now()
   WHERE event_id = p_event_id AND buyer_uid IS NULL AND lower(buyer_email) = v_email AND status = 'active';

  PERFORM public.exos_assert_purchase_limit_email(p_event_id, v_email, p_quantity);

  FOR q IN SELECT quota_id FROM public.exos_quota_tiers WHERE tier_id = p_tier_id LOOP
    PERFORM 1 FROM public.exos_quotas WHERE id = q.quota_id FOR UPDATE;
  END LOOP;

  SELECT sales_start, sales_end, visibility INTO v_sstart, v_send, v_vis
    FROM public.exos_ticket_tiers
   WHERE id = p_tier_id AND event_id = p_event_id
   FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'exos_create_guest_hold: tier not found for this event';
  END IF;
  IF v_vis IS NOT NULL AND v_vis <> 'public' AND NOT EXISTS (
       SELECT 1 FROM public.exos_check_voucher(p_event_id, p_voucher_code, v_email) v
        WHERE v.is_valid AND v.restrict_tier_id = p_tier_id) THEN
    RAISE EXCEPTION 'exos_create_guest_hold: ticket type not available' USING ERRCODE = '42501';
  END IF;
  IF v_sstart IS NOT NULL AND now() < v_sstart THEN
    RAISE EXCEPTION 'exos_create_guest_hold: sales have not started for this tier' USING ERRCODE = '23514';
  END IF;
  IF v_send IS NOT NULL AND now() > v_send THEN
    RAISE EXCEPTION 'exos_create_guest_hold: sales have ended for this tier' USING ERRCODE = '23514';
  END IF;

  v_avail := public.exos_effective_available(p_tier_id);
  IF v_avail IS NOT NULL AND v_avail < p_quantity THEN
    RAISE EXCEPTION 'exos_create_guest_hold: not enough tickets available' USING ERRCODE = '23514';
  END IF;

  -- Live guest holds reserve at most a quarter of what's left (>= 10 seats).
  PERFORM pg_advisory_xact_lock(hashtextextended('exos_guest_ceiling:' || p_event_id::text, 0));
  SELECT coalesce(sum(quantity), 0) INTO v_guest FROM public.exos_cart_holds
   WHERE event_id = p_event_id AND buyer_uid IS NULL AND status = 'active' AND expires_at > now();
  v_ev_left := coalesce(v_avail, 1000000) + v_guest;
  IF v_guest + p_quantity > greatest(10, ceil(v_ev_left / 4.0)::int) THEN
    RAISE EXCEPTION 'exos_create_guest_hold: this event is busy right now, sign in to check out or try again shortly'
      USING ERRCODE = '53400';
  END IF;

  INSERT INTO public.exos_cart_holds (event_id, tier_id, org_id, buyer_uid, buyer_email, ip_hash, quantity, expires_at)
  VALUES (p_event_id, p_tier_id, v_org, NULL, v_email, v_ip, p_quantity, now() + interval '30 minutes')
  RETURNING id INTO v_id;
  RETURN v_id;
END $$;
REVOKE ALL ON FUNCTION public.exos_create_guest_hold(uuid, uuid, int, text, text, text) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.exos_create_guest_hold(uuid, uuid, int, text, text, text) TO service_role;

-- A guest hold has no buyer_uid, and "v_buy = v_uid" is NULL, which made the
-- old NOT (...) check pass for any signed-in caller. Only staff release those.
CREATE OR REPLACE FUNCTION public.exos_release_hold(p_hold_id uuid)
RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_uid  uuid := auth.uid();
  v_org  uuid;
  v_buy  uuid;
  v_n    int;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'exos_release_hold: not authenticated' USING ERRCODE = '42501';
  END IF;
  SELECT org_id, buyer_uid INTO v_org, v_buy FROM public.exos_cart_holds WHERE id = p_hold_id;
  IF v_org IS NULL THEN
    RETURN false;                       -- unknown hold → nothing to do
  END IF;
  IF NOT (coalesce(v_buy = v_uid, false) OR exos_is_admin() OR exos_has_org_role(v_org, ARRAY['owner','manager'])) THEN
    RAISE EXCEPTION 'exos_release_hold: not authorized' USING ERRCODE = '42501';
  END IF;

  UPDATE public.exos_cart_holds
     SET status = 'released', released_at = now()
   WHERE id = p_hold_id AND status = 'active';
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN v_n > 0;
END $$;

-- Add-ons of a parked guest order follow the first claimed ticket.
CREATE OR REPLACE FUNCTION public.exos_tg_guest_addons_follow()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF NEW.owner_id IS NOT NULL AND NEW.order_ref IS NOT NULL AND NEW.channel_source = 'stripe' THEN
    UPDATE public.exos_order_addons
       SET owner_id = NEW.owner_id, buyer_id = NEW.owner_id
     WHERE order_ref = NEW.order_ref AND owner_id IS NULL AND event_id = NEW.event_id;
  END IF;
  RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION public.exos_tg_guest_addons_follow() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS exos_tickets_guest_addons_follow ON public.exos_tickets;
CREATE TRIGGER exos_tickets_guest_addons_follow
  AFTER UPDATE OF owner_id ON public.exos_tickets
  FOR EACH ROW WHEN (NEW.owner_id IS DISTINCT FROM OLD.owner_id AND NEW.transfer_id IS NOT NULL)
  EXECUTE FUNCTION public.exos_tg_guest_addons_follow();

-- Fulfilment: the body as of 20260926090000 plus the guest branches (marked
-- "Guest"). s.buyer_uid is NULL only for guest sessions.
CREATE OR REPLACE FUNCTION public.exos_fulfill_checkout(p_session_id text)
RETURNS uuid[]
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
DECLARE
  s          public.exos_checkout_sessions%ROWTYPE;
  v_tier_name text;
  v_updated  int;
  v_ids      uuid[] := '{}';
  v_id       uuid;
  v_evname   text;
  v_safe     text;
  v_bypass   boolean := false;
  v_fail     text;
  i          int;
  r          record;
  -- Guest checkout (mig 20260928050000): who the tickets go to.
  v_owner    uuid;
  v_park     boolean := false;
  v_tr       uuid;
  v_ev       public.exos_events%ROWTYPE;
BEGIN
  SELECT * INTO s FROM public.exos_checkout_sessions WHERE session_id = p_session_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'exos_fulfill_checkout: unknown session %', p_session_id;
  END IF;

  IF s.status = 'fulfilled' THEN
    RETURN coalesce(s.ticket_ids, '{}');
  END IF;
  IF s.status <> 'pending' THEN
    RETURN '{}'::uuid[];
  END IF;

  BEGIN  -- all-or-nothing claim: any RAISE ... 'XF001' undoes every step below
    BEGIN
      IF s.buyer_uid IS NULL THEN
        PERFORM public.exos_assert_purchase_limit_email(s.event_id, s.buyer_email, s.quantity);
      ELSE
        PERFORM public.exos_assert_purchase_limit(s.event_id, s.buyer_uid, s.quantity);
      END IF;
    EXCEPTION WHEN others THEN
      RAISE EXCEPTION 'per-account purchase limit exceeded at fulfillment' USING ERRCODE = 'XF001';
    END;

    IF s.voucher_id IS NOT NULL THEN
      IF NOT EXISTS (
           SELECT 1 FROM public.exos_vouchers v
            WHERE v.id = s.voucher_id AND v.event_id = s.event_id
              AND (v.valid_until IS NULL OR v.valid_until >= coalesce(s.created_at, now()))
              -- reserved_email no longer limits who redeems: first redeemer wins
              AND (v.tier_id IS NULL OR v.tier_id = s.tier_id)) THEN
        RAISE EXCEPTION 'voucher no longer valid at fulfillment' USING ERRCODE = 'XF001';
      END IF;
      SELECT bypass_capacity INTO v_bypass FROM public.exos_vouchers WHERE id = s.voucher_id;
      v_bypass := coalesce(v_bypass, false);
      IF NOT public.exos_consume_voucher(s.voucher_id, s.quantity) THEN
        RAISE EXCEPTION 'voucher already fully redeemed' USING ERRCODE = 'XF001';
      END IF;
      UPDATE public.exos_waitlist SET status = 'converted'
       WHERE voucher_id = s.voucher_id AND status = 'offered';
    END IF;

    -- The session's own hold stops counting against the quota check below.
    PERFORM public.exos_consume_holds_for_session(p_session_id);

    IF NOT v_bypass THEN
      BEGIN
        PERFORM public.exos_assert_quota(s.tier_id, s.quantity);
      EXCEPTION WHEN others THEN
        RAISE EXCEPTION 'shared quota exhausted at fulfillment' USING ERRCODE = 'XF001';
      END;
    END IF;

    IF s.tier_id IS NOT NULL THEN
      UPDATE public.exos_ticket_tiers
         SET sold = sold + s.quantity
       WHERE id = s.tier_id AND event_id = s.event_id
         AND (v_bypass OR capacity = 0 OR sold + s.quantity <= capacity)
      RETURNING name INTO v_tier_name;
      IF NOT FOUND THEN
        RAISE EXCEPTION 'tier sold out at fulfillment' USING ERRCODE = 'XF001';
      END IF;
    END IF;

    UPDATE public.exos_events
       SET tickets_sold = tickets_sold + s.quantity * public.exos_tier_party_size(s.tier_id)
     WHERE id = s.event_id
       AND (v_bypass OR total_tickets = 0 OR tickets_sold + s.quantity * public.exos_tier_party_size(s.tier_id) <= total_tickets);
    GET DIAGNOSTICS v_updated = ROW_COUNT;
    IF v_updated = 0 THEN
      RAISE EXCEPTION 'event sold out at fulfillment' USING ERRCODE = 'XF001';
    END IF;

    -- Guest: the confirmed account with that email, else parked on the org
    -- owner with a claim-by-email transfer per ticket (as marketplace orders).
    v_owner := s.buyer_uid;
    IF v_owner IS NULL THEN
      v_owner := public.exos_guest_owner(s.buyer_email);
      IF v_owner IS NULL THEN
        v_park := true;
        SELECT owner_uid INTO v_owner FROM public.exos_orgs WHERE id = s.org_id;
        SELECT * INTO v_ev FROM public.exos_events WHERE id = s.event_id;
      END IF;
    END IF;

    PERFORM set_config('exos.table_mint', p_session_id, true);
    FOR i IN 1..s.quantity * public.exos_tier_party_size(s.tier_id) LOOP
      INSERT INTO public.exos_tickets (
        event_id, org_id, tier_id, tier_name, buyer_id, owner_id, buyer_email,
        status, barcode_secret, price_paid, order_ref, channel_source, promoter_id, referral_code
      ) VALUES (
        s.event_id, s.org_id, s.tier_id, v_tier_name, v_owner, v_owner,
        lower(coalesce(s.buyer_email, '')),
        'active', gen_random_uuid()::text,
        round(greatest(s.amount_cents - coalesce((SELECT sum(coalesce((a->>'quantity')::int, 0) * coalesce((a->>'unit_price_cents')::int, 0)) FROM jsonb_array_elements(CASE WHEN jsonb_typeof(s.addons) = 'array' THEN s.addons ELSE '[]'::jsonb END) a), 0), 0)::numeric / 100 / (s.quantity * public.exos_tier_party_size(s.tier_id)), 2),
        p_session_id, 'stripe', s.promoter_id,
        (SELECT fr.code FROM public.exos_fan_referrals fr WHERE fr.code = s.attribution->>'ref' AND fr.event_id = s.event_id AND fr.user_id IS DISTINCT FROM CASE WHEN v_park THEN NULL ELSE v_owner END)
      ) RETURNING id INTO v_id;
      v_ids := array_append(v_ids, v_id);

      IF v_park THEN
        INSERT INTO public.exos_transfers
        SELECT * FROM jsonb_populate_record(NULL::public.exos_transfers, jsonb_build_object(
          'id', gen_random_uuid(), 'ticket_id', v_id, 'org_id', s.org_id,
          'sender_id', v_owner, 'receiver_email', lower(s.buyer_email),
          'status', 'pending', 'event_id', s.event_id, 'event_title', v_ev.name,
          'event_image', v_ev.image_url, 'tier_name', v_tier_name, 'organizer_id', v_ev.created_by,
          -- jsonb_populate_record yields NULL (not DEFAULT) for absent keys.
          'created_at', now(), 'updated_at', now()))
        RETURNING id INTO v_tr;
        UPDATE public.exos_tickets SET pending_transfer_id = v_tr, last_reissue_at = now() WHERE id = v_id;
      END IF;
    END LOOP;

    -- A table order: one booking per table (mig 20260926050000).
    PERFORM public._exos_book_tables(s.tier_id, p_session_id, CASE WHEN v_park THEN NULL ELSE v_owner END, v_ids, s.quantity);

    IF s.addons IS NOT NULL AND jsonb_typeof(s.addons) = 'array' THEN
      FOR r IN
        SELECT * FROM jsonb_to_recordset(s.addons)
          AS x(addon_id uuid, quantity int, unit_price_cents int, name text)
      LOOP
        IF r.addon_id IS NULL OR coalesce(r.quantity, 0) < 1 THEN CONTINUE; END IF;
        UPDATE public.exos_event_addons
           SET sold = sold + r.quantity
         WHERE id = r.addon_id AND event_id = s.event_id
           AND (capacity = 0 OR sold + r.quantity <= capacity);
        IF NOT FOUND THEN
          RAISE EXCEPTION 'add-on "%" sold out at fulfillment', left(coalesce(r.name, '?'), 80)
            USING ERRCODE = 'XF001';
        END IF;
        INSERT INTO public.exos_order_addons (
          event_id, org_id, addon_id, addon_name, buyer_id, owner_id,
          quantity, unit_price_paid, order_ref, channel_source, status
        ) VALUES (
          s.event_id, s.org_id, r.addon_id, r.name,
          CASE WHEN v_park THEN NULL ELSE v_owner END, CASE WHEN v_park THEN NULL ELSE v_owner END,
          r.quantity, round(coalesce(r.unit_price_cents, 0)::numeric / 100, 2),
          p_session_id, 'stripe', 'active'
        );
      END LOOP;
    END IF;
  EXCEPTION WHEN SQLSTATE 'XF001' THEN
    v_fail := SQLERRM;
  END;

  IF v_fail IS NOT NULL THEN
    UPDATE public.exos_cart_holds
       SET status = 'released', released_at = now()
     WHERE checkout_session_id = p_session_id AND status = 'active';
    UPDATE public.exos_checkout_sessions
       SET status = 'failed', failure_reason = left(v_fail, 500)
     WHERE session_id = p_session_id;
    IF coalesce(s.buyer_email, '') <> '' THEN
      SELECT name INTO v_evname FROM public.exos_events WHERE id = s.event_id;
      v_safe := replace(replace(coalesce(v_evname, 'your event'), '<', '&lt;'), '>', '&gt;');
      BEGIN
        INSERT INTO public.exos_mail (template, to_email, subject, html, created_by, status)
        VALUES ('order-failed', lower(s.buyer_email),
          left('Your order for ' || v_safe || ' didn''t go through', 200),
          '<p>Sorry, the tickets you picked for <strong>' || v_safe ||
          CASE WHEN v_fail LIKE 'voucher%'
               THEN '</strong> couldn''t be issued because the access code you used is no longer valid, so your order didn''t go through. '
               ELSE '</strong> sold out while you were paying, so your order didn''t go through. ' END ||
          'Your payment is being refunded in full; it can take 5 to 10 days to show up.</p>',
          s.buyer_uid, 'pending');
      EXCEPTION WHEN others THEN NULL;
      END;
    END IF;
    RETURN '{}'::uuid[];
  END IF;

  UPDATE public.exos_checkout_sessions
     SET status='fulfilled', ticket_ids=v_ids, fulfilled_at=now()
   WHERE session_id = p_session_id;

  -- Guest with no account yet: the claim links are the tickets.
  IF v_park THEN
    v_safe := replace(replace(replace(coalesce(v_ev.name, 'your event'), '&', '&amp;'), '<', '&lt;'), '>', '&gt;');
    BEGIN
      INSERT INTO public.exos_mail (template, to_email, subject, html, created_by, status)
      VALUES (
        'transfer-initiated', lower(s.buyer_email),
        left('Your ticket' || CASE WHEN cardinality(v_ids) > 1 THEN 's' ELSE '' END || ' for ' || v_safe, 200),
        '<p>Payment received. Your ' || cardinality(v_ids)::text || ' ticket' ||
          CASE WHEN cardinality(v_ids) > 1 THEN 's' ELSE '' END || ' for <strong>' || v_safe ||
          '</strong> ' || CASE WHEN cardinality(v_ids) > 1 THEN 'are' ELSE 'is' END ||
          ' waiting for you. Open a link below and sign in with a one-time code sent to this email ' ||
          '(no password needed) to get your entry QR code. Send a link to a friend and they can claim that ticket themselves.</p>' ||
          coalesce((SELECT '<ul>' || string_agg('<li><a href="{{app_url}}/claim/' || tr.id || '">Claim ticket ' || n || '</a></li>', '' ORDER BY n) || '</ul>'
                      FROM (SELECT tr0.id, row_number() OVER (ORDER BY tr0.created_at, tr0.id) AS n
                              FROM public.exos_transfers tr0
                             WHERE tr0.ticket_id = ANY (v_ids) AND tr0.status = 'pending') tr), ''),
        NULL, 'pending');
    EXCEPTION WHEN others THEN
      NULL;
    END;
    RETURN v_ids;
  END IF;

  -- Buyer confirmation mail (best-effort; never unwinds a paid fulfillment).
  IF coalesce(s.buyer_email, '') <> '' THEN
    SELECT name INTO v_evname FROM public.exos_events WHERE id = s.event_id;
    v_safe := replace(replace(coalesce(v_evname, 'your event'), '<', '&lt;'), '>', '&gt;');
    BEGIN
      INSERT INTO public.exos_mail (template, to_email, subject, html, created_by, status)
      VALUES (
        'ticket-issued', lower(s.buyer_email),
        left('Your ticket' || CASE WHEN s.quantity > 1 THEN 's' ELSE '' END ||
             ' for ' || v_safe || ' ' || CASE WHEN s.quantity > 1 THEN 'are' ELSE 'is' END || ' ready', 200),
        '<p>Payment received — your ' || s.quantity::text || ' ticket' ||
          CASE WHEN s.quantity > 1 THEN 's' ELSE '' END ||
          ' for <strong>' || v_safe ||
          '</strong> ' || CASE WHEN s.quantity > 1 THEN 'are' ELSE 'is' END ||
          ' in your wallet. ' ||
          CASE WHEN s.buyer_uid IS NULL THEN 'Sign in to Exos with this email to show your QR at the door.</p>'
               ELSE 'Open the app to show your QR at the door.</p>' END,
        v_owner, 'pending'
      );
    EXCEPTION WHEN others THEN
      NULL;
    END;
  END IF;

  RETURN v_ids;
END $function$

;
REVOKE ALL ON FUNCTION public.exos_fulfill_checkout(text) FROM PUBLIC, anon, authenticated;
