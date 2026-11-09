-- ============================================================================
-- Migration 20261111120000 — Exos: group pay v2 ("pay separately") switched
--                            off (KANBAN "Group buy / split pay")
--
-- Branch:   claude/exos-group-pay-off
-- Decision: operator 2026-11-09: v2 is paused for good. It ships dormant: off
--   at every entry point by default, no UI. Nothing is dropped: the tables,
--   functions and tests of migs 20261108120000 / 20261110110000 stay, and
--   the tests turn the switch on for themselves. v1 ("split with friends",
--   mig 20261031220000, /split/:sessionId: the host pays, friends pay back
--   by Venmo) is not touched.
--
-- Touches:  W: TABLE exos_platform_settings (+ key 'group_pay_enabled',
--              JSON false; no row reads as off too)
--           C: FUNCTION _exos_group_pay_on() (definer; service role only):
--              true only when the key is JSON true
--           C: FUNCTION exos_set_group_pay_enabled(boolean, text) (definer;
--              authenticated + service role; a platform admin, or the
--              operator through the service role / a direct DB session;
--              anyone else 42501). Needs a reason; each change is one
--              org-audit row (platform.group_pay, below)
--           W: FUNCTION exos_group_buy_start (4 args), exos_group_claim,
--              exos_group_checkout_ctx: refuse with SQLSTATE XGOFF
--              "Group pay isn't available" while off
--              (marker '/* exos: group pay off */', each matching once)
--           W: FUNCTION exos_group_seat_view: NULL while off (the seat page
--              shows "not available"; same marker)
--           R: exos_platform_settings, _exos_audit, exos_is_admin
--   Left as they are, on purpose: exos_group_buy_get / _mine (the host and
--   platform admins can still read a group that exists), exos_group_buy_cancel
--   (the host can still end one), exos_group_attach / _unclaim and
--   exos_fulfill_checkout (a checkout already past the claim when the switch
--   goes off finishes or gives its seat back as before), the hold triggers,
--   exos_group_pages_to_expire (exos-reconcile-checkouts' page expiry is
--   harmless and closes any open page).
-- Pre-reqs: 20261108120000, 20261110110000 (group pay), 20261014140000
--           (exos_platform_settings), 20261109100000 (_exos_audit).
--
-- Error code: XGOFF (new; not XG403, which already means "only the host can
--   cover the rest"). exos-checkout maps it to 403 group_pay_off, the same
--   answer its own env switch EXOS_GROUP_PAY gives (unset = off), which is
--   checked first, before the rate gate, any DB claim or any Stripe call.
--
-- The audit row: the setting is platform-wide, but exos_org_audit.org_id is
--   NOT NULL, so platform rows use the nil uuid
--   00000000-0000-0000-0000-000000000000 as their org (no org has it; the
--   table has no foreign key). Platform admins read them through RLS and
--   exos_org_audit_list(nil uuid, ...). action platform.group_pay, entity
--   platform_setting / group_pay_enabled, changes {group_pay_enabled:
--   [old, new]}, the reason; an admin's row is actor_role platform_admin,
--   source dashboard; the service role's is actor service, source system.
--
-- Prod (supabase/README.md rule 4): the four patched functions were created
-- or last rewritten by 2026-11 migrations (20261108120000, 20261110110000;
-- the seat view's hygiene patch 20261109110000 is after the anchor), so
-- prod's bodies are the chain's. Apply this one right after
-- 20261110110000 / with the wave 7-10 rollout, so group pay is never on in
-- prod.
--
-- Additive, re-run safe (ON CONFLICT DO NOTHING keeps the operator's value,
-- CREATE OR REPLACE, marker-checked patches). No cron, no sequence, no table.
-- Not applied; prod apply needs operator OK.
-- ROLLBACK (turning v2 back on is NOT a rollback: call
--   exos_set_group_pay_enabled(true, '<reason>') and set EXOS_GROUP_PAY=on
--   and VITE_EXOS_GROUP_PAY=on): re-run 20261110110000's start / ctx and its
--   claim / seat-view patches on 20261108120000's bodies; drop the two new
--   functions; delete the setting row.
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
-- 1. The switch: off by default.
-- ---------------------------------------------------------------------------
INSERT INTO public.exos_platform_settings (key, value) VALUES ('group_pay_enabled', 'false')
ON CONFLICT (key) DO NOTHING;

-- On only when the key is JSON true: a missing row, false, a string or a
-- number all read as off.
CREATE OR REPLACE FUNCTION public._exos_group_pay_on()
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT coalesce((SELECT value = 'true'::jsonb FROM public.exos_platform_settings WHERE key = 'group_pay_enabled'), false)
$$;
REVOKE ALL ON FUNCTION public._exos_group_pay_on() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_group_pay_on() TO service_role;

-- Turning it on or off: a platform admin (app_metadata.admin), or the
-- operator through the service role or a direct database session (no API
-- role set). A reason of 5 to 300 characters is required; each change writes
-- one audit row. Setting the value it already has changes nothing and logs
-- nothing. Returns { group_pay_enabled, changed }.
CREATE OR REPLACE FUNCTION public.exos_set_group_pay_enabled(p_enabled boolean, p_reason text)
RETURNS jsonb
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_role   text := coalesce(nullif(current_setting('role', true), ''), 'none');
  v_reason text := nullif(btrim(regexp_replace(coalesce(p_reason, ''), '\s+', ' ', 'g')), '');
  v_old    boolean;
BEGIN
  IF v_role NOT IN ('service_role', 'none') AND NOT public.exos_is_admin() THEN
    RAISE EXCEPTION 'exos_set_group_pay_enabled: platform admins only' USING ERRCODE = '42501';
  END IF;
  IF p_enabled IS NULL THEN
    RAISE EXCEPTION 'exos_set_group_pay_enabled: on or off?' USING ERRCODE = '22023';
  END IF;
  IF v_reason IS NULL OR char_length(v_reason) < 5 OR char_length(v_reason) > 300 THEN
    RAISE EXCEPTION 'exos_set_group_pay_enabled: give a reason (5 to 300 characters)' USING ERRCODE = '22023';
  END IF;
  -- One change at a time: the row (created off when missing) is locked.
  INSERT INTO public.exos_platform_settings (key, value) VALUES ('group_pay_enabled', 'false')
  ON CONFLICT (key) DO NOTHING;
  SELECT value = 'true'::jsonb INTO v_old FROM public.exos_platform_settings WHERE key = 'group_pay_enabled' FOR UPDATE;
  IF v_old IS NOT DISTINCT FROM p_enabled THEN
    RETURN jsonb_build_object('group_pay_enabled', p_enabled, 'changed', false);
  END IF;
  UPDATE public.exos_platform_settings SET value = to_jsonb(p_enabled), updated_at = now() WHERE key = 'group_pay_enabled';
  /* exos: audit platform.group_pay */
  PERFORM public._exos_audit('00000000-0000-0000-0000-000000000000'::uuid, 'platform.group_pay', 'platform_setting',
                             'group_pay_enabled', NULL, jsonb_build_object('group_pay_enabled', jsonb_build_array(v_old, p_enabled)),
                             NULL, NULL, v_reason, NULL, NULL, NULL);
  RETURN jsonb_build_object('group_pay_enabled', p_enabled, 'changed', true);
END $$;
REVOKE ALL ON FUNCTION public.exos_set_group_pay_enabled(boolean, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_set_group_pay_enabled(boolean, text) TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 2. Every entry point refuses while it's off.
-- ---------------------------------------------------------------------------
-- Start (the current, 4-argument version, mig 20261110110000): no holds.
SELECT pg_temp.exos_patch_n('public.exos_group_buy_start(uuid,uuid,integer,text)',
  '/* exos: group pay off */',
  $o$  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'exos_group_buy_start: sign in to start a group'$o$,
  $n$  /* exos: group pay off */ -- mig 20261111120000: paused by the operator 2026-11-09
  IF NOT public._exos_group_pay_on() THEN
    RAISE EXCEPTION 'Group pay isn''t available' USING ERRCODE = 'XGOFF';
  END IF;
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'exos_group_buy_start: sign in to start a group'$n$, 1);

-- The claim (exos-checkout): no checkout takes a seat.
SELECT pg_temp.exos_patch_n('public.exos_group_claim(text,uuid,uuid,text,uuid,uuid,integer)',
  '/* exos: group pay off */',
  $o$  IF (p_token IS NULL) = (p_group_id IS NULL) THEN$o$,
  $n$  /* exos: group pay off */ -- mig 20261111120000
  IF NOT public._exos_group_pay_on() THEN
    RAISE EXCEPTION 'Group pay isn''t available' USING ERRCODE = 'XGOFF';
  END IF;
  IF (p_token IS NULL) = (p_group_id IS NULL) THEN$n$, 1);

-- exos-checkout's context, read before its rate gate: the SQL half of the
-- edge's 403.
SELECT pg_temp.exos_patch_n('public.exos_group_checkout_ctx(text,uuid,uuid)',
  '/* exos: group pay off */',
  $o$  IF (p_token IS NULL) = (p_group_id IS NULL) THEN$o$,
  $n$  /* exos: group pay off */ -- mig 20261111120000
  IF NOT public._exos_group_pay_on() THEN
    RAISE EXCEPTION 'Group pay isn''t available' USING ERRCODE = 'XGOFF';
  END IF;
  IF (p_token IS NULL) = (p_group_id IS NULL) THEN$n$, 1);

-- The friend's seat page (anon): nothing, as for an unknown link.
SELECT pg_temp.exos_patch_n('public.exos_group_seat_view(text)',
  '/* exos: group pay off */',
  $o$  IF p_token IS NULL OR p_token !~ '^[0-9a-f]{32}$' THEN
    RETURN NULL;$o$,
  $n$  /* exos: group pay off */ -- mig 20261111120000
  IF NOT public._exos_group_pay_on() THEN
    RETURN NULL;
  END IF;
  IF p_token IS NULL OR p_token !~ '^[0-9a-f]{32}$' THEN
    RETURN NULL;$n$, 1);
