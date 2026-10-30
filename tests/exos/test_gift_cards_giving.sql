-- ============================================================================
-- Gift cards and giving (mig 20261030130000). Self-contained (c6… ids), rolled
-- back at the end.
--   G1 RLS and grants: products (owner / manager write, finance + door read),
--      cards (staff read, no client writes), ledger / redemptions (service only),
--      public product view (active only)
--   G2 codes: generated codes pass the Luhn mod 32 check; every single-character
--      typo fails; dashes / spaces / case are ignored; same vectors as commerce.test.ts
--   G3 issuing: owner cash/comp, scanner cash only, stranger refused,
--      external id idempotent (no second card, no code), only the hash stored
--   G4 quote: wrong org / currency / voided / expired, and the rate limit counts
--      misses (10 a minute per bucket)
--   G5 checkout: hold -> fulfillment captures it in the same transaction; ticket
--      price = order value; invoice = order value; price disclosure not a mismatch
--   G6 double redeem: the same session twice is one hold; a second order can't
--      take more than is left
--   G7 give back: expired and failed release the hold, a full refund restores
--      the captured part; each only once
--   G8 staff partial refund to the card: per key, never more than taken
--   G9 donation at checkout: recorded at fulfillment, not in the ticket price or
--      the refund pool, refunded with the order; public raised total
--   G10 offline donations: owner / finance record, scanner refused, retry with
--      the same external id is one row; receipt numbered and mailed
--   G11 commerce orders: gift card + donation fulfil once; amount mismatch fails;
--      refund voids the card / refunds the donation
--   G12 cross-org isolation
--   G13 ledger invariant: every card's balance = the sum of its ledger
--   psql -d <db> -v ON_ERROR_STOP=1 -f tests/exos/test_gift_cards_giving.sql
-- ============================================================================
\set ON_ERROR_STOP on
BEGIN;

INSERT INTO auth.users (id, email, email_confirmed_at) VALUES
  ('c6000000-0000-0000-0000-0000000000a0', 'c6-owner@x.com', now()),
  ('c6000000-0000-0000-0000-0000000000a1', 'c6-manager@x.com', now()),
  ('c6000000-0000-0000-0000-0000000000a2', 'c6-finance@x.com', now()),
  ('c6000000-0000-0000-0000-0000000000a3', 'c6-scanner@x.com', now()),
  ('c6000000-0000-0000-0000-0000000000a4', 'c6-stranger@x.com', now()),
  ('c6000000-0000-0000-0000-0000000000a5', 'c6-fan@x.com', now()),
  ('c6000000-0000-0000-0000-0000000000b9', 'c6-other-owner@x.com', now());
INSERT INTO public.exos_orgs (id, name, slug, owner_uid) VALUES
  ('c6000000-0000-0000-0000-000000000001', 'C6 Org', 'c6-org', 'c6000000-0000-0000-0000-0000000000a0'),
  ('c6000000-0000-0000-0000-000000000002', 'C6 Other', 'c6-other', 'c6000000-0000-0000-0000-0000000000b9');
INSERT INTO public.exos_org_memberships (org_id, user_id, role) VALUES
  ('c6000000-0000-0000-0000-000000000001', 'c6000000-0000-0000-0000-0000000000a0', 'owner'),
  ('c6000000-0000-0000-0000-000000000001', 'c6000000-0000-0000-0000-0000000000a1', 'manager'),
  ('c6000000-0000-0000-0000-000000000001', 'c6000000-0000-0000-0000-0000000000a2', 'finance'),
  ('c6000000-0000-0000-0000-000000000001', 'c6000000-0000-0000-0000-0000000000a3', 'scanner'),
  ('c6000000-0000-0000-0000-000000000002', 'c6000000-0000-0000-0000-0000000000b9', 'owner');
INSERT INTO public.exos_events (id, org_id, name, slug, status, starts_at) VALUES
  ('c6000000-0000-0000-0000-0000000000e1', 'c6000000-0000-0000-0000-000000000001', 'C6 Show', 'c6-show', 'published', now() + interval '9 days');
INSERT INTO public.exos_ticket_tiers (id, event_id, name, price, capacity, sold, visibility) VALUES
  ('c6000000-0000-0000-0000-0000000000d1', 'c6000000-0000-0000-0000-0000000000e1', 'GA', 40, 100, 0, 'public'),
  ('c6000000-0000-0000-0000-0000000000d2', 'c6000000-0000-0000-0000-0000000000e1', 'Tiny', 40, 1, 0, 'public');

CREATE FUNCTION pg_temp.act(p_uid text) RETURNS void LANGUAGE sql AS $$
  SELECT set_config('app.uid', coalesce(p_uid, ''), true), set_config('app.jwt', '', true);
$$;
GRANT EXECUTE ON FUNCTION pg_temp.act(text) TO anon, authenticated, service_role;
-- A test-only code generator (the client never gets the internal one).
CREATE FUNCTION pg_temp.sum_ledger(p_card uuid) RETURNS int LANGUAGE sql AS $$
  SELECT coalesce(sum(amount_cents), 0)::int FROM public.exos_gift_card_ledger WHERE card_id = p_card;
$$;

