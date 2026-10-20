// Channels (mig 20261019090000): the Exos event as the mirrors on Eventbrite
// and Luma should show it. Pure: no Deno or Node APIs beyond Web Crypto, so the
// Deno tests and the planners share it.

export interface MirrorTier {
  id: string;
  name: string;
  description: string | null;
  priceCents: number;
  free: boolean;
  capacity: number;
  freeNow: number;
  hidden: boolean;
  /** Why this ticket type isn't mirrored (table, capacity group, no capacity). */
  skip: string | null;
}

export interface MirrorEvent {
  id: string;
  name: string;
  descriptionText: string;
  descriptionMd: string;
  startUtc: string;          // 2026-10-19T20:00:00Z
  endUtc: string;
  timezone: string;
  currency: string;          // upper case, e.g. USD
  status: string;            // draft | published | cancelled | ...
  venueName: string | null;
  address: { street?: string; city?: string; region?: string; postal?: string; country?: string };
  /** One line for a place lookup ("Blue Room, 1 Main St, Brooklyn, NY 11211, US"). */
  venueQuery: string | null;
  pack: number;
  tiers: MirrorTier[];
}

export interface StepRecord {
  op: string;
  method: "GET" | "POST";
  path: string;
  body?: unknown;
  ok?: boolean;
  error?: string;
}

export interface Io {
  /** Writes are sent only when live; otherwise POSTs are recorded and answered with a stand-in. */
  live: boolean;
  req(method: "GET" | "POST", path: string, body?: unknown): Promise<{ ok: boolean; status: number; body: any; error?: string }>;
}

export interface SyncResult {
  state: "synced" | "dry_run" | "error";
  external_id?: string;
  external_url?: string;
  external_meta?: Record<string, unknown>;
  hash?: string;
  plan?: { steps: StepRecord[] };
  error?: string;
  /** created: Exos added this class / ticket type on this pass. */
  tickets?: { tier_id: string; external_ticket_id: string; name: string; created?: boolean }[];
}

const str = (v: unknown) => (typeof v === "string" ? v.trim() : "");

/** "2026-10-19T20:00:00.000Z" -> "2026-10-19T20:00:00Z" (Eventbrite refuses milliseconds). */
export function utc(iso: string): string {
  const t = Date.parse(iso);
  return Number.isNaN(t) ? "" : new Date(t).toISOString().replace(/\.\d{3}Z$/, "Z");
}

export function mirrorEvent(payload: any): MirrorEvent | null {
  const e = payload?.event;
  if (!e || typeof e.id !== "string" || !str(e.name) || !e.starts_at) return null;
  const start = utc(e.starts_at);
  if (!start) return null;
  const end = utc(e.ends_at ?? "") || utc(new Date(Date.parse(start) + 3 * 3600_000).toISOString());
  const addr = e.venue_address && typeof e.venue_address === "object" ? e.venue_address : {};
  const address = {
    street: str(addr.street) || undefined, city: str(addr.city) || undefined, region: str(addr.region) || undefined,
    postal: str(addr.postal) || undefined, country: str(addr.country) || undefined,
  };
  const venueName = str(e.venue_name) || str(e.venue_location) || null;
  const line = [venueName, address.street, address.city, [address.region, address.postal].filter(Boolean).join(" "), address.country]
    .filter((x) => x && String(x).trim()).join(", ");
  const maxPer = Number(e.purchase_limits?.maxPerOrder);
  const descMd = str(e.description_md) || str(e.description);
  const tiers = (Array.isArray(payload?.tiers) ? payload.tiers : []).map((t: any): MirrorTier => {
    const cents = Math.round(Number(t.price ?? 0) * 100);
    const capacity = Number(t.capacity) || 0;
    return {
      id: String(t.id),
      name: str(t.name) || "Ticket",
      description: str(t.description) || null,
      priceCents: Number.isFinite(cents) && cents > 0 ? cents : 0,
      free: !(cents > 0),
      capacity,
      freeNow: Math.max(0, Number(t.free_now) || 0),
      hidden: t.visibility !== undefined && t.visibility !== null && t.visibility !== "public",
      skip: t.is_table ? "table ticket types stay on Exos"
        : t.in_quota ? "ticket types in a shared capacity group stay on Exos"
        : capacity <= 0 ? "set a capacity on this ticket type to sell it elsewhere" : null,
    };
  });
  return {
    id: e.id,
    name: str(e.name).slice(0, 200),
    descriptionText: descMd,
    descriptionMd: descMd,
    startUtc: start,
    endUtc: end,
    timezone: str(e.timezone) || "America/New_York",
    currency: (str(e.currency) || "usd").toUpperCase(),
    status: str(e.status) || "draft",
    venueName,
    address,
    venueQuery: line || null,
    pack: Number.isInteger(maxPer) && maxPer > 0 ? maxPer : 8,
    tiers,
  };
}

