-- ============================================================================
-- Online events, two follow-ups (KANBAN "Online events follow-ups")
-- ============================================================================
-- Touches:  P: _exos_wallet_payload (an online event's pass carries no
--              location, so Apple / Google Wallet don't geofence it; + format)
--           P: exos_calendar_public_feed (org and venue calendars leave out
--              events marked noindex, like the sitemap and the Google feed)
-- Pre-reqs: 20260929072000 (wallet passes), 20260929073000 (calendar feeds),
--           20261005090000 (format, noindex)
--
-- A single event's own calendar link (kind 'event') still answers for a
-- noindex event: whoever has the link was given it.
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

SELECT pg_temp.exos_patch_n('public._exos_wallet_payload(text)', $m$'format', e.format$m$,
  $o$'lat', g.lat, 'lng', g.lng)$o$,
  $n$'lat', CASE WHEN e.format = 'online' THEN NULL ELSE g.lat END,
      'lng', CASE WHEN e.format = 'online' THEN NULL ELSE g.lng END, 'format', e.format)$n$, 1);

SELECT pg_temp.exos_patch_n('public.exos_calendar_public_feed(text, text)', '/* unlisted: org */',
  'WHERE e.org_id = v_org.id AND e.starts_at >= v_since',
  'WHERE e.org_id = v_org.id AND e.starts_at >= v_since AND NOT e.noindex /* unlisted: org */', 1);
SELECT pg_temp.exos_patch_n('public.exos_calendar_public_feed(text, text)', '/* unlisted: venue */',
  'WHERE e.starts_at >= v_since',
  'WHERE e.starts_at >= v_since AND NOT e.noindex /* unlisted: venue */', 2);
