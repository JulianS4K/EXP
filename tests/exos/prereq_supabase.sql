-- ============================================================================
-- Supabase-platform shims for run_p0.sh, which builds the database from the
-- real migration chain (phase-1 schema on) the way prod was built. Run after
-- prereq_lifecycle.sql (roles, auth, pgcrypto, the claim-key test helpers).
-- Only what Supabase itself provides and the early migrations touch; no
-- exos_* object is stubbed here. Test harness only, never a migration.
-- ============================================================================

-- Storage (migs 20260520150000, 20260605131000: the exos-media bucket and its
-- storage.objects policies). The columns and helper those statements use.
CREATE SCHEMA IF NOT EXISTS storage;
CREATE TABLE IF NOT EXISTS storage.buckets (
  id                 text PRIMARY KEY,
  name               text NOT NULL,
  public             boolean DEFAULT false,
  file_size_limit    bigint,
  allowed_mime_types text[],
  owner              uuid,
  created_at         timestamptz DEFAULT now(),
  updated_at         timestamptz DEFAULT now()
);
CREATE TABLE IF NOT EXISTS storage.objects (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  bucket_id  text REFERENCES storage.buckets (id),
  name       text,
  owner      uuid,
  metadata   jsonb,
  created_at timestamptz DEFAULT now(),
  updated_at timestamptz DEFAULT now()
);
ALTER TABLE storage.objects ENABLE ROW LEVEL SECURITY;
CREATE OR REPLACE FUNCTION storage.foldername(name text) RETURNS text[]
  LANGUAGE sql IMMUTABLE AS $$ SELECT (string_to_array(name, '/'))[1:array_length(string_to_array(name, '/'), 1) - 1] $$;

-- Realtime (mig 20260523120000 adds exos_event_checkins to it; later ones
-- add their tables when it exists, as in prod). Quiet: wal_level isn't
-- 'logical' here, which only matters to a subscriber.
SET client_min_messages = error;
DO $r$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_publication WHERE pubname = 'supabase_realtime') THEN
    CREATE PUBLICATION supabase_realtime;
  END IF;
END $r$;
RESET client_min_messages;

-- cron_should_fire() (Terminal-2's 4-stage cron policy gate, mig
-- 20260515250000, not an Exos migration). Cron-entry RPCs gate on it.
CREATE OR REPLACE FUNCTION public.cron_should_fire(p_jobname text) RETURNS boolean
  LANGUAGE sql VOLATILE AS $$ SELECT true $$;

-- Supabase lets the API roles use the auth schema (auth.uid() / auth.jwt() in
-- policies and invoker functions, e.g. phase-2's exos_is_admin()).
GRANT USAGE ON SCHEMA auth TO anon, authenticated, service_role;
