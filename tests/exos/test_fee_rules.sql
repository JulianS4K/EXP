-- ============================================================================
-- Organizer fee rules (mig 20261027100000). Self-contained (fe… ids), rolled
-- back at the end.
--   F1 RLS: owner / manager write, finance reads, nobody else sees a thing
--   F2 constraints: per-order passed-on, amount shape, cross-org event, tiers
--   F3 inheritance: org rules, event rules, full opt-out, per-rule skip
--   F4 public fee rules (published, passed on only) and the per-tier pick + all-in in SQL
--   F5 maths: rounding, percent vs fixed, cap, $0, taxable vs not (same
--      vectors as src/lib/fees.test.ts)
--   F6 fulfillment records the checkout's breakdown (both kinds), idempotent
--   F7 a session without a snapshot gets its absorbed fees from the rules
--   F8 the receipt and the invoice document say what the all-in price includes
--   F9 order fees: finance reads, scanner / anon don't, nobody writes
--   psql -d <db> -v ON_ERROR_STOP=1 -f tests/exos/test_fee_rules.sql
-- ============================================================================
\set ON_ERROR_STOP on
BEGIN;

INSERT INTO auth.users (id, email, email_confirmed_at) VALUES
  ('fe000000-0000-0000-0000-0000000000a0', 'fe-owner@x.com', now()),
  ('fe000000-0000-0000-0000-0000000000a1', 'fe-manager@x.com', now()),
  ('fe000000-0000-0000-0000-0000000000a2', 'fe-finance@x.com', now()),
  ('fe000000-0000-0000-0000-0000000000a3', 'fe-scanner@x.com', now()),
  ('fe000000-0000-0000-0000-0000000000a4', 'fe-stranger@x.com', now()),
  ('fe000000-0000-0000-0000-0000000000b9', 'fe-other-owner@x.com', now());
INSERT INTO public.exos_orgs (id, name, slug, owner_uid) VALUES
  ('fe000000-0000-0000-0000-000000000001', 'FE Org', 'fe-org', 'fe000000-0000-0000-0000-0000000000a0'),
  ('fe000000-0000-0000-0000-000000000002', 'FE Other', 'fe-other', 'fe000000-0000-0000-0000-0000000000b9');
INSERT INTO public.exos_org_memberships (org_id, user_id, role) VALUES
  ('fe000000-0000-0000-0000-000000000001', 'fe000000-0000-0000-0000-0000000000a0', 'owner'),
  ('fe000000-0000-0000-0000-000000000001', 'fe000000-0000-0000-0000-0000000000a1', 'manager'),
  ('fe000000-0000-0000-0000-000000000001', 'fe000000-0000-0000-0000-0000000000a2', 'finance'),
  ('fe000000-0000-0000-0000-000000000001', 'fe000000-0000-0000-0000-0000000000a3', 'scanner'),
  ('fe000000-0000-0000-0000-000000000002', 'fe000000-0000-0000-0000-0000000000b9', 'owner');
-- e1 inherits; e2 opts out of every org rule; e3 skips one; e4 draft; e9 other org.
INSERT INTO public.exos_events (id, org_id, name, slug, status, starts_at) VALUES
  ('fe000000-0000-0000-0000-0000000000e1', 'fe000000-0000-0000-0000-000000000001', 'FE Show', 'fe-show', 'published', now() + interval '9 days'),
  ('fe000000-0000-0000-0000-0000000000e2', 'fe000000-0000-0000-0000-000000000001', 'FE Opt-out', 'fe-optout', 'published', now() + interval '9 days'),
  ('fe000000-0000-0000-0000-0000000000e3', 'fe000000-0000-0000-0000-000000000001', 'FE Skip', 'fe-skip', 'published', now() + interval '9 days'),
  ('fe000000-0000-0000-0000-0000000000e4', 'fe000000-0000-0000-0000-000000000001', 'FE Draft', 'fe-draft', 'draft', now() + interval '9 days'),
  ('fe000000-0000-0000-0000-0000000000e9', 'fe000000-0000-0000-0000-000000000002', 'FE Theirs', 'fe-theirs', 'published', now() + interval '9 days');
