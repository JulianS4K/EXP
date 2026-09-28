-- ============================================================================
-- MCP server reads (mig 20260929060000). Self-contained (7c prefix), rolled back.
--   C1 exos_mcp_event_sales: per tier, paid orders, gross, refunds; NULL for
--      another org's event
--   C2 exos_mcp_door_status: issued / checked in / voided; NULL for another org
--   C3 exos_rate_hit counts per bucket per minute
--   C4 all three are service role only
-- ============================================================================
\set ON_ERROR_STOP on
BEGIN;
INSERT INTO auth.users(id,email,email_confirmed_at) VALUES ('7c000000-0000-0000-0000-0000000000a0','7c-owner@x.com',now());
INSERT INTO public.exos_orgs(id,name,slug,owner_uid) VALUES
  ('7c000000-0000-0000-0000-000000000001','7C Org','7c-org','7c000000-0000-0000-0000-0000000000a0'),
  ('7c000000-0000-0000-0000-000000000002','7C Other','7c-other','7c000000-0000-0000-0000-0000000000a0');
INSERT INTO public.exos_events(id,org_id,name,slug,status,starts_at,venue_name,total_tickets,tickets_sold,currency) VALUES
  ('7c000000-0000-0000-0000-0000000000e1','7c000000-0000-0000-0000-000000000001','7C Show','7c-show','published',now() + interval '5 days','Hall',100,3,'usd');
INSERT INTO public.exos_ticket_tiers(id,event_id,name,price,capacity,sold) VALUES
  ('7c000000-0000-0000-0000-0000000000d1','7c000000-0000-0000-0000-0000000000e1','GA',40,100,3);
INSERT INTO public.exos_checkout_sessions(session_id,event_id,tier_id,org_id,buyer_uid,buyer_email,quantity,amount_cents,currency,status) VALUES
  ('cs_7c_1','7c000000-0000-0000-0000-0000000000e1','7c000000-0000-0000-0000-0000000000d1','7c000000-0000-0000-0000-000000000001','7c000000-0000-0000-0000-0000000000a0','a@x.com',2,8000,'usd','fulfilled'),
  ('cs_7c_2','7c000000-0000-0000-0000-0000000000e1','7c000000-0000-0000-0000-0000000000d1','7c000000-0000-0000-0000-000000000001','7c000000-0000-0000-0000-0000000000a0','a@x.com',1,4000,'usd','partially_refunded'),
  ('cs_7c_3','7c000000-0000-0000-0000-0000000000e1','7c000000-0000-0000-0000-0000000000d1','7c000000-0000-0000-0000-000000000001','7c000000-0000-0000-0000-0000000000a0','a@x.com',1,4000,'usd','pending');
INSERT INTO public.exos_order_refunds(session_id,org_id,provider,refund_id,amount_cents,currency,status)
VALUES ('cs_7c_2','7c000000-0000-0000-0000-000000000001','stripe','re_7c_1',1500,'usd','succeeded');
INSERT INTO public.exos_tickets(id,event_id,org_id,tier_id,owner_id,buyer_id,status,barcode_secret) VALUES
  ('7c000000-0000-0000-0000-00000000c001','7c000000-0000-0000-0000-0000000000e1','7c000000-0000-0000-0000-000000000001','7c000000-0000-0000-0000-0000000000d1','7c000000-0000-0000-0000-0000000000a0','7c000000-0000-0000-0000-0000000000a0','used','s1'),
  ('7c000000-0000-0000-0000-00000000c002','7c000000-0000-0000-0000-0000000000e1','7c000000-0000-0000-0000-000000000001','7c000000-0000-0000-0000-0000000000d1','7c000000-0000-0000-0000-0000000000a0','7c000000-0000-0000-0000-0000000000a0','active','s2'),
  ('7c000000-0000-0000-0000-00000000c003','7c000000-0000-0000-0000-0000000000e1','7c000000-0000-0000-0000-000000000001','7c000000-0000-0000-0000-0000000000d1','7c000000-0000-0000-0000-0000000000a0','7c000000-0000-0000-0000-0000000000a0','voided','s3');

DO $$
DECLARE r jsonb;
BEGIN
  r := public.exos_mcp_event_sales('7c000000-0000-0000-0000-000000000001','7c000000-0000-0000-0000-0000000000e1');
  IF r->'orders' <> '{"paid": 2, "gross_cents": 12000, "refunded_cents": 1500, "currency": "USD"}'::jsonb
     OR r->'tiers'->0->>'name' <> 'GA' OR (r->'tiers'->0->>'sold')::int <> 3 THEN
    RAISE EXCEPTION 'C1 FAIL: %', r;
  END IF;
  IF public.exos_mcp_event_sales('7c000000-0000-0000-0000-000000000002','7c000000-0000-0000-0000-0000000000e1') IS NOT NULL THEN
    RAISE EXCEPTION 'C1 FAIL: another org read the sales';
  END IF;
  RAISE NOTICE 'C1 ok: sales per tier, paid orders, gross and refunds; own org only';

  r := public.exos_mcp_door_status('7c000000-0000-0000-0000-000000000001','7c000000-0000-0000-0000-0000000000e1');
  IF (r->>'issued')::int <> 2 OR (r->>'checked_in')::int <> 1 OR (r->>'voided')::int <> 1 THEN RAISE EXCEPTION 'C2 FAIL: %', r; END IF;
  IF public.exos_mcp_door_status('7c000000-0000-0000-0000-000000000002','7c000000-0000-0000-0000-0000000000e1') IS NOT NULL THEN
    RAISE EXCEPTION 'C2 FAIL: another org read the door';
  END IF;
  RAISE NOTICE 'C2 ok: door counts; own org only';

  IF NOT public.exos_rate_hit('mcp:test', 2) OR NOT public.exos_rate_hit('mcp:test', 2) OR public.exos_rate_hit('mcp:test', 2) THEN
    RAISE EXCEPTION 'C3 FAIL: limit';
  END IF;
  IF NOT public.exos_rate_hit('mcp:other', 2) THEN RAISE EXCEPTION 'C3 FAIL: buckets are separate'; END IF;
  RAISE NOTICE 'C3 ok: per-bucket fixed window';

  IF has_function_privilege('authenticated', 'public.exos_mcp_event_sales(uuid, uuid)', 'EXECUTE')
     OR has_function_privilege('anon', 'public.exos_mcp_door_status(uuid, uuid)', 'EXECUTE')
     OR has_function_privilege('authenticated', 'public.exos_rate_hit(text, integer)', 'EXECUTE')
     OR NOT has_function_privilege('service_role', 'public.exos_mcp_event_sales(uuid, uuid)', 'EXECUTE') THEN
    RAISE EXCEPTION 'C4 FAIL: grants';
  END IF;
  RAISE NOTICE 'C4 ok: service role only';
END $$;
ROLLBACK;
