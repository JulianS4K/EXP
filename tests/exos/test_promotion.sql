-- ============================================================================
-- Promotion (mig 20261121153700).
--   PR1 channels: the_skint, allevents, fever, nonsense_nyc (no URL), spotify,
--       partiful (NYC) seeded as manual; songkick moved to the bottom; every channel listed
--       by exos_discovery_event_channels, songkick last
--   PR2 placements: owner / manager add (slug from the name, -2 / -3 on a
--       clash, whitespace collapsed); bad names refused; finance reads but
--       can't add; scanner / other org / anon refused
--   PR3 remove: writer only; another org refused
--   PR4 the 200 cap
--   PR5 RLS on, no client grant on the table
--   PR6 _exos_channel_key: google + paid_search is Google ads; partiful its
--       own key, labelled Partiful; the old mappings and labels unchanged
--       (cpc, qr / print, meta paid_social, organic)
--   PR7 grants + search_path on the new functions
--   PR8 an event that moves orgs: its new owner lists, adds and removes the
--       placements; the old org can't (authorized through the event, not
--       the org_id stamped at insert); add takes no lock on exos_events
-- Self-contained ids b7160000-…; runs after the full run_p0.sh chain.
-- ============================================================================
\set ON_ERROR_STOP on
BEGIN;

INSERT INTO auth.users(id,email,email_confirmed_at) VALUES
  ('b7160000-0000-0000-0000-0000000000a1','prown@x.com',now()),
  ('b7160000-0000-0000-0000-0000000000a2','prman@x.com',now()),
  ('b7160000-0000-0000-0000-0000000000a3','prfin@x.com',now()),
  ('b7160000-0000-0000-0000-0000000000a4','prscan@x.com',now()),
  ('b7160000-0000-0000-0000-0000000000a5','prother@x.com',now());
INSERT INTO public.exos_orgs(id,name,slug,owner_uid) VALUES
  ('b7160000-0000-0000-0000-000000000001','PR Org','pr-org','b7160000-0000-0000-0000-0000000000a1'),
  ('b7160000-0000-0000-0000-000000000002','PR Other','pr-other','b7160000-0000-0000-0000-0000000000a5');
INSERT INTO public.exos_org_memberships(org_id,user_id,role) VALUES
  ('b7160000-0000-0000-0000-000000000001','b7160000-0000-0000-0000-0000000000a1','owner'),
  ('b7160000-0000-0000-0000-000000000001','b7160000-0000-0000-0000-0000000000a2','manager'),
  ('b7160000-0000-0000-0000-000000000001','b7160000-0000-0000-0000-0000000000a3','finance'),
  ('b7160000-0000-0000-0000-000000000001','b7160000-0000-0000-0000-0000000000a4','scanner'),
  ('b7160000-0000-0000-0000-000000000002','b7160000-0000-0000-0000-0000000000a5','owner');
INSERT INTO public.exos_events(id,org_id,name,slug,status,starts_at,timezone,venue_name,total_tickets,tickets_sold,created_by) VALUES
  ('b7160000-0000-0000-0000-0000000000e1','b7160000-0000-0000-0000-000000000001','PR Show','pr-show','published',now() + interval '9 days','America/New_York','Elsewhere',100,0,'b7160000-0000-0000-0000-0000000000a1'),
  ('b7160000-0000-0000-0000-0000000000e2','b7160000-0000-0000-0000-000000000001','PR Cap','pr-cap','published',now() + interval '9 days','America/New_York','Elsewhere',100,0,'b7160000-0000-0000-0000-0000000000a1'),
  ('b7160000-0000-0000-0000-0000000000e5','b7160000-0000-0000-0000-000000000002','PR Elsewhere','pr-elsewhere','published',now() + interval '4 days','America/New_York','Other Room',100,0,'b7160000-0000-0000-0000-0000000000a5');
