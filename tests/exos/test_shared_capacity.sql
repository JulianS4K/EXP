-- ============================================================================
-- Shared capacity (mig 20261106120000, claude/exos-capacity-pricing). DICE
-- TicketPool = exos_quotas. Self-contained (5c5 prefix), rolled back.
--   SC1 parity: exos_effective_available on the shared cases
--       (tests/exos/fixtures/shared_capacity_cases.json), which
--       src/lib/sharedCapacity.test.ts runs against sharedAvailability
--   SC2 RLS + grants: org staff only; another org sees and writes nothing;
--       the new SQL cores are service-role only
--   SC3 no unlimited pools: NULL / negative refused, 0 closes; never below
--       what's sold (dashboard writes); a type can't push a pool over
--   SC4 one limit across types through the real paths: holds (two buyers,
--       two types), a staff comp, checkout fulfilment, a type in two pools,
--       a refund freeing the place; public JSON + view say sold out when a
--       pool is full
--   SC5 allocation 0 closes the pool everywhere; publish blockers (closed
--       pool on an on-sale type, a pool with no types, a pool with no size)
--   SC6 API cores: create / update / list / delete, allocation required,
--       other events' types and other orgs refused, never below sold
--   SC7 the lock-order patches are in place
-- ============================================================================
\set ON_ERROR_STOP on
\if :{?fixtures}
\else
\set fixtures tests/exos/fixtures
\endif
\set cases_file :fixtures '/shared_capacity_cases.json'
\set cases `cat :cases_file`
BEGIN;
\o /dev/null
SELECT set_config('sc.cases', :'cases', true);
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
  ('5c500000-0000-0000-0000-0000000000a1', '5c5-owner@x.com', now()),
  ('5c500000-0000-0000-0000-0000000000a3', '5c5-owner2@x.com', now()),
  ('5c500000-0000-0000-0000-0000000000b1', '5c5-fan1@x.com', now()),
  ('5c500000-0000-0000-0000-0000000000b2', '5c5-fan2@x.com', now()),
  ('5c500000-0000-0000-0000-0000000000b3', '5c5-fan3@x.com', now());
INSERT INTO public.exos_orgs (id, name, slug, owner_uid) VALUES
  ('5c500000-0000-0000-0000-000000000001', '5C5 One', '5c5-one', '5c500000-0000-0000-0000-0000000000a1'),
  ('5c500000-0000-0000-0000-000000000002', '5C5 Two', '5c5-two', '5c500000-0000-0000-0000-0000000000a3');
INSERT INTO public.exos_org_memberships (org_id, user_id, role) VALUES
  ('5c500000-0000-0000-0000-000000000001', '5c500000-0000-0000-0000-0000000000a1', 'owner'),
  ('5c500000-0000-0000-0000-000000000002', '5c500000-0000-0000-0000-0000000000a3', 'owner');
INSERT INTO public.exos_events (id, org_id, name, slug, status, starts_at, total_tickets, created_by) VALUES
  ('5c500000-0000-0000-0000-0000000000e1', '5c500000-0000-0000-0000-000000000001', '5C5 Room', '5c5-room', 'published',
   now() + interval '30 days', 0, '5c500000-0000-0000-0000-0000000000a1'),
  ('5c500000-0000-0000-0000-0000000000e2', '5c500000-0000-0000-0000-000000000002', '5C5 Other', '5c5-other', 'published',
   now() + interval '30 days', 0, '5c500000-0000-0000-0000-0000000000a3'),
  ('5c500000-0000-0000-0000-0000000000e3', '5c500000-0000-0000-0000-000000000001', '5C5 Parity', '5c5-parity', 'draft',
   now() + interval '30 days', 0, '5c500000-0000-0000-0000-0000000000a1');
