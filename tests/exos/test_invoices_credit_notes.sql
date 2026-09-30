-- ============================================================================
-- Invoices, receipts and credit notes (mig 20261001100000). Self-contained
-- (fa prefix), rolled back.
--   I1 objects exist; exos_tg_invoice no longer flips status
--   I2 org legal details: owner / manager / finance write and read; scanner,
--      stranger and anon don't; exos_orgs / exos_public_orgs don't carry them
--   I3 a paid order gets an invoice with the seller snapshot; a free order
--      gets none
--   I4 a partial refund issues CN-000001 with the pro-rata tax; the rest
--      issues CN-000002 with the remaining tax; the invoice is unchanged
--   I5 re-firing a refund, an over-refund and a pending / failed refund
--      issue nothing and waste no number (the next note is CN-000003)
--   I6 invoices and credit notes can't be changed
--   I7 exos_invoice_document: the buyer and org owner / finance read it
--      (lines, tax per rate, credit notes, seller); scanner, stranger,
--      another org, unknown id and anon can't
--   I8 guest checkout: the confirmed account with the order's email reads it;
--      an unconfirmed one doesn't; exos_my_invoices lists the caller's
--   I9 exos_credit_note_document and the credit-note RLS
--   I10 exos_invoice_totals: refunded_cents and the derived status
-- ============================================================================
\set ON_ERROR_STOP on
BEGIN;
INSERT INTO auth.users(id,email,email_confirmed_at) VALUES
  ('fa000000-0000-0000-0000-0000000000a0','fa-owner@x.com',now()),
  ('fa000000-0000-0000-0000-0000000000a1','fa-finance@x.com',now()),
  ('fa000000-0000-0000-0000-0000000000a2','fa-scanner@x.com',now()),
  ('fa000000-0000-0000-0000-0000000000a3','fa-manager@x.com',now()),
  ('fa000000-0000-0000-0000-0000000000b0','fa-buyer@x.com',now()),
  ('fa000000-0000-0000-0000-0000000000b1','fa-guest@x.com',now()),
  ('fa000000-0000-0000-0000-0000000000b2','FA-Guest@x.com',NULL),
  ('fa000000-0000-0000-0000-0000000000c0','fa-stranger@x.com',now()),
  ('fa000000-0000-0000-0000-0000000000c1','fa-other-fin@x.com',now());
INSERT INTO public.exos_orgs(id,name,slug,owner_uid) VALUES
  ('fa000000-0000-0000-0000-000000000001','FA Org','fa-org','fa000000-0000-0000-0000-0000000000a0'),
  ('fa000000-0000-0000-0000-000000000002','FA Other','fa-other','fa000000-0000-0000-0000-0000000000c1');
INSERT INTO public.exos_org_memberships(org_id,user_id,role,disabled) VALUES
  ('fa000000-0000-0000-0000-000000000001','fa000000-0000-0000-0000-0000000000a0','owner',false),
  ('fa000000-0000-0000-0000-000000000001','fa000000-0000-0000-0000-0000000000a1','finance',false),
  ('fa000000-0000-0000-0000-000000000001','fa000000-0000-0000-0000-0000000000a2','scanner',false),
  ('fa000000-0000-0000-0000-000000000001','fa000000-0000-0000-0000-0000000000a3','manager',false),
  ('fa000000-0000-0000-0000-000000000002','fa000000-0000-0000-0000-0000000000c1','finance',false);
INSERT INTO public.exos_events(id,org_id,name,status,starts_at,venue_name,timezone,total_tickets,tickets_sold) VALUES
  ('fa000000-0000-0000-0000-0000000000e1','fa000000-0000-0000-0000-000000000001','FA Show','published',
   now() + interval '10 days','Hall','America/New_York',100,0);
INSERT INTO public.exos_tax_rules(id,event_id,name,rate_percent,price_includes_tax) VALUES
  ('fa000000-0000-0000-0000-0000000000f1','fa000000-0000-0000-0000-0000000000e1','Sales tax 10%',10,true);
