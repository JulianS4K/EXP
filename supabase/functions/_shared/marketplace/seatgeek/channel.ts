// SeatGeek as a MarketplaceChannel (../channel.ts).
//
// What SeatGeek allows, per the APIs we have (Terminal-2
// docs/seatgeek/migration-guide.md + seatgeek_client.py):
//   link    Platform API v2 GET /events (public catalog, client_id), read-only
//   create  no: SeatGeek has no seller event creation; list against its events
//   list    not direct: Exos inventory reaches SeatGeek through Automatiq
//   sell    SellerDirect /orders, which Terminal-2 already pulls into the shared
//           seatgeek_orders table every 30 min; normalizeSale reads those rows
//   fulfil  unknown: orders carry transfer_urls, but we have no SellerDirect
//           write docs, so a SeatGeek sale is fulfilled in Exos and delivered
//           by a human until they arrive

import {
  localDate,
  type EventCandidate,
  type ExosEventRef,
  type MarketplaceChannel,
  type MarketplaceSale,
  type SaleStatus,
} from '../channel.ts';

export const SEATGEEK_PLATFORM_BASE = 'https://api.seatgeek.com/2';

/** One event from GET /2/events. */
export interface SeatGeekPlatformEvent {
  id: number;
  title: string;
  datetime_local?: string | null;
  /** UTC wall clock without a zone suffix, e.g. "2026-11-07T02:00:00". */
  datetime_utc?: string | null;
  url?: string | null;
  venue?: { name?: string | null; city?: string | null; state?: string | null } | null;
}

export function platformEventToCandidate(e: SeatGeekPlatformEvent): EventCandidate {
  const utc = e.datetime_utc ? (/[zZ]|[+-]\d{2}:?\d{2}$/.test(e.datetime_utc) ? e.datetime_utc : `${e.datetime_utc}Z`) : null;
  return {
    channel: 'seatgeek',
    externalEventId: String(e.id),
    name: e.title,
    startsAt: utc,
    startsLocal: e.datetime_local ?? null,
    venueName: e.venue?.name ?? null,
    venueCity: e.venue?.city ?? null,
    url: e.url ?? null,
  };
}

export function seatGeekEventSearchUrl(ev: ExosEventRef, clientId: string, base = SEATGEEK_PLATFORM_BASE): string {
  const day = localDate(ev);
  const q = new URLSearchParams({
    q: ev.name,
    'datetime_local.gte': `${day}T00:00:00`,
    'datetime_local.lte': `${day}T23:59:59`,
    per_page: '25',
    client_id: clientId,
  });
  return `${base}/events?${q.toString()}`;
}

/** A row of Terminal-2's seatgeek_orders (SellerDirect /orders, pulled read-only). */
export interface SeatGeekOrderRow {
  sg_order_id: string;
  status: string | null;
  sg_event_id: number | string | null;
  sg_listing_id: string | null;
  sale_quantity: number | null;
  payment_total?: number | string | null;
  created_at_sg?: string | null;
  sale_section?: string | null;
  sale_row?: string | null;
}

// Seen in prod: 'confirmed' (to deliver) and 'fulfilled' (delivered).
const ORDER_STATUS: Record<string, SaleStatus> = {
  pending: 'pending',
  confirmed: 'confirmed',
  fulfilled: 'delivered',
  delivered: 'delivered',
  cancelled: 'cancelled',
  canceled: 'cancelled',
  rejected: 'cancelled',
};

export function normalizeSeatGeekOrder(raw: unknown): MarketplaceSale {
  const o = raw as SeatGeekOrderRow;
  if (!o || typeof o !== 'object' || !o.sg_order_id) throw new Error('not a seatgeek_orders row');
  const total = o.payment_total == null ? NaN : Number(o.payment_total);
  return {
    channel: 'seatgeek',
    externalOrderId: String(o.sg_order_id),
    externalEventId: o.sg_event_id != null ? String(o.sg_event_id) : null,
    externalListingId: o.sg_listing_id ?? null,
    quantity: Number(o.sale_quantity) || 0,
    status: ORDER_STATUS[String(o.status ?? '').toLowerCase()] ?? 'unknown',
    // SellerDirect orders don't carry the buyer's email.
    buyerEmail: null,
    proceeds: Number.isFinite(total) ? { amount: total, currency: 'USD' } : null,
    confirmBy: null,
    shipBy: null,
    createdAt: o.created_at_sg ?? null,
    section: o.sale_section ?? null,
    row: o.sale_row ?? null,
  };
}

export interface SeatGeekChannelOptions {
  /** Platform API client_id; without it the channel can't search the catalog. */
  clientId?: string;
  fetch?: typeof fetch;
  base?: string;
}

export function seatGeekChannel(opts: SeatGeekChannelOptions = {}): MarketplaceChannel {
  const doFetch = opts.fetch ?? fetch;
  return {
    id: 'seatgeek',
    label: 'SeatGeek',
    capabilities: { findEvents: !!opts.clientId, createEvent: false, listings: false, fulfilByUrls: false },

    findEvents: opts.clientId
      ? async (ev: ExosEventRef) => {
          const res = await doFetch(seatGeekEventSearchUrl(ev, opts.clientId!, opts.base), {
            method: 'GET',
            headers: { accept: 'application/json' },
          });
          if (!res.ok) throw new Error(`SeatGeek /events ${res.status}`);
          const body = (await res.json()) as { events?: SeatGeekPlatformEvent[] };
          return (body.events ?? []).map(platformEventToCandidate);
        }
      : undefined,

    normalizeSale: normalizeSeatGeekOrder,
  };
}
