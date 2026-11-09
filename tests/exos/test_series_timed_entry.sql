-- ============================================================================
-- Event series, collections and timed entry (mig 20261030150000).
-- Self-contained (5e… ids), rolled back at the end.
--   S1 create a series from a template; generate is idempotent, skips past
--      dates, exceptions and dates already recorded; roles + cross-org
--   S2 publish all; propagate skips edited fields, dates with sales, past
--   S3 cancel one date (with an event / without one: never generated)
--   S4 attach / detach a show; cancel the series by scope; delete refusal
--   S5 public series: anon sees published upcoming dates only
--   C1 collections: RLS writes, cross-org isolation, public page published only
--   T1 timed-entry config validation and roles
--   T2 public slots: published event for anon, drafts for staff only
--   T3 slot holds: capacity counts live holds; an expired hold frees the place
--   T4 fulfillment never oversells a slot (sequential race on the last place)
--   T5 a timed tier needs a slot; other mint paths are refused
--   T6 a void gives the place back; per-tier caps
--   T7 config changes never strand a sale
--   T8 the door: entry window (early / late), admit anyway, offline replay
--   T9 slot report; cross-org and anon refused
--   psql -d <db> -v ON_ERROR_STOP=1 -f tests/exos/test_series_timed_entry.sql
-- ============================================================================
\set ON_ERROR_STOP on
BEGIN;

INSERT INTO auth.users (id, email, email_confirmed_at) VALUES
  ('5e000000-0000-0000-0000-0000000000a0', '5e-owner@x.com', now()),
  ('5e000000-0000-0000-0000-0000000000a1', '5e-manager@x.com', now()),
  ('5e000000-0000-0000-0000-0000000000a2', '5e-content@x.com', now()),
  ('5e000000-0000-0000-0000-0000000000a3', '5e-scanner@x.com', now()),
  ('5e000000-0000-0000-0000-0000000000b1', '5e-buyer1@x.com', now()),
  ('5e000000-0000-0000-0000-0000000000b2', '5e-buyer2@x.com', now()),
  ('5e000000-0000-0000-0000-0000000000b3', '5e-buyer3@x.com', now()),
  ('5e000000-0000-0000-0000-0000000000b9', '5e-other@x.com', now());
INSERT INTO public.exos_orgs (id, name, slug, owner_uid) VALUES
  ('5e000000-0000-0000-0000-000000000001', '5E Org', '5e-org', '5e000000-0000-0000-0000-0000000000a0'),
  ('5e000000-0000-0000-0000-000000000002', '5E Other', '5e-other', '5e000000-0000-0000-0000-0000000000b9');
INSERT INTO public.exos_org_memberships (org_id, user_id, role) VALUES
  ('5e000000-0000-0000-0000-000000000001', '5e000000-0000-0000-0000-0000000000a0', 'owner'),
  ('5e000000-0000-0000-0000-000000000001', '5e000000-0000-0000-0000-0000000000a1', 'manager'),
  ('5e000000-0000-0000-0000-000000000001', '5e000000-0000-0000-0000-0000000000a2', 'content'),
  ('5e000000-0000-0000-0000-000000000001', '5e000000-0000-0000-0000-0000000000a3', 'scanner'),
  ('5e000000-0000-0000-0000-000000000002', '5e000000-0000-0000-0000-0000000000b9', 'owner');

-- e1 series template (Fridays 20:00 New York); e2 timed museum (published,
-- doors open); e3 timed draft; e4 a standalone show to attach; e9 other org.
INSERT INTO public.exos_events (id, org_id, name, slug, status, starts_at, doors_at, ends_at, timezone, description, image_url, venue_name) VALUES
  ('5e000000-0000-0000-0000-0000000000e1', '5e000000-0000-0000-0000-000000000001', 'Jazz Friday', '5e-jazz', 'published',
   ((current_date + 6)::timestamp + time '20:00') AT TIME ZONE 'America/New_York',
   ((current_date + 6)::timestamp + time '19:00') AT TIME ZONE 'America/New_York',
   ((current_date + 6)::timestamp + time '23:00') AT TIME ZONE 'America/New_York',
   'America/New_York', 'Live jazz', 'https://img/jazz.png', 'Blue Room'),
  ('5e000000-0000-0000-0000-0000000000e2', '5e000000-0000-0000-0000-000000000001', 'Museum', '5e-museum', 'published',
   now() - interval '1 hour', now() - interval '2 hours', now() + interval '60 days', 'America/New_York', NULL, NULL, 'Hall'),
  ('5e000000-0000-0000-0000-0000000000e3', '5e000000-0000-0000-0000-000000000001', 'Museum draft', '5e-draft', 'draft',
   now() + interval '5 days', NULL, now() + interval '60 days', 'America/New_York', NULL, NULL, 'Hall'),
  ('5e000000-0000-0000-0000-0000000000e4', '5e000000-0000-0000-0000-000000000001', 'Jazz special', '5e-special', 'published',
   ((current_date + 9)::timestamp + time '21:00') AT TIME ZONE 'America/New_York', NULL, NULL, 'America/New_York', NULL, NULL, 'Blue Room'),
  ('5e000000-0000-0000-0000-0000000000e9', '5e000000-0000-0000-0000-000000000002', 'Theirs', '5e-theirs', 'published',
   now() + interval '9 days', NULL, NULL, 'America/New_York', NULL, NULL, 'Elsewhere');
INSERT INTO public.exos_ticket_tiers (id, event_id, name, price, capacity, sold, visibility, kind, party_size) VALUES
  ('5e000000-0000-0000-0000-0000000000d1', '5e000000-0000-0000-0000-0000000000e1', 'GA', 20, 100, 0, 'public', 'standard', NULL),
  ('5e000000-0000-0000-0000-0000000000d2', '5e000000-0000-0000-0000-0000000000e2', 'Adult', 15, 500, 0, 'public', 'standard', NULL),
  ('5e000000-0000-0000-0000-0000000000d3', '5e000000-0000-0000-0000-0000000000e2', 'Child', 5, 500, 0, 'public', 'standard', NULL),
  ('5e000000-0000-0000-0000-0000000000d4', '5e000000-0000-0000-0000-0000000000e2', 'Members lounge', 0, 50, 0, 'public', 'standard', NULL),
  ('5e000000-0000-0000-0000-0000000000d5', '5e000000-0000-0000-0000-0000000000e2', 'Table', 100, 5, 0, 'public', 'table', 4),
  ('5e000000-0000-0000-0000-0000000000d6', '5e000000-0000-0000-0000-0000000000e3', 'Adult', 15, 500, 0, 'public', 'standard', NULL),
  ('5e000000-0000-0000-0000-0000000000d9', '5e000000-0000-0000-0000-0000000000e9', 'GA', 10, 100, 0, 'public', 'standard', NULL);

CREATE FUNCTION pg_temp.act(p_uid text, p_email text) RETURNS void LANGUAGE sql AS $$
  SELECT set_config('app.uid', coalesce(p_uid, ''), true),
         set_config('app.jwt', CASE WHEN p_email IS NULL THEN '' ELSE json_build_object('email', p_email)::text END, true);
