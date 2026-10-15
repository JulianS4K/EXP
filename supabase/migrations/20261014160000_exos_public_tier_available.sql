-- ============================================================================
-- Public tiers say what Exos itself can sell (for the Meta / TikTok / Google
-- catalog feed and the MCP tools for Claude and ChatGPT)
-- ============================================================================
-- Touches:  W: VIEW exos_public_tiers (+ available, last column)
-- Pre-reqs: 20261014150000 (pools, primary hold) and earlier view versions
--
-- The catalog feed (exos-catalog-feed) and the MCP tools (exos-mcp) worked out
-- "in stock" / "how many left" from capacity - sold. With marketplace pools,
-- S4K's pool and the primary hold, part of what's unsold isn't Exos's to sell:
-- an ad or an assistant could send a buyer to a checkout that then says sold
-- out. `available` is exos_effective_available (what an Exos checkout can
-- take now: S4K's and the marketplaces' pools, cart holds, blocking vouchers,
-- quotas and the Eventbrite primary hold left out); NULL = no cap. Exos sales
-- from those links come out of the Exos + Eventbrite pool.
--
-- Same columns, in the same order, plus one at the end (CREATE OR REPLACE
-- VIEW can only add at the end); grants and options are kept.
--
-- Re-run safe. Prod apply needs operator OK.
-- ============================================================================

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
       public.exos_effective_available(t.id) AS available
  FROM public.exos_ticket_tiers t
  JOIN public.exos_events e ON e.id = t.event_id
 WHERE t.visibility = 'public' AND e.status = 'published';

COMMENT ON COLUMN public.exos_public_tiers.available IS
  'What an Exos checkout can sell now (exos_effective_available; NULL = no cap). mig 20261014160000.';
