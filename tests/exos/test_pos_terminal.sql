-- ============================================================================
-- Card at the door, Stripe Terminal (mig 20261107130000):
--   T1  RLS on the new tables, no client writes, grants (cores service role only)
--   T2  locations, readers, connection tokens: owner / manager only, payment
--       setup required, a reader is one org's, door staff of the event for tokens
--   T3  a card sale: pending (places reserved, nothing minted), charge plan from
--       the order, the PaymentIntent attached, capture, complete: tickets, the
--       card tender with terminal_ref, capacity
--   T4  a decline or a cancel gives the places back; never after money was taken
--   T5  webhook completion is idempotent (one set of tickets)
--   T6  a webhook after the door's own completion is a no-op
--   T7  void / refund of a card sale: the walk-up rules, the reversal ledger row
--       with the card part, the refund's state; the cash RPC and the API refuse it
--   T8  a capture that can't become tickets (places gone): refund_needed, order
--       cancelled, refund recorded
--   T9  the charge plan: who may, the reader is the org's, the order key, $0,
--       no payment setup, attach checks
--   T10 a card tender can't come from anywhere else (cash path, direct complete, RLS)
--   T11 cross-org isolation (cores, RLS, the readers RPC)
--   T12 settlement counts the card tender and its Exos fee
--   T13 a refund answer is bound to the recorded PaymentIntent and refund id:
--       the right order with another PaymentIntent, or another refund id,
--       changes nothing; the matching answer records; a fail / complete with
--       another PaymentIntent is ignored
-- Self-contained (BEGIN / ROLLBACK). Org …01: owner a1, manager a2, scanner a3
-- (assigned to e1), finance a4, scanner a6 (assigned to e2). Org …02: owner b9
-- (connected too). Org …03: owner c9, no payment setup.
-- ============================================================================
\set ON_ERROR_STOP on
BEGIN;

CREATE FUNCTION pg_temp.u(p text) RETURNS uuid LANGUAGE sql IMMUTABLE AS $$
  SELECT ('c0a70000-0000-0000-0000-0000000000' || p)::uuid $$;
CREATE FUNCTION pg_temp.k(p text) RETURNS uuid LANGUAGE sql IMMUTABLE AS $$
  SELECT ('c0a70000-0000-0000-0000-00000000c0' || p)::uuid $$;
CREATE FUNCTION pg_temp.act(p_uid uuid) RETURNS void LANGUAGE sql AS $$
  SELECT set_config('app.uid', coalesce(p_uid::text, ''), true), set_config('app.jwt', '', true) $$;
CREATE FUNCTION pg_temp.st(p_sql text) RETURNS text LANGUAGE plpgsql AS $$
BEGIN
  EXECUTE p_sql;
  RETURN 'ok';
EXCEPTION WHEN OTHERS THEN RETURN SQLSTATE;
END $$;
-- Begin a card walk-up (service role, as exos-pos calls it: no auth.uid()).
CREATE FUNCTION pg_temp.begin(p_actor text, p_tier text, p_qty int, p_key text, p_event text DEFAULT 'e1') RETURNS jsonb
LANGUAGE plpgsql AS $$
BEGIN
  PERFORM pg_temp.act(NULL);
  RETURN public._exos_pos_walkup_begin_card(pg_temp.u(p_actor), pg_temp.u(p_event), pg_temp.u(p_tier), p_qty, pg_temp.k(p_key),
                                            NULL, 'Card Buyer', NULL, NULL, false);
END $$;
-- Charge plan + attach a PaymentIntent (what exos-pos does around Stripe).
CREATE FUNCTION pg_temp.charge(p_actor text, p_order uuid, p_pi text) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE v_plan jsonb;
BEGIN
  v_plan := public._exos_pos_card_begin(pg_temp.u(p_actor), p_order, 'reader', pg_temp.v('reader_dev')::uuid, false);
  PERFORM public._exos_pos_card_attach(p_order, p_pi, (v_plan ->> 'amount_cents')::int, v_plan ->> 'currency', 100, 50, 50, 300);
  RETURN v_plan;
END $$;
CREATE FUNCTION pg_temp.sold(p_tier text) RETURNS int LANGUAGE sql AS $$
  SELECT sold FROM public.exos_ticket_tiers WHERE id = pg_temp.u(p_tier) $$;
CREATE TEMP TABLE tk (k text PRIMARY KEY, v text) ON COMMIT DROP;
CREATE FUNCTION pg_temp.v(p_k text) RETURNS text LANGUAGE sql AS $$ SELECT v FROM tk WHERE k = p_k $$;

INSERT INTO auth.users (id, email, email_confirmed_at) VALUES
  (pg_temp.u('a1'), 'c0a7-owner@x.com', now()), (pg_temp.u('a2'), 'c0a7-manager@x.com', now()),
  (pg_temp.u('a3'), 'c0a7-scanner@x.com', now()), (pg_temp.u('a4'), 'c0a7-finance@x.com', now()),
  (pg_temp.u('a6'), 'c0a7-scanner2@x.com', now()), (pg_temp.u('b9'), 'c0a7-other@x.com', now()),
  (pg_temp.u('c9'), 'c0a7-unset@x.com', now());
INSERT INTO public.exos_orgs (id, name, slug, owner_uid) VALUES
  (pg_temp.u('01'), 'Terminal Org', 'c0a7-org', pg_temp.u('a1')),
  (pg_temp.u('02'), 'Terminal Other', 'c0a7-other', pg_temp.u('b9')),
  (pg_temp.u('03'), 'Terminal Unset', 'c0a7-unset', pg_temp.u('c9'));
INSERT INTO public.exos_org_memberships (org_id, user_id, role) VALUES
  (pg_temp.u('01'), pg_temp.u('a1'), 'owner'), (pg_temp.u('01'), pg_temp.u('a2'), 'manager'),
  (pg_temp.u('01'), pg_temp.u('a3'), 'scanner'), (pg_temp.u('01'), pg_temp.u('a4'), 'finance'),
  (pg_temp.u('01'), pg_temp.u('a6'), 'scanner'),
  (pg_temp.u('02'), pg_temp.u('b9'), 'owner'), (pg_temp.u('03'), pg_temp.u('c9'), 'owner');
-- The harness has no phase-1 exos_org_secrets: its prod shape, rolled back.
CREATE TABLE IF NOT EXISTS public.exos_org_secrets (
  org_id uuid PRIMARY KEY, payments jsonb, updated_at timestamptz NOT NULL DEFAULT now());
INSERT INTO public.exos_org_secrets (org_id, payments) VALUES
  (pg_temp.u('01'), '{"connectedAccountId":"acct_termOrgA","chargesEnabled":true}'),
  (pg_temp.u('02'), '{"connectedAccountId":"acct_termOrgB","chargesEnabled":true}'),
  (pg_temp.u('03'), '{"connectedAccountId":"acct_termOrgC","chargesEnabled":false}')
ON CONFLICT (org_id) DO UPDATE SET payments = EXCLUDED.payments;
INSERT INTO public.exos_events (id, org_id, name, slug, status, starts_at, total_tickets, tickets_sold, currency, created_by) VALUES
  (pg_temp.u('e1'), pg_temp.u('01'), 'Terminal Night', 'c0a7-night', 'published', now() + interval '1 hour', 60, 0, 'usd', pg_temp.u('a1')),
  (pg_temp.u('e2'), pg_temp.u('01'), 'Terminal Other Night', 'c0a7-night2', 'published', now() + interval '1 day', 60, 0, 'usd', pg_temp.u('a1')),
  (pg_temp.u('e9'), pg_temp.u('02'), 'Terminal Elsewhere', 'c0a7-else', 'published', now() + interval '1 hour', 60, 0, 'usd', pg_temp.u('b9')),
  (pg_temp.u('e8'), pg_temp.u('03'), 'Terminal Unset Night', 'c0a7-unset', 'published', now() + interval '1 hour', 60, 0, 'usd', pg_temp.u('c9'));
