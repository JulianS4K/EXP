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
//
// A live create is recorded first (hooks.beginCreate, mig 20261121100000) with
// a slug of Exos's own: Luma refuses a second event with that slug, and the
// next pass finds the first one by it (GET entities/lookup) before it creates
// again.
import {
  beginRefused, firstCapacity, type Io, notOnAccount, type MirrorEvent, type MirrorTicket, type MirrorTier, pendingCreate, type StepRecord,
  type SyncHooks, type SyncResult,
} from "./model.ts";

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
export async function syncLuma(io: Io, ev: MirrorEvent, payload: any, steps: StepRecord[], hash: string, hooks?: SyncHooks,
                               random: () => number = Math.random): Promise<SyncResult> {
  const mirror = payload?.mirror ?? {};
  const meta: Record<string, any> = { ...(mirror.external_meta ?? {}) };
  let id: string | null = typeof mirror.external_id === "string" ? mirror.external_id : null;
  let url: string | null = mirror.external_url ?? null;
  const changed = mirror.last_hash !== hash;
  const todo = ev.tiers.filter((t) => !t.skip);
  const names = lumaTicketNames(todo);
  const maps = new Map<string, string>((payload?.maps ?? []).map((m: any) => [String(m.tier_id), String(m.external_ticket_id)]));

  // A linked event not yet synced: this calendar must manage it (same answer
  // as another org's event, mig 20261121100000).
  if (id && mirror.status !== "synced") {
    const r = await io.req("GET", `/v1/events/get?${new URLSearchParams({ event_id: id })}`);
    if (!r.ok || r.body?.access !== "manage") return { state: "error", error: notOnAccount("luma"), plan: { steps } };
  }

  if (ev.status === "cancelled") {
    if (id && !meta.closed) {
      const r = await io.req("POST", "/v1/events/update", { event_id: id, registration_open: false });
      if (!r.ok) return fail(steps, "couldn't close registration", r.error);
      meta.closed = true;
    }
    return done(io, steps, id, url, meta, hash, []);
  }

  let createdWithEvent = false;
  if (!id) {
    if (mirror.mode === "link") return fail(steps, "no event to link");
    // A create recorded by an earlier pass: its slug finds it.
    const pending = pendingCreate(meta);
    if (pending?.slug && io.live) {
      const found = await lumaFindBySlug(io, pending.slug);
      if (found.error) return fail(steps, "couldn't check for the event an earlier pass created", found.error);
      if (found.id && hooks?.taken) {
        // The slug is Exos's own, but never adopt another Exos event's (mig 20261121100000).
        const used = await hooks.taken([found.id]);
        if (used === null) return fail(steps, "couldn't check which events are in use");
        if (used.includes(found.id)) return fail(steps, "the event an earlier pass created belongs to another Exos event: link the right one");
      }
      if (found.id) id = found.id;
    }
  }
  if (!id) {
    if (todo.length === 0) return fail(steps, "add a ticket type with a capacity first");
    let slug: string | undefined;
    if (io.live && hooks) {
      const b = await hooks.beginCreate({ name: ev.name, start: ev.startUtc, slug: lumaSlug(ev.name, random) });
      if (!b.ok) return fail(steps, `didn't create the event: ${beginRefused(b.reason)}`, b.reason);
      slug = b.pending?.slug;
    }
    const r = await io.req("POST", "/v1/events/create", {
      ...lumaEventBody(ev),
      ...(slug ? { slug } : {}),
      ticket_types: todo.map((t) => lumaTicketBody(t, ev, names.get(t.id) as string, true)),
    });
    if (!r.ok || typeof r.body?.id !== "string") return fail(steps, "couldn't create the event", r.error);
    id = r.body.id;
    createdWithEvent = true;
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
  const tickets: MirrorTicket[] = [];
  for (const t of todo) {
    const name = names.get(t.id) as string;
    let ttype = maps.get(t.id) ?? existing.find((x: any) => typeof x?.name === "string" && x.name.trim().toLowerCase() === name.toLowerCase())?.id ?? null;
    if (!ttype && eventId === "evt-planned") ttype = "ttype-planned";   // created with the event (dry run)
    // Created with the event in this pass: its first capacity, for the other
    // platform's share (mig 20261121100000).
    let capacity: number | undefined = createdWithEvent && ttype && !maps.has(t.id) ? firstCapacity(t, ev.pack) : undefined;
    if (!ttype) {
      const body = lumaTicketBody(t, ev, name, true);
      const r = await io.req("POST", "/v1/events/ticket-types/create", { event_id: eventId, ...body });
      if (!r.ok || typeof r.body?.id !== "string") return fail(steps, `couldn't add the ticket "${name}"`, r.error);
      ttype = r.body.id;
      capacity = body.max_capacity as number;
    } else if (changed && maps.has(t.id)) {
      const r = await io.req("POST", "/v1/events/ticket-types/update", { event_ticket_type_id: ttype, ...lumaTicketBody(t, ev, name, false) });
      if (!r.ok) return fail(steps, `couldn't update the ticket "${name}"`, r.error);
    }
    tickets.push({ tier_id: t.id, external_ticket_id: ttype as string, name, ...(capacity !== undefined ? { capacity, created: true } : {}) });
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
  delete meta.pending_create;   // mark clears it once the mirror has its id
  return {
    state: "synced", ...(id ? { external_id: id } : {}), ...(url ? { external_url: url } : {}),
    external_meta: meta, hash, plan: { steps }, tickets,
  };
}

/** A slug of Exos's own for a new Luma event: the name's words and 8 random characters (3-50 chars, a-z 0-9 -). */
export function lumaSlug(name: string, random: () => number = Math.random): string {
  const words = name.normalize("NFKD").toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-+|-+$/g, "").slice(0, 32).replace(/-+$/, "");
  const abc = "abcdefghijklmnopqrstuvwxyz0123456789";
  let tag = "";
  for (let i = 0; i < 8; i++) tag += abc[Math.floor(random() * abc.length) % abc.length];
  return words ? `${words}-${tag}` : `exos-${tag}`;
}

/** The event at a slug (GET entities/lookup). `error` when Luma couldn't be read: then nothing is created. */
export async function lumaFindBySlug(io: Io, slug: string): Promise<{ id?: string; error?: string }> {
  if (!/^[a-z0-9-]{3,50}$/.test(slug)) return {};
  const r = await io.req("GET", `/v1/entities/lookup?${new URLSearchParams({ slug })}`);
  if (r.status === 404) return {};
  if (!r.ok) return { error: r.error ?? "failed" };
  const e = r.body?.entity;
  const id = e?.type === "event" ? (e?.event?.id ?? e?.event?.api_id) : null;
  return typeof id === "string" && /^evt-[A-Za-z0-9]{4,40}$/.test(id) ? { id } : {};
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
