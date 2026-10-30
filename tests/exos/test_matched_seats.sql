-- ============================================================================
-- Matched seats (mig 20261031210000). Self-contained (c4… prefix), rolled back.
--   M1  RLS on, no client writes, only exos_match_public is anon-callable
--   M2  settings + spots: owner / manager only, checks, public read hides spots
--   M3  quiz: intake + per-ticket answers, validation, holders only
--   M4  apply: hard rules re-checked in SQL (order split, max, capacity,
--       blocked pair, unknown / duplicate ticket); late tickets; re-run
--   M5  staff review: move, swap, place a leftover, blocks honoured, lock
--   M6  reveal: nothing before, then spot + first names to holders only;
--       mail to every member, SMS only to the opted-in; idempotent
--   M7  would-meet-again: only after meeting, shown only when mutual
--   M8  safety: report, member block (applies in another org), staff remove
--       with block
--   M9  cross-org isolation
--   M10 retention sweep; due list
--   psql -d <db> -v ON_ERROR_STOP=1 -f tests/exos/test_matched_seats.sql
-- ============================================================================
\set ON_ERROR_STOP on
BEGIN;
GRANT USAGE ON SCHEMA auth TO anon, authenticated;

CREATE FUNCTION pg_temp.u(p text) RETURNS uuid LANGUAGE sql IMMUTABLE AS $$
  SELECT ('c4000000-0000-0000-0000-' || lpad(p, 12, '0'))::uuid $$;

INSERT INTO auth.users(id,email,email_confirmed_at)
SELECT pg_temp.u(x), 'ms-' || x || '@x.com', now()
  FROM unnest(ARRAY['a0','a1','a2','b1','b2','b3','b4','b5','b6','b7','b9']) x;
INSERT INTO public.exos_orgs(id,name,slug,owner_uid) VALUES
  (pg_temp.u('01'),'MS Org','ms-org',pg_temp.u('a0')),
  (pg_temp.u('02'),'MS Other','ms-other',pg_temp.u('a2'));
INSERT INTO public.exos_org_memberships(org_id,user_id,role) VALUES
  (pg_temp.u('01'),pg_temp.u('a0'),'owner'),
  (pg_temp.u('01'),pg_temp.u('a1'),'scanner'),
  (pg_temp.u('02'),pg_temp.u('a2'),'owner');
INSERT INTO public.exos_events(id,org_id,name,slug,status,starts_at,timezone) VALUES
  (pg_temp.u('e1'),pg_temp.u('01'),'Dinner <with> Strangers','ms-dinner','published', now() + interval '30 hours','America/New_York'),
  (pg_temp.u('e2'),pg_temp.u('02'),'Other Supper','ms-other','published', now() + interval '10 hours','UTC');
INSERT INTO public.exos_ticket_tiers(id,event_id,name,price,capacity) VALUES
  (pg_temp.u('d1'),pg_temp.u('e1'),'Seat',40,20),
  (pg_temp.u('d2'),pg_temp.u('e1'),'GA',10,20),
  (pg_temp.u('d3'),pg_temp.u('e2'),'Seat',40,20);
INSERT INTO public.exos_tickets(id,event_id,org_id,tier_id,tier_name,buyer_id,owner_id,buyer_email,status,barcode_secret,price_paid,order_ref,attendee_name)
SELECT pg_temp.u(t), pg_temp.u(ev), pg_temp.u(org), pg_temp.u(tier), 'Seat', o, o, be, 'active', gen_random_uuid()::text, 40, ord, nm
  FROM (VALUES
    ('c01','e1','01','d1',pg_temp.u('b1'),NULL,'o1','Ana Maria Lopez'),
    ('c02','e1','01','d1',pg_temp.u('b1'),NULL,'o1',NULL),
    ('c03','e1','01','d1',pg_temp.u('b2'),NULL,'o3','Ben Smith'),
    ('c04','e1','01','d1',pg_temp.u('b3'),NULL,'o4','Cleo'),
    ('c05','e1','01','d1',pg_temp.u('b4'),NULL,'o5','Dev'),
    ('c06','e1','01','d1',pg_temp.u('b5'),NULL,'o6','Eve'),
    ('c07','e1','01','d1',pg_temp.u('b6'),NULL,'o7','Finn'),
    ('c08','e1','01','d1',pg_temp.u('b7'),NULL,'o8','Gus'),
    ('c09','e1','01','d1',NULL,'guest@x.com','o9','Hana'),
    ('c10','e2','02','d3',pg_temp.u('b2'),NULL,'p1','Ben'),
    ('c11','e2','02','d3',pg_temp.u('b3'),NULL,'p2','Cleo'),
    ('c12','e2','02','d3',pg_temp.u('b4'),NULL,'p3','Dev')
  ) v(t, ev, org, tier, o, be, ord, nm);
