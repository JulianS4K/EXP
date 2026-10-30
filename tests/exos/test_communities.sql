-- ============================================================================
-- Communities + ActivityPub federation (mig 20261031200000).
--   C1  grants: tables closed to anon, RPC-only writes, service-only helpers
--   C2  create / update: owner or manager only, slug rules, cross-org refused
--   C3  join modes: open, approval (decide), invite (token, email-bound, uses)
--   C4  remove / ban / unban; banned can't rejoin or accept a host invite
--   C5  hosts: invite, accept (email must match), post, add own-org events
--       only, propose draft events, revoke
--   C6  posts: rate limits (10 / author / day), notify budget (3 / day),
--       mail fan-out to opted-in confirmed members, members-only visibility
--   C7  texts: need the org SMS opt-in; STOP'd numbers aren't queued
--   C8  members-only / early access: checkout gate, ticket trigger, staff and
--       server bypass, membership rule fails closed without memberships
--   C9  reports: once per post, 10 a day, resolve with ban
--   C10 directory by city, unlisted hidden, cross-org isolation (RLS + RPCs)
--   C11 federation: lookup, keys in Vault, follow → Accept, enqueue, claim /
--       backoff / dead, replies queued for moderation, block, Delete
--   C12 publishing an event in a community announces it once
-- Self-contained ids c7…; runs after the full run_p0.sh chain.
-- ============================================================================
\set ON_ERROR_STOP on
BEGIN;

CREATE FUNCTION pg_temp.u(p text) RETURNS uuid LANGUAGE sql IMMUTABLE AS $$ SELECT ('c7000000-0000-0000-0000-' || p)::uuid $$;
CREATE FUNCTION pg_temp.act(p_uid text) RETURNS void LANGUAGE sql AS $$
  SELECT set_config('app.uid', coalesce(p_uid, ''), true), set_config('app.jwt', '', true);
$$;
CREATE FUNCTION pg_temp.as_u(p text) RETURNS void LANGUAGE sql AS $$
  SELECT set_config('app.uid', ('c7000000-0000-0000-0000-' || p), true), set_config('app.jwt', '', true);
$$;
CREATE FUNCTION pg_temp.refused(p_sql text, p_like text) RETURNS boolean LANGUAGE plpgsql AS $$
BEGIN
  EXECUTE p_sql;
  RETURN false;
EXCEPTION WHEN others THEN
  IF SQLERRM NOT LIKE '%' || p_like || '%' THEN
    RAISE EXCEPTION 'expected "%", got % "%"', p_like, SQLSTATE, SQLERRM;
  END IF;
  RETURN true;
