// DICE nodes -> the rows exos_dice_apply takes (mig 20261106100000). Pure
// TypeScript, imported by vitest (src/lib/diceClient.test.ts).
//
// Every field the client's documents ask for is mapped here, with DICE's
// names turned into Exos's (snake case, money in integer cents as DICE
// sends it, times as ISO strings). The SQL re-checks everything; this side
// drops what is the wrong type, trims strings and caps list sizes, so a
// malformed node can't make a row the SQL refuses as a whole.
//
// THE CONSENT RULE: a fan gets marketing consent (the org's email list)
// ONLY when DICE's Fan.optInPartners is literally true. null, missing,
// "true" as a string, 1: no consent. Everyone else is a ticket holder
// without marketing consent. marketingConsent() is the rule; the SQL
// (_exos_dice_fan_upsert) applies the same one to the boolean it receives.

import type { DiceEntity } from "./client.ts";

type Node = Record<string, unknown>;

const obj = (v: unknown): Node | null => (v && typeof v === "object" && !Array.isArray(v) ? (v as Node) : null);
const arr = (v: unknown, max = 50): unknown[] => (Array.isArray(v) ? v.slice(0, max) : []);

/** A trimmed string of at most `max` characters, or null. */
export function str(v: unknown, max = 200): string | null {
  if (typeof v === "number" && Number.isFinite(v)) v = String(v);
  if (typeof v !== "string") return null;
  const t = v.trim();
  return t ? t.slice(0, max) : null;
}

/** An id DICE sent as ID (string or number), or null. */
export function id(v: unknown): string | null {
  if (typeof v === "number" && Number.isSafeInteger(v)) return String(v);
  if (typeof v !== "string") return null;
  const t = v.trim();
  return t && t.length <= 200 && !/\s/.test(t) ? t : null;
}

/** An Int (DICE money is integer cents): a safe integer within Int32, or null. */
export function int(v: unknown): number | null {
  return typeof v === "number" && Number.isInteger(v) && Math.abs(v) <= 2_147_483_647 ? v : null;
}

const num = (v: unknown): number | null => (typeof v === "number" && Number.isFinite(v) ? v : null);
const bool = (v: unknown): boolean | null => (typeof v === "boolean" ? v : null);

/** A Datetime as an ISO string, or null. */
export function iso(v: unknown): string | null {
  if (typeof v !== "string" || v.length > 40) return null;
  // DICE documents "YYYY-MM-DDThh:mm:ss"; without a zone it is UTC.
  const s = /[zZ]|[+-]\d{2}:?\d{2}$/.test(v) ? v : `${v}Z`;
  const t = Date.parse(s);
  return Number.isFinite(t) ? new Date(t).toISOString() : null;
}

export interface FanRow {
  dice_id: string | null;
  email: string | null;
  first_name: string | null;
  last_name: string | null;
  phone: string | null;
  /** DICE's optInPartners exactly: true, false or null. */
  opt_in_partners: boolean | null;
}

/** THE rule: marketing consent only when optInPartners is true. */
export function marketingConsent(f: { opt_in_partners?: unknown } | null | undefined): boolean {
  return f?.opt_in_partners === true;
}

const EMAIL = /^[^@\s]{1,64}@[^@\s]{1,190}\.[^@\s]{2,}$/;

export function mapFan(v: unknown): FanRow | null {
  const f = obj(v);
  if (!f) return null;
  const email = str(f.email, 254)?.toLowerCase() ?? null;
  return {
    dice_id: id(f.id),
    email: email && EMAIL.test(email) ? email : null,
    first_name: str(f.firstName, 60),
    last_name: str(f.lastName, 60),
    phone: str(f.phoneNumber, 32),
    opt_in_partners: bool(f.optInPartners),
  };
}

export interface FeeRow { category: string | null; promoter_cents: number | null; dice_cents: number | null }
const mapFees = (v: unknown): FeeRow[] =>
  arr(v, 30).flatMap((x) => {
    const f = obj(x);
    return f ? [{ category: str(f.category, 40), promoter_cents: int(f.promoter), dice_cents: int(f.dice) }] : [];
  });

