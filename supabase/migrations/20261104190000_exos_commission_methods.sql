-- ============================================================================
-- Migration 20261104190000 — Exos: four ways to fund promoter commissions
--
-- Touches:  W: TABLE exos_org_commission_settings, exos_event_commission_settings,
--                 exos_commission_method_changes, exos_checkout_commission_plans,
--                 exos_commission_netting, exos_commission_transfers (new)
--              TABLE exos_promoters (+commission_method)
--              TABLE exos_promoter_commissions (+method, +method_source, +session_id)
--              TABLE exos_promoter_payouts (+source_session_id; via CHECK widened
--                 to 'split' and 'platform_fee')
--              TRIGGER exos_promoter_commissions_method (BEFORE INSERT),
--                 exos_promoter_commissions_gate (BEFORE UPDATE),
--                 exos_promoter_commissions_netting (AFTER UPDATE),
--                 exos_order_refunds_split_true_up, exos_checkout_sessions_split_dispute
--              FUNCTION exos_settle_promoter, exos_record_promoter_payout,
--                 exos_org_promoter_commissions, exos_promoter_by_token,
--                 exos_promoter_earnings (replaced, same signatures)
--              FUNCTION _exos_commission_pin, _exos_commission_resolve,
--                 _exos_commission_payable_at, _exos_org_promoter_stripe_needed,
--                 exos_commission_checkout_plan, exos_record_commission_plan,
--                 _exos_split_entitlement, _exos_split_true_up, _exos_split_plan_order,
--                 _exos_fee_plan_promoter, exos_commission_plan_due,
--                 exos_commission_record_charge, exos_ct_due, exos_ct_claim,
--                 exos_ct_lease_ok, exos_ct_mark, exos_ct_reconcile,
--                 exos_ct_lease_release, exos_ct_cancel,
--                 exos_get_commission_settings, exos_set_commission_settings,
--                 exos_set_event_commission_method, exos_set_promoter_commission_method,
--                 exos_commission_balances, exos_commission_payable (new)
--              CRON exos-commission-transfers-15min (created inactive)
--           R: exos_events, exos_tickets, exos_checkout_sessions, exos_order_payments,
--              exos_order_refunds, exos_refund_requests, exos_org_secrets,
--              exos_promoter_stripe_accounts, exos_org_promoter_payouts
-- Pre-reqs: 20261102150000 (the promoter wedge: settle, leases, payout columns),
--           20260926020000 (commission ledger), 20261031220000 (processor),
--           20260929131000 (fee columns), 20260926050000 (party size)
--
-- Why: the operator wants the money for a promoter's commission to come from
-- one of four places, chosen case by case (docs/payouts.md "Commission
-- methods", docs/organizer-guide.md).
--
--   A. clawback       the promoter wedge, unchanged: at settle time the
--                     commission is reversed out of the organizer's
--                     destination-charge transfers and sent to the promoter.
--   B. split_at_sale  separate charges and transfers: the charge lands on the
--                     platform (no transfer_data) with a transfer_group per
--                     order; after the holdback Exos transfers the organizer's
--                     share and each promoter's commission from that charge
--                     (source_transaction). EXOS_SPLIT_AT_SALE=on + the owner's
--                     org switch, default off.
--   C. platform_fee   the commission rides inside the destination charge's
--                     application_fee_amount; after the holdback Exos transfers
--                     it from the platform balance to the promoter.
--                     EXOS_PLATFORM_FEE_COMMISSIONS=on, default off.
--   D. manual         the ledger only (Venmo, cash). The default.
--
-- Choosing. A per-org default (exos_org_commission_settings), a per-event
-- override and a per-promoter override (exos_promoters.commission_method).
-- Most specific wins: promoter, then event, then org, then 'manual'. A
-- method whose switch is off falls back to 'manual' at checkout (recorded as
-- method_source 'fallback'), so a sale is never charged a way Exos can't pay.
--
-- Locking. An event's method is pinned (locked_method) by its first paid
-- ticket, and before any org default change, so later changes never move an
-- event that has sold. Changing a sold event's method needs
-- p_future_sales_only = true and affects only later sales: every accrual
-- records the method it used (method, method_source), checkout records it per
-- order (exos_checkout_commission_plans), and a recorded method is never
-- rewritten.
--
-- Holdback. A commission is payable from coalesce(ends_at, starts_at + 12 h,
-- accrued_at) + holdback_days (org setting 0..30, default 3). Enforced on the
-- row (exos_promoter_commissions_gate) for every Exos-moved payout (split,
-- platform_fee) and, once an org has saved commission settings, for its
-- manual and clawback payouts too. Orgs that never saved them keep today's
-- behaviour, so nothing changes for existing organizers until they opt in.
--
-- Netting. A sale refunded after it was paid becomes a negative line in
-- exos_commission_netting (a mirror of the commission row, kept by trigger),
-- taken off that promoter's next payout by the party that funded it:
-- organizer-funded lines (manual, clawback) by exos_settle_promoter /
-- exos_record_promoter_payout, platform-funded ones (split_at_sale,
-- platform_fee) by the Exos transfers. Never reversed from the promoter's
-- account. A line still open after netting_alert_days (default 30) is shown
-- to the organizer as overdue. Split orders also net the organizer: a refund
-- after the organizer's share went out is a true-up line (_exos_split_true_up)
-- taken off the organizer's next split transfer.
--
-- Money. Integer cents; a ledger row for every movement (commission rows,
-- payouts, netting lines, exos_commission_transfers). Every Stripe transfer
-- for B and C is one exos_commission_transfers row with its own deterministic
-- idempotency key (exos-ct:<id>), lease, fence and reconcile: the same rules
-- and timing as the wedge's clawback sends (6-minute lease, 10-minute wait
-- before a reconcile or cancel, 'sent' always wins), which stay untouched.
--
-- Security review (2026-11-04), for the Exos-funded methods B and C:
--   * the holdback is frozen at the sale (payable_at on the plan and the
--     accrual), never earlier than the event's start at the sale; editing the
--     event can only push it out; a platform minimum the org can't lower;
--   * Exos-funded commissions are capped (exos_funded_commission_max_bps, 30%
--     of the ticket's net to the organizer) unless a platform admin approves
--     more (exos_commission_cap_approvals); sends re-check the holdback, open
--     disputes and refunds in flight (_exos_ct_hold);
--   * organizer refunds of split orders reverse the organizer's part from
--     their transfer first, or are refused (section 14); a platform_fee
--     refund after the commission went out keeps the fee; true-ups are the
--     fallback only, with an alert and a debt cap (split_org_debt_cap_cents).
--
-- Additive, re-run safe. Prod apply, the cron and deploys need operator OK.
-- ============================================================================

-- ===========================================================================
-- 1. Settings: org default + holdback, event override + lock, promoter
--    override, and a log of every change.
-- ===========================================================================
CREATE TABLE IF NOT EXISTS public.exos_org_commission_settings (
  org_id                uuid PRIMARY KEY REFERENCES public.exos_orgs (id) ON DELETE CASCADE,
  default_method        text NOT NULL DEFAULT 'manual'
                          CHECK (default_method IN ('clawback', 'split_at_sale', 'platform_fee', 'manual')),
  holdback_days         integer NOT NULL DEFAULT 3 CHECK (holdback_days BETWEEN 0 AND 30),
  split_at_sale_enabled boolean NOT NULL DEFAULT false,
  netting_alert_days    integer NOT NULL DEFAULT 30 CHECK (netting_alert_days BETWEEN 1 AND 365),
  updated_by            uuid REFERENCES auth.users (id) ON DELETE SET NULL,
  created_at            timestamptz NOT NULL DEFAULT now(),
  updated_at            timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.exos_event_commission_settings (
  event_id      uuid PRIMARY KEY REFERENCES public.exos_events (id) ON DELETE CASCADE,
  org_id        uuid NOT NULL REFERENCES public.exos_orgs (id) ON DELETE CASCADE,
  -- The override (NULL: the org default).
  method        text CHECK (method IS NULL OR method IN ('clawback', 'split_at_sale', 'platform_fee', 'manual')),
  -- Pinned by the first paid ticket (or before an org default change).
  locked_method text CHECK (locked_method IS NULL OR locked_method IN ('clawback', 'split_at_sale', 'platform_fee', 'manual')),
  locked_at     timestamptz,
  updated_by    uuid REFERENCES auth.users (id) ON DELETE SET NULL,
  created_at    timestamptz NOT NULL DEFAULT now(),
  updated_at    timestamptz NOT NULL DEFAULT now(),
  CHECK ((locked_method IS NULL) = (locked_at IS NULL))
);
CREATE INDEX IF NOT EXISTS exos_event_commission_settings_org_idx ON public.exos_event_commission_settings (org_id);

ALTER TABLE public.exos_promoters ADD COLUMN IF NOT EXISTS commission_method text;
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'exos_promoters_commission_method_chk') THEN
    ALTER TABLE public.exos_promoters ADD CONSTRAINT exos_promoters_commission_method_chk
      CHECK (commission_method IS NULL OR commission_method IN ('clawback', 'split_at_sale', 'platform_fee', 'manual'));
  END IF;
END $$;
COMMENT ON COLUMN public.exos_promoters.commission_method IS
  'Per-promoter commission method override (NULL: the event''s, then the org''s). mig 20261104190000.';

CREATE TABLE IF NOT EXISTS public.exos_commission_method_changes (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id      uuid NOT NULL REFERENCES public.exos_orgs (id) ON DELETE CASCADE,
  scope       text NOT NULL CHECK (scope IN ('org', 'event', 'promoter', 'holdback', 'split_switch')),
  event_id    uuid REFERENCES public.exos_events (id) ON DELETE CASCADE,
  promoter_id uuid REFERENCES public.exos_promoters (id) ON DELETE CASCADE,
  old_value   text,
  new_value   text,
  changed_by  uuid REFERENCES auth.users (id) ON DELETE SET NULL,
  changed_at  timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS exos_commission_method_changes_org_idx ON public.exos_commission_method_changes (org_id, changed_at DESC);

-- ===========================================================================
-- 2. Resolving a method.
-- ===========================================================================
-- Pin an event's method once it has sold a paid ticket (idempotent; the first
-- pin wins). Returns the locked method, or NULL while nothing has sold.
CREATE OR REPLACE FUNCTION public._exos_commission_pin(p_event_id uuid)
RETURNS text
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  s     public.exos_event_commission_settings%ROWTYPE;
  v_org uuid;
  v     text;
BEGIN
  SELECT * INTO s FROM public.exos_event_commission_settings WHERE event_id = p_event_id;
  IF s.locked_method IS NOT NULL THEN RETURN s.locked_method; END IF;
  IF NOT EXISTS (SELECT 1 FROM public.exos_tickets t WHERE t.event_id = p_event_id AND coalesce(t.price_paid, 0) > 0) THEN
    RETURN NULL;
  END IF;
  SELECT org_id INTO v_org FROM public.exos_events WHERE id = p_event_id;
  IF v_org IS NULL THEN RETURN NULL; END IF;
  v := coalesce(s.method, (SELECT default_method FROM public.exos_org_commission_settings WHERE org_id = v_org), 'manual');
  INSERT INTO public.exos_event_commission_settings AS x (event_id, org_id, locked_method, locked_at)
  VALUES (p_event_id, v_org, v, now())
  ON CONFLICT (event_id) DO UPDATE
    SET locked_method = coalesce(x.locked_method, EXCLUDED.locked_method),
        locked_at = coalesce(x.locked_at, EXCLUDED.locked_at)
  RETURNING locked_method INTO v;
  RETURN v;
END $$;
REVOKE ALL ON FUNCTION public._exos_commission_pin(uuid) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public._exos_commission_pin(uuid) TO service_role;

-- The method for a sale of p_promoter_id at p_event_id, and where it came
-- from: promoter > event (locked, else override) > org > 'manual'. Mirrors
-- src/lib/commissionMethods.ts resolveMethod.
CREATE OR REPLACE FUNCTION public._exos_commission_resolve(p_event_id uuid, p_promoter_id uuid, p_pin boolean DEFAULT false)
RETURNS TABLE (method text, source text)
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_pm  text;
  v_def text;
  s     public.exos_event_commission_settings%ROWTYPE;
BEGIN
  IF p_pin THEN PERFORM public._exos_commission_pin(p_event_id); END IF;
  IF p_promoter_id IS NOT NULL THEN
    SELECT p.commission_method INTO v_pm FROM public.exos_promoters p WHERE p.id = p_promoter_id;
  END IF;
  IF v_pm IS NOT NULL THEN
    method := v_pm; source := 'promoter'; RETURN NEXT; RETURN;
  END IF;
  SELECT * INTO s FROM public.exos_event_commission_settings WHERE event_id = p_event_id;
  IF s.locked_method IS NOT NULL THEN
    method := s.locked_method; source := 'event_locked';
  ELSIF s.method IS NOT NULL THEN
    method := s.method; source := 'event';
  ELSE
    SELECT o.default_method INTO v_def
      FROM public.exos_org_commission_settings o JOIN public.exos_events e ON e.org_id = o.org_id
     WHERE e.id = p_event_id;
    method := coalesce(v_def, 'manual'); source := CASE WHEN v_def IS NULL THEN 'default' ELSE 'org' END;
  END IF;
  RETURN NEXT;
END $$;
REVOKE ALL ON FUNCTION public._exos_commission_resolve(uuid, uuid, boolean) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public._exos_commission_resolve(uuid, uuid, boolean) TO service_role;

-- A platform rule (exos_platform_settings, a JSON number), else the default.
CREATE OR REPLACE FUNCTION public._exos_cm_setting_int(p_key text, p_default integer)
RETURNS integer
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT coalesce((SELECT CASE WHEN jsonb_typeof(value) = 'number' AND (value #>> '{}') ~ '^[0-9]{1,9}$'
                               THEN (value #>> '{}')::integer END
                     FROM public.exos_platform_settings WHERE key = p_key), p_default)
$$;
REVOKE ALL ON FUNCTION public._exos_cm_setting_int(text, integer) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public._exos_cm_setting_int(text, integer) TO service_role;

-- The holdback days for a method at an org: the org's (0..30, default 3);
-- for the Exos-funded methods never less than the platform minimum
-- (commission_min_holdback_days, default 3), which org staff can't lower.
CREATE OR REPLACE FUNCTION public._exos_commission_holdback_days(p_org_id uuid, p_method text)
RETURNS integer
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT CASE WHEN p_method IN ('split_at_sale', 'platform_fee')
              THEN greatest(coalesce(s.holdback_days, 3), public._exos_cm_setting_int('commission_min_holdback_days', 3))
              ELSE coalesce(s.holdback_days, 3) END
    FROM (SELECT 1) one
    LEFT JOIN public.exos_org_commission_settings s ON s.org_id = p_org_id
$$;
REVOKE ALL ON FUNCTION public._exos_commission_holdback_days(uuid, text) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public._exos_commission_holdback_days(uuid, text) TO service_role;

-- The payable time frozen at the sale (checkout plan, else the accrual):
-- the event's later of starts_at / ends_at as it is at that moment, plus the
-- holdback. Exos-funded methods also wait the holdback from the sale itself,
-- so an event dated in the past can't make a fresh sale payable at once.
-- Never earlier than the event's starts_at at the sale.
CREATE OR REPLACE FUNCTION public._exos_commission_frozen_payable(p_event_id uuid, p_method text)
RETURNS timestamptz
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT CASE WHEN p_method IN ('split_at_sale', 'platform_fee')
              THEN greatest(coalesce(greatest(e.starts_at, e.ends_at), now()), now())
              ELSE coalesce(greatest(e.starts_at, e.ends_at), now()) END
         + make_interval(days => public._exos_commission_holdback_days(e.org_id, p_method))
    FROM public.exos_events e
   WHERE e.id = p_event_id
$$;
REVOKE ALL ON FUNCTION public._exos_commission_frozen_payable(uuid, text) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public._exos_commission_frozen_payable(uuid, text) TO service_role;

-- When a commission becomes payable: the later of the time frozen at the
-- sale (p_frozen) and the event as it is now (later of starts_at / ends_at,
-- else the accrual, plus the holdback). Editing the event can push this out
-- (a reschedule), never bring it forward.
CREATE OR REPLACE FUNCTION public._exos_commission_payable_at(
  p_event_id uuid, p_accrued_at timestamptz, p_method text DEFAULT 'manual', p_frozen timestamptz DEFAULT NULL
) RETURNS timestamptz
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT greatest(
           p_frozen,
           coalesce(greatest(e.starts_at, e.ends_at), p_accrued_at, now())
             + make_interval(days => public._exos_commission_holdback_days(e.org_id, coalesce(p_method, 'manual'))))
    FROM public.exos_events e
   WHERE e.id = p_event_id
$$;
REVOKE ALL ON FUNCTION public._exos_commission_payable_at(uuid, timestamptz, text, timestamptz) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public._exos_commission_payable_at(uuid, timestamptz, text, timestamptz) TO service_role;

-- Do this org's promoters need a Stripe payout account? Yes when the owner
-- turned clawback transfers on, or any setting uses a platform-funded method.
CREATE OR REPLACE FUNCTION public._exos_org_promoter_stripe_needed(p_org_id uuid)
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT coalesce((SELECT stripe_transfers FROM public.exos_org_promoter_payouts WHERE org_id = p_org_id), false)
      OR EXISTS (SELECT 1 FROM public.exos_org_commission_settings
                  WHERE org_id = p_org_id AND default_method IN ('split_at_sale', 'platform_fee'))
      OR EXISTS (SELECT 1 FROM public.exos_event_commission_settings
                  WHERE org_id = p_org_id AND (method IN ('split_at_sale', 'platform_fee')
                                               OR locked_method IN ('split_at_sale', 'platform_fee')))
      OR EXISTS (SELECT 1 FROM public.exos_promoters
                  WHERE org_id = p_org_id AND commission_method IN ('split_at_sale', 'platform_fee'))
$$;
REVOKE ALL ON FUNCTION public._exos_org_promoter_stripe_needed(uuid) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public._exos_org_promoter_stripe_needed(uuid) TO service_role;

-- ===========================================================================
-- 3. Checkout: the plan for one order (service role: exos-checkout).
-- ===========================================================================
-- What checkout decided for an order. Service-role written, staff read; kept
-- off exos_checkout_sessions, which the buyer can read.
CREATE TABLE IF NOT EXISTS public.exos_checkout_commission_plans (
  session_id            text PRIMARY KEY REFERENCES public.exos_checkout_sessions (session_id) ON DELETE CASCADE,
  org_id                uuid NOT NULL REFERENCES public.exos_orgs (id) ON DELETE CASCADE,
  event_id              uuid NOT NULL REFERENCES public.exos_events (id) ON DELETE CASCADE,
  promoter_id           uuid REFERENCES public.exos_promoters (id) ON DELETE SET NULL,
  method                text NOT NULL CHECK (method IN ('clawback', 'split_at_sale', 'platform_fee', 'manual')),
  method_source         text NOT NULL CHECK (method_source IN ('promoter', 'event', 'event_locked', 'org', 'default', 'fallback')),
  charge_model          text NOT NULL CHECK (charge_model IN ('destination', 'split')),
  -- The Exos fee alone (what exos_checkout_sessions.application_fee_cents says).
  application_fee_cents integer NOT NULL CHECK (application_fee_cents >= 0),
  -- platform_fee: the commission added to Stripe's application_fee_amount.
  commission_fee_cents  integer NOT NULL DEFAULT 0 CHECK (commission_fee_cents >= 0),
  -- platform_fee: the commission per ticket, in mint order (what was charged).
  quote                 jsonb NOT NULL DEFAULT '[]'::jsonb CHECK (jsonb_typeof(quote) = 'array'),
  transfer_group        text CHECK (transfer_group IS NULL OR transfer_group ~ '^exos-order-[0-9a-f-]{36}$'),
  -- Frozen at the sale (_exos_commission_frozen_payable): editing the event
  -- later never makes this order's commissions or split shares payable sooner.
  payable_at            timestamptz NOT NULL,
  event_starts_at       timestamptz,
  created_at            timestamptz NOT NULL DEFAULT now(),
  CHECK (event_starts_at IS NULL OR payable_at >= event_starts_at),
  CHECK ((charge_model = 'split') = (method = 'split_at_sale')),
  CHECK (method = 'platform_fee' OR commission_fee_cents = 0),
  CHECK ((charge_model = 'split') = (transfer_group IS NOT NULL))
);
CREATE INDEX IF NOT EXISTS exos_checkout_commission_plans_org_idx ON public.exos_checkout_commission_plans (org_id);
CREATE INDEX IF NOT EXISTS exos_checkout_commission_plans_split_idx
  ON public.exos_checkout_commission_plans (created_at) WHERE charge_model = 'split';

-- Exos-funded commissions are capped (self-dealing guard): at most
-- exos_funded_commission_max_bps (platform setting, default 3000 = 30%) of a
-- ticket's net to the organizer, unless a platform admin recorded a higher
-- cap for the org (or one promoter) here. Service role writes only.
CREATE TABLE IF NOT EXISTS public.exos_commission_cap_approvals (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id      uuid NOT NULL REFERENCES public.exos_orgs (id) ON DELETE CASCADE,
  promoter_id uuid REFERENCES public.exos_promoters (id) ON DELETE CASCADE,
  max_bps     integer NOT NULL CHECK (max_bps BETWEEN 0 AND 10000),
  reason      text NOT NULL CHECK (length(btrim(reason)) BETWEEN 3 AND 500),
  approved_by text NOT NULL CHECK (length(btrim(approved_by)) BETWEEN 1 AND 200),
  expires_at  timestamptz,
  created_at  timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS exos_commission_cap_approvals_org_idx ON public.exos_commission_cap_approvals (org_id);

-- The cap in basis points for a promoter at an org (an unexpired approval for
-- the promoter or the whole org, else the platform setting).
CREATE OR REPLACE FUNCTION public._exos_commission_cap_bps(p_org_id uuid, p_promoter_id uuid)
RETURNS integer
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT greatest(
           least(public._exos_cm_setting_int('exos_funded_commission_max_bps', 3000), 10000),
           coalesce((SELECT max(a.max_bps) FROM public.exos_commission_cap_approvals a
                      WHERE a.org_id = p_org_id AND (a.promoter_id IS NULL OR a.promoter_id = p_promoter_id)
                        AND (a.expires_at IS NULL OR a.expires_at > now())), 0))
$$;
REVOKE ALL ON FUNCTION public._exos_commission_cap_bps(uuid, uuid) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public._exos_commission_cap_bps(uuid, uuid) TO service_role;

-- The most an Exos-funded commission may be on one ticket: the cap of the
-- ticket's net to the organizer (its base less its share of the Exos fee).
CREATE OR REPLACE FUNCTION public._exos_commission_cap_cents(p_org_id uuid, p_promoter_id uuid, p_base_cents integer, p_fee_per_ticket integer)
RETURNS integer
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT floor(greatest(coalesce(p_base_cents, 0) - greatest(coalesce(p_fee_per_ticket, 0), 0), 0)::numeric
               * public._exos_commission_cap_bps(p_org_id, p_promoter_id) / 10000)::integer
$$;
REVOKE ALL ON FUNCTION public._exos_commission_cap_cents(uuid, uuid, integer, integer) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public._exos_commission_cap_cents(uuid, uuid, integer, integer) TO service_role;

-- What an org owes Exos from split refunds, in one currency (open organizer
-- lines). Over split_org_debt_cap_cents (platform setting, default 50000)
-- Exos sells no new split orders for it and sends it no split money until
-- the debt is netted or settled.
CREATE OR REPLACE FUNCTION public._exos_org_split_debt(p_org_id uuid, p_currency text)
RETURNS bigint
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  RETURN coalesce((SELECT -sum(amount_cents) FROM public.exos_commission_netting
                    WHERE org_id = p_org_id AND party = 'organizer' AND currency = lower(coalesce(p_currency, 'usd'))
                      AND applied_payout_id IS NULL AND applied_transfer_id IS NULL AND voided_at IS NULL), 0);
END $$;
REVOKE ALL ON FUNCTION public._exos_org_split_debt(uuid, text) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public._exos_org_split_debt(uuid, text) TO service_role;

-- The plan for one order. Never refuses: a method that can't be used here
-- (processor, a switch off, a fee + commission larger than the charge) falls
-- back to 'manual', and checkout charges the destination way as before.
-- p_split_on / p_fee_on are the platform switches (EXOS_SPLIT_AT_SALE,
-- EXOS_PLATFORM_FEE_COMMISSIONS) as the function read them.
CREATE OR REPLACE FUNCTION public.exos_commission_checkout_plan(
  p_event_id              uuid,
  p_tier_id               uuid,
  p_promoter_code         text,
  p_quantity              integer,
  p_charge_cents          integer,
  p_addon_net_cents       integer,
  p_tax_cents             integer,
  p_application_fee_cents integer,
  p_processor             text,
  p_split_on              boolean,
  p_fee_on                boolean
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_org   uuid;
  v_pid   uuid;
  v_m     text;
  v_src   text;
  v_tix   integer;
  v_gross integer;
  v_base  integer;
  v_n     integer;
  v_c     integer;
  v_comm  bigint := 0;
  v_quote jsonb := '[]'::jsonb;
  v_why   text;
  r       record;
  x       record;
  i       integer;
BEGIN
  SELECT org_id INTO v_org FROM public.exos_events WHERE id = p_event_id;
  IF v_org IS NULL OR coalesce(p_quantity, 0) < 1 THEN RETURN NULL; END IF;
  IF p_promoter_code IS NOT NULL AND p_promoter_code <> '' THEN
    SELECT id INTO v_pid FROM public.exos_promoters WHERE org_id = v_org AND code = p_promoter_code;
  END IF;
  SELECT * INTO r FROM public._exos_commission_resolve(p_event_id, v_pid, false);
  v_m := r.method; v_src := r.source;

  IF v_m IN ('split_at_sale', 'platform_fee')
     AND (coalesce(p_processor, 'stripe') <> 'stripe' OR coalesce(p_charge_cents, 0) <= 0) THEN
    v_m := 'manual'; v_src := 'fallback';
  END IF;
  IF v_m = 'split_at_sale' AND NOT (coalesce(p_split_on, false)
       AND coalesce((SELECT split_at_sale_enabled FROM public.exos_org_commission_settings WHERE org_id = v_org), false)) THEN
    v_m := 'manual'; v_src := 'fallback';
  END IF;
  IF v_m = 'platform_fee' AND NOT coalesce(p_fee_on, false) THEN
    v_m := 'manual'; v_src := 'fallback';
  END IF;

  -- The commission this order will accrue, ticket by ticket, the way
  -- exos_pc_accrue_ticket will (same base, same ordinal counting).
  IF v_m IN ('split_at_sale', 'platform_fee') AND v_pid IS NOT NULL THEN
    v_tix := p_quantity * public.exos_tier_party_size(p_tier_id);
    v_gross := round(round(greatest(p_charge_cents - coalesce(p_addon_net_cents, 0), 0)::numeric / 100 / v_tix, 2) * 100)::integer;
    v_base := least(greatest(p_charge_cents - coalesce(p_addon_net_cents, 0) - coalesce(p_tax_cents, 0), 0) / p_quantity, v_gross);
    IF v_base > 0 THEN
      SELECT count(*) INTO v_n FROM public.exos_promoter_commissions
       WHERE promoter_id = v_pid AND event_id = p_event_id AND status <> 'reversed';
      FOR i IN 1..v_tix LOOP
        SELECT * INTO x FROM public._exos_pc_terms(v_pid, p_event_id, v_n + i);
        v_c := public.exos_pc_commission_cents(v_base, x.rate_bps, x.flat_cents);
        v_quote := v_quote || jsonb_build_array(jsonb_build_object(
          'rate_bps', x.rate_bps, 'flat_cents', x.flat_cents, 'source', x.source, 'stepped', x.stepped, 'commission_cents', v_c));
        v_comm := v_comm + v_c;
      END LOOP;
    END IF;
    -- Never more out of a charge than the charge: fee + commission must fit.
    IF v_comm + coalesce(p_application_fee_cents, 0) > p_charge_cents THEN
      v_m := 'manual'; v_src := 'fallback'; v_comm := 0; v_quote := '[]'::jsonb; v_why := 'fee_and_commission_over_charge';
    END IF;
    -- The self-dealing cap: no ticket's commission above the cap of its net.
    IF v_m <> 'manual' AND EXISTS (
         SELECT 1 FROM jsonb_array_elements(v_quote) q
          WHERE (q ->> 'commission_cents')::integer > public._exos_commission_cap_cents(
                  v_org, v_pid, v_base, ceil(coalesce(p_application_fee_cents, 0)::numeric / v_tix)::integer)) THEN
      v_m := 'manual'; v_src := 'fallback'; v_comm := 0; v_quote := '[]'::jsonb; v_why := 'commission_cap';
    END IF;
  END IF;
  -- An org over its split debt cap sells no new split orders.
  IF v_m = 'split_at_sale'
     AND public._exos_org_split_debt(v_org, (SELECT currency FROM public.exos_events WHERE id = p_event_id))
         > public._exos_cm_setting_int('split_org_debt_cap_cents', 50000) THEN
    v_m := 'manual'; v_src := 'fallback'; v_why := 'split_debt_cap';
  END IF;

  RETURN jsonb_build_object(
    'method', v_m, 'source', v_src, 'promoter_id', v_pid, 'fallback_reason', v_why,
    'charge_model', CASE WHEN v_m = 'split_at_sale' THEN 'split' ELSE 'destination' END,
    'application_fee_cents', coalesce(p_application_fee_cents, 0),
    'commission_fee_cents', CASE WHEN v_m = 'platform_fee' THEN v_comm ELSE 0 END,
    'quote', CASE WHEN v_m = 'platform_fee' THEN v_quote ELSE '[]'::jsonb END,
    'transfer_group', CASE WHEN v_m = 'split_at_sale' THEN 'exos-order-' || gen_random_uuid() END);
END $$;
REVOKE ALL ON FUNCTION public.exos_commission_checkout_plan(uuid, uuid, text, integer, integer, integer, integer, integer, text, boolean, boolean) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.exos_commission_checkout_plan(uuid, uuid, text, integer, integer, integer, integer, integer, text, boolean, boolean) TO service_role;

-- Record the plan once the session row exists (exos-checkout; a failure there
-- expires the Stripe session, so no order is charged without its plan).
CREATE OR REPLACE FUNCTION public.exos_record_commission_plan(p_session_id text, p_plan jsonb)
RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  s public.exos_checkout_sessions%ROWTYPE;
BEGIN
  SELECT * INTO s FROM public.exos_checkout_sessions WHERE session_id = p_session_id;
  IF s.session_id IS NULL OR p_plan IS NULL OR jsonb_typeof(p_plan) <> 'object' THEN RETURN false; END IF;
  -- The payable time is worked out here, from the event as it is now, never
  -- taken from the caller.
  INSERT INTO public.exos_checkout_commission_plans (
    session_id, org_id, event_id, promoter_id, method, method_source, charge_model,
    application_fee_cents, commission_fee_cents, quote, transfer_group, payable_at, event_starts_at
  ) VALUES (
    s.session_id, s.org_id, s.event_id,
    (SELECT p.id FROM public.exos_promoters p WHERE p.org_id = s.org_id AND p.id = (p_plan ->> 'promoter_id')::uuid),
    p_plan ->> 'method', p_plan ->> 'source', p_plan ->> 'charge_model',
    coalesce((p_plan ->> 'application_fee_cents')::integer, coalesce(s.application_fee_cents, 0)),
    coalesce((p_plan ->> 'commission_fee_cents')::integer, 0),
    coalesce(p_plan -> 'quote', '[]'::jsonb), p_plan ->> 'transfer_group',
    public._exos_commission_frozen_payable(s.event_id, p_plan ->> 'method'),
    (SELECT e.starts_at FROM public.exos_events e WHERE e.id = s.event_id)
  ) ON CONFLICT (session_id) DO NOTHING;
  RETURN true;
END $$;
REVOKE ALL ON FUNCTION public.exos_record_commission_plan(text, jsonb) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.exos_record_commission_plan(text, jsonb) TO service_role;

-- ===========================================================================
-- 4. The commission rows remember their method; payouts learn two new ways.
-- ===========================================================================
ALTER TABLE public.exos_promoter_commissions
  ADD COLUMN IF NOT EXISTS method        text NOT NULL DEFAULT 'manual',
  ADD COLUMN IF NOT EXISTS method_source text NOT NULL DEFAULT 'default',
  ADD COLUMN IF NOT EXISTS session_id    text,
  -- Frozen at accrual (the order's plan, else _exos_commission_frozen_payable).
  ADD COLUMN IF NOT EXISTS payable_at    timestamptz;
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'exos_promoter_commissions_method_chk') THEN
    ALTER TABLE public.exos_promoter_commissions ADD CONSTRAINT exos_promoter_commissions_method_chk CHECK (
      method IN ('clawback', 'split_at_sale', 'platform_fee', 'manual')
      AND method_source IN ('promoter', 'event', 'event_locked', 'org', 'default', 'fallback'));
  END IF;
END $$;
CREATE INDEX IF NOT EXISTS exos_promoter_commissions_session_idx
  ON public.exos_promoter_commissions (session_id) WHERE session_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS exos_promoter_commissions_exos_due_idx
  ON public.exos_promoter_commissions (method, status) WHERE method IN ('split_at_sale', 'platform_fee') AND status = 'accrued';
-- Existing rows: the order they came from (rows from before this migration
-- keep method 'manual', which is what they were).
UPDATE public.exos_promoter_commissions c
   SET session_id = t.order_ref
  FROM public.exos_tickets t
 WHERE c.session_id IS NULL AND t.id = c.ticket_id AND t.order_ref IS NOT NULL
   AND EXISTS (SELECT 1 FROM public.exos_checkout_sessions s WHERE s.session_id = t.order_ref);
UPDATE public.exos_promoter_commissions c
   SET payable_at = public._exos_commission_frozen_payable(c.event_id, c.method)
 WHERE c.payable_at IS NULL;
COMMENT ON COLUMN public.exos_promoter_commissions.method IS
  'How this commission is funded (recorded at accrual, never rewritten): clawback, split_at_sale, platform_fee, manual. mig 20261104190000.';

-- Payouts by the two new ways: 'split' (a transfer from the order's charge)
-- and 'platform_fee' (a transfer from the platform balance). Same shape as
-- 'stripe' (transfer_status, stripe_transfer_id, ...). The wedge's clawback
-- functions keep refusing anything but via 'stripe'.
ALTER TABLE public.exos_promoter_payouts ADD COLUMN IF NOT EXISTS source_session_id text;
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'exos_promoter_payouts_transfer_chk'
               AND pg_get_constraintdef(oid) NOT LIKE '%platform_fee%') THEN
    ALTER TABLE public.exos_promoter_payouts DROP CONSTRAINT exos_promoter_payouts_transfer_chk;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'exos_promoter_payouts_transfer_chk') THEN
    ALTER TABLE public.exos_promoter_payouts ADD CONSTRAINT exos_promoter_payouts_transfer_chk CHECK (
      (idempotency_key IS NULL OR idempotency_key ~ '^[A-Za-z0-9_-]{8,80}$')
      AND via IN ('manual', 'stripe', 'split', 'platform_fee')
      AND (transfer_status IS NULL OR transfer_status IN ('pending', 'sending', 'sent', 'dry_run', 'failed', 'cancel_pending', 'return_pending', 'cancelled'))
      AND ((via = 'manual') = (transfer_status IS NULL))
      AND (stripe_transfer_id IS NULL OR stripe_transfer_id ~ '^tr_[A-Za-z0-9]{1,64}$')
      AND (return_transfer_id IS NULL OR return_transfer_id ~ '^tr_[A-Za-z0-9]{1,64}$')
      AND (transfer_error IS NULL OR length(transfer_error) <= 300)
      AND (transfer_status IS DISTINCT FROM 'sent' OR stripe_transfer_id IS NOT NULL)
      AND ((transfer_status = 'cancelled') = (cancelled_at IS NOT NULL)));
  END IF;
END $$;

-- ===========================================================================
-- 5. Exos-made transfers (methods B and C): one row = one Stripe transfer.
-- ===========================================================================
CREATE TABLE IF NOT EXISTS public.exos_commission_transfers (
  id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id             uuid NOT NULL REFERENCES public.exos_orgs (id) ON DELETE CASCADE,
  -- split_org: the organizer's share of a split order; split_promoter: one
  -- promoter's commission from a split order; fee_promoter: commissions held
  -- in application fees, from the platform balance.
  kind               text NOT NULL CHECK (kind IN ('split_org', 'split_promoter', 'fee_promoter')),
  session_id         text REFERENCES public.exos_checkout_sessions (session_id) ON DELETE CASCADE,
  promoter_id        uuid REFERENCES public.exos_promoters (id) ON DELETE CASCADE,
  payout_id          uuid UNIQUE REFERENCES public.exos_promoter_payouts (id) ON DELETE CASCADE,
  currency           text NOT NULL CHECK (currency ~ '^[a-z]{3}$'),
  -- The share before netting; netted_cents was taken off for earlier
  -- refunds (negative: a credit owed to the organizer was added).
  gross_cents        integer NOT NULL CHECK (gross_cents >= 0),
  netted_cents       integer NOT NULL DEFAULT 0,
  amount_cents       integer NOT NULL CHECK (amount_cents >= 0),
  destination        text CHECK (destination IS NULL OR destination ~ '^acct_[A-Za-z0-9]{1,64}$'),
  source_charge_id   text CHECK (source_charge_id IS NULL OR source_charge_id ~ '^(ch|py)_[A-Za-z0-9]{1,64}$'),
  transfer_group     text NOT NULL CHECK (transfer_group ~ '^exos-[a-z]+-[0-9a-f-]{36}$'),
  -- planned -> sending -> sent | failed | dry_run; cancelled (never went out);
  -- netted (nothing to move: earlier refunds took all of it).
  status             text NOT NULL DEFAULT 'planned'
                       CHECK (status IN ('planned', 'sending', 'sent', 'dry_run', 'failed', 'cancelled', 'netted')),
  stripe_transfer_id text CHECK (stripe_transfer_id IS NULL OR stripe_transfer_id ~ '^tr_[A-Za-z0-9]{1,64}$'),
  error              text CHECK (error IS NULL OR length(error) <= 300),
  attempts           integer NOT NULL DEFAULT 0,
  failures           integer NOT NULL DEFAULT 0,
  lease_until        timestamptz,
  lease_token        uuid,
  lease_purpose      text CHECK (lease_purpose IS NULL OR lease_purpose IN ('send', 'reconcile', 'cancel')),
  send_started_at    timestamptz,
  reconciled_at      timestamptz,
  cancelled_at       timestamptz,
  cancelled_commission_ids uuid[],
  alert              text,
  created_at         timestamptz NOT NULL DEFAULT now(),
  updated_at         timestamptz NOT NULL DEFAULT now(),
  CHECK (amount_cents = gross_cents - netted_cents),
  CHECK ((status = 'netted') = (amount_cents = 0)),
  CHECK (status = 'netted' OR destination IS NOT NULL),
  CHECK (status <> 'sent' OR stripe_transfer_id IS NOT NULL),
  CHECK ((status = 'cancelled') = (cancelled_at IS NOT NULL)),
  CHECK ((kind = 'split_org') = (promoter_id IS NULL)),
  CHECK (kind = 'split_org' OR payout_id IS NOT NULL),
  CHECK (kind = 'fee_promoter' OR (session_id IS NOT NULL AND source_charge_id IS NOT NULL))
);
CREATE UNIQUE INDEX IF NOT EXISTS exos_commission_transfers_split_uq
  ON public.exos_commission_transfers (kind, session_id, coalesce(promoter_id, '00000000-0000-0000-0000-000000000000'::uuid))
  WHERE kind IN ('split_org', 'split_promoter') AND status <> 'cancelled';
CREATE INDEX IF NOT EXISTS exos_commission_transfers_due_idx
  ON public.exos_commission_transfers (created_at) WHERE status IN ('planned', 'dry_run', 'failed');
CREATE INDEX IF NOT EXISTS exos_commission_transfers_org_idx ON public.exos_commission_transfers (org_id, created_at DESC);
CREATE INDEX IF NOT EXISTS exos_commission_transfers_promoter_idx ON public.exos_commission_transfers (promoter_id) WHERE promoter_id IS NOT NULL;

-- ===========================================================================
-- 6. Netting lines: what was paid and then refunded, owed back.
-- ===========================================================================
CREATE TABLE IF NOT EXISTS public.exos_commission_netting (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id              uuid NOT NULL REFERENCES public.exos_orgs (id) ON DELETE CASCADE,
  -- promoter: owed by a promoter (taken off their next payout).
  -- organizer: a split order's true-up (negative: the organizer owes Exos;
  -- positive: Exos owes the organizer), taken off / added to their next
  -- split transfer.
  party               text NOT NULL CHECK (party IN ('promoter', 'organizer')),
  promoter_id         uuid REFERENCES public.exos_promoters (id) ON DELETE CASCADE,
  currency            text NOT NULL,
  amount_cents        integer NOT NULL CHECK (amount_cents <> 0),
  -- clawback: a paid commission refunded (mirrors the commission row);
  -- shortfall: less held for a sale than its commission (partial refunds);
  -- true_up: a split order changed after the organizer was paid;
  -- carry: what a transfer couldn't net, carried forward.
  kind                text NOT NULL CHECK (kind IN ('clawback', 'shortfall', 'true_up', 'carry')),
  commission_id       uuid REFERENCES public.exos_promoter_commissions (id) ON DELETE SET NULL,
  session_id          text,
  method              text CHECK (method IS NULL OR method IN ('clawback', 'split_at_sale', 'platform_fee', 'manual')),
  -- Who is owed, i.e. who bore the loss: the organizer (manual, clawback;
  -- and a platform_fee order whose refund kept the fee, see
  -- exos_commission_refund_marks) or Exos (split, platform fee, true-ups).
  funder              text NOT NULL CHECK (funder IN ('organizer', 'platform')),
  reason              text CHECK (reason IS NULL OR length(reason) <= 200),
  applied_payout_id   uuid REFERENCES public.exos_promoter_payouts (id) ON DELETE SET NULL,
  applied_transfer_id uuid REFERENCES public.exos_commission_transfers (id) ON DELETE SET NULL,
  carried_from        uuid REFERENCES public.exos_commission_transfers (id) ON DELETE SET NULL,
  applied_at          timestamptz,
  voided_at           timestamptz,
  created_at          timestamptz NOT NULL DEFAULT now(),
  CHECK ((party = 'promoter') = (promoter_id IS NOT NULL)),
  CHECK (party = 'organizer' OR amount_cents < 0),
  CHECK ((party = 'organizer') = (kind IN ('true_up', 'carry'))),
  CHECK (applied_payout_id IS NULL OR applied_transfer_id IS NULL),
  CHECK (party = 'promoter' OR funder = 'platform')
);
CREATE UNIQUE INDEX IF NOT EXISTS exos_commission_netting_commission_uq
  ON public.exos_commission_netting (commission_id) WHERE commission_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS exos_commission_netting_open_idx
  ON public.exos_commission_netting (org_id, party, promoter_id, currency)
  WHERE applied_payout_id IS NULL AND applied_transfer_id IS NULL AND voided_at IS NULL;
CREATE INDEX IF NOT EXISTS exos_commission_netting_session_idx ON public.exos_commission_netting (session_id) WHERE session_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS exos_commission_netting_payout_idx ON public.exos_commission_netting (applied_payout_id) WHERE applied_payout_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS exos_commission_netting_transfer_idx ON public.exos_commission_netting (applied_transfer_id) WHERE applied_transfer_id IS NOT NULL;

-- A platform_fee order refunded after its commission went out: the refund
-- kept the Exos fee (refund_application_fee off), so the organizer bore the
-- commission part and the promoter's clawback is owed to the organizer.
CREATE TABLE IF NOT EXISTS public.exos_commission_refund_marks (
  session_id text PRIMARY KEY REFERENCES public.exos_checkout_sessions (session_id) ON DELETE CASCADE,
  org_id     uuid NOT NULL REFERENCES public.exos_orgs (id) ON DELETE CASCADE,
  reason     text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);

-- Who a paid-then-refunded commission is owed to: its netting line's funder;
-- rows from before this migration (no line) by method.
CREATE OR REPLACE FUNCTION public._exos_pc_funder(p_commission_id uuid, p_method text)
RETURNS text
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT coalesce((SELECT n.funder FROM public.exos_commission_netting n WHERE n.commission_id = p_commission_id),
                  CASE WHEN p_method IN ('split_at_sale', 'platform_fee') THEN 'platform' ELSE 'organizer' END)
$$;
REVOKE ALL ON FUNCTION public._exos_pc_funder(uuid, text) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public._exos_pc_funder(uuid, text) TO service_role;

-- RLS: staff who see promoter money (owner / manager / finance) read; every
-- write goes through the definer functions. The change log too.
DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['exos_org_commission_settings', 'exos_event_commission_settings', 'exos_commission_method_changes',
                           'exos_checkout_commission_plans', 'exos_commission_transfers', 'exos_commission_netting',
                           'exos_commission_cap_approvals', 'exos_commission_refund_marks'] LOOP
    EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY', t);
    EXECUTE format('REVOKE ALL ON public.%I FROM PUBLIC, anon, authenticated', t);
    EXECUTE format('GRANT SELECT ON public.%I TO authenticated', t);
    EXECUTE format('GRANT ALL ON public.%I TO service_role', t);
    EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I', t || '_staff_read', t);
    EXECUTE format('CREATE POLICY %I ON public.%I FOR SELECT TO authenticated
                    USING (public.exos_has_org_role(org_id, ARRAY[''owner'', ''manager'', ''finance'']))',
                   t || '_staff_read', t);
  END LOOP;
  FOREACH t IN ARRAY ARRAY['exos_org_commission_settings', 'exos_event_commission_settings', 'exos_commission_transfers'] LOOP
    EXECUTE format('DROP TRIGGER IF EXISTS %I ON public.%I', t || '_touch', t);
    EXECUTE format('CREATE TRIGGER %I BEFORE UPDATE ON public.%I FOR EACH ROW EXECUTE FUNCTION public.exos_touch_updated_at()',
                   t || '_touch', t);
  END LOOP;
END $$;

-- ===========================================================================
-- 7. Triggers on the commission rows.
-- ===========================================================================
-- At accrual: the order behind the ticket, the method that sale used (the
-- checkout plan's, else resolved now; a sale not charged the B / C way falls
-- back to manual), and the event's lock. A platform_fee sale takes its
-- commission from the checkout quote, capped at what the fee collected.
CREATE OR REPLACE FUNCTION public.exos_tg_pc_method()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_sid  text;
  pl     public.exos_checkout_commission_plans%ROWTYPE;
  r      record;
  q      jsonb;
  v_k    integer;
  v_used bigint;
  v_tix  integer;
BEGIN
  IF NEW.session_id IS NULL AND NEW.ticket_id IS NOT NULL THEN
    SELECT t.order_ref INTO v_sid FROM public.exos_tickets t WHERE t.id = NEW.ticket_id;
    IF v_sid IS NOT NULL AND EXISTS (SELECT 1 FROM public.exos_checkout_sessions s WHERE s.session_id = v_sid) THEN
      NEW.session_id := v_sid;
    END IF;
  END IF;
  PERFORM public._exos_commission_pin(NEW.event_id);
  IF NEW.session_id IS NOT NULL THEN
    SELECT * INTO pl FROM public.exos_checkout_commission_plans WHERE session_id = NEW.session_id;
  END IF;
  IF pl.session_id IS NOT NULL AND pl.promoter_id IS NOT DISTINCT FROM NEW.promoter_id THEN
    NEW.method := pl.method;
    NEW.method_source := pl.method_source;
    IF pl.method = 'platform_fee' THEN
      SELECT count(*), coalesce(sum(commission_cents), 0) INTO v_k, v_used
        FROM public.exos_promoter_commissions WHERE session_id = NEW.session_id;
      q := pl.quote -> v_k;
      IF q IS NOT NULL THEN
        NEW.rate_bps := (q ->> 'rate_bps')::integer;
        NEW.flat_cents := (q ->> 'flat_cents')::integer;
        NEW.terms_source := q ->> 'source';
        NEW.stepped := coalesce((q ->> 'stepped')::boolean, false);
        NEW.commission_cents := (q ->> 'commission_cents')::integer;
      END IF;
      NEW.commission_cents := greatest(least(NEW.commission_cents, NEW.base_cents, pl.commission_fee_cents - v_used), 0)::integer;
    END IF;
    NEW.payable_at := pl.payable_at;
    -- Exos-funded: never above the self-dealing cap (terms may have changed
    -- since checkout checked it).
    IF pl.method IN ('split_at_sale', 'platform_fee') THEN
      SELECT greatest(s.quantity * public.exos_tier_party_size(s.tier_id), 1) INTO v_tix
        FROM public.exos_checkout_sessions s WHERE s.session_id = NEW.session_id;
      NEW.commission_cents := least(NEW.commission_cents, public._exos_commission_cap_cents(
        NEW.org_id, NEW.promoter_id, NEW.base_cents, ceil(pl.application_fee_cents::numeric / v_tix)::integer));
    END IF;
  ELSE
    SELECT * INTO r FROM public._exos_commission_resolve(NEW.event_id, NEW.promoter_id, false);
    IF r.method IN ('split_at_sale', 'platform_fee') THEN
      NEW.method := 'manual'; NEW.method_source := 'fallback';
    ELSE
      NEW.method := r.method; NEW.method_source := r.source;
    END IF;
    NEW.payable_at := public._exos_commission_frozen_payable(NEW.event_id, NEW.method);
  END IF;
  RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION public.exos_tg_pc_method() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS exos_promoter_commissions_method ON public.exos_promoter_commissions;
CREATE TRIGGER exos_promoter_commissions_method
  BEFORE INSERT ON public.exos_promoter_commissions
  FOR EACH ROW EXECUTE FUNCTION public.exos_tg_pc_method();

-- Every update. The method is never rewritten; a platform_fee sale keeps the
-- commission it was charged (a re-price leaves it alone). Accrued -> paid only
-- by a payout of the matching kind, and only after the holdback (always for
-- Exos-moved payouts; for manual / clawback once the org saved settings).
-- A late 'sent' restoring a cancelled payout's sales passes: 'sent' wins.
CREATE OR REPLACE FUNCTION public.exos_tg_pc_gate()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  po   public.exos_promoter_payouts%ROWTYPE;
  v_at timestamptz;
BEGIN
  NEW.method := OLD.method;
  NEW.method_source := OLD.method_source;
  -- Frozen at the sale: set once, never moved.
  NEW.payable_at := coalesce(OLD.payable_at, NEW.payable_at);
  IF OLD.method = 'platform_fee' AND OLD.status = 'accrued' AND NEW.status = 'accrued' THEN
    NEW.commission_cents := OLD.commission_cents; NEW.rate_bps := OLD.rate_bps; NEW.flat_cents := OLD.flat_cents;
    NEW.terms_source := OLD.terms_source; NEW.stepped := OLD.stepped;
  END IF;
  IF OLD.status = 'accrued' AND NEW.status = 'paid' THEN
    SELECT * INTO po FROM public.exos_promoter_payouts WHERE id = NEW.payout_id;
    IF po.transfer_status = 'cancelled' THEN RETURN NEW; END IF;
    IF NOT ((OLD.method IN ('manual', 'clawback') AND po.via IN ('manual', 'stripe'))
            OR (OLD.method = 'split_at_sale' AND po.via = 'split')
            OR (OLD.method = 'platform_fee' AND po.via = 'platform_fee')
            OR (po.via = 'manual' AND po.amount_cents = 0 AND po.created_by IS NULL AND po.method = 'Netted against refunds')) THEN
      RAISE EXCEPTION 'Some selected sales are paid out by Exos (split at sale or inside the Exos fee), not here. Reload and pick the others.'
        USING ERRCODE = '22023';
    END IF;
    IF po.via IN ('split', 'platform_fee')
       OR EXISTS (SELECT 1 FROM public.exos_org_commission_settings WHERE org_id = OLD.org_id) THEN
      v_at := public._exos_commission_payable_at(OLD.event_id, OLD.accrued_at, OLD.method, OLD.payable_at);
      IF v_at > now() THEN
        RAISE EXCEPTION 'Some selected sales are still in the refund holdback (payable from % UTC).',
          to_char(v_at AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI') USING ERRCODE = '22023';
      END IF;
    END IF;
  END IF;
  RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION public.exos_tg_pc_gate() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS exos_promoter_commissions_gate ON public.exos_promoter_commissions;
CREATE TRIGGER exos_promoter_commissions_gate
  BEFORE UPDATE ON public.exos_promoter_commissions
  FOR EACH ROW EXECUTE FUNCTION public.exos_tg_pc_gate();

-- ===========================================================================
-- 8. Split orders: what the organizer is owed, now; the true-up after a
--    refund that came once their share went out.
-- ===========================================================================
-- net = charge - refunds (succeeded + pending); a lost dispute: nothing.
-- fee = the Exos fee less its refunded share (as refund_application_fee
-- would). commission = the order's commission rows that still stand.
-- org_share = net - fee - commission (never below 0). Mirrors
-- _shared/payouts/commissionMethods.ts splitShares.
CREATE OR REPLACE FUNCTION public._exos_split_entitlement(p_session_id text)
RETURNS TABLE (net bigint, fee bigint, commission bigint, org_share bigint, refunded bigint,
               open_dispute boolean, in_flight boolean, currency text, org_id uuid)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  s  public.exos_checkout_sessions%ROWTYPE;
  pl public.exos_checkout_commission_plans%ROWTYPE;
  v_lost boolean;
BEGIN
  SELECT * INTO s FROM public.exos_checkout_sessions WHERE session_id = p_session_id;
  SELECT * INTO pl FROM public.exos_checkout_commission_plans WHERE session_id = p_session_id;
  IF s.session_id IS NULL OR pl.session_id IS NULL THEN RETURN; END IF;
  v_lost := s.dispute_status = 'lost';
  SELECT coalesce(sum(amount_cents), 0) INTO refunded FROM public.exos_order_refunds rf
   WHERE rf.session_id = p_session_id AND rf.status IN ('succeeded', 'pending');
  refunded := least(refunded, s.amount_cents);
  net := CASE WHEN v_lost THEN 0 ELSE greatest(s.amount_cents - refunded, 0) END;
  fee := CASE WHEN v_lost OR s.amount_cents <= 0 THEN 0
              ELSE pl.application_fee_cents - floor(pl.application_fee_cents::numeric * refunded / s.amount_cents)::bigint END;
  -- A commission refunded after Exos paid it stays counted until the
  -- promoter's clawback line is recovered: Exos never fronts it to the
  -- organizer (the true-up credits them once it is netted).
  SELECT coalesce(sum(c.commission_cents), 0) INTO commission FROM public.exos_promoter_commissions c
   WHERE c.session_id = p_session_id
     AND (c.status <> 'reversed'
          OR (c.payout_id IS NOT NULL AND EXISTS (
                SELECT 1 FROM public.exos_commission_netting n
                 WHERE n.commission_id = c.id AND n.funder = 'platform'
                   AND n.applied_payout_id IS NULL AND n.applied_transfer_id IS NULL AND n.voided_at IS NULL)));
  org_share := greatest(net - fee - commission, 0);
  open_dispute := s.dispute_status IS NOT NULL AND s.dispute_status NOT IN ('won', 'lost', 'warning_closed');
  in_flight := EXISTS (SELECT 1 FROM public.exos_order_refunds rf WHERE rf.session_id = p_session_id AND rf.status = 'pending')
            OR EXISTS (SELECT 1 FROM public.exos_refund_requests rq WHERE rq.session_id = p_session_id AND rq.status IN ('claimed', 'pending'));
  currency := lower(coalesce(s.currency, 'usd'));
  org_id := s.org_id;
  RETURN NEXT;
END $$;
REVOKE ALL ON FUNCTION public._exos_split_entitlement(text) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public._exos_split_entitlement(text) TO service_role;

-- Once the organizer's share of a split order is planned (any live
-- split_org transfer), any later change to the order is a true-up line:
-- target = share planned - share now (positive: the organizer owes Exos).
-- Idempotent: only the difference from the lines so far is written.
CREATE OR REPLACE FUNCTION public._exos_split_true_up(p_session_id text)
RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  ct    public.exos_commission_transfers%ROWTYPE;
  e     record;
  v_cur bigint;
  v_d   bigint;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.exos_checkout_commission_plans WHERE session_id = p_session_id AND charge_model = 'split') THEN
    RETURN 0;
  END IF;
  PERFORM pg_advisory_xact_lock(hashtextextended('exos-split:' || p_session_id, 0));
  SELECT * INTO ct FROM public.exos_commission_transfers
   WHERE kind = 'split_org' AND session_id = p_session_id AND status <> 'cancelled';
  IF ct.id IS NULL THEN RETURN 0; END IF;
  SELECT * INTO e FROM public._exos_split_entitlement(p_session_id);
  PERFORM pg_advisory_xact_lock(hashtextextended('exos-org-net:' || ct.org_id || ':' || ct.currency, 0));
  -- Recovered so far: true-up lines, plus what transfer reversals took back
  -- from the organizer's transfer (exos_split_reversals, the first resort).
  SELECT -coalesce(sum(amount_cents), 0) INTO v_cur FROM public.exos_commission_netting
   WHERE party = 'organizer' AND kind = 'true_up' AND session_id = p_session_id AND voided_at IS NULL;
  v_cur := v_cur + coalesce((SELECT sum(amount_cents) FROM public.exos_split_reversals
                              WHERE session_id = p_session_id AND status IN ('planned', 'taken')), 0);
  v_d := (ct.gross_cents - e.org_share) - v_cur;
  IF v_d > 0 AND ct.status = 'sent' THEN
    -- The fallback: money Exos couldn't take back from the transfer.
    UPDATE public.exos_commission_transfers
       SET alert = left(coalesce(alert || ' | ', '') || 'A refund or dispute after this share was paid left '
                        || v_d || ' cents owed to Exos (not reversed); netted from the next split order', 1000)
     WHERE id = ct.id;
  END IF;
  IF v_d <> 0 THEN
    INSERT INTO public.exos_commission_netting (org_id, party, currency, amount_cents, kind, session_id, method, funder, reason)
    VALUES (ct.org_id, 'organizer', ct.currency, (-v_d)::integer, 'true_up', p_session_id, 'split_at_sale', 'platform',
            CASE WHEN v_d > 0 THEN 'refund or dispute after your share was paid' ELSE 'adjustment in your favour' END);
  END IF;
  RETURN v_d::integer;
END $$;
REVOKE ALL ON FUNCTION public._exos_split_true_up(text) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public._exos_split_true_up(text) TO service_role;

-- After a commission row changes: the netting mirror, and split true-ups.
CREATE OR REPLACE FUNCTION public.exos_tg_pc_netting()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  -- Paid, then refunded: a negative line, owed back by the promoter.
  IF NEW.status = 'reversed' AND OLD.status = 'paid' AND NEW.payout_id IS NOT NULL AND NEW.commission_cents > 0 THEN
    INSERT INTO public.exos_commission_netting (org_id, party, promoter_id, currency, amount_cents, kind, commission_id,
                                                session_id, method, funder, reason)
    VALUES (NEW.org_id, 'promoter', NEW.promoter_id, NEW.currency, -NEW.commission_cents, 'clawback', NEW.id,
            NEW.session_id, NEW.method,
            CASE WHEN NEW.method IN ('split_at_sale', 'platform_fee')
                      AND NOT EXISTS (SELECT 1 FROM public.exos_commission_refund_marks m WHERE m.session_id = NEW.session_id)
                 THEN 'platform' ELSE 'organizer' END,
            left('refunded after payout: ' || coalesce(NEW.reversed_reason, 'refund'), 200))
    ON CONFLICT (commission_id) WHERE commission_id IS NOT NULL DO UPDATE
      SET voided_at = NULL, applied_payout_id = NULL, applied_transfer_id = NULL, applied_at = NULL,
          amount_cents = EXCLUDED.amount_cents, funder = EXCLUDED.funder;
  END IF;
  -- Netted (or un-netted, when that payout is cancelled).
  IF NEW.recovered_payout_id IS DISTINCT FROM OLD.recovered_payout_id THEN
    UPDATE public.exos_commission_netting
       SET applied_payout_id = NEW.recovered_payout_id,
           applied_at = CASE WHEN NEW.recovered_payout_id IS NULL THEN NULL ELSE now() END
     WHERE commission_id = NEW.id;
  END IF;
  -- Its payout was cancelled (the money never went out): nothing is owed.
  IF NEW.status = 'reversed' AND OLD.payout_id IS NOT NULL AND NEW.payout_id IS NULL THEN
    UPDATE public.exos_commission_netting SET voided_at = now()
     WHERE commission_id = NEW.id AND voided_at IS NULL;
  END IF;
  IF NEW.method = 'split_at_sale' AND NEW.session_id IS NOT NULL
     AND (NEW.status IS DISTINCT FROM OLD.status OR NEW.recovered_payout_id IS DISTINCT FROM OLD.recovered_payout_id) THEN
    PERFORM public._exos_split_true_up(NEW.session_id);
  END IF;
  RETURN NULL;
END $$;
REVOKE ALL ON FUNCTION public.exos_tg_pc_netting() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS exos_promoter_commissions_netting ON public.exos_promoter_commissions;
CREATE TRIGGER exos_promoter_commissions_netting
  AFTER UPDATE ON public.exos_promoter_commissions
  FOR EACH ROW EXECUTE FUNCTION public.exos_tg_pc_netting();

-- Refunds and disputes on split orders: true up the organizer.
CREATE OR REPLACE FUNCTION public.exos_tg_split_true_up()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF EXISTS (SELECT 1 FROM public.exos_checkout_commission_plans WHERE session_id = NEW.session_id AND charge_model = 'split') THEN
    PERFORM public._exos_split_true_up(NEW.session_id);
  END IF;
  RETURN NULL;
END $$;
REVOKE ALL ON FUNCTION public.exos_tg_split_true_up() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS exos_order_refunds_split_true_up ON public.exos_order_refunds;
CREATE TRIGGER exos_order_refunds_split_true_up
  AFTER INSERT OR UPDATE OF status, amount_cents ON public.exos_order_refunds
  FOR EACH ROW EXECUTE FUNCTION public.exos_tg_split_true_up();
DROP TRIGGER IF EXISTS exos_checkout_sessions_split_dispute ON public.exos_checkout_sessions;
CREATE TRIGGER exos_checkout_sessions_split_dispute
  AFTER UPDATE OF dispute_status ON public.exos_checkout_sessions
  FOR EACH ROW WHEN (NEW.dispute_status IS DISTINCT FROM OLD.dispute_status)
  EXECUTE FUNCTION public.exos_tg_split_true_up();

-- ===========================================================================
-- 9. Planning Exos-made transfers (service role: exos-promoter-payouts /run).
--    Only sales past the holdback. Amounts are fixed when planned; anything
--    that changes later is netting, never a bigger or smaller transfer.
-- ===========================================================================
-- Pay one promoter for p_ids (accrued, one currency) by an Exos transfer:
-- net their open platform-funded clawbacks (whole lines, oldest first, never
-- more than the payout), record any shortfall (less held than the
-- commission) as lines, flip the rows to paid and plan the transfer. A
-- payout fully netted moves nothing ('Netted against refunds'). Returns the
-- payout id, or NULL when the promoter has no ready payout account.
CREATE OR REPLACE FUNCTION public._exos_ct_pay_promoter(
  p_promoter_id uuid, p_kind text, p_currency text, p_ids uuid[], p_shortfall jsonb,
  p_session_id text, p_charge_id text, p_group text
) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_org   uuid;
  v_acct  text;
  v_gross bigint;
  v_short bigint;
  v_cap   bigint;
  v_net   bigint := 0;
  v_lines uuid[] := '{}';
  v_amt   bigint;
  v_po    uuid;
  v_meth  text := CASE WHEN p_kind = 'fee_promoter' THEN 'platform_fee' ELSE 'split_at_sale' END;
  l       record;
  x       jsonb;
BEGIN
  SELECT org_id INTO v_org FROM public.exos_promoters WHERE id = p_promoter_id;
  SELECT stripe_account_id INTO v_acct FROM public.exos_promoter_stripe_accounts
   WHERE promoter_id = p_promoter_id AND transfers_active;
  IF v_org IS NULL OR v_acct IS NULL OR coalesce(cardinality(p_ids), 0) = 0 THEN RETURN NULL; END IF;
  SELECT coalesce(sum(commission_cents), 0) INTO v_gross FROM public.exos_promoter_commissions WHERE id = ANY (p_ids);
  SELECT coalesce(sum((e ->> 'cents')::bigint), 0) INTO v_short
    FROM jsonb_array_elements(coalesce(p_shortfall, '[]'::jsonb)) e WHERE (e ->> 'cents')::bigint > 0;
  v_cap := v_gross - v_short;
  FOR l IN SELECT n.commission_id, -n.amount_cents::bigint AS owed
             FROM public.exos_commission_netting n
            WHERE n.party = 'promoter' AND n.promoter_id = p_promoter_id AND n.currency = p_currency
              AND n.funder = 'platform' AND n.kind = 'clawback' AND n.commission_id IS NOT NULL
              AND n.applied_payout_id IS NULL AND n.applied_transfer_id IS NULL AND n.voided_at IS NULL
            ORDER BY n.created_at, n.id
  LOOP
    EXIT WHEN v_net + l.owed > v_cap;
    v_net := v_net + l.owed;
    v_lines := v_lines || l.commission_id;
  END LOOP;
  v_amt := v_cap - v_net;

  INSERT INTO public.exos_promoter_payouts (
    org_id, promoter_id, currency, amount_cents, commission_cents, clawback_cents, row_count, method,
    paid_on, created_by, via, transfer_status, stripe_account_id, source_session_id
  ) VALUES (
    v_org, p_promoter_id, p_currency, v_amt, v_gross, v_net + v_short, cardinality(p_ids),
    CASE WHEN v_amt = 0 THEN 'Netted against refunds'
         WHEN p_kind = 'fee_promoter' THEN 'Stripe transfer (Exos fee)' ELSE 'Stripe transfer (split at sale)' END,
    current_date, NULL,
    CASE WHEN v_amt = 0 THEN 'manual' WHEN p_kind = 'fee_promoter' THEN 'platform_fee' ELSE 'split' END,
    CASE WHEN v_amt > 0 THEN 'pending' END, CASE WHEN v_amt > 0 THEN v_acct END, p_session_id
  ) RETURNING id INTO v_po;

  FOR x IN SELECT * FROM jsonb_array_elements(coalesce(p_shortfall, '[]'::jsonb)) LOOP
    IF (x ->> 'cents')::bigint > 0 THEN
      INSERT INTO public.exos_commission_netting (org_id, party, promoter_id, currency, amount_cents, kind, session_id,
                                                  method, funder, reason, applied_payout_id, applied_at)
      VALUES (v_org, 'promoter', p_promoter_id, p_currency, -((x ->> 'cents')::integer), 'shortfall', x ->> 'session_id',
              v_meth, 'platform', 'less was held for this order than its commission (a partial refund)', v_po, now());
    END IF;
  END LOOP;
  UPDATE public.exos_promoter_commissions
     SET status = 'paid', payout_id = v_po, paid_at = now(), updated_at = now()
   WHERE id = ANY (p_ids);
  IF cardinality(v_lines) > 0 THEN
    UPDATE public.exos_promoter_commissions SET recovered_payout_id = v_po, updated_at = now() WHERE id = ANY (v_lines);
  END IF;
  IF v_amt > 0 THEN
    INSERT INTO public.exos_commission_transfers (
      org_id, kind, session_id, promoter_id, payout_id, currency, gross_cents, netted_cents, amount_cents,
      destination, source_charge_id, transfer_group
    ) VALUES (
      v_org, p_kind, p_session_id, p_promoter_id, v_po, p_currency, v_cap, v_net, v_amt,
      v_acct, p_charge_id, coalesce(p_group, 'exos-fee-' || v_po)
    );
  END IF;
  RETURN v_po;
END $$;
REVOKE ALL ON FUNCTION public._exos_ct_pay_promoter(uuid, text, text, uuid[], jsonb, text, text, text) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public._exos_ct_pay_promoter(uuid, text, text, uuid[], jsonb, text, text, text) TO service_role;

-- One split order past its holdback: the organizer's share (less what they
-- owe from earlier split refunds, plus anything Exos owes them, up to this
-- order's fee) and each promoter with a ready account. Returns rows planned.
CREATE OR REPLACE FUNCTION public._exos_split_plan_order(p_session_id text)
RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  s       public.exos_checkout_sessions%ROWTYPE;
  pl      public.exos_checkout_commission_plans%ROWTYPE;
  e       record;
  r       record;
  v_charge text;
  v_dest  text;
  v_ct    uuid;
  v_d     bigint;
  v_take  bigint;
  v_amt   bigint;
  v_ids   uuid[];
  v_gross bigint;
  v_paid  bigint;
  v_avail bigint;
  v_cap   bigint;
  v_n     integer := 0;
BEGIN
  PERFORM pg_advisory_xact_lock(hashtextextended('exos-split:' || p_session_id, 0));
  SELECT * INTO pl FROM public.exos_checkout_commission_plans WHERE session_id = p_session_id AND charge_model = 'split';
  IF pl.session_id IS NULL THEN RETURN 0; END IF;
  SELECT * INTO s FROM public.exos_checkout_sessions WHERE session_id = p_session_id;
  IF s.status NOT IN ('fulfilled', 'partially_refunded', 'refunded') THEN RETURN 0; END IF;
  IF public._exos_commission_payable_at(s.event_id, s.created_at, 'split_at_sale', pl.payable_at) > now() THEN RETURN 0; END IF;
  SELECT op.charge_id INTO v_charge FROM public.exos_order_payments op
   WHERE op.session_id = p_session_id AND op.status = 'succeeded' AND op.charge_id ~ '^(ch|py)_[A-Za-z0-9]{1,64}$'
   ORDER BY op.created_at DESC LIMIT 1;
  IF v_charge IS NULL THEN RETURN 0; END IF;
  SELECT * INTO e FROM public._exos_split_entitlement(p_session_id);
  IF e.open_dispute OR e.in_flight THEN RETURN 0; END IF;

  -- The organizer.
  IF NOT EXISTS (SELECT 1 FROM public.exos_commission_transfers
                  WHERE kind = 'split_org' AND session_id = p_session_id AND status <> 'cancelled') THEN
    SELECT sec.payments ->> 'connectedAccountId' INTO v_dest FROM public.exos_org_secrets sec WHERE sec.org_id = s.org_id;
    IF v_dest ~ '^acct_[A-Za-z0-9]{1,64}$' THEN
      PERFORM pg_advisory_xact_lock(hashtextextended('exos-org-net:' || s.org_id || ':' || e.currency, 0));
      SELECT -coalesce(sum(amount_cents), 0) INTO v_d FROM public.exos_commission_netting
       WHERE party = 'organizer' AND org_id = s.org_id AND currency = e.currency
         AND applied_payout_id IS NULL AND applied_transfer_id IS NULL AND voided_at IS NULL;
      v_take := CASE WHEN v_d > 0 THEN least(v_d, e.org_share) WHEN v_d < 0 THEN -least(-v_d, e.fee) ELSE 0 END;
      v_amt := e.org_share - v_take;
      -- Over the debt cap: no split money goes to this org (a share that only
      -- nets the debt down is still planned).
      IF v_amt > 0 AND v_d > public._exos_cm_setting_int('split_org_debt_cap_cents', 50000) THEN
        RETURN v_n;
      END IF;
      INSERT INTO public.exos_commission_transfers (
        org_id, kind, session_id, currency, gross_cents, netted_cents, amount_cents, destination,
        source_charge_id, transfer_group, status
      ) VALUES (
        s.org_id, 'split_org', p_session_id, e.currency, e.org_share, v_take, v_amt, v_dest,
        v_charge, pl.transfer_group, CASE WHEN v_amt = 0 THEN 'netted' ELSE 'planned' END
      ) RETURNING id INTO v_ct;
      IF v_take <> 0 THEN
        UPDATE public.exos_commission_netting SET applied_transfer_id = v_ct, applied_at = now()
         WHERE party = 'organizer' AND org_id = s.org_id AND currency = e.currency
           AND applied_payout_id IS NULL AND applied_transfer_id IS NULL AND voided_at IS NULL;
        IF v_d - v_take <> 0 THEN
          INSERT INTO public.exos_commission_netting (org_id, party, currency, amount_cents, kind, session_id,
                                                      method, funder, reason, carried_from)
          VALUES (s.org_id, 'organizer', e.currency, (-(v_d - v_take))::integer, 'carry', p_session_id,
                  'split_at_sale', 'platform', 'carried forward to your next split order', v_ct);
        END IF;
      END IF;
      v_n := v_n + 1;
    END IF;
  END IF;

  -- Each promoter with accrued split sales on this order and a ready account.
  FOR r IN SELECT c.promoter_id FROM public.exos_promoter_commissions c
            WHERE c.session_id = p_session_id AND c.status = 'accrued' AND c.method = 'split_at_sale'
            GROUP BY c.promoter_id ORDER BY c.promoter_id
  LOOP
    CONTINUE WHEN EXISTS (SELECT 1 FROM public.exos_commission_transfers
                           WHERE kind = 'split_promoter' AND session_id = p_session_id
                             AND promoter_id = r.promoter_id AND status <> 'cancelled');
    CONTINUE WHEN NOT EXISTS (SELECT 1 FROM public.exos_promoter_stripe_accounts
                               WHERE promoter_id = r.promoter_id AND transfers_active);
    PERFORM 1 FROM public.exos_promoters WHERE id = r.promoter_id FOR UPDATE;
    PERFORM 1 FROM public.exos_promoter_commissions
      WHERE session_id = p_session_id AND promoter_id = r.promoter_id AND status = 'accrued' AND method = 'split_at_sale'
      ORDER BY id FOR UPDATE;
    SELECT array_agg(id ORDER BY accrued_at, id), coalesce(sum(commission_cents), 0) INTO v_ids, v_gross
      FROM public.exos_promoter_commissions
     WHERE session_id = p_session_id AND promoter_id = r.promoter_id AND status = 'accrued' AND method = 'split_at_sale';
    CONTINUE WHEN v_ids IS NULL;
    SELECT coalesce(sum(commission_cents), 0) INTO v_paid FROM public.exos_promoter_commissions
     WHERE session_id = p_session_id AND status = 'paid';
    v_avail := e.net - e.fee - e.org_share - v_paid;
    v_cap := least(v_gross, greatest(v_avail, 0));
    PERFORM public._exos_ct_pay_promoter(
      r.promoter_id, 'split_promoter', e.currency, v_ids,
      CASE WHEN v_gross > v_cap THEN jsonb_build_array(jsonb_build_object('session_id', p_session_id, 'cents', v_gross - v_cap))
           ELSE '[]'::jsonb END,
      p_session_id, v_charge, pl.transfer_group);
    v_n := v_n + 1;
  END LOOP;
  RETURN v_n;
END $$;
REVOKE ALL ON FUNCTION public._exos_split_plan_order(text) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public._exos_split_plan_order(text) TO service_role;

-- One promoter's platform_fee sales past the holdback, in one currency: one
-- transfer from the platform balance. Per order, never more than the fee
-- still holds for its commission (Stripe refunds that share of the fee with
-- a refund: refund_application_fee). One open transfer per promoter.
CREATE OR REPLACE FUNCTION public._exos_fee_plan_promoter(p_promoter_id uuid, p_currency text)
RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_org   uuid;
  v_ids   uuid[] := '{}';
  v_short jsonb := '[]'::jsonb;
  r       record;
  v_held  bigint;
  v_used  bigint;
  v_rf    bigint;
  v_pay   bigint;
BEGIN
  SELECT org_id INTO v_org FROM public.exos_promoters WHERE id = p_promoter_id FOR UPDATE;
  IF v_org IS NULL OR NOT EXISTS (SELECT 1 FROM public.exos_promoter_stripe_accounts
                                   WHERE promoter_id = p_promoter_id AND transfers_active) THEN
    RETURN 0;
  END IF;
  IF EXISTS (SELECT 1 FROM public.exos_commission_transfers
              WHERE kind = 'fee_promoter' AND promoter_id = p_promoter_id AND currency = p_currency
                AND status IN ('planned', 'sending', 'dry_run', 'failed')) THEN
    RETURN 0;
  END IF;
  FOR r IN
    SELECT c.session_id, array_agg(c.id ORDER BY c.accrued_at, c.id) AS ids, sum(c.commission_cents)::bigint AS entitled,
           max(pl.commission_fee_cents) AS fee_comm, max(s.amount_cents) AS amount, bool_or(s.dispute_status = 'lost') AS lost
      FROM public.exos_promoter_commissions c
      JOIN public.exos_checkout_commission_plans pl ON pl.session_id = c.session_id
      JOIN public.exos_checkout_sessions s ON s.session_id = c.session_id
     WHERE c.promoter_id = p_promoter_id AND c.currency = p_currency AND c.status = 'accrued' AND c.method = 'platform_fee'
       AND public._exos_commission_payable_at(c.event_id, c.accrued_at, c.method, c.payable_at) <= now()
       AND NOT (s.dispute_status IS NOT NULL AND s.dispute_status NOT IN ('won', 'lost', 'warning_closed'))
       AND NOT EXISTS (SELECT 1 FROM public.exos_order_refunds rf WHERE rf.session_id = c.session_id AND rf.status = 'pending')
       AND NOT EXISTS (SELECT 1 FROM public.exos_refund_requests rq WHERE rq.session_id = c.session_id AND rq.status IN ('claimed', 'pending'))
     GROUP BY c.session_id
     ORDER BY min(c.accrued_at), c.session_id
     LIMIT 200
  LOOP
    PERFORM 1 FROM public.exos_promoter_commissions WHERE id = ANY (r.ids) ORDER BY id FOR UPDATE;
    -- A refund may have reversed some of them meanwhile.
    SELECT array_agg(id ORDER BY accrued_at, id), coalesce(sum(commission_cents), 0) INTO r.ids, r.entitled
      FROM public.exos_promoter_commissions WHERE id = ANY (r.ids) AND status = 'accrued';
    CONTINUE WHEN r.ids IS NULL;
    SELECT coalesce(sum(amount_cents), 0) INTO v_rf FROM public.exos_order_refunds
     WHERE session_id = r.session_id AND status IN ('succeeded', 'pending');
    v_held := CASE WHEN r.lost OR r.amount <= 0 THEN 0
                   ELSE r.fee_comm - ceil(r.fee_comm::numeric * least(v_rf, r.amount) / r.amount)::bigint END;
    SELECT coalesce(sum(commission_cents), 0) INTO v_used FROM public.exos_promoter_commissions
     WHERE session_id = r.session_id AND status = 'paid';
    v_pay := least(r.entitled, greatest(v_held - v_used, 0));
    v_ids := v_ids || r.ids;
    IF v_pay < r.entitled THEN
      v_short := v_short || jsonb_build_array(jsonb_build_object('session_id', r.session_id, 'cents', r.entitled - v_pay));
    END IF;
  END LOOP;
  IF cardinality(v_ids) = 0 THEN RETURN 0; END IF;
  PERFORM public._exos_ct_pay_promoter(p_promoter_id, 'fee_promoter', p_currency, v_ids, v_short, NULL, NULL, NULL);
  RETURN 1;
END $$;
REVOKE ALL ON FUNCTION public._exos_fee_plan_promoter(uuid, text) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public._exos_fee_plan_promoter(uuid, text) TO service_role;

-- The job's planning step. p_org_id NULL: every org (cron). Returns
-- {planned, needs_charge: [{session_id, payment_intent}]}: split orders whose
-- charge id isn't recorded yet (the job reads it from Stripe and records it
-- with exos_commission_record_charge, then the next run plans them).
CREATE OR REPLACE FUNCTION public.exos_commission_plan_due(p_org_id uuid DEFAULT NULL, p_limit integer DEFAULT 25)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_lim integer := least(greatest(coalesce(p_limit, 25), 1), 100);
  v_n   integer := 0;
  r     record;
BEGIN
  FOR r IN
    SELECT pl.session_id
      FROM public.exos_checkout_commission_plans pl
      JOIN public.exos_checkout_sessions s ON s.session_id = pl.session_id
     WHERE pl.charge_model = 'split' AND (p_org_id IS NULL OR pl.org_id = p_org_id)
       AND s.status IN ('fulfilled', 'partially_refunded', 'refunded')
       AND NOT (s.dispute_status IS NOT NULL AND s.dispute_status NOT IN ('won', 'lost', 'warning_closed'))
       AND public._exos_commission_payable_at(s.event_id, s.created_at, 'split_at_sale', pl.payable_at) <= now()
       AND EXISTS (SELECT 1 FROM public.exos_order_payments op
                    WHERE op.session_id = pl.session_id AND op.status = 'succeeded' AND op.charge_id IS NOT NULL)
       AND (NOT EXISTS (SELECT 1 FROM public.exos_commission_transfers ct
                         WHERE ct.kind = 'split_org' AND ct.session_id = pl.session_id AND ct.status <> 'cancelled')
            OR EXISTS (SELECT 1 FROM public.exos_promoter_commissions c
                         JOIN public.exos_promoter_stripe_accounts a ON a.promoter_id = c.promoter_id AND a.transfers_active
                        WHERE c.session_id = pl.session_id AND c.status = 'accrued' AND c.method = 'split_at_sale'
                          AND NOT EXISTS (SELECT 1 FROM public.exos_commission_transfers ct
                                           WHERE ct.kind = 'split_promoter' AND ct.session_id = pl.session_id
                                             AND ct.promoter_id = c.promoter_id AND ct.status <> 'cancelled')))
     ORDER BY pl.created_at
     LIMIT v_lim
  LOOP
    v_n := v_n + public._exos_split_plan_order(r.session_id);
  END LOOP;
  FOR r IN
    SELECT DISTINCT c.promoter_id, c.currency
      FROM public.exos_promoter_commissions c
      JOIN public.exos_promoter_stripe_accounts a ON a.promoter_id = c.promoter_id AND a.transfers_active
     WHERE c.method = 'platform_fee' AND c.status = 'accrued' AND (p_org_id IS NULL OR c.org_id = p_org_id)
       AND public._exos_commission_payable_at(c.event_id, c.accrued_at, c.method, c.payable_at) <= now()
     LIMIT v_lim
  LOOP
    v_n := v_n + public._exos_fee_plan_promoter(r.promoter_id, r.currency);
  END LOOP;
  RETURN jsonb_build_object(
    'planned', v_n,
    'needs_charge', coalesce((
      SELECT jsonb_agg(jsonb_build_object('session_id', x.session_id, 'payment_intent', x.payment_intent))
        FROM (SELECT op.session_id, op.payment_intent
                FROM public.exos_checkout_commission_plans pl
                JOIN public.exos_order_payments op ON op.session_id = pl.session_id
               WHERE pl.charge_model = 'split' AND (p_org_id IS NULL OR pl.org_id = p_org_id)
                 AND op.status = 'succeeded' AND op.charge_id IS NULL AND op.payment_intent ~ '^pi_[A-Za-z0-9]{1,250}$'
               ORDER BY op.created_at LIMIT 10) x), '[]'::jsonb));
END $$;
REVOKE ALL ON FUNCTION public.exos_commission_plan_due(uuid, integer) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.exos_commission_plan_due(uuid, integer) TO service_role;

-- A split order's charge id, read from its PaymentIntent (first write wins).
CREATE OR REPLACE FUNCTION public.exos_commission_record_charge(p_session_id text, p_payment_intent text, p_charge_id text)
RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE v_n integer;
BEGIN
  IF p_charge_id IS NULL OR p_charge_id !~ '^(ch|py)_[A-Za-z0-9]{1,64}$' THEN RETURN false; END IF;
  UPDATE public.exos_order_payments SET charge_id = p_charge_id, updated_at = now()
   WHERE session_id = p_session_id AND payment_intent = p_payment_intent AND charge_id IS NULL;
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN v_n > 0;
END $$;
REVOKE ALL ON FUNCTION public.exos_commission_record_charge(text, text, text) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.exos_commission_record_charge(text, text, text) TO service_role;

-- ===========================================================================
-- 10. Sending an Exos-made transfer: the wedge's lease / fence / reconcile
--     rules, for exos_commission_transfers (service role:
--     exos-promoter-payouts). Same numbers: a send lease lasts 6 minutes and
--     is never extended; a reconcile or cancel waits until 10 minutes after
--     a send began; every claim mints a new token that fences out older
--     holders; 'sent' always wins. Promoter transfers mirror their state onto
--     their payout row (transfer_status) in the same statement's transaction.
-- ===========================================================================
CREATE OR REPLACE FUNCTION public._exos_ct_mirror(p_ct_id uuid)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE ct public.exos_commission_transfers%ROWTYPE;
BEGIN
  SELECT * INTO ct FROM public.exos_commission_transfers WHERE id = p_ct_id;
  IF ct.payout_id IS NULL THEN RETURN; END IF;
  UPDATE public.exos_promoter_payouts
     SET transfer_status = CASE ct.status WHEN 'planned' THEN 'pending' WHEN 'netted' THEN 'sent' ELSE ct.status END,
         stripe_transfer_id = ct.stripe_transfer_id,
         transfer_error = ct.error,
         transfer_attempts = ct.attempts,
         cancelled_at = CASE WHEN ct.status = 'cancelled' THEN coalesce(cancelled_at, now()) ELSE NULL END,
         alert = ct.alert,
         transfer_updated_at = now()
   WHERE id = ct.payout_id;
END $$;
REVOKE ALL ON FUNCTION public._exos_ct_mirror(uuid) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public._exos_ct_mirror(uuid) TO service_role;

-- What the job should send now (planned, dry run, or failed fewer than 5 times).
CREATE OR REPLACE FUNCTION public.exos_ct_due(p_org_id uuid DEFAULT NULL, p_limit integer DEFAULT 10)
RETURNS SETOF uuid
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT id FROM public.exos_commission_transfers
   WHERE (status IN ('planned', 'dry_run') OR (status = 'failed' AND failures < 5))
     AND (lease_until IS NULL OR lease_until <= now())
     AND (p_org_id IS NULL OR org_id = p_org_id)
   ORDER BY created_at, id
   LIMIT least(greatest(coalesce(p_limit, 10), 1), 25)
$$;
REVOKE ALL ON FUNCTION public.exos_ct_due(uuid, integer) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.exos_ct_due(uuid, integer) TO service_role;

-- Why a transfer may not go out right now, or NULL. Re-checked at every send
-- claim (the planner checked it too): the frozen holdback, an open dispute or
-- a refund in flight on any order behind it (the reserve), and for an
-- organizer share the split debt cap.
CREATE OR REPLACE FUNCTION public._exos_ct_hold(p_id uuid)
RETURNS text
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  ct public.exos_commission_transfers%ROWTYPE;
  v_sessions text[];
BEGIN
  SELECT * INTO ct FROM public.exos_commission_transfers WHERE id = p_id;
  IF ct.id IS NULL THEN RETURN 'not_found'; END IF;
  IF ct.payout_id IS NOT NULL THEN
    IF EXISTS (SELECT 1 FROM public.exos_promoter_commissions c
                WHERE c.payout_id = ct.payout_id
                  AND public._exos_commission_payable_at(c.event_id, c.accrued_at, c.method, c.payable_at) > now()) THEN
      RETURN 'holdback';
    END IF;
    SELECT array_agg(DISTINCT c.session_id) INTO v_sessions FROM public.exos_promoter_commissions c
     WHERE c.payout_id = ct.payout_id AND c.session_id IS NOT NULL;
  ELSE
    IF EXISTS (SELECT 1 FROM public.exos_checkout_commission_plans pl JOIN public.exos_checkout_sessions s ON s.session_id = pl.session_id
                WHERE pl.session_id = ct.session_id
                  AND public._exos_commission_payable_at(s.event_id, s.created_at, 'split_at_sale', pl.payable_at) > now()) THEN
      RETURN 'holdback';
    END IF;
    IF ct.amount_cents > 0 AND public._exos_org_split_debt(ct.org_id, ct.currency) > public._exos_cm_setting_int('split_org_debt_cap_cents', 50000) THEN
      RETURN 'debt_cap';
    END IF;
    v_sessions := ARRAY[ct.session_id];
  END IF;
  IF EXISTS (SELECT 1 FROM public.exos_checkout_sessions s WHERE s.session_id = ANY (coalesce(v_sessions, '{}'))
                AND s.dispute_status IS NOT NULL AND s.dispute_status NOT IN ('won', 'lost', 'warning_closed')) THEN
    RETURN 'dispute_open';
  END IF;
  IF EXISTS (SELECT 1 FROM public.exos_order_refunds rf WHERE rf.session_id = ANY (coalesce(v_sessions, '{}')) AND rf.status = 'pending')
     OR EXISTS (SELECT 1 FROM public.exos_refund_requests rq WHERE rq.session_id = ANY (coalesce(v_sessions, '{}'))
                   AND rq.status IN ('claimed', 'pending')) THEN
    RETURN 'refund_in_flight';
  END IF;
  RETURN NULL;
END $$;
REVOKE ALL ON FUNCTION public._exos_ct_hold(uuid) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public._exos_ct_hold(uuid) TO service_role;

-- Claim one. p_user NULL: the cron; else the org's owner or manager (the
-- function checked the JWT; this re-checks). 'send' leases it to send
-- (needs_reconcile when an earlier send was never reconciled); 'reconcile'
-- and 'cancel' lease it to look Stripe up / to cancel, and are refused while
-- a send attempt may still be open.
CREATE OR REPLACE FUNCTION public.exos_ct_claim(p_id uuid, p_purpose text DEFAULT 'send', p_user uuid DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  ct      public.exos_commission_transfers%ROWTYPE;
  v_tok   uuid := gen_random_uuid();
  v_unrec boolean;
  v_state text;
  v_hold  text;
BEGIN
  IF p_purpose NOT IN ('send', 'reconcile', 'cancel') THEN
    RAISE EXCEPTION 'exos_ct_claim: bad purpose' USING ERRCODE = '22023';
  END IF;
  SELECT * INTO ct FROM public.exos_commission_transfers WHERE id = p_id FOR UPDATE;
  IF ct.id IS NULL OR (p_user IS NOT NULL AND NOT EXISTS (
       SELECT 1 FROM public.exos_org_memberships m
        WHERE m.org_id = ct.org_id AND m.user_id = p_user AND m.disabled IS NOT TRUE AND m.role IN ('owner', 'manager'))) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_found');
  END IF;
  IF ct.status IN ('sent', 'cancelled', 'netted') THEN
    RETURN jsonb_build_object('ok', false, 'error', ct.status);
  END IF;
  IF ct.lease_until > now() THEN
    RETURN jsonb_build_object('ok', false, 'error', 'busy');
  END IF;
  IF p_purpose <> 'send' AND ct.status = 'sending' AND ct.lease_purpose = 'send'
     AND ct.send_started_at > now() - interval '10 minutes' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'send_in_progress');
  END IF;
  v_unrec := ct.send_started_at IS NOT NULL AND (ct.reconciled_at IS NULL OR ct.reconciled_at < ct.send_started_at);
  IF p_purpose = 'send' AND v_unrec THEN
    RETURN jsonb_build_object('ok', false, 'error', 'needs_reconcile');
  END IF;
  IF p_purpose = 'send' THEN
    v_hold := public._exos_ct_hold(ct.id);
    IF v_hold IS NOT NULL THEN
      RETURN jsonb_build_object('ok', false, 'error', v_hold);
    END IF;
  END IF;
  v_state := CASE WHEN p_purpose = 'send' THEN 'sending' ELSE ct.status END;
  UPDATE public.exos_commission_transfers
     SET status = v_state,
         lease_until = now() + interval '6 minutes', lease_token = v_tok, lease_purpose = p_purpose,
         attempts = attempts + CASE WHEN p_purpose = 'send' THEN 1 ELSE 0 END,
         send_started_at = CASE WHEN p_purpose = 'send' THEN clock_timestamp() ELSE send_started_at END
   WHERE id = ct.id;
  PERFORM public._exos_ct_mirror(ct.id);
  RETURN jsonb_build_object(
    'ok', true, 'id', ct.id, 'lease_token', v_tok, 'purpose', p_purpose, 'state', v_state,
    'needs_reconcile', p_purpose <> 'send' AND v_unrec,
    'kind', ct.kind, 'org_id', ct.org_id, 'promoter_id', ct.promoter_id, 'session_id', ct.session_id,
    'payout_id', ct.payout_id, 'amount_cents', ct.amount_cents, 'currency', ct.currency,
    'destination', ct.destination, 'source_charge_id', ct.source_charge_id, 'transfer_group', ct.transfer_group,
    'stripe_transfer_id', ct.stripe_transfer_id, 'attempt', ct.attempts + CASE WHEN p_purpose = 'send' THEN 1 ELSE 0 END);
