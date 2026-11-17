-- ============================================================================
-- On-sale waiting room (mig 20261118120000). Self-contained (d71… ids),
-- rolled back. now() is fixed inside the transaction, so time moves by
-- back-dating rows (arrived_at, advanced_at, admit_clock, admit_expires_at).
--   WR0 shape: RLS on, no client grants; definer + search_path; anon may call
--       exactly join / status; summary / configure signed in; require /
--       attach / verify gate service only; the gate is the first statement
--       of the five hold / claim bodies; no stale configure overloads
--   WR1 roles: configure owner / manager (+ an audit row); finance reads;
--       content, scanner, an outsider, the other org's owner 42501; 22023
--   WR2 off by default; "before" the window: no token, the opening time
--   WR3 lobby: a random place fixed at mint (none shown), holds refused; at
--       the on-sale 200 distinct random places, late arrivals at the back in
--       order; one token per browser
--   WR4 batches (first round, 5 s rounds, a minute's credit, positions); idle
--       3 minutes skipped, back within 30 keeps its place; idle 30 released
--       for good (poll, join, recount batch)
--   WR5 gate: admitted token passes; require check-only (x6); the first hold
--       binds the buyer, a claim spends the turn (XWR03); none / waiting /
--       malformed / other event XWR01; presale type in its window; one cart;
--       the event taken from the type
--   WR6 expiry; WR7 mint limits, strict network shares, the live-line cap,
--       Turnstile (anon refused, verified join scales under a ceiling)
--   WR8 idle / organizer close; re-enable keeps admitted turns
--   WR9 no PII
--   WR10 accounts (x1): one place per account outside the cap and shares,
--       resumed anywhere, usable only by that account
--   WR11 on-sale (x5): sold-out / ended early types ignored, the pin, no idle
--       close before a wait, drafts off
--   WR12 one turn, one order: attach / release / bind, sessions spend or free
--   WR13 polls: 10,000+ positions, the 5 s cached view
--   WR14 phone RSVP verify and the referral reward gated
--   WR15 phone RSVP: a wrong code costs nothing, the right one spends
--   WR16 a join on a place cached + rate-limited; one turn per account;
--       a retried free claim
--   WR17 the "live at once" warning
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
            WHERE c.relname IN ('exos_wroom_settings', 'exos_wroom_entries', 'exos_wroom_counts') AND c.relkind = 'r' LOOP
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
  ASSERT has_function_privilege('service_role', 'public.exos_wroom_require(uuid,uuid,text,uuid,text)', 'EXECUTE')
     AND NOT has_function_privilege('authenticated', 'public.exos_wroom_require(uuid,uuid,text,uuid,text)', 'EXECUTE'), 'WR0 require: service only';
  FOREACH f IN ARRAY ARRAY['public.exos_create_hold(uuid,uuid,integer,integer,text)',
                           'public.exos_create_guest_hold(uuid,uuid,integer,text,text,text)',
                           'public.exos_claim_free_tickets(uuid,uuid,integer,text,text,text)',
                           'public.exos_phone_rsvp_verify(uuid,text,text)',
                           'public.exos_redeem_referral_reward(uuid,uuid)'] LOOP
    v_def := pg_get_functiondef(f::regprocedure);
    ASSERT position(E'\nBEGIN\n  PERFORM public._exos_wroom_gate' in v_def) = position(E'\nBEGIN\n' in v_def)
       AND (length(v_def) - length(replace(v_def, '/* exos: waiting room gate */', ''))) = length('/* exos: waiting room gate */'),
      'WR0 gate first, once: ' || f;
  END LOOP;
  ASSERT has_function_privilege('service_role', 'public.exos_wroom_attach(uuid,uuid,text,uuid,text,uuid)', 'EXECUTE')
     AND NOT has_function_privilege('authenticated', 'public.exos_wroom_attach(uuid,uuid,text,uuid,text,uuid)', 'EXECUTE')
     AND NOT has_function_privilege('anon', 'public.exos_wroom_verify_gate(jsonb)', 'EXECUTE'), 'WR0 attach / verify gate: service only';
  ASSERT to_regprocedure('public.exos_wroom_configure(uuid,boolean,integer,integer,integer,integer,integer)') IS NULL
     AND to_regprocedure('public.exos_wroom_configure(uuid,boolean,integer,integer,integer,integer,integer,boolean)') IS NULL,
    'WR0 no stale configure overloads';
  RAISE NOTICE 'OK  WR0 RLS + no client grants, search_path, anon / signed-in / service surfaces, the gate first in 5 bodies, no stale overloads';
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
  -- Each place got its random key at mint (no draw later); none is shown before the on-sale.
  ASSERT (SELECT bool_and(order_key >= 0 AND order_key < 1) FROM public.exos_wroom_entries WHERE event_id = pg_temp.u('e1')),
    'WR3 random keys at mint';
  -- Holds in the lobby: refused (nobody is admitted yet), even with a token.
  PERFORM pg_temp.as_('authenticated', pg_temp.u('b1'), '198.51.100.9', (SELECT token FROM wr_tok WHERE n = 1));
  v_err := pg_temp.st(format('SELECT public.exos_create_hold(%L, %L, 1, 600, NULL)', pg_temp.u('e1'), pg_temp.u('c1')));
  ASSERT v_err LIKE 'XWR01%', 'WR3 lobby hold refused: ' || v_err;

  -- The on-sale: it opened a second ago.
  PERFORM pg_temp.as_('postgres');
  UPDATE public.exos_ticket_tiers SET sales_start = now() - interval '1 second' WHERE id IN (pg_temp.u('c1'), pg_temp.u('c3'));
  UPDATE public.exos_drop_settings SET public_on_sale_at = now() - interval '1 second' WHERE event_id = pg_temp.u('e1');
  -- No credit in the first round (places only).
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
  END LOOP;
  PERFORM pg_temp.as_('postgres');
  ASSERT (SELECT array_agg(e.order_key > 1 ORDER BY t.n) = array_fill(true, ARRAY[5])
                 AND array_agg(e.order_key ORDER BY t.n) = array_agg(e.order_key ORDER BY e.order_key)
            FROM wr_tok t JOIN public.exos_wroom_entries e ON e.token_hash = public._exos_wroom_hash(t.event_id, t.token)
           WHERE t.n > 200), 'WR3 every late arrival behind every early one, in arrival order';
  RAISE NOTICE 'OK  WR3 lobby (random place at mint, none shown, holds refused), the on-sale (200 distinct random places, corr %, top-half %), late arrivals at the back in order, one token per browser',
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
  -- A tab not seen for 3 minutes is skipped; back within 30 minutes (room left), it keeps its place.
  PERFORM pg_temp.as_('postgres');
  UPDATE public.exos_wroom_entries SET last_seen_at = now() - interval '4 minutes'
   WHERE id = (SELECT id FROM public.exos_wroom_entries WHERE event_id = pg_temp.u('e1') AND state = 'waiting' ORDER BY order_key, id LIMIT 1)
  RETURNING id INTO v_stale;
  PERFORM pg_temp.tick(pg_temp.u('e1'), 1);
  PERFORM public._exos_wroom_advance(pg_temp.u('e1'));
  ASSERT (SELECT state FROM public.exos_wroom_entries WHERE id = v_stale) = 'waiting'
     AND (SELECT count(*) FROM public.exos_wroom_entries WHERE event_id = pg_temp.u('e1') AND state = 'admitted') = 97, 'WR4 stale skipped';
  SELECT t.token INTO v_tok FROM wr_tok t
   WHERE public._exos_wroom_hash(t.event_id, t.token) = (SELECT token_hash FROM public.exos_wroom_entries WHERE id = v_stale);
  PERFORM pg_temp.as_('anon');
  j := public.exos_wroom_status(pg_temp.u('e1'), v_tok);
  ASSERT j->>'state' = 'waiting' AND (j->>'position')::int = 1, 'WR4 revived at the front: ' || j::text;
  PERFORM pg_temp.as_('postgres');
  PERFORM pg_temp.tick(pg_temp.u('e1'), 1);
  PERFORM public._exos_wroom_advance(pg_temp.u('e1'));
  ASSERT (SELECT state FROM public.exos_wroom_entries WHERE id = v_stale) = 'admitted', 'WR4 back, it goes next';
  -- Idle 30 minutes: released for good; neither a poll nor a join with the token revives it.
  UPDATE public.exos_wroom_entries SET last_seen_at = now() - interval '31 minutes'
   WHERE id = (SELECT id FROM public.exos_wroom_entries WHERE event_id = pg_temp.u('e1') AND state = 'waiting' ORDER BY order_key, id LIMIT 1)
  RETURNING id INTO v_stale;
  ASSERT public._exos_wroom_view(pg_temp.u('e1'), v_stale) @> '{"state": "expired", "reason": "idle"}'::jsonb, 'WR4 idle on read';
  SELECT t.token INTO v_tok FROM wr_tok t
   WHERE public._exos_wroom_hash(t.event_id, t.token) = (SELECT token_hash FROM public.exos_wroom_entries WHERE id = v_stale);
  PERFORM pg_temp.as_('anon');
  j := public.exos_wroom_status(pg_temp.u('e1'), v_tok);
  ASSERT j->>'state' = 'expired' AND j->>'reason' = 'idle' AND NOT j ? 'token', 'WR4 30-minute idle poll: ' || j::text;
  j := public.exos_wroom_join(pg_temp.u('e1'), v_tok);
  ASSERT j->>'state' = 'expired' AND j->>'reason' = 'idle' AND NOT j ? 'token', 'WR4 idle join with the token: ' || j::text;
  PERFORM pg_temp.as_('postgres');
  ASSERT (SELECT state = 'abandoned' AND last_seen_at = now() - interval '31 minutes' FROM public.exos_wroom_entries WHERE id = v_stale),
    'WR4 marked abandoned, not revived';
  PERFORM pg_temp.tick(pg_temp.u('e1'), 1);
  PERFORM public._exos_wroom_advance(pg_temp.u('e1'));
  ASSERT (SELECT state FROM public.exos_wroom_entries WHERE id = v_stale) = 'abandoned'
     AND (SELECT count(*) FROM public.exos_wroom_entries WHERE event_id = pg_temp.u('e1') AND state = 'admitted') = 99, 'WR4 never admitted';
  -- The recount marks 30-minute-idle places in batches too.
  UPDATE public.exos_wroom_entries SET last_seen_at = now() - interval '40 minutes'
   WHERE id = (SELECT id FROM public.exos_wroom_entries WHERE event_id = pg_temp.u('e1') AND state = 'waiting' ORDER BY order_key DESC, id LIMIT 1)
  RETURNING id INTO v_stale;
  UPDATE public.exos_wroom_settings SET counted_at = now() - interval '6 seconds' WHERE event_id = pg_temp.u('e1');
  PERFORM public._exos_wroom_recount(pg_temp.u('e1'));
  ASSERT (SELECT state FROM public.exos_wroom_entries WHERE id = v_stale) = 'abandoned', 'WR4 recount abandons';
  RAISE NOTICE 'OK  WR4 batches: first round 6 (the front), one round per 5 s, +30 for 30 s, capped at a minute, positions; idle 3 minutes skipped, back within 30 keeps its place; idle 30 released for good (poll, join, recount)';
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
  -- Admitted: the hold goes through and binds the turn to b1.
  PERFORM pg_temp.as_('authenticated', pg_temp.u('b1'), '198.51.100.1', v_adm);
  h := public.exos_create_hold(pg_temp.u('e1'), pg_temp.u('c1'), 2, 600, NULL);
  ASSERT h IS NOT NULL, 'WR5 admitted hold';
  -- b1's turn refuses b2's account.
  PERFORM pg_temp.as_('authenticated', pg_temp.u('b2'), '198.51.100.1', v_adm);
  ASSERT pg_temp.st(format('SELECT public.exos_create_hold(%L, %L, 1, 600, NULL)', pg_temp.u('e1'), pg_temp.u('c1'))) LIKE 'XWR01%',
    'WR5 another account on a bound turn';
  ASSERT pg_temp.st(format('SELECT public.exos_claim_free_tickets(%L, %L, 1)', pg_temp.u('e1'), pg_temp.u('c3'))) LIKE 'XWR01%',
    'WR5 another account, free claim';
  -- A completed claim spends the turn: nothing more on it (XWR03).
  PERFORM pg_temp.as_('authenticated', pg_temp.u('b1'), '198.51.100.1', v_adm);
  v_ids := public.exos_claim_free_tickets(pg_temp.u('e1'), pg_temp.u('c3'), 1);
  ASSERT cardinality(v_ids) = 1, 'WR5 admitted free claim';
  ASSERT pg_temp.st(format('SELECT public.exos_create_hold(%L, %L, 1, 600, NULL)', pg_temp.u('e1'), pg_temp.u('c1'))) LIKE 'XWR03%',
    'WR5 a spent turn: XWR03';
  PERFORM pg_temp.as_('anon');
  ASSERT public.exos_wroom_status(pg_temp.u('e1'), v_adm) @> '{"state": "expired", "reason": "used"}'::jsonb, 'WR5 spent: status says used';
  -- The guest hold (service role) and exos-checkout's first check.
  PERFORM pg_temp.as_('service_role', NULL, '198.51.100.1', NULL);
  ASSERT pg_temp.st(format('SELECT public.exos_create_guest_hold(%L, %L, 1, %L, %L, NULL)', pg_temp.u('e1'), pg_temp.u('c1'),
                           'guest@x.com', md5('g1'))) LIKE 'XWR01%', 'WR5 guest hold without a token';
  ASSERT pg_temp.st(format('SELECT public.exos_wroom_require(%L, %L, %L, NULL, %L)', pg_temp.u('e1'), pg_temp.u('c1'), v_wait, 'guest@x.com')) LIKE 'XWR01%', 'WR5 require waiting';
  -- exos_wroom_require is check-only: a typo'd email first (then a refusal
  -- elsewhere in checkout) binds nothing; the right email still can go on (x6).
  ASSERT public.exos_wroom_require(pg_temp.u('e1'), pg_temp.u('c1'), v_adm2, NULL, 'guest@x.con'), 'WR5 require (typo)';
  PERFORM pg_temp.as_('postgres');
  ASSERT (SELECT redeemer_hash IS NULL AND used_at IS NULL FROM public.exos_wroom_entries
           WHERE token_hash = public._exos_wroom_hash(pg_temp.u('e1'), v_adm2)), 'WR5 require wrote nothing';
  PERFORM pg_temp.as_('service_role', NULL, '198.51.100.1', NULL);
  ASSERT public.exos_wroom_require(pg_temp.u('e1'), pg_temp.u('c1'), v_adm2, NULL, 'Guest@x.com '), 'WR5 require admitted';
  PERFORM pg_temp.as_('service_role', NULL, '198.51.100.1', v_adm2);
  ASSERT public.exos_create_guest_hold(pg_temp.u('e1'), pg_temp.u('c1'), 1, 'guest@x.com', md5('g1'), NULL) IS NOT NULL, 'WR5 guest hold admitted';
  ASSERT pg_temp.st(format('SELECT public.exos_create_guest_hold(%L, %L, 1, %L, %L, NULL)', pg_temp.u('e1'), pg_temp.u('c1'),
                           'other@x.com', md5('g2'))) LIKE 'XWR01%', 'WR5 the guest''s turn refuses another email';
  -- The same guest again: one live cart (the first hold is released, never two).
  ASSERT public.exos_create_guest_hold(pg_temp.u('e1'), pg_temp.u('c1'), 1, 'guest@x.com', md5('g1'), NULL) IS NOT NULL, 'WR5 same guest again';
  PERFORM pg_temp.as_('postgres');
  ASSERT (SELECT count(*) FROM public.exos_cart_holds WHERE event_id = pg_temp.u('e1') AND buyer_email = 'guest@x.com' AND status = 'active') = 1,
    'WR5 one live cart per turn';
  -- Now bound to the guest (the hold): another account or email is refused.
  PERFORM pg_temp.as_('service_role');
  ASSERT pg_temp.st(format('SELECT public.exos_wroom_require(%L, %L, %L, %L, NULL)', pg_temp.u('e1'), pg_temp.u('c1'), v_adm2,
                           pg_temp.u('b2'))) LIKE 'XWR01%', 'WR5 a bound turn refuses another account';
  ASSERT pg_temp.st(format('SELECT public.exos_wroom_require(%L, %L, %L, NULL, %L)', pg_temp.u('e1'), pg_temp.u('c1'), v_adm2,
                           'guest@x.con')) LIKE 'XWR01%', 'WR5 ... and the typo now';
  -- A roomless event named with this room's ticket type: the type's event is checked.
  PERFORM pg_temp.as_('service_role');
  ASSERT pg_temp.st(format('SELECT public.exos_wroom_require(%L, %L, NULL, %L, NULL)', pg_temp.u('e3'), pg_temp.u('c1'), pg_temp.u('b2')))
    LIKE 'XWR01%', 'WR5 event taken from the type';
  -- The drop list presale type bypasses the room in its early window (members
  -- only, their code, until the public on-sale it was set against); after, it queues.
  PERFORM pg_temp.as_('postgres');
  UPDATE public.exos_drop_settings SET public_on_sale_at = now() + interval '30 minutes' WHERE event_id = pg_temp.u('e1');
  PERFORM pg_temp.as_('authenticated', pg_temp.u('b2'));
  v_err := pg_temp.st(format('SELECT public.exos_create_hold(%L, %L, 1, 600, NULL)', pg_temp.u('e1'), pg_temp.u('c2')));
  ASSERT v_err NOT LIKE 'XWR01%', 'WR5 presale type not queued: ' || v_err;
  PERFORM pg_temp.as_('service_role');
  ASSERT public.exos_wroom_require(pg_temp.u('e1'), pg_temp.u('c2'), NULL, pg_temp.u('b2'), NULL), 'WR5 require: presale type';
  PERFORM pg_temp.as_('postgres');
  UPDATE public.exos_drop_settings SET public_on_sale_at = now() - interval '1 second' WHERE event_id = pg_temp.u('e1');
  PERFORM pg_temp.as_('service_role');
  ASSERT pg_temp.st(format('SELECT public.exos_wroom_require(%L, %L, NULL, %L, NULL)', pg_temp.u('e1'), pg_temp.u('c2'), pg_temp.u('b2'))) LIKE 'XWR01%',
    'WR5 presale type after the public on-sale: queued';
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
  ASSERT pg_temp.st(format('SELECT public.exos_wroom_require(%L, %L, %L, %L, NULL)', pg_temp.u('e2'), pg_temp.u('c4'), v_adm, pg_temp.u('b1'))) LIKE 'XWR01%',
    'WR5 cross-event require refused';
  PERFORM pg_temp.as_('postgres');
  ASSERT (SELECT count(*) FROM public.exos_wroom_entries WHERE used_at IS NOT NULL AND event_id = pg_temp.u('e1')) = 2, 'WR5 two used';
  PERFORM pg_temp.as_('authenticated', pg_temp.u('a1'));
  j := public.exos_wroom_summary(pg_temp.u('e1'));
  ASSERT (j->'counts'->>'checked_out')::int = 2 AND (j->'counts'->>'admitted')::int = 97 AND (j->'counts'->>'waiting')::int = 104
     AND (j->'counts'->>'total')::int = 205 AND j->>'phase' = 'live', 'WR5 counts: ' || j::text;
  RAISE NOTICE 'OK  WR5 gate: admitted token passes (hold, free claim, guest hold, require); require is check-only (x6); the first hold binds the turn to its buyer, a claim spends it (XWR03 after); none / waiting / malformed / other event XWR01; presale type bypasses in its window only; one live cart; the event is taken from the type';
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
  ASSERT (j->'counts'->>'expired')::int = 3 AND (j->'counts'->>'admitted')::int = 96, 'WR6 counts (1 lapsed + 2 abandoned): ' || j::text;
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
  -- IPv6: rotating /64s inside one /48 hits the /48's 120 a minute.
  FOR i IN 1..120 LOOP
    PERFORM pg_temp.as_('anon', NULL, '2001:db8:1:' || to_hex(i) || '::1');
    j := public.exos_wroom_join(pg_temp.u('e2'));
    ASSERT j->>'state' IN ('waiting', 'full'), 'WR7 v6 ' || i || ': ' || j::text;
  END LOOP;
  PERFORM pg_temp.as_('anon', NULL, '2001:db8:1:ff::1');
  ASSERT public.exos_wroom_join(pg_temp.u('e2'))->>'state' = 'busy', 'WR7 /48 rate limit';
  PERFORM pg_temp.as_('postgres');
  -- ...and only 20 of them got a place: 20 per /48 per run.
  ASSERT (SELECT count(*) FROM public.exos_wroom_entries WHERE event_id = pg_temp.u('e2')) = v_n + 61 + 20, 'WR7 20 per /48 per run';
  -- IPv6 /32: 100 LIVE places without a CAPTCHA. The 20 above are in 2001:db8::/32; 80 more, then a
  -- fresh /48 and /64 in it is full, another /32 isn't; idle ones free the quota.
  INSERT INTO public.exos_wroom_entries (org_id, event_id, run_id, token_hash, net_hash, net32_hash, order_key)
  SELECT pg_temp.u('1'), pg_temp.u('e2'), s.run_id, encode(sha256(convert_to('wr7-32-' || g, 'UTF8')), 'hex'),
         encode(sha256(convert_to('wr7-48-' || g, 'UTF8')), 'hex'),
         encode(sha256(convert_to(s.run_id::text || ':2001:db8::/32', 'UTF8')), 'hex'), extract(epoch FROM now())
    FROM public.exos_wroom_settings s, generate_series(1, 80) g WHERE s.event_id = pg_temp.u('e2');
  PERFORM pg_temp.as_('anon', NULL, '2001:db8:9999:1::1');
  j := public.exos_wroom_join(pg_temp.u('e2'));
  ASSERT j->>'state' = 'full' AND j->>'reason' = 'network', 'WR7 100 live per /32: ' || j::text;
  PERFORM pg_temp.as_('anon', NULL, '2001:db9:1:1::1');
  ASSERT public.exos_wroom_join(pg_temp.u('e2'))->>'state' = 'waiting', 'WR7 another /32 joins';
  PERFORM pg_temp.as_('postgres');
  UPDATE public.exos_wroom_entries SET last_seen_at = now() - interval '4 minutes'
   WHERE event_id = pg_temp.u('e2') AND net32_hash = encode(sha256(convert_to(
         (SELECT run_id FROM public.exos_wroom_settings WHERE event_id = pg_temp.u('e2'))::text || ':2001:db8::/32', 'UTF8')), 'hex')
     AND state = 'waiting';
  PERFORM pg_temp.as_('anon', NULL, '2001:db8:9999:2::1');
  ASSERT public.exos_wroom_join(pg_temp.u('e2'))->>'state' = 'waiting', 'WR7 idle places free the /32 quota';
  -- An IPv4 address: 200 per run (shared NAT). 200 rows from 100.64.0.3's network, then full.
  PERFORM pg_temp.as_('postgres');
  INSERT INTO public.exos_wroom_entries (org_id, event_id, run_id, token_hash, net_hash, net32_hash, order_key)
  SELECT pg_temp.u('1'), pg_temp.u('e2'), s.run_id, encode(sha256(convert_to('wr7-' || g, 'UTF8')), 'hex'),
         encode(sha256(convert_to(s.run_id::text || ':100.64.0.3', 'UTF8')), 'hex'),
         encode(sha256(convert_to(s.run_id::text || ':100.64.0.3', 'UTF8')), 'hex'), extract(epoch FROM now())
    FROM public.exos_wroom_settings s, generate_series(1, 200) g WHERE s.event_id = pg_temp.u('e2');
  PERFORM pg_temp.as_('anon', NULL, '100.64.0.3');
  j := public.exos_wroom_join(pg_temp.u('e2'));
  ASSERT j->>'state' = 'full' AND j->>'reason' = 'network' AND NOT j ? 'token', 'WR7 200 per IPv4 per run: ' || j::text;
  -- The room's cap counts the LIVE line: the organizer sets 100 (fewer than are live): full.
  PERFORM pg_temp.as_('authenticated', pg_temp.u('a1'));
  j := public.exos_wroom_configure(pg_temp.u('e2'), true, NULL, NULL, NULL, NULL, 100);
  ASSERT (j->>'cap')::int = 100 AND (j->>'max_entries')::int = 100, 'WR7 cap set: ' || j::text;
  PERFORM pg_temp.as_('postgres');
  UPDATE public.exos_wroom_settings SET counted_at = now() - interval '6 seconds', advanced_at = now() WHERE event_id = pg_temp.u('e2');
  PERFORM pg_temp.as_('anon', NULL, '100.64.0.4');
  j := public.exos_wroom_join(pg_temp.u('e2'));
  ASSERT j->>'state' = 'full' AND j->>'reason' = 'room', 'WR7 room full: ' || j::text;
  ASSERT public.exos_wroom_join(pg_temp.u('e2'), v_tok)->>'state' IN ('waiting', 'admitted'), 'WR7 people in line keep their place';
  PERFORM pg_temp.as_('postgres');
  ASSERT (SELECT live_count FROM public.exos_wroom_settings WHERE event_id = pg_temp.u('e2'))
       = (SELECT count(*) FROM public.exos_wroom_entries x WHERE x.event_id = pg_temp.u('e2')
            AND ((x.state = 'waiting' AND x.last_seen_at > now() - interval '3 minutes')
              OR (x.state = 'admitted' AND x.admit_expires_at > now() AND x.used_at IS NULL))), 'WR7 live count exact';
  -- Abandoned places free up: all but 50 waiting go idle (3+ minutes unseen).
  UPDATE public.exos_wroom_entries SET last_seen_at = now() - interval '4 minutes'
   WHERE event_id = pg_temp.u('e2') AND state = 'waiting'
     AND id NOT IN (SELECT id FROM public.exos_wroom_entries WHERE event_id = pg_temp.u('e2') AND state = 'waiting'
                      AND last_seen_at > now() - interval '3 minutes' ORDER BY id LIMIT 50);
  UPDATE public.exos_wroom_settings SET counted_at = now() - interval '6 seconds' WHERE event_id = pg_temp.u('e2');
  PERFORM pg_temp.as_('anon', NULL, '100.64.0.5');
  ASSERT public.exos_wroom_join(pg_temp.u('e2'))->>'state' = 'waiting', 'WR7 idle places free the room';
  PERFORM pg_temp.as_('postgres');
  ASSERT (SELECT live_count BETWEEN 50 AND 99 FROM public.exos_wroom_settings WHERE event_id = pg_temp.u('e2')),
    'WR7 live count after idling: ' || (SELECT live_count FROM public.exos_wroom_settings WHERE event_id = pg_temp.u('e2'));
  -- Admitted, unused places count until they expire: 60 idle ones admitted -> full; expired -> free.
  UPDATE public.exos_wroom_entries SET state = 'admitted', admitted_at = now(), admit_expires_at = now() + interval '10 minutes'
   WHERE id IN (SELECT id FROM public.exos_wroom_entries WHERE event_id = pg_temp.u('e2') AND state IN ('waiting', 'abandoned')
                  AND last_seen_at < now() - interval '3 minutes' ORDER BY id LIMIT 60);
  UPDATE public.exos_wroom_settings SET counted_at = now() - interval '6 seconds' WHERE event_id = pg_temp.u('e2');
  PERFORM pg_temp.as_('anon', NULL, '100.64.0.6');
  ASSERT public.exos_wroom_join(pg_temp.u('e2'))->>'state' = 'full', 'WR7 admitted places are live';
  PERFORM pg_temp.as_('postgres');
  UPDATE public.exos_wroom_entries SET admit_expires_at = now() - interval '1 second'
   WHERE event_id = pg_temp.u('e2') AND state = 'admitted' AND admitted_at = now();
  UPDATE public.exos_wroom_settings SET counted_at = now() - interval '6 seconds' WHERE event_id = pg_temp.u('e2');
  PERFORM pg_temp.as_('anon', NULL, '100.64.0.7');
  ASSERT public.exos_wroom_join(pg_temp.u('e2'))->>'state' = 'waiting', 'WR7 expired places free the room';
  -- Strict without a CAPTCHA: a fresh /48 with 25 live places is full, even in a 50,000 room.
  PERFORM pg_temp.as_('postgres');
  INSERT INTO public.exos_wroom_entries (org_id, event_id, run_id, token_hash, net_hash, net32_hash, order_key)
  SELECT pg_temp.u('1'), pg_temp.u('e2'), s.run_id, encode(sha256(convert_to('wr7-s48-' || g, 'UTF8')), 'hex'),
         encode(sha256(convert_to(s.run_id::text || ':2001:dba:5::/48', 'UTF8')), 'hex'),
         encode(sha256(convert_to('wr7-s32-' || g, 'UTF8')), 'hex'), extract(epoch FROM now())
    FROM public.exos_wroom_settings s, generate_series(1, 25) g WHERE s.event_id = pg_temp.u('e2');
  PERFORM pg_temp.as_('authenticated', pg_temp.u('a1'));
  j := public.exos_wroom_configure(pg_temp.u('e2'), true, NULL, NULL, NULL, NULL, 50000);
  ASSERT (j->>'cap')::int = 50000 AND j->>'turnstile' = 'false', 'WR7 cap 50,000, no Turnstile: ' || j::text;
  PERFORM pg_temp.as_('anon', NULL, '2001:dba:5:1::1');
  j := public.exos_wroom_join(pg_temp.u('e2'));
  ASSERT j->>'state' = 'full' AND j->>'reason' = 'network', 'WR7 strict /48 share (20) without Turnstile: ' || j::text;
  -- Turnstile on: the anon join can't mint (challenge, nothing stored) ...
  PERFORM pg_temp.as_('authenticated', pg_temp.u('a1'));
  j := public.exos_wroom_configure(pg_temp.u('e2'), true, NULL, NULL, NULL, NULL, NULL, true);
  ASSERT j->>'turnstile' = 'true' AND (j->>'cap')::int = 50000, 'WR7 Turnstile on: ' || j::text;
  PERFORM pg_temp.as_('postgres');
  SELECT count(*) INTO v_n FROM public.exos_wroom_entries WHERE event_id = pg_temp.u('e2');
  PERFORM pg_temp.as_('anon', NULL, '198.51.100.77');
  ASSERT public.exos_wroom_join(pg_temp.u('e2')) = '{"state": "challenge", "signed_in": false}'::jsonb, 'WR7 anon join refused while Turnstile is on';
  ASSERT pg_temp.st(format('SELECT public.exos_wroom_join_verified(%L, NULL, %L)', pg_temp.u('e2'), '{}')) LIKE '42501%',
    'WR7 the verified join is service role only';
  -- ... the verified join (exos-wroom-join, service role) scales the shares under a ceiling: 200 per /48 at 50,000.
  PERFORM pg_temp.as_('service_role', NULL, '10.9.9.9');
  j := public.exos_wroom_join_verified(pg_temp.u('e2'), NULL, '{"cf-connecting-ip": "2001:dba:5:2::1"}');
  ASSERT j->>'state' = 'waiting' AND j->>'token' ~ '^[0-9a-f]{64}$', 'WR7 more than 20 from one /48 behind Turnstile: ' || j::text;
  v_tok := j->>'token';
  PERFORM pg_temp.as_('postgres');
  ASSERT (SELECT count(*) FROM public.exos_wroom_entries WHERE event_id = pg_temp.u('e2')) = v_n + 1, 'WR7 challenge stored nothing';
  -- A place already held keeps working through the anon join and poll.
  PERFORM pg_temp.as_('anon', NULL, '2001:dba:5:2::1');
  ASSERT public.exos_wroom_join(pg_temp.u('e2'), v_tok)->>'state' = 'waiting', 'WR7 own token without a new challenge';
  PERFORM pg_temp.as_('postgres');
  INSERT INTO public.exos_wroom_entries (org_id, event_id, run_id, token_hash, net_hash, net32_hash, order_key)
  SELECT pg_temp.u('1'), pg_temp.u('e2'), s.run_id, encode(sha256(convert_to('wr7-s48b-' || g, 'UTF8')), 'hex'),
         encode(sha256(convert_to(s.run_id::text || ':2001:dba:5::/48', 'UTF8')), 'hex'),
         encode(sha256(convert_to('wr7-s32b-' || g, 'UTF8')), 'hex'), extract(epoch FROM now())
    FROM public.exos_wroom_settings s, generate_series(1, 174) g WHERE s.event_id = pg_temp.u('e2');
  PERFORM pg_temp.as_('service_role');
  j := public.exos_wroom_join_verified(pg_temp.u('e2'), NULL, '{"cf-connecting-ip": "2001:dba:5:3::1"}');
  ASSERT j->>'state' = 'full' AND j->>'reason' = 'network', 'WR7 the scaled /48 share holds at its ceiling, 200: ' || j::text;
  -- IPv4 behind Turnstile: least(5,000, 1,000) = 1,000 live places at 50,000.
  j := public.exos_wroom_join_verified(pg_temp.u('e2'), NULL, '{"cf-connecting-ip": "100.64.0.3"}');
  ASSERT j->>'state' = 'waiting', 'WR7 more than 200 from one IPv4 address behind Turnstile: ' || j::text;
  PERFORM pg_temp.as_('postgres');
  INSERT INTO public.exos_wroom_entries (org_id, event_id, run_id, token_hash, net_hash, net32_hash, order_key)
  SELECT pg_temp.u('1'), pg_temp.u('e2'), s.run_id, encode(sha256(convert_to('wr7-s4-' || g, 'UTF8')), 'hex'),
         encode(sha256(convert_to(s.run_id::text || ':100.64.0.3', 'UTF8')), 'hex'),
         encode(sha256(convert_to(s.run_id::text || ':100.64.0.3', 'UTF8')), 'hex'), extract(epoch FROM now())
    FROM public.exos_wroom_settings s, generate_series(1, 999) g WHERE s.event_id = pg_temp.u('e2');
  PERFORM pg_temp.as_('service_role');
  j := public.exos_wroom_join_verified(pg_temp.u('e2'), NULL, '{"cf-connecting-ip": "100.64.0.3"}');
  ASSERT j->>'state' = 'full' AND j->>'reason' = 'network', 'WR7 the scaled IPv4 share holds at its ceiling, 1,000: ' || j::text;
  -- The verified join reads the address the edge function passed, not its own request's.
  ASSERT public.exos_wroom_join_verified(pg_temp.u('e2'), NULL, '{"cf-connecting-ip": "100.64.0.8"}')->>'state' = 'waiting',
    'WR7 the passed address decides';
  -- Network shares count the live line: those 1,000 going idle free the address.
  PERFORM pg_temp.as_('postgres');
  UPDATE public.exos_wroom_entries SET last_seen_at = now() - interval '4 minutes'
   WHERE event_id = pg_temp.u('e2') AND net_hash = encode(sha256(convert_to(
         (SELECT run_id FROM public.exos_wroom_settings WHERE event_id = pg_temp.u('e2'))::text || ':100.64.0.3', 'UTF8')), 'hex');
  PERFORM pg_temp.as_('service_role');
  ASSERT public.exos_wroom_join_verified(pg_temp.u('e2'), NULL, '{"cf-connecting-ip": "100.64.0.3"}')->>'state' = 'waiting',
    'WR7 idle places free the IPv4 share';
  PERFORM pg_temp.as_('authenticated', pg_temp.u('a1'));
  PERFORM public.exos_wroom_configure(pg_temp.u('e2'), true, NULL, NULL, NULL, NULL, NULL, false);
  PERFORM pg_temp.as_('authenticated', pg_temp.u('a1'));
  j := public.exos_wroom_configure(pg_temp.u('e2'), true, NULL, NULL, NULL, NULL, 0);
  ASSERT j->>'max_entries' IS NULL AND (j->>'cap')::int = 1000, 'WR7 automatic cap (5 x 100, at least 1,000): ' || j::text;
  ASSERT pg_temp.st(format('SELECT public.exos_wroom_configure(%L, true, NULL, NULL, NULL, NULL, 50)', pg_temp.u('e2'))) LIKE '22023%', 'WR7 cap bounds';
  RAISE NOTICE 'OK  WR7 60 new tokens a minute per network and 120 per IPv6 /48 (busy, nothing stored); live places per network fixed without a CAPTCHA (20 per /48, 200 per IPv4, 100 per /32, even at 50,000) and scaled behind Turnstile under a ceiling (200 per /48, 1,000 per IPv4 at 50,000), the anon join refused (challenge) while Turnstile is on, the verified join service-only and reading the passed address; the room cap on the live line (exact recount; idle and expired places free it); known tokens still poll';
