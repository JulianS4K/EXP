-- ============================================================================
-- Migration 20260926190000 — Exos (Bridge / D4): queue a StubHub event request
--                            when an event is published for StubHub
--
-- Lane:     d4 (exos / bridge ticketing infra)
-- Touches:  W: exos_distribution_listings (+external_event_id, +planned_request,
--              status 'planned')
--              FUNCTION exos_sync_stubhub_distribution (new, trigger)
--              TRIGGER exos_events_stubhub_distribution ON exos_events (new)
-- Pre-reqs: 20260523190000 (exos_distribution_listings)
--
-- Ties Exos event creation to StubHub event creation. The create/edit form
-- already stores the organizer's networks in exos_events.distribution_networks;
-- nothing read them. Now, whenever an event is published with 'stubhub' among
-- them (and isn't primary-market-only), it gets one exos_distribution_listings
-- row, channel 'stubhub', status 'pending'. exos-distribute picks that up,
-- builds the PUT /sellerevents body from the event
-- (supabase/functions/_shared/stubhub-event.ts), and:
--   * dry-run (the default, and the only mode today): stores that body in
--     planned_request and sets status 'planned'. Nothing is sent to StubHub.
--   * a mapping problem (no venue city, ...): status 'failed' + error, which
--     the event editor shows the organizer.
-- external_event_id is where StubHub's SellerEvent id goes once live writes
-- are authorized (Hard Rule #2); nothing sets it yet.
--
-- Editing the event re-queues the request (so the plan follows the details)
-- until StubHub has an event for it. Unpublishing, cancelling, going
-- primary-market-only or unticking StubHub removes a row that never reached
-- StubHub; one that did is left alone for a human.
--
-- The trigger is SECURITY DEFINER because organizers write exos_events
-- directly (RLS) but have no write grant on exos_distribution_listings. It
-- only ever touches the 'stubhub' row of the event being written.
--
-- Re-run safe. D4 authors; applying to prod is operator-gated.
-- ============================================================================

ALTER TABLE public.exos_distribution_listings
  ADD COLUMN IF NOT EXISTS external_event_id text,
  ADD COLUMN IF NOT EXISTS planned_request   jsonb;

COMMENT ON COLUMN public.exos_distribution_listings.external_event_id IS
  'Marketplace event id (StubHub SellerEvent id) once the event request has been sent. NULL while dry-run.';
COMMENT ON COLUMN public.exos_distribution_listings.planned_request IS
  'Dry-run: the request exos-distribute would send ({endpoint, method, path, body}). Not sent.';

ALTER TABLE public.exos_distribution_listings
  DROP CONSTRAINT IF EXISTS exos_distribution_listings_status_check;
ALTER TABLE public.exos_distribution_listings
  ADD CONSTRAINT exos_distribution_listings_status_check
  CHECK (status IN ('pending','planned','listing','listed','failed','delisting','delisted'));

CREATE OR REPLACE FUNCTION public.exos_sync_stubhub_distribution()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF NEW.status = 'published'
     AND 'stubhub' = ANY (coalesce(NEW.distribution_networks, '{}'::text[]))
     AND coalesce(NEW.exclusivity ->> 'primaryMarketOnly', 'false') <> 'true'
  THEN
    INSERT INTO public.exos_distribution_listings (event_id, org_id, channel, status)
    VALUES (NEW.id, NEW.org_id, 'stubhub', 'pending')
    ON CONFLICT (event_id, channel) DO UPDATE
      SET status = 'pending', error = NULL, planned_request = NULL, updated_at = now()
      WHERE exos_distribution_listings.external_event_id IS NULL
        AND exos_distribution_listings.external_listing_id IS NULL
        AND exos_distribution_listings.status IN ('pending','planned','failed','delisted');
  ELSE
    DELETE FROM public.exos_distribution_listings
     WHERE event_id = NEW.id
       AND channel = 'stubhub'
       AND external_event_id IS NULL
       AND external_listing_id IS NULL
       AND status IN ('pending','planned','failed');
  END IF;
  RETURN NULL;
END $$;
REVOKE EXECUTE ON FUNCTION public.exos_sync_stubhub_distribution() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS exos_events_stubhub_distribution ON public.exos_events;
CREATE TRIGGER exos_events_stubhub_distribution
  AFTER INSERT OR UPDATE OF status, distribution_networks, exclusivity, name, starts_at,
                            venue_name, venue_location, venue_address
  ON public.exos_events
  FOR EACH ROW EXECUTE FUNCTION public.exos_sync_stubhub_distribution();
