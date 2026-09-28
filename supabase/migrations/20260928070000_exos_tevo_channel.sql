-- ============================================================================
-- Migration 20260928070000 — Exos (Bridge / D4): Ticket Evolution order names
--
-- Lane:     d4 (exos / bridge ticketing infra)
-- Touches:  W: FUNCTION exos_set_channel_allocation, exos_fulfil_marketplace_order
--                (patched in place: the 'evo' label)
-- Pre-reqs: 20260928030000 (Vivid Seats)
--
-- Ticket Evolution (channel 'evo'; _shared/marketplace/tevo,
-- docs/marketplace/tevo/README.md) takes orders through the same record +
-- fulfil path as the other marketplaces. 'evo' has been in every channel
-- CHECK and IN list since the first distribution migrations, so this only
-- names it: the buyer mail and the allocation errors said "Evo".
-- Nothing is sent to Ticket Evolution (dry-run; Hard Rule #2).
--
-- Re-run safe (each patch asserts one match and is skipped once applied).
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

SELECT pg_temp.exos_patch('public.exos_set_channel_allocation(uuid, text, uuid, integer)',
  'WHEN ''evo'' THEN ''Ticket Evolution''',
  'WHEN ''vivid'' THEN ''Vivid Seats'' ELSE initcap(p_channel) END',
  'WHEN ''vivid'' THEN ''Vivid Seats'' WHEN ''evo'' THEN ''Ticket Evolution'' ELSE initcap(p_channel) END');

SELECT pg_temp.exos_patch('public.exos_fulfil_marketplace_order(uuid, text)',
  'WHEN ''evo'' THEN ''Ticket Evolution''',
  'WHEN ''vivid'' THEN ''Vivid Seats'' ELSE initcap(o.channel) END',
  'WHEN ''vivid'' THEN ''Vivid Seats'' WHEN ''evo'' THEN ''Ticket Evolution'' ELSE initcap(o.channel) END');
