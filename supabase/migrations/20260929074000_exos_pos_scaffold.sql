-- ============================================================================
-- Migration 20260929074000 — Exos (Bridge / D4): venue POS scaffold (Phase 3)
--
-- Lane:     d4 (exos / bridge ticketing infra)
-- Touches:  C: TABLE exos_pos_devices, exos_pos_items, exos_pos_tabs,
--              exos_pos_orders, exos_pos_order_lines, exos_pos_payments,
--              exos_pos_drawer_sessions, exos_pos_settlements;
--              FUNCTION exos_pos_can_ring, exos_pos_set_86, exos_pos_open_tab,
--              exos_pos_close_tab, exos_pos_close_drawer,
--              exos_pos_settlement_summary, exos_pos_record_settlement
--              (+ trigger functions exos_pos_tg_*)
--           R: exos_events, exos_orgs, exos_tickets, exos_ticket_tiers,
--              exos_tax_rules, exos_promoters, exos_org_memberships,
--              exos_can_door_event (20260929041000), exos_tax_cents,
--              exos_org_fee_bps (20260929062000)
-- Pre-reqs: 20260616230000 (tax rules), 20260924233000 (promoters),
--           20260929041000 (per-event door staff), 20260929062000 (fee rate)
--
-- SCAFFOLDING for the venue POS (docs/strategy.md "Phase 3", docs/pos.md):
-- box office walk-up, bar and merch, end-of-night settlement. No live
-- payments: card payments can only be written by the server (service role),
-- and nothing writes them yet (exos-pos answers 501 for payment actions).
-- NO CARD DATA is ever stored: a card payment carries at most the terminal's
-- opaque reference (a Stripe PaymentIntent id, later), never a PAN, expiry,
-- cardholder name or track data.
--
-- Money is integer cents everywhere. Design references (not copied): pretix
-- models a POS as a sales channel with its own payment providers and several
-- payments per order (split tender); hi.events keeps line snapshots on the
-- order. Both ideas are used here: a POS order is its own table
-- (source 'pos'), its lines snapshot the item, price and tax at the time of
-- sale, and exos_pos_payments holds one row per tender (cash / card / comp).
--
--   exos_pos_devices          registered iPads / readers per org (event optional)
--   exos_pos_items            the catalog: ticket | bar | merch, price, tax rule,
--                             sku, active, 86'd, optional inventory count
--   exos_pos_tabs             open / closed tabs tied to a ticket or wristband
--   exos_pos_orders           one sale; totals kept by the line trigger
--   exos_pos_order_lines      item snapshot + tax (same math as checkout)
--   exos_pos_payments         tenders; paying the total marks the order paid
--   exos_pos_drawer_sessions  cash drawer: float, counts, expected vs counted
--   exos_pos_settlements      end-of-night snapshots (draft / final)
--
-- Who can do what (RLS + SECURITY DEFINER checks):
--   * owner / manager manage devices and the catalog.
--   * door staff ring sales: exos_pos_can_ring(event) = exos_can_door_event,
--     i.e. owner / manager, or a scanner either unrestricted in the org or
--     assigned to the event (exos_event_staff). They insert orders, bar /
--     merch lines, cash and comp payments, and open drawers; tabs and 86 go
--     through functions. Ticket lines and card payments are service-role
--     only (walk-up tickets must go through the quota-aware mint path).
--   * finance reads orders and settlements.
--   * nobody outside the org sees anything (every policy is org-scoped).
--
-- Re-run safe (IF NOT EXISTS / CREATE OR REPLACE / DROP ... IF EXISTS).
-- D4 authors; applying to prod is operator-gated.
-- ============================================================================

