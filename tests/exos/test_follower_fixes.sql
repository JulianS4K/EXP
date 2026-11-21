-- ============================================================================
-- Follower fixes (mig 20261112100000, claude/exos-follower-fixes): the
-- Applier's review of 20261111110000. Self-contained (ff… ids), rolled back.
--   FF0 shape: the new helpers service role only, search_path pinned, the
--       counter table RLS on with no client grants, both marker patches, the
--       skip reason CHECK takes email_unconfirmed
--   FF1 consent: the one-follower and the whole-org reasons agree for every
--       reason; an unconfirmed address is skipped at publish and again at
--       send time; a follower confirmed later gets the next event
--   FF2 a publish with 5,000 followers finishes under statement_timeout 2s
--       and queues no mail (one INSERT: 5,000 pending notices); so does
--       exos_announce_to_followers; the digest job mails, oldest waiting
--       first, p_limit at a time, never twice
--   FF3 exos_follow_org: 30 a minute and 300 a UTC day per user (54000, the
--       follow not made, the count unchanged), per user, a new day resets
--   FF4 exos_org_followers carries no address (names and fan status only);
--       the export still does, rate limited and logged
--   FF5 exos_audit_export: 200 a day per org, then 54000; other orgs and the
--       follower export unaffected
-- Users: oa owner A, oc owner C, fl follower (throttle), fx follower B,
--        u1..u5 consent cases, big0001..big5000 followers.
-- ============================================================================
\set ON_ERROR_STOP on
BEGIN;

CREATE FUNCTION pg_temp.u(p text) RETURNS uuid LANGUAGE sql IMMUTABLE AS $$
  SELECT md5('ff:' || p)::uuid
$$;
CREATE FUNCTION pg_temp.act(p_uid uuid, p_admin boolean DEFAULT false) RETURNS void LANGUAGE sql AS $$
  SELECT set_config('app.uid', coalesce(p_uid::text, ''), true),
         set_config('app.jwt', CASE WHEN p_admin THEN '{"app_metadata":{"admin":"true"}}' ELSE '{}' END, true);
$$;
CREATE FUNCTION pg_temp.st(p_sql text) RETURNS text LANGUAGE plpgsql AS $$
BEGIN
  EXECUTE p_sql;
  RETURN 'ok';
EXCEPTION WHEN OTHERS THEN
  RETURN SQLSTATE;
END $$;
CREATE FUNCTION pg_temp.mails(p_to text) RETURNS integer LANGUAGE sql AS $$
  SELECT count(*)::int FROM public.exos_mail WHERE template = 'follower-new-event' AND to_email = p_to
$$;

INSERT INTO auth.users (id, email, email_confirmed_at) VALUES
  (pg_temp.u('oa'), 'ff-oa@x.com', now()), (pg_temp.u('oc'), 'ff-oc@x.com', now()),
  (pg_temp.u('fl'), 'ff-fl@x.com', now()), (pg_temp.u('fx'), 'ff-fx@x.com', now()),
  (pg_temp.u('u1'), 'ff-u1@x.com', now()),   -- may get it
  (pg_temp.u('u2'), 'ff-u2@x.com', NULL),    -- unconfirmed
  (pg_temp.u('u3'), 'not-an-address', now()),-- no email
  (pg_temp.u('u4'), 'ff-u4@x.com', now()),   -- opted out
  (pg_temp.u('u5'), 'ff-u5@x.com', now());   -- unsubscribed from A
INSERT INTO public.exos_orgs (id, name, slug, owner_uid) VALUES
  (pg_temp.u('A'), 'FF Hall', 'ff-hall', pg_temp.u('oa')),
  (pg_temp.u('C'), 'FF Club', 'ff-club', pg_temp.u('oc'));
INSERT INTO public.exos_org_memberships (org_id, user_id, role) VALUES
  (pg_temp.u('A'), pg_temp.u('oa'), 'owner'), (pg_temp.u('C'), pg_temp.u('oc'), 'owner');