END $$;
CREATE FUNCTION pg_temp.ok(p_cond boolean, p_label text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  IF p_cond IS NOT TRUE THEN RAISE EXCEPTION 'FAILED: %', p_label; END IF;
  RAISE NOTICE 'OK  %', p_label;
END $$;
GRANT EXECUTE ON FUNCTION pg_temp.u(text), pg_temp.act(text), pg_temp.as_u(text), pg_temp.refused(text, text),
                         pg_temp.ok(boolean, text) TO anon, authenticated, service_role;
CREATE TEMP TABLE consent AS SELECT 'Email me when this community adds an event or posts news. Unsubscribe any time.'::text AS t,
  'Text me about SM events. Up to 8 msgs/mo. Msg & data rates may apply. Reply STOP to cancel, HELP for help.'::text AS sms;
GRANT SELECT ON consent TO anon, authenticated, service_role;
CREATE TEMP TABLE st (k text PRIMARY KEY, v text);
GRANT ALL ON st TO anon, authenticated, service_role;

-- Fixtures ---------------------------------------------------------------
INSERT INTO auth.users(id, email, email_confirmed_at) VALUES
  (pg_temp.u('0000000000a1'), 'cown@x.com', now()),   -- owner, org 1
  (pg_temp.u('0000000000a2'), 'cman@x.com', now()),   -- manager, org 1
  (pg_temp.u('0000000000a3'), 'ccon@x.com', now()),   -- content, org 1
  (pg_temp.u('0000000000a4'), 'cscan@x.com', now()),  -- scanner, org 1
  (pg_temp.u('0000000000b1'), 'bown@x.com', now()),   -- owner, org 2 (other org)
  (pg_temp.u('0000000000aa'), 'host@x.com', now()),   -- run club owner (org 3), host in org 1's community
  (pg_temp.u('0000000000d1'), 'm1@x.com', now()),
  (pg_temp.u('0000000000d2'), 'm2@x.com', now()),
  (pg_temp.u('0000000000d3'), 'm3@x.com', NULL),      -- unconfirmed email
  (pg_temp.u('0000000000d4'), 'm4@x.com', now()),
  (pg_temp.u('0000000000d5'), 'm5@x.com', now()),
  (pg_temp.u('0000000000d6'), 'm6@x.com', now()),
  (pg_temp.u('0000000000e9'), 'stranger@x.com', now());
INSERT INTO public.exos_orgs(id, name, slug, owner_uid) VALUES
  (pg_temp.u('000000000001'), 'Corner Bar', 'corner-bar', pg_temp.u('0000000000a1')),
  (pg_temp.u('000000000002'), 'Other Org', 'other-org-c7', pg_temp.u('0000000000b1')),
  (pg_temp.u('000000000003'), 'Run Club', 'run-club-c7', pg_temp.u('0000000000aa'));
INSERT INTO public.exos_org_memberships(org_id, user_id, role) VALUES
  (pg_temp.u('000000000001'), pg_temp.u('0000000000a1'), 'owner'),
  (pg_temp.u('000000000001'), pg_temp.u('0000000000a2'), 'manager'),
  (pg_temp.u('000000000001'), pg_temp.u('0000000000a3'), 'content'),
  (pg_temp.u('000000000001'), pg_temp.u('0000000000a4'), 'scanner'),
  (pg_temp.u('000000000002'), pg_temp.u('0000000000b1'), 'owner'),
  (pg_temp.u('000000000003'), pg_temp.u('0000000000aa'), 'owner');
INSERT INTO public.exos_events(id, org_id, name, slug, status, starts_at, timezone, total_tickets, created_by) VALUES
  (pg_temp.u('0000000000f1'), pg_temp.u('000000000001'), 'Trivia Night', 'c7-trivia', 'published', now() + interval '5 days', 'America/New_York', 100, pg_temp.u('0000000000a1')),
  (pg_temp.u('0000000000f2'), pg_temp.u('000000000001'), 'Members Mixer', 'c7-mixer', 'published', now() + interval '6 days', 'America/New_York', 100, pg_temp.u('0000000000a1')),
  (pg_temp.u('0000000000f3'), pg_temp.u('000000000003'), 'Saturday 5K', 'c7-5k', 'published', now() + interval '3 days', 'America/New_York', 100, pg_temp.u('0000000000aa')),
  (pg_temp.u('0000000000f4'), pg_temp.u('000000000002'), 'Other Show', 'c7-other', 'published', now() + interval '3 days', 'America/New_York', 100, pg_temp.u('0000000000b1')),
  (pg_temp.u('0000000000f5'), pg_temp.u('000000000001'), 'Draft Gig', 'c7-draft', 'draft', now() + interval '9 days', 'America/New_York', 100, pg_temp.u('0000000000a1')),
  (pg_temp.u('0000000000f6'), pg_temp.u('000000000001'), 'Old Quiz', 'c7-old', 'published', now() - interval '20 days', 'America/New_York', 100, pg_temp.u('0000000000a1'));
INSERT INTO public.exos_ticket_tiers(id, event_id, name, price, capacity, visibility) VALUES
  (pg_temp.u('0000000000cc'), pg_temp.u('0000000000f2'), 'GA', 0, 100, 'public');

-- C1 ----------------------------------------------------------------------
SET LOCAL ROLE anon;
SELECT pg_temp.act(NULL);
SELECT pg_temp.ok(pg_temp.refused($$SELECT count(*) FROM public.exos_communities$$, 'permission denied'), 'C1 anon cannot read the communities table');
SELECT pg_temp.ok(pg_temp.refused($$SELECT public.exos_community_join(pg_temp.u('000000000c01'))$$, 'permission denied'), 'C1 anon cannot join');
SELECT pg_temp.ok(pg_temp.refused($$SELECT public.exos_ap_lookup('x_y_z')$$, 'permission denied'), 'C1 anon cannot call federation RPCs');
SELECT pg_temp.ok(public.exos_public_community('nope') IS NULL, 'C1 anon reads the public page RPC (unknown slug = NULL)');
RESET ROLE;
SET LOCAL ROLE authenticated;
SELECT pg_temp.as_u('0000000000a1');
SELECT pg_temp.ok(pg_temp.refused($$INSERT INTO public.exos_communities(org_id, slug, name) VALUES (pg_temp.u('000000000001'), 'direct', 'x')$$, 'permission denied'), 'C1 no direct inserts');
SELECT pg_temp.ok(pg_temp.refused($$SELECT public.exos_ap_signing_key(gen_random_uuid())$$, 'permission denied'), 'C1 signing key is service role only');
SELECT pg_temp.ok(pg_temp.refused($$SELECT public.exos_community_checkout_gate(gen_random_uuid(), gen_random_uuid())$$, 'permission denied'), 'C1 checkout gate is service role only');
SELECT pg_temp.ok(pg_temp.refused($$SELECT token_hash FROM public.exos_community_invites$$, 'permission denied'), 'C1 invite token hashes are not readable');
RESET ROLE;
DO $$
BEGIN
  PERFORM pg_temp.ok(NOT has_table_privilege('authenticated', 'public.exos_ap_actors', 'SELECT')
                 AND NOT has_table_privilege('authenticated', 'public.exos_ap_deliveries', 'SELECT')
                 AND NOT has_table_privilege('anon', 'public.exos_ap_followers', 'SELECT'), 'C1 federation tables have no client grants');
  PERFORM pg_temp.ok((SELECT bool_and(c.relrowsecurity) FROM pg_class c
                       WHERE c.relname IN ('exos_communities','exos_community_hosts','exos_community_members','exos_community_invites',
                         'exos_community_events','exos_community_posts','exos_community_reports','exos_ap_actors','exos_ap_followers',
                         'exos_ap_blocks','exos_ap_remote_replies','exos_ap_deliveries','exos_ap_remote_actors')), 'C1 RLS on all thirteen tables');
END $$;

-- C2 ----------------------------------------------------------------------
SET LOCAL ROLE authenticated;
SELECT pg_temp.as_u('0000000000a1');
INSERT INTO st SELECT 'c1', (public.exos_community_save(pg_temp.u('000000000001'), NULL,
  '{"slug":"bar-run-club","name":"Bar Run Club","tagline":"Run, then a pint","city":"Brooklyn","country":"US","join_mode":"open"}'))->>'id';
INSERT INTO st SELECT 'c2', (public.exos_community_save(pg_temp.u('000000000001'), NULL,
  '{"slug":"vip-circle","name":"VIP Circle","city":"Brooklyn","join_mode":"approval"}'))->>'id';
INSERT INTO st SELECT 'c3', (public.exos_community_save(pg_temp.u('000000000001'), NULL,
  '{"slug":"inner_room","name":"Inner Room","city":"Queens","join_mode":"invite"}'))->>'id';
SELECT pg_temp.ok(pg_temp.refused($$SELECT public.exos_community_save(pg_temp.u('000000000001'), NULL, '{"slug":"bar_run_club","name":"dup"}')$$, 'taken'), 'C2 slug that collides on ap_name is taken');
SELECT pg_temp.ok(pg_temp.refused($$SELECT public.exos_community_save(pg_temp.u('000000000001'), NULL, '{"slug":"org_bar","name":"x"}')$$, 'link name'), 'C2 org_ prefix is reserved');
SELECT pg_temp.ok(pg_temp.refused($$SELECT public.exos_community_save(pg_temp.u('000000000001'), NULL, '{"slug":"A!","name":"x"}')$$, 'link name'), 'C2 bad slug refused');
SELECT pg_temp.ok(pg_temp.refused($$SELECT public.exos_community_save(pg_temp.u('000000000001'), (SELECT v::uuid FROM st WHERE k='c1'), '{"banner_url":"javascript:alert(1)"}')$$, 'exos_community_save'), 'C2 non-https banner refused');
SELECT pg_temp.as_u('0000000000a3');
SELECT pg_temp.ok(pg_temp.refused($$SELECT public.exos_community_save(pg_temp.u('000000000001'), NULL, '{"slug":"content-made","name":"x"}')$$, 'owner or manager'), 'C2 content role cannot create');
SELECT pg_temp.as_u('0000000000b1');
SELECT pg_temp.ok(pg_temp.refused($$SELECT public.exos_community_save(pg_temp.u('000000000001'), (SELECT v::uuid FROM st WHERE k='c1'), '{"name":"Hijacked"}')$$, 'owner or manager'), 'C2 another org''s owner cannot edit');
SELECT pg_temp.ok(pg_temp.refused($$SELECT public.exos_community_save(pg_temp.u('000000000002'), (SELECT v::uuid FROM st WHERE k='c1'), '{"name":"Hijacked"}')$$, 'owner or manager'), 'C2 passing your own org id does not help');
SELECT pg_temp.as_u('0000000000a2');
SELECT public.exos_community_save(pg_temp.u('000000000001'), (SELECT v::uuid FROM st WHERE k='c1'), '{"about":"We run 5K on Saturdays.","federation_enabled":true}');
RESET ROLE;
SELECT pg_temp.ok((SELECT about = 'We run 5K on Saturdays.' AND federation_enabled AND ap_name = 'bar_run_club'
                     FROM public.exos_communities WHERE slug = 'bar-run-club'), 'C2 manager updates; ap_name derived');

-- C3 ----------------------------------------------------------------------
SET LOCAL ROLE authenticated;
SELECT pg_temp.as_u('0000000000d1');
SELECT pg_temp.ok((public.exos_community_join((SELECT v::uuid FROM st WHERE k='c1'), true, false, (SELECT t FROM consent)))->>'status' = 'active', 'C3 open: joins at once');
SELECT pg_temp.ok((public.exos_community_join((SELECT v::uuid FROM st WHERE k='c1'), true, false, (SELECT t FROM consent)))->>'status' = 'active', 'C3 join again is a no-op');
SELECT pg_temp.ok(pg_temp.refused($$SELECT public.exos_community_join((SELECT v::uuid FROM st WHERE k='c2'), true, false, 'ok')$$, 'consent'), 'C3 a channel needs the consent text');
SELECT pg_temp.ok(pg_temp.refused($$SELECT public.exos_community_join((SELECT v::uuid FROM st WHERE k='c2'), false, true, (SELECT t FROM consent))$$, 'texts first'), 'C3 texts need the org SMS opt-in');
SELECT pg_temp.ok((public.exos_community_join((SELECT v::uuid FROM st WHERE k='c2'), false, false))->>'status' = 'pending', 'C3 approval: pending');
SELECT pg_temp.ok(pg_temp.refused($$SELECT public.exos_community_join((SELECT v::uuid FROM st WHERE k='c3'))$$, 'invite only'), 'C3 invite-only refuses without a token');
SELECT pg_temp.ok(pg_temp.refused($$SELECT public.exos_community_decide((SELECT v::uuid FROM st WHERE k='c2'), pg_temp.u('0000000000d1'), true)$$, 'owner or manager'), 'C3 a member cannot approve');
SELECT pg_temp.as_u('0000000000a1');
SELECT pg_temp.ok(public.exos_community_decide((SELECT v::uuid FROM st WHERE k='c2'), pg_temp.u('0000000000d1'), true) = 'active', 'C3 owner approves');
INSERT INTO st SELECT 'inv_any', (public.exos_community_invite((SELECT v::uuid FROM st WHERE k='c3'), NULL, 2))->>'token';
INSERT INTO st SELECT 'inv_m4', (public.exos_community_invite((SELECT v::uuid FROM st WHERE k='c3'), 'M4@x.com'))->>'token';
SELECT pg_temp.as_u('0000000000d2');
SELECT pg_temp.ok(pg_temp.refused($$SELECT public.exos_community_join((SELECT v::uuid FROM st WHERE k='c3'), false, false, NULL, (SELECT v FROM st WHERE k='inv_m4'))$$, 'email the invite'), 'C3 an email invite is for that email only');
SELECT pg_temp.ok((public.exos_community_join((SELECT v::uuid FROM st WHERE k='c3'), false, false, NULL, (SELECT v FROM st WHERE k='inv_any')))->>'status' = 'active', 'C3 invite token joins');
SELECT pg_temp.as_u('0000000000d4');
SELECT pg_temp.ok((public.exos_community_join((SELECT v::uuid FROM st WHERE k='c3'), false, false, NULL, (SELECT v FROM st WHERE k='inv_m4')))->>'status' = 'active', 'C3 the invited email joins');
SELECT pg_temp.as_u('0000000000d5');
SELECT public.exos_community_join((SELECT v::uuid FROM st WHERE k='c3'), false, false, NULL, (SELECT v FROM st WHERE k='inv_any'));
SELECT pg_temp.as_u('0000000000d6');
SELECT pg_temp.ok(pg_temp.refused($$SELECT public.exos_community_join((SELECT v::uuid FROM st WHERE k='c3'), false, false, NULL, (SELECT v FROM st WHERE k='inv_any'))$$, 'not valid'), 'C3 a 2-use invite stops after 2');
SELECT pg_temp.ok(pg_temp.refused($$SELECT public.exos_community_join((SELECT v::uuid FROM st WHERE k='c3'), false, false, NULL, 'ecv_' || repeat('0', 64))$$, 'not valid'), 'C3 an unknown token is refused');
SELECT pg_temp.act(NULL);
RESET ROLE;
SET LOCAL ROLE anon;
SELECT pg_temp.ok((public.exos_community_invite_preview((SELECT v FROM st WHERE k='inv_any')))->>'valid' = 'false', 'C3 anon invite preview: used up');
SELECT pg_temp.ok(public.exos_community_invite_preview('junk') IS NULL, 'C3 preview of junk is NULL');
RESET ROLE;

-- C4 ----------------------------------------------------------------------
SET LOCAL ROLE authenticated;
SELECT pg_temp.as_u('0000000000d2');
SELECT public.exos_community_join((SELECT v::uuid FROM st WHERE k='c1'), true, false, (SELECT t FROM consent));
SELECT pg_temp.as_u('0000000000a1');
SELECT pg_temp.ok(public.exos_community_remove_member((SELECT v::uuid FROM st WHERE k='c1'), pg_temp.u('0000000000d2')) = 'removed', 'C4 remove');
SELECT pg_temp.as_u('0000000000d2');
SELECT pg_temp.ok((public.exos_community_join((SELECT v::uuid FROM st WHERE k='c1'), true, false, (SELECT t FROM consent)))->>'status' = 'active', 'C4 removed member can rejoin');
SELECT pg_temp.as_u('0000000000a1');
SELECT pg_temp.ok(public.exos_community_remove_member((SELECT v::uuid FROM st WHERE k='c1'), pg_temp.u('0000000000e9'), true, 'spam') = 'banned', 'C4 pre-emptive ban');
SELECT pg_temp.ok(pg_temp.refused($$SELECT public.exos_community_remove_member((SELECT v::uuid FROM st WHERE k='c1'), pg_temp.u('0000000000a1'), true)$$, 'yourself'), 'C4 cannot ban yourself');
SELECT pg_temp.as_u('0000000000e9');
SELECT pg_temp.ok(pg_temp.refused($$SELECT public.exos_community_join((SELECT v::uuid FROM st WHERE k='c1'))$$, 'can''t join'), 'C4 banned cannot rejoin');
SELECT pg_temp.as_u('0000000000a1');
SELECT pg_temp.ok(public.exos_community_unban((SELECT v::uuid FROM st WHERE k='c1'), pg_temp.u('0000000000e9')), 'C4 unban');
SELECT public.exos_community_remove_member((SELECT v::uuid FROM st WHERE k='c1'), pg_temp.u('0000000000e9'), true, 'again');
RESET ROLE;

-- C5 ----------------------------------------------------------------------
SET LOCAL ROLE authenticated;
SELECT pg_temp.as_u('0000000000a1');
INSERT INTO st SELECT 'host_tok', (public.exos_community_host_invite((SELECT v::uuid FROM st WHERE k='c1'), 'host@x.com', 'Run Club', pg_temp.u('000000000003')))->>'token';
INSERT INTO st SELECT 'host_tok2', (public.exos_community_host_invite((SELECT v::uuid FROM st WHERE k='c1'), 'stranger@x.com', 'Banned Host'))->>'token';
SELECT pg_temp.as_u('0000000000d1');
SELECT pg_temp.ok(pg_temp.refused($$SELECT public.exos_community_host_accept((SELECT v FROM st WHERE k='host_tok'))$$, 'email the invite'), 'C5 host invite needs the invited email');
SELECT pg_temp.ok(pg_temp.refused($$SELECT public.exos_community_post((SELECT v::uuid FROM st WHERE k='c1'), NULL, 'member post')$$, 'organizer and hosts'), 'C5 members cannot post');
SELECT pg_temp.as_u('0000000000e9');
SELECT pg_temp.ok(pg_temp.refused($$SELECT public.exos_community_host_accept((SELECT v FROM st WHERE k='host_tok2'))$$, 'not valid'), 'C5 a banned person cannot become host');
SELECT pg_temp.as_u('0000000000aa');
SELECT public.exos_community_host_accept((SELECT v FROM st WHERE k='host_tok'));
SELECT pg_temp.ok(pg_temp.refused($$SELECT public.exos_community_host_accept((SELECT v FROM st WHERE k='host_tok'))$$, 'not valid'), 'C5 host token is single use');
SELECT pg_temp.ok(((public.exos_community_add_event((SELECT v::uuid FROM st WHERE k='c1'), pg_temp.u('0000000000f3')))->>'added')::boolean, 'C5 host adds their own org''s event');
SELECT pg_temp.ok(pg_temp.refused($$SELECT public.exos_community_add_event((SELECT v::uuid FROM st WHERE k='c1'), pg_temp.u('0000000000f1'))$$, 'own events'), 'C5 host cannot add the org''s events');
SELECT pg_temp.ok(pg_temp.refused($$SELECT public.exos_community_add_event((SELECT v::uuid FROM st WHERE k='c1'), pg_temp.u('0000000000f4'))$$, 'own events'), 'C5 host cannot add a third org''s event');
SELECT pg_temp.ok(pg_temp.refused($$SELECT public.exos_community_add_event((SELECT v::uuid FROM st WHERE k='c2'), pg_temp.u('0000000000f3'))$$, 'own events'), 'C5 host role is per community');
INSERT INTO st SELECT 'host_post', (public.exos_community_post((SELECT v::uuid FROM st WHERE k='c1'), 'Route change', 'We start at the bar now.'))->>'id';
INSERT INTO st SELECT 'draft_ev', public.exos_community_host_create_event((SELECT v::uuid FROM st WHERE k='c1'), 'Hill Repeats', now() + interval '10 days', 'America/New_York', 'Corner Bar');
SELECT pg_temp.ok(pg_temp.refused($$SELECT public.exos_community_moderate_post((SELECT v::uuid FROM st WHERE k='host_post'), 'restore')$$, 'owner or manager'), 'C5 host cannot restore');
SELECT pg_temp.ok(pg_temp.refused($$SELECT public.exos_community_admin((SELECT v::uuid FROM st WHERE k='c1'))$$, 'owner or manager'), 'C5 host cannot open the admin panel');
SELECT pg_temp.ok(pg_temp.refused($$SELECT public.exos_community_member_list((SELECT v::uuid FROM st WHERE k='c1'))$$, 'owner or manager'), 'C5 host cannot list members');
RESET ROLE;
SELECT pg_temp.ok((SELECT status = 'draft' AND org_id = pg_temp.u('000000000001') FROM public.exos_events WHERE id = (SELECT v::uuid FROM st WHERE k='draft_ev')),
                  'C5 host proposal is a draft in the community''s org');
SELECT pg_temp.ok((SELECT announced_at IS NOT NULL FROM public.exos_community_events WHERE event_id = pg_temp.u('0000000000f3')), 'C5 a published event is announced when added');
SELECT pg_temp.ok((SELECT announced_at IS NULL FROM public.exos_community_events WHERE event_id = (SELECT v::uuid FROM st WHERE k='draft_ev')), 'C5 a draft is not announced');

-- C6 ----------------------------------------------------------------------
-- d1 (email on, confirmed), d2 (email on), d3 (email on, unconfirmed) are members of c1.
SET LOCAL ROLE authenticated;
SELECT pg_temp.as_u('0000000000d3');
SELECT public.exos_community_join((SELECT v::uuid FROM st WHERE k='c1'), true, false, (SELECT t FROM consent));
SELECT pg_temp.as_u('0000000000a1');
INSERT INTO st SELECT 'p_members', (public.exos_community_post((SELECT v::uuid FROM st WHERE k='c1'), 'Members only', 'Secret route', 'members', true))->>'id';
RESET ROLE;
SELECT pg_temp.ok((SELECT count(*) FROM public.exos_mail WHERE template = 'community-post' AND payload->'post'->>'id' = (SELECT v FROM st WHERE k='p_members')) = 2,
                  'C6 notify mails the 2 opted-in confirmed members (not the unconfirmed one)');
SELECT pg_temp.ok((SELECT bool_and(list_unsubscribe LIKE '{{app_url}}/unsubscribe?t=%' AND (payload->>'marketing')::boolean) FROM public.exos_mail WHERE template = 'community-post'),
                  'C6 community mail is marketing: unsubscribe link + opt-out honoured');
UPDATE public.exos_mail_prefs SET marketing_opt_out = true WHERE user_id = pg_temp.u('0000000000d2');
SET LOCAL ROLE authenticated;
SELECT pg_temp.as_u('0000000000a1');
INSERT INTO st SELECT 'p2', (public.exos_community_post((SELECT v::uuid FROM st WHERE k='c1'), NULL, 'Second', 'public', true))->>'id';
INSERT INTO st SELECT 'p3', (public.exos_community_post((SELECT v::uuid FROM st WHERE k='c1'), NULL, 'Third', 'public', true))->>'id';
INSERT INTO st SELECT 'p4', (public.exos_community_post((SELECT v::uuid FROM st WHERE k='c1'), NULL, 'Fourth', 'public', true))->>'notify_note';
RESET ROLE;
SELECT pg_temp.ok((SELECT count(*) FROM public.exos_mail WHERE template = 'community-post' AND payload->'post'->>'id' = (SELECT v FROM st WHERE k='p2')) = 1,
                  'C6 a member who opted out of marketing mail gets none');
SELECT pg_temp.ok((SELECT v FROM st WHERE k='p4') LIKE '%3 times today%', 'C6 the 4th notifying post today is not sent');
SET LOCAL ROLE authenticated;
SELECT pg_temp.as_u('0000000000a3');
DO $$ BEGIN FOR i IN 1..10 LOOP PERFORM public.exos_community_post((SELECT v::uuid FROM st WHERE k='c1'), NULL, 'spam ' || i); END LOOP; END $$;
SELECT pg_temp.ok(pg_temp.refused($$SELECT public.exos_community_post((SELECT v::uuid FROM st WHERE k='c1'), NULL, 'eleven')$$, '10 posts a day'), 'C6 10 posts a day per author');
SELECT pg_temp.as_u('0000000000d6');
SELECT pg_temp.ok(NOT (public.exos_public_community('bar-run-club')->'posts') @> jsonb_build_array(jsonb_build_object('id', (SELECT v FROM st WHERE k='p_members'))),
                  'C6 non-members do not see members-only posts');
SELECT pg_temp.as_u('0000000000d1');
SELECT pg_temp.ok((public.exos_public_community('bar-run-club')->'posts') @> jsonb_build_array(jsonb_build_object('id', (SELECT v FROM st WHERE k='p_members'))),
                  'C6 members see members-only posts');
SELECT pg_temp.ok((public.exos_public_community('bar-run-club')->'me'->>'status') = 'active', 'C6 the page knows who I am');
SELECT pg_temp.act(NULL);
RESET ROLE;
SET LOCAL ROLE anon;
SELECT pg_temp.ok((public.exos_public_community('bar-run-club')->>'member_count')::int = 3 AND public.exos_public_community('bar-run-club')->'me' = 'null'::jsonb,
                  'C6 anon sees the member count, no member list');
SELECT pg_temp.ok(jsonb_array_length(public.exos_public_community('bar-run-club')->'upcoming') = 1, 'C6 upcoming lists the published community event');
RESET ROLE;

-- C7 ----------------------------------------------------------------------
INSERT INTO public.exos_org_integrations(org_id, provider, config, status) VALUES (pg_temp.u('000000000001'), 'twilio', '{"from":"+12125550199"}', 'connected');
SET LOCAL ROLE authenticated;
SELECT pg_temp.as_u('0000000000d1');
SELECT public.exos_sms_opt_in(pg_temp.u('000000000001'), '2125550171', (SELECT sms FROM consent));
SELECT pg_temp.ok((public.exos_community_set_notify((SELECT v::uuid FROM st WHERE k='c1'), true, true, (SELECT t FROM consent)))->>'notify_sms' = 'true', 'C7 texts on after the org SMS opt-in');
SELECT pg_temp.as_u('0000000000d4');
SELECT public.exos_sms_opt_in(pg_temp.u('000000000001'), '2125550174', (SELECT sms FROM consent));
SELECT public.exos_community_join((SELECT v::uuid FROM st WHERE k='c1'), false, true, (SELECT t FROM consent));
SELECT pg_temp.as_u('0000000000a1');
RESET ROLE;
-- d4 replies STOP before the next announcement.
SELECT public.exos_sms_inbound(pg_temp.u('000000000001'), '+12125550174', 'STOP');
SET LOCAL ROLE authenticated;
SELECT pg_temp.as_u('0000000000a1');
SELECT public.exos_community_add_event((SELECT v::uuid FROM st WHERE k='c1'), pg_temp.u('0000000000f1'));
RESET ROLE;
SELECT pg_temp.ok((SELECT count(*) FROM public.exos_sms_outbox o JOIN public.exos_sms_campaigns c ON c.id = o.campaign_id
                    WHERE c.community_id = (SELECT v::uuid FROM st WHERE k='c1') AND c.event_id = pg_temp.u('0000000000f1')) = 1
                  AND (SELECT body LIKE '%Reply STOP to opt out.' FROM public.exos_sms_campaigns WHERE community_id = (SELECT v::uuid FROM st WHERE k='c1') LIMIT 1),
                  'C7 the event text goes to the subscribed member only (STOP''d number skipped), with STOP footer');
SELECT pg_temp.ok((SELECT count(*) FROM public.exos_mail WHERE template = 'community-event' AND payload->'event'->>'id' = pg_temp.u('0000000000f1')::text) = 1,
                  'C7 the event mail goes to email-opted members');

-- C8 ----------------------------------------------------------------------
SET LOCAL ROLE authenticated;
SELECT pg_temp.as_u('0000000000a1');
SELECT public.exos_community_add_event((SELECT v::uuid FROM st WHERE k='c1'), pg_temp.u('0000000000f2'), true);
SELECT pg_temp.ok(pg_temp.refused($$SELECT public.exos_community_add_event((SELECT v::uuid FROM st WHERE k='c1'), pg_temp.u('0000000000f1'), true, NULL, 'membership', ARRAY[gen_random_uuid()])$$, 'memberships are not set up'),
                  'C8 membership rule needs the memberships migration');
SELECT pg_temp.ok(pg_temp.refused($$SELECT public.exos_community_add_event((SELECT v::uuid FROM st WHERE k='c1'), pg_temp.u('0000000000f1'), false, now() + interval '30 days')$$, 'before the event'),
                  'C8 early access must end before the event');
RESET ROLE;
SET LOCAL ROLE service_role;
SELECT pg_temp.ok((public.exos_community_checkout_gate(pg_temp.u('0000000000f2'), pg_temp.u('0000000000d6')))->>'blocked' = 'true', 'C8 checkout gate blocks a non-member');
SELECT pg_temp.ok((public.exos_community_checkout_gate(pg_temp.u('0000000000f2'), NULL))->>'blocked' = 'true', 'C8 checkout gate blocks a guest');
SELECT pg_temp.ok((public.exos_community_checkout_gate(pg_temp.u('0000000000f2'), pg_temp.u('0000000000d1')))->>'blocked' = 'false', 'C8 checkout gate lets a member in');
SELECT pg_temp.ok((public.exos_community_checkout_gate(pg_temp.u('0000000000f1'), pg_temp.u('0000000000d6')))->>'gated' = 'false', 'C8 an ungated event is open');
RESET ROLE;
SET LOCAL ROLE authenticated;
SELECT pg_temp.as_u('0000000000d6');
SELECT pg_temp.ok((public.exos_public_event_communities(pg_temp.u('0000000000f2')))->'access'->>'reason' = 'members_only', 'C8 the event page explains why');
RESET ROLE;
-- Trigger fires on table writes; the harness role writes directly to test it.
SELECT pg_temp.as_u('0000000000d6');
SELECT pg_temp.ok(pg_temp.refused($$INSERT INTO public.exos_tickets(event_id, org_id, tier_id, owner_id) VALUES (pg_temp.u('0000000000f2'), pg_temp.u('000000000001'), pg_temp.u('0000000000cc'), pg_temp.u('0000000000d6'))$$, 'for members of'),
                  'C8 ticket trigger refuses any insert made for a signed-in non-member (free claims, definer paths)');
SELECT pg_temp.as_u('0000000000d1');
INSERT INTO public.exos_tickets(event_id, org_id, tier_id, owner_id) VALUES (pg_temp.u('0000000000f2'), pg_temp.u('000000000001'), pg_temp.u('0000000000cc'), pg_temp.u('0000000000d1'));
SELECT pg_temp.as_u('0000000000a4');
INSERT INTO public.exos_tickets(event_id, org_id, tier_id, owner_id) VALUES (pg_temp.u('0000000000f2'), pg_temp.u('000000000001'), pg_temp.u('0000000000cc'), pg_temp.u('0000000000d6'));
SELECT pg_temp.act(NULL);
INSERT INTO public.exos_tickets(event_id, org_id, tier_id, owner_id) VALUES (pg_temp.u('0000000000f2'), pg_temp.u('000000000001'), pg_temp.u('0000000000cc'), NULL);
SELECT pg_temp.ok((SELECT count(*) FROM public.exos_tickets WHERE event_id = pg_temp.u('0000000000f2')) = 3, 'C8 member, door staff (comp) and server path are let through');
-- Early access: open to everyone once it ends.
UPDATE public.exos_community_events SET members_only = false, early_access_until = now() + interval '1 hour' WHERE event_id = pg_temp.u('0000000000f2');
SELECT pg_temp.ok((public._exos_comm_gate(pg_temp.u('0000000000f2'), pg_temp.u('0000000000d6')))->>'reason' = 'early_access', 'C8 early access blocks non-members during the window');
UPDATE public.exos_community_events SET early_access_until = now() - interval '1 minute' WHERE event_id = pg_temp.u('0000000000f2');
SELECT pg_temp.ok((public._exos_comm_gate(pg_temp.u('0000000000f2'), pg_temp.u('0000000000d6')))->>'blocked' = 'false', 'C8 after early access everyone can buy');
-- Membership rule without the memberships migration: fails closed.
UPDATE public.exos_community_events SET members_only = true, access_rule = 'membership', membership_product_ids = ARRAY[gen_random_uuid()]
 WHERE event_id = pg_temp.u('0000000000f2');
SELECT pg_temp.ok((public._exos_comm_gate(pg_temp.u('0000000000f2'), pg_temp.u('0000000000d1')))->>'blocked' = 'true', 'C8 membership rule fails closed without memberships (community member not enough)');
UPDATE public.exos_community_events SET access_rule = 'either' WHERE event_id = pg_temp.u('0000000000f2');
SELECT pg_temp.ok((public._exos_comm_gate(pg_temp.u('0000000000f2'), pg_temp.u('0000000000d1')))->>'blocked' = 'false', 'C8 "either" lets community members in');

-- C9 ----------------------------------------------------------------------
INSERT INTO st SELECT 'spam:' || substr(body, 6), id FROM public.exos_community_posts WHERE body LIKE 'spam %';
SET LOCAL ROLE authenticated;
SELECT pg_temp.as_u('0000000000d1');
SELECT public.exos_community_report((SELECT v::uuid FROM st WHERE k='host_post'), 'spam', 'ad');
SELECT public.exos_community_report((SELECT v::uuid FROM st WHERE k='host_post'), 'spam', 'twice');
SELECT pg_temp.as_u('0000000000d6');
SELECT pg_temp.ok(pg_temp.refused($$SELECT public.exos_community_report((SELECT v::uuid FROM st WHERE k='p_members'), 'spam')$$, 'not found'), 'C9 cannot report a members-only post you can''t see');
SELECT pg_temp.ok(pg_temp.refused($$SELECT public.exos_community_report((SELECT v::uuid FROM st WHERE k='host_post'), 'because')$$, 'reason'), 'C9 reason must be from the list');
DO $$ BEGIN FOR i IN 1..10 LOOP
  BEGIN PERFORM public.exos_community_report((SELECT v::uuid FROM st WHERE k = 'spam:' || i), 'spam'); END;
END LOOP; END $$;
SELECT pg_temp.ok(pg_temp.refused($$SELECT public.exos_community_report((SELECT v::uuid FROM st WHERE k='p2'), 'spam')$$, 'too many reports'), 'C9 10 reports a day');
SELECT pg_temp.as_u('0000000000a1');
SELECT public.exos_community_resolve_report((SELECT id FROM public.exos_community_reports WHERE post_id = (SELECT v::uuid FROM st WHERE k='host_post') LIMIT 1), 'ban');
RESET ROLE;
SELECT pg_temp.ok((SELECT count(*) FROM public.exos_community_reports WHERE post_id = (SELECT v::uuid FROM st WHERE k='host_post')) = 1, 'C9 one report per person per post');
SELECT pg_temp.ok((SELECT status FROM public.exos_community_posts WHERE id = (SELECT v::uuid FROM st WHERE k='host_post')) = 'removed'
              AND (SELECT status FROM public.exos_community_hosts WHERE email = 'host@x.com') = 'revoked'
              AND (SELECT status FROM public.exos_community_members WHERE community_id = (SELECT v::uuid FROM st WHERE k='c1') AND user_id = pg_temp.u('0000000000aa')) = 'banned',
                  'C9 resolve with ban: post removed, host revoked, author banned');
SET LOCAL ROLE authenticated;
SELECT pg_temp.as_u('0000000000aa');
SELECT pg_temp.ok(pg_temp.refused($$SELECT public.exos_community_post((SELECT v::uuid FROM st WHERE k='c1'), NULL, 'back?')$$, 'organizer and hosts'), 'C9 a revoked host cannot post');
RESET ROLE;

-- C10 ---------------------------------------------------------------------
SET LOCAL ROLE authenticated;
SELECT pg_temp.as_u('0000000000b1');
SELECT public.exos_community_save(pg_temp.u('000000000002'), NULL, '{"slug":"other-crew","name":"Other Crew","city":"brooklyn "}');
SELECT public.exos_community_save(pg_temp.u('000000000002'), NULL, '{"slug":"hidden-crew","name":"Hidden","city":"Brooklyn","visibility":"unlisted"}');
SELECT pg_temp.ok((SELECT count(*) FROM public.exos_communities) = 2, 'C10 RLS: an org sees only its own communities');
SELECT pg_temp.ok((SELECT count(*) FROM public.exos_community_members) = 0, 'C10 RLS: no other org''s member rows');
SELECT pg_temp.ok(pg_temp.refused($$SELECT public.exos_community_admin((SELECT v::uuid FROM st WHERE k='c1'))$$, 'owner or manager'), 'C10 admin RPC refuses another org');
SELECT pg_temp.ok(pg_temp.refused($$SELECT public.exos_community_remove_member((SELECT v::uuid FROM st WHERE k='c1'), pg_temp.u('0000000000d1'), true)$$, 'owner or manager'), 'C10 cannot ban in another org''s community');
SELECT pg_temp.ok(pg_temp.refused($$SELECT public.exos_community_add_event((SELECT v::uuid FROM st WHERE k='c1'), pg_temp.u('0000000000f4'))$$, 'own events'), 'C10 cannot add your event to another org''s community');
SELECT pg_temp.act(NULL);
RESET ROLE;
SET LOCAL ROLE anon;
SELECT pg_temp.ok((public.exos_public_communities('Brooklyn'))->>'total' = '3', 'C10 directory by city (case / space insensitive), unlisted left out');
SELECT pg_temp.ok((public.exos_public_communities('queens'))->>'total' = '1' AND (public.exos_public_communities(NULL, 'run'))->>'total' = '1', 'C10 directory city + search');
SELECT pg_temp.ok(public.exos_public_community('hidden-crew') IS NOT NULL, 'C10 unlisted page still opens by link');
SELECT pg_temp.ok((public.exos_public_communities(NULL, '%'))->>'total' = '0', 'C10 search wildcards are escaped');
RESET ROLE;

-- C11 ---------------------------------------------------------------------
SET LOCAL ROLE service_role;
SELECT pg_temp.ok(public.exos_ap_lookup('inner_room') IS NULL, 'C11 a non-federating community is not an actor');
SELECT pg_temp.ok((public.exos_ap_lookup('bar_run_club'))->>'kind' = 'community', 'C11 federating community resolves by ap_name');
SELECT pg_temp.ok((public.exos_ap_lookup('org_corner_bar'))->>'kind' = 'org' AND public.exos_ap_lookup('org_other_org_c7') IS NULL,
                  'C11 org actor only while it has a federating community');
INSERT INTO st SELECT 'actor', (public.exos_ap_store_key('community', (SELECT v::uuid FROM st WHERE k='c1'),
  E'-----BEGIN PUBLIC KEY-----\nAAA\n-----END PUBLIC KEY-----', E'-----BEGIN PRIVATE KEY-----\nSECRET1\n-----END PRIVATE KEY-----'))->>'actor_id';
SELECT pg_temp.ok((public.exos_ap_store_key('community', (SELECT v::uuid FROM st WHERE k='c1'),
  E'-----BEGIN PUBLIC KEY-----\nBBB\n-----END PUBLIC KEY-----', E'-----BEGIN PRIVATE KEY-----\nSECRET2\n-----END PRIVATE KEY-----'))->>'created' = 'false',
  'C11 second key store keeps the first key');
SELECT pg_temp.ok(public.exos_ap_signing_key((SELECT v::uuid FROM st WHERE k='actor')) LIKE '%SECRET1%', 'C11 signing key comes from Vault');
RESET ROLE;
SELECT pg_temp.ok((SELECT count(*) FROM vault.secrets WHERE name LIKE 'exos_ap_key:%') = 1
              AND NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = 'exos_ap_actors' AND column_name LIKE '%private%'),
                  'C11 one Vault secret; no private key column');
