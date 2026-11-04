-- ============================================================================
-- Resale unlocks at a max capacity of 250 (mig 20261014140000):
--   R1 max capacity: overall cap (never above the capped types' sum unless a
--      type has no cap), else the capped types' sum; an uncapped type adds
--      nothing without an overall cap; a table counts as its party size
--   R2 under 250: no allocation, no distribution request (with the reason)
--   R3 under 250: a ticked marketplace makes no event row; 250+ does
--   R4 a ticket type growing past 250 unlocks it (event row made); lowering
--      the overall cap below 250 locks it again (pending row gone)
--   R5 a locked event's pools plan to 0 and refill releases them; the auto
--      split plans nothing
--   R6 S4K: no route under 250; a locked S4K event leaves the feed and its
--      pool is released
--   R7 the operator setting changes the number
--   R8 grants
-- Self-contained (a8 prefix), rolled back. Since mig 20261029090000 the
-- rule is "max capacity over free_tier_max_capacity, and opted in"; this file
-- keeps the 250 cases by setting the cutoff to 249 with no opt-in needed
-- (test_free_tier_resale.sql covers the 150 default and the opt-in). The
-- harness turns the rules off for older fixtures.
-- ============================================================================
\set ON_ERROR_STOP on
BEGIN;
DELETE FROM public.exos_platform_settings WHERE key IN ('free_tier_max_capacity', 'resale_consent_required');
INSERT INTO public.exos_platform_settings (key, value) VALUES ('free_tier_max_capacity', '249'), ('resale_consent_required', 'false');

INSERT INTO auth.users(id,email,email_confirmed_at) VALUES
  ('a8000000-0000-0000-0000-0000000000a0','a8-owner@x.com',now());
INSERT INTO public.exos_orgs(id,name,slug,owner_uid) VALUES
  ('a8000000-0000-0000-0000-000000000001','A8 Org','a8-org','a8000000-0000-0000-0000-0000000000a0');
INSERT INTO public.exos_org_memberships(org_id,user_id,role) VALUES
  ('a8000000-0000-0000-0000-000000000001','a8000000-0000-0000-0000-0000000000a0','owner');
-- e1: 200 (100 + 100). e2: 260 (200 + 60). e3: cap 300 over types of 120.
-- e4: cap 300 with an uncapped type. e5: no cap, 100 + an uncapped type.
INSERT INTO public.exos_events(id,org_id,name,status,starts_at,venue_name,total_tickets,tickets_sold,purchase_limits,timezone,distribution_networks) VALUES
  ('a8000000-0000-0000-0000-0000000000e1','a8000000-0000-0000-0000-000000000001','Small Room','draft',now() + interval '20 days','Hall',0,0,'{"maxPerOrder":4}','America/New_York','{}'),
  ('a8000000-0000-0000-0000-0000000000e2','a8000000-0000-0000-0000-000000000001','Big Room','draft',now() + interval '20 days','Hall',0,0,'{"maxPerOrder":4}','America/New_York','{}'),
  ('a8000000-0000-0000-0000-0000000000e3','a8000000-0000-0000-0000-000000000001','Capped','draft',now() + interval '20 days','Hall',300,0,'{}','America/New_York','{}'),
  ('a8000000-0000-0000-0000-0000000000e4','a8000000-0000-0000-0000-000000000001','Open Cap','draft',now() + interval '20 days','Hall',300,0,'{}','America/New_York','{}'),
  ('a8000000-0000-0000-0000-0000000000e5','a8000000-0000-0000-0000-000000000001','Open','draft',now() + interval '20 days','Hall',0,0,'{}','America/New_York','{}');
