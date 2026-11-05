-- ============================================================================
-- Giving and gift card writes (mig 20261102110000). Self-contained (9b… ids),
-- rolled back at the end.
--   W1 grants and RLS: new tables read by staff (and the donor), never written
--      by clients; service-only functions refused to signed-in users
--   W2 campaigns: create (draft), duplicate slug, update, activate, complete
--      (monthly gifts asked to stop, subscriptions returned), can't reopen,
--      delete refused with donations (409, "complete it instead"), dashboard roles
--   W3 donations: delete only an offline one with no payment; offline refunds
--      (ledger row, idempotent per reference, never more than is left, full ->
--      refunded); raised totals net of refunds; roles
--   W4 monthly gifts: checkout attaches the subscription; one donation per paid
--      invoice (replays, first invoice before the session event); failure ->
--      past_due once per event; deleted -> cancelled, never revived; refund of a
--      charge; cancel; who may cancel
--   W5 gift card import: created / duplicate / error rows, batch idempotency,
--      cap, another source; an imported code pays at checkout (fee owed, like a
--      box-office card), is ambiguous across orgs without one; roles
--   W6 gift cards on reservations: apply (partial, due), same card twice,
--      OVERDRAW (two reservations, one card), remove gives back, cancel /
--      expiry give back, completion captures, idempotency key, cross-org
--   W7 ledger invariant: every card's balance = the sum of its ledger
--   psql -d <db> -v ON_ERROR_STOP=1 -f tests/exos/test_giving_writes.sql
-- ============================================================================
\set ON_ERROR_STOP on
BEGIN;

INSERT INTO auth.users (id, email, email_confirmed_at) VALUES
  ('9b000000-0000-0000-0000-0000000000a0', '9b-owner@x.com', now()),
  ('9b000000-0000-0000-0000-0000000000a1', '9b-manager@x.com', now()),
  ('9b000000-0000-0000-0000-0000000000a2', '9b-finance@x.com', now()),
  ('9b000000-0000-0000-0000-0000000000a3', '9b-scanner@x.com', now()),
  ('9b000000-0000-0000-0000-0000000000a4', '9b-stranger@x.com', now()),
  ('9b000000-0000-0000-0000-0000000000a5', '9b-donor@x.com', now()),
  ('9b000000-0000-0000-0000-0000000000b9', '9b-other-owner@x.com', now());
INSERT INTO public.exos_orgs (id, name, slug, owner_uid) VALUES
  ('9b000000-0000-0000-0000-000000000001', '9B Org', '9b-org', '9b000000-0000-0000-0000-0000000000a0'),
  ('9b000000-0000-0000-0000-000000000002', '9B Other', '9b-other', '9b000000-0000-0000-0000-0000000000b9');
INSERT INTO public.exos_org_memberships (org_id, user_id, role) VALUES
  ('9b000000-0000-0000-0000-000000000001', '9b000000-0000-0000-0000-0000000000a0', 'owner'),
  ('9b000000-0000-0000-0000-000000000001', '9b000000-0000-0000-0000-0000000000a1', 'manager'),
  ('9b000000-0000-0000-0000-000000000001', '9b000000-0000-0000-0000-0000000000a2', 'finance'),
  ('9b000000-0000-0000-0000-000000000001', '9b000000-0000-0000-0000-0000000000a3', 'scanner'),
  ('9b000000-0000-0000-0000-000000000002', '9b000000-0000-0000-0000-0000000000b9', 'owner');
INSERT INTO public.exos_events (id, org_id, name, slug, status, starts_at, total_tickets, tickets_sold, currency) VALUES
  ('9b000000-0000-0000-0000-0000000000e1', '9b000000-0000-0000-0000-000000000001', '9B Show', '9b-show', 'published',
   now() + interval '9 days', 0, 0, 'usd');
INSERT INTO public.exos_ticket_tiers (id, event_id, name, price, capacity, sold, visibility, sort_order) VALUES
  ('9b000000-0000-0000-0000-0000000000d1', '9b000000-0000-0000-0000-0000000000e1', 'GA', 40, 100, 0, 'public', 1);
INSERT INTO public.exos_api_keys (id, org_id, name, key_prefix, key_hash, scopes, created_by) VALUES
  ('9b000000-0000-0000-0000-0000000000f1', '9b000000-0000-0000-0000-000000000001', 'Box office', 'sk_live_9b9b9b9b',
   repeat('9b', 32), ARRAY['tickets:write', 'commerce:write'], '9b000000-0000-0000-0000-0000000000a0');

CREATE FUNCTION pg_temp.act(p_uid text) RETURNS void LANGUAGE sql AS $$
  SELECT set_config('app.uid', coalesce(p_uid, ''), true), set_config('app.jwt', '', true);
$$;
GRANT EXECUTE ON FUNCTION pg_temp.act(text) TO anon, authenticated, service_role;
CREATE FUNCTION pg_temp.sum_ledger(p_card uuid) RETURNS int LANGUAGE sql AS $$
  SELECT coalesce(sum(amount_cents), 0)::int FROM public.exos_gift_card_ledger WHERE card_id = p_card;
$$;
CREATE TEMP TABLE gw (k text PRIMARY KEY, v text);
GRANT ALL ON gw TO authenticated, service_role;