INSERT INTO public.exos_ticket_tiers (id, event_id, name, price, capacity, sold, visibility) VALUES
  ('fe000000-0000-0000-0000-0000000000d1', 'fe000000-0000-0000-0000-0000000000e1', 'GA', 40, 100, 0, 'public'),
  ('fe000000-0000-0000-0000-0000000000d2', 'fe000000-0000-0000-0000-0000000000e1', 'VIP', 100, 100, 0, 'public'),
  ('fe000000-0000-0000-0000-0000000000d3', 'fe000000-0000-0000-0000-0000000000e1', 'Comp', 0, 100, 0, 'public'),
  ('fe000000-0000-0000-0000-0000000000d4', 'fe000000-0000-0000-0000-0000000000e1', 'Secret', 40, 100, 0, 'hidden'),
  ('fe000000-0000-0000-0000-0000000000d5', 'fe000000-0000-0000-0000-0000000000e2', 'GA', 40, 100, 0, 'public'),
  ('fe000000-0000-0000-0000-0000000000d6', 'fe000000-0000-0000-0000-0000000000e3', 'GA', 40, 100, 0, 'public'),
  ('fe000000-0000-0000-0000-0000000000d7', 'fe000000-0000-0000-0000-0000000000e4', 'GA', 40, 100, 0, 'public');
INSERT INTO public.exos_event_addons (id, event_id, name, price, capacity, sold) VALUES
  ('fe000000-0000-0000-0000-0000000000c1', 'fe000000-0000-0000-0000-0000000000e1', 'Parking', 10, 0, 0);

-- F1 -------------------------------------------------------------------------
SET ROLE authenticated;
DO $$
DECLARE n int;
BEGIN
  -- Owner: org rules. $2 facility fee per ticket (passed on, to the venue),
  -- 3% service charge (absorbed), $1.50 per order (absorbed).
  PERFORM set_config('app.uid', 'fe000000-0000-0000-0000-0000000000a0', true);
  INSERT INTO public.exos_fee_rules (id, org_id, name, recipient, kind, calc, amount_cents, sort_order)
  VALUES ('fe000000-0000-0000-0000-00000000f001', 'fe000000-0000-0000-0000-000000000001', ' Facility fee ', ' Venue ',
          'passed_on', 'fixed', 200, 1);
  INSERT INTO public.exos_fee_rules (id, org_id, name, kind, calc, percent, sort_order)
  VALUES ('fe000000-0000-0000-0000-00000000f002', 'fe000000-0000-0000-0000-000000000001', 'Service charge',
          'absorbed', 'percent', 3, 2);
  -- Manager: the per-order fee, and an edit.
  PERFORM set_config('app.uid', 'fe000000-0000-0000-0000-0000000000a1', true);
  INSERT INTO public.exos_fee_rules (id, org_id, name, recipient, kind, calc, amount_cents, per, applies_to_addons, sort_order)
  VALUES ('fe000000-0000-0000-0000-00000000f003', 'fe000000-0000-0000-0000-000000000001', 'Order fee', 'promoter',
          'absorbed', 'fixed', 150, 'order', true, 3);
  UPDATE public.exos_fee_rules SET applies_to_addons = true WHERE id = 'fe000000-0000-0000-0000-00000000f001';
  GET DIAGNOSTICS n = ROW_COUNT;
  ASSERT n = 1, 'F1: manager edits a rule';
  ASSERT (SELECT name = 'Facility fee' AND recipient = 'venue' AND created_by = 'fe000000-0000-0000-0000-0000000000a0'
            FROM public.exos_fee_rules WHERE id = 'fe000000-0000-0000-0000-00000000f001'), 'F1: name/recipient trimmed, creator stamped';

  -- Finance reads, can't write.
  PERFORM set_config('app.uid', 'fe000000-0000-0000-0000-0000000000a2', true);
  ASSERT (SELECT count(*) FROM public.exos_fee_rules) = 3, 'F1: finance reads the rules';
  UPDATE public.exos_fee_rules SET amount_cents = 1 WHERE id = 'fe000000-0000-0000-0000-00000000f001';
  GET DIAGNOSTICS n = ROW_COUNT;
  ASSERT n = 0, 'F1: finance can''t edit';
  DELETE FROM public.exos_fee_rules;
  GET DIAGNOSTICS n = ROW_COUNT;
  ASSERT n = 0, 'F1: finance can''t delete';
  BEGIN
    INSERT INTO public.exos_fee_rules (org_id, name, kind, calc, amount_cents)
    VALUES ('fe000000-0000-0000-0000-000000000001', 'Sneaky', 'passed_on', 'fixed', 999);
    RAISE EXCEPTION 'F1: finance inserted a rule';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;

  -- Scanner and a stranger see nothing and write nothing.
  FOREACH n IN ARRAY ARRAY[3, 4] LOOP
    PERFORM set_config('app.uid', 'fe000000-0000-0000-0000-0000000000a' || n, true);
    ASSERT (SELECT count(*) FROM public.exos_fee_rules) = 0, 'F1: no read for a' || n;
    ASSERT (SELECT count(*) FROM public.exos_event_fee_settings) = 0, 'F1: no settings read for a' || n;
    BEGIN
      INSERT INTO public.exos_fee_rules (org_id, name, kind, calc, amount_cents)
      VALUES ('fe000000-0000-0000-0000-000000000001', 'Sneaky', 'passed_on', 'fixed', 999);
      RAISE EXCEPTION 'F1: a% inserted a rule', n;
    EXCEPTION WHEN insufficient_privilege THEN NULL;
    END;
  END LOOP;
  -- The other org's owner can't put a rule on our org either.
  PERFORM set_config('app.uid', 'fe000000-0000-0000-0000-0000000000b9', true);
  BEGIN
    INSERT INTO public.exos_fee_rules (org_id, name, kind, calc, amount_cents)
    VALUES ('fe000000-0000-0000-0000-000000000001', 'Sneaky', 'passed_on', 'fixed', 999);
    RAISE EXCEPTION 'F1: another org''s owner inserted a rule';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  PERFORM set_config('app.uid', '', true);
  ASSERT (SELECT count(*) FROM public.exos_fee_rules) = 0, 'F1: no uid, no rows';
  BEGIN
    PERFORM 1 FROM public.exos_effective_fee_rules;
    RAISE EXCEPTION 'F1: authenticated read exos_effective_fee_rules';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  RAISE NOTICE 'OK  F1 owner/manager write, finance reads, others nothing';
