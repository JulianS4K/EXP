// Server-side ad conversions: shared types and helpers for the per-platform
// request builders (meta.ts, tiktok.ts, ga4.ts, reddit.ts, snap.ts,
// googleAds.ts) and the exos-conversions-drain send loop (send.ts).
//
// The builders are pure: a claimed outbox row (exos_marketing_conversions,
// mig 20260930100000) + the org's credential in, a request (url, headers,
// body) or a skip reason out. No Deno or Node APIs beyond WebCrypto, so
// vitest imports them too. docs/marketing-conversions.md has the field
// mapping per platform and the API references.
//
// What a row carries (payload, written by the SQL trigger): SHA-256 hex of
// the normalized email only (never the address), the ad click / browser ids
// captured at checkout (mig 20260929131000), the user agent, the event id /
// slug / name and the quantity. No IP: the checkout keeps only a salted hash
// of it, which no platform can match on.

import type { AdIds } from "../adIds.ts";

export type Platform = "meta" | "tiktok" | "ga4" | "google_ads" | "reddit" | "snap";
export const PLATFORMS: readonly Platform[] = ["meta", "tiktok", "ga4", "google_ads", "reddit", "snap"];

export type ConversionEventName = "Purchase" | "Refund";

export interface ConversionPayload {
  /** The Stripe Checkout Session id: the order id every platform sees. */
  transaction_id: string;
  /** sha256(lower(trim(email))). */
  em?: string;
  /** Google's normalization (gmail dots dropped), for GA4 / Google Ads. */
  em_google?: string;
  /** sha256 of the E.164 phone (not collected today; kept for later). */
  ph?: string;
  user_agent?: string;
  ad_ids?: AdIds;
  /** When the checkout started (for a synthesized Meta fbc). */
  click_at?: string;
  quantity?: number;
  event?: { id: string; slug?: string; name?: string };
  refund_id?: string;
  partial?: boolean;
}

/** One claimed outbox row (what exos_conversions_claim_batch returns, minus the lease). */
export interface ConversionRow {
  id: string;
  platform: Platform;
  event_name: ConversionEventName;
  /** Stripe session id for Purchase (= the browser pixel's eventID); refund:<id> for Refund. */
  event_id_dedupe: string;
  occurred_at: string;
  value_cents: number;
  currency: string;
  payload: ConversionPayload;
}

export interface Credential {
  /** Non-secret ids: pixel_id, pixel_code, measurement_id, customer_id, conversion_action_id, login_customer_id. */
  config: Record<string, string>;
  /** Access token / API secret, from Vault. Never logged, redacted from planned requests. */
  secret: string;
  test_event_code?: string | null;
}

export interface BuildContext {
  /** https://… base of the SPA (EXOS_APP_BASE_URL), for event_source_url. Empty = omit. */
  appBase: string;
  now: Date;
}

export interface PlannedRequest {
  method: "POST";
  url: string;
  headers: Record<string, string>;
  body: unknown;
}

export type BuildResult = { ok: true; request: PlannedRequest } | { ok: false; skip: string };

export const skip = (reason: string): BuildResult => ({ ok: false, skip: reason });

/** Hosts the drain may POST to. A builder URL on any other host is refused. */
export const ALLOWED_HOSTS: ReadonlySet<string> = new Set([
  "graph.facebook.com",
  "business-api.tiktok.com",
  "www.google-analytics.com",
  "ads-api.reddit.com",
  "tr.snapchat.com",
  "datamanager.googleapis.com",
  // Google's OAuth token endpoint: the drain swaps each org's Google Ads
  // refresh token for an access token here (googleOAuth.ts).
  "oauth2.googleapis.com",
]);

const DAY = 86_400_000;
/**
 * How old an event each platform accepts. Conservative: Meta takes website
 * events up to 7 days back, GA4 Measurement Protocol timestamps up to 72
 * hours; the others are held to 7 days (Google Ads click conversions: 90).
 */
export const MAX_AGE_MS: Record<Platform, number> = {
  meta: 7 * DAY,
  tiktok: 7 * DAY,
  ga4: 3 * DAY,
  google_ads: 90 * DAY,
  reddit: 7 * DAY,
  snap: 7 * DAY,
};

/** Null when the row is fresh enough for the platform, else the skip reason. */
export function tooOld(row: ConversionRow, now: Date): string | null {
  const t = Date.parse(row.occurred_at);
  if (!Number.isFinite(t)) return "bad occurred_at";
  return now.getTime() - t > MAX_AGE_MS[row.platform] ? `older than the ${row.platform} window` : null;
}

