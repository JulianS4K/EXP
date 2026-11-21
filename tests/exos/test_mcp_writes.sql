-- ============================================================================
-- Event writes from AI assistants and user-token writes (mig 20261119130000).
-- Self-contained (cc13 prefix), rolled back. Org 1: owner u1, manager u2;
-- org 2: owner u5. Credentials: k1 an owner's API key; p1 the owner's personal
-- token (events:write), p2 the owner's read-only token, p3 the manager's
-- token (events:write), p4 a token revoked in M9, p5 an expired one; o1 the
-- owner's OAuth access token (events:write) under grant g1.
--   M1  grants: every new function service_role only; the old five-argument
--       exos_api_write is gone; exos_mcp_writes RLS (owner / manager)
--   M2  a personal token creates a draft as its user; the write log names the
--       credential (pat + its id), the actor and source api
--   M3  a draft is invisible to search / fetch / feeds (exos_public_events)
--   M4  ticket type + publish through the token: published, then public
--   M5  an OAuth token creates a paid event; publish without Stripe Connect
--       answers published=false with stripe_not_connected; a free one publishes
--   M6  every other action refuses a user token (event.update, refund.claim,
--       comp.issue, ticket_type.delete); a key AND a token is refused
--   M7  a token without events:write is refused
--   M8  role lost: demoted to scanner, then removed: refused at once
--   M9  revoked token, revoked OAuth grant, expired token: refused
--   M10 another org's event: not found (P0002), for tokens and through MCP
--   M11 the API-key path is unchanged; Idempotency-Keys are per credential
--   M12 free tier: 150 is the free tier, 151 the standard fee; another org NULL
--   M13 confirm tokens: spend once; reused, expired, changed args (burned),
--       another credential's, a revoked credential: refused
--   M14 the hourly cap per org (mcp_writes_per_hour); a refusal keeps the token
--   M15 audit: exos_mcp_writes, exos_org_audit (mcp.write, source mcp), and the
--       API write log (source mcp, credential)
--   M16 exos_mcp_event_state: own event with blockers; another org's is NULL
--   M17 a failed MCP write spends its token and is logged failed
-- ============================================================================
\set ON_ERROR_STOP on
BEGIN;

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
-- The free tier as prod has it (the harness turns it off for older fixtures).
INSERT INTO public.exos_platform_settings (key, value) VALUES ('free_tier_max_capacity', '150')
  ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value;

INSERT INTO auth.users(id,email,email_confirmed_at) VALUES
  ('cc130000-0000-0000-0000-0000000000a1','cc13-owner@x.com',now()),
  ('cc130000-0000-0000-0000-0000000000a2','cc13-manager@x.com',now()),
  ('cc130000-0000-0000-0000-0000000000a5','cc13-other@x.com',now());
INSERT INTO public.exos_orgs(id,name,slug,owner_uid) VALUES
  ('cc130000-0000-0000-0000-000000000001','CC13 Org','cc13-org','cc130000-0000-0000-0000-0000000000a1'),
  ('cc130000-0000-0000-0000-000000000002','CC13 Other','cc13-other','cc130000-0000-0000-0000-0000000000a5');
INSERT INTO public.exos_org_memberships(org_id,user_id,role) VALUES
  ('cc130000-0000-0000-0000-000000000001','cc130000-0000-0000-0000-0000000000a1','owner'),
  ('cc130000-0000-0000-0000-000000000001','cc130000-0000-0000-0000-0000000000a2','manager'),
  ('cc130000-0000-0000-0000-000000000002','cc130000-0000-0000-0000-0000000000a5','owner');
INSERT INTO public.exos_api_keys(id,org_id,name,key_prefix,key_hash,scopes,created_by) VALUES
  ('cc130000-0000-0000-0000-0000000000f1','cc130000-0000-0000-0000-000000000001','k1','sk_live_cc13','cc13hash1',
   ARRAY['events:write'],'cc130000-0000-0000-0000-0000000000a1');

