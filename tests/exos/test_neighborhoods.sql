-- ============================================================================
-- Neighborhood pages + follower "new event" mail + follower list
-- (mig 20261111110000, claude/exos-neighborhoods). Self-contained (nb… ids),
-- rolled back.
--   NB0 shape: grants (anon: the two page RPCs and the unfollow token, never
--       the internals), search_path pinned, RLS on, no client grants on the
--       follower tables, the template allowed
--   NB1 neighborhood matching: haversine pairs (the same as
--       src/lib/neighborhoods.test.ts), nearest center wins, outside every
--       circle is nothing; the page lists published, listed, upcoming events
--       in the window with a fresh pin; hidden (noindex), drafts, past, far
--       off, stale pins and other neighborhoods are left out; the list counts;
--       the no-coordinates count is for admins only; anon can call it; 120
--       calls a minute per network
--   NB2 follower mail: consent gating (opted out, unsubscribed from the org,
--       no email, org staff), one mail per (event, follower) across
--       republishing and the announce RPC, the 24-hour limit with batching
--       into one mail, noindex / series dates not announced (un-hiding is),
--       nothing sent (queued only), the organizer's counts and who may read
--       them, no cross-org leaks
--   NB3 follower list: only followers with a fan profile are rows, the rest
--       a count, non-fan emails never out; export logs export.run and is
--       rate limited; owner / manager only; cross-org refused
--   NB4 unfollow: the mail's token unfollows once (count right, waiting
--       notices skipped), a bad token says nothing, no mail after
-- Users: oa owner A, ma manager A, fa finance A, ca content A, ob owner B,
--        f1..f4 followers.
-- ============================================================================
\set ON_ERROR_STOP on
BEGIN;

CREATE FUNCTION pg_temp.u(p text) RETURNS uuid LANGUAGE sql IMMUTABLE AS $$
  SELECT md5('nb:' || p)::uuid
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
CREATE FUNCTION pg_temp.publish(p_ev text) RETURNS void LANGUAGE sql AS $$
  UPDATE public.exos_events SET status = 'published' WHERE id = pg_temp.u(p_ev);
$$;

INSERT INTO auth.users (id, email, email_confirmed_at) VALUES
  (pg_temp.u('oa'), 'nb-oa@x.com', now()), (pg_temp.u('ma'), 'nb-ma@x.com', now()),
  (pg_temp.u('fa'), 'nb-fa@x.com', now()), (pg_temp.u('ca'), 'nb-ca@x.com', now()),
  (pg_temp.u('ob'), 'nb-ob@x.com', now()),
  (pg_temp.u('f1'), 'nb-f1@x.com', now()), (pg_temp.u('f2'), 'nb-f2@x.com', now()),
  (pg_temp.u('f3'), 'nb-f3@x.com', now()), (pg_temp.u('f4'), NULL, now());
INSERT INTO public.exos_orgs (id, name, slug, owner_uid) VALUES
  (pg_temp.u('A'), 'NB Hall <A>', 'nb-hall', pg_temp.u('oa')),
  (pg_temp.u('B'), 'NB Other', 'nb-other', pg_temp.u('ob'));
INSERT INTO public.exos_org_memberships (org_id, user_id, role) VALUES
  (pg_temp.u('A'), pg_temp.u('oa'), 'owner'), (pg_temp.u('A'), pg_temp.u('ma'), 'manager'),
  (pg_temp.u('A'), pg_temp.u('fa'), 'finance'), (pg_temp.u('A'), pg_temp.u('ca'), 'content'),
  (pg_temp.u('B'), pg_temp.u('ob'), 'owner');

-- Neighborhood events (org B, nobody follows B yet). Pins: Elsewhere (Bushwick),
-- Williamsburg, a stale Bushwick pin.
INSERT INTO public.exos_events (id, org_id, name, slug, status, starts_at, ends_at, timezone, noindex, total_tickets, tickets_sold, currency, created_by) VALUES
  (pg_temp.u('bk'),      pg_temp.u('B'), 'NB Bushwick Night', 'nb-bk',      'published', now() + interval '2 days',  NULL, 'America/New_York', false, 0, 0, 'usd', pg_temp.u('ob')),
  (pg_temp.u('bk10'),    pg_temp.u('B'), 'NB Bushwick Later', 'nb-bk10',    'published', now() + interval '10 days', NULL, 'America/New_York', false, 0, 0, 'usd', pg_temp.u('ob')),
  (pg_temp.u('bkfar'),   pg_temp.u('B'), 'NB Bushwick Far',   'nb-bkfar',   'published', now() + interval '20 days', NULL, 'America/New_York', false, 0, 0, 'usd', pg_temp.u('ob')),
  (pg_temp.u('bkhid'),   pg_temp.u('B'), 'NB Bushwick Hidden','nb-bkhid',   'published', now() + interval '2 days',  NULL, 'America/New_York', true,  0, 0, 'usd', pg_temp.u('ob')),
  (pg_temp.u('bkdraft'), pg_temp.u('B'), 'NB Bushwick Draft', 'nb-bkdraft', 'draft',     now() + interval '2 days',  NULL, 'America/New_York', false, 0, 0, 'usd', pg_temp.u('ob')),
  (pg_temp.u('bkpast'),  pg_temp.u('B'), 'NB Bushwick Past',  'nb-bkpast',  'published', now() - interval '2 days',  now() - interval '1 day', 'America/New_York', false, 0, 0, 'usd', pg_temp.u('ob')),
  (pg_temp.u('bkstale'), pg_temp.u('B'), 'NB Bushwick Stale', 'nb-bkstale', 'published', now() + interval '3 days',  NULL, 'America/New_York', false, 0, 0, 'usd', pg_temp.u('ob')),
  (pg_temp.u('wb'),      pg_temp.u('B'), 'NB Williamsburg',   'nb-wb',      'published', now() + interval '1 day',   NULL, 'America/New_York', false, 0, 0, 'usd', pg_temp.u('ob')),
  (pg_temp.u('nopin'),   pg_temp.u('B'), 'NB No Pin',         'nb-nopin',   'published', now() + interval '1 day',   NULL, 'America/New_York', false, 0, 0, 'usd', pg_temp.u('ob'));
