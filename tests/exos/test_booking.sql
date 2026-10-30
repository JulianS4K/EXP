-- ============================================================================
-- Booking core (mig 20261030100000). Self-contained (bb… ids), rolled back at
-- the end.
--   B1 venues + rooms: RLS by role, permalink default / clash, time zone,
--      a room takes its venue's org
--   B2 grants: no anon access; holds have no client write path; the cores
--      are service_role only, the wrappers signed-in only
--   B3 hold levels: append, insert at a level, separate rooms, one slot per
--      hold, promotion on clear, moves, full-list update, rental, webhooks
--   B4 convert one night: draft event in the venue's zone, GA tier, links,
--      the line moves up, the hold's other room that night drops, retry is
--      refused, clear_holds_on_day, announce + notes carried, webhook
--   B5 show schedule ↔ doors_at, both ways; one doors row; doors before start
--   B6 notes + contacts: staff only (never scanners), authorship
--   B7 cross-org isolation: other orgs see and touch nothing, levels never
--      count another org's holds, event links stay in the org
--   B8 the service_role cores (exos-api) act only for the org they're given
--   B9 calendar (challenged nights, local dates, 92-day cap) and hold pages
--   psql -d <db> -v ON_ERROR_STOP=1 -f tests/exos/test_booking.sql
-- ============================================================================
\set ON_ERROR_STOP on
BEGIN;

INSERT INTO auth.users (id, email, email_confirmed_at) VALUES
  ('bb000000-0000-0000-0000-0000000000a0', 'bb-owner@x.com', now()),
  ('bb000000-0000-0000-0000-0000000000a1', 'bb-manager@x.com', now()),
  ('bb000000-0000-0000-0000-0000000000a2', 'bb-finance@x.com', now()),
  ('bb000000-0000-0000-0000-0000000000a3', 'bb-scanner@x.com', now()),
  ('bb000000-0000-0000-0000-0000000000a4', 'bb-content@x.com', now()),
  ('bb000000-0000-0000-0000-0000000000a5', 'bb-stranger@x.com', now()),
  ('bb000000-0000-0000-0000-0000000000b9', 'bb-other@x.com', now());
INSERT INTO public.exos_orgs (id, name, slug, owner_uid) VALUES
  ('bb000000-0000-0000-0000-000000000001', 'BB Org', 'bb-org', 'bb000000-0000-0000-0000-0000000000a0'),
  ('bb000000-0000-0000-0000-000000000002', 'BB Other', 'bb-other', 'bb000000-0000-0000-0000-0000000000b9');
INSERT INTO public.exos_org_memberships (org_id, user_id, role) VALUES
  ('bb000000-0000-0000-0000-000000000001', 'bb000000-0000-0000-0000-0000000000a0', 'owner'),
  ('bb000000-0000-0000-0000-000000000001', 'bb000000-0000-0000-0000-0000000000a1', 'manager'),
  ('bb000000-0000-0000-0000-000000000001', 'bb000000-0000-0000-0000-0000000000a2', 'finance'),
  ('bb000000-0000-0000-0000-000000000001', 'bb000000-0000-0000-0000-0000000000a3', 'scanner'),
  ('bb000000-0000-0000-0000-000000000001', 'bb000000-0000-0000-0000-0000000000a4', 'content'),
  ('bb000000-0000-0000-0000-000000000002', 'bb000000-0000-0000-0000-0000000000b9', 'owner');
INSERT INTO public.exos_webhooks (id, org_id, url, event_types) VALUES
  ('bb000000-0000-0000-0000-0000000000c1', 'bb000000-0000-0000-0000-000000000001', 'https://hooks.example/bb', ARRAY['*']);

-- The harness's exos_events / tiers carry none of prod's staff grants and
-- policies; give the signed-in role plain access here (rolled back) so the
-- event-side triggers run as they would for an organizer.
GRANT SELECT, INSERT, UPDATE ON public.exos_events TO authenticated;
GRANT SELECT ON public.exos_ticket_tiers TO authenticated;

CREATE FUNCTION pg_temp.as_user(p_uid text) RETURNS void LANGUAGE sql AS $$
  SELECT set_config('app.uid', coalesce(p_uid, ''), true)::text IS NOT NULL AND true;
$$;
GRANT EXECUTE ON FUNCTION pg_temp.as_user(text) TO anon, authenticated, service_role;
-- Level of a hold's active night on a date (room NULL = whole venue).
CREATE FUNCTION pg_temp.lvl(p_hold uuid, p_date date, p_room uuid) RETURNS int LANGUAGE sql AS $$
  SELECT level FROM public.exos_hold_positions
   WHERE hold_id = p_hold AND date = p_date AND room_id IS NOT DISTINCT FROM p_room AND status = 'active';
$$;
GRANT EXECUTE ON FUNCTION pg_temp.lvl(uuid, date, uuid) TO authenticated, service_role;
CREATE TEMP TABLE bb (k text PRIMARY KEY, v uuid);
GRANT ALL ON bb TO authenticated, service_role;

