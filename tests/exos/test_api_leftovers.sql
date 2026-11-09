-- ============================================================================
-- Partner API leftovers (mig 20261111140000, claude/exos-api-leftovers).
-- Self-contained (al11… ids), rolled back.
--   AL0 shape: the new internal functions are service-role only, the reissue
--       is authenticated (never anon), search_path pinned, every marker in
--       place and the earlier ones kept, the log table's RLS and grants
--   AL1 a partner's update replaces the answers while the reservation is
--       open: the reserve's rules (required for partners, "show only if",
--       invalid 22023, hidden refused, another org's question unnamed),
--       nothing changes on a refusal, one audit row per replacement (counts,
--       never values); completed: 409 and the attached answers untouched;
--       expired: nothing changes; another partner / org / the organizer:
--       not found
--   AL2 an organizer's update: never required, hidden questions allowed,
--       clearing with {}; a partner can't reach it; another org can't
--   AL3 partner order reads: each ticket's answers + custom_field_values,
--       only the answers the partner itself submitted (origin, source api, by
--       completion): a door answer and a holder's rewrite after completion
--       are left out, hidden questions too,
--       another partner's / org's order is nothing; organizer reads unchanged
--   AL4 add-on wallet reissue: holder only (42501, unnamed), voided / never
--       in a wallet refused, the epoch moves, the door refuses the old Apple
--       and Google codes (online and the offline replay) and takes the new
--       one, the door's saved keys change, 5 a day per holder, logged (table
--       + audit), the log's RLS (holder, owner / manager; not a scanner, not
--       another org), exos_my_addon_passes shows the epoch
-- Users: oa owner A, ma manager A, sa scanner A, ob owner B, b1 / b2 buyers.
-- ============================================================================
\set ON_ERROR_STOP on
BEGIN;

CREATE FUNCTION pg_temp.u(p text) RETURNS uuid LANGUAGE sql IMMUTABLE AS $$
  SELECT md5('al11:' || p)::uuid
$$;
CREATE FUNCTION pg_temp.act(p_uid uuid) RETURNS void LANGUAGE sql AS $$
  SELECT set_config('app.uid', coalesce(p_uid::text, ''), true), set_config('app.jwt', '{"email":"al11@x.com"}', true);
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
CREATE FUNCTION pg_temp.reserve(p_lines jsonb, p_answers jsonb DEFAULT NULL, p_partner text DEFAULT 'p1', p_event text DEFAULT 'e1')
RETURNS jsonb LANGUAGE sql AS $$
  SELECT public._exos_partner_reserve(pg_temp.u('A'), pg_temp.u(p_event),
    CASE WHEN p_partner = 'org' THEN NULL ELSE pg_temp.u(p_partner) END,
    CASE WHEN p_partner = 'org' THEN pg_temp.u('kbox') END, p_lines,
    CASE WHEN p_answers IS NULL THEN '{}'::jsonb ELSE jsonb_build_object('answers', p_answers) END, false, false)
$$;
-- The update as exos-api calls it (p_attrs carries answers when sent).
CREATE FUNCTION pg_temp.upd(p_token text, p_attrs jsonb, p_partner text DEFAULT 'p1', p_org text DEFAULT 'A') RETURNS jsonb
LANGUAGE sql AS $$
  SELECT public._exos_partner_reservation_update(pg_temp.u(p_org), CASE WHEN p_partner = 'org' THEN NULL ELSE pg_temp.u(p_partner) END,
                                                 p_token, p_attrs)
$$;
CREATE FUNCTION pg_temp.complete(p_token text, p_partner text DEFAULT 'p1') RETURNS jsonb LANGUAGE sql AS $$
  SELECT public._exos_partner_reservation_complete(pg_temp.u('A'), CASE WHEN p_partner = 'org' THEN NULL ELSE pg_temp.u(p_partner) END,
                                                   p_token, NULL, 'https://exos.test')
$$;
CREATE FUNCTION pg_temp.line(p_tier text, p_qty int) RETURNS jsonb LANGUAGE sql IMMUTABLE AS $$
  SELECT jsonb_build_object('ticket_type_id', pg_temp.u(p_tier), 'quantity', p_qty)
$$;
CREATE FUNCTION pg_temp.res_id(p_token text) RETURNS uuid LANGUAGE sql AS $$
  SELECT id FROM public.exos_partner_reservations WHERE token = p_token
$$;
-- The reservation's stored answers as {question label: display}, per ticket index.
CREATE FUNCTION pg_temp.stored(p_token text) RETURNS jsonb LANGUAGE sql AS $$
  SELECT coalesce(jsonb_object_agg(coalesce(a.ticket_index::text, 'o') || ':' || a.label, a.display), '{}'::jsonb)
    FROM public.exos_question_answers a WHERE a.order_ref = 'po:' || pg_temp.res_id(p_token)
$$;
CREATE TEMP TABLE al11q (k text PRIMARY KEY, v text) ON COMMIT DROP;
CREATE FUNCTION pg_temp.q(p_key text) RETURNS text LANGUAGE sql AS $$ SELECT v FROM al11q WHERE k = p_key $$;
CREATE FUNCTION pg_temp.pass(p_line text, p_unit int DEFAULT 1) RETURNS uuid LANGUAGE sql AS $$
  SELECT id FROM public.exos_addon_passes WHERE order_addon_id = pg_temp.u(p_line) AND unit_index = p_unit
$$;
CREATE FUNCTION pg_temp.wapple(p_pass uuid, p_epoch int) RETURNS text LANGUAGE sql AS $$
  SELECT public._exos_addon_wallet_apple_code(p.id, p.owner_id, p.barcode_secret, p_epoch) FROM public.exos_addon_passes p WHERE p.id = p_pass
$$;
CREATE FUNCTION pg_temp.wgoogle(p_pass uuid, p_epoch int, p_at timestamptz DEFAULT now()) RETURNS text LANGUAGE sql AS $$
  SELECT 'A-' || p.id || ':' || p.owner_id || ':g' || p_epoch || ':'
         || public._exos_wallet_totp(public._exos_wallet_google_key(p.id, p.owner_id, p.barcode_secret, p_epoch),
                                     floor(extract(epoch FROM p_at) / 30)::bigint)
    FROM public.exos_addon_passes p WHERE p.id = p_pass
