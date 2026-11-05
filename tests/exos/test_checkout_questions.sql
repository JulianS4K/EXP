-- ============================================================================
-- Checkout questions (mig 20261106110000, docs/checkout-questions.md):
--   CQ1  grants: tables are read-only to authenticated (RLS), nothing for
--        anon; the cores and the triggers have no client grant; only
--        exos_public_event_questions is anon (H3 allowlist)
--   CQ2  the builder: owner / manager save; finance, scanner, content,
--        another org's owner and anon can't; bad definitions are refused
--        (options, limits, a ticket type of another event)
--   CQ3  paid checkout: required / choice / length refused before payment;
--        the answers sit on the pending order and attach to the right
--        tickets at fulfillment (ticket 1 -> first ticket minted); a retry
--        records nothing twice; per-ticket questions limited to a ticket type
--   CQ4  free claim: the plain claim refuses to skip required questions;
--        the answered claim attaches per-ticket answers; a retry returns the
--        same tickets; an event with optional questions only is unchanged;
--        another buyer can't reuse an order ref
--   CQ5  a guest's paid order: tickets parked until proof of email, answers
--        attached to the same tickets before and after; the buyer reads
--        them once the tickets are theirs
--   CQ6  who reads answers: owner, manager, finance (all); the buyer (own);
--        door staff (per-ticket of their event only); not content, not a
--        stranger, not another org's owner, not anon
--   CQ7  changing a question after sales: a renamed question keeps the old
--        answers' label; its kind / scope can't change; archived keeps
--        answers and is refused at checkout; made required, old orders stay
--   CQ8  the door: staff of the event add a (hidden) per-ticket answer; a
--        scanner of another event can't
--   CQ9  phone RSVP: a refused answer expires the RSVP; the RSVP's tickets
--        take its answers
--   CQ10 API cores: cross-org isolation, reorder, answers per ticket / order
--   CQ11 the public questions: no hidden / archived ones, nothing of a draft
--   CQ12 TS/SQL parity: the cases between the CQ-CASES markers, which
--        src/lib/checkoutQuestions.test.ts runs through _shared/questions.ts
--   CQ13 no hijack through order_ref: buyer B minting (free claim, answered
--        claim, any other insert) with buyer A's order ref is refused or
--        takes none of A's answers; A's tickets still get them; parked
--        tickets (guest, unconfirmed account) still do
--   CQ14 no cross-tenant label leak: a validation error names only the
--        event's own questions, never an unknown question's label
-- Self-contained (BEGIN / ROLLBACK), prefix c9e0.
-- ============================================================================
\set ON_ERROR_STOP on
BEGIN;

INSERT INTO auth.users (id, email, email_confirmed_at) VALUES
  ('c9e00000-0000-0000-0000-0000000000a1', 'cq-owner@x.com', now()),
  ('c9e00000-0000-0000-0000-0000000000a2', 'cq-manager@x.com', now()),
  ('c9e00000-0000-0000-0000-0000000000a3', 'cq-scanner@x.com', now()),
  ('c9e00000-0000-0000-0000-0000000000a4', 'cq-finance@x.com', now()),
  ('c9e00000-0000-0000-0000-0000000000a5', 'cq-content@x.com', now()),
  ('c9e00000-0000-0000-0000-0000000000a6', 'cq-scanner2@x.com', now()),
  ('c9e00000-0000-0000-0000-0000000000b1', 'cq-other@x.com', now()),
  ('c9e00000-0000-0000-0000-0000000000f1', 'cq-fan@x.com', now()),
  ('c9e00000-0000-0000-0000-0000000000f2', 'cq-fan2@x.com', now()),
  ('c9e00000-0000-0000-0000-0000000000f3', 'cq-guest@x.com', now()),
  ('c9e00000-0000-0000-0000-0000000000f4', 'cq-unconfirmed@x.com', NULL);
INSERT INTO public.exos_orgs (id, name, slug, owner_uid) VALUES
  ('c9e00000-0000-0000-0000-000000000001', 'CQ Org', 'cq-org', 'c9e00000-0000-0000-0000-0000000000a1'),
  ('c9e00000-0000-0000-0000-000000000002', 'CQ Other', 'cq-other', 'c9e00000-0000-0000-0000-0000000000b1');
INSERT INTO public.exos_org_memberships (org_id, user_id, role) VALUES
  ('c9e00000-0000-0000-0000-000000000001', 'c9e00000-0000-0000-0000-0000000000a1', 'owner'),
  ('c9e00000-0000-0000-0000-000000000001', 'c9e00000-0000-0000-0000-0000000000a2', 'manager'),
  ('c9e00000-0000-0000-0000-000000000001', 'c9e00000-0000-0000-0000-0000000000a3', 'scanner'),
  ('c9e00000-0000-0000-0000-000000000001', 'c9e00000-0000-0000-0000-0000000000a4', 'finance'),
  ('c9e00000-0000-0000-0000-000000000001', 'c9e00000-0000-0000-0000-0000000000a5', 'content'),
  ('c9e00000-0000-0000-0000-000000000001', 'c9e00000-0000-0000-0000-0000000000a6', 'scanner'),
  ('c9e00000-0000-0000-0000-000000000002', 'c9e00000-0000-0000-0000-0000000000b1', 'owner');
-- e1 paid (GA + VIP), e2 free (questions required), e3 free (optional only), e4 draft, e9 org B.
INSERT INTO public.exos_events (id, org_id, name, slug, status, total_tickets, tickets_sold, currency, created_by) VALUES
  ('c9e00000-0000-0000-0000-0000000000e1', 'c9e00000-0000-0000-0000-000000000001', 'CQ Show', 'cq-show', 'published', 0, 0, 'usd', 'c9e00000-0000-0000-0000-0000000000a1'),
  ('c9e00000-0000-0000-0000-0000000000e2', 'c9e00000-0000-0000-0000-000000000001', 'CQ Free', 'cq-free', 'published', 0, 0, 'usd', 'c9e00000-0000-0000-0000-0000000000a1'),
  ('c9e00000-0000-0000-0000-0000000000e3', 'c9e00000-0000-0000-0000-000000000001', 'CQ Easy', 'cq-easy', 'published', 0, 0, 'usd', 'c9e00000-0000-0000-0000-0000000000a1'),
  ('c9e00000-0000-0000-0000-0000000000e4', 'c9e00000-0000-0000-0000-000000000001', 'CQ Draft', 'cq-draft', 'draft', 0, 0, 'usd', 'c9e00000-0000-0000-0000-0000000000a1'),
  ('c9e00000-0000-0000-0000-0000000000e9', 'c9e00000-0000-0000-0000-000000000002', 'CQ Else', 'cq-else', 'published', 0, 0, 'usd', 'c9e00000-0000-0000-0000-0000000000b1');
INSERT INTO public.exos_ticket_tiers (id, event_id, name, price, capacity, sold) VALUES
  ('c9e00000-0000-0000-0000-0000000000d1', 'c9e00000-0000-0000-0000-0000000000e1', 'GA', 20, 100, 0),
  ('c9e00000-0000-0000-0000-0000000000d2', 'c9e00000-0000-0000-0000-0000000000e1', 'VIP', 50, 50, 0),
  ('c9e00000-0000-0000-0000-0000000000d6', 'c9e00000-0000-0000-0000-0000000000e1', 'Free list', 0, 50, 0),
  ('c9e00000-0000-0000-0000-0000000000d3', 'c9e00000-0000-0000-0000-0000000000e2', 'Free', 0, 100, 0),
  ('c9e00000-0000-0000-0000-0000000000d4', 'c9e00000-0000-0000-0000-0000000000e3', 'Free', 0, 100, 0),
  ('c9e00000-0000-0000-0000-0000000000d5', 'c9e00000-0000-0000-0000-0000000000e4', 'GA', 10, 100, 0),
  ('c9e00000-0000-0000-0000-0000000000d9', 'c9e00000-0000-0000-0000-0000000000e9', 'GA', 10, 100, 0);
-- a6 scans e2 only.
INSERT INTO public.exos_event_staff (event_id, user_id, org_id) VALUES
  ('c9e00000-0000-0000-0000-0000000000e2', 'c9e00000-0000-0000-0000-0000000000a6', 'c9e00000-0000-0000-0000-000000000001');

CREATE FUNCTION pg_temp.act(p_uid uuid) RETURNS void LANGUAGE sql AS $$
  SELECT set_config('app.uid', coalesce(p_uid::text, ''), true),
         set_config('app.jwt', CASE WHEN p_uid IS NULL THEN '' ELSE
           json_build_object('email', (SELECT email FROM auth.users WHERE id = p_uid))::text END, true);
$$;
GRANT EXECUTE ON FUNCTION pg_temp.act(uuid) TO anon, authenticated;
-- Run SQL as a signed-in user (NULL: anon); the result as text, or 'ERR <sqlstate>: <message>'.
CREATE FUNCTION pg_temp.as_user(p_uid uuid, p_sql text) RETURNS text LANGUAGE plpgsql AS $$
DECLARE r text;
BEGIN
  PERFORM pg_temp.act(p_uid);
  IF p_uid IS NULL THEN SET LOCAL ROLE anon; ELSE SET LOCAL ROLE authenticated; END IF;
  EXECUTE p_sql INTO r;
  RESET ROLE;
  PERFORM pg_temp.act(NULL);
  RETURN r;
EXCEPTION WHEN OTHERS THEN
  RESET ROLE;
  PERFORM pg_temp.act(NULL);
  RETURN 'ERR ' || SQLSTATE || ': ' || SQLERRM;
END $$;
GRANT EXECUTE ON FUNCTION pg_temp.as_user(uuid, text) TO anon, authenticated;
-- A question id by label (on an event).
CREATE FUNCTION pg_temp.qid(p_event uuid, p_label text) RETURNS uuid LANGUAGE sql AS $$
  SELECT id FROM public.exos_event_questions WHERE event_id = p_event AND label = p_label ORDER BY created_at LIMIT 1;
$$;
GRANT EXECUTE ON FUNCTION pg_temp.qid(uuid, text) TO anon, authenticated;
-- A pending checkout session as exos-checkout records it.
CREATE FUNCTION pg_temp.session(p_id text, p_event uuid, p_tier uuid, p_qty int, p_buyer uuid, p_email text) RETURNS void
LANGUAGE sql AS $$
  INSERT INTO public.exos_checkout_sessions (session_id, event_id, tier_id, org_id, buyer_uid, buyer_email, guest,
                                             quantity, amount_cents, status, proof_token_hash)
  VALUES (p_id, p_event, p_tier, (SELECT org_id FROM public.exos_events WHERE id = p_event), p_buyer, p_email, p_buyer IS NULL,
          p_qty, 2000 * p_qty, 'pending',
          CASE WHEN p_buyer IS NULL THEN encode(extensions.digest('tok-' || p_id || '-0123456789abcdef', 'sha256'), 'hex') END);
$$;
CREATE FUNCTION pg_temp.err(p_sql text) RETURNS text LANGUAGE plpgsql AS $$
BEGIN
  EXECUTE p_sql;
  RETURN NULL;
EXCEPTION WHEN OTHERS THEN RETURN SQLSTATE || ': ' || SQLERRM;
END $$;

