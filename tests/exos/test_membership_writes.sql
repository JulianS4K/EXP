-- ============================================================================
-- Membership product writes + lifecycle, staff-issued memberships, imported
-- attendees, the API's commerce writes, the season-pass wallet card
-- (mig 20261102100000). Self-contained (d7… ids), rolled back at the end.
-- Org 1: owner a0, manager a1, finance a2, scanner a3; fans a5 / a6;
-- org 2: owner b0.
--   W1  grants: anon nothing; the API write is service only; staff notes are
--       staff's (column grant), the member name the holder's too
--   W2  lifecycle: draft -> published <-> unpublished -> archived; archived is
--       final; a draft can't be unpublished; old clients' active / archived_at
--       move the status; checkout's `active` and the public view follow
--   W3  save rules: owner / manager only, unknown and set-once fields refused,
--       names unique among live products, archived products not edited
--   W4  editing price / benefits never changes members; an archived product's
--       members keep their benefits
--   W5  issue: comp / import, account matched by confirmed email, claim
--       later, one live membership per product and email, archived refused
--   W6  update: rename + notes; cancel ends benefits now, reactivate; a
--       refunded one is never revived; Stripe-billed and pending gifts refused
--   W7  members page: filters, search, sort, paging; finance reads, scanner
--       and another org refused
--   W8  imported attendees: list (imports only), edit through the guest
--       rules, code normalized + unique, checked-in rows keep their code and
--       stay, synced rows refused, delete frees the place
--   W9  the API: scope re-checked, runs as the key's creator, org-pinned,
--       Idempotency-Key replays, claims put back, every write logged
--   W10 season-pass wallet card: the holder's active pass only
--   psql -d <db> -v ON_ERROR_STOP=1 -f tests/exos/test_membership_writes.sql
-- ============================================================================
\set ON_ERROR_STOP on
BEGIN;

-- auth.uid() as Supabase defines it (the JWT claims), still honouring app.uid.
CREATE OR REPLACE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql STABLE AS $$
  SELECT coalesce(nullif(current_setting('app.uid', true), ''),
                  nullif(current_setting('request.jwt.claim.sub', true), ''),
                  nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'sub')::uuid
$$;
SELECT set_config('app.uid', '', false);

INSERT INTO auth.users (id, email, email_confirmed_at) VALUES
  ('d7000000-0000-0000-0000-0000000000a0', 'd7-owner@x.com', now()),
  ('d7000000-0000-0000-0000-0000000000a1', 'd7-manager@x.com', now()),
  ('d7000000-0000-0000-0000-0000000000a2', 'd7-finance@x.com', now()),
  ('d7000000-0000-0000-0000-0000000000a3', 'd7-scanner@x.com', now()),
  ('d7000000-0000-0000-0000-0000000000a5', 'd7-fan@x.com', now()),
  ('d7000000-0000-0000-0000-0000000000a6', 'd7-other-fan@x.com', now()),
  ('d7000000-0000-0000-0000-0000000000a8', 'd7-left@x.com', now()),
  ('d7000000-0000-0000-0000-0000000000b0', 'd7-other-owner@x.com', now());
INSERT INTO public.exos_orgs (id, name, slug, owner_uid) VALUES
  ('d7000000-0000-0000-0000-000000000001', 'D7 Org', 'd7-org', 'd7000000-0000-0000-0000-0000000000a0'),
  ('d7000000-0000-0000-0000-000000000002', 'D7 Other', 'd7-other', 'd7000000-0000-0000-0000-0000000000b0');
INSERT INTO public.exos_org_memberships (org_id, user_id, role) VALUES
  ('d7000000-0000-0000-0000-000000000001', 'd7000000-0000-0000-0000-0000000000a0', 'owner'),
  ('d7000000-0000-0000-0000-000000000001', 'd7000000-0000-0000-0000-0000000000a1', 'manager'),
  ('d7000000-0000-0000-0000-000000000001', 'd7000000-0000-0000-0000-0000000000a2', 'finance'),
  ('d7000000-0000-0000-0000-000000000001', 'd7000000-0000-0000-0000-0000000000a3', 'scanner'),
  ('d7000000-0000-0000-0000-000000000001', 'd7000000-0000-0000-0000-0000000000a8', 'manager'),
  ('d7000000-0000-0000-0000-000000000002', 'd7000000-0000-0000-0000-0000000000b0', 'owner');
INSERT INTO public.exos_events (id, org_id, name, slug, status, starts_at) VALUES
  ('d7000000-0000-0000-0000-0000000000e1', 'd7000000-0000-0000-0000-000000000001', 'D7 One', 'd7-one', 'published', now() + interval '5 days'),
  ('d7000000-0000-0000-0000-0000000000e2', 'd7000000-0000-0000-0000-000000000001', 'D7 Two', 'd7-two', 'published', now() + interval '9 days'),
  ('d7000000-0000-0000-0000-0000000000e9', 'd7000000-0000-0000-0000-000000000002', 'D7 Theirs', 'd7-theirs', 'published', now() + interval '5 days');
-- Keys: k1 manager (commerce:write + tickets:write), k2 manager (commerce:read),
-- k3 org 2 owner (commerce:write), k4 a manager who leaves (commerce:write),
-- k5 finance (commerce:write: the role, not the scope, refuses).
INSERT INTO public.exos_api_keys (id, org_id, name, key_prefix, key_hash, scopes, created_by) VALUES
  ('d7000000-0000-0000-0000-0000000000f1', 'd7000000-0000-0000-0000-000000000001', 'k1', 'sk_live_d7k1', 'd7hash1',
   ARRAY['commerce:write', 'tickets:write'], 'd7000000-0000-0000-0000-0000000000a1'),
  ('d7000000-0000-0000-0000-0000000000f2', 'd7000000-0000-0000-0000-000000000001', 'k2', 'sk_live_d7k2', 'd7hash2',
   ARRAY['commerce:read'], 'd7000000-0000-0000-0000-0000000000a1'),
  ('d7000000-0000-0000-0000-0000000000f3', 'd7000000-0000-0000-0000-000000000002', 'k3', 'sk_live_d7k3', 'd7hash3',
   ARRAY['commerce:write'], 'd7000000-0000-0000-0000-0000000000b0'),
  ('d7000000-0000-0000-0000-0000000000f4', 'd7000000-0000-0000-0000-000000000001', 'k4', 'sk_live_d7k4', 'd7hash4',
   ARRAY['commerce:write'], 'd7000000-0000-0000-0000-0000000000a8'),
  ('d7000000-0000-0000-0000-0000000000f5', 'd7000000-0000-0000-0000-000000000001', 'k5', 'sk_live_d7k5', 'd7hash5',
   ARRAY['commerce:write'], 'd7000000-0000-0000-0000-0000000000a2');

