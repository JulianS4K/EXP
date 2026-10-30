-- ============================================================================
-- The core partner API's writes + publish blockers (mig 20261031110000).
-- Self-contained (c7 prefix), rolled back. Org 1: owner a1, manager a2,
-- scanner a3, finance a4, content a6; org 2: owner a5. (Real keys are made by
-- owners / managers; the scanner / finance keys here are fixtures that pin the
-- role check to the creator.) Keys are inserted directly (the
-- edge function hashes the bearer key and passes the key id).
--   C1  grants: exos_api_write is service_role only; the helpers nobody's
--   C2  the key's scope is checked again in SQL; unknown action refused
--   C3  writes run as the key's creator: a scanner's key can't create events,
--       a key whose creator left can't write at all
--   C4  event create: a draft in the key's org, creator stamped, ticket types,
--       occurs_at_local derived, unknown / server-owned fields refused
--   C5  publish blockers + publish: refused with the list, published once
--       clear; dashboard RPCs (content may read blockers, not publish)
--   C6  update: cross-org targets are not found; name can't be blanked
--   C7  ticket types: create / update / delete; a type with tickets stays
--   C8  promo codes via exos_issue_voucher: dup code 23505; update; delete
--   C9  add-ons: create / update / delete
--   C10 refunds: Idempotency-Key required; same key = same request; key
--       reused on another order refused; role from the creator (finance ok,
--       scanner refused); cross-org order not found; logged money_moving
--   C11 comps: issued through the batch; a replayed key issues nothing new
--   C12 door: manual check-in (owner) / needs-manager (scanner key); undo;
--       order check-in; offline batch with a foreign ticket = not-found
--   C13 guest lists: create, update, add, edit, check in, remove, delete
--   C14 the request's claims are put back after each call
--   C15 exos_api_writes: RLS (owner / manager of the org only)
--   C16 an Idempotency-Key reused for another action is refused
-- ============================================================================
\set ON_ERROR_STOP on
BEGIN;

-- auth.uid() / auth.jwt() as Supabase defines them (the request's JWT
-- claims), still honouring the harness's app.uid / app.jwt. Rolled back.
CREATE OR REPLACE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql STABLE AS $$
  SELECT coalesce(nullif(current_setting('app.uid', true), ''),
                  nullif(current_setting('request.jwt.claim.sub', true), ''),
                  nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'sub')::uuid
$$;
CREATE OR REPLACE FUNCTION auth.jwt() RETURNS jsonb LANGUAGE sql STABLE AS $$
  SELECT coalesce(nullif(current_setting('app.jwt', true), ''),
                  nullif(current_setting('request.jwt.claims', true), ''), '{}')::jsonb
$$;
SELECT set_config('app.uid', '', false), set_config('app.jwt', '', false);

INSERT INTO auth.users(id,email,email_confirmed_at) VALUES
  ('c7000000-0000-0000-0000-0000000000a1','c7-owner@x.com',now()),
  ('c7000000-0000-0000-0000-0000000000a2','c7-manager@x.com',now()),
  ('c7000000-0000-0000-0000-0000000000a3','c7-scanner@x.com',now()),
  ('c7000000-0000-0000-0000-0000000000a4','c7-finance@x.com',now()),
  ('c7000000-0000-0000-0000-0000000000a5','c7-other@x.com',now()),
  ('c7000000-0000-0000-0000-0000000000a6','c7-content@x.com',now()),
  ('c7000000-0000-0000-0000-0000000000b1','c7-buyer@x.com',now());
INSERT INTO public.exos_orgs(id,name,slug,owner_uid) VALUES
  ('c7000000-0000-0000-0000-000000000001','C7 Org','c7-org','c7000000-0000-0000-0000-0000000000a1'),
  ('c7000000-0000-0000-0000-000000000002','C7 Other','c7-other','c7000000-0000-0000-0000-0000000000a5');
INSERT INTO public.exos_org_memberships(org_id,user_id,role) VALUES
  ('c7000000-0000-0000-0000-000000000001','c7000000-0000-0000-0000-0000000000a1','owner'),
  ('c7000000-0000-0000-0000-000000000001','c7000000-0000-0000-0000-0000000000a2','manager'),
  ('c7000000-0000-0000-0000-000000000001','c7000000-0000-0000-0000-0000000000a3','scanner'),
  ('c7000000-0000-0000-0000-000000000001','c7000000-0000-0000-0000-0000000000a4','finance'),
  ('c7000000-0000-0000-0000-000000000001','c7000000-0000-0000-0000-0000000000a6','content'),
  ('c7000000-0000-0000-0000-000000000002','c7000000-0000-0000-0000-0000000000a5','owner');

-- Keys: k1 owner (everything), k2 scanner (events:write + checkin:write),
-- k3 owner (legacy read), k4 finance (refunds:write), k5 manager (all, its
-- creator leaves in C3), k6 org 2 owner (everything), k7 scanner (refunds:write).
INSERT INTO public.exos_api_keys(id,org_id,name,key_prefix,key_hash,scopes,created_by) VALUES
  ('c7000000-0000-0000-0000-0000000000f1','c7000000-0000-0000-0000-000000000001','k1','sk_live_c7k1','c7hash1',
   ARRAY['events:write','orders:read','refunds:write','tickets:write','checkin:write'],'c7000000-0000-0000-0000-0000000000a1'),
  ('c7000000-0000-0000-0000-0000000000f2','c7000000-0000-0000-0000-000000000001','k2','sk_live_c7k2','c7hash2',
   ARRAY['events:write','checkin:write'],'c7000000-0000-0000-0000-0000000000a3'),
  ('c7000000-0000-0000-0000-0000000000f3','c7000000-0000-0000-0000-000000000001','k3','sk_live_c7k3','c7hash3',
   ARRAY['read'],'c7000000-0000-0000-0000-0000000000a1'),
  ('c7000000-0000-0000-0000-0000000000f4','c7000000-0000-0000-0000-000000000001','k4','sk_live_c7k4','c7hash4',
   ARRAY['orders:read','refunds:write'],'c7000000-0000-0000-0000-0000000000a4'),
  ('c7000000-0000-0000-0000-0000000000f5','c7000000-0000-0000-0000-000000000001','k5','sk_live_c7k5','c7hash5',
   ARRAY['events:write'],'c7000000-0000-0000-0000-0000000000a2'),
  ('c7000000-0000-0000-0000-0000000000f6','c7000000-0000-0000-0000-000000000002','k6','sk_live_c7k6','c7hash6',
   ARRAY['events:write','orders:read','refunds:write','tickets:write','checkin:write'],'c7000000-0000-0000-0000-0000000000a5'),
  ('c7000000-0000-0000-0000-0000000000f7','c7000000-0000-0000-0000-000000000001','k7','sk_live_c7k7','c7hash7',
   ARRAY['refunds:write'],'c7000000-0000-0000-0000-0000000000a3');