INSERT INTO public.exos_ticket_tiers (id, event_id, name, price, capacity, sold, sort_order) VALUES
  ('5c500000-0000-0000-0000-0000000000d1', '5c500000-0000-0000-0000-0000000000e1', 'GA', 20, 10, 0, 1),
  ('5c500000-0000-0000-0000-0000000000d2', '5c500000-0000-0000-0000-0000000000e1', 'VIP', 50, 3, 0, 2),
  ('5c500000-0000-0000-0000-0000000000d3', '5c500000-0000-0000-0000-0000000000e1', 'Student', 10, 10, 0, 3),
  ('5c500000-0000-0000-0000-0000000000d9', '5c500000-0000-0000-0000-0000000000e2', 'GA', 20, 10, 0, 1);

CREATE OR REPLACE FUNCTION pg_temp.avail(p_tier text) RETURNS int LANGUAGE sql AS $$
  SELECT public.exos_effective_available(p_tier::uuid);
$$;
CREATE OR REPLACE FUNCTION pg_temp.json_tier(p_tier text) RETURNS jsonb LANGUAGE sql AS $$
  SELECT x FROM jsonb_array_elements(public._exos_api_public_tiers_json('5c500000-0000-0000-0000-0000000000e1')) x
   WHERE x ->> 'id' = p_tier;
$$;
CREATE OR REPLACE FUNCTION pg_temp.hold(p_buyer text, p_tier text, p_qty int) RETURNS uuid LANGUAGE plpgsql AS $$
DECLARE v uuid;
BEGIN
  PERFORM pg_temp.as_user(p_buyer, '5c5-' || right(p_buyer, 2) || '@x.com');
  v := public.exos_create_hold('5c500000-0000-0000-0000-0000000000e1', p_tier::uuid, p_qty);
  PERFORM pg_temp.as_user(NULL, NULL);
  RETURN v;
END $$;

-- SC1 ------------------------------------------------------------------------
DO $$
DECLARE c jsonb; t jsonb; p jsonb; m text; v_tier uuid; v_pool uuid; ids jsonb; k int := 0; got int; n int;
BEGIN
  FOR c IN SELECT x FROM jsonb_array_elements(current_setting('sc.cases')::jsonb -> 'cases') x LOOP
    k := k + 1;
    ids := '{}';
    FOR t IN SELECT x FROM jsonb_array_elements(c -> 'types') x LOOP
      INSERT INTO public.exos_ticket_tiers (event_id, name, price, capacity, sold, sort_order)
      VALUES ('5c500000-0000-0000-0000-0000000000e3', 'C' || k || ' ' || (t ->> 'key'), 10, (t ->> 'capacity')::int,
              (t ->> 'sold')::int, 100 + k)
      RETURNING id INTO v_tier;
      ids := ids || jsonb_build_object(t ->> 'key', v_tier);
      INSERT INTO public.exos_tickets (event_id, org_id, tier_id, tier_name, status, barcode_secret, price_paid, channel_source)
      SELECT '5c500000-0000-0000-0000-0000000000e3', '5c500000-0000-0000-0000-000000000001', v_tier, 'x', 'active',
             gen_random_uuid()::text, 10, 'vibepass'
        FROM generate_series(1, (t ->> 'sold')::int);
      IF (t ->> 'held')::int > 0 THEN
        INSERT INTO public.exos_cart_holds (event_id, tier_id, org_id, quantity, expires_at)
        VALUES ('5c500000-0000-0000-0000-0000000000e3', v_tier, '5c500000-0000-0000-0000-000000000001', (t ->> 'held')::int,
                now() + interval '1 hour');
      END IF;
    END LOOP;
    FOR p IN SELECT x FROM jsonb_array_elements(c -> 'pools') x LOOP
      INSERT INTO public.exos_quotas (event_id, org_id, name, size, closed)
      VALUES ('5c500000-0000-0000-0000-0000000000e3', '5c500000-0000-0000-0000-000000000001', 'C' || k || ' ' || (p ->> 'key'),
              (p ->> 'allocation')::int, (p ->> 'closed')::boolean)
      RETURNING id INTO v_pool;
      FOR m IN SELECT jsonb_array_elements_text(p -> 'members') LOOP
        INSERT INTO public.exos_quota_tiers (quota_id, tier_id) VALUES (v_pool, (ids ->> m)::uuid);
      END LOOP;
    END LOOP;
    FOR m IN SELECT jsonb_object_keys(c -> 'expect') LOOP
      got := public.exos_effective_available((ids ->> m)::uuid);
      ASSERT got = (c -> 'expect' ->> m)::int, format('SC1 %s: %s has %s, want %s', c ->> 'name', m, got, c -> 'expect' ->> m);
    END LOOP;
    DELETE FROM public.exos_quotas WHERE event_id = '5c500000-0000-0000-0000-0000000000e3';
    DELETE FROM public.exos_cart_holds WHERE event_id = '5c500000-0000-0000-0000-0000000000e3';
    DELETE FROM public.exos_tickets WHERE event_id = '5c500000-0000-0000-0000-0000000000e3';
    DELETE FROM public.exos_ticket_tiers WHERE event_id = '5c500000-0000-0000-0000-0000000000e3';
  END LOOP;
  ASSERT k >= 8, 'SC1 the cases file was read: ' || k;
  RAISE NOTICE 'OK  SC1 exos_effective_available matches the % shared parity cases', k;