END $$;
REVOKE ALL ON FUNCTION public.exos_ct_claim(uuid, text, uuid) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.exos_ct_claim(uuid, text, uuid) TO service_role;

-- Does this send still hold it? Checked right before the Stripe call.
CREATE OR REPLACE FUNCTION public.exos_ct_lease_ok(p_id uuid, p_lease_token uuid)
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.exos_commission_transfers
     WHERE id = p_id AND status = 'sending' AND lease_purpose = 'send' AND lease_token = p_lease_token
       AND lease_until > now() AND cancelled_at IS NULL)
$$;
REVOKE ALL ON FUNCTION public.exos_ct_lease_ok(uuid, uuid) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.exos_ct_lease_ok(uuid, uuid) TO service_role;

-- The outcome of a send. 'sent' always wins: on a transfer a cancel had
-- finished, it restores the sales the cancel freed (those still unpaid) and
-- raises an alert. dry_run / failed only by the holder of p_lease_token.
CREATE OR REPLACE FUNCTION public.exos_ct_mark(
  p_id uuid, p_status text, p_transfer_id text DEFAULT NULL, p_error text DEFAULT NULL, p_lease_token uuid DEFAULT NULL
) RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  ct     public.exos_commission_transfers%ROWTYPE;
  v_n    integer;
  v_lost integer := 0;