-- W1 -------------------------------------------------------------------------
DO $$
BEGIN
  ASSERT NOT has_table_privilege('authenticated', 'public.exos_recurring_donations', 'INSERT'), 'W1: no client insert on monthly gifts';
  ASSERT NOT has_table_privilege('authenticated', 'public.exos_recurring_donations', 'UPDATE'), 'W1: no client update on monthly gifts';
  ASSERT NOT has_table_privilege('authenticated', 'public.exos_recurring_donation_events', 'SELECT'), 'W1: events are service only';
  ASSERT NOT has_table_privilege('authenticated', 'public.exos_donation_ledger', 'INSERT'), 'W1: no client ledger writes';
  ASSERT NOT has_table_privilege('authenticated', 'public.exos_gift_card_imports', 'INSERT'), 'W1: no client import rows';
  ASSERT NOT has_table_privilege('anon', 'public.exos_recurring_donations', 'SELECT'), 'W1: anon reads no monthly gifts';
  ASSERT NOT has_function_privilege('authenticated', 'public.exos_api_giving_campaign_op(uuid,text,uuid,jsonb)', 'EXECUTE'), 'W1: api campaign op';
  ASSERT NOT has_function_privilege('authenticated', 'public.exos_api_donation_op(uuid,text,uuid,jsonb)', 'EXECUTE'), 'W1: api donation op';
  ASSERT NOT has_function_privilege('authenticated', 'public.exos_api_gift_card_import(uuid,text,jsonb,text)', 'EXECUTE'), 'W1: api import';
  ASSERT NOT has_function_privilege('authenticated', 'public.exos_recurring_donation_invoice(uuid,text,text,text,text,integer,text,timestamptz,text,text,text)', 'EXECUTE'), 'W1: invoice';
  ASSERT NOT has_function_privilege('authenticated', 'public._exos_reservation_gift_card_apply(uuid,uuid,text,text,integer,text,text)', 'EXECUTE'), 'W1: reservation apply';
  ASSERT NOT has_function_privilege('authenticated', 'public._exos_gift_card_import(uuid,uuid,text,jsonb,text)', 'EXECUTE'), 'W1: internal import';
  ASSERT NOT has_function_privilege('anon', 'public.exos_giving_campaign_op(text,uuid,jsonb,uuid)', 'EXECUTE'), 'W1: anon campaign op';
  ASSERT NOT has_function_privilege('anon', 'public.exos_gift_card_import(uuid,text,jsonb,text)', 'EXECUTE'), 'W1: anon import';
  ASSERT has_function_privilege('authenticated', 'public.exos_donation_offline_refund(uuid,integer,text,text,text)', 'EXECUTE'), 'W1: dashboard refund';
  RAISE NOTICE 'OK  W1 grants';
END $$;

SET ROLE authenticated;
DO $$
DECLARE refused boolean := false;
BEGIN
  PERFORM pg_temp.act('9b000000-0000-0000-0000-0000000000a0');
  BEGIN
    PERFORM public.exos_recurring_donation_cancel(NULL, gen_random_uuid(), NULL);
  EXCEPTION WHEN insufficient_privilege THEN refused := true;
  END;
  ASSERT refused, 'W1: a signed-in owner can''t call a service function';
  RAISE NOTICE 'OK  W1 service functions refused';
END $$;
RESET ROLE;

-- W2 campaigns ------------------------------------------------------------------
SET ROLE service_role;
DO $$
DECLARE r jsonb; v_id uuid; refused text;
BEGIN
  r := public.exos_api_giving_campaign_op('9b000000-0000-0000-0000-000000000001', 'create', NULL,
         '{"name": "Roof Fund", "goal_cents": 500000, "suggested_cents": [1500, 3000]}');
  v_id := (r->'campaign'->>'id')::uuid;
  ASSERT r->'campaign'->>'status' = 'draft' AND r->'campaign'->>'slug' = 'roof-fund'
     AND (r->'campaign'->'suggested_cents') = '[1500, 3000]'::jsonb, 'W2: created as a draft ' || r::text;
  INSERT INTO gw VALUES ('camp', v_id::text);
  BEGIN
    PERFORM public.exos_api_giving_campaign_op('9b000000-0000-0000-0000-000000000001', 'create', NULL, '{"name": "Roof fund"}');
  EXCEPTION WHEN unique_violation THEN refused := SQLERRM;
  END;
  ASSERT refused LIKE '%slug%', 'W2: duplicate slug refused';
  refused := NULL;
  BEGIN
    PERFORM public.exos_api_giving_campaign_op('9b000000-0000-0000-0000-000000000001', 'create', NULL, '{"goal_cents": 5}');
  EXCEPTION WHEN invalid_parameter_value THEN refused := SQLERRM;
  END;
  ASSERT refused LIKE '%name%', 'W2: name required';
  refused := NULL;
  BEGIN
    PERFORM public.exos_api_giving_campaign_op('9b000000-0000-0000-0000-000000000001', 'update', v_id, '{"goal_cents": "lots"}');
  EXCEPTION WHEN invalid_parameter_value THEN refused := SQLERRM;
  END;
  ASSERT refused LIKE '%wrong type%', 'W2: bad type is a 400';
  r := public.exos_api_giving_campaign_op('9b000000-0000-0000-0000-000000000001', 'update', v_id, '{"description": "New roof", "round_up": true}');
  ASSERT r->'campaign'->>'description' = 'New roof' AND (r->'campaign'->>'round_up')::boolean
     AND (r->'campaign'->>'goal_cents')::int = 500000, 'W2: update touches only the given fields';
  r := public.exos_api_giving_campaign_op('9b000000-0000-0000-0000-000000000001', 'activate', v_id, '{}');
  ASSERT r->'campaign'->>'status' = 'active', 'W2: activated';
  ASSERT EXISTS (SELECT 1 FROM public.exos_public_giving_campaigns WHERE id = v_id), 'W2: on the public view';
  -- Another org can't see or touch it.
  refused := NULL;
  BEGIN
    PERFORM public.exos_api_giving_campaign_op('9b000000-0000-0000-0000-000000000002', 'complete', v_id, '{}');
  EXCEPTION WHEN no_data_found THEN refused := 'nf';
  END;
  ASSERT refused = 'nf', 'W2: cross-org is not found';
  RAISE NOTICE 'OK  W2 create / update / activate';
END $$;
RESET ROLE;

