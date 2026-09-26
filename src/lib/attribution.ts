// Client side of sale attribution. The sanitizer is shared with exos-checkout
// (supabase/functions/_shared/attribution.ts) so the SPA and the server keep
// exactly the same fields.
//
// A buyer often lands with ?promoter=…&utm_source=… and then signs in (an
// OAuth round trip drops the query string) before buying, so the first
// attribution seen for an event is kept in sessionStorage for the visit.
// First touch wins: a later untagged visit to the same event doesn't erase it.

import { readAttribution, type Attribution, isEmptyAttribution } from '../../supabase/functions/_shared/attribution.ts';

export type { Attribution };
export { readAttribution, isEmptyAttribution };

const KEY = (eventId: string) => `exos_attr:${eventId}`;

export function attributionFromSearch(search: string): Attribution {
  const params = new URLSearchParams(search);
  return readAttribution((k) => params.get(k) ?? undefined);
}

// Remember this visit's attribution for the event (first touch wins) and
// return whatever applies now.
export function captureAttribution(eventId: string, search: string): Attribution {
  const fresh = attributionFromSearch(search);
  let stored: Attribution = {};
  try {
    const raw = sessionStorage.getItem(KEY(eventId));
    if (raw) stored = readAttribution((k) => (JSON.parse(raw) as Record<string, unknown>)[k]);
  } catch {
    /* storage blocked or corrupt: fall back to the URL alone */
  }
  if (!isEmptyAttribution(stored)) return stored;
  if (!isEmptyAttribution(fresh)) {
    try { sessionStorage.setItem(KEY(eventId), JSON.stringify(fresh)); } catch { /* non-fatal */ }
  }
  return fresh;
}

// Set attribution params on a URL, replacing any it already has.
export function withAttribution(url: string, attr: Attribution): string {
  let u: URL;
  try { u = new URL(url); } catch { return url; }
  for (const [k, v] of Object.entries(attr)) {
    if (v) u.searchParams.set(k, v);
  }
  return u.toString();
}
