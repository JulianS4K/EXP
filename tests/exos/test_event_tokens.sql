-- ============================================================================
-- Event tokens (mig 20261114110000, docs/pos.md "Event tokens"):
--   ET1  RLS on, reads only, no code hash readable, the ledger sequence off
--        anon, helpers service role only, nothing for anon
--   ET2  configure: owner / manager only (scanner, finance, another org: 42501),
--        validation, the offers (add-ons + POS items) with the rule text,
--        client writes to an offer refused, token.configure audited
--   ET3  buy online: the add-on line puts the credits on the buyer's own
--        ticket (a lot + a purchase row); the checkout's max-per-order check;
--        the journal moves the value to tokens outstanding
--   ET4  spend: door staff only (finance 42501), the ticket's rotating code,
--        insufficient refused (all or nothing), replay of a client ref is the
--        same answer, a ref reused for another spend refused, codes of another
--        event / org read 'not-found', a stale code 'barcode-expired'
--   ET5  undo: owner / manager with a reason, once; the credits come back;
--        token.undo audited; the journal reverses the redemption
--   ET6  sell at the door: cash into the seller's drawer onto a new code
--        (shown once, only its hash kept), comps owner / manager only, a
--        double tap is one sale, the code spends; a void before any spend
--        takes the credits back, after a spend it is refused; a client can't
--        ring a token item; token.sell audited; drawer + journal
--   ET7  offline sync: the device's ledger replayed; more than the balance ->
--        the rest is an 'overspent' exception, never a negative balance;
--        replays idempotent; a code that no longer passes is 'rejected';
--        token.overspent audited; the roster carries balances by ticket / hash
--   ET8  expiry: past the event's end + grace a spend is refused; the expiry
--        writes 'expire' rows (breakage) for non-refundable products only
--   ET9  refunds: unused online credits (refundable) -> the order + amount +
--        key for the existing partial refund; door cash -> a paid-out; a
--        non-refundable product refused; a full order refund takes what's left
--   ET10 the journal: every org's trial balance nets to zero, tokens
--        outstanding = the value still on cards, entries per ledger row
--   ET11 cross-org: another org's owner can't spend, sell, undo, refund, read
--        the report or the roster
--   ET12 the ticket page: the holder sees their balances and the rule
--   ET13 the report: sold = redeemed + expired + refunded + outstanding, the
--        exceptions, the refundable lots; export kind 'event_tokens'
--   ET14 rate limits: lookups / spends 120 a minute per member, a miss counts
-- Self-contained (BEGIN / ROLLBACK). Org …01: owner a1, manager a2, scanner a3,
-- finance a4, buyers a5 / a6. Org …02: owner b9.
-- ============================================================================
\set ON_ERROR_STOP on
BEGIN;

CREATE FUNCTION pg_temp.u(p text) RETURNS uuid LANGUAGE sql IMMUTABLE AS $$
  SELECT ('e70c0000-0000-0000-0000-0000000000' || p)::uuid $$;
CREATE FUNCTION pg_temp.act(p_uid uuid) RETURNS void LANGUAGE sql AS $$
  SELECT set_config('app.uid', coalesce(p_uid::text, ''), true), set_config('app.jwt', '', true) $$;
CREATE FUNCTION pg_temp.st(p_sql text) RETURNS text LANGUAGE plpgsql AS $$
DECLARE v_hint text;
BEGIN
  EXECUTE p_sql;
  RETURN 'ok';
EXCEPTION WHEN OTHERS THEN
  GET STACKED DIAGNOSTICS v_hint = PG_EXCEPTION_HINT;
  RETURN SQLSTATE || CASE WHEN coalesce(v_hint, '') <> '' THEN ':' || v_hint ELSE '' END;
END $$;
-- A ticket's rotating door code now (or at p_at).
CREATE FUNCTION pg_temp.tcode(p_ticket uuid, p_at timestamptz DEFAULT NULL) RETURNS text LANGUAGE sql AS $$
  SELECT 'T-' || t.id || ':' || t.owner_id || ':' || b || ':' || public._exos_door_code_mac(t.id, t.owner_id, b, t.barcode_secret)
    FROM public.exos_tickets t,
         LATERAL (SELECT floor(extract(epoch FROM coalesce(p_at, clock_timestamp())) * 1000 / 30000)::bigint AS b) x
   WHERE t.id = p_ticket $$;
CREATE TEMP TABLE tk (k text PRIMARY KEY, v text) ON COMMIT DROP;
GRANT SELECT ON tk TO authenticated;
CREATE FUNCTION pg_temp.v(p_k text) RETURNS text LANGUAGE sql AS $$ SELECT v FROM tk WHERE k = p_k $$;
CREATE FUNCTION pg_temp.bal(p_ticket text, p_product text) RETURNS int LANGUAGE sql AS $$
  SELECT public._exos_event_token_balance((SELECT id FROM public.exos_event_token_cards WHERE ticket_id = pg_temp.u(p_ticket)),
                                          pg_temp.v(p_product)::uuid) $$;
GRANT EXECUTE ON FUNCTION pg_temp.u(text), pg_temp.v(text), pg_temp.st(text), pg_temp.act(uuid) TO authenticated;
-- The journal's net of one account for org 01.
CREATE FUNCTION pg_temp.acct(p_account text) RETURNS bigint LANGUAGE sql AS $$
  SELECT coalesce(sum(l.debit_cents - l.credit_cents), 0)::bigint FROM public.exos_journal_lines l
   WHERE l.org_id = pg_temp.u('01') AND l.account = p_account $$;

INSERT INTO auth.users (id, email, email_confirmed_at) VALUES
  (pg_temp.u('a1'), 'e70c-owner@x.com', now()), (pg_temp.u('a2'), 'e70c-manager@x.com', now()),
  (pg_temp.u('a3'), 'e70c-scanner@x.com', now()), (pg_temp.u('a4'), 'e70c-finance@x.com', now()),
  (pg_temp.u('a5'), 'e70c-buyer@x.com', now()), (pg_temp.u('a6'), 'e70c-friend@x.com', now()),
  (pg_temp.u('b9'), 'e70c-other@x.com', now());
INSERT INTO public.exos_orgs (id, name, slug, owner_uid) VALUES
  (pg_temp.u('01'), 'Token Fair', 'e70c-fair', pg_temp.u('a1')),
  (pg_temp.u('02'), 'Token Other', 'e70c-other', pg_temp.u('b9'));
INSERT INTO public.exos_org_memberships (org_id, user_id, role) VALUES
  (pg_temp.u('01'), pg_temp.u('a1'), 'owner'), (pg_temp.u('01'), pg_temp.u('a2'), 'manager'),
  (pg_temp.u('01'), pg_temp.u('a3'), 'scanner'), (pg_temp.u('01'), pg_temp.u('a4'), 'finance'),
  (pg_temp.u('02'), pg_temp.u('b9'), 'owner');
INSERT INTO public.exos_events (id, org_id, name, slug, status, starts_at, ends_at, total_tickets, tickets_sold, currency, created_by) VALUES
  (pg_temp.u('e1'), pg_temp.u('01'), 'Cherry Festival', 'e70c-cherry', 'published', now() + interval '1 hour', now() + interval '6 hours', 500, 0, 'usd', pg_temp.u('a1')),
  (pg_temp.u('e2'), pg_temp.u('01'), 'Last Week''s Tasting', 'e70c-tasting', 'published', now() - interval '2 days', now() - interval '1 day', 500, 0, 'usd', pg_temp.u('a1')),
  (pg_temp.u('e9'), pg_temp.u('02'), 'Other Fair', 'e70c-else', 'published', now() + interval '1 hour', now() + interval '6 hours', 100, 0, 'usd', pg_temp.u('b9'));
INSERT INTO public.exos_ticket_tiers (id, event_id, name, price, capacity, sold, visibility, sort_order) VALUES
  (pg_temp.u('d1'), pg_temp.u('e1'), 'GA', 40, 100, 0, 'public', 1),
  (pg_temp.u('d2'), pg_temp.u('e2'), 'GA', 40, 100, 0, 'public', 1),
  (pg_temp.u('d9'), pg_temp.u('e9'), 'GA', 40, 100, 0, 'public', 1);
