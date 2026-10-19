// Channels: the Exos event mirrored on Luma (mig 20261019090000; Luma's
// openapi.json). Exos is the source: this creates the event on the org's Luma
// calendar (or keeps a linked one) in step with Exos (details, ticket types with
// prices), keeps each ticket type's capacity at the shared count (from the
// guests Luma reports), and, on a Luma-primary event, adds comp guests.
//
// Writes are limited to LUMA_WRITES and go out only when the org's switch and
// EXOS_LUMA_WRITES=on are both set; otherwise the plan is recorded (dry run).
// Never: refunds, guest status changes, cancellations (Luma's cancel refunds
// and deletes: Exos only closes registration), blasts, coupons, webhooks.
import { firstCapacity, type Io, type MirrorEvent, type MirrorTier, type SyncResult, type StepRecord } from "./model.ts";

export const LUMA_BASE = "https://public-api.luma.com";

export const LUMA_WRITES: RegExp[] = [
  /^\/v1\/events\/create$/,
  /^\/v1\/events\/update$/,
  /^\/v1\/events\/ticket-types\/create$/,
  /^\/v1\/events\/ticket-types\/update$/,
  /^\/v1\/events\/guests\/add$/,
];

export function lumaStandIn(path: string): any {
  if (path === "/v1/events/create") return { id: "evt-planned" };
  if (path === "/v1/events/ticket-types/create") return { id: "ttype-planned" };
  if (path === "/v1/events/guests/add") return { skipped: [] };
  return {};
}

/** Luma ticket type names are 1-30 characters; keep them unique within the event. */
export function lumaTicketNames(tiers: MirrorTier[]): Map<string, string> {
  const out = new Map<string, string>();
  const used = new Set<string>();
  for (const t of tiers) {
    let n = t.name.slice(0, 30).trim() || "Ticket";
    for (let i = 2; used.has(n.toLowerCase()); i++) n = `${t.name.slice(0, 30 - String(i).length - 1).trim()} ${i}`;
    used.add(n.toLowerCase());
    out.set(t.id, n);
  }
  return out;
}

export function lumaTicketBody(t: MirrorTier, ev: MirrorEvent, name: string, create: boolean) {
  const base: Record<string, unknown> = {
    name,
    type: t.free ? "free" : "paid",
    is_hidden: t.hidden,
    ...(t.description ? { description: t.description.slice(0, 1000) } : {}),
    ...(t.free ? {} : { cents: t.priceCents, currency: ev.currency.toLowerCase() }),
  };
  if (create) base.max_capacity = firstCapacity(t, ev.pack);
  return base;
}

export function lumaEventBody(ev: MirrorEvent) {
  return {
    name: ev.name,
    start_at: ev.startUtc,
    end_at: ev.endUtc,
    timezone: ev.timezone,
    description_md: ev.descriptionMd,
    ...(ev.venueQuery ? { geo_address_json: { type: "lookup", query: ev.venueQuery } } : {}),
  };
}

const fail = (steps: StepRecord[], what: string, error?: string): SyncResult =>
  ({ state: "error", error: `Luma: ${what} (${error ?? "failed"})`.slice(0, 300), plan: { steps } });

