-- ============================================================================
-- Migration 20260929061000 — Exos (Bridge / D4): how marketplace buyers may
-- split a ticket type's listings
--
-- Lane:     d4 (exos / bridge ticketing infra)
-- Touches:  W: exos_ticket_tiers (column market_split + CHECK)
-- Pre-reqs: 20260929060000
--
-- Every marketplace listing was split "any" (a buyer takes any number from
-- it). Organizers can now choose, per ticket type, one policy that every
-- marketplace gets in its own words (_shared/marketplace/listingStandard.ts):
--
--   any         any quantity                     (the default, as before)
--   no_single   any quantity that doesn't leave one seat behind
--   pairs       even quantities only (tables for two, couples tickets)
--   together    the whole listing or nothing
--
-- Set in the event editor's Marketplaces grid; org owners and managers
-- already write exos_ticket_tiers through RLS, and the CHECK keeps the value
-- to the four above. exos-distribute reads it with the ticket type, so apply
-- this before deploying that function.
--
-- Re-run safe (IF NOT EXISTS / constraint guarded). D4 authors; applying to
-- prod is operator-gated.
-- ============================================================================

ALTER TABLE public.exos_ticket_tiers ADD COLUMN IF NOT EXISTS market_split text NOT NULL DEFAULT 'any';

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'exos_ticket_tiers_market_split_check') THEN
    ALTER TABLE public.exos_ticket_tiers ADD CONSTRAINT exos_ticket_tiers_market_split_check
      CHECK (market_split IN ('any', 'no_single', 'pairs', 'together'));
  END IF;
END $$;

COMMENT ON COLUMN public.exos_ticket_tiers.market_split IS
  'How marketplace buyers may split this ticket type''s listings: any | no_single | pairs | together (listingStandard.ts).';