-- Bearer hashes: SHA-256 hex of the presented token, as the edge functions send it.
CREATE FUNCTION pg_temp.h(p text) RETURNS text LANGUAGE sql IMMUTABLE AS $$ SELECT encode(sha256(convert_to(p, 'UTF8')), 'hex') $$;
INSERT INTO public.exos_personal_tokens(id,user_id,org_id,name,key_prefix,key_hash,scopes,expires_at) VALUES
  ('cc130000-0000-0000-0000-0000000000c1','cc130000-0000-0000-0000-0000000000a1','cc130000-0000-0000-0000-000000000001',
   'p1','exos_pat_cc1',pg_temp.h('exos_pat_cc13_p1'),ARRAY['events:read','events:write'],NULL),
  ('cc130000-0000-0000-0000-0000000000c2','cc130000-0000-0000-0000-0000000000a1','cc130000-0000-0000-0000-000000000001',
   'p2','exos_pat_cc2',pg_temp.h('exos_pat_cc13_p2'),ARRAY['events:read'],NULL),
  ('cc130000-0000-0000-0000-0000000000c3','cc130000-0000-0000-0000-0000000000a2','cc130000-0000-0000-0000-000000000001',
   'p3','exos_pat_cc3',pg_temp.h('exos_pat_cc13_p3'),ARRAY['events:write'],NULL),
  ('cc130000-0000-0000-0000-0000000000c4','cc130000-0000-0000-0000-0000000000a1','cc130000-0000-0000-0000-000000000001',
   'p4','exos_pat_cc4',pg_temp.h('exos_pat_cc13_p4'),ARRAY['events:write'],NULL),
  ('cc130000-0000-0000-0000-0000000000c5','cc130000-0000-0000-0000-0000000000a1','cc130000-0000-0000-0000-000000000001',
   'p5','exos_pat_cc5',pg_temp.h('exos_pat_cc13_p5'),ARRAY['events:write'],now() - interval '1 minute');
INSERT INTO public.exos_oauth_apps(id,client_id,name,redirect_uris,scopes,client_type,source) VALUES
  ('cc130000-0000-0000-0000-0000000000d1','exos_app_cc1300000000000000000001','CC13 Assistant',ARRAY['https://claude.ai/api/mcp/auth_callback'],
   ARRAY['events:read','events:write'],'public','dcr');
INSERT INTO public.exos_oauth_grants(id,app_id,user_id,org_id,scopes) VALUES
  ('cc130000-0000-0000-0000-0000000000d2','cc130000-0000-0000-0000-0000000000d1','cc130000-0000-0000-0000-0000000000a1',
   'cc130000-0000-0000-0000-000000000001',ARRAY['events:read','events:write']);
INSERT INTO public.exos_oauth_tokens(token_hash,kind,app_id,grant_id,family_id,user_id,org_id,scopes,expires_at) VALUES
  (pg_temp.h('exos_oat_cc13_o1'),'access','cc130000-0000-0000-0000-0000000000d1','cc130000-0000-0000-0000-0000000000d2',
   gen_random_uuid(),'cc130000-0000-0000-0000-0000000000a1','cc130000-0000-0000-0000-000000000001',
   ARRAY['events:read','events:write'],now() + interval '1 hour');

-- Org 2's draft (M10).
INSERT INTO public.exos_events(id,org_id,name,slug,status,starts_at,timezone,venue_name,total_tickets,created_by) VALUES
  ('cc130000-0000-0000-0000-0000000000e9','cc130000-0000-0000-0000-000000000002','CC13 Elsewhere','cc13-else','draft',
   now() + interval '5 days','America/New_York','Hall',10,'cc130000-0000-0000-0000-0000000000a5');