-- Order cs_e70c1: the buyer a5 has two tickets, the friend's (a6, transferred
-- first) and their own; the credits must land on the buyer's own.
INSERT INTO public.exos_tickets (id, event_id, org_id, tier_id, tier_name, buyer_id, owner_id, buyer_email, status, barcode_secret, price_paid, order_ref, channel_source, created_at) VALUES
  (pg_temp.u('11'), pg_temp.u('e1'), pg_temp.u('01'), pg_temp.u('d1'), 'GA', pg_temp.u('a5'), pg_temp.u('a6'), 'e70c-buyer@x.com', 'active', 'sek-11', 40, 'cs_e70c1', 'stripe', now() - interval '2 minutes'),
  (pg_temp.u('12'), pg_temp.u('e1'), pg_temp.u('01'), pg_temp.u('d1'), 'GA', pg_temp.u('a5'), pg_temp.u('a5'), 'e70c-buyer@x.com', 'active', 'sek-12', 40, 'cs_e70c1', 'stripe', now() - interval '1 minute'),
  (pg_temp.u('13'), pg_temp.u('e1'), pg_temp.u('01'), pg_temp.u('d1'), 'GA', pg_temp.u('a6'), pg_temp.u('a6'), 'e70c-friend@x.com', 'active', 'sek-13', 40, 'cs_e70c2', 'stripe', now()),
  (pg_temp.u('14'), pg_temp.u('e2'), pg_temp.u('01'), pg_temp.u('d2'), 'GA', pg_temp.u('a5'), pg_temp.u('a5'), 'e70c-buyer@x.com', 'active', 'sek-14', 40, 'cs_e70c4', 'stripe', now()),
  (pg_temp.u('19'), pg_temp.u('e9'), pg_temp.u('02'), pg_temp.u('d9'), 'GA', pg_temp.u('a5'), pg_temp.u('a5'), 'e70c-buyer@x.com', 'active', 'sek-19', 40, 'cs_e70c9', 'stripe', now());
-- The scanner's drawer at e1 ($50 float); the manager's at e2.
SELECT pg_temp.act(pg_temp.u('a3'));
INSERT INTO public.exos_pos_drawer_sessions (id, event_id, open_float_cents) VALUES (pg_temp.u('81'), pg_temp.u('e1'), 5000);

-- ── ET1 ─────────────────────────────────────────────────────────────────────
DO $$
DECLARE t text; f text;
BEGIN
  FOREACH t IN ARRAY ARRAY['exos_event_token_products', 'exos_event_token_cards', 'exos_event_token_lots',
                           'exos_event_token_ledger', 'exos_event_token_exceptions'] LOOP
    ASSERT (SELECT relrowsecurity FROM pg_class WHERE oid = ('public.' || t)::regclass), 'ET1 RLS on ' || t;
    ASSERT NOT has_table_privilege('anon', 'public.' || t, 'SELECT'), 'ET1 anon reads ' || t;
    ASSERT NOT has_table_privilege('authenticated', 'public.' || t, 'INSERT')
       AND NOT has_table_privilege('authenticated', 'public.' || t, 'UPDATE')
       AND NOT has_table_privilege('authenticated', 'public.' || t, 'DELETE'), 'ET1 client writes ' || t;
  END LOOP;
  ASSERT has_column_privilege('authenticated', 'public.exos_event_token_cards', 'code_last4', 'SELECT')
     AND NOT has_column_privilege('authenticated', 'public.exos_event_token_cards', 'code_hash', 'SELECT'), 'ET1 no code hash';
  ASSERT NOT has_sequence_privilege('anon', 'public.exos_event_token_ledger_id_seq', 'USAGE')
     AND NOT has_sequence_privilege('authenticated', 'public.exos_event_token_ledger_id_seq', 'USAGE'), 'ET1 sequence';
  FOREACH f IN ARRAY ARRAY['public._exos_event_token_resolve(uuid,text,timestamptz,boolean)', 'public._exos_event_token_take(uuid,uuid,integer)',
      'public._exos_event_token_add_lot(uuid,uuid,text,integer,integer,uuid,uuid,text,uuid,text)',
      'public._exos_event_token_close_lot(uuid,text,uuid,text)', 'public._exos_event_token_sync_offers(uuid)',
      'public._exos_event_token_expire_core(uuid,uuid)', 'public._exos_event_token_expire_due()',
      'public.exos_event_token_order_check(uuid,jsonb)', 'public.exos_journal_post_event_token(bigint)',
      'public._exos_event_token_balances(uuid)', 'public._exos_event_token_role(uuid)'] LOOP
    ASSERT NOT has_function_privilege('authenticated', f, 'EXECUTE') AND NOT has_function_privilege('anon', f, 'EXECUTE')
       AND has_function_privilege('service_role', f, 'EXECUTE'), 'ET1 service role only: ' || f;
  END LOOP;
  FOREACH f IN ARRAY ARRAY['public.exos_event_token_product_save(uuid,jsonb)', 'public.exos_event_token_products(uuid)',
      'public.exos_event_token_lookup(uuid,text)', 'public.exos_event_token_spend(uuid,text,uuid,integer,uuid,timestamptz,text)',
      'public.exos_event_token_undo(uuid,bigint,text)', 'public.exos_event_token_roster(uuid)',
      'public.exos_event_token_pos_sell(uuid,uuid,integer,integer,text,uuid,text,uuid,uuid,text)',
      'public.exos_event_token_card_reissue(uuid,uuid,text)', 'public.exos_event_token_refund_unused(uuid,uuid,text,uuid)',
      'public.exos_event_token_expire(uuid)', 'public.exos_event_token_report(uuid)', 'public.exos_my_event_tokens(uuid)'] LOOP
    ASSERT has_function_privilege('authenticated', f, 'EXECUTE') AND NOT has_function_privilege('anon', f, 'EXECUTE'), 'ET1 signed in only: ' || f;
    ASSERT (SELECT prosecdef AND proconfig::text LIKE '%search_path=public, pg_temp%' FROM pg_proc WHERE oid = f::regprocedure), 'ET1 pinned: ' || f;
  END LOOP;
  RAISE NOTICE 'OK ET1 RLS on, reads only, no code hash, sequence off anon, helpers service role only';
END $$;