BEGIN
  IF p_status NOT IN ('sent', 'dry_run', 'failed') THEN
    RAISE EXCEPTION 'exos_ct_mark: bad status' USING ERRCODE = '22023';
  END IF;
  SELECT * INTO ct FROM public.exos_commission_transfers WHERE id = p_id FOR UPDATE;
  IF ct.id IS NULL THEN RETURN false; END IF;
  IF p_status = 'sent' THEN
    IF p_transfer_id IS NULL OR p_transfer_id !~ '^tr_[A-Za-z0-9]{1,64}$' THEN
      RAISE EXCEPTION 'exos_ct_mark: sent needs a transfer id' USING ERRCODE = '22023';
    END IF;
    IF ct.status = 'sent' THEN RETURN ct.stripe_transfer_id = p_transfer_id; END IF;
    IF ct.status = 'netted' THEN RETURN false; END IF;
    IF ct.status = 'cancelled' AND ct.payout_id IS NOT NULL THEN
      UPDATE public.exos_promoter_commissions
         SET status = 'paid', payout_id = ct.payout_id, paid_at = now(), updated_at = now()
       WHERE id = ANY (coalesce(ct.cancelled_commission_ids, '{}')) AND status = 'accrued' AND payout_id IS NULL;
      GET DIAGNOSTICS v_n = ROW_COUNT;
      v_lost := coalesce(cardinality(ct.cancelled_commission_ids), 0) - v_n;
      UPDATE public.exos_commission_netting SET voided_at = NULL
       WHERE applied_payout_id = ct.payout_id AND kind = 'shortfall';
    END IF;
    UPDATE public.exos_commission_transfers
       SET status = 'sent', stripe_transfer_id = p_transfer_id, error = NULL, cancelled_at = NULL,
           lease_until = NULL, lease_token = NULL,
           alert = CASE WHEN ct.status = 'cancelled' THEN left(coalesce(alert || ' | ', '') ||
                     'Stripe sent this transfer (' || p_transfer_id || ') after it was cancelled' ||
                     CASE WHEN v_lost > 0 THEN '; ' || v_lost || ' of its sales were paid again since: check for a double payment'
                          WHEN ct.kind <> 'split_org' THEN '; check the refunds it had netted'
                          WHEN ct.kind = 'split_org' THEN '; check the order was not planned again' ELSE '' END, 1000)
                   ELSE alert END
     WHERE id = ct.id;
    PERFORM public._exos_ct_mirror(ct.id);
    RETURN true;
  END IF;
  UPDATE public.exos_commission_transfers
     SET status = p_status,
         error = CASE WHEN p_status = 'failed' THEN left(coalesce(p_error, 'failed'), 300) ELSE NULL END,
         failures = failures + CASE WHEN p_status = 'failed' THEN 1 ELSE 0 END,
         -- A dry run never called Stripe, so there is nothing to reconcile.
         reconciled_at = CASE WHEN p_status = 'dry_run' THEN clock_timestamp() ELSE reconciled_at END,
         lease_until = NULL, lease_token = NULL
   WHERE id = p_id AND status = 'sending' AND lease_token = p_lease_token;
  GET DIAGNOSTICS v_n = ROW_COUNT;
  IF v_n > 0 THEN PERFORM public._exos_ct_mirror(p_id); END IF;
  RETURN v_n > 0;