INSERT INTO public.exos_ticket_tiers(id,event_id,name,price,capacity,tax_rate_id) VALUES
  ('fa000000-0000-0000-0000-0000000000d1','fa000000-0000-0000-0000-0000000000e1','GA',50,100,'fa000000-0000-0000-0000-0000000000f1');
INSERT INTO public.exos_event_addons(id,event_id,name,price,capacity) VALUES
  ('fa000000-0000-0000-0000-0000000000d2','fa000000-0000-0000-0000-0000000000e1','Poster',10,50);

-- I1 -------------------------------------------------------------------------
DO $$
DECLARE d text := pg_get_functiondef('public.exos_tg_invoice()'::regprocedure);
BEGIN
  ASSERT to_regclass('public.exos_credit_notes') IS NOT NULL, 'I1: exos_credit_notes';
  ASSERT to_regclass('public.exos_credit_note_counters') IS NOT NULL, 'I1: counters';
  ASSERT to_regclass('public.exos_org_legal') IS NOT NULL, 'I1: exos_org_legal';
  ASSERT to_regclass('public.exos_invoice_totals') IS NOT NULL, 'I1: exos_invoice_totals';
  ASSERT to_regprocedure('public.exos_invoice_document(uuid)') IS NOT NULL, 'I1: document RPC';
  ASSERT to_regprocedure('public.exos_credit_note_document(uuid)') IS NOT NULL, 'I1: credit note RPC';
  ASSERT to_regprocedure('public.exos_my_invoices()') IS NOT NULL, 'I1: my invoices RPC';
  ASSERT position('SET status = ''refunded''' in d) = 0, 'I1: exos_tg_invoice still flips status';
  ASSERT (length(d) - length(replace(d, 'no $0 invoices', ''))) / length('no $0 invoices') = 1, 'I1: patched once';
  RAISE NOTICE 'OK  I1 objects exist; the invoice trigger no longer flips status';
END $$;

-- I2 -------------------------------------------------------------------------
SET LOCAL ROLE authenticated;
SELECT set_config('app.uid', 'fa000000-0000-0000-0000-0000000000a1', true);  -- finance writes
INSERT INTO public.exos_org_legal(org_id, legal_name, legal_address, tax_id, invoice_footer)
VALUES ('fa000000-0000-0000-0000-000000000001', '  FA Events LLC ', E'1 Main St\nBrooklyn, NY 11201', 'EIN 12-3456789', 'Thanks!');
SELECT set_config('app.uid', 'fa000000-0000-0000-0000-0000000000a3', true);  -- manager updates
UPDATE public.exos_org_legal SET invoice_footer = 'Thanks for coming.' WHERE org_id = 'fa000000-0000-0000-0000-000000000001';
DO $$
DECLARE n int; ok boolean;
BEGIN
  SELECT count(*) INTO n FROM public.exos_org_legal WHERE invoice_footer = 'Thanks for coming.' AND legal_name = 'FA Events LLC';
  ASSERT n = 1, 'I2: manager reads the trimmed, updated row';
  PERFORM set_config('app.uid', 'fa000000-0000-0000-0000-0000000000a2', true);  -- scanner
  SELECT count(*) INTO n FROM public.exos_org_legal;
  ASSERT n = 0, 'I2: scanner reads legal details';
  UPDATE public.exos_org_legal SET tax_id = 'x' WHERE org_id = 'fa000000-0000-0000-0000-000000000001';
  GET DIAGNOSTICS n = ROW_COUNT;
  ASSERT n = 0, 'I2: scanner updated legal details';
  PERFORM set_config('app.uid', 'fa000000-0000-0000-0000-0000000000c1', true);  -- another org's finance
  SELECT count(*) INTO n FROM public.exos_org_legal;
  ASSERT n = 0, 'I2: another org reads legal details';
  ok := false;
  BEGIN
    INSERT INTO public.exos_org_legal(org_id, legal_name) VALUES ('fa000000-0000-0000-0000-000000000001', 'Hijack');
  EXCEPTION WHEN insufficient_privilege THEN ok := true;
  END;
  ASSERT ok, 'I2: a stranger inserted legal details';
