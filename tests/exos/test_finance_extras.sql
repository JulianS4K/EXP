-- ============================================================================
-- Tiered deal brackets, ledger codes per revenue type with per-event
-- overrides and backfills, imported ledger entries, reporting rows and the
-- cash summary (mig 20261102120000). Self-contained (fe… ids), rolled back
-- at the end.
--   FX1 grants: RLS everywhere, no anon access, no client write path to
--       reporting rows or imported entries, cores service_role only
--   FX2 _exos_bracket_amount agrees with dealBrackets.ts (same fixtures as
--       src/lib/dealBrackets.test.ts)
--   FX3 brackets: roles, strictly increasing thresholds, one basis, the cap,
--       draft-only, settlement inputs (and the frozen snapshot)
--   FX4 ledger codes: revenue codes, overrides, discarded codes
--   FX5 imported entries: dedupe, conflicts, per-row errors, the 500 cap,
--       reporting rows (flagged), P&L inputs, delete
--   FX6 backfill: rows from orders / refunds / payouts, idempotent, re-tags
--   FX7 cash summary
--   FX8 cross-org isolation
--   psql -d <db> -v ON_ERROR_STOP=1 -f tests/exos/test_finance_extras.sql
-- ============================================================================
\set ON_ERROR_STOP on
BEGIN;

INSERT INTO auth.users (id, email, email_confirmed_at) VALUES
  ('fe000000-0000-0000-0000-0000000000a0', 'fe-owner@x.com', now()),
  ('fe000000-0000-0000-0000-0000000000a1', 'fe-manager@x.com', now()),
  ('fe000000-0000-0000-0000-0000000000a2', 'fe-finance@x.com', now()),
  ('fe000000-0000-0000-0000-0000000000a3', 'fe-scanner@x.com', now()),
  ('fe000000-0000-0000-0000-0000000000b9', 'fe-other@x.com', now());
INSERT INTO public.exos_orgs (id, name, slug, owner_uid) VALUES
  ('fe000000-0000-0000-0000-000000000001', 'FE Org', 'fe-org', 'fe000000-0000-0000-0000-0000000000a0'),
  ('fe000000-0000-0000-0000-000000000002', 'FE Other', 'fe-other', 'fe000000-0000-0000-0000-0000000000b9');
INSERT INTO public.exos_org_memberships (org_id, user_id, role) VALUES
  ('fe000000-0000-0000-0000-000000000001', 'fe000000-0000-0000-0000-0000000000a0', 'owner'),
  ('fe000000-0000-0000-0000-000000000001', 'fe000000-0000-0000-0000-0000000000a1', 'manager'),
  ('fe000000-0000-0000-0000-000000000001', 'fe000000-0000-0000-0000-0000000000a2', 'finance'),
  ('fe000000-0000-0000-0000-000000000001', 'fe000000-0000-0000-0000-0000000000a3', 'scanner'),
  ('fe000000-0000-0000-0000-000000000002', 'fe000000-0000-0000-0000-0000000000b9', 'owner');
INSERT INTO public.exos_events (id, org_id, name, slug, status, starts_at, currency) VALUES
  ('fe000000-0000-0000-0000-0000000000e1', 'fe000000-0000-0000-0000-000000000001', 'FE Show', 'fe-show', 'published', now() + interval '9 days', 'USD'),
  ('fe000000-0000-0000-0000-0000000000e9', 'fe000000-0000-0000-0000-000000000002', 'FE Theirs', 'fe-theirs', 'published', now() + interval '9 days', 'USD');

CREATE FUNCTION pg_temp.as_user(p_uid text) RETURNS void LANGUAGE sql AS $$
  SELECT set_config('app.uid', coalesce(p_uid, ''), true)::text IS NOT NULL AND true;
$$;
GRANT EXECUTE ON FUNCTION pg_temp.as_user(text) TO anon, authenticated, service_role;
CREATE TEMP TABLE fe (k text PRIMARY KEY, v text);
GRANT ALL ON fe TO anon, authenticated, service_role;
CREATE FUNCTION pg_temp.g(p_k text) RETURNS uuid LANGUAGE sql AS $$ SELECT v::uuid FROM fe WHERE k = p_k $$;
GRANT EXECUTE ON FUNCTION pg_temp.g(text) TO anon, authenticated, service_role;