INSERT INTO public.exos_checkout_sessions(session_id,event_id,tier_id,org_id,buyer_uid,quantity,amount_cents,status,ticket_ids)
VALUES ('cs_ms_6', pg_temp.u('e1'), pg_temp.u('d1'), pg_temp.u('01'), pg_temp.u('b5'), 1, 4000, 'fulfilled', ARRAY[pg_temp.u('c06')]);
-- SMS: the org texts from Twilio; b3 opted in, b4 opted in then out.
INSERT INTO public.exos_org_integrations(org_id, provider, config, status) VALUES (pg_temp.u('01'), 'twilio', '{"from":"+12125550199"}', 'connected');
INSERT INTO public.exos_sms_subscribers(org_id, phone, user_id, consent_text, opted_out_at) VALUES
  (pg_temp.u('01'), '+12125550133', pg_temp.u('b3'), 'Yes, text me about MS Org events. Reply STOP to opt out.', NULL),
  (pg_temp.u('01'), '+12125550144', pg_temp.u('b4'), 'Yes, text me about MS Org events. Reply STOP to opt out.', now());
-- A staff block in org 01 between b5 and b6.
INSERT INTO public.exos_match_blocks(org_id, a_key, b_key, source) VALUES
  (pg_temp.u('01'), pg_temp.u('b5')::text, pg_temp.u('b6')::text, 'staff');

-- M1 ---------------------------------------------------------------------------
DO $$
DECLARE t text; f text;
BEGIN
  FOREACH t IN ARRAY ARRAY['exos_match_configs','exos_match_spots','exos_match_intake','exos_match_answers',
      'exos_social_groups','exos_social_group_members','exos_match_leftovers','exos_match_picks',
      'exos_match_reports','exos_match_blocks'] LOOP
    ASSERT (SELECT relrowsecurity FROM pg_class WHERE oid = ('public.' || t)::regclass), 'M1: RLS off on ' || t;
    ASSERT NOT has_table_privilege('anon', 'public.' || t, 'SELECT'), 'M1: anon reads ' || t;
    ASSERT NOT has_table_privilege('authenticated', 'public.' || t, 'INSERT'), 'M1: authenticated inserts ' || t;
    ASSERT NOT has_table_privilege('authenticated', 'public.' || t, 'UPDATE'), 'M1: authenticated updates ' || t;
    ASSERT NOT has_table_privilege('authenticated', 'public.' || t, 'DELETE'), 'M1: authenticated deletes ' || t;
  END LOOP;
  FOREACH t IN ARRAY ARRAY['exos_match_intake','exos_match_answers','exos_match_picks'] LOOP
    ASSERT NOT has_table_privilege('authenticated', 'public.' || t, 'SELECT'), 'M1: authenticated reads ' || t;
  END LOOP;
  ASSERT has_function_privilege('anon', 'public.exos_match_public(uuid)', 'EXECUTE'), 'M1: anon public read';
  FOR f IN SELECT p.oid::regprocedure::text FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
            WHERE n.nspname = 'public' AND (p.proname LIKE 'exos\_match\_%' OR p.proname LIKE '\_exos\_match\_%')
              AND p.proname <> 'exos_match_public' LOOP
    ASSERT NOT has_function_privilege('anon', f, 'EXECUTE'), 'M1: anon can call ' || f;
  END LOOP;
  FOREACH f IN ARRAY ARRAY['public.exos_match_inputs(uuid,uuid)','public.exos_match_apply(uuid,uuid,bigint,jsonb)',
      'public.exos_match_due()','public.exos_match_reveal_due()','public.exos_match_sweep()',
      'public._exos_match_reveal(uuid)','public._exos_match_staff_cfg(uuid,uuid)'] LOOP
    ASSERT NOT has_function_privilege('authenticated', f, 'EXECUTE'), 'M1: authenticated can call ' || f;
  END LOOP;
  FOR f IN SELECT p.oid::regprocedure::text FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
            WHERE n.nspname = 'public' AND p.prosecdef AND p.proname LIKE '%exos%match%'
              AND NOT ('search_path=public, pg_temp' = ANY (coalesce(p.proconfig, '{}'))) LOOP
    RAISE EXCEPTION 'M1: % has no fixed search_path', f;
  END LOOP;
  RAISE NOTICE 'OK  M1 RLS, grants, anon surface, search_path';
END $$;