-- ── ET2 ─────────────────────────────────────────────────────────────────────
DO $$
DECLARE r jsonb; v_spec jsonb := '{"name":"Drink token","unit_label":"drink","price_cents":500,"bundles":[{"credits":10,"price_cents":4500}],"max_per_order":20,"refundable":false,"grace_hours":2}';
BEGIN
  PERFORM pg_temp.act(pg_temp.u('a3'));
  ASSERT pg_temp.st(format('SELECT public.exos_event_token_product_save(%L, %L)', pg_temp.u('e1'), v_spec)) = '42501', 'ET2 scanner';
  PERFORM pg_temp.act(pg_temp.u('a4'));
  ASSERT pg_temp.st(format('SELECT public.exos_event_token_product_save(%L, %L)', pg_temp.u('e1'), v_spec)) = '42501', 'ET2 finance';
  PERFORM pg_temp.act(pg_temp.u('b9'));
  ASSERT pg_temp.st(format('SELECT public.exos_event_token_product_save(%L, %L)', pg_temp.u('e1'), v_spec)) = '42501', 'ET2 other org';
  PERFORM pg_temp.act(pg_temp.u('a2'));
  ASSERT pg_temp.st(format('SELECT public.exos_event_token_product_save(%L, %L)', pg_temp.u('e1'), v_spec - 'price_cents')) = '22023', 'ET2 price';
  ASSERT pg_temp.st(format('SELECT public.exos_event_token_product_save(%L, %L)', pg_temp.u('e1'),
           v_spec || '{"bundles":[{"credits":10,"price_cents":4500},{"credits":10,"price_cents":4000}]}')) = '22023', 'ET2 two bundles of 10';
  ASSERT pg_temp.st(format('SELECT public.exos_event_token_product_save(%L, %L)', pg_temp.u('e1'),
           v_spec || '{"bundles":[{"credits":1,"price_cents":400}]}')) = '22023', 'ET2 a bundle of 1';
  ASSERT pg_temp.st(format('SELECT public.exos_event_token_product_save(%L, %L)', pg_temp.u('e1'),
           v_spec || '{"max_per_order":900}')) = '22023', 'ET2 max per order';
  r := public.exos_event_token_product_save(pg_temp.u('e1'), v_spec);
  INSERT INTO tk VALUES ('drink', r ->> 'id');
  ASSERT r ->> 'rule' LIKE 'Event tokens, no cash value, valid for Cherry Festival only.%not refundable.', 'ET2 rule ' || (r ->> 'rule');
  ASSERT (SELECT count(*) FROM public.exos_event_addons WHERE token_product_id = pg_temp.v('drink')::uuid AND visibility = 'public') = 2
     AND (SELECT price = 45 AND max_per_order = 2 AND description = r ->> 'rule' FROM public.exos_event_addons
           WHERE token_product_id = pg_temp.v('drink')::uuid AND token_credits = 10), 'ET2 add-on offers';
  ASSERT (SELECT count(*) FROM public.exos_pos_items WHERE token_product_id = pg_temp.v('drink')::uuid AND active AND category = 'merch') = 2,
    'ET2 POS items';
  -- A refundable ride credit, and one on the past event (expired already).
  r := public.exos_event_token_product_save(pg_temp.u('e1'),
         '{"name":"Ride credit","unit_label":"ride","price_cents":200,"bundles":[{"credits":5,"price_cents":900}],"max_per_order":30,"refundable":true}');
  INSERT INTO tk VALUES ('ride', r ->> 'id');
  ASSERT r ->> 'rule' LIKE '%unused tokens are refunded on request%', 'ET2 refundable rule';
  r := public.exos_event_token_product_save(pg_temp.u('e2'), '{"name":"Tasting ticket","price_cents":300}');
  INSERT INTO tk VALUES ('taste', r ->> 'id');
  -- Edit: the bundle changes, the offers follow.
  r := public.exos_event_token_product_save(pg_temp.u('e1'), v_spec || jsonb_build_object('id', pg_temp.v('drink'),
         'bundles', '[{"credits":10,"price_cents":4000}]'::jsonb));
  ASSERT (SELECT price = 40 FROM public.exos_event_addons WHERE token_product_id = pg_temp.v('drink')::uuid AND token_credits = 10), 'ET2 edit';
  -- Another org's product id on this event: not found.
  PERFORM pg_temp.act(pg_temp.u('b9'));
  r := public.exos_event_token_product_save(pg_temp.u('e9'), '{"name":"Other drink","price_cents":600}');
  INSERT INTO tk VALUES ('other', r ->> 'id');
  PERFORM pg_temp.act(pg_temp.u('a2'));
  ASSERT pg_temp.st(format('SELECT public.exos_event_token_product_save(%L, %L)', pg_temp.u('e1'),
           v_spec || jsonb_build_object('id', pg_temp.v('other')))) = 'P0002', 'ET2 another org''s product';
  ASSERT (SELECT count(*) FROM public.exos_org_audit WHERE org_id = pg_temp.u('01') AND action = 'token.configure') = 4, 'ET2 audited';
  RAISE NOTICE 'OK ET2 configure: owner / manager only, validation, offers online + at the door with the rule, audited';
END $$;
-- Client writes to the offers: refused (as a manager through RLS).
SELECT pg_temp.act(pg_temp.u('a2'));
SET ROLE authenticated;
DO $$
BEGIN
  ASSERT pg_temp.st(format('UPDATE public.exos_event_addons SET price = 1 WHERE token_product_id = %L', pg_temp.v('drink'))) = '42501', 'ET2 add-on price';
  ASSERT pg_temp.st(format('INSERT INTO public.exos_event_addons (event_id, name, price, capacity, token_product_id, token_credits) VALUES (%L, %L, 1, 10, %L, 50)',
           pg_temp.u('e1'), 'Cheap', pg_temp.v('drink'))) = '42501', 'ET2 add-on insert';
  ASSERT pg_temp.st(format('UPDATE public.exos_pos_items SET price_cents = 1 WHERE token_product_id = %L', pg_temp.v('drink'))) = '42501', 'ET2 item price';
  ASSERT (SELECT count(*) FROM public.exos_event_token_products WHERE event_id = pg_temp.u('e1')) = 2, 'ET2 manager reads products';
  ASSERT pg_temp.st('SELECT code_hash FROM public.exos_event_token_cards') = '42501', 'ET2 no code hash';
END $$;
RESET ROLE;
DO $$ BEGIN RAISE NOTICE 'OK ET2 client writes to token offers refused'; END $$;

-- ── ET3 ─────────────────────────────────────────────────────────────────────
DO $$
DECLARE v_single uuid; v_ten uuid; v_ride5 uuid; r text;
BEGIN
  SELECT id INTO v_single FROM public.exos_event_addons WHERE token_product_id = pg_temp.v('drink')::uuid AND token_credits = 1;
  SELECT id INTO v_ten FROM public.exos_event_addons WHERE token_product_id = pg_temp.v('drink')::uuid AND token_credits = 10;
  SELECT id INTO v_ride5 FROM public.exos_event_addons WHERE token_product_id = pg_temp.v('ride')::uuid AND token_credits = 5;
  INSERT INTO tk VALUES ('ride5', v_ride5);
  -- The checkout's check: 2 x 10 + 1 = 21 > 20.
  ASSERT public.exos_event_token_order_check(pg_temp.u('e1'),
           jsonb_build_array(jsonb_build_object('addon_id', v_ten, 'quantity', 2), jsonb_build_object('addon_id', v_single, 'quantity', 1)))
         = 'Drink token: at most 20 per order', 'ET3 max per order';
  ASSERT public.exos_event_token_order_check(pg_temp.u('e1'),
           jsonb_build_array(jsonb_build_object('addon_id', v_ten, 'quantity', 2))) IS NULL, 'ET3 20 is fine';
  ASSERT public.exos_event_token_order_check(pg_temp.u('e2'),
           jsonb_build_array(jsonb_build_object('addon_id', (SELECT id FROM public.exos_event_addons WHERE token_product_id = pg_temp.v('taste')::uuid), 'quantity', 1)))
         LIKE '%isn''t on sale', 'ET3 expired product not on sale';
  -- Fulfilment: one 10-pack ($40) + 2 singles ($5 each) of drinks, a ride 5-pack ($9).
  INSERT INTO public.exos_order_addons (id, event_id, org_id, addon_id, addon_name, buyer_id, owner_id, quantity, unit_price_paid, order_ref, channel_source) VALUES
    (pg_temp.u('21'), pg_temp.u('e1'), pg_temp.u('01'), v_ten, '10 × Drink token', pg_temp.u('a5'), pg_temp.u('a5'), 1, 40, 'cs_e70c1', 'stripe'),
    (pg_temp.u('22'), pg_temp.u('e1'), pg_temp.u('01'), v_single, 'Drink token', pg_temp.u('a5'), pg_temp.u('a5'), 2, 5, 'cs_e70c1', 'stripe'),
    (pg_temp.u('23'), pg_temp.u('e1'), pg_temp.u('01'), v_ride5, '5 × Ride credit', pg_temp.u('a5'), pg_temp.u('a5'), 1, 9, 'cs_e70c1', 'stripe'),
    (pg_temp.u('24'), pg_temp.u('e1'), pg_temp.u('01'), v_ride5, '5 × Ride credit', pg_temp.u('a6'), pg_temp.u('a6'), 1, 9, 'cs_e70c2', 'stripe'),
    (pg_temp.u('25'), pg_temp.u('e2'), pg_temp.u('01'), (SELECT id FROM public.exos_event_addons WHERE token_product_id = pg_temp.v('taste')::uuid),
     'Tasting ticket', pg_temp.u('a5'), pg_temp.u('a5'), 3, 3, 'cs_e70c4', 'stripe');
  ASSERT pg_temp.bal('12', 'drink') = 12 AND pg_temp.bal('12', 'ride') = 5, 'ET3 on the buyer''s own ticket';
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_event_token_cards WHERE ticket_id = pg_temp.u('11')), 'ET3 not the friend''s';
  ASSERT pg_temp.bal('13', 'ride') = 5 AND pg_temp.bal('14', 'taste') = 3, 'ET3 the other orders';
  ASSERT (SELECT count(*) FROM public.exos_event_token_lots WHERE order_addon_id IN (pg_temp.u('21'), pg_temp.u('22')) AND source = 'online'
            AND session_id = 'cs_e70c1') = 2
     AND (SELECT sum(value_cents) FROM public.exos_event_token_lots WHERE order_addon_id IN (pg_temp.u('21'), pg_temp.u('22'))) = 5000,
    'ET3 lots carry what was paid';
  ASSERT (SELECT count(*) FROM public.exos_event_token_ledger WHERE kind = 'purchase' AND org_id = pg_temp.u('01')) = 5, 'ET3 purchase rows';
  -- The journal: 50.00 + 9.00 + 9.00 + 9.00 deferred out of ticket revenue.
  ASSERT pg_temp.acct('event_tokens_outstanding') = -7700 AND pg_temp.acct('ticket_revenue') = 7700, 'ET3 deferred ' || pg_temp.acct('event_tokens_outstanding');
  ASSERT (SELECT count(*) FROM public.exos_journal_entries WHERE source_table = 'exos_event_token_ledger' AND kind = 'token_purchase'
            AND org_id = pg_temp.u('01')) = 5, 'ET3 one entry per purchase';
  -- A re-run of the trigger adds nothing (one lot per line).
  UPDATE public.exos_order_addons SET owner_id = owner_id WHERE id = pg_temp.u('21');
  ASSERT (SELECT count(*) FROM public.exos_event_token_lots WHERE order_addon_id = pg_temp.u('21')) = 1, 'ET3 once';
  RAISE NOTICE 'OK ET3 bought online: credits on the buyer''s own ticket, max per order at checkout, value deferred in the journal';
