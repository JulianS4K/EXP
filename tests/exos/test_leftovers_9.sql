-- ============================================================================
-- Wave-9 leftovers (mig 20261110120000, claude/exos-leftovers-9).
-- Self-contained (lo9… ids), rolled back.
--   LO0 shape: the new internal functions are service-role only, the audit
--       summary is authenticated (never anon), search_path pinned, every
--       marker in place and the earlier ones kept
--   LO1 partner reservations: required questions are required at reserve
--       (EXQRQ, the missing ones in DETAIL, nothing held), "show only if"
--       conditions apply, an invalid answer is 22023, a hidden question is
--       not asked of partners, another org's question names nothing; the
--       answers are stored like online ones (po:<id>, source api) and attach
--       to the n-th ticket minted at complete, in the reservation's order;
--       comps the same
--   LO2 organizer reservations: never required, hidden questions included,
--       /build checks without storing; complete-time answers (partners'
--       through _exos_partner_reservation_answers) kept once; the partner's
--       questions list; cross-org / cross-partner refusals
--   LO3 POST /v1/tickets/:id/undo-check-in with an add-on pass id: the door's
--       rules for the key's creator (own scan within 10 minutes, else owner /
--       manager; a reason), another org's pass not found, tickets unchanged
--   LO4 the event report's "N changes since publish": counts after the latest
--       publish, exports left out, republish resets; owner / manager /
--       finance / admin only (scanner, content, another org, nobody: 42501)
-- Users: oa owner A, ma manager A, fa finance A, ca content A, sa / sb
--        scanners A, ob owner B.
-- ============================================================================
\set ON_ERROR_STOP on
BEGIN;

CREATE FUNCTION pg_temp.u(p text) RETURNS uuid LANGUAGE sql IMMUTABLE AS $$
  SELECT md5('lo9:' || p)::uuid
$$;
CREATE FUNCTION pg_temp.act(p_uid uuid) RETURNS void LANGUAGE sql AS $$
  SELECT set_config('app.uid', coalesce(p_uid::text, ''), true), set_config('app.jwt', '{"email":"lo9@x.com"}', true);
$$;
-- 'ok', or SQLSTATE message [hint] {detail}.
CREATE FUNCTION pg_temp.st(p_sql text) RETURNS text LANGUAGE plpgsql AS $$
DECLARE v_hint text; v_detail text;
BEGIN
  EXECUTE p_sql;
  RETURN 'ok';
EXCEPTION WHEN OTHERS THEN
  GET STACKED DIAGNOSTICS v_hint = PG_EXCEPTION_HINT, v_detail = PG_EXCEPTION_DETAIL;
  RETURN SQLSTATE || ' ' || SQLERRM || ' [' || coalesce(v_hint, '') || '] {' || coalesce(v_detail, '') || '}';
END $$;
-- A reservation through _exos_partner_reserve: partner p1 (or another), or the organizer's key.
CREATE FUNCTION pg_temp.reserve(p_lines jsonb, p_answers jsonb DEFAULT NULL, p_partner text DEFAULT 'p1',
                                p_event text DEFAULT 'e1', p_dry boolean DEFAULT false, p_comp boolean DEFAULT false)
RETURNS jsonb LANGUAGE sql AS $$
  SELECT public._exos_partner_reserve(pg_temp.u('A'), pg_temp.u(p_event),
    CASE WHEN p_partner = 'org' THEN NULL ELSE pg_temp.u(p_partner) END,
    CASE WHEN p_partner = 'org' THEN pg_temp.u('kbox') END, p_lines,
    CASE WHEN p_answers IS NULL THEN '{}'::jsonb ELSE jsonb_build_object('answers', p_answers) END, p_comp, p_dry)
$$;
CREATE FUNCTION pg_temp.complete(p_token text, p_partner text DEFAULT 'p1') RETURNS jsonb LANGUAGE sql AS $$
  SELECT public._exos_partner_reservation_complete(pg_temp.u('A'), CASE WHEN p_partner = 'org' THEN NULL ELSE pg_temp.u(p_partner) END,
                                                   p_token, NULL, 'https://exos.test')
$$;
CREATE FUNCTION pg_temp.line(p_tier text, p_qty int) RETURNS jsonb LANGUAGE sql IMMUTABLE AS $$
  SELECT jsonb_build_object('ticket_type_id', pg_temp.u(p_tier), 'quantity', p_qty)
$$;
CREATE TEMP TABLE lo9q (k text PRIMARY KEY, v text) ON COMMIT DROP;
CREATE FUNCTION pg_temp.q(p_key text) RETURNS text LANGUAGE sql AS $$ SELECT v FROM lo9q WHERE k = p_key $$;
CREATE FUNCTION pg_temp.acode(p_pass uuid) RETURNS text LANGUAGE sql AS $$
  SELECT 'A-' || p.id || ':' || p.owner_id || ':' || b || ':' || public._exos_door_code_mac(p.id, p.owner_id, b, p.barcode_secret)
    FROM public.exos_addon_passes p, (SELECT floor(extract(epoch FROM now()) * 1000 / 30000)::bigint AS b) x
   WHERE p.id = p_pass