END $$;

-- WR8 -----------------------------------------------------------------------
DO $$
DECLARE j jsonb; v_tok text; v_old text; v_kept text; v_carry int; h uuid;
BEGIN
  PERFORM pg_temp.as_('postgres');
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
  ASSERT public.exos_wroom_require(pg_temp.u('e1'), pg_temp.u('c1'), NULL, NULL, 'a@x.com'), 'WR8 off: require passes';
  -- On again: a new run; admitted, unexpired turns carry over, the rest of the line is gone.
  PERFORM pg_temp.as_('postgres');
  SELECT t.token INTO v_old FROM wr_tok t JOIN public.exos_wroom_entries e ON e.token_hash = public._exos_wroom_hash(t.event_id, t.token)
   WHERE e.state = 'waiting' LIMIT 1;
  SELECT t.token INTO v_kept FROM wr_tok t JOIN public.exos_wroom_entries e ON e.token_hash = public._exos_wroom_hash(t.event_id, t.token)
   WHERE e.state = 'admitted' AND e.admit_expires_at > now() AND e.used_at IS NULL LIMIT 1;
  SELECT count(*) INTO v_carry FROM public.exos_wroom_entries
   WHERE event_id = pg_temp.u('e1') AND state = 'admitted' AND admit_expires_at > now();
  PERFORM pg_temp.as_('authenticated', pg_temp.u('a1'));
  j := public.exos_wroom_configure(pg_temp.u('e1'), true, 0, 120, 5, 10);
  ASSERT j->>'phase' = 'live' AND (j->'counts'->>'total')::int = v_carry AND v_carry > 0 AND j->>'closed_at' IS NULL,
    'WR8 new run keeps ' || v_carry || ' admitted: ' || j::text;
  PERFORM pg_temp.as_('anon');
  ASSERT public.exos_wroom_status(pg_temp.u('e1'), v_old)->>'state' = 'unknown', 'WR8 old waiting token unknown';
  ASSERT public.exos_wroom_status(pg_temp.u('e1'), v_kept)->>'state' = 'admitted', 'WR8 an admitted turn survives the re-enable';
  PERFORM pg_temp.as_('postgres');
  ASSERT (SELECT count(*) FROM public.exos_org_audit WHERE action = 'event.waiting_room' AND event_id = pg_temp.u('e1')) = 3, 'WR8 3 audit rows';
  RAISE NOTICE 'OK  WR8 closes when idle and when turned off (no token needed then); on again = a new run, admitted turns kept, the rest gone';
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