END $$;
RESET ROLE;

SET ROLE anon;
DO $$
BEGIN
  BEGIN
    PERFORM 1 FROM public.exos_fee_rules;
    RAISE EXCEPTION 'F1: anon read exos_fee_rules';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  BEGIN
    PERFORM 1 FROM public.exos_order_fees;
    RAISE EXCEPTION 'F1: anon read exos_order_fees';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  RAISE NOTICE 'OK  F1 anon: no access';
END $$;
RESET ROLE;

-- F2 -------------------------------------------------------------------------
DO $$
BEGIN
  BEGIN
    INSERT INTO public.exos_fee_rules (org_id, name, kind, calc, amount_cents, per)
    VALUES ('fe000000-0000-0000-0000-000000000001', 'Order fee', 'passed_on', 'fixed', 150, 'order');
    RAISE EXCEPTION 'F2: passed-on per-order fee accepted';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
  BEGIN
    INSERT INTO public.exos_fee_rules (org_id, name, kind, calc, amount_cents, percent)
    VALUES ('fe000000-0000-0000-0000-000000000001', 'Both', 'absorbed', 'fixed', 150, 3);
    RAISE EXCEPTION 'F2: fixed rule with a percent accepted';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
  BEGIN
    INSERT INTO public.exos_fee_rules (org_id, name, kind, calc, percent)
    VALUES ('fe000000-0000-0000-0000-000000000001', 'Too much', 'absorbed', 'percent', 101);
    RAISE EXCEPTION 'F2: 101%% accepted';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
  BEGIN
    INSERT INTO public.exos_fee_rules (org_id, name, kind, calc, amount_cents, tier_ids)
    VALUES ('fe000000-0000-0000-0000-000000000001', 'Tiers', 'absorbed', 'fixed', 1, ARRAY['fe000000-0000-0000-0000-0000000000d1'::uuid]);
    RAISE EXCEPTION 'F2: tier list on an org rule accepted';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
  BEGIN
    INSERT INTO public.exos_fee_rules (org_id, event_id, name, kind, calc, amount_cents)
    VALUES ('fe000000-0000-0000-0000-000000000001', 'fe000000-0000-0000-0000-0000000000e9', 'Theirs', 'absorbed', 'fixed', 1);
    RAISE EXCEPTION 'F2: rule on another org''s event accepted';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  BEGIN
    UPDATE public.exos_fee_rules SET event_id = 'fe000000-0000-0000-0000-0000000000e1'
     WHERE id = 'fe000000-0000-0000-0000-00000000f002';
    RAISE EXCEPTION 'F2: a rule moved scope';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  BEGIN
    INSERT INTO public.exos_event_fee_settings (event_id, org_id, inherit_org_rules)
    VALUES ('fe000000-0000-0000-0000-0000000000e9', 'fe000000-0000-0000-0000-000000000001', false);
    RAISE EXCEPTION 'F2: settings for another org''s event accepted';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  RAISE NOTICE 'OK  F2 constraints hold';
END $$;

-- F3 -------------------------------------------------------------------------
-- e1: the org's 3 rules + its own VIP-only 5% passed-on, non-taxable "Restoration".
-- e2: opts out of every org rule, has its own $1 passed-on fee.
-- e3: skips the facility fee only.
-- An inactive org rule never applies.
INSERT INTO public.exos_fee_rules (id, org_id, event_id, name, kind, calc, percent, taxable, tier_ids)
VALUES ('fe000000-0000-0000-0000-00000000f101', 'fe000000-0000-0000-0000-000000000001', 'fe000000-0000-0000-0000-0000000000e1',
        'Restoration', 'passed_on', 'percent', 5, false, ARRAY['fe000000-0000-0000-0000-0000000000d2'::uuid]);