-- e1: upcoming, paid GA (sold). e2: started an hour ago (doors open), published.
-- e9: org 2's event.
INSERT INTO public.exos_events(id,org_id,name,slug,status,starts_at,timezone,venue_name,total_tickets,tickets_sold,created_by) VALUES
  ('c7000000-0000-0000-0000-0000000000e1','c7000000-0000-0000-0000-000000000001','C7 Night','c7-night','published',
   now() + interval '5 days','America/New_York','The Room',100,3,'c7000000-0000-0000-0000-0000000000a1'),
  ('c7000000-0000-0000-0000-0000000000e2','c7000000-0000-0000-0000-000000000001','C7 Live','c7-live','published',
   now() - interval '1 hour','America/New_York','The Room',100,3,'c7000000-0000-0000-0000-0000000000a1'),
  ('c7000000-0000-0000-0000-0000000000e9','c7000000-0000-0000-0000-000000000002','C7 Elsewhere','c7-else','draft',
   now() + interval '5 days','America/New_York','Hall',10,1,'c7000000-0000-0000-0000-0000000000a5');
INSERT INTO public.exos_ticket_tiers(id,event_id,name,price,capacity,sold,visibility) VALUES
  ('c7000000-0000-0000-0000-0000000000d1','c7000000-0000-0000-0000-0000000000e1','GA',30,100,2,'public'),
  ('c7000000-0000-0000-0000-0000000000d2','c7000000-0000-0000-0000-0000000000e2','GA',20,100,3,'public'),
  ('c7000000-0000-0000-0000-0000000000d9','c7000000-0000-0000-0000-0000000000e9','GA',20,10,1,'public');
INSERT INTO public.exos_checkout_sessions(session_id,event_id,tier_id,org_id,buyer_uid,buyer_email,quantity,amount_cents,status,payment_intent) VALUES
  ('cs_c7a','c7000000-0000-0000-0000-0000000000e1','c7000000-0000-0000-0000-0000000000d1','c7000000-0000-0000-0000-000000000001',
   'c7000000-0000-0000-0000-0000000000b1','c7-buyer@x.com',2,6000,'fulfilled','pi_c7a'),
  ('cs_c7b','c7000000-0000-0000-0000-0000000000e1','c7000000-0000-0000-0000-0000000000d1','c7000000-0000-0000-0000-000000000001',
   'c7000000-0000-0000-0000-0000000000b1','c7-buyer@x.com',1,3000,'fulfilled','pi_c7b'),
  ('cs_c7c','c7000000-0000-0000-0000-0000000000e2','c7000000-0000-0000-0000-0000000000d2','c7000000-0000-0000-0000-000000000001',
   'c7000000-0000-0000-0000-0000000000b1','c7-buyer@x.com',2,4000,'fulfilled','pi_c7c'),
  ('cs_c7z','c7000000-0000-0000-0000-0000000000e9','c7000000-0000-0000-0000-0000000000d9','c7000000-0000-0000-0000-000000000002',
   'c7000000-0000-0000-0000-0000000000b1','c7-buyer@x.com',1,2000,'fulfilled','pi_c7z');
SELECT public.exos_record_payment('cs_c7a','pi_c7a',6000,'succeeded');
SELECT public.exos_record_payment('cs_c7b','pi_c7b',3000,'succeeded');
SELECT public.exos_record_payment('cs_c7z','pi_c7z',2000,'succeeded');
INSERT INTO public.exos_tickets(id,event_id,org_id,tier_id,buyer_id,owner_id,status,barcode_secret,price_paid,order_ref) VALUES
  ('c7000000-0000-0000-0000-000000000101','c7000000-0000-0000-0000-0000000000e1','c7000000-0000-0000-0000-000000000001','c7000000-0000-0000-0000-0000000000d1','c7000000-0000-0000-0000-0000000000b1','c7000000-0000-0000-0000-0000000000b1','active','s1',30,'cs_c7a'),
  ('c7000000-0000-0000-0000-000000000102','c7000000-0000-0000-0000-0000000000e1','c7000000-0000-0000-0000-000000000001','c7000000-0000-0000-0000-0000000000d1','c7000000-0000-0000-0000-0000000000b1','c7000000-0000-0000-0000-0000000000b1','active','s2',30,'cs_c7a'),
  ('c7000000-0000-0000-0000-000000000103','c7000000-0000-0000-0000-0000000000e1','c7000000-0000-0000-0000-000000000001','c7000000-0000-0000-0000-0000000000d1','c7000000-0000-0000-0000-0000000000b1','c7000000-0000-0000-0000-0000000000b1','active','s3',30,'cs_c7b'),
  ('c7000000-0000-0000-0000-000000000201','c7000000-0000-0000-0000-0000000000e2','c7000000-0000-0000-0000-000000000001','c7000000-0000-0000-0000-0000000000d2','c7000000-0000-0000-0000-0000000000b1','c7000000-0000-0000-0000-0000000000b1','active','s4',20,'cs_c7c'),
  ('c7000000-0000-0000-0000-000000000202','c7000000-0000-0000-0000-0000000000e2','c7000000-0000-0000-0000-000000000001','c7000000-0000-0000-0000-0000000000d2','c7000000-0000-0000-0000-0000000000b1','c7000000-0000-0000-0000-0000000000b1','active','s5',20,'cs_c7c'),
  ('c7000000-0000-0000-0000-000000000203','c7000000-0000-0000-0000-0000000000e2','c7000000-0000-0000-0000-000000000001','c7000000-0000-0000-0000-0000000000d2','c7000000-0000-0000-0000-0000000000b1','c7000000-0000-0000-0000-0000000000b1','active','s6',20,NULL),
  ('c7000000-0000-0000-0000-000000000901','c7000000-0000-0000-0000-0000000000e9','c7000000-0000-0000-0000-000000000002','c7000000-0000-0000-0000-0000000000d9','c7000000-0000-0000-0000-0000000000b1','c7000000-0000-0000-0000-0000000000b1','active','s9',20,'cs_c7z');