SET LOCAL ROLE service_role;
SELECT pg_temp.ok(public.exos_ap_follow((SELECT v::uuid FROM st WHERE k='c1'), 'https://lemmy.example/u/alice', 'https://lemmy.example/u/alice/inbox',
                  'https://lemmy.example/inbox', '{"id":"https://lemmy.example/activities/follow/1","type":"Follow","object":"https://exos.example/ap/c/bar_run_club"}', 'lemmy') = 'accepted',
                  'C11 Follow accepted');
SELECT public.exos_ap_follow((SELECT v::uuid FROM st WHERE k='c1'), 'https://lemmy.example/u/bob', 'https://lemmy.example/u/bob/inbox',
                  'https://lemmy.example/inbox', '{"id":"https://lemmy.example/activities/follow/2"}', 'lemmy');
SELECT public.exos_ap_follow((SELECT v::uuid FROM st WHERE k='c1'), 'https://masto.example/users/carol', 'https://masto.example/users/carol/inbox',
                  NULL, '{"id":"https://masto.example/f/3"}', 'mastodon');
SELECT pg_temp.ok(public.exos_ap_follow((SELECT v::uuid FROM st WHERE k='c3'), 'https://masto.example/users/carol', 'https://masto.example/users/carol/inbox',
                  NULL, '{"id":"https://masto.example/f/4"}') = 'not_found', 'C11 Follow of a non-federating community is refused');