$$;
CREATE FUNCTION pg_temp.pass(p_line text, p_unit int DEFAULT 1) RETURNS uuid LANGUAGE sql AS $$
  SELECT id FROM public.exos_addon_passes WHERE order_addon_id = pg_temp.u(p_line) AND unit_index = p_unit
$$;
-- exos_api_write runs as the key's creator (in the harness, auth.uid() is app.uid).
CREATE FUNCTION pg_temp.api(p_key text, p_as text, p_action text, p_target uuid, p_args jsonb) RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE r jsonb;
BEGIN
  PERFORM pg_temp.act(pg_temp.u(p_as));
  r := public.exos_api_write(pg_temp.u(p_key), p_action, p_target::text, p_args, NULL);
  PERFORM pg_temp.act(NULL);
  RETURN r;
END $$;
INSERT INTO auth.users (id, email, email_confirmed_at) VALUES
  (pg_temp.u('oa'), 'lo9-oa@x.com', now()), (pg_temp.u('ma'), 'lo9-ma@x.com', now()),
  (pg_temp.u('fa'), 'lo9-fa@x.com', now()), (pg_temp.u('ca'), 'lo9-ca@x.com', now()),
  (pg_temp.u('sa'), 'lo9-sa@x.com', now()), (pg_temp.u('sb'), 'lo9-sb@x.com', now()),
  (pg_temp.u('ob'), 'lo9-ob@x.com', now()), (pg_temp.u('b1'), 'lo9-b1@x.com', now());
INSERT INTO public.exos_orgs (id, name, slug, owner_uid) VALUES
  (pg_temp.u('A'), 'LO9 Hall', 'lo9-hall', pg_temp.u('oa')),
  (pg_temp.u('B'), 'LO9 Other', 'lo9-other', pg_temp.u('ob'));
INSERT INTO public.exos_org_memberships (org_id, user_id, role) VALUES
  (pg_temp.u('A'), pg_temp.u('oa'), 'owner'), (pg_temp.u('A'), pg_temp.u('ma'), 'manager'),
  (pg_temp.u('A'), pg_temp.u('fa'), 'finance'), (pg_temp.u('A'), pg_temp.u('ca'), 'content'),
  (pg_temp.u('A'), pg_temp.u('sa'), 'scanner'), (pg_temp.u('A'), pg_temp.u('sb'), 'scanner'),
  (pg_temp.u('B'), pg_temp.u('ob'), 'owner');
-- e1: questions (required + conditional + hidden). e2: one optional question. e3: draft, no
-- questions (the audit summary). e9: org B (a question of its own).
INSERT INTO public.exos_events (id, org_id, name, slug, status, starts_at, doors_at, total_tickets, tickets_sold, currency, created_by) VALUES
  (pg_temp.u('e1'), pg_temp.u('A'), 'LO9 Night', 'lo9-night', 'published', now() + interval '1 hour', now() - interval '1 hour', 0, 0, 'usd', pg_temp.u('oa')),
  (pg_temp.u('e2'), pg_temp.u('A'), 'LO9 Matinee', 'lo9-matinee', 'published', now() + interval '3 days', NULL, 0, 0, 'usd', pg_temp.u('oa')),
  (pg_temp.u('e3'), pg_temp.u('A'), 'LO9 Draft', 'lo9-draft', 'draft', now() + interval '9 days', NULL, 0, 0, 'usd', pg_temp.u('oa')),
  (pg_temp.u('e9'), pg_temp.u('B'), 'LO9 Elsewhere', 'lo9-else', 'published', now() + interval '3 days', NULL, 0, 0, 'usd', pg_temp.u('ob'));
INSERT INTO public.exos_ticket_tiers (id, event_id, name, price, capacity, sold, visibility, sort_order) VALUES
  (pg_temp.u('ga'), pg_temp.u('e1'), 'GA', 20, 100, 0, 'public', 1),
  (pg_temp.u('vip'), pg_temp.u('e1'), 'VIP', 50, 100, 0, 'public', 2),
  (pg_temp.u('m1'), pg_temp.u('e2'), 'Matinee', 15, 100, 0, 'public', 1),
  (pg_temp.u('d1'), pg_temp.u('e3'), 'Draft GA', 15, 100, 0, 'public', 1),
  (pg_temp.u('t9'), pg_temp.u('e9'), 'B GA', 20, 100, 0, 'public', 1);
INSERT INTO public.exos_tier_distribution (tier_id, event_id, org_id, enabled)
SELECT t.id, t.event_id, e.org_id, true FROM public.exos_ticket_tiers t JOIN public.exos_events e ON e.id = t.event_id
 WHERE t.id IN (pg_temp.u('ga'), pg_temp.u('vip'), pg_temp.u('m1'), pg_temp.u('t9'));
