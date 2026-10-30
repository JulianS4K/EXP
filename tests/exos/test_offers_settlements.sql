-- ============================================================================
-- Offers, settlements, finance, P&L and ticket counts (migs 20261031100000 +
-- 20261031100500). Self-contained (cf… ids), rolled back at the end.
--   OS1 grants: no anon table access; offers / settlements / schedules have
--       no client write path; token hashes have no client column grant; the
--       cores are service_role only; only the token functions are anon
--   OS2 finance categories (seeded, built-ins kept) and GL codes
--   OS3 offers: create from a hold and a template, terms validation, roles,
--       send (token, mail, webhook), the agent's link, accept / decline,
--       editing a sent offer, expiry, cancel, delete
--   OS4 shared budgets, offer pools, imports (partial), the hold converting
--   OS5 box office from Exos sales, sold elsewhere (seam), settlement
--       seeding, adjustments, finalize (frozen), the contacts' link, reopen
--   OS6 P&L inputs
--   OS7 ticket-count emails: defaults, send now, the run (claim, move,
--       dedupe), opt-out, switching off
--   OS8 CRM deals
--   OS9 cross-org isolation
--   psql -d <db> -v ON_ERROR_STOP=1 -f tests/exos/test_offers_settlements.sql
-- ============================================================================
\set ON_ERROR_STOP on
BEGIN;

INSERT INTO auth.users (id, email, email_confirmed_at) VALUES
  ('cf000000-0000-0000-0000-0000000000a0', 'cf-owner@x.com', now()),
  ('cf000000-0000-0000-0000-0000000000a1', 'cf-manager@x.com', now()),
  ('cf000000-0000-0000-0000-0000000000a2', 'cf-finance@x.com', now()),
  ('cf000000-0000-0000-0000-0000000000a3', 'cf-scanner@x.com', now()),
  ('cf000000-0000-0000-0000-0000000000a4', 'cf-content@x.com', now()),
  ('cf000000-0000-0000-0000-0000000000b9', 'cf-other@x.com', now());
INSERT INTO public.exos_orgs (id, name, slug, owner_uid) VALUES
  ('cf000000-0000-0000-0000-000000000001', 'CF Org', 'cf-org', 'cf000000-0000-0000-0000-0000000000a0'),
  ('cf000000-0000-0000-0000-000000000002', 'CF Other', 'cf-other', 'cf000000-0000-0000-0000-0000000000b9');
INSERT INTO public.exos_org_memberships (org_id, user_id, role) VALUES
  ('cf000000-0000-0000-0000-000000000001', 'cf000000-0000-0000-0000-0000000000a0', 'owner'),
  ('cf000000-0000-0000-0000-000000000001', 'cf000000-0000-0000-0000-0000000000a1', 'manager'),
  ('cf000000-0000-0000-0000-000000000001', 'cf000000-0000-0000-0000-0000000000a2', 'finance'),
  ('cf000000-0000-0000-0000-000000000001', 'cf000000-0000-0000-0000-0000000000a3', 'scanner'),
  ('cf000000-0000-0000-0000-000000000001', 'cf000000-0000-0000-0000-0000000000a4', 'content'),
  ('cf000000-0000-0000-0000-000000000002', 'cf000000-0000-0000-0000-0000000000b9', 'owner');
INSERT INTO public.exos_webhooks (id, org_id, url, event_types) VALUES
  ('cf000000-0000-0000-0000-0000000000c1', 'cf000000-0000-0000-0000-000000000001', 'https://hooks.example/cf', ARRAY['*']);

GRANT SELECT, INSERT, UPDATE ON public.exos_events TO authenticated;
GRANT SELECT ON public.exos_ticket_tiers TO authenticated;

CREATE FUNCTION pg_temp.as_user(p_uid text) RETURNS void LANGUAGE sql AS $$
  SELECT set_config('app.uid', coalesce(p_uid, ''), true)::text IS NOT NULL AND true;
$$;
GRANT EXECUTE ON FUNCTION pg_temp.as_user(text) TO anon, authenticated, service_role;
CREATE TEMP TABLE cf (k text PRIMARY KEY, v text);
GRANT ALL ON cf TO anon, authenticated, service_role;
CREATE FUNCTION pg_temp.g(p_k text) RETURNS uuid LANGUAGE sql AS $$ SELECT v::uuid FROM cf WHERE k = p_k $$;
CREATE FUNCTION pg_temp.gt(p_k text) RETURNS text LANGUAGE sql AS $$ SELECT v FROM cf WHERE k = p_k $$;
GRANT EXECUTE ON FUNCTION pg_temp.g(text), pg_temp.gt(text) TO anon, authenticated, service_role;

-- A venue the org rents, a hold with rental terms on it, a template.
INSERT INTO public.exos_venues (id, org_id, name, timezone, capacity, relationship)
VALUES ('cf000000-0000-0000-0000-0000000000f1', 'cf000000-0000-0000-0000-000000000001', 'Metro', 'America/Chicago', 500, 'rented');
INSERT INTO public.exos_artists (id, org_id, name, permalink)
VALUES ('cf000000-0000-0000-0000-0000000000f2', 'cf000000-0000-0000-0000-000000000001', 'The Headliners', 'the-headliners'),
       ('cf000000-0000-0000-0000-0000000000f3', 'cf000000-0000-0000-0000-000000000002', 'Not Ours', 'not-ours');

-- OS1 ------------------------------------------------------------------------
DO $$
DECLARE t text; f text;
BEGIN
  FOREACH t IN ARRAY ARRAY['exos_gl_codes', 'exos_finance_categories', 'exos_budgets', 'exos_budget_lines', 'exos_offer_pools',
                           'exos_offer_templates', 'exos_offer_imports', 'exos_offers', 'exos_crm_deals', 'exos_finance_items',
                           'exos_settlements', 'exos_ticket_count_schedules', 'exos_ticket_count_recipients'] LOOP
    ASSERT NOT has_table_privilege('anon', 'public.' || t, 'SELECT'), 'OS1: anon reads ' || t;
    ASSERT (SELECT relrowsecurity FROM pg_class WHERE oid = ('public.' || t)::regclass), 'OS1: RLS on ' || t;
  END LOOP;
  FOREACH t IN ARRAY ARRAY['exos_offers', 'exos_offer_imports', 'exos_settlements', 'exos_ticket_count_schedules',
                           'exos_ticket_count_recipients'] LOOP
    ASSERT NOT has_table_privilege('authenticated', 'public.' || t, 'INSERT')
       AND NOT has_table_privilege('authenticated', 'public.' || t, 'UPDATE')
       AND NOT has_table_privilege('authenticated', 'public.' || t, 'DELETE'), 'OS1: client writes ' || t;
  END LOOP;
  ASSERT NOT has_column_privilege('authenticated', 'public.exos_offers', 'response_token_hash', 'SELECT'), 'OS1: offer token hash';
  ASSERT NOT has_column_privilege('authenticated', 'public.exos_settlements', 'link_token_hash', 'SELECT'), 'OS1: settlement token hash';
  ASSERT NOT has_column_privilege('authenticated', 'public.exos_settlements', 'snapshot', 'SELECT'), 'OS1: snapshot via the functions only';
  ASSERT NOT has_column_privilege('authenticated', 'public.exos_ticket_count_recipients', 'optout_token', 'SELECT'), 'OS1: opt-out token';
  FOREACH f IN ARRAY ARRAY['public._exos_offer_save(uuid,uuid,text,uuid,uuid,jsonb)', 'public._exos_offer_send(uuid,uuid,uuid,text)',
                           'public._exos_offer_record_response(uuid,uuid,uuid,text,text,text,text,text,text)',
                           'public._exos_offer_import(uuid,uuid,text,uuid,text,jsonb)', 'public._exos_settlement_get(uuid,uuid)',
                           'public._exos_settlement_finalize(uuid,uuid,uuid,integer)', 'public._exos_settlement_inputs(uuid)',
                           'public._exos_pnl_inputs(uuid,date,date)', 'public._exos_tc_save(uuid,uuid,jsonb)',
                           'public.exos_ticket_counts_run(integer)', 'public._exos_box_office(uuid)'] LOOP
    ASSERT NOT has_function_privilege('authenticated', f, 'EXECUTE') AND NOT has_function_privilege('anon', f, 'EXECUTE'),
           'OS1: clients execute ' || f;
    ASSERT has_function_privilege('service_role', f, 'EXECUTE'), 'OS1: service_role executes ' || f;
  END LOOP;
  FOREACH f IN ARRAY ARRAY['public.exos_offer_create(uuid,jsonb)', 'public.exos_settlement_finalize(uuid,integer)',
                           'public.exos_ticket_counts_save(uuid,jsonb)', 'public.exos_pnl_inputs(uuid,date,date)'] LOOP
    ASSERT NOT has_function_privilege('anon', f, 'EXECUTE') AND has_function_privilege('authenticated', f, 'EXECUTE'),
           'OS1: wrapper grants ' || f;
  END LOOP;
  FOREACH f IN ARRAY ARRAY['public.exos_offer_public(uuid,text)', 'public.exos_offer_respond(uuid,text,text,text,text)',
                           'public.exos_settlement_public(uuid,text)', 'public.exos_ticket_counts_optout(text,boolean)'] LOOP
    ASSERT has_function_privilege('anon', f, 'EXECUTE'), 'OS1: anon token function ' || f;
  END LOOP;
  RAISE NOTICE 'OK  OS1 grants';
