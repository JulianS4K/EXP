-- ============================================================================
-- Exos owns its cron helpers (mig 20261118110000). Rolled back.
--   C1 exos_cron_invoke_edge_fn / exos_cron_should_fire: definer, search_path
--      pinned, no PUBLIC / anon / authenticated EXECUTE
--   C2 no exos function calls Terminal-2's cron_should_fire( or
--      _cron_invoke_edge_fn( any more; the ones that did call the Exos names
--   C3 the gate: true for a job, false for none; it holds a transaction-level
--      advisory lock for the job (so a second, overlapping run skips)
--   C4 the re-pointed cron entry functions still run
--   psql -d <db> -v ON_ERROR_STOP=1 -f tests/exos/test_own_cron_helpers.sql
-- ============================================================================
\set ON_ERROR_STOP on
BEGIN;

-- C1 ---------------------------------------------------------------------------
DO $$
DECLARE
  f regprocedure;
BEGIN
  FOREACH f IN ARRAY ARRAY[to_regprocedure('public.exos_cron_invoke_edge_fn(text,jsonb)'),
                           to_regprocedure('public.exos_cron_should_fire(text)')] LOOP
    ASSERT f IS NOT NULL, 'C1: a helper is missing';
    ASSERT (SELECT prosecdef FROM pg_proc WHERE oid = f), 'C1: ' || f || ' is not a definer';
    ASSERT EXISTS (SELECT 1 FROM pg_proc, unnest(proconfig) c WHERE oid = f AND c LIKE 'search_path=%'),
           'C1: ' || f || ' has no pinned search_path';
    ASSERT NOT has_function_privilege('anon', f, 'EXECUTE')
       AND NOT has_function_privilege('authenticated', f, 'EXECUTE'), 'C1: a client role may call ' || f;
    ASSERT NOT EXISTS (SELECT 1 FROM pg_proc, aclexplode(proacl) a WHERE oid = f AND a.grantee = 0),
           'C1: PUBLIC may call ' || f;
  END LOOP;
  RAISE NOTICE 'OK  C1 both helpers: definer, search_path pinned, no PUBLIC / anon / authenticated EXECUTE';
END $$;

-- C2 ---------------------------------------------------------------------------
DO $$
DECLARE
  v_left text;
  v_n    int;
BEGIN
  SELECT string_agg(p.oid::regprocedure::text, ', ') INTO v_left
    FROM pg_proc p
   WHERE p.pronamespace = 'public'::regnamespace AND p.proname LIKE '%exos%'
     AND p.prosrc ~ '\m(cron_should_fire|_cron_invoke_edge_fn)\s*\(';
  ASSERT v_left IS NULL, 'C2: still calling a Terminal-2 helper: ' || v_left;
  SELECT count(*) INTO v_n
    FROM pg_proc p
   WHERE p.pronamespace = 'public'::regnamespace AND p.proname LIKE '%exos%'
     AND p.proname <> 'exos_cron_should_fire'
     AND p.prosrc ~ '\mexos_cron_should_fire\s*\(';
  -- exos_send_event_reminders / _checkout_reminders / _mail_followups /
  -- _channel_reports and the promoter-events digest gate on it.
  ASSERT v_n >= 4, 'C2: expected the cron entry functions to gate on exos_cron_should_fire, found ' || v_n;
  RAISE NOTICE 'OK  C2 no exos function calls Terminal-2''s helpers; % gate on exos_cron_should_fire', v_n;
END $$;

-- C3 ---------------------------------------------------------------------------
DO $$
BEGIN
  ASSERT public.exos_cron_should_fire('exos-test-job'), 'C3: a job should fire';
  ASSERT NOT public.exos_cron_should_fire(NULL), 'C3: no job name fires';
  ASSERT EXISTS (SELECT 1 FROM pg_locks
                  WHERE locktype = 'advisory' AND pid = pg_backend_pid() AND granted
                    AND objsubid = 1  -- a single-bigint key: classid = high half, objid = low half
                    AND ((classid::bigint << 32) | objid::bigint) = hashtext('exos_cron:exos-test-job')::bigint),
         'C3: no advisory lock held for the job';
  -- The same transaction may ask again (the lock is its own).
  ASSERT public.exos_cron_should_fire('exos-test-job'), 'C3: the holder asking again';
  RAISE NOTICE 'OK  C3 the gate fires a named job and holds its advisory lock for the transaction';
END $$;

-- C4 ---------------------------------------------------------------------------
DO $$
DECLARE
  f record;
  v_n int := 0;
BEGIN
  FOR f IN
    SELECT p.oid::regprocedure AS sig
      FROM pg_proc p
     WHERE p.pronamespace = 'public'::regnamespace AND p.proname LIKE 'exos\_send\_%'
       AND p.pronargs = 0 AND p.prokind = 'f'
       AND p.prosrc ~ '\mexos_cron_should_fire\s*\('
  LOOP
    EXECUTE 'SELECT ' || f.sig::text;
    v_n := v_n + 1;
  END LOOP;
  ASSERT v_n >= 1, 'C4: no zero-argument exos_send_* cron entry function to run';
  RAISE NOTICE 'OK  C4 % re-pointed cron entry function(s) run', v_n;
END $$;

ROLLBACK;
