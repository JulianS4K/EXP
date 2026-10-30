-- ============================================================================
-- Season passes, flex packs and memberships (mig 20261030130500).
-- Self-contained (c7… ids), rolled back at the end.
--   M1 RLS and grants: products (owner / manager write, finance reads, `sold`
--      server-kept), passes / memberships (holder + staff read, no client
--      writes, gift token hash unreadable), credit ledgers service only
--   M2 buying a pass (exos_commerce_fulfill): credits from the product, sold
--      counted, sold out -> failed (the webhook refunds)
--   M3 using a pass: $0 tickets through the normal fulfillment, credits taken in
--      the same transaction; same request id = same tickets; per-event limit;
--      uncovered event / tier refused; someone else's pass refused; a sold-out
--      tier takes no credit; the last credit can't be spent twice
--   M4 subscriptions: purchase -> active; invoice.paid renews; past_due; deleted
--      -> cancelled; a stale event doesn't bring it back
--   M5 member price + presale (exos_member_checkout): discount, presale gate,
--      product filter; benefits end with the period
--   M6 free tickets per period, households (seats cap, confirmed email)
--   M7 gifts: pending + claim mail; claim once with the token; cancel
--   M8 door lookup of a membership card (no email; other org refused)
--   M9 one-time terms stack; refunds void the pass / cancel the membership
--   M10 cross-org isolation
--   psql -d <db> -v ON_ERROR_STOP=1 -f tests/exos/test_passes_memberships.sql
-- ============================================================================
\set ON_ERROR_STOP on
BEGIN;

INSERT INTO auth.users (id, email, email_confirmed_at) VALUES
  ('c7000000-0000-0000-0000-0000000000a0', 'c7-owner@x.com', now()),
  ('c7000000-0000-0000-0000-0000000000a1', 'c7-manager@x.com', now()),
  ('c7000000-0000-0000-0000-0000000000a2', 'c7-finance@x.com', now()),
  ('c7000000-0000-0000-0000-0000000000a3', 'c7-scanner@x.com', now()),
  ('c7000000-0000-0000-0000-0000000000a5', 'c7-fan@x.com', now()),
  ('c7000000-0000-0000-0000-0000000000a6', 'c7-partner@x.com', now()),
  ('c7000000-0000-0000-0000-0000000000a7', 'c7-friend@x.com', now()),
  ('c7000000-0000-0000-0000-0000000000a8', 'c7-unconfirmed@x.com', NULL),
  ('c7000000-0000-0000-0000-0000000000b9', 'c7-other-owner@x.com', now());
INSERT INTO public.exos_orgs (id, name, slug, owner_uid) VALUES
  ('c7000000-0000-0000-0000-000000000001', 'C7 Org', 'c7-org', 'c7000000-0000-0000-0000-0000000000a0'),
  ('c7000000-0000-0000-0000-000000000002', 'C7 Other', 'c7-other', 'c7000000-0000-0000-0000-0000000000b9');
INSERT INTO public.exos_org_memberships (org_id, user_id, role) VALUES
  ('c7000000-0000-0000-0000-000000000001', 'c7000000-0000-0000-0000-0000000000a0', 'owner'),
  ('c7000000-0000-0000-0000-000000000001', 'c7000000-0000-0000-0000-0000000000a1', 'manager'),
  ('c7000000-0000-0000-0000-000000000001', 'c7000000-0000-0000-0000-0000000000a2', 'finance'),
  ('c7000000-0000-0000-0000-000000000001', 'c7000000-0000-0000-0000-0000000000a3', 'scanner'),
  ('c7000000-0000-0000-0000-000000000002', 'c7000000-0000-0000-0000-0000000000b9', 'owner');
INSERT INTO public.exos_events (id, org_id, name, slug, status, starts_at) VALUES
  ('c7000000-0000-0000-0000-0000000000e1', 'c7000000-0000-0000-0000-000000000001', 'C7 One', 'c7-one', 'published', now() + interval '5 days'),
  ('c7000000-0000-0000-0000-0000000000e2', 'c7000000-0000-0000-0000-000000000001', 'C7 Two', 'c7-two', 'published', now() + interval '10 days'),
  ('c7000000-0000-0000-0000-0000000000e3', 'c7000000-0000-0000-0000-000000000001', 'C7 Late', 'c7-late', 'published', now() + interval '400 days'),
  ('c7000000-0000-0000-0000-0000000000e9', 'c7000000-0000-0000-0000-000000000002', 'C7 Theirs', 'c7-theirs', 'published', now() + interval '5 days');
INSERT INTO public.exos_ticket_tiers (id, event_id, name, price, capacity, sold, visibility) VALUES
  ('c7000000-0000-0000-0000-0000000000d1', 'c7000000-0000-0000-0000-0000000000e1', 'GA', 30, 100, 0, 'public'),
  ('c7000000-0000-0000-0000-0000000000d2', 'c7000000-0000-0000-0000-0000000000e1', 'VIP', 90, 100, 0, 'public'),
  ('c7000000-0000-0000-0000-0000000000d3', 'c7000000-0000-0000-0000-0000000000e2', 'GA', 30, 1, 1, 'public'),
  ('c7000000-0000-0000-0000-0000000000d4', 'c7000000-0000-0000-0000-0000000000e2', 'Floor', 30, 100, 0, 'public'),
  ('c7000000-0000-0000-0000-0000000000d5', 'c7000000-0000-0000-0000-0000000000e3', 'GA', 30, 100, 0, 'public'),
  ('c7000000-0000-0000-0000-0000000000d9', 'c7000000-0000-0000-0000-0000000000e9', 'GA', 30, 100, 0, 'public');

