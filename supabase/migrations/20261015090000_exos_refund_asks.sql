-- ============================================================================
-- Buyer refund requests: the buyer asks, the organizer refunds or declines
-- ============================================================================
-- Touches:  C: TABLE exos_refund_asks (RLS on, no policies: RPCs only)
--           C: FUNCTION _exos_refund_ask_state, exos_refund_ask_window,
--              exos_ask_refund, exos_withdraw_refund_ask, exos_my_refund_asks,
--              exos_event_refund_asks, exos_decline_refund_ask,
--              exos_tg_refund_asks_close (trigger on exos_refund_requests)
-- Pre-reqs: 20260926040000 (refund ledger), 20260929120000 (refund_policy),
--           20260929150000 (reschedule refunds, same eligibility shape)
--
-- pretix calls this a cancellation request; hi.events has none. The buyer
-- (the person who paid: the checkout's account, or an account with the
-- buyer's confirmed email) asks for a ticket's money back, with a reason. The
-- event's refund policy (exos_events.refund_policy) decides whether they can
-- ask: 'none' = all sales final, 'until_7d' / 'until_24h' / 'until_start' = up
-- to that long before the start, unset = ask any time before the start and the
-- organizer decides. Nothing moves until the organizer acts:
--   refund  -> the event report calls exos-refund { action: 'refund',
--              session_id, items: [{ ticket_id }], nonce: 'ask:<id>' } (the
--              existing organizer refund: Stripe, void, refund-issued mail).
--              When that refund succeeds, the trigger closes the ask. Any other
--              refund of the same ticket closes it too.
--   decline -> exos_decline_refund_ask, with a note the buyer sees.
-- One open ask per ticket. Marketplace (StubHub, S4K, ...), comp and free
-- tickets, used / voided / in-transfer tickets and cancelled events can't ask.
--
-- Re-run safe. Prod apply needs operator OK.
-- ============================================================================

CREATE TABLE IF NOT EXISTS public.exos_refund_asks (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  ticket_id         uuid NOT NULL REFERENCES public.exos_tickets (id) ON DELETE CASCADE,
  event_id          uuid NOT NULL REFERENCES public.exos_events (id) ON DELETE CASCADE,
  org_id            uuid NOT NULL REFERENCES public.exos_orgs (id) ON DELETE CASCADE,
  session_id        text NOT NULL,
  asked_by          uuid REFERENCES auth.users (id) ON DELETE SET NULL,
  reason            text CHECK (reason IS NULL OR length(reason) <= 500),
  amount_cents      int  NOT NULL DEFAULT 0 CHECK (amount_cents >= 0),
  currency          text NOT NULL DEFAULT 'usd',
  status            text NOT NULL DEFAULT 'open'
                      CHECK (status IN ('open', 'refunded', 'declined', 'withdrawn')),
  decided_by        uuid REFERENCES auth.users (id) ON DELETE SET NULL,
  decided_at        timestamptz,
  decline_note      text CHECK (decline_note IS NULL OR length(decline_note) <= 500),
  refund_request_id uuid REFERENCES public.exos_refund_requests (id) ON DELETE SET NULL,
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX IF NOT EXISTS exos_refund_asks_open_uq ON public.exos_refund_asks (ticket_id) WHERE status = 'open';
CREATE INDEX IF NOT EXISTS exos_refund_asks_event_idx ON public.exos_refund_asks (event_id, status);
CREATE INDEX IF NOT EXISTS exos_refund_asks_asker_idx ON public.exos_refund_asks (asked_by);
ALTER TABLE public.exos_refund_asks ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.exos_refund_asks FROM anon, authenticated;

-- Until when the policy lets a buyer ask (NULL = can't ask: all sales final).
CREATE OR REPLACE FUNCTION public.exos_refund_ask_window(p_policy text, p_starts_at timestamptz)
RETURNS timestamptz
LANGUAGE sql STABLE
SET search_path = public, pg_temp
AS $$
  SELECT CASE coalesce(p_policy, '')
           WHEN 'none'        THEN NULL
           WHEN 'until_7d'    THEN p_starts_at - interval '7 days'
           WHEN 'until_24h'   THEN p_starts_at - interval '24 hours'
           ELSE p_starts_at
         END
$$;
GRANT EXECUTE ON FUNCTION public.exos_refund_ask_window(text, timestamptz) TO anon, authenticated, service_role;

-- Can this ticket be asked about now, by whom, for how much.
CREATE OR REPLACE FUNCTION public._exos_refund_ask_state(p_ticket_id uuid)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  t        public.exos_tickets%ROWTYPE;
  e        public.exos_events%ROWTYPE;
  s        public.exos_checkout_sessions%ROWTYPE;
  a        public.exos_refund_asks%ROWTYPE;
  st       record;
  v_until  timestamptz;
  v_email  text;
  v_share  int := 0;
  v_reason text;
BEGIN
  SELECT * INTO t FROM public.exos_tickets WHERE id = p_ticket_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'not-found', 'ticket_id', p_ticket_id);
  END IF;
  SELECT * INTO e FROM public.exos_events WHERE id = t.event_id;
  SELECT * INTO s FROM public.exos_checkout_sessions cs WHERE cs.session_id = t.order_ref AND cs.event_id = t.event_id;
  SELECT * INTO a FROM public.exos_refund_asks x WHERE x.ticket_id = t.id ORDER BY x.created_at DESC LIMIT 1;
  v_until := public.exos_refund_ask_window(e.refund_policy, e.starts_at);
  v_email := nullif(lower(btrim(coalesce(s.buyer_email, ''))), '');
  IF v_email IS NULL AND s.buyer_uid IS NOT NULL THEN
    SELECT lower(email) INTO v_email FROM auth.users WHERE id = s.buyer_uid;
  END IF;
  IF s.session_id IS NOT NULL THEN
    SELECT x.share_cents, x.allocated_cents INTO st FROM public.exos_refund_ticket_state(s.session_id) x WHERE x.ticket_id = t.id;
    v_share := greatest(coalesce(st.share_cents, 0) - coalesce(st.allocated_cents, 0), 0);
  END IF;

  IF a.status = 'open' THEN
    v_reason := 'asked';
  ELSIF t.channel_source IN ('gotickets', 'gametime', 'stubhub', 'seatgeek', 'vivid', 'tickpick', 'evo', 'tevo', 'automatiq', 's4k') THEN
    v_reason := 'marketplace';
  ELSIF s.session_id IS NULL OR coalesce(s.amount_cents, 0) <= 0 THEN
    v_reason := 'not-exos-paid';
  ELSIF e.status = 'cancelled' THEN
    v_reason := 'event-cancelled';
  ELSIF t.status = 'voided' THEN
    v_reason := 'voided';
  ELSIF t.status = 'used' OR t.check_in_at IS NOT NULL THEN
    v_reason := 'checked-in';
  ELSIF t.status <> 'active' THEN
    v_reason := 'not-active';
  ELSIF t.pending_transfer_id IS NOT NULL THEN
    v_reason := 'in-transfer';
  ELSIF v_until IS NULL THEN
    v_reason := 'no-refunds';
  ELSIF now() >= v_until THEN
    v_reason := 'too-late';
  ELSIF v_share <= 0 OR s.status NOT IN ('fulfilled', 'partially_refunded') THEN
    v_reason := 'refunded';
  END IF;

  RETURN jsonb_build_object(
    'ok', v_reason IS NULL, 'reason', v_reason, 'ticket_id', t.id, 'event_id', t.event_id, 'org_id', t.org_id,
    'tier_name', t.tier_name, 'session_id', s.session_id, 'amount_cents', v_share,
    'currency', lower(coalesce(s.currency, e.currency, 'usd')), 'ask_until', v_until,
    'refund_policy', e.refund_policy, 'payer_uid', s.buyer_uid, 'payer_email', v_email,
    'ask_id', a.id, 'ask_status', a.status, 'decline_note', a.decline_note);
END $$;
REVOKE ALL ON FUNCTION public._exos_refund_ask_state(uuid) FROM PUBLIC, anon, authenticated;

-- The person who paid: the checkout's account, or an account with its confirmed email.
CREATE OR REPLACE FUNCTION public._exos_refund_ask_payer_ok(p_state jsonb, p_actor uuid)
RETURNS boolean
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE v_email text;
BEGIN
  IF p_actor IS NULL OR p_state IS NULL THEN RETURN false; END IF;
  -- NULL-safe throughout: a ticket with no order has no payer, so nobody passes.
  IF p_actor::text IS NOT DISTINCT FROM p_state->>'payer_uid' THEN RETURN true; END IF;
  SELECT lower(email) INTO v_email FROM auth.users WHERE id = p_actor AND email_confirmed_at IS NOT NULL;
  RETURN coalesce(v_email IS NOT NULL AND v_email = p_state->>'payer_email', false);
END $$;
REVOKE ALL ON FUNCTION public._exos_refund_ask_payer_ok(jsonb, uuid) FROM PUBLIC, anon, authenticated;

-- Buyer: ask for these tickets' money back. One result per ticket.
CREATE OR REPLACE FUNCTION public.exos_ask_refund(p_ticket_ids uuid[], p_reason text DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_uid    uuid := auth.uid();
  v_reason text := nullif(btrim(coalesce(p_reason, '')), '');
  v_tid    uuid;
  st       jsonb;
  v_id     uuid;
  v_out    jsonb := '[]'::jsonb;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'exos_ask_refund: sign in to ask for a refund' USING ERRCODE = '42501';
  END IF;
  IF coalesce(cardinality(p_ticket_ids), 0) = 0 THEN
    RAISE EXCEPTION 'exos_ask_refund: say which tickets' USING ERRCODE = '22023';
  END IF;
  IF cardinality(p_ticket_ids) > 50 THEN
    RAISE EXCEPTION 'exos_ask_refund: at most 50 tickets at a time' USING ERRCODE = '22023';
  END IF;
  IF length(v_reason) > 500 THEN
    RAISE EXCEPTION 'exos_ask_refund: keep the reason under 500 characters' USING ERRCODE = '22023';
  END IF;

  FOREACH v_tid IN ARRAY (SELECT array_agg(DISTINCT x) FROM unnest(p_ticket_ids) x) LOOP
    PERFORM 1 FROM public.exos_tickets WHERE id = v_tid FOR UPDATE;
    st := public._exos_refund_ask_state(v_tid);
    IF st->>'reason' = 'not-found' OR NOT coalesce(public._exos_refund_ask_payer_ok(st, v_uid), false) THEN
      v_out := v_out || jsonb_build_object('ticket_id', v_tid, 'ok', false, 'reason', 'not-buyer');
      CONTINUE;
    END IF;
    IF st->>'reason' = 'asked' THEN
      v_out := v_out || jsonb_build_object('ticket_id', v_tid, 'ok', true, 'ask_id', st->>'ask_id', 'existing', true);
      CONTINUE;
    END IF;
    IF NOT (st->>'ok')::boolean THEN
      v_out := v_out || jsonb_build_object('ticket_id', v_tid, 'ok', false, 'reason', st->>'reason');
      CONTINUE;
    END IF;
    INSERT INTO public.exos_refund_asks (ticket_id, event_id, org_id, session_id, asked_by, reason, amount_cents, currency)
    VALUES (v_tid, (st->>'event_id')::uuid, (st->>'org_id')::uuid, st->>'session_id', v_uid, v_reason,
            (st->>'amount_cents')::int, st->>'currency')
    RETURNING id INTO v_id;
    v_out := v_out || jsonb_build_object('ticket_id', v_tid, 'ok', true, 'ask_id', v_id,
                                         'amount_cents', (st->>'amount_cents')::int, 'existing', false);
  END LOOP;
  RETURN v_out;
END $$;
REVOKE ALL ON FUNCTION public.exos_ask_refund(uuid[], text) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.exos_ask_refund(uuid[], text) TO authenticated, service_role;

-- Buyer: take an open ask back.
CREATE OR REPLACE FUNCTION public.exos_withdraw_refund_ask(p_ask_id uuid)
RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE v_uid uuid := auth.uid(); a public.exos_refund_asks%ROWTYPE;
BEGIN
  SELECT * INTO a FROM public.exos_refund_asks WHERE id = p_ask_id FOR UPDATE;
  IF NOT FOUND OR v_uid IS NULL OR a.asked_by IS DISTINCT FROM v_uid THEN
    RAISE EXCEPTION 'exos_withdraw_refund_ask: not found' USING ERRCODE = 'P0002';
  END IF;
  IF a.status <> 'open' THEN RETURN false; END IF;
  UPDATE public.exos_refund_asks SET status = 'withdrawn', decided_at = now(), updated_at = now() WHERE id = p_ask_id;
  RETURN true;
END $$;
REVOKE ALL ON FUNCTION public.exos_withdraw_refund_ask(uuid) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.exos_withdraw_refund_ask(uuid) TO authenticated, service_role;

-- Buyer: what each of my tickets for this event can do (the ticket page).
CREATE OR REPLACE FUNCTION public.exos_my_refund_asks(p_event_id uuid)
RETURNS TABLE (ticket_id uuid, can_ask boolean, reason text, amount_cents int, currency text, ask_until timestamptz,
               refund_policy text, ask_id uuid, ask_status text, decline_note text)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE v_uid uuid := auth.uid(); v_email text; r record; st jsonb;
BEGIN
  IF v_uid IS NULL THEN RETURN; END IF;
  SELECT lower(email) INTO v_email FROM auth.users WHERE id = v_uid AND email_confirmed_at IS NOT NULL;
  FOR r IN
    SELECT tk.id FROM public.exos_tickets tk
      JOIN public.exos_checkout_sessions cs ON cs.session_id = tk.order_ref AND cs.event_id = tk.event_id
     WHERE tk.event_id = p_event_id
       AND (cs.buyer_uid = v_uid OR (v_email IS NOT NULL AND lower(btrim(coalesce(cs.buyer_email, ''))) = v_email))
     ORDER BY tk.created_at, tk.id
     LIMIT 200
  LOOP
    st := public._exos_refund_ask_state(r.id);
    ticket_id := r.id;
    can_ask := (st->>'ok')::boolean;
    reason := st->>'reason';
    amount_cents := (st->>'amount_cents')::int;
    currency := st->>'currency';
    ask_until := (st->>'ask_until')::timestamptz;
    refund_policy := st->>'refund_policy';
    ask_id := (st->>'ask_id')::uuid;
    ask_status := st->>'ask_status';
    decline_note := st->>'decline_note';
    RETURN NEXT;
  END LOOP;
END $$;
REVOKE ALL ON FUNCTION public.exos_my_refund_asks(uuid) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.exos_my_refund_asks(uuid) TO authenticated, service_role;

-- Owner / manager / finance: the event's asks, open first.
CREATE OR REPLACE FUNCTION public.exos_event_refund_asks(p_event_id uuid)
RETURNS TABLE (ask_id uuid, ticket_id uuid, tier_name text, session_id text, buyer_email text, reason text,
               amount_cents int, currency text, status text, decline_note text, created_at timestamptz,
               decided_at timestamptz, ticket_status text, checked_in boolean)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE v_org uuid;
BEGIN
  SELECT org_id INTO v_org FROM public.exos_events WHERE id = p_event_id;
  IF v_org IS NULL OR NOT EXISTS (
       SELECT 1 FROM public.exos_org_memberships m
        WHERE m.org_id = v_org AND m.user_id = auth.uid() AND m.disabled IS NOT TRUE
          AND m.role IN ('owner', 'manager', 'finance')) THEN
    RAISE EXCEPTION 'exos_event_refund_asks: not authorized' USING ERRCODE = '42501';
  END IF;
  RETURN QUERY
    SELECT a.id, a.ticket_id, tk.tier_name, a.session_id,
           coalesce(nullif(cs.buyer_email, ''), (SELECT u.email::text FROM auth.users u WHERE u.id = a.asked_by)),
           a.reason, a.amount_cents, a.currency, a.status, a.decline_note, a.created_at, a.decided_at,
           tk.status, tk.check_in_at IS NOT NULL
      FROM public.exos_refund_asks a
      JOIN public.exos_tickets tk ON tk.id = a.ticket_id
      LEFT JOIN public.exos_checkout_sessions cs ON cs.session_id = a.session_id
     WHERE a.event_id = p_event_id
     ORDER BY (a.status = 'open') DESC, a.created_at DESC
     LIMIT 500;
END $$;
REVOKE ALL ON FUNCTION public.exos_event_refund_asks(uuid) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.exos_event_refund_asks(uuid) TO authenticated, service_role;

-- Owner / manager / finance: say no, with a note the buyer sees.
CREATE OR REPLACE FUNCTION public.exos_decline_refund_ask(p_ask_id uuid, p_note text DEFAULT NULL)
RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE a public.exos_refund_asks%ROWTYPE; v_note text := nullif(btrim(coalesce(p_note, '')), '');
BEGIN
  SELECT * INTO a FROM public.exos_refund_asks WHERE id = p_ask_id FOR UPDATE;
  IF NOT FOUND OR NOT EXISTS (
       SELECT 1 FROM public.exos_org_memberships m
        WHERE m.org_id = a.org_id AND m.user_id = auth.uid() AND m.disabled IS NOT TRUE
          AND m.role IN ('owner', 'manager', 'finance')) THEN
    RAISE EXCEPTION 'exos_decline_refund_ask: not authorized' USING ERRCODE = '42501';
  END IF;
  IF length(v_note) > 500 THEN
    RAISE EXCEPTION 'exos_decline_refund_ask: keep the note under 500 characters' USING ERRCODE = '22023';
  END IF;
  IF a.status <> 'open' THEN RETURN false; END IF;
  UPDATE public.exos_refund_asks
     SET status = 'declined', decline_note = v_note, decided_by = auth.uid(), decided_at = now(), updated_at = now()
   WHERE id = p_ask_id;
  RETURN true;
END $$;
REVOKE ALL ON FUNCTION public.exos_decline_refund_ask(uuid, text) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.exos_decline_refund_ask(uuid, text) TO authenticated, service_role;

-- A refund that succeeds for a ticket closes its open ask (the organizer's
-- "Refund" on the ask, or any other refund of that ticket).
CREATE OR REPLACE FUNCTION public.exos_tg_refund_asks_close()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF NEW.status = 'succeeded' AND OLD.status IS DISTINCT FROM 'succeeded' THEN
    UPDATE public.exos_refund_asks a
       SET status = 'refunded', refund_request_id = NEW.id, decided_by = NEW.requested_by,
           decided_at = now(), updated_at = now()
     WHERE a.status = 'open'
       AND a.ticket_id IN (SELECT i.ticket_id FROM public.exos_refund_request_items i WHERE i.request_id = NEW.id);
  END IF;
  RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION public.exos_tg_refund_asks_close() FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE TRIGGER exos_refund_requests_close_asks
  AFTER UPDATE OF status ON public.exos_refund_requests
  FOR EACH ROW EXECUTE FUNCTION public.exos_tg_refund_asks_close();

-- ROLLBACK (manual): drop the trigger, the functions above and exos_refund_asks.