INSERT INTO public.exos_event_staff (event_id, user_id, org_id) VALUES
  (pg_temp.u('e1'), pg_temp.u('a3'), pg_temp.u('01')), (pg_temp.u('e2'), pg_temp.u('a6'), pg_temp.u('01'));
INSERT INTO public.exos_ticket_tiers (id, event_id, name, price, capacity, sold, visibility, sort_order, door_price_cents) VALUES
  (pg_temp.u('d1'), pg_temp.u('e1'), 'GA', 20, 8, 0, 'public', 1, 2500),
  (pg_temp.u('d5'), pg_temp.u('e1'), 'Free', 0, 10, 0, 'public', 2, NULL),
  (pg_temp.u('d6'), pg_temp.u('e2'), 'GA', 10, 10, 0, 'public', 1, NULL),
  (pg_temp.u('d9'), pg_temp.u('e9'), 'GA', 10, 10, 0, 'public', 1, NULL),
  (pg_temp.u('d8'), pg_temp.u('e8'), 'GA', 10, 10, 0, 'public', 1, NULL);
INSERT INTO public.exos_api_keys (id, org_id, name, key_prefix, key_hash, scopes, created_by) VALUES
  (pg_temp.u('f1'), pg_temp.u('01'), 'manager key', 'sk_live_c0a71', 'c0a7hash1', ARRAY['orders:read','refunds:write'], pg_temp.u('a2'));

-- ── T1 ──────────────────────────────────────────────────────────────────────
DO $$
DECLARE t text; f text;
BEGIN
  FOREACH t IN ARRAY ARRAY['exos_pos_terminal_locations', 'exos_pos_terminal_readers', 'exos_pos_card_payments'] LOOP
    ASSERT (SELECT relrowsecurity FROM pg_class WHERE oid = ('public.' || t)::regclass), 'T1: RLS on ' || t;
    ASSERT NOT has_table_privilege('anon', 'public.' || t, 'SELECT'), 'T1: anon reads nothing of ' || t;
    ASSERT has_table_privilege('authenticated', 'public.' || t, 'SELECT'), 'T1: members read ' || t;
    ASSERT NOT has_table_privilege('authenticated', 'public.' || t, 'INSERT')
       AND NOT has_table_privilege('authenticated', 'public.' || t, 'UPDATE')
       AND NOT has_table_privilege('authenticated', 'public.' || t, 'DELETE'), 'T1: no client writes on ' || t;
  END LOOP;
  FOREACH f IN ARRAY ARRAY[
      'public._exos_pos_connected_account(uuid)', 'public._exos_pos_card_json(uuid)',
      'public._exos_pos_terminal_manage_check(uuid,uuid,boolean)',
      'public._exos_pos_terminal_save_location(uuid,uuid,boolean,text,text,jsonb)',
      'public._exos_pos_terminal_save_reader(uuid,uuid,boolean,text,text,text,uuid)',
      'public._exos_pos_terminal_token_check(uuid,uuid,boolean)',
      'public._exos_pos_walkup_begin_card(uuid,uuid,uuid,integer,uuid,uuid,text,text,jsonb,boolean)',
      'public._exos_pos_card_begin(uuid,uuid,text,uuid,boolean)',
      'public._exos_pos_card_attach(uuid,text,integer,text,integer,integer,integer,integer)',
      'public._exos_pos_card_lookup(uuid,uuid,text,boolean)', 'public._exos_pos_card_capture_prepare(uuid,text)',
      'public._exos_pos_card_complete(uuid,text,integer,text,text)', 'public._exos_pos_card_fail(uuid,text,text,text,text,text)',
      'public._exos_pos_card_reverse(uuid,uuid,text,text,boolean,uuid)', 'public._exos_pos_card_refund_record(uuid,text,text,text,text)'] LOOP
    ASSERT NOT has_function_privilege('authenticated', f, 'EXECUTE') AND NOT has_function_privilege('anon', f, 'EXECUTE')
       AND has_function_privilege('service_role', f, 'EXECUTE'), 'T1: service role only: ' || f;
    ASSERT (SELECT prosecdef AND proconfig::text LIKE '%search_path=public, pg_temp%' FROM pg_proc WHERE oid = f::regprocedure),
      'T1: definer with a fixed search_path: ' || f;
  END LOOP;
  ASSERT has_function_privilege('authenticated', 'public.exos_pos_card_readers(uuid)', 'EXECUTE')
     AND NOT has_function_privilege('anon', 'public.exos_pos_card_readers(uuid)', 'EXECUTE'), 'T1: readers RPC for members only';
  -- No column that could hold card data.
  ASSERT NOT EXISTS (SELECT 1 FROM information_schema.columns
                      WHERE table_schema = 'public' AND table_name IN ('exos_pos_terminal_locations', 'exos_pos_terminal_readers', 'exos_pos_card_payments')
                        AND column_name ~* '(pan|card_?number|cvc|cvv|expir|exp_month|exp_year|track|cardholder|last4)'),
    'T1: no card-data column';
  RAISE NOTICE 'OK T1 RLS on, reads only, cores service role only, no card-data column';
END $$;

