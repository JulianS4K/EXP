-- ============================================================================
-- Migration 20260927010000 — Exos (Bridge / D4): marketplace tickets are
--                            claimed by link, into any Exos account
--
-- Lane:     d4 (exos / bridge ticketing infra)
-- Touches:  W: exos_transfers (+claim_mode)
--              FUNCTION exos_claim_transfer, exos_fulfil_marketplace_order
--                (patched in place)
--              FUNCTION exos_transfer_claim_preview (new)
--           R: exos_transfers
-- Pre-reqs: 20260926193000 (fulfil_marketplace_order), 20260925010000
--
-- Marketplace buyer emails are a mix of the buyer's real address and a relay
-- address the marketplace forwards from. Making the buyer sign in with that
-- exact address to claim was the wrong gate: they should be able to claim
-- into whichever Exos account they already have.
--
-- 1. exos_transfers.claim_mode: 'email' (default; every existing transfer and
--    every Exos-to-Exos transfer; NULL counts as 'email') or 'link'. A friend transfer still has to be
--    claimed by the account whose email it was sent to.
-- 2. exos_claim_transfer: a 'link' transfer is claimed by any verified Exos
--    account that opens the link, first claim wins. Everything else stays as
--    it was: the row locks, the ticket still has to point at this transfer
--    and belong to its sender, the barcode secret rotates, and the ticket
--    moves to the claimer (buyer_email becomes the claimer's email).
-- 3. exos_fulfil_marketplace_order issues 'link' transfers, and its mail says
--    "sign in with any Exos account" instead of naming the order email.
-- 4. exos_transfer_claim_preview: the claim page for a link transfer has to
--    render for someone RLS doesn't let read the row (different email, or not
--    signed in yet). It returns the display fields of a LINK transfer only,
--    with no emails and no ticket id; an email transfer returns nothing.
--
-- The transfer id (a random UUID, only in the claim links sent to the buyer
-- and handed to the marketplace as e-ticket URLs) is the bearer secret.
--
-- Every patch asserts one match and is skipped once applied (re-run safe).
-- D4 authors; applying to prod is operator-gated.
-- ============================================================================

-- Nullable on purpose: several functions insert transfers through
-- jsonb_populate_record, which writes NULL (not the DEFAULT) for keys it
-- isn't given. NULL means 'email'; only an explicit 'link' opens a transfer.
ALTER TABLE public.exos_transfers
  ADD COLUMN IF NOT EXISTS claim_mode text DEFAULT 'email';
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'exos_transfers_claim_mode_chk') THEN
    ALTER TABLE public.exos_transfers
      ADD CONSTRAINT exos_transfers_claim_mode_chk CHECK (claim_mode IN ('email', 'link'));
  END IF;
END $$;
COMMENT ON COLUMN public.exos_transfers.claim_mode IS
  'email (or NULL): only the account with receiver_email can claim (Exos-to-Exos). link: any verified account holding the link (marketplace sales).';

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

-- 2. link transfers skip the email match -------------------------------------
SELECT pg_temp.exos_patch('public.exos_claim_transfer(uuid)',
  'tr.claim_mode',
  '  IF v_email = '''' OR lower(tr.receiver_email) <> v_email THEN',
  '  -- A marketplace (link) transfer goes to whichever verified account opens
  -- the link first; an Exos-to-Exos transfer only to the addressed email.
  IF tr.claim_mode IS DISTINCT FROM ''link''
     AND (v_email = '''' OR lower(tr.receiver_email) <> v_email) THEN');

-- 3. marketplace sales are issued as link transfers ---------------------------
SELECT pg_temp.exos_patch('public.exos_fulfil_marketplace_order(uuid, text)',
  '''claim_mode''',
  '      ''status'', ''pending'', ''event_id'', o.event_id, ''event_title'', v_ev.name,',
  '      ''status'', ''pending'', ''claim_mode'', ''link'', ''event_id'', o.event_id, ''event_title'', v_ev.name,');

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

-- 4. claim page preview for link transfers ------------------------------------
CREATE OR REPLACE FUNCTION public.exos_transfer_claim_preview(p_transfer_id uuid)
RETURNS TABLE (id uuid, status text, claim_mode text, event_id uuid,
               event_title text, event_image text, tier_name text,
               created_at timestamptz)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT tr.id, tr.status::text, tr.claim_mode, tr.event_id,
         tr.event_title, tr.event_image, tr.tier_name, tr.created_at
    FROM public.exos_transfers tr
   WHERE tr.id = p_transfer_id
     AND tr.claim_mode = 'link';
$$;
REVOKE ALL ON FUNCTION public.exos_transfer_claim_preview(uuid) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.exos_transfer_claim_preview(uuid) TO anon, authenticated;
