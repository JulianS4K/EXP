-- ============================================================================
-- Exos Door imports (mig 20261013090000):
--   I1 owner imports: codes normalized, ticket + source kept, bad rows reported
--   I2 importing the same export again adds nothing; a code twice in one file
--      counts once
--   I3 only owners / managers import (scanner, outsider, anon refused)
--   I4 the door download carries code / ticket / source; the per-event
--      scanner scope now applies to it
--   I5 an imported guest checks in through exos_guest_check_in, once
--   I6 list rules still apply (cap, plus-ones)
--   I7 limits: not an array, more than 5000 rows
--   I8 grants; _exos_door_code is internal
-- Self-contained (BEGIN / ROLLBACK). Org d3…01 owned by …a1; manager …a2,
-- scanner …a3 (unscoped), scanner …a4 (assigned to e2 only), outsider …a6.
-- ============================================================================
\set ON_ERROR_STOP on
BEGIN;

INSERT INTO auth.users(id,email,email_confirmed_at) VALUES
  ('d3000000-0000-0000-0000-0000000000a1','d3own@x.com',now()),
  ('d3000000-0000-0000-0000-0000000000a2','d3mgr@x.com',now()),
  ('d3000000-0000-0000-0000-0000000000a3','d3scan@x.com',now()),
  ('d3000000-0000-0000-0000-0000000000a4','d3scan2@x.com',now()),
  ('d3000000-0000-0000-0000-0000000000a6','d3out@x.com',now());
INSERT INTO public.exos_orgs(id,name,slug,owner_uid) VALUES
  ('d3000000-0000-0000-0000-000000000001','Door Org','door-org-stub','d3000000-0000-0000-0000-0000000000a1'),
  ('d3000000-0000-0000-0000-000000000002','Other Org','door-other-stub','d3000000-0000-0000-0000-0000000000a6');
INSERT INTO public.exos_org_memberships(org_id,user_id,role) VALUES
  ('d3000000-0000-0000-0000-000000000001','d3000000-0000-0000-0000-0000000000a1','owner'),
  ('d3000000-0000-0000-0000-000000000001','d3000000-0000-0000-0000-0000000000a2','manager'),
  ('d3000000-0000-0000-0000-000000000001','d3000000-0000-0000-0000-0000000000a3','scanner'),
  ('d3000000-0000-0000-0000-000000000001','d3000000-0000-0000-0000-0000000000a4','scanner'),
  ('d3000000-0000-0000-0000-000000000002','d3000000-0000-0000-0000-0000000000a6','owner');
-- e1: a door-only event (draft, no tiers), doors open. e2: where a4 works.
INSERT INTO public.exos_events(id,org_id,name,slug,status,starts_at,doors_at,total_tickets,created_by) VALUES
  ('d3000000-0000-0000-0000-0000000000e1','d3000000-0000-0000-0000-000000000001','Imported Night','door-imp-stub','draft',
   now() + interval '1 hour', now() - interval '1 hour', 0, 'd3000000-0000-0000-0000-0000000000a1'),
  ('d3000000-0000-0000-0000-0000000000e2','d3000000-0000-0000-0000-000000000001','Other Night','door-oth-stub','draft',
   now() + interval '1 hour', now() - interval '1 hour', 0, 'd3000000-0000-0000-0000-0000000000a1');
INSERT INTO public.exos_event_staff(event_id, user_id, org_id) VALUES
  ('d3000000-0000-0000-0000-0000000000e2','d3000000-0000-0000-0000-0000000000a4','d3000000-0000-0000-0000-000000000001');

CREATE FUNCTION pg_temp.act(p_uid text) RETURNS void LANGUAGE sql AS $$
  SELECT set_config('app.uid', coalesce(p_uid, ''), false), set_config('app.jwt', '{"email":"door@x.com"}', false);
$$;
CREATE TABLE pg_temp.ids (k text PRIMARY KEY, v uuid);

DO $$
BEGIN
  PERFORM pg_temp.act('d3000000-0000-0000-0000-0000000000a1');
  INSERT INTO pg_temp.ids VALUES
    ('list', public.exos_upsert_guest_list('d3000000-0000-0000-0000-0000000000e1', 'Eventbrite import')),
    ('small', public.exos_upsert_guest_list('d3000000-0000-0000-0000-0000000000e1', 'Small', 2, NULL, false, 1));
