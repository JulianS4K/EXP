-- ============================================================================
-- Buyer fixes: a code-unlocked free tier can be claimed; fans of a cancelled
-- event can ask for their refund
-- ============================================================================
-- Touches:  R: exos_claim_free_tickets gains an optional p_voucher_code (the
--              6-argument form is DROPPED and recreated with the 7th argument
--              defaulted, so every existing named or positional call still
--              resolves; grants unchanged: authenticated only)
--           P: _exos_refund_ask_state (a cancelled event no longer refuses the
--              ask; its policy / window don't apply)
-- Pre-reqs: 20260925003000 (exos_create_hold's voucher check),
--           20261016100000 (claim's ticket-backend gate), 20261015090000 (asks)
--
-- 1. A hidden tier is only sold through a voucher restricted to it. Checkout
--    and exos_create_hold check the code; the free claim had no way to receive
--    one, so a free hidden tier unlocked by a code answered "tier not
--    available". The claim now takes the code, checks it the way
--    exos_create_hold does (exos_check_voucher: valid, restricted to this
--    tier) and uses it up, one use per ticket, as fulfilment does for a paid
--    order (mig 20260924205508). A retry of a claim already made (same
--    order_ref) still returns its tickets, even once the code is used up.
-- 2. A cancelled event refused every refund ask ("refunds are sent
--    automatically"), but refunds only happen when the organizer runs
--    "refund everyone". Holders of a cancelled event can now ask, whatever the
--    refund policy or window; the other rules (payer only, not refunded /
--    voided / checked in / in transfer) stay.
-- ============================================================================

CREATE OR REPLACE FUNCTION pg_temp.exos_patch_n(p_sig text, p_marker text, p_old text, p_new text, p_hits int)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE p_fn regprocedure := to_regprocedure(p_sig); v_def text; v_hits int;
BEGIN
  IF p_fn IS NULL THEN
    RAISE EXCEPTION '%: not present', p_sig;
  END IF;
  -- Pasted through a browser the patch text can carry CRLF line ends; compare without CRs.
  v_def := replace(pg_get_functiondef(p_fn), chr(13), '');
  p_marker := replace(p_marker, chr(13), ''); p_old := replace(p_old, chr(13), ''); p_new := replace(p_new, chr(13), '');
  IF position(p_marker in v_def) > 0 THEN
    RAISE NOTICE '%: already patched (%)', p_fn, p_marker;
    RETURN;
  END IF;
  v_hits := (length(v_def) - length(replace(v_def, p_old, ''))) / length(p_old);
  IF v_hits <> p_hits THEN
    RAISE EXCEPTION '%: expected % match(es) for patch "%", found %', p_fn, p_hits, p_marker, v_hits;
  END IF;
  EXECUTE replace(v_def, p_old, p_new);
END $$;

-- 1. Free claim takes a voucher code ------------------------------------------
DO $$
DECLARE
  v_def text;
  -- Each pair: the text in the live body, what it becomes. All CR-free.
  v_old text[] := ARRAY[
    'p_order_ref text DEFAULT NULL::text)',
    E'  i            int;\n',
    E'  IF v_vis IS NOT NULL AND v_vis <> ''public'' THEN\n    RAISE EXCEPTION ''exos_claim_free_tickets: tier not available'' USING ERRCODE = ''42501'';\n  END IF;',
    E'  PERFORM public.exos_assert_purchase_limit(p_event_id, v_uid, p_quantity);\n'];
  v_new text[] := ARRAY[
    'p_order_ref text DEFAULT NULL::text, p_voucher_code text DEFAULT NULL::text)',
    E'  i            int;\n  v_voucher    uuid;\n',
    E'  -- exos:claim-voucher: a hidden tier needs a valid code restricted to it, as\n'
    '  -- in exos_create_hold; a retry of a claim already made passes.\n'
    '  IF v_vis IS NOT NULL AND v_vis <> ''public'' THEN\n'
    '    IF nullif(btrim(coalesce(p_voucher_code, '''')), '''') IS NOT NULL THEN\n'
    '      SELECT v.voucher_id INTO v_voucher\n'
    '        FROM public.exos_check_voucher(p_event_id, p_voucher_code, nullif(lower(coalesce(auth.jwt() ->> ''email'', '''')), '''')) v\n'
    '       WHERE v.is_valid AND v.restrict_tier_id = p_tier_id;\n'
    '    END IF;\n'
    '    IF v_voucher IS NULL AND NOT (nullif(p_order_ref, '''') IS NOT NULL AND EXISTS (\n'
    '         SELECT 1 FROM public.exos_tickets\n'
    '          WHERE event_id = p_event_id AND owner_id = v_uid AND order_ref = p_order_ref)) THEN\n'
    '      RAISE EXCEPTION ''exos_claim_free_tickets: tier not available'' USING ERRCODE = ''42501'';\n'
    '    END IF;\n'
    '  END IF;',
    E'  PERFORM public.exos_assert_purchase_limit(p_event_id, v_uid, p_quantity);\n\n'
    '  -- One code use per ticket (mig 20260924205508); rolled back with the claim.\n'
    '  IF v_voucher IS NOT NULL AND NOT public.exos_consume_voucher(v_voucher, p_quantity) THEN\n'
    '    RAISE EXCEPTION ''exos_claim_free_tickets: that code doesn''''t cover % tickets'', p_quantity USING ERRCODE = ''23514'';\n'
    '  END IF;\n'];
  n int;
  i int;
BEGIN
  IF to_regprocedure('public.exos_claim_free_tickets(uuid, uuid, integer, text, text, text, text)') IS NOT NULL THEN
    RAISE NOTICE 'exos_claim_free_tickets: voucher argument already applied';
    RETURN;
  END IF;
  v_def := replace(pg_get_functiondef(
    'public.exos_claim_free_tickets(uuid, uuid, integer, text, text, text)'::regprocedure), chr(13), '');
  FOR i IN 1..array_length(v_old, 1) LOOP
    n := (length(v_def) - length(replace(v_def, v_old[i], ''))) / length(v_old[i]);
    IF n <> 1 THEN
      RAISE EXCEPTION 'exos_claim_free_tickets: patch % expected 1 match, found %', i, n;
    END IF;
    v_def := replace(v_def, v_old[i], v_new[i]);
  END LOOP;
  DROP FUNCTION public.exos_claim_free_tickets(uuid, uuid, integer, text, text, text);
  EXECUTE v_def;
END $$;
REVOKE ALL ON FUNCTION public.exos_claim_free_tickets(uuid, uuid, integer, text, text, text, text) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.exos_claim_free_tickets(uuid, uuid, integer, text, text, text, text) TO authenticated;

-- 2. A cancelled event's holders can ask for a refund --------------------------
SELECT pg_temp.exos_patch_n('public._exos_refund_ask_state(uuid)', '/* cancelled: may ask */',
  $o$  ELSIF e.status = 'cancelled' THEN
    v_reason := 'event-cancelled';
  ELSIF t.status = 'voided' THEN$o$,
  $n$  ELSIF t.status = 'voided' THEN$n$,
  1);
SELECT pg_temp.exos_patch_n('public._exos_refund_ask_state(uuid)', '/* cancelled: may ask */',
  $o$  ELSIF v_until IS NULL THEN
    v_reason := 'no-refunds';
  ELSIF now() >= v_until THEN$o$,
  $n$  ELSIF e.status = 'cancelled' AND v_share > 0 AND s.status IN ('fulfilled', 'partially_refunded') THEN
    v_reason := NULL;  /* cancelled: may ask */
  ELSIF v_until IS NULL THEN
    v_reason := 'no-refunds';
  ELSIF now() >= v_until THEN$n$,
  1);
