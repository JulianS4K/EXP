// Channels: the Exos event mirrored on Eventbrite (mig 20261019090000).
// Exos is the source: this creates the event (or keeps a linked one) in step
// with Exos. Its details, ticket classes with prices, publish and cancel are
// sent from here. Capacity is NOT: the inventory sync
// (exos-eventbrite-sync, _shared/eventbrite/writer.ts) keeps each class at
// the shared count once the classes are mapped.
//
// Writes are limited to EB_WRITES (below) and go out only when the org's
// switch and EXOS_EVENTBRITE_WRITES=on are both set; otherwise the plan is
// recorded (dry run). No orders, attendees, check-ins, webhooks or prices of
// classes Exos didn't create: a class Exos adopted (one of the same name it
// found on the event, or one the organizer mapped) on an event Exos didn't
// create gets no update at all from here, only the inventory sync's
// capacity (mig 20261121100000).
//
// A live create is recorded first (hooks.beginCreate, mig 20261121100000);
// a pass that finds one recorded looks the event up by the name and start it
// sent, created since then, before it creates again.
import { ebOwns } from "../eventbrite/client.ts";
import {
  beginRefused, firstCapacity, type Io, notOnAccount, type MirrorEvent, type MirrorTicket, type MirrorTier, type PendingCreate, pendingCreate,
  type StepRecord, type SyncHooks, type SyncResult, textToHtml, utc,
} from "./model.ts";

export const EB_WRITES: RegExp[] = [
  /^\/organizations\/[0-9]{1,24}\/venues\/$/,
  /^\/organizations\/[0-9]{1,24}\/events\/$/,
  /^\/events\/[0-9]{1,24}\/$/,
  /^\/events\/[0-9]{1,24}\/ticket_classes\/$/,
  /^\/events\/[0-9]{1,24}\/ticket_classes\/[0-9]{1,24}\/$/,
  /^\/events\/[0-9]{1,24}\/publish\/$/,
  /^\/events\/[0-9]{1,24}\/cancel\/$/,
];

/** Stand-in answers for a dry run (ids that never reach the database). */
export function ebStandIn(path: string): any {
  if (/\/venues\/$/.test(path)) return { id: "0" };
  if (/^\/organizations\/[0-9]+\/events\/$/.test(path)) return { id: "0", url: null };
  if (/\/ticket_classes\/$/.test(path)) return { id: "0" };
  return {};
}

export function ebEventBody(ev: MirrorEvent, venueId: string | null) {
  return {
    event: {
      name: { html: ev.name },
      description: { html: textToHtml(ev.descriptionText) },
      start: { timezone: ev.timezone, utc: ev.startUtc },
      end: { timezone: ev.timezone, utc: ev.endUtc },
      currency: ev.currency,
      online_event: false,
      listed: true,
      shareable: true,
      ...(venueId && venueId !== "0" ? { venue_id: venueId } : {}),
    },
  };
}

export function ebVenueBody(ev: MirrorEvent) {
  return {
    venue: {
      name: (ev.venueName ?? "Venue").slice(0, 120),
      address: {
        address_1: ev.address.street ?? null,
        city: ev.address.city ?? null,
        region: ev.address.region ?? null,
        postal_code: ev.address.postal ?? null,
        country: ev.address.country ?? null,
      },
    },
  };
}

/**
 * Create body for a class Exos makes; update bodies (classes Exos created
 * only) leave capacity to the inventory sync. `capacity`, as the spec's
 * Ticket Class Create has it (`quantity_total` is deprecated there; the
 * inventory writer sends `capacity` too).
 */
export function ebClassBody(t: MirrorTier, ev: MirrorEvent, create: boolean) {
  const base: Record<string, unknown> = { name: t.name.slice(0, 50), hidden: t.hidden };
  if (t.description) base.description = t.description.slice(0, 2500);
  if (create) {
    base.free = t.free;
    base.capacity = firstCapacity(t, ev.pack);
  }
  if (!t.free) base.cost = `${ev.currency},${t.priceCents}`;
  return { ticket_class: base };
}