CREATE FUNCTION pg_temp.act(p_uid text) RETURNS void LANGUAGE sql AS $$
  SELECT set_config('app.uid', coalesce(p_uid, ''), true), set_config('app.jwt', '', true);
$$;
GRANT EXECUTE ON FUNCTION pg_temp.act(text) TO anon, authenticated, service_role;
GRANT SELECT ON public.exos_mail, public.exos_tickets, public.exos_checkout_sessions TO service_role;

-- M1 -------------------------------------------------------------------------
SET ROLE authenticated;
DO $$
DECLARE n int; refused boolean;
BEGIN
  PERFORM pg_temp.act('c7000000-0000-0000-0000-0000000000a1');  -- manager
  INSERT INTO public.exos_pass_products (id, org_id, kind, name, price_cents, event_ids, per_event_limit)
  VALUES ('c7000000-0000-0000-0000-00000000f001', 'c7000000-0000-0000-0000-000000000001', 'season', 'Fall season', 5000,
          ARRAY['c7000000-0000-0000-0000-0000000000e1', 'c7000000-0000-0000-0000-0000000000e2']::uuid[], 1);
  INSERT INTO public.exos_pass_products (id, org_id, kind, name, price_cents, credits, max_sold)
  VALUES ('c7000000-0000-0000-0000-00000000f002', 'c7000000-0000-0000-0000-000000000001', 'flex', '3-pack', 7500, 3, 1);
  INSERT INTO public.exos_pass_products (id, org_id, kind, name, price_cents, date_from, date_to, tier_ids)
  VALUES ('c7000000-0000-0000-0000-00000000f003', 'c7000000-0000-0000-0000-000000000001', 'season', 'Year GA', 9000,
          now(), now() + interval '30 days',
          ARRAY['c7000000-0000-0000-0000-0000000000d1', 'c7000000-0000-0000-0000-0000000000d3', 'c7000000-0000-0000-0000-0000000000d4']::uuid[]);
  INSERT INTO public.exos_membership_products (id, org_id, name, price_cents, billing, discount_percent, presale,
    free_tickets_per_period, guest_allowance, household_seats)
  VALUES ('c7000000-0000-0000-0000-00000000a001', 'c7000000-0000-0000-0000-000000000001', 'Member', 1000, 'month', 10, true, 1, 1, 1),
         ('c7000000-0000-0000-0000-00000000a002', 'c7000000-0000-0000-0000-000000000001', 'Annual', 10000, 'once', 20, false, 0, 0, 0);
  refused := false;
  BEGIN
    UPDATE public.exos_pass_products SET sold = 0 + 5 WHERE id = 'c7000000-0000-0000-0000-00000000f001';
  EXCEPTION WHEN insufficient_privilege THEN refused := true;
  END;
  ASSERT refused, 'M1: sold is server-kept';
  refused := false;
  BEGIN
    UPDATE public.exos_membership_products SET billing = 'year' WHERE id = 'c7000000-0000-0000-0000-00000000a001';
  EXCEPTION WHEN invalid_parameter_value THEN refused := true;
  END;
  ASSERT refused, 'M1: billing can''t change';

  PERFORM pg_temp.act('c7000000-0000-0000-0000-0000000000a2');  -- finance
  ASSERT (SELECT count(*) FROM public.exos_pass_products) = 3 AND (SELECT count(*) FROM public.exos_membership_products) = 2, 'M1: finance reads';
  UPDATE public.exos_membership_products SET price_cents = 1;
  GET DIAGNOSTICS n = ROW_COUNT;
  ASSERT n = 0, 'M1: finance can''t edit';
  PERFORM pg_temp.act('c7000000-0000-0000-0000-0000000000a3');  -- scanner
  ASSERT (SELECT count(*) FROM public.exos_membership_products) = 0, 'M1: scanner sees no products';
  RAISE NOTICE 'OK  M1 product RLS';
END $$;
DO $$
BEGIN
  ASSERT NOT has_table_privilege('authenticated', 'public.exos_passes', 'INSERT'), 'M1: no client insert on passes';
  ASSERT NOT has_table_privilege('authenticated', 'public.exos_fan_memberships', 'UPDATE'), 'M1: no client update on memberships';
  ASSERT NOT has_column_privilege('authenticated', 'public.exos_fan_memberships', 'gift_token_hash', 'SELECT'), 'M1: gift token hash unreadable';
  ASSERT NOT has_table_privilege('authenticated', 'public.exos_pass_redemptions', 'SELECT'), 'M1: pass ledger service only';
  ASSERT NOT has_table_privilege('authenticated', 'public.exos_membership_redemptions', 'SELECT'), 'M1: member ledger service only';
  ASSERT NOT has_table_privilege('authenticated', 'public.exos_member_presales', 'INSERT'), 'M1: presales via the RPC only';
  ASSERT NOT has_function_privilege('authenticated', 'public.exos_member_checkout(uuid,uuid,uuid)', 'EXECUTE'), 'M1: member checkout is service only';
  ASSERT NOT has_function_privilege('authenticated', 'public.exos_membership_sync(text,text,text,timestamptz,boolean)', 'EXECUTE'), 'M1: sync is service only';
  ASSERT NOT has_function_privilege('authenticated', 'public._exos_credit_order(text,uuid,uuid,uuid,uuid,integer,uuid,uuid)', 'EXECUTE'), 'M1: internal credit order';
  ASSERT NOT has_function_privilege('anon', 'public.exos_pass_redeem(uuid,uuid,uuid,integer,uuid)', 'EXECUTE'), 'M1: anon can''t redeem';
  RAISE NOTICE 'OK  M1 grants';
