// hi.events (hosted or self-hosted), read only: a check-in list's public
// attendee feed (the short id from its share link; no account password is
// stored). GET only. The QR code on a hi.events ticket is the attendee's
// public_id (unless the organizer switched on rotating QR codes, which
// Exos can't check: those guests are found by name at the door).
// API: /api/public/check-in-lists/{short_id}  and  …/attendees?page=…&per_page=…
import { type BackendRow, joinName } from "./rows.ts";

type Fetch = typeof fetch;

export function attendeeRow(a: any): BackendRow | null {
  if (!a || (typeof a.id !== "number" && typeof a.id !== "string")) return null;
  const status = String(a.status ?? "ACTIVE").toUpperCase();
  const isVoid = status !== "ACTIVE";
  return {
    ref: String(a.id),
    code: typeof a.public_id === "string" ? a.public_id : null,
    name: joinName(a.first_name, a.last_name),
    email: typeof a.email === "string" && a.email ? a.email : null,
    ticket: null,
    void: isVoid,
    ...(isVoid ? { reason: status === "CANCELLED" ? "cancelled" : "unpaid" } : {}),
  };
}

/** The check-in list's name and event: proves the link works. */
export async function hiEventsList(f: Fetch, base: string, shortId: string): Promise<{ ok: boolean; name?: string; error?: string }> {
  const r = await f(`${base}/api/public/check-in-lists/${encodeURIComponent(shortId)}`, { method: "GET", headers: { Accept: "application/json" }, redirect: "manual" });
  if (r.status === 404) return { ok: false, error: "hi.events doesn't know that check-in list." };
  if (r.status === 403) return { ok: false, error: "That check-in list has expired or isn't active yet." };
  if (!r.ok) return { ok: false, error: `hi.events answered ${r.status}.` };
  const b = await r.json().catch(() => ({}));
  const d = b?.data ?? b;
  const name = [d?.event?.title, d?.name].filter((x) => typeof x === "string" && x).join(" · ");
  return { ok: true, name: name || shortId };
}

export interface HiEventsPage { rows: BackendRow[]; next: boolean; status: number }

export async function hiEventsAttendeesPage(f: Fetch, base: string, shortId: string, page: number): Promise<HiEventsPage> {
  const q = new URLSearchParams({ page: String(page), per_page: "100" });
  const r = await f(`${base}/api/public/check-in-lists/${encodeURIComponent(shortId)}/attendees?${q}`,
    { method: "GET", headers: { Accept: "application/json" }, redirect: "manual" });
  if (!r.ok) return { rows: [], next: false, status: r.status };
  const b = await r.json().catch(() => ({}));
  const data = Array.isArray(b?.data) ? b.data : [];
  const meta = b?.meta ?? {};
  const last = Number(meta.last_page ?? meta.lastPage ?? page);
  return {
    rows: data.map(attendeeRow).filter((x: BackendRow | null): x is BackendRow => x !== null),
    next: Number.isFinite(last) && page < last,
    status: r.status,
  };
}