INSERT INTO public.exos_ticket_tiers(id,event_id,name,price,capacity,sold,visibility,sort_order) VALUES
  ('a8000000-0000-0000-0000-0000000000d1','a8000000-0000-0000-0000-0000000000e1','GA',40,100,0,'public',1),
  ('a8000000-0000-0000-0000-0000000000d2','a8000000-0000-0000-0000-0000000000e1','VIP',90,100,0,'public',2),
  ('a8000000-0000-0000-0000-0000000000d3','a8000000-0000-0000-0000-0000000000e2','GA',40,200,0,'public',1),
  ('a8000000-0000-0000-0000-0000000000d4','a8000000-0000-0000-0000-0000000000e2','VIP',90,60,0,'public',2),
  ('a8000000-0000-0000-0000-0000000000d5','a8000000-0000-0000-0000-0000000000e3','GA',40,120,0,'public',1),
  ('a8000000-0000-0000-0000-0000000000d6','a8000000-0000-0000-0000-0000000000e4','GA',40,100,0,'public',1),
  ('a8000000-0000-0000-0000-0000000000d7','a8000000-0000-0000-0000-0000000000e4','RSVP',0,0,0,'public',2),
  ('a8000000-0000-0000-0000-0000000000d8','a8000000-0000-0000-0000-0000000000e5','GA',40,100,0,'public',1),
  ('a8000000-0000-0000-0000-0000000000d9','a8000000-0000-0000-0000-0000000000e5','RSVP',0,0,0,'public',2);

CREATE FUNCTION pg_temp.act(p_uid text) RETURNS void LANGUAGE sql AS $$
  SELECT set_config('app.uid', coalesce(p_uid, ''), false), set_config('app.jwt', '{"email":"a8@x.com"}', false);
$$;
CREATE FUNCTION pg_temp.u(p text) RETURNS uuid LANGUAGE sql AS $$ SELECT ('a8000000-0000-0000-0000-0000000000' || p)::uuid $$;
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
CREATE FUNCTION pg_temp.event_row(p_event text, p_ch text) RETURNS public.exos_distribution_listings LANGUAGE sql AS $$
  SELECT * FROM public.exos_distribution_listings WHERE event_id = pg_temp.u(p_event) AND channel = p_ch AND tier_id IS NULL
$$;

-- R1. Max capacity.
DO $$
BEGIN
  ASSERT public.exos_event_max_capacity(pg_temp.u('e1')) = 200, 'R1: e1';
  ASSERT public.exos_event_max_capacity(pg_temp.u('e2')) = 260, 'R1: e2';
  ASSERT public.exos_event_max_capacity(pg_temp.u('e3')) = 120, 'R1: e3 cap above its types';
  ASSERT public.exos_event_max_capacity(pg_temp.u('e4')) = 300, 'R1: e4 cap with an uncapped type';
  ASSERT public.exos_event_max_capacity(pg_temp.u('e5')) = 100, 'R1: e5 uncapped type adds nothing';
  ASSERT NOT public.exos_resale_unlocked(pg_temp.u('e1')) AND public.exos_resale_unlocked(pg_temp.u('e2'))
     AND NOT public.exos_resale_unlocked(pg_temp.u('e3')) AND public.exos_resale_unlocked(pg_temp.u('e4'))
     AND NOT public.exos_resale_unlocked(pg_temp.u('e5')), 'R1: unlocked';
  ASSERT public.exos_resale_min_capacity() = 250, 'R1: 250 (cutoff 249 + 1)';
END $$;

-- R1. A table counts as its party size: 100 GA + 100 tables of 2 = 300.
UPDATE public.exos_ticket_tiers SET kind = 'table', party_size = 2 WHERE id = pg_temp.u('d2');
DO $$
BEGIN
  ASSERT public.exos_event_max_capacity(pg_temp.u('e1')) = 300, 'R1: table party size';
  ASSERT public.exos_resale_unlocked(pg_temp.u('e1')), 'R1: tables unlock';
END $$;
UPDATE public.exos_ticket_tiers SET kind = 'standard', party_size = NULL WHERE id = pg_temp.u('d2');

