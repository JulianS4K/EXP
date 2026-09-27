-- ============================================================================
-- Migration 20260927010000 — Exos (Bridge / D4): a transfer is claimed by
--                            link, into any Exos account
--
-- Lane:     d4 (exos / bridge ticketing infra)
-- Touches:  W: FUNCTION exos_claim_transfer, exos_queue_mail,
--                exos_fulfil_marketplace_order (patched in place)
--              FUNCTION exos_transfer_claim_preview (new)
--           R: exos_transfers, exos_tickets, exos_marketplace_orders
-- Pre-reqs: 20260926193000 (fulfil_marketplace_order), 20260925010000
--
-- Operator decision (2026-09-27): people sign in with whichever account they
-- want. The email a ticket was sent to only decides where the claim link is
-- mailed; it no longer decides who may claim. That covers marketplace sales
-- (the buyer email is often a relay address the marketplace forwards from)
-- and Exos-to-Exos transfers alike.
--
-- 1. exos_claim_transfer: any verified Exos account holding the transfer id
--    (the claim link) claims it; the first claim wins. Everything else is
--    unchanged: rows lock FOR UPDATE, the ticket must still point at this
--    transfer and belong to its sender, the barcode secret rotates, and the
--    ticket (owner, buyer, buyer_email) moves to the claimer.
-- 2. exos_queue_mail 'transfer-claimed': the claimer was authorised by their
--    email matching receiver_email. Now: the caller owns the ticket through
--    this transfer. A marketplace sale's sender is the organizer, who isn't
--    mailed once per claimed ticket.
-- 3. exos_fulfil_marketplace_order: the mail says "sign in with any Exos
--    account" instead of naming the order email.
-- 4. exos_transfer_claim_preview: RLS only lets the sender, the addressed
--    email and org staff read a transfer, so the claim page reads its display
--    fields through this function instead: no emails, no ticket id.
--
-- The transfer id (a random UUID, only in the claim link) is the bearer
-- secret, as it already was for whoever the link reached.
--
-- Every patch asserts one match and is skipped once applied (re-run safe).
-- D4 authors; applying to prod is operator-gated.
-- ============================================================================

-- Patch helper: replace exactly one occurrence of p_old in a function body.
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

-- 1. any verified account claims -----------------------------------------------
SELECT pg_temp.exos_patch('public.exos_claim_transfer(uuid)',
  'claimed into any account',
  '  IF v_email = '''' OR lower(tr.receiver_email) <> v_email THEN
    RAISE EXCEPTION ''exos_claim_transfer: transfer addressed to a different email'';
  END IF;',
  '  -- Transfers are claimed into any account (mig 20260927010000): the
  -- receiver email is only where the link was sent. First claim wins.');

-- 2. the "your transfer was claimed" mail -------------------------------------
SELECT pg_temp.exos_patch('public.exos_queue_mail(text, uuid)',
  'owns the ticket through this transfer',
  '      AND lower(trim(t.receiver_email)) = lower(trim(caller.email))',
  '      -- the caller owns the ticket through this transfer (any account can
      -- claim; mig 20260927010000). Marketplace sales: no per-ticket mail.
      AND EXISTS (SELECT 1 FROM public.exos_tickets tk
                   WHERE tk.id = t.ticket_id AND tk.transfer_id = t.id AND tk.owner_id = caller.id)
      AND NOT EXISTS (SELECT 1 FROM public.exos_marketplace_orders mo WHERE t.id = ANY (mo.transfer_ids))');

-- 3. marketplace mail copy ----------------------------------------------------
SELECT pg_temp.exos_patch('public.exos_fulfil_marketplace_order(uuid, text)',
  'any Exos account',
  '          '' been transferred to you on Exos. Sign in with '' || o.buyer_email || '' to claim '' ||
          CASE WHEN o.quantity > 1 THEN ''them'' ELSE ''it'' END ||
          '' and get your entry QR code.</p>'' || v_links,',
  '          '' been transferred to you on Exos. Open a claim link (below, or from your '' || v_label ||
          '' order) and sign in with any Exos account, or create one, to claim '' ||
          CASE WHEN o.quantity > 1 THEN ''them'' ELSE ''it'' END ||
          '' and get your entry QR code.</p>'' || v_links ||
          ''<p>Whoever claims a link first gets that ticket, so keep this email to yourself.</p>'',');

-- 4. claim page preview -------------------------------------------------------
CREATE OR REPLACE FUNCTION public.exos_transfer_claim_preview(p_transfer_id uuid)
RETURNS TABLE (id uuid, status text, event_id uuid, event_title text,
               event_image text, tier_name text, created_at timestamptz)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT tr.id, tr.status::text, tr.event_id, tr.event_title, tr.event_image,
         tr.tier_name, tr.created_at
    FROM public.exos_transfers tr
   WHERE tr.id = p_transfer_id;
$$;
REVOKE ALL ON FUNCTION public.exos_transfer_claim_preview(uuid) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.exos_transfer_claim_preview(uuid) TO anon, authenticated;