-- Dashboard roles.
SET ROLE authenticated;
DO $$
DECLARE r jsonb; refused boolean := false;
BEGIN
  PERFORM pg_temp.act('9b000000-0000-0000-0000-0000000000a1');  -- manager
  r := public.exos_giving_campaign_op('create', NULL, '{"name": "Spare", "active": true}', '9b000000-0000-0000-0000-000000000001');
  ASSERT r->'campaign'->>'status' = 'active', 'W2: manager creates';
  INSERT INTO gw VALUES ('spare', r->'campaign'->>'id');
  PERFORM pg_temp.act('9b000000-0000-0000-0000-0000000000a2');  -- finance
  BEGIN
    PERFORM public.exos_giving_campaign_op('complete', (SELECT v::uuid FROM gw WHERE k = 'spare'));
  EXCEPTION WHEN insufficient_privilege THEN refused := true;
  END;
  ASSERT refused, 'W2: finance can''t change campaigns';
  PERFORM pg_temp.act('9b000000-0000-0000-0000-0000000000a1');
  r := public.exos_giving_campaign_op('delete', (SELECT v::uuid FROM gw WHERE k = 'spare'));
  ASSERT (r->'campaign'->>'deleted')::boolean, 'W2: an empty campaign is deleted';
  RAISE NOTICE 'OK  W2 dashboard roles';
END $$;
RESET ROLE;

-- W3 donations ------------------------------------------------------------------
SET ROLE authenticated;
DO $$
DECLARE c uuid := (SELECT v::uuid FROM gw WHERE k = 'camp'); d1 uuid; d2 uuid;
BEGIN
  PERFORM pg_temp.act('9b000000-0000-0000-0000-0000000000a2');  -- finance records two checks
  d1 := public.exos_record_offline_donation(c, 10000, 'check', 'Pat', 'pat@x.com', false, NULL, 'chk-101');
  d2 := public.exos_record_offline_donation(c, 2500, 'cash', 'Lee', NULL, false, NULL, 'cash-7');
  INSERT INTO gw VALUES ('d1', d1::text), ('d2', d2::text);
END $$;
RESET ROLE;
-- A card gift from a commerce order (a payment stands behind it).
INSERT INTO public.exos_donations (id, org_id, campaign_id, amount_cents, total_cents, currency, method, key, session_id)
VALUES ('9b000000-0000-0000-0000-00000000dd01', '9b000000-0000-0000-0000-000000000001',
        (SELECT v::uuid FROM gw WHERE k = 'camp'), 4000, 4000, 'usd', 'card', 'stripe:cs_9b_card', 'cs_9b_card');

SET ROLE service_role;
DO $$
DECLARE c uuid := (SELECT v::uuid FROM gw WHERE k = 'camp'); d1 uuid := (SELECT v::uuid FROM gw WHERE k = 'd1');
        d2 uuid := (SELECT v::uuid FROM gw WHERE k = 'd2'); r jsonb; refused text;
BEGIN
  ASSERT (SELECT raised_cents FROM public.exos_public_giving_campaigns WHERE id = c) = 16500, 'W3: raised before';
  -- Delete: the card gift can't go.
  BEGIN
    PERFORM public.exos_api_donation_op('9b000000-0000-0000-0000-000000000001', 'delete', '9b000000-0000-0000-0000-00000000dd01', NULL);
  EXCEPTION WHEN object_not_in_prerequisite_state THEN refused := SQLERRM;
  END;
  ASSERT refused LIKE '%refund this one instead%', 'W3: a paid donation is not deleted: ' || coalesce(refused, 'none');
  -- The cash one can, with an audit row.
  r := public.exos_api_donation_op('9b000000-0000-0000-0000-000000000001', 'delete', d2, NULL);
  ASSERT (r->>'deleted')::boolean AND NOT EXISTS (SELECT 1 FROM public.exos_donations WHERE id = d2), 'W3: offline gift deleted';
  ASSERT (SELECT amount_cents FROM public.exos_donation_ledger WHERE donation_id = d2 AND kind = 'deleted') = -2500
     AND (SELECT snapshot->>'donor_name' FROM public.exos_donation_ledger WHERE donation_id = d2) = 'Lee', 'W3: deletion kept in the ledger';
  -- Offline refunds: partial, the same reference again, too much, the rest.
  r := public.exos_api_donation_op('9b000000-0000-0000-0000-000000000001', 'offline_refund', d1,
         '{"amount_cents": 3000, "reference": "chk-9001", "method": "check", "note": "half back"}');
  ASSERT (r->>'fresh')::boolean AND (r->'donation'->>'refunded_cents')::int = 3000 AND r->'donation'->>'status' = 'received', 'W3: partial ' || r::text;
  r := public.exos_api_donation_op('9b000000-0000-0000-0000-000000000001', 'offline_refund', d1,
         '{"amount_cents": 3000, "reference": "chk-9001"}');
  ASSERT NOT (r->>'fresh')::boolean AND (r->'donation'->>'refunded_cents')::int = 3000, 'W3: resend is a no-op';
  refused := NULL;
  BEGIN
    PERFORM public.exos_api_donation_op('9b000000-0000-0000-0000-000000000001', 'offline_refund', d1, '{"amount_cents": 9000, "reference": "x2"}');
  EXCEPTION WHEN invalid_parameter_value THEN refused := SQLERRM;
  END;
  ASSERT refused LIKE '%7000%', 'W3: never more than is left';
  ASSERT (SELECT raised_cents FROM public.exos_public_giving_campaigns WHERE id = c) = 11000, 'W3: raised net of the refund';
  -- A refunded donation stays in the books.
  refused := NULL;
  BEGIN
    PERFORM public.exos_api_donation_op('9b000000-0000-0000-0000-000000000001', 'delete', d1, NULL);
  EXCEPTION WHEN object_not_in_prerequisite_state THEN refused := SQLERRM;
  END;
  ASSERT refused LIKE '%refund recorded%', 'W3: no delete after a refund';
  r := public.exos_api_donation_op('9b000000-0000-0000-0000-000000000001', 'offline_refund', d1, '{"reference": "rest"}');
  ASSERT r->'donation'->>'status' = 'refunded' AND (r->'donation'->>'refunded_cents')::int = 10000, 'W3: the rest refunds it';
  ASSERT (SELECT sum(amount_cents) FROM public.exos_donation_ledger WHERE donation_id = d1) = -10000, 'W3: ledger sums to the refund';
  refused := NULL;
  BEGIN
    PERFORM public.exos_api_donation_op('9b000000-0000-0000-0000-000000000001', 'offline_refund', d1, '{"reference": "again"}');
  EXCEPTION WHEN object_not_in_prerequisite_state THEN refused := SQLERRM;
  END;
  ASSERT refused LIKE '%already refunded%', 'W3: refunded once';
  -- Another org.
  refused := NULL;
  BEGIN
    PERFORM public.exos_api_donation_op('9b000000-0000-0000-0000-000000000002', 'offline_refund', '9b000000-0000-0000-0000-00000000dd01', '{}');
  EXCEPTION WHEN no_data_found THEN refused := 'nf';
  END;
  ASSERT refused = 'nf', 'W3: cross-org is not found';
  RAISE NOTICE 'OK  W3 delete + offline refunds';
