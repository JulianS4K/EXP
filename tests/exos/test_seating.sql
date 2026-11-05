-- ============================================================================
-- Reserved seating (mig 20261030140000). Self-contained (5ea… ids), rolled
-- back at the end.
--   S1  seat maps: owner / manager write, staff read, other orgs see nothing,
--       invalid maps refused, seat count kept
--   S2  assigning a map: levels → seats, seated tiers' capacity and flag
--       (server-written; client edits ignored), GA-sold tiers refused
--   S3  anon sees a published event's layout and seat status only
--   S4  two buyers racing for one seat: one wins, the other gets 409 naming it
--   S5  hold expiry frees the seat (active-but-expired and cron-expired)
--   S6  fulfillment assigns the held seats in the same transaction; receipt,
--       wallet payload and door roster carry the seat
--   S7  a seat lost while paying fails the order (refunded), nothing sold
--   S8  a refund / void frees the seat
--   S9  general-admission tiers are unaffected
--   S10 comps / box office / partner mints refuse seated tiers; holding seats
--       on a GA tier is refused
--   S11 cross-org isolation
--   S12 block / unblock follow capacity; a sold seat can't be blocked;
--       seating locked once seats sold
--   S13 reconciliation finds and releases orphans, never a live seat
--   psql -d <db> -v ON_ERROR_STOP=1 -f tests/exos/test_seating.sql
-- ============================================================================
\set ON_ERROR_STOP on
BEGIN;

INSERT INTO auth.users (id, email, email_confirmed_at) VALUES
  ('5ea00000-0000-0000-0000-0000000000a0', 'st-owner@x.com', now()),
  ('5ea00000-0000-0000-0000-0000000000a1', 'st-manager@x.com', now()),
  ('5ea00000-0000-0000-0000-0000000000a3', 'st-scanner@x.com', now()),
  ('5ea00000-0000-0000-0000-0000000000b1', 'st-buyer-a@x.com', now()),
  ('5ea00000-0000-0000-0000-0000000000b2', 'st-buyer-b@x.com', now()),
  ('5ea00000-0000-0000-0000-0000000000b3', 'st-buyer-c@x.com', now()),
  ('5ea00000-0000-0000-0000-0000000000b9', 'st-other-owner@x.com', now());
INSERT INTO public.exos_orgs (id, name, slug, owner_uid) VALUES
  ('5ea00000-0000-0000-0000-000000000001', 'ST Org', 'st-org', '5ea00000-0000-0000-0000-0000000000a0'),
  ('5ea00000-0000-0000-0000-000000000002', 'ST Other', 'st-other', '5ea00000-0000-0000-0000-0000000000b9');
INSERT INTO public.exos_org_memberships (org_id, user_id, role) VALUES
  ('5ea00000-0000-0000-0000-000000000001', '5ea00000-0000-0000-0000-0000000000a0', 'owner'),
  ('5ea00000-0000-0000-0000-000000000001', '5ea00000-0000-0000-0000-0000000000a1', 'manager'),
  ('5ea00000-0000-0000-0000-000000000001', '5ea00000-0000-0000-0000-0000000000a3', 'scanner'),
  ('5ea00000-0000-0000-0000-000000000002', '5ea00000-0000-0000-0000-0000000000b9', 'owner');
INSERT INTO public.exos_events (id, org_id, name, slug, status, starts_at, total_tickets) VALUES
  ('5ea00000-0000-0000-0000-0000000000e1', '5ea00000-0000-0000-0000-000000000001', 'ST Show', 'st-show', 'published', now() + interval '9 days', 0),
  ('5ea00000-0000-0000-0000-0000000000e2', '5ea00000-0000-0000-0000-000000000001', 'ST Draft', 'st-draft', 'draft', now() + interval '9 days', 0);
INSERT INTO public.exos_ticket_tiers (id, event_id, name, price, capacity, sold, visibility) VALUES
  ('5ea00000-0000-0000-0000-0000000000d1', '5ea00000-0000-0000-0000-0000000000e1', 'Orchestra', 50, 999, 0, 'public'),
  ('5ea00000-0000-0000-0000-0000000000d2', '5ea00000-0000-0000-0000-0000000000e1', 'Standing', 20, 100, 0, 'public'),
  ('5ea00000-0000-0000-0000-0000000000d3', '5ea00000-0000-0000-0000-0000000000e1', 'Old GA', 20, 100, 1, 'public'),
  ('5ea00000-0000-0000-0000-0000000000d4', '5ea00000-0000-0000-0000-0000000000e2', 'Draft seats', 10, 10, 0, 'public');

