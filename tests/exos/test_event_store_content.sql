-- ============================================================================
-- Store page content (mig 20260929120000). Self-contained (5c… prefix),
-- rolled back at the end.
--   S1 a full, well-formed store page is accepted
--   S2 bad shapes, lengths and vocabularies are rejected
--   S3 column grants: anon + authenticated read, only authenticated writes
--   S4 anon reads the columns through exos_public_events (a stub view is
--      built here when the chain has none, then the migration is re-applied
--      so its append path runs), and a second apply is a no-op
--   psql -d <db> -v ON_ERROR_STOP=1 -f tests/exos/test_event_store_content.sql
-- ============================================================================
\set ON_ERROR_STOP on
BEGIN;
INSERT INTO auth.users(id,email,email_confirmed_at) VALUES
  ('5c000000-0000-0000-0000-0000000000a0','sc-owner@x.com',now());
INSERT INTO public.exos_orgs(id,name,slug,owner_uid) VALUES
  ('5c000000-0000-0000-0000-000000000001','SC Org','sc-org','5c000000-0000-0000-0000-0000000000a0');
INSERT INTO public.exos_events(id,org_id,name,slug,status) VALUES
  ('5c000000-0000-0000-0000-0000000000e1','5c000000-0000-0000-0000-000000000001','SC Night','sc-night','published');

-- S1 ---------------------------------------------------------------------------
DO $$
DECLARE e record;
BEGIN
  UPDATE public.exos_events SET
    summary        = 'Techno till sunrise in a Bushwick warehouse.',
    description_md = E'## The night\n\n**Four rooms**, one [lineup](https://example.com).\n\n- Coat check\n- Water',
    lineup  = '[{"name":"DJ Nova","role":"headliner","set_at":"23:30","bio":"Berlin via Queens."},
                {"name":"Opener","role":"support"}]',
    faq     = '[{"q":"Is there parking?","a":"Street only."}]',
    gallery = '[{"url":"https://cdn.example.com/a.jpg","alt":"The main room"},{"url":"https://cdn.example.com/b.jpg"}]',
    video_url     = 'https://www.youtube.com/watch?v=dQw4w9WgXcQ',
    min_age       = 21,
    refund_policy = 'until_7d',
    policy_notes  = 'No re-entry. Clear bags only.'
  WHERE id = '5c000000-0000-0000-0000-0000000000e1';
  SELECT * INTO e FROM public.exos_events WHERE id = '5c000000-0000-0000-0000-0000000000e1';
  ASSERT jsonb_array_length(e.lineup) = 2 AND e.min_age = 21, 'S1: store content saved';
  UPDATE public.exos_events SET video_url = 'https://youtu.be/dQw4w9WgXcQ' WHERE id = '5c000000-0000-0000-0000-0000000000e1';
  UPDATE public.exos_events SET video_url = 'https://vimeo.com/76979871' WHERE id = '5c000000-0000-0000-0000-0000000000e1';
  UPDATE public.exos_events SET min_age = 0, refund_policy = 'custom' WHERE id = '5c000000-0000-0000-0000-0000000000e1';
  -- Defaults: a new event starts with empty lists, not NULL.
  INSERT INTO public.exos_events(id,org_id,name,slug) VALUES
    ('5c000000-0000-0000-0000-0000000000e2','5c000000-0000-0000-0000-000000000001','SC Draft','sc-draft');
  ASSERT (SELECT lineup = '[]' AND faq = '[]' AND gallery = '[]' FROM public.exos_events
           WHERE id = '5c000000-0000-0000-0000-0000000000e2'), 'S1: lists default to []';
  RAISE NOTICE 'OK  S1 well-formed store content accepted';
END $$;

-- S2 ---------------------------------------------------------------------------
DO $$
DECLARE
  bad text;
  n int := 0;
BEGIN
  FOREACH bad IN ARRAY ARRAY[
    $s$summary = repeat('x', 161)$s$,
    $s$description_md = repeat('x', 20001)$s$,
    $s$lineup = '{"name":"x"}'$s$,
    $s$lineup = '[{"name":"x","role":"drummer"}]'$s$,
    $s$lineup = '[{"name":"","role":"dj"}]'$s$,
    $s$lineup = '[{"role":"dj"}]'$s$,
    $s$lineup = '[{"name":"x","role":"dj","set_at":"25:00"}]'$s$,
    $s$lineup = '[{"name":"x","role":"dj","set_at":"9pm"}]'$s$,
    $s$lineup = jsonb_build_array(jsonb_build_object('name','x','role','dj','bio',repeat('b',501)))$s$,
    $s$lineup = '[{"name":"x","role":"dj","image_url":"javascript:alert(1)"}]'$s$,
    $s$lineup = (SELECT jsonb_agg(jsonb_build_object('name','n'||g,'role','dj')) FROM generate_series(1,21) g)$s$,
    $s$lineup = 'null'$s$,
    $s$faq = '[{"q":"Why?"}]'$s$,
    $s$faq = '[{"q":"Why?","a":"Because","html":"<b>"}]'$s$,
    $s$faq = jsonb_build_array(jsonb_build_object('q',repeat('q',201),'a','a'))$s$,
    $s$faq = jsonb_build_array(jsonb_build_object('q','q','a',repeat('a',1001)))$s$,
    $s$faq = '["just a string"]'$s$,
    $s$faq = (SELECT jsonb_agg(jsonb_build_object('q','q'||g,'a','a')) FROM generate_series(1,21) g)$s$,
    $s$gallery = '[{"url":"http://cdn.example.com/a.jpg"}]'$s$,
    $s$gallery = '[{"url":"javascript:alert(1)"}]'$s$,
    $s$gallery = '[{"url":"https://x.com/a.jpg\" onerror=\"x"}]'$s$,
    $s$gallery = '[{"alt":"no url"}]'$s$,
    $s$gallery = jsonb_build_array(jsonb_build_object('url','https://x.com/a.jpg','alt',repeat('a',201)))$s$,
    $s$gallery = (SELECT jsonb_agg(jsonb_build_object('url','https://x.com/'||g||'.jpg')) FROM generate_series(1,13) g)$s$,
    $s$video_url = 'https://evil.example.com/watch?v=1'$s$,
    $s$video_url = 'http://www.youtube.com/watch?v=1'$s$,
    $s$video_url = 'https://youtube.com.evil.com/x'$s$,
    $s$min_age = 17$s$,
    $s$refund_policy = 'whenever'$s$,
    $s$policy_notes = repeat('x', 1001)$s$]
  LOOP
    BEGIN
      EXECUTE 'UPDATE public.exos_events SET ' || bad || $w$ WHERE id = '5c000000-0000-0000-0000-0000000000e1'$w$;
      RAISE EXCEPTION 'S2: accepted %', bad;
    EXCEPTION
      WHEN check_violation OR not_null_violation THEN n := n + 1;
    END;
  END LOOP;
  RAISE NOTICE 'OK  S2 % bad values rejected', n;