-- FX1 ------------------------------------------------------------------------
DO $$
DECLARE t text; f text;
BEGIN
  FOREACH t IN ARRAY ARRAY['exos_deal_brackets', 'exos_gl_revenue_codes', 'exos_gl_code_assignments',
                           'exos_imported_ledger_entries', 'exos_reporting_rows'] LOOP
    ASSERT NOT has_table_privilege('anon', 'public.' || t, 'SELECT'), 'FX1: anon reads ' || t;
    ASSERT (SELECT relrowsecurity FROM pg_class WHERE oid = ('public.' || t)::regclass), 'FX1: RLS on ' || t;
    ASSERT EXISTS (SELECT 1 FROM pg_trigger WHERE tgrelid = ('public.' || t)::regclass AND tgname = t || '_touch'), 'FX1: touch on ' || t;
  END LOOP;
  ASSERT NOT has_table_privilege('authenticated', 'public.exos_reporting_rows', 'INSERT')
     AND NOT has_table_privilege('authenticated', 'public.exos_reporting_rows', 'UPDATE')
     AND NOT has_table_privilege('authenticated', 'public.exos_reporting_rows', 'DELETE'), 'FX1: client writes reporting rows';
  ASSERT NOT has_table_privilege('authenticated', 'public.exos_imported_ledger_entries', 'INSERT')
     AND NOT has_table_privilege('authenticated', 'public.exos_imported_ledger_entries', 'UPDATE'), 'FX1: client writes imported entries';
  ASSERT NOT has_column_privilege('authenticated', 'public.exos_deal_brackets', 'org_id', 'UPDATE')
     AND NOT has_column_privilege('authenticated', 'public.exos_deal_brackets', 'offer_id', 'UPDATE'), 'FX1: bracket org / offer fixed';
  FOREACH f IN ARRAY ARRAY['public._exos_bracket_amount(bigint,bigint,numeric,jsonb)', 'public._exos_offer_brackets_json(uuid)',
                           'public._exos_gl_backfill(uuid,uuid)', 'public._exos_ledger_import(uuid,uuid,text,uuid,jsonb)',
                           'public._exos_cash_summary(uuid,uuid,timestamptz,timestamptz)'] LOOP
    ASSERT NOT has_function_privilege('authenticated', f, 'EXECUTE') AND NOT has_function_privilege('anon', f, 'EXECUTE'),
           'FX1: clients execute ' || f;
    ASSERT has_function_privilege('service_role', f, 'EXECUTE'), 'FX1: service_role executes ' || f;
  END LOOP;
  FOREACH f IN ARRAY ARRAY['public._exos_gl_resolve(uuid,uuid,text)', 'public._exos_settlement_extras(uuid,uuid)'] LOOP
    ASSERT NOT has_function_privilege('authenticated', f, 'EXECUTE') AND NOT has_function_privilege('anon', f, 'EXECUTE'),
           'FX1: clients execute ' || f;
  END LOOP;
  FOREACH f IN ARRAY ARRAY['public.exos_gl_backfill(uuid)', 'public.exos_ledger_import(uuid,jsonb)',
                           'public.exos_cash_summary(uuid,timestamptz,timestamptz)'] LOOP
    ASSERT NOT has_function_privilege('anon', f, 'EXECUTE') AND has_function_privilege('authenticated', f, 'EXECUTE'),
           'FX1: wrapper grants ' || f;
    ASSERT (SELECT prosecdef AND 'search_path=public, pg_temp' = ANY (proconfig) FROM pg_proc WHERE oid = f::regprocedure),
           'FX1: definer with search_path ' || f;
  END LOOP;
  RAISE NOTICE 'OK  FX1 grants';
END $$;

-- FX2 ------------------------------------------------------------------------
-- The same fixtures as FIXTURES in src/lib/dealBrackets.test.ts.
DO $$
DECLARE r record;
BEGIN
  FOR r IN SELECT * FROM (VALUES
    ('85% to $20k, 90% above', 3000000, 0, 85, '{"basis":"amount","tiers":[{"threshold":2000000,"percentage":90}]}', 2600000),
    ('exactly at the threshold', 2000000, 0, 85, '{"basis":"amount","tiers":[{"threshold":2000000,"percentage":90}]}', 1700000),
    ('one cent past the threshold', 2000001, 0, 85, '{"basis":"amount","tiers":[{"threshold":2000000,"percentage":90}]}', 1700001),
    ('a single tier from 0', 12345, 0, 85, '{"basis":"amount","tiers":[{"threshold":0,"percentage":80}]}', 9876),
    ('unsorted input', 6000000, 0, 85, '{"basis":"amount","tiers":[{"threshold":5000000,"percentage":95},{"threshold":0,"percentage":80},{"threshold":2000000,"percentage":90}]}', 5250000),
    ('threshold above the base', 100, 0, 85, '{"basis":"amount","tiers":[{"threshold":10000000,"percentage":90}]}', 85),
    ('half a cent rounds up', 3, 0, 50, '{"basis":"amount","tiers":[{"threshold":1000000,"percentage":60}]}', 2),
    ('ticket basis', 1000001, 1500, 85, '{"basis":"tickets","tiers":[{"threshold":1000,"percentage":90}]}', 866667),
    ('ticket basis, nothing sold', 50000, 0, 85, '{"basis":"tickets","tiers":[{"threshold":1000,"percentage":90}]}', 42500),
    ('ticket basis, below the first threshold', 1000000, 999, 85, '{"basis":"tickets","tiers":[{"threshold":1000,"percentage":90}]}', 850000),
    ('ticket basis, exactly at the threshold', 1000000, 1000, 85, '{"basis":"tickets","tiers":[{"threshold":1000,"percentage":90}]}', 850000),
    ('zero base', 0, 10, 85, '{"basis":"amount","tiers":[{"threshold":0,"percentage":90}]}', 0)
  ) v(name, base, sold, pct, b, want) LOOP
    ASSERT public._exos_bracket_amount(r.base, r.sold, r.pct, r.b::jsonb) = r.want,
           format('FX2: %s: want %s, got %s', r.name, r.want, public._exos_bracket_amount(r.base, r.sold, r.pct, r.b::jsonb));
  END LOOP;
  ASSERT public._exos_bracket_amount(12345, 0, 72.5, NULL) = 8950, 'FX2: no brackets = the plain percentage';
  RAISE NOTICE 'OK  FX2 SQL bracket maths = TS';
