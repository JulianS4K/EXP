-- ============================================================================
-- BYO credentials (mig 20261016090000) and ticket backends (20261016100000).
--   I1 save: owner / manager only; secret to Vault, hint only; list never
--      shows a secret; a token in a settings field is refused
--   I2 save again without a secret keeps it; service role reads it; mark
--   I3 remove deletes the Vault secret
--   B1 set backend: owner only, https link required, refused after Exos sales
--   B2 another backend: cart holds and free claims refused; the public view
--      shows the link; back to exos sells again
--   B3 link pretix: needs the integration; guest list made; claim + apply
--      (add, update, void, restore, bad rows); lease lost refused
--   B4 status for door staff, never a secret; unlink keeps the guests
-- Self-contained ids 5e…; runs after the full run_p0.sh chain.
-- ============================================================================
\set ON_ERROR_STOP on
BEGIN;

INSERT INTO auth.users(id,email,email_confirmed_at) VALUES
  ('5e000000-0000-0000-0000-0000000000a1','inown@x.com',now()),
  ('5e000000-0000-0000-0000-0000000000a2','inmgr@x.com',now()),
  ('5e000000-0000-0000-0000-0000000000a3','infin@x.com',now()),
  ('5e000000-0000-0000-0000-0000000000a4','inscan@x.com',now()),
  ('5e000000-0000-0000-0000-0000000000b1','infan@x.com',now());
INSERT INTO public.exos_orgs(id,name,slug,owner_uid) VALUES
  ('5e000000-0000-0000-0000-000000000001','IN Org','in-org-stub','5e000000-0000-0000-0000-0000000000a1');
INSERT INTO public.exos_org_memberships(org_id,user_id,role) VALUES
  ('5e000000-0000-0000-0000-000000000001','5e000000-0000-0000-0000-0000000000a1','owner'),
  ('5e000000-0000-0000-0000-000000000001','5e000000-0000-0000-0000-0000000000a2','manager'),
  ('5e000000-0000-0000-0000-000000000001','5e000000-0000-0000-0000-0000000000a3','finance'),
  ('5e000000-0000-0000-0000-000000000001','5e000000-0000-0000-0000-0000000000a4','scanner');
INSERT INTO public.exos_events(id,org_id,name,slug,status,starts_at,timezone,total_tickets,tickets_sold,created_by) VALUES
  ('5e000000-0000-0000-0000-0000000000e1','5e000000-0000-0000-0000-000000000001','IN One','in-one','published',now() + interval '1 day','America/New_York',100,0,'5e000000-0000-0000-0000-0000000000a1'),
  ('5e000000-0000-0000-0000-0000000000e2','5e000000-0000-0000-0000-000000000001','IN Two','in-two','published',now() + interval '9 days','America/New_York',100,3,'5e000000-0000-0000-0000-0000000000a1');
INSERT INTO public.exos_ticket_tiers(id,event_id,name,price,capacity,sold,visibility) VALUES
  ('5e000000-0000-0000-0000-0000000000d1','5e000000-0000-0000-0000-0000000000e1','GA',30,100,0,'public'),
  ('5e000000-0000-0000-0000-0000000000d0','5e000000-0000-0000-0000-0000000000e1','RSVP',0,100,0,'public');

CREATE FUNCTION pg_temp.act(p_uid text) RETURNS void LANGUAGE sql AS $$
  SELECT set_config('app.uid', coalesce(p_uid, ''), true), set_config('app.jwt', '', true);
$$;
GRANT EXECUTE ON FUNCTION pg_temp.act(text) TO anon, authenticated;
CREATE FUNCTION pg_temp.u(p text) RETURNS uuid LANGUAGE sql IMMUTABLE AS $$ SELECT ('5e000000-0000-0000-0000-' || p)::uuid $$;
GRANT EXECUTE ON FUNCTION pg_temp.u(text) TO anon, authenticated;
CREATE FUNCTION pg_temp.refused(p_sql text, p_like text) RETURNS boolean LANGUAGE plpgsql AS $$
BEGIN
  EXECUTE p_sql;
  RETURN false;
EXCEPTION WHEN others THEN
  IF SQLERRM NOT LIKE '%' || p_like || '%' THEN
    RAISE EXCEPTION 'expected "%", got % "%"', p_like, SQLSTATE, SQLERRM;
  END IF;
  RETURN true;