-- CQ1 ------------------------------------------------------------------------
DO $$
DECLARE f text; n int := 0;
BEGIN
  ASSERT NOT has_table_privilege('anon', 'public.exos_event_questions', 'SELECT'), 'CQ1: anon reads no questions table';
  ASSERT NOT has_table_privilege('anon', 'public.exos_question_answers', 'SELECT'), 'CQ1: anon reads no answers';
  ASSERT has_table_privilege('authenticated', 'public.exos_question_answers', 'SELECT'), 'CQ1: authenticated reads through RLS';
  ASSERT NOT has_table_privilege('authenticated', 'public.exos_question_answers', 'INSERT')
     AND NOT has_table_privilege('authenticated', 'public.exos_question_answers', 'UPDATE')
     AND NOT has_table_privilege('authenticated', 'public.exos_question_answers', 'DELETE'), 'CQ1: no direct answer writes';
  ASSERT NOT has_table_privilege('authenticated', 'public.exos_event_questions', 'INSERT')
     AND NOT has_table_privilege('authenticated', 'public.exos_event_questions', 'UPDATE')
     AND NOT has_table_privilege('authenticated', 'public.exos_event_questions', 'DELETE'), 'CQ1: no direct question writes';
  ASSERT NOT has_table_privilege('authenticated', 'public.exos_question_answer_cursors', 'SELECT'), 'CQ1: cursors are service only';
  ASSERT (SELECT relrowsecurity FROM pg_class WHERE oid = 'public.exos_event_questions'::regclass)
     AND (SELECT relrowsecurity FROM pg_class WHERE oid = 'public.exos_question_answers'::regclass)
     AND (SELECT relrowsecurity FROM pg_class WHERE oid = 'public.exos_question_answer_cursors'::regclass), 'CQ1: RLS on';
  FOREACH f IN ARRAY ARRAY[
    'public._exos_validate_answers_core(jsonb,uuid[],jsonb,boolean)', 'public._exos_validate_answers(uuid,uuid[],jsonb,boolean,boolean)',
    'public._exos_record_answers(uuid,uuid,text,uuid[],jsonb,boolean,boolean,text,uuid)',
    'public.exos_record_checkout_answers(text,jsonb)', 'public._exos_checkout_question_ctx(uuid,uuid,integer)',
    'public.exos_rsvp_questions(uuid)', 'public.exos_rsvp_record_answers(uuid,jsonb)',
    'public._exos_api_reservation_answers(uuid,text,jsonb)', 'public._exos_set_ticket_answers(uuid,jsonb,text)',
    'public._exos_api_questions(uuid,uuid)', 'public._exos_question_upsert(uuid,uuid,uuid,jsonb,uuid)',
    'public._exos_question_archive(uuid,uuid,boolean)', 'public._exos_questions_reorder(uuid,uuid,uuid[])',
    'public._exos_answers_for(uuid[],boolean)', 'public._exos_event_answer_rows(uuid)', 'public._exos_raise_answer_problem(jsonb,uuid)', 'public._exos_question_defs(uuid,boolean)',
    'public._exos_tg_ticket_answers_attach()', 'public._exos_tg_ticket_answers_buyer()', 'public._exos_required_questions_for(uuid,uuid[])'] LOOP
    ASSERT NOT has_function_privilege('anon', f, 'EXECUTE') AND NOT has_function_privilege('authenticated', f, 'EXECUTE'),
      'CQ1: no client grant on ' || f;
    n := n + 1;
  END LOOP;
  FOREACH f IN ARRAY ARRAY['public.exos_claim_free_tickets_answered(uuid,uuid,integer,text,text,text,jsonb)',
    'public.exos_door_set_ticket_answers(uuid,jsonb)', 'public.exos_list_event_questions(uuid)',
    'public.exos_save_event_question(uuid,jsonb,uuid)', 'public.exos_archive_event_question(uuid,boolean)',
    'public.exos_reorder_event_questions(uuid,uuid[])', 'public.exos_event_question_answers(uuid)'] LOOP
    ASSERT has_function_privilege('authenticated', f, 'EXECUTE') AND NOT has_function_privilege('anon', f, 'EXECUTE'),
      'CQ1: authenticated only: ' || f;
  END LOOP;
  ASSERT has_function_privilege('anon', 'public.exos_public_event_questions(uuid)', 'EXECUTE'), 'CQ1: public questions for anon';
  ASSERT (SELECT bool_and(prosecdef AND proconfig::text LIKE '%search_path=public, pg_temp%') FROM pg_proc
           WHERE pronamespace = 'public'::regnamespace AND prosecdef
             AND proname IN ('exos_public_event_questions', 'exos_claim_free_tickets_answered', '_exos_record_answers',
                             'exos_record_checkout_answers', 'exos_door_set_ticket_answers', '_exos_tg_ticket_answers_attach')),
    'CQ1: definers pin search_path';
  RAISE NOTICE 'OK  CQ1 grants: RLS read only, % cores service-only, anon gets the public questions only', n;
END $$;

-- CQ2 ------------------------------------------------------------------------
DO $$
DECLARE r text;
BEGIN
  r := pg_temp.as_user('c9e00000-0000-0000-0000-0000000000a1', $q$SELECT public.exos_save_event_question('c9e00000-0000-0000-0000-0000000000e1',
    '{"label":"T-shirt size","kind":"single_choice","options":["S","M","L"],"required":true,"scope":"ticket"}')::text$q$);
  ASSERT r NOT LIKE 'ERR%', 'CQ2: owner saves a question: ' || r;
  r := pg_temp.as_user('c9e00000-0000-0000-0000-0000000000a2', $q$SELECT public.exos_save_event_question('c9e00000-0000-0000-0000-0000000000e1',
    '{"label":"Company","kind":"text","max_length":20,"scope":"order"}')::text$q$);
  ASSERT r NOT LIKE 'ERR%', 'CQ2: manager saves a question: ' || r;
  PERFORM pg_temp.as_user('c9e00000-0000-0000-0000-0000000000a1', $q$SELECT public.exos_save_event_question('c9e00000-0000-0000-0000-0000000000e1',
    '{"label":"I agree to the photo policy","kind":"checkbox","required":true,"scope":"order"}')::text$q$);
  PERFORM pg_temp.as_user('c9e00000-0000-0000-0000-0000000000a1', $q$SELECT public.exos_save_event_question('c9e00000-0000-0000-0000-0000000000e1',
    '{"label":"Name on the VIP list","kind":"text","required":true,"scope":"ticket","tier_ids":["c9e00000-0000-0000-0000-0000000000d2"]}')::text$q$);
  PERFORM pg_temp.as_user('c9e00000-0000-0000-0000-0000000000a1', $q$SELECT public.exos_save_event_question('c9e00000-0000-0000-0000-0000000000e1',
    '{"label":"Wristband colour","kind":"text","scope":"ticket","hidden":true}')::text$q$);
  ASSERT (SELECT count(*) FROM public.exos_event_questions WHERE event_id = 'c9e00000-0000-0000-0000-0000000000e1') = 5, 'CQ2: five questions';
  ASSERT (SELECT array_agg(sort_order ORDER BY created_at) FROM public.exos_event_questions WHERE event_id = 'c9e00000-0000-0000-0000-0000000000e1')
         = ARRAY[0, 1, 2, 3, 4], 'CQ2: new questions go last';

  FOREACH r IN ARRAY ARRAY['c9e00000-0000-0000-0000-0000000000a4', 'c9e00000-0000-0000-0000-0000000000a3',
                           'c9e00000-0000-0000-0000-0000000000a5', 'c9e00000-0000-0000-0000-0000000000b1'] LOOP
    ASSERT pg_temp.as_user(r::uuid, $q$SELECT public.exos_save_event_question('c9e00000-0000-0000-0000-0000000000e1',
      '{"label":"x","kind":"text"}')::text$q$) LIKE 'ERR 42501%', 'CQ2: refused for ' || r;
  END LOOP;
  ASSERT pg_temp.as_user(NULL, $q$SELECT public.exos_save_event_question('c9e00000-0000-0000-0000-0000000000e1','{"label":"x","kind":"text"}')::text$q$)
         LIKE 'ERR 42501%', 'CQ2: anon refused';

  -- Bad definitions.
  ASSERT pg_temp.err($q$SELECT public._exos_question_upsert('c9e00000-0000-0000-0000-000000000001','c9e00000-0000-0000-0000-0000000000e1',NULL,
    '{"label":"Pick","kind":"single_choice","options":["Only one"]}',NULL)$q$) LIKE '22023%options%', 'CQ2: one option refused';
  ASSERT pg_temp.err($q$SELECT public._exos_question_upsert('c9e00000-0000-0000-0000-000000000001','c9e00000-0000-0000-0000-0000000000e1',NULL,
    '{"label":"Pick","kind":"single_choice","options":["A","A"]}',NULL)$q$) LIKE '22023%same%', 'CQ2: duplicate options refused';
  ASSERT pg_temp.err($q$SELECT public._exos_question_upsert('c9e00000-0000-0000-0000-000000000001','c9e00000-0000-0000-0000-0000000000e1',NULL,
    '{"label":"Age","kind":"number","min_value":10,"max_value":5}',NULL)$q$) LIKE '22023%min_value%', 'CQ2: min above max refused';
  ASSERT pg_temp.err($q$SELECT public._exos_question_upsert('c9e00000-0000-0000-0000-000000000001','c9e00000-0000-0000-0000-0000000000e1',NULL,
    '{"label":"Bio","kind":"text","max_length":9000}',NULL)$q$) LIKE '22023%max_length%', 'CQ2: max_length over the cap refused';
  ASSERT pg_temp.err($q$SELECT public._exos_question_upsert('c9e00000-0000-0000-0000-000000000001','c9e00000-0000-0000-0000-0000000000e1',NULL,
    '{"label":"VIP?","kind":"text","tier_ids":["c9e00000-0000-0000-0000-0000000000d9"]}',NULL)$q$) LIKE '22023%ticket type%', 'CQ2: another event''s ticket type refused';
  ASSERT pg_temp.err($q$SELECT public._exos_question_upsert('c9e00000-0000-0000-0000-000000000001','c9e00000-0000-0000-0000-0000000000e1',NULL,
    '{"label":"","kind":"text"}',NULL)$q$) LIKE '22023%label%', 'CQ2: empty label refused';
  ASSERT pg_temp.err($q$SELECT public._exos_question_upsert('c9e00000-0000-0000-0000-000000000001','c9e00000-0000-0000-0000-0000000000e1',NULL,
    '{"label":"x","kind":"text","colour":"red"}',NULL)$q$) LIKE '22023%unknown field%', 'CQ2: unknown field refused';
  ASSERT pg_temp.err($q$SELECT public._exos_question_upsert('c9e00000-0000-0000-0000-000000000001','c9e00000-0000-0000-0000-0000000000e1',NULL,
    '{"label":"x","kind":"essay"}',NULL)$q$) LIKE '22023%type%', 'CQ2: unknown kind refused';

  -- Questions on the free events.
  PERFORM public._exos_question_upsert('c9e00000-0000-0000-0000-000000000001', 'c9e00000-0000-0000-0000-0000000000e2', NULL,
    '{"label":"Dietary needs","kind":"multiple_choice","options":["Vegan","Vegetarian","Halal"],"required":true,"scope":"ticket","max_choices":2}', NULL);
  PERFORM public._exos_question_upsert('c9e00000-0000-0000-0000-000000000001', 'c9e00000-0000-0000-0000-0000000000e2', NULL,
    '{"label":"Needs wheelchair access","kind":"checkbox","scope":"ticket"}', NULL);
  PERFORM public._exos_question_upsert('c9e00000-0000-0000-0000-000000000001', 'c9e00000-0000-0000-0000-0000000000e2', NULL,
    '{"label":"How did you hear about us?","kind":"text","scope":"order"}', NULL);
  PERFORM public._exos_question_upsert('c9e00000-0000-0000-0000-000000000001', 'c9e00000-0000-0000-0000-0000000000e3', NULL,
    '{"label":"Anything else?","kind":"long_text","scope":"order"}', NULL);
  RAISE NOTICE 'OK  CQ2 the builder: owner / manager save; finance, scanner, content, other org, anon refused; bad definitions refused';
