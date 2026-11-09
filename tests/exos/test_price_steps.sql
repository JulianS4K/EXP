-- ============================================================================
-- Price steps (mig 20261106130000, claude/exos-capacity-pricing). DICE
-- PriceTier. Self-contained (b57 prefix), rolled back.
--   PS1  parity: exos_tier_current_price on the shared cases
--        (tests/exos/fixtures/price_steps_cases.json), which
--        src/lib/priceSteps.test.ts runs against the TypeScript mirror
--   PS2  RLS + grants: staff of the org read steps, nobody writes the table
--        directly, another org sees nothing; the price function is
--        service-role only, buyers get it through exos_public_tier_price
--        (public types of published events only); cross-org writes refused
--   PS3  validation: an end on every step but the last, none on the last,
--        times don't go backwards, unknown fields, 20 at most
--   PS4  one pricing path: the old price_schedule becomes steps (time-only),
--        steps write it back; a count step empties it and refuses schedule
--        writes; a price write moves the first step
--   PS5  advance by count through real holds + fulfilment; the latch
--   PS6  boundary rule (cap): an order bigger than the step's remaining is
--        refused at the lock with how many are left
--   PS7  a locked price survives an advance during payment; a stale price
--        is refused (price_changed)
--   PS8  advance by time; the door price at POS (and it takes no step place)
--   PS9  refunds: before the latch they free the step's place, after it no
--   PS10 feeds and APIs show the checkout price (view, public API JSON,
--        partner event JSON, discovery, listing feed, partner unit price,
--        voucher tier, all-in)
--   PS11 API cores: org scoping, steps + door price, validation
--   PS12 price and door-price writes: only keys created by an owner or manager
--   PS13 door_price_cents through PATCH ticket-type; exos_current_price
-- ============================================================================
\set ON_ERROR_STOP on
\if :{?fixtures}
\else
\set fixtures tests/exos/fixtures
\endif
\set cases_file :fixtures '/price_steps_cases.json'
\set cases `cat :cases_file`
BEGIN;
\o /dev/null
SELECT set_config('b57.cases', :'cases', true);
\o

CREATE OR REPLACE FUNCTION pg_temp.as_user(p_uid text, p_email text) RETURNS void LANGUAGE sql AS $$
  SELECT set_config('app.uid', coalesce(p_uid, ''), true), set_config('app.jwt', json_build_object('email', p_email)::text, true);
$$;
CREATE OR REPLACE FUNCTION pg_temp.st(p_sql text) RETURNS text LANGUAGE plpgsql AS $$
BEGIN
  EXECUTE p_sql;
  RETURN 'ok';
EXCEPTION WHEN OTHERS THEN RETURN SQLSTATE || ' ' || SQLERRM;
END $$;

INSERT INTO auth.users (id, email, email_confirmed_at) VALUES
  ('b5700000-0000-0000-0000-0000000000a1', 'b57-owner@x.com', now()),
  ('b5700000-0000-0000-0000-0000000000a2', 'b57-scanner@x.com', now()),
  ('b5700000-0000-0000-0000-0000000000a3', 'b57-owner2@x.com', now()),
  ('b5700000-0000-0000-0000-0000000000b1', 'b57-fan1@x.com', now()),
  ('b5700000-0000-0000-0000-0000000000b2', 'b57-fan2@x.com', now());
INSERT INTO public.exos_orgs (id, name, slug, owner_uid) VALUES
  ('b5700000-0000-0000-0000-000000000001', 'B57 One', 'b57-one', 'b5700000-0000-0000-0000-0000000000a1'),
  ('b5700000-0000-0000-0000-000000000002', 'B57 Two', 'b57-two', 'b5700000-0000-0000-0000-0000000000a3');
INSERT INTO auth.users (id, email, email_confirmed_at) VALUES
  ('b5700000-0000-0000-0000-0000000000a4', 'b57-manager@x.com', now()),
  ('b5700000-0000-0000-0000-0000000000a5', 'b57-finance@x.com', now()),
  ('b5700000-0000-0000-0000-0000000000a6', 'b57-content@x.com', now());
INSERT INTO public.exos_org_memberships (org_id, user_id, role) VALUES
  ('b5700000-0000-0000-0000-000000000001', 'b5700000-0000-0000-0000-0000000000a1', 'owner'),
  ('b5700000-0000-0000-0000-000000000001', 'b5700000-0000-0000-0000-0000000000a2', 'scanner'),
  ('b5700000-0000-0000-0000-000000000001', 'b5700000-0000-0000-0000-0000000000a4', 'manager'),
  ('b5700000-0000-0000-0000-000000000001', 'b5700000-0000-0000-0000-0000000000a5', 'finance'),
  ('b5700000-0000-0000-0000-000000000001', 'b5700000-0000-0000-0000-0000000000a6', 'content'),
  ('b5700000-0000-0000-0000-000000000002', 'b5700000-0000-0000-0000-0000000000a3', 'owner');
-- API keys holding events:write, each created by one member: f1 owner,
-- f2 scanner, f4 manager, f5 finance, f6 content (org one); f3 org two's owner.
INSERT INTO public.exos_api_keys (id, org_id, name, key_prefix, key_hash, scopes, created_by)
SELECT ('b5700000-0000-0000-0000-0000000000f' || x.n)::uuid, x.org::uuid, 'key ' || x.n, 'sk_live_b57' || x.n,
       encode(extensions.digest('sk_live_b57_' || x.n, 'sha256'), 'hex'), ARRAY['events:read', 'events:write'],
       ('b5700000-0000-0000-0000-0000000000a' || x.n)::uuid
  FROM (VALUES ('1', 'b5700000-0000-0000-0000-000000000001'), ('2', 'b5700000-0000-0000-0000-000000000001'),
               ('4', 'b5700000-0000-0000-0000-000000000001'), ('5', 'b5700000-0000-0000-0000-000000000001'),
               ('6', 'b5700000-0000-0000-0000-000000000001'), ('3', 'b5700000-0000-0000-0000-000000000002')) x(n, org);
INSERT INTO public.exos_events (id, org_id, name, slug, status, starts_at, total_tickets, created_by) VALUES
  ('b5700000-0000-0000-0000-0000000000e1', 'b5700000-0000-0000-0000-000000000001', 'B57 Show', 'b57-show', 'published',
   now() + interval '30 days', 0, 'b5700000-0000-0000-0000-0000000000a1'),
  ('b5700000-0000-0000-0000-0000000000e2', 'b5700000-0000-0000-0000-000000000002', 'B57 Other', 'b57-other', 'published',
   now() + interval '30 days', 0, 'b5700000-0000-0000-0000-0000000000a3');
