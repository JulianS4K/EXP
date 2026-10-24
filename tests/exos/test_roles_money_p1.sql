-- ============================================================================
-- Roles + money P1 (mig 20261021120000). Self-contained ("a1d0" ids: owner
-- …a1, manager …a2, finance …a3, scanner …a4, content …a5, stranger …a6),
-- rolled back.
--   R1 finance records a promoter payout; scanner / content / stranger can't;
--      finance still can't set terms
--   R2 refund orders page: totals over every order (past 500), search by
--      email / order id (wildcards literal), offset paging, newest first
--   R3 the page is owner / manager / finance only
--   R4 dispute buyers: the session's email for finance-capable roles only
--   R5 checkout reminder stats: sent, recovered (paid after the reminder),
--      the org switch; finance-capable only
-- (The switch itself is owner-only through exos_orgs_upd, which this scratch
-- DB stubs without RLS; orgRoles.test.ts checks the policy text.)
-- ============================================================================
\set ON_ERROR_STOP on
BEGIN;
INSERT INTO auth.users(id,email,email_confirmed_at) VALUES
  ('a1d00000-0000-0000-0000-0000000000a1','rm-own@x.com',now()),
  ('a1d00000-0000-0000-0000-0000000000a2','rm-mgr@x.com',now()),
  ('a1d00000-0000-0000-0000-0000000000a3','rm-fin@x.com',now()),
  ('a1d00000-0000-0000-0000-0000000000a4','rm-scan@x.com',now()),
  ('a1d00000-0000-0000-0000-0000000000a5','rm-content@x.com',now()),
  ('a1d00000-0000-0000-0000-0000000000a6','rm-stranger@x.com',now()),
  ('a1d00000-0000-0000-0000-0000000000b1','rm-buyer1@x.com',now()),
  ('a1d00000-0000-0000-0000-0000000000b2','rm-buyer2@x.com',now()),
  ('a1d00000-0000-0000-0000-0000000000b3','rm-buyer3@x.com',now());
INSERT INTO public.exos_orgs(id,name,slug,owner_uid) VALUES
  ('a1d00000-0000-0000-0000-000000000001','RM Org','rm-org-stub','a1d00000-0000-0000-0000-0000000000a1');
INSERT INTO public.exos_org_memberships(org_id,user_id,role,disabled) VALUES
  ('a1d00000-0000-0000-0000-000000000001','a1d00000-0000-0000-0000-0000000000a1','owner',false),
  ('a1d00000-0000-0000-0000-000000000001','a1d00000-0000-0000-0000-0000000000a2','manager',false),
  ('a1d00000-0000-0000-0000-000000000001','a1d00000-0000-0000-0000-0000000000a3','finance',false),
  ('a1d00000-0000-0000-0000-000000000001','a1d00000-0000-0000-0000-0000000000a4','scanner',false),
  ('a1d00000-0000-0000-0000-000000000001','a1d00000-0000-0000-0000-0000000000a5','content',false);
INSERT INTO public.exos_events(id,org_id,name,slug,status,starts_at,total_tickets,tickets_sold,created_by) VALUES
  ('a1d00000-0000-0000-0000-0000000000e1','a1d00000-0000-0000-0000-000000000001','RM Night','rm-night-stub','published',
   now() + interval '3 days', 1000, 0, 'a1d00000-0000-0000-0000-0000000000a1');
INSERT INTO public.exos_ticket_tiers(id,event_id,name,price,capacity,sold,visibility) VALUES
  ('a1d00000-0000-0000-0000-0000000000d1','a1d00000-0000-0000-0000-0000000000e1','GA',20,1000,0,'public');

-- 520 paid orders of $20 (one ticket each), the newest last; order 7 is a
-- "50%_off@x.com" buyer to check that LIKE wildcards are literal.
INSERT INTO public.exos_checkout_sessions(session_id,event_id,tier_id,org_id,buyer_uid,buyer_email,quantity,amount_cents,status,payment_intent,created_at)
SELECT 'cs_rm' || lpad(n::text, 4, '0'), 'a1d00000-0000-0000-0000-0000000000e1', 'a1d00000-0000-0000-0000-0000000000d1',
       'a1d00000-0000-0000-0000-000000000001', 'a1d00000-0000-0000-0000-0000000000b1',
       CASE WHEN n = 7 THEN '50%_off@x.com' ELSE 'buyer' || n || '@x.com' END,
       1, 2000, 'fulfilled', 'pi_rm' || n, now() - interval '30 days' + n * interval '1 minute'
  FROM generate_series(1, 520) n;