export interface TicketRow {
  dice_id: string;
  code: string | null;
  holder: FanRow | null;
  ticket_type_id: string | null;
  ticket_type_name: string | null;
  claimed_at: string | null;
  full_price_cents: number | null;
  commission_cents: number | null;
  dice_commission_cents: number | null;
  total_cents: number | null;
  fees: FeeRow[];
  seat: string | null;
  price_tier: { dice_id: string | null; name: string | null } | null;
  survey_answers: Array<{ question: string | null; value: string | null }>;
  extras: Array<{ dice_id: string | null; code: string | null; separate_barcode: boolean | null; product: string | null }>;
  /** Known when the ticket came inside an order (Order.event); else the SQL finds it from the ticket type. */
  dice_event_id: string | null;
}

export function mapTicket(v: unknown, diceEventId: string | null = null): TicketRow | null {
  const t = obj(v);
  const tid = id(t?.id);
  if (!t || !tid) return null;
  const tt = obj(t.ticketType);
  const pt = obj(t.priceTier);
  return {
    dice_id: tid,
    code: str(t.code, 128),
    holder: mapFan(t.holder),
    ticket_type_id: id(tt?.id),
    ticket_type_name: str(tt?.name, 80),
    claimed_at: iso(t.claimedAt),
    full_price_cents: int(t.fullPrice),
    commission_cents: int(t.commission),
    dice_commission_cents: int(t.diceCommission),
    total_cents: int(t.total),
    fees: mapFees(t.fees),
    seat: str(obj(t.seat)?.name, 80),
    price_tier: pt ? { dice_id: id(pt.id), name: str(pt.name, 80) } : null,
    survey_answers: arr(t.fanSurveyAnswers, 30).flatMap((x) => {
      const a = obj(x);
      return a ? [{ question: str(obj(a.fanSurveyQuestion)?.title, 200), value: str(a.value, 500) }] : [];
    }),
    extras: arr(t.extras, 30).flatMap((x) => {
      const e = obj(x);
      return e
        ? [{ dice_id: id(e.id), code: str(e.code, 128), separate_barcode: bool(e.hasSeparateAccessBarcode), product: str(obj(e.product)?.name, 120) }]
        : [];
    }),
    dice_event_id: diceEventId,
  };
}

export interface PriceTierRow {
  dice_id: string | null; name: string | null; allocation: number | null; time: string | null;
  face_value_cents: number | null; price_cents: number | null; door_price_cents: number | null;
}

export interface TicketTypeRow {
  dice_id: string;
  name: string | null;
  description: string | null;
  allocation: number | null;
  archived: boolean | null;
  face_value_cents: number | null;
  price_cents: number | null;
  door_price_cents: number | null;
  price_tier_type: string | null;
  price_tiers: PriceTierRow[];
  external_skus: string[];
  ticket_pool_id: string | null;
}

function mapTicketType(v: unknown): TicketTypeRow | null {
  const t = obj(v);
  const tid = id(t?.id);
  if (!t || !tid) return null;
  return {
    dice_id: tid,
    name: str(t.name, 120),
    description: str(t.description, 1000),
    allocation: int(t.totalTicketAllocationQty),
    archived: bool(t.archived),
    face_value_cents: int(t.faceValue),
    price_cents: int(t.price),
    door_price_cents: int(t.doorSalesPrice),
    price_tier_type: str(t.priceTierType, 20),
    price_tiers: arr(t.priceTiers, 30).flatMap((x) => {
      const p = obj(x);
      return p
        ? [{
          dice_id: id(p.id), name: str(p.name, 80), allocation: int(p.allocation), time: iso(p.time),
          face_value_cents: int(p.faceValue), price_cents: int(p.price), door_price_cents: int(p.doorSalesPrice),
        }]
        : [];
    }),
    external_skus: arr(t.externalSkus, 20).map((s) => str(s, 80)).filter((s): s is string => !!s),
    ticket_pool_id: id(t.ticketPoolId),
  };
}