END $$;

-- FX3 ------------------------------------------------------------------------
SET ROLE authenticated;
DO $$
DECLARE r jsonb; o uuid; o2 uuid; ok boolean; b uuid;
BEGIN
  PERFORM pg_temp.as_user('fe000000-0000-0000-0000-0000000000a1');   -- manager
  r := public.exos_offer_create('fe000000-0000-0000-0000-000000000001', jsonb_build_object(
         'artist_name', 'Tiered Act', 'event_id', 'fe000000-0000-0000-0000-0000000000e1',
         'terms', jsonb_build_object('deal_type', 'door', 'percentage', 85)));
  o := (r->>'id')::uuid;
  INSERT INTO fe VALUES ('offer', o);
  INSERT INTO public.exos_deal_brackets (offer_id, org_id, basis, threshold, percentage)
  VALUES (o, 'fe000000-0000-0000-0000-000000000002', 'amount', 2000000, 90) RETURNING id INTO b;
  ASSERT (SELECT org_id FROM public.exos_deal_brackets WHERE id = b) = 'fe000000-0000-0000-0000-000000000001', 'FX3: org from the offer';
  INSERT INTO fe VALUES ('bracket', b);
  ok := false;
  BEGIN INSERT INTO public.exos_deal_brackets (offer_id, basis, threshold, percentage) VALUES (o, 'amount', 2000000, 95);
  EXCEPTION WHEN invalid_parameter_value THEN ok := true; END;
  ASSERT ok, 'FX3: a repeated threshold (overlap) is refused';
  ok := false;
  BEGIN INSERT INTO public.exos_deal_brackets (offer_id, basis, threshold, percentage) VALUES (o, 'tickets', 500, 95);
  EXCEPTION WHEN invalid_parameter_value THEN ok := true; END;
  ASSERT ok, 'FX3: one basis per offer';
  ok := false;
  BEGIN INSERT INTO public.exos_deal_brackets (offer_id, basis, threshold, percentage) VALUES (o, 'amount', 10, 100.5);
  EXCEPTION WHEN check_violation THEN ok := true; END;
  ASSERT ok, 'FX3: percentage 0..100';
  -- 20 per offer.
  r := public.exos_offer_create('fe000000-0000-0000-0000-000000000001', '{"artist_name":"Many"}');
  o2 := (r->>'id')::uuid;
  INSERT INTO public.exos_deal_brackets (offer_id, threshold, percentage) SELECT o2, g, 50 FROM generate_series(1, 20) g;
  ok := false;
  BEGIN INSERT INTO public.exos_deal_brackets (offer_id, threshold, percentage) VALUES (o2, 21, 50);
  EXCEPTION WHEN program_limit_exceeded THEN ok := true; END;
  ASSERT ok, 'FX3: at most 20';
  UPDATE public.exos_deal_brackets SET percentage = 60 WHERE offer_id = o2 AND threshold = 20;
  ASSERT (SELECT percentage FROM public.exos_deal_brackets WHERE offer_id = o2 AND threshold = 20) = 60, 'FX3: edit a bracket';
  DELETE FROM public.exos_deal_brackets WHERE offer_id = o2 AND threshold > 1;
  ASSERT (SELECT count(*) FROM public.exos_deal_brackets WHERE offer_id = o2) = 1, 'FX3: delete brackets';

  -- Finance reads but doesn't write; a scanner sees nothing.
  PERFORM pg_temp.as_user('fe000000-0000-0000-0000-0000000000a2');
  ASSERT (SELECT count(*) FROM public.exos_deal_brackets) = 2, 'FX3: finance reads';
  ok := false;
  BEGIN INSERT INTO public.exos_deal_brackets (offer_id, threshold, percentage) VALUES (o, 5, 50);
  EXCEPTION WHEN insufficient_privilege THEN ok := true; END;
  ASSERT ok, 'FX3: finance writes brackets';
  PERFORM pg_temp.as_user('fe000000-0000-0000-0000-0000000000a3');
  ASSERT (SELECT count(*) FROM public.exos_deal_brackets) = 0, 'FX3: a scanner sees brackets';

  -- Accepted: the brackets are frozen, and they reach the settlement inputs.
  PERFORM pg_temp.as_user('fe000000-0000-0000-0000-0000000000a1');
  PERFORM public.exos_offer_record_response(o, 'accept', 'Agent on the phone');
  ok := false;
  BEGIN UPDATE public.exos_deal_brackets SET percentage = 99 WHERE id = b;
  EXCEPTION WHEN object_not_in_prerequisite_state THEN ok := true; END;
  ASSERT ok, 'FX3: brackets of an accepted offer are frozen';
  ok := false;
  BEGIN DELETE FROM public.exos_deal_brackets WHERE id = b;
  EXCEPTION WHEN object_not_in_prerequisite_state THEN ok := true; END;
  ASSERT ok, 'FX3: and can''t be deleted';
  RAISE NOTICE 'OK  FX3a brackets: rules and roles';