END $$;

-- CQ3 ------------------------------------------------------------------------
DO $$
DECLARE
  e uuid := 'c9e00000-0000-0000-0000-0000000000e1';
  qs uuid := pg_temp.qid('c9e00000-0000-0000-0000-0000000000e1', 'T-shirt size');
  qc uuid := pg_temp.qid('c9e00000-0000-0000-0000-0000000000e1', 'Company');
  qa uuid := pg_temp.qid('c9e00000-0000-0000-0000-0000000000e1', 'I agree to the photo policy');
  qv uuid := pg_temp.qid('c9e00000-0000-0000-0000-0000000000e1', 'Name on the VIP list');
  qh uuid := pg_temp.qid('c9e00000-0000-0000-0000-0000000000e1', 'Wristband colour');
  ids uuid[]; r text; n int;
BEGIN
  PERFORM pg_temp.session('cs_cq_paid_1', e, 'c9e00000-0000-0000-0000-0000000000d1', 2, 'c9e00000-0000-0000-0000-0000000000f1', 'cq-fan@x.com');
  -- Required, per ticket: ticket 2 has no size.
  r := pg_temp.err(format($q$SELECT public.exos_record_checkout_answers('cs_cq_paid_1', '{"order":{"%s":true},"tickets":[{"%s":"M"}]}')$q$, qa, qs));
  ASSERT r LIKE '22023%T-shirt size%(ticket 2)%required%', 'CQ3: a missing required per-ticket answer is refused: ' || coalesce(r, 'accepted');
  -- The agree box unticked.
  r := pg_temp.err(format($q$SELECT public.exos_record_checkout_answers('cs_cq_paid_1', '{"order":{"%s":false},"tickets":[{"%s":"M"},{"%s":"L"}]}')$q$, qa, qs, qs));
  ASSERT r LIKE '22023%photo policy%required%', 'CQ3: the agree box must be ticked: ' || coalesce(r, 'accepted');
  -- Not one of the options.
  r := pg_temp.err(format($q$SELECT public.exos_record_checkout_answers('cs_cq_paid_1', '{"order":{"%s":true},"tickets":[{"%s":"M"},{"%s":"XXL"}]}')$q$, qa, qs, qs));
  ASSERT r LIKE '22023%options%', 'CQ3: an unknown choice is refused: ' || coalesce(r, 'accepted');
  -- Too long.
  r := pg_temp.err(format($q$SELECT public.exos_record_checkout_answers('cs_cq_paid_1', '{"order":{"%s":true,"%s":"%s"},"tickets":[{"%s":"M"},{"%s":"L"}]}')$q$,
                   qa, qc, repeat('x', 21), qs, qs));
  ASSERT r LIKE '22023%Company%too long%', 'CQ3: over max_length refused: ' || coalesce(r, 'accepted');
  -- A hidden question isn't asked at checkout; an unknown id is refused.
  r := pg_temp.err(format($q$SELECT public.exos_record_checkout_answers('cs_cq_paid_1', '{"order":{"%s":true},"tickets":[{"%s":"M","%s":"red"},{"%s":"L"}]}')$q$, qa, qs, qh, qs));
  ASSERT r LIKE '22023%not asked%', 'CQ3: a hidden question is refused at checkout: ' || coalesce(r, 'accepted');
  r := pg_temp.err(format($q$SELECT public.exos_record_checkout_answers('cs_cq_paid_1', '{"order":{"%s":true,"%s":"x"},"tickets":[{"%s":"M"},{"%s":"L"}]}')$q$, qa, gen_random_uuid(), qs, qs));
  ASSERT r LIKE '22023%not asked%', 'CQ3: an unknown question id is refused: ' || coalesce(r, 'accepted');
  -- More ticket entries than tickets.
  r := pg_temp.err(format($q$SELECT public.exos_record_checkout_answers('cs_cq_paid_1', '{"order":{"%s":true},"tickets":[{"%s":"M"},{"%s":"L"},{"%s":"S"}]}')$q$, qa, qs, qs, qs));
  ASSERT r LIKE '22023%more tickets%', 'CQ3: per-ticket answers must match the quantity: ' || coalesce(r, 'accepted');
  -- The VIP-only question isn't asked of GA.
  r := pg_temp.err(format($q$SELECT public.exos_record_checkout_answers('cs_cq_paid_1', '{"order":{"%s":true},"tickets":[{"%s":"M","%s":"Ada"},{"%s":"L"}]}')$q$, qa, qs, qv, qs));
  ASSERT r LIKE '22023%ticket type%', 'CQ3: a question limited to VIP is refused on GA: ' || coalesce(r, 'accepted');
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_question_answers WHERE order_ref = 'cs_cq_paid_1'), 'CQ3: nothing stored from refused bodies';

  -- Good answers: stored pending (before payment).
  r := public.exos_record_checkout_answers('cs_cq_paid_1', format('{"order":{"%s":true,"%s":"  Acme Inc  "},"tickets":[{"%s":"M"},{"%s":" L "}]}', qa, qc, qs, qs)::jsonb)::text;
  ASSERT r = '{"recorded": 4}', 'CQ3: four answers recorded, got ' || r;
  ASSERT (SELECT value FROM public.exos_question_answers WHERE order_ref = 'cs_cq_paid_1' AND question_id = qc) = '"Acme Inc"'::jsonb, 'CQ3: text trimmed';
  ASSERT (SELECT count(*) FROM public.exos_question_answers WHERE order_ref = 'cs_cq_paid_1' AND ticket_id IS NULL AND attached_at IS NULL) = 4,
    'CQ3: pending until the tickets exist';
  ASSERT public.exos_record_checkout_answers('cs_cq_paid_1', format('{"order":{"%s":true},"tickets":[{"%s":"S"},{"%s":"S"}]}', qa, qs, qs)::jsonb) = '{"recorded": 0}'::jsonb,
    'CQ3: a retry records nothing again';
  ASSERT (SELECT value FROM public.exos_question_answers WHERE order_ref = 'cs_cq_paid_1' AND ticket_index = 1) = '"M"'::jsonb, 'CQ3: the first answers stay';
  -- Paid (the webhook): the n-th ticket minted takes ticket n's answers.
  ids := public.exos_fulfill_checkout('cs_cq_paid_1');
  ASSERT cardinality(ids) = 2, 'CQ3: two tickets';
  ASSERT (SELECT value FROM public.exos_question_answers WHERE question_id = qs AND ticket_id = ids[1]) = '"M"'::jsonb
     AND (SELECT value FROM public.exos_question_answers WHERE question_id = qs AND ticket_id = ids[2]) = '"L"'::jsonb,
    'CQ3: ticket 1 got M, ticket 2 got L';
  ASSERT (SELECT count(*) FROM public.exos_question_answers WHERE order_ref = 'cs_cq_paid_1' AND attached_at IS NOT NULL) = 4,
    'CQ3: every answer of the order attached';
  ASSERT (SELECT label FROM public.exos_question_answers WHERE question_id = qs AND ticket_id = ids[1]) = 'T-shirt size'
     AND (SELECT buyer_uid FROM public.exos_question_answers WHERE question_id = qs AND ticket_id = ids[1]) = 'c9e00000-0000-0000-0000-0000000000f1',
    'CQ3: label snapshot and buyer';
  ASSERT (public._exos_answers_for(ARRAY[ids[2]], true) -> (ids[2]::text)) @> format('[{"question_id":"%s","value":"L"},{"question_id":"%s","value":"Acme Inc"}]', qs, qc)::jsonb,
    'CQ3: with order access, a ticket''s answers include its order''s';
  ASSERT (public._exos_answers_for(ARRAY[ids[2]], false) -> (ids[2]::text)) = format('[{"question_id":"%s","scope":"ticket","label":"T-shirt size","kind":"single_choice","value":"L","display":"L"}]', qs)::jsonb,
    'CQ3: without it (tickets:read only), per-ticket answers only: ' || (public._exos_answers_for(ARRAY[ids[2]], false) -> (ids[2]::text))::text;
  ASSERT pg_temp.err($q$SELECT public.exos_record_checkout_answers('cs_cq_paid_1', '{}')$q$) LIKE '22023%fulfilled%', 'CQ3: a fulfilled order takes no new answers';

  -- VIP: the VIP-only per-ticket question is required there.
  PERFORM pg_temp.session('cs_cq_vip_1', e, 'c9e00000-0000-0000-0000-0000000000d2', 1, 'c9e00000-0000-0000-0000-0000000000f1', 'cq-fan@x.com');
  r := pg_temp.err(format($q$SELECT public.exos_record_checkout_answers('cs_cq_vip_1', '{"order":{"%s":true},"tickets":[{"%s":"S"}]}')$q$, qa, qs));
  ASSERT r LIKE '22023%VIP list%required%', 'CQ3: VIP requires its own question: ' || coalesce(r, 'accepted');
  PERFORM public.exos_record_checkout_answers('cs_cq_vip_1', format('{"order":{"%s":true},"tickets":[{"%s":"S","%s":"Ada Lovelace"}]}', qa, qs, qv)::jsonb);
  ids := public.exos_fulfill_checkout('cs_cq_vip_1');
  SELECT count(*) INTO n FROM public.exos_question_answers WHERE ticket_id = ids[1];
  ASSERT n = 2, 'CQ3: the VIP ticket has size + list name, got ' || n;
  RAISE NOTICE 'OK  CQ3 paid checkout: required / choice / length / scope / ticket type refused before payment; answers attach to the right tickets at fulfillment';
END $$;

-- CQ4 ------------------------------------------------------------------------
DO $$
DECLARE
  e uuid := 'c9e00000-0000-0000-0000-0000000000e2';
  qd uuid := pg_temp.qid('c9e00000-0000-0000-0000-0000000000e2', 'Dietary needs');
  qw uuid := pg_temp.qid('c9e00000-0000-0000-0000-0000000000e2', 'Needs wheelchair access');
  qo uuid := pg_temp.qid('c9e00000-0000-0000-0000-0000000000e2', 'How did you hear about us?');
  r text; r2 text;