export interface VenueRow {
  dice_id: string | null; name: string | null; type: string | null; age_limit: string | null;
  displayed_address: string | null; street: string | null; city: string | null; state: string | null;
  region: string | null; country: string | null; postal: string | null; po_box: string | null;
  latitude: number | null; longitude: number | null; timezone: string | null;
  spaces: Array<{ dice_id: string | null; name: string | null }>;
}

function mapVenue(v: unknown): VenueRow | null {
  const x = obj(v);
  if (!x) return null;
  const lat = num(x.latitude);
  const lng = num(x.longitude);
  return {
    dice_id: id(x.id), name: str(x.name, 200), type: str(x.type, 60), age_limit: str(x.ageLimit, 40),
    displayed_address: str(x.displayedAddress, 300), street: str(x.streetAddress, 200), city: str(x.city, 120),
    state: str(x.state, 120), region: str(x.region, 120), country: str(x.country, 60), postal: str(x.postalCode, 20),
    po_box: str(x.postOfficeBoxNumber, 40),
    latitude: lat !== null && lat >= -90 && lat <= 90 ? lat : null,
    longitude: lng !== null && lng >= -180 && lng <= 180 ? lng : null,
    timezone: str(x.timezoneName, 64),
    spaces: arr(x.venueSpaces, 20).flatMap((s) => {
      const o = obj(s);
      return o ? [{ dice_id: id(o.id), name: str(o.name, 120) }] : [];
    }),
  };
}

export interface EventRow {
  dice_id: string;
  live_id: string | null;
  name: string | null;
  state: string | null;
  announce_at: string | null;
  on_sale_at: string | null;
  off_sale_at: string | null;
  starts_at: string | null;
  ends_at: string | null;
  description: string | null;
  hidden: boolean | null;
  allocation: number | null;
  /** ISO 4217, upper case. */
  currency: string | null;
  url: string | null;
  updated_at: string | null;
  artists: string[];
  genres: string[];
  genre_types: string[];
  image_url: string | null;
  images: Array<{ type: string | null; url: string }>;
  ticket_types: TicketTypeRow[];
  ticket_pools: Array<{ dice_id: string | null; name: string | null; allocation: number | null }>;
  /** The first venue (Exos events have one); `venues` keeps every one DICE listed. */
  venue: VenueRow | null;
  venues: VenueRow[];
  venue_space: { dice_id: string | null; name: string | null } | null;
  products: Array<{
    dice_id: string | null; name: string | null; description: string | null; allocation: number | null;
    archived: boolean | null; face_value_cents: number | null; external_sku: string | null;
  }>;
  social_links: Array<{ url: string; campaign: string | null; default: boolean | null }>;
  promoters: string[];
}

const EVENT_STATES = new Set(["DRAFT", "DECLINED", "SUBMITTED", "REVIEW", "APPROVED", "ARCHIVED", "CANCELLED"]);
const httpsUrl = (v: unknown, max = 1000): string | null => {
  const s = str(v, max);
  return s && /^https:\/\/[^\s/]+\.[^\s]+$/.test(s) ? s : null;
};
const names = (v: unknown, max: number, len: number) =>
  arr(v, max).map((x) => str(typeof x === "string" ? x : obj(x)?.name, len)).filter((s): s is string => !!s);