-- M2 ---------------------------------------------------------------------------
SET LOCAL ROLE authenticated;
DO $$
BEGIN
  PERFORM set_config('app.uid', pg_temp.u('a1')::text, true);   -- scanner
  BEGIN
    PERFORM public.exos_match_set_config(pg_temp.u('d1'), '{}');
    RAISE EXCEPTION 'M2: scanner set config';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  PERFORM set_config('app.uid', pg_temp.u('a2')::text, true);   -- other org's owner
  BEGIN
    PERFORM public.exos_match_set_config(pg_temp.u('d1'), '{}');
    RAISE EXCEPTION 'M2: other org set config';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  PERFORM public.exos_match_set_config(pg_temp.u('d3'),
    '{"group_min":1,"group_target":2,"group_max":3,"match_hours_before":12,"reveal_hours_before":2}');

  PERFORM set_config('app.uid', pg_temp.u('a0')::text, true);   -- owner
  BEGIN
    PERFORM public.exos_match_set_config(pg_temp.u('d1'), '{"group_min":6,"group_target":4,"group_max":5}');
    RAISE EXCEPTION 'M2: min > target accepted';
  EXCEPTION WHEN invalid_parameter_value THEN NULL;
  END;
  BEGIN
    PERFORM public.exos_match_set_config(pg_temp.u('d1'), '{"match_hours_before":2,"reveal_hours_before":5}');
    RAISE EXCEPTION 'M2: reveal before cutoff accepted';
  EXCEPTION WHEN invalid_parameter_value THEN NULL;
  END;
  BEGIN
    PERFORM public.exos_match_set_config(pg_temp.u('d1'), '{"quiz_languages":["english"]}');
    RAISE EXCEPTION 'M2: bad language code accepted';
  EXCEPTION WHEN invalid_parameter_value THEN NULL;
  END;
  PERFORM public.exos_match_set_config(pg_temp.u('d1'),
    '{"group_min":2,"group_target":4,"group_max":5,"match_hours_before":24,"reveal_hours_before":3,
      "undersub_policy":"refund","quiz_tags":["Food","wine","Hiking"," "],"quiz_languages":["en","es"],"retention_days":7}');
  ASSERT (SELECT quiz_tags FROM public.exos_match_configs WHERE tier_id = pg_temp.u('d1')) = ARRAY['food','hiking','wine'],
    'M2: tags normalized';
  PERFORM public.exos_match_upsert_spot(pg_temp.u('d1'), '{"name":"Trattoria Uno","address":"1 Main St","details":"Ask for the Exos table","capacity":5}');
  PERFORM public.exos_match_upsert_spot(pg_temp.u('d1'), '{"name":"Bar Due","address":"2 Main St","capacity":5,"sort_order":1}');
  BEGIN
    PERFORM public.exos_match_upsert_spot(pg_temp.u('d1'), '{"name":"","capacity":0}');
    RAISE EXCEPTION 'M2: empty spot accepted';
  EXCEPTION WHEN invalid_parameter_value THEN NULL;
  END;
  ASSERT (SELECT count(*) FROM public.exos_match_spots) = 2, 'M2: owner reads spots through RLS';
  RAISE NOTICE 'OK  M2 settings and spots: owner / manager only, checks';
END $$;
RESET ROLE;

SET LOCAL ROLE anon;
DO $$
DECLARE r record; v text;
BEGIN
  SELECT * INTO r FROM public.exos_match_public(pg_temp.u('e1'));
  ASSERT r.tier_id = pg_temp.u('d1') AND r.spot_count = 2 AND r.group_max = 5 AND r.status = 'open', 'M2: public row';
  ASSERT r.match_at < r.reveal_at, 'M2: reveal after the cutoff';
  SELECT string_agg(x::text, '') INTO v FROM public.exos_match_public(pg_temp.u('e1')) x;
  ASSERT position('Trattoria' in v) = 0, 'M2: public read leaks a spot';
  RAISE NOTICE 'OK  M2 anon reads sizes + quiz options only';
END $$;
RESET ROLE;
UPDATE public.exos_events SET status = 'draft' WHERE id = pg_temp.u('e1');
SET LOCAL ROLE anon;
DO $$ BEGIN
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_match_public(pg_temp.u('e1'))), 'M2: a draft event is public';
  RAISE NOTICE 'OK  M2 drafts stay hidden';
END $$;
RESET ROLE;
UPDATE public.exos_events SET status = 'published' WHERE id = pg_temp.u('e1');

-- M3 ---------------------------------------------------------------------------
SET LOCAL ROLE authenticated;
DO $$
DECLARE a jsonb;
BEGIN
  PERFORM set_config('app.uid', pg_temp.u('b2')::text, true);
  a := public.exos_match_save_intake(pg_temp.u('d1'),
    '{"age_band":"25-34","language":"es","tags":["food","wine"],"mode":"solo","display_name":"  Benji <b>Smith"}');
  ASSERT a ->> 'display_name' = 'Benji', 'M3: first name only, got ' || coalesce(a ->> 'display_name', 'null');
  BEGIN
    PERFORM public.exos_match_save_intake(pg_temp.u('d1'), '{"language":"fr"}');
    RAISE EXCEPTION 'M3: unlisted language accepted';
  EXCEPTION WHEN invalid_parameter_value THEN NULL;
  END;
  BEGIN
    PERFORM public.exos_match_save_intake(pg_temp.u('d1'), '{"tags":["golf"]}');
    RAISE EXCEPTION 'M3: unlisted tag accepted';
  EXCEPTION WHEN invalid_parameter_value THEN NULL;
  END;
  BEGIN
    PERFORM public.exos_match_save_intake(pg_temp.u('d1'), '{"age_band":"1990-05-01"}');
    RAISE EXCEPTION 'M3: a birthdate accepted';
  EXCEPTION WHEN invalid_parameter_value THEN NULL;
  END;
  BEGIN
    PERFORM public.exos_match_set_answers(pg_temp.u('c01'), '{"language":"en"}');   -- b1's ticket
    RAISE EXCEPTION 'M3: answered someone else''s ticket';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  PERFORM set_config('app.uid', pg_temp.u('b1')::text, true);
  a := public.exos_match_set_answers(pg_temp.u('c01'), '{"language":"en","party_code":"ab-12","age_band":"35-44"}');
  ASSERT a ->> 'party_code' = 'AB12', 'M3: party code normalized';
  PERFORM set_config('app.uid', pg_temp.u('b3')::text, true);
  PERFORM public.exos_match_set_answers(pg_temp.u('c04'), '{"language":"en"}');
  PERFORM public.exos_match_clear_answers(pg_temp.u('c04'));
  PERFORM set_config('app.uid', '', true);
  BEGIN
    PERFORM public.exos_match_save_intake(pg_temp.u('d1'), '{}');
    RAISE EXCEPTION 'M3: signed-out intake';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  RAISE NOTICE 'OK  M3 quiz: validated, minimal, holders only';