END $$;

-- ── ET4 ─────────────────────────────────────────────────────────────────────
DO $$
DECLARE r jsonb; r2 jsonb; v_ref uuid := gen_random_uuid(); v_code text := pg_temp.tcode(pg_temp.u('12'));
BEGIN
  PERFORM pg_temp.act(pg_temp.u('a4'));
  ASSERT pg_temp.st(format('SELECT public.exos_event_token_spend(%L, %L, %L, 1, %L)', pg_temp.u('e1'), v_code, pg_temp.v('drink'), gen_random_uuid())) = '42501',
    'ET4 finance can''t spend';
  PERFORM pg_temp.act(pg_temp.u('a3'));
  r := public.exos_event_token_spend(pg_temp.u('e1'), v_code, pg_temp.v('drink')::uuid, 3, v_ref, NULL, 'bar-1');
  ASSERT (r ->> 'ok')::boolean AND (r ->> 'spent')::int = 3 AND (r ->> 'balance')::int = 9, 'ET4 spend ' || r::text;
  INSERT INTO tk VALUES ('spend1', r ->> 'ledger_id');
  -- The same ref again: the first answer, nothing more taken.
  r2 := public.exos_event_token_spend(pg_temp.u('e1'), v_code, pg_temp.v('drink')::uuid, 3, v_ref, NULL, 'bar-1');
  ASSERT (r2 ->> 'duplicate')::boolean AND (r2 ->> 'ledger_id') = (r ->> 'ledger_id') AND pg_temp.bal('12', 'drink') = 9, 'ET4 replay';
  r2 := public.exos_event_token_spend(pg_temp.u('e1'), v_code, pg_temp.v('drink')::uuid, 2, v_ref, NULL, 'bar-1');
  ASSERT r2 ->> 'reason' = 'bad-client-ref', 'ET4 ref reused for another spend';
  -- All or nothing: 10 > 9.
  r := public.exos_event_token_spend(pg_temp.u('e1'), v_code, pg_temp.v('drink')::uuid, 10, gen_random_uuid());
  ASSERT NOT (r ->> 'ok')::boolean AND r ->> 'reason' = 'insufficient' AND (r ->> 'balance')::int = 9 AND pg_temp.bal('12', 'drink') = 9,
    'ET4 insufficient ' || r::text;
  -- The value taken: the 10-pack first (oldest lot), 3 x 4.00 = 12.00.
  ASSERT (SELECT amount_cents FROM public.exos_event_token_ledger WHERE id = pg_temp.v('spend1')::bigint) = -1200, 'ET4 value';
  ASSERT (r ->> 'balance') IS NOT NULL AND public.exos_event_token_spend(pg_temp.u('e1'), v_code, pg_temp.v('drink')::uuid, 0, gen_random_uuid()) ->> 'reason' = 'bad-credits',
    'ET4 0 credits';
  -- Another event's / org's codes, a forged one, a stale one.
  ASSERT public.exos_event_token_spend(pg_temp.u('e1'), pg_temp.tcode(pg_temp.u('19')), pg_temp.v('drink')::uuid, 1, gen_random_uuid()) ->> 'reason' = 'not-found',
    'ET4 another org''s ticket';
  ASSERT public.exos_event_token_spend(pg_temp.u('e1'), pg_temp.tcode(pg_temp.u('14')), pg_temp.v('drink')::uuid, 1, gen_random_uuid()) ->> 'reason' = 'not-found',
    'ET4 another event''s ticket';
  ASSERT public.exos_event_token_spend(pg_temp.u('e1'), left(v_code, length(v_code) - 3) || 'AAA', pg_temp.v('drink')::uuid, 1, gen_random_uuid()) ->> 'reason'
         = 'barcode-rejected', 'ET4 forged';
  ASSERT public.exos_event_token_spend(pg_temp.u('e1'), pg_temp.tcode(pg_temp.u('12'), clock_timestamp() - interval '10 minutes'),
           pg_temp.v('drink')::uuid, 1, gen_random_uuid()) ->> 'reason' = 'barcode-expired', 'ET4 stale code';
  ASSERT public.exos_event_token_spend(pg_temp.u('e1'), v_code, pg_temp.v('other')::uuid, 1, gen_random_uuid()) ->> 'reason' = 'unknown-product',
    'ET4 another org''s product';
  ASSERT public.exos_event_token_spend(pg_temp.u('e1'), 'K-ABCDEFGHJKLMNPQR', pg_temp.v('drink')::uuid, 1, gen_random_uuid()) ->> 'reason' = 'not-found',
    'ET4 unknown code';
  -- A ticket with no tokens: insufficient, balance 0.
  r := public.exos_event_token_spend(pg_temp.u('e1'), pg_temp.tcode(pg_temp.u('11')), pg_temp.v('drink')::uuid, 1, gen_random_uuid());
  ASSERT r ->> 'reason' = 'insufficient' AND (r ->> 'balance')::int = 0, 'ET4 no tokens';
  -- Lookup.
  r := public.exos_event_token_lookup(pg_temp.u('e1'), v_code);
  ASSERT (r ->> 'ok')::boolean AND jsonb_array_length(r -> 'balances') = 2, 'ET4 lookup ' || r::text;
  ASSERT pg_temp.acct('event_token_redemptions') = -1200, 'ET4 journal redemption';
  RAISE NOTICE 'OK ET4 spend: door staff, the ticket''s own code, all or nothing, idempotent ref, other events / orgs not found';
END $$;

-- ── ET5 ─────────────────────────────────────────────────────────────────────
DO $$
DECLARE r jsonb;
BEGIN
  PERFORM pg_temp.act(pg_temp.u('a3'));
  ASSERT pg_temp.st(format('SELECT public.exos_event_token_undo(%L, %s, %L)', pg_temp.u('e1'), pg_temp.v('spend1'), 'wrong drink')) = '42501',
    'ET5 scanner can''t undo';
  PERFORM pg_temp.act(pg_temp.u('a2'));
  ASSERT pg_temp.st(format('SELECT public.exos_event_token_undo(%L, %s, %L)', pg_temp.u('e1'), pg_temp.v('spend1'), 'x')) = '22023:reason-required',
    'ET5 reason';
  ASSERT pg_temp.st(format('SELECT public.exos_event_token_undo(%L, %s, %L)', pg_temp.u('e2'), pg_temp.v('spend1'), 'wrong drink')) = 'P0002',
    'ET5 the spend''s own event';
  r := public.exos_event_token_undo(pg_temp.u('e1'), pg_temp.v('spend1')::bigint, 'rang the wrong guest');
  ASSERT (r ->> 'ok')::boolean AND (r ->> 'balance')::int = 12 AND pg_temp.bal('12', 'drink') = 12, 'ET5 undone ' || r::text;
  r := public.exos_event_token_undo(pg_temp.u('e1'), pg_temp.v('spend1')::bigint, 'again');
  ASSERT (r ->> 'duplicate')::boolean AND pg_temp.bal('12', 'drink') = 12, 'ET5 once';
  ASSERT (SELECT count(*) FROM public.exos_org_audit WHERE org_id = pg_temp.u('01') AND action = 'token.undo'
            AND entity_id = pg_temp.v('spend1') AND reason = 'rang the wrong guest') = 1, 'ET5 audited';
  ASSERT pg_temp.acct('event_token_redemptions') = 0, 'ET5 journal reversed';
  -- Spend again for the rest of the suite: 3 drinks.
  PERFORM pg_temp.act(pg_temp.u('a3'));
  r := public.exos_event_token_spend(pg_temp.u('e1'), pg_temp.tcode(pg_temp.u('12')), pg_temp.v('drink')::uuid, 3, gen_random_uuid());
  ASSERT (r ->> 'balance')::int = 9, 'ET5 spend again';
  RAISE NOTICE 'OK ET5 undo: owner / manager, a reason, once, credits back, audited, journal reversed';