INSERT INTO public.exos_tickets(event_id,org_id,tier_id,buyer_id,owner_id,status,barcode_secret,price_paid,order_ref)
SELECT 'a1d00000-0000-0000-0000-0000000000e1','a1d00000-0000-0000-0000-000000000001','a1d00000-0000-0000-0000-0000000000d1',
       'a1d00000-0000-0000-0000-0000000000b1','a1d00000-0000-0000-0000-0000000000b1','active', gen_random_uuid()::text, 20,
       'cs_rm' || lpad(n::text, 4, '0')
  FROM generate_series(1, 520) n;

-- R1 -------------------------------------------------------------------------
DO $$
DECLARE p uuid; c1 uuid; c2 uuid; ok boolean; u text; po uuid;
BEGIN
  INSERT INTO public.exos_promoters(org_id, code, name) VALUES ('a1d00000-0000-0000-0000-000000000001', 'rmkay', 'RM Kay')
    RETURNING id INTO p;
  INSERT INTO public.exos_promoter_commissions(org_id,promoter_id,event_id,currency,gross_cents,base_cents,rate_bps,flat_cents,terms_source,commission_cents)
  VALUES ('a1d00000-0000-0000-0000-000000000001', p, 'a1d00000-0000-0000-0000-0000000000e1', 'usd', 2000, 2000, 1000, 0, 'promoter', 200)
  RETURNING id INTO c1;
  INSERT INTO public.exos_promoter_commissions(org_id,promoter_id,event_id,currency,gross_cents,base_cents,rate_bps,flat_cents,terms_source,commission_cents)
  VALUES ('a1d00000-0000-0000-0000-000000000001', p, 'a1d00000-0000-0000-0000-0000000000e1', 'usd', 2000, 2000, 1000, 0, 'promoter', 200)
  RETURNING id INTO c2;

  FOREACH u IN ARRAY ARRAY['a1d00000-0000-0000-0000-0000000000a4','a1d00000-0000-0000-0000-0000000000a5','a1d00000-0000-0000-0000-0000000000a6'] LOOP
    PERFORM set_config('app.uid', u, false);
    ok := false;
    BEGIN PERFORM public.exos_record_promoter_payout(p, ARRAY[c1], 200, 'Venmo');
    EXCEPTION WHEN insufficient_privilege THEN ok := true; END;
    ASSERT ok, 'R1: ' || u || ' recorded a payout';
  END LOOP;

  PERFORM set_config('app.uid', 'a1d00000-0000-0000-0000-0000000000a3', false);
  ok := false;
  BEGIN PERFORM public.exos_set_promoter_terms(p, 5000, 0);
  EXCEPTION WHEN insufficient_privilege THEN ok := true; END;
  ASSERT ok, 'R1: finance set promoter terms';
  ok := false;
  BEGIN PERFORM public.exos_record_promoter_payout(p, ARRAY[c1], 199, 'Venmo');
  EXCEPTION WHEN invalid_parameter_value THEN ok := true; END;
  ASSERT ok, 'R1: finance payout skipped the amount check';
  po := public.exos_record_promoter_payout(p, ARRAY[c1], 200, 'Venmo', 'week 1');
  ASSERT (SELECT status FROM public.exos_promoter_commissions WHERE id = c1) = 'paid', 'R1: finance payout did not mark the row paid';
  ASSERT (SELECT created_by FROM public.exos_promoter_payouts WHERE id = po) = 'a1d00000-0000-0000-0000-0000000000a3', 'R1: payout author';
  -- owner / manager unchanged
  PERFORM set_config('app.uid', 'a1d00000-0000-0000-0000-0000000000a2', false);
  PERFORM public.exos_record_promoter_payout(p, ARRAY[c2], 200, 'cash');
  ASSERT (SELECT status FROM public.exos_promoter_commissions WHERE id = c2) = 'paid', 'R1: manager payout';
  RAISE NOTICE 'OK  R1 finance records promoter payouts; terms stay owner / manager';
END $$;