INSERT INTO public.exos_event_geo (event_id, query, status, lat, lng, geocoded_at) VALUES
  (pg_temp.u('bk'),      '599 Johnson Ave', 'ok', 40.7096, -73.9235, now()),
  (pg_temp.u('bk10'),    '599 Johnson Ave', 'ok', 40.7096, -73.9235, now()),
  (pg_temp.u('bkfar'),   '599 Johnson Ave', 'ok', 40.7096, -73.9235, now()),
  (pg_temp.u('bkhid'),   '599 Johnson Ave', 'ok', 40.7096, -73.9235, now()),
  (pg_temp.u('bkdraft'), '599 Johnson Ave', 'ok', 40.7096, -73.9235, now()),
  (pg_temp.u('bkpast'),  '599 Johnson Ave', 'ok', 40.7096, -73.9235, now()),
  (pg_temp.u('bkstale'), '599 Johnson Ave', 'ok', 40.7096, -73.9235, now() - interval '31 days'),
  (pg_temp.u('wb'),      'Bedford Ave',     'ok', 40.7180, -73.9570, now());

-- NB0 -------------------------------------------------------------------------
DO $$
DECLARE f text;
BEGIN
  FOREACH f IN ARRAY ARRAY['public.exos_neighborhoods_list(text,integer)', 'public.exos_neighborhood_page(text,integer)',
                           'public.exos_unfollow_by_token(text)'] LOOP
    ASSERT has_function_privilege('anon', f, 'EXECUTE') AND has_function_privilege('authenticated', f, 'EXECUTE'), 'NB0 public: ' || f;
  END LOOP;
  FOREACH f IN ARRAY ARRAY['public.exos_event_follower_notice(uuid)', 'public.exos_org_followers(uuid,integer,integer)',
                           'public.exos_org_followers_export(uuid)', 'public.exos_announce_to_followers(uuid)'] LOOP
    ASSERT NOT has_function_privilege('anon', f, 'EXECUTE') AND has_function_privilege('authenticated', f, 'EXECUTE'), 'NB0 signed in: ' || f;
  END LOOP;
  FOREACH f IN ARRAY ARRAY['public._exos_neighborhood_of(double precision,double precision,text)', 'public._exos_neighborhood_rate_ok()',
                           'public._exos_follower_skip_reason(uuid,uuid)', 'public._exos_follower_event_ok(uuid)',
                           'public._exos_follower_flush(uuid,uuid)', 'public._exos_follower_notices_on_publish(uuid)',
                           'public._exos_org_follower_rows(uuid)', 'public.exos_send_follower_digests(integer)'] LOOP
    ASSERT NOT has_function_privilege('anon', f, 'EXECUTE') AND NOT has_function_privilege('authenticated', f, 'EXECUTE')
       AND has_function_privilege('service_role', f, 'EXECUTE'), 'NB0 service role only: ' || f;
  END LOOP;
  ASSERT NOT has_function_privilege('anon', 'public._exos_tg_follower_new_event()', 'EXECUTE')
     AND NOT has_function_privilege('authenticated', 'public._exos_tg_follower_new_event()', 'EXECUTE'), 'NB0 trigger fn';
  ASSERT (SELECT bool_and(p.proconfig @> ARRAY['search_path=public, pg_temp']) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
           WHERE n.nspname = 'public' AND p.proname IN ('exos_neighborhoods_list', 'exos_neighborhood_page', 'exos_unfollow_by_token',
             'exos_event_follower_notice', 'exos_org_followers', 'exos_org_followers_export', 'exos_announce_to_followers',
             '_exos_neighborhood_of', '_exos_follower_skip_reason', '_exos_follower_event_ok', '_exos_follower_flush',
             '_exos_follower_notices_on_publish', '_exos_org_follower_rows', 'exos_send_follower_digests', '_exos_tg_follower_new_event',
             'exos_geo_distance_m', '_exos_neighborhood_rate_ok')), 'NB0 search_path pinned';
  FOREACH f IN ARRAY ARRAY['exos_neighborhoods', 'exos_follower_notices', 'exos_follower_mail_slots', 'exos_follow_tokens'] LOOP
    ASSERT (SELECT relrowsecurity FROM pg_class WHERE oid = ('public.' || f)::regclass), 'NB0 RLS on ' || f;
  END LOOP;
  FOREACH f IN ARRAY ARRAY['exos_follower_notices', 'exos_follower_mail_slots', 'exos_follow_tokens'] LOOP
    ASSERT NOT has_table_privilege('anon', 'public.' || f, 'SELECT') AND NOT has_table_privilege('authenticated', 'public.' || f, 'SELECT'),
      'NB0 no client read: ' || f;
  END LOOP;
  ASSERT has_table_privilege('anon', 'public.exos_neighborhoods', 'SELECT')
     AND NOT has_table_privilege('anon', 'public.exos_neighborhoods', 'INSERT')
     AND NOT has_table_privilege('authenticated', 'public.exos_neighborhoods', 'UPDATE'), 'NB0 neighborhoods read-only for clients';
  ASSERT position('follower-new-event' IN (SELECT pg_get_constraintdef(oid) FROM pg_constraint
                                            WHERE conname = 'exos_mail_template_check' AND conrelid = 'public.exos_mail'::regclass)) > 0,
    'NB0 template allowed';
  ASSERT (SELECT count(*) FROM public.exos_neighborhoods WHERE city = 'nyc' AND active) >= 11, 'NB0 NYC seeded';
  ASSERT position('/* exos: follower notices */' IN pg_get_functiondef('public.exos_announce_to_followers(uuid)'::regprocedure)) > 0,
    'NB0 announce redefined';
  RAISE NOTICE 'OK  NB0 shape: grants, search_path, RLS, template, seed';
