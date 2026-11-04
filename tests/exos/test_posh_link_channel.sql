-- ============================================================================
-- Posh third-party link channel (mig 20261104150000).
--   PL1 catalog: posh_link is a manual, global, unverified channel
--   PL2 eligibility: link-out events (sold on Posh / Eventbrite) are refused
--       with a clear message; an Exos event queues; Posh webhooks connected
--       for an event give a warning fact, not a refusal
--   PL3 free tier: posh_link counts toward the 5 manual channels
--   PL4 stats: owner / manager record readings on a live listing only;
--       same day replaces; bad values refused; finance / scanner / other org
--       refused; another channel refused
--   PL5 RLS: finance + admin read readings; scanner / other org see none;
--       no direct client writes
--   PL6 funnel: readings oldest first + Exos orders with utm_source=posh_link
--       only (other sources, other events and unfulfilled ones left out;
--       refunds and voided tickets taken off)
--   PL7 delete a reading (writer only)
--   PL8 grants + search_path on every new definer function
-- Self-contained ids b7150000-…; runs after the full run_p0.sh chain.
-- ============================================================================
\set ON_ERROR_STOP on
BEGIN;

INSERT INTO auth.users(id,email,email_confirmed_at) VALUES
  ('b7150000-0000-0000-0000-0000000000a1','plown@x.com',now()),
  ('b7150000-0000-0000-0000-0000000000a2','plman@x.com',now()),
  ('b7150000-0000-0000-0000-0000000000a3','plfin@x.com',now()),
  ('b7150000-0000-0000-0000-0000000000a4','plscan@x.com',now()),
  ('b7150000-0000-0000-0000-0000000000a5','plother@x.com',now()),
  ('b7150000-0000-0000-0000-0000000000a9','plop@x.com',now()),
  ('b7150000-0000-0000-0000-0000000000b1','plfan@x.com',now());
INSERT INTO public.exos_orgs(id,name,slug,owner_uid) VALUES
  ('b7150000-0000-0000-0000-000000000001','PL Org','pl-org','b7150000-0000-0000-0000-0000000000a1'),
  ('b7150000-0000-0000-0000-000000000002','PL Other','pl-other','b7150000-0000-0000-0000-0000000000a5');
INSERT INTO public.exos_org_memberships(org_id,user_id,role) VALUES
  ('b7150000-0000-0000-0000-000000000001','b7150000-0000-0000-0000-0000000000a1','owner'),
  ('b7150000-0000-0000-0000-000000000001','b7150000-0000-0000-0000-0000000000a2','manager'),
  ('b7150000-0000-0000-0000-000000000001','b7150000-0000-0000-0000-0000000000a3','finance'),
  ('b7150000-0000-0000-0000-000000000001','b7150000-0000-0000-0000-0000000000a4','scanner'),
  ('b7150000-0000-0000-0000-000000000002','b7150000-0000-0000-0000-0000000000a5','owner');
INSERT INTO public.exos_events(id,org_id,name,slug,status,starts_at,timezone,venue_name,total_tickets,tickets_sold,created_by) VALUES
  ('b7150000-0000-0000-0000-0000000000e1','b7150000-0000-0000-0000-000000000001','PL Exos','pl-exos','published',now() + interval '9 days','America/New_York','Elsewhere',100,0,'b7150000-0000-0000-0000-0000000000a1'),
  ('b7150000-0000-0000-0000-0000000000e4','b7150000-0000-0000-0000-000000000001','PL Hooked','pl-hooked','published',now() + interval '9 days','America/New_York','Elsewhere',100,0,'b7150000-0000-0000-0000-0000000000a1'),
  ('b7150000-0000-0000-0000-0000000000e5','b7150000-0000-0000-0000-000000000002','PL Elsewhere','pl-elsewhere','published',now() + interval '4 days','America/New_York','Other Room',100,0,'b7150000-0000-0000-0000-0000000000a5');