-- Partners: p1 and p2 (org A; p1 may comp), p9 (org B). Org A's box-office API key (the owner's).
INSERT INTO public.exos_distribution_partners (id, org_id, label, partner_type, key_prefix, key_hash, scopes) VALUES
  (pg_temp.u('p1'), pg_temp.u('A'), 'LO9 StubHub', 'stubhub', 'dk_live_lo9aaaa1', repeat('a1', 32), ARRAY['inventory', 'comps']),
  (pg_temp.u('p2'), pg_temp.u('A'), 'LO9 Vivid', 'vivid', 'dk_live_lo9aaaa2', repeat('a2', 32), ARRAY['inventory']),
  (pg_temp.u('p9'), pg_temp.u('B'), 'LO9 B', 'vivid', 'dk_live_lo9bbbb9', repeat('b9', 32), ARRAY['inventory']);
INSERT INTO public.exos_api_keys (id, org_id, name, key_prefix, key_hash, scopes, created_by) VALUES
  (pg_temp.u('kbox'), pg_temp.u('A'), 'Box office', 'sk_live_lo9box', 'lo9hashbox', ARRAY['tickets:write'], pg_temp.u('oa')),
  (pg_temp.u('ko'), pg_temp.u('A'), 'owner door', 'sk_live_lo9o', 'lo9hasho', ARRAY['checkin:write'], pg_temp.u('oa')),
  (pg_temp.u('ksa'), pg_temp.u('A'), 'sa door', 'sk_live_lo9sa', 'lo9hashsa', ARRAY['checkin:write'], pg_temp.u('sa')),
  (pg_temp.u('ksb'), pg_temp.u('A'), 'sb door', 'sk_live_lo9sb', 'lo9hashsb', ARRAY['checkin:write'], pg_temp.u('sb')),
  (pg_temp.u('kread'), pg_temp.u('A'), 'read only', 'sk_live_lo9r', 'lo9hashr', ARRAY['tickets:read'], pg_temp.u('oa')),
  (pg_temp.u('kb'), pg_temp.u('B'), 'B door', 'sk_live_lo9b', 'lo9hashb', ARRAY['checkin:write'], pg_temp.u('ob'));

-- The questions, through the owner's editor.
DO $$
DECLARE r jsonb;
BEGIN
  PERFORM pg_temp.act(pg_temp.u('oa'));
  r := public.exos_save_event_question(pg_temp.u('e1'), '{"label": "Company", "kind": "text", "required": true, "scope": "order"}');
  INSERT INTO lo9q VALUES ('company', r ->> 'id');
  r := public.exos_save_event_question(pg_temp.u('e1'), '{"label": "Size", "kind": "single_choice", "options": ["S", "M", "L"], "required": true, "scope": "ticket"}');
  INSERT INTO lo9q VALUES ('size', r ->> 'id');
  r := public.exos_save_event_question(pg_temp.u('e1'), '{"label": "Bringing a guest?", "kind": "single_choice", "options": ["Yes", "No"], "scope": "order"}');
  INSERT INTO lo9q VALUES ('guest', r ->> 'id');
  r := public.exos_save_event_question(pg_temp.u('e1'), jsonb_build_object('label', 'Guest name', 'kind', 'text', 'required', true,
         'scope', 'order', 'parent_question_id', pg_temp.q('guest'), 'parent_values', jsonb_build_array('Yes')));
  INSERT INTO lo9q VALUES ('gname', r ->> 'id');
  r := public.exos_save_event_question(pg_temp.u('e1'), '{"label": "Staff note", "kind": "text", "scope": "ticket", "hidden": true}');
  INSERT INTO lo9q VALUES ('hidden', r ->> 'id');
  r := public.exos_save_event_question(pg_temp.u('e2'), '{"label": "Dietary needs", "kind": "text", "scope": "ticket"}');
  INSERT INTO lo9q VALUES ('diet', r ->> 'id');
  PERFORM pg_temp.act(pg_temp.u('ob'));
  r := public.exos_save_event_question(pg_temp.u('e9'), '{"label": "B secret label", "kind": "text", "scope": "order"}');
  INSERT INTO lo9q VALUES ('bq', r ->> 'id');
  PERFORM pg_temp.act(NULL);
END $$;

