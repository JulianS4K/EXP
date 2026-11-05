-- ============================================================================
-- Partner reservations and price steps (mig 20261107120000,
-- claude/exos-partner-steps). Self-contained (b58 prefix), rolled back.
--   PT1  grants and markers: the reservation core stays service-role only;
--        the new patches are in the live bodies next to every earlier one
--   PT2  a partner reservation locks the early-bird price: the line, the
--        holds (price_step_id + unit_price_cents) and the step's count
--   PT3  CAP: a line over the step's remainder is XP410 price_step_remaining
--        (DETAIL remaining / price_cents / tier_id); the /build quote too
--   PT4  the step advances mid-reservation (time passes, or the organizer
--        re-saves the steps): complete still mints at the locked price, on
--        the locked step
--   PT5  expiry (lazy and by the sweep) and cancellation free the step's count
--   PT6  a checkout after the partner took the last early birds is told the
--        price changed; a partner after a checkout took them pays the next one
--   PT7  organizer reservations (API key, /organizer-reservations) the same
--   PT8  comps take no step place
--   PT9  a multi-type reservation over two shared pools completes, and
--        complete locks every pool before it re-checks any type
--   PT10 RLS and cross-org isolation are unchanged
-- ============================================================================
\set ON_ERROR_STOP on
BEGIN;

CREATE OR REPLACE FUNCTION pg_temp.as_user(p_uid text, p_email text) RETURNS void LANGUAGE sql AS $$
  SELECT set_config('app.uid', coalesce(p_uid, ''), true), set_config('app.jwt', json_build_object('email', p_email)::text, true);
$$;
-- 'ok', or the SQLSTATE, the message and the DETAIL of the error.
CREATE OR REPLACE FUNCTION pg_temp.st(p_sql text) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE v_state text; v_msg text; v_detail text;
BEGIN
  EXECUTE p_sql;
  RETURN jsonb_build_object('state', 'ok');
EXCEPTION WHEN OTHERS THEN
  GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT, v_detail = PG_EXCEPTION_DETAIL;
  RETURN jsonb_build_object('state', v_state, 'message', v_msg, 'detail', nullif(v_detail, ''));
END $$;

INSERT INTO auth.users (id, email, email_confirmed_at) VALUES
  ('b5800000-0000-0000-0000-0000000000a1', 'b58-owner@x.com', now()),
  ('b5800000-0000-0000-0000-0000000000a2', 'b58-finance@x.com', now()),
  ('b5800000-0000-0000-0000-0000000000a3', 'b58-owner2@x.com', now()),
  ('b5800000-0000-0000-0000-0000000000b1', 'b58-fan1@x.com', now());
INSERT INTO public.exos_orgs (id, name, slug, owner_uid) VALUES
  ('b5800000-0000-0000-0000-000000000001', 'B58 One', 'b58-one', 'b5800000-0000-0000-0000-0000000000a1'),
  ('b5800000-0000-0000-0000-000000000002', 'B58 Two', 'b58-two', 'b5800000-0000-0000-0000-0000000000a3');
INSERT INTO public.exos_org_memberships (org_id, user_id, role) VALUES
  ('b5800000-0000-0000-0000-000000000001', 'b5800000-0000-0000-0000-0000000000a1', 'owner'),
  ('b5800000-0000-0000-0000-000000000001', 'b5800000-0000-0000-0000-0000000000a2', 'finance'),
  ('b5800000-0000-0000-0000-000000000002', 'b5800000-0000-0000-0000-0000000000a3', 'owner');
INSERT INTO public.exos_events (id, org_id, name, slug, status, starts_at, total_tickets, tickets_sold, currency, created_by) VALUES
  ('b5800000-0000-0000-0000-0000000000e1', 'b5800000-0000-0000-0000-000000000001', 'B58 Show', 'b58-show', 'published',
   now() + interval '10 days', 0, 0, 'usd', 'b5800000-0000-0000-0000-0000000000a1'),
  ('b5800000-0000-0000-0000-0000000000e2', 'b5800000-0000-0000-0000-000000000002', 'B58 Elsewhere', 'b58-else', 'published',
   now() + interval '10 days', 0, 0, 'usd', 'b5800000-0000-0000-0000-0000000000a3');