$$;
CREATE FUNCTION pg_temp.scan(p_id uuid, p_code text) RETURNS jsonb LANGUAGE sql AS $$
  SELECT public.exos_check_in_ticket(p_id, 'camera', 'verified', p_code, pg_temp.u('e1'), NULL, NULL,
                                     'Door AL', pg_temp.u('ll'), 'entry')
$$;

INSERT INTO auth.users (id, email, email_confirmed_at) VALUES
  (pg_temp.u('oa'), 'al11-oa@x.com', now()), (pg_temp.u('ma'), 'al11-ma@x.com', now()),
  (pg_temp.u('sa'), 'al11-sa@x.com', now()), (pg_temp.u('ob'), 'al11-ob@x.com', now()),
  (pg_temp.u('b1'), 'al11-b1@x.com', now()), (pg_temp.u('b2'), 'al11-b2@x.com', now());
INSERT INTO public.exos_orgs (id, name, slug, owner_uid) VALUES
  (pg_temp.u('A'), 'AL11 Hall', 'al11-hall', pg_temp.u('oa')),
  (pg_temp.u('B'), 'AL11 Other', 'al11-other', pg_temp.u('ob'));
INSERT INTO public.exos_org_memberships (org_id, user_id, role) VALUES
  (pg_temp.u('A'), pg_temp.u('oa'), 'owner'), (pg_temp.u('A'), pg_temp.u('ma'), 'manager'),
  (pg_temp.u('A'), pg_temp.u('sa'), 'scanner'), (pg_temp.u('B'), pg_temp.u('ob'), 'owner');
INSERT INTO public.exos_events (id, org_id, name, slug, status, starts_at, doors_at, total_tickets, tickets_sold, currency, created_by) VALUES
  (pg_temp.u('e1'), pg_temp.u('A'), 'AL11 Night', 'al11-night', 'published', now() + interval '1 hour', now() - interval '1 hour', 0, 0, 'usd', pg_temp.u('oa')),
  (pg_temp.u('e9'), pg_temp.u('B'), 'AL11 Elsewhere', 'al11-else', 'published', now() + interval '3 days', NULL, 0, 0, 'usd', pg_temp.u('ob'));
INSERT INTO public.exos_ticket_tiers (id, event_id, name, price, capacity, sold, visibility, sort_order) VALUES
  (pg_temp.u('ga'), pg_temp.u('e1'), 'GA', 20, 100, 0, 'public', 1),
  (pg_temp.u('vip'), pg_temp.u('e1'), 'VIP', 50, 100, 0, 'public', 2),
  (pg_temp.u('t9'), pg_temp.u('e9'), 'B GA', 20, 100, 0, 'public', 1);
INSERT INTO public.exos_tier_distribution (tier_id, event_id, org_id, enabled)
SELECT t.id, t.event_id, e.org_id, true FROM public.exos_ticket_tiers t JOIN public.exos_events e ON e.id = t.event_id
 WHERE t.id IN (pg_temp.u('ga'), pg_temp.u('vip'), pg_temp.u('t9'));
INSERT INTO public.exos_distribution_partners (id, org_id, label, partner_type, key_prefix, key_hash, scopes) VALUES
  (pg_temp.u('p1'), pg_temp.u('A'), 'AL11 StubHub', 'stubhub', 'dk_live_al11aaa1', repeat('c1', 32), ARRAY['inventory']),
  (pg_temp.u('p2'), pg_temp.u('A'), 'AL11 Vivid', 'vivid', 'dk_live_al11aaa2', repeat('c2', 32), ARRAY['inventory']),
  (pg_temp.u('p9'), pg_temp.u('B'), 'AL11 B', 'vivid', 'dk_live_al11bbb9', repeat('c9', 32), ARRAY['inventory']);
INSERT INTO public.exos_api_keys (id, org_id, name, key_prefix, key_hash, scopes, created_by) VALUES
  (pg_temp.u('kbox'), pg_temp.u('A'), 'Box office', 'sk_live_al11box', 'al11hashbox', ARRAY['tickets:write'], pg_temp.u('oa'));

-- e1: Company (order, required), Size (ticket, required), Bringing a guest?
-- (order) -> Guest name (order, required when Yes), Staff note (ticket, hidden).
DO $$
DECLARE r jsonb;
BEGIN
  PERFORM pg_temp.act(pg_temp.u('oa'));
  r := public.exos_save_event_question(pg_temp.u('e1'), '{"label": "Company", "kind": "text", "required": true, "scope": "order"}');
  INSERT INTO al11q VALUES ('company', r ->> 'id');
  r := public.exos_save_event_question(pg_temp.u('e1'), '{"label": "Size", "kind": "single_choice", "options": ["S", "M", "L"], "required": true, "scope": "ticket"}');
  INSERT INTO al11q VALUES ('size', r ->> 'id');
  r := public.exos_save_event_question(pg_temp.u('e1'), '{"label": "Bringing a guest?", "kind": "single_choice", "options": ["Yes", "No"], "scope": "order"}');
  INSERT INTO al11q VALUES ('guest', r ->> 'id');
  r := public.exos_save_event_question(pg_temp.u('e1'), jsonb_build_object('label', 'Guest name', 'kind', 'text', 'required', true,
         'scope', 'order', 'parent_question_id', pg_temp.q('guest'), 'parent_values', jsonb_build_array('Yes')));
  INSERT INTO al11q VALUES ('gname', r ->> 'id');
  r := public.exos_save_event_question(pg_temp.u('e1'), '{"label": "Staff note", "kind": "text", "scope": "ticket", "hidden": true}');
  INSERT INTO al11q VALUES ('hidden', r ->> 'id');
  r := public.exos_save_event_question(pg_temp.u('e1'), '{"label": "Dietary needs", "kind": "text", "scope": "ticket"}');
  INSERT INTO al11q VALUES ('diet', r ->> 'id');
  PERFORM pg_temp.act(pg_temp.u('ob'));
  r := public.exos_save_event_question(pg_temp.u('e9'), '{"label": "B secret label", "kind": "text", "scope": "order"}');
  INSERT INTO al11q VALUES ('bq', r ->> 'id');
  PERFORM pg_temp.act(NULL);
END $$;