END $$;

-- The pools of SC2-SC5: Room 5 across all three, Balcony 2 on VIP only.
INSERT INTO public.exos_quotas (id, event_id, org_id, name, size) VALUES
  ('5c500000-0000-0000-0000-0000000000c1', '5c500000-0000-0000-0000-0000000000e1', '5c500000-0000-0000-0000-000000000001', 'Room', 5),
  ('5c500000-0000-0000-0000-0000000000c2', '5c500000-0000-0000-0000-0000000000e1', '5c500000-0000-0000-0000-000000000001', 'Balcony', 2);
INSERT INTO public.exos_quota_tiers (quota_id, tier_id) VALUES
  ('5c500000-0000-0000-0000-0000000000c1', '5c500000-0000-0000-0000-0000000000d1'),
  ('5c500000-0000-0000-0000-0000000000c1', '5c500000-0000-0000-0000-0000000000d2'),
  ('5c500000-0000-0000-0000-0000000000c1', '5c500000-0000-0000-0000-0000000000d3'),
  ('5c500000-0000-0000-0000-0000000000c2', '5c500000-0000-0000-0000-0000000000d2');

-- SC2 ------------------------------------------------------------------------
DO $$
DECLARE f text;
BEGIN
  ASSERT NOT has_table_privilege('anon', 'public.exos_quotas', 'SELECT'), 'SC2 anon reads no pools';
  ASSERT NOT has_table_privilege('anon', 'public.exos_quota_tiers', 'SELECT'), 'SC2 anon reads no members';
  FOREACH f IN ARRAY ARRAY['public._exos_quota_used(uuid)', 'public._exos_shared_limit_blockers(uuid)',
      'public._exos_api_capacity_pool_json(uuid)', 'public._exos_api_capacity_pools(uuid,uuid)',
      'public._exos_api_capacity_pool_write(uuid,uuid,uuid,jsonb,boolean)'] LOOP
    ASSERT NOT has_function_privilege('anon', f, 'EXECUTE'), 'SC2 anon can''t run ' || f;
    ASSERT NOT has_function_privilege('authenticated', f, 'EXECUTE'), 'SC2 authenticated can''t run ' || f;
    ASSERT has_function_privilege('service_role', f, 'EXECUTE'), 'SC2 service role runs ' || f;
  END LOOP;
END $$;
SELECT pg_temp.as_user('5c500000-0000-0000-0000-0000000000a3', '5c5-owner2@x.com');
SET LOCAL ROLE authenticated;
DO $$
DECLARE n int; s text;
BEGIN
  SELECT count(*) INTO n FROM public.exos_quotas WHERE event_id = '5c500000-0000-0000-0000-0000000000e1';
  ASSERT n = 0, 'SC2 another org sees no pools: ' || n;
  SELECT count(*) INTO n FROM public.exos_quota_tiers WHERE quota_id = '5c500000-0000-0000-0000-0000000000c1';
  ASSERT n = 0, 'SC2 another org sees no members: ' || n;
  s := pg_temp.st($q$INSERT INTO public.exos_quotas (event_id, org_id, name, size)
        VALUES ('5c500000-0000-0000-0000-0000000000e1', '5c500000-0000-0000-0000-000000000002', 'Steal', 0)$q$);
  ASSERT s LIKE '42501 %', 'SC2 another org can''t put a pool on this event: ' || s;
  UPDATE public.exos_quotas SET size = 0 WHERE id = '5c500000-0000-0000-0000-0000000000c1';
  GET DIAGNOSTICS n = ROW_COUNT;
  ASSERT n = 0, 'SC2 another org can''t close this pool';
  s := pg_temp.st($q$SELECT public.exos_event_quotas('5c500000-0000-0000-0000-0000000000e1')$q$);
  ASSERT s LIKE '42501 %', 'SC2 the editor read is the org''s: ' || s;
