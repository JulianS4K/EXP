// Client side of the per-checkout ad ids (mig 20260929131000). The sanitizer
// is shared with exos-checkout (supabase/functions/_shared/adIds.ts), which
// validates everything again.
//
//   * Click ids (gclid, ttclid, fbclid, ...) come off the landing URL. Like
//     attribution, they're kept in sessionStorage per event for the visit, so
//     an OAuth sign-in round trip (which drops the query string) doesn't lose
//     them. A newer click for the same platform replaces the older one.
//     They're never copied onto share links (lib/attribution.ts is).
//   * Browser ids (_fbp, _fbc, the GA client id from _ga) are read from the
//     vendors' first-party cookies only when marketing consent is granted.
//   * The consent state at checkout goes along as granted / denied / unknown.

import {
  browserIdsFromCookies,
  clickIdsOnly,
  isEmptyAdIds,
  normalizeConsent,
  readAdIds,
  type AdIds,
  type MarketingConsent,
} from '../../supabase/functions/_shared/adIds.ts';
import { getConsent } from './consent';

export type { AdIds, MarketingConsent };

const KEY = (eventId: string) => `exos_adids:${eventId}`;

export function clickIdsFromSearch(search: string): AdIds {
  const params = new URLSearchParams(search);
  return clickIdsOnly(readAdIds((k) => params.get(k) ?? undefined));
}

function readStored(eventId: string): AdIds {
  try {
    const raw = sessionStorage.getItem(KEY(eventId));
    if (!raw) return {};
    const obj = JSON.parse(raw) as Record<string, unknown>;
    return clickIdsOnly(readAdIds((k) => obj?.[k]));
  } catch {
    return {};
  }
}

/** Remember the click ids on this landing URL for the event; returns what applies now. */
export function captureClickIds(eventId: string, search: string): AdIds {
  const fresh = clickIdsFromSearch(search);
  const merged = { ...readStored(eventId), ...fresh };
  if (!isEmptyAdIds(fresh)) {
    try { sessionStorage.setItem(KEY(eventId), JSON.stringify(merged)); } catch { /* storage blocked */ }
  }
  return merged;
}

/** Marketing consent as sent with a checkout. */
export function checkoutConsent(): MarketingConsent {
  return normalizeConsent(getConsent());
}

/**
 * Everything to send with a checkout for this event: the stored (and current
 * URL's) click ids, plus browser ids from cookies when consent is granted.
 */
export function checkoutAdIds(eventId: string, search = '', cookie?: string): AdIds {
  const clicks = captureClickIds(eventId, search);
  if (checkoutConsent() !== 'granted') return clicks;
  let jar = cookie;
  if (jar === undefined) {
    try { jar = typeof document !== 'undefined' ? document.cookie : ''; } catch { jar = ''; }
  }
  return { ...clicks, ...browserIdsFromCookies(jar) };
}