-- WR10 ----------------------------------------------------------------------
-- Accounts (x1): five IPv4 addresses fill a 1,000-place guest line; a
-- signed-in buyer still gets a place, outside the cap; a second browser of
-- the account resumes it; only that account can use it.
DO $$
DECLARE j jsonb; i int; v_tok text; v_id uuid; h uuid;
BEGIN
  PERFORM pg_temp.as_('postgres');
  INSERT INTO public.exos_events (id, org_id, name, slug, status, starts_at, timezone, total_tickets, created_by, link_out)
  VALUES (pg_temp.u('e4'), pg_temp.u('1'), 'D71 Accounts', 'd71-accounts', 'published', now() + interval '30 days',
          'America/New_York', 500, pg_temp.u('a1'), false);
  INSERT INTO public.exos_ticket_tiers (id, event_id, name, price, capacity, sales_start, visibility)
  VALUES (pg_temp.u('c41'), pg_temp.u('e4'), 'GA', 20, 100, NULL, 'public');
  PERFORM pg_temp.as_('authenticated', pg_temp.u('a1'));
  j := public.exos_wroom_configure(pg_temp.u('e4'), true, 0, 60, 10, 10);
  ASSERT (j->>'cap')::int = 1000, 'WR10 cap 1,000: ' || j::text;
  PERFORM pg_temp.as_('postgres');
  INSERT INTO public.exos_wroom_entries (org_id, event_id, run_id, token_hash, net_hash, net32_hash, order_key)
  SELECT pg_temp.u('1'), pg_temp.u('e4'), s.run_id, encode(sha256(convert_to('wr10-' || g, 'UTF8')), 'hex'),
         encode(sha256(convert_to(s.run_id::text || ':100.65.0.' || (g % 5), 'UTF8')), 'hex'),
         encode(sha256(convert_to(s.run_id::text || ':100.65.0.' || (g % 5), 'UTF8')), 'hex'), 1 + g
    FROM public.exos_wroom_settings s, generate_series(1, 1000) g WHERE s.event_id = pg_temp.u('e4');
  PERFORM pg_temp.as_('anon', NULL, '100.66.0.1');
  j := public.exos_wroom_join(pg_temp.u('e4'));
  ASSERT j->>'state' = 'full' AND j->>'reason' = 'room', 'WR10 guests full: ' || j::text;
  -- An unconfirmed account counts as a guest.
  PERFORM pg_temp.as_('postgres');
  INSERT INTO auth.users (id, email, email_confirmed_at) VALUES (pg_temp.u('b9'), 'd71-unconfirmed@x.com', NULL);
  PERFORM pg_temp.as_('authenticated', pg_temp.u('b9'), '100.66.0.2');
  ASSERT public.exos_wroom_join(pg_temp.u('e4'))->>'state' = 'full', 'WR10 unconfirmed: guest rules';
  -- A confirmed account made today with no paid order: guest rules too, and
  -- the full page doesn't offer sign-in (signed_in).
  PERFORM pg_temp.as_('postgres');
  INSERT INTO auth.users (id, email, email_confirmed_at, created_at) VALUES (pg_temp.u('b8'), 'd71-new@x.com', now(), now());
  UPDATE auth.users SET created_at = now() - interval '30 days' WHERE id IN (pg_temp.u('b1'), pg_temp.u('b2'));
  PERFORM pg_temp.as_('authenticated', pg_temp.u('b8'), '100.66.0.3');
  j := public.exos_wroom_join(pg_temp.u('e4'));
  ASSERT j->>'state' = 'full' AND j->>'signed_in' = 'true', 'WR10 a new account: guest rules: ' || j::text;
  -- ... until it has paid for an order (any org): then a seat.
  PERFORM pg_temp.as_('postgres');
  ALTER TABLE public.exos_checkout_sessions DISABLE TRIGGER USER;
  INSERT INTO public.exos_checkout_sessions (session_id, event_id, tier_id, org_id, quantity, amount_cents, status, buyer_uid)
  VALUES ('cs_wr10_paid', pg_temp.u('e4'), pg_temp.u('c41'), pg_temp.u('1'), 1, 2000, 'fulfilled', pg_temp.u('b8'));
  ALTER TABLE public.exos_checkout_sessions ENABLE TRIGGER USER;
  PERFORM pg_temp.as_('authenticated', pg_temp.u('b8'), '100.66.0.3');
  j := public.exos_wroom_join(pg_temp.u('e4'));
  ASSERT j->>'state' = 'waiting' AND j->>'kind' = 'account', 'WR10 a paid order: a seat: ' || j::text;
  -- b1 (30 days old) signs in: a place anyway, at the back, outside the cap and the network shares.
  PERFORM pg_temp.as_('authenticated', pg_temp.u('b1'), '100.65.0.1');
  j := public.exos_wroom_join(pg_temp.u('e4'));
  ASSERT j->>'state' = 'waiting' AND j->>'kind' = 'account' AND j->>'token' ~ '^[0-9a-f]{64}$'
     AND (j->>'position')::int = 1002, 'WR10 an account always gets a place: ' || j::text;
  v_tok := j->>'token';
  -- A second browser (no token) resumes the same place; status works without the token.
  j := public.exos_wroom_join(pg_temp.u('e4'));
  ASSERT j->>'state' = 'waiting' AND NOT j ? 'token' AND (j->>'position')::int = 1002, 'WR10 resumed: ' || j::text;
  ASSERT public.exos_wroom_status(pg_temp.u('e4'), NULL)->>'kind' = 'account', 'WR10 status by account';
  PERFORM pg_temp.as_('postgres');
  ASSERT (SELECT count(*) FROM public.exos_wroom_entries WHERE event_id = pg_temp.u('e4') AND kind = 'account') = 2, 'WR10 one per account';
  -- Admitted: only that account can use it, with or without the token.
  UPDATE public.exos_wroom_entries SET state = 'admitted', admitted_at = now(), admit_expires_at = now() + interval '10 minutes'
   WHERE event_id = pg_temp.u('e4') AND kind = 'account'
     AND account_hash = encode(sha256(convert_to(pg_temp.u('e4')::text || ':uid:' || pg_temp.u('b1')::text, 'UTF8')), 'hex')
  RETURNING id INTO v_id;
  PERFORM pg_temp.as_('postgres');
  DELETE FROM public.exos_wroom_entries WHERE event_id = pg_temp.u('e4')
     AND account_hash = encode(sha256(convert_to(pg_temp.u('e4')::text || ':uid:' || pg_temp.u('b8')::text, 'UTF8')), 'hex');
  PERFORM pg_temp.as_('authenticated', pg_temp.u('b2'), '198.51.100.1', v_tok);
  ASSERT pg_temp.st(format('SELECT public.exos_create_hold(%L, %L, 1, 600, NULL)', pg_temp.u('e4'), pg_temp.u('c41'))) LIKE 'XWR01%',
    'WR10 another account with the token';
  PERFORM pg_temp.as_('service_role', NULL, '198.51.100.1', v_tok);
  ASSERT pg_temp.st(format('SELECT public.exos_create_guest_hold(%L, %L, 1, %L, %L, NULL)', pg_temp.u('e4'), pg_temp.u('c41'),
                           'thief@x.com', md5('t1'))) LIKE 'XWR01%', 'WR10 a guest with the token';
  PERFORM pg_temp.as_('authenticated', pg_temp.u('b1'));
  h := public.exos_create_hold(pg_temp.u('e4'), pg_temp.u('c41'), 1, 600, NULL);
  ASSERT h IS NOT NULL, 'WR10 the account, no token needed';
  -- A guest's browser place becomes the account's when they sign in with it.
  PERFORM pg_temp.as_('authenticated', pg_temp.u('a1'));
  PERFORM public.exos_wroom_configure(pg_temp.u('e4'), true, NULL, NULL, NULL, NULL, 1500);
  PERFORM pg_temp.as_('anon', NULL, '100.66.0.9');
  j := public.exos_wroom_join(pg_temp.u('e4'));
  ASSERT j->>'state' = 'waiting' AND j->>'kind' = 'anon', 'WR10 a guest place: ' || j::text;
  v_tok := j->>'token';
  PERFORM pg_temp.as_('authenticated', pg_temp.u('b2'), '100.66.0.9');
  j := public.exos_wroom_join(pg_temp.u('e4'), v_tok);
  ASSERT j->>'kind' = 'account' AND j->>'token' = v_tok, 'WR10 the guest place is the account''s now: ' || j::text;
  RAISE NOTICE 'OK  WR10 accounts (x1, A): guests full; unconfirmed and new unpaid accounts are guests (no sign-in offer); 7+ days or a paid order: one place outside the cap and shares, resumed by a second browser, usable only by that account (token or not); a guest place carries over on sign-in';
