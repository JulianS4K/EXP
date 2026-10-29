// Eventbrite, read only: the half of exos-eventbrite-sync that talks to
// Eventbrite's API v3 (docs/marketplace/eventbrite.md; mig 20261013100000).
// No Deno or Node APIs beyond fetch (injected), so vitest imports it too
// (src/lib/eventbrite.test.ts).
//
// READ ONLY BY CONSTRUCTION (CLAUDE.md: upstream ticketing APIs are
// read-only). Every request goes through ebGet, which only sends GET to
// www.eventbriteapi.com; assertReadonlyMethod throws on anything else. No
// check-in write-back, no webhook registration, no orders.
//
// The token is the organizer's private token or OAuth token (the same
// thing to the API; mig 20261029140000), sent only in the Authorization
// header (never in a URL, never logged). Error text is Eventbrite's error
// code, never a response body.

export const EB_API = "https://www.eventbriteapi.com/v3";
export const ALLOWED_HTTP_METHODS: ReadonlySet<string> = new Set(["GET"]);
const TIMEOUT_MS = 15_000;
/** Re-read this much before the cursor: clock skew between us and Eventbrite. */
export const CURSOR_OVERLAP_MS = 2 * 60_000;

export function assertReadonlyMethod(method: string): void {
  if (!ALLOWED_HTTP_METHODS.has(method.toUpperCase())) {
    throw new Error(`eventbrite: ${method} is not allowed (read-only client)`);
  }
}

export type Fetch = (input: string, init?: RequestInit) => Promise<Response>;

export interface EbResult<T> {
  ok: boolean;
  status: number;
  body: T | null;
  /** Eventbrite's error code (e.g. INVALID_AUTH, BAD_CONTINUATION_TOKEN), or ours. */
  error?: string;
}

/** A private token's shape (the SQL checks the same). */
export function isTokenShaped(t: unknown): t is string {
  return typeof t === "string" && /^[A-Za-z0-9_-]{8,255}$/.test(t);
}

export function isEbId(v: unknown): v is string {
  return typeof v === "string" && /^[0-9]{1,24}$/.test(v);
}

/** GET {EB_API}{path}?{params}. Never throws: network errors come back as status 0. */
export async function ebGet<T>(
  fetchImpl: Fetch, token: string, path: string, params: Record<string, string | undefined> = {},
): Promise<EbResult<T>> {
  assertReadonlyMethod("GET");
  if (!path.startsWith("/") || path.includes("..") || path.includes("//")) {
    return { ok: false, status: 0, body: null, error: "bad path" };
  }
  const url = new URL(EB_API + path);
  for (const [k, v] of Object.entries(params)) if (v !== undefined && v !== "") url.searchParams.set(k, v);
  const ctrl = new AbortController();
  const timer = setTimeout(() => ctrl.abort(), TIMEOUT_MS);
  try {
    const res = await fetchImpl(url.toString(), {
      method: "GET",
      headers: { Authorization: `Bearer ${token}`, Accept: "application/json" },
      signal: ctrl.signal,
      redirect: "error",
    });
    const body = await res.json().catch(() => null);
    if (!res.ok) {
      const code = typeof body?.error === "string" && /^[A-Z_]{2,64}$/.test(body.error) ? body.error : `HTTP_${res.status}`;
      return { ok: false, status: res.status, body: null, error: code };
    }
    return { ok: true, status: res.status, body: body as T };
  } catch (err) {
    return { ok: false, status: 0, body: null, error: (err as Error)?.name === "AbortError" ? "TIMEOUT" : "NETWORK" };
  } finally {
    clearTimeout(timer);
  }
}

/** What the organizer sees when a request fails. */
export function ebErrorMessage(r: { status: number; error?: string }): string {
  if (r.status === 401 || r.error === "INVALID_AUTH" || r.error === "NO_AUTH") {
    return "Eventbrite rejected the token. Disconnect and connect Eventbrite again.";
  }
  if (r.status === 403 || r.error === "NOT_AUTHORIZED") return "This Eventbrite account can't read that event's attendees.";
  if (r.status === 404 || r.error === "NOT_FOUND") return "Eventbrite has no such event for this account.";
  if (r.status === 429 || r.error === "HIT_RATE_LIMIT") return "Eventbrite rate limit reached; the next sync will retry.";
  if (r.error === "TIMEOUT" || r.error === "NETWORK" || r.status >= 500) return "Eventbrite didn't answer; the next sync will retry.";
  return `Eventbrite error ${r.error ?? r.status}.`;
}

// ---- Shapes (only the fields we read) --------------------------------------