END $$;

-- NB1 -------------------------------------------------------------------------
DO $$
DECLARE p jsonb; l jsonb; ids text[];
BEGIN
  -- The same pairs as src/lib/neighborhoods.test.ts.
  ASSERT abs(public.exos_geo_distance_m(40.6990, -73.9200, 40.7128, -73.9570) - 3475.9) < 1, 'NB1 Bushwick -> Williamsburg centers '
    || public.exos_geo_distance_m(40.6990, -73.9200, 40.7128, -73.9570);
  ASSERT abs(public.exos_geo_distance_m(40.7096, -73.9235, 40.7096, -73.9235)) < 0.001, 'NB1 same point';
  ASSERT abs(public.exos_geo_distance_m(40.7580, -73.9855, 40.6413, -73.7781) - 21773.4) < 1, 'NB1 Times Square -> JFK '
    || public.exos_geo_distance_m(40.7580, -73.9855, 40.6413, -73.7781);
  ASSERT public._exos_neighborhood_of(40.7096, -73.9235) = 'bushwick', 'NB1 Elsewhere is Bushwick';
  ASSERT public._exos_neighborhood_of(40.7580, -73.9855) = 'midtown', 'NB1 Times Square is Midtown';
  ASSERT public._exos_neighborhood_of(40.7205, -73.9850) IN ('lower-east-side', 'east-village'), 'NB1 overlap picks one';
  ASSERT public._exos_neighborhood_of(40.7205, -73.9850) = 'lower-east-side', 'NB1 overlap: the nearest center';
  ASSERT public._exos_neighborhood_of(40.5795, -74.1502) IS NULL, 'NB1 Staten Island: no neighborhood';
  ASSERT public._exos_neighborhood_of(NULL, NULL) IS NULL, 'NB1 no pin';
  ASSERT public._exos_neighborhood_of(40.7096, -73.9235, 'la') IS NULL, 'NB1 another city';

  -- Anonymous visitor.
  PERFORM pg_temp.act(NULL);
  SET LOCAL ROLE anon;
  p := public.exos_neighborhood_page('Bushwick');
  l := public.exos_neighborhoods_list('nyc', 7);
  RESET ROLE;
  ASSERT p -> 'neighborhood' ->> 'name' = 'Bushwick' AND (p ->> 'days')::int = 7, 'NB1 page header ' || p;
  SELECT array_agg(e ->> 'name' ORDER BY e ->> 'name') INTO ids FROM jsonb_array_elements(p -> 'events') e WHERE e ->> 'name' LIKE 'NB %';
  ASSERT ids = ARRAY['NB Bushwick Night'], 'NB1 this week in Bushwick: ' || coalesce(array_to_string(ids, ', '), '(none)');
  ASSERT NOT p ? 'missing_coordinates', 'NB1 the no-coordinates count is not public';
  ASSERT (SELECT e -> 'org' ->> 'slug' FROM jsonb_array_elements(p -> 'events') e WHERE e ->> 'name' = 'NB Bushwick Night') = 'nb-other',
    'NB1 organizer on the card';
  ASSERT (SELECT (e ->> 'events')::int FROM jsonb_array_elements(l) e WHERE e ->> 'slug' = 'bushwick')
       >= 1, 'NB1 list counts Bushwick';
  ASSERT (SELECT (e ->> 'events')::int FROM jsonb_array_elements(l) e WHERE e ->> 'slug' = 'williamsburg') >= 1, 'NB1 list counts Williamsburg';
  ASSERT (SELECT count(*) FROM jsonb_array_elements(l)) = (SELECT count(*) FROM public.exos_neighborhoods WHERE city = 'nyc' AND active),
    'NB1 every active neighborhood listed';

  p := public.exos_neighborhood_page('bushwick', 14);
  SELECT array_agg(e ->> 'name' ORDER BY e ->> 'name') INTO ids FROM jsonb_array_elements(p -> 'events') e WHERE e ->> 'name' LIKE 'NB %';
  ASSERT ids = ARRAY['NB Bushwick Later', 'NB Bushwick Night'], 'NB1 two weeks: ' || array_to_string(ids, ', ');
  ASSERT (public.exos_neighborhood_page('bushwick', 99) ->> 'days')::int = 14, 'NB1 window capped at 14 days';
  SELECT array_agg(e ->> 'name') INTO ids FROM jsonb_array_elements(public.exos_neighborhood_page('williamsburg') -> 'events') e
   WHERE e ->> 'name' LIKE 'NB %';
  ASSERT ids = ARRAY['NB Williamsburg'], 'NB1 Williamsburg has its own';
  ASSERT public.exos_neighborhood_page('nowhere') IS NULL AND public.exos_neighborhood_page(NULL) IS NULL, 'NB1 unknown slug';
  UPDATE public.exos_neighborhoods SET active = false WHERE slug = 'gowanus';
  ASSERT public.exos_neighborhood_page('gowanus') IS NULL, 'NB1 inactive slug';
  SET LOCAL ROLE anon;
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_neighborhoods WHERE slug = 'gowanus'), 'NB1 anon does not see an inactive row';
  RESET ROLE;

  -- Admins see how many listed events have no pin.
  PERFORM pg_temp.act(pg_temp.u('oa'), true);
  p := public.exos_neighborhood_page('bushwick');
  ASSERT (p ->> 'missing_coordinates')::int >= 2, 'NB1 admin: no pin (no-pin + stale) ' || coalesce(p ->> 'missing_coordinates', 'absent');
  PERFORM pg_temp.act(pg_temp.u('oa'));
  ASSERT NOT public.exos_neighborhood_page('bushwick') ? 'missing_coordinates', 'NB1 an org owner is not an admin';
  PERFORM pg_temp.act(NULL);
  -- 120 a minute per network, then 54000 (this session is one network).
  DELETE FROM public.exos_rate_windows WHERE bucket LIKE 'neighborhoods:%';
  PERFORM count(public.exos_neighborhood_page('bushwick')) FROM generate_series(1, 120);
  ASSERT pg_temp.st($q$SELECT public.exos_neighborhood_page('bushwick')$q$) = '54000', 'NB1 rate limited';
  ASSERT pg_temp.st($q$SELECT public.exos_neighborhoods_list()$q$) = '54000', 'NB1 the list shares the limit';
  DELETE FROM public.exos_rate_windows WHERE bucket LIKE 'neighborhoods:%';
  RAISE NOTICE 'OK  NB1 neighborhood matching, window, hidden / draft / past / stale left out, admin-only count, rate limit';