export const unixSeconds = (iso: string): number => Math.floor(Date.parse(iso) / 1000);

/** Cents -> major units, 2 decimals, as a number (12.5 for 1250). */
export const toMajor = (cents: number): number => Math.round(cents) / 100;

export const upperCurrency = (c: string): string => (c || "usd").trim().toUpperCase();

/** Same page the buyer bought on: /e/<slug> or /event/<id>. Undefined without a base. */
export function eventSourceUrl(appBase: string, ev: ConversionPayload["event"]): string | undefined {
  const base = (appBase || "").replace(/\/+$/, "");
  if (!/^https:\/\//.test(base) || !ev?.id) return undefined;
  return ev.slug ? `${base}/e/${encodeURIComponent(ev.slug)}` : `${base}/event/${encodeURIComponent(ev.id)}`;
}

/** The unit price of the order's line (value / quantity), 2 decimals. */
export function unitPrice(valueCents: number, quantity: number | undefined): number {
  const q = quantity && quantity > 0 ? quantity : 1;
  return Math.round(valueCents / q) / 100;
}

const HEX64 = /^[0-9a-f]{64}$/;
/** A stored hash, only when it really is SHA-256 hex. */
export const hashOrUndefined = (v: unknown): string | undefined =>
  typeof v === "string" && HEX64.test(v) ? v : undefined;

// ---- normalization + hashing (parity with the SQL helpers) --------------

/** Trimmed, lower-cased email, or null. Same as SQL _exos_email_sha256's input. */
export function normalizeEmail(raw: unknown): string | null {
  if (typeof raw !== "string") return null;
  const e = raw.trim().toLowerCase();
  return e && e.includes("@") ? e : null;
}

/** Google's rule: also drop dots in the local part of gmail.com / googlemail.com. */
export function normalizeEmailGoogle(raw: unknown): string | null {
  const e = normalizeEmail(raw);
  if (!e) return null;
  const at = e.lastIndexOf("@");
  const local = e.slice(0, at), domain = e.slice(at + 1);
  return domain === "gmail.com" || domain === "googlemail.com" ? `${local.replace(/\./g, "")}@${domain}` : e;
}

/**
 * E.164 digits with a leading +, or null. Numbers without a country code are
 * assumed US/Canada (10 digits -> +1). Meta and Snap want it without the +
 * (normalizePhone(…, false)).
 */
export function normalizePhone(raw: unknown, withPlus = true): string | null {
  if (typeof raw !== "string") return null;
  let d = raw.replace(/[^0-9]/g, "");
  if (raw.trim().startsWith("00")) d = d.slice(2);
  if (d.length === 10 && !raw.trim().startsWith("+")) d = "1" + d;
  if (d.length < 8 || d.length > 15) return null;
  return withPlus ? `+${d}` : d;
}

export async function sha256Hex(s: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(s));
  return Array.from(new Uint8Array(digest), (b) => b.toString(16).padStart(2, "0")).join("");
}

// ---- redaction -----------------------------------------------------------

/**
 * The request with the secret replaced everywhere (url, headers, body), for
 * payload_planned and logs.
 */
export function redactRequest(req: PlannedRequest, secret: string): PlannedRequest {
  const scrub = (s: string) => (secret && secret.length >= 4 ? s.split(secret).join("[redacted]") : s);
  const scrubUrl = (u: string) => {
    const out = scrub(u);
    if (!secret || secret.length < 4) return out;
    // A secret in a query string arrives URL-encoded.
    return out.split(encodeURIComponent(secret)).join("[redacted]");
  };
  const headers: Record<string, string> = {};
  for (const [k, v] of Object.entries(req.headers)) headers[k] = scrub(v);
  return {
    method: req.method,
    url: scrubUrl(req.url),
    headers,
    body: JSON.parse(scrub(JSON.stringify(req.body ?? null))),
  };
}

/** Drop undefined / null / empty-string members (shallow), so bodies carry only what we have. */
export function compact<T extends Record<string, unknown>>(o: T): Partial<T> {
  const out: Record<string, unknown> = {};
  for (const [k, v] of Object.entries(o)) {
    if (v === undefined || v === null || v === "") continue;
    if (Array.isArray(v) && v.length === 0) continue;
    out[k] = v;
  }
  return out as Partial<T>;
}
