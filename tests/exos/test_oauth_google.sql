-- ============================================================================
-- Connect Google Ads (mig 20260930102000). Self-contained (af prefix), rolled
-- back. Needs tests/exos/prereq_vault.sql and mig 20260930100000.
--   G1 objects exist; no client role touches the state table or runs the
--      OAuth RPCs; definer functions pin search_path
--   G2 begin: owner / manager only (finance, scanner, disabled, other org
--      refused); bad hash / provider refused; 10-minute expiry; per-user cap
--   G3 return: parks the code once; unknown / expired / used states give
--      NULL; an error return consumes the state
--   G4 consume: only the starting user, once, before expiry, with a code,
--      while still owner / manager; clears the stored code
--   G5 token store: Vault secret named exos_ad:<org>:google_ads (the same
--      name exos_set_ad_credential uses), ids / enabled / test code kept,
--      update in place on reconnect, listed as has_secret, handed to the
--      drain's claim; role re-checked
-- ============================================================================
\set ON_ERROR_STOP on
BEGIN;
INSERT INTO auth.users(id,email,email_confirmed_at) VALUES
  ('af000000-0000-0000-0000-0000000000a0','af-owner@x.com',now()),
  ('af000000-0000-0000-0000-0000000000a1','af-finance@x.com',now()),
  ('af000000-0000-0000-0000-0000000000a2','af-scanner@x.com',now()),
  ('af000000-0000-0000-0000-0000000000a3','af-manager@x.com',now()),
  ('af000000-0000-0000-0000-0000000000a4','af-disabled@x.com',now()),
  ('af000000-0000-0000-0000-0000000000c0','af-other@x.com',now());
INSERT INTO public.exos_orgs(id,name,slug,owner_uid) VALUES
  ('af000000-0000-0000-0000-000000000001','AF Org','af-org','af000000-0000-0000-0000-0000000000a0'),
  ('af000000-0000-0000-0000-000000000002','AF Other','af-other','af000000-0000-0000-0000-0000000000c0');
INSERT INTO public.exos_org_memberships(org_id,user_id,role,disabled) VALUES
  ('af000000-0000-0000-0000-000000000001','af000000-0000-0000-0000-0000000000a0','owner',false),
  ('af000000-0000-0000-0000-000000000001','af000000-0000-0000-0000-0000000000a1','finance',false),
  ('af000000-0000-0000-0000-000000000001','af000000-0000-0000-0000-0000000000a2','scanner',false),
  ('af000000-0000-0000-0000-000000000001','af000000-0000-0000-0000-0000000000a3','manager',false),
  ('af000000-0000-0000-0000-000000000001','af000000-0000-0000-0000-0000000000a4','manager',true),
  ('af000000-0000-0000-0000-000000000002','af000000-0000-0000-0000-0000000000c0','owner',false);

CREATE OR REPLACE FUNCTION pg_temp.sqlstate_of(p_sql text) RETURNS text LANGUAGE plpgsql AS $$
BEGIN
  EXECUTE p_sql;
  RETURN '';
EXCEPTION WHEN OTHERS THEN
  RETURN SQLSTATE;
END $$;
GRANT EXECUTE ON FUNCTION pg_temp.sqlstate_of(text) TO anon, authenticated, service_role;
-- A fake state hash per label.
CREATE OR REPLACE FUNCTION pg_temp.h(p text) RETURNS text LANGUAGE sql IMMUTABLE AS $$
  SELECT encode(sha256(convert_to('af-state-' || p, 'UTF8')), 'hex')
$$;
GRANT EXECUTE ON FUNCTION pg_temp.h(text) TO anon, authenticated, service_role;

