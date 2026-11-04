-- ============================================================================
-- Org API permissions, venue booking requests + event-scoped grants, partner
-- presale (mig 20261104180000). Self-contained (ac prefix), rolled back.
--   OA1  grants: what anon / authenticated / service_role may call
--   OA2  the ceiling per role; today's sets are the defaults
--   OA3  only the owner edits a role's set, never above its ceiling
--   OA4  existing keys and tokens lose a scope at once; raising gives it back
--   OA5  new keys are held to the maker's set
--   OA6  a promoter is blocked at a venue another org runs (events, holds,
--        templates, its own record once it links it); a squatter's "owned"
--        venue captures nothing; links are explicit, suggestions ambiguous
--   OA7  request -> approve as an event -> the event-scoped grant works;
--        co-host edits need the promoter key's owner / manager and are logged
--   OA8  grant changes (money: gross only with finance:read in the grant AND
--        the key); a revoked grant stops it; decline, withdraw, approve as a
--        hold then convert later
--   OA9  cross-org isolation
--   OA10 partner presale: block (default) vs allow, org setting and event
--        override, who may set it
-- Orgs: V (venue: owner a1, manager a2, finance a3, content a4, scanner a5),
-- P (promoter: owner b1, manager b2), X (another org: owner c1).
-- ============================================================================
\set ON_ERROR_STOP on
BEGIN;

