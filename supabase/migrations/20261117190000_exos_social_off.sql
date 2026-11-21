-- ============================================================================
-- Migration 20261117190000 — Exos: social / "friends" features switched off
--                            (operator 2026-11-17: focus on ticket selling,
--                            promotion and distribution)
--
-- Branch:   claude/exos-focus-core
-- Decision: operator 2026-11-17: Exos narrows to its core. The social
--   features are hidden, code kept: nothing new can be started, nothing is
--   dropped, and what already exists keeps working so no buyer is stranded.
--   Modelled on the group pay v2 switch (mig 20261111120000), which stays as
--   it is. One platform setting covers the three features, because they
--   share a seam (exos_social_groups) and are paused together:
--     * split with friends (group buy v1, mig 20261031220000);
--     * matched seats (mig 20261031210000);
--     * group chats and the masked SMS relay (mig 20261031230000).
--
-- Touches:  W: TABLE exos_platform_settings (+ key 'social_features_enabled',
--              JSON false; no row reads as off too)
--           C: FUNCTION _exos_social_on() (definer; service role only)
--           C: FUNCTION exos_set_social_features_enabled(boolean, text)
--              (definer; authenticated + service role; a platform admin, or
--              the operator through the service role / a direct DB session;
--              anyone else 42501). Needs a reason; each change is one
--              org-audit row (platform.social_features, nil org)
--           W: FUNCTION (marker '/* exos: social off */', each matching once)
--              exos_split_save            XSOFF before anything: no new split,
--                                         no friends added to one
--              exos_match_set_config      XSOFF when the ticket type has no
--                                         matched-seats config yet (an
--                                         existing one can still be edited)
--              exos_group_create          XSOFF before anything
--              exos_group_join            XSOFF for a new member (a member
--                                         asking again still gets "joined")
--              exos_group_add_member      XSOFF after the staff check
--              exos_group_sms_opt_in      XSOFF before anything: no new relay
--              _exos_group_fanout         queues no relayed text
--              exos_sms_relay_claim       skips queued relay / confirm texts
--                                         (keyword answers still go)
--              exos_sms_relay_inbound     a member's text isn't relayed; one
--                                         "texts are paused" answer a day
--                                         (STOP / START / HELP unchanged)
--           R: exos_platform_settings, _exos_audit, exos_is_admin,
--              _exos_relay_reply
--   Left as they are, on purpose (existing records keep working):
--     split:   exos_split_get, exos_split_mark_paid (a paid pay-back still
--              settles: in 'on_paid' mode the tick still sends the ticket),
--              exos_split_nudged, exos_bulk_create_transfers and every
--              transfer / claim function (an outstanding claim link can still
--              be claimed; plain transfers are core).
--     matched: everything for a ticket type that is already matched: the
--              quiz, exos_match_due / _inputs / _apply (the cron still groups
--              holders at the cutoff), reveal (mail, the org's own opted-in
--              texts), staff review, leftovers (refunded through exos-refund),
--              picks, reports, blocks, the retention sweep.
--     chat:    exos_group_state / _post / _leave / _mute / _block / _report,
--              moderation, contact shares, exos_group_sms_opt_out, the
--              retention sweep. The SPA hides the chat while paused.
--
-- The relay: STOPS while off (the brief's other option was "until the event
--   ends"). Why: it never went live (EXOS_SMS_RELAY is unset in prod, so
--   every send is a dry run, and the pool numbers have no US A2P 10DLC
--   registration), so nobody depends on it; the in-app chat and the staff
--   moderation screens are hidden while paused, so nobody could read or
--   moderate what it relays; and every relayed text costs money. STOP /
--   STOPALL / START / HELP keep their answers (carrier compliance doesn't
--   wait for a switch). Turning the switch back on resumes relaying for the
--   consents already given; nothing is deleted.
--
-- Error code: XSOFF (new), "<feature> isn't available". The SPA shows its own
--   "not available" page; no edge function starts any of these (exos-match's
--   /run is refused by its env switch EXOS_SOCIAL, _shared/socialGate.ts).
--
-- The audit row: as group pay's, under the nil uuid org
--   00000000-0000-0000-0000-000000000000; action platform.social_features,
--   entity platform_setting / social_features_enabled, changes
--   {social_features_enabled: [old, new]}, the reason.
--
-- Prod (supabase/README.md rule 4): all nine patched functions were created
-- by 2026-10-31 migrations (20261031210000, 20261031220000, 20261031230000),
-- applied in the 2026-11-05 rollout and not rewritten since, so prod's bodies
-- are the chain's. Each patch must match exactly once or the migration stops.
--
-- Additive, re-run safe (ON CONFLICT DO NOTHING keeps the operator's value,
-- CREATE OR REPLACE, marker-checked patches). No cron, no sequence, no table.
-- Not applied; prod apply needs operator OK.
-- ROLLBACK (turning the features back on is NOT a rollback: call
--   exos_set_social_features_enabled(true, '<reason>') and build the SPA with
--   VITE_EXOS_SOCIAL=on; set EXOS_SOCIAL=on on exos-match): re-run the nine
--   functions from their 2026-10-31 migrations; drop the two new functions;
--   delete the setting row.
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
INSERT INTO public.exos_platform_settings (key, value) VALUES ('social_features_enabled', 'false')
ON CONFLICT (key) DO NOTHING;

