// Eventbrite: the ONE write Exos makes (docs/marketplace/eventbrite/README.md
// "Inventory"; mig 20261014110000). Separate from client.ts, which stays GET
// only.
//
// What it can send: Update a Ticket Class
//   POST /events/{event_id}/ticket_classes/{ticket_class_id}/
//   {"ticket_class": {"capacity": N}}
// on a ticket class the organizer already has and mapped to an Exos ticket
// type. Nothing else: no events, no ticket classes created, no prices, no
// orders, no check-ins, no webhooks. sendCapacity refuses any other path or
// body.
//
// Dry run unless BOTH the org's switch (exos_eventbrite_accounts.writes_enabled,
// owner only) and the operator's EXOS_EVENTBRITE_WRITES=on are set
// (writesLive). A dry run only records the plan.
//
// Pure apart from the injected fetch, so vitest imports it.

import { EB_API, type EbResult, type Fetch, isEbId } from "./client.ts";

const TIMEOUT_MS = 15_000;
const WRITE_PATH = /^\/events\/[0-9]{1,24}\/ticket_classes\/[0-9]{1,24}\/$/;
const MAX_CAPACITY = 1_000_000;

export interface CapacityPlan {
  method: "POST";
  path: string;
  body: { ticket_class: { capacity: number } };
  /** For the organizer: what changes. */
  ticket_class_id: string;
  from: number | null;
  to: number;
}

/** The request that sets a class's capacity, or null when nothing changes. */
export function planCapacity(ebEventId: string, classId: string, from: number | null, to: number | null): CapacityPlan | null {
  if (!isEbId(ebEventId) || !isEbId(classId)) return null;
  // Eventbrite refuses 0 for a normal class (and reads it as unlimited for a
  // donation class), so 0 is never sent.
  if (to == null || !Number.isInteger(to) || to < 1 || to > MAX_CAPACITY) return null;
  if (from === to) return null;
  return {
    method: "POST",
    path: `/events/${ebEventId}/ticket_classes/${classId}/`,
    body: { ticket_class: { capacity: to } },
    ticket_class_id: classId,
    from,
    to,
  };
}

/** Sending is live only with the org's switch on AND the operator's flag. */
export function writesLive(orgEnabled: boolean, envFlag: string | undefined | null): boolean {
  return orgEnabled === true && envFlag === "on";
}

/** Throws unless the request is exactly the capacity update. */
export function assertCapacityOnly(plan: CapacityPlan): void {
  const keys = Object.keys(plan.body ?? {});
  const inner = Object.keys(plan.body?.ticket_class ?? {});
  if (plan.method !== "POST" || !WRITE_PATH.test(plan.path) || keys.length !== 1 || keys[0] !== "ticket_class"
      || inner.length !== 1 || inner[0] !== "capacity"
      || !Number.isInteger(plan.body.ticket_class.capacity) || plan.body.ticket_class.capacity < 1
      || plan.body.ticket_class.capacity > MAX_CAPACITY) {
    throw new Error("eventbrite writer: only a ticket class capacity update may be sent");
  }
}

/** Send the capacity update. Never throws for network errors (status 0). */
export async function sendCapacity(fetchImpl: Fetch, token: string, plan: CapacityPlan): Promise<EbResult<null>> {
  assertCapacityOnly(plan);
  const ctrl = new AbortController();
  const timer = setTimeout(() => ctrl.abort(), TIMEOUT_MS);
  try {
    const res = await fetchImpl(EB_API + plan.path, {
      method: "POST",
      headers: { Authorization: `Bearer ${token}`, Accept: "application/json", "Content-Type": "application/json" },
      body: JSON.stringify(plan.body),
      signal: ctrl.signal,
      redirect: "error",
    });
    const body = await res.json().catch(() => null);
    if (!res.ok) {
      const code = typeof body?.error === "string" && /^[A-Z_]{2,64}$/.test(body.error) ? body.error : `HTTP_${res.status}`;
      return { ok: false, status: res.status, body: null, error: code };
    }
    return { ok: true, status: res.status, body: null };
  } catch (err) {
    return { ok: false, status: 0, body: null, error: (err as Error)?.name === "AbortError" ? "TIMEOUT" : "NETWORK" };
  } finally {
    clearTimeout(timer);
  }
}

/** The plan as stored for the organizer (no token, nothing secret). */
export function planRecord(plan: CapacityPlan, live: boolean): Record<string, unknown> {
  return { dry_run: !live, method: plan.method, path: plan.path, body: plan.body, from: plan.from, to: plan.to };
}