END $$;
GRANT EXECUTE ON FUNCTION pg_temp.refused(text, text) TO anon, authenticated;

-- I1 / I2 -----------------------------------------------------------------
SET LOCAL ROLE authenticated;
SELECT pg_temp.act('5e000000-0000-0000-0000-0000000000a3');
SELECT set_config('in.fin', pg_temp.refused($$SELECT public.exos_save_integration(pg_temp.u('000000000001'), 'pretix', '{}', 'x')$$, 'owner or manager only')::text, true);
SELECT set_config('in.finlist', (SELECT count(*)::text FROM public.exos_list_integrations(pg_temp.u('000000000001'))), true);
SELECT pg_temp.act('5e000000-0000-0000-0000-0000000000a2');
SELECT set_config('in.badkey', pg_temp.refused($$SELECT public.exos_save_integration(pg_temp.u('000000000001'), 'pretix', '{"api_token":"abc"}', NULL)$$, 'plain values')::text, true);
SELECT set_config('in.badprov', pg_temp.refused($$SELECT public.exos_save_integration(pg_temp.u('000000000001'), 'nope', '{}', NULL)$$, 'unknown provider')::text, true);
SELECT set_config('in.s1', public.exos_save_integration(pg_temp.u('000000000001'), 'pretix',
  '{"base_url":"https://pretix.eu","organizer":"in-org"}', 'tok_abcdefgh1234', 'Our pretix')::text, true);
SELECT set_config('in.s2', public.exos_save_integration(pg_temp.u('000000000001'), 'pretix',
  '{"base_url":"https://pretix.eu","organizer":"in-org2"}', NULL, 'Our pretix')::text, true);
SELECT set_config('in.list', (SELECT row_to_json(x)::text FROM public.exos_list_integrations(pg_temp.u('000000000001')) x WHERE provider = 'pretix'), true);
SELECT pg_temp.act('5e000000-0000-0000-0000-0000000000a4');
SELECT set_config('in.scan', pg_temp.refused($$SELECT * FROM public.exos_list_integrations(pg_temp.u('000000000001'))$$, 'not authorized')::text, true);
RESET ROLE;
DO $$
DECLARE l jsonb := current_setting('in.list')::jsonb; c jsonb;
BEGIN
  ASSERT current_setting('in.fin')::boolean AND current_setting('in.finlist')::int = 0, 'I1: finance can list, not save';
  ASSERT current_setting('in.badkey')::boolean AND current_setting('in.badprov')::boolean, 'I1: bad settings / provider';
  ASSERT l->>'secret_hint' = '…1234' AND (l->>'has_secret')::boolean AND l->>'status' = 'unverified', 'I1: hint only ' || l::text;
  ASSERT l::text NOT LIKE '%tok_abcdefgh1234%', 'I1: never the secret';
  ASSERT l->'config'->>'organizer' = 'in-org2', 'I2: settings updated';
  c := public.exos_integration_config(pg_temp.u('000000000001'), 'pretix');
  ASSERT c->>'secret' = 'tok_abcdefgh1234', 'I2: secret kept when not re-sent ' || c::text;
  ASSERT public.exos_integration_mark(pg_temp.u('000000000001'), 'pretix', true, NULL, 'IN Org on pretix'), 'I2: mark';
  ASSERT (SELECT status FROM public.exos_org_integrations WHERE org_id = pg_temp.u('000000000001') AND provider = 'pretix') = 'connected', 'I2: connected';
  ASSERT (SELECT count(*) FROM vault.secrets WHERE name = 'exos_integration:' || pg_temp.u('000000000001') || ':pretix') = 1, 'I2: one vault secret';
  ASSERT NOT has_function_privilege('authenticated', 'public.exos_integration_config(uuid, text)', 'EXECUTE'), 'I2: config is service-only';
  ASSERT NOT has_table_privilege('authenticated', 'public.exos_org_integrations', 'SELECT'), 'I2: table via RPCs';
END $$;