-- AL0 -------------------------------------------------------------------------
DO $$
DECLARE f text; d text;
BEGIN
  FOREACH f IN ARRAY ARRAY['public._exos_reservation_answers_replace(uuid,boolean,jsonb)',
                           'public._exos_partner_ticket_answers(uuid,uuid)',
                           'public._exos_partner_order_answers_json(uuid,text)'] LOOP
    ASSERT NOT has_function_privilege('anon', f, 'EXECUTE') AND NOT has_function_privilege('authenticated', f, 'EXECUTE')
       AND has_function_privilege('service_role', f, 'EXECUTE'), 'AL0 service role only: ' || f;
  END LOOP;
  f := 'public.exos_wallet_addon_reissue(uuid)';
  ASSERT NOT has_function_privilege('anon', f, 'EXECUTE') AND has_function_privilege('authenticated', f, 'EXECUTE'), 'AL0 ' || f;
  ASSERT (SELECT bool_and(p.proconfig @> ARRAY['search_path=public, pg_temp']) FROM pg_proc p
           WHERE p.oid IN ('public._exos_reservation_answers_replace(uuid,boolean,jsonb)'::regprocedure,
                           'public._exos_partner_ticket_answers(uuid,uuid)'::regprocedure,
                           'public._exos_partner_order_answers_json(uuid,text)'::regprocedure,
                           'public.exos_wallet_addon_reissue(uuid)'::regprocedure)), 'AL0 search_path pinned';
  ASSERT position('/* exos: reservation answers update */' IN
    pg_get_functiondef('public._exos_partner_reservation_update(uuid,uuid,text,jsonb)'::regprocedure)) > 0, 'AL0 update marker';
  ASSERT position('/* exos: partner order answers */' IN
    pg_get_functiondef('public._exos_partner_orders(uuid,uuid,jsonb,integer,integer,text)'::regprocedure)) > 0, 'AL0 orders marker';
  ASSERT position('/* exos: partner order answers */' IN
    pg_get_functiondef('public._exos_partner_order(uuid,uuid,uuid,text)'::regprocedure)) > 0, 'AL0 order marker';
  ASSERT position('/* exos: addon wallet epoch */' IN pg_get_functiondef('public.exos_my_addon_passes(uuid)'::regprocedure)) > 0,
    'AL0 my add-on passes marker';
  d := pg_get_functiondef('public._exos_partner_reserve(uuid,uuid,uuid,uuid,jsonb,jsonb,boolean,boolean)'::regprocedure);
  FOREACH f IN ARRAY ARRAY['/* exos: reservation answers check */', '/* exos: reservation answers record */'] LOOP
    ASSERT position(f IN d) > 0, 'AL0 _exos_partner_reserve keeps ' || f;
  END LOOP;
  -- The log: RLS on, read-only for clients, nothing for anon.
  ASSERT (SELECT relrowsecurity FROM pg_class WHERE oid = 'public.exos_addon_wallet_reissues'::regclass), 'AL0 RLS on';
  ASSERT has_table_privilege('authenticated', 'public.exos_addon_wallet_reissues', 'SELECT')
     AND NOT has_table_privilege('authenticated', 'public.exos_addon_wallet_reissues', 'INSERT')
     AND NOT has_table_privilege('authenticated', 'public.exos_addon_wallet_reissues', 'UPDATE')
     AND NOT has_table_privilege('anon', 'public.exos_addon_wallet_reissues', 'SELECT'), 'AL0 log grants';
  RAISE NOTICE 'OK  AL0 grants, search_path, markers (new and earlier), log RLS';
END $$;

-- AL1 -------------------------------------------------------------------------
DO $$
DECLARE
  s text; r jsonb; v_tok text; v_res uuid; v_before jsonb; v_n int;
  v_ok jsonb := jsonb_build_object(
    'order', jsonb_build_object(pg_temp.q('company'), 'Acme', pg_temp.q('guest'), 'No'),
    'tickets', jsonb_build_array(jsonb_build_object(pg_temp.q('size'), 'L'), jsonb_build_object(pg_temp.q('size'), 'S')));
  v_new jsonb := jsonb_build_object(
    'order', jsonb_build_object(pg_temp.q('company'), 'Globex', pg_temp.q('guest'), 'Yes', pg_temp.q('gname'), 'Sam'),
    'tickets', jsonb_build_array(jsonb_build_object(pg_temp.q('size'), 'M'), jsonb_build_object(pg_temp.q('size'), 'M')));
