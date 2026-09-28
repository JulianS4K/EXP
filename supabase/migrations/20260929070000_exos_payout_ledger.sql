-- ============================================================================
-- Migration 20260929070000 — Exos (Bridge / D4): marketplace payout ledger
--
-- Lane:     d4 (exos / bridge ticketing infra)
-- Touches:  C: TABLE exos_marketplace_remittances, exos_remittance_allocations,
--              exos_org_payouts, exos_org_payout_lines;
--              VIEW exos_marketplace_order_money;
--              FUNCTION exos_record_remittance, exos_confirm_remittance,
--              exos_plan_org_payouts, exos_mark_org_payout,
--              exos_cancel_org_payout
-- Pre-reqs: 20260929062000 (exos_fee, organizer_net on marketplace orders)
--
-- Exos checkouts pay the organizer directly (Stripe destination charges).
-- Marketplace sales don't: the marketplace pays Exos, usually about a week
-- after the event, and Exos pays the organizer what's theirs
-- (exos_marketplace_orders.organizer_net = payout - Exos fee). This is that
-- bookkeeping:
--
--   remittance     money a marketplace says it paid (API, statement or a
--                  person), allocated to the orders it covers. It counts for
--                  payouts only once CONFIRMED: TEvo marks an EvoPay payment
--                  "completed" when it's applied to the order, before any
--                  cash moves, so a reported payment isn't money yet.
--   payable        an order whose tickets were delivered and whose proceeds
--                  are covered by confirmed remittances.
--   payout         one planned payment to an org: its payable orders'
--                  organizer_net, less clawbacks. At most one open (planned
--                  or sending) payout per org and currency.
--   clawback       an order the marketplace cancelled after the organizer
--                  was paid: minus what was paid, taken off the next payout.
--                  A payout that would come to zero or less isn't made; the
--                  balance carries forward.
--
-- Sending the money (a Stripe Connect transfer from the platform balance to
-- the org's connected account) is exos-payouts, dry-run unless the operator
-- turns it on (EXOS_PAYOUTS_LIVE). Organizers read their payouts, lines and
-- the per-order money view; everything else is service role.
--
-- Re-run safe (IF NOT EXISTS / CREATE OR REPLACE / DROP POLICY IF EXISTS).
-- D4 authors; applying to prod is operator-gated.
-- ============================================================================

CREATE TABLE IF NOT EXISTS public.exos_marketplace_remittances (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  channel      text NOT NULL,
  external_id  text NOT NULL,
  amount       numeric(12,2) NOT NULL,
  currency     text NOT NULL DEFAULT 'USD',
  received_at  timestamptz,
  reference    text,
  source       text NOT NULL CHECK (source IN ('marketplace_api', 'statement', 'manual')),
  confirmed    boolean NOT NULL DEFAULT false,
  confirmed_at timestamptz,
  confirmed_by uuid,
  note         text,
  raw          jsonb,
  created_at   timestamptz NOT NULL DEFAULT now(),
  updated_at   timestamptz NOT NULL DEFAULT now(),
  UNIQUE (channel, external_id)
);

CREATE TABLE IF NOT EXISTS public.exos_remittance_allocations (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  remittance_id uuid NOT NULL REFERENCES public.exos_marketplace_remittances (id) ON DELETE CASCADE,
  order_id      uuid NOT NULL REFERENCES public.exos_marketplace_orders (id) ON DELETE CASCADE,
  amount        numeric(12,2) NOT NULL,
  created_at    timestamptz NOT NULL DEFAULT now(),
  UNIQUE (remittance_id, order_id)
);
CREATE INDEX IF NOT EXISTS exos_remittance_allocations_order_idx ON public.exos_remittance_allocations (order_id);

CREATE TABLE IF NOT EXISTS public.exos_org_payouts (
  id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id             uuid NOT NULL REFERENCES public.exos_orgs (id) ON DELETE CASCADE,
  currency           text NOT NULL DEFAULT 'USD',
  amount             numeric(12,2) NOT NULL CHECK (amount > 0),
  status             text NOT NULL DEFAULT 'planned'
                       CHECK (status IN ('planned', 'sending', 'sent', 'failed', 'cancelled')),
  stripe_transfer_id text,
  idempotency_key    text NOT NULL UNIQUE,
  error              text,
  created_at         timestamptz NOT NULL DEFAULT now(),
  updated_at         timestamptz NOT NULL DEFAULT now(),
  sent_at            timestamptz
);
CREATE UNIQUE INDEX IF NOT EXISTS exos_org_payouts_one_open
  ON public.exos_org_payouts (org_id, currency) WHERE status IN ('planned', 'sending');

CREATE TABLE IF NOT EXISTS public.exos_org_payout_lines (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  payout_id  uuid NOT NULL REFERENCES public.exos_org_payouts (id) ON DELETE CASCADE,
  org_id     uuid NOT NULL,
  order_id   uuid NOT NULL REFERENCES public.exos_marketplace_orders (id) ON DELETE RESTRICT,
  kind       text NOT NULL CHECK (kind IN ('sale', 'clawback')),
  amount     numeric(12,2) NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  -- An order is paid once, and clawed back at most once.
  UNIQUE (order_id, kind)
);
CREATE INDEX IF NOT EXISTS exos_org_payout_lines_payout_idx ON public.exos_org_payout_lines (payout_id);

-- RLS: organizers (owner / manager / finance) read their payouts and lines;
-- remittances are Exos's own books, service role only.
ALTER TABLE public.exos_marketplace_remittances ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.exos_remittance_allocations ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.exos_org_payouts ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.exos_org_payout_lines ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.exos_marketplace_remittances, public.exos_remittance_allocations,
              public.exos_org_payouts, public.exos_org_payout_lines FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.exos_org_payouts, public.exos_org_payout_lines TO authenticated;
GRANT ALL ON public.exos_marketplace_remittances, public.exos_remittance_allocations,
             public.exos_org_payouts, public.exos_org_payout_lines TO service_role;
DROP POLICY IF EXISTS exos_org_payouts_sel ON public.exos_org_payouts;
CREATE POLICY exos_org_payouts_sel ON public.exos_org_payouts FOR SELECT TO authenticated
  USING (public.exos_is_admin() OR public.exos_has_org_role(org_id, ARRAY['owner','manager','finance']));
DROP POLICY IF EXISTS exos_org_payout_lines_sel ON public.exos_org_payout_lines;
CREATE POLICY exos_org_payout_lines_sel ON public.exos_org_payout_lines FOR SELECT TO authenticated
  USING (public.exos_is_admin() OR public.exos_has_org_role(org_id, ARRAY['owner','manager','finance']));

-- Where each marketplace order's money stands. security_invoker: organizers
-- see their own orders (exos_marketplace_orders RLS), service role sees all.
CREATE OR REPLACE VIEW public.exos_marketplace_order_money WITH (security_invoker = true) AS
  SELECT o.id AS order_id, o.org_id, o.event_id, o.channel, o.external_order_id, o.quantity,
         upper(coalesce(o.currency, 'USD')) AS currency,
         o.proceeds, o.exos_fee, o.organizer_net,
         coalesce(r.confirmed, 0) AS received,
         coalesce(r.reported, 0) AS reported,
         s.amount AS paid_amount, s.payout_status,
         c.amount AS clawback_amount,
         CASE
           WHEN o.status = 'cancelled' OR o.sale_status = 'cancelled' THEN
             CASE WHEN s.payout_status IN ('sent', 'sending', 'planned') AND c.amount IS NULL THEN 'clawback_due'
                  WHEN c.amount IS NOT NULL THEN 'clawed_back'
                  ELSE 'cancelled' END
           WHEN s.payout_status = 'sent' THEN 'paid'
           WHEN s.payout_status IN ('planned', 'sending') THEN 'in_payout'
           WHEN o.status NOT IN ('fulfilled', 'delivered') THEN 'awaiting_delivery'
           WHEN o.organizer_net IS NULL THEN 'needs_price'
           WHEN coalesce(r.confirmed, 0) < o.proceeds - 0.01 THEN
             CASE WHEN coalesce(r.reported, 0) >= o.proceeds - 0.01 THEN 'reported_unconfirmed' ELSE 'awaiting_marketplace' END
           ELSE 'payable'
         END AS state
    FROM public.exos_marketplace_orders o
    LEFT JOIN LATERAL (
      SELECT sum(a.amount) FILTER (WHERE m.confirmed) AS confirmed, sum(a.amount) AS reported
        FROM public.exos_remittance_allocations a
        JOIN public.exos_marketplace_remittances m ON m.id = a.remittance_id
       WHERE a.order_id = o.id) r ON true
    LEFT JOIN LATERAL (
      SELECT l.amount, p.status AS payout_status
        FROM public.exos_org_payout_lines l JOIN public.exos_org_payouts p ON p.id = l.payout_id
       WHERE l.order_id = o.id AND l.kind = 'sale') s ON true
    LEFT JOIN LATERAL (
      SELECT l.amount FROM public.exos_org_payout_lines l
       WHERE l.order_id = o.id AND l.kind = 'clawback') c ON true;
REVOKE ALL ON public.exos_marketplace_order_money FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.exos_marketplace_order_money TO authenticated, service_role;

-- Record what a marketplace paid, and which orders it covers.
--   p = { channel, external_id, amount, currency?, received_at?, reference?,
--         source, note?, raw?, allocations: [{ external_order_id, amount }] }
-- Idempotent on (channel, external_id). A confirmed remittance is never
-- changed; an unconfirmed one takes the new amount and allocations. Returns
-- { remittance_id, allocated, unmatched: [external_order_id…], confirmed }.
CREATE OR REPLACE FUNCTION public.exos_record_remittance(p jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  v_id uuid; v_confirmed boolean; a jsonb; v_order uuid; v_amt numeric;
  v_alloc int := 0; v_unmatched text[] := '{}';
BEGIN
  IF coalesce(p ->> 'channel', '') = '' OR coalesce(p ->> 'external_id', '') = '' THEN
    RAISE EXCEPTION 'exos_record_remittance: channel and external_id are required';
  END IF;
  IF (p ->> 'amount') IS NULL OR (p ->> 'amount') !~ '^-?[0-9]+(\.[0-9]+)?$' THEN
    RAISE EXCEPTION 'exos_record_remittance: amount must be a number';
  END IF;
  SELECT id, confirmed INTO v_id, v_confirmed FROM public.exos_marketplace_remittances
   WHERE channel = p ->> 'channel' AND external_id = p ->> 'external_id';
  IF v_confirmed THEN
    RETURN jsonb_build_object('remittance_id', v_id, 'allocated', 0, 'unmatched', '[]'::jsonb, 'confirmed', true);
  END IF;
  INSERT INTO public.exos_marketplace_remittances AS r
    (channel, external_id, amount, currency, received_at, reference, source, note, raw)
  VALUES (p ->> 'channel', p ->> 'external_id', round((p ->> 'amount')::numeric, 2),
          upper(coalesce(nullif(p ->> 'currency', ''), 'USD')), public.exos_try_timestamptz(p ->> 'received_at'),
          left(p ->> 'reference', 200), coalesce(p ->> 'source', 'manual'), left(p ->> 'note', 500), p -> 'raw')
  ON CONFLICT (channel, external_id) DO UPDATE
    SET amount = EXCLUDED.amount, currency = EXCLUDED.currency, received_at = EXCLUDED.received_at,
        reference = EXCLUDED.reference, note = EXCLUDED.note, raw = EXCLUDED.raw, updated_at = now()
  RETURNING id INTO v_id;
  DELETE FROM public.exos_remittance_allocations WHERE remittance_id = v_id;
  FOR a IN SELECT * FROM jsonb_array_elements(coalesce(p -> 'allocations', '[]'::jsonb)) LOOP
    SELECT id INTO v_order FROM public.exos_marketplace_orders
     WHERE channel = p ->> 'channel' AND external_order_id = a ->> 'external_order_id';
    IF v_order IS NULL OR (a ->> 'amount') IS NULL OR (a ->> 'amount') !~ '^-?[0-9]+(\.[0-9]+)?$' THEN
      v_unmatched := v_unmatched || coalesce(a ->> 'external_order_id', '(none)');
      CONTINUE;
    END IF;
    v_amt := round((a ->> 'amount')::numeric, 2);
    INSERT INTO public.exos_remittance_allocations (remittance_id, order_id, amount)
    VALUES (v_id, v_order, v_amt)
    ON CONFLICT (remittance_id, order_id) DO UPDATE SET amount = public.exos_remittance_allocations.amount + EXCLUDED.amount;
    v_alloc := v_alloc + 1;
  END LOOP;
  RETURN jsonb_build_object('remittance_id', v_id, 'allocated', v_alloc, 'unmatched', to_jsonb(v_unmatched), 'confirmed', false);
END $$;

-- A person (or a bank / Stripe balance check) confirms the money arrived.
CREATE OR REPLACE FUNCTION public.exos_confirm_remittance(p_id uuid, p_by uuid DEFAULT NULL)
RETURNS boolean LANGUAGE sql SECURITY DEFINER SET search_path = public, pg_temp AS $$
  UPDATE public.exos_marketplace_remittances
     SET confirmed = true, confirmed_at = now(), confirmed_by = p_by, updated_at = now()
   WHERE id = p_id AND NOT confirmed
  RETURNING true;
$$;

-- Plan one payout per org (and currency) from its payable orders, less any
-- clawbacks. Skips orgs with a payout already open, and totals of zero or
-- less (the balance carries forward). Returns the payouts made.
CREATE OR REPLACE FUNCTION public.exos_plan_org_payouts(p_org uuid DEFAULT NULL)
RETURNS TABLE (payout_id uuid, org_id uuid, currency text, amount numeric, sale_lines int, clawback_lines int)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE g record; v_payout uuid; v_sales int; v_claws int;
BEGIN
  FOR g IN
    WITH due AS (
      SELECT m.org_id, m.currency, m.order_id, 'sale'::text AS kind, m.organizer_net AS amount
        FROM public.exos_marketplace_order_money m
       WHERE m.state = 'payable' AND m.organizer_net > 0
      UNION ALL
      SELECT m.org_id, m.currency, m.order_id, 'clawback', -m.paid_amount
        FROM public.exos_marketplace_order_money m
       WHERE m.state = 'clawback_due' AND m.payout_status = 'sent'
    )
    SELECT d.org_id, d.currency, sum(d.amount) AS total
      FROM due d
     WHERE (p_org IS NULL OR d.org_id = p_org)
       AND NOT EXISTS (SELECT 1 FROM public.exos_org_payouts p
                        WHERE p.org_id = d.org_id AND p.currency = d.currency AND p.status IN ('planned', 'sending'))
     GROUP BY d.org_id, d.currency
    HAVING sum(d.amount) > 0
  LOOP
    v_payout := gen_random_uuid();
    INSERT INTO public.exos_org_payouts (id, org_id, currency, amount, idempotency_key)
    VALUES (v_payout, g.org_id, g.currency, round(g.total, 2), 'exos-payout-' || v_payout);
    INSERT INTO public.exos_org_payout_lines (payout_id, org_id, order_id, kind, amount)
    SELECT v_payout, m.org_id, m.order_id, 'sale', m.organizer_net
      FROM public.exos_marketplace_order_money m
     WHERE m.org_id = g.org_id AND m.currency = g.currency AND m.state = 'payable' AND m.organizer_net > 0;
    GET DIAGNOSTICS v_sales = ROW_COUNT;
    INSERT INTO public.exos_org_payout_lines (payout_id, org_id, order_id, kind, amount)
    SELECT v_payout, m.org_id, m.order_id, 'clawback', -m.paid_amount
      FROM public.exos_marketplace_order_money m
     WHERE m.org_id = g.org_id AND m.currency = g.currency AND m.state = 'clawback_due' AND m.payout_status = 'sent';
    GET DIAGNOSTICS v_claws = ROW_COUNT;
    payout_id := v_payout; org_id := g.org_id; currency := g.currency; amount := round(g.total, 2);
    sale_lines := v_sales; clawback_lines := v_claws;
    RETURN NEXT;
  END LOOP;
END $$;

-- Move a payout along: planned -> sending -> sent | failed; failed -> planned (retry).
CREATE OR REPLACE FUNCTION public.exos_mark_org_payout(
  p_id uuid, p_status text, p_transfer_id text DEFAULT NULL, p_error text DEFAULT NULL
) RETURNS text LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_from text;
BEGIN
  SELECT status INTO v_from FROM public.exos_org_payouts WHERE id = p_id FOR UPDATE;
  IF v_from IS NULL THEN RAISE EXCEPTION 'exos_mark_org_payout: payout not found'; END IF;
  IF NOT ((v_from = 'planned' AND p_status = 'sending')
       OR (v_from = 'sending' AND p_status IN ('sent', 'failed'))
       OR (v_from = 'failed' AND p_status = 'planned')) THEN
    RAISE EXCEPTION 'exos_mark_org_payout: can''t go from % to %', v_from, p_status;
  END IF;
  IF p_status = 'sent' AND coalesce(p_transfer_id, '') = '' THEN
    RAISE EXCEPTION 'exos_mark_org_payout: a sent payout needs its transfer id';
  END IF;
  UPDATE public.exos_org_payouts
     SET status = p_status,
         stripe_transfer_id = coalesce(p_transfer_id, stripe_transfer_id),
         error = CASE WHEN p_status = 'failed' THEN left(p_error, 500) ELSE NULL END,
         sent_at = CASE WHEN p_status = 'sent' THEN now() ELSE sent_at END,
         updated_at = now()
   WHERE id = p_id;
  RETURN p_status;
END $$;

-- Cancel a payout that hasn't gone out: its orders become payable again.
CREATE OR REPLACE FUNCTION public.exos_cancel_org_payout(p_id uuid)
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.exos_org_payouts WHERE id = p_id AND status IN ('planned', 'failed')) THEN
    RETURN false;
  END IF;
  DELETE FROM public.exos_org_payout_lines WHERE payout_id = p_id;
  UPDATE public.exos_org_payouts SET status = 'cancelled', updated_at = now() WHERE id = p_id;
  RETURN true;
END $$;

REVOKE ALL ON FUNCTION public.exos_record_remittance(jsonb) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.exos_confirm_remittance(uuid, uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.exos_plan_org_payouts(uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.exos_mark_org_payout(uuid, text, text, text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.exos_cancel_org_payout(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_record_remittance(jsonb) TO service_role;
GRANT EXECUTE ON FUNCTION public.exos_confirm_remittance(uuid, uuid) TO service_role;
GRANT EXECUTE ON FUNCTION public.exos_plan_org_payouts(uuid) TO service_role;
GRANT EXECUTE ON FUNCTION public.exos_mark_org_payout(uuid, text, text, text) TO service_role;
GRANT EXECUTE ON FUNCTION public.exos_cancel_org_payout(uuid) TO service_role;