END $$;

-- OS2 ------------------------------------------------------------------------
SET ROLE authenticated;
DO $$
DECLARE n int; ok boolean; v uuid; gl uuid;
BEGIN
  PERFORM pg_temp.as_user('cf000000-0000-0000-0000-0000000000a3');   -- a scanner can't seed or read
  ok := false;
  BEGIN PERFORM public.exos_finance_categories_ensure('cf000000-0000-0000-0000-000000000001');
  EXCEPTION WHEN insufficient_privilege THEN ok := true; END;
  ASSERT ok, 'OS2: scanner seeds';
  PERFORM pg_temp.as_user('cf000000-0000-0000-0000-0000000000a2');   -- finance seeds
  n := public.exos_finance_categories_ensure('cf000000-0000-0000-0000-000000000001');
  ASSERT n = 9, 'OS2: nine defaults, got ' || n;
  ASSERT public.exos_finance_categories_ensure('cf000000-0000-0000-0000-000000000001') = 9, 'OS2: seeding is idempotent';
  ASSERT (SELECT count(*) FROM public.exos_finance_categories WHERE system) = 4, 'OS2: four built-ins';
  -- A built-in renames and takes a GL code; it can't change kind or be deleted.
  INSERT INTO public.exos_gl_codes (org_id, code, name, kind) VALUES ('cf000000-0000-0000-0000-000000000001', '5100', 'Talent fees', 'expense')
  RETURNING id INTO gl;
  INSERT INTO cf VALUES ('gl', gl);
  UPDATE public.exos_finance_categories SET name = 'Artist fees', gl_code_id = gl WHERE key = 'talent';
  ASSERT (SELECT name = 'Artist fees' AND gl_code_id = gl FROM public.exos_finance_categories WHERE key = 'talent'), 'OS2: rename + code';
  ok := false;
  BEGIN UPDATE public.exos_finance_categories SET kind = 'income' WHERE key = 'talent';
  EXCEPTION WHEN object_not_in_prerequisite_state THEN ok := true; END;
  ASSERT ok, 'OS2: a built-in keeps its kind';
  DELETE FROM public.exos_finance_categories WHERE key = 'talent';
  ASSERT EXISTS (SELECT 1 FROM public.exos_finance_categories WHERE key = 'talent'), 'OS2: a built-in is not deleted';
  -- A custom category; one can't take a built-in key.
  INSERT INTO public.exos_finance_categories (org_id, name, kind) VALUES ('cf000000-0000-0000-0000-000000000001', 'Security', 'expense')
  RETURNING id INTO v;
  DELETE FROM public.exos_finance_categories WHERE id = v;
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_finance_categories WHERE id = v), 'OS2: a custom category is deleted';
  ok := false;
  BEGIN INSERT INTO public.exos_finance_categories (org_id, key, name, kind) VALUES ('cf000000-0000-0000-0000-000000000001', 'talent', 'Fake', 'income');
  EXCEPTION WHEN unique_violation THEN ok := true; END;
  ASSERT ok, 'OS2: built-in key taken';
  -- Duplicate live code refused; discarding unlinks; the code can be reused.
  ok := false;
  BEGIN INSERT INTO public.exos_gl_codes (org_id, code, name) VALUES ('cf000000-0000-0000-0000-000000000001', '5100', 'Dup');
  EXCEPTION WHEN unique_violation THEN ok := true; END;
  ASSERT ok, 'OS2: duplicate GL code';
  UPDATE public.exos_gl_codes SET discarded_at = now() WHERE id = gl;
  ASSERT (SELECT gl_code_id IS NULL FROM public.exos_finance_categories WHERE key = 'talent'), 'OS2: discard unlinks';
  INSERT INTO public.exos_gl_codes (org_id, code, name) VALUES ('cf000000-0000-0000-0000-000000000001', '5100', 'Talent fees')
  RETURNING id INTO gl;
  UPDATE public.exos_finance_categories SET gl_code_id = gl WHERE key = 'talent';
  UPDATE cf SET v = gl WHERE k = 'gl';
  -- Content and scanners see nothing; content can't write.
  PERFORM pg_temp.as_user('cf000000-0000-0000-0000-0000000000a4');
  ASSERT (SELECT count(*) FROM public.exos_finance_categories) = 0, 'OS2: content reads categories';
  ASSERT (SELECT count(*) FROM public.exos_gl_codes) = 0, 'OS2: content reads GL codes';
  ok := false;
  BEGIN INSERT INTO public.exos_gl_codes (org_id, code, name) VALUES ('cf000000-0000-0000-0000-000000000001', '9999', 'X');
  EXCEPTION WHEN insufficient_privilege THEN ok := true; END;
  ASSERT ok, 'OS2: content writes a GL code';
  RAISE NOTICE 'OK  OS2 finance categories and GL codes';
END $$;
RESET ROLE;

-- The hold (rental terms) and a template, set up as the service role.
DO $$
DECLARE r jsonb;
BEGIN
  r := public._exos_hold_create('cf000000-0000-0000-0000-000000000001', 'cf000000-0000-0000-0000-0000000000a1', 'api', NULL,
         jsonb_build_object('title', 'Headliners at Metro', 'artist_ids', jsonb_build_array('cf000000-0000-0000-0000-0000000000f2'),
                            'rental', jsonb_build_object('status', 'confirmed', 'fee', 1500, 'deposit', 500),
                            'positions', jsonb_build_array(jsonb_build_object('date', '2026-11-19', 'venue_id', 'cf000000-0000-0000-0000-0000000000f1'))));
  INSERT INTO cf VALUES ('hold', r->>'id');
  INSERT INTO public.exos_offer_templates (id, org_id, name, terms, boilerplate, budget_lines, expires_in_days, sell_through_percent)
  VALUES ('cf000000-0000-0000-0000-0000000000d1', 'cf000000-0000-0000-0000-000000000001', 'Club standard',
          '{"deal_type":"versus","guarantee_cents":100000,"percentage":85}', 'Subject to contract.',
          '[{"category_key":"production","kind":"expense","label":"Sound and lights","amount_cents":150000},
            {"category_key":"marketing","kind":"expense","label":"Ads","amount_cents":50000}]', 7, 80);
END $$;