INSERT INTO public.exos_org_follows (follower_uid, org_id)
SELECT pg_temp.u(x), pg_temp.u('A') FROM unnest(ARRAY['u1', 'u2', 'u3', 'u4', 'u5', 'oa']) x;
INSERT INTO public.exos_mail_prefs (user_id, marketing_opt_out) VALUES (pg_temp.u('u4'), true);
INSERT INTO public.exos_fans (org_id, email, user_id, source, first_name, last_name) VALUES
  (pg_temp.u('A'), 'ff-u1@x.com', pg_temp.u('u1'), 'order', 'Una', 'One'),
  (pg_temp.u('A'), 'ff-u5@x.com', pg_temp.u('u5'), 'order', NULL, NULL);
DO $$
BEGIN
  PERFORM set_config('exos.fan_consent_action', 'on', true);
  UPDATE public.exos_fans SET email_opt_out_at = now() WHERE org_id = pg_temp.u('A') AND user_id = pg_temp.u('u5');
  PERFORM set_config('exos.fan_consent_action', '', true);
END $$;
INSERT INTO public.exos_events (id, org_id, name, slug, status, starts_at, timezone, total_tickets, tickets_sold, currency, created_by) VALUES
  (pg_temp.u('e1'), pg_temp.u('A'), 'FF One', 'ff-e1', 'draft', now() + interval '5 days', 'America/New_York', 0, 0, 'usd', pg_temp.u('oa')),
  (pg_temp.u('e2'), pg_temp.u('A'), 'FF Two', 'ff-e2', 'draft', now() + interval '6 days', 'America/New_York', 0, 0, 'usd', pg_temp.u('oa'));

-- FF0 -------------------------------------------------------------------------
DO $$
DECLARE f text;
BEGIN
  FOREACH f IN ARRAY ARRAY['public._exos_follower_skip_reasons(uuid)', 'public._exos_follow_day_hit(uuid,integer)',
                           'public._exos_follower_skip_reason(uuid,uuid)', 'public._exos_follower_notices_on_publish(uuid)',
                           'public.exos_send_follower_digests(integer)'] LOOP
    ASSERT NOT has_function_privilege('anon', f, 'EXECUTE') AND NOT has_function_privilege('authenticated', f, 'EXECUTE')
       AND has_function_privilege('service_role', f, 'EXECUTE'), 'FF0 service role only: ' || f;
  END LOOP;
  FOREACH f IN ARRAY ARRAY['public.exos_org_followers(uuid,integer,integer)', 'public.exos_follow_org(uuid)',
                           'public.exos_audit_export(uuid,text,integer,uuid)'] LOOP
    ASSERT NOT has_function_privilege('anon', f, 'EXECUTE') AND has_function_privilege('authenticated', f, 'EXECUTE'), 'FF0 signed in: ' || f;
  END LOOP;
  ASSERT (SELECT bool_and(p.proconfig @> ARRAY['search_path=public, pg_temp']) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
           WHERE n.nspname = 'public' AND p.proname IN ('_exos_follower_skip_reasons', '_exos_follow_day_hit', '_exos_follower_skip_reason',
             '_exos_follower_notices_on_publish', 'exos_send_follower_digests', 'exos_org_followers', 'exos_follow_org', 'exos_audit_export')),
    'FF0 search_path pinned';
  ASSERT (SELECT relrowsecurity FROM pg_class WHERE oid = 'public.exos_follow_daily'::regclass), 'FF0 RLS on exos_follow_daily';
  ASSERT NOT has_table_privilege('anon', 'public.exos_follow_daily', 'SELECT')
     AND NOT has_table_privilege('authenticated', 'public.exos_follow_daily', 'SELECT')
     AND NOT has_table_privilege('authenticated', 'public.exos_follow_daily', 'UPDATE'), 'FF0 no client grants on exos_follow_daily';
  ASSERT position('/* exos: follow throttle */' IN pg_get_functiondef('public.exos_follow_org(uuid)'::regprocedure)) > 0, 'FF0 follow marker';
  ASSERT position('/* exos: export daily cap */' IN pg_get_functiondef('public.exos_audit_export(uuid,text,integer,uuid)'::regprocedure)) > 0,
    'FF0 export marker';
  ASSERT position('email_unconfirmed' IN (SELECT pg_get_constraintdef(oid) FROM pg_constraint
           WHERE conname = 'exos_follower_notices_skip_reason_check' AND conrelid = 'public.exos_follower_notices'::regclass)) > 0,
    'FF0 skip reason email_unconfirmed allowed';
  ASSERT position('_exos_follower_flush' IN pg_get_functiondef('public._exos_follower_notices_on_publish(uuid)'::regprocedure)) = 0,
    'FF0 the publish path never flushes';
  RAISE NOTICE 'OK  FF0 shape: grants, search_path, RLS, markers, CHECK';