END $$;
RESET ROLE;
DO $$
DECLARE inp jsonb := public._exos_settlement_inputs('fe000000-0000-0000-0000-0000000000e1');
BEGIN
  ASSERT inp->'deal_brackets'->(pg_temp.g('offer')::text) = '{"basis":"amount","tiers":[{"threshold":2000000,"percentage":90.000}]}'::jsonb,
         'FX3: deal_brackets in the inputs: ' || coalesce(inp->>'deal_brackets', 'null');
  ASSERT inp ? 'version' AND inp ? 'box_office' AND jsonb_array_length(inp->'offers') = 1, 'FX3: the rest of the inputs is unchanged';
  ASSERT jsonb_typeof(inp->'imported_entries') = 'array', 'FX3: imported_entries present';
  RAISE NOTICE 'OK  FX3b brackets in the settlement inputs';
END $$;

-- FX4 ------------------------------------------------------------------------
SET ROLE authenticated;
DO $$
DECLARE g1 uuid; g2 uuid; g3 uuid; ok boolean; a uuid; theirs uuid;
BEGIN
  PERFORM pg_temp.as_user('fe000000-0000-0000-0000-0000000000a2');   -- finance codes the books
  INSERT INTO public.exos_gl_codes (org_id, code, name, kind) VALUES
    ('fe000000-0000-0000-0000-000000000001', '4000', 'Ticket sales', 'income') RETURNING id INTO g1;
  INSERT INTO public.exos_gl_codes (org_id, code, name, kind) VALUES
    ('fe000000-0000-0000-0000-000000000001', '2200', 'Sales tax payable', 'liability') RETURNING id INTO g2;
  INSERT INTO public.exos_gl_codes (org_id, code, name, kind) VALUES
    ('fe000000-0000-0000-0000-000000000001', '4010', 'Ticket sales - festival', 'income') RETURNING id INTO g3;
  INSERT INTO fe VALUES ('g1', g1), ('g2', g2), ('g3', g3);
  INSERT INTO public.exos_gl_revenue_codes (org_id, revenue_type, gl_code_id) VALUES
    ('fe000000-0000-0000-0000-000000000001', 'tickets', g1), ('fe000000-0000-0000-0000-000000000001', 'tax', g2);
  ok := false;
  BEGIN INSERT INTO public.exos_gl_revenue_codes (org_id, revenue_type, gl_code_id) VALUES ('fe000000-0000-0000-0000-000000000001', 'nope', g1);
  EXCEPTION WHEN check_violation THEN ok := true; END;
  ASSERT ok, 'FX4: unknown revenue type';
  -- An override for one event; one per type.
  INSERT INTO public.exos_gl_code_assignments (event_id, revenue_type, gl_code_id)
  VALUES ('fe000000-0000-0000-0000-0000000000e1', 'tickets', g3) RETURNING id INTO a;
  INSERT INTO fe VALUES ('assign', a);
  ASSERT (SELECT org_id FROM public.exos_gl_code_assignments WHERE id = a) = 'fe000000-0000-0000-0000-000000000001', 'FX4: org from the event';
  ok := false;
  BEGIN INSERT INTO public.exos_gl_code_assignments (event_id, revenue_type, gl_code_id) VALUES ('fe000000-0000-0000-0000-0000000000e1', 'tickets', g1);
  EXCEPTION WHEN unique_violation THEN ok := true; END;
  ASSERT ok, 'FX4: one override per type';
  ok := false;
  BEGIN UPDATE public.exos_gl_code_assignments SET revenue_type = 'tax' WHERE id = a;
  EXCEPTION WHEN invalid_parameter_value THEN ok := true; END;
  ASSERT ok, 'FX4: an override only repoints';
  ok := false;
  BEGIN INSERT INTO public.exos_gl_code_assignments (event_id, revenue_type, gl_code_id) VALUES ('fe000000-0000-0000-0000-0000000000e9', 'tickets', g1);
  EXCEPTION WHEN insufficient_privilege OR invalid_parameter_value OR foreign_key_violation THEN ok := true; END;
  ASSERT ok, 'FX4: an override on another org''s event';
  PERFORM pg_temp.as_user('fe000000-0000-0000-0000-0000000000a3');
  ok := false;
  BEGIN INSERT INTO public.exos_gl_revenue_codes (org_id, revenue_type, gl_code_id) VALUES ('fe000000-0000-0000-0000-000000000001', 'fees', g1);
  EXCEPTION WHEN insufficient_privilege THEN ok := true; END;
  ASSERT ok, 'FX4: a scanner codes';
  RAISE NOTICE 'OK  FX4 revenue codes and overrides';