INSERT INTO public.exos_fee_rules (id, org_id, event_id, name, kind, calc, amount_cents)
VALUES ('fe000000-0000-0000-0000-00000000f201', 'fe000000-0000-0000-0000-000000000001', 'fe000000-0000-0000-0000-0000000000e2',
        'Box office', 'passed_on', 'fixed', 100);
INSERT INTO public.exos_fee_rules (id, org_id, name, kind, calc, amount_cents, active)
VALUES ('fe000000-0000-0000-0000-00000000f009', 'fe000000-0000-0000-0000-000000000001', 'Old fee', 'passed_on', 'fixed', 999, false);
INSERT INTO public.exos_event_fee_settings (event_id, org_id, inherit_org_rules) VALUES
  ('fe000000-0000-0000-0000-0000000000e2', 'fe000000-0000-0000-0000-000000000001', false);
INSERT INTO public.exos_event_fee_settings (event_id, org_id, skipped_org_rule_ids) VALUES
  ('fe000000-0000-0000-0000-0000000000e3', 'fe000000-0000-0000-0000-000000000001', ARRAY['fe000000-0000-0000-0000-00000000f001'::uuid]);

DO $$
BEGIN
  ASSERT (SELECT array_agg(name ORDER BY rank) FROM public.exos_effective_fee_rules
           WHERE event_id = 'fe000000-0000-0000-0000-0000000000e1')
         = ARRAY['Facility fee', 'Service charge', 'Order fee', 'Restoration'], 'F3: e1 = org rules then its own';
  ASSERT (SELECT array_agg(name ORDER BY rank) FROM public.exos_effective_fee_rules
           WHERE event_id = 'fe000000-0000-0000-0000-0000000000e2') = ARRAY['Box office'], 'F3: e2 opted out of the org rules';
  ASSERT (SELECT array_agg(name ORDER BY rank) FROM public.exos_effective_fee_rules
           WHERE event_id = 'fe000000-0000-0000-0000-0000000000e3') = ARRAY['Service charge', 'Order fee'], 'F3: e3 skips the facility fee';
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_effective_fee_rules WHERE event_id = 'fe000000-0000-0000-0000-0000000000e9'),
    'F3: the other org''s event has none';
  RAISE NOTICE 'OK  F3 inheritance, opt-out and per-rule skip';
END $$;

-- F4 -------------------------------------------------------------------------
-- What the buyer's price uses: exos_public_fee_rules (anon), and the same pick
-- in SQL (exos_tier_passed_on_fees, internal).
SET ROLE anon;
DO $$
BEGIN
  ASSERT (SELECT array_agg(name ORDER BY rank) FROM public.exos_public_fee_rules
           WHERE event_id = 'fe000000-0000-0000-0000-0000000000e1') = ARRAY['Facility fee', 'Restoration'],
    'F4: e1 passed-on rules only (absorbed ones never public)';
  ASSERT (SELECT amount_cents = 200 AND calc = 'fixed' AND taxable AND applies_to_addons AND tier_ids IS NULL
            FROM public.exos_public_fee_rules WHERE id = 'fe000000-0000-0000-0000-00000000f001'
              AND event_id = 'fe000000-0000-0000-0000-0000000000e1'), 'F4: facility fee row';
  ASSERT (SELECT percent = 5 AND NOT taxable AND tier_ids = ARRAY['fe000000-0000-0000-0000-0000000000d2'::uuid]
            FROM public.exos_public_fee_rules WHERE id = 'fe000000-0000-0000-0000-00000000f101'), 'F4: VIP-only row';
  ASSERT (SELECT array_agg(name) FROM public.exos_public_fee_rules
           WHERE event_id = 'fe000000-0000-0000-0000-0000000000e2') = ARRAY['Box office'], 'F4: opted-out event: its own only';
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_public_fee_rules WHERE event_id = 'fe000000-0000-0000-0000-0000000000e3'),
    'F4: skipped rule not passed on';
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_public_fee_rules WHERE event_id = 'fe000000-0000-0000-0000-0000000000e4'),
    'F4: draft event: nothing public';
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_public_fee_rules WHERE kind <> 'passed_on' OR per <> 'ticket'),
    'F4: only passed-on per-ticket rules';
  BEGIN
    PERFORM public.exos_tier_passed_on_fees('fe000000-0000-0000-0000-0000000000d1');
    RAISE EXCEPTION 'F4: anon called the internal helper';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  RAISE NOTICE 'OK  F4 public fee rules';
