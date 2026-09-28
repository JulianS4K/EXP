-- ============================================================================
-- Venue POS scaffold (mig 20260929074000):
--   P1 every POS table has RLS, anon has nothing, grants are explicit
--   P2 catalog: owner / manager manage; staff can't; tax rule from another event refused
--   P3 RLS isolation between orgs (items, orders, devices, tabs, functions)
--   P4 staff ring bar / merch (cash, comp); ticket lines and card payments are server-only
--   P5 86 an item: the next sale is refused; back on, it sells; stock runs out
--   P6 tabs: ticket or wristband, one open tab each, can't close with a balance
--   P7 cash drawer: expected vs counted, counts must add up
--   P8 settlement summary numbers (same case as src/lib/pos/settlement.test.ts)
--   P9 settlement records: owner / manager only, one final per event
-- Self-contained (BEGIN / ROLLBACK). Org 8c…01: owner …a1, manager …a2,
-- scanner …a3 (assigned to event …e1 only), finance …a4, ticket holder …a5.
-- Org 8c…02: owner …b9, event …e9. Events …e1 and …e2 in org 8c…01.
-- ============================================================================
\set ON_ERROR_STOP on
BEGIN;

INSERT INTO auth.users(id,email,email_confirmed_at) VALUES
  ('8c000000-0000-0000-0000-0000000000a1','8cown@x.com',now()),
  ('8c000000-0000-0000-0000-0000000000a2','8cmgr@x.com',now()),
  ('8c000000-0000-0000-0000-0000000000a3','8cscan@x.com',now()),
  ('8c000000-0000-0000-0000-0000000000a4','8cfin@x.com',now()),
  ('8c000000-0000-0000-0000-0000000000a5','8chold@x.com',now()),
  ('8c000000-0000-0000-0000-0000000000b9','8cother@x.com',now());
INSERT INTO public.exos_orgs(id,name,slug,owner_uid) VALUES
  ('8c000000-0000-0000-0000-000000000001','POS Org','pos-org-stub','8c000000-0000-0000-0000-0000000000a1'),
  ('8c000000-0000-0000-0000-000000000002','Other POS Org','pos-other-stub','8c000000-0000-0000-0000-0000000000b9');
INSERT INTO public.exos_org_memberships(org_id,user_id,role) VALUES
  ('8c000000-0000-0000-0000-000000000001','8c000000-0000-0000-0000-0000000000a1','owner'),
  ('8c000000-0000-0000-0000-000000000001','8c000000-0000-0000-0000-0000000000a2','manager'),
  ('8c000000-0000-0000-0000-000000000001','8c000000-0000-0000-0000-0000000000a3','scanner'),
  ('8c000000-0000-0000-0000-000000000001','8c000000-0000-0000-0000-0000000000a4','finance'),
  ('8c000000-0000-0000-0000-000000000002','8c000000-0000-0000-0000-0000000000b9','owner');
INSERT INTO public.exos_events(id,org_id,name,slug,status,starts_at,doors_at,total_tickets,created_by) VALUES
  ('8c000000-0000-0000-0000-0000000000e1','8c000000-0000-0000-0000-000000000001','POS Night','pos-night-stub','published',
   now() + interval '1 hour', now() - interval '1 hour', 100, '8c000000-0000-0000-0000-0000000000a1'),
  ('8c000000-0000-0000-0000-0000000000e2','8c000000-0000-0000-0000-000000000001','POS Other Night','pos-night2-stub','published',
   now() + interval '1 day', now() + interval '23 hours', 100, '8c000000-0000-0000-0000-0000000000a1'),
  ('8c000000-0000-0000-0000-0000000000e9','8c000000-0000-0000-0000-000000000002','Elsewhere','pos-else-stub','published',
   now() + interval '1 hour', now() - interval '1 hour', 100, '8c000000-0000-0000-0000-0000000000b9');
-- The scanner works event e1 only (mig 20260929041000).
INSERT INTO public.exos_event_staff(event_id,user_id,org_id) VALUES
  ('8c000000-0000-0000-0000-0000000000e1','8c000000-0000-0000-0000-0000000000a3','8c000000-0000-0000-0000-000000000001');
INSERT INTO public.exos_tax_rules(id,event_id,name,rate_percent,price_includes_tax) VALUES
  ('8c000000-0000-0000-0000-0000000007a1','8c000000-0000-0000-0000-0000000000e1','Bar tax 10%',10,false),
  ('8c000000-0000-0000-0000-0000000007a2','8c000000-0000-0000-0000-0000000000e1','Ticket tax 10% incl',10,true),
  ('8c000000-0000-0000-0000-0000000007a9','8c000000-0000-0000-0000-0000000000e2','Other night tax',5,false);
INSERT INTO public.exos_ticket_tiers(id,event_id,name,price,capacity) VALUES
  ('8c000000-0000-0000-0000-000000000071','8c000000-0000-0000-0000-0000000000e1','GA',20,100);