-- B1 -------------------------------------------------------------------------
SET ROLE authenticated;
DO $$
DECLARE v uuid; n int; ok boolean;
BEGIN
  PERFORM pg_temp.as_user('bb000000-0000-0000-0000-0000000000a0');
  INSERT INTO public.exos_venues (org_id, name, timezone, capacity, address)
  VALUES ('bb000000-0000-0000-0000-000000000001', ' Lincoln Hall ', 'America/Chicago', 500,
          '{"street":"2424 N Lincoln Ave","city":"Chicago","region":"IL","country":"US"}')
  RETURNING id INTO v;
  INSERT INTO bb VALUES ('venue', v);
  ASSERT (SELECT name = 'Lincoln Hall' AND permalink = 'lincoln-hall' AND relationship = 'owned'
                 AND created_by = 'bb000000-0000-0000-0000-0000000000a0'
            FROM public.exos_venues WHERE id = v), 'B1: trimmed, slugged, owned, creator stamped';
  -- A second venue with the same name gets the next free slug; an explicit clash is refused.
  INSERT INTO public.exos_venues (org_id, name, relationship, contact_name, contact_email)
  VALUES ('bb000000-0000-0000-0000-000000000001', 'Lincoln Hall', 'rented', 'Club GM', ' GM@Metro.Example ')
  RETURNING id INTO v;
  INSERT INTO bb VALUES ('rented', v);
  ASSERT (SELECT permalink = 'lincoln-hall-2' AND contact_email = 'gm@metro.example' FROM public.exos_venues WHERE id = v),
         'B1: next free slug, email lowercased';
  BEGIN
    INSERT INTO public.exos_venues (org_id, name, permalink) VALUES ('bb000000-0000-0000-0000-000000000001', 'Dup', 'lincoln-hall');
    RAISE EXCEPTION 'B1: duplicate permalink accepted';
  EXCEPTION WHEN unique_violation THEN NULL;
  END;
  BEGIN
    INSERT INTO public.exos_venues (org_id, name, timezone) VALUES ('bb000000-0000-0000-0000-000000000001', 'X', 'Mars/Base');
    RAISE EXCEPTION 'B1: bad time zone accepted';
  EXCEPTION WHEN invalid_parameter_value THEN NULL;
  END;
  BEGIN
    INSERT INTO public.exos_venues (org_id, name, relationship) VALUES ('bb000000-0000-0000-0000-000000000001', 'X', 'stolen');
    RAISE EXCEPTION 'B1: bad relationship accepted';
  EXCEPTION WHEN check_violation THEN NULL;
  END;

  -- Manager adds rooms; the room's org comes from the venue whatever is sent.
  PERFORM pg_temp.as_user('bb000000-0000-0000-0000-0000000000a1');
  INSERT INTO public.exos_venue_rooms (org_id, venue_id, name, capacity)
  VALUES ('bb000000-0000-0000-0000-000000000001', (SELECT bb.v FROM bb WHERE k = 'venue'), 'Main Room', 450)
  RETURNING id INTO v;
  INSERT INTO bb VALUES ('main', v);
  INSERT INTO public.exos_venue_rooms (org_id, venue_id, name, capacity)
  VALUES ('bb000000-0000-0000-0000-000000000002', (SELECT bb.v FROM bb WHERE k = 'venue'), 'Loft', 120)
  RETURNING id INTO v;
  INSERT INTO bb VALUES ('loft', v);
  ASSERT (SELECT org_id FROM public.exos_venue_rooms WHERE id = v) = 'bb000000-0000-0000-0000-000000000001',
         'B1: the room took the venue''s org';
  UPDATE public.exos_venues SET capacity = 520 WHERE id = (SELECT bb.v FROM bb WHERE k = 'venue');
  GET DIAGNOSTICS n = ROW_COUNT;
  ASSERT n = 1, 'B1: manager edits a venue';

  -- Content, finance, scanner read venues and rooms but can't write.
  FOREACH v IN ARRAY ARRAY['bb000000-0000-0000-0000-0000000000a2', 'bb000000-0000-0000-0000-0000000000a3',
                           'bb000000-0000-0000-0000-0000000000a4']::uuid[] LOOP
    PERFORM pg_temp.as_user(v::text);
    ASSERT (SELECT count(*) FROM public.exos_venues) = 2, 'B1: staff read venues ' || v;
    ASSERT (SELECT count(*) FROM public.exos_venue_rooms) = 2, 'B1: staff read rooms ' || v;
    UPDATE public.exos_venues SET capacity = 1;
    GET DIAGNOSTICS n = ROW_COUNT;
    ASSERT n = 0, 'B1: no venue edit for ' || v;
    ok := false;
    BEGIN
      INSERT INTO public.exos_venue_rooms (venue_id, org_id, name) VALUES ((SELECT bb.v FROM bb WHERE k = 'venue'), 'bb000000-0000-0000-0000-000000000001', 'Sneaky');
    EXCEPTION WHEN insufficient_privilege THEN ok := true;
    END;
    ASSERT ok, 'B1: no room insert for ' || v;
  END LOOP;
  -- A stranger sees nothing.
  PERFORM pg_temp.as_user('bb000000-0000-0000-0000-0000000000a5');
  ASSERT (SELECT count(*) FROM public.exos_venues) = 0 AND (SELECT count(*) FROM public.exos_venue_rooms) = 0,
         'B1: stranger sees no venue';
  RAISE NOTICE 'OK  B1 venues and rooms';
END $$;
RESET ROLE;

-- B2 -------------------------------------------------------------------------
DO $$
DECLARE t text; f text;
BEGIN
  FOREACH t IN ARRAY ARRAY['exos_venues', 'exos_venue_rooms', 'exos_holds', 'exos_hold_positions',
                           'exos_show_activities', 'exos_event_notes', 'exos_event_contacts'] LOOP
    ASSERT NOT has_table_privilege('anon', 'public.' || t, 'SELECT'), 'B2: anon reads ' || t;
    ASSERT (SELECT relrowsecurity FROM pg_class WHERE oid = ('public.' || t)::regclass), 'B2: RLS on ' || t;
  END LOOP;
  FOREACH t IN ARRAY ARRAY['exos_holds', 'exos_hold_positions'] LOOP
    ASSERT has_table_privilege('authenticated', 'public.' || t, 'SELECT'), 'B2: staff read ' || t;
    ASSERT NOT has_table_privilege('authenticated', 'public.' || t, 'INSERT')
       AND NOT has_table_privilege('authenticated', 'public.' || t, 'UPDATE')
       AND NOT has_table_privilege('authenticated', 'public.' || t, 'DELETE'), 'B2: no client write on ' || t;
  END LOOP;
  FOREACH f IN ARRAY ARRAY['public._exos_hold_create(uuid,uuid,text,uuid,jsonb)', 'public._exos_hold_update(uuid,uuid,jsonb)',
                           'public._exos_hold_clear(uuid,uuid,uuid[])', 'public._exos_hold_convert(uuid,uuid,text,uuid,uuid,jsonb)',
                           'public._exos_hold_json(uuid)'] LOOP
    ASSERT NOT has_function_privilege('anon', f, 'EXECUTE') AND NOT has_function_privilege('authenticated', f, 'EXECUTE'),
           'B2: clients can run ' || f;
    ASSERT has_function_privilege('service_role', f, 'EXECUTE'), 'B2: service_role lost ' || f;
  END LOOP;
  FOREACH f IN ARRAY ARRAY['public._exos_slot_place(uuid,uuid,uuid,date,uuid,integer)', 'public._exos_hold_release(uuid,uuid[],text,uuid)',
                           'public._exos_hold_finish(uuid,uuid,uuid[],text,jsonb)', 'public._exos_hold_set_fields(uuid,jsonb)'] LOOP
    ASSERT NOT has_function_privilege('authenticated', f, 'EXECUTE') AND NOT has_function_privilege('anon', f, 'EXECUTE'),
           'B2: clients can run ' || f;
  END LOOP;
  FOREACH f IN ARRAY ARRAY['public.exos_hold_create(uuid,jsonb)', 'public.exos_hold_update(uuid,jsonb)',
                           'public.exos_hold_clear(uuid,uuid[])', 'public.exos_hold_convert(uuid,jsonb)'] LOOP
    ASSERT NOT has_function_privilege('anon', f, 'EXECUTE'), 'B2: anon runs ' || f;
    ASSERT has_function_privilege('authenticated', f, 'EXECUTE'), 'B2: staff can''t run ' || f;
  END LOOP;
  RAISE NOTICE 'OK  B2 grants';