INSERT INTO public.exos_ticket_tiers(id,event_id,name,price,capacity,sold,visibility) VALUES
  ('b7160000-0000-0000-0000-0000000000d1','b7160000-0000-0000-0000-0000000000e1','GA',25,100,0,'public');

CREATE FUNCTION pg_temp.act(p_uid text) RETURNS void LANGUAGE sql AS $$
  SELECT set_config('app.uid', coalesce(p_uid, ''), true), set_config('app.jwt', '', true);
$$;
GRANT EXECUTE ON FUNCTION pg_temp.act(text) TO anon, authenticated;
CREATE FUNCTION pg_temp.u(p text) RETURNS uuid LANGUAGE sql IMMUTABLE AS $$ SELECT ('b7160000-0000-0000-0000-' || p)::uuid $$;
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

-- PR1 ---------------------------------------------------------------------
DO $$
DECLARE c public.exos_discovery_channels%ROWTYPE;
BEGIN
  SELECT * INTO c FROM public.exos_discovery_channels WHERE id = 'the_skint';
  ASSERT FOUND AND c.kind = 'manual' AND c.region = 'NYC' AND c.submission_url = 'https://theskint.com/submit-an-event/' AND c.verified, 'PR1: the_skint';
  SELECT * INTO c FROM public.exos_discovery_channels WHERE id = 'nonsense_nyc';
  ASSERT FOUND AND c.kind = 'manual' AND c.submission_url IS NULL AND NOT c.verified, 'PR1: nonsense_nyc has no URL';
  SELECT * INTO c FROM public.exos_discovery_channels WHERE id = 'fever';
  ASSERT FOUND AND c.kind = 'manual' AND NOT c.verified, 'PR1: fever not verified';
  ASSERT (SELECT count(*) FROM public.exos_discovery_channels
           WHERE id IN ('the_skint', 'allevents', 'fever', 'nonsense_nyc', 'spotify', 'partiful') AND kind = 'manual' AND active) = 6, 'PR1: six new manual channels';
  SELECT * INTO c FROM public.exos_discovery_channels WHERE id = 'partiful';
  ASSERT FOUND AND c.region = 'NYC' AND c.submission_url = 'https://partiful.com' AND NOT c.verified, 'PR1: partiful';
  ASSERT (SELECT id FROM public.exos_discovery_channels WHERE active ORDER BY sort_order DESC, id LIMIT 1) = 'songkick', 'PR1: songkick last';
  RAISE NOTICE 'OK  PR1 six channels seeded (Nonsense NYC without a URL, Partiful NYC), Songkick at the bottom';
END $$;

SET LOCAL ROLE authenticated;
SELECT pg_temp.act('b7160000-0000-0000-0000-0000000000a1');
SELECT set_config('pr.ec', public.exos_discovery_event_channels(pg_temp.u('0000000000e1'))::text, true);
SELECT set_config('pr.q', public.exos_discovery_queue(pg_temp.u('0000000000e1'), 'nonsense_nyc')::text, true);
RESET ROLE;
DO $$
DECLARE ec jsonb := current_setting('pr.ec')::jsonb; n int;
BEGIN
  n := jsonb_array_length(ec->'channels');
  ASSERT n = (SELECT count(*) FROM public.exos_discovery_channels WHERE active), 'PR1: every channel listed';
  ASSERT ec->'channels'->(n - 1)->>'id' = 'songkick', 'PR1: songkick listed last ' || (ec->'channels'->(n - 1))::text;
  ASSERT current_setting('pr.q')::jsonb->>'status' = 'queued', 'PR1: a channel with no URL still queues';
  RAISE NOTICE 'OK  PR1 event channels list them, Songkick last; Nonsense NYC queues';
END $$;