END $$;
RESET ROLE;
SET ROLE anon;
DO $$
BEGIN
  ASSERT (SELECT count(*) FROM public.exos_public_pass_products WHERE org_slug = 'c7-org') = 3, 'M1: public passes';
  ASSERT (SELECT count(*) FROM public.exos_public_membership_products WHERE org_slug = 'c7-org') = 2, 'M1: public memberships';
END $$;
RESET ROLE;

-- M2 -------------------------------------------------------------------------
INSERT INTO public.exos_commerce_orders (session_id, org_id, kind, product_id, buyer_uid, buyer_email, amount_cents, currency) VALUES
  ('cs_c7_p1', 'c7000000-0000-0000-0000-000000000001', 'pass', 'c7000000-0000-0000-0000-00000000f001', 'c7000000-0000-0000-0000-0000000000a5', 'c7-fan@x.com', 5000, 'usd'),
  ('cs_c7_p2', 'c7000000-0000-0000-0000-000000000001', 'pass', 'c7000000-0000-0000-0000-00000000f002', 'c7000000-0000-0000-0000-0000000000a5', 'c7-fan@x.com', 7500, 'usd'),
  ('cs_c7_p3', 'c7000000-0000-0000-0000-000000000001', 'pass', 'c7000000-0000-0000-0000-00000000f002', 'c7000000-0000-0000-0000-0000000000a6', 'c7-partner@x.com', 7500, 'usd'),
  ('cs_c7_p4', 'c7000000-0000-0000-0000-000000000001', 'pass', 'c7000000-0000-0000-0000-00000000f003', 'c7000000-0000-0000-0000-0000000000a5', 'c7-fan@x.com', 9000, 'usd');
CREATE TEMP TABLE c7 (k text PRIMARY KEY, v text);
GRANT ALL ON c7 TO authenticated, service_role;
SET ROLE service_role;
DO $$
BEGIN
  ASSERT public.exos_commerce_fulfill('cs_c7_p1', 'pi_c7_p1', 5000) = 'fulfilled', 'M2: season pass';
  ASSERT public.exos_commerce_fulfill('cs_c7_p1', 'pi_c7_p1', 5000) = 'fulfilled', 'M2: replay';
  ASSERT public.exos_commerce_fulfill('cs_c7_p2', 'pi_c7_p2', 7500) = 'fulfilled', 'M2: flex pack';
  ASSERT public.exos_commerce_fulfill('cs_c7_p3', 'pi_c7_p3', 7500) = 'failed', 'M2: the flex pack sold out (max 1)';
  ASSERT public.exos_commerce_fulfill('cs_c7_p4', 'pi_c7_p4', 9000) = 'fulfilled', 'M2: date-range pass';
  INSERT INTO c7 SELECT 'season', result_id::text FROM public.exos_commerce_orders WHERE session_id = 'cs_c7_p1';
  INSERT INTO c7 SELECT 'flex', result_id::text FROM public.exos_commerce_orders WHERE session_id = 'cs_c7_p2';
  INSERT INTO c7 SELECT 'range', result_id::text FROM public.exos_commerce_orders WHERE session_id = 'cs_c7_p4';
END $$;
RESET ROLE;
DO $$
BEGIN
  ASSERT (SELECT credits_total FROM public.exos_passes WHERE id = (SELECT v::uuid FROM c7 WHERE k = 'season')) = 2, 'M2: two named events = 2 credits';
  ASSERT (SELECT credits_total FROM public.exos_passes WHERE id = (SELECT v::uuid FROM c7 WHERE k = 'flex')) = 3, 'M2: flex = 3';
  ASSERT (SELECT credits_total IS NULL FROM public.exos_passes WHERE id = (SELECT v::uuid FROM c7 WHERE k = 'range')), 'M2: range = no total';
  ASSERT (SELECT sold FROM public.exos_pass_products WHERE id = 'c7000000-0000-0000-0000-00000000f002') = 1, 'M2: sold counted once';
  ASSERT (SELECT count(*) FROM public.exos_passes WHERE session_id = 'cs_c7_p1') = 1, 'M2: one pass per order';
  RAISE NOTICE 'OK  M2 buying passes';
END $$;

-- M3 -------------------------------------------------------------------------
SET ROLE authenticated;
DO $$
DECLARE r jsonb; r2 jsonb; refused boolean; season uuid := (SELECT v::uuid FROM c7 WHERE k = 'season');
        flex uuid := (SELECT v::uuid FROM c7 WHERE k = 'flex'); range uuid := (SELECT v::uuid FROM c7 WHERE k = 'range');