END $$;
RESET ROLE;
SELECT pg_temp.as_user('5c500000-0000-0000-0000-0000000000a1', '5c5-owner@x.com');
SET LOCAL ROLE authenticated;
DO $$
DECLARE n int;
BEGIN
  SELECT count(*) INTO n FROM public.exos_quotas WHERE event_id = '5c500000-0000-0000-0000-0000000000e1';
  ASSERT n = 2, 'SC2 the owner sees its pools: ' || n;
  RAISE NOTICE 'OK  SC2 RLS, grants, cross-org isolation';
END $$;

-- SC3 (still the owner, as the dashboard) ------------------------------------
DO $$
DECLARE s text;
BEGIN
  s := pg_temp.st($q$INSERT INTO public.exos_quotas (event_id, org_id, name, size)
        VALUES ('5c500000-0000-0000-0000-0000000000e1', '5c500000-0000-0000-0000-000000000001', 'Unlimited', NULL)$q$);
  ASSERT s LIKE '22023 shared limit: give it a size%', 'SC3 no unlimited pool: ' || s;
  s := pg_temp.st($q$INSERT INTO public.exos_quotas (event_id, org_id, name, size)
        VALUES ('5c500000-0000-0000-0000-0000000000e1', '5c500000-0000-0000-0000-000000000001', 'Minus', -1)$q$);
  ASSERT s LIKE '22023 %', 'SC3 no negative pool: ' || s;
  s := pg_temp.st($q$UPDATE public.exos_quotas SET size = NULL WHERE id = '5c500000-0000-0000-0000-0000000000c2'$q$);
  ASSERT s LIKE '22023 %', 'SC3 can''t make a pool unlimited later: ' || s;
END $$;
RESET ROLE;
SELECT pg_temp.as_user(NULL, NULL);

-- SC4 ------------------------------------------------------------------------
INSERT INTO public.exos_checkout_sessions (session_id, event_id, tier_id, org_id, buyer_uid, buyer_email, quantity, amount_cents, status)
VALUES ('5c5-s1', '5c500000-0000-0000-0000-0000000000e1', '5c500000-0000-0000-0000-0000000000d1', '5c500000-0000-0000-0000-000000000001',
        '5c500000-0000-0000-0000-0000000000b1', '5c5-b1@x.com', 2, 4000, 'pending');
