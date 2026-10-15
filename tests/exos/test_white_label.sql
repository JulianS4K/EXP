-- ============================================================================
-- White-label (mig 20261016130000).
--   W1 site: owner / manager save; shape checks (types, sizes, https links)
--   W2 domains: add (normalized, token), refused (bad, ours, another org's,
--      a 4th); list; verify -> public view; remove; grants
-- Self-contained ids 61…; runs after the full run_p0.sh chain.
-- ============================================================================
\set ON_ERROR_STOP on
BEGIN;

INSERT INTO auth.users(id,email,email_confirmed_at) VALUES
  ('61000000-0000-0000-0000-0000000000a1','wlown@x.com',now()),
  ('61000000-0000-0000-0000-0000000000a3','wlfin@x.com',now()),
  ('61000000-0000-0000-0000-0000000000a9','wlother@x.com',now());
INSERT INTO public.exos_orgs(id,name,slug,owner_uid) VALUES
  ('61000000-0000-0000-0000-000000000001','WL Hall','wl-hall','61000000-0000-0000-0000-0000000000a1'),
  ('61000000-0000-0000-0000-000000000002','WL Other','wl-other','61000000-0000-0000-0000-0000000000a9');
INSERT INTO public.exos_org_memberships(org_id,user_id,role) VALUES
  ('61000000-0000-0000-0000-000000000001','61000000-0000-0000-0000-0000000000a1','owner'),
  ('61000000-0000-0000-0000-000000000001','61000000-0000-0000-0000-0000000000a3','finance'),
  ('61000000-0000-0000-0000-000000000002','61000000-0000-0000-0000-0000000000a9','owner');

CREATE FUNCTION pg_temp.act(p_uid text) RETURNS void LANGUAGE sql AS $$
  SELECT set_config('app.uid', coalesce(p_uid, ''), true), set_config('app.jwt', '', true);
$$;
GRANT EXECUTE ON FUNCTION pg_temp.act(text) TO anon, authenticated;
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

-- W1 ----------------------------------------------------------------------
SET LOCAL ROLE authenticated;
SELECT pg_temp.act('61000000-0000-0000-0000-0000000000a3');
SELECT set_config('wl.fin', pg_temp.refused($$SELECT public.exos_set_org_site('61000000-0000-0000-0000-000000000001', '{"sections":[]}')$$, 'owner or manager')::text, true);
SELECT pg_temp.act('61000000-0000-0000-0000-0000000000a1');
SELECT public.exos_set_org_site('61000000-0000-0000-0000-000000000001', $j${"sections":[
  {"type":"hero","title":"WL Hall","subtitle":"Live music, Bushwick","image":"https://cdn.x/h.jpg","button_url":"https://x.com/tix"},
  {"type":"events","title":"Upcoming"},
  {"type":"faq","items":[{"q":"Age?","a":"21+"}]},
  {"type":"links","items":[{"label":"Instagram","url":"https://instagram.com/wl"}]}]}$j$);
SELECT set_config('wl.badtype', pg_temp.refused($$SELECT public.exos_set_org_site('61000000-0000-0000-0000-000000000001', '{"sections":[{"type":"script","x":"1"}]}')$$, 'unknown section')::text, true);
SELECT set_config('wl.badurl', pg_temp.refused($$SELECT public.exos_set_org_site('61000000-0000-0000-0000-000000000001', '{"sections":[{"type":"hero","image":"javascript:alert(1)"}]}')$$, 'https link')::text, true);
SELECT set_config('wl.baditem', pg_temp.refused($$SELECT public.exos_set_org_site('61000000-0000-0000-0000-000000000001', '{"sections":[{"type":"links","items":[{"label":"x","url":"http://x"}]}]}')$$, 'bad item')::text, true);
SELECT set_config('wl.badnum', pg_temp.refused($$SELECT public.exos_set_org_site('61000000-0000-0000-0000-000000000001', '{"sections":[{"type":"text","body":5}]}')$$, 'must be text')::text, true);
RESET ROLE;
DO $$
BEGIN
  ASSERT current_setting('wl.fin')::boolean, 'W1: finance refused';
  ASSERT current_setting('wl.badtype')::boolean AND current_setting('wl.badurl')::boolean
     AND current_setting('wl.baditem')::boolean AND current_setting('wl.badnum')::boolean, 'W1: shape checks';
  ASSERT jsonb_array_length((SELECT site->'sections' FROM public.exos_orgs WHERE id = '61000000-0000-0000-0000-000000000001')) = 4, 'W1: saved';