-- PR2 ---------------------------------------------------------------------
SET LOCAL ROLE authenticated;
SELECT pg_temp.act('b7160000-0000-0000-0000-0000000000a1');
SELECT set_config('pr.p1', public.exos_print_placement_add(pg_temp.u('0000000000e1'), '  Poster –  Bedford Ave ')::text, true);
SELECT set_config('pr.p2', public.exos_print_placement_add(pg_temp.u('0000000000e1'), 'Poster - Bedford Ave!')::text, true);
SELECT pg_temp.act('b7160000-0000-0000-0000-0000000000a2');
SELECT set_config('pr.p3', public.exos_print_placement_add(pg_temp.u('0000000000e1'), 'poster bedford ave')::text, true);
SELECT set_config('pr.p4', public.exos_print_placement_add(pg_temp.u('0000000000e1'), 'Flyer @ Bar X')::text, true);
SELECT set_config('pr.long', public.exos_print_placement_add(pg_temp.u('0000000000e1'), repeat('a', 70))::text, true);
SELECT set_config('pr.long2', public.exos_print_placement_add(pg_temp.u('0000000000e1'), repeat('a', 75))::text, true);
SELECT set_config('pr.empty', pg_temp.refused($$SELECT public.exos_print_placement_add(pg_temp.u('0000000000e1'), '   ')$$, 'name the spot')::text, true);
SELECT set_config('pr.toolong', pg_temp.refused($$SELECT public.exos_print_placement_add(pg_temp.u('0000000000e1'), repeat('x', 81))$$, 'up to 80')::text, true);
SELECT set_config('pr.noalnum', pg_temp.refused($$SELECT public.exos_print_placement_add(pg_temp.u('0000000000e1'), '!!!')$$, 'a letter or a number')::text, true);
SELECT pg_temp.act('b7160000-0000-0000-0000-0000000000a3');
SELECT set_config('pr.fin_list', public.exos_print_placements(pg_temp.u('0000000000e1'))::text, true);
SELECT set_config('pr.fin_add', pg_temp.refused($$SELECT public.exos_print_placement_add(pg_temp.u('0000000000e1'), 'Finance spot')$$, 'not authorized')::text, true);
SELECT pg_temp.act('b7160000-0000-0000-0000-0000000000a4');
SELECT set_config('pr.scan_list', pg_temp.refused($$SELECT public.exos_print_placements(pg_temp.u('0000000000e1'))$$, 'not authorized')::text, true);
SELECT set_config('pr.scan_add', pg_temp.refused($$SELECT public.exos_print_placement_add(pg_temp.u('0000000000e1'), 'Scanner spot')$$, 'not authorized')::text, true);
SELECT pg_temp.act('b7160000-0000-0000-0000-0000000000a5');
SELECT set_config('pr.other_list', pg_temp.refused($$SELECT public.exos_print_placements(pg_temp.u('0000000000e1'))$$, 'not authorized')::text, true);
SELECT set_config('pr.other_add', pg_temp.refused($$SELECT public.exos_print_placement_add(pg_temp.u('0000000000e1'), 'Other spot')$$, 'not authorized')::text, true);
SELECT set_config('pr.missing', pg_temp.refused($$SELECT public.exos_print_placement_add(pg_temp.u('0000000000ff'), 'Nowhere')$$, 'not authorized')::text, true);
RESET ROLE;
SET LOCAL ROLE anon;
SELECT set_config('pr.anon', pg_temp.refused($$SELECT public.exos_print_placements(pg_temp.u('0000000000e1'))$$, 'permission denied')::text, true);
RESET ROLE;
DO $$
DECLARE l jsonb := current_setting('pr.fin_list')::jsonb;
BEGIN
  ASSERT current_setting('pr.p1')::jsonb->>'slug' = 'poster-bedford-ave', 'PR2: slug ' || current_setting('pr.p1');
  ASSERT current_setting('pr.p1')::jsonb->>'name' = 'Poster – Bedford Ave', 'PR2: name trimmed, spaces collapsed';
  ASSERT current_setting('pr.p2')::jsonb->>'slug' = 'poster-bedford-ave-2', 'PR2: clash -2';
  ASSERT current_setting('pr.p3')::jsonb->>'slug' = 'poster-bedford-ave-3', 'PR2: manager adds, clash -3';
  ASSERT current_setting('pr.p4')::jsonb->>'slug' = 'flyer-bar-x', 'PR2: flyer slug';
  ASSERT current_setting('pr.long')::jsonb->>'slug' = repeat('a', 60), 'PR2: 60 characters';
  ASSERT current_setting('pr.long2')::jsonb->>'slug' = repeat('a', 58) || '-2', 'PR2: clash fits 60 ' || current_setting('pr.long2');
  ASSERT current_setting('pr.empty')::boolean AND current_setting('pr.toolong')::boolean AND current_setting('pr.noalnum')::boolean, 'PR2: bad names';
  ASSERT jsonb_array_length(l) = 6, 'PR2: finance reads all six ' || l::text;
  ASSERT l->0->>'slug' = 'poster-bedford-ave' AND l->0 ? 'created_at' AND l->0 ? 'id', 'PR2: oldest first';
  ASSERT current_setting('pr.fin_add')::boolean, 'PR2: finance cannot add';
  ASSERT current_setting('pr.scan_list')::boolean AND current_setting('pr.scan_add')::boolean, 'PR2: scanner refused';
  ASSERT current_setting('pr.other_list')::boolean AND current_setting('pr.other_add')::boolean, 'PR2: other org refused';
  ASSERT current_setting('pr.missing')::boolean, 'PR2: unknown event refused';
  ASSERT current_setting('pr.anon')::boolean, 'PR2: anon has no EXECUTE';
  ASSERT (SELECT org_id FROM public.exos_print_placements WHERE slug = 'flyer-bar-x') = pg_temp.u('000000000001'), 'PR2: org stamped';
  ASSERT (SELECT created_by FROM public.exos_print_placements WHERE slug = 'flyer-bar-x') = pg_temp.u('0000000000a2'), 'PR2: creator stamped';
  RAISE NOTICE 'OK  PR2 owner / manager add with slugs; finance reads; others refused';