END $$;

-- B3 -------------------------------------------------------------------------
SET ROLE authenticated;
DO $$
DECLARE
  o uuid := 'bb000000-0000-0000-0000-000000000001';
  ven uuid := (SELECT bb.v FROM bb WHERE k = 'venue');
  main uuid := (SELECT bb.v FROM bb WHERE k = 'main');
  loft uuid := (SELECT bb.v FROM bb WHERE k = 'loft');
  d date := '2026-11-14';
  h jsonb; a uuid; b uuid; c uuid; x uuid; ok boolean; n int;
BEGIN
  -- Scanner, finance, content: no hold writes.
  FOREACH x IN ARRAY ARRAY['bb000000-0000-0000-0000-0000000000a2', 'bb000000-0000-0000-0000-0000000000a3',
                           'bb000000-0000-0000-0000-0000000000a4', 'bb000000-0000-0000-0000-0000000000a5']::uuid[] LOOP
    PERFORM pg_temp.as_user(x::text);
    ok := false;
    BEGIN
      PERFORM public.exos_hold_create(o, jsonb_build_object('title', 'X', 'positions',
        jsonb_build_array(jsonb_build_object('date', d, 'venue_id', ven))));
    EXCEPTION WHEN insufficient_privilege THEN ok := true;
    END;
    ASSERT ok, 'B3: hold create refused for ' || x;
  END LOOP;

  PERFORM pg_temp.as_user('bb000000-0000-0000-0000-0000000000a1');
  -- Bad input.
  FOREACH h IN ARRAY ARRAY[
    jsonb_build_object('title', 'No nights', 'positions', '[]'::jsonb),
    jsonb_build_object('positions', jsonb_build_array(jsonb_build_object('date', d, 'venue_id', ven))),
    jsonb_build_object('title', 'Bad date', 'positions', jsonb_build_array(jsonb_build_object('date', '2026-02-30', 'venue_id', ven))),
    jsonb_build_object('title', 'Bad venue', 'positions', jsonb_build_array(jsonb_build_object('date', d, 'venue_id', 'nope'))),
    jsonb_build_object('title', 'Bad room', 'positions', jsonb_build_array(jsonb_build_object('date', d, 'venue_id', ven, 'room_id', gen_random_uuid()))),
    jsonb_build_object('title', 'Bad level', 'positions', jsonb_build_array(jsonb_build_object('date', d, 'venue_id', ven, 'level', 0))),
    jsonb_build_object('title', 'Bad rental', 'rental', '{"status":"maybe"}'::jsonb, 'positions', jsonb_build_array(jsonb_build_object('date', d, 'venue_id', ven)))
  ] LOOP
    ok := false;
    BEGIN
      PERFORM public.exos_hold_create(o, h);
    EXCEPTION WHEN invalid_parameter_value THEN ok := true;
    END;
    ASSERT ok, 'B3: refused as bad input: ' || h::text;
  END LOOP;

  -- A: level 1. B: appended at 2. C asks for level 1: C1 A2 B3.
  h := public.exos_hold_create(o, jsonb_build_object('title', 'Band A', 'notes', 'Settle in the office.',
         'announce_at', now() + interval '30 days',
         'positions', jsonb_build_array(jsonb_build_object('date', d, 'venue_id', ven, 'room_id', main, 'start_time', '20:00'),
                                        jsonb_build_object('date', d, 'venue_id', ven, 'room_id', loft),
                                        jsonb_build_object('date', '2026-11-15', 'venue_id', ven, 'room_id', main))));
  a := (h->>'id')::uuid;
  ASSERT h->>'status' = 'active' AND jsonb_array_length(h->'positions') = 3, 'B3: A created with three nights';
  ASSERT pg_temp.lvl(a, d, main) = 1, 'B3: first hold is level 1';
  b := (public.exos_hold_create(o, jsonb_build_object('title', 'Band B', 'positions',
         jsonb_build_array(jsonb_build_object('date', d, 'venue_id', ven, 'room_id', main))))->>'id')::uuid;
  ASSERT pg_temp.lvl(b, d, main) = 2, 'B3: second hold appends';
  c := (public.exos_hold_create(o, jsonb_build_object('title', 'Band C', 'positions',
         jsonb_build_array(jsonb_build_object('date', d, 'venue_id', ven, 'room_id', main, 'level', 1))))->>'id')::uuid;
  ASSERT pg_temp.lvl(c, d, main) = 1 AND pg_temp.lvl(a, d, main) = 2 AND pg_temp.lvl(b, d, main) = 3,
         'B3: inserted at level 1, the others moved down';
  -- A level past the end is the end; another room is its own line; the whole venue too.
  x := (public.exos_hold_create(o, jsonb_build_object('title', 'Band E', 'positions',
         jsonb_build_array(jsonb_build_object('date', d, 'venue_id', ven, 'room_id', main, 'level', 9),
                           jsonb_build_object('date', d, 'venue_id', ven))))->>'id')::uuid;
  ASSERT pg_temp.lvl(x, d, main) = 4 AND pg_temp.lvl(x, d, NULL) = 1, 'B3: clamped to the end; whole venue separate';
  ASSERT pg_temp.lvl(a, d, loft) = 1, 'B3: loft is its own line';
  -- One hold, one slot.
  ok := false;
  BEGIN
    PERFORM public.exos_hold_create(o, jsonb_build_object('title', 'Twice', 'positions',
      jsonb_build_array(jsonb_build_object('date', d, 'venue_id', ven, 'room_id', main),
                        jsonb_build_object('date', d, 'venue_id', ven, 'room_id', main))));
  EXCEPTION WHEN unique_violation THEN ok := true;
  END;
  ASSERT ok, 'B3: the same slot twice is refused';
  -- Clear C (level 1): A and B move up.
  h := public.exos_hold_clear(c);
  ASSERT h->>'status' = 'cleared' AND h->>'cleared_at' IS NOT NULL, 'B3: C cleared';
  ASSERT pg_temp.lvl(a, d, main) = 1 AND pg_temp.lvl(b, d, main) = 2 AND pg_temp.lvl(x, d, main) = 3, 'B3: promotion';
  ASSERT (SELECT level FROM public.exos_hold_positions WHERE hold_id = c) = 1, 'B3: a cleared night keeps its last level';
  ok := false;
  BEGIN
    PERFORM public.exos_hold_clear(c);
  EXCEPTION WHEN object_not_in_prerequisite_state THEN ok := true;
  END;
  ASSERT ok, 'B3: clearing a hold with no active nights is 409';
  -- Naming an already-cleared night changes nothing; a night of another hold is not found.
  PERFORM public.exos_hold_clear(c, ARRAY(SELECT id FROM public.exos_hold_positions WHERE hold_id = c));
  ok := false;
  BEGIN
    PERFORM public.exos_hold_clear(c, ARRAY(SELECT id FROM public.exos_hold_positions WHERE hold_id = a LIMIT 1));
  EXCEPTION WHEN no_data_found THEN ok := true;
  END;
  ASSERT ok, 'B3: another hold''s night is not found';

  -- Webhooks: hold.created x4, hold.updated for the clear, and for each hold that moved.
  ASSERT (SELECT count(*) FROM public.exos_webhook_deliveries WHERE org_id = o AND event_type = 'hold.created') = 4,
         'B3: hold.created per hold';
  ASSERT (SELECT count(*) FROM public.exos_webhook_deliveries
           WHERE org_id = o AND event_type = 'hold.updated' AND payload->'data'->>'reason' = 'level_changed'
             AND payload->'data'->'hold'->>'id' IN (a::text, b::text)) >= 4, 'B3: hold.updated for holds whose level moved';

  -- Update: B moves to level 1 and gets a new night; title changes.
  h := public.exos_hold_update(b, jsonb_build_object('title', 'Band B (co-headline)', 'positions', jsonb_build_array(
         jsonb_build_object('id', (SELECT id FROM public.exos_hold_positions WHERE hold_id = b AND date = d), 'level', 1, 'is_target', true),
         jsonb_build_object('date', '2026-11-15', 'venue_id', ven, 'room_id', main))));
  ASSERT h->>'title' = 'Band B (co-headline)', 'B3: title updated';
  ASSERT pg_temp.lvl(b, d, main) = 1 AND pg_temp.lvl(a, d, main) = 2, 'B3: moved to level 1';
  ASSERT pg_temp.lvl(b, '2026-11-15', main) = 2 AND pg_temp.lvl(a, '2026-11-15', main) = 1, 'B3: new night appended';
  ASSERT (SELECT is_target FROM public.exos_hold_positions WHERE hold_id = b AND date = d), 'B3: target flag';
  -- Full list: leaving the new night out clears it, and A's line closes up.
  h := public.exos_hold_update(b, jsonb_build_object('positions', jsonb_build_array(
         jsonb_build_object('id', (SELECT id FROM public.exos_hold_positions WHERE hold_id = b AND date = d)),
         jsonb_build_object('id', (SELECT id FROM public.exos_hold_positions WHERE hold_id = b AND date = d), 'level', 2))));
  ASSERT pg_temp.lvl(b, '2026-11-15', main) IS NULL, 'B3: omitted night cleared';
  ASSERT pg_temp.lvl(b, d, main) = 2 AND pg_temp.lvl(a, d, main) = 1, 'B3: moved back to level 2';
  -- Rental terms on a rented venue.
  h := public.exos_hold_create(o, jsonb_build_object('title', 'Rental show',
         'rental', jsonb_build_object('fee', 2500, 'deposit', '500', 'notes', 'Bar split TBD'),
         'positions', jsonb_build_array(jsonb_build_object('date', d, 'venue_id', (SELECT bb.v FROM bb WHERE k = 'rented')))));
  ASSERT h->'rental' = '{"fee": 2500.00, "notes": "Bar split TBD", "status": "requested", "deposit": 500.00, "currency": "USD"}'::jsonb,
         'B3: rental terms ' || (h->'rental')::text;
  ASSERT (h->'positions'->0->>'level')::int = 1, 'B3: rented venue line is separate';
  h := public.exos_hold_update((h->>'id')::uuid, '{"rental": null}');
  ASSERT h->'rental' = 'null'::jsonb, 'B3: rental removed';
  -- Levels are contiguous in every slot.
  SELECT count(*) INTO n FROM (
    SELECT venue_id, room_id, date, max(level) AS mx, count(*) AS cnt, count(DISTINCT level) AS dl
      FROM public.exos_hold_positions WHERE org_id = o AND status = 'active' GROUP BY 1, 2, 3) s
   WHERE mx <> cnt OR dl <> cnt;
  ASSERT n = 0, 'B3: every slot is 1..N';
  -- Staff read holds; the scanner doesn't.
  PERFORM pg_temp.as_user('bb000000-0000-0000-0000-0000000000a2');
  ASSERT (SELECT count(*) FROM public.exos_holds) = 5, 'B3: finance reads holds';
  PERFORM pg_temp.as_user('bb000000-0000-0000-0000-0000000000a3');
  ASSERT (SELECT count(*) FROM public.exos_holds) = 0 AND (SELECT count(*) FROM public.exos_hold_positions) = 0,
         'B3: scanner reads no holds';
  INSERT INTO bb VALUES ('a', a), ('b', b), ('e', x);
  RAISE NOTICE 'OK  B3 hold levels and promotion';