END $$;
RESET ROLE;

SET ROLE authenticated;
DO $$
DECLARE refused boolean := false; r jsonb;
BEGIN
  PERFORM pg_temp.act('9b000000-0000-0000-0000-0000000000a3');  -- scanner
  BEGIN
    PERFORM public.exos_donation_offline_refund('9b000000-0000-0000-0000-00000000dd01', 100, 'scan');
  EXCEPTION WHEN insufficient_privilege THEN refused := true;
  END;
  ASSERT refused, 'W3: door staff can''t refund donations';
  PERFORM pg_temp.act('9b000000-0000-0000-0000-0000000000a2');  -- finance may record a refund
  r := public.exos_donation_offline_refund('9b000000-0000-0000-0000-00000000dd01', 1000, 'fin-1', 'bank_transfer');
  ASSERT (r->'donation'->>'refunded_cents')::int = 1000, 'W3: finance records a refund';
  refused := false;
  BEGIN
    PERFORM public.exos_donation_delete('9b000000-0000-0000-0000-00000000dd01');
  EXCEPTION WHEN insufficient_privilege THEN refused := true;
  END;
  ASSERT refused, 'W3: finance can''t delete';
  ASSERT (SELECT count(*) FROM public.exos_donation_ledger) >= 3, 'W3: finance reads the ledger';
  PERFORM pg_temp.act('9b000000-0000-0000-0000-0000000000a3');
  ASSERT (SELECT count(*) FROM public.exos_donation_ledger) = 0, 'W3: door staff don''t';
  RAISE NOTICE 'OK  W3 roles';
END $$;
RESET ROLE;

-- W4 monthly gifts -------------------------------------------------------------
INSERT INTO public.exos_recurring_donations (id, org_id, campaign_id, amount_cents, cover_fees_cents, currency, donor_uid, donor_email, donor_name)
VALUES ('9b000000-0000-0000-0000-00000000aa01', '9b000000-0000-0000-0000-000000000001', (SELECT v::uuid FROM gw WHERE k = 'camp'),
        2000, 60, 'usd', '9b000000-0000-0000-0000-0000000000a5', '9b-donor@x.com', 'Dee'),
       ('9b000000-0000-0000-0000-00000000aa02', '9b000000-0000-0000-0000-000000000001', (SELECT v::uuid FROM gw WHERE k = 'camp'),
        1000, 0, 'usd', NULL, 'walkin@x.com', NULL);
INSERT INTO public.exos_commerce_orders (session_id, org_id, kind, product_id, buyer_uid, buyer_email, amount_cents, currency, details, stripe_customer_id)
VALUES ('cs_9b_monthly', '9b000000-0000-0000-0000-000000000001', 'recurring_donation', (SELECT v::uuid FROM gw WHERE k = 'camp'),
        '9b000000-0000-0000-0000-0000000000a5', '9b-donor@x.com', 2060, 'usd',
        '{"recurring_id": "9b000000-0000-0000-0000-00000000aa01"}', 'cus_9bdonor');

