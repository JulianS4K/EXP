-- ============================================================================
-- Discovery publishing (mig 20261029130000).
--   D1 catalog: seeded channels and kinds; authenticated reads, anon can't
--   D2 queue: owner / manager only (finance, scanner, another org refused);
--      manual channels only; upcoming published events only; idempotent
--   D3 RLS: finance + admin read the record; scanner / other org see nothing;
--      no direct writes from clients
--   D4 operator queue: admin only, across orgs, with copy-ready event + tiers
--   D5 results: submitted -> live (needs https URL) / rejected (needs reason);
--      bad moves refused; live -> removed; requeue clears the old result
--   D6 withdraw: queued -> not_submitted, then queue again
--   D7 organizer screen: channels + record + calendar verdict computed from
--      exos_calendar_public_feed (noindex event not in the calendar)
--   D8 grants + search_path on every new definer function
--   D9 free-tier cap: 5 manual channels for events of capacity <= the cutoff
--      (settings row, else 150); requeue / feeds don't count; withdraw frees
--   D10 manual minutes: logged with submitted / live / rejected, totalled
--      per event and per org (exos_discovery_minutes)
-- Self-contained ids d15…; runs after the full run_p0.sh chain.
-- ============================================================================
\set ON_ERROR_STOP on
BEGIN;

INSERT INTO auth.users(id,email,email_confirmed_at) VALUES
  ('d1500000-0000-0000-0000-0000000000a1','dpown@x.com',now()),
  ('d1500000-0000-0000-0000-0000000000a2','dpman@x.com',now()),
  ('d1500000-0000-0000-0000-0000000000a3','dpfin@x.com',now()),
  ('d1500000-0000-0000-0000-0000000000a4','dpscan@x.com',now()),
  ('d1500000-0000-0000-0000-0000000000a5','dpother@x.com',now()),
  ('d1500000-0000-0000-0000-0000000000a9','dpop@x.com',now());
INSERT INTO public.exos_orgs(id,name,slug,owner_uid) VALUES
  ('d1500000-0000-0000-0000-000000000001','DP Org','dp-org','d1500000-0000-0000-0000-0000000000a1'),
  ('d1500000-0000-0000-0000-000000000002','DP Other','dp-other','d1500000-0000-0000-0000-0000000000a5');
INSERT INTO public.exos_org_memberships(org_id,user_id,role) VALUES
  ('d1500000-0000-0000-0000-000000000001','d1500000-0000-0000-0000-0000000000a1','owner'),
  ('d1500000-0000-0000-0000-000000000001','d1500000-0000-0000-0000-0000000000a2','manager'),
  ('d1500000-0000-0000-0000-000000000001','d1500000-0000-0000-0000-0000000000a3','finance'),
  ('d1500000-0000-0000-0000-000000000001','d1500000-0000-0000-0000-0000000000a4','scanner'),
  ('d1500000-0000-0000-0000-000000000002','d1500000-0000-0000-0000-0000000000a5','owner');
INSERT INTO public.exos_events(id,org_id,name,slug,status,starts_at,timezone,venue_name,venue_address,total_tickets,tickets_sold,created_by) VALUES
  ('d1500000-0000-0000-0000-0000000000e1','d1500000-0000-0000-0000-000000000001','DP Live','dp-live','published',now() + interval '9 days','America/New_York','Elsewhere','{"city":"Brooklyn","country":"US"}',100,0,'d1500000-0000-0000-0000-0000000000a1'),
  ('d1500000-0000-0000-0000-0000000000e2','d1500000-0000-0000-0000-000000000001','DP Draft','dp-draft','draft',now() + interval '9 days','America/New_York','Elsewhere',NULL,100,0,'d1500000-0000-0000-0000-0000000000a1'),
  ('d1500000-0000-0000-0000-0000000000e3','d1500000-0000-0000-0000-000000000001','DP Past','dp-past','published',now() - interval '3 days','America/New_York','Elsewhere',NULL,100,0,'d1500000-0000-0000-0000-0000000000a1'),
  ('d1500000-0000-0000-0000-0000000000e4','d1500000-0000-0000-0000-000000000001','DP Hidden','dp-hidden','published',now() + interval '5 days','America/New_York','Elsewhere',NULL,100,0,'d1500000-0000-0000-0000-0000000000a1'),
  ('d1500000-0000-0000-0000-0000000000e5','d1500000-0000-0000-0000-000000000002','DP Elsewhere','dp-elsewhere','published',now() + interval '4 days','America/New_York','Other Room',NULL,100,0,'d1500000-0000-0000-0000-0000000000a5');