END $$;

-- WR11 ----------------------------------------------------------------------
-- The on-sale moment (x5): an early, sold-out or ended public type doesn't
-- switch the room live before the real drop; the organizer's pin wins; a
-- room never closes before anyone waited.
DO $$
DECLARE j jsonb;
BEGIN
  PERFORM pg_temp.as_('postgres');
  INSERT INTO public.exos_events (id, org_id, name, slug, status, starts_at, timezone, total_tickets, created_by, link_out)
  VALUES (pg_temp.u('e5'), pg_temp.u('1'), 'D71 Early Bird', 'd71-early', 'published', now() + interval '30 days',
          'America/New_York', 500, pg_temp.u('a1'), false),
         (pg_temp.u('e6'), pg_temp.u('1'), 'D71 Draft', 'd71-draft-room', 'draft', now() + interval '30 days',
          'America/New_York', 500, pg_temp.u('a1'), false);
  INSERT INTO public.exos_ticket_tiers (id, event_id, name, price, capacity, sold, sales_start, sales_end, visibility) VALUES
    (pg_temp.u('c51'), pg_temp.u('e5'), 'Early bird (sold out)', 10, 50, 50, NULL, NULL, 'public'),
    (pg_temp.u('c52'), pg_temp.u('e5'), 'Teaser (ended)', 10, 50, 0, NULL, now() - interval '1 day', 'public'),
    (pg_temp.u('c53'), pg_temp.u('e5'), 'GA', 20, 400, 0, now() + interval '2 hours', NULL, 'public'),
    (pg_temp.u('c61'), pg_temp.u('e6'), 'GA', 20, 400, 0, NULL, NULL, 'public');
  PERFORM pg_temp.as_('authenticated', pg_temp.u('a1'));
  j := public.exos_wroom_configure(pg_temp.u('e5'), true, 15, 60, 10, 1);
  ASSERT j->>'phase' = 'before' AND (j->>'on_sale_at')::timestamptz = now() + interval '2 hours',
    'WR11 the drop, not the early types: ' || j::text;
  PERFORM pg_temp.as_('anon', NULL, '100.67.0.1');
  ASSERT public.exos_wroom_join(pg_temp.u('e5'))->>'state' = 'before', 'WR11 the first visitor sees "before"';
  PERFORM pg_temp.as_('postgres');
  ASSERT (SELECT closed_at IS NULL FROM public.exos_wroom_settings WHERE event_id = pg_temp.u('e5')), 'WR11 not closed';
  -- The pin wins (e.g. an early type still on sale but the drop is at 18:00).
  PERFORM pg_temp.as_('authenticated', pg_temp.u('a1'));
  j := public.exos_wroom_configure(pg_temp.u('e5'), true, NULL, NULL, NULL, NULL, NULL, NULL, now() + interval '5 minutes');
  ASSERT j->>'phase' = 'lobby' AND (j->>'on_sale_at')::timestamptz = now() + interval '5 minutes'
     AND (j->>'opens_at_pin')::timestamptz = now() + interval '5 minutes', 'WR11 pinned: ' || j::text;
  -- Live with nobody ever waiting: it stays open (idle close needs a wait or an admission first).
  j := public.exos_wroom_configure(pg_temp.u('e5'), true, NULL, NULL, NULL, NULL, NULL, NULL, now() - interval '2 hours');
  ASSERT j->>'phase' = 'live', 'WR11 live: ' || j::text;
  PERFORM pg_temp.as_('postgres');
  UPDATE public.exos_wroom_settings SET advanced_at = now() - interval '1 hour' WHERE event_id = pg_temp.u('e5');
  PERFORM pg_temp.as_('anon', NULL, '100.67.0.2');
  j := public.exos_wroom_join(pg_temp.u('e5'));
  ASSERT j->>'state' = 'waiting', 'WR11 the first visitor gets a place, the room stays: ' || j::text;
  PERFORM pg_temp.as_('authenticated', pg_temp.u('a1'));
  j := public.exos_wroom_configure(pg_temp.u('e5'), true, NULL, NULL, NULL, NULL, NULL, NULL, NULL, true);
  ASSERT j->>'opens_at_pin' IS NULL, 'WR11 pin cleared';
  -- An unpublished event: no room, whatever the setting.
  PERFORM public.exos_wroom_configure(pg_temp.u('e6'), true, 0, 60, 10, 10);
  PERFORM pg_temp.as_('anon', NULL, '100.67.0.3');
  ASSERT public.exos_wroom_join(pg_temp.u('e6')) = '{"state": "off"}'::jsonb
     AND public.exos_wroom_status(pg_temp.u('e6'), repeat('a', 64)) = '{"state": "off"}'::jsonb, 'WR11 draft: off';
  RAISE NOTICE 'OK  WR11 on-sale (x5): sold-out / ended early types ignored, the pin wins and clears, never idle-closed before a wait, drafts off';
