-- ============================================================================
-- Walk-up sales at the door (mig 20261107100000):
--   W1  RLS on the new tables, grants (cores service role only, RPCs authenticated)
--   W2  a scanner sells at their assigned event only; door price; tickets minted
--   W3  card is refused (no rows); cash with no open drawer is refused
--   W4  the order key: a double tap is one sale; a reused key is refused
--   W5  comps: owner / manager only, comp budget, mixed cash + comp
--   W6  capacity: the type's own, a shared limit, a live online hold
--   W7  price steps at the door (cap rule), door price over steps, tax
--   W8  void: frees capacity, paid-out row, ledger row; who may; scanned refused
--   W9  refund after a scan needs the owner / manager override; late void
--   W10 cash paid-outs: holder / manager, a reason, never more than the drawer
--   W11 closing the drawer: expected = float + cash in - paid-outs
--   W12 settlement totals and the fee setting
--   W13 delivery: print codes scan like any ticket; email (account / claim link)
--   W14 pending (the card path): reserve, cancel, expiry gives places back
--   W15 checkout answers at the door attach to the tickets
--   W16 partner API cores: list, void by an owner / manager key, other orgs
--   W17 cross-org isolation through RLS and the RPCs
--   W18 handing over: only the seller or an owner / manager; unconfirmed
--       accounts get a claim link; no re-delivery (owner / manager can, never
--       a scanned ticket)
--   W19 drawers are their holder's: sell into, void out of, close, gift cards
-- Self-contained (BEGIN / ROLLBACK). Org …01: owner a1, manager a2, scanner a3
-- (assigned to e1), scanner a6 (assigned to e2), scanner a7 (org-wide), finance a4;
-- buyer a5 (no org); a8 an account whose email isn't confirmed.
-- Org …02: owner b9, event e9.
-- ============================================================================
\set ON_ERROR_STOP on
BEGIN;

CREATE FUNCTION pg_temp.u(p text) RETURNS uuid LANGUAGE sql IMMUTABLE AS $$
  SELECT ('b0c70000-0000-0000-0000-0000000000' || p)::uuid $$;
CREATE FUNCTION pg_temp.k(p text) RETURNS uuid LANGUAGE sql IMMUTABLE AS $$
  SELECT ('b0c70000-0000-0000-0000-00000000c0' || p)::uuid $$;
CREATE FUNCTION pg_temp.act(p_uid uuid) RETURNS void LANGUAGE sql AS $$
  SELECT set_config('app.uid', coalesce(p_uid::text, ''), true), set_config('app.jwt', '', true) $$;
-- SQLSTATE of a statement ('ok' when it ran).
CREATE FUNCTION pg_temp.st(p_sql text) RETURNS text LANGUAGE plpgsql AS $$
BEGIN
  EXECUTE p_sql;
  RETURN 'ok';
EXCEPTION WHEN OTHERS THEN RETURN SQLSTATE;
END $$;
CREATE FUNCTION pg_temp.sell(p_actor text, p_tier text, p_qty int, p_key text, p_comp int DEFAULT 0, p_pay text DEFAULT 'cash',
                             p_drawer uuid DEFAULT NULL, p_email text DEFAULT NULL, p_answers jsonb DEFAULT NULL,
                             p_event text DEFAULT 'e1') RETURNS jsonb
LANGUAGE plpgsql AS $$
BEGIN
  PERFORM pg_temp.act(pg_temp.u(p_actor));
  RETURN public.exos_pos_walkup_sell(pg_temp.u(p_event), pg_temp.u(p_tier), p_qty, pg_temp.k(p_key), p_comp, p_pay, NULL,
                                     p_drawer, 'Walk Up', p_email, p_answers, NULL);
END $$;
CREATE FUNCTION pg_temp.sell_st(p_actor text, p_tier text, p_qty int, p_key text, p_comp int DEFAULT 0, p_pay text DEFAULT 'cash',
                                p_drawer uuid DEFAULT NULL, p_event text DEFAULT 'e1') RETURNS text
LANGUAGE plpgsql AS $$
BEGIN
  PERFORM pg_temp.sell(p_actor, p_tier, p_qty, p_key, p_comp, p_pay, p_drawer, NULL, NULL, p_event);
  RETURN 'ok';
EXCEPTION WHEN OTHERS THEN RETURN SQLSTATE;
END $$;
CREATE FUNCTION pg_temp.sold(p_tier text) RETURNS int LANGUAGE sql AS $$
  SELECT sold FROM public.exos_ticket_tiers WHERE id = pg_temp.u(p_tier) $$;
CREATE TEMP TABLE wk (k text PRIMARY KEY, v text) ON COMMIT DROP;
CREATE FUNCTION pg_temp.v(p_k text) RETURNS text LANGUAGE sql AS $$ SELECT v FROM wk WHERE k = p_k $$;

INSERT INTO auth.users (id, email, email_confirmed_at) VALUES
  (pg_temp.u('a1'), 'b0c7-owner@x.com', now()), (pg_temp.u('a2'), 'b0c7-manager@x.com', now()),
  (pg_temp.u('a3'), 'b0c7-scanner@x.com', now()), (pg_temp.u('a4'), 'b0c7-finance@x.com', now()),
  (pg_temp.u('a5'), 'b0c7-fan@x.com', now()), (pg_temp.u('a6'), 'b0c7-scanner2@x.com', now()),
  (pg_temp.u('a7'), 'b0c7-scanner3@x.com', now()), (pg_temp.u('a8'), 'b0c7-unconfirmed@x.com', NULL),
  (pg_temp.u('b9'), 'b0c7-other@x.com', now());
INSERT INTO public.exos_orgs (id, name, slug, owner_uid) VALUES
  (pg_temp.u('01'), 'Walkup Org', 'b0c7-org', pg_temp.u('a1')),
  (pg_temp.u('02'), 'Walkup Other', 'b0c7-other', pg_temp.u('b9'));
INSERT INTO public.exos_org_memberships (org_id, user_id, role) VALUES
  (pg_temp.u('01'), pg_temp.u('a1'), 'owner'), (pg_temp.u('01'), pg_temp.u('a2'), 'manager'),
  (pg_temp.u('01'), pg_temp.u('a3'), 'scanner'), (pg_temp.u('01'), pg_temp.u('a4'), 'finance'),
  (pg_temp.u('01'), pg_temp.u('a6'), 'scanner'), (pg_temp.u('01'), pg_temp.u('a7'), 'scanner'),
  (pg_temp.u('02'), pg_temp.u('b9'), 'owner');
INSERT INTO public.exos_events (id, org_id, name, slug, status, starts_at, total_tickets, tickets_sold, currency, created_by) VALUES
  (pg_temp.u('e1'), pg_temp.u('01'), 'Walkup Night', 'b0c7-night', 'published', now() + interval '1 hour', 60, 0, 'usd', pg_temp.u('a1')),
  (pg_temp.u('e2'), pg_temp.u('01'), 'Walkup Other Night', 'b0c7-night2', 'published', now() + interval '1 day', 60, 0, 'usd', pg_temp.u('a1')),
  (pg_temp.u('e9'), pg_temp.u('02'), 'Walkup Elsewhere', 'b0c7-else', 'published', now() + interval '1 hour', 60, 0, 'usd', pg_temp.u('b9'));
UPDATE public.exos_events SET doors_at = now() - interval '1 hour' WHERE id = pg_temp.u('e1');
INSERT INTO public.exos_event_staff (event_id, user_id, org_id) VALUES
  (pg_temp.u('e1'), pg_temp.u('a3'), pg_temp.u('01')), (pg_temp.u('e2'), pg_temp.u('a6'), pg_temp.u('01'));
INSERT INTO public.exos_tax_rules (id, event_id, name, rate_percent, price_includes_tax) VALUES
  (pg_temp.u('7a'), pg_temp.u('e1'), 'Ticket tax 10%', 10, false);