BEGIN
  PERFORM pg_temp.act('c7000000-0000-0000-0000-0000000000a5');
  r := public.exos_pass_redeem(season, 'c7000000-0000-0000-0000-0000000000e1', 'c7000000-0000-0000-0000-0000000000d1', 1,
                               'c7000000-0000-0000-0000-0000000001a1');
  ASSERT jsonb_array_length(r->'ticket_ids') = 1 AND (r->>'fresh')::boolean, 'M3: one ticket ' || r::text;
  INSERT INTO c7 VALUES ('t1', r->'ticket_ids'->>0);
  r2 := public.exos_pass_redeem(season, 'c7000000-0000-0000-0000-0000000000e1', 'c7000000-0000-0000-0000-0000000000d1', 1,
                                'c7000000-0000-0000-0000-0000000001a1');
  ASSERT NOT (r2->>'fresh')::boolean AND r2->'ticket_ids' = r->'ticket_ids', 'M3: same request, same tickets';
  -- Per-event limit 1.
  refused := false;
  BEGIN
    r := public.exos_pass_redeem(season, 'c7000000-0000-0000-0000-0000000000e1', 'c7000000-0000-0000-0000-0000000000d1', 1,
                                 'c7000000-0000-0000-0000-0000000001a2');
    refused := r->>'error' LIKE '%limit for this event%';
  END;
  ASSERT refused, 'M3: the per-event limit holds';
  -- Not a named event.
  refused := false;
  BEGIN PERFORM public.exos_pass_redeem(season, 'c7000000-0000-0000-0000-0000000000e3', 'c7000000-0000-0000-0000-0000000000d5', 1,
                                        'c7000000-0000-0000-0000-0000000001a3');
  EXCEPTION WHEN raise_exception THEN refused := true; END;
  ASSERT refused, 'M3: uncovered event refused';
  -- Range pass: tier not covered, event out of range.
  refused := false;
  BEGIN PERFORM public.exos_pass_redeem(range, 'c7000000-0000-0000-0000-0000000000e1', 'c7000000-0000-0000-0000-0000000000d2', 1,
                                        'c7000000-0000-0000-0000-0000000001a4');
  EXCEPTION WHEN raise_exception THEN refused := true; END;
  ASSERT refused, 'M3: tier not covered';
  refused := false;
  BEGIN PERFORM public.exos_pass_redeem(range, 'c7000000-0000-0000-0000-0000000000e3', 'c7000000-0000-0000-0000-0000000000d5', 1,
                                        'c7000000-0000-0000-0000-0000000001a5');
  EXCEPTION WHEN raise_exception THEN refused := true; END;
  ASSERT refused, 'M3: out of the date range';
  -- Sold-out tier: no ticket and no credit taken.
  r := public.exos_pass_redeem(season, 'c7000000-0000-0000-0000-0000000000e2', 'c7000000-0000-0000-0000-0000000000d3', 1,
                               'c7000000-0000-0000-0000-0000000001a6');
  ASSERT r->>'error' LIKE '%sold out%', 'M3: sold out ' || r::text;
  -- Flex: 3 credits, 2 + 1 then nothing left.
  r := public.exos_pass_redeem(flex, 'c7000000-0000-0000-0000-0000000000e2', 'c7000000-0000-0000-0000-0000000000d4', 2,
                               'c7000000-0000-0000-0000-0000000001b1');
  ASSERT jsonb_array_length(r->'ticket_ids') = 2, 'M3: flex 2';
  r := public.exos_pass_redeem(flex, 'c7000000-0000-0000-0000-0000000000e1', 'c7000000-0000-0000-0000-0000000000d1', 1,
                               'c7000000-0000-0000-0000-0000000001b2');
  ASSERT jsonb_array_length(r->'ticket_ids') = 1, 'M3: flex last credit';
  r := public.exos_pass_redeem(flex, 'c7000000-0000-0000-0000-0000000000e1', 'c7000000-0000-0000-0000-0000000000d1', 1,
                               'c7000000-0000-0000-0000-0000000001b3');
  ASSERT r->>'error' LIKE '%admissions left%', 'M3: the last credit can''t be spent twice ' || r::text;
  -- Someone else's pass.
  PERFORM pg_temp.act('c7000000-0000-0000-0000-0000000000a6');
  refused := false;
  BEGIN PERFORM public.exos_pass_redeem(season, 'c7000000-0000-0000-0000-0000000000e2', 'c7000000-0000-0000-0000-0000000000d4', 1,
                                        'c7000000-0000-0000-0000-0000000001c1');
  EXCEPTION WHEN no_data_found THEN refused := true; END;
  ASSERT refused, 'M3: someone else''s pass';
  -- Reusing another account's request id doesn't return their tickets.
  refused := false;
  BEGIN PERFORM public.exos_pass_redeem(season, 'c7000000-0000-0000-0000-0000000000e1', 'c7000000-0000-0000-0000-0000000000d1', 1,
                                        'c7000000-0000-0000-0000-0000000001a1');
  EXCEPTION WHEN no_data_found THEN refused := true; END;
  ASSERT refused, 'M3: not their pass anyway';
  RAISE NOTICE 'OK  M3 using passes';