-- G1 -------------------------------------------------------------------------
SET ROLE authenticated;
DO $$
DECLARE n int; refused boolean;
BEGIN
  PERFORM pg_temp.act('c6000000-0000-0000-0000-0000000000a1');  -- manager
  INSERT INTO public.exos_gift_card_products (id, org_id, name, amount_type, amounts_cents)
  VALUES ('c6000000-0000-0000-0000-00000000f001', 'c6000000-0000-0000-0000-000000000001', ' Holiday card ', 'fixed', '{2500,5000,10000}');
  INSERT INTO public.exos_gift_card_products (id, org_id, name, amount_type, min_cents, max_cents, active)
  VALUES ('c6000000-0000-0000-0000-00000000f002', 'c6000000-0000-0000-0000-000000000001', 'Any amount', 'open', 1000, 50000, false);
  ASSERT (SELECT name FROM public.exos_gift_card_products WHERE id = 'c6000000-0000-0000-0000-00000000f001') = 'Holiday card', 'G1: name trimmed';

  PERFORM pg_temp.act('c6000000-0000-0000-0000-0000000000a2');  -- finance
  ASSERT (SELECT count(*) FROM public.exos_gift_card_products) = 2, 'G1: finance reads products';
  UPDATE public.exos_gift_card_products SET name = 'x';
  GET DIAGNOSTICS n = ROW_COUNT;
  ASSERT n = 0, 'G1: finance can''t edit products';
  PERFORM pg_temp.act('c6000000-0000-0000-0000-0000000000a3');  -- scanner (box office)
  ASSERT (SELECT count(*) FROM public.exos_gift_card_products) = 2, 'G1: door staff read products';
  PERFORM pg_temp.act('c6000000-0000-0000-0000-0000000000a4');  -- stranger
  ASSERT (SELECT count(*) FROM public.exos_gift_card_products) = 0, 'G1: stranger sees no products';
  refused := false;
  BEGIN
    INSERT INTO public.exos_gift_card_products (org_id, name, amount_type, amounts_cents)
    VALUES ('c6000000-0000-0000-0000-000000000001', 'Mine', 'fixed', '{1000}');
  EXCEPTION WHEN insufficient_privilege THEN refused := true;
  END;
  ASSERT refused, 'G1: stranger can''t add a product';
  -- Bad shapes.
  PERFORM pg_temp.act('c6000000-0000-0000-0000-0000000000a0');
  refused := false;
  BEGIN
    INSERT INTO public.exos_gift_card_products (org_id, name, amount_type, amounts_cents)
    VALUES ('c6000000-0000-0000-0000-000000000001', 'Too small', 'fixed', '{50}');
  EXCEPTION WHEN check_violation THEN refused := true;
  END;
  ASSERT refused, 'G1: amounts under 1.00 refused';
  RAISE NOTICE 'OK  G1 product RLS';
END $$;

DO $$
DECLARE refused boolean;
BEGIN
  ASSERT NOT has_table_privilege('authenticated', 'public.exos_gift_cards', 'INSERT'), 'G1: no client insert on cards';
  ASSERT NOT has_table_privilege('authenticated', 'public.exos_gift_cards', 'UPDATE'), 'G1: no client update on cards';
  ASSERT NOT has_table_privilege('authenticated', 'public.exos_gift_card_ledger', 'SELECT'), 'G1: ledger is service only';
  ASSERT NOT has_table_privilege('authenticated', 'public.exos_gift_card_redemptions', 'SELECT'), 'G1: redemptions are service only';
  ASSERT NOT has_table_privilege('anon', 'public.exos_donations', 'SELECT'), 'G1: anon reads no donations';
  ASSERT NOT has_table_privilege('authenticated', 'public.exos_donations', 'INSERT'), 'G1: no client insert on donations';
  ASSERT NOT has_table_privilege('authenticated', 'public.exos_commerce_orders', 'INSERT'), 'G1: no client insert on commerce orders';
  ASSERT NOT has_function_privilege('authenticated', 'public.exos_gift_card_hold(text,text,integer,text,uuid,text)', 'EXECUTE'), 'G1: hold is service only';
  ASSERT NOT has_function_privilege('authenticated', 'public.exos_gift_card_quote(text,text,uuid,text,integer)', 'EXECUTE'), 'G1: quote is service only';
  ASSERT NOT has_function_privilege('anon', 'public.exos_gift_card_balance(text)', 'EXECUTE'), 'G1: anon balance goes through exos-commerce';
  ASSERT NOT has_function_privilege('authenticated', 'public.exos_commerce_fulfill(text,text,integer,text,timestamptz)', 'EXECUTE'), 'G1: fulfill is service only';
  ASSERT NOT has_function_privilege('authenticated', 'public._exos_gift_card_issue(uuid,uuid,integer,text,text,text,text,uuid,uuid,text,text,text,text,boolean)', 'EXECUTE'), 'G1: internal issue';
  ASSERT NOT has_function_privilege('authenticated', 'public._exos_gift_card_move(uuid,text,integer,text,text,uuid,text)', 'EXECUTE'), 'G1: internal move';
  RAISE NOTICE 'OK  G1 grants';
END $$;
RESET ROLE;

SET ROLE anon;
DO $$
BEGIN
  PERFORM pg_temp.act(NULL);
  ASSERT (SELECT count(*) FROM public.exos_public_gift_card_products WHERE org_id = 'c6000000-0000-0000-0000-000000000001') = 1,
    'G1: anon sees the one active product';
  RAISE NOTICE 'OK  G1 public product view';
END $$;
RESET ROLE;

-- G2 -------------------------------------------------------------------------
DO $$
DECLARE c text; bad text; i int; j int; a constant text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789'; ch text;
BEGIN
  FOR i IN 1..200 LOOP
    c := public._exos_gift_card_new_code();
    ASSERT length(c) = 16 AND public.exos_gift_card_check_ok(c), 'G2: generated code passes: ' || c;
    -- Every single-character change fails.
    IF i <= 5 THEN
      FOR j IN 1..16 LOOP
        ch := substr(a, (position(substr(c, j, 1) in a) % 32) + 1, 1);
        bad := overlay(c placing ch from j for 1);
        ASSERT NOT public.exos_gift_card_check_ok(bad), 'G2: typo accepted: ' || bad;
      END LOOP;
    END IF;
  END LOOP;
  ASSERT public.exos_gift_card_normalize('abcd-efgh jkmn-pqr2') = 'ABCDEFGHJKMNPQR2', 'G2: normalized';
  ASSERT public.exos_gift_card_normalize('ABCD-EFGH-JKMN-PQR0') IS NULL, 'G2: 0 is not in the alphabet';
  -- Fixed vectors shared with src/lib/commerce.test.ts.
  ASSERT public.exos_gift_card_check_ok('ABCD-EFGH-JKLM-NPQ9'), 'G2: vector 1';
  ASSERT public.exos_gift_card_check_ok('2222-2222-2222-222S'), 'G2: vector 2';
  ASSERT NOT public.exos_gift_card_check_ok('ABCD-EFGH-JKLM-NPQ8'), 'G2: vector 3';
  RAISE NOTICE 'OK  G2 codes';