END $$;

-- WR12 ----------------------------------------------------------------------
-- One turn, one order: one open checkout per turn (attach), a failed one
-- released (bound or not: N5); the same buyer again takes over its earlier
-- Stripe session (B); a failed / expired session frees the attachment but
-- stays mapped, so a late fulfilment still spends the turn (G); a bind
-- without the attachment is false (G).
DO $$
DECLARE j jsonb; v_tok text; a1 uuid := gen_random_uuid(); a2 uuid := gen_random_uuid(); a3 uuid := gen_random_uuid();
        v_id uuid; e record;
BEGIN
  PERFORM pg_temp.as_('anon', NULL, '100.68.0.1');
  v_tok := public.exos_wroom_join(pg_temp.u('e4'))->>'token';
  PERFORM pg_temp.as_('postgres');
  UPDATE public.exos_wroom_entries SET state = 'admitted', admitted_at = now(), admit_expires_at = now() + interval '10 minutes'
   WHERE token_hash = public._exos_wroom_hash(pg_temp.u('e4'), v_tok) RETURNING id INTO v_id;
  ALTER TABLE public.exos_checkout_sessions DISABLE TRIGGER USER;
  ALTER TABLE public.exos_checkout_sessions ENABLE TRIGGER exos_checkout_sessions_wroom;
  PERFORM pg_temp.as_('service_role');
  ASSERT public.exos_wroom_attach(pg_temp.u('e4'), pg_temp.u('c41'), v_tok, NULL, 'buyer@x.com', a1) = '{"attached": true}', 'WR12 attach';
  ASSERT pg_temp.st(format('SELECT public.exos_wroom_attach(%L, %L, %L, NULL, %L, %L)', pg_temp.u('e4'), pg_temp.u('c41'), v_tok,
                           'buyer@x.com', a2)) LIKE 'XWR02%', 'WR12 a second checkout in flight (no session yet): XWR02';
  PERFORM public.exos_wroom_release(pg_temp.u('e4'), a1);
  ASSERT public.exos_wroom_attach(pg_temp.u('e4'), pg_temp.u('c41'), v_tok, NULL, 'buyer@x.com', a2)->>'attached' = 'true', 'WR12 released: another try';
  ASSERT public.exos_wroom_bind(pg_temp.u('e4'), a2, 'cs_wr12_a', NULL, 'buyer@x.com'), 'WR12 bound';
  ASSERT NOT public.exos_wroom_bind(pg_temp.u('e4'), a1, 'cs_wr12_x', NULL, 'buyer@x.com'), 'WR12 a stale attempt can''t bind';
  -- B: the same buyer starts again: take over the earlier Stripe session.
  j := public.exos_wroom_attach(pg_temp.u('e4'), pg_temp.u('c41'), v_tok, NULL, 'Buyer@x.com ', a3);
  ASSERT j = '{"takeover": "cs_wr12_a"}', 'WR12 same buyer: take over: ' || j::text;
  -- (exos-checkout expired it at Stripe and marks its row expired:) the turn is free; the session stays mapped.
  PERFORM pg_temp.as_('postgres');
  INSERT INTO public.exos_checkout_sessions (session_id, event_id, tier_id, org_id, quantity, amount_cents, status, buyer_email, guest)
  VALUES ('cs_wr12_a', pg_temp.u('e4'), pg_temp.u('c41'), pg_temp.u('1'), 1, 2000, 'pending', 'buyer@x.com', true);
  UPDATE public.exos_checkout_sessions SET status = 'expired' WHERE session_id = 'cs_wr12_a';
  SELECT * INTO e FROM public.exos_wroom_entries WHERE id = v_id;
  ASSERT e.checkout_ref IS NULL AND e.session_id = 'cs_wr12_a' AND e.state = 'admitted', 'WR12 expired: attachment freed, session kept';
  PERFORM pg_temp.as_('service_role');
  ASSERT public.exos_wroom_attach(pg_temp.u('e4'), pg_temp.u('c41'), v_tok, NULL, 'buyer@x.com', a3)->>'attached' = 'true', 'WR12 attach after the take-over';
  ASSERT public.exos_wroom_bind(pg_temp.u('e4'), a3, 'cs_wr12_b', NULL, 'buyer@x.com'), 'WR12 bound again';
  -- N5: a failure after the bind releases it, session and all.
  PERFORM public.exos_wroom_release(pg_temp.u('e4'), a3);
  PERFORM pg_temp.as_('postgres');
  SELECT * INTO e FROM public.exos_wroom_entries WHERE id = v_id;
  ASSERT e.checkout_ref IS NULL AND e.session_id IS NULL, 'WR12 release clears the bound session';
  -- A different buyer is never a take-over (XWR01: the turn is bound to the first buyer).
  PERFORM pg_temp.as_('service_role');
  ASSERT pg_temp.st(format('SELECT public.exos_wroom_attach(%L, %L, %L, NULL, %L, %L)', pg_temp.u('e4'), pg_temp.u('c41'), v_tok,
                           'other@x.com', gen_random_uuid())) LIKE 'XWR01%', 'WR12 another buyer';
  -- A non-Stripe open session (PayPal, gift card): XWR02, no take-over.
  ASSERT public.exos_wroom_attach(pg_temp.u('e4'), pg_temp.u('c41'), v_tok, NULL, 'buyer@x.com', a1)->>'attached' = 'true', 'WR12 attach (PayPal)';
  ASSERT public.exos_wroom_bind(pg_temp.u('e4'), a1, 'pp_wr12_c', NULL, 'buyer@x.com'), 'WR12 bound (PayPal)';
  ASSERT pg_temp.st(format('SELECT public.exos_wroom_attach(%L, %L, %L, NULL, %L, %L)', pg_temp.u('e4'), pg_temp.u('c41'), v_tok,
                           'buyer@x.com', gen_random_uuid())) LIKE 'XWR02%', 'WR12 a non-Stripe session: XWR02';
  -- G: the expired Stripe session is fulfilled after all (it was paying): the turn is spent.
  PERFORM pg_temp.as_('postgres');
  UPDATE public.exos_checkout_sessions SET status = 'fulfilled' WHERE session_id = 'cs_wr12_a';
  ASSERT (SELECT state = 'spent' AND spent_at IS NOT NULL FROM public.exos_wroom_entries WHERE id = v_id), 'WR12 late fulfilment: spent';
  ALTER TABLE public.exos_checkout_sessions ENABLE TRIGGER USER;
  PERFORM pg_temp.as_('service_role');
  ASSERT pg_temp.st(format('SELECT public.exos_wroom_require(%L, %L, %L, NULL, %L)', pg_temp.u('e4'), pg_temp.u('c41'), v_tok,
                           'buyer@x.com')) LIKE 'XWR03%', 'WR12 used: XWR03';
  ASSERT pg_temp.st(format('SELECT public.exos_wroom_attach(%L, %L, %L, NULL, %L, %L)', pg_temp.u('e4'), pg_temp.u('c41'), v_tok,
                           'buyer@x.com', gen_random_uuid())) LIKE 'XWR03%', 'WR12 used: attach XWR03';
  -- The attach refuses another buyer on a bound turn too.
  PERFORM pg_temp.as_('anon', NULL, '100.68.0.2');
  v_tok := public.exos_wroom_join(pg_temp.u('e4'))->>'token';
  PERFORM pg_temp.as_('postgres');
  UPDATE public.exos_wroom_entries SET state = 'admitted', admitted_at = now(), admit_expires_at = now() + interval '10 minutes',
         redeemer_hash = public._exos_wroom_buyer_hash(pg_temp.u('e4'), 'email:first@x.com')
   WHERE token_hash = public._exos_wroom_hash(pg_temp.u('e4'), v_tok);
  PERFORM pg_temp.as_('service_role');
  ASSERT pg_temp.st(format('SELECT public.exos_wroom_attach(%L, %L, %L, NULL, %L, %L)', pg_temp.u('e4'), pg_temp.u('c41'), v_tok,
                           'second@x.com', gen_random_uuid())) LIKE 'XWR01%', 'WR12 another buyer can''t attach';
  -- An account's used place: its next join is a new place at the back.
  PERFORM pg_temp.as_('postgres');
  UPDATE public.exos_wroom_entries SET state = 'spent', spent_at = now()
   WHERE event_id = pg_temp.u('e4') AND kind = 'account' AND redeemer_hash = public._exos_wroom_buyer_hash(pg_temp.u('e4'), 'uid:' || pg_temp.u('b1'));
  PERFORM pg_temp.as_('authenticated', pg_temp.u('b1'), '100.65.0.1');
  j := public.exos_wroom_join(pg_temp.u('e4'));
  ASSERT j->>'state' = 'waiting' AND j->>'token' ~ '^[0-9a-f]{64}$' AND j->>'kind' = 'account', 'WR12 account rejoins at the back: ' || j::text;
  RAISE NOTICE 'OK  WR12 one turn, one order: one open checkout (XWR02), release (bound too), stale bind false, the same buyer takes over its Stripe session (B), not another buyer or a non-Stripe session, expired frees but stays mapped and a late fulfilment spends (G, XWR03), an account re-places';