INSERT INTO public.exos_ticket_tiers (id, event_id, name, price, capacity, sold, visibility, sort_order, door_price_cents, tax_rate_id) VALUES
  (pg_temp.u('d1'), pg_temp.u('e1'), 'GA', 20, 6, 0, 'public', 1, 2500, NULL),
  (pg_temp.u('d2'), pg_temp.u('e1'), 'Early', 15, 20, 0, 'public', 2, NULL, pg_temp.u('7a')),
  (pg_temp.u('d3'), pg_temp.u('e1'), 'Pool A', 10, 10, 0, 'public', 3, NULL, NULL),
  (pg_temp.u('d4'), pg_temp.u('e1'), 'Pool B', 10, 10, 0, 'public', 4, NULL, NULL),
  (pg_temp.u('d5'), pg_temp.u('e1'), 'Free', 0, 10, 0, 'public', 5, NULL, NULL),
  (pg_temp.u('d6'), pg_temp.u('e2'), 'GA', 10, 10, 0, 'public', 1, NULL, NULL),
  (pg_temp.u('d9'), pg_temp.u('e9'), 'GA', 10, 10, 0, 'public', 1, NULL, NULL);
INSERT INTO public.exos_quotas (id, event_id, org_id, name, size) VALUES
  (pg_temp.u('91'), pg_temp.u('e1'), pg_temp.u('01'), 'Room', 3);
INSERT INTO public.exos_quota_tiers (quota_id, tier_id) VALUES
  (pg_temp.u('91'), pg_temp.u('d3')), (pg_temp.u('91'), pg_temp.u('d4'));
INSERT INTO public.exos_api_keys (id, org_id, name, key_prefix, key_hash, scopes, created_by) VALUES
  (pg_temp.u('f1'), pg_temp.u('01'), 'manager key', 'sk_live_b0c71', 'b0c7hash1', ARRAY['orders:read','refunds:write'], pg_temp.u('a2')),
  (pg_temp.u('f2'), pg_temp.u('01'), 'scanner key', 'sk_live_b0c72', 'b0c7hash2', ARRAY['orders:read','refunds:write'], pg_temp.u('a3')),
  (pg_temp.u('f9'), pg_temp.u('02'), 'other key', 'sk_live_b0c79', 'b0c7hash9', ARRAY['orders:read','refunds:write'], pg_temp.u('b9'));
-- The scanner's drawer at e1: a $100 float.
SELECT pg_temp.act(pg_temp.u('a3'));
INSERT INTO public.exos_pos_drawer_sessions (id, event_id, open_float_cents) VALUES (pg_temp.u('81'), pg_temp.u('e1'), 10000);
-- Price steps on Early (d2): $15 for the first 3, then $30.
SELECT pg_temp.act(pg_temp.u('a1'));
SELECT 1 FROM public.exos_set_price_steps(pg_temp.u('d2'),
  '[{"name":"Early","price_cents":1500,"ends_after_count":3},{"name":"Final","price_cents":3000}]'::jsonb);

-- ── W1 ──────────────────────────────────────────────────────────────────────
DO $$
DECLARE t text; f text;
BEGIN
  FOREACH t IN ARRAY ARRAY['exos_pos_paid_outs', 'exos_pos_reversals'] LOOP
    ASSERT (SELECT relrowsecurity FROM pg_class WHERE oid = ('public.' || t)::regclass), 'W1: RLS on ' || t;
    ASSERT NOT has_table_privilege('anon', 'public.' || t, 'SELECT'), 'W1: anon reads nothing of ' || t;
    ASSERT has_table_privilege('authenticated', 'public.' || t, 'SELECT'), 'W1: staff read ' || t;
    ASSERT NOT has_table_privilege('authenticated', 'public.' || t, 'INSERT')
       AND NOT has_table_privilege('authenticated', 'public.' || t, 'UPDATE')
       AND NOT has_table_privilege('authenticated', 'public.' || t, 'DELETE'), 'W1: no client writes on ' || t;
  END LOOP;
  FOREACH f IN ARRAY ARRAY[
      'public._exos_pos_walkup_begin(uuid,text,uuid,uuid,integer,integer,uuid,uuid,text,text,jsonb,integer)',
      'public._exos_pos_walkup_complete(uuid,uuid,text,uuid,text)', 'public._exos_pos_walkup_cancel(uuid,uuid,text)',
      'public._exos_pos_walkup_sell(uuid,boolean,uuid,uuid,integer,uuid,integer,text,uuid,uuid,text,text,jsonb,text)',
      'public._exos_pos_reverse(uuid,boolean,uuid,uuid,uuid,text,text,boolean,uuid,uuid)',
      'public._exos_pos_paid_out(uuid,boolean,uuid,integer,text,uuid)', 'public._exos_pos_deliver_email(uuid,uuid,text,boolean)',
      'public._exos_pos_actor_role(uuid,uuid,boolean)', 'public._exos_pos_open_drawer(uuid,uuid,uuid,uuid,boolean)',
      'public._exos_pos_drawer_refusal(uuid,uuid,uuid,boolean)',
      'public._exos_pos_drawer_cash(uuid)', 'public._exos_pos_order_json(uuid,uuid)',
      'public._exos_api_pos_orders(uuid,uuid,integer,integer)', 'public._exos_api_pos_void(uuid,uuid,uuid,uuid,text,uuid)'] LOOP
    ASSERT NOT has_function_privilege('authenticated', f, 'EXECUTE') AND NOT has_function_privilege('anon', f, 'EXECUTE')
       AND has_function_privilege('service_role', f, 'EXECUTE'), 'W1: service role only: ' || f;
  END LOOP;
  FOREACH f IN ARRAY ARRAY[
      'public.exos_pos_walkup_sell(uuid,uuid,integer,uuid,integer,text,uuid,uuid,text,text,jsonb,text)',
      'public.exos_pos_void_order(uuid,text,uuid)', 'public.exos_pos_refund_order(uuid,text,boolean,uuid)',
      'public.exos_pos_paid_out(uuid,integer,text,uuid)', 'public.exos_pos_order_codes(uuid)',
      'public.exos_pos_order_email(uuid,text)', 'public.exos_pos_walkup_catalog(uuid)',
      'public.exos_pos_recent_sales(uuid,integer)', 'public.exos_pos_walkup_fee_base()'] LOOP
    ASSERT has_function_privilege('authenticated', f, 'EXECUTE') AND NOT has_function_privilege('anon', f, 'EXECUTE'),
      'W1: authenticated, not anon: ' || f;
  END LOOP;
  ASSERT NOT has_function_privilege('authenticated', 'public.exos_pos_tg_order_walkup_fields()', 'EXECUTE'), 'W1: trigger fn private';
  -- Still no column that could hold card data.
  ASSERT NOT EXISTS (SELECT 1 FROM information_schema.columns
                      WHERE table_schema = 'public' AND table_name LIKE 'exos_pos_%'
                        AND column_name ~ '(pan|card_number|cvc|cvv|expiry|exp_month|track)'), 'W1: no card-data columns';
  RAISE NOTICE 'OK W1 RLS on the new tables, cores service role only, RPCs authenticated, no card-data columns';
END $$;