-- ── T2 ──────────────────────────────────────────────────────────────────────
DO $$
DECLARE r jsonb; v_dev uuid;
BEGIN
  -- Locations and readers: owner / manager only; payment setup first.
  ASSERT (public._exos_pos_terminal_manage_check(pg_temp.u('a1'), pg_temp.u('01'), false) -> 'location') = 'null'::jsonb,
    'T2: owner, no location yet';
  ASSERT public._exos_pos_terminal_manage_check(pg_temp.u('a2'), pg_temp.u('01'), false) ->> 'org_id' = pg_temp.u('01')::text, 'T2: manager';
  ASSERT pg_temp.st(format('SELECT public._exos_pos_terminal_manage_check(%L, %L, false)', pg_temp.u('a3'), pg_temp.u('01'))) = '42501', 'T2: scanner refused';
  ASSERT pg_temp.st(format('SELECT public._exos_pos_terminal_manage_check(%L, %L, false)', pg_temp.u('a4'), pg_temp.u('01'))) = '42501', 'T2: finance refused';
  ASSERT pg_temp.st(format('SELECT public._exos_pos_terminal_manage_check(%L, %L, false)', pg_temp.u('b9'), pg_temp.u('01'))) = '42501', 'T2: another org''s owner refused';
  ASSERT pg_temp.st(format('SELECT public._exos_pos_terminal_manage_check(%L, %L, false)', pg_temp.u('c9'), pg_temp.u('03'))) = '55000', 'T2: payment setup first';
  ASSERT pg_temp.st(format('SELECT public._exos_pos_terminal_save_location(%L, %L, false, %L, %L, %L)', pg_temp.u('a3'), pg_temp.u('01'),
                           'tml_Scanner', 'Box', '{}')) = '42501', 'T2: scanner can''t store a location';
  -- A reader before a location: refused.
  ASSERT pg_temp.st(format('SELECT public._exos_pos_terminal_save_reader(%L, %L, false, %L, %L, NULL, NULL)', pg_temp.u('a1'), pg_temp.u('01'),
                           'tmr_Early', 'Door 1')) = '55000', 'T2: location first';
  r := public._exos_pos_terminal_save_location(pg_temp.u('a1'), pg_temp.u('01'), false, 'tml_OrgA', 'Terminal Org box office',
                                               '{"line1":"1 Main St","city":"Brooklyn","state":"NY","postal_code":"11201","country":"US"}');
  ASSERT r ->> 'stripe_location_id' = 'tml_OrgA', 'T2: location stored';
  -- A second create (a racing request) keeps the first.
  r := public._exos_pos_terminal_save_location(pg_temp.u('a2'), pg_temp.u('01'), false, 'tml_OrgA2', 'Other', '{"line1":"x"}');
  ASSERT r ->> 'stripe_location_id' = 'tml_OrgA', 'T2: one location per org and mode';
  ASSERT (SELECT count(*) FROM public.exos_pos_terminal_locations WHERE org_id = pg_temp.u('01')) = 1, 'T2: one row';
  PERFORM public._exos_pos_terminal_save_location(pg_temp.u('b9'), pg_temp.u('02'), false, 'tml_OrgB', 'Other box office', '{"line1":"2 Main St"}');
  -- Readers: owner / manager; a device of kind reader, active.
  ASSERT pg_temp.st(format('SELECT public._exos_pos_terminal_save_reader(%L, %L, false, %L, %L, NULL, NULL)', pg_temp.u('a3'), pg_temp.u('01'),
                           'tmr_Scanner', 'Door 1')) = '42501', 'T2: scanner can''t register a reader';
  r := public._exos_pos_terminal_save_reader(pg_temp.u('a2'), pg_temp.u('01'), false, 'tmr_DoorOne', 'Door 1', 'stripe_s700', NULL);
  v_dev := (r ->> 'device_id')::uuid;
  INSERT INTO tk VALUES ('reader_dev', v_dev::text);
  ASSERT (SELECT kind = 'reader' AND status = 'active' AND hardware_ref = 'tmr_DoorOne' AND org_id = pg_temp.u('01')
            FROM public.exos_pos_devices WHERE id = v_dev), 'T2: reader device';
  ASSERT (public._exos_pos_terminal_save_reader(pg_temp.u('a1'), pg_temp.u('01'), false, 'tmr_DoorOne', 'Door 1', NULL, NULL) ->> 'device_id')::uuid = v_dev,
    'T2: same reader again is the same device';
  ASSERT pg_temp.st(format('SELECT public._exos_pos_terminal_save_reader(%L, %L, false, %L, %L, NULL, NULL)', pg_temp.u('b9'), pg_temp.u('02'),
                           'tmr_DoorOne', 'Stolen')) = '23505', 'T2: another org can''t claim our reader';
  ASSERT pg_temp.st(format('SELECT public._exos_pos_terminal_save_reader(%L, %L, false, %L, %L, NULL, %L)', pg_temp.u('a1'), pg_temp.u('01'),
                           'tmr_Wrong', 'x', pg_temp.u('e9'))) = 'P0002', 'T2: an event of another org';
  -- A reader set to e2 only, and org B's reader.
  r := public._exos_pos_terminal_save_reader(pg_temp.u('a1'), pg_temp.u('01'), false, 'tmr_EventTwo', 'E2 reader', NULL, pg_temp.u('e2'));
  INSERT INTO tk VALUES ('e2_reader', r ->> 'device_id');
  r := public._exos_pos_terminal_save_reader(pg_temp.u('b9'), pg_temp.u('02'), false, 'tmr_OrgB', 'B reader', NULL, NULL);
  INSERT INTO tk VALUES ('b_reader', r ->> 'device_id');
  -- Connection tokens: door staff of the event, the org's location.
  ASSERT public._exos_pos_terminal_token_check(pg_temp.u('a3'), pg_temp.u('e1'), false) ->> 'location_id' = 'tml_OrgA', 'T2: scanner of e1';
  ASSERT public._exos_pos_terminal_token_check(pg_temp.u('a1'), pg_temp.u('e2'), false) ->> 'location_id' = 'tml_OrgA', 'T2: owner';
  ASSERT pg_temp.st(format('SELECT public._exos_pos_terminal_token_check(%L, %L, false)', pg_temp.u('a6'), pg_temp.u('e1'))) = '42501',
    'T2: a scanner of another event';
  ASSERT pg_temp.st(format('SELECT public._exos_pos_terminal_token_check(%L, %L, false)', pg_temp.u('a4'), pg_temp.u('e1'))) = '42501', 'T2: finance';
  ASSERT pg_temp.st(format('SELECT public._exos_pos_terminal_token_check(%L, %L, false)', pg_temp.u('b9'), pg_temp.u('e1'))) = '42501', 'T2: another org';
  ASSERT pg_temp.st(format('SELECT public._exos_pos_terminal_token_check(%L, %L, true)', pg_temp.u('a3'), pg_temp.u('e1'))) = '55000',
    'T2: no live location yet';
  ASSERT pg_temp.st(format('SELECT public._exos_pos_terminal_token_check(%L, %L, false)', pg_temp.u('c9'), pg_temp.u('e8'))) = '55000',
    'T2: no location at all';
  RAISE NOTICE 'OK T2 locations / readers owner-manager only, one location per org, readers are one org''s, tokens door staff only';
END $$;

-- ── T3 ──────────────────────────────────────────────────────────────────────
DO $$
DECLARE r jsonb; v_o uuid; v_avail int; v_plan jsonb; v_sold int; v_ev int;
BEGIN
  v_avail := public.exos_effective_available(pg_temp.u('d1'));
  v_sold := pg_temp.sold('d1');
  SELECT tickets_sold INTO v_ev FROM public.exos_events WHERE id = pg_temp.u('e1');
  r := pg_temp.begin('a3', 'd1', 2, '01');
  v_o := (r ->> 'id')::uuid;
  INSERT INTO tk VALUES ('t3', v_o::text);
  ASSERT r ->> 'status' = 'pending' AND (r ->> 'total_cents')::int = 5000 AND r -> 'card' ->> 'status' = 'awaiting', 'T3: pending ' || r::text;
  ASSERT public.exos_effective_available(pg_temp.u('d1')) = v_avail - 2, 'T3: places reserved';
  ASSERT pg_temp.sold('d1') = v_sold AND NOT EXISTS (SELECT 1 FROM public.exos_tickets WHERE order_ref = 'pos:' || v_o), 'T3: nothing minted';
  ASSERT (SELECT expires_at > now() + interval '4 minutes' FROM public.exos_cart_holds WHERE pos_order_id = v_o LIMIT 1), 'T3: 5 minutes to pay';
  -- The charge plan: the order's amount, the connected account, the location and the reader.
  v_plan := public._exos_pos_card_begin(pg_temp.u('a3'), v_o, 'reader', pg_temp.v('reader_dev')::uuid, false);
  ASSERT (v_plan ->> 'amount_cents')::int = 5000 AND v_plan ->> 'currency' = 'usd' AND v_plan ->> 'destination' = 'acct_termOrgA'
     AND v_plan ->> 'location_id' = 'tml_OrgA' AND v_plan ->> 'reader_id' = 'tmr_DoorOne' AND v_plan ->> 'fee_base' = 'card-tickets'
     AND (v_plan ->> 'fee_bps')::int = public.exos_event_fee_bps(pg_temp.u('e1'), now()) AND NOT (v_plan ->> 'done')::boolean,
    'T3: plan ' || v_plan::text;
  ASSERT public._exos_pos_card_attach(v_o, 'pi_T3door', 5000, 'usd', 266, 120, 146, 300) ->> 'cancel' = 'false', 'T3: attached';
  ASSERT (SELECT status = 'processing' AND payment_intent_id = 'pi_T3door' AND application_fee_cents = 266 FROM public.exos_pos_card_payments WHERE order_id = v_o),
    'T3: processing';
  -- A retry of the charge returns the same PaymentIntent.
  ASSERT public._exos_pos_card_begin(pg_temp.u('a3'), v_o, 'reader', pg_temp.v('reader_dev')::uuid, false) ->> 'payment_intent_id' = 'pi_T3door',
    'T3: the same PaymentIntent on a retry';
  -- Authorized: capture, then complete.
  ASSERT public._exos_pos_card_capture_prepare(v_o, 'pi_T3door') ->> 'action' = 'capture', 'T3: capture';
  ASSERT public._exos_pos_card_capture_prepare(v_o, 'pi_Other') ->> 'action' = 'ignore', 'T3: another PaymentIntent is ignored';
  r := public._exos_pos_card_complete(v_o, 'pi_T3door', 5000, 'door', NULL);
  ASSERT r ->> 'status' = 'paid' AND r ->> 'payment_method' = 'card' AND (r -> 'tenders' ->> 'card')::int = 5000
     AND NOT (r ->> 'replay')::boolean AND NOT (r ->> 'refund_needed')::boolean, 'T3: paid by card ' || r::text;
  ASSERT (SELECT count(*) FROM public.exos_tickets WHERE order_ref = 'pos:' || v_o AND channel_source = 'pos' AND status = 'active') = 2,
    'T3: two tickets';
  ASSERT (SELECT terminal_ref FROM public.exos_pos_payments WHERE order_id = v_o AND method = 'card') = 'pi_T3door'
     AND (SELECT drawer_session_id IS NULL AND taken_by = pg_temp.u('a3') FROM public.exos_pos_payments WHERE order_id = v_o AND method = 'card'),
    'T3: the card tender is the PaymentIntent, no drawer';
  ASSERT (SELECT status = 'succeeded' AND completed_via = 'door' FROM public.exos_pos_card_payments WHERE order_id = v_o), 'T3: card row succeeded';
  ASSERT pg_temp.sold('d1') = v_sold + 2 AND (SELECT tickets_sold FROM public.exos_events WHERE id = pg_temp.u('e1')) = v_ev + 2,
    'T3: sold counts';
  ASSERT public.exos_effective_available(pg_temp.u('d1')) = v_avail - 2, 'T3: capacity used once (holds consumed, tickets sold)';
  RAISE NOTICE 'OK T3 card sale: pending, plan from the order, PaymentIntent attached, capture, complete, tickets + card tender, capacity';