END $$;

-- WR13 ----------------------------------------------------------------------
-- Polls (should-fix 4): positions count at most 10,000 ahead ("10,000+"); a
-- poll within 5 s of the last write gets the cached view with no write.
DO $$
DECLARE j jsonb; j2 jsonb; v_tok text; v_seen timestamptz;
BEGIN
  PERFORM pg_temp.as_('postgres');
  INSERT INTO public.exos_wroom_entries (org_id, event_id, run_id, token_hash, net_hash, net32_hash, order_key)
  SELECT pg_temp.u('1'), pg_temp.u('e4'), s.run_id, encode(sha256(convert_to('wr13-' || g, 'UTF8')), 'hex'),
         encode(sha256(convert_to('wr13n-' || g, 'UTF8')), 'hex'), encode(sha256(convert_to('wr13m-' || g, 'UTF8')), 'hex'), 0.5
    FROM public.exos_wroom_settings s, generate_series(1, 10050) g WHERE s.event_id = pg_temp.u('e4');
  UPDATE public.exos_wroom_settings SET max_entries = 1000000, advanced_at = now() WHERE event_id = pg_temp.u('e4');
  PERFORM pg_temp.as_('anon', NULL, '100.69.0.1');
  j := public.exos_wroom_join(pg_temp.u('e4'));
  v_tok := j->>'token';
  PERFORM pg_temp.as_('postgres');
  UPDATE public.exos_wroom_entries SET last_seen_at = now() - interval '30 seconds', view_at = NULL
   WHERE token_hash = public._exos_wroom_hash(pg_temp.u('e4'), v_tok);
  PERFORM pg_temp.as_('anon', NULL, '100.69.0.1');
  j := public.exos_wroom_status(pg_temp.u('e4'), v_tok);
  ASSERT (j->>'position_capped')::boolean AND (j->>'position')::int = 10001, 'WR13 10,000+: ' || (j - 'token')::text;
  PERFORM pg_temp.as_('postgres');
  SELECT last_seen_at INTO v_seen FROM public.exos_wroom_entries WHERE token_hash = public._exos_wroom_hash(pg_temp.u('e4'), v_tok);
  ASSERT v_seen = now(), 'WR13 the first poll wrote last_seen';
  UPDATE public.exos_wroom_entries SET view_cache = view_cache || '{"cached": true}' WHERE token_hash = public._exos_wroom_hash(pg_temp.u('e4'), v_tok);
  PERFORM pg_temp.as_('anon', NULL, '100.69.0.1');
  j2 := public.exos_wroom_status(pg_temp.u('e4'), v_tok);
  ASSERT j2->>'cached' = 'true', 'WR13 a poll within 5 s: the cached view';
  RAISE NOTICE 'OK  WR13 positions capped at 10,000+ (LIMIT 10001); a poll within 5 s gets the cached view (no write)';
