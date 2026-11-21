-- ============================================================================
-- Short-lived pg_cron shim for the one migration that calls cron unguarded:
-- 20260702144637_exos_reconcile_checkouts_cron (cron.unschedule + cron.schedule,
-- nothing else). run_p0.sh creates this just before that file and drops the
-- schema right after it (DROP SCHEMA cron CASCADE), so the rest of the chain
-- and the tests still see no pg_cron: every later migration guards its cron
-- calls on pg_extension, and some tests check to_regclass('cron.job').
-- Same names and signatures as pg_cron. Test harness only, never a migration.
-- ============================================================================
CREATE SCHEMA IF NOT EXISTS cron;
CREATE TABLE IF NOT EXISTS cron.job (
  jobid    bigserial PRIMARY KEY,
  schedule text NOT NULL,
  command  text NOT NULL,
  jobname  text UNIQUE,
  active   boolean NOT NULL DEFAULT true
);
CREATE OR REPLACE FUNCTION cron.schedule(job_name text, schedule text, command text) RETURNS bigint
  LANGUAGE sql AS $$
  INSERT INTO cron.job (jobname, schedule, command) VALUES (job_name, schedule, command)
  ON CONFLICT (jobname) DO UPDATE SET schedule = EXCLUDED.schedule, command = EXCLUDED.command
  RETURNING jobid
$$;
CREATE OR REPLACE FUNCTION cron.unschedule(job_name text) RETURNS boolean
  LANGUAGE sql AS $$
  WITH d AS (DELETE FROM cron.job WHERE jobname = job_name RETURNING 1) SELECT EXISTS (SELECT 1 FROM d)
$$;