END $$;
REVOKE ALL ON FUNCTION public.exos_ct_mark(uuid, text, text, text, uuid) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.exos_ct_mark(uuid, text, text, text, uuid) TO service_role;

-- Reconcile with Stripe by the holder of a 'reconcile' or 'cancel' lease.
-- p_transfer_id: the transfer found at Stripe (transfer_group + metadata
-- exos_ct_id): it is sent. NULL: reconciled; a reconcile lease turns a stuck
-- 'sending' into 'failed' so the next send may go.
CREATE OR REPLACE FUNCTION public.exos_ct_reconcile(p_id uuid, p_lease_token uuid, p_transfer_id text)
RETURNS text
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE ct public.exos_commission_transfers%ROWTYPE;
BEGIN
  SELECT * INTO ct FROM public.exos_commission_transfers WHERE id = p_id FOR UPDATE;
  IF ct.id IS NULL OR ct.status IN ('sent', 'cancelled', 'netted') OR ct.lease_purpose NOT IN ('reconcile', 'cancel')
     OR ct.lease_token IS DISTINCT FROM p_lease_token THEN
    RAISE EXCEPTION 'exos_ct_reconcile: claim the transfer to reconcile first' USING ERRCODE = '22023';
  END IF;
  IF p_transfer_id IS NOT NULL AND p_transfer_id !~ '^tr_[A-Za-z0-9]{1,64}$' THEN
    RAISE EXCEPTION 'exos_ct_reconcile: bad transfer id' USING ERRCODE = '22023';
  END IF;
  IF p_transfer_id IS NOT NULL THEN
    UPDATE public.exos_commission_transfers SET reconciled_at = clock_timestamp() WHERE id = ct.id;
    PERFORM public.exos_ct_mark(ct.id, 'sent', p_transfer_id);
    RETURN 'sent';
  END IF;
  UPDATE public.exos_commission_transfers
     SET reconciled_at = clock_timestamp(),
         lease_until = CASE WHEN ct.lease_purpose = 'reconcile' THEN NULL ELSE lease_until END,
         status = CASE WHEN ct.lease_purpose = 'reconcile' AND ct.status = 'sending' THEN 'failed' ELSE status END,
         error = CASE WHEN ct.lease_purpose = 'reconcile' AND ct.status = 'sending'
                      THEN coalesce(error, 'reconciled: nothing at Stripe') ELSE error END
   WHERE id = ct.id;
  PERFORM public._exos_ct_mirror(ct.id);
  RETURN 'reconciled';