export interface EbPagination { has_more_items?: boolean; continuation?: string | null }
export interface EbBarcode {
  barcode?: string | null;
  status?: string;
  /** 0 not validated, 1 by scanner, 2 by name. */
  checkin_type?: number;
  changed?: string;
}
export interface EbAttendee {
  id?: string;
  status?: string;
  cancelled?: boolean;
  refunded?: boolean;
  checked_in?: boolean;
  changed?: string;
  ticket_class_name?: string;
  profile?: { name?: string; first_name?: string; last_name?: string; email?: string };
  barcodes?: EbBarcode[];
}
export interface EbEvent {
  id?: string;
  name?: { text?: string };
  start?: { utc?: string };
  status?: string;
}

/** One barcode as Eventbrite has it (stored apart from Exos codes). */
export interface ApplyBarcode {
  code: string;
  status: 'unused' | 'used' | 'refunded';
  checkin_type?: 0 | 1 | 2;
  changed?: string;
}

/** One row for exos_eventbrite_apply. */
export interface ApplyRow {
  ref: string;
  code?: string;
  name?: string;
  email?: string;
  ticket?: string;
  void: boolean;
  reason?: string;
  /** What Eventbrite says (mig 20261014120000): read only, never written back. */
  checked_in: boolean;
  status?: string;
  refunded?: true;
  cancelled?: true;
  changed?: string;
  barcodes?: ApplyBarcode[];
}

const BARCODE_STATUS = new Set(['unused', 'used', 'refunded']);

const VOID_STATUS: Record<string, string> = {
  "not attending": "not attending",
  deleted: "deleted",
  cancelled: "cancelled",
  canceled: "cancelled",
  refunded: "refunded",
  transferred: "transferred",
};

/**
 * An attendee as a door row. Voided when Eventbrite says refunded, cancelled,
 * not attending, deleted or transferred, or when every barcode is refunded.
 * The barcode is the first one that isn't refunded (else the first). It also
 * carries what Eventbrite says about check-in (their flag, or a used barcode)
 * and every barcode with Eventbrite's status, for exos_eventbrite_barcodes
 * (mig 20261014120000). NULL when the attendee has no usable id.
 */
export function toApplyRow(a: EbAttendee): ApplyRow | null {
  if (!a || !isEbId(a.id)) return null;
  const codes = (a.barcodes ?? []).filter((b) => typeof b?.barcode === "string" && b.barcode.trim() !== "");
  const live = codes.find((b) => b.status !== "refunded") ?? codes[0];
  const status = (a.status ?? "").trim().toLowerCase();
  let reason: string | undefined;
  if (a.refunded) reason = "refunded";
  else if (a.cancelled) reason = "cancelled";
  else if (VOID_STATUS[status]) reason = VOID_STATUS[status];
  else if (codes.length > 0 && codes.every((b) => b.status === "refunded")) reason = "refunded";
  const p = a.profile ?? {};
  const name = (p.name ?? [p.first_name, p.last_name].filter(Boolean).join(" ")).trim();
  const row: ApplyRow = {
    ref: a.id,
    void: reason !== undefined,
    // Checked in on Eventbrite: their flag, or a used barcode.
    checked_in: a.checked_in === true || codes.some((b) => b.status === 'used'),
  };
  if (live?.barcode) row.code = live.barcode.trim();
  if (name) row.name = name.slice(0, 80);
  if (p.email) row.email = p.email.trim();
  if (a.ticket_class_name) row.ticket = a.ticket_class_name.trim().slice(0, 80);
  if (reason) row.reason = reason;
  if (a.status && a.status.trim()) row.status = a.status.trim().slice(0, 40);
  if (a.refunded === true) row.refunded = true;
  if (a.cancelled === true) row.cancelled = true;
  if (typeof a.changed === 'string' && a.changed) row.changed = a.changed;
  const barcodes: ApplyBarcode[] = [];
  for (const b of codes.slice(0, 20)) {
    const status = (b.status ?? '').toLowerCase();
    if (!BARCODE_STATUS.has(status)) continue;
    const out: ApplyBarcode = { code: b.barcode!.trim(), status: status as ApplyBarcode['status'] };
    if (b.checkin_type === 0 || b.checkin_type === 1 || b.checkin_type === 2) out.checkin_type = b.checkin_type;
    if (typeof b.changed === 'string' && b.changed) out.changed = b.changed;
    barcodes.push(out);
  }
  if (barcodes.length > 0) row.barcodes = barcodes;
  return row;
}

/** changed_since for a cursor: the overlap back, in Eventbrite's format (no ms). */
export function changedSince(cursor: string | null | undefined): string | undefined {
  if (!cursor) return undefined;
  const t = Date.parse(cursor);
  if (!Number.isFinite(t)) return undefined;
  return new Date(t - CURSOR_OVERLAP_MS).toISOString().replace(/\.\d{3}Z$/, "Z");
}