BEGIN
  r := pg_temp.as_user('c9e00000-0000-0000-0000-0000000000f1', $q$SELECT public.exos_claim_free_tickets('c9e00000-0000-0000-0000-0000000000e2',
    'c9e00000-0000-0000-0000-0000000000d3', 1, NULL, NULL, 'cq-free-ref-0001')::text$q$);
  ASSERT r LIKE 'ERR 22023%answer the checkout questions%', 'CQ4: the plain claim refuses to skip required questions: ' || r;
  r := pg_temp.as_user('c9e00000-0000-0000-0000-0000000000f1', format($q$SELECT public.exos_claim_free_tickets_answered('c9e00000-0000-0000-0000-0000000000e2',
    'c9e00000-0000-0000-0000-0000000000d3', 2, NULL, NULL, 'cq-free-ref-0001', '{"tickets":[{"%s":["Vegan"]}]}')::text$q$, qd));
  ASSERT r LIKE 'ERR 22023%Dietary needs%(ticket 2)%', 'CQ4: the answered claim needs every ticket''s required answer: ' || r;
  r := pg_temp.as_user('c9e00000-0000-0000-0000-0000000000f1', format($q$SELECT public.exos_claim_free_tickets_answered('c9e00000-0000-0000-0000-0000000000e2',
    'c9e00000-0000-0000-0000-0000000000d3', 2, NULL, NULL, 'cq-free-ref-0001',
    '{"order":{"%s":"A flyer"},"tickets":[{"%s":["Halal","Vegan"]},{"%s":["Vegetarian"],"%s":true}]}')::text$q$, qo, qd, qd, qw));
  ASSERT r NOT LIKE 'ERR%', 'CQ4: answered claim: ' || r;
  ASSERT (SELECT value FROM public.exos_question_answers a WHERE a.question_id = qd
            AND a.ticket_id = (r::uuid[])[1]) = '["Vegan","Halal"]'::jsonb, 'CQ4: ticket 1 took ticket 1''s answer (normalised to the options'' order)';
  ASSERT (SELECT value FROM public.exos_question_answers a WHERE a.question_id = qw AND a.ticket_id = (r::uuid[])[2]) = 'true'::jsonb,
    'CQ4: ticket 2 took ticket 2''s answer';
  ASSERT (SELECT source FROM public.exos_question_answers a WHERE a.question_id = qo AND a.order_ref = 'cq-free-ref-0001') = 'free_claim'
     AND (SELECT attached_at IS NOT NULL FROM public.exos_question_answers a WHERE a.question_id = qo AND a.order_ref = 'cq-free-ref-0001'),
    'CQ4: the order answer is kept and attached';
  r2 := pg_temp.as_user('c9e00000-0000-0000-0000-0000000000f1', format($q$SELECT public.exos_claim_free_tickets_answered('c9e00000-0000-0000-0000-0000000000e2',
    'c9e00000-0000-0000-0000-0000000000d3', 2, NULL, NULL, 'cq-free-ref-0001', '{"tickets":[{"%s":["Vegan"]},{"%s":["Vegan"]}]}')::text$q$, qd, qd));
  ASSERT (SELECT array_agg(x ORDER BY x) FROM unnest(r2::uuid[]) x) = (SELECT array_agg(x ORDER BY x) FROM unnest(r::uuid[]) x),
    'CQ4: a retry returns the same tickets: ' || r2;
  ASSERT (SELECT count(*) FROM public.exos_question_answers WHERE order_ref = 'cq-free-ref-0001') = 4, 'CQ4: and records nothing again';
  -- Another buyer can't take over that order ref.
  r := pg_temp.as_user('c9e00000-0000-0000-0000-0000000000f2', format($q$SELECT public.exos_claim_free_tickets_answered('c9e00000-0000-0000-0000-0000000000e2',
    'c9e00000-0000-0000-0000-0000000000d3', 1, NULL, NULL, 'cq-free-ref-0001', '{"tickets":[{"%s":["Vegan"]}]}')::text$q$, qd));
  ASSERT r LIKE 'ERR 42501%already in use%', 'CQ4: another buyer''s order ref is refused: ' || r;
  -- Optional questions only: the plain claim is unchanged.
  r := pg_temp.as_user('c9e00000-0000-0000-0000-0000000000f2', $q$SELECT public.exos_claim_free_tickets('c9e00000-0000-0000-0000-0000000000e3',
    'c9e00000-0000-0000-0000-0000000000d4', 1, NULL, NULL, 'cq-easy-ref-0001')::text$q$);
  ASSERT r NOT LIKE 'ERR%', 'CQ4: no required questions, the plain claim works: ' || r;
  RAISE NOTICE 'OK  CQ4 free claim: required questions can''t be skipped; answered claims attach per ticket; retries are idempotent; refs can''t be reused';
END $$;

-- CQ5 ------------------------------------------------------------------------
DO $$
DECLARE
  e uuid := 'c9e00000-0000-0000-0000-0000000000e1';
  qs uuid := pg_temp.qid('c9e00000-0000-0000-0000-0000000000e1', 'T-shirt size');
  qa uuid := pg_temp.qid('c9e00000-0000-0000-0000-0000000000e1', 'I agree to the photo policy');
  ids uuid[]; v jsonb; code text; r text;
BEGIN
  PERFORM pg_temp.session('cs_cq_guest_1', e, 'c9e00000-0000-0000-0000-0000000000d1', 2, NULL, 'cq-guest@x.com');
  PERFORM public.exos_record_checkout_answers('cs_cq_guest_1', format('{"order":{"%s":true},"tickets":[{"%s":"S"},{"%s":"L"}]}', qa, qs, qs)::jsonb);
  ids := public.exos_fulfill_checkout('cs_cq_guest_1');
  ASSERT cardinality(ids) = 2 AND (SELECT bool_and(owner_id = 'c9e00000-0000-0000-0000-0000000000a1') FROM public.exos_tickets WHERE id = ANY (ids)),
    'CQ5: parked on the org owner until proof';
  ASSERT (SELECT value FROM public.exos_question_answers WHERE question_id = qs AND ticket_id = ids[2]) = '"L"'::jsonb, 'CQ5: attached while parked';
  ASSERT (SELECT count(*) FROM public.exos_question_answers WHERE order_ref = 'cs_cq_guest_1' AND buyer_uid IS NULL) = 3, 'CQ5: no buyer yet';
  ASSERT pg_temp.as_user('c9e00000-0000-0000-0000-0000000000f3',
    $q$SELECT count(*)::text FROM public.exos_question_answers WHERE order_ref = 'cs_cq_guest_1'$q$) = '0', 'CQ5: the buyer can''t read them before proof';
  code := (SELECT substring(html from 'letter-spacing:6px"><strong>([0-9]{6})</strong>') FROM public.exos_mail
            WHERE to_email = 'cq-guest@x.com' AND template = 'rsvp-code' ORDER BY created_at DESC, id DESC LIMIT 1);
  v := public.exos_order_proof_verify('cs_cq_guest_1', 'tok-cs_cq_guest_1-0123456789abcdef', code);
  ASSERT (v->>'attached')::boolean, 'CQ5: proven, attached to the account: ' || v::text;
  ASSERT (SELECT bool_and(buyer_id = 'c9e00000-0000-0000-0000-0000000000f3') FROM public.exos_tickets WHERE id = ANY (ids)), 'CQ5: tickets moved';
  ASSERT (SELECT value FROM public.exos_question_answers WHERE question_id = qs AND ticket_id = ids[1]) = '"S"'::jsonb
     AND (SELECT value FROM public.exos_question_answers WHERE question_id = qs AND ticket_id = ids[2]) = '"L"'::jsonb,
    'CQ5: same tickets, same answers after proof';
  r := pg_temp.as_user('c9e00000-0000-0000-0000-0000000000f3', $q$SELECT count(*)::text FROM public.exos_question_answers WHERE order_ref = 'cs_cq_guest_1'$q$);
  ASSERT r = '3', 'CQ5: the buyer reads their order''s answers after proof, got ' || r;
  RAISE NOTICE 'OK  CQ5 a guest''s answers survive proof of email (same tickets) and become the buyer''s to read';
END $$;

-- CQ6 ------------------------------------------------------------------------
DO $$
DECLARE
  cnt text := $q$SELECT count(*)::text FROM public.exos_question_answers WHERE event_id = 'c9e00000-0000-0000-0000-0000000000e1'$q$;
  ord text := $q$SELECT count(*)::text FROM public.exos_question_answers WHERE event_id = 'c9e00000-0000-0000-0000-0000000000e1' AND scope = 'order'$q$;
  total int;
  tix int;
BEGIN
  SELECT count(*), count(*) FILTER (WHERE scope = 'ticket') INTO total, tix
    FROM public.exos_question_answers WHERE event_id = 'c9e00000-0000-0000-0000-0000000000e1';
  ASSERT pg_temp.as_user('c9e00000-0000-0000-0000-0000000000a1', cnt) = total::text, 'CQ6: owner reads all';
  ASSERT pg_temp.as_user('c9e00000-0000-0000-0000-0000000000a2', cnt) = total::text, 'CQ6: manager reads all';
  ASSERT pg_temp.as_user('c9e00000-0000-0000-0000-0000000000a4', cnt) = total::text, 'CQ6: finance reads all';
  ASSERT pg_temp.as_user('c9e00000-0000-0000-0000-0000000000a3', cnt) = tix::text
     AND pg_temp.as_user('c9e00000-0000-0000-0000-0000000000a3', ord) = '0', 'CQ6: the org-wide scanner reads per-ticket answers only';
  ASSERT pg_temp.as_user('c9e00000-0000-0000-0000-0000000000a6', cnt) = '0', 'CQ6: a scanner of another event reads none';
  ASSERT pg_temp.as_user('c9e00000-0000-0000-0000-0000000000a5', cnt) = '0', 'CQ6: content reads none';
  ASSERT pg_temp.as_user('c9e00000-0000-0000-0000-0000000000b1', cnt) = '0', 'CQ6: another org''s owner reads none';
  ASSERT pg_temp.as_user('c9e00000-0000-0000-0000-0000000000f2', cnt) = '0', 'CQ6: a stranger reads none';
  ASSERT pg_temp.as_user('c9e00000-0000-0000-0000-0000000000f1', cnt) =
         (SELECT count(*)::text FROM public.exos_question_answers WHERE event_id = 'c9e00000-0000-0000-0000-0000000000e1'
             AND buyer_uid = 'c9e00000-0000-0000-0000-0000000000f1'), 'CQ6: the buyer reads their own';
  ASSERT pg_temp.as_user(NULL, cnt) LIKE 'ERR 42501%', 'CQ6: anon can''t read the table';
  -- The report function: owner / manager / finance only.
  ASSERT pg_temp.as_user('c9e00000-0000-0000-0000-0000000000a4',
    $q$SELECT count(*)::text FROM public.exos_event_question_answers('c9e00000-0000-0000-0000-0000000000e1')$q$) = total::text, 'CQ6: finance sees the answers table';
  ASSERT pg_temp.as_user('c9e00000-0000-0000-0000-0000000000a3',
    $q$SELECT count(*)::text FROM public.exos_event_question_answers('c9e00000-0000-0000-0000-0000000000e1')$q$) LIKE 'ERR 42501%', 'CQ6: a scanner doesn''t';
  ASSERT pg_temp.as_user('c9e00000-0000-0000-0000-0000000000b1',
    $q$SELECT count(*)::text FROM public.exos_event_question_answers('c9e00000-0000-0000-0000-0000000000e1')$q$) LIKE 'ERR 42501%', 'CQ6: nor another org';
  ASSERT pg_temp.as_user('c9e00000-0000-0000-0000-0000000000b1',
    $q$SELECT public.exos_list_event_questions('c9e00000-0000-0000-0000-0000000000e1')::text$q$) LIKE 'ERR 42501%', 'CQ6: another org can''t list the questions';
  RAISE NOTICE 'OK  CQ6 RLS: owner / manager / finance all, buyer own, door staff per-ticket of their event, nobody else';
END $$;

