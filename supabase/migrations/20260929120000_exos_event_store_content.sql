-- ============================================================================
-- Migration 20260929120000 — Exos (Bridge / D4): richer store page content
--
-- Lane:     d4 (exos / bridge ticketing infra)
-- Touches:  W: exos_events (+summary, +description_md, +lineup, +faq, +gallery,
--              +video_url, +min_age, +refund_policy, +policy_notes)
--              FUNCTION _exos_store_content_ok (new, CHECK helper)
--              VIEW exos_public_events (columns appended in place)
-- Pre-reqs: 20260926090000 (accessibility column + the view-append pattern)
--
-- What organizers get on the event page:
--   * summary: a one-line pitch (<= 160) shown under the title and used as
--     the meta description.
--   * description_md: the long "About" text in a small markdown subset
--     (paragraphs, bold/italic, links, lists, headings, quotes). The app
--     renders it to React elements from an allowlist, never as raw HTML.
--     `description` stays the plain fallback: the app keeps writing
--     description = mdToPlain(description_md), so every existing consumer
--     (SEO copy, calendar, MCP, feeds) keeps working unchanged.
--   * lineup: [{name, role, set_at?, bio?}] with set times and short bios.
--   * faq: [{q, a}] shown as an accordion.
--   * gallery: [{url, alt}] extra https images (the cover stays image_url).
--   * video_url: a YouTube or Vimeo link, embedded privacy-enhanced.
--   * min_age (0 = all ages, 16, 18, 21), refund_policy (a fixed vocabulary)
--     and policy_notes (dress code, bag policy, re-entry) for "Good to know".
--
-- All public: anon reads them through exos_public_events like the rest of
-- the listing. Writes ride the existing exos_events RLS.
--
-- Re-run safe. D4 authors; applying to prod is operator-gated.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. Shape check for the three jsonb lists (vocabulary shared with the UI:
--    src/components/StoreContentEditor.tsx)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._exos_store_content_ok(p_lineup jsonb, p_faq jsonb, p_gallery jsonb)
RETURNS boolean LANGUAGE sql IMMUTABLE
SET search_path TO 'public', 'pg_temp'
AS $$
  SELECT p_lineup IS NOT NULL AND p_faq IS NOT NULL AND p_gallery IS NOT NULL
     -- lineup: [{name, role, set_at?, bio?}] max 20
     AND jsonb_typeof(p_lineup) = 'array'
     AND jsonb_array_length(p_lineup) <= 20
     AND NOT EXISTS (
           SELECT 1 FROM jsonb_array_elements(p_lineup) e
            WHERE jsonb_typeof(e) <> 'object'
               OR EXISTS (SELECT 1 FROM jsonb_object_keys(e) k
                           WHERE k NOT IN ('name', 'role', 'set_at', 'bio'))
               OR jsonb_typeof(e->'name') IS DISTINCT FROM 'string'
               OR length(btrim(e->>'name')) NOT BETWEEN 1 AND 120
               OR jsonb_typeof(e->'role') IS DISTINCT FROM 'string'
               OR e->>'role' NOT IN ('headliner', 'support', 'dj', 'host', 'other')
               OR (e ? 'set_at' AND (jsonb_typeof(e->'set_at') <> 'string'
                                     OR e->>'set_at' !~ '^([01][0-9]|2[0-3]):[0-5][0-9]$'))
               OR (e ? 'bio' AND (jsonb_typeof(e->'bio') <> 'string' OR length(e->>'bio') > 500)))
     -- faq: [{q, a}] max 20
     AND jsonb_typeof(p_faq) = 'array'
     AND jsonb_array_length(p_faq) <= 20
     AND NOT EXISTS (
           SELECT 1 FROM jsonb_array_elements(p_faq) e
            WHERE jsonb_typeof(e) <> 'object'
               OR EXISTS (SELECT 1 FROM jsonb_object_keys(e) k WHERE k NOT IN ('q', 'a'))
               OR jsonb_typeof(e->'q') IS DISTINCT FROM 'string'
               OR jsonb_typeof(e->'a') IS DISTINCT FROM 'string'
               OR length(btrim(e->>'q')) NOT BETWEEN 1 AND 200
               OR length(btrim(e->>'a')) NOT BETWEEN 1 AND 1000)
     -- gallery: [{url (https), alt?}] max 12
     AND jsonb_typeof(p_gallery) = 'array'
     AND jsonb_array_length(p_gallery) <= 12
     AND NOT EXISTS (
           SELECT 1 FROM jsonb_array_elements(p_gallery) e
            WHERE jsonb_typeof(e) <> 'object'
               OR EXISTS (SELECT 1 FROM jsonb_object_keys(e) k WHERE k NOT IN ('url', 'alt'))
               OR jsonb_typeof(e->'url') IS DISTINCT FROM 'string'
               OR e->>'url' !~ '^https://[^\s"<>]+$'
               OR length(e->>'url') > 2048
               OR (e ? 'alt' AND (jsonb_typeof(e->'alt') <> 'string' OR length(e->>'alt') > 200)))