END $$;

-- S3 ---------------------------------------------------------------------------
DO $$
DECLARE c text;
BEGIN
  FOREACH c IN ARRAY ARRAY['summary','description_md','lineup','faq','gallery','video_url',
                           'min_age','refund_policy','policy_notes'] LOOP
    ASSERT has_column_privilege('anon', 'public.exos_events', c, 'SELECT'), 'S3: anon reads ' || c;
    ASSERT has_column_privilege('authenticated', 'public.exos_events', c, 'SELECT'), 'S3: authenticated reads ' || c;
    ASSERT has_column_privilege('authenticated', 'public.exos_events', c, 'INSERT'), 'S3: authenticated inserts ' || c;
    ASSERT has_column_privilege('authenticated', 'public.exos_events', c, 'UPDATE'), 'S3: authenticated updates ' || c;
    ASSERT NOT has_column_privilege('anon', 'public.exos_events', c, 'UPDATE'), 'S3: anon may update ' || c;
    ASSERT NOT has_column_privilege('anon', 'public.exos_events', c, 'INSERT'), 'S3: anon may insert ' || c;
  END LOOP;
  ASSERT NOT has_function_privilege('anon', 'public._exos_store_content_ok(jsonb,jsonb,jsonb)', 'EXECUTE'),
    'S3: anon may call the check helper';
  RAISE NOTICE 'OK  S3 column grants';
END $$;

-- S4 ---------------------------------------------------------------------------
-- Prod-shaped schemas already have the view; stub chains get a minimal one
-- (rolled back) and the migration is re-applied so its append path runs.
SELECT to_regclass('public.exos_public_events') IS NULL AS need_stub_view \gset
\if :need_stub_view
  GRANT SELECT (id, name, status) ON public.exos_events TO anon, authenticated;
  CREATE VIEW public.exos_public_events WITH (security_invoker = true) AS
    SELECT id, name FROM public.exos_events WHERE status = 'published';
  GRANT SELECT ON public.exos_public_events TO anon, authenticated;
\endif
\ir ../../supabase/migrations/20260929120000_exos_event_store_content.sql
-- Second apply: must not append the columns twice.
\ir ../../supabase/migrations/20260929120000_exos_event_store_content.sql
UPDATE public.exos_events SET min_age = 21, refund_policy = 'until_7d'
 WHERE id = '5c000000-0000-0000-0000-0000000000e1';
DO $$
BEGIN
  ASSERT (SELECT count(*) FROM information_schema.columns
           WHERE table_schema = 'public' AND table_name = 'exos_public_events'
             AND column_name = 'description_md') = 1, 'S4: view has description_md once';
END $$;
SET LOCAL ROLE anon;
DO $$
DECLARE e record;
BEGIN
  SELECT summary, description_md, lineup, faq, gallery, video_url, min_age, refund_policy, policy_notes
    INTO e FROM public.exos_public_events WHERE id = '5c000000-0000-0000-0000-0000000000e1';
  ASSERT e.summary LIKE 'Techno till sunrise%', 'S4: anon reads summary';
  ASSERT e.description_md LIKE '## The night%', 'S4: anon reads description_md';
  ASSERT e.lineup->0->>'name' = 'DJ Nova', 'S4: anon reads lineup';
  ASSERT e.faq->0->>'a' = 'Street only.', 'S4: anon reads faq';
  ASSERT jsonb_array_length(e.gallery) = 2, 'S4: anon reads gallery';
  ASSERT e.video_url LIKE 'https://vimeo.com/%', 'S4: anon reads video_url';
  ASSERT e.min_age = 21 AND e.refund_policy = 'until_7d', 'S4: anon reads age + refund policy';
  ASSERT e.policy_notes LIKE 'No re-entry%', 'S4: anon reads policy notes';
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_public_events
                      WHERE id = '5c000000-0000-0000-0000-0000000000e2'), 'S4: drafts stay hidden';
  RAISE NOTICE 'OK  S4 anon reads the store content through exos_public_events';
END $$;
RESET ROLE;

ROLLBACK;