END $$;
RESET ROLE;
DO $$ BEGIN
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_match_answers WHERE ticket_id = pg_temp.u('c04')), 'M3: answers cleared';
  ASSERT (SELECT count(*) FROM public.exos_match_intake) = 1, 'M3: one intake row';
END $$;

-- M4 ---------------------------------------------------------------------------
-- Runs as the service (the exos-match function).
CREATE FUNCTION pg_temp.res(g jsonb, l jsonb DEFAULT '[]') RETURNS jsonb LANGUAGE sql AS $$
  SELECT jsonb_build_object('groups', g, 'leftovers', l) $$;
CREATE FUNCTION pg_temp.grp(spot text, VARIADIC t text[]) RETURNS jsonb LANGUAGE sql AS $$
  SELECT jsonb_build_object('spotId', (SELECT id FROM public.exos_match_spots WHERE name = spot),
                            'ticketIds', (SELECT jsonb_agg(pg_temp.u(x)) FROM unnest(t) x), 'score', 1) $$;
DO $$
DECLARE j jsonb; bad jsonb; v text;
BEGIN
  BEGIN
    PERFORM public.exos_match_inputs(pg_temp.u('d1'), pg_temp.u('a1'));     -- scanner via "Match now"
    RAISE EXCEPTION 'M4: scanner ran matching';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  j := public.exos_match_inputs(pg_temp.u('d1'), pg_temp.u('a0'));
  ASSERT jsonb_array_length(j -> 'members') = 9, 'M4: 9 holders, got ' || jsonb_array_length(j -> 'members');
  ASSERT jsonb_array_length(j -> 'spots') = 2, 'M4: 2 spots';
  ASSERT (SELECT count(*) FROM jsonb_array_elements(j -> 'members') m
           WHERE m ->> 'ticketId' = pg_temp.u('c03')::text AND m ->> 'language' = 'es') = 1, 'M4: intake copied to the ticket';
  ASSERT (SELECT count(*) FROM jsonb_array_elements(j -> 'members') m
           WHERE m ->> 'userKey' = 'email:guest@x.com') = 1, 'M4: guest keyed by email';
  ASSERT (j -> 'blocks') @> jsonb_build_array(jsonb_build_array(pg_temp.u('b5')::text, pg_temp.u('b6')::text)), 'M4: staff block in inputs';
  v := j::text;
  ASSERT position('ms-b' in v) = 0, 'M4: inputs carry an email of an account';

  FOR bad IN SELECT x FROM unnest(ARRAY[
      pg_temp.res(jsonb_build_array(pg_temp.grp('Trattoria Uno','c01','c03'), pg_temp.grp('Bar Due','c02','c04'))),  -- order split
      pg_temp.res(jsonb_build_array(pg_temp.grp('Trattoria Uno','c01','c02','c03','c04','c05','c07'))),             -- above max
      pg_temp.res(jsonb_build_array(pg_temp.grp('Trattoria Uno','c01','c02','c03'), pg_temp.grp('Trattoria Uno','c04','c05','c08'))), -- spot over capacity
      pg_temp.res(jsonb_build_array(pg_temp.grp('Trattoria Uno','c06','c07'))),                                    -- blocked pair
      pg_temp.res(jsonb_build_array(pg_temp.grp('Trattoria Uno','c03','c10'))),                                    -- another tier's ticket
      pg_temp.res(jsonb_build_array(pg_temp.grp('Trattoria Uno','c03')), jsonb_build_array(jsonb_build_object('ticketId', pg_temp.u('c03'))))  -- twice
    ]) x LOOP
    BEGIN
      PERFORM public.exos_match_apply(pg_temp.u('d1'), NULL, 7, bad);
      RAISE EXCEPTION 'M4: accepted %', bad;
    EXCEPTION WHEN invalid_parameter_value THEN NULL;
    END;
  END LOOP;

  j := public.exos_match_apply(pg_temp.u('d1'), pg_temp.u('a0'), 7,
         pg_temp.res(jsonb_build_array(pg_temp.grp('Trattoria Uno','c01','c02','c03','c04'),
                                       pg_temp.grp('Bar Due','c05','c07','c08')),
                     jsonb_build_array(jsonb_build_object('ticketId', pg_temp.u('c06'), 'reason', 'no_room'))));
  ASSERT (j ->> 'groups')::int = 2 AND (j ->> 'placed')::int = 7 AND (j ->> 'leftovers')::int = 2, 'M4: apply summary ' || j;
  ASSERT (SELECT reason FROM public.exos_match_leftovers WHERE ticket_id = pg_temp.u('c09')) = 'late', 'M4: unmentioned = late';
  ASSERT (SELECT status FROM public.exos_match_configs WHERE tier_id = pg_temp.u('d1')) = 'matched', 'M4: matched';
  ASSERT (SELECT count(*) FROM public.exos_social_group_members m JOIN public.exos_social_groups g ON g.id = m.group_id
           WHERE g.tier_id = pg_temp.u('d1') AND m.org_id = pg_temp.u('01') AND m.kind = 'matched_seats') = 7, 'M4: members filled from group';
  -- A re-run while every group is still a draft replaces them.
  j := public.exos_match_apply(pg_temp.u('d1'), NULL, 8,
         pg_temp.res(jsonb_build_array(pg_temp.grp('Trattoria Uno','c01','c02','c03','c04'),
                                       pg_temp.grp('Bar Due','c05','c07','c08')),
                     jsonb_build_array(jsonb_build_object('ticketId', pg_temp.u('c06'), 'reason', 'no_room'))));
  ASSERT (SELECT count(*) FROM public.exos_social_groups WHERE tier_id = pg_temp.u('d1')) = 2, 'M4: re-run replaced';
  ASSERT (SELECT seed FROM public.exos_match_configs WHERE tier_id = pg_temp.u('d1')) = 8, 'M4: seed stored';
  RAISE NOTICE 'OK  M4 apply re-checks every hard rule; late tickets; re-run';