END $$;
REVOKE ALL ON FUNCTION public.exos_ct_reconcile(uuid, uuid, text) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.exos_ct_reconcile(uuid, uuid, text) TO service_role;

-- A cancel that stopped on an error lets go of its lease.
CREATE OR REPLACE FUNCTION public.exos_ct_lease_release(p_id uuid, p_lease_token uuid)
RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE v_n integer;
BEGIN
  UPDATE public.exos_commission_transfers SET lease_until = NULL
   WHERE id = p_id AND lease_token = p_lease_token AND lease_purpose IN ('cancel', 'reconcile');
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN v_n > 0;
END $$;
REVOKE ALL ON FUNCTION public.exos_ct_lease_release(uuid, uuid) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.exos_ct_lease_release(uuid, uuid) TO service_role;

-- Cancel one that never went out, by the holder of the cancel lease, after
-- any started send was reconciled. Nothing was taken from anyone (the money
-- sits on the platform), so there is nothing to return: a promoter's sales go
-- back to unpaid and the clawbacks it netted are open again; an organizer's
-- share is planned again next run, and the lines it netted are open again.
-- Refused for an organizer share that already has true-up lines (sort those
-- out first). Idempotent.
CREATE OR REPLACE FUNCTION public.exos_ct_cancel(p_id uuid, p_lease_token uuid)
RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  ct    public.exos_commission_transfers%ROWTYPE;
  v_ids uuid[];
BEGIN
  SELECT * INTO ct FROM public.exos_commission_transfers WHERE id = p_id FOR UPDATE;
  IF ct.id IS NULL OR ct.stripe_transfer_id IS NOT NULL OR ct.status IN ('sent', 'netted') THEN RETURN false; END IF;
  IF ct.status = 'cancelled' THEN RETURN true; END IF;
  IF ct.lease_purpose IS DISTINCT FROM 'cancel' OR ct.lease_token IS DISTINCT FROM p_lease_token OR ct.lease_until <= now() THEN
    RAISE EXCEPTION 'exos_ct_cancel: claim the transfer for cancel first' USING ERRCODE = '22023';
  END IF;
  IF ct.send_started_at IS NOT NULL AND (ct.reconciled_at IS NULL OR ct.reconciled_at < ct.send_started_at) THEN
    RAISE EXCEPTION 'exos_ct_cancel: a send was started; reconcile with Stripe before cancelling' USING ERRCODE = '22023';
  END IF;
  IF ct.kind = 'split_org' AND EXISTS (SELECT 1 FROM public.exos_commission_netting
                                        WHERE session_id = ct.session_id AND kind = 'true_up' AND voided_at IS NULL) THEN
    RAISE EXCEPTION 'exos_ct_cancel: this order was adjusted after its share was planned; it can''t be cancelled' USING ERRCODE = '22023';
  END IF;
  IF ct.payout_id IS NOT NULL THEN
    SELECT array_agg(id) INTO v_ids FROM public.exos_promoter_commissions WHERE payout_id = ct.payout_id AND status = 'paid';
    UPDATE public.exos_promoter_commissions
       SET status = CASE WHEN status = 'paid' THEN 'accrued' ELSE status END,
           payout_id = NULL, paid_at = NULL, updated_at = now()
     WHERE payout_id = ct.payout_id AND status IN ('paid', 'reversed');
    UPDATE public.exos_promoter_commissions SET recovered_payout_id = NULL, updated_at = now()
     WHERE recovered_payout_id = ct.payout_id;
    UPDATE public.exos_commission_netting SET voided_at = now()
     WHERE applied_payout_id = ct.payout_id AND kind = 'shortfall' AND voided_at IS NULL;
  ELSE
    UPDATE public.exos_commission_netting SET voided_at = now() WHERE carried_from = ct.id AND voided_at IS NULL;
    UPDATE public.exos_commission_netting SET applied_transfer_id = NULL, applied_at = NULL WHERE applied_transfer_id = ct.id;
  END IF;
  UPDATE public.exos_commission_transfers
     SET status = 'cancelled', cancelled_at = now(), lease_until = NULL, lease_token = NULL, cancelled_commission_ids = v_ids
   WHERE id = ct.id;
  PERFORM public._exos_ct_mirror(ct.id);
  RETURN true;