-- Link-out events (the import writes these; the harness is the service side).
INSERT INTO public.exos_events(id,org_id,name,slug,status,starts_at,timezone,venue_name,total_tickets,tickets_sold,created_by,
                               link_out,ticket_backend,external_ticket_url) VALUES
  ('b7150000-0000-0000-0000-0000000000e2','b7150000-0000-0000-0000-000000000001','PL Posh Sold','pl-posh-sold','published',now() + interval '9 days','America/New_York','Elsewhere',0,0,'b7150000-0000-0000-0000-0000000000a1',
   true,'posh','https://posh.vip/e/pl-posh-sold'),
  ('b7150000-0000-0000-0000-0000000000e3','b7150000-0000-0000-0000-000000000001','PL EB Sold','pl-eb-sold','published',now() + interval '9 days','America/New_York','Elsewhere',0,0,'b7150000-0000-0000-0000-0000000000a1',
   true,'eventbrite','https://www.eventbrite.com/e/123456');
INSERT INTO public.exos_event_imports(event_id,org_id,platform,source_event_id,source_url,origin) VALUES
  ('b7150000-0000-0000-0000-0000000000e2','b7150000-0000-0000-0000-000000000001','posh','pl-posh-sold','https://posh.vip/e/pl-posh-sold','link'),
  ('b7150000-0000-0000-0000-0000000000e3','b7150000-0000-0000-0000-000000000001','eventbrite','123456','https://www.eventbrite.com/e/123456','link');
INSERT INTO public.exos_ticket_tiers(id,event_id,name,price,capacity,sold,visibility) VALUES
  ('b7150000-0000-0000-0000-0000000000d1','b7150000-0000-0000-0000-0000000000e1','GA',25,100,0,'public'),
  ('b7150000-0000-0000-0000-0000000000d4','b7150000-0000-0000-0000-0000000000e4','GA',25,100,0,'public');
-- Posh webhooks connected for e4 (active hook + the event linked).
INSERT INTO public.exos_posh_hooks(org_id,token_hash,token_hint) VALUES
  ('b7150000-0000-0000-0000-000000000001', repeat('ab', 32), 'abab');
INSERT INTO public.exos_posh_event_links(org_id,posh_ref,event_id) VALUES
  ('b7150000-0000-0000-0000-000000000001','pl-hooked','b7150000-0000-0000-0000-0000000000e4');
-- The free-tier cutoff is lifted for the whole run (run_p0.sh); put it back here.
DELETE FROM public.exos_platform_settings WHERE key = 'free_tier_max_capacity';

-- prereq.sql stubs exos_is_admin() as false; install prod's body for this transaction.
CREATE OR REPLACE FUNCTION public.exos_is_admin()
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT coalesce((auth.jwt() -> 'app_metadata' ->> 'admin') = 'true', false);
$$;

CREATE FUNCTION pg_temp.act(p_uid text, p_admin boolean DEFAULT false) RETURNS void LANGUAGE sql AS $$
  SELECT set_config('app.uid', coalesce(p_uid, ''), true),
         set_config('app.jwt', CASE WHEN p_admin THEN '{"app_metadata":{"admin":"true"}}' ELSE '' END, true);
$$;
GRANT EXECUTE ON FUNCTION pg_temp.act(text, boolean) TO anon, authenticated;
CREATE FUNCTION pg_temp.u(p text) RETURNS uuid LANGUAGE sql IMMUTABLE AS $$ SELECT ('b7150000-0000-0000-0000-' || p)::uuid $$;
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

-- PL1 ---------------------------------------------------------------------
DO $$
DECLARE c public.exos_discovery_channels%ROWTYPE;
BEGIN
  SELECT * INTO c FROM public.exos_discovery_channels WHERE id = 'posh_link';
  ASSERT FOUND AND c.kind = 'manual' AND c.region = 'global' AND c.active, 'PL1: posh_link manual global';
  ASSERT c.name = 'Posh (third-party link)' AND c.submission_url = 'https://posh.vip' AND NOT c.verified, 'PL1: link not verified';
  RAISE NOTICE 'OK  PL1 posh_link channel seeded (manual, global, not verified)';
