-- ============================================================================
-- Templates, rental invoices, inbound submissions, deleting a draft event
-- (mig 20261102130000). Self-contained (d7… ids), rolled back at the end.
--   TI1 grants: no anon table access; cores service_role only; wrappers
--       signed-in only; the two anon RPCs are the only anon surface
--   TI2 event templates: roles, validation, create a draft event from one
--       (tiers in cents -> price, fee rules, doors / end, inherit switch,
--       use count), archived refused, save an event as a template
--   TI3 note templates: content writes, finance reads, scanners nothing
--   TI4 rental templates + invoices: lines and totals, invoice for a held
--       night (venue / room / date derived), draft edits, gapless numbering
--       (a failed issue burns no number), frozen once issued, never deleted,
--       void keeps the number, prefix, paid / void transitions, roles
--   TI5 inbound: form off by default, public text, honeypot, body cap,
--       per-network / per-email limits, staff review, hold from a
--       submission, delete, the IP hash never reaches the dashboard
--   TI6 deleting an event: drafts with nothing sold only; 55000 otherwise
--   TI7 cross-org isolation for every core
--   psql -d <db> -v ON_ERROR_STOP=1 -f tests/exos/test_templates_inbound.sql
-- ============================================================================
\set ON_ERROR_STOP on
BEGIN;

INSERT INTO auth.users (id, email, email_confirmed_at) VALUES
  ('d7000000-0000-0000-0000-0000000000a0', 'd7-owner@x.com', now()),
  ('d7000000-0000-0000-0000-0000000000a1', 'd7-manager@x.com', now()),
  ('d7000000-0000-0000-0000-0000000000a2', 'd7-finance@x.com', now()),
  ('d7000000-0000-0000-0000-0000000000a3', 'd7-scanner@x.com', now()),
  ('d7000000-0000-0000-0000-0000000000a4', 'd7-content@x.com', now()),
  ('d7000000-0000-0000-0000-0000000000b9', 'd7-other@x.com', now());
INSERT INTO public.exos_orgs (id, name, slug, owner_uid) VALUES
  ('d7000000-0000-0000-0000-000000000001', 'D7 Org', 'd7-org', 'd7000000-0000-0000-0000-0000000000a0'),
  ('d7000000-0000-0000-0000-000000000002', 'D7 Other', 'd7-other', 'd7000000-0000-0000-0000-0000000000b9');
INSERT INTO public.exos_org_memberships (org_id, user_id, role) VALUES
  ('d7000000-0000-0000-0000-000000000001', 'd7000000-0000-0000-0000-0000000000a0', 'owner'),
  ('d7000000-0000-0000-0000-000000000001', 'd7000000-0000-0000-0000-0000000000a1', 'manager'),
  ('d7000000-0000-0000-0000-000000000001', 'd7000000-0000-0000-0000-0000000000a2', 'finance'),
  ('d7000000-0000-0000-0000-000000000001', 'd7000000-0000-0000-0000-0000000000a3', 'scanner'),
  ('d7000000-0000-0000-0000-000000000001', 'd7000000-0000-0000-0000-0000000000a4', 'content'),
  ('d7000000-0000-0000-0000-000000000002', 'd7000000-0000-0000-0000-0000000000b9', 'owner');
INSERT INTO public.exos_venues (id, org_id, name, timezone, capacity) VALUES
  ('d7000000-0000-0000-0000-0000000000c1', 'd7000000-0000-0000-0000-000000000001', 'D7 Hall', 'America/Chicago', 400),
  ('d7000000-0000-0000-0000-0000000000c2', 'd7000000-0000-0000-0000-000000000002', 'Other Hall', 'America/Chicago', 100);
INSERT INTO public.exos_venue_rooms (id, venue_id, name, capacity) VALUES
  ('d7000000-0000-0000-0000-0000000000c3', 'd7000000-0000-0000-0000-0000000000c1', 'Back Room', 120);

-- The harness's exos_events / tiers carry none of prod's staff grants; give
-- the signed-in role plain read here (rolled back).
GRANT SELECT ON public.exos_events, public.exos_ticket_tiers TO authenticated;

CREATE FUNCTION pg_temp.as_user(p_uid text) RETURNS void LANGUAGE sql AS $$
  SELECT set_config('app.uid', coalesce(p_uid, ''), true)::text IS NOT NULL AND true;
$$;
GRANT EXECUTE ON FUNCTION pg_temp.as_user(text) TO anon, authenticated, service_role;
CREATE TEMP TABLE d7 (k text PRIMARY KEY, v uuid);
GRANT ALL ON d7 TO anon, authenticated, service_role;

-- TI1 -------------------------------------------------------------------------
DO $$
DECLARE t text; f text;
BEGIN
  FOREACH t IN ARRAY ARRAY['exos_event_templates', 'exos_note_templates', 'exos_rental_invoice_templates',
                           'exos_rental_invoice_counters', 'exos_rental_invoices', 'exos_inbound_settings',
                           'exos_inbound_submissions'] LOOP
    ASSERT NOT has_table_privilege('anon', 'public.' || t, 'SELECT'), 'TI1: anon reads ' || t;
    ASSERT NOT has_table_privilege('anon', 'public.' || t, 'INSERT'), 'TI1: anon writes ' || t;
    ASSERT (SELECT relrowsecurity FROM pg_class WHERE oid = ('public.' || t)::regclass), 'TI1: RLS on ' || t;
  END LOOP;
  -- Numbers and totals have no client write path.
  ASSERT NOT has_table_privilege('authenticated', 'public.exos_rental_invoices', 'INSERT')
     AND NOT has_table_privilege('authenticated', 'public.exos_rental_invoices', 'UPDATE')
     AND NOT has_table_privilege('authenticated', 'public.exos_rental_invoice_counters', 'UPDATE'),
    'TI1: rental invoices / counters are written only through functions';
  ASSERT NOT has_column_privilege('authenticated', 'public.exos_inbound_submissions', 'ip_hash', 'SELECT'),
    'TI1: the network hash is not readable from the dashboard';
  FOREACH f IN ARRAY ARRAY['_exos_event_from_template(uuid,uuid,uuid,jsonb)', '_exos_event_template_from_event(uuid,uuid,uuid,text)',
                           '_exos_rental_invoice_create(uuid,uuid,text,jsonb)', '_exos_rental_invoice_update(uuid,uuid,jsonb)',
                           '_exos_rental_invoice_issue(uuid,uuid,date)', '_exos_rental_invoice_set_status(uuid,uuid,text,text)',
                           '_exos_rental_invoice_delete(uuid,uuid)', '_exos_inbound_create(uuid,text,jsonb,text,text,uuid)',
                           '_exos_inbound_set_status(uuid,uuid,uuid,text,text)', '_exos_inbound_hold(uuid,uuid,text,uuid,uuid,jsonb)',
                           '_exos_event_delete(uuid,uuid)'] LOOP
    ASSERT has_function_privilege('service_role', 'public.' || f, 'EXECUTE'), 'TI1: service_role runs ' || f;
    ASSERT NOT has_function_privilege('authenticated', 'public.' || f, 'EXECUTE')
       AND NOT has_function_privilege('anon', 'public.' || f, 'EXECUTE'), 'TI1: core is service_role only: ' || f;
  END LOOP;
  FOREACH f IN ARRAY ARRAY['exos_event_from_template(uuid,jsonb)', 'exos_event_template_from_event(uuid,text)',
                           'exos_rental_invoice_create(uuid,jsonb)', 'exos_rental_invoice_issue(uuid,date)',
                           'exos_rental_invoice_set_status(uuid,text,text)', 'exos_rental_invoice_delete(uuid)',
                           'exos_rental_invoice_update(uuid,jsonb)', 'exos_rental_invoice_prefix_set(uuid,text)',
                           'exos_inbound_set_status(uuid,text,text)', 'exos_inbound_create_hold(uuid,jsonb)',
                           'exos_event_delete(uuid)'] LOOP
    ASSERT has_function_privilege('authenticated', 'public.' || f, 'EXECUTE')
       AND NOT has_function_privilege('anon', 'public.' || f, 'EXECUTE'), 'TI1: signed-in only: ' || f;
  END LOOP;
  ASSERT has_function_privilege('anon', 'public.exos_inbound_submit(text,jsonb)', 'EXECUTE')
     AND has_function_privilege('anon', 'public.exos_inbound_form_public(text)', 'EXECUTE'), 'TI1: the form is anon';
  RAISE NOTICE 'OK  TI1 grants';