END $$;
REVOKE ALL ON FUNCTION public.exos_ct_cancel(uuid, uuid) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.exos_ct_cancel(uuid, uuid) TO service_role;

-- ===========================================================================
-- 11. The dashboard: settings, the picker, balances (owner / manager write;
--     owner / manager / finance read).
-- ===========================================================================
CREATE OR REPLACE FUNCTION public.exos_get_commission_settings(p_org_id uuid)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  o public.exos_org_commission_settings%ROWTYPE;
BEGIN
  IF NOT public.exos_has_org_role(p_org_id, ARRAY['owner', 'manager', 'finance']) THEN
    RAISE EXCEPTION 'exos_get_commission_settings: not allowed' USING ERRCODE = '42501';
  END IF;
  SELECT * INTO o FROM public.exos_org_commission_settings WHERE org_id = p_org_id;
  RETURN jsonb_build_object(
    'configured', o.org_id IS NOT NULL,
    'default_method', coalesce(o.default_method, 'manual'),
    'holdback_days', coalesce(o.holdback_days, 3),
    'split_at_sale_enabled', coalesce(o.split_at_sale_enabled, false),
    'netting_alert_days', coalesce(o.netting_alert_days, 30),
    'clawback_transfers_enabled', coalesce((SELECT stripe_transfers FROM public.exos_org_promoter_payouts WHERE org_id = p_org_id), false),
    'organizer_account', coalesce((SELECT (sec.payments ->> 'connectedAccountId') ~ '^acct_' FROM public.exos_org_secrets sec
                                    WHERE sec.org_id = p_org_id), false),
    'events', coalesce((
      SELECT jsonb_agg(jsonb_build_object(
               'event_id', e.id, 'name', e.name, 'starts_at', e.starts_at, 'ends_at', e.ends_at,
               'method', s.method, 'locked_method', s.locked_method, 'locked_at', s.locked_at,
               'sold', s.locked_method IS NOT NULL OR EXISTS (SELECT 1 FROM public.exos_tickets t
                                                               WHERE t.event_id = e.id AND coalesce(t.price_paid, 0) > 0),
               'effective', coalesce(s.locked_method, s.method, o.default_method, 'manual'))
             ORDER BY e.starts_at DESC NULLS LAST, e.id)
        FROM (SELECT * FROM public.exos_events WHERE org_id = p_org_id ORDER BY starts_at DESC NULLS LAST LIMIT 200) e
        LEFT JOIN public.exos_event_commission_settings s ON s.event_id = e.id), '[]'::jsonb),
    'promoters', coalesce((
      SELECT jsonb_agg(jsonb_build_object(
               'promoter_id', p.id, 'name', p.name, 'code', p.code, 'method', p.commission_method,
               'account_ready', coalesce(a.transfers_active, false)) ORDER BY p.name, p.id)
        FROM public.exos_promoters p
        LEFT JOIN public.exos_promoter_stripe_accounts a ON a.promoter_id = p.id
       WHERE p.org_id = p_org_id), '[]'::jsonb),
    'changes', coalesce((
      SELECT jsonb_agg(jsonb_build_object('scope', ch.scope, 'event_id', ch.event_id, 'promoter_id', ch.promoter_id,
                                          'old', ch.old_value, 'new', ch.new_value, 'at', ch.changed_at) ORDER BY ch.changed_at DESC)
        FROM (SELECT * FROM public.exos_commission_method_changes WHERE org_id = p_org_id
               ORDER BY changed_at DESC LIMIT 20) ch), '[]'::jsonb));
END $$;
REVOKE ALL ON FUNCTION public.exos_get_commission_settings(uuid) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.exos_get_commission_settings(uuid) TO authenticated, service_role;