-- A user-token write (p = the token's text, t = pat / oauth).
CREATE FUNCTION pg_temp.tw(p text, t text, a text, tgt text, args jsonb DEFAULT '{}', idem text DEFAULT NULL)
RETURNS jsonb LANGUAGE sql AS $$
  SELECT public.exos_api_write(NULL, a, tgt, args, idem, pg_temp.h(p), t)
$$;
CREATE FUNCTION pg_temp.tst(p text, t text, a text, tgt text, args jsonb DEFAULT '{}') RETURNS text LANGUAGE plpgsql AS $$
BEGIN
  PERFORM pg_temp.tw(p, t, a, tgt, args);
  RETURN 'ok';
EXCEPTION WHEN OTHERS THEN RETURN SQLSTATE;
END $$;
CREATE FUNCTION pg_temp.ev(p_name text, p_cap int) RETURNS jsonb LANGUAGE sql AS $$
  SELECT jsonb_build_object('event', jsonb_build_object('name', p_name, 'starts_at', (now() + interval '10 days')::text,
    'timezone', 'America/New_York', 'venue_name', 'The Loft', 'total_tickets', p_cap))
$$;

-- M1 -----------------------------------------------------------------------------
DO $$
DECLARE f text;
BEGIN
  ASSERT to_regprocedure('public.exos_api_write(uuid,text,text,jsonb,text)') IS NULL, 'M1 the five-argument exos_api_write is gone';
  FOREACH f IN ARRAY ARRAY[
    'public.exos_api_write(uuid,text,text,jsonb,text,text,text,uuid,text)',
    'public.exos_mcp_confirm_issue(uuid,text,uuid,text,text,text,text,jsonb,text)',
    'public.exos_mcp_write(text,uuid,text,uuid,text,text,text,text,jsonb)',
    'public.exos_mcp_event_state(uuid,uuid)', 'public.exos_mcp_fee_outcome(uuid,uuid)',
    'public._exos_api_user_token_actions()'] LOOP
    ASSERT has_function_privilege('service_role', f, 'EXECUTE'), 'M1 service_role runs ' || f;
    ASSERT NOT has_function_privilege('anon', f, 'EXECUTE') AND NOT has_function_privilege('authenticated', f, 'EXECUTE'),
      'M1 no client runs ' || f;
  END LOOP;
  FOREACH f IN ARRAY ARRAY['public._exos_mcp_credential(uuid,text,uuid,text)', 'public._exos_mcp_tool_action(text)',
                           'public._exos_tg_api_writes_cred()'] LOOP
    ASSERT NOT has_function_privilege('anon', f, 'EXECUTE') AND NOT has_function_privilege('authenticated', f, 'EXECUTE'),
      'M1 helper not client-callable: ' || f;
  END LOOP;
  ASSERT NOT has_table_privilege('authenticated', 'public.exos_mcp_confirms', 'SELECT')
     AND NOT has_table_privilege('anon', 'public.exos_mcp_confirms', 'SELECT'), 'M1 confirmations: no client access';
  ASSERT has_table_privilege('authenticated', 'public.exos_mcp_writes', 'SELECT')
     AND NOT has_table_privilege('authenticated', 'public.exos_mcp_writes', 'INSERT')
     AND NOT has_table_privilege('anon', 'public.exos_mcp_writes', 'SELECT'), 'M1 MCP write log: SELECT only';
  ASSERT (SELECT relrowsecurity FROM pg_class WHERE oid = 'public.exos_mcp_writes'::regclass)
     AND (SELECT relrowsecurity FROM pg_class WHERE oid = 'public.exos_mcp_confirms'::regclass), 'M1 RLS on';
  RAISE NOTICE 'M1 ok';
END $$;

-- M2 / M3 / M4 -----------------------------------------------------------------------
DO $$
DECLARE v jsonb; v_id uuid; w public.exos_api_writes%ROWTYPE; v_tier jsonb; v_pub jsonb;
BEGIN
  v := pg_temp.tw('exos_pat_cc13_p1', 'pat', 'event.create', NULL, pg_temp.ev('CC13 Token Night', 120));
  v_id := (v ->> 'id')::uuid;
  ASSERT (SELECT status FROM public.exos_events WHERE id = v_id) = 'draft', 'M2 a draft';
  ASSERT (SELECT org_id FROM public.exos_events WHERE id = v_id) = 'cc130000-0000-0000-0000-000000000001', 'M2 in the token''s org';
  ASSERT (SELECT created_by FROM public.exos_events WHERE id = v_id) = 'cc130000-0000-0000-0000-0000000000a1', 'M2 created by the token''s user';
  SELECT * INTO w FROM public.exos_api_writes WHERE action = 'event.create' AND target IS NULL
     AND org_id = 'cc130000-0000-0000-0000-000000000001' ORDER BY created_at DESC LIMIT 1;
  ASSERT w.credential_kind = 'pat' AND w.credential_id = 'cc130000-0000-0000-0000-0000000000c1' AND w.api_key_id IS NULL
     AND w.actor = 'cc130000-0000-0000-0000-0000000000a1' AND w.source = 'api', 'M2 the log names the token, its user, source api';
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_public_events WHERE id = v_id), 'M3 a draft is not public';

  v_tier := pg_temp.tw('exos_pat_cc13_p1', 'pat', 'ticket_type.create', v_id::text,
                       '{"ticket_type": {"name": "RSVP", "price": 0, "capacity": 120}}');
  ASSERT (v_tier ->> 'event_id')::uuid = v_id, 'M4 ticket type on the draft';
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_public_events WHERE id = v_id), 'M3 still a draft with a ticket type';
  v_pub := pg_temp.tw('exos_pat_cc13_p1', 'pat', 'event.publish', v_id::text);
  ASSERT (v_pub ->> 'published')::boolean, 'M4 a free event publishes without Stripe: ' || v_pub::text;
  ASSERT EXISTS (SELECT 1 FROM public.exos_public_events WHERE id = v_id), 'M4 public once published';
  RAISE NOTICE 'M2-M4 ok';
END $$;

-- M5 -----------------------------------------------------------------------------
DO $$
DECLARE v jsonb; v_id uuid; v_pub jsonb; w public.exos_api_writes%ROWTYPE;
BEGIN
  v := pg_temp.tw('exos_oat_cc13_o1', 'oauth', 'event.create', NULL,
         pg_temp.ev('CC13 Paid Night', 100) || '{"ticket_types": [{"name": "GA", "price": 25, "capacity": 100}]}');
  v_id := (v ->> 'id')::uuid;
  SELECT * INTO w FROM public.exos_api_writes WHERE action = 'event.create' AND credential_kind = 'oauth' LIMIT 1;
  ASSERT w.credential_id = 'cc130000-0000-0000-0000-0000000000d2' AND w.actor = 'cc130000-0000-0000-0000-0000000000a1',
    'M5 the log names the OAuth grant and its user';
  v_pub := pg_temp.tw('exos_oat_cc13_o1', 'oauth', 'event.publish', v_id::text);
  ASSERT NOT (v_pub ->> 'published')::boolean, 'M5 paid without Connect is not published';
  ASSERT EXISTS (SELECT 1 FROM jsonb_array_elements(v_pub -> 'blockers') b WHERE b ->> 'code' = 'stripe_not_connected'),
    'M5 the blocker says Stripe: ' || v_pub::text;
  ASSERT (SELECT status FROM public.exos_events WHERE id = v_id) = 'draft', 'M5 still a draft';
  RAISE NOTICE 'M5 ok';
