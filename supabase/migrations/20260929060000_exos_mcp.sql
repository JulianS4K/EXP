-- ============================================================================
-- Migration 20260929060000 — Exos (Bridge / D4): MCP server reads
--
-- Lane:     d4 (exos / bridge ticketing infra)
-- Touches:  C: TABLE exos_rate_windows; FUNCTION exos_rate_hit,
--              exos_mcp_event_sales, exos_mcp_door_status
-- Pre-reqs: 20260929052000
--
-- The exos-mcp edge function (docs/mcp.md) lets AI assistants (Claude,
-- ChatGPT) find events and, with an organizer's Exos API key, read that org's
-- sales and door numbers. These are its database reads: aggregates computed
-- here rather than by paging rows through the API, each scoped to the org the
-- key belongs to, and a generic fixed-window rate limit (the public tools have
-- no key to count against, so they count per hashed network). All service
-- role only; nothing here is callable by the app's users.
--
-- Re-run safe (IF NOT EXISTS / CREATE OR REPLACE). D4 authors; applying to
-- prod is operator-gated.
-- ============================================================================

CREATE TABLE IF NOT EXISTS public.exos_rate_windows (
  bucket       text        NOT NULL,
  window_start timestamptz NOT NULL,
  hits         int         NOT NULL DEFAULT 0,
  PRIMARY KEY (bucket, window_start)
);
ALTER TABLE public.exos_rate_windows ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.exos_rate_windows FROM PUBLIC, anon, authenticated;

-- One hit on `bucket` in this clock minute; true while within `p_limit`.
CREATE OR REPLACE FUNCTION public.exos_rate_hit(p_bucket text, p_limit integer)
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_win timestamptz := date_trunc('minute', now()); v_n int;
BEGIN
  IF p_bucket IS NULL OR length(p_bucket) > 200 THEN RETURN false; END IF;
  INSERT INTO public.exos_rate_windows (bucket, window_start, hits) VALUES (p_bucket, v_win, 1)
  ON CONFLICT (bucket, window_start) DO UPDATE SET hits = public.exos_rate_windows.hits + 1
  RETURNING hits INTO v_n;
  -- Sweep old windows now and then (one call in ~100).
  IF random() < 0.01 THEN
    DELETE FROM public.exos_rate_windows WHERE window_start < now() - interval '1 hour';
  END IF;
  RETURN v_n <= greatest(coalesce(p_limit, 0), 0);
END $$;
REVOKE ALL ON FUNCTION public.exos_rate_hit(text, integer) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_rate_hit(text, integer) TO service_role;

-- Sales for one of the org's events: per ticket type, paid orders, gross and
-- refunds. NULL when the event isn't the org's.
CREATE OR REPLACE FUNCTION public.exos_mcp_event_sales(p_org_id uuid, p_event_id uuid)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT jsonb_build_object(
    'event', jsonb_build_object('id', e.id, 'name', e.name, 'status', e.status, 'starts_at', e.starts_at,
                                'venue_name', e.venue_name, 'tickets_sold', e.tickets_sold, 'total_tickets', e.total_tickets),
    'tiers', coalesce((SELECT jsonb_agg(jsonb_build_object('name', t.name, 'price', t.price, 'capacity', t.capacity, 'sold', t.sold)
                                ORDER BY t.sort_order, t.name)
                         FROM public.exos_ticket_tiers t WHERE t.event_id = e.id), '[]'::jsonb),
    'orders', jsonb_build_object(
      'paid', (SELECT count(*) FROM public.exos_checkout_sessions s
                WHERE s.event_id = e.id AND s.amount_cents > 0
                  AND s.status IN ('fulfilled', 'refunded', 'partially_refunded')),
      'gross_cents', (SELECT coalesce(sum(s.amount_cents), 0) FROM public.exos_checkout_sessions s
                       WHERE s.event_id = e.id AND s.status IN ('fulfilled', 'refunded', 'partially_refunded')),
      'refunded_cents', (SELECT coalesce(sum(r.amount_cents), 0) FROM public.exos_order_refunds r
                          JOIN public.exos_checkout_sessions s ON s.session_id = r.session_id
                         WHERE s.event_id = e.id AND r.status = 'succeeded'),
      'currency', upper(coalesce(e.currency, 'usd'))))
    FROM public.exos_events e
   WHERE e.id = p_event_id AND e.org_id = p_org_id;
$$;
REVOKE ALL ON FUNCTION public.exos_mcp_event_sales(uuid, uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_mcp_event_sales(uuid, uuid) TO service_role;

-- The door for one of the org's events: issued / checked in / voided, last scan.
CREATE OR REPLACE FUNCTION public.exos_mcp_door_status(p_org_id uuid, p_event_id uuid)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT jsonb_build_object(
    'event', jsonb_build_object('id', e.id, 'name', e.name, 'status', e.status, 'starts_at', e.starts_at,
                                'venue_name', e.venue_name, 'tickets_sold', e.tickets_sold, 'total_tickets', e.total_tickets),
    'issued', (SELECT count(*) FROM public.exos_tickets t WHERE t.event_id = e.id AND t.status IN ('active', 'used')),
    'checked_in', (SELECT count(*) FROM public.exos_tickets t WHERE t.event_id = e.id AND t.status = 'used'),
    'voided', (SELECT count(*) FROM public.exos_tickets t WHERE t.event_id = e.id AND t.status = 'voided'),
    'last_scan_at', (SELECT max(c.scanned_at) FROM public.exos_event_checkins c WHERE c.event_id = e.id))
    FROM public.exos_events e
   WHERE e.id = p_event_id AND e.org_id = p_org_id;
$$;
REVOKE ALL ON FUNCTION public.exos_mcp_door_status(uuid, uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_mcp_door_status(uuid, uuid) TO service_role;