END $$;
RESET ROLE;
DO $$
DECLARE ok boolean;
BEGIN
  ASSERT NOT has_table_privilege('anon', 'public.exos_org_legal', 'SELECT'), 'I2: anon can read exos_org_legal';
  ASSERT NOT has_table_privilege('anon', 'public.exos_credit_notes', 'SELECT'), 'I2: anon can read credit notes';
  ASSERT NOT has_table_privilege('authenticated', 'public.exos_credit_note_counters', 'SELECT'), 'I2: counters readable';
  ASSERT NOT has_table_privilege('authenticated', 'public.exos_credit_notes', 'INSERT'), 'I2: clients can write credit notes';
  ASSERT NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public'
                      AND table_name IN ('exos_orgs', 'exos_public_orgs')
                      AND column_name IN ('legal_name', 'legal_address', 'tax_id', 'invoice_footer')),
         'I2: legal details on exos_orgs / exos_public_orgs';
  ASSERT NOT has_function_privilege('anon', 'public.exos_invoice_document(uuid)', 'EXECUTE'), 'I2: anon runs the document RPC';
  ASSERT NOT has_function_privilege('anon', 'public.exos_my_invoices()', 'EXECUTE'), 'I2: anon runs my invoices';
  ASSERT NOT has_function_privilege('authenticated', 'public._exos_issue_credit_note(uuid)', 'EXECUTE'), 'I2: clients issue notes';
  ASSERT NOT has_function_privilege('authenticated', 'public.exos_next_credit_note_number(uuid)', 'EXECUTE'), 'I2: clients take numbers';
  RAISE NOTICE 'OK  I2 legal details: owner / manager / finance only, never anon or public views';
END $$;

-- I3 -------------------------------------------------------------------------
-- S1: 2 x GA at 50.00 (10.00 tax included) + 1 poster at 10.00 = 110.00.
INSERT INTO public.exos_checkout_sessions(session_id,event_id,tier_id,org_id,buyer_uid,buyer_email,quantity,amount_cents,tax_cents,status)
VALUES ('cs_fa1','fa000000-0000-0000-0000-0000000000e1','fa000000-0000-0000-0000-0000000000d1','fa000000-0000-0000-0000-000000000001',
        'fa000000-0000-0000-0000-0000000000b0','fa-buyer@x.com',2,11000,1000,'pending');
INSERT INTO public.exos_price_disclosures(session_id,event_id,org_id,currency,total_shown_cents)
VALUES ('cs_fa1','fa000000-0000-0000-0000-0000000000e1','fa000000-0000-0000-0000-000000000001','usd',11000);
INSERT INTO public.exos_price_disclosure_lines(session_id,line_no,kind,item_id,item_name,quantity,face_unit_cents,tax_cents,tax_included,fee_cents,unit_all_in_cents,line_total_cents) VALUES
  ('cs_fa1',1,'ticket','fa000000-0000-0000-0000-0000000000d1','GA',2,5000,1000,true,0,5000,10000),
  ('cs_fa1',2,'addon','fa000000-0000-0000-0000-0000000000d2','Poster',1,1000,0,false,0,1000,1000);
UPDATE public.exos_checkout_sessions SET status = 'fulfilled', fulfilled_at = now() WHERE session_id = 'cs_fa1';
-- S2: a free order.
INSERT INTO public.exos_checkout_sessions(session_id,event_id,tier_id,org_id,buyer_uid,buyer_email,quantity,amount_cents,status)
VALUES ('cs_fa2','fa000000-0000-0000-0000-0000000000e1','fa000000-0000-0000-0000-0000000000d1','fa000000-0000-0000-0000-000000000001',
        'fa000000-0000-0000-0000-0000000000b0','fa-buyer@x.com',1,0,'pending');
