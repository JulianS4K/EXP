-- ============================================================================
-- Org lifecycle (mig 20261021150000). Self-contained (1c prefix), rolled back.
--   O1 transfer: owner only, to an active member; owner_uid + both rows move;
--      the ex-owner (now a manager) can delete their account
--   O2 client writes can't re-point owner_uid / created_by, add members, or
--      touch an owner's row; at commit an org keeps an active owner and
--      owner_uid is one (the real RLS run is test_org_lifecycle_p1_rls.sql)
--   O3 members list (role-gated, with email + name), leave, remove
--   O4 org caps count created_by: handing orgs over frees no slot
--   O5 financial mail: current active owners, not a stale owner_uid
--   B1 a switch away from Exos is refused with live carts, open checkouts or
--      marketplace allocations; it stamps the switch and unlinks the old sync
--   B2 after a switch: a session opened earlier fulfils, a later one fails;
--      staff mints, comps, issue-to-email, distribution, allocations, the
--      auto split and marketplace sales refuse / need a person
--   psql -d <db> -v ON_ERROR_STOP=1 -f tests/exos/test_org_lifecycle_p1.sql
-- ============================================================================
\set ON_ERROR_STOP on
BEGIN;
-- As in prod (not all in this chain; the client grants are RLS-gated there,
-- see test_org_lifecycle_p1_rls.sql). Rolled back with the rest.
ALTER TABLE auth.users ADD COLUMN IF NOT EXISTS phone text, ADD COLUMN IF NOT EXISTS raw_user_meta_data jsonb,
  ADD COLUMN IF NOT EXISTS banned_until timestamptz, ADD COLUMN IF NOT EXISTS updated_at timestamptz;
CREATE TABLE IF NOT EXISTS auth.identities (id uuid DEFAULT gen_random_uuid(), user_id uuid);
CREATE TABLE IF NOT EXISTS auth.sessions (id uuid DEFAULT gen_random_uuid(), user_id uuid);
CREATE TABLE IF NOT EXISTS auth.refresh_tokens (id bigserial, user_id varchar);
CREATE TABLE IF NOT EXISTS public.exos_org_invites (token uuid DEFAULT gen_random_uuid(), org_id uuid, email text, claimed_by uuid);
CREATE TABLE IF NOT EXISTS public.exos_profiles (id uuid PRIMARY KEY, display_name text);
CREATE TABLE IF NOT EXISTS public.exos_event_saves (user_id uuid);
CREATE TABLE IF NOT EXISTS public.exos_notification_reads (uid uuid);
CREATE TABLE IF NOT EXISTS public.exos_org_follows (follower_uid uuid, org_id uuid);
ALTER TABLE public.exos_org_memberships ADD COLUMN IF NOT EXISTS created_at timestamptz NOT NULL DEFAULT now(),
  ADD COLUMN IF NOT EXISTS added_by uuid;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.exos_org_memberships, public.exos_orgs TO authenticated;

INSERT INTO auth.users(id,email,email_confirmed_at) VALUES
  ('1c000000-0000-0000-0000-0000000000a1','1c-own@x.com',now()),
  ('1c000000-0000-0000-0000-0000000000a2','1c-mgr@x.com',now()),
  ('1c000000-0000-0000-0000-0000000000a3','1c-fin@x.com',now()),
  ('1c000000-0000-0000-0000-0000000000a4','1c-off@x.com',now()),
  ('1c000000-0000-0000-0000-0000000000a5','1c-stranger@x.com',now()),
  ('1c000000-0000-0000-0000-0000000000a6','1c-spam@x.com',now()),
  ('1c000000-0000-0000-0000-0000000000a7','1c-victim@x.com',now());
INSERT INTO public.exos_profiles(id, display_name) VALUES ('1c000000-0000-0000-0000-0000000000a2', 'Mia Manager');
INSERT INTO public.exos_orgs(id,name,slug,owner_uid) VALUES
  ('1c000000-0000-0000-0000-000000000001','1C Org','1c-org','1c000000-0000-0000-0000-0000000000a1');