END $$;
RESET ROLE;
DO $$
DECLARE f jsonb;
BEGIN
  f := public.exos_tier_passed_on_fees('fe000000-0000-0000-0000-0000000000d1');
  ASSERT jsonb_array_length(f) = 1 AND f->0->>'name' = 'Facility fee', 'F4: GA: the facility fee, got ' || f;
  f := public.exos_tier_passed_on_fees('fe000000-0000-0000-0000-0000000000d2');
  ASSERT jsonb_array_length(f) = 2 AND f->1->>'name' = 'Restoration', 'F4: VIP adds its own rule, got ' || f;
  f := public.exos_tier_passed_on_fees('fe000000-0000-0000-0000-0000000000d6');
  ASSERT f = '[]'::jsonb, 'F4: e3 GA: none';
  f := public.exos_addon_passed_on_fees('fe000000-0000-0000-0000-0000000000c1');
  ASSERT jsonb_array_length(f) = 1 AND f->0->>'name' = 'Facility fee', 'F4: add-on: the rule covering add-ons';
  -- The view's all-in price: GA $40 + $2 = $42; VIP $100 + $2 + 5% = $107.
  ASSERT public.exos_all_in_unit_cents(4000, 0, public.exos_tier_passed_on_fees('fe000000-0000-0000-0000-0000000000d1')) = 4200, 'F4: GA all-in';
  ASSERT public.exos_all_in_unit_cents(10000, 0, public.exos_tier_passed_on_fees('fe000000-0000-0000-0000-0000000000d2')) = 10700, 'F4: VIP all-in';
  ASSERT public.exos_all_in_unit_cents(0, 0, public.exos_tier_passed_on_fees('fe000000-0000-0000-0000-0000000000d3')) = 0, 'F4: comp stays free';
  RAISE NOTICE 'OK  F4 per-tier pick in SQL';
END $$;

-- F5 -------------------------------------------------------------------------
DO $$
BEGIN
  ASSERT public.exos_fee_unit_cents(1999, '{"calc":"percent","percent":3}') = 60, 'F5: 3% of 19.99 = 0.5997 -> 0.60';
  ASSERT public.exos_fee_unit_cents(100, '{"calc":"percent","percent":1.5}') = 2, 'F5: 1.5 cents rounds half up';
  ASSERT public.exos_fee_unit_cents(1000, '{"calc":"percent","percent":12.345}') = 123, 'F5: 123.45 cents -> 123';
  ASSERT public.exos_fee_unit_cents(1, '{"calc":"percent","percent":2.5}') = 0, 'F5: tiny percent -> 0';
  ASSERT public.exos_fee_unit_cents(100000, '{"calc":"percent","percent":10,"cap_cents":500}') = 500, 'F5: cap';
  ASSERT public.exos_fee_unit_cents(4000, '{"calc":"fixed","amount_cents":200}') = 200, 'F5: fixed';
  ASSERT public.exos_fee_unit_cents(0, '{"calc":"fixed","amount_cents":200}') = 0, 'F5: free unit stays free';
  ASSERT public.exos_fee_unit_cents(4000, '{"calc":"bogus","amount_cents":200}') = 0, 'F5: unknown calc -> 0';
  ASSERT public.exos_all_in_unit_cents(4000, 0, '[]') = 4000, 'F5: no fees, no tax';
  ASSERT public.exos_all_in_unit_cents(4000, 8.875, '[]') = 4355, 'F5: tax only (unchanged rule)';
  ASSERT public.exos_all_in_unit_cents(4000, 0, '[{"calc":"fixed","amount_cents":200}]') = 4200, 'F5: fee only';
  ASSERT public.exos_all_in_unit_cents(4000, 8.875, '[{"calc":"fixed","amount_cents":200}]') = 4573,
    'F5: taxable fee: 4000 + 200 + round(4200 x 8.875%) = 4573';
  ASSERT public.exos_all_in_unit_cents(4000, 8.875, '[{"calc":"fixed","amount_cents":200,"taxable":false}]') = 4555,
    'F5: non-taxable fee: 4000 + 200 + round(4000 x 8.875%) = 4555';
  ASSERT public.exos_all_in_unit_cents(10000, 8.875, '[{"calc":"fixed","amount_cents":200},{"calc":"percent","percent":5,"taxable":false}]') = 11605,
    'F5: two fees: 10000 + 200 + 500 + round(10200 x 8.875%) = 11605';
  RAISE NOTICE 'OK  F5 fee maths';
END $$;

