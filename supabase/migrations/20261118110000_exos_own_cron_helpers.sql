-- ============================================================================
-- Migration 20261118110000 — Exos: own its two cron helpers
--                            (operator 2026-11-17: Terminal-2 is reference
--                            only and unrelated to Exos; copy what Exos uses)
--
-- Branch:   claude/exos-own-cron-helpers (stacked on claude/exos-drop-list)
-- Why: Exos still called two Terminal-2 functions. Nothing else: no trigger,
--   policy, view or column default on an exos_* object uses a Terminal-2
--   function, and no edge function or SPA call reaches one (checked read-only
--   on prod 2026-11-17).
--     * public._cron_invoke_edge_fn(text, jsonb): the pg_net POST to an edge
--       function with the vault's EDGE_FN_ANON_JWT + CRON_SECRET. 16 exos
--       crons on prod (17 with #117's Discord job).
--     * public.cron_should_fire(text): Terminal-2's cron gate (cron_policy,
--       cron_gate_decisions, cron_try_lock). 5 exos functions and 6 exos
--       crons. For Exos jobs it only ever did two things: an overlap lock
--       (every Exos job logs 'fire_no_policy'), and, for exos-mail-drain-2min
--       alone, a "claimable mail?" work check from its cron_policy row.
--
-- Touches:  C: FUNCTION exos_cron_invoke_edge_fn(text, jsonb)
--              (definer; prod's _cron_invoke_edge_fn body, copied as is)
--           C: FUNCTION exos_cron_should_fire(text)
--              (definer; the overlap lock only, no Terminal-2 tables)
--           W: every exos function whose body calls cron_should_fire( or
--              _cron_invoke_edge_fn( is re-created with the exos_ names
--              (generic rewrite, see below)
--           W: cron.job: every exos job whose command calls either is
--              re-pointed with cron.alter_job(command := ...) only: schedule
--              and active are left as they are. exos-mail-drain-2min gets its
--              work check in its own command.
--           R: vault.decrypted_secrets, net.http_post (at call time)
--   Left as they are: Terminal-2's two functions and its cron_policy row for
--   exos-mail-drain-2min (Terminal-2's data; unused by Exos after this).
--
-- The rewrite is generic on purpose (not anchored text patches): the calls
-- sit in bodies written over many waves and in cron commands, and whatever
-- the exact text, the change is the same rename. It matches the names as
-- whole words followed by "(", so exos_cron_should_fire( itself never
-- matches (the "_" before "cron" is a word character). A body with nothing
-- to rename is not touched. Re-run safe: the second run finds nothing.
--
-- Order: apply last (after claude/exos-drop-list, #125), so #117's Discord cron is re-pointed
--   too. scripts/check-migrations.sh refuses any later migration that calls
--   the Terminal-2 names again.
-- Not applied; prod apply needs operator OK (it changes cron commands).
-- ROLLBACK: re-run the same two rewrites the other way (exos_cron_should_fire
--   -> cron_should_fire, exos_cron_invoke_edge_fn -> _cron_invoke_edge_fn),
--   then drop the two new functions.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. The edge-function call, owned by Exos: prod's body, unchanged.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.exos_cron_invoke_edge_fn(p_url text, p_body jsonb)
RETURNS bigint
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE v_jwt text; v_cron text; v_req_id bigint;
BEGIN
  SELECT decrypted_secret INTO v_jwt  FROM vault.decrypted_secrets WHERE name = 'EDGE_FN_ANON_JWT';
  SELECT decrypted_secret INTO v_cron FROM vault.decrypted_secrets WHERE name = 'CRON_SECRET';
  IF v_jwt IS NULL OR v_cron IS NULL THEN
    RAISE EXCEPTION 'edge fn auth secrets missing from vault';
  END IF;
  SELECT net.http_post(
    url := p_url,
    headers := jsonb_build_object('Content-Type','application/json','Authorization','Bearer ' || v_jwt,'X-Cron-Secret',v_cron),
    body := p_body, timeout_milliseconds := 60000
  ) INTO v_req_id;
  RETURN v_req_id;
END $$;
REVOKE ALL ON FUNCTION public.exos_cron_invoke_edge_fn(text, jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_cron_invoke_edge_fn(text, jsonb) TO service_role;

-- ---------------------------------------------------------------------------
-- 2. The gate, owned by Exos: one run of a job at a time. A second run that
--    starts while the first still holds the lock skips (returns false). The
--    lock is the transaction's, so it is released when the run commits.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.exos_cron_should_fire(p_jobname text)
RETURNS boolean
LANGUAGE sql VOLATILE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT p_jobname IS NOT NULL
     AND pg_try_advisory_xact_lock(hashtext('exos_cron:' || p_jobname)::bigint)
$$;
REVOKE ALL ON FUNCTION public.exos_cron_should_fire(text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_cron_should_fire(text) TO service_role;

-- ---------------------------------------------------------------------------
-- 3. Exos functions: call the Exos helpers.
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  r     record;
  v_def text;
  v_new text;
  v_n   int := 0;
BEGIN
  FOR r IN
    SELECT p.oid
      FROM pg_proc p
     WHERE p.pronamespace = 'public'::regnamespace
       AND p.proname LIKE '%exos%'
       AND p.proname NOT IN ('exos_cron_should_fire', 'exos_cron_invoke_edge_fn')
       AND p.prokind IN ('f', 'p')
       AND p.prosrc ~ '\m(cron_should_fire|_cron_invoke_edge_fn)\s*\('
  LOOP
    v_def := pg_get_functiondef(r.oid);
    v_new := regexp_replace(v_def, '\mcron_should_fire(\s*\()', 'exos_cron_should_fire\1', 'g');
    v_new := regexp_replace(v_new, '\m_cron_invoke_edge_fn(\s*\()', 'exos_cron_invoke_edge_fn\1', 'g');
    IF v_new <> v_def THEN
      EXECUTE v_new;
      v_n := v_n + 1;
    END IF;
  END LOOP;
  RAISE NOTICE 'exos_own_cron_helpers: % function(s) re-pointed', v_n;
END $$;

-- ---------------------------------------------------------------------------
-- 4. Exos crons: call the Exos helpers. Only the command changes. Skipped
--    where pg_cron isn't installed (the SQL harness).
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  j     record;
  v_cmd text;
  v_n   int := 0;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    RAISE NOTICE 'exos_own_cron_helpers: no pg_cron, crons skipped';
    RETURN;
  END IF;

  FOR j IN
    SELECT jobid, jobname, command
      FROM cron.job
     WHERE jobname ILIKE '%exos%'
       AND command ~ '\m(cron_should_fire|_cron_invoke_edge_fn)\s*\('
  LOOP
    v_cmd := regexp_replace(j.command, '\mcron_should_fire(\s*\()', 'exos_cron_should_fire\1', 'g');
    v_cmd := regexp_replace(v_cmd, '\m_cron_invoke_edge_fn(\s*\()', 'exos_cron_invoke_edge_fn\1', 'g');
    PERFORM cron.alter_job(job_id := j.jobid, command := v_cmd);
    v_n := v_n + 1;
  END LOOP;

  -- exos-mail-drain-2min: Terminal-2's gate skipped it unless there was mail
  -- to claim (its cron_policy work check). The check now sits in the command,
  -- just before the call, worded as in that row. Added once.
  FOR j IN
    SELECT jobid, command
      FROM cron.job
     WHERE jobname = 'exos-mail-drain-2min'
       AND command !~ 'exos_mail\M'
       AND command ~* 'perform\s+public\.exos_cron_invoke_edge_fn\s*\('
  LOOP
    v_cmd := regexp_replace(j.command,
      '(perform\s+public\.exos_cron_invoke_edge_fn\s*\()',
      'if not exists (select 1 from public.exos_mail where status in (''pending'', ''sending'') and attempts < 5) then return; end if; \1',
      'i');
    PERFORM cron.alter_job(job_id := j.jobid, command := v_cmd);
  END LOOP;

  RAISE NOTICE 'exos_own_cron_helpers: % cron command(s) re-pointed', v_n;
END $$;