-- A 2-row x 4-seat section "Orchestra" (rows A, B; seats 1-4) and a standing area.
CREATE TEMP TABLE st_map AS SELECT jsonb_build_object(
  'width', 1000, 'height', 700,
  'stage', jsonb_build_object('x', 300, 'y', 20, 'w', 400, 'h', 60, 'label', 'Stage'),
  'sections', jsonb_build_array(
    jsonb_build_object('id', 's1', 'name', 'Orchestra', 'kind', 'seated', 'x', 400, 'y', 140,
      'rows', jsonb_build_array(
        jsonb_build_object('id', 'r1', 'label', 'A', 'seats', jsonb_build_array(
          jsonb_build_object('key', '1', 'label', '1', 'x', 0, 'y', 0),
          jsonb_build_object('key', '2', 'label', '2', 'x', 24, 'y', 0),
          jsonb_build_object('key', '3', 'label', '3', 'x', 48, 'y', 0),
          jsonb_build_object('key', '4', 'label', '4', 'x', 72, 'y', 0, 'accessible', true))),
        jsonb_build_object('id', 'r2', 'label', 'B', 'seats', jsonb_build_array(
          jsonb_build_object('key', '1', 'label', '1', 'x', 0, 'y', 28),
          jsonb_build_object('key', '2', 'label', '2', 'x', 24, 'y', 28),
          jsonb_build_object('key', '3', 'label', '3', 'x', 48, 'y', 28),
          jsonb_build_object('key', '4', 'label', '4', 'x', 72, 'y', 28))))),
    jsonb_build_object('id', 'g1', 'name', 'Floor', 'kind', 'ga', 'x', 100, 'y', 400, 'w', 200, 'h', 120, 'capacity', 100)
  )) AS m;
GRANT SELECT ON st_map TO authenticated, anon;

CREATE FUNCTION pg_temp.act(p_uid text) RETURNS void LANGUAGE sql AS $$
  SELECT set_config('app.uid', coalesce(p_uid, ''), true), set_config('app.jwt', '', true);
$$;
GRANT EXECUTE ON FUNCTION pg_temp.act(text) TO anon, authenticated;

-- S1 -------------------------------------------------------------------------
SELECT pg_temp.act('5ea00000-0000-0000-0000-0000000000a1');
SET LOCAL ROLE authenticated;
DO $$
DECLARE raised boolean;
BEGIN
  INSERT INTO public.exos_seat_maps (id, org_id, name, map)
  VALUES ('5ea00000-0000-0000-0000-00000000aa01', '5ea00000-0000-0000-0000-000000000001', 'Main room', (SELECT m FROM st_map));
  ASSERT (SELECT seat_count = 8 AND version = 1 AND created_by = '5ea00000-0000-0000-0000-0000000000a1'
            FROM public.exos_seat_maps WHERE id = '5ea00000-0000-0000-0000-00000000aa01'), 'S1: seat count / version / creator';
  UPDATE public.exos_seat_maps SET name = 'Main room v2' WHERE id = '5ea00000-0000-0000-0000-00000000aa01';
  ASSERT (SELECT version FROM public.exos_seat_maps WHERE id = '5ea00000-0000-0000-0000-00000000aa01') = 2, 'S1: version bumps';
  raised := false;
  BEGIN
    INSERT INTO public.exos_seat_maps (org_id, name, map)
    VALUES ('5ea00000-0000-0000-0000-000000000001', 'Bad', jsonb_set((SELECT m FROM st_map), '{sections,0,rows,0,seats,1,key}', '"1"'));
  EXCEPTION WHEN check_violation THEN raised := true;
  END;
  ASSERT raised, 'S1: duplicate seat key refused';
  raised := false;
  BEGIN
    INSERT INTO public.exos_seat_maps (org_id, name, map) VALUES ('5ea00000-0000-0000-0000-000000000001', 'Empty', '{"width":500,"height":500,"sections":[]}');
  EXCEPTION WHEN check_violation THEN raised := true;
  END;
  ASSERT raised, 'S1: empty map refused';
  raised := false;
  BEGIN
    INSERT INTO public.exos_seat_maps (org_id, name, map) VALUES ('5ea00000-0000-0000-0000-000000000002', 'Theirs', (SELECT m FROM st_map));
  EXCEPTION WHEN insufficient_privilege THEN raised := true;
  END;
  ASSERT raised, 'S1: can''t write another org''s maps';
END $$;
SELECT pg_temp.act('5ea00000-0000-0000-0000-0000000000a3');
DO $$
DECLARE n int;
BEGIN
  ASSERT (SELECT count(*) FROM public.exos_seat_maps) = 1, 'S1: scanner reads the org''s maps';
  UPDATE public.exos_seat_maps SET name = 'Scanner was here';
  GET DIAGNOSTICS n = ROW_COUNT;
  ASSERT n = 0, 'S1: scanner can''t edit maps';
END $$;
SELECT pg_temp.act('5ea00000-0000-0000-0000-0000000000b9');
DO $$
BEGIN
  ASSERT (SELECT count(*) FROM public.exos_seat_maps) = 0, 'S1: another org sees no maps';
  RAISE NOTICE 'OK  S1 seat maps';
