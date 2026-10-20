-- ============================================================================
-- Buyer fixes (mig 20261021100000).
--   B1 a hidden free tier: no code / a wrong code / another tier's code are
--      refused; its own code claims it and uses one use per ticket
--   B2 a retry of the same claim returns its tickets once the code is used up
--   B3 a code that doesn't cover the quantity is refused and nothing is taken
--   B4 public free tiers still claim without a code (3-argument call); one
--      function, authenticated only
--   B5 a cancelled event: the payer can ask for a refund whatever the policy;
--      a refunded ticket still can't
-- Self-contained ids bb…; runs after the full run_p0.sh chain.
-- ============================================================================
\set ON_ERROR_STOP on
BEGIN;

CREATE FUNCTION pg_temp.u(p text) RETURNS uuid LANGUAGE sql IMMUTABLE AS $$ SELECT ('bb000000-0000-0000-0000-' || p)::uuid $$;
GRANT EXECUTE ON FUNCTION pg_temp.u(text) TO anon, authenticated;
CREATE FUNCTION pg_temp.act(p_uid text, p_email text) RETURNS void LANGUAGE sql AS $$
  SELECT set_config('app.uid', coalesce(p_uid, ''), true),
         set_config('app.jwt', CASE WHEN p_email IS NULL THEN '' ELSE jsonb_build_object('email', p_email)::text END, true);
$$;
GRANT EXECUTE ON FUNCTION pg_temp.act(text, text) TO anon, authenticated;
-- The error a statement raises ('' when it runs).
CREATE FUNCTION pg_temp.err(p_sql text) RETURNS text LANGUAGE plpgsql AS $$
BEGIN
  EXECUTE p_sql;
  RETURN '';
EXCEPTION WHEN OTHERS THEN
  RETURN SQLERRM;
END $$;
GRANT EXECUTE ON FUNCTION pg_temp.err(text) TO anon, authenticated;

INSERT INTO auth.users(id,email,email_confirmed_at) VALUES
  ('bb000000-0000-0000-0000-0000000000a1','bbown@x.com',now()),
  ('bb000000-0000-0000-0000-0000000000b1','bbfan@x.com',now()),
  ('bb000000-0000-0000-0000-0000000000b2','bbfan2@x.com',now());
INSERT INTO public.exos_orgs(id,name,slug,owner_uid) VALUES
  ('bb000000-0000-0000-0000-000000000001','BB Org','bb-org-stub','bb000000-0000-0000-0000-0000000000a1');
INSERT INTO public.exos_org_memberships(org_id,user_id,role) VALUES
  ('bb000000-0000-0000-0000-000000000001','bb000000-0000-0000-0000-0000000000a1','owner');
-- e1: free event with a hidden guest-list tier (d1), a public free tier (d2) and
-- a hidden tier with its own code (d3). e2: cancelled, all sales final.
INSERT INTO public.exos_events(id,org_id,name,slug,status,starts_at,timezone,total_tickets,tickets_sold,created_by,refund_policy) VALUES
  ('bb000000-0000-0000-0000-0000000000e1','bb000000-0000-0000-0000-000000000001','BB Free','bb-free','published',now() + interval '10 days','America/New_York',100,0,'bb000000-0000-0000-0000-0000000000a1',NULL),
  ('bb000000-0000-0000-0000-0000000000e2','bb000000-0000-0000-0000-000000000001','BB Off','bb-off','cancelled',now() + interval '10 days','America/New_York',100,2,'bb000000-0000-0000-0000-0000000000a1','none');
INSERT INTO public.exos_ticket_tiers(id,event_id,name,price,capacity,sold,visibility) VALUES
  ('bb000000-0000-0000-0000-0000000000d1','bb000000-0000-0000-0000-0000000000e1','Guest list',0,50,0,'hidden'),
  ('bb000000-0000-0000-0000-0000000000d2','bb000000-0000-0000-0000-0000000000e1','RSVP',0,50,0,'public'),
  ('bb000000-0000-0000-0000-0000000000d3','bb000000-0000-0000-0000-0000000000e1','Crew',0,50,0,'hidden'),
  ('bb000000-0000-0000-0000-0000000000d4','bb000000-0000-0000-0000-0000000000e2','GA',30,100,2,'public');
INSERT INTO public.exos_vouchers(event_id,code,tier_id,max_uses) VALUES
  ('bb000000-0000-0000-0000-0000000000e1','BBLIST','bb000000-0000-0000-0000-0000000000d1',3),
  ('bb000000-0000-0000-0000-0000000000e1','BBCREW','bb000000-0000-0000-0000-0000000000d3',1);