-- d1 GA (steps: early bird $20 x4, then $30), d2 VIP (no steps), d3 Late (steps, for PT4b),
-- d4 Org (steps, for the organizer, PT7), d5 Comp (steps; comps, PT8), d6 A / d7 B (pools, PT9),
-- d9 org 2's GA.
INSERT INTO public.exos_ticket_tiers (id, event_id, name, price, capacity, sold, visibility, sort_order) VALUES
  ('b5800000-0000-0000-0000-0000000000d1', 'b5800000-0000-0000-0000-0000000000e1', 'GA', 20, 100, 0, 'public', 1),
  ('b5800000-0000-0000-0000-0000000000d2', 'b5800000-0000-0000-0000-0000000000e1', 'VIP', 50, 20, 0, 'public', 2),
  ('b5800000-0000-0000-0000-0000000000d3', 'b5800000-0000-0000-0000-0000000000e1', 'Late', 15, 50, 0, 'public', 3),
  ('b5800000-0000-0000-0000-0000000000d4', 'b5800000-0000-0000-0000-0000000000e1', 'Box', 10, 50, 0, 'hidden', 4),
  ('b5800000-0000-0000-0000-0000000000d5', 'b5800000-0000-0000-0000-0000000000e1', 'Comp', 12, 50, 0, 'public', 5),
  ('b5800000-0000-0000-0000-0000000000d6', 'b5800000-0000-0000-0000-0000000000e1', 'Pool A', 30, 50, 0, 'public', 6),
  ('b5800000-0000-0000-0000-0000000000d7', 'b5800000-0000-0000-0000-0000000000e1', 'Pool B', 40, 50, 0, 'public', 7),
  ('b5800000-0000-0000-0000-0000000000d9', 'b5800000-0000-0000-0000-0000000000e2', 'Other GA', 20, 50, 0, 'public', 1);
INSERT INTO public.exos_tier_distribution (tier_id, event_id, org_id, enabled)
SELECT t.id, t.event_id, e.org_id, true FROM public.exos_ticket_tiers t JOIN public.exos_events e ON e.id = t.event_id
 WHERE t.id::text LIKE 'b5800000-%' AND t.id <> 'b5800000-0000-0000-0000-0000000000d4';
-- Partners: p1 (org 1, inventory + comps), p9 (org 2). An org-1 API key by the owner (organizer reservations).
INSERT INTO public.exos_distribution_partners (id, org_id, label, partner_type, key_prefix, key_hash, scopes) VALUES
  ('b5800000-0000-0000-0000-0000000000f1', 'b5800000-0000-0000-0000-000000000001', 'B58 StubHub', 'stubhub',
   'dk_live_b58b58b5', repeat('b1', 32), ARRAY['inventory', 'comps']),
  ('b5800000-0000-0000-0000-0000000000f9', 'b5800000-0000-0000-0000-000000000002', 'B58 Other', 'vivid',
   'dk_live_b58b58b9', repeat('b9', 32), ARRAY['inventory']);
INSERT INTO public.exos_api_keys (id, org_id, name, key_prefix, key_hash, scopes, created_by) VALUES
  ('b5800000-0000-0000-0000-0000000000c1', 'b5800000-0000-0000-0000-000000000001', 'Box office', 'sk_live_b58b58b5',
   repeat('c1', 32), ARRAY['tickets:write'], 'b5800000-0000-0000-0000-0000000000a1');

-- Steps through the owner's editor (exos_set_price_steps).
SELECT pg_temp.as_user('b5800000-0000-0000-0000-0000000000a1', 'b58-owner@x.com');
\o /dev/null
SELECT public.exos_set_price_steps(x.id, x.steps) FROM (VALUES
  ('b5800000-0000-0000-0000-0000000000d1'::uuid, '[{"name":"Early bird","price_cents":2000,"ends_after_count":4},{"name":"GA","price_cents":3000}]'::jsonb),
  ('b5800000-0000-0000-0000-0000000000d3'::uuid, '[{"name":"Early","price_cents":1500,"ends_after_count":10},{"name":"Late","price_cents":2500}]'::jsonb),
  ('b5800000-0000-0000-0000-0000000000d4'::uuid, '[{"name":"Early","price_cents":1000,"ends_after_count":3},{"name":"Later","price_cents":1800}]'::jsonb),
  ('b5800000-0000-0000-0000-0000000000d5'::uuid, '[{"name":"Early","price_cents":1200,"ends_after_count":2},{"name":"Later","price_cents":2200}]'::jsonb)
) AS x(id, steps);
\o
SELECT pg_temp.as_user(NULL, NULL);

CREATE TEMP TABLE b58 (k text PRIMARY KEY, v text) ON COMMIT DROP;
-- A partner (p1) or organizer (API key) reservation of one line.
CREATE FUNCTION pg_temp.line(p_tier text, p_qty int) RETURNS jsonb LANGUAGE sql AS $$
  SELECT jsonb_build_array(jsonb_build_object('ticket_type_id', 'b5800000-0000-0000-0000-0000000000' || p_tier, 'quantity', p_qty))