-- R2 -------------------------------------------------------------------------
DO $$
DECLARE j jsonb; old_n int;
BEGIN
  PERFORM set_config('app.uid', 'a1d00000-0000-0000-0000-0000000000a3', false);
  SELECT count(*) INTO old_n FROM public.exos_event_refund_orders('a1d00000-0000-0000-0000-0000000000e1');
  ASSERT old_n = 500, 'R2: the old read should stop at 500, got ' || old_n;

  j := public.exos_event_refund_orders_page('a1d00000-0000-0000-0000-0000000000e1');
  ASSERT (j->>'total_orders')::int = 520, 'R2: total_orders ' || (j->>'total_orders');
  ASSERT (j->>'matches')::int = 520, 'R2: matches';
  ASSERT (j->>'total_refundable_cents')::bigint = 520 * 2000, 'R2: total refundable ' || (j->>'total_refundable_cents');
  ASSERT jsonb_array_length(j->'orders') = 50, 'R2: default page size';
  ASSERT j->'orders'->0->>'session_id' = 'cs_rm0520', 'R2: newest first, got ' || (j->'orders'->0->>'session_id');
  ASSERT (j->'orders'->0->>'tickets')::int = 1 AND (j->'orders'->0->>'active_tickets')::int = 1, 'R2: ticket counts';

  -- the oldest order (beyond the newest 500) is reachable by search and by paging
  j := public.exos_event_refund_orders_page('a1d00000-0000-0000-0000-0000000000e1', 'CS_RM0001');
  ASSERT (j->>'matches')::int = 1 AND j->'orders'->0->>'session_id' = 'cs_rm0001', 'R2: search by order id (case-insensitive)';
  ASSERT (j->>'total_orders')::int = 520, 'R2: totals ignore the search';
  j := public.exos_event_refund_orders_page('a1d00000-0000-0000-0000-0000000000e1', 'buyer3@x.com');
  ASSERT (j->>'matches')::int = 1 AND j->'orders'->0->>'buyer_email' = 'buyer3@x.com', 'R2: search by email';
  j := public.exos_event_refund_orders_page('a1d00000-0000-0000-0000-0000000000e1', '50%_');
  ASSERT (j->>'matches')::int = 1 AND j->'orders'->0->>'session_id' = 'cs_rm0007', 'R2: % and _ are literal, got ' || (j->>'matches');
  j := public.exos_event_refund_orders_page('a1d00000-0000-0000-0000-0000000000e1', NULL, 500, 50);
  ASSERT jsonb_array_length(j->'orders') = 20, 'R2: last page';
  ASSERT j->'orders'->19->>'session_id' = 'cs_rm0001', 'R2: last row is the oldest';
  j := public.exos_event_refund_orders_page('a1d00000-0000-0000-0000-0000000000e1', NULL, 0, 10000);
  ASSERT jsonb_array_length(j->'orders') = 200, 'R2: page size capped at 200';
  j := public.exos_event_refund_orders_page('a1d00000-0000-0000-0000-0000000000e1', 'nobody-here');
  ASSERT (j->>'matches')::int = 0 AND j->'orders' = '[]'::jsonb, 'R2: no match';
  RAISE NOTICE 'OK  R2 refund orders page: totals, search, paging';
END $$;

-- R3 -------------------------------------------------------------------------
DO $$
DECLARE ok boolean; u text;
BEGIN
  FOREACH u IN ARRAY ARRAY['a1d00000-0000-0000-0000-0000000000a1','a1d00000-0000-0000-0000-0000000000a2'] LOOP
    PERFORM set_config('app.uid', u, false);
    PERFORM public.exos_event_refund_orders_page('a1d00000-0000-0000-0000-0000000000e1');
  END LOOP;
  FOREACH u IN ARRAY ARRAY['a1d00000-0000-0000-0000-0000000000a4','a1d00000-0000-0000-0000-0000000000a5','a1d00000-0000-0000-0000-0000000000a6', ''] LOOP
    PERFORM set_config('app.uid', u, false);
    ok := false;
    BEGIN PERFORM public.exos_event_refund_orders_page('a1d00000-0000-0000-0000-0000000000e1');
    EXCEPTION WHEN insufficient_privilege THEN ok := true; END;
    ASSERT ok, 'R3: ' || coalesce(nullif(u, ''), 'anonymous') || ' read the refund orders';
  END LOOP;
  ASSERT NOT has_function_privilege('anon', 'public.exos_event_refund_orders_page(uuid,text,int,int)', 'EXECUTE'), 'R3: anon may call';
  RAISE NOTICE 'OK  R3 refund orders page is owner / manager / finance';
END $$;

-- R4 -------------------------------------------------------------------------
DO $$
DECLARE d1 uuid; n int; e text; u text;
BEGIN
  INSERT INTO public.exos_disputes(org_id,event_id,session_id,dispute_id,amount_cents,fee_cents,currency,status)
  VALUES ('a1d00000-0000-0000-0000-000000000001','a1d00000-0000-0000-0000-0000000000e1','cs_rm0003','du_rm3',2000,1500,'usd','needs_response')
  RETURNING id INTO d1;
  FOREACH u IN ARRAY ARRAY['a1d00000-0000-0000-0000-0000000000a1','a1d00000-0000-0000-0000-0000000000a2','a1d00000-0000-0000-0000-0000000000a3'] LOOP
    PERFORM set_config('app.uid', u, false);
    SELECT b.buyer_email INTO e FROM public.exos_dispute_buyers(ARRAY[d1]) b WHERE b.id = d1;
    ASSERT e = 'buyer3@x.com', 'R4: ' || u || ' got ' || coalesce(e, 'null');
  END LOOP;
  FOREACH u IN ARRAY ARRAY['a1d00000-0000-0000-0000-0000000000a4','a1d00000-0000-0000-0000-0000000000a5','a1d00000-0000-0000-0000-0000000000a6', ''] LOOP
    PERFORM set_config('app.uid', u, false);
    SELECT count(*) INTO n FROM public.exos_dispute_buyers(ARRAY[d1]);
    ASSERT n = 0, 'R4: ' || coalesce(nullif(u, ''), 'anonymous') || ' saw a buyer email';
  END LOOP;
  PERFORM set_config('app.uid', 'a1d00000-0000-0000-0000-0000000000a3', false);
  SELECT count(*) INTO n FROM public.exos_dispute_buyers(NULL);
  ASSERT n = 0, 'R4: NULL ids';
  RAISE NOTICE 'OK  R4 dispute buyers for finance-capable roles only';
