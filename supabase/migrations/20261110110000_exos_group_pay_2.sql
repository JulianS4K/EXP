-- ============================================================================
-- Migration 20261110110000 — Exos: group buy v2 follow-ups
--                            (KANBAN "Group buy / split pay")
--
-- Branch:   claude/exos-group-pay-2
-- Touches:  W: TABLE exos_group_buys (+slot_id, +price_step_id,
--                 +unit_price_cents: the group's time slot and locked price)
--              TABLE exos_group_buy_seats (+label: the host's name for a
--                 seat; new policies exos_group_buy_seats_host_sel /
--                 _host_label: the host or a platform admin; column grants:
--                 authenticated reads the seat's state and label, never its
--                 token or claimant, and writes only label)
--              FUNCTION exos_group_buy_start (3 args -> 4: + p_slot_id;
--                 dropped and recreated: timed and price-step types allowed)
--              FUNCTION _exos_group_buy_json, exos_group_checkout_ctx
--                 (redefined: + label / slot / locked price)
--              FUNCTION exos_group_seat_view (marker
--                 '/* exos: seat view price slot */')
--              FUNCTION exos_group_attach (marker '/* exos: group attach slot step */')
--              FUNCTION exos_group_claim (markers '/* exos: audit order.group_cover */',
--                 '/* exos: group reclaim guard */')
--              FUNCTION exos_group_buy_cancel (marker '/* exos: audit hold.group_cancel */')
--              FUNCTION exos_group_pages_to_expire (new, service role:
--                 exos-reconcile-checkouts)
--           R: exos_create_hold, exos_attach_hold_slot, _exos_tier_is_timed,
--              exos_tier_current_price, exos_price_steps, _exos_audit
-- Pre-reqs: 20261108120000 (group pay), 20261109100000 (_exos_audit),
--           20261109110000 (its seat view patch), 20261106130000 (price
--           steps), 20261030150000 (timed entry)
--
-- 1. Friends' open Stripe pages close with their seat. A group order's
--    Checkout Session (cs_...) that can't be fulfilled any more (the group's
--    deadline passed, the host ended the group or covered the seat, the
--    friend started over on another page) is listed by
--    exos_group_pages_to_expire; exos-reconcile-checkouts (the existing
--    15-minute cron, no new one) expires each one at Stripe
--    (POST /v1/checkout/sessions/:id/expire, the platform's own account) and
--    marks the row expired. The same test exos_fulfill_checkout makes ("every
--    seat's hold active, unexpired and attached to this order"); pages under
--    2 minutes old are left alone (exos-checkout records the order before it
--    attaches the seat). A payment that lands first still fails at
--    fulfilment and is auto-refunded: the backstop stays.
-- 2. Price steps (mig 20261106130000). A group is priced at ONE step, like
--    any order (boundary rule CAP): the start locks the type's steps after
--    taking the N holds, reads the current step under that lock, refuses
--    with XP410 when the step has fewer than N places left, and stamps every
--    seat's hold with the step and its price (exos_hold_lock_price's
--    columns), so the seats count against the step for the whole window. A
--    friend pays their seat's locked price; the host's cover pays each
--    covered seat's locked price (one price: a group never spans two steps).
--    exos-checkout takes the price from exos_group_checkout_ctx, never from
--    the client, and records the step on the order (its tickets take it).
-- 3. Timed entry (mig 20261030150000). The host picks the slot; every seat's
--    hold is put on it through exos_attach_hold_slot (the slot's capacity
--    check, under its row lock), and each order records the group's slot.
-- 4. Seat labels. The host can name a seat ("Sam"): exos_group_buy_seats.
--    label, readable and writable by the group's host or a platform admin
--    (RLS + column grants); on the host's page only, never in
--    exos_group_seat_view.
-- 5. Still refused: reserved seating, hidden types, free tickets, and
--    add-ons, gift cards and donations on a group seat (exos-checkout).
-- 6. Audit (mig 20261109100000): the host's cover (order.group_cover, at the
--    claim, with the seats' face total) and cancel (hold.group_cancel).
-- 7. Abuse limits (review 2026-11-09). A start counts the whole group against
--    the host's maxPerAccount (tickets + every live hold in their name + this
--    group), live group seats of all hosts reserve at most a quarter of what's
--    left (>= 10, the guest-hold ceiling's rule), and a host starts at most 3
--    groups an hour whatever became of them. A seat's same buyer can't
--    re-claim within 2 minutes (XG429), and exos-checkout rate-limits group
--    claims before any Stripe call.
--
-- Lock order unchanged: session -> holds -> seats -> group; start: pools ->
-- type (exos_create_hold) -> hold -> slot row (exos_attach_hold_slot) ->
-- the type's steps, as a checkout's hold -> slot -> price lock.
--
-- Additive, re-run safe (IF NOT EXISTS / CREATE OR REPLACE / marker patches;
-- the old 3-argument start is dropped). No cron, no sequence. Not applied;
-- prod apply needs operator OK.
-- ROLLBACK: drop exos_group_pages_to_expire and the two new policies; re-run
--   20261108120000's start / ctx / json / attach / claim / cancel and
--   20261109110000's seat view patch; drop the 4-argument start; the new
--   columns can stay (NULL).
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
-- 1. Columns.
-- ---------------------------------------------------------------------------
ALTER TABLE public.exos_group_buys
  ADD COLUMN IF NOT EXISTS slot_id text CONSTRAINT exos_group_buys_slot_chk CHECK (slot_id IS NULL OR slot_id ~ '^\d{8}T\d{4}$'),
  ADD COLUMN IF NOT EXISTS price_step_id uuid REFERENCES public.exos_price_steps (id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS unit_price_cents integer CONSTRAINT exos_group_buys_unit_price_chk CHECK (unit_price_cents IS NULL OR unit_price_cents > 0);
CREATE INDEX IF NOT EXISTS exos_group_buys_price_step_idx ON public.exos_group_buys (price_step_id) WHERE price_step_id IS NOT NULL;
COMMENT ON COLUMN public.exos_group_buys.slot_id IS
  'Timed entry: the slot every seat of the group is held on (mig 20261110110000).';
COMMENT ON COLUMN public.exos_group_buys.unit_price_cents IS
  'Price steps: the face price every seat locked at the start (one step per group, CAP). NULL: a type without steps (mig 20261110110000).';

ALTER TABLE public.exos_group_buy_seats
  ADD COLUMN IF NOT EXISTS label text CONSTRAINT exos_group_buy_seats_label_chk
    CHECK (label IS NULL OR (char_length(label) BETWEEN 1 AND 40 AND label = btrim(label) AND label !~ '[[:cntrl:]]'));
COMMENT ON COLUMN public.exos_group_buy_seats.label IS
  'The host''s name for the seat ("Sam"). Host and platform admins only; never on the friend''s seat page (mig 20261110110000).';

-- The host reads their seats' state and label and writes only the label.
-- Tokens, claimants and order ids stay out of every client read (the host
-- gets the links through exos_group_buy_get). exos_group_buy_seats_sel (admins)
-- is unchanged; these add the host.
REVOKE SELECT, UPDATE ON public.exos_group_buy_seats FROM authenticated;
GRANT SELECT (id, group_id, org_id, seat_no, label, status, cover, covered, paid_at, released_at, created_at, updated_at)
  ON public.exos_group_buy_seats TO authenticated;
GRANT UPDATE (label) ON public.exos_group_buy_seats TO authenticated;
DROP POLICY IF EXISTS exos_group_buy_seats_host_sel ON public.exos_group_buy_seats;
CREATE POLICY exos_group_buy_seats_host_sel ON public.exos_group_buy_seats FOR SELECT TO authenticated
  USING (EXISTS (SELECT 1 FROM public.exos_group_buys g WHERE g.id = group_id AND g.host_uid = (SELECT auth.uid())));
DROP POLICY IF EXISTS exos_group_buy_seats_host_label ON public.exos_group_buy_seats;
CREATE POLICY exos_group_buy_seats_host_label ON public.exos_group_buy_seats FOR UPDATE TO authenticated
  USING ((SELECT public.exos_is_admin())
         OR EXISTS (SELECT 1 FROM public.exos_group_buys g WHERE g.id = group_id AND g.host_uid = (SELECT auth.uid())))
  WITH CHECK ((SELECT public.exos_is_admin())
         OR EXISTS (SELECT 1 FROM public.exos_group_buys g WHERE g.id = group_id AND g.host_uid = (SELECT auth.uid())));

-- ---------------------------------------------------------------------------
-- 2. Start: timed slots and price steps.
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.exos_group_buy_start(uuid, uuid, int);
CREATE OR REPLACE FUNCTION public.exos_group_buy_start(p_event_id uuid, p_tier_id uuid, p_quantity int, p_slot_id text DEFAULT NULL)
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
  v_timed    boolean;
  v_cur      jsonb;
  v_step     uuid;
  v_price    int;
  v_rem      int;
  v_acct     int;
  v_have     int;
  v_avail    int;
  v_grouped  int;
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
  -- Still refused: reserved seating (each friend would need their own seat
  -- picked; a group seat carries one general-admission hold).
  IF coalesce(t.seated, false) THEN
    RAISE EXCEPTION 'exos_group_buy_start: paying separately isn''t available for reserved seating: pick your seats and pay together' USING ERRCODE = '22023';
  END IF;
  -- Timed entry: one slot for the whole group.
  v_timed := public._exos_tier_is_timed(p_tier_id);
  IF v_timed AND (p_slot_id IS NULL OR p_slot_id !~ '^\d{8}T\d{4}$') THEN
    RAISE EXCEPTION 'exos_group_buy_start: pick a date and time slot first' USING ERRCODE = '22023';
  ELSIF NOT v_timed AND p_slot_id IS NOT NULL THEN
    RAISE EXCEPTION 'exos_group_buy_start: this ticket type isn''t sold by time slot' USING ERRCODE = '22023';
  END IF;
  -- Free (the base price, or the current price step): no group needed.
  v_cur := public.exos_tier_current_price(p_tier_id, now(), 'online');
  IF coalesce((v_cur ->> 'price_cents')::int, 0) <= 0 THEN
    RAISE EXCEPTION 'exos_group_buy_start: free tickets don''t need a group: claim them for everyone' USING ERRCODE = '22023';
  END IF;
  v_max := nullif(e.purchase_limits ->> 'maxPerOrder', '')::int;
  IF v_max IS NOT NULL AND v_max > 0 AND p_quantity > v_max THEN
    RAISE EXCEPTION 'exos_group_buy_start: at most % seats per group for this event', v_max USING ERRCODE = '22023';
  END IF;
  -- /* exos: group per-account cap */ (review 2026-11-09): each seat's hold is a
  -- one-ticket exos_create_hold, which checks only 1 against maxPerAccount, and
  -- the guard keeps earlier group holds alive. A group is the host's order
  -- until friends pay (the cover issues every unpaid seat to the host), so the
  -- whole group counts against the host's maxPerAccount.
  v_acct := nullif(e.purchase_limits ->> 'maxPerAccount', '')::int;
  IF v_acct IS NOT NULL AND v_acct > 0 AND p_quantity > v_acct THEN
    RAISE EXCEPTION 'exos_group_buy_start: this event allows % ticket% per person, and a group is held in your name until friends pay: start a group of at most %',
      v_acct, CASE WHEN v_acct = 1 THEN '' ELSE 's' END, v_acct USING ERRCODE = '22023';
  END IF;

  -- One open group per host per event; at most 3 STARTED per host per hour,
  -- whatever became of them (cancelled and expired ones count), so cancel and
  -- restart can't keep seats off sale: one group, one retry after a mistake
  -- and one spare. (Was 10, which let one account cycle 100 held seats an hour.)
  PERFORM pg_advisory_xact_lock(hashtextextended('exos_group_buy:' || v_uid::text, 0));
  IF EXISTS (SELECT 1 FROM public.exos_group_buys g
              WHERE g.host_uid = v_uid AND g.event_id = p_event_id AND g.status = 'open' AND g.deadline > now()) THEN
    RAISE EXCEPTION 'exos_group_buy_start: you already have an open group for this event' USING ERRCODE = '23505';
  END IF;
  IF (SELECT count(*) FROM public.exos_group_buys g
       WHERE g.host_uid = v_uid AND g.created_at > now() - interval '1 hour') >= 3 THEN
    RAISE EXCEPTION 'exos_group_buy_start: too many groups started, try again in an hour' USING ERRCODE = '53400';
  END IF;
  -- maxPerAccount, cumulative: the host's tickets for the event, plus every
  -- live hold in their name (seats of any group, and a normal cart), plus this
  -- group. Under exos_assert_purchase_limit's own lock for (event, host).
  IF v_acct IS NOT NULL AND v_acct > 0 THEN
    PERFORM pg_advisory_xact_lock(hashtextextended(p_event_id::text || ':' || v_uid::text, 0));
    SELECT count(*) INTO v_have FROM public.exos_tickets
     WHERE event_id = p_event_id AND owner_id = v_uid AND status <> 'voided';
    v_have := v_have + (SELECT coalesce(sum(h.quantity), 0)::int FROM public.exos_cart_holds h
                         WHERE h.event_id = p_event_id AND h.buyer_uid = v_uid AND h.status = 'active' AND h.expires_at > now());
    IF v_have + p_quantity > v_acct THEN
      RAISE EXCEPTION 'exos_group_buy_start: this event allows % ticket% per person and you already have or hold %: start a group of at most %',
        v_acct, CASE WHEN v_acct = 1 THEN '' ELSE 's' END, v_have, greatest(v_acct - v_have, 0) USING ERRCODE = '23514';
    END IF;
  END IF;
  -- /* exos: group event ceiling */ Live group seats of ALL hosts reserve at
  -- most a quarter of what's left (at least 10 seats), the guest-hold ceiling's
  -- rule (exos_create_guest_hold), under one lock per event.
  PERFORM pg_advisory_xact_lock(hashtextextended('exos_group_ceiling:' || p_event_id::text, 0));
  v_avail := public.exos_effective_available(p_tier_id);
  SELECT coalesce(sum(h.quantity), 0)::int INTO v_grouped FROM public.exos_cart_holds h
   WHERE h.event_id = p_event_id AND h.group_seat_id IS NOT NULL AND h.status = 'active' AND h.expires_at > now();
  IF v_grouped + p_quantity > greatest(10, ceil((coalesce(v_avail, 1000000) + v_grouped) / 4.0)::int) THEN
    RAISE EXCEPTION 'exos_group_buy_start: lots of groups are holding seats for this event right now: start a smaller group, buy now, or try again shortly'
      USING ERRCODE = '53400';
  END IF;

  INSERT INTO public.exos_group_buys (org_id, event_id, tier_id, host_uid, quantity, deadline, slot_id)
  VALUES (e.org_id, p_event_id, p_tier_id, v_uid, p_quantity, v_deadline, CASE WHEN v_timed THEN p_slot_id END)
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
    -- Timed entry: the seat's hold takes a place in the group's slot (the
    -- slot's own capacity check, under its row lock), as a checkout's does.
    IF v_timed THEN
      BEGIN
        PERFORM public.exos_attach_hold_slot(v_hold, p_slot_id);
      EXCEPTION WHEN others THEN
        RAISE EXCEPTION 'exos_group_buy_start: %', regexp_replace(SQLERRM, '^exos_attach_hold_slot: ', '') USING ERRCODE = SQLSTATE;
      END;
    END IF;
  END LOOP;

  -- Price steps: one step for the whole group (CAP, as any order), locked on
  -- every seat's hold under the lock exos_hold_lock_price takes. The holds
  -- carry no step yet, so they don't count against it in this read.
  IF EXISTS (SELECT 1 FROM public.exos_price_steps WHERE tier_id = p_tier_id) THEN
    PERFORM 1 FROM public.exos_price_steps WHERE tier_id = p_tier_id ORDER BY sort_order, id FOR UPDATE;
    v_cur := public.exos_tier_current_price(p_tier_id, now(), 'online');
    v_step := (v_cur ->> 'step_id')::uuid;
    v_price := (v_cur ->> 'price_cents')::int;
    v_rem := (v_cur ->> 'step_remaining')::int;
    IF coalesce(v_price, 0) <= 0 THEN
      RAISE EXCEPTION 'exos_group_buy_start: free tickets don''t need a group: claim them for everyone' USING ERRCODE = '22023';
    END IF;
    IF v_step IS NOT NULL AND v_rem IS NOT NULL AND v_rem < p_quantity * public.exos_tier_party_size(p_tier_id) THEN
      IF v_rem >= 2 THEN
        RAISE EXCEPTION 'exos_group_buy_start: only % left at this price, and a group pays one price: start a group of % (or fewer)', v_rem, v_rem
          USING ERRCODE = 'XP410', DETAIL = jsonb_build_object('remaining', v_rem, 'price_cents', v_price)::text;
      END IF;
      RAISE EXCEPTION 'exos_group_buy_start: only % left at this price, and a group pays one price: start the group at the next price', greatest(v_rem, 0)
        USING ERRCODE = 'XP410', DETAIL = jsonb_build_object('remaining', greatest(v_rem, 0), 'price_cents', v_price)::text;
    END IF;
    IF v_step IS NOT NULL THEN
      UPDATE public.exos_cart_holds SET price_step_id = v_step, unit_price_cents = v_price
       WHERE id IN (SELECT s.hold_id FROM public.exos_group_buy_seats s WHERE s.group_id = v_gid);
      UPDATE public.exos_group_buys SET price_step_id = v_step, unit_price_cents = v_price WHERE id = v_gid;
    END IF;
  END IF;

  RETURN public._exos_group_buy_json(v_gid);
END $$;
REVOKE ALL ON FUNCTION public.exos_group_buy_start(uuid, uuid, int, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_group_buy_start(uuid, uuid, int, text) TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 3. What the host reads: + each seat's label, the slot and the locked price.
-- ---------------------------------------------------------------------------
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
    'slot_id', g.slot_id,
    'unit_price_cents', g.unit_price_cents,
    'counts', (SELECT jsonb_build_object(
                 'paid', count(*) FILTER (WHERE state IN ('paid', 'covered')),
                 'paying', count(*) FILTER (WHERE state IN ('paying', 'covering')),
                 'waiting', count(*) FILTER (WHERE state = 'waiting'),
                 'released', count(*) FILTER (WHERE state = 'released')) FROM seats),
    'can_cover', g.status = 'open' AND now() < g.deadline - interval '1 minute'
                 AND EXISTS (SELECT 1 FROM seats WHERE state IN ('waiting', 'paying', 'covering')),
    'seats', coalesce((SELECT jsonb_agg(jsonb_build_object(
                 'id', x.id, 'seat_no', x.seat_no, 'state', x.state, 'label', x.label,
                 'path', '/group-pay/seat/' || x.token, 'paid_at', x.paid_at,
                 'order_status', x.order_status) ORDER BY x.seat_no) FROM seats x), '[]'::jsonb))
    FROM g;
$$;
REVOKE ALL ON FUNCTION public._exos_group_buy_json(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_group_buy_json(uuid) TO service_role;

-- A friend's seat page: the price their seat locked and the group's slot
-- (nothing about the host's labels). Hidden for an unpublished event, like
-- the ids (mig 20261109110000).
SELECT pg_temp.exos_patch_n('public.exos_group_seat_view(text)',
  '/* exos: seat view price slot */',
  $o$    'event', CASE WHEN e.id IS NULL THEN NULL ELSE jsonb_build_object($o$,
  $n$    /* exos: seat view price slot */ -- mig 20261110110000
    'unit_price_cents', CASE WHEN e.id IS NOT NULL THEN g.unit_price_cents END,
    'slot_id', CASE WHEN e.id IS NOT NULL THEN g.slot_id END,
    'event', CASE WHEN e.id IS NULL THEN NULL ELSE jsonb_build_object($n$, 1);

-- ---------------------------------------------------------------------------
-- 4. exos-checkout's context: + the slot and the seats' locked price.
-- ---------------------------------------------------------------------------
-- { group_id, event_id, tier_id, quantity, slot_id, unit_price_cents,
--   price_step_id }. unit_price_cents: what each seat's hold locked (NULL for
-- a type without steps: the checkout prices it as any order). The cover's
-- seats share one price; anything else is XG412.
CREATE OR REPLACE FUNCTION public.exos_group_checkout_ctx(p_token text, p_group_id uuid, p_buyer uuid)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  s        public.exos_group_buy_seats%ROWTYPE;
  g        public.exos_group_buys%ROWTYPE;
  v_state  text;
  v_n      int;
  v_prices int;
  v_unit   int;
  v_step   uuid;
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
  -- The price the seat(s) locked at the start.
  SELECT count(DISTINCT coalesce(h.unit_price_cents::text, '-') || '/' || coalesce(h.price_step_id::text, '-')),
         min(h.unit_price_cents), (array_agg(h.price_step_id ORDER BY x.seat_no))[1]
    INTO v_prices, v_unit, v_step
    FROM public.exos_group_buy_seats x JOIN public.exos_cart_holds h ON h.id = x.hold_id
   WHERE x.group_id = g.id
     AND CASE WHEN p_token IS NOT NULL THEN x.id = s.id
              ELSE public._exos_group_seat_state(x.id) IN ('waiting', 'paying', 'covering') END;
  IF v_prices > 1 THEN
    RAISE EXCEPTION 'the group just changed: check the seats and try again' USING ERRCODE = 'XG412';
  END IF;
  RETURN jsonb_build_object('group_id', g.id, 'event_id', g.event_id, 'tier_id', g.tier_id, 'quantity', v_n,
    'slot_id', g.slot_id, 'unit_price_cents', v_unit, 'price_step_id', v_step);
END $$;
REVOKE ALL ON FUNCTION public.exos_group_checkout_ctx(text, uuid, uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_group_checkout_ctx(text, uuid, uuid) TO service_role;

-- ---------------------------------------------------------------------------
-- 5. Attach: the order must carry the group's slot and the seats' step.
-- ---------------------------------------------------------------------------
SELECT pg_temp.exos_patch_n('public.exos_group_attach(text,text,uuid)',
  '/* exos: group attach slot step */',
  $o$  IF g.status <> 'open' OR now() >= g.deadline OR v_ok = 0 OR v_ok <> coalesce(cardinality(v_ids), 0)
     OR v_ok <> cs.quantity THEN$o$,
  $n$  /* exos: group attach slot step */ -- mig 20261110110000: the order is for the
  -- group's slot and is priced at the step its seats locked.
  IF cs.slot_id IS DISTINCT FROM g.slot_id
     OR EXISTS (SELECT 1 FROM public.exos_cart_holds h
                 WHERE h.id = ANY (coalesce(v_holds, '{}')) AND h.unit_price_cents IS NOT NULL
                   AND h.price_step_id IS DISTINCT FROM cs.price_step_id) THEN
    RAISE EXCEPTION 'this group is for another ticket' USING ERRCODE = 'XG400';
  END IF;
  IF g.status <> 'open' OR now() >= g.deadline OR v_ok = 0 OR v_ok <> coalesce(cardinality(v_ids), 0)
     OR v_ok <> cs.quantity THEN$n$, 1);

-- ---------------------------------------------------------------------------
-- 6. Audit: the host's cover (at the claim) and cancel.
-- ---------------------------------------------------------------------------
SELECT pg_temp.exos_patch_n('public.exos_group_claim(text,uuid,uuid,text,uuid,uuid,integer)',
  '/* exos: audit order.group_cover */',
  $o$  RETURN v_hold;$o$,
  $n$  /* exos: audit order.group_cover */ -- mig 20261110110000: the seats and their face total
  PERFORM public._exos_audit(g.org_id, 'order.group_cover', 'group_buy', g.id::text, g.event_id,
    jsonb_build_object('seats_covered', jsonb_build_array(NULL, cardinality(v_ids))),
    (SELECT sum(coalesce(h.unit_price_cents, round(coalesce(t.price, 0) * 100)::int))
       FROM public.exos_group_buy_seats x
       JOIN public.exos_cart_holds h ON h.id = x.hold_id
       JOIN public.exos_ticket_tiers t ON t.id = h.tier_id
      WHERE x.id = ANY (v_ids)),
    (SELECT e.currency FROM public.exos_events e WHERE e.id = g.event_id),
    'host covers the unpaid seats', p_buyer);
  RETURN v_hold;$n$, 1);

-- The same buyer starting over on a seat (review 2026-11-09): refused while
-- their claim is under 2 minutes old, so a guest can't open Stripe pages on a
-- link without end (exos-checkout also rate-limits before the claim,
-- _shared/groupGate.ts). XG429; DETAIL = their order's session id when one is
-- attached and still pending, so exos-checkout hands that page back.
SELECT pg_temp.exos_patch_n('public.exos_group_claim(text,uuid,uuid,text,uuid,uuid,integer)',
  '/* exos: group reclaim guard */',
  $o$      RAISE EXCEPTION 'seat already taken: a friend is paying for it right now' USING ERRCODE = 'XG409';
    END IF;
    UPDATE public.exos_group_buy_seats
       SET status = 'paying', cover = false,$o$,
  $n$      RAISE EXCEPTION 'seat already taken: a friend is paying for it right now' USING ERRCODE = 'XG409';
    END IF;
    /* exos: group reclaim guard */ -- mig 20261110110000
    IF v_state = 'paying' AND s.claimed_at > now() - interval '2 minutes' THEN
      RAISE EXCEPTION 'your checkout for this seat is already open: finish it there, or try again in 2 minutes'
        USING ERRCODE = 'XG429',
              DETAIL = coalesce((SELECT xs.session_id FROM public.exos_checkout_sessions xs
                                  WHERE xs.session_id = s.session_id AND xs.status = 'pending'), '');
    END IF;
    UPDATE public.exos_group_buy_seats
       SET status = 'paying', cover = false,$n$, 1);

SELECT pg_temp.exos_patch_n('public.exos_group_buy_cancel(uuid)',
  '/* exos: audit hold.group_cancel */',
  $o$  UPDATE public.exos_group_buys SET status = 'cancelled', closed_at = coalesce(closed_at, now())
   WHERE id = g.id AND (v_n > 0 OR status = 'open');$o$,
  $n$  UPDATE public.exos_group_buys SET status = 'cancelled', closed_at = coalesce(closed_at, now())
   WHERE id = g.id AND (v_n > 0 OR status = 'open');
  /* exos: audit hold.group_cancel */ -- mig 20261110110000
  PERFORM public._exos_audit(g.org_id, 'hold.group_cancel', 'group_buy', g.id::text, g.event_id,
    jsonb_build_object('status', jsonb_build_array('open', 'cancelled'), 'seats_released', jsonb_build_array(NULL, v_n)),
    NULL, NULL, 'host ended the group', auth.uid());$n$, 1);

-- ---------------------------------------------------------------------------
-- 7. Friends' open Stripe pages that can't be issued any more.
-- ---------------------------------------------------------------------------
-- exos-reconcile-checkouts (service role) expires each at Stripe and marks
-- the row expired. A pending group order (cs_...) older than 2 minutes whose
-- seats' holds aren't all active, unexpired and attached to it: exactly the
-- orders exos_fulfill_checkout would refuse. why: deadline | cancelled |
-- seat_gone (covered, paid, or the friend moved to another page).
CREATE OR REPLACE FUNCTION public.exos_group_pages_to_expire(p_limit int DEFAULT 50)
RETURNS TABLE (session_id text, group_buy_id uuid, why text)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT cs.session_id, cs.group_buy_id,
         CASE WHEN g.status = 'cancelled' THEN 'cancelled'
              WHEN now() >= g.deadline THEN 'deadline'
              ELSE 'seat_gone' END
    FROM public.exos_checkout_sessions cs
    JOIN public.exos_group_buys g ON g.id = cs.group_buy_id
   WHERE cs.group_buy_id IS NOT NULL
     AND cs.status = 'pending'
     AND cs.session_id LIKE 'cs\_%'
     AND cs.created_at < now() - interval '2 minutes'
     AND (SELECT count(*) FROM public.exos_cart_holds h
           WHERE h.checkout_session_id = cs.session_id AND h.group_seat_id IS NOT NULL
             AND h.status = 'active' AND h.expires_at > now()) <> cs.quantity
   ORDER BY cs.created_at, cs.session_id
   LIMIT least(greatest(coalesce(p_limit, 50), 1), 200);
$$;
REVOKE ALL ON FUNCTION public.exos_group_pages_to_expire(int) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_group_pages_to_expire(int) TO service_role;