$$;
CREATE FUNCTION pg_temp.reserve(p_lines jsonb, p_org_key boolean DEFAULT false, p_dry boolean DEFAULT false) RETURNS jsonb LANGUAGE sql AS $$
  SELECT public._exos_partner_reserve('b5800000-0000-0000-0000-000000000001', 'b5800000-0000-0000-0000-0000000000e1',
    CASE WHEN p_org_key THEN NULL ELSE 'b5800000-0000-0000-0000-0000000000f1'::uuid END,
    CASE WHEN p_org_key THEN 'b5800000-0000-0000-0000-0000000000c1'::uuid END, p_lines, '{}'::jsonb, false, p_dry)
$$;
CREATE FUNCTION pg_temp.complete(p_token text, p_org_key boolean DEFAULT false) RETURNS jsonb LANGUAGE sql AS $$
  SELECT public._exos_partner_reservation_complete('b5800000-0000-0000-0000-000000000001',
    CASE WHEN p_org_key THEN NULL ELSE 'b5800000-0000-0000-0000-0000000000f1'::uuid END, p_token, NULL, 'https://exos.test')
$$;
CREATE FUNCTION pg_temp.cur(p_tier text) RETURNS jsonb LANGUAGE sql AS $$
  SELECT public.exos_tier_current_price(('b5800000-0000-0000-0000-0000000000' || p_tier)::uuid, now(), 'online')
$$;
CREATE FUNCTION pg_temp.step(p_tier text, p_idx int) RETURNS uuid LANGUAGE sql AS $$
  SELECT id FROM public.exos_price_steps WHERE tier_id = ('b5800000-0000-0000-0000-0000000000' || p_tier)::uuid
   ORDER BY sort_order, id OFFSET p_idx - 1 LIMIT 1
$$;

-- PT1 -----------------------------------------------------------------------
DO $$
DECLARE f text; r record; v_lost text := '';
BEGIN
  FOREACH f IN ARRAY ARRAY[
    'public._exos_partner_reserve(uuid,uuid,uuid,uuid,jsonb,jsonb,boolean,boolean)',
    'public._exos_partner_reservation_complete(uuid,uuid,text,jsonb,text)'] LOOP
    ASSERT NOT has_function_privilege('anon', f, 'EXECUTE'), 'PT1 anon can call ' || f;
    ASSERT NOT has_function_privilege('authenticated', f, 'EXECUTE'), 'PT1 authenticated can call ' || f;
    ASSERT has_function_privilege('service_role', f, 'EXECUTE'), 'PT1 service role can''t call ' || f;
    ASSERT EXISTS (SELECT 1 FROM pg_proc p, unnest(p.proconfig) c
                    WHERE p.oid = to_regprocedure(f) AND p.prosecdef AND c LIKE 'search_path=%pg_temp%'), 'PT1 definer + search_path ' || f;
  END LOOP;
  FOR r IN SELECT * FROM (VALUES
    -- this migration
    ('public._exos_partner_reserve(uuid,uuid,uuid,uuid,jsonb,jsonb,boolean,boolean)', '/* exos: partner step var */'),
    ('public._exos_partner_reserve(uuid,uuid,uuid,uuid,jsonb,jsonb,boolean,boolean)', '/* exos: partner step lock */'),
    ('public._exos_partner_reserve(uuid,uuid,uuid,uuid,jsonb,jsonb,boolean,boolean)', '/* exos: partner price step */'),
    ('public._exos_partner_reserve(uuid,uuid,uuid,uuid,jsonb,jsonb,boolean,boolean)', '/* exos: partner hold step */'),
    ('public._exos_partner_reservation_complete(uuid,uuid,text,jsonb,text)', '/* exos: partner pool lock order */'),
    ('public._exos_partner_reservation_complete(uuid,uuid,text,jsonb,text)', '/* exos: partner price step */'),
    ('public._exos_partner_reservation_complete(uuid,uuid,text,jsonb,text)', '/* exos: partner price step value */'),
    -- earlier ones on the same two functions
    ('public._exos_partner_reserve(uuid,uuid,uuid,uuid,jsonb,jsonb,boolean,boolean)', '/* exos: reserve idempotency */'),
    ('public._exos_partner_reserve(uuid,uuid,uuid,uuid,jsonb,jsonb,boolean,boolean)', '/* exos: reserve idem store */'),
    ('public._exos_partner_reserve(uuid,uuid,uuid,uuid,jsonb,jsonb,boolean,boolean)', '/* exos: partner presale */'),
    ('public._exos_partner_reserve(uuid,uuid,uuid,uuid,jsonb,jsonb,boolean,boolean)', '/* exos: partner presale mode */'),
    ('public._exos_partner_reserve(uuid,uuid,uuid,uuid,jsonb,jsonb,boolean,boolean)', '/* exos: partner cap */'),
    ('public._exos_partner_reserve(uuid,uuid,uuid,uuid,jsonb,jsonb,boolean,boolean)', '_exos_tier_needs_picker'),
    ('public._exos_partner_reservation_complete(uuid,uuid,text,jsonb,text)', '/* exos: cap0 closed */'),
    ('public.exos_assert_quota(uuid,integer)', '/* exos: pool lock order */'),
    ('public.exos_create_hold(uuid,uuid,integer,integer,text)', '/* exos: pool lock order */')
  ) AS t(sig, marker) LOOP
    IF position(r.marker IN pg_get_functiondef(to_regprocedure(r.sig))) = 0 THEN
      v_lost := v_lost || format(E'\n  %s lost %s', r.sig, r.marker);
    END IF;
  END LOOP;
  ASSERT v_lost = '', 'PT1 patches lost:' || v_lost;
  RAISE NOTICE 'OK  PT1 grants unchanged; 7 new markers and 9 earlier ones in the live bodies';