// ---- Calls -----------------------------------------------------------------

/** The token's account name (GET /users/me/). */
export async function whoAmI(fetchImpl: Fetch, token: string): Promise<EbResult<{ name: string }>> {
  const r = await ebGet<{ name?: string; emails?: Array<{ email?: string }> }>(fetchImpl, token, "/users/me/");
  if (!r.ok) return { ...r, body: null };
  const name = (r.body?.name || r.body?.emails?.[0]?.email || "Eventbrite account").slice(0, 120);
  return { ok: true, status: r.status, body: { name } };
}

/** One event the token can read (GET /events/{id}/). */
export async function readEvent(fetchImpl: Fetch, token: string, id: string): Promise<EbResult<EventChoice>> {
  if (!isEbId(id)) return { ok: false, status: 400, body: null, error: "bad event id" };
  const r = await ebGet<EbEvent>(fetchImpl, token, `/events/${id}/`);
  if (!r.ok || !r.body) return { ...r, body: null };
  const c = toChoice(r.body);
  return c ? { ok: true, status: r.status, body: c } : { ok: false, status: 502, body: null, error: "bad event" };
}

export interface EventChoice { id: string; name: string; start: string | null; status: string | null }

function toChoice(e: EbEvent): EventChoice | null {
  if (!isEbId(e?.id)) return null;
  return {
    id: e.id,
    name: (e.name?.text ?? "").trim().slice(0, 200) || `Event ${e.id}`,
    start: e.start?.utc ?? null,
    status: e.status ?? null,
  };
}

/**
 * The account's current and future events, across its organizations
 * (GET /users/me/organizations/, then GET /organizations/{id}/events/), at
 * most 5 organizations and 4 pages each. Sorted by start.
 */
export async function listUpcomingEvents(fetchImpl: Fetch, token: string): Promise<EbResult<EventChoice[]>> {
  const orgs = await ebGet<{ organizations?: Array<{ id?: string }> }>(fetchImpl, token, "/users/me/organizations/");
  if (!orgs.ok) return { ...orgs, body: null };
  const out: EventChoice[] = [];
  for (const o of (orgs.body?.organizations ?? []).slice(0, 5)) {
    if (!isEbId(o?.id)) continue;
    let continuation: string | undefined;
    for (let page = 0; page < 4; page++) {
      const r = await ebGet<{ events?: EbEvent[]; pagination?: EbPagination }>(
        fetchImpl, token, `/organizations/${o.id}/events/`,
        { status: "live,started,draft", time_filter: "current_future", order_by: "start_asc", continuation },
      );
      if (!r.ok) return { ...r, body: null };
      for (const e of r.body?.events ?? []) {
        const c = toChoice(e);
        if (c) out.push(c);
      }
      if (!r.body?.pagination?.has_more_items || !r.body.pagination.continuation) break;
      continuation = r.body.pagination.continuation;
    }
  }
  out.sort((a, b) => (a.start ?? "").localeCompare(b.start ?? ""));
  return { ok: true, status: 200, body: out };
}

// ---- Ticket classes (for the inventory sync, mig 20261014110000) -----------

/** The fields exos_eventbrite_inventory_apply reads. */
export interface EbTicketClass {
  id: string;
  name: string | null;
  capacity: number | null;
  quantity_sold: number | null;
  inventory_tier_id: string | null;
  free: boolean;
  hidden: boolean;
  donation: boolean;
  /** admission, add_on or donation (admission when Eventbrite doesn't say). */
  category: string;
}

/** Why a class can't share a count with Exos, or null. */
export function unshareableReason(c: EbTicketClass): string | null {
  if (c.inventory_tier_id) return "It is in an Eventbrite inventory tier (not supported yet).";
  if (c.donation || c.category === "donation") return "Donation tickets can't share a count.";
  if (c.category === "add_on") return "Add-ons don't count toward the event, so they can't share a count.";
  return null;
}

function toTicketClass(t: Record<string, unknown> | null | undefined): EbTicketClass | null {
  if (!t || !isEbId(t.id)) return null;
  const num = (v: unknown) => (typeof v === "number" && Number.isInteger(v) && v >= 0 ? v : null);
  const tier = t.inventory_tier_id;
  return {
    id: t.id as string,
    name: typeof t.name === "string" ? t.name.slice(0, 200) : null,
    capacity: num(t.capacity ?? t.quantity_total),
    quantity_sold: num(t.quantity_sold),
    inventory_tier_id: typeof tier === "string" && tier !== "" ? tier : typeof tier === "number" ? String(tier) : null,
    free: t.free === true,
    hidden: t.hidden === true,
    donation: t.donation === true,
    category: typeof t.category === "string" && /^[a-z_]{1,20}$/.test(t.category) ? t.category : "admission",
  };
}

