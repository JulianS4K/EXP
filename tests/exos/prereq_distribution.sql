-- exos_events columns from the phase-1 schema (20260520120000) that the
-- distribution migrations read but the minimal prereq.sql stub leaves out.
ALTER TABLE public.exos_events
  ADD COLUMN IF NOT EXISTS distribution_networks text[],
  ADD COLUMN IF NOT EXISTS sync_status           text,
  ADD COLUMN IF NOT EXISTS exclusivity           jsonb,
  ADD COLUMN IF NOT EXISTS venue_address         jsonb;

-- bridge_event_xref, as in the phase-1 schema (Terminal-2 reads it).
CREATE TABLE IF NOT EXISTS public.bridge_event_xref (
  exos_event_id     uuid PRIMARY KEY REFERENCES public.exos_events (id) ON DELETE CASCADE,
  aq_short_event_id text,
  tevo_event_id     bigint,
  sg_event_id       bigint,
  match_method      text,
  matched_at        timestamptz,
  meta              jsonb,
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now()
);
