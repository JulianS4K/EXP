-- ============================================================================
-- Hotfix: event pages show no tickets (exos_public_tiers.available)
-- ============================================================================
-- Touches:  W: FUNCTION exos_public_tier_available (new), VIEW exos_public_tiers
-- Pre-reqs: 20261014160000 (the `available` column)
--
-- 20261014160000 added `available` to exos_public_tiers by calling
-- exos_effective_available, whose client EXECUTE was revoked in
-- 20260925003000 (anyone could read hidden-tier stock through it). Postgres
-- checks EXECUTE on a function in a view against the reader, so every
-- `select('*')` on the view by anon or a signed-in user fails with
-- "permission denied for function exos_effective_available" (checked on prod
-- 2026-10-28 with SET ROLE anon): event pages, home and org pages list no
-- tickets. Same failure as 2026-09-29 (docs/security.md, the tax-percent rows).
--
-- Fix without reopening the hidden-tier leak: a definer wrapper that answers
-- only for public tiers of published events (exactly the rows the view shows)
-- and NULL for anything else, callable by anon and authenticated; the view
-- uses it. Same columns in the same order; grants and options are kept.
--
-- Re-run safe. Prod apply needs operator OK.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.exos_public_tier_available(p_tier_id uuid)
RETURNS integer
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT CASE
           WHEN EXISTS (SELECT 1
                          FROM public.exos_ticket_tiers t
                          JOIN public.exos_events e ON e.id = t.event_id
                         WHERE t.id = p_tier_id AND t.visibility = 'public' AND e.status = 'published')
           THEN public.exos_effective_available(p_tier_id)
         END
$$;
REVOKE ALL ON FUNCTION public.exos_public_tier_available(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.exos_public_tier_available(uuid) TO anon, authenticated, service_role;
COMMENT ON FUNCTION public.exos_public_tier_available(uuid) IS
  'What an Exos checkout can sell now for a PUBLIC tier of a PUBLISHED event (exos_effective_available); NULL otherwise or when uncapped. Backs exos_public_tiers.available. mig 20261027080000.';

CREATE OR REPLACE VIEW public.exos_public_tiers
WITH (security_barrier = true)
AS
SELECT t.id,
       t.event_id,
       t.name,
       t.description,
       t.price,
       t.capacity,
       t.sold,
       t.ticket_type,
       t.sales_start,
       t.sales_end,
       t.sort_order,
       t.price_schedule,
       public.exos_tier_exclusive_tax_percent(t.id) AS exclusive_tax_percent,
       t.accessible,
       t.accessible_note,
       public.exos_public_tier_available(t.id) AS available
  FROM public.exos_ticket_tiers t
  JOIN public.exos_events e ON e.id = t.event_id
 WHERE t.visibility = 'public' AND e.status = 'published';

COMMENT ON COLUMN public.exos_public_tiers.available IS
  'What an Exos checkout can sell now (exos_public_tier_available; NULL = no cap). mig 20261027080000.';