END $$;

-- Sizes are fixed once matched.
SET LOCAL ROLE authenticated;
DO $$ BEGIN
  PERFORM set_config('app.uid', pg_temp.u('a0')::text, true);
  BEGIN
    PERFORM public.exos_match_set_config(pg_temp.u('d1'), '{"group_max":9}');
    RAISE EXCEPTION 'M4: resized after matching';
  EXCEPTION WHEN object_not_in_prerequisite_state THEN NULL;
  END;
  PERFORM public.exos_match_set_config(pg_temp.u('d1'), '{"reveal_hours_before":4}');    -- reveal time may move
  PERFORM set_config('app.uid', pg_temp.u('b4')::text, true);
  BEGIN
    PERFORM public.exos_match_set_answers(pg_temp.u('c05'), '{"language":"en"}');
    RAISE EXCEPTION 'M4: answers after matching';
  EXCEPTION WHEN object_not_in_prerequisite_state THEN NULL;
  END;
  RAISE NOTICE 'OK  M4 sizes and answers frozen after matching';
END $$;
RESET ROLE;

-- M5 ---------------------------------------------------------------------------
CREATE FUNCTION pg_temp.mem(t text) RETURNS uuid LANGUAGE sql AS $$
  SELECT id FROM public.exos_social_group_members WHERE ticket_id = pg_temp.u(t) AND status = 'active' $$;
CREATE FUNCTION pg_temp.grp_of(t text) RETURNS uuid LANGUAGE sql AS $$
  SELECT group_id FROM public.exos_social_group_members WHERE ticket_id = pg_temp.u(t) AND status = 'active' $$;
CREATE TEMP TABLE ms_ids AS
  SELECT pg_temp.grp_of('c01') AS g1, pg_temp.grp_of('c05') AS g2,
         pg_temp.mem('c04') AS m4, pg_temp.mem('c05') AS m5;
GRANT SELECT ON ms_ids TO authenticated;
SET LOCAL ROLE authenticated;
DO $$
DECLARE v jsonb; i record;
BEGIN
  SELECT * INTO i FROM ms_ids;
  PERFORM set_config('app.uid', pg_temp.u('a1')::text, true);
  BEGIN
    PERFORM public.exos_match_staff_view(pg_temp.u('d1'));
    RAISE EXCEPTION 'M5: scanner read the review';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  PERFORM set_config('app.uid', pg_temp.u('a0')::text, true);
  v := public.exos_match_staff_view(pg_temp.u('d1'));
  ASSERT jsonb_array_length(v -> 'groups') = 2, 'M5: 2 groups';
  ASSERT (SELECT l ->> 'session_id' FROM jsonb_array_elements(v -> 'leftovers') l
           WHERE l ->> 'ticket_id' = pg_temp.u('c06')::text) = 'cs_ms_6', 'M5: leftover carries its order for the refund';
  ASSERT (v -> 'config' ->> 'reveal_at') IS NOT NULL, 'M5: times in the review';
  -- Place leftover c06 (b5) in g2: b6 sits there and staff blocked b5/b6.
  BEGIN
    PERFORM public.exos_match_move(i.g2, NULL, pg_temp.u('c06'));
    RAISE EXCEPTION 'M5: placed a blocked pair together';
  EXCEPTION WHEN invalid_parameter_value THEN NULL;
  END;
  PERFORM public.exos_match_move(i.g1, NULL, pg_temp.u('c06'));       -- g1 now 5 (max)
  BEGIN
    PERFORM public.exos_match_move(i.g1, NULL, pg_temp.u('c09'));
    RAISE EXCEPTION 'M5: overfilled a group';
  EXCEPTION WHEN invalid_parameter_value THEN NULL;
  END;
  PERFORM public.exos_match_move(i.g2, NULL, pg_temp.u('c09'));       -- g2 now 4
  PERFORM public.exos_match_swap(i.m4, i.m5);
  ASSERT pg_temp.grp_of('c04') = i.g2 AND pg_temp.grp_of('c05') = i.g1, 'M5: swapped';
  ASSERT (SELECT count(*) FROM public.exos_match_leftovers WHERE tier_id = pg_temp.u('d1')) = 0, 'M5: leftovers placed';
  PERFORM public.exos_match_move(i.g2, pg_temp.mem('c05'), NULL);     -- move back c05 -> g2 is 5
  PERFORM public.exos_match_move(i.g1, pg_temp.mem('c05'), NULL);
  ASSERT public.exos_match_lock(pg_temp.u('d1'), true) = 2, 'M5: two groups locked';
  RAISE NOTICE 'OK  M5 review: move, swap, place, blocks and sizes honoured, lock';
