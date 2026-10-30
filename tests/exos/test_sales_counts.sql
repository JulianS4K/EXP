-- ============================================================================
-- Sales counts from other platforms (mig 20261030120000). Self-contained (5c…
-- ids), rolled back at the end.
--   S1 manual counts: owner / manager / finance write; same label replaces;
--      validation (label, sold, currency, note)
--   S2 CSV import: tiers merged and summed server-side; re-import replaces;
--      the same numbers again are 'unchanged'; at most 50 ticket types
--   S3 RLS: owner / manager / finance read; scanner, stranger, other org's
--      owner see nothing and can't write; no direct table writes
--   S4 totals per event and currency (exos_sales_count_totals)
--   S5 cross-org: another org can't write to, read or delete our counts;
--      the API writer refuses another org's event / row
--   S6 public total: published events only, the number only; anon has no
--      table, view or writer access
--   S7 caps: 20 entries per event
--   psql -d <db> -v ON_ERROR_STOP=1 -f tests/exos/test_sales_counts.sql
-- ============================================================================
\set ON_ERROR_STOP on
BEGIN;

INSERT INTO auth.users (id, email, email_confirmed_at) VALUES
  ('5c000000-0000-0000-0000-0000000000a0', '5c-owner@x.com', now()),
  ('5c000000-0000-0000-0000-0000000000a1', '5c-manager@x.com', now()),
  ('5c000000-0000-0000-0000-0000000000a2', '5c-finance@x.com', now()),
  ('5c000000-0000-0000-0000-0000000000a3', '5c-scanner@x.com', now()),
  ('5c000000-0000-0000-0000-0000000000a4', '5c-stranger@x.com', now()),
  ('5c000000-0000-0000-0000-0000000000b9', '5c-other-owner@x.com', now());
INSERT INTO public.exos_orgs (id, name, slug, owner_uid) VALUES
  ('5c000000-0000-0000-0000-000000000001', '5C Org', '5c-org', '5c000000-0000-0000-0000-0000000000a0'),
  ('5c000000-0000-0000-0000-000000000002', '5C Other', '5c-other', '5c000000-0000-0000-0000-0000000000b9');
INSERT INTO public.exos_org_memberships (org_id, user_id, role) VALUES
  ('5c000000-0000-0000-0000-000000000001', '5c000000-0000-0000-0000-0000000000a0', 'owner'),
  ('5c000000-0000-0000-0000-000000000001', '5c000000-0000-0000-0000-0000000000a1', 'manager'),
  ('5c000000-0000-0000-0000-000000000001', '5c000000-0000-0000-0000-0000000000a2', 'finance'),
  ('5c000000-0000-0000-0000-000000000001', '5c000000-0000-0000-0000-0000000000a3', 'scanner'),
  ('5c000000-0000-0000-0000-000000000002', '5c000000-0000-0000-0000-0000000000b9', 'owner');
INSERT INTO public.exos_events (id, org_id, name, slug, status, starts_at) VALUES
  ('5c000000-0000-0000-0000-0000000000e1', '5c000000-0000-0000-0000-000000000001', '5C Show', '5c-show', 'published', now() + interval '9 days'),
  ('5c000000-0000-0000-0000-0000000000e2', '5c000000-0000-0000-0000-000000000001', '5C Draft', '5c-draft', 'draft', now() + interval '9 days'),
  ('5c000000-0000-0000-0000-0000000000e9', '5c000000-0000-0000-0000-000000000002', '5C Theirs', '5c-theirs', 'published', now() + interval '9 days');