-- The org default, holdback and alert days (owner / manager); the split
-- switch (owner only; NULL leaves it). Sold events are pinned first, so a
-- new default only reaches events that haven't sold.
CREATE OR REPLACE FUNCTION public.exos_set_commission_settings(
  p_org_id                uuid,
  p_default_method        text,
  p_holdback_days         integer,
  p_netting_alert_days    integer DEFAULT NULL,
  p_split_at_sale_enabled boolean DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  o     public.exos_org_commission_settings%ROWTYPE;
  v_m   text := coalesce(p_default_method, 'manual');
  r     record;
BEGIN
  IF NOT public.exos_has_org_role(p_org_id, ARRAY['owner', 'manager']) THEN
    RAISE EXCEPTION 'exos_set_commission_settings: not allowed' USING ERRCODE = '42501';
  END IF;
  IF v_m NOT IN ('clawback', 'split_at_sale', 'platform_fee', 'manual') THEN
    RAISE EXCEPTION 'Pick clawback, split at sale, inside the Exos fee, or manual.' USING ERRCODE = '22023';
  END IF;
  IF coalesce(p_holdback_days, 3) NOT BETWEEN 0 AND 30 THEN
    RAISE EXCEPTION 'The holdback is 0 to 30 days.' USING ERRCODE = '22023';
  END IF;
  IF p_netting_alert_days IS NOT NULL AND p_netting_alert_days NOT BETWEEN 1 AND 365 THEN
    RAISE EXCEPTION 'The overdue alert is 1 to 365 days.' USING ERRCODE = '22023';
  END IF;
  SELECT * INTO o FROM public.exos_org_commission_settings WHERE org_id = p_org_id FOR UPDATE;
  IF p_split_at_sale_enabled IS NOT NULL AND p_split_at_sale_enabled IS DISTINCT FROM coalesce(o.split_at_sale_enabled, false)
     AND NOT public.exos_has_org_role(p_org_id, ARRAY['owner']) THEN
    RAISE EXCEPTION 'Only the org owner can turn split at sale on or off.' USING ERRCODE = '42501';
  END IF;
  -- Lock in what sold events used before the default moves.
  IF v_m IS DISTINCT FROM coalesce(o.default_method, 'manual') THEN
    FOR r IN SELECT e.id FROM public.exos_events e
              WHERE e.org_id = p_org_id
                AND NOT EXISTS (SELECT 1 FROM public.exos_event_commission_settings s WHERE s.event_id = e.id AND s.locked_method IS NOT NULL)
                AND EXISTS (SELECT 1 FROM public.exos_tickets t WHERE t.event_id = e.id AND coalesce(t.price_paid, 0) > 0)
    LOOP
      PERFORM public._exos_commission_pin(r.id);
    END LOOP;
    INSERT INTO public.exos_commission_method_changes (org_id, scope, old_value, new_value, changed_by)
    VALUES (p_org_id, 'org', coalesce(o.default_method, 'manual'), v_m, auth.uid());
  END IF;
  IF coalesce(p_holdback_days, 3) IS DISTINCT FROM coalesce(o.holdback_days, 3) OR o.org_id IS NULL THEN
    INSERT INTO public.exos_commission_method_changes (org_id, scope, old_value, new_value, changed_by)
    VALUES (p_org_id, 'holdback', o.holdback_days::text, coalesce(p_holdback_days, 3)::text, auth.uid());
  END IF;
  IF p_split_at_sale_enabled IS NOT NULL AND p_split_at_sale_enabled IS DISTINCT FROM coalesce(o.split_at_sale_enabled, false) THEN
    INSERT INTO public.exos_commission_method_changes (org_id, scope, old_value, new_value, changed_by)
    VALUES (p_org_id, 'split_switch', coalesce(o.split_at_sale_enabled, false)::text, p_split_at_sale_enabled::text, auth.uid());
  END IF;
  INSERT INTO public.exos_org_commission_settings AS x
    (org_id, default_method, holdback_days, split_at_sale_enabled, netting_alert_days, updated_by)
  VALUES (p_org_id, v_m, coalesce(p_holdback_days, 3), coalesce(p_split_at_sale_enabled, false),
          coalesce(p_netting_alert_days, 30), auth.uid())
  ON CONFLICT (org_id) DO UPDATE SET
    default_method = EXCLUDED.default_method, holdback_days = EXCLUDED.holdback_days,
    split_at_sale_enabled = coalesce(p_split_at_sale_enabled, x.split_at_sale_enabled),
    netting_alert_days = coalesce(p_netting_alert_days, x.netting_alert_days),
    updated_by = EXCLUDED.updated_by
  RETURNING * INTO o;
  RETURN jsonb_build_object('default_method', o.default_method, 'holdback_days', o.holdback_days,
                            'split_at_sale_enabled', o.split_at_sale_enabled, 'netting_alert_days', o.netting_alert_days);
END $$;
REVOKE ALL ON FUNCTION public.exos_set_commission_settings(uuid, text, integer, integer, boolean) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.exos_set_commission_settings(uuid, text, integer, integer, boolean) TO authenticated, service_role;

-- An event's override (NULL: back to the org default). Once the event has
-- sold, its method is locked: a change needs p_future_sales_only and only
-- reaches sales made after it.
CREATE OR REPLACE FUNCTION public.exos_set_event_commission_method(
  p_event_id uuid, p_method text, p_future_sales_only boolean DEFAULT false
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_org  uuid;
  s      public.exos_event_commission_settings%ROWTYPE;
  v_sold boolean;
  v_new  text;
BEGIN
  SELECT org_id INTO v_org FROM public.exos_events WHERE id = p_event_id;
  IF v_org IS NULL OR NOT public.exos_has_org_role(v_org, ARRAY['owner', 'manager']) THEN
    RAISE EXCEPTION 'exos_set_event_commission_method: not allowed' USING ERRCODE = '42501';
  END IF;
  IF p_method IS NOT NULL AND p_method NOT IN ('clawback', 'split_at_sale', 'platform_fee', 'manual') THEN
    RAISE EXCEPTION 'Pick clawback, split at sale, inside the Exos fee, or manual.' USING ERRCODE = '22023';
  END IF;
  PERFORM public._exos_commission_pin(p_event_id);
  SELECT * INTO s FROM public.exos_event_commission_settings WHERE event_id = p_event_id FOR UPDATE;
  v_sold := s.locked_method IS NOT NULL;
  v_new := coalesce(p_method, (SELECT default_method FROM public.exos_org_commission_settings WHERE org_id = v_org), 'manual');
  IF v_sold AND v_new IS DISTINCT FROM s.locked_method AND NOT coalesce(p_future_sales_only, false) THEN
    RAISE EXCEPTION 'This event has sold tickets, so its commission method is locked. Confirm the change applies to future sales only.'
      USING ERRCODE = '22023';
  END IF;
  INSERT INTO public.exos_event_commission_settings AS x (event_id, org_id, method, locked_method, locked_at, updated_by)
  VALUES (p_event_id, v_org, p_method, CASE WHEN v_sold THEN v_new END, CASE WHEN v_sold THEN now() END, auth.uid())
  ON CONFLICT (event_id) DO UPDATE SET
    method = EXCLUDED.method,
    locked_method = CASE WHEN x.locked_method IS NOT NULL THEN v_new ELSE NULL END,
    locked_at = CASE WHEN x.locked_method IS NOT NULL THEN x.locked_at ELSE NULL END,
    updated_by = EXCLUDED.updated_by
  RETURNING * INTO s;
  INSERT INTO public.exos_commission_method_changes (org_id, scope, event_id, old_value, new_value, changed_by)
  VALUES (v_org, 'event', p_event_id, NULL, coalesce(p_method, 'org default') || CASE WHEN v_sold THEN ' (future sales)' ELSE '' END, auth.uid());
  RETURN jsonb_build_object('event_id', p_event_id, 'method', s.method, 'locked_method', s.locked_method,
                            'effective', coalesce(s.locked_method, v_new));
END $$;
REVOKE ALL ON FUNCTION public.exos_set_event_commission_method(uuid, text, boolean) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.exos_set_event_commission_method(uuid, text, boolean) TO authenticated, service_role;

-- A promoter's override (NULL: the event's / org's). Recorded sales keep the
-- method they used; only later sales follow.
CREATE OR REPLACE FUNCTION public.exos_set_promoter_commission_method(p_promoter_id uuid, p_method text)
RETURNS text
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_org uuid;
  v_old text;
BEGIN
  SELECT org_id, commission_method INTO v_org, v_old FROM public.exos_promoters WHERE id = p_promoter_id FOR UPDATE;
  IF v_org IS NULL OR NOT public.exos_has_org_role(v_org, ARRAY['owner', 'manager']) THEN
    RAISE EXCEPTION 'exos_set_promoter_commission_method: not allowed' USING ERRCODE = '42501';
  END IF;
  IF p_method IS NOT NULL AND p_method NOT IN ('clawback', 'split_at_sale', 'platform_fee', 'manual') THEN
    RAISE EXCEPTION 'Pick clawback, split at sale, inside the Exos fee, or manual.' USING ERRCODE = '22023';
  END IF;
  UPDATE public.exos_promoters SET commission_method = p_method, updated_at = now() WHERE id = p_promoter_id;
  IF p_method IS DISTINCT FROM v_old THEN
    INSERT INTO public.exos_commission_method_changes (org_id, scope, promoter_id, old_value, new_value, changed_by)
    VALUES (v_org, 'promoter', p_promoter_id, v_old, p_method, auth.uid());
  END IF;
  RETURN p_method;
END $$;
REVOKE ALL ON FUNCTION public.exos_set_promoter_commission_method(uuid, text) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.exos_set_promoter_commission_method(uuid, text) TO authenticated, service_role;

-- Every promoter's balance per currency, with netting, plus the organizer's
-- split true-ups and recent Exos transfers. A netting balance still open
-- after netting_alert_days is 'overdue': ask the promoter (or settle up).
CREATE OR REPLACE FUNCTION public.exos_commission_balances(p_org_id uuid)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_alert integer;
  v_cfg   boolean;
BEGIN
  IF NOT public.exos_has_org_role(p_org_id, ARRAY['owner', 'manager', 'finance']) THEN
    RAISE EXCEPTION 'exos_commission_balances: not allowed' USING ERRCODE = '42501';
  END IF;
  SELECT netting_alert_days INTO v_alert FROM public.exos_org_commission_settings WHERE org_id = p_org_id;
  v_cfg := v_alert IS NOT NULL;
  v_alert := coalesce(v_alert, 30);
  RETURN jsonb_build_object(
    'netting_alert_days', v_alert,
    'promoters', coalesce((
      SELECT jsonb_agg(row_to_json(b)::jsonb ORDER BY b.name, b.currency)
        FROM (
          SELECT p.id AS promoter_id, p.name, p.code, cur.currency,
                 coalesce(a.transfers_active, false) AS account_ready,
                 coalesce(m.held, 0) AS held_cents, m.held_until,
                 coalesce(m.payable_by_you, 0) AS payable_by_you_cents,
                 coalesce(m.payable_by_exos, 0) AS payable_by_exos_cents,
                 coalesce(m.processing, 0) AS processing_cents,
                 coalesce(m.paid, 0) AS paid_cents,
                 coalesce(n.owed_org, 0) AS netting_owed_to_you_cents,
                 coalesce(n.owed_platform, 0) AS netting_owed_to_exos_cents,
                 n.oldest AS netting_since,
                 (n.oldest IS NOT NULL AND n.oldest < now() - make_interval(days => v_alert)) AS netting_overdue,
                 coalesce(m.held, 0) + coalesce(m.payable_by_you, 0) + coalesce(m.payable_by_exos, 0)
                   - coalesce(n.owed_org, 0) - coalesce(n.owed_platform, 0) AS balance_cents
            FROM public.exos_promoters p
            JOIN (SELECT DISTINCT promoter_id, currency FROM public.exos_promoter_commissions WHERE org_id = p_org_id
                  UNION
                  SELECT DISTINCT promoter_id, currency FROM public.exos_commission_netting
                   WHERE org_id = p_org_id AND party = 'promoter') cur ON cur.promoter_id = p.id
            LEFT JOIN public.exos_promoter_stripe_accounts a ON a.promoter_id = p.id
            LEFT JOIN LATERAL (
              SELECT sum(c.commission_cents) FILTER (WHERE c.status = 'accrued' AND pa.at > now()) AS held,
                     min(pa.at) FILTER (WHERE c.status = 'accrued' AND pa.at > now()) AS held_until,
                     sum(c.commission_cents) FILTER (WHERE c.status = 'accrued' AND pa.at <= now()
                                                       AND c.method IN ('manual', 'clawback')) AS payable_by_you,
                     sum(c.commission_cents) FILTER (WHERE c.status = 'accrued' AND pa.at <= now()
                                                       AND c.method IN ('split_at_sale', 'platform_fee')) AS payable_by_exos,
                     sum(c.commission_cents) FILTER (WHERE c.status = 'paid' AND po.via <> 'manual'
                                                       AND po.transfer_status IS DISTINCT FROM 'sent') AS processing,
                     sum(c.commission_cents) FILTER (WHERE c.status = 'paid' AND (po.via = 'manual' OR po.transfer_status = 'sent')) AS paid
                FROM public.exos_promoter_commissions c
                LEFT JOIN public.exos_promoter_payouts po ON po.id = c.payout_id
                CROSS JOIN LATERAL (SELECT CASE WHEN NOT v_cfg AND c.method IN ('manual', 'clawback') THEN c.accrued_at
                                                ELSE public._exos_commission_payable_at(c.event_id, c.accrued_at, c.method, c.payable_at) END AS at) pa
               WHERE c.promoter_id = p.id AND c.currency = cur.currency
            ) m ON true
            LEFT JOIN LATERAL (
              SELECT -sum(x.amount_cents) FILTER (WHERE x.funder = 'organizer') AS owed_org,
                     -sum(x.amount_cents) FILTER (WHERE x.funder = 'platform') AS owed_platform,
                     min(x.created_at) AS oldest
                FROM public.exos_commission_netting x
               WHERE x.party = 'promoter' AND x.promoter_id = p.id AND x.currency = cur.currency
                 AND x.applied_payout_id IS NULL AND x.applied_transfer_id IS NULL AND x.voided_at IS NULL
            ) n ON true
           WHERE p.org_id = p_org_id
        ) b), '[]'::jsonb),
    'organizer', coalesce((
      SELECT jsonb_agg(jsonb_build_object('currency', y.currency, 'owed_to_exos_cents', y.owed, 'since', y.oldest,
                                          'overdue', y.oldest < now() - make_interval(days => v_alert),
                                          'over_cap', y.owed > public._exos_cm_setting_int('split_org_debt_cap_cents', 50000)) ORDER BY y.currency)
        FROM (SELECT x.currency, -sum(x.amount_cents) AS owed, min(x.created_at) AS oldest
                FROM public.exos_commission_netting x
               WHERE x.org_id = p_org_id AND x.party = 'organizer'
                 AND x.applied_payout_id IS NULL AND x.applied_transfer_id IS NULL AND x.voided_at IS NULL
               GROUP BY x.currency HAVING sum(x.amount_cents) <> 0) y), '[]'::jsonb),
    'transfers', coalesce((
      SELECT jsonb_agg(jsonb_build_object(
               'id', t.id, 'kind', t.kind, 'promoter', pr.name, 'session_id', t.session_id, 'currency', t.currency,
               'gross_cents', t.gross_cents, 'netted_cents', t.netted_cents, 'amount_cents', t.amount_cents,
               'status', t.status, 'error', t.error, 'alert', t.alert, 'created_at', t.created_at,
               'stripe_transfer_id', t.stripe_transfer_id) ORDER BY t.created_at DESC)
        FROM (SELECT * FROM public.exos_commission_transfers WHERE org_id = p_org_id ORDER BY created_at DESC LIMIT 50) t
        LEFT JOIN public.exos_promoters pr ON pr.id = t.promoter_id), '[]'::jsonb));
END $$;
REVOKE ALL ON FUNCTION public.exos_commission_balances(uuid) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.exos_commission_balances(uuid) TO authenticated, service_role;

-- A promoter's unpaid sales, for the settle screen: which can be paid here
-- (manual / clawback) and which are past the holdback.
CREATE OR REPLACE FUNCTION public.exos_commission_payable(p_promoter_id uuid)
RETURNS TABLE (id uuid, method text, payable_at timestamptz, payable boolean, settle_here boolean)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_org uuid;
  v_cfg boolean;
BEGIN
  SELECT org_id INTO v_org FROM public.exos_promoters WHERE exos_promoters.id = p_promoter_id;
  IF v_org IS NULL OR NOT public.exos_has_org_role(v_org, ARRAY['owner', 'manager', 'finance']) THEN
    RAISE EXCEPTION 'exos_commission_payable: not allowed' USING ERRCODE = '42501';
  END IF;
  v_cfg := EXISTS (SELECT 1 FROM public.exos_org_commission_settings s WHERE s.org_id = v_org);
  RETURN QUERY
    SELECT c.id, c.method, x.at, x.at <= now(), c.method IN ('manual', 'clawback')
      FROM public.exos_promoter_commissions c
      CROSS JOIN LATERAL (SELECT CASE WHEN NOT v_cfg AND c.method IN ('manual', 'clawback') THEN c.accrued_at
                                      ELSE public._exos_commission_payable_at(c.event_id, c.accrued_at, c.method, c.payable_at) END AS at) x
     WHERE c.promoter_id = p_promoter_id AND c.status = 'accrued'
     ORDER BY c.accrued_at, c.id
     LIMIT 2000;
END $$;
REVOKE ALL ON FUNCTION public.exos_commission_payable(uuid) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.exos_commission_payable(uuid) TO authenticated, service_role;

-- ===========================================================================
-- 12. Replaced (same signatures, same bodies but for the lines marked):
--     clawback netting in the organizer's payouts only nets organizer-funded
--     lines (_exos_pc_funder); platform-funded ones are netted by Exos
--     transfers, so a refund Exos absorbed is never repaid to the organizer.
--     And a promoter is asked to set up a payout account when the org pays
--     by any Stripe method, not only clawback transfers.
--     exos_settle_promoter       from 20261102150000 (+ funder filter x2)
--     exos_record_promoter_payout from 20260926020000 (+ funder filter x2)
--     exos_org_promoter_commissions from 20260926020000 (clawback: + filter)
--     exos_promoter_by_token, exos_promoter_earnings from 20261102150000
--       (transfers_enabled = _exos_org_promoter_stripe_needed)
-- ===========================================================================
CREATE OR REPLACE FUNCTION public.exos_settle_promoter(
  p_promoter_id     uuid,
  p_commission_ids  uuid[],
  p_amount_cents    integer,
  p_method          text,
  p_idempotency_key text,
  p_via             text DEFAULT 'manual',
  p_note            text DEFAULT NULL,
  p_paid_on         date DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_org    uuid;
  v_ids    uuid[];
  v_found  integer;
  v_cur    text;
  v_ncur   integer;
  v_sum    bigint;
  v_claw   bigint;
  v_net    bigint;
  v_left   bigint;
  v_take   bigint;
  v_id     uuid;
  v_acct   text;
  v_old    public.exos_promoter_payouts%ROWTYPE;
  v_via    text := lower(btrim(coalesce(p_via, 'manual')));
  v_method text := btrim(coalesce(p_method, ''));
  r        record;
BEGIN
  SELECT org_id INTO v_org FROM public.exos_promoters WHERE id = p_promoter_id FOR UPDATE;
  IF v_org IS NULL OR NOT public.exos_has_org_role(v_org, ARRAY['owner', 'manager']) THEN
    RAISE EXCEPTION 'exos_settle_promoter: not allowed' USING ERRCODE = '42501';
  END IF;
  IF p_idempotency_key IS NULL OR p_idempotency_key !~ '^[A-Za-z0-9_-]{8,80}$' THEN
    RAISE EXCEPTION 'exos_settle_promoter: idempotency key must be 8-80 letters, digits, - or _' USING ERRCODE = '22023';
  END IF;

  -- A retry (double click, dropped connection) returns the first answer.
  SELECT * INTO v_old FROM public.exos_promoter_payouts
   WHERE promoter_id = p_promoter_id AND idempotency_key = p_idempotency_key;
  IF v_old.id IS NOT NULL THEN
    IF v_old.amount_cents IS DISTINCT FROM p_amount_cents OR v_old.via <> v_via THEN
      RAISE EXCEPTION 'That payout key was already used for a different payout. Reload and try again.' USING ERRCODE = '22023';
    END IF;
    RETURN jsonb_build_object('payout_id', v_old.id, 'replayed', true, 'via', v_old.via,
                              'transfer_status', v_old.transfer_status, 'amount_cents', v_old.amount_cents);
  END IF;

  IF v_via NOT IN ('manual', 'stripe') THEN
    RAISE EXCEPTION 'Pay out manually or by Stripe transfer.' USING ERRCODE = '22023';
  END IF;
  IF v_via = 'stripe' THEN
    v_method := 'Stripe transfer';
    IF NOT coalesce((SELECT stripe_transfers FROM public.exos_org_promoter_payouts WHERE org_id = v_org), false) THEN
      RAISE EXCEPTION 'Stripe payouts to promoters are off for this organization (the owner turns them on).' USING ERRCODE = '42501';
    END IF;
    SELECT stripe_account_id INTO v_acct FROM public.exos_promoter_stripe_accounts
     WHERE promoter_id = p_promoter_id AND transfers_active;
    IF v_acct IS NULL THEN
      RAISE EXCEPTION 'This promoter hasn''t finished setting up Stripe payouts yet.' USING ERRCODE = '22023';
    END IF;
  END IF;
  IF length(v_method) NOT BETWEEN 1 AND 60 THEN
    RAISE EXCEPTION 'Say how you paid (e.g. Venmo), up to 60 characters.' USING ERRCODE = '22023';
  END IF;
  IF p_note IS NOT NULL AND length(p_note) > 500 THEN
    RAISE EXCEPTION 'Note is too long (500 characters max).' USING ERRCODE = '22023';
  END IF;
  SELECT array_agg(DISTINCT x) INTO v_ids FROM unnest(p_commission_ids) x WHERE x IS NOT NULL;
  IF coalesce(cardinality(v_ids), 0) = 0 THEN
    RAISE EXCEPTION 'Pick at least one sale to pay out.' USING ERRCODE = '22023';
  END IF;

  PERFORM 1 FROM public.exos_promoter_commissions WHERE id = ANY (v_ids) ORDER BY id FOR UPDATE;
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
     AND payout_id IS NOT NULL AND recovered_payout_id IS NULL
     AND public._exos_pc_funder(id, method) = 'organizer';
  v_net := v_sum - v_claw;
  IF v_net < 0 THEN
    RAISE EXCEPTION 'Refunds on already-paid sales (%) are more than this payout. Nothing is owed yet.', v_claw
      USING ERRCODE = '22023';
  END IF;
  IF p_amount_cents IS DISTINCT FROM v_net::integer THEN
    RAISE EXCEPTION 'Amount doesn''t match the selected sales (expected % cents). Reload and try again.', v_net
      USING ERRCODE = '22023';
  END IF;
  IF v_via = 'stripe' AND v_net = 0 THEN
    RAISE EXCEPTION 'Nothing to send: refunds already cover these sales. Record it manually instead.' USING ERRCODE = '22023';
  END IF;

  INSERT INTO public.exos_promoter_payouts (
    org_id, promoter_id, currency, amount_cents, commission_cents, clawback_cents,
    row_count, method, note, paid_on, created_by, idempotency_key, via, transfer_status, stripe_account_id
  ) VALUES (
    v_org, p_promoter_id, v_cur, p_amount_cents, v_sum, v_claw,
    cardinality(v_ids), v_method, NULLIF(btrim(coalesce(p_note, '')), ''),
    coalesce(p_paid_on, current_date), auth.uid(), p_idempotency_key, v_via,
    CASE WHEN v_via = 'stripe' THEN 'pending' END, v_acct
  ) RETURNING id INTO v_id;

  IF v_via = 'stripe' THEN
    -- Fund the net from the orders behind the selected sales, never more per
    -- order than (a) the selected commission from it and (b) what the
    -- organizer still holds from it. Oldest orders first.
    v_left := v_net;
    FOR r IN
      SELECT s.session_id, op.transfer_id,
             sum(c.commission_cents)::bigint AS commission,
             (s.amount_cents - coalesce(s.application_fee_cents, 0)
               - coalesce((SELECT sum(rf.amount_cents) FROM public.exos_order_refunds rf
                            WHERE rf.session_id = s.session_id AND rf.status = 'succeeded'), 0)
               - coalesce((SELECT sum(f.amount_cents) FROM public.exos_promoter_payout_funding f
                            WHERE f.session_id = s.session_id AND f.status IN ('planned', 'taken')), 0))::bigint AS headroom,
             min(s.created_at) AS created_at
        FROM public.exos_promoter_commissions c
        JOIN public.exos_tickets t ON t.id = c.ticket_id
        JOIN public.exos_checkout_sessions s ON s.session_id = t.order_ref
        JOIN LATERAL (SELECT op2.transfer_id FROM public.exos_order_payments op2
                       WHERE op2.session_id = s.session_id AND op2.status = 'succeeded' AND op2.transfer_id IS NOT NULL
                       ORDER BY op2.created_at DESC LIMIT 1) op ON true
       WHERE c.id = ANY (v_ids) AND coalesce(s.processor, 'stripe') = 'stripe'
       GROUP BY s.session_id, op.transfer_id, s.amount_cents, s.application_fee_cents
       ORDER BY min(s.created_at), s.session_id
    LOOP
      EXIT WHEN v_left <= 0;
      v_take := least(v_left, r.commission, greatest(r.headroom, 0));
      IF v_take > 0 THEN
        INSERT INTO public.exos_promoter_payout_funding (payout_id, session_id, org_id, org_transfer_id, amount_cents)
        VALUES (v_id, r.session_id, v_org, r.transfer_id, v_take);
        v_left := v_left - v_take;
      END IF;
    END LOOP;
    IF EXISTS (SELECT 1 FROM public.exos_promoter_commissions c
                 LEFT JOIN public.exos_tickets t ON t.id = c.ticket_id
                WHERE c.id = ANY (v_ids)
                  AND NOT EXISTS (SELECT 1 FROM public.exos_checkout_sessions s
                                    JOIN public.exos_order_payments op ON op.session_id = s.session_id
                                   WHERE s.session_id = t.order_ref AND coalesce(s.processor, 'stripe') = 'stripe'
                                     AND op.status = 'succeeded' AND op.transfer_id IS NOT NULL)) THEN
      RAISE EXCEPTION 'Some selected sales weren''t paid to you through Stripe (door, PayPal or staff-issued). Pay those manually.'
        USING ERRCODE = '22023';
    END IF;
    -- Bounded work per send (one reversal per line + the transfer), so the
    -- worst case fits the lease: MAX_FUNDING_LINES in promoterTransfers.ts.
    IF (SELECT count(*) FROM public.exos_promoter_payout_funding WHERE payout_id = v_id) > 10 THEN
      RAISE EXCEPTION 'Pay at most 10 orders in one Stripe payout; select fewer sales.' USING ERRCODE = '22023';
    END IF;
    IF v_left > 0 THEN
      RAISE EXCEPTION 'That is more than you have received for these orders (short by % cents after refunds and earlier payouts).', v_left
        USING ERRCODE = '22023';
    END IF;
  END IF;

  UPDATE public.exos_promoter_commissions
     SET status = 'paid', payout_id = v_id, paid_at = now(), updated_at = now()
   WHERE id = ANY (v_ids);
  UPDATE public.exos_promoter_commissions
     SET recovered_payout_id = v_id, updated_at = now()
   WHERE promoter_id = p_promoter_id AND currency = v_cur AND status = 'reversed'
     AND payout_id IS NOT NULL AND recovered_payout_id IS NULL
     AND public._exos_pc_funder(id, method) = 'organizer';
  RETURN jsonb_build_object('payout_id', v_id, 'replayed', false, 'via', v_via,
                            'transfer_status', CASE WHEN v_via = 'stripe' THEN 'pending' END,
                            'amount_cents', p_amount_cents);
END $$;
REVOKE ALL ON FUNCTION public.exos_settle_promoter(uuid, uuid[], integer, text, text, text, text, date) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.exos_settle_promoter(uuid, uuid[], integer, text, text, text, text, date) TO authenticated, service_role;

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
  IF v_org IS NULL OR NOT public.exos_has_org_role(v_org, ARRAY['owner', 'manager']) THEN
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
     AND payout_id IS NOT NULL AND recovered_payout_id IS NULL
     AND public._exos_pc_funder(id, method) = 'organizer';
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
     AND payout_id IS NOT NULL AND recovered_payout_id IS NULL
     AND public._exos_pc_funder(id, method) = 'organizer';
  RETURN v_id;
END $$;
REVOKE ALL ON FUNCTION public.exos_record_promoter_payout(uuid, uuid[], integer, text, text, date) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.exos_record_promoter_payout(uuid, uuid[], integer, text, text, date) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.exos_org_promoter_commissions(p_org_id uuid, p_event_id uuid DEFAULT NULL)
RETURNS TABLE (
  promoter_id uuid, code text, name text, status text, rate_bps integer, flat_cents integer,
  currency text, tickets bigint, gross_cents bigint, base_cents bigint,
  accrued_cents bigint, reversed_cents bigint, paid_cents bigint, clawback_cents bigint, owed_cents bigint
)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF NOT public.exos_has_org_role(p_org_id, ARRAY['owner', 'manager', 'finance']) THEN
    RAISE EXCEPTION 'exos_org_promoter_commissions: not allowed' USING ERRCODE = '42501';
  END IF;
  RETURN QUERY
    SELECT p.id, p.code, p.name, p.status, p.commission_bps, p.commission_flat_cents,
           c.currency,
           count(c.id) FILTER (WHERE c.status <> 'reversed'),
           coalesce(sum(c.gross_cents) FILTER (WHERE c.status <> 'reversed'), 0)::bigint,
           coalesce(sum(c.base_cents) FILTER (WHERE c.status <> 'reversed'), 0)::bigint,
           coalesce(sum(c.commission_cents) FILTER (WHERE c.status = 'accrued'), 0)::bigint,
           coalesce(sum(c.commission_cents) FILTER (WHERE c.status = 'reversed'), 0)::bigint,
           coalesce(sum(c.commission_cents) FILTER (WHERE c.status = 'paid'), 0)::bigint,
           coalesce(sum(c.commission_cents) FILTER (WHERE c.status = 'reversed' AND c.payout_id IS NOT NULL
                                                      AND c.recovered_payout_id IS NULL
                                                      AND public._exos_pc_funder(c.id, c.method) = 'organizer'), 0)::bigint,
           (coalesce(sum(c.commission_cents) FILTER (WHERE c.status = 'accrued'), 0)
            - coalesce(sum(c.commission_cents) FILTER (WHERE c.status = 'reversed' AND c.payout_id IS NOT NULL
                                                        AND c.recovered_payout_id IS NULL
                                                      AND public._exos_pc_funder(c.id, c.method) = 'organizer'), 0))::bigint
      FROM public.exos_promoters p
      LEFT JOIN public.exos_promoter_commissions c
             ON c.promoter_id = p.id AND (p_event_id IS NULL OR c.event_id = p_event_id)
     WHERE p.org_id = p_org_id
     GROUP BY p.id, p.code, p.name, p.status, p.commission_bps, p.commission_flat_cents, c.currency
     ORDER BY 15 DESC, p.name;
END $$;
REVOKE ALL ON FUNCTION public.exos_org_promoter_commissions(uuid, uuid) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.exos_org_promoter_commissions(uuid, uuid) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.exos_promoter_by_token(p_token uuid)
RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT jsonb_build_object('promoter_id', p.id, 'org_id', p.org_id, 'name', p.name, 'email', p.email,
                            'org_name', o.name,
                            'transfers_enabled', public._exos_org_promoter_stripe_needed(p.org_id),
                            'stripe_account_id', a.stripe_account_id,
                            'transfers_active', coalesce(a.transfers_active, false))
    FROM public.exos_promoters p
    JOIN public.exos_orgs o ON o.id = p.org_id
    LEFT JOIN public.exos_org_promoter_payouts s ON s.org_id = p.org_id
    LEFT JOIN public.exos_promoter_stripe_accounts a ON a.promoter_id = p.id
   WHERE p.kit_token = p_token AND p.status = 'active'
$$;
REVOKE ALL ON FUNCTION public.exos_promoter_by_token(uuid) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.exos_promoter_by_token(uuid) TO service_role;

CREATE OR REPLACE FUNCTION public.exos_promoter_earnings(p_token uuid)
RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT jsonb_build_object(
    'promoter', jsonb_build_object('name', p.name, 'code', p.code),
    'terms', jsonb_build_object('rate_bps', p.commission_bps, 'flat_cents', p.commission_flat_cents,
                                'step_after', p.step_after, 'step_rate_bps', p.step_rate_bps,
                                'step_flat_cents', p.step_flat_cents),
    'payout_account', jsonb_build_object(
      'transfers_enabled', public._exos_org_promoter_stripe_needed(p.org_id),
      'connected', EXISTS (SELECT 1 FROM public.exos_promoter_stripe_accounts a WHERE a.promoter_id = p.id),
      'ready', coalesce((SELECT a.transfers_active FROM public.exos_promoter_stripe_accounts a WHERE a.promoter_id = p.id), false)),
    'totals', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
               'currency', x.currency, 'tickets', x.tickets, 'sales_cents', x.sales, 'accrued_cents', x.accrued,
               'paid_cents', x.paid, 'processing_cents', x.processing, 'reversed_cents', x.reversed,
               'clawback_cents', x.claw, 'owed_cents', x.accrued - x.claw) ORDER BY x.currency)
        FROM (
          SELECT c.currency,
                 count(*) FILTER (WHERE c.status <> 'reversed') AS tickets,
                 coalesce(sum(c.base_cents) FILTER (WHERE c.status <> 'reversed'), 0) AS sales,
                 coalesce(sum(c.commission_cents) FILTER (WHERE c.status = 'accrued'), 0) AS accrued,
                 coalesce(sum(c.commission_cents) FILTER (WHERE c.status = 'paid'
                            AND coalesce(po.transfer_status, 'sent') = 'sent'), 0) AS paid,
                 coalesce(sum(c.commission_cents) FILTER (WHERE c.status = 'paid'
                            AND po.transfer_status IN ('pending', 'sending', 'dry_run', 'failed', 'cancel_pending', 'return_pending')), 0) AS processing,
                 coalesce(sum(c.commission_cents) FILTER (WHERE c.status = 'reversed'), 0) AS reversed,
                 coalesce(sum(c.commission_cents) FILTER (WHERE c.status = 'reversed' AND c.payout_id IS NOT NULL
                                                            AND c.recovered_payout_id IS NULL), 0) AS claw
            FROM public.exos_promoter_commissions c
            LEFT JOIN public.exos_promoter_payouts po ON po.id = c.payout_id
           WHERE c.promoter_id = p.id
           GROUP BY c.currency
        ) x
    ), '[]'::jsonb),
    'events', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
               'event_id', e.id, 'name', e.name, 'starts_at', e.starts_at, 'currency', y.currency,
               'rate_bps', CASE WHEN o.promoter_id IS NOT NULL THEN o.rate_bps ELSE p.commission_bps END,
               'flat_cents', CASE WHEN o.promoter_id IS NOT NULL THEN o.flat_cents ELSE p.commission_flat_cents END,
               'step_after', CASE WHEN o.promoter_id IS NOT NULL THEN o.step_after ELSE p.step_after END,
               'step_rate_bps', CASE WHEN o.promoter_id IS NOT NULL THEN o.step_rate_bps ELSE p.step_rate_bps END,
               'step_flat_cents', CASE WHEN o.promoter_id IS NOT NULL THEN o.step_flat_cents ELSE p.step_flat_cents END,
               'tickets', y.tickets, 'base_cents', y.base, 'accrued_cents', y.accrued,
               'paid_cents', y.paid, 'reversed_cents', y.reversed)
             ORDER BY e.starts_at DESC NULLS LAST)
        FROM (
          SELECT c.event_id, c.currency,
                 count(*) FILTER (WHERE c.status <> 'reversed') AS tickets,
                 coalesce(sum(c.base_cents) FILTER (WHERE c.status <> 'reversed'), 0) AS base,
                 coalesce(sum(c.commission_cents) FILTER (WHERE c.status = 'accrued'), 0) AS accrued,
                 coalesce(sum(c.commission_cents) FILTER (WHERE c.status = 'paid'), 0) AS paid,
                 coalesce(sum(c.commission_cents) FILTER (WHERE c.status = 'reversed'), 0) AS reversed
            FROM public.exos_promoter_commissions c
           WHERE c.promoter_id = p.id
           GROUP BY c.event_id, c.currency
        ) y
        JOIN public.exos_events e ON e.id = y.event_id
        LEFT JOIN public.exos_promoter_event_terms o ON o.promoter_id = p.id AND o.event_id = e.id
    ), '[]'::jsonb),
    'payouts', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
               'paid_on', po.paid_on, 'amount_cents', po.amount_cents, 'currency', po.currency,
               'method', po.method, 'sales', po.row_count, 'via', po.via,
               'status', CASE WHEN po.via = 'manual' THEN 'paid'
                              WHEN po.transfer_status = 'sent' THEN 'paid'
                              ELSE 'processing' END)
             ORDER BY po.paid_on DESC, po.created_at DESC)
        FROM public.exos_promoter_payouts po
       WHERE po.promoter_id = p.id AND po.cancelled_at IS NULL
    ), '[]'::jsonb),
    'as_of', to_char(now() AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')
  )
  FROM public.exos_promoters p
  WHERE p.kit_token = p_token AND p.status = 'active';