SELECT pg_temp.ok((SELECT count(*) FROM public.exos_ap_deliveries WHERE kind = 'accept') = 3, 'C11 each Follow queues an Accept to the follower inbox');
RESET ROLE;
SET LOCAL ROLE authenticated;
SELECT pg_temp.as_u('0000000000a1');
INSERT INTO st SELECT 'fed_post', (public.exos_community_post((SELECT v::uuid FROM st WHERE k='c1'), 'Fed post', 'Hello fediverse'))->>'id';
SELECT public.exos_community_post((SELECT v::uuid FROM st WHERE k='c1'), NULL, 'Members news', 'members');
RESET ROLE;
SELECT pg_temp.ok((SELECT count(*) FROM public.exos_ap_deliveries WHERE kind = 'create_post' AND ref_id = (SELECT v::uuid FROM st WHERE k='fed_post')) = 2
              AND (SELECT style FROM public.exos_ap_deliveries WHERE kind = 'create_post' AND inbox_uri = 'https://lemmy.example/inbox') = 'activity'
              AND (SELECT style FROM public.exos_ap_deliveries WHERE kind = 'create_post' AND inbox_uri = 'https://masto.example/users/carol/inbox') = 'object',
                  'C11 a public post goes once per shared inbox; Lemmy-style vs Mastodon-style');