-- The SQLSTATE a call fails with ('ok' when it doesn't).
CREATE FUNCTION pg_temp.st(p_key text, p_action text, p_target text, p_args jsonb DEFAULT '{}', p_idem text DEFAULT NULL)
RETURNS text LANGUAGE plpgsql AS $$
BEGIN
  PERFORM public.exos_api_write(('c7000000-0000-0000-0000-0000000000' || p_key)::uuid, p_action, p_target, p_args, p_idem);
  RETURN 'ok';
EXCEPTION WHEN OTHERS THEN RETURN SQLSTATE;
END $$;
CREATE FUNCTION pg_temp.w(p_key text, p_action text, p_target text, p_args jsonb DEFAULT '{}', p_idem text DEFAULT NULL)
RETURNS jsonb LANGUAGE sql AS $$
  SELECT public.exos_api_write(('c7000000-0000-0000-0000-0000000000' || p_key)::uuid, p_action, p_target, p_args, p_idem)
$$;

-- C1 -----------------------------------------------------------------------------
DO $$
DECLARE f text;
BEGIN
  IF NOT has_function_privilege('service_role', 'public.exos_api_write(uuid,text,text,jsonb,text)', 'EXECUTE')
     OR has_function_privilege('anon', 'public.exos_api_write(uuid,text,text,jsonb,text)', 'EXECUTE')
     OR has_function_privilege('authenticated', 'public.exos_api_write(uuid,text,text,jsonb,text)', 'EXECUTE') THEN
    RAISE EXCEPTION 'C1 FAIL: exos_api_write grants';
  END IF;
  FOREACH f IN ARRAY ARRAY['public._exos_api_has_scope(text[],text)', 'public._exos_api_action_scope(text)',
      'public._exos_api_uuid(text,text)', 'public._exos_api_event_of(uuid,text)',
      'public._exos_api_columns(regclass,text[])', 'public._exos_api_field_keys(regclass,text[],jsonb)',
      'public._exos_api_insert(regclass,text[],jsonb,jsonb)', 'public._exos_api_update(regclass,uuid,text[],jsonb)',
      'public._exos_api_event_json(uuid)'] LOOP
    IF has_function_privilege('anon', f, 'EXECUTE') OR has_function_privilege('authenticated', f, 'EXECUTE')
       OR has_function_privilege('service_role', f, 'EXECUTE') THEN
      RAISE EXCEPTION 'C1 FAIL: % is callable', f;
    END IF;
  END LOOP;
  IF has_function_privilege('anon', 'public._exos_event_publish_blockers(uuid)', 'EXECUTE')
     OR has_function_privilege('authenticated', 'public._exos_event_publish_blockers(uuid)', 'EXECUTE')
     OR has_function_privilege('anon', 'public.exos_event_publish_blockers(uuid)', 'EXECUTE')
     OR has_function_privilege('anon', 'public.exos_publish_event(uuid)', 'EXECUTE')
     OR NOT has_function_privilege('authenticated', 'public.exos_publish_event(uuid)', 'EXECUTE') THEN
    RAISE EXCEPTION 'C1 FAIL: blocker / publish grants';
  END IF;
  IF has_table_privilege('anon', 'public.exos_api_writes', 'SELECT')
     OR has_table_privilege('authenticated', 'public.exos_api_writes', 'INSERT')
     OR NOT (SELECT relrowsecurity FROM pg_class WHERE oid = 'public.exos_api_writes'::regclass) THEN
    RAISE EXCEPTION 'C1 FAIL: exos_api_writes grants / RLS';
  END IF;
  IF NOT ('refunds:write' = ANY (public.exos_api_scope_names())) THEN
    RAISE EXCEPTION 'C1 FAIL: refunds:write not in the vocabulary';
  END IF;
  RAISE NOTICE 'OK C1 grants: exos_api_write service_role only, helpers internal, log RLS on';
END $$;

-- C2 -----------------------------------------------------------------------------
DO $$
BEGIN
  IF pg_temp.st('f3', 'event.create', NULL, '{"event":{"name":"x"}}') <> '42501' THEN RAISE EXCEPTION 'C2 FAIL: read key wrote'; END IF;
  IF pg_temp.st('f4', 'event.create', NULL, '{"event":{"name":"x"}}') <> '42501' THEN RAISE EXCEPTION 'C2 FAIL: refunds key created an event'; END IF;
  IF pg_temp.st('f1', 'event.explode', NULL) <> '22023' THEN RAISE EXCEPTION 'C2 FAIL: unknown action'; END IF;
  IF pg_temp.st('f2', 'comp.issue', 'c7000000-0000-0000-0000-0000000000e1', '{"emails":["a@x.com"]}') <> '42501' THEN
    RAISE EXCEPTION 'C2 FAIL: checkin key issued comps';
  END IF;
  IF pg_temp.st('f1', 'event.create', NULL, '{"event":{"name":"x"}}') <> 'ok' THEN RAISE EXCEPTION 'C2 FAIL: owner key'; END IF;
  RAISE NOTICE 'OK C2 the key''s scope is checked in SQL too';
END $$;

-- C3 -----------------------------------------------------------------------------
DO $$
BEGIN
  -- k2 has events:write, but its creator is a scanner: the dashboard's RLS roles say no.
  IF pg_temp.st('f2', 'event.create', NULL, '{"event":{"name":"x"}}') <> '42501' THEN RAISE EXCEPTION 'C3 FAIL: scanner key created an event'; END IF;
  IF pg_temp.st('f2', 'ticket_type.create', 'c7000000-0000-0000-0000-0000000000e1', '{"ticket_type":{"name":"VIP"}}') <> '42501' THEN
    RAISE EXCEPTION 'C3 FAIL: scanner key added a ticket type';
  END IF;
  IF pg_temp.st('f5', 'event.create', NULL, '{"event":{"name":"x"}}') <> 'ok' THEN RAISE EXCEPTION 'C3 FAIL: manager key'; END IF;
  UPDATE public.exos_org_memberships SET disabled = true
   WHERE org_id = 'c7000000-0000-0000-0000-000000000001' AND user_id = 'c7000000-0000-0000-0000-0000000000a2';
  IF pg_temp.st('f5', 'event.create', NULL, '{"event":{"name":"x"}}') <> '42501' THEN RAISE EXCEPTION 'C3 FAIL: disabled creator''s key'; END IF;
  DELETE FROM public.exos_org_memberships
   WHERE org_id = 'c7000000-0000-0000-0000-000000000001' AND user_id = 'c7000000-0000-0000-0000-0000000000a2';
  IF pg_temp.st('f5', 'event.create', NULL, '{"event":{"name":"x"}}') <> '42501' THEN RAISE EXCEPTION 'C3 FAIL: departed creator''s key'; END IF;
  UPDATE public.exos_api_keys SET revoked_at = now() WHERE id = 'c7000000-0000-0000-0000-0000000000f5';
  IF pg_temp.st('f5', 'event.create', NULL, '{"event":{"name":"x"}}') <> '42501' THEN RAISE EXCEPTION 'C3 FAIL: revoked key'; END IF;
  RAISE NOTICE 'OK C3 writes run as the key''s creator (role now; gone or disabled = refused)';
END $$;

-- C4 -----------------------------------------------------------------------------
DO $$
DECLARE r jsonb; e public.exos_events%ROWTYPE;
BEGIN
  r := pg_temp.w('f1', 'event.create', NULL,
    jsonb_build_object('event', jsonb_build_object('name', 'C7 API Show', 'starts_at', (now() + interval '10 days')::text,
                       'timezone', 'America/New_York', 'venue_name', 'Club', 'status', 'published'),
                       'ticket_types', '[{"name":"GA","price":25,"capacity":50},{"name":"Free","price":0,"ticket_type":"free"}]'::jsonb));
  RAISE EXCEPTION 'C4 FAIL: status was accepted';
EXCEPTION WHEN SQLSTATE '22023' THEN
  r := pg_temp.w('f1', 'event.create', NULL,
    jsonb_build_object('event', jsonb_build_object('name', 'C7 API Show', 'starts_at', (now() + interval '10 days')::text,
                       'timezone', 'America/New_York', 'venue_name', 'Club'),
                       'ticket_types', '[{"name":"GA","price":25,"capacity":50},{"name":"Free","price":0,"ticket_type":"free"}]'::jsonb));
  SELECT * INTO e FROM public.exos_events WHERE id = (r ->> 'id')::uuid;
  IF e.org_id <> 'c7000000-0000-0000-0000-000000000001' OR e.status <> 'draft'
     OR e.created_by <> 'c7000000-0000-0000-0000-0000000000a1' OR e.occurs_at_local IS NULL THEN
    RAISE EXCEPTION 'C4 FAIL: row %', to_jsonb(e);
  END IF;
  IF jsonb_array_length(r -> 'tiers') <> 2 OR (r -> 'tiers' -> 1 ->> 'name') <> 'Free' THEN
    RAISE EXCEPTION 'C4 FAIL: tiers %', r -> 'tiers';
  END IF;
  IF pg_temp.st('f1', 'event.create', NULL, '{"event":{"name":"x","tickets_sold":5}}') <> '22023'
     OR pg_temp.st('f1', 'event.create', NULL, '{"event":{"name":"x","org_id":"c7000000-0000-0000-0000-000000000002"}}') <> '22023'
     OR pg_temp.st('f1', 'event.create', NULL, '{"event":{"name":" "}}') <> '22023'
     OR pg_temp.st('f1', 'event.create', NULL, '{"event":{"name":"x","starts_at":"not a date"}}') NOT IN ('22007', '22008') THEN
    RAISE EXCEPTION 'C4 FAIL: bad fields accepted';
  END IF;
  PERFORM set_config('c7.event', r ->> 'id', false);
  RAISE NOTICE 'OK C4 event create: draft in the key''s org with its ticket types; server fields refused';
END $$;

-- C5 -----------------------------------------------------------------------------
DO $$
DECLARE r jsonb; v_ev uuid := current_setting('c7.event')::uuid; v_bare uuid; codes text[];
BEGIN
  r := pg_temp.w('f1', 'event.publish', v_ev::text);
  SELECT array_agg(b ->> 'code') INTO codes FROM jsonb_array_elements(r -> 'blockers') b;
  IF (r ->> 'published')::boolean OR codes <> ARRAY['stripe_not_connected'] THEN
    RAISE EXCEPTION 'C5 FAIL: paid tickets without Stripe published: %', r;
  END IF;
  -- A bare draft: every field blocker at once.
  r := pg_temp.w('f1', 'event.create', NULL, '{"event":{"name":"Bare"}}');
  v_bare := (r ->> 'id')::uuid;
  SELECT array_agg(b ->> 'code' ORDER BY b ->> 'code') INTO codes FROM jsonb_array_elements(r -> 'publish_blockers') b;
  IF codes <> ARRAY['missing_start', 'missing_timezone', 'missing_venue', 'no_ticket_types'] THEN
    RAISE EXCEPTION 'C5 FAIL: bare blockers %', codes;
  END IF;
  r := pg_temp.w('f1', 'event.update', v_bare::text,
    jsonb_build_object('event', jsonb_build_object('starts_at', (now() - interval '1 day')::text, 'timezone', 'Europe/Paris',
                                                   'format', 'online', 'ends_at', (now() - interval '2 days')::text)));
  SELECT array_agg(b ->> 'code' ORDER BY b ->> 'code') INTO codes FROM jsonb_array_elements(r -> 'publish_blockers') b;
  IF codes <> ARRAY['ends_before_start', 'no_ticket_types', 'starts_in_past'] THEN
    RAISE EXCEPTION 'C5 FAIL: past / online blockers %', codes;
  END IF;
  -- Connect Stripe: the first event publishes, and a second publish is a no-op.
  -- The harness has no phase-1 exos_org_secrets: its prod shape, rolled back.
  CREATE TABLE IF NOT EXISTS public.exos_org_secrets (
    org_id uuid PRIMARY KEY, payments jsonb, updated_at timestamptz NOT NULL DEFAULT now());
  INSERT INTO public.exos_org_secrets (org_id, payments)
  VALUES ('c7000000-0000-0000-0000-000000000001', '{"connectedAccountId":"acct_c7","chargesEnabled":true}')
  ON CONFLICT (org_id) DO UPDATE SET payments = EXCLUDED.payments;
  r := pg_temp.w('f1', 'event.publish', v_ev::text);
  IF NOT (r ->> 'published')::boolean OR (SELECT status FROM public.exos_events WHERE id = v_ev) <> 'published' THEN
    RAISE EXCEPTION 'C5 FAIL: publish %', r;
  END IF;
  r := pg_temp.w('f1', 'event.publish', v_ev::text);
  IF NOT (r ->> 'published')::boolean THEN RAISE EXCEPTION 'C5 FAIL: republish %', r; END IF;
  r := pg_temp.w('f1', 'event.unpublish', v_ev::text);
  IF r ->> 'status' <> 'draft' THEN RAISE EXCEPTION 'C5 FAIL: unpublish %', r; END IF;
  -- The dashboard's RPCs: content may read the blockers but not publish; strangers see nothing.
  PERFORM set_config('app.uid', 'c7000000-0000-0000-0000-0000000000a6', false);
  IF jsonb_array_length(public.exos_event_publish_blockers(v_bare)) <> 3 THEN RAISE EXCEPTION 'C5 FAIL: content read'; END IF;
  BEGIN
    PERFORM public.exos_publish_event(v_ev);
    RAISE EXCEPTION 'C5 FAIL: content published';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  PERFORM set_config('app.uid', 'c7000000-0000-0000-0000-0000000000a5', false);
  BEGIN
    PERFORM public.exos_event_publish_blockers(v_bare);
    RAISE EXCEPTION 'C5 FAIL: stranger read blockers';
  EXCEPTION WHEN no_data_found THEN NULL;
  END;
  PERFORM set_config('app.uid', 'c7000000-0000-0000-0000-0000000000a1', false);
  r := public.exos_publish_event(v_ev);
  IF NOT (r ->> 'published')::boolean THEN RAISE EXCEPTION 'C5 FAIL: dashboard publish %', r; END IF;
  PERFORM set_config('app.uid', '', false);
  RAISE NOTICE 'OK C5 publish blockers: listed, enforced, cleared; dashboard RPCs role-checked';
END $$;

-- C6 -----------------------------------------------------------------------------
DO $$
DECLARE r jsonb;
BEGIN
  IF pg_temp.st('f6', 'event.update', 'c7000000-0000-0000-0000-0000000000e1', '{"event":{"name":"mine"}}') <> 'P0002'
     OR pg_temp.st('f1', 'event.update', 'c7000000-0000-0000-0000-0000000000e9', '{"event":{"name":"mine"}}') <> 'P0002'
     OR pg_temp.st('f1', 'event.publish', 'c7000000-0000-0000-0000-0000000000e9') <> 'P0002'
     OR pg_temp.st('f1', 'event.update', 'not-a-uuid', '{"event":{"name":"x"}}') <> 'P0002' THEN
    RAISE EXCEPTION 'C6 FAIL: cross-org target reachable';
  END IF;
  IF pg_temp.st('f1', 'event.update', 'c7000000-0000-0000-0000-0000000000e1', '{"event":{"name":""}}') <> '22023' THEN
    RAISE EXCEPTION 'C6 FAIL: name blanked';
  END IF;
  r := pg_temp.w('f1', 'event.update', 'c7000000-0000-0000-0000-0000000000e1', '{"event":{"name":"C7 Night (late)","venue_name":"Annex"}}');
  IF r ->> 'name' <> 'C7 Night (late)' OR r ->> 'venue_name' <> 'Annex'
     OR (SELECT name FROM public.exos_events WHERE id = 'c7000000-0000-0000-0000-0000000000e9') <> 'C7 Elsewhere' THEN
    RAISE EXCEPTION 'C6 FAIL: update %', r;
  END IF;
  RAISE NOTICE 'OK C6 event update: own org only (others read as not found)';
END $$;

-- C7 -----------------------------------------------------------------------------
DO $$
DECLARE r jsonb; v_id uuid;
BEGIN
  r := pg_temp.w('f1', 'ticket_type.create', 'c7000000-0000-0000-0000-0000000000e1', '{"ticket_type":{"name":"VIP","price":80,"capacity":20}}');
  v_id := (r ->> 'id')::uuid;
  IF r ->> 'event_id' <> 'c7000000-0000-0000-0000-0000000000e1' OR (r ->> 'price')::numeric <> 80 THEN RAISE EXCEPTION 'C7 FAIL: create %', r; END IF;
  r := pg_temp.w('f1', 'ticket_type.update', v_id::text, '{"ticket_type":{"price":90,"visibility":"hidden"}}');
  IF (r ->> 'price')::numeric <> 90 OR r ->> 'visibility' <> 'hidden' THEN RAISE EXCEPTION 'C7 FAIL: update %', r; END IF;
  IF pg_temp.st('f1', 'ticket_type.update', v_id::text, '{"ticket_type":{"sold":0}}') <> '22023' THEN RAISE EXCEPTION 'C7 FAIL: sold writable'; END IF;
  IF pg_temp.st('f1', 'ticket_type.delete', 'c7000000-0000-0000-0000-0000000000d1') <> '23503' THEN RAISE EXCEPTION 'C7 FAIL: sold type deleted'; END IF;
  IF pg_temp.st('f6', 'ticket_type.delete', v_id::text) <> 'P0002' THEN RAISE EXCEPTION 'C7 FAIL: cross-org delete'; END IF;
  r := pg_temp.w('f1', 'ticket_type.delete', v_id::text);
  IF EXISTS (SELECT 1 FROM public.exos_ticket_tiers WHERE id = v_id) THEN RAISE EXCEPTION 'C7 FAIL: not deleted'; END IF;
  RAISE NOTICE 'OK C7 ticket types: create / update / delete; sold types stay';
END $$;

-- C8 -----------------------------------------------------------------------------
DO $$
DECLARE r jsonb; v_id uuid;
BEGIN
  r := pg_temp.w('f1', 'promo_code.create', 'c7000000-0000-0000-0000-0000000000e1',
                 '{"promo_code":{"code":"C7SAVE","discount_percent":20,"max_uses":5}}');
  v_id := (r ->> 'id')::uuid;
  IF r ->> 'code' <> 'C7SAVE' OR (r ->> 'max_uses')::int <> 5 THEN RAISE EXCEPTION 'C8 FAIL: create %', r; END IF;
  IF pg_temp.st('f1', 'promo_code.create', 'c7000000-0000-0000-0000-0000000000e1', '{"promo_code":{"code":"C7SAVE"}}') <> '23505' THEN
    RAISE EXCEPTION 'C8 FAIL: duplicate code';
  END IF;
  IF pg_temp.st('f1', 'promo_code.create', 'c7000000-0000-0000-0000-0000000000e1', '{"promo_code":{"discount_percent":100}}') <> '22023' THEN
    RAISE EXCEPTION 'C8 FAIL: 100%% off accepted (comps are their own route)';
  END IF;
  r := pg_temp.w('f1', 'promo_code.update', v_id::text, '{"promo_code":{"max_uses":9}}');
  IF (r ->> 'max_uses')::int <> 9 THEN RAISE EXCEPTION 'C8 FAIL: update %', r; END IF;
  IF pg_temp.st('f1', 'promo_code.update', v_id::text, '{"promo_code":{"used_count":0}}') <> '22023' THEN RAISE EXCEPTION 'C8 FAIL: used_count writable'; END IF;
  IF pg_temp.st('f6', 'promo_code.delete', v_id::text) <> 'P0002' THEN RAISE EXCEPTION 'C8 FAIL: cross-org delete'; END IF;
  PERFORM pg_temp.w('f1', 'promo_code.delete', v_id::text);
  IF EXISTS (SELECT 1 FROM public.exos_vouchers WHERE id = v_id) THEN RAISE EXCEPTION 'C8 FAIL: not deleted'; END IF;
  RAISE NOTICE 'OK C8 promo codes through exos_issue_voucher; update / delete';
END $$;

-- C9 -----------------------------------------------------------------------------
DO $$
DECLARE r jsonb; v_id uuid;
BEGIN
  r := pg_temp.w('f1', 'add_on.create', 'c7000000-0000-0000-0000-0000000000e1', '{"add_on":{"name":"Parking","price":15,"capacity":40}}');
  v_id := (r ->> 'id')::uuid;
  r := pg_temp.w('f1', 'add_on.update', v_id::text, '{"add_on":{"price":12}}');
  IF (r ->> 'price')::numeric <> 12 THEN RAISE EXCEPTION 'C9 FAIL: update %', r; END IF;
  IF pg_temp.st('f1', 'add_on.update', v_id::text, '{"add_on":{"price":-1}}') <> '23514' THEN RAISE EXCEPTION 'C9 FAIL: negative price'; END IF;
  PERFORM pg_temp.w('f1', 'add_on.delete', v_id::text);
  IF EXISTS (SELECT 1 FROM public.exos_event_addons WHERE id = v_id) THEN RAISE EXCEPTION 'C9 FAIL: not deleted'; END IF;
  RAISE NOTICE 'OK C9 add-ons: create / update / delete';
END $$;

-- C10 ----------------------------------------------------------------------------
DO $$
DECLARE r1 jsonb; r2 jsonb; n int;
BEGIN
  IF pg_temp.st('f1', 'refund.claim', 'cs_c7a', '{"whole_order":true}') <> '22023' THEN RAISE EXCEPTION 'C10 FAIL: no key'; END IF;
  r1 := pg_temp.w('f1', 'refund.claim', 'cs_c7a', '{"items":[{"ticket_id":"c7000000-0000-0000-0000-000000000101"}],"reason":"api"}', 'idem-c7-0001');
  r2 := pg_temp.w('f1', 'refund.claim', 'cs_c7a', '{"items":[{"ticket_id":"c7000000-0000-0000-0000-000000000101"}],"reason":"api"}', 'idem-c7-0001');
  IF r1 ->> 'request_id' <> r2 ->> 'request_id' OR NOT (r2 ->> 'existing')::boolean OR (r1 ->> 'amount_cents')::int <> 3000 THEN
    RAISE EXCEPTION 'C10 FAIL: replay % / %', r1, r2;
  END IF;
  SELECT count(*) INTO n FROM public.exos_refund_requests WHERE session_id = 'cs_c7a';
  IF n <> 1 THEN RAISE EXCEPTION 'C10 FAIL: % requests', n; END IF;
  IF (SELECT requested_by FROM public.exos_refund_requests WHERE id = (r1 ->> 'request_id')::uuid) <> 'c7000000-0000-0000-0000-0000000000a1' THEN
    RAISE EXCEPTION 'C10 FAIL: requested_by';
  END IF;
  IF pg_temp.st('f1', 'refund.claim', 'cs_c7b', '{"whole_order":true}', 'idem-c7-0001') <> '22023' THEN
    RAISE EXCEPTION 'C10 FAIL: key reused on another order';
  END IF;
  -- More than is left: the claim's own rule.
  IF pg_temp.st('f1', 'refund.claim', 'cs_c7a', '{"amount_cents":999999}', 'idem-c7-0002') <> '22023' THEN
    RAISE EXCEPTION 'C10 FAIL: over-refund';
  END IF;
  -- Finance may refund (as in the dashboard); a scanner's key may not, even with refunds:write.
  IF pg_temp.st('f4', 'refund.claim', 'cs_c7b', '{"whole_order":true}', 'idem-c7-0003') <> 'ok' THEN RAISE EXCEPTION 'C10 FAIL: finance'; END IF;
  IF pg_temp.st('f7', 'refund.claim', 'cs_c7b', '{"amount_cents":100}', 'idem-c7-0004') <> '42501' THEN RAISE EXCEPTION 'C10 FAIL: scanner refunded'; END IF;
  IF pg_temp.st('f2', 'refund.claim', 'cs_c7b', '{"amount_cents":100}', 'idem-c7-0005') <> '42501' THEN RAISE EXCEPTION 'C10 FAIL: scope'; END IF;
  IF pg_temp.st('f1', 'refund.claim', 'cs_c7z', '{"whole_order":true}', 'idem-c7-0006') <> 'P0002'
     OR pg_temp.st('f6', 'refund.claim', 'cs_c7a', '{"whole_order":true}', 'idem-c7-0007') <> 'P0002' THEN
    RAISE EXCEPTION 'C10 FAIL: cross-org order';
  END IF;
  SELECT count(*) INTO n FROM public.exos_api_writes WHERE action = 'refund.claim' AND money_moving AND result IS NOT NULL;
  IF n <> 2 THEN RAISE EXCEPTION 'C10 FAIL: % logged refund claims', n; END IF;
  -- The preview needs the creator's role too (finance yes).
  r1 := public.exos_api_write('c7000000-0000-0000-0000-0000000000f4', 'refund.preview', 'cs_c7a');
  IF (r1 ->> 'refundable_cents') IS NULL THEN RAISE EXCEPTION 'C10 FAIL: preview %', r1; END IF;
  RAISE NOTICE 'OK C10 refunds: Idempotency-Key = one request; dashboard roles; own org; logged';
END $$;

-- C11 ----------------------------------------------------------------------------
DO $$
DECLARE r1 jsonb; r2 jsonb; n0 int; n1 int; n2 int;
BEGIN
  SELECT count(*) INTO n0 FROM public.exos_tickets WHERE event_id = 'c7000000-0000-0000-0000-0000000000e1';
  r1 := pg_temp.w('f1', 'comp.issue', 'c7000000-0000-0000-0000-0000000000e1',
                  '{"tier_id":"c7000000-0000-0000-0000-0000000000d1","emails":["guest1@x.com","guest2@x.com"]}', 'idem-c7-comp1');
  SELECT count(*) INTO n1 FROM public.exos_tickets WHERE event_id = 'c7000000-0000-0000-0000-0000000000e1';
  r2 := pg_temp.w('f1', 'comp.issue', 'c7000000-0000-0000-0000-0000000000e1',
                  '{"tier_id":"c7000000-0000-0000-0000-0000000000d1","emails":["guest1@x.com","guest2@x.com"]}', 'idem-c7-comp1');
  SELECT count(*) INTO n2 FROM public.exos_tickets WHERE event_id = 'c7000000-0000-0000-0000-0000000000e1';
  IF n1 - n0 <> 2 OR n2 <> n1 OR NOT (r2 ->> 'idempotent_replay')::boolean
     OR jsonb_array_length(r1 -> 'results') <> 2 THEN
    RAISE EXCEPTION 'C11 FAIL: % % % / % / %', n0, n1, n2, r1, r2;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.exos_api_writes WHERE action = 'comp.issue' AND money_moving
                    AND actor = 'c7000000-0000-0000-0000-0000000000a1') THEN
    RAISE EXCEPTION 'C11 FAIL: not logged';
  END IF;
  IF pg_temp.st('f6', 'comp.issue', 'c7000000-0000-0000-0000-0000000000e1', '{"emails":["x@x.com"]}') <> 'P0002' THEN
    RAISE EXCEPTION 'C11 FAIL: cross-org comps';
  END IF;
  RAISE NOTICE 'OK C11 comps through the batch; a replayed key issues nothing';