END $$;

-- FF1 -------------------------------------------------------------------------
DO $$
DECLARE r jsonb;
BEGIN
  -- The two rule sets agree, follower by follower.
  ASSERT NOT EXISTS (
    SELECT 1 FROM public._exos_follower_skip_reasons(pg_temp.u('A')) s
     WHERE s.skip_reason IS DISTINCT FROM public._exos_follower_skip_reason(pg_temp.u('A'), s.follower_uid)), 'FF1 one = all';
  SELECT jsonb_object_agg(s.follower_uid::text, coalesce(s.skip_reason, 'ok')) INTO r FROM public._exos_follower_skip_reasons(pg_temp.u('A')) s;
  ASSERT r = jsonb_build_object(pg_temp.u('u1')::text, 'ok', pg_temp.u('u2')::text, 'email_unconfirmed', pg_temp.u('u3')::text, 'no_email',
                                pg_temp.u('u4')::text, 'opted_out', pg_temp.u('u5')::text, 'org_unsubscribed', pg_temp.u('oa')::text, 'org_staff'),
    'FF1 reasons ' || r;
  ASSERT public._exos_follower_skip_reason(pg_temp.u('A'), pg_temp.u('fx')) = 'not_following', 'FF1 not following';

  -- Publish e1: u1 pending, u2 skipped as unconfirmed, no mail yet.
  UPDATE public.exos_events SET status = 'published' WHERE id = pg_temp.u('e1');
  ASSERT (SELECT skip_reason FROM public.exos_follower_notices WHERE event_id = pg_temp.u('e1') AND follower_uid = pg_temp.u('u2')) = 'email_unconfirmed',
    'FF1 unconfirmed skipped at publish';
  ASSERT (SELECT count(*) FROM public.exos_follower_notices WHERE event_id = pg_temp.u('e1') AND status = 'pending') = 1, 'FF1 one pending';
  ASSERT (SELECT count(*) FROM public.exos_mail WHERE template = 'follower-new-event' AND to_email LIKE 'ff-%') = 0, 'FF1 publish queues nothing';

  -- u1's address goes unconfirmed before the digest: re-checked at send time.
  UPDATE auth.users SET email_confirmed_at = NULL WHERE id = pg_temp.u('u1');
  PERFORM public.exos_send_follower_digests(5000);
  ASSERT pg_temp.mails('ff-u1@x.com') = 0
     AND (SELECT skip_reason FROM public.exos_follower_notices WHERE event_id = pg_temp.u('e1') AND follower_uid = pg_temp.u('u1')) = 'email_unconfirmed',
    'FF1 unconfirmed at send time: skipped';

  -- Both confirm: the next event reaches both.
  UPDATE auth.users SET email_confirmed_at = now() WHERE id IN (pg_temp.u('u1'), pg_temp.u('u2'));
  UPDATE public.exos_events SET status = 'published' WHERE id = pg_temp.u('e2');
  PERFORM public.exos_send_follower_digests(5000);
  ASSERT pg_temp.mails('ff-u1@x.com') = 1 AND pg_temp.mails('ff-u2@x.com') = 1, 'FF1 confirmed later: the next event mails';
  ASSERT pg_temp.mails('not-an-address') + pg_temp.mails('ff-u4@x.com') + pg_temp.mails('ff-u5@x.com') + pg_temp.mails('ff-oa@x.com') = 0,
    'FF1 no consent, no mail';
  RAISE NOTICE 'OK  FF1 consent: one = all, unconfirmed skipped at publish and at send time';
END $$;