END $$;

-- NB2 -------------------------------------------------------------------------
-- Followers of A: f1 (ok), f2 (opted out of follow-ups), f3 (unsubscribed
-- from A's list), f4 (no email), ma (A's manager). f1 also follows B.
DO $$
DECLARE u text;
BEGIN
  FOREACH u IN ARRAY ARRAY['f1', 'f2', 'f3', 'f4', 'ma'] LOOP
    PERFORM pg_temp.act(pg_temp.u(u));
    PERFORM public.exos_follow_org(pg_temp.u('A'));
  END LOOP;
  PERFORM pg_temp.act(pg_temp.u('f1'));
  PERFORM public.exos_follow_org(pg_temp.u('B'));
  PERFORM pg_temp.act(NULL);
END $$;
INSERT INTO public.exos_mail_prefs (user_id, marketing_opt_out) VALUES (pg_temp.u('f2'), true);
INSERT INTO public.exos_fans (org_id, email, user_id, source) VALUES
  (pg_temp.u('A'), 'nb-f1@x.com', pg_temp.u('f1'), 'order'),
  (pg_temp.u('A'), 'nb-f3@x.com', pg_temp.u('f3'), 'order');
DO $$
BEGIN
  PERFORM set_config('exos.fan_consent_action', 'on', true);
  UPDATE public.exos_fans SET email_opt_out_at = now() WHERE org_id = pg_temp.u('A') AND user_id = pg_temp.u('f3');
  PERFORM set_config('exos.fan_consent_action', '', true);