/** The first capacity a new ticket type gets: what Exos has free less one pack, at least 1. */
export function firstCapacity(t: MirrorTier, pack: number): number {
  return Math.max(1, t.freeNow - pack);
}

/** Everything a details pass sends, so an unchanged event costs no writes. */
export async function contentHash(ev: MirrorEvent): Promise<string> {
  const basis = JSON.stringify({
    n: ev.name, d: ev.descriptionMd, s: ev.startUtc, e: ev.endUtc, z: ev.timezone, c: ev.currency, st: ev.status,
    v: ev.venueQuery, t: ev.tiers.map((t) => [t.id, t.name, t.priceCents, t.hidden, t.skip]),
  });
  const buf = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(basis));
  return Array.from(new Uint8Array(buf)).map((b) => b.toString(16).padStart(2, "0")).join("");
}

/** Plain text -> the little HTML Eventbrite's description takes. */
export function textToHtml(text: string): string {
  const esc = text.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
  return esc.split(/\n{2,}/).map((p) => `<p>${p.replace(/\n/g, "<br>")}</p>`).join("") || "<p></p>";
}

/** Luma is plugged in but off until the operator sets EXOS_LUMA_ENABLED=on: no Luma API call is made. */
export function lumaEnabled(flag: string | undefined | null): boolean {
  return flag === "on";
}

/** Write gate: the org's switch AND the operator's flag. */
export function writesLive(orgEnabled: unknown, envFlag: string | undefined | null): boolean {
  return orgEnabled === true && envFlag === "on";
}

/**
 * An Io over fetch for one platform. GETs always go out (reads); POSTs go
 * out only when live and only to an allowed path; otherwise they are recorded
 * in `steps` and answered with `standIn(path)`.
 */
export function makeIo(opts: {
  fetch: typeof fetch;
  base: string;
  headers: Record<string, string>;
  live: boolean;
  allowed: RegExp[];
  steps: StepRecord[];
  standIn: (path: string, body: unknown) => any;
  timeoutMs?: number;
}): Io {
  return {
    live: opts.live,
    async req(method, path, body) {
      if (!path.startsWith("/") || path.includes("..") || path.includes("//")) return { ok: false, status: 0, body: null, error: "bad path" };
      if (method === "POST") {
        const p = path.split("?")[0];
        if (!opts.allowed.some((r) => r.test(p))) throw new Error(`channels: POST ${p} is not an allowed write`);
        if (!opts.live) {
          opts.steps.push({ op: "planned", method, path, body });
          return { ok: true, status: 200, body: opts.standIn(p, body) };
        }
      }
      const ctrl = new AbortController();
      const timer = setTimeout(() => ctrl.abort(), opts.timeoutMs ?? 15_000);
      try {
        const res = await opts.fetch(opts.base + path, {
          method,
          headers: { Accept: "application/json", ...(method === "POST" ? { "Content-Type": "application/json" } : {}), ...opts.headers },
          body: method === "POST" ? JSON.stringify(body ?? {}) : undefined,
          signal: ctrl.signal,
          redirect: "error",
        });
        const out = await res.json().catch(() => null);
        if (method === "POST") opts.steps.push({ op: "sent", method, path, body, ok: res.ok, ...(res.ok ? {} : { error: `HTTP_${res.status}` }) });
        if (!res.ok) {
          const code = typeof out?.error === "string" && /^[A-Z_]{2,64}$/.test(out.error) ? out.error
            : typeof out?.message === "string" ? out.message.slice(0, 120) : `HTTP_${res.status}`;
          return { ok: false, status: res.status, body: out, error: code };
        }
        return { ok: true, status: res.status, body: out };
      } catch (err) {
        return { ok: false, status: 0, body: null, error: (err as Error)?.name === "AbortError" ? "TIMEOUT" : "NETWORK" };
      } finally {
        clearTimeout(timer);
      }
    },
  };
}