-- FF2 -------------------------------------------------------------------------
-- 5,000 followers of C (and one older pending notice of A, to check the
-- digest's order). bt is published before anyone follows (for the announce).
INSERT INTO auth.users (id, email, email_confirmed_at)
SELECT pg_temp.u('big' || i), 'ff-big' || i || '@x.com', now() FROM generate_series(1, 5000) i;
INSERT INTO public.exos_events (id, org_id, name, slug, status, starts_at, timezone, total_tickets, tickets_sold, currency, created_by) VALUES
  (pg_temp.u('bt'), pg_temp.u('C'), 'FF Announce', 'ff-bt', 'published', now() + interval '3 days', 'America/New_York', 0, 0, 'usd', pg_temp.u('oc')),
  (pg_temp.u('bp'), pg_temp.u('C'), 'FF Big', 'ff-bp', 'draft', now() + interval '4 days', 'America/New_York', 0, 0, 'usd', pg_temp.u('oc')),
  (pg_temp.u('e3'), pg_temp.u('A'), 'FF Three', 'ff-e3', 'published', now() + interval '7 days', 'America/New_York', 0, 0, 'usd', pg_temp.u('oa'));
INSERT INTO public.exos_org_follows (follower_uid, org_id)
SELECT pg_temp.u('big' || i), pg_temp.u('C') FROM generate_series(1, 5000) i;
UPDATE public.exos_follower_mail_slots SET last_mail_at = now() - interval '25 hours' WHERE org_id = pg_temp.u('A');
UPDATE public.exos_follower_notices SET created_at = now() - interval '1 hour' WHERE event_id = pg_temp.u('e3');

-- The publish itself, under a strict timeout.
SET LOCAL statement_timeout = '2s';
UPDATE public.exos_events SET status = 'published' WHERE id = pg_temp.u('bp');
DO $$ BEGIN PERFORM pg_temp.act(pg_temp.u('oc')); END $$;
CREATE TEMP TABLE ff_announced AS SELECT public.exos_announce_to_followers(pg_temp.u('bt')) AS notices;
DO $$ BEGIN PERFORM pg_temp.act(NULL); END $$;
SET LOCAL statement_timeout = 0;

DO $$
DECLARE n int;
BEGIN
  ASSERT (SELECT a.notices FROM ff_announced a) = 5000, 'FF2 announce recorded 5000 notices';
  ASSERT (SELECT count(*) FROM public.exos_follower_notices WHERE event_id = pg_temp.u('bp') AND status = 'pending') = 5000,
    'FF2 5000 pending notices for the publish';
  ASSERT (SELECT count(*) FROM public.exos_follower_notices WHERE event_id = pg_temp.u('bt') AND status = 'pending') = 5000,
    'FF2 5000 pending notices for the announce';
  ASSERT (SELECT count(*) FROM public.exos_mail WHERE template = 'follower-new-event' AND to_email LIKE 'ff-big%') = 0,
    'FF2 the publish queued no mail';
  PERFORM pg_temp.act(pg_temp.u('oc'));
  ASSERT public.exos_announce_to_followers(pg_temp.u('bp')) = 0, 'FF2 announce again: nobody new';
  PERFORM pg_temp.act(NULL);

  -- The digest: oldest waiting first (A's e3 notices for u1 and u2, an hour
  -- old), then C's 5,000.
  ASSERT (SELECT count(*) FROM public.exos_follower_notices WHERE event_id = pg_temp.u('e3') AND status = 'pending') = 2, 'FF2 A: two waiting';
  ASSERT public.exos_send_follower_digests(1) = 1, 'FF2 one';
  ASSERT (SELECT count(*) FROM public.exos_follower_notices WHERE event_id = pg_temp.u('e3') AND status = 'queued') = 1
     AND NOT EXISTS (SELECT 1 FROM public.exos_mail WHERE template = 'follower-new-event' AND to_email LIKE 'ff-big%'),
    'FF2 the oldest waiting goes first';
  ASSERT public.exos_send_follower_digests(200) = 200, 'FF2 p_limit at a time';
  ASSERT (SELECT count(*) FROM public.exos_follower_notices WHERE event_id = pg_temp.u('e3') AND status = 'queued') = 2, 'FF2 A done';
  SELECT count(*) INTO n FROM public.exos_mail WHERE template = 'follower-new-event' AND to_email LIKE 'ff-big%';
  ASSERT n = 199, 'FF2 C mails so far ' || n;
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_mail WHERE template = 'follower-new-event' AND to_email LIKE 'ff-big%'
                      GROUP BY to_email HAVING count(*) > 1), 'FF2 one mail per follower';
  ASSERT (SELECT count(*) FROM public.exos_mail WHERE template = 'follower-new-event' AND to_email LIKE 'ff-big%'
           AND jsonb_array_length(payload -> 'events') = 2) = n, 'FF2 both events in the one mail';
  ASSERT public.exos_send_follower_digests(200) = 200, 'FF2 the next batch';
  ASSERT (SELECT count(DISTINCT to_email) FROM public.exos_mail WHERE template = 'follower-new-event' AND to_email LIKE 'ff-big%')
       = (SELECT count(*) FROM public.exos_mail WHERE template = 'follower-new-event' AND to_email LIKE 'ff-big%'), 'FF2 still never twice';
  RAISE NOTICE 'OK  FF2 publish + announce with 5,000 followers under statement_timeout 2s, no mail in the publish, the digest mails oldest first';
