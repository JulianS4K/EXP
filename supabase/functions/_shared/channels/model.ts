// Channels (mig 20261019090000): the Exos event as the mirrors on Eventbrite
// and Luma should show it. Pure: no Deno or Node APIs beyond Web Crypto, so the
// Deno tests and the planners share it.
import { CHANNEL_RETRY, nextWait, realSleep, type RetryPolicy } from "../retry.ts";

export interface MirrorTier {
  id: string;
  name: string;
  description: string | null;
  priceCents: number;
  free: boolean;
  capacity: number;
  freeNow: number;
  hidden: boolean;
  /** The most this platform may be offered, given the other platform (mig 20261121100000); null = no cap sent. */
  shareCap: number | null;
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
  tickets?: MirrorTicket[];
}

/** A ticket type as mark records it: created (by Exos, this mirror) and the capacity it was created with. */
export interface MirrorTicket {
  tier_id: string;
  external_ticket_id: string;
  name: string;
  created?: boolean;
  capacity?: number;
}

/** A create a live pass is about to send (exos_channel_create_begin, mig 20261121100000). */
export interface PendingCreate {
  at?: string;
  first?: string;
  name?: string;
  start?: string;
  slug?: string;
  /** The venue a pass made for it (Eventbrite), reused by the next try. */
  venue_id?: string;
  venue_key?: string;
  tries?: number;
}

/**
 * What the details pass asks the database before it creates the event on a
 * platform: record the create (and get the marker back), so a pass that
 * timed out or lost its lease is looked up next time instead of repeated.
 */
export interface SyncHooks {
  beginCreate(marker: PendingCreate): Promise<{ ok: boolean; reason?: string; pending?: PendingCreate }>;
  /** Which of these external ids another Exos event already uses (any org); null when it couldn't be checked. */
  taken?(ids: string[]): Promise<string[] | null>;
  /** Keep a note with the pending create (the venue made for it); renews the lease. */
  note?(note: { venue_id: string; venue_key: string }): Promise<boolean>;
}

/** The pending create in a claimed mirror's external_meta, if any. */
export function pendingCreate(meta: unknown): PendingCreate | null {
  const p = (meta as Record<string, unknown> | null)?.pending_create;
  return p && typeof p === "object" && !Array.isArray(p) ? p as PendingCreate : null;
}

/** Why a create wasn't started, for the organizer. */
export function beginRefused(reason: string | undefined): string {
  if (reason === "in-flight") return "an earlier pass is still creating it; checking again shortly";
  if (reason === "has-external") return "it was created meanwhile";
  if (reason === "conflict") return "this event is already linked to another event there: unlink one of them, then save the channel again";
  return "the sync lost its turn; retrying";
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
      shareCap: Number.isInteger(t.share_cap) && t.share_cap >= 0 ? t.share_cap : null,
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

/**
 * The first capacity a new ticket type gets: what Exos has free less one
 * pack, no more than the other platform leaves it (shareCap, mig
 * 20261121100000), at least 1 (Eventbrite refuses 0).
 */
export function firstCapacity(t: MirrorTier, pack: number): number {
  return Math.max(1, Math.min(t.freeNow - pack, t.shareCap ?? Number.POSITIVE_INFINITY));
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
 * in `steps` and answered with `standIn(path)`. A GET that gets a 429, a 5xx
 * or a network failure is tried again (`retry`, _shared/retry.ts: Retry-After
 * honoured up to its limit). A POST is sent once: one that failed or timed
 * out may have happened, so the next pass looks it up instead of re-sending.
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
  retry?: RetryPolicy;
}): Io {
  const policy = opts.retry ?? CHANNEL_RETRY;
  const sleep = policy.sleep ?? realSleep;
  const once = async (method: "GET" | "POST", path: string, body: unknown) => {
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
      const retryAfter = res.headers?.get?.("retry-after") ?? null;
      const out = await res.json().catch(() => null);
      if (method === "POST") opts.steps.push({ op: "sent", method, path, body, ok: res.ok, ...(res.ok ? {} : { error: `HTTP_${res.status}` }) });
      if (!res.ok) {
        const code = typeof out?.error === "string" && /^[A-Z_]{2,64}$/.test(out.error) ? out.error
          : typeof out?.message === "string" ? out.message.slice(0, 120) : `HTTP_${res.status}`;
        return { r: { ok: false, status: res.status, body: out, error: code }, retryAfter };
      }
      return { r: { ok: true, status: res.status, body: out }, retryAfter: null };
    } catch (err) {
      const error = (err as Error)?.name === "AbortError" ? "TIMEOUT" : "NETWORK";
      if (method === "POST") opts.steps.push({ op: "sent", method, path, body, ok: false, error });
      return { r: { ok: false, status: 0, body: null, error }, retryAfter: null };
    } finally {
      clearTimeout(timer);
    }
  };
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
        return (await once("POST", path, body)).r;   // never retried
      }
      for (let attempt = 1; ; attempt++) {
        const { r, retryAfter } = await once("GET", path, undefined);
        const wait = r.ok ? null : nextWait(attempt, r.status, r.error, retryAfter, policy);
        if (wait === null) return r;
        await sleep(wait);
      }
    },
  };
}

/**
 * An Io whose live POSTs first renew the pass's lease (exos_channel_lease_renew,
 * mig 20261121100000), so a long pass is never taken over half-way; a lost
 * lease refuses the write (LEASE_LOST) instead of sending it. Reads and a
 * dry run's plan go through as they are.
 */
export function leasedIo(io: Io, renew: () => Promise<boolean>): Io {
  return {
    live: io.live,
    async req(method, path, body) {
      if (method === "POST" && io.live && !(await renew().catch(() => false))) {
        return { ok: false, status: 0, body: null, error: "LEASE_LOST" };
      }
      return io.req(method, path, body);
    },
  };
}