SELECT pg_temp.ok(NOT EXISTS (SELECT 1 FROM public.exos_ap_deliveries d JOIN public.exos_community_posts p ON p.id = d.ref_id WHERE p.visibility = 'members'),
                  'C11 members-only posts never federate');
SET LOCAL ROLE service_role;
SELECT pg_temp.ok((SELECT count(*) FROM public.exos_ap_claim(100)) = 5, 'C11 claim leases every due delivery');
SELECT pg_temp.ok((SELECT count(*) FROM public.exos_ap_claim(100)) = 0, 'C11 leased rows are not handed out twice');
SELECT pg_temp.ok(public.exos_ap_mark((SELECT id FROM public.exos_ap_deliveries WHERE kind = 'create_post' AND inbox_uri = 'https://lemmy.example/inbox'), true, 202) = 'sent', 'C11 mark sent');
SELECT pg_temp.ok(public.exos_ap_mark((SELECT id FROM public.exos_ap_deliveries WHERE kind = 'create_post' AND inbox_uri = 'https://masto.example/users/carol/inbox'), false, 503, 'busy') = 'queued', 'C11 5xx retries');
SELECT pg_temp.ok(public.exos_ap_mark((SELECT id FROM public.exos_ap_deliveries WHERE kind = 'accept' AND inbox_uri = 'https://lemmy.example/u/bob/inbox'), false, 410) = 'dead', 'C11 410 is final');
RESET ROLE;
SELECT pg_temp.ok((SELECT next_attempt_at > now() + interval '50 seconds' FROM public.exos_ap_deliveries WHERE kind = 'create_post' AND inbox_uri = 'https://masto.example/users/carol/inbox')
              AND (SELECT status FROM public.exos_ap_followers WHERE actor_uri = 'https://lemmy.example/u/bob') = 'removed',
                  'C11 backoff set; a gone inbox drops the follower');