END $$;

-- PT2 -----------------------------------------------------------------------
DO $$
DECLARE v jsonb; c jsonb; v_eb uuid := pg_temp.step('d1', 1);
BEGIN
  c := pg_temp.cur('d1');
  ASSERT (c->>'price_cents')::int = 2000 AND (c->>'step_remaining')::int = 4, 'PT2 starts at the early bird ' || c::text;
  v := pg_temp.reserve(pg_temp.line('d1', 3));
  INSERT INTO b58 VALUES ('rsv_ga3', v->>'token');
  ASSERT v->>'status' = 'active' AND (v->'order_items'->0->>'price')::numeric = 20.00, 'PT2 quoted at $20 ' || v::text;
  ASSERT (SELECT (lines->0->>'price_step_id')::uuid FROM public.exos_partner_reservations WHERE token = v->>'token') = v_eb,
    'PT2 the line records the step';
  ASSERT (SELECT bool_and(h.price_step_id = v_eb AND h.unit_price_cents = 2000) AND sum(h.quantity) = 3
            FROM public.exos_cart_holds h JOIN public.exos_partner_reservations r ON r.id = h.partner_reservation_id
           WHERE r.token = v->>'token'), 'PT2 the holds carry the step and its price';
  c := pg_temp.cur('d1');
  ASSERT c->>'step_id' = v_eb::text AND (c->>'step_remaining')::int = 1, 'PT2 the reservation counts against the step ' || c::text;
  -- A type without steps: no step on the line or the holds (as before).
  v := pg_temp.reserve(pg_temp.line('d2', 2));
  ASSERT (SELECT lines->0->>'price_step_id' IS NULL FROM public.exos_partner_reservations WHERE token = v->>'token')
     AND (SELECT bool_and(h.price_step_id IS NULL AND h.unit_price_cents IS NULL) FROM public.exos_cart_holds h
           JOIN public.exos_partner_reservations r ON r.id = h.partner_reservation_id WHERE r.token = v->>'token'),
    'PT2 no steps, no step';
  PERFORM public._exos_partner_reservation_cancel('b5800000-0000-0000-0000-000000000001', 'b5800000-0000-0000-0000-0000000000f1', v->>'token');
  RAISE NOTICE 'OK  PT2 a partner reservation locks the early-bird price ($20) and holds 3 of its 4 places';
END $$;

-- PT3 -----------------------------------------------------------------------
DO $$
DECLARE s jsonb; v_held int;
BEGIN
  v_held := (SELECT sum(quantity) FROM public.exos_cart_holds WHERE tier_id = 'b5800000-0000-0000-0000-0000000000d1' AND status = 'active');
  s := pg_temp.st(format('SELECT pg_temp.reserve(%L)', pg_temp.line('d1', 2)));
  ASSERT s->>'state' = 'XP410' AND s->>'message' LIKE 'price_step_remaining: only 1 of GA left at this price%', 'PT3 over the remainder ' || s::text;
  ASSERT (s->>'detail')::jsonb = jsonb_build_object('remaining', 1, 'price_cents', 2000, 'tier_id', 'b5800000-0000-0000-0000-0000000000d1'),
    'PT3 detail ' || s::text;
  -- The quote (/build) refuses it the same way; the organizer's too.
  s := pg_temp.st(format('SELECT pg_temp.reserve(%L, true, true)', pg_temp.line('d1', 2)));
  ASSERT s->>'state' = 'XP410', 'PT3 the /build quote ' || s::text;
  -- In a multi-type reservation the whole reservation is refused: nothing held.
  s := pg_temp.st(format('SELECT pg_temp.reserve(%L)', pg_temp.line('d2', 1) || pg_temp.line('d1', 2)));
  ASSERT s->>'state' = 'XP410', 'PT3 multi-type ' || s::text;
  ASSERT (SELECT sum(quantity) FROM public.exos_cart_holds WHERE tier_id = 'b5800000-0000-0000-0000-0000000000d1' AND status = 'active') = v_held
     AND NOT EXISTS (SELECT 1 FROM public.exos_cart_holds WHERE tier_id = 'b5800000-0000-0000-0000-0000000000d2' AND status = 'active'),
    'PT3 a refused reservation holds nothing';
  -- Exactly the remainder is fine (CAP: take those, then the rest at the next price).
  s := pg_temp.st(format('SELECT pg_temp.reserve(%L, false, true)', pg_temp.line('d1', 1)));
  ASSERT s->>'state' = 'ok', 'PT3 the remainder ' || s::text;
  RAISE NOTICE 'OK  PT3 asking for 2 with 1 early bird left is XP410 price_step_remaining (remaining 1, $20), quote included';
