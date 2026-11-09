// exos-api: an event's location (venue record, unlisted venue, secret
// location, to be announced) and the "this venue is on Exos" suggestion
// (mig 20261105130000, docs/promoter-events.md). Dispatched from index.ts by
// route id.
//
// The function runs with the service role: every call names the key's org
// (c.orgId) and the SQL cores take it, so another org's event is a 404.
// A secret_location event's exact address is the organizer's: GET answers
// it only to a credential that may edit events (events:write); the public
// part (mode, area, reveal time, sales choice) to any events:read one.
// Nothing here is a public endpoint: partners (/public/…) and the listing
// feed read the event row, which never carries the secret address.

import type { SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2";
import type { ApiRoute } from "../_shared/api/routes.ts";
import { hasScope } from "../_shared/api/scopes.ts";

/** The route ids this module answers. */
export const LOCATION_ROUTES = new Set(["get-event-location", "set-event-location", "list-venue-matches"]);

export interface LocationCtx {
  sb: SupabaseClient;
  orgId: string;
  cred: { kind: "api_key" | "pat" | "oauth"; id: string; scopes: string[] };
  params: Record<string, string>;
  q: URLSearchParams;
  body: Record<string, unknown>;
}

/** An answer with a status (index.ts sends it as JSON). */
export class LocationError extends Error {
  constructor(public status: number, message: string, public extra: Record<string, unknown> = {}) {
    super(message);
  }
}

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
/** The keys PUT /events/:id/location takes (the SQL checks them again). */
export const LOCATION_FIELDS = [
  "location_mode", "venue_name", "venue_location", "area", "venue_address", "location_reveal_at",
  "reveal_hours_before", "tba_allow_sales", "secret_location",
] as const;

/** The body, or its one wrapped object ({ location: {...} }). */
export function unwrapLocation(b: Record<string, unknown>): Record<string, unknown> {
  const inner = b.location;
  if (inner && typeof inner === "object" && !Array.isArray(inner) && Object.keys(b).length === 1) {
    return inner as Record<string, unknown>;
  }
  return b;
}

/** A first-pass check of a location body (the SQL is the authority); null when fine. */
export function locationBodyProblem(b: Record<string, unknown>): string | null {
  const extra = Object.keys(b).find((k) => !(LOCATION_FIELDS as readonly string[]).includes(k));
  if (extra) return `unknown field ${extra.slice(0, 60)}`;
  if (Object.keys(b).length === 0) return "send at least one location field";
  return null;
}

/** The SQL's refusals as HTTP answers. */
export function locationDbError(e: unknown): LocationError {
  const err = e as { code?: unknown; message?: unknown } | null;
  const code = typeof err?.code === "string" ? err.code : "";
  const message = String(err?.message ?? "request refused").slice(0, 400);
  if (code === "P0002") return new LocationError(404, "event not found");
  if (code === "42501") return new LocationError(403, message);
  if (code === "22023" || code === "23514" || code === "22P02" || code === "22007" || code === "22008") {
    return new LocationError(400, message);
  }
  return new LocationError(500, "internal error");
}

// deno-lint-ignore no-explicit-any
async function rpc(c: LocationCtx, fn: string, args: Record<string, unknown>): Promise<any> {
  const { data, error } = await c.sb.rpc(fn, args);
  if (error) throw locationDbError(error);
  return data;
}

async function ownEvent(c: LocationCtx): Promise<string> {
  const id = c.params.id;
  if (!id || !UUID_RE.test(id)) throw new LocationError(404, "event not found");
  const { data, error } = await c.sb.from("exos_events").select("id").eq("id", id).eq("org_id", c.orgId).maybeSingle();
  if (error) throw locationDbError(error);
  if (!data) throw new LocationError(404, "event not found");
  return id;
}

/** Handles one of this module's routes. */
export async function handleLocation(route: ApiRoute, c: LocationCtx): Promise<unknown> {
  switch (route.id) {
    case "get-event-location": {
      const id = await ownEvent(c);
      const editor = hasScope(c.cred.scopes, "events:write");
      const loc = await rpc(c, "_exos_event_location_json", { p_event_id: id, p_secret: editor }) as Record<string, unknown>;
      const matches = editor ? await rpc(c, "_exos_event_venue_matches", { p_event_id: id }) : [];
      if (!editor) delete loc.secret_location;
      return { data: { ...loc, venue_suggestions: matches } };
    }

    case "set-event-location": {
      const id = await ownEvent(c);
      if (c.cred.kind !== "api_key") throw new LocationError(403, "this write needs an organization API key (sk_live_…)");
      const body = unwrapLocation(c.body);
      const problem = locationBodyProblem(body);
      if (problem) throw new LocationError(400, problem);
      const uid = await rpc(c, "_exos_api_key_actor", { p_org: c.orgId, p_api_key: c.cred.id, p_roles: ["owner", "manager"] });
      return { data: await rpc(c, "_exos_event_location_set", { p_org: c.orgId, p_event: id, p_actor: uid, p: body }) };
    }

    // "This venue is on Exos": owned venues of other organizations that take
    // booking requests, with this exact name and city. A suggestion only.
    case "list-venue-matches": {
      const name = (c.q.get("name") ?? "").trim();
      const city = (c.q.get("city") ?? "").trim();
      if (!name || !city) throw new LocationError(400, "name and city are required");
      if (name.length > 200 || city.length > 120) throw new LocationError(400, "name or city too long");
      return { data: await rpc(c, "_exos_location_venue_matches", { p_org: c.orgId, p_name: name, p_city: city }) };
    }
  }
  throw new LocationError(404, "not found");
}
