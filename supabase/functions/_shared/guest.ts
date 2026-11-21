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

/**
 * The network an address stands for, for per-network limits: an IPv4 address
 * as it is (an IPv4-mapped IPv6 address as its IPv4), an IPv6 address as its
 * /64 ("v6:2001:db8:0:1"), since one subscriber or device holds a whole /64
 * and could otherwise rotate through it to dodge a limit. Anything else
 * (e.g. "unknown") unchanged.
 */
export function networkOf(ip: string): string {
  let a = ip.trim().toLowerCase();
  if (a.startsWith("[")) a = a.slice(1, a.indexOf("]") > 0 ? a.indexOf("]") : undefined);
  a = a.replace(/%.*$/, ""); // zone id
  const mapped = /^(?:0{0,4}:){0,5}(?:0{0,4}:)?ffff:(\d{1,3}(?:\.\d{1,3}){3})$/.exec(a);
  if (mapped) return mapped[1];
  if (!a.includes(":") || !/^[0-9a-f:.]+$/.test(a)) return ip;
  // A trailing dotted IPv4 counts as two hextets.
  let tail: string[] = [];
  const v4 = /:(\d{1,3}(?:\.\d{1,3}){3})$/.exec(a);
  if (v4) {
    const o = v4[1].split(".").map(Number);
    if (o.some((x) => x > 255)) return ip;
    tail = [((o[0] << 8) | o[1]).toString(16), ((o[2] << 8) | o[3]).toString(16)];
    a = a.slice(0, a.length - v4[1].length - 1) + (a.endsWith("::" + v4[1]) ? ":" : "");
  }
  const halves = a.split("::");
  if (halves.length > 2) return ip;
  const head = halves[0] ? halves[0].split(":") : [];
  const rest = halves.length === 2 && halves[1] ? halves[1].split(":") : [];
  const known = [...head, ...rest].length + tail.length;
  if (halves.length === 1 && known !== 8) return ip;
  if (known > 8 || [...head, ...rest].some((h) => !/^[0-9a-f]{1,4}$/.test(h))) return ip;
  const full = [...head, ...Array(8 - known).fill("0"), ...rest, ...tail];
  return "v6:" + full.slice(0, 4).map((h) => h.replace(/^0+(?=.)/, "")).join(":");
}

/**
 * Salted SHA-256 hex of the client's network (networkOf: an IPv4 address, an
 * IPv6 /64), for per-network limits: the guest hold, guest promo codes, the
 * public feeds' and APIs' rate limits.
 */
export async function hashIp(ip: string | null, salt: string): Promise<string | null> {
  if (!ip) return null;
  const bytes = new TextEncoder().encode(`exos-guest:${salt}:${networkOf(ip)}`);
  const digest = await crypto.subtle.digest("SHA-256", bytes);
  return Array.from(new Uint8Array(digest), (b) => b.toString(16).padStart(2, "0")).join("");
}