UPDATE public.exos_ap_deliveries SET attempts = 8, status = 'sending' WHERE kind = 'create_post' AND inbox_uri = 'https://masto.example/users/carol/inbox';
SET LOCAL ROLE service_role;
SELECT pg_temp.ok(public.exos_ap_mark((SELECT id FROM public.exos_ap_deliveries WHERE kind = 'create_post' AND inbox_uri = 'https://masto.example/users/carol/inbox'), false, 500) = 'dead', 'C11 dead after 8 attempts');
-- Replies go to moderation.
SELECT pg_temp.ok(public.exos_ap_record_reply('post', (SELECT v::uuid FROM st WHERE k='fed_post'), 'https://masto.example/a/1', 'https://masto.example/n/1',
                  'https://masto.example/users/carol', 'Carol', '@carol@masto.example', 'Nice route!', 'https://masto.example/@carol/1') = 'queued', 'C11 reply queued');
SELECT pg_temp.ok(public.exos_ap_record_reply('post', (SELECT v::uuid FROM st WHERE k='fed_post'), 'https://masto.example/a/1', 'https://masto.example/n/1',
                  'https://masto.example/users/carol', 'Carol', '@carol@masto.example', 'Nice route!', NULL) = 'duplicate', 'C11 same reply twice is a duplicate');