-- OS3 ------------------------------------------------------------------------
SET ROLE authenticated;
DO $$
DECLARE r jsonb; o uuid; ok boolean; b uuid;
BEGIN
  -- Content can't make an offer; nobody reads offers without the role.
  PERFORM pg_temp.as_user('cf000000-0000-0000-0000-0000000000a4');
  ok := false;
  BEGIN PERFORM public.exos_offer_create('cf000000-0000-0000-0000-000000000001', '{"artist_name":"X"}');
  EXCEPTION WHEN insufficient_privilege THEN ok := true; END;
  ASSERT ok, 'OS3: content creates an offer';

  PERFORM pg_temp.as_user('cf000000-0000-0000-0000-0000000000a1');   -- manager
  -- From the hold and the template: dates, venue, artist, capacity, rental line, expiry.
  r := public.exos_offer_create('cf000000-0000-0000-0000-000000000001', jsonb_build_object(
         'hold_id', pg_temp.g('hold'), 'template_id', 'cf000000-0000-0000-0000-0000000000d1',
         'terms', jsonb_build_object('bonuses', jsonb_build_array(jsonb_build_object('sold', 450, 'amount_cents', 50000),
                                                                   jsonb_build_object('sold', 400, 'amount_cents', 25000))),
         'budget', jsonb_build_object('average_price_cents', 2500),
         'agent', jsonb_build_object('name', 'Ann Agent', 'email', ' Ann@Agency.Example ')));
  o := (r->>'id')::uuid; b := (r->>'budget_id')::uuid;
  INSERT INTO cf VALUES ('o1', o), ('b1', b);
  ASSERT r->>'status' = 'draft' AND r->>'artist_name' = 'The Headliners' AND r->>'title' = 'Headliners at Metro',
         'OS3: draft from the hold: ' || r::text;
  ASSERT r->'dates' = '["2026-11-19"]'::jsonb AND (r->>'venue_id')::uuid = 'cf000000-0000-0000-0000-0000000000f1', 'OS3: dates + venue';
  ASSERT r->'terms'->>'deal_type' = 'versus' AND (r->'terms'->>'guarantee_cents')::int = 100000, 'OS3: template terms';
  ASSERT (r->'terms'->'bonuses'->0->>'sold')::int = 400, 'OS3: bonuses sorted by threshold';
  ASSERT r->'agent'->>'email' = 'ann@agency.example', 'OS3: agent email lowercased';
  ASSERT r->>'boilerplate' = 'Subject to contract.' AND (r->>'expires_at')::timestamptz > now() + interval '6 days', 'OS3: boilerplate + expiry';
  ASSERT (SELECT capacity = 500 AND average_price_cents = 2500 AND sell_through_percent = 80 AND currency = 'USD'
            FROM public.exos_budgets WHERE id = b), 'OS3: budget from the venue and template';
  ASSERT (SELECT count(*) FROM public.exos_budget_lines WHERE budget_id = b) = 3, 'OS3: template lines + the rental line';
  ASSERT (SELECT amount_cents FROM public.exos_budget_lines l JOIN public.exos_finance_categories c ON c.id = l.category_id
           WHERE l.budget_id = b AND c.key = 'venue-rental') = 150000, 'OS3: rental line from the hold';
  -- Validation.
  ok := false;
  BEGIN PERFORM public.exos_offer_update(o, '{"terms":{"deal_type":"backend"}}');
  EXCEPTION WHEN invalid_parameter_value THEN ok := true; END;
  ASSERT ok, 'OS3: bad deal type';
  ok := false;
  BEGIN PERFORM public.exos_offer_update(o, '{"terms":{"percentage":100.5}}');
  EXCEPTION WHEN invalid_parameter_value THEN ok := true; END;
  ASSERT ok, 'OS3: percentage over 100';
  ok := false;
  BEGIN PERFORM public.exos_offer_update(o, '{"terms":{"guarantee_cents":12.5}}');
  EXCEPTION WHEN invalid_parameter_value THEN ok := true; END;
  ASSERT ok, 'OS3: fractional cents';
  ok := false;
  BEGIN PERFORM public.exos_offer_update(o, '{"artist_id":"cf000000-0000-0000-0000-0000000000f3"}');
  EXCEPTION WHEN invalid_parameter_value THEN ok := true; END;
  ASSERT ok, 'OS3: another org''s artist';
  -- Partial terms merge.
  r := public.exos_offer_update(o, '{"terms":{"expenses_cap_cents":150000},"notes":"internal"}');
  ASSERT (r->'terms'->>'expenses_cap_cents')::int = 150000 AND r->'terms'->>'deal_type' = 'versus', 'OS3: terms merge';
  -- Finance reads, but can't send.
  PERFORM pg_temp.as_user('cf000000-0000-0000-0000-0000000000a2');
  ASSERT (SELECT count(*) FROM public.exos_offers WHERE id = o) = 1, 'OS3: finance reads offers';
  ok := false;
  BEGIN PERFORM public.exos_offer_send(o);
  EXCEPTION WHEN insufficient_privilege THEN ok := true; END;
  ASSERT ok, 'OS3: finance sends';
  PERFORM pg_temp.as_user('cf000000-0000-0000-0000-0000000000a4');
  ASSERT (SELECT count(*) FROM public.exos_offers) = 0, 'OS3: content reads offers';

  -- Send: link token, mail, webhook.
  PERFORM pg_temp.as_user('cf000000-0000-0000-0000-0000000000a1');
  r := public.exos_offer_send(o);
  ASSERT r->>'status' = 'sent' AND r->>'sent_to' = 'ann@agency.example', 'OS3: sent';
  ASSERT r->>'link_path' ~ ('^/offer/' || o || '\?t=[0-9a-f]{64}$'), 'OS3: link path';
  INSERT INTO cf VALUES ('tok1', substring(r->>'link_path' FROM 't=([0-9a-f]{64})'));
  -- Editing the terms of a sent offer takes it back to draft and kills the link.
  r := public.exos_offer_update(o, '{"terms":{"guarantee_cents":120000}}');
  ASSERT r->>'status' = 'draft', 'OS3: back to draft';
  r := public.exos_offer_send(o, 'booker@agency.example');
  ASSERT r->>'sent_to' = 'booker@agency.example', 'OS3: send to another address';
  INSERT INTO cf VALUES ('tok2', substring(r->>'link_path' FROM 't=([0-9a-f]{64})'));
  -- Notes alone don't touch a sent offer.
  r := public.exos_offer_update(o, '{"notes":"chasing"}');
  ASSERT r->>'status' = 'sent', 'OS3: notes keep it sent';
  RAISE NOTICE 'OK  OS3a offers: create, validate, roles, send';
END $$;
RESET ROLE;
DO $$
BEGIN
  ASSERT (SELECT count(*) FROM public.exos_mail WHERE template = 'offer-sent') = 2, 'OS3: two offer mails';
  ASSERT (SELECT payload->>'token' FROM public.exos_mail WHERE template = 'offer-sent' AND to_email = 'booker@agency.example') = pg_temp.gt('tok2'),
         'OS3: the mail carries the token';
  ASSERT (SELECT response_token_hash FROM public.exos_offers WHERE id = pg_temp.g('o1'))
         = encode(extensions.digest(pg_temp.gt('tok2'), 'sha256'), 'hex'), 'OS3: only the hash is stored';
  ASSERT (SELECT count(*) FROM public.exos_webhook_deliveries WHERE event_type = 'offer.sent') = 2, 'OS3: offer.sent webhooks';
END $$;