INSERT INTO public.exos_org_memberships(org_id,user_id,role,disabled) VALUES
  ('1c000000-0000-0000-0000-000000000001','1c000000-0000-0000-0000-0000000000a1','owner',false),
  ('1c000000-0000-0000-0000-000000000001','1c000000-0000-0000-0000-0000000000a2','manager',false),
  ('1c000000-0000-0000-0000-000000000001','1c000000-0000-0000-0000-0000000000a3','finance',false),
  ('1c000000-0000-0000-0000-000000000001','1c000000-0000-0000-0000-0000000000a4','scanner',true);

CREATE FUNCTION pg_temp.act(p_uid text, p_email text DEFAULT NULL) RETURNS void LANGUAGE sql AS $$
  SELECT set_config('app.uid', coalesce(p_uid, ''), true),
         set_config('app.jwt', CASE WHEN p_email IS NULL THEN '' ELSE json_build_object('email', p_email)::text END, true);
$$;
CREATE FUNCTION pg_temp.u(p text) RETURNS uuid LANGUAGE sql IMMUTABLE AS $$ SELECT ('1c000000-0000-0000-0000-' || p)::uuid $$;
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
GRANT EXECUTE ON FUNCTION pg_temp.act(text, text), pg_temp.u(text), pg_temp.refused(text, text) TO authenticated;
CREATE TEMP TABLE out(k text PRIMARY KEY, v text);
GRANT ALL ON out TO authenticated;

-- O1 -------------------------------------------------------------------------
SET LOCAL ROLE authenticated;
SELECT pg_temp.act('1c000000-0000-0000-0000-0000000000a2');
INSERT INTO out VALUES ('o1_mgr', pg_temp.refused($$SELECT public.exos_transfer_org_ownership(pg_temp.u('000000000001'), pg_temp.u('0000000000a2'))$$, 'only the owner')::text);
SELECT pg_temp.act('1c000000-0000-0000-0000-0000000000a1');
INSERT INTO out VALUES ('o1_disabled', pg_temp.refused($$SELECT public.exos_transfer_org_ownership(pg_temp.u('000000000001'), pg_temp.u('0000000000a4'))$$, 'active member')::text);
INSERT INTO out VALUES ('o1_stranger', pg_temp.refused($$SELECT public.exos_transfer_org_ownership(pg_temp.u('000000000001'), pg_temp.u('0000000000a5'))$$, 'active member')::text);
INSERT INTO out VALUES ('o1_self', pg_temp.refused($$SELECT public.exos_transfer_org_ownership(pg_temp.u('000000000001'), pg_temp.u('0000000000a1'))$$, 'already own')::text);
INSERT INTO out VALUES ('o1_owner_cant_delete', pg_temp.refused($$SELECT public.exos_delete_my_account()$$, 'own an organization')::text);
INSERT INTO out VALUES ('o1_owner_cant_leave', pg_temp.refused($$SELECT public.exos_leave_org(pg_temp.u('000000000001'))$$, 'make someone else the owner')::text);
INSERT INTO out VALUES ('o1_xfer', public.exos_transfer_org_ownership(pg_temp.u('000000000001'), pg_temp.u('0000000000a2'))::text);
SET CONSTRAINTS ALL IMMEDIATE;
SET CONSTRAINTS ALL DEFERRED;
RESET ROLE;
DO $$
BEGIN
  ASSERT (SELECT v FROM out WHERE k = 'o1_mgr')::boolean, 'O1: a manager can''t hand the org over';
  ASSERT (SELECT v FROM out WHERE k = 'o1_disabled')::boolean AND (SELECT v FROM out WHERE k = 'o1_stranger')::boolean
     AND (SELECT v FROM out WHERE k = 'o1_self')::boolean, 'O1: only to another active member';
  ASSERT (SELECT v FROM out WHERE k = 'o1_owner_cant_delete')::boolean AND (SELECT v FROM out WHERE k = 'o1_owner_cant_leave')::boolean,
    'O1: the owner can''t delete their account or leave';
  ASSERT (SELECT owner_uid FROM public.exos_orgs WHERE id = pg_temp.u('000000000001')) = pg_temp.u('0000000000a2'), 'O1: owner_uid moved';
  ASSERT (SELECT string_agg(user_id::text || ':' || role, ',' ORDER BY user_id) FROM public.exos_org_memberships
           WHERE org_id = pg_temp.u('000000000001') AND role IN ('owner', 'manager'))
         = pg_temp.u('0000000000a1')::text || ':manager,' || pg_temp.u('0000000000a2')::text || ':owner', 'O1: both rows moved';
  ASSERT (SELECT v FROM out WHERE k = 'o1_xfer')::jsonb->>'previous_owner_uid' = pg_temp.u('0000000000a1')::text, 'O1: result';
  RAISE NOTICE 'O1 ok: ownership handed to an active member, atomically';