END $$;

-- FF3 -------------------------------------------------------------------------
INSERT INTO public.exos_orgs (id, name, slug, owner_uid)
SELECT pg_temp.u('o' || i), 'FF Org ' || i, 'ff-org-' || i, pg_temp.u('oa') FROM generate_series(1, 32) i;
DO $$
DECLARE v_cnt int;
BEGIN
  DELETE FROM public.exos_rate_windows WHERE bucket LIKE 'follow:%';
  PERFORM pg_temp.act(pg_temp.u('fl'));
  PERFORM public.exos_follow_org(pg_temp.u('o' || i)) FROM generate_series(1, 30) i;
  ASSERT (SELECT count(*) FROM public.exos_org_follows WHERE follower_uid = pg_temp.u('fl')) = 30, 'FF3 30 a minute';
  SELECT followers_count INTO v_cnt FROM public.exos_orgs WHERE id = pg_temp.u('o31');
  ASSERT pg_temp.st(format('SELECT public.exos_follow_org(%L)', pg_temp.u('o31'))) = '54000', 'FF3 the 31st: 54000';
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_org_follows WHERE follower_uid = pg_temp.u('fl') AND org_id = pg_temp.u('o31'))
     AND (SELECT followers_count FROM public.exos_orgs WHERE id = pg_temp.u('o31')) = v_cnt, 'FF3 refused: no follow, count unchanged';
  ASSERT pg_temp.st(format('SELECT public.exos_follow_org(%L)', gen_random_uuid())) = '54000', 'FF3 throttled before the org lookup';
  -- Another user has their own budget.
  PERFORM pg_temp.act(pg_temp.u('fx'));
  PERFORM public.exos_follow_org(pg_temp.u('o31'));
  ASSERT EXISTS (SELECT 1 FROM public.exos_org_follows WHERE follower_uid = pg_temp.u('fx') AND org_id = pg_temp.u('o31')), 'FF3 per user';
  ASSERT (SELECT follows FROM public.exos_follow_daily WHERE user_id = pg_temp.u('fx')) = 1, 'FF3 counted for the day';

  -- 300 a day: fx at the cap today is refused; a new day resets.
  DELETE FROM public.exos_rate_windows WHERE bucket LIKE 'follow:%';
  UPDATE public.exos_follow_daily SET follows = 300 WHERE user_id = pg_temp.u('fx');
  ASSERT pg_temp.st(format('SELECT public.exos_follow_org(%L)', pg_temp.u('o32'))) = '54000', 'FF3 301st today: 54000';
  ASSERT (SELECT follows FROM public.exos_follow_daily WHERE user_id = pg_temp.u('fx')) = 300, 'FF3 a refused call is not counted';
  UPDATE public.exos_follow_daily SET day = day - 1 WHERE user_id = pg_temp.u('fx');
  PERFORM public.exos_follow_org(pg_temp.u('o32'));
  ASSERT (SELECT follows FROM public.exos_follow_daily WHERE user_id = pg_temp.u('fx')) = 1
     AND EXISTS (SELECT 1 FROM public.exos_org_follows WHERE follower_uid = pg_temp.u('fx') AND org_id = pg_temp.u('o32')), 'FF3 a new day';
  PERFORM pg_temp.act(NULL);
  ASSERT pg_temp.st(format('SELECT public.exos_follow_org(%L)', pg_temp.u('o32'))) = '42501', 'FF3 nobody: 42501 first';
  DELETE FROM public.exos_rate_windows WHERE bucket LIKE 'follow:%';
  RAISE NOTICE 'OK  FF3 follow throttle: 30 a minute, 300 a day, per user, refused calls change nothing';