-- B1 / B2 -----------------------------------------------------------------
SET LOCAL ROLE authenticated;
SELECT pg_temp.act('5e000000-0000-0000-0000-0000000000a3');
SELECT set_config('in.b_fin', pg_temp.refused($$SELECT public.exos_set_ticket_backend(pg_temp.u('0000000000e1'), 'pretix', 'https://pretix.eu/in-org/one/')$$, 'owner or manager')::text, true);
SELECT pg_temp.act('5e000000-0000-0000-0000-0000000000a1');
SELECT set_config('in.b_nourl', pg_temp.refused($$SELECT public.exos_set_ticket_backend(pg_temp.u('0000000000e1'), 'pretix', 'http://pretix.eu/x')$$, 'https link')::text, true);
SELECT set_config('in.b_sold', pg_temp.refused($$SELECT public.exos_set_ticket_backend(pg_temp.u('0000000000e2'), 'eventbrite', 'https://www.eventbrite.com/e/1')$$, 'already sold')::text, true);
SELECT public.exos_set_ticket_backend(pg_temp.u('0000000000e1'), 'pretix', 'https://pretix.eu/in-org/one/');
SELECT pg_temp.act('5e000000-0000-0000-0000-0000000000b1');
SELECT set_config('in.b_free', pg_temp.refused($$SELECT public.exos_claim_free_tickets(pg_temp.u('0000000000e1'), pg_temp.u('0000000000d0'), 1)$$, 'another site')::text, true);
RESET ROLE;
DO $$
DECLARE ok boolean;
BEGIN
  ASSERT current_setting('in.b_fin')::boolean AND current_setting('in.b_nourl')::boolean AND current_setting('in.b_sold')::boolean, 'B1';
  ASSERT (SELECT ticket_backend || ' ' || external_ticket_url FROM public.exos_events WHERE id = pg_temp.u('0000000000e1'))
         = 'pretix https://pretix.eu/in-org/one/', 'B2: backend saved';
  -- The public view (prod) carries the columns; the stub schema has no view.
  IF to_regclass('public.exos_public_events') IS NOT NULL THEN
    EXECUTE $q$SELECT 1 FROM public.exos_public_events WHERE ticket_backend = 'pretix' AND external_ticket_url IS NOT NULL$q$;
  END IF;
  ASSERT current_setting('in.b_free')::boolean, 'B2: free claim refused';
  BEGIN
    INSERT INTO public.exos_cart_holds(event_id, tier_id, org_id, buyer_uid, quantity, expires_at)
    VALUES (pg_temp.u('0000000000e1'), pg_temp.u('0000000000d1'), pg_temp.u('000000000001'), pg_temp.u('0000000000b1'), 1, now() + interval '10 minutes');
    ok := false;
  EXCEPTION WHEN insufficient_privilege THEN ok := SQLERRM LIKE '%sold on pretix%';
  END;
  ASSERT ok, 'B2: cart hold refused';
END $$;