END $$;
RESET ROLE;

-- S2 -------------------------------------------------------------------------
SELECT pg_temp.act('5ea00000-0000-0000-0000-0000000000a3');
SET LOCAL ROLE authenticated;
DO $$
DECLARE raised boolean := false;
BEGIN
  BEGIN
    PERFORM public.exos_set_event_seating('5ea00000-0000-0000-0000-0000000000e1', '5ea00000-0000-0000-0000-00000000aa01',
      '{"s1":"5ea00000-0000-0000-0000-0000000000d1"}');
  EXCEPTION WHEN insufficient_privilege THEN raised := true;
  END;
  ASSERT raised, 'S2: scanner can''t assign seating';
END $$;
SELECT pg_temp.act('5ea00000-0000-0000-0000-0000000000a1');
DO $$
DECLARE r jsonb; raised boolean := false;
BEGIN
  -- A tier with general-admission sales can't become seats.
  BEGIN
    PERFORM public.exos_set_event_seating('5ea00000-0000-0000-0000-0000000000e1', '5ea00000-0000-0000-0000-00000000aa01',
      '{"s1":"5ea00000-0000-0000-0000-0000000000d3"}');
  EXCEPTION WHEN check_violation THEN raised := true;
  END;
  ASSERT raised, 'S2: GA-sold tier refused';
  raised := false;
  BEGIN
    PERFORM public.exos_set_event_seating('5ea00000-0000-0000-0000-0000000000e1', '5ea00000-0000-0000-0000-00000000aa01',
      '{"s1":"5ea00000-0000-0000-0000-0000000000d1","g1":"5ea00000-0000-0000-0000-0000000000d1"}');
  EXCEPTION WHEN invalid_parameter_value THEN raised := true;
  END;
  ASSERT raised, 'S2: a tier as both seats and standing refused';
  raised := false;
  BEGIN
    PERFORM public.exos_set_event_seating('5ea00000-0000-0000-0000-0000000000e1', '5ea00000-0000-0000-0000-00000000aa01',
      '{"nope":"5ea00000-0000-0000-0000-0000000000d1"}');
  EXCEPTION WHEN invalid_parameter_value THEN raised := true;
  END;
  ASSERT raised, 'S2: unknown level key refused';

  -- Row B sells as Standing would mix; keep it simple: whole section Orchestra,
  -- seat s1-r2-4 not on sale (level for another event's tier is refused, so
  -- leave it as section-level and block it later instead).
  r := public.exos_set_event_seating('5ea00000-0000-0000-0000-0000000000e1', '5ea00000-0000-0000-0000-00000000aa01',
         '{"s1":"5ea00000-0000-0000-0000-0000000000d1","g1":"5ea00000-0000-0000-0000-0000000000d2"}');
  ASSERT (r->>'seat_count')::int = 8 AND (r->'tiers'->>'5ea00000-0000-0000-0000-0000000000d1')::int = 8, 'S2: result ' || r::text;
  -- The draft event gets the same map (for S3).
  PERFORM public.exos_set_event_seating('5ea00000-0000-0000-0000-0000000000e2', '5ea00000-0000-0000-0000-00000000aa01',
    '{"s1":"5ea00000-0000-0000-0000-0000000000d4"}');
END $$;
RESET ROLE;
-- (The harness DB has no client grants on tiers: the guard is a trigger, so
-- checking it as the table owner is the same check.)
DO $$
BEGIN
  ASSERT (SELECT seated AND capacity = 8 FROM public.exos_ticket_tiers WHERE id = '5ea00000-0000-0000-0000-0000000000d1'),
    'S2: Orchestra is seated, capacity 8';
  ASSERT (SELECT NOT seated AND capacity = 100 FROM public.exos_ticket_tiers WHERE id = '5ea00000-0000-0000-0000-0000000000d2'),
    'S2: Standing stays general admission';
  ASSERT (SELECT label FROM public.exos_event_seats WHERE event_id = '5ea00000-0000-0000-0000-0000000000e1' AND seat_id = 's1-r2-3')
         = 'Orchestra · Row B · Seat 3', 'S2: seat label';

  -- The editor's ordinary save can't flip `seated` or move a seated capacity.
  UPDATE public.exos_ticket_tiers SET capacity = 500, seated = false, price = 55 WHERE id = '5ea00000-0000-0000-0000-0000000000d1';
  ASSERT (SELECT seated AND capacity = 8 AND price = 55 FROM public.exos_ticket_tiers WHERE id = '5ea00000-0000-0000-0000-0000000000d1'),
    'S2: client edit keeps seated + capacity, other fields save';
  UPDATE public.exos_ticket_tiers SET seated = true WHERE id = '5ea00000-0000-0000-0000-0000000000d2';
  ASSERT NOT (SELECT seated FROM public.exos_ticket_tiers WHERE id = '5ea00000-0000-0000-0000-0000000000d2'), 'S2: client can''t set seated';
  UPDATE public.exos_ticket_tiers SET price = 50 WHERE id = '5ea00000-0000-0000-0000-0000000000d1';
  RAISE NOTICE 'OK  S2 assigning a map';