END $$;

-- WR14 ----------------------------------------------------------------------
-- The two other inventory paths (should-fix 7): phone RSVP verify and the
-- referral reward refuse without a turn; both carry the gate first.
DO $$
DECLARE v_rsvp uuid := gen_random_uuid(); v_err text; v_v uuid := gen_random_uuid(); v_rw uuid := gen_random_uuid();
BEGIN
  PERFORM pg_temp.as_('postgres');
  INSERT INTO public.exos_phone_rsvps (id, org_id, event_id, tier_id, guest_name, phone, channel, code_hash, code_expires_at)
  VALUES (v_rsvp, pg_temp.u('1'), pg_temp.u('e4'), pg_temp.u('c41'), 'Guest', '+15555550123', 'sms', repeat('a', 64), now() + interval '10 minutes');
  PERFORM pg_temp.as_('service_role', NULL, '198.51.100.1', NULL);
  v_err := pg_temp.st(format('SELECT public.exos_phone_rsvp_verify(%L, %L, %L)', v_rsvp, '123456', 'https://x.test'));
  ASSERT v_err LIKE 'XWR01%', 'WR14 phone RSVP without a turn: ' || v_err;
  PERFORM pg_temp.as_('postgres');
  SET LOCAL session_replication_role = replica;
  INSERT INTO public.exos_vouchers (id, event_id, code, price_override) VALUES (v_v, pg_temp.u('e4'), 'WR14REWARD', 0);
  INSERT INTO public.exos_referral_rewards (id, referral_code, user_id, event_id, milestone, threshold, reward_event_id, voucher_id)
  VALUES (v_rw, 'wr14code', pg_temp.u('b2'), pg_temp.u('e4'), 1, 1, pg_temp.u('e4'), v_v);
  SET LOCAL session_replication_role = origin;
  PERFORM pg_temp.as_('authenticated', pg_temp.u('b4'));
  v_err := pg_temp.st(format('SELECT public.exos_redeem_referral_reward(%L, %L)', v_rw, pg_temp.u('c41')));
  ASSERT v_err LIKE 'XWR01%', 'WR14 referral reward without a turn: ' || v_err;
  RAISE NOTICE 'OK  WR14 phone RSVP verify and the referral reward are gated first (XWR01 without a turn)';
END $$;