$$;
GRANT EXECUTE ON FUNCTION pg_temp.act(text, text) TO anon, authenticated, service_role;
CREATE FUNCTION pg_temp.d(n int) RETURNS text LANGUAGE sql AS $$ SELECT (current_date + n)::text $$;
GRANT EXECUTE ON FUNCTION pg_temp.d(int) TO anon, authenticated, service_role;
-- The slot id of day current_date + n at HH:MM.
CREATE FUNCTION pg_temp.slot(n int, hm text) RETURNS text LANGUAGE sql AS $$
  SELECT to_char(current_date + n, 'YYYYMMDD') || 'T' || replace(hm, ':', '') $$;
GRANT EXECUTE ON FUNCTION pg_temp.slot(int, text) TO anon, authenticated, service_role;
CREATE TEMP TABLE ctx (k text PRIMARY KEY, v text);
GRANT ALL ON ctx TO anon, authenticated, service_role;

-- Grants: staff RPCs are for signed-in callers only; the checks inside decide
-- who. Blocks below run as the table owner where they assert on rows (the
-- harness grants authenticated only a few event columns); RLS checks run as
-- authenticated / anon.
DO $$
DECLARE f text;
BEGIN
  FOREACH f IN ARRAY ARRAY['public.exos_series_create(uuid, text, jsonb, text)', 'public.exos_series_generate(uuid, jsonb)',
                           'public.exos_set_timed_entry(uuid, jsonb)', 'public.exos_event_slot_report(uuid, date, date)',
                           'public.exos_admit_outside_window(uuid, uuid)', 'public.exos_event_door_slots(uuid)'] LOOP
    ASSERT has_function_privilege('authenticated', f, 'EXECUTE'), 'grants: authenticated runs ' || f;
    ASSERT NOT has_function_privilege('anon', f, 'EXECUTE'), 'grants: anon can''t run ' || f;
  END LOOP;
  FOREACH f IN ARRAY ARRAY['public.exos_attach_hold_slot(uuid, text)', 'public._exos_slot_commit(text)',
                           'public._exos_slot_report(uuid, date, date)', 'public._exos_collection_event_ids(uuid, boolean)'] LOOP
    ASSERT NOT has_function_privilege('authenticated', f, 'EXECUTE'), 'grants: authenticated can''t run ' || f;
    ASSERT NOT has_function_privilege('anon', f, 'EXECUTE'), 'grants: anon can''t run ' || f;
  END LOOP;
  ASSERT has_function_privilege('service_role', 'public.exos_attach_hold_slot(uuid, text)', 'EXECUTE'), 'grants: checkout attaches';
  ASSERT has_function_privilege('anon', 'public.exos_public_event_slots(uuid, date, date)', 'EXECUTE'), 'grants: anon reads slots';
  RAISE NOTICE 'OK  grants';
END $$;