-- The agent's link.
SET ROLE anon;
DO $$
DECLARE r jsonb; ok boolean;
BEGIN
  ok := false;
  BEGIN PERFORM public.exos_offer_public(pg_temp.g('o1'), pg_temp.gt('tok1'));
  EXCEPTION WHEN no_data_found THEN ok := true; END;
  ASSERT ok, 'OS3: the rotated token is dead';
  ok := false;
  BEGIN PERFORM public.exos_offer_public(pg_temp.g('o1'), 'nope');
  EXCEPTION WHEN no_data_found THEN ok := true; END;
  ASSERT ok, 'OS3: malformed token';
  r := public.exos_offer_public(pg_temp.g('o1'), pg_temp.gt('tok2'));
  ASSERT r->>'status' = 'sent' AND r->'org'->>'name' = 'CF Org' AND r->'venue'->>'name' = 'Metro', 'OS3: public view';
  ASSERT NOT (r ? 'notes') AND NOT (r ? 'history') AND NOT (r ? 'agent'), 'OS3: no internals on the public view';
  ok := false;
  BEGIN PERFORM public.exos_offer_respond(pg_temp.g('o1'), pg_temp.gt('tok2'), 'accept', '  ');
  EXCEPTION WHEN invalid_parameter_value THEN ok := true; END;
  ASSERT ok, 'OS3: name required';
  PERFORM set_config('request.headers', '{"x-forwarded-for":"203.0.113.9, 10.0.0.1","user-agent":"AgentBrowser/1"}', true);
  r := public.exos_offer_respond(pg_temp.g('o1'), pg_temp.gt('tok2'), 'accept', 'Ann Agent', 'Great');
  ASSERT r->>'status' = 'accepted' AND r->'response'->>'name' = 'Ann Agent', 'OS3: accepted on the link';
  ok := false;
  BEGIN PERFORM public.exos_offer_respond(pg_temp.g('o1'), pg_temp.gt('tok2'), 'decline', 'Ann');
  EXCEPTION WHEN object_not_in_prerequisite_state THEN ok := true; END;
  ASSERT ok, 'OS3: answered once';
  ASSERT public.exos_offer_public(pg_temp.g('o1'), pg_temp.gt('tok2'))->>'status' = 'accepted', 'OS3: the link stays readable';
  RAISE NOTICE 'OK  OS3b the agent''s link';
END $$;
RESET ROLE;
DO $$
BEGIN
  ASSERT (SELECT response->>'ip' = '203.0.113.9' AND response->>'user_agent' = 'AgentBrowser/1' AND response->>'via' = 'link'
            FROM public.exos_offers WHERE id = pg_temp.g('o1')), 'OS3: IP and user agent recorded';
  ASSERT (SELECT count(*) FROM public.exos_webhook_deliveries WHERE event_type = 'offer.accepted') = 1, 'OS3: offer.accepted webhook';
END $$;

SET ROLE authenticated;
DO $$
DECLARE r jsonb; o uuid; ok boolean;
BEGIN
  PERFORM pg_temp.as_user('cf000000-0000-0000-0000-0000000000a1');
  -- An accepted offer only takes notes and event_id.
  ok := false;
  BEGIN PERFORM public.exos_offer_update(pg_temp.g('o1'), '{"terms":{"guarantee_cents":1}}');
  EXCEPTION WHEN object_not_in_prerequisite_state THEN ok := true; END;
  ASSERT ok, 'OS3: accepted terms are fixed';
  PERFORM public.exos_offer_update(pg_temp.g('o1'), '{"notes":"signed"}');
  -- Expiry: a sent offer past its expiry reads as expired and can't be answered.
  r := public.exos_offer_create('cf000000-0000-0000-0000-000000000001', '{"artist_name":"Late Act","agent":{"email":"late@x.example"}}');
  o := (r->>'id')::uuid;
  r := public.exos_offer_send(o);
  INSERT INTO cf VALUES ('o_late', o), ('tok_late', substring(r->>'link_path' FROM 't=([0-9a-f]{64})'));
  PERFORM public.exos_offer_update(o, jsonb_build_object('expires_at', to_jsonb(now() - interval '1 minute')));
  -- Staff records an answer for a draft (api / dashboard).
  r := public.exos_offer_create('cf000000-0000-0000-0000-000000000001', '{"artist_name":"Phone Deal"}');
  r := public.exos_offer_record_response((r->>'id')::uuid, 'decline', 'Agent on the phone');
  ASSERT r->>'status' = 'declined' AND r->'response'->>'via' = 'dashboard', 'OS3: recorded decline';
  -- Cancel and delete.
  r := public.exos_offer_create('cf000000-0000-0000-0000-000000000001', '{"artist_name":"Gone"}');
  ok := false;
  BEGIN PERFORM public.exos_offer_cancel((r->>'id')::uuid); PERFORM public.exos_offer_delete((r->>'id')::uuid);
  EXCEPTION WHEN object_not_in_prerequisite_state THEN ok := true; END;
  ASSERT ok, 'OS3: a cancelled offer is not deleted';
  r := public.exos_offer_create('cf000000-0000-0000-0000-000000000001', '{"artist_name":"Draft only"}');
  PERFORM public.exos_offer_delete((r->>'id')::uuid);
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_offers WHERE id = (r->>'id')::uuid), 'OS3: draft deleted';
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_budgets WHERE id = (r->>'budget_id')::uuid), 'OS3: its own budget goes too';
  RAISE NOTICE 'OK  OS3c accepted, expiry, staff answers, cancel, delete';
END $$;
RESET ROLE;
SET ROLE anon;
DO $$
DECLARE ok boolean := false;
BEGIN
  ASSERT public.exos_offer_public(pg_temp.g('o_late'), pg_temp.gt('tok_late'))->>'status' = 'expired', 'OS3: reads as expired';
  BEGIN PERFORM public.exos_offer_respond(pg_temp.g('o_late'), pg_temp.gt('tok_late'), 'accept', 'Too late');
  EXCEPTION WHEN object_not_in_prerequisite_state THEN ok := true; END;
  ASSERT ok, 'OS3: an expired offer can''t be answered';
END $$;
RESET ROLE;
DO $$
BEGIN
  ASSERT (SELECT status FROM public.exos_offers WHERE id = pg_temp.g('o_late')) = 'expired', 'OS3: expiry written back';
  RAISE NOTICE 'OK  OS3d expiry';
END $$;

-- OS4 ------------------------------------------------------------------------
SET ROLE authenticated;
DO $$
DECLARE r jsonb; p jsonb; o2 uuid; ok boolean; imp jsonb;
BEGIN
  PERFORM pg_temp.as_user('cf000000-0000-0000-0000-0000000000a1');
  -- A support act joins the headliner's budget (a lineup).
  r := public.exos_offer_create('cf000000-0000-0000-0000-000000000001', jsonb_build_object(
         'artist_name', 'Support Act', 'act_type', 'support', 'budget_id', pg_temp.g('b1'), 'hold_id', pg_temp.g('hold'),
         'terms', '{"guarantee_cents":20000}'::jsonb));
  o2 := (r->>'id')::uuid;
  INSERT INTO cf VALUES ('o2', o2);
  ASSERT (r->>'budget_id')::uuid = pg_temp.g('b1'), 'OS4: shared budget';
  ASSERT public.exos_offer_record_response(o2, 'accept', 'Support agent')->>'status' = 'accepted', 'OS4: support accepted';
  -- The pool over that budget: created once, idempotent, terms normalized.
  p := public.exos_offer_pool_ensure(pg_temp.g('b1'));
  ASSERT p->>'mode' = 'independent' AND jsonb_array_length(p->'offer_ids') = 2, 'OS4: pool over both offers';
  ASSERT (public.exos_offer_pool_ensure(pg_temp.g('b1'))->>'id') = p->>'id', 'OS4: idempotent';
  ok := false;
  BEGIN PERFORM public.exos_offer_pool_ensure(pg_temp.g('b1'), 'pool', '{"payout_cap_cents":100,"payout_floor_cents":200}');
  EXCEPTION WHEN invalid_parameter_value THEN ok := true; END;
  ASSERT ok, 'OS4: cap below floor';
  ok := false;
  BEGIN PERFORM public.exos_offer_pool_ensure(pg_temp.g('b1'), 'shared');
  EXCEPTION WHEN invalid_parameter_value THEN ok := true; END;
  ASSERT ok, 'OS4: bad mode';
  -- An import: rows in one group share a budget; a bad row is reported.
  imp := public.exos_offer_import('cf000000-0000-0000-0000-000000000001', 'fall.csv', jsonb_build_array(
    jsonb_build_object('group', 'fest', 'artist_name', 'Fest One', 'dates', '["2026-12-05"]'::jsonb, 'terms', '{"deal_type":"door","percentage":70}'::jsonb),
    jsonb_build_object('group', 'fest', 'artist_name', 'Fest Two', 'dates', '["2026-12-05"]'::jsonb),
    jsonb_build_object('artist_name', 'Bad', 'terms', '{"deal_type":"nope"}'::jsonb),
    jsonb_build_object('artist_name', 'Solo', 'budget', '{"capacity":200,"average_price_cents":1500}'::jsonb)));
  ASSERT imp->>'status' = 'partial' AND (imp->>'created_count')::int = 3 AND imp->'errors'->0->>'row' = '3', 'OS4: partial import ' || imp::text;
  ASSERT (SELECT count(DISTINCT budget_id) FROM public.exos_offers WHERE import_id = (imp->>'id')::uuid) = 2, 'OS4: one budget per group';
  ASSERT (SELECT bool_and(created_via = 'import') FROM public.exos_offers WHERE import_id = (imp->>'id')::uuid), 'OS4: created via import';
  RAISE NOTICE 'OK  OS4a shared budgets, pools, imports';