END $$;

-- C12 ----------------------------------------------------------------------------
DO $$
DECLARE r jsonb;
BEGIN
  -- A typed check-in is an override: the scanner's key gets needs-manager; the owner's needs a reason.
  r := pg_temp.w('f2', 'ticket.check_in', 'c7000000-0000-0000-0000-000000000201', '{"reason":"list"}');
  IF (r ->> 'ok')::boolean OR r ->> 'reason' <> 'needs-manager' THEN RAISE EXCEPTION 'C12 FAIL: scanner %', r; END IF;
  r := pg_temp.w('f1', 'ticket.check_in', 'c7000000-0000-0000-0000-000000000201', '{}');
  IF r ->> 'reason' <> 'reason-required' THEN RAISE EXCEPTION 'C12 FAIL: no reason %', r; END IF;
  r := pg_temp.w('f1', 'ticket.check_in', 'c7000000-0000-0000-0000-000000000201', '{"reason":"box office"}');
  IF NOT (r ->> 'ok')::boolean OR (SELECT status FROM public.exos_tickets WHERE id = 'c7000000-0000-0000-0000-000000000201') <> 'used' THEN
    RAISE EXCEPTION 'C12 FAIL: check-in %', r;
  END IF;
  IF (SELECT scanned_by FROM public.exos_event_checkins WHERE ticket_id = 'c7000000-0000-0000-0000-000000000201' ORDER BY scanned_at DESC LIMIT 1)
     <> 'c7000000-0000-0000-0000-0000000000a1' THEN
    RAISE EXCEPTION 'C12 FAIL: scanned_by is not the key''s creator';
  END IF;
  r := pg_temp.w('f1', 'ticket.check_in', 'c7000000-0000-0000-0000-000000000101', '{"reason":"early"}');
  IF r ->> 'reason' <> 'doors-not-open' THEN RAISE EXCEPTION 'C12 FAIL: doors %', r; END IF;
  r := pg_temp.w('f1', 'ticket.undo_check_in', 'c7000000-0000-0000-0000-000000000201', '{"reason":"wrong person"}');
  IF (SELECT status FROM public.exos_tickets WHERE id = 'c7000000-0000-0000-0000-000000000201') <> 'active' THEN
    RAISE EXCEPTION 'C12 FAIL: undo %', r;
  END IF;
  IF pg_temp.st('f6', 'ticket.check_in', 'c7000000-0000-0000-0000-000000000201', '{"reason":"x"}') <> 'P0002' THEN
    RAISE EXCEPTION 'C12 FAIL: cross-org check-in';
  END IF;
  r := pg_temp.w('f1', 'order.check_in', 'cs_c7c', '{"reason":"whole party"}');
  IF jsonb_array_length(r -> 'results') <> 2 OR EXISTS (
       SELECT 1 FROM jsonb_array_elements(r -> 'results') x WHERE NOT (x ->> 'ok')::boolean) THEN
    RAISE EXCEPTION 'C12 FAIL: order check-in %', r;
  END IF;
  r := pg_temp.w('f1', 'event.offline_check_ins', 'c7000000-0000-0000-0000-0000000000e2', jsonb_build_object('scans', jsonb_build_array(
         jsonb_build_object('client_ref', 'c7000000-0000-0000-0000-00000000c001', 'ticket_id', 'c7000000-0000-0000-0000-000000000203',
                            'scanned_at', (now() - interval '5 minutes')::text, 'reason', 'offline door'),
         jsonb_build_object('client_ref', 'c7000000-0000-0000-0000-00000000c002', 'ticket_id', 'c7000000-0000-0000-0000-000000000901',
                            'scanned_at', (now() - interval '5 minutes')::text),
         jsonb_build_object('client_ref', 'nope', 'ticket_id', 'c7000000-0000-0000-0000-000000000203', 'scanned_at', 'x'))));
  IF jsonb_array_length(r -> 'results') <> 3
     OR r -> 'results' -> 1 ->> 'reason' <> 'not-found'
     OR r -> 'results' -> 2 ->> 'reason' <> 'bad-scan' THEN
    RAISE EXCEPTION 'C12 FAIL: offline %', r;
  END IF;
  IF (SELECT status FROM public.exos_tickets WHERE id = 'c7000000-0000-0000-0000-000000000901') <> 'active' THEN
    RAISE EXCEPTION 'C12 FAIL: org 2 ticket touched';
  END IF;
  RAISE NOTICE 'OK C12 door: the dashboard''s check-in rules, as the key''s creator; own org only';
