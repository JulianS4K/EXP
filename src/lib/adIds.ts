// Client side of the per-checkout ad ids (mig 20260929131000). The sanitizer
// is shared with exos-checkout (supabase/functions/_shared/adIds.ts), which
// validates everything again.
//
//   * Click ids (gclid, ttclid, fbclid, ...) come off the landing URL. Like
//     attribution, they're kept in sessionStorage per event for the visit, so
//     an OAuth sign-in round trip (which drops the query string) doesn't lose
//     them. A newer click for the same platform replaces the older one.
//     They're never copied onto share links (lib/attribution.ts is).
//   * Browser ids are read from the vendors' first-party cookies only with the
//     matching consent (lib/consent.ts): _fbp / _fbc with ADVERTISING consent,
//     the GA client id (_ga) with ANALYTICS consent.
//   * The consent state at checkout (exos_checkout_sessions.consent_marketing)
//     is the ADVERTISING category, as granted / denied / unknown. Global
//     Privacy Control without an explicit opt-in reads as denied.

import {
  browserIdsFromCookies,
  clickIdsOnly,
  isEmptyAdIds,
  normalizeConsent,
  readAdIds,
  type AdIds,
  type MarketingConsent,
} from '../../supabase/functions/_shared/adIds.ts';
import { getConsentState } from './consent';

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

/** Marketing (advertising) consent as sent with a checkout. */
export function checkoutConsent(): MarketingConsent {
  return normalizeConsent(getConsentState().advertising);
}

/**
 * Everything to send with a checkout for this event: the stored (and current
 * URL's) click ids, plus browser ids from cookies for each granted category.
 */
export function checkoutAdIds(eventId: string, search = '', cookie?: string): AdIds {
  const clicks = captureClickIds(eventId, search);
  const consent = getConsentState();
  const ads = consent.advertising === 'granted';
  const analytics = consent.analytics === 'granted';
  if (!ads && !analytics) return clicks;
  let jar = cookie;
  if (jar === undefined) {
    try { jar = typeof document !== 'undefined' ? document.cookie : ''; } catch { jar = ''; }
  }
  const { fbp, fbc, ga_client_id } = browserIdsFromCookies(jar);
  const out: AdIds = { ...clicks };
  if (ads && fbp) out.fbp = fbp;
  if (ads && fbc) out.fbc = fbc;
  if (analytics && ga_client_id) out.ga_client_id = ga_client_id;
  return out;
}