BEGIN
  -- Two types, VIP sent first: tickets[] follow the reservation's order (GA, VIP).
  r := pg_temp.reserve(jsonb_build_array(pg_temp.line('vip', 1), pg_temp.line('ga', 1)), v_ok);
  v_tok := r ->> 'token';
  v_res := pg_temp.res_id(v_tok);
  v_before := pg_temp.stored(v_tok);
  ASSERT v_before ->> 'o:Company' = 'Acme' AND v_before ->> '1:Size' = 'L', 'AL1 reserved with answers: ' || v_before::text;
  -- Refusals change nothing: a required one missing (and a shown child), an invalid
  -- choice, a hidden question, another org's question.
  s := pg_temp.st(format('SELECT pg_temp.upd(%L, %L::jsonb)', v_tok, jsonb_build_object('answers',
         jsonb_set(v_new, '{order}', (v_new -> 'order') - pg_temp.q('company')))));
  ASSERT s LIKE 'EXQRQ %first: "Company"%[questions-required]%', 'AL1 a required one missing: ' || s;
  s := pg_temp.st(format('SELECT pg_temp.upd(%L, %L::jsonb)', v_tok, jsonb_build_object('answers',
         jsonb_set(v_new, '{order}', (v_new -> 'order') - pg_temp.q('gname')))));
  ASSERT s LIKE 'EXQRQ %first: "Guest name"%', 'AL1 a shown child is required: ' || s;
  s := pg_temp.st(format('SELECT pg_temp.upd(%L, %L::jsonb)', v_tok, jsonb_build_object('answers',
         jsonb_set(v_new, '{tickets,0}', jsonb_build_object(pg_temp.q('size'), 'XXL')))));
  ASSERT s LIKE '22023 checkout question "Size" (ticket 1): pick one of the options%', 'AL1 invalid: ' || s;
  s := pg_temp.st(format('SELECT pg_temp.upd(%L, %L::jsonb)', v_tok, jsonb_build_object('answers',
         jsonb_set(v_new, '{tickets,0}', jsonb_build_object(pg_temp.q('size'), 'M', pg_temp.q('hidden'), 'x')))));
  ASSERT s LIKE '22023 %this question is not asked for this event%', 'AL1 hidden refused for partners: ' || s;
  s := pg_temp.st(format('SELECT pg_temp.upd(%L, %L::jsonb)', v_tok, jsonb_build_object('answers',
         jsonb_set(v_new, ARRAY['order', pg_temp.q('bq')], '"hi"'))));
  ASSERT s LIKE '22023 %not asked%' AND s NOT LIKE '%B secret label%', 'AL1 another org''s question unnamed: ' || s;
  s := pg_temp.st(format('SELECT pg_temp.upd(%L, %L::jsonb)', v_tok, '{"answers": ["no"]}'));
  ASSERT s LIKE '22023 answers must be an object%', 'AL1 not an object: ' || s;
  ASSERT pg_temp.stored(v_tok) = v_before, 'AL1 refusals left the set as it was';
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_org_audit WHERE entity_id = v_res::text), 'AL1 no audit row for a refusal';
  -- Not another partner's, not another org's, not the organizer's: nothing named.
  s := pg_temp.st(format('SELECT pg_temp.upd(%L, %L::jsonb, %L)', v_tok, jsonb_build_object('answers', v_new), 'p2'));
  ASSERT s LIKE 'P0002 reservation not found%', 'AL1 another partner: ' || s;
  s := pg_temp.st(format('SELECT pg_temp.upd(%L, %L::jsonb, %L, %L)', v_tok, jsonb_build_object('answers', v_new), 'p9', 'B'));
  ASSERT s LIKE 'P0002 reservation not found%', 'AL1 another org''s partner: ' || s;
  s := pg_temp.st(format('SELECT pg_temp.upd(%L, %L::jsonb, %L)', v_tok, jsonb_build_object('answers', v_new), 'org'));
  ASSERT s LIKE 'P0002 reservation not found%', 'AL1 the organizer on a partner''s reservation: ' || s;
  ASSERT pg_temp.stored(v_tok) = v_before, 'AL1 still the first set';
  -- Replaced, attendee fields in the same call.
  r := pg_temp.upd(v_tok, jsonb_build_object('first_name', 'Jane', 'answers', v_new));
  ASSERT r ->> 'first_name' = 'Jane' AND r ->> 'status' = 'active', 'AL1 updated: ' || r::text;
  ASSERT pg_temp.stored(v_tok) = jsonb_build_object('o:Company', 'Globex', 'o:Bringing a guest?', 'Yes', 'o:Guest name', 'Sam',
                                                    '1:Size', 'M', '2:Size', 'M'), 'AL1 replaced: ' || pg_temp.stored(v_tok)::text;
  ASSERT (SELECT count(*) FROM public.exos_question_answer_cursors WHERE order_ref = 'po:' || v_res) = 1, 'AL1 one cursor';
  ASSERT (SELECT count(*) FROM public.exos_org_audit WHERE entity_id = v_res::text) = 1, 'AL1 one audit row';
  ASSERT (SELECT action = 'reservation.answers_replace' AND entity_type = 'partner_reservation' AND org_id = pg_temp.u('A')
             AND event_id = pg_temp.u('e1') AND changes -> 'answers' = '[4, 5]'::jsonb AND source = 'api'
             AND changes::text NOT LIKE '%Globex%' AND changes::text NOT LIKE '%Acme%'
            FROM public.exos_org_audit WHERE entity_id = v_res::text), 'AL1 the audit row (counts, never values)';
  -- An update without answers leaves them.
  r := pg_temp.upd(v_tok, '{"last_name": "Doe"}');
  ASSERT pg_temp.stored(v_tok) ->> 'o:Company' = 'Globex', 'AL1 no answers sent: kept';
  -- Complete attaches the replaced set; then the update is 409 and nothing moves.
  r := pg_temp.complete(v_tok);
  ASSERT (r ->> 'fresh')::boolean, 'AL1 completed: ' || r::text;
  ASSERT (SELECT bool_and(attached_at IS NOT NULL) FROM public.exos_question_answers WHERE order_ref = 'po:' || v_res), 'AL1 attached';
  ASSERT (SELECT a.display FROM public.exos_question_answers a JOIN public.exos_tickets t ON t.id = a.ticket_id
           WHERE a.order_ref = 'po:' || v_res AND t.tier_id = pg_temp.u('vip')) = 'M', 'AL1 the VIP ticket has M';
  v_n := (SELECT count(*) FROM public.exos_question_answers WHERE order_ref = 'po:' || v_res);
  s := pg_temp.st(format('SELECT pg_temp.upd(%L, %L::jsonb)', v_tok, jsonb_build_object('answers', v_ok)));
  ASSERT s LIKE 'EX409 this reservation is completed%', 'AL1 completed: 409: ' || s;
  s := pg_temp.st(format('SELECT public._exos_reservation_answers_replace(%L, true, %L::jsonb)', v_res, v_ok));
  ASSERT s LIKE 'EX409 answers can only change while the reservation is open%', 'AL1 the helper refuses too: ' || s;
  ASSERT (SELECT count(*) FROM public.exos_question_answers WHERE order_ref = 'po:' || v_res AND attached_at IS NOT NULL) = v_n
     AND pg_temp.stored(v_tok) ->> 'o:Company' = 'Globex', 'AL1 the completed set untouched';
  -- Expired: the update answers the status and changes nothing.
  r := pg_temp.reserve(jsonb_build_array(pg_temp.line('ga', 1)),
         jsonb_build_object('order', v_ok -> 'order', 'tickets', jsonb_build_array(v_ok -> 'tickets' -> 0)));
  v_tok := r ->> 'token';
  UPDATE public.exos_partner_reservations SET expires_at = now() - interval '1 second' WHERE token = v_tok;
  v_before := pg_temp.stored(v_tok);
  r := pg_temp.upd(v_tok, jsonb_build_object('answers', jsonb_build_object('order', v_new -> 'order',
         'tickets', jsonb_build_array(v_new -> 'tickets' -> 0))));
  ASSERT r ->> 'status' = 'expired' AND pg_temp.stored(v_tok) = v_before, 'AL1 expired: unchanged: ' || r::text;
  RAISE NOTICE 'OK  AL1 partner update replaces answers while open (rules, refusals change nothing, audit); completed 409; expired; cross-partner / org';
END $$;