export function mapEvent(v: unknown): EventRow | null {
  const e = obj(v);
  const eid = id(e?.id);
  if (!e || !eid) return null;
  const state = str(e.state, 20);
  const images = arr(e.images, 10).flatMap((x) => {
    const i = obj(x);
    const url = httpsUrl(i?.url);
    return url ? [{ type: str(i?.type, 20), url }] : [];
  });
  const venues = arr(e.venues, 10).map(mapVenue).filter((x): x is VenueRow => !!x);
  const cur = str(e.currency, 10);
  const vs = obj(e.venueSpace);
  return {
    dice_id: eid,
    live_id: str(e.eventIdLive, 80),
    name: str(e.name, 200),
    state: state && EVENT_STATES.has(state) ? state : null,
    announce_at: iso(e.announceDatetime),
    on_sale_at: iso(e.onSaleDatetime),
    off_sale_at: iso(e.offSaleDatetime),
    starts_at: iso(e.startDatetime),
    ends_at: iso(e.endDatetime),
    description: str(e.description, 20000),
    hidden: bool(e.hidden),
    allocation: int(e.totalTicketAllocationQty),
    currency: cur && /^[A-Za-z]{3}$/.test(cur) ? cur.toUpperCase() : null,
    url: httpsUrl(e.url, 500),
    updated_at: iso(e.updatedAt),
    artists: names(e.artists, 50, 120),
    genres: names(e.genres, 30, 60),
    genre_types: names(e.genreTypes, 30, 60),
    image_url: (images.find((i) => i.type === "LANDSCAPE") ?? images[0])?.url ?? null,
    images,
    ticket_types: arr(e.ticketTypes, 50).map(mapTicketType).filter((x): x is TicketTypeRow => !!x),
    ticket_pools: arr(e.ticketPools, 30).flatMap((x) => {
      const p = obj(x);
      return p ? [{ dice_id: id(p.id), name: str(p.name, 120), allocation: int(p.allocation) }] : [];
    }),
    venue: venues[0] ?? null,
    venues,
    venue_space: vs ? { dice_id: id(vs.id), name: str(vs.name, 120) } : null,
    products: arr(e.products, 30).flatMap((x) => {
      const p = obj(x);
      return p
        ? [{
          dice_id: id(p.id), name: str(p.name, 120), description: str(p.description, 1000),
          allocation: int(p.totalAllocationQty), archived: bool(p.archived), face_value_cents: int(p.faceValue),
          external_sku: str(p.externalSku, 80),
        }]
        : [];
    }),
    social_links: arr(e.socialLinks, 20).flatMap((x) => {
      const s = obj(x);
      const url = httpsUrl(s?.url, 500);
      return url ? [{ url, campaign: str(s?.campaign, 120), default: bool(s?.default) }] : [];
    }),
    promoters: names(e.promoters, 20, 120),
  };
}

export interface ReturnRow { dice_id: string; ticket_id: string | null; order_id: string | null; returned_at: string | null; reason: string | null }

export function mapReturn(v: unknown, orderId: string | null = null): ReturnRow | null {
  const r = obj(v);
  const rid = id(r?.id);
  if (!r || !rid) return null;
  return {
    dice_id: rid,
    ticket_id: id(r.ticketId) ?? id(obj(r.ticket)?.id),
    order_id: id(obj(r.order)?.id) ?? orderId,
    returned_at: iso(r.returnedAt),
    reason: str(r.reason, 200),
  };
}

export interface OrderRow {
  dice_id: string;
  purchased_at: string | null;
  quantity: number | null;
  sales_channel: string | null;
  full_price_cents: number | null;
  commission_cents: number | null;
  dice_commission_cents: number | null;
  total_cents: number | null;
  fees: FeeRow[];
  ip_city: string | null;
  ip_country: string | null;
  dice_event_id: string | null;
  fan: FanRow | null;
  tickets: TicketRow[];
  returns: ReturnRow[];
  adjustments: Array<{ reason: string | null; processed_at: string | null; ticket_id: string | null; fees_change: FeeRow[] }>;
  promo_code: string | null;
  promo_name: string | null;
  promo_discount_cents: number | null;
  promo_type: string | null;
}