END $$;
-- The ex-owner can now leave the account behind.
SET LOCAL ROLE authenticated;
SELECT pg_temp.act('1c000000-0000-0000-0000-0000000000a1', '1c-own@x.com');
SELECT public.exos_delete_my_account();
SET CONSTRAINTS ALL IMMEDIATE;
SET CONSTRAINTS ALL DEFERRED;
RESET ROLE;
DO $$
BEGIN
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_org_memberships WHERE user_id = pg_temp.u('0000000000a1')), 'O1: deleted ex-owner off the team';
  RAISE NOTICE 'O1 ok: the ex-owner deleted their account';
END $$;

-- O2 -------------------------------------------------------------------------
SET LOCAL ROLE authenticated;
SELECT pg_temp.act('1c000000-0000-0000-0000-0000000000a2');   -- the owner now
INSERT INTO out VALUES ('o2_insert', pg_temp.refused($$INSERT INTO public.exos_org_memberships(org_id,user_id,role) VALUES (pg_temp.u('000000000001'), pg_temp.u('0000000000a5'), 'manager')$$, 'join through an invite')::text);
INSERT INTO out VALUES ('o2_promote', pg_temp.refused($$UPDATE public.exos_org_memberships SET role = 'owner' WHERE user_id = pg_temp.u('0000000000a3')$$, 'exos_transfer_org_ownership')::text);
INSERT INTO out VALUES ('o2_demote_self', pg_temp.refused($$UPDATE public.exos_org_memberships SET role = 'content' WHERE user_id = pg_temp.u('0000000000a2')$$, 'exos_transfer_org_ownership')::text);
INSERT INTO out VALUES ('o2_disable_self', pg_temp.refused($$UPDATE public.exos_org_memberships SET disabled = true WHERE user_id = pg_temp.u('0000000000a2')$$, 'exos_transfer_org_ownership')::text);
INSERT INTO out VALUES ('o2_delete_self', pg_temp.refused($$DELETE FROM public.exos_org_memberships WHERE user_id = pg_temp.u('0000000000a2')$$, 'transfer ownership first')::text);
INSERT INTO out VALUES ('o2_move_row', pg_temp.refused($$UPDATE public.exos_org_memberships SET user_id = pg_temp.u('0000000000a5') WHERE user_id = pg_temp.u('0000000000a3')$$, 'moved to another')::text);
INSERT INTO out VALUES ('o2_owner_uid', pg_temp.refused($$UPDATE public.exos_orgs SET owner_uid = pg_temp.u('0000000000a7') WHERE id = pg_temp.u('000000000001')$$, 'exos_transfer_org_ownership')::text);
INSERT INTO out VALUES ('o2_rename', pg_temp.refused($$UPDATE public.exos_orgs SET name = '1C Renamed' WHERE id = pg_temp.u('000000000001')$$, 'zzz-never')::text);
INSERT INTO out VALUES ('o2_role', pg_temp.refused($$UPDATE public.exos_org_memberships SET role = 'content' WHERE user_id = pg_temp.u('0000000000a3')$$, 'zzz-never')::text);
UPDATE public.exos_org_memberships SET role = 'finance' WHERE user_id = pg_temp.u('0000000000a3');
RESET ROLE;
UPDATE public.exos_orgs SET created_by = pg_temp.u('0000000000a2') WHERE id = pg_temp.u('000000000001');
SET LOCAL ROLE authenticated;
SELECT pg_temp.act('1c000000-0000-0000-0000-0000000000a2');
INSERT INTO out VALUES ('o2_created_by2', pg_temp.refused($$UPDATE public.exos_orgs SET created_by = NULL WHERE id = pg_temp.u('000000000001')$$, 'exos_transfer_org_ownership')::text);
RESET ROLE;
-- Server-side writes still answer to the commit-time checks.
INSERT INTO out VALUES ('o2_last_owner', pg_temp.refused($$UPDATE public.exos_org_memberships SET role = 'content' WHERE user_id = pg_temp.u('0000000000a2')$$, 'needs an active owner')::text);
INSERT INTO out VALUES ('o2_uid_nonowner', pg_temp.refused($$UPDATE public.exos_orgs SET owner_uid = pg_temp.u('0000000000a3') WHERE id = pg_temp.u('000000000001')$$, 'must be an active owner member')::text);
DO $$
BEGIN
  ASSERT (SELECT v FROM out WHERE k = 'o2_insert')::boolean, 'O2: no direct membership insert';
  ASSERT (SELECT v FROM out WHERE k = 'o2_promote')::boolean AND (SELECT v FROM out WHERE k = 'o2_demote_self')::boolean
     AND (SELECT v FROM out WHERE k = 'o2_disable_self')::boolean AND (SELECT v FROM out WHERE k = 'o2_delete_self')::boolean,
    'O2: the owner role only moves through the RPC';
  ASSERT (SELECT v FROM out WHERE k = 'o2_move_row')::boolean, 'O2: a row can''t be re-pointed';
  ASSERT (SELECT v FROM out WHERE k = 'o2_owner_uid')::boolean AND (SELECT v FROM out WHERE k = 'o2_created_by2')::boolean,
    'O2: owner_uid / created_by not client-writable';
  ASSERT NOT (SELECT v FROM out WHERE k = 'o2_rename')::boolean
     AND NOT (SELECT v FROM out WHERE k = 'o2_role')::boolean, 'O2: ordinary edits still work';
  ASSERT (SELECT v FROM out WHERE k = 'o2_last_owner')::boolean AND (SELECT v FROM out WHERE k = 'o2_uid_nonowner')::boolean,
    'O2: commit-time owner checks';
  ASSERT (SELECT name FROM public.exos_orgs WHERE id = pg_temp.u('000000000001')) = '1C Renamed', 'O2: rename kept';
  RAISE NOTICE 'O2 ok: ownership invariants hold';