-- On only when the key is JSON true: a missing row, false, a string or a
-- number all read as off.
CREATE OR REPLACE FUNCTION public._exos_social_on()
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT coalesce((SELECT value = 'true'::jsonb FROM public.exos_platform_settings WHERE key = 'social_features_enabled'), false)
$$;
REVOKE ALL ON FUNCTION public._exos_social_on() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_social_on() TO service_role;

-- Turning it on or off: a platform admin (app_metadata.admin), or the
-- operator through the service role or a direct database session (no API
-- role set). A reason of 5 to 300 characters is required; each change writes
-- one audit row. Setting the value it already has changes nothing and logs
-- nothing. Returns { social_features_enabled, changed }.
CREATE OR REPLACE FUNCTION public.exos_set_social_features_enabled(p_enabled boolean, p_reason text)
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
    RAISE EXCEPTION 'exos_set_social_features_enabled: platform admins only' USING ERRCODE = '42501';
  END IF;
  IF p_enabled IS NULL THEN
    RAISE EXCEPTION 'exos_set_social_features_enabled: on or off?' USING ERRCODE = '22023';
  END IF;
  IF v_reason IS NULL OR char_length(v_reason) < 5 OR char_length(v_reason) > 300 THEN
    RAISE EXCEPTION 'exos_set_social_features_enabled: give a reason (5 to 300 characters)' USING ERRCODE = '22023';
  END IF;
  -- One change at a time: the row (created off when missing) is locked.
  INSERT INTO public.exos_platform_settings (key, value) VALUES ('social_features_enabled', 'false')
  ON CONFLICT (key) DO NOTHING;
  SELECT value = 'true'::jsonb INTO v_old FROM public.exos_platform_settings WHERE key = 'social_features_enabled' FOR UPDATE;
  IF v_old IS NOT DISTINCT FROM p_enabled THEN
    RETURN jsonb_build_object('social_features_enabled', p_enabled, 'changed', false);
  END IF;
  UPDATE public.exos_platform_settings SET value = to_jsonb(p_enabled), updated_at = now() WHERE key = 'social_features_enabled';
  /* exos: audit platform.social_features */
  PERFORM public._exos_audit('00000000-0000-0000-0000-000000000000'::uuid, 'platform.social_features', 'platform_setting',
                             'social_features_enabled', NULL, jsonb_build_object('social_features_enabled', jsonb_build_array(v_old, p_enabled)),
                             NULL, NULL, v_reason, NULL, NULL, NULL);
  RETURN jsonb_build_object('social_features_enabled', p_enabled, 'changed', true);