export function mapOrder(v: unknown): OrderRow | null {
  const o = obj(v);
  const oid = id(o?.id);
  if (!o || !oid) return null;
  const ev = id(obj(o.event)?.id);
  return {
    dice_id: oid,
    purchased_at: iso(o.purchasedAt),
    quantity: int(o.quantity),
    sales_channel: str(o.salesChannel, 20),
    full_price_cents: int(o.fullPrice),
    commission_cents: int(o.commission),
    dice_commission_cents: int(o.diceCommission),
    total_cents: int(o.total),
    fees: mapFees(o.fees),
    ip_city: str(o.ipCity, 120),
    ip_country: str(o.ipCountry, 60),
    dice_event_id: ev,
    fan: mapFan(o.fan),
    tickets: arr(o.tickets, 100).map((t) => mapTicket(t, ev)).filter((x): x is TicketRow => !!x),
    returns: arr(o.returns, 100).map((r) => mapReturn(r, oid)).filter((x): x is ReturnRow => !!x),
    adjustments: arr(o.adjustments, 30).flatMap((x) => {
      const a = obj(x);
      return a
        ? [{ reason: str(a.reason, 200), processed_at: iso(a.processedAt), ticket_id: id(obj(a.ticket)?.id), fees_change: mapFees(a.feesChange) }]
        : [];
    }),
    promo_code: str(o.promoCode, 80),
    promo_name: str(o.promoName, 120),
    promo_discount_cents: int(o.promoDiscount),
    promo_type: str(o.promoType, 20),
  };
}

export interface TransferRow { dice_id: string; transferred_at: string | null; tickets: TicketRow[]; order_ids: string[] }

export function mapTransfer(v: unknown): TransferRow | null {
  const t = obj(v);
  const tid = id(t?.id);
  if (!t || !tid) return null;
  return {
    dice_id: tid,
    transferred_at: iso(t.transferredAt),
    tickets: arr(t.tickets, 100).map((x) => mapTicket(x)).filter((x): x is TicketRow => !!x),
    order_ids: arr(t.orders, 100).map((x) => id(obj(x)?.id)).filter((x): x is string => !!x),
  };
}

export type DiceRow = EventRow | TicketRow | OrderRow | ReturnRow | TransferRow;

/** One page's nodes as rows of `entity` (nodes that aren't usable are dropped). */
export function mapNodes(entity: DiceEntity, nodes: unknown[]): DiceRow[] {
  const f: (v: unknown) => DiceRow | null =
    entity === "events" ? mapEvent
    : entity === "tickets" ? (v) => mapTicket(v)
    : entity === "orders" ? mapOrder
    : entity === "returns" ? (v) => mapReturn(v)
    : mapTransfer;
  return nodes.map(f).filter((x): x is DiceRow => !!x);
}

/**
 * Whether an imported DICE event becomes an Exos event: not cancelled or
 * archived, and not over (its end, else its start + 6 hours, is less than a
 * day ago). The SQL (_exos_dice_event_upsert) applies the same rule; this
 * copy is for the dry-run preview.
 */
export function isUpcomingEvent(e: Pick<EventRow, "state" | "starts_at" | "ends_at">, now: Date = new Date()): boolean {
  if (e.state === "CANCELLED" || e.state === "ARCHIVED") return false;
  const start = e.starts_at ? Date.parse(e.starts_at) : NaN;
  const end = e.ends_at ? Date.parse(e.ends_at) : start + 6 * 3600_000;
  if (!Number.isFinite(end)) return true; // no date yet: a draft to finish
  return end >= now.getTime() - 24 * 3600_000;
}

/** The fans in a set of rows (buyers and holders), one per email. */
export function fansIn(entity: DiceEntity, rows: DiceRow[]): FanRow[] {
  const out: FanRow[] = [];
  const add = (f: FanRow | null) => { if (f) out.push(f); };
  for (const r of rows) {
    if (entity === "tickets") add((r as TicketRow).holder);
    else if (entity === "orders") {
      add((r as OrderRow).fan);
      for (const t of (r as OrderRow).tickets) add(t.holder);
    } else if (entity === "transfers") for (const t of (r as TransferRow).tickets) add(t.holder);
  }
  return out;
}