/** An Eventbrite event's ticket classes (GET /events/{id}/ticket_classes/), at most 10 pages. */
export async function listTicketClasses(fetchImpl: Fetch, token: string, ebEventId: string): Promise<EbResult<EbTicketClass[]>> {
  if (!isEbId(ebEventId)) return { ok: false, status: 0, body: null, error: "bad event id" };
  const out: EbTicketClass[] = [];
  let continuation: string | undefined;
  for (let page = 0; page < 10; page++) {
    const r = await ebGet<{ ticket_classes?: Array<Record<string, unknown>>; pagination?: EbPagination }>(
      fetchImpl, token, `/events/${ebEventId}/ticket_classes/`, { continuation },
    );
    if (!r.ok) return { ...r, body: null };
    for (const t of r.body?.ticket_classes ?? []) {
      const c = toTicketClass(t);
      if (c) out.push(c);
    }
    if (!r.body?.pagination?.has_more_items || !r.body.pagination.continuation) break;
    continuation = r.body.pagination.continuation;
  }
  return { ok: true, status: 200, body: out };
}

// ---- One sync run for one link ---------------------------------------------

export interface ClaimedLink {
  event_id: string;
  eb_event_id: string;
  token: string;
  sync_cursor: string | null;
  continuation: string | null;
  /** The claim's lease id; every apply presents it (a stale run writes nothing). */
  lease_id: string;
}

export type ApplyState = "more" | "pause" | "done" | "error";
export type ApplyFn = (rows: ApplyRow[], state: ApplyState, continuation: string | null,
  error: string | null) => Promise<{ ok: boolean; reason?: string; added?: number; voided?: number; restored?: number } | null>;

export interface SyncOutcome {
  state: "done" | "more" | "error";
  pages: number;
  rows: number;
  added: number;
  voided: number;
  restored: number;
  error?: string;
}

/**
 * Page through GET /events/{id}/attendees/?changed_since=… from where the
 * link left off, handing each page to apply. Stops at maxPages or the
 * deadline with state 'more' (applied as 'pause': the continuation is
 * saved and the next run resumes). A bad continuation token restarts the pass next run; any other
 * Eventbrite error is recorded and keeps the cursor.
 */
export async function syncLink(
  fetchImpl: Fetch, link: ClaimedLink, apply: ApplyFn,
  opts: { maxPages: number; deadline: number; now?: () => number },
): Promise<SyncOutcome> {
  const now = opts.now ?? Date.now;
  const out: SyncOutcome = { state: "more", pages: 0, rows: 0, added: 0, voided: 0, restored: 0 };
  const since = changedSince(link.sync_cursor);
  let continuation = link.continuation ?? undefined;

  while (true) {
    const r = await ebGet<{ attendees?: EbAttendee[]; pagination?: EbPagination }>(
      fetchImpl, link.token, `/events/${link.eb_event_id}/attendees/`,
      { changed_since: since, continuation },
    );
    if (!r.ok) {
      out.state = "error";
      out.error = r.error === "BAD_CONTINUATION_TOKEN" ? "Restarting the sync (Eventbrite page expired)." : ebErrorMessage(r);
      // A bad continuation: drop it so the next pass starts over from the cursor.
      await apply([], "error", r.error === "BAD_CONTINUATION_TOKEN" ? null : continuation ?? null, out.error);
      return out;
    }
    const rows = (r.body?.attendees ?? []).map(toApplyRow).filter((x): x is ApplyRow => x !== null);
    const more = r.body?.pagination?.has_more_items === true && !!r.body.pagination.continuation;
    out.pages += 1;
    out.rows += rows.length;
    const next = more ? r.body!.pagination!.continuation! : null;
    // Stopping with pages left: 'pause' saves where to resume and frees the link.
    const stop = more && (out.pages >= opts.maxPages || now() >= opts.deadline);
    const res = await apply(rows, more ? (stop ? "pause" : "more") : "done", next, null);
    if (!res?.ok) {
      out.state = "error";
      if (res?.reason === "lease-lost") {
        // Relinked, reconnected or taken over by another run: stop, write nothing.
        out.error = "The link changed during the sync.";
        return out;
      }
      out.error = "Exos couldn't save the attendees; retrying.";
      // Keep the continuation this page was fetched WITH, so it is read again.
      await apply([], "error", continuation ?? null, out.error);
      return out;
    }
    out.added += res.added ?? 0;
    out.voided += res.voided ?? 0;
    out.restored += res.restored ?? 0;
    if (!more) {
      out.state = "done";
      return out;
    }
    if (stop) return out;
    continuation = next!;
  }
}