-- R2 / R3. Publish both with StubHub ticked.
DO $$
BEGIN
  PERFORM pg_temp.act(NULL);
  UPDATE public.exos_events SET status = 'published', distribution_networks = ARRAY['stubhub']
   WHERE id IN (pg_temp.u('e1'), pg_temp.u('e2'));
  ASSERT (pg_temp.event_row('e1', 'stubhub')).id IS NULL, 'R3: no event row under 250';
  ASSERT (pg_temp.event_row('e2', 'stubhub')).status = 'pending', 'R3: event row at 260';
  PERFORM pg_temp.act('a8000000-0000-0000-0000-0000000000a0');
  ASSERT pg_temp.refused($q$SELECT public.exos_set_channel_allocation(pg_temp.u('e1'), 'stubhub', pg_temp.u('d1'), 10)$q$,
                         'need a max capacity over 249 (events of 249 or less are the free tier: no Exos fee, never resold); this event''s is 200'), 'R2: allocation';
  ASSERT pg_temp.refused($q$SELECT public.exos_request_distribution(pg_temp.u('e1'), ARRAY['stubhub'])$q$,
                         'need a max capacity over 249'), 'R2: request';
  ASSERT public.exos_set_channel_allocation(pg_temp.u('e2'), 'stubhub', pg_temp.u('d3'), 10) = 10, 'R2: 260 allocates';
  -- Setting 0 is always fine (taking seats off).
  ASSERT public.exos_set_channel_allocation(pg_temp.u('e1'), 'stubhub', pg_temp.u('d1'), 0) = 0, 'R2: 0 allowed';
END $$;

-- R4. Growing past 250 unlocks; lowering the cap locks.
DO $$
BEGIN
  PERFORM pg_temp.act(NULL);
  UPDATE public.exos_ticket_tiers SET capacity = 160 WHERE id = pg_temp.u('d2');   -- 100 + 160 = 260
  ASSERT (pg_temp.event_row('e1', 'stubhub')).status = 'pending', 'R4: unlocked by a ticket type';
  UPDATE public.exos_events SET total_tickets = 240 WHERE id = pg_temp.u('e1');
  ASSERT (pg_temp.event_row('e1', 'stubhub')).id IS NULL, 'R4: locked by the overall cap';
  UPDATE public.exos_events SET total_tickets = 0 WHERE id = pg_temp.u('e1');
  ASSERT (pg_temp.event_row('e1', 'stubhub')).status = 'pending', 'R4: unlocked again';
END $$;

-- R5. A locked event's pools go to 0; the auto split plans nothing.
DO $$
DECLARE p record; v_alloc uuid;
BEGIN
  SELECT id INTO v_alloc FROM public.exos_distribution_listings WHERE tier_id = pg_temp.u('d3') AND channel = 'stubhub';
  ASSERT (SELECT requested_qty FROM public.exos_distribution_listings WHERE id = v_alloc) > 0, 'R5: pool held';
  ASSERT EXISTS (SELECT 1 FROM public._exos_channel_split_plan(pg_temp.u('e2'))), 'R5: split plans while unlocked';
  -- With the tier trigger off first, so the plan itself is checked: a pool
  -- that is still there (e.g. live on a marketplace) plans 0 when locked.
  ALTER TABLE public.exos_ticket_tiers DISABLE TRIGGER exos_tiers_resale_resync;
  UPDATE public.exos_ticket_tiers SET capacity = 40 WHERE id = pg_temp.u('d4');   -- 200 + 40 = 240
  ALTER TABLE public.exos_ticket_tiers ENABLE TRIGGER exos_tiers_resale_resync;
  SELECT * INTO p FROM public.exos_channel_pool_plan(v_alloc);
  ASSERT p.target = 0 AND p.state = 'locked', 'R5: plan ' || p::text;
  ASSERT NOT EXISTS (SELECT 1 FROM public._exos_channel_split_plan(pg_temp.u('e2'))), 'R5: no auto split';
  PERFORM public.exos_refill_channel_pools();
  ASSERT (SELECT requested_qty FROM public.exos_distribution_listings WHERE id = v_alloc) = 0, 'R5: released';
  ASSERT public.exos_effective_available(pg_temp.u('d3')) = 200, 'R5: all back to Exos';
  -- And through the trigger: an unticked-equivalent pull.
  UPDATE public.exos_ticket_tiers SET capacity = 41 WHERE id = pg_temp.u('d4');
  ASSERT (pg_temp.event_row('e2', 'stubhub')).id IS NULL, 'R5: event row gone';
  ASSERT (SELECT status FROM public.exos_distribution_listings WHERE id = v_alloc) = 'delisted', 'R5: pool pulled';
