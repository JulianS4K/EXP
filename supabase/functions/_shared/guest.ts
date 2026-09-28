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
 * The client IP as the edge sees it: the first x-forwarded-for hop, else
 * cf-connecting-ip / x-real-ip. Only ever hashed, never stored or logged.
 */
export function clientIp(get: (name: string) => string | null): string | null {
  const xff = get("x-forwarded-for");
  const first = xff?.split(",")[0]?.trim();
  const ip = first || get("cf-connecting-ip")?.trim() || get("x-real-ip")?.trim() || "";
  return ip.length > 0 && ip.length <= 64 ? ip : null;
}

/** Salted SHA-256 hex of the IP, for the per-network guest hold limit. */
export async function hashIp(ip: string | null, salt: string): Promise<string | null> {
  if (!ip) return null;
  const bytes = new TextEncoder().encode(`exos-guest:${salt}:${ip}`);
  const digest = await crypto.subtle.digest("SHA-256", bytes);
  return Array.from(new Uint8Array(digest), (b) => b.toString(16).padStart(2, "0")).join("");
}
