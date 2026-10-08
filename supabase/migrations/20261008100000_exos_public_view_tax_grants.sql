-- ============================================================================
-- Public tier / add-on views: give the tax helpers back to anon + authenticated
-- ============================================================================
-- Touches:  W: GRANT EXECUTE on exos_tier_exclusive_tax_percent(uuid),
--              exos_addon_exclusive_tax_percent(uuid) to anon, authenticated
-- Pre-reqs: 20260924211840 (the helpers + the views' exclusive_tax_percent),
--           20260929080000 (the revoke this undoes for these two)
--
-- 20260929080000 revoked EXECUTE on these helpers from anon / authenticated on
-- the belief that the SECURITY DEFINER (owner-run) views exos_public_tiers and
-- exos_public_addons call them as their owner. They don't: Postgres checks
-- EXECUTE on a function in a view against the user running the query, even
-- with security_invoker off (only table access uses the owner). Every read of
-- the views' exclusive_tax_percent column failed with 42501 for visitors and
-- signed-in buyers, the event page got no tiers, and Buy said "No ticket tier
-- available for this event yet". (The harness check counted rows, which never
-- evaluates the column, so it passed.)
--
-- Granting them back is what prod ran with before 2026-09-29. The cost is the
-- one 20260929080000 named: a direct /rpc call answers the exclusive tax
-- percent for any tier / add-on id, drafts included. That is a tax rate, not
-- buyer or sales data.
--
-- Applied to prod by the operator on 2026-10-08 (the two GRANTs below, run in
-- the SQL editor); this file records it. Re-run safe.
-- ============================================================================

DO $g$
DECLARE f text;
BEGIN
  FOREACH f IN ARRAY ARRAY[
    'public.exos_tier_exclusive_tax_percent(uuid)',
    'public.exos_addon_exclusive_tax_percent(uuid)'
  ] LOOP
    IF to_regprocedure(f) IS NULL THEN
      RAISE NOTICE '%: not present, skipped', f;
      CONTINUE;
    END IF;
    EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO anon, authenticated', f);
  END LOOP;
END $g$;
