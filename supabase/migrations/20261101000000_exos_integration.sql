-- ============================================================================
-- Build-phase integration fixes (2026-11-01)
-- ============================================================================
-- The build-phase branches were written in parallel. Each one passes on its
-- own; this migration holds the few places where two of them redefine the same
-- logic and the later one, unaware of the other, drops a rule. Each section
-- names the two migrations and what is kept from each. Re-run safe: CREATE OR
-- REPLACE only.
--
-- Touches:  R: FUNCTION exos_event_buy_link (section 1)
--           R: FUNCTION exos_api_scope_names (section 2)
-- Pre-reqs: every exos migration before this one.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. Where to buy for a fixed-block event at last call.
--    20261029160000 (fixed block) made exos_public_event_sale treat
--    primary_source 'external' as Exos: Exos sells its own block at last call.
--    20261029170000 (event import) rebuilt exos_public_event_sale on top of
--    exos_event_buy_link, whose last-call branch only excludes 'exos', so a
--    block event at last call sent buyers to a NULL 'external' page.
--    Kept: #63's single where-to-buy function (link-out, sold elsewhere, last
--    call) plus #60's rule that 'external' is not a primary that takes the sale.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.exos_event_buy_link(p_event_id uuid)
RETURNS TABLE (sells_on text, url text, link_out boolean)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT CASE WHEN e.link_out THEN coalesce(i.platform, e.ticket_backend)
              WHEN e.ticket_backend <> 'exos' AND e.external_ticket_url IS NOT NULL THEN e.ticket_backend
              WHEN x.lc AND e.primary_source NOT IN ('exos', 'external') THEN e.primary_source   -- fixed block (mig 20261029160000)
              ELSE 'exos' END,
         CASE WHEN e.link_out THEN coalesce(i.source_url, e.external_ticket_url)
              WHEN e.ticket_backend <> 'exos' AND e.external_ticket_url IS NOT NULL THEN e.external_ticket_url
              WHEN x.lc AND e.primary_source NOT IN ('exos', 'external') THEN public._exos_primary_url(e.id)
         END,
         e.link_out
    FROM public.exos_events e
    LEFT JOIN public.exos_event_imports i ON i.event_id = e.id
    CROSS JOIN LATERAL (SELECT public.exos_event_last_call(e.id) AS lc) x
   WHERE e.id = p_event_id
$$;
REVOKE ALL ON FUNCTION public.exos_event_buy_link(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_event_buy_link(uuid) TO service_role;

-- ---------------------------------------------------------------------------
-- 2. Partner API scopes: the union.
--    20261031110000 (core API) added refunds:write and 20261031120000 (fans)
--    added fans:read / fans:write; each redefined exos_api_scope_names() from
--    the 15-scope list, so the later one dropped refunds:write and a key could
--    no longer be given the refund scope. Same order as SCOPES in
--    supabase/functions/_shared/api/scopes.ts (src/lib/apiScopes.test.ts reads
--    the latest definition); org:admin stays last.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.exos_api_scope_names()
RETURNS text[]
LANGUAGE sql IMMUTABLE
SET search_path = public, pg_temp
AS $$
  SELECT ARRAY[
    'events:read', 'events:write', 'orders:read', 'refunds:write', 'fans:read', 'fans:write', 'tickets:read',
    'tickets:write', 'checkin:write', 'booking:read', 'booking:write', 'finance:read', 'finance:write',
    'commerce:read', 'commerce:write', 'webhooks:read', 'webhooks:write', 'org:admin'
  ]::text[]
$$;
REVOKE ALL ON FUNCTION public.exos_api_scope_names() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.exos_api_scope_names() TO authenticated, service_role;