const fail = (steps: StepRecord[], what: string, error?: string): SyncResult =>
  ({ state: "error", error: `Eventbrite: ${what} (${error ?? "failed"})`.slice(0, 300), plan: { steps } });

export async function syncEventbrite(io: Io, ev: MirrorEvent, payload: any, steps: StepRecord[], hash: string, hooks?: SyncHooks): Promise<SyncResult> {
  const mirror = payload?.mirror ?? {};
  const meta: Record<string, any> = { ...(mirror.external_meta ?? {}) };
  let id: string | null = typeof mirror.external_id === "string" ? mirror.external_id : null;
  let url: string | null = mirror.external_url ?? null;
  const changed = mirror.last_hash !== hash;

  if (!meta.organization_id) {
    const r = await io.req("GET", "/users/me/organizations/");
    const org = r.ok ? r.body?.organizations?.[0]?.id : null;
    if (typeof org !== "string" || !/^[0-9]{1,24}$/.test(org)) return fail(steps, "no organization on this account", r.error);
    meta.organization_id = org;
  }

  // A linked event not yet synced must be one of this token's organizations'
  // (a public event reads with any token): otherwise the same answer as
  // another org's event, and nothing is sent to it (mig 20261121100000).
  if (id && mirror.status !== "synced") {
    const owned = await ebOwns(async (path, params) => {
      const q = params && Object.keys(params).length ? `?${new URLSearchParams(params as Record<string, string>)}` : "";
      return io.req("GET", `${path}${q}`);
    }, id);
    if (!owned) return { state: "error", error: notOnAccount("eventbrite"), plan: { steps } };
  }

  if (ev.status === "cancelled") {
    if (id && !meta.cancelled) {
      const r = await io.req("POST", `/events/${id}/cancel/`);
      if (!r.ok) return fail(steps, "it won't cancel an event that has orders: cancel or refund it on Eventbrite", r.error);
      meta.cancelled = true;
    }
    return done(io, steps, id, url, meta, hash, []);
  }

  // The venue is made only once the event is going ahead (after the lookup
  // and the recorded create, mig 20261121100000), and reused: the one noted
  // with the pending create, else one of the org's with the same name and
  // address, else a new one (a new one whenever the place changes).
  let venueId: string | null = meta.venue_id ?? null;
  const venue = async (pending: PendingCreate | null): Promise<string | null | false> => {
    if (!ev.venueName || (venueId && meta.venue_key === ev.venueQuery)) return venueId;
    let vid: string | null = pending?.venue_id && pending.venue_key === ev.venueQuery ? pending.venue_id : null;
    if (!vid && io.live) vid = await ebFindVenue(io, meta.organization_id, ev);
    if (!vid) {
      const r = await io.req("POST", `/organizations/${meta.organization_id}/venues/`, ebVenueBody(ev));
      if (!r.ok || typeof r.body?.id !== "string") return false;
      vid = r.body.id as string;
      if (io.live && hooks?.note) await hooks.note({ venue_id: vid, venue_key: ev.venueQuery ?? "" });
    }
    venueId = vid;
    meta.venue_id = vid;
    meta.venue_key = ev.venueQuery;
    return vid;
  };

  let recovered = false;
  if (!id) {
    if (mirror.mode === "link") return fail(steps, "no event to link");
    // A create recorded by an earlier pass: find it before creating again.
    const pending = pendingCreate(meta);
    if (pending && io.live) {
      const found = await ebFindCreated(io, meta.organization_id, pending, hooks?.taken);
      if (found.error) return fail(steps, "couldn't check for the event an earlier pass created", found.error);
      if (found.ids.length > 1) {
        return fail(steps, `${found.ids.length} events on Eventbrite match the one an earlier pass created: link the right one`);
      }
      if (found.ids.length === 1) {
        id = found.ids[0];
        url = found.url ?? url;
        recovered = true;
      }
    }
  }
  if (!id) {
    let pending: PendingCreate | null = null;
    if (io.live && hooks) {
      const b = await hooks.beginCreate({ name: ev.name, start: ev.startUtc });
      if (!b.ok) return fail(steps, `didn't create the event: ${beginRefused(b.reason)}`, b.reason);
      pending = b.pending ?? null;
    }
    if ((await venue(pending)) === false) return fail(steps, "couldn't save the venue");
    const r = await io.req("POST", `/organizations/${meta.organization_id}/events/`, ebEventBody(ev, venueId));
    if (!r.ok || typeof r.body?.id !== "string") return fail(steps, "couldn't create the event", r.error);
    id = r.body.id;
    url = typeof r.body.url === "string" && r.body.url.startsWith("https://") ? r.body.url : url;
  } else if (changed) {
    if ((await venue(pendingCreate(meta))) === false) return fail(steps, "couldn't save the venue");
    const r = await io.req("POST", `/events/${id}/`, ebEventBody(ev, venueId));
    if (!r.ok) return fail(steps, "couldn't update the event", r.error);
    if (typeof r.body?.url === "string" && r.body.url.startsWith("https://")) url = r.body.url;
  }
  const eventId = id as string;

  // Ticket classes: one per mirrored Exos ticket type. Exos owns (and so
  // updates, price included) the classes of an event it created here, and
  // those it created on a linked one; any other class it adopted is left
  // alone (its capacity is the inventory sync's).
  const ownEvent = mirror.mode === "create" || recovered;
  const maps = new Map<string, string>((payload?.maps ?? []).map((m: any) => [String(m.tier_id), String(m.external_ticket_id)]));
  const createdMaps = new Set<string>((payload?.maps ?? []).filter((m: any) => m?.created === true).map((m: any) => String(m.tier_id)));
  const tickets: MirrorTicket[] = [];
  const todo = ev.tiers.filter((t) => !t.skip);
  let existing: any[] | null = null;
  for (const t of todo) {
    let classId = maps.get(t.id) ?? null;
    let created = ownEvent || createdMaps.has(t.id);
    let capacity: number | undefined;
    if (!classId && eventId !== "0") {
      // A linked event (or a retry after a partial pass): reuse a class of the same name.
      if (!existing) {
        const r = await io.req("GET", `/events/${eventId}/ticket_classes/`);
        existing = r.ok && Array.isArray(r.body?.ticket_classes) ? r.body.ticket_classes : [];
      }
      const same = (existing ?? []).find((c: any) => typeof c?.name === "string" && c.name.trim() === t.name.slice(0, 50) && typeof c.id === "string");
      if (same) {
        classId = same.id;
        created = ownEvent;
      }
    }
    if (!classId) {
      const body = ebClassBody(t, ev, true);
      const r = await io.req("POST", `/events/${eventId}/ticket_classes/`, body);
      if (!r.ok || typeof r.body?.id !== "string") return fail(steps, `couldn't add the ticket "${t.name}"`, r.error);
      classId = r.body.id;
      created = true;
      capacity = body.ticket_class.capacity as number;
    } else if (changed && created) {
      const r = await io.req("POST", `/events/${eventId}/ticket_classes/${classId}/`, ebClassBody(t, ev, false));
      if (!r.ok) return fail(steps, `couldn't update the ticket "${t.name}"`, r.error);
    }
    tickets.push({ tier_id: t.id, external_ticket_id: classId as string, name: t.name, created, ...(capacity !== undefined ? { capacity } : {}) });
  }

  if (ev.status === "published" && !meta.published) {
    const r = await io.req("POST", `/events/${eventId}/publish/`);
    if (!r.ok) return fail(steps, "couldn't publish the event (it needs a ticket and a date in the future)", r.error);
    meta.published = true;
  }
  return done(io, steps, eventId, url, meta, hash, tickets);
}

