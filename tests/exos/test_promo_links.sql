-- ============================================================================
-- Promo links (mig 20261016110000).
--   P1 create: owner / manager (scanner refused); label and limit checked;
--      the voucher never jumps sold-out
--   P2 list: finance sees links with visits and redemptions; plain vouchers
--      aren't listed
--   P3 hits: anon counts a visit on a link code only (any case); unknown /
--      plain codes change nothing and the call answers nothing
--   P4 the limit is the voucher's: check reports exhausted once used up
-- Self-contained ids 5f…; runs after the full run_p0.sh chain.
-- ============================================================================
\set ON_ERROR_STOP on
BEGIN;

INSERT INTO auth.users(id,email,email_confirmed_at) VALUES
  ('5f000000-0000-0000-0000-0000000000a1','plown@x.com',now()),
  ('5f000000-0000-0000-0000-0000000000a3','plfin@x.com',now()),
  ('5f000000-0000-0000-0000-0000000000a4','plscan@x.com',now()),
  ('5f000000-0000-0000-0000-0000000000b1','plfan@x.com',now());
INSERT INTO public.exos_orgs(id,name,slug,owner_uid) VALUES
  ('5f000000-0000-0000-0000-000000000001','PL Org','pl-org-stub','5f000000-0000-0000-0000-0000000000a1');
INSERT INTO public.exos_org_memberships(org_id,user_id,role) VALUES
  ('5f000000-0000-0000-0000-000000000001','5f000000-0000-0000-0000-0000000000a1','owner'),
  ('5f000000-0000-0000-0000-000000000001','5f000000-0000-0000-0000-0000000000a3','finance'),
  ('5f000000-0000-0000-0000-000000000001','5f000000-0000-0000-0000-0000000000a4','scanner');
INSERT INTO public.exos_events(id,org_id,name,slug,status,starts_at,timezone,total_tickets,tickets_sold,created_by) VALUES
  ('5f000000-0000-0000-0000-0000000000e1','5f000000-0000-0000-0000-000000000001','PL One','pl-one','published',now() + interval '9 days','America/New_York',100,0,'5f000000-0000-0000-0000-0000000000a1');
INSERT INTO public.exos_ticket_tiers(id,event_id,name,price,capacity,sold,visibility) VALUES
  ('5f000000-0000-0000-0000-0000000000d1','5f000000-0000-0000-0000-0000000000e1','GA',30,100,0,'public');

CREATE FUNCTION pg_temp.act(p_uid text) RETURNS void LANGUAGE sql AS $$
  SELECT set_config('app.uid', coalesce(p_uid, ''), true), set_config('app.jwt', '', true);
$$;
GRANT EXECUTE ON FUNCTION pg_temp.act(text) TO anon, authenticated;
CREATE FUNCTION pg_temp.u(p text) RETURNS uuid LANGUAGE sql IMMUTABLE AS $$ SELECT ('5f000000-0000-0000-0000-' || p)::uuid $$;
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