END $$;

-- TI2 -------------------------------------------------------------------------
SET ROLE authenticated;
DO $$
DECLARE v uuid; r jsonb; ok boolean; e record;
BEGIN
  PERFORM pg_temp.as_user('d7000000-0000-0000-0000-0000000000a1');  -- manager
  INSERT INTO public.exos_event_templates (org_id, name, event_name, description, capacity, doors_offset_minutes,
                                           duration_minutes, event_fields, tiers, fee_rules, inherit_org_fees)
  VALUES ('d7000000-0000-0000-0000-000000000001', ' Friday club night ', 'Club Night', 'Late show. 21+.', 300, 60, 240,
          '{"timezone":"America/Chicago","currency":"usd","venue_name":"D7 Hall","exos_venue_id":"d7000000-0000-0000-0000-0000000000c1"}',
          '[{"name":"GA","price_cents":2500,"capacity":250},{"name":"VIP","price_cents":6000,"capacity":50,"visibility":"hidden"}]',
          '[{"name":"Facility","kind":"passed_on","calc":"fixed","amount_cents":200},{"name":"Card","kind":"absorbed","calc":"percent","percent":3,"per":"order"}]',
          false)
  RETURNING id INTO v;
  INSERT INTO d7 VALUES ('etpl', v);
  ASSERT (SELECT name = 'Friday club night' AND created_by = 'd7000000-0000-0000-0000-0000000000a1'
                 AND tiers -> 0 ->> 'ticket_type' = 'paid' AND (tiers -> 1 ->> 'sort_order')::int = 1
                 AND fee_rules -> 0 ->> 'per' = 'ticket' AND fee_rules -> 0 ->> 'recipient' = 'org'
            FROM public.exos_event_templates WHERE id = v), 'TI2: trimmed, creator, tiers and fee rules normalized';

  -- Validation.
  BEGIN
    INSERT INTO public.exos_event_templates (org_id, name, event_fields)
    VALUES ('d7000000-0000-0000-0000-000000000001', 'Bad', '{"status":"published"}');
    RAISE EXCEPTION 'TI2: a server-owned setting was accepted';
  EXCEPTION WHEN SQLSTATE '22023' THEN NULL;
  END;
  BEGIN
    INSERT INTO public.exos_event_templates (org_id, name, tiers)
    VALUES ('d7000000-0000-0000-0000-000000000001', 'Bad', '[{"name":"GA","price_cents":-5}]');
    RAISE EXCEPTION 'TI2: a negative price was accepted';
  EXCEPTION WHEN SQLSTATE '22023' THEN NULL;
  END;
  BEGIN
    INSERT INTO public.exos_event_templates (org_id, name, fee_rules)
    VALUES ('d7000000-0000-0000-0000-000000000001', 'Bad', '[{"name":"Order fee","kind":"passed_on","calc":"fixed","amount_cents":100,"per":"order"}]');
    RAISE EXCEPTION 'TI2: a passed-on per-order fee was accepted';
  EXCEPTION WHEN SQLSTATE '22023' THEN NULL;
  END;
  BEGIN
    INSERT INTO public.exos_event_templates (org_id, name, event_fields)
    VALUES ('d7000000-0000-0000-0000-000000000001', 'Bad', '{"exos_venue_id":"d7000000-0000-0000-0000-0000000000c2"}');
    RAISE EXCEPTION 'TI2: another org''s venue was accepted';
  EXCEPTION WHEN SQLSTATE '22023' THEN NULL;
  END;

  -- Content and finance read; they can't write; scanners see nothing.
  PERFORM pg_temp.as_user('d7000000-0000-0000-0000-0000000000a4');
  ASSERT (SELECT count(*) FROM public.exos_event_templates WHERE id = v) = 1, 'TI2: content reads';
  BEGIN
    INSERT INTO public.exos_event_templates (org_id, name) VALUES ('d7000000-0000-0000-0000-000000000001', 'Nope');
    RAISE EXCEPTION 'TI2: content wrote an event template';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  BEGIN
    PERFORM public.exos_event_from_template(v, '{}');
    RAISE EXCEPTION 'TI2: content made an event';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  PERFORM pg_temp.as_user('d7000000-0000-0000-0000-0000000000a3');
  ASSERT (SELECT count(*) FROM public.exos_event_templates) = 0, 'TI2: scanners see nothing';

  -- Create a draft event from it.
  PERFORM pg_temp.as_user('d7000000-0000-0000-0000-0000000000a0');
  r := public.exos_event_from_template(v, '{"starts_at":"2026-12-04T03:00:00Z","name":"Club Night: Dec 3"}');
  INSERT INTO d7 VALUES ('ev1', (r ->> 'event_id')::uuid);
  SELECT * INTO e FROM public.exos_events WHERE id = (r ->> 'event_id')::uuid;
  ASSERT e.status = 'draft' AND e.name = 'Club Night: Dec 3' AND e.org_id = 'd7000000-0000-0000-0000-000000000001'
     AND e.doors_at = '2026-12-04T02:00:00Z' AND e.ends_at = '2026-12-04T07:00:00Z' AND e.timezone = 'America/Chicago'
     AND e.total_tickets = 300 AND e.description = 'Late show. 21+.' AND e.venue_name = 'D7 Hall'
     AND e.created_by = 'd7000000-0000-0000-0000-0000000000a0',
    'TI2: a draft with the name, dates from the start, settings and capacity';
  ASSERT (SELECT array_agg(name || ':' || price::text || ':' || capacity || ':' || visibility ORDER BY sort_order)
            FROM public.exos_ticket_tiers WHERE event_id = e.id) = ARRAY['GA:25.00:250:public', 'VIP:60.00:50:hidden'],
    'TI2: tiers with prices from cents';
  RESET ROLE;
  ASSERT (SELECT count(*) FROM public.exos_fee_rules WHERE event_id = e.id) = 2
     AND (SELECT inherit_org_rules FROM public.exos_event_fee_settings WHERE event_id = e.id) = false,
    'TI2: event fee rules copied, org rules off';
  ASSERT (SELECT use_count = 1 AND last_used_at IS NOT NULL FROM public.exos_event_templates WHERE id = v), 'TI2: use counted';
  SET ROLE authenticated;
  PERFORM pg_temp.as_user('d7000000-0000-0000-0000-0000000000a0');
  -- No start: a draft with no dates; unknown args refused.
  r := public.exos_event_from_template(v, '{}');
  ASSERT (SELECT starts_at IS NULL AND doors_at IS NULL AND name = 'Club Night' FROM public.exos_events WHERE id = (r ->> 'event_id')::uuid),
    'TI2: no start, no dates; the template''s event name';
  BEGIN
    PERFORM public.exos_event_from_template(v, '{"status":"published"}');
    RAISE EXCEPTION 'TI2: an unknown arg was accepted';
  EXCEPTION WHEN SQLSTATE '22023' THEN NULL;
  END;
  -- Archived: refused.
  UPDATE public.exos_event_templates SET status = 'archived' WHERE id = v;
  BEGIN
    PERFORM public.exos_event_from_template(v, '{}');
    RAISE EXCEPTION 'TI2: an archived template made an event';
  EXCEPTION WHEN SQLSTATE '55000' THEN NULL;
  END;
  UPDATE public.exos_event_templates SET status = 'active' WHERE id = v;

  -- Save an event as a template: the setup comes back.
  v := public.exos_event_template_from_event((SELECT d7.v FROM d7 WHERE k = 'ev1'), 'Copy');
  ASSERT (SELECT name = 'Copy' AND doors_offset_minutes = 60 AND duration_minutes = 240 AND capacity = 300
                 AND jsonb_array_length(tiers) = 2 AND (tiers -> 1 ->> 'price_cents')::int = 6000
                 AND jsonb_array_length(fee_rules) = 2 AND inherit_org_fees = false
                 AND event_fields ->> 'timezone' = 'America/Chicago'
            FROM public.exos_event_templates WHERE id = v), 'TI2: save as template snapshots the event';
  RAISE NOTICE 'OK  TI2 event templates';