-- G1 -------------------------------------------------------------------------
DO $$
DECLARE r text; f text;
BEGIN
  ASSERT to_regclass('public.exos_oauth_states') IS NOT NULL, 'G1: state table missing';
  ASSERT (SELECT relrowsecurity FROM pg_class WHERE oid = 'public.exos_oauth_states'::regclass), 'G1: RLS off';
  FOREACH r IN ARRAY ARRAY['anon','authenticated'] LOOP
    ASSERT NOT has_table_privilege(r, 'public.exos_oauth_states', 'SELECT,INSERT,UPDATE,DELETE'), 'G1: ' || r || ' touches states';
    FOREACH f IN ARRAY ARRAY[
      'public.exos_oauth_state_begin(text,uuid,uuid,text,integer)',
      'public.exos_oauth_state_return(text,text)',
      'public.exos_oauth_state_consume(text,uuid)',
      'public.exos_set_google_ads_token(uuid,uuid,text)',
      'public._exos_oauth_can_connect(uuid,uuid)'] LOOP
      ASSERT NOT has_function_privilege(r, f, 'EXECUTE'), 'G1: ' || r || ' runs ' || f;
    END LOOP;
  END LOOP;
  ASSERT has_function_privilege('service_role', 'public.exos_oauth_state_begin(text,uuid,uuid,text,integer)', 'EXECUTE'), 'G1: service role cannot begin';
  ASSERT has_function_privilege('service_role', 'public.exos_set_google_ads_token(uuid,uuid,text)', 'EXECUTE'), 'G1: service role cannot store';
  SELECT string_agg(p.proname, ', ') INTO r FROM pg_proc p
   WHERE p.pronamespace = 'public'::regnamespace AND p.prosecdef
     AND p.proname IN ('exos_oauth_state_begin','exos_oauth_state_return','exos_oauth_state_consume',
                       'exos_set_google_ads_token','_exos_oauth_can_connect')
     AND NOT coalesce(array_to_string(p.proconfig, ',') LIKE '%search_path=public, pg_temp%', false);
  ASSERT r IS NULL, 'G1: search_path not pinned: ' || r;
  RAISE NOTICE 'OK  G1 states and OAuth RPCs are service role only';
END $$;

-- A signed-in owner can't reach any of it directly either.
SET LOCAL ROLE authenticated;
SELECT set_config('app.uid', 'af000000-0000-0000-0000-0000000000a0', true);
DO $$
BEGIN
  ASSERT pg_temp.sqlstate_of('SELECT 1 FROM public.exos_oauth_states') = '42501', 'G1: owner read states';
  ASSERT pg_temp.sqlstate_of($q$SELECT public.exos_oauth_state_begin('google_ads','af000000-0000-0000-0000-000000000001','af000000-0000-0000-0000-0000000000a0',pg_temp.h('x'))$q$) = '42501', 'G1: owner began directly';
  ASSERT pg_temp.sqlstate_of($q$SELECT public.exos_set_google_ads_token('af000000-0000-0000-0000-000000000001','af000000-0000-0000-0000-0000000000a0','1//refresh-token')$q$) = '42501', 'G1: owner stored directly';
END $$;
RESET ROLE;