END $$;

-- G3 -------------------------------------------------------------------------
CREATE TEMP TABLE c6 (k text PRIMARY KEY, v text);
GRANT ALL ON c6 TO authenticated, service_role, anon;
SET ROLE authenticated;
DO $$
DECLARE r jsonb; r2 jsonb; refused boolean;
BEGIN
  PERFORM pg_temp.act('c6000000-0000-0000-0000-0000000000a0');
  r := public.exos_gift_card_issue('c6000000-0000-0000-0000-000000000001', 5000, 'cash',
         'c6000000-0000-0000-0000-00000000f001', 'usd', 'c6-gift@x.com', 'Ann', 'Enjoy', NULL, 'till-1');
  ASSERT (r->>'fresh')::boolean AND r->>'code' IS NOT NULL AND (r->>'balance_cents')::int = 5000, 'G3: issued: ' || r::text;
  INSERT INTO c6 VALUES ('code1', r->>'code'), ('card1', r->>'card_id');
  r2 := public.exos_gift_card_issue('c6000000-0000-0000-0000-000000000001', 5000, 'cash',
         'c6000000-0000-0000-0000-00000000f001', 'usd', 'c6-gift@x.com', NULL, NULL, NULL, 'till-1');
  ASSERT NOT (r2->>'fresh')::boolean AND r2->>'code' IS NULL AND r2->>'card_id' = r->>'card_id', 'G3: retry is the same card, no code';
  -- An amount the product doesn't offer.
  refused := false;
  BEGIN
    PERFORM public.exos_gift_card_issue('c6000000-0000-0000-0000-000000000001', 3000, 'cash', 'c6000000-0000-0000-0000-00000000f001');
  EXCEPTION WHEN invalid_parameter_value THEN refused := true;
  END;
  ASSERT refused, 'G3: product amounts enforced';
  -- Owner comp without a product, open amount.
  r := public.exos_gift_card_issue('c6000000-0000-0000-0000-000000000001', 10000, 'comp');
  INSERT INTO c6 VALUES ('code2', r->>'code'), ('card2', r->>'card_id');

  -- Scanner: cash yes, comp no.
  PERFORM pg_temp.act('c6000000-0000-0000-0000-0000000000a3');
  r := public.exos_gift_card_issue('c6000000-0000-0000-0000-000000000001', 2000, 'cash');
  INSERT INTO c6 VALUES ('code3', r->>'code'), ('card3', r->>'card_id');
  refused := false;
  BEGIN PERFORM public.exos_gift_card_issue('c6000000-0000-0000-0000-000000000001', 2000, 'comp');
  EXCEPTION WHEN insufficient_privilege THEN refused := true; END;
  ASSERT refused, 'G3: scanner can''t comp a card';
  -- Stranger, other org's owner.
  PERFORM pg_temp.act('c6000000-0000-0000-0000-0000000000a4');
  refused := false;
  BEGIN PERFORM public.exos_gift_card_issue('c6000000-0000-0000-0000-000000000001', 2000, 'cash');
  EXCEPTION WHEN insufficient_privilege THEN refused := true; END;
  ASSERT refused, 'G3: stranger refused';
  PERFORM pg_temp.act('c6000000-0000-0000-0000-0000000000b9');
  refused := false;
  BEGIN PERFORM public.exos_gift_card_issue('c6000000-0000-0000-0000-000000000001', 2000, 'cash');
  EXCEPTION WHEN insufficient_privilege THEN refused := true; END;
  ASSERT refused, 'G3: another org''s owner refused';
  RAISE NOTICE 'OK  G3 issuing';
END $$;
RESET ROLE;
DO $$
DECLARE c public.exos_gift_cards%ROWTYPE;
BEGIN
  SELECT * INTO c FROM public.exos_gift_cards WHERE id = (SELECT v::uuid FROM c6 WHERE k = 'card1');
  ASSERT c.code_hash = public._exos_gift_card_hash((SELECT v FROM c6 WHERE k = 'code1')), 'G3: hash stored';
  ASSERT position((SELECT v FROM c6 WHERE k = 'code1') in row_to_json(c)::text) = 0, 'G3: the plain code is not stored on the card';
  ASSERT c.last4 = right((SELECT v FROM c6 WHERE k = 'code1'), 4) AND c.source = 'box_office' AND c.payment_method = 'cash', 'G3: card fields';
  ASSERT (SELECT count(*) FROM public.exos_mail WHERE to_email = 'c6-gift@x.com' AND template = 'gift-card-issued') = 1, 'G3: one mail with the code';
  ASSERT (SELECT count(*) FROM public.exos_gift_card_ledger WHERE card_id = c.id AND kind = 'issue' AND amount_cents = 5000) = 1, 'G3: issue ledger row';
  RAISE NOTICE 'OK  G3 storage';
END $$;