function done(io: Io, steps: StepRecord[], id: string | null, url: string | null, meta: Record<string, unknown>,
              hash: string, tickets: SyncResult["tickets"]): SyncResult {
  if (!io.live) return { state: "dry_run", plan: { steps } };
  delete meta.pending_create;   // mark clears it once the mirror has its id
  return {
    state: "synced",
    ...(id ? { external_id: id } : {}),
    ...(url ? { external_url: url } : {}),
    external_meta: meta,
    hash,
    plan: { steps },
    tickets,
  };
}

/**
 * The event an earlier pass may have created (its pending create): the
 * org's events with the name it sent (name_filter), the same start, created
 * between that pass's first try (less 5 minutes of clock skew) and its last
 * try plus 2 minutes, and not another Exos event's (`taken`: any org's
 * mirror or door link, asked of the database). GET only. Eventbrite has no
 * field Exos can set at create and read back as a marker (`source` is
 * undocumented beyond "api", and the description is rewritten HTML), so the
 * bound and the exclusion are what stop a sibling's event being adopted.
 * `error` when the list (or the check) couldn't be read: then nothing is created.
 */
export async function ebFindCreated(
  io: Io, orgId: string, pending: PendingCreate, taken?: (ids: string[]) => Promise<string[] | null>,
): Promise<{ ids: string[]; url?: string; error?: string }> {
  const name = typeof pending.name === "string" ? pending.name.trim() : "";
  const start = typeof pending.start === "string" ? utc(pending.start) : "";
  if (!name || !start || !/^[0-9]{1,24}$/.test(String(orgId))) return { ids: [], error: "no record of what was sent" };
  const since = Date.parse(pending.first ?? pending.at ?? "") - 5 * 60_000;
  const until = Date.parse(pending.at ?? pending.first ?? "") + 2 * 60_000;
  const q = new URLSearchParams({ name_filter: name, status: "all", time_filter: "all", order_by: "created_desc", page_size: "50" });
  const r = await io.req("GET", `/organizations/${orgId}/events/?${q}`);
  if (!r.ok) return { ids: [], error: r.error ?? "failed" };
  const events: any[] = Array.isArray(r.body?.events) ? r.body.events : [];
  let hits = events.filter((e) => {
    if (typeof e?.id !== "string" || !/^[0-9]{1,24}$/.test(e.id)) return false;
    if (String(e?.name?.text ?? "").trim() !== name || utc(String(e?.start?.utc ?? "")) !== start) return false;
    const created = Date.parse(String(e?.created ?? ""));
    if (!Number.isFinite(created)) return false;    // no creation time: can't tell it was this pass's
    return (!Number.isFinite(since) || created >= since) && (!Number.isFinite(until) || created <= until);
  });
  if (hits.length && taken) {
    const used = await taken(hits.map((e) => e.id));
    if (used === null) return { ids: [], error: "couldn't check which events are in use" };
    hits = hits.filter((e) => !used.includes(e.id));
  }
  const url = hits.length === 1 && typeof hits[0].url === "string" && hits[0].url.startsWith("https://") ? hits[0].url : undefined;
  return { ids: hits.map((e) => e.id), url };
}

const norm = (v: unknown) => String(v ?? "").trim().toLowerCase().replace(/\s+/g, " ");

/** One of the org's venues with the same name and address (GET, first page), so a retry or a re-save reuses it. */
export async function ebFindVenue(io: Io, orgId: string, ev: MirrorEvent): Promise<string | null> {
  if (!/^[0-9]{1,24}$/.test(String(orgId))) return null;
  const r = await io.req("GET", `/organizations/${orgId}/venues/`);
  if (!r.ok || !Array.isArray(r.body?.venues)) return null;
  const want = ebVenueBody(ev).venue;
  const v = r.body.venues.find((x: any) => typeof x?.id === "string" && /^[0-9]{1,24}$/.test(x.id)
    && norm(x.name) === norm(want.name)
    && norm(x.address?.address_1) === norm(want.address.address_1)
    && norm(x.address?.city) === norm(want.address.city)
    && norm(x.address?.postal_code) === norm(want.address.postal_code));
  return v ? v.id : null;
}