END $$;
RESET ROLE;

-- B4 -------------------------------------------------------------------------
SET ROLE authenticated;
DO $$
DECLARE
  o uuid := 'bb000000-0000-0000-0000-000000000001';
  ven uuid := (SELECT bb.v FROM bb WHERE k = 'venue');
  main uuid := (SELECT bb.v FROM bb WHERE k = 'main');
  loft uuid := (SELECT bb.v FROM bb WHERE k = 'loft');
  a uuid := (SELECT bb.v FROM bb WHERE k = 'a');
  b uuid := (SELECT bb.v FROM bb WHERE k = 'b');
  e uuid := (SELECT bb.v FROM bb WHERE k = 'e');
  d date := '2026-11-14';
  r jsonb; ev uuid; pos uuid; ok boolean; f uuid;
BEGIN
  PERFORM pg_temp.as_user('bb000000-0000-0000-0000-0000000000a0');
  ok := false;
  BEGIN
    PERFORM public.exos_hold_convert(a, '{}');
  EXCEPTION WHEN invalid_parameter_value THEN ok := true;
  END;
  ASSERT ok, 'B4: a night is required';
  ok := false;
  BEGIN
    PERFORM public.exos_hold_convert(a, jsonb_build_object('date', d));
  EXCEPTION WHEN invalid_parameter_value THEN ok := true;
  END;
  ASSERT ok, 'B4: two rooms that night needs position_id';
  pos := (SELECT id FROM public.exos_hold_positions WHERE hold_id = a AND date = d AND room_id = main);
  r := public.exos_hold_convert(a, jsonb_build_object('position_id', pos));
  ev := (r->>'event_id')::uuid;
  ASSERT (r->>'position_id')::uuid = pos, 'B4: the night converted';
  ASSERT (SELECT name = 'Band A' AND status = 'draft' AND timezone = 'America/Chicago'
                 AND starts_at = '2026-11-15T02:00:00Z'::timestamptz
                 AND occurs_at_local = '2026-11-14T20:00:00-06:00'
                 AND venue_name = 'Lincoln Hall — Main Room' AND venue_location = 'Chicago, IL'
                 AND venue_address->>'city' = 'Chicago' AND total_tickets = 450
                 AND exos_venue_id = ven AND exos_room_id = main AND hold_id = a AND hold_position_id = pos
                 AND created_by = 'bb000000-0000-0000-0000-0000000000a0'
            FROM public.exos_events WHERE id = ev), 'B4: draft event from the night';
  ASSERT (SELECT count(*) = 1 AND min(capacity) = 450 AND min(price) = 0 AND min(ticket_type) = 'free'
            FROM public.exos_ticket_tiers WHERE event_id = ev), 'B4: one free GA tier sized to the room';
  ASSERT (SELECT status = 'converted' AND event_id = ev FROM public.exos_hold_positions WHERE id = pos), 'B4: position converted';
  ASSERT (SELECT status FROM public.exos_hold_positions WHERE hold_id = a AND date = d AND room_id = loft) = 'cleared',
         'B4: the hold''s other room that night dropped';
  ASSERT pg_temp.lvl(a, '2026-11-15', main) = 1 AND (SELECT status FROM public.exos_holds WHERE id = a) = 'active',
         'B4: other nights stay active';
  ASSERT pg_temp.lvl(b, d, main) = 1 AND pg_temp.lvl(e, d, main) = 2, 'B4: the line moved up';
  ASSERT (SELECT count(*) FROM public.exos_show_activities WHERE event_id = ev AND kind = 'announce') = 1, 'B4: announce row carried';
  ASSERT (SELECT body FROM public.exos_event_notes WHERE event_id = ev) = 'Settle in the office.', 'B4: hold notes carried';
  ASSERT (SELECT count(*) FROM public.exos_webhook_deliveries
           WHERE org_id = o AND event_type = 'hold.converted' AND payload->'data'->'event'->>'id' = ev::text
             AND payload->'data'->>'position_id' = pos::text) = 1, 'B4: hold.converted webhook';
  ok := false;
  BEGIN
    PERFORM public.exos_hold_convert(a, jsonb_build_object('position_id', pos));
  EXCEPTION WHEN object_not_in_prerequisite_state THEN ok := true;
  END;
  ASSERT ok, 'B4: converting the night again is 409';
  -- Client can't forge hold links on an event.
  ok := false;
  BEGIN
    UPDATE public.exos_events SET hold_id = b WHERE id = ev;
  EXCEPTION WHEN insufficient_privilege THEN ok := true;
  END;
  ASSERT ok, 'B4: hold links are set only by convert';
  -- A copy (a series date, a duplicate) starts without them; the venue link stays.
  INSERT INTO public.exos_events (org_id, name, status, exos_venue_id, hold_id, hold_position_id)
  VALUES (o, 'Copy', 'draft', ven, a, pos) RETURNING id INTO f;
  ASSERT (SELECT hold_id IS NULL AND hold_position_id IS NULL AND exos_venue_id = ven FROM public.exos_events WHERE id = f),
         'B4: a copied event drops the hold links';

  -- B's night with clear_holds_on_day: E's main-room night and its whole-venue night go too.
  r := public.exos_hold_convert(b, jsonb_build_object('date', d, 'time', '19:30', 'title', 'B live', 'capacity', 300,
                                                    'clear_holds_on_day', true));
  ASSERT (SELECT starts_at = '2026-11-15T01:30:00Z'::timestamptz AND name = 'B live' AND total_tickets = 300
            FROM public.exos_events WHERE id = (r->>'event_id')::uuid), 'B4: time, title and capacity';
  ASSERT (SELECT status FROM public.exos_holds WHERE id = e) = 'cleared', 'B4: clear_holds_on_day cleared E';
  ASSERT (SELECT status FROM public.exos_holds WHERE id = b) = 'converted', 'B4: B converted';
  -- A whole-venue night converts with the venue's capacity.
  f := (public.exos_hold_create(o, jsonb_build_object('title', 'Venue buyout', 'positions',
          jsonb_build_array(jsonb_build_object('date', '2026-12-01', 'venue_id', ven))))->>'id')::uuid;
  r := public.exos_hold_convert(f, jsonb_build_object('date', '2026-12-01'));
  ASSERT (SELECT total_tickets = 520 AND venue_name = 'Lincoln Hall' AND exos_room_id IS NULL
            FROM public.exos_events WHERE id = (r->>'event_id')::uuid), 'B4: whole venue uses the venue capacity';
  INSERT INTO bb VALUES ('ev', ev);
  RAISE NOTICE 'OK  B4 convert one night';