END $$;

-- PR3 ---------------------------------------------------------------------
SET LOCAL ROLE authenticated;
SELECT pg_temp.act('b7160000-0000-0000-0000-0000000000a5');
SELECT set_config('pr.rm_other', pg_temp.refused(format('SELECT public.exos_print_placement_remove(%L)',
  (current_setting('pr.p4')::jsonb->>'id')), 'not authorized')::text, true);
SELECT pg_temp.act('b7160000-0000-0000-0000-0000000000a3');
SELECT set_config('pr.rm_fin', pg_temp.refused(format('SELECT public.exos_print_placement_remove(%L)',
  (current_setting('pr.p4')::jsonb->>'id')), 'not authorized')::text, true);
SELECT pg_temp.act('b7160000-0000-0000-0000-0000000000a2');
SELECT set_config('pr.rm', public.exos_print_placement_remove((current_setting('pr.p4')::jsonb->>'id')::uuid)::text, true);
SELECT set_config('pr.rm_again', pg_temp.refused(format('SELECT public.exos_print_placement_remove(%L)',
  (current_setting('pr.p4')::jsonb->>'id')), 'not authorized')::text, true);
-- The slug is free again.
SELECT set_config('pr.p5', public.exos_print_placement_add(pg_temp.u('0000000000e1'), 'Flyer - Bar X')::text, true);
RESET ROLE;
DO $$
BEGIN
  ASSERT current_setting('pr.rm_other')::boolean AND current_setting('pr.rm_fin')::boolean, 'PR3: other org / finance refused';
  ASSERT current_setting('pr.rm')::boolean, 'PR3: manager removes';
  ASSERT current_setting('pr.rm_again')::boolean, 'PR3: gone';
  ASSERT current_setting('pr.p5')::jsonb->>'slug' = 'flyer-bar-x', 'PR3: slug reusable';
  RAISE NOTICE 'OK  PR3 remove (writer only)';
END $$;