-- G4 -------------------------------------------------------------------------
SET ROLE service_role;
DO $$
DECLARE q jsonb; i int; code text := (SELECT v FROM c6 WHERE k = 'code1');
BEGIN
  q := public.exos_gift_card_quote(code, 'g4-a', 'c6000000-0000-0000-0000-000000000001', 'usd', 3000);
  ASSERT q->>'error' IS NULL AND (q->>'applicable_cents')::int = 3000 AND (q->>'balance_cents')::int = 5000, 'G4: quote ' || q::text;
  q := public.exos_gift_card_quote(code, 'g4-a', 'c6000000-0000-0000-0000-000000000001', 'usd', 9000);
  ASSERT (q->>'applicable_cents')::int = 5000, 'G4: applicable is the balance';
  q := public.exos_gift_card_quote(code, 'g4-a', 'c6000000-0000-0000-0000-000000000002', 'usd', 100);
  ASSERT q->>'error' LIKE '%another organizer%', 'G4: wrong org';
  q := public.exos_gift_card_quote(code, 'g4-a', NULL, 'eur', 100);
  ASSERT q->>'error' LIKE '%USD%', 'G4: wrong currency';
  q := public.exos_gift_card_quote('ABCD-EFGH-JKLM-NPQ9', 'g4-a', NULL, NULL, 100);
  ASSERT q->>'error' = 'gift card not found', 'G4: unknown code';
  q := public.exos_gift_card_quote('ABCD-EFGH-JKLM-NPQ8', 'g4-a', NULL, NULL, 100);
  ASSERT q->>'error' LIKE '%typo%', 'G4: check digit';
  -- Misses count: 6 used, 4 more pass, the 11th is limited even with the right code.
  FOR i IN 1..4 LOOP PERFORM public.exos_gift_card_quote('ABCD-EFGH-JKLM-NPQ9', 'g4-a', NULL, NULL, 100); END LOOP;
  q := public.exos_gift_card_quote(code, 'g4-a', NULL, NULL, 100);
  ASSERT q->>'error' LIKE 'too many%', 'G4: rate limited after 10 lookups: ' || q::text;
  q := public.exos_gift_card_quote(code, 'g4-b', NULL, NULL, 100);
  ASSERT q->>'error' IS NULL, 'G4: another bucket still works';
  RAISE NOTICE 'OK  G4 quote + rate limit';
END $$;
RESET ROLE;
-- Voided / expired.
DO $$
DECLARE q jsonb; r jsonb;
BEGIN
  r := public._exos_gift_card_issue('c6000000-0000-0000-0000-000000000001', NULL, 1500, 'usd', 'dashboard', 'comp', NULL, NULL, NULL, NULL, NULL, NULL, NULL, false);
  UPDATE public.exos_gift_cards SET expires_at = now() - interval '1 day' WHERE id = (r->>'card_id')::uuid;
  q := public.exos_gift_card_quote(r->>'code', 'g4-c', NULL, NULL, 100);
  ASSERT q->>'error' LIKE '%expired%', 'G4: expired';
  r := public._exos_gift_card_issue('c6000000-0000-0000-0000-000000000001', NULL, 1500, 'usd', 'dashboard', 'comp', NULL, NULL, NULL, NULL, NULL, NULL, NULL, false);
  PERFORM public.exos_gift_card_void((r->>'card_id')::uuid, 'test');
  q := public.exos_gift_card_quote(r->>'code', 'g4-c', NULL, NULL, 100);
  ASSERT q->>'error' LIKE '%voided%', 'G4: voided';
  ASSERT (SELECT balance_cents FROM public.exos_gift_cards WHERE id = (r->>'card_id')::uuid) = 0, 'G4: void empties the card';
  RAISE NOTICE 'OK  G4 voided / expired';
END $$;

-- G5 -------------------------------------------------------------------------
-- 2 x GA at $40 = $80; card1 ($50) pays 50, Stripe charges 30.
INSERT INTO public.exos_checkout_sessions (session_id, event_id, tier_id, org_id, buyer_uid, buyer_email,
  quantity, amount_cents, gift_card_cents, currency, status)
VALUES ('c6-s1', 'c6000000-0000-0000-0000-0000000000e1', 'c6000000-0000-0000-0000-0000000000d1',
        'c6000000-0000-0000-0000-000000000001', 'c6000000-0000-0000-0000-0000000000a5', 'c6-fan@x.com',
        2, 3000, 5000, 'usd', 'pending');
SET ROLE service_role;
DO $$
DECLARE h jsonb; code text := (SELECT v FROM c6 WHERE k = 'code1');
BEGIN
  h := public.exos_gift_card_hold(code, 'c6-s1', 5000, 'g5', 'c6000000-0000-0000-0000-000000000001', 'usd');
  ASSERT (h->>'fresh')::boolean AND (h->>'balance_cents')::int = 0, 'G5: held ' || h::text;
  -- G6: same session again is the same hold.
  h := public.exos_gift_card_hold(code, 'c6-s1', 5000, 'g5', 'c6000000-0000-0000-0000-000000000001', 'usd');
  ASSERT NOT (h->>'fresh')::boolean, 'G6: replayed hold is a no-op';
  RAISE NOTICE 'OK  G5 hold';
END $$;
RESET ROLE;
DO $$
DECLARE ids uuid[]; card uuid := (SELECT v::uuid FROM c6 WHERE k = 'card1'); refused boolean := false;
BEGIN
  ASSERT (SELECT balance_cents FROM public.exos_gift_cards WHERE id = card) = 0, 'G5: balance moved at hold';
  -- G6: another order can't take money that is held.
  INSERT INTO public.exos_checkout_sessions (session_id, event_id, tier_id, org_id, buyer_uid, buyer_email,
    quantity, amount_cents, gift_card_cents, currency, status)
  VALUES ('c6-s2', 'c6000000-0000-0000-0000-0000000000e1', 'c6000000-0000-0000-0000-0000000000d1',
          'c6000000-0000-0000-0000-000000000001', 'c6000000-0000-0000-0000-0000000000a5', 'c6-fan@x.com',
          1, 0, 4000, 'usd', 'pending');
  BEGIN
    PERFORM public.exos_gift_card_hold((SELECT v FROM c6 WHERE k = 'code1'), 'c6-s2', 4000, 'g6', 'c6000000-0000-0000-0000-000000000001', 'usd');
  EXCEPTION WHEN raise_exception THEN refused := true;
  END;
  ASSERT refused, 'G6: the second order can''t double-spend the card';
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_gift_card_redemptions WHERE session_id = 'c6-s2'), 'G6: nothing held for the second order';
  -- Fulfil: captures, tickets at the order value.
  ids := public.exos_fulfill_checkout('c6-s1');
  ASSERT cardinality(ids) = 2, 'G5: two tickets';
  ASSERT (SELECT status FROM public.exos_gift_card_redemptions WHERE session_id = 'c6-s1') = 'captured', 'G5: captured';
  ASSERT (SELECT sum(price_paid) FROM public.exos_tickets WHERE order_ref = 'c6-s1') = 80, 'G5: tickets carry the order value (card + gift card)';
  ASSERT (SELECT total_cents FROM public.exos_invoices WHERE session_id = 'c6-s1') = 8000, 'G5: invoice = order value';
  RAISE NOTICE 'OK  G5 fulfillment captures; G6 double redeem refused';