END $$;
RESET ROLE;

-- B5 -------------------------------------------------------------------------
UPDATE public.exos_events SET starts_at = '2026-11-15T02:00:00Z' WHERE id = (SELECT bb.v FROM bb WHERE k = 'ev');
SET ROLE authenticated;
DO $$
DECLARE
  ev uuid := (SELECT bb.v FROM bb WHERE k = 'ev');
  t0 timestamptz := '2026-11-15T02:00:00Z';
  doors uuid; ok boolean; n int;
BEGIN
  PERFORM pg_temp.as_user('bb000000-0000-0000-0000-0000000000a4');   -- content edits the schedule
  INSERT INTO public.exos_show_activities (event_id, org_id, kind, name, starts_at)
  VALUES (ev, 'bb000000-0000-0000-0000-000000000002', 'load_in', 'Load in', t0 - interval '6 hours');
  ASSERT (SELECT org_id FROM public.exos_show_activities WHERE event_id = ev AND kind = 'load_in')
         = 'bb000000-0000-0000-0000-000000000001', 'B5: org from the event';
  ok := false;
  BEGIN
    INSERT INTO public.exos_show_activities (event_id, org_id, kind, name, starts_at)
    VALUES (ev, 'bb000000-0000-0000-0000-000000000001', 'doors', 'Doors', t0 + interval '30 minutes');
  EXCEPTION WHEN invalid_parameter_value THEN ok := true;
  END;
  ASSERT ok, 'B5: doors after the start refused';
  ok := false;
  BEGIN
    INSERT INTO public.exos_show_activities (event_id, org_id, kind, name, starts_at, ends_at)
    VALUES (ev, 'bb000000-0000-0000-0000-000000000001', 'set', 'Set', t0 + interval '1 hour', t0);
  EXCEPTION WHEN check_violation THEN ok := true;
  END;
  ASSERT ok, 'B5: ends before it starts refused';
  INSERT INTO public.exos_show_activities (event_id, org_id, kind, name, starts_at)
  VALUES (ev, 'bb000000-0000-0000-0000-000000000001', 'doors', 'Doors', t0 - interval '1 hour')
  RETURNING id INTO doors;
  ASSERT (SELECT doors_at FROM public.exos_events WHERE id = ev) = t0 - interval '1 hour', 'B5: doors row sets doors_at';
  ok := false;
  BEGIN
    INSERT INTO public.exos_show_activities (event_id, org_id, kind, name, starts_at)
    VALUES (ev, 'bb000000-0000-0000-0000-000000000001', 'doors', 'Doors 2', t0 - interval '45 minutes');
  EXCEPTION WHEN unique_violation THEN ok := true;
  END;
  ASSERT ok, 'B5: one doors row per event';
  UPDATE public.exos_show_activities SET starts_at = t0 - interval '90 minutes' WHERE id = doors;
  ASSERT (SELECT doors_at FROM public.exos_events WHERE id = ev) = t0 - interval '90 minutes', 'B5: moving the row moves doors_at';
  -- Edit Event / the API move doors_at: the row follows.
  UPDATE public.exos_events SET doors_at = t0 - interval '30 minutes' WHERE id = ev;
  ASSERT (SELECT starts_at FROM public.exos_show_activities WHERE id = doors) = t0 - interval '30 minutes', 'B5: doors_at moves the row';
  -- Scanner reads the schedule (door page header).
  PERFORM pg_temp.as_user('bb000000-0000-0000-0000-0000000000a3');
  ASSERT (SELECT count(*) FROM public.exos_show_activities WHERE event_id = ev) = 3, 'B5: scanner reads the schedule';
  UPDATE public.exos_show_activities SET name = 'x';
  GET DIAGNOSTICS n = ROW_COUNT;
  ASSERT n = 0, 'B5: scanner can''t edit';
  PERFORM pg_temp.as_user('bb000000-0000-0000-0000-0000000000a5');
  ASSERT (SELECT count(*) FROM public.exos_show_activities) = 0, 'B5: stranger sees nothing';
  -- Deleting the doors row clears doors_at; clearing doors_at deletes the row.
  PERFORM pg_temp.as_user('bb000000-0000-0000-0000-0000000000a1');
  DELETE FROM public.exos_show_activities WHERE id = doors;
  ASSERT (SELECT doors_at FROM public.exos_events WHERE id = ev) IS NULL, 'B5: deleting the row clears doors_at';
  INSERT INTO public.exos_show_activities (event_id, org_id, kind, name, starts_at)
  VALUES (ev, 'bb000000-0000-0000-0000-000000000001', 'doors', 'Doors', t0 - interval '1 hour');
  UPDATE public.exos_events SET doors_at = NULL WHERE id = ev;
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_show_activities WHERE event_id = ev AND kind = 'doors'),
         'B5: clearing doors_at deletes the row';
  RAISE NOTICE 'OK  B5 show schedule and doors';