-- F6 -------------------------------------------------------------------------
-- 2 x GA at $40 + 1 parking at $10, no tax. What exos-checkout's orderFeeLines
-- produces for e1's rules (src/lib/fees.test.ts "the e1 order" is the same case):
--   facility fee  passed_on  200/ticket x2, 200/parking x1  -> the buyer pays 600, inside the all-in price
--   service 3%    absorbed   120/ticket x2                    -> 240
--   order fee     absorbed   150 once                         -> 150
INSERT INTO public.exos_checkout_sessions (session_id, event_id, tier_id, org_id, buyer_uid, buyer_email, guest,
                                           quantity, amount_cents, currency, status, addons)
VALUES ('fe-s1', 'fe000000-0000-0000-0000-0000000000e1', 'fe000000-0000-0000-0000-0000000000d1',
        'fe000000-0000-0000-0000-000000000001', NULL, 'fe-fan@x.com', true, 2, 9600, 'usd', 'pending',
        '[{"addon_id":"fe000000-0000-0000-0000-0000000000c1","quantity":1,"unit_price_cents":1000,"name":"Parking"}]');
-- The fee lines sit in their own service-only table, not on the buyer-readable session.
INSERT INTO public.exos_checkout_fee_snapshots (session_id, lines)
VALUES ('fe-s1',
        '[{"rule_id":"fe000000-0000-0000-0000-00000000f001","name":"Facility fee","kind":"passed_on","recipient":"venue","calc":"fixed","percent":null,"per":"ticket","item_kind":"ticket","item_id":"fe000000-0000-0000-0000-0000000000d1","unit_cents":200,"quantity":2,"amount_cents":400,"taxable":true},
          {"rule_id":"fe000000-0000-0000-0000-00000000f001","name":"Facility fee","kind":"passed_on","recipient":"venue","calc":"fixed","percent":null,"per":"ticket","item_kind":"addon","item_id":"fe000000-0000-0000-0000-0000000000c1","unit_cents":200,"quantity":1,"amount_cents":200,"taxable":true},
          {"rule_id":"fe000000-0000-0000-0000-00000000f002","name":"Service charge","kind":"absorbed","recipient":"org","calc":"percent","percent":3,"per":"ticket","item_kind":"ticket","item_id":"fe000000-0000-0000-0000-0000000000d1","unit_cents":120,"quantity":2,"amount_cents":240,"taxable":false},
          {"rule_id":"fe000000-0000-0000-0000-00000000f003","name":"Order fee","kind":"absorbed","recipient":"promoter","calc":"fixed","percent":null,"per":"order","item_kind":"order","item_id":null,"unit_cents":150,"quantity":1,"amount_cents":150,"taxable":false},
          {"rule_id":"junk","name":"Bad","kind":"passed_on","calc":"fixed","per":"ticket","item_kind":"ticket","unit_cents":-5,"quantity":1},
          {"name":"Bad kind","kind":"surprise","calc":"fixed","per":"ticket","item_kind":"ticket","unit_cents":5,"quantity":1}]');
DO $$
DECLARE ids uuid[]; n int;
BEGIN
  PERFORM public.exos_record_price_disclosure('fe-s1', 'usd', jsonb_build_array(
    jsonb_build_object('kind','ticket','item_id','fe000000-0000-0000-0000-0000000000d1','name','GA','quantity',2,
                       'face_unit_cents',4000,'tax_cents',0,'fee_cents',400,'unit_all_in_cents',4200),
    jsonb_build_object('kind','addon','item_id','fe000000-0000-0000-0000-0000000000c1','name','Parking','quantity',1,
                       'face_unit_cents',1000,'tax_cents',0,'fee_cents',200,'unit_all_in_cents',1200)));
  ids := public.exos_fulfill_checkout('fe-s1');
  ASSERT array_length(ids, 1) = 2, 'F6: two tickets minted';
  ASSERT (SELECT count(*) FROM public.exos_order_fees WHERE session_id = 'fe-s1') = 4, 'F6: four lines (junk skipped)';
  ASSERT (SELECT sum(amount_cents) FROM public.exos_order_fees WHERE session_id = 'fe-s1' AND kind = 'passed_on') = 600,
    'F6: passed on = 600';
  ASSERT (SELECT sum(amount_cents) FROM public.exos_order_fees WHERE session_id = 'fe-s1' AND kind = 'absorbed') = 390,
    'F6: absorbed = 240 + 150';
  ASSERT (SELECT org_id = 'fe000000-0000-0000-0000-000000000001' AND event_id = 'fe000000-0000-0000-0000-0000000000e1'
                 AND recipient = 'promoter' AND per = 'order' AND item_id IS NULL AND source = 'checkout' AND currency = 'usd'
            FROM public.exos_order_fees WHERE session_id = 'fe-s1' AND rule_id = 'fe000000-0000-0000-0000-00000000f003'),
    'F6: per-order line';
  ASSERT (SELECT percent = 3 AND NOT taxable FROM public.exos_order_fees
           WHERE session_id = 'fe-s1' AND rule_id = 'fe000000-0000-0000-0000-00000000f002'), 'F6: percent kept';
  -- Disclosure: shown = charged, and the passed-on fees are inside it.
  ASSERT (SELECT total_shown_cents FROM public.exos_price_disclosures WHERE session_id = 'fe-s1')
         = (SELECT amount_cents FROM public.exos_checkout_sessions WHERE session_id = 'fe-s1'), 'F6: shown = charged';
  ASSERT (SELECT sum(fee_cents) FROM public.exos_price_disclosure_lines WHERE session_id = 'fe-s1') = 600,
    'F6: disclosure lines carry the passed-on fees';
  -- Idempotent: re-fulfilment and a manual re-record add nothing.
  ASSERT public.exos_fulfill_checkout('fe-s1') = ids, 'F6: re-fulfilment idempotent';
  n := public.exos_record_order_fees('fe-s1');
  ASSERT n = 0 AND (SELECT count(*) FROM public.exos_order_fees WHERE session_id = 'fe-s1') = 4, 'F6: re-record adds nothing';
  ASSERT public.exos_record_order_fees('fe-nope') = 0, 'F6: unknown session';
  RAISE NOTICE 'OK  F6 fulfillment records the checkout breakdown';