END $$;
-- Deleting an org (its memberships cascade) is fine.
INSERT INTO public.exos_orgs(id,name,slug,owner_uid) VALUES (pg_temp.u('000000000009'),'Gone','1c-gone',pg_temp.u('0000000000a5'));
INSERT INTO public.exos_org_memberships(org_id,user_id,role) VALUES (pg_temp.u('000000000009'),pg_temp.u('0000000000a5'),'owner');
DO $d$
BEGIN
  ASSERT NOT pg_temp.refused($$DELETE FROM public.exos_orgs WHERE id = pg_temp.u('000000000009')$$, 'zzz-never'), 'O2: org delete';
  RAISE NOTICE 'O2 ok: deleting an org is not blocked';
END $d$;

-- O3 -------------------------------------------------------------------------
INSERT INTO public.exos_org_memberships(org_id,user_id,role) VALUES (pg_temp.u('000000000001'),pg_temp.u('0000000000a5'),'content');
SET LOCAL ROLE authenticated;
SELECT pg_temp.act('1c000000-0000-0000-0000-0000000000a3');
INSERT INTO out SELECT 'o3_fin_list', json_agg(m)::text FROM public.exos_org_members(pg_temp.u('000000000001')) m;
SELECT pg_temp.act('1c000000-0000-0000-0000-0000000000a7');
INSERT INTO out VALUES ('o3_outsider', pg_temp.refused($$SELECT * FROM public.exos_org_members(pg_temp.u('000000000001'))$$, 'not on this team')::text);
SELECT pg_temp.act('1c000000-0000-0000-0000-0000000000a2');
INSERT INTO out SELECT 'o3_owner_list', json_agg(m)::text FROM public.exos_org_members(pg_temp.u('000000000001')) m;
INSERT INTO out VALUES ('o3_remove_owner', pg_temp.refused($$SELECT public.exos_remove_org_member(pg_temp.u('000000000001'), pg_temp.u('0000000000a2'))$$, 'can''t be removed')::text);
INSERT INTO out VALUES ('o3_remove', public.exos_remove_org_member(pg_temp.u('000000000001'), pg_temp.u('0000000000a4'))::text);
SELECT pg_temp.act('1c000000-0000-0000-0000-0000000000a3');
INSERT INTO out VALUES ('o3_fin_remove', pg_temp.refused($$SELECT public.exos_remove_org_member(pg_temp.u('000000000001'), pg_temp.u('0000000000a5'))$$, 'owner only')::text);
INSERT INTO out VALUES ('o3_leave', public.exos_leave_org(pg_temp.u('000000000001'))::text);
INSERT INTO out VALUES ('o3_leave_again', pg_temp.refused($$SELECT public.exos_leave_org(pg_temp.u('000000000001'))$$, 'not on this team')::text);
RESET ROLE;
DO $$
DECLARE f jsonb := (SELECT v FROM out WHERE k = 'o3_fin_list')::jsonb; o jsonb := (SELECT v FROM out WHERE k = 'o3_owner_list')::jsonb;
BEGIN
  ASSERT jsonb_array_length(f) = 1 AND f->0->>'email' = '1c-fin@x.com', 'O3: finance sees only their own row ' || f::text;
  ASSERT (SELECT v FROM out WHERE k = 'o3_outsider')::boolean, 'O3: outsiders see nothing';
  ASSERT jsonb_array_length(o) = 4 AND o->0->>'role' = 'owner' AND o->0->>'email' = '1c-mgr@x.com'
     AND o->0->>'display_name' = 'Mia Manager', 'O3: the owner sees the team with email + name ' || o::text;
  ASSERT (SELECT v FROM out WHERE k = 'o3_remove_owner')::boolean AND (SELECT v FROM out WHERE k = 'o3_fin_remove')::boolean,
    'O3: remove is owner-only and never the owner';
  ASSERT (SELECT v FROM out WHERE k = 'o3_remove')::boolean AND (SELECT v FROM out WHERE k = 'o3_leave')::boolean
     AND (SELECT v FROM out WHERE k = 'o3_leave_again')::boolean, 'O3: remove + leave';
  ASSERT (SELECT string_agg(user_id::text, ',' ORDER BY user_id) FROM public.exos_org_memberships WHERE org_id = pg_temp.u('000000000001'))
         = pg_temp.u('0000000000a2')::text || ',' || pg_temp.u('0000000000a5')::text, 'O3: team left';
  RAISE NOTICE 'O3 ok: members list, remove, leave';