END $$;
RESET ROLE;

-- TI3 -------------------------------------------------------------------------
SET ROLE authenticated;
DO $$
DECLARE v uuid;
BEGIN
  PERFORM pg_temp.as_user('d7000000-0000-0000-0000-0000000000a4');  -- content
  INSERT INTO public.exos_note_templates (org_id, title, body)
  VALUES ('d7000000-0000-0000-0000-000000000001', ' Advance checklist ', 'Parking: 2 spots. Hospitality: hot meal for 6.')
  RETURNING id INTO v;
  INSERT INTO d7 VALUES ('ntpl', v);
  ASSERT (SELECT title = 'Advance checklist' AND created_by = 'd7000000-0000-0000-0000-0000000000a4'
            FROM public.exos_note_templates WHERE id = v), 'TI3: content writes, trimmed, creator';
  PERFORM pg_temp.as_user('d7000000-0000-0000-0000-0000000000a2');  -- finance
  ASSERT (SELECT count(*) FROM public.exos_note_templates WHERE id = v) = 1, 'TI3: finance reads';
  UPDATE public.exos_note_templates SET body = 'x' WHERE id = v;
  ASSERT (SELECT body FROM public.exos_note_templates WHERE id = v) <> 'x', 'TI3: finance can''t edit';
  PERFORM pg_temp.as_user('d7000000-0000-0000-0000-0000000000a3');
  ASSERT (SELECT count(*) FROM public.exos_note_templates) = 0, 'TI3: scanners see nothing';
  BEGIN
    PERFORM pg_temp.as_user('d7000000-0000-0000-0000-0000000000a0');
    INSERT INTO public.exos_note_templates (org_id, title, body) VALUES ('d7000000-0000-0000-0000-000000000001', 'Empty', '  ');
    RAISE EXCEPTION 'TI3: an empty body was accepted';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
  RAISE NOTICE 'OK  TI3 note templates';
END $$;
RESET ROLE;

-- TI4 -------------------------------------------------------------------------
-- A hold night to rent.
DO $$
DECLARE r jsonb;
BEGIN
  r := public._exos_hold_create('d7000000-0000-0000-0000-000000000001', 'd7000000-0000-0000-0000-0000000000a0', 'dashboard', NULL,
         '{"title":"Private party","positions":[{"date":"2026-12-12","venue_id":"d7000000-0000-0000-0000-0000000000c1","room_id":"d7000000-0000-0000-0000-0000000000c3"}]}');
  INSERT INTO d7 VALUES ('hold', (r ->> 'id')::uuid);
  INSERT INTO d7 SELECT 'night', id FROM public.exos_hold_positions WHERE hold_id = (r ->> 'id')::uuid;
END $$;

