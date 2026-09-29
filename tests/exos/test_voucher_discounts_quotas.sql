-- ============================================================================
-- Promo codes as vouchers + quota editor (mig 20260928060000). Runs in
-- run_p0.sh after the platform suites; fixtures use their own ids (9d…).
--   V1 issue a % / $ off code; one price rule per code; comps aren't discounts
--   V2 the table refuses two price rules or out-of-range values
--   V3 exos_voucher_discount answers only for a code that is valid now
--   V4 saved exos_discount_codes carry over to vouchers (idempotent)
--   V5 a discount code is used up per ticket at fulfilment, like any voucher
--   Q1 a quota always belongs to its event's org (no cross-org quota)
--   Q2 a quota only takes ticket types of its own event, and can't move events
--   Q3 exos_event_quotas: sold / held / left, staff only
-- ============================================================================
\set ON_ERROR_STOP on

INSERT INTO auth.users(id,email,email_confirmed_at) VALUES
  ('9d000000-0000-0000-0000-0000000000a0','9d-owner@x.com',now()),
  ('9d000000-0000-0000-0000-0000000000a1','9d-rival@x.com',now()),
  ('9d000000-0000-0000-0000-0000000000b1','9d-fan@x.com',now());
INSERT INTO public.exos_orgs(id,name,slug,owner_uid) VALUES
  ('9d000000-0000-0000-0000-000000000001','9D Org','9d-org','9d000000-0000-0000-0000-0000000000a0'),
  ('9d000000-0000-0000-0000-000000000002','9D Rival','9d-rival','9d000000-0000-0000-0000-0000000000a1');
INSERT INTO public.exos_org_memberships(org_id,user_id,role) VALUES
  ('9d000000-0000-0000-0000-000000000001','9d000000-0000-0000-0000-0000000000a0','owner'),
  ('9d000000-0000-0000-0000-000000000002','9d000000-0000-0000-0000-0000000000a1','owner');
INSERT INTO public.exos_events(id,org_id,name,slug,status,total_tickets,tickets_sold) VALUES
  ('9d000000-0000-0000-0000-0000000000e1','9d000000-0000-0000-0000-000000000001','9D Show','9d-show','published',0,0),
  ('9d000000-0000-0000-0000-0000000000e2','9d000000-0000-0000-0000-000000000001','9D Other','9d-other','published',0,0);
INSERT INTO public.exos_ticket_tiers(id,event_id,name,price,capacity,sold) VALUES
  ('9d000000-0000-0000-0000-0000000000d1','9d000000-0000-0000-0000-0000000000e1','Early',30,100,0),
  ('9d000000-0000-0000-0000-0000000000d2','9d000000-0000-0000-0000-0000000000e1','GA',40,100,0),
  ('9d000000-0000-0000-0000-0000000000d3','9d000000-0000-0000-0000-0000000000e2','GA',40,100,0);

CREATE OR REPLACE FUNCTION pg_temp.as_user(p_uid text, p_email text) RETURNS void LANGUAGE sql AS $$
  SELECT set_config('app.uid', coalesce(p_uid, ''), true), set_config('app.jwt', json_build_object('email', p_email)::text, true);
$$;
CREATE OR REPLACE FUNCTION pg_temp.issue_err(p_pct numeric, p_amt numeric, p_set numeric, p_code text) RETURNS text
LANGUAGE plpgsql AS $$
BEGIN
  PERFORM public.exos_issue_voucher('9d000000-0000-0000-0000-0000000000e1', NULL, NULL, false, p_set, 10, NULL, NULL, p_code, p_pct, p_amt);
  RETURN NULL;
EXCEPTION WHEN others THEN RETURN SQLERRM;
END $$;