END $$;
RESET ROLE;
DO $$
DECLARE flex uuid := (SELECT v::uuid FROM c7 WHERE k = 'flex'); season uuid := (SELECT v::uuid FROM c7 WHERE k = 'season');
BEGIN
  ASSERT (SELECT credits_used FROM public.exos_passes WHERE id = flex) = 3, 'M3: flex credits used = 3';
  ASSERT (SELECT credits_used FROM public.exos_passes WHERE id = season) = 1, 'M3: season used 1 (sold out took none)';
  ASSERT (SELECT sum(quantity) FROM public.exos_pass_redemptions WHERE pass_id = flex) = 3, 'M3: ledger = credits used';
  ASSERT (SELECT price_paid = 0 AND status = 'active' AND owner_id = 'c7000000-0000-0000-0000-0000000000a5'
            FROM public.exos_tickets WHERE id = (SELECT v::uuid FROM c7 WHERE k = 't1')), 'M3: a $0 ticket the holder owns';
  ASSERT (SELECT sold FROM public.exos_ticket_tiers WHERE id = 'c7000000-0000-0000-0000-0000000000d1') = 2, 'M3: counts toward capacity';
  ASSERT (SELECT redemption FROM public.exos_checkout_sessions WHERE session_id = 'pass_c70000000000000000000000000001a1') = 'pass', 'M3: order marked as a pass redemption';
  RAISE NOTICE 'OK  M3 ledgers';
END $$;

-- M4 -------------------------------------------------------------------------
INSERT INTO public.exos_commerce_orders (session_id, org_id, kind, product_id, buyer_uid, buyer_email, amount_cents, currency, stripe_customer_id) VALUES
  ('cs_c7_m1', 'c7000000-0000-0000-0000-000000000001', 'membership', 'c7000000-0000-0000-0000-00000000a001',
   'c7000000-0000-0000-0000-0000000000a5', 'c7-fan@x.com', 1000, 'usd', 'cus_c7fan');
SET ROLE service_role;
DO $$
DECLARE m uuid; st text;
BEGIN
  ASSERT public.exos_commerce_fulfill('cs_c7_m1', NULL, 1000, 'sub_c7fan', now() + interval '1 month') = 'fulfilled', 'M4: subscription bought';
  SELECT result_id INTO m FROM public.exos_commerce_orders WHERE session_id = 'cs_c7_m1';
  INSERT INTO c7 VALUES ('m1', m::text);
  ASSERT public.exos_membership_sync('sub_unknown', 'invoice_paid', 'active', now()) = 'unknown', 'M4: unknown subscription ignored';
  st := public.exos_membership_sync('sub_c7fan', 'invoice_paid', NULL, now() + interval '2 months');
  ASSERT st = 'active', 'M4: renewed';
  st := public.exos_membership_sync('sub_c7fan', 'updated', 'past_due', now() + interval '2 months', false);
  ASSERT st = 'past_due', 'M4: past due';
  st := public.exos_membership_sync('sub_c7fan', 'updated', 'active', now() + interval '2 months', true);
  ASSERT st = 'active', 'M4: paid again, cancel at period end';
END $$;
RESET ROLE;
DO $$
DECLARE m public.exos_fan_memberships%ROWTYPE;
BEGIN
  SELECT * INTO m FROM public.exos_fan_memberships WHERE id = (SELECT v::uuid FROM c7 WHERE k = 'm1');
  ASSERT m.holder_uid = 'c7000000-0000-0000-0000-0000000000a5' AND m.stripe_customer_id = 'cus_c7fan'
     AND m.current_period_end > now() + interval '55 days' AND m.cancel_at_period_end, 'M4: membership row';
  ASSERT (m.benefits->>'discount_percent')::numeric = 10, 'M4: benefits snapshot';
  -- Editing the product never changes the member.
  UPDATE public.exos_membership_products SET discount_percent = 50 WHERE id = 'c7000000-0000-0000-0000-00000000a001';
  ASSERT (SELECT (benefits->>'discount_percent')::numeric FROM public.exos_fan_memberships WHERE id = m.id) = 10, 'M4: snapshot kept';
  RAISE NOTICE 'OK  M4 subscription lifecycle';
END $$;

-- M5 -------------------------------------------------------------------------
-- A member presale on e1's VIP for presale products.
SET ROLE authenticated;
DO $$
BEGIN
  PERFORM pg_temp.act('c7000000-0000-0000-0000-0000000000a1');
  PERFORM public.exos_set_member_presale('c7000000-0000-0000-0000-0000000000e1', NULL, now() + interval '1 day',
    ARRAY['c7000000-0000-0000-0000-0000000000d2']::uuid[], '{}');