INSERT INTO public.exos_tickets(id,event_id,org_id,tier_id,buyer_id,owner_id,status,barcode_secret,price_paid,order_ref) VALUES
  ('8c000000-0000-0000-0000-0000000000c1','8c000000-0000-0000-0000-0000000000e1','8c000000-0000-0000-0000-000000000001',
   '8c000000-0000-0000-0000-000000000071','8c000000-0000-0000-0000-0000000000a5','8c000000-0000-0000-0000-0000000000a5',
   'active','pos-sek-1',20,'pos-seed-1');
INSERT INTO public.exos_promoters(id,org_id,code,name) VALUES
  ('8c000000-0000-0000-0000-0000000009a1','8c000000-0000-0000-0000-000000000001','POSPROMO','Pos Promoter');

-- ── P1 ──────────────────────────────────────────────────────────────────────
DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['exos_pos_devices','exos_pos_items','exos_pos_tabs','exos_pos_orders',
                           'exos_pos_order_lines','exos_pos_payments','exos_pos_drawer_sessions','exos_pos_settlements'] LOOP
    ASSERT (SELECT relrowsecurity FROM pg_class WHERE oid = ('public.' || t)::regclass), 'P1: RLS on ' || t;
    ASSERT NOT has_table_privilege('anon', 'public.' || t, 'SELECT'), 'P1: anon cannot read ' || t;
    ASSERT NOT has_table_privilege('authenticated', 'public.' || t, 'TRUNCATE'), 'P1: no truncate on ' || t;
    ASSERT has_table_privilege('service_role', 'public.' || t, 'SELECT'), 'P1: service role reads ' || t;
  END LOOP;
  ASSERT NOT has_table_privilege('authenticated', 'public.exos_pos_orders', 'UPDATE'), 'P1: orders are not client-updatable';
  ASSERT NOT has_table_privilege('authenticated', 'public.exos_pos_payments', 'UPDATE'), 'P1: payments are append-only';
  ASSERT NOT has_table_privilege('authenticated', 'public.exos_pos_tabs', 'INSERT'), 'P1: tabs only through functions';
  ASSERT NOT has_table_privilege('authenticated', 'public.exos_pos_settlements', 'INSERT'), 'P1: settlements only through functions';
  ASSERT NOT has_function_privilege('anon', 'public.exos_pos_settlement_summary(uuid)', 'EXECUTE'), 'P1: anon cannot settle';
  ASSERT NOT has_function_privilege('authenticated', 'public.exos_pos_tg_line()', 'EXECUTE'), 'P1: trigger fns private';
  -- No column anywhere that could hold card data.
  ASSERT NOT EXISTS (SELECT 1 FROM information_schema.columns
                      WHERE table_schema = 'public' AND table_name LIKE 'exos_pos_%'
                        AND column_name ~ '(pan|card_number|cvc|cvv|expiry|exp_month|track)'), 'P1: no card-data columns';
  RAISE NOTICE 'PASS P1 RLS on every POS table, explicit grants, no card-data columns';
END $$;

-- ── P2 catalog ─────────────────────────────────────────────────────────────
SET ROLE authenticated;
SELECT set_config('app.uid', '8c000000-0000-0000-0000-0000000000a1', false);
INSERT INTO public.exos_pos_devices(id,org_id,event_id,name,kind,status,hardware_ref) VALUES
  ('8c000000-0000-0000-0000-000000000de1','8c000000-0000-0000-0000-000000000001','8c000000-0000-0000-0000-0000000000e1',
   'Bar iPad 1','register','active','tmr_TESTREADER1');
INSERT INTO public.exos_pos_items(id,org_id,event_id,category,name,sku,price_cents,tax_rule_id,tier_id,inventory_count) VALUES
  ('8c000000-0000-0000-0000-000000000f01','8c000000-0000-0000-0000-000000000001','8c000000-0000-0000-0000-0000000000e1',
   'bar','Beer','BEER-1',800,'8c000000-0000-0000-0000-0000000007a1',NULL,NULL),
  ('8c000000-0000-0000-0000-000000000f02','8c000000-0000-0000-0000-000000000001','8c000000-0000-0000-0000-0000000000e1',
   'merch','Tour shirt','SHIRT-1',2500,NULL,NULL,2),
  ('8c000000-0000-0000-0000-000000000f03','8c000000-0000-0000-0000-000000000001',NULL,
   'bar','Water','WATER',300,NULL,NULL,NULL),
  ('8c000000-0000-0000-0000-000000000f04','8c000000-0000-0000-0000-000000000001','8c000000-0000-0000-0000-0000000000e1',
   'ticket','GA walk-up','GA-DOOR',2000,'8c000000-0000-0000-0000-0000000007a2','8c000000-0000-0000-0000-000000000071',NULL),
  ('8c000000-0000-0000-0000-000000000f05','8c000000-0000-0000-0000-000000000001','8c000000-0000-0000-0000-0000000000e2',
   'bar','Other-night beer','BEER-2',900,NULL,NULL,NULL);