END $$;
RESET ROLE;

-- B6 -------------------------------------------------------------------------
SET ROLE authenticated;
DO $$
DECLARE ev uuid := (SELECT bb.v FROM bb WHERE k = 'ev'); note uuid; ok boolean; n int; x uuid;
BEGIN
  PERFORM pg_temp.as_user('bb000000-0000-0000-0000-0000000000a4');   -- content
  INSERT INTO public.exos_event_notes (event_id, org_id, body, author_id, author_name)
  VALUES (ev, 'bb000000-0000-0000-0000-000000000001', 'Rider: two towels.', 'bb000000-0000-0000-0000-0000000000a0', 'Cee')
  RETURNING id INTO note;
  ASSERT (SELECT author_id FROM public.exos_event_notes WHERE id = note) = 'bb000000-0000-0000-0000-0000000000a4',
         'B6: author is the signed-in user';
  INSERT INTO public.exos_event_contacts (event_id, org_id, role, title, name, email, company)
  VALUES (ev, 'bb000000-0000-0000-0000-000000000001', 'agent', 'Responsible agent', ' Ana Agent ', 'ANA@agency.example', 'Agency');
  ASSERT (SELECT name = 'Ana Agent' AND email = 'ana@agency.example' FROM public.exos_event_contacts WHERE event_id = ev),
         'B6: contact trimmed';
  ok := false;
  BEGIN
    INSERT INTO public.exos_event_contacts (event_id, org_id, role, name) VALUES (ev, 'bb000000-0000-0000-0000-000000000001', 'fan', 'X');
  EXCEPTION WHEN check_violation THEN ok := true;
  END;
  ASSERT ok, 'B6: bad role refused';
  -- Finance reads, can't write; scanner and stranger see nothing.
  PERFORM pg_temp.as_user('bb000000-0000-0000-0000-0000000000a2');
  ASSERT (SELECT count(*) FROM public.exos_event_notes) = 2 AND (SELECT count(*) FROM public.exos_event_contacts) = 1,
         'B6: finance reads notes and contacts';
  ok := false;
  BEGIN
    INSERT INTO public.exos_event_notes (event_id, org_id, body) VALUES (ev, 'bb000000-0000-0000-0000-000000000001', 'x');
  EXCEPTION WHEN insufficient_privilege THEN ok := true;
  END;
  ASSERT ok, 'B6: finance can''t add a note';
  FOREACH x IN ARRAY ARRAY['bb000000-0000-0000-0000-0000000000a3', 'bb000000-0000-0000-0000-0000000000a5',
                           'bb000000-0000-0000-0000-0000000000b9']::uuid[] LOOP
    PERFORM pg_temp.as_user(x::text);
    ASSERT (SELECT count(*) FROM public.exos_event_notes) = 0 AND (SELECT count(*) FROM public.exos_event_contacts) = 0,
           'B6: no notes or contacts for ' || x;
  END LOOP;
  -- Content can't delete the owner's carried note; the manager can.
  PERFORM pg_temp.as_user('bb000000-0000-0000-0000-0000000000a4');
  DELETE FROM public.exos_event_notes WHERE id <> note;
  GET DIAGNOSTICS n = ROW_COUNT;
  ASSERT n = 0, 'B6: content can''t delete someone else''s note';
  UPDATE public.exos_event_notes SET body = 'Rider: three towels.', author_id = 'bb000000-0000-0000-0000-0000000000a1' WHERE id = note;
  ASSERT (SELECT body = 'Rider: three towels.' AND author_id = 'bb000000-0000-0000-0000-0000000000a4'
            FROM public.exos_event_notes WHERE id = note), 'B6: author edits own note, authorship fixed';
  PERFORM pg_temp.as_user('bb000000-0000-0000-0000-0000000000a1');
  DELETE FROM public.exos_event_notes WHERE id <> note;
  GET DIAGNOSTICS n = ROW_COUNT;
  ASSERT n = 1, 'B6: manager deletes it';
  RAISE NOTICE 'OK  B6 notes and contacts';