UPDATE public.exos_events SET noindex = true WHERE id = 'd1500000-0000-0000-0000-0000000000e4';
INSERT INTO public.exos_ticket_tiers(id,event_id,name,price,capacity,sold,visibility) VALUES
  ('d1500000-0000-0000-0000-0000000000d1','d1500000-0000-0000-0000-0000000000e1','GA',30,100,0,'public'),
  ('d1500000-0000-0000-0000-0000000000d2','d1500000-0000-0000-0000-0000000000e1','Secret',5,10,0,'hidden');

-- prereq.sql stubs exos_is_admin() as constant false; this test needs the
-- operator, so install prod's body (mig 20260520130000) for this transaction
-- (definer here only because the harness's auth schema has no client grants).
CREATE OR REPLACE FUNCTION public.exos_is_admin()
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT coalesce((auth.jwt() -> 'app_metadata' ->> 'admin') = 'true', false);
$$;

CREATE FUNCTION pg_temp.act(p_uid text, p_admin boolean DEFAULT false) RETURNS void LANGUAGE sql AS $$
  SELECT set_config('app.uid', coalesce(p_uid, ''), true),
         set_config('app.jwt', CASE WHEN p_admin THEN '{"app_metadata":{"admin":"true"}}' ELSE '' END, true);
$$;
GRANT EXECUTE ON FUNCTION pg_temp.act(text, boolean) TO anon, authenticated;
CREATE FUNCTION pg_temp.u(p text) RETURNS uuid LANGUAGE sql IMMUTABLE AS $$ SELECT ('d1500000-0000-0000-0000-' || p)::uuid $$;
GRANT EXECUTE ON FUNCTION pg_temp.u(text) TO anon, authenticated;
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
GRANT EXECUTE ON FUNCTION pg_temp.refused(text, text) TO anon, authenticated;

-- D1 ----------------------------------------------------------------------
SET LOCAL ROLE authenticated;
SELECT pg_temp.act('d1500000-0000-0000-0000-0000000000a4');
SELECT set_config('dp.cat', (SELECT json_object_agg(id, kind)::text FROM public.exos_discovery_channels), true);
RESET ROLE;
DO $$
DECLARE c jsonb := current_setting('dp.cat')::jsonb;
BEGIN
  ASSERT c->>'google_events' = 'feed' AND c->>'calendar_ics' = 'feed' AND c->>'ad_catalog' = 'feed', 'D1: feeds ' || c::text;
  ASSERT c->>'donyc' = 'manual' AND c->>'timeout_nyc' = 'manual' AND c->>'cityspark' = 'manual'
     AND c->>'resident_advisor' = 'manual' AND c->>'edmtrain' = 'manual' AND c->>'meetup' = 'manual', 'D1: manual ' || c::text;
  ASSERT NOT (c ? 'stubhub'), 'D1: no resale sites in the discovery catalog';
  ASSERT NOT has_table_privilege('anon', 'public.exos_discovery_channels', 'SELECT'), 'D1: anon can''t read the catalog';
  ASSERT NOT has_table_privilege('anon', 'public.exos_discovery_publications', 'SELECT'), 'D1: anon can''t read records';
END $$;

-- D2 ----------------------------------------------------------------------
SET LOCAL ROLE authenticated;
SELECT pg_temp.act('d1500000-0000-0000-0000-0000000000a4');
SELECT set_config('dp.scan', pg_temp.refused($$SELECT public.exos_discovery_queue(pg_temp.u('0000000000e1'), 'donyc')$$, 'not authorized')::text, true);
SELECT pg_temp.act('d1500000-0000-0000-0000-0000000000a3');
SELECT set_config('dp.fin', pg_temp.refused($$SELECT public.exos_discovery_queue(pg_temp.u('0000000000e1'), 'donyc')$$, 'not authorized')::text, true);
SELECT pg_temp.act('d1500000-0000-0000-0000-0000000000a5');
SELECT set_config('dp.other', pg_temp.refused($$SELECT public.exos_discovery_queue(pg_temp.u('0000000000e1'), 'donyc')$$, 'not authorized')::text, true);
SELECT pg_temp.act('d1500000-0000-0000-0000-0000000000a1');
SELECT set_config('dp.feed', pg_temp.refused($$SELECT public.exos_discovery_queue(pg_temp.u('0000000000e1'), 'google_events')$$, 'is a feed')::text, true);
SELECT set_config('dp.unk', pg_temp.refused($$SELECT public.exos_discovery_queue(pg_temp.u('0000000000e1'), 'stubhub')$$, 'unknown channel')::text, true);
SELECT set_config('dp.draft', pg_temp.refused($$SELECT public.exos_discovery_queue(pg_temp.u('0000000000e2'), 'donyc')$$, 'only upcoming published')::text, true);
SELECT set_config('dp.past', pg_temp.refused($$SELECT public.exos_discovery_queue(pg_temp.u('0000000000e3'), 'donyc')$$, 'only upcoming published')::text, true);
SELECT set_config('dp.q1', public.exos_discovery_queue(pg_temp.u('0000000000e1'), 'donyc', 'Brooklyn, 21+')::text, true);
SELECT set_config('dp.q2', public.exos_discovery_queue(pg_temp.u('0000000000e1'), 'donyc')::text, true);
SELECT pg_temp.act('d1500000-0000-0000-0000-0000000000a2');
SELECT set_config('dp.q3', public.exos_discovery_queue(pg_temp.u('0000000000e1'), 'resident_advisor')::text, true);
SELECT pg_temp.act('d1500000-0000-0000-0000-0000000000a5');
SELECT set_config('dp.q4', public.exos_discovery_queue(pg_temp.u('0000000000e5'), 'timeout_nyc')::text, true);
RESET ROLE;
DO $$
DECLARE q1 jsonb := current_setting('dp.q1')::jsonb; q2 jsonb := current_setting('dp.q2')::jsonb;
        r public.exos_discovery_publications%ROWTYPE;
BEGIN
  ASSERT current_setting('dp.scan')::boolean AND current_setting('dp.fin')::boolean AND current_setting('dp.other')::boolean, 'D2: roles';
  ASSERT current_setting('dp.feed')::boolean AND current_setting('dp.unk')::boolean, 'D2: channel checks';
  ASSERT current_setting('dp.draft')::boolean AND current_setting('dp.past')::boolean, 'D2: event checks';
  ASSERT q1->>'status' = 'queued' AND q1->>'next_action' = 'Submit on DoNYC' AND q1->>'note' = 'Brooklyn, 21+', 'D2: queued ' || q1::text;
  ASSERT q2->>'id' = q1->>'id' AND q2->>'status' = 'queued' AND q2->>'queued_at' = q1->>'queued_at' AND q2->>'note' = 'Brooklyn, 21+', 'D2: idempotent ' || q2::text;
  ASSERT (SELECT count(*) FROM public.exos_discovery_publications WHERE event_id = pg_temp.u('0000000000e1') AND channel_id = 'donyc') = 1, 'D2: one row';
  SELECT * INTO r FROM public.exos_discovery_publications WHERE id = (q1->>'id')::uuid;
  ASSERT r.org_id = pg_temp.u('000000000001') AND r.queued_by = pg_temp.u('0000000000a1'), 'D2: org + who';
  ASSERT current_setting('dp.q3')::jsonb->>'status' = 'queued', 'D2: manager queues';
END $$;

-- D3 ----------------------------------------------------------------------
SET LOCAL ROLE authenticated;
SELECT pg_temp.act('d1500000-0000-0000-0000-0000000000a3');
SELECT set_config('dp.fin_n', (SELECT count(*)::text FROM public.exos_discovery_publications), true);
SELECT pg_temp.act('d1500000-0000-0000-0000-0000000000a4');
SELECT set_config('dp.scan_n', (SELECT count(*)::text FROM public.exos_discovery_publications), true);
SELECT pg_temp.act('d1500000-0000-0000-0000-0000000000a5');
SELECT set_config('dp.other_n', (SELECT count(*)::text FROM public.exos_discovery_publications), true);
SELECT pg_temp.act('d1500000-0000-0000-0000-0000000000a9', true);
SELECT set_config('dp.admin_n', (SELECT count(*)::text FROM public.exos_discovery_publications), true);
SELECT pg_temp.act('d1500000-0000-0000-0000-0000000000a1');
SELECT set_config('dp.ins', pg_temp.refused($$INSERT INTO public.exos_discovery_publications(event_id, org_id, channel_id, status) VALUES (pg_temp.u('0000000000e1'), pg_temp.u('000000000001'), 'meetup', 'live')$$, 'permission denied')::text, true);
SELECT set_config('dp.upd', pg_temp.refused($$UPDATE public.exos_discovery_publications SET status = 'live'$$, 'permission denied')::text, true);
RESET ROLE;
DO $$
BEGIN
  ASSERT current_setting('dp.fin_n') = '2', 'D3: finance reads its org''s two, got ' || current_setting('dp.fin_n');
  ASSERT current_setting('dp.scan_n') = '0', 'D3: scanner reads none';
  ASSERT current_setting('dp.other_n') = '1', 'D3: other org reads only its own';
  ASSERT current_setting('dp.admin_n') = '3', 'D3: admin reads all';
  ASSERT current_setting('dp.ins')::boolean AND current_setting('dp.upd')::boolean, 'D3: no direct writes';
END $$;

-- D4 ----------------------------------------------------------------------
SET LOCAL ROLE authenticated;
SELECT pg_temp.act('d1500000-0000-0000-0000-0000000000a1');
SELECT set_config('dp.ql_owner', pg_temp.refused($$SELECT public.exos_discovery_queue_list()$$, 'operator only')::text, true);
SELECT pg_temp.act('d1500000-0000-0000-0000-0000000000a9', true);
SELECT set_config('dp.ql', public.exos_discovery_queue_list()::text, true);
SELECT set_config('dp.ql_tonyc', public.exos_discovery_queue_list('queued', 'timeout_nyc')::text, true);
SELECT set_config('dp.ql_bad', pg_temp.refused($$SELECT public.exos_discovery_queue_list('pending')$$, 'unknown status')::text, true);
RESET ROLE;
DO $$
DECLARE l jsonb := current_setting('dp.ql')::jsonb; d jsonb;
BEGIN
  ASSERT current_setting('dp.ql_owner')::boolean AND current_setting('dp.ql_bad')::boolean, 'D4: refusals';
  ASSERT jsonb_array_length(l) = 3, 'D4: three queued across orgs, got ' || l::text;
  SELECT x INTO d FROM jsonb_array_elements(l) x WHERE x->>'channel_id' = 'donyc';
  ASSERT d->>'channel_name' = 'DoNYC' AND d->>'submission_url' = 'https://donyc.com/p/how-to-nyc', 'D4: channel ' || d::text;
  ASSERT d->'event'->>'name' = 'DP Live' AND d->'event'->>'org_slug' = 'dp-org' AND d->'event'->>'venue_name' = 'Elsewhere', 'D4: event';
  ASSERT jsonb_array_length(d->'event'->'tiers') = 1 AND d->'event'->'tiers'->0->>'name' = 'GA', 'D4: public tiers only';
  ASSERT jsonb_array_length(current_setting('dp.ql_tonyc')::jsonb) = 1, 'D4: channel filter';
END $$;

-- D5 ----------------------------------------------------------------------
SELECT set_config('dp.pid', (SELECT id::text FROM public.exos_discovery_publications WHERE channel_id = 'donyc' AND event_id = pg_temp.u('0000000000e1')), true);
SELECT set_config('dp.rid', (SELECT id::text FROM public.exos_discovery_publications WHERE channel_id = 'resident_advisor'), true);
SELECT set_config('dp.oid', (SELECT id::text FROM public.exos_discovery_publications WHERE channel_id = 'timeout_nyc'), true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.act('d1500000-0000-0000-0000-0000000000a5');
SELECT set_config('dp.s_other', pg_temp.refused(format($$SELECT public.exos_discovery_set_status(%L, 'submitted')$$, current_setting('dp.pid')), 'not authorized')::text, true);
SELECT pg_temp.act('d1500000-0000-0000-0000-0000000000a3');
SELECT set_config('dp.s_fin', pg_temp.refused(format($$SELECT public.exos_discovery_set_status(%L, 'submitted')$$, current_setting('dp.pid')), 'not authorized')::text, true);
SELECT pg_temp.act('d1500000-0000-0000-0000-0000000000a9', true);
SELECT set_config('dp.s1', public.exos_discovery_set_status(current_setting('dp.pid')::uuid, 'submitted')::text, true);
SELECT set_config('dp.s_nourl', pg_temp.refused(format($$SELECT public.exos_discovery_set_status(%L, 'live')$$, current_setting('dp.pid')), 'https URL')::text, true);
SELECT set_config('dp.s_http', pg_temp.refused(format($$SELECT public.exos_discovery_set_status(%L, 'live', 'http://donyc.com/events/x')$$, current_setting('dp.pid')), 'https URL')::text, true);
SELECT set_config('dp.s2', public.exos_discovery_set_status(current_setting('dp.pid')::uuid, 'live', ' https://donyc.com/events/2026/11/7/dp-live ')::text, true);
SELECT set_config('dp.s2b', public.exos_discovery_set_status(current_setting('dp.pid')::uuid, 'live', 'https://donyc.com/events/2026/11/7/dp-live')::text, true);
SELECT set_config('dp.s_back', pg_temp.refused(format($$SELECT public.exos_discovery_set_status(%L, 'submitted')$$, current_setting('dp.pid')), 'can''t go from live to submitted')::text, true);
SELECT set_config('dp.s_bogus', pg_temp.refused(format($$SELECT public.exos_discovery_set_status(%L, 'approved')$$, current_setting('dp.pid')), 'can''t go from')::text, true);
SELECT set_config('dp.s_noreason', pg_temp.refused(format($$SELECT public.exos_discovery_set_status(%L, 'rejected')$$, current_setting('dp.oid')), 'needs a reason')::text, true);
SELECT set_config('dp.s3', public.exos_discovery_set_status(current_setting('dp.oid')::uuid, 'rejected', NULL, 'Editorial: not a fit this week')::text, true);
SELECT set_config('dp.s4', public.exos_discovery_set_status(current_setting('dp.pid')::uuid, 'removed')::text, true);
RESET ROLE;
SELECT set_config('dp.who', (SELECT concat_ws(',', submitted_by, decided_by) FROM public.exos_discovery_publications WHERE id = current_setting('dp.pid')::uuid), true);
SET LOCAL ROLE authenticated;
-- the organizer records its own RA submission
SELECT pg_temp.act('d1500000-0000-0000-0000-0000000000a2');
SELECT set_config('dp.s5', public.exos_discovery_set_status(current_setting('dp.rid')::uuid, 'submitted', NULL, NULL, 'RA reviews in 2-3 days')::text, true);
-- requeue after removed / rejected clears the old result
SELECT pg_temp.act('d1500000-0000-0000-0000-0000000000a1');
SELECT set_config('dp.rq', public.exos_discovery_queue(pg_temp.u('0000000000e1'), 'donyc')::text, true);
SELECT pg_temp.act('d1500000-0000-0000-0000-0000000000a5');
SELECT set_config('dp.rq2', public.exos_discovery_queue(pg_temp.u('0000000000e5'), 'timeout_nyc')::text, true);
RESET ROLE;
DO $$
DECLARE s1 jsonb := current_setting('dp.s1')::jsonb; s2 jsonb := current_setting('dp.s2')::jsonb;
        s3 jsonb := current_setting('dp.s3')::jsonb; s4 jsonb := current_setting('dp.s4')::jsonb;
        rq jsonb := current_setting('dp.rq')::jsonb; rq2 jsonb := current_setting('dp.rq2')::jsonb;
        r public.exos_discovery_publications%ROWTYPE;
BEGIN
  ASSERT current_setting('dp.s_other')::boolean AND current_setting('dp.s_fin')::boolean, 'D5: roles';
  ASSERT s1->>'status' = 'submitted' AND s1->>'submitted_at' IS NOT NULL AND s1->>'next_action' = 'Check the listing went up', 'D5: submitted ' || s1::text;
  ASSERT current_setting('dp.s_nourl')::boolean AND current_setting('dp.s_http')::boolean, 'D5: live needs https';
  ASSERT s2->>'status' = 'live' AND s2->>'live_url' = 'https://donyc.com/events/2026/11/7/dp-live' AND s2->>'decided_at' IS NOT NULL, 'D5: live ' || s2::text;
  ASSERT current_setting('dp.s2b')::jsonb->>'updated_at' = s2->>'updated_at', 'D5: same live is a no-op';
  ASSERT current_setting('dp.s_back')::boolean AND current_setting('dp.s_bogus')::boolean, 'D5: bad moves';
  ASSERT current_setting('dp.s_noreason')::boolean, 'D5: rejected needs a reason';
  ASSERT s3->>'status' = 'rejected' AND s3->>'rejection_reason' = 'Editorial: not a fit this week', 'D5: rejected ' || s3::text;
  ASSERT s4->>'status' = 'removed' AND s4->>'live_url' IS NOT NULL, 'D5: removed keeps the old URL ' || s4::text;
  ASSERT current_setting('dp.s5')::jsonb->>'next_action' = 'RA reviews in 2-3 days', 'D5: manager records + next action';
  ASSERT current_setting('dp.who') = 'd1500000-0000-0000-0000-0000000000a9,d1500000-0000-0000-0000-0000000000a9', 'D5: who ' || current_setting('dp.who');
  SELECT * INTO r FROM public.exos_discovery_publications WHERE id = current_setting('dp.rid')::uuid;
  ASSERT r.submitted_by = pg_temp.u('0000000000a2') AND r.status = 'submitted', 'D5: organizer recorded RA';
  ASSERT rq->>'id' = current_setting('dp.pid') AND rq->>'status' = 'queued' AND rq->>'live_url' IS NULL AND rq->>'submitted_at' IS NULL, 'D5: requeue after removed ' || rq::text;
  ASSERT rq2->>'status' = 'queued' AND rq2->>'rejection_reason' IS NULL, 'D5: requeue after rejected';
END $$;

-- D6 ----------------------------------------------------------------------
SET LOCAL ROLE authenticated;
SELECT pg_temp.act('d1500000-0000-0000-0000-0000000000a1');
SELECT set_config('dp.w1', public.exos_discovery_withdraw(pg_temp.u('0000000000e1'), 'donyc')::text, true);
SELECT set_config('dp.w2', pg_temp.refused($$SELECT public.exos_discovery_withdraw(pg_temp.u('0000000000e1'), 'donyc')$$, 'nothing queued')::text, true);
SELECT set_config('dp.w_sub', pg_temp.refused($$SELECT public.exos_discovery_withdraw(pg_temp.u('0000000000e1'), 'resident_advisor')$$, 'nothing queued')::text, true);
SELECT set_config('dp.w3', public.exos_discovery_queue(pg_temp.u('0000000000e1'), 'donyc')::text, true);
RESET ROLE;
DO $$
BEGIN
  ASSERT current_setting('dp.w1')::jsonb->>'status' = 'not_submitted', 'D6: withdrawn';
  ASSERT current_setting('dp.w2')::boolean AND current_setting('dp.w_sub')::boolean, 'D6: only queued can be withdrawn';
  ASSERT current_setting('dp.w3')::jsonb->>'status' = 'queued', 'D6: queue again';
END $$;

-- D7 ----------------------------------------------------------------------
SET LOCAL ROLE authenticated;
SELECT pg_temp.act('d1500000-0000-0000-0000-0000000000a3');
SELECT set_config('dp.ec', public.exos_discovery_event_channels(pg_temp.u('0000000000e1'))::text, true);
SELECT set_config('dp.ec_hidden', public.exos_discovery_event_channels(pg_temp.u('0000000000e4'))::text, true);
SELECT set_config('dp.ec_draft', public.exos_discovery_event_channels(pg_temp.u('0000000000e2'))::text, true);
SELECT pg_temp.act('d1500000-0000-0000-0000-0000000000a4');
SELECT set_config('dp.ec_scan', pg_temp.refused($$SELECT public.exos_discovery_event_channels(pg_temp.u('0000000000e1'))$$, 'not authorized')::text, true);
SELECT pg_temp.act('d1500000-0000-0000-0000-0000000000a5');
SELECT set_config('dp.ec_other', pg_temp.refused($$SELECT public.exos_discovery_event_channels(pg_temp.u('0000000000e1'))$$, 'not authorized')::text, true);
SELECT pg_temp.act('d1500000-0000-0000-0000-0000000000a1');
SELECT set_config('dp.ec_owner', public.exos_discovery_event_channels(pg_temp.u('0000000000e1'))::text, true);
RESET ROLE;
DO $$
DECLARE ec jsonb := current_setting('dp.ec')::jsonb; ch jsonb;
BEGIN
  ASSERT current_setting('dp.ec_scan')::boolean AND current_setting('dp.ec_other')::boolean, 'D7: roles';
  ASSERT NOT (ec->>'can_edit')::boolean AND (current_setting('dp.ec_owner')::jsonb->>'can_edit')::boolean, 'D7: can_edit';
  ASSERT ec->'calendar'->>'status' = 'live', 'D7: in the org calendar ' || (ec->'calendar')::text;
  ASSERT current_setting('dp.ec_hidden')::jsonb->'calendar'->>'status' = 'not_eligible'
     AND current_setting('dp.ec_hidden')::jsonb->'calendar'->>'reason' LIKE 'hidden from search%', 'D7: noindex not in the calendar';
  ASSERT current_setting('dp.ec_draft')::jsonb->'calendar'->>'reason' = 'not published', 'D7: draft';
  ASSERT jsonb_array_length(ec->'channels') = (SELECT count(*) FROM public.exos_discovery_channels WHERE active), 'D7: every channel';
  SELECT x INTO ch FROM jsonb_array_elements(ec->'channels') x WHERE x->>'id' = 'donyc';
  ASSERT ch->'publication'->>'status' = 'queued', 'D7: record ' || ch::text;
  SELECT x INTO ch FROM jsonb_array_elements(ec->'channels') x WHERE x->>'id' = 'google_events';
  ASSERT ch->'publication' = 'null'::jsonb AND ch->>'kind' = 'feed', 'D7: feeds have no record';
  ASSERT jsonb_array_length(ec->'event'->'tiers') = 1, 'D7: public tiers for the feed rules';
END $$;

-- D9 free-tier cap ---------------------------------------------------------
-- e1 is capacity 100 (free tier, cutoff 150 by default: no settings row).
-- It uses donyc (queued) + resident_advisor (submitted) = 2 manual channels.
INSERT INTO public.exos_events(id,org_id,name,slug,status,starts_at,timezone,venue_name,total_tickets,tickets_sold,created_by) VALUES
  ('d1500000-0000-0000-0000-0000000000e6','d1500000-0000-0000-0000-000000000001','DP Big','dp-big','published',now() + interval '20 days','America/New_York','Hall',500,0,'d1500000-0000-0000-0000-0000000000a1');
INSERT INTO public.exos_ticket_tiers(id,event_id,name,price,capacity,sold,visibility) VALUES
  ('d1500000-0000-0000-0000-0000000000d6','d1500000-0000-0000-0000-0000000000e6','GA',40,500,0,'public');
DELETE FROM public.exos_platform_settings WHERE key = 'free_tier_max_capacity';
SET LOCAL ROLE authenticated;
SELECT pg_temp.act('d1500000-0000-0000-0000-0000000000a1');
SELECT public.exos_discovery_queue(pg_temp.u('0000000000e1'), 'cityspark');
SELECT public.exos_discovery_queue(pg_temp.u('0000000000e1'), 'oh_my_rockness');
SELECT public.exos_discovery_queue(pg_temp.u('0000000000e1'), 'edmtrain');
SELECT set_config('dp.cap6', pg_temp.refused($$SELECT public.exos_discovery_queue(pg_temp.u('0000000000e1'), 'meetup')$$, 'free-tier events (capacity 150 or less) can go to at most 5 listing sites')::text, true);
SELECT set_config('dp.cap_again', public.exos_discovery_queue(pg_temp.u('0000000000e1'), 'donyc')::text, true);
SELECT set_config('dp.cap_feed', pg_temp.refused($$SELECT public.exos_discovery_queue(pg_temp.u('0000000000e1'), 'calendar_ics')$$, 'is a feed')::text, true);
SELECT set_config('dp.cap_ec', public.exos_discovery_event_channels(pg_temp.u('0000000000e1'))::text, true);
SELECT public.exos_discovery_withdraw(pg_temp.u('0000000000e1'), 'edmtrain');
SELECT set_config('dp.cap_after', public.exos_discovery_queue(pg_temp.u('0000000000e1'), 'meetup')::text, true);
-- over the cutoff: no cap
SELECT public.exos_discovery_queue(pg_temp.u('0000000000e6'), c)
  FROM unnest(ARRAY['donyc', 'timeout_nyc', 'cityspark', 'resident_advisor', 'oh_my_rockness', 'edmtrain']) c;
SELECT set_config('dp.big_ec', public.exos_discovery_event_channels(pg_temp.u('0000000000e6'))::text, true);
RESET ROLE;
-- the cutoff comes from the settings row when there is one
INSERT INTO public.exos_platform_settings (key, value) VALUES ('free_tier_max_capacity', '50');
SET LOCAL ROLE authenticated;
SELECT pg_temp.act('d1500000-0000-0000-0000-0000000000a1');
SELECT set_config('dp.cap_set', public.exos_discovery_queue(pg_temp.u('0000000000e1'), 'songkick')::text, true);
RESET ROLE;
DELETE FROM public.exos_platform_settings WHERE key = 'free_tier_max_capacity';
DO $$
DECLARE ec jsonb := current_setting('dp.cap_ec')::jsonb;
BEGIN
  ASSERT current_setting('dp.cap6')::boolean, 'D9: 6th manual channel refused';
  ASSERT current_setting('dp.cap_again')::jsonb->>'status' = 'queued', 'D9: requeue of a used channel is fine';
  ASSERT current_setting('dp.cap_feed')::boolean, 'D9: feeds never queue';
  ASSERT (ec->>'manual_cap')::int = 5 AND (ec->>'manual_used')::int = 5, 'D9: cap shown ' || (ec - 'channels' - 'event')::text;
  ASSERT current_setting('dp.cap_after')::jsonb->>'status' = 'queued', 'D9: withdrawing frees a slot';
  ASSERT current_setting('dp.big_ec')::jsonb->'manual_cap' = 'null'::jsonb
     AND (current_setting('dp.big_ec')::jsonb->>'manual_used')::int = 6, 'D9: no cap over 150';
  ASSERT current_setting('dp.cap_set')::jsonb->>'status' = 'queued', 'D9: cutoff 50 -> a 100-cap event is uncapped';
END $$;

-- D10 manual minutes -------------------------------------------------------
SELECT set_config('dp.m1', (SELECT id::text FROM public.exos_discovery_publications WHERE event_id = pg_temp.u('0000000000e6') AND channel_id = 'cityspark'), true);
SELECT set_config('dp.m2', (SELECT id::text FROM public.exos_discovery_publications WHERE event_id = pg_temp.u('0000000000e6') AND channel_id = 'timeout_nyc'), true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.act('d1500000-0000-0000-0000-0000000000a9', true);
SELECT public.exos_discovery_set_status(current_setting('dp.m1')::uuid, 'submitted', NULL, NULL, NULL, 12);
SELECT public.exos_discovery_set_status(current_setting('dp.m1')::uuid, 'submitted', NULL, NULL, NULL, 2);
SELECT set_config('dp.m1r', public.exos_discovery_set_status(current_setting('dp.m1')::uuid, 'live', 'https://cityspark.example/e/1', NULL, NULL, 3)::text, true);
SELECT public.exos_discovery_set_status(current_setting('dp.m2')::uuid, 'rejected', NULL, 'Not a fit', NULL, 7);
SELECT set_config('dp.m_neg', pg_temp.refused(format($$SELECT public.exos_discovery_set_status(%L, 'live', 'https://x.example/1', NULL, NULL, -1)$$, current_setting('dp.m1')), '0 to 600')::text, true);
SELECT set_config('dp.m_rm', pg_temp.refused(format($$SELECT public.exos_discovery_set_status(%L, 'removed', NULL, NULL, NULL, 5)$$, current_setting('dp.m1')), 'minutes are logged with')::text, true);
SELECT set_config('dp.m_all', public.exos_discovery_minutes()::text, true);
SELECT pg_temp.act('d1500000-0000-0000-0000-0000000000a3');
SELECT set_config('dp.m_org', public.exos_discovery_minutes(pg_temp.u('000000000001'))::text, true);
SELECT set_config('dp.m_ec', public.exos_discovery_event_channels(pg_temp.u('0000000000e6'))::text, true);
SELECT set_config('dp.m_fin_all', pg_temp.refused($$SELECT public.exos_discovery_minutes()$$, 'operator only')::text, true);
SELECT pg_temp.act('d1500000-0000-0000-0000-0000000000a5');
SELECT set_config('dp.m_other', pg_temp.refused($$SELECT public.exos_discovery_minutes(pg_temp.u('000000000001'))$$, 'not authorized')::text, true);
SELECT pg_temp.act('d1500000-0000-0000-0000-0000000000a4');
SELECT set_config('dp.m_scan', pg_temp.refused($$SELECT public.exos_discovery_minutes(pg_temp.u('000000000001'))$$, 'not authorized')::text, true);
RESET ROLE;
DO $$
DECLARE o jsonb := current_setting('dp.m_org')::jsonb -> 0; e jsonb;
BEGIN
  ASSERT (current_setting('dp.m1r')::jsonb->>'minutes_spent')::int = 17, 'D10: minutes add up (12 + 2 + 3) ' || current_setting('dp.m1r');
  ASSERT current_setting('dp.m_neg')::boolean AND current_setting('dp.m_rm')::boolean, 'D10: minute checks';
  ASSERT jsonb_array_length(current_setting('dp.m_org')::jsonb) = 1 AND (o->>'minutes')::int = 24, 'D10: org total ' || o::text;
  SELECT x INTO e FROM jsonb_array_elements(o->'by_event') x WHERE x->>'event_id' = 'd1500000-0000-0000-0000-0000000000e6';
  ASSERT (e->>'minutes')::int = 24 AND (e->'channels'->>'cityspark')::int = 17 AND (e->'channels'->>'timeout_nyc')::int = 7, 'D10: per event ' || e::text;
  ASSERT (o->>'events')::int = 2 AND (o->>'minutes_per_event')::numeric = 12.0, 'D10: minutes per event ' || o::text;
  ASSERT (current_setting('dp.m_ec')::jsonb->>'minutes_spent')::int = 24, 'D10: event total on the organizer screen';
  ASSERT jsonb_array_length(current_setting('dp.m_all')::jsonb) = 2, 'D10: admin sees every org';
  ASSERT current_setting('dp.m_fin_all')::boolean AND current_setting('dp.m_other')::boolean AND current_setting('dp.m_scan')::boolean, 'D10: roles';
END $$;

-- D8 ----------------------------------------------------------------------
DO $$
DECLARE f record;
BEGIN
  FOR f IN SELECT p.oid::regprocedure AS sig, p.proname, p.proconfig FROM pg_proc p
            WHERE p.pronamespace = 'public'::regnamespace AND p.proname LIKE '%exos_discovery%' LOOP
    ASSERT f.proconfig @> ARRAY['search_path=public, pg_temp'], 'D8: search_path on ' || f.sig::text;
    ASSERT NOT has_function_privilege('anon', f.sig, 'EXECUTE'), 'D8: anon on ' || f.sig::text;
    IF f.proname LIKE '\_exos%' THEN
      ASSERT NOT has_function_privilege('authenticated', f.sig, 'EXECUTE'), 'D8: helper granted ' || f.sig::text;
    END IF;
  END LOOP;
END $$;

\echo 'test_discovery_publishing: all passed'
ROLLBACK;