END $$;

-- M6 / M7 / M8 / M9 / M10 --------------------------------------------------------------
DO $$
DECLARE v_id uuid; v_tier uuid;
BEGIN
  v_id := (pg_temp.tw('exos_pat_cc13_p1', 'pat', 'event.create', NULL, pg_temp.ev('CC13 M6', 50)) ->> 'id')::uuid;
  v_tier := (pg_temp.tw('exos_pat_cc13_p1', 'pat', 'ticket_type.create', v_id::text,
             '{"ticket_type": {"name": "Free", "price": 0, "capacity": 50}}') ->> 'id')::uuid;
  ASSERT pg_temp.tst('exos_pat_cc13_p1', 'pat', 'event.update', v_id::text, '{"event": {"name": "x"}}') = '42501', 'M6 event.update needs a key';
  ASSERT pg_temp.tst('exos_pat_cc13_p1', 'pat', 'ticket_type.delete', v_tier::text) = '42501', 'M6 ticket_type.delete needs a key';
  ASSERT pg_temp.tst('exos_pat_cc13_p1', 'pat', 'event.unpublish', v_id::text) = '42501', 'M6 event.unpublish needs a key';
  ASSERT pg_temp.tst('exos_oat_cc13_o1', 'oauth', 'refund.claim', 'cs_none', '{}') = '42501', 'M6 refund.claim needs a key';
  ASSERT pg_temp.tst('exos_oat_cc13_o1', 'oauth', 'comp.issue', v_id::text, '{"emails": []}') = '42501', 'M6 comp.issue needs a key';
  BEGIN
    PERFORM public.exos_api_write('cc130000-0000-0000-0000-0000000000f1', 'event.create', NULL, pg_temp.ev('both', 5), NULL,
                                  pg_temp.h('exos_pat_cc13_p1'), 'pat');
    RAISE EXCEPTION 'M6 a key and a token together must be refused';
  EXCEPTION WHEN invalid_parameter_value THEN NULL;
  END;
  BEGIN
    PERFORM public.exos_api_write(NULL, 'event.create', NULL, pg_temp.ev('src', 5), NULL, pg_temp.h('exos_pat_cc13_p1'), 'pat', NULL, 'browser');
    RAISE EXCEPTION 'M6 an unknown source must be refused';
  EXCEPTION WHEN invalid_parameter_value THEN NULL;
  END;
  -- M7
  ASSERT pg_temp.tst('exos_pat_cc13_p2', 'pat', 'event.create', NULL, pg_temp.ev('CC13 M7', 5)) = '42501', 'M7 read-only token refused';
  -- M8: the manager's token works, then not once demoted, then not once removed.
  ASSERT pg_temp.tst('exos_pat_cc13_p3', 'pat', 'event.create', NULL, pg_temp.ev('CC13 M8', 5)) = 'ok', 'M8 manager token creates';
  UPDATE public.exos_org_memberships SET role = 'scanner'
   WHERE org_id = 'cc130000-0000-0000-0000-000000000001' AND user_id = 'cc130000-0000-0000-0000-0000000000a2';
  ASSERT pg_temp.tst('exos_pat_cc13_p3', 'pat', 'event.create', NULL, pg_temp.ev('CC13 M8b', 5)) = '42501', 'M8 demoted to scanner: refused';
  UPDATE public.exos_org_memberships SET role = 'manager', disabled = true
   WHERE org_id = 'cc130000-0000-0000-0000-000000000001' AND user_id = 'cc130000-0000-0000-0000-0000000000a2';
  ASSERT pg_temp.tst('exos_pat_cc13_p3', 'pat', 'event.create', NULL, pg_temp.ev('CC13 M8c', 5)) = '42501', 'M8 disabled: refused';
  -- M9
  ASSERT pg_temp.tst('exos_pat_cc13_p4', 'pat', 'event.create', NULL, pg_temp.ev('CC13 M9', 5)) = 'ok', 'M9 p4 works before';
  UPDATE public.exos_personal_tokens SET revoked_at = now() WHERE id = 'cc130000-0000-0000-0000-0000000000c4';
  ASSERT pg_temp.tst('exos_pat_cc13_p4', 'pat', 'event.create', NULL, pg_temp.ev('CC13 M9b', 5)) = '42501', 'M9 revoked token refused';
  ASSERT pg_temp.tst('exos_pat_cc13_p5', 'pat', 'event.create', NULL, pg_temp.ev('CC13 M9c', 5)) = '42501', 'M9 expired token refused';
  ASSERT pg_temp.tst('exos_pat_cc13_nope', 'pat', 'event.create', NULL, pg_temp.ev('CC13 M9d', 5)) = '42501', 'M9 unknown token refused';
  -- M10
  ASSERT pg_temp.tst('exos_pat_cc13_p1', 'pat', 'event.publish', 'cc130000-0000-0000-0000-0000000000e9') = 'P0002', 'M10 publish another org''s event';
  ASSERT pg_temp.tst('exos_pat_cc13_p1', 'pat', 'ticket_type.create', 'cc130000-0000-0000-0000-0000000000e9',
                     '{"ticket_type": {"name": "x", "price": 0, "capacity": 5}}') = 'P0002', 'M10 ticket type on another org''s event';
  RAISE NOTICE 'M6-M10 ok';