END $$;
RESET ROLE;
SET ROLE service_role;
DO $$
DECLARE r jsonb;
BEGIN
  r := public.exos_member_checkout('c7000000-0000-0000-0000-0000000000e1', 'c7000000-0000-0000-0000-0000000000d1', 'c7000000-0000-0000-0000-0000000000a5');
  ASSERT NOT (r->>'presale_blocked')::boolean AND (r->>'discount_percent')::numeric = 10 AND (r->>'guest_allowance')::int = 1, 'M5: member price ' || r::text;
  r := public.exos_member_checkout('c7000000-0000-0000-0000-0000000000e1', 'c7000000-0000-0000-0000-0000000000d1', 'c7000000-0000-0000-0000-0000000000a6');
  ASSERT r->>'discount_percent' IS NULL, 'M5: non-member pays the regular price';
  r := public.exos_member_checkout('c7000000-0000-0000-0000-0000000000e1', 'c7000000-0000-0000-0000-0000000000d2', 'c7000000-0000-0000-0000-0000000000a6');
  ASSERT (r->>'presale_blocked')::boolean, 'M5: presale blocks a non-member';
  r := public.exos_member_checkout('c7000000-0000-0000-0000-0000000000e1', 'c7000000-0000-0000-0000-0000000000d2', NULL);
  ASSERT (r->>'presale_blocked')::boolean, 'M5: presale blocks a guest';
  r := public.exos_member_checkout('c7000000-0000-0000-0000-0000000000e1', 'c7000000-0000-0000-0000-0000000000d2', 'c7000000-0000-0000-0000-0000000000a5');
  ASSERT NOT (r->>'presale_blocked')::boolean, 'M5: the member is in';
END $$;
RESET ROLE;
-- The presale also gates pass redemptions.
SET ROLE authenticated;
DO $$
DECLARE refused boolean := false;
BEGIN
  PERFORM pg_temp.act('c7000000-0000-0000-0000-0000000000a6');
  INSERT INTO c7 VALUES ('dummy', 'x');
  BEGIN
    PERFORM public.exos_set_member_presale('c7000000-0000-0000-0000-0000000000e1', NULL, now() + interval '1 day');
  EXCEPTION WHEN insufficient_privilege THEN refused := true;
  END;
  ASSERT refused, 'M5: only owner / manager set presales';
  RAISE NOTICE 'OK  M5 member price + presale';
END $$;
RESET ROLE;

-- M6 -------------------------------------------------------------------------
SET ROLE authenticated;
DO $$
DECLARE r jsonb; refused boolean; m uuid := (SELECT v::uuid FROM c7 WHERE k = 'm1'); n int;
BEGIN
  -- One free redemption per period, up to 1 + 1 guest.
  PERFORM pg_temp.act('c7000000-0000-0000-0000-0000000000a5');
  refused := false;
  BEGIN
    r := public.exos_membership_redeem(m, 'c7000000-0000-0000-0000-0000000000e2', 'c7000000-0000-0000-0000-0000000000d4', 3,
                                       'c7000000-0000-0000-0000-0000000002a0');
    refused := r->>'error' LIKE '%more tickets%';
  END;
  ASSERT refused, 'M6: 3 > 1 + guest';
  r := public.exos_membership_redeem(m, 'c7000000-0000-0000-0000-0000000000e2', 'c7000000-0000-0000-0000-0000000000d4', 2,
                                     'c7000000-0000-0000-0000-0000000002a1');
  ASSERT jsonb_array_length(r->'ticket_ids') = 2, 'M6: member + guest free ' || r::text;
  r := public.exos_membership_redeem(m, 'c7000000-0000-0000-0000-0000000000e2', 'c7000000-0000-0000-0000-0000000000d4', 1,
                                     'c7000000-0000-0000-0000-0000000002a2');
  ASSERT r->>'error' LIKE '%no free tickets left%', 'M6: one per period';
  -- Household: one seat.
  n := public.exos_membership_household_set(m, 'C7-Partner@x.com');
  ASSERT n = 1, 'M6: partner added';
  refused := false;
  BEGIN PERFORM public.exos_membership_household_set(m, 'c7-friend@x.com');
  EXCEPTION WHEN raise_exception THEN refused := true; END;
  ASSERT refused, 'M6: seats cap';
  -- The partner shares the benefits; someone not on it doesn't.
  PERFORM pg_temp.act('c7000000-0000-0000-0000-0000000000a6');
  ASSERT (public.exos_my_member_benefit('c7000000-0000-0000-0000-000000000001')->>'discount_percent')::numeric = 10, 'M6: household gets the member price';
  ASSERT (SELECT count(*) FROM public.exos_my_memberships() WHERE shared AND billing IS NULL) = 1, 'M6: shared row without billing';
  refused := false;
  BEGIN PERFORM public.exos_membership_household_set(m, 'c7-friend@x.com');
  EXCEPTION WHEN no_data_found THEN refused := true; END;
  ASSERT refused, 'M6: only the holder manages the household';
  PERFORM pg_temp.act('c7000000-0000-0000-0000-0000000000a7');
  ASSERT public.exos_my_member_benefit('c7000000-0000-0000-0000-000000000001') IS NULL, 'M6: not on it';
  RAISE NOTICE 'OK  M6 free tickets + household';