-- WR15 ----------------------------------------------------------------------
-- C: a phone RSVP with a turn: a wrong code spends (and binds) nothing; the
-- right code confirms it and spends the turn ('rsvp:<id>'); a used code
-- answers as before.
DO $$
DECLARE v_rsvp uuid := gen_random_uuid(); j jsonb; v_tok text; v_id uuid; e record;
BEGIN
  PERFORM pg_temp.as_('postgres');
  INSERT INTO public.exos_ticket_tiers (id, event_id, name, price, capacity, sales_start, visibility)
  VALUES (pg_temp.u('c42'), pg_temp.u('e4'), 'Free RSVP', 0, 100, NULL, 'public');
  INSERT INTO public.exos_phone_rsvp_settings (event_id, org_id, enabled, tier_id) VALUES (pg_temp.u('e4'), pg_temp.u('1'), true, pg_temp.u('c42'));
  INSERT INTO public.exos_phone_rsvps (id, org_id, event_id, tier_id, guest_name, phone, channel, code_hash, code_expires_at)
  VALUES (v_rsvp, pg_temp.u('1'), pg_temp.u('e4'), pg_temp.u('c42'), 'Guest', '+15555550124', 'sms',
          encode(extensions.digest(v_rsvp::text || ':246810', 'sha256'), 'hex'), now() + interval '10 minutes');
  PERFORM pg_temp.as_('anon', NULL, '100.70.0.1');
  v_tok := public.exos_wroom_join(pg_temp.u('e4'))->>'token';
  PERFORM pg_temp.as_('postgres');
  UPDATE public.exos_wroom_entries SET state = 'admitted', admitted_at = now(), admit_expires_at = now() + interval '10 minutes'
   WHERE token_hash = public._exos_wroom_hash(pg_temp.u('e4'), v_tok) RETURNING id INTO v_id;
  PERFORM pg_temp.as_('service_role', NULL, '198.51.100.1', v_tok);
  j := public.exos_phone_rsvp_verify(v_rsvp, '111111', 'https://x.test');
  ASSERT j->>'error' = 'wrong_code', 'WR15 wrong code: ' || j::text;
  PERFORM pg_temp.as_('postgres');
  SELECT * INTO e FROM public.exos_wroom_entries WHERE id = v_id;
  ASSERT e.state = 'admitted' AND e.used_at IS NULL AND e.redeemer_hash IS NULL, 'WR15 a wrong code costs nothing';
  PERFORM pg_temp.as_('service_role', NULL, '198.51.100.1', v_tok);
  j := public.exos_phone_rsvp_verify(v_rsvp, '246810', 'https://x.test');
  ASSERT (j->>'ok')::boolean, 'WR15 right code: ' || j::text;
  PERFORM pg_temp.as_('postgres');
  SELECT * INTO e FROM public.exos_wroom_entries WHERE id = v_id;
  ASSERT e.state = 'spent' AND e.spent_ref = 'rsvp:' || v_rsvp
     AND e.redeemer_hash = public._exos_wroom_buyer_hash(pg_temp.u('e4'), 'phone:+15555550124'), 'WR15 confirmed: spent';
  PERFORM pg_temp.as_('service_role', NULL, '198.51.100.1', v_tok);
  ASSERT public.exos_phone_rsvp_verify(v_rsvp, '246810', 'https://x.test')->>'error' = 'used', 'WR15 used code: as before';
  RAISE NOTICE 'OK  WR15 phone RSVP (C): a wrong code spends and binds nothing; the right one confirms and spends the turn; a used code answers as before';
END $$;

-- WR16 ----------------------------------------------------------------------
-- E: a join that finds a place answers like a poll (cached 5 s, 30 a minute
-- per place). H: one turn per account: a signed-in buyer's own place is the
-- turn, another browser token never stands in or gets keyed on the account.
-- I: a retried free claim with the same order_ref gets the same tickets.
DO $$
DECLARE j jsonb; v_tok text; v_tok2 text; v_id uuid; v_n int; t1 uuid[]; t2 uuid[]; h uuid;
BEGIN
  -- E
  PERFORM pg_temp.as_('anon', NULL, '100.71.0.1');
  v_tok := public.exos_wroom_join(pg_temp.u('e4'))->>'token';
  PERFORM pg_temp.as_('postgres');
  UPDATE public.exos_wroom_entries SET view_cache = '{"state": "waiting", "cached": true}', view_at = now()
   WHERE token_hash = public._exos_wroom_hash(pg_temp.u('e4'), v_tok) RETURNING id INTO v_id;
  PERFORM pg_temp.as_('anon', NULL, '100.71.0.1');
  j := public.exos_wroom_join(pg_temp.u('e4'), v_tok);
  ASSERT j->>'cached' = 'true' AND j->>'token' = v_tok, 'WR16 join within 5 s: the cached view: ' || j::text;
  v_n := 0;
  LOOP
    v_n := v_n + 1;
    EXIT WHEN v_n > 40;
    PERFORM pg_temp.as_('postgres');
    UPDATE public.exos_wroom_entries SET view_at = NULL, view_cache = NULL WHERE id = v_id;
    PERFORM pg_temp.as_('anon', NULL, '100.71.0.1');
    j := public.exos_wroom_join(pg_temp.u('e4'), v_tok);
    EXIT WHEN j->>'state' = 'busy';
  END LOOP;
  ASSERT j->>'state' = 'busy' AND v_n BETWEEN 29 AND 31, 'WR16 joins on a place: 30 a minute: ' || v_n || ' ' || j::text;
  -- H: b2 has its own place (WR10). Another browser's admitted guest token:
  PERFORM pg_temp.as_('anon', NULL, '100.71.0.2');
  v_tok2 := public.exos_wroom_join(pg_temp.u('e4'))->>'token';
  PERFORM pg_temp.as_('postgres');
  UPDATE public.exos_wroom_entries SET state = 'admitted', admitted_at = now(), admit_expires_at = now() + interval '10 minutes'
   WHERE token_hash = public._exos_wroom_hash(pg_temp.u('e4'), v_tok2) RETURNING id INTO v_id;
  UPDATE public.exos_wroom_entries SET state = 'waiting', admitted_at = NULL, admit_expires_at = NULL, used_at = NULL,
         last_seen_at = now(), view_at = NULL
   WHERE event_id = pg_temp.u('e4')
     AND account_hash = encode(sha256(convert_to(pg_temp.u('e4')::text || ':uid:' || pg_temp.u('b2')::text, 'UTF8')), 'hex');
  PERFORM pg_temp.as_('authenticated', pg_temp.u('b2'), '198.51.100.1', v_tok2);
  ASSERT pg_temp.st(format('SELECT public.exos_create_hold(%L, %L, 1, 600, NULL)', pg_temp.u('e4'), pg_temp.u('c41'))) LIKE 'XWR01%',
    'WR16 the account''s own (waiting) place is its turn, not another token';
  j := public.exos_wroom_join(pg_temp.u('e4'), v_tok2);
  ASSERT j->>'kind' = 'account' AND j->>'state' = 'waiting', 'WR16 a join resumes the account''s place: ' || j::text;
  PERFORM pg_temp.as_('postgres');
  ASSERT (SELECT account_hash IS NULL AND used_at IS NULL FROM public.exos_wroom_entries WHERE id = v_id),
    'WR16 the other token is not keyed on the account';
  -- An account with no place uses an admitted guest token: it becomes the account's one place.
  PERFORM pg_temp.as_('authenticated', pg_temp.u('b4'), '198.51.100.1', v_tok2);
  h := public.exos_create_hold(pg_temp.u('e4'), pg_temp.u('c41'), 1, 600, NULL);
  ASSERT h IS NOT NULL, 'WR16 b4 holds with the guest turn';
  PERFORM pg_temp.as_('postgres');
  ASSERT (SELECT account_hash = encode(sha256(convert_to(pg_temp.u('e4')::text || ':uid:' || pg_temp.u('b4')::text, 'UTF8')), 'hex')
            FROM public.exos_wroom_entries WHERE id = v_id), 'WR16 keyed on b4 now';
  PERFORM pg_temp.as_('authenticated', pg_temp.u('b4'), '100.71.0.3');
  ASSERT public.exos_wroom_status(pg_temp.u('e4'), NULL)->>'state' = 'admitted', 'WR16 b4''s place, by account';
  -- I: the same free claim twice (a retry): the same tickets, not XWR03.
  PERFORM pg_temp.as_('authenticated', pg_temp.u('b4'), '198.51.100.1', NULL);
  t1 := public.exos_claim_free_tickets(pg_temp.u('e4'), pg_temp.u('c42'), 1, NULL, NULL, 'wr16-claim');
  t2 := public.exos_claim_free_tickets(pg_temp.u('e4'), pg_temp.u('c42'), 1, NULL, NULL, 'wr16-claim');
  ASSERT cardinality(t1) = 1 AND t1 = t2, 'WR16 a retried claim: the same tickets';
  ASSERT pg_temp.st(format('SELECT public.exos_claim_free_tickets(%L, %L, 1, NULL, NULL, %L)', pg_temp.u('e4'), pg_temp.u('c42'),
                           'wr16-other')) LIKE 'XWR03%', 'WR16 another claim: XWR03';
  RAISE NOTICE 'OK  WR16 a join on a place: 5 s cache, 30 a minute (E); one turn per account: its own place first, another token never keyed on it, an admitted guest token used by a placeless account becomes its place (H); a retried claim gets the same tickets (I)';
END $$;

-- WR17 ----------------------------------------------------------------------
-- K: a public type on sale now with no pin: configure warns (live at once).
DO $$
DECLARE j jsonb;
BEGIN
  PERFORM pg_temp.as_('authenticated', pg_temp.u('a1'));
  j := public.exos_wroom_summary(pg_temp.u('e4'));
  ASSERT j->'warnings'->0->>'code' = 'live_now', 'WR17 live at once: ' || (j->'warnings')::text;
  j := public.exos_wroom_configure(pg_temp.u('e4'), true, NULL, NULL, NULL, NULL, NULL, NULL, now() + interval '1 hour');
  ASSERT j->'warnings' = '[]'::jsonb, 'WR17 pinned: no warning: ' || (j->'warnings')::text;
  j := public.exos_wroom_summary(pg_temp.u('e5'));
  ASSERT j->'warnings' = '[]'::jsonb, 'WR17 the drop has a sales start: no warning';
  RAISE NOTICE 'OK  WR17 configure / summary warn when a public type on sale now makes the line live at once; a pin clears it';
END $$;

ROLLBACK;
