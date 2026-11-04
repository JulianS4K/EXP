// Recommendations (mig 20261102140000): similar events, events for a fan and
// fans for an event. The score is supabase/functions/_shared/recommend.ts
// (shared with exos-api; the SQL uses the same weights). Pure parsing and the
// tables' client-side sort / filter below; the calls are in ./orderDeskApi.ts.

import {
  compareRanked, fanRecReasons, fanRecScore, recReasons, type FanRecSignals, type RecSignals,
} from '../../supabase/functions/_shared/recommend.ts';

export * from '../../supabase/functions/_shared/recommend.ts';

export interface RecEvent {
  id: string;
  name: string;
  slug: string | null;
  startsAt: string;
  venueName: string | null;
  orgName: string;
  orgSlug: string | null;
  sameOrg: boolean;
  score: number;
  signals: RecSignals;
  reasons: string[];
}

export interface RecFan {
  id: string;
  email: string;
  name: string | null;
  ordersCount: number;
  lastOrderAt: string | null;
  score: number;
  signals: FanRecSignals;
  reasons: string[];
}

const int = (v: unknown) => Math.max(0, Math.trunc(Number(v) || 0));

export function parseRecSignals(s: any): RecSignals {
  return {
    shared_artists: int(s?.shared_artists), same_venue: s?.same_venue === true, same_series: s?.same_series === true,
    shared_genres: int(s?.shared_genres), shared_tags: int(s?.shared_tags), co_buyers: int(s?.co_buyers),
    days_apart: s?.days_apart == null ? null : int(s.days_apart),
  };
}

export function parseRecEvent(r: any): RecEvent {
  const signals = parseRecSignals(r?.signals);
  return {
    id: String(r?.id ?? ''), name: String(r?.name ?? ''), slug: r?.slug ?? null, startsAt: String(r?.starts_at ?? ''),
    venueName: r?.venue_name ?? null, orgName: String(r?.org?.name ?? ''), orgSlug: r?.org?.slug ?? null,
    sameOrg: r?.same_org === true, score: int(r?.score), signals, reasons: recReasons(signals),
  };
}

export function parseRecFan(r: any): RecFan {
  const signals: FanRecSignals = {
    artist_events: int(r?.signals?.artist_events), venue_events: int(r?.signals?.venue_events),
    series_events: int(r?.signals?.series_events), genre_events: int(r?.signals?.genre_events),
    tag_events: int(r?.signals?.tag_events),
  };
  const name = [r?.first_name, r?.last_name].filter(Boolean).join(' ').trim();
  return {
    id: String(r?.id ?? ''), email: String(r?.email ?? ''), name: name || null, ordersCount: int(r?.orders_count),
    lastOrderAt: r?.last_order_at ?? null, score: int(r?.score ?? fanRecScore(signals)), signals, reasons: fanRecReasons(signals),
  };
}

export type RecEventSort = 'score' | 'date' | 'name';
export type RecEventFilter = 'all' | 'org' | 'other';

/** A page of recommended events, filtered (own org / others) and sorted locally. */
export function viewRecEvents(rows: RecEvent[], filter: RecEventFilter, sort: RecEventSort): RecEvent[] {
  const kept = rows.filter((r) => filter === 'all' || (filter === 'org' ? r.sameOrg : !r.sameOrg));
  const byDb = (a: RecEvent, b: RecEvent) =>
    compareRanked({ id: a.id, score: a.score, starts_at: a.startsAt }, { id: b.id, score: b.score, starts_at: b.startsAt });
  const cmp = sort === 'score' ? byDb
    : sort === 'date' ? (a: RecEvent, b: RecEvent) => a.startsAt.localeCompare(b.startsAt) || a.id.localeCompare(b.id)
    : (a: RecEvent, b: RecEvent) => a.name.localeCompare(b.name) || a.id.localeCompare(b.id);
  return [...kept].sort(cmp);
}

export type RecFanSort = 'score' | 'recent' | 'email';

/** A page of recommended fans, searched and sorted locally. */
export function viewRecFans(rows: RecFan[], search: string, sort: RecFanSort): RecFan[] {
  const q = search.trim().toLowerCase();
  const kept = q ? rows.filter((r) => r.email.toLowerCase().includes(q) || (r.name ?? '').toLowerCase().includes(q)) : rows;
  const cmp = sort === 'email'
    ? (a: RecFan, b: RecFan) => a.email.localeCompare(b.email)
    : sort === 'recent'
      ? (a: RecFan, b: RecFan) => (b.lastOrderAt ?? '').localeCompare(a.lastOrderAt ?? '') || a.id.localeCompare(b.id)
      : (a: RecFan, b: RecFan) => b.score - a.score || (b.lastOrderAt ?? '').localeCompare(a.lastOrderAt ?? '') || a.id.localeCompare(b.id);
  return [...kept].sort(cmp);
}