END $$;

-- PT4 -----------------------------------------------------------------------
-- a) The early bird ends by time while the partner's buyer pays: complete
--    still mints at $20, on the early-bird step.
DO $$
DECLARE v jsonb; v_eb uuid := pg_temp.step('d1', 1); n int;
BEGIN
  UPDATE public.exos_price_steps SET ends_at = now() WHERE id = v_eb;
  ASSERT (pg_temp.cur('d1')->>'price_cents')::int = 3000, 'PT4a the price moved on';
  v := pg_temp.complete((SELECT b.v FROM b58 b WHERE b.k = 'rsv_ga3'));
  ASSERT v->>'status' = 'completed' AND (v->>'fresh')::boolean, 'PT4a completed ' || v::text;
  SELECT count(*) INTO n FROM public.exos_tickets t
   WHERE t.order_ref = 'po:' || (SELECT id FROM public.exos_partner_reservations WHERE token = (SELECT b.v FROM b58 b WHERE b.k = 'rsv_ga3'))
     AND t.price_step_id = v_eb AND t.price_paid = 20.00;
  ASSERT n = 3, 'PT4a 3 tickets at $20 on the early-bird step, got ' || n;
  ASSERT (SELECT count(*) FROM public.exos_tickets WHERE price_step_id = pg_temp.step('d1', 2)) = 0, 'PT4a none on the next step';
  -- A new reservation now pays the next price.
  v := pg_temp.reserve(pg_temp.line('d1', 2), false, true);
  ASSERT (v->'order_items'->0->>'price')::numeric = 30.00, 'PT4a the next quote is $30 ' || v::text;
  RAISE NOTICE 'OK  PT4a the step ended by time mid-reservation: 3 tickets minted at $20 on the early-bird step';
END $$;
-- b) The organizer re-saves the steps (raises the early price) mid-reservation.
DO $$
DECLARE v jsonb; v_e uuid := pg_temp.step('d3', 1); n int;
BEGIN
  v := pg_temp.reserve(pg_temp.line('d3', 4));
  PERFORM pg_temp.as_user('b5800000-0000-0000-0000-0000000000a1', 'b58-owner@x.com');
  PERFORM public.exos_set_price_steps('b5800000-0000-0000-0000-0000000000d3',
    jsonb_build_array(jsonb_build_object('id', v_e, 'name', 'Early', 'price_cents', 1700, 'ends_after_count', 10),
                      jsonb_build_object('name', 'Late', 'price_cents', 2500)));
  PERFORM pg_temp.as_user(NULL, NULL);
  ASSERT (pg_temp.cur('d3')->>'price_cents')::int = 1700 AND (pg_temp.cur('d3')->>'step_remaining')::int = 6,
    'PT4b the re-saved step still counts the reservation ' || pg_temp.cur('d3')::text;
  v := pg_temp.complete(v->>'token');
  SELECT count(*) INTO n FROM public.exos_tickets
   WHERE tier_id = 'b5800000-0000-0000-0000-0000000000d3' AND price_step_id = v_e AND price_paid = 15.00;
  ASSERT n = 4, 'PT4b 4 tickets at the locked $15, got ' || n;
  RAISE NOTICE 'OK  PT4b the organizer re-priced the step mid-reservation: minted at the locked $15';
END $$;