-- ── W2 ──────────────────────────────────────────────────────────────────────
DO $$
DECLARE r jsonb; c jsonb;
BEGIN
  -- The Sell tab's catalog: door price, what's left, no comp for a scanner.
  PERFORM pg_temp.act(pg_temp.u('a3'));
  c := public.exos_pos_walkup_catalog(pg_temp.u('e1'));
  ASSERT c ->> 'role' = 'scanner' AND (c ->> 'can_comp')::boolean IS FALSE, 'W2: scanner, no comps ' || c::text;
  ASSERT (SELECT (x ->> 'price_cents')::int FROM jsonb_array_elements(c -> 'tiers') x WHERE x ->> 'tier_id' = pg_temp.u('d1')::text) = 2500,
    'W2: GA at the door price';
  ASSERT (SELECT (x ->> 'remaining')::int FROM jsonb_array_elements(c -> 'tiers') x WHERE x ->> 'tier_id' = pg_temp.u('d1')::text) = 6,
    'W2: 6 left';
  ASSERT jsonb_array_length(c -> 'drawers') = 1 AND (c -> 'drawers' -> 0 ->> 'mine')::boolean, 'W2: my open drawer';

  r := pg_temp.sell('a3', 'd1', 2, '01');
  INSERT INTO wk VALUES ('o1', r ->> 'id');
  ASSERT r ->> 'status' = 'paid' AND (r ->> 'total_cents')::int = 5000 AND r ->> 'payment_method' = 'cash', 'W2: paid 2 x 25.00 ' || r::text;
  ASSERT (r -> 'tenders' ->> 'cash')::int = 5000 AND jsonb_array_length(r -> 'ticket_ids') = 2, 'W2: cash tender, 2 tickets';
  ASSERT (SELECT count(*) FROM public.exos_tickets
           WHERE order_ref = 'pos:' || (r ->> 'id') AND status = 'active' AND channel_source = 'pos' AND price_paid = 25
             AND owner_id = pg_temp.u('a3') AND attendee_name = 'Walk Up' AND price_step_id IS NULL) = 2, 'W2: real tickets';
  ASSERT pg_temp.sold('d1') = 2 AND (SELECT tickets_sold FROM public.exos_events WHERE id = pg_temp.u('e1')) = 2, 'W2: counters';
  ASSERT (SELECT drawer_session_id FROM public.exos_pos_payments WHERE order_id = (r ->> 'id')::uuid) = pg_temp.u('81'),
    'W2: the cash went into my drawer';
  ASSERT (SELECT count(*) FROM public.exos_cart_holds WHERE pos_order_id = (r ->> 'id')::uuid AND status = 'consumed') = 1,
    'W2: the reservation was consumed';
  -- A scanner assigned to another event can't sell here.
  ASSERT pg_temp.sell_st('a6', 'd1', 1, '02') = '42501', 'W2: scanner of e2 refused at e1';
  ASSERT pg_temp.st(format('SELECT public.exos_pos_walkup_catalog(%L)', pg_temp.u('e1'))) = 'ok', 'W2: (still a3)';
  PERFORM pg_temp.act(pg_temp.u('a6'));
  ASSERT pg_temp.st(format('SELECT public.exos_pos_walkup_catalog(%L)', pg_temp.u('e1'))) = '42501', 'W2: no catalog for e2 staff';
  RAISE NOTICE 'OK W2 a scanner sells at their assigned event at the door price; tickets minted; another event''s scanner refused';
END $$;

-- ── W3 ──────────────────────────────────────────────────────────────────────
DO $$
DECLARE n int := (SELECT count(*) FROM public.exos_pos_orders);
BEGIN
  ASSERT pg_temp.sell_st('a3', 'd1', 1, '03', 0, 'card') = '0A000', 'W3: card refused';
  ASSERT (SELECT count(*) FROM public.exos_pos_orders) = n AND pg_temp.sold('d1') = 2, 'W3: nothing written for a card';
  -- e2: the scanner of e2 has no drawer.
  ASSERT pg_temp.sell_st('a6', 'd6', 1, '04', 0, 'cash', NULL, 'e2') = '55000', 'W3: cash with no open drawer';
  ASSERT pg_temp.sell_st('a6', 'd6', 1, '05', 0, 'cash', pg_temp.u('81'), 'e2') = '55000', 'W3: another event''s drawer';
  ASSERT pg_temp.sold('d6') = 0 AND (SELECT count(*) FROM public.exos_pos_orders) = n, 'W3: nothing sold';
  ASSERT pg_temp.sell_st('a3', 'd1', 1, '06', 0, 'cheque') = '22023', 'W3: unknown tender';
  RAISE NOTICE 'OK W3 a card tender is refused before anything is written; cash needs an open drawer at the event';
END $$;

-- ── W4 ──────────────────────────────────────────────────────────────────────
DO $$
DECLARE r jsonb;
BEGIN
  r := pg_temp.sell('a3', 'd1', 2, '01');
  ASSERT r ->> 'id' = pg_temp.v('o1') AND (r ->> 'replay')::boolean, 'W4: same key, same sale ' || r::text;
  ASSERT pg_temp.sold('d1') = 2 AND (SELECT count(*) FROM public.exos_pos_payments WHERE order_id = pg_temp.v('o1')::uuid) = 1,
    'W4: minted and paid once';
  ASSERT pg_temp.sell_st('a3', 'd1', 1, '01') = '23505', 'W4: the key with another quantity';
  ASSERT pg_temp.sell_st('a2', 'd1', 2, '01') = '23505', 'W4: another member''s key';
  ASSERT pg_temp.sell_st('b9', 'd9', 2, '01', 0, 'cash', NULL, 'e9') = '23505', 'W4: another org''s key, nothing said about it';
  RAISE NOTICE 'OK W4 a double tap is one sale; a key reused for another sale is refused';
END $$;

-- ── W5 ──────────────────────────────────────────────────────────────────────
DO $$
DECLARE r jsonb; v_used int;
BEGIN
  ASSERT pg_temp.sell_st('a3', 'd1', 1, '10', 1, 'comp') = '42501', 'W5: a scanner can''t comp';
  ASSERT pg_temp.sell_st('a3', 'd1', 2, '11', 1) = '42501', 'W5: nor comp one of two';
  r := pg_temp.sell('a2', 'd1', 1, '12', 0, 'comp');
  INSERT INTO wk VALUES ('o_comp', r ->> 'id');
  ASSERT r ->> 'status' = 'paid' AND r ->> 'payment_method' = 'comp' AND (r -> 'tenders' ->> 'comp')::int = 2500, 'W5: comp ' || r::text;
  ASSERT (SELECT channel_source || ':' || price_paid FROM public.exos_tickets WHERE order_ref = 'pos:' || (r ->> 'id')) = 'boxoffice:0',
    'W5: a comp ticket counts as a box-office comp';
  -- The comp budget.
  v_used := public.exos_comp_usage_count(pg_temp.u('01'));
  ASSERT v_used = 1, 'W5: one comp used';
  UPDATE public.exos_orgs SET comp_budget = v_used WHERE id = pg_temp.u('01');
  ASSERT pg_temp.sell_st('a2', 'd1', 1, '13', 0, 'comp') = '23514', 'W5: comp budget spent';
  UPDATE public.exos_orgs SET comp_budget = NULL WHERE id = pg_temp.u('01');
  -- Two tickets, one comped, one cash into the scanner's drawer.
  r := pg_temp.sell('a2', 'd1', 2, '14', 1, 'cash', pg_temp.u('81'));
  INSERT INTO wk VALUES ('o_split', r ->> 'id');
  ASSERT r ->> 'payment_method' = 'split' AND (r -> 'tenders' ->> 'cash')::int = 2500 AND (r -> 'tenders' ->> 'comp')::int = 2500,
    'W5: split ' || r::text;
  ASSERT (SELECT string_agg(channel_source, ',' ORDER BY channel_source) FROM public.exos_tickets WHERE order_ref = 'pos:' || (r ->> 'id'))
         = 'boxoffice,pos', 'W5: one comp ticket, one paid';
  ASSERT pg_temp.sold('d1') = 5, 'W5: 5 of 6 sold';
  RAISE NOTICE 'OK W5 comps need an owner or manager and the comp budget; cash + comp in one sale';
END $$;

-- ── W6 ──────────────────────────────────────────────────────────────────────
DO $$
DECLARE v_hold uuid;
BEGIN
  ASSERT pg_temp.sell_st('a2', 'd1', 2, '20', 0, 'cash', pg_temp.u('81')) = '23514', 'W6: 2 asked, 1 left';
  ASSERT pg_temp.sell_st('a2', 'd1', 1, '21', 0, 'cash', pg_temp.u('81')) = 'ok', 'W6: the last one';
  ASSERT pg_temp.sell_st('a2', 'd1', 1, '22', 0, 'cash', pg_temp.u('81')) = '23514', 'W6: sold out';
  ASSERT pg_temp.sold('d1') = 6, 'W6: never over capacity';
  -- The shared limit (3) across Pool A and Pool B.
  ASSERT pg_temp.sell_st('a2', 'd3', 2, '23', 0, 'cash', pg_temp.u('81')) = 'ok', 'W6: 2 of the pool';
  -- An online buyer holds the last place: the door can't take it.
  PERFORM pg_temp.act(pg_temp.u('a5'));
  PERFORM set_config('app.jwt', '{"email":"b0c7-fan@x.com"}', true);
  v_hold := public.exos_create_hold(pg_temp.u('e1'), pg_temp.u('d4'), 1);
  ASSERT pg_temp.sell_st('a2', 'd4', 1, '24', 0, 'cash', pg_temp.u('81')) = '23514', 'W6: the pool''s last place is held online';
  UPDATE public.exos_cart_holds SET status = 'released', released_at = now() WHERE id = v_hold;
  ASSERT pg_temp.sell_st('a2', 'd4', 1, '25', 0, 'cash', pg_temp.u('81')) = 'ok', 'W6: released, the door sells it';
  ASSERT pg_temp.sell_st('a2', 'd3', 1, '26', 0, 'cash', pg_temp.u('81')) = '23514', 'W6: the pool is full for Pool A too';
  RAISE NOTICE 'OK W6 type capacity, a shared limit and a live online hold all bind the door';