END $$;

-- ── ET6 ─────────────────────────────────────────────────────────────────────
DO $$
DECLARE r jsonb; r2 jsonb; v_key uuid := gen_random_uuid(); v_cash int;
BEGIN
  PERFORM pg_temp.act(pg_temp.u('a3'));
  -- Comps: owner / manager only.
  ASSERT pg_temp.st(format('SELECT public.exos_event_token_pos_sell(%L, %L, 10, 1, %L, %L)', pg_temp.u('e1'), pg_temp.v('drink'), 'comp', gen_random_uuid()))
         = '42501:comp-role', 'ET6 scanner comp';
  ASSERT pg_temp.st(format('SELECT public.exos_event_token_pos_sell(%L, %L, 10, 1, %L, %L)', pg_temp.u('e1'), pg_temp.v('drink'), 'card', gen_random_uuid()))
         = '0A000:card-not-connected', 'ET6 card not yet';
  ASSERT pg_temp.st(format('SELECT public.exos_event_token_pos_sell(%L, %L, 10, 3, %L, %L)', pg_temp.u('e1'), pg_temp.v('drink'), 'cash', gen_random_uuid()))
         = '22023:max-per-order', 'ET6 30 > 20';
  ASSERT pg_temp.st(format('SELECT public.exos_event_token_pos_sell(%L, %L, 7, 1, %L, %L)', pg_temp.u('e1'), pg_temp.v('drink'), 'cash', gen_random_uuid()))
         = 'P0002', 'ET6 no 7-pack';
  v_cash := public._exos_pos_drawer_cash(pg_temp.u('81'));
  r := public.exos_event_token_pos_sell(pg_temp.u('e1'), pg_temp.v('drink')::uuid, 10, 1, 'cash', v_key);
  ASSERT r ->> 'code' ~ '^K-[A-Z2-9]{16}$' AND (r ->> 'credits')::int = 10 AND (r ->> 'total_cents')::int = 4000 AND (r ->> 'balance')::int = 10,
    'ET6 sold ' || r::text;
  INSERT INTO tk VALUES ('kcode', r ->> 'code'), ('korder', r ->> 'order_id'), ('kcard', r ->> 'card_id');
  ASSERT (SELECT code_hash = public._exos_event_token_hash(public._exos_event_token_code(r ->> 'code'))
                 AND position(substr(r ->> 'code', 3) IN code_hash) = 0 AND code_last4 = right(r ->> 'code', 4)
            FROM public.exos_event_token_cards WHERE id = (r ->> 'card_id')::uuid), 'ET6 only the hash kept';
  ASSERT public._exos_pos_drawer_cash(pg_temp.u('81')) = v_cash + 4000, 'ET6 the drawer has the cash';
  ASSERT (SELECT status = 'paid' AND payment_method = 'cash' FROM public.exos_pos_orders WHERE id = (r ->> 'order_id')::uuid), 'ET6 a paid POS order';
  -- A double tap: the same sale, no second code.
  r2 := public.exos_event_token_pos_sell(pg_temp.u('e1'), pg_temp.v('drink')::uuid, 10, 1, 'cash', v_key);
  ASSERT (r2 ->> 'replay')::boolean AND r2 ->> 'order_id' = r ->> 'order_id' AND r2 ->> 'code' IS NULL
     AND public._exos_pos_drawer_cash(pg_temp.u('81')) = v_cash + 4000, 'ET6 one sale';
  -- The code spends (typed with dashes too).
  r2 := public.exos_event_token_spend(pg_temp.u('e1'), regexp_replace(substr(pg_temp.v('kcode'), 3), '(.{4})(?!$)', '\1-', 'g'),
          pg_temp.v('drink')::uuid, 2, gen_random_uuid());
  ASSERT (r2 ->> 'ok')::boolean AND (r2 ->> 'balance')::int = 8, 'ET6 the code spends ' || r2::text;
  -- Void after a spend: refused, nothing changes.
  ASSERT pg_temp.st(format('SELECT public.exos_pos_void_order(%L, %L)', pg_temp.v('korder'), 'guest changed mind')) = '55000:tokens-spent',
    'ET6 void after a spend';
  ASSERT (SELECT status FROM public.exos_pos_orders WHERE id = pg_temp.v('korder')::uuid) = 'paid', 'ET6 still paid';
  -- A second sale voided before any spend: the credits leave with the cash.
  r := public.exos_event_token_pos_sell(pg_temp.u('e1'), pg_temp.v('drink')::uuid, 1, 2, 'cash', gen_random_uuid(), pg_temp.v('kcode'));
  ASSERT (r ->> 'balance')::int = 10 AND r ->> 'code' IS NULL AND r ->> 'card_id' = pg_temp.v('kcard'), 'ET6 top-up onto the code';
  r2 := public.exos_pos_void_order((r ->> 'order_id')::uuid, 'wrong button');
  ASSERT public._exos_event_token_balance(pg_temp.v('kcard')::uuid, pg_temp.v('drink')::uuid) = 8, 'ET6 void took them back';
  ASSERT (SELECT count(*) FROM public.exos_event_token_ledger WHERE card_id = pg_temp.v('kcard')::uuid AND kind = 'refund' AND credits = -2) = 1, 'ET6 refund row';
  -- Top up a ticket at the door.
  r := public.exos_event_token_pos_sell(pg_temp.u('e1'), pg_temp.v('ride')::uuid, 1, 2, 'cash', gen_random_uuid(), pg_temp.tcode(pg_temp.u('11')));
  ASSERT pg_temp.bal('11', 'ride') = 2, 'ET6 onto a ticket';
  -- A comp by the manager (value 0).
  PERFORM pg_temp.act(pg_temp.u('a2'));
  r := public.exos_event_token_pos_sell(pg_temp.u('e1'), pg_temp.v('drink')::uuid, 1, 2, 'comp', gen_random_uuid(), pg_temp.v('kcode'), NULL, NULL, 'band rider');
  ASSERT (r ->> 'balance')::int = 10 AND (SELECT source = 'comp' AND value_cents = 0 FROM public.exos_event_token_lots
                                           WHERE pos_order_id = (r ->> 'order_id')::uuid), 'ET6 comp';
  ASSERT (SELECT count(*) FROM public.exos_org_audit WHERE org_id = pg_temp.u('01') AND action = 'token.sell') = 4, 'ET6 audited';
  -- The journal: the cash sale credited bar & merch; the deferral moved it to tokens outstanding.
  ASSERT (SELECT count(*) FROM public.exos_journal_entries WHERE kind = 'token_purchase' AND org_id = pg_temp.u('01')
            AND source_id IN (SELECT id::text FROM public.exos_event_token_ledger WHERE card_id = pg_temp.v('kcard')::uuid AND kind = 'purchase')) = 2,
    'ET6 deferrals (the comp posts nothing)';
  RAISE NOTICE 'OK ET6 door: cash into the drawer onto a new code (hash only) or a ticket, comps owner / manager, one sale per key, void before a spend only, audited';
END $$;
-- A client ringing a token item itself: refused.
SELECT pg_temp.act(pg_temp.u('a3'));
SET ROLE authenticated;
DO $$
DECLARE v_o uuid;
BEGIN
  INSERT INTO public.exos_pos_orders (event_id) VALUES (pg_temp.u('e1')) RETURNING id INTO v_o;
  ASSERT pg_temp.st(format('INSERT INTO public.exos_pos_order_lines (order_id, org_id, event_id, item_id, category, name, quantity, unit_price_cents) VALUES (%L, %L, %L, %L, %L, %L, 1, 0)',
           v_o, pg_temp.u('01'), pg_temp.u('e1'),
           (SELECT id FROM public.exos_pos_items WHERE token_product_id = pg_temp.v('drink')::uuid AND token_credits = 10), 'merch', 'x')) = '42501',
    'ET6 a client token line';