-- d1: the early-bird type (steps set in PS3/PS5); d2: hidden; d3: the old
-- schedule type (PS4); d9: org two's.
INSERT INTO public.exos_ticket_tiers (id, event_id, name, price, capacity, sold, sort_order, visibility) VALUES
  ('b5700000-0000-0000-0000-0000000000d1', 'b5700000-0000-0000-0000-0000000000e1', 'GA', 20, 100, 0, 1, 'public'),
  ('b5700000-0000-0000-0000-0000000000d2', 'b5700000-0000-0000-0000-0000000000e1', 'Secret', 15, 10, 0, 2, 'hidden'),
  ('b5700000-0000-0000-0000-0000000000d3', 'b5700000-0000-0000-0000-0000000000e1', 'Old', 20, 50, 0, 3, 'public'),
  ('b5700000-0000-0000-0000-0000000000d9', 'b5700000-0000-0000-0000-0000000000e2', 'GA', 20, 50, 0, 1, 'public');

-- Checkout, as exos-checkout does it: read the price, hold, lock, record the
-- session with the locked step, then (later) the webhook fulfils it.
CREATE OR REPLACE FUNCTION pg_temp.checkout(p_sid text, p_buyer text, p_tier uuid, p_qty int) RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE cp jsonb; v_hold uuid; v_lock jsonb;
BEGIN
  cp := public.exos_tier_current_price(p_tier, now(), 'online');
  PERFORM pg_temp.as_user(p_buyer, 'b57-' || right(p_buyer, 2) || '@x.com');
  v_hold := public.exos_create_hold('b5700000-0000-0000-0000-0000000000e1', p_tier, p_qty);
  PERFORM pg_temp.as_user(NULL, NULL);
  IF cp ->> 'step_id' IS NOT NULL THEN
    v_lock := public.exos_hold_lock_price(v_hold, (cp ->> 'step_id')::uuid, (cp ->> 'price_cents')::int);
  END IF;
  INSERT INTO public.exos_checkout_sessions (session_id, event_id, tier_id, org_id, buyer_uid, buyer_email, quantity,
                                            amount_cents, status, price_step_id)
  VALUES (p_sid, 'b5700000-0000-0000-0000-0000000000e1', p_tier, 'b5700000-0000-0000-0000-000000000001',
          p_buyer::uuid, 'b57-' || right(p_buyer, 2) || '@x.com', p_qty, (cp ->> 'price_cents')::int * p_qty, 'pending',
          (cp ->> 'step_id')::uuid);
  UPDATE public.exos_cart_holds SET checkout_session_id = p_sid WHERE id = v_hold;
  RETURN cp || jsonb_build_object('hold_id', v_hold);
END $$;

-- PS1 ------------------------------------------------------------------------
DO $$
DECLARE c jsonb; s jsonb; v_tier uuid; v_step uuid; keys jsonb; got jsonb; e jsonb; k int := 0; i int;
BEGIN
  FOR c IN SELECT x FROM jsonb_array_elements(current_setting('b57.cases')::jsonb -> 'cases') x LOOP
    k := k + 1;
    INSERT INTO public.exos_ticket_tiers (event_id, name, price, capacity, sold, sort_order, door_price_cents)
    VALUES ('b5700000-0000-0000-0000-0000000000e1', 'Parity ' || k, (c ->> 'base_price_cents')::numeric / 100, 1000, 0, 100 + k,
            (c ->> 'door_price_cents')::int)
    RETURNING id INTO v_tier;
    keys := '{}'; i := 0;
    FOR s IN SELECT x FROM jsonb_array_elements(c -> 'steps') x LOOP
      INSERT INTO public.exos_price_steps (tier_id, org_id, event_id, sort_order, name, price_cents, ends_after_count, ends_at, sold_out_at)
      VALUES (v_tier, 'b5700000-0000-0000-0000-000000000001', 'b5700000-0000-0000-0000-0000000000e1', i, coalesce(s ->> 'name', ''),
              (s ->> 'price_cents')::int, (s ->> 'ends_after_count')::int, (s ->> 'ends_at')::timestamptz, (s ->> 'sold_out_at')::timestamptz)
      RETURNING id INTO v_step;
      -- 'used' as live holds on the step (10 a hold at most).
      INSERT INTO public.exos_cart_holds (event_id, tier_id, org_id, quantity, expires_at, price_step_id)
      SELECT 'b5700000-0000-0000-0000-0000000000e1', v_tier, 'b5700000-0000-0000-0000-000000000001',
             least(10, (s ->> 'used')::int - g * 10), now() + interval '1 hour', v_step
        FROM generate_series(0, ((s ->> 'used')::int - 1) / 10) g
       WHERE (s ->> 'used')::int > 0;
      keys := keys || jsonb_build_object(v_step::text, s ->> 'key');
      i := i + 1;
    END LOOP;
    got := public.exos_tier_current_price(v_tier, (c ->> 'at')::timestamptz, c ->> 'channel');
    e := c -> 'expect';
    ASSERT (got ->> 'price_cents')::int = (e ->> 'price_cents')::int, format('PS1 %s: price %s', c ->> 'name', got);
    ASSERT got ->> 'source' = e ->> 'source', format('PS1 %s: source %s', c ->> 'name', got);
    ASSERT (keys ->> (got ->> 'step_id')) IS NOT DISTINCT FROM (e ->> 'step'), format('PS1 %s: step %s', c ->> 'name', got);
    ASSERT (got ->> 'step_index') IS NOT DISTINCT FROM (e ->> 'step_index'), format('PS1 %s: index %s', c ->> 'name', got);
    ASSERT (got ->> 'step_remaining') IS NOT DISTINCT FROM (e ->> 'step_remaining'), format('PS1 %s: remaining %s', c ->> 'name', got);
    ASSERT (got ->> 'next_price_cents') IS NOT DISTINCT FROM (e ->> 'next_price_cents'), format('PS1 %s: next %s', c ->> 'name', got);
    DELETE FROM public.exos_cart_holds WHERE tier_id = v_tier;
    DELETE FROM public.exos_ticket_tiers WHERE id = v_tier;
  END LOOP;
  ASSERT k >= 10, 'PS1 the cases file was read: ' || k;
  RAISE NOTICE 'OK  PS1 exos_tier_current_price matches the % shared parity cases', k;