END $$;
RESET ROLE;

-- B7 -------------------------------------------------------------------------
SET ROLE authenticated;
DO $$
DECLARE
  a uuid := (SELECT bb.v FROM bb WHERE k = 'a');
  ven uuid := (SELECT bb.v FROM bb WHERE k = 'venue');
  ev uuid := (SELECT bb.v FROM bb WHERE k = 'ev');
  theirs uuid; their_ev uuid; h jsonb; ok boolean; n int;
BEGIN
  PERFORM pg_temp.as_user('bb000000-0000-0000-0000-0000000000b9');
  ASSERT (SELECT count(*) FROM public.exos_venues) = 0 AND (SELECT count(*) FROM public.exos_holds) = 0
     AND (SELECT count(*) FROM public.exos_hold_positions) = 0 AND (SELECT count(*) FROM public.exos_show_activities) = 0,
         'B7: other org sees nothing of ours';
  FOREACH h IN ARRAY ARRAY['{"op":"update"}', '{"op":"clear"}', '{"op":"convert"}']::jsonb[] LOOP
    ok := false;
    BEGIN
      CASE h->>'op'
        WHEN 'update' THEN PERFORM public.exos_hold_update(a, '{"title":"Mine now"}');
        WHEN 'clear' THEN PERFORM public.exos_hold_clear(a);
        ELSE PERFORM public.exos_hold_convert(a, '{"date":"2026-11-15"}');
      END CASE;
    EXCEPTION WHEN insufficient_privilege THEN ok := true;
    END;
    ASSERT ok, 'B7: other org refused: ' || (h->>'op');
  END LOOP;
  -- Holding our venue from their org: not found in their org.
  ok := false;
  BEGIN
    PERFORM public.exos_hold_create('bb000000-0000-0000-0000-000000000002', jsonb_build_object('title', 'Foreign',
      'positions', jsonb_build_array(jsonb_build_object('date', '2026-11-15', 'venue_id', ven))));
  EXCEPTION WHEN invalid_parameter_value THEN ok := true;
  END;
  ASSERT ok, 'B7: another org''s venue is not found';
  -- Their own venue: their own line, level 1, untouched by ours.
  INSERT INTO public.exos_venues (org_id, name, timezone) VALUES ('bb000000-0000-0000-0000-000000000002', 'Their Hall', 'UTC')
  RETURNING id INTO theirs;
  h := public.exos_hold_create('bb000000-0000-0000-0000-000000000002', jsonb_build_object('title', 'Theirs',
    'positions', jsonb_build_array(jsonb_build_object('date', '2026-11-15', 'venue_id', theirs))));
  ASSERT (h->'positions'->0->>'level')::int = 1, 'B7: their own line';
  -- Their event can't link our venue; no writes on our event's schedule.
  INSERT INTO public.exos_events (org_id, name, status, starts_at) VALUES ('bb000000-0000-0000-0000-000000000002', 'Theirs', 'draft', now())
  RETURNING id INTO their_ev;
  ok := false;
  BEGIN
    UPDATE public.exos_events SET exos_venue_id = ven WHERE id = their_ev;
  EXCEPTION WHEN invalid_parameter_value THEN ok := true;
  END;
  ASSERT ok, 'B7: an event can''t link another org''s venue';
  UPDATE public.exos_events SET exos_venue_id = theirs WHERE id = their_ev;
  ok := false;
  BEGIN
    INSERT INTO public.exos_show_activities (event_id, org_id, kind, name, starts_at)
    VALUES (ev, 'bb000000-0000-0000-0000-000000000002', 'other', 'Sneaky', now());
  EXCEPTION WHEN insufficient_privilege THEN ok := true;
  END;
  ASSERT ok, 'B7: no schedule row on our event';
  RAISE NOTICE 'OK  B7 cross-org isolation';