END $$;
INSERT INTO public.exos_events (id, org_id, name, slug, status, starts_at, timezone, noindex, series_index, total_tickets, tickets_sold, currency, created_by) VALUES
  (pg_temp.u('a1'), pg_temp.u('A'), 'NB A One',    'nb-a1', 'draft', now() + interval '5 days', 'America/New_York', false, NULL, 0, 0, 'usd', pg_temp.u('oa')),
  (pg_temp.u('a2'), pg_temp.u('A'), 'NB A Two',    'nb-a2', 'draft', now() + interval '6 days', 'America/New_York', false, NULL, 0, 0, 'usd', pg_temp.u('oa')),
  (pg_temp.u('a3'), pg_temp.u('A'), 'NB A Three',  'nb-a3', 'draft', now() + interval '7 days', 'America/New_York', false, NULL, 0, 0, 'usd', pg_temp.u('oa')),
  (pg_temp.u('ah'), pg_temp.u('A'), 'NB A Hidden', 'nb-ah', 'draft', now() + interval '8 days', 'America/New_York', true,  NULL, 0, 0, 'usd', pg_temp.u('oa')),
  (pg_temp.u('as'), pg_temp.u('A'), 'NB A Series 2', 'nb-as', 'draft', now() + interval '9 days', 'America/New_York', false, 1, 0, 0, 'usd', pg_temp.u('oa')),
  (pg_temp.u('ap'), pg_temp.u('A'), 'NB A Past',   'nb-ap', 'draft', now() - interval '1 day', 'America/New_York', false, NULL, 0, 0, 'usd', pg_temp.u('oa')),
  (pg_temp.u('b1'), pg_temp.u('B'), 'NB B One',    'nb-b1', 'draft', now() + interval '5 days', 'America/New_York', false, NULL, 0, 0, 'usd', pg_temp.u('ob'));