END $$;

-- ── T4 ──────────────────────────────────────────────────────────────────────
DO $$
DECLARE r jsonb; v_o uuid; v_o2 uuid; v_avail int;
BEGIN
  v_avail := public.exos_effective_available(pg_temp.u('d1'));
  -- Declined on the reader.
  v_o := (pg_temp.begin('a3', 'd1', 2, '02') ->> 'id')::uuid;
  PERFORM pg_temp.charge('a3', v_o, 'pi_T4decl');
  ASSERT public.exos_effective_available(pg_temp.u('d1')) = v_avail - 2, 'T4: held';
  r := public._exos_pos_card_fail(v_o, 'pi_T4decl', 'declined', 'insufficient_funds', 'door', 'card declined');
  ASSERT r ->> 'status' = 'void' AND r -> 'card' ->> 'status' = 'declined' AND r -> 'card' ->> 'decline_code' = 'insufficient_funds',
    'T4: declined -> cancelled ' || r::text;
  ASSERT public.exos_effective_available(pg_temp.u('d1')) = v_avail, 'T4: places back';
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_tickets WHERE order_ref = 'pos:' || v_o), 'T4: no tickets';
  -- Again (the webhook's copy): idempotent.
  ASSERT public._exos_pos_card_fail(v_o, 'pi_T4decl', 'declined', NULL, 'webhook', NULL) ->> 'status' = 'void', 'T4: replay';
  -- A capture prepared on it afterwards: cancel (an authorization is never captured for a dead sale).
  ASSERT public._exos_pos_card_capture_prepare(v_o, 'pi_T4decl') ->> 'action' = 'cancel', 'T4: no capture after a decline';
  -- Cancelled before any PaymentIntent.
  v_o2 := (pg_temp.begin('a3', 'd1', 1, '03') ->> 'id')::uuid;
  r := public._exos_pos_card_fail(v_o2, NULL, 'canceled', NULL, 'door', 'buyer walked away');
  ASSERT r ->> 'status' = 'void' AND r -> 'card' ->> 'status' = 'canceled', 'T4: cancelled';
  ASSERT public.exos_effective_available(pg_temp.u('d1')) = v_avail, 'T4: places back again';
  -- Never after money was taken: a fail on the paid T3 sale is ignored.
  r := public._exos_pos_card_fail(pg_temp.v('t3')::uuid, 'pi_T3door', 'canceled', NULL, 'webhook', NULL);
  ASSERT (r ->> 'ignored')::boolean AND (SELECT status FROM public.exos_pos_orders WHERE id = pg_temp.v('t3')::uuid) = 'paid',
    'T4: a paid sale is never cancelled';
  ASSERT pg_temp.st(format('SELECT public._exos_pos_card_fail(%L, NULL, %L, NULL, NULL, NULL)', v_o, 'succeeded')) = '22023', 'T4: only declined / canceled';
  RAISE NOTICE 'OK T4 decline / cancel give the places back, idempotent, never after money was taken';
END $$;

-- ── T5 ──────────────────────────────────────────────────────────────────────
DO $$
DECLARE r jsonb; v_o uuid; v_sold int;
BEGIN
  v_sold := pg_temp.sold('d1');
  v_o := (pg_temp.begin('a3', 'd1', 1, '05') ->> 'id')::uuid;
  PERFORM pg_temp.charge('a3', v_o, 'pi_T5hook');
  -- The door app died: the webhook captures and completes, twice (a replay).
  ASSERT public._exos_pos_card_capture_prepare(v_o, 'pi_T5hook') ->> 'action' = 'capture', 'T5: capture';
  r := public._exos_pos_card_complete(v_o, 'pi_T5hook', 2500, 'webhook', 'evt_T5first');
  ASSERT r ->> 'status' = 'paid' AND NOT (r ->> 'replay')::boolean, 'T5: completed by the webhook';
  r := public._exos_pos_card_complete(v_o, 'pi_T5hook', 2500, 'webhook', 'evt_T5again');
  ASSERT (r ->> 'replay')::boolean AND r ->> 'status' = 'paid', 'T5: the replay is a no-op';
  ASSERT (SELECT count(*) FROM public.exos_tickets WHERE order_ref = 'pos:' || v_o) = 1, 'T5: one ticket';
  ASSERT (SELECT count(*) FROM public.exos_pos_payments WHERE order_id = v_o) = 1, 'T5: one tender';
  ASSERT pg_temp.sold('d1') = v_sold + 1, 'T5: sold once';
  ASSERT (SELECT completed_via = 'webhook' AND stripe_event_id = 'evt_T5first' FROM public.exos_pos_card_payments WHERE order_id = v_o),
    'T5: recorded as the webhook''s';
  ASSERT public._exos_pos_card_capture_prepare(v_o, 'pi_T5hook') ->> 'action' = 'done', 'T5: nothing more to capture';
  INSERT INTO tk VALUES ('t5', v_o::text);
  RAISE NOTICE 'OK T5 webhook completion is idempotent: one ticket, one tender';
END $$;

-- ── T6 ──────────────────────────────────────────────────────────────────────
DO $$
DECLARE r jsonb; v_o uuid := pg_temp.v('t3')::uuid; v_n int; v_sold int;
BEGIN
  SELECT count(*) INTO v_n FROM public.exos_tickets WHERE order_ref = 'pos:' || v_o;
  v_sold := pg_temp.sold('d1');
  -- The door completed T3; the webhook arrives after: amount_capturable_updated, then succeeded.
  ASSERT public._exos_pos_card_capture_prepare(v_o, 'pi_T3door') ->> 'action' = 'done', 'T6: already done';
  r := public._exos_pos_card_complete(v_o, 'pi_T3door', 5000, 'webhook', 'evt_T6late');
  ASSERT (r ->> 'replay')::boolean AND NOT (r ->> 'refund_needed')::boolean, 'T6: no-op ' || r::text;
  ASSERT (SELECT count(*) FROM public.exos_tickets WHERE order_ref = 'pos:' || v_o) = v_n AND pg_temp.sold('d1') = v_sold, 'T6: nothing minted';
  ASSERT (SELECT completed_via FROM public.exos_pos_card_payments WHERE order_id = v_o) = 'door', 'T6: still the door''s';
  -- A failure event after the capture changes nothing either.
  ASSERT (public._exos_pos_card_fail(v_o, 'pi_T3door', 'declined', 'generic_decline', 'webhook', NULL) ->> 'ignored')::boolean, 'T6: fail ignored';
  RAISE NOTICE 'OK T6 a webhook after the door''s completion is a no-op';
END $$;

-- ── T7 ──────────────────────────────────────────────────────────────────────
DO $$
DECLARE r jsonb; v_o uuid := pg_temp.v('t3')::uuid; v_o2 uuid; v_avail int; v_sold int;
BEGIN
  -- The cash path can't reverse a card sale (the card must be refunded): 0A000.
  PERFORM pg_temp.act(pg_temp.u('a3'));
  ASSERT pg_temp.st(format('SELECT public.exos_pos_void_order(%L, %L)', v_o, 'cash path')) = '0A000', 'T7: cash RPC refuses a card sale';
  ASSERT pg_temp.st(format('SELECT public._exos_api_pos_void(%L, %L, %L, %L, %L, NULL)', pg_temp.u('01'), pg_temp.u('f1'), pg_temp.u('e1'), v_o, 'api void')) = '0A000',
    'T7: the API void refuses a card sale';
  -- Refund needs an owner / manager.
  ASSERT pg_temp.st(format('SELECT public._exos_pos_card_reverse(%L, %L, %L, %L, false, NULL)', pg_temp.u('a3'), v_o, 'refund', 'nope')) = '42501',
    'T7: a scanner can''t refund';
  ASSERT pg_temp.st(format('SELECT public._exos_pos_card_reverse(%L, %L, %L, %L, false, NULL)', pg_temp.u('a6'), v_o, 'void', 'nope')) = 'P0002',
    'T7: a scanner of another event doesn''t see it';
  -- The seller voids it the same night: tickets voided, places back, the ledger row with the card part.
  v_avail := public.exos_effective_available(pg_temp.u('d1'));
  v_sold := pg_temp.sold('d1');
  r := public._exos_pos_card_reverse(pg_temp.u('a3'), v_o, 'void', 'wrong night', false, NULL);
  ASSERT r ->> 'status' = 'void' AND r -> 'card_refund' ->> 'payment_intent' = 'pi_T3door'
     AND (r -> 'card_refund' ->> 'amount_cents')::int = 5000 AND r -> 'card_refund' ->> 'status' = 'pending', 'T7: void ' || r::text;
  ASSERT (SELECT card_cents = 5000 AND cash_cents = 0 AND kind = 'void' AND card_refund_status = 'pending' AND tickets_voided = 2
            FROM public.exos_pos_reversals WHERE order_id = v_o), 'T7: ledger row';
  ASSERT pg_temp.sold('d1') = v_sold - 2 AND public.exos_effective_available(pg_temp.u('d1')) = v_avail + 2, 'T7: places back';
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_pos_paid_outs WHERE order_id = v_o), 'T7: no cash paid out';
  -- A replay answers the pending refund (exos-pos retries it with the same key).
  r := public._exos_pos_card_reverse(pg_temp.u('a3'), v_o, 'void', 'wrong night', false, NULL);
  ASSERT (r ->> 'replay')::boolean AND r -> 'card_refund' ->> 'status' = 'pending', 'T7: replay';
  -- Stripe's answer, then the webhook's later one.
  PERFORM public._exos_pos_card_refund_record(v_o, 'pi_T3door', 're_T7void', 'pending', NULL);
  PERFORM public._exos_pos_card_refund_record(v_o, 'pi_T3door', 're_T7void', 'succeeded', NULL);
  ASSERT (SELECT card_refund_ref = 're_T7void' AND card_refund_status = 'succeeded' FROM public.exos_pos_reversals WHERE order_id = v_o), 'T7: refunded';
  PERFORM public._exos_pos_card_refund_record(v_o, 'pi_T3door', 're_T7void', 'pending', NULL);
  ASSERT (SELECT card_refund_status FROM public.exos_pos_reversals WHERE order_id = v_o) = 'succeeded', 'T7: a late pending doesn''t undo it';
  -- After a scan: a refund needs the manager's override.
  v_o2 := pg_temp.v('t5')::uuid;
  UPDATE public.exos_tickets SET status = 'used', check_in_at = now() WHERE order_ref = 'pos:' || v_o2;
  ASSERT pg_temp.st(format('SELECT public._exos_pos_card_reverse(%L, %L, %L, %L, false, NULL)', pg_temp.u('a3'), v_o2, 'void', 'scanned')) = '55000',
    'T7: no void after a scan';
  ASSERT pg_temp.st(format('SELECT public._exos_pos_card_reverse(%L, %L, %L, %L, false, NULL)', pg_temp.u('a2'), v_o2, 'refund', 'scanned')) = '55000',
    'T7: refund after a scan needs the override';
  r := public._exos_pos_card_reverse(pg_temp.u('a2'), v_o2, 'refund', 'guest left early', true, NULL);
  ASSERT r ->> 'status' = 'refunded' AND (r ->> 'override')::boolean AND (r ->> 'tickets_kept')::int = 1
     AND (r -> 'card_refund' ->> 'amount_cents')::int = 2500, 'T7: refund with the override ' || r::text;
  PERFORM public._exos_pos_card_refund_record(v_o2, 'pi_T5hook', NULL, 'failed', 'charge_already_refunded');
  ASSERT (SELECT card_refund_status = 'failed' AND card_refund_error = 'charge_already_refunded' FROM public.exos_pos_reversals WHERE order_id = v_o2),
    'T7: a failed refund is on the ledger for the operator';
  RAISE NOTICE 'OK T7 void / refund of a card sale: walk-up rules, ledger row with the card part, refund state; cash RPC / API refuse it';
