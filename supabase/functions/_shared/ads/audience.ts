// The one audience builder (ads phase, mig 20261121190500): Exos fans and
// buyers -> consent-filtered, deduped members, and each platform's rows from
// them. Pure, so vitest imports it.
//
// Input: exos_ads_audience_source's rows (service role), already limited in
// SQL to people who granted ADVERTISING consent on a paid / issued order
// whose email was proven (the latest counted choice wins; mail and list
// opt-outs, discarded, deleted and banned left out), and already HASHED in
// SQL (review of #138, S4: no raw email or phone leaves Postgres). Each row
// carries the forms hashedIds.ts names (em, em_google, em_reddit, ph,
// ph_digits), built by the same SQL helpers as the conversions outbox. The
// builder checks the consent flag again, keeps only 64-hex values, and
// ignores anything else in a row (a raw "email" / "phone" key included), so
// nothing raw goes into a plan, an audit step or a payload.
//
// Dedupe: one member per person, by the plain email hash, else the phone
// hash; a later row for the same person fills in a missing phone.

import type { HashedIdentifiers } from "../hashedIds.ts";

export interface AudienceSourceRow {
  em?: string | null;
  em_google?: string | null;
  em_reddit?: string | null;
  ph?: string | null;
  ph_digits?: string | null;
  /** 'granted' only: anything else is dropped. */
  ad_consent?: string | null;
  source?: string | null;
}

const HEX64 = /^[0-9a-f]{64}$/;
const HASH_KEYS = ["em", "em_google", "em_reddit", "ph", "ph_digits"] as const;

/** A source row's hashes, each kept only when it is a SHA-256 hex. */
export function rowHashes(r: AudienceSourceRow): HashedIdentifiers {
  const out: HashedIdentifiers = {};
  for (const k of HASH_KEYS) {
    const v = r?.[k];
    if (typeof v === "string" && HEX64.test(v)) out[k] = v;
  }
  return out;
}

export interface BuiltAudience {
  members: HashedIdentifiers[];
  counts: { rows: number; noConsent: number; noIdentifier: number; duplicates: number; members: number; withEmail: number; withPhone: number };
}

export async function buildAudience(rows: readonly AudienceSourceRow[]): Promise<BuiltAudience> {
  const counts = { rows: rows.length, noConsent: 0, noIdentifier: 0, duplicates: 0, members: 0, withEmail: 0, withPhone: 0 };
  const byKey = new Map<string, HashedIdentifiers>();
  const order: string[] = [];
  for (const r of rows) {
    if (r?.ad_consent !== "granted") { counts.noConsent++; continue; }
    const h = rowHashes(r);
    const key = h.em ?? h.ph;
    if (!key) { counts.noIdentifier++; continue; }
    const seen = byKey.get(key);
    if (seen) {
      counts.duplicates++;
      if (!seen.ph && h.ph) { seen.ph = h.ph; seen.ph_digits = h.ph_digits; }
      continue;
    }
    byKey.set(key, h);
    order.push(key);
  }
  const members = order.map((k) => byKey.get(k)!);
  counts.members = members.length;
  counts.withEmail = members.filter((m) => m.em).length;
  counts.withPhone = members.filter((m) => m.ph).length;
  return { members, counts };
}

/** Meta Custom Audiences: schema [EMAIL, PHONE]; a missing value is "". */
export const META_SCHEMA = ["EMAIL", "PHONE"] as const;
export function metaRows(members: readonly HashedIdentifiers[]): string[][] {
  return members.filter((m) => m.em || m.ph_digits).map((m) => [m.em ?? "", m.ph_digits ?? ""]);
}

/** Google Customer Match (Data Manager audienceMembers): Google's email hash and the E.164 phone hash. */
export function googleMembers(members: readonly HashedIdentifiers[]): Array<{ userData: { userIdentifiers: Array<Record<string, string>> } }> {
  return members
    .map((m) => [
      ...(m.em_google ? [{ emailAddress: m.em_google }] : []),
      ...(m.ph ? [{ phoneNumber: m.ph }] : []),
    ])
    .filter((ids) => ids.length > 0)
    .map((userIdentifiers) => ({ userData: { userIdentifiers } }));
}

/** Reddit CUSTOMER_LIST: one EMAIL_SHA256 column, Reddit's normalization; people without an email are left out. */
export function redditRows(members: readonly HashedIdentifiers[]): string[][] {
  const seen = new Set<string>();
  const out: string[][] = [];
  for (const m of members) {
    if (!m.em_reddit || seen.has(m.em_reddit)) continue;
    seen.add(m.em_reddit);
    out.push([m.em_reddit]);
  }
  return out;
}

/** What an audit step records instead of a batch of hashes: the shape and the count, never the hashes. */
export function hashedRowsSummary(n: number, columns: readonly string[]): string {
  return `[${n} hashed row${n === 1 ? "" : "s"} (${columns.join(", ")}), not recorded]`;
}

/** Split rows into chunks of at most `size`, order kept. */
export function chunk<T>(rows: readonly T[], size: number): T[][] {
  const n = Math.max(1, Math.floor(size));
  const out: T[][] = [];
  for (let i = 0; i < rows.length; i += n) out.push(rows.slice(i, i + n));
  return out;
}
