-- ============================================================================
-- Roles + money (P1): finance records promoter payouts; refunds reach every
-- order; disputes show the buyer; abandoned-checkout reminders are counted
-- ============================================================================
-- Touches:  R: exos_record_promoter_payout (same signature and body; finance
--              may call it too)
--           C: FUNCTION exos_event_refund_orders_page (authenticated; owner /
--              manager / finance): search + paging over the event's paid
--              orders, with totals over all of them
--           C: FUNCTION exos_dispute_buyers (authenticated; owner / manager /
--              finance of the dispute's org): the buyer email of each dispute
--           C: FUNCTION exos_event_checkout_reminder_stats (authenticated;
--              owner / manager / finance): reminders sent and recovered
-- Pre-reqs: 20260926020000 (promoter commissions), 20260926040000 (organizer
--           refunds), 20260926060000 (abandoned checkout), 20261001101000
--           (disputes)
--
-- 1. Promoter payouts. Finance can read what's owed (exos_org_promoter_
--    commissions) but recording that it was paid was owner / manager only,
--    so the "Money: payouts" role had a button that always failed. Recording
--    a payout moves no money (it marks rows paid after the organizer paid
--    outside Exos), so finance may now do it. Terms stay owner / manager.
--
-- 2. Refund orders. exos_event_refund_orders returns the newest 500 orders,
--    so an order past that (a big show) couldn't be found or refunded from
--    the panel, and the "refundable" total only added those 500. The page
--    form searches every paid order (buyer email or order id, substring,
--    case-insensitive), pages by offset, newest first, and returns:
--      { orders: [... same fields as exos_event_refund_orders ...],
--        matches, total_orders, total_refundable_cents }
--    The old function is kept for the deployed bundle.
--
-- 3. Disputes. exos_disputes has no buyer, so the panel showed cs_ ids. The
--    session's buyer_email is column-scoped to finance-capable roles already
--    (exos_event_refund_orders returns it); this returns it per dispute row
--    for the same roles. Account deletion NULLs it (mig 20260926010000).
--
-- 4. Abandoned-checkout reminders (on by default, mig 20260926060000) had no
--    report. Per event: whether the org has them on, how many were sent, and
--    how many of those buyers then paid for the event (a paid session created
--    after the reminder), with what they paid.
--
-- The org toggle needs no SQL: exos_orgs.checkout_reminders_enabled is
-- owner-writable through exos_orgs_upd. Fee terms need none either: the rate
-- is exos_platform_fee_bps() (EXOS_FEE_BPS in the app) and exos_org_billing
-- is readable by owner / manager / finance (exos_org_billing_sel).
--
-- Re-run safe (CREATE OR REPLACE, same signature for the patched function).
-- D4 authors; applying to prod is operator-gated.
-- ROLLBACK: re-run section 5 of 20260926020000 (exos_record_promoter_payout);
--   DROP FUNCTION exos_event_refund_orders_page(uuid, text, int, int),
--   exos_dispute_buyers(uuid[]), exos_event_checkout_reminder_stats(uuid).
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. Record a payout (owner / manager / finance). Body unchanged from
--    20260926020000 apart from the role list.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.exos_record_promoter_payout(
  p_promoter_id    uuid,
  p_commission_ids uuid[],
  p_amount_cents   integer,
  p_method         text,
  p_note           text DEFAULT NULL,
  p_paid_on        date DEFAULT NULL
) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_org      uuid;
  v_ids      uuid[];
  v_found    integer;
  v_cur      text;
  v_ncur     integer;
  v_sum      bigint;
  v_claw     bigint;
  v_id       uuid;
