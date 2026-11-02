-- ============================================================================
-- Migration 20261102150000 — Exos: the promoter wedge (kickbacks paid out,
--                            fast organizer payouts, phone-number RSVP)
--
-- Touches:  W: TABLE exos_promoters, exos_promoter_event_terms (+step_after,
--                 +step_rate_bps, +step_flat_cents)
--              TABLE exos_promoter_commissions (+stepped)
--              TABLE exos_promoter_payouts (+idempotency_key, +via,
--                 +transfer_status, +stripe_account_id, +stripe_transfer_id,
--                 +return_transfer_id, +transfer_error, +transfer_attempts,
--                 +lease_until, +cancelled_at, +transfer_updated_at)
--              TABLE exos_promoter_stripe_accounts, exos_org_promoter_payouts,
--                 exos_promoter_payout_funding, exos_org_instant_payouts,
--                 exos_phone_rsvp_settings, exos_phone_rsvps (new)
--              exos_mail_template_check (+ 'rsvp-code', union pattern)
--              FUNCTION exos_pc_accrue_ticket, exos_set_promoter_terms,
--                 exos_promoter_earnings (replaced, same signatures)
--              FUNCTION _exos_pc_terms, _exos_pc_reprice, exos_set_promoter_step,
--                 exos_promoter_unpaid, exos_settle_promoter,
--                 exos_set_promoter_stripe_transfers, exos_promoter_leaderboard,
--                 exos_promoter_by_token, exos_record_promoter_stripe,
--                 exos_promoter_transfer_claim, exos_promoter_funding_mark,
--                 exos_promoter_transfer_mark, exos_promoter_payout_cancel,
--                 exos_instant_payout_begin, exos_instant_payout_mark,
--                 exos_event_money_so_far, exos_set_phone_rsvp,
--                 _exos_phone_rsvp_offer, exos_phone_rsvp_info,
--                 exos_phone_rsvp_start, exos_phone_rsvp_verify,
--                 exos_phone_rsvp_claim (new)
--           R: exos_tickets, exos_checkout_sessions, exos_order_payments,
--              exos_order_refunds, exos_events, exos_ticket_tiers, exos_orgs,
--              exos_pos_payments, exos_sms_subscribers, exos_mail
-- Pre-reqs: 20260926020000 (promoter commissions), 20260929131000 (transfer_id
--           on payments), 20261031130000 (ticket links), 20261031220000
--           (processor on sessions), 20261016120000 (SMS), 20260929074000 (POS)
--
-- Why: Posh won nightlife with promoter kickbacks plus fast payouts; Partiful
-- and Luma spread through no-app, phone-number RSVP. Exos had the pieces
-- (commission ledger, destination charges, an SMS layer, ticket links); this
-- closes the gaps (docs/organizer-guide.md, docs/payouts.md).
--
-- A. PROMOTER KICKBACKS, PAID OUT.
--   * Step terms. A promoter's terms (default or one event's override) may
--     carry one step: after N tickets AT AN EVENT, a second rate applies
--     ("10% for the first 20, 15% after"). The ticket's ordinal is its place
--     among the promoter's non-reversed rows for that event, counted under an
--     advisory lock so two checkouts can't both be ticket 20. An event
--     override replaces the whole default, step included. A refund doesn't
--     re-price later sales; "re-price unpaid sales" recomputes ordinals.
--   * Idempotent settle. exos_settle_promoter is exos_record_promoter_payout
--     plus an idempotency key (a retry or double click returns the same
--     payout; the same key with another amount is refused) and a choice of
--     how: 'manual' (Venmo, cash: nothing moves) or 'stripe'.
--   * Stripe transfers to the promoter's Connect Express account. Gated by
--     the org owner's switch (exos_org_promoter_payouts.stripe_transfers) AND
--     EXOS_PROMOTER_TRANSFERS=on in exos-promoter-payouts (dry run otherwise).
--     Funding keeps the destination-charge model: the organizer was paid for
--     each order by a Stripe transfer (exos_order_payments.transfer_id); the
--     commission is taken back from those order transfers (transfer reversals)
--     and sent on to the promoter. The cap is in SQL, at settle time:
--       - every selected sale must come from a Stripe order the organizer was
--         paid for (succeeded payment with a transfer id);
--       - per order, the amount taken is at most the commission of the
--         selected sales from that order AND at most what the organizer still
--         holds from it (organizer net - refunds - commission already taken
--         by other payouts);
--       - the funding lines add up to the payout, which is the commission
--         less clawbacks. So a transfer can never exceed the commission the
--         organizer has received.
--     The rows flip to 'paid' at settle (as manual payouts do); the transfer
--     moves pending -> sending -> sent, or failed / dry_run, and a payout
--     that never reached 'sent' can be cancelled: its sales go back to
--     unpaid and any amount already taken goes back to the organizer.
--   * Leaderboard on the promoter's page (exos_promoter_leaderboard, token):
--     rank, display name and tickets of the org's active promoters. No money.
--   * exos_promoter_earnings (token) adds the step, gross sales, payouts in
--     progress vs paid, and the promoter's payout-account state.
--
-- B. FAST PAYOUTS FOR ORGANIZERS. Exos checkout money lands on the org's
--    connected account (destination charges) and Stripe pays it out on the
--    account's schedule. exos-instant-payouts lets the org OWNER request a
--    Stripe Instant Payout from that balance where Stripe allows it, with the
--    fee shown first; EXOS_INSTANT_PAYOUTS=on, default off. The ledger here is
--    idempotent per (org, key) and capped at 5 requests a day.
--    exos_event_money_so_far: the end-of-night money summary (online, door,
--    refunds, fees, commissions owed), owner / manager / finance.
--
-- C. PHONE-NUMBER RSVP for free events. A guest gives a name and a mobile
--    number; exos-rsvp texts a 6-digit code through the org's own Twilio /
--    Telnyx (or mails it when texts aren't available and an email was given);
--    the code issues the ticket(s), parked on the org owner like guest and
--    partner orders, and the guest gets the ticket link (/t/<id>#k=<key>: the
--    rotating door code, no app, no account). Codes expire after 10 minutes,
--    5 tries. Limits: per phone 3 / 10 min and 8 / day, per network 10 / 10
--    min and 40 / day, per event 200 / 10 min; a honeypot in the function.
--    One RSVP per phone per event (a second verify resends the same tickets);
--    plus-ones only up to the organizer's setting. Capacity, quotas and the
--    house cap apply as for free claims; sold out answers 'sold_out' and the
--    page offers the waitlist. Signed in later, the guest saves each ticket
--    to their account from its link (exos_phone_rsvp_claim), which rotates
--    the barcode secret so the old link dies.
--
-- Money is integer cents; every balance change is a ledger row. Re-run safe.
-- Prod apply and deploys need operator OK.
-- ============================================================================

-- ===========================================================================
-- A1. Step terms.
-- ===========================================================================
ALTER TABLE public.exos_promoters
  ADD COLUMN IF NOT EXISTS step_after integer,
  ADD COLUMN IF NOT EXISTS step_rate_bps integer,
  ADD COLUMN IF NOT EXISTS step_flat_cents integer;
ALTER TABLE public.exos_promoter_event_terms
  ADD COLUMN IF NOT EXISTS step_after integer,
  ADD COLUMN IF NOT EXISTS step_rate_bps integer,
  ADD COLUMN IF NOT EXISTS step_flat_cents integer;
DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['exos_promoters', 'exos_promoter_event_terms'] LOOP
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = t || '_step_chk') THEN
      EXECUTE format('ALTER TABLE public.%I ADD CONSTRAINT %I CHECK (
        (step_after IS NULL AND step_rate_bps IS NULL AND step_flat_cents IS NULL)
        OR (step_after BETWEEN 1 AND 100000 AND step_rate_bps BETWEEN 0 AND 10000
            AND step_flat_cents BETWEEN 0 AND 100000))', t, t || '_step_chk');
    END IF;
  END LOOP;
END $$;
COMMENT ON COLUMN public.exos_promoters.step_after IS
  'Step terms: after this many tickets at one event, step_rate_bps / step_flat_cents apply. mig 20261102150000.';

ALTER TABLE public.exos_promoter_commissions
  ADD COLUMN IF NOT EXISTS stepped boolean NOT NULL DEFAULT false;

-- The terms for the n-th (1-based) non-reversed ticket of a promoter at an
-- event: the event override if there is one, else the promoter's default; the
-- step applies once n > step_after. Mirrors src/lib/commissions.ts termsForOrdinal.
CREATE OR REPLACE FUNCTION public._exos_pc_terms(p_promoter_id uuid, p_event_id uuid, p_ordinal integer)
RETURNS TABLE (rate_bps integer, flat_cents integer, source text, stepped boolean)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  p public.exos_promoters%ROWTYPE;
  o public.exos_promoter_event_terms%ROWTYPE;
  v_after integer; v_srate integer; v_sflat integer;
BEGIN
  SELECT * INTO p FROM public.exos_promoters WHERE id = p_promoter_id;
  SELECT * INTO o FROM public.exos_promoter_event_terms WHERE promoter_id = p_promoter_id AND event_id = p_event_id;
  IF o.promoter_id IS NOT NULL THEN
    rate_bps := o.rate_bps; flat_cents := o.flat_cents; source := 'event';
    v_after := o.step_after; v_srate := o.step_rate_bps; v_sflat := o.step_flat_cents;
  ELSE
    rate_bps := p.commission_bps; flat_cents := p.commission_flat_cents; source := 'promoter';
    v_after := p.step_after; v_srate := p.step_rate_bps; v_sflat := p.step_flat_cents;
  END IF;
  stepped := v_after IS NOT NULL AND coalesce(p_ordinal, 1) > v_after;
  IF stepped THEN
    rate_bps := v_srate; flat_cents := v_sflat;
  END IF;
  RETURN NEXT;
END $$;
REVOKE ALL ON FUNCTION public._exos_pc_terms(uuid, uuid, integer) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public._exos_pc_terms(uuid, uuid, integer) TO service_role;

