-- ============================================================================
-- Migration 20261121133000 — Exos pricing, operator 2026-11-21: the free tier
-- is UNDER 150 (149 or less), 150 or more is paid; the Exos fee is 2%
-- ============================================================================
-- Touches:  P: exos_free_tier_max_capacity()   (default 150 -> 149)
--              _exos_discovery_free_tier_max() (default 150 -> 149)
--              exos_platform_fee_bps()         (SELECT 300 -> SELECT 200)
--              exos_tg_marketplace_fee()       (a sale is priced once, C below)
--              _exos_resale_consent_version()  ('2026-10-29' -> '2026-11-21': the
--                                               opt-in text now says under 150)
--           W: COLUMN exos_marketplace_orders.exos_fee_bps (new, backfilled)
--           C: COMMENT ON TABLE exos_platform_settings (the default it names),
--              COMMENT ON COLUMN exos_checkout_sessions.exos_fee_cents (the rate)
-- Pre-reqs: 20260929062000, 20261029090000, 20261029130000
--
-- A. The free tier.
-- Operator 2026-11-21: "No 150 venue cap or more is paid". Until now the free
-- tier was a max capacity of 150 or less (free_tier_max_capacity, default
-- 150, read as an inclusive maximum). Now under 150 is free and 150 or more
-- pays the standard Exos fee and can resell (with the opt-in), so the
-- inclusive maximum becomes 149.
--
-- Prod has no free_tier_max_capacity row in exos_platform_settings (checked
-- read-only 2026-11-21), so it runs on the coded default; this migration
-- changes the default and inserts no row. An operator-set row still wins.
-- Every other SQL reader takes the number from exos_free_tier_max_capacity()
-- (exos_event_is_free_tier, exos_event_fee_terms, exos_event_sales_rules,
-- exos_resale_unlocked, exos_resale_min_capacity = 150 now,
-- _exos_resale_locked_msg, _exos_resale_consent_recheck,
-- exos_set_resale_consent, exos_mcp_* fee lines) or from
-- _exos_discovery_free_tier_max() (the 5 manual channels cap), so nothing
-- else changes. TS mirrors: FREE_TIER_MAX_CAPACITY (_shared/platformFee.ts)
-- and FREE_TIER_MAX_CAPACITY_DEFAULT (_shared/discovery/channels.ts) = 149.
--
-- An event already over 149 but not over 150 (exactly 150) leaves the free
-- tier: its later orders pay the standard fee (an org's first 6 months stay
-- free), and it can now be opted in to resale. No consent is revoked (the
-- rule only revokes when the capacity drops to the cutoff or below).
--
-- B. The Exos fee: 2% (200 bps), down from 3%.
-- Operator 2026-11-21: "2% for now". exos_platform_fee_bps() is the one SQL
-- rate (IMMUTABLE, no settings row reads it; prod had no fee setting row on
-- 2026-11-21, checked read-only); every reader goes through it:
-- exos_org_fee_bps (0 in the free months) -> exos_event_fee_bps (0 on the
-- free tier) -> exos_tg_marketplace_fee (exos_marketplace_orders.exos_fee),
-- exos_pos_settlement_summary and _exos_pos_card_begin (POS card sales),
-- _exos_feed_lines (S4K), and exos_send_mail_followups (fee-free-ending
-- mail). TS mirror: EXOS_FEE_BPS = 200 (_shared/platformFee.ts), used by
-- exos-checkout, exos-commerce, POS and recurring gifts; EXOS_PLATFORM_FEE_BPS
-- (env) must stay unset or 200. Checkout sessions already written keep the
-- fee they were charged (they record fee_bps); marketplace sales keep theirs
-- through C below. Every marketplace sale is Managed (Exos's channel accounts) and
-- takes the same 2%. A BYO sale (the organizer's own marketplace account,
-- not built) would take 0: it would branch in exos_tg_marketplace_fee before
-- exos_event_fee_bps.
--
-- C. A marketplace sale is priced once (Applier's review of this PR).
-- exos_tg_marketplace_fee ran on every UPDATE OF listing_ref / proceeds / ...
-- and recomputed exos_fee at the rate of the moment, and
-- exos_record_marketplace_order's upsert sets listing_ref on every re-poll
-- (exos-marketplace-sales re-checks known orders each run). So once the rate
-- moved, an unchanged re-poll re-priced a recorded sale (3% -> 2%: fee 2.40 ->
-- 1.60 on 80.00), the journal posted the difference and payouts paid it. The
-- same happened when an event left the free tier after a sale.
-- Now the rate a sale is first priced at is stored (exos_fee_bps) and never
-- re-read: a re-poll keeps the fee to the cent, and a real proceeds change is
-- re-priced at the stored rate. Rows written before this migration are
-- backfilled from their own fee (0 when it is 0, else 300 when it is 3% of
-- proceeds to the cent; anything else stays NULL and keeps its fee until its
-- proceeds change). The new column is written only by the trigger (the
-- table's one grant is SELECT to authenticated).
--
-- Applier's prod anchor check (supabase/README.md rule 4), read-only:
--   select pg_get_functiondef('public.exos_free_tier_max_capacity()'::regprocedure);
--     must contain once:  _exos_setting_int('free_tier_max_capacity', 150, -1, 999999)
--   select pg_get_functiondef('public._exos_discovery_free_tier_max()'::regprocedure);
--     must contain once:  WHERE key = 'free_tier_max_capacity'), 150)
--   select pg_get_functiondef('public.exos_platform_fee_bps()'::regprocedure);
--     must contain once:  SELECT 300
--   select pg_get_functiondef('public._exos_resale_consent_version()'::regprocedure);
--     must contain once:  SELECT '2026-10-29'::text
--   select pg_get_functiondef('public.exos_tg_marketplace_fee()'::regprocedure);
--     must contain once (mig 20260929062000 as patched by 20261029090000):
--       NEW.exos_fee := CASE WHEN NEW.proceeds IS NOT NULL
--         THEN round(NEW.proceeds * public.exos_event_fee_bps(NEW.event_id, coalesce(NEW.sold_at, NEW.created_at, now())) / 10000.0, 2) END;
-- The first three matched prod on 2026-11-21 (read-only); the last two are
-- still to check. Each patch is a counted text
-- replacement on pg_get_functiondef and is skipped when its end state is
-- already present, so the migration is re-run safe. Prod apply needs
-- operator OK.
-- ============================================================================

CREATE OR REPLACE FUNCTION pg_temp.exos_patch_n(p_sig text, p_marker text, p_old text, p_new text, p_hits int)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE p_fn regprocedure := to_regprocedure(p_sig); v_def text; v_hits int;
BEGIN
  IF p_fn IS NULL THEN
    RAISE EXCEPTION '%: not present', p_sig;
  END IF;
  v_def := replace(pg_get_functiondef(p_fn), chr(13), '');
  p_marker := replace(p_marker, chr(13), ''); p_old := replace(p_old, chr(13), ''); p_new := replace(p_new, chr(13), '');
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

-- The platform-wide number (authenticated may read it).
SELECT pg_temp.exos_patch_n('public.exos_free_tier_max_capacity()',
  $m$_exos_setting_int('free_tier_max_capacity', 149, -1, 999999)$m$,
  $o$_exos_setting_int('free_tier_max_capacity', 150, -1, 999999)$o$,
  $n$_exos_setting_int('free_tier_max_capacity', 149, -1, 999999)$n$, 1);

-- The discovery copy of the same default (the free tier's 5 manual channels).
SELECT pg_temp.exos_patch_n('public._exos_discovery_free_tier_max()',
  $m$WHERE key = 'free_tier_max_capacity'), 149)$m$,
  $o$WHERE key = 'free_tier_max_capacity'), 150)$o$,
  $n$WHERE key = 'free_tier_max_capacity'), 149)$n$, 1);