END $$;
RESET ROLE;
-- Converting the hold links its open offers and budget to the new event.
DO $$
DECLARE r jsonb; ev uuid;
BEGIN
  r := public._exos_hold_convert('cf000000-0000-0000-0000-000000000001', 'cf000000-0000-0000-0000-0000000000a1', 'api', NULL,
                                 pg_temp.g('hold'), jsonb_build_object('date', '2026-11-19', 'time', '20:00', 'capacity', 500));
  ev := (r->>'event_id')::uuid;
  INSERT INTO cf VALUES ('ev', ev);
  ASSERT (SELECT count(*) FROM public.exos_offers WHERE hold_id = pg_temp.g('hold') AND event_id = ev) = 2, 'OS4: offers linked';
  ASSERT (SELECT event_id FROM public.exos_budgets WHERE id = pg_temp.g('b1')) = ev, 'OS4: budget linked';
  UPDATE public.exos_events SET status = 'published', currency = 'USD' WHERE id = ev;
  RAISE NOTICE 'OK  OS4b the hold converting links offers';
END $$;

-- OS5 ------------------------------------------------------------------------
-- Sales: 4 paid GA ($25 each, two orders), one voided paid ticket, 2 comps;
-- an order with tax, an Exos fee and an absorbed fee; a $10 refund on top.
DO $$
DECLARE ev uuid := pg_temp.g('ev'); t uuid;
BEGIN
  SELECT id INTO t FROM public.exos_ticket_tiers WHERE event_id = ev LIMIT 1;
  INSERT INTO cf VALUES ('tier', t);
  INSERT INTO public.exos_checkout_sessions (session_id, event_id, tier_id, org_id, buyer_uid, buyer_email, quantity, amount_cents,
                                             currency, status, tax_cents, application_fee_cents)
  VALUES ('cs_cf_1', ev, t, 'cf000000-0000-0000-0000-000000000001', 'cf000000-0000-0000-0000-0000000000a0', 'a@x.com', 3, 7500, 'usd', 'fulfilled', 600, 300),
         ('cs_cf_2', ev, t, 'cf000000-0000-0000-0000-000000000001', 'cf000000-0000-0000-0000-0000000000a0', 'a@x.com', 2, 5000, 'usd', 'fulfilled', 0, 200);
  INSERT INTO public.exos_tickets (event_id, org_id, tier_id, tier_name, owner_id, buyer_id, status, barcode_secret, price_paid, order_ref) VALUES
    (ev, 'cf000000-0000-0000-0000-000000000001', t, 'GA', 'cf000000-0000-0000-0000-0000000000a0', 'cf000000-0000-0000-0000-0000000000a0', 'active', 'x1', 25, 'cs_cf_1'),
    (ev, 'cf000000-0000-0000-0000-000000000001', t, 'GA', 'cf000000-0000-0000-0000-0000000000a0', 'cf000000-0000-0000-0000-0000000000a0', 'used', 'x2', 25, 'cs_cf_1'),
    (ev, 'cf000000-0000-0000-0000-000000000001', t, 'GA', 'cf000000-0000-0000-0000-0000000000a0', 'cf000000-0000-0000-0000-0000000000a0', 'voided', 'x3', 25, 'cs_cf_1'),
    (ev, 'cf000000-0000-0000-0000-000000000001', t, 'GA', 'cf000000-0000-0000-0000-0000000000a0', 'cf000000-0000-0000-0000-0000000000a0', 'active', 'x4', 25, 'cs_cf_2'),
    (ev, 'cf000000-0000-0000-0000-000000000001', t, 'GA', 'cf000000-0000-0000-0000-0000000000a0', 'cf000000-0000-0000-0000-0000000000a0', 'active', 'x5', 25, 'cs_cf_2'),
    (ev, 'cf000000-0000-0000-0000-000000000001', t, 'Guest list', 'cf000000-0000-0000-0000-0000000000a0', 'cf000000-0000-0000-0000-0000000000a0', 'active', 'x6', 0, NULL),
    (ev, 'cf000000-0000-0000-0000-000000000001', t, 'Guest list', 'cf000000-0000-0000-0000-0000000000a0', 'cf000000-0000-0000-0000-0000000000a0', 'used', 'x7', 0, NULL);
  -- The voided ticket covers $25 of cs_cf_1's $35 refund; $10 more comes off the gross.
  INSERT INTO public.exos_order_refunds (session_id, org_id, provider, refund_id, amount_cents, currency, status)
  VALUES ('cs_cf_1', 'cf000000-0000-0000-0000-000000000001', 'stripe', 're_cf_1', 3500, 'usd', 'succeeded');
  INSERT INTO public.exos_order_fees (session_id, org_id, event_id, rule_name, kind, calc, per, item_kind, unit_cents, quantity, amount_cents)
  VALUES ('cs_cf_2', 'cf000000-0000-0000-0000-000000000001', ev, 'Venue fee', 'absorbed', 'fixed', 'ticket', 'ticket', 100, 2, 200);
END $$;
DO $$
DECLARE bo jsonb := public._exos_box_office(pg_temp.g('ev')); ext jsonb;
BEGIN
  ASSERT (bo->>'paid_sold')::int = 4 AND (bo->>'comps')::int = 2, 'OS5: paid vs comps: ' || bo::text;
  ASSERT (bo->>'gross_cents')::int = 9000, 'OS5: gross = 4 × $25 − $10 extra refund, got ' || (bo->>'gross_cents');
  -- cs_cf_1: (5000 − 1000) / 7500 of tax 600 and fee 300 = 320 + 160; cs_cf_2 all of 200 + 200.
  ASSERT (bo->>'tax_cents')::int = 320 AND (bo->>'platform_fees_cents')::int = 360 AND (bo->>'absorbed_fees_cents')::int = 200,
         'OS5: deductions in proportion: ' || bo::text;
  ASSERT (bo->>'refunded_cents')::int = 3500, 'OS5: refunds';
  -- Sold elsewhere: no PR #65 view → not available; with it → read per currency.
  ext := public._exos_sold_elsewhere(pg_temp.g('ev'));
  IF to_regclass('public.exos_sales_count_totals') IS NULL THEN
    ASSERT ext = '{"available": false, "lines": []}'::jsonb, 'OS5: seam without the view';
    CREATE VIEW public.exos_sales_count_totals AS
      SELECT pg_temp.g('ev') AS event_id, 'cf000000-0000-0000-0000-000000000001'::uuid AS org_id, 'USD'::text AS currency,
             10::bigint AS sold, 30000::bigint AS gross_cents, 1 AS entries, now() AS updated_at
      UNION ALL SELECT pg_temp.g('ev'), 'cf000000-0000-0000-0000-000000000001', 'EUR', 5, 9000, 1, now();
    ext := public._exos_sold_elsewhere(pg_temp.g('ev'));
    ASSERT (ext->>'available')::boolean AND jsonb_array_length(ext->'lines') = 2 AND ext->'lines'->1->>'currency' = 'USD',
           'OS5: seam reads the view: ' || ext::text;
  END IF;
  RAISE NOTICE 'OK  OS5a box office and sold elsewhere';