-- Accrue one ticket (replaces 20260926020000's body; same rules plus the step).
CREATE OR REPLACE FUNCTION public.exos_pc_accrue_ticket(p_ticket_id uuid)
RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  t       public.exos_tickets%ROWTYPE;
  p       public.exos_promoters%ROWTYPE;
  s       public.exos_checkout_sessions%ROWTYPE;
  x       record;
  v_gross integer;
  v_base  integer;
  v_addon integer;
  v_n     integer;
  v_cur   text;
  v_id    uuid;
BEGIN
  SELECT * INTO t FROM public.exos_tickets WHERE id = p_ticket_id;
  IF NOT FOUND OR t.promoter_id IS NULL
     OR t.status NOT IN ('active', 'used', 'transferred')
     OR t.channel_source = 'comp'
     OR coalesce(t.price_paid, 0) <= 0 THEN
    RETURN false;
  END IF;
  SELECT * INTO p FROM public.exos_promoters WHERE org_id = t.org_id AND code = t.promoter_id;
  IF NOT FOUND THEN
    RETURN false;
  END IF;
  IF EXISTS (SELECT 1 FROM public.exos_promoter_commissions WHERE ticket_id = t.id) THEN
    RETURN false;
  END IF;

  v_gross := round(t.price_paid * 100)::integer;
  IF t.order_ref IS NOT NULL THEN
    SELECT * INTO s FROM public.exos_checkout_sessions WHERE session_id = t.order_ref;
  END IF;
  IF s.session_id IS NOT NULL AND s.quantity > 0 THEN
    SELECT coalesce(sum(coalesce((a->>'quantity')::int, 0) * coalesce((a->>'unit_price_cents')::int, 0)), 0)
      INTO v_addon
      FROM jsonb_array_elements(CASE WHEN jsonb_typeof(s.addons) = 'array' THEN s.addons ELSE '[]'::jsonb END) a;
    v_base := least(greatest(s.amount_cents - v_addon - coalesce(s.tax_cents, 0), 0) / s.quantity, v_gross);
    v_cur  := lower(coalesce(s.currency, 'usd'));
  ELSE
    v_base := v_gross;
    SELECT lower(coalesce(e.currency, 'usd')) INTO v_cur FROM public.exos_events e WHERE e.id = t.event_id;
  END IF;
  IF coalesce(v_base, 0) <= 0 THEN
    RETURN false;
  END IF;

  -- The ordinal for step terms: one counter per promoter and event.
  PERFORM pg_advisory_xact_lock(hashtextextended('exos-pc-step:' || p.id || ':' || t.event_id, 0));
  SELECT count(*) INTO v_n FROM public.exos_promoter_commissions
   WHERE promoter_id = p.id AND event_id = t.event_id AND status <> 'reversed';
  SELECT * INTO x FROM public._exos_pc_terms(p.id, t.event_id, v_n + 1);

  INSERT INTO public.exos_promoter_commissions (
    org_id, promoter_id, event_id, ticket_id, currency, gross_cents, base_cents,
    rate_bps, flat_cents, terms_source, commission_cents, stepped, accrued_at
  ) VALUES (
    t.org_id, p.id, t.event_id, t.id, coalesce(v_cur, 'usd'), greatest(v_gross, 0), v_base,
    x.rate_bps, x.flat_cents, x.source, public.exos_pc_commission_cents(v_base, x.rate_bps, x.flat_cents), x.stepped,
    -- clock time, so (accrued_at, id) orders tickets of one checkout the way
    -- the ordinal counted them (the re-price recomputes ordinals that way)
    clock_timestamp()
  )
  ON CONFLICT (ticket_id) DO NOTHING
  RETURNING id INTO v_id;
  RETURN v_id IS NOT NULL;
END $$;
REVOKE ALL ON FUNCTION public.exos_pc_accrue_ticket(uuid) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.exos_pc_accrue_ticket(uuid) TO service_role;

-- Re-price a promoter's accrued (unpaid) rows at the terms now in effect,
-- ordinals recomputed per event over non-reversed rows (paid rows count, but
-- keep their terms). Returns the accrued rows in scope. Internal.
CREATE OR REPLACE FUNCTION public._exos_pc_reprice(p_promoter_id uuid, p_event_id uuid)
RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE v_n integer;
BEGIN
  UPDATE public.exos_promoter_commissions c
     SET rate_bps = x.rate_bps, flat_cents = x.flat_cents, terms_source = x.source, stepped = x.stepped,
         commission_cents = public.exos_pc_commission_cents(c.base_cents, x.rate_bps, x.flat_cents),
         updated_at = now()
    FROM (
      SELECT r.id, tt.*
        FROM (SELECT c2.id, c2.event_id, c2.status,
                     row_number() OVER (PARTITION BY c2.event_id ORDER BY c2.accrued_at, c2.id) AS ord
                FROM public.exos_promoter_commissions c2
               WHERE c2.promoter_id = p_promoter_id AND c2.status <> 'reversed'
                 AND (p_event_id IS NULL OR c2.event_id = p_event_id)) r
        CROSS JOIN LATERAL public._exos_pc_terms(p_promoter_id, r.event_id, r.ord::integer) tt
       WHERE r.status = 'accrued'
    ) x
   WHERE c.id = x.id;
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN v_n;
END $$;
REVOKE ALL ON FUNCTION public._exos_pc_reprice(uuid, uuid) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public._exos_pc_reprice(uuid, uuid) TO service_role;

-- Same signature and checks as 20260926020000; the re-price is step-aware and
-- an event override created here starts with no step.
CREATE OR REPLACE FUNCTION public.exos_set_promoter_terms(
  p_promoter_id     uuid,
  p_rate_bps        integer,
  p_flat_cents      integer,
  p_event_id        uuid    DEFAULT NULL,
  p_reprice_accrued boolean DEFAULT false
) RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_org uuid;
BEGIN
  SELECT org_id INTO v_org FROM public.exos_promoters WHERE id = p_promoter_id;
  IF v_org IS NULL OR NOT public.exos_has_org_role(v_org, ARRAY['owner', 'manager']) THEN
    RAISE EXCEPTION 'exos_set_promoter_terms: not allowed' USING ERRCODE = '42501';
  END IF;
  IF coalesce(p_rate_bps, 0) NOT BETWEEN 0 AND 10000 THEN
    RAISE EXCEPTION 'Commission percent must be between 0 and 100.' USING ERRCODE = '22023';
  END IF;
  IF coalesce(p_flat_cents, 0) NOT BETWEEN 0 AND 100000 THEN
    RAISE EXCEPTION 'Flat commission must be between 0 and 1,000 per ticket.' USING ERRCODE = '22023';
  END IF;

  IF p_event_id IS NULL THEN
    UPDATE public.exos_promoters
       SET commission_bps = coalesce(p_rate_bps, 0),
           commission_flat_cents = coalesce(p_flat_cents, 0),
           updated_at = now()
     WHERE id = p_promoter_id;
  ELSE
    IF NOT EXISTS (SELECT 1 FROM public.exos_events WHERE id = p_event_id AND org_id = v_org) THEN
      RAISE EXCEPTION 'exos_set_promoter_terms: event is not this organizer''s' USING ERRCODE = '22023';
    END IF;
    IF p_rate_bps IS NULL AND p_flat_cents IS NULL THEN
      DELETE FROM public.exos_promoter_event_terms WHERE promoter_id = p_promoter_id AND event_id = p_event_id;
    ELSE
      INSERT INTO public.exos_promoter_event_terms AS o (promoter_id, event_id, org_id, rate_bps, flat_cents, updated_by)
      VALUES (p_promoter_id, p_event_id, v_org, coalesce(p_rate_bps, 0), coalesce(p_flat_cents, 0), auth.uid())
      ON CONFLICT (promoter_id, event_id) DO UPDATE SET
        rate_bps = EXCLUDED.rate_bps, flat_cents = EXCLUDED.flat_cents,
        updated_by = EXCLUDED.updated_by, updated_at = now();
    END IF;
  END IF;

  IF p_reprice_accrued THEN
    RETURN public._exos_pc_reprice(p_promoter_id, p_event_id);
  END IF;
  RETURN 0;
END $$;
REVOKE ALL ON FUNCTION public.exos_set_promoter_terms(uuid, integer, integer, uuid, boolean) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.exos_set_promoter_terms(uuid, integer, integer, uuid, boolean) TO authenticated, service_role;

-- Set or clear (p_after NULL) the step on a promoter's default terms, or on
-- one event's override (which must exist: set its base terms first).
-- Owner / manager. Returns the rows re-priced (0 unless p_reprice_accrued).
CREATE OR REPLACE FUNCTION public.exos_set_promoter_step(
  p_promoter_id     uuid,
  p_after           integer,
  p_rate_bps        integer,
  p_flat_cents      integer,
  p_event_id        uuid    DEFAULT NULL,
  p_reprice_accrued boolean DEFAULT false
) RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_org uuid;
  v_n   integer;
BEGIN
  SELECT org_id INTO v_org FROM public.exos_promoters WHERE id = p_promoter_id;
  IF v_org IS NULL OR NOT public.exos_has_org_role(v_org, ARRAY['owner', 'manager']) THEN
    RAISE EXCEPTION 'exos_set_promoter_step: not allowed' USING ERRCODE = '42501';
  END IF;
  IF p_after IS NOT NULL AND (p_after NOT BETWEEN 1 AND 100000
       OR coalesce(p_rate_bps, 0) NOT BETWEEN 0 AND 10000 OR coalesce(p_flat_cents, 0) NOT BETWEEN 0 AND 100000) THEN
    RAISE EXCEPTION 'The step needs a ticket count from 1 and a percent from 0 to 100 (flat up to 1,000).' USING ERRCODE = '22023';
  END IF;
  IF p_event_id IS NULL THEN
    UPDATE public.exos_promoters
       SET step_after = p_after,
           step_rate_bps = CASE WHEN p_after IS NULL THEN NULL ELSE coalesce(p_rate_bps, 0) END,
           step_flat_cents = CASE WHEN p_after IS NULL THEN NULL ELSE coalesce(p_flat_cents, 0) END,
           updated_at = now()
     WHERE id = p_promoter_id;
  ELSE
    UPDATE public.exos_promoter_event_terms
       SET step_after = p_after,
           step_rate_bps = CASE WHEN p_after IS NULL THEN NULL ELSE coalesce(p_rate_bps, 0) END,
           step_flat_cents = CASE WHEN p_after IS NULL THEN NULL ELSE coalesce(p_flat_cents, 0) END,
           updated_by = auth.uid(), updated_at = now()
     WHERE promoter_id = p_promoter_id AND event_id = p_event_id;
    GET DIAGNOSTICS v_n = ROW_COUNT;
    IF v_n = 0 THEN
      RAISE EXCEPTION 'Set this event''s terms first, then its step.' USING ERRCODE = '22023';
    END IF;
  END IF;
  IF p_reprice_accrued THEN
    RETURN public._exos_pc_reprice(p_promoter_id, p_event_id);
  END IF;
  RETURN 0;
END $$;
REVOKE ALL ON FUNCTION public.exos_set_promoter_step(uuid, integer, integer, integer, uuid, boolean) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.exos_set_promoter_step(uuid, integer, integer, integer, uuid, boolean) TO authenticated, service_role;

-- ===========================================================================
-- A2. Payout accounts, the org switch, payout columns, funding lines.
-- ===========================================================================
CREATE TABLE IF NOT EXISTS public.exos_promoter_stripe_accounts (
  promoter_id       uuid PRIMARY KEY REFERENCES public.exos_promoters (id) ON DELETE CASCADE,
  org_id            uuid NOT NULL REFERENCES public.exos_orgs (id) ON DELETE CASCADE,
  stripe_account_id text NOT NULL UNIQUE CHECK (stripe_account_id ~ '^acct_[A-Za-z0-9]{1,64}$'),
  details_submitted boolean NOT NULL DEFAULT false,
  transfers_active  boolean NOT NULL DEFAULT false,
  payouts_enabled   boolean NOT NULL DEFAULT false,
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS exos_promoter_stripe_accounts_org_idx ON public.exos_promoter_stripe_accounts (org_id);

CREATE TABLE IF NOT EXISTS public.exos_org_promoter_payouts (
  org_id           uuid PRIMARY KEY REFERENCES public.exos_orgs (id) ON DELETE CASCADE,
  stripe_transfers boolean NOT NULL DEFAULT false,
  updated_by       uuid REFERENCES auth.users (id) ON DELETE SET NULL,
  created_at       timestamptz NOT NULL DEFAULT now(),
  updated_at       timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.exos_promoter_payouts
  ADD COLUMN IF NOT EXISTS idempotency_key     text,
  ADD COLUMN IF NOT EXISTS via                 text NOT NULL DEFAULT 'manual',
  ADD COLUMN IF NOT EXISTS transfer_status     text,
  ADD COLUMN IF NOT EXISTS stripe_account_id   text,
  ADD COLUMN IF NOT EXISTS stripe_transfer_id  text,
  ADD COLUMN IF NOT EXISTS return_transfer_id  text,
  ADD COLUMN IF NOT EXISTS transfer_error      text,
  ADD COLUMN IF NOT EXISTS transfer_attempts   integer NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS lease_until         timestamptz,
  ADD COLUMN IF NOT EXISTS cancelled_at        timestamptz,
  ADD COLUMN IF NOT EXISTS transfer_updated_at timestamptz,
  ADD COLUMN IF NOT EXISTS updated_at          timestamptz NOT NULL DEFAULT now(),
  -- Set each time a send is claimed; a payout with a send that may have
  -- reached Stripe can't be cancelled until reconciled_at is later.
  ADD COLUMN IF NOT EXISTS send_started_at     timestamptz,
  ADD COLUMN IF NOT EXISTS reconciled_at       timestamptz,
  -- The current lease holder (exos_promoter_transfer_claim): a send checks
  -- its token before each Stripe call; any new claim replaces it.
  ADD COLUMN IF NOT EXISTS lease_token         uuid,
  ADD COLUMN IF NOT EXISTS lease_purpose       text;
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'exos_promoter_payouts_transfer_chk') THEN
    ALTER TABLE public.exos_promoter_payouts ADD CONSTRAINT exos_promoter_payouts_transfer_chk CHECK (
      (idempotency_key IS NULL OR idempotency_key ~ '^[A-Za-z0-9_-]{8,80}$')
      AND via IN ('manual', 'stripe')
      AND (transfer_status IS NULL OR transfer_status IN ('pending', 'sending', 'sent', 'dry_run', 'failed', 'cancelled'))
      AND ((via = 'manual') = (transfer_status IS NULL))
      AND (stripe_transfer_id IS NULL OR stripe_transfer_id ~ '^tr_[A-Za-z0-9]{1,64}$')
      AND (return_transfer_id IS NULL OR return_transfer_id ~ '^tr_[A-Za-z0-9]{1,64}$')
      AND (transfer_error IS NULL OR length(transfer_error) <= 300)
      AND (transfer_status IS DISTINCT FROM 'sent' OR stripe_transfer_id IS NOT NULL)
      AND ((transfer_status = 'cancelled') = (cancelled_at IS NOT NULL)));
  END IF;
END $$;
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'exos_promoter_payouts_lease_chk') THEN
    ALTER TABLE public.exos_promoter_payouts ADD CONSTRAINT exos_promoter_payouts_lease_chk
      CHECK (lease_purpose IS NULL OR lease_purpose IN ('send', 'reconcile', 'cancel'));
  END IF;
END $$;
CREATE UNIQUE INDEX IF NOT EXISTS exos_promoter_payouts_idem_uq
  ON public.exos_promoter_payouts (promoter_id, idempotency_key) WHERE idempotency_key IS NOT NULL;
CREATE INDEX IF NOT EXISTS exos_promoter_payouts_transfer_idx
  ON public.exos_promoter_payouts (transfer_status) WHERE via = 'stripe';

-- One row per order the commission is taken back from (Stripe payouts only).
CREATE TABLE IF NOT EXISTS public.exos_promoter_payout_funding (
  payout_id       uuid NOT NULL REFERENCES public.exos_promoter_payouts (id) ON DELETE CASCADE,
  session_id      text NOT NULL REFERENCES public.exos_checkout_sessions (session_id) ON DELETE CASCADE,
  org_id          uuid NOT NULL REFERENCES public.exos_orgs (id) ON DELETE CASCADE,
  org_transfer_id text NOT NULL CHECK (org_transfer_id ~ '^tr_[A-Za-z0-9]{1,64}$'),
  amount_cents    integer NOT NULL CHECK (amount_cents > 0),
  status          text NOT NULL DEFAULT 'planned' CHECK (status IN ('planned', 'taken', 'returned', 'released')),
  reversal_id     text CHECK (reversal_id IS NULL OR reversal_id ~ '^trr_[A-Za-z0-9]{1,64}$'),
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (payout_id, session_id),
  CHECK (status <> 'taken' OR reversal_id IS NOT NULL)
);
CREATE INDEX IF NOT EXISTS exos_promoter_payout_funding_session_idx ON public.exos_promoter_payout_funding (session_id);
CREATE INDEX IF NOT EXISTS exos_promoter_payout_funding_org_idx ON public.exos_promoter_payout_funding (org_id);

DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['exos_promoter_stripe_accounts', 'exos_org_promoter_payouts', 'exos_promoter_payout_funding'] LOOP
    EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY', t);
    EXECUTE format('REVOKE ALL ON public.%I FROM PUBLIC, anon, authenticated', t);
    EXECUTE format('GRANT SELECT ON public.%I TO authenticated', t);
    EXECUTE format('GRANT ALL ON public.%I TO service_role', t);
    EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I', t || '_staff_read', t);
    EXECUTE format('CREATE POLICY %I ON public.%I FOR SELECT TO authenticated
                    USING (public.exos_has_org_role(org_id, ARRAY[''owner'', ''manager'', ''finance'']))',
                   t || '_staff_read', t);
  END LOOP;
  FOREACH t IN ARRAY ARRAY['exos_promoter_stripe_accounts', 'exos_org_promoter_payouts', 'exos_promoter_payout_funding',
                           'exos_promoter_payouts'] LOOP
    EXECUTE format('DROP TRIGGER IF EXISTS %I ON public.%I', t || '_touch', t);
    EXECUTE format('CREATE TRIGGER %I BEFORE UPDATE ON public.%I FOR EACH ROW EXECUTE FUNCTION public.exos_touch_updated_at()',
                   t || '_touch', t);
  END LOOP;
END $$;

-- The org owner's switch: may this org pay promoters by Stripe transfer?
CREATE OR REPLACE FUNCTION public.exos_set_promoter_stripe_transfers(p_org_id uuid, p_enabled boolean)
RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF NOT public.exos_has_org_role(p_org_id, ARRAY['owner']) THEN
    RAISE EXCEPTION 'Only the org owner can turn Stripe payouts to promoters on or off.' USING ERRCODE = '42501';
  END IF;
  INSERT INTO public.exos_org_promoter_payouts AS s (org_id, stripe_transfers, updated_by)
  VALUES (p_org_id, coalesce(p_enabled, false), auth.uid())
  ON CONFLICT (org_id) DO UPDATE SET stripe_transfers = EXCLUDED.stripe_transfers, updated_by = EXCLUDED.updated_by;
  RETURN coalesce(p_enabled, false);
END $$;
REVOKE ALL ON FUNCTION public.exos_set_promoter_stripe_transfers(uuid, boolean) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.exos_set_promoter_stripe_transfers(uuid, boolean) TO authenticated, service_role;

-- ===========================================================================
-- A3. Unpaid sales (with whether each can be paid by Stripe transfer).
--     fundable: the ticket came from a Stripe order the organizer was paid
--     for (succeeded payment carrying a transfer id).
-- ===========================================================================
CREATE OR REPLACE FUNCTION public.exos_promoter_unpaid(p_promoter_id uuid)
RETURNS TABLE (
  id uuid, event_id uuid, event_name text, currency text, base_cents integer, commission_cents integer,
  stepped boolean, accrued_at timestamptz, fundable boolean
)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE v_org uuid;
BEGIN
  SELECT org_id INTO v_org FROM public.exos_promoters WHERE exos_promoters.id = p_promoter_id;
  IF v_org IS NULL OR NOT public.exos_has_org_role(v_org, ARRAY['owner', 'manager', 'finance']) THEN
    RAISE EXCEPTION 'exos_promoter_unpaid: not allowed' USING ERRCODE = '42501';
  END IF;
  RETURN QUERY
    SELECT c.id, c.event_id, e.name, c.currency, c.base_cents, c.commission_cents, c.stepped, c.accrued_at,
           EXISTS (SELECT 1 FROM public.exos_checkout_sessions s
                     JOIN public.exos_order_payments op ON op.session_id = s.session_id
                    WHERE s.session_id = t.order_ref AND coalesce(s.processor, 'stripe') = 'stripe'
                      AND op.status = 'succeeded' AND op.transfer_id IS NOT NULL)
      FROM public.exos_promoter_commissions c
      JOIN public.exos_events e ON e.id = c.event_id
      LEFT JOIN public.exos_tickets t ON t.id = c.ticket_id
     WHERE c.promoter_id = p_promoter_id AND c.status = 'accrued'
     ORDER BY c.accrued_at, c.id
     LIMIT 2000;
END $$;
REVOKE ALL ON FUNCTION public.exos_promoter_unpaid(uuid) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.exos_promoter_unpaid(uuid) TO authenticated, service_role;

-- ===========================================================================
-- A4. Settle (idempotent). Owner / manager. Same row rules as
--     exos_record_promoter_payout; p_via 'stripe' also plans the funding.
--     Returns {payout_id, replayed, via, transfer_status, amount_cents}.
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
     AND payout_id IS NOT NULL AND recovered_payout_id IS NULL;
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
     AND payout_id IS NOT NULL AND recovered_payout_id IS NULL;
  RETURN jsonb_build_object('payout_id', v_id, 'replayed', false, 'via', v_via,
                            'transfer_status', CASE WHEN v_via = 'stripe' THEN 'pending' END,
                            'amount_cents', p_amount_cents);
END $$;
REVOKE ALL ON FUNCTION public.exos_settle_promoter(uuid, uuid[], integer, text, text, text, text, date) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.exos_settle_promoter(uuid, uuid[], integer, text, text, text, text, date) TO authenticated, service_role;

-- ===========================================================================
-- A5. The transfer job's SQL side (service role: exos-promoter-payouts).
-- ===========================================================================
-- The promoter behind a kit token (active only), for onboarding.
CREATE OR REPLACE FUNCTION public.exos_promoter_by_token(p_token uuid)
RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT jsonb_build_object('promoter_id', p.id, 'org_id', p.org_id, 'name', p.name, 'email', p.email,
                            'org_name', o.name,
                            'transfers_enabled', coalesce(s.stripe_transfers, false),
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

CREATE OR REPLACE FUNCTION public.exos_record_promoter_stripe(
  p_promoter_id uuid, p_account_id text, p_details_submitted boolean, p_transfers_active boolean, p_payouts_enabled boolean
) RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE v_org uuid;
BEGIN
  SELECT org_id INTO v_org FROM public.exos_promoters WHERE id = p_promoter_id;
  IF v_org IS NULL THEN RETURN false; END IF;
  INSERT INTO public.exos_promoter_stripe_accounts AS a
    (promoter_id, org_id, stripe_account_id, details_submitted, transfers_active, payouts_enabled)
  VALUES (p_promoter_id, v_org, p_account_id, coalesce(p_details_submitted, false),
          coalesce(p_transfers_active, false), coalesce(p_payouts_enabled, false))
  ON CONFLICT (promoter_id) DO UPDATE SET
    stripe_account_id = EXCLUDED.stripe_account_id, details_submitted = EXCLUDED.details_submitted,
    transfers_active = EXCLUDED.transfers_active, payouts_enabled = EXCLUDED.payouts_enabled;
  RETURN true;
END $$;
REVOKE ALL ON FUNCTION public.exos_record_promoter_stripe(uuid, text, boolean, boolean, boolean) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.exos_record_promoter_stripe(uuid, text, boolean, boolean, boolean) TO service_role;

-- Claim a Stripe payout (service role: exos-promoter-payouts). p_user must
-- be the org's owner or manager (the function checked the JWT; this
-- re-checks). p_purpose:
--   'send'       lease it to send. Refused ('needs_reconcile') when an earlier
--                send attempt was never reconciled with Stripe, so a retry
--                (even after Stripe's 24 h idempotency window) can't pay twice.
--   'reconcile'  lease it to look Stripe up (exos_promoter_transfer_reconcile).
--   'cancel'     lease it to cancel; answers needs_reconcile when a send was
--                ever started and not reconciled since.
-- Every claim mints a new lease token, which fences out any older holder:
-- a send re-checks its token (exos_promoter_lease_ok) right before each
-- Stripe call. 'reconcile' / 'cancel' are refused while a send attempt is
-- still open (leased for send, no outcome recorded, under 10 minutes old).
-- Returns the payout, its funding lines and the token, or {ok:false, error}.
CREATE OR REPLACE FUNCTION public.exos_promoter_transfer_claim(p_payout_id uuid, p_user uuid, p_purpose text DEFAULT 'send')
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  po      public.exos_promoter_payouts%ROWTYPE;
  v_lines bigint;
  v_tok   uuid := gen_random_uuid();
  v_unrec boolean;
BEGIN
  IF p_purpose NOT IN ('send', 'reconcile', 'cancel') THEN
    RAISE EXCEPTION 'exos_promoter_transfer_claim: bad purpose' USING ERRCODE = '22023';
  END IF;
  SELECT * INTO po FROM public.exos_promoter_payouts WHERE id = p_payout_id FOR UPDATE;
  IF po.id IS NULL OR NOT EXISTS (
       SELECT 1 FROM public.exos_org_memberships m
        WHERE m.org_id = po.org_id AND m.user_id = p_user AND m.disabled IS NOT TRUE AND m.role IN ('owner', 'manager')) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_found');
  END IF;
  IF po.via <> 'stripe' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'manual');
  END IF;
  IF po.transfer_status IN ('sent', 'cancelled') THEN
    RETURN jsonb_build_object('ok', false, 'error', po.transfer_status);
  END IF;
  IF po.transfer_status = 'sending' AND po.lease_until > now() THEN
    RETURN jsonb_build_object('ok', false, 'error', 'busy');
  END IF;
  IF p_purpose <> 'send' AND po.transfer_status = 'sending' AND po.lease_purpose = 'send'
     AND po.send_started_at > now() - interval '10 minutes' THEN
    -- A send may still be talking to Stripe: wait for it to finish or time out.
    RETURN jsonb_build_object('ok', false, 'error', 'send_in_progress');
  END IF;
  v_unrec := po.send_started_at IS NOT NULL AND (po.reconciled_at IS NULL OR po.reconciled_at < po.send_started_at);
  IF p_purpose = 'send' THEN
    IF v_unrec THEN
      RETURN jsonb_build_object('ok', false, 'error', 'needs_reconcile');
    END IF;
    IF NOT coalesce((SELECT stripe_transfers FROM public.exos_org_promoter_payouts WHERE org_id = po.org_id), false) THEN
      RETURN jsonb_build_object('ok', false, 'error', 'switched_off');
    END IF;
    SELECT coalesce(sum(amount_cents), 0) INTO v_lines FROM public.exos_promoter_payout_funding
     WHERE payout_id = po.id AND status IN ('planned', 'taken');
    IF v_lines <> po.amount_cents THEN
      -- Never send more (or other) than the funding the settle planned.
      RETURN jsonb_build_object('ok', false, 'error', 'funding_mismatch');
    END IF;
  END IF;
  UPDATE public.exos_promoter_payouts
     SET transfer_status = 'sending', lease_until = now() + interval '2 minutes',
         lease_token = v_tok, lease_purpose = p_purpose,
         transfer_attempts = transfer_attempts + CASE WHEN p_purpose = 'send' THEN 1 ELSE 0 END,
         transfer_updated_at = now(),
         send_started_at = CASE WHEN p_purpose = 'send' THEN clock_timestamp() ELSE send_started_at END
   WHERE id = po.id;
  RETURN jsonb_build_object(
    'ok', true, 'payout_id', po.id, 'lease_token', v_tok, 'purpose', p_purpose,
    'attempt', po.transfer_attempts + CASE WHEN p_purpose = 'send' THEN 1 ELSE 0 END,
    'needs_reconcile', p_purpose <> 'send' AND v_unrec,
    'org_id', po.org_id, 'promoter_id', po.promoter_id,
    'amount_cents', po.amount_cents, 'currency', po.currency, 'destination', po.stripe_account_id,
    'stripe_transfer_id', po.stripe_transfer_id,
    'lines', coalesce((SELECT jsonb_agg(jsonb_build_object('session_id', f.session_id, 'org_transfer_id', f.org_transfer_id,
                                                           'amount_cents', f.amount_cents, 'status', f.status,
                                                           'reversal_id', f.reversal_id) ORDER BY f.created_at, f.session_id)
                         FROM public.exos_promoter_payout_funding f WHERE f.payout_id = po.id), '[]'::jsonb));
END $$;
REVOKE ALL ON FUNCTION public.exos_promoter_transfer_claim(uuid, uuid, text) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.exos_promoter_transfer_claim(uuid, uuid, text) TO service_role;

-- Does this send still hold the payout? Called right before every Stripe
-- call: the payout is 'sending', leased for send with this token, not
-- cancelled, and the lease hasn't run out. Extends the lease by 2 minutes,
-- never past 8 minutes after the send started (cancel waits 10).
CREATE OR REPLACE FUNCTION public.exos_promoter_lease_ok(p_payout_id uuid, p_lease_token uuid)
RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE v_n integer;
BEGIN
  UPDATE public.exos_promoter_payouts
     SET lease_until = least(now() + interval '2 minutes', send_started_at + interval '8 minutes')
   WHERE id = p_payout_id AND via = 'stripe' AND transfer_status = 'sending' AND lease_purpose = 'send'
     AND lease_token = p_lease_token AND lease_until > now() AND cancelled_at IS NULL
     AND send_started_at > now() - interval '8 minutes';
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN v_n > 0;
END $$;
REVOKE ALL ON FUNCTION public.exos_promoter_lease_ok(uuid, uuid) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.exos_promoter_lease_ok(uuid, uuid) TO service_role;

-- One funding line: 'taken' (the reversal went through) or 'returned' (sent
-- back to the organizer on cancel).
CREATE OR REPLACE FUNCTION public.exos_promoter_funding_mark(p_payout_id uuid, p_session_id text, p_status text, p_reversal_id text DEFAULT NULL)
RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE v_n integer;
BEGIN
  IF p_status NOT IN ('taken', 'returned') THEN
    RAISE EXCEPTION 'exos_promoter_funding_mark: bad status' USING ERRCODE = '22023';
  END IF;
  UPDATE public.exos_promoter_payout_funding
     SET status = p_status, reversal_id = coalesce(p_reversal_id, reversal_id)
   WHERE payout_id = p_payout_id AND session_id = p_session_id
     AND ((p_status = 'taken' AND status IN ('planned', 'taken')) OR (p_status = 'returned' AND status = 'taken'));
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN v_n > 0;
END $$;
REVOKE ALL ON FUNCTION public.exos_promoter_funding_mark(uuid, text, text, text) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.exos_promoter_funding_mark(uuid, text, text, text) TO service_role;

-- The outcome of a send: sent (with the transfer id), dry_run, or failed.
-- 'sent' is recorded whoever holds the lease (the money moved); dry_run /
-- failed only by the holder of p_lease_token, so a stale send can't flip a
-- payout that a cancel or reconcile has since claimed.
CREATE OR REPLACE FUNCTION public.exos_promoter_transfer_mark(
  p_payout_id uuid, p_status text, p_transfer_id text DEFAULT NULL, p_error text DEFAULT NULL, p_lease_token uuid DEFAULT NULL
) RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE v_n integer;
BEGIN
  IF p_status NOT IN ('sent', 'dry_run', 'failed') THEN
    RAISE EXCEPTION 'exos_promoter_transfer_mark: bad status' USING ERRCODE = '22023';
  END IF;
  IF p_status = 'sent' AND (p_transfer_id IS NULL OR EXISTS (
       SELECT 1 FROM public.exos_promoter_payout_funding WHERE payout_id = p_payout_id AND status <> 'taken')) THEN
    RAISE EXCEPTION 'exos_promoter_transfer_mark: sent needs a transfer id and every funding line taken' USING ERRCODE = '22023';
  END IF;
  UPDATE public.exos_promoter_payouts
     SET transfer_status = p_status,
         stripe_transfer_id = CASE WHEN p_status = 'sent' THEN p_transfer_id ELSE stripe_transfer_id END,
         transfer_error = CASE WHEN p_status = 'failed' THEN left(coalesce(p_error, 'failed'), 300) ELSE NULL END,
         lease_until = NULL, lease_token = NULL, transfer_updated_at = now()
   WHERE id = p_payout_id AND via = 'stripe' AND transfer_status = 'sending'
     AND (p_status = 'sent' OR lease_token = p_lease_token);
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN v_n > 0;
END $$;
REVOKE ALL ON FUNCTION public.exos_promoter_transfer_mark(uuid, text, text, text, uuid) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.exos_promoter_transfer_mark(uuid, text, text, text, uuid) TO service_role;

-- Reconcile with what Stripe actually did, by the holder of a 'reconcile' or
-- 'cancel' lease (service role). p_reversals: [{session_id, reversal_id}]
-- found at Stripe for this payout; those lines become 'taken'.
-- p_transfer_id: the transfer to the promoter found at Stripe, which marks
-- the payout sent (nothing new is created). NULL: Stripe has none, so the
-- payout is reconciled: a send may be claimed again, or the cancel go on.
-- Answers 'sent' or 'reconciled'.
CREATE OR REPLACE FUNCTION public.exos_promoter_transfer_reconcile(
  p_payout_id uuid, p_lease_token uuid, p_transfer_id text, p_reversals jsonb DEFAULT '[]'::jsonb
) RETURNS text
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  po public.exos_promoter_payouts%ROWTYPE;
  x  jsonb;
BEGIN
  SELECT * INTO po FROM public.exos_promoter_payouts WHERE id = p_payout_id FOR UPDATE;
  IF po.id IS NULL OR po.via <> 'stripe' OR po.transfer_status <> 'sending'
     OR po.lease_purpose NOT IN ('reconcile', 'cancel') OR po.lease_token IS DISTINCT FROM p_lease_token THEN
    RAISE EXCEPTION 'exos_promoter_transfer_reconcile: claim the payout to reconcile first' USING ERRCODE = '22023';
  END IF;
  IF p_transfer_id IS NOT NULL AND p_transfer_id !~ '^tr_[A-Za-z0-9]{1,64}$' THEN
    RAISE EXCEPTION 'exos_promoter_transfer_reconcile: bad transfer id' USING ERRCODE = '22023';
  END IF;
  FOR x IN SELECT * FROM jsonb_array_elements(CASE WHEN jsonb_typeof(p_reversals) = 'array' THEN p_reversals ELSE '[]'::jsonb END) LOOP
    UPDATE public.exos_promoter_payout_funding
       SET status = 'taken', reversal_id = x ->> 'reversal_id'
     WHERE payout_id = po.id AND session_id = x ->> 'session_id' AND status = 'planned'
       AND (x ->> 'reversal_id') ~ '^trr_[A-Za-z0-9]{1,64}$';
  END LOOP;
  IF p_transfer_id IS NOT NULL THEN
    -- The money went out: it is paid, whatever the ledger said.
    UPDATE public.exos_promoter_payouts
       SET transfer_status = 'sent', stripe_transfer_id = p_transfer_id, transfer_error = NULL,
           lease_until = NULL, lease_token = NULL, reconciled_at = clock_timestamp(), transfer_updated_at = now()
     WHERE id = po.id;
    RETURN 'sent';
  END IF;
  -- A reconcile lease ends here (a send may now be claimed); a cancel keeps
  -- its token for exos_promoter_payout_cancel in the next step.
  UPDATE public.exos_promoter_payouts
     SET reconciled_at = clock_timestamp(),
         lease_until = CASE WHEN po.lease_purpose = 'reconcile' THEN NULL ELSE lease_until END,
         transfer_status = CASE WHEN po.lease_purpose = 'reconcile' THEN 'failed' ELSE transfer_status END,
         transfer_error = CASE WHEN po.lease_purpose = 'reconcile' THEN coalesce(transfer_error, 'reconciled: nothing at Stripe') ELSE transfer_error END
   WHERE id = po.id;
  RETURN 'reconciled';
END $$;
REVOKE ALL ON FUNCTION public.exos_promoter_transfer_reconcile(uuid, uuid, text, jsonb) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.exos_promoter_transfer_reconcile(uuid, uuid, text, jsonb) TO service_role;

-- Cancel a Stripe payout that never reached 'sent', by the holder of the
-- 'cancel' lease (claimed with exos_promoter_transfer_claim, which also
-- fenced out any send). Refused until a started send was reconciled and
-- every taken line returned. Its sales go back to unpaid; clawbacks it
-- netted are outstanding again. Service role.
CREATE OR REPLACE FUNCTION public.exos_promoter_payout_cancel(p_payout_id uuid, p_lease_token uuid, p_return_transfer_id text DEFAULT NULL)
RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE po public.exos_promoter_payouts%ROWTYPE;
BEGIN
  SELECT * INTO po FROM public.exos_promoter_payouts WHERE id = p_payout_id FOR UPDATE;
  IF po.id IS NULL OR po.via <> 'stripe' OR po.transfer_status <> 'sending' OR po.stripe_transfer_id IS NOT NULL THEN
    RETURN false;
  END IF;
  IF po.lease_purpose IS DISTINCT FROM 'cancel' OR po.lease_token IS DISTINCT FROM p_lease_token THEN
    RAISE EXCEPTION 'exos_promoter_payout_cancel: claim the payout for cancel first' USING ERRCODE = '22023';
  END IF;
  IF po.send_started_at IS NOT NULL AND (po.reconciled_at IS NULL OR po.reconciled_at < po.send_started_at) THEN
    -- A send may have reached Stripe: look it up first (exos_promoter_transfer_reconcile).
    RAISE EXCEPTION 'exos_promoter_payout_cancel: a send was started; reconcile with Stripe before cancelling' USING ERRCODE = '22023';
  END IF;
  IF EXISTS (SELECT 1 FROM public.exos_promoter_payout_funding WHERE payout_id = po.id AND status = 'taken') THEN
    RAISE EXCEPTION 'exos_promoter_payout_cancel: money taken for this payout must be returned first' USING ERRCODE = '22023';
  END IF;
  UPDATE public.exos_promoter_payout_funding SET status = 'released'
   WHERE payout_id = po.id AND status = 'planned';
  -- Paid rows go back to unpaid; a sale refunded while this payout was
  -- pending was a clawback against it, and with the payout gone it is simply
  -- reversed (status stays, payout cleared).
  UPDATE public.exos_promoter_commissions
     SET status = CASE WHEN status = 'paid' THEN 'accrued' ELSE status END,
         payout_id = NULL, paid_at = NULL, updated_at = now()
   WHERE payout_id = po.id AND status IN ('paid', 'reversed');
  -- Clawbacks this payout netted out are outstanding again.
  UPDATE public.exos_promoter_commissions SET recovered_payout_id = NULL, updated_at = now()
   WHERE recovered_payout_id = po.id;
  UPDATE public.exos_promoter_payouts
     SET transfer_status = 'cancelled', cancelled_at = now(), lease_until = NULL, lease_token = NULL,
         return_transfer_id = p_return_transfer_id, transfer_updated_at = now()
   WHERE id = po.id;
  RETURN true;
END $$;
REVOKE ALL ON FUNCTION public.exos_promoter_payout_cancel(uuid, uuid, text) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.exos_promoter_payout_cancel(uuid, uuid, text) TO service_role;

-- ===========================================================================
-- A6. The promoter's page: earnings (replaced) and the leaderboard.
-- ===========================================================================
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
      'transfers_enabled', coalesce((SELECT s.stripe_transfers FROM public.exos_org_promoter_payouts s WHERE s.org_id = p.org_id), false),
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
                            AND po.transfer_status IN ('pending', 'sending', 'dry_run', 'failed')), 0) AS processing,
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

