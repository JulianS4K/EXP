// Hashed identifiers: the one builder for every place Exos hands a platform
// a buyer's email or phone, hashed (server-side conversions,
// _shared/conversions; audience sync, ChannelAdapter.syncAudience). Pure: no
// Deno or Node APIs beyond Web Crypto, so vitest imports it too.
//
// Only the SHA-256 hex of a normalized value ever leaves Exos; the raw value
// never goes into a payload, a plan or an audit row. The normalization
// matches the SQL helpers (_exos_email_sha256 / _exos_email_sha256_google,
// mig 20260930100000), so a hash built here equals the one the outbox
// trigger stored. Moved here from _shared/conversions/common.ts (which
// re-exports it) by the channel core, mig 20261121162400.

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
 * Reddit's rule (Conversions API and CUSTOMER_LIST audiences): lower case,
 * trimmed, and in the local part everything from the first "+" on dropped
 * and every dot removed, on every domain (not only gmail). SQL twin:
 * _exos_email_sha256_reddit (mig 20261121190500), with the same edges: only
 * ASCII whitespace is trimmed (space, tab, newline, CR, VT, FF; not JS
 * trim()'s Unicode spaces, which Postgres btrim leaves), and an address
 * with whitespace left inside or with other than exactly one "@" gives null.
 */
export function normalizeEmailReddit(raw: unknown): string | null {
  if (typeof raw !== "string") return null;
  const e = raw.replace(/^[ \t\n\r\v\f]+|[ \t\n\r\v\f]+$/g, "").toLowerCase();
  if (!e || /[ \t\n\r\v\f]/.test(e) || e.split("@").length !== 2) return null;
  const [rawLocal, domain] = e.split("@");
  const local = rawLocal.split("+")[0].replace(/\./g, "");
  return local && domain ? `${local}@${domain}` : null;
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

/** The hashed forms a platform may take; each present only when the input normalized. */
export interface HashedIdentifiers {
  /** sha256(lower(trim(email))): Meta, TikTok, Snap, X, LinkedIn, Luma-style lists. */
  em?: string;
  /** sha256 of Google's normalization (gmail dots dropped): GA4, Google Ads, Customer Match. */
  em_google?: string;
  /** sha256 of Reddit's normalization (+tag and local-part dots dropped): Reddit CAPI, Reddit audiences. */
  em_reddit?: string;
  /** sha256 of the E.164 phone with its +: GA4, TikTok. */
  ph?: string;
  /** sha256 of the E.164 digits without the +: Meta, Snap. */
  ph_digits?: string;
}

/** One person's identifiers, hashed. Nothing raw comes back. */
export async function hashedIdentifiers(input: { email?: unknown; phone?: unknown }): Promise<HashedIdentifiers> {
  const out: HashedIdentifiers = {};
  const email = normalizeEmail(input.email);
  const emailG = normalizeEmailGoogle(input.email);
  const emailR = normalizeEmailReddit(input.email);
  const phone = normalizePhone(input.phone);
  const digits = normalizePhone(input.phone, false);
  if (email) out.em = await sha256Hex(email);
  if (emailG) out.em_google = await sha256Hex(emailG);
  if (emailR) out.em_reddit = await sha256Hex(emailR);
  if (phone) out.ph = await sha256Hex(phone);
  if (digits) out.ph_digits = await sha256Hex(digits);
  return out;
}

/**
 * A batch for an audience sync: one entry per distinct person (by hashed
 * email, else hashed phone), people with neither dropped, order kept.
 */
export async function hashedAudience(people: Array<{ email?: unknown; phone?: unknown }>): Promise<HashedIdentifiers[]> {
  const seen = new Set<string>();
  const out: HashedIdentifiers[] = [];
  for (const p of people) {
    const h = await hashedIdentifiers(p);
    const key = h.em ?? h.ph;
    if (!key || seen.has(key)) continue;
    seen.add(key);
    out.push(h);
  }
  return out;
}
