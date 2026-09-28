// SeatGeek's public Platform API (https://api.seatgeek.com/2), read-only,
// for linking Exos events to SeatGeek events. The Seller Direct API has no
// event search; its listings attach to a SeatGeek event id, which is what
// this finds. Auth: a Platform `client_id` (SEATGEEK_CLIENT_ID), sent as a
// query parameter as that API expects. Optional: without it, SeatGeek links
// are made by a platform admin by hand.
//
// Only GET /2/events is used. Its datetime_utc has no zone suffix; it is UTC.

import { guardedFetch } from '../netError.ts';
import type { EventCandidate } from '../channel.ts';
import type { FetchLike } from './transport.ts';

export const SEATGEEK_PLATFORM_HOST = 'https://api.seatgeek.com';

export interface PlatformEvent {
  id: number;
  title?: string;
  short_title?: string;
  datetime_local?: string;
  datetime_utc?: string;
  url?: string;
  venue?: { name?: string; city?: string; state?: string; country?: string };
}

export interface PlatformEventsPage {
  events?: PlatformEvent[];
  meta?: { total?: number; page?: number; per_page?: number };
}

export function platformEventToCandidate(e: PlatformEvent): EventCandidate {
  const utc = e.datetime_utc ? (/[zZ]|[+-]\d{2}:?\d{2}$/.test(e.datetime_utc) ? e.datetime_utc : `${e.datetime_utc}Z`) : null;
  return {
    channel: 'seatgeek',
    externalEventId: String(e.id),
    name: e.title ?? e.short_title ?? '',
    startsAt: utc,
    startsLocal: e.datetime_local ?? null,
    venueName: e.venue?.name ?? null,
    venueCity: e.venue?.city ?? null,
    url: e.url ?? null,
  };
}

export class SeatGeekPlatformClient {
  private readonly fetchImpl: FetchLike;
  private readonly host: string;

  constructor(private readonly clientId: string, opts: { fetch?: FetchLike; host?: string } = {}) {
    if (!clientId.trim()) throw new Error('seatgeek platform: client id is required');
    this.fetchImpl = opts.fetch ?? ((input, init) => fetch(input, init));
    this.host = (opts.host ?? SEATGEEK_PLATFORM_HOST).replace(/\/+$/, '');
  }

  /** Events matching `q` on one venue-local date (YYYY-MM-DD). */
  async searchEvents(q: string, dateLocal: string, perPage = 20): Promise<PlatformEvent[]> {
    if (!/^\d{4}-\d{2}-\d{2}$/.test(dateLocal)) throw new Error(`seatgeek platform: bad date ${dateLocal}`);
    const params = new URLSearchParams({
      q,
      'datetime_local.gte': `${dateLocal}T00:00:00`,
      'datetime_local.lte': `${dateLocal}T23:59:59`,
      per_page: String(perPage),
      client_id: this.clientId,
    });
    const res = await guardedFetch(this.fetchImpl, `${this.host}/2/events?${params}`, { method: 'GET', headers: { Accept: 'application/json' } }, 'seatgeek platform GET /2/events', [this.clientId]);
    if (!res.ok) throw new Error(`seatgeek platform GET /2/events -> ${res.status}`);
    const page = (await res.json()) as PlatformEventsPage;
    return page.events ?? [];
  }
}