END $$;
RESET ROLE;
DO $$ BEGIN RAISE NOTICE 'OK ET6 a token item is rung only by the token sale'; END $$;

-- ── ET7 ─────────────────────────────────────────────────────────────────────
DO $$
DECLARE r jsonb; r2 jsonb; v_ref uuid := gen_random_uuid(); v_ref2 uuid := gen_random_uuid(); v_at timestamptz := clock_timestamp() - interval '20 minutes';
BEGIN
  PERFORM pg_temp.act(pg_temp.u('a3'));
  -- The roster: balances by ticket and by code hash.
  r := public.exos_event_token_roster(pg_temp.u('e1'));
  ASSERT EXISTS (SELECT 1 FROM jsonb_array_elements(r -> 'cards') c WHERE c ->> 'ticket_id' = pg_temp.u('12')::text
                    AND (c -> 'balances' ->> pg_temp.v('drink'))::int = 9)
     AND EXISTS (SELECT 1 FROM jsonb_array_elements(r -> 'cards') c
                  WHERE c ->> 'code_hash' = public._exos_event_token_hash(public._exos_event_token_code(pg_temp.v('kcode')))), 'ET7 roster';
  -- Two devices took 6 drinks each offline from the 9 on ticket 12.
  r := public.exos_event_token_spend(pg_temp.u('e1'), pg_temp.tcode(pg_temp.u('12'), v_at), pg_temp.v('drink')::uuid, 6, v_ref, v_at, 'bar-2');
  ASSERT (r ->> 'ok')::boolean AND (r ->> 'balance')::int = 3, 'ET7 first replay ' || r::text;
  r := public.exos_event_token_spend(pg_temp.u('e1'), pg_temp.tcode(pg_temp.u('12'), v_at + interval '1 minute'), pg_temp.v('drink')::uuid, 6, v_ref2,
         v_at + interval '1 minute', 'bar-3');
  ASSERT NOT (r ->> 'ok')::boolean AND r ->> 'reason' = 'overspent' AND (r ->> 'spent')::int = 3 AND (r ->> 'short')::int = 3
     AND (r ->> 'balance')::int = 0 AND pg_temp.bal('12', 'drink') = 0, 'ET7 overspent ' || r::text;
  ASSERT (SELECT kind = 'overspent' AND credits_short = 3 AND credits_asked = 6 AND device = 'bar-3' AND ledger_id IS NOT NULL
            FROM public.exos_event_token_exceptions WHERE client_ref = v_ref2), 'ET7 exception row';
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_event_token_lots WHERE credits_left < 0), 'ET7 never negative';
  -- The same replay again: the same answer, no second exception.
  r2 := public.exos_event_token_spend(pg_temp.u('e1'), pg_temp.tcode(pg_temp.u('12'), v_at + interval '1 minute'), pg_temp.v('drink')::uuid, 6, v_ref2,
          v_at + interval '1 minute', 'bar-3');
  ASSERT (r2 ->> 'duplicate')::boolean AND r2 ->> 'reason' = 'overspent' AND (r2 ->> 'short')::int = 3
     AND (SELECT count(*) FROM public.exos_event_token_exceptions WHERE client_ref = v_ref2) = 1, 'ET7 replay idempotent';
  -- Fully overspent (balance 0): an exception with no ledger row.
  r := public.exos_event_token_spend(pg_temp.u('e1'), pg_temp.tcode(pg_temp.u('12'), v_at), pg_temp.v('drink')::uuid, 2, gen_random_uuid(), v_at, 'bar-2');
  ASSERT r ->> 'reason' = 'overspent' AND (r ->> 'spent')::int = 0 AND (r ->> 'short')::int = 2, 'ET7 all short';
  -- A code that no longer passes (forged at sync): 'rejected'.
  r := public.exos_event_token_spend(pg_temp.u('e1'), 'T-' || pg_temp.u('12') || ':' || pg_temp.u('a5') || ':1:bad', pg_temp.v('drink')::uuid, 1,
         gen_random_uuid(), v_at, 'bar-2');
  ASSERT r ->> 'reason' = 'rejected' AND r ->> 'why' = 'barcode-rejected', 'ET7 rejected ' || r::text;
  -- A time from the future: refused, nothing recorded.
  ASSERT public.exos_event_token_spend(pg_temp.u('e1'), pg_temp.v('kcode'), pg_temp.v('drink')::uuid, 1, gen_random_uuid(),
           clock_timestamp() + interval '1 hour', 'bar-2') ->> 'reason' = 'bad-scan-time', 'ET7 future';
  ASSERT (SELECT count(*) FROM public.exos_org_audit WHERE org_id = pg_temp.u('01') AND action = 'token.overspent') = 2, 'ET7 audited';
  RAISE NOTICE 'OK ET7 offline: replays take what is left, the rest is an overspent exception (never negative), idempotent, rejected codes recorded';
END $$;

-- ── ET8 ─────────────────────────────────────────────────────────────────────
DO $$
DECLARE r jsonb; v_out bigint;
BEGIN
  PERFORM pg_temp.act(pg_temp.u('a3'));
  -- e2 ended a day ago (grace 0): its tasting tickets can't be spent.
  r := public.exos_event_token_spend(pg_temp.u('e2'), pg_temp.tcode(pg_temp.u('14')), pg_temp.v('taste')::uuid, 1, gen_random_uuid());
  ASSERT r ->> 'reason' = 'expired' AND pg_temp.bal('14', 'taste') = 3, 'ET8 expired ' || r::text;
  ASSERT pg_temp.st(format('SELECT public.exos_event_token_pos_sell(%L, %L, 1, 1, %L, %L)', pg_temp.u('e2'), pg_temp.v('taste'), 'cash', gen_random_uuid()))
         = '55000:not-on-sale', 'ET8 not sold after expiry';
  ASSERT pg_temp.st(format('SELECT public.exos_event_token_expire(%L)', pg_temp.u('e2'))) = '42501', 'ET8 scanner can''t expire';
  PERFORM pg_temp.act(pg_temp.u('a2'));
  -- e1 hasn't ended: nothing to expire.
  ASSERT (public.exos_event_token_expire(pg_temp.u('e1')) ->> 'lots')::int = 0, 'ET8 not yet';
  v_out := pg_temp.acct('event_token_breakage');
  r := public.exos_event_token_expire(pg_temp.u('e2'));
  ASSERT (r ->> 'lots')::int = 1 AND (r ->> 'credits')::int = 3 AND (r ->> 'cents')::int = 900 AND pg_temp.bal('14', 'taste') = 0, 'ET8 ' || r::text;
  ASSERT (SELECT status FROM public.exos_event_token_lots WHERE order_addon_id = pg_temp.u('25')) = 'expired', 'ET8 lot expired';
  ASSERT pg_temp.acct('event_token_breakage') = v_out - 900, 'ET8 breakage';
  ASSERT (public.exos_event_token_expire(pg_temp.u('e2')) ->> 'lots')::int = 0, 'ET8 once';
  ASSERT (SELECT count(*) FROM public.exos_org_audit WHERE org_id = pg_temp.u('01') AND action = 'token.expire') = 1, 'ET8 audited';
  -- The cron's sweep: a refundable product past expiry is left for refunds.
  -- e1 ended 3 hours ago: drinks (grace 2 hours) and rides (grace 0) are past expiry.
  UPDATE public.exos_events SET ends_at = now() - interval '3 hours', starts_at = now() - interval '8 hours' WHERE id = pg_temp.u('e1');
  ASSERT (public._exos_event_token_expire_due() ->> 'events')::int = 1, 'ET8 the sweep';
  ASSERT pg_temp.bal('12', 'ride') = 5 AND pg_temp.bal('12', 'drink') = 0
     AND public._exos_event_token_balance(pg_temp.v('kcard')::uuid, pg_temp.v('drink')::uuid) = 0, 'ET8 rides stay, drinks expire';
  PERFORM pg_temp.act(pg_temp.u('a3'));
  ASSERT public.exos_event_token_spend(pg_temp.u('e1'), pg_temp.tcode(pg_temp.u('12')), pg_temp.v('ride')::uuid, 1, gen_random_uuid()) ->> 'reason' = 'expired',
    'ET8 rides can''t be spent either';
  -- An offline spend from before the end is still taken.
  r := public.exos_event_token_spend(pg_temp.u('e1'), pg_temp.tcode(pg_temp.u('13'), now() - interval '4 hours'), pg_temp.v('ride')::uuid, 1,
         gen_random_uuid(), now() - interval '4 hours', 'gate');
  ASSERT (r ->> 'ok')::boolean AND pg_temp.bal('13', 'ride') = 4, 'ET8 an offline spend before the end ' || r::text;
  RAISE NOTICE 'OK ET8 expiry: no spend or sale after end + grace, expire rows (breakage) for non-refundable only, once, audited';