END $$;
REVOKE ALL ON FUNCTION public.exos_set_social_features_enabled(boolean, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_set_social_features_enabled(boolean, text) TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 2. Split with friends: no new split, no friends added to one.
-- ---------------------------------------------------------------------------
-- First thing, before the order lock or any transfer.
SELECT pg_temp.exos_patch_n('public.exos_split_save(text,jsonb,text,text,text,text)',
  '/* exos: social off */',
  $o$  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'exos_split_save: not authenticated'$o$,
  $n$  /* exos: social off */ -- mig 20261117190000: paused by the operator 2026-11-17
  IF NOT public._exos_social_on() THEN
    RAISE EXCEPTION 'Split with friends isn''t available' USING ERRCODE = 'XSOFF';
  END IF;
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'exos_split_save: not authenticated'$n$, 1);

-- ---------------------------------------------------------------------------
-- 3. Matched seats: no ticket type becomes matched.
-- ---------------------------------------------------------------------------
-- After the staff check and the config lookup, before any write: a ticket
-- type with a config already (sold as matched before the pause) can still be
-- edited within its own rules.
SELECT pg_temp.exos_patch_n('public.exos_match_set_config(uuid,jsonb)',
  '/* exos: social off */',
  $o$  SELECT * INTO v_old FROM public.exos_match_configs WHERE tier_id = p_tier_id FOR UPDATE;
$o$,
  $n$  SELECT * INTO v_old FROM public.exos_match_configs WHERE tier_id = p_tier_id FOR UPDATE;
  /* exos: social off */ -- mig 20261117190000
  IF v_old.tier_id IS NULL AND NOT public._exos_social_on() THEN
    RAISE EXCEPTION 'Matched seats aren''t available' USING ERRCODE = 'XSOFF';
  END IF;
$n$, 1);

-- ---------------------------------------------------------------------------
-- 4. Group chats: no new group, no new member, no new relay.
-- ---------------------------------------------------------------------------
SELECT pg_temp.exos_patch_n('public.exos_group_create(uuid,text,text,uuid,text,integer,integer)',
  '/* exos: social off */',
  $o$  IF NOT public._exos_group_staff(p_org_id) THEN
    RAISE EXCEPTION 'exos_group_create: owner or manager only'$o$,
  $n$  /* exos: social off */ -- mig 20261117190000
  IF NOT public._exos_social_on() THEN
    RAISE EXCEPTION 'Group chat isn''t available' USING ERRCODE = 'XSOFF';
  END IF;
  IF NOT public._exos_group_staff(p_org_id) THEN
    RAISE EXCEPTION 'exos_group_create: owner or manager only'$n$, 1);

-- A member asking again still gets { joined: true } (that check comes first).
SELECT pg_temp.exos_patch_n('public.exos_group_join(uuid)',
  '/* exos: social off */',
  $o$  IF g.join_policy = 'invite' THEN$o$,
  $n$  /* exos: social off */ -- mig 20261117190000
  IF NOT public._exos_social_on() THEN
    RAISE EXCEPTION 'Group chat isn''t available' USING ERRCODE = 'XSOFF';
  END IF;
  IF g.join_policy = 'invite' THEN$n$, 1);

SELECT pg_temp.exos_patch_n('public.exos_group_add_member(uuid,uuid,text)',
  '/* exos: social off */',
  $o$  IF p_role NOT IN ('member', 'host') THEN$o$,
  $n$  /* exos: social off */ -- mig 20261117190000
  IF NOT public._exos_social_on() THEN
    RAISE EXCEPTION 'Group chat isn''t available' USING ERRCODE = 'XSOFF';
  END IF;
  IF p_role NOT IN ('member', 'host') THEN$n$, 1);

-- Opting in to a group's texts starts a relay: refused before the consent,
-- the pool number or the confirmation text.
SELECT pg_temp.exos_patch_n('public.exos_group_sms_opt_in(uuid,text,text)',
  '/* exos: social off */',
  $o$  IF v_uid IS NULL OR NOT public.exos_is_group_member(p_group_id) THEN
    RAISE EXCEPTION 'exos_group_sms_opt_in: not a member'$o$,
  $n$  /* exos: social off */ -- mig 20261117190000
  IF NOT public._exos_social_on() THEN
    RAISE EXCEPTION 'Group texts aren''t available' USING ERRCODE = 'XSOFF';
  END IF;
  IF v_uid IS NULL OR NOT public.exos_is_group_member(p_group_id) THEN
    RAISE EXCEPTION 'exos_group_sms_opt_in: not a member'$n$, 1);

-- The relay stops: nothing is queued for other members while off.
SELECT pg_temp.exos_patch_n('public._exos_group_fanout(uuid)',
  '/* exos: social off */',
  $o$  IF NOT g.relay_enabled OR g.daily_sms_cap = 0 THEN
    RETURN jsonb_build_object('queued', 0, 'capped', 0);
  END IF;
$o$,
  $n$  IF NOT g.relay_enabled OR g.daily_sms_cap = 0 THEN
    RETURN jsonb_build_object('queued', 0, 'capped', 0);
  END IF;
  /* exos: social off */ -- mig 20261117190000: the relay stops while paused
  IF NOT public._exos_social_on() THEN
    RETURN jsonb_build_object('queued', 0, 'capped', 0, 'paused', true);
  END IF;
$n$, 1);

-- What was queued before the switch went off isn't sent either (keyword
-- answers still are).
SELECT pg_temp.exos_patch_n('public.exos_sms_relay_claim(integer)',
  '/* exos: social off */',
  $o$BEGIN
  UPDATE public.exos_sms_relay_outbox o SET status = 'skipped', error = 'no longer opted in'$o$,
  $n$BEGIN
  /* exos: social off */ -- mig 20261117190000
  IF NOT public._exos_social_on() THEN
    UPDATE public.exos_sms_relay_outbox o SET status = 'skipped', error = 'group texts paused'
     WHERE o.kind <> 'reply'
       AND (o.status = 'queued' OR (o.status = 'sending' AND o.lease_until < now()));
  END IF;
  UPDATE public.exos_sms_relay_outbox o SET status = 'skipped', error = 'no longer opted in'$n$, 1);