BEGIN
  SELECT org_id INTO v_org FROM public.exos_promoters WHERE id = p_promoter_id FOR UPDATE;
  IF v_org IS NULL OR NOT public.exos_has_org_role(v_org, ARRAY['owner', 'manager', 'finance']) THEN
    RAISE EXCEPTION 'exos_record_promoter_payout: not allowed' USING ERRCODE = '42501';
  END IF;
  IF p_method IS NULL OR length(btrim(p_method)) NOT BETWEEN 1 AND 60 THEN
    RAISE EXCEPTION 'Say how you paid (e.g. Venmo), up to 60 characters.' USING ERRCODE = '22023';
  END IF;
  IF p_note IS NOT NULL AND length(p_note) > 500 THEN
    RAISE EXCEPTION 'Note is too long (500 characters max).' USING ERRCODE = '22023';
  END IF;
  SELECT array_agg(DISTINCT x) INTO v_ids FROM unnest(p_commission_ids) x WHERE x IS NOT NULL;
  IF coalesce(cardinality(v_ids), 0) = 0 THEN
    RAISE EXCEPTION 'Pick at least one sale to pay out.' USING ERRCODE = '22023';
  END IF;

  PERFORM 1 FROM public.exos_promoter_commissions
    WHERE id = ANY (v_ids) FOR UPDATE;
  SELECT count(*), min(currency), count(DISTINCT currency), coalesce(sum(commission_cents), 0)
    INTO v_found, v_cur, v_ncur, v_sum
    FROM public.exos_promoter_commissions
   WHERE id = ANY (v_ids) AND promoter_id = p_promoter_id AND status = 'accrued';
  IF v_found <> cardinality(v_ids) THEN
    RAISE EXCEPTION 'Some of the selected sales can''t be paid (reversed, already paid, or not this promoter''s). Reload and try again.'
      USING ERRCODE = '22023';
  END IF;
  IF v_ncur <> 1 THEN
    RAISE EXCEPTION 'Pay out one currency at a time.' USING ERRCODE = '22023';
  END IF;

  SELECT coalesce(sum(commission_cents), 0) INTO v_claw
    FROM public.exos_promoter_commissions
   WHERE promoter_id = p_promoter_id AND currency = v_cur AND status = 'reversed'
     AND payout_id IS NOT NULL AND recovered_payout_id IS NULL;
  IF v_sum - v_claw < 0 THEN
    RAISE EXCEPTION 'Refunds on already-paid sales (%) are more than this payout. Nothing is owed yet.', v_claw
      USING ERRCODE = '22023';
  END IF;
  IF p_amount_cents IS DISTINCT FROM (v_sum - v_claw)::integer THEN
    RAISE EXCEPTION 'Amount doesn''t match the selected sales (expected % cents). Reload and try again.', v_sum - v_claw
      USING ERRCODE = '22023';
  END IF;

  INSERT INTO public.exos_promoter_payouts (
    org_id, promoter_id, currency, amount_cents, commission_cents, clawback_cents,
    row_count, method, note, paid_on, created_by
  ) VALUES (
    v_org, p_promoter_id, v_cur, p_amount_cents, v_sum, v_claw,
    cardinality(v_ids), btrim(p_method), NULLIF(btrim(coalesce(p_note, '')), ''),
    coalesce(p_paid_on, current_date), auth.uid()
  ) RETURNING id INTO v_id;

  UPDATE public.exos_promoter_commissions
     SET status = 'paid', payout_id = v_id, paid_at = now(), updated_at = now()
   WHERE id = ANY (v_ids);
  UPDATE public.exos_promoter_commissions
     SET recovered_payout_id = v_id, updated_at = now()
   WHERE promoter_id = p_promoter_id AND currency = v_cur AND status = 'reversed'
     AND payout_id IS NOT NULL AND recovered_payout_id IS NULL;
  RETURN v_id;