END $$;
CREATE FUNCTION pg_temp.list(p text) RETURNS uuid LANGUAGE sql AS $$ SELECT v FROM pg_temp.ids WHERE k = p $$;
CREATE FUNCTION pg_temp.imp(p_list text, p_rows jsonb) RETURNS jsonb LANGUAGE sql AS $$
  SELECT public.exos_import_guests(pg_temp.list(p_list), p_rows);
$$;

-- I1. Import.
DO $$
DECLARE r jsonb; g record;
BEGIN
  PERFORM pg_temp.act('d3000000-0000-0000-0000-0000000000a1');
  r := pg_temp.imp('list', jsonb_build_array(
    jsonb_build_object('name', ' Ada Lovelace ', 'email', 'ADA@x.com', 'code', ' 1234 5678 9001 ', 'ticket', 'General Admission', 'source', 'Eventbrite'),
    jsonb_build_object('name', 'Bo Diddley', 'email', 'bo@x.com', 'ticket', 'VIP', 'source', 'Eventbrite'),
    jsonb_build_object('email', 'noname@x.com', 'code', 'X1'),
    jsonb_build_object('name', 'Long Code', 'code', repeat('Z', 129)),
    jsonb_build_object('name', 'Bad Email', 'email', 'not-an-email', 'code', 'eb-77', 'plus_ones', 'lots')));
  ASSERT r->>'inserted' = '3' AND r->>'duplicates' = '0' AND r->>'invalid' = '2', 'I1: counts ' || r::text;
  ASSERT r->'errors' = '[{"row":3,"reason":"missing name"},{"row":4,"reason":"code too long"}]'::jsonb, 'I1: errors ' || (r->'errors')::text;
  SELECT * INTO g FROM public.exos_guest_list_entries WHERE external_code = '123456789001';
  ASSERT g.guest_name = 'Ada Lovelace' AND g.email = 'ada@x.com' AND g.ticket_label = 'General Admission'
         AND g.source = 'Eventbrite' AND g.plus_ones = 0, 'I1: normalized row';
  SELECT * INTO g FROM public.exos_guest_list_entries WHERE external_code = 'EB-77';
  ASSERT g.email IS NULL AND g.plus_ones = 0, 'I1: a bad email / plus-ones is dropped, not fatal';
  ASSERT (SELECT external_code FROM public.exos_guest_list_entries WHERE guest_name = 'Bo Diddley') IS NULL, 'I1: no code is fine';
END $$;

-- I2. Re-import.
DO $$
DECLARE r jsonb;
BEGIN
  PERFORM pg_temp.act('d3000000-0000-0000-0000-0000000000a2');
  r := pg_temp.imp('list', jsonb_build_array(
    jsonb_build_object('name', 'Ada Lovelace', 'code', '123456789001'),
    jsonb_build_object('name', 'Bo Diddley', 'email', 'BO@x.com'),
    jsonb_build_object('name', 'Cy Twombly', 'code', 'tw-1'),
    jsonb_build_object('name', 'Cy Twombly again', 'code', 'TW-1')));
  ASSERT r->>'inserted' = '1' AND r->>'duplicates' = '3' AND r->>'invalid' = '0', 'I2: ' || r::text;
  -- A code is unique per event, not per list.
  r := pg_temp.imp('small', jsonb_build_array(jsonb_build_object('name', 'Ada again', 'code', '123456789001')));
  ASSERT r->>'duplicates' = '1' AND r->>'inserted' = '0', 'I2: same code on another list of the event';
END $$;

-- I3. Who may import.
DO $$
DECLARE u text;
BEGIN
  FOREACH u IN ARRAY ARRAY['', 'd3000000-0000-0000-0000-0000000000a3', 'd3000000-0000-0000-0000-0000000000a6'] LOOP
    PERFORM pg_temp.act(nullif(u, ''));
    BEGIN
      PERFORM pg_temp.imp('list', '[{"name":"Sneaky"}]'::jsonb);
      RAISE EXCEPTION 'I3: % imported', coalesce(nullif(u, ''), 'anon');
    EXCEPTION WHEN insufficient_privilege THEN NULL;
    END;
  END LOOP;
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_guest_list_entries WHERE guest_name = 'Sneaky'), 'I3: nothing written';
END $$;

