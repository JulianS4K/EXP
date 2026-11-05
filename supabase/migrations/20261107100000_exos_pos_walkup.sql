-- ============================================================================
-- Migration 20261107100000 — Exos: walk-up sales at the door (POS)
--
-- Branch:   claude/exos-pos-walkup
-- Touches:  C: TABLE exos_pos_paid_outs, exos_pos_reversals (RLS: door staff of
--              the event and finance read; no client writes)
--           W: TABLE exos_pos_orders (+buyer_name, buyer_email, comp_quantity,
--              hold_expires_at, reversed_at, reversed_by, reverse_reason),
--              exos_cart_holds (+pos_order_id), exos_ticket_print_codes
--              (printed_via + 'pos')
--           C: FUNCTION exos_pos_walkup_fee_base (the fee setting),
--              exos_pos_walkup_sell, exos_pos_walkup_catalog,
--              exos_pos_recent_sales, exos_pos_void_order, exos_pos_refund_order,
--              exos_pos_paid_out, exos_pos_order_codes, exos_pos_order_email
--              (authenticated, role-checked in SQL);
--              _exos_pos_actor_role, _exos_pos_open_drawer, _exos_pos_drawer_cash,
--              _exos_pos_order_json, _exos_pos_walkup_begin,
--              _exos_pos_walkup_complete, _exos_pos_walkup_cancel,
--              _exos_pos_walkup_sell, _exos_pos_deliver_email, _exos_pos_reverse,
--              _exos_pos_paid_out, _exos_api_pos_orders, _exos_api_pos_void
--              (service role only)
--           W: FUNCTION exos_pos_tg_line (marker /* exos: pos walkup door price */),
--              exos_pos_close_drawer (markers /* exos: pos paid-outs */,
--              /* exos: pos paid-outs json */, /* exos: pos drawer holder */),
--              exos_pos_tg_payment and exos_gift_card_issue (marker
--              /* exos: pos drawer holder */), exos_pos_settlement_summary
--              (redefined in full; keeps the 20261029090000 exos_event_fee_bps
--              line, marker /* exos: pos walkup settlement */)
-- Pre-reqs: 20260929074000 (POS scaffold), 20261104120000 (drawer gift cards),
--           20261105120000 (print codes), 20261106110000 (checkout questions),
--           20261106120000 (shared capacity), 20261106130000 (price steps).
--
-- Door staff sell tickets at the door for cash or as a comp, hand the ticket
-- over (QR on the staff screen, paper, or email), and void or refund the sale.
-- docs/pos.md "Walk-up sales".
--
-- 1. A walk-up sale is two steps, so a card tender can slot in later without
--    rework (docs/pos.md "Card at the door"):
--      begin     (_exos_pos_walkup_begin)  checks, prices at the DOOR channel,
--                creates the order (status open = pending) and its ticket line,
--                and RESERVES the places with exos_cart_holds rows tied to the
--                order (pos_order_id). Nothing is minted. A hold expires on its
--                own, so a card that is declined or abandoned gives the places
--                back like an abandoned online checkout.
--      complete  (_exos_pos_walkup_complete) records the tenders, turns the
--                holds into tickets (consumed + minted in one transaction),
--                fills order_lines.ticket_ids and delivers by email if asked.
--      cancel    (_exos_pos_walkup_cancel) releases the holds of a pending order.
--    Cash and comp do begin + complete in one transaction
--    (exos_pos_walkup_sell). A card tender is refused today ("card at the door
--    isn't connected yet"): no card data is ever accepted, and the only card
--    reference the schema holds stays exos_pos_payments.terminal_ref.
-- 2. Same inventory rules as online, in the same lock order as holds: the
--    tier's pools by quota_id (exos_assert_quota), then the tier row, then
--    its price steps; then the type's own room (exos_effective_available,
--    live online holds count), the house cap, and a price step's places. The
--    price is the door channel's: door_price_cents when set, else the current
--    step (exos_tier_current_price(tier, now(), 'door')). Comps don't use a
--    step's places (their hold carries no step).
-- 3. Idempotent on the client's order key (exos_pos_orders.client_ref): a
--    double tap returns the first sale. A key another member, event or org
--    used is refused without saying anything about that sale.
-- 4. Who: selling = exos_pos_can_ring (owner / manager, or a scanner org-wide
--    or assigned to the event). A comp needs an owner or manager (the box-office
--    comp rule: exos_issue_ticket_to_email / exos_mint_tickets), and counts
--    against the org's comp budget (comp tickets are channel 'boxoffice', as
--    box-office comps are). Cash needs an open drawer at the event.
-- 5. Void (same night: within 12 hours, before any of its tickets is scanned):
--    the seller or an owner / manager. The tickets are voided (capacity back),
--    the cash goes back out of an open drawer as a paid-out ledger row, the
--    tenders become 'refunded', and an exos_pos_reversals row records it.
--    Refund: owner / manager; after a scan only with p_override (recorded).
--    A scanned ticket stays 'used' (the guest came in; like an online refund,
--    which voids only the active tickets) and keeps its place.
--    Handing a sale's tickets over (the screen QR / paper print codes, email)
--    follows the void rule too: the seller or an owner / manager. Email gives
--    an Exos account the tickets only when its email is confirmed (else a
--    claim link), and a ticket already handed over, claimed or scanned isn't
--    sent again, except by an owner / manager (never a scanned one).
-- 6. A drawer is its holder's: cash goes into it (a sale, a bar tender, a
--    cash gift card), comes out of it (a paid-out, a void / refund) and it is
--    closed only by the member who opened it, or by an owner / manager. Nothing
--    picks another member's drawer by itself; an owner / manager names it.
--    Cash paid-outs need a reason and never exceed what the drawer holds. A drawer's expected cash
--    at close = float + cash taken (refunded sales included: the cash came in)
--    + cash gift cards - paid-outs (voids and refunds included).
-- 7. The Exos fee on walk-up ticket sales is ONE setting, still an OPEN
--    operator decision (docs/pos.md "Operator decisions" 1):
--      exos_platform_settings 'pos_walkup_fee_base' =
--        "card-tickets" (DEFAULT: what the scaffold settlement already does:
--                        cash and comp walk-ups pay no Exos fee)
--        "all-tickets"  (cash ticket sales are charged too)
--    exos_pos_settlement_summary reads it.
--
-- Additive, replay-safe (IF NOT EXISTS, CREATE OR REPLACE, marker-checked
-- patches). D4 authors; not applied.
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

-- ===========================================================================
-- 1. Columns and tables.
-- ===========================================================================
ALTER TABLE public.exos_pos_orders
  ADD COLUMN IF NOT EXISTS buyer_name      text CHECK (buyer_name IS NULL OR char_length(buyer_name) BETWEEN 1 AND 80),
  ADD COLUMN IF NOT EXISTS buyer_email     text CHECK (buyer_email IS NULL OR (char_length(buyer_email) <= 254 AND position('@' in buyer_email) > 1)),
  ADD COLUMN IF NOT EXISTS comp_quantity   integer NOT NULL DEFAULT 0 CHECK (comp_quantity BETWEEN 0 AND 100),
  ADD COLUMN IF NOT EXISTS hold_expires_at timestamptz,
  ADD COLUMN IF NOT EXISTS reversed_at     timestamptz,
  ADD COLUMN IF NOT EXISTS reversed_by     uuid,
  ADD COLUMN IF NOT EXISTS reverse_reason  text CHECK (reverse_reason IS NULL OR char_length(reverse_reason) <= 300);

-- The walk-up path alone sets those columns: a direct insert (RLS lets door
-- staff ring bar orders) gets them cleared.
CREATE OR REPLACE FUNCTION public.exos_pos_tg_order_walkup_fields()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
  IF coalesce(current_setting('exos.pos_walkup', true), '') <> 'on' THEN
    NEW.buyer_name := NULL; NEW.buyer_email := NULL; NEW.comp_quantity := 0; NEW.hold_expires_at := NULL;
  END IF;
  NEW.reversed_at := NULL; NEW.reversed_by := NULL; NEW.reverse_reason := NULL;
  RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION public.exos_pos_tg_order_walkup_fields() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS exos_pos_orders_walkup_fields ON public.exos_pos_orders;
CREATE TRIGGER exos_pos_orders_walkup_fields BEFORE INSERT ON public.exos_pos_orders
  FOR EACH ROW EXECUTE FUNCTION public.exos_pos_tg_order_walkup_fields();

-- A pending walk-up's reserved places (the card path's "reserved, not minted").
ALTER TABLE public.exos_cart_holds
  ADD COLUMN IF NOT EXISTS pos_order_id uuid REFERENCES public.exos_pos_orders (id) ON DELETE CASCADE;
CREATE INDEX IF NOT EXISTS exos_cart_holds_pos_order_idx ON public.exos_cart_holds (pos_order_id) WHERE pos_order_id IS NOT NULL;

-- Print codes shown or printed at the door.
ALTER TABLE public.exos_ticket_print_codes DROP CONSTRAINT IF EXISTS exos_ticket_print_codes_printed_via_check;
ALTER TABLE public.exos_ticket_print_codes ADD CONSTRAINT exos_ticket_print_codes_printed_via_check
  CHECK (printed_via IN ('dashboard', 'api', 'pos'));

-- Cash out of a drawer: a paid-out (with a reason), or the cash of a voided /
-- refunded sale handed back. Append-only ledger.
CREATE TABLE IF NOT EXISTS public.exos_pos_paid_outs (
  id                uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id            uuid        NOT NULL REFERENCES public.exos_orgs (id) ON DELETE CASCADE,
  event_id          uuid        NOT NULL REFERENCES public.exos_events (id) ON DELETE CASCADE,
  drawer_session_id uuid        NOT NULL REFERENCES public.exos_pos_drawer_sessions (id) ON DELETE CASCADE,
  kind              text        NOT NULL CHECK (kind IN ('paid_out', 'void', 'refund')),
  amount_cents      integer     NOT NULL CHECK (amount_cents > 0 AND amount_cents <= 10000000),
  reason            text        NOT NULL CHECK (char_length(reason) BETWEEN 3 AND 300),
  order_id          uuid        REFERENCES public.exos_pos_orders (id) ON DELETE SET NULL,
  client_ref        uuid        UNIQUE,                      -- a double tap pays out once
  created_by        uuid,
  created_at        timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT exos_pos_paid_outs_order_chk CHECK ((kind = 'paid_out') = (order_id IS NULL))
);
CREATE INDEX IF NOT EXISTS exos_pos_paid_outs_drawer_idx ON public.exos_pos_paid_outs (drawer_session_id);
CREATE INDEX IF NOT EXISTS exos_pos_paid_outs_event_idx ON public.exos_pos_paid_outs (event_id, kind);