CREATE FUNCTION pg_temp.act(p_uid text) RETURNS void LANGUAGE sql AS $$
  SELECT set_config('app.uid', coalesce(p_uid, ''), true);
$$;
-- The SQLSTATE a statement fails with ('ok' when it doesn't).
CREATE FUNCTION pg_temp.st(p_sql text) RETURNS text LANGUAGE plpgsql AS $$
BEGIN
  EXECUTE p_sql;
  RETURN 'ok';
EXCEPTION WHEN OTHERS THEN RETURN SQLSTATE;
END $$;
CREATE FUNCTION pg_temp.w(p_key text, p_action text, p_target text, p_args jsonb DEFAULT '{}', p_idem text DEFAULT NULL)
RETURNS jsonb LANGUAGE sql AS $$
  SELECT public.exos_api_commerce_write(('d7000000-0000-0000-0000-0000000000' || p_key)::uuid, p_action, p_target, p_args, p_idem)
$$;
CREATE FUNCTION pg_temp.wst(p_key text, p_action text, p_target text, p_args jsonb DEFAULT '{}', p_idem text DEFAULT NULL)
RETURNS text LANGUAGE plpgsql AS $$
BEGIN
  PERFORM public.exos_api_commerce_write(('d7000000-0000-0000-0000-0000000000' || p_key)::uuid, p_action, p_target, p_args, p_idem);
  RETURN 'ok';
EXCEPTION WHEN OTHERS THEN RETURN SQLSTATE;
END $$;
-- Benefits live? (as the owner: authenticated can't read whole membership rows)
CREATE FUNCTION pg_temp.live(p_id uuid) RETURNS boolean LANGUAGE sql SECURITY DEFINER AS $$
  SELECT public._exos_membership_benefits_live(m) FROM public.exos_fan_memberships m WHERE m.id = p_id
$$;
GRANT EXECUTE ON FUNCTION pg_temp.act(text), pg_temp.st(text), pg_temp.live(uuid) TO anon, authenticated, service_role;
CREATE TEMP TABLE ids (k text PRIMARY KEY, id uuid);
GRANT ALL ON ids TO anon, authenticated, service_role;

-- W1 -------------------------------------------------------------------------
DO $$
DECLARE f text;
BEGIN
  FOREACH f IN ARRAY ARRAY[
    'public.exos_membership_product_save(uuid,uuid,jsonb)', 'public.exos_membership_product_transition(uuid,text)',
    'public.exos_membership_issue(uuid,jsonb)', 'public.exos_membership_update(uuid,jsonb)',
    'public.exos_org_membership_products(uuid)',
    'public.exos_org_memberships_page(uuid,text,uuid,text,text,boolean,integer,integer)',
    'public.exos_claim_my_memberships()',
    'public.exos_org_imported_attendees(uuid,uuid,text,text,text,boolean,integer,integer)',
    'public.exos_imported_attendee_update(uuid,jsonb)', 'public.exos_imported_attendee_delete(uuid)',
    'public.exos_wallet_season_pass(uuid)', 'public.exos_api_commerce_write(uuid,text,text,jsonb,text)'] LOOP
    ASSERT NOT has_function_privilege('anon', f, 'EXECUTE'), 'W1: anon can run ' || f;
  END LOOP;
  ASSERT NOT has_function_privilege('authenticated', 'public.exos_api_commerce_write(uuid,text,text,jsonb,text)', 'EXECUTE')
     AND has_function_privilege('service_role', 'public.exos_api_commerce_write(uuid,text,text,jsonb,text)', 'EXECUTE'),
    'W1: the API write is service only';
  FOREACH f IN ARRAY ARRAY[
    'public._exos_membership_product_json(uuid)', 'public._exos_membership_admin_json(uuid)',
    'public._exos_confirmed_uid(text)', 'public._exos_imported_attendee_json(uuid)',
    'public._exos_imported_attendee_for_write(uuid)', 'public._exos_api_commerce_action_scope(text)',
    'public._exos_tg_membership_product_status()'] LOOP
    ASSERT NOT has_function_privilege('authenticated', f, 'EXECUTE'), 'W1: internal ' || f;
    ASSERT NOT has_function_privilege('anon', f, 'EXECUTE'), 'W1: internal (anon) ' || f;
  END LOOP;
  ASSERT NOT has_column_privilege('authenticated', 'public.exos_fan_memberships', 'staff_notes', 'SELECT'), 'W1: notes are staff''s';
  ASSERT NOT has_column_privilege('authenticated', 'public.exos_fan_memberships', 'issued_by', 'SELECT'), 'W1: issued_by is staff''s';
  ASSERT has_column_privilege('authenticated', 'public.exos_fan_memberships', 'member_name', 'SELECT'), 'W1: member name readable';
  ASSERT NOT has_column_privilege('authenticated', 'public.exos_fan_memberships', 'gift_token_hash', 'SELECT'), 'W1: gift hash still hidden';
  RAISE NOTICE 'OK  W1 grants';
END $$;

-- W2 + W3 ----------------------------------------------------------------------
SET ROLE authenticated;
DO $$
DECLARE r jsonb; v_id uuid; v_old uuid;
BEGIN
  PERFORM pg_temp.act('d7000000-0000-0000-0000-0000000000a1');  -- manager
  r := public.exos_membership_product_save('d7000000-0000-0000-0000-000000000001', NULL,
    '{"name":"  Gold  ","price_cents":1500,"billing":"month","discount_percent":10,"presale":true,"free_tickets_per_period":1}');
  v_id := (r->>'id')::uuid;
  INSERT INTO ids VALUES ('gold', v_id);
  ASSERT r->>'status' = 'draft' AND NOT (r->>'active')::boolean AND r->>'name' = 'Gold', 'W2: a new product is a draft: ' || r;
  ASSERT (SELECT count(*) FROM public.exos_public_membership_products WHERE id = v_id) = 0, 'W2: a draft isn''t public';
  ASSERT pg_temp.st(format('SELECT public.exos_membership_product_transition(%L, ''unpublish'')', v_id)) = '55000', 'W2: a draft can''t be unpublished';
  r := public.exos_membership_product_transition(v_id, 'publish');
  ASSERT r->>'status' = 'published' AND (r->>'active')::boolean, 'W2: published';
  ASSERT (SELECT count(*) FROM public.exos_public_membership_products WHERE id = v_id) = 1, 'W2: published is public';
  r := public.exos_membership_product_transition(v_id, 'publish');
  ASSERT r->>'status' = 'published', 'W2: publish again is a no-op';
  r := public.exos_membership_product_transition(v_id, 'unpublish');
  ASSERT r->>'status' = 'unpublished' AND NOT (r->>'active')::boolean, 'W2: unpublished';
  ASSERT (SELECT count(*) FROM public.exos_public_membership_products WHERE id = v_id) = 0, 'W2: unpublished isn''t public';
  r := public.exos_membership_product_transition(v_id, 'publish');
  ASSERT r->>'status' = 'published', 'W2: published again';
  ASSERT pg_temp.st(format('SELECT public.exos_membership_product_transition(%L, ''delete'')', v_id)) = '22023', 'W2: unknown action';

  -- Older clients (the dashboard before this migration) write active / archived_at.
  INSERT INTO public.exos_membership_products (id, org_id, name, price_cents, billing)
  VALUES ('d7000000-0000-0000-0000-00000000a0a1', 'd7000000-0000-0000-0000-000000000001', 'Legacy', 1000, 'year');
  v_old := 'd7000000-0000-0000-0000-00000000a0a1';
  ASSERT (SELECT status FROM public.exos_membership_products WHERE id = v_old) = 'published', 'W2: legacy insert (active) is published';
  UPDATE public.exos_membership_products SET active = false WHERE id = v_old;
  ASSERT (SELECT status FROM public.exos_membership_products WHERE id = v_old) = 'unpublished', 'W2: active off = unpublished';
  UPDATE public.exos_membership_products SET archived_at = now() WHERE id = v_old;
  ASSERT (SELECT status = 'archived' AND NOT active FROM public.exos_membership_products WHERE id = v_old), 'W2: archived_at = archived';
  ASSERT pg_temp.st(format('UPDATE public.exos_membership_products SET active = true WHERE id = %L', v_old)) = '55000', 'W2: archived stays (active)';
  ASSERT pg_temp.st(format('UPDATE public.exos_membership_products SET archived_at = NULL WHERE id = %L', v_old)) = '55000', 'W2: archived stays (archived_at)';
  ASSERT pg_temp.st(format('UPDATE public.exos_membership_products SET status = ''published'' WHERE id = %L', v_old)) = '55000', 'W2: archived stays (status)';
  ASSERT pg_temp.st(format('SELECT public.exos_membership_product_transition(%L, ''publish'')', v_old)) = '55000', 'W2: archived can''t be published';
  ASSERT (public.exos_membership_product_transition(v_old, 'archive'))->>'status' = 'archived', 'W2: archive again is a no-op';
  ASSERT pg_temp.st(format('UPDATE public.exos_membership_products SET status = ''draft'' WHERE id = %L', v_id)) = '55000', 'W2: never back to draft';

  -- W3
  ASSERT pg_temp.st(format('SELECT public.exos_membership_product_save(%L, %L, ''{"billing":"year"}'')',
    'd7000000-0000-0000-0000-000000000001', v_id)) = '22023', 'W3: billing is set once';
  ASSERT pg_temp.st(format('SELECT public.exos_membership_product_save(%L, %L, ''{"status":"archived"}'')',
    'd7000000-0000-0000-0000-000000000001', v_id)) = '22023', 'W3: status only through the lifecycle';
  ASSERT pg_temp.st(format('SELECT public.exos_membership_product_save(%L, %L, ''{"colour":"red"}'')',
    'd7000000-0000-0000-0000-000000000001', v_id)) = '22023', 'W3: unknown field';
  ASSERT pg_temp.st(format('SELECT public.exos_membership_product_save(%L, NULL, ''{"name":"gold","price_cents":900,"billing":"once"}'')',
    'd7000000-0000-0000-0000-000000000001')) = '23505', 'W3: name unique among live products';
  ASSERT pg_temp.st(format('SELECT public.exos_membership_product_save(%L, NULL, ''{"name":"legacy","price_cents":900,"billing":"once"}'')',
    'd7000000-0000-0000-0000-000000000001')) = 'ok', 'W3: an archived product''s name is free again';
  ASSERT pg_temp.st(format('SELECT public.exos_membership_product_save(%L, NULL, ''{"name":"No price","billing":"once"}'')',
    'd7000000-0000-0000-0000-000000000001')) = '23502', 'W3: a price is required';
  ASSERT pg_temp.st(format('SELECT public.exos_membership_product_save(%L, NULL, ''{"name":"Cheap","price_cents":10,"billing":"once"}'')',
    'd7000000-0000-0000-0000-000000000001')) = '23514', 'W3: the table''s checks apply';
  ASSERT pg_temp.st(format('SELECT public.exos_membership_product_save(%L, %L, ''{"name":"Renamed"}'')',
    'd7000000-0000-0000-0000-000000000001', v_old)) = '55000', 'W3: archived products aren''t edited';
  ASSERT pg_temp.st(format('SELECT public.exos_membership_product_save(%L, %L, ''{"name":"Nope"}'')',
    'd7000000-0000-0000-0000-000000000002', v_id)) = '42501', 'W3: another org''s staff can''t save here';
  ASSERT pg_temp.st(format('SELECT public.exos_membership_product_save(%L, %L, ''{"name":"Nope"}'')',
    'd7000000-0000-0000-0000-000000000001', 'd7000000-0000-0000-0000-00000000ffff')) = 'P0002', 'W3: unknown product';

  PERFORM pg_temp.act('d7000000-0000-0000-0000-0000000000a2');  -- finance
  ASSERT jsonb_array_length(public.exos_org_membership_products('d7000000-0000-0000-0000-000000000001')) = 3,
    'W3: finance reads the products table';
  ASSERT pg_temp.st(format('SELECT public.exos_membership_product_save(%L, %L, ''{"name":"F"}'')',
    'd7000000-0000-0000-0000-000000000001', v_id)) = '42501', 'W3: finance can''t save';
  ASSERT pg_temp.st(format('SELECT public.exos_membership_product_transition(%L, ''archive'')', v_id)) = 'P0002', 'W3: finance can''t archive';
  PERFORM pg_temp.act('d7000000-0000-0000-0000-0000000000b0');  -- other org
  ASSERT pg_temp.st(format('SELECT public.exos_membership_product_transition(%L, ''archive'')', v_id)) = 'P0002', 'W3: other org: not found';
  ASSERT pg_temp.st(format('SELECT public.exos_org_membership_products(%L)', 'd7000000-0000-0000-0000-000000000001')) = '42501', 'W3: other org: no table';
  PERFORM pg_temp.act('d7000000-0000-0000-0000-0000000000a3');  -- scanner
  ASSERT pg_temp.st(format('SELECT public.exos_org_membership_products(%L)', 'd7000000-0000-0000-0000-000000000001')) = '42501', 'W3: scanner: no table';
  RAISE NOTICE 'OK  W2 lifecycle';
  RAISE NOTICE 'OK  W3 save rules';
END $$;

-- W4 + W5 ----------------------------------------------------------------------
DO $$
DECLARE r jsonb; g uuid := (SELECT id FROM ids WHERE k = 'gold'); m1 uuid; m2 uuid; v_ben jsonb; n int;
BEGIN
  PERFORM pg_temp.act('d7000000-0000-0000-0000-0000000000a1');  -- manager
  r := public.exos_membership_issue('d7000000-0000-0000-0000-000000000001',
    jsonb_build_object('product_id', g, 'email', ' D7-Fan@X.com ', 'member_name', 'Dee Fan', 'staff_notes', 'VIP comp'));
  m1 := (r->>'id')::uuid;
  INSERT INTO ids VALUES ('m1', m1);
  ASSERT r->>'status' = 'active' AND r->>'source' = 'comp' AND (r->>'has_account')::boolean
     AND r->>'holder_email' = 'd7-fan@x.com' AND r->>'billing' = 'once' AND NOT (r->>'stripe_billed')::boolean,
    'W5: comp issued to the matching account: ' || r;
  ASSERT (r->>'current_period_end')::timestamptz BETWEEN now() + interval '27 days' AND now() + interval '32 days', 'W5: one period of the product';
  ASSERT (r->'benefits'->>'discount_percent')::numeric = 10, 'W5: the product''s benefits';
  ASSERT pg_temp.st(format('SELECT public.exos_membership_issue(%L, %L)', 'd7000000-0000-0000-0000-000000000001',
    jsonb_build_object('product_id', g, 'email', 'd7-fan@x.com'))) = '23505', 'W5: one live membership per product and email';
  ASSERT pg_temp.st(format('SELECT public.exos_membership_issue(%L, %L)', 'd7000000-0000-0000-0000-000000000001',
    jsonb_build_object('product_id', g, 'email', 'nope'))) = '22023', 'W5: bad email';
  ASSERT pg_temp.st(format('SELECT public.exos_membership_issue(%L, %L)', 'd7000000-0000-0000-0000-000000000001',
    jsonb_build_object('product_id', g, 'email', 'x@y.com', 'expires_at', now() - interval '1 day'))) = '22023', 'W5: past end refused';
  ASSERT pg_temp.st(format('SELECT public.exos_membership_issue(%L, %L)', 'd7000000-0000-0000-0000-000000000001',
    jsonb_build_object('product_id', g, 'email', 'x@y.com', 'source', 'purchase'))) = '22023', 'W5: staff can''t fake a purchase';
  ASSERT pg_temp.st(format('SELECT public.exos_membership_issue(%L, %L)', 'd7000000-0000-0000-0000-000000000001',
    jsonb_build_object('product_id', 'd7000000-0000-0000-0000-00000000a0a1', 'email', 'x@y.com'))) = '55000', 'W5: archived product refused';
  ASSERT pg_temp.st(format('SELECT public.exos_membership_issue(%L, %L)', 'd7000000-0000-0000-0000-000000000002',
    jsonb_build_object('product_id', g, 'email', 'x@y.com'))) = '42501', 'W5: not this manager''s org';
  -- No account yet: held for the email, claimed on sign-up.
  r := public.exos_membership_issue('d7000000-0000-0000-0000-000000000001',
    jsonb_build_object('product_id', g, 'email', 'd7-later@x.com', 'source', 'import', 'expires_at', now() + interval '200 days'));
  m2 := (r->>'id')::uuid;
  INSERT INTO ids VALUES ('m2', m2);
  ASSERT NOT (r->>'has_account')::boolean AND r->>'source' = 'import', 'W5: import held for the email';

  PERFORM pg_temp.act('d7000000-0000-0000-0000-0000000000a2');  -- finance
  ASSERT pg_temp.st(format('SELECT public.exos_membership_issue(%L, %L)', 'd7000000-0000-0000-0000-000000000001',
    jsonb_build_object('product_id', g, 'email', 'x@y.com'))) = '42501', 'W5: finance can''t issue';

  -- W4: product edits don't touch members.
  PERFORM pg_temp.act('d7000000-0000-0000-0000-0000000000a1');
  SELECT benefits INTO v_ben FROM public.exos_fan_memberships WHERE id = m1;
  PERFORM public.exos_membership_product_save('d7000000-0000-0000-0000-000000000001', g,
    '{"price_cents":2500,"discount_percent":40,"free_tickets_per_period":0}');
  ASSERT (SELECT price_cents FROM public.exos_membership_products WHERE id = g) = 2500, 'W4: new price for new members';
  ASSERT (SELECT benefits FROM public.exos_fan_memberships WHERE id = m1) = v_ben, 'W4: members keep their benefits';
  ASSERT (public.exos_membership_product_transition(g, 'archive'))->>'status' = 'archived', 'W4: archive a sold product';
  ASSERT pg_temp.st(format('DELETE FROM public.exos_membership_products WHERE id = %L', g)) = '23503', 'W4: a sold product isn''t deleted';
  ASSERT pg_temp.live(m1), 'W4: members of an archived product keep benefits';
  RAISE NOTICE 'OK  W4 product edits leave members alone';
END $$;
RESET ROLE;
-- The held import is claimed once the account exists (confirmed email only).
INSERT INTO auth.users (id, email, email_confirmed_at) VALUES
  ('d7000000-0000-0000-0000-0000000000a7', 'd7-later@x.com', now());
SET ROLE authenticated;
DO $$
DECLARE m2 uuid := (SELECT id FROM ids WHERE k = 'm2');
BEGIN
  PERFORM pg_temp.act('d7000000-0000-0000-0000-0000000000a6');
  ASSERT public.exos_claim_my_memberships() = 0, 'W5: someone else claims nothing';
  PERFORM pg_temp.act('d7000000-0000-0000-0000-0000000000a7');
  ASSERT public.exos_claim_my_memberships() = 1, 'W5: claimed';
  ASSERT (SELECT holder_uid FROM public.exos_fan_memberships WHERE id = m2) = 'd7000000-0000-0000-0000-0000000000a7', 'W5: holder set';
  ASSERT (SELECT count(*) FROM public.exos_my_memberships() WHERE id = m2) = 1, 'W5: in my memberships';
  ASSERT (SELECT member_name IS NULL FROM public.exos_fan_memberships WHERE id = m2), 'W5: the holder reads the name column';
  ASSERT pg_temp.st(format('SELECT staff_notes FROM public.exos_fan_memberships WHERE id = %L', m2)) = '42501', 'W5: not the notes';
  RAISE NOTICE 'OK  W5 issue + claim';
END $$;
RESET ROLE;

-- W6 -------------------------------------------------------------------------
-- Fixtures: a refunded purchase, a Stripe-billed one, a pending gift.
INSERT INTO public.exos_fan_memberships (id, org_id, product_id, product_name, billing, holder_uid, holder_email, status,
  current_period_start, current_period_end, benefits, source, ended_reason, stripe_subscription_id, gift) VALUES
  ('d7000000-0000-0000-0000-00000000c001', 'd7000000-0000-0000-0000-000000000001', 'd7000000-0000-0000-0000-00000000a0a1',
   'Legacy', 'once', 'd7000000-0000-0000-0000-0000000000a6', 'd7-other-fan@x.com', 'cancelled', now() - interval '5 days', now(),
   '{}', 'purchase', 'refunded', NULL, NULL),
  ('d7000000-0000-0000-0000-00000000c002', 'd7000000-0000-0000-0000-000000000001', 'd7000000-0000-0000-0000-00000000a0a1',
   'Legacy', 'month', 'd7000000-0000-0000-0000-0000000000a6', 'd7-other-fan@x.com', 'active', now(), now() + interval '20 days',
   '{}', 'purchase', NULL, 'sub_d7billed', NULL),
  ('d7000000-0000-0000-0000-00000000c003', 'd7000000-0000-0000-0000-000000000001', 'd7000000-0000-0000-0000-00000000a0a1',
   'Legacy', 'once', NULL, 'd7-gift@x.com', 'pending', NULL, NULL, '{"term":"1 year"}', 'gift', NULL, NULL, '{"status":"pending"}');
SET ROLE authenticated;
DO $$
DECLARE r jsonb; m1 uuid := (SELECT id FROM ids WHERE k = 'm1');
BEGIN
  PERFORM pg_temp.act('d7000000-0000-0000-0000-0000000000a0');  -- owner
  r := public.exos_membership_update(m1, '{"member_name":"Dee F.","staff_notes":"moved from the old system"}');
  ASSERT r->>'member_name' = 'Dee F.' AND r->>'staff_notes' = 'moved from the old system' AND r->>'status' = 'active', 'W6: renamed';
  r := public.exos_membership_update(m1, '{"status":"cancelled"}');
  ASSERT r->>'status' = 'cancelled' AND (r->>'current_period_end')::timestamptz <= now(), 'W6: cancelled now';
  ASSERT NOT pg_temp.live(m1), 'W6: benefits end';
  ASSERT pg_temp.st(format('SELECT public.exos_membership_update(%L, ''{"status":"active"}'')', m1)) = '22023', 'W6: active needs a future end';
  r := public.exos_membership_update(m1, jsonb_build_object('status', 'active', 'expires_at', now() + interval '60 days'));
  ASSERT r->>'status' = 'active' AND pg_temp.live(m1),
    'W6: a comp can be reactivated';
  ASSERT pg_temp.st(format('SELECT public.exos_membership_update(%L, ''{"status":"past_due"}'')', m1)) = '22023', 'W6: staff statuses only';
  ASSERT pg_temp.st(format('SELECT public.exos_membership_update(%L, ''{"holder_email":"a@b.co"}'')', m1)) = '22023', 'W6: email is read-only';
  ASSERT pg_temp.st(format('SELECT public.exos_membership_update(%L, ''{"status":"active","expires_at":"2099-01-01"}'')',
    'd7000000-0000-0000-0000-00000000c001')) = '55000', 'W6: a refunded membership is never revived';
  ASSERT (public.exos_membership_update('d7000000-0000-0000-0000-00000000c001', '{"staff_notes":"refunded at the door"}'))->>'status' = 'cancelled',
    'W6: notes on a refunded one are fine, the status stays';
  ASSERT (SELECT ended_reason FROM public.exos_fan_memberships WHERE id = 'd7000000-0000-0000-0000-00000000c001') = 'refunded', 'W6: ended_reason kept';
  ASSERT pg_temp.st(format('SELECT public.exos_membership_update(%L, ''{"status":"cancelled"}'')',
    'd7000000-0000-0000-0000-00000000c002')) = '55000', 'W6: Stripe-billed: through Stripe';
  ASSERT pg_temp.st(format('SELECT public.exos_membership_update(%L, %L)', 'd7000000-0000-0000-0000-00000000c002',
    jsonb_build_object('expires_at', now() + interval '1 year'))) = '55000', 'W6: Stripe-billed period mirrors Stripe';
  ASSERT pg_temp.st(format('SELECT public.exos_membership_update(%L, ''{"status":"active"}'')',
    'd7000000-0000-0000-0000-00000000c003')) = '55000', 'W6: a pending gift is the gift functions''';
  PERFORM pg_temp.act('d7000000-0000-0000-0000-0000000000a2');  -- finance
  ASSERT pg_temp.st(format('SELECT public.exos_membership_update(%L, ''{"member_name":"x"}'')', m1)) = 'P0002', 'W6: finance can''t edit';
  PERFORM pg_temp.act('d7000000-0000-0000-0000-0000000000b0');
  ASSERT pg_temp.st(format('SELECT public.exos_membership_update(%L, ''{"member_name":"x"}'')', m1)) = 'P0002', 'W6: other org: not found';
  RAISE NOTICE 'OK  W6 update';
END $$;

-- W7 -------------------------------------------------------------------------
DO $$
DECLARE r jsonb;
BEGIN
  PERFORM pg_temp.act('d7000000-0000-0000-0000-0000000000a2');  -- finance reads
  r := public.exos_org_memberships_page('d7000000-0000-0000-0000-000000000001');
  ASSERT (r->>'total')::int = 5 AND jsonb_array_length(r->'rows') = 5, 'W7: every membership: ' || (r->>'total');
  r := public.exos_org_memberships_page('d7000000-0000-0000-0000-000000000001', 'active');
  ASSERT (r->>'total')::int = 3, 'W7: active filter (effective): ' || (r->>'total');
  r := public.exos_org_memberships_page('d7000000-0000-0000-0000-000000000001', NULL, NULL, 'later');
  ASSERT (r->>'total')::int = 1 AND r->'rows'->0->>'holder_email' = 'd7-later@x.com', 'W7: search';
  r := public.exos_org_memberships_page('d7000000-0000-0000-0000-000000000001', NULL, NULL, '%');
  ASSERT (r->>'total')::int = 0, 'W7: wildcards are literal';
  r := public.exos_org_memberships_page('d7000000-0000-0000-0000-000000000001', NULL, NULL, NULL, 'holder_email', false, 2, 0);
  ASSERT (r->>'total')::int = 5 AND jsonb_array_length(r->'rows') = 2 AND r->'rows'->0->>'holder_email' = 'd7-fan@x.com', 'W7: sorted, paged: ' || r;
  r := public.exos_org_memberships_page('d7000000-0000-0000-0000-000000000001', NULL, NULL, NULL, 'holder_email', false, 2, 4);
  ASSERT jsonb_array_length(r->'rows') = 1 AND r->'rows'->0->>'holder_email' = 'd7-other-fan@x.com', 'W7: last page';
  r := public.exos_org_memberships_page('d7000000-0000-0000-0000-000000000001', NULL, 'd7000000-0000-0000-0000-00000000a0a1');
  ASSERT (r->>'total')::int = 3, 'W7: product filter';
  ASSERT pg_temp.st(format('SELECT public.exos_org_memberships_page(%L, NULL, NULL, NULL, ''created_at'', true, 500)',
    'd7000000-0000-0000-0000-000000000001')) = '22023', 'W7: limit capped';
  PERFORM pg_temp.act('d7000000-0000-0000-0000-0000000000a3');
  ASSERT pg_temp.st(format('SELECT public.exos_org_memberships_page(%L)', 'd7000000-0000-0000-0000-000000000001')) = '42501', 'W7: scanner refused';
  PERFORM pg_temp.act('d7000000-0000-0000-0000-0000000000b0');
  ASSERT pg_temp.st(format('SELECT public.exos_org_memberships_page(%L)', 'd7000000-0000-0000-0000-000000000001')) = '42501', 'W7: other org refused';
  RAISE NOTICE 'OK  W7 members page';
END $$;
RESET ROLE;

-- W8 -------------------------------------------------------------------------
INSERT INTO public.exos_guest_lists (id, event_id, org_id, name, counts_toward_capacity) VALUES
  ('d7000000-0000-0000-0000-00000000b001', 'd7000000-0000-0000-0000-0000000000e1', 'd7000000-0000-0000-0000-000000000001', 'Imported from Posh', true),
  ('d7000000-0000-0000-0000-00000000b009', 'd7000000-0000-0000-0000-0000000000e9', 'd7000000-0000-0000-0000-000000000002', 'Theirs', false);
SET ROLE authenticated;
DO $$
DECLARE r jsonb; a uuid; b uuid; c uuid; v_sold int;
BEGIN
  PERFORM pg_temp.act('d7000000-0000-0000-0000-0000000000a1');  -- manager
  r := public.exos_import_guests('d7000000-0000-0000-0000-00000000b001', '[
    {"name":"Ann Import","email":"ann@x.com","code":"po sh-001","ticket":"GA","source":"Posh"},
    {"name":"Bob Import","code":"POSH-002","ticket":"GA","source":"Posh"},
    {"name":"Cat Import","code":"POSH-003","source":"Posh"}]');
  ASSERT (r->>'inserted')::int = 3, 'W8: imported';
  PERFORM public.exos_add_guest('d7000000-0000-0000-0000-00000000b001', 'Hand Added', NULL, NULL, 0, NULL);
  r := public.exos_org_imported_attendees('d7000000-0000-0000-0000-000000000001', NULL, NULL, NULL, 'guest_name', false);
  ASSERT (r->>'total')::int = 3 AND r->'rows'->0->>'guest_name' = 'Ann Import' AND r->'rows'->0->>'code' = 'POSH-001',
    'W8: imports only, sorted: ' || r;
  r := public.exos_org_imported_attendees('d7000000-0000-0000-0000-000000000001', NULL, 'posh', 'posh-00', 'guest_name', true, 1, 0);
  ASSERT (r->>'total')::int = 3 AND r->'rows'->0->>'guest_name' = 'Cat Import', 'W8: search by code, page of one';
  SELECT (x->>'id')::uuid INTO a FROM jsonb_array_elements((public.exos_org_imported_attendees('d7000000-0000-0000-0000-000000000001'))->'rows') x WHERE x->>'guest_name' = 'Ann Import';
  SELECT (x->>'id')::uuid INTO b FROM jsonb_array_elements((public.exos_org_imported_attendees('d7000000-0000-0000-0000-000000000001'))->'rows') x WHERE x->>'guest_name' = 'Bob Import';
  SELECT (x->>'id')::uuid INTO c FROM jsonb_array_elements((public.exos_org_imported_attendees('d7000000-0000-0000-0000-000000000001'))->'rows') x WHERE x->>'guest_name' = 'Cat Import';
  INSERT INTO ids VALUES ('att_a', a), ('att_b', b), ('att_c', c);

  r := public.exos_imported_attendee_update(a, '{"guest_name":"Ann Renamed","code":" posh 0001 ","ticket_label":"VIP","plus_ones":1}');
  ASSERT r->>'guest_name' = 'Ann Renamed' AND r->>'code' = 'POSH0001' AND r->>'ticket_label' = 'VIP'
     AND (r->>'plus_ones')::int = 1 AND r->>'email' = 'ann@x.com', 'W8: edited, code normalized, email kept: ' || r;
  ASSERT pg_temp.st(format('SELECT public.exos_imported_attendee_update(%L, ''{"code":"POSH-002"}'')', a)) = '23505', 'W8: code unique per event';
  ASSERT pg_temp.st(format('SELECT public.exos_imported_attendee_update(%L, ''{"plus_ones":99}'')', a)) = '23514', 'W8: the list''s plus-one rule';
  ASSERT pg_temp.st(format('SELECT public.exos_imported_attendee_update(%L, ''{"source":""}'')', a)) = '22023', 'W8: source can''t be blanked';
  ASSERT pg_temp.st(format('SELECT public.exos_imported_attendee_update(%L, ''{"arrived":1}'')', a)) = '22023', 'W8: arrivals are the door''s';
  ASSERT pg_temp.st(format('SELECT public.exos_imported_attendee_update(%L, ''{"guest_name":"x"}'')',
    (SELECT id FROM public.exos_guest_list_entries WHERE guest_name = 'Hand Added'))) = 'P0002', 'W8: a hand-added guest isn''t an import';
  RAISE NOTICE 'OK  W8a imported attendees: list + edit';
END $$;
RESET ROLE;
-- Bob arrived at the door; Cat is synced from Eventbrite.
UPDATE public.exos_guest_list_entries SET arrived = 1, arrived_at = now() WHERE id = (SELECT id FROM ids WHERE k = 'att_b');
UPDATE public.exos_guest_list_entries SET external_ref = 'eb:123' WHERE id = (SELECT id FROM ids WHERE k = 'att_c');
INSERT INTO public.exos_guest_list_entries (id, list_id, event_id, org_id, guest_name, external_code, source) VALUES
  ('d7000000-0000-0000-0000-00000000b999', 'd7000000-0000-0000-0000-00000000b009', 'd7000000-0000-0000-0000-0000000000e9',
   'd7000000-0000-0000-0000-000000000002', 'Their Guest', 'T-1', 'Posh');
SET ROLE authenticated;
DO $$
DECLARE r jsonb; a uuid := (SELECT id FROM ids WHERE k = 'att_a'); b uuid := (SELECT id FROM ids WHERE k = 'att_b');
        c uuid := (SELECT id FROM ids WHERE k = 'att_c');
BEGIN
  PERFORM pg_temp.act('d7000000-0000-0000-0000-0000000000a1');
  ASSERT pg_temp.st(format('SELECT public.exos_imported_attendee_update(%L, ''{"code":"NEW"}'')', b)) = '55000', 'W8: an arrived party keeps its code';
  ASSERT (public.exos_imported_attendee_update(b, '{"note":"came early"}'))->>'note' = 'came early', 'W8: other fields still edit';
  ASSERT pg_temp.st(format('SELECT public.exos_imported_attendee_delete(%L)', b)) = '55000', 'W8: an arrived party stays';
  ASSERT pg_temp.st(format('SELECT public.exos_imported_attendee_update(%L, ''{"guest_name":"x"}'')', c)) = '55000', 'W8: synced rows: edit on the source';
  ASSERT pg_temp.st(format('SELECT public.exos_imported_attendee_delete(%L)', c)) = '55000', 'W8: synced rows aren''t deleted here';
  ASSERT pg_temp.st(format('SELECT public.exos_imported_attendee_delete(%L)', 'd7000000-0000-0000-0000-00000000b999')) = 'P0002', 'W8: other org: not found';
  r := public.exos_imported_attendee_delete(a);
  ASSERT (r->>'deleted')::boolean AND NOT EXISTS (SELECT 1 FROM public.exos_guest_list_entries WHERE id = a), 'W8: deleted';
  PERFORM pg_temp.act('d7000000-0000-0000-0000-0000000000a2');
  ASSERT pg_temp.st(format('SELECT public.exos_org_imported_attendees(%L)', 'd7000000-0000-0000-0000-000000000001')) = '42501', 'W8: finance doesn''t list guests';
  ASSERT pg_temp.st(format('SELECT public.exos_imported_attendee_delete(%L)', b)) = 'P0002', 'W8: finance can''t delete';
  RAISE NOTICE 'OK  W8b imported attendees: arrived, synced, delete, roles';
END $$;
RESET ROLE;

-- W9 -------------------------------------------------------------------------
SET ROLE service_role;
DO $$
DECLARE r jsonb; r2 jsonb; v_id uuid; n int;
BEGIN
  PERFORM pg_temp.act(NULL);
  r := pg_temp.w('f1', 'membership_product.create', NULL, '{"name":"API Plus","price_cents":3000,"billing":"year"}', 'idem-d7-0001');
  v_id := (r->>'id')::uuid;
  INSERT INTO ids VALUES ('api_prod', v_id);
  ASSERT r->>'status' = 'draft', 'W9: created as a draft';
  ASSERT (SELECT org_id = 'd7000000-0000-0000-0000-000000000001' AND created_by = 'd7000000-0000-0000-0000-0000000000a1'
            FROM public.exos_membership_products WHERE id = v_id), 'W9: key''s org, run as its creator';
  r2 := pg_temp.w('f1', 'membership_product.create', NULL, '{"name":"API Plus","price_cents":3000,"billing":"year"}', 'idem-d7-0001');
  ASSERT (r2->>'id')::uuid = v_id AND (r2->>'idempotent_replay')::boolean, 'W9: replayed';
  ASSERT (SELECT count(*) FROM public.exos_membership_products WHERE name = 'API Plus') = 1, 'W9: one product';
  ASSERT pg_temp.wst('f1', 'membership_product.publish', v_id::text, '{}', 'idem-d7-0001') = '22023', 'W9: key reused elsewhere';
  ASSERT (pg_temp.w('f1', 'membership_product.publish', v_id::text))->>'status' = 'published', 'W9: publish';
  ASSERT (pg_temp.w('f1', 'membership_product.update', v_id::text, '{"description":"More"}'))->>'description' = 'More', 'W9: update';
  ASSERT (pg_temp.w('f1', 'membership_product.unpublish', v_id::text))->>'status' = 'unpublished', 'W9: unpublish';
  r := pg_temp.w('f1', 'membership.issue', NULL, ('{"product_id":"' || v_id || '","email":"d7-api@x.com","source":"import"}')::jsonb);
  ASSERT r->>'status' = 'active' AND (r->>'issued_by')::uuid = 'd7000000-0000-0000-0000-0000000000a1', 'W9: issued as the creator';
  ASSERT (pg_temp.w('f1', 'membership.update', r->>'id', '{"member_name":"API Member"}'))->>'member_name' = 'API Member', 'W9: membership update';
  ASSERT (pg_temp.w('f1', 'membership_product.archive', v_id::text))->>'status' = 'archived', 'W9: archive';
  ASSERT pg_temp.wst('f1', 'membership_product.publish', v_id::text) = '55000', 'W9: archived is final over the API too';
  ASSERT pg_temp.wst('f2', 'membership_product.create', NULL, '{"name":"R","price_cents":3000,"billing":"year"}') = '42501', 'W9: read scope can''t write';
  ASSERT pg_temp.wst('f2', 'migrated_attendee.delete', (SELECT id FROM ids WHERE k = 'att_b')::text) = '42501', 'W9: needs tickets:write';
  ASSERT pg_temp.wst('f3', 'membership_product.update', v_id::text, '{"name":"Mine"}') = 'P0002', 'W9: another org''s product is not found';
  ASSERT pg_temp.wst('f3', 'membership.update', (SELECT id FROM ids WHERE k = 'm1')::text, '{"member_name":"x"}') = 'P0002', 'W9: another org''s membership';
  ASSERT pg_temp.wst('f1', 'membership_product.update', 'not-a-uuid', '{}') = 'P0002', 'W9: bad id is not found';
  ASSERT pg_temp.wst('f5', 'membership_product.create', NULL, '{"name":"Fin","price_cents":3000,"billing":"year"}') = '42501', 'W9: the creator''s role decides';
  ASSERT pg_temp.wst('f1', 'membership_product.delete', v_id::text) = '22023', 'W9: unknown action';
  ASSERT (pg_temp.w('f1', 'migrated_attendee.update', (SELECT id FROM ids WHERE k = 'att_b')::text, '{"phone":"555-0100"}'))->>'phone' = '555-0100',
    'W9: imported attendee update';
  ASSERT current_setting('request.jwt.claim.sub', true) IS DISTINCT FROM 'd7000000-0000-0000-0000-0000000000a1', 'W9: claims put back';
  SELECT count(*) INTO n FROM public.exos_api_writes WHERE api_key_id = 'd7000000-0000-0000-0000-0000000000f1';
  ASSERT n = 8, 'W9: every write logged once: ' || n;
  RAISE NOTICE 'OK  W9a API writes';
END $$;
RESET ROLE;
UPDATE public.exos_org_memberships SET disabled = true WHERE user_id = 'd7000000-0000-0000-0000-0000000000a8';
SET ROLE service_role;
DO $$
BEGIN
  ASSERT pg_temp.wst('f4', 'membership_product.create', NULL, '{"name":"Gone","price_cents":3000,"billing":"year"}') = '42501',
    'W9: a key whose creator left can''t write';
  RAISE NOTICE 'OK  W9b a departed creator''s key';
END $$;
RESET ROLE;

-- W10 ------------------------------------------------------------------------
INSERT INTO public.exos_passes (id, org_id, kind, name, holder_uid, holder_email, credits_total, credits_used, per_event_limit,
  eligibility, valid_until, status) VALUES
  ('d7000000-0000-0000-0000-00000000f001', 'd7000000-0000-0000-0000-000000000001', 'season', 'Fall season',
   'd7000000-0000-0000-0000-0000000000a5', 'd7-fan@x.com', 2, 0, 1,
   '{"event_ids":["d7000000-0000-0000-0000-0000000000e1","d7000000-0000-0000-0000-0000000000e2","d7000000-0000-0000-0000-0000000000e9"]}',
   now() + interval '60 days', 'active'),
  ('d7000000-0000-0000-0000-00000000f002', 'd7000000-0000-0000-0000-000000000001', 'flex', '5-pack',
   'd7000000-0000-0000-0000-0000000000a5', 'd7-fan@x.com', 5, 5, NULL, '{}', NULL, 'active'),
  ('d7000000-0000-0000-0000-00000000f003', 'd7000000-0000-0000-0000-000000000001', 'flex', 'Voided pack',
   'd7000000-0000-0000-0000-0000000000a5', 'd7-fan@x.com', 5, 0, NULL, '{}', NULL, 'voided');
SET ROLE authenticated;
DO $$
DECLARE r jsonb;
BEGIN
  PERFORM pg_temp.act('d7000000-0000-0000-0000-0000000000a5');
  r := public.exos_wallet_season_pass('d7000000-0000-0000-0000-00000000f001');
  ASSERT (r->>'ok')::boolean AND r->'payload'->>'serial' = 'sp-d7000000-0000-0000-0000-00000000f001'
     AND r->'payload'->>'org_name' = 'D7 Org' AND (r->'payload'->>'credits_total')::int = 2, 'W10: the holder''s card: ' || r;
  ASSERT jsonb_array_length(r->'payload'->'events') = 2, 'W10: only the org''s own events are named';
  ASSERT NOT (r->'payload') ? 'holder_email' AND NOT (r->'payload') ? 'price_cents', 'W10: holder-safe';
  ASSERT (public.exos_wallet_season_pass('d7000000-0000-0000-0000-00000000f002'))->>'reason' = 'wallet_pass_unavailable', 'W10: used up';
  ASSERT (public.exos_wallet_season_pass('d7000000-0000-0000-0000-00000000f003'))->>'reason' = 'wallet_pass_unavailable', 'W10: voided';
  PERFORM pg_temp.act('d7000000-0000-0000-0000-0000000000a6');
  ASSERT (public.exos_wallet_season_pass('d7000000-0000-0000-0000-00000000f001'))->>'reason' = 'record_not_found', 'W10: not someone else''s';
  PERFORM pg_temp.act(NULL);
  ASSERT pg_temp.st(format('SELECT public.exos_wallet_season_pass(%L)', 'd7000000-0000-0000-0000-00000000f001')) = '42501', 'W10: signed in only';
  RAISE NOTICE 'OK  W10 season-pass wallet card';
END $$;
RESET ROLE;

ROLLBACK;
