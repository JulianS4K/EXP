-- ============================================================================
-- Migration 20260927020000 — Exos (Bridge / D4): SeatGeek's name in the
--                            marketplace ticket mail
--
-- Lane:     d4 (exos / bridge ticketing infra)
-- Touches:  W: FUNCTION exos_fulfil_marketplace_order (patched in place)
-- Pre-reqs: 20260926193000 (fulfil_marketplace_order), 20260927010000
--
-- The mail a marketplace buyer gets names the marketplace with
-- initcap(channel), which spells SeatGeek "Seatgeek". SeatGeek sales now
-- come in (exos-marketplace-sales polls the Seller Direct API), so it gets
-- its own label, like StubHub.
--
-- The patch asserts one match and is skipped once applied (re-run safe).
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

SELECT pg_temp.exos_patch('public.exos_fulfil_marketplace_order(uuid, text)',
  'WHEN ''seatgeek'' THEN ''SeatGeek''',
  'CASE o.channel WHEN ''stubhub'' THEN ''StubHub'' ELSE initcap(o.channel) END',
  'CASE o.channel WHEN ''stubhub'' THEN ''StubHub'' WHEN ''seatgeek'' THEN ''SeatGeek'' ELSE initcap(o.channel) END');