-- G2 -------------------------------------------------------------------------
SET LOCAL ROLE service_role;
DO $$
DECLARE v_exp timestamptz; n int;
BEGIN
  v_exp := public.exos_oauth_state_begin('google_ads', 'af000000-0000-0000-0000-000000000001',
                                         'af000000-0000-0000-0000-0000000000a0', pg_temp.h('owner'));
  ASSERT v_exp BETWEEN now() + interval '9 minutes' AND now() + interval '10 minutes', 'G2: expiry not 10 min';
  -- A longer TTL is capped at 10 minutes.
  v_exp := public.exos_oauth_state_begin('google_ads', 'af000000-0000-0000-0000-000000000001',
                                         'af000000-0000-0000-0000-0000000000a3', pg_temp.h('manager'), 600);
  ASSERT v_exp <= now() + interval '10 minutes', 'G2: TTL not capped';
  ASSERT (SELECT count(*) FROM public.exos_oauth_states WHERE org_id = 'af000000-0000-0000-0000-000000000001') = 2, 'G2: two states';
  ASSERT pg_temp.sqlstate_of($q$SELECT public.exos_oauth_state_begin('google_ads','af000000-0000-0000-0000-000000000001','af000000-0000-0000-0000-0000000000a1',pg_temp.h('fin'))$q$) = '42501', 'G2: finance began';
  ASSERT pg_temp.sqlstate_of($q$SELECT public.exos_oauth_state_begin('google_ads','af000000-0000-0000-0000-000000000001','af000000-0000-0000-0000-0000000000a2',pg_temp.h('scan'))$q$) = '42501', 'G2: scanner began';
  ASSERT pg_temp.sqlstate_of($q$SELECT public.exos_oauth_state_begin('google_ads','af000000-0000-0000-0000-000000000001','af000000-0000-0000-0000-0000000000a4',pg_temp.h('dis'))$q$) = '42501', 'G2: disabled manager began';
  ASSERT pg_temp.sqlstate_of($q$SELECT public.exos_oauth_state_begin('google_ads','af000000-0000-0000-0000-000000000002','af000000-0000-0000-0000-0000000000a0',pg_temp.h('xorg'))$q$) = '42501', 'G2: owner of another org began';
  ASSERT pg_temp.sqlstate_of($q$SELECT public.exos_oauth_state_begin('google_ads','af000000-0000-0000-0000-000000000001',NULL,pg_temp.h('nouser'))$q$) = '42501', 'G2: no user began';
  ASSERT pg_temp.sqlstate_of($q$SELECT public.exos_oauth_state_begin('meta','af000000-0000-0000-0000-000000000001','af000000-0000-0000-0000-0000000000a0',pg_temp.h('meta'))$q$) = '22023', 'G2: other provider';
  ASSERT pg_temp.sqlstate_of($q$SELECT public.exos_oauth_state_begin('google_ads','af000000-0000-0000-0000-000000000001','af000000-0000-0000-0000-0000000000a0','not-a-hash')$q$) = '22023', 'G2: raw state stored';
  -- The same hash twice is refused (primary key).
  ASSERT pg_temp.sqlstate_of($q$SELECT public.exos_oauth_state_begin('google_ads','af000000-0000-0000-0000-000000000001','af000000-0000-0000-0000-0000000000a0',pg_temp.h('owner'))$q$) = '23505', 'G2: duplicate state';
  -- Per-user cap: 10 in 10 minutes (the owner has 1).
  FOR n IN 1..9 LOOP
    PERFORM public.exos_oauth_state_begin('google_ads', 'af000000-0000-0000-0000-000000000001',
                                          'af000000-0000-0000-0000-0000000000a0', pg_temp.h('cap' || n));
  END LOOP;
  ASSERT pg_temp.sqlstate_of($q$SELECT public.exos_oauth_state_begin('google_ads','af000000-0000-0000-0000-000000000001','af000000-0000-0000-0000-0000000000a0',pg_temp.h('cap10'))$q$) = '54000', 'G2: cap not enforced';
  -- Stale rows (a day past expiry) are cleaned up on the next begin.
  UPDATE public.exos_oauth_states SET created_at = now() - interval '2 days', expires_at = now() - interval '2 days'
   WHERE state_hash IN (SELECT pg_temp.h('cap' || i) FROM generate_series(1, 9) i);
  PERFORM public.exos_oauth_state_begin('google_ads', 'af000000-0000-0000-0000-000000000001',
                                        'af000000-0000-0000-0000-0000000000a0', pg_temp.h('after-cleanup'));
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_oauth_states WHERE state_hash = pg_temp.h('cap1')), 'G2: stale row kept';
  RAISE NOTICE 'OK  G2 begin: owner / manager only, hashed, 10-minute expiry, capped';
END $$;

