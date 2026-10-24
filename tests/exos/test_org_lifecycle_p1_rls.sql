-- ============================================================================
-- Org lifecycle (mig 20261021150000) under the REAL phase-1 RLS policies
-- (run_lifecycle.sh chain). Self-contained (1d prefix), rolled back.
--   R1 an invite still makes a member; an owner can't insert one directly,
--      promote anyone to owner, re-point owner_uid, demote / remove themselves
--   R2 ordinary owner edits still pass RLS; a non-owner can't delete their own
--      row through RLS but can leave with exos_leave_org
--   R3 transfer: the new owner manages the team, the old one can't
--   R4 platform admin: reads the team and can hand the org over; a direct
--      admin UPDATE still changes nothing (the UI hides those controls)
--   R5 caps: re-pointing owner_uid no longer frees org slots
-- ============================================================================
\set ON_ERROR_STOP on
BEGIN;
-- Supabase lets the API roles call auth.uid() / auth.jwt() (the prereq stub doesn't).
GRANT USAGE ON SCHEMA auth TO anon, authenticated;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA auth TO anon, authenticated;
INSERT INTO auth.users(id,email,email_confirmed_at) VALUES
  ('1d000000-0000-0000-0000-0000000000a1','1d-own@x.com',now()),
  ('1d000000-0000-0000-0000-0000000000a2','1d-mgr@x.com',now()),
  ('1d000000-0000-0000-0000-0000000000a3','1d-stranger@x.com',now()),
  ('1d000000-0000-0000-0000-0000000000a4','1d-spam@x.com',now()),
  ('1d000000-0000-0000-0000-0000000000ad','1d-admin@exos.test',now());

CREATE FUNCTION pg_temp.act(p_uid text, p_email text, p_admin boolean DEFAULT false) RETURNS void LANGUAGE sql AS $$
  SELECT set_config('app.uid', p_uid, true),
         set_config('app.jwt', json_build_object('email', p_email, 'role', 'authenticated',
                    'app_metadata', json_build_object('admin', CASE WHEN p_admin THEN 'true' ELSE 'false' END))::text, true);
$$;
CREATE FUNCTION pg_temp.u(p text) RETURNS uuid LANGUAGE sql IMMUTABLE AS $$ SELECT ('1d000000-0000-0000-0000-' || p)::uuid $$;
-- Runs p_sql and fires the deferred checks; true when refused with p_like.
CREATE FUNCTION pg_temp.refused(p_sql text, p_like text) RETURNS boolean LANGUAGE plpgsql AS $$
BEGIN
  EXECUTE p_sql;
  SET CONSTRAINTS ALL IMMEDIATE;
  SET CONSTRAINTS ALL DEFERRED;
  RETURN false;
EXCEPTION WHEN others THEN
  IF SQLERRM NOT LIKE '%' || p_like || '%' THEN
    RAISE EXCEPTION 'expected "%", got % "%"', p_like, SQLSTATE, SQLERRM;
  END IF;
  RETURN true;
END $$;
-- Rows a statement changed (0 when RLS hid them).
CREATE FUNCTION pg_temp.n(p_sql text) RETURNS int LANGUAGE plpgsql AS $$
DECLARE v int;
BEGIN
  EXECUTE p_sql;
  GET DIAGNOSTICS v = ROW_COUNT;
  RETURN v;
END $$;
GRANT EXECUTE ON FUNCTION pg_temp.act(text, text, boolean), pg_temp.u(text), pg_temp.refused(text, text), pg_temp.n(text) TO authenticated;
CREATE TEMP TABLE out(k text PRIMARY KEY, v text);
GRANT ALL ON out TO authenticated;

-- R1 -------------------------------------------------------------------------
SET LOCAL ROLE authenticated;
SELECT pg_temp.act('1d000000-0000-0000-0000-0000000000a1', '1d-own@x.com');
SELECT set_config('t.org', public.exos_create_org('1D Org', '1d-org')::text, true);
INSERT INTO public.exos_org_invites(org_id, email, role, created_by) VALUES (current_setting('t.org')::uuid, '1d-mgr@x.com', 'manager', auth.uid());
SELECT pg_temp.act('1d000000-0000-0000-0000-0000000000a2', '1d-mgr@x.com');
SELECT public.exos_claim_invite((SELECT token FROM public.exos_org_invites WHERE email = '1d-mgr@x.com'));
SELECT pg_temp.act('1d000000-0000-0000-0000-0000000000a1', '1d-own@x.com');
INSERT INTO out VALUES ('r1_insert', pg_temp.refused(format($$INSERT INTO public.exos_org_memberships(org_id,user_id,role) VALUES (%L, %L, 'manager')$$, current_setting('t.org'), pg_temp.u('0000000000a3')), 'join through an invite')::text);
INSERT INTO out VALUES ('r1_promote', pg_temp.refused($$UPDATE public.exos_org_memberships SET role = 'owner' WHERE user_id = pg_temp.u('0000000000a2')$$, 'exos_transfer_org_ownership')::text);
INSERT INTO out VALUES ('r1_owner_uid', pg_temp.refused(format($$UPDATE public.exos_orgs SET owner_uid = %L WHERE id = %L$$, pg_temp.u('0000000000a2'), current_setting('t.org')), 'exos_transfer_org_ownership')::text);
INSERT INTO out VALUES ('r1_demote_self', pg_temp.refused($$UPDATE public.exos_org_memberships SET role = 'content' WHERE user_id = auth.uid()$$, 'exos_transfer_org_ownership')::text);
INSERT INTO out VALUES ('r1_delete_self', pg_temp.refused($$DELETE FROM public.exos_org_memberships WHERE user_id = auth.uid()$$, 'transfer ownership first')::text);
-- R2
INSERT INTO out VALUES ('r2_role', pg_temp.n($$UPDATE public.exos_org_memberships SET role = 'finance' WHERE user_id = pg_temp.u('0000000000a2')$$)::text);
INSERT INTO out VALUES ('r2_rename', pg_temp.n(format($$UPDATE public.exos_orgs SET name = '1D Renamed' WHERE id = %L$$, current_setting('t.org')))::text);
SELECT pg_temp.act('1d000000-0000-0000-0000-0000000000a2', '1d-mgr@x.com');
INSERT INTO out VALUES ('r2_self_delete_rls', pg_temp.n($$DELETE FROM public.exos_org_memberships WHERE user_id = auth.uid()$$)::text);
RESET ROLE;
DO $$
BEGIN
  ASSERT (SELECT string_agg(user_id::text || ':' || role, ',' ORDER BY user_id) FROM public.exos_org_memberships WHERE org_id = current_setting('t.org')::uuid)
         = pg_temp.u('0000000000a1')::text || ':owner,' || pg_temp.u('0000000000a2')::text || ':finance', 'R1: invite claimed, role edited';
  ASSERT (SELECT v FROM out WHERE k = 'r1_insert')::boolean AND (SELECT v FROM out WHERE k = 'r1_promote')::boolean
     AND (SELECT v FROM out WHERE k = 'r1_owner_uid')::boolean AND (SELECT v FROM out WHERE k = 'r1_demote_self')::boolean
     AND (SELECT v FROM out WHERE k = 'r1_delete_self')::boolean, 'R1: raw RLS paths closed';
  ASSERT (SELECT v FROM out WHERE k = 'r2_role') = '1' AND (SELECT v FROM out WHERE k = 'r2_rename') = '1'
     AND (SELECT v FROM out WHERE k = 'r2_self_delete_rls') = '0', 'R2: ordinary edits pass RLS';
  ASSERT (SELECT created_by FROM public.exos_orgs WHERE id = current_setting('t.org')::uuid) = pg_temp.u('0000000000a1'), 'R1: created_by';
  RAISE NOTICE 'R1/R2 ok: invites, owner edits; owner role closed to raw writes';
END $$;

-- R2 leave / R3 transfer -----------------------------------------------------
SET LOCAL ROLE authenticated;
SELECT pg_temp.act('1d000000-0000-0000-0000-0000000000a2', '1d-mgr@x.com');
SELECT public.exos_leave_org(current_setting('t.org')::uuid);
RESET ROLE;
INSERT INTO public.exos_org_memberships(org_id,user_id,role) VALUES (current_setting('t.org')::uuid, pg_temp.u('0000000000a2'), 'manager');
SET LOCAL ROLE authenticated;
SELECT pg_temp.act('1d000000-0000-0000-0000-0000000000a1', '1d-own@x.com');
SELECT public.exos_transfer_org_ownership(current_setting('t.org')::uuid, pg_temp.u('0000000000a2'));
SET CONSTRAINTS ALL IMMEDIATE;
SET CONSTRAINTS ALL DEFERRED;
INSERT INTO out VALUES ('r3_old_owner_edit', pg_temp.n($$UPDATE public.exos_org_memberships SET role = 'scanner' WHERE user_id = pg_temp.u('0000000000a2')$$)::text);
SELECT pg_temp.act('1d000000-0000-0000-0000-0000000000a2', '1d-mgr@x.com');
INSERT INTO out VALUES ('r3_new_owner_edit', pg_temp.n($$UPDATE public.exos_org_memberships SET role = 'content' WHERE user_id = pg_temp.u('0000000000a1')$$)::text);
RESET ROLE;
DO $$
BEGIN
  ASSERT (SELECT v FROM out WHERE k = 'r3_old_owner_edit') = '0' AND (SELECT v FROM out WHERE k = 'r3_new_owner_edit') = '1',
    'R3: the new owner manages the team, the old one no longer can';
  ASSERT (SELECT owner_uid FROM public.exos_orgs WHERE id = current_setting('t.org')::uuid) = pg_temp.u('0000000000a2'), 'R3: owner_uid';
  RAISE NOTICE 'R2/R3 ok: leave; transfer hands over RLS rights';
END $$;

-- R4 -------------------------------------------------------------------------
SET LOCAL ROLE authenticated;
SELECT pg_temp.act('1d000000-0000-0000-0000-0000000000ad', '1d-admin@exos.test', true);
INSERT INTO out SELECT 'r4_list', count(*)::text FROM public.exos_org_members(current_setting('t.org')::uuid) WHERE email IS NOT NULL;
INSERT INTO out VALUES ('r4_direct', pg_temp.n(format($$UPDATE public.exos_orgs SET name = 'By admin' WHERE id = %L$$, current_setting('t.org')))::text);
SELECT public.exos_transfer_org_ownership(current_setting('t.org')::uuid, pg_temp.u('0000000000a1'));
SET CONSTRAINTS ALL IMMEDIATE;
SET CONSTRAINTS ALL DEFERRED;
RESET ROLE;
DO $$
BEGIN
  ASSERT (SELECT v FROM out WHERE k = 'r4_list') = '2', 'R4: admin reads the team';
  ASSERT (SELECT v FROM out WHERE k = 'r4_direct') = '0', 'R4: a direct admin UPDATE still changes nothing';
  ASSERT (SELECT owner_uid FROM public.exos_orgs WHERE id = current_setting('t.org')::uuid) = pg_temp.u('0000000000a1'), 'R4: admin handover';
  RAISE NOTICE 'R4 ok: platform admin reads + hands over via RPC';
END $$;

-- R5 -------------------------------------------------------------------------
SET LOCAL ROLE authenticated;
SELECT pg_temp.act('1d000000-0000-0000-0000-0000000000a4', '1d-spam@x.com');
SELECT public.exos_create_org('1D Spam ' || i, '1d-spam-' || i) FROM generate_series(1, 3) i;
INSERT INTO out VALUES ('r5_repoint', pg_temp.refused($$UPDATE public.exos_orgs SET owner_uid = pg_temp.u('0000000000a3') WHERE slug LIKE '1d-spam-%'$$, 'exos_transfer_org_ownership')::text);
INSERT INTO out VALUES ('r5_cap', pg_temp.refused($$SELECT public.exos_create_org('1D Spam 4', '1d-spam-4')$$, '3 a day')::text);
RESET ROLE;
DO $$
BEGIN
  ASSERT (SELECT v FROM out WHERE k = 'r5_repoint')::boolean AND (SELECT v FROM out WHERE k = 'r5_cap')::boolean, 'R5: caps hold';
  RAISE NOTICE 'R5 ok: re-pointing owner_uid is closed; the caps hold';
END $$;

SELECT 'test_org_lifecycle_p1_rls: all passed' AS result;
ROLLBACK;