-- S1 -------------------------------------------------------------------------
SET ROLE authenticated;
DO $$
DECLARE r jsonb;
BEGIN
  PERFORM set_config('app.uid', '5c000000-0000-0000-0000-0000000000a0', true);
  r := public.exos_set_sales_count('5c000000-0000-0000-0000-0000000000e1', '  Box   office ', 12, 24000, 'usd', NULL, 'Cash, Friday');
  ASSERT r->>'status' = 'created' AND r->>'label' = 'Box office' AND r->>'currency' = 'USD'
     AND (r->>'sold')::int = 12 AND (r->>'gross_cents')::bigint = 24000 AND r->>'note' = 'Cash, Friday', 'S1: created ' || r;
  -- Same label, any case: replaces.
  PERFORM set_config('app.uid', '5c000000-0000-0000-0000-0000000000a1', true);
  r := public.exos_set_sales_count('5c000000-0000-0000-0000-0000000000e1', 'BOX OFFICE', 15, 30000, 'USD');
  ASSERT r->>'status' = 'updated' AND (r->>'sold')::int = 15 AND r->>'label' = 'BOX OFFICE' AND r->>'note' IS NULL,
    'S1: manager replaces by label ' || r;
  ASSERT (SELECT count(*) FROM public.exos_sales_counts WHERE event_id = '5c000000-0000-0000-0000-0000000000e1') = 1,
    'S1: one row per label';
  -- Finance writes too (box-office reconciliation).
  PERFORM set_config('app.uid', '5c000000-0000-0000-0000-0000000000a2', true);
  r := public.exos_set_sales_count('5c000000-0000-0000-0000-0000000000e1', 'Consignment', 5, 0, 'USD', 10);
  ASSERT r->>'status' = 'created' AND (r->>'capacity')::int = 10, 'S1: finance writes';
  r := public.exos_set_sales_count('5c000000-0000-0000-0000-0000000000e1', 'Consignment', 5, 0, 'USD', 10);
  ASSERT r->>'status' = 'unchanged', 'S1: same values unchanged';

  BEGIN
    PERFORM public.exos_set_sales_count('5c000000-0000-0000-0000-0000000000e1', ' ', 1, 0, 'USD');
    RAISE EXCEPTION 'S1: empty label accepted';
  EXCEPTION WHEN invalid_parameter_value THEN NULL;
  END;
  BEGIN
    PERFORM public.exos_set_sales_count('5c000000-0000-0000-0000-0000000000e1', repeat('x', 41), 1, 0, 'USD');
    RAISE EXCEPTION 'S1: long label accepted';
  EXCEPTION WHEN invalid_parameter_value THEN NULL;
  END;
  BEGIN
    PERFORM public.exos_set_sales_count('5c000000-0000-0000-0000-0000000000e1', 'Neg', -1, 0, 'USD');
    RAISE EXCEPTION 'S1: negative sold accepted';
  EXCEPTION WHEN invalid_parameter_value THEN NULL;
  END;
  BEGIN
    PERFORM public.exos_set_sales_count('5c000000-0000-0000-0000-0000000000e1', 'Cur', 1, 0, 'dollars');
    RAISE EXCEPTION 'S1: bad currency accepted';
  EXCEPTION WHEN invalid_parameter_value THEN NULL;
  END;
  BEGIN
    PERFORM public.exos_set_sales_count('5c000000-0000-0000-0000-0000000000e1', 'Note', 1, 0, 'USD', NULL, repeat('n', 201));
    RAISE EXCEPTION 'S1: long note accepted';
  EXCEPTION WHEN invalid_parameter_value THEN NULL;
  END;
  RAISE NOTICE 'OK  S1 manual counts';
END $$;