END $$;

-- PL2 ---------------------------------------------------------------------
SET LOCAL ROLE authenticated;
SELECT pg_temp.act('b7150000-0000-0000-0000-0000000000a1');
SELECT set_config('pl.posh', pg_temp.refused($$SELECT public.exos_discovery_queue(pg_temp.u('0000000000e2'), 'posh_link')$$,
  'this event is sold on Posh, so it already has a Posh page. Posh (third-party link) is for events sold on Exos.')::text, true);
SELECT set_config('pl.eb', pg_temp.refused($$SELECT public.exos_discovery_queue(pg_temp.u('0000000000e3'), 'posh_link')$$,
  'this event is sold on Eventbrite (a link-out event), so Posh (third-party link) isn''t offered')::text, true);
-- Another manual channel is still fine for a link-out event.
SELECT set_config('pl.eb_ra', public.exos_discovery_queue(pg_temp.u('0000000000e3'), 'resident_advisor')::text, true);
SELECT set_config('pl.q1', public.exos_discovery_queue(pg_temp.u('0000000000e1'), 'posh_link')::text, true);
SELECT set_config('pl.q4', public.exos_discovery_queue(pg_temp.u('0000000000e4'), 'posh_link')::text, true);
SELECT set_config('pl.ec1', public.exos_discovery_event_channels(pg_temp.u('0000000000e1'))::text, true);
SELECT set_config('pl.ec2', public.exos_discovery_event_channels(pg_temp.u('0000000000e2'))::text, true);
SELECT set_config('pl.ec3', public.exos_discovery_event_channels(pg_temp.u('0000000000e3'))::text, true);
SELECT set_config('pl.ec4', public.exos_discovery_event_channels(pg_temp.u('0000000000e4'))::text, true);
RESET ROLE;
DO $$
DECLARE ec1 jsonb := current_setting('pl.ec1')::jsonb; ec2 jsonb := current_setting('pl.ec2')::jsonb;
        ec3 jsonb := current_setting('pl.ec3')::jsonb; ec4 jsonb := current_setting('pl.ec4')::jsonb;
BEGIN
  ASSERT current_setting('pl.posh')::boolean, 'PL2: Posh-sold event refused';
  ASSERT current_setting('pl.eb')::boolean, 'PL2: Eventbrite link-out refused';
  ASSERT current_setting('pl.eb_ra')::jsonb->>'status' = 'queued', 'PL2: other channels unaffected';
  ASSERT current_setting('pl.q1')::jsonb->>'status' = 'queued', 'PL2: Exos event queues';
  ASSERT current_setting('pl.q4')::jsonb->>'status' = 'queued', 'PL2: webhooks only warn';
  ASSERT ec1->'posh_link' = '{"link_out": false, "link_out_platform": null, "ticket_backend": "exos", "posh_webhooks": false, "blocked": null}'::jsonb,
    'PL2: facts for an Exos event ' || (ec1->'posh_link')::text;
  ASSERT (ec2->'posh_link'->>'link_out')::boolean AND ec2->'posh_link'->>'link_out_platform' = 'posh'
     AND ec2->'posh_link'->>'blocked' LIKE '%already has a Posh page%', 'PL2: facts for a Posh-sold event ' || (ec2->'posh_link')::text;
  ASSERT ec3->'posh_link'->>'link_out_platform' = 'eventbrite' AND ec3->'posh_link'->>'blocked' LIKE '%Eventbrite%', 'PL2: Eventbrite facts';
  ASSERT (ec4->'posh_link'->>'posh_webhooks')::boolean AND ec4->'posh_link'->'blocked' = 'null'::jsonb, 'PL2: webhook warning fact';
  ASSERT EXISTS (SELECT 1 FROM jsonb_array_elements(ec1->'channels') c WHERE c->>'id' = 'posh_link' AND c->'publication'->>'status' = 'queued'),
    'PL2: listed on the organizer screen';
  RAISE NOTICE 'OK  PL2 link-out events refused (Posh, Eventbrite), webhooks warn only';