-- AL2 -------------------------------------------------------------------------
DO $$
DECLARE s text; r jsonb; v_tok text; v_ptok text;
BEGIN
  r := pg_temp.reserve(jsonb_build_array(pg_temp.line('ga', 2)), NULL, 'org');
  v_tok := r ->> 'token';
  ASSERT pg_temp.stored(v_tok) = '{}'::jsonb, 'AL2 the box office reserved without answers';
  -- Never required; hidden staff questions allowed.
  r := pg_temp.upd(v_tok, jsonb_build_object('answers', jsonb_build_object('tickets', jsonb_build_array('{}'::jsonb,
         jsonb_build_object(pg_temp.q('hidden'), 'Wheelchair')))), 'org');
  ASSERT pg_temp.stored(v_tok) = '{"2:Staff note": "Wheelchair"}'::jsonb, 'AL2 hidden answered: ' || pg_temp.stored(v_tok)::text;
  -- Still checked.
  s := pg_temp.st(format('SELECT pg_temp.upd(%L, %L::jsonb, %L)', v_tok, jsonb_build_object('answers',
         jsonb_build_object('tickets', jsonb_build_array(jsonb_build_object(pg_temp.q('size'), 'XXL')))), 'org'));
  ASSERT s LIKE '22023 %pick one of the options%', 'AL2 invalid: ' || s;
  ASSERT pg_temp.stored(v_tok) = '{"2:Staff note": "Wheelchair"}'::jsonb, 'AL2 unchanged by a refusal';
  -- {} clears the set.
  r := pg_temp.upd(v_tok, '{"answers": {}}', 'org');
  ASSERT pg_temp.stored(v_tok) = '{}'::jsonb, 'AL2 cleared';
  ASSERT (SELECT count(*) FROM public.exos_org_audit WHERE entity_id = pg_temp.res_id(v_tok)::text
           AND action = 'reservation.answers_replace') = 2, 'AL2 two audit rows';
  -- A partner can't reach the organizer's reservation; another org can't either.
  s := pg_temp.st(format('SELECT pg_temp.upd(%L, %L::jsonb, %L)', v_tok, '{"answers": {}}', 'p1'));
  ASSERT s LIKE 'P0002 reservation not found%', 'AL2 a partner on the organizer''s reservation: ' || s;
  s := pg_temp.st(format('SELECT pg_temp.upd(%L, %L::jsonb, %L, %L)', v_tok, '{"answers": {}}', 'org', 'B'));
  ASSERT s LIKE 'P0002 reservation not found%', 'AL2 another org: ' || s;
  -- The organizer's PUT on a partner's reservation is not found either (AL1); a partner's
  -- complete-time answers still keep the first set (wave 9).
  r := pg_temp.reserve(jsonb_build_array(pg_temp.line('ga', 1)), jsonb_build_object('order',
         jsonb_build_object(pg_temp.q('company'), 'First', pg_temp.q('guest'), 'No'),
         'tickets', jsonb_build_array(jsonb_build_object(pg_temp.q('size'), 'S'))));
  v_ptok := r ->> 'token';
  ASSERT public._exos_partner_reservation_answers(pg_temp.u('A'), pg_temp.u('p1'), v_ptok,
           jsonb_build_object('order', jsonb_build_object(pg_temp.q('company'), 'Second'))) = 0, 'AL2 complete-time: first wins';
  ASSERT pg_temp.stored(v_ptok) ->> 'o:Company' = 'First', 'AL2 still First';
  PERFORM public._exos_partner_reservation_cancel(pg_temp.u('A'), pg_temp.u('p1'), v_ptok);
  s := pg_temp.st(format('SELECT pg_temp.upd(%L, %L::jsonb)', v_ptok, '{"answers": {}}'));
  ASSERT s LIKE 'EX409 this reservation is cancelled%', 'AL2 cancelled: 409: ' || s;
  PERFORM public._exos_partner_reservation_cancel(pg_temp.u('A'), NULL, v_tok);
  RAISE NOTICE 'OK  AL2 organizer update: never required, hidden allowed, {} clears; cross-channel / cross-org refused; cancelled 409';
END $$;