$$;
REVOKE ALL ON FUNCTION public.exos_promoter_earnings(uuid) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.exos_promoter_earnings(uuid) TO anon, authenticated, service_role;

-- ===========================================================================
-- 14. Organizer refunds of Exos-funded orders (service role: refundRun, for
--     exos-refund and exos-api). Exos never pays for a refund out of its own
--     balance beyond the fee it collected:
--       split order, organizer's share already sent: before the refund, the
--         organizer's part of it is taken back from that transfer (a Stripe
--         transfer reversal, exos_split_reversals: lease, reconcile, key
--         exos-ctr:<id>). If the transfer can't cover it the refund is
--         refused, saying how much can be refunded. A share not sent yet is
--         cancelled and planned again from the smaller order.
--       platform_fee order whose commission already went out: the refund
--         keeps the fee (refund_application_fee off; the organizer bears
--         the refund, like a clawback) and the promoter's clawback is owed to
--         the organizer (exos_commission_refund_marks). Otherwise the fee
--         goes back in proportion.
--     True-up / netting stays only as the fallback (refunds outside Exos,
--     disputes, a reversal that couldn't be taken), with an alert and the
--     debt cap.
-- ===========================================================================
CREATE TABLE IF NOT EXISTS public.exos_refund_charge_plans (
  request_id uuid PRIMARY KEY REFERENCES public.exos_refund_requests (id) ON DELETE CASCADE,
  session_id text NOT NULL REFERENCES public.exos_checkout_sessions (session_id) ON DELETE CASCADE,
  org_id     uuid NOT NULL REFERENCES public.exos_orgs (id) ON DELETE CASCADE,
  -- standard (as before), commission_fee (fee always refunded), keep_fee,
  -- split (no Connect flags), reverse (split, after a transfer reversal).
  mode       text NOT NULL CHECK (mode IN ('standard', 'commission_fee', 'keep_fee', 'split', 'reverse')),
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.exos_split_reversals (
  id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id             uuid NOT NULL REFERENCES public.exos_orgs (id) ON DELETE CASCADE,
  session_id         text NOT NULL REFERENCES public.exos_checkout_sessions (session_id) ON DELETE CASCADE,
  ct_id              uuid NOT NULL REFERENCES public.exos_commission_transfers (id) ON DELETE CASCADE,
  request_id         uuid NOT NULL UNIQUE REFERENCES public.exos_refund_requests (id) ON DELETE CASCADE,
  org_transfer_id    text NOT NULL CHECK (org_transfer_id ~ '^tr_[A-Za-z0-9]{1,64}$'),
  amount_cents       integer NOT NULL CHECK (amount_cents > 0),
  status             text NOT NULL DEFAULT 'planned' CHECK (status IN ('planned', 'taken', 'failed')),
  stripe_reversal_id text CHECK (stripe_reversal_id IS NULL OR stripe_reversal_id ~ '^trr_[A-Za-z0-9]{1,64}$'),
  error              text CHECK (error IS NULL OR length(error) <= 300),
  lease_token        uuid,
  lease_until        timestamptz,
  started_at         timestamptz,
  reconciled_at      timestamptz,
  created_at         timestamptz NOT NULL DEFAULT now(),
  updated_at         timestamptz NOT NULL DEFAULT now(),
  CHECK (status <> 'taken' OR stripe_reversal_id IS NOT NULL)
);
CREATE INDEX IF NOT EXISTS exos_split_reversals_ct_idx ON public.exos_split_reversals (ct_id);
CREATE INDEX IF NOT EXISTS exos_split_reversals_session_idx ON public.exos_split_reversals (session_id);
DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['exos_refund_charge_plans', 'exos_split_reversals'] LOOP
    EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY', t);
    EXECUTE format('REVOKE ALL ON public.%I FROM PUBLIC, anon, authenticated', t);
    EXECUTE format('GRANT SELECT ON public.%I TO authenticated', t);
    EXECUTE format('GRANT ALL ON public.%I TO service_role', t);
    EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I', t || '_staff_read', t);
    EXECUTE format('CREATE POLICY %I ON public.%I FOR SELECT TO authenticated
                    USING (public.exos_has_org_role(org_id, ARRAY[''owner'', ''manager'', ''finance'']))',
                   t || '_staff_read', t);
  END LOOP;
END $$;
DROP TRIGGER IF EXISTS exos_split_reversals_touch ON public.exos_split_reversals;
CREATE TRIGGER exos_split_reversals_touch BEFORE UPDATE ON public.exos_split_reversals
  FOR EACH ROW EXECUTE FUNCTION public.exos_touch_updated_at();

-- How to refund one claimed organizer refund request. Decided once per
-- request (exos_refund_charge_plans), so every retry sends Stripe the same
-- parameters. Answers {mode, ...}:
--   standard / commission_fee / keep_fee / split   refund with those flags
--   reverse   {reversal_id, org_transfer_id, amount_cents}: take that from
--             the organizer's transfer first (exos_split_reversal_claim ...)
--   busy      an Exos transfer for this order is in flight: try again later
--   refuse    {recoverable_cents, max_refund_cents}: Exos can't take enough
--             back from the organizer's transfer
CREATE OR REPLACE FUNCTION public.exos_refund_charge_prepare(p_request_id uuid)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  rq      public.exos_refund_requests%ROWTYPE;
  s       public.exos_checkout_sessions%ROWTYPE;
  pl      public.exos_checkout_commission_plans%ROWTYPE;
  cp      public.exos_refund_charge_plans%ROWTYPE;
  ct      public.exos_commission_transfers%ROWTYPE;
  rv      public.exos_split_reversals%ROWTYPE;
  e       record;
  v_mode  text;
  v_ref   bigint;
  v_net   bigint;
  v_fee   bigint;
  v_after bigint;
  v_rec   bigint;
  v_req   bigint;
  v_rev   bigint;
  v_max   bigint;
BEGIN
  SELECT * INTO rq FROM public.exos_refund_requests WHERE id = p_request_id;
  IF rq.id IS NULL THEN RETURN jsonb_build_object('mode', 'standard'); END IF;
  SELECT * INTO cp FROM public.exos_refund_charge_plans WHERE request_id = p_request_id;
  IF cp.request_id IS NOT NULL AND cp.mode <> 'reverse' THEN
    RETURN jsonb_build_object('mode', cp.mode);
  END IF;
  SELECT * INTO pl FROM public.exos_checkout_commission_plans WHERE session_id = rq.session_id;
  IF pl.session_id IS NULL OR (pl.charge_model = 'destination' AND pl.commission_fee_cents = 0) THEN
    RETURN jsonb_build_object('mode', 'standard');
  END IF;

  IF pl.charge_model = 'destination' THEN
    -- platform_fee: the commission rides in the fee.
    IF EXISTS (SELECT 1 FROM public.exos_commission_refund_marks WHERE session_id = rq.session_id)
       OR EXISTS (SELECT 1 FROM public.exos_promoter_commissions c
                    JOIN public.exos_promoter_payouts po ON po.id = c.payout_id
                   WHERE c.session_id = rq.session_id AND po.cancelled_at IS NULL) THEN
      v_mode := 'keep_fee';
      INSERT INTO public.exos_commission_refund_marks (session_id, org_id, reason)
      VALUES (rq.session_id, rq.org_id, 'refunded after the commission went out; the refund kept the fee')
      ON CONFLICT (session_id) DO NOTHING;
    ELSE
      v_mode := 'commission_fee';
    END IF;
    INSERT INTO public.exos_refund_charge_plans (request_id, session_id, org_id, mode)
    VALUES (p_request_id, rq.session_id, rq.org_id, v_mode) ON CONFLICT (request_id) DO NOTHING;
    RETURN jsonb_build_object('mode', v_mode);
  END IF;

  -- Split at sale.
  PERFORM pg_advisory_xact_lock(hashtextextended('exos-split:' || rq.session_id, 0));
  SELECT * INTO rv FROM public.exos_split_reversals WHERE request_id = p_request_id;
  IF rv.id IS NOT NULL THEN
    IF rv.status = 'failed' THEN
      RETURN jsonb_build_object('mode', 'refuse', 'error', coalesce(rv.error, 'the reversal failed'), 'recoverable_cents', 0);
    END IF;
    RETURN jsonb_build_object('mode', 'reverse', 'reversal_id', rv.id, 'org_transfer_id', rv.org_transfer_id,
                              'amount_cents', rv.amount_cents, 'status', rv.status, 'stripe_reversal_id', rv.stripe_reversal_id);
  END IF;
  SELECT * INTO ct FROM public.exos_commission_transfers
   WHERE kind = 'split_org' AND session_id = rq.session_id AND status <> 'cancelled' FOR UPDATE;
  IF ct.id IS NOT NULL AND ct.status IN ('planned', 'dry_run', 'failed')
     AND (ct.lease_until IS NULL OR ct.lease_until <= now())
     AND NOT (ct.send_started_at IS NOT NULL AND (ct.reconciled_at IS NULL OR ct.reconciled_at < ct.send_started_at))
     AND NOT EXISTS (SELECT 1 FROM public.exos_commission_netting n
                      WHERE n.session_id = ct.session_id AND n.kind = 'true_up' AND n.voided_at IS NULL) THEN
    -- Not sent: cancel it; the next run plans the smaller share.
    UPDATE public.exos_commission_netting SET voided_at = now() WHERE carried_from = ct.id AND voided_at IS NULL;
    UPDATE public.exos_commission_netting SET applied_transfer_id = NULL, applied_at = NULL WHERE applied_transfer_id = ct.id;
    UPDATE public.exos_commission_transfers
       SET status = 'cancelled', cancelled_at = now(), lease_until = NULL, lease_token = NULL,
           error = 'cancelled by a refund before it went out'
     WHERE id = ct.id;
    ct := NULL;
  END IF;
  IF ct.id IS NULL THEN
    INSERT INTO public.exos_refund_charge_plans (request_id, session_id, org_id, mode)
    VALUES (p_request_id, rq.session_id, rq.org_id, 'split') ON CONFLICT (request_id) DO NOTHING;
    RETURN jsonb_build_object('mode', 'split');
  END IF;
  IF ct.status NOT IN ('sent', 'netted') THEN
    RETURN jsonb_build_object('mode', 'busy', 'error', 'Exos is paying out your share of this order right now');
  END IF;

  -- Sent (or fully netted): the organizer's part of this refund.
  SELECT * INTO e FROM public._exos_split_entitlement(rq.session_id);
  SELECT coalesce(sum(amount_cents), 0) INTO v_ref FROM public.exos_order_refunds
   WHERE session_id = rq.session_id AND status IN ('succeeded', 'pending');
  SELECT * INTO s FROM public.exos_checkout_sessions WHERE session_id = rq.session_id;
  v_ref := least(v_ref + rq.amount_cents, s.amount_cents);
  v_net := greatest(s.amount_cents - v_ref, 0);
  v_fee := CASE WHEN s.amount_cents <= 0 THEN 0
                ELSE pl.application_fee_cents - floor(pl.application_fee_cents::numeric * v_ref / s.amount_cents)::bigint END;
  v_after := greatest(v_net - v_fee - e.commission, 0);
  SELECT -coalesce(sum(amount_cents), 0) INTO v_rec FROM public.exos_commission_netting
   WHERE party = 'organizer' AND kind = 'true_up' AND session_id = rq.session_id AND voided_at IS NULL;
  v_rec := v_rec + coalesce((SELECT sum(amount_cents) FROM public.exos_split_reversals
                              WHERE session_id = rq.session_id AND status IN ('planned', 'taken')), 0);
  v_req := (ct.gross_cents - v_after) - v_rec;
  IF v_req <= 0 THEN
    INSERT INTO public.exos_refund_charge_plans (request_id, session_id, org_id, mode)
    VALUES (p_request_id, rq.session_id, rq.org_id, 'split') ON CONFLICT (request_id) DO NOTHING;
    RETURN jsonb_build_object('mode', 'split');
  END IF;
  v_rev := CASE WHEN ct.status = 'sent' THEN ct.amount_cents ELSE 0 END
         - coalesce((SELECT sum(amount_cents) FROM public.exos_split_reversals
                      WHERE ct_id = ct.id AND status IN ('planned', 'taken')), 0);
  IF v_req > v_rev THEN
    -- The most this request could refund with what can still be taken back
    -- (each cent of refund needs about 1 - fee share of the organizer).
    v_max := greatest(rq.amount_cents - (v_req - greatest(v_rev, 0)), 0);
    RETURN jsonb_build_object('mode', 'refuse', 'recoverable_cents', greatest(v_rev, 0), 'needed_cents', v_req,
                              'max_refund_cents', v_max,
                              'error', 'Exos can take back only ' || greatest(v_rev, 0) || ' cents of your share of this order (it needs '
                                       || v_req || '), so this refund is refused. Refund less, or contact Exos.');
  END IF;
  INSERT INTO public.exos_split_reversals (org_id, session_id, ct_id, request_id, org_transfer_id, amount_cents)
  VALUES (rq.org_id, rq.session_id, ct.id, p_request_id, ct.stripe_transfer_id, v_req::integer)
  RETURNING * INTO rv;
  INSERT INTO public.exos_refund_charge_plans (request_id, session_id, org_id, mode)
  VALUES (p_request_id, rq.session_id, rq.org_id, 'reverse') ON CONFLICT (request_id) DO NOTHING;
  RETURN jsonb_build_object('mode', 'reverse', 'reversal_id', rv.id, 'org_transfer_id', rv.org_transfer_id,
                            'amount_cents', rv.amount_cents, 'status', rv.status, 'stripe_reversal_id', NULL);
END $$;
REVOKE ALL ON FUNCTION public.exos_refund_charge_prepare(uuid) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.exos_refund_charge_prepare(uuid) TO service_role;

-- Lease a planned reversal (6 minutes, never extended). needs_reconcile when
-- an earlier attempt started and was never reconciled: list the transfer's
-- reversals first (metadata exos_split_reversal_id).
CREATE OR REPLACE FUNCTION public.exos_split_reversal_claim(p_id uuid)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  rv    public.exos_split_reversals%ROWTYPE;
  v_tok uuid := gen_random_uuid();
BEGIN
  SELECT * INTO rv FROM public.exos_split_reversals WHERE id = p_id FOR UPDATE;
  IF rv.id IS NULL THEN RETURN jsonb_build_object('ok', false, 'error', 'not_found'); END IF;
  IF rv.status <> 'planned' THEN RETURN jsonb_build_object('ok', false, 'error', rv.status, 'stripe_reversal_id', rv.stripe_reversal_id); END IF;
  IF rv.lease_until > now() THEN RETURN jsonb_build_object('ok', false, 'error', 'busy'); END IF;
  UPDATE public.exos_split_reversals
     SET lease_token = v_tok, lease_until = now() + interval '6 minutes',
         started_at = CASE WHEN started_at IS NOT NULL AND (reconciled_at IS NULL OR reconciled_at < started_at)
                           THEN started_at ELSE clock_timestamp() END
   WHERE id = rv.id;
  RETURN jsonb_build_object('ok', true, 'id', rv.id, 'lease_token', v_tok, 'org_transfer_id', rv.org_transfer_id,
                            'amount_cents', rv.amount_cents,
                            'needs_reconcile', rv.started_at IS NOT NULL AND (rv.reconciled_at IS NULL OR rv.reconciled_at < rv.started_at));
END $$;
REVOKE ALL ON FUNCTION public.exos_split_reversal_claim(uuid) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.exos_split_reversal_claim(uuid) TO service_role;

-- The outcome, by the lease holder: 'taken' with the trr_ id (also what a
-- reconcile found), 'reconciled' (nothing found: may create now), or
-- 'failed' (Stripe refused: the refund is refused too). 'taken' always wins.
CREATE OR REPLACE FUNCTION public.exos_split_reversal_mark(p_id uuid, p_lease_token uuid, p_status text, p_reversal_id text DEFAULT NULL, p_error text DEFAULT NULL)
RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  rv  public.exos_split_reversals%ROWTYPE;
BEGIN
  IF p_status NOT IN ('taken', 'reconciled', 'failed') THEN
    RAISE EXCEPTION 'exos_split_reversal_mark: bad status' USING ERRCODE = '22023';
  END IF;
  SELECT * INTO rv FROM public.exos_split_reversals WHERE id = p_id FOR UPDATE;
  IF rv.id IS NULL THEN RETURN false; END IF;
  IF p_status = 'taken' THEN
    IF p_reversal_id IS NULL OR p_reversal_id !~ '^trr_[A-Za-z0-9]{1,64}$' THEN
      RAISE EXCEPTION 'exos_split_reversal_mark: taken needs a reversal id' USING ERRCODE = '22023';
    END IF;
    IF rv.status = 'taken' THEN RETURN rv.stripe_reversal_id = p_reversal_id; END IF;
    UPDATE public.exos_split_reversals
       SET status = 'taken', stripe_reversal_id = p_reversal_id, error = NULL, lease_until = NULL, lease_token = NULL,
           reconciled_at = clock_timestamp()
     WHERE id = rv.id;
    RETURN true;
  END IF;
  IF rv.status <> 'planned' OR rv.lease_token IS DISTINCT FROM p_lease_token THEN RETURN false; END IF;
  UPDATE public.exos_split_reversals
     SET status = CASE WHEN p_status = 'failed' THEN 'failed' ELSE status END,
         error = CASE WHEN p_status = 'failed' THEN left(coalesce(p_error, 'failed'), 300) ELSE error END,
         reconciled_at = clock_timestamp(),
         lease_until = CASE WHEN p_status = 'failed' THEN NULL ELSE lease_until END
   WHERE id = rv.id;
  RETURN true;
END $$;
REVOKE ALL ON FUNCTION public.exos_split_reversal_mark(uuid, uuid, text, text, text) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.exos_split_reversal_mark(uuid, uuid, text, text, text) TO service_role;

-- The refund after a taken reversal failed for good at Stripe: the money
-- taken back is owed to the organizer again (a credit true-up, with an alert).
CREATE OR REPLACE FUNCTION public.exos_split_reversal_unused(p_request_id uuid)
RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE rv public.exos_split_reversals%ROWTYPE;
BEGIN
  SELECT * INTO rv FROM public.exos_split_reversals WHERE request_id = p_request_id AND status = 'taken';
  IF rv.id IS NULL THEN RETURN 0; END IF;
  UPDATE public.exos_commission_transfers
     SET alert = left(coalesce(alert || ' | ', '') || 'Reversal ' || rv.stripe_reversal_id || ' took ' || rv.amount_cents
                      || ' cents for a refund that then failed; credited to the next split order', 1000)
   WHERE id = rv.ct_id;
  RETURN public._exos_split_true_up(rv.session_id);
END $$;
REVOKE ALL ON FUNCTION public.exos_split_reversal_unused(uuid) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.exos_split_reversal_unused(uuid) TO service_role;

-- ===========================================================================
-- 13. Cron: plan and send due Exos transfers every 15 minutes (deploy
--     exos-promoter-payouts first; it records dry runs until
--     EXOS_SPLIT_AT_SALE / EXOS_PLATFORM_FEE_COMMISSIONS are on). Created
--     inactive: prod keeps Exos crons off and the operator turns them on.
-- ===========================================================================
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron')
     AND to_regprocedure('public._cron_invoke_edge_fn(text, jsonb)') IS NOT NULL THEN
    IF EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'exos-commission-transfers-15min') THEN
      PERFORM cron.unschedule('exos-commission-transfers-15min');
    END IF;
    PERFORM cron.schedule('exos-commission-transfers-15min', '7,22,37,52 * * * *', $cron$
      SELECT public._cron_invoke_edge_fn(
        coalesce(nullif(current_setting('app.exos_functions_url', true), ''),
                 'https://hzrizjeaxlqcxfrtczpq.supabase.co/functions/v1') || '/exos-promoter-payouts/run', '{}'::jsonb);
    $cron$);
    PERFORM cron.alter_job(job_id := (SELECT jobid FROM cron.job WHERE jobname = 'exos-commission-transfers-15min'), active := false);  -- created off (prod keeps Exos crons off; operator turns on)
  END IF;
END $$;