-- One row per voided or refunded POS order: what went back, and who said so.
CREATE TABLE IF NOT EXISTS public.exos_pos_reversals (
  id              uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id          uuid        NOT NULL REFERENCES public.exos_orgs (id) ON DELETE CASCADE,
  event_id        uuid        NOT NULL REFERENCES public.exos_events (id) ON DELETE CASCADE,
  order_id        uuid        NOT NULL UNIQUE REFERENCES public.exos_pos_orders (id) ON DELETE CASCADE,
  kind            text        NOT NULL CHECK (kind IN ('void', 'refund')),
  total_cents     integer     NOT NULL CHECK (total_cents >= 0),
  cash_cents      integer     NOT NULL DEFAULT 0 CHECK (cash_cents >= 0),
  comp_cents      integer     NOT NULL DEFAULT 0 CHECK (comp_cents >= 0),
  card_cents      integer     NOT NULL DEFAULT 0 CHECK (card_cents = 0),   -- card refunds wait for the terminal
  tickets_voided  integer     NOT NULL DEFAULT 0,
  tickets_kept    integer     NOT NULL DEFAULT 0,                          -- scanned (refund override)
  paid_out_id     uuid        REFERENCES public.exos_pos_paid_outs (id) ON DELETE SET NULL,
  override        boolean     NOT NULL DEFAULT false,
  reason          text        NOT NULL CHECK (char_length(reason) BETWEEN 3 AND 300),
  api_key_id      uuid,
  created_by      uuid,
  created_at      timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS exos_pos_reversals_event_idx ON public.exos_pos_reversals (event_id, kind);

ALTER TABLE public.exos_pos_paid_outs ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.exos_pos_reversals ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.exos_pos_paid_outs, public.exos_pos_reversals FROM PUBLIC, anon, authenticated;
GRANT ALL ON public.exos_pos_paid_outs, public.exos_pos_reversals TO service_role;
GRANT SELECT ON public.exos_pos_paid_outs, public.exos_pos_reversals TO authenticated;
DROP POLICY IF EXISTS exos_pos_paid_outs_sel ON public.exos_pos_paid_outs;
CREATE POLICY exos_pos_paid_outs_sel ON public.exos_pos_paid_outs FOR SELECT TO authenticated
  USING (public.exos_pos_can_ring(event_id) OR public.exos_has_org_role(org_id, ARRAY['finance']));
DROP POLICY IF EXISTS exos_pos_reversals_sel ON public.exos_pos_reversals;
CREATE POLICY exos_pos_reversals_sel ON public.exos_pos_reversals FOR SELECT TO authenticated
  USING (public.exos_pos_can_ring(event_id) OR public.exos_has_org_role(org_id, ARRAY['finance']));
COMMENT ON TABLE public.exos_pos_paid_outs IS
  'Cash out of a POS drawer: paid-outs and the cash of voided / refunded sales (mig 20261107100000). Written by functions only.';
COMMENT ON TABLE public.exos_pos_reversals IS
  'One row per voided or refunded POS order (mig 20261107100000). Written by functions only.';

-- ===========================================================================
-- 2. The fee setting (OPEN operator decision, docs/pos.md).
-- ===========================================================================
CREATE OR REPLACE FUNCTION public.exos_pos_walkup_fee_base()
RETURNS text LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT coalesce((SELECT CASE WHEN value #>> '{}' IN ('card-tickets', 'all-tickets') THEN value #>> '{}' END
                     FROM public.exos_platform_settings WHERE key = 'pos_walkup_fee_base'), 'card-tickets')
$$;
REVOKE ALL ON FUNCTION public.exos_pos_walkup_fee_base() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.exos_pos_walkup_fee_base() TO authenticated, service_role;

-- ===========================================================================
-- 3. Helpers (service role only).
-- ===========================================================================

-- The role an actor works this event's door with: 'owner' | 'manager' |
-- 'scanner' (org-wide, or assigned to it: exos_can_door_event for any user),
-- else NULL. p_admin (platform admin, from the authenticated wrappers) = owner.
CREATE OR REPLACE FUNCTION public._exos_pos_actor_role(p_event uuid, p_actor uuid, p_admin boolean DEFAULT false)
RETURNS text LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT CASE
           WHEN coalesce(p_admin, false) AND EXISTS (SELECT 1 FROM public.exos_events WHERE id = p_event) THEN 'owner'
           ELSE (SELECT CASE
                          WHEN m.role IN ('owner', 'manager') THEN m.role
                          WHEN m.role = 'scanner'
                               AND (EXISTS (SELECT 1 FROM public.exos_event_staff s WHERE s.event_id = e.id AND s.user_id = m.user_id)
                                    OR NOT EXISTS (SELECT 1 FROM public.exos_event_staff s WHERE s.org_id = e.org_id AND s.user_id = m.user_id))
                            THEN 'scanner'
                        END
                   FROM public.exos_events e
                   JOIN public.exos_org_memberships m ON m.org_id = e.org_id AND m.user_id = p_actor AND m.disabled IS NOT TRUE
                  WHERE e.id = p_event)
         END
$$;
REVOKE ALL ON FUNCTION public._exos_pos_actor_role(uuid, uuid, boolean) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_pos_actor_role(uuid, uuid, boolean) TO service_role;

-- Cash a drawer holds now: float + cash tenders taken into it (refunded ones
-- too: that cash came in, and its return is a paid-out) + cash gift cards sold
-- from it - paid-outs. Same terms as exos_pos_close_drawer's expected.
CREATE OR REPLACE FUNCTION public._exos_pos_drawer_cash(p_drawer uuid)
RETURNS integer LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT (d.open_float_cents
          + coalesce((SELECT sum(p.amount_cents + p.tip_cents) FROM public.exos_pos_payments p
                       WHERE p.drawer_session_id = d.id AND p.method = 'cash' AND p.status IN ('succeeded', 'refunded')), 0)
          + coalesce((SELECT sum(g.initial_cents) FROM public.exos_gift_cards g
                       WHERE g.pos_drawer_id = d.id AND g.payment_method = 'cash'), 0)
          - coalesce((SELECT sum(o.amount_cents) FROM public.exos_pos_paid_outs o WHERE o.drawer_session_id = d.id), 0))::int
    FROM public.exos_pos_drawer_sessions d WHERE d.id = p_drawer
$$;
REVOKE ALL ON FUNCTION public._exos_pos_drawer_cash(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_pos_drawer_cash(uuid) TO service_role;

-- The open drawer at this event the actor may put cash into or take it out
-- of. Named (p_drawer): open, at this event, and the actor's own unless they
-- are an owner / manager (p_manager). Not named: only the actor's own (the
-- device's drawer if they opened it, else their latest), never somebody
-- else's, whoever asks. NULL = none.
CREATE OR REPLACE FUNCTION public._exos_pos_open_drawer(p_event uuid, p_actor uuid, p_device uuid, p_drawer uuid, p_manager boolean)
RETURNS uuid LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT CASE WHEN p_drawer IS NOT NULL THEN
           (SELECT d.id FROM public.exos_pos_drawer_sessions d
             WHERE d.id = p_drawer AND d.event_id = p_event AND d.status = 'open'
               AND (d.opened_by = p_actor OR coalesce(p_manager, false)))
         ELSE coalesce(
           (SELECT d.id FROM public.exos_pos_drawer_sessions d
             WHERE p_device IS NOT NULL AND d.device_id = p_device AND d.event_id = p_event AND d.status = 'open'
               AND d.opened_by = p_actor
             ORDER BY d.opened_at DESC LIMIT 1),
           (SELECT d.id FROM public.exos_pos_drawer_sessions d
             WHERE d.opened_by = p_actor AND d.event_id = p_event AND d.status = 'open'
             ORDER BY d.opened_at DESC LIMIT 1))
         END
$$;
REVOKE ALL ON FUNCTION public._exos_pos_open_drawer(uuid, uuid, uuid, uuid, boolean) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_pos_open_drawer(uuid, uuid, uuid, uuid, boolean) TO service_role;

-- Why a named drawer can't be used: '42501' someone else's, '55000' not open
-- here (or unknown). The callers raise it; NULL when it can be used.
CREATE OR REPLACE FUNCTION public._exos_pos_drawer_refusal(p_event uuid, p_actor uuid, p_drawer uuid, p_manager boolean)
RETURNS text LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT CASE
           WHEN public._exos_pos_open_drawer(p_event, p_actor, NULL, p_drawer, p_manager) IS NOT NULL THEN NULL
           WHEN EXISTS (SELECT 1 FROM public.exos_pos_drawer_sessions d
                         WHERE d.id = p_drawer AND d.event_id = p_event AND d.status = 'open') THEN '42501'
           ELSE '55000'
         END
$$;
REVOKE ALL ON FUNCTION public._exos_pos_drawer_refusal(uuid, uuid, uuid, boolean) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_pos_drawer_refusal(uuid, uuid, uuid, boolean) TO service_role;

-- An order as the door app and the API show it. Callers check who may see it.
CREATE OR REPLACE FUNCTION public._exos_pos_order_json(p_order uuid, p_actor uuid DEFAULT NULL)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT jsonb_build_object(
           'id', o.id, 'event_id', o.event_id, 'status', CASE WHEN o.status = 'open' THEN 'pending' ELSE o.status END,
           'payment_method', o.payment_method, 'currency', o.currency,
           'subtotal_cents', o.subtotal_cents, 'tax_cents', o.tax_cents, 'total_cents', o.total_cents,
           'tenders', jsonb_build_object(
             'cash', coalesce((SELECT sum(p.amount_cents) FROM public.exos_pos_payments p WHERE p.order_id = o.id AND p.method = 'cash'), 0),
             'comp', coalesce((SELECT sum(p.amount_cents) FROM public.exos_pos_payments p WHERE p.order_id = o.id AND p.method = 'comp'), 0),
             'card', coalesce((SELECT sum(p.amount_cents) FROM public.exos_pos_payments p WHERE p.order_id = o.id AND p.method = 'card'), 0)),
           'tier_id', i.tier_id, 'tier_name', l.name, 'quantity', l.quantity, 'comp_quantity', o.comp_quantity,
           'unit_cents', CASE WHEN l.quantity > 0 THEN l.line_total_cents / l.quantity END,
           'lines', (SELECT coalesce(jsonb_agg(jsonb_build_object('category', x.category, 'name', x.name, 'quantity', x.quantity,
                                                                   'total_cents', x.line_total_cents) ORDER BY x.created_at), '[]'::jsonb)
                       FROM public.exos_pos_order_lines x WHERE x.order_id = o.id),
           'ticket_ids', to_jsonb(coalesce(l.ticket_ids, '{}'::uuid[])),
           'tickets_scanned', (SELECT count(*) FROM public.exos_tickets t
                                WHERE t.id = ANY (coalesce(l.ticket_ids, '{}')) AND (t.status = 'used' OR t.check_in_at IS NOT NULL)),
           'buyer_name', o.buyer_name, 'buyer_email', o.buyer_email,
           'device_id', o.device_id, 'rung_by_me', p_actor IS NOT NULL AND o.rung_by = p_actor,
           'order_key', o.client_ref, 'created_at', o.created_at, 'paid_at', o.paid_at,
           'hold_expires_at', CASE WHEN o.status = 'open' THEN o.hold_expires_at END,
           'voided_at', o.voided_at, 'reversed_at', o.reversed_at, 'reverse_reason', coalesce(o.reverse_reason, o.void_reason))
    FROM public.exos_pos_orders o
    LEFT JOIN LATERAL (SELECT * FROM public.exos_pos_order_lines x WHERE x.order_id = o.id AND x.category = 'ticket'
                        ORDER BY x.created_at LIMIT 1) l ON true
    LEFT JOIN public.exos_pos_items i ON i.id = l.item_id
   WHERE o.id = p_order
$$;
REVOKE ALL ON FUNCTION public._exos_pos_order_json(uuid, uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_pos_order_json(uuid, uuid) TO service_role;

-- ===========================================================================
-- 4. Ticket lines take the door price (the line trigger snapshots the item's
--    price otherwise). The walk-up path sets exos.pos_walkup_unit for the
--    one insert; the tax is the ticket type's own rule, as at checkout.
-- ===========================================================================
SELECT pg_temp.exos_patch_n('public.exos_pos_tg_line()',
  '/* exos: pos walkup door price */',
  $o$  NEW.unit_price_cents := i.price_cents;$o$,
  $n$  NEW.unit_price_cents := i.price_cents;
  /* exos: pos walkup door price */ -- mig 20261107100000
  IF i.category = 'ticket' AND nullif(current_setting('exos.pos_walkup_unit', true), '') IS NOT NULL THEN
    NEW.unit_price_cents := current_setting('exos.pos_walkup_unit', true)::int;
    SELECT r.rate_percent, r.price_includes_tax INTO v_rate, v_incl
      FROM public.exos_ticket_tiers t JOIN public.exos_tax_rules r ON r.id = t.tax_rate_id
     WHERE t.id = i.tier_id;
  END IF;$n$, 1);

-- ===========================================================================
-- 5. Drawers: paid-outs (and returned cash) come out of the expected cash.
-- ===========================================================================
SELECT pg_temp.exos_patch_n('public.exos_pos_close_drawer(uuid,integer,jsonb,text)',
  '/* exos: pos paid-outs */',
  $o$  v_expected := d.open_float_cents + v_cash;$o$,
  $n$  /* exos: pos paid-outs */ -- mig 20261107100000. Cash of sales voided or
  -- refunded later came in too; what went back out is a paid-out.
  v_cash := v_cash + (SELECT coalesce(sum(amount_cents + tip_cents), 0)::int FROM public.exos_pos_payments
                       WHERE drawer_session_id = p_session_id AND method = 'cash' AND status = 'refunded');
  v_expected := d.open_float_cents + v_cash
              - (SELECT coalesce(sum(amount_cents), 0)::int FROM public.exos_pos_paid_outs WHERE drawer_session_id = p_session_id);$n$, 1);
SELECT pg_temp.exos_patch_n('public.exos_pos_close_drawer(uuid,integer,jsonb,text)',
  '/* exos: pos paid-outs json */',
  $o$'cash_taken_cents', v_cash, 'expected_cents', v_expected,$o$,
  $n$'cash_taken_cents', v_cash, 'expected_cents', v_expected,
                            /* exos: pos paid-outs json */ 'paid_out_cents', d.open_float_cents + v_cash - v_expected,$n$, 1);

-- The other paths that change a drawer follow the same rule: a bar / merch
-- cash tender (exos_pos_tg_payment), a cash gift card sold into it
-- (exos_gift_card_issue), closing it (exos_pos_close_drawer). The service
-- role (no auth.uid()) is unchanged.
SELECT pg_temp.exos_patch_n('public.exos_pos_tg_payment()',
  '/* exos: pos drawer holder */',
  $o$    RAISE EXCEPTION 'exos_pos_payments: drawer is not open at this event' USING ERRCODE = '22023';
  END IF;$o$,
  $n$    RAISE EXCEPTION 'exos_pos_payments: drawer is not open at this event' USING ERRCODE = '22023';
  END IF;
  /* exos: pos drawer holder */ -- mig 20261107100000
  IF NEW.drawer_session_id IS NOT NULL AND auth.uid() IS NOT NULL
     AND NOT EXISTS (SELECT 1 FROM public.exos_pos_drawer_sessions d WHERE d.id = NEW.drawer_session_id AND d.opened_by = auth.uid())
     AND coalesce(public._exos_pos_actor_role(o.event_id, auth.uid(), public.exos_is_admin()), '') NOT IN ('owner', 'manager') THEN
    RAISE EXCEPTION 'exos_pos_payments: that drawer is someone else''s' USING ERRCODE = '42501';
  END IF;$n$, 1);
SELECT pg_temp.exos_patch_n('public.exos_gift_card_issue(uuid,integer,text,uuid,text,text,text,text,text,text,text,uuid)',
  '/* exos: pos drawer holder */',
  $o$    RAISE EXCEPTION 'that drawer isn''t open for this organization' USING ERRCODE = '22023';
  END IF;$o$,
  $n$    RAISE EXCEPTION 'that drawer isn''t open for this organization' USING ERRCODE = '22023';
  END IF;
  /* exos: pos drawer holder */ -- mig 20261107100000
  IF p_drawer_id IS NOT NULL AND NOT v_mgr AND NOT EXISTS (
       SELECT 1 FROM public.exos_pos_drawer_sessions d WHERE d.id = p_drawer_id AND d.opened_by = auth.uid()) THEN
    RAISE EXCEPTION 'that drawer is someone else''s: sell into your own, or ask a manager' USING ERRCODE = '42501';
  END IF;$n$, 1);
SELECT pg_temp.exos_patch_n('public.exos_pos_close_drawer(uuid,integer,jsonb,text)',
  '/* exos: pos drawer holder */',
  $o$    RAISE EXCEPTION 'exos_pos_close_drawer: not authorized' USING ERRCODE = '42501';
  END IF;$o$,
  $n$    RAISE EXCEPTION 'exos_pos_close_drawer: not authorized' USING ERRCODE = '42501';
  END IF;
  /* exos: pos drawer holder */ -- mig 20261107100000
  IF d.opened_by IS DISTINCT FROM auth.uid()
     AND coalesce(public._exos_pos_actor_role(d.event_id, auth.uid(), public.exos_is_admin()), '') NOT IN ('owner', 'manager') THEN
    RAISE EXCEPTION 'exos_pos_close_drawer: only the member who opened the drawer, an owner or a manager can close it' USING ERRCODE = '42501';
  END IF;$n$, 1);

-- ===========================================================================
-- 6. Begin / complete / cancel (service role; the wrappers below check roles).
-- ===========================================================================

-- Reserve the places and price the order. Returns the order id. The caller
-- has checked the role (p_role: the actor's door role) and the rate limit.
CREATE OR REPLACE FUNCTION public._exos_pos_walkup_begin(
  p_actor uuid, p_role text, p_event uuid, p_tier uuid, p_quantity integer, p_comp_quantity integer,
  p_order_key uuid, p_device uuid, p_buyer_name text, p_buyer_email text, p_answers jsonb, p_ttl_seconds integer
) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  ev      public.exos_events%ROWTYPE;
  t       public.exos_ticket_tiers%ROWTYPE;
  v_qty   int := coalesce(p_quantity, 0);
  v_comp  int := coalesce(p_comp_quantity, 0);
  v_paid  int;
  v_party int;
  v_avail int;
  v_house int;
  v_price jsonb;
  v_unit  int;
  v_step  uuid;
  v_rem   int;
  v_item  uuid;
  v_order uuid;
  v_name  text := nullif(btrim(coalesce(p_buyer_name, '')), '');
  v_email text := nullif(lower(btrim(coalesce(p_buyer_email, ''))), '');
  v_exp   timestamptz := now() + make_interval(secs => least(greatest(coalesce(p_ttl_seconds, 120), 30), 900));
BEGIN
  IF p_role IS NULL OR p_role NOT IN ('owner', 'manager', 'scanner') THEN
    RAISE EXCEPTION 'not authorized to sell at this event' USING ERRCODE = '42501';
  END IF;
  IF v_qty < 1 OR v_qty > 10 THEN
    RAISE EXCEPTION 'quantity must be 1 to 10' USING ERRCODE = '22023';
  END IF;
  IF v_comp < 0 OR v_comp > v_qty THEN
    RAISE EXCEPTION 'comp quantity must be 0 to the quantity' USING ERRCODE = '22023';
  END IF;
  IF v_comp > 0 AND p_role NOT IN ('owner', 'manager') THEN
    RAISE EXCEPTION 'comps need an owner or manager' USING ERRCODE = '42501', HINT = 'comp-role';
  END IF;
  IF v_name IS NOT NULL AND char_length(v_name) > 80 THEN
    RAISE EXCEPTION 'the name is at most 80 characters' USING ERRCODE = '22023';
  END IF;
  IF v_email IS NOT NULL AND (char_length(v_email) > 254 OR v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$') THEN
    RAISE EXCEPTION 'that email address doesn''t look right' USING ERRCODE = '22023';
  END IF;

  SELECT * INTO ev FROM public.exos_events WHERE id = p_event;
  IF ev.id IS NULL THEN
    RAISE EXCEPTION 'event not found' USING ERRCODE = 'P0002';
  END IF;
  IF ev.status = 'cancelled' THEN
    RAISE EXCEPTION 'the event is cancelled' USING ERRCODE = '55000';
  END IF;
  SELECT * INTO t FROM public.exos_ticket_tiers WHERE id = p_tier AND event_id = p_event;
  IF t.id IS NULL THEN
    RAISE EXCEPTION 'ticket type not found' USING ERRCODE = 'P0002';
  END IF;
  IF coalesce(t.kind, '') = 'table' THEN
    RAISE EXCEPTION 'tables are booked from the dashboard, not sold at the door' USING ERRCODE = '22023';
  END IF;
  v_paid := v_qty - v_comp;
  v_party := public.exos_tier_party_size(p_tier);

  -- Comps: the org's comp budget (it locks the org row, before any pool, as
  -- the box-office comp does).
  IF v_comp > 0 THEN
    PERFORM public.exos_assert_comp_budget(ev.org_id, v_comp);
  END IF;

  -- Pools by quota_id, then the type, then its steps: the holds' lock order.
  BEGIN
    PERFORM public.exos_assert_quota(p_tier, v_qty);
  EXCEPTION WHEN check_violation THEN
    RAISE EXCEPTION 'sold out: a shared limit this ticket type is in is full' USING ERRCODE = '23514', HINT = 'sold-out';
  END;
  PERFORM 1 FROM public.exos_ticket_tiers WHERE id = p_tier FOR UPDATE;
  PERFORM 1 FROM public.exos_price_steps WHERE tier_id = p_tier ORDER BY sort_order, id FOR UPDATE;

  v_avail := public.exos_effective_available(p_tier);
  IF v_avail IS NOT NULL AND v_avail < v_qty THEN
    RAISE EXCEPTION 'sold out: % left of this ticket type', greatest(v_avail, 0) USING ERRCODE = '23514', HINT = 'sold-out';
  END IF;
  v_house := public.exos_event_house_available(p_event);
  IF v_house IS NOT NULL AND v_house < v_qty * v_party THEN
    RAISE EXCEPTION 'sold out: the event is at capacity' USING ERRCODE = '23514', HINT = 'sold-out';
  END IF;

  -- The door channel's price: door_price_cents, else the current step.
  v_price := public.exos_tier_current_price(p_tier, now(), 'door');
  v_unit := greatest(coalesce((v_price ->> 'price_cents')::int, 0), 0);
  IF v_price ->> 'source' = 'step' AND v_paid > 0 THEN
    v_step := (v_price ->> 'step_id')::uuid;
    v_rem := (v_price ->> 'step_remaining')::int;
    IF v_rem IS NOT NULL AND v_rem < v_paid * v_party THEN
      RAISE EXCEPTION 'price_step_remaining: only % left at this price', v_rem USING ERRCODE = 'XP410';
    END IF;
  END IF;

  PERFORM set_config('exos.pos_walkup', 'on', true);
  INSERT INTO public.exos_pos_orders (event_id, device_id, client_ref, rung_by, buyer_name, buyer_email, comp_quantity, hold_expires_at)
  VALUES (p_event, p_device, p_order_key, p_actor, v_name, v_email, v_comp, v_exp)
  RETURNING id INTO v_order;
  PERFORM set_config('exos.pos_walkup', '', true);

  -- The type's ticket item (the scaffold's line model): an active one, else a new one.
  SELECT id INTO v_item FROM public.exos_pos_items
   WHERE event_id = p_event AND category = 'ticket' AND tier_id = p_tier AND active
   ORDER BY created_at, id LIMIT 1;
  IF v_item IS NULL THEN
    INSERT INTO public.exos_pos_items (org_id, event_id, category, name, price_cents, tier_id)
    VALUES (ev.org_id, p_event, 'ticket', left(coalesce(nullif(btrim(t.name), ''), 'Ticket'), 120), least(v_unit, 10000000), p_tier)
    RETURNING id INTO v_item;
  END IF;
  PERFORM set_config('exos.pos_walkup_unit', v_unit::text, true);
  INSERT INTO public.exos_pos_order_lines (order_id, item_id, quantity, org_id, event_id, category, name, unit_price_cents)
  VALUES (v_order, v_item, v_qty, ev.org_id, p_event, 'ticket', '-', 0);
  PERFORM set_config('exos.pos_walkup_unit', '', true);

  -- The reservation: paid places (on the step they're priced at) and comps (no step).
  IF v_paid > 0 THEN
    INSERT INTO public.exos_cart_holds (event_id, tier_id, org_id, buyer_uid, quantity, expires_at, price_step_id, unit_price_cents, pos_order_id)
    VALUES (p_event, p_tier, ev.org_id, NULL, v_paid, v_exp, v_step, v_unit, v_order);
  END IF;
  IF v_comp > 0 THEN
    INSERT INTO public.exos_cart_holds (event_id, tier_id, org_id, buyer_uid, quantity, expires_at, unit_price_cents, pos_order_id)
    VALUES (p_event, p_tier, ev.org_id, NULL, v_comp, v_exp, 0, v_order);
  END IF;

  -- Checkout questions: optional at the door (never required), hidden ones too.
  IF p_answers IS NOT NULL AND jsonb_typeof(p_answers) = 'object' THEN
    PERFORM public._exos_record_answers(ev.org_id, p_event, 'pos:' || v_order::text, array_fill(p_tier, ARRAY[v_qty]),
                                        p_answers, false, true, 'door', p_actor);
  END IF;
  RETURN v_order;
END $$;
REVOKE ALL ON FUNCTION public._exos_pos_walkup_begin(uuid, text, uuid, uuid, integer, integer, uuid, uuid, text, text, jsonb, integer)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_pos_walkup_begin(uuid, text, uuid, uuid, integer, integer, uuid, uuid, text, text, jsonb, integer)
  TO service_role;

-- Email the order's undelivered tickets: the box-office mail path
-- (exos_issue_ticket_to_email). An Exos account gets them directly; anyone
-- else gets a claim link (a pending transfer from the seller).
-- p_manager (an owner / manager): tickets already handed over or claimed are
-- sent again (their pending claim link is cancelled); a scanned ticket never.
-- Anyone else: only tickets still with the seller. The callers check who may.
CREATE OR REPLACE FUNCTION public._exos_pos_deliver_email(p_order uuid, p_actor uuid, p_email text, p_manager boolean)
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  o      public.exos_pos_orders%ROWTYPE;
  ev     public.exos_events%ROWTYPE;
  v_ids  uuid[];
  v_all  uuid[];
  v_email text := lower(btrim(coalesce(p_email, '')));
  v_rcpt uuid;
  v_id   uuid;
  v_tr   uuid;
  v_safe text;
  v_n    int;
  v_sender_email text;
BEGIN
  IF v_email = '' OR char_length(v_email) > 254 OR v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' THEN
    RAISE EXCEPTION 'that email address doesn''t look right' USING ERRCODE = '22023';
  END IF;
  SELECT * INTO o FROM public.exos_pos_orders WHERE id = p_order;
  SELECT * INTO ev FROM public.exos_events WHERE id = o.event_id;
  SELECT coalesce(l.ticket_ids, '{}') INTO v_all FROM public.exos_pos_order_lines l
   WHERE l.order_id = p_order AND l.category = 'ticket' ORDER BY l.created_at LIMIT 1;
  -- Still with the seller: active, not in a transfer, never handed to anyone.
  -- An owner / manager: every active ticket (a scanned one is 'used').
  SELECT array_agg(t.id ORDER BY t.created_at, t.id) INTO v_ids FROM public.exos_tickets t
   WHERE t.id = ANY (coalesce(v_all, '{}')) AND t.status = 'active'
     AND (coalesce(p_manager, false)
          OR (t.pending_transfer_id IS NULL AND t.owner_id IS NOT DISTINCT FROM o.rung_by AND t.check_in_at IS NULL));
  v_n := coalesce(cardinality(v_ids), 0);
  IF v_n = 0 THEN
    RAISE EXCEPTION 'these tickets were already handed over, claimed or scanned: an owner or manager can resend them'
      USING ERRCODE = '55000', HINT = 'handed-over';
  END IF;
  IF coalesce(p_manager, false) THEN
    UPDATE public.exos_transfers SET status = 'cancelled' WHERE ticket_id = ANY (v_ids) AND status = 'pending';
    UPDATE public.exos_tickets SET pending_transfer_id = NULL WHERE id = ANY (v_ids) AND pending_transfer_id IS NOT NULL;
  END IF;
  -- An account only when its email is confirmed: anyone can sign up with an
  -- address they don't own; they get a claim link like everyone else.
  SELECT id INTO v_rcpt FROM auth.users WHERE lower(email) = v_email AND email_confirmed_at IS NOT NULL LIMIT 1;
  SELECT lower(email) INTO v_sender_email FROM auth.users WHERE id = o.rung_by;
  IF v_rcpt IS NOT NULL THEN
    UPDATE public.exos_tickets SET owner_id = v_rcpt, buyer_id = v_rcpt, buyer_email = v_email
     WHERE id = ANY (v_ids);
  ELSE
    FOREACH v_id IN ARRAY v_ids LOOP
      INSERT INTO public.exos_transfers
      SELECT * FROM jsonb_populate_record(NULL::public.exos_transfers, jsonb_build_object(
        'id', gen_random_uuid(), 'ticket_id', v_id, 'org_id', ev.org_id,
        'sender_id', (SELECT owner_id FROM public.exos_tickets WHERE id = v_id),
        'sender_email', v_sender_email, 'receiver_email', v_email,
        'receiver_name', o.buyer_name,
        'status', 'pending', 'event_id', ev.id, 'event_title', ev.name,
        'event_image', ev.image_url, 'tier_name', (SELECT tier_name FROM public.exos_tickets WHERE id = v_id),
        'organizer_id', ev.created_by, 'created_at', now(), 'updated_at', now()))
      RETURNING id INTO v_tr;
      UPDATE public.exos_tickets SET pending_transfer_id = v_tr, buyer_email = v_email, last_reissue_at = now() WHERE id = v_id;
    END LOOP;
  END IF;
  UPDATE public.exos_pos_orders SET buyer_email = v_email WHERE id = p_order;

  v_safe := replace(replace(replace(coalesce(ev.name, 'your event'), '&', '&amp;'), '<', '&lt;'), '>', '&gt;');
  IF v_rcpt IS NOT NULL THEN
    INSERT INTO public.exos_mail (template, to_email, subject, html, created_by, status)
    VALUES ('ticket-issued', v_email, left('Your ticket for ' || v_safe || ' is ready', 200),
            '<p>Thanks for buying at the door. Your ticket' || CASE WHEN v_n > 1 THEN 's for <strong>' ELSE ' for <strong>' END
            || v_safe || '</strong> ' || CASE WHEN v_n > 1 THEN 'are' ELSE 'is' END
            || ' in the Exos app. Show the QR at the door.</p>', p_actor, 'pending');
  ELSE
    INSERT INTO public.exos_mail (template, to_email, subject, html, created_by, status)
    VALUES ('transfer-initiated', v_email, left('Your ticket for ' || v_safe, 200),
            '<p>Thanks for buying at the door of <strong>' || v_safe || '</strong>. Sign in to Exos with this email, or create '
            || 'an account, to keep your ticket' || CASE WHEN v_n > 1 THEN 's' ELSE '' END || ' in the app.</p>' ||
            coalesce((SELECT '<ul>' || string_agg('<li><a href="{{app_url}}/claim/' || tr.id || '?k=' || tr.claim_key || '">Claim ticket</a></li>', '' ORDER BY tr.id) || '</ul>'
                        FROM public.exos_transfers tr
                       WHERE tr.ticket_id = ANY (v_ids) AND tr.status = 'pending' AND lower(tr.receiver_email) = v_email), ''),
            p_actor, 'pending');
  END IF;
  RETURN v_n;
END $$;
REVOKE ALL ON FUNCTION public._exos_pos_deliver_email(uuid, uuid, text, boolean) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_pos_deliver_email(uuid, uuid, text, boolean) TO service_role;

-- Take the tenders and mint. p_payment: 'cash' (into p_drawer, which the
-- caller resolved) or 'comp' (the whole order is comped). A card tender is
-- refused here until the terminal is wired: it will arrive as an opaque
-- terminal_ref after the reader captured, never as card data.
CREATE OR REPLACE FUNCTION public._exos_pos_walkup_complete(
  p_actor uuid, p_order uuid, p_payment text, p_drawer uuid, p_comp_reason text
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  o       public.exos_pos_orders%ROWTYPE;
  l       public.exos_pos_order_lines%ROWTYPE;
  v_tier  uuid;
  v_tname text;
  v_held  int;
  v_step  uuid;
  v_per   int;
  v_comp_amt int;
  v_cash  int;
  v_ids   uuid[] := '{}';
  v_id    uuid;
  v_n     int;
  i       int;
BEGIN
  IF lower(coalesce(p_payment, '')) = 'card' THEN
    RAISE EXCEPTION 'card at the door isn''t connected yet: take cash, or comp it' USING ERRCODE = '0A000', HINT = 'card-not-connected';
  END IF;
  SELECT * INTO o FROM public.exos_pos_orders WHERE id = p_order FOR UPDATE;
  IF o.id IS NULL THEN
    RAISE EXCEPTION 'order not found' USING ERRCODE = 'P0002';
  END IF;
  IF o.status = 'paid' THEN
    RETURN public._exos_pos_order_json(o.id, p_actor);
  END IF;
  IF o.status <> 'open' THEN
    RAISE EXCEPTION 'this sale was %', o.status USING ERRCODE = '55000';
  END IF;
  SELECT * INTO l FROM public.exos_pos_order_lines WHERE order_id = o.id AND category = 'ticket' ORDER BY created_at LIMIT 1;
  SELECT tier_id INTO v_tier FROM public.exos_pos_items WHERE id = l.item_id;
  -- Every reserved place must still be held (a lapsed card wait gave them back).
  SELECT coalesce(sum(quantity), 0), max(price_step_id::text)::uuid INTO v_held, v_step
    FROM (SELECT quantity, price_step_id FROM public.exos_cart_holds
           WHERE pos_order_id = o.id AND status = 'active' AND expires_at > now() FOR UPDATE) h;
  IF l.id IS NULL OR v_held <> l.quantity THEN
    RAISE EXCEPTION 'reservation_expired: the places were given back; start the sale again' USING ERRCODE = '55000', HINT = 'expired';
  END IF;

  v_per := l.line_total_cents / l.quantity;   -- exact: tax is per unit (exclusive) or inside the price (inclusive)
  v_comp_amt := v_per * o.comp_quantity;
  v_cash := o.total_cents - v_comp_amt;
  IF lower(coalesce(p_payment, 'cash')) = 'comp' AND v_cash > 0 THEN
    RAISE EXCEPTION 'a comp covers the whole sale: set the comp quantity to the quantity' USING ERRCODE = '22023';
  END IF;
  IF v_cash > 0 AND p_drawer IS NULL THEN
    RAISE EXCEPTION 'open a cash drawer first' USING ERRCODE = '55000', HINT = 'no-drawer';
  END IF;
  IF v_comp_amt > 0 THEN
    INSERT INTO public.exos_pos_payments (order_id, org_id, event_id, method, amount_cents, comp_reason, taken_by)
    VALUES (o.id, o.org_id, o.event_id, 'comp', v_comp_amt,
            left(coalesce(nullif(btrim(coalesce(p_comp_reason, '')), ''), 'door comp'), 200), p_actor);
  END IF;
  IF v_cash > 0 THEN
    INSERT INTO public.exos_pos_payments (order_id, org_id, event_id, method, amount_cents, drawer_session_id, taken_by)
    VALUES (o.id, o.org_id, o.event_id, 'cash', v_cash, p_drawer, p_actor);
  END IF;
  IF o.total_cents = 0 THEN
    UPDATE public.exos_pos_orders SET status = 'paid', paid_at = now(),
           payment_method = CASE WHEN o.comp_quantity > 0 THEN 'comp' END
     WHERE id = o.id;
  END IF;

  -- Holds -> tickets, in one transaction (the webhook's fulfilment order).
  UPDATE public.exos_cart_holds SET status = 'consumed', consumed_at = now() WHERE pos_order_id = o.id AND status = 'active';
  UPDATE public.exos_ticket_tiers SET sold = sold + l.quantity
   WHERE id = v_tier AND (capacity > 0 AND sold + l.quantity <= capacity)
  RETURNING name INTO v_tname;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'sold out: this ticket type is full' USING ERRCODE = '23514', HINT = 'sold-out';
  END IF;
  UPDATE public.exos_events SET tickets_sold = tickets_sold + l.quantity
   WHERE id = o.event_id AND (total_tickets = 0 OR tickets_sold + l.quantity <= total_tickets);
  GET DIAGNOSTICS v_n = ROW_COUNT;
  IF v_n = 0 THEN
    RAISE EXCEPTION 'sold out: the event is at capacity' USING ERRCODE = '23514', HINT = 'sold-out';
  END IF;
  FOR i IN 1..l.quantity LOOP
    -- Paid tickets first (channel 'pos', at the order's step when priced at
    -- one); comps last (channel 'boxoffice' at 0: the comp budget counts them).
    INSERT INTO public.exos_tickets (
      event_id, org_id, tier_id, tier_name, buyer_id, owner_id, buyer_email, status, barcode_secret,
      price_paid, order_ref, channel_source, attendee_name, price_step_id
    ) VALUES (
      o.event_id, o.org_id, v_tier, v_tname, o.rung_by, o.rung_by, o.buyer_email, 'active', gen_random_uuid()::text,
      CASE WHEN i <= l.quantity - o.comp_quantity THEN round(v_per::numeric / 100, 2) ELSE 0 END,
      'pos:' || o.id::text,
      CASE WHEN i <= l.quantity - o.comp_quantity THEN 'pos' ELSE 'boxoffice' END,
      o.buyer_name,
      CASE WHEN i <= l.quantity - o.comp_quantity THEN v_step END
    ) RETURNING id INTO v_id;
    v_ids := array_append(v_ids, v_id);
  END LOOP;
  UPDATE public.exos_pos_order_lines SET ticket_ids = v_ids WHERE id = l.id;
  UPDATE public.exos_pos_orders SET hold_expires_at = NULL WHERE id = o.id;

  IF o.buyer_email IS NOT NULL THEN
    PERFORM public._exos_pos_deliver_email(o.id, p_actor, o.buyer_email, false);
  END IF;
  RETURN public._exos_pos_order_json(o.id, p_actor);
END $$;
REVOKE ALL ON FUNCTION public._exos_pos_walkup_complete(uuid, uuid, text, uuid, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_pos_walkup_complete(uuid, uuid, text, uuid, text) TO service_role;

-- Give a pending sale's places back (a declined or abandoned card, later).
CREATE OR REPLACE FUNCTION public._exos_pos_walkup_cancel(p_actor uuid, p_order uuid, p_reason text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE o public.exos_pos_orders%ROWTYPE;
BEGIN
  SELECT * INTO o FROM public.exos_pos_orders WHERE id = p_order FOR UPDATE;
  IF o.id IS NULL THEN
    RAISE EXCEPTION 'order not found' USING ERRCODE = 'P0002';
  END IF;
  IF o.status = 'void' THEN
    RETURN public._exos_pos_order_json(o.id, p_actor);
  END IF;
  IF o.status <> 'open' THEN
    RAISE EXCEPTION 'only a pending sale can be cancelled (this one is %)', o.status USING ERRCODE = '55000';
  END IF;
  IF EXISTS (SELECT 1 FROM public.exos_pos_payments WHERE order_id = o.id AND status = 'succeeded') THEN
    RAISE EXCEPTION 'this sale has a payment: void it instead' USING ERRCODE = '55000';
  END IF;
  UPDATE public.exos_cart_holds SET status = 'released', released_at = now() WHERE pos_order_id = o.id AND status = 'active';
  UPDATE public.exos_pos_orders
     SET status = 'void', voided_at = now(), hold_expires_at = NULL,
         void_reason = left(coalesce(nullif(btrim(coalesce(p_reason, '')), ''), 'cancelled before payment'), 300)
   WHERE id = o.id;
  RETURN public._exos_pos_order_json(o.id, p_actor);
END $$;
REVOKE ALL ON FUNCTION public._exos_pos_walkup_cancel(uuid, uuid, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_pos_walkup_cancel(uuid, uuid, text) TO service_role;

-- One walk-up sale, cash or comp: role, rate limit, idempotency, begin, complete.
CREATE OR REPLACE FUNCTION public._exos_pos_walkup_sell(
  p_actor uuid, p_admin boolean, p_event_id uuid, p_tier_id uuid, p_quantity integer, p_order_key uuid,
  p_comp_quantity integer, p_payment text, p_device_id uuid, p_drawer_id uuid, p_buyer_name text,
  p_buyer_email text, p_answers jsonb, p_comp_reason text
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  v_role   text;
  v_pay    text := lower(coalesce(nullif(btrim(coalesce(p_payment, '')), ''), 'cash'));
  v_comp   int := coalesce(p_comp_quantity, 0);
  o        public.exos_pos_orders%ROWTYPE;
  v_line   public.exos_pos_order_lines%ROWTYPE;
  v_tier   uuid;
  v_drawer uuid;
  v_order  uuid;
  v_out    jsonb;
BEGIN
  IF p_actor IS NULL THEN
    RAISE EXCEPTION 'not authenticated' USING ERRCODE = '42501';
  END IF;
  -- No card data, no card tender: refused before anything else is read.
  IF v_pay = 'card' THEN
    RAISE EXCEPTION 'card at the door isn''t connected yet: take cash, or comp it' USING ERRCODE = '0A000', HINT = 'card-not-connected';
  END IF;
  IF v_pay NOT IN ('cash', 'comp') THEN
    RAISE EXCEPTION 'payment must be cash or comp' USING ERRCODE = '22023';
  END IF;
  IF v_pay = 'comp' THEN v_comp := coalesce(p_quantity, 0); END IF;
  v_role := public._exos_pos_actor_role(p_event_id, p_actor, p_admin);
  IF v_role IS NULL THEN
    RAISE EXCEPTION 'not authorized to sell at this event' USING ERRCODE = '42501';
  END IF;
  IF p_order_key IS NULL THEN
    RAISE EXCEPTION 'an order key is required (a new UUID per sale)' USING ERRCODE = '22023';
  END IF;
  -- Per device (or per member without one), before any lock or write.
  IF NOT public.exos_rate_hit('pos:sell:' || coalesce('d:' || p_device_id::text, 'u:' || p_actor::text), 30) THEN
    RAISE EXCEPTION 'too many sales a minute from this device' USING ERRCODE = '54000';
  END IF;

  -- A double tap: the same key is the same sale.
  PERFORM pg_advisory_xact_lock(hashtextextended('exos_pos_key:' || p_order_key::text, 0));
  SELECT * INTO o FROM public.exos_pos_orders WHERE client_ref = p_order_key;
  IF o.id IS NOT NULL THEN
    SELECT * INTO v_line FROM public.exos_pos_order_lines WHERE order_id = o.id AND category = 'ticket' ORDER BY created_at LIMIT 1;
    SELECT tier_id INTO v_tier FROM public.exos_pos_items WHERE id = v_line.item_id;
    IF o.event_id <> p_event_id OR o.rung_by IS DISTINCT FROM p_actor OR v_tier IS DISTINCT FROM p_tier_id
       OR v_line.quantity IS DISTINCT FROM p_quantity OR o.comp_quantity <> v_comp THEN
      RAISE EXCEPTION 'this order key was already used for another sale' USING ERRCODE = '23505';
    END IF;
    RETURN public._exos_pos_order_json(o.id, p_actor) || jsonb_build_object('replay', true);
  END IF;

  -- The drawer the cash goes into (complete refuses cash without one; a free
  -- ticket at a $0 door price needs none).
  IF v_comp < coalesce(p_quantity, 0) THEN
    v_drawer := public._exos_pos_open_drawer(p_event_id, p_actor, p_device_id, p_drawer_id, v_role IN ('owner', 'manager'));
    IF v_drawer IS NULL AND p_drawer_id IS NOT NULL THEN
      IF public._exos_pos_drawer_refusal(p_event_id, p_actor, p_drawer_id, v_role IN ('owner', 'manager')) = '42501' THEN
        RAISE EXCEPTION 'that drawer is someone else''s: open your own, or ask a manager' USING ERRCODE = '42501', HINT = 'not-your-drawer';
      END IF;
      RAISE EXCEPTION 'that drawer isn''t open at this event' USING ERRCODE = '55000', HINT = 'no-drawer';
    END IF;
  END IF;
  v_order := public._exos_pos_walkup_begin(p_actor, v_role, p_event_id, p_tier_id, p_quantity, v_comp, p_order_key,
                                            p_device_id, p_buyer_name, p_buyer_email, p_answers, 120);
  v_out := public._exos_pos_walkup_complete(p_actor, v_order, CASE WHEN v_comp >= p_quantity THEN 'comp' ELSE 'cash' END,
                                            v_drawer, p_comp_reason);
  RETURN v_out || jsonb_build_object('replay', false);
END $$;
REVOKE ALL ON FUNCTION public._exos_pos_walkup_sell(uuid, boolean, uuid, uuid, integer, uuid, integer, text, uuid, uuid, text, text, jsonb, text)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_pos_walkup_sell(uuid, boolean, uuid, uuid, integer, uuid, integer, text, uuid, uuid, text, text, jsonb, text)
  TO service_role;

-- ===========================================================================
-- 7. Void / refund, paid-outs.
-- ===========================================================================

-- p_kind 'void' (same night, before a scan: the seller or an owner / manager)
-- or 'refund' (owner / manager; after a scan only with p_override). p_org
-- (the API) scopes the lookup; a miss is "order not found" whatever the reason.
CREATE OR REPLACE FUNCTION public._exos_pos_reverse(
  p_actor uuid, p_admin boolean, p_org uuid, p_event uuid, p_order uuid, p_kind text, p_reason text,
  p_override boolean, p_drawer uuid, p_api_key uuid
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  o        public.exos_pos_orders%ROWTYPE;
  v_role   text;
  v_reason text := btrim(coalesce(p_reason, ''));
  v_ids    uuid[];
  v_scanned int;
  v_cash   int;
  v_comp   int;
  v_card   int;
  v_drawer uuid;
  v_po     uuid;
  v_void   int := 0;
  r        record;
  v_override boolean := false;
BEGIN
  IF p_kind NOT IN ('void', 'refund') THEN
    RAISE EXCEPTION 'unknown reversal' USING ERRCODE = '22023';
  END IF;
  SELECT * INTO o FROM public.exos_pos_orders WHERE id = p_order FOR UPDATE;
  IF o.id IS NULL OR (p_org IS NOT NULL AND o.org_id <> p_org) OR (p_event IS NOT NULL AND o.event_id <> p_event) THEN
    RAISE EXCEPTION 'order not found' USING ERRCODE = 'P0002';
  END IF;
  v_role := public._exos_pos_actor_role(o.event_id, p_actor, p_admin);
  IF v_role IS NULL THEN
    RAISE EXCEPTION 'order not found' USING ERRCODE = 'P0002';
  END IF;
  IF NOT public.exos_rate_hit('pos:reverse:' || p_actor::text, 20) THEN
    RAISE EXCEPTION 'too many voids a minute' USING ERRCODE = '54000';
  END IF;
  IF char_length(v_reason) < 3 OR char_length(v_reason) > 300 THEN
    RAISE EXCEPTION 'say why (3 to 300 characters)' USING ERRCODE = '22023';
  END IF;
  -- Already done: the same answer (a double tap); the other kind is refused.
  IF o.status IN ('void', 'refunded') THEN
    IF (o.status = 'void') = (p_kind = 'void') THEN
      RETURN public._exos_pos_order_json(o.id, p_actor) || jsonb_build_object('replay', true);
    END IF;
    RAISE EXCEPTION 'this sale was already %', CASE o.status WHEN 'void' THEN 'voided' ELSE 'refunded' END USING ERRCODE = '55000';
  END IF;
  IF o.status = 'open' THEN
    IF p_kind = 'void' AND (o.rung_by = p_actor OR v_role IN ('owner', 'manager')) THEN
      RETURN public._exos_pos_walkup_cancel(p_actor, o.id, v_reason);
    END IF;
    RAISE EXCEPTION 'this sale isn''t paid' USING ERRCODE = '55000';
  END IF;
  IF EXISTS (SELECT 1 FROM public.exos_pos_settlements s WHERE s.event_id = o.event_id AND s.status = 'final') THEN
    RAISE EXCEPTION 'the event''s settlement is final' USING ERRCODE = '55000';
  END IF;

  SELECT coalesce(sum(amount_cents) FILTER (WHERE method = 'cash'), 0),
         coalesce(sum(amount_cents) FILTER (WHERE method = 'comp'), 0),
         coalesce(sum(amount_cents) FILTER (WHERE method = 'card'), 0)
    INTO v_cash, v_comp, v_card
    FROM public.exos_pos_payments WHERE order_id = o.id AND status = 'succeeded';
  IF v_card > 0 THEN
    RAISE EXCEPTION 'card refunds at the door aren''t connected yet' USING ERRCODE = '0A000', HINT = 'card-not-connected';
  END IF;
  SELECT array_agg(x) INTO v_ids FROM public.exos_pos_order_lines l, unnest(coalesce(l.ticket_ids, '{}')) x WHERE l.order_id = o.id;
  SELECT count(*) INTO v_scanned FROM public.exos_tickets t
   WHERE t.id = ANY (coalesce(v_ids, '{}')) AND (t.status = 'used' OR t.check_in_at IS NOT NULL);

  IF p_kind = 'void' THEN
    IF NOT (o.rung_by = p_actor OR v_role IN ('owner', 'manager')) THEN
      RAISE EXCEPTION 'only the seller, an owner or a manager can void this sale' USING ERRCODE = '42501';
    END IF;
    IF v_scanned > 0 THEN
      RAISE EXCEPTION 'a ticket of this sale was scanned: an owner or manager can refund it' USING ERRCODE = '55000', HINT = 'scanned';
    END IF;
    IF o.created_at < now() - interval '12 hours' THEN
      RAISE EXCEPTION 'a sale can be voided for 12 hours: an owner or manager can refund it' USING ERRCODE = '55000', HINT = 'too-late';
    END IF;
  ELSE
    IF v_role NOT IN ('owner', 'manager') THEN
      RAISE EXCEPTION 'refunds need an owner or manager' USING ERRCODE = '42501';
    END IF;
    IF v_scanned > 0 THEN
      IF NOT coalesce(p_override, false) THEN
        RAISE EXCEPTION 'a ticket of this sale was scanned: refunding it needs an owner or manager override' USING ERRCODE = '55000', HINT = 'override';
      END IF;
      v_override := true;
    END IF;
  END IF;

  -- The cash comes out of a drawer the actor may use (the _exos_pos_paid_out
  -- rule): their own, or any open one at this event for an owner / manager.
  -- Named: that one. Not named: the drawer the cash went into when they may
  -- use it, else their own. Never somebody else's by default.
  IF v_cash > 0 THEN
    IF p_drawer IS NOT NULL THEN
      v_drawer := public._exos_pos_open_drawer(o.event_id, p_actor, NULL, p_drawer, v_role IN ('owner', 'manager'));
      IF v_drawer IS NULL THEN
        IF public._exos_pos_drawer_refusal(o.event_id, p_actor, p_drawer, v_role IN ('owner', 'manager')) = '42501' THEN
          RAISE EXCEPTION 'that drawer is someone else''s: hand the cash back from your own, or ask a manager'
            USING ERRCODE = '42501', HINT = 'not-your-drawer';
        END IF;
        RAISE EXCEPTION 'that drawer isn''t open at this event' USING ERRCODE = '55000', HINT = 'no-drawer';
      END IF;
    ELSE
      SELECT p.drawer_session_id INTO v_drawer FROM public.exos_pos_payments p
        JOIN public.exos_pos_drawer_sessions d ON d.id = p.drawer_session_id AND d.status = 'open' AND d.event_id = o.event_id
                                              AND (d.opened_by = p_actor OR v_role IN ('owner', 'manager'))
       WHERE p.order_id = o.id AND p.method = 'cash' AND p.status = 'succeeded' LIMIT 1;
      v_drawer := coalesce(v_drawer, public._exos_pos_open_drawer(o.event_id, p_actor, NULL, NULL, v_role IN ('owner', 'manager')));
    END IF;
    IF v_drawer IS NULL THEN
      RAISE EXCEPTION 'open your cash drawer to hand the cash back (or ask a manager)' USING ERRCODE = '55000', HINT = 'no-drawer';
    END IF;
    PERFORM 1 FROM public.exos_pos_drawer_sessions WHERE id = v_drawer FOR UPDATE;
    -- Re-checked under the lock: closed meanwhile, it can't pay out.
    IF NOT EXISTS (SELECT 1 FROM public.exos_pos_drawer_sessions WHERE id = v_drawer AND status = 'open') THEN
      RAISE EXCEPTION 'the drawer was just closed' USING ERRCODE = '55000', HINT = 'no-drawer';
    END IF;
    IF public._exos_pos_drawer_cash(v_drawer) < v_cash THEN
      RAISE EXCEPTION 'the drawer only has % cents: hand the cash back from another drawer', public._exos_pos_drawer_cash(v_drawer)
        USING ERRCODE = '23514', HINT = 'drawer-short';
    END IF;
    INSERT INTO public.exos_pos_paid_outs (org_id, event_id, drawer_session_id, kind, amount_cents, reason, order_id, created_by)
    VALUES (o.org_id, o.event_id, v_drawer, p_kind, v_cash, left(v_reason, 300), o.id, p_actor)
    RETURNING id INTO v_po;
  END IF;

  -- The tickets: active ones are voided and their places come back; a
  -- scanned one stays used (the guest came in) and keeps its place.
  UPDATE public.exos_transfers SET status = 'cancelled'
   WHERE ticket_id = ANY (coalesce(v_ids, '{}')) AND status = 'pending';
  FOR r IN
    UPDATE public.exos_tickets
       SET status = 'voided', voided_at = now(), voided_by = p_actor, pending_transfer_id = NULL,
           voided_reason = left('pos ' || p_kind || ': ' || v_reason, 500)
     WHERE id = ANY (coalesce(v_ids, '{}')) AND status = 'active'
    RETURNING tier_id
  LOOP
    v_void := v_void + 1;
    IF r.tier_id IS NOT NULL THEN
      UPDATE public.exos_ticket_tiers SET sold = greatest(0, sold - 1) WHERE id = r.tier_id;
    END IF;
  END LOOP;
  IF v_void > 0 THEN
    UPDATE public.exos_events SET tickets_sold = greatest(0, tickets_sold - v_void) WHERE id = o.event_id;
  END IF;

  UPDATE public.exos_pos_payments SET status = 'refunded' WHERE order_id = o.id AND status = 'succeeded';
  UPDATE public.exos_pos_orders
     SET status = CASE p_kind WHEN 'void' THEN 'void' ELSE 'refunded' END,
         voided_at = CASE p_kind WHEN 'void' THEN now() END,
         void_reason = CASE p_kind WHEN 'void' THEN left(v_reason, 300) END,
         reversed_at = now(), reversed_by = p_actor, reverse_reason = left(v_reason, 300)
   WHERE id = o.id;
  INSERT INTO public.exos_pos_reversals (org_id, event_id, order_id, kind, total_cents, cash_cents, comp_cents,
                                         tickets_voided, tickets_kept, paid_out_id, override, reason, api_key_id, created_by)
  VALUES (o.org_id, o.event_id, o.id, p_kind, o.total_cents, v_cash, v_comp, v_void, v_scanned, v_po, v_override,
          left(v_reason, 300), p_api_key, p_actor);
  RETURN public._exos_pos_order_json(o.id, p_actor)
         || jsonb_build_object('replay', false, 'cash_returned_cents', v_cash, 'drawer_id', v_drawer,
                               'tickets_voided', v_void, 'tickets_kept', v_scanned, 'override', v_override);
END $$;
REVOKE ALL ON FUNCTION public._exos_pos_reverse(uuid, boolean, uuid, uuid, uuid, text, text, boolean, uuid, uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_pos_reverse(uuid, boolean, uuid, uuid, uuid, text, text, boolean, uuid, uuid) TO service_role;

-- Cash out of a drawer: owner / manager, or the member who opened it.
CREATE OR REPLACE FUNCTION public._exos_pos_paid_out(
  p_actor uuid, p_admin boolean, p_drawer uuid, p_amount_cents integer, p_reason text, p_key uuid
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  d       public.exos_pos_drawer_sessions%ROWTYPE;
  v_role  text;
  v_reason text := btrim(coalesce(p_reason, ''));
  v_have  int;
  v_prev  public.exos_pos_paid_outs%ROWTYPE;
  v_id    uuid;
BEGIN
  SELECT * INTO d FROM public.exos_pos_drawer_sessions WHERE id = p_drawer FOR UPDATE;
  v_role := CASE WHEN d.id IS NULL THEN NULL ELSE public._exos_pos_actor_role(d.event_id, p_actor, p_admin) END;
  IF v_role IS NULL THEN
    RAISE EXCEPTION 'drawer not found' USING ERRCODE = 'P0002';
  END IF;
  IF NOT (v_role IN ('owner', 'manager') OR d.opened_by = p_actor) THEN
    RAISE EXCEPTION 'only the drawer''s holder, an owner or a manager can pay out of it' USING ERRCODE = '42501';
  END IF;
  IF NOT public.exos_rate_hit('pos:paidout:' || p_actor::text, 20) THEN
    RAISE EXCEPTION 'too many paid-outs a minute' USING ERRCODE = '54000';
  END IF;
  IF p_key IS NOT NULL THEN
    SELECT * INTO v_prev FROM public.exos_pos_paid_outs WHERE client_ref = p_key;
    IF v_prev.id IS NOT NULL THEN
      IF v_prev.drawer_session_id = d.id AND v_prev.amount_cents = p_amount_cents AND v_prev.created_by = p_actor THEN
        RETURN jsonb_build_object('id', v_prev.id, 'drawer_id', d.id, 'amount_cents', v_prev.amount_cents,
                                  'reason', v_prev.reason, 'drawer_cash_cents', public._exos_pos_drawer_cash(d.id), 'replay', true);
      END IF;
      RAISE EXCEPTION 'this key was already used for another paid-out' USING ERRCODE = '23505';
    END IF;
  END IF;
  IF d.status <> 'open' THEN
    RAISE EXCEPTION 'the drawer is closed' USING ERRCODE = '55000';
  END IF;
  IF p_amount_cents IS NULL OR p_amount_cents < 1 OR p_amount_cents > 10000000 THEN
    RAISE EXCEPTION 'amount must be 1 cent to 100000.00' USING ERRCODE = '22023';
  END IF;
  IF char_length(v_reason) < 3 OR char_length(v_reason) > 300 THEN
    RAISE EXCEPTION 'say what the cash is for (3 to 300 characters)' USING ERRCODE = '22023';
  END IF;
  v_have := public._exos_pos_drawer_cash(d.id);
  IF p_amount_cents > v_have THEN
    RAISE EXCEPTION 'the drawer only has % cents', v_have USING ERRCODE = '23514';
  END IF;
  INSERT INTO public.exos_pos_paid_outs (org_id, event_id, drawer_session_id, kind, amount_cents, reason, client_ref, created_by)
  VALUES (d.org_id, d.event_id, d.id, 'paid_out', p_amount_cents, v_reason, p_key, p_actor)
  RETURNING id INTO v_id;
  RETURN jsonb_build_object('id', v_id, 'drawer_id', d.id, 'amount_cents', p_amount_cents, 'reason', v_reason,
                            'drawer_cash_cents', v_have - p_amount_cents, 'replay', false);
END $$;
REVOKE ALL ON FUNCTION public._exos_pos_paid_out(uuid, boolean, uuid, integer, text, uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_pos_paid_out(uuid, boolean, uuid, integer, text, uuid) TO service_role;

-- ===========================================================================
-- 8. Door staff RPCs (authenticated; the role checks are in SQL).
-- ===========================================================================
CREATE OR REPLACE FUNCTION public.exos_pos_walkup_sell(
  p_event_id uuid, p_tier_id uuid, p_quantity integer, p_order_key uuid,
  p_comp_quantity integer DEFAULT 0, p_payment text DEFAULT 'cash', p_device_id uuid DEFAULT NULL,
  p_drawer_id uuid DEFAULT NULL, p_buyer_name text DEFAULT NULL, p_buyer_email text DEFAULT NULL,
  p_answers jsonb DEFAULT NULL, p_comp_reason text DEFAULT NULL
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
  RETURN public._exos_pos_walkup_sell(auth.uid(), public.exos_is_admin(), p_event_id, p_tier_id, p_quantity, p_order_key,
                                      p_comp_quantity, p_payment, p_device_id, p_drawer_id, p_buyer_name, p_buyer_email,
                                      p_answers, p_comp_reason);
END $$;
REVOKE ALL ON FUNCTION public.exos_pos_walkup_sell(uuid, uuid, integer, uuid, integer, text, uuid, uuid, text, text, jsonb, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.exos_pos_walkup_sell(uuid, uuid, integer, uuid, integer, text, uuid, uuid, text, text, jsonb, text) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.exos_pos_void_order(p_order_id uuid, p_reason text, p_drawer_id uuid DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'not authenticated' USING ERRCODE = '42501'; END IF;
  RETURN public._exos_pos_reverse(auth.uid(), public.exos_is_admin(), NULL, NULL, p_order_id, 'void', p_reason, false, p_drawer_id, NULL);
END $$;
REVOKE ALL ON FUNCTION public.exos_pos_void_order(uuid, text, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.exos_pos_void_order(uuid, text, uuid) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.exos_pos_refund_order(p_order_id uuid, p_reason text, p_override boolean DEFAULT false,
                                                        p_drawer_id uuid DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'not authenticated' USING ERRCODE = '42501'; END IF;
  RETURN public._exos_pos_reverse(auth.uid(), public.exos_is_admin(), NULL, NULL, p_order_id, 'refund', p_reason,
                                  coalesce(p_override, false), p_drawer_id, NULL);
END $$;
REVOKE ALL ON FUNCTION public.exos_pos_refund_order(uuid, text, boolean, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.exos_pos_refund_order(uuid, text, boolean, uuid) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.exos_pos_paid_out(p_drawer_id uuid, p_amount_cents integer, p_reason text, p_key uuid DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'not authenticated' USING ERRCODE = '42501'; END IF;
  RETURN public._exos_pos_paid_out(auth.uid(), public.exos_is_admin(), p_drawer_id, p_amount_cents, p_reason, p_key);
END $$;
REVOKE ALL ON FUNCTION public.exos_pos_paid_out(uuid, integer, text, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.exos_pos_paid_out(uuid, integer, text, uuid) TO authenticated, service_role;

-- The QR (screen) or paper for a walk-up's tickets: one-time print codes
-- (docs/wallet.md "Printed tickets"), so they scan like any printed ticket.
-- Door staff of the event, for a paid POS order's own tickets only.
-- The seller or an owner / manager (the void rule). The seller: only tickets
-- still with them (not emailed, claimed or scanned), so paper can't be made
-- for a ticket the buyer already holds in the app.
CREATE OR REPLACE FUNCTION public.exos_pos_order_codes(p_order_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE o public.exos_pos_orders%ROWTYPE; v_ids uuid[]; v_role text;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'not authenticated' USING ERRCODE = '42501'; END IF;
  SELECT * INTO o FROM public.exos_pos_orders WHERE id = p_order_id;
  v_role := CASE WHEN o.id IS NULL THEN NULL ELSE public._exos_pos_actor_role(o.event_id, auth.uid(), public.exos_is_admin()) END;
  IF v_role IS NULL THEN
    RAISE EXCEPTION 'order not found' USING ERRCODE = 'P0002';
  END IF;
  IF NOT (o.rung_by = auth.uid() OR v_role IN ('owner', 'manager')) THEN
    RAISE EXCEPTION 'only the seller, an owner or a manager can hand over this sale''s tickets' USING ERRCODE = '42501';
  END IF;
  IF o.status <> 'paid' THEN
    RAISE EXCEPTION 'this sale is %', CASE WHEN o.status = 'open' THEN 'pending' ELSE o.status END USING ERRCODE = '55000';
  END IF;
  SELECT array_agg(x) INTO v_ids FROM public.exos_pos_order_lines l, unnest(coalesce(l.ticket_ids, '{}')) x WHERE l.order_id = o.id;
  IF v_ids IS NOT NULL AND v_role NOT IN ('owner', 'manager') THEN
    SELECT array_agg(t.id) INTO v_ids FROM public.exos_tickets t
     WHERE t.id = ANY (v_ids) AND t.status = 'active' AND t.pending_transfer_id IS NULL
       AND t.owner_id IS NOT DISTINCT FROM o.rung_by AND t.check_in_at IS NULL;
    IF v_ids IS NULL THEN
      RAISE EXCEPTION 'these tickets were already handed over, claimed or scanned' USING ERRCODE = '55000', HINT = 'handed-over';
    END IF;
  END IF;
  IF v_ids IS NULL THEN
    RAISE EXCEPTION 'this sale has no tickets' USING ERRCODE = '55000';
  END IF;
  RETURN public._exos_print_mint(o.org_id, auth.uid(), v_ids, 'pos', NULL, true);
END $$;
REVOKE ALL ON FUNCTION public.exos_pos_order_codes(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.exos_pos_order_codes(uuid) TO authenticated, service_role;

-- The seller or an owner / manager (the void rule).
CREATE OR REPLACE FUNCTION public.exos_pos_order_email(p_order_id uuid, p_email text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE o public.exos_pos_orders%ROWTYPE; v_n int; v_role text;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'not authenticated' USING ERRCODE = '42501'; END IF;
  SELECT * INTO o FROM public.exos_pos_orders WHERE id = p_order_id FOR UPDATE;
  v_role := CASE WHEN o.id IS NULL THEN NULL ELSE public._exos_pos_actor_role(o.event_id, auth.uid(), public.exos_is_admin()) END;
  IF v_role IS NULL THEN
    RAISE EXCEPTION 'order not found' USING ERRCODE = 'P0002';
  END IF;
  IF NOT (o.rung_by = auth.uid() OR v_role IN ('owner', 'manager')) THEN
    RAISE EXCEPTION 'only the seller, an owner or a manager can send this sale''s tickets' USING ERRCODE = '42501';
  END IF;
  IF NOT public.exos_rate_hit('pos:mail:' || auth.uid()::text, 10) THEN
    RAISE EXCEPTION 'too many emails a minute' USING ERRCODE = '54000';
  END IF;
  IF o.status <> 'paid' THEN
    RAISE EXCEPTION 'this sale is %', CASE WHEN o.status = 'open' THEN 'pending' ELSE o.status END USING ERRCODE = '55000';
  END IF;
  v_n := public._exos_pos_deliver_email(o.id, auth.uid(), p_email, v_role IN ('owner', 'manager'));
  RETURN public._exos_pos_order_json(o.id, auth.uid()) || jsonb_build_object('emailed', v_n);
END $$;
REVOKE ALL ON FUNCTION public.exos_pos_order_email(uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.exos_pos_order_email(uuid, text) TO authenticated, service_role;

-- What the Sell tab needs: the ticket types at the door price with what's
-- left, the questions (optional at the door, hidden ones too), the open
-- drawers this member may use (their own; every one for an owner / manager),
-- and whether they may comp.
CREATE OR REPLACE FUNCTION public.exos_pos_walkup_catalog(p_event_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_role text; v_uid uuid := auth.uid(); ev public.exos_events%ROWTYPE;
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'not authenticated' USING ERRCODE = '42501'; END IF;
  v_role := public._exos_pos_actor_role(p_event_id, v_uid, public.exos_is_admin());
  IF v_role IS NULL THEN
    RAISE EXCEPTION 'not authorized to sell at this event' USING ERRCODE = '42501';
  END IF;
  SELECT * INTO ev FROM public.exos_events WHERE id = p_event_id;
  RETURN jsonb_build_object(
    'event', jsonb_build_object('id', ev.id, 'name', ev.name, 'status', ev.status, 'currency', upper(coalesce(ev.currency, 'usd'))),
    'role', v_role, 'can_comp', v_role IN ('owner', 'manager'),
    'card', jsonb_build_object('connected', false, 'message', 'Card at the door isn''t connected yet.'),
    'fee_base', public.exos_pos_walkup_fee_base(),
    'tiers', (SELECT coalesce(jsonb_agg(x.j ORDER BY x.sort_order, x.name), '[]'::jsonb) FROM (
      SELECT t.sort_order, t.name, jsonb_build_object(
               'tier_id', t.id, 'name', t.name,
               'price_cents', (p.j ->> 'price_cents')::int, 'price_source', p.j ->> 'source',
               'step_name', p.j ->> 'step_name', 'step_remaining', (p.j ->> 'step_remaining')::int,
               'tax', CASE WHEN r.id IS NULL THEN NULL
                           ELSE jsonb_build_object('rate_percent', r.rate_percent, 'price_includes_tax', r.price_includes_tax) END,
               'unit_total_cents', CASE WHEN r.id IS NULL OR r.price_includes_tax THEN (p.j ->> 'price_cents')::int
                                        ELSE (p.j ->> 'price_cents')::int + public.exos_tax_cents((p.j ->> 'price_cents')::int, r.rate_percent, false) END,
               'remaining', CASE WHEN a.tier IS NULL AND a.house IS NULL THEN NULL
                                 ELSE greatest(least(coalesce(a.tier, a.house), coalesce(a.house, a.tier)), 0) END) AS j
        FROM public.exos_ticket_tiers t
        CROSS JOIN LATERAL (SELECT public.exos_tier_current_price(t.id, now(), 'door') AS j) p
        LEFT JOIN public.exos_tax_rules r ON r.id = t.tax_rate_id
        CROSS JOIN LATERAL (SELECT public.exos_effective_available(t.id) AS tier,
                                   public.exos_event_house_available(t.event_id) / greatest(public.exos_tier_party_size(t.id), 1) AS house) a
       WHERE t.event_id = p_event_id AND coalesce(t.kind, '') <> 'table') x),
    'questions', public._exos_question_defs(p_event_id, true),
    'drawers', (SELECT coalesce(jsonb_agg(jsonb_build_object(
                  'id', d.id, 'device_id', d.device_id, 'mine', d.opened_by = v_uid, 'opened_at', d.opened_at,
                  'open_float_cents', d.open_float_cents, 'cash_cents', public._exos_pos_drawer_cash(d.id)) ORDER BY d.opened_at), '[]'::jsonb)
                  FROM public.exos_pos_drawer_sessions d
                 WHERE d.event_id = p_event_id AND d.status = 'open'
                   AND (d.opened_by = v_uid OR v_role IN ('owner', 'manager'))));
END $$;
REVOKE ALL ON FUNCTION public.exos_pos_walkup_catalog(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.exos_pos_walkup_catalog(uuid) TO authenticated, service_role;

-- The event's POS sales, newest first, with what this member may do to each.
CREATE OR REPLACE FUNCTION public.exos_pos_recent_sales(p_event_id uuid, p_limit integer DEFAULT 20)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_role text; v_uid uuid := auth.uid();
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'not authenticated' USING ERRCODE = '42501'; END IF;
  v_role := public._exos_pos_actor_role(p_event_id, v_uid, public.exos_is_admin());
  IF v_role IS NULL THEN
    RAISE EXCEPTION 'not authorized at this event' USING ERRCODE = '42501';
  END IF;
  RETURN (SELECT coalesce(jsonb_agg(j ORDER BY created_at DESC), '[]'::jsonb) FROM (
    SELECT o.created_at, public._exos_pos_order_json(o.id, v_uid) || jsonb_build_object(
             'can_void', o.status = 'paid' AND o.created_at >= now() - interval '12 hours'
                         AND (o.rung_by = v_uid OR v_role IN ('owner', 'manager')),
             'can_refund', o.status = 'paid' AND v_role IN ('owner', 'manager'),
             'can_hand_over', o.status = 'paid' AND (o.rung_by = v_uid OR v_role IN ('owner', 'manager'))) AS j
      FROM public.exos_pos_orders o
     WHERE o.event_id = p_event_id
     ORDER BY o.created_at DESC
     LIMIT least(greatest(coalesce(p_limit, 20), 1), 100)) s);
END $$;
REVOKE ALL ON FUNCTION public.exos_pos_recent_sales(uuid, integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.exos_pos_recent_sales(uuid, integer) TO authenticated, service_role;

-- ===========================================================================
-- 9. Partner API cores (exos-api, service role; the key's org scopes every lookup).
-- ===========================================================================
CREATE OR REPLACE FUNCTION public._exos_api_pos_orders(p_org uuid, p_event uuid, p_limit integer, p_offset integer)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.exos_events WHERE id = p_event AND org_id = p_org) THEN
    RAISE EXCEPTION 'event not found' USING ERRCODE = 'P0002';
  END IF;
  RETURN jsonb_build_object(
    'total', (SELECT count(*) FROM public.exos_pos_orders WHERE event_id = p_event AND org_id = p_org),
    'data', (SELECT coalesce(jsonb_agg(public._exos_pos_order_json(o.id, NULL) - 'rung_by_me' ORDER BY o.created_at DESC, o.id), '[]'::jsonb)
               FROM (SELECT id, created_at FROM public.exos_pos_orders WHERE event_id = p_event AND org_id = p_org
                      ORDER BY created_at DESC, id
                      LIMIT least(greatest(coalesce(p_limit, 25), 1), 200) OFFSET greatest(coalesce(p_offset, 0), 0)) o));
END $$;
REVOKE ALL ON FUNCTION public._exos_api_pos_orders(uuid, uuid, integer, integer) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_api_pos_orders(uuid, uuid, integer, integer) TO service_role;

-- POST /v1/events/:id/pos-orders/:id/void: a key whose creator is an owner or
-- manager now (the dashboard's void rule for them), same night, before a scan.
CREATE OR REPLACE FUNCTION public._exos_api_pos_void(p_org uuid, p_api_key uuid, p_event uuid, p_order uuid,
                                                     p_reason text, p_drawer uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_actor uuid;
BEGIN
  v_actor := public._exos_api_key_actor(p_org, p_api_key, ARRAY['owner', 'manager']);
  RETURN public._exos_pos_reverse(v_actor, false, p_org, p_event, p_order, 'void', p_reason, false, p_drawer, p_api_key)
         - 'rung_by_me';
END $$;
REVOKE ALL ON FUNCTION public._exos_api_pos_void(uuid, uuid, uuid, uuid, text, uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_api_pos_void(uuid, uuid, uuid, uuid, text, uuid) TO service_role;

-- ===========================================================================
-- 10. Settlement: the fee setting, cash ticket sales, voids / refunds and
--     paid-outs. Redefined in full (same math as before for the default
--     setting); keeps the free-tier rate line of mig 20261029090000.
-- ===========================================================================
CREATE OR REPLACE FUNCTION public.exos_pos_settlement_summary(p_event_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  v_org uuid; v_currency text; v_bps int; r jsonb; v_base text;
BEGIN
  SELECT org_id, coalesce(currency, 'usd') INTO v_org, v_currency FROM public.exos_events WHERE id = p_event_id;
  IF v_org IS NULL THEN
    RAISE EXCEPTION 'exos_pos_settlement_summary: unknown event' USING ERRCODE = '42501';
  END IF;
  IF NOT (public.exos_is_admin()
          OR public.exos_has_org_role(v_org, ARRAY['owner','manager','finance'])
          OR (auth.uid() IS NULL AND coalesce(auth.jwt() ->> 'role', '') = 'service_role')) THEN
    RAISE EXCEPTION 'exos_pos_settlement_summary: not authorized' USING ERRCODE = '42501';
  END IF;
  v_bps := public.exos_event_fee_bps(p_event_id, now());   -- free tier: 0 (mig 20261029090000)
  /* exos: pos walkup settlement */ -- mig 20261107100000: the walk-up fee setting (OPEN operator decision).
  v_base := public.exos_pos_walkup_fee_base();

  WITH o AS (
    SELECT id, total_cents FROM public.exos_pos_orders WHERE event_id = p_event_id AND status = 'paid'
  ), pay AS (
    SELECT p.order_id,
           coalesce(sum(p.amount_cents) FILTER (WHERE p.method = 'cash'), 0)::bigint AS cash,
           coalesce(sum(p.amount_cents) FILTER (WHERE p.method = 'card'), 0)::bigint AS card,
           coalesce(sum(p.amount_cents) FILTER (WHERE p.method = 'comp'), 0)::bigint AS comp,
           coalesce(sum(p.tip_cents)    FILTER (WHERE p.method = 'cash'), 0)::bigint AS tip_cash,
           coalesce(sum(p.tip_cents)    FILTER (WHERE p.method = 'card'), 0)::bigint AS tip_card
      FROM public.exos_pos_payments p JOIN o ON o.id = p.order_id
     WHERE p.status = 'succeeded'
     GROUP BY p.order_id
  ), ln AS (
    SELECT l.order_id,
           coalesce(sum(l.line_total_cents) FILTER (WHERE l.category = 'ticket'), 0)::bigint AS ticket,
           coalesce(sum(l.line_total_cents) FILTER (WHERE l.category = 'bar'), 0)::bigint    AS bar,
           coalesce(sum(l.line_total_cents) FILTER (WHERE l.category = 'merch'), 0)::bigint  AS merch,
           coalesce(sum(l.tax_cents), 0)::bigint                                             AS tax
      FROM public.exos_pos_order_lines l JOIN o ON o.id = l.order_id
     GROUP BY l.order_id
  ), per AS (
    SELECT o.id, o.total_cents::bigint AS total, coalesce(ln.ticket, 0) AS ticket, coalesce(ln.bar, 0) AS bar,
           coalesce(ln.merch, 0) AS merch, coalesce(ln.tax, 0) AS tax,
           coalesce(pay.cash, 0) AS cash, coalesce(pay.card, 0) AS card, coalesce(pay.comp, 0) AS comp,
           coalesce(pay.tip_cash, 0) AS tip_cash, coalesce(pay.tip_card, 0) AS tip_card
      FROM o LEFT JOIN ln ON ln.order_id = o.id LEFT JOIN pay ON pay.order_id = o.id
  ), tot AS (
    SELECT count(*) AS orders,
           coalesce(sum(ticket), 0)::bigint AS ticket, coalesce(sum(bar), 0)::bigint AS bar,
           coalesce(sum(merch), 0)::bigint AS merch, coalesce(sum(tax), 0)::bigint AS tax,
           coalesce(sum(cash), 0)::bigint AS cash, coalesce(sum(card), 0)::bigint AS card,
           coalesce(sum(comp), 0)::bigint AS comp, coalesce(sum(tip_cash), 0)::bigint AS tip_cash,
           coalesce(sum(tip_card), 0)::bigint AS tip_card,
           coalesce(sum(CASE WHEN total > 0 THEN (ticket * card) / total ELSE 0 END), 0)::bigint AS card_ticket,
           coalesce(sum(CASE WHEN total > 0 THEN (ticket * cash) / total ELSE 0 END), 0)::bigint AS cash_ticket
      FROM per
  ), fee AS (
    SELECT CASE WHEN v_base = 'all-tickets' THEN tot.card_ticket + tot.cash_ticket ELSE tot.card_ticket END AS base
      FROM tot
  ), promo AS (
    SELECT coalesce(jsonb_agg(jsonb_build_object('promoter_id', x.promoter_id, 'tickets', x.qty, 'base_cents', x.base)
                              ORDER BY x.promoter_id), '[]'::jsonb) AS rows
      FROM (SELECT l.promoter_id, sum(l.quantity) AS qty,
                   sum(CASE WHEN per.total > 0
                            THEN ((l.line_total_cents - l.tax_cents)::bigint * (per.cash + per.card)) / per.total
                            ELSE 0 END)::bigint AS base
              FROM public.exos_pos_order_lines l JOIN per ON per.id = l.order_id
             WHERE l.category = 'ticket' AND l.promoter_id IS NOT NULL
             GROUP BY l.promoter_id) x
  ), dr AS (
    SELECT count(*) FILTER (WHERE status = 'open') AS open_drawers,
           count(*) FILTER (WHERE status = 'closed') AS closed_drawers,
           coalesce(sum(open_float_cents) FILTER (WHERE status = 'closed'), 0) AS float_cents,
           coalesce(sum(expected_cents), 0) AS expected, coalesce(sum(counted_cents), 0) AS counted,
           coalesce(sum(variance_cents), 0) AS variance
      FROM public.exos_pos_drawer_sessions WHERE event_id = p_event_id
  ), rev AS (
    SELECT count(*) FILTER (WHERE kind = 'void') AS voids, count(*) FILTER (WHERE kind = 'refund') AS refunds,
           coalesce(sum(total_cents) FILTER (WHERE kind = 'void'), 0)::bigint AS voided_cents,
           coalesce(sum(total_cents) FILTER (WHERE kind = 'refund'), 0)::bigint AS refunded_cents,
           coalesce(sum(cash_cents), 0)::bigint AS cash_returned,
           count(*) FILTER (WHERE override) AS overrides
      FROM public.exos_pos_reversals WHERE event_id = p_event_id
  ), po AS (
    SELECT count(*) FILTER (WHERE kind = 'paid_out') AS n,
           coalesce(sum(amount_cents) FILTER (WHERE kind = 'paid_out'), 0)::bigint AS cents
      FROM public.exos_pos_paid_outs WHERE event_id = p_event_id
  ), misc AS (
    SELECT (SELECT count(*) FROM public.exos_pos_orders WHERE event_id = p_event_id AND status = 'open') AS open_orders,
           (SELECT count(*) FROM public.exos_pos_tabs WHERE event_id = p_event_id AND status = 'open') AS open_tabs
  )
  SELECT jsonb_build_object(
           'event_id', p_event_id, 'org_id', v_org, 'currency', v_currency, 'fee_bps', v_bps,
           'orders', tot.orders, 'open_orders', misc.open_orders, 'open_tabs', misc.open_tabs,
           'gross', jsonb_build_object('ticket', tot.ticket, 'bar', tot.bar, 'merch', tot.merch,
                                       'total', tot.ticket + tot.bar + tot.merch),
           'tax_cents', tot.tax,
           'tenders', jsonb_build_object('cash', tot.cash, 'card', tot.card, 'comp', tot.comp),
           'tips', jsonb_build_object('cash', tot.tip_cash, 'card', tot.tip_card, 'total', tot.tip_cash + tot.tip_card),
           'card_ticket_cents', tot.card_ticket,
           'cash_ticket_cents', tot.cash_ticket,
           'fee_base', v_base,
           'fee_base_cents', fee.base,
           'exos_fee_cents', CASE WHEN fee.base > 0 AND v_bps > 0 THEN (fee.base * v_bps + 5000) / 10000 ELSE 0 END,
           'organizer_net_cents', tot.cash + tot.card
                                  - CASE WHEN fee.base > 0 AND v_bps > 0 THEN (fee.base * v_bps + 5000) / 10000 ELSE 0 END,
           'promoters', promo.rows,
           'reversals', jsonb_build_object('voids', rev.voids, 'refunds', rev.refunds, 'voided_cents', rev.voided_cents,
                                           'refunded_cents', rev.refunded_cents, 'cash_returned_cents', rev.cash_returned,
                                           'overrides', rev.overrides),
           'paid_outs', jsonb_build_object('count', po.n, 'cents', po.cents),
           'drawers', jsonb_build_object('open', dr.open_drawers, 'closed', dr.closed_drawers,
                                         'float_cents', dr.float_cents, 'expected_cents', dr.expected,
                                         'counted_cents', dr.counted, 'variance_cents', dr.variance),
           'computed_at', now())
    INTO r
    FROM tot, fee, promo, dr, rev, po, misc;
  RETURN r;
END $$;
REVOKE ALL ON FUNCTION public.exos_pos_settlement_summary(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.exos_pos_settlement_summary(uuid) TO authenticated, service_role;

-- ROLLBACK (manual): DROP the functions created above and the tables
-- exos_pos_paid_outs / exos_pos_reversals; drop the added columns; restore
-- exos_pos_tg_line, exos_pos_close_drawer and exos_pos_settlement_summary from
-- 20260929074000 + 20261029090000 + 20261104120000; the printed_via check
-- back to ('dashboard', 'api').