END $$;

-- W2 ----------------------------------------------------------------------
SET LOCAL ROLE authenticated;
SELECT pg_temp.act('61000000-0000-0000-0000-0000000000a1');
SELECT set_config('wl.add', public.exos_add_org_domain('61000000-0000-0000-0000-000000000001', 'https://Tickets.WLHall.com/')::text, true);
SELECT set_config('wl.bad', pg_temp.refused($$SELECT public.exos_add_org_domain('61000000-0000-0000-0000-000000000001', 'not a domain')$$, 'like tickets')::text, true);
SELECT set_config('wl.ours', pg_temp.refused($$SELECT public.exos_add_org_domain('61000000-0000-0000-0000-000000000001', 'x.onrender.com')$$, 'you own')::text, true);
SELECT public.exos_add_org_domain('61000000-0000-0000-0000-000000000001', 'b.wlhall.com');
SELECT public.exos_add_org_domain('61000000-0000-0000-0000-000000000001', 'c.wlhall.com');
SELECT set_config('wl.four', pg_temp.refused($$SELECT public.exos_add_org_domain('61000000-0000-0000-0000-000000000001', 'd.wlhall.com')$$, 'at most 3')::text, true);
SELECT set_config('wl.list', (SELECT count(*)::text FROM public.exos_list_org_domains('61000000-0000-0000-0000-000000000001')), true);
SELECT pg_temp.act('61000000-0000-0000-0000-0000000000a9');
SELECT set_config('wl.steal', pg_temp.refused($$SELECT public.exos_add_org_domain('61000000-0000-0000-0000-000000000002', 'tickets.wlhall.com')$$, 'another organizer')::text, true);
RESET ROLE;
DO $$
DECLARE a jsonb := current_setting('wl.add')::jsonb;
BEGIN
  ASSERT a->>'domain' = 'tickets.wlhall.com' AND a->>'status' = 'pending' AND a->>'txt_name' = '_exos-verify.tickets.wlhall.com'
     AND length(a->>'txt_value') = 32, 'W2: added ' || a::text;
  ASSERT current_setting('wl.bad')::boolean AND current_setting('wl.ours')::boolean AND current_setting('wl.four')::boolean
     AND current_setting('wl.steal')::boolean, 'W2: refusals';
  ASSERT current_setting('wl.list')::int = 3, 'W2: list';
  ASSERT (SELECT count(*) FROM public.exos_public_org_domains WHERE domain = 'tickets.wlhall.com') = 0, 'W2: pending not public';
  ASSERT public.exos_org_domain_token('61000000-0000-0000-0000-000000000001', 'tickets.wlhall.com') = a->>'txt_value', 'W2: token';
  ASSERT public.exos_mark_org_domain('tickets.wlhall.com', true), 'W2: mark';
  ASSERT (SELECT org_slug FROM public.exos_public_org_domains WHERE domain = 'tickets.wlhall.com') = 'wl-hall', 'W2: public once verified';
  ASSERT has_table_privilege('anon', 'public.exos_public_org_domains', 'SELECT'), 'W2: anon reads the view';
  ASSERT NOT has_table_privilege('anon', 'public.exos_org_domains', 'SELECT'), 'W2: not the table (tokens)';
  ASSERT NOT has_function_privilege('authenticated', 'public.exos_org_domain_token(uuid, text)', 'EXECUTE'), 'W2: token is service-only';
END $$;
SET LOCAL ROLE authenticated;
SELECT pg_temp.act('61000000-0000-0000-0000-0000000000a1');
SELECT set_config('wl.rm', public.exos_remove_org_domain('61000000-0000-0000-0000-000000000001', 'c.wlhall.com')::text, true);
RESET ROLE;
DO $$ BEGIN ASSERT current_setting('wl.rm')::boolean, 'W2: removed'; END $$;

\echo 'test_white_label: all passed'
ROLLBACK;
