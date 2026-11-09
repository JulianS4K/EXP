-- ============================================================================
-- View-order shim around 20260703130000_exos_event_artist_links. Test harness
-- only, never a migration.
--
-- That file's CREATE OR REPLACE VIEW puts artist_links in the MIDDLE of
-- exos_public_events (after performer_names). Postgres can only append view
-- columns, so the file cannot run as written against the phase-1 view; prod
-- got artist_links appended LAST instead (20260911133000_exos_event_series
-- says so and relies on it: its own CREATE OR REPLACE lists
-- "..., tickets_sold, artist_links, series_id, series_index").
--
-- run_p0.sh therefore drops the view just before the file (so the file runs
-- unchanged: column, CHECK, view, grants, comment) and then runs this, which
-- rebuilds the view in prod's column order with the same options and grants
-- the file set. Nothing depends on the view at this point in the chain.
-- ============================================================================
DROP VIEW public.exos_public_events;
CREATE VIEW public.exos_public_events WITH (security_invoker = true) AS
  SELECT id, org_id, name, slug, description, occurs_at_local, starts_at, doors_at,
         ends_at, timezone, currency, venue_name, venue_location, venue_address,
         primary_performer_name, performer_names, event_type, category, genres,
         subgenres, image_url, branding, purchase_limits, total_tickets,
         tickets_sold, artist_links
  FROM public.exos_events
  WHERE status = 'published';
REVOKE ALL ON public.exos_public_events FROM anon, authenticated;
GRANT SELECT ON public.exos_public_events TO anon, authenticated;
COMMENT ON VIEW public.exos_public_events IS
  'Public storefront projection: published events only. SECURITY DEFINER by design (base tables are RLS-locked to staff). Advisor 0010 ERROR accepted — see migration 20260601120500.';