-- ── Tables ──────────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS public.exos_pos_devices (
  id            uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id        uuid        NOT NULL REFERENCES public.exos_orgs (id) ON DELETE CASCADE,
  event_id      uuid        REFERENCES public.exos_events (id) ON DELETE SET NULL,
  name          text        NOT NULL CHECK (length(btrim(name)) BETWEEN 1 AND 80),
  kind          text        NOT NULL DEFAULT 'register'
                            CHECK (kind IN ('register', 'reader', 'printer', 'other')),
  status        text        NOT NULL DEFAULT 'pending'
                            CHECK (status IN ('pending', 'active', 'disabled', 'retired')),
  -- The reader's own serial / Stripe Terminal reader id (not a secret, not card data).
  hardware_ref  text        CHECK (hardware_ref IS NULL OR length(hardware_ref) <= 120),
  registered_by uuid,
  last_seen_at  timestamptz,
  created_at    timestamptz NOT NULL DEFAULT now(),
  updated_at    timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS exos_pos_devices_org_idx ON public.exos_pos_devices (org_id);

CREATE TABLE IF NOT EXISTS public.exos_pos_items (
  id              uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id          uuid        NOT NULL REFERENCES public.exos_orgs (id) ON DELETE CASCADE,
  event_id        uuid        REFERENCES public.exos_events (id) ON DELETE CASCADE, -- NULL = every event of the org
  category        text        NOT NULL CHECK (category IN ('ticket', 'bar', 'merch')),
  name            text        NOT NULL CHECK (length(btrim(name)) BETWEEN 1 AND 120),
  sku             text        CHECK (sku IS NULL OR sku ~ '^[A-Za-z0-9._-]{1,64}$'),
  price_cents     integer     NOT NULL CHECK (price_cents BETWEEN 0 AND 10000000),
  tax_rule_id     uuid        REFERENCES public.exos_tax_rules (id) ON DELETE SET NULL,
  tier_id         uuid        REFERENCES public.exos_ticket_tiers (id) ON DELETE CASCADE,
  active          boolean     NOT NULL DEFAULT true,
  is_86d          boolean     NOT NULL DEFAULT false,
  eighty_sixed_at timestamptz,
  eighty_sixed_by uuid,
  inventory_count integer     CHECK (inventory_count IS NULL OR inventory_count >= 0), -- NULL = not tracked
  sort_order      integer     NOT NULL DEFAULT 0,
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now(),
  -- A walk-up ticket sells a tier of one event (minted through exos_mint_tickets later).
  CONSTRAINT exos_pos_items_ticket_chk CHECK (category <> 'ticket' OR (event_id IS NOT NULL AND tier_id IS NOT NULL)),
  -- Tax rules are per event, so a taxed item belongs to that event.
  CONSTRAINT exos_pos_items_tax_chk CHECK (tax_rule_id IS NULL OR event_id IS NOT NULL)
);
CREATE INDEX IF NOT EXISTS exos_pos_items_org_idx ON public.exos_pos_items (org_id, event_id);
CREATE UNIQUE INDEX IF NOT EXISTS exos_pos_items_sku_uq ON public.exos_pos_items (org_id, sku) WHERE sku IS NOT NULL;

CREATE TABLE IF NOT EXISTS public.exos_pos_tabs (
  id             uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id         uuid        NOT NULL REFERENCES public.exos_orgs (id) ON DELETE CASCADE,
  event_id       uuid        NOT NULL REFERENCES public.exos_events (id) ON DELETE CASCADE,
  status         text        NOT NULL DEFAULT 'open' CHECK (status IN ('open', 'closed', 'void')),
  ticket_id      uuid        REFERENCES public.exos_tickets (id) ON DELETE SET NULL,
  wristband_code text        CHECK (wristband_code IS NULL OR wristband_code ~ '^[A-Za-z0-9_-]{3,64}$'),
  label          text        CHECK (label IS NULL OR length(label) <= 80),
  opened_by      uuid,
  opened_at      timestamptz NOT NULL DEFAULT now(),
  closed_by      uuid,
  closed_at      timestamptz,
  CONSTRAINT exos_pos_tabs_link_chk CHECK (ticket_id IS NOT NULL OR wristband_code IS NOT NULL)
);
CREATE INDEX IF NOT EXISTS exos_pos_tabs_event_idx ON public.exos_pos_tabs (event_id, status);
-- One open tab per wristband / per ticket at an event.
CREATE UNIQUE INDEX IF NOT EXISTS exos_pos_tabs_open_wristband_uq
  ON public.exos_pos_tabs (event_id, wristband_code) WHERE status = 'open' AND wristband_code IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS exos_pos_tabs_open_ticket_uq
  ON public.exos_pos_tabs (event_id, ticket_id) WHERE status = 'open' AND ticket_id IS NOT NULL;

CREATE TABLE IF NOT EXISTS public.exos_pos_orders (
  id             uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id         uuid        NOT NULL REFERENCES public.exos_orgs (id) ON DELETE CASCADE,
  event_id       uuid        NOT NULL REFERENCES public.exos_events (id) ON DELETE CASCADE,
  device_id      uuid        REFERENCES public.exos_pos_devices (id) ON DELETE SET NULL,
  tab_id         uuid        REFERENCES public.exos_pos_tabs (id) ON DELETE SET NULL,
  source         text        NOT NULL DEFAULT 'pos' CHECK (source = 'pos'),
  status         text        NOT NULL DEFAULT 'open' CHECK (status IN ('open', 'paid', 'void', 'refunded')),
  -- cash | card | comp, or 'split' when more than one tender paid it. Set when paid.
  payment_method text        CHECK (payment_method IS NULL OR payment_method IN ('cash', 'card', 'comp', 'split')),
  subtotal_cents integer     NOT NULL DEFAULT 0 CHECK (subtotal_cents >= 0),  -- lines net of tax
  tax_cents      integer     NOT NULL DEFAULT 0 CHECK (tax_cents >= 0),
  total_cents    integer     NOT NULL DEFAULT 0 CHECK (total_cents >= 0),     -- what the guest owes, tip excluded
  tip_cents      integer     NOT NULL DEFAULT 0 CHECK (tip_cents >= 0),
  currency       text        NOT NULL DEFAULT 'usd',
  client_ref     uuid        UNIQUE,                                          -- offline replay idempotency
  rung_by        uuid,
  created_at     timestamptz NOT NULL DEFAULT now(),
  paid_at        timestamptz,
  voided_at      timestamptz,
  void_reason    text
);
CREATE INDEX IF NOT EXISTS exos_pos_orders_event_idx ON public.exos_pos_orders (event_id, status);
CREATE INDEX IF NOT EXISTS exos_pos_orders_tab_idx ON public.exos_pos_orders (tab_id) WHERE tab_id IS NOT NULL;

CREATE TABLE IF NOT EXISTS public.exos_pos_order_lines (
  id                 uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  order_id           uuid        NOT NULL REFERENCES public.exos_pos_orders (id) ON DELETE CASCADE,
  org_id             uuid        NOT NULL,
  event_id           uuid        NOT NULL,
  item_id            uuid        NOT NULL REFERENCES public.exos_pos_items (id) ON DELETE RESTRICT,
  category           text        NOT NULL CHECK (category IN ('ticket', 'bar', 'merch')),
  name               text        NOT NULL,
  quantity           integer     NOT NULL CHECK (quantity BETWEEN 1 AND 100),
  unit_price_cents   integer     NOT NULL CHECK (unit_price_cents >= 0),
  tax_rate_percent   numeric     NOT NULL DEFAULT 0 CHECK (tax_rate_percent BETWEEN 0 AND 100),
  price_includes_tax boolean     NOT NULL DEFAULT false,
  tax_cents          integer     NOT NULL DEFAULT 0 CHECK (tax_cents >= 0),
  line_total_cents   integer     NOT NULL DEFAULT 0 CHECK (line_total_cents >= 0),
  promoter_id        uuid        REFERENCES public.exos_promoters (id) ON DELETE SET NULL,
  ticket_ids         uuid[],     -- walk-up tickets minted for this line (later)
  created_at         timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS exos_pos_order_lines_order_idx ON public.exos_pos_order_lines (order_id);
CREATE INDEX IF NOT EXISTS exos_pos_order_lines_event_idx ON public.exos_pos_order_lines (event_id, category);

CREATE TABLE IF NOT EXISTS public.exos_pos_drawer_sessions (
  id                uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id            uuid        NOT NULL REFERENCES public.exos_orgs (id) ON DELETE CASCADE,
  event_id          uuid        NOT NULL REFERENCES public.exos_events (id) ON DELETE CASCADE,
  device_id         uuid        REFERENCES public.exos_pos_devices (id) ON DELETE SET NULL,
  status            text        NOT NULL DEFAULT 'open' CHECK (status IN ('open', 'closed')),
  open_float_cents  integer     NOT NULL DEFAULT 0 CHECK (open_float_cents >= 0),
  expected_cents    integer,    -- float + cash taken (incl. cash tips), set at close
  counted_cents     integer     CHECK (counted_cents IS NULL OR counted_cents >= 0),
  variance_cents    integer,    -- counted - expected (negative = short)
  counts            jsonb,      -- {"2000": 5, "100": 12, ...}: denomination (cents) -> count
  note              text        CHECK (note IS NULL OR length(note) <= 500),
  opened_by         uuid,
  opened_at         timestamptz NOT NULL DEFAULT now(),
  closed_by         uuid,
  closed_at         timestamptz
);
CREATE INDEX IF NOT EXISTS exos_pos_drawer_sessions_event_idx ON public.exos_pos_drawer_sessions (event_id);
CREATE UNIQUE INDEX IF NOT EXISTS exos_pos_drawer_open_device_uq
  ON public.exos_pos_drawer_sessions (device_id) WHERE status = 'open' AND device_id IS NOT NULL;

CREATE TABLE IF NOT EXISTS public.exos_pos_payments (
  id                uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  order_id          uuid        NOT NULL REFERENCES public.exos_pos_orders (id) ON DELETE CASCADE,
  org_id            uuid        NOT NULL,
  event_id          uuid        NOT NULL,
  method            text        NOT NULL CHECK (method IN ('cash', 'card', 'comp')),
  amount_cents      integer     NOT NULL CHECK (amount_cents > 0),     -- applied to the order, tip excluded
  tip_cents         integer     NOT NULL DEFAULT 0 CHECK (tip_cents >= 0),
  drawer_session_id uuid        REFERENCES public.exos_pos_drawer_sessions (id) ON DELETE SET NULL,
  -- Opaque terminal reference (a Stripe PaymentIntent id, later). NEVER card data.
  terminal_ref      text        CHECK (terminal_ref IS NULL OR terminal_ref ~ '^[A-Za-z0-9_]{1,255}$'),
  comp_reason       text        CHECK (comp_reason IS NULL OR length(comp_reason) <= 200),
  status            text        NOT NULL DEFAULT 'succeeded' CHECK (status IN ('succeeded', 'refunded')),
  taken_by          uuid,
  created_at        timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT exos_pos_payments_ref_chk CHECK (terminal_ref IS NULL OR method = 'card'),
  CONSTRAINT exos_pos_payments_comp_chk CHECK (method <> 'comp' OR tip_cents = 0),
  CONSTRAINT exos_pos_payments_drawer_chk CHECK (drawer_session_id IS NULL OR method = 'cash')
);
CREATE INDEX IF NOT EXISTS exos_pos_payments_order_idx ON public.exos_pos_payments (order_id);
CREATE INDEX IF NOT EXISTS exos_pos_payments_event_idx ON public.exos_pos_payments (event_id, method);

CREATE TABLE IF NOT EXISTS public.exos_pos_settlements (
  id                uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id            uuid        NOT NULL REFERENCES public.exos_orgs (id) ON DELETE CASCADE,
  event_id          uuid        NOT NULL REFERENCES public.exos_events (id) ON DELETE CASCADE,
  status            text        NOT NULL DEFAULT 'draft' CHECK (status IN ('draft', 'final')),
  ticket_cents      integer     NOT NULL DEFAULT 0,
  bar_cents         integer     NOT NULL DEFAULT 0,
  merch_cents       integer     NOT NULL DEFAULT 0,
  tax_cents         integer     NOT NULL DEFAULT 0,
  tip_cents         integer     NOT NULL DEFAULT 0,
  cash_cents        integer     NOT NULL DEFAULT 0,
  card_cents        integer     NOT NULL DEFAULT 0,
  comp_cents        integer     NOT NULL DEFAULT 0,
  exos_fee_cents    integer     NOT NULL DEFAULT 0,
  organizer_net_cents integer   NOT NULL DEFAULT 0,
  drawer_variance_cents integer NOT NULL DEFAULT 0,
  summary           jsonb       NOT NULL,          -- the full exos_pos_settlement_summary answer
  computed_by       uuid,
  computed_at       timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS exos_pos_settlements_event_idx ON public.exos_pos_settlements (event_id, computed_at DESC);
CREATE UNIQUE INDEX IF NOT EXISTS exos_pos_settlements_final_uq
  ON public.exos_pos_settlements (event_id) WHERE status = 'final';

DROP TRIGGER IF EXISTS exos_pos_devices_touch ON public.exos_pos_devices;
CREATE TRIGGER exos_pos_devices_touch BEFORE UPDATE ON public.exos_pos_devices
  FOR EACH ROW EXECUTE FUNCTION public.exos_touch_updated_at();
DROP TRIGGER IF EXISTS exos_pos_items_touch ON public.exos_pos_items;
CREATE TRIGGER exos_pos_items_touch BEFORE UPDATE ON public.exos_pos_items
  FOR EACH ROW EXECUTE FUNCTION public.exos_touch_updated_at();

-- ── Who may ring sales at an event ─────────────────────────────────────────

-- Same people who may work the door (mig 20260929041000): owner / manager, or
-- a scanner who is org-wide or assigned to this event. Admins too.
CREATE OR REPLACE FUNCTION public.exos_pos_can_ring(p_event_id uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT p_event_id IS NOT NULL AND public.exos_can_door_event(p_event_id);
$$;
REVOKE ALL ON FUNCTION public.exos_pos_can_ring(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.exos_pos_can_ring(uuid) TO authenticated, service_role;

-- ── Integrity triggers (server-side truth for org, totals, stock) ──────────

-- Devices / items / drawers: the org comes from the event when there is one.
CREATE OR REPLACE FUNCTION public.exos_pos_tg_event_org()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_org uuid;
BEGIN
  IF NEW.event_id IS NOT NULL THEN
    SELECT org_id INTO v_org FROM public.exos_events WHERE id = NEW.event_id;
    IF v_org IS NULL OR (NEW.org_id IS NOT NULL AND NEW.org_id <> v_org) THEN
      RAISE EXCEPTION '%: event belongs to another organization', TG_TABLE_NAME USING ERRCODE = '22023';
    END IF;
    NEW.org_id := v_org;
  END IF;
  RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION public.exos_pos_tg_event_org() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS exos_pos_devices_org ON public.exos_pos_devices;
CREATE TRIGGER exos_pos_devices_org BEFORE INSERT OR UPDATE OF event_id, org_id ON public.exos_pos_devices
  FOR EACH ROW EXECUTE FUNCTION public.exos_pos_tg_event_org();

-- Items: org from event; tax rule and tier must belong to the item's event.
CREATE OR REPLACE FUNCTION public.exos_pos_tg_item()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
  IF NEW.tax_rule_id IS NOT NULL AND NOT EXISTS (
       SELECT 1 FROM public.exos_tax_rules r WHERE r.id = NEW.tax_rule_id AND r.event_id = NEW.event_id) THEN
    RAISE EXCEPTION 'exos_pos_items: tax rule must belong to the item''s event' USING ERRCODE = '22023';
  END IF;
  IF NEW.tier_id IS NOT NULL AND NOT EXISTS (
       SELECT 1 FROM public.exos_ticket_tiers t WHERE t.id = NEW.tier_id AND t.event_id = NEW.event_id) THEN
    RAISE EXCEPTION 'exos_pos_items: tier must belong to the item''s event' USING ERRCODE = '22023';
  END IF;
  RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION public.exos_pos_tg_item() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS exos_pos_items_org ON public.exos_pos_items;
CREATE TRIGGER exos_pos_items_org BEFORE INSERT OR UPDATE OF event_id, org_id ON public.exos_pos_items
  FOR EACH ROW EXECUTE FUNCTION public.exos_pos_tg_event_org();
DROP TRIGGER IF EXISTS exos_pos_items_refs ON public.exos_pos_items;
CREATE TRIGGER exos_pos_items_refs BEFORE INSERT OR UPDATE OF event_id, tax_rule_id, tier_id ON public.exos_pos_items
  FOR EACH ROW EXECUTE FUNCTION public.exos_pos_tg_item();

-- A new drawer starts open, uncounted; its org is the event's.
CREATE OR REPLACE FUNCTION public.exos_pos_tg_drawer_new()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
  SELECT org_id INTO NEW.org_id FROM public.exos_events WHERE id = NEW.event_id;
  IF NEW.org_id IS NULL THEN
    RAISE EXCEPTION 'exos_pos_drawer_sessions: unknown event' USING ERRCODE = '22023';
  END IF;
  NEW.status := 'open';
  NEW.expected_cents := NULL; NEW.counted_cents := NULL; NEW.variance_cents := NULL;
  NEW.closed_by := NULL; NEW.closed_at := NULL;
  NEW.opened_by := coalesce(auth.uid(), NEW.opened_by);
  IF NEW.device_id IS NOT NULL AND NOT EXISTS (
       SELECT 1 FROM public.exos_pos_devices d
        WHERE d.id = NEW.device_id AND d.org_id = NEW.org_id AND d.status = 'active') THEN
    RAISE EXCEPTION 'exos_pos_drawer_sessions: device is not an active device of this organization' USING ERRCODE = '22023';
  END IF;
  RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION public.exos_pos_tg_drawer_new() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS exos_pos_drawer_new ON public.exos_pos_drawer_sessions;
CREATE TRIGGER exos_pos_drawer_new BEFORE INSERT ON public.exos_pos_drawer_sessions
  FOR EACH ROW EXECUTE FUNCTION public.exos_pos_tg_drawer_new();

-- Orders: org from event, always born open with zero totals; tab and device checked.
CREATE OR REPLACE FUNCTION public.exos_pos_tg_order_new()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
  SELECT org_id, coalesce(currency, 'usd') INTO NEW.org_id, NEW.currency
    FROM public.exos_events WHERE id = NEW.event_id;
  IF NEW.org_id IS NULL THEN
    RAISE EXCEPTION 'exos_pos_orders: unknown event' USING ERRCODE = '22023';
  END IF;
  NEW.source := 'pos'; NEW.status := 'open'; NEW.payment_method := NULL;
  NEW.subtotal_cents := 0; NEW.tax_cents := 0; NEW.total_cents := 0; NEW.tip_cents := 0;
  NEW.paid_at := NULL; NEW.voided_at := NULL; NEW.void_reason := NULL;
  NEW.rung_by := coalesce(auth.uid(), NEW.rung_by);
  IF NEW.tab_id IS NOT NULL AND NOT EXISTS (
       SELECT 1 FROM public.exos_pos_tabs t WHERE t.id = NEW.tab_id AND t.event_id = NEW.event_id AND t.status = 'open') THEN
    RAISE EXCEPTION 'exos_pos_orders: tab is not open at this event' USING ERRCODE = '22023';
  END IF;
  IF NEW.device_id IS NOT NULL AND NOT EXISTS (
       SELECT 1 FROM public.exos_pos_devices d WHERE d.id = NEW.device_id AND d.org_id = NEW.org_id AND d.status = 'active') THEN
    RAISE EXCEPTION 'exos_pos_orders: device is not an active device of this organization' USING ERRCODE = '22023';
  END IF;
  RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION public.exos_pos_tg_order_new() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS exos_pos_orders_new ON public.exos_pos_orders;
CREATE TRIGGER exos_pos_orders_new BEFORE INSERT ON public.exos_pos_orders
  FOR EACH ROW EXECUTE FUNCTION public.exos_pos_tg_order_new();

-- Lines: snapshot the item, refuse 86'd / inactive / out of stock, compute tax
-- the way checkout does (_shared/pricing.ts allInCents, public.exos_tax_cents):
--   exclusive: tax per unit, rounded, x quantity; total = (unit + unit tax) x qty
--   inclusive: total = unit x qty; tax = the embedded part of that total
CREATE OR REPLACE FUNCTION public.exos_pos_tg_line()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE o record; i record; v_rate numeric := 0; v_incl boolean := false;
BEGIN
  SELECT * INTO o FROM public.exos_pos_orders WHERE id = NEW.order_id FOR UPDATE;
  IF o.id IS NULL OR o.status <> 'open' THEN
    RAISE EXCEPTION 'exos_pos_order_lines: order is not open' USING ERRCODE = '22023';
  END IF;
  SELECT * INTO i FROM public.exos_pos_items WHERE id = NEW.item_id FOR UPDATE;
  IF i.id IS NULL OR i.org_id <> o.org_id OR (i.event_id IS NOT NULL AND i.event_id <> o.event_id) THEN
    RAISE EXCEPTION 'exos_pos_order_lines: item is not sold at this event' USING ERRCODE = '22023';
  END IF;
  IF NOT i.active THEN
    RAISE EXCEPTION 'exos_pos_order_lines: item is not active' USING ERRCODE = '22023';
  END IF;
  IF i.is_86d THEN
    RAISE EXCEPTION 'exos_pos_order_lines: item is 86''d' USING ERRCODE = 'P0001', HINT = '86';
  END IF;
  IF i.inventory_count IS NOT NULL THEN
    IF i.inventory_count < NEW.quantity THEN
      RAISE EXCEPTION 'exos_pos_order_lines: only % left', i.inventory_count USING ERRCODE = 'P0001';
    END IF;
    UPDATE public.exos_pos_items SET inventory_count = inventory_count - NEW.quantity WHERE id = i.id;
  END IF;
  IF i.tax_rule_id IS NOT NULL THEN
    SELECT rate_percent, price_includes_tax INTO v_rate, v_incl FROM public.exos_tax_rules WHERE id = i.tax_rule_id;
  END IF;
  NEW.org_id := o.org_id; NEW.event_id := o.event_id;
  NEW.category := i.category; NEW.name := i.name;
  NEW.unit_price_cents := i.price_cents;
  NEW.tax_rate_percent := coalesce(v_rate, 0); NEW.price_includes_tax := coalesce(v_incl, false);
  IF NEW.price_includes_tax THEN
    NEW.line_total_cents := NEW.unit_price_cents * NEW.quantity;
    NEW.tax_cents := public.exos_tax_cents(NEW.line_total_cents, NEW.tax_rate_percent, true);
  ELSE
    NEW.tax_cents := public.exos_tax_cents(NEW.unit_price_cents, NEW.tax_rate_percent, false) * NEW.quantity;
    NEW.line_total_cents := NEW.unit_price_cents * NEW.quantity + NEW.tax_cents;
  END IF;
  IF NEW.promoter_id IS NOT NULL AND NOT EXISTS (
       SELECT 1 FROM public.exos_promoters p WHERE p.id = NEW.promoter_id AND p.org_id = o.org_id) THEN
    RAISE EXCEPTION 'exos_pos_order_lines: promoter of another organization' USING ERRCODE = '22023';
  END IF;
  NEW.ticket_ids := NULL;  -- set by the mint path only (later)
  RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION public.exos_pos_tg_line() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS exos_pos_lines_new ON public.exos_pos_order_lines;
CREATE TRIGGER exos_pos_lines_new BEFORE INSERT ON public.exos_pos_order_lines
  FOR EACH ROW EXECUTE FUNCTION public.exos_pos_tg_line();

CREATE OR REPLACE FUNCTION public.exos_pos_tg_line_totals()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
  UPDATE public.exos_pos_orders o
     SET total_cents    = s.total,
         tax_cents      = s.tax,
         subtotal_cents = s.total - s.tax
    FROM (SELECT coalesce(sum(line_total_cents), 0)::int AS total, coalesce(sum(tax_cents), 0)::int AS tax
            FROM public.exos_pos_order_lines WHERE order_id = NEW.order_id) s
   WHERE o.id = NEW.order_id;
  RETURN NULL;
END $$;
REVOKE ALL ON FUNCTION public.exos_pos_tg_line_totals() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS exos_pos_lines_totals ON public.exos_pos_order_lines;
CREATE TRIGGER exos_pos_lines_totals AFTER INSERT ON public.exos_pos_order_lines
  FOR EACH ROW EXECUTE FUNCTION public.exos_pos_tg_line_totals();

-- Payments: never more than what's left; a cash payment's drawer must be open
-- at the same event. Paying the total marks the order paid.
CREATE OR REPLACE FUNCTION public.exos_pos_tg_payment()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE o record; v_paid int;
BEGIN
  SELECT * INTO o FROM public.exos_pos_orders WHERE id = NEW.order_id FOR UPDATE;
  IF o.id IS NULL OR o.status <> 'open' THEN
    RAISE EXCEPTION 'exos_pos_payments: order is not open' USING ERRCODE = '22023';
  END IF;
  SELECT coalesce(sum(amount_cents), 0) INTO v_paid FROM public.exos_pos_payments
   WHERE order_id = o.id AND status = 'succeeded';
  IF NEW.amount_cents > o.total_cents - v_paid THEN
    RAISE EXCEPTION 'exos_pos_payments: % is more than the % left on the order', NEW.amount_cents, o.total_cents - v_paid
      USING ERRCODE = '22023';
  END IF;
  IF NEW.drawer_session_id IS NOT NULL AND NOT EXISTS (
       SELECT 1 FROM public.exos_pos_drawer_sessions d
        WHERE d.id = NEW.drawer_session_id AND d.event_id = o.event_id AND d.status = 'open') THEN
    RAISE EXCEPTION 'exos_pos_payments: drawer is not open at this event' USING ERRCODE = '22023';
  END IF;
  NEW.org_id := o.org_id; NEW.event_id := o.event_id; NEW.status := 'succeeded';
  NEW.taken_by := coalesce(auth.uid(), NEW.taken_by);
  RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION public.exos_pos_tg_payment() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS exos_pos_payments_new ON public.exos_pos_payments;
CREATE TRIGGER exos_pos_payments_new BEFORE INSERT ON public.exos_pos_payments
  FOR EACH ROW EXECUTE FUNCTION public.exos_pos_tg_payment();

CREATE OR REPLACE FUNCTION public.exos_pos_tg_payment_settle()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_paid int; v_tips int; v_methods text[];
BEGIN
  SELECT coalesce(sum(amount_cents), 0), coalesce(sum(tip_cents), 0), array_agg(DISTINCT method)
    INTO v_paid, v_tips, v_methods
    FROM public.exos_pos_payments WHERE order_id = NEW.order_id AND status = 'succeeded';
  UPDATE public.exos_pos_orders
     SET tip_cents = v_tips,
         status = CASE WHEN v_paid >= total_cents AND total_cents > 0 THEN 'paid' ELSE status END,
         paid_at = CASE WHEN v_paid >= total_cents AND total_cents > 0 THEN now() ELSE paid_at END,
         payment_method = CASE WHEN v_paid >= total_cents AND total_cents > 0
                               THEN CASE WHEN cardinality(v_methods) = 1 THEN v_methods[1] ELSE 'split' END
                               ELSE payment_method END
   WHERE id = NEW.order_id;
  RETURN NULL;
END $$;
REVOKE ALL ON FUNCTION public.exos_pos_tg_payment_settle() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS exos_pos_payments_settle ON public.exos_pos_payments;
CREATE TRIGGER exos_pos_payments_settle AFTER INSERT ON public.exos_pos_payments
  FOR EACH ROW EXECUTE FUNCTION public.exos_pos_tg_payment_settle();

-- ── RLS + grants ───────────────────────────────────────────────────────────

ALTER TABLE public.exos_pos_devices         ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.exos_pos_items           ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.exos_pos_tabs            ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.exos_pos_orders          ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.exos_pos_order_lines     ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.exos_pos_payments        ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.exos_pos_drawer_sessions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.exos_pos_settlements     ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON public.exos_pos_devices, public.exos_pos_items, public.exos_pos_tabs,
              public.exos_pos_orders, public.exos_pos_order_lines, public.exos_pos_payments,
              public.exos_pos_drawer_sessions, public.exos_pos_settlements
  FROM PUBLIC, anon, authenticated;
GRANT ALL ON public.exos_pos_devices, public.exos_pos_items, public.exos_pos_tabs,
             public.exos_pos_orders, public.exos_pos_order_lines, public.exos_pos_payments,
             public.exos_pos_drawer_sessions, public.exos_pos_settlements
  TO service_role;

-- Devices: owner / manager manage; staff of the org read.
GRANT SELECT, INSERT, UPDATE, DELETE ON public.exos_pos_devices TO authenticated;
DROP POLICY IF EXISTS exos_pos_devices_sel ON public.exos_pos_devices;
CREATE POLICY exos_pos_devices_sel ON public.exos_pos_devices FOR SELECT TO authenticated
  USING (public.exos_is_admin() OR public.exos_has_org_role(org_id, ARRAY['owner','manager','finance','scanner']));
DROP POLICY IF EXISTS exos_pos_devices_wr ON public.exos_pos_devices;
CREATE POLICY exos_pos_devices_wr ON public.exos_pos_devices FOR ALL TO authenticated
  USING (public.exos_is_admin() OR public.exos_has_org_role(org_id, ARRAY['owner','manager']))
  WITH CHECK (public.exos_is_admin() OR public.exos_has_org_role(org_id, ARRAY['owner','manager']));

-- Catalog: owner / manager manage; staff read (86 goes through exos_pos_set_86).
GRANT SELECT, INSERT, UPDATE, DELETE ON public.exos_pos_items TO authenticated;
DROP POLICY IF EXISTS exos_pos_items_sel ON public.exos_pos_items;
CREATE POLICY exos_pos_items_sel ON public.exos_pos_items FOR SELECT TO authenticated
  USING (public.exos_is_admin()
         OR public.exos_has_org_role(org_id, ARRAY['owner','manager','finance'])
         OR (event_id IS NULL AND public.exos_has_org_role(org_id, ARRAY['scanner']))
         OR (event_id IS NOT NULL AND public.exos_pos_can_ring(event_id)));
DROP POLICY IF EXISTS exos_pos_items_wr ON public.exos_pos_items;
CREATE POLICY exos_pos_items_wr ON public.exos_pos_items FOR ALL TO authenticated
  USING (public.exos_is_admin() OR public.exos_has_org_role(org_id, ARRAY['owner','manager']))
  WITH CHECK (public.exos_is_admin() OR public.exos_has_org_role(org_id, ARRAY['owner','manager']));

-- Tabs: read by people who can ring the event (and finance); written by functions.
GRANT SELECT ON public.exos_pos_tabs TO authenticated;
DROP POLICY IF EXISTS exos_pos_tabs_sel ON public.exos_pos_tabs;
CREATE POLICY exos_pos_tabs_sel ON public.exos_pos_tabs FOR SELECT TO authenticated
  USING (public.exos_pos_can_ring(event_id) OR public.exos_has_org_role(org_id, ARRAY['finance']));

-- Orders: staff ring (insert); finance reads. No client UPDATE / DELETE.
GRANT SELECT, INSERT ON public.exos_pos_orders TO authenticated;
DROP POLICY IF EXISTS exos_pos_orders_sel ON public.exos_pos_orders;
CREATE POLICY exos_pos_orders_sel ON public.exos_pos_orders FOR SELECT TO authenticated
  USING (public.exos_pos_can_ring(event_id) OR public.exos_has_org_role(org_id, ARRAY['finance']));
DROP POLICY IF EXISTS exos_pos_orders_ins ON public.exos_pos_orders;
CREATE POLICY exos_pos_orders_ins ON public.exos_pos_orders FOR INSERT TO authenticated
  WITH CHECK (public.exos_pos_can_ring(event_id));

-- Lines: bar / merch from staff; ticket lines only from the server (mint path).
GRANT SELECT, INSERT ON public.exos_pos_order_lines TO authenticated;
DROP POLICY IF EXISTS exos_pos_lines_sel ON public.exos_pos_order_lines;
CREATE POLICY exos_pos_lines_sel ON public.exos_pos_order_lines FOR SELECT TO authenticated
  USING (public.exos_pos_can_ring(event_id) OR public.exos_has_org_role(org_id, ARRAY['finance']));
DROP POLICY IF EXISTS exos_pos_lines_ins ON public.exos_pos_order_lines;
CREATE POLICY exos_pos_lines_ins ON public.exos_pos_order_lines FOR INSERT TO authenticated
  WITH CHECK (category IN ('bar', 'merch') AND public.exos_pos_can_ring(event_id));

-- Payments: cash and comp from staff; card only from the server (terminal path).
GRANT SELECT, INSERT ON public.exos_pos_payments TO authenticated;
DROP POLICY IF EXISTS exos_pos_payments_sel ON public.exos_pos_payments;
CREATE POLICY exos_pos_payments_sel ON public.exos_pos_payments FOR SELECT TO authenticated
  USING (public.exos_pos_can_ring(event_id) OR public.exos_has_org_role(org_id, ARRAY['finance']));
DROP POLICY IF EXISTS exos_pos_payments_ins ON public.exos_pos_payments;
CREATE POLICY exos_pos_payments_ins ON public.exos_pos_payments FOR INSERT TO authenticated
  WITH CHECK (method IN ('cash', 'comp') AND terminal_ref IS NULL AND public.exos_pos_can_ring(event_id));

-- Drawers: staff open (insert) and read; closed through exos_pos_close_drawer.
GRANT SELECT, INSERT ON public.exos_pos_drawer_sessions TO authenticated;
DROP POLICY IF EXISTS exos_pos_drawer_sel ON public.exos_pos_drawer_sessions;
CREATE POLICY exos_pos_drawer_sel ON public.exos_pos_drawer_sessions FOR SELECT TO authenticated
  USING (public.exos_pos_can_ring(event_id) OR public.exos_has_org_role(org_id, ARRAY['finance']));
DROP POLICY IF EXISTS exos_pos_drawer_ins ON public.exos_pos_drawer_sessions;
CREATE POLICY exos_pos_drawer_ins ON public.exos_pos_drawer_sessions FOR INSERT TO authenticated
  WITH CHECK (public.exos_pos_can_ring(event_id));

-- Settlements: owner / manager / finance read; written by exos_pos_record_settlement.
GRANT SELECT ON public.exos_pos_settlements TO authenticated;
DROP POLICY IF EXISTS exos_pos_settlements_sel ON public.exos_pos_settlements;
CREATE POLICY exos_pos_settlements_sel ON public.exos_pos_settlements FOR SELECT TO authenticated
  USING (public.exos_is_admin() OR public.exos_has_org_role(org_id, ARRAY['owner','manager','finance']));

-- ── Functions ──────────────────────────────────────────────────────────────

-- 86 an item (or bring it back). Owner / manager, or staff who can ring the
-- item's event (bartenders 86 at the bar). Org-wide items: owner / manager.
CREATE OR REPLACE FUNCTION public.exos_pos_set_86(p_item_id uuid, p_is_86d boolean DEFAULT true)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE i record;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'exos_pos_set_86: not authenticated' USING ERRCODE = '42501';
  END IF;
  SELECT * INTO i FROM public.exos_pos_items WHERE id = p_item_id FOR UPDATE;
  IF i.id IS NULL THEN
    RAISE EXCEPTION 'exos_pos_set_86: no such item' USING ERRCODE = '42501';
  END IF;
  IF NOT (public.exos_is_admin()
          OR public.exos_has_org_role(i.org_id, ARRAY['owner','manager'])
          OR (i.event_id IS NOT NULL AND public.exos_pos_can_ring(i.event_id))) THEN
    RAISE EXCEPTION 'exos_pos_set_86: not authorized' USING ERRCODE = '42501';
  END IF;
  UPDATE public.exos_pos_items
     SET is_86d = coalesce(p_is_86d, true),
         eighty_sixed_at = CASE WHEN coalesce(p_is_86d, true) THEN now() END,
         eighty_sixed_by = CASE WHEN coalesce(p_is_86d, true) THEN auth.uid() END
   WHERE id = p_item_id;
  RETURN jsonb_build_object('item_id', p_item_id, 'is_86d', coalesce(p_is_86d, true));
END $$;
REVOKE ALL ON FUNCTION public.exos_pos_set_86(uuid, boolean) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.exos_pos_set_86(uuid, boolean) TO authenticated, service_role;

-- Open a tab on a ticket (active, at this event) or a wristband code.
CREATE OR REPLACE FUNCTION public.exos_pos_open_tab(
  p_event_id uuid, p_ticket_id uuid DEFAULT NULL, p_wristband_code text DEFAULT NULL, p_label text DEFAULT NULL
) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_org uuid; v_id uuid;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'exos_pos_open_tab: not authenticated' USING ERRCODE = '42501';
  END IF;
  IF NOT public.exos_pos_can_ring(p_event_id) THEN
    RAISE EXCEPTION 'exos_pos_open_tab: not authorized' USING ERRCODE = '42501';
  END IF;
  IF p_ticket_id IS NULL AND nullif(btrim(p_wristband_code), '') IS NULL THEN
    RAISE EXCEPTION 'exos_pos_open_tab: a ticket or a wristband is required' USING ERRCODE = '22023';
  END IF;
  IF p_ticket_id IS NOT NULL AND NOT EXISTS (
       SELECT 1 FROM public.exos_tickets t
        WHERE t.id = p_ticket_id AND t.event_id = p_event_id AND t.status IN ('active', 'used')) THEN
    RAISE EXCEPTION 'exos_pos_open_tab: ticket is not valid for this event' USING ERRCODE = '22023';
  END IF;
  SELECT org_id INTO v_org FROM public.exos_events WHERE id = p_event_id;
  INSERT INTO public.exos_pos_tabs (org_id, event_id, ticket_id, wristband_code, label, opened_by)
  VALUES (v_org, p_event_id, p_ticket_id, nullif(btrim(p_wristband_code), ''), nullif(btrim(p_label), ''), auth.uid())
  RETURNING id INTO v_id;
  RETURN v_id;
EXCEPTION WHEN unique_violation THEN
  RAISE EXCEPTION 'exos_pos_open_tab: that ticket or wristband already has an open tab' USING ERRCODE = '23505';
END $$;
REVOKE ALL ON FUNCTION public.exos_pos_open_tab(uuid, uuid, text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.exos_pos_open_tab(uuid, uuid, text, text) TO authenticated, service_role;

-- Close a tab. Every order on it must be paid (or void); empty open orders
-- are voided. Returns the tab's totals. (Paying a tab in one tender that fans
-- out to its orders is part of the payment path, later.)
CREATE OR REPLACE FUNCTION public.exos_pos_close_tab(p_tab_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE t record; v_due int; v_total int; v_tips int; v_orders int;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'exos_pos_close_tab: not authenticated' USING ERRCODE = '42501';
  END IF;
  SELECT * INTO t FROM public.exos_pos_tabs WHERE id = p_tab_id FOR UPDATE;
  IF t.id IS NULL OR NOT public.exos_pos_can_ring(t.event_id) THEN
    RAISE EXCEPTION 'exos_pos_close_tab: not authorized' USING ERRCODE = '42501';
  END IF;
  IF t.status <> 'open' THEN
    RAISE EXCEPTION 'exos_pos_close_tab: tab is %', t.status USING ERRCODE = '22023';
  END IF;
  UPDATE public.exos_pos_orders SET status = 'void', voided_at = now(), void_reason = 'empty order on a closed tab'
   WHERE tab_id = p_tab_id AND status = 'open' AND total_cents = 0;
  SELECT coalesce(sum(o.total_cents - coalesce(p.paid, 0)) FILTER (WHERE o.status = 'open'), 0)
    INTO v_due
    FROM public.exos_pos_orders o
    LEFT JOIN LATERAL (SELECT sum(amount_cents) AS paid FROM public.exos_pos_payments
                        WHERE order_id = o.id AND status = 'succeeded') p ON true
   WHERE o.tab_id = p_tab_id;
  IF v_due > 0 THEN
    RAISE EXCEPTION 'exos_pos_close_tab: % still due on the tab', v_due USING ERRCODE = 'P0001', HINT = 'balance-due';
  END IF;
  SELECT count(*), coalesce(sum(total_cents), 0), coalesce(sum(tip_cents), 0)
    INTO v_orders, v_total, v_tips
    FROM public.exos_pos_orders WHERE tab_id = p_tab_id AND status = 'paid';
  UPDATE public.exos_pos_tabs SET status = 'closed', closed_at = now(), closed_by = auth.uid() WHERE id = p_tab_id;
  RETURN jsonb_build_object('tab_id', p_tab_id, 'orders', v_orders, 'total_cents', v_total, 'tip_cents', v_tips);
END $$;
REVOKE ALL ON FUNCTION public.exos_pos_close_tab(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.exos_pos_close_tab(uuid) TO authenticated, service_role;

-- Close a cash drawer: expected = float + cash taken into it (amount + cash
-- tips); variance = counted - expected. Counts (denomination cents -> count),
-- when given, must add up to counted. Same math as _shared/pos/drawer.ts.
CREATE OR REPLACE FUNCTION public.exos_pos_close_drawer(
  p_session_id uuid, p_counted_cents integer, p_counts jsonb DEFAULT NULL, p_note text DEFAULT NULL
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE d record; v_cash int; v_expected int; v_sum bigint;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'exos_pos_close_drawer: not authenticated' USING ERRCODE = '42501';
  END IF;
  SELECT * INTO d FROM public.exos_pos_drawer_sessions WHERE id = p_session_id FOR UPDATE;
  IF d.id IS NULL OR NOT public.exos_pos_can_ring(d.event_id) THEN
    RAISE EXCEPTION 'exos_pos_close_drawer: not authorized' USING ERRCODE = '42501';
  END IF;
  IF d.status <> 'open' THEN
    RAISE EXCEPTION 'exos_pos_close_drawer: drawer is already closed' USING ERRCODE = '22023';
  END IF;
  IF p_counted_cents IS NULL OR p_counted_cents < 0 THEN
    RAISE EXCEPTION 'exos_pos_close_drawer: counted amount required' USING ERRCODE = '22023';
  END IF;
  IF p_counts IS NOT NULL THEN
    IF jsonb_typeof(p_counts) <> 'object' OR EXISTS (
         SELECT 1 FROM jsonb_each_text(p_counts) e
          WHERE e.key !~ '^[1-9][0-9]{0,5}$' OR e.value !~ '^[0-9]{1,6}$') THEN
      RAISE EXCEPTION 'exos_pos_close_drawer: counts must map denomination cents to whole counts' USING ERRCODE = '22023';
    END IF;
    SELECT coalesce(sum(e.key::bigint * e.value::bigint), 0) INTO v_sum FROM jsonb_each_text(p_counts) e;
    IF v_sum <> p_counted_cents THEN
      RAISE EXCEPTION 'exos_pos_close_drawer: counts add up to %, not %', v_sum, p_counted_cents USING ERRCODE = '22023';
    END IF;
  END IF;
  SELECT coalesce(sum(amount_cents + tip_cents), 0) INTO v_cash
    FROM public.exos_pos_payments
   WHERE drawer_session_id = p_session_id AND method = 'cash' AND status = 'succeeded';
  v_expected := d.open_float_cents + v_cash;
  UPDATE public.exos_pos_drawer_sessions
     SET status = 'closed', expected_cents = v_expected, counted_cents = p_counted_cents,
         variance_cents = p_counted_cents - v_expected, counts = p_counts,
         note = left(p_note, 500), closed_by = auth.uid(), closed_at = now()
   WHERE id = p_session_id;
  RETURN jsonb_build_object('session_id', p_session_id, 'open_float_cents', d.open_float_cents,
                            'cash_taken_cents', v_cash, 'expected_cents', v_expected,
                            'counted_cents', p_counted_cents, 'variance_cents', p_counted_cents - v_expected);
END $$;
REVOKE ALL ON FUNCTION public.exos_pos_close_drawer(uuid, integer, jsonb, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.exos_pos_close_drawer(uuid, integer, jsonb, text) TO authenticated, service_role;

-- End-of-night settlement for an event, computed from paid POS orders.
-- Same math as _shared/pos/settlement.ts (buildSettlement):
--   gross per category = line totals (tax in, comps in) of paid orders
--   cash / card / comp  = tenders (tips apart); tips per method
--   card ticket sales   = per order floor(ticket gross x card / total)
--   Exos fee            = exos_org_fee_bps(org, now) of card ticket sales,
--                         to the cent, half up (0 in the org's free months).
--                         OPERATOR DECISION (docs/pos.md): bar, merch and cash
--                         are not charged yet.
--   organizer net       = cash + card - Exos fee (tips are owed to staff;
--                         card processing comes off the Stripe payout)
--   promoters           = per promoter, ticket lines net of tax, paid share
--                         (floor(net x (cash + card) / total)); the commission
--                         itself is the caller's hook (terms live elsewhere)
--   drawers             = float, expected, counted, variance of closed drawers
-- Owner / manager / finance (or the service role).
CREATE OR REPLACE FUNCTION public.exos_pos_settlement_summary(p_event_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  v_org uuid; v_currency text; v_bps int; r jsonb;
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
  v_bps := public.exos_org_fee_bps(v_org, now());

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
    -- sum(bigint) is numeric: cast back so the fee below is integer math.
    SELECT count(*) AS orders,
           coalesce(sum(ticket), 0)::bigint AS ticket, coalesce(sum(bar), 0)::bigint AS bar,
           coalesce(sum(merch), 0)::bigint AS merch, coalesce(sum(tax), 0)::bigint AS tax,
           coalesce(sum(cash), 0)::bigint AS cash, coalesce(sum(card), 0)::bigint AS card,
           coalesce(sum(comp), 0)::bigint AS comp, coalesce(sum(tip_cash), 0)::bigint AS tip_cash,
           coalesce(sum(tip_card), 0)::bigint AS tip_card,
           coalesce(sum(CASE WHEN total > 0 THEN (ticket * card) / total ELSE 0 END), 0)::bigint AS card_ticket
      FROM per
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
           'exos_fee_cents', CASE WHEN tot.card_ticket > 0 AND v_bps > 0
                                  THEN (tot.card_ticket * v_bps + 5000) / 10000 ELSE 0 END,
           'organizer_net_cents', tot.cash + tot.card
                                  - CASE WHEN tot.card_ticket > 0 AND v_bps > 0
                                         THEN (tot.card_ticket * v_bps + 5000) / 10000 ELSE 0 END,
           'promoters', promo.rows,
           'drawers', jsonb_build_object('open', dr.open_drawers, 'closed', dr.closed_drawers,
                                         'float_cents', dr.float_cents, 'expected_cents', dr.expected,
                                         'counted_cents', dr.counted, 'variance_cents', dr.variance),
           'computed_at', now())
    INTO r
    FROM tot, promo, dr, misc;
  RETURN r;
END $$;
REVOKE ALL ON FUNCTION public.exos_pos_settlement_summary(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.exos_pos_settlement_summary(uuid) TO authenticated, service_role;

-- Record the summary as a settlement row (owner / manager). 'final' once per
-- event; a final settlement needs every drawer closed and no open orders.
CREATE OR REPLACE FUNCTION public.exos_pos_record_settlement(p_event_id uuid, p_final boolean DEFAULT false)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_org uuid; s jsonb; v_id uuid;
BEGIN
  SELECT org_id INTO v_org FROM public.exos_events WHERE id = p_event_id;
  IF v_org IS NULL OR NOT (public.exos_is_admin() OR public.exos_has_org_role(v_org, ARRAY['owner','manager'])) THEN
    RAISE EXCEPTION 'exos_pos_record_settlement: not authorized' USING ERRCODE = '42501';
  END IF;
  s := public.exos_pos_settlement_summary(p_event_id);
  IF coalesce(p_final, false) AND ((s -> 'drawers' ->> 'open')::int > 0 OR (s ->> 'open_orders')::int > 0) THEN
    RAISE EXCEPTION 'exos_pos_record_settlement: close every drawer and order first' USING ERRCODE = 'P0001';
  END IF;
  INSERT INTO public.exos_pos_settlements (
    org_id, event_id, status, ticket_cents, bar_cents, merch_cents, tax_cents, tip_cents,
    cash_cents, card_cents, comp_cents, exos_fee_cents, organizer_net_cents, drawer_variance_cents,
    summary, computed_by)
  VALUES (
    v_org, p_event_id, CASE WHEN coalesce(p_final, false) THEN 'final' ELSE 'draft' END,
    (s -> 'gross' ->> 'ticket')::int, (s -> 'gross' ->> 'bar')::int, (s -> 'gross' ->> 'merch')::int,
    (s ->> 'tax_cents')::int, (s -> 'tips' ->> 'total')::int,
    (s -> 'tenders' ->> 'cash')::int, (s -> 'tenders' ->> 'card')::int, (s -> 'tenders' ->> 'comp')::int,
    (s ->> 'exos_fee_cents')::int, (s ->> 'organizer_net_cents')::int,
    (s -> 'drawers' ->> 'variance_cents')::int, s, auth.uid())
  RETURNING id INTO v_id;
  RETURN v_id;
EXCEPTION WHEN unique_violation THEN
  RAISE EXCEPTION 'exos_pos_record_settlement: this event already has a final settlement' USING ERRCODE = '23505';
END $$;
REVOKE ALL ON FUNCTION public.exos_pos_record_settlement(uuid, boolean) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.exos_pos_record_settlement(uuid, boolean) TO authenticated, service_role;

COMMENT ON TABLE public.exos_pos_items IS
  'POS catalog (mig 20260929074000): ticket | bar | merch, integer cents, tax rule, 86 flag, optional stock.';
COMMENT ON TABLE public.exos_pos_payments IS
  'POS tenders (mig 20260929074000). NEVER card data: terminal_ref is an opaque processor reference. Card rows are server-only.';
COMMENT ON TABLE public.exos_pos_settlements IS
  'End-of-night POS settlement snapshots (mig 20260929074000); exos_pos_record_settlement writes them.';

-- ROLLBACK: DROP the eight exos_pos_* tables (CASCADE) and the exos_pos_*
-- functions. Nothing outside exos_pos_* is changed.