UPDATE public.exos_checkout_sessions SET status = 'fulfilled', fulfilled_at = now() WHERE session_id = 'cs_fa2';
-- S3: a guest order, 30.00 no tax, no disclosure record (older order shape).
INSERT INTO public.exos_checkout_sessions(session_id,event_id,tier_id,org_id,buyer_uid,buyer_email,guest,quantity,amount_cents,status)
VALUES ('cs_fa3','fa000000-0000-0000-0000-0000000000e1','fa000000-0000-0000-0000-0000000000d1','fa000000-0000-0000-0000-000000000001',
        NULL,'Fa-Guest@x.com',true,1,3000,'pending');
UPDATE public.exos_checkout_sessions SET status = 'fulfilled', fulfilled_at = now() WHERE session_id = 'cs_fa3';
-- A fulfilment replay doesn't take another number.
UPDATE public.exos_checkout_sessions SET status = 'pending' WHERE session_id = 'cs_fa3';
UPDATE public.exos_checkout_sessions SET status = 'fulfilled' WHERE session_id = 'cs_fa3';
DO $$
DECLARE inv public.exos_invoices%ROWTYPE; n int; v_next int;
BEGIN
  SELECT * INTO inv FROM public.exos_invoices WHERE session_id = 'cs_fa1';
  ASSERT inv.number = 'INV-000001' AND inv.total_cents = 11000 AND inv.tax_cents = 1000 AND inv.subtotal_cents = 10000,
         'I3: S1 invoice ' || coalesce(inv.number, 'missing');
  ASSERT inv.seller->>'legal_name' = 'FA Events LLC' AND inv.seller->>'tax_id' = 'EIN 12-3456789'
         AND inv.seller->>'name' = 'FA Org', 'I3: seller snapshot ' || coalesce(inv.seller::text, 'null');
  SELECT count(*) INTO n FROM public.exos_invoices WHERE session_id = 'cs_fa2';
  ASSERT n = 0, 'I3: a free order got an invoice';
  SELECT number INTO inv.number FROM public.exos_invoices WHERE session_id = 'cs_fa3';
  ASSERT inv.number = 'INV-000002', 'I3: guest order invoice ' || coalesce(inv.number, 'missing');
  SELECT next_seq INTO v_next FROM public.exos_invoice_counters WHERE org_id = 'fa000000-0000-0000-0000-000000000001';
  ASSERT v_next = 3, 'I3: a replayed fulfilment used up a number (next ' || v_next || ')';
  RAISE NOTICE 'OK  I3 paid orders get invoices with the seller snapshot; free orders none; replays waste no number';
END $$;

