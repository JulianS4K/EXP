// Exos event -> StubHub "requested event" (PUT /sellerevents). Shared by the
// exos-distribute edge function (Deno) and EXP src/lib/marketplace/stubhub
// (vitest/tsc), so it has no imports.
//
// StubHub lets a seller ask for an event it doesn't have yet: PUT /sellerevents
// with the event name, start and venue, scope write:requestedevents. Exos
// queues one such request per published event that has StubHub in its
// distribution networks (mig 20260926190000). The request is built here from
// the exos_events row and, until an operator authorizes live writes, only
// recorded as the plan (dry-run).

export class ListingMappingError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "ListingMappingError";
  }
}

/** The Exos event, as StubHub's requested-event endpoints need it. */
export interface ExosEventForListing {
  name: string;
  startsAt: Date | string;
  venueName: string;
  venueCity: string;
  venueStateProvince?: string;
  /** Two-letter ISO 3166, e.g. "US". */
  countryCode?: string;
  /** Default true: Exos events have a fixed start. */
  dateConfirmed?: boolean;
}

/**
 * PutRequestedEventRequest: the body of both PUT /sellerevents (ask StubHub
 * to create the event) and PUT /listingconstraints (constraints for it).
 */
export interface RequestedEvent {
  event: { name: string; start_date: string; date_confirmed?: boolean; note?: string };
  venue: { name: string; city: string; state_province?: string };
  /** Two-letter ISO 3166. */
  country?: { code: string };
}

export function buildRequestedEvent(ev: ExosEventForListing): RequestedEvent {
  const start = ev.startsAt instanceof Date ? ev.startsAt : new Date(ev.startsAt);
  if (Number.isNaN(start.getTime())) throw new ListingMappingError("event start is not a date");
  if (!ev.name.trim()) throw new ListingMappingError("event name is required");
  if (!ev.venueName.trim() || !ev.venueCity.trim()) throw new ListingMappingError("venue name and city are required");
  if (ev.countryCode != null && !/^[A-Z]{2}$/.test(ev.countryCode)) {
    throw new ListingMappingError(`country must be ISO 3166 alpha-2, got "${ev.countryCode}"`);
  }
  const req: RequestedEvent = {
    event: { name: ev.name.trim(), start_date: start.toISOString(), date_confirmed: ev.dateConfirmed ?? true },
    venue: { name: ev.venueName.trim(), city: ev.venueCity.trim() },
  };
  if (ev.venueStateProvince) req.venue.state_province = ev.venueStateProvince;
  if (ev.countryCode) req.country = { code: ev.countryCode };
  return req;
}

// ── From the exos_events row ─────────────────────────────────────────

/** The exos_events columns the mapping reads. */
export interface ExosEventRow {
  name: string | null;
  starts_at: string | null;
  venue_name: string | null;
  venue_location?: string | null;
  /** CreateEvent/EditEvent shape: { street, city, region, country, postal }, all free text. */
  venue_address?: Record<string, unknown> | null;
}

// The address form is free text, so accept the usual spellings. Anything else
// is left off: country is optional for StubHub, and a wrong code is worse than none.
const COUNTRY_NAMES: Record<string, string> = {
  "us": "US", "usa": "US", "united states": "US", "united states of america": "US",
  "ca": "CA", "canada": "CA",
  "mx": "MX", "mexico": "MX", "méxico": "MX",
  "gb": "GB", "uk": "GB", "united kingdom": "GB", "great britain": "GB", "england": "GB",
  "scotland": "GB", "wales": "GB", "northern ireland": "GB",
  "ie": "IE", "ireland": "IE",
  "au": "AU", "australia": "AU",
  "nz": "NZ", "new zealand": "NZ",
  "de": "DE", "germany": "DE", "fr": "FR", "france": "FR", "es": "ES", "spain": "ES",
  "it": "IT", "italy": "IT", "nl": "NL", "netherlands": "NL",
};

/** ISO 3166 alpha-2 for a free-text country, or undefined when unsure. */
export function countryCode(raw: unknown): string | undefined {
  if (typeof raw !== "string") return undefined;
  const key = raw.trim().toLowerCase().replace(/\./g, "").replace(/\s+/g, " ");
  if (!key) return undefined;
  return COUNTRY_NAMES[key];
}

const text = (v: unknown): string => (typeof v === "string" ? v.trim() : "");

/**
 * Read the event off its exos_events row. City comes from the structured
 * address; without one there's no reliable city (venue_location is whatever
 * the organizer typed), so this throws and the organizer is told to add it.
 */
export function exosEventForListing(row: ExosEventRow): ExosEventForListing {
  const addr = row.venue_address ?? {};
  const venueName = text(row.venue_name) || text(row.venue_location);
  const venueCity = text(addr.city);
  if (!text(row.name)) throw new ListingMappingError("event name is required");
  if (!row.starts_at) throw new ListingMappingError("event start time is required");
  if (!venueName) throw new ListingMappingError("venue name is required");
  if (!venueCity) throw new ListingMappingError("venue city is required: add the venue address to the event");
  const out: ExosEventForListing = { name: text(row.name), startsAt: row.starts_at, venueName, venueCity };
  const region = text(addr.region);
  if (region) out.venueStateProvince = region;
  const cc = countryCode(addr.country);
  if (cc) out.countryCode = cc;
  return out;
}

/** The PUT /sellerevents call for this event, as the writer's dry-run would plan it. */
export interface PlannedEventRequest {
  endpoint: "createSellerEvent";
  method: "PUT";
  path: "/sellerevents";
  body: RequestedEvent;
}

export function planStubHubEventRequest(row: ExosEventRow): PlannedEventRequest {
  return {
    endpoint: "createSellerEvent",
    method: "PUT",
    path: "/sellerevents",
    body: buildRequestedEvent(exosEventForListing(row)),
  };
}