END $$;

-- S3 -------------------------------------------------------------------------
SELECT pg_temp.act(NULL);
SET LOCAL ROLE anon;
DO $$
DECLARE j jsonb; raised boolean := false;
BEGIN
  j := public.exos_public_event_seating('5ea00000-0000-0000-0000-0000000000e1');
  ASSERT j->'seated_tier_ids' = '["5ea00000-0000-0000-0000-0000000000d1"]'::jsonb, 'S3: seated tiers ' || coalesce(j::text, 'null');
  ASSERT jsonb_array_length(j->'map'->'sections') = 2 AND NOT (j->'map'->'sections'->0 ? 'rows'), 'S3: layout without rows';
  ASSERT (SELECT count(*) FROM public.exos_public_event_seats('5ea00000-0000-0000-0000-0000000000e1') WHERE available) = 8,
    'S3: 8 seats available';
  ASSERT public.exos_public_event_seating('5ea00000-0000-0000-0000-0000000000e2') IS NULL, 'S3: draft layout hidden';
  ASSERT (SELECT count(*) FROM public.exos_public_event_seats('5ea00000-0000-0000-0000-0000000000e2')) = 0, 'S3: draft seats hidden';
  BEGIN
    PERFORM 1 FROM public.exos_event_seat_claims;
  EXCEPTION WHEN insufficient_privilege THEN raised := true;
  END;
  ASSERT raised, 'S3: anon can''t read claims';
  raised := false;
  BEGIN
    PERFORM public.exos_event_seat_status('5ea00000-0000-0000-0000-0000000000e1');
  EXCEPTION WHEN insufficient_privilege THEN raised := true;
  END;
  ASSERT raised, 'S3: anon can''t read full seat status';
END $$;
RESET ROLE;
DO $$
BEGIN
  -- Only status leaves the public function: no ticket / hold / holder columns.
  ASSERT NOT EXISTS (
    SELECT 1 FROM unnest((SELECT proargnames FROM pg_proc WHERE proname = 'exos_public_event_seats')) a
     WHERE a ~ '(ticket|hold|buyer|owner|email|claim|status)'), 'S3: public seats leak holder fields';
  ASSERT NOT has_table_privilege('anon', 'public.exos_event_seats', 'SELECT')
     AND NOT has_table_privilege('anon', 'public.exos_seat_maps', 'SELECT'), 'S3: anon table grants';
  RAISE NOTICE 'OK  S3 anon sees layout + status only';
END $$;

-- S4 -------------------------------------------------------------------------
CREATE TEMP TABLE st_h (who text PRIMARY KEY, hold uuid);
DO $$
DECLARE h uuid; raised boolean := false; msg text; j jsonb;
BEGIN
  PERFORM pg_temp.act('5ea00000-0000-0000-0000-0000000000b1');
  h := public.exos_create_hold('5ea00000-0000-0000-0000-0000000000e1', '5ea00000-0000-0000-0000-0000000000d1', 2);
  INSERT INTO st_h VALUES ('a', h);
  j := public.exos_hold_seats(h, ARRAY['s1-r1-1', 's1-r1-2']);
  ASSERT jsonb_array_length(j->'seats') = 2 AND j->'seats'->0->>'label' = 'Orchestra · Row A · Seat 1', 'S4: A holds A1, A2';

  PERFORM pg_temp.act('5ea00000-0000-0000-0000-0000000000b2');
  h := public.exos_create_hold('5ea00000-0000-0000-0000-0000000000e1', '5ea00000-0000-0000-0000-0000000000d1', 1);
  INSERT INTO st_h VALUES ('b', h);
  BEGIN
    PERFORM public.exos_hold_seats(h, ARRAY['s1-r1-2']);
  EXCEPTION WHEN SQLSTATE 'XS409' THEN raised := true; msg := SQLERRM;
  END;
  ASSERT raised AND msg LIKE '%Row A · Seat 2 was just taken%', 'S4: B loses A2: ' || coalesce(msg, '-');
  -- Wrong count / wrong tier / unknown seat are refused too.
  raised := false;
  BEGIN PERFORM public.exos_hold_seats(h, ARRAY['s1-r1-3', 's1-r1-4']);
  EXCEPTION WHEN invalid_parameter_value THEN raised := true; END;
  ASSERT raised, 'S4: seat count must match the hold';
  raised := false;
  BEGIN PERFORM public.exos_hold_seats(h, ARRAY['nope']);
  EXCEPTION WHEN invalid_parameter_value THEN raised := true; END;
  ASSERT raised, 'S4: unknown seat refused';
  PERFORM public.exos_hold_seats(h, ARRAY['s1-r1-3']);
  ASSERT (SELECT count(*) FROM public.exos_public_event_seats('5ea00000-0000-0000-0000-0000000000e1') WHERE NOT available) = 3,
    'S4: A1-A3 unavailable';
  RAISE NOTICE 'OK  S4 race for one seat';
