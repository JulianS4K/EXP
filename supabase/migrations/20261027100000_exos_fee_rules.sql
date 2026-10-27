-- ============================================================================
-- Migration 20261027100000 — Exos: organizer fee rules (passed on or absorbed)
--
-- Touches:  W: TABLE exos_fee_rules, exos_event_fee_settings, exos_order_fees (new)
--              COLUMN exos_checkout_sessions.fee_breakdown (new)
--              VIEW exos_effective_fee_rules (new, service_role only)
--              VIEW exos_public_fee_rules (new, anon: published events'
--                       passed-on rules; exos_public_tiers / _addons unchanged)
--              FUNCTION exos_tier_passed_on_fees, exos_addon_passed_on_fees (new)
--              FUNCTION exos_fee_unit_cents, exos_fees_unit_total_cents,
--                       exos_all_in_unit_cents (new, pure)
--              FUNCTION exos_record_order_fees, exos_tg_checkout_fees,
--                       _exos_tg_fee_rules_scope (new)
--              FUNCTION exos_receipt_html, exos_invoice_document (replaced:
--                       "includes ... fee" lines; everything else unchanged)
--           R: exos_events, exos_ticket_tiers, exos_event_addons,
--              exos_price_disclosure_lines
-- Pre-reqs: 20261014160000 (latest exos_public_tiers), 20260924211840 (latest
--           exos_public_addons; neither view is redefined here),
--           20260926070000 (price disclosure),
--           20260929071000 (latest exos_receipt_html), 20261001100000
--           (exos_invoice_document)
--
-- Organizers (and venues) define fee rules: "$2 facility fee per ticket", "3%
-- service charge", "$1.50 per order". At org level (every event inherits them)
-- and per event (an event can opt out of the org's rules, all or some). A rule
-- is either:
--   * passed_on: the buyer pays it, FOLDED INTO THE ALL-IN PRICE (operator
--     decision 2026-09-24, NY ACAL 25.07 + FTC fee rule). No buyer fee line at
--     checkout; the storefront, the "from" prices, the feeds and the Stripe
--     charge all include it, through the shared price functions
--     (_shared/fees.ts + _shared/pricing.ts, mirrored in src/lib). Receipts
--     and invoices say "includes $2.00 facility fee".
--   * absorbed: the organizer pays it out of revenue; the buyer price doesn't
--     change. Recorded per order for settlements / P&L.
--
-- Passed-on fees are per ticket (or per add-on unit, when the rule says so):
-- an all-in UNIT price can't carry a per-order amount, so per-order rules are
-- absorbed only (CHECK below). Fees never apply to a $0 unit. A passed-on fee
-- is taxable unless the rule says otherwise (taxable, default true): exclusive
-- tax is computed on price + taxable fees, per unit, as checkout always has.
--
-- This is NOT the Exos platform fee (_shared/platformFee.ts), which is
-- unchanged.
--
-- Records: exos-checkout prices the order with the shared functions, stores
-- every fee line (passed on and absorbed) on the session (fee_breakdown
-- jsonb) and each line's passed-on fees in the price-disclosure record
-- (fee_cents). When the session turns 'fulfilled', a trigger copies the lines
-- into exos_order_fees (the table settlements read). A session without a
-- snapshot (created before this deploy) gets its absorbed fees computed from
-- the current rules and the price-disclosure lines.
--
-- Who can do what: owners and managers write rules and event settings;
-- finance reads them and the per-order fees; nobody else sees anything.
-- Buyers see only the passed-on rules of published events (name + amount,
-- exos_public_fee_rules), which their prices already include.
--
-- Additive, re-run safe. Prod apply needs operator OK.
-- ROLLBACK: restore exos_receipt_html (20260929071000) and
--   exos_invoice_document (20261001100000), then DROP the trigger
--   exos_checkout_fees, the functions, view and tables above and
--   exos_checkout_sessions.fee_breakdown.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. Rules: org level (event_id NULL) or event level.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.exos_fee_rules (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id            uuid NOT NULL,
  event_id          uuid REFERENCES public.exos_events (id) ON DELETE CASCADE,
  name              text NOT NULL CHECK (length(btrim(name)) BETWEEN 1 AND 60),
  -- Who the money is for, a label for reports: 'org', 'venue', 'promoter', ...
  recipient         text NOT NULL DEFAULT 'org' CHECK (length(btrim(recipient)) BETWEEN 1 AND 40),
  kind              text NOT NULL CHECK (kind IN ('passed_on', 'absorbed')),
  calc              text NOT NULL CHECK (calc IN ('percent', 'fixed')),
  -- percent: of the unit price (per ticket) or of the order's base (per order).
  percent           numeric(6,3) CHECK (percent IS NULL OR (percent >= 0 AND percent <= 100)),
  -- fixed: minor units of the event's currency.
  amount_cents      integer CHECK (amount_cents IS NULL OR (amount_cents >= 0 AND amount_cents <= 10000000)),
  -- Optional ceiling on a percent fee (per unit, or per order).
  cap_cents         integer CHECK (cap_cents IS NULL OR cap_cents >= 0),
  per               text NOT NULL DEFAULT 'ticket' CHECK (per IN ('ticket', 'order')),
  taxable           boolean NOT NULL DEFAULT true,
  applies_to_addons boolean NOT NULL DEFAULT false,
  -- Event rules only: the tiers it applies to (NULL = every tier).
  tier_ids          uuid[],
  active            boolean NOT NULL DEFAULT true,
  sort_order        integer NOT NULL DEFAULT 0,
  created_by        uuid,
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT exos_fee_rules_amount CHECK (
    (calc = 'percent' AND percent IS NOT NULL AND amount_cents IS NULL)
    OR (calc = 'fixed' AND amount_cents IS NOT NULL AND percent IS NULL AND cap_cents IS NULL)),
  -- An all-in unit price can't hold a per-order amount: per-order fees are absorbed.
  CONSTRAINT exos_fee_rules_order_absorbed CHECK (per = 'ticket' OR kind = 'absorbed'),
  CONSTRAINT exos_fee_rules_tiers_event CHECK (tier_ids IS NULL OR (event_id IS NOT NULL AND cardinality(tier_ids) BETWEEN 1 AND 100))
);
COMMENT ON TABLE public.exos_fee_rules IS
  'Organizer fee rules (mig 20261027100000, docs/fees.md): org level (event_id NULL) or per event; passed_on (inside the all-in price) or absorbed (paid by the organizer).';
CREATE INDEX IF NOT EXISTS exos_fee_rules_org_idx ON public.exos_fee_rules (org_id) WHERE event_id IS NULL;
CREATE INDEX IF NOT EXISTS exos_fee_rules_event_idx ON public.exos_fee_rules (event_id) WHERE event_id IS NOT NULL;

-- Per-event switches: inherit the org's rules (default) or not, and which org
-- rules to skip when inheriting.
CREATE TABLE IF NOT EXISTS public.exos_event_fee_settings (
  event_id             uuid PRIMARY KEY REFERENCES public.exos_events (id) ON DELETE CASCADE,
  org_id               uuid NOT NULL,
  inherit_org_rules    boolean NOT NULL DEFAULT true,
  skipped_org_rule_ids uuid[] NOT NULL DEFAULT '{}' CHECK (cardinality(skipped_org_rule_ids) <= 100),
  updated_at           timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE public.exos_event_fee_settings IS
  'Per-event fee switches (mig 20261027100000): inherit the org''s fee rules or not, and org rules to skip.';

DROP TRIGGER IF EXISTS exos_fee_rules_touch ON public.exos_fee_rules;
CREATE TRIGGER exos_fee_rules_touch BEFORE UPDATE ON public.exos_fee_rules
  FOR EACH ROW EXECUTE FUNCTION public.exos_touch_updated_at();
DROP TRIGGER IF EXISTS exos_event_fee_settings_touch ON public.exos_event_fee_settings;
CREATE TRIGGER exos_event_fee_settings_touch BEFORE UPDATE ON public.exos_event_fee_settings
  FOR EACH ROW EXECUTE FUNCTION public.exos_touch_updated_at();

-- An event row's org_id is the event's org (so RLS on org_id is RLS on the
-- event), a rule can't move between orgs or events, and a scope holds at most
-- 25 rules.
CREATE OR REPLACE FUNCTION public._exos_tg_fee_rules_scope()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_org uuid;
  v_n   int;
BEGIN
  IF NEW.event_id IS NOT NULL THEN
    SELECT org_id INTO v_org FROM public.exos_events WHERE id = NEW.event_id;
    IF v_org IS NULL THEN
      RAISE EXCEPTION 'fee rules: event % not found', NEW.event_id USING ERRCODE = '23503';
    END IF;
    IF NEW.org_id IS DISTINCT FROM v_org THEN
      RAISE EXCEPTION 'fee rules: the event belongs to another organization' USING ERRCODE = '42501';
    END IF;
  END IF;
  IF TG_OP = 'UPDATE' AND (NEW.org_id IS DISTINCT FROM OLD.org_id OR NEW.event_id IS DISTINCT FROM OLD.event_id) THEN
    RAISE EXCEPTION 'fee rules: a rule can''t move to another organization or event' USING ERRCODE = '42501';
  END IF;
  IF TG_TABLE_NAME = 'exos_fee_rules' THEN
    NEW.name := btrim(NEW.name);
    NEW.recipient := lower(btrim(NEW.recipient));
    IF TG_OP = 'INSERT' THEN
      SELECT count(*) INTO v_n FROM public.exos_fee_rules
       WHERE org_id = NEW.org_id AND event_id IS NOT DISTINCT FROM NEW.event_id;
      IF v_n >= 25 THEN
        RAISE EXCEPTION 'fee rules: at most 25 rules per organization or event' USING ERRCODE = '22023';
      END IF;
      NEW.created_by := coalesce(NEW.created_by, auth.uid());
    END IF;
  END IF;
  RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION public._exos_tg_fee_rules_scope() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS exos_fee_rules_scope ON public.exos_fee_rules;
CREATE TRIGGER exos_fee_rules_scope BEFORE INSERT OR UPDATE ON public.exos_fee_rules
  FOR EACH ROW EXECUTE FUNCTION public._exos_tg_fee_rules_scope();
DROP TRIGGER IF EXISTS exos_event_fee_settings_scope ON public.exos_event_fee_settings;
CREATE TRIGGER exos_event_fee_settings_scope BEFORE INSERT OR UPDATE ON public.exos_event_fee_settings
  FOR EACH ROW EXECUTE FUNCTION public._exos_tg_fee_rules_scope();

-- RLS: owner / manager write; finance reads too; nobody else.
ALTER TABLE public.exos_fee_rules ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.exos_event_fee_settings ENABLE ROW LEVEL SECURITY;
DO $p$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['exos_fee_rules', 'exos_event_fee_settings'] LOOP
    EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I', t || '_sel', t);
    EXECUTE format($f$CREATE POLICY %I ON public.%I FOR SELECT TO authenticated
      USING (public.exos_is_admin() OR public.exos_has_org_role(org_id, ARRAY['owner','manager','finance']))$f$, t || '_sel', t);
    EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I', t || '_ins', t);
    EXECUTE format($f$CREATE POLICY %I ON public.%I FOR INSERT TO authenticated
      WITH CHECK (public.exos_is_admin() OR public.exos_has_org_role(org_id, ARRAY['owner','manager']))$f$, t || '_ins', t);
    EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I', t || '_upd', t);
    EXECUTE format($f$CREATE POLICY %I ON public.%I FOR UPDATE TO authenticated
      USING (public.exos_is_admin() OR public.exos_has_org_role(org_id, ARRAY['owner','manager']))
      WITH CHECK (public.exos_is_admin() OR public.exos_has_org_role(org_id, ARRAY['owner','manager']))$f$, t || '_upd', t);
    EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I', t || '_del', t);
    EXECUTE format($f$CREATE POLICY %I ON public.%I FOR DELETE TO authenticated
      USING (public.exos_is_admin() OR public.exos_has_org_role(org_id, ARRAY['owner','manager']))$f$, t || '_del', t);
    EXECUTE format('REVOKE ALL ON public.%I FROM PUBLIC, anon, authenticated', t);
    EXECUTE format('GRANT SELECT, INSERT, UPDATE, DELETE ON public.%I TO authenticated', t);
    EXECUTE format('GRANT ALL ON public.%I TO service_role', t);
  END LOOP;
END $p$;

-- ---------------------------------------------------------------------------
-- 2. The rules in effect for each event: the org's (unless the event opted
--    out of all or some of them), then the event's own; active only; at most
--    10. Owner-run view, service role only (exos-checkout reads it). The
--    public views below read it as their owner, so anon needs no grant.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW public.exos_effective_fee_rules AS
  SELECT e.id AS event_id, r.id AS rule_id, r.org_id, r.event_id AS rule_event_id,
         r.name, r.recipient, r.kind, r.calc, r.percent, r.amount_cents, r.cap_cents,
         r.per, r.taxable, r.applies_to_addons, r.tier_ids, r.rank
    FROM public.exos_events e
    LEFT JOIN public.exos_event_fee_settings s ON s.event_id = e.id
    JOIN LATERAL (
      SELECT f.*, row_number() OVER (ORDER BY (f.event_id IS NOT NULL), f.sort_order, f.created_at, f.id)::int AS rank
        FROM public.exos_fee_rules f
       WHERE f.active AND f.org_id = e.org_id
         AND (f.event_id = e.id
              OR (f.event_id IS NULL AND coalesce(s.inherit_org_rules, true)
                  AND NOT (f.id = ANY (coalesce(s.skipped_org_rule_ids, '{}'::uuid[])))))
    ) r ON r.rank <= 10;
COMMENT ON VIEW public.exos_effective_fee_rules IS
  'Fee rules in effect per event (org rules unless opted out, then event rules; active; max 10). Service role only. mig 20261027100000.';
REVOKE ALL ON public.exos_effective_fee_rules FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.exos_effective_fee_rules TO service_role;

-- ---------------------------------------------------------------------------
-- 3. Pure maths, mirrored by _shared/fees.ts + _shared/pricing.ts (and
--    src/lib). A fee rule as jsonb: {calc, percent, amount_cents, cap_cents,
--    taxable}. Fees never apply to a $0 unit; percent is half-up to a cent.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.exos_fee_unit_cents(p_unit_cents integer, p_rule jsonb)
RETURNS integer
LANGUAGE sql IMMUTABLE
SET search_path = public, pg_temp
AS $$
  SELECT CASE
    WHEN coalesce(p_unit_cents, 0) <= 0 OR p_rule IS NULL THEN 0
    WHEN p_rule->>'calc' = 'percent' THEN
      least(
        round(p_unit_cents * least(greatest(coalesce(round((p_rule->>'percent')::numeric, 3), 0), 0), 100) / 100)::int,
        coalesce(nullif(p_rule->>'cap_cents', '')::int, 2147483647))
    WHEN p_rule->>'calc' = 'fixed' THEN greatest(coalesce(round((p_rule->>'amount_cents')::numeric)::int, 0), 0)
    ELSE 0
  END
$$;
REVOKE ALL ON FUNCTION public.exos_fee_unit_cents(integer, jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.exos_fee_unit_cents(integer, jsonb) TO anon, authenticated, service_role;

-- Sum of a unit's passed-on fees; p_taxable_only: only the taxable ones.
CREATE OR REPLACE FUNCTION public.exos_fees_unit_total_cents(p_unit_cents integer, p_fees jsonb, p_taxable_only boolean DEFAULT false)
RETURNS integer
LANGUAGE sql IMMUTABLE
SET search_path = public, pg_temp
AS $$
  SELECT coalesce(sum(public.exos_fee_unit_cents(p_unit_cents, f)), 0)::int
    FROM jsonb_array_elements(CASE WHEN jsonb_typeof(p_fees) = 'array' THEN p_fees ELSE '[]'::jsonb END) f
   WHERE NOT p_taxable_only OR coalesce((f->>'taxable')::boolean, true)
$$;
REVOKE ALL ON FUNCTION public.exos_fees_unit_total_cents(integer, jsonb, boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.exos_fees_unit_total_cents(integer, jsonb, boolean) TO anon, authenticated, service_role;

-- All-in unit price: price + passed-on fees + exclusive tax on price + taxable fees.
CREATE OR REPLACE FUNCTION public.exos_all_in_unit_cents(p_unit_cents integer, p_exclusive_tax_percent numeric, p_fees jsonb DEFAULT '[]'::jsonb)
RETURNS integer
LANGUAGE sql IMMUTABLE
SET search_path = public, pg_temp
AS $$
  SELECT p_unit_cents
       + public.exos_fees_unit_total_cents(p_unit_cents, p_fees)
       + CASE WHEN coalesce(p_exclusive_tax_percent, 0) <= 0 THEN 0
              ELSE round((p_unit_cents + public.exos_fees_unit_total_cents(p_unit_cents, p_fees, true))
                         * p_exclusive_tax_percent / 100)::int END
$$;
REVOKE ALL ON FUNCTION public.exos_all_in_unit_cents(integer, numeric, jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.exos_all_in_unit_cents(integer, numeric, jsonb) TO anon, authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 4. Public price data: the passed-on fee rules of every published event, as
--    the buyer's price includes them. The storefront, the feeds and
--    exos-checkout pick a tier's / add-on's rules from this list
--    (tierPassedOnFees / addonPassedOnFees, _shared/fees.ts) and fold them
--    into the all-in price with the same function (allInCents).
--
--    A view of its own rather than a column on exos_public_tiers /
--    exos_public_addons: those keep their columns (an appended column would
--    break the replay of the migrations that define them, CREATE OR REPLACE
--    VIEW can't drop one), and a hidden tier a voucher unlocks
--    (exos_voucher_tier) prices from the same list.
--
--    Owner-run (it reads exos_effective_fee_rules, service role only), so it
--    filters itself: published events, passed-on per-ticket rules, and only
--    what the buyer's price needs. tier_ids can name a hidden tier (a rule for
--    a voucher-only tier); a tier id alone unlocks nothing.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW public.exos_public_fee_rules
WITH (security_barrier = true)
AS
SELECT f.event_id, f.rule_id AS id, f.name, f.kind, f.per, f.calc, f.percent, f.amount_cents,
       f.cap_cents, f.taxable, f.applies_to_addons, f.tier_ids, f.rank
  FROM public.exos_effective_fee_rules f
  JOIN public.exos_events e ON e.id = f.event_id
 WHERE e.status = 'published' AND f.kind = 'passed_on' AND f.per = 'ticket';
COMMENT ON VIEW public.exos_public_fee_rules IS
  'Passed-on fee rules inside the all-in prices of published events (pick per tier / add-on with _shared/fees.ts). mig 20261027100000.';
REVOKE ALL ON public.exos_public_fee_rules FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.exos_public_fee_rules TO anon, authenticated, service_role;

-- The same pick in SQL (tests, reports): one tier's / add-on's passed-on fee
-- rules as the jsonb array exos_all_in_unit_cents takes. Internal.
CREATE OR REPLACE FUNCTION public.exos_tier_passed_on_fees(p_tier_id uuid)
RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT coalesce((
    SELECT jsonb_agg(jsonb_build_object(
             'id', f.rule_id, 'name', f.name, 'calc', f.calc, 'percent', f.percent,
             'amount_cents', f.amount_cents, 'cap_cents', f.cap_cents, 'taxable', f.taxable)
             ORDER BY f.rank)
      FROM public.exos_ticket_tiers t
      JOIN public.exos_effective_fee_rules f ON f.event_id = t.event_id
     WHERE t.id = p_tier_id AND f.kind = 'passed_on' AND f.per = 'ticket'
       AND (f.tier_ids IS NULL OR t.id = ANY (f.tier_ids))
  ), '[]'::jsonb)
$$;
REVOKE ALL ON FUNCTION public.exos_tier_passed_on_fees(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_tier_passed_on_fees(uuid) TO service_role;

CREATE OR REPLACE FUNCTION public.exos_addon_passed_on_fees(p_addon_id uuid)
RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT coalesce((
    SELECT jsonb_agg(jsonb_build_object(
             'id', f.rule_id, 'name', f.name, 'calc', f.calc, 'percent', f.percent,
             'amount_cents', f.amount_cents, 'cap_cents', f.cap_cents, 'taxable', f.taxable)
             ORDER BY f.rank)
      FROM public.exos_event_addons a
      JOIN public.exos_effective_fee_rules f ON f.event_id = a.event_id
     WHERE a.id = p_addon_id AND f.kind = 'passed_on' AND f.per = 'ticket' AND f.applies_to_addons
  ), '[]'::jsonb)
$$;
REVOKE ALL ON FUNCTION public.exos_addon_passed_on_fees(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_addon_passed_on_fees(uuid) TO service_role;

-- ---------------------------------------------------------------------------
-- 5. Per-order fees: what each order paid (passed on) or cost the organizer
--    (absorbed), per rule and item. Settlements / P&L read this.
-- ---------------------------------------------------------------------------
ALTER TABLE public.exos_checkout_sessions ADD COLUMN IF NOT EXISTS fee_breakdown jsonb;
COMMENT ON COLUMN public.exos_checkout_sessions.fee_breakdown IS
  'Fee lines priced by exos-checkout (passed on + absorbed), copied to exos_order_fees on fulfillment. mig 20261027100000.';

CREATE TABLE IF NOT EXISTS public.exos_order_fees (
  id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  session_id    text NOT NULL REFERENCES public.exos_checkout_sessions (session_id) ON DELETE CASCADE,
  org_id        uuid NOT NULL,
  event_id      uuid NOT NULL,
  rule_id       uuid,
  rule_name     text NOT NULL CHECK (length(rule_name) <= 60),
  kind          text NOT NULL CHECK (kind IN ('passed_on', 'absorbed')),
  recipient     text NOT NULL DEFAULT 'org' CHECK (length(recipient) <= 40),
  calc          text NOT NULL CHECK (calc IN ('percent', 'fixed')),
  percent       numeric(6,3),
  per           text NOT NULL CHECK (per IN ('ticket', 'order')),
  -- What the amount is on: the tickets, an add-on, or the whole order.
  item_kind     text NOT NULL CHECK (item_kind IN ('ticket', 'addon', 'order')),
  item_id       uuid,
  unit_cents    integer NOT NULL CHECK (unit_cents >= 0),
  quantity      integer NOT NULL CHECK (quantity BETWEEN 1 AND 50),
  amount_cents  integer NOT NULL CHECK (amount_cents >= 0 AND amount_cents = unit_cents * quantity),
  taxable       boolean NOT NULL DEFAULT false,
  currency      text NOT NULL DEFAULT 'usd',
  source        text NOT NULL DEFAULT 'checkout' CHECK (source IN ('checkout', 'rules')),
  created_at    timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE public.exos_order_fees IS
  'Fees per order, rule and item (mig 20261027100000): passed_on = paid by the buyer inside the all-in price; absorbed = paid by the organizer. source: checkout snapshot, or rules (computed at fulfillment for sessions without one).';
CREATE UNIQUE INDEX IF NOT EXISTS exos_order_fees_line_uq
  ON public.exos_order_fees (session_id, coalesce(rule_id, '00000000-0000-0000-0000-000000000000'::uuid), item_kind,
                             coalesce(item_id, '00000000-0000-0000-0000-000000000000'::uuid));
CREATE INDEX IF NOT EXISTS exos_order_fees_event_idx ON public.exos_order_fees (event_id, kind);
CREATE INDEX IF NOT EXISTS exos_order_fees_org_idx ON public.exos_order_fees (org_id, created_at);

ALTER TABLE public.exos_order_fees ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS exos_order_fees_sel ON public.exos_order_fees;
CREATE POLICY exos_order_fees_sel ON public.exos_order_fees FOR SELECT TO authenticated
  USING (public.exos_is_admin() OR public.exos_has_org_role(org_id, ARRAY['owner','manager','finance']));
REVOKE ALL ON public.exos_order_fees FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.exos_order_fees TO authenticated;
GRANT ALL ON public.exos_order_fees TO service_role;
DO $$
DECLARE r text; t text;
BEGIN
  FOREACH r IN ARRAY ARRAY['coworker_readonly','analyst_ro'] LOOP
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = r) THEN
      FOREACH t IN ARRAY ARRAY['exos_fee_rules','exos_event_fee_settings','exos_order_fees'] LOOP
        EXECUTE format('REVOKE ALL ON public.%I FROM %I', t, r);
      END LOOP;
    END IF;
  END LOOP;
END $$;

-- Record a fulfilled session's fees. Idempotent (a second call adds nothing).
-- From the checkout snapshot when there is one; otherwise the absorbed fees
-- from the current rules and the price-disclosure lines (passed-on fees can't
-- have been charged without a snapshot). Returns the number of lines added.
CREATE OR REPLACE FUNCTION public.exos_record_order_fees(p_session_id text)
RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  s      public.exos_checkout_sessions%ROWTYPE;
  v_n    int := 0;
  v_base int;
  v_add  int;
  r      record;
  l      record;
  v_amt  int;
BEGIN
  SELECT * INTO s FROM public.exos_checkout_sessions WHERE session_id = p_session_id;
  IF NOT FOUND OR s.status <> 'fulfilled' THEN
    RETURN 0;
  END IF;
  IF EXISTS (SELECT 1 FROM public.exos_order_fees WHERE session_id = p_session_id) THEN
    RETURN 0;
  END IF;

  IF jsonb_typeof(s.fee_breakdown) = 'array' THEN
    INSERT INTO public.exos_order_fees (session_id, org_id, event_id, rule_id, rule_name, kind, recipient,
      calc, percent, per, item_kind, item_id, unit_cents, quantity, amount_cents, taxable, currency, source)
    SELECT p_session_id, s.org_id, s.event_id,
           CASE WHEN f->>'rule_id' ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
                THEN (f->>'rule_id')::uuid END,
           left(coalesce(nullif(btrim(f->>'name'), ''), 'Fee'), 60),
           f->>'kind', left(coalesce(nullif(btrim(f->>'recipient'), ''), 'org'), 40),
           f->>'calc', round((f->>'percent')::numeric, 3), f->>'per', f->>'item_kind',
           CASE WHEN f->>'item_id' ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
                THEN (f->>'item_id')::uuid END,
           (f->>'unit_cents')::int, (f->>'quantity')::int,
           (f->>'unit_cents')::int * (f->>'quantity')::int,
           coalesce((f->>'taxable')::boolean, false), lower(coalesce(s.currency, 'usd')), 'checkout'
      FROM jsonb_array_elements(s.fee_breakdown) f
     WHERE f->>'kind' IN ('passed_on', 'absorbed') AND f->>'calc' IN ('percent', 'fixed')
       AND f->>'per' IN ('ticket', 'order') AND f->>'item_kind' IN ('ticket', 'addon', 'order')
       AND (f->>'unit_cents') ~ '^[0-9]{1,9}$' AND (f->>'quantity') ~ '^[0-9]{1,2}$'
       AND (f->>'unit_cents')::int > 0 AND (f->>'quantity')::int BETWEEN 1 AND 50
    ON CONFLICT DO NOTHING;
    GET DIAGNOSTICS v_n = ROW_COUNT;
    RETURN v_n;
  END IF;

  -- No snapshot: absorbed fees only, from what the buyer was shown.
  v_base := 0; v_add := 0;
  FOR l IN SELECT * FROM public.exos_price_disclosure_lines WHERE session_id = p_session_id LOOP
    IF l.kind = 'ticket' THEN v_base := v_base + l.face_unit_cents * l.quantity;
    ELSE v_add := v_add + l.face_unit_cents * l.quantity; END IF;
  END LOOP;
  FOR r IN SELECT * FROM public.exos_effective_fee_rules
            WHERE event_id = s.event_id AND kind = 'absorbed'
              AND (tier_ids IS NULL OR s.tier_id = ANY (tier_ids))
            ORDER BY rank LOOP
    IF r.per = 'ticket' THEN
      FOR l IN SELECT * FROM public.exos_price_disclosure_lines
                WHERE session_id = p_session_id AND (kind = 'ticket' OR r.applies_to_addons) ORDER BY line_no LOOP
        v_amt := public.exos_fee_unit_cents(l.face_unit_cents, to_jsonb(r));
        CONTINUE WHEN v_amt <= 0;
        INSERT INTO public.exos_order_fees (session_id, org_id, event_id, rule_id, rule_name, kind, recipient,
          calc, percent, per, item_kind, item_id, unit_cents, quantity, amount_cents, taxable, currency, source)
        VALUES (p_session_id, s.org_id, s.event_id, r.rule_id, r.name, 'absorbed', r.recipient,
          r.calc, r.percent, 'ticket', CASE WHEN l.kind = 'ticket' THEN 'ticket' ELSE 'addon' END, l.item_id,
          v_amt, l.quantity, v_amt * l.quantity, false, lower(coalesce(s.currency, 'usd')), 'rules')
        ON CONFLICT DO NOTHING;
        v_n := v_n + 1;
      END LOOP;
    ELSE
      v_amt := public.exos_fee_unit_cents(v_base + CASE WHEN r.applies_to_addons THEN v_add ELSE 0 END, to_jsonb(r));
      CONTINUE WHEN v_amt <= 0;
      INSERT INTO public.exos_order_fees (session_id, org_id, event_id, rule_id, rule_name, kind, recipient,
        calc, percent, per, item_kind, item_id, unit_cents, quantity, amount_cents, taxable, currency, source)
      VALUES (p_session_id, s.org_id, s.event_id, r.rule_id, r.name, 'absorbed', r.recipient,
        r.calc, r.percent, 'order', 'order', NULL, v_amt, 1, v_amt, false, lower(coalesce(s.currency, 'usd')), 'rules')
      ON CONFLICT DO NOTHING;
      v_n := v_n + 1;
    END IF;
  END LOOP;
  RETURN v_n;
END $$;
REVOKE ALL ON FUNCTION public.exos_record_order_fees(text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_record_order_fees(text) TO service_role;

-- On fulfillment. Never unwinds a paid fulfillment: a failure is a warning,
-- and exos_record_order_fees can be re-run for the session.
CREATE OR REPLACE FUNCTION public.exos_tg_checkout_fees()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF NEW.status = 'fulfilled' AND OLD.status IS DISTINCT FROM 'fulfilled' THEN
    BEGIN
      PERFORM public.exos_record_order_fees(NEW.session_id);
    EXCEPTION WHEN others THEN
      RAISE WARNING 'exos_tg_checkout_fees: session %: %', NEW.session_id, SQLERRM;
    END;
  END IF;
  RETURN NULL;
END $$;
REVOKE ALL ON FUNCTION public.exos_tg_checkout_fees() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS exos_checkout_fees ON public.exos_checkout_sessions;
CREATE TRIGGER exos_checkout_fees AFTER UPDATE OF status ON public.exos_checkout_sessions
  FOR EACH ROW EXECUTE FUNCTION public.exos_tg_checkout_fees();

-- ---------------------------------------------------------------------------
-- 6. Receipt mail (body of 20260929071000): unchanged, except an order with
--    passed-on fees says what its all-in prices include ("include 4.00
--    facility fee"). Read from the session's fee_breakdown, not
--    exos_order_fees: exos_fulfill_checkout builds the mail in the same
--    statement that marks the session fulfilled.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.exos_receipt_html(p_session_id text)
RETURNS text
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT coalesce((
    SELECT '<p>Paid: <strong>' || to_char(s.amount_cents / 100.0, 'FM999,999,990.00') || ' ' ||
           upper(coalesce(s.currency, 'usd')) || '</strong>' ||
           CASE WHEN coalesce(s.tax_cents, 0) > 0
                THEN ' (including ' || to_char(s.tax_cents / 100.0, 'FM999,999,990.00') || ' tax)' ELSE '' END ||
           '. Order reference: ' || public.exos_mail_escape(s.session_id) || '.</p>' ||
           coalesce((
             SELECT '<table style="border-collapse:collapse;font-size:14px">' ||
                    string_agg('<tr><td style="padding:2px 12px 2px 0">' || l.quantity || ' &times; ' ||
                               public.exos_mail_escape(coalesce(l.item_name, 'Ticket')) ||
                               '</td><td style="padding:2px 0;text-align:right">' ||
                               to_char(l.line_total_cents / 100.0, 'FM999,999,990.00') || '</td></tr>',
                               '' ORDER BY l.line_no) ||
                    '</table>'
               FROM public.exos_price_disclosure_lines l
              WHERE l.session_id = s.session_id), '') ||
           coalesce((
             SELECT '<p style="color:#666;font-size:13px">All-in price: the prices above include ' ||
                    string_agg(to_char(x.amount / 100.0, 'FM999,999,990.00') || ' ' ||
                               public.exos_mail_escape(lower(x.rule_name)), ', ' ORDER BY x.first_id) ||
                    CASE WHEN coalesce(s.tax_cents, 0) > 0 THEN ' and tax' ELSE '' END ||
                    '; nothing was added at checkout.</p>'
               FROM (SELECT left(coalesce(nullif(btrim(f.el->>'name'), ''), 'Fee'), 60) AS rule_name,
                            sum((f.el->>'amount_cents')::int) AS amount, min(f.ord) AS first_id
                       FROM jsonb_array_elements(CASE WHEN jsonb_typeof(s.fee_breakdown) = 'array'
                                                      THEN s.fee_breakdown ELSE '[]'::jsonb END)
                              WITH ORDINALITY AS f(el, ord)
                      WHERE f.el->>'kind' = 'passed_on' AND (f.el->>'amount_cents') ~ '^[0-9]{1,9}$'
                      GROUP BY 1) x
             HAVING count(*) > 0),
             '<p style="color:#666;font-size:13px">All-in price: no fees were added at checkout' ||
             CASE WHEN coalesce(s.tax_cents, 0) > 0 THEN ' and tax is included' ELSE '' END || '.</p>') ||
           CASE WHEN EXISTS (SELECT 1 FROM public.exos_tickets t
                              WHERE t.order_ref = s.session_id AND t.pending_transfer_id IS NOT NULL)
                THEN ''
                ELSE '<p><a href="{{app_url}}/my-tickets">View your tickets</a></p>' END
      FROM public.exos_checkout_sessions s
     WHERE s.session_id = p_session_id AND coalesce(s.amount_cents, 0) > 0), '');
$$;
REVOKE ALL ON FUNCTION public.exos_receipt_html(text) FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 7. Invoice / receipt document: unchanged, plus each line's fee_cents (from
--    the disclosure record) and a top-level `fees` list of the passed-on fees
--    the all-in prices include ([{name, recipient, amount_cents}]).
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
  v_fees   jsonb;
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
           'tax_name', r.name, 'tax_rate', r.rate_percent,
           'fee_cents', l.fee_cents)
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

  -- Passed-on fees inside the all-in prices (mig 20261027100000).
  SELECT coalesce(jsonb_agg(jsonb_build_object('name', x.rule_name, 'recipient', x.recipient, 'amount_cents', x.amount)
                            ORDER BY x.first_id), '[]'::jsonb)
    INTO v_fees
    FROM (SELECT f.rule_name, min(f.recipient) AS recipient, sum(f.amount_cents)::int AS amount, min(f.id) AS first_id
            FROM public.exos_order_fees f
           WHERE f.session_id = inv.session_id AND f.kind = 'passed_on'
           GROUP BY f.rule_name) x;

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
    'fees', v_fees,
    'credit_notes', v_notes,
    'viewer', CASE WHEN v_staff THEN 'org' ELSE 'buyer' END);
END $$;
REVOKE ALL ON FUNCTION public.exos_invoice_document(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_invoice_document(uuid) TO authenticated, service_role;