END $$;
RESET ROLE;
DO $$
BEGIN
  ASSERT (SELECT gl_code FROM public._exos_gl_resolve('fe000000-0000-0000-0000-000000000001', 'fe000000-0000-0000-0000-0000000000e1', 'tickets')) = '4010',
         'FX4: the override wins';
  ASSERT (SELECT gl_code FROM public._exos_gl_resolve('fe000000-0000-0000-0000-000000000001', NULL, 'tickets')) = '4000', 'FX4: org default';
  ASSERT NOT EXISTS (SELECT 1 FROM public._exos_gl_resolve('fe000000-0000-0000-0000-000000000001', NULL, 'fees')), 'FX4: uncoded';
  UPDATE public.exos_gl_codes SET discarded_at = now() WHERE id = pg_temp.g('g3');
  ASSERT (SELECT gl_code FROM public._exos_gl_resolve('fe000000-0000-0000-0000-000000000001', 'fe000000-0000-0000-0000-0000000000e1', 'tickets')) = '4000',
         'FX4: a discarded override falls back';
  UPDATE public.exos_gl_codes SET discarded_at = NULL WHERE id = pg_temp.g('g3');
  RAISE NOTICE 'OK  FX4b resolution';
END $$;

-- FX5 ------------------------------------------------------------------------
-- The core, as exos-api calls it (service role; here the test superuser).
DO $$
DECLARE r jsonb; rows jsonb; big jsonb; ok boolean;
BEGIN
  rows := jsonb_build_array(
    jsonb_build_object('event_id', 'fe000000-0000-0000-0000-0000000000e1', 'source', 'bar', 'description', 'Bar night',
                       'amount_cents', 50000, 'tax_amount_cents', 4000, 'gl_code', '4100', 'tax_gl_code', '2200',
                       'posted_at', '2026-11-01T22:00:00Z', 'source_system', 'square', 'source_line_id', 'sq:1'),
    jsonb_build_object('event_id', 'fe000000-0000-0000-0000-0000000000e1', 'source', 'merchandise', 'description', 'Tees',
                       'amount_cents', '10000', 'posted_at', '2026-11-01T22:00:00Z', 'source_system', 'shopify', 'source_line_id', 'sh:1'),
    jsonb_build_object('source', 'bar', 'amount_cents', 12.5, 'posted_at', '2026-11-01', 'source_system', 'square', 'source_line_id', 'sq:bad'),
    jsonb_build_object('source', 'nope', 'amount_cents', 1, 'posted_at', '2026-11-01', 'source_system', 'square', 'source_line_id', 'sq:bad2'),
    jsonb_build_object('event_id', 'fe000000-0000-0000-0000-0000000000e9', 'source', 'bar', 'amount_cents', 1, 'posted_at', '2026-11-01',
                       'source_system', 'square', 'source_line_id', 'sq:theirs'));
  r := public._exos_ledger_import('fe000000-0000-0000-0000-000000000001', NULL, 'api', NULL, rows);
  ASSERT (r->>'created')::int = 2 AND (r->>'errors')::int = 3, 'FX5: two created, three per-row errors: ' || r::text;
  ASSERT r->'results'->2->>'error' LIKE 'amount_cents must be a whole number%', 'FX5: integer cents only';
  ASSERT r->'results'->4->>'error' LIKE 'event_id is not one of this organization%', 'FX5: another org''s event';
  INSERT INTO fe VALUES ('imp1', r->'results'->0->>'id'), ('imp2', r->'results'->1->>'id');
  -- Sent again: exists (nothing written); different values under the same id: an error naming it.
  r := public._exos_ledger_import('fe000000-0000-0000-0000-000000000001', NULL, 'api', NULL, jsonb_build_array(rows->0, rows->1,
         (rows->1) || '{"amount_cents": 20000}'));
  ASSERT (r->>'created')::int = 0 AND (r->>'exists')::int = 2 AND (r->>'errors')::int = 1, 'FX5: dedupe: ' || r::text;
  ASSERT r->'results'->2->>'id' = pg_temp.g('imp2')::text AND r->'results'->2->>'error' LIKE '%delete that entry first%', 'FX5: conflict names the entry';
  ASSERT (SELECT count(*) FROM public.exos_imported_ledger_entries WHERE org_id = 'fe000000-0000-0000-0000-000000000001') = 2, 'FX5: two entries';
  -- The cap.
  SELECT jsonb_agg(jsonb_build_object('source', 'bar', 'amount_cents', 1, 'posted_at', '2026-11-01', 'source_system', 'cap',
                                      'source_line_id', 'c' || g)) INTO big FROM generate_series(1, 501) g;
  ok := false;
  BEGIN PERFORM public._exos_ledger_import('fe000000-0000-0000-0000-000000000001', NULL, 'api', NULL, big);
  EXCEPTION WHEN program_limit_exceeded THEN ok := true; END;
  ASSERT ok, 'FX5: at most 500 per import';
  -- Reporting rows at once, flagged, with their own codes.
  ASSERT (SELECT count(*) FROM public.exos_reporting_rows WHERE source_type = 'imported' AND imported) = 3, 'FX5: bar + its tax + tees';
  ASSERT (SELECT gl_code FROM public.exos_reporting_rows WHERE source_id = pg_temp.g('imp1')::text AND revenue_type = 'bar') = '4100'
     AND (SELECT gl_code_id IS NULL FROM public.exos_reporting_rows WHERE source_id = pg_temp.g('imp1')::text AND revenue_type = 'bar'),
         'FX5: its own code (not in the chart yet)';
  ASSERT (SELECT gl_code_id FROM public.exos_reporting_rows WHERE source_id = pg_temp.g('imp1')::text AND revenue_type = 'tax') = pg_temp.g('g2'),
         'FX5: tax code linked to the chart';
  ok := false;
  BEGIN UPDATE public.exos_imported_ledger_entries SET amount_cents = 1 WHERE id = pg_temp.g('imp1');
  EXCEPTION WHEN object_not_in_prerequisite_state THEN ok := true; END;
  ASSERT ok, 'FX5: entries are not edited';
  RAISE NOTICE 'OK  FX5a imports: dedupe, errors, cap, reporting rows';