-- B. The Exos fee: 2%. The body is " SELECT 300 " on one line; the marker is
-- the new body, so a re-run skips it.
SELECT pg_temp.exos_patch_n('public.exos_platform_fee_bps()',
  $m$$function$ SELECT 200 $function$$m$,
  $o$ SELECT 300 $o$,
  $n$ SELECT 200 $n$, 1);

-- C. A marketplace sale is priced once: the rate it was first priced at.
ALTER TABLE public.exos_marketplace_orders ADD COLUMN IF NOT EXISTS exos_fee_bps integer;
COMMENT ON COLUMN public.exos_marketplace_orders.exos_fee_bps IS
  'The Exos rate (bps) the sale was first priced at (exos_event_fee_bps at the sale), kept for good: a re-poll keeps exos_fee, a proceeds change re-prices at this rate. Set only by exos_tg_marketplace_fee. Mig 20261121133000.';
COMMENT ON COLUMN public.exos_marketplace_orders.exos_fee IS
  'The Exos fee: exos_fee_bps of proceeds, to the cent, half up (priced once, mig 20261121133000). Mig 20260929062000.';
-- Rows priced before this migration (all at 300 or 0). The UPDATE OF column
-- list doesn't include exos_fee_bps, so this fires no fee trigger.
UPDATE public.exos_marketplace_orders
   SET exos_fee_bps = CASE WHEN exos_fee = 0 THEN 0
                           WHEN exos_fee = round(proceeds * 300 / 10000.0, 2) THEN 300 END
 WHERE exos_fee_bps IS NULL AND exos_fee IS NOT NULL AND proceeds IS NOT NULL;

