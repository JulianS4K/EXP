// Guest checkout helpers (mig 20260928050000), shared by exos-checkout and the
// SPA tests. No Deno or Node APIs beyond WebCrypto, so vitest imports it too.

// Same shape the DB enforces in exos_create_guest_hold.
const EMAIL_RE = /^[^@\s]+@[^@\s]+\.[^@\s]+$/;

/** Lower-cased, trimmed email, or null when it isn't a usable address. */
export function normalizeGuestEmail(raw: unknown): string | null {
  if (typeof raw !== "string") return null;
  const e = raw.trim().toLowerCase();
  if (e.length === 0 || e.length > 254 || !EMAIL_RE.test(e)) return null;
  return e;
}

/**
 * The client IP as the platform saw it, never as the client claims it:
 * cf-connecting-ip (set by Cloudflare in front of Supabase, overwriting any
 * value the client sent), else x-real-ip, else the LAST x-forwarded-for hop
 * (the one our proxy appended; earlier hops are whatever the client wrote).
 * With none, every such request shares one bucket ("unknown") rather than
 * skipping the limit. Only ever hashed, never stored or logged.
 */
export function clientIp(get: (name: string) => string | null): string {
  const pick = (v: string | null | undefined) => {
    const ip = v?.trim() ?? '';
    return ip.length > 0 && ip.length <= 64 ? ip : null;
  };
  const hops = (get("x-forwarded-for") ?? "").split(",").map((h) => h.trim()).filter(Boolean);
  return pick(get("cf-connecting-ip")) ?? pick(get("x-real-ip")) ?? pick(hops[hops.length - 1]) ?? "unknown";
}

/** Salted SHA-256 hex of the IP, for the per-network guest hold limit. */
export async function hashIp(ip: string | null, salt: string): Promise<string | null> {
  if (!ip) return null;
  const bytes = new TextEncoder().encode(`exos-guest:${salt}:${ip}`);
  const digest = await crypto.subtle.digest("SHA-256", bytes);
  return Array.from(new Uint8Array(digest), (b) => b.toString(16).padStart(2, "0")).join("");
}