/** Details pass: create or update the event and its ticket types. */
export async function syncLuma(io: Io, ev: MirrorEvent, payload: any, steps: StepRecord[], hash: string): Promise<SyncResult> {
  const mirror = payload?.mirror ?? {};
  const meta: Record<string, any> = { ...(mirror.external_meta ?? {}) };
  let id: string | null = typeof mirror.external_id === "string" ? mirror.external_id : null;
  let url: string | null = mirror.external_url ?? null;
  const changed = mirror.last_hash !== hash;
  const todo = ev.tiers.filter((t) => !t.skip);
  const names = lumaTicketNames(todo);
  const maps = new Map<string, string>((payload?.maps ?? []).map((m: any) => [String(m.tier_id), String(m.external_ticket_id)]));

  if (ev.status === "cancelled") {
    if (id && !meta.closed) {
      const r = await io.req("POST", "/v1/events/update", { event_id: id, registration_open: false });
      if (!r.ok) return fail(steps, "couldn't close registration", r.error);
      meta.closed = true;
    }
    return done(io, steps, id, url, meta, hash, []);
  }

  if (!id) {
    if (mirror.mode === "link") return fail(steps, "no event to link");
    if (todo.length === 0) return fail(steps, "add a ticket type with a capacity first");
    const r = await io.req("POST", "/v1/events/create", {
      ...lumaEventBody(ev),
      ticket_types: todo.map((t) => lumaTicketBody(t, ev, names.get(t.id) as string, true)),
    });
    if (!r.ok || typeof r.body?.id !== "string") return fail(steps, "couldn't create the event", r.error);
    id = r.body.id;
  } else if (changed || ev.status === "published" && meta.closed) {
    const r = await io.req("POST", "/v1/events/update", { event_id: id, ...lumaEventBody(ev), ...(meta.closed ? { registration_open: true } : {}) });
    if (!r.ok) return fail(steps, "couldn't update the event", r.error);
    meta.closed = false;
  }
  const eventId = id as string;

  // Ticket types: match by name once (a new or linked event), then by mapping.
  let existing: any[] = [];
  if (eventId !== "evt-planned" && todo.some((t) => !maps.has(t.id))) {
    const r = await io.req("GET", `/v1/events/ticket-types/list?${new URLSearchParams({ event_id: eventId, include_hidden: "true" })}`);
    existing = r.ok && Array.isArray(r.body?.entries) ? r.body.entries : [];
  }
  const tickets: { tier_id: string; external_ticket_id: string; name: string }[] = [];
  for (const t of todo) {
    const name = names.get(t.id) as string;
    let ttype = maps.get(t.id) ?? existing.find((x: any) => typeof x?.name === "string" && x.name.trim().toLowerCase() === name.toLowerCase())?.id ?? null;
    if (!ttype && eventId === "evt-planned") ttype = "ttype-planned";   // created with the event (dry run)
    if (!ttype) {
      const r = await io.req("POST", "/v1/events/ticket-types/create", { event_id: eventId, ...lumaTicketBody(t, ev, name, true) });
      if (!r.ok || typeof r.body?.id !== "string") return fail(steps, `couldn't add the ticket "${name}"`, r.error);
      ttype = r.body.id;
    } else if (changed && maps.has(t.id)) {
      const r = await io.req("POST", "/v1/events/ticket-types/update", { event_ticket_type_id: ttype, ...lumaTicketBody(t, ev, name, false) });
      if (!r.ok) return fail(steps, `couldn't update the ticket "${name}"`, r.error);
    }
    tickets.push({ tier_id: t.id, external_ticket_id: ttype as string, name });
  }

  if (!url && eventId !== "evt-planned") {
    const r = await io.req("GET", `/v1/events/get?${new URLSearchParams({ event_id: eventId })}`);
    if (r.ok && typeof r.body?.url === "string" && r.body.url.startsWith("https://")) url = r.body.url;
  }
  return done(io, steps, eventId, url, meta, hash, tickets);
}

function done(io: Io, steps: StepRecord[], id: string | null, url: string | null, meta: Record<string, unknown>,
              hash: string, tickets: SyncResult["tickets"]): SyncResult {
  if (!io.live) return { state: "dry_run", plan: { steps } };
  return {
    state: "synced", ...(id ? { external_id: id } : {}), ...(url ? { external_url: url } : {}),
    external_meta: meta, hash, plan: { steps }, tickets,
  };
}

/** Tickets held per Luma ticket type: approved (and session) guests' tickets. */
export async function lumaTicketCounts(io: Io, eventId: string, maxPages = 40): Promise<{ counts: Map<string, number>; complete: boolean; error?: string }> {
  const counts = new Map<string, number>();
  let cursor: string | null = null;
  for (let i = 0; i < maxPages; i++) {
    const q = new URLSearchParams({ event_id: eventId, pagination_limit: "100", sort_column: "created_at", sort_direction: "asc" });
    if (cursor) q.set("pagination_cursor", cursor);
    const r = await io.req("GET", `/v1/events/guests/list?${q}`);
    if (!r.ok) return { counts, complete: false, error: r.error };
    for (const g of Array.isArray(r.body?.entries) ? r.body.entries : []) {
      if (g?.approval_status !== "approved" && g?.approval_status !== "session") continue;
      for (const t of Array.isArray(g.event_tickets) ? g.event_tickets : []) {
        const tt = t?.event_ticket_type_id;
        if (typeof tt === "string") counts.set(tt, (counts.get(tt) ?? 0) + 1);
      }
    }
    cursor = r.body?.has_more === true && typeof r.body?.next_cursor === "string" ? r.body.next_cursor : null;
    if (!cursor) return { counts, complete: true };
  }
  return { counts, complete: false, error: "too many guests for one pass" };
}

export function capacityUpdate(ttype: string, target: number | null, current: number | null) {
  if (target == null || !Number.isInteger(target) || target < 0 || target === current) return null;
  return { event_ticket_type_id: ttype, max_capacity: target };
}

export function compBody(eventId: string, ttype: string, guests: { email: string; name: string | null }[], sendEmail: boolean) {
  return {
    event_id: eventId,
    guests: guests.map((g) => ({ email: g.email, ...(g.name ? { name: g.name } : {}) })),
    ticket: { event_ticket_type_id: ttype },
    send_email: sendEmail,
  };
}