-- CQ7 ------------------------------------------------------------------------
DO $$
DECLARE
  e uuid := 'c9e00000-0000-0000-0000-0000000000e1';
  qs uuid := pg_temp.qid('c9e00000-0000-0000-0000-0000000000e1', 'T-shirt size');
  qc uuid := pg_temp.qid('c9e00000-0000-0000-0000-0000000000e1', 'Company');
  qa uuid := pg_temp.qid('c9e00000-0000-0000-0000-0000000000e1', 'I agree to the photo policy');
  qn uuid;
  r text; v_row jsonb; ids uuid[];
BEGIN
  -- Rename: the answers keep the label they were given under.
  PERFORM public._exos_question_upsert('c9e00000-0000-0000-0000-000000000001', e, qs, '{"label":"Shirt size","options":["S","M","L","XL"]}', NULL);
  ASSERT (SELECT bool_and(label = 'T-shirt size') FROM public.exos_question_answers WHERE question_id = qs), 'CQ7: snapshot kept';
  SELECT to_jsonb(x) INTO v_row FROM public._exos_event_answer_rows(e) x WHERE x.question_id = qs LIMIT 1;
  ASSERT v_row->>'label' = 'T-shirt size' AND v_row->>'current_label' = 'Shirt size', 'CQ7: the table shows both labels';
  -- Kind / scope can't change once answered; an unanswered one can.
  ASSERT pg_temp.err(format($q$SELECT public._exos_question_upsert('c9e00000-0000-0000-0000-000000000001','c9e00000-0000-0000-0000-0000000000e1','%s','{"kind":"text"}',NULL)$q$, qs))
         LIKE '22023%type can''t change%', 'CQ7: kind is fixed after answers';
  ASSERT pg_temp.err(format($q$SELECT public._exos_question_upsert('c9e00000-0000-0000-0000-000000000001','c9e00000-0000-0000-0000-0000000000e1','%s','{"scope":"order"}',NULL)$q$, qs))
         LIKE '22023%per order%', 'CQ7: scope is fixed after answers';
  -- Archive ("delete"): answers stay, the question is no longer asked.
  r := pg_temp.as_user('c9e00000-0000-0000-0000-0000000000a1', format($q$SELECT public.exos_archive_event_question('%s')::text$q$, qc));
  ASSERT r::jsonb->>'archived' = 'true', 'CQ7: archived: ' || r;
  ASSERT (SELECT count(*) FROM public.exos_question_answers WHERE question_id = qc) = 1, 'CQ7: its answer is kept';
  ASSERT (SELECT bool_and(question_archived) FROM public._exos_event_answer_rows(e) x WHERE x.question_id = qc), 'CQ7: shown as archived';
  PERFORM pg_temp.session('cs_cq_paid_2', e, 'c9e00000-0000-0000-0000-0000000000d1', 1, 'c9e00000-0000-0000-0000-0000000000f2', 'cq-fan2@x.com');
  r := pg_temp.err(format($q$SELECT public.exos_record_checkout_answers('cs_cq_paid_2', '{"order":{"%s":true,"%s":"Acme"},"tickets":[{"%s":"XL"}]}')$q$, qa, qc, qs));
  ASSERT r LIKE '22023%not asked%', 'CQ7: an archived question is refused at checkout: ' || coalesce(r, 'accepted');
  ASSERT NOT (public.exos_public_event_questions(e)->'questions' @> format('[{"id":"%s"}]', qc)::jsonb), 'CQ7: and not offered';
  -- A new optional question made required later: old orders are untouched,
  -- new ones must answer it.
  qn := (public._exos_question_upsert('c9e00000-0000-0000-0000-000000000001', e, NULL, '{"label":"Emergency contact","kind":"phone","scope":"order"}', NULL)->>'id')::uuid;
  PERFORM public._exos_question_upsert('c9e00000-0000-0000-0000-000000000001', e, qn, '{"required":true}', NULL);
  ASSERT (SELECT status FROM public.exos_checkout_sessions WHERE session_id = 'cs_cq_paid_1') = 'fulfilled'
     AND (SELECT count(*) FROM public.exos_tickets WHERE order_ref = 'cs_cq_paid_1' AND status = 'active') = 2, 'CQ7: old orders unchanged';
  r := pg_temp.err(format($q$SELECT public.exos_record_checkout_answers('cs_cq_paid_2', '{"order":{"%s":true},"tickets":[{"%s":"XL"}]}')$q$, qa, qs));
  ASSERT r LIKE '22023%Emergency contact%required%', 'CQ7: new orders must answer it: ' || coalesce(r, 'accepted');
  PERFORM public.exos_record_checkout_answers('cs_cq_paid_2', format('{"order":{"%s":true,"%s":"+44 20 7946 0958"},"tickets":[{"%s":"XL"}]}', qa, qn, qs)::jsonb);
  ids := public.exos_fulfill_checkout('cs_cq_paid_2');
  ASSERT (SELECT value FROM public.exos_question_answers WHERE question_id = qn AND order_ref = 'cs_cq_paid_2') = '"+442079460958"'::jsonb,
    'CQ7: phone normalised';
  -- Restore works (and puts it back on offer).
  PERFORM public._exos_question_archive('c9e00000-0000-0000-0000-000000000001', qc, false);
  ASSERT public.exos_public_event_questions(e)->'questions' @> format('[{"id":"%s"}]', qc)::jsonb, 'CQ7: restored';
  RAISE NOTICE 'OK  CQ7 after sales: renames keep snapshots, kind / scope fixed, archive keeps answers and stops asking, required later spares old orders';
END $$;

-- CQ8 ------------------------------------------------------------------------
DO $$
DECLARE
  qh uuid := pg_temp.qid('c9e00000-0000-0000-0000-0000000000e1', 'Wristband colour');
  qs uuid := pg_temp.qid('c9e00000-0000-0000-0000-0000000000e1', 'Shirt size');
  qa uuid := pg_temp.qid('c9e00000-0000-0000-0000-0000000000e1', 'I agree to the photo policy');
  t uuid := (SELECT ticket_ids[1] FROM public.exos_checkout_sessions WHERE session_id = 'cs_cq_paid_1');
  r text;
BEGIN
  r := pg_temp.as_user('c9e00000-0000-0000-0000-0000000000a3', format($q$SELECT public.exos_door_set_ticket_answers('%s', '{"%s":"Red"}')::text$q$, t, qh));
  ASSERT r NOT LIKE 'ERR%' AND r::jsonb @> format('[{"question_id":"%s","value":"Red"}]', qh)::jsonb, 'CQ8: the door adds a hidden answer: ' || r;
  ASSERT (SELECT source FROM public.exos_question_answers WHERE question_id = qh AND ticket_id = t) = 'door', 'CQ8: source door';
  r := pg_temp.as_user('c9e00000-0000-0000-0000-0000000000a3', format($q$SELECT public.exos_door_set_ticket_answers('%s', '{"%s":"XL"}')::text$q$, t, qs));
  ASSERT (SELECT value FROM public.exos_question_answers WHERE question_id = qs AND ticket_id = t) = '"XL"'::jsonb, 'CQ8: the door corrects a size';
  ASSERT pg_temp.as_user('c9e00000-0000-0000-0000-0000000000a3', format($q$SELECT public.exos_door_set_ticket_answers('%s', '{"%s":"XXXL"}')::text$q$, t, qs))
         LIKE 'ERR 22023%options%', 'CQ8: the rules still hold at the door';
  ASSERT pg_temp.as_user('c9e00000-0000-0000-0000-0000000000a3', format($q$SELECT public.exos_door_set_ticket_answers('%s', '{"%s":true}')::text$q$, t, qa))
         LIKE 'ERR 22023%', 'CQ8: an order question isn''t set per ticket';
  ASSERT pg_temp.as_user('c9e00000-0000-0000-0000-0000000000a6', format($q$SELECT public.exos_door_set_ticket_answers('%s', '{"%s":"Blue"}')::text$q$, t, qh))
         LIKE 'ERR 42501%', 'CQ8: a scanner of another event can''t';
  ASSERT pg_temp.as_user('c9e00000-0000-0000-0000-0000000000f1', format($q$SELECT public.exos_door_set_ticket_answers('%s', '{"%s":"Blue"}')::text$q$, t, qh))
         LIKE 'ERR 42501%', 'CQ8: nor the buyer';
  r := pg_temp.as_user('c9e00000-0000-0000-0000-0000000000a3', format($q$SELECT public.exos_door_set_ticket_answers('%s', '{"%s":""}')::text$q$, t, qh));
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_question_answers WHERE question_id = qh AND ticket_id = t), 'CQ8: a blank answer clears it';
  RAISE NOTICE 'OK  CQ8 the door: event staff set per-ticket (also hidden) answers under the same rules; others can''t';
END $$;

-- CQ9 ------------------------------------------------------------------------
DO $$
DECLARE
  qd uuid := pg_temp.qid('c9e00000-0000-0000-0000-0000000000e2', 'Dietary needs');
  r1 uuid := 'c9e00000-0000-0000-0000-00000000c001';
  r2 uuid := 'c9e00000-0000-0000-0000-00000000c002';
  v jsonb; tid uuid;
BEGIN
  INSERT INTO public.exos_phone_rsvps (id, org_id, event_id, tier_id, guest_name, phone, plus_ones, channel, code_hash, code_expires_at)
  VALUES (r1, 'c9e00000-0000-0000-0000-000000000001', 'c9e00000-0000-0000-0000-0000000000e2', 'c9e00000-0000-0000-0000-0000000000d3',
          'Ada', '+15550100001', 1, 'email', repeat('a', 64), now() + interval '10 minutes'),
         (r2, 'c9e00000-0000-0000-0000-000000000001', 'c9e00000-0000-0000-0000-0000000000e2', 'c9e00000-0000-0000-0000-0000000000d3',
          'Bob', '+15550100002', 0, 'email', repeat('a', 64), now() + interval '10 minutes');
  v := public.exos_rsvp_record_answers(r1, format('{"tickets":[{"%s":["Vegan"]}]}', qd)::jsonb);
  ASSERT v->>'ok' = 'false' AND v->>'error' = 'answers' AND v->'problems'->0->>'code' = 'required'
     AND (SELECT status FROM public.exos_phone_rsvps WHERE id = r1) = 'expired', 'CQ9: plus one unanswered: refused, RSVP expired: ' || v::text;
  v := public.exos_rsvp_record_answers(r2, format('{"tickets":[{"%s":["Halal"]}]}', qd)::jsonb);
  ASSERT (v->>'ok')::boolean AND (v->>'recorded')::int = 1, 'CQ9: recorded: ' || v::text;
  -- What exos_phone_rsvp_verify inserts.
  INSERT INTO public.exos_tickets (event_id, org_id, tier_id, tier_name, buyer_id, owner_id, status, barcode_secret, price_paid, order_ref)
  VALUES ('c9e00000-0000-0000-0000-0000000000e2', 'c9e00000-0000-0000-0000-000000000001', 'c9e00000-0000-0000-0000-0000000000d3', 'Free',
          'c9e00000-0000-0000-0000-0000000000a1', 'c9e00000-0000-0000-0000-0000000000a1', 'active', gen_random_uuid()::text, 0, 'rsvp:' || r2)
  RETURNING id INTO tid;
  ASSERT (SELECT value FROM public.exos_question_answers WHERE ticket_id = tid AND question_id = qd) = '["Halal"]'::jsonb, 'CQ9: the RSVP ticket took it';
  ASSERT (public.exos_rsvp_questions('c9e00000-0000-0000-0000-0000000000e2')->'questions') @> format('[{"id":"%s"}]', qd)::jsonb
     OR (public.exos_rsvp_questions('c9e00000-0000-0000-0000-0000000000e2')->>'tier_id') IS NULL, 'CQ9: questions offered to RSVPs';
  RAISE NOTICE 'OK  CQ9 phone RSVP: answers checked at start, a refusal expires it, the RSVP''s tickets take them';