DO $$
DECLARE h1 uuid; h2 uuid; s text; ids uuid[]; j jsonb; v int;
BEGIN
  ASSERT pg_temp.avail('5c500000-0000-0000-0000-0000000000d1') = 5, 'SC4 GA: room of 5';
  ASSERT pg_temp.avail('5c500000-0000-0000-0000-0000000000d2') = 2, 'SC4 VIP: balcony of 2 (type in two pools)';
  -- Fan 1 holds 2 GA.
  h1 := pg_temp.hold('5c500000-0000-0000-0000-0000000000b1', '5c500000-0000-0000-0000-0000000000d1', 2);
  UPDATE public.exos_cart_holds SET checkout_session_id = '5c5-s1' WHERE id = h1;
  ASSERT pg_temp.avail('5c500000-0000-0000-0000-0000000000d3') = 3, 'SC4 a GA hold counts against Student''s room';
  -- The owner comps 1 Student (box office, price 0).
  PERFORM pg_temp.as_user('5c500000-0000-0000-0000-0000000000a1', '5c5-owner@x.com');
  ids := public.exos_mint_tickets('5c500000-0000-0000-0000-0000000000e1', '5c500000-0000-0000-0000-0000000000d3', 1, 'comp-5c5', 0);
  PERFORM pg_temp.as_user(NULL, NULL);
  ASSERT pg_temp.avail('5c500000-0000-0000-0000-0000000000d1') = 2, 'SC4 the comp counts: 2 left in the room';
  -- Fan 2 holds the 2 VIP: the room is full.
  h2 := pg_temp.hold('5c500000-0000-0000-0000-0000000000b2', '5c500000-0000-0000-0000-0000000000d2', 2);
  ASSERT pg_temp.avail('5c500000-0000-0000-0000-0000000000d1') = 0 AND pg_temp.avail('5c500000-0000-0000-0000-0000000000d3') = 0,
    'SC4 room full: GA and Student at 0 though their own caps have room';
  j := pg_temp.json_tier('5c500000-0000-0000-0000-0000000000d1');
  ASSERT (j ->> 'sold_out')::boolean AND (j ->> 'available')::int = 0, 'SC4 public JSON: sold out when the pool is: ' || j;
  SELECT available INTO v FROM public.exos_public_tiers WHERE id = '5c500000-0000-0000-0000-0000000000d3';
  ASSERT v = 0, 'SC4 public view (storefront, feeds, MCP): 0 left';
  -- Fan 3 can't take a place.
  s := pg_temp.st($q$SELECT pg_temp.hold('5c500000-0000-0000-0000-0000000000b3', '5c500000-0000-0000-0000-0000000000d3', 1)$q$);
  ASSERT s LIKE '23514 %not enough%', 'SC4 the next hold is refused: ' || s;
  -- Fan 1 pays: the webhook mints inside the pool.
  ids := public.exos_fulfill_checkout('5c5-s1');
  ASSERT array_length(ids, 1) = 2, 'SC4 fan 1 minted';
  ASSERT public._exos_quota_used('5c500000-0000-0000-0000-0000000000c1') = 3, 'SC4 room sold 3';
  -- Fan 1 is refunded: the 2 places come back to every type in the room.
  PERFORM public.exos_refund_checkout('5c5-s1');
  ASSERT pg_temp.avail('5c500000-0000-0000-0000-0000000000d3') = 2, 'SC4 the refund frees 2 places for Student';
  j := pg_temp.json_tier('5c500000-0000-0000-0000-0000000000d3');
  ASSERT NOT (j ->> 'sold_out')::boolean, 'SC4 not sold out after the refund: ' || j;
  UPDATE public.exos_cart_holds SET status = 'released', released_at = now() WHERE id = h2;
  RAISE NOTICE 'OK  SC4 one limit across types: holds, comps, fulfilment, two pools, refund; sold out shown';
END $$;

-- SC3 continued: the floor (as the owner, dashboard writes) -------------------
SELECT pg_temp.as_user('5c500000-0000-0000-0000-0000000000a1', '5c5-owner@x.com');
SET LOCAL ROLE authenticated;
DO $$
DECLARE s text;
BEGIN
  -- The room has sold 1 (the comp).
  s := pg_temp.st($q$UPDATE public.exos_quotas SET size = 2 WHERE id = '5c500000-0000-0000-0000-0000000000c1'$q$);
  ASSERT s = 'ok', 'SC3 down to 2 is fine: ' || s;
  s := pg_temp.st($q$INSERT INTO public.exos_quotas (event_id, org_id, name, size)
        VALUES ('5c500000-0000-0000-0000-0000000000e1', '5c500000-0000-0000-0000-000000000001', 'Tiny', 1)$q$);
  ASSERT s = 'ok', 'SC3 a pool of 1: ' || s;
  -- Student has sold 1: it fits a pool of 1; GA (sold 0) on top too; nothing more.
  s := pg_temp.st($q$INSERT INTO public.exos_quota_tiers (quota_id, tier_id)
        SELECT id, '5c500000-0000-0000-0000-0000000000d3' FROM public.exos_quotas WHERE name = 'Tiny'$q$);
  ASSERT s = 'ok', 'SC3 Student fits Tiny: ' || s;
  UPDATE public.exos_quotas SET size = 0 WHERE name = 'Tiny';
  s := pg_temp.st($q$UPDATE public.exos_quotas SET size = 1 WHERE name = 'Tiny'$q$);
  ASSERT s = 'ok', 'SC3 back to 1 = sold: ' || s;
  s := pg_temp.st($q$UPDATE public.exos_quotas SET size = 1 WHERE id = '5c500000-0000-0000-0000-0000000000c1'$q$);
  ASSERT s = 'ok', 'SC3 room at its sold count: ' || s;
  s := pg_temp.st($q$UPDATE public.exos_quotas SET size = 0 WHERE id = '5c500000-0000-0000-0000-0000000000c1'$q$);
  ASSERT s = 'ok', 'SC3 0 closes even with sales: ' || s;
  UPDATE public.exos_quotas SET size = 5 WHERE id = '5c500000-0000-0000-0000-0000000000c1';
  DELETE FROM public.exos_quotas WHERE name = 'Tiny';