-- S2 -------------------------------------------------------------------------
DO $$
DECLARE r jsonb; v_id uuid;
BEGIN
  PERFORM set_config('app.uid', '5c000000-0000-0000-0000-0000000000a1', true);
  -- Two lines of "GA" (any case) merge; capacity is the largest given.
  r := public.exos_import_sales_counts('5c000000-0000-0000-0000-0000000000e1', 'DICE', 'gbp',
    '[{"name":"Early","sold":50,"gross_cents":100000,"capacity":50},
      {"name":"GA","sold":20,"gross_cents":60000,"capacity":150},
      {"name":" ga ","sold":10,"gross_cents":30000,"capacity":100}]'::jsonb,
    NULL, NULL, NULL, 'dice-export.csv', 3);
  ASSERT r->>'status' = 'created' AND r->>'platform' = 'dice' AND r->>'label' = 'DICE' AND r->>'currency' = 'GBP',
    'S2: created ' || r;
  ASSERT (r->>'sold')::int = 80 AND (r->>'gross_cents')::bigint = 190000 AND (r->>'capacity')::int = 200,
    'S2: summed server-side ' || r;
  ASSERT jsonb_array_length(r->'tiers') = 2 AND (r->'tiers'->1->>'sold')::int = 30
     AND (r->'tiers'->1->>'capacity')::int = 150, 'S2: tiers merged ' || (r->'tiers');
  v_id := (r->>'id')::uuid;
  -- Same file again: unchanged, same row.
  r := public.exos_import_sales_counts('5c000000-0000-0000-0000-0000000000e1', 'dice', 'GBP',
    '[{"name":"Early","sold":50,"gross_cents":100000,"capacity":50},
      {"name":"GA","sold":20,"gross_cents":60000,"capacity":150},
      {"name":"GA","sold":10,"gross_cents":30000,"capacity":100}]'::jsonb,
    NULL, NULL, NULL, 'dice-export.csv', 3);
  ASSERT r->>'status' = 'unchanged' AND (r->>'id')::uuid = v_id, 'S2: re-import unchanged ' || r;
  -- A newer export replaces (snapshot, not increment).
  r := public.exos_import_sales_counts('5c000000-0000-0000-0000-0000000000e1', 'dice', 'GBP',
    '[{"name":"Early","sold":50,"gross_cents":100000,"capacity":50},
      {"name":"GA","sold":45,"gross_cents":135000,"capacity":150}]'::jsonb);
  ASSERT r->>'status' = 'updated' AND (r->>'id')::uuid = v_id AND (r->>'sold')::int = 95, 'S2: replaced ' || r;
  ASSERT (SELECT count(*) FROM public.exos_sales_counts WHERE event_id = '5c000000-0000-0000-0000-0000000000e1' AND platform = 'dice') = 1,
    'S2: one row per platform';
  -- No tiers: the totals given.
  r := public.exos_import_sales_counts('5c000000-0000-0000-0000-0000000000e1', 'ra', 'EUR', '[]'::jsonb, 7, 7000);
  ASSERT (r->>'sold')::int = 7 AND r->>'label' = 'Resident Advisor', 'S2: tier-less import';

  BEGIN
    PERFORM public.exos_import_sales_counts('5c000000-0000-0000-0000-0000000000e1', 'myspace', 'USD', '[]'::jsonb, 1, 0);
    RAISE EXCEPTION 'S2: unknown platform accepted';
  EXCEPTION WHEN invalid_parameter_value THEN NULL;
  END;
  BEGIN
    PERFORM public.exos_import_sales_counts('5c000000-0000-0000-0000-0000000000e1', 'posh', 'USD',
      '[{"name":"GA","sold":1.5}]'::jsonb);
    RAISE EXCEPTION 'S2: fractional sold accepted';
  EXCEPTION WHEN invalid_parameter_value THEN NULL;
  END;
  BEGIN
    PERFORM public.exos_import_sales_counts('5c000000-0000-0000-0000-0000000000e1', 'posh', 'USD',
      '[{"name":"","sold":1}]'::jsonb);
    RAISE EXCEPTION 'S2: nameless tier accepted';
  EXCEPTION WHEN invalid_parameter_value THEN NULL;
  END;
  BEGIN
    PERFORM public.exos_import_sales_counts('5c000000-0000-0000-0000-0000000000e1', 'posh', 'USD',
      (SELECT jsonb_agg(jsonb_build_object('name', 'T' || i, 'sold', 1)) FROM generate_series(1, 51) i));
    RAISE EXCEPTION 'S2: 51 ticket types accepted';
  EXCEPTION WHEN invalid_parameter_value THEN NULL;
  END;
  RAISE NOTICE 'OK  S2 CSV import: merged, idempotent, replaces';
