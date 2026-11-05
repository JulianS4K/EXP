-- ============================================================================
-- Migration 20261105150000 — Exos: wave 3 integration (2026-11-05)
-- ============================================================================
-- Wave 3 merged #88 sim decisions (20261105100000), #85 fan API
-- (20261105110000), #87 na-build (20261105120000) and #89 promoter events
-- (20261105130000). They were built side by side on the same base, so each
-- one's in-place patches were checked against the others after a full
-- replay (tests/exos/test_wave3_integration.sql W1: every marker is still
-- in the live body). One rule crossed branches without a patch to carry it:
--
-- 1. A closed ticket type is sold out in public discovery. #88 made
--    capacity 0 mean CLOSED (nothing sells) instead of "uncapped". #85's
--    public discovery (/v1/public/discovery/events, exos_api_public) was
--    written to the old meaning and marks a type sold out only when it has
--    a positive capacity that is used up, so a closed type showed as on
--    sale and counted toward the event's "from" price. Now sold_out is
--    capacity <= 0 OR sold >= capacity, as exos_tier_available answers 0.
--
-- Touches:  W: FUNCTION _exos_api_public_tiers_json (patched in place,
--              marker-checked; same signature, same grants)
-- Callers:  exos_api_public / _exos_api_public (exos-api /v1/public/…).
-- Pre-reqs: every exos migration before this one.
-- Re-run safe: marker-checked patch (pg_temp.exos_patch_n). D4 authors; not
-- applied.
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
-- 1. A closed ticket type (capacity 0, mig 20261105100000) is sold out in
--    public discovery (mig 20261105110000).
-- ===========================================================================
SELECT pg_temp.exos_patch_n('public._exos_api_public_tiers_json(uuid)',
  '/* exos: closed is sold out */',
  $o$'sold_out', t.capacity IS NOT NULL AND t.capacity > 0 AND coalesce(t.sold, 0) >= t.capacity)$o$,
  $n$'sold_out', coalesce(t.capacity, 0) <= 0 /* exos: closed is sold out */ OR coalesce(t.sold, 0) >= t.capacity)$n$, 1);