-- LO0 -------------------------------------------------------------------------
DO $$
DECLARE f text; d text;
BEGIN
  FOREACH f IN ARRAY ARRAY['public._exos_reservation_answer_tiers(jsonb)',
                           'public._exos_reservation_answers_check(uuid,boolean,jsonb,jsonb)',
                           'public._exos_partner_reservation_answers(uuid,uuid,text,jsonb)',
                           'public._exos_partner_event_questions(uuid,uuid)'] LOOP
    ASSERT NOT has_function_privilege('anon', f, 'EXECUTE') AND NOT has_function_privilege('authenticated', f, 'EXECUTE')
       AND has_function_privilege('service_role', f, 'EXECUTE'), 'LO0 service role only: ' || f;
  END LOOP;
  f := 'public.exos_event_audit_summary(uuid)';
  ASSERT NOT has_function_privilege('anon', f, 'EXECUTE') AND has_function_privilege('authenticated', f, 'EXECUTE'), 'LO0 ' || f;
  ASSERT (SELECT bool_and(p.proconfig @> ARRAY['search_path=public, pg_temp']) FROM pg_proc p
           WHERE p.oid IN ('public._exos_reservation_answers_check(uuid,boolean,jsonb,jsonb)'::regprocedure,
                           'public._exos_partner_reservation_answers(uuid,uuid,text,jsonb)'::regprocedure,
                           'public._exos_partner_event_questions(uuid,uuid)'::regprocedure,
                           'public.exos_event_audit_summary(uuid)'::regprocedure)), 'LO0 search_path pinned';
  d := pg_get_functiondef('public._exos_partner_reserve(uuid,uuid,uuid,uuid,jsonb,jsonb,boolean,boolean)'::regprocedure);
  FOREACH f IN ARRAY ARRAY['/* exos: reservation answers check */', '/* exos: reservation answers record */',
                           '/* exos: partner price step */', '/* exos: partner cap */', '/* exos: reserve idem store */',
                           '/* exos: partner presale mode */'] LOOP
    ASSERT position(f IN d) > 0, 'LO0 _exos_partner_reserve keeps ' || f;
  END LOOP;
  d := pg_get_functiondef('public.exos_api_write(uuid,text,text,jsonb,text)'::regprocedure);
  FOREACH f IN ARRAY ARRAY['/* exos: addon undo api */', '/* exos: addon undo api route */', '/* exos: addon pass api */',
                           '/* exos: addon access barcode */', '/* exos: idem hash set */'] LOOP
    ASSERT position(f IN d) > 0, 'LO0 exos_api_write keeps ' || f;
  END LOOP;
  RAISE NOTICE 'OK  LO0 grants, search_path, markers (new and earlier)';
END $$;

-- LO1 -------------------------------------------------------------------------
DO $$
DECLARE
  s text; r jsonb; v_res uuid; v_tok text; v_ans jsonb; v_t1 uuid; v_t2 uuid;
  v_ok jsonb := jsonb_build_object(
    'order', jsonb_build_object(pg_temp.q('company'), 'Acme', pg_temp.q('guest'), 'No'),
    'tickets', jsonb_build_array(jsonb_build_object(pg_temp.q('size'), 'L'), jsonb_build_object(pg_temp.q('size'), 'S')));