SELECT pg_temp.ok(public.exos_ap_record_reply('post', (SELECT id FROM public.exos_community_posts WHERE body = 'Members news'), NULL, 'https://masto.example/n/2',
                  'https://masto.example/users/carol', 'Carol', NULL, 'peek', NULL) = 'not_found', 'C11 cannot reply to a members-only post');
RESET ROLE;
SET LOCAL ROLE anon;
SELECT pg_temp.ok(NOT (public.exos_public_community('bar-run-club')::text LIKE '%Nice route!%'), 'C11 a pending reply is not on the public page');
RESET ROLE;
INSERT INTO st SELECT 'reply1', id FROM public.exos_ap_remote_replies WHERE object_id = 'https://masto.example/n/1';
SET LOCAL ROLE authenticated;
SELECT pg_temp.as_u('0000000000a1');
SELECT pg_temp.ok(jsonb_array_length((public.exos_community_admin((SELECT v::uuid FROM st WHERE k='c1')))->'remote_replies') = 1, 'C11 the moderation queue shows it');
SELECT public.exos_community_review_reply((SELECT v::uuid FROM st WHERE k = 'reply1'), true);
SELECT pg_temp.act(NULL);
RESET ROLE;
SET LOCAL ROLE anon;
SELECT pg_temp.ok(public.exos_public_community('bar-run-club')::text LIKE '%Nice route!%', 'C11 an approved reply shows');
RESET ROLE;
SET LOCAL ROLE authenticated;
SELECT pg_temp.as_u('0000000000a1');
SELECT pg_temp.ok(public.exos_community_block_remote((SELECT v::uuid FROM st WHERE k='c1'), 'masto.example') = 1, 'C11 blocking a domain drops its followers');
RESET ROLE;
SET LOCAL ROLE service_role;
SELECT pg_temp.ok(public.exos_ap_follow((SELECT v::uuid FROM st WHERE k='c1'), 'https://sub.masto.example/users/dan', 'https://sub.masto.example/inbox', NULL, '{"id":"x"}') = 'blocked',
                  'C11 subdomains of a blocked domain are blocked');