END $$;
RESET ROLE;
DO $$ BEGIN
  BEGIN
    PERFORM public.exos_match_apply(pg_temp.u('d1'), NULL, 9, pg_temp.res('[]'::jsonb));
    RAISE EXCEPTION 'M5: re-run over locked groups';
  EXCEPTION WHEN object_not_in_prerequisite_state THEN NULL;
  END;
  RAISE NOTICE 'OK  M5 a locked review is not overwritten';
END $$;

-- Member ids as the service sees them (holders can't read member rows).
CREATE TEMP TABLE ms_mem AS
  SELECT replace(right(ticket_id::text, 3), '0', '') AS k, ticket_id, id FROM public.exos_social_group_members
   WHERE kind = 'matched_seats';
GRANT SELECT ON ms_mem TO authenticated;
CREATE FUNCTION pg_temp.mm(t text) RETURNS uuid LANGUAGE sql AS $$
  SELECT id FROM ms_mem WHERE ticket_id = pg_temp.u(t) $$;

-- M6 ---------------------------------------------------------------------------
-- g1: c01 c02 (b1), c03 (b2), c05 (b4), c06 (b5)   g2: c04 (b3), c07 (b6), c08 (b7), c09 (guest)
SET LOCAL ROLE authenticated;
DO $$
DECLARE v jsonb;
BEGIN
  PERFORM set_config('app.uid', pg_temp.u('b2')::text, true);
  v := public.exos_match_my_group(pg_temp.u('c03'));
  ASSERT v ->> 'state' = 'matched' AND (v ->> 'group_size')::int = 5, 'M6: matched, hidden: ' || v;
  ASSERT position('Trattoria' in v::text) = 0 AND position('Ana' in v::text) = 0, 'M6: leaked before reveal';
  PERFORM set_config('app.uid', pg_temp.u('b9')::text, true);
  ASSERT public.exos_match_my_group(pg_temp.u('c03')) ->> 'state' = 'not_holder', 'M6: stranger';
  PERFORM set_config('app.uid', pg_temp.u('b1')::text, true);
  BEGIN
    PERFORM public.exos_match_reveal_now(pg_temp.u('d1'));
    RAISE EXCEPTION 'M6: a holder revealed';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  PERFORM set_config('app.uid', pg_temp.u('a0')::text, true);
  ASSERT public.exos_match_reveal_now(pg_temp.u('d1')) = 9, 'M6: 9 members notified';
  ASSERT public.exos_match_reveal_now(pg_temp.u('d1')) = 0, 'M6: second reveal sends nothing';
  PERFORM set_config('app.uid', pg_temp.u('b2')::text, true);
  v := public.exos_match_my_group(pg_temp.u('c03'));
  ASSERT v ->> 'state' = 'revealed', 'M6: revealed';
  ASSERT v -> 'spot' ->> 'name' = 'Trattoria Uno' AND v -> 'spot' ->> 'details' = 'Ask for the Exos table', 'M6: spot';
  ASSERT (SELECT string_agg(m ->> 'first_name', ',' ORDER BY m ->> 'first_name') FROM jsonb_array_elements(v -> 'members') m)
         = 'Ana,Benji,Dev,Eve,Guest', 'M6: first names: ' || (v -> 'members');
  ASSERT position('@' in v::text) = 0 AND position('Lopez' in v::text) = 0 AND position('Smith' in v::text) = 0,
    'M6: more than first names';
  ASSERT NOT (v ->> 'after_event')::boolean, 'M6: not met yet';
  RAISE NOTICE 'OK  M6 reveal: hidden before, spot + first names after, holders only';
END $$;
RESET ROLE;
DO $$
DECLARE h text;
BEGIN
  ASSERT (SELECT count(*) FROM public.exos_mail WHERE template = 'matched-reveal') = 9, 'M6: one mail per member';
  ASSERT (SELECT count(*) FROM public.exos_mail WHERE template = 'matched-reveal' AND to_email = 'guest@x.com') = 1, 'M6: guest mailed';
  SELECT html INTO h FROM public.exos_mail WHERE template = 'matched-reveal' AND to_email = 'ms-b3@x.com';
  ASSERT position('Bar Due' in h) > 0 AND position('&lt;with&gt;' in h) > 0 AND position('<with>' in h) = 0, 'M6: mail escaped: ' || h;
  ASSERT position('Cleo' in h) = 0 AND position('Finn' in h) > 0, 'M6: mail lists the others';
  ASSERT (SELECT count(*) FROM public.exos_sms_outbox) = 1, 'M6: one text (b3 opted in; b4 opted out)';
  ASSERT (SELECT phone FROM public.exos_sms_outbox) = '+12125550133', 'M6: to b3';
  ASSERT (SELECT body FROM public.exos_sms_outbox) LIKE '%Bar Due%Reply STOP to opt out.', 'M6: text body';
  RAISE NOTICE 'OK  M6 email to every member, SMS only where opted in';
END $$;

-- M7 ---------------------------------------------------------------------------
SET LOCAL ROLE authenticated;
DO $$ BEGIN
  PERFORM set_config('app.uid', pg_temp.u('b2')::text, true);
  BEGIN
    PERFORM public.exos_match_pick(pg_temp.u('c03'), pg_temp.mm('c05'), true);
    RAISE EXCEPTION 'M7: picked before meeting';
  EXCEPTION WHEN object_not_in_prerequisite_state THEN NULL;
  END;
END $$;
RESET ROLE;
UPDATE public.exos_social_groups SET meet_at = now() - interval '2 hours' WHERE tier_id = pg_temp.u('d1');
SET LOCAL ROLE authenticated;
DO $$
DECLARE v jsonb;
BEGIN
  PERFORM set_config('app.uid', pg_temp.u('b2')::text, true);
  ASSERT NOT public.exos_match_pick(pg_temp.u('c03'), pg_temp.mm('c05'), true), 'M7: one-sided is not mutual';
  BEGIN
    PERFORM public.exos_match_pick(pg_temp.u('c03'), pg_temp.mm('c04'), true);    -- c04 is in the other group
    RAISE EXCEPTION 'M7: picked outside the group';
  EXCEPTION WHEN invalid_parameter_value THEN NULL;
  END;
  v := public.exos_match_my_group(pg_temp.u('c03'));
  ASSERT (SELECT bool_or((m ->> 'mutual')::boolean) FROM jsonb_array_elements(v -> 'members') m) = false, 'M7: nothing mutual yet';
  PERFORM set_config('app.uid', pg_temp.u('b4')::text, true);
  v := public.exos_match_my_group(pg_temp.u('c05'));
  ASSERT (SELECT bool_or((m ->> 'picked')::boolean) FROM jsonb_array_elements(v -> 'members') m) = false,
    'M7: b4 sees who picked them';
  ASSERT public.exos_match_pick(pg_temp.u('c05'), pg_temp.mm('c03'), true), 'M7: mutual';
  PERFORM set_config('app.uid', pg_temp.u('b2')::text, true);
  v := public.exos_match_my_group(pg_temp.u('c03'));
  ASSERT (SELECT (m ->> 'mutual')::boolean FROM jsonb_array_elements(v -> 'members') m WHERE m ->> 'first_name' = 'Dev'), 'M7: b2 sees the match';
  PERFORM set_config('app.uid', pg_temp.u('b1')::text, true);
  v := public.exos_match_my_group(pg_temp.u('c01'));
  ASSERT (SELECT bool_or((m ->> 'mutual')::boolean OR (m ->> 'picked')::boolean) FROM jsonb_array_elements(v -> 'members') m) = false,
    'M7: a third member sees others'' picks';
  RAISE NOTICE 'OK  M7 would-meet-again: after meeting, shown only when mutual';
END $$;
RESET ROLE;

-- M8 ---------------------------------------------------------------------------
SET LOCAL ROLE authenticated;
DO $$
DECLARE v_id uuid; v jsonb;
BEGIN
  PERFORM set_config('app.uid', pg_temp.u('b4')::text, true);
  v_id := public.exos_match_report(pg_temp.u('c05'), pg_temp.mm('c03'), 'harassment', 'kept asking for my number');
  BEGIN
    PERFORM public.exos_match_report(pg_temp.u('c05'), pg_temp.mm('c04'), 'other');   -- not in b4's group
    RAISE EXCEPTION 'M8: reported outside the group';
  EXCEPTION WHEN invalid_parameter_value THEN NULL;
  END;
  PERFORM public.exos_match_block(pg_temp.u('c05'), pg_temp.mm('c03'));              -- b4 blocks b2
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_match_blocks WHERE source = 'member'), 'M8: member blocks hidden from members';
  PERFORM set_config('app.uid', pg_temp.u('a0')::text, true);
  v := public.exos_match_staff_view(pg_temp.u('d1'));
  ASSERT (SELECT count(*) FROM jsonb_array_elements(v -> 'reports') r WHERE r ->> 'reason' = 'harassment') = 1, 'M8: staff see the report';
  PERFORM public.exos_match_review_report(v_id, 'actioned');
  PERFORM public.exos_match_remove_member(pg_temp.mm('c03'), 'reported', true);
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_match_blocks WHERE source = 'member'), 'M8: staff don''t see member blocks';
  ASSERT (SELECT count(*) FROM public.exos_match_blocks WHERE source = 'staff' AND (a_key = pg_temp.u('b2')::text)) = 3,
    'M8: staff block vs the 3 other holders of g1';
  PERFORM set_config('app.uid', pg_temp.u('b2')::text, true);
  ASSERT public.exos_match_my_group(pg_temp.u('c03')) ->> 'state' = 'removed', 'M8: removed';
  RAISE NOTICE 'OK  M8 report, block, staff remove with block';
