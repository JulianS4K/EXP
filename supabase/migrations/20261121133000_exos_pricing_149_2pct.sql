-- ============================================================================
-- Migration 20261121133000 — Exos pricing, operator 2026-11-21: the free tier
-- is UNDER 150 (149 or less), 150 or more is paid; the Exos fee is 2%
-- ============================================================================
-- Touches:  P: exos_free_tier_max_capacity()   (default 150 -> 149)
--              _exos_discovery_free_tier_max() (default 150 -> 149)
--              exos_platform_fee_bps()         (SELECT 300 -> SELECT 200)
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
-- (env) must stay unset or 200. Rows already written keep the fee they were
-- charged (checkout sessions record fee_bps; marketplace exos_fee is set at
-- insert). Every marketplace sale is Managed (Exos's channel accounts) and
-- takes the same 2%. A BYO sale (the organizer's own marketplace account,
-- not built) would take 0: it would branch in exos_tg_marketplace_fee before
-- exos_event_fee_bps.
--
-- Applier's prod anchor check (supabase/README.md rule 4), read-only:
--   select pg_get_functiondef('public.exos_free_tier_max_capacity()'::regprocedure);
--     must contain once:  _exos_setting_int('free_tier_max_capacity', 150, -1, 999999)
--   select pg_get_functiondef('public._exos_discovery_free_tier_max()'::regprocedure);
--     must contain once:  WHERE key = 'free_tier_max_capacity'), 150)
--   select pg_get_functiondef('public.exos_platform_fee_bps()'::regprocedure);
--     must contain once:  SELECT 300
-- All three matched prod on 2026-11-21 (read-only). Each patch is a counted text
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
-- SELECT 200 -> SELECT 300), and the comment back to
-- 'free_tier_max_capacity (150)'. The cutoff alone can also go back without a
-- migration: exos_platform_settings free_tier_max_capacity = 150.