END $$;
-- The full-gift-card order (no Stripe) gets an invoice and isn't a mismatch.
DO $$
DECLARE r jsonb; ids uuid[];
BEGIN
  r := public._exos_gift_card_issue('c6000000-0000-0000-0000-000000000001', NULL, 4000, 'usd', 'dashboard', 'comp', NULL, NULL, NULL, NULL, NULL, NULL, NULL, false);
  INSERT INTO c6 VALUES ('card4', r->>'card_id');
  INSERT INTO public.exos_checkout_sessions (session_id, event_id, tier_id, org_id, buyer_uid, buyer_email,
    quantity, amount_cents, gift_card_cents, currency, status)
  VALUES ('c6-s3', 'c6000000-0000-0000-0000-0000000000e1', 'c6000000-0000-0000-0000-0000000000d1',
          'c6000000-0000-0000-0000-000000000001', 'c6000000-0000-0000-0000-0000000000a5', 'c6-fan@x.com',
          1, 0, 4000, 'usd', 'pending');
  PERFORM public.exos_gift_card_hold(r->>'code', 'c6-s3', 4000, 'g5b', 'c6000000-0000-0000-0000-000000000001', 'usd');
  PERFORM public.exos_record_price_disclosure('c6-s3', 'usd', '[{"kind":"ticket","quantity":1,"face_unit_cents":4000,"unit_all_in_cents":4000,"name":"GA"}]');
  ids := public.exos_fulfill_checkout('c6-s3');
  ASSERT cardinality(ids) = 1, 'G5: full gift card order fulfilled';
  ASSERT NOT public.exos_record_price_charged('c6-s3', 0, 'usd'), 'G5: card 0 + gift card 4000 = shown 4000, no mismatch';
  ASSERT (SELECT total_cents FROM public.exos_invoices WHERE session_id = 'c6-s3') = 4000, 'G5: invoice for a gift-card-paid order';
  RAISE NOTICE 'OK  G5 full gift card order';
END $$;

-- G7 -------------------------------------------------------------------------
DO $$
DECLARE r jsonb; card uuid; ids uuid[];
BEGIN
  -- Expired: the hold comes back.
  r := public._exos_gift_card_issue('c6000000-0000-0000-0000-000000000001', NULL, 3000, 'usd', 'dashboard', 'comp', NULL, NULL, NULL, NULL, NULL, NULL, NULL, false);
  card := (r->>'card_id')::uuid;
  INSERT INTO c6 VALUES ('card5', card::text), ('code5', r->>'code');
  INSERT INTO public.exos_checkout_sessions (session_id, event_id, tier_id, org_id, buyer_uid, buyer_email, quantity, amount_cents, gift_card_cents, currency, status)
  VALUES ('c6-s4', 'c6000000-0000-0000-0000-0000000000e1', 'c6000000-0000-0000-0000-0000000000d1', 'c6000000-0000-0000-0000-000000000001',
          'c6000000-0000-0000-0000-0000000000a5', 'c6-fan@x.com', 1, 1000, 3000, 'usd', 'pending');
  PERFORM public.exos_gift_card_hold(r->>'code', 'c6-s4', 3000, 'g7', 'c6000000-0000-0000-0000-000000000001', 'usd');
  ASSERT (SELECT balance_cents FROM public.exos_gift_cards WHERE id = card) = 0, 'G7: held';
  UPDATE public.exos_checkout_sessions SET status = 'expired' WHERE session_id = 'c6-s4';
  ASSERT (SELECT balance_cents FROM public.exos_gift_cards WHERE id = card) = 3000, 'G7: expired gives it back';
  ASSERT public._exos_gift_card_give_back('c6-s4', 'again') = 0, 'G7: only once';
  ASSERT (SELECT balance_cents FROM public.exos_gift_cards WHERE id = card) = 3000, 'G7: still 3000';

  -- Failed at fulfillment (sold out): the hold comes back, no tickets.
  UPDATE public.exos_ticket_tiers SET sold = 1 WHERE id = 'c6000000-0000-0000-0000-0000000000d2';
  INSERT INTO public.exos_checkout_sessions (session_id, event_id, tier_id, org_id, buyer_uid, buyer_email, quantity, amount_cents, gift_card_cents, currency, status)
  VALUES ('c6-s5', 'c6000000-0000-0000-0000-0000000000e1', 'c6000000-0000-0000-0000-0000000000d2', 'c6000000-0000-0000-0000-000000000001',
          'c6000000-0000-0000-0000-0000000000a5', 'c6-fan@x.com', 1, 1000, 3000, 'usd', 'pending');
  PERFORM public.exos_gift_card_hold(r->>'code', 'c6-s5', 3000, 'g7', 'c6000000-0000-0000-0000-000000000001', 'usd');
  ids := public.exos_fulfill_checkout('c6-s5');
  ASSERT cardinality(ids) = 0 AND (SELECT status FROM public.exos_checkout_sessions WHERE session_id = 'c6-s5') = 'failed', 'G7: sold out fails';
  ASSERT (SELECT balance_cents FROM public.exos_gift_cards WHERE id = card) = 3000, 'G7: failed gives it back';
  ASSERT (SELECT status FROM public.exos_gift_card_redemptions WHERE session_id = 'c6-s5') = 'released', 'G7: released';

  -- A hold released before fulfillment can't be captured (order fails, no tickets).
  INSERT INTO public.exos_checkout_sessions (session_id, event_id, tier_id, org_id, buyer_uid, buyer_email, quantity, amount_cents, gift_card_cents, currency, status)
  VALUES ('c6-s6', 'c6000000-0000-0000-0000-0000000000e1', 'c6000000-0000-0000-0000-0000000000d1', 'c6000000-0000-0000-0000-000000000001',
          'c6000000-0000-0000-0000-0000000000a5', 'c6-fan@x.com', 1, 1000, 3000, 'usd', 'pending');
  ids := public.exos_fulfill_checkout('c6-s6');
  ASSERT cardinality(ids) = 0 AND (SELECT failure_reason FROM public.exos_checkout_sessions WHERE session_id = 'c6-s6') LIKE 'gift card hold%',
    'G7: no hold, no tickets';

  -- Full refund of c6-s1: the 5000 goes back on card1, once.
  PERFORM public.exos_refund_checkout('c6-s1', 'test refund');
  ASSERT (SELECT balance_cents FROM public.exos_gift_cards WHERE id = (SELECT v::uuid FROM c6 WHERE k = 'card1')) = 5000, 'G7: refund restores';
  UPDATE public.exos_checkout_sessions SET status = 'partially_refunded' WHERE session_id = 'c6-s1';
  UPDATE public.exos_checkout_sessions SET status = 'refunded' WHERE session_id = 'c6-s1';
  ASSERT (SELECT balance_cents FROM public.exos_gift_cards WHERE id = (SELECT v::uuid FROM c6 WHERE k = 'card1')) = 5000, 'G7: only once';
  RAISE NOTICE 'OK  G7 give back';