END $$;
RESET ROLE;
SELECT pg_temp.as_user(NULL, NULL);
-- Below sold: three more Student comps, then the owner tries 2.
DO $$
DECLARE s text;
BEGIN
  PERFORM pg_temp.as_user('5c500000-0000-0000-0000-0000000000a1', '5c5-owner@x.com');
  PERFORM public.exos_mint_tickets('5c500000-0000-0000-0000-0000000000e1', '5c500000-0000-0000-0000-0000000000d3', 2, 'comp-5c5-b', 0);
  PERFORM pg_temp.as_user(NULL, NULL);
END $$;
SELECT pg_temp.as_user('5c500000-0000-0000-0000-0000000000a1', '5c5-owner@x.com');
SET LOCAL ROLE authenticated;
DO $$
DECLARE s text;
BEGIN
  s := pg_temp.st($q$UPDATE public.exos_quotas SET size = 2 WHERE id = '5c500000-0000-0000-0000-0000000000c1'$q$);
  ASSERT s LIKE '23514 shared limit "Room" has already sold 3%', 'SC3 never below sold: ' || s;
  s := pg_temp.st($q$INSERT INTO public.exos_quotas (event_id, org_id, name, size)
        VALUES ('5c500000-0000-0000-0000-0000000000e1', '5c500000-0000-0000-0000-000000000001', 'Small', 2)$q$);
  s := pg_temp.st($q$INSERT INTO public.exos_quota_tiers (quota_id, tier_id)
        SELECT id, '5c500000-0000-0000-0000-0000000000d3' FROM public.exos_quotas WHERE name = 'Small'$q$);
  ASSERT s LIKE '23514 %would count 3 sold against a size of 2%', 'SC3 a type can''t push a pool over: ' || s;
  DELETE FROM public.exos_quotas WHERE name = 'Small';
  RAISE NOTICE 'OK  SC3 no unlimited pools; 0 closes; never below what''s sold';
END $$;
RESET ROLE;
SELECT pg_temp.as_user(NULL, NULL);