SET ROLE service_role;
DO $$
DECLARE s text; c uuid := (SELECT v::uuid FROM gw WHERE k = 'camp'); r jsonb;
BEGIN
  s := public.exos_commerce_fulfill('cs_9b_monthly', 'pi_9b_first', 2060, 'sub_9bA', now() + interval '1 month');
  ASSERT s = 'fulfilled', 'W4: the session fulfils (not refused as an unknown kind): ' || s;
  ASSERT (SELECT status || ':' || stripe_subscription_id || ':' || stripe_customer_id FROM public.exos_recurring_donations
           WHERE id = '9b000000-0000-0000-0000-00000000aa01') = 'active:sub_9bA:cus_9bdonor', 'W4: plan active with its subscription';
  ASSERT (SELECT result_id FROM public.exos_commerce_orders WHERE session_id = 'cs_9b_monthly') = '9b000000-0000-0000-0000-00000000aa01', 'W4: result id';
  -- The first invoice, twice (Stripe retries).
  s := public.exos_recurring_donation_invoice('9b000000-0000-0000-0000-00000000aa01', 'sub_9bA', 'cus_9bdonor', 'in_9b1', 'pi_9b_first',
         2060, 'usd', now() + interval '1 month', 'paid');
  ASSERT s = 'recorded', 'W4: first invoice ' || s;
  s := public.exos_recurring_donation_invoice(NULL, 'sub_9bA', NULL, 'in_9b1', 'pi_9b_first', 2060, 'usd', NULL, 'paid');
  ASSERT s = 'duplicate', 'W4: replay ' || s;
  ASSERT (SELECT count(*) FROM public.exos_donations WHERE recurring_id = '9b000000-0000-0000-0000-00000000aa01') = 1, 'W4: one donation per invoice';
  ASSERT (SELECT amount_cents || '+' || cover_fees_cents FROM public.exos_donations WHERE stripe_invoice_id = 'in_9b1') = '2000+60', 'W4: plan split';
  ASSERT (SELECT receipt_number IS NOT NULL FROM public.exos_donations WHERE stripe_invoice_id = 'in_9b1'), 'W4: receipt numbered';
  -- A failed renewal, the same event twice, then it pays.
  s := public.exos_recurring_donation_invoice(NULL, 'sub_9bA', NULL, 'in_9b2', NULL, 2060, 'usd', NULL, 'failed', 'evt_9b_f1', 'card declined');
  ASSERT s = 'failed_recorded', 'W4: failure ' || s;
  s := public.exos_recurring_donation_invoice(NULL, 'sub_9bA', NULL, 'in_9b2', NULL, 2060, 'usd', NULL, 'failed', 'evt_9b_f1', 'card declined');
  ASSERT s = 'duplicate', 'W4: failure replay';
  ASSERT (SELECT status || ':' || failed_payments FROM public.exos_recurring_donations WHERE id = '9b000000-0000-0000-0000-00000000aa01') = 'past_due:1', 'W4: past due once';
  s := public.exos_recurring_donation_invoice(NULL, 'sub_9bA', NULL, 'in_9b2', 'pi_9b_second', 2060, 'usd', now() + interval '2 months', 'paid');
  ASSERT (SELECT status || ':' || failed_payments FROM public.exos_recurring_donations WHERE id = '9b000000-0000-0000-0000-00000000aa01') = 'active:0', 'W4: paid again -> active';
  -- Unknown subscriptions are ignored.
  ASSERT public.exos_recurring_donation_invoice(NULL, 'sub_nobody', NULL, 'in_9bx', NULL, 500, 'usd', NULL, 'paid') = 'unknown', 'W4: not ours';
  -- The second plan's first invoice lands before its checkout session event (metadata id).
  s := public.exos_recurring_donation_invoice('9b000000-0000-0000-0000-00000000aa02', 'sub_9bB', 'cus_9bwalk', 'in_9bB1', 'pi_9bB1', 1000, 'usd', NULL, 'paid');
  ASSERT s = 'recorded' AND (SELECT stripe_subscription_id FROM public.exos_recurring_donations WHERE id = '9b000000-0000-0000-0000-00000000aa02') = 'sub_9bB',
    'W4: early invoice attaches the subscription';
  -- Refund of the second charge (Stripe): that donation only.
  ASSERT public.exos_recurring_donation_refund('pi_9b_second') = 1, 'W4: refund one charge';
  ASSERT (SELECT status FROM public.exos_donations WHERE stripe_invoice_id = 'in_9b2') = 'refunded'
     AND (SELECT status FROM public.exos_donations WHERE stripe_invoice_id = 'in_9b1') = 'received', 'W4: only that charge';
  -- Cancel: the subscription to stop comes back; Stripe's .deleted ends it.
  r := public.exos_recurring_donation_cancel('9b000000-0000-0000-0000-000000000001', '9b000000-0000-0000-0000-00000000aa01', 'donor asked');
  ASSERT r->>'subscription_id' = 'sub_9bA' AND r->'recurring_donation'->>'cancel_requested_at' IS NOT NULL, 'W4: cancel asks ' || r::text;
  ASSERT public.exos_recurring_donation_sync('sub_9bA', 'deleted', 'canceled') = 'cancelled', 'W4: deleted -> cancelled';
  ASSERT public.exos_recurring_donation_sync('sub_9bA', 'updated', 'active') = 'cancelled', 'W4: never revived by an update';
  s := public.exos_recurring_donation_invoice(NULL, 'sub_9bA', NULL, 'in_9b3', 'pi_9b_third', 2060, 'usd', NULL, 'paid');
  ASSERT s = 'recorded' AND (SELECT status FROM public.exos_recurring_donations WHERE id = '9b000000-0000-0000-0000-00000000aa01') = 'cancelled',
    'W4: a late charge is still a gift, the plan stays cancelled';
  r := public.exos_recurring_donation_cancel(NULL, '9b000000-0000-0000-0000-00000000aa01');
  ASSERT r->>'subscription_id' IS NULL, 'W4: cancelling twice asks nothing of Stripe';
  -- A full refund of the first purchase (the commerce order) refunds its donation.
  ASSERT public.exos_commerce_refund('cs_9b_monthly', 'stripe refund') = 'refunded', 'W4: commerce refund';
  ASSERT (SELECT status FROM public.exos_donations WHERE stripe_invoice_id = 'in_9b1') = 'refunded', 'W4: first charge refunded';
  RAISE NOTICE 'OK  W4 monthly gifts';
END $$;
RESET ROLE;

SET ROLE authenticated;
DO $$
BEGIN
  PERFORM pg_temp.act('9b000000-0000-0000-0000-0000000000a5');  -- donor
  ASSERT public.exos_recurring_donation_can_cancel('9b000000-0000-0000-0000-00000000aa01'), 'W4: the donor may cancel';
  ASSERT (SELECT count(*) FROM public.exos_recurring_donations) = 1, 'W4: the donor reads their own plan only';
  PERFORM pg_temp.act('9b000000-0000-0000-0000-0000000000a4');  -- stranger
  ASSERT NOT public.exos_recurring_donation_can_cancel('9b000000-0000-0000-0000-00000000aa01'), 'W4: a stranger may not';
  ASSERT (SELECT count(*) FROM public.exos_recurring_donations) = 0, 'W4: a stranger reads none';
  PERFORM pg_temp.act('9b000000-0000-0000-0000-0000000000a2');  -- finance
  ASSERT public.exos_recurring_donation_can_cancel('9b000000-0000-0000-0000-00000000aa02'), 'W4: finance may cancel';
  ASSERT (SELECT count(*) FROM public.exos_recurring_donations) = 2, 'W4: finance reads the org''s';
  RAISE NOTICE 'OK  W4 who may cancel';
END $$;
RESET ROLE;