-- G3 -------------------------------------------------------------------------
DO $$
DECLARE v uuid;
BEGIN
  v := public.exos_oauth_state_return(pg_temp.h('owner'), '4/0AcodeFromGoogle');
  ASSERT v = 'af000000-0000-0000-0000-000000000001', 'G3: return gave no org';
  ASSERT (SELECT code FROM public.exos_oauth_states WHERE state_hash = pg_temp.h('owner')) = '4/0AcodeFromGoogle', 'G3: code not parked';
  -- A second return (replayed redirect) doesn't overwrite the code.
  ASSERT public.exos_oauth_state_return(pg_temp.h('owner'), '4/0Aattacker-code') IS NULL, 'G3: second return accepted';
  ASSERT (SELECT code FROM public.exos_oauth_states WHERE state_hash = pg_temp.h('owner')) = '4/0AcodeFromGoogle', 'G3: code overwritten';
  ASSERT public.exos_oauth_state_return(pg_temp.h('unknown'), '4/0Acode12345') IS NULL, 'G3: unknown state';
  ASSERT public.exos_oauth_state_return('bad', '4/0Acode12345') IS NULL, 'G3: malformed hash';
  -- Expired.
  PERFORM public.exos_oauth_state_begin('google_ads', 'af000000-0000-0000-0000-000000000001',
                                        'af000000-0000-0000-0000-0000000000a3', pg_temp.h('late'));
  UPDATE public.exos_oauth_states SET expires_at = now() - interval '1 second' WHERE state_hash = pg_temp.h('late');
  ASSERT public.exos_oauth_state_return(pg_temp.h('late'), '4/0Acode12345') IS NULL, 'G3: expired state accepted';
  -- An error return (declined) consumes the state and still names the org.
  PERFORM public.exos_oauth_state_begin('google_ads', 'af000000-0000-0000-0000-000000000001',
                                        'af000000-0000-0000-0000-0000000000a3', pg_temp.h('declined'));
  ASSERT public.exos_oauth_state_return(pg_temp.h('declined'), NULL) = 'af000000-0000-0000-0000-000000000001', 'G3: declined gave no org';
  ASSERT (SELECT consumed_at IS NOT NULL AND code IS NULL FROM public.exos_oauth_states WHERE state_hash = pg_temp.h('declined')), 'G3: declined not consumed';
  -- A value with spaces is not a code: treated as an error return.
  PERFORM public.exos_oauth_state_begin('google_ads', 'af000000-0000-0000-0000-000000000001',
                                        'af000000-0000-0000-0000-0000000000a3', pg_temp.h('junk'));
  PERFORM public.exos_oauth_state_return(pg_temp.h('junk'), 'not a code');
  ASSERT (SELECT consumed_at IS NOT NULL AND code IS NULL FROM public.exos_oauth_states WHERE state_hash = pg_temp.h('junk')), 'G3: junk code parked';
  RAISE NOTICE 'OK  G3 return parks the code once; bad states give NULL';
END $$;

-- G4 -------------------------------------------------------------------------
DO $$
DECLARE r record; n int;
BEGIN
  -- Someone else (even a manager of the same org) can't use the owner's state.
  SELECT count(*) INTO n FROM public.exos_oauth_state_consume(pg_temp.h('owner'), 'af000000-0000-0000-0000-0000000000a3');
  ASSERT n = 0, 'G4: another user consumed';
  ASSERT (SELECT consumed_at IS NULL FROM public.exos_oauth_states WHERE state_hash = pg_temp.h('owner')), 'G4: another user burned the state';
  SELECT * INTO r FROM public.exos_oauth_state_consume(pg_temp.h('owner'), 'af000000-0000-0000-0000-0000000000a0');
  ASSERT r.org_id = 'af000000-0000-0000-0000-000000000001' AND r.code = '4/0AcodeFromGoogle', 'G4: owner consume';
  ASSERT (SELECT consumed_at IS NOT NULL AND code IS NULL FROM public.exos_oauth_states WHERE state_hash = pg_temp.h('owner')), 'G4: code kept after consume';
  SELECT count(*) INTO n FROM public.exos_oauth_state_consume(pg_temp.h('owner'), 'af000000-0000-0000-0000-0000000000a0');
  ASSERT n = 0, 'G4: consumed twice';
  -- No code yet (Google never returned): refused, and the state is burned.
  SELECT count(*) INTO n FROM public.exos_oauth_state_consume(pg_temp.h('manager'), 'af000000-0000-0000-0000-0000000000a3');
  ASSERT n = 0, 'G4: consumed without a code';
  ASSERT public.exos_oauth_state_return(pg_temp.h('manager'), '4/0Acode12345') IS NULL, 'G4: burned state took a code';
  -- Expired between return and finish.
  PERFORM public.exos_oauth_state_begin('google_ads', 'af000000-0000-0000-0000-000000000001',
                                        'af000000-0000-0000-0000-0000000000a3', pg_temp.h('slow'));
  PERFORM public.exos_oauth_state_return(pg_temp.h('slow'), '4/0Acode12345');
  UPDATE public.exos_oauth_states SET expires_at = now() - interval '1 second' WHERE state_hash = pg_temp.h('slow');
  SELECT count(*) INTO n FROM public.exos_oauth_state_consume(pg_temp.h('slow'), 'af000000-0000-0000-0000-0000000000a3');
  ASSERT n = 0, 'G4: expired consume';
  ASSERT (SELECT code IS NULL FROM public.exos_oauth_states WHERE state_hash = pg_temp.h('slow')), 'G4: expired code kept';