-- AL3 -------------------------------------------------------------------------
DO $$
DECLARE r jsonb; v_tok text; v_res uuid; o jsonb; t jsonb; v_tk uuid; v_tok2 text; v_res2 uuid;
BEGIN
  r := pg_temp.reserve(jsonb_build_array(pg_temp.line('ga', 2)), jsonb_build_object(
         'order', jsonb_build_object(pg_temp.q('company'), 'Initech', pg_temp.q('guest'), 'No'),
         'tickets', jsonb_build_array(jsonb_build_object(pg_temp.q('size'), 'S'), jsonb_build_object(pg_temp.q('size'), 'L'))), 'p2');
  v_tok := r ->> 'token';
  v_res := pg_temp.res_id(v_tok);
  PERFORM public._exos_partner_reservation_complete(pg_temp.u('A'), pg_temp.u('p2'), v_tok, NULL, 'https://exos.test');
  -- The door answers the hidden question on ticket 1: staff data, never shown to the partner.
  SELECT ticket_id INTO v_tk FROM public.exos_question_answers
   WHERE order_ref = 'po:' || v_res AND ticket_index = 1 AND question_id = pg_temp.q('size')::uuid;
  PERFORM public._exos_set_ticket_answers(v_tk, jsonb_build_object(pg_temp.q('hidden'), 'Banned last year'), 'door');
  ASSERT EXISTS (SELECT 1 FROM public.exos_question_answers WHERE ticket_id = v_tk AND question_id = pg_temp.q('hidden')::uuid),
    'AL3 the door''s hidden answer exists';
  o := public._exos_partner_order(pg_temp.u('A'), pg_temp.u('p2'), v_res, 'https://exos.test');
  ASSERT jsonb_array_length(o -> 'tickets') = 2, 'AL3 two tickets: ' || o::text;
  ASSERT o::text NOT LIKE '%Banned last year%' AND o::text NOT LIKE '%Staff note%', 'AL3 hidden left out: ' || o::text;
  t := (SELECT x FROM jsonb_array_elements(o -> 'tickets') x WHERE x ->> 'id' = v_tk::text);
  ASSERT jsonb_array_length(t -> 'answers') = 3
     AND (SELECT count(*) FROM jsonb_array_elements(t -> 'answers') a WHERE a ->> 'scope' = 'order') = 2
     AND (SELECT a ->> 'display' FROM jsonb_array_elements(t -> 'answers') a WHERE a ->> 'label' = 'Size') = 'S',
    'AL3 ticket 1: the order''s two + its own: ' || t::text;
  ASSERT (SELECT bool_and(a ? 'question_id' AND a ? 'kind' AND a ? 'value') FROM jsonb_array_elements(t -> 'answers') a),
    'AL3 the answers shape';
  ASSERT jsonb_array_length(t -> 'custom_field_values') = 3
     AND t -> 'custom_field_values' @> jsonb_build_array(jsonb_build_object('custom_field_id', pg_temp.q('company'),
                                                                            'name', 'Company', 'value', 'Initech')),
    'AL3 Opendate custom_field_values: ' || (t -> 'custom_field_values')::text;
  ASSERT (SELECT x FROM jsonb_array_elements(o -> 'tickets') x WHERE x ->> 'id' <> v_tk::text) -> 'answers' @>
         jsonb_build_array(jsonb_build_object('label', 'Size', 'display', 'L')), 'AL3 ticket 2 has L';
  -- The list carries the same.
  r := public._exos_partner_orders(pg_temp.u('A'), pg_temp.u('p2'), '{}'::jsonb, 1, 25, 'https://exos.test');
  ASSERT (r ->> 'total_entries')::int = 1 AND r -> 'collection' -> 0 = o, 'AL3 the list = the single read: ' || r::text;
  -- Only what the partner itself submitted. Its rows carry their origin; after completion the door answers a
  -- shown question on ticket 1 and a later holder rewrites ticket 1's size: neither reaches the partner.
  ASSERT (SELECT bool_and(partner_reservation_id = v_res) FROM public.exos_question_answers
           WHERE order_ref = 'po:' || v_res AND source = 'api'), 'AL3 the partner''s answers carry their origin';
  PERFORM public._exos_set_ticket_answers(v_tk, jsonb_build_object(pg_temp.q('diet'), 'Vegan, nut allergy'), 'door');
  PERFORM public._exos_set_ticket_answers(v_tk, jsonb_build_object(pg_temp.q('size'), 'M'), 'checkout');
  ASSERT (SELECT display = 'M' AND source = 'checkout' AND partner_reservation_id IS NULL FROM public.exos_question_answers
           WHERE ticket_id = v_tk AND question_id = pg_temp.q('size')::uuid), 'AL3 the rewritten answer lost its origin';
  ASSERT (SELECT partner_reservation_id IS NULL FROM public.exos_question_answers
           WHERE ticket_id = v_tk AND question_id = pg_temp.q('diet')::uuid), 'AL3 the door''s answer has no origin';
  -- An UPDATE can't hand an origin to someone else's answer.
  UPDATE public.exos_question_answers SET partner_reservation_id = v_res
   WHERE ticket_id = v_tk AND question_id = pg_temp.q('diet')::uuid;
  ASSERT (SELECT partner_reservation_id IS NULL FROM public.exos_question_answers
           WHERE ticket_id = v_tk AND question_id = pg_temp.q('diet')::uuid), 'AL3 an origin can''t be set by an update';
  o := public._exos_partner_order(pg_temp.u('A'), pg_temp.u('p2'), v_res, 'https://exos.test');
  t := (SELECT x FROM jsonb_array_elements(o -> 'tickets') x WHERE x ->> 'id' = v_tk::text);
  ASSERT o::text NOT LIKE '%Vegan%' AND o::text NOT LIKE '%Dietary%', 'AL3 the door''s later answer left out: ' || o::text;
  ASSERT jsonb_array_length(t -> 'answers') = 2
     AND (SELECT bool_and(a ->> 'scope' = 'order') FROM jsonb_array_elements(t -> 'answers') a)
     AND t -> 'answers' @> jsonb_build_array(jsonb_build_object('label', 'Company', 'display', 'Initech'))
     AND jsonb_array_length(t -> 'custom_field_values') = 2,
    'AL3 ticket 1: the holder''s rewrite left out, the partner''s order answers kept: ' || t::text;
  ASSERT (SELECT x FROM jsonb_array_elements(o -> 'tickets') x WHERE x ->> 'id' <> v_tk::text) -> 'answers' @>
         jsonb_build_array(jsonb_build_object('label', 'Size', 'display', 'L')), 'AL3 ticket 2 still has the partner''s L';
  r := public._exos_partner_orders(pg_temp.u('A'), pg_temp.u('p2'), '{}'::jsonb, 1, 25, 'https://exos.test');
  ASSERT r -> 'collection' -> 0 = o, 'AL3 the list agrees';
  -- Another partner's order, another org's partner: nothing (404 at the edge); p1's list has no p2 order.
  ASSERT public._exos_partner_order(pg_temp.u('A'), pg_temp.u('p1'), v_res, 'https://exos.test') IS NULL, 'AL3 another partner';
  ASSERT public._exos_partner_order(pg_temp.u('B'), pg_temp.u('p9'), v_res, 'https://exos.test') IS NULL, 'AL3 another org';
  r := public._exos_partner_orders(pg_temp.u('A'), pg_temp.u('p1'), '{}'::jsonb, 1, 250, 'https://exos.test');
  ASSERT r::text NOT LIKE '%Initech%' AND NOT (r -> 'collection' @> jsonb_build_array(jsonb_build_object('id', v_res))),
    'AL3 p1''s list: ' || left(r::text, 300);
  r := public._exos_partner_orders(pg_temp.u('B'), pg_temp.u('p9'), '{}'::jsonb, 1, 250, 'https://exos.test');
  ASSERT (r ->> 'total_entries')::int = 0, 'AL3 org B''s partner sees nothing';
  -- The helper refuses a ticket of another reservation.
  r := pg_temp.reserve(jsonb_build_array(pg_temp.line('ga', 1)), jsonb_build_object(
         'order', jsonb_build_object(pg_temp.q('company'), 'Other', pg_temp.q('guest'), 'No'),
         'tickets', jsonb_build_array(jsonb_build_object(pg_temp.q('size'), 'M'))), 'p1');
  v_tok2 := r ->> 'token';
  v_res2 := pg_temp.res_id(v_tok2);
  PERFORM pg_temp.complete(v_tok2);
  ASSERT public._exos_partner_ticket_answers(v_res2, v_tk) = '[]'::jsonb, 'AL3 a ticket of another reservation: nothing';
  -- The organizer's read (p_partner_id NULL) of its own order: unchanged (no answers added).
  r := pg_temp.reserve(jsonb_build_array(pg_temp.line('ga', 1)), jsonb_build_object('tickets',
         jsonb_build_array(jsonb_build_object(pg_temp.q('size'), 'M'))), 'org');
  PERFORM pg_temp.complete(r ->> 'token', 'org');
  o := public._exos_partner_order(pg_temp.u('A'), NULL, pg_temp.res_id(r ->> 'token'), 'https://exos.test');
  ASSERT o IS NOT NULL AND NOT (o -> 'tickets' -> 0 ? 'answers'), 'AL3 organizer read unchanged: ' || o::text;
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_question_answers WHERE order_ref = 'po:' || pg_temp.res_id(r ->> 'token')
                      AND partner_reservation_id IS NOT NULL), 'AL3 an organizer reservation''s answers have no partner origin';
  RAISE NOTICE 'OK  AL3 partner order reads: only the partner''s own answers (later door / holder answers left out), hidden left out, own orders only';