SELECT pg_temp.exos_patch_n('public.exos_tg_marketplace_fee()',
  $m$NEW.exos_fee_bps := OLD.exos_fee_bps$m$,
  $o$  NEW.exos_fee := CASE WHEN NEW.proceeds IS NOT NULL
    THEN round(NEW.proceeds * public.exos_event_fee_bps(NEW.event_id, coalesce(NEW.sold_at, NEW.created_at, now())) / 10000.0, 2) END;$o$,
  $n$  -- exos: priced once (mig 20261121133000). The rate is read when the sale
  -- is first priced and kept (exos_fee_bps): a re-poll keeps the fee, a real
  -- proceeds change is re-priced at the same rate.
  IF TG_OP = 'UPDATE' THEN
    NEW.exos_fee_bps := OLD.exos_fee_bps;
  ELSE
    NEW.exos_fee_bps := NULL;
  END IF;
  IF NEW.proceeds IS NULL THEN
    NEW.exos_fee := NULL;
  ELSIF TG_OP = 'UPDATE' AND NEW.exos_fee_bps IS NULL AND OLD.exos_fee IS NOT NULL
        AND NEW.proceeds IS NOT DISTINCT FROM OLD.proceeds THEN
    NEW.exos_fee := OLD.exos_fee;   -- an older row whose rate isn't known, re-polled unchanged
  ELSE
    IF NEW.exos_fee_bps IS NULL THEN
      NEW.exos_fee_bps := public.exos_event_fee_bps(NEW.event_id, coalesce(NEW.sold_at, NEW.created_at, now()));
    END IF;
    NEW.exos_fee := round(NEW.proceeds * NEW.exos_fee_bps / 10000.0, 2);
  END IF;$n$, 1);

-- The resale opt-in text names the cutoff ("the free tier (under 150)"), so
-- its version moves with it: src/lib/marketplace/resaleConsent.ts
-- RESALE_CONSENT_VERSION is the same value (an opt-in must name the current
-- one, else 22023). Consents already given stay active
-- (exos_resale_consent_active doesn't read the version); prod had none on
-- 2026-11-21.
SELECT pg_temp.exos_patch_n('public._exos_resale_consent_version()',
  $m$SELECT '2026-11-21'::text$m$,
  $o$SELECT '2026-10-29'::text$o$,
  $n$SELECT '2026-11-21'::text$n$, 1);

-- The settings table's comment names the default.
DO $$
DECLARE v text := obj_description('public.exos_platform_settings'::regclass, 'pg_class');
BEGIN
  IF v IS NOT NULL AND position('free_tier_max_capacity (150)' in v) > 0 THEN
    EXECUTE format('COMMENT ON TABLE public.exos_platform_settings IS %L',
      replace(v, 'free_tier_max_capacity (150)', 'free_tier_max_capacity (149: under 150 is free, mig 20261121133000)'));
  END IF;
END $$;

-- The checkout column's comment names the rate.
DO $$
DECLARE v text := col_description('public.exos_checkout_sessions'::regclass,
  (SELECT attnum FROM pg_attribute WHERE attrelid = 'public.exos_checkout_sessions'::regclass AND attname = 'exos_fee_cents')::int);
BEGIN
  IF v IS NOT NULL AND position('(3%;' in v) > 0 THEN
    EXECUTE format('COMMENT ON COLUMN public.exos_checkout_sessions.exos_fee_cents IS %L',
      replace(v, '(3%;', '(the session''s fee_bps: 3% before mig 20261121133000, 2% after;'));
  END IF;
END $$;

-- ROLLBACK (manual): the same three patches the other way (149 -> 150,
-- SELECT 200 -> SELECT 300), exos_tg_marketplace_fee's priced-once block back
-- to the one CASE (the exos_fee_bps column can stay), the consent version back
-- to '2026-10-29' (with the SPA's), and the comment back to
-- 'free_tier_max_capacity (150)'. The cutoff alone can also go back without a
-- migration: exos_platform_settings free_tier_max_capacity = 150.