END $$;
-- Demoted between start and finish (the membership change needs the owner role).
RESET ROLE;
DO $$
DECLARE n int;
BEGIN
  PERFORM public.exos_oauth_state_begin('google_ads', 'af000000-0000-0000-0000-000000000001',
                                        'af000000-0000-0000-0000-0000000000a3', pg_temp.h('demoted'));
  PERFORM public.exos_oauth_state_return(pg_temp.h('demoted'), '4/0Acode12345');
  UPDATE public.exos_org_memberships SET role = 'finance'
   WHERE org_id = 'af000000-0000-0000-0000-000000000001' AND user_id = 'af000000-0000-0000-0000-0000000000a3';
  SELECT count(*) INTO n FROM public.exos_oauth_state_consume(pg_temp.h('demoted'), 'af000000-0000-0000-0000-0000000000a3');
  ASSERT n = 0, 'G4: demoted user consumed';
  UPDATE public.exos_org_memberships SET role = 'manager'
   WHERE org_id = 'af000000-0000-0000-0000-000000000001' AND user_id = 'af000000-0000-0000-0000-0000000000a3';
  RAISE NOTICE 'OK  G4 consume: starting user only, once, before expiry, still owner / manager';
END $$;

-- G5 -------------------------------------------------------------------------
-- As the migration owner from here: the checks read Vault, which only the
-- definer functions can (G1 covers the service role's grants).
RESET ROLE;
DO $$
DECLARE j jsonb; v_id uuid; v_id2 uuid; n int;
BEGIN
  -- New row: token saved, off, no ids.
  j := public.exos_set_google_ads_token('af000000-0000-0000-0000-000000000001',
                                        'af000000-0000-0000-0000-0000000000a0', '1//first-refresh-token');
  ASSERT (j->>'has_secret')::boolean AND NOT (j->>'enabled')::boolean, 'G5: first save';
  ASSERT position('1//first' in j::text) = 0, 'G5: token returned';
  SELECT secret_id INTO v_id FROM public.exos_org_ad_credentials
   WHERE org_id = 'af000000-0000-0000-0000-000000000001' AND platform = 'google_ads';
  ASSERT (SELECT name FROM vault.secrets WHERE id = v_id) = 'exos_ad:af000000-0000-0000-0000-000000000001:google_ads', 'G5: Vault name';
  ASSERT (SELECT decrypted_secret FROM vault.decrypted_secrets WHERE id = v_id) = '1//first-refresh-token', 'G5: Vault value';
  ASSERT (SELECT config = '{}'::jsonb AND NOT enabled FROM public.exos_org_ad_credentials
           WHERE org_id = 'af000000-0000-0000-0000-000000000001' AND platform = 'google_ads'), 'G5: new row not blank/off';
  -- Bad tokens / roles.
  ASSERT pg_temp.sqlstate_of($q$SELECT public.exos_set_google_ads_token('af000000-0000-0000-0000-000000000001','af000000-0000-0000-0000-0000000000a0','has space here')$q$) = '22023', 'G5: spaced token';
  ASSERT pg_temp.sqlstate_of($q$SELECT public.exos_set_google_ads_token('af000000-0000-0000-0000-000000000001','af000000-0000-0000-0000-0000000000a0',NULL)$q$) = '22023', 'G5: null token';
  ASSERT pg_temp.sqlstate_of($q$SELECT public.exos_set_google_ads_token('af000000-0000-0000-0000-000000000001','af000000-0000-0000-0000-0000000000a1','1//finance-token')$q$) = '42501', 'G5: finance stored';
  ASSERT pg_temp.sqlstate_of($q$SELECT public.exos_set_google_ads_token('af000000-0000-0000-0000-000000000002','af000000-0000-0000-0000-0000000000a0','1//cross-org-token')$q$) = '42501', 'G5: cross-org stored';
END $$;
RESET ROLE;

-- The owner adds ids and turns it on through the normal RPC (NULL keeps the token).
SET LOCAL ROLE authenticated;
SELECT set_config('app.uid', 'af000000-0000-0000-0000-0000000000a0', true);
SELECT public.exos_set_ad_credential('af000000-0000-0000-0000-000000000001', 'google_ads',
       '{"customer_id":"1234567890","conversion_action_id":"987654"}', NULL, true, 'validate');
DO $$
DECLARE v record;
BEGIN
  SELECT * INTO v FROM public.exos_list_ad_credentials('af000000-0000-0000-0000-000000000001') WHERE platform = 'google_ads';
  ASSERT v.has_secret AND v.enabled AND v.config ? 'customer_id', 'G5: list after connect';
END $$;
RESET ROLE;

-- Reconnect: same Vault secret updated in place; ids, switch and test code kept.
DO $$
DECLARE v_id uuid; v_id2 uuid; n int; r record;
BEGIN
  SELECT secret_id INTO v_id FROM public.exos_org_ad_credentials
   WHERE org_id = 'af000000-0000-0000-0000-000000000001' AND platform = 'google_ads';
  PERFORM public.exos_set_google_ads_token('af000000-0000-0000-0000-000000000001',
                                           'af000000-0000-0000-0000-0000000000a3', '1//second-refresh-token');
  SELECT secret_id INTO v_id2 FROM public.exos_org_ad_credentials
   WHERE org_id = 'af000000-0000-0000-0000-000000000001' AND platform = 'google_ads';
  ASSERT v_id = v_id2, 'G5: reconnect made a new secret';
  ASSERT (SELECT decrypted_secret FROM vault.decrypted_secrets WHERE id = v_id) = '1//second-refresh-token', 'G5: reconnect value';
  SELECT count(*) INTO n FROM vault.secrets WHERE name LIKE 'exos_ad:af000000-0000-0000-0000-000000000001:%';
  ASSERT n = 1, 'G5: extra Vault secrets ' || n;
  ASSERT (SELECT enabled AND test_event_code = 'validate' AND config->>'customer_id' = '1234567890'
            AND updated_by = 'af000000-0000-0000-0000-0000000000a3'
            FROM public.exos_org_ad_credentials
           WHERE org_id = 'af000000-0000-0000-0000-000000000001' AND platform = 'google_ads'), 'G5: reconnect lost settings';

  -- The drain's claim hands the refresh token over for a queued Google Ads row.
  INSERT INTO public.exos_marketing_conversions (org_id, platform, event_name, event_id_dedupe, occurred_at,
                                                 value_cents, currency, payload)
  VALUES ('af000000-0000-0000-0000-000000000001', 'google_ads', 'Purchase', 'cs_test_af_1', now(), 5000, 'usd',
          '{"transaction_id":"cs_test_af_1","ad_ids":{"gclid":"Cj0KCQ"}}');
  SELECT * INTO r FROM public.exos_conversions_claim_batch(50, 6, 10) WHERE event_id_dedupe = 'cs_test_af_1';
  ASSERT r.secret = '1//second-refresh-token' AND r.enabled, 'G5: claim did not hand over the refresh token';
  RAISE NOTICE 'OK  G5 token store: Vault exos_ad:<org>:google_ads, settings kept, claim hands it over';
END $$;
RESET ROLE;

ROLLBACK;