-- The org's active promoters ranked by tickets (all time, or one of the org's
-- events). Token-gated like the kit; names and ticket counts only. The top
-- p_limit (max 25) plus the caller's own row.
CREATE OR REPLACE FUNCTION public.exos_promoter_leaderboard(p_token uuid, p_event_id uuid DEFAULT NULL, p_limit integer DEFAULT 10)
RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  WITH me AS (
    SELECT p.id, p.org_id FROM public.exos_promoters p WHERE p.kit_token = p_token AND p.status = 'active'
  ), board AS (
    SELECT p.id, p.name, count(t.id)::int AS tickets,
           rank() OVER (ORDER BY count(t.id) DESC)::int AS rnk,
           row_number() OVER (ORDER BY count(t.id) DESC, p.name, p.id) AS rn
      FROM me
      JOIN public.exos_promoters p ON p.org_id = me.org_id AND p.status = 'active'
      LEFT JOIN public.exos_tickets t
             ON t.org_id = p.org_id AND t.promoter_id = p.code AND t.status IN ('active', 'used', 'transferred')
            AND (p_event_id IS NULL OR t.event_id = p_event_id)
     GROUP BY p.id, p.name
  )
  SELECT CASE WHEN NOT EXISTS (SELECT 1 FROM me) THEN NULL
              WHEN p_event_id IS NOT NULL AND NOT EXISTS (
                     SELECT 1 FROM public.exos_events e, me WHERE e.id = p_event_id AND e.org_id = me.org_id) THEN NULL
              ELSE jsonb_build_object(
    'promoters', (SELECT count(*) FROM board),
    'rows', coalesce((SELECT jsonb_agg(jsonb_build_object('rank', b.rnk, 'name', b.name, 'tickets', b.tickets,
                                                          'me', b.id = (SELECT id FROM me)) ORDER BY b.rn)
                        FROM board b
                       WHERE b.rn <= least(greatest(coalesce(p_limit, 10), 1), 25) OR b.id = (SELECT id FROM me)), '[]'::jsonb))
         END