SELECT pg_temp.ok(public.exos_ap_remote_delete('https://masto.example/users/carol', 'https://masto.example/n/1') = 1, 'C11 Delete by the author removes the reply');
SELECT pg_temp.ok(public.exos_ap_remote_delete('https://lemmy.example/u/eve', 'https://masto.example/n/1') = 0, 'C11 Delete by someone else does nothing');
SELECT pg_temp.ok(public.exos_ap_unfollow((SELECT v::uuid FROM st WHERE k='c1'), 'https://lemmy.example/u/alice'), 'C11 Undo Follow');
RESET ROLE;
-- Removing a post that already went out sends a Delete.
SELECT public.exos_ap_follow((SELECT v::uuid FROM st WHERE k='c1'), 'https://lemmy.example/u/fay', 'https://lemmy.example/u/fay/inbox', 'https://lemmy.example/inbox', '{"id":"f5"}', 'lemmy');
SET LOCAL ROLE authenticated;
SELECT pg_temp.as_u('0000000000a1');
SELECT public.exos_community_moderate_post((SELECT v::uuid FROM st WHERE k='fed_post'), 'remove');
RESET ROLE;
SELECT pg_temp.ok((SELECT count(*) FROM public.exos_ap_deliveries WHERE kind = 'delete_post' AND ref_id = (SELECT v::uuid FROM st WHERE k='fed_post')) = 1, 'C11 removing a sent post queues a Delete');
-- Turning federation off cancels what's queued.
SET LOCAL ROLE authenticated;
SELECT pg_temp.as_u('0000000000a1');
SELECT public.exos_community_save(pg_temp.u('000000000001'), (SELECT v::uuid FROM st WHERE k='c1'), '{"federation_enabled":false}');
RESET ROLE;
SELECT pg_temp.ok(NOT EXISTS (SELECT 1 FROM public.exos_ap_deliveries WHERE community_id = (SELECT v::uuid FROM st WHERE k='c1') AND status = 'queued'),
                  'C11 federation off cancels queued deliveries');

-- C12 ---------------------------------------------------------------------
SET LOCAL ROLE authenticated;
SELECT pg_temp.as_u('0000000000a1');
SELECT public.exos_community_add_event((SELECT v::uuid FROM st WHERE k='c1'), pg_temp.u('0000000000f5'));
RESET ROLE;
SELECT pg_temp.ok((SELECT announced_at IS NULL FROM public.exos_community_events WHERE event_id = pg_temp.u('0000000000f5')), 'C12 draft not announced yet');
UPDATE public.exos_events SET status = 'published' WHERE id = pg_temp.u('0000000000f5');
UPDATE public.exos_events SET status = 'draft' WHERE id = pg_temp.u('0000000000f5');
UPDATE public.exos_events SET status = 'published' WHERE id = pg_temp.u('0000000000f5');
SELECT pg_temp.ok((SELECT announced_at IS NOT NULL FROM public.exos_community_events WHERE event_id = pg_temp.u('0000000000f5'))
              AND (SELECT count(*) FROM public.exos_mail WHERE template = 'community-event' AND payload->'event'->>'id' = pg_temp.u('0000000000f5')::text) = 1,
                  'C12 publishing announces once (republish does not repeat)');
SET LOCAL ROLE anon;
SELECT pg_temp.ok(jsonb_array_length(public.exos_public_community('bar-run-club')->'past') = 0, 'C12 past list only has past events');
RESET ROLE;

ROLLBACK;