END $$;
RESET ROLE;
DO $$ BEGIN
  ASSERT (SELECT count(*) FROM public.exos_match_blocks WHERE source = 'member'
           AND a_key = pg_temp.u('b4')::text AND b_key = pg_temp.u('b2')::text) = 1, 'M8: member block stored';
  ASSERT (SELECT reviewed_by FROM public.exos_match_reports) = pg_temp.u('a0'), 'M8: review recorded';
END $$;
-- The member block applies in the other org too: b2 (c10) and b4 (c12).
DO $$
DECLARE j jsonb;
BEGIN
  j := public.exos_match_inputs(pg_temp.u('d3'));
  ASSERT (j -> 'blocks') @> jsonb_build_array(jsonb_build_array(pg_temp.u('b4')::text, pg_temp.u('b2')::text)), 'M8: member block crosses orgs';
  ASSERT NOT ((j -> 'blocks') @> jsonb_build_array(jsonb_build_array(pg_temp.u('b2')::text, pg_temp.u('b1')::text))), 'M8: org 01 staff block leaked to org 02';
  PERFORM set_config('app.uid', pg_temp.u('a2')::text, true);
  PERFORM public.exos_match_upsert_spot(pg_temp.u('d3'), '{"name":"Other Spot","capacity":6}');
  BEGIN
    PERFORM public.exos_match_apply(pg_temp.u('d3'), NULL, 1,
      pg_temp.res(jsonb_build_array(pg_temp.grp('Other Spot','c10','c12','c11'))));
    RAISE EXCEPTION 'M8: blocked pair grouped in another org';
  EXCEPTION WHEN invalid_parameter_value THEN NULL;
  END;
  RAISE NOTICE 'OK  M8 a member''s block holds in every org''s matching';