END $$;

-- ── W7 ──────────────────────────────────────────────────────────────────────
DO $$
DECLARE r jsonb; v_early uuid; v_final uuid;
BEGIN
  SELECT id INTO v_early FROM public.exos_price_steps WHERE tier_id = pg_temp.u('d2') AND price_cents = 1500;
  SELECT id INTO v_final FROM public.exos_price_steps WHERE tier_id = pg_temp.u('d2') AND price_cents = 3000;
  -- Early: $15 + 10% tax (exclusive, per unit) = $16.50.
  r := pg_temp.sell('a2', 'd2', 2, '30', 0, 'cash', pg_temp.u('81'));
  ASSERT (r ->> 'total_cents')::int = 3300 AND (r ->> 'tax_cents')::int = 300, 'W7: early bird with tax ' || r::text;
  ASSERT (SELECT count(*) FROM public.exos_tickets WHERE order_ref = 'pos:' || (r ->> 'id') AND price_step_id = v_early) = 2,
    'W7: on the early step';
  ASSERT (public.exos_tier_current_price(pg_temp.u('d2'), now(), 'door') ->> 'step_remaining')::int = 1, 'W7: 1 left at $15';
  ASSERT pg_temp.sell_st('a2', 'd2', 2, '31', 0, 'cash', pg_temp.u('81')) = 'XP410', 'W7: the cap rule';
  r := pg_temp.sell('a2', 'd2', 1, '32', 0, 'cash', pg_temp.u('81'));
  ASSERT (r ->> 'total_cents')::int = 1650, 'W7: the last early bird';
  r := pg_temp.sell('a2', 'd2', 1, '33', 0, 'cash', pg_temp.u('81'));
  ASSERT (r ->> 'total_cents')::int = 3300
     AND (SELECT price_step_id FROM public.exos_tickets WHERE order_ref = 'pos:' || (r ->> 'id')) = v_final, 'W7: then $30 + tax';
  -- A door price wins over the steps and takes no step's place.
  UPDATE public.exos_ticket_tiers SET door_price_cents = 2000 WHERE id = pg_temp.u('d2');
  r := pg_temp.sell('a2', 'd2', 1, '34', 0, 'cash', pg_temp.u('81'));
  ASSERT (r ->> 'total_cents')::int = 2200
     AND (SELECT price_step_id FROM public.exos_tickets WHERE order_ref = 'pos:' || (r ->> 'id')) IS NULL, 'W7: door price ' || r::text;
  UPDATE public.exos_ticket_tiers SET door_price_cents = NULL WHERE id = pg_temp.u('d2');
  RAISE NOTICE 'OK W7 price steps at the door (cap rule, latch), the door price over steps, tax as at checkout';
END $$;

-- ── W8 ──────────────────────────────────────────────────────────────────────
DO $$
DECLARE r jsonb; v_cash_before int; v_rev public.exos_pos_reversals%ROWTYPE;
BEGIN
  v_cash_before := public._exos_pos_drawer_cash(pg_temp.u('81'));
  PERFORM pg_temp.act(pg_temp.u('a3'));
  ASSERT pg_temp.st(format('SELECT public.exos_pos_void_order(%L, %L)', pg_temp.v('o1'), 'x')) = '22023', 'W8: a reason';
  ASSERT pg_temp.st(format('SELECT public.exos_pos_void_order(%L, %L)', pg_temp.v('o_split'), 'mistake')) = '42501',
    'W8: a scanner can''t void the manager''s sale';
  r := public.exos_pos_void_order(pg_temp.v('o1')::uuid, 'rang the wrong type');
  ASSERT r ->> 'status' = 'void' AND (r ->> 'cash_returned_cents')::int = 5000 AND (r ->> 'tickets_voided')::int = 2, 'W8: voided ' || r::text;
  ASSERT (SELECT count(*) FROM public.exos_tickets WHERE order_ref = 'pos:' || pg_temp.v('o1') AND status = 'voided') = 2, 'W8: tickets voided';
  ASSERT pg_temp.sold('d1') = 4, 'W8: capacity back';
  ASSERT (SELECT kind || ':' || amount_cents FROM public.exos_pos_paid_outs WHERE order_id = pg_temp.v('o1')::uuid) = 'void:5000',
    'W8: the cash out of the drawer is a paid-out row';
  ASSERT public._exos_pos_drawer_cash(pg_temp.u('81')) = v_cash_before - 5000, 'W8: the drawer holds 50.00 less';
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_pos_payments WHERE order_id = pg_temp.v('o1')::uuid AND status <> 'refunded'),
    'W8: tenders refunded';
  SELECT * INTO v_rev FROM public.exos_pos_reversals WHERE order_id = pg_temp.v('o1')::uuid;
  ASSERT v_rev.kind = 'void' AND v_rev.total_cents = 5000 AND v_rev.cash_cents = 5000 AND NOT v_rev.override
     AND v_rev.created_by = pg_temp.u('a3'), 'W8: the ledger row';
  -- A double tap answers the same.
  ASSERT (public.exos_pos_void_order(pg_temp.v('o1')::uuid, 'rang the wrong type') ->> 'replay')::boolean, 'W8: replay';
  ASSERT (SELECT count(*) FROM public.exos_pos_paid_outs WHERE order_id = pg_temp.v('o1')::uuid) = 1, 'W8: one paid-out';
  ASSERT pg_temp.st(format('SELECT public.exos_pos_refund_order(%L, %L)', pg_temp.v('o1'), 'again')) = '55000', 'W8: already voided';
  -- A sale whose ticket was scanned can't be voided.
  r := pg_temp.sell('a3', 'd1', 1, '40');
  INSERT INTO wk VALUES ('o_scanned', r ->> 'id');
  UPDATE public.exos_tickets SET status = 'used', check_in_at = now() WHERE order_ref = 'pos:' || (r ->> 'id');
  PERFORM pg_temp.act(pg_temp.u('a3'));
  ASSERT pg_temp.st(format('SELECT public.exos_pos_void_order(%L, %L)', r ->> 'id', 'changed mind')) = '55000', 'W8: scanned';
  -- The manager voids the scanner's sale (unscanned) too.
  r := pg_temp.sell('a3', 'd1', 1, '41');
  PERFORM pg_temp.act(pg_temp.u('a2'));
  ASSERT public.exos_pos_void_order((r ->> 'id')::uuid, 'duplicate') ->> 'status' = 'void', 'W8: a manager voids';
  RAISE NOTICE 'OK W8 void frees capacity, returns the cash as a paid-out row, writes the ledger; seller or manager; not after a scan';
END $$;

