// Link-out events (mig 20261029170000; docs/organizer-guide.md "List an
// event you sell elsewhere"): events Exos lists while the organizer sells on
// their own Eventbrite, Luma or Posh checkout. Exos sells nothing for them.
//
//   * Storefront: exos_public_link_outs (anon) gives the checkout URL, the
//     source status and the imported prices (display only).
//   * Organizer: the exos-event-import edge function lists Eventbrite events,
//     imports picked ones, turns a pasted link into an event, and re-checks.

import { supabase } from './supabase';
import { formatCurrency } from './utils';
import { SALE_PLATFORM_LABEL, type LinkOutPlatform } from '../../supabase/functions/_shared/eventImport/urls.ts';

export { nameFromSlug, parseEventUrl, type LinkOutPlatform, type ParsedEventUrl } from '../../supabase/functions/_shared/eventImport/urls.ts';

export type SourceStatus = 'on_sale' | 'sold_out' | 'cancelled' | 'ended' | 'unknown';

export interface LinkOutTicketType { name: string; minPrice: number | null; maxPrice: number | null; soldOut: boolean; free: boolean }

export interface PublicLinkOut {
  platform: LinkOutPlatform;
  url: string;
  status: SourceStatus;
  priceMin: number | null;
  priceMax: number | null;
  currency: string | null;
  isFree: boolean;
  ticketTypes: LinkOutTicketType[];
}

const STATUSES: readonly SourceStatus[] = ['on_sale', 'sold_out', 'cancelled', 'ended', 'unknown'];
const PLATFORMS: readonly LinkOutPlatform[] = ['eventbrite', 'luma', 'posh'];

const num = (v: unknown): number | null => {
  const n = typeof v === 'number' ? v : typeof v === 'string' && v.trim() !== '' ? Number(v) : NaN;
  return Number.isFinite(n) && n >= 0 ? n : null;
};

/** One exos_public_link_outs row; null when it isn't a usable link-out. */
export function parsePublicLinkOut(raw: unknown): PublicLinkOut | null {
  if (!raw || typeof raw !== 'object') return null;
  const r = raw as Record<string, unknown>;
  if (!PLATFORMS.includes(r.platform as LinkOutPlatform)) return null;
  if (typeof r.url !== 'string' || !/^https:\/\/[^\s/]+\.[^\s]+$/.test(r.url)) return null;
  const types = Array.isArray(r.ticket_types) ? r.ticket_types : [];
  return {
    platform: r.platform as LinkOutPlatform,
    url: r.url,
    status: STATUSES.includes(r.source_status as SourceStatus) ? (r.source_status as SourceStatus) : 'unknown',
    priceMin: num(r.price_min),
    priceMax: num(r.price_max),
    currency: typeof r.currency === 'string' && /^[A-Za-z]{3}$/.test(r.currency) ? r.currency.toUpperCase() : null,
    isFree: r.is_free === true,
    ticketTypes: types.flatMap((t) => {
      if (!t || typeof t !== 'object') return [];
      const x = t as Record<string, unknown>;
      const name = typeof x.name === 'string' ? x.name.trim() : '';
      return name ? [{ name, minPrice: num(x.min_price), maxPrice: num(x.max_price), soldOut: x.sold_out === true, free: x.free === true }] : [];
    }).slice(0, 50),
  };
}

export const platformLabel = (p: string): string => SALE_PLATFORM_LABEL[p] ?? p;

/** "$25 – $45", "$25", "Free", or null when the source gave no price. */
export function linkOutPriceLabel(lo: Pick<PublicLinkOut, 'priceMin' | 'priceMax' | 'isFree' | 'currency'>, fallbackCurrency?: string): string | null {
  const cur = lo.currency ?? fallbackCurrency ?? 'USD';
  if (lo.priceMin === null) return lo.isFree ? 'Free' : null;
  const max = lo.priceMax ?? lo.priceMin;
  if (lo.priceMin === 0 && max === 0) return 'Free';
  return max > lo.priceMin
    ? `${formatCurrency(lo.priceMin, cur)} – ${formatCurrency(max, cur)}`
    : formatCurrency(lo.priceMin, cur);
}

/** The published link-out details for these events (empty before the migration). */
export async function fetchPublicLinkOuts(eventIds: string[]): Promise<Map<string, PublicLinkOut>> {
  const out = new Map<string, PublicLinkOut>();
  if (!eventIds.length) return out;
  const { data, error } = await supabase.from('exos_public_link_outs').select('*').in('event_id', eventIds);
  if (error || !data) return out;
  for (const r of data as Array<Record<string, unknown>>) {
    const lo = parsePublicLinkOut(r);
    if (lo && typeof r.event_id === 'string') out.set(r.event_id, lo);
  }
  return out;
}