END $$;

-- S3 -------------------------------------------------------------------------
DO $$
DECLARE n int;
BEGIN
  FOREACH n IN ARRAY ARRAY[0, 1, 2] LOOP
    PERFORM set_config('app.uid', '5c000000-0000-0000-0000-0000000000a' || n, true);
    ASSERT (SELECT count(*) FROM public.exos_sales_counts) = 4, 'S3: a' || n || ' reads the counts';
  END LOOP;
  FOREACH n IN ARRAY ARRAY[3, 4] LOOP
    PERFORM set_config('app.uid', '5c000000-0000-0000-0000-0000000000a' || n, true);
    ASSERT (SELECT count(*) FROM public.exos_sales_counts) = 0, 'S3: a' || n || ' reads nothing';
    ASSERT (SELECT count(*) FROM public.exos_sales_count_totals) = 0, 'S3: a' || n || ' no totals';
    BEGIN
      PERFORM public.exos_set_sales_count('5c000000-0000-0000-0000-0000000000e1', 'Sneaky', 1, 0, 'USD');
      RAISE EXCEPTION 'S3: a% wrote a count', n;
    EXCEPTION WHEN insufficient_privilege THEN NULL;
    END;
    BEGIN
      PERFORM public.exos_import_sales_counts('5c000000-0000-0000-0000-0000000000e1', 'posh', 'USD', '[]'::jsonb, 1, 0);
      RAISE EXCEPTION 'S3: a% imported', n;
    EXCEPTION WHEN insufficient_privilege THEN NULL;
    END;
  END LOOP;
  -- Owner: no direct table writes either.
  PERFORM set_config('app.uid', '5c000000-0000-0000-0000-0000000000a0', true);
  BEGIN
    UPDATE public.exos_sales_counts SET sold = 999;
    RAISE EXCEPTION 'S3: direct update allowed';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  BEGIN
    INSERT INTO public.exos_sales_counts (org_id, event_id, kind, label, source_key, sold, currency)
    VALUES ('5c000000-0000-0000-0000-000000000001', '5c000000-0000-0000-0000-0000000000e1', 'manual', 'X', 'manual:x', 1, 'USD');
    RAISE EXCEPTION 'S3: direct insert allowed';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  -- Internal helpers aren't client-callable.
  BEGIN
    PERFORM public._exos_sales_count_write('5c000000-0000-0000-0000-000000000001', '5c000000-0000-0000-0000-0000000000e1',
      NULL, 'manual', 'X', NULL, 1, 0, 'USD', NULL, '[]', NULL, NULL, NULL, NULL);
    RAISE EXCEPTION 'S3: writer callable';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  BEGIN
    PERFORM public.exos_api_sales_count_put('5c000000-0000-0000-0000-000000000001', '5c000000-0000-0000-0000-0000000000e1',
      NULL, 'manual', 'X', NULL, 1, 0, 'USD', NULL, '[]', NULL);
    RAISE EXCEPTION 'S3: API writer callable by a signed-in user';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  RAISE NOTICE 'OK  S3 RLS: owner/manager/finance only, writes through the RPCs';
END $$;

-- S4 -------------------------------------------------------------------------
DO $$
BEGIN
  PERFORM set_config('app.uid', '5c000000-0000-0000-0000-0000000000a2', true);
  ASSERT (SELECT sold = 20 AND gross_cents = 30000 AND entries = 2 FROM public.exos_sales_count_totals
           WHERE event_id = '5c000000-0000-0000-0000-0000000000e1' AND currency = 'USD'), 'S4: USD totals';
  ASSERT (SELECT sold = 95 AND gross_cents = 235000 FROM public.exos_sales_count_totals
           WHERE event_id = '5c000000-0000-0000-0000-0000000000e1' AND currency = 'GBP'), 'S4: GBP totals';
  ASSERT (SELECT count(*) FROM public.exos_sales_count_totals WHERE event_id = '5c000000-0000-0000-0000-0000000000e1') = 3,
    'S4: one row per currency, never mixed';
  RAISE NOTICE 'OK  S4 totals per event and currency';