-- B1. The hidden tier needs its own code.
SET LOCAL ROLE authenticated;
SELECT pg_temp.act('bb000000-0000-0000-0000-0000000000b1', 'bbfan@x.com');
SELECT set_config('bb.none',  pg_temp.err($$SELECT public.exos_claim_free_tickets(pg_temp.u('0000000000e1'), pg_temp.u('0000000000d1'), 1)$$), true),
       set_config('bb.wrong', pg_temp.err($$SELECT public.exos_claim_free_tickets(pg_temp.u('0000000000e1'), pg_temp.u('0000000000d1'), 1, p_voucher_code => 'NOPE')$$), true),
       set_config('bb.other', pg_temp.err($$SELECT public.exos_claim_free_tickets(pg_temp.u('0000000000e1'), pg_temp.u('0000000000d1'), 1, p_voucher_code => 'BBCREW')$$), true);
SELECT set_config('bb.ids', public.exos_claim_free_tickets(pg_temp.u('0000000000e1'), pg_temp.u('0000000000d1'), 2,
                    NULL, NULL, 'bb-claim-1', ' bblist ')::text, true);
RESET ROLE;
DO $$
BEGIN
  ASSERT current_setting('bb.none') LIKE '%tier not available%', 'B1: no code ' || current_setting('bb.none');
  ASSERT current_setting('bb.wrong') LIKE '%tier not available%', 'B1: wrong code ' || current_setting('bb.wrong');
  ASSERT current_setting('bb.other') LIKE '%tier not available%', 'B1: another tier''s code ' || current_setting('bb.other');
  ASSERT array_length(current_setting('bb.ids')::uuid[], 1) = 2, 'B1: two tickets ' || current_setting('bb.ids');
  ASSERT (SELECT count(*) FROM public.exos_tickets WHERE tier_id = pg_temp.u('0000000000d1')
           AND owner_id = pg_temp.u('0000000000b1') AND status = 'active' AND price_paid = 0) = 2, 'B1: minted to the fan';
  ASSERT (SELECT used_count FROM public.exos_vouchers WHERE code = 'BBLIST') = 2, 'B1: one use per ticket';
  ASSERT (SELECT used_count FROM public.exos_vouchers WHERE code = 'BBCREW') = 0, 'B1: the other code untouched';
  ASSERT (SELECT sold FROM public.exos_ticket_tiers WHERE id = pg_temp.u('0000000000d1')) = 2, 'B1: sold';
  RAISE NOTICE 'OK  B1 a hidden free tier claims with its own code';
END $$;

-- B2. Retry after the code is used up: same tickets, nothing more taken.
UPDATE public.exos_vouchers SET used_count = max_uses WHERE code = 'BBLIST';
SET LOCAL ROLE authenticated;
SELECT pg_temp.act('bb000000-0000-0000-0000-0000000000b1', 'bbfan@x.com');
SELECT set_config('bb.ids2', public.exos_claim_free_tickets(pg_temp.u('0000000000e1'), pg_temp.u('0000000000d1'), 2,
                    NULL, NULL, 'bb-claim-1', 'BBLIST')::text, true);
SELECT set_config('bb.spent', pg_temp.err($$SELECT public.exos_claim_free_tickets(pg_temp.u('0000000000e1'), pg_temp.u('0000000000d1'), 1, NULL, NULL, 'bb-claim-2', 'BBLIST')$$), true);
RESET ROLE;
DO $$
BEGIN
  ASSERT (SELECT array_agg(x ORDER BY x) FROM unnest(current_setting('bb.ids2')::uuid[]) x)
       = (SELECT array_agg(x ORDER BY x) FROM unnest(current_setting('bb.ids')::uuid[]) x), 'B2: same tickets back';
  ASSERT current_setting('bb.spent') LIKE '%tier not available%', 'B2: a new claim on a spent code ' || current_setting('bb.spent');
  ASSERT (SELECT sold FROM public.exos_ticket_tiers WHERE id = pg_temp.u('0000000000d1')) = 2, 'B2: nothing more sold';
  RAISE NOTICE 'OK  B2 a retry returns the claim already made';
END $$;

-- B3. A one-use code for two tickets.
SET LOCAL ROLE authenticated;
SELECT pg_temp.act('bb000000-0000-0000-0000-0000000000b2', 'bbfan2@x.com');
SELECT set_config('bb.short', pg_temp.err($$SELECT public.exos_claim_free_tickets(pg_temp.u('0000000000e1'), pg_temp.u('0000000000d3'), 2, p_voucher_code => 'BBCREW')$$), true);
RESET ROLE;
DO $$
BEGIN
  ASSERT current_setting('bb.short') LIKE '%doesn''t cover 2 tickets%', 'B3: refused ' || current_setting('bb.short');
  ASSERT (SELECT used_count FROM public.exos_vouchers WHERE code = 'BBCREW') = 0, 'B3: code not used';
  ASSERT (SELECT sold FROM public.exos_ticket_tiers WHERE id = pg_temp.u('0000000000d3')) = 0, 'B3: nothing sold';
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_tickets WHERE tier_id = pg_temp.u('0000000000d3')), 'B3: nothing minted';
  RAISE NOTICE 'OK  B3 a code that doesn''t cover the order takes nothing';
END $$;