-- W2 again: complete stops the monthly gifts, delete with donations refused.
SET ROLE service_role;
DO $$
DECLARE c uuid := (SELECT v::uuid FROM gw WHERE k = 'camp'); r jsonb; refused text;
BEGIN
  INSERT INTO public.exos_recurring_donations (id, org_id, campaign_id, amount_cents, currency, donor_email, stripe_subscription_id, status)
  VALUES ('9b000000-0000-0000-0000-00000000aa03', '9b000000-0000-0000-0000-000000000001', c, 1500, 'usd', 'c@x.com', 'sub_9bC', 'active'),
         ('9b000000-0000-0000-0000-00000000aa04', '9b000000-0000-0000-0000-000000000001', c, 1500, 'usd', 'd@x.com', NULL, 'pending');
  BEGIN
    PERFORM public.exos_api_giving_campaign_op('9b000000-0000-0000-0000-000000000001', 'delete', c, NULL);
  EXCEPTION WHEN object_not_in_prerequisite_state THEN refused := SQLERRM;
  END;
  ASSERT refused LIKE '%complete it instead%', 'W2: delete with donations refused';
  r := public.exos_api_giving_campaign_op('9b000000-0000-0000-0000-000000000001', 'complete', c, NULL);
  ASSERT r->'campaign'->>'status' = 'completed' AND r->'cancel_subscriptions' @> '["sub_9bB", "sub_9bC"]'::jsonb
     AND NOT (r->'cancel_subscriptions' ? 'sub_9bA'), 'W2: complete returns the live subscriptions ' || r::text;
  ASSERT (SELECT status FROM public.exos_recurring_donations WHERE id = '9b000000-0000-0000-0000-00000000aa04') = 'cancelled', 'W2: pending plan ends';
  ASSERT (SELECT cancel_requested_at IS NOT NULL FROM public.exos_recurring_donations WHERE id = '9b000000-0000-0000-0000-00000000aa03'), 'W2: live plan asked to stop';
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_public_giving_campaigns WHERE id = c), 'W2: off the public view';
  refused := NULL;
  BEGIN
    PERFORM public.exos_api_giving_campaign_op('9b000000-0000-0000-0000-000000000001', 'activate', c, NULL);
  EXCEPTION WHEN object_not_in_prerequisite_state THEN refused := SQLERRM;
  END;
  ASSERT refused LIKE '%completed%', 'W2: can''t reopen';
  RAISE NOTICE 'OK  W2 complete + delete';
END $$;
RESET ROLE;

-- W5 gift card import ------------------------------------------------------------
SET ROLE service_role;
DO $$
DECLARE r jsonb; r2 jsonb; refused text; big jsonb;
BEGIN
  r := public.exos_api_gift_card_import('9b000000-0000-0000-0000-000000000001', 'gift_up', '[
    {"code": "GU-ABC123", "balance_cents": 2500, "initial_cents": 5000},
    {"code": "gu-zz9900", "balance_cents": 10000, "currency": "USD", "recipient_email": "Sam@X.com"},
    {"code": "no", "balance_cents": 100},
    {"code": "GUEXPIRED1", "balance_cents": 100, "expires_at": "2001-01-01"},
    {"code": "GUZERO0001", "balance_cents": 0},
    {"code": "GUABC123", "balance_cents": 999}
  ]', 'file-1');
  ASSERT (r->>'created')::int = 2 AND (r->>'duplicates')::int = 1 AND (r->>'errors')::int = 3
     AND (r->>'imported_cents')::int = 12500, 'W5: first import ' || r::text;
  ASSERT r->'rows'->2->>'error' LIKE '%6-64%', 'W5: short code refused';
  INSERT INTO gw VALUES ('gu1', r->'rows'->0->>'card_id');
  ASSERT (SELECT source || '/' || payment_method || '/' || last4 || '/' || initial_cents || '/' || balance_cents
            FROM public.exos_gift_cards WHERE id = (r->'rows'->0->>'card_id')::uuid) = 'import/external/C123/5000/2500', 'W5: card shape';
  ASSERT (SELECT recipient_email FROM public.exos_gift_cards WHERE id = (r->'rows'->1->>'card_id')::uuid) = 'sam@x.com', 'W5: email lowered';
  -- Same batch key: the stored answer. Another key, same file: all duplicates.
  r2 := public.exos_api_gift_card_import('9b000000-0000-0000-0000-000000000001', 'gift_up', '[{"code": "SOMETHINGELSE", "balance_cents": 5}]', 'file-1');
  ASSERT NOT (r2->>'fresh')::boolean AND r2->'rows' = r->'rows', 'W5: same key, same answer';
  r2 := public.exos_api_gift_card_import('9b000000-0000-0000-0000-000000000001', 'gift_up',
          '[{"code": "GU-ABC123", "balance_cents": 2500}, {"code": "GUZZ9900", "balance_cents": 10000}]', 'file-1-again');
  ASSERT (r2->>'created')::int = 0 AND (r2->>'duplicates')::int = 2, 'W5: re-import is all duplicates';
  ASSERT (SELECT count(*) FROM public.exos_gift_cards WHERE org_id = '9b000000-0000-0000-0000-000000000001' AND source = 'import') = 2, 'W5: two cards';
  -- Another source with a code already imported: refused per row.
  r2 := public.exos_api_gift_card_import('9b000000-0000-0000-0000-000000000001', 'square', '[{"code": "GUABC123", "balance_cents": 100}]', NULL);
  ASSERT (r2->>'errors')::int = 1 AND r2->'rows'->0->>'error' LIKE '%another source%', 'W5: another source';
  -- The other org can import the same code.
  r2 := public.exos_api_gift_card_import('9b000000-0000-0000-0000-000000000002', 'gift_up', '[{"code": "GUABC123", "balance_cents": 700}]', NULL);
  ASSERT (r2->>'created')::int = 1, 'W5: per-org dedupe';
  -- Cap and shape.
  SELECT jsonb_agg(jsonb_build_object('code', 'CAP' || lpad(g::text, 6, '0'), 'balance_cents', 100)) INTO big FROM generate_series(1, 501) g;
  BEGIN
    PERFORM public.exos_api_gift_card_import('9b000000-0000-0000-0000-000000000001', 'gift_up', big, NULL);
  EXCEPTION WHEN invalid_parameter_value THEN refused := SQLERRM;
  END;
  ASSERT refused LIKE '%1-500%', 'W5: at most 500 a batch';
  refused := NULL;
  BEGIN
    PERFORM public.exos_api_gift_card_import('9b000000-0000-0000-0000-000000000001', 'Gift Up!', '[]', NULL);
  EXCEPTION WHEN invalid_parameter_value THEN refused := SQLERRM;
  END;
  ASSERT refused LIKE '%source%', 'W5: bad source';
  RAISE NOTICE 'OK  W5 import';