END $$;
-- The same race on the unique index directly (as if two transactions both
-- passed the checks): a second live claim can't exist.
DO $$
DECLARE raised boolean := false;
BEGIN
  BEGIN
    INSERT INTO public.exos_event_seat_claims (event_id, seat_id, org_id, status)
    VALUES ('5ea00000-0000-0000-0000-0000000000e1', 's1-r1-1', '5ea00000-0000-0000-0000-000000000001', 'held');
  EXCEPTION WHEN unique_violation THEN raised := true;
  END;
  ASSERT raised, 'S4: one live claim per seat';
END $$;

-- S5 -------------------------------------------------------------------------
DO $$
DECLARE h uuid; raised boolean := false;
BEGIN
  -- B's hold runs out (still 'active' until the cron): C can take A3.
  UPDATE public.exos_cart_holds SET expires_at = now() - interval '1 second' WHERE id = (SELECT hold FROM st_h WHERE who = 'b');
  ASSERT (SELECT available FROM public.exos_public_event_seats('5ea00000-0000-0000-0000-0000000000e1') WHERE seat_id = 's1-r1-3'),
    'S5: an expired hold''s seat shows available';
  PERFORM pg_temp.act('5ea00000-0000-0000-0000-0000000000b3');
  h := public.exos_create_hold('5ea00000-0000-0000-0000-0000000000e1', '5ea00000-0000-0000-0000-0000000000d1', 1);
  INSERT INTO st_h VALUES ('c', h);
  PERFORM public.exos_hold_seats(h, ARRAY['s1-r1-3']);
  ASSERT (SELECT status FROM public.exos_event_seat_claims WHERE hold_id = (SELECT hold FROM st_h WHERE who = 'b')) = 'lapsed',
    'S5: B''s claim lapsed';
  -- The cron path: C's hold expires via exos_expire_holds → claim lapses.
  UPDATE public.exos_cart_holds SET expires_at = now() - interval '1 second' WHERE id = h;
  PERFORM public.exos_expire_holds();
  ASSERT (SELECT status FROM public.exos_event_seat_claims WHERE hold_id = h) = 'lapsed', 'S5: cron expiry lapses the claim';
  -- A hold that's gone can't take seats.
  BEGIN PERFORM public.exos_hold_seats(h, ARRAY['s1-r1-4']);
  EXCEPTION WHEN check_violation THEN raised := true; END;
  ASSERT raised, 'S5: expired hold refused';
  RAISE NOTICE 'OK  S5 hold expiry frees the seat';
END $$;

-- S6 -------------------------------------------------------------------------
DO $$
DECLARE ids uuid[]; r text; j jsonb;
BEGIN
  INSERT INTO public.exos_checkout_sessions (session_id, event_id, tier_id, org_id, buyer_uid, buyer_email, quantity, amount_cents, currency, status)
  VALUES ('st-sess-a', '5ea00000-0000-0000-0000-0000000000e1', '5ea00000-0000-0000-0000-0000000000d1', '5ea00000-0000-0000-0000-000000000001',
          '5ea00000-0000-0000-0000-0000000000b1', 'st-buyer-a@x.com', 2, 10000, 'usd', 'pending');
  UPDATE public.exos_cart_holds SET checkout_session_id = 'st-sess-a' WHERE id = (SELECT hold FROM st_h WHERE who = 'a');
  ids := public.exos_fulfill_checkout('st-sess-a');
  ASSERT cardinality(ids) = 2, 'S6: two tickets';
  ASSERT (SELECT array_agg(seat_label ORDER BY seat_label) FROM public.exos_tickets WHERE id = ANY (ids))
         = ARRAY['Orchestra · Row A · Seat 1', 'Orchestra · Row A · Seat 2'], 'S6: tickets carry A1, A2';
  ASSERT (SELECT bool_and(seat_section = 'Orchestra' AND seat_row = 'A') FROM public.exos_tickets WHERE id = ANY (ids)), 'S6: seat parts';
  ASSERT (SELECT count(*) FROM public.exos_event_seat_claims WHERE ticket_id = ANY (ids) AND status = 'sold') = 2, 'S6: claims sold';
  ASSERT (SELECT sold FROM public.exos_ticket_tiers WHERE id = '5ea00000-0000-0000-0000-0000000000d1') = 2, 'S6: tier sold 2';
  r := public.exos_receipt_html('st-sess-a');
  ASSERT r LIKE '%Seats: Orchestra · Row A · Seat 1; Orchestra · Row A · Seat 2%', 'S6: receipt seats: ' || r;
  -- Fulfilling again is a no-op.
  ASSERT public.exos_fulfill_checkout('st-sess-a') = ids, 'S6: replay returns the same tickets';
  -- Wallet payload carries the seat.
  INSERT INTO public.exos_wallet_passes (ticket_id, owner_id, serial_number, pass_type_identifier)
  SELECT ids[1], '5ea00000-0000-0000-0000-0000000000b1', 'exw5ea00000000000000000000000000001', 'pass.test';
  j := public._exos_wallet_payload('exw5ea00000000000000000000000000001');
  ASSERT j->'ticket'->'seat'->>'row' = 'A' AND j->'ticket'->'seat'->>'label' LIKE 'Orchestra · Row A%', 'S6: wallet seat ' || j::text;
  RAISE NOTICE 'OK  S6 fulfillment assigns seats';