END $$;

-- C13 ----------------------------------------------------------------------------
DO $$
DECLARE r jsonb; v_list uuid; v_g uuid;
BEGIN
  r := pg_temp.w('f1', 'guest_list.create', 'c7000000-0000-0000-0000-0000000000e2', '{"guest_list":{"name":"Friends","cap":10,"max_plus_ones":2}}');
  v_list := (r ->> 'id')::uuid;
  IF (r ->> 'cap')::int <> 10 THEN RAISE EXCEPTION 'C13 FAIL: create %', r; END IF;
  r := pg_temp.w('f1', 'guest_list.update', v_list::text, '{"guest_list":{"cap":12}}');
  IF (r ->> 'cap')::int <> 12 OR r ->> 'name' <> 'Friends' THEN RAISE EXCEPTION 'C13 FAIL: update %', r; END IF;
  r := pg_temp.w('f1', 'guest.add', v_list::text, '{"guests":[{"guest_name":"Ana","plus_ones":1},{"guest_name":"Bo"}]}');
  IF jsonb_array_length(r -> 'data') <> 2 THEN RAISE EXCEPTION 'C13 FAIL: add %', r; END IF;
  SELECT (x ->> 'id')::uuid INTO v_g FROM jsonb_array_elements(r -> 'data') x WHERE x ->> 'guest_name' = 'Ana';
  IF pg_temp.st('f1', 'guest.add', v_list::text, '{"guest_name":"Cy","plus_ones":5}') <> '23514' THEN RAISE EXCEPTION 'C13 FAIL: plus-ones cap'; END IF;
  r := pg_temp.w('f1', 'guest.update', v_g::text, '{"note":"VIP"}');
  IF r ->> 'note' <> 'VIP' OR r ->> 'guest_name' <> 'Ana' OR (r ->> 'plus_ones')::int <> 1 THEN RAISE EXCEPTION 'C13 FAIL: edit %', r; END IF;
  IF pg_temp.st('f2', 'guest.check_in', v_g::text, '{"count":1}') <> 'ok' THEN RAISE EXCEPTION 'C13 FAIL: scanner guest check-in'; END IF;
  IF pg_temp.st('f1', 'guest.remove', v_g::text) <> '23514' THEN RAISE EXCEPTION 'C13 FAIL: arrived guest removed'; END IF;
  IF pg_temp.st('f6', 'guest.update', v_g::text, '{"note":"x"}') <> 'P0002'
     OR pg_temp.st('f6', 'guest_list.delete', v_list::text) <> 'P0002' THEN
    RAISE EXCEPTION 'C13 FAIL: cross-org guest list';
  END IF;
  IF pg_temp.st('f1', 'guest_list.delete', v_list::text) = 'ok' THEN RAISE EXCEPTION 'C13 FAIL: list with arrivals deleted'; END IF;
  r := pg_temp.w('f1', 'guest_list.create', 'c7000000-0000-0000-0000-0000000000e2', '{"guest_list":{"name":"Empty"}}');
  PERFORM pg_temp.w('f1', 'guest_list.delete', r ->> 'id');
  IF EXISTS (SELECT 1 FROM public.exos_guest_lists WHERE id = (r ->> 'id')::uuid) THEN RAISE EXCEPTION 'C13 FAIL: delete'; END IF;
  RAISE NOTICE 'OK C13 guest lists through the dashboard''s functions';