$$;
REVOKE ALL ON FUNCTION public.exos_promoter_leaderboard(uuid, uuid, integer) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.exos_promoter_leaderboard(uuid, uuid, integer) TO anon, authenticated, service_role;

-- ===========================================================================
-- B1. Instant payouts ledger (service role: exos-instant-payouts).
-- ===========================================================================
CREATE TABLE IF NOT EXISTS public.exos_org_instant_payouts (
  id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id             uuid NOT NULL REFERENCES public.exos_orgs (id) ON DELETE CASCADE,
  currency           text NOT NULL CHECK (currency ~ '^[a-z]{3}$'),
  amount_cents       integer NOT NULL CHECK (amount_cents > 0),
  fee_estimate_cents integer NOT NULL CHECK (fee_estimate_cents >= 0),
  idempotency_key    text NOT NULL CHECK (idempotency_key ~ '^[A-Za-z0-9_-]{8,80}$'),
  status             text NOT NULL DEFAULT 'requested' CHECK (status IN ('requested', 'sent', 'dry_run', 'failed')),
  stripe_payout_id   text CHECK (stripe_payout_id IS NULL OR stripe_payout_id ~ '^po_[A-Za-z0-9]{1,64}$'),
  error              text CHECK (error IS NULL OR length(error) <= 300),
  requested_by       uuid REFERENCES auth.users (id) ON DELETE SET NULL,
  created_at         timestamptz NOT NULL DEFAULT now(),
  updated_at         timestamptz NOT NULL DEFAULT now(),
  UNIQUE (org_id, idempotency_key),
  CHECK (status <> 'sent' OR stripe_payout_id IS NOT NULL)
);
CREATE INDEX IF NOT EXISTS exos_org_instant_payouts_org_idx ON public.exos_org_instant_payouts (org_id, created_at DESC);
ALTER TABLE public.exos_org_instant_payouts ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.exos_org_instant_payouts FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.exos_org_instant_payouts TO authenticated;
GRANT ALL ON public.exos_org_instant_payouts TO service_role;
DROP POLICY IF EXISTS exos_org_instant_payouts_read ON public.exos_org_instant_payouts;
CREATE POLICY exos_org_instant_payouts_read ON public.exos_org_instant_payouts FOR SELECT TO authenticated
  USING (public.exos_has_org_role(org_id, ARRAY['owner', 'finance']));