END $$;

-- O4 -------------------------------------------------------------------------
SET LOCAL ROLE authenticated;
SELECT pg_temp.act('1c000000-0000-0000-0000-0000000000a6');
SELECT public.exos_create_org('Spam 1', '1c-spam-1'), public.exos_create_org('Spam 2', '1c-spam-2'), public.exos_create_org('Spam 3', '1c-spam-3');
RESET ROLE;
INSERT INTO public.exos_org_memberships(org_id,user_id,role) SELECT id, pg_temp.u('0000000000a7'), 'manager' FROM public.exos_orgs WHERE slug LIKE '1c-spam-%';
SET LOCAL ROLE authenticated;
SELECT pg_temp.act('1c000000-0000-0000-0000-0000000000a6');
SELECT public.exos_transfer_org_ownership(id, pg_temp.u('0000000000a7')) FROM public.exos_orgs WHERE slug LIKE '1c-spam-%';
INSERT INTO out VALUES ('o4_cap', pg_temp.refused($$SELECT public.exos_create_org('Spam 4', '1c-spam-4')$$, '3 a day')::text);
RESET ROLE;
DO $$
BEGIN
  ASSERT (SELECT count(*) FROM public.exos_orgs WHERE slug LIKE '1c-spam-%' AND created_by = pg_temp.u('0000000000a6')
             AND owner_uid = pg_temp.u('0000000000a7')) = 3, 'O4: created_by recorded, owners moved';
  ASSERT (SELECT v FROM out WHERE k = 'o4_cap')::boolean, 'O4: handing orgs over frees no slot';
  RAISE NOTICE 'O4 ok: the org caps count who created them';