END $$;
-- The door: scanner reads seat labels for the event.
SELECT pg_temp.act('5ea00000-0000-0000-0000-0000000000a3');
SET LOCAL ROLE authenticated;
DO $$
BEGIN
  ASSERT (SELECT count(*) FROM public.exos_event_seat_roster('5ea00000-0000-0000-0000-0000000000e1')) = 2, 'S6: door roster';
END $$;
RESET ROLE;

-- S7 -------------------------------------------------------------------------
DO $$
DECLARE ids uuid[]; h uuid;
BEGIN
  -- B's hold lapsed in S5 and C took A3 (then C's hold expired too). D (= B
  -- again, a fresh hold) holds A3 now; B's old session then completes.
  PERFORM pg_temp.act('5ea00000-0000-0000-0000-0000000000b3');
  h := public.exos_create_hold('5ea00000-0000-0000-0000-0000000000e1', '5ea00000-0000-0000-0000-0000000000d1', 1);
  PERFORM public.exos_hold_seats(h, ARRAY['s1-r1-3']);
  INSERT INTO public.exos_checkout_sessions (session_id, event_id, tier_id, org_id, buyer_uid, buyer_email, quantity, amount_cents, currency, status)
  VALUES ('st-sess-b', '5ea00000-0000-0000-0000-0000000000e1', '5ea00000-0000-0000-0000-0000000000d1', '5ea00000-0000-0000-0000-000000000001',
          '5ea00000-0000-0000-0000-0000000000b2', 'st-buyer-b@x.com', 1, 5000, 'usd', 'pending');
  UPDATE public.exos_cart_holds SET checkout_session_id = 'st-sess-b' WHERE id = (SELECT hold FROM st_h WHERE who = 'b');
  ids := public.exos_fulfill_checkout('st-sess-b');
  ASSERT cardinality(ids) = 0, 'S7: no tickets';
  ASSERT (SELECT status = 'failed' AND failure_reason LIKE '%taken while you were paying%'
            FROM public.exos_checkout_sessions WHERE session_id = 'st-sess-b'), 'S7: order failed (refund path)';
  ASSERT (SELECT sold FROM public.exos_ticket_tiers WHERE id = '5ea00000-0000-0000-0000-0000000000d1') = 2, 'S7: nothing sold';
  ASSERT (SELECT hold_id FROM public.exos_event_seat_claims WHERE seat_id = 's1-r1-3' AND status = 'held') = h, 'S7: the new holder keeps A3';
  UPDATE public.exos_cart_holds SET status = 'released' WHERE id = h;
  ASSERT (SELECT available FROM public.exos_public_event_seats('5ea00000-0000-0000-0000-0000000000e1') WHERE seat_id = 's1-r1-3'),
    'S7: a released hold frees its seat';
  RAISE NOTICE 'OK  S7 seat lost while paying';
END $$;

-- S8 -------------------------------------------------------------------------
DO $$
DECLARE t uuid;
BEGIN
  SELECT id INTO t FROM public.exos_tickets WHERE seat_id = 's1-r1-2' AND status = 'active';
  UPDATE public.exos_tickets SET status = 'voided', voided_at = now(), voided_reason = 'refund' WHERE id = t;
  ASSERT (SELECT status FROM public.exos_event_seat_claims WHERE ticket_id = t) = 'released', 'S8: claim released';
  ASSERT (SELECT available FROM public.exos_public_event_seats('5ea00000-0000-0000-0000-0000000000e1') WHERE seat_id = 's1-r1-2'),
    'S8: seat available again';
  ASSERT (SELECT seat_label FROM public.exos_tickets WHERE id = t) = 'Orchestra · Row A · Seat 2', 'S8: the voided ticket keeps its seat label';
  -- Clients can't rewrite a ticket's seat.
  UPDATE public.exos_tickets SET seat_label = 'Box 1' WHERE id = t;
  ASSERT (SELECT seat_label FROM public.exos_tickets WHERE id = t) = 'Orchestra · Row A · Seat 2', 'S8: seat columns server-written';
  RAISE NOTICE 'OK  S8 refund frees the seat';