END $$;

INSERT INTO public.exos_event_contacts (event_id, org_id, role, name, email) VALUES
  (pg_temp.g('ev'), 'cf000000-0000-0000-0000-000000000001', 'settlement', 'Tour Accountant', 'Accounts@Tour.Example'),
  (pg_temp.g('ev'), 'cf000000-0000-0000-0000-000000000001', 'agent', 'Ann Agent', 'ann@agency.example'),
  (pg_temp.g('ev'), 'cf000000-0000-0000-0000-000000000001', 'agent', 'Bob Agent', 'bob@agency.example');

SET ROLE authenticated;
DO $$
DECLARE s jsonb; ok boolean; ev uuid := pg_temp.g('ev'); item uuid; rev int;
BEGIN
  PERFORM pg_temp.as_user('cf000000-0000-0000-0000-0000000000a4');
  ok := false;
  BEGIN PERFORM public.exos_settlement_get(ev);
  EXCEPTION WHEN insufficient_privilege THEN ok := true; END;
  ASSERT ok, 'OS5: content reads the settlement';
  PERFORM pg_temp.as_user('cf000000-0000-0000-0000-0000000000a2');   -- finance
  s := public.exos_settlement_get(ev);
  ASSERT s->>'status' = 'draft' AND (s->'inputs'->>'promoter_mode')::boolean, 'OS5: draft, promoter mode';
  ASSERT jsonb_array_length(s->'inputs'->'offers') = 2, 'OS5: both accepted / linked offers? ' || (s->'inputs'->'offers')::text;
  ASSERT (SELECT count(*) FROM public.exos_finance_items WHERE event_id = ev AND auto = 'venue-rental' AND amount_cents = 150000) = 1,
         'OS5: rental line seeded';
  ASSERT (s->'inputs'->'settlement'->>'venue_deposit_paid_cents')::int = 50000, 'OS5: rental deposit from the hold';
  -- Deleting the seeded line sticks.
  DELETE FROM public.exos_finance_items WHERE event_id = ev AND auto = 'venue-rental';
  PERFORM public.exos_settlement_get(ev);
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_finance_items WHERE event_id = ev AND auto = 'venue-rental'), 'OS5: not re-seeded';
  -- Items: finance writes; a client can't fake an auto line; the category's kind must fit.
  INSERT INTO public.exos_finance_items (event_id, org_id, category_id, kind, label, amount_cents, actual_cents)
  VALUES (ev, 'cf000000-0000-0000-0000-000000000002', (SELECT id FROM public.exos_finance_categories WHERE key = 'production'),
          'expense', 'Sound', 200000, 180000) RETURNING id INTO item;
  ASSERT (SELECT org_id FROM public.exos_finance_items WHERE id = item) = 'cf000000-0000-0000-0000-000000000001', 'OS5: org from the event';
  ok := false;
  BEGIN INSERT INTO public.exos_finance_items (event_id, org_id, kind, label, auto) VALUES (ev, 'cf000000-0000-0000-0000-000000000001', 'expense', 'X', 'venue-rental');
  EXCEPTION WHEN invalid_parameter_value THEN ok := true; END;
  ASSERT ok, 'OS5: client auto line';
  ok := false;
  BEGIN INSERT INTO public.exos_finance_items (event_id, org_id, category_id, kind, label)
        VALUES (ev, 'cf000000-0000-0000-0000-000000000001', (SELECT id FROM public.exos_finance_categories WHERE key = 'merch-income'), 'expense', 'X');
  EXCEPTION WHEN invalid_parameter_value THEN ok := true; END;
  ASSERT ok, 'OS5: category kind';
  -- Adjustments need a reason; deposits; venue share; revision guard.
  ok := false;
  BEGIN PERFORM public.exos_settlement_update(ev, '{"adjustments":[{"label":"Late","amount_cents":-1000}]}');
  EXCEPTION WHEN invalid_parameter_value THEN ok := true; END;
  ASSERT ok, 'OS5: adjustment reason required';
  s := public.exos_settlement_update(ev, jsonb_build_object(
         'adjustments', jsonb_build_array(jsonb_build_object('offer_id', pg_temp.g('o1'), 'label', 'Late start', 'amount_cents', -10000, 'reason', 'Went on 40 minutes late'),
                                          jsonb_build_object('label', 'Damage', 'amount_cents', -5000, 'reason', 'Broken mic stand')),
         'deposits_paid', jsonb_build_object(pg_temp.g('o1'), true, pg_temp.g('o2'), false),
         'venue', '{"share_percent":10}'::jsonb));
  rev := (s->>'revision')::int;
  ASSERT jsonb_array_length(s->'adjustments') = 2 AND s->'deposits_paid' = jsonb_build_object(pg_temp.g('o1'), true)
         AND (s->>'venue_share_percent')::numeric = 10, 'OS5: saved: ' || s::text;
  ok := false;
  BEGIN PERFORM public.exos_settlement_update(ev, '{"venue":{"share_percent":5}}', rev - 1);
  EXCEPTION WHEN object_not_in_prerequisite_state THEN ok := true; END;
  ASSERT ok, 'OS5: stale revision';
  -- Finalize (finance may): snapshot, link, mail to the settlement contact, webhook.
  s := public.exos_settlement_finalize(ev, rev);
  ASSERT s->>'status' = 'finalized' AND s->'emailed_to' = '["accounts@tour.example"]'::jsonb, 'OS5: finalized: ' || (s->'emailed_to')::text;
  ASSERT s->>'link_path' ~ ('^/settlement/' || ev || '\?t=[0-9a-f]{64}$'), 'OS5: link';
  INSERT INTO cf VALUES ('stok', substring(s->>'link_path' FROM 't=([0-9a-f]{64})'));
  ok := false;
  BEGIN PERFORM public.exos_settlement_update(ev, '{"venue":{"share_percent":5}}');
  EXCEPTION WHEN object_not_in_prerequisite_state THEN ok := true; END;
  ASSERT ok, 'OS5: finalized is read-only';
  ok := false;
  BEGIN PERFORM public.exos_settlement_reopen(ev);
  EXCEPTION WHEN insufficient_privilege THEN ok := true; END;
  ASSERT ok, 'OS5: finance can''t reopen';
  RAISE NOTICE 'OK  OS5b settlement: seed, items, adjustments, finalize';
END $$;
RESET ROLE;
-- A sale after finalizing doesn't move the snapshot.
INSERT INTO public.exos_tickets (event_id, org_id, tier_id, tier_name, owner_id, buyer_id, status, barcode_secret, price_paid)
VALUES (pg_temp.g('ev'), 'cf000000-0000-0000-0000-000000000001', pg_temp.g('tier'), 'GA', 'cf000000-0000-0000-0000-0000000000a0',
        'cf000000-0000-0000-0000-0000000000a0', 'active', 'x8', 25);
DO $$
DECLARE s jsonb := public._exos_settlement_get('cf000000-0000-0000-0000-000000000001', pg_temp.g('ev'));
BEGIN
  ASSERT (s->'inputs'->'box_office'->>'paid_sold')::int = 4, 'OS5: snapshot frozen';
  ASSERT (public._exos_settlement_inputs(pg_temp.g('ev'))->'box_office'->>'paid_sold')::int = 5, 'OS5: live moved';
  ASSERT (SELECT count(*) FROM public.exos_mail WHERE template = 'settlement-finalized' AND to_email = 'accounts@tour.example'
            AND payload->>'token' = pg_temp.gt('stok')) = 1, 'OS5: contact mailed the link';
  ASSERT (SELECT count(*) FROM public.exos_webhook_deliveries WHERE event_type = 'settlement.finalized') = 1, 'OS5: webhook';