-- I4. Door download.
DO $$
DECLARE x jsonb; g jsonb;
BEGIN
  PERFORM pg_temp.act('d3000000-0000-0000-0000-0000000000a3');
  x := public.exos_event_door_extras('d3000000-0000-0000-0000-0000000000e1');
  SELECT e INTO g FROM jsonb_array_elements(x->'guests') e WHERE e->>'guest_name' = 'Ada Lovelace';
  ASSERT g->>'code' = '123456789001' AND g->>'ticket' = 'General Admission' AND g->>'source' = 'Eventbrite',
         'I4: code / ticket / source ' || coalesce(g::text, 'null');
  ASSERT NOT (g ? 'email'), 'I4: still no email at the door';
  PERFORM pg_temp.act('d3000000-0000-0000-0000-0000000000a4');
  BEGIN
    PERFORM public.exos_event_door_extras('d3000000-0000-0000-0000-0000000000e1');
    RAISE EXCEPTION 'I4: a scanner assigned elsewhere downloaded the guests';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  ASSERT public.exos_event_door_extras('d3000000-0000-0000-0000-0000000000e2') ? 'guests', 'I4: their own event works';
END $$;

-- I5. Check in an imported guest.
DO $$
DECLARE r jsonb; v_id uuid;
BEGIN
  PERFORM pg_temp.act('d3000000-0000-0000-0000-0000000000a3');
  SELECT id INTO v_id FROM public.exos_guest_list_entries WHERE external_code = '123456789001';
  r := public.exos_guest_check_in(v_id, 1, 'd3000000-0000-0000-0000-0000000000e1', gen_random_uuid(), 'online');
  ASSERT r->>'ok' = 'true' AND r->>'reason' = 'checked-in', 'I5: in ' || r::text;
  r := public.exos_guest_check_in(v_id, 1, 'd3000000-0000-0000-0000-0000000000e1', gen_random_uuid(), 'online');
  ASSERT r->>'ok' = 'false' AND r->>'reason' = 'used', 'I5: once ' || r::text;
END $$;

-- I6. List rules (Small: cap 2 heads, at most 1 plus-one).
DO $$
DECLARE r jsonb;
BEGIN
  PERFORM pg_temp.act('d3000000-0000-0000-0000-0000000000a1');
  r := pg_temp.imp('small', jsonb_build_array(
    jsonb_build_object('name', 'Duo', 'plus_ones', '1', 'code', 'S-1'),
    jsonb_build_object('name', 'Trio', 'plus_ones', '2', 'code', 'S-2'),
    jsonb_build_object('name', 'Late', 'code', 'S-3')));
  ASSERT r->>'inserted' = '1' AND r->>'invalid' = '2', 'I6: ' || r::text;
  ASSERT (r->'errors'->0->>'reason') LIKE 'this list allows up to 1 plus-one%', 'I6: plus-ones reason ' || (r->'errors')::text;
  ASSERT (r->'errors'->1->>'reason') LIKE 'the list is full%', 'I6: cap reason';
END $$;

-- I7. Limits.
DO $$
BEGIN
  PERFORM pg_temp.act('d3000000-0000-0000-0000-0000000000a1');
  BEGIN
    PERFORM pg_temp.imp('list', '{"name":"x"}'::jsonb);
    RAISE EXCEPTION 'I7: an object was accepted';
  EXCEPTION WHEN invalid_parameter_value THEN NULL;
  END;
  BEGIN
    PERFORM pg_temp.imp('list', (SELECT jsonb_agg(jsonb_build_object('name', 'n' || g)) FROM generate_series(1, 5001) g));
    RAISE EXCEPTION 'I7: 5001 rows were accepted';
  EXCEPTION WHEN invalid_parameter_value THEN NULL;
  END;
END $$;

-- I8. Grants.
DO $$
BEGIN
  ASSERT has_function_privilege('authenticated', 'public.exos_import_guests(uuid,jsonb)', 'EXECUTE'), 'I8: authenticated imports';
  ASSERT NOT has_function_privilege('anon', 'public.exos_import_guests(uuid,jsonb)', 'EXECUTE'), 'I8: anon may not';
  ASSERT NOT has_function_privilege('authenticated', 'public._exos_door_code(text)', 'EXECUTE'), 'I8: helper internal';
  ASSERT public._exos_door_code('  ab c ') = 'ABC' AND public._exos_door_code('') IS NULL, 'I8: normalization';
END $$;

\echo 'test_door_imports: all passed'
ROLLBACK;
