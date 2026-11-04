-- ============================================================================
-- Migration 20261104100000 — Exos: buyer mistake simulation fixes (2026-11-04)
-- ============================================================================
-- Found by tests/exos/sim_buyer.sql and race_sim_buyer.sh (buyers, fans and
-- guests doing the wrong thing against the merged gaps tree).
--
-- 1. exos_claim_transfer(uuid) read the transfer and the ticket without a
--    lock. Two claims of one link at the same moment (the recipient on two
--    devices, or a forwarded link) both succeeded: both were told the ticket
--    was theirs, the last one won it. A claim racing the sender's cancel
--    overwrote 'cancelled' with 'completed' and moved the ticket anyway, so
--    the sender was told it was cancelled and lost it. And a claim racing a
--    refund put the voided ticket back to 'active' (refunded AND admitted).
--    Now the claim locks the transfer, then the ticket, and re-reads both
--    under the locks: the loser gets "transfer is completed / cancelled" or
--    "ticket was refunded".
-- 2. exos_cancel_transfer: the same lock, so a cancel that loses the race to a
--    claim says "transfer is completed" instead of reporting a cancel that
--    did not happen. Prod has the function (mig 20260520130000, patched by
--    20260925010000 4a); this replay chain did not, so it is defined here in
--    full: the same body, mail withdrawal included, plus the lock.
-- 3. exos_refund_checkout (a whole-order refund: Stripe dashboard refunds via
--    charge.refunded, disputes, the reconcile sweep) voided the tickets but
--    left the buyer's refund ask 'open': only the organizer's refund-request
--    flow closed asks. The buyer's "My refund requests" said pending after the
--    money was back, and the organizer's queue kept a refunded order in it.
--    Now the asks on the voided tickets close as 'refunded'.
-- 4. The "your order didn't go through" mail (exos_fulfill_checkout) said
--    "sold out while you were paying" for every failure but a voucher one. A
--    buyer who paid twice (double-click, two tabs) and hit the per-person
--    cap, or whose membership lapsed during a member presale, was told the
--    show sold out. Now those two say what happened. Same refund line.
--
-- Touches:  W: FUNCTION exos_claim_transfer(uuid), exos_refund_checkout(text,text),
--              exos_fulfill_checkout(text) (patched in place), exos_cancel_transfer(uuid) (redefined,
--              same signature + grants)
-- Pre-reqs: every exos migration before this one.
-- Re-run safe: marker-checked patches (pg_temp.exos_patch_n); CREATE OR
-- REPLACE keeps grants, and the grants are restated.
-- ============================================================================

CREATE OR REPLACE FUNCTION pg_temp.exos_patch_n(p_sig text, p_marker text, p_old text, p_new text, p_hits int)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE p_fn regprocedure := to_regprocedure(p_sig); v_def text; v_hits int;
BEGIN
  IF p_fn IS NULL THEN
    RAISE EXCEPTION '%: not present', p_sig;
  END IF;
  v_def := replace(pg_get_functiondef(p_fn), chr(13), '');
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

-- ---------------------------------------------------------------------------
-- 1. Claim: lock the transfer, then the ticket.
-- ---------------------------------------------------------------------------
SELECT pg_temp.exos_patch_n('public.exos_claim_transfer(uuid)',
  '/* exos: claim locks the transfer */',
  $o$  SELECT * INTO tr FROM public.exos_transfers WHERE id = p_transfer_id;$o$,
  $n$  /* exos: claim locks the transfer */ -- mig 20261104100000: two claims, or a claim and
  -- the sender's cancel, serialize here; the loser sees the winner's status.
  SELECT * INTO tr FROM public.exos_transfers WHERE id = p_transfer_id FOR UPDATE;$n$, 1);