END $$;

-- PS3 (before PS2: it creates the steps PS2 reads) ---------------------------
DO $$
DECLARE s text;
BEGIN
  PERFORM pg_temp.as_user('b5700000-0000-0000-0000-0000000000a1', 'b57-owner@x.com');
  s := pg_temp.st($q$SELECT public.exos_set_price_steps('b5700000-0000-0000-0000-0000000000d1',
        '[{"price_cents":2000,"ends_after_count":3},{"price_cents":2500,"ends_after_count":2}]')$q$);
  ASSERT s LIKE '22023 %last step%', 'PS3 the last step has no end: ' || s;
  s := pg_temp.st($q$SELECT public.exos_set_price_steps('b5700000-0000-0000-0000-0000000000d1',
        '[{"price_cents":2000},{"price_cents":2500}]')$q$);
  ASSERT s LIKE '22023 step 1: give it an end%', 'PS3 every other step needs an end: ' || s;
  s := pg_temp.st($q$SELECT public.exos_set_price_steps('b5700000-0000-0000-0000-0000000000d1',
        '[{"price_cents":2000,"ends_at":"2026-12-10T00:00:00Z"},{"price_cents":2500,"ends_at":"2026-12-01T00:00:00Z"},{"price_cents":3000}]')$q$);
  ASSERT s LIKE '22023 step 2: ends before an earlier step%', 'PS3 times go forward: ' || s;
  s := pg_temp.st($q$SELECT public.exos_set_price_steps('b5700000-0000-0000-0000-0000000000d1',
        '[{"price_cents":2000,"ends_after_count":3,"fee":1},{"price_cents":3000}]')$q$);
  ASSERT s LIKE '22023 step 1: unknown field fee%', 'PS3 unknown field: ' || s;
  s := pg_temp.st($q$SELECT public.exos_set_price_steps('b5700000-0000-0000-0000-0000000000d1',
        '[{"price_cents":-5,"ends_after_count":3},{"price_cents":3000}]')$q$);
  ASSERT s LIKE '22023 step 1: price_cents%', 'PS3 negative price: ' || s;
  s := pg_temp.st(format($q$SELECT public.exos_set_price_steps('b5700000-0000-0000-0000-0000000000d1', %L)$q$,
        (SELECT jsonb_agg(jsonb_build_object('price_cents', 100 * g, 'ends_after_count', 1)) || '[{"price_cents":9999}]'::jsonb
           FROM generate_series(1, 20) g)));
  ASSERT s LIKE '22023 at most 20%', 'PS3 at most 20 steps: ' || s;
  -- The real ones: Early bird $20 for 3 or until a week out, GA $25 for 2, Final $30; door $35.
  s := pg_temp.st(format($q$SELECT public.exos_set_price_steps('b5700000-0000-0000-0000-0000000000d1',
        %L, 3500, true)$q$, jsonb_build_array(
          jsonb_build_object('name', 'Early bird', 'price_cents', 2000, 'ends_after_count', 3, 'ends_at', now() + interval '7 days'),
          jsonb_build_object('name', 'GA', 'price_cents', 2500, 'ends_after_count', 2),
          jsonb_build_object('name', 'Final', 'price_cents', 3000))));
  ASSERT s = 'ok', 'PS3 a valid list saves: ' || s;
  ASSERT (SELECT count(*) FROM public.exos_price_steps WHERE tier_id = 'b5700000-0000-0000-0000-0000000000d1') = 3, 'PS3 three steps';
  ASSERT (SELECT door_price_cents FROM public.exos_ticket_tiers WHERE id = 'b5700000-0000-0000-0000-0000000000d1') = 3500, 'PS3 door price';
  PERFORM pg_temp.as_user(NULL, NULL);
  RAISE NOTICE 'OK  PS3 steps are validated (ends, order, fields, count); a good list saves';
END $$;

-- PS2 ------------------------------------------------------------------------
DO $$
DECLARE s text; n int; j jsonb;
BEGIN
  ASSERT NOT has_table_privilege('anon', 'public.exos_price_steps', 'SELECT'), 'PS2 anon reads no steps';
  ASSERT NOT has_table_privilege('authenticated', 'public.exos_price_steps', 'INSERT'), 'PS2 no direct insert';
  ASSERT NOT has_table_privilege('authenticated', 'public.exos_price_steps', 'UPDATE'), 'PS2 no direct update';
  ASSERT NOT has_table_privilege('authenticated', 'public.exos_price_steps', 'DELETE'), 'PS2 no direct delete';
  ASSERT (SELECT relrowsecurity FROM pg_class WHERE oid = 'public.exos_price_steps'::regclass), 'PS2 RLS on';
  FOREACH s IN ARRAY ARRAY['public.exos_tier_current_price(uuid,timestamptz,text)', 'public.exos_tier_price_now(uuid,text)',
      'public.exos_hold_lock_price(uuid,uuid,integer)', 'public._exos_api_price_steps(uuid,uuid,uuid)',
      'public._exos_api_price_steps_set(uuid,uuid,uuid,uuid,jsonb)', 'public._exos_price_steps_apply(uuid,jsonb)',
      'public._exos_price_step_used(uuid)', 'public._exos_price_steps_json(uuid)',
      'public.exos_current_price(public.exos_ticket_tiers)'] LOOP
    ASSERT NOT has_function_privilege('anon', s, 'EXECUTE'), 'PS2 anon can''t run ' || s;
    ASSERT NOT has_function_privilege('authenticated', s, 'EXECUTE'), 'PS2 authenticated can''t run ' || s;
  END LOOP;
  ASSERT has_function_privilege('service_role', 'public.exos_tier_current_price(uuid,timestamptz,text)', 'EXECUTE'), 'PS2 service role prices';
  ASSERT has_function_privilege('anon', 'public.exos_public_tier_price(uuid)', 'EXECUTE'), 'PS2 buyers read the public price';
  ASSERT NOT has_function_privilege('anon', 'public.exos_set_price_steps(uuid,jsonb,integer,boolean)', 'EXECUTE'), 'PS2 anon writes nothing';
  -- Hidden types' prices stay behind their code.
  ASSERT public.exos_public_tier_price('b5700000-0000-0000-0000-0000000000d2') IS NULL, 'PS2 hidden type: no public price';
  ASSERT (public.exos_public_tier_price('b5700000-0000-0000-0000-0000000000d1') ->> 'price_cents')::int = 2000, 'PS2 public price';