-- A member's text to a pool number: not relayed or stored while off; one
-- answer a day says so. After the stop checks, so a stopped phone gets nothing.
SELECT pg_temp.exos_patch_n('public.exos_sms_relay_inbound(text,text,text,text,text,text)',
  '/* exos: social off */',
  $o$  IF p_provider_ref IS NOT NULL AND EXISTS (SELECT 1 FROM public.exos_group_messages WHERE provider_ref = left(p_provider_ref, 80)) THEN$o$,
  $n$  /* exos: social off */ -- mig 20261117190000
  IF NOT public._exos_social_on() THEN
    IF NOT EXISTS (SELECT 1 FROM public.exos_sms_relay_outbox WHERE assignment_id = a.id AND kind = 'reply'
                    AND body LIKE 'Exos: group texts are paused%' AND created_at > now() - interval '1 day') THEN
      PERFORM public._exos_relay_reply(n.id, v_from, 'Exos: group texts are paused, so this text didn''t reach anyone. Reply STOP to stop these messages.',
                                       a.org_id, a.group_id, a.id);
    END IF;
    RETURN jsonb_build_object('action', 'paused', 'group_id', a.group_id);
  END IF;
  IF p_provider_ref IS NOT NULL AND EXISTS (SELECT 1 FROM public.exos_group_messages WHERE provider_ref = left(p_provider_ref, 80)) THEN$n$, 1);
