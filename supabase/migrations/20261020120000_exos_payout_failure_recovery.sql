-- ============================================================================
-- Payouts: a failed transfer is re-planned, one org can't stop the run, and
-- a payout stuck in 'sending' can be sent again
-- ============================================================================
-- Touches:  C: FUNCTION exos_plan_org_payouts_report (the planner, with a
--              per-org error list; exos-payouts calls this one)
--           R: exos_plan_org_payouts (same signature and rows; now a wrapper
--              over the report, errors raised as WARNINGs)
--           R: exos_mark_org_payout (sending -> sending re-claims a send
--              older than 15 minutes)
-- Pre-reqs: 20260929070000 (payout ledger)
--
-- A payout that went planned -> sending -> failed kept its lines, so its
-- orders read 'payable' again but stayed taken (UNIQUE (order_id, kind)).
-- The next plan picked them up and died on the duplicate line; with p_org
-- NULL (the cron) that aborted every org, so nobody was planned.
--
-- Now, per org and currency (skipped while it has a planned / sending
-- payout, as before):
--   * a failed payout's lines are released and the payout is cancelled
--     (its error is kept), the same as exos_cancel_org_payout; its orders
--     and clawbacks go into the new payout with the rest.
--   * each org is planned in its own subtransaction: an error rolls back
--     that org only and is reported in the result's errors list.
--
-- 'sending' is the claim exos-payouts takes before the Stripe call. A run
-- that dies after the claim left the payout there for good. A claim older
-- than 15 minutes (exos-payouts uses the same number) can be taken again;
-- the resend reuses the payout's idempotency key and transfer group, so
-- Stripe returns the first transfer instead of making a second one.
--
-- Re-run safe (CREATE OR REPLACE, same signatures). D4 authors; applying to
-- prod is operator-gated.
-- ============================================================================

-- Plan payouts. Returns { planned: [{ payout_id, org_id, currency, amount,
-- sale_lines, clawback_lines, released }], errors: [{ org_id, currency,
-- error }] }; released = failed payouts folded into this one.
CREATE OR REPLACE FUNCTION public.exos_plan_org_payouts_report(p_org uuid DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  g record; v_payout uuid; v_total numeric; v_sales int; v_claws int; v_released int;
  v_planned jsonb := '[]'::jsonb; v_errors jsonb := '[]'::jsonb;
BEGIN
  FOR g IN
    SELECT DISTINCT x.org_id, x.currency FROM (
      SELECT m.org_id, m.currency FROM public.exos_marketplace_order_money m
       WHERE (m.state = 'payable' AND m.organizer_net > 0)
          OR (m.state = 'clawback_due' AND m.payout_status = 'sent')
      UNION
      SELECT p.org_id, p.currency FROM public.exos_org_payouts p
       WHERE p.status = 'failed'
         AND EXISTS (SELECT 1 FROM public.exos_org_payout_lines l WHERE l.payout_id = p.id)
    ) x
     WHERE (p_org IS NULL OR x.org_id = p_org)
       AND NOT EXISTS (SELECT 1 FROM public.exos_org_payouts p
                        WHERE p.org_id = x.org_id AND p.currency = x.currency AND p.status IN ('planned', 'sending'))
     ORDER BY x.org_id, x.currency
  LOOP
    BEGIN
      -- A failed transfer moved no money: free its orders for this payout.
      WITH f AS (
        UPDATE public.exos_org_payouts p SET status = 'cancelled', updated_at = now()
         WHERE p.org_id = g.org_id AND p.currency = g.currency AND p.status = 'failed'
           AND EXISTS (SELECT 1 FROM public.exos_org_payout_lines l WHERE l.payout_id = p.id)
        RETURNING p.id),
      d AS (DELETE FROM public.exos_org_payout_lines l USING f WHERE l.payout_id = f.id)
      SELECT count(*) INTO v_released FROM f;

      SELECT sum(d.amount) INTO v_total FROM (
        SELECT m.organizer_net AS amount FROM public.exos_marketplace_order_money m
         WHERE m.org_id = g.org_id AND m.currency = g.currency AND m.state = 'payable' AND m.organizer_net > 0
        UNION ALL
        SELECT -m.paid_amount FROM public.exos_marketplace_order_money m
         WHERE m.org_id = g.org_id AND m.currency = g.currency AND m.state = 'clawback_due' AND m.payout_status = 'sent'
      ) d;
      -- Zero or less: no payout, the balance carries forward.
      CONTINUE WHEN coalesce(v_total, 0) <= 0;

      v_payout := gen_random_uuid();
      INSERT INTO public.exos_org_payouts (id, org_id, currency, amount, idempotency_key)
      VALUES (v_payout, g.org_id, g.currency, round(v_total, 2), 'exos-payout-' || v_payout);
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
      v_planned := v_planned || jsonb_build_object('payout_id', v_payout, 'org_id', g.org_id, 'currency', g.currency,
        'amount', round(v_total, 2), 'sale_lines', v_sales, 'clawback_lines', v_claws, 'released', v_released);
    EXCEPTION WHEN OTHERS THEN
      RAISE WARNING 'exos_plan_org_payouts: org % (%) not planned: % (%)', g.org_id, g.currency, SQLERRM, SQLSTATE;
      v_errors := v_errors || jsonb_build_object('org_id', g.org_id, 'currency', g.currency, 'error', left(SQLERRM, 300));
    END;
  END LOOP;
  RETURN jsonb_build_object('planned', v_planned, 'errors', v_errors);
END $$;

-- The original table form, for SQL callers: the payouts made (orgs that
-- errored are left out, with a WARNING).
CREATE OR REPLACE FUNCTION public.exos_plan_org_payouts(p_org uuid DEFAULT NULL)
RETURNS TABLE (payout_id uuid, org_id uuid, currency text, amount numeric, sale_lines int, clawback_lines int)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
  RETURN QUERY
  SELECT (e ->> 'payout_id')::uuid, (e ->> 'org_id')::uuid, e ->> 'currency', (e ->> 'amount')::numeric,
         (e ->> 'sale_lines')::int, (e ->> 'clawback_lines')::int
    FROM jsonb_array_elements(public.exos_plan_org_payouts_report(p_org) -> 'planned') e;
END $$;

-- Move a payout along: planned -> sending -> sent | failed; failed -> planned
-- (retry); sending -> sending re-claims a send that's been stuck 15 minutes.
CREATE OR REPLACE FUNCTION public.exos_mark_org_payout(
  p_id uuid, p_status text, p_transfer_id text DEFAULT NULL, p_error text DEFAULT NULL
) RETURNS text LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_from text; v_at timestamptz;
BEGIN
  SELECT status, updated_at INTO v_from, v_at FROM public.exos_org_payouts WHERE id = p_id FOR UPDATE;
  IF v_from IS NULL THEN RAISE EXCEPTION 'exos_mark_org_payout: payout not found'; END IF;
  IF v_from = 'sending' AND p_status = 'sending' AND v_at >= now() - interval '15 minutes' THEN
    RAISE EXCEPTION 'exos_mark_org_payout: payout is already being sent';
  END IF;
  IF NOT ((v_from = 'planned' AND p_status = 'sending')
       OR (v_from = 'sending' AND p_status IN ('sending', 'sent', 'failed'))
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

REVOKE ALL ON FUNCTION public.exos_plan_org_payouts_report(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_plan_org_payouts_report(uuid) TO service_role;
