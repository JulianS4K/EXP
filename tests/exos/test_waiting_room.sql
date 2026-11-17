-- ============================================================================
-- On-sale waiting room (mig 20261118120000). Self-contained (d71… ids),
-- rolled back. now() is fixed inside the transaction, so time moves by
-- back-dating rows (arrived_at, advanced_at, admit_clock, admit_expires_at).
--   WR0 shape: RLS on, no client grants; definer + search_path; anon may call
--       exactly join / status; summary / configure signed in; require service
--       only; the gate is the first statement of the three hold / claim bodies
--   WR1 roles: configure owner / manager (+ an event.waiting_room audit row
--       with the before / after numbers); finance, content, scanner, an
--       outsider and the other org's owner 42501; summary owner / manager /
--       finance, never a token; bad numbers 22023
--   WR2 off by default: no room, no token, holds as before; "before" the
--       window: no token, the opening time
--   WR3 lobby + fair draw: early arrivals get no position before the on-sale;
--       holds refused (XWR01); at the on-sale every early arrival gets a
--       distinct random place (not arrival order), late arrivals after all of
--       them in arrival order; one token per browser
--   WR4 batches: the first round lets in six seconds' worth, the front of the
--       line; a round at most every 5 s; credit capped at one minute; a tab
--       not seen for 3 minutes is skipped but keeps its place; positions
--       count only the people ahead
--   WR5 gate: an admitted token of THIS event passes (create_hold, guest
--       hold, free claim, exos_wroom_require) and is marked used; no token, a
--       waiting token, a malformed one and another event's admitted token are
--       XWR01; the drop list presale type bypasses
--   WR6 expiry: after N minutes the admission is gone (status, gate, counts)
--   WR7 rate limit: 60 new tokens a minute per network, then "busy" with
--       nothing stored; a known token still polls
--   WR8 closing: idle (nobody waiting for X minutes) and by the organizer;
--       then no token is needed; on again = a new run, old tokens dead
--   WR9 no PII: no email / user / IP columns; nothing about other people
-- Users: o owner A, m manager A, f finance A, c content A, s scanner A,
--        b owner B, f1 / f2 fans, x outsider.
-- ============================================================================
\set ON_ERROR_STOP on
BEGIN;

CREATE FUNCTION pg_temp.u(p text) RETURNS uuid LANGUAGE sql IMMUTABLE AS $$
  SELECT ('d7100000-0000-0000-0000-' || lpad(p, 12, '0'))::uuid
$$;
-- Act as a role / user from a network, optionally carrying a queue token
-- in the x-exos-queue header (what PostgREST puts in request.headers).
CREATE FUNCTION pg_temp.as_(p_role text, p_uid uuid DEFAULT NULL, p_ip text DEFAULT '198.51.100.1', p_q text DEFAULT NULL)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  PERFORM set_config('role', 'postgres', true);
  PERFORM set_config('app.uid', coalesce(p_uid::text, ''), true);
  PERFORM set_config('app.jwt', CASE WHEN p_uid IS NOT NULL
                                     THEN jsonb_build_object('email', (SELECT email FROM auth.users WHERE id = p_uid))::text
                                     ELSE '' END, true);
  PERFORM set_config('request.jwt.claims', CASE WHEN p_role IN ('anon', 'authenticated')
                                                THEN jsonb_build_object('role', p_role)::text ELSE '' END, true);
  PERFORM set_config('request.headers', (jsonb_build_object('cf-connecting-ip', p_ip)
                                         || CASE WHEN p_q IS NOT NULL THEN jsonb_build_object('x-exos-queue', p_q)
                                                 ELSE '{}'::jsonb END)::text, true);
  PERFORM set_config('role', p_role, true);
END $$;
CREATE FUNCTION pg_temp.st(p_sql text) RETURNS text LANGUAGE plpgsql AS $$
BEGIN
  EXECUTE p_sql;
  RETURN 'ok';
EXCEPTION WHEN OTHERS THEN RETURN SQLSTATE || ' ' || SQLERRM;
END $$;
-- Let the next admission round run (as if 5+ seconds passed) with p_secs of credit.
CREATE FUNCTION pg_temp.tick(p_event uuid, p_secs int) RETURNS void LANGUAGE sql AS $$
  UPDATE public.exos_wroom_settings
     SET advanced_at = now() - interval '6 seconds', admit_clock = now() - make_interval(secs => p_secs)
   WHERE event_id = p_event
$$;
GRANT EXECUTE ON FUNCTION pg_temp.u(text), pg_temp.as_(text, uuid, text, text), pg_temp.st(text) TO anon, authenticated, service_role;

CREATE TEMP TABLE wr_tok (n int, event_id uuid, token text, early boolean) ON COMMIT DROP;
GRANT ALL ON wr_tok TO anon, authenticated, service_role;

INSERT INTO auth.users (id, email, email_confirmed_at) VALUES
  (pg_temp.u('a1'), 'd71-o@x.com', now()), (pg_temp.u('a2'), 'd71-m@x.com', now()),
  (pg_temp.u('a3'), 'd71-f@x.com', now()), (pg_temp.u('a4'), 'd71-c@x.com', now()),
  (pg_temp.u('a5'), 'd71-s@x.com', now()), (pg_temp.u('a6'), 'd71-b@x.com', now()),
  (pg_temp.u('b1'), 'd71-fan1@x.com', now()), (pg_temp.u('b2'), 'd71-fan2@x.com', now()),
  (pg_temp.u('b4'), 'd71-x@x.com', now());