END $$;

-- S9 -------------------------------------------------------------------------
DO $$
DECLARE ids uuid[]; h uuid; raised boolean := false;
BEGIN
  PERFORM pg_temp.act('5ea00000-0000-0000-0000-0000000000b2');
  h := public.exos_create_hold('5ea00000-0000-0000-0000-0000000000e1', '5ea00000-0000-0000-0000-0000000000d2', 2);
  -- Seats can't be held on a GA tier.
  BEGIN PERFORM public.exos_hold_seats(h, ARRAY['s1-r2-1', 's1-r2-2']);
  EXCEPTION WHEN invalid_parameter_value THEN raised := true; END;
  ASSERT raised, 'S9: no seats on a GA tier';
  INSERT INTO public.exos_checkout_sessions (session_id, event_id, tier_id, org_id, buyer_uid, buyer_email, quantity, amount_cents, currency, status)
  VALUES ('st-sess-ga', '5ea00000-0000-0000-0000-0000000000e1', '5ea00000-0000-0000-0000-0000000000d2', '5ea00000-0000-0000-0000-000000000001',
          '5ea00000-0000-0000-0000-0000000000b2', 'st-buyer-b@x.com', 2, 4000, 'usd', 'pending');
  UPDATE public.exos_cart_holds SET checkout_session_id = 'st-sess-ga' WHERE id = h;
  ids := public.exos_fulfill_checkout('st-sess-ga');
  ASSERT cardinality(ids) = 2 AND (SELECT bool_and(seat_id IS NULL) FROM public.exos_tickets WHERE id = ANY (ids)), 'S9: GA tickets, no seat';
  ASSERT public.exos_receipt_html('st-sess-ga') NOT LIKE '%Seat%', 'S9: GA receipt unchanged';
  -- A plain GA comp still works.
  INSERT INTO public.exos_tickets (event_id, org_id, tier_id, buyer_id, owner_id, status, barcode_secret)
  VALUES ('5ea00000-0000-0000-0000-0000000000e1', '5ea00000-0000-0000-0000-000000000001', '5ea00000-0000-0000-0000-0000000000d2',
          '5ea00000-0000-0000-0000-0000000000b2', '5ea00000-0000-0000-0000-0000000000b2', 'active', gen_random_uuid()::text);
  RAISE NOTICE 'OK  S9 GA unaffected';
END $$;

-- S10 ------------------------------------------------------------------------
DO $$
DECLARE raised boolean := false;
BEGIN
  -- Box office / POS / partner / marketplace / comps all mint into
  -- exos_tickets outside a seat-picker checkout: refused for a seated tier.
  BEGIN
    INSERT INTO public.exos_tickets (event_id, org_id, tier_id, buyer_id, owner_id, status, barcode_secret, order_ref, channel_source)
    VALUES ('5ea00000-0000-0000-0000-0000000000e1', '5ea00000-0000-0000-0000-000000000001', '5ea00000-0000-0000-0000-0000000000d1',
            '5ea00000-0000-0000-0000-0000000000b2', '5ea00000-0000-0000-0000-0000000000b2', 'active', gen_random_uuid()::text,
            'pos-order-1', 'pos');
  EXCEPTION WHEN check_violation THEN raised := true;
  END;
  ASSERT raised, 'S10: box office mint of a seated tier refused';
  raised := false;
  BEGIN
    PERFORM pg_temp.act('5ea00000-0000-0000-0000-0000000000a0');
    PERFORM public.exos_issue_comp_batch('5ea00000-0000-0000-0000-0000000000e1', '5ea00000-0000-0000-0000-0000000000d1',
                                         ARRAY['st-comp@x.com'], 1, NULL);
  EXCEPTION WHEN check_violation THEN raised := true; RAISE NOTICE 'comp batch: %', SQLERRM;
  END;
  ASSERT raised, 'S10: comp batch on a seated tier refused';
  RAISE NOTICE 'OK  S10 non-picker paths refuse seated tiers';
END $$;

-- S11 ------------------------------------------------------------------------
SELECT pg_temp.act('5ea00000-0000-0000-0000-0000000000b9');
SET LOCAL ROLE authenticated;
DO $$
DECLARE raised boolean := false;
BEGIN
  ASSERT (SELECT count(*) FROM public.exos_event_seats) = 0 AND (SELECT count(*) FROM public.exos_event_seating) = 0
     AND (SELECT count(*) FROM public.exos_event_seat_claims) = 0, 'S11: another org reads none of our seating';
  BEGIN
    PERFORM public.exos_set_seats_blocked('5ea00000-0000-0000-0000-0000000000e1', ARRAY['s1-r2-4'], true);
  EXCEPTION WHEN insufficient_privilege THEN raised := true;
  END;
  ASSERT raised, 'S11: can''t block our seats';
  raised := false;
  BEGIN
    PERFORM public.exos_event_seat_status('5ea00000-0000-0000-0000-0000000000e1');
  EXCEPTION WHEN insufficient_privilege THEN raised := true;
  END;
  ASSERT raised, 'S11: can''t read our seat status';
  raised := false;
  BEGIN
    PERFORM public.exos_seat_reconciliation('5ea00000-0000-0000-0000-0000000000e1');
  EXCEPTION WHEN insufficient_privilege THEN raised := true;
  END;
  ASSERT raised, 'S11: can''t reconcile our seats';
  RAISE NOTICE 'OK  S11 cross-org isolation';
