// pretix (pretix.eu or self-hosted), read only: the org's API token from
// Integrations (Token auth), GET only. Orders -> one row per position; the
// position's `secret` is what pretix prints in the QR code.
// API: /api/v1/organizers/{organizer}/events/{event}/orders/?modified_since=…&page=…
import { type BackendRow, joinName, SLUG } from "./rows.ts";

type Fetch = typeof fetch;

export interface PretixConfig { base: string; organizer: string; token: string }

/** pretix multilingual strings: {"en": "GA", "de": "…"} -> the first value. */
export function i18n(v: unknown): string | null {
  if (typeof v === "string") return v.trim() || null;
  if (v && typeof v === "object") {
    const o = v as Record<string, unknown>;
    const first = (o.en ?? Object.values(o)[0]) as unknown;
    return typeof first === "string" && first.trim() ? first.trim().slice(0, 80) : null;
  }
  return null;
}

/** Cursor "ms=<iso>|p=<page>" (either part optional). */
export function parseCursor(c: string | null | undefined): { since: string | null; page: number } {
  const out = { since: null as string | null, page: 1 };
  for (const part of String(c ?? "").split("|")) {
    const [k, v] = part.split("=");
    if (k === "ms" && v && !Number.isNaN(Date.parse(v))) out.since = v;
    if (k === "p" && /^[0-9]{1,6}$/.test(v ?? "")) out.page = Math.max(1, Number(v));
  }
  return out;
}

export function cursorString(since: string | null, page?: number): string {
  return [since ? `ms=${since}` : "", page && page > 1 ? `p=${page}` : ""].filter(Boolean).join("|");
}

/** pretix order JSON -> door rows. Unpaid (n), expired (e) and cancelled (c)
 *  orders, and cancelled positions, are voided; paid (p) admit. */
export function orderRows(order: any, items: Map<number, string>): BackendRow[] {
  if (!order || typeof order.code !== "string") return [];
  const status = String(order.status ?? "");
  const orderVoid = status !== "p";
  const reason = status === "c" ? "cancelled" : status === "e" ? "expired" : status === "n" ? "unpaid" : undefined;
  const positions = Array.isArray(order.positions) ? order.positions : [];
  return positions
    .filter((p: any) => p && (typeof p.positionid === "number" || typeof p.id === "number"))
    .map((p: any): BackendRow => {
      const cancelled = p.canceled === true;
      const name = joinName(p.attendee_name) ??
        (p.attendee_name_parts ? joinName(p.attendee_name_parts.given_name, p.attendee_name_parts.family_name) : null);
      return {
        ref: `${order.code}-${p.positionid ?? p.id}`,
        code: typeof p.secret === "string" ? p.secret : null,
        name,
        email: typeof p.attendee_email === "string" && p.attendee_email ? p.attendee_email : (typeof order.email === "string" ? order.email : null),
        ticket: items.get(Number(p.item)) ?? null,
        void: orderVoid || cancelled,
        ...(orderVoid || cancelled ? { reason: cancelled ? "cancelled" : reason } : {}),
      };
    });
}

function headers(token: string): HeadersInit {
  return { Authorization: `Token ${token}`, Accept: "application/json" };
}

function api(cfg: PretixConfig, path: string): string {
  return `${cfg.base}/api/v1/organizers/${encodeURIComponent(cfg.organizer)}${path}`;
}

/** Who the token belongs to: GET the organizer. */
export async function pretixWhoAmI(f: Fetch, cfg: PretixConfig): Promise<{ ok: boolean; name?: string; error?: string }> {
  if (!SLUG.test(cfg.organizer)) return { ok: false, error: "The organizer short name looks wrong." };
  const r = await f(api(cfg, "/"), { method: "GET", headers: headers(cfg.token), redirect: "manual" });
  if (r.status === 401 || r.status === 403) return { ok: false, error: "pretix refused the token." };
  if (!r.ok) return { ok: false, error: `pretix answered ${r.status}.` };
  const b = await r.json().catch(() => ({}));
  return { ok: true, name: i18n(b?.name) ?? cfg.organizer };
}

export async function pretixItems(f: Fetch, cfg: PretixConfig, event: string): Promise<Map<number, string>> {
  const out = new Map<number, string>();
  const r = await f(api(cfg, `/events/${encodeURIComponent(event)}/items/?page_size=200`), { method: "GET", headers: headers(cfg.token), redirect: "manual" });
  if (!r.ok) return out;
  const b = await r.json().catch(() => ({}));
  for (const it of Array.isArray(b?.results) ? b.results : []) {
    if (typeof it?.id === "number") out.set(it.id, i18n(it.name) ?? `Item ${it.id}`);
  }
  return out;
}

export interface PretixPage { rows: BackendRow[]; next: boolean; status: number }

export async function pretixOrdersPage(f: Fetch, cfg: PretixConfig, event: string, since: string | null, page: number,
                                       items: Map<number, string>): Promise<PretixPage> {
  const q = new URLSearchParams({ page: String(page), page_size: "50", ordering: "datetime" });
  if (since) q.set("modified_since", since);
  const r = await f(api(cfg, `/events/${encodeURIComponent(event)}/orders/?${q}`), { method: "GET", headers: headers(cfg.token), redirect: "manual" });
  if (!r.ok) return { rows: [], next: false, status: r.status };
  const b = await r.json().catch(() => ({}));
  const rows = (Array.isArray(b?.results) ? b.results : []).flatMap((o: unknown) => orderRows(o, items));
  return { rows, next: typeof b?.next === "string" && b.next.length > 0, status: r.status };
}