-- ── W9 ──────────────────────────────────────────────────────────────────────
DO $$
DECLARE r jsonb; v_sold int := pg_temp.sold('d1');
BEGIN
  PERFORM pg_temp.act(pg_temp.u('a3'));
  ASSERT pg_temp.st(format('SELECT public.exos_pos_refund_order(%L, %L, true)', pg_temp.v('o_scanned'), 'left early')) = '42501',
    'W9: a scanner can''t refund';
  PERFORM pg_temp.act(pg_temp.u('a2'));
  ASSERT pg_temp.st(format('SELECT public.exos_pos_refund_order(%L, %L)', pg_temp.v('o_scanned'), 'left early')) = '55000',
    'W9: scanned needs the override';
  r := public.exos_pos_refund_order(pg_temp.v('o_scanned')::uuid, 'left early, sound was off', true);
  ASSERT r ->> 'status' = 'refunded' AND (r ->> 'override')::boolean AND (r ->> 'tickets_kept')::int = 1
     AND (r ->> 'cash_returned_cents')::int = 2500, 'W9: refunded with the override ' || r::text;
  ASSERT (SELECT status FROM public.exos_tickets WHERE order_ref = 'pos:' || pg_temp.v('o_scanned')) = 'used'
     AND pg_temp.sold('d1') = v_sold, 'W9: the guest came in: the ticket stays used and keeps its place';
  ASSERT (SELECT override AND kind = 'refund' FROM public.exos_pos_reversals WHERE order_id = pg_temp.v('o_scanned')::uuid),
    'W9: the override is recorded';
  -- Same night only: a 13-hour-old sale can't be voided, a manager refunds it.
  r := pg_temp.sell('a3', 'd1', 1, '42');
  UPDATE public.exos_pos_orders SET created_at = now() - interval '13 hours' WHERE id = (r ->> 'id')::uuid;
  PERFORM pg_temp.act(pg_temp.u('a3'));
  ASSERT pg_temp.st(format('SELECT public.exos_pos_void_order(%L, %L)', r ->> 'id', 'next morning')) = '55000', 'W9: too late to void';
  PERFORM pg_temp.act(pg_temp.u('a2'));
  ASSERT public.exos_pos_refund_order((r ->> 'id')::uuid, 'next morning') ->> 'status' = 'refunded', 'W9: refund, no override needed';
  RAISE NOTICE 'OK W9 a refund after a scan needs an owner / manager override; a late void becomes a refund';
END $$;

-- ── W10 ─────────────────────────────────────────────────────────────────────
DO $$
DECLARE r jsonb; v_have int;
BEGIN
  PERFORM pg_temp.act(pg_temp.u('a3'));
  r := public.exos_pos_paid_out(pg_temp.u('81'), 1000, 'ice for the bar', pg_temp.k('50'));
  ASSERT (r ->> 'amount_cents')::int = 1000 AND NOT (r ->> 'replay')::boolean, 'W10: holder pays out';
  ASSERT (public.exos_pos_paid_out(pg_temp.u('81'), 1000, 'ice for the bar', pg_temp.k('50')) ->> 'replay')::boolean, 'W10: double tap';
  ASSERT (SELECT count(*) FROM public.exos_pos_paid_outs WHERE client_ref = pg_temp.k('50')) = 1, 'W10: once';
  ASSERT pg_temp.st(format('SELECT public.exos_pos_paid_out(%L, 500, %L, %L)', pg_temp.u('81'), 'x', pg_temp.k('51'))) = '22023', 'W10: a reason';
  v_have := public._exos_pos_drawer_cash(pg_temp.u('81'));
  ASSERT pg_temp.st(format('SELECT public.exos_pos_paid_out(%L, %s, %L)', pg_temp.u('81'), v_have + 1, 'too much')) = '23514',
    'W10: never more than the drawer holds';
  -- The manager's drawer: the scanner isn't its holder.
  PERFORM pg_temp.act(pg_temp.u('a2'));
  INSERT INTO public.exos_pos_drawer_sessions (id, event_id, open_float_cents) VALUES (pg_temp.u('82'), pg_temp.u('e1'), 2000);
  PERFORM pg_temp.act(pg_temp.u('a3'));
  ASSERT pg_temp.st(format('SELECT public.exos_pos_paid_out(%L, 100, %L)', pg_temp.u('82'), 'change run')) = '42501', 'W10: not the holder';
  PERFORM pg_temp.act(pg_temp.u('a2'));
  ASSERT pg_temp.st(format('SELECT public.exos_pos_paid_out(%L, 100, %L)', pg_temp.u('81'), 'change run')) = 'ok', 'W10: a manager may';
  PERFORM pg_temp.act(pg_temp.u('b9'));
  ASSERT pg_temp.st(format('SELECT public.exos_pos_paid_out(%L, 100, %L)', pg_temp.u('81'), 'theft')) = 'P0002', 'W10: other org: not found';
  RAISE NOTICE 'OK W10 paid-outs: holder or manager, a reason, at most the drawer''s cash, once per key';
END $$;

-- ── W11 ─────────────────────────────────────────────────────────────────────
DO $$
DECLARE r jsonb; v_in int; v_out int; v_exp int;
BEGIN
  SELECT coalesce(sum(amount_cents + tip_cents), 0) INTO v_in FROM public.exos_pos_payments
   WHERE drawer_session_id = pg_temp.u('81') AND method = 'cash';
  SELECT coalesce(sum(amount_cents), 0) INTO v_out FROM public.exos_pos_paid_outs WHERE drawer_session_id = pg_temp.u('81');
  v_exp := 10000 + v_in - v_out;
  ASSERT public._exos_pos_drawer_cash(pg_temp.u('81')) = v_exp, 'W11: drawer cash = float + in - out';
  PERFORM pg_temp.act(pg_temp.u('a3'));
  r := public.exos_pos_close_drawer(pg_temp.u('81'), v_exp, NULL, 'end of night');
  ASSERT (r ->> 'expected_cents')::int = v_exp AND (r ->> 'variance_cents')::int = 0 AND (r ->> 'paid_out_cents')::int = v_out,
    'W11: closes balanced ' || r::text;
  RAISE NOTICE 'OK W11 a drawer''s expected cash counts refunded sales in and paid-outs (voids included) out';
END $$;

-- ── W12 ─────────────────────────────────────────────────────────────────────
DO $$
DECLARE s jsonb; v_cash bigint; v_bps int;
BEGIN
  PERFORM pg_temp.act(pg_temp.u('a1'));
  s := public.exos_pos_settlement_summary(pg_temp.u('e1'));
  SELECT coalesce(sum(p.amount_cents), 0) INTO v_cash FROM public.exos_pos_payments p
    JOIN public.exos_pos_orders o ON o.id = p.order_id
   WHERE o.event_id = pg_temp.u('e1') AND o.status = 'paid' AND p.method = 'cash' AND p.status = 'succeeded';
  ASSERT (s -> 'tenders' ->> 'cash')::bigint = v_cash AND (s -> 'tenders' ->> 'comp')::int = 5000, 'W12: tenders ' || s::text;
  ASSERT (s -> 'reversals' ->> 'voids')::int = 2 AND (s -> 'reversals' ->> 'refunds')::int = 2
     AND (s -> 'reversals' ->> 'overrides')::int = 1 AND (s -> 'reversals' ->> 'voided_cents')::int = 7500, 'W12: voids and refunds';
  ASSERT (s -> 'paid_outs' ->> 'count')::int = 2 AND (s -> 'paid_outs' ->> 'cents')::int = 1100, 'W12: paid-outs';
  ASSERT s ->> 'fee_base' = 'card-tickets' AND (s ->> 'exos_fee_cents')::int = 0
     AND (s ->> 'organizer_net_cents')::bigint = v_cash, 'W12: default: no Exos fee on cash walk-ups';
  ASSERT (s ->> 'cash_ticket_cents')::bigint = v_cash, 'W12: cash ticket sales';
  -- The one setting (operator decision): charge cash ticket sales too.
  INSERT INTO public.exos_platform_settings (key, value) VALUES ('pos_walkup_fee_base', '"all-tickets"')
  ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value;
  s := public.exos_pos_settlement_summary(pg_temp.u('e1'));
  v_bps := (s ->> 'fee_bps')::int;
  ASSERT s ->> 'fee_base' = 'all-tickets' AND (s ->> 'fee_base_cents')::bigint = v_cash
     AND (s ->> 'exos_fee_cents')::bigint = (v_cash * v_bps + 5000) / 10000
     AND (s ->> 'organizer_net_cents')::bigint = v_cash - (v_cash * v_bps + 5000) / 10000, 'W12: all-tickets ' || s::text;
  DELETE FROM public.exos_platform_settings WHERE key = 'pos_walkup_fee_base';
  ASSERT public.exos_pos_walkup_fee_base() = 'card-tickets', 'W12: default back';
  RAISE NOTICE 'OK W12 settlement: tenders, voids / refunds, paid-outs; the fee setting (default card-tickets)';
END $$;