-- PT5 -----------------------------------------------------------------------
DO $$
DECLARE v jsonb; v_id uuid; c jsonb;
BEGIN
  -- Late: 4 sold at Early (10). A reservation of 5 leaves 1.
  v := pg_temp.reserve(pg_temp.line('d3', 5));
  v_id := (SELECT id FROM public.exos_partner_reservations WHERE token = v->>'token');
  ASSERT (pg_temp.cur('d3')->>'step_remaining')::int = 1, 'PT5 held';
  -- Ten minutes pass: the holds stop counting at once (lazily), the sweep marks them.
  UPDATE public.exos_partner_reservations SET expires_at = now() - interval '1 second' WHERE id = v_id;
  UPDATE public.exos_cart_holds SET expires_at = now() - interval '1 second' WHERE partner_reservation_id = v_id;
  ASSERT (pg_temp.cur('d3')->>'step_remaining')::int = 6, 'PT5 expiry frees the count ' || pg_temp.cur('d3')::text;
  PERFORM public.exos_partner_reservations_sweep(500);
  ASSERT (SELECT status FROM public.exos_partner_reservations WHERE id = v_id) = 'expired'
     AND NOT EXISTS (SELECT 1 FROM public.exos_cart_holds WHERE partner_reservation_id = v_id AND status = 'active'), 'PT5 swept';
  ASSERT (pg_temp.complete(v->>'token'))->>'status' = 'expired', 'PT5 an expired reservation mints nothing';
  ASSERT (pg_temp.cur('d3')->>'step_remaining')::int = 6, 'PT5 still free';
  -- Cancel frees it too.
  v := pg_temp.reserve(pg_temp.line('d3', 6));
  ASSERT (pg_temp.cur('d3')->>'step_index')::int = 2 AND (pg_temp.cur('d3')->>'price_cents')::int = 2500,
    'PT5 all six held: the price moves on ' || pg_temp.cur('d3')::text;
  PERFORM public._exos_partner_reservation_cancel('b5800000-0000-0000-0000-000000000001', 'b5800000-0000-0000-0000-0000000000f1', v->>'token');
  c := pg_temp.cur('d3');
  ASSERT (c->>'step_remaining')::int = 6 AND (c->>'price_cents')::int = 1700, 'PT5 cancel frees the count ' || c::text;
  RAISE NOTICE 'OK  PT5 expiry (lazy + sweep) and cancellation give the step''s places back';
END $$;

-- PT6 -----------------------------------------------------------------------
DO $$
DECLARE v jsonb; c jsonb; v_hold uuid; s jsonb; v_e uuid := pg_temp.step('d3', 1);
BEGIN
  -- A checkout reads $17 for 2, holds; the partner takes the last 6 first.
  c := pg_temp.cur('d3');
  PERFORM pg_temp.as_user('b5800000-0000-0000-0000-0000000000b1', 'b58-fan1@x.com');
  v_hold := public.exos_create_hold('b5800000-0000-0000-0000-0000000000e1', 'b5800000-0000-0000-0000-0000000000d3', 2);
  PERFORM pg_temp.as_user(NULL, NULL);
  v := pg_temp.reserve(pg_temp.line('d3', 6));
  s := pg_temp.st(format('SELECT public.exos_hold_lock_price(%L, %L, %s)', v_hold, c->>'step_id', c->>'price_cents'));
  ASSERT s->>'state' = 'XP409' AND s->>'message' LIKE 'price_changed%2500%', 'PT6 the checkout is told the price changed ' || s::text;
  ASSERT (SELECT price_step_id FROM public.exos_cart_holds WHERE id = v_hold) IS NULL, 'PT6 the checkout hold has no step';
  PERFORM public._exos_partner_reservation_cancel('b5800000-0000-0000-0000-000000000001', 'b5800000-0000-0000-0000-0000000000f1', v->>'token');
  -- The other way round: a checkout locks 2 of 6; the partner asking 6 is capped at 4.
  PERFORM public.exos_hold_lock_price(v_hold, v_e, 1700);
  s := pg_temp.st(format('SELECT pg_temp.reserve(%L)', pg_temp.line('d3', 6)));
  ASSERT s->>'state' = 'XP410' AND ((s->>'detail')::jsonb->>'remaining')::int = 4, 'PT6 partner after the checkout ' || s::text;
  ASSERT (pg_temp.reserve(pg_temp.line('d3', 4))->'order_items'->0->>'price')::numeric = 17.00, 'PT6 the 4 at $17';
  c := pg_temp.cur('d3');
  ASSERT (c->>'price_cents')::int = 2500 AND (SELECT public._exos_price_step_used(v_e)) = 10, 'PT6 never more than 10 at $17 ' || c::text;
  RAISE NOTICE 'OK  PT6 partner vs checkout on the last early birds: one gets them, the other is told (price_changed / price_step_remaining)';
END $$;

