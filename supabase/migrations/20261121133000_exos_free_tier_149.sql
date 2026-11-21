-- ============================================================================
-- Migration 20261121133000 — Exos: the free tier is UNDER 150 (149 or less);
-- 150 or more is paid
-- ============================================================================
-- Touches:  P: exos_free_tier_max_capacity()   (default 150 -> 149)
--              _exos_discovery_free_tier_max() (default 150 -> 149)
--           C: COMMENT ON TABLE exos_platform_settings (the default it names)
-- Pre-reqs: 20261029090000, 20261029130000
--
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
-- Applier's prod anchor check (supabase/README.md rule 4), read-only:
--   select pg_get_functiondef('public.exos_free_tier_max_capacity()'::regprocedure);
--     must contain once:  _exos_setting_int('free_tier_max_capacity', 150, -1, 999999)
--   select pg_get_functiondef('public._exos_discovery_free_tier_max()'::regprocedure);
--     must contain once:  WHERE key = 'free_tier_max_capacity'), 150)
-- Both matched prod on 2026-11-21 (read-only). Each patch is a counted text
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

-- The settings table's comment names the default.
DO $$
DECLARE v text := obj_description('public.exos_platform_settings'::regclass, 'pg_class');
BEGIN
  IF v IS NOT NULL AND position('free_tier_max_capacity (150)' in v) > 0 THEN
    EXECUTE format('COMMENT ON TABLE public.exos_platform_settings IS %L',
      replace(v, 'free_tier_max_capacity (150)', 'free_tier_max_capacity (149: under 150 is free, mig 20261121133000)'));
  END IF;
END $$;

-- ROLLBACK (manual): the same two patches the other way (149 -> 150), and the
-- comment back to 'free_tier_max_capacity (150)'. Or, without a migration, the
-- operator can set exos_platform_settings free_tier_max_capacity = 150.