SET ROLE authenticated;
DO $$
DECLARE v uuid; r jsonb; n int; ok boolean;
BEGIN
  PERFORM pg_temp.as_user('d7000000-0000-0000-0000-0000000000a1');
  INSERT INTO public.exos_rental_invoice_templates (org_id, title, payee_name, attendance_count, discount_cents, items, deposits, tax_fees, terms)
  VALUES ('d7000000-0000-0000-0000-000000000001', 'Back room rental', 'D7 Org LLC', 80, 5000,
          '[{"title":"Room hire","cost_cents":50000},{"title":"Bar staff","quantity":"2.5","cost_cents":3000},{"title":"Security","cost_type":"per_head","cost_cents":150}]',
          '[{"deposit_type":"percent","value":50,"relative_due_days":14},{"deposit_type":"flat","value":10000,"due_date_type":"specific","specific_due_date":"2026-12-01"}]',
          '[{"name":"Sales tax","rate_percent":"8.875"}]', '<p>Net 30.</p>')
  RETURNING id INTO v;
  INSERT INTO d7 VALUES ('rtpl', v);
  ASSERT (SELECT items -> 1 ->> 'quantity' = '2.5' AND items -> 2 ->> 'position' = '2' AND items -> 0 ->> 'cost_type' = 'fixed'
            FROM public.exos_rental_invoice_templates WHERE id = v), 'TI4: lines normalized';
  BEGIN
    UPDATE public.exos_rental_invoice_templates SET items = '[{"title":"x","cost_type":"hourly","cost_cents":1}]' WHERE id = v;
    RAISE EXCEPTION 'TI4: a bad cost_type was accepted';
  EXCEPTION WHEN SQLSTATE '22023' THEN NULL;
  END;
  -- Totals: 50000 + 2.5 x 3000 + 80 x 150 = 69500; less 5000 = 64500;
  -- tax round(64500 x 8.875%) = 5724; total 70224; deposits 35112 + 10000.
  r := public._exos_rental_totals((SELECT items FROM public.exos_rental_invoice_templates WHERE id = v), 80, 5000,
                                  (SELECT tax_fees FROM public.exos_rental_invoice_templates WHERE id = v),
                                  (SELECT deposits FROM public.exos_rental_invoice_templates WHERE id = v));
  ASSERT r = '{"subtotal_cents":69500,"discount_cents":5000,"taxable_cents":64500,"tax_cents":5724,"total_cents":70224,"deposits_cents":45112}'::jsonb,
    'TI4: totals ' || r::text;
  -- The discount never goes below zero.
  ASSERT (public._exos_rental_totals('[{"quantity":1,"cost_type":"fixed","cost_cents":100}]', NULL, 900, '[]') ->> 'total_cents')::int = 0,
    'TI4: discount capped at the subtotal';

  -- An invoice from the template for the held night.
  r := public.exos_rental_invoice_create('d7000000-0000-0000-0000-000000000001',
         jsonb_build_object('template_id', v, 'hold_position_id', (SELECT d7.v FROM d7 WHERE k = 'night'),
                            'bill_to_name', 'Party Host', 'bill_to_email', ' Host@Example.com '));
  INSERT INTO d7 VALUES ('inv1', (r ->> 'id')::uuid);
  ASSERT r ->> 'status' = 'draft' AND r ->> 'number' IS NULL AND (r ->> 'total_cents')::int = 70224
     AND r ->> 'rental_date' = '2026-12-12' AND r ->> 'venue_id' = 'd7000000-0000-0000-0000-0000000000c1'
     AND r ->> 'room_id' = 'd7000000-0000-0000-0000-0000000000c3' AND r ->> 'hold_id' = (SELECT d7.v::text FROM d7 WHERE k = 'hold')
     AND r ->> 'bill_to_email' = 'host@example.com' AND r ->> 'title' = 'Back room rental' AND r ->> 'terms' = '<p>Net 30.</p>',
    'TI4: a draft copying the template, the night''s venue, room and date';
  -- Editing the template later doesn't change the invoice.
  UPDATE public.exos_rental_invoice_templates SET items = '[{"title":"Room hire","cost_cents":1}]' WHERE id = v;
  ASSERT (SELECT total_cents FROM public.exos_rental_invoices WHERE id = (r ->> 'id')::uuid) = 70224, 'TI4: lines are copied';
  -- Draft edits recompute; totals can't be written.
  r := public.exos_rental_invoice_update((r ->> 'id')::uuid, '{"attendance_count":100}');
  ASSERT (r ->> 'subtotal_cents')::int = 72500, 'TI4: draft edit recomputes';
  BEGIN
    PERFORM public.exos_rental_invoice_update((r ->> 'id')::uuid, '{"total_cents":1}');
    RAISE EXCEPTION 'TI4: totals were writable';
  EXCEPTION WHEN SQLSTATE '22023' THEN NULL;
  END;

  -- Numbering: an empty draft can't be issued and burns no number.
  r := public.exos_rental_invoice_create('d7000000-0000-0000-0000-000000000001', '{"title":"Empty"}');
  INSERT INTO d7 VALUES ('empty', (r ->> 'id')::uuid);
  BEGIN
    PERFORM public.exos_rental_invoice_issue((r ->> 'id')::uuid);
    RAISE EXCEPTION 'TI4: an empty invoice was issued';
  EXCEPTION WHEN SQLSTATE '22023' THEN NULL;
  END;
  r := public.exos_rental_invoice_issue((SELECT d7.v FROM d7 WHERE k = 'inv1'), '2026-12-31');
  ASSERT r ->> 'number' = 'R-00001' AND r ->> 'status' = 'issued' AND r ->> 'due_on' = '2026-12-31', 'TI4: first number R-00001';
  r := public.exos_rental_invoice_issue((SELECT d7.v FROM d7 WHERE k = 'inv1'));
  ASSERT r ->> 'number' = 'R-00001' AND (r ->> 'already_issued')::boolean, 'TI4: issuing again is a no-op';
  -- Frozen once issued; never deleted.
  BEGIN
    PERFORM public.exos_rental_invoice_update((SELECT d7.v FROM d7 WHERE k = 'inv1'), '{"discount_cents":0}');
    RAISE EXCEPTION 'TI4: an issued invoice was edited';
  EXCEPTION WHEN SQLSTATE '55000' THEN NULL;
  END;
  BEGIN
    PERFORM public.exos_rental_invoice_delete((SELECT d7.v FROM d7 WHERE k = 'inv1'));
    RAISE EXCEPTION 'TI4: an issued invoice was deleted';
  EXCEPTION WHEN SQLSTATE '55000' THEN NULL;
  END;
  -- Paid and back, void keeps its number.
  r := public.exos_rental_invoice_set_status((SELECT d7.v FROM d7 WHERE k = 'inv1'), 'paid');
  ASSERT r ->> 'status' = 'paid' AND r ->> 'paid_at' IS NOT NULL, 'TI4: paid';
  r := public.exos_rental_invoice_set_status((SELECT d7.v FROM d7 WHERE k = 'inv1'), 'void', 'Event moved');
  ASSERT r ->> 'status' = 'void' AND r ->> 'number' = 'R-00001' AND r ->> 'void_reason' = 'Event moved', 'TI4: void keeps the number';
  BEGIN
    PERFORM public.exos_rental_invoice_set_status((SELECT d7.v FROM d7 WHERE k = 'inv1'), 'issued');
    RAISE EXCEPTION 'TI4: a void invoice came back';
  EXCEPTION WHEN SQLSTATE '55000' THEN NULL;
  END;
  BEGIN
    PERFORM public.exos_rental_invoice_set_status((SELECT d7.v FROM d7 WHERE k = 'empty'), 'paid');
    RAISE EXCEPTION 'TI4: a draft was marked paid';
  EXCEPTION WHEN SQLSTATE '55000' THEN NULL;
  END;
  -- The next invoice gets the next number (the failed issue burned none); a new prefix.
  PERFORM public.exos_rental_invoice_update((SELECT d7.v FROM d7 WHERE k = 'empty'), '{"items":[{"title":"Deposit","cost_cents":100}]}');
  PERFORM public.exos_rental_invoice_prefix_set('d7000000-0000-0000-0000-000000000001', 'D7-2026-');
  r := public.exos_rental_invoice_issue((SELECT d7.v FROM d7 WHERE k = 'empty'));
  ASSERT r ->> 'number' = 'D7-2026-00002' AND (r ->> 'number_seq')::int = 2, 'TI4: gapless, prefix applies to new numbers';
  -- Drafts delete.
  r := public.exos_rental_invoice_create('d7000000-0000-0000-0000-000000000001', '{"title":"Scratch"}');
  PERFORM public.exos_rental_invoice_delete((r ->> 'id')::uuid);
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_rental_invoices WHERE id = (r ->> 'id')::uuid), 'TI4: a draft deletes';
  -- Links stay in the org.
  BEGIN
    PERFORM public.exos_rental_invoice_create('d7000000-0000-0000-0000-000000000001',
              '{"title":"x","venue_id":"d7000000-0000-0000-0000-0000000000c2"}');
    RAISE EXCEPTION 'TI4: another org''s venue was linked';
  EXCEPTION WHEN SQLSTATE '22023' THEN NULL;
  END;

  -- Finance issues and reads; content can't.
  PERFORM pg_temp.as_user('d7000000-0000-0000-0000-0000000000a2');
  ASSERT (SELECT count(*) FROM public.exos_rental_invoices WHERE org_id = 'd7000000-0000-0000-0000-000000000001') = 2, 'TI4: finance reads';
  r := public.exos_rental_invoice_create('d7000000-0000-0000-0000-000000000001', '{"title":"Finance","items":[{"title":"Fee","cost_cents":500}]}');
  r := public.exos_rental_invoice_issue((r ->> 'id')::uuid);
  ASSERT r ->> 'number' = 'D7-2026-00003', 'TI4: finance issues; sequence continues';
  BEGIN
    INSERT INTO public.exos_rental_invoice_templates (org_id, title) VALUES ('d7000000-0000-0000-0000-000000000001', 'Nope');
    RAISE EXCEPTION 'TI4: finance wrote a rental template';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  PERFORM pg_temp.as_user('d7000000-0000-0000-0000-0000000000a4');
  ASSERT (SELECT count(*) FROM public.exos_rental_invoices) = 0 AND (SELECT count(*) FROM public.exos_rental_invoice_templates) = 0,
    'TI4: content sees no rental money';
  BEGIN
    PERFORM public.exos_rental_invoice_create('d7000000-0000-0000-0000-000000000001', '{"title":"x"}');
    RAISE EXCEPTION 'TI4: content made an invoice';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  RAISE NOTICE 'OK  TI4 rental templates and invoices';