-- V1 -------------------------------------------------------------------------
DO $$
DECLARE c text; v record; e text;
BEGIN
  PERFORM pg_temp.as_user('9d000000-0000-0000-0000-0000000000a0', '9d-owner@x.com');
  c := public.exos_issue_voucher('9d000000-0000-0000-0000-0000000000e1', NULL, NULL, false, NULL, 100, NULL, NULL, 'early20', 20, NULL);
  SELECT * INTO v FROM public.exos_vouchers WHERE event_id = '9d000000-0000-0000-0000-0000000000e1' AND code = 'EARLY20';
  ASSERT c = 'EARLY20' AND v.discount_percent = 20 AND v.discount_amount IS NULL AND v.price_override IS NULL
     AND v.max_uses = 100 AND NOT v.bypass_capacity, 'V1: 20% off code for 100 tickets';
  c := public.exos_issue_voucher('9d000000-0000-0000-0000-0000000000e1', '9d000000-0000-0000-0000-0000000000d2', NULL, false, NULL, 5, NULL, NULL, 'FIVEOFF', NULL, 5);
  ASSERT (SELECT discount_amount FROM public.exos_vouchers WHERE code = 'FIVEOFF') = 5, 'V1: $5 off code';
  e := pg_temp.issue_err(20, 5, NULL, 'BOTH1');
  ASSERT e LIKE '%pick one%', 'V1: two rules refused, got ' || coalesce(e, 'ok');
  e := pg_temp.issue_err(10, NULL, 25, 'BOTH2');
  ASSERT e LIKE '%pick one%', 'V1: set price + percent refused, got ' || coalesce(e, 'ok');
  e := pg_temp.issue_err(100, NULL, NULL, 'FREE');
  ASSERT e LIKE '%use a comp%', 'V1: 100% refused, got ' || coalesce(e, 'ok');
  e := pg_temp.issue_err(NULL, 0, NULL, 'ZERO');
  ASSERT e LIKE '%more than 0%', 'V1: $0 off refused, got ' || coalesce(e, 'ok');
  -- The old signature's callers (price override only) still work.
  c := public.exos_issue_voucher(p_event_id => '9d000000-0000-0000-0000-0000000000e1', p_price_override => 12, p_code => 'SETPRICE');
  ASSERT (SELECT price_override FROM public.exos_vouchers WHERE code = 'SETPRICE') = 12, 'V1: set-price vouchers unchanged';
  PERFORM pg_temp.as_user(NULL, NULL);
  RAISE NOTICE 'OK  V1 %% / $ off codes; one price rule; comps are not discounts';
END $$;

-- V2 -------------------------------------------------------------------------
DO $$
BEGIN
  BEGIN
    INSERT INTO public.exos_vouchers(event_id, code, discount_percent, discount_amount)
    VALUES ('9d000000-0000-0000-0000-0000000000e1', 'RAWONE', 10, 5);
    RAISE EXCEPTION 'V2: two rules must be refused';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
  BEGIN
    INSERT INTO public.exos_vouchers(event_id, code, discount_percent) VALUES ('9d000000-0000-0000-0000-0000000000e1', 'RAWTWO', 150);
    RAISE EXCEPTION 'V2: 150%% must be refused';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
  RAISE NOTICE 'OK  V2 the table holds one in-range price rule';
END $$;

-- V3 -------------------------------------------------------------------------
DO $$
DECLARE p numeric; n int;
BEGIN
  SET LOCAL ROLE authenticated;  -- codes need an account (mig 20260929080000)
  SELECT discount_percent INTO p FROM public.exos_voucher_discount('9d000000-0000-0000-0000-0000000000e1', 'early20');
  RESET ROLE;
  ASSERT p = 20, 'V3: a buyer sees the discount of a valid code (any case)';
  SELECT count(*) INTO n FROM public.exos_voucher_discount('9d000000-0000-0000-0000-0000000000e1', 'NOPE');
  ASSERT n = 0, 'V3: nothing for an unknown code';
  UPDATE public.exos_vouchers SET valid_until = now() - interval '1 minute' WHERE code = 'FIVEOFF';
  SELECT count(*) INTO n FROM public.exos_voucher_discount('9d000000-0000-0000-0000-0000000000e1', 'FIVEOFF');
  ASSERT n = 0, 'V3: nothing for an expired code';
  UPDATE public.exos_vouchers SET valid_until = NULL WHERE code = 'FIVEOFF';
  RAISE NOTICE 'OK  V3 exos_voucher_discount answers only for valid codes';
END $$;

-- V4 -------------------------------------------------------------------------
-- The old table (20260520120000) isn't in every scratch chain; prod has it.
CREATE TABLE IF NOT EXISTS public.exos_discount_codes (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  event_id uuid NOT NULL REFERENCES public.exos_events (id) ON DELETE CASCADE,
  code text NOT NULL, type text NOT NULL CHECK (type IN ('percentage','fixed')),
  value numeric NOT NULL CHECK (value >= 0), usage_limit integer,
  used_count integer NOT NULL DEFAULT 0, expires_at timestamptz, unlocks_tier_ids uuid[],
  created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (event_id, code));
