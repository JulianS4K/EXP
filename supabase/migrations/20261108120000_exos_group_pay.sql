-- ============================================================================
-- Migration 20261108120000 — Exos: group buy v2, "pay separately"
--                            (KANBAN "Group buy / split pay", Next (money records))
--
-- Touches:  W: TABLE exos_group_buys, exos_group_buy_seats (new; host reads
--                 their own, org staff read the groups, writes through RPCs)
--              TABLE exos_cart_holds (+group_seat_id)
--              TABLE exos_checkout_sessions (+group_buy_id)
--              TRIGGER exos_cart_holds_zz_group_guard (BEFORE INSERT/UPDATE:
--                 a group seat's hold never outlives the deadline, and only
--                 the group's own code releases it early)
--              TRIGGER exos_cart_holds_group_sync (AFTER UPDATE OF status:
--                 consumed -> seat paid, expired / released -> seat released)
--              FUNCTION exos_fulfill_checkout (2 marker patches:
--                 '/* exos: group seat held */', '/* exos: group seat mail */')
--              FUNCTION exos_group_buy_start, exos_group_buy_get,
--                 exos_group_buy_mine, exos_group_buy_cancel (new, authenticated)
--              FUNCTION exos_group_seat_view (new, anon + authenticated: one
--                 seat's 128-bit link token)
--              FUNCTION exos_group_checkout_ctx, exos_group_claim,
--                 exos_group_attach, exos_group_unclaim (new, service role:
--                 exos-checkout only)
--           R: exos_create_hold (called once per seat), exos_events,
--              exos_ticket_tiers, exos_timed_entry, exos_price_steps,
--              exos_checkout_sessions
-- Pre-reqs: 20260702123000 (cart holds), 20261031220000 (split v1),
--           20261105100000 (hold session grace, session expired release,
--           exos_fulfill_checkout's failure mail reasons),
--           20261106120000 (latest exos_create_hold), 20261106130000 (price steps),
--           20261030140000 (seated tiers), 20261030150000 (timed entry)
--
-- v1 ("split with friends", mig 20261031220000) stays as it is: the host pays
-- everything and friends pay the host back. v2: each friend pays for their
-- own seat within a 30-minute group window.
--
-- 1. Start. A signed-in host starts a group of N seats (2 to 10, and at most
--    the event's maxPerOrder) of one public, paid, general-admission ticket
--    type. Exos takes N one-seat holds through exos_create_hold (every check a
--    normal hold gets: confirmed email, sales window, the type's and shared
--    capacity, the house cap, the host's per-person limit for one ticket) and
--    ties them to the group: their expires_at is the deadline (now + 30 min)
--    and no checkout can extend it. Card authorizations last ~7 days, so
--    nothing here is ever multi-day. One open group per host per event; at
--    most 10 groups started per host per hour. The host gets one link per
--    seat (/group-pay/seat/<token>, a 128-bit token) and may pay their own
--    seat with one of them.
--    Seated and timed types, price-step types, hidden types and free types
--    are refused (a group seat carries one hold; those need more per order).
-- 2. Pay. A friend opens their link and pays through exos-checkout, as any
--    buyer does (the same all-in price, fees, questions, codes, limits, guest
--    proof). Instead of a new hold, the checkout CLAIMS the seat
--    (exos_group_claim: first claimant wins, "a friend is already paying for
--    this seat" for the next) and ATTACHES the seat's hold to its session
--    (exos_group_attach; the session records group_buy_id). The ticket is
--    minted to the friend (the session's buyer). Each seat is its own order:
--    receipts, refunds and transfers work as today.
-- 3. Cover the rest. Before the deadline the host can pay for every unpaid
--    seat in one checkout (minted to the host, who can then split or
--    transfer with v1). It takes seats a friend is paying for right now too:
--    whichever payment lands first on a seat wins (below); the other is
--    refunded by the existing auto-refund. The host page warns before that.
-- 4. Deadline. The holds expire by the clock at the deadline, so the seats
--    count as on sale again at once; the existing exos_expire_holds sweep
--    flips them and exos_cart_holds_group_sync marks the seats released.
-- 5. Late payments. A checkout page can outlive the deadline (Stripe's
--    minimum is 30 minutes). exos_fulfill_checkout fulfils a group order only
--    while every one of its seats' holds is active, unexpired and attached to
--    THIS session (it locks them); otherwise the order fails ('group seat no
--    longer held at fulfillment') and the existing paths refund it:
--    stripe-webhook's auto-refund of a failed session, exos-reconcile-
--    checkouts, and the PayPal capture gate (no capture once the hold lapsed).
--    The race between a payment and the expiry sweep is decided by the hold
--    row's lock: one of them commits first, the other sees its result.
-- 6. Releases. A failed or abandoned checkout never sends a group seat back
--    to sale before the deadline: the guard trigger turns any other code's
--    'released' on a group hold into a no-op (exos-checkout's failure path,
--    fulfilment failure, an expired checkout page, the host's own new cart via
--    exos_create_hold). The seat goes back to the group instead (exos-checkout
--    calls exos_group_unclaim; a claim whose checkout failed or expired, or
--    that never got a checkout within 5 minutes, stops counting). Only
--    exos_group_buy_cancel and the deadline release early.
-- Lock order everywhere: checkout session -> holds (by id) -> seats (by id)
-- -> group. exos_fulfill_checkout locks its session first; its hold lock and
-- the sync trigger's seat / group updates follow the same order.
--
-- Additive, re-run safe (IF NOT EXISTS / CREATE OR REPLACE / marker patches).
-- No cron. Prod apply needs operator OK.
-- ROLLBACK: drop the two triggers on exos_cart_holds, take the two marked
--   blocks out of exos_fulfill_checkout, drop the new functions and tables;
--   the two new columns can stay (NULL).
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. Tables.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.exos_group_buys (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id      uuid NOT NULL REFERENCES public.exos_orgs (id) ON DELETE CASCADE,
  event_id    uuid NOT NULL REFERENCES public.exos_events (id) ON DELETE CASCADE,
  tier_id     uuid NOT NULL REFERENCES public.exos_ticket_tiers (id) ON DELETE CASCADE,
  host_uid    uuid NOT NULL REFERENCES auth.users (id) ON DELETE CASCADE,
  quantity    int  NOT NULL CHECK (quantity BETWEEN 2 AND 10),
  deadline    timestamptz NOT NULL,
  status      text NOT NULL DEFAULT 'open' CHECK (status IN ('open', 'closed', 'cancelled')),
  closed_at   timestamptz,
  created_at  timestamptz NOT NULL DEFAULT now(),
  updated_at  timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT exos_group_buys_window_chk CHECK (deadline > created_at AND deadline <= created_at + interval '30 minutes')
);
CREATE INDEX IF NOT EXISTS exos_group_buys_host_idx ON public.exos_group_buys (host_uid, created_at DESC);
CREATE INDEX IF NOT EXISTS exos_group_buys_event_idx ON public.exos_group_buys (event_id);
CREATE INDEX IF NOT EXISTS exos_group_buys_org_idx ON public.exos_group_buys (org_id);
COMMENT ON TABLE public.exos_group_buys IS
  'Group buy v2: a host''s N one-seat holds, each paid by a friend within a 30-minute window. Host reads their own, org owner / manager / finance read their org''s; writes through the exos_group_* RPCs. mig 20261108120000.';

CREATE TABLE IF NOT EXISTS public.exos_group_buy_seats (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  group_id         uuid NOT NULL REFERENCES public.exos_group_buys (id) ON DELETE CASCADE,
  org_id           uuid NOT NULL REFERENCES public.exos_orgs (id) ON DELETE CASCADE,
  seat_no          int  NOT NULL CHECK (seat_no BETWEEN 1 AND 10),
  token            text NOT NULL UNIQUE CHECK (token ~ '^[0-9a-f]{32}$'),
  hold_id          uuid UNIQUE REFERENCES public.exos_cart_holds (id) ON DELETE SET NULL,
  status           text NOT NULL DEFAULT 'waiting' CHECK (status IN ('waiting', 'paying', 'paid', 'released')),
  cover            boolean NOT NULL DEFAULT false,
  claim_uid        uuid,
  claim_email      text CHECK (claim_email IS NULL OR (claim_email = lower(claim_email) AND char_length(claim_email) <= 320)),
  claimed_at       timestamptz,
  session_id       text,
  paid_session_id  text REFERENCES public.exos_checkout_sessions (session_id) ON DELETE SET NULL,
  covered          boolean NOT NULL DEFAULT false,
  paid_at          timestamptz,
  released_at      timestamptz,
  created_at       timestamptz NOT NULL DEFAULT now(),
  updated_at       timestamptz NOT NULL DEFAULT now(),
  UNIQUE (group_id, seat_no)
);
CREATE INDEX IF NOT EXISTS exos_group_buy_seats_org_idx ON public.exos_group_buy_seats (org_id);
CREATE INDEX IF NOT EXISTS exos_group_buy_seats_paid_idx ON public.exos_group_buy_seats (paid_session_id) WHERE paid_session_id IS NOT NULL;
COMMENT ON TABLE public.exos_group_buy_seats IS
  'One seat of a group buy: its hold, its link token, who is paying (claim) and the order that paid it. Platform admins read rows; the host reads states and links through exos_group_buy_get. mig 20261108120000.';
COMMENT ON COLUMN public.exos_group_buy_seats.cover IS
  'The host''s "cover the rest" checkout has claimed this seat. covered = the host''s cover order paid it.';

DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['exos_group_buys', 'exos_group_buy_seats'] LOOP
    EXECUTE format('DROP TRIGGER IF EXISTS %I ON public.%I;', t || '_touch', t);
    EXECUTE format('CREATE TRIGGER %I BEFORE UPDATE ON public.%I FOR EACH ROW EXECUTE FUNCTION public.exos_touch_updated_at();', t || '_touch', t);
  END LOOP;
END $$;

ALTER TABLE public.exos_group_buys ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.exos_group_buy_seats ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.exos_group_buys, public.exos_group_buy_seats FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.exos_group_buys, public.exos_group_buy_seats TO authenticated;
GRANT ALL ON public.exos_group_buys, public.exos_group_buy_seats TO service_role;
DROP POLICY IF EXISTS exos_group_buys_sel ON public.exos_group_buys;
CREATE POLICY exos_group_buys_sel ON public.exos_group_buys FOR SELECT TO authenticated
  USING (host_uid = auth.uid() OR public.exos_is_admin()
         OR public.exos_has_org_role(org_id, ARRAY['owner', 'manager', 'finance']));
DROP POLICY IF EXISTS exos_group_buy_seats_sel ON public.exos_group_buy_seats;
-- Seats carry the claimant's email: platform admins only. The host reads
-- their seats (states and links, no claimant) through exos_group_buy_get.
CREATE POLICY exos_group_buy_seats_sel ON public.exos_group_buy_seats FOR SELECT TO authenticated
  USING (public.exos_is_admin());

ALTER TABLE public.exos_cart_holds
  ADD COLUMN IF NOT EXISTS group_seat_id uuid REFERENCES public.exos_group_buy_seats (id) ON DELETE SET NULL;
CREATE INDEX IF NOT EXISTS exos_cart_holds_group_seat_idx ON public.exos_cart_holds (group_seat_id) WHERE group_seat_id IS NOT NULL;
COMMENT ON COLUMN public.exos_cart_holds.group_seat_id IS
  'The group-buy seat this one-seat hold belongs to: it ends at the group''s deadline and only the group releases it early. mig 20261108120000.';

ALTER TABLE public.exos_checkout_sessions
  ADD COLUMN IF NOT EXISTS group_buy_id uuid REFERENCES public.exos_group_buys (id) ON DELETE SET NULL;
CREATE INDEX IF NOT EXISTS exos_checkout_sessions_group_buy_idx ON public.exos_checkout_sessions (group_buy_id) WHERE group_buy_id IS NOT NULL;
COMMENT ON COLUMN public.exos_checkout_sessions.group_buy_id IS
  'A group-buy order (one friend''s seat, or the host''s cover of the rest): fulfilled only while its seats'' holds are live and attached to it. mig 20261108120000.';

-- ---------------------------------------------------------------------------
-- 2. The holds: never past the deadline; only the group releases early.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._exos_tg_group_hold_guard()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_deadline timestamptz;
  v_gstatus  text;
BEGIN
  IF NEW.group_seat_id IS NULL THEN
    RETURN NEW;
  END IF;
  SELECT g.deadline, g.status INTO v_deadline, v_gstatus
    FROM public.exos_group_buy_seats s JOIN public.exos_group_buys g ON g.id = s.group_id
   WHERE s.id = NEW.group_seat_id;
  IF v_deadline IS NULL THEN
    RETURN NEW;
  END IF;
  -- The checkout grace (exos_tg_hold_session_grace) runs first and may push
  -- expires_at past the checkout page's end: a group seat ends at the deadline.
  NEW.expires_at := least(NEW.expires_at, v_deadline);
  IF TG_OP = 'UPDATE' AND OLD.status = 'active' AND NEW.status = 'released'
     AND coalesce(current_setting('exos.group_release', true), '') <> 'on'
     AND v_gstatus = 'open' AND now() < v_deadline THEN
    -- A checkout that failed or expired, or the host's own new cart: the seat
    -- stays with the group (exos_group_unclaim / the claim rules free it).
    NEW.status := OLD.status;
    NEW.released_at := OLD.released_at;
  END IF;
  RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION public._exos_tg_group_hold_guard() FROM PUBLIC, anon, authenticated;
-- Named to run after exos_cart_holds_session_grace (BEFORE triggers fire by name).
DROP TRIGGER IF EXISTS exos_cart_holds_zz_group_guard ON public.exos_cart_holds;
CREATE TRIGGER exos_cart_holds_zz_group_guard BEFORE INSERT OR UPDATE ON public.exos_cart_holds
  FOR EACH ROW EXECUTE FUNCTION public._exos_tg_group_hold_guard();

-- The seat follows its hold: consumed -> paid (by that hold's session),
-- expired / released -> released. The group closes when no seat is left open.
CREATE OR REPLACE FUNCTION public._exos_tg_group_hold_sync()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE v_group uuid;
BEGIN
  IF NEW.status = 'consumed' THEN
    UPDATE public.exos_group_buy_seats s
       SET status = 'paid', paid_session_id = NEW.checkout_session_id, paid_at = now(),
           covered = s.cover AND s.session_id IS NOT DISTINCT FROM NEW.checkout_session_id
     WHERE s.id = NEW.group_seat_id AND s.status <> 'paid'
    RETURNING s.group_id INTO v_group;
  ELSIF NEW.status IN ('expired', 'released') THEN
    UPDATE public.exos_group_buy_seats s
       SET status = 'released', released_at = now()
     WHERE s.id = NEW.group_seat_id AND s.status IN ('waiting', 'paying')
    RETURNING s.group_id INTO v_group;
  END IF;
  IF v_group IS NOT NULL THEN
    UPDATE public.exos_group_buys g
       SET status = 'closed', closed_at = now()
     WHERE g.id = v_group AND g.status = 'open'
       AND NOT EXISTS (SELECT 1 FROM public.exos_group_buy_seats s
                        WHERE s.group_id = v_group AND s.status IN ('waiting', 'paying'));
  END IF;
  RETURN NULL;
END $$;
REVOKE ALL ON FUNCTION public._exos_tg_group_hold_sync() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS exos_cart_holds_group_sync ON public.exos_cart_holds;
CREATE TRIGGER exos_cart_holds_group_sync AFTER UPDATE OF status ON public.exos_cart_holds
  FOR EACH ROW WHEN (NEW.group_seat_id IS NOT NULL AND OLD.status IS DISTINCT FROM NEW.status)
  EXECUTE FUNCTION public._exos_tg_group_hold_sync();

-- ---------------------------------------------------------------------------
-- 3. Fulfilment: a group order needs every seat's hold, live and its own.
-- ---------------------------------------------------------------------------
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

-- 3a. Before the session's holds are consumed: lock the group seats' holds and
--     require all of them (session -> holds, the order every group path uses).
--     Inside the all-or-nothing block, so a late payment fails and is refunded.
SELECT pg_temp.exos_patch_n('public.exos_fulfill_checkout(text)',
  '/* exos: group seat held */',
  $o$    PERFORM public.exos_consume_holds_for_session(p_session_id);$o$,
  $n$    /* exos: group seat held */ -- mig 20261108120000: a group-buy order is
    -- fulfilled only while each of its seats' holds is active, unexpired and
    -- attached to this session (not after the deadline, not after the host
    -- covered the seat, not on a friend's earlier abandoned checkout).
    IF s.group_buy_id IS NOT NULL AND (
         SELECT count(*) FROM (
           SELECT 1 FROM public.exos_cart_holds gh
            WHERE gh.checkout_session_id = p_session_id AND gh.group_seat_id IS NOT NULL
              AND gh.status = 'active' AND gh.expires_at > now()
            ORDER BY gh.id FOR UPDATE) gx) <> s.quantity THEN
      RAISE EXCEPTION 'group seat no longer held at fulfillment' USING ERRCODE = 'XF001';
    END IF;
    PERFORM public.exos_consume_holds_for_session(p_session_id);$n$, 1);

-- 3b. The failure mail says why.
SELECT pg_temp.exos_patch_n('public.exos_fulfill_checkout(text)',
  '/* exos: group seat mail */',
  $o$CASE /* exos: failure mail reasons */ WHEN v_fail LIKE 'per-account%'$o$,
  $n$CASE /* exos: failure mail reasons */ WHEN v_fail LIKE 'group seat%' /* exos: group seat mail */
               THEN '</strong> couldn''t be issued: your group''s time ran out, or the host covered your seat, before your payment came through, so your order didn''t go through. '
               WHEN v_fail LIKE 'per-account%'$n$, 1);

-- ---------------------------------------------------------------------------
-- 4. Reading a seat's state.
-- ---------------------------------------------------------------------------
-- waiting / paying / paid / covered / released, by the clock (the sweep may
-- not have run yet). 'paying' = a claim whose checkout is still open: a
-- pending session attached to the seat, or a claim of the last 5 minutes that
-- hasn't attached one yet (the checkout is being created).
CREATE OR REPLACE FUNCTION public._exos_group_seat_state(p_seat_id uuid)
RETURNS text
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT CASE
           WHEN s.status = 'paid' THEN CASE WHEN s.covered THEN 'covered' ELSE 'paid' END
           WHEN s.status = 'released' OR g.status = 'cancelled' OR now() >= g.deadline
                OR h.id IS NULL OR h.status <> 'active' OR h.expires_at <= now() THEN 'released'
           WHEN s.status = 'paying' AND (
                  (s.session_id IS NULL AND s.claimed_at > now() - interval '5 minutes')
                  OR (s.session_id IS NOT NULL AND h.checkout_session_id = s.session_id AND EXISTS (
                        SELECT 1 FROM public.exos_checkout_sessions cs
                         WHERE cs.session_id = s.session_id AND cs.status = 'pending')))
             THEN CASE WHEN s.cover THEN 'covering' ELSE 'paying' END
           ELSE 'waiting'
         END
    FROM public.exos_group_buy_seats s
    JOIN public.exos_group_buys g ON g.id = s.group_id
    LEFT JOIN public.exos_cart_holds h ON h.id = s.hold_id
   WHERE s.id = p_seat_id;
$$;
REVOKE ALL ON FUNCTION public._exos_group_seat_state(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_group_seat_state(uuid) TO service_role;

-- The group as its host sees it: every seat's state and link, the counts and
-- whether "cover the rest" is still possible. Internal (callers check the host).
CREATE OR REPLACE FUNCTION public._exos_group_buy_json(p_group_id uuid)
RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  WITH g AS (SELECT * FROM public.exos_group_buys WHERE id = p_group_id),
  seats AS (
    SELECT s.*, public._exos_group_seat_state(s.id) AS state,
           (SELECT cs.status FROM public.exos_checkout_sessions cs WHERE cs.session_id = s.paid_session_id) AS order_status
      FROM public.exos_group_buy_seats s WHERE s.group_id = p_group_id)
  SELECT jsonb_build_object(
    'id', g.id, 'org_id', g.org_id, 'event_id', g.event_id, 'tier_id', g.tier_id,
    'quantity', g.quantity, 'deadline', g.deadline, 'created_at', g.created_at,
    'status', CASE WHEN g.status = 'open' AND now() >= g.deadline THEN 'closed' ELSE g.status END,
    'server_now', clock_timestamp(),
    'counts', (SELECT jsonb_build_object(
                 'paid', count(*) FILTER (WHERE state IN ('paid', 'covered')),
                 'paying', count(*) FILTER (WHERE state IN ('paying', 'covering')),
                 'waiting', count(*) FILTER (WHERE state = 'waiting'),
                 'released', count(*) FILTER (WHERE state = 'released')) FROM seats),
    'can_cover', g.status = 'open' AND now() < g.deadline - interval '1 minute'
                 AND EXISTS (SELECT 1 FROM seats WHERE state IN ('waiting', 'paying', 'covering')),
    'seats', coalesce((SELECT jsonb_agg(jsonb_build_object(
                 'id', x.id, 'seat_no', x.seat_no, 'state', x.state,
                 'path', '/group-pay/seat/' || x.token, 'paid_at', x.paid_at,
                 'order_status', x.order_status) ORDER BY x.seat_no) FROM seats x), '[]'::jsonb))
    FROM g;
$$;
REVOKE ALL ON FUNCTION public._exos_group_buy_json(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_group_buy_json(uuid) TO service_role;

-- ---------------------------------------------------------------------------
-- 5. The host: start, read, list, cancel.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.exos_group_buy_start(p_event_id uuid, p_tier_id uuid, p_quantity int)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_uid      uuid := auth.uid();
  e          public.exos_events%ROWTYPE;
  t          public.exos_ticket_tiers%ROWTYPE;
  v_max      int;
  v_gid      uuid;
  v_deadline timestamptz := now() + interval '30 minutes';
  v_hold     uuid;
  v_seat     uuid;
  i          int;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'exos_group_buy_start: sign in to start a group' USING ERRCODE = '42501';
  END IF;
  IF p_quantity IS NULL OR p_quantity < 2 OR p_quantity > 10 THEN
    RAISE EXCEPTION 'exos_group_buy_start: a group is 2 to 10 seats' USING ERRCODE = '22023';
  END IF;
  SELECT * INTO e FROM public.exos_events WHERE id = p_event_id;
  IF NOT FOUND OR e.status <> 'published' THEN
    RAISE EXCEPTION 'exos_group_buy_start: event not on sale' USING ERRCODE = '22023';
  END IF;
  IF coalesce(e.ticket_backend, 'exos') <> 'exos' THEN
    RAISE EXCEPTION 'exos_group_buy_start: tickets for this event are sold on another site' USING ERRCODE = '22023';
  END IF;
  SELECT * INTO t FROM public.exos_ticket_tiers WHERE id = p_tier_id AND event_id = p_event_id;
  IF NOT FOUND OR coalesce(t.visibility, 'public') <> 'public' THEN
    RAISE EXCEPTION 'exos_group_buy_start: ticket type not available' USING ERRCODE = '22023';
  END IF;
  IF coalesce(t.price, 0) <= 0 THEN
    RAISE EXCEPTION 'exos_group_buy_start: free tickets don''t need a group: claim them for everyone' USING ERRCODE = '22023';
  END IF;
  IF coalesce(t.seated, false)
     OR EXISTS (SELECT 1 FROM public.exos_timed_entry te WHERE te.event_id = p_event_id AND p_tier_id = ANY (te.tier_ids))
     OR EXISTS (SELECT 1 FROM public.exos_price_steps ps WHERE ps.tier_id = p_tier_id) THEN
    RAISE EXCEPTION 'exos_group_buy_start: paying separately isn''t available for this ticket type yet' USING ERRCODE = '22023';
  END IF;
  v_max := nullif(e.purchase_limits ->> 'maxPerOrder', '')::int;
  IF v_max IS NOT NULL AND v_max > 0 AND p_quantity > v_max THEN
    RAISE EXCEPTION 'exos_group_buy_start: at most % seats per group for this event', v_max USING ERRCODE = '22023';
  END IF;

  -- One open group per host per event; at most 10 started per host per hour.
  PERFORM pg_advisory_xact_lock(hashtextextended('exos_group_buy:' || v_uid::text, 0));
  IF EXISTS (SELECT 1 FROM public.exos_group_buys g
              WHERE g.host_uid = v_uid AND g.event_id = p_event_id AND g.status = 'open' AND g.deadline > now()) THEN
    RAISE EXCEPTION 'exos_group_buy_start: you already have an open group for this event' USING ERRCODE = '23505';
  END IF;
  IF (SELECT count(*) FROM public.exos_group_buys g
       WHERE g.host_uid = v_uid AND g.created_at > now() - interval '1 hour') >= 10 THEN
    RAISE EXCEPTION 'exos_group_buy_start: too many groups started, try again later' USING ERRCODE = '53400';
  END IF;

  INSERT INTO public.exos_group_buys (org_id, event_id, tier_id, host_uid, quantity, deadline)
  VALUES (e.org_id, p_event_id, p_tier_id, v_uid, p_quantity, v_deadline)
  RETURNING id INTO v_gid;

  -- N one-seat holds through the normal hold (its checks, the host's own
  -- per-person limit for one ticket). exos_create_hold retires the host's
  -- earlier cart for the event; the guard keeps this group's seats.
  FOR i IN 1..p_quantity LOOP
    v_hold := public.exos_create_hold(p_event_id, p_tier_id, 1, 1800, NULL);
    INSERT INTO public.exos_group_buy_seats (group_id, org_id, seat_no, token, hold_id)
    VALUES (v_gid, e.org_id, i, encode(extensions.gen_random_bytes(16), 'hex'), v_hold)
    RETURNING id INTO v_seat;
    UPDATE public.exos_cart_holds SET group_seat_id = v_seat, expires_at = v_deadline WHERE id = v_hold;
  END LOOP;

  RETURN public._exos_group_buy_json(v_gid);
END $$;
REVOKE ALL ON FUNCTION public.exos_group_buy_start(uuid, uuid, int) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_group_buy_start(uuid, uuid, int) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.exos_group_buy_get(p_group_id uuid)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'exos_group_buy_get: sign in' USING ERRCODE = '42501';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.exos_group_buys g WHERE g.id = p_group_id AND g.host_uid = auth.uid()) THEN
    RAISE EXCEPTION 'exos_group_buy_get: not your group' USING ERRCODE = '42501';
  END IF;
  RETURN public._exos_group_buy_json(p_group_id);
END $$;
REVOKE ALL ON FUNCTION public.exos_group_buy_get(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_group_buy_get(uuid) TO authenticated, service_role;

-- The caller's recent groups (newest first, at most 20), for one event or all.
CREATE OR REPLACE FUNCTION public.exos_group_buy_mine(p_event_id uuid DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'exos_group_buy_mine: sign in' USING ERRCODE = '42501';
  END IF;
  RETURN coalesce((
    SELECT jsonb_agg(jsonb_build_object(
             'id', g.id, 'event_id', g.event_id, 'tier_id', g.tier_id, 'quantity', g.quantity,
             'deadline', g.deadline,
             'status', CASE WHEN g.status = 'open' AND now() >= g.deadline THEN 'closed' ELSE g.status END,
             'paid', (SELECT count(*) FROM public.exos_group_buy_seats s WHERE s.group_id = g.id AND s.status = 'paid'))
           ORDER BY g.created_at DESC)
      FROM (SELECT * FROM public.exos_group_buys g0
             WHERE g0.host_uid = auth.uid() AND (p_event_id IS NULL OR g0.event_id = p_event_id)
             ORDER BY g0.created_at DESC LIMIT 20) g), '[]'::jsonb);
END $$;
REVOKE ALL ON FUNCTION public.exos_group_buy_mine(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_group_buy_mine(uuid) TO authenticated, service_role;

-- The host ends the group now: every unpaid seat goes back on sale. A friend
-- still on a checkout page can't be issued that seat any more (refunded).
CREATE OR REPLACE FUNCTION public.exos_group_buy_cancel(p_group_id uuid)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  g     public.exos_group_buys%ROWTYPE;
  v_n   int;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'exos_group_buy_cancel: sign in' USING ERRCODE = '42501';
  END IF;
  SELECT * INTO g FROM public.exos_group_buys WHERE id = p_group_id;
  IF NOT FOUND OR g.host_uid IS DISTINCT FROM auth.uid() THEN
    RAISE EXCEPTION 'exos_group_buy_cancel: not your group' USING ERRCODE = '42501';
  END IF;
  -- holds -> seats -> group
  PERFORM 1 FROM public.exos_cart_holds h
   WHERE h.id IN (SELECT s.hold_id FROM public.exos_group_buy_seats s WHERE s.group_id = g.id)
   ORDER BY h.id FOR UPDATE;
  PERFORM 1 FROM public.exos_group_buy_seats s WHERE s.group_id = g.id ORDER BY s.id FOR UPDATE;
  SELECT * INTO g FROM public.exos_group_buys WHERE id = p_group_id FOR UPDATE;
  IF g.status <> 'open' THEN
    RETURN public._exos_group_buy_json(g.id);
  END IF;
  PERFORM set_config('exos.group_release', 'on', true);
  UPDATE public.exos_cart_holds h
     SET status = 'released', released_at = now()
   WHERE h.status = 'active'
     AND h.id IN (SELECT s.hold_id FROM public.exos_group_buy_seats s
                   WHERE s.group_id = g.id AND s.status IN ('waiting', 'paying'));
  GET DIAGNOSTICS v_n = ROW_COUNT;
  PERFORM set_config('exos.group_release', '', true);
  UPDATE public.exos_group_buy_seats SET status = 'released', released_at = now()
   WHERE group_id = g.id AND status IN ('waiting', 'paying');
  UPDATE public.exos_group_buys SET status = 'cancelled', closed_at = coalesce(closed_at, now())
   WHERE id = g.id AND (v_n > 0 OR status = 'open');
  RETURN public._exos_group_buy_json(g.id);
END $$;
REVOKE ALL ON FUNCTION public.exos_group_buy_cancel(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_group_buy_cancel(uuid) TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 6. A friend's seat page (anon): this seat only, by its 128-bit token.
-- ---------------------------------------------------------------------------
-- The event, the type, the deadline, this seat's state and how many seats of
-- the group are paid / still open. Nothing about the other friends (no names,
-- emails or links) and nothing about the host. Unknown token: NULL.
CREATE OR REPLACE FUNCTION public.exos_group_seat_view(p_token text)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  s       public.exos_group_buy_seats%ROWTYPE;
  g       public.exos_group_buys%ROWTYPE;
  e       public.exos_events%ROWTYPE;
  v_state text;
BEGIN
  IF p_token IS NULL OR p_token !~ '^[0-9a-f]{32}$' THEN
    RETURN NULL;
  END IF;
  SELECT * INTO s FROM public.exos_group_buy_seats WHERE token = p_token;
  IF NOT FOUND THEN
    RETURN NULL;
  END IF;
  SELECT * INTO g FROM public.exos_group_buys WHERE id = s.group_id;
  SELECT * INTO e FROM public.exos_events WHERE id = g.event_id AND status = 'published';
  v_state := public._exos_group_seat_state(s.id);
  RETURN jsonb_build_object(
    'seat_no', s.seat_no,
    'seats', g.quantity,
    'state', CASE WHEN e.id IS NULL AND v_state NOT IN ('paid', 'covered') THEN 'released' ELSE v_state END,
    'mine', auth.uid() IS NOT NULL AND s.claim_uid = auth.uid() AND v_state = 'paying',
    'is_host', auth.uid() IS NOT NULL AND g.host_uid = auth.uid(),
    'group_id', CASE WHEN auth.uid() IS NOT NULL AND g.host_uid = auth.uid() THEN g.id END,
    'deadline', g.deadline,
    'server_now', clock_timestamp(),
    'group_status', CASE WHEN g.status = 'open' AND now() >= g.deadline THEN 'closed' ELSE g.status END,
    'paid', (SELECT count(*) FROM public.exos_group_buy_seats x WHERE x.group_id = g.id AND x.status = 'paid'),
    'open', (SELECT count(*) FROM public.exos_group_buy_seats x
              WHERE x.group_id = g.id AND public._exos_group_seat_state(x.id) IN ('waiting', 'paying', 'covering')),
    'event_id', g.event_id,
    'tier_id', g.tier_id,
    'event', CASE WHEN e.id IS NULL THEN NULL ELSE jsonb_build_object(
               'name', e.name, 'starts_at', e.starts_at, 'venue_name', e.venue_name,
               'image_url', e.image_url, 'currency', e.currency, 'timezone', e.timezone) END);
END $$;
REVOKE ALL ON FUNCTION public.exos_group_seat_view(text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_group_seat_view(text) TO anon, authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 7. exos-checkout (service role): context, claim, attach, unclaim.
-- ---------------------------------------------------------------------------
-- Errors carry an SQLSTATE exos-checkout maps to a reason:
--   XG404 bad link, XG403 not the host, XG410 time ran out / group closed,
--   XG411 already paid, XG409 taken (a friend, or the host covering it),
--   XG412 the group changed (cover count), XG400 another ticket type.
-- Service role only: EXECUTE is granted to nobody else.

-- What a group checkout buys: { group_id, event_id, tier_id, quantity }.
-- A seat link: that seat (1). The host's cover: every unpaid seat still held.
CREATE OR REPLACE FUNCTION public.exos_group_checkout_ctx(p_token text, p_group_id uuid, p_buyer uuid)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  s       public.exos_group_buy_seats%ROWTYPE;
  g       public.exos_group_buys%ROWTYPE;
  v_state text;
  v_n     int;
BEGIN
  IF (p_token IS NULL) = (p_group_id IS NULL) THEN
    RAISE EXCEPTION 'this group link isn''t valid' USING ERRCODE = 'XG404';
  END IF;
  IF p_token IS NOT NULL THEN
    SELECT * INTO s FROM public.exos_group_buy_seats WHERE token = p_token AND p_token ~ '^[0-9a-f]{32}$';
    IF NOT FOUND THEN
      RAISE EXCEPTION 'this group link isn''t valid' USING ERRCODE = 'XG404';
    END IF;
    SELECT * INTO g FROM public.exos_group_buys WHERE id = s.group_id;
  ELSE
    SELECT * INTO g FROM public.exos_group_buys WHERE id = p_group_id;
    IF NOT FOUND OR p_buyer IS NULL OR g.host_uid IS DISTINCT FROM p_buyer THEN
      RAISE EXCEPTION 'only the host can cover the rest' USING ERRCODE = 'XG403';
    END IF;
  END IF;
  IF g.status <> 'open' OR now() >= g.deadline - interval '1 minute' THEN
    RAISE EXCEPTION 'this group''s time ran out: the seats are back on sale' USING ERRCODE = 'XG410';
  END IF;
  IF p_token IS NOT NULL THEN
    v_state := public._exos_group_seat_state(s.id);
    IF v_state IN ('paid', 'covered') THEN
      RAISE EXCEPTION 'this seat is already paid for' USING ERRCODE = 'XG411';
    ELSIF v_state = 'released' THEN
      RAISE EXCEPTION 'this group''s time ran out: the seats are back on sale' USING ERRCODE = 'XG410';
    END IF;
    v_n := 1;
  ELSE
    SELECT count(*) INTO v_n FROM public.exos_group_buy_seats x
     WHERE x.group_id = g.id AND public._exos_group_seat_state(x.id) IN ('waiting', 'paying', 'covering');
    IF v_n = 0 THEN
      RAISE EXCEPTION 'there are no seats left to cover' USING ERRCODE = 'XG411';
    END IF;
  END IF;
  RETURN jsonb_build_object('group_id', g.id, 'event_id', g.event_id, 'tier_id', g.tier_id, 'quantity', v_n);
END $$;
REVOKE ALL ON FUNCTION public.exos_group_checkout_ctx(text, uuid, uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_group_checkout_ctx(text, uuid, uuid) TO service_role;

-- Claim the seat (or, for the host's cover, every unpaid seat) for a buyer at
-- the point a normal checkout takes its hold. Returns the (first) seat's hold
-- id: the hold the checkout carries. A seat a friend is paying for is taken;
-- the same buyer may start over. The cover takes every unpaid seat.
CREATE OR REPLACE FUNCTION public.exos_group_claim(
  p_token    text,
  p_group_id uuid,
  p_buyer    uuid,
  p_email    text,
  p_event_id uuid,
  p_tier_id  uuid,
  p_quantity int
) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_email text := nullif(lower(btrim(coalesce(p_email, ''))), '');
  v_gid   uuid;
  v_seat  uuid;
  s       public.exos_group_buy_seats%ROWTYPE;
  g       public.exos_group_buys%ROWTYPE;
  v_state text;
  v_ids   uuid[];
  v_hold  uuid;
BEGIN
  IF (p_token IS NULL) = (p_group_id IS NULL) THEN
    RAISE EXCEPTION 'this group link isn''t valid' USING ERRCODE = 'XG404';
  END IF;
  IF p_buyer IS NULL AND v_email IS NULL THEN
    RAISE EXCEPTION 'who is paying?' USING ERRCODE = '22023';
  END IF;
  IF p_token IS NOT NULL THEN
    SELECT id, group_id INTO v_seat, v_gid FROM public.exos_group_buy_seats
     WHERE token = p_token AND p_token ~ '^[0-9a-f]{32}$';
    IF v_seat IS NULL THEN
      RAISE EXCEPTION 'this group link isn''t valid' USING ERRCODE = 'XG404';
    END IF;
  ELSE
    v_gid := p_group_id;
  END IF;
  SELECT * INTO g FROM public.exos_group_buys WHERE id = v_gid;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'this group link isn''t valid' USING ERRCODE = 'XG404';
  END IF;
  IF p_token IS NULL AND (p_buyer IS NULL OR p_buyer IS DISTINCT FROM g.host_uid) THEN
    RAISE EXCEPTION 'only the host can cover the rest' USING ERRCODE = 'XG403';
  END IF;
  IF g.event_id IS DISTINCT FROM p_event_id OR g.tier_id IS DISTINCT FROM p_tier_id THEN
    RAISE EXCEPTION 'this group is for another ticket' USING ERRCODE = 'XG400';
  END IF;
  -- The checks the normal hold makes of its buyer (exos_create_hold /
  -- exos_create_guest_hold): a confirmed account, or guests allowed.
  IF p_buyer IS NOT NULL AND NOT EXISTS (
       SELECT 1 FROM auth.users u WHERE u.id = p_buyer AND u.email_confirmed_at IS NOT NULL) THEN
    RAISE EXCEPTION 'confirm your email before paying for a seat' USING ERRCODE = '42501';
  END IF;
  IF p_buyer IS NULL AND lower(coalesce((SELECT e.purchase_limits ->> 'guestCheckout'
                                           FROM public.exos_events e WHERE e.id = g.event_id), '')) = 'false' THEN
    RAISE EXCEPTION 'sign in to buy tickets for this event' USING ERRCODE = '42501';
  END IF;

  -- holds -> seats -> group
  PERFORM 1 FROM public.exos_cart_holds h
   WHERE h.id IN (SELECT x.hold_id FROM public.exos_group_buy_seats x
                   WHERE x.group_id = g.id AND (v_seat IS NULL OR x.id = v_seat))
   ORDER BY h.id FOR UPDATE;
  PERFORM 1 FROM public.exos_group_buy_seats x
   WHERE x.group_id = g.id AND (v_seat IS NULL OR x.id = v_seat) ORDER BY x.id FOR UPDATE;
  SELECT * INTO g FROM public.exos_group_buys WHERE id = v_gid FOR UPDATE;
  IF g.status <> 'open' OR now() >= g.deadline - interval '1 minute' THEN
    RAISE EXCEPTION 'this group''s time ran out: the seats are back on sale' USING ERRCODE = 'XG410';
  END IF;

  IF v_seat IS NOT NULL THEN
    IF p_quantity IS DISTINCT FROM 1 THEN
      RAISE EXCEPTION 'a group seat is one ticket' USING ERRCODE = 'XG400';
    END IF;
    SELECT * INTO s FROM public.exos_group_buy_seats WHERE id = v_seat;
    v_state := public._exos_group_seat_state(s.id);
    IF v_state IN ('paid', 'covered') THEN
      RAISE EXCEPTION 'this seat is already paid for' USING ERRCODE = 'XG411';
    ELSIF v_state = 'released' THEN
      RAISE EXCEPTION 'this group''s time ran out: the seats are back on sale' USING ERRCODE = 'XG410';
    ELSIF v_state = 'covering' THEN
      RAISE EXCEPTION 'seat already taken: the host is paying for the rest of the group' USING ERRCODE = 'XG409';
    ELSIF v_state = 'paying' AND NOT (
            (p_buyer IS NOT NULL AND s.claim_uid = p_buyer)
            OR (p_buyer IS NULL AND s.claim_uid IS NULL AND s.claim_email = v_email)) THEN
      RAISE EXCEPTION 'seat already taken: a friend is paying for it right now' USING ERRCODE = 'XG409';
    END IF;
    UPDATE public.exos_group_buy_seats
       SET status = 'paying', cover = false, claim_uid = p_buyer, claim_email = v_email,
           claimed_at = now(), session_id = NULL
     WHERE id = s.id;
    RETURN s.hold_id;
  END IF;

  -- The host's cover: every unpaid seat whose hold is still live.
  SELECT array_agg(x.id ORDER BY x.seat_no), (array_agg(x.hold_id ORDER BY x.seat_no))[1]
    INTO v_ids, v_hold
    FROM public.exos_group_buy_seats x
   WHERE x.group_id = g.id AND public._exos_group_seat_state(x.id) IN ('waiting', 'paying', 'covering');
  IF coalesce(cardinality(v_ids), 0) = 0 THEN
    RAISE EXCEPTION 'there are no seats left to cover' USING ERRCODE = 'XG411';
  END IF;
  IF cardinality(v_ids) IS DISTINCT FROM p_quantity THEN
    RAISE EXCEPTION 'the group just changed: check the seats and try again' USING ERRCODE = 'XG412';
  END IF;
  UPDATE public.exos_group_buy_seats
     SET status = 'paying', cover = true, claim_uid = p_buyer, claim_email = v_email,
         claimed_at = now(), session_id = NULL
   WHERE id = ANY (v_ids);
  RETURN v_hold;
END $$;
REVOKE ALL ON FUNCTION public.exos_group_claim(text, uuid, uuid, text, uuid, uuid, int) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_group_claim(text, uuid, uuid, text, uuid, uuid, int) TO service_role;

-- Attach the claimed seat(s)' holds to the checkout session just recorded.
-- Every seat must still be claimed by this session's buyer, with its hold
-- live; the session must match the group (org, event, type, quantity). The
-- hold then ends at the deadline whatever the checkout page's expiry.
CREATE OR REPLACE FUNCTION public.exos_group_attach(p_session_id text, p_token text, p_group_id uuid)
RETURNS int
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  cs      public.exos_checkout_sessions%ROWTYPE;
  g       public.exos_group_buys%ROWTYPE;
  v_seat  uuid;
  v_gid   uuid;
  v_ids   uuid[];
  v_holds uuid[];
  v_ok    int;
BEGIN
  IF (p_token IS NULL) = (p_group_id IS NULL) THEN
    RAISE EXCEPTION 'this group link isn''t valid' USING ERRCODE = 'XG404';
  END IF;
  -- session -> holds -> seats -> group
  SELECT * INTO cs FROM public.exos_checkout_sessions WHERE session_id = p_session_id FOR UPDATE;
  IF NOT FOUND OR cs.status <> 'pending' THEN
    RAISE EXCEPTION 'exos_group_attach: no pending order %', p_session_id USING ERRCODE = 'P0002';
  END IF;
  IF p_token IS NOT NULL THEN
    SELECT id, group_id INTO v_seat, v_gid FROM public.exos_group_buy_seats WHERE token = p_token;
  ELSE
    v_gid := p_group_id;
  END IF;
  SELECT * INTO g FROM public.exos_group_buys WHERE id = v_gid;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'this group link isn''t valid' USING ERRCODE = 'XG404';
  END IF;
  IF cs.org_id IS DISTINCT FROM g.org_id OR cs.event_id IS DISTINCT FROM g.event_id OR cs.tier_id IS DISTINCT FROM g.tier_id THEN
    RAISE EXCEPTION 'this group is for another ticket' USING ERRCODE = 'XG400';
  END IF;
  IF p_token IS NULL AND cs.buyer_uid IS DISTINCT FROM g.host_uid THEN
    RAISE EXCEPTION 'only the host can cover the rest' USING ERRCODE = 'XG403';
  END IF;

  SELECT array_agg(x.id ORDER BY x.id), array_agg(x.hold_id ORDER BY x.id) INTO v_ids, v_holds
    FROM public.exos_group_buy_seats x
   WHERE x.group_id = g.id AND x.status = 'paying'
     AND (CASE WHEN v_seat IS NOT NULL THEN x.id = v_seat AND NOT x.cover ELSE x.cover END);
  PERFORM 1 FROM public.exos_cart_holds h WHERE h.id = ANY (coalesce(v_holds, '{}')) ORDER BY h.id FOR UPDATE;
  PERFORM 1 FROM public.exos_group_buy_seats x WHERE x.id = ANY (coalesce(v_ids, '{}')) ORDER BY x.id FOR UPDATE;
  SELECT * INTO g FROM public.exos_group_buys WHERE id = v_gid FOR UPDATE;

  SELECT count(*) INTO v_ok
    FROM public.exos_group_buy_seats x
    JOIN public.exos_cart_holds h ON h.id = x.hold_id
   WHERE x.id = ANY (coalesce(v_ids, '{}')) AND x.status = 'paying'
     AND h.status = 'active' AND h.expires_at > now() AND h.group_seat_id = x.id
     AND ((cs.buyer_uid IS NOT NULL AND x.claim_uid = cs.buyer_uid)
          OR (cs.buyer_uid IS NULL AND x.claim_uid IS NULL AND x.claim_email = lower(cs.buyer_email)));
  IF g.status <> 'open' OR now() >= g.deadline OR v_ok = 0 OR v_ok <> coalesce(cardinality(v_ids), 0)
     OR v_ok <> cs.quantity THEN
    RAISE EXCEPTION 'seat already taken: the group changed while you were checking out' USING ERRCODE = 'XG409';
  END IF;

  UPDATE public.exos_cart_holds SET checkout_session_id = p_session_id WHERE id = ANY (v_holds);
  UPDATE public.exos_group_buy_seats SET session_id = p_session_id WHERE id = ANY (v_ids);
  UPDATE public.exos_checkout_sessions SET group_buy_id = g.id WHERE session_id = p_session_id;
  RETURN v_ok;
END $$;
REVOKE ALL ON FUNCTION public.exos_group_attach(text, text, uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_group_attach(text, text, uuid) TO service_role;

-- A group checkout failed before the buyer could pay: give the claimed
-- seat(s) back to the group (not to sale) and detach the holds, so the failed
-- order can't be fulfilled. Only the claimant's own seats.
CREATE OR REPLACE FUNCTION public.exos_group_unclaim(p_token text, p_group_id uuid, p_buyer uuid, p_email text)
RETURNS int
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_email text := nullif(lower(btrim(coalesce(p_email, ''))), '');
  v_gid   uuid;
  v_seat  uuid;
  v_ids   uuid[];
  v_holds uuid[];
  v_n     int;
BEGIN
  IF (p_token IS NULL) = (p_group_id IS NULL) THEN
    RETURN 0;
  END IF;
  IF p_token IS NOT NULL THEN
    SELECT id, group_id INTO v_seat, v_gid FROM public.exos_group_buy_seats WHERE token = p_token;
  ELSE
    v_gid := p_group_id;
  END IF;
  IF v_gid IS NULL THEN
    RETURN 0;
  END IF;
  SELECT array_agg(x.id ORDER BY x.id), array_agg(x.hold_id ORDER BY x.id) INTO v_ids, v_holds
    FROM public.exos_group_buy_seats x
   WHERE x.group_id = v_gid AND x.status = 'paying'
     AND (CASE WHEN v_seat IS NOT NULL THEN x.id = v_seat AND NOT x.cover ELSE x.cover END)
     AND ((p_buyer IS NOT NULL AND x.claim_uid = p_buyer)
          OR (p_buyer IS NULL AND x.claim_uid IS NULL AND x.claim_email = v_email));
  IF v_ids IS NULL THEN
    RETURN 0;
  END IF;
  -- holds -> seats -> (no group change)
  PERFORM 1 FROM public.exos_cart_holds h WHERE h.id = ANY (v_holds) ORDER BY h.id FOR UPDATE;
  PERFORM 1 FROM public.exos_group_buy_seats x WHERE x.id = ANY (v_ids) ORDER BY x.id FOR UPDATE;
  -- Detach only from this buyer's own checkouts: a seat the host's failed
  -- cover had taken keeps a friend's open checkout on it.
  UPDATE public.exos_cart_holds h SET checkout_session_id = NULL
   WHERE h.id = ANY (v_holds) AND h.status = 'active'
     AND EXISTS (SELECT 1 FROM public.exos_checkout_sessions cs
                  WHERE cs.session_id = h.checkout_session_id
                    AND ((p_buyer IS NOT NULL AND cs.buyer_uid = p_buyer)
                         OR (p_buyer IS NULL AND cs.buyer_uid IS NULL AND lower(cs.buyer_email) = v_email)));
  UPDATE public.exos_group_buy_seats
     SET status = 'waiting', cover = false, claim_uid = NULL, claim_email = NULL, claimed_at = NULL, session_id = NULL
   WHERE id = ANY (v_ids) AND status = 'paying'
     AND ((p_buyer IS NOT NULL AND claim_uid = p_buyer)
          OR (p_buyer IS NULL AND claim_uid IS NULL AND claim_email = v_email));
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN v_n;
END $$;
REVOKE ALL ON FUNCTION public.exos_group_unclaim(text, uuid, uuid, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_group_unclaim(text, uuid, uuid, text) TO service_role;