-- S1 -------------------------------------------------------------------------
DO $$
DECLARE sid uuid; r jsonb; n int;
BEGIN
  -- A stranger (another org's owner) and content staff can't start a series.
  PERFORM pg_temp.act('5e000000-0000-0000-0000-0000000000b9', '5e-other@x.com');
  BEGIN
    PERFORM public.exos_series_create('5e000000-0000-0000-0000-0000000000e1', 'X',
      jsonb_build_object('freq', 'weekly', 'startDate', pg_temp.d(6), 'time', '20:00'));
    RAISE EXCEPTION 'S1: another org created a series';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  PERFORM pg_temp.act('5e000000-0000-0000-0000-0000000000a2', '5e-content@x.com');
  BEGIN
    PERFORM public.exos_series_create('5e000000-0000-0000-0000-0000000000e1', 'X',
      jsonb_build_object('freq', 'weekly', 'startDate', pg_temp.d(6), 'time', '20:00'));
    RAISE EXCEPTION 'S1: content staff created a series';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;

  PERFORM pg_temp.act('5e000000-0000-0000-0000-0000000000a1', '5e-manager@x.com');
  BEGIN
    PERFORM public.exos_series_create('5e000000-0000-0000-0000-0000000000e1', 'X', '{"freq":"yearly"}'::jsonb);
    RAISE EXCEPTION 'S1: a bad rule was accepted';
  EXCEPTION WHEN invalid_parameter_value THEN NULL;
  END;
  sid := public.exos_series_create('5e000000-0000-0000-0000-0000000000e1', 'Jazz Fridays',
    jsonb_build_object('freq', 'weekly', 'interval', 1, 'weekdays', jsonb_build_array(extract(dow FROM current_date + 6)::int),
                       'startDate', pg_temp.d(6), 'count', 6, 'time', '20:00',
                       'exceptions', jsonb_build_array(pg_temp.d(27))));
  INSERT INTO ctx VALUES ('series', sid::text);
  ASSERT (SELECT series_id = sid AND series_index = 0 FROM public.exos_events WHERE id = '5e000000-0000-0000-0000-0000000000e1'),
         'S1: the template becomes member 0';
  ASSERT (SELECT count(*) FROM public.exos_series_occurrences WHERE series_id = sid AND occ_date = current_date + 6
            AND event_id = '5e000000-0000-0000-0000-0000000000e1' AND occ_time = '20:00') = 1,
         'S1: the template''s own date is the first occurrence (wall clock in the event zone)';
  BEGIN
    PERFORM public.exos_series_create('5e000000-0000-0000-0000-0000000000e1', 'Again',
      jsonb_build_object('freq', 'weekly', 'startDate', pg_temp.d(6), 'time', '20:00'));
    RAISE EXCEPTION 'S1: an event joined two series';
  EXCEPTION WHEN check_violation THEN NULL;
  END;

  r := public.exos_series_generate(sid, jsonb_build_array(
         jsonb_build_object('date', pg_temp.d(6), 'time', '20:00'),     -- the template: exists
         jsonb_build_object('date', pg_temp.d(13), 'time', '20:00'),
         jsonb_build_object('date', pg_temp.d(20), 'time', '20:00'),
         jsonb_build_object('date', pg_temp.d(27), 'time', '20:00'),    -- exception
         jsonb_build_object('date', pg_temp.d(34), 'time', '21:30'),    -- an override time
         jsonb_build_object('date', pg_temp.d(-7), 'time', '20:00'),    -- past
         jsonb_build_object('date', 'not-a-date', 'time', '20:00')));
  ASSERT jsonb_array_length(r -> 'created') = 3, 'S1: three new dates, got ' || r::text;
  ASSERT (SELECT count(*) FROM jsonb_array_elements(r -> 'skipped') x WHERE x ->> 'reason' = 'exists') = 1, 'S1: template date exists';
  ASSERT (SELECT count(*) FROM jsonb_array_elements(r -> 'skipped') x WHERE x ->> 'reason' = 'exception') = 1, 'S1: exception skipped';
  ASSERT (SELECT count(*) FROM jsonb_array_elements(r -> 'skipped') x WHERE x ->> 'reason' = 'past') = 1, 'S1: past skipped';
  ASSERT (SELECT count(*) FROM jsonb_array_elements(r -> 'skipped') x WHERE x ->> 'reason' = 'invalid') = 1, 'S1: junk skipped';
  SELECT count(*) INTO n FROM public.exos_events WHERE series_id = sid AND status = 'draft';
  ASSERT n = 3, 'S1: generated dates are drafts';
  ASSERT (SELECT (starts_at AT TIME ZONE 'America/New_York')::time = '21:30' FROM public.exos_events
           WHERE series_id = sid AND (starts_at AT TIME ZONE 'America/New_York')::date = current_date + 34),
         'S1: the override''s wall-clock time';
  ASSERT (SELECT count(*) FROM public.exos_ticket_tiers t JOIN public.exos_events e ON e.id = t.event_id
           WHERE e.series_id = sid) = 4, 'S1: tiers are cloned onto each date';

  -- Again, with the same dates: nothing new.
  r := public.exos_series_generate(sid, jsonb_build_array(
         jsonb_build_object('date', pg_temp.d(13), 'time', '20:00'),
         jsonb_build_object('date', pg_temp.d(20), 'time', '20:00')));
  ASSERT jsonb_array_length(r -> 'created') = 0, 'S1: generating twice creates nothing';
  ASSERT (SELECT count(*) FROM public.exos_events WHERE series_id = sid) = 4, 'S1: still four members';

  -- Another org's owner can't generate into it.
  PERFORM pg_temp.act('5e000000-0000-0000-0000-0000000000b9', '5e-other@x.com');
  BEGIN
    PERFORM public.exos_series_generate(sid, jsonb_build_array(jsonb_build_object('date', pg_temp.d(41), 'time', '20:00')));
    RAISE EXCEPTION 'S1: another org generated dates';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  RAISE NOTICE 'OK  S1 create + idempotent generate, exceptions, past, roles';
END $$;
SET LOCAL ROLE authenticated;
DO $$
BEGIN
  PERFORM pg_temp.act('5e000000-0000-0000-0000-0000000000b9', '5e-other@x.com');
  ASSERT (SELECT count(*) FROM public.exos_series_occurrences) = 0, 'S1: another org reads no occurrences';
  PERFORM pg_temp.act('5e000000-0000-0000-0000-0000000000a3', '5e-scanner@x.com');
  ASSERT (SELECT count(*) FROM public.exos_series_occurrences) = 4, 'S1: org staff read the schedule';
  RAISE NOTICE 'OK  S1 occurrences RLS';
END $$;
RESET ROLE;

-- S2 -------------------------------------------------------------------------
DO $$
DECLARE sid uuid := (SELECT v::uuid FROM ctx WHERE k = 'series'); r jsonb; n int; e13 uuid; e20 uuid; e34 uuid;
BEGIN
  PERFORM pg_temp.act('5e000000-0000-0000-0000-0000000000a0', '5e-owner@x.com');
  SELECT event_id INTO e13 FROM public.exos_series_occurrences WHERE series_id = sid AND occ_date = current_date + 13;
  SELECT event_id INTO e20 FROM public.exos_series_occurrences WHERE series_id = sid AND occ_date = current_date + 20;
  SELECT event_id INTO e34 FROM public.exos_series_occurrences WHERE series_id = sid AND occ_date = current_date + 34;
  INSERT INTO ctx VALUES ('e13', e13::text), ('e20', e20::text), ('e34', e34::text);
  n := public.exos_series_publish(sid);
  ASSERT n = 3, 'S2: publish all publishes the three drafts, got ' || n;
  ASSERT (SELECT count(*) FROM public.exos_events WHERE series_id = sid AND status = 'published') = 4, 'S2: all published';

  -- Someone edits date 13's title by hand; date 20 has a sale.
  UPDATE public.exos_events SET name = 'Jazz Friday (sold-out special)' WHERE id = e13;
  UPDATE public.exos_ticket_tiers SET sold = 1 WHERE event_id = e20;
  PERFORM pg_temp.act('5e000000-0000-0000-0000-0000000000a0', '5e-owner@x.com');
  r := public.exos_series_propagate(sid, '{"name":"Jazz Fridays at the Blue Room","prices":{"GA":25}}'::jsonb);
  ASSERT (SELECT name FROM public.exos_events WHERE id = e13) = 'Jazz Friday (sold-out special)', 'S2: an edited title is kept';
  ASSERT (SELECT name FROM public.exos_events WHERE id = e20) = 'Jazz Fridays at the Blue Room', 'S2: an untouched title changes';
  ASSERT (SELECT name FROM public.exos_events WHERE id = '5e000000-0000-0000-0000-0000000000e1') = 'Jazz Fridays at the Blue Room',
         'S2: the template changes';
  ASSERT (SELECT price FROM public.exos_ticket_tiers WHERE event_id = e20) = 20, 'S2: a date with sales keeps its price';
  ASSERT (SELECT price FROM public.exos_ticket_tiers WHERE event_id = e13) = 25, 'S2: an unsold date takes the new price';
  ASSERT EXISTS (SELECT 1 FROM jsonb_array_elements(r -> 'skipped') x
                  WHERE x ->> 'reason' = 'edited' AND (x ->> 'event_id')::uuid = e13 AND x ->> 'field' = 'name'),
         'S2: the edited skip is reported';
  ASSERT EXISTS (SELECT 1 FROM jsonb_array_elements(r -> 'skipped') x
                  WHERE x ->> 'reason' = 'has_sales' AND (x ->> 'event_id')::uuid = e20), 'S2: the has_sales skip is reported';
  -- The next propagate sees date 20's title as written by the series.
  r := public.exos_series_propagate(sid, '{"description":"New blurb"}'::jsonb);
  ASSERT (SELECT count(*) FROM public.exos_events WHERE series_id = sid AND description = 'New blurb') = 4,
         'S2: description everywhere (none was edited)';
  UPDATE public.exos_ticket_tiers SET sold = 0 WHERE event_id = e20;
  RAISE NOTICE 'OK  S2 publish all; propagate keeps edits and priced sales';
END $$;

-- S3 -------------------------------------------------------------------------
DO $$
DECLARE sid uuid := (SELECT v::uuid FROM ctx WHERE k = 'series'); e20 uuid := (SELECT v::uuid FROM ctx WHERE k = 'e20'); r jsonb;
BEGIN
  PERFORM pg_temp.act('5e000000-0000-0000-0000-0000000000a1', '5e-manager@x.com');
  r := public.exos_series_cancel_date(sid, current_date + 20, 'Band ill');
  ASSERT r ->> 'status' = 'cancelled', 'S3: a date with an event is cancelled';
  ASSERT (SELECT status FROM public.exos_events WHERE id = e20) = 'cancelled', 'S3: its event is cancelled';
  -- A date not generated yet is skipped, and generation then leaves it alone.
  r := public.exos_series_cancel_date(sid, current_date + 41, NULL);
  ASSERT r ->> 'status' = 'skipped', 'S3: an ungenerated date is skipped';
  r := public.exos_series_generate(sid, jsonb_build_array(jsonb_build_object('date', pg_temp.d(41), 'time', '20:00'),
                                                          jsonb_build_object('date', pg_temp.d(20), 'time', '20:00')));
  ASSERT jsonb_array_length(r -> 'created') = 0, 'S3: skipped and cancelled dates are never regenerated';
  -- Propagate reports the cancelled date.
  r := public.exos_series_propagate(sid, '{"image_url":"https://img/new.png"}'::jsonb);
  ASSERT EXISTS (SELECT 1 FROM jsonb_array_elements(r -> 'skipped') x WHERE x ->> 'reason' = 'cancelled'),
         'S3: cancelled dates are left alone';
  ASSERT (SELECT image_url FROM public.exos_events WHERE id = e20) = 'https://img/jazz.png', 'S3: cancelled date untouched';
  RAISE NOTICE 'OK  S3 cancel one date';
END $$;

-- S4 -------------------------------------------------------------------------
DO $$
DECLARE sid uuid := (SELECT v::uuid FROM ctx WHERE k = 'series'); e34 uuid := (SELECT v::uuid FROM ctx WHERE k = 'e34'); r jsonb;
BEGIN
  PERFORM pg_temp.act('5e000000-0000-0000-0000-0000000000a0', '5e-owner@x.com');
  r := public.exos_series_attach_event(sid, '5e000000-0000-0000-0000-0000000000e4');
  ASSERT (SELECT series_id FROM public.exos_events WHERE id = '5e000000-0000-0000-0000-0000000000e4') = sid, 'S4: attached by reference';
  BEGIN
    PERFORM public.exos_series_attach_event(sid, '5e000000-0000-0000-0000-0000000000e9');
    RAISE EXCEPTION 'S4: another org''s event attached';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  ASSERT public.exos_series_detach_event(sid, '5e000000-0000-0000-0000-0000000000e4'), 'S4: detached';
  ASSERT (SELECT series_id FROM public.exos_events WHERE id = '5e000000-0000-0000-0000-0000000000e4') IS NULL, 'S4: standalone again';
  ASSERT (SELECT status FROM public.exos_series_occurrences WHERE event_id = '5e000000-0000-0000-0000-0000000000e4') = 'removed',
         'S4: the date stays recorded as removed';
  BEGIN
    PERFORM public.exos_series_detach_event(sid, '5e000000-0000-0000-0000-0000000000e1');
    RAISE EXCEPTION 'S4: the template detached';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
  BEGIN
    PERFORM public.exos_series_cancel(sid, NULL);
    RAISE EXCEPTION 'S4: cancel without a scope';
  EXCEPTION WHEN invalid_parameter_value THEN NULL;
  END;
  -- Delete is refused once a member has tickets (simulated: tickets_sold).
  UPDATE public.exos_events SET tickets_sold = 1 WHERE id = e34;
  PERFORM pg_temp.act('5e000000-0000-0000-0000-0000000000a0', '5e-owner@x.com');
  BEGIN
    PERFORM public.exos_series_delete(sid);
    RAISE EXCEPTION 'S4: a series with sales was deleted';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
  UPDATE public.exos_events SET tickets_sold = 0 WHERE id = e34;
  RAISE NOTICE 'OK  S4 attach / detach, cancel scope required, delete refused with sales';
END $$;

-- S5 -------------------------------------------------------------------------
SET LOCAL ROLE anon;
DO $$
DECLARE sid uuid := (SELECT v::uuid FROM ctx WHERE k = 'series'); r jsonb;
BEGIN
  PERFORM pg_temp.act(NULL, NULL);
  r := public.exos_public_series(sid);
  ASSERT (r ->> 'upcoming_count')::int = 3, 'S5: three upcoming published dates (one cancelled), got ' || coalesce(r::text, 'null');
  ASSERT NOT EXISTS (SELECT 1 FROM jsonb_array_elements(r -> 'events') x WHERE x ? 'status' OR x ? 'tickets_sold'),
         'S5: no internal columns';
  ASSERT (SELECT bool_and((x ->> 'from_price') IS NOT NULL) FROM jsonb_array_elements(r -> 'events') x), 'S5: from price';
  r := public.exos_public_org_series('5e-org');
  ASSERT jsonb_array_length(r) = 1 AND jsonb_array_length(r -> 0 -> 'events') = 3, 'S5: the org''s series list';
  ASSERT jsonb_array_length(public.exos_public_org_series('5e-other')) = 0, 'S5: the other org has none';
  BEGIN
    PERFORM public.exos_series_publish(sid);
    RAISE EXCEPTION 'S5: anon published';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  BEGIN
    PERFORM 1 FROM public.exos_series_occurrences;
    RAISE EXCEPTION 'S5: anon read occurrences';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  RAISE NOTICE 'OK  S5 public series: published upcoming only';
END $$;
SET LOCAL ROLE authenticated;
DO $$
DECLARE sid uuid := (SELECT v::uuid FROM ctx WHERE k = 'series'); r jsonb;
BEGIN
  -- Archived: off the public pages; cancel all shows: everything future is cancelled.
  PERFORM pg_temp.act('5e000000-0000-0000-0000-0000000000a0', '5e-owner@x.com');
  PERFORM public.exos_series_update(sid, '{"status":"archived"}'::jsonb);
  ASSERT public.exos_public_series(sid) IS NULL, 'S5: archived series is not public';
  r := public.exos_series_cancel(sid, 'all_shows', NULL, 'Venue closed');
  ASSERT jsonb_array_length(r -> 'cancelled_event_ids') = 3, 'S5: all future shows cancelled, got ' || r::text;
  ASSERT (SELECT status FROM public.exos_event_series WHERE id = sid) = 'cancelled', 'S5: series cancelled';
  RAISE NOTICE 'OK  S5 archive + cancel all shows';
END $$;

-- C1 -------------------------------------------------------------------------
SET LOCAL ROLE authenticated;
DO $$
DECLARE n int; r jsonb;
BEGIN
  PERFORM pg_temp.act('5e000000-0000-0000-0000-0000000000a2', '5e-content@x.com');
  INSERT INTO public.exos_collections (id, org_id, name, slug, mode, event_ids, published) VALUES
    ('5e000000-0000-0000-0000-0000000000c1', '5e000000-0000-0000-0000-000000000001', 'Picks', 'Picks', 'manual',
     ARRAY['5e000000-0000-0000-0000-0000000000e4', '5e000000-0000-0000-0000-0000000000e3',
           '5e000000-0000-0000-0000-0000000000e9']::uuid[], true);
  INSERT INTO public.exos_collections (id, org_id, name, slug, mode, rule_kind, rule_value, published) VALUES
    ('5e000000-0000-0000-0000-0000000000c2', '5e000000-0000-0000-0000-000000000001', 'Blue Room', 'blue-room', 'rule',
     'venue', 'blue room', true),
    ('5e000000-0000-0000-0000-0000000000c3', '5e000000-0000-0000-0000-000000000001', 'Secret', 'secret', 'manual',
     NULL, NULL, false);
  ASSERT (SELECT slug FROM public.exos_collections WHERE id = '5e000000-0000-0000-0000-0000000000c1') = 'picks', 'C1: slug lowercased';
  -- Scanner reads, can't write; another org sees nothing and can't insert here.
  PERFORM pg_temp.act('5e000000-0000-0000-0000-0000000000a3', '5e-scanner@x.com');
  ASSERT (SELECT count(*) FROM public.exos_collections) = 3, 'C1: scanner reads';
  UPDATE public.exos_collections SET name = 'Hacked';
  GET DIAGNOSTICS n = ROW_COUNT;
  ASSERT n = 0, 'C1: scanner can''t edit';
  PERFORM pg_temp.act('5e000000-0000-0000-0000-0000000000b9', '5e-other@x.com');
  ASSERT (SELECT count(*) FROM public.exos_collections) = 0, 'C1: other org reads nothing';
  BEGIN
    INSERT INTO public.exos_collections (org_id, name, slug) VALUES ('5e000000-0000-0000-0000-000000000001', 'X', 'x');
    RAISE EXCEPTION 'C1: other org inserted';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  -- Staff preview includes drafts but never another org's event.
  PERFORM pg_temp.act('5e000000-0000-0000-0000-0000000000a0', '5e-owner@x.com');
  ASSERT (SELECT count(*) FROM public.exos_collection_event_ids('5e000000-0000-0000-0000-0000000000c1')) = 2,
         'C1: staff preview: own events only (draft included)';
  PERFORM pg_temp.act('5e000000-0000-0000-0000-0000000000b9', '5e-other@x.com');
  BEGIN
    PERFORM public.exos_collection_event_ids('5e000000-0000-0000-0000-0000000000c1');
    RAISE EXCEPTION 'C1: other org previewed';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  RAISE NOTICE 'OK  C1 collections RLS + cross-org';
END $$;
SET LOCAL ROLE anon;
DO $$
DECLARE r jsonb;
BEGIN
  PERFORM pg_temp.act(NULL, NULL);
  r := public.exos_public_collection('5e-org', 'picks');
  ASSERT jsonb_array_length(r -> 'events') = 1 AND r -> 'events' -> 0 ->> 'id' = '5e000000-0000-0000-0000-0000000000e4',
         'C1: public page: the published event only (no draft, no other org), got ' || coalesce(r::text, 'null');
  r := public.exos_public_collection('5e-org', 'blue-room');
  ASSERT (SELECT count(*) FROM jsonb_array_elements(r -> 'events') x
           WHERE x ->> 'id' = '5e000000-0000-0000-0000-0000000000e4') = 1, 'C1: venue rule matches case-insensitively';
  ASSERT jsonb_array_length(r -> 'events') = 1, 'C1: rule pages show published only (the series dates are cancelled)';
  ASSERT public.exos_public_collection('5e-org', 'secret') IS NULL, 'C1: unpublished collection is not public';
  ASSERT public.exos_public_collection('5e-other', 'picks') IS NULL, 'C1: wrong org slug';
  BEGIN
    PERFORM 1 FROM public.exos_collections;
    RAISE EXCEPTION 'C1: anon read the table';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  RAISE NOTICE 'OK  C1 public collection page';
END $$;

-- T1 -------------------------------------------------------------------------
SET LOCAL ROLE authenticated;
DO $$
DECLARE cfg jsonb; r jsonb;
BEGIN
  cfg := jsonb_build_object(
    'tierIds', jsonb_build_array('5e000000-0000-0000-0000-0000000000d2', '5e000000-0000-0000-0000-0000000000d3'),
    'slotMinutes', 60, 'capacity', 2, 'tierCapacity', jsonb_build_object('5e000000-0000-0000-0000-0000000000d3', 1),
    'entryWindowMinutes', 30, 'earlyEntryMinutes', 15,
    'hours', (SELECT jsonb_object_agg(g::text, jsonb_build_array(jsonb_build_object('open', '10:00', 'close', '17:00')))
                FROM generate_series(0, 6) g),
    'startDate', pg_temp.d(0), 'endDate', pg_temp.d(30), 'closedDates', jsonb_build_array(pg_temp.d(5)));
  INSERT INTO ctx VALUES ('cfg', cfg::text);
  PERFORM pg_temp.act('5e000000-0000-0000-0000-0000000000a3', '5e-scanner@x.com');
  BEGIN
    PERFORM public.exos_set_timed_entry('5e000000-0000-0000-0000-0000000000e2', cfg);
    RAISE EXCEPTION 'T1: scanner configured timed entry';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  PERFORM pg_temp.act('5e000000-0000-0000-0000-0000000000a1', '5e-manager@x.com');
  BEGIN
    PERFORM public.exos_set_timed_entry('5e000000-0000-0000-0000-0000000000e2',
      cfg || jsonb_build_object('tierIds', jsonb_build_array('5e000000-0000-0000-0000-0000000000d9')));
    RAISE EXCEPTION 'T1: another event''s tier accepted';
  EXCEPTION WHEN invalid_parameter_value THEN NULL;
  END;
  BEGIN
    PERFORM public.exos_set_timed_entry('5e000000-0000-0000-0000-0000000000e2',
      cfg || jsonb_build_object('tierIds', jsonb_build_array('5e000000-0000-0000-0000-0000000000d5')));
    RAISE EXCEPTION 'T1: a table tier accepted';
  EXCEPTION WHEN invalid_parameter_value THEN NULL;
  END;
  BEGIN
    PERFORM public.exos_set_timed_entry('5e000000-0000-0000-0000-0000000000e2',
      cfg || jsonb_build_object('hours', jsonb_build_object('1', jsonb_build_array(
        jsonb_build_object('open', '10:00', 'close', '13:00'), jsonb_build_object('open', '12:00', 'close', '15:00')))));
    RAISE EXCEPTION 'T1: overlapping ranges accepted';
  EXCEPTION WHEN invalid_parameter_value THEN NULL;
  END;
  BEGIN
    PERFORM public.exos_set_timed_entry('5e000000-0000-0000-0000-0000000000e2',
      cfg || jsonb_build_object('slotMinutes', 5, 'hours', jsonb_build_object('1', jsonb_build_array(
        jsonb_build_object('open', '00:00', 'close', '24:00')))));
    RAISE EXCEPTION 'T1: 288 slots a day accepted';
  EXCEPTION WHEN invalid_parameter_value THEN NULL;
  END;
  r := public.exos_set_timed_entry('5e000000-0000-0000-0000-0000000000e2', cfg);
  ASSERT (r ->> 'capacity')::int = 2 AND (r ->> 'version')::bigint > 0, 'T1: saved';
  PERFORM public.exos_set_timed_entry('5e000000-0000-0000-0000-0000000000e3',
    cfg || jsonb_build_object('tierIds', jsonb_build_array('5e000000-0000-0000-0000-0000000000d6'), 'tierCapacity', '{}'::jsonb));
  RAISE NOTICE 'OK  T1 config validation + roles';
END $$;

-- T2 -------------------------------------------------------------------------
SET LOCAL ROLE anon;
DO $$
DECLARE n int; r record;
BEGIN
  PERFORM pg_temp.act(NULL, NULL);
  ASSERT (public.exos_public_timed_entry('5e000000-0000-0000-0000-0000000000e2') ->> 'slot_minutes')::int = 60, 'T2: config is public';
  ASSERT public.exos_public_timed_entry('5e000000-0000-0000-0000-0000000000e3') IS NULL, 'T2: a draft''s config is not';
  SELECT count(*) INTO n FROM public.exos_public_event_slots('5e000000-0000-0000-0000-0000000000e2', current_date + 3, current_date + 3);
  ASSERT n = 7, 'T2: 10:00-17:00 in 60-minute slots = 7, got ' || n;
  SELECT count(*) INTO n FROM public.exos_public_event_slots('5e000000-0000-0000-0000-0000000000e2', current_date + 5, current_date + 5);
  ASSERT n = 0, 'T2: a closed date has no slots';
  SELECT * INTO r FROM public.exos_public_event_slots('5e000000-0000-0000-0000-0000000000e2', current_date + 3, current_date + 3)
   WHERE slot_id = pg_temp.slot(3, '10:00');
  ASSERT r.remaining = 2 AND (r.tier_remaining ->> '5e000000-0000-0000-0000-0000000000d3')::int = 1, 'T2: remaining + per-tier cap';
  ASSERT r.starts_at = ((current_date + 3)::timestamp + time '10:00') AT TIME ZONE 'America/New_York', 'T2: wall clock in the zone';
  ASSERT r.entry_until = r.starts_at + interval '30 minutes', 'T2: entry window';
  SELECT count(*) INTO n FROM public.exos_public_event_slots('5e000000-0000-0000-0000-0000000000e3', current_date + 3, current_date + 3);
  ASSERT n = 0, 'T2: a draft''s slots are not public';
  SELECT count(*) INTO n FROM public.exos_public_event_slots('5e000000-0000-0000-0000-0000000000e2', current_date, current_date + 200);
  ASSERT n <= 62 * 7, 'T2: at most 62 days per call';
  RAISE NOTICE 'OK  T2 public slots';
END $$;
SET LOCAL ROLE authenticated;
DO $$
DECLARE n int;
BEGIN
  PERFORM pg_temp.act('5e000000-0000-0000-0000-0000000000a3', '5e-scanner@x.com');
  SELECT count(*) INTO n FROM public.exos_public_event_slots('5e000000-0000-0000-0000-0000000000e3', current_date + 3, current_date + 3);
  ASSERT n = 7, 'T2: staff see a draft''s slots';
  PERFORM pg_temp.act('5e000000-0000-0000-0000-0000000000b9', '5e-other@x.com');
  SELECT count(*) INTO n FROM public.exos_public_event_slots('5e000000-0000-0000-0000-0000000000e3', current_date + 3, current_date + 3);
  ASSERT n = 0, 'T2: another org doesn''t';
  ASSERT (SELECT count(*) FROM public.exos_timed_entry) = 0, 'T2: another org reads no config rows';
  RAISE NOTICE 'OK  T2 drafts for staff only';
END $$;

-- T3 -------------------------------------------------------------------------
DO $$
DECLARE h1 uuid; h2 uuid; h3 uuid;
BEGIN
  PERFORM pg_temp.act('5e000000-0000-0000-0000-0000000000b1', '5e-buyer1@x.com');
  h1 := public.exos_create_hold('5e000000-0000-0000-0000-0000000000e2', '5e000000-0000-0000-0000-0000000000d2', 2);
  PERFORM pg_temp.act('5e000000-0000-0000-0000-0000000000b2', '5e-buyer2@x.com');
  h2 := public.exos_create_hold('5e000000-0000-0000-0000-0000000000e2', '5e000000-0000-0000-0000-0000000000d2', 1);
  INSERT INTO ctx VALUES ('h1', h1::text), ('h2', h2::text);
  BEGIN
    PERFORM public.exos_attach_hold_slot(h1, pg_temp.slot(3, '10:00'));
    RAISE EXCEPTION 'T3: authenticated attached a slot directly';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
END $$;
SET LOCAL ROLE service_role;
DO $$
DECLARE h1 uuid := (SELECT v::uuid FROM ctx WHERE k = 'h1'); h2 uuid := (SELECT v::uuid FROM ctx WHERE k = 'h2');
BEGIN
  PERFORM pg_temp.act(NULL, NULL);
  BEGIN
    PERFORM public.exos_attach_hold_slot(h1, pg_temp.slot(3, '10:30'));
    RAISE EXCEPTION 'T3: an off-grid slot accepted';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
  BEGIN
    PERFORM public.exos_attach_hold_slot(h1, pg_temp.slot(5, '10:00'));
    RAISE EXCEPTION 'T3: a closed date accepted';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
  ASSERT public.exos_attach_hold_slot(h1, pg_temp.slot(3, '10:00')), 'T3: first hold takes both places';
  ASSERT (SELECT remaining FROM public.exos_public_event_slots('5e000000-0000-0000-0000-0000000000e2', current_date + 3, current_date + 3)
           WHERE slot_id = pg_temp.slot(3, '10:00')) = 0, 'T3: a live hold counts as taken';
  BEGIN
    PERFORM public.exos_attach_hold_slot(h2, pg_temp.slot(3, '10:00'));
    RAISE EXCEPTION 'T3: a full slot took another hold';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
  -- The first hold expires (the sweeper hasn't run yet): its places are free.
  RESET ROLE;
  UPDATE public.exos_cart_holds SET expires_at = now() - interval '1 second' WHERE id = h1;
  SET LOCAL ROLE service_role;
  ASSERT public.exos_attach_hold_slot(h2, pg_temp.slot(3, '10:00')), 'T3: an expired hold frees the slot';
  BEGIN
    PERFORM public.exos_attach_hold_slot(h1, pg_temp.slot(3, '11:00'));
    RAISE EXCEPTION 'T3: an expired hold attached';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
  RAISE NOTICE 'OK  T3 slot holds + expiry';
END $$;
RESET ROLE;

-- T4 -------------------------------------------------------------------------
-- Sessions as exos-checkout writes them (service role), fulfilled in turn.
CREATE FUNCTION pg_temp.sess(p_id text, p_tier uuid, p_qty int, p_slot text, p_buyer uuid) RETURNS uuid[]
LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO public.exos_checkout_sessions (session_id, event_id, tier_id, org_id, buyer_uid, buyer_email,
                                             quantity, amount_cents, status, slot_id)
  VALUES (p_id, '5e000000-0000-0000-0000-0000000000e2', p_tier, '5e000000-0000-0000-0000-000000000001',
          p_buyer, (SELECT email FROM auth.users WHERE id = p_buyer), p_qty, 1500 * p_qty, 'pending', p_slot);
  RETURN public.exos_fulfill_checkout(p_id);
END $$;
DO $$
DECLARE a uuid[]; b uuid[]; c uuid[]; why text; t record; s11 text := pg_temp.slot(3, '11:00');
BEGIN
  a := pg_temp.sess('5e-t4a', '5e000000-0000-0000-0000-0000000000d2', 1, s11, '5e000000-0000-0000-0000-0000000000b1');
  b := pg_temp.sess('5e-t4b', '5e000000-0000-0000-0000-0000000000d2', 1, s11, '5e000000-0000-0000-0000-0000000000b2');
  c := pg_temp.sess('5e-t4c', '5e000000-0000-0000-0000-0000000000d2', 1, s11, '5e000000-0000-0000-0000-0000000000b3');
  ASSERT cardinality(a) = 1 AND cardinality(b) = 1, 'T4: two buyers take the two places';
  ASSERT coalesce(cardinality(c), 0) = 0, 'T4: the third order is refused';
  SELECT failure_reason INTO why FROM public.exos_checkout_sessions WHERE session_id = '5e-t4c';
  ASSERT why = 'time slot sold out at fulfillment', 'T4: refused for the slot, got ' || coalesce(why, 'null');
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_tickets WHERE order_ref = '5e-t4c'), 'T4: nothing minted';
  ASSERT (SELECT sold FROM public.exos_ticket_tiers WHERE id = '5e000000-0000-0000-0000-0000000000d2') = 2,
         'T4: the refused order left the tier counter alone (same transaction)';
  ASSERT (SELECT sold FROM public.exos_event_slots WHERE event_id = '5e000000-0000-0000-0000-0000000000e2' AND slot_id = s11) = 2,
         'T4: slot sold = 2';
  SELECT * INTO t FROM public.exos_tickets WHERE id = a[1];
  ASSERT t.slot_id = s11 AND t.slot_starts_at = ((current_date + 3)::timestamp + time '11:00') AT TIME ZONE 'America/New_York'
         AND t.slot_entry_from = t.slot_starts_at - interval '15 minutes'
         AND t.slot_entry_until = t.slot_starts_at + interval '30 minutes', 'T4: the ticket carries its slot and window';
  ASSERT (SELECT sum(sold) FROM public.exos_event_slots WHERE event_id = '5e000000-0000-0000-0000-0000000000e2')
         = (SELECT count(*) FROM public.exos_tickets WHERE event_id = '5e000000-0000-0000-0000-0000000000e2' AND status IN ('active', 'used')),
         'T4: slot counters match the tickets';
  -- Buyer 2 pays for the place held on 10:00 (T3).
  a := pg_temp.sess('5e-t4h', '5e000000-0000-0000-0000-0000000000d2', 1, pg_temp.slot(3, '10:00'), '5e000000-0000-0000-0000-0000000000b2');
  ASSERT cardinality(a) = 1, 'T4: a held place fulfills';
  RAISE NOTICE 'OK  T4 the last place goes to one buyer; the slot never oversells';
END $$;

-- T5 -------------------------------------------------------------------------
DO $$
DECLARE a uuid[]; why text;
BEGIN
  a := pg_temp.sess('5e-t5a', '5e000000-0000-0000-0000-0000000000d2', 1, NULL, '5e000000-0000-0000-0000-0000000000b1');
  SELECT failure_reason INTO why FROM public.exos_checkout_sessions WHERE session_id = '5e-t5a';
  ASSERT coalesce(cardinality(a), 0) = 0 AND why = 'pick a date and time slot', 'T5: a timed tier needs a slot, got ' || coalesce(why, 'null');
  a := pg_temp.sess('5e-t5b', '5e000000-0000-0000-0000-0000000000d4', 1, pg_temp.slot(3, '12:00'), '5e000000-0000-0000-0000-0000000000b1');
  ASSERT coalesce(cardinality(a), 0) = 0, 'T5: a slot on an untimed tier is refused';
  -- A comp / box-office / free-claim mint (no fulfillment) can't sell into a slot.
  BEGIN
    INSERT INTO public.exos_tickets (event_id, org_id, tier_id, tier_name, status, barcode_secret, price_paid)
    VALUES ('5e000000-0000-0000-0000-0000000000e2', '5e000000-0000-0000-0000-000000000001',
            '5e000000-0000-0000-0000-0000000000d2', 'Adult', 'active', 'x', 0);
    RAISE EXCEPTION 'T5: a timed ticket minted without a slot';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
  BEGIN
    INSERT INTO public.exos_tickets (event_id, org_id, tier_id, tier_name, status, barcode_secret, price_paid, slot_id)
    VALUES ('5e000000-0000-0000-0000-0000000000e2', '5e000000-0000-0000-0000-000000000001',
            '5e000000-0000-0000-0000-0000000000d2', 'Adult', 'active', 'x', 0, pg_temp.slot(3, '12:00'));
    RAISE EXCEPTION 'T5: a slot set by hand';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
  RAISE NOTICE 'OK  T5 timed tiers need a slot; other mint paths refused';
END $$;

-- T6 -------------------------------------------------------------------------
DO $$
DECLARE a uuid[]; s11 text := pg_temp.slot(3, '11:00'); s13 text := pg_temp.slot(3, '13:00');
BEGIN
  UPDATE public.exos_tickets SET status = 'voided', voided_at = now()
   WHERE order_ref = '5e-t4a';
  ASSERT (SELECT sold FROM public.exos_event_slots WHERE event_id = '5e000000-0000-0000-0000-0000000000e2' AND slot_id = s11) = 1,
         'T6: a void gives the place back';
  a := pg_temp.sess('5e-t6a', '5e000000-0000-0000-0000-0000000000d2', 1, s11, '5e000000-0000-0000-0000-0000000000b3');
  ASSERT cardinality(a) = 1, 'T6: the freed place sells again';
  -- Child: 1 per slot.
  a := pg_temp.sess('5e-t6b', '5e000000-0000-0000-0000-0000000000d3', 1, s13, '5e000000-0000-0000-0000-0000000000b1');
  ASSERT cardinality(a) = 1, 'T6: one child';
  a := pg_temp.sess('5e-t6c', '5e000000-0000-0000-0000-0000000000d3', 1, s13, '5e000000-0000-0000-0000-0000000000b2');
  ASSERT coalesce(cardinality(a), 0) = 0, 'T6: the child cap holds';
  a := pg_temp.sess('5e-t6d', '5e000000-0000-0000-0000-0000000000d2', 1, s13, '5e000000-0000-0000-0000-0000000000b2');
  ASSERT cardinality(a) = 1, 'T6: an adult still fits';
  ASSERT (SELECT tier_sold FROM public.exos_event_slots WHERE event_id = '5e000000-0000-0000-0000-0000000000e2' AND slot_id = s13)
         = jsonb_build_object('5e000000-0000-0000-0000-0000000000d3', 1, '5e000000-0000-0000-0000-0000000000d2', 1), 'T6: per-tier counts';
  RAISE NOTICE 'OK  T6 voids release; per-tier caps';
END $$;

-- T7 -------------------------------------------------------------------------
SET LOCAL ROLE authenticated;
DO $$
DECLARE cfg jsonb := (SELECT v::jsonb FROM ctx WHERE k = 'cfg'); r jsonb;
BEGIN
  PERFORM pg_temp.act('5e000000-0000-0000-0000-0000000000a0', '5e-owner@x.com');
  BEGIN
    PERFORM public.exos_set_timed_entry('5e000000-0000-0000-0000-0000000000e2', cfg || '{"capacity":1}'::jsonb);
    RAISE EXCEPTION 'T7: capacity dropped below what a slot sold';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
  BEGIN
    PERFORM public.exos_set_timed_entry('5e000000-0000-0000-0000-0000000000e2',
      cfg || jsonb_build_object('closedDates', jsonb_build_array(pg_temp.d(3))));
    RAISE EXCEPTION 'T7: a date with sales was closed';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
  BEGIN
    PERFORM public.exos_clear_timed_entry('5e000000-0000-0000-0000-0000000000e2');
    RAISE EXCEPTION 'T7: timed entry turned off with sales';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
  -- A staff override keeps the slot's own capacity across config edits.
  r := public.exos_set_event_slot('5e000000-0000-0000-0000-0000000000e2', pg_temp.slot(4, '10:00'), 5, NULL);
  ASSERT (r ->> 'capacity')::int = 5, 'T7: slot capacity set';
  BEGIN
    PERFORM public.exos_set_event_slot('5e000000-0000-0000-0000-0000000000e2', pg_temp.slot(3, '11:00'), 0, NULL);
    RAISE EXCEPTION 'T7: slot capacity below sold';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
  PERFORM public.exos_set_timed_entry('5e000000-0000-0000-0000-0000000000e2', cfg || '{"capacity":3}'::jsonb);
  ASSERT (SELECT capacity FROM public.exos_public_event_slots('5e000000-0000-0000-0000-0000000000e2', current_date + 4, current_date + 4)
           WHERE slot_id = pg_temp.slot(4, '10:00')) = 5, 'T7: the custom capacity is kept';
  PERFORM public.exos_set_event_slot('5e000000-0000-0000-0000-0000000000e2', pg_temp.slot(4, '11:00'), NULL, true);
  ASSERT (SELECT remaining FROM public.exos_public_event_slots('5e000000-0000-0000-0000-0000000000e2', current_date + 4, current_date + 4)
           WHERE slot_id = pg_temp.slot(4, '11:00')) = 0, 'T7: a closed slot has no room';
  RAISE NOTICE 'OK  T7 config changes never strand a sale';
END $$;

-- T8 -------------------------------------------------------------------------
RESET ROLE;
DO $$
DECLARE tk uuid; r jsonb;
BEGIN
  SELECT id INTO tk FROM public.exos_tickets WHERE order_ref = '5e-t4b';
  INSERT INTO ctx VALUES ('tk', tk::text);
  PERFORM pg_temp.act('5e000000-0000-0000-0000-0000000000a0', '5e-owner@x.com');
  -- The slot is three days out: too early.
  r := public.exos_check_in_ticket(tk, 'manual', 'manual', NULL, '5e000000-0000-0000-0000-0000000000e2',
                                   'typed at the desk', NULL, NULL, NULL, 'entry');
  ASSERT r ->> 'reason' = 'outside-entry-window' AND r ->> 'window' = 'early', 'T8: too early, got ' || r::text;
  ASSERT (SELECT status FROM public.exos_tickets WHERE id = tk) = 'active', 'T8: nothing written';
  -- The legacy overload applies the same check.
  r := public.exos_check_in_ticket(tk, 'manual', 'manual', NULL, '5e000000-0000-0000-0000-0000000000e2',
                                   'typed at the desk', NULL, NULL);
  ASSERT r ->> 'reason' = 'outside-entry-window', 'T8: legacy overload too';
  -- A scanner from another org can't override.
  PERFORM pg_temp.act('5e000000-0000-0000-0000-0000000000b9', '5e-other@x.com');
  BEGIN
    PERFORM public.exos_admit_outside_window(tk, '5e000000-0000-0000-0000-0000000000e2');
    RAISE EXCEPTION 'T8: another org overrode';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  -- Staff: admit anyway.
  PERFORM pg_temp.act('5e000000-0000-0000-0000-0000000000a3', '5e-scanner@x.com');
  ASSERT public.exos_admit_outside_window(tk, '5e000000-0000-0000-0000-0000000000e2'), 'T8: override recorded';
  ASSERT (SELECT admit_override FROM public.exos_event_door_slots('5e000000-0000-0000-0000-0000000000e2') WHERE ticket_id = tk),
         'T8: the door registry shows the override';
  PERFORM pg_temp.act('5e000000-0000-0000-0000-0000000000a0', '5e-owner@x.com');
  r := public.exos_check_in_ticket(tk, 'manual', 'manual', NULL, '5e000000-0000-0000-0000-0000000000e2',
                                   'typed at the desk', NULL, NULL, NULL, 'entry');
  ASSERT (r ->> 'ok')::boolean, 'T8: admitted after the override, got ' || r::text;

  -- Late: a ticket whose window closed an hour ago.
  SELECT id INTO tk FROM public.exos_tickets WHERE order_ref = '5e-t6a';
  UPDATE public.exos_tickets SET slot_entry_from = now() - interval '3 hours', slot_entry_until = now() - interval '1 hour' WHERE id = tk;
  PERFORM pg_temp.act('5e000000-0000-0000-0000-0000000000a0', '5e-owner@x.com');
  r := public.exos_check_in_ticket(tk, 'manual', 'manual', NULL, '5e000000-0000-0000-0000-0000000000e2',
                                   'typed at the desk', NULL, NULL, NULL, 'entry');
  ASSERT r ->> 'window' = 'late', 'T8: too late';
  -- In the window: admitted.
  UPDATE public.exos_tickets SET slot_entry_from = now() - interval '10 minutes', slot_entry_until = now() + interval '20 minutes' WHERE id = tk;
  PERFORM pg_temp.act('5e000000-0000-0000-0000-0000000000a0', '5e-owner@x.com');
  r := public.exos_check_in_ticket(tk, 'manual', 'manual', NULL, '5e000000-0000-0000-0000-0000000000e2',
                                   'typed at the desk', NULL, NULL, NULL, 'entry');
  ASSERT (r ->> 'ok')::boolean, 'T8: inside the window, got ' || r::text;

  -- An offline replay was decided at the door: not re-judged.
  SELECT id INTO tk FROM public.exos_tickets WHERE order_ref = '5e-t6d';
  PERFORM pg_temp.act('5e000000-0000-0000-0000-0000000000a0', '5e-owner@x.com');
  r := public.exos_check_in_offline(gen_random_uuid(), tk, '5e000000-0000-0000-0000-0000000000e2', now() - interval '1 minute',
                                    NULL, 'manual', 'admitted offline', NULL, NULL, 'entry');
  ASSERT (r ->> 'ok')::boolean, 'T8: offline replay admitted, got ' || r::text;
  RAISE NOTICE 'OK  T8 entry window at the door';
END $$;

-- T9 -------------------------------------------------------------------------
SET LOCAL ROLE authenticated;
DO $$
DECLARE r record;
BEGIN
  PERFORM pg_temp.act('5e000000-0000-0000-0000-0000000000a2', '5e-content@x.com');
  SELECT * INTO r FROM public.exos_event_slot_report('5e000000-0000-0000-0000-0000000000e2', current_date + 3, current_date + 3)
   WHERE slot_id = pg_temp.slot(3, '11:00');
  ASSERT r.sold = 2 AND r.capacity = 3 AND r.checked_in = 2 AND r.gross > 0, 'T9: report row ' || row_to_json(r)::text;
  ASSERT (SELECT count(*) FROM public.exos_event_slot_report('5e000000-0000-0000-0000-0000000000e2', current_date + 3, current_date + 3)) = 7,
         'T9: every scheduled slot of the day';
  PERFORM pg_temp.act('5e000000-0000-0000-0000-0000000000b9', '5e-other@x.com');
  BEGIN
    PERFORM 1 FROM public.exos_event_slot_report('5e000000-0000-0000-0000-0000000000e2', NULL, NULL);
    RAISE EXCEPTION 'T9: another org read the report';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  BEGIN
    PERFORM public.exos_set_event_slot('5e000000-0000-0000-0000-0000000000e2', pg_temp.slot(4, '10:00'), 9, NULL);
    RAISE EXCEPTION 'T9: another org changed a slot';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  BEGIN
    PERFORM 1 FROM public.exos_event_door_slots('5e000000-0000-0000-0000-0000000000e2');
    RAISE EXCEPTION 'T9: another org read the door registry';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  ASSERT (SELECT count(*) FROM public.exos_event_slots) = 0, 'T9: another org reads no slot rows';
END $$;
SET LOCAL ROLE anon;
DO $$
BEGIN
  PERFORM pg_temp.act(NULL, NULL);
  BEGIN
    PERFORM 1 FROM public.exos_event_slot_report('5e000000-0000-0000-0000-0000000000e2', NULL, NULL);
    RAISE EXCEPTION 'T9: anon read the report';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  BEGIN
    PERFORM public.exos_admit_outside_window(gen_random_uuid(), gen_random_uuid());
    RAISE EXCEPTION 'T9: anon overrode';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  RAISE NOTICE 'OK  T9 slot report + isolation';
END $$;
RESET ROLE;

SELECT '*** SERIES + TIMED ENTRY PASSED ***' AS result;
ROLLBACK;
