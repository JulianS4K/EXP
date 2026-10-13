// The S4K network feed contract (docs/marketplace/s4k-feed.md): Exos served
// the way S4K's Ticket Desk serves Paciolan, with the names changed. Two GET
// calls (events, one event's tickets), plus the order calls S4K uses to fill
// a marketplace sale and the signed webhook that says something moved.
//
// The database (mig 20261014100000) does the counting and the locking; this
// module only parses requests and shapes rows into the contract's camelCase
// JSON. Pure: no Deno or Supabase imports (the app's vitest covers it).

export type FeedRoute =
  | { kind: 'events' }
  | { kind: 'tickets'; eventId: string }
  | { kind: 'order'; eventId: string }
  | { kind: 'orderGet'; orderId: string }
  | { kind: 'orderCancel'; orderId: string }
  | { kind: 'status' }
  | { kind: 'cron' };

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

/** The route for a request path, after the function name (/exos-s4k-feed/...). */
export function parseFeedRoute(pathname: string, method: string): FeedRoute | null {
  const parts = pathname.replace(/\/+$/, '').split('/').filter(Boolean);
  const i = parts.indexOf('exos-s4k-feed');
  const p = i >= 0 ? parts.slice(i + 1) : parts;
  const m = method.toUpperCase();
  if (p.length === 1 && p[0] === 'cron' && m === 'POST') return { kind: 'cron' };
  if (p[0] !== 'exos') return null;
  if (p.length === 2 && p[1] === 'status' && m === 'GET') return { kind: 'status' };
  if (p.length === 2 && p[1] === 'events' && m === 'GET') return { kind: 'events' };
  if (p.length === 4 && p[1] === 'events' && UUID.test(p[2])) {
    if (p[3] === 'tickets' && m === 'GET') return { kind: 'tickets', eventId: p[2].toLowerCase() };
    if (p[3] === 'orders' && m === 'POST') return { kind: 'order', eventId: p[2].toLowerCase() };
  }
  if (p[1] === 'orders' && p.length >= 3 && UUID.test(p[2])) {
    if (p.length === 3 && m === 'GET') return { kind: 'orderGet', orderId: p[2].toLowerCase() };
    if (p.length === 4 && p[3] === 'cancel' && m === 'POST') return { kind: 'orderCancel', orderId: p[2].toLowerCase() };
  }
  return null;
}

/** Bearer token, else X-API-Key (the desk accepts both). */
export function bearerToken(get: (h: string) => string | null): string | null {
  const auth = (get('authorization') ?? '').trim();
  if (/^bearer\s+/i.test(auth)) return auth.replace(/^bearer\s+/i, '').trim() || null;
  return (get('x-api-key') ?? '').trim() || null;
}

/** updatedSince: an ISO date or date-time; null when absent; an error when unreadable. */
export function parseSince(v: string | null): { since: string | null } | { error: string } {
  if (v == null || v.trim() === '') return { since: null };
  const s = v.trim();
  if (!/^\d{4}-\d{2}-\d{2}([T ][0-9:.]+(Z|[+-]\d{2}:?\d{2})?)?$/.test(s)) return { error: 'updatedSince must be an ISO-8601 date or date-time' };
  const ms = Date.parse(/^\d{4}-\d{2}-\d{2}$/.test(s) ? `${s}T00:00:00Z` : s);
  if (!Number.isFinite(ms)) return { error: 'updatedSince must be an ISO-8601 date or date-time' };
  return { since: new Date(ms).toISOString() };
}

export function parsePaging(limit: string | null, offset: string | null): { limit: number; offset: number } {
  const l = Number.parseInt(limit ?? '', 10);
  const o = Number.parseInt(offset ?? '', 10);
  return { limit: Number.isFinite(l) ? Math.min(Math.max(l, 1), 1000) : 200, offset: Number.isFinite(o) ? Math.max(o, 0) : 0 };
}

/** ISO-8601 UTC to the second, as the desk stamps time. */
export function isoSecond(v: string | null | undefined): string | null {
  if (!v) return null;
  const ms = Date.parse(v);
  return Number.isFinite(ms) ? new Date(ms).toISOString().replace(/\.\d{3}Z$/, 'Z') : null;
}

/** Venue-local date (YYYY-MM-DD) and time (HH:MM) of an instant. */
export function localDateTime(iso: string | null, timeZone: string | null): { date: string | null; time: string | null } {
  if (!iso || !Number.isFinite(Date.parse(iso))) return { date: null, time: null };
  let parts: Intl.DateTimeFormatPart[];
  try {
    parts = new Intl.DateTimeFormat('en-CA', {
      timeZone: timeZone || 'UTC', year: 'numeric', month: '2-digit', day: '2-digit',
      hour: '2-digit', minute: '2-digit', hourCycle: 'h23',
    }).formatToParts(new Date(iso));
  } catch {
    return localDateTime(iso, 'UTC');
  }
  const g = (t: string) => parts.find((p) => p.type === t)?.value ?? '';
  return { date: `${g('year')}-${g('month')}-${g('day')}`, time: `${g('hour')}:${g('minute')}` };
}