-- I4 -------------------------------------------------------------------------
-- Partial: 33.33 of 110.00 → tax round(1000 * 3333 / 11000) = 303.
INSERT INTO public.exos_order_refunds(id,session_id,org_id,refund_id,amount_cents,status,reason,is_partial)
VALUES ('fa000000-0000-0000-0000-00000000f001','cs_fa1','fa000000-0000-0000-0000-000000000001','re_fa1',3333,'pending','requested_by_customer',true);
UPDATE public.exos_order_refunds SET status = 'succeeded' WHERE id = 'fa000000-0000-0000-0000-00000000f001';
-- The rest (76.67) → the remaining tax, 697.
INSERT INTO public.exos_order_refunds(id,session_id,org_id,refund_id,amount_cents,status,reason)
VALUES ('fa000000-0000-0000-0000-00000000f002','cs_fa1','fa000000-0000-0000-0000-000000000001','re_fa2',7667,'succeeded','event cancelled');
SELECT public.exos_refund_checkout('cs_fa1', 'stripe refund');
DO $$
DECLARE c1 public.exos_credit_notes%ROWTYPE; c2 public.exos_credit_notes%ROWTYPE; inv public.exos_invoices%ROWTYPE;
BEGIN
  SELECT * INTO c1 FROM public.exos_credit_notes WHERE refund_id = 'fa000000-0000-0000-0000-00000000f001';
  SELECT * INTO c2 FROM public.exos_credit_notes WHERE refund_id = 'fa000000-0000-0000-0000-00000000f002';
  SELECT * INTO inv FROM public.exos_invoices WHERE session_id = 'cs_fa1';
  ASSERT c1.number = 'CN-000001' AND c1.amount_cents = 3333 AND c1.tax_cents = 303 AND c1.invoice_id = inv.id
         AND c1.currency = 'usd' AND c1.reason = 'requested_by_customer' AND c1.event_id = inv.event_id,
         format('I4: partial note %s %s %s', c1.number, c1.amount_cents, c1.tax_cents);
  ASSERT c2.number = 'CN-000002' AND c2.amount_cents = 7667 AND c2.tax_cents = 697,
         format('I4: final note %s %s %s', c2.number, c2.amount_cents, c2.tax_cents);
  ASSERT c1.tax_cents + c2.tax_cents = inv.tax_cents, 'I4: notes'' tax doesn''t add up to the invoice''s';
  ASSERT c1.seller->>'legal_name' = 'FA Events LLC', 'I4: note seller snapshot';
  ASSERT inv.status = 'issued' AND inv.total_cents = 11000 AND inv.tax_cents = 1000 AND inv.number = 'INV-000001',
         'I4: the invoice changed: ' || inv.status;
  RAISE NOTICE 'OK  I4 partial + final refund → CN-000001 / CN-000002, pro-rata tax, invoice unchanged';
END $$;

-- I5 -------------------------------------------------------------------------
UPDATE public.exos_order_refunds SET status = 'failed' WHERE id = 'fa000000-0000-0000-0000-00000000f001';
UPDATE public.exos_order_refunds SET status = 'succeeded' WHERE id = 'fa000000-0000-0000-0000-00000000f001';
-- An extra refund beyond the invoice total: nothing left to credit.
INSERT INTO public.exos_order_refunds(session_id,org_id,refund_id,amount_cents,status)
VALUES ('cs_fa1','fa000000-0000-0000-0000-000000000001','re_fa3',500,'succeeded');
-- Pending / failed refunds and one on a free order: nothing.
INSERT INTO public.exos_order_refunds(session_id,org_id,refund_id,amount_cents,status) VALUES
  ('cs_fa3','fa000000-0000-0000-0000-000000000001','re_fa4',1000,'pending'),
  ('cs_fa3','fa000000-0000-0000-0000-000000000001','re_fa5',1000,'failed'),
  ('cs_fa2','fa000000-0000-0000-0000-000000000001','re_fa6',100,'succeeded');
DO $$
DECLARE n int;
BEGIN
  SELECT count(*) INTO n FROM public.exos_credit_notes WHERE org_id = 'fa000000-0000-0000-0000-000000000001';
  ASSERT n = 2, 'I5: extra credit notes: ' || n;
END $$;
-- Next real refund on S3 takes CN-000003 (no gap).
UPDATE public.exos_order_refunds SET status = 'succeeded' WHERE refund_id = 're_fa4';
DO $$
DECLARE c public.exos_credit_notes%ROWTYPE;
BEGIN
  SELECT * INTO c FROM public.exos_credit_notes WHERE session_id = 'cs_fa3';
  ASSERT c.number = 'CN-000003' AND c.amount_cents = 1000 AND c.tax_cents = 0, 'I5: next note ' || coalesce(c.number, 'missing');
  -- The other org's series starts at 1 on its own.
  ASSERT public.exos_next_credit_note_number('fa000000-0000-0000-0000-000000000002') = 'CN-000001', 'I5: per-org series';
  RAISE NOTICE 'OK  I5 re-fired, over-, pending and free-order refunds issue nothing; numbering is gapless';