END $$;

-- ── T8 ──────────────────────────────────────────────────────────────────────
DO $$
DECLARE r jsonb; v_o uuid; v_avail int;
BEGIN
  v_avail := public.exos_effective_available(pg_temp.u('d1'));
  v_o := (pg_temp.begin('a3', 'd1', 1, '08') ->> 'id')::uuid;
  PERFORM pg_temp.charge('a3', v_o, 'pi_T8late');
  -- The guest took too long: the places lapsed.
  UPDATE public.exos_cart_holds SET expires_at = now() - interval '1 second' WHERE pos_order_id = v_o;
  ASSERT public._exos_pos_card_capture_prepare(v_o, 'pi_T8late') ->> 'action' = 'cancel', 'T8: don''t capture';
  -- Captured anyway (a delayed webhook, a capture already in flight): refund, never a silent charge.
  r := public._exos_pos_card_complete(v_o, 'pi_T8late', 2500, 'webhook', 'evt_T8');
  ASSERT (r ->> 'refund_needed')::boolean AND r -> 'card' ->> 'status' = 'refund_pending', 'T8: refund needed ' || r::text;
  ASSERT (SELECT status FROM public.exos_pos_orders WHERE id = v_o) = 'void'
     AND NOT EXISTS (SELECT 1 FROM public.exos_tickets WHERE order_ref = 'pos:' || v_o)
     AND NOT EXISTS (SELECT 1 FROM public.exos_pos_payments WHERE order_id = v_o), 'T8: no tickets, no tender, cancelled';
  ASSERT public.exos_effective_available(pg_temp.u('d1')) = v_avail, 'T8: places back';
  -- The second delivery asks for the same refund (Stripe's key makes it one).
  ASSERT (public._exos_pos_card_complete(v_o, 'pi_T8late', 2500, 'webhook', 'evt_T8b') ->> 'refund_needed')::boolean, 'T8: still pending';
  PERFORM public._exos_pos_card_refund_record(v_o, 'pi_T8late', 're_T8auto', 'succeeded', NULL);
  ASSERT (SELECT status = 'refunded' AND refund_ref = 're_T8auto' FROM public.exos_pos_card_payments WHERE order_id = v_o), 'T8: refunded';
  ASSERT NOT (public._exos_pos_card_complete(v_o, 'pi_T8late', 2500, 'webhook', 'evt_T8c') ->> 'refund_needed')::boolean, 'T8: done';
  -- An amount that doesn't match the sale is refunded too.
  v_o := (pg_temp.begin('a3', 'd1', 1, '09') ->> 'id')::uuid;
  PERFORM pg_temp.charge('a3', v_o, 'pi_T8amount');
  ASSERT (public._exos_pos_card_complete(v_o, 'pi_T8amount', 2400, 'door', NULL) ->> 'refund_needed')::boolean, 'T8: wrong amount';
  RAISE NOTICE 'OK T8 a capture that can''t become tickets is cancelled and refunded in full';
END $$;

-- ── T9 ──────────────────────────────────────────────────────────────────────
DO $$
DECLARE r jsonb; v_o uuid;
BEGIN
  v_o := (pg_temp.begin('a3', 'd1', 1, '10') ->> 'id')::uuid;
  -- Who may charge: the seller, an owner or a manager.
  ASSERT pg_temp.st(format('SELECT public._exos_pos_card_begin(%L, %L, %L, %L, false)', pg_temp.u('a6'), v_o, 'reader', pg_temp.v('reader_dev'))) = 'P0002',
    'T9: scanner of another event';
  ASSERT pg_temp.st(format('SELECT public._exos_pos_card_begin(%L, %L, %L, %L, false)', pg_temp.u('a4'), v_o, 'reader', pg_temp.v('reader_dev'))) = 'P0002',
    'T9: finance';
  ASSERT public._exos_pos_card_begin(pg_temp.u('a2'), v_o, 'reader', pg_temp.v('reader_dev')::uuid, false) ->> 'order_id' = v_o::text, 'T9: manager';
  -- The reader: the org's, active, org-wide or set to this event, this mode.
  ASSERT pg_temp.st(format('SELECT public._exos_pos_card_begin(%L, %L, %L, %L, false)', pg_temp.u('a3'), v_o, 'reader', pg_temp.v('e2_reader'))) = '55000',
    'T9: a reader set to another event';
  ASSERT pg_temp.st(format('SELECT public._exos_pos_card_begin(%L, %L, %L, %L, false)', pg_temp.u('a3'), v_o, 'reader', pg_temp.v('b_reader'))) = '55000',
    'T9: another org''s reader';
  ASSERT pg_temp.st(format('SELECT public._exos_pos_card_begin(%L, %L, %L, %L, true)', pg_temp.u('a3'), v_o, 'reader', pg_temp.v('reader_dev'))) = '55000',
    'T9: the other Stripe mode';
  UPDATE public.exos_pos_devices SET status = 'disabled' WHERE id = pg_temp.v('reader_dev')::uuid;
  ASSERT pg_temp.st(format('SELECT public._exos_pos_card_begin(%L, %L, %L, %L, false)', pg_temp.u('a3'), v_o, 'reader', pg_temp.v('reader_dev'))) = '55000',
    'T9: a disabled reader';
  UPDATE public.exos_pos_devices SET status = 'active' WHERE id = pg_temp.v('reader_dev')::uuid;
  -- An owner editing the device's hardware_ref can't point a charge at another reader.
  UPDATE public.exos_pos_devices SET hardware_ref = 'tmr_OrgB' WHERE id = pg_temp.v('reader_dev')::uuid;
  ASSERT public._exos_pos_card_begin(pg_temp.u('a3'), v_o, 'reader', pg_temp.v('reader_dev')::uuid, false) ->> 'reader_id' = 'tmr_DoorOne',
    'T9: the registered reader id, not the editable hardware_ref';
  UPDATE public.exos_pos_devices SET hardware_ref = 'tmr_DoorOne' WHERE id = pg_temp.v('reader_dev')::uuid;
  -- SDK mode needs no reader.
  ASSERT public._exos_pos_card_begin(pg_temp.u('a3'), v_o, 'sdk', NULL, false) ->> 'mode' = 'sdk', 'T9: sdk mode';
  ASSERT pg_temp.st(format('SELECT public._exos_pos_card_begin(%L, %L, %L, NULL, false)', pg_temp.u('a3'), v_o, 'tap')) = '22023', 'T9: bad mode';
  -- Attach: the amount and currency are the order's.
  ASSERT pg_temp.st(format('SELECT public._exos_pos_card_attach(%L, %L, 2400, %L, 0, 0, 0, 300)', v_o, 'pi_T9bad', 'usd')) = '22023', 'T9: amount';
  ASSERT pg_temp.st(format('SELECT public._exos_pos_card_attach(%L, %L, 2500, %L, 0, 0, 0, 300)', v_o, 'pi_T9bad', 'eur')) = '22023', 'T9: currency';
  PERFORM public._exos_pos_card_attach(v_o, 'pi_T9ok', 2500, 'usd', 0, 0, 0, 300);
  ASSERT pg_temp.st(format('SELECT public._exos_pos_card_attach(%L, %L, 2500, %L, 0, 0, 0, 300)', v_o, 'pi_T9second', 'usd')) = '23505',
    'T9: one PaymentIntent per sale';
  -- The sale ended meanwhile: attach says cancel.
  PERFORM public._exos_pos_card_fail(v_o, 'pi_T9ok', 'canceled', NULL, 'door', NULL);
  ASSERT (public._exos_pos_card_attach(v_o, 'pi_T9ok', 2500, 'usd', 0, 0, 0, 300) ->> 'cancel')::boolean, 'T9: cancel after the sale ended';
  -- The order key: a double tap is the same pending sale; reused for another sale, refused.
  r := pg_temp.begin('a3', 'd1', 1, '11');
  ASSERT (pg_temp.begin('a3', 'd1', 1, '11') ->> 'id') = r ->> 'id' AND (pg_temp.begin('a3', 'd1', 1, '11') ->> 'replay')::boolean, 'T9: double tap';
  ASSERT pg_temp.st(format('SELECT pg_temp.begin(%L, %L, 2, %L)', 'a3', 'd1', '11')) = '23505', 'T9: key reused';
  ASSERT pg_temp.st(format('SELECT pg_temp.begin(%L, %L, 1, %L)', 'a2', 'd1', '11')) = '23505', 'T9: key reused by another member';
  -- A cash sale's key can't be replayed as a card sale.
  PERFORM pg_temp.act(pg_temp.u('a1'));
  PERFORM public.exos_pos_walkup_sell(pg_temp.u('e1'), pg_temp.u('d5'), 1, pg_temp.k('12'), 1, 'comp');
  ASSERT pg_temp.st(format('SELECT pg_temp.begin(%L, %L, 1, %L)', 'a1', 'd5', '12')) = '23505', 'T9: a cash / comp key';
  -- $0 is cash; no payment setup, no card; nobody outside the event.
  ASSERT pg_temp.st(format('SELECT pg_temp.begin(%L, %L, 1, %L)', 'a3', 'd5', '13')) = '22023', 'T9: nothing to charge';
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_pos_orders WHERE client_ref = pg_temp.k('13')), 'T9: rolled back';
  ASSERT pg_temp.st(format('SELECT pg_temp.begin(%L, %L, 1, %L, %L)', 'c9', 'd8', '14', 'e8')) = '55000', 'T9: no payment setup';
  ASSERT pg_temp.st(format('SELECT pg_temp.begin(%L, %L, 1, %L)', 'a6', 'd1', '15')) = '42501', 'T9: a scanner of another event';
  ASSERT pg_temp.st(format('SELECT pg_temp.begin(%L, %L, 1, %L)', 'a4', 'd1', '16')) = '42501', 'T9: finance can''t sell';
  -- A card sale that isn't paid can't be charged twice after it's done.
  ASSERT pg_temp.st(format('SELECT public._exos_pos_card_begin(%L, %L, %L, %L, false)', pg_temp.u('a3'), v_o, 'reader', pg_temp.v('reader_dev'))) = '55000',
    'T9: a cancelled sale can''t be charged';
  RAISE NOTICE 'OK T9 charge plan: seller / owner / manager, the org''s registered reader, the order''s amount, the order key, $0, payment setup';
