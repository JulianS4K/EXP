// claude/exos-buyer-geo-genre (mig 20261106140000): where buyers are and the
// genres in use, for an organization's API key.
//
//   GET /v1/events/:id/buyer-locations   orders:read   one event's report
//   GET /v1/buyer-locations              orders:read   the organization's,
//                                                      ?since= (ISO date)
//   GET /v1/genres                       events:read   genres on the org's events
//
// Both reports are _exos_buyer_geo (service role, scoped to the key's org in
// SQL): orders, tickets and gross per country and per city, plus the orders
// with no location (free orders, RSVPs, orders before the location was
// recorded). Locations come from the billing address Stripe or PayPal gave
// (country, region, city, postal code; never a street, never an IP lookup),
// and the report itself carries no postal code. ?limit= caps the country and
// city lists (1-100, default 10).
//
// The ?genre= / ?genres= filter on GET /v1/events lives in index.ts
// (eventIdsByGenre below); the public discovery side in _shared/api/publicDiscovery.ts.

import type { SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2";
import type { ApiRoute } from "../_shared/api/routes.ts";
import { GeoGenreError, reportLimit, reportSince } from "../_shared/api/buyerLocations.ts";

export { GeoGenreError };

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

/** The route ids this module answers. */
export const GEO_GENRE_ROUTES = new Set(["get-event-buyer-locations", "get-buyer-locations", "list-genres"]);

export interface GeoGenreCtx {
  sb: SupabaseClient;
  orgId: string;
  params: Record<string, string>;
  q: URLSearchParams;
}

/** The org's events (any status) with at least one of the genre keys; never empty (PostgREST needs a list). */
export async function eventIdsByGenre(sb: SupabaseClient, orgId: string, keys: string[]): Promise<string[]> {
  const { data, error } = await sb.rpc("_exos_org_event_ids_by_genre", { p_org: orgId, p_genres: keys });
  if (error) throw error;
  const ids = ((data ?? []) as string[]).slice(0, 10000);
  // The nil UUID matches nothing.
  return ids.length ? ids : ["00000000-0000-0000-0000-000000000000"];
}

export async function handleGeoGenre(route: ApiRoute, c: GeoGenreCtx): Promise<unknown> {
  switch (route.id) {
    case "get-event-buyer-locations": {
      const id = c.params.id ?? "";
      if (!UUID_RE.test(id)) throw new GeoGenreError(404, "event not found");
      const limit = reportLimit(c.q);
      const { data: ev, error: evErr } = await c.sb.from("exos_events").select("id")
        .eq("org_id", c.orgId).eq("id", id).maybeSingle();
      if (evErr) throw evErr;
      if (!ev) throw new GeoGenreError(404, "event not found");
      const { data, error } = await c.sb.rpc("_exos_buyer_geo", {
        p_org: c.orgId, p_event: id, p_since: null, p_limit: limit,
      });
      if (error) throw error;
      return { data };
    }
    case "get-buyer-locations": {
      const limit = reportLimit(c.q);
      const since = reportSince(c.q);
      const { data, error } = await c.sb.rpc("_exos_buyer_geo", {
        p_org: c.orgId, p_event: null, p_since: since, p_limit: limit,
      });
      if (error) throw error;
      return { data };
    }
    case "list-genres": {
      const { data, error } = await c.sb.rpc("_exos_org_genres", { p_org: c.orgId });
      if (error) throw error;
      return { data: data ?? [] };
    }
  }
  throw new GeoGenreError(404, "not found");
}

/**
 * GET /v1/orders/:id's buyer_location: { country, region, city, postal_code,
 * source } or null (no location, or the migration not applied yet: a
 * missing table never fails the order read).
 */
export async function orderLocation(sb: SupabaseClient, orgId: string, sessionId: string): Promise<unknown> {
  const { data, error } = await sb.from("exos_order_locations")
    .select("country, region, city, postal_code, source")
    .eq("org_id", orgId).eq("session_id", sessionId).maybeSingle();
  if (error) {
    if (error.code === "42P01" || error.code === "PGRST205") return null;
    throw error;
  }
  return data ?? null;
}
