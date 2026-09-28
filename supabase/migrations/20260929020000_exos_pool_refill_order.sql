-- ============================================================================
-- Migration 20260929020000 — Exos (Bridge / D4): pool refill order
--
-- Lane:     d4 (exos / bridge ticketing infra)
-- Touches:  W: FUNCTION exos_refill_channel_pools (patched in place)
-- Pre-reqs: 20260928040000 (scarcity mode)
--
-- exos_refill_channel_pools shrinks pools before growing them, but two pools
-- that shrink in the same run (same last sale, same updated_at: the same
-- transaction) were taken in no particular order, and the order matters near
-- sellout: shrinking the busy one first frees seats that lift the tier out of
-- scarcity, so the stagnant one keeps its seats. That made the scarcity
-- harness (C2) fail about one run in four. Now shrinks go longest-idle first
-- (the stagnant marketplace gives its seats back before a selling one does),
-- then by id, so a run is deterministic.
--
-- Re-run safe (the patch asserts one match and is skipped once applied).
-- D4 authors; applying to prod is operator-gated.
-- ============================================================================

CREATE OR REPLACE FUNCTION pg_temp.exos_patch(p_sig text, p_marker text, p_old text, p_new text)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE p_fn regprocedure := to_regprocedure(p_sig); v_def text; v_hits int;
BEGIN
  IF p_fn IS NULL THEN
    RAISE NOTICE '%: not present, skipped', p_sig;
    RETURN;
  END IF;
  v_def := pg_get_functiondef(p_fn);
  IF position(p_marker in v_def) > 0 THEN
    RAISE NOTICE '%: already patched (%)', p_fn, p_marker;
    RETURN;
  END IF;
  v_hits := (length(v_def) - length(replace(v_def, p_old, ''))) / length(p_old);
  IF v_hits <> 1 THEN
    RAISE EXCEPTION '%: expected one match for patch "%", found %', p_fn, p_marker, v_hits;
  END IF;
  EXECUTE replace(v_def, p_old, p_new);
END $$;

SELECT pg_temp.exos_patch('public.exos_refill_channel_pools()',
  'x.idle_since',
  'SELECT d.id, d.last_sold_at, d.updated_at, coalesce(d.requested_qty, 0) AS held, d.list_qty,',
  'SELECT d.id, d.last_sold_at, d.updated_at, d.idle_since, coalesce(d.requested_qty, 0) AS held, d.list_qty,');
SELECT pg_temp.exos_patch('public.exos_refill_channel_pools()',
  'CASE WHEN x.held > x.target THEN x.idle_since END',
  'ORDER BY (x.held > x.target) DESC, x.last_sold_at DESC NULLS LAST, x.updated_at',
  'ORDER BY (x.held > x.target) DESC, CASE WHEN x.held > x.target THEN x.idle_since END ASC NULLS LAST,
              x.last_sold_at DESC NULLS LAST, x.updated_at, x.id');