DO $$
DECLARE raised boolean;
BEGIN
  -- A tax rule of another event is refused.
  raised := false;
  BEGIN
    INSERT INTO public.exos_pos_items(org_id,event_id,category,name,price_cents,tax_rule_id) VALUES
      ('8c000000-0000-0000-0000-000000000001','8c000000-0000-0000-0000-0000000000e1','bar','Wrong tax',500,
       '8c000000-0000-0000-0000-0000000007a9');
  EXCEPTION WHEN invalid_parameter_value THEN raised := true; END;
  ASSERT raised, 'P2: tax rule must belong to the item''s event';
  -- A ticket item needs a tier.
  raised := false;
  BEGIN
    INSERT INTO public.exos_pos_items(org_id,event_id,category,name,price_cents) VALUES
      ('8c000000-0000-0000-0000-000000000001','8c000000-0000-0000-0000-0000000000e1','ticket','No tier',500);
  EXCEPTION WHEN check_violation THEN raised := true; END;
  ASSERT raised, 'P2: ticket items need a tier';
  ASSERT (SELECT org_id FROM public.exos_pos_items WHERE id = '8c000000-0000-0000-0000-000000000f01')
         = '8c000000-0000-0000-0000-000000000001', 'P2: owner sees the catalog';
END $$;
SELECT set_config('app.uid', '8c000000-0000-0000-0000-0000000000a3', false);
DO $$
DECLARE raised boolean := false;
BEGIN
  BEGIN
    INSERT INTO public.exos_pos_items(org_id,event_id,category,name,price_cents) VALUES
      ('8c000000-0000-0000-0000-000000000001','8c000000-0000-0000-0000-0000000000e1','bar','Scanner item',100);
  EXCEPTION WHEN insufficient_privilege THEN raised := true; END;
  ASSERT raised, 'P2: staff cannot add catalog items';
  UPDATE public.exos_pos_items SET price_cents = 1 WHERE id = '8c000000-0000-0000-0000-000000000f01';
  ASSERT NOT FOUND, 'P2: staff cannot change prices';
  -- Scanner (assigned to e1) sees e1 and org-wide items, not e2's.
  ASSERT (SELECT count(*) FROM public.exos_pos_items) = 4, 'P2: scanner sees e1 + org-wide items';
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_pos_items WHERE event_id = '8c000000-0000-0000-0000-0000000000e2'),
         'P2: scanner does not see another event''s items';
  RAISE NOTICE 'PASS P2 catalog: owner manages, staff read only, tax rule / tier checked';
END $$;

-- ── P3 isolation between orgs ─────────────────────────────────────────────
SELECT set_config('app.uid', '8c000000-0000-0000-0000-0000000000b9', false);
INSERT INTO public.exos_pos_items(id,org_id,event_id,category,name,price_cents) VALUES
  ('8c000000-0000-0000-0000-000000000f09','8c000000-0000-0000-0000-000000000002','8c000000-0000-0000-0000-0000000000e9',
   'bar','Their beer',700);
DO $$
DECLARE raised boolean;
BEGIN
  ASSERT (SELECT count(*) FROM public.exos_pos_items) = 1, 'P3: the other org sees only its own item';
  ASSERT (SELECT count(*) FROM public.exos_pos_devices) = 0, 'P3: the other org sees no devices of org 1';
  raised := false;
  BEGIN
    INSERT INTO public.exos_pos_items(org_id,event_id,category,name,price_cents) VALUES
      ('8c000000-0000-0000-0000-000000000001',NULL,'bar','Injected',1);
  EXCEPTION WHEN insufficient_privilege THEN raised := true; END;
  ASSERT raised, 'P3: cannot add items to another org';
  raised := false;
  BEGIN
    -- The event's org wins over the claimed org: then RLS refuses.
    INSERT INTO public.exos_pos_items(org_id,event_id,category,name,price_cents) VALUES
      ('8c000000-0000-0000-0000-000000000002','8c000000-0000-0000-0000-0000000000e1','bar','Cross-org',1);
  EXCEPTION WHEN invalid_parameter_value OR insufficient_privilege THEN raised := true; END;
  ASSERT raised, 'P3: cannot attach an item to another org''s event';
  raised := false;
  BEGIN
    INSERT INTO public.exos_pos_orders(event_id) VALUES ('8c000000-0000-0000-0000-0000000000e1');
  EXCEPTION WHEN insufficient_privilege THEN raised := true; END;
  ASSERT raised, 'P3: cannot ring a sale at another org''s event';
  raised := false;
  BEGIN PERFORM public.exos_pos_set_86('8c000000-0000-0000-0000-000000000f01', true);
  EXCEPTION WHEN insufficient_privilege THEN raised := true; END;
  ASSERT raised, 'P3: cannot 86 another org''s item';
  raised := false;
  BEGIN PERFORM public.exos_pos_open_tab('8c000000-0000-0000-0000-0000000000e1', NULL, 'WB-HACK');
  EXCEPTION WHEN insufficient_privilege THEN raised := true; END;
  ASSERT raised, 'P3: cannot open a tab at another org''s event';
  raised := false;
  BEGIN PERFORM public.exos_pos_settlement_summary('8c000000-0000-0000-0000-0000000000e1');
  EXCEPTION WHEN insufficient_privilege THEN raised := true; END;
  ASSERT raised, 'P3: cannot read another org''s settlement';