END $$;
RESET ROLE;
-- Directly, even the service role can't renumber or unfreeze.
DO $$
BEGIN
  BEGIN
    UPDATE public.exos_rental_invoices SET number = 'R-99999' WHERE id = (SELECT d7.v FROM d7 WHERE k = 'inv1');
    RAISE EXCEPTION 'TI4: a number was rewritten';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  BEGIN
    DELETE FROM public.exos_rental_invoices WHERE id = (SELECT d7.v FROM d7 WHERE k = 'inv1');
    RAISE EXCEPTION 'TI4: an issued invoice was deleted directly';
  EXCEPTION WHEN SQLSTATE '55000' THEN NULL;
  END;
  -- Numbers per org: the other org starts at 1.
  PERFORM public._exos_rental_invoice_issue('d7000000-0000-0000-0000-000000000002',
            (public._exos_rental_invoice_create('d7000000-0000-0000-0000-000000000002', NULL, 'api',
               '{"title":"Other","items":[{"title":"x","cost_cents":1}]}') ->> 'id')::uuid);
  ASSERT (SELECT array_agg(number) FROM public.exos_rental_invoices WHERE org_id = 'd7000000-0000-0000-0000-000000000002') = ARRAY['R-00001'],
    'TI4: each org numbers on its own';
  ASSERT (SELECT array_agg(number_seq ORDER BY number_seq) FROM public.exos_rental_invoices
           WHERE org_id = 'd7000000-0000-0000-0000-000000000001' AND number_seq IS NOT NULL) = ARRAY[1, 2, 3],
    'TI4: 1, 2, 3 with no gap';
  RAISE NOTICE 'OK  TI4 numbering is fixed once given';
END $$;

-- TI5 -------------------------------------------------------------------------
SET ROLE anon;
DO $$
BEGIN
  ASSERT public.exos_inbound_form_public('d7-org') IS NULL, 'TI5: the form is off by default';
  BEGIN
    PERFORM public.exos_inbound_submit('d7-org', '{"artist_name":"Band","email":"a@b.co"}');
    RAISE EXCEPTION 'TI5: a submission reached an org with the form off';
  EXCEPTION WHEN SQLSTATE 'P0002' THEN NULL;
  END;
  RAISE NOTICE 'OK  TI5 off by default';
END $$;
RESET ROLE;
SET ROLE authenticated;
DO $$
BEGIN
  PERFORM pg_temp.as_user('d7000000-0000-0000-0000-0000000000a4');  -- content can't turn it on
  BEGIN
    INSERT INTO public.exos_inbound_settings (org_id, enabled) VALUES ('d7000000-0000-0000-0000-000000000001', true);
    RAISE EXCEPTION 'TI5: content turned the form on';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  PERFORM pg_temp.as_user('d7000000-0000-0000-0000-0000000000a1');
  INSERT INTO public.exos_inbound_settings (org_id, enabled, intro, venue_ids)
  VALUES ('d7000000-0000-0000-0000-000000000001', true, 'Tell us about your act.', ARRAY['d7000000-0000-0000-0000-0000000000c1'::uuid]);
  BEGIN
    UPDATE public.exos_inbound_settings SET venue_ids = ARRAY['d7000000-0000-0000-0000-0000000000c2'::uuid]
     WHERE org_id = 'd7000000-0000-0000-0000-000000000001';
    RAISE EXCEPTION 'TI5: another org''s venue on the form';
  EXCEPTION WHEN SQLSTATE '22023' THEN NULL;
  END;