END $$;

-- ── ET9 ─────────────────────────────────────────────────────────────────────
DO $$
DECLARE r jsonb; r2 jsonb; v_lot uuid; v_cash int;
BEGIN
  SELECT id INTO v_lot FROM public.exos_event_token_lots WHERE order_addon_id = pg_temp.u('23');
  PERFORM pg_temp.act(pg_temp.u('a3'));
  ASSERT pg_temp.st(format('SELECT public.exos_event_token_refund_unused(%L, %L, %L)', pg_temp.u('e1'), v_lot, 'unused rides')) = '42501', 'ET9 scanner';
  PERFORM pg_temp.act(pg_temp.u('a2'));
  -- Drinks aren't refundable.
  ASSERT pg_temp.st(format('SELECT public.exos_event_token_refund_unused(%L, %L, %L)', pg_temp.u('e1'),
           (SELECT id FROM public.exos_event_token_lots WHERE order_addon_id = pg_temp.u('22')), 'please')) = '55000:not-refundable', 'ET9 not refundable';
  r := public.exos_event_token_refund_unused(pg_temp.u('e1'), v_lot, 'unused rides');
  ASSERT r ->> 'source' = 'online' AND (r ->> 'credits')::int = 5 AND (r ->> 'amount_cents')::int = 900 AND r ->> 'session_id' = 'cs_e70c1'
     AND r ->> 'refund_key' ~ '^evtoken-refund:[0-9]+$' AND pg_temp.bal('12', 'ride') = 0, 'ET9 online ' || r::text;
  r2 := public.exos_event_token_refund_unused(pg_temp.u('e1'), v_lot, 'unused rides');
  ASSERT (r2 ->> 'replay')::boolean AND r2 ->> 'refund_key' = r ->> 'refund_key' AND (r2 ->> 'amount_cents')::int = 900, 'ET9 once';
  -- (the ET6 void's refund row posted the first one)
  ASSERT (SELECT count(*) FROM public.exos_journal_entries WHERE kind = 'token_refund' AND org_id = pg_temp.u('01')) = 2, 'ET9 journal';
  -- The ticket at the door bought 2 rides for cash: paid back from a drawer.
  SELECT id INTO v_lot FROM public.exos_event_token_lots WHERE card_id = (SELECT id FROM public.exos_event_token_cards WHERE ticket_id = pg_temp.u('11'));
  ASSERT pg_temp.st(format('SELECT public.exos_event_token_refund_unused(%L, %L, %L)', pg_temp.u('e1'), v_lot, 'left early')) = '55000:no-drawer',
    'ET9 the manager has no drawer';
  v_cash := public._exos_pos_drawer_cash(pg_temp.u('81'));
  r := public.exos_event_token_refund_unused(pg_temp.u('e1'), v_lot, 'left early', pg_temp.u('81'));
  ASSERT r ->> 'source' = 'pos' AND (r ->> 'amount_cents')::int = 400 AND r ->> 'paid_out_id' IS NOT NULL
     AND public._exos_pos_drawer_cash(pg_temp.u('81')) = v_cash - 400 AND pg_temp.bal('11', 'ride') = 0, 'ET9 cash ' || r::text;
  ASSERT (SELECT kind = 'refund' AND amount_cents = 400 FROM public.exos_pos_paid_outs WHERE id = (r ->> 'paid_out_id')::uuid), 'ET9 paid-out';
  -- That sale can't be voided now (refunded already).
  ASSERT pg_temp.st(format('SELECT public.exos_pos_void_order(%L, %L)',
           (SELECT pos_order_id FROM public.exos_event_token_lots WHERE id = v_lot), 'try again')) = '55000:tokens-spent', 'ET9 no second refund';
  -- A full order refund: what is left on the friend's rides leaves the card.
  UPDATE public.exos_order_addons SET status = 'refunded' WHERE id = pg_temp.u('24');
  ASSERT pg_temp.bal('13', 'ride') = 0 AND (SELECT -credits FROM public.exos_event_token_ledger
                                             WHERE lot_id = (SELECT id FROM public.exos_event_token_lots WHERE order_addon_id = pg_temp.u('24'))
                                               AND kind = 'refund') = 4, 'ET9 order refund';
  ASSERT (SELECT count(*) FROM public.exos_org_audit WHERE org_id = pg_temp.u('01') AND action = 'token.refund') = 2, 'ET9 audited';
  RAISE NOTICE 'OK ET9 refunds: refundable only, online -> order + amount + key (idempotent), cash -> a paid-out, a full order refund takes the rest';
END $$;

-- ── ET10 ────────────────────────────────────────────────────────────────────
DO $$
BEGIN
  -- Check every entry's balance now (the constraint triggers run at commit otherwise).
  SET CONSTRAINTS exos_journal_entries_balanced, exos_journal_lines_balanced IMMEDIATE;
  SET CONSTRAINTS exos_journal_entries_balanced, exos_journal_lines_balanced DEFERRED;
  ASSERT (SELECT sum(debit_cents) = sum(credit_cents) FROM public.exos_journal_trial_balance(pg_temp.u('01'))), 'ET10 balanced';
  ASSERT -pg_temp.acct('event_tokens_outstanding') = (SELECT coalesce(sum(value_left), 0) FROM public.exos_event_token_lots
                                                       WHERE org_id = pg_temp.u('01') AND status = 'active'),
    'ET10 outstanding = value on cards ' || pg_temp.acct('event_tokens_outstanding');
  ASSERT (SELECT count(*) FROM public.exos_event_token_ledger g WHERE g.org_id = pg_temp.u('01') AND g.amount_cents <> 0
            AND NOT EXISTS (SELECT 1 FROM public.exos_journal_entries e WHERE e.source_table = 'exos_event_token_ledger' AND e.source_id = g.id::text)
            AND NOT EXISTS (SELECT 1 FROM public.exos_event_token_lots l WHERE l.id = g.lot_id AND l.source = 'comp')) = 0, 'ET10 every row posted';
  -- The backfill posts nothing new.
  ASSERT (public._exos_journal_backfill(pg_temp.u('01')) ->> 'posted')::int = 0, 'ET10 backfill idempotent';
  ASSERT pg_temp.st(format('SELECT public._exos_journal_post(%L, NULL, %L, %L, %L, now(), %L, %L, %L::jsonb)', pg_temp.u('01'),
           'exos_event_token_ledger', 'x', 'token_spend', 'usd', 'x', '[{"a":"event_tokens_outstanding","c":100},{"a":"event_token_redemptions","c":-100}]'))
         = 'ok', 'ET10 the accounts and source are accepted';
  ASSERT (SELECT count(*) FROM public.exos_journal_accounts()) = 28, 'ET10 the chart';
  RAISE NOTICE 'OK ET10 journal: balanced, outstanding = value on cards, every ledger row posted, backfill idempotent';
END $$;

-- ── ET11 ────────────────────────────────────────────────────────────────────
DO $$
BEGIN
  PERFORM pg_temp.act(pg_temp.u('b9'));
  ASSERT pg_temp.st(format('SELECT public.exos_event_token_spend(%L, %L, %L, 1, %L)', pg_temp.u('e1'), pg_temp.v('kcode'), pg_temp.v('drink'), gen_random_uuid())) = '42501', 'ET11 spend';
  ASSERT pg_temp.st(format('SELECT public.exos_event_token_lookup(%L, %L)', pg_temp.u('e1'), pg_temp.v('kcode'))) = '42501', 'ET11 lookup';
  ASSERT pg_temp.st(format('SELECT public.exos_event_token_pos_sell(%L, %L, 1, 1, %L, %L)', pg_temp.u('e1'), pg_temp.v('drink'), 'cash', gen_random_uuid())) = '42501', 'ET11 sell';
  ASSERT pg_temp.st(format('SELECT public.exos_event_token_undo(%L, %s, %L)', pg_temp.u('e1'), pg_temp.v('spend1'), 'mine now')) = '42501', 'ET11 undo';
  ASSERT pg_temp.st(format('SELECT public.exos_event_token_report(%L)', pg_temp.u('e1'))) = '42501', 'ET11 report';
  ASSERT pg_temp.st(format('SELECT public.exos_event_token_roster(%L)', pg_temp.u('e1'))) = '42501', 'ET11 roster';
  ASSERT pg_temp.st(format('SELECT public.exos_event_token_products(%L)', pg_temp.u('e1'))) = '42501', 'ET11 products';
  ASSERT pg_temp.st(format('SELECT public.exos_event_token_card_reissue(%L, %L, %L)', pg_temp.u('e1'), pg_temp.v('kcard'), 'lost it')) = '42501', 'ET11 reissue';
  -- Their own event: our code is not found there, nothing about it said.
  ASSERT public.exos_event_token_spend(pg_temp.u('e9'), pg_temp.v('kcode'), pg_temp.v('other')::uuid, 1, gen_random_uuid()) ->> 'reason' = 'not-found', 'ET11 our code';
  ASSERT public.exos_event_token_lookup(pg_temp.u('e9'), pg_temp.tcode(pg_temp.u('12'))) = '{"ok": false, "reason": "not-found"}'::jsonb, 'ET11 our ticket';
  ASSERT public.exos_event_token_spend(pg_temp.u('e9'), pg_temp.v('kcode'), pg_temp.v('drink')::uuid, 1, gen_random_uuid()) ->> 'reason' = 'unknown-product', 'ET11 our product';
  RAISE NOTICE 'OK ET11 cross-org: spend, lookup, sell, undo, report, roster, products, reissue refused; codes never cross';
END $$;
SELECT pg_temp.act(pg_temp.u('b9'));
SET ROLE authenticated;
DO $$
BEGIN
  ASSERT (SELECT count(*) FROM public.exos_event_token_products WHERE org_id = pg_temp.u('01')) = 0
     AND (SELECT count(*) FROM public.exos_event_token_ledger WHERE org_id = pg_temp.u('01')) = 0
     AND (SELECT count(*) FROM public.exos_event_token_lots WHERE org_id = pg_temp.u('01')) = 0, 'ET11 RLS';
END $$;
RESET ROLE;

-- ── ET12 ────────────────────────────────────────────────────────────────────
DO $$
DECLARE r jsonb;
BEGIN
  -- The buyer holds ticket 12 (its credits spent, expired or refunded by now: the history still shows).
  PERFORM pg_temp.act(pg_temp.u('a5'));
  r := public.exos_my_event_tokens(pg_temp.u('e1'));
  ASSERT jsonb_array_length(r) = 1 AND r -> 0 ->> 'ticket_id' = pg_temp.u('12')::text AND r -> 0 ->> 'event_name' = 'Cherry Festival'
     AND (r -> 0 -> 'rules' ->> pg_temp.v('drink')) LIKE 'Event tokens, no cash value%', 'ET12 holder ' || r::text;
  PERFORM pg_temp.act(pg_temp.u('a6'));
  r := public.exos_my_event_tokens(pg_temp.u('e1'));
  -- The friend holds ticket 11 (rides refunded) and 13 (refunded): their cards, nobody else's.
  ASSERT NOT EXISTS (SELECT 1 FROM jsonb_array_elements(r) x WHERE x ->> 'ticket_id' = pg_temp.u('12')::text), 'ET12 not someone else''s';
  PERFORM pg_temp.act(NULL);
  ASSERT pg_temp.st('SELECT public.exos_my_event_tokens(NULL)') = '42501', 'ET12 signed in';
  RAISE NOTICE 'OK ET12 the ticket page: the holder''s own balances and the rule';
END $$;

-- ── ET13 ────────────────────────────────────────────────────────────────────
DO $$
DECLARE r jsonb; d jsonb; v_reissue jsonb;
BEGIN
  PERFORM pg_temp.act(pg_temp.u('a3'));
  ASSERT pg_temp.st(format('SELECT public.exos_event_token_report(%L)', pg_temp.u('e1'))) = '42501', 'ET13 scanner';
  PERFORM pg_temp.act(pg_temp.u('a4'));
  r := public.exos_event_token_report(pg_temp.u('e1'));
  SELECT x INTO d FROM jsonb_array_elements(r -> 'products') x WHERE x ->> 'name' = 'Drink token';
  ASSERT (d ->> 'sold_credits')::int = (d ->> 'redeemed_credits')::int + (d ->> 'expired_credits')::int + (d ->> 'refunded_credits')::int
                                        + (d ->> 'outstanding_credits')::int
     AND (d ->> 'outstanding_credits')::int = 0 AND (d ->> 'overspent_count')::int = 2 AND (d ->> 'overspent_credits')::int = 5
     AND (d ->> 'rejected_count')::int = 1, 'ET13 drinks ' || d::text;
  ASSERT (d ->> 'sold_cents')::int = (d ->> 'redeemed_cents')::int + (d ->> 'expired_cents')::int + (d ->> 'refunded_cents')::int
                                     + (d ->> 'outstanding_cents')::int, 'ET13 cents';
  ASSERT jsonb_array_length(r -> 'exceptions') = 3 AND NOT (r::text LIKE '%e70c-buyer%'), 'ET13 exceptions, no buyer data';
  ASSERT public.exos_audit_export(pg_temp.u('01'), 'event_tokens', 4, pg_temp.u('e1')), 'ET13 export.run';
  ASSERT (SELECT count(*) FROM public.exos_org_audit WHERE org_id = pg_temp.u('01') AND action = 'export.run' AND entity_id = 'event_tokens') = 1,
    'ET13 export logged';
  -- A lost wristband code: a new one, the old one stops working.
  PERFORM pg_temp.act(pg_temp.u('a2'));
  ASSERT pg_temp.st(format('SELECT public.exos_event_token_card_reissue(%L, %L, %L)', pg_temp.u('e1'),
           (SELECT id FROM public.exos_event_token_cards WHERE ticket_id = pg_temp.u('12')), 'lost')) = '22023', 'ET13 a ticket card has no code';
  v_reissue := public.exos_event_token_card_reissue(pg_temp.u('e1'), pg_temp.v('kcard')::uuid, 'guest lost the wristband');
  PERFORM pg_temp.act(pg_temp.u('a3'));
  ASSERT public.exos_event_token_lookup(pg_temp.u('e1'), pg_temp.v('kcode')) ->> 'reason' = 'not-found'
     AND (public.exos_event_token_lookup(pg_temp.u('e1'), v_reissue ->> 'code') ->> 'ok')::boolean, 'ET13 reissued';
  ASSERT (SELECT count(*) FROM public.exos_org_audit WHERE org_id = pg_temp.u('01') AND action = 'token.reissue') = 1, 'ET13 audited';
  RAISE NOTICE 'OK ET13 report: sold = redeemed + expired + refunded + outstanding, exceptions, export.run; a new code replaces a lost one';
END $$;

-- ── ET14 ────────────────────────────────────────────────────────────────────
DO $$
BEGIN
  PERFORM pg_temp.act(pg_temp.u('a3'));
  INSERT INTO public.exos_rate_windows (bucket, window_start, hits)
  VALUES ('tok:door:' || pg_temp.u('a3')::text, date_trunc('minute', now()), 120)
  ON CONFLICT (bucket, window_start) DO UPDATE SET hits = 120;
  ASSERT public.exos_event_token_lookup(pg_temp.u('e1'), 'K-ABCDEFGHJKLMNPQR') ->> 'reason' = 'rate-limited', 'ET14 lookups';
  ASSERT public.exos_event_token_spend(pg_temp.u('e1'), 'K-ABCDEFGHJKLMNPQR', pg_temp.v('drink')::uuid, 1, gen_random_uuid()) ->> 'reason' = 'rate-limited',
    'ET14 spends';
  -- A miss counted (it answered instead of raising).
  ASSERT (SELECT hits FROM public.exos_rate_windows WHERE bucket = 'tok:door:' || pg_temp.u('a3')::text
            AND window_start = date_trunc('minute', now())) = 122, 'ET14 misses count';
  RAISE NOTICE 'OK ET14 rate limits: 120 lookups / spends a minute per member, misses count';
END $$;

ROLLBACK;
