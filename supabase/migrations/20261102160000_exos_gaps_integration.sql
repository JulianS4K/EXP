-- ============================================================================
-- Migration 20261102160000 — Exos: gaps integration (2026-11-02)
-- ============================================================================
-- The gaps branches (memberships 20261102100000, giving 110000, finance
-- 120000, templates 130000, orders 140000) were written in parallel. None of
-- them redefines or patches a function another one also changes, so nothing
-- here undoes a sibling. This migration holds one security fix found while
-- merging them.
--
-- 1. exos_delete_my_account: email-keyed effects only for a confirmed email.
--    The function (mig 20260926010000, live in prod) read the account's
--    email without checking auth.users.email_confirmed_at. Anyone could sign
--    up with another person's address, never confirm it, delete the account,
--    and so rewrite that person's transfers (receiver_email), clear their
--    promoter email, delete their unclaimed org invites, their pending mail
--    and their waitlist rows, and tombstone their sent mail. Now the email is
--    read only when it is confirmed; with no confirmed email every
--    email-keyed statement matches nothing. Rows keyed by the caller's uid
--    always apply, as before.
--    The orders branch's patch (mig 20261102140000, marker
--    'exos_order_details') checks confirmation on its own and anchors on a
--    different line; it is left as it is, whichever of the two runs first.
--
-- Touches:  W: FUNCTION exos_delete_my_account (patched in place, section 1)
-- Pre-reqs: every exos migration before this one.
-- Re-run safe: a marker-checked in-place patch (pg_temp.exos_patch_n); grants
-- are unchanged (CREATE OR REPLACE through pg_get_functiondef keeps them).
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

-- ---------------------------------------------------------------------------
-- 1. Account deletion: the email counts only once it is confirmed.
-- ---------------------------------------------------------------------------
SELECT pg_temp.exos_patch_n('public.exos_delete_my_account()',
  '/* exos: confirmed email only */',
  $o$  SELECT lower(btrim(u.email)) INTO v_email FROM auth.users u WHERE u.id = v_uid;$o$,
  $n$  /* exos: confirmed email only */ -- mig 20261102160000. An unconfirmed address may be
  -- someone else's: then v_email stays NULL and no email-keyed row (transfers,
  -- promoters, invites, mail, waitlist) is touched. uid-keyed rows always are.
  SELECT lower(btrim(u.email)) INTO v_email FROM auth.users u
   WHERE u.id = v_uid AND u.email_confirmed_at IS NOT NULL;$n$, 1);