END $$;

-- ── T10 ─────────────────────────────────────────────────────────────────────
DO $$
DECLARE v_o uuid;
BEGIN
  PERFORM pg_temp.act(pg_temp.u('a2'));
  ASSERT pg_temp.st(format('SELECT public.exos_pos_walkup_sell(%L, %L, 1, %L, 0, %L)', pg_temp.u('e1'), pg_temp.u('d1'), pg_temp.k('20'), 'card')) = '0A000',
    'T10: the cash path still refuses card';
  v_o := (pg_temp.begin('a2', 'd1', 1, '21') ->> 'id')::uuid;
  ASSERT pg_temp.st(format('SELECT public._exos_pos_walkup_complete(%L, %L, %L, NULL, NULL)', pg_temp.u('a2'), v_o, 'card')) = '0A000',
    'T10: no card tender without the card path';
  ASSERT pg_temp.st(format('SELECT public._exos_pos_card_complete(%L, %L, 2500, %L, NULL)', v_o, 'pi_NotAttached', 'door')) = 'P0002',
    'T10: a PaymentIntent that isn''t the sale''s';
  PERFORM public._exos_pos_card_fail(v_o, NULL, 'canceled', NULL, 'door', NULL);
END $$;
SET ROLE authenticated;
SELECT pg_temp.act(pg_temp.u('a2'));
DO $$
BEGIN
  ASSERT pg_temp.st(format('INSERT INTO public.exos_pos_payments (order_id, org_id, event_id, method, amount_cents, terminal_ref) VALUES (%L, %L, %L, %L, 100, %L)',
                           (SELECT id FROM public.exos_pos_orders WHERE client_ref = 'c0a70000-0000-0000-0000-00000000c021'),
                           'c0a70000-0000-0000-0000-000000000001', 'c0a70000-0000-0000-0000-0000000000e1', 'card', 'pi_Forged')) <> 'ok',
    'T10: a client can''t write a card tender';
  ASSERT pg_temp.st('INSERT INTO public.exos_pos_card_payments (org_id, event_id, order_id, amount_cents, currency) VALUES ('
                    || quote_literal('c0a70000-0000-0000-0000-000000000001') || ', ' || quote_literal('c0a70000-0000-0000-0000-0000000000e1') || ', '
                    || quote_literal((SELECT id FROM public.exos_pos_orders WHERE client_ref = 'c0a70000-0000-0000-0000-00000000c021')) || ', 1, ''usd'')') = '42501',
    'T10: no client writes on card rows';
  RAISE NOTICE 'OK T10 a card tender comes only from the card path';