END $$;

-- AL4 -------------------------------------------------------------------------
-- An add-on with its own entry code; b1 bought 3 units at e1; a list that admits it.
INSERT INTO public.exos_event_addons (id, event_id, name, price, capacity, separate_access_barcode) VALUES
  (pg_temp.u('ad1'), pg_temp.u('e1'), 'VIP lounge', 30, 100, true);
INSERT INTO public.exos_checkout_sessions (session_id, event_id, org_id, buyer_uid, buyer_email, guest, quantity, amount_cents, currency, status) VALUES
  ('cs_al11', pg_temp.u('e1'), pg_temp.u('A'), pg_temp.u('b1'), 'al11-b1@x.com', false, 1, 11000, 'usd', 'fulfilled');
INSERT INTO public.exos_tickets (id, event_id, org_id, tier_id, tier_name, buyer_id, owner_id, buyer_email, status, barcode_secret, price_paid, order_ref, channel_source) VALUES
  (pg_temp.u('k1'), pg_temp.u('e1'), pg_temp.u('A'), pg_temp.u('ga'), 'GA', pg_temp.u('b1'), pg_temp.u('b1'), 'al11-b1@x.com', 'active', 'sek-al11', 20, 'cs_al11', 'stripe');
INSERT INTO public.exos_order_addons (id, event_id, org_id, addon_id, addon_name, buyer_id, owner_id, quantity, unit_price_paid, order_ref, channel_source) VALUES
  (pg_temp.u('l1'), pg_temp.u('e1'), pg_temp.u('A'), pg_temp.u('ad1'), 'VIP lounge', pg_temp.u('b1'), pg_temp.u('b1'), 3, 30, 'cs_al11', 'stripe');
INSERT INTO public.exos_checkin_lists (id, event_id, org_id, name, admits, addon_ids, allow_reentry, sort_order) VALUES
  (pg_temp.u('ll'), pg_temp.u('e1'), NULL, 'VIP lounge', 'addons', ARRAY[pg_temp.u('ad1')], false, 1);
DO $$
DECLARE
  p1 uuid := pg_temp.pass('l1', 1); p2 uuid := pg_temp.pass('l1', 2); p3 uuid := pg_temp.pass('l1', 3);
  r jsonb; s text; who text; k jsonb; v_old_a text; v_old_g text; i int;