END $$;
RESET ROLE;
SET ROLE anon;
DO $$
DECLARE f jsonb; i int;
BEGIN
  f := public.exos_inbound_form_public('d7-org');
  ASSERT f ->> 'org_name' = 'D7 Org' AND f ->> 'intro' = 'Tell us about your act.'
     AND f -> 'venues' = '[{"id":"d7000000-0000-0000-0000-0000000000c1","name":"D7 Hall"}]'::jsonb
     AND NOT f ? 'org_id', 'TI5: public text and venues only';
  -- The client wrote the first X-Forwarded-For entry; the proxy appended the last.
  PERFORM set_config('request.headers', '{"x-forwarded-for":"1.2.3.4, 203.0.113.7","user-agent":"t"}', true);
  ASSERT public.exos_inbound_submit('d7-org', '{"artist_name":"The Ramblers","contact_name":"Jo","contact_role":"agent","email":"Jo@Agency.example","message":"Touring in March.","links":{"spotify":"https://open.spotify.com/artist/1"},"genres":["folk"],"venue_id":"d7000000-0000-0000-0000-0000000000c1","preferred_dates":["2027-03-05","2027-03-06"],"expected_draw":200}')
         = '{"ok":true}'::jsonb, 'TI5: accepted';
  -- Honeypot: answered the same, stored nothing.
  ASSERT public.exos_inbound_submit('d7-org', '{"artist_name":"Spam","email":"s@spam.example","homepage":"http://x"}') = '{"ok":true}'::jsonb,
    'TI5: honeypot answers ok';
  -- Bad input.
  BEGIN
    PERFORM public.exos_inbound_submit('d7-org', '{"artist_name":"X","email":"x@y.co","links":{"spotify":"javascript:alert(1)"}}');
    RAISE EXCEPTION 'TI5: a non-https link was accepted';
  EXCEPTION WHEN SQLSTATE '22023' THEN NULL;
  END;
  BEGIN
    PERFORM public.exos_inbound_submit('d7-org', '{"artist_name":"X"}');
    RAISE EXCEPTION 'TI5: a form submission without an email was accepted';
  EXCEPTION WHEN SQLSTATE '22023' THEN NULL;
  END;
  BEGIN
    PERFORM public.exos_inbound_submit('d7-org', jsonb_build_object('artist_name', 'X', 'email', 'x@y.co', 'message', repeat('a', 17000)));
    RAISE EXCEPTION 'TI5: an oversized body was accepted';
  EXCEPTION WHEN SQLSTATE '22023' THEN NULL;
  END;
  BEGIN
    PERFORM public.exos_inbound_submit('d7-org', '{"artist_name":"X","email":"x@y.co","status":"accepted"}');
    RAISE EXCEPTION 'TI5: a server field was accepted';
  EXCEPTION WHEN SQLSTATE '22023' THEN NULL;
  END;
  -- Per email: 3 a day per org.
  PERFORM public.exos_inbound_submit('d7-org', '{"artist_name":"Two","email":"jo@agency.example"}');
  PERFORM public.exos_inbound_submit('d7-org', '{"artist_name":"Three","email":"jo@agency.example"}');
  BEGIN
    PERFORM public.exos_inbound_submit('d7-org', '{"artist_name":"Four","email":"jo@agency.example"}');
    RAISE EXCEPTION 'TI5: a 4th request from one email today';
  EXCEPTION WHEN SQLSTATE '54000' THEN NULL;
  END;
  -- Per network: 5 an hour per org (3 so far from this network). Rotating
  -- the spoofable first X-Forwarded-For entry doesn't reset it.
  PERFORM set_config('request.headers', '{"x-forwarded-for":"9.9.9.1, 203.0.113.7"}', true);
  PERFORM public.exos_inbound_submit('d7-org', '{"artist_name":"A","email":"a1@x.example"}');
  PERFORM set_config('request.headers', '{"x-forwarded-for":"9.9.9.2, 203.0.113.7"}', true);
  PERFORM public.exos_inbound_submit('d7-org', '{"artist_name":"B","email":"a2@x.example"}');
  PERFORM set_config('request.headers', '{"x-forwarded-for":"9.9.9.3, 8.8.8.8, 203.0.113.7"}', true);
  BEGIN
    PERFORM public.exos_inbound_submit('d7-org', '{"artist_name":"C","email":"a3@x.example"}');
    RAISE EXCEPTION 'TI5: a spoofed first X-Forwarded-For entry reset the network limit';
  EXCEPTION WHEN SQLSTATE '54000' THEN NULL;
  END;
  -- cf-connecting-ip wins over X-Forwarded-For: another network gets through.
  PERFORM set_config('request.headers', '{"cf-connecting-ip":"198.51.100.9","x-forwarded-for":"203.0.113.7"}', true);
  ASSERT public.exos_inbound_submit('d7-org', '{"artist_name":"Other net","email":"o@x.example"}') = '{"ok":true}'::jsonb,
    'TI5: limits are per network (cf-connecting-ip first)';
  -- No trusted IP (no headers, or junk): one shared bucket with the same caps.
  PERFORM set_config('request.headers', '{}', true);
  PERFORM public.exos_inbound_submit('d7-org', '{"artist_name":"U1","email":"u1@x.example"}');
  PERFORM public.exos_inbound_submit('d7-org', '{"artist_name":"U2","email":"u2@x.example"}');
  PERFORM set_config('request.headers', '', true);
  PERFORM public.exos_inbound_submit('d7-org', '{"artist_name":"U3","email":"u3@x.example"}');
  PERFORM set_config('request.headers', '{"x-forwarded-for":"not-an-ip"}', true);
  PERFORM public.exos_inbound_submit('d7-org', '{"artist_name":"U4","email":"u4@x.example"}');
  PERFORM set_config('request.headers', '{"cf-connecting-ip":"","x-forwarded-for":""}', true);
  PERFORM public.exos_inbound_submit('d7-org', '{"artist_name":"U5","email":"u5@x.example"}');
  BEGIN
    PERFORM set_config('request.headers', '{}', true);
    PERFORM public.exos_inbound_submit('d7-org', '{"artist_name":"U6","email":"u6@x.example"}');
    RAISE EXCEPTION 'TI5: requests without a trusted IP skipped the network limit';
  EXCEPTION WHEN SQLSTATE '54000' THEN NULL;
  END;
  RAISE NOTICE 'OK  TI5 public form: honeypot, cap, validation, limits';