END $$;

-- F7 -------------------------------------------------------------------------
-- A session from before the deploy (no fee_breakdown): absorbed fees from the
-- current rules and what the buyer was shown; nothing passed on.
INSERT INTO public.exos_checkout_sessions (session_id, event_id, tier_id, org_id, buyer_uid, buyer_email, guest,
                                           quantity, amount_cents, currency, status, addons)
VALUES ('fe-s2', 'fe000000-0000-0000-0000-0000000000e1', 'fe000000-0000-0000-0000-0000000000d2',
        'fe000000-0000-0000-0000-000000000001', NULL, 'fe-fan2@x.com', true, 1, 11000, 'usd', 'pending',
        '[{"addon_id":"fe000000-0000-0000-0000-0000000000c1","quantity":1,"unit_price_cents":1000,"name":"Parking"}]');
DO $$
DECLARE ids uuid[];
BEGIN
  PERFORM public.exos_record_price_disclosure('fe-s2', 'usd', jsonb_build_array(
    jsonb_build_object('kind','ticket','item_id','fe000000-0000-0000-0000-0000000000d2','name','VIP','quantity',1,
                       'face_unit_cents',10000,'unit_all_in_cents',10000),
    jsonb_build_object('kind','addon','item_id','fe000000-0000-0000-0000-0000000000c1','name','Parking','quantity',1,
                       'face_unit_cents',1000,'unit_all_in_cents',1000)));
  ids := public.exos_fulfill_checkout('fe-s2');
  ASSERT array_length(ids, 1) = 1, 'F7: minted';
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_order_fees WHERE session_id = 'fe-s2' AND kind = 'passed_on'),
    'F7: nothing passed on without a snapshot';
  ASSERT (SELECT amount_cents FROM public.exos_order_fees WHERE session_id = 'fe-s2'
           AND rule_id = 'fe000000-0000-0000-0000-00000000f002' AND item_kind = 'ticket') = 300, 'F7: 3% of 100.00';
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_order_fees WHERE session_id = 'fe-s2'
           AND rule_id = 'fe000000-0000-0000-0000-00000000f002' AND item_kind = 'addon'), 'F7: service charge skips add-ons';
  ASSERT (SELECT amount_cents FROM public.exos_order_fees WHERE session_id = 'fe-s2'
           AND rule_id = 'fe000000-0000-0000-0000-00000000f003') = 150, 'F7: per-order fee';
  ASSERT (SELECT bool_and(source = 'rules') FROM public.exos_order_fees WHERE session_id = 'fe-s2'), 'F7: source = rules';
  RAISE NOTICE 'OK  F7 absorbed fees for a session without a snapshot';
END $$;

-- F8 -------------------------------------------------------------------------
DO $$
DECLARE h text;
BEGIN
  h := public.exos_receipt_html('fe-s1');
  ASSERT h LIKE '%Paid: <strong>96.00 USD</strong>%', 'F8: total';
  ASSERT h LIKE '%the prices above include 6.00 facility fee; nothing was added at checkout.%', 'F8: includes line, got ' || h;
  h := public.exos_receipt_html('fe-s2');
  ASSERT h LIKE '%All-in price: no fees were added at checkout.%' AND h NOT LIKE '%service charge%',
    'F8: absorbed fees never reach the buyer''s receipt';
  RAISE NOTICE 'OK  F8 receipt says what the all-in price includes';
END $$;