END $$;

-- M9 (the OAuth grant) runs last among the token checks: revoking it ends o1.
-- M11 -----------------------------------------------------------------------------
DO $$
DECLARE a jsonb; b jsonb; c jsonb; w public.exos_api_writes%ROWTYPE;
BEGIN
  a := public.exos_api_write('cc130000-0000-0000-0000-0000000000f1', 'event.create', NULL, pg_temp.ev('CC13 Key', 10), 'cc13-idem-1');
  b := public.exos_api_write('cc130000-0000-0000-0000-0000000000f1', 'event.create', NULL, pg_temp.ev('CC13 Key', 10), 'cc13-idem-1');
  ASSERT a ->> 'id' = b ->> 'id' AND (b ->> 'idempotent_replay')::boolean, 'M11 the key replays its Idempotency-Key';
  SELECT * INTO w FROM public.exos_api_writes WHERE idempotency_key = 'cc13-idem-1';
  ASSERT w.credential_kind = 'api_key' AND w.credential_id = 'cc130000-0000-0000-0000-0000000000f1'
     AND w.api_key_id = 'cc130000-0000-0000-0000-0000000000f1' AND w.actor = 'cc130000-0000-0000-0000-0000000000a1',
    'M11 key rows as before, plus the credential';
  -- The same Idempotency-Key from a token is the token's own, not the key's.
  c := pg_temp.tw('exos_pat_cc13_p1', 'pat', 'event.create', NULL, pg_temp.ev('CC13 Key', 10), 'cc13-idem-1');
  ASSERT c ->> 'id' <> a ->> 'id' AND c ->> 'idempotent_replay' IS NULL, 'M11 Idempotency-Keys are per credential';
  ASSERT (pg_temp.tw('exos_pat_cc13_p1', 'pat', 'event.create', NULL, pg_temp.ev('CC13 Key', 10), 'cc13-idem-1') ->> 'idempotent_replay')::boolean,
    'M11 a token replays its own';
  -- Another writer's rows get their credential from api_key_id (the trigger).
  INSERT INTO public.exos_api_writes (org_id, api_key_id, action) VALUES
    ('cc130000-0000-0000-0000-000000000001', 'cc130000-0000-0000-0000-0000000000f1', 'membership.update');
  ASSERT (SELECT credential_kind = 'api_key' AND credential_id = api_key_id FROM public.exos_api_writes
           WHERE action = 'membership.update' AND org_id = 'cc130000-0000-0000-0000-000000000001'), 'M11 trigger fills the credential';
  RAISE NOTICE 'M11 ok';
END $$;

-- M12 -----------------------------------------------------------------------------
DO $$
DECLARE e150 uuid; e151 uuid; f jsonb;
BEGIN
  -- The size is the capacity capped by what the ticket types add up to.
  e150 := (pg_temp.tw('exos_pat_cc13_p1', 'pat', 'event.create', NULL, pg_temp.ev('CC13 150', 150)
            || '{"ticket_types": [{"name": "GA", "price": 20, "capacity": 150}]}') ->> 'id')::uuid;
  e151 := (pg_temp.tw('exos_pat_cc13_p1', 'pat', 'event.create', NULL, pg_temp.ev('CC13 151', 151)
            || '{"ticket_types": [{"name": "GA", "price": 20, "capacity": 100}, {"name": "VIP", "price": 50, "capacity": 51}]}') ->> 'id')::uuid;
  f := public.exos_mcp_fee_outcome('cc130000-0000-0000-0000-000000000001', e150);
  ASSERT (f ->> 'free_tier')::boolean AND (f ->> 'max_capacity')::int = 150 AND (f ->> 'free_tier_max_capacity')::int = 150,
    'M12 150 is the free tier: ' || f::text;
  f := public.exos_mcp_fee_outcome('cc130000-0000-0000-0000-000000000001', e151);
  ASSERT NOT (f ->> 'free_tier')::boolean AND (f ->> 'max_capacity')::int = 151, 'M12 151 pays the standard fee: ' || f::text;
  ASSERT public.exos_mcp_fee_outcome('cc130000-0000-0000-0000-000000000002', e150) IS NULL, 'M12 another org: nothing';
  RAISE NOTICE 'M12 ok';
