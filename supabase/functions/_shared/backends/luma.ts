// Luma (luma.com), read only: the calendar's API key from Integrations
// (header x-luma-api-key; Luma Plus, one key per calendar), GET only.
// Guests -> one door row per guest. A Luma ticket's QR code is a link,
// https://luma.com/check-in/<evt-…>?pk=<g-…>; the pk (the guest key) is the
// code, and the door scanner already reads query values out of scanned links.
// API: https://public-api.luma.com/v1  user/get-self, event/get,
//      event/get-guests?event_id=…&pagination_cursor=…  (docs.luma.com)
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

/** One get-guests entry (legacy {guest: {…}} or flat) -> a door row. */
export function guestRow(entry: any): BackendRow | null {
  const g = entry?.guest && typeof entry.guest === "object" ? entry.guest : entry;
  const id = g?.api_id ?? g?.id ?? entry?.api_id;
  if (typeof id !== "string" || !/^[A-Za-z0-9._-]{1,64}$/.test(id)) return null;
  const status = String(g.approval_status ?? "approved");
  const reason = status === "approved" || status === "session" ? undefined : (VOID_REASON[status] ?? "not approved");
  const tickets: any[] = Array.isArray(g.event_tickets) ? g.event_tickets : g.event_ticket ? [g.event_ticket] : [];
  const live = tickets.filter((t) => t && t.is_canceled !== true && t.cancelled !== true);
  const type = live.map((t) => t?.name ?? t?.ticket_type_name).find((n) => typeof n === "string" && n.trim());
  const ticket = typeof type === "string" ? `${type.trim().slice(0, 70)}${live.length > 1 ? ` ×${live.length}` : ""}` : null;
  const email = g.user_email ?? g.email;
  return {
    ref: id,
    code: lumaKey(g.check_in_qr_code) ?? lumaKey(g.guest_key ?? g.key),
    name: joinName(g.user_name ?? g.name) ?? joinName(g.user_first_name ?? g.first_name, g.user_last_name ?? g.last_name),
    email: typeof email === "string" && email ? email : null,
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

/** Whose key it is: GET user/get-self. */
export async function lumaWhoAmI(f: Fetch, key: string): Promise<{ ok: boolean; name?: string; error?: string }> {
  const r = await f(`${LUMA_API}/user/get-self`, { method: "GET", headers: headers(key), redirect: "manual" });
  if (!r.ok) return { ok: false, error: refused(r.status) ?? `Luma answered ${r.status}.` };
  const b = await r.json().catch(() => ({}));
  const u = b?.user ?? b;
  const name = [u?.name, u?.email].find((x) => typeof x === "string" && x);
  return { ok: true, name: typeof name === "string" ? name : "Luma calendar" };
}

/** The event's name: proves the id is on this key's calendar. */
export async function lumaEvent(f: Fetch, key: string, eventId: string): Promise<{ ok: boolean; name?: string; error?: string }> {
  if (!LUMA_EVENT.test(eventId)) return { ok: false, error: "A Luma event id starts with evt-." };
  const q = new URLSearchParams({ event_id: eventId, api_id: eventId });
  const r = await f(`${LUMA_API}/event/get?${q}`, { method: "GET", headers: headers(key), redirect: "manual" });
  if (r.status === 404 || r.status === 400) return { ok: false, error: "Luma has no event with that id on this calendar." };
  if (!r.ok) return { ok: false, error: refused(r.status) ?? `Luma answered ${r.status}.` };
  const b = await r.json().catch(() => ({}));
  const name = b?.event?.name ?? b?.name;
  return { ok: true, name: typeof name === "string" && name ? name.slice(0, 200) : eventId };
}

export interface LumaPage { rows: BackendRow[]; next: string | null; status: number }

export async function lumaGuestsPage(f: Fetch, key: string, eventId: string, cursor: string | null): Promise<LumaPage> {
  // event_api_id is the older name of the same parameter.
  const q = new URLSearchParams({ event_id: eventId, event_api_id: eventId, pagination_limit: "50" });
  if (cursor) q.set("pagination_cursor", cursor);
  const r = await f(`${LUMA_API}/event/get-guests?${q}`, { method: "GET", headers: headers(key), redirect: "manual" });
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