export function eventPageUrl(appBase: string, e: { event_id: string; slug?: string | null }): string {
  return e.slug ? `${appBase}/e/${encodeURIComponent(e.slug)}` : `${appBase}/event/${e.event_id}`;
}

// ── Call 1 ──────────────────────────────────────────────────────────────
export type EventRow = {
  event_id: string; status: 'active' | 'withdrawn'; organizer: string | null; name: string;
  venue_name: string | null; venue_address: unknown; timezone: string | null;
  starts_at: string | null; doors_at: string | null; slug: string | null;
  available: number; total_capacity: number; updated_at: string;
};
export type EventsPage = { generated_at: string; total: number; limit: number; offset: number; events: EventRow[] };

function addressPart(a: unknown, ...keys: string[]): string | null {
  if (!a || typeof a !== 'object') return null;
  for (const k of keys) {
    const v = (a as Record<string, unknown>)[k];
    if (typeof v === 'string' && v.trim()) return v.trim();
  }
  return null;
}

export function shapeEvent(r: EventRow, appBase: string) {
  const { date, time } = localDateTime(r.starts_at, r.timezone);
  const cap = Math.max(r.total_capacity ?? 0, 0);
  const avail = Math.max(r.available ?? 0, 0);
  return {
    eventId: r.event_id,
    eventUid: r.event_id,
    internalId: null,
    status: r.status,
    organizer: r.organizer,
    host: 'exos',
    name: r.name,
    opponent: null,
    venue: r.venue_name,
    city: addressPart(r.venue_address, 'city', 'locality'),
    region: addressPart(r.venue_address, 'region', 'state', 'administrative_area_level_1'),
    date, time,
    timezone: r.timezone,
    doorsAt: isoSecond(r.doors_at),
    startsAt: isoSecond(r.starts_at),
    isAway: false,
    eventUrl: appBase ? eventPageUrl(appBase, r) : null,
    availability: {
      available: avail,
      totalCapacity: cap,
      pctAvailable: cap > 0 ? Math.round((avail / cap) * 1000) / 10 : null,
      soldOut: avail === 0,
      asOf: isoSecond(r.updated_at),
    },
    updatedAt: isoSecond(r.updated_at),
  };
}

export function shapeEventsPage(p: EventsPage, since: string | null, appBase: string) {
  return {
    generatedAt: isoSecond(p.generated_at),
    updatedSince: since ? isoSecond(since) : null,
    count: p.events.length,
    total: p.total, limit: p.limit, offset: p.offset,
    events: p.events.map((e) => shapeEvent(e, appBase)),
  };
}

// ── Call 2 ──────────────────────────────────────────────────────────────
export type TicketRow = {
  tier_id: string; name: string; quantity: number; max_per_order: number | null; split: string;
  price: number; net: number; currency: string;
};
export type TicketsResult = { generated_at: string; event_id: string; name: string; starts_at: string | null; timezone: string | null; tickets: TicketRow[] };

const money = (n: number) => Math.round(Number(n) * 100) / 100;

export function shapeTickets(t: TicketsResult) {
  const { date } = localDateTime(t.starts_at, t.timezone);
  const tickets = t.tickets.map((l) => ({
    ticketId: l.tier_id,
    level: '', section: 'GA', row: 'GA',
    seatFirst: null, seatLast: null,
    quantity: l.quantity,
    maxContiguous: l.max_per_order ?? l.quantity,
    split: l.split,
    priceLevel: l.tier_id,
    priceLevelName: l.name,
    price: money(l.price),
    fees: 0,
    allInPrice: money(l.price),
    netToOrganizer: money(l.net),
    currency: l.currency,
    inventoryType: 'primary',
    inHandDate: date,
    delivery: 'mobile_transfer',
  }));
  return {
    eventId: t.event_id, eventUid: t.event_id, internalId: null,
    name: t.name, date,
    asOf: isoSecond(t.generated_at),
    count: tickets.length,
    seats: tickets.reduce((s, l) => s + l.quantity, 0),
    tickets,
  };
}

// ── Orders ──────────────────────────────────────────────────────────────
export type OrderBody = {
  ticketId: string; quantity: number; externalRef: string; unitPrice: number;
  marketplace: string | null; buyerEmail: string | null;
};