END $$;
RESET ROLE;

-- ── T11 ─────────────────────────────────────────────────────────────────────
DO $$
DECLARE v_o uuid := pg_temp.v('t3')::uuid;
BEGIN
  ASSERT pg_temp.st(format('SELECT public._exos_pos_card_begin(%L, %L, %L, %L, false)', pg_temp.u('b9'), v_o, 'reader', pg_temp.v('b_reader'))) = 'P0002',
    'T11: another org can''t charge our sale';
  ASSERT pg_temp.st(format('SELECT public._exos_pos_card_lookup(%L, %L, %L, false)', pg_temp.u('b9'), v_o, 'read')) = 'P0002', 'T11: nor read it';
  ASSERT pg_temp.st(format('SELECT public._exos_pos_card_reverse(%L, %L, %L, %L, false, NULL)', pg_temp.u('b9'), v_o, 'refund', 'theirs')) = 'P0002',
    'T11: nor refund it';
  ASSERT pg_temp.st(format('SELECT pg_temp.begin(%L, %L, 1, %L, %L)', 'b9', 'd1', '30', 'e1')) = '42501', 'T11: nor sell at our event';
  ASSERT (public._exos_pos_card_lookup(pg_temp.u('a3'), v_o, 'read', false) ->> 'is_card')::boolean, 'T11: our scanner reads it';
  ASSERT pg_temp.st(format('SELECT public._exos_pos_card_lookup(%L, %L, %L, false)', pg_temp.u('a6'), v_o, 'act')) = 'P0002',
    'T11: a scanner of another event can''t act on it';
END $$;
SET ROLE authenticated;
SELECT pg_temp.act(pg_temp.u('b9'));
DO $$
BEGIN
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_pos_card_payments WHERE org_id = 'c0a70000-0000-0000-0000-000000000001')
     AND NOT EXISTS (SELECT 1 FROM public.exos_pos_terminal_readers WHERE org_id = 'c0a70000-0000-0000-0000-000000000001')
     AND NOT EXISTS (SELECT 1 FROM public.exos_pos_terminal_locations WHERE org_id = 'c0a70000-0000-0000-0000-000000000001'),
    'T11: another org sees none of our rows';
  ASSERT (SELECT count(*) FROM public.exos_pos_terminal_readers) = 1, 'T11: but its own reader';
  ASSERT pg_temp.st('SELECT public.exos_pos_card_readers(''c0a70000-0000-0000-0000-0000000000e1'')') = '42501', 'T11: nor our readers';
END $$;
SELECT pg_temp.act(pg_temp.u('a3'));
DO $$
DECLARE r jsonb;
BEGIN
  r := public.exos_pos_card_readers('c0a70000-0000-0000-0000-0000000000e1');
  ASSERT jsonb_array_length(r -> 'readers') = 1 AND r -> 'readers' -> 0 ->> 'label' = 'Door 1' AND NOT (r ->> 'can_manage')::boolean,
    'T11: e1''s scanner sees the org-wide reader, not e2''s ' || r::text;
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_pos_terminal_locations), 'T11: a scanner doesn''t read the location''s address';
  ASSERT (SELECT count(*) FROM public.exos_pos_card_payments WHERE event_id = 'c0a70000-0000-0000-0000-0000000000e1') > 0,
    'T11: door staff read their event''s card rows';
END $$;
SELECT pg_temp.act(pg_temp.u('a6'));
DO $$
BEGIN
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_pos_card_payments WHERE event_id = 'c0a70000-0000-0000-0000-0000000000e1'),
    'T11: a scanner of e2 doesn''t read e1''s card rows';
  ASSERT jsonb_array_length(public.exos_pos_card_readers('c0a70000-0000-0000-0000-0000000000e2') -> 'readers') = 2,
    'T11: e2 has the org-wide reader and its own';
END $$;
SELECT pg_temp.act(pg_temp.u('a4'));
DO $$
BEGIN
  ASSERT (SELECT count(*) FROM public.exos_pos_terminal_locations) = 1 AND (SELECT count(*) FROM public.exos_pos_card_payments) > 0,
    'T11: finance reads the location and the card rows';
  RAISE NOTICE 'OK T11 cross-org isolation: cores, RLS and the readers RPC';