END $$;
RESET ROLE;
DO $$
DECLARE inp jsonb := public._exos_settlement_inputs('fe000000-0000-0000-0000-0000000000e1');
BEGIN
  ASSERT jsonb_array_length(inp->'imported_entries') = 2, 'FX5: the show''s imported entries in the inputs';
  ASSERT (SELECT sum((x->>'amount_cents')::bigint) FROM jsonb_array_elements(inp->'imported_entries') x) = 60000, 'FX5: amounts';
  RAISE NOTICE 'OK  FX5b imported entries reach the settlement and P&L inputs';
END $$;

-- FX6 ------------------------------------------------------------------------
-- Sales: a $100 card order (tax $8, Exos fee $5, a $3 buyer fee) transferred
-- to the organizer, refunded $20; a $40 Venmo order through PayPal.
DO $$
DECLARE t uuid := gen_random_uuid();
BEGIN
  INSERT INTO public.exos_ticket_tiers (id, event_id, name, price, capacity) VALUES (t, 'fe000000-0000-0000-0000-0000000000e1', 'GA', 46, 100);
  INSERT INTO public.exos_checkout_sessions (session_id, event_id, tier_id, org_id, buyer_uid, buyer_email, quantity, amount_cents,
                                             currency, status, tax_cents, application_fee_cents, processor, payment_method)
  VALUES ('cs_fe_1', 'fe000000-0000-0000-0000-0000000000e1', t, 'fe000000-0000-0000-0000-000000000001', 'fe000000-0000-0000-0000-0000000000a0',
          'a@x.com', 2, 10000, 'usd', 'partially_refunded', 800, 500, 'stripe', 'card'),
         ('pp_' || repeat('fe', 16), 'fe000000-0000-0000-0000-0000000000e1', t, 'fe000000-0000-0000-0000-000000000001',
          'fe000000-0000-0000-0000-0000000000a0', 'a@x.com', 1, 4000, 'usd', 'fulfilled', 0, 200, 'paypal', 'venmo');
  INSERT INTO public.exos_order_fees (session_id, org_id, event_id, rule_name, kind, calc, per, item_kind, unit_cents, quantity, amount_cents)
  VALUES ('cs_fe_1', 'fe000000-0000-0000-0000-000000000001', 'fe000000-0000-0000-0000-0000000000e1', 'Service', 'passed_on', 'fixed', 'order', 'order', 300, 1, 300);
  INSERT INTO public.exos_order_payments (session_id, org_id, event_id, provider, payment_intent, amount_cents, currency, status, transfer_id)
  VALUES ('cs_fe_1', 'fe000000-0000-0000-0000-000000000001', 'fe000000-0000-0000-0000-0000000000e1', 'stripe', 'pi_fe_1', 10000, 'usd', 'succeeded', 'tr_fe_1');
  INSERT INTO public.exos_order_refunds (session_id, org_id, provider, refund_id, amount_cents, currency, status)
  VALUES ('cs_fe_1', 'fe000000-0000-0000-0000-000000000001', 'stripe', 're_fe_1', 2000, 'usd', 'succeeded');
  INSERT INTO public.exos_tickets (event_id, org_id, tier_id, tier_name, owner_id, buyer_id, status, barcode_secret, price_paid, order_ref) VALUES
    ('fe000000-0000-0000-0000-0000000000e1', 'fe000000-0000-0000-0000-000000000001', t, 'GA', 'fe000000-0000-0000-0000-0000000000a0', 'fe000000-0000-0000-0000-0000000000a0', 'active', 'fe1', 46, 'cs_fe_1'),
    ('fe000000-0000-0000-0000-0000000000e1', 'fe000000-0000-0000-0000-000000000001', t, 'Guest list', 'fe000000-0000-0000-0000-0000000000a0', 'fe000000-0000-0000-0000-0000000000a0', 'active', 'fe2', 0, NULL);