END $$;
SELECT pg_temp.as_user('b5700000-0000-0000-0000-0000000000a3', 'b57-owner2@x.com');
SET LOCAL ROLE authenticated;
DO $$
DECLARE n int; s text;
BEGIN
  SELECT count(*) INTO n FROM public.exos_price_steps WHERE tier_id = 'b5700000-0000-0000-0000-0000000000d1';
  ASSERT n = 0, 'PS2 another org sees no steps: ' || n;
  s := pg_temp.st($q$SELECT public.exos_set_price_steps('b5700000-0000-0000-0000-0000000000d1', '[]')$q$);
  ASSERT s LIKE 'P0002 %', 'PS2 another org can''t write steps: ' || s;
  s := pg_temp.st($q$SELECT public.exos_tier_price_steps('b5700000-0000-0000-0000-0000000000d1')$q$);
  ASSERT s LIKE 'P0002 %', 'PS2 another org can''t read them by RPC: ' || s;
  s := pg_temp.st($q$INSERT INTO public.exos_price_steps (tier_id, org_id, event_id, price_cents)
        VALUES ('b5700000-0000-0000-0000-0000000000d9', 'b5700000-0000-0000-0000-000000000002', 'b5700000-0000-0000-0000-0000000000e2', 1)$q$);
  ASSERT s LIKE '42501 %', 'PS2 not even its own org writes the table directly: ' || s;
END $$;
RESET ROLE;
SELECT pg_temp.as_user('b5700000-0000-0000-0000-0000000000a2', 'b57-scanner@x.com');
SET LOCAL ROLE authenticated;
DO $$
DECLARE n int; s text;
BEGIN
  SELECT count(*) INTO n FROM public.exos_price_steps WHERE tier_id = 'b5700000-0000-0000-0000-0000000000d1';
  ASSERT n = 0, 'PS2 a scanner sees no prices config: ' || n;
  s := pg_temp.st($q$SELECT public.exos_set_price_steps('b5700000-0000-0000-0000-0000000000d1', '[]')$q$);
  ASSERT s LIKE 'P0002 %', 'PS2 a scanner can''t change prices: ' || s;
END $$;
RESET ROLE;
SELECT pg_temp.as_user('b5700000-0000-0000-0000-0000000000a1', 'b57-owner@x.com');
SET LOCAL ROLE authenticated;
DO $$
DECLARE n int; j jsonb;
BEGIN
  SELECT count(*) INTO n FROM public.exos_price_steps WHERE tier_id = 'b5700000-0000-0000-0000-0000000000d1';
  ASSERT n = 3, 'PS2 the owner reads its steps: ' || n;
  j := public.exos_tier_price_steps('b5700000-0000-0000-0000-0000000000d1');
  ASSERT jsonb_array_length(j -> 'steps') = 3 AND (j -> 'current' ->> 'price_cents')::int = 2000, 'PS2 editor read: ' || j;
END $$;
RESET ROLE;
SELECT pg_temp.as_user(NULL, NULL);
SET LOCAL ROLE anon;
DO $$
DECLARE v numeric; j jsonb; n int;
BEGIN
  SELECT price INTO v FROM public.exos_public_tiers WHERE id = 'b5700000-0000-0000-0000-0000000000d1';
  ASSERT v = 20, 'PS2 anon reads the step price on the view: ' || v;
  SELECT price_step, door_price_cents INTO j, n FROM public.exos_public_price_steps WHERE tier_id = 'b5700000-0000-0000-0000-0000000000d1';
  ASSERT j ->> 'step_name' = 'Early bird' AND (j ->> 'next_price_cents')::int = 2500 AND n = 3500, 'PS2 anon step view: ' || j;
  SELECT count(*) INTO n FROM public.exos_public_price_steps WHERE tier_id = 'b5700000-0000-0000-0000-0000000000d2';
  ASSERT n = 0, 'PS2 hidden type not in the public step view';
  RAISE NOTICE 'OK  PS2 RLS, grants, cross-org isolation; buyers read public prices only';
END $$;
RESET ROLE;