INSERT INTO public.exos_discount_codes(event_id, code, type, value, usage_limit, used_count, expires_at, unlocks_tier_ids) VALUES
  ('9d000000-0000-0000-0000-0000000000e1', 'summer15', 'percentage', 15, 50, 3, now() + interval '30 days', ARRAY['9d000000-0000-0000-0000-0000000000d1']::uuid[]),
  ('9d000000-0000-0000-0000-0000000000e1', 'TENBUCKS', 'fixed', 10, NULL, 0, NULL, NULL),
  ('9d000000-0000-0000-0000-0000000000e1', 'ALLFREE', 'percentage', 100, 5, 0, NULL, NULL),
  ('9d000000-0000-0000-0000-0000000000e1', 'early20', 'percentage', 50, 5, 0, NULL, NULL),
  ('9d000000-0000-0000-0000-0000000000e1', 'TWOTIERS', 'percentage', 10, 5, 0, NULL,
   ARRAY['9d000000-0000-0000-0000-0000000000d1','9d000000-0000-0000-0000-0000000000d2']::uuid[]);
\ir ../../supabase/migrations/20260928060000_exos_voucher_discounts_quota_editor.sql
\ir ../../supabase/migrations/20260928060000_exos_voucher_discounts_quota_editor.sql
-- The replay re-grants exos_voucher_discount to anon; the later hardening
-- (mig 20260929080000) owns that grant, so put it back as prod has it.
\ir ../../supabase/migrations/20260929080000_exos_rpc_hardening.sql
DO $$
DECLARE v record;
BEGIN
  SELECT * INTO v FROM public.exos_vouchers WHERE event_id = '9d000000-0000-0000-0000-0000000000e1' AND code = 'SUMMER15';
  ASSERT v.discount_percent = 15 AND v.max_uses = 50 AND v.used_count = 3 AND v.valid_until IS NOT NULL
     AND v.tier_id = '9d000000-0000-0000-0000-0000000000d1' AND NOT v.bypass_capacity, 'V4: percent code carried over';
  SELECT * INTO v FROM public.exos_vouchers WHERE event_id = '9d000000-0000-0000-0000-0000000000e1' AND code = 'TENBUCKS';
  ASSERT v.discount_amount = 10 AND v.max_uses = 100000 AND v.tier_id IS NULL, 'V4: fixed code, no limit';
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_vouchers WHERE code = 'ALLFREE'), 'V4: a 100% code is not carried over';
  ASSERT (SELECT discount_percent FROM public.exos_vouchers WHERE event_id = '9d000000-0000-0000-0000-0000000000e1' AND code = 'EARLY20') = 20,
    'V4: an existing voucher with the same code wins';
  ASSERT (SELECT tier_id FROM public.exos_vouchers WHERE code = 'TWOTIERS') IS NULL, 'V4: several unlocked tiers -> any tier';
  ASSERT (SELECT count(*) FROM public.exos_vouchers WHERE event_id = '9d000000-0000-0000-0000-0000000000e1' AND code = 'SUMMER15') = 1,
    'V4: re-applying copies nothing twice';
  RAISE NOTICE 'OK  V4 saved promo codes carry over to vouchers, once';
END $$;

-- V5 -------------------------------------------------------------------------
DO $$
DECLARE vid uuid; ids uuid[];
BEGIN
  SELECT id INTO vid FROM public.exos_vouchers WHERE event_id = '9d000000-0000-0000-0000-0000000000e1' AND code = 'EARLY20';
  INSERT INTO public.exos_checkout_sessions(session_id,event_id,tier_id,org_id,buyer_uid,buyer_email,quantity,amount_cents,status,voucher_id)
  VALUES ('9d-v5','9d000000-0000-0000-0000-0000000000e1','9d000000-0000-0000-0000-0000000000d2',
          '9d000000-0000-0000-0000-000000000001','9d000000-0000-0000-0000-0000000000b1','9d-fan@x.com',3,9600,'pending',vid);
  ids := public.exos_fulfill_checkout('9d-v5');
  ASSERT array_length(ids,1) = 3, 'V5: three tickets';
  ASSERT (SELECT used_count FROM public.exos_vouchers WHERE id = vid) = 3, 'V5: three uses of the code';
  ASSERT (SELECT min(price_paid) FROM public.exos_tickets WHERE order_ref = '9d-v5') = 32, 'V5: each ticket paid 32 (40 less 20%)';
  RAISE NOTICE 'OK  V5 a discount code is used up per ticket at fulfilment';
END $$;