SELECT pg_temp.exos_patch_n('public.exos_claim_transfer(uuid)',
  '/* exos: claim locks the ticket */',
  $o$  SELECT status INTO v_status FROM public.exos_tickets WHERE id = tr.ticket_id;$o$,
  $n$  /* exos: claim locks the ticket */ -- mig 20261104100000: a refund (or check-in)
  -- racing the claim commits first or waits; a voided ticket is never revived.
  SELECT status INTO v_status FROM public.exos_tickets WHERE id = tr.ticket_id FOR UPDATE;$n$, 1);

-- ---------------------------------------------------------------------------
-- 2. Cancel: the same lock (full definition; see the header).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.exos_cancel_transfer(p_transfer_id uuid)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_uid uuid := auth.uid();
  tr    public.exos_transfers%ROWTYPE;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'exos_cancel_transfer: not authenticated' USING ERRCODE = '42501';
  END IF;
  -- mig 20261104100000: locked, so a claim that got there first wins cleanly.
  SELECT * INTO tr FROM public.exos_transfers WHERE id = p_transfer_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'exos_cancel_transfer: transfer not found';
  END IF;
  IF tr.sender_id <> v_uid THEN
    RAISE EXCEPTION 'exos_cancel_transfer: not the sender' USING ERRCODE = '42501';
  END IF;
  IF tr.status <> 'pending' THEN
    RAISE EXCEPTION 'exos_cancel_transfer: transfer is %', tr.status;
  END IF;

  UPDATE public.exos_transfers SET status = 'cancelled' WHERE id = p_transfer_id;
  -- withdraw the unsent "someone sent you a ticket" mail (mig 20260925010000)
  DELETE FROM public.exos_mail
   WHERE template = 'transfer-initiated' AND status = 'pending'
     AND to_email = lower(trim(tr.receiver_email)) AND created_by = tr.sender_id
     AND created_at >= tr.created_at;
  UPDATE public.exos_tickets
     SET pending_transfer_id = NULL, last_reissue_at = now()
   WHERE id = tr.ticket_id AND pending_transfer_id = p_transfer_id;
END $$;
REVOKE EXECUTE ON FUNCTION public.exos_cancel_transfer(uuid) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.exos_cancel_transfer(uuid) FROM anon;
GRANT  EXECUTE ON FUNCTION public.exos_cancel_transfer(uuid) TO authenticated;

-- ---------------------------------------------------------------------------
-- 3. A whole-order refund closes the buyer's open refund asks.
-- ---------------------------------------------------------------------------
SELECT pg_temp.exos_patch_n('public.exos_refund_checkout(text,text)',
  '/* exos: refund closes asks */',
  $o$  IF s.status <> 'refunded' THEN$o$,
  $n$  /* exos: refund closes asks */ -- mig 20261104100000: however the refund came in.
  UPDATE public.exos_refund_asks a
     SET status = 'refunded', decided_at = now(), updated_at = now()
   WHERE a.status = 'open' AND a.session_id = p_session_id
     AND a.ticket_id IN (SELECT t.id FROM public.exos_tickets t WHERE t.order_ref = p_session_id AND t.status = 'voided');

  IF s.status <> 'refunded' THEN$n$, 1);

-- ---------------------------------------------------------------------------
-- 4. The failure mail names the per-person cap and the member presale.
-- ---------------------------------------------------------------------------
SELECT pg_temp.exos_patch_n('public.exos_fulfill_checkout(text)',
  '/* exos: failure mail reasons */',
  $o$          CASE WHEN v_fail LIKE 'voucher%'$o$,
  $n$          CASE /* exos: failure mail reasons */ WHEN v_fail LIKE 'per-account%'
               THEN '</strong> couldn''t be issued because you already have as many tickets as this event allows per person, so this order didn''t go through. '
               WHEN v_fail LIKE '%presale for members%'
               THEN '</strong> are on a members-only presale and your membership wasn''t active when your payment came through, so your order didn''t go through. '
               WHEN v_fail LIKE 'voucher%'$n$, 1);