-- PS4 ------------------------------------------------------------------------
DO $$
DECLARE s text; n int; v jsonb; c int;
BEGIN
  -- An old client writes a schedule: $20 now, $25 from +5 days, $30 from +10 days.
  UPDATE public.exos_ticket_tiers
     SET price_schedule = jsonb_build_array(
           jsonb_build_object('startsAt', to_char((now() + interval '10 days') AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'), 'price', 30),
           jsonb_build_object('startsAt', 'not a date', 'price', 1),
           jsonb_build_object('startsAt', to_char((now() + interval '5 days') AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'), 'price', 25))
   WHERE id = 'b5700000-0000-0000-0000-0000000000d3';
  SELECT count(*), count(*) FILTER (WHERE ends_after_count IS NULL) INTO n, c
    FROM public.exos_price_steps WHERE tier_id = 'b5700000-0000-0000-0000-0000000000d3';
  ASSERT n = 3 AND c = 3, format('PS4 the schedule is three time steps (malformed one skipped): %s/%s', n, c);
  ASSERT (public.exos_tier_current_price('b5700000-0000-0000-0000-0000000000d3', now()) ->> 'price_cents')::int = 2000, 'PS4 now: 20';
  ASSERT (public.exos_tier_current_price('b5700000-0000-0000-0000-0000000000d3', now() + interval '6 days') ->> 'price_cents')::int = 2500, 'PS4 +6d: 25';
  ASSERT (public.exos_tier_current_price('b5700000-0000-0000-0000-0000000000d3', now() + interval '11 days') ->> 'price_cents')::int = 3000, 'PS4 +11d: 30';
  -- A price write moves the opening step.
  UPDATE public.exos_ticket_tiers SET price = 18 WHERE id = 'b5700000-0000-0000-0000-0000000000d3';
  ASSERT (public.exos_tier_current_price('b5700000-0000-0000-0000-0000000000d3') ->> 'price_cents')::int = 1800, 'PS4 price write';
  -- Steps saved by the editor write the schedule back (time-only form).
  PERFORM pg_temp.as_user('b5700000-0000-0000-0000-0000000000a1', 'b57-owner@x.com');
  PERFORM public.exos_set_price_steps('b5700000-0000-0000-0000-0000000000d3', jsonb_build_array(
    jsonb_build_object('price_cents', 1500, 'ends_at', '2027-01-01T00:00:00Z'),
    jsonb_build_object('price_cents', 2250)));
  SELECT price_schedule INTO v FROM public.exos_ticket_tiers WHERE id = 'b5700000-0000-0000-0000-0000000000d3';
  ASSERT v = '[{"price": 22.5, "startsAt": "2027-01-01T00:00:00.000Z"}]'::jsonb, 'PS4 schedule written back: ' || v;
  ASSERT (SELECT price FROM public.exos_ticket_tiers WHERE id = 'b5700000-0000-0000-0000-0000000000d3') = 15, 'PS4 price = first step';
  -- A count step has no schedule form: [] and schedule writes refused.
  PERFORM public.exos_set_price_steps('b5700000-0000-0000-0000-0000000000d3', jsonb_build_array(
    jsonb_build_object('price_cents', 1500, 'ends_after_count', 10), jsonb_build_object('price_cents', 2250)));
  SELECT price_schedule INTO v FROM public.exos_ticket_tiers WHERE id = 'b5700000-0000-0000-0000-0000000000d3';
  ASSERT v = '[]'::jsonb, 'PS4 count steps: empty schedule: ' || v;
  PERFORM pg_temp.as_user(NULL, NULL);
  s := pg_temp.st($q$UPDATE public.exos_ticket_tiers SET price_schedule = '[{"startsAt":"2027-02-01T00:00:00Z","price":40}]'
                      WHERE id = 'b5700000-0000-0000-0000-0000000000d3'$q$);
  ASSERT s LIKE '22023 price_schedule:%price steps%', 'PS4 schedule write refused on count steps: ' || s;
  UPDATE public.exos_ticket_tiers SET price = 16 WHERE id = 'b5700000-0000-0000-0000-0000000000d3';
  ASSERT (SELECT price_cents FROM public.exos_price_steps WHERE tier_id = 'b5700000-0000-0000-0000-0000000000d3' ORDER BY sort_order LIMIT 1) = 1600,
    'PS4 a price write sets the first count step';
  -- [] removes them: the type's own price again.
  PERFORM pg_temp.as_user('b5700000-0000-0000-0000-0000000000a1', 'b57-owner@x.com');
  PERFORM public.exos_set_price_steps('b5700000-0000-0000-0000-0000000000d3', '[]');
  PERFORM pg_temp.as_user(NULL, NULL);
  ASSERT public.exos_tier_current_price('b5700000-0000-0000-0000-0000000000d3') ->> 'source' = 'base', 'PS4 no steps: base';
  RAISE NOTICE 'OK  PS4 price_schedule and steps stay one path (both ways; count steps refuse schedules)';
END $$;

-- PS5 + PS6 + PS7 ------------------------------------------------------------
-- d1: Early bird $20 x3 (or a week), GA $25 x2, Final $30; door $35.
DO $$
DECLARE a jsonb; b jsonb; c jsonb; s text; ids uuid[]; v_eb uuid; v_ga uuid; v_rem int;
BEGIN
  SELECT id INTO v_eb FROM public.exos_price_steps WHERE tier_id = 'b5700000-0000-0000-0000-0000000000d1' AND name = 'Early bird';
  SELECT id INTO v_ga FROM public.exos_price_steps WHERE tier_id = 'b5700000-0000-0000-0000-0000000000d1' AND name = 'GA';
  -- Fan 1 buys 2 early birds: priced, held, locked.
  a := pg_temp.checkout('b57-s1', 'b5700000-0000-0000-0000-0000000000b1', 'b5700000-0000-0000-0000-0000000000d1', 2);
  ASSERT (a ->> 'price_cents')::int = 2000 AND (a ->> 'step_id')::uuid = v_eb, 'PS5 fan 1 at the early bird: ' || a;
  ASSERT (SELECT price_step_id = v_eb AND unit_price_cents = 2000 FROM public.exos_cart_holds WHERE id = (a ->> 'hold_id')::uuid),
    'PS5 the hold carries the locked step';
  -- The hold counts: 1 early bird left for everyone else.
  v_rem := (public.exos_tier_current_price('b5700000-0000-0000-0000-0000000000d1') ->> 'step_remaining')::int;
  ASSERT v_rem = 1, 'PS5 held places count against the step: ' || v_rem;

  -- PS6: fan 2 asks for 2 early birds with 1 left: the lock refuses (cap).
  b := public.exos_tier_current_price('b5700000-0000-0000-0000-0000000000d1');
  PERFORM pg_temp.as_user('b5700000-0000-0000-0000-0000000000b2', 'b57-b2@x.com');
  c := jsonb_build_object('hold', public.exos_create_hold('b5700000-0000-0000-0000-0000000000e1', 'b5700000-0000-0000-0000-0000000000d1', 2));
  PERFORM pg_temp.as_user(NULL, NULL);
  s := pg_temp.st(format('SELECT public.exos_hold_lock_price(%L, %L, 2000)', c ->> 'hold', b ->> 'step_id'));
  ASSERT s LIKE 'XP410 price_step_remaining: only 1 left%', 'PS6 an order past the step''s remaining is capped: ' || s;
  ASSERT (SELECT price_step_id FROM public.exos_cart_holds WHERE id = (c ->> 'hold')::uuid) IS NULL, 'PS6 nothing stamped';
  UPDATE public.exos_cart_holds SET status = 'released', released_at = now() WHERE id = (c ->> 'hold')::uuid;
  RAISE NOTICE 'OK  PS6 boundary rule: an order bigger than the step''s remaining is refused with what''s left (cap)';

  -- Fan 2 takes the last early bird.
  b := pg_temp.checkout('b57-s2', 'b5700000-0000-0000-0000-0000000000b2', 'b5700000-0000-0000-0000-0000000000d1', 1);
  ASSERT (b ->> 'price_cents')::int = 2000, 'PS5 fan 2 gets the last early bird: ' || b;
  -- Early bird all held: everyone else sees GA now (advance by count).
  c := public.exos_tier_current_price('b5700000-0000-0000-0000-0000000000d1');
  ASSERT (c ->> 'step_id')::uuid = v_ga AND (c ->> 'price_cents')::int = 2500, 'PS5 advanced to GA by count: ' || c;

  -- PS7: a stale price (a third buyer who saw $20 a moment ago) is refused.
  -- (A new hold retires the same buyer's old cart, so it's someone else.)
  PERFORM pg_temp.as_user('b5700000-0000-0000-0000-0000000000a3', 'b57-owner2@x.com');
  c := jsonb_build_object('hold', public.exos_create_hold('b5700000-0000-0000-0000-0000000000e1', 'b5700000-0000-0000-0000-0000000000d1', 1));
  PERFORM pg_temp.as_user(NULL, NULL);
  s := pg_temp.st(format('SELECT public.exos_hold_lock_price(%L, %L, 2000)', c ->> 'hold', v_eb));
  ASSERT s LIKE 'XP409 price_changed: the price is now 2500%', 'PS7 a stale price is refused: ' || s;
  UPDATE public.exos_cart_holds SET status = 'released', released_at = now() WHERE id = (c ->> 'hold')::uuid;

  -- Both pay; the webhook mints at the locked $20 although the step moved on.
  ids := public.exos_fulfill_checkout('b57-s1');
  ASSERT array_length(ids, 1) = 2, 'PS5 fan 1 minted';
  ids := public.exos_fulfill_checkout('b57-s2');
  ASSERT array_length(ids, 1) = 1, 'PS5 fan 2 minted';
  ASSERT (SELECT bool_and(price_step_id = v_eb AND price_paid = 20) FROM public.exos_tickets
           WHERE order_ref IN ('b57-s1', 'b57-s2')), 'PS7 minted at the locked early-bird price, on its step';
  ASSERT (SELECT sold_out_at IS NOT NULL FROM public.exos_price_steps WHERE id = v_eb), 'PS5 early bird sold: latched';
  RAISE NOTICE 'OK  PS5 advance by count (holds count, mints latch); PS7 locked price survives the advance, stale price refused';
END $$;

-- PS8 ------------------------------------------------------------------------
DO $$
DECLARE c jsonb; v_rem int; v_id uuid;
BEGIN
  -- Time: a type whose early bird ended yesterday sells at the next step.
  PERFORM pg_temp.as_user('b5700000-0000-0000-0000-0000000000a1', 'b57-owner@x.com');
  PERFORM public.exos_set_price_steps('b5700000-0000-0000-0000-0000000000d2', jsonb_build_array(
    jsonb_build_object('price_cents', 1000, 'ends_at', now() - interval '1 day'),
    jsonb_build_object('price_cents', 1500)));
  PERFORM pg_temp.as_user(NULL, NULL);
  c := public.exos_tier_current_price('b5700000-0000-0000-0000-0000000000d2');
  ASSERT (c ->> 'price_cents')::int = 1500 AND (c ->> 'step_index')::int = 2, 'PS8 advanced by time: ' || c;
  ASSERT (public.exos_tier_current_price('b5700000-0000-0000-0000-0000000000d2', now() - interval '2 days') ->> 'price_cents')::int = 1000,
    'PS8 before the end time: the first step';

  -- Door: $35 at POS, while online is GA $25 with 2 left.
  c := public.exos_tier_current_price('b5700000-0000-0000-0000-0000000000d1', now(), 'pos');
  ASSERT (c ->> 'price_cents')::int = 3500 AND c ->> 'source' = 'door' AND c ->> 'step_id' IS NULL, 'PS8 door price at POS: ' || c;
  v_rem := (public.exos_tier_current_price('b5700000-0000-0000-0000-0000000000d1') ->> 'step_remaining')::int;
  -- A door sale at the door price takes no GA place.
  INSERT INTO public.exos_tickets (event_id, org_id, tier_id, tier_name, buyer_id, owner_id, status, barcode_secret, price_paid, channel_source)
  VALUES ('b5700000-0000-0000-0000-0000000000e1', 'b5700000-0000-0000-0000-000000000001', 'b5700000-0000-0000-0000-0000000000d1',
          'GA', 'b5700000-0000-0000-0000-0000000000a1', 'b5700000-0000-0000-0000-0000000000a1', 'active', gen_random_uuid()::text, 35, 'door')
  RETURNING id INTO v_id;
  ASSERT (SELECT price_step_id FROM public.exos_tickets WHERE id = v_id) IS NULL, 'PS8 a door sale is on no step';
  ASSERT (public.exos_tier_current_price('b5700000-0000-0000-0000-0000000000d1') ->> 'step_remaining')::int = v_rem,
    'PS8 GA places unchanged by the door sale';
  -- A comp takes no step place either.
  INSERT INTO public.exos_tickets (event_id, org_id, tier_id, tier_name, buyer_id, owner_id, status, barcode_secret, price_paid, channel_source)
  VALUES ('b5700000-0000-0000-0000-0000000000e1', 'b5700000-0000-0000-0000-000000000001', 'b5700000-0000-0000-0000-0000000000d1',
          'GA', 'b5700000-0000-0000-0000-0000000000a1', 'b5700000-0000-0000-0000-0000000000a1', 'active', gen_random_uuid()::text, 0, 'boxoffice')
  RETURNING id INTO v_id;
  ASSERT (SELECT price_step_id FROM public.exos_tickets WHERE id = v_id) IS NULL, 'PS8 a comp is on no step';
  RAISE NOTICE 'OK  PS8 advance by time; the door price at POS; door sales and comps use no step places';
END $$;

-- PS9 ------------------------------------------------------------------------
DO $$
DECLARE c jsonb; v_ga uuid; ids uuid[];
BEGIN
  SELECT id INTO v_ga FROM public.exos_price_steps WHERE tier_id = 'b5700000-0000-0000-0000-0000000000d1' AND name = 'GA';
  -- One GA sold, then refunded before GA sold out: the place comes back.
  c := pg_temp.checkout('b57-s3', 'b5700000-0000-0000-0000-0000000000b1', 'b5700000-0000-0000-0000-0000000000d1', 1);
  ASSERT (c ->> 'step_id')::uuid = v_ga, 'PS9 GA order: ' || c;
  ids := public.exos_fulfill_checkout('b57-s3');
  ASSERT (public.exos_tier_current_price('b5700000-0000-0000-0000-0000000000d1') ->> 'step_remaining')::int = 1, 'PS9 one GA left';
  PERFORM public.exos_refund_checkout('b57-s3');
  ASSERT (public.exos_tier_current_price('b5700000-0000-0000-0000-0000000000d1') ->> 'step_remaining')::int = 2, 'PS9 refund frees the GA place';
  -- The early bird sold out (latched): refunding one doesn't bring $20 back.
  PERFORM public.exos_refund_checkout('b57-s2');
  c := public.exos_tier_current_price('b5700000-0000-0000-0000-0000000000d1');
  ASSERT (c ->> 'price_cents')::int = 2500, 'PS9 a latched step stays ended after a refund: ' || c;
  RAISE NOTICE 'OK  PS9 refunds free a live step''s place; a sold-out (latched) step doesn''t reopen';
END $$;

-- PS10 -----------------------------------------------------------------------
DO $$
DECLARE v_view numeric; v_api numeric; v_ev numeric; v_disc numeric; v_feed numeric; v_rr numeric; u jsonb; v_all int;
BEGIN
  SELECT price INTO v_view FROM public.exos_public_tiers WHERE id = 'b5700000-0000-0000-0000-0000000000d1';
  SELECT (x ->> 'price')::numeric INTO v_api FROM jsonb_array_elements(public._exos_api_public_tiers_json('b5700000-0000-0000-0000-0000000000e1')) x
   WHERE x ->> 'id' = 'b5700000-0000-0000-0000-0000000000d1';
  SELECT (x ->> 'price')::numeric INTO v_ev FROM jsonb_array_elements(public._exos_api_event_json('b5700000-0000-0000-0000-0000000000e1') -> 'tiers') x
   WHERE x ->> 'id' = 'b5700000-0000-0000-0000-0000000000d1';
  SELECT (x ->> 'price')::numeric INTO v_disc FROM jsonb_array_elements(public._exos_discovery_event_json('b5700000-0000-0000-0000-0000000000e1') -> 'tiers') x
   WHERE x ->> 'id' = 'b5700000-0000-0000-0000-0000000000d1';
  SELECT (x ->> 'price')::numeric INTO v_feed
    FROM public.exos_events e, jsonb_array_elements(public._exos_listing_feed_event(e) -> 'tiers') x
   WHERE e.id = 'b5700000-0000-0000-0000-0000000000e1' AND x ->> 'id' = 'b5700000-0000-0000-0000-0000000000d1';
  v_rr := public.exos_rr_tier_price('b5700000-0000-0000-0000-0000000000d1');
  u := public._exos_partner_unit_price('b5700000-0000-0000-0000-0000000000d1', false);
  ASSERT v_view = 25 AND v_api = 25 AND v_ev = 25 AND v_disc = 25 AND v_rr = 25,
    format('PS10 every reader shows the GA step: view %s api %s event %s discovery %s partner %s', v_view, v_api, v_ev, v_disc, v_rr);
  ASSERT v_feed IS NULL OR v_feed = 25, 'PS10 listing feed: ' || coalesce(v_feed::text, 'null');
  ASSERT (u ->> 'unit_cents')::int = 2500, 'PS10 partner unit price: ' || u;
  -- All-in: the SQL mirror of allInCents on the step's price (no fee rules or tax here).
  v_all := public.exos_all_in_unit_cents(2500, public.exos_tier_exclusive_tax_percent('b5700000-0000-0000-0000-0000000000d1'),
                                         public.exos_tier_passed_on_fees('b5700000-0000-0000-0000-0000000000d1'));
  ASSERT (u ->> 'all_in_cents')::int = v_all, 'PS10 partner all-in = all-in of the step price';
  -- What checkout charges for one ticket now (the locked unit) = what they show.
  ASSERT (pg_temp.checkout('b57-s4', 'b5700000-0000-0000-0000-0000000000b2', 'b5700000-0000-0000-0000-0000000000d1', 1) ->> 'price_cents')::int
         = round(v_view * 100), 'PS10 checkout charges the shown price';
  ASSERT (SELECT amount_cents FROM public.exos_checkout_sessions WHERE session_id = 'b57-s4') = 2500, 'PS10 session amount';
  RAISE NOTICE 'OK  PS10 view, public API, partner API, discovery, partner sales and checkout show one price';
END $$;

-- PS11 -----------------------------------------------------------------------
DO $$
DECLARE s text; j jsonb;
BEGIN
  s := pg_temp.st($q$SELECT public._exos_api_price_steps('b5700000-0000-0000-0000-000000000002',
        'b5700000-0000-0000-0000-0000000000e1', 'b5700000-0000-0000-0000-0000000000d1')$q$);
  ASSERT s LIKE 'P0002 %', 'PS11 another org''s key reads nothing: ' || s;
  s := pg_temp.st($q$SELECT public._exos_api_price_steps_set('b5700000-0000-0000-0000-000000000002', 'b5700000-0000-0000-0000-0000000000f3',
        'b5700000-0000-0000-0000-0000000000e1', 'b5700000-0000-0000-0000-0000000000d1', '{"steps":[]}')$q$);
  ASSERT s LIKE 'P0002 %', 'PS11 another org''s key writes nothing: ' || s;
  s := pg_temp.st($q$SELECT public._exos_api_price_steps_set('b5700000-0000-0000-0000-000000000001', 'b5700000-0000-0000-0000-0000000000f1',
        'b5700000-0000-0000-0000-0000000000e1', 'b5700000-0000-0000-0000-0000000000d1', '{"door":1}')$q$);
  ASSERT s LIKE '22023 unknown field door%', 'PS11 unknown field: ' || s;
  s := pg_temp.st($q$SELECT public._exos_api_price_steps_set('b5700000-0000-0000-0000-000000000001', 'b5700000-0000-0000-0000-0000000000f1',
        'b5700000-0000-0000-0000-0000000000e1', 'b5700000-0000-0000-0000-0000000000d1', '{"door_price_cents":-1}')$q$);
  ASSERT s LIKE '22023 door_price_cents%', 'PS11 bad door price: ' || s;
  j := public._exos_api_price_steps_set('b5700000-0000-0000-0000-000000000001', 'b5700000-0000-0000-0000-0000000000f1', 'b5700000-0000-0000-0000-0000000000e1',
         'b5700000-0000-0000-0000-0000000000d9', '{"steps":[]}');
  RAISE EXCEPTION 'PS11 FAIL: org one wrote org two''s type';
EXCEPTION WHEN no_data_found THEN
  j := public._exos_api_price_steps('b5700000-0000-0000-0000-000000000001', 'b5700000-0000-0000-0000-0000000000e1',
         'b5700000-0000-0000-0000-0000000000d1');
  ASSERT jsonb_array_length(j -> 'steps') = 3 AND (j -> 'steps' -> 0 ->> 'sold')::int = 2, 'PS11 steps with counts: ' || j;
  j := public._exos_api_price_steps_set('b5700000-0000-0000-0000-000000000001', 'b5700000-0000-0000-0000-0000000000f1', 'b5700000-0000-0000-0000-0000000000e1',
         'b5700000-0000-0000-0000-0000000000d1', '{"door_price_cents":null}');
  ASSERT j -> 'door_price_cents' = 'null'::jsonb, 'PS11 door price cleared: ' || j;
  RAISE NOTICE 'OK  PS11 API cores: org-scoped reads and writes, door price, validation';
END $$;

-- PS12 -----------------------------------------------------------------------
-- A key acts as its creator (mig 20261104180000): a price change is a
-- ticket-type edit, owner / manager only. Every lesser role's key holds
-- events:write here and is refused (42501) in SQL; owner and manager pass.
DO $$
DECLARE s text; k text; j jsonb;
BEGIN
  FOREACH k IN ARRAY ARRAY['2', '5', '6'] LOOP
    s := pg_temp.st(format($q$SELECT public._exos_api_price_steps_set('b5700000-0000-0000-0000-000000000001',
          'b5700000-0000-0000-0000-0000000000f%s', 'b5700000-0000-0000-0000-0000000000e1', 'b5700000-0000-0000-0000-0000000000d1',
          '{"steps":[]}')$q$, k));
    ASSERT s LIKE '42501 %owner or manager%', format('PS12 key of role %s sets no steps: %s', k, s);
    s := pg_temp.st(format($q$SELECT public._exos_api_price_steps_set('b5700000-0000-0000-0000-000000000001',
          'b5700000-0000-0000-0000-0000000000f%s', 'b5700000-0000-0000-0000-0000000000e1', 'b5700000-0000-0000-0000-0000000000d1',
          '{"door_price_cents":1}')$q$, k));
    ASSERT s LIKE '42501 %', format('PS12 key of role %s sets no door price: %s', k, s);
    -- Reads: no role rule (as GET ticket-type under events:read).
    ASSERT jsonb_array_length(public._exos_api_price_steps('b5700000-0000-0000-0000-000000000001', 'b5700000-0000-0000-0000-0000000000e1',
             'b5700000-0000-0000-0000-0000000000d1') -> 'steps') = 3, 'PS12 reads';
  END LOOP;
  ASSERT (SELECT count(*) FROM public.exos_price_steps WHERE tier_id = 'b5700000-0000-0000-0000-0000000000d1') = 3, 'PS12 steps untouched';
  s := pg_temp.st($q$SELECT public._exos_api_price_steps_set('b5700000-0000-0000-0000-000000000001',
        'b5700000-0000-0000-0000-0000000000f3', 'b5700000-0000-0000-0000-0000000000e1', 'b5700000-0000-0000-0000-0000000000d1',
        '{"door_price_cents":1}')$q$);
  ASSERT s LIKE '42501 %', 'PS12 another org''s key: ' || s;
  j := public._exos_api_price_steps_set('b5700000-0000-0000-0000-000000000001', 'b5700000-0000-0000-0000-0000000000f4',
        'b5700000-0000-0000-0000-0000000000e1', 'b5700000-0000-0000-0000-0000000000d1', '{"door_price_cents":3600}');
  ASSERT (j ->> 'door_price_cents')::int = 3600, 'PS12 the manager''s key sets the door price';
  j := public._exos_api_price_steps_set('b5700000-0000-0000-0000-000000000001', 'b5700000-0000-0000-0000-0000000000f1',
        'b5700000-0000-0000-0000-0000000000e1', 'b5700000-0000-0000-0000-0000000000d1', '{"door_price_cents":3500}');
  ASSERT (j ->> 'door_price_cents')::int = 3500, 'PS12 the owner''s key too';
  RAISE NOTICE 'OK  PS12 price-step and door-price writes need a key whose creator is an owner or manager (scanner, finance, content: 42501)';
END $$;

-- PS13 -----------------------------------------------------------------------
-- door_price_cents through PATCH ticket-type (exos_api_write, same rule), and
-- exos-distribute's computed field reads the step price.
CREATE OR REPLACE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql STABLE AS $$
  SELECT coalesce(nullif(current_setting('app.uid', true), ''),
                  nullif(current_setting('request.jwt.claim.sub', true), ''),
                  nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'sub')::uuid
$$;
SELECT set_config('app.uid', '', true);
DO $$
DECLARE s text; j jsonb; v numeric;
BEGIN
  ASSERT position('/* exos: door price */' in pg_get_functiondef('public.exos_api_write(uuid,text,text,jsonb,text)'::regprocedure)) > 0,
    'PS13 the door price patch is in exos_api_write';
  j := public.exos_api_write('b5700000-0000-0000-0000-0000000000f1', 'ticket_type.update', 'b5700000-0000-0000-0000-0000000000d1',
        '{"ticket_type":{"door_price_cents":4000}}');
  ASSERT (j ->> 'door_price_cents')::int = 4000, 'PS13 the owner''s key sets the door price on the ticket type: ' || j;
  ASSERT (public.exos_tier_current_price('b5700000-0000-0000-0000-0000000000d1', now(), 'door') ->> 'price_cents')::int = 4000,
    'PS13 the door channel sells at it';
  s := pg_temp.st($q$SELECT public.exos_api_write('b5700000-0000-0000-0000-0000000000f5', 'ticket_type.update',
        'b5700000-0000-0000-0000-0000000000d1', '{"ticket_type":{"door_price_cents":1}}')$q$);
  ASSERT s LIKE '42501 %', 'PS13 a finance key can''t: ' || s;
  s := pg_temp.st($q$SELECT public.exos_api_write('b5700000-0000-0000-0000-0000000000f1', 'ticket_type.update',
        'b5700000-0000-0000-0000-0000000000d1', '{"ticket_type":{"door_price_cents":-1}}')$q$);
  ASSERT s LIKE '23514 %', 'PS13 no negative door price: ' || s;
  SELECT public.exos_current_price(t) INTO v FROM public.exos_ticket_tiers t WHERE t.id = 'b5700000-0000-0000-0000-0000000000d1';
  ASSERT v = (public.exos_tier_current_price('b5700000-0000-0000-0000-0000000000d1') ->> 'price_cents')::numeric / 100,
    'PS13 the computed field is the current step price: ' || v;
  ASSERT v <> (SELECT price FROM public.exos_ticket_tiers WHERE id = 'b5700000-0000-0000-0000-0000000000d1'),
    'PS13 and not the raw opening price';
  RAISE NOTICE 'OK  PS13 door price via PATCH ticket-type (owner / manager); exos_current_price for exos-distribute';
END $$;

ROLLBACK;
\echo test_price_steps: all passed