END $$;
SET ROLE anon;
DO $$
DECLARE p jsonb; ok boolean := false;
BEGIN
  p := public.exos_settlement_public(pg_temp.g('ev'), pg_temp.gt('stok'));
  ASSERT p->'org'->>'name' = 'CF Org' AND (p->'inputs'->'box_office'->>'paid_sold')::int = 4, 'OS5: contacts'' copy';
  ASSERT NOT (p->'inputs' ? 'budget') AND NOT (p->'inputs'->'items'->0 ? 'notes'), 'OS5: no budget, no item notes';
  BEGIN PERFORM public.exos_settlement_public(pg_temp.g('ev'), repeat('0', 64));
  EXCEPTION WHEN no_data_found THEN ok := true; END;
  ASSERT ok, 'OS5: wrong token';
END $$;
RESET ROLE;
SET ROLE authenticated;
DO $$
DECLARE s jsonb;
BEGIN
  PERFORM pg_temp.as_user('cf000000-0000-0000-0000-0000000000a1');
  s := public.exos_settlement_reopen(pg_temp.g('ev'));
  ASSERT s->>'status' = 'draft' AND (s->'inputs'->'box_office'->>'paid_sold')::int = 5, 'OS5: reopened to live numbers';
END $$;
RESET ROLE;
SET ROLE anon;
DO $$
DECLARE ok boolean := false;
BEGIN
  BEGIN PERFORM public.exos_settlement_public(pg_temp.g('ev'), pg_temp.gt('stok'));
  EXCEPTION WHEN no_data_found THEN ok := true; END;
  ASSERT ok, 'OS5: reopening kills the link';
  RAISE NOTICE 'OK  OS5c frozen snapshot, contacts'' link, reopen';
END $$;
RESET ROLE;

-- OS6 ------------------------------------------------------------------------
SET ROLE authenticated;
DO $$
DECLARE p jsonb; ok boolean;
BEGIN
  PERFORM pg_temp.as_user('cf000000-0000-0000-0000-0000000000a2');
  p := public.exos_pnl_inputs('cf000000-0000-0000-0000-000000000001', '2026-11-01', '2026-11-30');
  ASSERT jsonb_array_length(p->'shows') = 1 AND (p->'shows'->0->>'event_id')::uuid = pg_temp.g('ev'), 'OS6: the show in range';
  ASSERT p->'shows'->0->'inputs'->'budget'->>'id' = pg_temp.gt('b1'), 'OS6: forecast budget';
  ok := false;
  BEGIN PERFORM public.exos_pnl_inputs('cf000000-0000-0000-0000-000000000001', '2026-01-01', '2027-06-01');
  EXCEPTION WHEN invalid_parameter_value THEN ok := true; END;
  ASSERT ok, 'OS6: range over 366 days';
  ok := false;
  BEGIN PERFORM public.exos_pnl_inputs('cf000000-0000-0000-0000-000000000002', '2026-11-01', '2026-11-30');
  EXCEPTION WHEN insufficient_privilege THEN ok := true; END;
  ASSERT ok, 'OS6: another org';
  RAISE NOTICE 'OK  OS6 P&L inputs';
END $$;
RESET ROLE;

-- OS7 ------------------------------------------------------------------------
SET ROLE authenticated;
DO $$
DECLARE t jsonb; ok boolean; ev uuid := pg_temp.g('ev');
BEGIN
  PERFORM pg_temp.as_user('cf000000-0000-0000-0000-0000000000a2');
  ok := false;
  BEGIN PERFORM public.exos_ticket_counts_save(ev, '{"enabled":true}');
  EXCEPTION WHEN insufficient_privilege THEN ok := true; END;
  ASSERT ok, 'OS7: finance saves a schedule';
  PERFORM pg_temp.as_user('cf000000-0000-0000-0000-0000000000a1');
  t := public.exos_ticket_counts_save(ev, '{"enabled":true,"frequency":"daily","send_time":"09:30"}');
  ASSERT t->>'timezone' = 'America/Chicago' AND jsonb_array_length(t->'recipients') = 2, 'OS7: agent contacts by default: ' || t::text;
  ASSERT (t->>'next_run_at')::timestamptz > now() AND (t->'preview'->>'paid_sold')::int = 5, 'OS7: next run + preview';
  ok := false;
  BEGIN PERFORM public.exos_ticket_counts_save(ev, '{"send_time":"25:00"}');
  EXCEPTION WHEN invalid_parameter_value THEN ok := true; END;
  ASSERT ok, 'OS7: bad time';
  t := public.exos_ticket_counts_send_now(ev);
  ASSERT (t->>'queued')::int = 2, 'OS7: send now queues one mail per recipient';
  ok := false;
  BEGIN PERFORM public.exos_ticket_counts_send_now(ev);
  EXCEPTION WHEN program_limit_exceeded THEN ok := true; END;
  ASSERT ok, 'OS7: once per 10 minutes';
  PERFORM pg_temp.as_user('cf000000-0000-0000-0000-0000000000a2');
  ASSERT jsonb_array_length(public.exos_ticket_counts_get(ev)->'recipients') = 2, 'OS7: finance reads';
  RAISE NOTICE 'OK  OS7a schedule, defaults, send now';
END $$;
RESET ROLE;
DO $$
DECLARE r jsonb; v_next timestamptz; ev uuid := pg_temp.g('ev');
BEGIN
  ASSERT (SELECT count(*) FROM public.exos_mail WHERE template = 'ticket-counts') = 2, 'OS7: two mails';
  ASSERT (SELECT bool_and(payload->'counts'->>'paid_sold' = '5' AND payload->>'optout_token' ~ '^[0-9a-f]{64}$')
            FROM public.exos_mail WHERE template = 'ticket-counts'), 'OS7: payload';
  -- Due: the run claims it, moves it to the next run and queues once.
  UPDATE public.exos_ticket_count_schedules SET next_run_at = now() - interval '1 minute' WHERE event_id = ev;
  r := public.exos_ticket_counts_run(25);
  ASSERT (r->>'runs')::int = 1 AND (r->>'queued')::int = 2, 'OS7: run: ' || r::text;
  SELECT next_run_at INTO v_next FROM public.exos_ticket_count_schedules WHERE event_id = ev;
  ASSERT v_next > now(), 'OS7: moved to the next run';
  r := public.exos_ticket_counts_run(25);
  ASSERT (r->>'runs')::int = 0, 'OS7: nothing due twice';
  -- The same run again (a retry) queues nothing new: per-run dedupe keys.
  UPDATE public.exos_ticket_count_schedules SET next_run_at = now() - interval '1 minute' WHERE event_id = ev;
  PERFORM public._exos_tc_send(ev, 'run:fixed');
  ASSERT public._exos_tc_send(ev, 'run:fixed') = 0, 'OS7: a retried run doesn''t double';
  INSERT INTO cf VALUES ('optout', (SELECT optout_token FROM public.exos_ticket_count_recipients
                                     WHERE event_id = ev AND email = 'bob@agency.example'));
END $$;
SET ROLE anon;
DO $$
DECLARE r jsonb;
BEGIN
  r := public.exos_ticket_counts_optout(pg_temp.gt('optout'));
  ASSERT NOT (r->>'opted_out')::boolean AND r->>'email' = 'b…@agency.example', 'OS7: opt-out preview ' || r::text;
  r := public.exos_ticket_counts_optout(pg_temp.gt('optout'), true);
  ASSERT (r->>'opted_out')::boolean, 'OS7: opted out';