-- B3 ----------------------------------------------------------------------
SET LOCAL ROLE authenticated;
SELECT pg_temp.act('5e000000-0000-0000-0000-0000000000a2');
SELECT set_config('in.l_he', pg_temp.refused($$SELECT public.exos_backend_link(pg_temp.u('0000000000e1'), 'hievents', 'cil_abc')$$, 'Integrations first')::text, true);
SELECT set_config('in.l_bad', pg_temp.refused($$SELECT public.exos_backend_link(pg_temp.u('0000000000e1'), 'pretix', 'bad slug!')$$, 'look right')::text, true);
SELECT public.exos_backend_link(pg_temp.u('0000000000e1'), 'pretix', 'one', 'IN One on pretix');
RESET ROLE;
DO $$
DECLARE c record; j jsonb; v_list uuid; n int;
BEGIN
  ASSERT current_setting('in.l_he')::boolean AND current_setting('in.l_bad')::boolean, 'B3: link checks';
  SELECT list_id INTO v_list FROM public.exos_backend_links WHERE event_id = pg_temp.u('0000000000e1');
  ASSERT (SELECT name FROM public.exos_guest_lists WHERE id = v_list) = 'pretix', 'B3: guest list made';
  SELECT * INTO c FROM public.exos_backend_sync_claim(10) x WHERE x.event_id = pg_temp.u('0000000000e1');
  ASSERT c.lease_id IS NOT NULL AND c.provider = 'pretix' AND c.external_ref = 'one', 'B3: claimed';
  SELECT count(*) INTO n FROM public.exos_backend_sync_claim(10) x WHERE x.event_id = pg_temp.u('0000000000e1');
  ASSERT n = 0, 'B3: leased, not claimed twice';
  j := public.exos_backend_apply(pg_temp.u('0000000000e1'), c.lease_id, jsonb_build_array(
         jsonb_build_object('ref', 'ABC12-1', 'code', 'px-secret-one-0001', 'name', 'Ana Lee', 'email', 'ANA@x.com', 'ticket', 'GA'),
         jsonb_build_object('ref', 'ABC12-2', 'code', 'px-secret-two-0002', 'name', 'Bo Kim', 'ticket', 'GA'),
         jsonb_build_object('ref', 'ZZZ99-1', 'code', 'px-secret-gone-003', 'void', true),
         jsonb_build_object('ref', 'bad ref!'), '"junk"'::jsonb), 'more', '2');
  ASSERT (j->>'added')::int = 2 AND (j->>'skipped')::int = 1 AND (j->>'invalid')::int = 2, 'B3: page 1 ' || j::text;
  j := public.exos_backend_apply(pg_temp.u('0000000000e1'), c.lease_id, jsonb_build_array(
         jsonb_build_object('ref', 'ABC12-2', 'code', 'px-secret-two-0002', 'name', 'Bo Kim', 'void', true, 'reason', 'canceled')),
         'done', '2026-10-16T09:00:00Z');
  ASSERT (j->>'voided')::int = 1, 'B3: voided ' || j::text;
  ASSERT (SELECT external_code FROM public.exos_guest_list_entries WHERE external_ref = 'px:ABC12-1') IS NOT NULL, 'B3: QR code stored';
  ASSERT (SELECT source FROM public.exos_guest_list_entries WHERE external_ref = 'px:ABC12-1') = 'pretix', 'B3: source';
  ASSERT (SELECT synced_count FROM public.exos_backend_links WHERE event_id = pg_temp.u('0000000000e1')) = 1, 'B3: count';
  ASSERT (SELECT sync_cursor FROM public.exos_backend_links WHERE event_id = pg_temp.u('0000000000e1')) = '2026-10-16T09:00:00Z', 'B3: cursor';
  j := public.exos_backend_apply(pg_temp.u('0000000000e1'), c.lease_id, '[]', 'done');
  ASSERT j->>'reason' = 'lease-lost', 'B3: a finished lease writes nothing';
END $$;

-- B4 ----------------------------------------------------------------------
SET LOCAL ROLE authenticated;
SELECT pg_temp.act('5e000000-0000-0000-0000-0000000000a4');
SELECT set_config('in.st', public.exos_backend_status(pg_temp.u('0000000000e1'))::text, true);
SELECT pg_temp.act('5e000000-0000-0000-0000-0000000000b1');
SELECT set_config('in.st_fan', pg_temp.refused($$SELECT public.exos_backend_status(pg_temp.u('0000000000e1'))$$, 'not authorized')::text, true);
SELECT pg_temp.act('5e000000-0000-0000-0000-0000000000a1');
SELECT set_config('in.unl', public.exos_backend_unlink(pg_temp.u('0000000000e1'))::text, true);
SELECT set_config('in.back', public.exos_set_ticket_backend(pg_temp.u('0000000000e1'), 'exos')::text, true);
SELECT set_config('in.rm', public.exos_remove_integration(pg_temp.u('000000000001'), 'pretix')::text, true);
RESET ROLE;
DO $$
DECLARE s jsonb := current_setting('in.st')::jsonb;
BEGIN
  ASSERT s->>'ticket_backend' = 'pretix' AND NOT (s->>'can_manage')::boolean AND s->'link'->>'provider' = 'pretix', 'B4: scanner sees status ' || s::text;
  ASSERT s::text NOT LIKE '%tok_%', 'B4: never a token';
  ASSERT current_setting('in.st_fan')::boolean, 'B4: fan refused';
  ASSERT current_setting('in.unl')::boolean
     AND (SELECT count(*) FROM public.exos_guest_list_entries WHERE external_ref LIKE 'px:%' AND event_id = pg_temp.u('0000000000e1')) = 2, 'B4: unlink keeps guests';
  ASSERT (SELECT ticket_backend FROM public.exos_events WHERE id = pg_temp.u('0000000000e1')) = 'exos'
     AND (SELECT external_ticket_url FROM public.exos_events WHERE id = pg_temp.u('0000000000e1')) IS NULL, 'B4: back to exos';
  ASSERT current_setting('in.rm')::boolean
     AND (SELECT count(*) FROM vault.secrets WHERE name = 'exos_integration:' || pg_temp.u('000000000001') || ':pretix') = 0, 'I3: secret deleted';
END $$;

\echo 'test_integrations_backends: all passed'
ROLLBACK;