END $$;
SELECT set_config('app.uid', '8c000000-0000-0000-0000-0000000000a1', false);
DO $$
BEGIN
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_pos_items WHERE org_id = '8c000000-0000-0000-0000-000000000002'),
         'P3: org 1 does not see org 2''s items';
  RAISE NOTICE 'PASS P3 RLS isolation between orgs (items, devices, orders, 86, tabs, settlement)';
END $$;

-- ── P4 staff ring sales ───────────────────────────────────────────────────
SELECT set_config('app.uid', '8c000000-0000-0000-0000-0000000000a3', false);
INSERT INTO public.exos_pos_drawer_sessions(id,event_id,device_id,open_float_cents) VALUES
  ('8c000000-0000-0000-0000-000000000dd1','8c000000-0000-0000-0000-0000000000e1','8c000000-0000-0000-0000-000000000de1',10000);
-- Order A: 2 beers (800 + 10% tax = 880 each), cash 1760 + 200 tip into the drawer.
INSERT INTO public.exos_pos_orders(id,event_id,device_id) VALUES
  ('8c000000-0000-0000-0000-000000000d0a','8c000000-0000-0000-0000-0000000000e1','8c000000-0000-0000-0000-000000000de1');
INSERT INTO public.exos_pos_order_lines(order_id,item_id,category,name,quantity,unit_price_cents) VALUES
  ('8c000000-0000-0000-0000-000000000d0a','8c000000-0000-0000-0000-000000000f01','bar','x',2,1);
INSERT INTO public.exos_pos_payments(order_id,method,amount_cents,tip_cents,drawer_session_id) VALUES
  ('8c000000-0000-0000-0000-000000000d0a','cash',1760,200,'8c000000-0000-0000-0000-000000000dd1');
-- Order B: 1 shirt 2500 — cash 1000 now (drawer), card 1500 + 300 tip by the server below.
INSERT INTO public.exos_pos_orders(id,event_id) VALUES
  ('8c000000-0000-0000-0000-000000000d0b','8c000000-0000-0000-0000-0000000000e1');
INSERT INTO public.exos_pos_order_lines(order_id,item_id,category,name,quantity,unit_price_cents) VALUES
  ('8c000000-0000-0000-0000-000000000d0b','8c000000-0000-0000-0000-000000000f02','merch','x',1,0);
INSERT INTO public.exos_pos_payments(order_id,method,amount_cents,drawer_session_id) VALUES
  ('8c000000-0000-0000-0000-000000000d0b','cash',1000,'8c000000-0000-0000-0000-000000000dd1');
DO $$
DECLARE raised boolean; o record;
BEGIN
  SELECT * INTO o FROM public.exos_pos_orders WHERE id = '8c000000-0000-0000-0000-000000000d0a';
  ASSERT o.status = 'paid' AND o.payment_method = 'cash' AND o.total_cents = 1760 AND o.tax_cents = 160
         AND o.subtotal_cents = 1600 AND o.tip_cents = 200 AND o.org_id = '8c000000-0000-0000-0000-000000000001',
         'P4: order A paid in cash, server-computed totals, got ' || row_to_json(o)::text;
  ASSERT (SELECT unit_price_cents || '/' || name || '/' || line_total_cents FROM public.exos_pos_order_lines
           WHERE order_id = o.id) = '800/Beer/1760', 'P4: the line snapshots the catalog, not the client';
  SELECT * INTO o FROM public.exos_pos_orders WHERE id = '8c000000-0000-0000-0000-000000000d0b';
  ASSERT o.status = 'open' AND o.total_cents = 2500, 'P4: order B half paid, still open';
  -- Card payments are server-only.
  raised := false;
  BEGIN
    INSERT INTO public.exos_pos_payments(order_id,method,amount_cents) VALUES ('8c000000-0000-0000-0000-000000000d0b','card',1500);
  EXCEPTION WHEN insufficient_privilege THEN raised := true; END;
  ASSERT raised, 'P4: staff cannot record a card payment';
  -- Never more than what's left.
  raised := false;
  BEGIN
    INSERT INTO public.exos_pos_payments(order_id,method,amount_cents) VALUES ('8c000000-0000-0000-0000-000000000d0b','cash',1501);
  EXCEPTION WHEN invalid_parameter_value THEN raised := true; END;
  ASSERT raised, 'P4: overpaying is refused';
  -- Ticket lines go through the mint path (server), not the register.
  raised := false;
  BEGIN
    INSERT INTO public.exos_pos_orders(id,event_id) VALUES ('8c000000-0000-0000-0000-000000000d0f','8c000000-0000-0000-0000-0000000000e1');
    INSERT INTO public.exos_pos_order_lines(order_id,item_id,category,name,quantity,unit_price_cents) VALUES
      ('8c000000-0000-0000-0000-000000000d0f','8c000000-0000-0000-0000-000000000f04','bar','sneaky',1,0);
  EXCEPTION WHEN insufficient_privilege THEN raised := true; END;
  ASSERT raised, 'P4: staff cannot ring a ticket line (category comes from the item)';
  -- The scanner is assigned to e1 only.
  raised := false;
  BEGIN
    INSERT INTO public.exos_pos_orders(event_id) VALUES ('8c000000-0000-0000-0000-0000000000e2');
  EXCEPTION WHEN insufficient_privilege THEN raised := true; END;
  ASSERT raised, 'P4: a scanner rings only at the events they work';
  -- An item of another event is refused.
  raised := false;
  BEGIN
    INSERT INTO public.exos_pos_order_lines(order_id,item_id,category,name,quantity,unit_price_cents) VALUES
      ('8c000000-0000-0000-0000-000000000d0b','8c000000-0000-0000-0000-000000000f05','bar','x',1,0);
  EXCEPTION WHEN invalid_parameter_value THEN raised := true; END;
  ASSERT raised, 'P4: an item of another event is refused';
  RAISE NOTICE 'PASS P4 staff ring bar / merch in cash; card + ticket lines are server-only';