END $$;

-- S5 -------------------------------------------------------------------------
DO $$
DECLARE v_id uuid; ok boolean;
BEGIN
  PERFORM set_config('app.uid', '5c000000-0000-0000-0000-0000000000b9', true);
  ASSERT (SELECT count(*) FROM public.exos_sales_counts) = 0, 'S5: other org reads nothing';
  BEGIN
    PERFORM public.exos_set_sales_count('5c000000-0000-0000-0000-0000000000e1', 'Sneaky', 1, 0, 'USD');
    RAISE EXCEPTION 'S5: other org wrote';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  -- Its own event works.
  PERFORM public.exos_set_sales_count('5c000000-0000-0000-0000-0000000000e9', 'Door', 3, 0, 'USD');
  -- Can't delete ours.
  SELECT id INTO v_id FROM public.exos_sales_counts WHERE event_id = '5c000000-0000-0000-0000-0000000000e9';
  PERFORM set_config('app.uid', '5c000000-0000-0000-0000-0000000000a0', true);
  ASSERT (SELECT count(*) FROM public.exos_sales_counts WHERE org_id = '5c000000-0000-0000-0000-000000000002') = 0,
    'S5: we don''t see theirs';
  BEGIN
    PERFORM public.exos_delete_sales_count(v_id);
    RAISE EXCEPTION 'S5: deleted another org''s row';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  -- Owner deletes our own.
  SELECT id INTO v_id FROM public.exos_sales_counts WHERE label = 'Consignment';
  ok := public.exos_delete_sales_count(v_id);
  ASSERT ok AND NOT EXISTS (SELECT 1 FROM public.exos_sales_counts WHERE id = v_id), 'S5: owner deletes';
  RAISE NOTICE 'OK  S5 cross-org isolation (signed in)';
END $$;
RESET ROLE;

SET ROLE service_role;
DO $$
DECLARE r jsonb; v_id uuid; v_theirs uuid;
BEGIN
  -- API: create, update by id (rename), delete; scoped to the key's org.
  r := public.exos_api_sales_count_put('5c000000-0000-0000-0000-000000000001', '5c000000-0000-0000-0000-0000000000e1',
    NULL, 'manual', 'Street team', NULL, 4, 8000, 'USD', NULL, NULL, NULL);
  ASSERT r->>'status' = 'created', 'S5: API create ' || r;
  v_id := (r->>'id')::uuid;
  r := public.exos_api_sales_count_put('5c000000-0000-0000-0000-000000000001', NULL, v_id, NULL, 'Street team B',
    NULL, 6, NULL, NULL, NULL, NULL, NULL);
  ASSERT r->>'status' = 'updated' AND r->>'label' = 'Street team B' AND (r->>'sold')::int = 6
     AND (r->>'gross_cents')::bigint = 8000 AND r->>'currency' = 'USD', 'S5: API partial update keeps the rest ' || r;
  BEGIN
    PERFORM public.exos_api_sales_count_put('5c000000-0000-0000-0000-000000000001', NULL, v_id, NULL, 'box office',
      NULL, NULL, NULL, NULL, NULL, NULL, NULL);
    RAISE EXCEPTION 'S5: rename onto an existing label';
  EXCEPTION WHEN unique_violation THEN NULL;
  END;
  BEGIN
    PERFORM public.exos_api_sales_count_put('5c000000-0000-0000-0000-000000000001', '5c000000-0000-0000-0000-0000000000e9',
      NULL, 'manual', 'Sneaky', NULL, 1, 0, 'USD', NULL, NULL, NULL);
    RAISE EXCEPTION 'S5: API wrote another org''s event';
  EXCEPTION WHEN no_data_found THEN NULL;
  END;
  SELECT id INTO v_theirs FROM public.exos_sales_counts WHERE org_id = '5c000000-0000-0000-0000-000000000002';
  BEGIN
    PERFORM public.exos_api_sales_count_put('5c000000-0000-0000-0000-000000000001', NULL, v_theirs, NULL, NULL,
      NULL, 99, NULL, NULL, NULL, NULL, NULL);
    RAISE EXCEPTION 'S5: API updated another org''s row';
  EXCEPTION WHEN no_data_found THEN NULL;
  END;
  ASSERT NOT public.exos_api_sales_count_delete('5c000000-0000-0000-0000-000000000001', v_theirs), 'S5: API delete theirs';
  ASSERT EXISTS (SELECT 1 FROM public.exos_sales_counts WHERE id = v_theirs), 'S5: theirs still there';
  ASSERT public.exos_api_sales_count_delete('5c000000-0000-0000-0000-000000000001', v_id), 'S5: API delete ours';
  RAISE NOTICE 'OK  S5 cross-org isolation (API writer)';