END $$;
-- A disabled hook is not "connected".
UPDATE public.exos_posh_hooks SET status = 'disabled' WHERE org_id = pg_temp.u('000000000001');
SET LOCAL ROLE authenticated;
SELECT pg_temp.act('b7150000-0000-0000-0000-0000000000a1');
SELECT set_config('pl.ec4off', public.exos_discovery_event_channels(pg_temp.u('0000000000e4'))::text, true);
RESET ROLE;
UPDATE public.exos_posh_hooks SET status = 'active' WHERE org_id = pg_temp.u('000000000001');
DO $$
BEGIN
  ASSERT NOT (current_setting('pl.ec4off')::jsonb->'posh_link'->>'posh_webhooks')::boolean, 'PL2: disabled hook';
  RAISE NOTICE 'OK  PL2 a disabled Posh hook gives no warning';
END $$;

-- PL3 ---------------------------------------------------------------------
SET LOCAL ROLE authenticated;
SELECT pg_temp.act('b7150000-0000-0000-0000-0000000000a1');
SELECT public.exos_discovery_queue(pg_temp.u('0000000000e1'), c)
  FROM unnest(ARRAY['donyc', 'timeout_nyc', 'cityspark', 'resident_advisor']) c;
SELECT set_config('pl.cap6', pg_temp.refused($$SELECT public.exos_discovery_queue(pg_temp.u('0000000000e1'), 'meetup')$$,
  'can go to at most 5 listing sites')::text, true);
SELECT set_config('pl.cap_ec', public.exos_discovery_event_channels(pg_temp.u('0000000000e1'))::text, true);
RESET ROLE;
DO $$
BEGIN
  ASSERT current_setting('pl.cap6')::boolean, 'PL3: posh_link + 4 = the 5, the 6th refused';
  ASSERT (current_setting('pl.cap_ec')::jsonb->>'manual_used')::int = 5, 'PL3: posh_link counted';
  RAISE NOTICE 'OK  PL3 posh_link counts toward the free tier''s 5 manual channels';
END $$;