END $$;

-- M9 ---------------------------------------------------------------------------
SET LOCAL ROLE authenticated;
DO $$ BEGIN
  PERFORM set_config('app.uid', pg_temp.u('a2')::text, true);
  ASSERT (SELECT count(*) FROM public.exos_social_groups) = 0, 'M9: other org sees groups';
  ASSERT (SELECT count(*) FROM public.exos_match_spots) = 1, 'M9: other org sees spots';
  ASSERT (SELECT count(*) FROM public.exos_match_reports) = 0, 'M9: other org sees reports';
  BEGIN
    PERFORM public.exos_match_staff_view(pg_temp.u('d1'));
    RAISE EXCEPTION 'M9: other org read the review';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  BEGIN
    PERFORM public.exos_match_remove_member(pg_temp.mm('c04'), 'x', true);
    RAISE EXCEPTION 'M9: other org removed a member';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  PERFORM set_config('app.uid', pg_temp.u('b1')::text, true);
  ASSERT (SELECT count(*) FROM public.exos_social_group_members) = 0, 'M9: a holder reads member rows';
  PERFORM set_config('app.uid', pg_temp.u('a0')::text, true);
  ASSERT (SELECT count(*) FROM public.exos_social_groups) = 2, 'M9: owner reads own groups';
  RAISE NOTICE 'OK  M9 cross-org isolation';
END $$;
RESET ROLE;

-- M10 --------------------------------------------------------------------------
DO $$ BEGIN
  ASSERT pg_temp.u('d3') IN (SELECT public.exos_match_due()), 'M10: other tier due (10h out, 12h cutoff)';
  ASSERT pg_temp.u('d1') NOT IN (SELECT public.exos_match_due()), 'M10: matched tier not due again';
  ASSERT public.exos_match_sweep() = 0, 'M10: nothing to sweep yet';
  UPDATE public.exos_events SET ends_at = now() - interval '8 days', starts_at = now() - interval '8 days 3 hours'
   WHERE id = pg_temp.u('e1');
  ASSERT public.exos_match_sweep() >= 2, 'M10: answers + intake swept';
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_match_answers WHERE tier_id = pg_temp.u('d1')), 'M10: answers gone';
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_match_intake WHERE tier_id = pg_temp.u('d1')), 'M10: intake gone';
  ASSERT (SELECT swept_at IS NOT NULL FROM public.exos_match_configs WHERE tier_id = pg_temp.u('d1')), 'M10: swept_at';
  ASSERT public.exos_match_sweep() = 0, 'M10: second sweep is a no-op';
  ASSERT EXISTS (SELECT 1 FROM public.exos_social_groups WHERE tier_id = pg_temp.u('d1')), 'M10: groups stay (chat seam)';
  ASSERT (SELECT pg_get_constraintdef(oid) FROM pg_constraint WHERE conname = 'exos_mail_template_check') LIKE '%matched-reveal%',
    'M10: mail template allowed';
  RAISE NOTICE 'OK  M10 retention sweep and due list';
END $$;

ROLLBACK;