BEGIN
  -- No answers: the required ones are missing; nothing held, no reservation.
  s := pg_temp.st(format('SELECT pg_temp.reserve(%L::jsonb)', jsonb_build_array(pg_temp.line('ga', 2))));
  ASSERT s LIKE 'EXQRQ %required checkout questions (3 unanswered, first: "Company")%[questions-required]%', 'LO1 no answers: ' || s;
  ASSERT s LIKE '%"label": "Size"%"ticket": 2%', 'LO1 DETAIL lists each missing one: ' || s;
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_partner_reservations WHERE event_id = pg_temp.u('e1')), 'LO1 no reservation';
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_cart_holds WHERE event_id = pg_temp.u('e1')), 'LO1 nothing held';
  -- One ticket's size missing.
  s := pg_temp.st(format('SELECT pg_temp.reserve(%L::jsonb, %L::jsonb)', jsonb_build_array(pg_temp.line('ga', 2)),
         jsonb_set(v_ok, '{tickets,1}', '{}'::jsonb)));
  ASSERT s LIKE 'EXQRQ %(1 unanswered, first: "Size")%' AND s LIKE '%"ticket": 2%', 'LO1 ticket 2''s size: ' || s;
  -- An invalid answer: 22023, before the required check.
  s := pg_temp.st(format('SELECT pg_temp.reserve(%L::jsonb, %L::jsonb)', jsonb_build_array(pg_temp.line('ga', 2)),
         jsonb_set(v_ok, '{tickets,0}', jsonb_build_object(pg_temp.q('size'), 'XXL'))));
  ASSERT s LIKE '22023 checkout question "Size" (ticket 1): pick one of the options%', 'LO1 invalid choice: ' || s;
  -- Show only if: "Yes" makes the guest's name required; "No" doesn't.
  s := pg_temp.st(format('SELECT pg_temp.reserve(%L::jsonb, %L::jsonb)', jsonb_build_array(pg_temp.line('ga', 2)),
         jsonb_set(v_ok, ARRAY['order', pg_temp.q('guest')], '"Yes"')));
  ASSERT s LIKE 'EXQRQ %first: "Guest name"%', 'LO1 a shown child is required: ' || s;
  -- A hidden (staff) question is not asked of partners.
  s := pg_temp.st(format('SELECT pg_temp.reserve(%L::jsonb, %L::jsonb)', jsonb_build_array(pg_temp.line('ga', 2)),
         jsonb_set(v_ok, '{tickets,0}', jsonb_build_object(pg_temp.q('size'), 'L', pg_temp.q('hidden'), 'x'))));
  ASSERT s LIKE '22023 checkout questions (ticket 1): this question is not asked for this event%', 'LO1 hidden refused: ' || s;
  -- Another org's question: refused, its label never echoed.
  s := pg_temp.st(format('SELECT pg_temp.reserve(%L::jsonb, %L::jsonb)', jsonb_build_array(pg_temp.line('ga', 2)),
         jsonb_set(v_ok, ARRAY['order', pg_temp.q('bq')], '"hi"')));
  ASSERT s LIKE '22023 checkout questions: this question is not asked%' AND s NOT LIKE '%B secret label%', 'LO1 cross-org: ' || s;
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_cart_holds WHERE event_id = pg_temp.u('e1')), 'LO1 still nothing held';
  -- A good reservation, two types sent VIP first: tickets[] follow the reservation's order (GA, then VIP).
  r := pg_temp.reserve(jsonb_build_array(pg_temp.line('vip', 1), pg_temp.line('ga', 1)), v_ok);
  v_tok := r ->> 'token';
  SELECT id INTO v_res FROM public.exos_partner_reservations WHERE token = v_tok;
  ASSERT (SELECT lines -> 0 ->> 'tier_id' FROM public.exos_partner_reservations WHERE id = v_res) = pg_temp.u('ga')::text,
    'LO1 the reservation lists GA first';
  ASSERT (SELECT count(*) FROM public.exos_question_answers WHERE order_ref = 'po:' || v_res) = 4, 'LO1 four answers stored';
  ASSERT (SELECT bool_and(source = 'api' AND attached_at IS NULL AND buyer_uid IS NULL AND org_id = pg_temp.u('A'))
            FROM public.exos_question_answers WHERE order_ref = 'po:' || v_res), 'LO1 stored like online, not attached yet';
  r := pg_temp.complete(v_tok);
  ASSERT (r ->> 'fresh')::boolean, 'LO1 completed: ' || r::text;
  SELECT id INTO v_t1 FROM public.exos_tickets WHERE order_ref = 'po:' || v_res AND tier_id = pg_temp.u('ga');
  SELECT id INTO v_t2 FROM public.exos_tickets WHERE order_ref = 'po:' || v_res AND tier_id = pg_temp.u('vip');
  ASSERT (SELECT value #>> '{}' FROM public.exos_question_answers WHERE ticket_id = v_t1 AND question_id = pg_temp.q('size')::uuid) = 'L',
    'LO1 GA (ticket 1) has L';
  ASSERT (SELECT value #>> '{}' FROM public.exos_question_answers WHERE ticket_id = v_t2 AND question_id = pg_temp.q('size')::uuid) = 'S',
    'LO1 VIP (ticket 2) has S';
  ASSERT (SELECT bool_and(attached_at IS NOT NULL) FROM public.exos_question_answers WHERE order_ref = 'po:' || v_res),
    'LO1 every answer attached at complete';
  v_ans := public._exos_answers_for(ARRAY[v_t1], true);
  ASSERT v_ans::text LIKE '%Acme%', 'LO1 the order''s answer reads with the ticket: ' || v_ans::text;
  -- Comps: the same rule.
  s := pg_temp.st(format('SELECT public._exos_partner_comp(%L, %L, %L, %L::jsonb, %L::jsonb, %L)', pg_temp.u('A'), pg_temp.u('p1'),
         pg_temp.u('e1'), jsonb_build_array(pg_temp.line('ga', 1)), '{}', 'https://exos.test'));
  ASSERT s LIKE 'EXQRQ %', 'LO1 a comp without answers: ' || s;
  r := public._exos_partner_comp(pg_temp.u('A'), pg_temp.u('p1'), pg_temp.u('e1'), jsonb_build_array(pg_temp.line('ga', 1)),
         jsonb_build_object('answers', jsonb_build_object('order', v_ok -> 'order', 'tickets', jsonb_build_array(v_ok -> 'tickets' -> 0))),
         'https://exos.test');
  ASSERT (SELECT count(*) FROM public.exos_question_answers a JOIN public.exos_tickets t ON t.id = a.ticket_id
           WHERE t.order_ref = 'po:' || (r -> 'order' ->> 'id')) = 1, 'LO1 the comp''s ticket has its size: ' || r::text;
  RAISE NOTICE 'OK  LO1 partner reserve: required (conditional) answers, refused before a hold; stored like online; attached at complete; comps';
END $$;

-- LO2 -------------------------------------------------------------------------
DO $$
DECLARE s text; r jsonb; v_tok text; v_res uuid; v_n int;
BEGIN
  -- The organizer's box office: never required; hidden questions taken.
  r := pg_temp.reserve(jsonb_build_array(pg_temp.line('ga', 1)), NULL, 'org');
  ASSERT r ->> 'token' IS NOT NULL, 'LO2 organizer without answers: ' || r::text;
  PERFORM public._exos_partner_reservation_cancel(pg_temp.u('A'), NULL, r ->> 'token');
  r := pg_temp.reserve(jsonb_build_array(pg_temp.line('ga', 1)),
         jsonb_build_object('tickets', jsonb_build_array(jsonb_build_object(pg_temp.q('hidden'), 'VIP friend'))), 'org');
  SELECT id INTO v_res FROM public.exos_partner_reservations WHERE token = r ->> 'token';
  ASSERT (SELECT display FROM public.exos_question_answers WHERE order_ref = 'po:' || v_res AND question_id = pg_temp.q('hidden')::uuid)
         = 'VIP friend', 'LO2 organizer answers a hidden question';
  -- /build checks and stores nothing.
  s := pg_temp.st(format('SELECT pg_temp.reserve(%L::jsonb, %L::jsonb, %L, %L, true)', jsonb_build_array(pg_temp.line('ga', 1)),
         jsonb_build_object('tickets', jsonb_build_array(jsonb_build_object(pg_temp.q('size'), 'XXL'))), 'org', 'e1'));
  ASSERT s LIKE '22023 %pick one of the options%', 'LO2 build checks answers: ' || s;
  v_n := (SELECT count(*) FROM public.exos_question_answers WHERE event_id = pg_temp.u('e1'));
  r := pg_temp.reserve(jsonb_build_array(pg_temp.line('ga', 1)),
         jsonb_build_object('tickets', jsonb_build_array(jsonb_build_object(pg_temp.q('size'), 'M'))), 'org', 'e1', true);
  ASSERT r ? 'order_items' AND (SELECT count(*) FROM public.exos_question_answers WHERE event_id = pg_temp.u('e1')) = v_n,
    'LO2 build stores nothing: ' || r::text;

  -- e2 (one optional question): a partner reserves without answers and sends them with complete.
  r := pg_temp.reserve(jsonb_build_array(pg_temp.line('m1', 2)), NULL, 'p1', 'e2');
  v_tok := r ->> 'token';
  SELECT id INTO v_res FROM public.exos_partner_reservations WHERE token = v_tok;
  -- Not another partner's, not another org's (nothing named).
  s := pg_temp.st(format('SELECT public._exos_partner_reservation_answers(%L, %L, %L, %L::jsonb)', pg_temp.u('A'), pg_temp.u('p2'), v_tok, '{}'));
  ASSERT s LIKE 'P0002 reservation not found%', 'LO2 another partner''s reservation: ' || s;
  s := pg_temp.st(format('SELECT public._exos_partner_reservation_answers(%L, %L, %L, %L::jsonb)', pg_temp.u('B'), pg_temp.u('p9'), v_tok, '{}'));
  ASSERT s LIKE 'P0002 reservation not found%', 'LO2 another org''s partner: ' || s;
  s := pg_temp.st(format('SELECT public._exos_partner_reservation_answers(%L, NULL, %L, %L::jsonb)', pg_temp.u('A'), v_tok, '{}'));
  ASSERT s LIKE 'P0002%', 'LO2 no partner: ' || s;
  v_n := public._exos_partner_reservation_answers(pg_temp.u('A'), pg_temp.u('p1'), v_tok,
           jsonb_build_object('tickets', jsonb_build_array('{}'::jsonb, jsonb_build_object(pg_temp.q('diet'), 'Vegan'))));
  ASSERT v_n = 1, 'LO2 complete-time answer stored: ' || v_n;
  v_n := public._exos_partner_reservation_answers(pg_temp.u('A'), pg_temp.u('p1'), v_tok,
           jsonb_build_object('tickets', jsonb_build_array(jsonb_build_object(pg_temp.q('diet'), 'Halal'))));
  ASSERT v_n = 0, 'LO2 kept once: ' || v_n;
  r := pg_temp.complete(v_tok);
  ASSERT (SELECT a.display FROM public.exos_question_answers a JOIN public.exos_tickets t ON t.id = a.ticket_id
           WHERE t.order_ref = 'po:' || v_res) = 'Vegan', 'LO2 ticket 2 has the answer';
  -- The partner's questions list: its organizer's published event only.
  r := public._exos_partner_event_questions(pg_temp.u('A'), pg_temp.u('e1'));
  ASSERT jsonb_array_length(r -> 'questions') = 4 AND r::text NOT LIKE '%Staff note%' AND r::text LIKE '%parent_question_id%',
    'LO2 questions (hidden left out, conditions shown): ' || r::text;
  s := pg_temp.st(format('SELECT public._exos_partner_event_questions(%L, %L)', pg_temp.u('B'), pg_temp.u('e1')));
  ASSERT s LIKE 'P0002 event not found%' AND s NOT LIKE '%Company%', 'LO2 another org''s event: ' || s;
  s := pg_temp.st(format('SELECT public._exos_partner_event_questions(%L, %L)', pg_temp.u('A'), pg_temp.u('e3')));
  ASSERT s LIKE 'P0002%', 'LO2 a draft event: ' || s;
  -- Another org's partner can't reserve org A's event with answers either.
  s := pg_temp.st(format($q$SELECT public._exos_partner_reserve(%L, %L, %L, NULL, %L::jsonb, '{}'::jsonb, false, false)$q$,
         pg_temp.u('B'), pg_temp.u('e1'), pg_temp.u('p9'), jsonb_build_array(pg_temp.line('ga', 1))));
  ASSERT s LIKE 'P0002 event not found%', 'LO2 org B''s partner on org A''s event: ' || s;
  RAISE NOTICE 'OK  LO2 organizer reservations optional (hidden too), build checks only; complete-time answers kept once; questions list; cross-org';
END $$;

-- LO3 -------------------------------------------------------------------------
-- An add-on with its own entry code; b1 bought 2 units at e1. A list that admits it.
INSERT INTO public.exos_event_addons (id, event_id, name, price, capacity, separate_access_barcode) VALUES
  (pg_temp.u('ad1'), pg_temp.u('e1'), 'VIP lounge', 30, 100, true);
INSERT INTO public.exos_checkout_sessions (session_id, event_id, org_id, buyer_uid, buyer_email, guest, quantity, amount_cents, currency, status) VALUES
  ('cs_lo9', pg_temp.u('e1'), pg_temp.u('A'), pg_temp.u('b1'), 'lo9-b1@x.com', false, 1, 8000, 'usd', 'fulfilled');
INSERT INTO public.exos_tickets (id, event_id, org_id, tier_id, tier_name, buyer_id, owner_id, buyer_email, status, barcode_secret, price_paid, order_ref, channel_source) VALUES
  (pg_temp.u('k1'), pg_temp.u('e1'), pg_temp.u('A'), pg_temp.u('ga'), 'GA', pg_temp.u('b1'), pg_temp.u('b1'), 'lo9-b1@x.com', 'active', 'sek-lo9', 20, 'cs_lo9', 'stripe');
INSERT INTO public.exos_order_addons (id, event_id, org_id, addon_id, addon_name, buyer_id, owner_id, quantity, unit_price_paid, order_ref, channel_source) VALUES
  (pg_temp.u('l1'), pg_temp.u('e1'), pg_temp.u('A'), pg_temp.u('ad1'), 'VIP lounge', pg_temp.u('b1'), pg_temp.u('b1'), 2, 30, 'cs_lo9', 'stripe');
INSERT INTO public.exos_checkin_lists (id, event_id, org_id, name, admits, addon_ids, allow_reentry, sort_order) VALUES
  (pg_temp.u('ll'), pg_temp.u('e1'), NULL, 'VIP lounge', 'addons', ARRAY[pg_temp.u('ad1')], false, 1);
DO $$
DECLARE p1 uuid := pg_temp.pass('l1', 1); p2 uuid := pg_temp.pass('l1', 2); r jsonb; s text;
BEGIN
  ASSERT p1 IS NOT NULL AND p2 IS NOT NULL, 'LO3 two passes issued';
  -- sa's key scans p1 at the lounge, then undoes it: their own scan, in the window.
  r := pg_temp.api('ksa', 'sa', 'ticket.check_in', p1, jsonb_build_object('barcode', pg_temp.acode(p1), 'list_id', pg_temp.u('ll')));
  ASSERT (r ->> 'ok')::boolean AND r ->> 'kind' = 'addon', 'LO3 API scan: ' || r::text;
  r := pg_temp.api('ksa', 'sa', 'ticket.undo_check_in', p1, '{"reason": "x"}');
  ASSERT r ->> 'reason' = 'reason-required' AND r ->> 'kind' = 'addon', 'LO3 a reason: ' || r::text;
  -- Another scanner's key: not theirs.
  r := pg_temp.api('ksb', 'sb', 'ticket.undo_check_in', p1, '{"reason": "wrong guest"}');
  ASSERT r ->> 'reason' = 'needs-manager', 'LO3 another scanner: ' || r::text;
  r := pg_temp.api('ksa', 'sa', 'ticket.undo_check_in', p1, '{"reason": "wrong guest", "device": "Gate 2"}');
  ASSERT (r ->> 'ok')::boolean AND r ->> 'status' = 'active' AND (r ->> 'removed')::int = 1, 'LO3 own undo: ' || r::text;
  ASSERT (SELECT undone_by = pg_temp.u('sa') AND undone_as = 'scanner' AND device = 'Gate 2' FROM public.exos_addon_pass_undos
           WHERE pass_id = p1), 'LO3 the undo row names the key''s creator';
  ASSERT (SELECT status = 'active' FROM public.exos_addon_passes WHERE id = p1), 'LO3 the pass is usable again';
  -- Scanned again, 11 minutes ago: the scanner's key can't; the owner's can.
  r := pg_temp.api('ksa', 'sa', 'ticket.check_in', p1, jsonb_build_object('barcode', pg_temp.acode(p1), 'list_id', pg_temp.u('ll')));
  ASSERT (r ->> 'ok')::boolean, 'LO3 scans again: ' || r::text;
  UPDATE public.exos_addon_pass_checkins SET scanned_at = now() - interval '11 minutes' WHERE pass_id = p1;
  r := pg_temp.api('ksa', 'sa', 'ticket.undo_check_in', p1, '{"reason": "late"}');
  ASSERT r ->> 'reason' = 'undo-window-passed', 'LO3 the window: ' || r::text;
  r := pg_temp.api('ko', 'oa', 'ticket.undo_check_in', p1, '{"reason": "owner fixes it"}');
  ASSERT (r ->> 'ok')::boolean AND EXISTS (SELECT 1 FROM public.exos_addon_pass_undos WHERE pass_id = p1 AND undone_as = 'manager' AND undone_by = pg_temp.u('oa')),
    'LO3 owner after the window: ' || r::text;
  -- Nothing to undo; a key without checkin:write; another org's key.
  r := pg_temp.api('ko', 'oa', 'ticket.undo_check_in', p2, '{"reason": "nothing here"}');
  ASSERT r ->> 'reason' = 'not-checked-in', 'LO3 not checked in: ' || r::text;
  s := pg_temp.st(format($q$SELECT pg_temp.api('kread', 'oa', 'ticket.undo_check_in', %L, '{"reason": "nope"}')$q$, p1));
  ASSERT s LIKE '42501%checkin:write%', 'LO3 a key without the scope: ' || s;
  s := pg_temp.st(format($q$SELECT pg_temp.api('kb', 'ob', 'ticket.undo_check_in', %L, '{"reason": "nope"}')$q$, p1));
  ASSERT s LIKE 'P0002 exos_api_write: ticket not found%' AND s NOT LIKE '%VIP lounge%', 'LO3 another org''s pass: ' || s;
  PERFORM pg_temp.act(NULL);
  -- A ticket still goes to the ticket undo.
  r := pg_temp.api('ko', 'oa', 'ticket.undo_check_in', pg_temp.u('k1'), '{"reason": "never scanned"}');
  ASSERT coalesce(r ->> 'kind', '') <> 'addon', 'LO3 a ticket id is a ticket undo: ' || r::text;
  RAISE NOTICE 'OK  LO3 API undo of an add-on scan: the door''s role and window rules for the key''s creator; scope; cross-org';
END $$;

-- LO4 -------------------------------------------------------------------------
DO $$
DECLARE r jsonb; s text; who text;
BEGIN
  PERFORM pg_temp.act(pg_temp.u('oa'));
  r := public.exos_event_audit_summary(pg_temp.u('e3'));
  ASSERT r ->> 'published_at' IS NULL AND r -> 'changes_since_publish' = 'null'::jsonb, 'LO4 never published: ' || r::text;
  -- Publish, then two changes and an export.
  UPDATE public.exos_events SET status = 'published' WHERE id = pg_temp.u('e3');
  UPDATE public.exos_events SET name = 'LO9 Draft (renamed)' WHERE id = pg_temp.u('e3');
  UPDATE public.exos_ticket_tiers SET price = 18 WHERE id = pg_temp.u('d1');
  PERFORM public.exos_audit_export(pg_temp.u('A'), 'attendees', 3, pg_temp.u('e3'));
  r := public.exos_event_audit_summary(pg_temp.u('e3'));
  ASSERT r ->> 'published_at' IS NOT NULL AND (r ->> 'changes_since_publish')::int = 2 AND (r ->> 'org_id')::uuid = pg_temp.u('A'),
    'LO4 two changes since publish (the export left out): ' || r::text;
  ASSERT (r ->> 'changes_total')::int = (SELECT count(*) FROM public.exos_org_audit WHERE event_id = pg_temp.u('e3') AND action NOT LIKE 'export.%'),
    'LO4 total: ' || r::text;
  -- Unpublish + publish again: counted from the latest publish.
  UPDATE public.exos_events SET status = 'draft' WHERE id = pg_temp.u('e3');
  UPDATE public.exos_events SET status = 'published' WHERE id = pg_temp.u('e3');
  r := public.exos_event_audit_summary(pg_temp.u('e3'));
  ASSERT (r ->> 'changes_since_publish')::int = 0, 'LO4 republished: ' || r::text;
  -- Manager and finance read it; scanner, content, org B's owner, nobody can't; an unknown event is the same 42501.
  FOREACH who IN ARRAY ARRAY['ma', 'fa'] LOOP
    PERFORM pg_temp.act(pg_temp.u(who));
    r := public.exos_event_audit_summary(pg_temp.u('e3'));
    ASSERT (r ->> 'changes_since_publish')::int = 0, 'LO4 ' || who || ' reads it';
  END LOOP;
  FOREACH who IN ARRAY ARRAY['sa', 'ca', 'ob', ''] LOOP
    PERFORM pg_temp.act(CASE WHEN who = '' THEN NULL ELSE pg_temp.u(who) END);
    s := pg_temp.st(format('SELECT public.exos_event_audit_summary(%L)', pg_temp.u('e3')));
    ASSERT s LIKE '42501 not authorized%', 'LO4 ' || coalesce(nullif(who, ''), 'nobody') || ': ' || s;
  END LOOP;
  PERFORM pg_temp.act(pg_temp.u('oa'));
  s := pg_temp.st(format('SELECT public.exos_event_audit_summary(%L)', gen_random_uuid()));
  ASSERT s LIKE '42501 not authorized%', 'LO4 an unknown event: ' || s;
  s := pg_temp.st(format('SELECT public.exos_event_audit_summary(%L)', pg_temp.u('e9')));
  ASSERT s LIKE '42501 not authorized%', 'LO4 org B''s event: ' || s;
  PERFORM pg_temp.act(NULL);
  RAISE NOTICE 'OK  LO4 changes since publish: after the latest publish, exports left out; owner / manager / finance only';
END $$;
-- As the client role: authenticated may call it; anon may not.
SET LOCAL ROLE anon;
DO $$ BEGIN
  PERFORM public.exos_event_audit_summary(md5('lo9:e3')::uuid);
  RAISE EXCEPTION 'LO4 anon called the summary';
EXCEPTION WHEN insufficient_privilege THEN NULL;
END $$;
RESET ROLE;

ROLLBACK;