-- PL4 ---------------------------------------------------------------------
SELECT set_config('pl.pub', current_setting('pl.q1')::jsonb->>'id', true);
SELECT set_config('pl.pub_ra', (SELECT id::text FROM public.exos_discovery_publications
                                  WHERE event_id = pg_temp.u('0000000000e1') AND channel_id = 'resident_advisor'), true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.act('b7150000-0000-0000-0000-0000000000a1');
SELECT set_config('pl.notlive', pg_temp.refused(format($$SELECT public.exos_posh_link_record_stats(%L, current_date, 10, 1)$$, current_setting('pl.pub')),
  'mark the Posh page live first')::text, true);
SELECT public.exos_discovery_set_status(current_setting('pl.pub')::uuid, 'submitted');
SELECT public.exos_discovery_set_status(current_setting('pl.pub')::uuid, 'live', 'https://posh.vip/e/pl-exos');
SELECT public.exos_discovery_set_status(current_setting('pl.pub_ra')::uuid, 'live', 'https://ra.co/events/1');
SELECT set_config('pl.s1', public.exos_posh_link_record_stats(current_setting('pl.pub')::uuid, current_date - 3, 120, 30)::text, true);
SELECT pg_temp.act('b7150000-0000-0000-0000-0000000000a2');
SELECT set_config('pl.s2', public.exos_posh_link_record_stats(current_setting('pl.pub')::uuid, current_date, 400, 80)::text, true);
-- Same day again replaces it.
SELECT set_config('pl.s2b', public.exos_posh_link_record_stats(current_setting('pl.pub')::uuid, current_date, 410, 82)::text, true);
SELECT set_config('pl.neg', pg_temp.refused(format($$SELECT public.exos_posh_link_record_stats(%L, current_date, -1, 0)$$, current_setting('pl.pub')), 'whole numbers from 0')::text, true);
SELECT set_config('pl.nul', pg_temp.refused(format($$SELECT public.exos_posh_link_record_stats(%L, current_date, NULL, 0)$$, current_setting('pl.pub')), 'whole numbers from 0')::text, true);
SELECT set_config('pl.fut', pg_temp.refused(format($$SELECT public.exos_posh_link_record_stats(%L, current_date + 5, 1, 0)$$, current_setting('pl.pub')), '"as of" date')::text, true);
SELECT set_config('pl.old', pg_temp.refused(format($$SELECT public.exos_posh_link_record_stats(%L, date '2026-09-01', 1, 0)$$, current_setting('pl.pub')), '"as of" date')::text, true);
SELECT set_config('pl.ra', pg_temp.refused(format($$SELECT public.exos_posh_link_record_stats(%L, current_date, 1, 0)$$, current_setting('pl.pub_ra')), 'only for the Posh (third-party link) listing')::text, true);
SELECT pg_temp.act('b7150000-0000-0000-0000-0000000000a3');
SELECT set_config('pl.fin', pg_temp.refused(format($$SELECT public.exos_posh_link_record_stats(%L, current_date, 1, 0)$$, current_setting('pl.pub')), 'not authorized')::text, true);
SELECT pg_temp.act('b7150000-0000-0000-0000-0000000000a4');
SELECT set_config('pl.scan', pg_temp.refused(format($$SELECT public.exos_posh_link_record_stats(%L, current_date, 1, 0)$$, current_setting('pl.pub')), 'not authorized')::text, true);
SELECT pg_temp.act('b7150000-0000-0000-0000-0000000000a5');
SELECT set_config('pl.other', pg_temp.refused(format($$SELECT public.exos_posh_link_record_stats(%L, current_date, 1, 0)$$, current_setting('pl.pub')), 'not authorized')::text, true);
SELECT set_config('pl.ghost', pg_temp.refused($$SELECT public.exos_posh_link_record_stats(gen_random_uuid(), current_date, 1, 0)$$, 'not authorized')::text, true);
RESET ROLE;
DO $$
DECLARE s2 jsonb := current_setting('pl.s2')::jsonb; s2b jsonb := current_setting('pl.s2b')::jsonb;
BEGIN
  ASSERT current_setting('pl.notlive')::boolean, 'PL4: not live yet';
  ASSERT (current_setting('pl.s1')::jsonb->>'page_views')::int = 120, 'PL4: owner records';
  ASSERT s2b->>'id' = s2->>'id' AND (s2b->>'page_views')::int = 410 AND (s2b->>'link_clicks')::int = 82, 'PL4: same day replaces ' || s2b::text;
  ASSERT (SELECT count(*) FROM public.exos_discovery_posh_stats WHERE publication_id = current_setting('pl.pub')::uuid) = 2, 'PL4: two readings';
  ASSERT (SELECT org_id FROM public.exos_discovery_posh_stats WHERE id = (s2->>'id')::uuid) = pg_temp.u('000000000001'), 'PL4: org on the row';
  ASSERT (SELECT updated_by FROM public.exos_discovery_posh_stats WHERE id = (s2->>'id')::uuid) = pg_temp.u('0000000000a2'), 'PL4: manager recorded';
  ASSERT current_setting('pl.neg')::boolean AND current_setting('pl.nul')::boolean, 'PL4: non-negative integers';
  ASSERT current_setting('pl.fut')::boolean AND current_setting('pl.old')::boolean, 'PL4: as-of date range';
  ASSERT current_setting('pl.ra')::boolean, 'PL4: only posh_link';
  ASSERT current_setting('pl.fin')::boolean AND current_setting('pl.scan')::boolean AND current_setting('pl.other')::boolean
     AND current_setting('pl.ghost')::boolean, 'PL4: roles';
  RAISE NOTICE 'OK  PL4 stats: live only, same day replaces, values checked, writers only';
END $$;

-- PL5 ---------------------------------------------------------------------
SET LOCAL ROLE authenticated;
SELECT pg_temp.act('b7150000-0000-0000-0000-0000000000a3');
SELECT set_config('pl.fin_n', (SELECT count(*)::text FROM public.exos_discovery_posh_stats), true);
SELECT pg_temp.act('b7150000-0000-0000-0000-0000000000a4');
SELECT set_config('pl.scan_n', (SELECT count(*)::text FROM public.exos_discovery_posh_stats), true);
SELECT pg_temp.act('b7150000-0000-0000-0000-0000000000a5');
SELECT set_config('pl.other_n', (SELECT count(*)::text FROM public.exos_discovery_posh_stats), true);
SELECT pg_temp.act('b7150000-0000-0000-0000-0000000000a9', true);
SELECT set_config('pl.admin_n', (SELECT count(*)::text FROM public.exos_discovery_posh_stats WHERE event_id = pg_temp.u('0000000000e1')), true);
SELECT pg_temp.act('b7150000-0000-0000-0000-0000000000a1');
SELECT set_config('pl.ins', pg_temp.refused(format($$INSERT INTO public.exos_discovery_posh_stats(publication_id, event_id, org_id, as_of, page_views, link_clicks)
  VALUES (%L, pg_temp.u('0000000000e1'), pg_temp.u('000000000001'), current_date - 1, 1, 1)$$, current_setting('pl.pub')), 'permission denied')::text, true);
SELECT set_config('pl.upd', pg_temp.refused($$UPDATE public.exos_discovery_posh_stats SET page_views = 0$$, 'permission denied')::text, true);
SELECT set_config('pl.del', pg_temp.refused($$DELETE FROM public.exos_discovery_posh_stats$$, 'permission denied')::text, true);
RESET ROLE;
DO $$
BEGIN
  ASSERT current_setting('pl.fin_n')::int = 2, 'PL5: finance reads';
  ASSERT current_setting('pl.scan_n')::int = 0 AND current_setting('pl.other_n')::int = 0, 'PL5: scanner / other org see nothing';
  ASSERT current_setting('pl.admin_n')::int = 2, 'PL5: admin reads';
  ASSERT current_setting('pl.ins')::boolean AND current_setting('pl.upd')::boolean AND current_setting('pl.del')::boolean, 'PL5: no direct writes';
  ASSERT NOT has_table_privilege('anon', 'public.exos_discovery_posh_stats', 'SELECT'), 'PL5: anon';
  ASSERT (SELECT relrowsecurity FROM pg_class WHERE oid = 'public.exos_discovery_posh_stats'::regclass), 'PL5: RLS on';
  RAISE NOTICE 'OK  PL5 RLS: finance + admin read, scanner / other org / anon don''t, no client writes';
END $$;

-- PL6 ---------------------------------------------------------------------
INSERT INTO public.exos_checkout_sessions (session_id, event_id, tier_id, org_id, buyer_uid, buyer_email, quantity, amount_cents, currency, status, fulfilled_at, attribution) VALUES
  ('pl-s1', pg_temp.u('0000000000e1'), pg_temp.u('0000000000d1'), pg_temp.u('000000000001'), pg_temp.u('0000000000b1'), 'plfan@x.com', 2, 5000, 'usd', 'fulfilled', now(),
   '{"utm_source":"posh_link","utm_medium":"listing","utm_campaign":"discovery"}'),
  ('pl-s2', pg_temp.u('0000000000e1'), pg_temp.u('0000000000d1'), pg_temp.u('000000000001'), pg_temp.u('0000000000b1'), 'plfan@x.com', 1, 2500, 'usd', 'partially_refunded', now(),
   '{"utm_source":"POSH_LINK","utm_medium":"listing"}'),
  ('pl-s3', pg_temp.u('0000000000e1'), pg_temp.u('0000000000d1'), pg_temp.u('000000000001'), pg_temp.u('0000000000b1'), 'plfan@x.com', 1, 2500, 'usd', 'fulfilled', now(),
   '{"utm_source":"donyc","utm_medium":"listing"}'),
  ('pl-s4', pg_temp.u('0000000000e1'), pg_temp.u('0000000000d1'), pg_temp.u('000000000001'), pg_temp.u('0000000000b1'), 'plfan@x.com', 1, 2500, 'usd', 'pending', NULL,
   '{"utm_source":"posh_link"}'),
  ('pl-s5', pg_temp.u('0000000000e4'), pg_temp.u('0000000000d4'), pg_temp.u('000000000001'), pg_temp.u('0000000000b1'), 'plfan@x.com', 1, 2500, 'usd', 'fulfilled', now(),
   '{"utm_source":"posh_link"}');
INSERT INTO public.exos_tickets (event_id, org_id, tier_id, owner_id, buyer_id, buyer_email, status, barcode_secret, price_paid, order_ref, channel_source) VALUES
  (pg_temp.u('0000000000e1'), pg_temp.u('000000000001'), pg_temp.u('0000000000d1'), pg_temp.u('0000000000b1'), pg_temp.u('0000000000b1'), 'plfan@x.com', 'active', 'x', 25, 'pl-s1', 'stripe'),
  (pg_temp.u('0000000000e1'), pg_temp.u('000000000001'), pg_temp.u('0000000000d1'), pg_temp.u('0000000000b1'), pg_temp.u('0000000000b1'), 'plfan@x.com', 'active', 'x', 25, 'pl-s1', 'stripe'),
  (pg_temp.u('0000000000e1'), pg_temp.u('000000000001'), pg_temp.u('0000000000d1'), pg_temp.u('0000000000b1'), pg_temp.u('0000000000b1'), 'plfan@x.com', 'voided', 'x', 25, 'pl-s2', 'stripe');
INSERT INTO public.exos_order_refunds (session_id, org_id, amount_cents, currency, status) VALUES
  ('pl-s2', pg_temp.u('000000000001'), 2500, 'usd', 'succeeded');
SET LOCAL ROLE authenticated;
SELECT pg_temp.act('b7150000-0000-0000-0000-0000000000a3');
SELECT set_config('pl.f', public.exos_posh_link_funnel(pg_temp.u('0000000000e1'))::text, true);
SELECT pg_temp.act('b7150000-0000-0000-0000-0000000000a4');
SELECT set_config('pl.f_scan', pg_temp.refused($$SELECT public.exos_posh_link_funnel(pg_temp.u('0000000000e1'))$$, 'not authorized')::text, true);
SELECT pg_temp.act('b7150000-0000-0000-0000-0000000000a5');
SELECT set_config('pl.f_other', pg_temp.refused($$SELECT public.exos_posh_link_funnel(pg_temp.u('0000000000e1'))$$, 'not authorized')::text, true);
SELECT set_config('pl.f_own', public.exos_posh_link_funnel(pg_temp.u('0000000000e5'))::text, true);
RESET ROLE;
DO $$
DECLARE f jsonb := current_setting('pl.f')::jsonb; o jsonb := current_setting('pl.f_own')::jsonb;
BEGIN
  ASSERT f->'publication'->>'status' = 'live' AND f->'publication'->>'live_url' = 'https://posh.vip/e/pl-exos', 'PL6: listing ' || f::text;
  ASSERT jsonb_array_length(f->'readings') = 2
     AND (f->'readings'->0->>'page_views')::int = 120 AND (f->'readings'->1->>'link_clicks')::int = 82, 'PL6: readings oldest first';
  ASSERT (f->'exos'->>'orders')::int = 2, 'PL6: two posh_link orders (case-insensitive), not donyc / pending / other event ' || (f->'exos')::text;
  ASSERT (f->'exos'->>'tickets')::int = 2, 'PL6: voided ticket left out';
  ASSERT (f->'exos'->>'gross_cents')::bigint = 5000, 'PL6: refund taken off';
  ASSERT f->'exos'->>'currency' = 'usd', 'PL6: currency';
  ASSERT current_setting('pl.f_scan')::boolean AND current_setting('pl.f_other')::boolean, 'PL6: roles';
  ASSERT o->'publication' = 'null'::jsonb AND jsonb_array_length(o->'readings') = 0 AND (o->'exos'->>'orders')::int = 0, 'PL6: empty funnel ' || o::text;
  RAISE NOTICE 'OK  PL6 funnel: readings + utm_source=posh_link orders only, net of refunds';
END $$;

-- PL7 ---------------------------------------------------------------------
SET LOCAL ROLE authenticated;
SELECT pg_temp.act('b7150000-0000-0000-0000-0000000000a3');
SELECT set_config('pl.d_fin', pg_temp.refused(format($$SELECT public.exos_posh_link_delete_stats(%L)$$, current_setting('pl.s1')::jsonb->>'id'), 'not authorized')::text, true);
SELECT pg_temp.act('b7150000-0000-0000-0000-0000000000a1');
SELECT set_config('pl.d', public.exos_posh_link_delete_stats((current_setting('pl.s1')::jsonb->>'id')::uuid)::text, true);
SELECT set_config('pl.d_again', pg_temp.refused(format($$SELECT public.exos_posh_link_delete_stats(%L)$$, current_setting('pl.s1')::jsonb->>'id'), 'not authorized')::text, true);
RESET ROLE;
DO $$
BEGIN
  ASSERT current_setting('pl.d_fin')::boolean, 'PL7: finance can''t delete';
  ASSERT (current_setting('pl.d')::jsonb->>'deleted')::boolean, 'PL7: owner deletes';
  ASSERT current_setting('pl.d_again')::boolean, 'PL7: gone';
  ASSERT (SELECT count(*) FROM public.exos_discovery_posh_stats WHERE publication_id = current_setting('pl.pub')::uuid) = 1, 'PL7: one left';
  RAISE NOTICE 'OK  PL7 a reading can be deleted by a writer';
END $$;

-- PL8 ---------------------------------------------------------------------
DO $$
DECLARE r record;
BEGIN
  FOR r IN SELECT p.oid::regprocedure AS sig, p.proname, p.proconfig
             FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
            WHERE n.nspname = 'public' AND p.prosecdef
              AND p.proname IN ('_exos_posh_link_blocked', '_exos_posh_link_facts', '_exos_posh_stat_row',
                                'exos_posh_link_record_stats', 'exos_posh_link_delete_stats', 'exos_posh_link_funnel') LOOP
    ASSERT r.proconfig @> ARRAY['search_path=public, pg_temp'], 'PL8: search_path ' || r.sig::text;
    ASSERT NOT has_function_privilege('anon', r.sig, 'EXECUTE'), 'PL8: anon ' || r.sig::text;
    IF r.proname LIKE '\_%' THEN
      ASSERT NOT has_function_privilege('authenticated', r.sig, 'EXECUTE'), 'PL8: helper is internal ' || r.sig::text;
    ELSE
      ASSERT has_function_privilege('authenticated', r.sig, 'EXECUTE'), 'PL8: client RPC ' || r.sig::text;
    END IF;
  END LOOP;
  ASSERT (SELECT count(*) FROM pg_proc WHERE proname IN ('_exos_posh_link_blocked', '_exos_posh_link_facts', '_exos_posh_stat_row',
          'exos_posh_link_record_stats', 'exos_posh_link_delete_stats', 'exos_posh_link_funnel') AND prosecdef) = 6, 'PL8: six definer functions';
  -- The patches are in place.
  ASSERT position('_exos_posh_link_blocked' in pg_get_functiondef('public.exos_discovery_queue(uuid,text,text)'::regprocedure)) > 0, 'PL8: queue patched';
  ASSERT position('_exos_posh_link_facts' in pg_get_functiondef('public.exos_discovery_event_channels(uuid)'::regprocedure)) > 0, 'PL8: event_channels patched';
  RAISE NOTICE 'OK  PL8 grants + search_path on the new definer functions; patches in place';
END $$;

\echo 'test_posh_link_channel: all passed'
ROLLBACK;