-- PR4 ---------------------------------------------------------------------
INSERT INTO public.exos_print_placements(event_id, org_id, name, slug)
SELECT pg_temp.u('0000000000e2'), pg_temp.u('000000000001'), 'Spot ' || g, 'spot-' || g FROM generate_series(1, 199) g;
SET LOCAL ROLE authenticated;
SELECT pg_temp.act('b7160000-0000-0000-0000-0000000000a1');
SELECT set_config('pr.c200', public.exos_print_placement_add(pg_temp.u('0000000000e2'), 'Spot 200')::text, true);
SELECT set_config('pr.c201', pg_temp.refused($$SELECT public.exos_print_placement_add(pg_temp.u('0000000000e2'), 'Spot 201')$$, 'at most 200')::text, true);
RESET ROLE;
DO $$
BEGIN
  ASSERT current_setting('pr.c200')::jsonb->>'slug' = 'spot-200', 'PR4: the 200th fits';
  ASSERT current_setting('pr.c201')::boolean, 'PR4: the 201st refused';
  RAISE NOTICE 'OK  PR4 200 placements per event';
END $$;

-- PR5 ---------------------------------------------------------------------
DO $$
BEGIN
  ASSERT (SELECT relrowsecurity FROM pg_class WHERE oid = 'public.exos_print_placements'::regclass), 'PR5: RLS on';
  ASSERT NOT has_table_privilege('authenticated', 'public.exos_print_placements', 'SELECT'), 'PR5: no client select';
  ASSERT NOT has_table_privilege('authenticated', 'public.exos_print_placements', 'INSERT'), 'PR5: no client insert';
  ASSERT NOT has_table_privilege('anon', 'public.exos_print_placements', 'SELECT'), 'PR5: no anon select';
  RAISE NOTICE 'OK  PR5 RLS on, RPCs only';
END $$;

-- PR6 ---------------------------------------------------------------------
DO $$
BEGIN
  ASSERT public._exos_channel_key('google', 'paid_search') = 'google-ads', 'PR6: paid_search';
  ASSERT public._exos_channel_key('google', 'cpc') = 'google-ads', 'PR6: cpc still';
  ASSERT public._exos_channel_key('google', 'events_feed') = 'google', 'PR6: organic google';
  ASSERT public._exos_channel_key('meta', 'paid_social') = 'meta-ads', 'PR6: meta paid_social';
  ASSERT public._exos_channel_key('instagram', 'organic_social') = 'instagram', 'PR6: organic social';
  ASSERT public._exos_channel_key('qr', 'print') = 'flyer', 'PR6: qr / print';
  ASSERT public._exos_channel_key('print', 'qr') = 'flyer', 'PR6: print / qr';
  ASSERT public._exos_channel_key('email', 'email') = 'email', 'PR6: email';
  ASSERT public._exos_channel_key('', 'paid_search') IS NULL, 'PR6: no source';
  ASSERT public._exos_channel_key('partiful', 'referral') = 'partiful', 'PR6: partiful';
  ASSERT public._exos_channel_key('https://partiful.com/e/abc', NULL) = 'partiful', 'PR6: partiful referrer form';
  ASSERT public._exos_channel_label('partiful') = 'Partiful', 'PR6: Partiful label';
  ASSERT public._exos_channel_label('flyer') = 'Flyer / QR code' AND public._exos_channel_label('posh') = 'Posh'
     AND public._exos_channel_label('promoter:dj') = 'Promoters' AND public._exos_channel_label('nope') = 'Other', 'PR6: old labels';
  ASSERT public._exos_channel_detail('partiful') IS NULL, 'PR6: a fixed channel has no detail';
  RAISE NOTICE 'OK  PR6 channel key: paid_search is Google ads, Partiful its own channel and label, older mappings kept';
END $$;