DROP TRIGGER IF EXISTS exos_org_instant_payouts_touch ON public.exos_org_instant_payouts;
CREATE TRIGGER exos_org_instant_payouts_touch BEFORE UPDATE ON public.exos_org_instant_payouts
  FOR EACH ROW EXECUTE FUNCTION public.exos_touch_updated_at();

-- Record a request before Stripe is called. p_user must own the org. The same
-- key returns the same row; at most 5 requests per org per 24 hours.
CREATE OR REPLACE FUNCTION public.exos_instant_payout_begin(
  p_org_id uuid, p_user uuid, p_amount_cents integer, p_currency text, p_fee_estimate_cents integer, p_idempotency_key text
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  r public.exos_org_instant_payouts%ROWTYPE;
  v_n integer;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.exos_org_memberships m
                  WHERE m.org_id = p_org_id AND m.user_id = p_user AND m.role = 'owner' AND m.disabled IS NOT TRUE) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'owner_only');
  END IF;
  PERFORM pg_advisory_xact_lock(hashtextextended('exos-instant:' || p_org_id, 0));
  SELECT * INTO r FROM public.exos_org_instant_payouts WHERE org_id = p_org_id AND idempotency_key = p_idempotency_key;
  IF r.id IS NOT NULL THEN
    IF r.amount_cents <> p_amount_cents OR r.currency <> lower(p_currency) THEN
      RETURN jsonb_build_object('ok', false, 'error', 'key_reused');
    END IF;
    RETURN jsonb_build_object('ok', true, 'id', r.id, 'replayed', true, 'status', r.status, 'stripe_payout_id', r.stripe_payout_id);
  END IF;
  SELECT count(*) INTO v_n FROM public.exos_org_instant_payouts
   WHERE org_id = p_org_id AND created_at > now() - interval '24 hours' AND status <> 'failed';
  IF v_n >= 5 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'daily_limit');
  END IF;
  INSERT INTO public.exos_org_instant_payouts (org_id, currency, amount_cents, fee_estimate_cents, idempotency_key, requested_by)
  VALUES (p_org_id, lower(p_currency), p_amount_cents, greatest(coalesce(p_fee_estimate_cents, 0), 0), p_idempotency_key, p_user)
  RETURNING * INTO r;
  RETURN jsonb_build_object('ok', true, 'id', r.id, 'replayed', false, 'status', r.status);
END $$;
REVOKE ALL ON FUNCTION public.exos_instant_payout_begin(uuid, uuid, integer, text, integer, text) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.exos_instant_payout_begin(uuid, uuid, integer, text, integer, text) TO service_role;

CREATE OR REPLACE FUNCTION public.exos_instant_payout_mark(p_id uuid, p_status text, p_payout_id text DEFAULT NULL, p_error text DEFAULT NULL)
RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE v_n integer;
BEGIN
  IF p_status NOT IN ('sent', 'dry_run', 'failed') THEN
    RAISE EXCEPTION 'exos_instant_payout_mark: bad status' USING ERRCODE = '22023';
  END IF;
  UPDATE public.exos_org_instant_payouts
     SET status = p_status, stripe_payout_id = coalesce(p_payout_id, stripe_payout_id),
         error = CASE WHEN p_status = 'failed' THEN left(coalesce(p_error, 'failed'), 300) END
   WHERE id = p_id AND status IN ('requested', 'failed', 'dry_run');
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN v_n > 0;
END $$;
REVOKE ALL ON FUNCTION public.exos_instant_payout_mark(uuid, text, text, text) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.exos_instant_payout_mark(uuid, text, text, text) TO service_role;

-- ===========================================================================
-- B2. Money so far: the end-of-night summary for one event.
--     Owner / manager / finance. Integer cents.
-- ===========================================================================
CREATE OR REPLACE FUNCTION public.exos_event_money_so_far(p_event_id uuid)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  e public.exos_events%ROWTYPE;
  v_online jsonb;
  v_door jsonb;
  v_tix jsonb;
  v_pc jsonb;