END $$;
RESET ROLE;

-- S12 ------------------------------------------------------------------------
CREATE TEMP TABLE st_cap (step text, cap int);
CREATE FUNCTION pg_temp.cap(p_step text) RETURNS void LANGUAGE sql SECURITY DEFINER AS $$
  INSERT INTO st_cap SELECT p_step, capacity FROM public.exos_ticket_tiers WHERE id = '5ea00000-0000-0000-0000-0000000000d1';
$$;
GRANT EXECUTE ON FUNCTION pg_temp.cap(text) TO authenticated;
GRANT ALL ON st_cap TO authenticated;
SELECT pg_temp.act('5ea00000-0000-0000-0000-0000000000a1');
SET LOCAL ROLE authenticated;
DO $$
DECLARE done text[]; raised boolean := false;
BEGIN
  done := public.exos_set_seats_blocked('5ea00000-0000-0000-0000-0000000000e1', ARRAY['s1-r2-4', 's1-r1-1'], true, 'camera');
  ASSERT done = ARRAY['s1-r2-4'], 'S12: only the free seat is blocked: ' || done::text;
  PERFORM pg_temp.cap('blocked');
  ASSERT (SELECT status FROM public.exos_event_seat_status('5ea00000-0000-0000-0000-0000000000e1') WHERE seat_id = 's1-r2-4') = 'blocked',
    'S12: staff see blocked';
  ASSERT (SELECT status FROM public.exos_event_seat_status('5ea00000-0000-0000-0000-0000000000e1') WHERE seat_id = 's1-r1-1') = 'sold',
    'S12: staff see sold';
  done := public.exos_set_seats_blocked('5ea00000-0000-0000-0000-0000000000e1', ARRAY['s1-r2-4'], false);
  ASSERT done = ARRAY['s1-r2-4'], 'S12: unblocked';
  PERFORM pg_temp.cap('unblocked');
  BEGIN
    PERFORM public.exos_set_event_seating('5ea00000-0000-0000-0000-0000000000e1', NULL);
  EXCEPTION WHEN check_violation THEN raised := true;
  END;
  ASSERT raised, 'S12: seating locked once seats are sold';
END $$;
RESET ROLE;
DO $$
BEGIN
  ASSERT (SELECT cap FROM st_cap WHERE step = 'blocked') = 7, 'S12: capacity 8 - 1 blocked';
  ASSERT (SELECT cap FROM st_cap WHERE step = 'unblocked') = 8, 'S12: unblock restores capacity';
  RAISE NOTICE 'OK  S12 block / unblock';
END $$;

-- S13 ------------------------------------------------------------------------
DO $$
DECLARE raised boolean := false; n int;
BEGIN
  -- An orphan: a sold claim whose ticket doesn't exist (e.g. deleted by hand
  -- with triggers off).
  INSERT INTO public.exos_event_seat_claims (event_id, seat_id, org_id, status, ticket_id)
  VALUES ('5ea00000-0000-0000-0000-0000000000e1', 's1-r2-1', '5ea00000-0000-0000-0000-000000000001', 'sold', gen_random_uuid());
  ASSERT (SELECT count(*) FROM public.exos_seat_reconciliation('5ea00000-0000-0000-0000-0000000000e1')) = 1
     AND (SELECT kind FROM public.exos_seat_reconciliation('5ea00000-0000-0000-0000-0000000000e1')) = 'claim_without_ticket',
    'S13: one orphan';
  BEGIN
    PERFORM public.exos_release_orphan_seats('5ea00000-0000-0000-0000-0000000000e1', ARRAY['s1-r2-1', 's1-r1-1']);
  EXCEPTION WHEN check_violation THEN raised := true;
  END;
  ASSERT raised, 'S13: a live seat in the request refuses the whole call';
  n := public.exos_release_orphan_seats('5ea00000-0000-0000-0000-0000000000e1', ARRAY['s1-r2-1']);
  ASSERT n = 1 AND (SELECT count(*) FROM public.exos_seat_reconciliation('5ea00000-0000-0000-0000-0000000000e1')) = 0,
    'S13: orphan released';
  RAISE NOTICE 'OK  S13 reconciliation';
END $$;

SELECT '*** SEATING PASSED ***';
ROLLBACK;