END $$;

-- I6 -------------------------------------------------------------------------
DO $$
DECLARE ok boolean;
BEGIN
  ok := false;
  BEGIN
    UPDATE public.exos_invoices SET total_cents = 1 WHERE session_id = 'cs_fa1';
  EXCEPTION WHEN object_not_in_prerequisite_state THEN ok := true;
  END;
  ASSERT ok, 'I6: an invoice amount changed';
  ok := false;
  BEGIN
    UPDATE public.exos_credit_notes SET amount_cents = 1 WHERE number = 'CN-000001';
  EXCEPTION WHEN object_not_in_prerequisite_state THEN ok := true;
  END;
  ASSERT ok, 'I6: a credit note changed';
  -- Clearing the email (account deletion) and cancelling still work.
  UPDATE public.exos_invoices SET buyer_email = NULL WHERE session_id = 'cs_fa3';
  RAISE NOTICE 'OK  I6 invoices and credit notes are frozen';
END $$;
UPDATE public.exos_invoices SET buyer_email = 'Fa-Guest@x.com' WHERE session_id = 'cs_fa3';

-- I7 -------------------------------------------------------------------------
CREATE TEMP TABLE fa_ids AS
  SELECT (SELECT id FROM public.exos_invoices WHERE session_id = 'cs_fa1') AS inv1,
         (SELECT id FROM public.exos_invoices WHERE session_id = 'cs_fa3') AS inv3,
         (SELECT id FROM public.exos_credit_notes WHERE number = 'CN-000001'
            AND org_id = 'fa000000-0000-0000-0000-000000000001') AS cn1;
GRANT SELECT ON fa_ids TO anon, authenticated;
SET LOCAL ROLE authenticated;
DO $$
DECLARE v_inv uuid; d jsonb; ok boolean; u text; l jsonb;
BEGIN
  SELECT inv1 INTO v_inv FROM fa_ids;
  -- The buyer.
  PERFORM set_config('app.uid', 'fa000000-0000-0000-0000-0000000000b0', true);
  d := public.exos_invoice_document(v_inv);
  ASSERT d->'invoice'->>'number' = 'INV-000001' AND (d->'invoice'->>'total_cents')::int = 11000
         AND (d->'invoice'->>'tax_cents')::int = 1000 AND d->'invoice'->>'status' = 'issued', 'I7: invoice block ' || (d->'invoice')::text;
  ASSERT d->'seller'->>'legal_name' = 'FA Events LLC' AND d->'seller'->>'legal_address' LIKE '1 Main St%'
         AND d->'seller'->>'invoice_footer' = 'Thanks for coming.', 'I7: seller ' || (d->'seller')::text;
  ASSERT d->'buyer'->>'email' = 'fa-buyer@x.com' AND d->>'viewer' = 'buyer', 'I7: buyer block';
  ASSERT d->'event'->>'name' = 'FA Show' AND d->'event'->>'venue_name' = 'Hall', 'I7: event block';
  ASSERT jsonb_array_length(d->'lines') = 2, 'I7: lines ' || (d->'lines')::text;
  l := d->'lines'->0;
  ASSERT l->>'name' = 'GA' AND (l->>'quantity')::int = 2 AND (l->>'unit_cents')::int = 5000 AND (l->>'total_cents')::int = 10000
         AND (l->>'tax_cents')::int = 1000 AND l->>'tax_name' = 'Sales tax 10%' AND (l->>'tax_rate')::numeric = 10
         AND (l->>'tax_included')::boolean, 'I7: ticket line ' || l::text;
  ASSERT d->'lines'->1->>'kind' = 'addon' AND d->'lines'->1->>'tax_name' IS NULL, 'I7: add-on line';
  ASSERT jsonb_array_length(d->'credit_notes') = 2 AND d->'credit_notes'->0->>'number' = 'CN-000001'
         AND (d->'credit_notes'->1->>'tax_cents')::int = 697, 'I7: credit notes ' || (d->'credit_notes')::text;
  -- Org finance and owner.
  PERFORM set_config('app.uid', 'fa000000-0000-0000-0000-0000000000a1', true);
  d := public.exos_invoice_document(v_inv);
  ASSERT d->>'viewer' = 'org', 'I7: finance';
  PERFORM set_config('app.uid', 'fa000000-0000-0000-0000-0000000000a0', true);
  ASSERT public.exos_invoice_document(v_inv)->'invoice'->>'number' = 'INV-000001', 'I7: owner';
  -- Refused: scanner, a stranger, another org's finance, an unknown id.
  FOREACH u IN ARRAY ARRAY['fa000000-0000-0000-0000-0000000000a2','fa000000-0000-0000-0000-0000000000c0',
                           'fa000000-0000-0000-0000-0000000000c1'] LOOP
    PERFORM set_config('app.uid', u, true);
    ok := false;
    BEGIN
      PERFORM public.exos_invoice_document(v_inv);
    EXCEPTION WHEN insufficient_privilege THEN ok := SQLERRM LIKE '%not found%';
    END;
    ASSERT ok, 'I7: ' || u || ' read the invoice';
  END LOOP;
  PERFORM set_config('app.uid', 'fa000000-0000-0000-0000-0000000000a1', true);
  ok := false;
  BEGIN
    PERFORM public.exos_invoice_document(gen_random_uuid());
  EXCEPTION WHEN insufficient_privilege THEN ok := SQLERRM LIKE '%not found%';
  END;
  ASSERT ok, 'I7: unknown id answers differently';
  -- Signed out (authenticated role, no uid).
  PERFORM set_config('app.uid', '', true);
  ok := false;
  BEGIN
    PERFORM public.exos_invoice_document(v_inv);
  EXCEPTION WHEN insufficient_privilege THEN ok := true;
  END;
  ASSERT ok, 'I7: no uid read the invoice';