INSERT INTO public.exos_orgs (id, name, slug, owner_uid) VALUES
  (pg_temp.u('1'), 'D71 Hall', 'd71-hall', pg_temp.u('a1')),
  (pg_temp.u('2'), 'D71 Elsewhere', 'd71-elsewhere', pg_temp.u('a6'));
INSERT INTO public.exos_org_memberships (org_id, user_id, role) VALUES
  (pg_temp.u('1'), pg_temp.u('a1'), 'owner'), (pg_temp.u('1'), pg_temp.u('a2'), 'manager'),
  (pg_temp.u('1'), pg_temp.u('a3'), 'finance'), (pg_temp.u('1'), pg_temp.u('a4'), 'content'),
  (pg_temp.u('1'), pg_temp.u('a5'), 'scanner'), (pg_temp.u('2'), pg_temp.u('a6'), 'owner');
-- e1: the big drop (GA opens in 2 hours, a hidden list presale type, a free type).
-- e2: on sale now, a second room (cross-event tokens). e3: no room. e9: org B's.
INSERT INTO public.exos_events (id, org_id, name, slug, status, starts_at, timezone, total_tickets, created_by, link_out) VALUES
  (pg_temp.u('e1'), pg_temp.u('1'), 'D71 Drop', 'd71-drop', 'published', now() + interval '30 days', 'America/New_York', 5000, pg_temp.u('a1'), false),
  (pg_temp.u('e2'), pg_temp.u('1'), 'D71 Second', 'd71-second', 'published', now() + interval '30 days', 'America/New_York', 500, pg_temp.u('a1'), false),
  (pg_temp.u('e3'), pg_temp.u('1'), 'D71 Quiet', 'd71-quiet', 'published', now() + interval '30 days', 'America/New_York', 500, pg_temp.u('a1'), false),
  (pg_temp.u('e9'), pg_temp.u('2'), 'D71 Other Org', 'd71-other', 'published', now() + interval '30 days', 'America/New_York', 500, pg_temp.u('a6'), false);
INSERT INTO public.exos_ticket_tiers (id, event_id, name, price, capacity, sales_start, visibility) VALUES
  (pg_temp.u('c1'), pg_temp.u('e1'), 'GA', 20, 4000, now() + interval '2 hours', 'public'),
  (pg_temp.u('c2'), pg_temp.u('e1'), 'List presale', 20, 50, NULL, 'hidden'),
  (pg_temp.u('c3'), pg_temp.u('e1'), 'Free', 0, 500, now() + interval '2 hours', 'public'),
  (pg_temp.u('c4'), pg_temp.u('e2'), 'GA', 20, 100, NULL, 'public'),
  (pg_temp.u('c5'), pg_temp.u('e3'), 'GA', 20, 100, NULL, 'public'),
  (pg_temp.u('c9'), pg_temp.u('e9'), 'GA', 20, 100, NULL, 'public');
INSERT INTO public.exos_drop_settings (event_id, org_id, presale_minutes, presale_tier_id, public_on_sale_at)
VALUES (pg_temp.u('e1'), pg_temp.u('1'), 60, pg_temp.u('c2'), now() + interval '2 hours');

-- WR0 -----------------------------------------------------------------------
DO $$
DECLARE r record; v_anon text[]; v_auth text[]; v_def text; f text;
BEGIN
  FOR r IN SELECT c.relname, c.relrowsecurity FROM pg_class c
            WHERE c.relname IN ('exos_wroom_settings', 'exos_wroom_entries') AND c.relkind = 'r' LOOP
    ASSERT r.relrowsecurity, 'WR0 RLS on ' || r.relname;
    ASSERT NOT has_table_privilege('anon', 'public.' || r.relname, 'SELECT,INSERT,UPDATE,DELETE')
       AND NOT has_table_privilege('authenticated', 'public.' || r.relname, 'SELECT,INSERT,UPDATE,DELETE'),
      'WR0 no client grants ' || r.relname;
  END LOOP;
  FOR r IN SELECT p.oid, p.proname, p.prosecdef, p.proconfig FROM pg_proc p
            WHERE p.pronamespace = 'public'::regnamespace AND p.proname ~ '^_?exos_wroom_' LOOP
    ASSERT array_to_string(r.proconfig, ',') LIKE '%search_path=public, pg_temp%', 'WR0 search_path ' || r.proname;
    IF has_function_privilege('anon', r.oid, 'EXECUTE') THEN v_anon := v_anon || r.proname::text; END IF;
    IF has_function_privilege('authenticated', r.oid, 'EXECUTE') THEN v_auth := v_auth || r.proname::text; END IF;
  END LOOP;
  ASSERT (SELECT array_agg(x ORDER BY x) FROM unnest(v_anon) x) = ARRAY['exos_wroom_join', 'exos_wroom_status'],
    'WR0 anon surface: ' || array_to_string(v_anon, ',');
  ASSERT (SELECT array_agg(x ORDER BY x) FROM unnest(v_auth) x)
       = ARRAY['exos_wroom_configure', 'exos_wroom_join', 'exos_wroom_status', 'exos_wroom_summary'],
    'WR0 authenticated surface: ' || array_to_string(v_auth, ',');
  ASSERT has_function_privilege('service_role', 'public.exos_wroom_require(uuid,uuid,text)', 'EXECUTE')
     AND NOT has_function_privilege('authenticated', 'public.exos_wroom_require(uuid,uuid,text)', 'EXECUTE'), 'WR0 require: service only';
  FOREACH f IN ARRAY ARRAY['public.exos_create_hold(uuid,uuid,integer,integer,text)',
                           'public.exos_create_guest_hold(uuid,uuid,integer,text,text,text)',
                           'public.exos_claim_free_tickets(uuid,uuid,integer,text,text,text)'] LOOP
    v_def := pg_get_functiondef(f::regprocedure);
    ASSERT position(E'\nBEGIN\n  PERFORM public._exos_wroom_gate(p_event_id, p_tier_id);  /* exos: waiting room gate */\n' in v_def) > 0
       AND position('/* exos: waiting room gate */' in v_def) < position('RAISE EXCEPTION' in v_def)
       AND (length(v_def) - length(replace(v_def, '/* exos: waiting room gate */', ''))) = length('/* exos: waiting room gate */'),
      'WR0 gate first, once: ' || f;
  END LOOP;
  RAISE NOTICE 'OK  WR0 RLS + no client grants, search_path, anon / signed-in / service surfaces, the gate first in 3 bodies';