// --- Organizer: exos-event-import ------------------------------------------------

export interface ImportChoice {
  id: string;
  name: string;
  start: string | null;
  status: SourceStatus;
  url: string;
  venue: string | null;
  priceMin: number | null;
  priceMax: number | null;
  currency: string | null;
  imageUrl: string | null;
  importedEventId: string | null;
}

export interface ImportResult { id?: string; ok: boolean; eventId?: string; created?: boolean; status?: string; error?: string }

/** The organizer's draft details for a pasted Luma / Posh link. */
export interface DraftDetails {
  name: string;
  starts_at?: string;
  ends_at?: string;
  timezone?: string;
  venue_name?: string;
  street?: string;
  city?: string;
  region?: string;
  country?: string;
  online?: boolean;
  price_min?: number;
  price_max?: number;
  currency?: string;
  image_url?: string;
  description?: string;
}

const env = (import.meta as { env?: Record<string, string | undefined> }).env ?? {};

async function callImport<T>(path: string, init: { method: 'GET' | 'POST'; body?: unknown }): Promise<T> {
  const url = (env.VITE_SUPABASE_URL ?? '').replace(/\/+$/, '');
  if (!url) throw new Error('Importing is not configured.');
  const { data } = await supabase.auth.getSession();
  const jwt = data.session?.access_token;
  if (!jwt) throw new Error('Sign in first.');
  let res: Response;
  try {
    res = await fetch(`${url}/functions/v1/exos-event-import/${path}`, {
      method: init.method,
      headers: {
        ...(env.VITE_SUPABASE_ANON_KEY ? { apikey: env.VITE_SUPABASE_ANON_KEY } : {}),
        Authorization: `Bearer ${jwt}`,
        ...(init.body !== undefined ? { 'Content-Type': 'application/json' } : {}),
      },
      ...(init.body !== undefined ? { body: JSON.stringify(init.body) } : {}),
    });
  } catch {
    throw new Error("Couldn't reach Exos. Check the connection.");
  }
  const out = await res.json().catch(() => null);
  if (!res.ok) {
    throw new Error(typeof out?.error === 'string' ? out.error : res.status === 404 ? 'Importing is not deployed yet.' : `Request failed (${res.status}).`);
  }
  return out as T;
}

export function parseImportChoice(r: Record<string, unknown>): ImportChoice {
  return {
    id: String(r.id ?? ''), name: String(r.name ?? ''), start: typeof r.start === 'string' ? r.start : null,
    status: STATUSES.includes(r.status as SourceStatus) ? (r.status as SourceStatus) : 'unknown',
    url: String(r.url ?? ''), venue: typeof r.venue === 'string' ? r.venue : null,
    priceMin: num(r.price_min), priceMax: num(r.price_max),
    currency: typeof r.currency === 'string' ? r.currency : null,
    imageUrl: typeof r.image_url === 'string' ? r.image_url : null,
    importedEventId: typeof r.imported_event_id === 'string' ? r.imported_event_id : null,
  };
}

function parseResult(r: Record<string, unknown>): ImportResult {
  return {
    ...(typeof r.id === 'string' ? { id: r.id } : {}),
    ok: r.ok === true,
    ...(typeof r.event_id === 'string' ? { eventId: r.event_id } : {}),
    ...(typeof r.created === 'boolean' ? { created: r.created } : {}),
    ...(typeof r.status === 'string' ? { status: r.status } : {}),
    ...(typeof r.error === 'string' ? { error: r.error } : {}),
  };
}

export async function listEventbriteImports(orgId: string): Promise<ImportChoice[]> {
  const out = await callImport<{ events?: Array<Record<string, unknown>> }>(`eventbrite/events?org=${encodeURIComponent(orgId)}`, { method: 'GET' });
  return (out.events ?? []).map(parseImportChoice);
}

export async function importEventbriteEvents(orgId: string, ids: string[]): Promise<ImportResult[]> {
  const out = await callImport<{ results?: Array<Record<string, unknown>> }>('eventbrite/import', { method: 'POST', body: { org: orgId, ids } });
  return (out.results ?? []).map(parseResult);
}

export async function importFromLink(orgId: string, url: string, details?: DraftDetails): Promise<ImportResult> {
  const out = await callImport<Record<string, unknown>>('link', { method: 'POST', body: { org: orgId, url, ...(details ? { details } : {}) } });
  return parseResult(out);
}

export async function checkLinkOutNow(eventId: string): Promise<void> {
  await callImport('check', { method: 'POST', body: { event: eventId } });
}