-- ── W13 ─────────────────────────────────────────────────────────────────────
DO $$
DECLARE r jsonb; p jsonb; c text; t uuid; tr uuid;
BEGIN
  -- Screen QR / paper: a one-time print code that scans like any printed ticket.
  -- (The scanner can't hand over the manager's sale: W18.)
  PERFORM pg_temp.act(pg_temp.u('a3'));
  ASSERT pg_temp.st(format('SELECT public.exos_pos_order_codes(%L)', pg_temp.v('o_comp'))) = '42501', 'W13: not the scanner''s sale';
  PERFORM pg_temp.act(pg_temp.u('a2'));
  p := public.exos_pos_order_codes(pg_temp.v('o_comp')::uuid);
  c := p #>> '{tickets,0,print_code}';
  t := (p #>> '{tickets,0,ticket_id}')::uuid;
  ASSERT c ~ '^P-[0-9a-f-]{36}:[A-Za-z0-9_-]{22}$', 'W13: a print code ' || p::text;
  ASSERT (SELECT printed_via FROM public.exos_ticket_print_codes WHERE ticket_id = t AND status = 'active') = 'pos', 'W13: printed at the door';
  r := public.exos_check_in_ticket(t, 'camera', 'verified', c, pg_temp.u('e1'), NULL, NULL, 'door-1');
  ASSERT r ->> 'reason' = 'checked-in', 'W13: it scans in ' || r::text;
  ASSERT public.exos_check_in_ticket(t, 'camera', 'verified', c, pg_temp.u('e1'), NULL, NULL, 'door-1') ->> 'reason' <> 'checked-in',
    'W13: once';
  PERFORM pg_temp.act(pg_temp.u('b9'));
  ASSERT pg_temp.st(format('SELECT public.exos_pos_order_codes(%L)', pg_temp.v('o_comp'))) = 'P0002', 'W13: other org';
  -- Email to an Exos account: the ticket is theirs.
  r := pg_temp.sell('a3', 'd5', 1, '60', 0, 'cash', NULL, 'B0C7-fan@x.com');
  ASSERT r ->> 'status' = 'paid' AND (r ->> 'total_cents')::int = 0, 'W13: a free door ticket needs no drawer ' || r::text;
  ASSERT (SELECT owner_id FROM public.exos_tickets WHERE order_ref = 'pos:' || (r ->> 'id')) = pg_temp.u('a5'), 'W13: owned by the buyer';
  ASSERT EXISTS (SELECT 1 FROM public.exos_mail WHERE to_email = 'b0c7-fan@x.com' AND template = 'ticket-issued'), 'W13: mail';
  -- Email to someone without an account: a claim link.
  r := pg_temp.sell('a3', 'd5', 1, '61');
  PERFORM pg_temp.act(pg_temp.u('a3'));
  r := public.exos_pos_order_email((r ->> 'id')::uuid, 'b0c7-walkin@x.com');
  ASSERT (r ->> 'emailed')::int = 1 AND r ->> 'buyer_email' = 'b0c7-walkin@x.com', 'W13: emailed ' || r::text;
  SELECT pending_transfer_id INTO tr FROM public.exos_tickets WHERE order_ref = 'pos:' || (r ->> 'id');
  ASSERT (SELECT receiver_email FROM public.exos_transfers WHERE id = tr) = 'b0c7-walkin@x.com', 'W13: a claim link';
  ASSERT EXISTS (SELECT 1 FROM public.exos_mail WHERE to_email = 'b0c7-walkin@x.com' AND template = 'transfer-initiated'
                    AND html LIKE '%/claim/%'), 'W13: claim mail';
  ASSERT pg_temp.st(format('SELECT public.exos_pos_order_email(%L, %L)', r ->> 'id', 'b0c7-other@x.com')) = '55000',
    'W13: already handed over';
  ASSERT pg_temp.st(format('SELECT public.exos_pos_order_codes(%L)', r ->> 'id')) = '55000', 'W13: the seller: no paper beside a claim link';
  PERFORM pg_temp.act(pg_temp.u('a2'));
  ASSERT (public.exos_pos_order_codes((r ->> 'id')::uuid) -> 'skipped' -> 0 ->> 'reason') = 'in-transfer', 'W13: a manager: skipped, in transfer';
  RAISE NOTICE 'OK W13 the screen QR / paper is a print code that scans once; email to an account or a claim link';
END $$;

-- ── W14 ─────────────────────────────────────────────────────────────────────
DO $$
DECLARE v_o uuid; v_avail int; v_st text;
BEGIN
  v_avail := public.exos_effective_available(pg_temp.u('d2'));
  -- The card path's first step: places reserved, nothing minted.
  v_o := public._exos_pos_walkup_begin(pg_temp.u('a2'), 'manager', pg_temp.u('e1'), pg_temp.u('d2'), 2, 0, pg_temp.k('70'),
                                       NULL, NULL, NULL, NULL, 300);
  ASSERT public.exos_effective_available(pg_temp.u('d2')) = v_avail - 2, 'W14: reserved';
  ASSERT (SELECT status FROM public.exos_pos_orders WHERE id = v_o) = 'open'
     AND NOT EXISTS (SELECT 1 FROM public.exos_tickets WHERE order_ref = 'pos:' || v_o), 'W14: pending, nothing minted';
  ASSERT public._exos_pos_order_json(v_o) ->> 'status' = 'pending', 'W14: shown as pending';
  -- A card is still refused at completion.
  ASSERT pg_temp.st(format('SELECT public._exos_pos_walkup_complete(%L, %L, %L, NULL, NULL)', pg_temp.u('a2'), v_o, 'card')) = '0A000',
    'W14: no card yet';
  -- Declined / abandoned: cancel gives the places back.
  ASSERT public._exos_pos_walkup_cancel(pg_temp.u('a2'), v_o, 'card declined') ->> 'status' = 'void', 'W14: cancelled';
  ASSERT public.exos_effective_available(pg_temp.u('d2')) = v_avail, 'W14: places back';
  -- A reservation that lapsed can't be completed; the places are already back.
  v_o := public._exos_pos_walkup_begin(pg_temp.u('a2'), 'manager', pg_temp.u('e1'), pg_temp.u('d2'), 1, 0, pg_temp.k('71'),
                                       NULL, NULL, NULL, NULL, 300);
  UPDATE public.exos_cart_holds SET expires_at = now() - interval '1 second' WHERE pos_order_id = v_o;
  ASSERT public.exos_effective_available(pg_temp.u('d2')) = v_avail, 'W14: a lapsed hold counts for nothing';
  BEGIN
    PERFORM public._exos_pos_walkup_complete(pg_temp.u('a2'), v_o, 'cash', pg_temp.u('82'), NULL);
    v_st := 'ok';
  EXCEPTION WHEN OTHERS THEN v_st := SQLSTATE;
  END;
  ASSERT v_st = '55000', 'W14: expired reservation refused: ' || v_st;
  -- A pending sale is voided as a cancel (no money moved, no ledger row).
  PERFORM pg_temp.act(pg_temp.u('a2'));
  ASSERT public.exos_pos_void_order(v_o, 'gave up') ->> 'status' = 'void'
     AND NOT EXISTS (SELECT 1 FROM public.exos_pos_reversals WHERE order_id = v_o), 'W14: cancel through void';
  RAISE NOTICE 'OK W14 the pending state: reserve, refuse card, cancel or lapse gives the places back';
END $$;

-- ── W15 ─────────────────────────────────────────────────────────────────────
DO $$
DECLARE q jsonb; r jsonb;
BEGIN
  PERFORM pg_temp.act(pg_temp.u('a1'));
  q := public.exos_save_event_question(pg_temp.u('e1'),
         '{"label":"T-shirt size","kind":"single_choice","options":["S","M","L"],"required":true,"scope":"ticket"}');
  -- Optional at the door: a sale without answers goes through.
  ASSERT pg_temp.sell_st('a2', 'd2', 1, '80', 0, 'cash', pg_temp.u('82')) = 'ok', 'W15: no answers needed';
  r := pg_temp.sell('a2', 'd2', 1, '81', 0, 'cash', pg_temp.u('82'), NULL,
                    jsonb_build_object('tickets', jsonb_build_array(jsonb_build_object(q ->> 'id', 'M'))));
  ASSERT (SELECT a.display FROM public.exos_question_answers a JOIN public.exos_tickets t ON t.id = a.ticket_id
           WHERE t.order_ref = 'pos:' || (r ->> 'id')) = 'M', 'W15: the answer is on the ticket';
  RAISE NOTICE 'OK W15 checkout answers at the door are optional and attach to the walk-up tickets';
END $$;

-- ── W16 ─────────────────────────────────────────────────────────────────────
DO $$
DECLARE r jsonb; v_o uuid;
BEGIN
  r := public._exos_api_pos_orders(pg_temp.u('01'), pg_temp.u('e1'), 5, 0);
  ASSERT (r ->> 'total')::int = (SELECT count(*) FROM public.exos_pos_orders WHERE event_id = pg_temp.u('e1'))
     AND jsonb_array_length(r -> 'data') = 5 AND NOT (r -> 'data' -> 0 ? 'rung_by_me'), 'W16: list ' || (r ->> 'total');
  ASSERT pg_temp.st(format('SELECT public._exos_api_pos_orders(%L, %L, 5, 0)', pg_temp.u('02'), pg_temp.u('e1'))) = 'P0002',
    'W16: another org''s event';
  r := pg_temp.sell('a2', 'd2', 1, '90', 0, 'cash', pg_temp.u('82'));
  v_o := (r ->> 'id')::uuid;
  ASSERT pg_temp.st(format('SELECT public._exos_api_pos_void(%L, %L, %L, %L, %L, NULL)', pg_temp.u('01'), pg_temp.u('f2'),
                           pg_temp.u('e1'), v_o, 'api void')) = '42501', 'W16: a scanner''s key';
  ASSERT pg_temp.st(format('SELECT public._exos_api_pos_void(%L, %L, %L, %L, %L, NULL)', pg_temp.u('02'), pg_temp.u('f9'),
                           pg_temp.u('e1'), v_o, 'api void')) = 'P0002', 'W16: another org''s key: not found';
  ASSERT pg_temp.st(format('SELECT public._exos_api_pos_void(%L, %L, %L, %L, %L, NULL)', pg_temp.u('01'), pg_temp.u('f1'),
                           pg_temp.u('e2'), v_o, 'api void')) = 'P0002', 'W16: the wrong event in the path';
  r := public._exos_api_pos_void(pg_temp.u('01'), pg_temp.u('f1'), pg_temp.u('e1'), v_o, 'api void', NULL);
  ASSERT r ->> 'status' = 'void' AND (SELECT api_key_id FROM public.exos_pos_reversals WHERE order_id = v_o) = pg_temp.u('f1'),
    'W16: voided by the manager''s key ' || r::text;
  RAISE NOTICE 'OK W16 partner API: list scoped to the key''s org, void by an owner / manager key only';
END $$;

-- ── W17 ─────────────────────────────────────────────────────────────────────
SET ROLE authenticated;
SELECT pg_temp.act(pg_temp.u('b9'));
DO $$
BEGIN
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_pos_paid_outs) AND NOT EXISTS (SELECT 1 FROM public.exos_pos_reversals)
     AND NOT EXISTS (SELECT 1 FROM public.exos_pos_orders WHERE event_id = 'b0c70000-0000-0000-0000-0000000000e1'),
    'W17: another org sees nothing';