-- SC5 ------------------------------------------------------------------------
DO $$
DECLARE b jsonb; j jsonb;
BEGIN
  ASSERT NOT public._exos_event_publish_blockers('5c500000-0000-0000-0000-0000000000e1') @> '[{"field":"shared_limits"}]',
    'SC5 no pool blockers while the pools are fine';
  UPDATE public.exos_quotas SET size = 0 WHERE id = '5c500000-0000-0000-0000-0000000000c2';
  ASSERT pg_temp.avail('5c500000-0000-0000-0000-0000000000d2') = 0, 'SC5 VIP closed by its closed Balcony';
  ASSERT pg_temp.avail('5c500000-0000-0000-0000-0000000000d1') > 0, 'SC5 GA unaffected';
  j := pg_temp.json_tier('5c500000-0000-0000-0000-0000000000d2');
  ASSERT (j ->> 'sold_out')::boolean, 'SC5 closed pool: sold out in public JSON';
  b := public._exos_event_publish_blockers('5c500000-0000-0000-0000-0000000000e1');
  ASSERT b @> '[{"code":"ticket_type_in_closed_shared_limit"}]' AND b::text LIKE '%VIP%Balcony%',
    'SC5 blocker: on-sale type in a closed pool: ' || b;
  -- A pool with no types, and one from before sizes were required.
  INSERT INTO public.exos_quotas (event_id, org_id, name, size) VALUES
    ('5c500000-0000-0000-0000-0000000000e1', '5c500000-0000-0000-0000-000000000001', 'Leftover', 10);
  ALTER TABLE public.exos_quotas DISABLE TRIGGER exos_quotas_size_rules;
  INSERT INTO public.exos_quotas (event_id, org_id, name, size) VALUES
    ('5c500000-0000-0000-0000-0000000000e1', '5c500000-0000-0000-0000-000000000001', 'Legacy', NULL);
  ALTER TABLE public.exos_quotas ENABLE TRIGGER exos_quotas_size_rules;
  b := public._exos_event_publish_blockers('5c500000-0000-0000-0000-0000000000e1');
  ASSERT b @> '[{"code":"shared_limit_no_types"}]' AND b @> '[{"code":"shared_limit_needs_size"}]', 'SC5 empty + sizeless: ' || b;
  -- Closing the type itself instead clears the closed-pool blocker.
  UPDATE public.exos_ticket_tiers SET capacity = 0 WHERE id = '5c500000-0000-0000-0000-0000000000d2';
  ASSERT NOT public._exos_event_publish_blockers('5c500000-0000-0000-0000-0000000000e1') @> '[{"code":"ticket_type_in_closed_shared_limit"}]',
    'SC5 a closed type in a closed pool is fine';
  UPDATE public.exos_ticket_tiers SET capacity = 3 WHERE id = '5c500000-0000-0000-0000-0000000000d2';
  DELETE FROM public.exos_quotas WHERE name IN ('Leftover', 'Legacy');
  UPDATE public.exos_quotas SET size = 2 WHERE id = '5c500000-0000-0000-0000-0000000000c2';
  RAISE NOTICE 'OK  SC5 allocation 0 closes a pool (sold out); publish blockers for closed / empty / sizeless pools';
END $$;