END $$;

-- WR1 -----------------------------------------------------------------------
DO $$
DECLARE j jsonb; u text;
BEGIN
  FOREACH u IN ARRAY ARRAY['a3', 'a4', 'a5', 'b4', 'a6'] LOOP
    PERFORM pg_temp.as_('authenticated', pg_temp.u(u));
    ASSERT pg_temp.st(format('SELECT public.exos_wroom_configure(%L, true)', pg_temp.u('e1'))) LIKE '42501%', 'WR1 configure refused ' || u;
  END LOOP;
  FOREACH u IN ARRAY ARRAY['a4', 'a5', 'b4', 'a6'] LOOP
    PERFORM pg_temp.as_('authenticated', pg_temp.u(u));
    ASSERT pg_temp.st(format('SELECT public.exos_wroom_summary(%L)', pg_temp.u('e1'))) LIKE '42501%', 'WR1 summary refused ' || u;
  END LOOP;
  PERFORM pg_temp.as_('authenticated', pg_temp.u('a1'));
  ASSERT pg_temp.st(format('SELECT public.exos_wroom_summary(%L)', gen_random_uuid())) LIKE '42501%', 'WR1 unknown event 42501';
  ASSERT pg_temp.st(format('SELECT public.exos_wroom_configure(%L, true, 15, 0)', pg_temp.u('e1'))) LIKE '22023%', 'WR1 rate 0';
  ASSERT pg_temp.st(format('SELECT public.exos_wroom_configure(%L, true, 15, 60, 1)', pg_temp.u('e1'))) LIKE '22023%', 'WR1 admission 1';
  ASSERT pg_temp.st(format('SELECT public.exos_wroom_configure(%L, NULL)', pg_temp.u('e1'))) LIKE '22023%', 'WR1 on / off required';
  -- Off by default: the summary of an event without a room.
  j := public.exos_wroom_summary(pg_temp.u('e1'));
  ASSERT j->>'enabled' = 'false' AND j->>'phase' = 'off' AND (j->'counts'->>'total')::int = 0 AND (j->>'can_manage')::boolean,
    'WR1 off by default: ' || j::text;
  PERFORM pg_temp.as_('authenticated', pg_temp.u('a2'));
  j := public.exos_wroom_configure(pg_temp.u('e1'), true, 15, 60, 10, 10);
  ASSERT j->>'enabled' = 'true' AND j->>'phase' = 'before' AND (j->>'admit_per_minute')::int = 60, 'WR1 manager turns it on: ' || j::text;
  PERFORM pg_temp.as_('authenticated', pg_temp.u('a3'));
  j := public.exos_wroom_summary(pg_temp.u('e1'));
  ASSERT j->>'phase' = 'before' AND NOT (j->>'can_manage')::boolean AND j::text !~ '[0-9a-f]{64}', 'WR1 finance reads: ' || j::text;
  PERFORM pg_temp.as_('postgres');
  ASSERT EXISTS (SELECT 1 FROM public.exos_org_audit a WHERE a.org_id = pg_temp.u('1') AND a.action = 'event.waiting_room'
                   AND a.event_id = pg_temp.u('e1') AND a.actor_uid = pg_temp.u('a2')
                   AND a.changes->'enabled' = '[false, true]'::jsonb AND a.changes->'admit_per_minute' = '[null, 60]'::jsonb),
    'WR1 audited: ' || (SELECT string_agg(changes::text, ' | ') FROM public.exos_org_audit WHERE action = 'event.waiting_room');
  RAISE NOTICE 'OK  WR1 configure owner / manager + audit row; finance reads; content / scanner / outsider / other org 42501; bad numbers 22023';
END $$;

-- WR2 -----------------------------------------------------------------------
DO $$
DECLARE j jsonb; h uuid;
BEGIN
  PERFORM pg_temp.as_('anon');
  ASSERT public.exos_wroom_join(pg_temp.u('e3')) = '{"state": "off"}'::jsonb, 'WR2 no room: off';
  ASSERT public.exos_wroom_status(pg_temp.u('e3'), repeat('a', 64)) = '{"state": "off"}'::jsonb, 'WR2 no room: status off';
  PERFORM pg_temp.as_('authenticated', pg_temp.u('b1'));
  h := public.exos_create_hold(pg_temp.u('e3'), pg_temp.u('c5'), 1, 600, NULL);
  ASSERT h IS NOT NULL, 'WR2 a hold without a room needs no token';
  -- e1 is armed but its window opens 15 minutes before the on-sale (2 hours out).
  PERFORM pg_temp.as_('anon');
  j := public.exos_wroom_join(pg_temp.u('e1'));
  ASSERT j->>'state' = 'before' AND NOT j ? 'token'
     AND (j->>'opens_at')::timestamptz = now() + interval '105 minutes'
     AND (j->>'poll_after_ms')::int = 300000, 'WR2 before: ' || j::text;
  PERFORM pg_temp.as_('postgres');
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_wroom_entries WHERE event_id = pg_temp.u('e1')), 'WR2 nothing stored before the window';
  RAISE NOTICE 'OK  WR2 off by default (no token, holds as before); before the window: no token, the opening time';