-- auth.uid() as Supabase defines it (exos_api_write sets the request
-- claims to the key's creator), still honouring the harness's app.uid.
CREATE OR REPLACE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql STABLE AS $$
  SELECT coalesce(nullif(current_setting('app.uid', true), ''),
                  nullif(current_setting('request.jwt.claim.sub', true), ''),
                  nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'sub')::uuid
$$;
SELECT set_config('app.uid', '', false);

INSERT INTO auth.users (id, email, email_confirmed_at) VALUES
  ('ac000000-0000-0000-0000-0000000000a1', 'ac-owner@x.com', now()),
  ('ac000000-0000-0000-0000-0000000000a2', 'ac-manager@x.com', now()),
  ('ac000000-0000-0000-0000-0000000000a3', 'ac-finance@x.com', now()),
  ('ac000000-0000-0000-0000-0000000000a4', 'ac-content@x.com', now()),
  ('ac000000-0000-0000-0000-0000000000a5', 'ac-scanner@x.com', now()),
  ('ac000000-0000-0000-0000-0000000000b1', 'ac-promoter@x.com', now()),
  ('ac000000-0000-0000-0000-0000000000b2', 'ac-promoter-mgr@x.com', now()),
  ('ac000000-0000-0000-0000-0000000000c1', 'ac-other@x.com', now());
INSERT INTO public.exos_orgs (id, name, slug, owner_uid) VALUES
  ('ac000000-0000-0000-0000-000000000001', 'AC Venue Co', 'ac-venue', 'ac000000-0000-0000-0000-0000000000a1'),
  ('ac000000-0000-0000-0000-000000000002', 'AC Promoter', 'ac-promoter', 'ac000000-0000-0000-0000-0000000000b1'),
  ('ac000000-0000-0000-0000-000000000003', 'AC Other', 'ac-other', 'ac000000-0000-0000-0000-0000000000c1');
INSERT INTO public.exos_org_memberships (org_id, user_id, role) VALUES
  ('ac000000-0000-0000-0000-000000000001', 'ac000000-0000-0000-0000-0000000000a1', 'owner'),
  ('ac000000-0000-0000-0000-000000000001', 'ac000000-0000-0000-0000-0000000000a2', 'manager'),
  ('ac000000-0000-0000-0000-000000000001', 'ac000000-0000-0000-0000-0000000000a3', 'finance'),
  ('ac000000-0000-0000-0000-000000000001', 'ac000000-0000-0000-0000-0000000000a4', 'content'),
  ('ac000000-0000-0000-0000-000000000001', 'ac000000-0000-0000-0000-0000000000a5', 'scanner'),
  ('ac000000-0000-0000-0000-000000000002', 'ac000000-0000-0000-0000-0000000000b1', 'owner'),
  ('ac000000-0000-0000-0000-000000000002', 'ac000000-0000-0000-0000-0000000000b2', 'manager'),
  ('ac000000-0000-0000-0000-000000000003', 'ac000000-0000-0000-0000-0000000000c1', 'owner');
-- Keys (as stored before this migration): f1 the venue manager's (wide),
-- f2 the venue owner's, f3 a legacy read key of the manager's, f4 the
-- promoter owner's, f5 the other org's.
INSERT INTO public.exos_api_keys (id, org_id, name, key_prefix, key_hash, scopes, created_by) VALUES
  ('ac000000-0000-0000-0000-0000000000f1', 'ac000000-0000-0000-0000-000000000001', 'mgr', 'sk_live_acf1',
   encode(extensions.digest('sk_live_ac_f1', 'sha256'), 'hex'),
   ARRAY['events:write','orders:read','fans:read','refunds:write','webhooks:write','booking:write','org:admin'],
   'ac000000-0000-0000-0000-0000000000a2'),
  ('ac000000-0000-0000-0000-0000000000f2', 'ac000000-0000-0000-0000-000000000001', 'own', 'sk_live_acf2', 'acf2hash',
   ARRAY['events:write','booking:write','fans:read','org:admin'], 'ac000000-0000-0000-0000-0000000000a1'),
  ('ac000000-0000-0000-0000-0000000000f3', 'ac000000-0000-0000-0000-000000000001', 'legacy', 'sk_live_acf3', 'acf3hash',
   ARRAY['read'], 'ac000000-0000-0000-0000-0000000000a2'),
  ('ac000000-0000-0000-0000-0000000000f4', 'ac000000-0000-0000-0000-000000000002', 'promoter', 'sk_live_acf4', 'acf4hash',
   ARRAY['events:write','booking:write','tickets:read','finance:read'], 'ac000000-0000-0000-0000-0000000000b1'),
  ('ac000000-0000-0000-0000-0000000000f5', 'ac000000-0000-0000-0000-000000000003', 'other', 'sk_live_acf5', 'acf5hash',
   ARRAY['events:write','booking:write','tickets:read'], 'ac000000-0000-0000-0000-0000000000c1');

-- The venue: an owned hall in Brooklyn with a room.
INSERT INTO public.exos_venues (id, org_id, name, timezone, capacity, address) VALUES
  ('ac000000-0000-0000-0000-0000000000e1', 'ac000000-0000-0000-0000-000000000001', 'AC Hall', 'America/New_York', 500,
   '{"city":"Brooklyn","region":"NY"}');
INSERT INTO public.exos_venue_rooms (id, venue_id, name, capacity) VALUES
  ('ac000000-0000-0000-0000-0000000000e2', 'ac000000-0000-0000-0000-0000000000e1', 'Main Room', 300);

-- As the dashboard has them (the harness's base schema grants none; rolled back).
GRANT SELECT, INSERT, UPDATE ON public.exos_events TO authenticated;
GRANT SELECT ON public.exos_ticket_tiers TO authenticated;
CREATE TEMP TABLE ac (k text PRIMARY KEY, v text) ON COMMIT DROP;
GRANT ALL ON ac TO authenticated, service_role;
CREATE FUNCTION pg_temp.act(p_uid text) RETURNS void LANGUAGE sql AS $$
  SELECT set_config('app.uid', coalesce(p_uid, ''), true);
$$;
CREATE FUNCTION pg_temp.u(p text) RETURNS text LANGUAGE sql IMMUTABLE AS $$
  SELECT 'ac000000-0000-0000-0000-0000000000' || p
$$;
CREATE FUNCTION pg_temp.o(p int) RETURNS uuid LANGUAGE sql IMMUTABLE AS $$
  SELECT ('ac000000-0000-0000-0000-00000000000' || p)::uuid
$$;
-- The SQLSTATE (and message) a statement fails with; 'ok' when it doesn't.
CREATE FUNCTION pg_temp.st(p_sql text) RETURNS text LANGUAGE plpgsql AS $$
BEGIN
  EXECUTE p_sql;
  RETURN 'ok';
EXCEPTION WHEN OTHERS THEN RETURN SQLSTATE || ' ' || SQLERRM;
END $$;
GRANT EXECUTE ON FUNCTION pg_temp.act(text), pg_temp.u(text), pg_temp.o(int), pg_temp.st(text) TO authenticated, service_role;
CREATE FUNCTION pg_temp.v(p text) RETURNS text LANGUAGE sql AS $$ SELECT v FROM ac WHERE k = p $$;
GRANT EXECUTE ON FUNCTION pg_temp.v(text) TO authenticated, service_role;
CREATE FUNCTION pg_temp.h(p text) RETURNS text LANGUAGE sql IMMUTABLE SECURITY DEFINER AS $$
  SELECT encode(extensions.digest(p, 'sha256'), 'hex')
$$;
CREATE FUNCTION pg_temp.kid(p text) RETURNS text LANGUAGE sql STABLE SECURITY DEFINER AS $$
  SELECT id::text FROM public.exos_api_keys WHERE key_hash = encode(extensions.digest(p, 'sha256'), 'hex')
$$;
GRANT EXECUTE ON FUNCTION pg_temp.h(text), pg_temp.kid(text) TO authenticated, service_role;
CREATE FUNCTION pg_temp.day(p int) RETURNS text LANGUAGE sql STABLE AS $$ SELECT to_char(current_date + p, 'YYYY-MM-DD') $$;
GRANT EXECUTE ON FUNCTION pg_temp.day(int) TO authenticated, service_role;

-- OA1 -------------------------------------------------------------------------
DO $$
DECLARE f text;
BEGIN
  FOREACH f IN ARRAY ARRAY['public.exos_api_key_auth(text)', 'public._exos_api_key_scopes(uuid)',
      'public._exos_org_role_scopes(uuid,text,boolean)', 'public._exos_scopes_for_role(text[],text,uuid,boolean)',
      'public._exos_org_role_scopes_set(uuid,uuid,text,text[])', 'public._exos_venue_gate(uuid,uuid)',
      'public._exos_venue_directory(uuid,text,integer)', 'public._exos_venue_request_create(uuid,uuid,text,uuid,jsonb)',
      'public._exos_venue_request_decide(uuid,uuid,text,uuid,uuid,text,jsonb)', 'public._exos_venue_request_withdraw(uuid,uuid,uuid)',
      'public._exos_venue_link_suggestions(uuid,uuid)', 'public._exos_venue_link(uuid,uuid,uuid)',
      'public._exos_venue_request_get(uuid,uuid)', 'public._exos_venue_requests_page(uuid,text,text,integer,integer)',
      'public._exos_partner_grants_list(uuid,uuid,boolean)', 'public._exos_partner_grant_set(uuid,uuid,uuid,jsonb)',
      'public._exos_partner_grant_revoke(uuid,uuid,uuid)', 'public._exos_cohost_events(uuid)',
      'public._exos_cohost_event(uuid,uuid)', 'public._exos_cohost_event_update(uuid,uuid,jsonb,uuid)',
      'public._exos_cohost_event_sales(uuid,uuid,text[])', 'public._exos_partner_presale_mode(uuid)',
      'public._exos_partner_presale_get(uuid,uuid)', 'public._exos_partner_presale_set(uuid,uuid,uuid,text)',
      'public._exos_api_key_actor(uuid,uuid,text[])'] LOOP
    ASSERT NOT has_function_privilege('anon', f, 'EXECUTE') AND NOT has_function_privilege('authenticated', f, 'EXECUTE')
       AND has_function_privilege('service_role', f, 'EXECUTE'), 'OA1 service only: ' || f;
  END LOOP;
  FOREACH f IN ARRAY ARRAY['public.exos_org_role_scopes_get(uuid)', 'public.exos_org_role_scopes_set(uuid,text,text[])',
      'public.exos_org_role_scopes_reset(uuid,text)', 'public.exos_venue_directory(uuid,text)',
      'public.exos_venue_request_create(uuid,jsonb)', 'public.exos_venue_request_decide(uuid,text,jsonb)',
      'public.exos_venue_requests(uuid,text,text)', 'public.exos_partner_grants(uuid)',
      'public.exos_partner_grant_set(uuid,text[])', 'public.exos_partner_grant_revoke(uuid)', 'public.exos_cohost_events(uuid)',
      'public.exos_partner_presale_get(uuid,uuid)', 'public.exos_partner_presale_set(uuid,text)',
      'public.exos_event_partner_presale_set(uuid,text)', 'public.exos_venue_link_suggestions(uuid)',
      'public.exos_venue_link(uuid,uuid)'] LOOP
    ASSERT NOT has_function_privilege('anon', f, 'EXECUTE') AND has_function_privilege('authenticated', f, 'EXECUTE'),
      'OA1 authenticated: ' || f;
  END LOOP;
  FOREACH f IN ARRAY ARRAY['public._exos_tg_org_role_scopes()', 'public._exos_tg_api_key_role_cap()',
      'public._exos_tg_venue_listing()', 'public._exos_tg_event_partner_grant()', 'public._exos_grant_clean_scopes(jsonb)',
      'public._exos_cohost_need(uuid,uuid,text)', 'public._exos_partner_grant_json(uuid)'] LOOP
    ASSERT NOT has_function_privilege('anon', f, 'EXECUTE') AND NOT has_function_privilege('authenticated', f, 'EXECUTE'),
      'OA1 internal: ' || f;
  END LOOP;
  FOREACH f IN ARRAY ARRAY['public.exos_org_role_scopes', 'public.exos_venue_requests', 'public.exos_event_partner_grants',
      'public.exos_org_partner_presale', 'public.exos_event_partner_presale', 'public.exos_cohost_event_edits'] LOOP
    ASSERT NOT has_table_privilege('anon', f, 'SELECT') AND has_table_privilege('authenticated', f, 'SELECT')
       AND NOT has_table_privilege('authenticated', f, 'INSERT') AND NOT has_table_privilege('authenticated', f, 'UPDATE')
       AND NOT has_table_privilege('authenticated', f, 'DELETE'), 'OA1 table: ' || f;
    ASSERT (SELECT relrowsecurity FROM pg_class WHERE oid = f::regclass), 'OA1 RLS on ' || f;
  END LOOP;
  RAISE NOTICE 'OK  OA1 grants';
END $$;

-- OA2 -------------------------------------------------------------------------
DO $$
DECLARE r text; s text;
BEGIN
  ASSERT public.exos_role_scope_ceiling('owner') = public._exos_org_scope_vocab(), 'OA2 owner ceiling = everything';
  FOREACH r IN ARRAY ARRAY['owner', 'manager', 'finance', 'content', 'scanner'] LOOP
    -- Today's default fits under the ceiling, and is what applies with no row.
    FOREACH s IN ARRAY public.exos_role_token_scopes(r) LOOP
      CONTINUE WHEN s LIKE 'me:%';
      ASSERT s = ANY (public.exos_role_scope_ceiling(r)), format('OA2 %s default %s above the ceiling', r, s);
    END LOOP;
    ASSERT public._exos_org_role_scopes(pg_temp.o(1), r) = public.exos_role_token_scopes(r), 'OA2 token default applies: ' || r;
    ASSERT public._exos_org_role_scopes(pg_temp.o(1), r, true) = public.exos_role_scope_ceiling(r), 'OA2 key default (as before): ' || r;
    ASSERT NOT ('org:admin' = ANY (public.exos_role_scope_ceiling(r))) OR r = 'owner', 'OA2 org:admin owner-only: ' || r;
  END LOOP;
  ASSERT NOT (public.exos_role_scope_ceiling('content') && ARRAY['finance:read','finance:write','refunds:write','orders:read']),
    'OA2 content never gets finance, refunds or orders';
  ASSERT public.exos_role_scope_ceiling('scanner') = ARRAY['events:read','tickets:read','checkin:write'], 'OA2 scanner door-only';
  ASSERT 'refunds:write' = ANY (public.exos_role_scope_ceiling('finance'))
     AND NOT ('events:write' = ANY (public.exos_role_scope_ceiling('finance'))), 'OA2 finance: refunds, no event edits';
  ASSERT public.exos_role_scope_ceiling('nobody') = '{}', 'OA2 unknown role';
  ASSERT cardinality(public._exos_org_role_scopes(pg_temp.o(1), 'nobody')) = 0, 'OA2 unknown role: nothing';
  RAISE NOTICE 'OK  OA2 ceilings and defaults';
END $$;

-- OA3 -------------------------------------------------------------------------
SET LOCAL ROLE authenticated;
DO $$
DECLARE v jsonb; s text;
BEGIN
  -- Any member reads; only the owner's view is editable.
  PERFORM pg_temp.act(pg_temp.u('a5'));
  v := public.exos_org_role_scopes_get(pg_temp.o(1));
  ASSERT NOT (v->>'editable')::boolean AND jsonb_array_length(v->'roles') = 5, 'OA3 scanner reads ' || v::text;
  PERFORM pg_temp.act(pg_temp.u('c1'));
  s := pg_temp.st($q$SELECT public.exos_org_role_scopes_get('ac000000-0000-0000-0000-000000000001')$q$);
  ASSERT s LIKE '42501%', 'OA3 another org''s owner reads: ' || s;
  -- A manager (or finance) can't change it.
  PERFORM pg_temp.act(pg_temp.u('a2'));
  s := pg_temp.st($q$SELECT public.exos_org_role_scopes_set('ac000000-0000-0000-0000-000000000001', 'manager', ARRAY['fans:read'])$q$);
  ASSERT s LIKE '42501%', 'OA3 manager edits: ' || s;
  s := pg_temp.st($q$INSERT INTO public.exos_org_role_scopes (org_id, role, scopes) VALUES ('ac000000-0000-0000-0000-000000000001', 'manager', '{}')$q$);
  ASSERT s LIKE '42501%', 'OA3 direct write: ' || s;
  -- The owner: within the ceiling only; the owner's own set is fixed.
  PERFORM pg_temp.act(pg_temp.u('a1'));
  v := public.exos_org_role_scopes_get(pg_temp.o(1));
  ASSERT (v->>'editable')::boolean, 'OA3 owner editable';
  s := pg_temp.st($q$SELECT public.exos_org_role_scopes_set('ac000000-0000-0000-0000-000000000001', 'content', ARRAY['events:read','finance:read'])$q$);
  ASSERT s LIKE '42501%role_scope_ceiling%', 'OA3 content finance: ' || s;
  s := pg_temp.st($q$SELECT public.exos_org_role_scopes_set('ac000000-0000-0000-0000-000000000001', 'content', ARRAY['refunds:write'])$q$);
  ASSERT s LIKE '42501%', 'OA3 content refunds: ' || s;
  s := pg_temp.st($q$SELECT public.exos_org_role_scopes_set('ac000000-0000-0000-0000-000000000001', 'scanner', ARRAY['events:write'])$q$);
  ASSERT s LIKE '42501%', 'OA3 scanner events:write: ' || s;
  s := pg_temp.st($q$SELECT public.exos_org_role_scopes_set('ac000000-0000-0000-0000-000000000001', 'manager', ARRAY['org:admin'])$q$);
  ASSERT s LIKE '42501%', 'OA3 manager org:admin: ' || s;
  s := pg_temp.st($q$SELECT public.exos_org_role_scopes_set('ac000000-0000-0000-0000-000000000001', 'manager', ARRAY['nope:read'])$q$);
  ASSERT s LIKE '22023%', 'OA3 unknown scope: ' || s;
  s := pg_temp.st($q$SELECT public.exos_org_role_scopes_set('ac000000-0000-0000-0000-000000000001', 'owner', ARRAY['events:read'])$q$);
  ASSERT s LIKE '22023%', 'OA3 owner set: ' || s;
  v := public.exos_org_role_scopes_set(pg_temp.o(1), 'finance', ARRAY['refunds:write', 'events:read', 'fans:read', 'orders:read']);
  ASSERT (SELECT r->'effective' FROM jsonb_array_elements(v->'roles') r WHERE r->>'role' = 'finance')
         = '["events:read","orders:read","refunds:write","fans:read"]'::jsonb, 'OA3 finance set, vocabulary order ' || v::text;
  v := public.exos_org_role_scopes_reset(pg_temp.o(1), 'finance');
  ASSERT (SELECT r->'configured' FROM jsonb_array_elements(v->'roles') r WHERE r->>'role' = 'finance') = 'null'::jsonb,
    'OA3 reset to the default';
  PERFORM pg_temp.act(NULL);
END $$;
RESET ROLE;
DO $$
DECLARE s text;
BEGIN
  -- Even the service role can't write a row above the ceiling.
  s := pg_temp.st($q$INSERT INTO public.exos_org_role_scopes (org_id, role, scopes) VALUES ('ac000000-0000-0000-0000-000000000003', 'scanner', ARRAY['finance:read'])$q$);
  ASSERT s LIKE '42501%', 'OA3 trigger ceiling: ' || s;
  RAISE NOTICE 'OK  OA3 owner-only edits within the ceiling';
END $$;

-- OA4 -------------------------------------------------------------------------
SET LOCAL ROLE authenticated;
DO $$
DECLARE v jsonb;
BEGIN
  PERFORM pg_temp.act(pg_temp.u('a2'));
  v := public.exos_create_personal_token(pg_temp.o(1), 'mgr pat', ARRAY['events:write','orders:read'], 30);
  INSERT INTO ac VALUES ('pat', v->>'token');
  PERFORM pg_temp.act(NULL);
END $$;
RESET ROLE;
SET LOCAL ROLE service_role;
DO $$
DECLARE k jsonb; t jsonb; s text; v_hash text := pg_temp.h(pg_temp.v('pat'));
BEGIN
  -- The manager's wide key, with no row: as before (the manager's
  -- dashboard reach), only org:admin (owners only) drops.
  k := public.exos_api_key_auth(pg_temp.h('sk_live_ac_f1'));
  ASSERT k->'scopes' = '["events:read","events:write","orders:read","refunds:write","fans:read","booking:read","booking:write","webhooks:read","webhooks:write"]'::jsonb,
    'OA4 manager key with no setting: ' || k::text;
  ASSERT k->'key_scopes' ? 'refunds:write' AND k->>'creator_role' = 'manager', 'OA4 stored scopes kept';
  ASSERT public.exos_api_key_auth('acf2hash') IS NULL AND public.exos_api_key_auth(repeat('0', 64)) IS NULL,
    'OA4 malformed / unknown hash';
  -- The legacy read key: every :read, as before (the manager reaches them all).
  ASSERT public._exos_api_key_scopes(pg_temp.u('f3')::uuid)
         = ARRAY['events:read','orders:read','fans:read','tickets:read','booking:read','finance:read','commerce:read','webhooks:read'],
    'OA4 legacy read narrowed: ' || public._exos_api_key_scopes(pg_temp.u('f3')::uuid)::text;
  t := public.exos_api_token_auth(v_hash, 'pat');
  ASSERT t->'scopes' = '["events:read","events:write","orders:read"]'::jsonb, 'OA4 PAT before ' || t::text;
  -- An API write with the stored events:write works now.
  PERFORM public.exos_api_write(pg_temp.u('f1')::uuid, 'event.create', NULL, '{"event":{"name":"AC Before"}}', NULL);
END $$;
RESET ROLE;
-- The owner takes events:write, orders:read, refunds and webhooks off managers (fans:read stays).
SET LOCAL ROLE authenticated;
SELECT pg_temp.act('ac000000-0000-0000-0000-0000000000a1');
SELECT public.exos_org_role_scopes_set('ac000000-0000-0000-0000-000000000001', 'manager',
  ARRAY['events:read','fans:read','tickets:read','booking:read','booking:write']);
SELECT pg_temp.act(NULL);
RESET ROLE;
SET LOCAL ROLE service_role;
DO $$
DECLARE k jsonb; t jsonb; s text; v_hash text := pg_temp.h(pg_temp.v('pat'));
BEGIN
  k := public.exos_api_key_auth(pg_temp.h('sk_live_ac_f1'));
  ASSERT k->'scopes' = '["events:read","fans:read","booking:read","booking:write"]'::jsonb,
    'OA4 existing key lost events:write, orders:read, refunds and webhooks at once: ' || k::text;
  ASSERT NOT (k->'scopes' ? 'tickets:read'), 'OA4 a raise never gives a key what it wasn''t made with';
  ASSERT k->'key_scopes' ? 'events:write', 'OA4 the stored scopes are untouched';
  -- The SQL write path refuses at once.
  s := pg_temp.st($q$SELECT public.exos_api_write('ac000000-0000-0000-0000-0000000000f1', 'event.create', NULL, '{"event":{"name":"AC After"}}', NULL)$q$);
  ASSERT s LIKE '42501%events:write%', 'OA4 SQL scope check: ' || s;
  -- The owner's key is untouched.
  ASSERT public._exos_api_key_scopes(pg_temp.u('f2')::uuid) @> ARRAY['events:write','org:admin'], 'OA4 owner key';
  -- The manager's token too (a write the role lacks keeps the read).
  t := public.exos_api_token_auth(v_hash, 'pat');
  ASSERT t->'scopes' = '["events:read"]'::jsonb, 'OA4 PAT narrowed at once: ' || t::text;
  -- Another org's managers are unaffected.
  ASSERT public._exos_org_role_scopes(pg_temp.o(3), 'manager') = public.exos_role_token_scopes('manager'), 'OA4 per org';
END $$;
RESET ROLE;
-- Back to the default: the key writes again.
SET LOCAL ROLE authenticated;
SELECT pg_temp.act('ac000000-0000-0000-0000-0000000000a1');
SELECT public.exos_org_role_scopes_reset('ac000000-0000-0000-0000-000000000001', 'manager');
SELECT pg_temp.act(NULL);
RESET ROLE;
SET LOCAL ROLE service_role;
DO $$
BEGIN
  PERFORM public.exos_api_write(pg_temp.u('f1')::uuid, 'event.create', NULL, '{"event":{"name":"AC Again"}}', NULL);
END $$;
RESET ROLE;
DO $$
BEGIN
  ASSERT (SELECT count(*) FROM public.exos_events WHERE org_id = pg_temp.o(1) AND name IN ('AC Before', 'AC After', 'AC Again')) = 2,
    'OA4 before and again, not after';
  RAISE NOTICE 'OK  OA4 existing keys and tokens follow the org''s set at request time';
END $$;

-- OA5 -------------------------------------------------------------------------
SET LOCAL ROLE authenticated;
DO $$
DECLARE s text; v_key text;
BEGIN
  PERFORM pg_temp.act(pg_temp.u('a2'));
  s := pg_temp.st($q$SELECT public.exos_create_api_key('ac000000-0000-0000-0000-000000000001', 'x', ARRAY['org:admin'])$q$);
  ASSERT s LIKE '42501%org:admin%', 'OA5 manager key above the ceiling: ' || s;
  -- With no setting a manager's key may carry webhooks (as before); the owner's setting then decides.
  PERFORM public.exos_create_api_key(pg_temp.o(1), 'hooks0', ARRAY['webhooks:write']);
  PERFORM pg_temp.act(pg_temp.u('a1'));
  PERFORM public.exos_org_role_scopes_set(pg_temp.o(1), 'manager', public.exos_role_token_scopes('manager'));
  PERFORM pg_temp.act(pg_temp.u('a2'));
  s := pg_temp.st($q$SELECT public.exos_create_api_key('ac000000-0000-0000-0000-000000000001', 'x', ARRAY['webhooks:write'])$q$);
  ASSERT s LIKE '42501%webhooks:write%', 'OA5 manager key above the owner''s set: ' || s;
  s := pg_temp.st($q$SELECT public.exos_create_personal_token('ac000000-0000-0000-0000-000000000001', 'x', ARRAY['fans:read'], 30)$q$);
  ASSERT s LIKE '42501%', 'OA5 manager PAT above the set: ' || s;
  v_key := public.exos_create_api_key(pg_temp.o(1), 'ok', ARRAY['events:write', 'booking:read']);
  INSERT INTO ac VALUES ('mgrkey', pg_temp.kid(v_key));
  PERFORM pg_temp.act(pg_temp.u('a1'));
  PERFORM public.exos_org_role_scopes_set(pg_temp.o(1), 'manager',
    public.exos_role_token_scopes('manager') || ARRAY['webhooks:read', 'webhooks:write']);
  PERFORM pg_temp.act(pg_temp.u('a2'));
  PERFORM public.exos_create_api_key(pg_temp.o(1), 'hooks', ARRAY['webhooks:write']);
  -- Widening a key is held to the set too; an existing scope can stay.
  s := pg_temp.st(format($q$SELECT public.exos_set_api_key_scopes(%L, ARRAY['events:write','booking:read','refunds:write'])$q$, pg_temp.v('mgrkey')));
  ASSERT s LIKE '42501%refunds:write%', 'OA5 widening: ' || s;
  PERFORM public.exos_set_api_key_scopes(pg_temp.v('mgrkey')::uuid, ARRAY['events:write', 'booking:read', 'webhooks:read']);
  PERFORM pg_temp.act(pg_temp.u('a1'));
  PERFORM public.exos_org_role_scopes_reset(pg_temp.o(1), 'manager');
  -- The owner may give a key anything.
  PERFORM public.exos_create_api_key(pg_temp.o(1), 'own2', ARRAY['org:admin', 'refunds:write']);
  PERFORM pg_temp.act(NULL);
  RAISE NOTICE 'OK  OA5 keys and tokens are made within the maker''s set';
END $$;
RESET ROLE;

-- OA6 -------------------------------------------------------------------------
SET LOCAL ROLE authenticated;
DO $$
DECLARE s text; v uuid; v0 uuid; v2 uuid; sq uuid; ev uuid; sg jsonb;
BEGIN
  PERFORM pg_temp.act(pg_temp.u('b1'));
  -- An event at the venue org's hall.
  s := pg_temp.st($q$INSERT INTO public.exos_events (org_id, name, status, starts_at, exos_venue_id)
                    VALUES ('ac000000-0000-0000-0000-000000000002', 'Sneaky', 'draft', now() + interval '20 days',
                            'ac000000-0000-0000-0000-0000000000e1')$q$);
  ASSERT s LIKE '22023 venue_approval_required%ac000000-0000-0000-0000-0000000000e1%', 'OA6 event: ' || s;
  INSERT INTO public.exos_events (org_id, name, status, starts_at) VALUES (pg_temp.o(2), 'Promoter show', 'draft', now() + interval '20 days')
  RETURNING id INTO ev;
  s := pg_temp.st(format($q$UPDATE public.exos_events SET exos_venue_id = 'ac000000-0000-0000-0000-0000000000e1' WHERE id = %L$q$, ev));
  ASSERT s LIKE '22023 venue_approval_required%', 'OA6 event update: ' || s;
  -- A hold night there.
  s := pg_temp.st(format($q$SELECT public.exos_hold_create('ac000000-0000-0000-0000-000000000002', jsonb_build_object('title', 'Mine',
         'positions', jsonb_build_array(jsonb_build_object('date', %L, 'venue_id', 'ac000000-0000-0000-0000-0000000000e1'))))$q$, pg_temp.day(30)));
  ASSERT s LIKE '22023 venue_approval_required%', 'OA6 hold: ' || s;
  -- A template naming it.
  s := pg_temp.st($q$INSERT INTO public.exos_event_templates (org_id, name, event_fields)
                    VALUES ('ac000000-0000-0000-0000-000000000002', 'T', '{"exos_venue_id":"ac000000-0000-0000-0000-0000000000e1"}')$q$);
  ASSERT s LIKE '22023 venue_approval_required%', 'OA6 template: ' || s;
  -- The promoter's record of the hall, made before anyone else claims it.
  INSERT INTO public.exos_venues (org_id, name, relationship, address) VALUES (pg_temp.o(2), 'AC Hall', 'partner', '{"city":"Brooklyn"}')
  RETURNING id INTO v0;
  ASSERT (SELECT listed_venue_id FROM public.exos_venues WHERE id = v0) IS NULL, 'OA6 no auto-link on create';
  -- A squatter (another org) declares a same-named "owned" hall in the same city.
  PERFORM pg_temp.act(pg_temp.u('c1'));
  INSERT INTO public.exos_venues (org_id, name, relationship, address) VALUES (pg_temp.o(3), 'AC Hall', 'owned', '{"city":"Brooklyn"}')
  RETURNING id INTO sq;
  s := pg_temp.st(format($q$UPDATE public.exos_venues SET verified = true WHERE id = %L$q$, sq));
  ASSERT s LIKE '42501%', 'OA6 an org can''t verify itself: ' || s;
  PERFORM pg_temp.act(pg_temp.u('b1'));
  -- It captures nothing: the existing record, renamed, stays unlinked and usable.
  UPDATE public.exos_venues SET name = ' ac hall ', address = '{"city":"brooklyn"}' WHERE id = v0;
  ASSERT (SELECT listed_venue_id FROM public.exos_venues WHERE id = v0) IS NULL, 'OA6 a squatter doesn''t capture an existing record';
  PERFORM public.exos_hold_create(pg_temp.o(2), jsonb_build_object('title', 'Still mine',
    'positions', jsonb_build_array(jsonb_build_object('date', pg_temp.day(29), 'venue_id', v0))));
  -- A new same-named record isn't linked either.
  INSERT INTO public.exos_venues (org_id, name, relationship, address) VALUES (pg_temp.o(2), ' ac hall ', 'partner', '{"city":"brooklyn"}')
  RETURNING id INTO v;
  ASSERT (SELECT listed_venue_id FROM public.exos_venues WHERE id = v) IS NULL, 'OA6 a same-named record doesn''t auto-link';
  -- Suggestions: both candidates, nothing decided.
  sg := public.exos_venue_link_suggestions(v);
  ASSERT jsonb_array_length(sg->'suggestions') = 2 AND sg->'listed_venue_id' = 'null'::jsonb
     AND (SELECT bool_and(NOT (x->>'verified')::boolean) FROM jsonb_array_elements(sg->'suggestions') x), 'OA6 ambiguous suggestions ' || sg::text;
  s := pg_temp.st(format($q$SELECT public.exos_venue_link_suggestions(%L)$q$, pg_temp.u('e1')));
  ASSERT s LIKE '42501%', 'OA6 suggestions for another org''s venue: ' || s;
  s := pg_temp.st(format($q$UPDATE public.exos_venues SET verified = true WHERE id = %L$q$, v));
  ASSERT s LIKE '42501%', 'OA6 a promoter can''t verify: ' || s;
  -- The promoter links explicitly: now it is gated, and the link stays.
  s := pg_temp.st(format($q$SELECT public.exos_venue_link(%L, %L)$q$, v, v0));
  ASSERT s LIKE '22023%', 'OA6 link to own venue: ' || s;
  sg := public.exos_venue_link(v, pg_temp.u('e1')::uuid);
  ASSERT (SELECT listed_venue_id FROM public.exos_venues WHERE id = v) = pg_temp.u('e1')::uuid
     AND sg->>'listed_venue_id' = pg_temp.u('e1'), 'OA6 explicit link';
  s := pg_temp.st(format($q$SELECT public.exos_hold_create('ac000000-0000-0000-0000-000000000002', jsonb_build_object('title', 'Mine',
         'positions', jsonb_build_array(jsonb_build_object('date', %L, 'venue_id', %L))))$q$, pg_temp.day(30), v));
  ASSERT s LIKE '22023 venue_approval_required%ac000000-0000-0000-0000-0000000000e1%', 'OA6 hold at the linked copy: ' || s;
  s := pg_temp.st(format($q$UPDATE public.exos_events SET exos_venue_id = %L WHERE id = %L$q$, v, ev));
  ASSERT s LIKE '22023 venue_approval_required%', 'OA6 event at the linked copy: ' || s;
  s := pg_temp.st(format($q$UPDATE public.exos_venues SET listed_venue_id = NULL WHERE id = %L$q$, v));
  ASSERT s LIKE '42501%', 'OA6 the link stays: ' || s;
  s := pg_temp.st(format($q$SELECT public.exos_venue_link(%L, %L)$q$, v, sq));
  ASSERT s LIKE '42501%', 'OA6 relink: ' || s;
  -- Its own other room works as before.
  INSERT INTO public.exos_venues (org_id, name, relationship) VALUES (pg_temp.o(2), 'AC Hall', 'rented') RETURNING id INTO v2;
  PERFORM public.exos_hold_create(pg_temp.o(2), jsonb_build_object('title', 'Own room',
    'positions', jsonb_build_array(jsonb_build_object('date', pg_temp.day(30), 'venue_id', v2))));
  UPDATE public.exos_events SET exos_venue_id = v2 WHERE id = ev;
  INSERT INTO ac VALUES ('copy', v::text), ('squat', sq::text);
  PERFORM pg_temp.act(NULL);
END $$;
RESET ROLE;
-- Exos staff (here the service role) verify the real hall: it leads the suggestions.
UPDATE public.exos_venues SET verified = true WHERE id = 'ac000000-0000-0000-0000-0000000000e1';
SET LOCAL ROLE service_role;
DO $$
DECLARE sg jsonb;
BEGIN
  sg := public._exos_venue_link_suggestions(pg_temp.o(2), pg_temp.v('copy')::uuid);
  ASSERT sg->'suggestions'->0->>'id' = pg_temp.u('e1') AND (sg->'suggestions'->0->>'verified')::boolean
     AND NOT (sg->'suggestions'->1->>'verified')::boolean, 'OA6 verified first ' || sg::text;
END $$;
RESET ROLE;
-- The API path (a template-made event) answers the same.
SET LOCAL ROLE service_role;
DO $$
DECLARE s text;
BEGIN
  s := pg_temp.st(format($q$SELECT public._exos_hold_create('ac000000-0000-0000-0000-000000000002', NULL, 'api',
         'ac000000-0000-0000-0000-0000000000f4', jsonb_build_object('title', 'API',
         'positions', jsonb_build_array(jsonb_build_object('date', %L, 'venue_id', 'ac000000-0000-0000-0000-0000000000e1'))))$q$, pg_temp.day(31)));
  ASSERT s LIKE '22023 venue_approval_required%', 'OA6 API hold: ' || s;
  RAISE NOTICE 'OK  OA6 a promoter is blocked at a venue another org runs';
END $$;
RESET ROLE;

-- OA7 -------------------------------------------------------------------------
SET LOCAL ROLE authenticated;
DO $$
DECLARE v jsonb; s text; n int;
BEGIN
  PERFORM pg_temp.act(pg_temp.u('b1'));
  v := public.exos_venue_directory(pg_temp.o(2), 'brook');
  -- Both "owned" halls are listed; only the real one is verified, and nothing private shows.
  ASSERT jsonb_array_length(v) = 2
     AND (SELECT count(*) FROM jsonb_array_elements(v) x WHERE x->>'id' = pg_temp.u('e1') AND (x->>'verified')::boolean
            AND x->'rooms'->0->>'name' = 'Main Room') = 1
     AND (SELECT count(*) FROM jsonb_array_elements(v) x WHERE x->>'id' = pg_temp.v('squat') AND NOT (x->>'verified')::boolean) = 1
     AND NOT (v->0 ? 'contact_email'), 'OA7 directory ' || v::text;
  s := pg_temp.st($q$SELECT public.exos_venue_directory('ac000000-0000-0000-0000-000000000001', 'brook')$q$);
  ASSERT s LIKE '42501%', 'OA7 directory as another org: ' || s;
  s := pg_temp.st($q$SELECT public.exos_venue_directory('ac000000-0000-0000-0000-000000000002', 'b')$q$);
  ASSERT s LIKE '22023%', 'OA7 directory needs 2 characters: ' || s;
  -- Through the linked copy: the request goes to the hall it stands for.
  v := public.exos_venue_request_create(pg_temp.o(2), jsonb_build_object('venue_id', pg_temp.v('copy'), 'room_id', pg_temp.u('e2'),
         'date', pg_temp.day(40), 'start_time', '21:00', 'title', 'Promoter Night', 'message', 'Two DJs.', 'expected_draw', 250));
  ASSERT v->>'status' = 'pending' AND v->'venue'->>'id' = pg_temp.u('e1') AND v->'venue_org'->>'name' = 'AC Venue Co'
     AND v->'requester_org'->>'name' = 'AC Promoter', 'OA7 request ' || v::text;
  INSERT INTO ac VALUES ('req', v->>'id');
  s := pg_temp.st(format($q$SELECT public.exos_venue_request_create('ac000000-0000-0000-0000-000000000002',
         jsonb_build_object('venue_id', 'ac000000-0000-0000-0000-0000000000e1', 'room_id', 'ac000000-0000-0000-0000-0000000000e2',
                            'date', %L, 'title', 'Again'))$q$, pg_temp.day(40)));
  ASSERT s LIKE '23505%', 'OA7 one pending per date and room: ' || s;
  s := pg_temp.st(format($q$SELECT public.exos_venue_request_create('ac000000-0000-0000-0000-000000000002',
         jsonb_build_object('venue_id', 'ac000000-0000-0000-0000-0000000000e1', 'date', %L, 'title', 'Past'))$q$, pg_temp.day(-3)));
  ASSERT s LIKE '22023%', 'OA7 a past date: ' || s;
  -- The promoter can't approve its own request.
  s := pg_temp.st(format($q$SELECT public.exos_venue_request_decide(%L, 'approve', '{}')$q$, pg_temp.v('req')));
  ASSERT s LIKE '42501%', 'OA7 promoter approves: ' || s;
  -- Venue content staff see it; can't decide.
  PERFORM pg_temp.act(pg_temp.u('a4'));
  SELECT count(*) INTO n FROM public.exos_venue_requests WHERE id = pg_temp.v('req')::uuid;
  ASSERT n = 1, 'OA7 venue content sees the request';
  s := pg_temp.st(format($q$SELECT public.exos_venue_request_decide(%L, 'approve', '{}')$q$, pg_temp.v('req')));
  ASSERT s LIKE '42501%', 'OA7 content approves: ' || s;
  -- The venue manager approves as an event, giving events:write and tickets:read.
  PERFORM pg_temp.act(pg_temp.u('a2'));
  s := pg_temp.st(format($q$SELECT public.exos_venue_request_decide(%L, 'approve', '{"scopes":["refunds:write"]}')$q$, pg_temp.v('req')));
  ASSERT s LIKE '22023%', 'OA7 refunds can''t be granted: ' || s;
  v := public.exos_venue_request_decide(pg_temp.v('req')::uuid, 'approve',
         '{"create":"event","scopes":["events:write","tickets:read"],"capacity":250}');
  ASSERT v->>'status' = 'approved' AND v->>'outcome' = 'event' AND v->>'event_id' IS NOT NULL
     AND v->'grant'->'scopes' = '["events:read","events:write","tickets:read"]'::jsonb, 'OA7 approved ' || v::text;
  INSERT INTO ac VALUES ('ev', v->>'event_id'), ('grant', v->'grant'->>'id');
  ASSERT (SELECT org_id = pg_temp.o(1) AND exos_venue_id = pg_temp.u('e1')::uuid AND exos_room_id = pg_temp.u('e2')::uuid
                 AND status = 'draft' AND total_tickets = 250
            FROM public.exos_events WHERE id = (v->>'event_id')::uuid), 'OA7 the event is the venue org''s, at the hall';
  ASSERT (SELECT h.status = 'converted' FROM public.exos_holds h WHERE h.id = (v->>'hold_id')::uuid), 'OA7 hold converted';
  s := pg_temp.st(format($q$SELECT public.exos_venue_request_decide(%L, 'decline', '{}')$q$, pg_temp.v('req')));
  ASSERT s LIKE '55000%', 'OA7 decided once: ' || s;
  PERFORM pg_temp.act(NULL);
END $$;
RESET ROLE;
SET LOCAL ROLE service_role;
DO $$
DECLARE v jsonb; s text; ev uuid := pg_temp.v('ev')::uuid; tier uuid;
BEGIN
  v := public._exos_cohost_events(pg_temp.o(2));
  ASSERT jsonb_array_length(v) = 1 AND v->0->>'id' = ev::text AND v->0->'host_org'->>'name' = 'AC Venue Co', 'OA7 list ' || v::text;
  v := public._exos_cohost_event(pg_temp.o(2), ev);
  ASSERT v->>'name' = 'Promoter Night' AND jsonb_array_length(v->'ticket_types') = 1, 'OA7 read ' || v::text;
  -- Edits act as the promoter key's creator (an owner / manager of the promoter now) and are logged.
  s := pg_temp.st(format($q$SELECT public._exos_cohost_event_update('ac000000-0000-0000-0000-000000000002', %L, '{"name":"x"}', NULL)$q$, ev));
  ASSERT s LIKE '42501%', 'OA7 no key, no edit: ' || s;
  s := pg_temp.st(format($q$SELECT public._exos_cohost_event_update('ac000000-0000-0000-0000-000000000002', %L, '{"name":"x"}', 'ac000000-0000-0000-0000-0000000000f5')$q$, ev));
  ASSERT s LIKE '42501%', 'OA7 another org''s key: ' || s;
  v := public._exos_cohost_event_update(pg_temp.o(2), ev, '{"name":"Promoter Night Live","description":"Two DJs, all night."}',
         pg_temp.u('f4')::uuid);
  ASSERT (SELECT actor_uid = pg_temp.u('b1')::uuid AND api_key_id = pg_temp.u('f4')::uuid AND org_id = pg_temp.o(1)
                 AND fields = ARRAY['description','name']
            FROM public.exos_cohost_event_edits WHERE event_id = ev), 'OA7 edit logged with its actor';
  ASSERT v->>'name' = 'Promoter Night Live' AND v->>'description' = 'Two DJs, all night.', 'OA7 update ' || v::text;
  s := pg_temp.st(format($q$SELECT public._exos_cohost_event_update('ac000000-0000-0000-0000-000000000002', %L, '{"total_tickets":9999}', 'ac000000-0000-0000-0000-0000000000f4')$q$, ev));
  ASSERT s LIKE '22023%', 'OA7 capacity is the venue''s: ' || s;
  s := pg_temp.st(format($q$SELECT public._exos_cohost_event_update('ac000000-0000-0000-0000-000000000002', %L, '{"image_url":"http://x"}', 'ac000000-0000-0000-0000-0000000000f4')$q$, ev));
  ASSERT s LIKE '22023%', 'OA7 https only: ' || s;
END $$;
RESET ROLE;
DO $$
DECLARE ev uuid := pg_temp.v('ev')::uuid; tier uuid;
BEGIN
  SELECT id INTO tier FROM public.exos_ticket_tiers WHERE event_id = ev;
  INSERT INTO public.exos_tickets (event_id, org_id, tier_id, tier_name, status, barcode_secret, price_paid, order_ref)
  VALUES (ev, pg_temp.o(1), tier, 'GA', 'active', 'ac-s1', 20, 'ac-o1'), (ev, pg_temp.o(1), tier, 'GA', 'used', 'ac-s2', 20, 'ac-o2');
END $$;
SET LOCAL ROLE service_role;
DO $$
DECLARE v jsonb; ev uuid := pg_temp.v('ev')::uuid;
BEGIN
  -- The key has finance:read, the grant doesn't: no money.
  v := public._exos_cohost_event_sales(pg_temp.o(2), ev, ARRAY['tickets:read', 'finance:read']);
  ASSERT v->'ticket_types'->0->>'sold' = '2' AND v->'ticket_types'->0->>'checked_in' = '1'
     AND NOT (v->'ticket_types'->0 ? 'gross_cents'), 'OA7 sales without money ' || v::text;
  RAISE NOTICE 'OK  OA7 request -> approve -> the event-scoped grant works';
END $$;
RESET ROLE;

-- OA8 -------------------------------------------------------------------------
SET LOCAL ROLE authenticated;
DO $$
DECLARE v jsonb; s text;
BEGIN
  PERFORM pg_temp.act(pg_temp.u('a1'));
  s := pg_temp.st(format($q$SELECT public.exos_partner_grant_set(%L, ARRAY['refunds:write'])$q$, pg_temp.v('grant')));
  ASSERT s LIKE '22023%', 'OA8 no refunds: ' || s;
  v := public.exos_partner_grant_set(pg_temp.v('grant')::uuid, ARRAY['tickets:read', 'finance:read']);
  ASSERT v->'scopes' = '["tickets:read","finance:read"]'::jsonb, 'OA8 narrowed ' || v::text;
  PERFORM pg_temp.act(pg_temp.u('a4'));
  s := pg_temp.st(format($q$SELECT public.exos_partner_grant_revoke(%L)$q$, pg_temp.v('grant')));
  ASSERT s LIKE '42501%', 'OA8 content revokes: ' || s;
  PERFORM pg_temp.act(NULL);
END $$;
RESET ROLE;
SET LOCAL ROLE service_role;
DO $$
DECLARE v jsonb; s text; ev uuid := pg_temp.v('ev')::uuid;
BEGIN
  s := pg_temp.st(format($q$SELECT public._exos_cohost_event('ac000000-0000-0000-0000-000000000002', %L)$q$, ev));
  ASSERT s LIKE '42501 grant_scope_required%', 'OA8 events:read taken away: ' || s;
  -- The grant has finance:read now; money needs it in the key too.
  v := public._exos_cohost_event_sales(pg_temp.o(2), ev, ARRAY['tickets:read']);
  ASSERT NOT (v->'ticket_types'->0 ? 'gross_cents'), 'OA8 grant only: no money ' || v::text;
  v := public._exos_cohost_event_sales(pg_temp.o(2), ev, NULL);
  ASSERT NOT (v->'ticket_types'->0 ? 'gross_cents'), 'OA8 no credential scopes: no money ' || v::text;
  v := public._exos_cohost_event_sales(pg_temp.o(2), ev, ARRAY['tickets:read', 'finance:read']);
  ASSERT (v->'ticket_types'->0->>'gross_cents')::int = 4000, 'OA8 both: gross ' || v::text;
  v := public._exos_cohost_event_sales(pg_temp.o(2), ev, ARRAY['tickets:read', 'finance:write']);
  ASSERT (v->'ticket_types'->0->>'gross_cents')::int = 4000, 'OA8 finance:write covers finance:read ' || v::text;
END $$;
RESET ROLE;
SET LOCAL ROLE authenticated;
SELECT pg_temp.act('ac000000-0000-0000-0000-0000000000a2');
SELECT public.exos_partner_grant_revoke(pg_temp.v('grant')::uuid);
SELECT pg_temp.act(NULL);
RESET ROLE;
SET LOCAL ROLE service_role;
DO $$
DECLARE s text; ev uuid := pg_temp.v('ev')::uuid;
BEGIN
  s := pg_temp.st(format($q$SELECT public._exos_cohost_event_sales('ac000000-0000-0000-0000-000000000002', %L, ARRAY['tickets:read'])$q$, ev));
  ASSERT s LIKE 'P0002%', 'OA8 a revoked grant stops it: ' || s;
  s := pg_temp.st(format($q$SELECT public._exos_cohost_event_update('ac000000-0000-0000-0000-000000000002', %L, '{"name":"x"}', 'ac000000-0000-0000-0000-0000000000f4')$q$, ev));
  ASSERT s LIKE 'P0002%', 'OA8 revoked: no writes: ' || s;
  ASSERT jsonb_array_length(public._exos_cohost_events(pg_temp.o(2))) = 0, 'OA8 gone from the list';
  s := pg_temp.st(format($q$SELECT public._exos_partner_grant_revoke('ac000000-0000-0000-0000-000000000001', NULL, %L)$q$, pg_temp.v('grant')));
  ASSERT s LIKE 'P0002%', 'OA8 revoked once: ' || s;
END $$;
RESET ROLE;
-- Approve as a hold; the grant arrives when the venue converts it later.
-- Decline and withdraw.
SET LOCAL ROLE service_role;
DO $$
DECLARE v jsonb; h jsonb; r2 uuid; r3 uuid; r4 uuid; s text; ev uuid;
BEGIN
  v := public._exos_venue_request_create(pg_temp.o(2), pg_temp.u('b1')::uuid, 'api', pg_temp.u('f4')::uuid,
         jsonb_build_object('venue_id', pg_temp.u('e1'), 'date', pg_temp.day(50), 'title', 'Hold me', 'idempotency_key', 'ac-idem-0001'));
  r2 := (v->>'id')::uuid;
  v := public._exos_venue_request_create(pg_temp.o(2), pg_temp.u('b1')::uuid, 'api', pg_temp.u('f4')::uuid,
         jsonb_build_object('venue_id', pg_temp.u('e1'), 'date', pg_temp.day(50), 'title', 'Hold me', 'idempotency_key', 'ac-idem-0001'));
  ASSERT (v->>'id')::uuid = r2 AND (v->>'idempotent_replay')::boolean, 'OA8 idempotent create';
  v := public._exos_venue_request_decide(pg_temp.o(1), pg_temp.u('a1')::uuid, 'api', pg_temp.u('f2')::uuid, r2, 'approve',
         '{"scopes":["events:read"]}');
  ASSERT v->>'outcome' = 'hold' AND v->>'event_id' IS NULL AND v->'grant' = 'null'::jsonb, 'OA8 approved as a hold ' || v::text;
  h := public._exos_hold_convert(pg_temp.o(1), pg_temp.u('a1')::uuid, 'dashboard', NULL, (v->>'hold_id')::uuid,
         jsonb_build_object('date', pg_temp.day(50)));
  ev := (h->>'event_id')::uuid;
  ASSERT public._exos_partner_grant_scopes(ev, pg_temp.o(2)) = ARRAY['events:read'], 'OA8 grant on a later convert';
  ASSERT (public._exos_venue_request_get(pg_temp.o(2), r2)->>'event_id')::uuid = ev, 'OA8 request linked to the event';
  -- Decline.
  v := public._exos_venue_request_create(pg_temp.o(2), NULL, 'api', pg_temp.u('f4')::uuid,
         jsonb_build_object('venue_id', pg_temp.u('e1'), 'date', pg_temp.day(51), 'title', 'No'));
  r3 := (v->>'id')::uuid;
  v := public._exos_venue_request_decide(pg_temp.o(1), NULL, 'api', NULL, r3, 'decline', '{"reason":"Booked."}');
  ASSERT v->>'status' = 'declined' AND v->>'decline_reason' = 'Booked.', 'OA8 declined';
  -- Withdraw (the requester only; once).
  v := public._exos_venue_request_create(pg_temp.o(2), NULL, 'api', NULL,
         jsonb_build_object('venue_id', pg_temp.u('e1'), 'date', pg_temp.day(52), 'title', 'Maybe'));
  r4 := (v->>'id')::uuid;
  s := pg_temp.st(format($q$SELECT public._exos_venue_request_withdraw('ac000000-0000-0000-0000-000000000001', %L, NULL)$q$, r4));
  ASSERT s LIKE 'P0002%', 'OA8 the venue can''t withdraw it: ' || s;
  ASSERT public._exos_venue_request_withdraw(pg_temp.o(2), r4, pg_temp.u('b1')::uuid)->>'status' = 'withdrawn', 'OA8 withdrawn';
  ASSERT (SELECT decided_by FROM public.exos_venue_requests WHERE id = r4) = pg_temp.u('b1')::uuid, 'OA8 who withdrew';
  s := pg_temp.st(format($q$SELECT public._exos_venue_request_decide('ac000000-0000-0000-0000-000000000001', NULL, 'api', NULL, %L, 'approve', '{}')$q$, r4));
  ASSERT s LIKE '55000%', 'OA8 a withdrawn request can''t be approved: ' || s;
  -- A venue that takes no requests; the venue's own hall.
  UPDATE public.exos_venues SET accepts_requests = false WHERE id = pg_temp.u('e1')::uuid;
  s := pg_temp.st(format($q$SELECT public._exos_venue_request_create('ac000000-0000-0000-0000-000000000002', NULL, 'api', NULL,
         jsonb_build_object('venue_id', 'ac000000-0000-0000-0000-0000000000e1', 'date', %L, 'title', 'Closed'))$q$, pg_temp.day(53)));
  ASSERT s LIKE '55000%', 'OA8 closed to requests: ' || s;
  UPDATE public.exos_venues SET accepts_requests = true WHERE id = pg_temp.u('e1')::uuid;
  s := pg_temp.st(format($q$SELECT public._exos_venue_request_create('ac000000-0000-0000-0000-000000000001', NULL, 'api', NULL,
         jsonb_build_object('venue_id', 'ac000000-0000-0000-0000-0000000000e1', 'date', %L, 'title', 'Self'))$q$, pg_temp.day(53)));
  ASSERT s LIKE 'P0002%', 'OA8 no request to yourself: ' || s;
  -- The API actor check.
  s := pg_temp.st($q$SELECT public._exos_api_key_actor('ac000000-0000-0000-0000-000000000001', 'ac000000-0000-0000-0000-0000000000f4', ARRAY['owner'])$q$);
  ASSERT s LIKE '42501%', 'OA8 another org''s key: ' || s;
  ASSERT public._exos_api_key_actor(pg_temp.o(1), pg_temp.u('f1')::uuid, ARRAY['owner', 'manager']) = pg_temp.u('a2')::uuid,
    'OA8 the key''s creator';
  RAISE NOTICE 'OK  OA8 grant changes, revoke, hold-then-convert, decline, withdraw';
END $$;
RESET ROLE;

-- OA9 -------------------------------------------------------------------------
SET LOCAL ROLE authenticated;
DO $$
DECLARE n int; s text;
BEGIN
  PERFORM pg_temp.act(pg_temp.u('c1'));
  SELECT count(*) INTO n FROM public.exos_venue_requests;
  ASSERT n = 0, 'OA9 another org sees no requests';
  SELECT count(*) INTO n FROM public.exos_event_partner_grants;
  ASSERT n = 0, 'OA9 another org sees no grants';
  s := pg_temp.st(format($q$SELECT public.exos_venue_request_decide(%L, 'decline', '{}')$q$, pg_temp.v('req')));
  ASSERT s LIKE '42501%', 'OA9 another org decides: ' || s;
  s := pg_temp.st($q$SELECT public.exos_venue_requests('ac000000-0000-0000-0000-000000000001', 'received')$q$);
  ASSERT s LIKE '42501%', 'OA9 another org lists the venue''s: ' || s;
  ASSERT (public.exos_venue_requests(pg_temp.o(3), 'received')->>'total')::int = 0, 'OA9 its own list is empty';
  s := pg_temp.st($q$SELECT public.exos_cohost_events('ac000000-0000-0000-0000-000000000002')$q$);
  ASSERT s LIKE '42501%', 'OA9 another org reads the promoter''s co-hosted list: ' || s;
  -- The promoter manager sees its own sent list; the promoter can't see the venue's received list.
  PERFORM pg_temp.act(pg_temp.u('b2'));
  ASSERT (public.exos_venue_requests(pg_temp.o(2), 'sent')->>'total')::int = 4, 'OA9 sent list';
  ASSERT (public.exos_venue_requests(pg_temp.o(2), 'received')->>'total')::int = 0, 'OA9 promoter received nothing';
  PERFORM pg_temp.act(NULL);
END $$;
RESET ROLE;
SET LOCAL ROLE service_role;
DO $$
DECLARE s text;
BEGIN
  s := pg_temp.st(format($q$SELECT public._exos_venue_request_get('ac000000-0000-0000-0000-000000000003', %L)$q$, pg_temp.v('req')));
  ASSERT s LIKE 'P0002%', 'OA9 get: ' || s;
  s := pg_temp.st(format($q$SELECT public._exos_cohost_event('ac000000-0000-0000-0000-000000000003', %L)$q$, pg_temp.v('ev')));
  ASSERT s LIKE 'P0002%', 'OA9 another org on the event: ' || s;
  s := pg_temp.st(format($q$SELECT public._exos_partner_grant_set('ac000000-0000-0000-0000-000000000003', NULL, %L, '["events:read"]')$q$, pg_temp.v('grant')));
  ASSERT s LIKE 'P0002%', 'OA9 another org edits the grant: ' || s;
  s := pg_temp.st(format($q$SELECT public._exos_venue_request_decide('ac000000-0000-0000-0000-000000000002', NULL, 'api', NULL, %L, 'approve', '{}')$q$, pg_temp.v('req')));
  ASSERT s LIKE 'P0002%', 'OA9 the requester decides via the API: ' || s;
  RAISE NOTICE 'OK  OA9 cross-org isolation';
END $$;
RESET ROLE;

-- OA10 ------------------------------------------------------------------------
-- A published show of the venue org on sale through a partner, with a
-- running member presale on the Presale type.
DO $$
DECLARE v jsonb;
BEGIN
  INSERT INTO public.exos_events (id, org_id, name, slug, status, starts_at, timezone, total_tickets, tickets_sold, currency, created_by)
  VALUES (pg_temp.u('d0')::uuid, pg_temp.o(1), 'AC Presale Show', 'ac-presale', 'published', now() + interval '5 days',
          'America/New_York', 0, 0, 'usd', pg_temp.u('a1')::uuid);
  INSERT INTO public.exos_ticket_tiers (id, event_id, name, price, capacity, sold, visibility, sort_order) VALUES
    (pg_temp.u('d1')::uuid, pg_temp.u('d0')::uuid, 'Presale', 30, 10, 0, 'public', 1);
  INSERT INTO public.exos_tier_distribution (tier_id, event_id, org_id, enabled)
  VALUES (pg_temp.u('d1')::uuid, pg_temp.u('d0')::uuid, pg_temp.o(1), true);
  v := public._exos_dist_partner_create(pg_temp.o(1), 'StubHub', 'stubhub', ARRAY['inventory'], pg_temp.u('a1')::uuid, NULL);
  INSERT INTO ac VALUES ('partner', v->>'id');
END $$;
SET LOCAL ROLE authenticated;
DO $$
DECLARE v jsonb; s text;
BEGIN
  PERFORM pg_temp.act(pg_temp.u('a1'));
  INSERT INTO public.exos_membership_products (id, org_id, name, price_cents, billing, discount_percent, presale,
                                               free_tickets_per_period, guest_allowance, household_seats)
  VALUES (pg_temp.u('d2')::uuid, pg_temp.o(1), 'AC Member', 1000, 'month', 0, true, 0, 0, 0);
  PERFORM public.exos_set_member_presale(pg_temp.u('d0')::uuid, NULL, now() + interval '1 day',
    ARRAY[pg_temp.u('d1')::uuid], '{}');
  v := public.exos_partner_presale_get(pg_temp.o(1), pg_temp.u('d0')::uuid);
  ASSERT v->>'org_mode' = 'block' AND v->'event_mode' = 'null'::jsonb AND v->>'effective' = 'block', 'OA10 default block ' || v::text;
  -- Who may set it.
  PERFORM pg_temp.act(pg_temp.u('a2'));
  s := pg_temp.st($q$SELECT public.exos_partner_presale_set('ac000000-0000-0000-0000-000000000001', 'allow')$q$);
  ASSERT s LIKE '42501%', 'OA10 manager sets the org mode: ' || s;
  PERFORM pg_temp.act(pg_temp.u('a3'));
  ASSERT public.exos_partner_presale_get(pg_temp.o(1))->>'org_mode' = 'block', 'OA10 finance reads';
  s := pg_temp.st(format($q$SELECT public.exos_event_partner_presale_set(%L, 'allow')$q$, pg_temp.u('d0')));
  ASSERT s LIKE '42501%', 'OA10 finance sets the event: ' || s;
  PERFORM pg_temp.act(pg_temp.u('c1'));
  s := pg_temp.st($q$SELECT public.exos_partner_presale_get('ac000000-0000-0000-0000-000000000001')$q$);
  ASSERT s LIKE '42501%', 'OA10 another org reads: ' || s;
  PERFORM pg_temp.act(pg_temp.u('a1'));
  s := pg_temp.st($q$SELECT public.exos_partner_presale_set('ac000000-0000-0000-0000-000000000001', 'sometimes')$q$);
  ASSERT s LIKE '22023%', 'OA10 bad mode: ' || s;
  PERFORM pg_temp.act(NULL);
END $$;
RESET ROLE;
CREATE FUNCTION pg_temp.reserve() RETURNS text LANGUAGE plpgsql AS $$
DECLARE o jsonb;
BEGIN
  o := public._exos_partner_reserve('ac000000-0000-0000-0000-000000000001', 'ac000000-0000-0000-0000-0000000000d0',
         (SELECT v::uuid FROM ac WHERE k = 'partner'), NULL,
         jsonb_build_array(jsonb_build_object('ticket_type_id', 'ac000000-0000-0000-0000-0000000000d1', 'quantity', 1)), '{}');
  PERFORM public._exos_partner_reservation_cancel('ac000000-0000-0000-0000-000000000001', (SELECT v::uuid FROM ac WHERE k = 'partner'),
                                                  o->>'token');
  RETURN 'ok';
EXCEPTION WHEN OTHERS THEN RETURN SQLSTATE;
END $$;
DO $$
DECLARE s text; m jsonb;
BEGIN
  ASSERT pg_temp.reserve() = 'EX422', 'OA10 block: a partner can''t sell the presale';
  PERFORM set_config('app.uid', pg_temp.u('a1'), true);
  PERFORM public.exos_partner_presale_set(pg_temp.o(1), 'allow');
  PERFORM set_config('app.uid', '', true);
  ASSERT pg_temp.reserve() = 'ok', 'OA10 allow: the partner sells during the presale';
  -- The per-buyer member gate on Exos's own checkout still applies.
  SET LOCAL ROLE service_role;
  m := public.exos_member_checkout(pg_temp.u('d0')::uuid, pg_temp.u('d1')::uuid, pg_temp.u('c1')::uuid);
  RESET ROLE;
  ASSERT (m->>'presale_blocked')::boolean, 'OA10 a non-member buyer is still refused at Exos checkout ' || m::text;
  -- An event override back to block, then inherit again.
  PERFORM set_config('app.uid', pg_temp.u('a2'), true);
  PERFORM public.exos_event_partner_presale_set(pg_temp.u('d0')::uuid, 'block');
  PERFORM set_config('app.uid', '', true);
  ASSERT pg_temp.reserve() = 'EX422', 'OA10 event override block';
  PERFORM set_config('app.uid', pg_temp.u('a2'), true);
  m := public.exos_event_partner_presale_set(pg_temp.u('d0')::uuid, 'inherit');
  PERFORM set_config('app.uid', '', true);
  ASSERT m->'event_mode' = 'null'::jsonb AND m->>'effective' = 'allow', 'OA10 inherit ' || m::text;
  ASSERT pg_temp.reserve() = 'ok', 'OA10 back to the org''s allow';
  -- Org block, event allow.
  PERFORM set_config('app.uid', pg_temp.u('a1'), true);
  PERFORM public.exos_partner_presale_set(pg_temp.o(1), 'block');
  PERFORM public.exos_event_partner_presale_set(pg_temp.u('d0')::uuid, 'allow');
  PERFORM set_config('app.uid', '', true);
  ASSERT pg_temp.reserve() = 'ok', 'OA10 event allow over org block';
  -- Another org's event can't be overridden from here.
  SET LOCAL ROLE service_role;
  s := pg_temp.st(format($q$SELECT public._exos_partner_presale_set('ac000000-0000-0000-0000-000000000003', NULL, %L, 'allow')$q$, pg_temp.u('d0')));
  RESET ROLE;
  ASSERT s LIKE 'P0002%', 'OA10 cross-org override: ' || s;
  RAISE NOTICE 'OK  OA10 partner presale block vs allow';
END $$;

\echo 'test_org_access: all passed'
ROLLBACK;