DO $$
DECLARE r jsonb; m record; n int;
BEGIN
  -- Before publishing: the organizer's count is the consenting followers.
  PERFORM pg_temp.act(pg_temp.u('oa'));
  r := public.exos_event_follower_notice(pg_temp.u('a1'));
  ASSERT r ->> 'state' = 'before' AND (r ->> 'followers')::int = 5 AND (r ->> 'will_notify')::int = 1
     AND (r ->> 'eligible')::boolean, 'NB2 before: 1 of 5 followers will be notified ' || r;
  r := public.exos_event_follower_notice(pg_temp.u('ah'));
  ASSERT r ->> 'reason' = 'hidden' AND (r ->> 'will_notify')::int = 0, 'NB2 before, hidden: nobody ' || r;
  ASSERT public.exos_event_follower_notice(pg_temp.u('as')) ->> 'reason' = 'series_date', 'NB2 a later series date';
  PERFORM pg_temp.act(pg_temp.u('ma'));
  ASSERT (public.exos_event_follower_notice(pg_temp.u('a1')) ->> 'will_notify')::int = 1, 'NB2 manager sees it';
  PERFORM pg_temp.act(pg_temp.u('fa'));
  ASSERT pg_temp.st($q$SELECT public.exos_event_follower_notice(md5('nb:a1')::uuid)$q$) = '42501', 'NB2 finance: 42501';
  PERFORM pg_temp.act(pg_temp.u('ca'));
  ASSERT pg_temp.st($q$SELECT public.exos_event_follower_notice(md5('nb:a1')::uuid)$q$) = '42501', 'NB2 content: 42501';
  PERFORM pg_temp.act(pg_temp.u('ob'));
  ASSERT pg_temp.st($q$SELECT public.exos_event_follower_notice(md5('nb:a1')::uuid)$q$) = 'P0002', 'NB2 another org: not found';
  PERFORM pg_temp.act(NULL);
  ASSERT pg_temp.st($q$SELECT public.exos_event_follower_notice(md5('nb:a1')::uuid)$q$) = 'P0002', 'NB2 nobody: not found';

  -- Publish a1: one mail, to f1 only; the rest skipped with their reason.
  PERFORM pg_temp.publish('a1');
  ASSERT pg_temp.mails('nb-f1@x.com') = 1, 'NB2 f1 mailed once';
  ASSERT pg_temp.mails('nb-f2@x.com') + pg_temp.mails('nb-f3@x.com') + pg_temp.mails('nb-ma@x.com') = 0, 'NB2 no consent, no mail';
  SELECT jsonb_object_agg(n.follower_uid::text, coalesce(n.skip_reason, n.status)) INTO r
    FROM public.exos_follower_notices n WHERE n.event_id = pg_temp.u('a1');
  ASSERT r = jsonb_build_object(pg_temp.u('f1')::text, 'queued', pg_temp.u('f2')::text, 'opted_out',
                                pg_temp.u('f3')::text, 'org_unsubscribed', pg_temp.u('f4')::text, 'no_email',
                                pg_temp.u('ma')::text, 'org_staff'), 'NB2 reasons ' || r;
  SELECT * INTO m FROM public.exos_mail WHERE template = 'follower-new-event' AND to_email = 'nb-f1@x.com';
  ASSERT m.status = 'pending', 'NB2 queued, not sent';
  ASSERT (m.payload ->> 'marketing')::boolean AND m.payload ->> 'unsubscribe_token' ~ '^[0-9a-f]{64}$'
     AND m.list_unsubscribe LIKE '{{app_url}}/unsubscribe?t=%', 'NB2 marketing: unsubscribe link + header';
  ASSERT m.payload ->> 'unfollow_token' = (SELECT token FROM public.exos_follow_tokens WHERE org_id = pg_temp.u('A') AND follower_uid = pg_temp.u('f1')),
    'NB2 the unfollow token';
  ASSERT m.payload -> 'org' ->> 'name' = 'NB Hall <A>' AND jsonb_array_length(m.payload -> 'events') = 1
     AND m.payload -> 'events' -> 0 ->> 'id' = pg_temp.u('a1')::text, 'NB2 payload: the org and the event';
  ASSERT position('nb-f2@x.com' IN m.payload::text) = 0 AND position('nb-oa@x.com' IN m.payload::text) = 0, 'NB2 no other addresses';

  -- After: the organizer's counts.
  PERFORM pg_temp.act(pg_temp.u('oa'));
  r := public.exos_event_follower_notice(pg_temp.u('a1'));
  ASSERT r ->> 'state' = 'after' AND (r ->> 'notified')::int = 1 AND (r ->> 'waiting')::int = 0
     AND (r ->> 'not_notified')::int = 4, 'NB2 after: notified 1 ' || r;

  -- Republish (draft, then live again) and the announce RPC: nothing new.
  UPDATE public.exos_events SET status = 'draft' WHERE id = pg_temp.u('a1');
  PERFORM pg_temp.publish('a1');
  ASSERT public.exos_announce_to_followers(pg_temp.u('a1')) = 0, 'NB2 announce again: nobody new';
  ASSERT pg_temp.mails('nb-f1@x.com') = 1, 'NB2 republish never re-sends';
  ASSERT (SELECT count(*) FROM public.exos_follower_notices WHERE event_id = pg_temp.u('a1')) = 5, 'NB2 one notice per follower';

  -- Within 24 hours: a2 and a3 wait, no mail.
  PERFORM pg_temp.publish('a2');
  PERFORM pg_temp.publish('a3');
  ASSERT pg_temp.mails('nb-f1@x.com') = 1, 'NB2 24-hour limit';
  ASSERT (SELECT count(*) FROM public.exos_follower_notices
           WHERE follower_uid = pg_temp.u('f1') AND event_id IN (pg_temp.u('a2'), pg_temp.u('a3')) AND status = 'pending') = 2, 'NB2 waiting';
  r := public.exos_event_follower_notice(pg_temp.u('a2'));
  ASSERT (r ->> 'waiting')::int = 1 AND (r ->> 'notified')::int = 0, 'NB2 a2: 1 waiting ' || r;

  -- Not announced: hidden, a later series date, a past event.
  PERFORM pg_temp.publish('ah');
  PERFORM pg_temp.publish('as');
  PERFORM pg_temp.publish('ap');
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_follower_notices WHERE event_id IN (pg_temp.u('ah'), pg_temp.u('as'), pg_temp.u('ap'))),
    'NB2 hidden / series date / past: no notices';

  -- Org B is its own window: f1 gets B's mail now, and it names only B.
  PERFORM pg_temp.act(NULL);
  UPDATE public.exos_events SET status = 'published' WHERE id = pg_temp.u('b1');
  ASSERT pg_temp.mails('nb-f1@x.com') = 2, 'NB2 another org has its own window';
  SELECT * INTO m FROM public.exos_mail WHERE template = 'follower-new-event' AND to_email = 'nb-f1@x.com' AND payload -> 'org' ->> 'id' = pg_temp.u('B')::text;
  ASSERT position(pg_temp.u('A')::text IN m.payload::text) = 0 AND position('NB A' IN m.payload::text) = 0, 'NB2 B''s mail says nothing of A';

  -- The sweep does nothing inside the window; after it, one mail with both.
  ASSERT public.exos_send_follower_digests() = 0, 'NB2 sweep inside the window';
  UPDATE public.exos_follower_mail_slots SET last_mail_at = now() - interval '25 hours'
   WHERE org_id = pg_temp.u('A') AND follower_uid = pg_temp.u('f1');
  -- Hidden -> listed counts as going live: ah joins the batch.
  UPDATE public.exos_events SET noindex = false WHERE id = pg_temp.u('ah');
  ASSERT pg_temp.mails('nb-f1@x.com') = 3, 'NB2 after the window: one more mail';
  SELECT * INTO m FROM public.exos_mail WHERE template = 'follower-new-event' AND to_email = 'nb-f1@x.com'
   ORDER BY created_at DESC, (payload -> 'events' -> 0 ->> 'starts_at') DESC LIMIT 1;
  SELECT count(*) INTO n FROM public.exos_mail WHERE template = 'follower-new-event' AND to_email = 'nb-f1@x.com'
   AND jsonb_array_length(payload -> 'events') = 3;
  ASSERT n = 1, 'NB2 batched: a2, a3 and ah in one mail';
  ASSERT public.exos_send_follower_digests() = 0, 'NB2 nothing left';
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_follower_notices WHERE follower_uid = pg_temp.u('f1') AND status = 'pending'), 'NB2 none waiting';

  -- The sweep sends what waits once the window has passed.
  UPDATE public.exos_events SET status = 'draft' WHERE id = pg_temp.u('a3');
  INSERT INTO public.exos_events (id, org_id, name, slug, status, starts_at, timezone, total_tickets, tickets_sold, currency, created_by)
  VALUES (pg_temp.u('a4'), pg_temp.u('A'), 'NB A Four', 'nb-a4', 'published', now() + interval '4 days', 'America/New_York', 0, 0, 'usd', pg_temp.u('oa'));
  ASSERT (SELECT status FROM public.exos_follower_notices WHERE event_id = pg_temp.u('a4') AND follower_uid = pg_temp.u('f1')) = 'pending',
    'NB2 a4 (inserted live) waits';
  UPDATE public.exos_follower_mail_slots SET last_mail_at = now() - interval '25 hours'
   WHERE org_id = pg_temp.u('A') AND follower_uid = pg_temp.u('f1');
  ASSERT public.exos_send_follower_digests() = 1 AND pg_temp.mails('nb-f1@x.com') = 4, 'NB2 the sweep sends it';
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_mail WHERE template = 'follower-new-event' AND status <> 'pending'), 'NB2 nothing sent anywhere';
  RAISE NOTICE 'OK  NB2 consent gating, once per event + follower, 24-hour limit + batching, hidden / series / past skipped, cross-org';