END $$;
RESET ROLE;
-- The server (service role) side: card tender for B, walk-up ticket orders C and D.
INSERT INTO public.exos_pos_payments(order_id,method,amount_cents,tip_cents,terminal_ref) VALUES
  ('8c000000-0000-0000-0000-000000000d0b','card',1500,300,'pi_TEST_B');
-- Order C: 2 GA at 2000, tax 10% included (364 of 4000), promoter, card 4000.
INSERT INTO public.exos_pos_orders(id,event_id) VALUES ('8c000000-0000-0000-0000-000000000d0c','8c000000-0000-0000-0000-0000000000e1');
INSERT INTO public.exos_pos_order_lines(order_id,item_id,category,name,quantity,unit_price_cents,promoter_id) VALUES
  ('8c000000-0000-0000-0000-000000000d0c','8c000000-0000-0000-0000-000000000f04','ticket','x',2,0,'8c000000-0000-0000-0000-0000000009a1');
INSERT INTO public.exos_pos_payments(order_id,method,amount_cents,terminal_ref) VALUES
  ('8c000000-0000-0000-0000-000000000d0c','card',4000,'pi_TEST_C');
-- Order D: 1 GA (2000, tax 182 incl, promoter) + 1 beer (880): beer comped by staff, ticket on card.
INSERT INTO public.exos_pos_orders(id,event_id) VALUES ('8c000000-0000-0000-0000-000000000d0d','8c000000-0000-0000-0000-0000000000e1');
INSERT INTO public.exos_pos_order_lines(order_id,item_id,category,name,quantity,unit_price_cents,promoter_id) VALUES
  ('8c000000-0000-0000-0000-000000000d0d','8c000000-0000-0000-0000-000000000f04','ticket','x',1,0,'8c000000-0000-0000-0000-0000000009a1'),
  ('8c000000-0000-0000-0000-000000000d0d','8c000000-0000-0000-0000-000000000f01','bar','x',1,0,NULL);
INSERT INTO public.exos_pos_payments(order_id,method,amount_cents,terminal_ref) VALUES
  ('8c000000-0000-0000-0000-000000000d0d','card',2000,'pi_TEST_D');
SET ROLE authenticated;
SELECT set_config('app.uid', '8c000000-0000-0000-0000-0000000000a3', false);
INSERT INTO public.exos_pos_payments(order_id,method,amount_cents,comp_reason) VALUES
  ('8c000000-0000-0000-0000-000000000d0d','comp',880,'band guest');
DO $$
BEGIN
  ASSERT (SELECT status || '/' || payment_method || '/' || tip_cents FROM public.exos_pos_orders
           WHERE id = '8c000000-0000-0000-0000-000000000d0b') = 'paid/split/300', 'P4: B paid split, card tip 300';
  ASSERT (SELECT total_cents || '/' || tax_cents FROM public.exos_pos_orders
           WHERE id = '8c000000-0000-0000-0000-000000000d0c') = '4000/364', 'P4: C inclusive tax 364 of 4000';
  ASSERT (SELECT status || '/' || payment_method || '/' || total_cents || '/' || tax_cents FROM public.exos_pos_orders
           WHERE id = '8c000000-0000-0000-0000-000000000d0d') = 'paid/split/2880/262', 'P4: D card + comp';
  ASSERT (SELECT count(*) FROM public.exos_pos_payments WHERE order_id = '8c000000-0000-0000-0000-000000000d0c') = 1,
         'P4: staff at the event see server-written payments';
END $$;

