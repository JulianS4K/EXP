-- ============================================================================
-- Door roster delta: wallet pass changes reach the door between full pulls
-- ============================================================================
-- Touches:  P: exos_event_door_roster (the since form also returns tickets
--              whose wallet pass was issued, reissued or voided since)
-- Pre-reqs: 20261019100000 (door day keys), 20260929072000 (wallet passes)
--
-- The door keys carry the live pass's Apple hash / Google key and epoch. An
-- issue or reissue only touches exos_wallet_passes, so the delta never sent
-- the new keys: offline, the new pass was refused (no key) until the next full
-- pull, and the old epoch's keys stayed on the device.
-- ============================================================================

CREATE OR REPLACE FUNCTION pg_temp.exos_patch_n(p_sig text, p_marker text, p_old text, p_new text, p_hits int)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE p_fn regprocedure := to_regprocedure(p_sig); v_def text; v_hits int;
BEGIN
  IF p_fn IS NULL THEN
    RAISE EXCEPTION '%: not present', p_sig;
  END IF;
  -- Pasted through a browser the patch text can carry CRLF line ends; compare without CRs.
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

SELECT pg_temp.exos_patch_n('public.exos_event_door_roster(uuid, timestamp with time zone)', '/* wallet delta */',
  '           OR p.updated_at >= p_since
',
  '           OR p.updated_at >= p_since
           OR EXISTS (SELECT 1 FROM public.exos_wallet_passes w /* wallet delta */
                       WHERE w.ticket_id = t.id AND w.updated_at >= p_since)
', 1);