-- The invoice document lists the same fees (owner view); the buyer-facing
-- fields are unchanged.
SET ROLE authenticated;
DO $$
DECLARE d jsonb; v_inv uuid;
BEGIN
  PERFORM set_config('app.uid', 'fe000000-0000-0000-0000-0000000000a0', true);
  SELECT id INTO v_inv FROM public.exos_invoices WHERE session_id = 'fe-s1';
  ASSERT v_inv IS NOT NULL, 'F8: fulfillment issued an invoice';
  d := public.exos_invoice_document(v_inv);
  ASSERT d->'fees' = '[{"name": "Facility fee", "recipient": "venue", "amount_cents": 600}]'::jsonb, 'F8: invoice fees, got ' || (d->'fees')::text;
  ASSERT (SELECT sum((l->>'fee_cents')::int) FROM jsonb_array_elements(d->'lines') l) = 600, 'F8: per-line fee_cents';
  ASSERT (SELECT sum((l->>'total_cents')::int) FROM jsonb_array_elements(d->'lines') l) = 9600, 'F8: lines = total paid';
  PERFORM set_config('app.uid', '', true);
  RAISE NOTICE 'OK  F8 invoice document lists the included fees';
END $$;
RESET ROLE;

-- F9 -------------------------------------------------------------------------
SET ROLE authenticated;
DO $$
BEGIN
  PERFORM set_config('app.uid', 'fe000000-0000-0000-0000-0000000000a2', true);
  ASSERT (SELECT count(*) FROM public.exos_order_fees) = 6, 'F9: finance reads the order fees (4 + 2)';
  PERFORM set_config('app.uid', 'fe000000-0000-0000-0000-0000000000a3', true);
  ASSERT (SELECT count(*) FROM public.exos_order_fees) = 0, 'F9: scanner reads none';
  PERFORM set_config('app.uid', 'fe000000-0000-0000-0000-0000000000a0', true);
  BEGIN
    INSERT INTO public.exos_order_fees (session_id, org_id, event_id, rule_name, kind, calc, per, item_kind, unit_cents, quantity, amount_cents)
    VALUES ('fe-s1', 'fe000000-0000-0000-0000-000000000001', 'fe000000-0000-0000-0000-0000000000e1', 'x', 'absorbed', 'fixed', 'order', 'order', 1, 1, 1);
    RAISE EXCEPTION 'F9: owner wrote an order fee';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  BEGIN
    PERFORM public.exos_record_order_fees('fe-s1');
    RAISE EXCEPTION 'F9: authenticated called exos_record_order_fees';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  PERFORM set_config('app.uid', '', true);
  RAISE NOTICE 'OK  F9 order fees: finance reads, nobody writes';
END $$;
RESET ROLE;

-- F10 ------------------------------------------------------------------------
DO $$
DECLARE i int;
BEGIN
  FOR i IN 1..21 LOOP
    INSERT INTO public.exos_fee_rules (org_id, name, kind, calc, amount_cents)
    VALUES ('fe000000-0000-0000-0000-000000000001', 'Filler ' || i, 'absorbed', 'fixed', 1);
  END LOOP;
  BEGIN
    INSERT INTO public.exos_fee_rules (org_id, name, kind, calc, amount_cents)
    VALUES ('fe000000-0000-0000-0000-000000000001', 'One too many', 'absorbed', 'fixed', 1);
    RAISE EXCEPTION 'F10: 26th org rule accepted';
  EXCEPTION WHEN invalid_parameter_value THEN NULL;
  END;
  ASSERT (SELECT count(*) FROM public.exos_effective_fee_rules WHERE event_id = 'fe000000-0000-0000-0000-0000000000e1') = 10,
    'F10: at most 10 rules take effect';
  RAISE NOTICE 'OK  F10 limits: 25 rules per scope, 10 in effect';
END $$;

-- F11 ------------------------------------------------------------------------
-- The checkout's fee lines (absorbed fees included) are not readable by
-- buyers or staff clients: service role only. The session row carries none.
DO $$
BEGIN
  ASSERT NOT has_table_privilege('authenticated', 'public.exos_checkout_fee_snapshots', 'SELECT')
     AND NOT has_table_privilege('anon', 'public.exos_checkout_fee_snapshots', 'SELECT'),
    'F11: fee snapshots readable by a client role';
  ASSERT NOT EXISTS (SELECT 1 FROM information_schema.columns
                      WHERE table_schema = 'public' AND table_name = 'exos_checkout_sessions'
                        AND column_name = 'fee_breakdown'),
    'F11: fee lines on the buyer-readable session row';
  RAISE NOTICE 'OK  F11 fee snapshots are service role only';
END $$;

SELECT '*** FEE RULES PASSED ***';
ROLLBACK;