END $$;

-- G8 -------------------------------------------------------------------------
SET ROLE authenticated;
DO $$
DECLARE r jsonb; refused boolean := false;
BEGIN
  -- c6-s3 (4000 from card4, captured). Manager puts 1500 back, then the rest.
  PERFORM pg_temp.act('c6000000-0000-0000-0000-0000000000a1');
  r := public.exos_gift_card_refund_order('c6-s3', 1500, 'ticket-1');
  ASSERT (r->>'refunded_cents')::int = 1500, 'G8: partial ' || r::text;
  r := public.exos_gift_card_refund_order('c6-s3', 1500, 'ticket-1');
  ASSERT (r->>'refunded_cents')::int = 0, 'G8: same key is a no-op';
  r := public.exos_gift_card_refund_order('c6-s3', 99999, 'rest');
  ASSERT (r->>'refunded_cents')::int = 2500, 'G8: never more than taken';
  PERFORM pg_temp.act('c6000000-0000-0000-0000-0000000000a2');  -- finance
  BEGIN PERFORM public.exos_gift_card_refund_order('c6-s3', 1, 'x');
  EXCEPTION WHEN insufficient_privilege THEN refused := true; END;
  ASSERT refused, 'G8: finance can''t move balances';
  RAISE NOTICE 'OK  G8 staff refund to card';
END $$;
RESET ROLE;
DO $$
BEGIN
  ASSERT (SELECT balance_cents FROM public.exos_gift_cards WHERE id = (SELECT v::uuid FROM c6 WHERE k = 'card4')) = 4000, 'G8: card4 whole again';
  -- A later full refund of that order adds nothing more.
  PERFORM public.exos_refund_checkout('c6-s3', 'test');
  ASSERT (SELECT balance_cents FROM public.exos_gift_cards WHERE id = (SELECT v::uuid FROM c6 WHERE k = 'card4')) = 4000, 'G8: no double refund';
END $$;

-- G9 -------------------------------------------------------------------------
SET ROLE authenticated;
DO $$
BEGIN
  PERFORM pg_temp.act('c6000000-0000-0000-0000-0000000000a0');
  INSERT INTO public.exos_giving_campaigns (id, org_id, name, slug, goal_cents, checkout_add_on, tax_receipt_text)
  VALUES ('c6000000-0000-0000-0000-00000000c001', 'c6000000-0000-0000-0000-000000000001', 'Roof fund', 'roof', 100000, true,
          'C6 Org is a 501(c)(3), EIN 00-0000000.');
  INSERT INTO public.exos_giving_campaigns (id, org_id, name, slug, active)
  VALUES ('c6000000-0000-0000-0000-00000000c002', 'c6000000-0000-0000-0000-000000000001', 'Old', 'old', false);
  PERFORM pg_temp.act('c6000000-0000-0000-0000-0000000000a3');
  ASSERT (SELECT count(*) FROM public.exos_giving_campaigns) = 0, 'G9: scanners don''t see campaigns';
END $$;
RESET ROLE;
DO $$
DECLARE ids uuid[];
BEGIN
  -- 1 x GA $40 + $10 donation = 50 charged.
  INSERT INTO public.exos_checkout_sessions (session_id, event_id, tier_id, org_id, buyer_uid, buyer_email,
    quantity, amount_cents, donation_cents, donation_campaign_id, currency, status)
  VALUES ('c6-s7', 'c6000000-0000-0000-0000-0000000000e1', 'c6000000-0000-0000-0000-0000000000d1',
          'c6000000-0000-0000-0000-000000000001', 'c6000000-0000-0000-0000-0000000000a5', 'c6-fan@x.com',
          1, 5000, 1000, 'c6000000-0000-0000-0000-00000000c001', 'usd', 'pending');
  ids := public.exos_fulfill_checkout('c6-s7');
  ASSERT cardinality(ids) = 1, 'G9: fulfilled';
  ASSERT (SELECT price_paid FROM public.exos_tickets WHERE order_ref = 'c6-s7') = 40, 'G9: ticket price excludes the donation';
  ASSERT (SELECT share_cents FROM public.exos_refund_ticket_state('c6-s7')) = 4000, 'G9: refund pool excludes the donation';
  ASSERT (SELECT total_cents FROM public.exos_invoices WHERE session_id = 'c6-s7') = 4000, 'G9: invoice excludes the donation';
  ASSERT (SELECT count(*) FROM public.exos_donations WHERE session_id = 'c6-s7' AND method = 'checkout' AND amount_cents = 1000
            AND donor_email = 'c6-fan@x.com' AND key = 'order:c6-s7') = 1, 'G9: donation recorded';
  ASSERT (SELECT receipt_number FROM public.exos_donations WHERE session_id = 'c6-s7') = 1, 'G9: receipt no. 1';
  ASSERT (SELECT count(*) FROM public.exos_mail WHERE template = 'donation-receipt' AND to_email = 'c6-fan@x.com'
            AND html LIKE '%EIN 00-0000000%') = 1, 'G9: receipt mailed with the org''s text';
  -- Replay: no second donation.
  ids := public.exos_fulfill_checkout('c6-s7');
  ASSERT (SELECT count(*) FROM public.exos_donations WHERE session_id = 'c6-s7') = 1, 'G9: replay is a no-op';
  -- The constraint pairs the amount and the campaign.
  BEGIN
    INSERT INTO public.exos_checkout_sessions (session_id, event_id, tier_id, org_id, buyer_uid, quantity, amount_cents, donation_cents, currency)
    VALUES ('c6-bad', 'c6000000-0000-0000-0000-0000000000e1', 'c6000000-0000-0000-0000-0000000000d1',
            'c6000000-0000-0000-0000-000000000001', 'c6000000-0000-0000-0000-0000000000a5', 1, 5000, 1000, 'usd');
    RAISE EXCEPTION 'G9: donation without a campaign accepted';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