-- PT7 -----------------------------------------------------------------------
DO $$
DECLARE v jsonb; s jsonb; v_e uuid := pg_temp.step('d4', 1); n int;
BEGIN
  -- Box is hidden: only an organizer reservation sells it.
  v := pg_temp.reserve(pg_temp.line('d4', 2), true);
  ASSERT (SELECT channel FROM public.exos_partner_reservations WHERE token = v->>'token') = 'organizer', 'PT7 organizer';
  ASSERT (SELECT bool_and(price_step_id = v_e AND unit_price_cents = 1000) FROM public.exos_cart_holds
           WHERE partner_reservation_id = (SELECT id FROM public.exos_partner_reservations WHERE token = v->>'token')), 'PT7 holds on the step';
  ASSERT (pg_temp.cur('d4')->>'step_remaining')::int = 1, 'PT7 counted';
  s := pg_temp.st(format('SELECT pg_temp.reserve(%L, true)', pg_temp.line('d4', 2)));
  ASSERT s->>'state' = 'XP410' AND ((s->>'detail')::jsonb->>'remaining')::int = 1, 'PT7 CAP ' || s::text;
  UPDATE public.exos_price_steps SET ends_at = now() WHERE id = v_e;
  v := pg_temp.complete(v->>'token', true);
  ASSERT v->>'status' = 'completed', 'PT7 completed ' || v::text;
  SELECT count(*) INTO n FROM public.exos_tickets
   WHERE tier_id = 'b5800000-0000-0000-0000-0000000000d4' AND price_step_id = v_e AND price_paid = 10.00 AND channel_source = 'api';
  ASSERT n = 2, 'PT7 minted at the locked $10, got ' || n;
  RAISE NOTICE 'OK  PT7 organizer reservations lock the step, cap at it and mint at the locked price';
END $$;

-- PT8 -----------------------------------------------------------------------
DO $$
DECLARE v jsonb;
BEGIN
  v := public._exos_partner_comp('b5800000-0000-0000-0000-000000000001', 'b5800000-0000-0000-0000-0000000000f1',
    'b5800000-0000-0000-0000-0000000000e1', pg_temp.line('d5', 3), '{}'::jsonb, 'https://exos.test');
  ASSERT v->>'status' = 'completed', 'PT8 comp ' || v::text;
  ASSERT (SELECT count(*) FROM public.exos_tickets WHERE tier_id = 'b5800000-0000-0000-0000-0000000000d5'
            AND price_paid = 0 AND price_step_id IS NULL) = 3, 'PT8 comps carry no step';
  ASSERT (pg_temp.cur('d5')->>'price_cents')::int = 1200 AND (pg_temp.cur('d5')->>'step_remaining')::int = 2,
    'PT8 the early bird is untouched (3 comps > its 2 places) ' || pg_temp.cur('d5')::text;
  RAISE NOTICE 'OK  PT8 comps take no step place (3 comped, the 2 early birds are still there)';
END $$;

-- PT9 -----------------------------------------------------------------------
INSERT INTO public.exos_quotas (id, event_id, org_id, name, size) VALUES
  ('b5800000-0000-0000-0000-000000000c01', 'b5800000-0000-0000-0000-0000000000e1', 'b5800000-0000-0000-0000-000000000001', 'Room', 10),
  ('b5800000-0000-0000-0000-000000000c02', 'b5800000-0000-0000-0000-0000000000e1', 'b5800000-0000-0000-0000-000000000001', 'Bar', 10);
-- Pool A (sort 6) is in the higher pool only, Pool B (sort 7) in the lower one:
-- line order (sort order) is the reverse of the pool order.
INSERT INTO public.exos_quota_tiers (quota_id, tier_id) VALUES
  ('b5800000-0000-0000-0000-000000000c02', 'b5800000-0000-0000-0000-0000000000d6'),
  ('b5800000-0000-0000-0000-000000000c01', 'b5800000-0000-0000-0000-0000000000d7');
DO $$
DECLARE v jsonb; d text; p_lock int; p_consume int; p_assert int;
BEGIN
  v := pg_temp.reserve(pg_temp.line('d6', 2) || pg_temp.line('d7', 3));
  v := pg_temp.complete(v->>'token');
  ASSERT v->>'status' = 'completed' AND jsonb_array_length(v->'order'->'tickets') = 5, 'PT9 completed ' || v::text;
  ASSERT public.exos_quota_available('b5800000-0000-0000-0000-000000000c01') = 7
     AND public.exos_quota_available('b5800000-0000-0000-0000-000000000c02') = 8, 'PT9 both pools counted';
  -- complete takes every pool (by id), then every type (by id), before it
  -- consumes the holds and re-checks each type with exos_assert_quota.
  d := pg_get_functiondef('public._exos_partner_reservation_complete(uuid,uuid,text,jsonb,text)'::regprocedure);
  p_lock := position('/* exos: partner pool lock order */' IN d);
  p_consume := position('SET status = ''consumed''' IN d);
  p_assert := position('exos_assert_quota' IN d);
  ASSERT p_lock > 0 AND p_lock < p_consume AND p_consume < p_assert, 'PT9 lock order in complete';
  ASSERT position('ORDER BY q.id FOR UPDATE' IN substr(d, p_lock)) > 0, 'PT9 pools by id';
  RAISE NOTICE 'OK  PT9 a two-type reservation over two shared pools completes; pools are locked by id before any type';
END $$;