END $$;
RESET ROLE;

-- S6 -------------------------------------------------------------------------
SET ROLE anon;
DO $$
BEGIN
  ASSERT (SELECT sold FROM public.exos_public_sales_count_total(ARRAY['5c000000-0000-0000-0000-0000000000e1']::uuid[])) = 117,
    'S6: published total';
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_public_sales_count_total(ARRAY['5c000000-0000-0000-0000-0000000000e2']::uuid[])),
    'S6: a draft answers nothing';
  -- Only two columns come back: the id and the number.
  ASSERT (SELECT count(*) FROM information_schema.routines r
           JOIN information_schema.parameters p ON p.specific_name = r.specific_name
          WHERE r.routine_name = 'exos_public_sales_count_total' AND p.parameter_mode = 'OUT') = 2,
    'S6: id + total only';
  BEGIN
    PERFORM 1 FROM public.exos_sales_counts;
    RAISE EXCEPTION 'S6: anon read the table';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  BEGIN
    PERFORM 1 FROM public.exos_sales_count_totals;
    RAISE EXCEPTION 'S6: anon read the totals view';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  BEGIN
    PERFORM public.exos_set_sales_count('5c000000-0000-0000-0000-0000000000e1', 'Anon', 1, 0, 'USD');
    RAISE EXCEPTION 'S6: anon wrote';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  BEGIN
    PERFORM 1 FROM public.exos_public_sales_count_total(array_fill('5c000000-0000-0000-0000-0000000000e1'::uuid, ARRAY[201]));
    RAISE EXCEPTION 'S6: 201 ids accepted';
  EXCEPTION WHEN invalid_parameter_value THEN NULL;
  END;
  RAISE NOTICE 'OK  S6 public: published total only';
END $$;
RESET ROLE;

-- S7 -------------------------------------------------------------------------
SET ROLE authenticated;
DO $$
DECLARE i int;
BEGIN
  PERFORM set_config('app.uid', '5c000000-0000-0000-0000-0000000000a0', true);
  FOR i IN 1..17 LOOP
    PERFORM public.exos_set_sales_count('5c000000-0000-0000-0000-0000000000e1', 'Filler ' || i, 1, 0, 'USD');
  END LOOP;
  ASSERT (SELECT count(*) FROM public.exos_sales_counts WHERE event_id = '5c000000-0000-0000-0000-0000000000e1') = 20,
    'S7: 20 entries';
  BEGIN
    PERFORM public.exos_set_sales_count('5c000000-0000-0000-0000-0000000000e1', 'One too many', 1, 0, 'USD');
    RAISE EXCEPTION 'S7: 21st entry accepted';
  EXCEPTION WHEN invalid_parameter_value THEN NULL;
  END;
  -- Replacing an existing one still works at the cap.
  ASSERT public.exos_set_sales_count('5c000000-0000-0000-0000-0000000000e1', 'Filler 1', 2, 0, 'USD')->>'status' = 'updated',
    'S7: replace at the cap';
  RAISE NOTICE 'OK  S7 at most 20 entries per event';
END $$;
RESET ROLE;

SELECT '*** SALES COUNTS PASSED ***';
ROLLBACK;