END $$;

-- An imported code pays like any card, owes the Exos fee on its part.
DO $$
DECLARE q jsonb; h jsonb;
BEGIN
  q := public.exos_gift_card_quote('gu abc 123', 'w5-a', '9b000000-0000-0000-0000-000000000001', 'usd', 1000);
  ASSERT q->>'error' IS NULL AND (q->>'applicable_cents')::int = 1000 AND q->>'last4' = 'C123', 'W5: quote by its own code ' || q::text;
  ASSERT q->>'source' = 'import' AND NOT (q->>'fee_paid_at_sale')::boolean, 'W5: fee owed on an imported card';
  q := public.exos_gift_card_quote('GUABC123', 'w5-a', NULL, NULL, NULL);
  ASSERT q->>'error' LIKE '%organizer''s checkout%', 'W5: two orgs share the code: ambiguous without one ' || q::text;
  q := public.exos_gift_card_quote('GUZZ9900', 'w5-a', NULL, NULL, NULL);
  ASSERT q->>'error' IS NULL AND (q->>'balance_cents')::int = 10000, 'W5: unique code needs no org';
  q := public.exos_gift_card_quote('GUABC123', 'w5-a', '9b000000-0000-0000-0000-000000000002', 'usd', 100);
  ASSERT (q->>'balance_cents')::int = 700, 'W5: the other org''s card';
  h := public.exos_gift_card_hold('GUABC123', 'cs_9b_gu_hold', 1500, 'w5-b', '9b000000-0000-0000-0000-000000000001', 'usd');
  ASSERT (h->>'balance_cents')::int = 1000 AND NOT (h->>'fee_paid_at_sale')::boolean, 'W5: hold at checkout ' || h::text;
  RAISE NOTICE 'OK  W5 imported codes redeem';
END $$;
RESET ROLE;

SET ROLE authenticated;
DO $$
DECLARE refused boolean := false; r jsonb;
BEGIN
  PERFORM pg_temp.act('9b000000-0000-0000-0000-0000000000a2');  -- finance
  BEGIN
    PERFORM public.exos_gift_card_import('9b000000-0000-0000-0000-000000000001', 'gift_up', '[{"code": "FINANCE01", "balance_cents": 100}]');
  EXCEPTION WHEN insufficient_privilege THEN refused := true;
  END;
  ASSERT refused, 'W5: finance can''t import stored value';
  ASSERT (SELECT count(*) FROM public.exos_gift_card_imports) >= 3, 'W5: finance reads the import log';
  PERFORM pg_temp.act('9b000000-0000-0000-0000-0000000000a1');  -- manager
  r := public.exos_gift_card_import('9b000000-0000-0000-0000-000000000001', 'gift_up', '[{"code": "MANAGER01", "balance_cents": 100}]');
  ASSERT (r->>'created')::int = 1, 'W5: manager imports';
  ASSERT (SELECT issued_by FROM public.exos_gift_cards WHERE id = (r->'rows'->0->>'card_id')::uuid) = '9b000000-0000-0000-0000-0000000000a1', 'W5: importer recorded';
  RAISE NOTICE 'OK  W5 roles';
END $$;
RESET ROLE;

-- W6 gift cards on reservations ---------------------------------------------------
-- An Exos card worth 50.00 from the box office.
SET ROLE authenticated;
DO $$
DECLARE r jsonb;
BEGIN
  PERFORM pg_temp.act('9b000000-0000-0000-0000-0000000000a0');
  r := public.exos_gift_card_issue('9b000000-0000-0000-0000-000000000001', 5000, 'cash');
  INSERT INTO gw VALUES ('code', r->>'code'), ('card', r->>'card_id');
END $$;
RESET ROLE;

DO $$
DECLARE o uuid := '9b000000-0000-0000-0000-000000000001'; e uuid := '9b000000-0000-0000-0000-0000000000e1';
        kid uuid := '9b000000-0000-0000-0000-0000000000f1'; code text := (SELECT v FROM gw WHERE k = 'code');
        card uuid := (SELECT v::uuid FROM gw WHERE k = 'card');
        lines jsonb := '[{"ticket_type_id": "9b000000-0000-0000-0000-0000000000d1", "quantity": 1}]';
        r1 jsonb; r2 jsonb; r3 jsonb; a jsonb; refused text; v_total int;