END $$;

-- FF4 -------------------------------------------------------------------------
DO $$
DECLARE r jsonb; k text[];
BEGIN
  PERFORM pg_temp.act(pg_temp.u('oa'));
  r := public.exos_org_followers(pg_temp.u('A'), 500, 0);
  ASSERT (r ->> 'listed')::int = 2 AND jsonb_array_length(r -> 'rows') = 2, 'FF4 two fan rows';
  SELECT array_agg(DISTINCT key ORDER BY key) INTO k FROM jsonb_array_elements(r -> 'rows') x, jsonb_object_keys(x) key;
  ASSERT k = ARRAY['email_list', 'fan_id', 'first_name', 'followed_at', 'gets_new_event_mail', 'last_name'], 'FF4 row keys ' || array_to_string(k, ',');
  ASSERT position('@' IN r::text) = 0 AND position('ff-u1' IN r::text) = 0, 'FF4 no address anywhere';
  ASSERT (SELECT x ->> 'first_name' || ' ' || (x ->> 'last_name') FROM jsonb_array_elements(r -> 'rows') x WHERE x ->> 'first_name' IS NOT NULL) = 'Una One',
    'FF4 names';
  ASSERT (r ->> 'gets_new_event_mail')::int = 2, 'FF4 count: u1 and u2 (now confirmed) ' || (r ->> 'gets_new_event_mail');
  DELETE FROM public.exos_rate_windows WHERE bucket LIKE 'followers-export:%';
  r := public.exos_org_followers_export(pg_temp.u('A'));
  ASSERT position('ff-u1@x.com' IN r::text) > 0, 'FF4 the export carries addresses';
  ASSERT (SELECT count(*) FROM public.exos_org_audit WHERE org_id = pg_temp.u('A') AND action = 'export.run' AND entity_id = 'followers') = 1,
    'FF4 and is logged';
  PERFORM pg_temp.act(NULL);
  RAISE NOTICE 'OK  FF4 the follower list has names and fan status, never an address; the export does, logged';
END $$;

-- FF5 -------------------------------------------------------------------------
DO $$
DECLARE i int;
BEGIN
  PERFORM pg_temp.act(pg_temp.u('oa'));
  FOR i IN 1..200 LOOP
    DELETE FROM public.exos_rate_windows WHERE bucket LIKE 'audit-export:%';
    PERFORM public.exos_audit_export(pg_temp.u('A'), (ARRAY['audit', 'donations', 'price_disclosure', 'attendees'])[1 + i % 4], i);
  END LOOP;
  DELETE FROM public.exos_rate_windows WHERE bucket LIKE 'audit-export:%';
  ASSERT pg_temp.st(format('SELECT public.exos_audit_export(%L, %L, 1)', pg_temp.u('A'), 'audit')) = '54000', 'FF5 the 201st: 54000';
  ASSERT (SELECT count(*) FROM public.exos_org_audit WHERE org_id = pg_temp.u('A') AND action = 'export.run'
           AND entity_id IN ('audit', 'donations', 'price_disclosure', 'attendees')) = 200, 'FF5 200 logged, no more';
  -- The followers export has its own cap; C has its own 200.
  DELETE FROM public.exos_rate_windows WHERE bucket LIKE 'followers-export:%';
  ASSERT (public.exos_org_followers_export(pg_temp.u('A')) ->> 'count')::int = 2, 'FF5 the follower export is not this cap';
  PERFORM pg_temp.act(pg_temp.u('oc'));
  ASSERT public.exos_audit_export(pg_temp.u('C'), 'audit', 1), 'FF5 another org';
  PERFORM pg_temp.act(NULL);
  DELETE FROM public.exos_rate_windows WHERE bucket LIKE 'audit-export:%' OR bucket LIKE 'followers-export:%';
  RAISE NOTICE 'OK  FF5 exos_audit_export: 200 a day per org';
END $$;

ROLLBACK;
