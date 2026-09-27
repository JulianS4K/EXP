-- exos_events columns from the phase-1 schema (20260520120000) that the
-- distribution migrations read but the minimal prereq.sql stub leaves out.
ALTER TABLE public.exos_events
  ADD COLUMN IF NOT EXISTS distribution_networks text[],
  ADD COLUMN IF NOT EXISTS sync_status           text,
  ADD COLUMN IF NOT EXISTS exclusivity           jsonb,
  ADD COLUMN IF NOT EXISTS venue_address         jsonb;


-- exos_transfers' denormalised claim-screen columns (prod has them since the
-- Sprint 1 migrations; the stub table in prereq.sql doesn't).
ALTER TABLE public.exos_transfers
  ADD COLUMN IF NOT EXISTS sender_email text,
  ADD COLUMN IF NOT EXISTS event_id     uuid,
  ADD COLUMN IF NOT EXISTS event_title  text,
  ADD COLUMN IF NOT EXISTS event_image  text,
  ADD COLUMN IF NOT EXISTS tier_name    text,
  ADD COLUMN IF NOT EXISTS organizer_id uuid;
