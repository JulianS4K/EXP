-- ============================================================================
-- Migration 20261001100000 — Exos (Bridge / D4): printable invoices and
--                            receipts, credit notes on refunds, org legal
--                            details, no $0 invoices
--
-- Lane:     d4 (exos / bridge ticketing infra)
-- Touches:  C: TABLE exos_org_legal (new; seller legal details, RLS)
--           C: TABLE exos_credit_notes, exos_credit_note_counters (new, RLS)
--           W: exos_invoices (+seller jsonb snapshot; BEFORE INSERT seller
--              trigger; BEFORE UPDATE guard: the money fields are frozen)
--           W: FUNCTION exos_tg_invoice (patched in place: no invoice for a
--              $0 order; a refund no longer flips status to 'refunded')
--           C: FUNCTION exos_next_credit_note_number(uuid) (service / definer)
--              _exos_org_seller(uuid), _exos_issue_credit_note(uuid)
--              (internal), exos_tg_refund_credit_note (trigger on
--              exos_order_refunds), exos_tg_invoice_seller,
--              exos_tg_invoice_frozen, exos_tg_credit_note_frozen (triggers)
--           C: VIEW exos_invoice_totals (security_invoker: invoice + credited
--              amounts + a derived status for old readers)
--           C: FUNCTION exos_invoice_document(uuid),
--              exos_credit_note_document(uuid), exos_my_invoices()
--              (authenticated; buyer or org owner / manager / finance)
--           R: exos_checkout_sessions, exos_price_disclosure_lines,
--              exos_ticket_tiers, exos_event_addons, exos_order_addons,
--              exos_tax_rules, exos_events, exos_orgs, auth.users,
--              exos_profiles (when present)
-- Pre-reqs: 20260616240000 (exos_invoices + exos_tg_invoice),
--           20260702123100 (exos_order_refunds),
--           20260926070000 (exos_price_disclosure_lines),
--           20260616230000 (exos_tax_rules)
--
-- Money audit 2026-09-30, ERP-lite #4 (credit notes) and #5 (invoice
-- document); #11 (free orders) only as far as "no $0 invoices".
--
-- 1. Seller legal details live in their own table, exos_org_legal, not on
--    exos_orgs: exos_orgs is readable by every member (scanners, content)
--    and its anon column grant feeds exos_public_orgs. The new table is
--    owner / manager / finance only (read and write), never anon.
-- 2. Invoices are immutable. exos_tg_invoice stops overwriting status to
--    'refunded'; a succeeded refund (full or partial) instead issues a
--    credit note with its own gapless per-org series (CN-000001), linked to
--    the invoice and the refund row, with the tax share pro rata to the
--    invoice's tax (the last note takes the remainder, so the notes' tax
--    adds up to the invoice's exactly). exos_invoice_totals derives
--    refunded_cents and a status ('issued' / 'partially_refunded' /
--    'refunded' / 'cancelled') for readers of the old status column
--    (exos-api /invoices). Rows already flipped to 'refunded' stay as they
--    are; their succeeded refunds are backfilled as credit notes.
-- 3. A free order (amount 0) gets no invoice. Existing $0 invoices stay.
-- 4. exos_invoice_document(invoice id) returns everything the printable
--    /invoice/:id page needs (seller, buyer, lines, tax, totals, credit
--    notes); exos_credit_note_document(id) the same plus the note. The buyer
--    (auth.uid() = the invoice's or the session's buyer, or, for a guest
--    checkout, the account whose confirmed email is the order's) and the
--    org's owner / manager / finance may read them.
--
-- Numbering is gapless: the counter row is incremented in the same
-- transaction (and, in the trigger, the same subtransaction) as the insert,
-- so a failure rolls both back. No sequence is involved.
--
-- Re-run safe (IF NOT EXISTS, CREATE OR REPLACE, guarded policies, patches
-- that detect their marker, idempotent backfill).
-- D4 authors; applying to prod is operator-gated.
-- ROLLBACK: DROP FUNCTION exos_invoice_document(uuid),
--   exos_credit_note_document(uuid), exos_my_invoices(); DROP VIEW
--   exos_invoice_totals; DROP TRIGGER exos_order_refunds_credit_note ON
--   exos_order_refunds; DROP TABLE exos_credit_notes,
--   exos_credit_note_counters, exos_org_legal; re-apply 20260616240000's
--   exos_tg_invoice.
-- ============================================================================

-- Patch helper (same as 20260929140000): replace p_old with p_new in the
-- function's definition, exactly p_hits times, unless p_marker is present.
CREATE OR REPLACE FUNCTION pg_temp.exos_patch_n(p_sig text, p_marker text, p_old text, p_new text, p_hits int)
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
  IF v_hits <> p_hits THEN
    RAISE EXCEPTION '%: expected % match(es) for patch "%", found %', p_fn, p_hits, p_marker, v_hits;
  END IF;
  EXECUTE replace(v_def, p_old, p_new);
END $$;

-- ---------------------------------------------------------------------------
-- 1. Seller legal details.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.exos_org_legal (
  org_id         uuid PRIMARY KEY REFERENCES public.exos_orgs (id) ON DELETE CASCADE,
  legal_name     text CHECK (legal_name IS NULL OR char_length(legal_name) <= 200),
  legal_address  text CHECK (legal_address IS NULL OR char_length(legal_address) <= 500),
  tax_id         text CHECK (tax_id IS NULL OR char_length(tax_id) <= 64),
  invoice_footer text CHECK (invoice_footer IS NULL OR char_length(invoice_footer) <= 500),
  updated_at     timestamptz NOT NULL DEFAULT now(),
  updated_by     uuid
);
COMMENT ON TABLE public.exos_org_legal IS
  'Seller details printed on invoices / receipts / credit notes (mig 20261001100000). '
  'Owner / manager / finance read and write; never anon.';

-- Blank → NULL, stamp who changed it.
CREATE OR REPLACE FUNCTION public.exos_tg_org_legal_clean()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
  NEW.legal_name     := nullif(btrim(NEW.legal_name), '');
  NEW.legal_address  := nullif(btrim(NEW.legal_address), '');
  NEW.tax_id         := nullif(btrim(NEW.tax_id), '');
  NEW.invoice_footer := nullif(btrim(NEW.invoice_footer), '');
  NEW.updated_at     := now();
  NEW.updated_by     := coalesce(auth.uid(), NEW.updated_by);
  RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION public.exos_tg_org_legal_clean() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS exos_org_legal_clean ON public.exos_org_legal;
CREATE TRIGGER exos_org_legal_clean BEFORE INSERT OR UPDATE ON public.exos_org_legal
  FOR EACH ROW EXECUTE FUNCTION public.exos_tg_org_legal_clean();

ALTER TABLE public.exos_org_legal ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS exos_org_legal_sel ON public.exos_org_legal;
CREATE POLICY exos_org_legal_sel ON public.exos_org_legal FOR SELECT TO authenticated
  USING (public.exos_has_org_role(org_id, ARRAY['owner','manager','finance']));
DROP POLICY IF EXISTS exos_org_legal_ins ON public.exos_org_legal;
CREATE POLICY exos_org_legal_ins ON public.exos_org_legal FOR INSERT TO authenticated
  WITH CHECK (public.exos_has_org_role(org_id, ARRAY['owner','manager','finance']));
DROP POLICY IF EXISTS exos_org_legal_upd ON public.exos_org_legal;
CREATE POLICY exos_org_legal_upd ON public.exos_org_legal FOR UPDATE TO authenticated
  USING (public.exos_has_org_role(org_id, ARRAY['owner','manager','finance']))
  WITH CHECK (public.exos_has_org_role(org_id, ARRAY['owner','manager','finance']));
REVOKE ALL ON public.exos_org_legal FROM PUBLIC, anon, authenticated;
GRANT SELECT, INSERT, UPDATE ON public.exos_org_legal TO authenticated;
GRANT ALL ON public.exos_org_legal TO service_role;

-- The seller block as printed today (org name + legal details). Internal.
CREATE OR REPLACE FUNCTION public._exos_org_seller(p_org_id uuid)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT jsonb_build_object(
           'name', o.name,
           'legal_name', l.legal_name,
           'legal_address', l.legal_address,
           'tax_id', l.tax_id,
           'invoice_footer', l.invoice_footer)
    FROM public.exos_orgs o
    LEFT JOIN public.exos_org_legal l ON l.org_id = o.id
   WHERE o.id = p_org_id;
$$;
REVOKE ALL ON FUNCTION public._exos_org_seller(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_org_seller(uuid) TO service_role;

-- ---------------------------------------------------------------------------
-- 2. Invoices: a seller snapshot at issue, and the money fields frozen.
-- ---------------------------------------------------------------------------
ALTER TABLE public.exos_invoices ADD COLUMN IF NOT EXISTS seller jsonb;
COMMENT ON COLUMN public.exos_invoices.seller IS
  'Seller block (org name + exos_org_legal) as it was when the invoice was issued (mig 20261001100000). NULL on older invoices: the document shows the current details.';

CREATE OR REPLACE FUNCTION public.exos_tg_invoice_seller()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
  IF NEW.seller IS NULL THEN
    NEW.seller := public._exos_org_seller(NEW.org_id);
  END IF;
  RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION public.exos_tg_invoice_seller() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS exos_invoices_seller ON public.exos_invoices;
CREATE TRIGGER exos_invoices_seller BEFORE INSERT ON public.exos_invoices
  FOR EACH ROW EXECUTE FUNCTION public.exos_tg_invoice_seller();

-- An issued invoice's number and amounts never change. buyer_email may be
-- cleared (account deletion, mig 20260926010000), status may still be set to
-- 'cancelled' by an operator, and a missing seller snapshot may be filled.
CREATE OR REPLACE FUNCTION public.exos_tg_invoice_frozen()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
  IF NEW.number IS DISTINCT FROM OLD.number
     OR NEW.org_id IS DISTINCT FROM OLD.org_id
     OR NEW.session_id IS DISTINCT FROM OLD.session_id
     OR NEW.currency IS DISTINCT FROM OLD.currency
     OR NEW.subtotal_cents IS DISTINCT FROM OLD.subtotal_cents
     OR NEW.tax_cents IS DISTINCT FROM OLD.tax_cents
     OR NEW.total_cents IS DISTINCT FROM OLD.total_cents
     OR NEW.issued_at IS DISTINCT FROM OLD.issued_at
     OR (OLD.seller IS NOT NULL AND NEW.seller IS DISTINCT FROM OLD.seller) THEN
    RAISE EXCEPTION 'exos_invoices: an issued invoice can''t be changed; issue a credit note'
      USING ERRCODE = '55000';
  END IF;
  RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION public.exos_tg_invoice_frozen() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS exos_invoices_frozen ON public.exos_invoices;
CREATE TRIGGER exos_invoices_frozen BEFORE UPDATE ON public.exos_invoices
  FOR EACH ROW EXECUTE FUNCTION public.exos_tg_invoice_frozen();

-- exos_tg_invoice, patched in place (the fulfilment branch is otherwise
-- unchanged): no invoice for a $0 order, and none (so no number used up)
-- when the order already has one ...
SELECT pg_temp.exos_patch_n('public.exos_tg_invoice()',
  'no $0 invoices',
  '  IF NEW.status = ''fulfilled'' AND OLD.status IS DISTINCT FROM ''fulfilled'' THEN',
  '  IF NEW.status = ''fulfilled'' AND OLD.status IS DISTINCT FROM ''fulfilled''
     AND coalesce(NEW.amount_cents, 0) > 0  -- no $0 invoices (mig 20261001100000)
     -- An order fulfilled a second time must not take (and waste) a number.
     AND NOT EXISTS (SELECT 1 FROM public.exos_invoices i WHERE i.session_id = NEW.session_id) THEN',
  1);
-- ... and a refund leaves the invoice alone (credit notes, section 3).
SELECT pg_temp.exos_patch_n('public.exos_tg_invoice()',
  'refunds get credit notes',
  '    UPDATE public.exos_invoices SET status = ''refunded'' WHERE session_id = NEW.session_id;',
  '    NULL;  -- invoices stay immutable: refunds get credit notes (mig 20261001100000)',
  1);

-- ---------------------------------------------------------------------------
-- 3. Credit notes.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.exos_credit_note_counters (
  org_id   uuid PRIMARY KEY REFERENCES public.exos_orgs (id) ON DELETE CASCADE,
  next_seq integer NOT NULL DEFAULT 1 CHECK (next_seq >= 1)
);
ALTER TABLE public.exos_credit_note_counters ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.exos_credit_note_counters FROM PUBLIC, anon, authenticated;
GRANT ALL ON public.exos_credit_note_counters TO service_role;

CREATE TABLE IF NOT EXISTS public.exos_credit_notes (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id       uuid NOT NULL REFERENCES public.exos_orgs (id) ON DELETE CASCADE,
  invoice_id   uuid NOT NULL REFERENCES public.exos_invoices (id) ON DELETE CASCADE,
  refund_id    uuid UNIQUE REFERENCES public.exos_order_refunds (id) ON DELETE SET NULL,
  event_id     uuid,
  session_id   text,
  number       text NOT NULL CHECK (number ~ '^CN-[0-9]{6,}$'),
  amount_cents integer NOT NULL CHECK (amount_cents > 0),
  tax_cents    integer NOT NULL DEFAULT 0 CHECK (tax_cents >= 0 AND tax_cents <= amount_cents),
  currency     text NOT NULL DEFAULT 'usd',
  reason       text CHECK (reason IS NULL OR char_length(reason) <= 500),
  seller       jsonb,
  created_at   timestamptz NOT NULL DEFAULT now(),
  UNIQUE (org_id, number)
);
CREATE INDEX IF NOT EXISTS exos_credit_notes_invoice_idx ON public.exos_credit_notes (invoice_id);
CREATE INDEX IF NOT EXISTS exos_credit_notes_event_idx   ON public.exos_credit_notes (event_id);
COMMENT ON TABLE public.exos_credit_notes IS
  'Credit notes (mig 20261001100000): one per succeeded exos_order_refunds row on an invoiced order, '
  'numbered CN-000001 per org (exos_next_credit_note_number, gapless). Tax share pro rata to the invoice. Immutable.';

ALTER TABLE public.exos_credit_notes ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS exos_credit_notes_sel ON public.exos_credit_notes;
CREATE POLICY exos_credit_notes_sel ON public.exos_credit_notes FOR SELECT TO authenticated
  USING (public.exos_has_org_role(org_id, ARRAY['owner','manager','finance'])
         OR EXISTS (SELECT 1 FROM public.exos_invoices i
                     WHERE i.id = invoice_id AND i.buyer_id = auth.uid()));
REVOKE ALL ON public.exos_credit_notes FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.exos_credit_notes TO authenticated;
GRANT ALL ON public.exos_credit_notes TO service_role;

-- Only refund_id may change (ON DELETE SET NULL when the refund row goes).
CREATE OR REPLACE FUNCTION public.exos_tg_credit_note_frozen()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
  IF (to_jsonb(NEW) - 'refund_id') IS DISTINCT FROM (to_jsonb(OLD) - 'refund_id') THEN
    RAISE EXCEPTION 'exos_credit_notes: a credit note can''t be changed' USING ERRCODE = '55000';
  END IF;
  RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION public.exos_tg_credit_note_frozen() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS exos_credit_notes_frozen ON public.exos_credit_notes;
CREATE TRIGGER exos_credit_notes_frozen BEFORE UPDATE ON public.exos_credit_notes
  FOR EACH ROW EXECUTE FUNCTION public.exos_tg_credit_note_frozen();

-- Atomic next number per org (row lock on the counter serialises an org).
CREATE OR REPLACE FUNCTION public.exos_next_credit_note_number(p_org_id uuid)
RETURNS text LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_seq integer;
BEGIN
  INSERT INTO public.exos_credit_note_counters (org_id, next_seq) VALUES (p_org_id, 2)
  ON CONFLICT (org_id) DO UPDATE SET next_seq = public.exos_credit_note_counters.next_seq + 1
  RETURNING next_seq - 1 INTO v_seq;
  RETURN 'CN-' || lpad(v_seq::text, 6, '0');
END $$;
REVOKE ALL ON FUNCTION public.exos_next_credit_note_number(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_next_credit_note_number(uuid) TO service_role;

-- Issue the credit note for one succeeded refund row. Idempotent (one per
-- refund); no-op for an order without an invoice (free, or before
-- invoicing) or an invoice already fully credited. The amount is capped at
-- what's left on the invoice. Returns the note id or NULL.
CREATE OR REPLACE FUNCTION public._exos_issue_credit_note(p_refund_id uuid)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  r      public.exos_order_refunds%ROWTYPE;
  inv    public.exos_invoices%ROWTYPE;
  v_id   uuid;
  v_amt_before int;
  v_tax_before int;
  v_left int;
  v_amt  int;
  v_tax  int;
BEGIN
  SELECT * INTO r FROM public.exos_order_refunds WHERE id = p_refund_id;
  IF r.id IS NULL OR r.status <> 'succeeded' OR coalesce(r.amount_cents, 0) <= 0 THEN
    RETURN NULL;
  END IF;
  SELECT id INTO v_id FROM public.exos_credit_notes WHERE refund_id = r.id;
  IF v_id IS NOT NULL THEN RETURN v_id; END IF;

  -- Lock the invoice: concurrent refunds on one order are credited in turn.
  SELECT * INTO inv FROM public.exos_invoices WHERE session_id = r.session_id FOR UPDATE;
  IF inv.id IS NULL OR inv.total_cents <= 0 THEN RETURN NULL; END IF;

  SELECT coalesce(sum(amount_cents), 0), coalesce(sum(tax_cents), 0)
    INTO v_amt_before, v_tax_before
    FROM public.exos_credit_notes WHERE invoice_id = inv.id;
  v_left := inv.total_cents - v_amt_before;
  IF v_left <= 0 THEN RETURN NULL; END IF;

  v_amt := least(r.amount_cents, v_left);
  IF v_amt = v_left THEN
    -- The last note takes the remaining tax, so the notes add up exactly.
    v_tax := inv.tax_cents - v_tax_before;
  ELSE
    v_tax := round(inv.tax_cents::numeric * v_amt / inv.total_cents)::int;
    v_tax := least(v_tax, inv.tax_cents - v_tax_before);
  END IF;
  v_tax := greatest(least(v_tax, v_amt), 0);

  INSERT INTO public.exos_credit_notes (org_id, invoice_id, refund_id, event_id, session_id, number,
              amount_cents, tax_cents, currency, reason, seller)
  VALUES (inv.org_id, inv.id, r.id, inv.event_id, inv.session_id,
          public.exos_next_credit_note_number(inv.org_id),
          v_amt, v_tax, inv.currency, left(r.reason, 500), public._exos_org_seller(inv.org_id))
  RETURNING id INTO v_id;
  RETURN v_id;
END $$;
REVOKE ALL ON FUNCTION public._exos_issue_credit_note(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_issue_credit_note(uuid) TO service_role;

-- On every refund row that reaches 'succeeded'. A problem here never blocks
-- recording the refund (Stripe has already moved the money); it is logged
-- and the subtransaction (counter included) rolls back, so no number is lost.
CREATE OR REPLACE FUNCTION public.exos_tg_refund_credit_note()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
  IF NEW.status <> 'succeeded' OR (TG_OP = 'UPDATE' AND OLD.status = 'succeeded') THEN
    RETURN NEW;
  END IF;
  BEGIN
    PERFORM public._exos_issue_credit_note(NEW.id);
  EXCEPTION WHEN others THEN
    RAISE WARNING 'exos_tg_refund_credit_note: refund %: % (%)', NEW.id, SQLERRM, SQLSTATE;
  END;
  RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION public.exos_tg_refund_credit_note() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS exos_order_refunds_credit_note ON public.exos_order_refunds;
CREATE TRIGGER exos_order_refunds_credit_note AFTER INSERT OR UPDATE OF status ON public.exos_order_refunds
  FOR EACH ROW EXECUTE FUNCTION public.exos_tg_refund_credit_note();

-- Backfill: succeeded refunds on invoiced orders, oldest first (idempotent).
DO $$
DECLARE r record;
BEGIN
  FOR r IN
    SELECT f.id FROM public.exos_order_refunds f
     WHERE f.status = 'succeeded'
       AND NOT EXISTS (SELECT 1 FROM public.exos_credit_notes c WHERE c.refund_id = f.id)
       AND EXISTS (SELECT 1 FROM public.exos_invoices i WHERE i.session_id = f.session_id)
     ORDER BY f.created_at, f.id
  LOOP
    PERFORM public._exos_issue_credit_note(r.id);
  END LOOP;
END $$;

-- ---------------------------------------------------------------------------
-- 4. Derived totals for readers (RLS of the base tables applies).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW public.exos_invoice_totals WITH (security_invoker = true) AS
  SELECT i.id, i.org_id, i.event_id, i.number, i.session_id, i.buyer_id, i.buyer_email, i.currency,
         i.subtotal_cents, i.tax_cents, i.total_cents, i.issued_at,
         coalesce(c.amount, 0)::int AS refunded_cents,
         coalesce(c.tax, 0)::int    AS refunded_tax_cents,
         (i.total_cents - coalesce(c.amount, 0))::int AS net_cents,
         coalesce(c.n, 0)::int      AS credit_notes,
         CASE WHEN i.status = 'cancelled' THEN 'cancelled'
              WHEN i.status = 'refunded' OR (i.total_cents > 0 AND coalesce(c.amount, 0) >= i.total_cents) THEN 'refunded'
              WHEN coalesce(c.amount, 0) > 0 THEN 'partially_refunded'
              ELSE 'issued' END AS status
    FROM public.exos_invoices i
    LEFT JOIN LATERAL (
      SELECT sum(cn.amount_cents) AS amount, sum(cn.tax_cents) AS tax, count(*) AS n
        FROM public.exos_credit_notes cn WHERE cn.invoice_id = i.id
    ) c ON true;
COMMENT ON VIEW public.exos_invoice_totals IS
  'exos_invoices + credited amounts (exos_credit_notes) and a derived status; security_invoker (mig 20261001100000).';
REVOKE ALL ON public.exos_invoice_totals FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.exos_invoice_totals TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 5. The document RPCs.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.exos_invoice_document(p_invoice_id uuid)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_uid    uuid := auth.uid();
  v_email  text;
  inv      public.exos_invoices%ROWTYPE;
  s        public.exos_checkout_sessions%ROWTYPE;
  v_staff  boolean;
  v_buyer  boolean;
  v_lines  jsonb;
  v_addons int := 0;
  v_name   text;
  v_event  jsonb;
  v_notes  jsonb;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'exos_invoice_document: not authenticated' USING ERRCODE = '42501';
  END IF;
  SELECT * INTO inv FROM public.exos_invoices WHERE id = p_invoice_id;
  IF inv.id IS NOT NULL AND inv.session_id IS NOT NULL THEN
    SELECT * INTO s FROM public.exos_checkout_sessions WHERE session_id = inv.session_id;
  END IF;
  v_staff := inv.id IS NOT NULL AND public.exos_has_org_role(inv.org_id, ARRAY['owner','manager','finance']);
  IF inv.id IS NOT NULL AND NOT v_staff THEN
    SELECT lower(u.email) INTO v_email FROM auth.users u WHERE u.id = v_uid AND u.email_confirmed_at IS NOT NULL;
    v_buyer := inv.buyer_id = v_uid
            OR s.buyer_uid = v_uid
            OR (inv.buyer_id IS NULL AND s.buyer_uid IS NULL AND v_email IS NOT NULL
                AND lower(coalesce(s.buyer_email, inv.buyer_email)) = v_email);
  END IF;
  -- Same answer for "no such invoice" and "not yours": no existence oracle.
  IF inv.id IS NULL OR NOT (v_staff OR coalesce(v_buyer, false)) THEN
    RAISE EXCEPTION 'exos_invoice_document: not found' USING ERRCODE = '42501';
  END IF;

  -- Lines: what the buyer was shown at checkout (price disclosure record),
  -- with each line's tax rule for the per-rate breakdown.
  SELECT jsonb_agg(jsonb_build_object(
           'kind', l.kind, 'name', l.item_name, 'quantity', l.quantity,
           'unit_cents', l.unit_all_in_cents, 'total_cents', l.line_total_cents,
           'tax_cents', l.tax_cents, 'tax_included', l.tax_included,
           'tax_name', r.name, 'tax_rate', r.rate_percent)
           ORDER BY l.line_no)
    INTO v_lines
    FROM public.exos_price_disclosure_lines l
    LEFT JOIN public.exos_ticket_tiers tt ON l.kind = 'ticket' AND tt.id = l.item_id
    LEFT JOIN public.exos_event_addons ea ON l.kind = 'addon' AND ea.id = l.item_id
    LEFT JOIN public.exos_tax_rules r ON r.id = coalesce(tt.tax_rate_id, ea.tax_rate_id)
   WHERE l.session_id = inv.session_id;

  -- Older orders (no disclosure record): the tier line and the add-ons from
  -- the order; tax per line unknown (the document shows the invoice's tax).
  IF v_lines IS NULL AND s.session_id IS NOT NULL THEN
    SELECT coalesce(sum(round(a.unit_price_paid * 100) * a.quantity), 0)::int INTO v_addons
      FROM public.exos_order_addons a WHERE a.order_ref = s.session_id;
    SELECT jsonb_build_array(jsonb_build_object(
             'kind', 'ticket', 'name', coalesce(t.name, 'Ticket'), 'quantity', greatest(s.quantity, 1),
             'unit_cents', round(greatest(s.amount_cents - v_addons, 0)::numeric / greatest(s.quantity, 1))::int,
             'total_cents', greatest(s.amount_cents - v_addons, 0),
             'tax_cents', NULL, 'tax_included', NULL, 'tax_name', NULL, 'tax_rate', NULL))
      INTO v_lines
      FROM (SELECT 1) one LEFT JOIN public.exos_ticket_tiers t ON t.id = s.tier_id;
    v_lines := v_lines || coalesce((
      SELECT jsonb_agg(jsonb_build_object(
               'kind', 'addon', 'name', coalesce(a.addon_name, 'Add-on'), 'quantity', a.quantity,
               'unit_cents', round(a.unit_price_paid * 100)::int,
               'total_cents', (round(a.unit_price_paid * 100) * a.quantity)::int,
               'tax_cents', NULL, 'tax_included', NULL, 'tax_name', NULL, 'tax_rate', NULL)
               ORDER BY a.created_at, a.id)
        FROM public.exos_order_addons a WHERE a.order_ref = s.session_id), '[]'::jsonb);
  END IF;

  -- Buyer name: the account's display name, when the profile table exists.
  IF coalesce(inv.buyer_id, s.buyer_uid) IS NOT NULL AND to_regclass('public.exos_profiles') IS NOT NULL THEN
    EXECUTE 'SELECT nullif(btrim(display_name), '''') FROM public.exos_profiles WHERE id = $1'
      INTO v_name USING coalesce(inv.buyer_id, s.buyer_uid);
  END IF;

  SELECT jsonb_build_object('id', e.id, 'name', e.name, 'starts_at', e.starts_at,
                            'timezone', e.timezone, 'venue_name', e.venue_name)
    INTO v_event FROM public.exos_events e WHERE e.id = inv.event_id;

  SELECT coalesce(jsonb_agg(jsonb_build_object(
           'id', c.id, 'number', c.number, 'amount_cents', c.amount_cents, 'tax_cents', c.tax_cents,
           'currency', c.currency, 'reason', c.reason, 'created_at', c.created_at)
           ORDER BY c.created_at, c.number), '[]'::jsonb)
    INTO v_notes FROM public.exos_credit_notes c WHERE c.invoice_id = inv.id;

  RETURN jsonb_build_object(
    'invoice', jsonb_build_object(
      'id', inv.id, 'number', inv.number, 'issued_at', inv.issued_at, 'currency', inv.currency,
      'subtotal_cents', inv.subtotal_cents, 'tax_cents', inv.tax_cents, 'total_cents', inv.total_cents,
      'status', inv.status, 'session_id', inv.session_id),
    'seller', coalesce(inv.seller, public._exos_org_seller(inv.org_id)),
    'buyer', jsonb_build_object('name', v_name, 'email', coalesce(inv.buyer_email, s.buyer_email)),
    'event', v_event,
    'order', jsonb_build_object('session_id', inv.session_id, 'paid_at', s.fulfilled_at, 'quantity', s.quantity),
    'lines', coalesce(v_lines, '[]'::jsonb),
    'credit_notes', v_notes,
    'viewer', CASE WHEN v_staff THEN 'org' ELSE 'buyer' END);
END $$;
REVOKE ALL ON FUNCTION public.exos_invoice_document(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_invoice_document(uuid) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.exos_credit_note_document(p_credit_note_id uuid)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE c public.exos_credit_notes%ROWTYPE;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'exos_credit_note_document: not authenticated' USING ERRCODE = '42501';
  END IF;
  SELECT * INTO c FROM public.exos_credit_notes WHERE id = p_credit_note_id;
  IF c.id IS NULL THEN
    RAISE EXCEPTION 'exos_invoice_document: not found' USING ERRCODE = '42501';
  END IF;
  -- The invoice's access check decides; the note's own seller snapshot wins.
  RETURN public.exos_invoice_document(c.invoice_id)
    || jsonb_build_object('credit_note', jsonb_build_object(
         'id', c.id, 'number', c.number, 'amount_cents', c.amount_cents, 'tax_cents', c.tax_cents,
         'currency', c.currency, 'reason', c.reason, 'created_at', c.created_at))
    || CASE WHEN c.seller IS NOT NULL THEN jsonb_build_object('seller', c.seller) ELSE '{}'::jsonb END;
END $$;
REVOKE ALL ON FUNCTION public.exos_credit_note_document(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_credit_note_document(uuid) TO authenticated, service_role;

-- The caller's invoices (My Tickets "Receipt" links): as buyer of the
-- invoice or its session, or a guest checkout to the caller's confirmed email.
CREATE OR REPLACE FUNCTION public.exos_my_invoices()
RETURNS TABLE (id uuid, number text, session_id text, event_id uuid, total_cents int,
               currency text, issued_at timestamptz, refunded_cents int)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_uid   uuid := auth.uid();
  v_email text;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'exos_my_invoices: not authenticated' USING ERRCODE = '42501';
  END IF;
  SELECT lower(u.email) INTO v_email FROM auth.users u WHERE u.id = v_uid AND u.email_confirmed_at IS NOT NULL;
  RETURN QUERY
  SELECT i.id, i.number, i.session_id, i.event_id, i.total_cents, i.currency, i.issued_at,
         coalesce((SELECT sum(c.amount_cents) FROM public.exos_credit_notes c WHERE c.invoice_id = i.id), 0)::int
    FROM public.exos_invoices i
    LEFT JOIN public.exos_checkout_sessions s ON s.session_id = i.session_id
   WHERE i.buyer_id = v_uid
      OR s.buyer_uid = v_uid
      OR (i.buyer_id IS NULL AND s.buyer_uid IS NULL AND v_email IS NOT NULL
          AND lower(coalesce(s.buyer_email, i.buyer_email)) = v_email)
   ORDER BY i.issued_at DESC
   LIMIT 500;
END $$;
REVOKE ALL ON FUNCTION public.exos_my_invoices() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_my_invoices() TO authenticated;