END $$;

-- CQ10 -----------------------------------------------------------------------
DO $$
DECLARE
  e uuid := 'c9e00000-0000-0000-0000-0000000000e1';
  qs uuid := pg_temp.qid('c9e00000-0000-0000-0000-0000000000e1', 'Shirt size');
  qa uuid := pg_temp.qid('c9e00000-0000-0000-0000-0000000000e1', 'I agree to the photo policy');
  v jsonb; ids uuid[];
BEGIN
  ASSERT jsonb_array_length(public._exos_api_questions('c9e00000-0000-0000-0000-000000000001', e)) = 6, 'CQ10: six questions incl. the new one';
  ASSERT public._exos_api_questions('c9e00000-0000-0000-0000-000000000002', e) = '[]'::jsonb, 'CQ10: another org sees none';
  ASSERT pg_temp.err(format($q$SELECT public._exos_question_upsert('c9e00000-0000-0000-0000-000000000002','c9e00000-0000-0000-0000-0000000000e1','%s','{"label":"pwned"}',NULL)$q$, qs))
         LIKE 'P0002%', 'CQ10: another org can''t change it';
  ASSERT pg_temp.err(format($q$SELECT public._exos_question_archive('c9e00000-0000-0000-0000-000000000002','%s',true)$q$, qs)) LIKE 'P0002%',
    'CQ10: nor archive it';
  ASSERT pg_temp.err(format($q$SELECT public._exos_questions_reorder('c9e00000-0000-0000-0000-000000000001','c9e00000-0000-0000-0000-0000000000e9',ARRAY['%s']::uuid[])$q$, qs))
         LIKE 'P0002%', 'CQ10: nor reorder across orgs';
  v := public._exos_questions_reorder('c9e00000-0000-0000-0000-000000000001', e, ARRAY[qa, qs]);
  ASSERT v->0->>'id' = qa::text AND v->1->>'id' = qs::text, 'CQ10: reordered';
  ASSERT (SELECT array_agg(sort_order ORDER BY sort_order) FROM public.exos_event_questions WHERE event_id = e) = ARRAY[0, 1, 2, 3, 4, 5], 'CQ10: the rest follow';
  ids := (SELECT ticket_ids FROM public.exos_checkout_sessions WHERE session_id = 'cs_cq_paid_1');
  v := public._exos_answers_for(ids, true);
  ASSERT jsonb_array_length(v->(ids[1]::text)) >= 2 AND v->(ids[1]::text)->0 ? 'display', 'CQ10: answers per ticket with display text';
  ASSERT (SELECT count(*) FROM public._exos_event_answer_rows(e)) = (SELECT count(*) FROM public.exos_question_answers WHERE event_id = e AND attached_at IS NOT NULL),
    'CQ10: the table lists the minted orders'' answers';
  ASSERT public._exos_answer_display('["Vegan","Halal"]') = 'Vegan, Halal' AND public._exos_answer_display('true') = 'Yes'
     AND public._exos_answer_display('12.5') = '12.5', 'CQ10: display text';
  RAISE NOTICE 'OK  CQ10 API cores: cross-org isolation, reorder, answers per ticket / order with display text';
END $$;

-- CQ11 -----------------------------------------------------------------------
DO $$
DECLARE v jsonb; r text;
BEGIN
  r := pg_temp.as_user(NULL, $q$SELECT public.exos_public_event_questions('c9e00000-0000-0000-0000-0000000000e1')::text$q$);
  v := r::jsonb;
  ASSERT jsonb_array_length(v->'questions') = 5, 'CQ11: five offered (the hidden one isn''t), got ' || jsonb_array_length(v->'questions');
  ASSERT NOT (v->'questions' @> '[{"label":"Wristband colour"}]'), 'CQ11: no hidden question';
  ASSERT NOT (v->'questions'->0 ? 'answer_count') AND NOT (v->'questions'->0 ? 'hidden'), 'CQ11: no staff fields';
  PERFORM public._exos_question_upsert('c9e00000-0000-0000-0000-000000000001', 'c9e00000-0000-0000-0000-0000000000e4', NULL,
    '{"label":"Secret plans","kind":"text"}', NULL);
  ASSERT pg_temp.as_user(NULL, $q$SELECT public.exos_public_event_questions('c9e00000-0000-0000-0000-0000000000e4')::text$q$)::jsonb->'questions' = '[]'::jsonb,
    'CQ11: a draft event shows nothing to anon';
  ASSERT jsonb_array_length(pg_temp.as_user('c9e00000-0000-0000-0000-0000000000a2',
    $q$SELECT public.exos_public_event_questions('c9e00000-0000-0000-0000-0000000000e4')::text$q$)::jsonb->'questions') = 1,
    'CQ11: the event''s editors preview it';
  RAISE NOTICE 'OK  CQ11 public questions: no hidden / archived, no staff fields, drafts only to editors';
END $$;

-- CQ13 -----------------------------------------------------------------------
DO $$
DECLARE
  e uuid := 'c9e00000-0000-0000-0000-0000000000e1';
  qs uuid := pg_temp.qid('c9e00000-0000-0000-0000-0000000000e1', 'Shirt size');
  qa uuid := pg_temp.qid('c9e00000-0000-0000-0000-0000000000e1', 'I agree to the photo policy');
  qn uuid := pg_temp.qid('c9e00000-0000-0000-0000-0000000000e1', 'Emergency contact');
  body jsonb;
  ids uuid[]; r text; tid uuid; n int;
BEGIN
  body := format('{"order":{"%s":true,"%s":"+15550100099"},"tickets":[{"%s":"S"},{"%s":"XL"}]}', qa, qn, qs, qs)::jsonb;
  -- Buyer A's pending order with answers.
  PERFORM pg_temp.session('cs_cq_hijack', e, 'c9e00000-0000-0000-0000-0000000000d1', 2, 'c9e00000-0000-0000-0000-0000000000f1', 'cq-fan@x.com');
  PERFORM public.exos_record_checkout_answers('cs_cq_hijack', body);
  -- B: the plain free claim with A's ref is refused.
  r := pg_temp.as_user('c9e00000-0000-0000-0000-0000000000f2', $q$SELECT public.exos_claim_free_tickets('c9e00000-0000-0000-0000-0000000000e1',
    'c9e00000-0000-0000-0000-0000000000d6', 1, NULL, NULL, 'cs_cq_hijack')::text$q$);
  ASSERT r LIKE 'ERR 42501%already in use%', 'CQ13: the free claim refuses another buyer''s order ref: ' || r;
  -- B: the answered claim too.
  r := pg_temp.as_user('c9e00000-0000-0000-0000-0000000000f2', format($q$SELECT public.exos_claim_free_tickets_answered('c9e00000-0000-0000-0000-0000000000e1',
    'c9e00000-0000-0000-0000-0000000000d6', 1, NULL, NULL, 'cs_cq_hijack', '{"order":{"%s":true,"%s":"+15550100098"},"tickets":[{"%s":"M"}]}')::text$q$, qa, qn, qs));
  ASSERT r LIKE 'ERR 42501%already in use%', 'CQ13: the answered claim refuses it: ' || r;
  -- Any other mint path: B's ticket with A's ref (same event and type) takes nothing.
  INSERT INTO public.exos_tickets (event_id, org_id, tier_id, tier_name, buyer_id, owner_id, status, barcode_secret, price_paid, order_ref)
  VALUES (e, 'c9e00000-0000-0000-0000-000000000001', 'c9e00000-0000-0000-0000-0000000000d1', 'GA',
          'c9e00000-0000-0000-0000-0000000000f2', 'c9e00000-0000-0000-0000-0000000000f2', 'active', gen_random_uuid()::text, 0, 'cs_cq_hijack')
  RETURNING id INTO tid;
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_question_answers WHERE ticket_id = tid), 'CQ13: B''s ticket took none of A''s answers';
  ASSERT (SELECT next_index FROM public.exos_question_answer_cursors WHERE order_ref = 'cs_cq_hijack') = 1, 'CQ13: and moved nothing';
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_question_answers WHERE order_ref = 'cs_cq_hijack' AND attached_at IS NOT NULL),
    'CQ13: A''s order answers stay unattached';
  ASSERT pg_temp.as_user('c9e00000-0000-0000-0000-0000000000f2',
    $q$SELECT count(*)::text FROM public.exos_question_answers WHERE order_ref = 'cs_cq_hijack'$q$) = '0', 'CQ13: B reads none of them';
  DELETE FROM public.exos_tickets WHERE id = tid;
  -- A pays: A's tickets get A's answers, in order.
  ids := public.exos_fulfill_checkout('cs_cq_hijack');
  ASSERT cardinality(ids) = 2
     AND (SELECT value FROM public.exos_question_answers WHERE question_id = qs AND ticket_id = ids[1]) = '"S"'::jsonb
     AND (SELECT value FROM public.exos_question_answers WHERE question_id = qs AND ticket_id = ids[2]) = '"XL"'::jsonb,
    'CQ13: A''s tickets take A''s answers';
  -- Parked tickets still attach: an unconfirmed account's order is parked on the org owner.
  PERFORM pg_temp.session('cs_cq_unconf', e, 'c9e00000-0000-0000-0000-0000000000d1', 1, 'c9e00000-0000-0000-0000-0000000000f4', 'cq-unconfirmed@x.com');
  PERFORM public.exos_record_checkout_answers('cs_cq_unconf', format('{"order":{"%s":true,"%s":"+15550100097"},"tickets":[{"%s":"M"}]}', qa, qn, qs)::jsonb);
  ids := public.exos_fulfill_checkout('cs_cq_unconf');
  ASSERT (SELECT owner_id FROM public.exos_tickets WHERE id = ids[1]) = 'c9e00000-0000-0000-0000-0000000000a1', 'CQ13: parked on the org owner';
  ASSERT (SELECT value FROM public.exos_question_answers WHERE question_id = qs AND ticket_id = ids[1]) = '"M"'::jsonb,
    'CQ13: the parked ticket of that buyer''s own session takes its answers';
  -- The org owner can't take a guest order's answers with its ref either.
  r := pg_temp.as_user('c9e00000-0000-0000-0000-0000000000a1', $q$SELECT public.exos_claim_free_tickets('c9e00000-0000-0000-0000-0000000000e1',
    'c9e00000-0000-0000-0000-0000000000d6', 1, NULL, NULL, 'cs_cq_guest_1')::text$q$);
  ASSERT r LIKE 'ERR 42501%already in use%', 'CQ13: a guest order''s ref is refused to the owner too: ' || r;
  -- exos_record_checkout_answers: a session whose ref another buyer's answers hold is refused.
  INSERT INTO public.exos_question_answer_cursors (order_ref, org_id, event_id, tier_id, buyer_uid, ticket_count)
  VALUES ('cs_cq_taken', 'c9e00000-0000-0000-0000-000000000001', e, 'c9e00000-0000-0000-0000-0000000000d1', 'c9e00000-0000-0000-0000-0000000000f2', 1);
  PERFORM pg_temp.session('cs_cq_taken', e, 'c9e00000-0000-0000-0000-0000000000d1', 1, 'c9e00000-0000-0000-0000-0000000000f1', 'cq-fan@x.com');
  r := pg_temp.err(format($q$SELECT public.exos_record_checkout_answers('cs_cq_taken', '{"order":{"%s":true,"%s":"+15550100096"},"tickets":[{"%s":"M"}]}')$q$, qa, qn, qs));
  ASSERT r LIKE '42501%already in use%', 'CQ13: checkout refuses a ref another buyer holds: ' || coalesce(r, 'accepted');
  RAISE NOTICE 'OK  CQ13 order_ref: another buyer''s ref is refused or takes nothing; the buyer''s own (and parked) tickets still take their answers';