BEGIN
  r1 := public._exos_partner_reserve(o, e, NULL, kid, lines, '{}');
  r2 := public._exos_partner_reserve(o, e, NULL, kid, lines, '{}');
  v_total := (SELECT total_cents FROM public.exos_partner_reservations WHERE token = r1->>'token');
  ASSERT v_total = 4000, 'W6: a 40.00 reservation, got ' || v_total;
  -- Partial: 15.00 of the card on the first reservation.
  a := public._exos_reservation_gift_card_apply(o, NULL, r1->>'token', code, 1500, 'w6-a');
  ASSERT a->>'error' IS NULL AND (a->>'amount_cents')::int = 1500 AND (a->>'amount_due_cents')::int = 2500
     AND (a->>'card_balance_cents')::int = 3500, 'W6: partial ' || a::text;
  INSERT INTO gw VALUES ('red1', a->>'redemption_id');
  a := public._exos_reservation_gift_card_apply(o, NULL, r1->>'token', code, NULL, 'w6-a');
  ASSERT a->>'error' LIKE '%already on this reservation%', 'W6: same card twice';
  -- Overdraw: the second reservation asks for the full 40.00; only 35.00 is left.
  a := public._exos_reservation_gift_card_apply(o, NULL, r2->>'token', code, NULL, 'w6-a');
  ASSERT (a->>'amount_cents')::int = 3500 AND (a->>'card_balance_cents')::int = 0 AND (a->>'amount_due_cents')::int = 500,
    'W6: takes what is left, never more ' || a::text;
  INSERT INTO gw VALUES ('red2', a->>'redemption_id');
  r3 := public._exos_partner_reserve(o, e, NULL, kid, lines, '{}');
  a := public._exos_reservation_gift_card_apply(o, NULL, r3->>'token', code, NULL, 'w6-a');
  ASSERT a->>'error' LIKE '%no balance%', 'W6: an empty card is refused ' || a::text;
  ASSERT (SELECT balance_cents FROM public.exos_gift_cards WHERE id = card) = 0, 'W6: balance 0, not below';
  -- Remove from r1: 15.00 comes back; twice is fine.
  a := public._exos_reservation_gift_card_remove(o, NULL, r1->>'token', (SELECT v FROM gw WHERE k = 'red1'));
  ASSERT (a->>'released_cents')::int = 1500 AND (a->>'amount_due_cents')::int = 4000, 'W6: remove gives back ' || a::text;
  a := public._exos_reservation_gift_card_remove(o, NULL, r1->>'token', (SELECT v FROM gw WHERE k = 'red1'));
  ASSERT (a->>'released_cents')::int = 0, 'W6: remove twice';
  ASSERT (SELECT balance_cents FROM public.exos_gift_cards WHERE id = card) = 1500, 'W6: balance after remove';
  -- Cancel r2: its 35.00 comes back.
  PERFORM public._exos_partner_reservation_cancel(o, NULL, r2->>'token');
  ASSERT (SELECT balance_cents FROM public.exos_gift_cards WHERE id = card) = 5000, 'W6: cancel returns the balance';
  ASSERT (SELECT status FROM public.exos_gift_card_redemptions WHERE session_id = (SELECT v FROM gw WHERE k = 'red2')) = 'released', 'W6: released';
  -- Idempotency key: a resend is the same redemption.
  a := public._exos_reservation_gift_card_apply(o, NULL, r3->>'token', code, 1000, 'w6-b', 'idem-1');
  r1 := public._exos_reservation_gift_card_apply(o, NULL, r3->>'token', code, 1000, 'w6-b', 'idem-1');
  ASSERT NOT (r1->>'fresh')::boolean AND r1->>'redemption_id' = a->>'redemption_id'
     AND (SELECT balance_cents FROM public.exos_gift_cards WHERE id = card) = 4000, 'W6: resend moves nothing';
  -- Expiry returns it (the sweep, as the cron runs it).
  UPDATE public.exos_partner_reservations SET expires_at = now() - interval '1 second' WHERE token = r3->>'token';
  PERFORM public.exos_partner_reservations_sweep(50);
  ASSERT (SELECT balance_cents FROM public.exos_gift_cards WHERE id = card) = 5000, 'W6: expiry returns the balance';
  refused := NULL;
  BEGIN
    PERFORM public._exos_reservation_gift_card_apply(o, NULL, r3->>'token', code, NULL, 'w6-b');
  EXCEPTION WHEN object_not_in_prerequisite_state THEN refused := SQLERRM;
  END;
  ASSERT refused LIKE '%expired%', 'W6: no gift card on an expired reservation';
  -- Completion captures.
  r1 := public._exos_partner_reserve(o, e, NULL, kid, lines, '{}');
  a := public._exos_reservation_gift_card_apply(o, NULL, r1->>'token', code, NULL, 'w6-c');
  ASSERT (a->>'amount_cents')::int = 4000 AND (a->>'amount_due_cents')::int = 0, 'W6: card covers it';
  refused := NULL;
  BEGIN
    PERFORM public._exos_reservation_gift_card_apply(o, NULL, r1->>'token', code, NULL, 'w6-c');
  EXCEPTION WHEN object_not_in_prerequisite_state THEN refused := SQLERRM;
  END;
  ASSERT refused LIKE '%already cover%', 'W6: nothing left to pay';
  PERFORM public._exos_partner_reservation_complete(o, NULL, r1->>'token', NULL, NULL);
  ASSERT (SELECT status FROM public.exos_gift_card_redemptions WHERE session_id = a->>'redemption_id') = 'captured', 'W6: captured';
  ASSERT NOT (SELECT fee_paid_at_sale FROM public.exos_gift_card_redemptions WHERE session_id = a->>'redemption_id'), 'W6: box-office card owes the fee';
  refused := NULL;
  BEGIN
    PERFORM public._exos_reservation_gift_card_remove(o, NULL, r1->>'token', a->>'redemption_id');
  EXCEPTION WHEN object_not_in_prerequisite_state THEN refused := SQLERRM;
  END;
  ASSERT refused LIKE '%refund the gift card part%', 'W6: completed keeps it';
  ASSERT (SELECT balance_cents FROM public.exos_gift_cards WHERE id = card) = 1000, 'W6: spent 40.00';
  -- Cross-org: the other org's token is not found.
  refused := NULL;
  BEGIN
    PERFORM public._exos_reservation_gift_card_apply('9b000000-0000-0000-0000-000000000002', NULL, r1->>'token', code, NULL, 'w6-d');
  EXCEPTION WHEN no_data_found THEN refused := 'nf';
  END;
  ASSERT refused = 'nf', 'W6: cross-org not found';
  -- An imported card on a reservation (fee owed recorded).
  r2 := public._exos_partner_reserve(o, e, NULL, kid, lines, '{}');
  a := public._exos_reservation_gift_card_apply(o, NULL, r2->>'token', 'GUZZ9900', NULL, 'w6-e');
  ASSERT (a->>'amount_cents')::int = 4000 AND NOT (a->'redemptions'->0->>'fee_paid_at_sale')::boolean, 'W6: imported card on a reservation ' || a::text;
  ASSERT jsonb_array_length(public._exos_reservation_gift_cards(o, NULL, r2->>'token')->'redemptions') = 1, 'W6: list';
  RAISE NOTICE 'OK  W6 reservations: apply, overdraw, remove, cancel, expiry, capture';
END $$;

-- W7 ------------------------------------------------------------------------------
DO $$
BEGIN
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_gift_cards c
                      WHERE c.org_id IN ('9b000000-0000-0000-0000-000000000001', '9b000000-0000-0000-0000-000000000002')
                        AND c.balance_cents <> pg_temp.sum_ledger(c.id)), 'W7: balance = ledger';
  RAISE NOTICE 'OK  W7 ledger invariant';
END $$;

ROLLBACK;
