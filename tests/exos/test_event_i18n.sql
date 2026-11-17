-- ============================================================================
-- Spanish (mig 20261114130000). Self-contained (e1500000… ids), rolled back.
--   ES1 shape: exos_events.i18n defaults to {}; the CHECK takes only
--       {"es": {"title"?, "description"?}}, non-blank strings, title <= 200
--       with no control characters, description <= 20000; the helper and the
--       trigger function are not callable by anon / signed-in users
--   ES2 roles: owner and manager of the org set it (the event's own RLS);
--       finance, scanner, an outsider, the other org's owner and anon change
--       nothing; the CHECK holds for an owner too
--   ES3 public read: anon reads i18n of a published event (table and
--       exos_public_events), never of a draft; anon can't write it
--   ES4 order language: exos_checkout_sessions.lang takes en / es / null only
--   ES5 mail language: a buyer mail gets the recipient's latest order
--       language, else their account's choice, else English; another
--       buyer's orders don't count; organizer mail gets none; a lang the
--       caller set is kept; the real queue path (exos_queue_ticket_issued)
--       is stamped too and its subject stays English (its dedupe still works)
-- Users: f1 owner A, f2 manager A, f3 finance A, f4 scanner A, f5 owner B,
--        f6 outsider, f7 buyer (es order), f8 buyer (account says es).
-- ============================================================================
\set ON_ERROR_STOP on
BEGIN;

CREATE FUNCTION pg_temp.u(p text) RETURNS uuid LANGUAGE sql IMMUTABLE AS $$
  SELECT ('e1500000-0000-0000-0000-' || lpad(p, 12, '0'))::uuid
$$;
CREATE FUNCTION pg_temp.act(p_uid uuid) RETURNS void LANGUAGE sql AS $$
  SELECT set_config('app.uid', coalesce(p_uid::text, ''), true);
$$;
GRANT EXECUTE ON FUNCTION pg_temp.act(uuid) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION pg_temp.u(text) TO anon, authenticated;
CREATE FUNCTION pg_temp.st(p_sql text) RETURNS text LANGUAGE plpgsql AS $$
BEGIN
  EXECUTE p_sql;
  RETURN 'ok';
EXCEPTION WHEN OTHERS THEN RETURN SQLSTATE;
END $$;
GRANT EXECUTE ON FUNCTION pg_temp.st(text) TO anon, authenticated;
-- Rows an UPDATE of e1's i18n touched, as the current role and app.uid.
CREATE FUNCTION pg_temp.set_es(p_title text) RETURNS int LANGUAGE plpgsql AS $$
DECLARE n int;
BEGIN
  UPDATE public.exos_events SET i18n = jsonb_build_object('es', jsonb_build_object('title', p_title))
   WHERE id = pg_temp.u('e1');
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
EXCEPTION WHEN insufficient_privilege THEN RETURN -1;
END $$;
GRANT EXECUTE ON FUNCTION pg_temp.set_es(text) TO anon, authenticated;

INSERT INTO auth.users (id, email, email_confirmed_at, raw_user_meta_data) VALUES
  (pg_temp.u('f1'), 'e15-oa@x.com', now(), NULL), (pg_temp.u('f2'), 'e15-ma@x.com', now(), NULL),
  (pg_temp.u('f3'), 'e15-fa@x.com', now(), NULL), (pg_temp.u('f4'), 'e15-sa@x.com', now(), NULL),
  (pg_temp.u('f5'), 'e15-ob@x.com', now(), NULL), (pg_temp.u('f6'), 'e15-x1@x.com', now(), NULL),
  (pg_temp.u('f7'), 'e15-buyer@x.com', now(), '{"lang": "en"}'),
  (pg_temp.u('f8'), 'e15-cuenta@x.com', now(), '{"lang": "es"}');
INSERT INTO public.exos_orgs (id, name, slug, owner_uid) VALUES
  (pg_temp.u('1'), 'E15 Salón', 'e15-salon', pg_temp.u('f1')),
  (pg_temp.u('2'), 'E15 Elsewhere', 'e15-elsewhere', pg_temp.u('f5'));
INSERT INTO public.exos_org_memberships (org_id, user_id, role) VALUES
  (pg_temp.u('1'), pg_temp.u('f1'), 'owner'), (pg_temp.u('1'), pg_temp.u('f2'), 'manager'),
  (pg_temp.u('1'), pg_temp.u('f3'), 'finance'), (pg_temp.u('1'), pg_temp.u('f4'), 'scanner'),
  (pg_temp.u('2'), pg_temp.u('f5'), 'owner');
INSERT INTO public.exos_events (id, org_id, name, slug, status, starts_at, timezone, total_tickets, created_by) VALUES
  (pg_temp.u('e1'), pg_temp.u('1'), 'E15 Salsa Night', 'e15-salsa', 'published', now() + interval '10 days', 'America/New_York', 100, pg_temp.u('f1')),
  (pg_temp.u('e2'), pg_temp.u('1'), 'E15 Draft', 'e15-draft', 'draft', now() + interval '20 days', 'America/New_York', 100, pg_temp.u('f1'));
INSERT INTO public.exos_ticket_tiers (id, event_id, name, price, capacity) VALUES
  (pg_temp.u('a1'), pg_temp.u('e1'), 'General', 20, 100);

-- ES1 ------------------------------------------------------------------------
DO $$
DECLARE bad jsonb;
BEGIN
  ASSERT (SELECT i18n = '{}'::jsonb FROM public.exos_events WHERE id = pg_temp.u('e1')), 'ES1 default {}';
  ASSERT public._exos_event_i18n_ok('{}'), 'ES1 {} ok';
  ASSERT public._exos_event_i18n_ok('{"es": {}}'), 'ES1 empty es ok';
  ASSERT public._exos_event_i18n_ok('{"es": {"title": "Noche de Salsa", "description": "Baile\ntoda la noche"}}'), 'ES1 full ok';
  FOREACH bad IN ARRAY ARRAY[
    'null'::jsonb, '[]', '"es"', '{"fr": {"title": "x"}}', '{"es": "Noche"}', '{"es": {"name": "x"}}',
    '{"es": {"title": 5}}', '{"es": {"title": "  "}}', '{"es": {"title": "a\u0007b"}}', '{"es": {"title": "a\nb"}}',
    '{"es": {"description": ""}}', '{"es": {"description": ["x"]}}',
    jsonb_build_object('es', jsonb_build_object('title', repeat('x', 201))),
    jsonb_build_object('es', jsonb_build_object('description', repeat('x', 20001)))] LOOP
    ASSERT NOT public._exos_event_i18n_ok(bad), 'ES1 refuses ' || left(bad::text, 60);
  END LOOP;
  ASSERT public._exos_event_i18n_ok(jsonb_build_object('es', jsonb_build_object('title', repeat('x', 200),
    'description', repeat('y', 20000)))), 'ES1 caps are inclusive';
  ASSERT pg_temp.st($q$UPDATE public.exos_events SET i18n = '{"es": {"title": ""}}' WHERE id = pg_temp.u('e1')$q$) = '23514',
    'ES1 CHECK on the table';
  ASSERT pg_temp.st($q$UPDATE public.exos_events SET i18n = NULL WHERE id = pg_temp.u('e1')$q$) = '23502', 'ES1 NOT NULL';
  ASSERT NOT has_function_privilege('anon', 'public._exos_event_i18n_ok(jsonb)', 'EXECUTE'), 'ES1 helper not anon';
  FOREACH bad IN ARRAY ARRAY['"anon"', '"authenticated"']::jsonb[] LOOP
    ASSERT NOT has_function_privilege(bad #>> '{}', 'public._exos_buyer_lang(text)', 'EXECUTE'), 'ES1 buyer_lang ' || bad::text;
    ASSERT NOT has_function_privilege(bad #>> '{}', 'public._exos_mail_set_lang()', 'EXECUTE'), 'ES1 trigger fn ' || bad::text;
  END LOOP;
  ASSERT (SELECT p.prosecdef AND p.proconfig @> ARRAY['search_path=public, pg_temp']
            FROM pg_proc p WHERE p.oid = 'public._exos_buyer_lang(text)'::regprocedure), 'ES1 buyer_lang definer + search_path';
  RAISE NOTICE 'OK  ES1 i18n shape, caps and grants';
END $$;

-- ES2 ------------------------------------------------------------------------
SET LOCAL ROLE authenticated;
SELECT pg_temp.act(pg_temp.u('f1'));
DO $$ BEGIN ASSERT pg_temp.set_es('Noche de Salsa') = 1, 'ES2 owner sets it'; END $$;
SELECT pg_temp.act(pg_temp.u('f2'));
DO $$ BEGIN ASSERT pg_temp.set_es('Noche de Salsa (gerente)') = 1, 'ES2 manager sets it'; END $$;
DO $$ BEGIN
  ASSERT pg_temp.st($q$UPDATE public.exos_events SET i18n = '{"es": {"title": "x", "precio": "0"}}' WHERE id = pg_temp.u('e1')$q$) = '23514',
    'ES2 the CHECK holds for a manager';
END $$;
SELECT pg_temp.act(pg_temp.u('f3'));
DO $$ BEGIN ASSERT pg_temp.set_es('finanzas') <= 0, 'ES2 finance changes nothing'; END $$;
SELECT pg_temp.act(pg_temp.u('f4'));
DO $$ BEGIN ASSERT pg_temp.set_es('escáner') <= 0, 'ES2 scanner changes nothing'; END $$;
SELECT pg_temp.act(pg_temp.u('f5'));
DO $$ BEGIN ASSERT pg_temp.set_es('otra org') <= 0, 'ES2 the other org''s owner changes nothing'; END $$;
SELECT pg_temp.act(pg_temp.u('f6'));
DO $$ BEGIN ASSERT pg_temp.set_es('extraño') <= 0, 'ES2 an outsider changes nothing'; END $$;
RESET ROLE;
SET LOCAL ROLE anon;
SELECT pg_temp.act(NULL);
DO $$ BEGIN ASSERT pg_temp.set_es('anónimo') <= 0, 'ES2 anon changes nothing'; END $$;
RESET ROLE;
DO $$ BEGIN
  ASSERT (SELECT i18n #>> '{es,title}' FROM public.exos_events WHERE id = pg_temp.u('e1')) = 'Noche de Salsa (gerente)',
    'ES2 only owner / manager writes landed';
  RAISE NOTICE 'OK  ES2 owner / manager only, the CHECK for everyone';
END $$;

-- ES3 ------------------------------------------------------------------------
UPDATE public.exos_events SET i18n = '{"es": {"title": "Borrador"}}' WHERE id = pg_temp.u('e2');
SET LOCAL ROLE anon;
SELECT pg_temp.act(NULL);
DO $$ BEGIN
  ASSERT (SELECT i18n #>> '{es,title}' FROM public.exos_public_events WHERE id = pg_temp.u('e1')) = 'Noche de Salsa (gerente)',
    'ES3 the public view carries i18n';
  ASSERT (SELECT i18n #>> '{es,title}' FROM public.exos_events WHERE id = pg_temp.u('e1')) = 'Noche de Salsa (gerente)',
    'ES3 anon reads the column of a published event';
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_public_events WHERE id = pg_temp.u('e2')), 'ES3 no draft in the view';
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_events WHERE id = pg_temp.u('e2')), 'ES3 no draft in the table';
  ASSERT NOT has_column_privilege('anon', 'public.exos_events', 'i18n', 'UPDATE'), 'ES3 anon has no UPDATE on i18n';
  ASSERT NOT has_column_privilege('anon', 'public.exos_events', 'i18n', 'INSERT'), 'ES3 anon has no INSERT on i18n';
  RAISE NOTICE 'OK  ES3 public read of published events only';
END $$;
RESET ROLE;

-- ES4 ------------------------------------------------------------------------
INSERT INTO public.exos_checkout_sessions (session_id, event_id, tier_id, org_id, buyer_uid, buyer_email, guest, quantity, amount_cents, status, created_at, lang)
VALUES ('e15-s1', pg_temp.u('e1'), pg_temp.u('a1'), pg_temp.u('1'), pg_temp.u('f7'), 'e15-buyer@x.com', false, 1, 2000, 'fulfilled', now() - interval '2 days', 'en'),
       ('e15-s2', pg_temp.u('e1'), pg_temp.u('a1'), pg_temp.u('1'), pg_temp.u('f7'), 'E15-Buyer@x.com', false, 1, 2000, 'fulfilled', now() - interval '1 day', 'es'),
       ('e15-s3', pg_temp.u('e1'), pg_temp.u('a1'), pg_temp.u('1'), NULL, 'e15-guest@x.com', true, 1, 2000, 'fulfilled', now(), NULL),
       ('e15-s4', pg_temp.u('e1'), pg_temp.u('a1'), pg_temp.u('1'), NULL, 'e15-other@x.com', true, 1, 2000, 'fulfilled', now(), 'es');
DO $$ BEGIN
  ASSERT pg_temp.st($q$INSERT INTO public.exos_checkout_sessions (session_id, event_id, org_id, buyer_email, guest, quantity, amount_cents, status, lang)
    VALUES ('e15-bad', pg_temp.u('e1'), pg_temp.u('1'), 'z@x.com', true, 1, 0, 'pending', 'fr')$q$) = '23514', 'ES4 lang is en / es';
  RAISE NOTICE 'OK  ES4 order language en / es / null';
END $$;

-- ES5 ------------------------------------------------------------------------
DO $$
DECLARE v text;
BEGIN
  -- latest order with a language (the later 'es' one, any email case)
  INSERT INTO public.exos_mail (template, to_email, subject, html, status)
  VALUES ('ticket-issued', 'e15-buyer@x.com', 'Your ticket for E15 Salsa Night is ready', '<p>x</p>', 'pending') RETURNING lang INTO v;
  ASSERT v = 'es', 'ES5 latest order language: ' || coalesce(v, 'null');
  -- no order language: the account's choice
  INSERT INTO public.exos_mail (template, to_email, subject, html, status)
  VALUES ('transfer-initiated', 'e15-cuenta@x.com', 'Someone sent you a ticket', '<p>x</p>', 'pending') RETURNING lang INTO v;
  ASSERT v = 'es', 'ES5 account language';
  -- nothing known (an order without a language): English
  INSERT INTO public.exos_mail (template, to_email, subject, html, status)
  VALUES ('refund-issued', 'e15-guest@x.com', 's', '', 'pending') RETURNING lang INTO v;
  ASSERT v = 'en', 'ES5 English by default';
  -- organizer mail: no language stamped
  INSERT INTO public.exos_mail (template, to_email, subject, html, status)
  VALUES ('org-sales-digest', 'e15-other@x.com', 's', '<p>x</p>', 'pending') RETURNING lang INTO v;
  ASSERT v IS NULL, 'ES5 organizer mail untouched';
  -- a language the caller chose is kept
  INSERT INTO public.exos_mail (template, to_email, subject, html, status, lang)
  VALUES ('ticket-issued', 'e15-other@x.com', 's', '<p>x</p>', 'pending', 'en') RETURNING lang INTO v;
  ASSERT v = 'en', 'ES5 explicit lang kept';
  ASSERT pg_temp.st($q$INSERT INTO public.exos_mail (template, to_email, subject, html, status, lang)
    VALUES ('ticket-issued', 'z@x.com', 's', '<p>x</p>', 'pending', 'pt')$q$) = '23514', 'ES5 mail lang is en / es';
  RAISE NOTICE 'OK  ES5 buyer mail language: order, then account, then English';
END $$;

-- The real path: the owner's ticket-issued mail, stamped Spanish, English row.
INSERT INTO public.exos_tickets (id, event_id, org_id, tier_id, tier_name, owner_id, buyer_id, status, barcode_secret)
VALUES (pg_temp.u('b1'), pg_temp.u('e1'), pg_temp.u('1'), pg_temp.u('a1'), 'General', pg_temp.u('f7'), pg_temp.u('f7'), 'active', repeat('ab', 16));
SET LOCAL ROLE authenticated;
SELECT pg_temp.act(pg_temp.u('f7'));
SELECT public.exos_queue_ticket_issued(pg_temp.u('b1'));
RESET ROLE;
DO $$
DECLARE m record;
BEGIN
  SELECT * INTO m FROM public.exos_mail WHERE to_email = 'e15-buyer@x.com' AND subject LIKE 'Your ticket for E15 Salsa Night is ready'
   ORDER BY created_at DESC LIMIT 1;
  ASSERT m.lang = 'es', 'ES5 queue path stamped es';
  ASSERT m.subject = 'Your ticket for E15 Salsa Night is ready', 'ES5 the stored subject stays English';
  RAISE NOTICE 'OK  ES5 the queue path is stamped, its row stays English';
END $$;

ROLLBACK;