END $$;

-- O5 -------------------------------------------------------------------------
-- A stale owner_uid (pre-existing data; never committed here) gets nothing.
INSERT INTO public.exos_org_memberships(org_id,user_id,role) VALUES (pg_temp.u('000000000001'),pg_temp.u('0000000000a3'),'finance');
UPDATE public.exos_orgs SET owner_uid = pg_temp.u('0000000000a7') WHERE id = pg_temp.u('000000000001');
DO $$
BEGIN
  ASSERT (SELECT string_agg(email, ',' ORDER BY email) FROM public.exos_org_mail_recipients(pg_temp.u('000000000001'), ARRAY['finance']))
         = '1c-fin@x.com,1c-mgr@x.com', 'O5: finance + the active owner only';
  ASSERT (SELECT string_agg(email, ',' ORDER BY email) FROM public.exos_org_mail_recipients(pg_temp.u('000000000001'), ARRAY['owner','manager']))
         = '1c-mgr@x.com', 'O5: owner / manager';
  RAISE NOTICE 'O5 ok: financial mail goes to current active owners';
END $$;
UPDATE public.exos_orgs SET owner_uid = pg_temp.u('0000000000a2') WHERE id = pg_temp.u('000000000001');

-- B1 -------------------------------------------------------------------------
INSERT INTO public.exos_events(id,org_id,name,slug,status,starts_at,timezone,total_tickets,tickets_sold,created_by) VALUES
  (pg_temp.u('0000000000e1'),pg_temp.u('000000000001'),'1C One','1c-one','published',now() + interval '5 days','UTC',100,0,pg_temp.u('0000000000a2'));
INSERT INTO public.exos_ticket_tiers(id,event_id,name,price,capacity,sold,visibility) VALUES
  (pg_temp.u('0000000000d1'),pg_temp.u('0000000000e1'),'GA',30,100,0,'public');
INSERT INTO public.exos_cart_holds(event_id, tier_id, org_id, buyer_uid, quantity, expires_at)
VALUES (pg_temp.u('0000000000e1'), pg_temp.u('0000000000d1'), pg_temp.u('000000000001'), pg_temp.u('0000000000a5'), 2, now() + interval '10 minutes');
INSERT INTO public.exos_checkout_sessions(session_id,event_id,tier_id,org_id,buyer_uid,buyer_email,quantity,amount_cents,status,created_at) VALUES
  ('1c-open', pg_temp.u('0000000000e1'), pg_temp.u('0000000000d1'), pg_temp.u('000000000001'), pg_temp.u('0000000000a5'), '1c-stranger@x.com', 1, 3000, 'pending', now() - interval '5 minutes');
INSERT INTO public.exos_distribution_listings(event_id,org_id,channel,status,tier_id,requested_qty,unit_price) VALUES
  (pg_temp.u('0000000000e1'), pg_temp.u('000000000001'), 'stubhub', 'listed', pg_temp.u('0000000000d1'), 4, 40);