END $$;
RESET ROLE;
DO $$
BEGIN
  ASSERT (SELECT count(*) FROM public.exos_inbound_submissions WHERE org_id = 'd7000000-0000-0000-0000-000000000001') = 11,
    'TI5: eleven stored (no honeypot, none over the limits)';
  ASSERT (SELECT count(*) FROM public.exos_inbound_submissions
           WHERE ip_hash = encode(sha256(convert_to('exos-inbound:unknown', 'UTF8')), 'hex')) = 5,
    'TI5: header-less requests share the unknown bucket';
  -- The helper: cf-connecting-ip, else the LAST X-Forwarded-For entry, valid addresses only.
  PERFORM set_config('request.headers', '{"x-forwarded-for":"1.2.3.4, 203.0.113.7 "}', true);
  ASSERT public._exos_request_ip() = '203.0.113.7', 'TI5: last XFF entry';
  PERFORM set_config('request.headers', '{"cf-connecting-ip":"2001:db8::1","x-forwarded-for":"203.0.113.7"}', true);
  ASSERT public._exos_request_ip() = '2001:db8::1', 'TI5: cf-connecting-ip first';
  PERFORM set_config('request.headers', '{"x-forwarded-for":"203.0.113.7, garbage"}', true);
  ASSERT public._exos_request_ip() IS NULL, 'TI5: junk is no IP';
  -- IPv6: one /64 is one bucket (a client can rotate inside it); IPv4 stays whole.
  PERFORM set_config('request.headers', '{"cf-connecting-ip":"2001:db8:1:2::1"}', true);
  ASSERT public._exos_request_ip_bucket() = '2001:db8:1:2::/64', 'TI5: IPv6 bucket is the /64';
  PERFORM set_config('request.headers', '{"cf-connecting-ip":"2001:db8:1:2:ffff:ee:dd:cc"}', true);
  ASSERT public._exos_request_ip_bucket() = '2001:db8:1:2::/64', 'TI5: two addresses in one /64 share a bucket';
  PERFORM set_config('request.headers', '{"cf-connecting-ip":"2001:db8:1:3::1"}', true);
  ASSERT public._exos_request_ip_bucket() = '2001:db8:1:3::/64', 'TI5: another /64 is another bucket';
  PERFORM set_config('request.headers', '{"cf-connecting-ip":"203.0.113.7"}', true);
  ASSERT public._exos_request_ip_bucket() = '203.0.113.7', 'TI5: IPv4 stays whole';
  PERFORM set_config('request.headers', '{}', true);
  ASSERT public._exos_request_ip_bucket() = 'unknown', 'TI5: no IP, the shared bucket';
  ASSERT public._exos_request_ip_source() = 'cloudflare', 'TI5: cloudflare by default';
  -- Self-hosted without Cloudflare: xff_last ignores a client-sent cf-connecting-ip.
  INSERT INTO public.exos_platform_settings (key, value) VALUES ('request_ip_source', '"xff_last"')
  ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value;
  PERFORM set_config('request.headers', '{"cf-connecting-ip":"198.51.100.200","x-forwarded-for":"1.2.3.4, 203.0.113.7"}', true);
  ASSERT public._exos_request_ip() = '203.0.113.7', 'TI5: xff_last ignores cf-connecting-ip';
  PERFORM set_config('request.headers', '{"cf-connecting-ip":"198.51.100.200"}', true);
  ASSERT public._exos_request_ip() IS NULL AND public._exos_request_ip_bucket() = 'unknown',
    'TI5: xff_last with only cf-connecting-ip is the shared bucket';
  UPDATE public.exos_platform_settings SET value = '"bogus"' WHERE key = 'request_ip_source';
  ASSERT public._exos_request_ip_source() = 'cloudflare', 'TI5: an unknown value falls back to cloudflare';
  DELETE FROM public.exos_platform_settings WHERE key = 'request_ip_source';
  ASSERT NOT has_function_privilege('anon', 'public._exos_request_ip_bucket()', 'EXECUTE')
     AND NOT has_function_privilege('anon', 'public._exos_request_ip_source()', 'EXECUTE'), 'TI5: helpers have no grants';
  ASSERT NOT has_function_privilege('anon', 'public._exos_request_ip()', 'EXECUTE')
     AND NOT has_function_privilege('authenticated', 'public._exos_request_ip()', 'EXECUTE'), 'TI5: helper has no grants';
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_inbound_submissions WHERE artist_name = 'Spam'), 'TI5: honeypot stored nothing';
  ASSERT (SELECT ip_hash = encode(sha256(convert_to('exos-inbound:203.0.113.7', 'UTF8')), 'hex') AND email = 'jo@agency.example'
                 AND status = 'new' AND source = 'form' AND preferred_dates = ARRAY['2027-03-05', '2027-03-06']::date[]
                 AND links ->> 'spotify' = 'https://open.spotify.com/artist/1'
            FROM public.exos_inbound_submissions WHERE artist_name = 'The Ramblers'), 'TI5: stored with the hash, not the IP';
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_inbound_submissions WHERE ip_hash LIKE '%203.0.113%'), 'TI5: no raw IP';
  INSERT INTO d7 SELECT 'sub', id FROM public.exos_inbound_submissions WHERE artist_name = 'The Ramblers';
END $$;

SET ROLE authenticated;
DO $$
DECLARE r jsonb;
BEGIN
  PERFORM pg_temp.as_user('d7000000-0000-0000-0000-0000000000a4');  -- content reviews
  ASSERT (SELECT count(*) FROM public.exos_inbound_submissions) = 11, 'TI5: content lists them';
  r := public.exos_inbound_set_status((SELECT d7.v FROM d7 WHERE k = 'sub'), 'reviewing', 'Check March avails');
  ASSERT r ->> 'status' = 'reviewing' AND r ->> 'reviewed_by' = 'd7000000-0000-0000-0000-0000000000a4' AND NOT r ? 'ip_hash',
    'TI5: content reviews';
  BEGIN
    PERFORM public.exos_inbound_create_hold((SELECT d7.v FROM d7 WHERE k = 'sub'), '{}');
    RAISE EXCEPTION 'TI5: content made a hold';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  DELETE FROM public.exos_inbound_submissions WHERE id = (SELECT d7.v FROM d7 WHERE k = 'sub');
  ASSERT EXISTS (SELECT 1 FROM public.exos_inbound_submissions WHERE id = (SELECT d7.v FROM d7 WHERE k = 'sub')), 'TI5: content can''t delete';
  PERFORM pg_temp.as_user('d7000000-0000-0000-0000-0000000000a2');  -- finance: nothing
  ASSERT (SELECT count(*) FROM public.exos_inbound_submissions) = 0, 'TI5: finance sees none';
  PERFORM pg_temp.as_user('d7000000-0000-0000-0000-0000000000a1');  -- manager: hold
  r := public.exos_inbound_create_hold((SELECT d7.v FROM d7 WHERE k = 'sub'),
         '{"positions":[{"date":"2027-03-05","venue_id":"d7000000-0000-0000-0000-0000000000c1"}]}');
  ASSERT r -> 'hold' ->> 'title' = 'The Ramblers' AND r -> 'hold' ->> 'notes' = 'Touring in March.', 'TI5: a hold from it';
  ASSERT (SELECT status = 'accepted' AND hold_id = (r -> 'hold' ->> 'id')::uuid FROM public.exos_inbound_submissions
           WHERE id = (SELECT d7.v FROM d7 WHERE k = 'sub')), 'TI5: accepted and linked';
  BEGIN
    PERFORM public.exos_inbound_create_hold((SELECT d7.v FROM d7 WHERE k = 'sub'),
              '{"positions":[{"date":"2027-03-06","venue_id":"d7000000-0000-0000-0000-0000000000c1"}]}');
    RAISE EXCEPTION 'TI5: a second hold from one submission';
  EXCEPTION WHEN SQLSTATE '55000' THEN NULL;
  END;
  BEGIN
    PERFORM public.exos_inbound_set_status((SELECT d7.v FROM d7 WHERE k = 'sub'), 'spam');
    RAISE EXCEPTION 'TI5: a bad status was accepted';
  EXCEPTION WHEN SQLSTATE '22023' THEN NULL;
  END;
  DELETE FROM public.exos_inbound_submissions WHERE artist_name = 'Other net';
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_inbound_submissions WHERE artist_name = 'Other net'), 'TI5: managers delete';
  RAISE NOTICE 'OK  TI5 staff review, hold, delete';
END $$;
RESET ROLE;