-- B4. Public free tier, old-style call; one function, authenticated only.
SET LOCAL ROLE authenticated;
SELECT pg_temp.act('bb000000-0000-0000-0000-0000000000b2', 'bbfan2@x.com');
SELECT set_config('bb.pub', public.exos_claim_free_tickets(pg_temp.u('0000000000e1'), pg_temp.u('0000000000d2'), 1)::text, true);
RESET ROLE;
DO $$
BEGIN
  ASSERT array_length(current_setting('bb.pub')::uuid[], 1) = 1, 'B4: public tier without a code';
  ASSERT (SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
           WHERE n.nspname = 'public' AND p.proname = 'exos_claim_free_tickets') = 1, 'B4: one function';
  ASSERT has_function_privilege('authenticated', 'public.exos_claim_free_tickets(uuid, uuid, integer, text, text, text, text)', 'EXECUTE'), 'B4: authenticated';
  ASSERT NOT has_function_privilege('anon', 'public.exos_claim_free_tickets(uuid, uuid, integer, text, text, text, text)', 'EXECUTE'), 'B4: not anon';
  ASSERT position('SECURITY DEFINER' in pg_get_functiondef('public.exos_claim_free_tickets(uuid, uuid, integer, text, text, text, text)'::regprocedure)) > 0
     AND position('ticket-backend' in pg_get_functiondef('public.exos_claim_free_tickets(uuid, uuid, integer, text, text, text, text)'::regprocedure)) > 0,
         'B4: body kept (definer, backend gate)';
  RAISE NOTICE 'OK  B4 public free claims unchanged';
END $$;

-- B5. Cancelled event: the payer can ask, even with all sales final.
INSERT INTO public.exos_checkout_sessions(session_id,event_id,tier_id,org_id,buyer_uid,buyer_email,quantity,amount_cents,status,payment_intent,guest,created_at) VALUES
  ('cs_bb1','bb000000-0000-0000-0000-0000000000e2','bb000000-0000-0000-0000-0000000000d4','bb000000-0000-0000-0000-000000000001','bb000000-0000-0000-0000-0000000000b1','bbfan@x.com',2,6000,'fulfilled','pi_bb1',false,now() - interval '2 days');
SELECT public.exos_record_payment('cs_bb1', 'pi_bb1', 6000, 'succeeded');
INSERT INTO public.exos_tickets(id,event_id,org_id,tier_id,tier_name,buyer_id,owner_id,buyer_email,status,barcode_secret,price_paid,order_ref,channel_source) VALUES
  ('bb000000-0000-0000-0000-000000000c11','bb000000-0000-0000-0000-0000000000e2','bb000000-0000-0000-0000-000000000001','bb000000-0000-0000-0000-0000000000d4','GA','bb000000-0000-0000-0000-0000000000b1','bb000000-0000-0000-0000-0000000000b1','bbfan@x.com','active','kbb11',30,'cs_bb1','stripe'),
  ('bb000000-0000-0000-0000-000000000c12','bb000000-0000-0000-0000-0000000000e2','bb000000-0000-0000-0000-000000000001','bb000000-0000-0000-0000-0000000000d4','GA','bb000000-0000-0000-0000-0000000000b1','bb000000-0000-0000-0000-0000000000b1','bbfan@x.com','voided','kbb12',30,'cs_bb1','stripe');
SET LOCAL ROLE authenticated;
SELECT pg_temp.act('bb000000-0000-0000-0000-0000000000b1', 'bbfan@x.com');
SELECT set_config('bb.ask', public.exos_ask_refund(ARRAY[pg_temp.u('000000000c11'), pg_temp.u('000000000c12')], 'Event cancelled')::text, true);
SELECT set_config('bb.mine', (SELECT json_agg(m)::text FROM public.exos_my_refund_asks(pg_temp.u('0000000000e2')) m), true);
RESET ROLE;
DO $$
DECLARE j jsonb := current_setting('bb.ask')::jsonb;
        a jsonb := (SELECT x FROM jsonb_array_elements(j) x WHERE x->>'ticket_id' = pg_temp.u('000000000c11')::text);
        b jsonb := (SELECT x FROM jsonb_array_elements(j) x WHERE x->>'ticket_id' = pg_temp.u('000000000c12')::text);
BEGIN
  ASSERT (a->>'ok')::boolean, 'B5: cancelled event, all sales final: may ask ' || j::text;
  ASSERT (a->>'amount_cents')::int = 3000, 'B5: the ticket''s share';
  ASSERT b->>'reason' = 'voided', 'B5: a voided ticket still can''t ' || j::text;
  ASSERT (SELECT status FROM public.exos_refund_asks WHERE ticket_id = pg_temp.u('000000000c11')) = 'open', 'B5: ask open';
  ASSERT current_setting('bb.mine') IS NOT NULL AND position('event-cancelled' in current_setting('bb.mine')) = 0, 'B5: no event-cancelled refusal';
  RAISE NOTICE 'OK  B5 a cancelled event''s buyer can ask for a refund';
END $$;

\echo 'test_buyer_p1: all passed'
ROLLBACK;