END $$;
RESET ROLE;
SET LOCAL ROLE anon;
DO $$
DECLARE ok boolean := false; v_inv uuid;
BEGIN
  SELECT inv1 INTO v_inv FROM fa_ids;
  BEGIN
    PERFORM public.exos_invoice_document(v_inv);
  EXCEPTION WHEN insufficient_privilege THEN ok := true;
  END;
  ASSERT ok, 'I7: anon ran exos_invoice_document';
  RAISE NOTICE 'OK  I7 buyer / owner / finance read the document; scanner, stranger, other org, unknown id, anon don''t';
END $$;
RESET ROLE;

-- I8 -------------------------------------------------------------------------
SET LOCAL ROLE authenticated;
DO $$
DECLARE v_inv uuid; d jsonb; ok boolean; n int; v_num text;
BEGIN
  SELECT inv3 INTO v_inv FROM fa_ids;
  PERFORM set_config('app.uid', 'fa000000-0000-0000-0000-0000000000b1', true);  -- confirmed, same email
  d := public.exos_invoice_document(v_inv);
  ASSERT d->'invoice'->>'number' = 'INV-000002', 'I8: guest reads their invoice';
  -- No disclosure record: the tier line from the order.
  ASSERT jsonb_array_length(d->'lines') = 1 AND d->'lines'->0->>'name' = 'GA'
         AND (d->'lines'->0->>'total_cents')::int = 3000 AND d->'lines'->0->'tax_cents' = 'null'::jsonb,
         'I8: fallback lines ' || (d->'lines')::text;
  SELECT count(*), min(number) INTO n, v_num FROM public.exos_my_invoices();
  ASSERT n = 1 AND v_num = 'INV-000002', 'I8: guest my invoices ' || n;
  PERFORM set_config('app.uid', 'fa000000-0000-0000-0000-0000000000b2', true);  -- unconfirmed, same email
  ok := false;
  BEGIN
    PERFORM public.exos_invoice_document(v_inv);
  EXCEPTION WHEN insufficient_privilege THEN ok := true;
  END;
  ASSERT ok, 'I8: an unconfirmed account read a guest invoice';
  SELECT count(*) INTO n FROM public.exos_my_invoices();
  ASSERT n = 0, 'I8: unconfirmed my invoices';
  PERFORM set_config('app.uid', 'fa000000-0000-0000-0000-0000000000b0', true);  -- the signed-in buyer
  SELECT count(*), min(number) INTO n, v_num FROM public.exos_my_invoices();
  ASSERT n = 1 AND v_num = 'INV-000001', 'I8: buyer my invoices';
  SELECT refunded_cents INTO n FROM public.exos_my_invoices();
  ASSERT n = 11000, 'I8: my invoices refunded_cents';
  RAISE NOTICE 'OK  I8 guest checkout: confirmed email reads it, unconfirmed doesn''t; exos_my_invoices';