END $$;
RESET ROLE;

-- ── T12 ─────────────────────────────────────────────────────────────────────
DO $$
DECLARE r jsonb; v_o uuid; s1 jsonb; s2 jsonb; v_bps int;
BEGIN
  PERFORM pg_temp.act(pg_temp.u('a1'));
  s1 := public.exos_pos_settlement_summary(pg_temp.u('e1'));
  -- exos-pos calls the cores with the service role: no auth.uid().
  PERFORM pg_temp.act(NULL);
  v_o := (pg_temp.begin('a3', 'd1', 2, '40') ->> 'id')::uuid;
  PERFORM pg_temp.charge('a3', v_o, 'pi_T12');
  PERFORM public._exos_pos_card_capture_prepare(v_o, 'pi_T12');
  PERFORM public._exos_pos_card_complete(v_o, 'pi_T12', 5000, 'door', NULL);
  PERFORM pg_temp.act(pg_temp.u('a1'));
  s2 := public.exos_pos_settlement_summary(pg_temp.u('e1'));
  v_bps := (s2 ->> 'fee_bps')::int;
  ASSERT (s2 -> 'tenders' ->> 'card')::int - (s1 -> 'tenders' ->> 'card')::int = 5000, 'T12: the card tender counts ' || s2::text;
  ASSERT (s2 ->> 'card_ticket_cents')::int - (s1 ->> 'card_ticket_cents')::int = 5000, 'T12: card ticket sales';
  ASSERT (s2 ->> 'exos_fee_cents')::int = ((s2 ->> 'fee_base_cents')::int * v_bps + 5000) / 10000, 'T12: the Exos fee on card tickets';
  ASSERT (s2 ->> 'orders')::int = (s1 ->> 'orders')::int + 1, 'T12: one more paid order';
  RAISE NOTICE 'OK T12 settlement counts the card tender and its Exos fee';
END $$;

-- ── T13 ─────────────────────────────────────────────────────────────────────
DO $$
DECLARE r jsonb; v_o uuid; v_u uuid;
BEGIN
  -- A completed card sale, voided: the reversal waits for its refund.
  v_o := (pg_temp.begin('a3', 'd1', 1, '50') ->> 'id')::uuid;
  PERFORM pg_temp.charge('a3', v_o, 'pi_T13sale');
  PERFORM public._exos_pos_card_capture_prepare(v_o, 'pi_T13sale');
  PERFORM public._exos_pos_card_complete(v_o, 'pi_T13sale', 2500, 'door', NULL);
  PERFORM public._exos_pos_card_reverse(pg_temp.u('a3'), v_o, 'void', 'binding test', false, NULL);
  -- The right order id (the metadata) with another PaymentIntent: nothing changes.
  r := public._exos_pos_card_refund_record(v_o, 'pi_T13other', 're_T13evil', 'succeeded', NULL);
  ASSERT NOT (r ->> 'recorded')::boolean, 'T13: another PaymentIntent is not recorded ' || r::text;
  ASSERT (SELECT card_refund_status = 'pending' AND card_refund_ref IS NULL FROM public.exos_pos_reversals WHERE order_id = v_o),
    'T13: the reversal is untouched';
  ASSERT NOT (public._exos_pos_card_refund_record(v_o, NULL, 're_T13evil', 'succeeded', NULL) ->> 'recorded')::boolean,
    'T13: no PaymentIntent, no change';
  -- The PaymentIntent of ANOTHER order (T3's) with this order's id: nothing.
  ASSERT NOT (public._exos_pos_card_refund_record(v_o, 'pi_T3door', 're_T13evil', 'failed', 'x') ->> 'recorded')::boolean,
    'T13: another order''s PaymentIntent';
  ASSERT (SELECT card_refund_status FROM public.exos_pos_reversals WHERE order_id = v_o) = 'pending', 'T13: still pending';
  -- The matching answer records, and binds the refund id.
  ASSERT (public._exos_pos_card_refund_record(v_o, 'pi_T13sale', 're_T13good', 'pending', NULL) ->> 'recorded')::boolean, 'T13: matching';
  -- A different refund id on the right PaymentIntent: nothing changes.
  ASSERT NOT (public._exos_pos_card_refund_record(v_o, 'pi_T13sale', 're_T13other', 'failed', 'x') ->> 'recorded')::boolean,
    'T13: another refund id';
  ASSERT (SELECT card_refund_ref = 're_T13good' AND card_refund_status = 'pending' AND card_refund_error IS NULL
            FROM public.exos_pos_reversals WHERE order_id = v_o), 'T13: the bound refund is untouched';
  ASSERT (public._exos_pos_card_refund_record(v_o, 'pi_T13sale', 're_T13good', 'succeeded', NULL) ->> 'recorded')::boolean, 'T13: settles';
  ASSERT (SELECT card_refund_status FROM public.exos_pos_reversals WHERE order_id = v_o) = 'succeeded', 'T13: succeeded';
  -- The unfulfilled-capture path (the card row) is bound the same way (T8's order).
  v_u := (SELECT order_id FROM public.exos_pos_card_payments WHERE payment_intent_id = 'pi_T8amount');
  ASSERT NOT (public._exos_pos_card_refund_record(v_u, 'pi_T8late', 're_T13x', 'succeeded', NULL) ->> 'recorded')::boolean,
    'T13: card row, another PaymentIntent';
  ASSERT (SELECT status = 'refund_pending' AND refund_ref IS NULL FROM public.exos_pos_card_payments WHERE order_id = v_u), 'T13: untouched';
  ASSERT (public._exos_pos_card_refund_record(v_u, 'pi_T8amount', 're_T13auto', 'succeeded', NULL) ->> 'recorded')::boolean, 'T13: card row matching';
  ASSERT NOT (public._exos_pos_card_refund_record(v_u, 'pi_T8amount', 're_T13y', 'failed', 'x') ->> 'recorded')::boolean,
    'T13: card row, another refund id';
  ASSERT (SELECT status = 'refunded' AND refund_ref = 're_T13auto' FROM public.exos_pos_card_payments WHERE order_id = v_u), 'T13: card row refunded';
  -- fail / complete with a PaymentIntent that isn't the order's: ignored / not found.
  v_o := (pg_temp.begin('a3', 'd1', 1, '51') ->> 'id')::uuid;
  PERFORM pg_temp.charge('a3', v_o, 'pi_T13pend');
  ASSERT (public._exos_pos_card_fail(v_o, 'pi_T13other', 'declined', NULL, 'webhook', NULL) ->> 'ignored')::boolean, 'T13: fail, another PI';
  ASSERT (public._exos_pos_card_fail(v_o, NULL, 'canceled', NULL, 'webhook', NULL) ->> 'ignored')::boolean, 'T13: fail, no PI once one is recorded';
  ASSERT (SELECT status FROM public.exos_pos_orders WHERE id = v_o) = 'open', 'T13: still pending';
  ASSERT pg_temp.st(format('SELECT public._exos_pos_card_complete(%L, %L, 2500, %L, NULL)', v_o, 'pi_T13other', 'webhook')) = 'P0002',
    'T13: complete, another PI';
  ASSERT public._exos_pos_card_capture_prepare(v_o, 'pi_T13other') ->> 'action' = 'ignore', 'T13: capture, another PI';
  PERFORM public._exos_pos_card_fail(v_o, 'pi_T13pend', 'canceled', NULL, 'door', NULL);
  RAISE NOTICE 'OK T13 refund answers bound to the recorded PaymentIntent and refund id; fail / complete with another PI ignored';
END $$;

ROLLBACK;
