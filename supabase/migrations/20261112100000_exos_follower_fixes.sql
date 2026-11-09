-- ============================================================================
-- Migration 20261112100000 — Exos: follower fixes (the Applier's review of
--   20261111110000_exos_neighborhoods). docs/fans.md "Followers",
--   docs/security.md "Neighborhood pages and followers".
--
-- Branch:   claude/exos-follower-fixes
--
-- 1. (S1) A publish never does the per-follower mail work. Before, the
--    publish trigger ran _exos_follower_flush once per follower inside the
--    organizer's UPDATE; its EXCEPTION WHEN others doesn't catch
--    query_canceled, so a big follower list hit statement_timeout and rolled
--    the publish back. Now _exos_follower_notices_on_publish (the trigger's
--    and exos_announce_to_followers' one path) is ONE set-based INSERT ...
--    SELECT ... ON CONFLICT DO NOTHING: a pending row for each follower who
--    may get the mail, a skipped row (with its reason) for the rest, from
--    _exos_follower_skip_reasons (the consent rules for a whole org in one
--    query). Building and queueing the mail (_exos_follower_flush, which
--    re-checks consent at send time) runs only in exos_send_follower_digests,
--    oldest waiting first (cron exos-follower-digests-hourly, still
--    INACTIVE). The (event, follower) key, the 24-hour slot and the flush's
--    locks are unchanged, so it stays once per event + follower and one mail
--    per follower per org per 24 hours (tests/exos/race_follower_mail.sh).
-- 2. (S1b) exos_follow_org is throttled per user: 30 a minute
--    (exos_rate_hit) and 300 a UTC day (exos_follow_daily), 54000 over
--    either, checked before the org is looked up. Marker patch
--    /* exos: follow throttle */.
-- 3. (S2) exos_org_followers no longer returns email (or any contact field):
--    names, since when, email-list state and whether they get the mail.
--    Addresses come only from exos_org_followers_export (3 a minute, 20 a day
--    per org, export.run in the audit log).
-- 4. (info a) exos_audit_export: at most 200 a day per org (its export.run
--    rows can't be deleted), under a per-org advisory lock. Marker patch
--    /* exos: export daily cap */.
-- 5. (info b) Follower mail goes only to a confirmed address
--    (auth.users.email_confirmed_at): new skip reason email_unconfirmed.
--
-- Touches:  C: TABLE exos_follow_daily (RLS on, service role only)
--           C: FUNCTION _exos_follower_skip_reasons, _exos_follow_day_hit
--              (service role)
--           W: TABLE exos_follower_notices (skip_reason CHECK + email_unconfirmed)
--           W: FUNCTION _exos_follower_skip_reason,
--              _exos_follower_notices_on_publish, exos_send_follower_digests,
--              exos_org_followers (full redefinitions: all created by
--              20261111110000 and patched by nothing since)
--           W: FUNCTION exos_follow_org (20260520140000; marker patch, the
--              body no migration has changed since), exos_audit_export
--              (20261109100000; marker patch)
-- Grants:   unchanged (nothing new for anon or authenticated; H3 unchanged).
-- Additive, replay-safe (IF NOT EXISTS, CREATE OR REPLACE, DROP/ADD of the
-- CHECK, marker-checked patches). No cron change. Not applied. Prod apply
-- needs operator OK; apply after 20261111110000.
-- ROLLBACK: re-run 20261111110000's sections 3 and 4 (the four functions);
--           re-create exos_follow_org from 20260520140000 and
--           exos_audit_export from 20261109100000; DROP FUNCTION
--           _exos_follower_skip_reasons, _exos_follow_day_hit; DROP TABLE
--           exos_follow_daily. The CHECK can keep the extra value.
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
-- 1. Consent: a confirmed address, and the whole org in one query
-- ===========================================================================
ALTER TABLE public.exos_follower_notices DROP CONSTRAINT IF EXISTS exos_follower_notices_skip_reason_check;
ALTER TABLE public.exos_follower_notices ADD CONSTRAINT exos_follower_notices_skip_reason_check
  CHECK (skip_reason IS NULL OR skip_reason IN
    ('not_following', 'org_staff', 'no_email', 'email_unconfirmed', 'opted_out', 'org_unsubscribed', 'event_not_listed', 'not_queued'));
COMMENT ON TABLE public.exos_follower_notices IS
  'mig 20261111110000 / 20261112100000: one "new event" notice per event + follower (the never-twice gate), recorded by the publish. pending = waiting for exos_send_follower_digests (and the follower''s 24-hour window); queued = in exos_mail (mail_id); skipped = no consent / not listed (skip_reason). Service role only; organizers see counts (exos_event_follower_notice).';

-- One follower (the flush, at send time). Same order of reasons as
-- _exos_follower_skip_reasons below; test FF1 checks they agree.
CREATE OR REPLACE FUNCTION public._exos_follower_skip_reason(p_org uuid, p_uid uuid)
RETURNS text LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT CASE
    WHEN NOT EXISTS (SELECT 1 FROM public.exos_org_follows f WHERE f.org_id = p_org AND f.follower_uid = p_uid)
      THEN 'not_following'
    WHEN p_uid = (SELECT o.owner_uid FROM public.exos_orgs o WHERE o.id = p_org)
      OR EXISTS (SELECT 1 FROM public.exos_org_memberships m
                  WHERE m.org_id = p_org AND m.user_id = p_uid AND m.disabled IS NOT TRUE)
      THEN 'org_staff'
    WHEN coalesce((SELECT u.email FROM auth.users u WHERE u.id = p_uid), '') !~ '^[^@[:space:]]+@[^@[:space:]]+$'
      THEN 'no_email'
    WHEN (SELECT u.email_confirmed_at FROM auth.users u WHERE u.id = p_uid) IS NULL
      THEN 'email_unconfirmed'
    WHEN EXISTS (SELECT 1 FROM public.exos_mail_prefs mp WHERE mp.user_id = p_uid AND mp.marketing_opt_out)
      THEN 'opted_out'
    WHEN EXISTS (SELECT 1 FROM public.exos_fans fa
                  WHERE fa.org_id = p_org AND fa.user_id = p_uid AND fa.email_opt_out_at IS NOT NULL)
      THEN 'org_unsubscribed'
  END
$$;
REVOKE ALL ON FUNCTION public._exos_follower_skip_reason(uuid, uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_follower_skip_reason(uuid, uuid) TO service_role;

-- Every follower of an org with its reason (NULL = may get the mail), in one
-- query: what a publish records. Plain index lookups per follower, no
-- function call per row.
CREATE OR REPLACE FUNCTION public._exos_follower_skip_reasons(p_org uuid)
RETURNS TABLE (follower_uid uuid, skip_reason text)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT f.follower_uid,
         CASE
           WHEN f.follower_uid = o.owner_uid
             OR EXISTS (SELECT 1 FROM public.exos_org_memberships m
                         WHERE m.org_id = f.org_id AND m.user_id = f.follower_uid AND m.disabled IS NOT TRUE)
             THEN 'org_staff'
           WHEN coalesce(u.email, '') !~ '^[^@[:space:]]+@[^@[:space:]]+$'
             THEN 'no_email'
           WHEN u.email_confirmed_at IS NULL
             THEN 'email_unconfirmed'
           WHEN EXISTS (SELECT 1 FROM public.exos_mail_prefs mp WHERE mp.user_id = f.follower_uid AND mp.marketing_opt_out)
             THEN 'opted_out'
           WHEN EXISTS (SELECT 1 FROM public.exos_fans fa
                         WHERE fa.org_id = f.org_id AND fa.user_id = f.follower_uid AND fa.email_opt_out_at IS NOT NULL)
             THEN 'org_unsubscribed'
         END
    FROM public.exos_org_follows f
    JOIN public.exos_orgs o ON o.id = f.org_id
    LEFT JOIN auth.users u ON u.id = f.follower_uid
   WHERE f.org_id = p_org
$$;
REVOKE ALL ON FUNCTION public._exos_follower_skip_reasons(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_follower_skip_reasons(uuid) TO service_role;

-- ===========================================================================
-- 2. Publishing records notices only; the digest job mails
-- ===========================================================================
-- A listed event went live: one notice per follower (once ever), pending for
-- those who may get the mail, skipped (with the reason) for the rest, in ONE
-- statement. No mail here: exos_send_follower_digests builds and queues it.
-- Returns the new pending notices.
CREATE OR REPLACE FUNCTION public._exos_follower_notices_on_publish(p_event uuid)
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_org uuid;
  v_n   integer;
BEGIN
  IF NOT public._exos_follower_event_ok(p_event) THEN
    RETURN 0;
  END IF;
  SELECT org_id INTO v_org FROM public.exos_events WHERE id = p_event;
  WITH ins AS (
    INSERT INTO public.exos_follower_notices (event_id, follower_uid, org_id, status, skip_reason)
    SELECT p_event, r.follower_uid, v_org,
           CASE WHEN r.skip_reason IS NULL THEN 'pending' ELSE 'skipped' END, r.skip_reason
      FROM public._exos_follower_skip_reasons(v_org) r
    ON CONFLICT (event_id, follower_uid) DO NOTHING
    RETURNING status)
  SELECT count(*) FILTER (WHERE status = 'pending') INTO v_n FROM ins;
  RETURN v_n;
END $$;
REVOKE ALL ON FUNCTION public._exos_follower_notices_on_publish(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_follower_notices_on_publish(uuid) TO service_role;

-- The sweep that sends: followers with pending notices whose 24-hour window
-- is free, oldest waiting first (so one big org can't hold the others back),
-- get one mail each with everything waiting (_exos_follower_flush: locks,
-- re-checks consent and listing, claims the slot). Returns mails queued.
CREATE OR REPLACE FUNCTION public.exos_send_follower_digests(p_limit integer DEFAULT 500)
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  r   record;
  v_n integer := 0;
BEGIN
  IF session_user NOT IN ('service_role', 'postgres', 'supabase_admin') THEN
    RAISE EXCEPTION 'exos_send_follower_digests: service role only' USING ERRCODE = '42501';
  END IF;
  FOR r IN
    SELECT n.org_id, n.follower_uid
      FROM public.exos_follower_notices n
     WHERE n.status = 'pending'
       AND NOT EXISTS (SELECT 1 FROM public.exos_follower_mail_slots s
                        WHERE s.org_id = n.org_id AND s.follower_uid = n.follower_uid
                          AND s.last_mail_at > now() - interval '24 hours')
     GROUP BY n.org_id, n.follower_uid
     ORDER BY min(n.created_at), n.org_id, n.follower_uid
     LIMIT least(greatest(coalesce(p_limit, 500), 1), 5000)
  LOOP
    BEGIN
      IF public._exos_follower_flush(r.org_id, r.follower_uid) IS NOT NULL THEN
        v_n := v_n + 1;
      END IF;
    EXCEPTION WHEN others THEN
      RAISE WARNING 'exos_send_follower_digests: org % follower %: % (%)', r.org_id, r.follower_uid, SQLERRM, SQLSTATE;
    END;
  END LOOP;
  RETURN v_n;
END $$;
REVOKE ALL ON FUNCTION public.exos_send_follower_digests(integer) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_send_follower_digests(integer) TO service_role;

-- ===========================================================================
-- 3. The follower list: names and fan status, no addresses
-- ===========================================================================
-- Owner / manager (and platform admins). Rows only for followers with a fan
-- profile in the org; never an email: addresses come from
-- exos_org_followers_export (rate limited, logged as export.run).
CREATE OR REPLACE FUNCTION public.exos_org_followers(p_org_id uuid, p_limit integer DEFAULT 100, p_offset integer DEFAULT 0)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_lim   integer := least(greatest(coalesce(p_limit, 100), 1), 500);
  v_off   integer := least(greatest(coalesce(p_offset, 0), 0), 1000000);
  v_total integer;
  v_seen  integer;
BEGIN
  IF auth.uid() IS NULL OR NOT (public.exos_is_admin() OR public.exos_has_org_role(p_org_id, ARRAY['owner', 'manager'])) THEN
    RAISE EXCEPTION 'exos_org_followers: owners and managers only' USING ERRCODE = '42501';
  END IF;
  SELECT count(*) INTO v_total FROM public.exos_org_follows f WHERE f.org_id = p_org_id;
  SELECT count(*) INTO v_seen FROM public._exos_org_follower_rows(p_org_id);
  RETURN jsonb_build_object(
    'total', v_total, 'listed', v_seen, 'not_listed', v_total - v_seen,
    'gets_new_event_mail', (SELECT count(*) FROM public._exos_follower_skip_reasons(p_org_id) s WHERE s.skip_reason IS NULL),
    'rows', coalesce((SELECT jsonb_agg(jsonb_build_object('fan_id', r.fan_id, 'first_name', r.first_name, 'last_name', r.last_name,
                                                          'followed_at', r.followed_at, 'email_list', r.email_list,
                                                          'gets_new_event_mail', r.gets_new_event_mail)
                                       ORDER BY r.followed_at DESC, r.fan_id)
                        FROM (SELECT * FROM public._exos_org_follower_rows(p_org_id)
                               ORDER BY followed_at DESC, fan_id LIMIT v_lim OFFSET v_off) r), '[]'::jsonb));
END $$;
REVOKE ALL ON FUNCTION public.exos_org_followers(uuid, integer, integer) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_org_followers(uuid, integer, integer) TO authenticated;

-- ===========================================================================
-- 4. Following is throttled: 30 a minute, 300 a UTC day per user
-- ===========================================================================
-- One row per user: today's follow calls. Reset on the first call of a new
-- day, so it never grows past one row per user.
CREATE TABLE IF NOT EXISTS public.exos_follow_daily (
  user_id uuid PRIMARY KEY REFERENCES auth.users (id) ON DELETE CASCADE,
  day     date NOT NULL,
  follows integer NOT NULL CHECK (follows >= 0)
);
COMMENT ON TABLE public.exos_follow_daily IS
  'mig 20261112100000: exos_follow_org calls per user per UTC day (300 a day). Service role only.';
ALTER TABLE public.exos_follow_daily ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.exos_follow_daily FROM PUBLIC, anon, authenticated;
GRANT ALL ON public.exos_follow_daily TO service_role;
DO $$
DECLARE r text;
BEGIN
  FOREACH r IN ARRAY ARRAY['coworker_readonly', 'analyst_ro'] LOOP
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = r) THEN
      EXECUTE format('REVOKE ALL ON public.exos_follow_daily FROM %I', r);
    END IF;
  END LOOP;
END $$;

-- Counts one call; true while the user is within p_limit today. Like
-- exos_rate_hit, a refused call's caller raises, which rolls the count back.
CREATE OR REPLACE FUNCTION public._exos_follow_day_hit(p_uid uuid, p_limit integer)
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_day date := (now() AT TIME ZONE 'UTC')::date;
  v_n   integer;
BEGIN
  IF p_uid IS NULL THEN
    RETURN false;
  END IF;
  INSERT INTO public.exos_follow_daily AS d (user_id, day, follows) VALUES (p_uid, v_day, 1)
  ON CONFLICT (user_id) DO UPDATE
    SET follows = CASE WHEN d.day = v_day THEN d.follows + 1 ELSE 1 END, day = v_day
  RETURNING follows INTO v_n;
  RETURN v_n <= greatest(coalesce(p_limit, 0), 0);
END $$;
REVOKE ALL ON FUNCTION public._exos_follow_day_hit(uuid, integer) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_follow_day_hit(uuid, integer) TO service_role;

SELECT pg_temp.exos_patch_n('public.exos_follow_org(uuid)',
  '/* exos: follow throttle */',
  $o$  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'exos_follow_org: not authenticated' USING ERRCODE = '42501';
  END IF;
$o$,
  $n$  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'exos_follow_org: not authenticated' USING ERRCODE = '42501';
  END IF;
  /* exos: follow throttle */ -- mig 20261112100000: 30 a minute, 300 a UTC day per user
  IF NOT public.exos_rate_hit('follow:' || v_uid::text, 30) THEN
    RAISE EXCEPTION 'exos_follow_org: too many follows, try again in a minute' USING ERRCODE = '54000';
  END IF;
  IF NOT public._exos_follow_day_hit(v_uid, 300) THEN
    RAISE EXCEPTION 'exos_follow_org: daily follow limit reached (300 a day)' USING ERRCODE = '54000';
  END IF;
$n$, 1);

-- ===========================================================================
-- 5. exos_audit_export: at most 200 a day per org
-- ===========================================================================
-- Its export.run rows are append-only, so a capped count keeps one member
-- from flooding the org's log (30 a minute per user stays). Counted per org
-- over the last 24 hours, for this RPC's kinds only (the fan, audience and
-- follower exports have their own caps), under an advisory lock so two
-- calls at the cap don't both pass.
SELECT pg_temp.exos_patch_n('public.exos_audit_export(uuid,text,integer,uuid)',
  '/* exos: export daily cap */',
  $o$  IF NOT public.exos_rate_hit('audit-export:' || auth.uid()::text, 30) THEN
    RAISE EXCEPTION 'too many exports a minute' USING ERRCODE = '54000';
  END IF;
$o$,
  $n$  IF NOT public.exos_rate_hit('audit-export:' || auth.uid()::text, 30) THEN
    RAISE EXCEPTION 'too many exports a minute' USING ERRCODE = '54000';
  END IF;
  /* exos: export daily cap */ -- mig 20261112100000: 200 a day per org
  PERFORM pg_advisory_xact_lock(hashtextextended('exos-audit-export:' || v_org::text, 0));
  IF (SELECT count(*) FROM public.exos_org_audit a
       WHERE a.org_id = v_org AND a.action = 'export.run' AND a.entity_type = 'export'
         AND a.entity_id IN ('audit', 'donations', 'price_disclosure', 'attendees')
         AND a.at > now() - interval '1 day') >= 200 THEN
    RAISE EXCEPTION 'daily export limit reached (200 per organization)' USING ERRCODE = '54000';
  END IF;
$n$, 1);