END $$;
RESET ROLE;
-- An unconfirmed email never gets household benefits.
DO $$
DECLARE m uuid := (SELECT v::uuid FROM c7 WHERE k = 'm1');
BEGIN
  INSERT INTO public.exos_membership_household (membership_id, email) VALUES (m, 'c7-unconfirmed@x.com');
  ASSERT public._exos_member_best('c7000000-0000-0000-0000-000000000001', 'c7000000-0000-0000-0000-0000000000a8') IS NULL
      OR (public._exos_member_best('c7000000-0000-0000-0000-000000000001', 'c7000000-0000-0000-0000-0000000000a8')).id IS NULL,
    'M6: unconfirmed email ignored';
  DELETE FROM public.exos_membership_household WHERE email = 'c7-unconfirmed@x.com';
  -- Benefits end with the period (cancelled at period end, period over).
  UPDATE public.exos_fan_memberships SET status = 'cancelled', current_period_end = now() - interval '1 minute' WHERE id = m;
  ASSERT (public._exos_member_best('c7000000-0000-0000-0000-000000000001', 'c7000000-0000-0000-0000-0000000000a5')).id IS NULL,
    'M6: no benefits after the paid period';
  UPDATE public.exos_fan_memberships SET status = 'active', current_period_end = now() + interval '2 months' WHERE id = m;
END $$;

-- M7 -------------------------------------------------------------------------
INSERT INTO public.exos_commerce_orders (session_id, org_id, kind, product_id, buyer_uid, buyer_email, amount_cents, currency, details) VALUES
  ('cs_c7_g1', 'c7000000-0000-0000-0000-000000000001', 'membership', 'c7000000-0000-0000-0000-00000000a001',
   'c7000000-0000-0000-0000-0000000000a5', 'c7-fan@x.com', 1000, 'usd',
   '{"gift_to_email":"c7-friend@x.com","gift_from_name":"Fan","gift_message":"Enjoy"}');
SET ROLE service_role;
DO $$
BEGIN
  ASSERT public.exos_commerce_fulfill('cs_c7_g1', 'pi_c7_g1', 1000) = 'fulfilled', 'M7: gift bought';
  INSERT INTO c7 SELECT 'g1', result_id::text FROM public.exos_commerce_orders WHERE session_id = 'cs_c7_g1';
  INSERT INTO c7 SELECT 'g1tok', substring(html from 'token=([0-9a-f]{64})') FROM public.exos_mail
   WHERE template = 'membership-gift' AND to_email = 'c7-friend@x.com';
END $$;
RESET ROLE;
DO $$
BEGIN
  ASSERT (SELECT status = 'pending' AND holder_uid IS NULL AND billing = 'once' FROM public.exos_fan_memberships WHERE id = (SELECT v::uuid FROM c7 WHERE k = 'g1')), 'M7: pending gift';
  ASSERT (SELECT v FROM c7 WHERE k = 'g1tok') ~ '^[0-9a-f]{64}$', 'M7: claim link mailed';
  ASSERT (SELECT gift_token_hash <> (SELECT v FROM c7 WHERE k = 'g1tok') FROM public.exos_fan_memberships WHERE id = (SELECT v::uuid FROM c7 WHERE k = 'g1')), 'M7: only the hash stored';
END $$;
SET ROLE authenticated;
DO $$
DECLARE v_id uuid; refused boolean := false; tok text := (SELECT v FROM c7 WHERE k = 'g1tok'); g uuid;
BEGIN
  PERFORM pg_temp.act('c7000000-0000-0000-0000-0000000000a7');
  v_id := public.exos_membership_claim_gift(tok);
  ASSERT v_id = (SELECT v::uuid FROM c7 WHERE k = 'g1'), 'M7: claimed';
  BEGIN PERFORM public.exos_membership_claim_gift(tok);
  EXCEPTION WHEN raise_exception THEN refused := true; END;
  ASSERT refused, 'M7: claim once';
  ASSERT (public.exos_my_member_benefit('c7000000-0000-0000-0000-000000000001')->>'membership_id')::uuid = v_id, 'M7: the friend is a member';
  -- Staff comp gift, then cancel it before it's claimed.
  PERFORM pg_temp.act('c7000000-0000-0000-0000-0000000000a0');
  g := public.exos_membership_gift('c7000000-0000-0000-0000-00000000a002', 'c7-later@x.com', 'C7 Org', 'Thanks');
  PERFORM public.exos_membership_cancel_gift(g);
  ASSERT (SELECT status FROM public.exos_fan_memberships WHERE id = g) = 'cancelled', 'M7: cancelled gift';
  PERFORM pg_temp.act('c7000000-0000-0000-0000-0000000000a3');
  refused := false;
  BEGIN PERFORM public.exos_membership_gift('c7000000-0000-0000-0000-00000000a002', 'x@x.com');
  EXCEPTION WHEN insufficient_privilege THEN refused := true; END;
  ASSERT refused, 'M7: scanners can''t comp memberships';
  RAISE NOTICE 'OK  M7 gifts';
END $$;
RESET ROLE;
DO $$
BEGIN
  ASSERT (SELECT status = 'active' AND holder_uid = 'c7000000-0000-0000-0000-0000000000a7'
            AND current_period_end BETWEEN now() + interval '27 days' AND now() + interval '32 days'
            FROM public.exos_fan_memberships WHERE id = (SELECT v::uuid FROM c7 WHERE k = 'g1')), 'M7: one month from the claim';
END $$;