-- Q1 -------------------------------------------------------------------------
DO $$
DECLARE q uuid; refused boolean := false;
BEGIN
  -- As postgres (no RLS): whatever org_id is sent, the event's org is kept.
  INSERT INTO public.exos_quotas(event_id, org_id, name, size)
  VALUES ('9d000000-0000-0000-0000-0000000000e1', '9d000000-0000-0000-0000-000000000002', ' Standing ', 150) RETURNING id INTO q;
  ASSERT (SELECT org_id FROM public.exos_quotas WHERE id = q) = '9d000000-0000-0000-0000-000000000001', 'Q1: org_id comes from the event';
  ASSERT (SELECT name FROM public.exos_quotas WHERE id = q) = 'Standing', 'Q1: name trimmed';
  INSERT INTO public.exos_quota_tiers(quota_id, tier_id) VALUES
    (q, '9d000000-0000-0000-0000-0000000000d1'), (q, '9d000000-0000-0000-0000-0000000000d2');

  -- The rival org's owner, labelling the row as their own org, is refused by RLS.
  PERFORM pg_temp.as_user('9d000000-0000-0000-0000-0000000000a1', '9d-rival@x.com');
  SET LOCAL ROLE authenticated;
  BEGIN
    INSERT INTO public.exos_quotas(event_id, org_id, name, size, closed)
    VALUES ('9d000000-0000-0000-0000-0000000000e1', '9d000000-0000-0000-0000-000000000002', 'Shut', 0, true);
  EXCEPTION WHEN insufficient_privilege THEN refused := true;
  END;
  RESET ROLE;
  PERFORM pg_temp.as_user(NULL, NULL);
  ASSERT refused, 'Q1: another org cannot put a quota on this event';
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_quotas WHERE name = 'Shut'), 'Q1: nothing inserted';
  RAISE NOTICE 'OK  Q1 a quota always belongs to its event''s org';
END $$;

-- Q2 -------------------------------------------------------------------------
DO $$
DECLARE q uuid;
BEGIN
  SELECT id INTO q FROM public.exos_quotas WHERE name = 'Standing' AND event_id = '9d000000-0000-0000-0000-0000000000e1';
  BEGIN
    INSERT INTO public.exos_quota_tiers(quota_id, tier_id) VALUES (q, '9d000000-0000-0000-0000-0000000000d3');
    RAISE EXCEPTION 'Q2: a tier of another event must be refused';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  BEGIN
    UPDATE public.exos_quotas SET event_id = '9d000000-0000-0000-0000-0000000000e2' WHERE id = q;
    RAISE EXCEPTION 'Q2: a quota must not move events';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  BEGIN
    UPDATE public.exos_quotas SET name = '  ' WHERE id = q;
    RAISE EXCEPTION 'Q2: a blank name must be refused';
  EXCEPTION WHEN invalid_parameter_value THEN NULL;
  END;
  RAISE NOTICE 'OK  Q2 a quota takes only its own event''s ticket types and stays on its event';
END $$;

-- Q3: 150 standing across Early + GA; 3 GA sold (V5), 2 Early in a live cart --
DO $$
DECLARE r record; refused boolean := false;
BEGIN
  INSERT INTO public.exos_cart_holds(event_id, tier_id, org_id, buyer_uid, buyer_email, quantity, expires_at)
  VALUES ('9d000000-0000-0000-0000-0000000000e1','9d000000-0000-0000-0000-0000000000d1','9d000000-0000-0000-0000-000000000001',
          '9d000000-0000-0000-0000-0000000000b1','9d-fan@x.com',2, now() + interval '10 minutes');
  PERFORM pg_temp.as_user('9d000000-0000-0000-0000-0000000000a0', '9d-owner@x.com');
  SELECT * INTO r FROM public.exos_event_quotas('9d000000-0000-0000-0000-0000000000e1') WHERE name = 'Standing';
  ASSERT r.size = 150 AND r.sold = 3 AND r.held = 2 AND r.available = 145 AND cardinality(r.tier_ids) = 2 AND NOT r.closed,
    format('Q3: sold/held/left, got %s/%s/%s', r.sold, r.held, r.available);
  UPDATE public.exos_quotas SET closed = true WHERE id = r.id;
  ASSERT (SELECT available FROM public.exos_event_quotas('9d000000-0000-0000-0000-0000000000e1') WHERE name = 'Standing') = 0,
    'Q3: a closed quota has nothing left';
  PERFORM pg_temp.as_user('9d000000-0000-0000-0000-0000000000a1', '9d-rival@x.com');
  BEGIN
    PERFORM * FROM public.exos_event_quotas('9d000000-0000-0000-0000-0000000000e1');
  EXCEPTION WHEN insufficient_privilege THEN refused := true;
  END;
  PERFORM pg_temp.as_user(NULL, NULL);
  ASSERT refused, 'Q3: another org cannot read the quotas';
  RAISE NOTICE 'OK  Q3 exos_event_quotas reports sold / held / left to staff only';
END $$;