END $$;

-- R5 -------------------------------------------------------------------------
DO $$
DECLARE j jsonb; ok boolean; u text;
BEGIN
  -- All reminded 2 days ago. b1 paid since (its 520 orders are older, the new
  -- one is partly refunded: still recovered); b2 paid only BEFORE the
  -- reminder; b3 only let another checkout expire.
  INSERT INTO public.exos_checkout_reminders(buyer_uid,event_id,session_id,sent_at) VALUES
    ('a1d00000-0000-0000-0000-0000000000b1','a1d00000-0000-0000-0000-0000000000e1','cs_rmx1', now() - interval '2 days'),
    ('a1d00000-0000-0000-0000-0000000000b2','a1d00000-0000-0000-0000-0000000000e1','cs_rmx2', now() - interval '2 days'),
    ('a1d00000-0000-0000-0000-0000000000b3','a1d00000-0000-0000-0000-0000000000e1','cs_rmx3', now() - interval '2 days');
  INSERT INTO public.exos_checkout_sessions(session_id,event_id,tier_id,org_id,buyer_uid,buyer_email,quantity,amount_cents,status,payment_intent,created_at) VALUES
    ('cs_rmr1','a1d00000-0000-0000-0000-0000000000e1','a1d00000-0000-0000-0000-0000000000d1','a1d00000-0000-0000-0000-000000000001',
     'a1d00000-0000-0000-0000-0000000000b2','rm-buyer2@x.com',2,4000,'fulfilled','pi_rmr1', now() - interval '3 days'),
    ('cs_rmr2','a1d00000-0000-0000-0000-0000000000e1','a1d00000-0000-0000-0000-0000000000d1','a1d00000-0000-0000-0000-000000000001',
     'a1d00000-0000-0000-0000-0000000000b3','rm-buyer3@x.com',1,2000,'expired',NULL, now() - interval '1 day');
  INSERT INTO public.exos_checkout_sessions(session_id,event_id,tier_id,org_id,buyer_uid,buyer_email,quantity,amount_cents,status,payment_intent,created_at) VALUES
    ('cs_rmr3','a1d00000-0000-0000-0000-0000000000e1','a1d00000-0000-0000-0000-0000000000d1','a1d00000-0000-0000-0000-000000000001',
     'a1d00000-0000-0000-0000-0000000000b1','rm-buyer1@x.com',3,6000,'partially_refunded','pi_rmr3', now() - interval '1 day');

  PERFORM set_config('app.uid', 'a1d00000-0000-0000-0000-0000000000a3', false);
  j := public.exos_event_checkout_reminder_stats('a1d00000-0000-0000-0000-0000000000e1');
  ASSERT j = '{"enabled": true, "sent": 3, "recovered": 1, "recovered_cents": 6000}'::jsonb, 'R5: stats ' || j::text;

  UPDATE public.exos_orgs SET checkout_reminders_enabled = false WHERE id = 'a1d00000-0000-0000-0000-000000000001';
  j := public.exos_event_checkout_reminder_stats('a1d00000-0000-0000-0000-0000000000e1');
  ASSERT (j->>'enabled')::boolean = false, 'R5: switch off';

  FOREACH u IN ARRAY ARRAY['a1d00000-0000-0000-0000-0000000000a4','a1d00000-0000-0000-0000-0000000000a5','a1d00000-0000-0000-0000-0000000000a6', ''] LOOP
    PERFORM set_config('app.uid', u, false);
    ok := false;
    BEGIN PERFORM public.exos_event_checkout_reminder_stats('a1d00000-0000-0000-0000-0000000000e1');
    EXCEPTION WHEN insufficient_privilege THEN ok := true; END;
    ASSERT ok, 'R5: ' || coalesce(nullif(u, ''), 'anonymous') || ' read reminder stats';
  END LOOP;
  RAISE NOTICE 'OK  R5 checkout reminder stats';
END $$;

ROLLBACK;