END $$;

-- C14 ----------------------------------------------------------------------------
DO $$
BEGIN
  PERFORM set_config('request.jwt.claims', '{"role":"service_role"}', true);
  PERFORM pg_temp.w('f1', 'event.update', 'c7000000-0000-0000-0000-0000000000e1', '{"event":{"description":"x"}}');
  IF current_setting('request.jwt.claims', true) <> '{"role":"service_role"}' OR auth.uid() IS NOT NULL THEN
    RAISE EXCEPTION 'C14 FAIL: claims left as % / %', current_setting('request.jwt.claims', true), auth.uid();
  END IF;
  RAISE NOTICE 'OK C14 the request''s claims are put back after the write';
END $$;

-- C15 ----------------------------------------------------------------------------
DO $$
DECLARE n_owner int; n_scan int; n_other int;
BEGIN
  SET LOCAL ROLE authenticated;
  PERFORM set_config('app.uid', 'c7000000-0000-0000-0000-0000000000a1', true);
  SELECT count(*) INTO n_owner FROM public.exos_api_writes WHERE org_id = 'c7000000-0000-0000-0000-000000000001';
  PERFORM set_config('app.uid', 'c7000000-0000-0000-0000-0000000000a3', true);
  SELECT count(*) INTO n_scan FROM public.exos_api_writes;
  PERFORM set_config('app.uid', 'c7000000-0000-0000-0000-0000000000a5', true);
  SELECT count(*) INTO n_other FROM public.exos_api_writes WHERE org_id = 'c7000000-0000-0000-0000-000000000001';
  RESET ROLE;
  PERFORM set_config('app.uid', '', true);
  IF n_owner < 10 OR n_scan <> 0 OR n_other <> 0 THEN
    RAISE EXCEPTION 'C15 FAIL: owner % scanner % other org %', n_owner, n_scan, n_other;
  END IF;
  RAISE NOTICE 'OK C15 exos_api_writes: owner / manager of the org read it, nobody else';