END $$;
REVOKE ALL ON FUNCTION public.exos_record_promoter_payout(uuid, uuid[], integer, text, text, date) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.exos_record_promoter_payout(uuid, uuid[], integer, text, text, date) TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 2. Refund orders: search + paging over every paid order of the event.
--    Same rows and refundable math as exos_refund_orders_list.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.exos_event_refund_orders_page(
  p_event_id uuid,
  p_search   text DEFAULT NULL,
  p_offset   int  DEFAULT 0,
  p_limit    int  DEFAULT 50
) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE
  v_org uuid;
  v_q   text := nullif(btrim(coalesce(p_search, '')), '');
  v_lim int  := least(greatest(coalesce(p_limit, 50), 1), 200);
  v_off int  := greatest(coalesce(p_offset, 0), 0);
  v_res jsonb;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'exos_event_refund_orders_page: not authenticated' USING ERRCODE = '42501';
  END IF;
  SELECT e.org_id INTO v_org FROM public.exos_events e WHERE e.id = p_event_id;
  IF v_org IS NULL OR NOT exos_has_org_role(v_org, ARRAY['owner', 'manager', 'finance']) THEN
    RAISE EXCEPTION 'exos_event_refund_orders_page: not authorized' USING ERRCODE = '42501';
  END IF;
  -- A literal substring: escape LIKE's wildcards.
  IF v_q IS NOT NULL THEN
    v_q := '%' || replace(replace(replace(lower(left(v_q, 200)), '\', '\\'), '%', '\%'), '_', '\_') || '%';
  END IF;

  WITH o AS (
    SELECT cs.session_id, cs.buyer_email, cs.created_at, cs.status, cs.amount_cents, cs.currency,
           public.exos_refund_order_reserved(cs.session_id) AS refunded_cents,
           (cs.payment_intent IS NOT NULL OR EXISTS (
              SELECT 1 FROM public.exos_order_payments p
               WHERE p.session_id = cs.session_id AND p.status = 'succeeded'
                 AND p.payment_intent IS NOT NULL)) AS has_pi
      FROM public.exos_checkout_sessions cs
     WHERE cs.event_id = p_event_id
       AND cs.status IN ('fulfilled', 'partially_refunded', 'refunded')
       AND cs.amount_cents > 0
  ), r AS (
    SELECT o.*, CASE WHEN o.has_pi THEN greatest(o.amount_cents - o.refunded_cents, 0) ELSE 0 END AS refundable_cents
      FROM o
  ), m AS (
    SELECT r.* FROM r
     WHERE v_q IS NULL
        OR lower(coalesce(r.buyer_email, '')) LIKE v_q ESCAPE '\'
        OR lower(r.session_id) LIKE v_q ESCAPE '\'
  ), pg AS (
    SELECT m.* FROM m ORDER BY m.created_at DESC, m.session_id DESC OFFSET v_off LIMIT v_lim
  )
  SELECT jsonb_build_object(
           'orders', coalesce((
             SELECT jsonb_agg(jsonb_build_object(
                      'session_id', pg.session_id, 'buyer_email', pg.buyer_email, 'created_at', pg.created_at,
                      'status', pg.status, 'amount_cents', pg.amount_cents, 'refunded_cents', pg.refunded_cents,
                      'refundable_cents', pg.refundable_cents,
                      'tickets', (SELECT count(*) FROM public.exos_tickets t WHERE t.order_ref = pg.session_id),
                      'active_tickets', (SELECT count(*) FROM public.exos_tickets t
                                          WHERE t.order_ref = pg.session_id AND t.status = 'active'),
                      'open_requests', (SELECT count(*) FROM public.exos_refund_requests q
                                         WHERE q.session_id = pg.session_id AND q.status IN ('claimed', 'pending')),
                      'currency', pg.currency)
                    ORDER BY pg.created_at DESC, pg.session_id DESC)
               FROM pg), '[]'::jsonb),
           'matches', (SELECT count(*) FROM m),
           'total_orders', (SELECT count(*) FROM r),
           'total_refundable_cents', (SELECT coalesce(sum(r.refundable_cents), 0) FROM r))
    INTO v_res;
  RETURN v_res;
END $$;
REVOKE ALL ON FUNCTION public.exos_event_refund_orders_page(uuid, text, int, int) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.exos_event_refund_orders_page(uuid, text, int, int) TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 3. The buyer email behind each dispute (exos_disputes.id), for the roles
--    that read disputes. Rows the caller can't read are left out. Max 500.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.exos_dispute_buyers(p_dispute_ids uuid[])
RETURNS TABLE (id uuid, buyer_email text)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
  SELECT d.id, cs.buyer_email
    FROM public.exos_disputes d
    JOIN public.exos_checkout_sessions cs ON cs.session_id = d.session_id
   WHERE d.id = ANY ((coalesce(p_dispute_ids, '{}'::uuid[]))[1:500])
     AND auth.uid() IS NOT NULL
     AND (public.exos_is_admin() OR public.exos_has_org_role(d.org_id, ARRAY['owner', 'manager', 'finance']));
$$;
REVOKE ALL ON FUNCTION public.exos_dispute_buyers(uuid[]) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.exos_dispute_buyers(uuid[]) TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 4. Abandoned-checkout reminders for one event: { enabled, sent, recovered,
--    recovered_cents }. Recovered = the reminded buyer has a paid session for
--    the event created after the reminder (a refund later doesn't undo it).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.exos_event_checkout_reminder_stats(p_event_id uuid)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE
  v_org  uuid;
  v_on   boolean;
  v_sent int;
  v_rec  int;
  v_cent bigint;
BEGIN
  SELECT e.org_id, o.checkout_reminders_enabled INTO v_org, v_on
    FROM public.exos_events e JOIN public.exos_orgs o ON o.id = e.org_id
   WHERE e.id = p_event_id;
  IF v_org IS NULL OR auth.uid() IS NULL
     OR NOT (public.exos_is_admin() OR public.exos_has_org_role(v_org, ARRAY['owner', 'manager', 'finance'])) THEN
    RAISE EXCEPTION 'exos_event_checkout_reminder_stats: not authorized' USING ERRCODE = '42501';
  END IF;
  SELECT count(*)::int, count(x.cents)::int, coalesce(sum(x.cents), 0)
    INTO v_sent, v_rec, v_cent
    FROM public.exos_checkout_reminders cr
    LEFT JOIN LATERAL (
      SELECT sum(s.amount_cents) AS cents
        FROM public.exos_checkout_sessions s
       WHERE s.event_id = cr.event_id AND s.buyer_uid = cr.buyer_uid
         AND s.created_at > cr.sent_at
         AND s.status IN ('fulfilled', 'partially_refunded', 'refunded')
    ) x ON true
   WHERE cr.event_id = p_event_id;
  RETURN jsonb_build_object('enabled', coalesce(v_on, true), 'sent', v_sent,
                            'recovered', v_rec, 'recovered_cents', v_cent);
END $$;
REVOKE ALL ON FUNCTION public.exos_event_checkout_reminder_stats(uuid) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.exos_event_checkout_reminder_stats(uuid) TO authenticated, service_role;
