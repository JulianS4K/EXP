// Ad click ids, browser ids and marketing consent captured per checkout
// (mig 20260929131000, exos_checkout_sessions.ad_ids / consent_marketing /
// client_ip_hash / user_agent). One sanitizer shared by exos-checkout and the
// SPA (src/lib/adIds.ts), so both keep exactly the same fields. No imports,
// so Deno and vitest can both load it.
//
// Kept apart from _shared/attribution.ts on purpose: attribution (promoter,
// UTM) is copied onto share and checkout links, and ad click ids must never
// be forwarded that way (a shared link would credit someone else's click).
//
// Click ids are opaque strings from the ad platforms: we only check the
// character set ([A-Za-z0-9._-]) and length (256), and drop anything else
// rather than trying to fix it. Browser ids come from first-party cookies the
// vendors' pixels set (_fbp, _fbc, _ga); the SPA reads them only when the
// visitor granted marketing consent.

/** URL click ids, keyed by the query parameter each platform appends. */
export const CLICK_ID_KEYS = [
  "gclid",    // Google Ads
  "gbraid",   // Google Ads (iOS app-to-web)
  "wbraid",   // Google Ads (iOS web-to-app)
  "ttclid",   // TikTok
  "rdt_cid",  // Reddit
  "ScCid",    // Snap
  "twclid",   // X (Twitter)
  "msclkid",  // Microsoft Ads
  "fbclid",   // Meta (also kept in attribution, mig 20260924223000)
] as const;

export type ClickIdKey = typeof CLICK_ID_KEYS[number];

export interface AdIds {
  gclid?: string;
  gbraid?: string;
  wbraid?: string;
  ttclid?: string;
  rdt_cid?: string;
  ScCid?: string;
  twclid?: string;
  msclkid?: string;
  fbclid?: string;
  /** Meta browser id (_fbp cookie): fb.1.<ms>.<random>. */
  fbp?: string;
  /** Meta click cookie (_fbc): fb.1.<ms>.<fbclid>. */
  fbc?: string;
  /** GA4 client id from the _ga cookie: <random>.<seconds>. */
  ga_client_id?: string;
}

export type MarketingConsent = "granted" | "denied" | "unknown";

const OPAQUE_RE = /^[A-Za-z0-9._-]{1,256}$/;
const FB_COOKIE_RE = /^fb\.[0-9]\.[0-9]{1,16}\.[A-Za-z0-9._-]{1,256}$/;
const GA_CLIENT_ID_RE = /^[0-9]{1,20}\.[0-9]{1,20}$/;

/** An ad platform's click id: [A-Za-z0-9._-], 1-256 chars, else undefined. */
export function sanitizeClickId(v: unknown): string | undefined {
  if (typeof v !== "string") return undefined;
  const t = v.trim();
  return OPAQUE_RE.test(t) ? t : undefined;
}

/** _fbp / _fbc cookie value (fb.<subdomain index>.<ms>.<value>), else undefined. */
export function sanitizeFbCookie(v: unknown): string | undefined {
  if (typeof v !== "string") return undefined;
  const t = v.trim();
  return t.length <= 300 && FB_COOKIE_RE.test(t) ? t : undefined;
}

/** A GA client id (<random>.<seconds>), else undefined. */
export function sanitizeGaClientId(v: unknown): string | undefined {
  if (typeof v !== "string") return undefined;
  const t = v.trim();
  return GA_CLIENT_ID_RE.test(t) ? t : undefined;
}

/**
 * The GA client id inside a _ga cookie: "GA1.1.123456789.1690000000" ->
 * "123456789.1690000000" (the last two dot-separated parts).
 */
export function gaClientIdFromCookie(v: unknown): string | undefined {
  if (typeof v !== "string") return undefined;
  const parts = v.trim().split(".");
  if (parts.length < 4 || !/^GA[0-9]+$/.test(parts[0])) return undefined;
  return sanitizeGaClientId(parts.slice(-2).join("."));
}

/**
 * Build clean AdIds from any key/value source (URLSearchParams, a JSON body).
 * Unknown keys are dropped; bad values are dropped, not fixed.
 */
export function readAdIds(get: (key: string) => unknown): AdIds {
  const out: AdIds = {};
  for (const k of CLICK_ID_KEYS) {
    const v = sanitizeClickId(get(k));
    if (v) out[k] = v;
  }
  const fbp = sanitizeFbCookie(get("fbp"));
  if (fbp) out.fbp = fbp;
  const fbc = sanitizeFbCookie(get("fbc"));
  if (fbc) out.fbc = fbc;
  const ga = sanitizeGaClientId(get("ga_client_id"));
  if (ga) out.ga_client_id = ga;
  return out;
}

/** Just the URL click ids of a set (what may be stashed from a landing URL). */
export function clickIdsOnly(ids: AdIds): AdIds {
  const out: AdIds = {};
  for (const k of CLICK_ID_KEYS) if (ids[k]) out[k] = ids[k];
  return out;
}

export function isEmptyAdIds(ids: AdIds): boolean {
  return Object.keys(ids).length === 0;
}

/** The SPA's consent state ('granted' / 'denied' / 'unset') as stored: anything else is 'unknown'. */
export function normalizeConsent(v: unknown): MarketingConsent {
  return v === "granted" || v === "denied" ? v : "unknown";
}

/** Cookie header / document.cookie -> name -> value (first one wins, values URI-decoded when valid). */
export function parseCookies(cookie: string | null | undefined): Record<string, string> {
  const out: Record<string, string> = {};
  if (!cookie) return out;
  for (const part of cookie.split(";")) {
    const i = part.indexOf("=");
    if (i <= 0) continue;
    const name = part.slice(0, i).trim();
    if (!name || name in out) continue;
    let value = part.slice(i + 1).trim();
    try { value = decodeURIComponent(value); } catch { /* keep raw */ }
    out[name] = value;
  }
  return out;
}

/**
 * Browser ids from the vendors' first-party cookies. The caller decides
 * whether it may read them (only with marketing consent).
 */
export function browserIdsFromCookies(cookie: string | null | undefined): AdIds {
  const c = parseCookies(cookie);
  const out: AdIds = {};
  const fbp = sanitizeFbCookie(c._fbp);
  if (fbp) out.fbp = fbp;
  const fbc = sanitizeFbCookie(c._fbc);
  if (fbc) out.fbc = fbc;
  const ga = gaClientIdFromCookie(c._ga);
  if (ga) out.ga_client_id = ga;
  return out;
}

export const USER_AGENT_MAX = 512;

/** The request's User-Agent for the checkout record: control characters stripped, at most 512 chars, null if empty. */
export function truncateUserAgent(v: string | null | undefined): string | null {
  if (typeof v !== "string") return null;
  // deno-lint-ignore no-control-regex
  const t = v.replace(/[\u0000-\u001f\u007f]/g, "").trim().slice(0, USER_AGENT_MAX);
  return t ? t : null;
}