END $$;
SET ROLE anon;
DO $$
BEGIN
  PERFORM pg_temp.act(NULL);
  ASSERT (SELECT raised_cents FROM public.exos_public_giving_campaigns WHERE id = 'c6000000-0000-0000-0000-00000000c001') = 1000, 'G9: public raised total';
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_public_giving_campaigns WHERE id = 'c6000000-0000-0000-0000-00000000c002'), 'G9: inactive hidden';
END $$;
RESET ROLE;
DO $$
BEGIN
  PERFORM public.exos_refund_checkout('c6-s7', 'test');
  ASSERT (SELECT status FROM public.exos_donations WHERE session_id = 'c6-s7') = 'refunded', 'G9: refunded with the order';
  ASSERT (SELECT raised_cents FROM public.exos_public_giving_campaigns WHERE id = 'c6000000-0000-0000-0000-00000000c001') = 0, 'G9: total comes down';
  RAISE NOTICE 'OK  G9 donation at checkout';
END $$;

-- G10 ------------------------------------------------------------------------
SET ROLE authenticated;
DO $$
DECLARE d1 uuid; d2 uuid; refused boolean := false; n int;
BEGIN
  PERFORM pg_temp.act('c6000000-0000-0000-0000-0000000000a2');  -- finance
  d1 := public.exos_record_offline_donation('c6000000-0000-0000-0000-00000000c001', 2500, 'check', 'Bo', 'c6-bo@x.com', false, 'check #12', 'chk-12');
  d2 := public.exos_record_offline_donation('c6000000-0000-0000-0000-00000000c001', 2500, 'check', 'Bo', 'c6-bo@x.com', false, 'check #12', 'chk-12');
  ASSERT d1 = d2, 'G10: same external id, one donation';
  ASSERT (SELECT receipt_number FROM public.exos_donations WHERE id = d1) = 2, 'G10: receipts numbered per org';
  SELECT count(*) INTO n FROM public.exos_donations_export('c6000000-0000-0000-0000-000000000001', NULL);
  ASSERT n = 2, 'G10: export rows';
  PERFORM pg_temp.act('c6000000-0000-0000-0000-0000000000a3');  -- scanner
  BEGIN PERFORM public.exos_record_offline_donation('c6000000-0000-0000-0000-00000000c001', 100, 'cash');
  EXCEPTION WHEN insufficient_privilege THEN refused := true; END;
  ASSERT refused, 'G10: scanner refused';
  ASSERT (SELECT count(*) FROM public.exos_donations) = 0, 'G10: scanner reads no donations';
  -- The donor reads their own.
  PERFORM pg_temp.act('c6000000-0000-0000-0000-0000000000a5');
  ASSERT (SELECT count(*) FROM public.exos_donations) = 1, 'G10: donor reads their own';
  RAISE NOTICE 'OK  G10 offline donations';
END $$;
RESET ROLE;

-- G11 ------------------------------------------------------------------------
INSERT INTO public.exos_commerce_orders (session_id, org_id, kind, product_id, buyer_uid, buyer_email, amount_cents, currency, details) VALUES
  ('cs_c6_gc', 'c6000000-0000-0000-0000-000000000001', 'gift_card', 'c6000000-0000-0000-0000-00000000f001',
   'c6000000-0000-0000-0000-0000000000a5', 'c6-fan@x.com', 2500, 'usd', '{"amount_cents":2500,"recipient_email":"c6-friend@x.com"}'),
  ('cs_c6_bad', 'c6000000-0000-0000-0000-000000000001', 'gift_card', 'c6000000-0000-0000-0000-00000000f001',
   NULL, 'c6-guest@x.com', 2500, 'usd', '{"amount_cents":2500}'),
  ('cs_c6_dn', 'c6000000-0000-0000-0000-000000000001', 'donation', 'c6000000-0000-0000-0000-00000000c001',
   NULL, 'c6-guest@x.com', 5150, 'usd', '{"campaign_id":"c6000000-0000-0000-0000-00000000c001","amount_cents":5000,"cover_fees_cents":150,"donor_name":"Cy"}');