END $$;
SET ROLE authenticated;
DO $$
DECLARE r jsonb; ok boolean;
BEGIN
  PERFORM pg_temp.as_user('fe000000-0000-0000-0000-0000000000a3');
  ok := false;
  BEGIN PERFORM public.exos_gl_backfill('fe000000-0000-0000-0000-0000000000e1');
  EXCEPTION WHEN insufficient_privilege THEN ok := true; END;
  ASSERT ok, 'FX6: a scanner backfills';
  PERFORM pg_temp.as_user('fe000000-0000-0000-0000-0000000000a2');
  r := public.exos_gl_backfill('fe000000-0000-0000-0000-0000000000e1');
  -- cs_fe_1: tickets 10000-800-300 = 8900, tax 800, fees 300, platform -500, payout 9500;
  -- refund -2000; pp_: tickets 4000, platform -200.
  ASSERT (r->>'created')::int = 8 AND (r->>'retagged')::int = 0 AND (r->>'removed')::int = 0, 'FX6: first run: ' || r::text;
  ASSERT (r->>'rows')::int = 11, 'FX6: 8 Exos rows + 3 imported: ' || r::text;
  r := public.exos_gl_backfill('fe000000-0000-0000-0000-0000000000e1');
  ASSERT (r->>'created')::int = 0 AND (r->>'retagged')::int = 0 AND (r->>'removed')::int = 0, 'FX6: idempotent: ' || r::text;
  ASSERT (SELECT amount_cents FROM public.exos_reporting_rows WHERE source_id = 'cs_fe_1' AND revenue_type = 'tickets') = 8900, 'FX6: tickets line';
  ASSERT (SELECT gl_code FROM public.exos_reporting_rows WHERE source_id = 'cs_fe_1' AND revenue_type = 'tickets') = '4010', 'FX6: override code';
  ASSERT (SELECT gl_code FROM public.exos_reporting_rows WHERE source_id = 'cs_fe_1' AND revenue_type = 'tax') = '2200', 'FX6: org code';
  ASSERT (SELECT gl_code IS NULL FROM public.exos_reporting_rows WHERE source_id = 'cs_fe_1' AND revenue_type = 'fees'), 'FX6: uncoded';
  ASSERT (SELECT payment_method FROM public.exos_reporting_rows WHERE source_id = 'pp_' || repeat('fe', 16) AND revenue_type = 'tickets') = 'venmo',
         'FX6: payment method';
  ASSERT (SELECT amount_cents FROM public.exos_reporting_rows WHERE source_type = 'refund') = -2000, 'FX6: refund line';
  ASSERT (SELECT amount_cents FROM public.exos_reporting_rows WHERE source_type = 'payout') = 9500, 'FX6: payout line';
  -- Repoint the override: the backfill re-tags the two ticket lines only.
  UPDATE public.exos_gl_code_assignments SET gl_code_id = pg_temp.g('g1') WHERE id = pg_temp.g('assign');
  r := public.exos_gl_backfill('fe000000-0000-0000-0000-0000000000e1');
  ASSERT (r->>'created')::int = 0 AND (r->>'retagged')::int = 2, 'FX6: re-tagged: ' || r::text;
  -- An org code for bar now: the imported bar line keeps its own code; codes added to the chart link up.
  INSERT INTO public.exos_gl_codes (org_id, code, name, kind) VALUES ('fe000000-0000-0000-0000-000000000001', '4100', 'Bar', 'income');
  r := public.exos_gl_backfill('fe000000-0000-0000-0000-0000000000e1');
  ASSERT (r->>'retagged')::int = 1, 'FX6: imported line linked to the new chart code: ' || r::text;
  ASSERT (SELECT gl_code_id IS NOT NULL AND gl_code = '4100' FROM public.exos_reporting_rows
           WHERE source_id = pg_temp.g('imp1')::text AND revenue_type = 'bar'), 'FX6: linked';
  RAISE NOTICE 'OK  FX6 backfill: rows, idempotent, re-tags';
END $$;