export function parseOrderBody(b: unknown, idempotencyKey: string | null): OrderBody | { error: string } {
  if (!b || typeof b !== 'object') return { error: 'send a JSON body' };
  const o = b as Record<string, unknown>;
  const ticketId = typeof o.ticketId === 'string' && UUID.test(o.ticketId) ? o.ticketId.toLowerCase() : null;
  if (!ticketId) return { error: 'ticketId is required (from /tickets)' };
  const quantity = typeof o.quantity === 'number' && Number.isInteger(o.quantity) ? o.quantity : NaN;
  if (!(quantity >= 1 && quantity <= 100)) return { error: 'quantity must be a whole number from 1 to 100' };
  const ref = (typeof o.externalRef === 'string' ? o.externalRef : idempotencyKey ?? '').trim();
  if (!ref || ref.length > 100) return { error: 'externalRef (or an Idempotency-Key header) is required, at most 100 characters' };
  if (typeof o.externalRef === 'string' && idempotencyKey && idempotencyKey.trim() !== ref) {
    return { error: 'Idempotency-Key and externalRef differ' };
  }
  const unitPrice = typeof o.unitPrice === 'number' && Number.isFinite(o.unitPrice) && o.unitPrice >= 0 ? o.unitPrice : NaN;
  if (Number.isNaN(unitPrice)) return { error: 'unitPrice is required: what S4K pays Exos per ticket' };
  const marketplace = typeof o.marketplace === 'string' && o.marketplace.trim() ? o.marketplace.trim().slice(0, 40) : null;
  const buyerEmail = typeof o.buyerEmail === 'string' && o.buyerEmail.trim() ? o.buyerEmail.trim() : null;
  return { ticketId, quantity, externalRef: ref, unitPrice, marketplace, buyerEmail };
}

export type OrderRpc =
  | { result: 'created' | 'existing'; order_id: string; status: string; transfer_ids?: string[]; reason?: string | null }
  | { result: 'rejected'; reason: string; available: number; price: number | null }
  | { result: 'invalid'; error: string }
  | { result: 'unauthorized' };
export type OrderTicketRow = { transfer_id: string | null; claim_key: string | null; internal_seat: number | null; ticket_status: string };

export function claimUrl(appBase: string, t: OrderTicketRow): string | null {
  return appBase && t.transfer_id && t.claim_key ? `${appBase}/claim/${t.transfer_id}?k=${encodeURIComponent(t.claim_key)}` : null;
}

/** HTTP status + body for an order call. A rejection is a 409, the oversell signal. */
export function shapeOrder(r: OrderRpc, tickets: OrderTicketRow[], appBase: string): { status: number; body: unknown } {
  if (r.result === 'unauthorized') return { status: 401, body: { error: 'unauthorized' } };
  if (r.result === 'invalid') return { status: 400, body: { error: r.error } };
  if (r.result === 'rejected') {
    const why: Record<string, string> = {
      sold_out: 'not enough left',
      price_changed: 'unitPrice is below the current price',
      over_max_per_order: 'more than the max per order',
      not_on_feed: 'that event is not on the feed',
      ticket_not_on_feed: 'that ticket is not on the feed',
      bad_quantity: 'bad quantity',
      no_delivery_email: 'no buyerEmail and no delivery inbox set for this token',
    };
    return {
      status: r.reason === 'not_on_feed' || r.reason === 'ticket_not_on_feed' ? 404 : 409,
      body: { error: why[r.reason] ?? r.reason, reason: r.reason, available: r.available, price: r.price },
    };
  }
  return {
    status: r.result === 'created' ? 201 : 200,
    body: {
      orderId: r.order_id,
      status: r.status,
      replayed: r.result === 'existing',
      tickets: tickets.map((t) => ({
        seat: t.internal_seat != null ? `GA-${String(t.internal_seat).padStart(4, '0')}` : null,
        claimUrl: claimUrl(appBase, t),
        status: t.ticket_status,
      })),
    },
  };
}

// ── Webhook ─────────────────────────────────────────────────────────────
export type WebhookEvent = { event_id: string; status: string; available: number; updated_at: string };

export function webhookBody(events: WebhookEvent[], now: Date) {
  return {
    type: 'inventory.changed',
    generatedAt: isoSecond(now.toISOString()),
    events: events.map((e) => ({ eventId: e.event_id, status: e.status, available: e.available, updatedAt: isoSecond(e.updated_at) })),
  };
}

/** Same signing as exos-webhook-drain: hex HMAC-SHA256(secret, `${ts}.${body}`). */
export async function signWebhook(secret: string, timestamp: number, body: string): Promise<string> {
  const enc = new TextEncoder();
  const key = await crypto.subtle.importKey('raw', enc.encode(secret), { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
  const sig = await crypto.subtle.sign('HMAC', key, enc.encode(`${timestamp}.${body}`));
  return [...new Uint8Array(sig)].map((b) => b.toString(16).padStart(2, '0')).join('');
}

export async function sha256Hex(v: string): Promise<string> {
  const d = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(v));
  return [...new Uint8Array(d)].map((b) => b.toString(16).padStart(2, '0')).join('');
}