END $$;

-- CQ14 -----------------------------------------------------------------------
DO $$
DECLARE
  e uuid := 'c9e00000-0000-0000-0000-0000000000e1';
  qs uuid := pg_temp.qid('c9e00000-0000-0000-0000-0000000000e1', 'Shirt size');
  qa uuid := pg_temp.qid('c9e00000-0000-0000-0000-0000000000e1', 'I agree to the photo policy');
  qb uuid;
  t uuid := (SELECT ticket_ids[1] FROM public.exos_checkout_sessions WHERE session_id = 'cs_cq_paid_1');
  r text;
BEGIN
  qb := (public._exos_question_upsert('c9e00000-0000-0000-0000-000000000002', 'c9e00000-0000-0000-0000-0000000000e9', NULL,
    '{"label":"Org B secret label","kind":"text","required":true,"scope":"ticket"}', NULL)->>'id')::uuid;
  PERFORM pg_temp.session('cs_cq_leak', e, 'c9e00000-0000-0000-0000-0000000000d1', 1, 'c9e00000-0000-0000-0000-0000000000f2', 'cq-fan2@x.com');
  -- Another org's question id at checkout (per ticket and per order).
  r := pg_temp.err(format($q$SELECT public.exos_record_checkout_answers('cs_cq_leak', '{"order":{"%s":true},"tickets":[{"%s":"M","%s":"x"}]}')$q$, qa, qs, qb));
  ASSERT r LIKE '22023%not asked%' AND r NOT LIKE '%Org B secret label%' AND r NOT LIKE '%checkout question "%', 'CQ14: no label for an unknown question: ' || coalesce(r, 'accepted');
  r := pg_temp.err(format($q$SELECT public.exos_record_checkout_answers('cs_cq_leak', '{"order":{"%s":true,"%s":"x"},"tickets":[{"%s":"M"}]}')$q$, qa, qb, qs));
  ASSERT r LIKE '22023%' AND r NOT LIKE '%Org B secret label%', 'CQ14: nor as an order key: ' || coalesce(r, 'accepted');
  -- At the door.
  r := pg_temp.as_user('c9e00000-0000-0000-0000-0000000000a3', format($q$SELECT public.exos_door_set_ticket_answers('%s', '{"%s":"x"}')::text$q$, t, qb));
  ASSERT r LIKE 'ERR 22023%' AND r NOT LIKE '%Org B secret label%', 'CQ14: the door gets no label either: ' || r;
  -- Even a forged problem naming another event's question gets no label.
  r := pg_temp.err(format($q$SELECT public._exos_raise_answer_problem('{"problems":[{"code":"required","question_id":"%s","ticket":null}]}', 'c9e00000-0000-0000-0000-0000000000e1')$q$, qb));
  ASSERT r LIKE '22023%checkout questions: an answer is required%' AND r NOT LIKE '%Org B%', 'CQ14: labels only from the event validated: ' || coalesce(r, 'none');
  -- The event's own question is still named.
  r := pg_temp.err(format($q$SELECT public.exos_record_checkout_answers('cs_cq_leak', '{"order":{"%s":true},"tickets":[{}]}')$q$, qa));
  ASSERT r LIKE '22023%"Emergency contact"%required%', 'CQ14: own labels are still named: ' || coalesce(r, 'accepted');
  RAISE NOTICE 'OK  CQ14 validation errors never echo another event''s or org''s question label';
END $$;

-- CQ12 -----------------------------------------------------------------------
-- The parity cases. src/lib/checkoutQuestions.test.ts reads the JSON between
-- the CQ-CASES markers and runs it through _shared/questions.ts.
-- "q" names questions from "questions"; "tiers" names ticket types A / B;
-- "expect" lists "code|question|ticket" (any order); "normalized" is the
-- expected answers when ok.
CREATE TEMP TABLE cq_cases AS SELECT $cases$
-- CQ-CASES-BEGIN
{
  "tiers": { "A": "aaaaaaaa-0000-0000-0000-000000000001", "B": "aaaaaaaa-0000-0000-0000-000000000002" },
  "questions": {
    "size":    { "id": "c0000000-0000-0000-0000-000000000001", "label": "Size", "kind": "single_choice", "options": ["S", "M", "L", "XL"], "required": true, "scope": "ticket", "tier_ids": null },
    "diet":    { "id": "c0000000-0000-0000-0000-000000000002", "label": "Diet", "kind": "multiple_choice", "options": ["Vegan", "Vegetarian", "Gluten-free", "Halal"], "required": false, "scope": "ticket", "tier_ids": null, "max_choices": 2 },
    "company": { "id": "c0000000-0000-0000-0000-000000000003", "label": "Company", "kind": "text", "options": [], "required": false, "scope": "order", "tier_ids": null, "max_length": 10 },
    "agree":   { "id": "c0000000-0000-0000-0000-000000000004", "label": "Agree", "kind": "checkbox", "options": [], "required": true, "scope": "order", "tier_ids": null },
    "age":     { "id": "c0000000-0000-0000-0000-000000000005", "label": "Age", "kind": "number", "options": [], "required": false, "scope": "ticket", "tier_ids": null, "min_value": 0, "max_value": 120 },
    "dob":     { "id": "c0000000-0000-0000-0000-000000000006", "label": "Date", "kind": "date", "options": [], "required": false, "scope": "order", "tier_ids": null },
    "phone":   { "id": "c0000000-0000-0000-0000-000000000007", "label": "Phone", "kind": "phone", "options": [], "required": false, "scope": "order", "tier_ids": null },
    "email":   { "id": "c0000000-0000-0000-0000-000000000008", "label": "Email", "kind": "email", "options": [], "required": false, "scope": "order", "tier_ids": null },
    "viponly": { "id": "c0000000-0000-0000-0000-000000000009", "label": "VIP name", "kind": "text", "options": [], "required": true, "scope": "ticket", "tier_ids": ["aaaaaaaa-0000-0000-0000-000000000002"] },
    "notes":   { "id": "c0000000-0000-0000-0000-00000000000a", "label": "Notes", "kind": "long_text", "options": [], "required": false, "scope": "order", "tier_ids": null },
    "viporder":{ "id": "c0000000-0000-0000-0000-00000000000b", "label": "VIP order", "kind": "single_choice", "options": ["Yes", "No"], "required": true, "scope": "order", "tier_ids": ["aaaaaaaa-0000-0000-0000-000000000002"] },
    "pick2":   { "id": "c0000000-0000-0000-0000-00000000000c", "label": "Pick two", "kind": "multiple_choice", "options": ["A", "B", "C"], "required": false, "scope": "order", "tier_ids": null, "min_choices": 2 }
  },
  "cases": [
    { "name": "basic ok", "q": ["size", "company", "agree"], "tiers": ["A", "A"], "require": true,
      "answers": { "order": { "company": " Acme ", "agree": true }, "tickets": [{ "size": "M" }, { "size": " L" }] },
      "expect": [], "normalized": { "order": { "company": "Acme", "agree": true }, "tickets": [{ "size": "M" }, { "size": "L" }] } },
    { "name": "required per ticket", "q": ["size", "agree"], "tiers": ["A", "A"], "require": true,
      "answers": { "order": { "agree": true }, "tickets": [{ "size": "M" }] }, "expect": ["required|size|2"] },
    { "name": "required skipped at the door", "q": ["size", "agree"], "tiers": ["A", "A"], "require": false,
      "answers": { "order": { "agree": true }, "tickets": [{ "size": "M" }] }, "expect": [],
      "normalized": { "order": { "agree": true }, "tickets": [{ "size": "M" }, {}] } },
    { "name": "unticked agree", "q": ["agree"], "tiers": ["A"], "require": true, "answers": { "order": { "agree": false } }, "expect": ["required|agree|"] },
    { "name": "agree as text", "q": ["agree"], "tiers": ["A"], "require": true, "answers": { "order": { "agree": "yes" } }, "expect": ["invalid_value|agree|"] },
    { "name": "not an option", "q": ["size"], "tiers": ["A"], "require": true, "answers": { "tickets": [{ "size": "XXL" }] }, "expect": ["invalid_choice|size|1"] },
    { "name": "choice not text", "q": ["size"], "tiers": ["A"], "require": true, "answers": { "tickets": [{ "size": 3 }] }, "expect": ["invalid_value|size|1"] },
    { "name": "too long", "q": ["company"], "tiers": ["A"], "require": true, "answers": { "order": { "company": "12345678901" } }, "expect": ["too_long|company|"] },
    { "name": "max length after trim", "q": ["company"], "tiers": ["A"], "require": true, "answers": { "order": { "company": "  1234567890  " } }, "expect": [],
      "normalized": { "order": { "company": "1234567890" }, "tickets": [{}] } },
    { "name": "length in characters", "q": ["company"], "tiers": ["A"], "require": true, "answers": { "order": { "company": "éééééééééé" } }, "expect": [],
      "normalized": { "order": { "company": "éééééééééé" }, "tickets": [{}] } },
    { "name": "text not a string", "q": ["company"], "tiers": ["A"], "require": true, "answers": { "order": { "company": 42 } }, "expect": ["invalid_value|company|"] },
    { "name": "multiple normalised", "q": ["diet"], "tiers": ["A"], "require": true, "answers": { "tickets": [{ "diet": ["Halal", "Vegan", "Halal"] }] }, "expect": [],
      "normalized": { "order": {}, "tickets": [{ "diet": ["Vegan", "Halal"] }] } },
    { "name": "multiple too many", "q": ["diet"], "tiers": ["A"], "require": true, "answers": { "tickets": [{ "diet": ["Vegan", "Vegetarian", "Halal"] }] }, "expect": ["too_many_choices|diet|1"] },
    { "name": "multiple not a list", "q": ["diet"], "tiers": ["A"], "require": true, "answers": { "tickets": [{ "diet": "Vegan" }] }, "expect": ["invalid_value|diet|1"] },
    { "name": "multiple non-string", "q": ["diet"], "tiers": ["A"], "require": true, "answers": { "tickets": [{ "diet": ["Vegan", 1] }] }, "expect": ["invalid_value|diet|1"] },
    { "name": "multiple unknown option", "q": ["diet"], "tiers": ["A"], "require": true, "answers": { "tickets": [{ "diet": ["Paleo"] }] }, "expect": ["invalid_choice|diet|1"] },
    { "name": "multiple blank option", "q": ["diet"], "tiers": ["A"], "require": true, "answers": { "tickets": [{ "diet": [" "] }] }, "expect": ["invalid_choice|diet|1"] },
    { "name": "min choices", "q": ["pick2"], "tiers": ["A"], "require": true, "answers": { "order": { "pick2": ["A"] } }, "expect": ["too_few_choices|pick2|"] },
    { "name": "min choices, none picked (optional)", "q": ["pick2"], "tiers": ["A"], "require": true, "answers": { "order": { "pick2": [] } }, "expect": [],
      "normalized": { "order": {}, "tickets": [{}] } },
    { "name": "number from text", "q": ["age"], "tiers": ["A", "A"], "require": true, "answers": { "tickets": [{ "age": "42" }, { "age": 42.5 }] }, "expect": [],
      "normalized": { "order": {}, "tickets": [{ "age": 42 }, { "age": 42.5 }] } },
    { "name": "number zero and minus zero", "q": ["age"], "tiers": ["A", "A"], "require": true, "answers": { "tickets": [{ "age": 0 }, { "age": "-0" }] }, "expect": [],
      "normalized": { "order": {}, "tickets": [{ "age": 0 }, { "age": 0 }] } },
    { "name": "number trailing zeros", "q": ["age"], "tiers": ["A"], "require": true, "answers": { "tickets": [{ "age": "7.500" }] }, "expect": [],
      "normalized": { "order": {}, "tickets": [{ "age": 7.5 }] } },
    { "name": "number out of range", "q": ["age"], "tiers": ["A", "A"], "require": true, "answers": { "tickets": [{ "age": 121 }, { "age": "-1" }] },
      "expect": ["out_of_range|age|1", "out_of_range|age|2"] },
    { "name": "not numbers", "q": ["age"], "tiers": ["A", "A", "A", "A"], "require": true,
      "answers": { "tickets": [{ "age": "4o" }, { "age": "1.1234567" }, { "age": 1e15 }, { "age": true }] },
      "expect": ["not_a_number|age|1", "not_a_number|age|2", "not_a_number|age|3", "not_a_number|age|4"] },
    { "name": "dates", "q": ["dob"], "tiers": ["A"], "require": true, "answers": { "order": { "dob": "2024-02-29" } }, "expect": [],
      "normalized": { "order": { "dob": "2024-02-29" }, "tickets": [{}] } },
    { "name": "not a leap year", "q": ["dob"], "tiers": ["A"], "require": true, "answers": { "order": { "dob": "2023-02-29" } }, "expect": ["invalid_date|dob|"] },
    { "name": "month 13", "q": ["dob"], "tiers": ["A"], "require": true, "answers": { "order": { "dob": "2024-13-01" } }, "expect": ["invalid_date|dob|"] },
    { "name": "short year", "q": ["dob"], "tiers": ["A"], "require": true, "answers": { "order": { "dob": "24-01-01" } }, "expect": ["invalid_date|dob|"] },
    { "name": "before 1900", "q": ["dob"], "tiers": ["A"], "require": true, "answers": { "order": { "dob": "1899-12-31" } }, "expect": ["invalid_date|dob|"] },
    { "name": "phone normalised", "q": ["phone"], "tiers": ["A"], "require": true, "answers": { "order": { "phone": " +1 (555) 010-9999 " } }, "expect": [],
      "normalized": { "order": { "phone": "+15550109999" }, "tickets": [{}] } },
    { "name": "phone too short", "q": ["phone"], "tiers": ["A"], "require": true, "answers": { "order": { "phone": "12345" } }, "expect": ["invalid_phone|phone|"] },
    { "name": "phone with letters", "q": ["phone"], "tiers": ["A"], "require": true, "answers": { "order": { "phone": "abc1234567" } }, "expect": ["invalid_phone|phone|"] },
    { "name": "email normalised", "q": ["email"], "tiers": ["A"], "require": true, "answers": { "order": { "email": " Ada@Example.COM " } }, "expect": [],
      "normalized": { "order": { "email": "ada@example.com" }, "tickets": [{}] } },
    { "name": "email without a dot", "q": ["email"], "tiers": ["A"], "require": true, "answers": { "order": { "email": "ada@example" } }, "expect": ["invalid_email|email|"] },
    { "name": "email with a space", "q": ["email"], "tiers": ["A"], "require": true, "answers": { "order": { "email": "a b@c.de" } }, "expect": ["invalid_email|email|"] },
    { "name": "unknown question", "q": ["company"], "tiers": ["A"], "require": true, "answers": { "order": { "zzz": "x" } }, "expect": ["unknown_question|zzz|"] },
    { "name": "wrong scope", "q": ["size", "company"], "tiers": ["A"], "require": true, "answers": { "order": { "size": "M" } },
      "expect": ["wrong_scope|size|", "required|size|1"] },
    { "name": "order question per ticket", "q": ["company"], "tiers": ["A"], "require": true, "answers": { "tickets": [{ "company": "Acme" }] },
      "expect": ["wrong_scope|company|1"] },
    { "name": "not for this ticket type", "q": ["viponly"], "tiers": ["A"], "require": true, "answers": { "tickets": [{ "viponly": "x" }] },
      "expect": ["not_for_ticket_type|viponly|1"] },
    { "name": "required on the VIP ticket only", "q": ["viponly"], "tiers": ["A", "B"], "require": true, "answers": { "tickets": [{}, {}] },
      "expect": ["required|viponly|2"] },
    { "name": "order question for VIP orders: GA only", "q": ["viporder"], "tiers": ["A"], "require": true, "answers": {}, "expect": [],
      "normalized": { "order": {}, "tickets": [{}] } },
    { "name": "order question for VIP orders: mixed", "q": ["viporder"], "tiers": ["A", "B"], "require": true, "answers": {}, "expect": ["required|viporder|"] },
    { "name": "order question for VIP orders: on GA", "q": ["viporder"], "tiers": ["A"], "require": true, "answers": { "order": { "viporder": "Yes" } },
      "expect": ["not_for_ticket_type|viporder|"] },
    { "name": "too many tickets", "q": ["size"], "tiers": ["A"], "require": false, "answers": { "tickets": [{}, {}] }, "expect": ["too_many_tickets||"] },
    { "name": "not an object", "q": ["size"], "tiers": ["A"], "require": false, "answers": "nope", "expect": ["bad_shape||"] },
    { "name": "tickets not a list", "q": ["size"], "tiers": ["A"], "require": false, "answers": { "tickets": {} }, "expect": ["bad_shape||"] },
    { "name": "ticket entry not an object", "q": ["size"], "tiers": ["A"], "require": false, "answers": { "tickets": [1] }, "expect": ["bad_shape||"] },
    { "name": "order not an object", "q": ["size"], "tiers": ["A"], "require": false, "answers": { "order": [] }, "expect": ["bad_shape||"] },
    { "name": "no answers, nothing required", "q": ["company", "notes"], "tiers": ["A"], "require": true, "answers": null, "expect": [],
      "normalized": { "order": {}, "tickets": [{}] } },
    { "name": "null ticket entry", "q": ["size"], "tiers": ["A", "A"], "require": false, "answers": { "tickets": [null, { "size": "S" }] }, "expect": [],
      "normalized": { "order": {}, "tickets": [{}, { "size": "S" }] } },
    { "name": "blank text is no answer", "q": ["company", "notes"], "tiers": ["A"], "require": true, "answers": { "order": { "company": "   ", "notes": "\n" } }, "expect": [],
      "normalized": { "order": {}, "tickets": [{}] } },
    { "name": "many problems at once", "q": ["size", "agree", "email"], "tiers": ["A", "A"], "require": true,
      "answers": { "order": { "email": "nope", "agree": 1 }, "tickets": [{ "size": "XXL" }] },
      "expect": ["invalid_email|email|", "invalid_value|agree|", "invalid_choice|size|1", "required|size|2"] }
  ]
}
-- CQ-CASES-END
$cases$::text AS doc;