BEGIN
  ASSERT p1 IS NOT NULL AND p2 IS NOT NULL AND p3 IS NOT NULL, 'AL4 three passes';
  -- Not the holder: 42501, the pass unnamed. Nobody signed in: 42501.
  FOREACH who IN ARRAY ARRAY['oa', 'sa', 'ob', 'b2'] LOOP
    PERFORM pg_temp.act(pg_temp.u(who));
    s := pg_temp.st(format('SELECT public.exos_wallet_addon_reissue(%L)', p1));
    ASSERT s LIKE '42501 exos_wallet_addon_reissue: not your add-on pass%' AND s NOT LIKE '%VIP%', 'AL4 not the holder: ' || who || ' ' || s;
  END LOOP;
  PERFORM pg_temp.act(NULL);
  ASSERT pg_temp.st(format('SELECT public.exos_wallet_addon_reissue(%L)', p1)) LIKE '42501%not authenticated%', 'AL4 nobody';
  -- Never in a wallet: nothing to reissue.
  PERFORM pg_temp.act(pg_temp.u('b1'));
  r := public.exos_wallet_addon_reissue(p1);
  ASSERT NOT (r ->> 'ok')::boolean AND r ->> 'reason' = 'no-pass', 'AL4 no wallet pass yet: ' || r::text;
  ASSERT (SELECT wallet_epoch IS NULL FROM public.exos_addon_passes WHERE id = p1), 'AL4 nothing changed';
  -- In a wallet (epoch 1); the app sees the epoch.
  r := public.exos_wallet_addon_pass(p1);
  ASSERT (r -> 'payload' ->> 'code_epoch')::int = 1, 'AL4 issued: ' || r::text;
  ASSERT (SELECT (x ->> 'wallet_epoch')::int FROM jsonb_array_elements(public.exos_my_addon_passes(pg_temp.u('e1'))) x
           WHERE x ->> 'id' = p1::text) = 1
     AND (SELECT x -> 'wallet_epoch' FROM jsonb_array_elements(public.exos_my_addon_passes(pg_temp.u('e1'))) x
           WHERE x ->> 'id' = p2::text) = 'null'::jsonb, 'AL4 exos_my_addon_passes shows the epoch';
  v_old_a := pg_temp.wapple(p1, 1);
  v_old_g := pg_temp.wgoogle(p1, 1);
  -- Reissue: the epoch moves, a fresh payload comes back.
  r := public.exos_wallet_addon_reissue(p1);
  ASSERT (r ->> 'ok')::boolean AND (r ->> 'reissued')::boolean AND (r ->> 'code_epoch')::int = 2
     AND (r -> 'payload' ->> 'code_epoch')::int = 2 AND r -> 'payload' ->> 'apple_code' = pg_temp.wapple(p1, 2)
     AND r -> 'payload' ->> 'google_pattern' LIKE '%:g2:{totp_value_0}' AND (r ->> 'reissues_left')::int = 4
     AND r::text NOT LIKE '%barcode_secret%', 'AL4 reissued: ' || r::text;
  ASSERT r -> 'payload' ->> 'apple_code' <> v_old_a, 'AL4 a new Apple code';
  ASSERT (SELECT old_epoch = 1 AND new_epoch = 2 AND holder_id = pg_temp.u('b1') AND org_id = pg_temp.u('A') AND event_id = pg_temp.u('e1')
            FROM public.exos_addon_wallet_reissues WHERE pass_id = p1), 'AL4 logged';
  PERFORM pg_temp.act(NULL);
  ASSERT (SELECT count(*) FROM public.exos_org_audit WHERE entity_id = p1::text AND action = 'addon_pass.wallet_reissue'
           AND changes -> 'wallet_epoch' = '[1, 2]'::jsonb AND actor_uid = pg_temp.u('b1')) = 1, 'AL4 one audit row';
  -- The door: the old codes are refused (Apple and Google), the new one admits.
  PERFORM pg_temp.act(pg_temp.u('sa'));
  r := pg_temp.scan(p1, v_old_a);
  ASSERT r ->> 'reason' = 'barcode-rejected', 'AL4 the old Apple code: ' || r::text;
  r := pg_temp.scan(p1, v_old_g);
  ASSERT r ->> 'reason' = 'barcode-rejected', 'AL4 the old Google code: ' || r::text;
  -- The offline replay of an old code scanned a minute ago: refused at the merge.
  r := public.exos_check_in_offline(pg_temp.u('r1'), p1, pg_temp.u('e1'), now() - interval '1 minute',
                                    pg_temp.wgoogle(p1, 1, now() - interval '1 minute'), 'camera', NULL, 'Door AL',
                                    pg_temp.u('ll'), 'entry');
  ASSERT NOT coalesce((r ->> 'ok')::boolean, false), 'AL4 offline replay of the old code: ' || r::text;
  ASSERT (SELECT status = 'active' FROM public.exos_addon_passes WHERE id = p1), 'AL4 still unused';
  -- The door's saved keys moved to epoch 2.
  k := (SELECT x -> 'door_keys' FROM jsonb_array_elements(public.exos_event_addon_passes(pg_temp.u('e1'))) x WHERE x ->> 'id' = p1::text);
  ASSERT (k ->> 'we')::int = 2 AND k ->> 'wa' = encode(extensions.digest(pg_temp.wapple(p1, 2), 'sha256'), 'hex'), 'AL4 door keys: ' || k::text;
  r := pg_temp.scan(p1, pg_temp.wapple(p1, 2));
  ASSERT (r ->> 'ok')::boolean AND r ->> 'kind' = 'addon', 'AL4 the new Apple code admits: ' || r::text;
  -- 5 a day per holder, across the holder's passes: 4 more (p2 needs a wallet pass first), then refused.
  PERFORM pg_temp.act(pg_temp.u('b1'));
  PERFORM public.exos_wallet_addon_pass(p2);
  FOR i IN 1..4 LOOP
    r := public.exos_wallet_addon_reissue(CASE WHEN i % 2 = 0 THEN p1 ELSE p2 END);
    ASSERT (r ->> 'ok')::boolean AND (r ->> 'reissues_left')::int = 4 - i, 'AL4 reissue ' || i || ': ' || r::text;
  END LOOP;
  r := public.exos_wallet_addon_reissue(p2);
  ASSERT NOT (r ->> 'ok')::boolean AND r ->> 'reason' = 'rate-limited' AND (r ->> 'limit')::int = 5
     AND (r ->> 'retry_after_seconds')::int BETWEEN 1 AND 86400, 'AL4 the sixth: ' || r::text;
  ASSERT (SELECT wallet_epoch FROM public.exos_addon_passes WHERE id = p2) = 3, 'AL4 the refused one changed nothing';
  ASSERT (SELECT count(*) FROM public.exos_addon_wallet_reissues WHERE holder_id = pg_temp.u('b1')) = 5, 'AL4 five logged';
  -- A day later the window has room again.
  UPDATE public.exos_addon_wallet_reissues SET created_at = created_at - interval '25 hours'
   WHERE holder_id = pg_temp.u('b1') AND created_at = (SELECT min(created_at) FROM public.exos_addon_wallet_reissues WHERE holder_id = pg_temp.u('b1'));
  r := public.exos_wallet_addon_reissue(p2);
  ASSERT (r ->> 'ok')::boolean AND (r ->> 'code_epoch')::int = 4, 'AL4 after the window: ' || r::text;
  -- A voided pass is not reissued.
  PERFORM pg_temp.act(NULL);
  UPDATE public.exos_addon_passes SET status = 'voided' WHERE id = p3;
  PERFORM pg_temp.act(pg_temp.u('b1'));
  r := public.exos_wallet_addon_reissue(p3);
  ASSERT NOT (r ->> 'ok')::boolean AND r ->> 'reason' = 'voided', 'AL4 voided: ' || r::text;
  PERFORM pg_temp.act(NULL);
  RAISE NOTICE 'OK  AL4 add-on wallet reissue: holder only, epoch moves, door refuses old codes (online, offline), keys, 5 a day, logged';
END $$;

-- AL4 RLS on the log, as the client role.
SET LOCAL ROLE authenticated;
DO $$
DECLARE who text; n int;
BEGIN
  FOREACH who IN ARRAY ARRAY['oa', 'ma', 'b1', 'sa', 'ob', 'b2'] LOOP
    PERFORM set_config('app.uid', md5('al11:' || who)::uuid::text, true);
    SELECT count(*) INTO n FROM public.exos_addon_wallet_reissues WHERE org_id = md5('al11:A')::uuid;
    ASSERT (who IN ('oa', 'ma', 'b1') AND n = 6) OR (who IN ('sa', 'ob', 'b2') AND n = 0), 'AL4 RLS ' || who || ': ' || n;
  END LOOP;
  BEGIN
    INSERT INTO public.exos_addon_wallet_reissues (org_id, event_id, pass_id, holder_id, old_epoch, new_epoch)
    VALUES (md5('al11:A')::uuid, md5('al11:e1')::uuid, gen_random_uuid(), md5('al11:b1')::uuid, 1, 2);
    RAISE EXCEPTION 'AL4 a client wrote the log';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  RAISE NOTICE 'OK  AL4 the log''s RLS: holder, owner and manager read; scanner, another org, another buyer don''t; no client writes';
END $$;
RESET ROLE;
SET LOCAL ROLE anon;
DO $$ BEGIN
  PERFORM public.exos_wallet_addon_reissue(md5('al11:x')::uuid);
  RAISE EXCEPTION 'AL4 anon called the reissue';
EXCEPTION WHEN insufficient_privilege THEN NULL;
END $$;
RESET ROLE;

ROLLBACK;