-- ── P5 86 an item ──────────────────────────────────────────────────────────
DO $$
DECLARE raised boolean; r jsonb;
BEGIN
  r := public.exos_pos_set_86('8c000000-0000-0000-0000-000000000f01', true);   -- the bartender 86s beer
  ASSERT (r ->> 'is_86d')::boolean, 'P5: 86 answer';
  ASSERT (SELECT is_86d AND eighty_sixed_by = '8c000000-0000-0000-0000-0000000000a3' FROM public.exos_pos_items
           WHERE id = '8c000000-0000-0000-0000-000000000f01'), 'P5: 86 recorded with who';
  INSERT INTO public.exos_pos_orders(id,event_id) VALUES ('8c000000-0000-0000-0000-000000000d1a','8c000000-0000-0000-0000-0000000000e1');
  raised := false;
  BEGIN
    INSERT INTO public.exos_pos_order_lines(order_id,item_id,category,name,quantity,unit_price_cents) VALUES
      ('8c000000-0000-0000-0000-000000000d1a','8c000000-0000-0000-0000-000000000f01','bar','x',1,0);
  EXCEPTION WHEN raise_exception THEN raised := SQLERRM LIKE '%86''d%'; END;
  ASSERT raised, 'P5: an 86''d item does not sell';
  PERFORM public.exos_pos_set_86('8c000000-0000-0000-0000-000000000f01', false);
  INSERT INTO public.exos_pos_order_lines(order_id,item_id,category,name,quantity,unit_price_cents) VALUES
    ('8c000000-0000-0000-0000-000000000d1a','8c000000-0000-0000-0000-000000000f01','bar','x',1,0);
  ASSERT (SELECT total_cents FROM public.exos_pos_orders WHERE id = '8c000000-0000-0000-0000-000000000d1a') = 880,
         'P5: back on, it sells';
  -- The org-wide item: only owner / manager may 86 it.
  raised := false;
  BEGIN PERFORM public.exos_pos_set_86('8c000000-0000-0000-0000-000000000f03', true);
  EXCEPTION WHEN insufficient_privilege THEN raised := true; END;
  ASSERT raised, 'P5: staff cannot 86 an org-wide item';
  -- Stock: 2 shirts, 1 sold (order B) -> 1 left; 2 more refused.
  ASSERT (SELECT inventory_count FROM public.exos_pos_items WHERE id = '8c000000-0000-0000-0000-000000000f02') = 1,
         'P5: stock went down';
  raised := false;
  BEGIN
    INSERT INTO public.exos_pos_order_lines(order_id,item_id,category,name,quantity,unit_price_cents) VALUES
      ('8c000000-0000-0000-0000-000000000d1a','8c000000-0000-0000-0000-000000000f02','merch','x',2,0);
  EXCEPTION WHEN raise_exception THEN raised := SQLERRM LIKE '%only 1 left%'; END;
  ASSERT raised, 'P5: can''t sell more than the stock';
  RAISE NOTICE 'PASS P5 86 an item: refused while 86''d, sells again after; stock enforced';
END $$;

-- ── P6 tabs ────────────────────────────────────────────────────────────────
DO $$
DECLARE tab uuid; tab2 uuid; raised boolean; r jsonb;
BEGIN
  tab := public.exos_pos_open_tab('8c000000-0000-0000-0000-0000000000e1', '8c000000-0000-0000-0000-0000000000c1', NULL, 'Sam');
  raised := false;
  BEGIN PERFORM public.exos_pos_open_tab('8c000000-0000-0000-0000-0000000000e1', '8c000000-0000-0000-0000-0000000000c1');
  EXCEPTION WHEN unique_violation THEN raised := true; END;
  ASSERT raised, 'P6: one open tab per ticket';
  tab2 := public.exos_pos_open_tab('8c000000-0000-0000-0000-0000000000e1', NULL, 'WB-0042');
  raised := false;
  BEGIN PERFORM public.exos_pos_open_tab('8c000000-0000-0000-0000-0000000000e1', NULL, NULL);
  EXCEPTION WHEN invalid_parameter_value THEN raised := true; END;
  ASSERT raised, 'P6: a tab needs a ticket or a wristband';
  raised := false;
  BEGIN PERFORM public.exos_pos_open_tab('8c000000-0000-0000-0000-0000000000e2', '8c000000-0000-0000-0000-0000000000c1');
  EXCEPTION WHEN insufficient_privilege OR invalid_parameter_value THEN raised := true; END;
  ASSERT raised, 'P6: a ticket opens a tab only at its own event (and where the staff works)';

  -- Order E on the ticket tab: a beer, unpaid -> can't close.
  INSERT INTO public.exos_pos_orders(id,event_id,tab_id) VALUES ('8c000000-0000-0000-0000-000000000d0e','8c000000-0000-0000-0000-0000000000e1', tab);
  INSERT INTO public.exos_pos_order_lines(order_id,item_id,category,name,quantity,unit_price_cents) VALUES
    ('8c000000-0000-0000-0000-000000000d0e','8c000000-0000-0000-0000-000000000f01','bar','x',1,0);
  INSERT INTO public.exos_pos_orders(event_id,tab_id) VALUES ('8c000000-0000-0000-0000-0000000000e1', tab); -- empty, voided at close
  raised := false;
  BEGIN PERFORM public.exos_pos_close_tab(tab);
  EXCEPTION WHEN raise_exception THEN raised := SQLERRM LIKE '%880 still due%'; END;
  ASSERT raised, 'P6: a tab with a balance does not close';
  INSERT INTO public.exos_pos_payments(order_id,method,amount_cents) VALUES ('8c000000-0000-0000-0000-000000000d0e','cash',880);
  r := public.exos_pos_close_tab(tab);
  ASSERT r = jsonb_build_object('tab_id', tab, 'orders', 1, 'total_cents', 880, 'tip_cents', 0), 'P6: close answer ' || r;
  ASSERT (SELECT status FROM public.exos_pos_tabs WHERE id = tab) = 'closed', 'P6: closed';
  ASSERT (SELECT count(*) FROM public.exos_pos_orders WHERE tab_id = tab AND status = 'void') = 1, 'P6: empty order voided';
  raised := false;
  BEGIN INSERT INTO public.exos_pos_orders(event_id,tab_id) VALUES ('8c000000-0000-0000-0000-0000000000e1', tab);
  EXCEPTION WHEN invalid_parameter_value THEN raised := true; END;
  ASSERT raised, 'P6: nothing rings onto a closed tab';
  -- The wristband tab has nothing on it: closes at zero.
  ASSERT (public.exos_pos_close_tab(tab2) ->> 'total_cents')::int = 0, 'P6: empty wristband tab closes';
  RAISE NOTICE 'PASS P6 tabs on a ticket or wristband: one open each, balance must be paid to close';