END $$;
RESET ROLE;

-- The service_role cores (exos-api) act for the org they are given.
SET ROLE service_role;
DO $$
DECLARE h jsonb;
BEGIN
  h := public._exos_hold_create('bb000000-0000-0000-0000-000000000001', NULL, 'api', NULL, jsonb_build_object('title', 'From the API',
         'positions', jsonb_build_array(jsonb_build_object('date', '2026-11-20', 'venue_id', (SELECT bb.v FROM bb WHERE k = 'venue')))));
  ASSERT h->>'created_via' = 'api', 'B8: API hold';
  BEGIN
    PERFORM public._exos_hold_update('bb000000-0000-0000-0000-000000000002', (h->>'id')::uuid, '{"title":"x"}');
    RAISE EXCEPTION 'B8: a key of another org updated the hold';
  EXCEPTION WHEN no_data_found THEN NULL;
  END;
  RAISE NOTICE 'OK  B8 service_role cores scoped to the given org';
END $$;
DO $$
DECLARE o uuid := 'bb000000-0000-0000-0000-000000000001'; c jsonb; p jsonb; late uuid; n int;
BEGIN
  -- A new hold on a night that already has a show in that room is challenged.
  late := (public._exos_hold_create(o, NULL, 'api', NULL, jsonb_build_object('title', 'Late add', 'positions',
            jsonb_build_array(jsonb_build_object('date', '2026-11-14', 'venue_id', (SELECT bb.v FROM bb WHERE k = 'venue'),
                                                 'room_id', (SELECT bb.v FROM bb WHERE k = 'main')))))->>'id')::uuid;
  c := public._exos_booking_calendar(o, '2026-11-01', '2026-11-30', NULL);
  ASSERT (SELECT (x->>'challenged')::boolean FROM jsonb_array_elements(c->'holds') x WHERE x->>'hold_id' = late::text),
         'B9: a hold against a booked show is challenged';
  ASSERT NOT (SELECT (x->>'challenged')::boolean FROM jsonb_array_elements(c->'holds') x
               WHERE x->>'hold_id' = (SELECT bb.v FROM bb WHERE k = 'a')::text), 'B9: a lone hold is not challenged';
  ASSERT (SELECT count(*) FROM jsonb_array_elements(c->'events') x WHERE x->>'date' = '2026-11-14') = 2,
         'B9: the two shows on their local date';
  ASSERT NOT EXISTS (SELECT 1 FROM jsonb_array_elements(c->'holds') x WHERE x->>'title' = 'Theirs'), 'B9: only our holds';
  BEGIN
    PERFORM public._exos_booking_calendar(o, '2026-01-01', '2026-12-31', NULL);
    RAISE EXCEPTION 'B9: a year-long calendar was accepted';
  EXCEPTION WHEN invalid_parameter_value THEN NULL;
  END;
  -- Hold pages: filters on any night, status, title.
  p := public._exos_holds_page(o, '2026-11-14', '2026-11-14', NULL, (SELECT bb.v FROM bb WHERE k = 'main'), NULL, NULL, 50, 0);
  ASSERT (p->>'total')::int = 5, 'B9: holds with a main-room night on the 14th, got ' || (p->>'total');
  p := public._exos_holds_page(o, NULL, NULL, NULL, NULL, 'cleared', NULL, 50, 0);
  ASSERT (SELECT array_agg(x->>'title' ORDER BY x->>'title') FROM jsonb_array_elements(p->'data') x) = ARRAY['Band C', 'Band E'],
         'B9: cleared holds';
  p := public._exos_holds_page(o, NULL, NULL, NULL, NULL, NULL, 'band', 2, 2);
  ASSERT (p->>'total')::int = 4 AND jsonb_array_length(p->'data') = 2, 'B9: title search, paged';
  p := public._exos_holds_page('bb000000-0000-0000-0000-000000000002', NULL, NULL, NULL, NULL, NULL, NULL, 50, 0);
  ASSERT (p->>'total')::int = 1, 'B9: another org''s page is its own';
  RAISE NOTICE 'OK  B9 calendar and hold pages';
END $$;
RESET ROLE;

ROLLBACK;