-- TI6 -------------------------------------------------------------------------
DO $$
DECLARE v_pub uuid; v_sold uuid; v_draft uuid;
BEGIN
  INSERT INTO public.exos_events (org_id, name, status) VALUES ('d7000000-0000-0000-0000-000000000001', 'Pub', 'published') RETURNING id INTO v_pub;
  INSERT INTO public.exos_events (org_id, name, status) VALUES ('d7000000-0000-0000-0000-000000000001', 'Sold', 'draft') RETURNING id INTO v_sold;
  INSERT INTO public.exos_tickets (event_id, org_id, buyer_id, owner_id, barcode_secret)
  VALUES (v_sold, 'd7000000-0000-0000-0000-000000000001', 'd7000000-0000-0000-0000-0000000000a0', 'd7000000-0000-0000-0000-0000000000a0', 'ti6');
  v_draft := (SELECT d7.v FROM d7 WHERE k = 'ev1');
  INSERT INTO d7 VALUES ('pub', v_pub), ('sold', v_sold);
  BEGIN
    PERFORM public._exos_event_delete('d7000000-0000-0000-0000-000000000001', v_pub);
    RAISE EXCEPTION 'TI6: a published event was deleted';
  EXCEPTION WHEN SQLSTATE '55000' THEN NULL;
  END;
  BEGIN
    PERFORM public._exos_event_delete('d7000000-0000-0000-0000-000000000001', v_sold);
    RAISE EXCEPTION 'TI6: an event with tickets was deleted';
  EXCEPTION WHEN SQLSTATE '55000' THEN
    ASSERT SQLERRM LIKE '%cancel it instead%', 'TI6: the message says cancel';
  END;
  BEGIN
    PERFORM public._exos_event_delete('d7000000-0000-0000-0000-000000000002', v_draft);
    RAISE EXCEPTION 'TI6: another org deleted the event';
  EXCEPTION WHEN SQLSTATE 'P0002' THEN NULL;
  END;
  ASSERT public._exos_event_delete('d7000000-0000-0000-0000-000000000001', v_draft) ->> 'deleted' = 'true', 'TI6: a draft deletes';
  -- (Tiers cascade in prod; the harness's stub tier table has no FK.)
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_events WHERE id = v_draft)
     AND NOT EXISTS (SELECT 1 FROM public.exos_fee_rules WHERE event_id = v_draft), 'TI6: with its fee rules';
  RAISE NOTICE 'OK  TI6 delete only drafts that never sold';
END $$;
SET ROLE authenticated;
DO $$
BEGIN
  PERFORM pg_temp.as_user('d7000000-0000-0000-0000-0000000000a4');
  BEGIN
    PERFORM public.exos_event_delete((SELECT d7.v FROM d7 WHERE k = 'sold'));
    RAISE EXCEPTION 'TI6: content deleted an event';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  RAISE NOTICE 'OK  TI6 wrapper is owner / manager only';
END $$;
RESET ROLE;

-- TI7 -------------------------------------------------------------------------
DO $$
DECLARE o2 uuid := 'd7000000-0000-0000-0000-000000000002';
BEGIN
  BEGIN
    PERFORM public._exos_event_from_template(o2, NULL, (SELECT d7.v FROM d7 WHERE k = 'etpl'), '{}');
    RAISE EXCEPTION 'TI7: another org used the template';
  EXCEPTION WHEN SQLSTATE 'P0002' THEN NULL;
  END;
  BEGIN
    PERFORM public._exos_event_template_from_event(o2, NULL, (SELECT d7.v FROM d7 WHERE k = 'sold'), 'x');
    RAISE EXCEPTION 'TI7: another org snapshotted the event';
  EXCEPTION WHEN SQLSTATE 'P0002' THEN NULL;
  END;
  BEGIN
    PERFORM public._exos_rental_invoice_create(o2, NULL, 'api', jsonb_build_object('template_id', (SELECT d7.v FROM d7 WHERE k = 'rtpl')));
    RAISE EXCEPTION 'TI7: another org used the rental template';
  EXCEPTION WHEN SQLSTATE 'P0002' THEN NULL;
  END;
  BEGIN
    PERFORM public._exos_rental_invoice_create(o2, NULL, 'api', jsonb_build_object('title', 'x', 'hold_id', (SELECT d7.v FROM d7 WHERE k = 'hold')));
    RAISE EXCEPTION 'TI7: another org billed the hold';
  EXCEPTION WHEN SQLSTATE '22023' THEN NULL;
  END;
  BEGIN
    PERFORM public._exos_rental_invoice_set_status(o2, (SELECT d7.v FROM d7 WHERE k = 'inv1'), 'paid');
    RAISE EXCEPTION 'TI7: another org touched the invoice';
  EXCEPTION WHEN SQLSTATE 'P0002' THEN NULL;
  END;
  BEGIN
    PERFORM public._exos_inbound_set_status(o2, NULL, (SELECT d7.v FROM d7 WHERE k = 'sub'), 'declined');
    RAISE EXCEPTION 'TI7: another org reviewed the submission';
  EXCEPTION WHEN SQLSTATE 'P0002' THEN NULL;
  END;
  BEGIN
    PERFORM public._exos_inbound_hold(o2, NULL, 'api', NULL, (SELECT d7.v FROM d7 WHERE k = 'sub'), '{}');
    RAISE EXCEPTION 'TI7: another org made a hold from the submission';
  EXCEPTION WHEN SQLSTATE 'P0002' THEN NULL;
  END;
  BEGIN
    PERFORM public._exos_inbound_create(o2, 'api', '{"artist_name":"x","venue_id":"d7000000-0000-0000-0000-0000000000c1"}', NULL, NULL);
    RAISE EXCEPTION 'TI7: a submission to another org''s venue';
  EXCEPTION WHEN SQLSTATE '22023' THEN NULL;
  END;
  RAISE NOTICE 'OK  TI7 cross-org isolation';
END $$;
SET ROLE authenticated;
DO $$
BEGIN
  PERFORM pg_temp.as_user('d7000000-0000-0000-0000-0000000000b9');  -- the other org's owner
  ASSERT (SELECT count(*) FROM public.exos_event_templates) = 0 AND (SELECT count(*) FROM public.exos_note_templates) = 0
     AND (SELECT count(*) FROM public.exos_inbound_submissions) = 0
     AND (SELECT count(*) FROM public.exos_rental_invoices) = 1, 'TI7: RLS shows only the own org''s rows';
  BEGIN
    PERFORM public.exos_rental_invoice_issue((SELECT d7.v FROM d7 WHERE k = 'inv1'));
    RAISE EXCEPTION 'TI7: another org''s owner issued the invoice';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  BEGIN
    PERFORM public.exos_event_from_template((SELECT d7.v FROM d7 WHERE k = 'etpl'), '{}');
    RAISE EXCEPTION 'TI7: another org''s owner used the template';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  RAISE NOTICE 'OK  TI7 RLS and wrappers';
END $$;
RESET ROLE;

ROLLBACK;