END $$;

-- M13 / M15 / M17 -------------------------------------------------------------------
DO $$
DECLARE
  p1 uuid := 'cc130000-0000-0000-0000-0000000000c1';
  o1 uuid := 'cc130000-0000-0000-0000-0000000000d2';
  org uuid := 'cc130000-0000-0000-0000-000000000001';
  args jsonb := pg_temp.ev('CC13 MCP Night', 80);
  r jsonb; v_id uuid; m public.exos_mcp_writes%ROWTYPE;
BEGIN
  PERFORM public.exos_mcp_confirm_issue(org, 'pat', p1, pg_temp.h('exos_pat_cc13_p1'), 'create_event_draft', 'event.create', NULL, args, pg_temp.h('confirm-1'));
  r := public.exos_mcp_write(pg_temp.h('confirm-1'), org, 'pat', p1, pg_temp.h('exos_pat_cc13_p1'), 'create_event_draft', 'event.create', NULL, args);
  ASSERT (r ->> 'ok')::boolean, 'M13 a confirmed write runs: ' || r::text;
  v_id := (r -> 'result' ->> 'id')::uuid;
  ASSERT (SELECT status FROM public.exos_events WHERE id = v_id) = 'draft', 'M13 the draft exists';
  r := public.exos_mcp_write(pg_temp.h('confirm-1'), org, 'pat', p1, pg_temp.h('exos_pat_cc13_p1'), 'create_event_draft', 'event.create', NULL, args);
  ASSERT r ->> 'error' = 'confirm_used', 'M13 reuse refused: ' || r::text;
  ASSERT (SELECT count(*) FROM public.exos_events WHERE name = 'CC13 MCP Night') = 1, 'M13 written once';
  -- M15: the logs.
  SELECT * INTO m FROM public.exos_mcp_writes WHERE id = (r ->> 'write_id')::uuid OR event_id = v_id LIMIT 1;
  ASSERT m.status = 'done' AND m.route_id = 'create-event' AND m.tool = 'create_event_draft' AND m.credential_kind = 'pat'
     AND m.credential_id = p1 AND m.actor = 'cc130000-0000-0000-0000-0000000000a1' AND m.event_id = v_id, 'M15 exos_mcp_writes row';
  ASSERT EXISTS (SELECT 1 FROM public.exos_org_audit a WHERE a.org_id = org AND a.action = 'mcp.write' AND a.source = 'mcp'
                    AND a.entity_type = 'mcp_write' AND a.entity_id = m.id::text AND a.event_id = v_id
                    AND a.actor_uid = 'cc130000-0000-0000-0000-0000000000a1' AND a.changes ->> 'tool' = 'create_event_draft'
                    AND a.changes ->> 'route' = 'create-event' AND a.changes ->> 'credential' = 'pat'),
    'M15 org audit row, source mcp, route and credential';
  ASSERT EXISTS (SELECT 1 FROM public.exos_api_writes w WHERE w.org_id = org AND w.action = 'event.create' AND w.source = 'mcp'
                    AND w.credential_kind = 'pat' AND w.credential_id = p1 AND w.idempotency_key LIKE 'mcp-%'),
    'M15 API write log: source mcp, the credential';

  -- Expired.
  PERFORM public.exos_mcp_confirm_issue(org, 'pat', p1, pg_temp.h('exos_pat_cc13_p1'), 'create_event_draft', 'event.create', NULL, args, pg_temp.h('confirm-2'));
  UPDATE public.exos_mcp_confirms SET expires_at = now() - interval '1 second' WHERE token_hash = pg_temp.h('confirm-2');
  r := public.exos_mcp_write(pg_temp.h('confirm-2'), org, 'pat', p1, pg_temp.h('exos_pat_cc13_p1'), 'create_event_draft', 'event.create', NULL, args);
  ASSERT r ->> 'error' = 'confirm_expired', 'M13 expired refused: ' || r::text;

  -- Changed args: refused and burned.
  PERFORM public.exos_mcp_confirm_issue(org, 'pat', p1, pg_temp.h('exos_pat_cc13_p1'), 'create_event_draft', 'event.create', NULL, args, pg_temp.h('confirm-3'));
  r := public.exos_mcp_write(pg_temp.h('confirm-3'), org, 'pat', p1, pg_temp.h('exos_pat_cc13_p1'), 'create_event_draft', 'event.create', NULL,
                             pg_temp.ev('CC13 MCP Night', 800));
  ASSERT r ->> 'error' = 'confirm_mismatch', 'M13 changed args refused: ' || r::text;
  r := public.exos_mcp_write(pg_temp.h('confirm-3'), org, 'pat', p1, pg_temp.h('exos_pat_cc13_p1'), 'create_event_draft', 'event.create', NULL, args);
  ASSERT r ->> 'error' = 'confirm_used', 'M13 a mismatch burns the token';
  -- Another tool with the same token.
  PERFORM public.exos_mcp_confirm_issue(org, 'pat', p1, pg_temp.h('exos_pat_cc13_p1'), 'create_event_draft', 'event.create', NULL, args, pg_temp.h('confirm-4'));
  BEGIN
    r := public.exos_mcp_write(pg_temp.h('confirm-4'), org, 'pat', p1, pg_temp.h('exos_pat_cc13_p1'), 'publish_event', 'event.create', NULL, args);
    RAISE EXCEPTION 'M13 a tool and an action that do not belong together must be refused';
  EXCEPTION WHEN invalid_parameter_value THEN NULL;
  END;
  -- Another credential's token: the OAuth token presents p1's confirmation.
  r := public.exos_mcp_write(pg_temp.h('confirm-4'), org, 'oauth', o1, pg_temp.h('exos_oat_cc13_o1'), 'create_event_draft', 'event.create', NULL, args);
  ASSERT r ->> 'error' = 'confirm_invalid', 'M13 another credential''s token refused: ' || r::text;
  r := public.exos_mcp_write(pg_temp.h('confirm-4'), org, 'pat', p1, pg_temp.h('exos_pat_cc13_p1'), 'create_event_draft', 'event.create', NULL, args);
  ASSERT (r ->> 'ok')::boolean, 'M13 ...which stays usable by its own credential';
  -- An unknown token.
  r := public.exos_mcp_write(pg_temp.h('nope'), org, 'pat', p1, pg_temp.h('exos_pat_cc13_p1'), 'create_event_draft', 'event.create', NULL, args);
  ASSERT r ->> 'error' = 'confirm_invalid', 'M13 an unknown token refused';
  -- A credential that doesn't check out: refused before anything.
  BEGIN
    PERFORM public.exos_mcp_confirm_issue(org, 'pat', p1, pg_temp.h('exos_pat_cc13_wrong'), 'create_event_draft', 'event.create', NULL, args, pg_temp.h('confirm-5'));
    RAISE EXCEPTION 'M13 issue with a bad bearer must be refused';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  BEGIN
    PERFORM public.exos_mcp_confirm_issue('cc130000-0000-0000-0000-000000000002', 'pat', p1, pg_temp.h('exos_pat_cc13_p1'), 'create_event_draft', 'event.create', NULL, args, pg_temp.h('confirm-6'));
    RAISE EXCEPTION 'M13 issue for another org must be refused';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  -- A revoked credential between the two calls.
  PERFORM public.exos_mcp_confirm_issue(org, 'api_key', 'cc130000-0000-0000-0000-0000000000f1', NULL, 'create_event_draft', 'event.create', NULL, args, pg_temp.h('confirm-7'));
  UPDATE public.exos_api_keys SET revoked_at = now() WHERE id = 'cc130000-0000-0000-0000-0000000000f1';
  r := public.exos_mcp_write(pg_temp.h('confirm-7'), org, 'api_key', 'cc130000-0000-0000-0000-0000000000f1', NULL, 'create_event_draft', 'event.create', NULL, args);
  ASSERT r ->> 'error' = 'credential', 'M13 a key revoked after the preview: refused: ' || r::text;
  UPDATE public.exos_api_keys SET revoked_at = NULL WHERE id = 'cc130000-0000-0000-0000-0000000000f1';

  -- M17: a failed write (another org's event) spends its token and is logged.
  PERFORM public.exos_mcp_confirm_issue(org, 'pat', p1, pg_temp.h('exos_pat_cc13_p1'), 'publish_event', 'event.publish',
                                        'cc130000-0000-0000-0000-0000000000e9', '{}', pg_temp.h('confirm-8'));
  r := public.exos_mcp_write(pg_temp.h('confirm-8'), org, 'pat', p1, pg_temp.h('exos_pat_cc13_p1'), 'publish_event', 'event.publish',
                             'cc130000-0000-0000-0000-0000000000e9', '{}');
  ASSERT r ->> 'error' = 'write_failed' AND r ->> 'code' = 'P0002', 'M17/M10 another org''s event through MCP: not found: ' || r::text;
  ASSERT (SELECT status = 'failed' AND error_code = 'P0002' FROM public.exos_mcp_writes WHERE id = (r ->> 'write_id')::uuid), 'M17 logged failed';
  ASSERT (SELECT used_at IS NOT NULL FROM public.exos_mcp_confirms WHERE token_hash = pg_temp.h('confirm-8')), 'M17 token spent';
  ASSERT (SELECT status FROM public.exos_events WHERE id = 'cc130000-0000-0000-0000-0000000000e9') = 'draft', 'M17 nothing changed there';
  RAISE NOTICE 'M13 M15 M17 ok';
END $$;

-- M14 -----------------------------------------------------------------------------
DO $$
DECLARE
  p1 uuid := 'cc130000-0000-0000-0000-0000000000c1';
  org uuid := 'cc130000-0000-0000-0000-000000000001';
  r jsonb; n int; i int;
BEGIN
  SELECT count(*) INTO n FROM public.exos_mcp_writes WHERE org_id = org AND created_at > now() - interval '1 hour';
  INSERT INTO public.exos_platform_settings (key, value) VALUES ('mcp_writes_per_hour', to_jsonb(n + 2))
    ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value;
  FOR i IN 1..3 LOOP
    PERFORM public.exos_mcp_confirm_issue(org, 'pat', p1, pg_temp.h('exos_pat_cc13_p1'), 'create_event_draft', 'event.create', NULL,
                                          pg_temp.ev('CC13 Cap ' || i, 5), pg_temp.h('cap-' || i));
    r := public.exos_mcp_write(pg_temp.h('cap-' || i), org, 'pat', p1, pg_temp.h('exos_pat_cc13_p1'), 'create_event_draft', 'event.create', NULL,
                               pg_temp.ev('CC13 Cap ' || i, 5));
    IF i <= 2 THEN
      ASSERT (r ->> 'ok')::boolean, 'M14 under the cap: ' || r::text;
    ELSE
      ASSERT r ->> 'error' = 'rate_limited' AND (r ->> 'retry_after_seconds')::int > 0, 'M14 over the cap: ' || r::text;
    END IF;
  END LOOP;
  ASSERT (SELECT used_at IS NULL FROM public.exos_mcp_confirms WHERE token_hash = pg_temp.h('cap-3')), 'M14 the refused token is kept';
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_events WHERE name = 'CC13 Cap 3'), 'M14 nothing written over the cap';
  -- The cap is per org: org 2's count is its own.
  ASSERT (SELECT count(*) FROM public.exos_mcp_writes WHERE org_id = 'cc130000-0000-0000-0000-000000000002') = 0, 'M14 org 2 untouched';
  DELETE FROM public.exos_platform_settings WHERE key = 'mcp_writes_per_hour';
  RAISE NOTICE 'M14 ok';