END $$;

-- ── P7 cash drawer ─────────────────────────────────────────────────────────
DO $$
DECLARE raised boolean; r jsonb;
BEGIN
  raised := false;
  BEGIN PERFORM public.exos_pos_close_drawer('8c000000-0000-0000-0000-000000000dd1', 12950, '{"10000":1,"2000":1}'::jsonb);
  EXCEPTION WHEN invalid_parameter_value THEN raised := true; END;
  ASSERT raised, 'P7: counts must add up to the counted amount';
  -- Float 10000 + A (1760 + 200 tip) + B cash 1000 = 12960 expected; 12950 counted -> 10 short.
  r := public.exos_pos_close_drawer('8c000000-0000-0000-0000-000000000dd1', 12950,
         '{"10000":1,"2000":1,"500":1,"100":4,"50":1}'::jsonb, 'end of night');
  ASSERT (r ->> 'expected_cents')::int = 12960 AND (r ->> 'variance_cents')::int = -10
         AND (r ->> 'cash_taken_cents')::int = 2960, 'P7: expected vs counted, got ' || r;
  raised := false;
  BEGIN INSERT INTO public.exos_pos_payments(order_id,method,amount_cents,drawer_session_id) VALUES
    ('8c000000-0000-0000-0000-000000000d1a','cash',100,'8c000000-0000-0000-0000-000000000dd1');
  EXCEPTION WHEN invalid_parameter_value THEN raised := true; END;
  ASSERT raised, 'P7: no cash into a closed drawer';
  RAISE NOTICE 'PASS P7 cash drawer: expected 12960, counted 12950, variance -10';
END $$;

-- ── P8 settlement summary ─────────────────────────────────────────────────
DO $$
DECLARE raised boolean := false;
BEGIN
  BEGIN PERFORM public.exos_pos_settlement_summary('8c000000-0000-0000-0000-0000000000e1');
  EXCEPTION WHEN insufficient_privilege THEN raised := true; END;
  ASSERT raised, 'P8: door staff do not read the settlement';
END $$;
SELECT set_config('app.uid', '8c000000-0000-0000-0000-0000000000a4', false);  -- finance
DO $$
DECLARE s jsonb := public.exos_pos_settlement_summary('8c000000-0000-0000-0000-0000000000e1');
BEGIN
  -- Inside the org's first 6 months: no Exos fee.
  ASSERT (s ->> 'fee_bps')::int = 0 AND (s ->> 'exos_fee_cents')::int = 0, 'P8: free months, no fee: ' || s;
END $$;
RESET ROLE;
UPDATE public.exos_org_billing SET fee_free_until = now() - interval '1 day'
 WHERE org_id = '8c000000-0000-0000-0000-000000000001';