SET LOCAL ROLE authenticated;
SELECT pg_temp.act('1c000000-0000-0000-0000-0000000000a2');
INSERT INTO out VALUES ('b1_hold', pg_temp.refused($$SELECT public.exos_set_ticket_backend(pg_temp.u('0000000000e1'), 'eventbrite', 'https://www.eventbrite.com/e/1')$$, 'in buyers'' carts')::text);
RESET ROLE;
UPDATE public.exos_cart_holds SET status = 'released', released_at = now() WHERE event_id = pg_temp.u('0000000000e1');
SET LOCAL ROLE authenticated;
SELECT pg_temp.act('1c000000-0000-0000-0000-0000000000a2');
INSERT INTO out VALUES ('b1_session', pg_temp.refused($$SELECT public.exos_set_ticket_backend(pg_temp.u('0000000000e1'), 'eventbrite', 'https://www.eventbrite.com/e/1')$$, 'checkouts are still open')::text);
RESET ROLE;
UPDATE public.exos_checkout_sessions SET created_at = now() - interval '40 minutes' WHERE session_id = '1c-open';
SET LOCAL ROLE authenticated;
SELECT pg_temp.act('1c000000-0000-0000-0000-0000000000a2');
INSERT INTO out VALUES ('b1_alloc', pg_temp.refused($$SELECT public.exos_set_ticket_backend(pg_temp.u('0000000000e1'), 'eventbrite', 'https://www.eventbrite.com/e/1')$$, 'resale marketplaces')::text);
RESET ROLE;
UPDATE public.exos_distribution_listings SET requested_qty = 0 WHERE event_id = pg_temp.u('0000000000e1');
SET LOCAL ROLE authenticated;
SELECT pg_temp.act('1c000000-0000-0000-0000-0000000000a2');
SELECT public.exos_save_integration(pg_temp.u('000000000001'), 'pretix', '{"base_url":"https://pretix.eu","organizer":"1c"}', 'tok_1c1c1c1c1c', 'pretix');
SELECT public.exos_set_ticket_backend(pg_temp.u('0000000000e1'), 'pretix', 'https://pretix.eu/1c/one/');
SELECT public.exos_backend_link(pg_temp.u('0000000000e1'), 'pretix', 'one', '1C on pretix');
INSERT INTO out VALUES ('b1_same', (public.exos_set_ticket_backend(pg_temp.u('0000000000e1'), 'pretix', 'https://pretix.eu/1c/one-b/')->>'unlinked'));
INSERT INTO out SELECT 'b1_link_kept', (public.exos_backend_status(pg_temp.u('0000000000e1'))->'link'->>'provider');
INSERT INTO out VALUES ('b1_switch', (public.exos_set_ticket_backend(pg_temp.u('0000000000e1'), 'hievents', 'https://app.hi.events/e/1')->>'unlinked'));
INSERT INTO out SELECT 'b1_status', public.exos_backend_status(pg_temp.u('0000000000e1'))::text;
RESET ROLE;
DO $$
BEGIN
  ASSERT (SELECT v FROM out WHERE k = 'b1_hold')::boolean AND (SELECT v FROM out WHERE k = 'b1_session')::boolean
     AND (SELECT v FROM out WHERE k = 'b1_alloc')::boolean, 'B1: refused while carts / checkouts / allocations are live';
  ASSERT (SELECT v FROM out WHERE k = 'b1_same') = 'false' AND (SELECT v FROM out WHERE k = 'b1_link_kept') = 'pretix', 'B1: same platform keeps the sync';
  ASSERT (SELECT v FROM out WHERE k = 'b1_switch') = 'true' AND (SELECT v FROM out WHERE k = 'b1_status')::jsonb->'link' = 'null'::jsonb,
    'B1: switching unlinks the old sync ' || (SELECT v FROM out WHERE k = 'b1_status');
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_backend_sync_claim(50) x WHERE x.event_id = pg_temp.u('0000000000e1')), 'B1: no longer synced';
  ASSERT (SELECT ticket_backend_changed_at FROM public.exos_events WHERE id = pg_temp.u('0000000000e1')) = now(), 'B1: switch stamped';
  RAISE NOTICE 'B1 ok: a switch can''t cut into live sales and drops the old door sync';
END $$;

-- B2 -------------------------------------------------------------------------
-- Opened before the switch (40 min ago, paid late): still fulfils. Opened after: fails (refunded).
INSERT INTO public.exos_checkout_sessions(session_id,event_id,tier_id,org_id,buyer_uid,buyer_email,quantity,amount_cents,status,created_at) VALUES
  ('1c-late', pg_temp.u('0000000000e1'), pg_temp.u('0000000000d1'), pg_temp.u('000000000001'), pg_temp.u('0000000000a5'), '1c-stranger@x.com', 1, 3000, 'pending', now() + interval '1 second');