$$;
REVOKE ALL ON FUNCTION public._exos_store_content_ok(jsonb, jsonb, jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public._exos_store_content_ok(jsonb, jsonb, jsonb) TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 2. Columns + checks
-- ---------------------------------------------------------------------------
ALTER TABLE public.exos_events
  ADD COLUMN IF NOT EXISTS summary        text,
  ADD COLUMN IF NOT EXISTS description_md text,
  ADD COLUMN IF NOT EXISTS lineup         jsonb NOT NULL DEFAULT '[]'::jsonb,
  ADD COLUMN IF NOT EXISTS faq            jsonb NOT NULL DEFAULT '[]'::jsonb,
  ADD COLUMN IF NOT EXISTS gallery        jsonb NOT NULL DEFAULT '[]'::jsonb,
  ADD COLUMN IF NOT EXISTS video_url      text,
  ADD COLUMN IF NOT EXISTS min_age        smallint,
  ADD COLUMN IF NOT EXISTS refund_policy  text,
  ADD COLUMN IF NOT EXISTS policy_notes   text;

DO $$
DECLARE
  r record;
BEGIN
  FOR r IN SELECT * FROM (VALUES
      ('exos_events_summary_chk',
       'summary IS NULL OR char_length(summary) <= 160'),
      ('exos_events_description_md_chk',
       'description_md IS NULL OR char_length(description_md) <= 20000'),
      ('exos_events_store_content_chk',
       'public._exos_store_content_ok(lineup, faq, gallery)'),
      ('exos_events_video_url_chk',
       $c$video_url IS NULL OR (char_length(video_url) <= 500
         AND video_url ~ '^https://(www\.|m\.)?(youtube\.com|youtu\.be|vimeo\.com)/[^\s"<>]*$')$c$),
      ('exos_events_min_age_chk',
       'min_age IS NULL OR min_age IN (0, 16, 18, 21)'),
      ('exos_events_refund_policy_chk',
       $c$refund_policy IS NULL OR refund_policy IN ('none', 'until_7d', 'until_24h', 'until_start', 'custom')$c$),
      ('exos_events_policy_notes_chk',
       'policy_notes IS NULL OR char_length(policy_notes) <= 1000')) AS v(name, expr)
  LOOP
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conname = r.name AND conrelid = 'public.exos_events'::regclass) THEN
      EXECUTE format('ALTER TABLE public.exos_events ADD CONSTRAINT %I CHECK (%s)', r.name, r.expr);
    END IF;
  END LOOP;
END $$;

-- Column grants follow the existing per-column pattern (mig 20260925021000).
-- RLS still decides which rows a writer can touch.
GRANT SELECT (summary, description_md, lineup, faq, gallery, video_url, min_age,
              refund_policy, policy_notes)
  ON public.exos_events TO anon, authenticated;
GRANT INSERT (summary, description_md, lineup, faq, gallery, video_url, min_age,
              refund_policy, policy_notes),
      UPDATE (summary, description_md, lineup, faq, gallery, video_url, min_age,
              refund_policy, policy_notes)
  ON public.exos_events TO authenticated;

-- ---------------------------------------------------------------------------
-- 3. Public view: append the new columns to whatever the live definition is
--    (prod's column list differs from older chains), keeping its options.
--    Same approach as 20260926090000.
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  d text;
  opts text;
  i int;
BEGIN
  IF to_regclass('public.exos_public_events') IS NULL THEN
    RAISE NOTICE 'exos_public_events: view not present here, skipping';   -- stub test schemas
    RETURN;
  END IF;
  d := pg_get_viewdef('public.exos_public_events'::regclass);
  IF position('description_md' || E'\n' in d) > 0 OR position('description_md' || ',' in d) > 0 THEN
    RAISE NOTICE 'exos_public_events: already has the store columns, skipping';
    RETURN;
  END IF;
  -- The select list ends at the outermost FROM, which pg_get_viewdef puts on
  -- its own line after the last column.
  i := position(E'\n   FROM ' in d);
  IF i = 0 THEN
    RAISE EXCEPTION 'exos_public_events: unexpected view definition';
  END IF;
  d := left(d, i - 1) || ',
    summary,
    description_md,
    lineup,
    faq,
    gallery,
    video_url,
    min_age,
    refund_policy,
    policy_notes' || substr(d, i);
  SELECT coalesce(' WITH (' || array_to_string(c.reloptions, ', ') || ')', '') INTO opts
    FROM pg_class c WHERE c.oid = 'public.exos_public_events'::regclass;
  EXECUTE format('CREATE OR REPLACE VIEW public.exos_public_events%s AS %s', opts, d);
  GRANT SELECT ON public.exos_public_events TO anon, authenticated;
END $$;