END $$;

-- WR3 -----------------------------------------------------------------------
DO $$
DECLARE j jsonb; i int; v_corr float8; v_top int; v_err text;
BEGIN
  -- The on-sale is 10 minutes away: the lobby is open.
  UPDATE public.exos_ticket_tiers SET sales_start = now() + interval '10 minutes' WHERE id IN (pg_temp.u('c1'), pg_temp.u('c3'));
  UPDATE public.exos_drop_settings SET public_on_sale_at = now() + interval '10 minutes' WHERE event_id = pg_temp.u('e1');
  FOR i IN 1..200 LOOP
    PERFORM pg_temp.as_('anon', NULL, '203.0.113.' || (i % 250)::text);
    j := public.exos_wroom_join(pg_temp.u('e1'));
    ASSERT j->>'state' = 'lobby' AND j->>'token' ~ '^[0-9a-f]{64}$' AND NOT j ? 'position', 'WR3 lobby token: ' || j::text;
    INSERT INTO wr_tok VALUES (i, pg_temp.u('e1'), j->>'token', true);
  END LOOP;
  -- One token per browser: presenting it again answers the same place, no new row.
  PERFORM pg_temp.as_('anon', NULL, '203.0.113.7');
  j := public.exos_wroom_join(pg_temp.u('e1'), (SELECT token FROM wr_tok WHERE n = 7));
  ASSERT j->>'state' = 'lobby' AND j->>'token' = (SELECT token FROM wr_tok WHERE n = 7), 'WR3 same token back';
  PERFORM pg_temp.as_('postgres');
  ASSERT (SELECT count(*) FROM public.exos_wroom_entries WHERE event_id = pg_temp.u('e1')) = 200, 'WR3 200 entries';
  ASSERT (SELECT count(*) FROM public.exos_wroom_entries WHERE order_key IS NOT NULL AND event_id = pg_temp.u('e1')) = 0,
    'WR3 no place before the on-sale';
  -- Holds in the lobby: refused (nobody is admitted yet), even with a token.
  PERFORM pg_temp.as_('authenticated', pg_temp.u('b1'), '198.51.100.9', (SELECT token FROM wr_tok WHERE n = 1));
  v_err := pg_temp.st(format('SELECT public.exos_create_hold(%L, %L, 1, 600, NULL)', pg_temp.u('e1'), pg_temp.u('c1')));
  ASSERT v_err LIKE 'XWR01%', 'WR3 lobby hold refused: ' || v_err;

  -- The on-sale: it opened a second ago; everyone above arrived a minute before.
  PERFORM pg_temp.as_('postgres');
  UPDATE public.exos_ticket_tiers SET sales_start = now() - interval '1 second' WHERE id IN (pg_temp.u('c1'), pg_temp.u('c3'));
  UPDATE public.exos_drop_settings SET public_on_sale_at = now() - interval '1 second' WHERE event_id = pg_temp.u('e1');
  UPDATE public.exos_wroom_entries SET arrived_at = now() - interval '1 minute', last_seen_at = now() - interval '1 minute'
   WHERE event_id = pg_temp.u('e1');
  -- No credit in the first round (so the draw is all this checks).
  UPDATE public.exos_wroom_settings SET admit_clock = now() WHERE event_id = pg_temp.u('e1');
  PERFORM pg_temp.as_('anon', NULL, '203.0.113.1');
  j := public.exos_wroom_status(pg_temp.u('e1'), (SELECT token FROM wr_tok WHERE n = 1));
  ASSERT j->>'state' = 'waiting' AND (j->>'position')::int BETWEEN 1 AND 200 AND NOT j ? 'token', 'WR3 placed: ' || j::text;
  PERFORM pg_temp.as_('postgres');
  ASSERT (SELECT count(DISTINCT order_key) FROM public.exos_wroom_entries WHERE event_id = pg_temp.u('e1')
            AND order_key >= 0 AND order_key < 1) = 200, 'WR3 200 distinct random places';
  -- Random, not arrival order: rank vs arrival is uncorrelated, and the first
  -- 100 arrivals hold about half of the first 100 places.
  SELECT corr(t.n, r.rk) INTO v_corr FROM wr_tok t
    JOIN (SELECT token_hash, rank() OVER (ORDER BY order_key, id) AS rk FROM public.exos_wroom_entries
           WHERE event_id = pg_temp.u('e1')) r ON r.token_hash = public._exos_wroom_hash(t.event_id, t.token);
  SELECT count(*) INTO v_top FROM wr_tok t
    JOIN (SELECT token_hash, rank() OVER (ORDER BY order_key, id) AS rk FROM public.exos_wroom_entries
           WHERE event_id = pg_temp.u('e1')) r ON r.token_hash = public._exos_wroom_hash(t.event_id, t.token)
   WHERE t.n <= 100 AND r.rk <= 100;
  ASSERT abs(v_corr) < 0.35 AND v_top BETWEEN 25 AND 75, format('WR3 shuffled: corr %s, top %s', v_corr, v_top);
  -- Late arrivals: after every early one, in arrival order.
  FOR i IN 201..205 LOOP
    PERFORM pg_temp.as_('anon', NULL, '192.0.2.' || i::text);
    j := public.exos_wroom_join(pg_temp.u('e1'));
    ASSERT j->>'state' = 'waiting' AND (j->>'position')::int = 200 + (i - 200), 'WR3 late at the back: ' || j::text;
    INSERT INTO wr_tok VALUES (i, pg_temp.u('e1'), j->>'token', false);
    PERFORM pg_temp.as_('postgres');
    -- (they all arrived at the transaction's now(): spread them out, in order)
    UPDATE public.exos_wroom_entries SET arrived_at = arrived_at + make_interval(secs => i - 200),
                                         order_key = order_key - 1000 + (i - 200)
     WHERE token_hash = public._exos_wroom_hash(pg_temp.u('e1'), j->>'token');
  END LOOP;
  ASSERT (SELECT min(order_key) FROM public.exos_wroom_entries WHERE event_id = pg_temp.u('e1') AND arrived_at >= now())
       > (SELECT max(order_key) FROM public.exos_wroom_entries WHERE event_id = pg_temp.u('e1') AND arrived_at < now()),
    'WR3 every late arrival behind every early one';
  RAISE NOTICE 'OK  WR3 lobby (no place, holds refused), fair draw at the on-sale (200 distinct random places, corr %, top-half %), late arrivals at the back in order, one token per browser',
    round(v_corr::numeric, 3), v_top;
END $$;

-- WR4 -----------------------------------------------------------------------
DO $$
DECLARE j jsonb; v_front uuid[]; v_adm uuid[]; v_tok text; v_pos int; v_stale uuid;
BEGIN
  -- Everyone polled just now.
  UPDATE public.exos_wroom_entries SET last_seen_at = now() WHERE event_id = pg_temp.u('e1');
  SELECT array_agg(id ORDER BY order_key, id) INTO v_front
    FROM (SELECT id, order_key FROM public.exos_wroom_entries WHERE event_id = pg_temp.u('e1') ORDER BY order_key, id LIMIT 6) x;
  -- First round: 60 a minute, six seconds' worth = 6, the front of the line.
  UPDATE public.exos_wroom_settings SET advanced_at = now() - interval '6 seconds', admit_clock = NULL WHERE event_id = pg_temp.u('e1');
  PERFORM pg_temp.as_('anon');
  j := public.exos_wroom_status(pg_temp.u('e1'), (SELECT token FROM wr_tok WHERE n = 201));
  PERFORM pg_temp.as_('postgres');
  SELECT array_agg(id ORDER BY order_key, id) INTO v_adm FROM public.exos_wroom_entries WHERE event_id = pg_temp.u('e1') AND state = 'admitted';
  ASSERT v_adm = v_front, 'WR4 the first 6 in line: ' || coalesce(array_length(v_adm, 1), 0);
  ASSERT (SELECT bool_and(admit_expires_at = now() + interval '10 minutes') FROM public.exos_wroom_entries WHERE state = 'admitted'
            AND event_id = pg_temp.u('e1')), 'WR4 admitted for 10 minutes';
  -- At most one round every 5 seconds.
  UPDATE public.exos_wroom_settings SET admit_clock = now() - interval '30 seconds' WHERE event_id = pg_temp.u('e1');
  PERFORM public._exos_wroom_advance(pg_temp.u('e1'));
  ASSERT (SELECT count(*) FROM public.exos_wroom_entries WHERE event_id = pg_temp.u('e1') AND state = 'admitted') = 6, 'WR4 throttled';
  -- 30 seconds of credit later: 30 more.
  PERFORM pg_temp.tick(pg_temp.u('e1'), 30);
  PERFORM public._exos_wroom_advance(pg_temp.u('e1'));
  ASSERT (SELECT count(*) FROM public.exos_wroom_entries WHERE event_id = pg_temp.u('e1') AND state = 'admitted') = 36, 'WR4 +30';
  -- Ten quiet minutes: still one minute's worth at most.
  PERFORM pg_temp.tick(pg_temp.u('e1'), 600);
  PERFORM public._exos_wroom_advance(pg_temp.u('e1'));
  ASSERT (SELECT count(*) FROM public.exos_wroom_entries WHERE event_id = pg_temp.u('e1') AND state = 'admitted') = 96, 'WR4 capped at 60';
  -- A waiting person's position = the people still waiting ahead + 1.
  SELECT t.token, (SELECT count(*) FROM public.exos_wroom_entries x WHERE x.event_id = pg_temp.u('e1') AND x.state = 'waiting'
                     AND (x.order_key, x.id) < (e.order_key, e.id)) + 1
    INTO v_tok, v_pos
    FROM wr_tok t JOIN public.exos_wroom_entries e ON e.token_hash = public._exos_wroom_hash(t.event_id, t.token)
   WHERE e.state = 'waiting' ORDER BY e.order_key DESC LIMIT 1 OFFSET 50;
  PERFORM pg_temp.as_('anon');
  j := public.exos_wroom_status(pg_temp.u('e1'), v_tok);
  ASSERT j->>'state' = 'waiting' AND (j->>'position')::int = v_pos AND (j->>'ahead')::int = v_pos - 1
     AND (j->>'eta_minutes')::int = ceil(v_pos / 60.0) AND (j->>'admit_per_minute')::int = 60, 'WR4 position: ' || j::text;
  -- A tab not seen for 3 minutes is skipped (keeps its place); back, it goes next.
  PERFORM pg_temp.as_('postgres');
  UPDATE public.exos_wroom_entries SET last_seen_at = now() - interval '4 minutes'
   WHERE id = (SELECT id FROM public.exos_wroom_entries WHERE event_id = pg_temp.u('e1') AND state = 'waiting' ORDER BY order_key, id LIMIT 1)
  RETURNING id INTO v_stale;
  PERFORM pg_temp.tick(pg_temp.u('e1'), 1);
  PERFORM public._exos_wroom_advance(pg_temp.u('e1'));
  ASSERT (SELECT state FROM public.exos_wroom_entries WHERE id = v_stale) = 'waiting'
     AND (SELECT count(*) FROM public.exos_wroom_entries WHERE event_id = pg_temp.u('e1') AND state = 'admitted') = 97, 'WR4 stale skipped';
  UPDATE public.exos_wroom_entries SET last_seen_at = now() WHERE id = v_stale;
  PERFORM pg_temp.tick(pg_temp.u('e1'), 1);
  PERFORM public._exos_wroom_advance(pg_temp.u('e1'));
  ASSERT (SELECT state FROM public.exos_wroom_entries WHERE id = v_stale) = 'admitted', 'WR4 back at the front';
  RAISE NOTICE 'OK  WR4 batches: first round 6 (the front), one round per 5 s, +30 for 30 s, capped at a minute, positions, stale tabs skipped but keep their place';
END $$;

-- WR5 -----------------------------------------------------------------------
DO $$
DECLARE j jsonb; v_adm text; v_wait text; v_adm2 text; h uuid; v_err text; v_ids uuid[];
BEGIN
  SELECT t.token INTO v_adm FROM wr_tok t JOIN public.exos_wroom_entries e ON e.token_hash = public._exos_wroom_hash(t.event_id, t.token)
   WHERE e.state = 'admitted' ORDER BY e.order_key LIMIT 1;
  SELECT t.token INTO v_wait FROM wr_tok t JOIN public.exos_wroom_entries e ON e.token_hash = public._exos_wroom_hash(t.event_id, t.token)
   WHERE e.state = 'waiting' ORDER BY e.order_key LIMIT 1;
  SELECT t.token INTO v_adm2 FROM wr_tok t JOIN public.exos_wroom_entries e ON e.token_hash = public._exos_wroom_hash(t.event_id, t.token)
   WHERE e.state = 'admitted' ORDER BY e.order_key OFFSET 1 LIMIT 1;
  PERFORM pg_temp.as_('anon');
  j := public.exos_wroom_status(pg_temp.u('e1'), v_adm);
  ASSERT j->>'state' = 'admitted' AND (j->>'admitted_until')::timestamptz > now(), 'WR5 admitted status: ' || j::text;
  -- Refused: no token, a waiting one, a malformed one.
  PERFORM pg_temp.as_('authenticated', pg_temp.u('b1'));
  v_err := pg_temp.st(format('SELECT public.exos_create_hold(%L, %L, 1, 600, NULL)', pg_temp.u('e1'), pg_temp.u('c1')));
  ASSERT v_err LIKE 'XWR01%', 'WR5 no token: ' || v_err;
  PERFORM pg_temp.as_('authenticated', pg_temp.u('b1'), '198.51.100.1', v_wait);
  ASSERT pg_temp.st(format('SELECT public.exos_create_hold(%L, %L, 1, 600, NULL)', pg_temp.u('e1'), pg_temp.u('c1'))) LIKE 'XWR01%', 'WR5 waiting token';
  PERFORM pg_temp.as_('authenticated', pg_temp.u('b1'), '198.51.100.1', 'nope');
  ASSERT pg_temp.st(format('SELECT public.exos_create_hold(%L, %L, 1, 600, NULL)', pg_temp.u('e1'), pg_temp.u('c1'))) LIKE 'XWR01%', 'WR5 malformed';
  ASSERT pg_temp.st(format('SELECT public.exos_claim_free_tickets(%L, %L, 1)', pg_temp.u('e1'), pg_temp.u('c3'))) LIKE 'XWR01%', 'WR5 free claim';
  -- Admitted: the hold goes through and the admission is marked used.
  PERFORM pg_temp.as_('authenticated', pg_temp.u('b1'), '198.51.100.1', v_adm);
  h := public.exos_create_hold(pg_temp.u('e1'), pg_temp.u('c1'), 2, 600, NULL);
  ASSERT h IS NOT NULL, 'WR5 admitted hold';
  v_ids := public.exos_claim_free_tickets(pg_temp.u('e1'), pg_temp.u('c3'), 1);
  ASSERT cardinality(v_ids) = 1, 'WR5 admitted free claim';
  -- The guest hold (service role) and exos-checkout's first check.
  PERFORM pg_temp.as_('service_role', NULL, '198.51.100.1', NULL);
  ASSERT pg_temp.st(format('SELECT public.exos_create_guest_hold(%L, %L, 1, %L, %L, NULL)', pg_temp.u('e1'), pg_temp.u('c1'),
                           'guest@x.com', md5('g1'))) LIKE 'XWR01%', 'WR5 guest hold without a token';
  ASSERT pg_temp.st(format('SELECT public.exos_wroom_require(%L, %L, %L)', pg_temp.u('e1'), pg_temp.u('c1'), v_wait)) LIKE 'XWR01%', 'WR5 require waiting';
  ASSERT public.exos_wroom_require(pg_temp.u('e1'), pg_temp.u('c1'), v_adm2), 'WR5 require admitted';
  PERFORM pg_temp.as_('service_role', NULL, '198.51.100.1', v_adm2);
  ASSERT public.exos_create_guest_hold(pg_temp.u('e1'), pg_temp.u('c1'), 1, 'guest@x.com', md5('g1'), NULL) IS NOT NULL, 'WR5 guest hold admitted';
  -- The drop list presale type bypasses the room (members only, until the on-sale).
  PERFORM pg_temp.as_('authenticated', pg_temp.u('b2'));
  v_err := pg_temp.st(format('SELECT public.exos_create_hold(%L, %L, 1, 600, NULL)', pg_temp.u('e1'), pg_temp.u('c2')));
  ASSERT v_err NOT LIKE 'XWR01%', 'WR5 presale type not queued: ' || v_err;
  PERFORM pg_temp.as_('service_role');
  ASSERT public.exos_wroom_require(pg_temp.u('e1'), pg_temp.u('c2'), NULL), 'WR5 require: presale type';
  -- Another event's admitted token: e2 has its own room (on sale now).
  PERFORM pg_temp.as_('authenticated', pg_temp.u('a1'));
  PERFORM public.exos_wroom_configure(pg_temp.u('e2'), true, 15, 60, 10, 10);
  PERFORM pg_temp.as_('anon');
  j := public.exos_wroom_status(pg_temp.u('e2'), v_adm);
  ASSERT j->>'state' = 'unknown', 'WR5 another event''s token is unknown there: ' || j::text;
  PERFORM pg_temp.as_('authenticated', pg_temp.u('b2'), '198.51.100.1', v_adm);
  ASSERT pg_temp.st(format('SELECT public.exos_create_hold(%L, %L, 1, 600, NULL)', pg_temp.u('e2'), pg_temp.u('c4'))) LIKE 'XWR01%',
    'WR5 cross-event token refused';
  PERFORM pg_temp.as_('service_role');
  ASSERT pg_temp.st(format('SELECT public.exos_wroom_require(%L, %L, %L)', pg_temp.u('e2'), pg_temp.u('c4'), v_adm)) LIKE 'XWR01%',
    'WR5 cross-event require refused';
  PERFORM pg_temp.as_('postgres');
  ASSERT (SELECT count(*) FROM public.exos_wroom_entries WHERE used_at IS NOT NULL AND event_id = pg_temp.u('e1')) = 2, 'WR5 two used';
  PERFORM pg_temp.as_('authenticated', pg_temp.u('a1'));
  j := public.exos_wroom_summary(pg_temp.u('e1'));
  ASSERT (j->'counts'->>'checked_out')::int = 2 AND (j->'counts'->>'admitted')::int = 96 AND (j->'counts'->>'waiting')::int = 107
     AND (j->'counts'->>'total')::int = 205 AND j->>'phase' = 'live', 'WR5 counts: ' || j::text;
  RAISE NOTICE 'OK  WR5 gate: admitted token passes (hold, free claim, guest hold, require) and is marked used; none / waiting / malformed / other event XWR01; presale type bypasses';
END $$;

-- WR6 -----------------------------------------------------------------------
DO $$
DECLARE j jsonb; v_tok text;
BEGIN
  PERFORM pg_temp.as_('postgres');
  SELECT t.token INTO v_tok FROM wr_tok t JOIN public.exos_wroom_entries e ON e.token_hash = public._exos_wroom_hash(t.event_id, t.token)
   WHERE e.state = 'admitted' AND e.used_at IS NULL ORDER BY e.order_key LIMIT 1;
  UPDATE public.exos_wroom_entries SET admit_expires_at = now() - interval '1 second'
   WHERE token_hash = public._exos_wroom_hash(pg_temp.u('e1'), v_tok);
  PERFORM pg_temp.as_('anon');
  j := public.exos_wroom_status(pg_temp.u('e1'), v_tok);
  ASSERT j->>'state' = 'expired', 'WR6 expired: ' || j::text;
  PERFORM pg_temp.as_('authenticated', pg_temp.u('b2'), '198.51.100.1', v_tok);
  ASSERT pg_temp.st(format('SELECT public.exos_create_hold(%L, %L, 1, 600, NULL)', pg_temp.u('e1'), pg_temp.u('c1'))) LIKE 'XWR01%', 'WR6 gate refuses';
  PERFORM pg_temp.as_('postgres');
  PERFORM pg_temp.tick(pg_temp.u('e1'), 0);
  PERFORM public._exos_wroom_advance(pg_temp.u('e1'));
  ASSERT (SELECT state FROM public.exos_wroom_entries WHERE token_hash = public._exos_wroom_hash(pg_temp.u('e1'), v_tok)) = 'expired',
    'WR6 swept to expired';
  PERFORM pg_temp.as_('authenticated', pg_temp.u('a3'));
  j := public.exos_wroom_summary(pg_temp.u('e1'));
  ASSERT (j->'counts'->>'expired')::int = 1 AND (j->'counts'->>'admitted')::int = 95, 'WR6 counts: ' || j::text;
  RAISE NOTICE 'OK  WR6 admission expires after N minutes: status, gate and counts';
END $$;

-- WR7 -----------------------------------------------------------------------
DO $$
DECLARE j jsonb; i int; v_tok text; v_n int;
BEGIN
  PERFORM pg_temp.as_('postgres');
  SELECT count(*) INTO v_n FROM public.exos_wroom_entries WHERE event_id = pg_temp.u('e2');
  FOR i IN 1..60 LOOP
    PERFORM pg_temp.as_('anon', NULL, '100.64.0.1');
    j := public.exos_wroom_join(pg_temp.u('e2'));
    ASSERT j->>'state' = 'waiting', 'WR7 minted ' || i || ': ' || j::text;
    IF i = 1 THEN v_tok := j->>'token'; END IF;
  END LOOP;
  j := public.exos_wroom_join(pg_temp.u('e2'));
  ASSERT j = '{"state": "busy", "retry_after_ms": 5000}'::jsonb, 'WR7 61st busy: ' || j::text;
  ASSERT public.exos_wroom_join(pg_temp.u('e2'), v_tok)->>'state' IN ('waiting', 'admitted'), 'WR7 a known token still answers';
  ASSERT public.exos_wroom_status(pg_temp.u('e2'), v_tok)->>'state' IN ('waiting', 'admitted'), 'WR7 and polls';
  PERFORM pg_temp.as_('anon', NULL, '100.64.0.2');
  ASSERT public.exos_wroom_join(pg_temp.u('e2'))->>'state' IN ('waiting', 'admitted'), 'WR7 another network mints';
  PERFORM pg_temp.as_('postgres');
  ASSERT (SELECT count(*) FROM public.exos_wroom_entries WHERE event_id = pg_temp.u('e2')) = v_n + 61, 'WR7 nothing stored when busy';
  RAISE NOTICE 'OK  WR7 60 new tokens a minute per network, then busy with nothing stored; known tokens still poll';
END $$;

-- WR8 -----------------------------------------------------------------------
DO $$
DECLARE j jsonb; v_tok text; v_old text; h uuid;
BEGIN
  -- Idle: e2's line emptied (everyone admitted) 11 minutes ago.
  UPDATE public.exos_wroom_entries SET state = 'admitted', admitted_at = now(), admit_expires_at = now() + interval '10 minutes'
   WHERE event_id = pg_temp.u('e2') AND state = 'waiting';
  UPDATE public.exos_wroom_settings SET last_waiting_at = now() - interval '11 minutes', advanced_at = now() - interval '6 seconds'
   WHERE event_id = pg_temp.u('e2');
  PERFORM pg_temp.as_('anon', NULL, '100.64.0.9');
  j := public.exos_wroom_join(pg_temp.u('e2'));
  ASSERT j = '{"state": "off"}'::jsonb, 'WR8 idle room closed: ' || j::text;
  PERFORM pg_temp.as_('postgres');
  ASSERT (SELECT closed_reason = 'idle' AND closed_at = now() FROM public.exos_wroom_settings WHERE event_id = pg_temp.u('e2')), 'WR8 idle';
  PERFORM pg_temp.as_('authenticated', pg_temp.u('b2'));
  h := public.exos_create_hold(pg_temp.u('e2'), pg_temp.u('c4'), 1, 600, NULL);
  ASSERT h IS NOT NULL, 'WR8 closed: no token needed';
  -- The organizer turns e1's room off: everyone buys as usual.
  PERFORM pg_temp.as_('authenticated', pg_temp.u('a1'));
  j := public.exos_wroom_configure(pg_temp.u('e1'), false);
  ASSERT j->>'phase' = 'off' AND j->>'closed_reason' = 'organizer', 'WR8 turned off: ' || j::text;
  PERFORM pg_temp.as_('anon');
  ASSERT public.exos_wroom_join(pg_temp.u('e1')) = '{"state": "off"}'::jsonb, 'WR8 off: no token';
  PERFORM pg_temp.as_('service_role');
  ASSERT public.exos_wroom_require(pg_temp.u('e1'), pg_temp.u('c1'), NULL), 'WR8 off: require passes';
  -- On again: a new run; the old tokens are dead, the line starts empty.
  SELECT token INTO v_old FROM wr_tok WHERE n = 1;
  PERFORM pg_temp.as_('authenticated', pg_temp.u('a1'));
  j := public.exos_wroom_configure(pg_temp.u('e1'), true, 0, 120, 5, 10);
  ASSERT j->>'phase' = 'live' AND (j->'counts'->>'total')::int = 0 AND j->>'closed_at' IS NULL, 'WR8 new run: ' || j::text;
  PERFORM pg_temp.as_('anon');
  ASSERT public.exos_wroom_status(pg_temp.u('e1'), v_old)->>'state' = 'unknown', 'WR8 old token unknown';
  PERFORM pg_temp.as_('postgres');
  ASSERT (SELECT count(*) FROM public.exos_org_audit WHERE action = 'event.waiting_room' AND event_id = pg_temp.u('e1')) = 3, 'WR8 3 audit rows';
  RAISE NOTICE 'OK  WR8 closes when idle and when turned off (no token needed then); on again = a new run, old tokens dead';
END $$;

-- WR9 -----------------------------------------------------------------------
DO $$
BEGIN
  ASSERT NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public'
                       AND table_name IN ('exos_wroom_entries', 'exos_wroom_settings')
                       AND column_name ~ '(email|phone|ip|user_id|uid|name|agent)' AND column_name <> 'updated_by'),
    'WR9 no PII columns';
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_org_audit WHERE action = 'event.waiting_room' AND changes::text ~ '[0-9a-f]{64}'),
    'WR9 no token in the audit';
  RAISE NOTICE 'OK  WR9 no PII in the queue (token hash, times, state); no token in the audit';
END $$;

ROLLBACK;