BEGIN
  SELECT * INTO e FROM public.exos_events WHERE id = p_event_id;
  IF e.id IS NULL OR NOT public.exos_has_org_role(e.org_id, ARRAY['owner', 'manager', 'finance']) THEN
    RAISE EXCEPTION 'exos_event_money_so_far: not allowed' USING ERRCODE = '42501';
  END IF;

  SELECT jsonb_build_object(
           'orders', count(*),
           'gross_cents', coalesce(sum(s.amount_cents), 0),
           'fees_cents', coalesce(sum(coalesce(s.application_fee_cents, 0)), 0),
           'tax_cents', coalesce(sum(coalesce(s.tax_cents, 0)), 0),
           'refunded_cents', coalesce(sum(r.refunded), 0),
           'net_cents', coalesce(sum(s.amount_cents - coalesce(s.application_fee_cents, 0) - coalesce(r.refunded, 0)), 0),
           'stripe_net_cents', coalesce(sum(s.amount_cents - coalesce(s.application_fee_cents, 0) - coalesce(r.refunded, 0))
                                   FILTER (WHERE coalesce(s.processor, 'stripe') = 'stripe'), 0),
           'paypal_net_cents', coalesce(sum(s.amount_cents - coalesce(s.application_fee_cents, 0) - coalesce(r.refunded, 0))
                                   FILTER (WHERE s.processor = 'paypal'), 0),
           'last_hour_gross_cents', coalesce(sum(s.amount_cents) FILTER (WHERE coalesce(s.fulfilled_at, s.created_at) > now() - interval '1 hour'), 0))
    INTO v_online
    FROM public.exos_checkout_sessions s
    LEFT JOIN LATERAL (SELECT sum(rf.amount_cents)::bigint AS refunded FROM public.exos_order_refunds rf
                        WHERE rf.session_id = s.session_id AND rf.status = 'succeeded') r ON true
   WHERE s.event_id = p_event_id AND s.amount_cents > 0
     AND s.status IN ('fulfilled', 'partially_refunded', 'refunded');

  SELECT jsonb_build_object(
           'cash_cents', coalesce(sum(pp.amount_cents) FILTER (WHERE pp.method = 'cash'), 0),
           'card_cents', coalesce(sum(pp.amount_cents) FILTER (WHERE pp.method = 'card'), 0),
           'comp_cents', coalesce(sum(pp.amount_cents) FILTER (WHERE pp.method = 'comp'), 0),
           'tips_cents', coalesce(sum(pp.tip_cents), 0))
    INTO v_door
    FROM public.exos_pos_payments pp
   WHERE pp.event_id = p_event_id AND pp.status = 'succeeded';

  SELECT jsonb_build_object(
           'paid', count(*) FILTER (WHERE t.price_paid > 0 AND t.status IN ('active', 'used', 'transferred')),
           'free', count(*) FILTER (WHERE coalesce(t.price_paid, 0) = 0 AND t.channel_source IS DISTINCT FROM 'comp'
                                      AND t.status IN ('active', 'used', 'transferred')),
           'comps', count(*) FILTER (WHERE t.channel_source = 'comp' AND t.status IN ('active', 'used', 'transferred')),
           'phone_rsvps', count(*) FILTER (WHERE t.order_ref LIKE 'rsvp:%' AND t.status IN ('active', 'used', 'transferred')),
           'checked_in', count(*) FILTER (WHERE t.status = 'used'),
           'voided', count(*) FILTER (WHERE t.status = 'voided'))
    INTO v_tix
    FROM public.exos_tickets t
   WHERE t.event_id = p_event_id;

  SELECT jsonb_build_object(
           'owed_cents', coalesce(sum(c.commission_cents) FILTER (WHERE c.status = 'accrued'), 0),
           'paid_cents', coalesce(sum(c.commission_cents) FILTER (WHERE c.status = 'paid'), 0),
           'tickets', count(*) FILTER (WHERE c.status <> 'reversed'))
    INTO v_pc
    FROM public.exos_promoter_commissions c
   WHERE c.event_id = p_event_id;

  RETURN jsonb_build_object(
    'event_id', e.id, 'name', e.name, 'currency', lower(coalesce(e.currency, 'usd')),
    'starts_at', e.starts_at, 'timezone', e.timezone,
    'online', v_online, 'door', v_door, 'tickets', v_tix, 'promoters', v_pc,
    'as_of', to_char(now() AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'));
END $$;
REVOKE ALL ON FUNCTION public.exos_event_money_so_far(uuid) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.exos_event_money_so_far(uuid) TO authenticated, service_role;

-- ===========================================================================
-- C1. Phone RSVP: settings and the ledger.
-- ===========================================================================
CREATE TABLE IF NOT EXISTS public.exos_phone_rsvp_settings (
  event_id      uuid PRIMARY KEY REFERENCES public.exos_events (id) ON DELETE CASCADE,
  org_id        uuid NOT NULL REFERENCES public.exos_orgs (id) ON DELETE CASCADE,
  enabled       boolean NOT NULL DEFAULT false,
  tier_id       uuid REFERENCES public.exos_ticket_tiers (id) ON DELETE SET NULL,
  max_plus_ones integer NOT NULL DEFAULT 0 CHECK (max_plus_ones BETWEEN 0 AND 9),
  updated_by    uuid REFERENCES auth.users (id) ON DELETE SET NULL,
  created_at    timestamptz NOT NULL DEFAULT now(),
  updated_at    timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS exos_phone_rsvp_settings_org_idx ON public.exos_phone_rsvp_settings (org_id);

CREATE TABLE IF NOT EXISTS public.exos_phone_rsvps (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id          uuid NOT NULL REFERENCES public.exos_orgs (id) ON DELETE CASCADE,
  event_id        uuid NOT NULL REFERENCES public.exos_events (id) ON DELETE CASCADE,
  tier_id         uuid REFERENCES public.exos_ticket_tiers (id) ON DELETE SET NULL,
  guest_name      text NOT NULL CHECK (length(btrim(guest_name)) BETWEEN 1 AND 80),
  phone           text NOT NULL CHECK (phone ~ '^\+[1-9][0-9]{7,14}$'),
  email           text CHECK (email IS NULL OR (length(email) <= 254 AND email ~ '^[^@\s]+@[^@\s]+\.[^@\s]+$')),
  plus_ones       integer NOT NULL DEFAULT 0 CHECK (plus_ones BETWEEN 0 AND 9),
  promoter_code   text CHECK (promoter_code IS NULL OR promoter_code ~ '^[A-Za-z0-9_-]{1,64}$'),
  channel         text NOT NULL CHECK (channel IN ('sms', 'email')),
  status          text NOT NULL DEFAULT 'pending'
                    CHECK (status IN ('pending', 'confirmed', 'duplicate', 'expired', 'locked', 'sold_out')),
  code_hash       text NOT NULL CHECK (code_hash ~ '^[0-9a-f]{64}$'),
  code_expires_at timestamptz NOT NULL,
  attempts        integer NOT NULL DEFAULT 0 CHECK (attempts BETWEEN 0 AND 10),
  ip_hash         text CHECK (ip_hash IS NULL OR ip_hash ~ '^[0-9a-f]{16,128}$'),
  ticket_ids      uuid[],
  -- A row anon gets an ordinary answer for but that can never verify: the
  -- email fallback refused for an RSVP'd number, or a sold-out log row.
  decoy           boolean NOT NULL DEFAULT false,
  verified_at     timestamptz,
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now(),
  CHECK (status NOT IN ('confirmed', 'duplicate') OR (verified_at IS NOT NULL AND cardinality(ticket_ids) >= 1))
);
-- One RSVP per phone per event; a second verified RSVP is a 'duplicate' that
-- resends the first one's tickets.
CREATE UNIQUE INDEX IF NOT EXISTS exos_phone_rsvps_one_per_phone_uq
  ON public.exos_phone_rsvps (event_id, phone) WHERE status = 'confirmed';
CREATE INDEX IF NOT EXISTS exos_phone_rsvps_phone_idx ON public.exos_phone_rsvps (phone, created_at);
CREATE INDEX IF NOT EXISTS exos_phone_rsvps_ip_idx ON public.exos_phone_rsvps (ip_hash, created_at) WHERE ip_hash IS NOT NULL;
CREATE INDEX IF NOT EXISTS exos_phone_rsvps_event_idx ON public.exos_phone_rsvps (event_id, created_at);
CREATE INDEX IF NOT EXISTS exos_phone_rsvps_org_idx ON public.exos_phone_rsvps (org_id);

ALTER TABLE public.exos_phone_rsvp_settings ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.exos_phone_rsvp_settings FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.exos_phone_rsvp_settings TO authenticated;
GRANT ALL ON public.exos_phone_rsvp_settings TO service_role;
DROP POLICY IF EXISTS exos_phone_rsvp_settings_staff_read ON public.exos_phone_rsvp_settings;
CREATE POLICY exos_phone_rsvp_settings_staff_read ON public.exos_phone_rsvp_settings FOR SELECT TO authenticated
  USING (public.exos_has_org_role(org_id, ARRAY['owner', 'manager', 'finance']));

-- Guests' phone numbers: owner / manager only, and never the code hash or
-- the hashed IP (column grant).
ALTER TABLE public.exos_phone_rsvps ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.exos_phone_rsvps FROM PUBLIC, anon, authenticated;
GRANT SELECT (id, org_id, event_id, tier_id, guest_name, phone, email, plus_ones, promoter_code, channel,
              status, attempts, ticket_ids, verified_at, created_at, updated_at)
  ON public.exos_phone_rsvps TO authenticated;
GRANT ALL ON public.exos_phone_rsvps TO service_role;
DO $$
DECLARE r text;
BEGIN
  FOREACH r IN ARRAY ARRAY['coworker_readonly', 'analyst_ro'] LOOP
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = r) THEN
      EXECUTE format('REVOKE ALL ON public.exos_phone_rsvps FROM %I', r);
    END IF;
  END LOOP;
END $$;
DROP POLICY IF EXISTS exos_phone_rsvps_staff_read ON public.exos_phone_rsvps;
CREATE POLICY exos_phone_rsvps_staff_read ON public.exos_phone_rsvps FOR SELECT TO authenticated
  USING (public.exos_has_org_role(org_id, ARRAY['owner', 'manager']));

DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['exos_phone_rsvp_settings', 'exos_phone_rsvps'] LOOP
    EXECUTE format('DROP TRIGGER IF EXISTS %I ON public.%I', t || '_touch', t);
    EXECUTE format('CREATE TRIGGER %I BEFORE UPDATE ON public.%I FOR EACH ROW EXECUTE FUNCTION public.exos_touch_updated_at()',
                   t || '_touch', t);
  END LOOP;
END $$;

-- Mail template allowlist (+ rsvp-code): live list ∪ new.
DO $$
DECLARE
  v_def  text;
  v_live text[];
  v_new  text[] := ARRAY['rsvp-code'];
  v_vals text[];
BEGIN
  SELECT pg_get_constraintdef(c.oid) INTO v_def
    FROM pg_constraint c
   WHERE c.conrelid = 'public.exos_mail'::regclass AND c.conname = 'exos_mail_template_check';
  IF v_def IS NULL THEN
    RETURN;
  END IF;
  IF strpos(v_def, '''{') > 0 THEN
    v_live := string_to_array(substring(v_def FROM '''\{([^}]*)\}'''), ',');
  ELSE
    SELECT array_agg(m[1]) INTO v_live FROM regexp_matches(v_def, '''([^'']+)''', 'g') AS m;
  END IF;
  IF v_new <@ coalesce(v_live, '{}'::text[]) THEN
    RETURN;
  END IF;
  SELECT array_agg(DISTINCT x ORDER BY x) INTO v_vals FROM (
    SELECT btrim(unnest(coalesce(v_live, '{}'::text[]) || v_new), ' "') AS x
  ) u WHERE x <> '';
  ALTER TABLE public.exos_mail DROP CONSTRAINT IF EXISTS exos_mail_template_check;
  EXECUTE format('ALTER TABLE public.exos_mail ADD CONSTRAINT exos_mail_template_check '
                 'CHECK (template = ANY (ARRAY[%s]))',
                 (SELECT string_agg(quote_literal(x), ',' ORDER BY x) FROM unnest(v_vals) x));
END $$;

-- Owner / manager: turn phone RSVP on for an event. The tier (NULL = the
-- event's first free public standard tier) must be free, public, standard,
-- unseated and not sold by time slot.
CREATE OR REPLACE FUNCTION public.exos_set_phone_rsvp(p_event_id uuid, p_enabled boolean, p_tier_id uuid DEFAULT NULL, p_max_plus_ones integer DEFAULT 0)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_org uuid;
  tr public.exos_ticket_tiers%ROWTYPE;
BEGIN
  SELECT org_id INTO v_org FROM public.exos_events WHERE id = p_event_id;
  IF v_org IS NULL OR NOT public.exos_has_org_role(v_org, ARRAY['owner', 'manager']) THEN
    RAISE EXCEPTION 'exos_set_phone_rsvp: not allowed' USING ERRCODE = '42501';
  END IF;
  IF coalesce(p_max_plus_ones, 0) NOT BETWEEN 0 AND 9 THEN
    RAISE EXCEPTION 'Plus-ones must be from 0 to 9.' USING ERRCODE = '22023';
  END IF;
  IF p_tier_id IS NOT NULL THEN
    SELECT * INTO tr FROM public.exos_ticket_tiers WHERE id = p_tier_id AND event_id = p_event_id;
    IF tr.id IS NULL OR coalesce(tr.price, 0) <> 0 OR coalesce(tr.visibility, 'public') <> 'public'
       OR coalesce(tr.kind, 'standard') <> 'standard' OR coalesce(tr.seated, false)
       OR public._exos_tier_is_timed(tr.id) THEN
      RAISE EXCEPTION 'Phone RSVP needs a free, public, general-admission ticket type.' USING ERRCODE = '22023';
    END IF;
  END IF;
  INSERT INTO public.exos_phone_rsvp_settings AS s (event_id, org_id, enabled, tier_id, max_plus_ones, updated_by)
  VALUES (p_event_id, v_org, coalesce(p_enabled, false), p_tier_id, coalesce(p_max_plus_ones, 0), auth.uid())
  ON CONFLICT (event_id) DO UPDATE SET enabled = EXCLUDED.enabled, tier_id = EXCLUDED.tier_id,
    max_plus_ones = EXCLUDED.max_plus_ones, updated_by = EXCLUDED.updated_by;
  RETURN jsonb_build_object('enabled', coalesce(p_enabled, false), 'tier_id', p_tier_id,
                            'max_plus_ones', coalesce(p_max_plus_ones, 0));
END $$;
REVOKE ALL ON FUNCTION public.exos_set_phone_rsvp(uuid, boolean, uuid, integer) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.exos_set_phone_rsvp(uuid, boolean, uuid, integer) TO authenticated, service_role;

-- Is phone RSVP open for this event right now? (ok, reason, tier, plus-ones,
-- what's left). Internal.
CREATE OR REPLACE FUNCTION public._exos_phone_rsvp_offer(p_event_id uuid)
RETURNS TABLE (ok boolean, reason text, org_id uuid, tier_id uuid, tier_name text, max_plus_ones integer,
               seats_left integer, event_name text, starts_at timestamptz, timezone text)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  e  public.exos_events%ROWTYPE;
  st public.exos_phone_rsvp_settings%ROWTYPE;
  tr public.exos_ticket_tiers%ROWTYPE;
  v_left integer;
BEGIN
  SELECT * INTO e FROM public.exos_events WHERE id = p_event_id;
  SELECT * INTO st FROM public.exos_phone_rsvp_settings WHERE event_id = p_event_id;
  ok := false; org_id := e.org_id; max_plus_ones := coalesce(st.max_plus_ones, 0);
  event_name := e.name; starts_at := e.starts_at; timezone := e.timezone;
  IF e.id IS NULL OR e.status <> 'published' THEN reason := 'closed'; RETURN NEXT; RETURN; END IF;
  IF NOT coalesce(st.enabled, false) THEN reason := 'off'; RETURN NEXT; RETURN; END IF;
  IF coalesce(e.ticket_backend, 'exos') <> 'exos' THEN reason := 'off'; RETURN NEXT; RETURN; END IF;
  IF coalesce(e.ends_at, e.starts_at + interval '12 hours', now() + interval '1 day') < now() THEN
    reason := 'over'; RETURN NEXT; RETURN;
  END IF;
  IF st.tier_id IS NOT NULL THEN
    SELECT * INTO tr FROM public.exos_ticket_tiers t WHERE t.id = st.tier_id AND t.event_id = p_event_id;
  ELSE
    SELECT * INTO tr FROM public.exos_ticket_tiers t
     WHERE t.event_id = p_event_id AND coalesce(t.price, 0) = 0 AND coalesce(t.visibility, 'public') = 'public'
       AND coalesce(t.kind, 'standard') = 'standard' AND NOT coalesce(t.seated, false)
       AND NOT public._exos_tier_is_timed(t.id)
     ORDER BY t.sort_order NULLS LAST, t.name, t.id LIMIT 1;
  END IF;
  IF tr.id IS NULL OR coalesce(tr.price, 0) <> 0 OR coalesce(tr.visibility, 'public') <> 'public'
     OR coalesce(tr.kind, 'standard') <> 'standard' OR coalesce(tr.seated, false) OR public._exos_tier_is_timed(tr.id) THEN
    reason := 'off'; RETURN NEXT; RETURN;
  END IF;
  IF (tr.sales_start IS NOT NULL AND now() < tr.sales_start) OR (tr.sales_end IS NOT NULL AND now() > tr.sales_end) THEN
    reason := 'closed'; RETURN NEXT; RETURN;
  END IF;
  tier_id := tr.id; tier_name := tr.name;
  v_left := public.exos_effective_available(tr.id);
  IF tr.capacity > 0 THEN v_left := least(coalesce(v_left, tr.capacity - tr.sold), tr.capacity - tr.sold); END IF;
  IF e.total_tickets > 0 THEN v_left := least(coalesce(v_left, e.total_tickets - e.tickets_sold), e.total_tickets - e.tickets_sold); END IF;
  seats_left := greatest(coalesce(v_left, 1000000), 0);
  IF seats_left <= 0 THEN reason := 'sold_out'; RETURN NEXT; RETURN; END IF;
  ok := true; reason := 'open';
  RETURN NEXT;
END $$;
REVOKE ALL ON FUNCTION public._exos_phone_rsvp_offer(uuid) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public._exos_phone_rsvp_offer(uuid) TO service_role;

-- What the RSVP page needs (service role: exos-rsvp adds whether texts work).
CREATE OR REPLACE FUNCTION public.exos_phone_rsvp_info(p_event_id uuid)
RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT jsonb_build_object('ok', o.ok, 'reason', o.reason, 'org_id', o.org_id, 'tier_name', o.tier_name,
                            'max_plus_ones', o.max_plus_ones, 'event_name', o.event_name,
                            'starts_at', o.starts_at, 'timezone', o.timezone)
    FROM public._exos_phone_rsvp_offer(p_event_id) o
$$;
REVOKE ALL ON FUNCTION public.exos_phone_rsvp_info(uuid) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.exos_phone_rsvp_info(uuid) TO service_role;

-- ===========================================================================
-- C2. Start: rate limits, then a one-time code (service role: exos-rsvp).
--     p_sms_ok: the org can text right now (provider connected and sending
--     live); else the code is mailed when an email was given. Returns
--     {ok, rsvp_id, code, channel, to} (the caller texts the code) or
--     {ok:false, error}. Never says whether the phone already RSVP'd.
-- ===========================================================================
CREATE OR REPLACE FUNCTION public.exos_phone_rsvp_start(
  p_event_id  uuid,
  p_name      text,
  p_phone     text,
  p_email     text,
  p_plus_ones integer,
  p_ip_hash   text,
  p_sms_ok    boolean,
  p_promoter  text DEFAULT NULL,
  p_app_base  text DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  o       record;
  v_phone text := public.exos_sms_normalize_phone(p_phone);
  v_name  text := left(regexp_replace(btrim(coalesce(p_name, '')), '\s+', ' ', 'g'), 80);
  v_email text := NULLIF(lower(btrim(coalesce(p_email, ''))), '');
  v_ip    text := NULLIF(btrim(coalesce(p_ip_hash, '')), '');
  v_plus  integer := coalesce(p_plus_ones, 0);
  v_chan  text;
  v_code  text;
  v_id    uuid := gen_random_uuid();
  v_promo text;
  v_safe  text;
  v_prev  public.exos_phone_rsvps%ROWTYPE;
  v_decoy boolean := false;
  v_full  boolean;
  v_links text := '';
  v_urls  jsonb;
  i       integer;
BEGIN
  IF length(v_name) < 1 THEN RETURN jsonb_build_object('ok', false, 'error', 'bad_name'); END IF;
  IF v_phone IS NULL THEN RETURN jsonb_build_object('ok', false, 'error', 'bad_phone'); END IF;
  IF v_email IS NOT NULL AND (length(v_email) > 254 OR v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'bad_email');
  END IF;
  IF v_ip IS NOT NULL AND v_ip !~ '^[0-9a-f]{16,128}$' THEN v_ip := NULL; END IF;

  -- Nothing anon sees may depend on whether this number already RSVP'd (no
  -- enumeration oracle): the answers below are the same either way, and
  -- what differs is only where messages go, always to a proven channel.
  SELECT * INTO o FROM public._exos_phone_rsvp_offer(p_event_id);
  IF NOT o.ok AND o.reason <> 'sold_out' THEN RETURN jsonb_build_object('ok', false, 'error', o.reason); END IF;
  IF v_plus NOT BETWEEN 0 AND o.max_plus_ones THEN
    RETURN jsonb_build_object('ok', false, 'error', 'too_many_guests', 'max_plus_ones', o.max_plus_ones);
  END IF;
  v_full := NOT o.ok OR o.seats_left < 1 + v_plus;
  SELECT * INTO v_prev FROM public.exos_phone_rsvps x
   WHERE x.event_id = p_event_id AND x.phone = v_phone AND x.status = 'confirmed';

  -- Channel: a text when the org can send one and the number hasn't opted out
  -- of its texts; else the guest's email; else not available.
  IF coalesce(p_sms_ok, false) AND NOT EXISTS (
       SELECT 1 FROM public.exos_sms_subscribers s
        WHERE s.org_id = o.org_id AND s.phone = v_phone AND s.opted_out_at IS NOT NULL) THEN
    v_chan := 'sms';
  ELSIF v_email IS NOT NULL THEN
    -- The email fallback proves an inbox, not the phone: it is only for a
    -- number with no confirmed RSVP here, or the very email that confirmed
    -- it. Anything else gets the same answer ("if this number and email can
    -- RSVP, we've emailed a code") but a decoy row: no mail, never verifies.
    v_decoy := v_prev.id IS NOT NULL
               AND NOT (v_prev.channel = 'email' AND v_prev.email IS NOT NULL AND lower(v_prev.email) = v_email);
    v_chan := 'email';
  ELSE
    RETURN jsonb_build_object('ok', false, 'error', 'no_channel');
  END IF;

  -- Rate limits, serialized per phone (and per network when known).
  PERFORM pg_advisory_xact_lock(hashtextextended('exos-rsvp-phone:' || v_phone, 0));
  IF v_ip IS NOT NULL THEN PERFORM pg_advisory_xact_lock(hashtextextended('exos-rsvp-ip:' || v_ip, 0)); END IF;
  IF (SELECT count(*) FROM public.exos_phone_rsvps WHERE phone = v_phone AND created_at > now() - interval '10 minutes') >= 3
     OR (SELECT count(*) FROM public.exos_phone_rsvps WHERE phone = v_phone AND created_at > now() - interval '24 hours') >= 8
     OR (v_ip IS NOT NULL AND (SELECT count(*) FROM public.exos_phone_rsvps WHERE ip_hash = v_ip AND created_at > now() - interval '10 minutes') >= 10)
     OR (v_ip IS NOT NULL AND (SELECT count(*) FROM public.exos_phone_rsvps WHERE ip_hash = v_ip AND created_at > now() - interval '24 hours') >= 40)
     OR (SELECT count(*) FROM public.exos_phone_rsvps WHERE event_id = p_event_id AND created_at > now() - interval '10 minutes') >= 200 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'rate_limited');
  END IF;

  -- Full: the same "sold out" for everyone. A number that already RSVP'd
  -- gets its tickets again, but only through a proven channel: by text to
  -- this very number, or by email to exactly the email that confirmed it.
  -- A log row (never verifiable) keeps the rate limits counting.
  IF v_full THEN
    INSERT INTO public.exos_phone_rsvps (org_id, event_id, tier_id, guest_name, phone, email, plus_ones, channel, status,
                                         code_hash, code_expires_at, ip_hash, decoy)
    VALUES (o.org_id, p_event_id, o.tier_id, v_name, v_phone, v_email, v_plus, v_chan, 'expired',
            encode(extensions.gen_random_bytes(32), 'hex'), now(), v_ip, true);
    IF v_prev.id IS NOT NULL THEN
      SELECT coalesce(jsonb_agg(public._exos_ticket_link_url(x.id, coalesce(p_app_base, '')) ORDER BY x.ord), '[]'::jsonb)
        INTO v_urls FROM unnest(v_prev.ticket_ids) WITH ORDINALITY AS x(id, ord);
      IF v_chan = 'sms' THEN
        -- '_resend' is for exos-rsvp only (it texts the links and strips it).
        RETURN jsonb_build_object('ok', false, 'error', 'sold_out',
                                  '_resend', jsonb_build_object('to', v_phone, 'org_id', o.org_id, 'event_name', o.event_name,
                                                                'urls', v_urls));
      ELSIF NOT v_decoy AND p_app_base ~ '^https://[A-Za-z0-9.-]+(:[0-9]{1,5})?(/[A-Za-z0-9._~/-]*)?$' THEN
        v_safe := replace(replace(replace(coalesce(o.event_name, 'your event'), '&', '&amp;'), '<', '&lt;'), '>', '&gt;');
        FOR i IN 1..jsonb_array_length(v_urls) LOOP
          IF v_urls ->> (i - 1) IS NOT NULL THEN
            v_links := v_links || '<li><a href="' || (v_urls ->> (i - 1)) || '">Open ticket ' || i || '</a></li>';
          END IF;
        END LOOP;
        IF v_links <> '' THEN
          INSERT INTO public.exos_mail (template, to_email, subject, html, status)
          VALUES ('ticket-issued', v_email, left('Your tickets: ' || coalesce(o.event_name, 'your RSVP'), 200),
                  '<p>Here are your tickets for <strong>' || v_safe || '</strong> again.</p><ul>' || v_links ||
                  '</ul><p>Anyone with a link can use that ticket.</p>', 'pending');
        END IF;
      END IF;
    END IF;
    RETURN jsonb_build_object('ok', false, 'error', 'sold_out');
  END IF;

  -- A newer code replaces any older pending one for this phone and event.
  UPDATE public.exos_phone_rsvps SET status = 'expired'
   WHERE event_id = p_event_id AND phone = v_phone AND status = 'pending';

  SELECT p.code INTO v_promo FROM public.exos_promoters p
   WHERE p.org_id = o.org_id AND p.code = btrim(coalesce(p_promoter, '')) AND p.status = 'active';

  v_code := lpad((('x00000000' || encode(extensions.gen_random_bytes(4), 'hex'))::bit(64)::bigint % 1000000)::text, 6, '0');
  INSERT INTO public.exos_phone_rsvps (id, org_id, event_id, tier_id, guest_name, phone, email, plus_ones, promoter_code,
                                       channel, code_hash, code_expires_at, ip_hash, decoy)
  VALUES (v_id, o.org_id, p_event_id, o.tier_id, v_name, v_phone, v_email, v_plus, v_promo,
          v_chan, encode(extensions.digest(v_id::text || ':' || v_code, 'sha256'), 'hex'), now() + interval '10 minutes', v_ip,
          v_decoy);

  IF v_decoy THEN
    RETURN jsonb_build_object('ok', true, 'rsvp_id', v_id, 'channel', 'email', 'to', v_email);
  END IF;
  IF v_chan = 'email' THEN
    v_safe := replace(replace(replace(coalesce(o.event_name, 'your event'), '&', '&amp;'), '<', '&lt;'), '>', '&gt;');
    INSERT INTO public.exos_mail (template, to_email, subject, html, status)
    VALUES ('rsvp-code', v_email, left('Your code for ' || coalesce(o.event_name, 'your RSVP'), 200),
            '<p>Your code for <strong>' || v_safe || '</strong> is</p><p style="font-size:28px;letter-spacing:6px"><strong>' ||
            v_code || '</strong></p><p>It works for 10 minutes. If you didn''t ask for it, ignore this email.</p>',
            'pending');
    RETURN jsonb_build_object('ok', true, 'rsvp_id', v_id, 'channel', 'email', 'to', v_email);
  END IF;
  RETURN jsonb_build_object('ok', true, 'rsvp_id', v_id, 'channel', 'sms', 'to', v_phone, 'code', v_code,
                            'org_id', o.org_id, 'event_name', o.event_name);
END $$;
REVOKE ALL ON FUNCTION public.exos_phone_rsvp_start(uuid, text, text, text, integer, text, boolean, text, text) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.exos_phone_rsvp_start(uuid, text, text, text, integer, text, boolean, text, text) TO service_role;

-- ===========================================================================
-- C3. Verify: the code, then the ticket(s). Service role (exos-rsvp).
--     Returns {ok, status:'confirmed', tickets:[{id, url}], channel, to,
--     phone, org_id, event_name} or {ok:false, error, attempts_left?}.
-- ===========================================================================
CREATE OR REPLACE FUNCTION public.exos_phone_rsvp_verify(p_rsvp_id uuid, p_code text, p_app_base text)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  r       public.exos_phone_rsvps%ROWTYPE;
  v_prev  public.exos_phone_rsvps%ROWTYPE;
  o       record;
  v_owner uuid;
  v_qty   integer;
  v_n     integer;
  v_id    uuid;
  v_ids   uuid[] := '{}';
  v_out   jsonb;
  v_safe  text;
  v_links text := '';
  i       integer;
BEGIN
  SELECT * INTO r FROM public.exos_phone_rsvps WHERE id = p_rsvp_id FOR UPDATE;
  IF r.id IS NULL THEN RETURN jsonb_build_object('ok', false, 'error', 'expired'); END IF;
  IF r.status IN ('confirmed', 'duplicate') THEN
    -- Re-verifying a used code changes nothing and shows nothing.
    RETURN jsonb_build_object('ok', false, 'error', 'used');
  END IF;
  IF r.status = 'locked' OR r.attempts >= 5 THEN RETURN jsonb_build_object('ok', false, 'error', 'locked'); END IF;
  IF r.status <> 'pending' OR r.code_expires_at <= now() THEN
    UPDATE public.exos_phone_rsvps SET status = 'expired' WHERE id = r.id AND status = 'pending';
    RETURN jsonb_build_object('ok', false, 'error', 'expired');
  END IF;
  IF p_code IS NULL OR btrim(p_code) !~ '^[0-9]{6}$' OR r.decoy
     OR encode(extensions.digest(r.id::text || ':' || btrim(p_code), 'sha256'), 'hex') <> r.code_hash THEN
    UPDATE public.exos_phone_rsvps
       SET attempts = attempts + 1, status = CASE WHEN attempts + 1 >= 5 THEN 'locked' ELSE status END
     WHERE id = r.id;
    RETURN jsonb_build_object('ok', false, 'error', CASE WHEN r.attempts + 1 >= 5 THEN 'locked' ELSE 'wrong_code' END,
                              'attempts_left', greatest(5 - (r.attempts + 1), 0));
  END IF;

  -- One RSVP per phone per event. A second one gets the first's tickets back
  -- ONLY through the channel that proves the same holder: this code went by
  -- text to the phone itself, or by email to exactly the email that
  -- confirmed the first one. Otherwise a generic "already", no links or ids
  -- (an attacker can't type a victim's number with their own email).
  PERFORM pg_advisory_xact_lock(hashtextextended('exos-rsvp-mint:' || r.event_id || ':' || r.phone, 0));
  SELECT * INTO v_prev FROM public.exos_phone_rsvps
   WHERE event_id = r.event_id AND phone = r.phone AND status = 'confirmed' AND id <> r.id;
  IF v_prev.id IS NOT NULL AND NOT (
       r.channel = 'sms'
       OR (r.channel = 'email' AND v_prev.channel = 'email' AND v_prev.email IS NOT NULL AND r.email IS NOT NULL
           AND lower(r.email) = lower(v_prev.email))) THEN
    UPDATE public.exos_phone_rsvps SET status = 'expired' WHERE id = r.id;
    -- The same answer as an expired code: nothing says the number RSVP'd.
    RETURN jsonb_build_object('ok', false, 'error', 'expired');
  END IF;
  IF v_prev.id IS NOT NULL THEN
    UPDATE public.exos_phone_rsvps SET status = 'duplicate', verified_at = now(), ticket_ids = v_prev.ticket_ids
     WHERE id = r.id;
    v_ids := v_prev.ticket_ids;
  ELSE
    SELECT * INTO o FROM public._exos_phone_rsvp_offer(r.event_id);
    IF NOT o.ok AND o.reason <> 'sold_out' THEN
      UPDATE public.exos_phone_rsvps SET status = 'expired' WHERE id = r.id;
      RETURN jsonb_build_object('ok', false, 'error', o.reason);
    END IF;
    SELECT owner_uid INTO v_owner FROM public.exos_orgs WHERE id = r.org_id;
    v_qty := 1 + r.plus_ones;
    BEGIN
      IF NOT o.ok OR o.tier_id IS DISTINCT FROM r.tier_id OR v_owner IS NULL THEN
        RAISE EXCEPTION 'sold out' USING ERRCODE = 'EXSLD';
      END IF;
      PERFORM public.exos_assert_quota(r.tier_id, v_qty);
      UPDATE public.exos_ticket_tiers SET sold = sold + v_qty
       WHERE id = r.tier_id AND event_id = r.event_id
         AND (capacity = 0 OR sold + v_qty <= capacity) AND public.exos_seats_available(r.tier_id, v_qty);
      GET DIAGNOSTICS v_n = ROW_COUNT;
      IF v_n = 0 THEN RAISE EXCEPTION 'sold out' USING ERRCODE = 'EXSLD'; END IF;
      UPDATE public.exos_events SET tickets_sold = tickets_sold + v_qty
       WHERE id = r.event_id AND (total_tickets = 0 OR tickets_sold + v_qty <= total_tickets);
      GET DIAGNOSTICS v_n = ROW_COUNT;
      IF v_n = 0 THEN RAISE EXCEPTION 'sold out' USING ERRCODE = 'EXSLD'; END IF;
      FOR i IN 1..v_qty LOOP
        INSERT INTO public.exos_tickets (
          event_id, org_id, tier_id, tier_name, buyer_id, owner_id, buyer_email,
          status, barcode_secret, price_paid, order_ref, channel_source, promoter_id, attendee_name
        ) VALUES (
          r.event_id, r.org_id, r.tier_id, o.tier_name, v_owner, v_owner, r.email,
          'active', gen_random_uuid()::text, 0, 'rsvp:' || r.id, 'vibepass', r.promoter_code,
          CASE WHEN i = 1 THEN r.guest_name ELSE left('Guest of ' || r.guest_name, 80) END
        ) RETURNING id INTO v_id;
        v_ids := v_ids || v_id;
      END LOOP;
    EXCEPTION WHEN SQLSTATE 'EXSLD' OR check_violation THEN
      UPDATE public.exos_phone_rsvps SET status = 'sold_out', verified_at = now() WHERE id = r.id;
      RETURN jsonb_build_object('ok', false, 'error', 'sold_out', 'event_id', r.event_id);
    END;
    UPDATE public.exos_phone_rsvps SET status = 'confirmed', verified_at = now(), ticket_ids = v_ids WHERE id = r.id;
  END IF;

  SELECT coalesce(jsonb_agg(jsonb_build_object('id', x.id, 'url', public._exos_ticket_link_url(x.id, p_app_base)) ORDER BY x.ord), '[]'::jsonb)
    INTO v_out
    FROM unnest(v_ids) WITH ORDINALITY AS x(id, ord);

  IF r.channel = 'email' AND r.email IS NOT NULL
     AND p_app_base ~ '^https://[A-Za-z0-9.-]+(:[0-9]{1,5})?(/[A-Za-z0-9._~/-]*)?$' THEN
    SELECT name INTO v_safe FROM public.exos_events WHERE id = r.event_id;
    v_safe := replace(replace(replace(coalesce(v_safe, 'your event'), '&', '&amp;'), '<', '&lt;'), '>', '&gt;');
    FOR i IN 1..jsonb_array_length(v_out) LOOP
      IF v_out -> (i - 1) ->> 'url' IS NOT NULL THEN
        v_links := v_links || '<li><a href="' || (v_out -> (i - 1) ->> 'url') || '">Open ticket ' || i || '</a></li>';
      END IF;
    END LOOP;
    IF v_links <> '' THEN
      INSERT INTO public.exos_mail (template, to_email, subject, html, status)
      VALUES ('ticket-issued', r.email, left('You''re in: ' || coalesce((SELECT name FROM public.exos_events WHERE id = r.event_id), 'your RSVP'), 200),
              '<p>You''re on the list for <strong>' || v_safe || '</strong>.</p>' ||
              '<p>Open your ticket on your phone at the door. Its QR code changes every 30 seconds, so screenshots won''t scan.</p>' ||
              '<ul>' || v_links || '</ul><p>Anyone with a link can use that ticket: send plus-one links to your guests only.</p>',
              'pending');
    END IF;
  END IF;

  RETURN jsonb_build_object('ok', true, 'status', 'confirmed', 'tickets', v_out, 'channel', r.channel,
                            'to', CASE WHEN r.channel = 'sms' THEN r.phone ELSE r.email END,
                            'org_id', r.org_id, 'event_id', r.event_id,
                            'event_name', (SELECT name FROM public.exos_events WHERE id = r.event_id));
END $$;
REVOKE ALL ON FUNCTION public.exos_phone_rsvp_verify(uuid, text, text) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.exos_phone_rsvp_verify(uuid, text, text) TO service_role;

-- ===========================================================================
-- C4. Claim a phone-RSVP ticket into the signed-in account, by its link key.
--     The ticket must still be parked on the org owner, active, with no
--     transfer pending. The barcode secret rotates, so the old link dies.
-- ===========================================================================
CREATE OR REPLACE FUNCTION public.exos_phone_rsvp_claim(p_ticket_id uuid, p_key text)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_uid uuid := auth.uid();
  t     public.exos_tickets%ROWTYPE;
  v_own uuid;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Sign in to save this ticket to your account.' USING ERRCODE = '42501';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM auth.users u WHERE u.id = v_uid AND u.email_confirmed_at IS NOT NULL) THEN
    RAISE EXCEPTION 'Confirm your email first, then save the ticket.' USING ERRCODE = '42501';
  END IF;
  IF p_ticket_id IS NULL OR p_key IS NULL OR p_key !~ '^[A-Za-z0-9_-]{43}$' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_found');
  END IF;
  SELECT * INTO t FROM public.exos_tickets WHERE id = p_ticket_id FOR UPDATE;
  IF t.id IS NULL OR t.owner_id IS NULL OR t.barcode_secret IS NULL
     OR public._exos_ticket_link_key(t.id, t.owner_id, t.barcode_secret) IS DISTINCT FROM p_key THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_found');
  END IF;
  SELECT owner_uid INTO v_own FROM public.exos_orgs WHERE id = t.org_id;
  IF t.order_ref IS NULL OR t.order_ref NOT LIKE 'rsvp:%' OR t.owner_id IS DISTINCT FROM v_own THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_claimable');
  END IF;
  IF t.status <> 'active' OR t.pending_transfer_id IS NOT NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_claimable');
  END IF;
  UPDATE public.exos_tickets
     SET owner_id = v_uid, buyer_id = v_uid,
         buyer_email = coalesce(nullif(lower(coalesce(auth.jwt() ->> 'email', '')), ''), buyer_email),
         barcode_secret = gen_random_uuid()::text, updated_at = now()
   WHERE id = t.id;
  RETURN jsonb_build_object('ok', true, 'ticket_id', t.id);
END $$;
REVOKE ALL ON FUNCTION public.exos_phone_rsvp_claim(uuid, text) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.exos_phone_rsvp_claim(uuid, text) TO authenticated, service_role;