END $$;

-- NB3 -------------------------------------------------------------------------
DO $$
DECLARE r jsonb; s text;
BEGIN
  PERFORM pg_temp.act(pg_temp.u('oa'));
  r := public.exos_org_followers(pg_temp.u('A'));
  -- f1 and f3 have fan profiles; f2, f4 and ma are a count only.
  ASSERT (r ->> 'total')::int = 5 AND (r ->> 'listed')::int = 2 AND (r ->> 'not_listed')::int = 3
     AND (r ->> 'gets_new_event_mail')::int = 1, 'NB3 counts ' || (r - 'rows');
  ASSERT (SELECT array_agg(x ->> 'email' ORDER BY x ->> 'email') FROM jsonb_array_elements(r -> 'rows') x) = ARRAY['nb-f1@x.com', 'nb-f3@x.com'],
    'NB3 rows are fans';
  ASSERT (SELECT x ->> 'email_list' FROM jsonb_array_elements(r -> 'rows') x WHERE x ->> 'email' = 'nb-f3@x.com') = 'unsubscribed'
     AND NOT (SELECT (x ->> 'gets_new_event_mail')::boolean FROM jsonb_array_elements(r -> 'rows') x WHERE x ->> 'email' = 'nb-f3@x.com'),
    'NB3 consent shown';
  s := r::text;
  ASSERT position('nb-f2@x.com' IN s) = 0 AND position('nb-ma@x.com' IN s) = 0 AND position(pg_temp.u('f2')::text IN s) = 0,
    'NB3 non-fan followers never named';
  ASSERT jsonb_array_length(public.exos_org_followers(pg_temp.u('A'), 1, 1) -> 'rows') = 1, 'NB3 paging';

  r := public.exos_org_followers_export(pg_temp.u('A'));
  ASSERT (r ->> 'count')::int = 2 AND NOT (r -> 'rows' -> 0) ? 'fan_id', 'NB3 export rows';
  ASSERT position('nb-f2@x.com' IN r::text) = 0, 'NB3 export: fans only';
  ASSERT (SELECT count(*) FROM public.exos_org_audit a WHERE a.org_id = pg_temp.u('A') AND a.action = 'export.run'
           AND a.entity_id = 'followers' AND a.actor_uid = pg_temp.u('oa') AND (a.changes -> 'row_count' ->> 1)::int = 2) = 1,
    'NB3 export.run logged';
  PERFORM public.exos_org_followers_export(pg_temp.u('A'));
  PERFORM public.exos_org_followers_export(pg_temp.u('A'));
  ASSERT pg_temp.st($q$SELECT public.exos_org_followers_export(md5('nb:A')::uuid)$q$) = '54000', 'NB3 3 a minute';

  PERFORM pg_temp.act(pg_temp.u('ma'));
  ASSERT (public.exos_org_followers(pg_temp.u('A')) ->> 'total')::int = 5, 'NB3 manager reads';
  FOREACH s IN ARRAY ARRAY['fa', 'ca', 'f1', 'ob'] LOOP
    PERFORM pg_temp.act(pg_temp.u(s));
    ASSERT pg_temp.st($q$SELECT public.exos_org_followers(md5('nb:A')::uuid)$q$) = '42501', 'NB3 refused: ' || s;
    ASSERT pg_temp.st($q$SELECT public.exos_org_followers_export(md5('nb:A')::uuid)$q$) = '42501', 'NB3 export refused: ' || s;
  END LOOP;
  PERFORM pg_temp.act(pg_temp.u('ob'));
  r := public.exos_org_followers(pg_temp.u('B'));
  ASSERT (r ->> 'total')::int = 1 AND (r ->> 'listed')::int = 0 AND jsonb_array_length(r -> 'rows') = 0,
    'NB3 B: f1 is not B''s fan, so a count only';
  PERFORM pg_temp.act(NULL);
  RAISE NOTICE 'OK  NB3 follower list: fans only, counts, export logged + rate limited, roles, cross-org';