END $$;
SELECT pg_temp.act(pg_temp.u('a6'));
DO $$
BEGIN
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_pos_paid_outs WHERE event_id = 'b0c70000-0000-0000-0000-0000000000e1'),
    'W17: a scanner of e2 doesn''t see e1''s paid-outs';
END $$;
SELECT pg_temp.act(pg_temp.u('a4'));
DO $$
BEGIN
  ASSERT (SELECT count(*) FROM public.exos_pos_reversals WHERE event_id = 'b0c70000-0000-0000-0000-0000000000e1') = 5,
    'W17: finance reads the ledger';
END $$;
SELECT pg_temp.act(pg_temp.u('a3'));
DO $$
BEGIN
  ASSERT (SELECT count(*) FROM public.exos_pos_paid_outs WHERE event_id = 'b0c70000-0000-0000-0000-0000000000e1') >= 5,
    'W17: door staff of e1 read its paid-outs';
  ASSERT jsonb_array_length(public.exos_pos_recent_sales('b0c70000-0000-0000-0000-0000000000e1', 5)) = 5, 'W17: recent sales';
END $$;
RESET ROLE;
SELECT pg_temp.act(pg_temp.u('b9'));
DO $$
BEGIN
  ASSERT pg_temp.st($s$SELECT public.exos_pos_recent_sales('b0c70000-0000-0000-0000-0000000000e1', 5)$s$) = '42501',
    'W17: another org''s recent sales';
  ASSERT pg_temp.st($s$SELECT public.exos_pos_void_order('$s$ || pg_temp.v('o_split') || $s$', 'not mine')$s$) = 'P0002',
    'W17: another org voids nothing (not found)';
  RAISE NOTICE 'OK W17 cross-org isolation: RLS on the ledgers, RPCs answer not found / not authorized';
END $$;