END $$;

-- C16 ----------------------------------------------------------------------------
DO $$
BEGIN
  PERFORM pg_temp.w('f1', 'event.update', 'c7000000-0000-0000-0000-0000000000e1', '{"event":{"description":"y"}}', 'idem-c7-0100');
  IF pg_temp.st('f1', 'event.unpublish', 'c7000000-0000-0000-0000-0000000000e1', '{}', 'idem-c7-0100') <> '22023'
     OR pg_temp.st('f1', 'event.update', 'c7000000-0000-0000-0000-0000000000e2', '{"event":{"description":"y"}}', 'idem-c7-0100') <> '22023'
     OR pg_temp.st('f1', 'event.update', 'c7000000-0000-0000-0000-0000000000e1', '{}', 'short') <> '22023' THEN
    RAISE EXCEPTION 'C16 FAIL: key reuse';
  END IF;
  -- The same key on another API key is its own.
  IF pg_temp.st('f6', 'event.update', 'c7000000-0000-0000-0000-0000000000e9', '{"event":{"description":"y"}}', 'idem-c7-0100') <> 'ok' THEN
    RAISE EXCEPTION 'C16 FAIL: keys are per API key';
  END IF;
  RAISE NOTICE 'OK C16 an Idempotency-Key is bound to its action and target, per API key';
END $$;

ROLLBACK;
