-- exos_events columns from the phase-1 schema (20260520120000) that the
-- distribution migrations read but the minimal prereq.sql stub leaves out.
ALTER TABLE public.exos_events
  ADD COLUMN IF NOT EXISTS distribution_networks text[],
  ADD COLUMN IF NOT EXISTS sync_status           text,
  ADD COLUMN IF NOT EXISTS exclusivity           jsonb,
  ADD COLUMN IF NOT EXISTS venue_address         jsonb;