-- ── W18 ─────────────────────────────────────────────────────────────────────
DO $$
DECLARE r jsonb; v_62 uuid; v_63 uuid; v_64 uuid; v_65 uuid; v_tr uuid; v_tr2 uuid; v_t uuid;
BEGIN
  -- The scanner's own sale (free door ticket: no drawer).
  v_62 := (pg_temp.sell('a3', 'd5', 1, '62') ->> 'id')::uuid;
  -- Another scanner working the same door can't hand it over (no redirecting).
  PERFORM pg_temp.act(pg_temp.u('a7'));
  ASSERT public._exos_pos_actor_role(pg_temp.u('e1'), pg_temp.u('a7')) = 'scanner', 'W18: a7 works this door';
  ASSERT pg_temp.st(format('SELECT public.exos_pos_order_email(%L, %L)', v_62, 'b0c7-scanner3@x.com')) = '42501', 'W18: no email';
  ASSERT pg_temp.st(format('SELECT public.exos_pos_order_codes(%L)', v_62)) = '42501', 'W18: no print / QR';
  ASSERT NOT (SELECT (x ->> 'can_hand_over')::boolean FROM jsonb_array_elements(public.exos_pos_recent_sales(pg_temp.u('e1'), 50)) x
               WHERE x ->> 'id' = v_62::text), 'W18: no hand-over button';
  ASSERT (SELECT owner_id FROM public.exos_tickets WHERE order_ref = 'pos:' || v_62) = pg_temp.u('a3'), 'W18: still the seller''s';
  PERFORM pg_temp.act(pg_temp.u('a3'));
  ASSERT jsonb_array_length(public.exos_pos_order_codes(v_62) -> 'tickets') = 1, 'W18: the seller shows the QR';

  -- An account whose email isn't confirmed gets a claim link, not the ticket.
  v_63 := (pg_temp.sell('a3', 'd5', 1, '63', 0, 'cash', NULL, 'b0c7-unconfirmed@x.com') ->> 'id')::uuid;
  SELECT id, pending_transfer_id INTO v_t, v_tr FROM public.exos_tickets WHERE order_ref = 'pos:' || v_63;
  ASSERT (SELECT owner_id FROM public.exos_tickets WHERE id = v_t) = pg_temp.u('a3') AND v_tr IS NOT NULL
     AND (SELECT receiver_email FROM public.exos_transfers WHERE id = v_tr) = 'b0c7-unconfirmed@x.com', 'W18: claim link, not ownership';
  ASSERT EXISTS (SELECT 1 FROM public.exos_mail WHERE to_email = 'b0c7-unconfirmed@x.com' AND template = 'transfer-initiated'),
    'W18: claim mail';
  -- Sent once: the seller can't send it again (to themselves, say).
  ASSERT pg_temp.st(format('SELECT public.exos_pos_order_email(%L, %L)', v_63, 'b0c7-scanner@x.com')) = '55000', 'W18: no re-delivery';
  -- An owner / manager can resend an unclaimed claim link: the old link is cancelled.
  PERFORM pg_temp.act(pg_temp.u('a2'));
  r := public.exos_pos_order_email(v_63, 'b0c7-walkin2@x.com');
  ASSERT (r ->> 'emailed')::int = 1, 'W18: manager resends ' || r::text;
  SELECT pending_transfer_id INTO v_tr2 FROM public.exos_tickets WHERE id = v_t;
  ASSERT (SELECT status FROM public.exos_transfers WHERE id = v_tr) = 'cancelled' AND v_tr2 IS NOT NULL AND v_tr2 <> v_tr
     AND (SELECT receiver_email || ':' || sender_id FROM public.exos_transfers WHERE id = v_tr2)
         = 'b0c7-walkin2@x.com:' || pg_temp.u('a3'), 'W18: a new link, still from the seller';
  -- Once claimed, the ticket is the buyer's: no resend moves it, not even by a manager.
  UPDATE public.exos_transfers SET status = 'claimed' WHERE id = v_tr2;
  UPDATE public.exos_tickets SET owner_id = pg_temp.u('a5'), buyer_id = pg_temp.u('a5'), pending_transfer_id = NULL WHERE id = v_t;
  ASSERT pg_temp.st(format('SELECT public.exos_pos_order_email(%L, %L)', v_63, 'b0c7-scanner3@x.com')) = '55000',
    'W18: a manager can''t take a claimed ticket';
  ASSERT (SELECT owner_id FROM public.exos_tickets WHERE id = v_t) = pg_temp.u('a5'), 'W18: still the buyer''s';
  -- Delivered straight to a confirmed account (W13's sale): the same.
  ASSERT pg_temp.st(format('SELECT public.exos_pos_order_email(%L, %L)', (SELECT o.id FROM public.exos_pos_orders o
           WHERE o.client_ref = pg_temp.k('60')), 'b0c7-scanner3@x.com')) = '55000', 'W18: a delivered ticket stays delivered';
  -- A ticket in a claim link someone else started (not the seller's) isn't touched.
  PERFORM pg_temp.act(pg_temp.u('a3'));
  v_65 := (pg_temp.sell('a3', 'd5', 1, '65') ->> 'id')::uuid;
  UPDATE public.exos_tickets SET pending_transfer_id = v_tr2 WHERE order_ref = 'pos:' || v_65;
  UPDATE public.exos_transfers SET status = 'pending', sender_id = pg_temp.u('a5') WHERE id = v_tr2;
  PERFORM pg_temp.act(pg_temp.u('a2'));
  ASSERT pg_temp.st(format('SELECT public.exos_pos_order_email(%L, %L)', v_65, 'b0c7-fan@x.com')) = '55000',
    'W18: not another sender''s claim link';
  ASSERT (SELECT status FROM public.exos_transfers WHERE id = v_tr2) = 'pending', 'W18: that link is left alone';
  UPDATE public.exos_transfers SET status = 'claimed' WHERE id = v_tr2;
  -- A scanned ticket is never sent again, by anyone.
  UPDATE public.exos_tickets SET status = 'used', check_in_at = now() WHERE order_ref = 'pos:' || v_62;
  ASSERT pg_temp.st(format('SELECT public.exos_pos_order_email(%L, %L)', v_62, 'b0c7-fan@x.com')) = '55000', 'W18: scanned';
  -- Checked in but still active (a test scan): not either.
  v_64 := (pg_temp.sell('a3', 'd5', 1, '64') ->> 'id')::uuid;
  UPDATE public.exos_tickets SET check_in_at = now() WHERE order_ref = 'pos:' || v_64;
  PERFORM pg_temp.act(pg_temp.u('a2'));
  ASSERT pg_temp.st(format('SELECT public.exos_pos_order_email(%L, %L)', v_64, 'b0c7-fan@x.com')) = '55000',
    'W18: a checked-in ticket isn''t sent, even by a manager';
  PERFORM pg_temp.act(pg_temp.u('a3'));
  ASSERT pg_temp.st(format('SELECT public.exos_pos_order_codes(%L)', v_62)) = '55000', 'W18: no paper for a scanned ticket';
  RAISE NOTICE 'OK W18 only the seller or an owner / manager hands tickets over; unconfirmed email = claim link; never a claimed or scanned ticket; a manager resends the seller''s unclaimed link';
END $$;

-- ── W19 ─────────────────────────────────────────────────────────────────────
DO $$
DECLARE r jsonb; v_o uuid; v_82 int;
BEGIN
  -- The manager's drawer 82 is open (W10). The scanner can't sell into it ...
  ASSERT pg_temp.sell_st('a3', 'd2', 1, '72', 0, 'cash', pg_temp.u('82')) = '42501', 'W19: not into another member''s drawer';
  ASSERT pg_temp.sell_st('a3', 'd2', 1, '72') = '55000', 'W19: and nothing picks it for them';
  -- ... sells into their own.
  PERFORM pg_temp.act(pg_temp.u('a3'));
  INSERT INTO public.exos_pos_drawer_sessions (id, event_id, open_float_cents) VALUES (pg_temp.u('84'), pg_temp.u('e1'), 1000);
  r := pg_temp.sell('a3', 'd2', 1, '73');
  v_o := (r ->> 'id')::uuid;
  ASSERT (SELECT drawer_session_id FROM public.exos_pos_payments WHERE order_id = v_o) = pg_temp.u('84'), 'W19: own drawer';
  -- Another scanner can't close it, nor pay out of it.
  PERFORM pg_temp.act(pg_temp.u('a7'));
  ASSERT pg_temp.st(format('SELECT public.exos_pos_close_drawer(%L, 0)', pg_temp.u('84'))) = '42501', 'W19: not their drawer to close';
  ASSERT pg_temp.st(format('SELECT public.exos_pos_paid_out(%L, 100, %L)', pg_temp.u('84'), 'taking it')) = '42501', 'W19: nor to pay out';
  ASSERT pg_temp.st(format($q$SELECT public.exos_gift_card_issue(%L, 1000, 'cash', NULL, 'usd', NULL, NULL, NULL, NULL, NULL, 'box_office', %L)$q$,
                           pg_temp.u('01'), pg_temp.u('84'))) = '42501', 'W19: nor sell a gift card into it';
  -- The scanner closes their drawer; a void then has no drawer of theirs to pay out of.
  PERFORM pg_temp.act(pg_temp.u('a3'));
  PERFORM public.exos_pos_close_drawer(pg_temp.u('84'), public._exos_pos_drawer_cash(pg_temp.u('84')));
  ASSERT pg_temp.st(format('SELECT public.exos_pos_void_order(%L, %L)', v_o, 'wrong type')) = '55000', 'W19: no own drawer open';
  ASSERT pg_temp.st(format('SELECT public.exos_pos_void_order(%L, %L, %L)', v_o, 'wrong type', pg_temp.u('82'))) = '42501',
    'W19: a void can''t pay out of another member''s drawer';
  ASSERT (SELECT status FROM public.exos_pos_orders WHERE id = v_o) = 'paid', 'W19: nothing changed';
  -- An owner / manager can name any open drawer at the event.
  v_82 := public._exos_pos_drawer_cash(pg_temp.u('82'));
  PERFORM pg_temp.act(pg_temp.u('a2'));
  r := public.exos_pos_void_order(v_o, 'wrong type', pg_temp.u('82'));
  ASSERT r ->> 'status' = 'void' AND (r ->> 'drawer_id')::uuid = pg_temp.u('82'), 'W19: manager voids from 82 ' || r::text;
  ASSERT public._exos_pos_drawer_cash(pg_temp.u('82')) = v_82 - 3300
     AND (SELECT drawer_session_id FROM public.exos_pos_paid_outs WHERE order_id = v_o) = pg_temp.u('82'), 'W19: paid out of 82';
  -- The scanner's catalog lists only their own drawers; the manager's all.
  PERFORM pg_temp.act(pg_temp.u('a7'));
  ASSERT jsonb_array_length(public.exos_pos_walkup_catalog(pg_temp.u('e1')) -> 'drawers') = 0, 'W19: a7 has none';
  PERFORM pg_temp.act(pg_temp.u('a2'));
  ASSERT jsonb_array_length(public.exos_pos_walkup_catalog(pg_temp.u('e1')) -> 'drawers') = 1, 'W19: the manager sees 82';
  RAISE NOTICE 'OK W19 a drawer is its holder''s: sell into, void / pay out of, close, gift cards; owners / managers name any';
END $$;

ROLLBACK;
