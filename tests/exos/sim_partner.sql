-- ============================================================================
-- Mistake simulations: developers and partners integrating with the partner
-- API (exos_api_write & co, mig 20261031110000 / 20261102*) and the partner
-- sales contract (#74, mig 20261031130000). Fixes in mig 20261104130000.
-- Self-contained (e9 prefix), rolled back. Each block is one mistake:
-- OK = Exos already handles it, FIXED = mig 20261104130000 made it OK,
-- KNOWN = a documented gap (reported, not failing the run).
--   psql -d <db> -v ON_ERROR_STOP=1 -f tests/exos/sim_partner.sql
-- Orgs: 1 (owner a1, manager a2, scanner a3), 2 (owner b1).
-- Keys: k1 org-1 owner (events, tickets, checkin, commerce writes),
--   k2 org-1 owner (the same scopes: a second integration of the org),
--   k3 org-1 legacy read, k4 org-1 revoked, k5 org-1 made by the scanner,
--   k6 org-2 owner.
-- ============================================================================
\set ON_ERROR_STOP on
BEGIN;

-- auth.uid() / auth.jwt() as Supabase defines them (exos_api_write sets the
-- request claims), still honouring the harness's app.uid. Rolled back.
CREATE OR REPLACE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql STABLE AS $$
  SELECT coalesce(nullif(current_setting('app.uid', true), ''),
                  nullif(current_setting('request.jwt.claim.sub', true), ''),
                  nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'sub')::uuid
$$;
SELECT set_config('app.uid', '', false);

INSERT INTO auth.users (id, email, email_confirmed_at) VALUES
  ('e9000000-0000-0000-0000-0000000000a1', 'e9-owner@x.com', now()),
  ('e9000000-0000-0000-0000-0000000000a2', 'e9-manager@x.com', now()),
  ('e9000000-0000-0000-0000-0000000000a3', 'e9-scanner@x.com', now()),
  ('e9000000-0000-0000-0000-0000000000b1', 'e9-other@x.com', now()),
  ('e9000000-0000-0000-0000-0000000000c1', 'e9-buyer@x.com', now());
INSERT INTO public.exos_orgs (id, name, slug, owner_uid) VALUES
  ('e9000000-0000-0000-0000-000000000001', 'E9 Org', 'e9-org', 'e9000000-0000-0000-0000-0000000000a1'),
  ('e9000000-0000-0000-0000-000000000002', 'E9 Other', 'e9-other', 'e9000000-0000-0000-0000-0000000000b1');
INSERT INTO public.exos_org_memberships (org_id, user_id, role) VALUES
  ('e9000000-0000-0000-0000-000000000001', 'e9000000-0000-0000-0000-0000000000a1', 'owner'),
  ('e9000000-0000-0000-0000-000000000001', 'e9000000-0000-0000-0000-0000000000a2', 'manager'),
  ('e9000000-0000-0000-0000-000000000001', 'e9000000-0000-0000-0000-0000000000a3', 'scanner'),
  ('e9000000-0000-0000-0000-000000000002', 'e9000000-0000-0000-0000-0000000000b1', 'owner');
INSERT INTO public.exos_api_keys (id, org_id, name, key_prefix, key_hash, scopes, created_by, revoked_at) VALUES
  ('e9000000-0000-0000-0000-0000000000f1', 'e9000000-0000-0000-0000-000000000001', 'k1', 'sk_live_e9k1', 'e9hash1',
   ARRAY['events:write','tickets:write','checkin:write','commerce:write','org:admin'], 'e9000000-0000-0000-0000-0000000000a1', NULL),
  ('e9000000-0000-0000-0000-0000000000f2', 'e9000000-0000-0000-0000-000000000001', 'k2', 'sk_live_e9k2', 'e9hash2',
   ARRAY['events:write','tickets:write','checkin:write','commerce:write'], 'e9000000-0000-0000-0000-0000000000a1', NULL),
  ('e9000000-0000-0000-0000-0000000000f3', 'e9000000-0000-0000-0000-000000000001', 'k3', 'sk_live_e9k3', 'e9hash3',
   ARRAY['read'], 'e9000000-0000-0000-0000-0000000000a1', NULL),
  ('e9000000-0000-0000-0000-0000000000f4', 'e9000000-0000-0000-0000-000000000001', 'k4', 'sk_live_e9k4', 'e9hash4',
   ARRAY['events:write'], 'e9000000-0000-0000-0000-0000000000a1', now() - interval '1 day'),
  ('e9000000-0000-0000-0000-0000000000f5', 'e9000000-0000-0000-0000-000000000001', 'k5', 'sk_live_e9k5', 'e9hash5',
   ARRAY['events:write'], 'e9000000-0000-0000-0000-0000000000a3', NULL),
  ('e9000000-0000-0000-0000-0000000000f6', 'e9000000-0000-0000-0000-000000000002', 'k6', 'sk_live_e9k6', 'e9hash6',
   ARRAY['events:write','tickets:write','checkin:write','commerce:write'], 'e9000000-0000-0000-0000-0000000000b1', NULL);

-- e1: org 1, published, on sale through partners (GA 20, Small 3, Seated 4,
-- Presale 10). e2: org 1, for the API writes. e9: org 2.
INSERT INTO public.exos_events (id, org_id, name, slug, status, starts_at, timezone, total_tickets, tickets_sold, currency, created_by) VALUES
  ('e9000000-0000-0000-0000-0000000000e1', 'e9000000-0000-0000-0000-000000000001', 'E9 Show', 'e9-show', 'published',
   now() + interval '3 days', 'America/New_York', 0, 0, 'usd', 'e9000000-0000-0000-0000-0000000000a1'),
  ('e9000000-0000-0000-0000-0000000000e2', 'e9000000-0000-0000-0000-000000000001', 'E9 Draft', 'e9-draft', 'draft',
   now() + interval '9 days', 'America/New_York', 0, 0, 'usd', 'e9000000-0000-0000-0000-0000000000a1'),
  ('e9000000-0000-0000-0000-0000000000e9', 'e9000000-0000-0000-0000-000000000002', 'E9 Elsewhere', 'e9-else', 'published',
   now() + interval '3 days', 'America/New_York', 0, 0, 'usd', 'e9000000-0000-0000-0000-0000000000b1');
INSERT INTO public.exos_ticket_tiers (id, event_id, name, price, capacity, sold, visibility, sort_order) VALUES
  ('e9000000-0000-0000-0000-0000000000d1', 'e9000000-0000-0000-0000-0000000000e1', 'GA', 25, 20, 0, 'public', 1),
  ('e9000000-0000-0000-0000-0000000000d2', 'e9000000-0000-0000-0000-0000000000e1', 'Small', 40, 3, 0, 'public', 2),
  ('e9000000-0000-0000-0000-0000000000d3', 'e9000000-0000-0000-0000-0000000000e1', 'Seated', 60, 4, 0, 'public', 3),
  ('e9000000-0000-0000-0000-0000000000d4', 'e9000000-0000-0000-0000-0000000000e1', 'Presale', 30, 10, 0, 'public', 4),
  ('e9000000-0000-0000-0000-0000000000d5', 'e9000000-0000-0000-0000-0000000000e2', 'Draft GA', 10, 50, 0, 'public', 1),
  ('e9000000-0000-0000-0000-0000000000d9', 'e9000000-0000-0000-0000-0000000000e9', 'Other GA', 20, 50, 0, 'public', 1);
INSERT INTO public.exos_tier_distribution (tier_id, event_id, org_id, enabled) VALUES
  ('e9000000-0000-0000-0000-0000000000d1', 'e9000000-0000-0000-0000-0000000000e1', 'e9000000-0000-0000-0000-000000000001', true),
  ('e9000000-0000-0000-0000-0000000000d2', 'e9000000-0000-0000-0000-0000000000e1', 'e9000000-0000-0000-0000-000000000001', true),
  ('e9000000-0000-0000-0000-0000000000d3', 'e9000000-0000-0000-0000-0000000000e1', 'e9000000-0000-0000-0000-000000000001', true),
  ('e9000000-0000-0000-0000-0000000000d4', 'e9000000-0000-0000-0000-0000000000e1', 'e9000000-0000-0000-0000-000000000001', true),
  ('e9000000-0000-0000-0000-0000000000d9', 'e9000000-0000-0000-0000-0000000000e9', 'e9000000-0000-0000-0000-000000000002', true);
INSERT INTO public.exos_checkout_sessions (session_id, event_id, tier_id, org_id, buyer_uid, buyer_email, quantity, amount_cents, status) VALUES
  ('cs_e9a', 'e9000000-0000-0000-0000-0000000000e1', 'e9000000-0000-0000-0000-0000000000d1', 'e9000000-0000-0000-0000-000000000001',
   'e9000000-0000-0000-0000-0000000000c1', 'e9-buyer@x.com', 1, 2500, 'fulfilled'),
  ('cs_e9z', 'e9000000-0000-0000-0000-0000000000e9', 'e9000000-0000-0000-0000-0000000000d9', 'e9000000-0000-0000-0000-000000000002',
   'e9000000-0000-0000-0000-0000000000c1', 'e9-buyer@x.com', 1, 2000, 'fulfilled');

CREATE TEMP TABLE e9 (k text PRIMARY KEY, v text) ON COMMIT DROP;

-- The SQLSTATE a statement fails with ('ok' when it doesn't).
CREATE FUNCTION pg_temp.st(p_sql text) RETURNS text LANGUAGE plpgsql AS $$
BEGIN
  EXECUTE p_sql;
  RETURN 'ok';
EXCEPTION WHEN OTHERS THEN RETURN SQLSTATE;
END $$;
-- An API write with key k<n>.
CREATE FUNCTION pg_temp.w(p_key int, p_action text, p_target text, p_args jsonb DEFAULT '{}', p_idem text DEFAULT NULL)
RETURNS jsonb LANGUAGE sql AS $$
  SELECT public.exos_api_write(('e9000000-0000-0000-0000-0000000000f' || p_key)::uuid, p_action, p_target, p_args, p_idem)
$$;
CREATE FUNCTION pg_temp.wst(p_key int, p_action text, p_target text, p_args jsonb DEFAULT '{}', p_idem text DEFAULT NULL)
RETURNS text LANGUAGE plpgsql AS $$
BEGIN
  PERFORM pg_temp.w(p_key, p_action, p_target, p_args, p_idem);
  RETURN 'ok';
EXCEPTION WHEN OTHERS THEN RETURN SQLSTATE;
END $$;
CREATE FUNCTION pg_temp.act(p_uid text) RETURNS void LANGUAGE sql AS $$
  SELECT set_config('app.uid', coalesce(p_uid, ''), true);
$$;
-- A reservation's line, as exos-api's parseOrderItems hands it over.
CREATE FUNCTION pg_temp.line(p_tier text, p_qty int) RETURNS jsonb LANGUAGE sql AS $$
  SELECT jsonb_build_array(jsonb_build_object('ticket_type_id', 'e9000000-0000-0000-0000-0000000000' || p_tier, 'quantity', p_qty))
$$;

-- A partner of org 1 (StubHub, inventory + comps), one with inventory only,
-- and one of org 2.
DO $$
DECLARE v jsonb;
BEGIN
  v := public._exos_dist_partner_create('e9000000-0000-0000-0000-000000000001', 'StubHub', 'stubhub', ARRAY['inventory','comps'],
                                        'e9000000-0000-0000-0000-0000000000a1', NULL);
  INSERT INTO e9 VALUES ('pA', v->>'id');
  v := public._exos_dist_partner_create('e9000000-0000-0000-0000-000000000001', 'Vivid', 'vivid', ARRAY['inventory'],
                                        'e9000000-0000-0000-0000-0000000000a1', NULL);
  INSERT INTO e9 VALUES ('pB', v->>'id');
  v := public._exos_dist_partner_create('e9000000-0000-0000-0000-000000000002', 'SeatGeek', 'seatgeek', ARRAY['inventory'],
                                        'e9000000-0000-0000-0000-0000000000b1', NULL);
  INSERT INTO e9 VALUES ('pZ', v->>'id');
END $$;
CREATE FUNCTION pg_temp.p(p_name text) RETURNS uuid LANGUAGE sql AS $$ SELECT v::uuid FROM e9 WHERE k = p_name $$;
CREATE FUNCTION pg_temp.v(p_name text) RETURNS text LANGUAGE sql AS $$ SELECT v FROM e9 WHERE k = p_name $$;

-- ============================================================================
-- Retries and idempotency (exos_api_write)
-- ============================================================================

-- SIM-PARTNER-1: retries POST /events after a timeout with no Idempotency-Key.
DO $$
DECLARE n int;
BEGIN
  PERFORM pg_temp.w(1, 'event.create', NULL, '{"event":{"name":"E9 Retry"}}');
  PERFORM pg_temp.w(1, 'event.create', NULL, '{"event":{"name":"E9 Retry"}}');
  SELECT count(*) INTO n FROM public.exos_events WHERE org_id = 'e9000000-0000-0000-0000-000000000001' AND name = 'E9 Retry';
  -- Intended: without a key a resend is a new request (docs: send an
  -- Idempotency-Key on any write you might retry). Both are drafts, so nothing
  -- is on sale twice.
  IF n <> 2 THEN RAISE EXCEPTION 'SIM-PARTNER-1 FAIL: % events', n; END IF;
  RAISE NOTICE 'OK SIM-PARTNER-1 a keyless retry is a second (draft) write, as documented';
END $$;

-- SIM-PARTNER-2: retries with the same Idempotency-Key and the same body.
DO $$
DECLARE r1 jsonb; r2 jsonb; n int;
BEGIN
  r1 := pg_temp.w(1, 'event.create', NULL, '{"event":{"name":"E9 Keyed"}}', 'e9-idem-0001');
  r2 := pg_temp.w(1, 'event.create', NULL, '{"event":{"name":"E9 Keyed"}}', 'e9-idem-0001');
  SELECT count(*) INTO n FROM public.exos_events WHERE name = 'E9 Keyed';
  IF n <> 1 OR r1->>'id' IS DISTINCT FROM r2->>'id' OR NOT coalesce((r2->>'idempotent_replay')::boolean, false) THEN
    RAISE EXCEPTION 'SIM-PARTNER-2 FAIL: % / % / %', n, r1, r2;
  END IF;
  RAISE NOTICE 'OK SIM-PARTNER-2 same key, same body: replayed';
END $$;

-- SIM-PARTNER-3: reuses one Idempotency-Key with a different body.
DO $$
DECLARE s text; n int;
BEGIN
  s := pg_temp.wst(1, 'event.create', NULL, '{"event":{"name":"E9 Keyed, but another"}}', 'e9-idem-0001');
  SELECT count(*) INTO n FROM public.exos_events WHERE name = 'E9 Keyed, but another';
  -- Before mig 20261104130000 this replayed the first event (200, nothing written).
  IF s <> '22023' OR n <> 0 THEN RAISE EXCEPTION 'SIM-PARTNER-3 FAIL: % (% written)', s, n; END IF;
  -- Comps (money-moving): a second batch under the first batch's key.
  PERFORM pg_temp.w(1, 'comp.issue', 'e9000000-0000-0000-0000-0000000000e1',
                    '{"tier_id":"e9000000-0000-0000-0000-0000000000d1","emails":["g1@x.com"]}', 'e9-idem-comp1');
  s := pg_temp.wst(1, 'comp.issue', 'e9000000-0000-0000-0000-0000000000e1',
                   '{"tier_id":"e9000000-0000-0000-0000-0000000000d1","emails":["g2@x.com","g3@x.com"]}', 'e9-idem-comp1');
  IF s <> '22023' THEN RAISE EXCEPTION 'SIM-PARTNER-3 FAIL: second comp batch under the same key: %', s; END IF;
  RAISE NOTICE 'OK SIM-PARTNER-3 FIXED same key, different body: 400, not a silent replay';
END $$;

-- SIM-PARTNER-4: reuses a key across API keys of the org, and across orgs.
DO $$
DECLARE r1 jsonb; r2 jsonb;
BEGIN
  r1 := pg_temp.w(2, 'event.create', NULL, '{"event":{"name":"E9 Keyed"}}', 'e9-idem-0001');
  r2 := pg_temp.w(6, 'event.create', NULL, '{"event":{"name":"E9 Keyed"}}', 'e9-idem-0001');
  IF r1 ? 'idempotent_replay' OR r2 ? 'idempotent_replay' OR r1->>'id' = r2->>'id' THEN
    RAISE EXCEPTION 'SIM-PARTNER-4 FAIL: a key was shared % / %', r1, r2;
  END IF;
  IF (SELECT org_id FROM public.exos_events WHERE id = (r2->>'id')::uuid) <> 'e9000000-0000-0000-0000-000000000002' THEN
    RAISE EXCEPTION 'SIM-PARTNER-4 FAIL: org 2''s write landed elsewhere';
  END IF;
  -- Intended: keys are per API key (exos_api_writes (api_key_id, key)), so
  -- another integration's or org's request never replays this one's answer.
  RAISE NOTICE 'OK SIM-PARTNER-4 Idempotency-Keys are per API key: no cross-key or cross-org replay';
END $$;

-- ============================================================================
-- Credentials and scopes
-- ============================================================================

-- SIM-PARTNER-5: a key with the wrong scope, a revoked key, a key whose
-- creator can't do the action, another org's ids.
DO $$
BEGIN
  IF pg_temp.wst(3, 'event.create', NULL, '{"event":{"name":"x"}}') <> '42501' THEN
    RAISE EXCEPTION 'SIM-PARTNER-5 FAIL: legacy read key wrote';
  END IF;
  IF pg_temp.wst(4, 'event.create', NULL, '{"event":{"name":"x"}}') <> '42501' THEN
    RAISE EXCEPTION 'SIM-PARTNER-5 FAIL: revoked key wrote';
  END IF;
  IF pg_temp.wst(5, 'event.create', NULL, '{"event":{"name":"x"}}') <> '42501' THEN
    RAISE EXCEPTION 'SIM-PARTNER-5 FAIL: a scanner''s key created an event';
  END IF;
  IF pg_temp.wst(1, 'event.update', 'e9000000-0000-0000-0000-0000000000e9', '{"event":{"name":"hijack"}}') <> 'P0002'
     OR pg_temp.wst(1, 'comp.issue', 'e9000000-0000-0000-0000-0000000000e9', '{"emails":["x@x.com"]}') <> 'P0002' THEN
    RAISE EXCEPTION 'SIM-PARTNER-5 FAIL: org 2''s event reached with org 1''s key';
  END IF;
  IF pg_temp.wst(1, 'event.update', 'not-a-uuid', '{"event":{"name":"x"}}') NOT IN ('P0002', '22023', '22P02') THEN
    RAISE EXCEPTION 'SIM-PARTNER-5 FAIL: a malformed id';
  END IF;
  IF (SELECT name FROM public.exos_events WHERE id = 'e9000000-0000-0000-0000-0000000000e9') <> 'E9 Elsewhere' THEN
    RAISE EXCEPTION 'SIM-PARTNER-5 FAIL: org 2''s event changed';
  END IF;
  -- A creator who leaves takes their keys' writes with them.
  UPDATE public.exos_org_memberships SET disabled = true
   WHERE org_id = 'e9000000-0000-0000-0000-000000000001' AND user_id = 'e9000000-0000-0000-0000-0000000000a3';
  IF pg_temp.wst(5, 'event.create', NULL, '{"event":{"name":"x"}}') <> '42501' THEN
    RAISE EXCEPTION 'SIM-PARTNER-5 FAIL: a departed member''s key wrote';
  END IF;
  UPDATE public.exos_org_memberships SET disabled = false
   WHERE org_id = 'e9000000-0000-0000-0000-000000000001' AND user_id = 'e9000000-0000-0000-0000-0000000000a3';
  RAISE NOTICE 'OK SIM-PARTNER-5 wrong scope / revoked / creator''s role / other org''s ids are refused';
END $$;

-- SIM-PARTNER-6: order edits (gap PR) with another org's order, and a reused key.
DO $$
DECLARE s text; r jsonb;
BEGIN
  s := pg_temp.st($q$SELECT public.exos_api_order_write('e9000000-0000-0000-0000-0000000000f1', 'order.update', 'cs_e9z',
                    '{"fields":{"first_name":"Hijack"}}')$q$);
  IF s <> 'P0002' THEN RAISE EXCEPTION 'SIM-PARTNER-6 FAIL: other org''s order: %', s; END IF;
  s := pg_temp.st($q$SELECT public.exos_api_order_write('e9000000-0000-0000-0000-0000000000f1', 'order.update', 'cs_e9a',
                    '{"fields":{"first_name":"Ann"},"event_id":"e9000000-0000-0000-0000-0000000000e9"}')$q$);
  IF s <> 'P0002' THEN RAISE EXCEPTION 'SIM-PARTNER-6 FAIL: order on the wrong event: %', s; END IF;
  r := public.exos_api_order_write('e9000000-0000-0000-0000-0000000000f1', 'order.update', 'cs_e9a',
         '{"fields":{"first_name":"Ann"}}', 'e9-idem-order1');
  r := public.exos_api_order_write('e9000000-0000-0000-0000-0000000000f1', 'order.update', 'cs_e9a',
         '{"fields":{"first_name":"Ann"}}', 'e9-idem-order1');
  IF NOT coalesce((r->>'idempotent_replay')::boolean, false) THEN RAISE EXCEPTION 'SIM-PARTNER-6 FAIL: no replay %', r; END IF;
  s := pg_temp.st($q$SELECT public.exos_api_order_write('e9000000-0000-0000-0000-0000000000f1', 'order.update', 'cs_e9a',
                    '{"fields":{"first_name":"Bob"}}', 'e9-idem-order1')$q$);
  IF s <> '22023' THEN RAISE EXCEPTION 'SIM-PARTNER-6 FAIL: same key, another name: %', s; END IF;
  -- Commerce writes (gap PR): the same rule.
  PERFORM public.exos_api_commerce_write('e9000000-0000-0000-0000-0000000000f1', 'membership_product.create', NULL,
    '{"name":"E9 Club","price_cents":1000,"billing":"month"}', 'e9-idem-club1');
  s := pg_temp.st($q$SELECT public.exos_api_commerce_write('e9000000-0000-0000-0000-0000000000f1', 'membership_product.create',
                    NULL, '{"name":"E9 Club Gold","price_cents":5000,"billing":"month"}', 'e9-idem-club1')$q$);
  IF s <> '22023' THEN RAISE EXCEPTION 'SIM-PARTNER-6 FAIL: commerce key reuse: %', s; END IF;
  RAISE NOTICE 'OK SIM-PARTNER-6 FIXED order / commerce writes: other org''s ids not found, reused key with another body refused';
END $$;

-- ============================================================================
-- Malformed values
-- ============================================================================

-- SIM-PARTNER-7: emoji names, negative / decimal cents, huge capacities.
DO $$
DECLARE r jsonb; s text;
BEGIN
  r := pg_temp.w(1, 'event.create', NULL, '{"event":{"name":"Fête 🎉 Ñandú 夜"}}');
  IF r->>'name' <> 'Fête 🎉 Ñandú 夜' THEN RAISE EXCEPTION 'SIM-PARTNER-7 FAIL: unicode name %', r->>'name'; END IF;
  INSERT INTO e9 VALUES ('ev7', r->>'id');
  s := pg_temp.wst(1, 'ticket_type.create', r->>'id', '{"ticket_type":{"name":"Neg","price":-5,"capacity":10}}');
  IF s = 'ok' THEN RAISE EXCEPTION 'SIM-PARTNER-7 FAIL: a negative price was accepted'; END IF;
  s := pg_temp.wst(1, 'ticket_type.create', r->>'id', '{"ticket_type":{"name":"Huge","price":5,"capacity":99999999999}}');
  IF s = 'ok' THEN RAISE EXCEPTION 'SIM-PARTNER-7 FAIL: an 11-digit capacity was accepted'; END IF;
  s := pg_temp.wst(1, 'event.update', r->>'id', '{"event":{"total_tickets":-1}}');
  IF s = 'ok' THEN RAISE EXCEPTION 'SIM-PARTNER-7 FAIL: negative total_tickets accepted'; END IF;
  s := pg_temp.wst(1, 'event.update', r->>'id', '{"event":{"name":"   "}}');
  IF s <> '22023' THEN RAISE EXCEPTION 'SIM-PARTNER-7 FAIL: a blank name: %', s; END IF;
  RAISE NOTICE 'OK SIM-PARTNER-7 unicode names round-trip; negative price / capacity overflow / blank name refused';
END $$;

-- ============================================================================
-- Partner sales (#74)
-- ============================================================================

-- SIM-PARTNER-8: reserves and never completes; nothing sweeps for a while.
DO $$
DECLARE r jsonb; a0 int; a1 int; a2 int;
BEGIN
  a0 := public.exos_effective_available('e9000000-0000-0000-0000-0000000000d1');
  r := public._exos_partner_reserve('e9000000-0000-0000-0000-000000000001', 'e9000000-0000-0000-0000-0000000000e1',
         pg_temp.p('pA'), NULL, pg_temp.line('d1', 5), '{}');
  INSERT INTO e9 VALUES ('abandoned', r->>'token');
  a1 := public.exos_effective_available('e9000000-0000-0000-0000-0000000000d1');
  -- Ten minutes pass with no sweep and no read.
  UPDATE public.exos_partner_reservations SET expires_at = now() - interval '1 second' WHERE token = r->>'token';
  UPDATE public.exos_cart_holds SET expires_at = now() - interval '1 second'
   WHERE partner_reservation_id = (SELECT id FROM public.exos_partner_reservations WHERE token = r->>'token');
  a2 := public.exos_effective_available('e9000000-0000-0000-0000-0000000000d1');
  IF a1 <> a0 - 5 OR a2 <> a0 THEN RAISE EXCEPTION 'SIM-PARTNER-8 FAIL: availability % -> % -> %', a0, a1, a2; END IF;
  IF (SELECT status FROM public.exos_partner_reservations WHERE token = r->>'token') <> 'active' THEN
    RAISE EXCEPTION 'SIM-PARTNER-8 FAIL: setup';
  END IF;
  -- The sweep (scheduled every minute by mig 20261104130000) says so.
  PERFORM public.exos_partner_reservations_sweep(50);
  IF (SELECT status FROM public.exos_partner_reservations WHERE token = r->>'token') <> 'expired' THEN
    RAISE EXCEPTION 'SIM-PARTNER-8 FAIL: the sweep left it active';
  END IF;
  RAISE NOTICE 'OK SIM-PARTNER-8 an abandoned reservation''s seats come back at expiry; the sweep closes it';
END $$;

-- SIM-PARTNER-9: completes after expiry.
DO $$
DECLARE c jsonb;
BEGIN
  c := public._exos_partner_reservation_complete('e9000000-0000-0000-0000-000000000001', pg_temp.p('pA'),
         pg_temp.v('abandoned'), NULL, NULL);
  IF c->>'status' <> 'expired' OR EXISTS (SELECT 1 FROM public.exos_tickets WHERE event_id = 'e9000000-0000-0000-0000-0000000000e1'
                                              AND channel_source LIKE 'partner:%') THEN
    RAISE EXCEPTION 'SIM-PARTNER-9 FAIL: %', c;
  END IF;
  RAISE NOTICE 'OK SIM-PARTNER-9 completing after expiry sells nothing (410 expired at the edge)';
END $$;

-- SIM-PARTNER-10: completes twice (a retried complete), then cancels after completing.
DO $$
DECLARE r jsonb; c1 jsonb; c2 jsonb; s text;
BEGIN
  r := public._exos_partner_reserve('e9000000-0000-0000-0000-000000000001', 'e9000000-0000-0000-0000-0000000000e1',
         pg_temp.p('pA'), NULL, pg_temp.line('d1', 2), '{"email":"fan@x.com"}');
  c1 := public._exos_partner_reservation_complete('e9000000-0000-0000-0000-000000000001', pg_temp.p('pA'), r->>'token', NULL, NULL);
  c2 := public._exos_partner_reservation_complete('e9000000-0000-0000-0000-000000000001', pg_temp.p('pA'), r->>'token', NULL, NULL);
  IF NOT (c1->>'fresh')::boolean OR (c2->>'fresh')::boolean OR c1->'order'->>'id' <> c2->'order'->>'id'
     OR (SELECT count(*) FROM public.exos_tickets WHERE event_id = 'e9000000-0000-0000-0000-0000000000e1'
           AND order_ref = 'po:' || (c1->'order'->>'id')) <> 2 THEN
    RAISE EXCEPTION 'SIM-PARTNER-10 FAIL: % / %', c1, c2;
  END IF;
  s := pg_temp.st(format($q$SELECT public._exos_partner_reservation_cancel('e9000000-0000-0000-0000-000000000001', %L, %L)$q$,
                         pg_temp.p('pA'), r->>'token'));
  IF s <> 'EX409' THEN RAISE EXCEPTION 'SIM-PARTNER-10 FAIL: cancel after complete: %', s; END IF;
  INSERT INTO e9 VALUES ('done', r->>'token');
  RAISE NOTICE 'OK SIM-PARTNER-10 complete is idempotent (one order, two tickets); cancel after complete is 409';
END $$;

-- SIM-PARTNER-11: reserves more than is left; and bad quantities.
DO $$
DECLARE s text; q jsonb;
BEGIN
  s := pg_temp.st(format($q$SELECT public._exos_partner_reserve('e9000000-0000-0000-0000-000000000001',
         'e9000000-0000-0000-0000-0000000000e1', %L, NULL, pg_temp.line('d2', 4), '{}')$q$, pg_temp.p('pA')));
  IF s <> 'EXSLD' THEN RAISE EXCEPTION 'SIM-PARTNER-11 FAIL: 4 of 3: %', s; END IF;
  FOREACH q IN ARRAY ARRAY[
      '[{"ticket_type_id":"e9000000-0000-0000-0000-0000000000d1","quantity":0}]',
      '[{"ticket_type_id":"e9000000-0000-0000-0000-0000000000d1","quantity":-2}]',
      '[{"ticket_type_id":"e9000000-0000-0000-0000-0000000000d1","quantity":1.5}]',
      '[{"ticket_type_id":"e9000000-0000-0000-0000-0000000000d1","quantity":101}]',
      '[{"ticket_type_id":"e9000000-0000-0000-0000-0000000000d1","quantity":"lots"}]',
      '[{"ticket_type_id":"not-a-uuid","quantity":1}]',
      '[]', '{}']::jsonb[] LOOP
    s := pg_temp.st(format($q$SELECT public._exos_partner_reserve('e9000000-0000-0000-0000-000000000001',
           'e9000000-0000-0000-0000-0000000000e1', %L, NULL, %L, '{}')$q$, pg_temp.p('pA'), q));
    IF s <> '22023' THEN RAISE EXCEPTION 'SIM-PARTNER-11 FAIL: % gave %', q, s; END IF;
  END LOOP;
  -- 10 lines of 10 of one tier adds up to 100 (fine), 11 lines is refused.
  s := pg_temp.st(format($q$SELECT public._exos_partner_reserve('e9000000-0000-0000-0000-000000000001',
         'e9000000-0000-0000-0000-0000000000e1', %L, NULL,
         (SELECT jsonb_agg(jsonb_build_object('ticket_type_id','e9000000-0000-0000-0000-0000000000d1','quantity',1)) FROM generate_series(1,11)),
         '{}')$q$, pg_temp.p('pA')));
  IF s <> '22023' THEN RAISE EXCEPTION 'SIM-PARTNER-11 FAIL: 11 lines: %', s; END IF;
  -- Negative cash at the SQL layer (exos-api refuses it first).
  s := pg_temp.st(format($q$SELECT public._exos_partner_reserve('e9000000-0000-0000-0000-000000000001',
         'e9000000-0000-0000-0000-0000000000e1', %L, NULL, pg_temp.line('d1', 1), '{"cash_paid_cents":-100}')$q$, pg_temp.p('pA')));
  IF s = 'ok' THEN RAISE EXCEPTION 'SIM-PARTNER-11 FAIL: negative cash paid stored'; END IF;
  IF EXISTS (SELECT 1 FROM public.exos_cart_holds WHERE tier_id = 'e9000000-0000-0000-0000-0000000000d2') THEN
    RAISE EXCEPTION 'SIM-PARTNER-11 FAIL: a refused reservation left a hold';
  END IF;
  RAISE NOTICE 'OK SIM-PARTNER-11 oversell refused (sold_out); quantity 0 / negative / decimal / 101 / text / 11 lines refused, no holds left';
END $$;

-- SIM-PARTNER-12: reserves a seated type, and reserves during last call.
DO $$
DECLARE s text;
BEGIN
  -- A seated type needs a real seat map (exos_ticket_tiers_seated_guard resets
  -- a bare flag), and a timed one a schedule: test_integration.sql I3 drives
  -- both through _exos_partner_reserve. Here: the gate itself is in reserve.
  ASSERT position('_exos_tier_needs_picker(t.id)' in pg_get_functiondef(
    'public._exos_partner_reserve(uuid,uuid,uuid,uuid,jsonb,jsonb,boolean,boolean)'::regprocedure)) > 0,
    'SIM-PARTNER-12 FAIL: reserve lost the seats / time slots gate';
  PERFORM pg_temp.act('e9000000-0000-0000-0000-0000000000a1');
  PERFORM public.exos_set_last_call_threshold('e9000000-0000-0000-0000-0000000000e1', 1000);
  PERFORM pg_temp.act(NULL);
  s := pg_temp.st(format($q$SELECT public._exos_partner_reserve('e9000000-0000-0000-0000-000000000001',
         'e9000000-0000-0000-0000-0000000000e1', %L, NULL, pg_temp.line('d1', 1), '{}')$q$, pg_temp.p('pA')));
  IF s <> 'EX422' THEN RAISE EXCEPTION 'SIM-PARTNER-12 FAIL: last call: %', s; END IF;
  PERFORM pg_temp.act('e9000000-0000-0000-0000-0000000000a1');
  PERFORM public.exos_set_last_call_threshold('e9000000-0000-0000-0000-0000000000e1', NULL);
  PERFORM pg_temp.act(NULL);
  RAISE NOTICE 'OK SIM-PARTNER-12 seated / timed types (I3) and last call refuse partner reservations (422 not_available)';
END $$;

-- SIM-PARTNER-13: reserves during a member presale.
SET LOCAL ROLE authenticated;
DO $$
BEGIN
  PERFORM pg_temp.act('e9000000-0000-0000-0000-0000000000a1');
  INSERT INTO public.exos_membership_products (id, org_id, name, price_cents, billing, discount_percent, presale,
                                               free_tickets_per_period, guest_allowance, household_seats)
  VALUES ('e9000000-0000-0000-0000-00000000c001', 'e9000000-0000-0000-0000-000000000001', 'E9 Member', 1000, 'month', 0, true, 0, 0, 0);
  PERFORM public.exos_set_member_presale('e9000000-0000-0000-0000-0000000000e1', NULL, now() + interval '1 day',
    ARRAY['e9000000-0000-0000-0000-0000000000d4']::uuid[], '{}');
  PERFORM pg_temp.act(NULL);
END $$;
RESET ROLE;
DO $$
DECLARE s text; o jsonb;
BEGIN
  s := pg_temp.st(format($q$SELECT public._exos_partner_reserve('e9000000-0000-0000-0000-000000000001',
         'e9000000-0000-0000-0000-0000000000e1', %L, NULL, pg_temp.line('d4', 2), '{}')$q$, pg_temp.p('pA')));
  -- Before mig 20261104130000: 'ok' (a marketplace sold the members' presale).
  IF s <> 'EX422' THEN RAISE EXCEPTION 'SIM-PARTNER-13 FAIL: a partner reserved a presale type: %', s; END IF;
  -- A type outside the presale still sells; the organizer's box office sells the presale type.
  PERFORM public._exos_partner_reserve('e9000000-0000-0000-0000-000000000001', 'e9000000-0000-0000-0000-0000000000e1',
    pg_temp.p('pA'), NULL, pg_temp.line('d1', 1), '{}');
  o := public._exos_partner_reserve('e9000000-0000-0000-0000-000000000001', 'e9000000-0000-0000-0000-0000000000e1',
         NULL, 'e9000000-0000-0000-0000-0000000000f1', pg_temp.line('d4', 1), '{}');
  IF o->>'status' <> 'active' THEN RAISE EXCEPTION 'SIM-PARTNER-13 FAIL: box office %', o; END IF;
  PERFORM public._exos_partner_reservation_cancel('e9000000-0000-0000-0000-000000000001', NULL, o->>'token');
  -- After the presale, partners sell it.
  UPDATE public.exos_member_presales SET ends_at = now() - interval '1 second', starts_at = now() - interval '2 days'
   WHERE event_id = 'e9000000-0000-0000-0000-0000000000e1';
  PERFORM public._exos_partner_reserve('e9000000-0000-0000-0000-000000000001', 'e9000000-0000-0000-0000-0000000000e1',
    pg_temp.p('pA'), NULL, pg_temp.line('d4', 1), '{}');
  RAISE NOTICE 'OK SIM-PARTNER-13 FIXED a partner can''t reserve a member-presale type while the presale runs';
END $$;

-- SIM-PARTNER-14: retries POST …/ticket_reservations after a timeout.
DO $$
DECLARE r1 jsonb; r2 jsonb; r3 jsonb; s text; h0 int; h1 int; h2 int;
BEGIN
  SELECT coalesce(sum(quantity), 0) INTO h0 FROM public.exos_cart_holds WHERE tier_id = 'e9000000-0000-0000-0000-0000000000d1' AND status = 'active';
  -- No key: each resend holds the seats again (the old behaviour, still the
  -- keyless one; the extra hold lapses in 10 minutes).
  r1 := public._exos_partner_reserve('e9000000-0000-0000-0000-000000000001', 'e9000000-0000-0000-0000-0000000000e1',
          pg_temp.p('pA'), NULL, pg_temp.line('d1', 3), '{"idempotency_key":"sh-txn-000001"}');
  r2 := public._exos_partner_reserve('e9000000-0000-0000-0000-000000000001', 'e9000000-0000-0000-0000-0000000000e1',
          pg_temp.p('pA'), NULL, pg_temp.line('d1', 3), '{"idempotency_key":"sh-txn-000001"}');
  SELECT coalesce(sum(quantity), 0) INTO h1 FROM public.exos_cart_holds WHERE tier_id = 'e9000000-0000-0000-0000-0000000000d1' AND status = 'active';
  IF r1->>'token' <> r2->>'token' OR h1 - h0 <> 3 OR NOT coalesce((r2->>'idempotent_replay')::boolean, false) THEN
    RAISE EXCEPTION 'SIM-PARTNER-14 FAIL: % / % holds % -> %', r1->>'token', r2->>'token', h0, h1;
  END IF;
  -- Same key, other lines: refused.
  s := pg_temp.st(format($q$SELECT public._exos_partner_reserve('e9000000-0000-0000-0000-000000000001',
         'e9000000-0000-0000-0000-0000000000e1', %L, NULL, pg_temp.line('d1', 4), '{"idempotency_key":"sh-txn-000001"}')$q$,
         pg_temp.p('pA')));
  IF s <> '22023' THEN RAISE EXCEPTION 'SIM-PARTNER-14 FAIL: same key, 4 seats: %', s; END IF;
  -- Another partner of the org may use the same key string.
  r3 := public._exos_partner_reserve('e9000000-0000-0000-0000-000000000001', 'e9000000-0000-0000-0000-0000000000e1',
          pg_temp.p('pB'), NULL, pg_temp.line('d1', 3), '{"idempotency_key":"sh-txn-000001"}');
  IF r3->>'token' = r1->>'token' THEN RAISE EXCEPTION 'SIM-PARTNER-14 FAIL: partner B got partner A''s reservation'; END IF;
  SELECT coalesce(sum(quantity), 0) INTO h2 FROM public.exos_cart_holds WHERE tier_id = 'e9000000-0000-0000-0000-0000000000d1' AND status = 'active';
  IF h2 - h1 <> 3 THEN RAISE EXCEPTION 'SIM-PARTNER-14 FAIL: holds % -> %', h1, h2; END IF;
  INSERT INTO e9 VALUES ('rA', r1->>'token'), ('rB', r3->>'token');
  RAISE NOTICE 'OK SIM-PARTNER-14 FIXED an Idempotency-Key on reserve returns the first reservation; another body is refused';
END $$;

-- SIM-PARTNER-15: uses another partner's (or org's) reservation token.
DO $$
DECLARE s text;
BEGIN
  s := pg_temp.st(format($q$SELECT public._exos_partner_reservation_complete('e9000000-0000-0000-0000-000000000001', %L, %L, NULL, NULL)$q$,
         pg_temp.p('pB'), pg_temp.v('rA')));
  IF s <> 'P0002' THEN RAISE EXCEPTION 'SIM-PARTNER-15 FAIL: B completed A''s: %', s; END IF;
  s := pg_temp.st(format($q$SELECT public._exos_partner_reservation_cancel('e9000000-0000-0000-0000-000000000002', %L, %L)$q$,
         pg_temp.p('pZ'), pg_temp.v('rA')));
  IF s <> 'P0002' THEN RAISE EXCEPTION 'SIM-PARTNER-15 FAIL: org 2 cancelled org 1''s: %', s; END IF;
  -- Org 2's partner can't reserve org 1's event, nor org 1's partner org 2's tier.
  s := pg_temp.st(format($q$SELECT public._exos_partner_reserve('e9000000-0000-0000-0000-000000000002',
         'e9000000-0000-0000-0000-0000000000e1', %L, NULL, pg_temp.line('d1', 1), '{}')$q$, pg_temp.p('pZ')));
  IF s <> 'P0002' THEN RAISE EXCEPTION 'SIM-PARTNER-15 FAIL: org 2 partner, org 1 event: %', s; END IF;
  s := pg_temp.st(format($q$SELECT public._exos_partner_reserve('e9000000-0000-0000-0000-000000000001',
         'e9000000-0000-0000-0000-0000000000e1', %L, NULL, pg_temp.line('d9', 1), '{}')$q$, pg_temp.p('pA')));
  IF s <> 'EX422' THEN RAISE EXCEPTION 'SIM-PARTNER-15 FAIL: another event''s tier: %', s; END IF;
  -- Valid-looking ids across orgs answer not found, never the other org's data.
  IF public._exos_partner_order('e9000000-0000-0000-0000-000000000002', pg_temp.p('pZ'),
       (SELECT id FROM public.exos_partner_reservations WHERE token = pg_temp.v('done')), NULL) IS NOT NULL THEN
    RAISE EXCEPTION 'SIM-PARTNER-15 FAIL: org 2 read org 1''s order';
  END IF;
  RAISE NOTICE 'OK SIM-PARTNER-15 other partners'' and orgs'' tokens / events / orders are not found';
END $$;

-- SIM-PARTNER-16: a retried comp, and emoji in the attendee's name.
DO $$
DECLARE c1 jsonb; c2 jsonb; n0 int; n1 int; n2 int;
BEGIN
  SELECT count(*) INTO n0 FROM public.exos_tickets WHERE event_id = 'e9000000-0000-0000-0000-0000000000e1';
  c1 := public._exos_partner_comp('e9000000-0000-0000-0000-000000000001', pg_temp.p('pA'), 'e9000000-0000-0000-0000-0000000000e1',
          pg_temp.line('d1', 2), jsonb_build_object('first_name', repeat('🎟', 60), 'idempotency_key', 'sh-comp-000001'), NULL);
  SELECT count(*) INTO n1 FROM public.exos_tickets WHERE event_id = 'e9000000-0000-0000-0000-0000000000e1';
  c2 := public._exos_partner_comp('e9000000-0000-0000-0000-000000000001', pg_temp.p('pA'), 'e9000000-0000-0000-0000-0000000000e1',
          pg_temp.line('d1', 2), jsonb_build_object('first_name', repeat('🎟', 60), 'idempotency_key', 'sh-comp-000001'), NULL);
  SELECT count(*) INTO n2 FROM public.exos_tickets WHERE event_id = 'e9000000-0000-0000-0000-0000000000e1';
  IF n1 - n0 <> 2 OR n2 <> n1 OR c1->'order'->>'id' <> c2->'order'->>'id' THEN
    RAISE EXCEPTION 'SIM-PARTNER-16 FAIL: % % % / % / %', n0, n1, n2, c1->'order'->>'id', c2->'order'->>'id';
  END IF;
  IF c1->'order'->>'first_name' <> repeat('🎟', 60) THEN RAISE EXCEPTION 'SIM-PARTNER-16 FAIL: name %', c1->'order'->>'first_name'; END IF;
  RAISE NOTICE 'OK SIM-PARTNER-16 FIXED a retried comp with its key mints once; 60 emoji fit the 60-character name';
END $$;

-- SIM-PARTNER-17: paging the partner's orders: past the end, 0, 10000.
DO $$
DECLARE o jsonb;
BEGIN
  o := public._exos_partner_orders('e9000000-0000-0000-0000-000000000001', pg_temp.p('pA'), '{}', 999, 25, NULL);
  IF jsonb_array_length(o->'collection') <> 0 OR (o->>'total_entries')::int < 2 THEN RAISE EXCEPTION 'SIM-PARTNER-17 FAIL: past the end %', o; END IF;
  o := public._exos_partner_orders('e9000000-0000-0000-0000-000000000001', pg_temp.p('pA'), '{}', 0, 0, NULL);
  IF (o->>'per_page')::int <> 1 OR (o->>'current_page')::int <> 1 THEN RAISE EXCEPTION 'SIM-PARTNER-17 FAIL: zeros %', o - 'collection'; END IF;
  o := public._exos_partner_orders('e9000000-0000-0000-0000-000000000001', pg_temp.p('pA'), '{}', 1, 10000, NULL);
  IF (o->>'per_page')::int <> 250 THEN RAISE EXCEPTION 'SIM-PARTNER-17 FAIL: 10000 %', o - 'collection'; END IF;
  o := public._exos_partner_orders('e9000000-0000-0000-0000-000000000001', pg_temp.p('pA'), '{}', -3, -5, NULL);
  IF (o->>'per_page')::int <> 1 OR (o->>'current_page')::int <> 1 THEN RAISE EXCEPTION 'SIM-PARTNER-17 FAIL: negatives %', o - 'collection'; END IF;
  -- (exos-api answers 400 for page/per_page 0 or negative before this;
  -- src/lib/sim/partner.test.ts.)
  RAISE NOTICE 'OK SIM-PARTNER-17 partner order paging: past the end is empty, sizes clamp to 1-250';
END $$;

-- SIM-PARTNER-18: a gift card on an organizer reservation that is then abandoned.
DO $$
DECLARE g jsonb; r jsonb; a jsonb; b0 int; b1 int; b2 int;
BEGIN
  g := public._exos_gift_card_issue('e9000000-0000-0000-0000-000000000001', NULL, 5000, 'usd', 'dashboard', 'comp',
                                    NULL, NULL, NULL, NULL, NULL, NULL, NULL, false);
  b0 := (SELECT balance_cents FROM public.exos_gift_cards WHERE id = (g->>'card_id')::uuid);
  r := public._exos_partner_reserve('e9000000-0000-0000-0000-000000000001', 'e9000000-0000-0000-0000-0000000000e1',
         NULL, 'e9000000-0000-0000-0000-0000000000f1', pg_temp.line('d1', 1), '{}');
  a := public._exos_reservation_gift_card_apply('e9000000-0000-0000-0000-000000000001', NULL, r->>'token', g->>'code', NULL,
                                                'sim:e9', 'e9-gc-apply-1');
  b1 := (SELECT balance_cents FROM public.exos_gift_cards WHERE id = (g->>'card_id')::uuid);
  IF a ? 'error' OR b1 >= b0 THEN RAISE EXCEPTION 'SIM-PARTNER-18 FAIL: apply % (% -> %)', a, b0, b1; END IF;
  UPDATE public.exos_partner_reservations SET expires_at = now() - interval '1 second' WHERE token = r->>'token';
  -- Nobody reads it again: only the sweep gives the balance back.
  PERFORM public.exos_partner_reservations_sweep(50);
  b2 := (SELECT balance_cents FROM public.exos_gift_cards WHERE id = (g->>'card_id')::uuid);
  IF b2 <> b0 THEN RAISE EXCEPTION 'SIM-PARTNER-18 FAIL: balance % -> % -> %', b0, b1, b2; END IF;
  -- The migration schedules the sweep where pg_cron exists (none in this harness).
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    EXECUTE 'SELECT count(*) FROM cron.job WHERE jobname = ''exos-partner-reservations-sweep''' INTO b1;
    IF b1 <> 1 THEN RAISE EXCEPTION 'SIM-PARTNER-18 FAIL: the sweep isn''t scheduled'; END IF;
  END IF;
  RAISE NOTICE 'OK SIM-PARTNER-18 FIXED an abandoned reservation''s gift card balance comes back on the (now scheduled) sweep';
END $$;

-- ============================================================================
-- Writes from the gap PRs: wrong ids, other orgs' ids, duplicates
-- ============================================================================

-- SIM-PARTNER-23: reserves more than the partner's share. There is no
-- per-partner cap: partners share the primary pool, which already leaves out
-- what is allocated to other channels (exos_channel_allocated).
DO $$
DECLARE s text; a0 int; a1 int;
BEGIN
  a0 := public.exos_effective_available('e9000000-0000-0000-0000-0000000000d1');
  INSERT INTO public.exos_distribution_listings (event_id, org_id, channel, status, tier_id, requested_qty)
  VALUES ('e9000000-0000-0000-0000-0000000000e1', 'e9000000-0000-0000-0000-000000000001', 'seatgeek', 'listed',
          'e9000000-0000-0000-0000-0000000000d1', 2);
  a1 := public.exos_effective_available('e9000000-0000-0000-0000-0000000000d1');
  IF a1 <> a0 - 2 THEN RAISE EXCEPTION 'SIM-PARTNER-23 FAIL: allocation not subtracted % -> %', a0, a1; END IF;
  s := pg_temp.st(format($q$SELECT public._exos_partner_reserve('e9000000-0000-0000-0000-000000000001',
         'e9000000-0000-0000-0000-0000000000e1', %L, NULL, pg_temp.line('d1', %s), '{}')$q$, pg_temp.p('pB'), a1 + 1));
  IF s <> 'EXSLD' THEN RAISE EXCEPTION 'SIM-PARTNER-23 FAIL: reserved into another channel''s allocation: %', s; END IF;
  -- KNOWN: one partner can take the whole primary pool (no per-partner quota).
  RAISE NOTICE 'KNOWN SIM-PARTNER-23 partners can''t reserve another channel''s allocation, but there is no per-partner cap (% left, any one partner may take all)', a1;
END $$;

-- SIM-PARTNER-19: gift-card import: a replay, a reused key with another file,
-- a re-import under a new key, the same code in another org.
SET LOCAL ROLE service_role;
DO $$
DECLARE r1 jsonb; r2 jsonb; s text;
BEGIN
  r1 := public.exos_api_gift_card_import('e9000000-0000-0000-0000-000000000001', 'gift_up',
          '[{"code":"E9GIFT0001","balance_cents":2500}]', 'api:e9-import-0001');
  r2 := public.exos_api_gift_card_import('e9000000-0000-0000-0000-000000000001', 'gift_up',
          '[{"code":"E9GIFT0001","balance_cents":2500}]', 'api:e9-import-0001');
  IF NOT (r1->>'fresh')::boolean OR (r2->>'fresh')::boolean OR (r1->>'created')::int <> 1 THEN
    RAISE EXCEPTION 'SIM-PARTNER-19 FAIL: replay % / %', r1, r2;
  END IF;
  s := pg_temp.st($q$SELECT public.exos_api_gift_card_import('e9000000-0000-0000-0000-000000000001', 'gift_up',
          '[{"code":"E9GIFT0002","balance_cents":9900}]', 'api:e9-import-0001')$q$);
  IF s <> '22023' THEN RAISE EXCEPTION 'SIM-PARTNER-19 FAIL: another file under the same key: %', s; END IF;
  r2 := public.exos_api_gift_card_import('e9000000-0000-0000-0000-000000000001', 'gift_up',
          '[{"code":"e9-gift-0001","balance_cents":2500}]', 'api:e9-import-0002');
  IF (r2->>'created')::int <> 0 OR (r2->>'duplicates')::int <> 1 THEN RAISE EXCEPTION 'SIM-PARTNER-19 FAIL: re-import %', r2; END IF;
  r2 := public.exos_api_gift_card_import('e9000000-0000-0000-0000-000000000002', 'gift_up',
          '[{"code":"E9GIFT0001","balance_cents":100}]', 'api:e9-import-0001');
  IF (r2->>'created')::int <> 1 OR NOT (r2->>'fresh')::boolean THEN RAISE EXCEPTION 'SIM-PARTNER-19 FAIL: org 2 %', r2; END IF;
  IF (SELECT sum(balance_cents) FROM public.exos_gift_cards WHERE org_id = 'e9000000-0000-0000-0000-000000000001' AND source = 'import') <> 2500 THEN
    RAISE EXCEPTION 'SIM-PARTNER-19 FAIL: org 1 holds the wrong stored value';
  END IF;
  RAISE NOTICE 'OK SIM-PARTNER-19 FIXED gift-card import: replay ok, reused key + other file 400, re-import is duplicates, orgs apart';
END $$;

-- SIM-PARTNER-20: donations and recurring donations by another org's ids.
DO $$
DECLARE s text;
BEGIN
  s := pg_temp.st($q$SELECT public.exos_api_donation_op('e9000000-0000-0000-0000-000000000002', 'delete',
                    gen_random_uuid(), '{}')$q$);
  IF s <> 'P0002' THEN RAISE EXCEPTION 'SIM-PARTNER-20 FAIL: donation delete %', s; END IF;
  s := pg_temp.st($q$SELECT public.exos_recurring_donation_cancel('e9000000-0000-0000-0000-000000000002', gen_random_uuid())$q$);
  IF s <> 'P0002' THEN RAISE EXCEPTION 'SIM-PARTNER-20 FAIL: recurring cancel %', s; END IF;
  RAISE NOTICE 'OK SIM-PARTNER-20 donation / recurring-donation writes with unknown or foreign ids are not found';
END $$;
RESET ROLE;

-- SIM-PARTNER-21: brackets on another org's offer, GL codes of another org,
-- a ledger import naming another org's event.
DO $$
DECLARE s text; r jsonb;
BEGIN
  INSERT INTO public.exos_budgets (id, org_id, name) VALUES
    ('e9000000-0000-0000-0000-00000000bb02', 'e9000000-0000-0000-0000-000000000002', 'Other budget');
  INSERT INTO public.exos_offers (id, org_id, budget_id, title, artist_name) VALUES
    ('e9000000-0000-0000-0000-00000000ff02', 'e9000000-0000-0000-0000-000000000002', 'e9000000-0000-0000-0000-00000000bb02',
     'Other offer', 'Other act');
  INSERT INTO public.exos_gl_codes (id, org_id, code, name) VALUES
    ('e9000000-0000-0000-0000-00000000cc02', 'e9000000-0000-0000-0000-000000000002', '4000', 'Other revenue');
  -- A signed-in org-1 owner writing a bracket on org 2's offer.
  PERFORM pg_temp.act('e9000000-0000-0000-0000-0000000000a1');
  s := pg_temp.st($q$INSERT INTO public.exos_deal_brackets (org_id, offer_id, threshold, percentage)
                    VALUES ('e9000000-0000-0000-0000-000000000001', 'e9000000-0000-0000-0000-00000000ff02', 100, 80)$q$);
  PERFORM pg_temp.act(NULL);
  IF s <> '42501' THEN RAISE EXCEPTION 'SIM-PARTNER-21 FAIL: bracket on another org''s offer: %', s; END IF;
  -- An override on org 1's event pointing at org 2's ledger code.
  s := pg_temp.st($q$INSERT INTO public.exos_gl_code_assignments (org_id, event_id, revenue_type, gl_code_id)
                    VALUES ('e9000000-0000-0000-0000-000000000001', 'e9000000-0000-0000-0000-0000000000e1',
                            'tickets', 'e9000000-0000-0000-0000-00000000cc02')$q$);
  IF s NOT IN ('22023', '23514') THEN RAISE EXCEPTION 'SIM-PARTNER-21 FAIL: foreign gl code: %', s; END IF;
  r := public._exos_ledger_import('e9000000-0000-0000-0000-000000000001', NULL, 'api', 'e9000000-0000-0000-0000-0000000000f1',
         '[{"event_id":"e9000000-0000-0000-0000-0000000000e9","posted_at":"2026-11-01T10:00:00Z","amount_cents":100,"external_id":"x1"}]');
  IF r::text NOT LIKE '%not one of this organization%' THEN RAISE EXCEPTION 'SIM-PARTNER-21 FAIL: ledger import %', r; END IF;
  IF EXISTS (SELECT 1 FROM public.exos_imported_ledger_entries WHERE event_id = 'e9000000-0000-0000-0000-0000000000e9') THEN
    RAISE EXCEPTION 'SIM-PARTNER-21 FAIL: an entry landed on org 2''s event';
  END IF;
  RAISE NOTICE 'OK SIM-PARTNER-21 brackets / GL overrides / ledger rows can''t point at another org''s offer, code or event';
END $$;

-- SIM-PARTNER-22: inbound submissions: a hold from another org's submission;
-- a status change on an unknown id.
DO $$
DECLARE v_sub uuid; s text;
BEGIN
  INSERT INTO public.exos_inbound_settings (org_id, enabled) VALUES ('e9000000-0000-0000-0000-000000000002', true);
  INSERT INTO public.exos_inbound_submissions (org_id, artist_name, email)
  VALUES ('e9000000-0000-0000-0000-000000000002', 'Band', 'band@x.com') RETURNING id INTO v_sub;
  PERFORM pg_temp.act('e9000000-0000-0000-0000-0000000000a1');
  s := pg_temp.st(format($q$SELECT public.exos_inbound_create_hold(%L, '{}')$q$, v_sub));
  IF s NOT IN ('42501', 'P0002') THEN RAISE EXCEPTION 'SIM-PARTNER-22 FAIL: org 1 held org 2''s submission: %', s; END IF;
  s := pg_temp.st(format($q$SELECT public.exos_inbound_set_status(%L, 'accepted')$q$, v_sub));
  IF s NOT IN ('42501', 'P0002') THEN RAISE EXCEPTION 'SIM-PARTNER-22 FAIL: org 1 accepted org 2''s submission: %', s; END IF;
  s := pg_temp.st(format($q$SELECT public.exos_inbound_set_status(%L, 'accepted')$q$, gen_random_uuid()));
  IF s NOT IN ('42501', 'P0002') THEN RAISE EXCEPTION 'SIM-PARTNER-22 FAIL: unknown id: %', s; END IF;
  PERFORM pg_temp.act(NULL);
  IF (SELECT status FROM public.exos_inbound_submissions WHERE id = v_sub) <> 'new' THEN
    RAISE EXCEPTION 'SIM-PARTNER-22 FAIL: org 2''s submission changed';
  END IF;
  RAISE NOTICE 'OK SIM-PARTNER-22 inbound submissions: another org''s or an unknown id is refused';
END $$;

-- ============================================================================
-- Grants on what this migration added.
-- ============================================================================
DO $$
BEGIN
  IF has_function_privilege('anon', 'public._exos_api_request_hash(text,text,jsonb)', 'EXECUTE')
     OR has_function_privilege('authenticated', 'public._exos_api_request_hash(text,text,jsonb)', 'EXECUTE') THEN
    RAISE EXCEPTION 'SIM-PARTNER-G FAIL: the hash helper is callable by clients';
  END IF;
  IF has_function_privilege('authenticated', 'public._exos_partner_reserve(uuid,uuid,uuid,uuid,jsonb,jsonb,boolean,boolean)', 'EXECUTE')
     OR NOT has_function_privilege('service_role', 'public._exos_partner_reserve(uuid,uuid,uuid,uuid,jsonb,jsonb,boolean,boolean)', 'EXECUTE')
     OR has_function_privilege('authenticated', 'public.exos_api_write(uuid,text,text,jsonb,text)', 'EXECUTE') THEN
    RAISE EXCEPTION 'SIM-PARTNER-G FAIL: a patched function''s grants changed';
  END IF;
  RAISE NOTICE 'OK SIM-PARTNER-G grants kept after the patches';
END $$;

ROLLBACK;