END $$;

-- NB4 -------------------------------------------------------------------------
DO $$
DECLARE v_tok text; r jsonb; v_cnt int;
BEGIN
  SELECT token INTO v_tok FROM public.exos_follow_tokens WHERE org_id = pg_temp.u('A') AND follower_uid = pg_temp.u('f1');
  SELECT followers_count INTO v_cnt FROM public.exos_orgs WHERE id = pg_temp.u('A');
  -- Something waiting when they unfollow.
  INSERT INTO public.exos_events (id, org_id, name, slug, status, starts_at, timezone, total_tickets, tickets_sold, currency, created_by)
  VALUES (pg_temp.u('a5'), pg_temp.u('A'), 'NB A Five', 'nb-a5', 'published', now() + interval '4 days', 'America/New_York', 0, 0, 'usd', pg_temp.u('oa'));
  ASSERT (SELECT status FROM public.exos_follower_notices WHERE event_id = pg_temp.u('a5') AND follower_uid = pg_temp.u('f1')) = 'pending', 'NB4 waiting';
  PERFORM pg_temp.act(NULL);
  SET LOCAL ROLE anon;
  ASSERT public.exos_unfollow_by_token('nope') = '{"ok": false}'::jsonb, 'NB4 bad token';
  ASSERT public.exos_unfollow_by_token(repeat('0', 64)) = '{"ok": false}'::jsonb, 'NB4 unknown token';
  r := public.exos_unfollow_by_token(v_tok);
  RESET ROLE;
  ASSERT r = jsonb_build_object('ok', true, 'org_name', 'NB Hall <A>'), 'NB4 unfollowed: org name only ' || r;
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_org_follows WHERE org_id = pg_temp.u('A') AND follower_uid = pg_temp.u('f1')), 'NB4 follow gone';
  ASSERT EXISTS (SELECT 1 FROM public.exos_org_follows WHERE org_id = pg_temp.u('B') AND follower_uid = pg_temp.u('f1')), 'NB4 B untouched';
  ASSERT (SELECT followers_count FROM public.exos_orgs WHERE id = pg_temp.u('A')) = v_cnt - 1, 'NB4 count down by one';
  ASSERT (SELECT skip_reason FROM public.exos_follower_notices WHERE event_id = pg_temp.u('a5') AND follower_uid = pg_temp.u('f1')) = 'not_following',
    'NB4 waiting notice dropped';
  ASSERT public.exos_unfollow_by_token(v_tok) ->> 'ok' = 'true'
     AND (SELECT followers_count FROM public.exos_orgs WHERE id = pg_temp.u('A')) = v_cnt - 1, 'NB4 twice: still one';
  UPDATE public.exos_follower_mail_slots SET last_mail_at = now() - interval '25 hours'
   WHERE org_id = pg_temp.u('A') AND follower_uid = pg_temp.u('f1');
  INSERT INTO public.exos_events (id, org_id, name, slug, status, starts_at, timezone, total_tickets, tickets_sold, currency, created_by)
  VALUES (pg_temp.u('a6'), pg_temp.u('A'), 'NB A Six', 'nb-a6', 'published', now() + interval '4 days', 'America/New_York', 0, 0, 'usd', pg_temp.u('oa'));
  ASSERT public.exos_send_follower_digests() = 0 AND pg_temp.mails('nb-f1@x.com') = 4
     AND NOT EXISTS (SELECT 1 FROM public.exos_follower_notices WHERE event_id = pg_temp.u('a6') AND follower_uid = pg_temp.u('f1')),
    'NB4 no mail after unfollowing';
  RAISE NOTICE 'OK  NB4 unfollow by token: once, count right, waiting dropped, nothing after';
END $$;

ROLLBACK;