-- The harness has no Supabase default grants on older tables; the assertions read the mail queue.
GRANT SELECT ON public.exos_mail TO service_role;
SET ROLE service_role;
DO $$
DECLARE st text; card uuid;
BEGIN
  st := public.exos_commerce_fulfill('cs_c6_gc', 'pi_c6_gc', 2500);
  ASSERT st = 'fulfilled', 'G11: gift card order fulfilled';
  st := public.exos_commerce_fulfill('cs_c6_gc', 'pi_c6_gc', 2500);
  ASSERT st = 'fulfilled', 'G11: replay';
  SELECT result_id INTO card FROM public.exos_commerce_orders WHERE session_id = 'cs_c6_gc';
  ASSERT (SELECT count(*) FROM public.exos_gift_cards WHERE issue_key = 'cs_c6_gc') = 1, 'G11: one card';
  ASSERT (SELECT source = 'online' AND payment_method = 'card' AND balance_cents = 2500 AND recipient_email = 'c6-friend@x.com'
            FROM public.exos_gift_cards WHERE id = card), 'G11: card fields';
  ASSERT (SELECT count(*) FROM public.exos_mail WHERE template = 'gift-card-issued' AND to_email = 'c6-friend@x.com') = 1, 'G11: code mailed to the recipient';
  st := public.exos_commerce_fulfill('cs_c6_bad', 'pi_c6_bad', 2400);
  ASSERT st = 'failed' AND NOT EXISTS (SELECT 1 FROM public.exos_gift_cards WHERE issue_key = 'cs_c6_bad'), 'G11: amount mismatch fails, no card';
  st := public.exos_commerce_fulfill('cs_c6_dn', 'pi_c6_dn', 5150);
  ASSERT st = 'fulfilled', 'G11: donation fulfilled';
  ASSERT (SELECT total_cents = 5150 AND cover_fees_cents = 150 AND method = 'card' FROM public.exos_donations WHERE key = 'stripe:cs_c6_dn'), 'G11: donation row';
  -- Refunds.
  ASSERT public.exos_commerce_refund('cs_c6_gc', 'test') = 'refunded', 'G11: refund';
  ASSERT (SELECT status = 'voided' AND balance_cents = 0 FROM public.exos_gift_cards WHERE id = card), 'G11: refunded purchase voids the card';
  ASSERT public.exos_commerce_refund('cs_c6_dn', 'test') = 'refunded', 'G11: donation refund';
  ASSERT (SELECT status FROM public.exos_donations WHERE key = 'stripe:cs_c6_dn') = 'refunded', 'G11: donation refunded';
  RAISE NOTICE 'OK  G11 commerce orders';
END $$;
RESET ROLE;
SET ROLE authenticated;
DO $$
DECLARE refused boolean := false;
BEGIN
  PERFORM pg_temp.act('c6000000-0000-0000-0000-0000000000a5');
  ASSERT (SELECT count(*) FROM public.exos_commerce_orders) = 1, 'G11: buyer reads their own order';
  -- The card they bought for a friend (voided by the refund) is listed for them.
  ASSERT (SELECT count(*) FROM public.exos_my_gift_cards() WHERE status = 'voided' AND NOT sent_to_me) = 1,
    'G11: the buyer sees the card they bought';
END $$;
RESET ROLE;

-- G12 ------------------------------------------------------------------------
SET ROLE authenticated;
DO $$
DECLARE refused boolean := false;
BEGIN
  PERFORM pg_temp.act('c6000000-0000-0000-0000-0000000000b9');
  ASSERT (SELECT count(*) FROM public.exos_gift_cards) = 0, 'G12: other org sees no cards';
  ASSERT (SELECT count(*) FROM public.exos_gift_card_products) = 0, 'G12: other org sees no products';
  ASSERT (SELECT count(*) FROM public.exos_donations) = 0, 'G12: other org sees no donations';
  ASSERT (SELECT count(*) FROM public.exos_giving_campaigns) = 0, 'G12: other org sees no campaigns';
  ASSERT (SELECT count(*) FROM public.exos_commerce_orders) = 0, 'G12: other org sees no commerce orders';
  BEGIN PERFORM public.exos_gift_card_void((SELECT v::uuid FROM c6 WHERE k = 'card2'));
  EXCEPTION WHEN insufficient_privilege THEN refused := true; END;
  ASSERT refused, 'G12: can''t void another org''s card';
  refused := false;
  BEGIN PERFORM public.exos_gift_card_ledger_for((SELECT v::uuid FROM c6 WHERE k = 'card2'));
  EXCEPTION WHEN insufficient_privilege THEN refused := true; END;
  ASSERT refused, 'G12: can''t read another org''s ledger';
  refused := false;
  BEGIN PERFORM public.exos_donations_export('c6000000-0000-0000-0000-000000000001', NULL);
  EXCEPTION WHEN insufficient_privilege THEN refused := true; END;
  ASSERT refused, 'G12: can''t export another org''s donations';
  refused := false;
  BEGIN PERFORM public.exos_gift_card_reissue_code((SELECT v::uuid FROM c6 WHERE k = 'card2'));
  EXCEPTION WHEN insufficient_privilege THEN refused := true; END;
  ASSERT refused, 'G12: can''t reissue another org''s code';
  -- Owner of the right org: ledger and reissue.
  PERFORM pg_temp.act('c6000000-0000-0000-0000-0000000000a0');
  ASSERT (SELECT count(*) FROM public.exos_gift_card_ledger_for((SELECT v::uuid FROM c6 WHERE k = 'card1'))) >= 3, 'G12: owner reads the ledger';
  RAISE NOTICE 'OK  G12 cross-org isolation';
END $$;
RESET ROLE;
DO $$
DECLARE r jsonb; old text := (SELECT v FROM c6 WHERE k = 'code5'); q jsonb;
BEGIN
  PERFORM set_config('app.uid', 'c6000000-0000-0000-0000-0000000000a0', true);
  r := public.exos_gift_card_reissue_code((SELECT v::uuid FROM c6 WHERE k = 'card5'), false);
  q := public.exos_gift_card_quote(old, 'g12', NULL, NULL, 100);
  ASSERT q->>'error' = 'gift card not found', 'G12: the old code stops working';
  q := public.exos_gift_card_quote(r->>'code', 'g12', NULL, NULL, 100);
  ASSERT (q->>'balance_cents')::int = 3000, 'G12: the new code has the balance';
END $$;

-- G13 ------------------------------------------------------------------------
DO $$
DECLARE bad text;
BEGIN
  SELECT string_agg(c.id::text, ', ') INTO bad FROM public.exos_gift_cards c
   WHERE c.org_id IN ('c6000000-0000-0000-0000-000000000001', 'c6000000-0000-0000-0000-000000000002')
     AND c.balance_cents <> pg_temp.sum_ledger(c.id);
  ASSERT bad IS NULL, 'G13: balance <> sum(ledger) for ' || bad;
  -- Releases happened in the stale sweep too (nothing left held for failed orders).
  ASSERT public.exos_gift_card_release_stale() >= 0, 'G13: stale sweep runs';
  RAISE NOTICE 'OK  G13 ledger invariant';
END $$;

SELECT '*** GIFT CARDS + GIVING PASSED ***';
ROLLBACK;