INSERT INTO out VALUES ('b2_before', cardinality(public.exos_fulfill_checkout('1c-open'))::text);
INSERT INTO out VALUES ('b2_after', cardinality(public.exos_fulfill_checkout('1c-late'))::text);
-- A StubHub sale on the listing still out from before (its allocation went to 0 above).
UPDATE public.exos_distribution_listings SET requested_qty = 2, external_listing_id = '1C-SH-1' WHERE event_id = pg_temp.u('0000000000e1');
SELECT public.exos_record_marketplace_order('{"channel":"stubhub","external_order_id":"1C-1","external_listing_id":"1C-SH-1","quantity":1,"sale_status":"confirmed","buyer_email":"mkt@x.com"}');
INSERT INTO out SELECT 'b2_mkt', row_to_json(f)::text FROM public.exos_marketplace_orders m, public.exos_fulfil_marketplace_order(m.id, 'https://exos.example.test/') f
 WHERE m.external_order_id = '1C-1';
UPDATE public.exos_events SET channel_split_mode = 'auto' WHERE id = pg_temp.u('0000000000e1');
INSERT INTO out VALUES ('b2_split', public.exos_apply_channel_split(pg_temp.u('0000000000e1'))->>'reason');
SET LOCAL ROLE authenticated;
SELECT pg_temp.act('1c000000-0000-0000-0000-0000000000a2', '1c-mgr@x.com');
INSERT INTO out VALUES ('b2_mint', pg_temp.refused($$SELECT public.exos_mint_tickets(pg_temp.u('0000000000e1'), pg_temp.u('0000000000d1'), 1, NULL, 30)$$, 'sold on another site')::text);
INSERT INTO out VALUES ('b2_comp', pg_temp.refused($$SELECT * FROM public.exos_issue_comp_batch(pg_temp.u('0000000000e1'), pg_temp.u('0000000000d1'), ARRAY['g@x.com'], 1)$$, 'sold on another site')::text);
INSERT INTO out VALUES ('b2_email', pg_temp.refused($$SELECT public.exos_issue_ticket_to_email(pg_temp.u('0000000000e1'), pg_temp.u('0000000000d1'), 'g@x.com', 1)$$, 'sold on another site')::text);
INSERT INTO out VALUES ('b2_dist', pg_temp.refused($$SELECT public.exos_request_distribution(pg_temp.u('0000000000e1'), ARRAY['stubhub'])$$, 'sold on another site')::text);
INSERT INTO out VALUES ('b2_alloc', pg_temp.refused($$SELECT public.exos_set_channel_allocation(pg_temp.u('0000000000e1'), 'stubhub', pg_temp.u('0000000000d1'), 2)$$, 'sold on another site')::text);
RESET ROLE;
DO $$
DECLARE m jsonb := (SELECT v FROM out WHERE k = 'b2_mkt')::jsonb;
BEGIN
  ASSERT (SELECT v FROM out WHERE k = 'b2_before') = '1', 'B2: a session opened before the switch fulfils';
  ASSERT (SELECT v FROM out WHERE k = 'b2_after') = '0'
     AND (SELECT status || ':' || failure_reason FROM public.exos_checkout_sessions WHERE session_id = '1c-late') = 'failed:tickets for this event are now sold on another site',
    'B2: a session opened after the switch fails';
  ASSERT m->>'status' = 'needs_attention' AND m->>'reason' LIKE 'tickets for this event are sold on hievents%', 'B2: marketplace sale needs a person ' || m::text;
  ASSERT (SELECT v FROM out WHERE k = 'b2_split') = 'other-backend', 'B2: the auto split skips it';
  ASSERT (SELECT v FROM out WHERE k = 'b2_mint')::boolean AND (SELECT v FROM out WHERE k = 'b2_comp')::boolean
     AND (SELECT v FROM out WHERE k = 'b2_email')::boolean, 'B2: staff mints / comps refused';
  ASSERT (SELECT v FROM out WHERE k = 'b2_dist')::boolean AND (SELECT v FROM out WHERE k = 'b2_alloc')::boolean, 'B2: distribution refused';
  ASSERT position('exos:backend-mint' in pg_get_functiondef('public.exos_redeem_referral_reward(uuid, uuid)'::regprocedure)) > 0, 'B2: referral rewards patched';
  ASSERT (SELECT count(*) FROM public.exos_tickets WHERE event_id = pg_temp.u('0000000000e1')) = 1, 'B2: only the earlier session minted';
  RAISE NOTICE 'B2 ok: no Exos mint path sells an event another platform sells';
END $$;

SELECT 'test_org_lifecycle_p1: all passed' AS result;
ROLLBACK;