END $$;

-- R6. S4K.
DO $$
DECLARE r jsonb;
BEGIN
  PERFORM pg_temp.act('a8000000-0000-0000-0000-0000000000a0');
  PERFORM public.exos_set_s4k_network('a8000000-0000-0000-0000-000000000001', true);
  UPDATE public.exos_events SET distribution_networks = '{}' WHERE id IN (pg_temp.u('e1'), pg_temp.u('e2'));
  ASSERT pg_temp.refused($q$SELECT public.exos_set_distribution_route(pg_temp.u('e2'), 's4k')$q$,
                         'this event''s is 241'), 'R6: route under 250';
  PERFORM pg_temp.act(NULL);
  UPDATE public.exos_ticket_tiers SET capacity = 60 WHERE id = pg_temp.u('d4');   -- 260 again
  PERFORM pg_temp.act('a8000000-0000-0000-0000-0000000000a0');
  ASSERT public.exos_set_distribution_route(pg_temp.u('e2'), 's4k') = 's4k', 'R6: route at 260';
  r := public.exos_set_s4k_split(pg_temp.u('e2'), jsonb_build_array(jsonb_build_object('tier_id', pg_temp.u('d3'), 'seats', 20)));
  ASSERT public._exos_feed_eligible(pg_temp.u('e2')), 'R6: on the feed';
  -- The cap comes down: off the feed, the pool released at the next refill.
  PERFORM pg_temp.act(NULL);
  UPDATE public.exos_events SET total_tickets = 200 WHERE id = pg_temp.u('e2');
  ASSERT NOT public._exos_feed_eligible(pg_temp.u('e2')), 'R6: off the feed';
  PERFORM public.exos_refill_channel_pools();
  ASSERT (SELECT requested_qty FROM public.exos_distribution_listings
           WHERE tier_id = pg_temp.u('d3') AND channel = 's4k') = 0, 'R6: S4K pool released';
  PERFORM pg_temp.act('a8000000-0000-0000-0000-0000000000a0');
  ASSERT pg_temp.refused($q$SELECT public.exos_set_s4k_split(pg_temp.u('e2'), '[{"tier_id":"a8000000-0000-0000-0000-0000000000d3","seats":5}]')$q$,
                         'need a max capacity over 249'), 'R6: no split under 250';
END $$;

-- R7. The operator setting.
DO $$
BEGIN
  UPDATE public.exos_platform_settings SET value = '99' WHERE key = 'free_tier_max_capacity';
  ASSERT public.exos_resale_min_capacity() = 100 AND public.exos_resale_unlocked(pg_temp.u('e5')), 'R7: 100';
  UPDATE public.exos_platform_settings SET value = '"oops"' WHERE key = 'free_tier_max_capacity';
  ASSERT public.exos_resale_min_capacity() = 151, 'R7: a bad value falls back to the 150 default';
END $$;

-- R8. Grants.
DO $$
BEGIN
  ASSERT NOT has_table_privilege('authenticated', 'public.exos_platform_settings', 'SELECT'), 'R8: settings';
  ASSERT NOT has_function_privilege('authenticated', 'public.exos_event_max_capacity(uuid)', 'EXECUTE'), 'R8: max capacity';
  ASSERT NOT has_function_privilege('authenticated', 'public.exos_resale_unlocked(uuid)', 'EXECUTE'), 'R8: unlocked';
  ASSERT NOT has_function_privilege('anon', 'public.exos_resale_min_capacity()', 'EXECUTE'), 'R8: not anon (definer)';
  ASSERT has_function_privilege('authenticated', 'public.exos_resale_min_capacity()', 'EXECUTE'), 'R8: the number';
END $$;

\echo 'test_resale_min_capacity: all passed'
ROLLBACK;
