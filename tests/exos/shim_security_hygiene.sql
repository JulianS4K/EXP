-- ============================================================================
-- Harness shim, run by run_p0.sh's apply() just before
-- 20261109110000_exos_security_hygiene. Test harness only, never a migration.
--
-- 1. Prod's state that migration cleans up and the chain doesn't build: the
--    leftover exos_paste_probe table (one row), and the anon EXECUTE that
--    Supabase's default privileges put on _exos_site_error /
--    _exos_door_code_loose. (The anon sequence grants come from the default
--    privileges in prereq_supabase.sql.)
-- 2. The exos_* policy set as it is before the migration, for
--    test_security_hygiene.sql S4 (same name, command, roles, permissive flag,
--    and the same expressions apart from the auth.* wrapping). Printed with an
--    empty search_path, so every name is schema-qualified. Schema `harness`,
--    outside public, so no exos_* check sees it.
-- ============================================================================
CREATE TABLE IF NOT EXISTS public.exos_paste_probe (id int, note text);
INSERT INTO public.exos_paste_probe SELECT 1, 'pasted' WHERE NOT EXISTS (SELECT 1 FROM public.exos_paste_probe);
GRANT EXECUTE ON FUNCTION public._exos_site_error(jsonb), public._exos_door_code_loose(text) TO anon;

CREATE SCHEMA IF NOT EXISTS harness;
DROP TABLE IF EXISTS harness.policies_before;
SET search_path = '';
CREATE TABLE harness.policies_before AS
SELECT c.relname::text AS relname, p.polname::text AS polname, p.polcmd::text AS cmd, p.polpermissive AS permissive,
       ARRAY(SELECT CASE WHEN r = 0 THEN 'public' ELSE r::regrole::text END FROM unnest(p.polroles) r ORDER BY 1) AS roles,
       pg_catalog.pg_get_expr(p.polqual, p.polrelid) AS qual,
       pg_catalog.pg_get_expr(p.polwithcheck, p.polrelid) AS chk
  FROM pg_catalog.pg_policy p
  JOIN pg_catalog.pg_class c ON c.oid = p.polrelid
  JOIN pg_catalog.pg_namespace s ON s.oid = c.relnamespace
 WHERE s.nspname = 'public' AND c.relname LIKE 'exos\_%';
RESET search_path;