SET ROLE authenticated;
DO $$
DECLARE s jsonb := public.exos_pos_settlement_summary('8c000000-0000-0000-0000-0000000000e1');
BEGIN
  -- Paid orders A, B, C, D, E (the P5 order D1A is still open).
  ASSERT (s ->> 'orders')::int = 5 AND (s ->> 'open_orders')::int = 1 AND (s ->> 'open_tabs')::int = 0, 'P8: counts ' || s;
  ASSERT s -> 'gross' = '{"ticket":6000,"bar":3520,"merch":2500,"total":12020}'::jsonb, 'P8: gross ' || (s -> 'gross');
  ASSERT (s ->> 'tax_cents')::int = 866, 'P8: tax ' || (s ->> 'tax_cents');
  ASSERT s -> 'tenders' = '{"cash":3640,"card":7500,"comp":880}'::jsonb, 'P8: tenders ' || (s -> 'tenders');
  ASSERT s -> 'tips' = '{"cash":200,"card":300,"total":500}'::jsonb, 'P8: tips ' || (s -> 'tips');
  -- Card ticket sales: C 4000 + D floor(2000 x 2000 / 2880) = 1388 -> 5388; 3% half up = 162.
  ASSERT (s ->> 'card_ticket_cents')::int = 5388, 'P8: card ticket sales ' || (s ->> 'card_ticket_cents');
  ASSERT (s ->> 'fee_bps')::int = 300 AND (s ->> 'exos_fee_cents')::int = 162, 'P8: Exos fee ' || (s ->> 'exos_fee_cents');
  ASSERT (s ->> 'organizer_net_cents')::int = 3640 + 7500 - 162, 'P8: organizer net ' || (s ->> 'organizer_net_cents');
  -- Promoter: C 3636 + D floor(1818 x 2000 / 2880) = 1262 -> 4898 over 3 tickets.
  ASSERT s -> 'promoters' = '[{"promoter_id":"8c000000-0000-0000-0000-0000000009a1","tickets":3,"base_cents":4898}]'::jsonb,
         'P8: promoters ' || (s -> 'promoters');
  ASSERT s -> 'drawers' = '{"open":0,"closed":1,"float_cents":10000,"expected_cents":12960,"counted_cents":12950,"variance_cents":-10}'::jsonb,
         'P8: drawers ' || (s -> 'drawers');
  RAISE NOTICE 'PASS P8 settlement summary: gross 12020, cash 3640 / card 7500 / comp 880, fee 162, variance -10';
END $$;

-- ── P9 settlement records ─────────────────────────────────────────────────
DO $$
DECLARE raised boolean := false;
BEGIN
  BEGIN PERFORM public.exos_pos_record_settlement('8c000000-0000-0000-0000-0000000000e1', false);
  EXCEPTION WHEN insufficient_privilege THEN raised := true; END;
  ASSERT raised, 'P9: finance reads but does not record settlements';
END $$;
SELECT set_config('app.uid', '8c000000-0000-0000-0000-0000000000a1', false);
DO $$
DECLARE raised boolean; v uuid;
BEGIN
  raised := false;
  BEGIN PERFORM public.exos_pos_record_settlement('8c000000-0000-0000-0000-0000000000e1', true);
  EXCEPTION WHEN raise_exception THEN raised := SQLERRM LIKE '%close every drawer and order%'; END;
  ASSERT raised, 'P9: no final settlement with an open order';
  v := public.exos_pos_record_settlement('8c000000-0000-0000-0000-0000000000e1', false);
  ASSERT (SELECT status || '/' || card_cents || '/' || exos_fee_cents || '/' || organizer_net_cents || '/' || drawer_variance_cents
            FROM public.exos_pos_settlements WHERE id = v) = 'draft/7500/162/10978/-10', 'P9: draft recorded';
END $$;
RESET ROLE;
-- Close the stray order (void, server side) so the night can be finalized.
UPDATE public.exos_pos_orders SET status = 'void', voided_at = now(), void_reason = 'test'
 WHERE id = '8c000000-0000-0000-0000-000000000d1a';
SET ROLE authenticated;
DO $$
DECLARE raised boolean; v uuid;
BEGIN
  v := public.exos_pos_record_settlement('8c000000-0000-0000-0000-0000000000e1', true);
  ASSERT (SELECT status FROM public.exos_pos_settlements WHERE id = v) = 'final', 'P9: final recorded';
  raised := false;
  BEGIN PERFORM public.exos_pos_record_settlement('8c000000-0000-0000-0000-0000000000e1', true);
  EXCEPTION WHEN unique_violation THEN raised := true; END;
  ASSERT raised, 'P9: one final settlement per event';
  RAISE NOTICE 'PASS P9 settlement records: owner / manager only, one final per event';
END $$;
SELECT set_config('app.uid', '8c000000-0000-0000-0000-0000000000b9', false);
DO $$
BEGIN
  ASSERT (SELECT count(*) FROM public.exos_pos_settlements) = 0, 'P9: the other org sees no settlements';
  ASSERT (SELECT count(*) FROM public.exos_pos_orders) = 0, 'P9: the other org sees no orders';
  ASSERT (SELECT count(*) FROM public.exos_pos_payments) = 0, 'P9: the other org sees no payments';
  ASSERT (SELECT count(*) FROM public.exos_pos_tabs) = 0, 'P9: the other org sees no tabs';
  ASSERT (SELECT count(*) FROM public.exos_pos_drawer_sessions) = 0, 'P9: the other org sees no drawers';
  RAISE NOTICE 'PASS P9b nothing of org 1 is visible to org 2';
END $$;
RESET ROLE;
SELECT set_config('app.uid', '', false);

DO $$ BEGIN RAISE NOTICE '*** POS scaffold tests PASSED ***'; END $$;
ROLLBACK;