-- P1 ----------------------------------------------------------------------
SET LOCAL ROLE authenticated;
SELECT pg_temp.act('5f000000-0000-0000-0000-0000000000a4');
SELECT set_config('pl.scan', pg_temp.refused($$SELECT public.exos_create_promo_link(pg_temp.u('0000000000e1'), 'IG', 'instagram', 10)$$, '')::text, true);
SELECT pg_temp.act('5f000000-0000-0000-0000-0000000000a1');
SELECT set_config('pl.nolabel', pg_temp.refused($$SELECT public.exos_create_promo_link(pg_temp.u('0000000000e1'), ' ', 'instagram', 10)$$, 'give the link a name')::text, true);
SELECT set_config('pl.badch', pg_temp.refused($$SELECT public.exos_create_promo_link(pg_temp.u('0000000000e1'), 'IG', 'Insta Gram', 10)$$, 'channel')::text, true);
SELECT set_config('pl.nolimit', pg_temp.refused($$SELECT public.exos_create_promo_link(pg_temp.u('0000000000e1'), 'IG', 'instagram', 0)$$, 'limit')::text, true);
SELECT set_config('pl.c1', public.exos_create_promo_link(pg_temp.u('0000000000e1'), 'Instagram story', 'Instagram', 2, 48, 'IGSTORY', 20, NULL, NULL), true);
SELECT set_config('pl.c2', public.exos_create_promo_link(pg_temp.u('0000000000e1'), 'SMS blast', 'sms', 50), true);
SELECT public.exos_issue_voucher(pg_temp.u('0000000000e1'), NULL, NULL, true, NULL, 1, NULL, 'plain', 'PLAIN1');
SELECT pg_temp.act('5f000000-0000-0000-0000-0000000000a3');
SELECT set_config('pl.list', (SELECT json_agg(x ORDER BY x.label)::text FROM public.exos_promo_links(pg_temp.u('0000000000e1')) x), true);
RESET ROLE;
DO $$
DECLARE l jsonb := current_setting('pl.list')::jsonb; v public.exos_vouchers%ROWTYPE;
BEGIN
  ASSERT current_setting('pl.scan')::boolean, 'P1: scanner refused';
  ASSERT current_setting('pl.nolabel')::boolean AND current_setting('pl.badch')::boolean AND current_setting('pl.nolimit')::boolean, 'P1: checks';
  ASSERT current_setting('pl.c1') = 'IGSTORY', 'P1: chosen code';
  SELECT * INTO v FROM public.exos_vouchers WHERE code = 'IGSTORY' AND event_id = pg_temp.u('0000000000e1');
  ASSERT v.link_channel = 'instagram' AND v.max_uses = 2 AND v.discount_percent = 20 AND NOT v.bypass_capacity, 'P1: voucher ' || row_to_json(v)::text;
  ASSERT v.valid_until > now() + interval '47 hours', 'P1: expiry';
  ASSERT jsonb_array_length(l) = 2, 'P2: only promo links, got ' || l::text;
  ASSERT l->0->>'label' = 'Instagram story' AND (l->0->>'clicks')::int = 0 AND (l->0->>'used')::int = 0, 'P2: row';
END $$;

-- P3 ----------------------------------------------------------------------
SET LOCAL ROLE anon;
SELECT pg_temp.act(NULL);
SELECT public.exos_promo_link_hit(pg_temp.u('0000000000e1'), 'igstory');
SELECT public.exos_promo_link_hit(pg_temp.u('0000000000e1'), 'IGSTORY');
SELECT public.exos_promo_link_hit(pg_temp.u('0000000000e1'), 'PLAIN1');
SELECT public.exos_promo_link_hit(pg_temp.u('0000000000e1'), 'NOPE');
RESET ROLE;
DO $$
BEGIN
  ASSERT (SELECT link_clicks FROM public.exos_vouchers WHERE code = 'IGSTORY') = 2, 'P3: two visits, any case';
  ASSERT (SELECT link_clicks FROM public.exos_vouchers WHERE code = 'PLAIN1') = 0, 'P3: plain vouchers untouched';
  ASSERT has_function_privilege('anon', 'public.exos_promo_link_hit(uuid, text)', 'EXECUTE'), 'P3: anon may count';
  ASSERT NOT has_function_privilege('anon', 'public.exos_promo_links(uuid)', 'EXECUTE'), 'P3: anon can''t list';
  ASSERT NOT has_function_privilege('anon', 'public.exos_create_promo_link(uuid, text, text, integer, integer, text, numeric, numeric, uuid)', 'EXECUTE'), 'P3: anon can''t create';
END $$;

-- P4 ----------------------------------------------------------------------
UPDATE public.exos_vouchers SET used_count = 2 WHERE code = 'IGSTORY';
SET LOCAL ROLE authenticated;
SELECT pg_temp.act('5f000000-0000-0000-0000-0000000000b1');
SELECT set_config('pl.chk', (SELECT row_to_json(r)::text FROM public.exos_check_voucher(pg_temp.u('0000000000e1'), 'IGSTORY', 'plfan@x.com') r), true);
RESET ROLE;
DO $$
BEGIN
  ASSERT NOT (current_setting('pl.chk')::jsonb->>'is_valid')::boolean, 'P4: used up ' || current_setting('pl.chk');
END $$;

\echo 'test_promo_links: all passed'
ROLLBACK;