END $$;

-- M16 + M9 (grant) ---------------------------------------------------------------------
DO $$
DECLARE s jsonb; v_id uuid;
BEGIN
  v_id := (pg_temp.tw('exos_oat_cc13_o1', 'oauth', 'event.create', NULL, '{"event": {"name": "CC13 State"}}') ->> 'id')::uuid;
  s := public.exos_mcp_event_state('cc130000-0000-0000-0000-000000000001', v_id);
  ASSERT s -> 'event' ->> 'status' = 'draft' AND jsonb_array_length(s -> 'blockers') > 0
     AND EXISTS (SELECT 1 FROM jsonb_array_elements(s -> 'blockers') b WHERE b ->> 'code' = 'missing_start'), 'M16 own draft with blockers';
  ASSERT public.exos_mcp_event_state('cc130000-0000-0000-0000-000000000001', 'cc130000-0000-0000-0000-0000000000e9') IS NULL,
    'M16 another org''s event is NULL';
  -- M9: revoking the OAuth grant stops its access token on the next call.
  UPDATE public.exos_oauth_grants SET revoked_at = now() WHERE id = 'cc130000-0000-0000-0000-0000000000d2';
  ASSERT pg_temp.tst('exos_oat_cc13_o1', 'oauth', 'event.create', NULL, pg_temp.ev('CC13 Revoked', 5)) = '42501', 'M9 revoked grant refused';
  RAISE NOTICE 'M16 M9 ok';
END $$;

-- M15: owner / manager read their org's MCP write log; nobody else's.
DO $$
DECLARE n int;
BEGIN
  SET LOCAL ROLE authenticated;
  PERFORM set_config('app.uid', 'cc130000-0000-0000-0000-0000000000a5', true);
  SELECT count(*) INTO n FROM public.exos_mcp_writes WHERE org_id = 'cc130000-0000-0000-0000-000000000001';
  ASSERT n = 0, 'M15 another org''s owner sees none';
  PERFORM set_config('app.uid', 'cc130000-0000-0000-0000-0000000000a1', true);
  SELECT count(*) INTO n FROM public.exos_mcp_writes WHERE org_id = 'cc130000-0000-0000-0000-000000000001';
  ASSERT n > 0, 'M15 the owner sees the org''s';
  RESET ROLE;
  PERFORM set_config('app.uid', '', true);
  RAISE NOTICE 'M15 RLS ok';
END $$;

ROLLBACK;
\echo 'test_mcp_writes: all assertions passed'
