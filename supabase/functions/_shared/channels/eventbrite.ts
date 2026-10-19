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
// classes Exos didn't create.
import { firstCapacity, type Io, type MirrorEvent, type MirrorTier, type SyncResult, type StepRecord, textToHtml } from "./model.ts";

export const EB_API = "https://www.eventbriteapi.com/v3";

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

/** Create body for a class Exos makes; update bodies leave capacity to the inventory sync. */
export function ebClassBody(t: MirrorTier, ev: MirrorEvent, create: boolean) {
  const base: Record<string, unknown> = { name: t.name.slice(0, 50), hidden: t.hidden };
  if (t.description) base.description = t.description.slice(0, 2500);
  if (create) {
    base.free = t.free;
    base.quantity_total = firstCapacity(t, ev.pack);
  }
  if (!t.free) base.cost = `${ev.currency},${t.priceCents}`;
  return { ticket_class: base };
}

const fail = (steps: StepRecord[], what: string, error?: string): SyncResult =>
  ({ state: "error", error: `Eventbrite: ${what} (${error ?? "failed"})`.slice(0, 300), plan: { steps } });

export async function syncEventbrite(io: Io, ev: MirrorEvent, payload: any, steps: StepRecord[], hash: string): Promise<SyncResult> {
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

  if (ev.status === "cancelled") {
    if (id && !meta.cancelled) {
      const r = await io.req("POST", `/events/${id}/cancel/`);
      if (!r.ok) return fail(steps, "it won't cancel an event that has orders: cancel or refund it on Eventbrite", r.error);
      meta.cancelled = true;
    }
    return done(io, steps, id, url, meta, hash, []);
  }

  // Venue: a new one whenever the place changes.
  let venueId: string | null = meta.venue_id ?? null;
  if (ev.venueName && (meta.venue_key !== ev.venueQuery || !venueId)) {
    const r = await io.req("POST", `/organizations/${meta.organization_id}/venues/`, ebVenueBody(ev));
    if (!r.ok || typeof r.body?.id !== "string") return fail(steps, "couldn't save the venue", r.error);
    venueId = r.body.id;
    meta.venue_id = venueId;
    meta.venue_key = ev.venueQuery;
  }

  if (!id) {
    if (mirror.mode === "link") return fail(steps, "no event to link");
    const r = await io.req("POST", `/organizations/${meta.organization_id}/events/`, ebEventBody(ev, venueId));
    if (!r.ok || typeof r.body?.id !== "string") return fail(steps, "couldn't create the event", r.error);
    id = r.body.id;
    url = typeof r.body.url === "string" && r.body.url.startsWith("https://") ? r.body.url : url;
  } else if (changed) {
    const r = await io.req("POST", `/events/${id}/`, ebEventBody(ev, venueId));
    if (!r.ok) return fail(steps, "couldn't update the event", r.error);
    if (typeof r.body?.url === "string" && r.body.url.startsWith("https://")) url = r.body.url;
  }
  const eventId = id as string;

  // Ticket classes: one per mirrored Exos ticket type.
  const maps = new Map<string, string>((payload?.maps ?? []).map((m: any) => [String(m.tier_id), String(m.external_ticket_id)]));
  const tickets: { tier_id: string; external_ticket_id: string; name: string }[] = [];
  const todo = ev.tiers.filter((t) => !t.skip);
  let existing: any[] | null = null;
  for (const t of todo) {
    let classId = maps.get(t.id) ?? null;
    if (!classId && eventId !== "0") {
      // A linked event (or a retry after a partial pass): reuse a class of the same name.
      if (!existing) {
        const r = await io.req("GET", `/events/${eventId}/ticket_classes/`);
        existing = r.ok && Array.isArray(r.body?.ticket_classes) ? r.body.ticket_classes : [];
      }
      const same = (existing ?? []).find((c: any) => typeof c?.name === "string" && c.name.trim() === t.name.slice(0, 50) && typeof c.id === "string");
      if (same) classId = same.id;
    }
    if (!classId) {
      const r = await io.req("POST", `/events/${eventId}/ticket_classes/`, ebClassBody(t, ev, true));
      if (!r.ok || typeof r.body?.id !== "string") return fail(steps, `couldn't add the ticket "${t.name}"`, r.error);
      classId = r.body.id;
    } else if (changed) {
      const r = await io.req("POST", `/events/${eventId}/ticket_classes/${classId}/`, ebClassBody(t, ev, false));
      if (!r.ok) return fail(steps, `couldn't update the ticket "${t.name}"`, r.error);
    }
    tickets.push({ tier_id: t.id, external_ticket_id: classId as string, name: t.name });
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
