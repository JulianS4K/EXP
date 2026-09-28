-- ============================================================================
-- Migration 20260929030000 — Exos (Bridge / D4): money path fixes
--
-- Lane:     d4 (exos / bridge ticketing infra)
-- Touches:  C: FUNCTION exos_event_house_available
--           W: FUNCTION exos_create_hold, exos_create_guest_hold,
--              exos_refund_finalize
--                (patched in place)
-- Pre-reqs: 20260929020000
--
-- From the 2026-09-28 build review:
--
-- 1. Holds ignored the event's house cap (exos_events.total_tickets). Only
--    fulfilment checked it, so near sellout on a multi-tier event buyers were
--    charged and then auto-refunded (losing Stripe's fee each time). Holds
--    (signed-in and guest) now also check what's left of the house:
--    total_tickets minus sold, live holds, seats set aside for marketplaces
--    and blocking vouchers across the event (exos_event_house_available).
-- 2. An organizer refund voided the tickets as soon as Stripe accepted it
--    ('pending'). A pending refund can still fail, leaving the buyer unpaid
--    with void tickets. Tickets are now voided once the refund has succeeded
--    (stripe-webhook settles a pending one on refund.updated / charge.refund.updated).
--
-- Re-run safe (each patch asserts one match and is skipped once applied).
-- D4 authors; applying to prod is operator-gated.
-- ============================================================================

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

-- ── 1. The house cap ────────────────────────────────────────────────────────

-- Seats left in the whole event (NULL = no house cap), in people.
CREATE OR REPLACE FUNCTION public.exos_event_house_available(p_event_id uuid)
RETURNS integer LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT CASE WHEN coalesce(e.total_tickets, 0) <= 0 THEN NULL ELSE greatest(0,
           e.total_tickets - e.tickets_sold
           - coalesce((SELECT sum(h.quantity * public.exos_tier_party_size(h.tier_id))
                         FROM public.exos_cart_holds h
                        WHERE h.event_id = e.id AND h.status = 'active' AND h.expires_at > now()), 0)
           - coalesce((SELECT sum(public.exos_channel_allocated(t.id) * public.exos_tier_party_size(t.id))
                         FROM public.exos_ticket_tiers t WHERE t.event_id = e.id), 0)
           - coalesce((SELECT sum((v.max_uses - v.used_count) * public.exos_tier_party_size(v.tier_id))
                         FROM public.exos_vouchers v
                        WHERE v.event_id = e.id AND v.tier_id IS NOT NULL AND v.block_quota
                          AND v.used_count < v.max_uses AND (v.valid_until IS NULL OR v.valid_until > now())), 0))::int
         END
    FROM public.exos_events e WHERE e.id = p_event_id;
$$;
REVOKE ALL ON FUNCTION public.exos_event_house_available(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.exos_event_house_available(uuid) TO authenticated, service_role;

-- Holds check the house as well as the tier (the mints already bump the
-- event's sold count against total_tickets themselves).
SELECT pg_temp.exos_patch('public.exos_create_hold(uuid, uuid, integer, integer, text)',
  'exos_event_house_available',
  '  IF v_avail IS NOT NULL AND v_avail < p_quantity THEN
    RAISE EXCEPTION ''exos_create_hold: not enough tickets available'' USING ERRCODE = ''23514'';
  END IF;',
  '  IF v_avail IS NOT NULL AND v_avail < p_quantity THEN
    RAISE EXCEPTION ''exos_create_hold: not enough tickets available'' USING ERRCODE = ''23514'';
  END IF;
  -- The house cap (mig 20260929030000).
  IF coalesce(public.exos_event_house_available(p_event_id), p_quantity * public.exos_tier_party_size(p_tier_id))
       < p_quantity * public.exos_tier_party_size(p_tier_id) THEN
    RAISE EXCEPTION ''exos_create_hold: not enough tickets available'' USING ERRCODE = ''23514'';
  END IF;');
SELECT pg_temp.exos_patch('public.exos_create_guest_hold(uuid, uuid, integer, text, text, text)',
  'exos_event_house_available',
  '  IF v_avail IS NOT NULL AND v_avail < p_quantity THEN
    RAISE EXCEPTION ''exos_create_guest_hold: not enough tickets available'' USING ERRCODE = ''23514'';
  END IF;',
  '  IF v_avail IS NOT NULL AND v_avail < p_quantity THEN
    RAISE EXCEPTION ''exos_create_guest_hold: not enough tickets available'' USING ERRCODE = ''23514'';
  END IF;
  -- The house cap (mig 20260929030000).
  IF coalesce(public.exos_event_house_available(p_event_id), p_quantity * public.exos_tier_party_size(p_tier_id))
       < p_quantity * public.exos_tier_party_size(p_tier_id) THEN
    RAISE EXCEPTION ''exos_create_guest_hold: not enough tickets available'' USING ERRCODE = ''23514'';
  END IF;');

-- ── 2. Refunds void tickets once they've succeeded ─────────────────────────

SELECT pg_temp.exos_patch('public.exos_refund_finalize(uuid, text, text, text)',
  'Void once, when the refund has succeeded',
  '  -- Void once, when Stripe has accepted the refund (pending or succeeded).
  IF v_req.voids_applied_at IS NULL THEN',
  '  -- Void once, when the refund has succeeded (mig 20260929030000): a pending
  -- one can still fail, and the buyer keeps their tickets until it lands.
  IF v_req.voids_applied_at IS NULL AND v_status = ''succeeded'' THEN');

-- ── 3. Receipts say what was paid ──────────────────────────────────────────
-- The purchase mails said "Payment received" without an amount; Stripe's own
-- receipt depends on a dashboard setting. Now they carry the total, the tax
-- in it and the order reference ('' for a free order).
CREATE OR REPLACE FUNCTION public.exos_receipt_html(p_session_id text)
RETURNS text LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT coalesce((
    SELECT '<p>Paid: <strong>' || to_char(s.amount_cents / 100.0, 'FM999,999,990.00') || ' ' ||
           upper(coalesce(s.currency, 'usd')) || '</strong>' ||
           CASE WHEN coalesce(s.tax_cents, 0) > 0
                THEN ' (including ' || to_char(s.tax_cents / 100.0, 'FM999,999,990.00') || ' tax)' ELSE '' END ||
           '. Order reference: ' || public.exos_mail_escape(s.session_id) || '.</p>'
      FROM public.exos_checkout_sessions s
     WHERE s.session_id = p_session_id AND coalesce(s.amount_cents, 0) > 0), '');
$$;
REVOKE ALL ON FUNCTION public.exos_receipt_html(text) FROM PUBLIC, anon, authenticated;

SELECT pg_temp.exos_patch('public.exos_fulfill_checkout(text)',
  'public.exos_receipt_html(s.session_id) ||
          coalesce((SELECT',
  '''(no password needed) to get your entry QR code. Send a link to a friend and they can claim that ticket themselves.</p>'' ||',
  '''(no password needed) to get your entry QR code. Send a link to a friend and they can claim that ticket themselves.</p>'' ||
          public.exos_receipt_html(s.session_id) ||');
SELECT pg_temp.exos_patch('public.exos_fulfill_checkout(text)',
  'door.</p>'' END || public.exos_receipt_html',
  '''Open the app to show your QR at the door.</p>'' END,',
  '''Open the app to show your QR at the door.</p>'' END || public.exos_receipt_html(s.session_id),');

-- A guest's free claim (exos-checkout, no Stripe) goes through the same
-- fulfilment: its mail says so instead of "Payment received".
SELECT pg_temp.exos_patch('public.exos_fulfill_checkout(text)',
  'You''re in. Your',
  '''<p>Payment received. Your '' || cardinality(v_ids)::text',
  '''<p>'' || CASE WHEN coalesce(s.amount_cents, 0) > 0 THEN ''Payment received.'' ELSE ''You''''re in.'' END ||
          '' Your '' || cardinality(v_ids)::text');