-- FX7 ------------------------------------------------------------------------
DO $$
DECLARE s jsonb; m jsonb;
BEGIN
  PERFORM pg_temp.as_user('fe000000-0000-0000-0000-0000000000a2');
  s := public.exos_cash_summary('fe000000-0000-0000-0000-0000000000e1');
  ASSERT (s->>'gross_cents')::int = 14000 AND (s->>'tax_cents')::int = 800 AND (s->>'refunds_cents')::int = 2000
     AND (s->>'fees_cents')::int = 700, 'FX7: totals: ' || s::text;
  ASSERT (s->>'net_cents')::int = 14000 - 800 - 2000 - 700, 'FX7: net';
  ASSERT (s->'fees'->>'buyer_fees_cents')::int = 300, 'FX7: buyer fees';
  SELECT jsonb_object_agg(x->>'method', x) INTO m FROM jsonb_array_elements(s->'by_payment_method') x;
  ASSERT (m->'card'->>'gross_cents')::int = 10000 AND (m->'card'->>'refunds_cents')::int = 2000, 'FX7: card: ' || m::text;
  ASSERT (m->'venmo'->>'gross_cents')::int = 4000, 'FX7: venmo';
  ASSERT (s->'comps'->>'tickets')::int = 1, 'FX7: comps';
  ASSERT (s->'payouts'->>'stripe_transferred_cents')::int = 9500, 'FX7: payouts: ' || (s->>'payouts');
  s := public.exos_cash_summary('fe000000-0000-0000-0000-0000000000e1', now() + interval '1 day', NULL);
  ASSERT (s->>'gross_cents')::int = 0 AND (s->>'orders')::int = 0, 'FX7: the window';
  RAISE NOTICE 'OK  FX7 cash summary';
END $$;

-- FX8 ------------------------------------------------------------------------
DO $$
DECLARE ok boolean;
BEGIN
  PERFORM pg_temp.as_user('fe000000-0000-0000-0000-0000000000b9');   -- the other org's owner
  ASSERT (SELECT count(*) FROM public.exos_deal_brackets) = 0
     AND (SELECT count(*) FROM public.exos_reporting_rows) = 0
     AND (SELECT count(*) FROM public.exos_imported_ledger_entries) = 0
     AND (SELECT count(*) FROM public.exos_gl_code_assignments) = 0
     AND (SELECT count(*) FROM public.exos_gl_revenue_codes) = 0, 'FX8: sees nothing of ours';
  ok := false;
  BEGIN INSERT INTO public.exos_deal_brackets (offer_id, threshold, percentage) VALUES (pg_temp.g('offer'), 7, 50);
  EXCEPTION WHEN insufficient_privilege THEN ok := true; END;
  ASSERT ok, 'FX8: brackets on our offer';
  DELETE FROM public.exos_imported_ledger_entries WHERE id = pg_temp.g('imp1');
  ok := false;
  BEGIN PERFORM public.exos_gl_backfill('fe000000-0000-0000-0000-0000000000e1');
  EXCEPTION WHEN insufficient_privilege THEN ok := true; END;
  ASSERT ok, 'FX8: backfill our event';
  ok := false;
  BEGIN PERFORM public.exos_cash_summary('fe000000-0000-0000-0000-0000000000e1');
  EXCEPTION WHEN insufficient_privilege THEN ok := true; END;
  ASSERT ok, 'FX8: our cash summary';
  ok := false;
  BEGIN PERFORM public.exos_ledger_import('fe000000-0000-0000-0000-000000000001', '[]');
  EXCEPTION WHEN insufficient_privilege THEN ok := true; END;
  ASSERT ok, 'FX8: import into our org';
  RAISE NOTICE 'OK  FX8 cross-org isolation';
END $$;
RESET ROLE;
DO $$
BEGIN
  ASSERT EXISTS (SELECT 1 FROM public.exos_imported_ledger_entries WHERE id = pg_temp.g('imp1')), 'FX8: their delete did nothing';
  ASSERT public._exos_gl_backfill('fe000000-0000-0000-0000-000000000002', 'fe000000-0000-0000-0000-0000000000e1') IS NULL, 'FX8: unreachable';
EXCEPTION WHEN no_data_found THEN
  RAISE NOTICE 'OK  FX8b the core refuses another org''s event';
END $$;
-- Deleting an entry (finance) removes its reporting rows.
SET ROLE authenticated;
DO $$
BEGIN
  PERFORM pg_temp.as_user('fe000000-0000-0000-0000-0000000000a2');
  DELETE FROM public.exos_imported_ledger_entries WHERE id = pg_temp.g('imp1');
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_reporting_rows WHERE source_type = 'imported' AND source_id = pg_temp.g('imp1')::text),
         'FX5: rows of a deleted entry go';
  RAISE NOTICE 'OK  FX5c deleting an entry';
END $$;
RESET ROLE;

-- Finalizing freezes the brackets with the rest of the inputs.
DO $$
DECLARE st jsonb;
BEGIN
  st := public._exos_settlement_finalize('fe000000-0000-0000-0000-000000000001', NULL, 'fe000000-0000-0000-0000-0000000000e1', NULL);
  ASSERT st->>'status' = 'finalized', 'FX3: finalized';
  ASSERT (SELECT snapshot->'deal_brackets' ? pg_temp.g('offer')::text FROM public.exos_settlements
           WHERE event_id = 'fe000000-0000-0000-0000-0000000000e1'), 'FX3: brackets in the snapshot';
  ASSERT (SELECT jsonb_array_length(snapshot->'imported_entries') = 1 FROM public.exos_settlements
           WHERE event_id = 'fe000000-0000-0000-0000-0000000000e1'), 'FX5: imported entries in the snapshot';
  RAISE NOTICE 'OK  FX3c brackets and imported entries frozen in the settlement snapshot';
END $$;

ROLLBACK;