END $$;
RESET ROLE;
DO $$
DECLARE r jsonb; ev uuid := pg_temp.g('ev');
BEGIN
  ASSERT public._exos_tc_send(ev, 'run:after-optout') = 1, 'OS7: the opted-out recipient is skipped';
  -- Re-saving the list keeps the opt-out.
  PERFORM public._exos_tc_save('cf000000-0000-0000-0000-000000000001', ev,
    '{"recipients":[{"email":"bob@agency.example","role":"agent"},{"email":"new@x.example"}]}');
  ASSERT (SELECT opted_out_at IS NOT NULL FROM public.exos_ticket_count_recipients WHERE event_id = ev AND email = 'bob@agency.example'),
         'OS7: opt-out kept';
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_ticket_count_recipients WHERE event_id = ev AND email = 'ann@agency.example'),
         'OS7: removed from the list';
  -- A day after the show the schedule switches off.
  UPDATE public.exos_events SET starts_at = now() - interval '3 days' WHERE id = ev;
  UPDATE public.exos_ticket_count_schedules SET next_run_at = now() - interval '1 minute' WHERE event_id = ev;
  r := public.exos_ticket_counts_run(25);
  ASSERT (r->>'switched_off')::int = 1 AND NOT (SELECT enabled FROM public.exos_ticket_count_schedules WHERE event_id = ev),
         'OS7: switched off after the show';
  UPDATE public.exos_events SET starts_at = '2026-11-20T02:00:00Z' WHERE id = ev;
  IF to_regclass('cron.job') IS NOT NULL THEN
    EXECUTE 'SELECT NOT active FROM cron.job WHERE jobname = ''exos-ticket-counts-15min''' INTO STRICT r;
  END IF;
  RAISE NOTICE 'OK  OS7b the run, dedupe, opt-out, switch off';
END $$;

-- OS8 ------------------------------------------------------------------------
SET ROLE authenticated;
DO $$
DECLARE d uuid; ok boolean;
BEGIN
  PERFORM pg_temp.as_user('cf000000-0000-0000-0000-0000000000a1');
  INSERT INTO public.exos_crm_deals (org_id, name, deal_type, stage, amount_cents, owner_user_id, contact_email)
  VALUES ('cf000000-0000-0000-0000-000000000001', 'Sponsor: Brewery', 'sales', 'proposal', 500000,
          'cf000000-0000-0000-0000-0000000000a2', 'Beer@Brew.Example') RETURNING id INTO d;
  UPDATE public.exos_crm_deals SET stage = 'closed_won' WHERE id = d;
  ASSERT (SELECT status = 'won' AND contact_email = 'beer@brew.example' FROM public.exos_crm_deals WHERE id = d), 'OS8: stage → status';
  ok := false;
  BEGIN UPDATE public.exos_crm_deals SET deal_type = 'fundraising', stage = 'proposal' WHERE id = d;
  EXCEPTION WHEN invalid_parameter_value THEN ok := true; END;
  ASSERT ok, 'OS8: stage per type';
  ok := false;
  BEGIN UPDATE public.exos_crm_deals SET owner_user_id = 'cf000000-0000-0000-0000-0000000000b9' WHERE id = d;
  EXCEPTION WHEN invalid_parameter_value THEN ok := true; END;
  ASSERT ok, 'OS8: owner must be a member';
  PERFORM pg_temp.as_user('cf000000-0000-0000-0000-0000000000a2');
  ok := false;
  BEGIN INSERT INTO public.exos_crm_deals (org_id, name) VALUES ('cf000000-0000-0000-0000-000000000001', 'X');
  EXCEPTION WHEN insufficient_privilege THEN ok := true; END;
  ASSERT ok, 'OS8: finance reads deals, doesn''t write them';
  ASSERT (SELECT count(*) FROM public.exos_crm_deals) = 1, 'OS8: finance reads';
  RAISE NOTICE 'OK  OS8 CRM deals';
END $$;

-- OS9 ------------------------------------------------------------------------
DO $$
DECLARE ok boolean; t text;
BEGIN
  PERFORM pg_temp.as_user('cf000000-0000-0000-0000-0000000000b9');   -- the other org's owner
  FOREACH t IN ARRAY ARRAY['exos_offers', 'exos_budgets', 'exos_budget_lines', 'exos_offer_pools', 'exos_offer_templates',
                           'exos_offer_imports', 'exos_finance_items', 'exos_settlements', 'exos_ticket_count_schedules',
                           'exos_crm_deals', 'exos_gl_codes'] LOOP
    EXECUTE format('SELECT count(*) = 0 FROM public.%I', t) INTO ok;
    ASSERT ok, 'OS9: other org reads ' || t;
  END LOOP;
  ok := false;
  BEGIN PERFORM public.exos_offer_update(pg_temp.g('o1'), '{"notes":"x"}');
  EXCEPTION WHEN insufficient_privilege THEN ok := true; END;
  ASSERT ok, 'OS9: other org edits an offer';
  ok := false;
  BEGIN PERFORM public.exos_settlement_get(pg_temp.g('ev'));
  EXCEPTION WHEN insufficient_privilege THEN ok := true; END;
  ASSERT ok, 'OS9: other org reads a settlement';
  ok := false;
  BEGIN PERFORM public.exos_ticket_counts_get(pg_temp.g('ev'));
  EXCEPTION WHEN insufficient_privilege THEN ok := true; END;
  ASSERT ok, 'OS9: other org reads ticket counts';
  ok := false;
  BEGIN PERFORM public.exos_offer_pool_ensure(pg_temp.g('b1'));
  EXCEPTION WHEN insufficient_privilege THEN ok := true; END;
  ASSERT ok, 'OS9: other org pools a budget';
  -- Their own offer can't join our budget; their line can't use our category.
  ok := false;
  BEGIN PERFORM public.exos_offer_create('cf000000-0000-0000-0000-000000000002', jsonb_build_object('artist_name', 'X', 'budget_id', pg_temp.g('b1')));
  EXCEPTION WHEN no_data_found THEN ok := true; END;
  ASSERT ok, 'OS9: joins our budget';
END $$;
RESET ROLE;
DO $$
DECLARE ok boolean := false;
BEGIN
  -- A budget line can't use another org's category.
  PERFORM public._exos_fin_seed('cf000000-0000-0000-0000-000000000002');
  INSERT INTO public.exos_budgets (id, org_id, name) VALUES ('cf000000-0000-0000-0000-0000000000e9', 'cf000000-0000-0000-0000-000000000002', 'Theirs');
  BEGIN
    INSERT INTO public.exos_budget_lines (org_id, budget_id, category_id, label)
    VALUES ('cf000000-0000-0000-0000-000000000002', 'cf000000-0000-0000-0000-0000000000e9',
            (SELECT c.id FROM public.exos_finance_categories c WHERE c.org_id = 'cf000000-0000-0000-0000-000000000001' AND c.key = 'staff'), 'Ours');
  EXCEPTION WHEN invalid_parameter_value THEN ok := true; END;
  ASSERT ok, 'OS9: another org''s category on a line';
  -- The cores act only for the org they are given.
  ok := false;
  BEGIN PERFORM public._exos_settlement_get('cf000000-0000-0000-0000-000000000002', pg_temp.g('ev'));
  EXCEPTION WHEN no_data_found THEN ok := true; END;
  ASSERT ok, 'OS9: settlement core, wrong org';
  ok := false;
  BEGIN PERFORM public._exos_offer_send('cf000000-0000-0000-0000-000000000002', NULL, pg_temp.g('o2'), 'x@y.example');
  EXCEPTION WHEN no_data_found THEN ok := true; END;
  ASSERT ok, 'OS9: offer core, wrong org';
  ok := false;
  BEGIN PERFORM public._exos_tc_get('cf000000-0000-0000-0000-000000000002', pg_temp.g('ev'));
  EXCEPTION WHEN no_data_found THEN ok := true; END;
  ASSERT ok, 'OS9: ticket-count core, wrong org';
  RAISE NOTICE 'OK  OS9 cross-org isolation';
END $$;

ROLLBACK;