-- SC6 ------------------------------------------------------------------------
DO $$
DECLARE s text; j jsonb; v_id uuid;
BEGIN
  s := pg_temp.st($q$SELECT public._exos_api_capacity_pools('5c500000-0000-0000-0000-000000000002', '5c500000-0000-0000-0000-0000000000e1')$q$);
  ASSERT s LIKE 'P0002 %', 'SC6 another org''s key lists nothing: ' || s;
  s := pg_temp.st($q$SELECT public._exos_api_capacity_pool_write('5c500000-0000-0000-0000-000000000002', '5c500000-0000-0000-0000-0000000000e1',
        '5c500000-0000-0000-0000-0000000000c1', '{"allocation":0}')$q$);
  ASSERT s LIKE 'P0002 %', 'SC6 another org''s key closes nothing: ' || s;
  s := pg_temp.st($q$SELECT public._exos_api_capacity_pool_write('5c500000-0000-0000-0000-000000000001', '5c500000-0000-0000-0000-0000000000e1',
        NULL, '{"name":"No size"}')$q$);
  ASSERT s LIKE '22023 allocation is required%', 'SC6 allocation required: ' || s;
  s := pg_temp.st($q$SELECT public._exos_api_capacity_pool_write('5c500000-0000-0000-0000-000000000001', '5c500000-0000-0000-0000-0000000000e1',
        NULL, '{"name":"Null","allocation":null}')$q$);
  ASSERT s LIKE '22023 allocation must be%', 'SC6 no unlimited: ' || s;
  s := pg_temp.st($q$SELECT public._exos_api_capacity_pool_write('5c500000-0000-0000-0000-000000000001', '5c500000-0000-0000-0000-0000000000e1',
        NULL, '{"name":"Cross","allocation":5,"ticket_type_ids":["5c500000-0000-0000-0000-0000000000d9"]}')$q$);
  ASSERT s LIKE '22023 a ticket type%not on this event%', 'SC6 other event''s type: ' || s;
  s := pg_temp.st($q$SELECT public._exos_api_capacity_pool_write('5c500000-0000-0000-0000-000000000001', '5c500000-0000-0000-0000-0000000000e1',
        NULL, '{"name":"X","allocation":5,"size":1}')$q$);
  ASSERT s LIKE '22023 unknown field size%', 'SC6 unknown field: ' || s;
  j := public._exos_api_capacity_pool_write('5c500000-0000-0000-0000-000000000001', '5c500000-0000-0000-0000-0000000000e1',
        NULL, '{"name":"Floor","allocation":4,"ticket_type_ids":["5c500000-0000-0000-0000-0000000000d1","5c500000-0000-0000-0000-0000000000d3"]}');
  v_id := (j ->> 'id')::uuid;
  ASSERT (j ->> 'allocation')::int = 4 AND (j ->> 'sold')::int = 3 AND (j ->> 'remaining')::int = 1
         AND jsonb_array_length(j -> 'ticket_type_ids') = 2, 'SC6 created with counts: ' || j;
  s := pg_temp.st(format($q$SELECT public._exos_api_capacity_pool_write('5c500000-0000-0000-0000-000000000001',
        '5c500000-0000-0000-0000-0000000000e1', %L, '{"allocation":2}')$q$, v_id));
  ASSERT s LIKE '23514 this shared limit has already sold 3%', 'SC6 never below sold: ' || s;
  j := public._exos_api_capacity_pool_write('5c500000-0000-0000-0000-000000000001', '5c500000-0000-0000-0000-0000000000e1',
        v_id, '{"allocation":0,"ticket_type_ids":["5c500000-0000-0000-0000-0000000000d1"]}');
  ASSERT (j ->> 'closed')::boolean AND (j ->> 'sold_out')::boolean AND jsonb_array_length(j -> 'ticket_type_ids') = 1,
    'SC6 closed with 0, members replaced: ' || j;
  ASSERT pg_temp.avail('5c500000-0000-0000-0000-0000000000d1') = 0, 'SC6 GA closed by the API pool';
  j := public._exos_api_capacity_pools('5c500000-0000-0000-0000-000000000001', '5c500000-0000-0000-0000-0000000000e1');
  ASSERT jsonb_array_length(j) = 3, 'SC6 list: ' || j;
  j := public._exos_api_capacity_pool_write('5c500000-0000-0000-0000-000000000001', '5c500000-0000-0000-0000-0000000000e1', v_id, NULL, true);
  ASSERT (j ->> 'deleted')::boolean AND pg_temp.avail('5c500000-0000-0000-0000-0000000000d1') > 0, 'SC6 deleted, GA open again';
  RAISE NOTICE 'OK  SC6 API cores: create / update / close / list / delete, org-scoped, validated';
END $$;

-- SC7 ------------------------------------------------------------------------
DO $$
DECLARE f text;
BEGIN
  FOREACH f IN ARRAY ARRAY['public.exos_assert_quota(uuid,integer)', 'public.exos_create_hold(uuid,uuid,integer,integer,text)',
      'public.exos_create_guest_hold(uuid,uuid,integer,text,text,text)'] LOOP
    ASSERT position('/* exos: pool lock order */' in pg_get_functiondef(f::regprocedure)) > 0, 'SC7 lock order patch lost: ' || f;
  END LOOP;
  ASSERT position('/* exos: shared limit blockers */' in pg_get_functiondef('public._exos_event_publish_blockers(uuid)'::regprocedure)) > 0,
    'SC7 publish blocker patch';
  ASSERT position('/* exos: shared limits sold out */' in pg_get_functiondef('public._exos_api_public_tiers_json(uuid)'::regprocedure)) > 0,
    'SC7 public JSON patch';
  RAISE NOTICE 'OK  SC7 patches present (pool lock order, blockers, public JSON)';
END $$;

ROLLBACK;
\echo test_shared_capacity: all passed