-- PT10 ----------------------------------------------------------------------
DO $$
DECLARE s jsonb; v_tok text;
BEGIN
  -- Org 2's partner can't reserve org 1's event, nor touch its reservation.
  s := pg_temp.st($q$SELECT public._exos_partner_reserve('b5800000-0000-0000-0000-000000000002', 'b5800000-0000-0000-0000-0000000000e1',
         'b5800000-0000-0000-0000-0000000000f9', NULL, pg_temp.line('d2', 1), '{}', false, false)$q$);
  ASSERT s->>'state' = 'P0002', 'PT10 org 2 reserving org 1''s event ' || s::text;
  s := pg_temp.st($q$SELECT public._exos_partner_reserve('b5800000-0000-0000-0000-000000000001', 'b5800000-0000-0000-0000-0000000000e1',
         'b5800000-0000-0000-0000-0000000000f9', NULL, pg_temp.line('d2', 1), '{}', false, false)$q$);
  ASSERT s->>'state' = '42501', 'PT10 org 2''s partner naming org 1 ' || s::text;
  -- A step error never names another org's type: org 1's type on org 2's event is refused before pricing.
  s := pg_temp.st($q$SELECT public._exos_partner_reserve('b5800000-0000-0000-0000-000000000002', 'b5800000-0000-0000-0000-0000000000e2',
         'b5800000-0000-0000-0000-0000000000f9', NULL, pg_temp.line('d1', 50), '{}', false, false)$q$);
  ASSERT s->>'state' = 'EX422' AND s->>'detail' IS NULL, 'PT10 a foreign type ' || s::text;
  v_tok := (SELECT token FROM public.exos_partner_reservations
             WHERE event_id = 'b5800000-0000-0000-0000-0000000000e1' AND status = 'active' LIMIT 1);
  s := pg_temp.st(format($q$SELECT public._exos_partner_reservation_complete('b5800000-0000-0000-0000-000000000002',
         'b5800000-0000-0000-0000-0000000000f9', %L, NULL, 'https://exos.test')$q$, v_tok));
  ASSERT s->>'state' = 'P0002', 'PT10 org 2 completing org 1''s reservation ' || s::text;
END $$;
-- Reads: org 1 staff see their reservations, holds and steps; org 2's owner and a fan see none.
SELECT pg_temp.as_user('b5800000-0000-0000-0000-0000000000a2', 'b58-finance@x.com');
SET LOCAL ROLE authenticated;
DO $$
BEGIN
  ASSERT (SELECT count(*) FROM public.exos_partner_reservations WHERE event_id = 'b5800000-0000-0000-0000-0000000000e1') > 0, 'PT10 finance reads';
  ASSERT (SELECT count(*) FROM public.exos_cart_holds WHERE event_id = 'b5800000-0000-0000-0000-0000000000e1' AND price_step_id IS NOT NULL) > 0,
    'PT10 finance reads the stepped holds';
END $$;
RESET ROLE;
SELECT pg_temp.as_user('b5800000-0000-0000-0000-0000000000a3', 'b58-owner2@x.com');
SET LOCAL ROLE authenticated;
DO $$
BEGIN
  ASSERT (SELECT count(*) FROM public.exos_partner_reservations WHERE event_id = 'b5800000-0000-0000-0000-0000000000e1') = 0, 'PT10 org 2 reservations';
  ASSERT (SELECT count(*) FROM public.exos_cart_holds WHERE event_id = 'b5800000-0000-0000-0000-0000000000e1') = 0, 'PT10 org 2 holds';
  ASSERT (SELECT count(*) FROM public.exos_price_steps WHERE event_id = 'b5800000-0000-0000-0000-0000000000e1') = 0, 'PT10 org 2 steps';
  BEGIN
    PERFORM public._exos_partner_reserve('b5800000-0000-0000-0000-000000000001', 'b5800000-0000-0000-0000-0000000000e1',
      'b5800000-0000-0000-0000-0000000000f1', NULL, '[]', '{}', false, true);
    RAISE EXCEPTION 'PT10 authenticated called the core';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
END $$;
RESET ROLE;
SELECT pg_temp.as_user('b5800000-0000-0000-0000-0000000000b1', 'b58-fan1@x.com');
SET LOCAL ROLE authenticated;
DO $$
BEGIN
  ASSERT (SELECT count(*) FROM public.exos_partner_reservations) = 0, 'PT10 a fan reads no reservation';
  ASSERT (SELECT count(*) FROM public.exos_cart_holds WHERE partner_reservation_id IS NOT NULL) = 0, 'PT10 a fan reads no partner hold';
  RAISE NOTICE 'OK  PT10 RLS and cross-org isolation unchanged (org 2 partner: P0002 / 42501; reads scoped to org 1 staff)';
END $$;
RESET ROLE;

ROLLBACK;
