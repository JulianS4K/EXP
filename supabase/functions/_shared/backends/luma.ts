// Luma (luma.com), read only: the calendar's API key from Integrations
// (header x-luma-api-key; Luma Plus, one key per calendar), GET only.
// Guests -> one door row per guest. A Luma ticket's QR code is a link,
// https://luma.com/check-in/<evt-…>?pk=<g-…>; the pk (the guest key) is the
// code, and the door scanner already reads query values out of scanned links.
// API (public-api.luma.com/openapi.json): calendars/get, entities/lookup,
//      events/get, events/guests/list?event_id=…&pagination_cursor=…
//      Rate limit 200 requests / minute per calendar key.
import { type BackendRow, joinName } from "./rows.ts";

type Fetch = typeof fetch;

export const LUMA_API = "https://public-api.luma.com/v1";
export const LUMA_EVENT = /^evt-[A-Za-z0-9]{4,40}$/;

// approved / session admit; the rest are on the list but not admitted.
const VOID_REASON: Record<string, string> = {
  pending_approval: "pending approval",
  waitlist: "waitlist",
  invited: "invited, not registered",
  declined: "declined",
};

/** The pk out of a Luma check-in link (or a bare g- key). */
export function lumaKey(qr: unknown): string | null {
  if (typeof qr !== "string" || !qr.trim()) return null;
  const s = qr.trim();
  if (/^g-[A-Za-z0-9]{4,64}$/.test(s)) return s;
  try {
    const pk = new URL(s).searchParams.get("pk");
    return pk && /^[A-Za-z0-9_-]{4,64}$/.test(pk) ? pk : null;
  } catch {
    return null;
  }
}

/** One events/guests/list entry (the Guest schema) -> a door row. */
export function guestRow(g: any): BackendRow | null {
  const id = g?.id;
  if (typeof id !== "string" || !/^[A-Za-z0-9._-]{1,64}$/.test(id)) return null;
  const status = String(g.approval_status ?? "");
  const reason = status === "approved" || status === "session" ? undefined : (VOID_REASON[status] ?? "not approved");
  const tickets: any[] = Array.isArray(g.event_tickets) ? g.event_tickets : [];
  const type = tickets.map((t) => t?.name).find((n) => typeof n === "string" && n.trim());
  const ticket = typeof type === "string" ? `${type.trim().slice(0, 70)}${tickets.length > 1 ? ` ×${tickets.length}` : ""}` : null;
  return {
    ref: id,
    code: lumaKey(g.check_in_qr_code),
    name: joinName(g.user_name) ?? joinName(g.user_first_name, g.user_last_name),
    email: typeof g.user_email === "string" && g.user_email ? g.user_email : null,
    ticket,
    void: reason !== undefined,
    ...(reason !== undefined ? { reason } : {}),
  };
}

function headers(key: string): HeadersInit {
  return { "x-luma-api-key": key, Accept: "application/json" };
}

function refused(status: number): string | null {
  if (status === 401 || status === 403) return "Luma refused the API key (it needs Luma Plus, and it only covers its own calendar).";
  if (status === 429) return "Luma is rate limiting; it will retry.";
  return null;
}

/** Which calendar the key belongs to: GET calendars/get. */
export async function lumaWhoAmI(f: Fetch, key: string): Promise<{ ok: boolean; name?: string; error?: string }> {
  const r = await f(`${LUMA_API}/calendars/get`, { method: "GET", headers: headers(key), redirect: "manual" });
  if (!r.ok) return { ok: false, error: refused(r.status) ?? `Luma answered ${r.status}.` };
  const b = await r.json().catch(() => ({}));
  return { ok: true, name: typeof b?.name === "string" && b.name ? b.name.slice(0, 120) : "Luma calendar" };
}

/** The event (by evt- id, or by its public slug via entities/lookup), and
 *  only if this key's calendar manages it: the guest list needs manage access. */
export async function lumaEvent(f: Fetch, key: string, ref: string): Promise<{ ok: boolean; id?: string; name?: string; error?: string }> {
  let id = ref;
  if (!LUMA_EVENT.test(ref)) {
    const q = new URLSearchParams({ slug: ref });
    const r = await f(`${LUMA_API}/entities/lookup?${q}`, { method: "GET", headers: headers(key), redirect: "manual" });
    if (!r.ok) return { ok: false, error: refused(r.status) ?? `Luma answered ${r.status}.` };
    const b = await r.json().catch(() => ({}));
    const e = b?.entity;
    if (e?.type !== "event" || typeof e?.event?.id !== "string" || !LUMA_EVENT.test(e.event.id)) {
      return { ok: false, error: "Luma has no event at that link." };
    }
    id = e.event.id;
  }
  const r = await f(`${LUMA_API}/events/get?${new URLSearchParams({ event_id: id })}`, { method: "GET", headers: headers(key), redirect: "manual" });
  if (r.status === 404 || r.status === 400) return { ok: false, error: "Luma has no event with that id." };
  if (!r.ok) return { ok: false, error: refused(r.status) ?? `Luma answered ${r.status}.` };
  const b = await r.json().catch(() => ({}));
  if (b?.access !== "manage") return { ok: false, error: "That event isn't managed by this Luma calendar, so its guests can't be read." };
  return { ok: true, id, name: typeof b?.name === "string" && b.name ? b.name.slice(0, 200) : id };
}

export interface LumaPage { rows: BackendRow[]; next: string | null; status: number }

export async function lumaGuestsPage(f: Fetch, key: string, eventId: string, cursor: string | null): Promise<LumaPage> {
  // Oldest first, so pages stay stable while new guests register mid-pass.
  const q = new URLSearchParams({ event_id: eventId, pagination_limit: "100", sort_column: "created_at", sort_direction: "asc" });
  if (cursor) q.set("pagination_cursor", cursor);
  const r = await f(`${LUMA_API}/events/guests/list?${q}`, { method: "GET", headers: headers(key), redirect: "manual" });
  if (!r.ok) return { rows: [], next: null, status: r.status };
  const b = await r.json().catch(() => ({}));
  const entries = Array.isArray(b?.entries) ? b.entries : [];
  const next = b?.has_more === true && typeof b?.next_cursor === "string" && b.next_cursor ? b.next_cursor : null;
  return {
    rows: entries.map(guestRow).filter((x: BackendRow | null): x is BackendRow => x !== null),
    next,
    status: r.status,
  };
}