-- M8 -------------------------------------------------------------------------
SET ROLE authenticated;
DO $$
DECLARE r jsonb; refused boolean := false; m uuid := (SELECT v::uuid FROM c7 WHERE k = 'm1');
BEGIN
  PERFORM pg_temp.act('c7000000-0000-0000-0000-0000000000a3');
  r := public.exos_membership_scan('c7000000-0000-0000-0000-000000000001', m);
  ASSERT (r->>'valid')::boolean AND r->>'product_name' = 'Member' AND position('@' in r::text) = 0, 'M8: valid card, no email ' || r::text;
  r := public.exos_membership_scan('c7000000-0000-0000-0000-000000000001', gen_random_uuid());
  ASSERT NOT (r->>'valid')::boolean, 'M8: unknown card';
  PERFORM pg_temp.act('c7000000-0000-0000-0000-0000000000b9');
  BEGIN PERFORM public.exos_membership_scan('c7000000-0000-0000-0000-000000000001', m);
  EXCEPTION WHEN insufficient_privilege THEN refused := true; END;
  ASSERT refused, 'M8: another org''s staff refused';
  r := public.exos_membership_scan('c7000000-0000-0000-0000-000000000002', m);
  ASSERT NOT (r->>'valid')::boolean, 'M8: not their member';
  RAISE NOTICE 'OK  M8 door lookup';
END $$;
RESET ROLE;

-- M9 -------------------------------------------------------------------------
INSERT INTO public.exos_commerce_orders (session_id, org_id, kind, product_id, buyer_uid, buyer_email, amount_cents, currency) VALUES
  ('cs_c7_o1', 'c7000000-0000-0000-0000-000000000001', 'membership', 'c7000000-0000-0000-0000-00000000a002', 'c7000000-0000-0000-0000-0000000000a6', 'c7-partner@x.com', 10000, 'usd'),
  ('cs_c7_o2', 'c7000000-0000-0000-0000-000000000001', 'membership', 'c7000000-0000-0000-0000-00000000a002', 'c7000000-0000-0000-0000-0000000000a6', 'c7-partner@x.com', 10000, 'usd');
SET ROLE service_role;
DO $$
DECLARE e1 timestamptz; s2 timestamptz;
BEGIN
  PERFORM public.exos_commerce_fulfill('cs_c7_o1', 'pi_c7_o1', 10000);
  PERFORM public.exos_commerce_fulfill('cs_c7_o2', 'pi_c7_o2', 10000);
  SELECT m.current_period_end INTO e1 FROM public.exos_fan_memberships m JOIN public.exos_commerce_orders o ON o.result_id = m.id WHERE o.session_id = 'cs_c7_o1';
  SELECT m.current_period_start INTO s2 FROM public.exos_fan_memberships m JOIN public.exos_commerce_orders o ON o.result_id = m.id WHERE o.session_id = 'cs_c7_o2';
  ASSERT s2 = e1, 'M9: the second term starts when the first ends';
  -- Refunds.
  ASSERT public.exos_commerce_refund('cs_c7_o2', 'test') = 'refunded', 'M9: refund';
  ASSERT (SELECT m.status FROM public.exos_fan_memberships m JOIN public.exos_commerce_orders o ON o.result_id = m.id WHERE o.session_id = 'cs_c7_o2') = 'cancelled', 'M9: membership cancelled';
  ASSERT public.exos_commerce_refund('cs_c7_p4', 'test') = 'refunded', 'M9: pass refund';
END $$;
RESET ROLE;
DO $$
BEGIN
  ASSERT (SELECT status FROM public.exos_passes WHERE id = (SELECT v::uuid FROM c7 WHERE k = 'range')) = 'voided', 'M9: pass voided';
  RAISE NOTICE 'OK  M9 terms + refunds';
END $$;

-- M10 ------------------------------------------------------------------------
SET ROLE authenticated;
DO $$
DECLARE refused boolean := false;
BEGIN
  PERFORM pg_temp.act('c7000000-0000-0000-0000-0000000000b9');
  ASSERT (SELECT count(*) FROM public.exos_passes) = 0, 'M10: no passes';
  ASSERT (SELECT count(*) FROM public.exos_fan_memberships) = 0, 'M10: no memberships';
  ASSERT (SELECT count(*) FROM public.exos_pass_products) = 0, 'M10: no pass products';
  ASSERT (SELECT count(*) FROM public.exos_membership_products) = 0, 'M10: no membership products';
  BEGIN PERFORM public.exos_set_member_presale('c7000000-0000-0000-0000-0000000000e1', NULL, NULL);
  EXCEPTION WHEN insufficient_privilege THEN refused := true; END;
  ASSERT refused, 'M10: can''t touch another org''s presale';
  refused := false;
  BEGIN PERFORM public.exos_membership_cancel_gift((SELECT v::uuid FROM c7 WHERE k = 'g1'));
  EXCEPTION WHEN insufficient_privilege THEN refused := true; END;
  ASSERT refused, 'M10: can''t cancel another org''s gift';
  -- A holder sees their own pass only.
  PERFORM pg_temp.act('c7000000-0000-0000-0000-0000000000a5');
  ASSERT (SELECT count(*) FROM public.exos_my_passes()) = 3, 'M10: the fan''s passes';
  ASSERT (SELECT count(*) FROM public.exos_passes) = 3, 'M10: RLS: holder reads own';
  RAISE NOTICE 'OK  M10 cross-org isolation';
END $$;
RESET ROLE;

SELECT '*** PASSES + MEMBERSHIPS PASSED ***';
ROLLBACK;