DO $$
DECLARE
  doc jsonb := (SELECT substring(doc from '-- CQ-CASES-BEGIN(.*)-- CQ-CASES-END')::jsonb FROM cq_cases);
  c jsonb; qs jsonb; tiers uuid[]; res jsonb; got text[]; want text[]; bad text := ''; n int := 0; id_to_name jsonb;
BEGIN
  SELECT jsonb_object_agg(value->>'id', key) INTO id_to_name FROM jsonb_each(doc->'questions');
  FOR c IN SELECT x FROM jsonb_array_elements(doc->'cases') x LOOP
    qs := (SELECT jsonb_agg(doc->'questions'->(nm #>> '{}')) FROM jsonb_array_elements(c->'q') nm);
    tiers := ARRAY(SELECT (doc->'tiers'->>(t #>> '{}'))::uuid FROM jsonb_array_elements(c->'tiers') WITH ORDINALITY AS u(t, i) ORDER BY i);
    -- Answers name questions by key: translate to ids.
    res := public._exos_validate_answers_core(qs, tiers,
      CASE WHEN jsonb_typeof(c->'answers') = 'object' THEN
        jsonb_strip_nulls(jsonb_build_object(
          'order', CASE WHEN jsonb_typeof(c->'answers'->'order') = 'object'
                        THEN (SELECT coalesce(jsonb_object_agg(coalesce(doc->'questions'->k->>'id', k), v), '{}'::jsonb) FROM jsonb_each(c->'answers'->'order') e(k, v))
                        ELSE c->'answers'->'order' END,
          'tickets', CASE WHEN jsonb_typeof(c->'answers'->'tickets') = 'array'
                          THEN (SELECT coalesce(jsonb_agg(CASE WHEN jsonb_typeof(t) = 'object'
                                   THEN (SELECT coalesce(jsonb_object_agg(coalesce(doc->'questions'->k->>'id', k), v), '{}'::jsonb) FROM jsonb_each(t) e(k, v))
                                   ELSE t END ORDER BY i), '[]'::jsonb)
                                  FROM jsonb_array_elements(c->'answers'->'tickets') WITH ORDINALITY AS u(t, i))
                          ELSE c->'answers'->'tickets' END))
      ELSE c->'answers' END,
      (c->>'require')::boolean);
    got := ARRAY(SELECT s FROM (SELECT (p->>'code') || '|' || coalesce(id_to_name->>(p->>'question_id'), p->>'question_id', '') || '|' || coalesce(p->>'ticket', '') AS s
                   FROM jsonb_array_elements(res->'problems') p) z ORDER BY s COLLATE "C");
    want := ARRAY(SELECT s FROM (SELECT x #>> '{}' AS s FROM jsonb_array_elements(c->'expect') x) z ORDER BY s COLLATE "C");
    IF got IS DISTINCT FROM want THEN
      bad := bad || format(E'\n  %s: want %s got %s', c->>'name', want, got);
    ELSIF c ? 'normalized' THEN
      -- Compare with the answers renamed back to the case's keys.
      IF jsonb_build_object(
           'order', (SELECT coalesce(jsonb_object_agg(id_to_name->>k, v), '{}'::jsonb) FROM jsonb_each(res->'answers'->'order') e(k, v)),
           'tickets', (SELECT coalesce(jsonb_agg((SELECT coalesce(jsonb_object_agg(id_to_name->>k, v), '{}'::jsonb) FROM jsonb_each(t) e(k, v)) ORDER BY i), '[]'::jsonb)
                         FROM jsonb_array_elements(res->'answers'->'tickets') WITH ORDINALITY AS u(t, i)))
         IS DISTINCT FROM c->'normalized' THEN
        bad := bad || format(E'\n  %s: normalised %s', c->>'name', res->'answers');
      END IF;
    END IF;
    n := n + 1;
  END LOOP;
  ASSERT bad = '', 'CQ12: SQL disagrees with the shared cases:' || bad;
  RAISE NOTICE 'OK  CQ12 TS/SQL parity: % shared cases agree in SQL', n;
END $$;

ROLLBACK;