-- PR7 ---------------------------------------------------------------------
DO $$
DECLARE r record;
BEGIN
  FOR r IN SELECT p.oid::regprocedure AS sig, p.proname, p.proconfig
             FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
            WHERE n.nspname = 'public'
              AND p.proname IN ('_exos_print_placement_slug', '_exos_print_placement_row', 'exos_print_placements',
                                'exos_print_placement_add', 'exos_print_placement_remove', '_exos_channel_key', '_exos_channel_label') LOOP
    ASSERT r.proconfig @> ARRAY['search_path=public, pg_temp'], 'PR7: search_path ' || r.sig::text;
    ASSERT NOT has_function_privilege('anon', r.sig, 'EXECUTE'), 'PR7: anon ' || r.sig::text;
    IF r.proname LIKE '\_%' THEN
      ASSERT NOT has_function_privilege('authenticated', r.sig, 'EXECUTE'), 'PR7: helper is internal ' || r.sig::text;
    ELSE
      ASSERT has_function_privilege('authenticated', r.sig, 'EXECUTE'), 'PR7: client RPC ' || r.sig::text;
    END IF;
  END LOOP;
  ASSERT (SELECT count(*) FROM pg_proc WHERE proname IN ('exos_print_placements', 'exos_print_placement_add', 'exos_print_placement_remove')
          AND prosecdef) = 3, 'PR7: three definer RPCs';
  RAISE NOTICE 'OK  PR7 grants + search_path';
END $$;

-- PR8 ---------------------------------------------------------------------
UPDATE public.exos_events SET org_id = pg_temp.u('000000000002') WHERE id = pg_temp.u('0000000000e1');
SET LOCAL ROLE authenticated;
SELECT pg_temp.act('b7160000-0000-0000-0000-0000000000a1');
SELECT set_config('pr.mv_old_list', pg_temp.refused($$SELECT public.exos_print_placements(pg_temp.u('0000000000e1'))$$, 'not authorized')::text, true);
SELECT set_config('pr.mv_old_rm', pg_temp.refused(format('SELECT public.exos_print_placement_remove(%L)',
  (current_setting('pr.p1')::jsonb->>'id')), 'not authorized')::text, true);
SELECT pg_temp.act('b7160000-0000-0000-0000-0000000000a5');
SELECT set_config('pr.mv_new_list', public.exos_print_placements(pg_temp.u('0000000000e1'))::text, true);
SELECT set_config('pr.mv_new_rm', public.exos_print_placement_remove((current_setting('pr.p1')::jsonb->>'id')::uuid)::text, true);
SELECT set_config('pr.mv_new_add', public.exos_print_placement_add(pg_temp.u('0000000000e1'), 'Moved spot')::text, true);
RESET ROLE;
DO $$
BEGIN
  ASSERT current_setting('pr.mv_old_list')::boolean AND current_setting('pr.mv_old_rm')::boolean, 'PR8: old org refused';
  ASSERT jsonb_array_length(current_setting('pr.mv_new_list')::jsonb) = 6, 'PR8: new owner lists';
  ASSERT current_setting('pr.mv_new_rm')::boolean, 'PR8: new owner removes';
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_print_placements WHERE id = (current_setting('pr.p1')::jsonb->>'id')::uuid), 'PR8: removed';
  ASSERT current_setting('pr.mv_new_add')::jsonb->>'slug' = 'moved-spot', 'PR8: new owner adds';
  ASSERT position('FOR UPDATE' in pg_get_functiondef('public.exos_print_placement_add(uuid,text)'::regprocedure)) = 0
     AND position('pg_advisory_xact_lock' in pg_get_functiondef('public.exos_print_placement_add(uuid,text)'::regprocedure)) > 0,
    'PR8: add takes an advisory lock, not a row lock on the event';
  ASSERT NOT (SELECT prosecdef FROM pg_proc WHERE proname = '_exos_print_placement_row'), 'PR8: row helper is invoker';
  RAISE NOTICE 'OK  PR8 moved event: managed by its new org only; no event row lock';
END $$;

\echo 'test_promotion: all passed'
ROLLBACK;