END $$;

-- I9 -------------------------------------------------------------------------
DO $$
DECLARE v_cn uuid; d jsonb; ok boolean; n int;
BEGIN
  SELECT cn1 INTO v_cn FROM fa_ids;
  PERFORM set_config('app.uid', 'fa000000-0000-0000-0000-0000000000b0', true);
  d := public.exos_credit_note_document(v_cn);
  ASSERT d->'credit_note'->>'number' = 'CN-000001' AND (d->'credit_note'->>'amount_cents')::int = 3333
         AND (d->'credit_note'->>'tax_cents')::int = 303 AND d->'invoice'->>'number' = 'INV-000001', 'I9: credit note doc';
  SELECT count(*) INTO n FROM public.exos_credit_notes;
  ASSERT n = 2, 'I9: buyer sees their 2 credit notes, got ' || n;
  PERFORM set_config('app.uid', 'fa000000-0000-0000-0000-0000000000a1', true);
  SELECT count(*) INTO n FROM public.exos_credit_notes;
  ASSERT n = 3, 'I9: finance sees the org''s 3 credit notes, got ' || n;
  PERFORM set_config('app.uid', 'fa000000-0000-0000-0000-0000000000c0', true);
  SELECT count(*) INTO n FROM public.exos_credit_notes;
  ASSERT n = 0, 'I9: a stranger sees credit notes';
  ok := false;
  BEGIN
    PERFORM public.exos_credit_note_document(v_cn);
  EXCEPTION WHEN insufficient_privilege THEN ok := true;
  END;
  ASSERT ok, 'I9: a stranger read a credit note';
  RAISE NOTICE 'OK  I9 credit note document and RLS';
END $$;

-- I10 ------------------------------------------------------------------------
DO $$
DECLARE t record;
BEGIN
  PERFORM set_config('app.uid', 'fa000000-0000-0000-0000-0000000000a1', true);
  SELECT * INTO t FROM public.exos_invoice_totals WHERE session_id = 'cs_fa1';
  ASSERT t.refunded_cents = 11000 AND t.refunded_tax_cents = 1000 AND t.net_cents = 0 AND t.credit_notes = 2
         AND t.status = 'refunded', 'I10: S1 totals ' || row_to_json(t)::text;
  SELECT * INTO t FROM public.exos_invoice_totals WHERE session_id = 'cs_fa3';
  ASSERT t.refunded_cents = 1000 AND t.net_cents = 2000 AND t.status = 'partially_refunded', 'I10: S3 totals ' || row_to_json(t)::text;
  PERFORM set_config('app.uid', 'fa000000-0000-0000-0000-0000000000c0', true);
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_invoice_totals), 'I10: a stranger reads invoice totals';
  RAISE NOTICE 'OK  I10 exos_invoice_totals: refunded_cents and derived status';
END $$;
RESET ROLE;
ROLLBACK;
