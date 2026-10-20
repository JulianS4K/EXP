// My Tickets: which events go under Active (upcoming, something still to
// scan) and which under Archive (over, or every pass used / refunded / given
// away), in date order, and what counts as "active". Plus the poll that waits
// for a just-paid order to be minted (stripe-webhook runs a few seconds after
// Stripe sends the buyer back).

interface TsLike { toMillis?: () => number; toDate?: () => Date }
interface EventLike {
  date?: TsLike | null;
  timing?: { startTime?: TsLike | null; endTime?: TsLike | null } | null;
}
export interface TicketLike {
  id: string;
  status: string;
  pendingTransferId?: string | null;
  orderId?: string | null;
  event?: EventLike | null;
}

// No end time: an event counts as over this long after it starts.
const DEFAULT_LENGTH_MS = 12 * 60 * 60 * 1000;

const ms = (t?: TsLike | null): number | null => {
  if (!t) return null;
  const v = t.toMillis ? t.toMillis() : t.toDate ? t.toDate().getTime() : NaN;
  return Number.isFinite(v) && v > 0 ? v : null;
};

/** The event's start, for sorting (null: no date). */
export function eventStartMs(ev?: EventLike | null): number | null {
  return ms(ev?.date) ?? ms(ev?.timing?.startTime);
}

/** The event has ended (its end time, or start + 12 h, is past). */
export function eventIsOver(ev: EventLike | null | undefined, now: number): boolean {
  const end = ms(ev?.timing?.endTime);
  if (end != null) return end < now;
  const start = eventStartMs(ev);
  return start != null && start + DEFAULT_LENGTH_MS < now;
}

/** A pass still to use: active and not on its way to someone else. */
export function isActivePass(t: TicketLike): boolean {
  return t.status === 'active' && !t.pendingTransferId;
}

export function activePassCount(tickets: TicketLike[]): number {
  return tickets.filter(isActivePass).length;
}

/** Active: the event isn't over and at least one pass is still to use. */
export function isActiveGroup(tickets: TicketLike[], now: number): boolean {
  // A cancelled event stays here while its passes are live: that's where the
  // holder looks for it (and asks for a refund from the ticket).
  if (eventIsOver(tickets[0]?.event, now)) return false;
  return tickets.some((t) => t.status === 'active');
}

/** Split grouped tickets: upcoming first (soonest first), the archive newest first. */
export function splitTicketGroups<T extends TicketLike>(
  grouped: Record<string, T[]>,
  now: number,
): { active: [string, T[]][]; archive: [string, T[]][] } {
  const active: [string, T[]][] = [];
  const archive: [string, T[]][] = [];
  for (const entry of Object.entries(grouped)) {
    (isActiveGroup(entry[1], now) ? active : archive).push(entry);
  }
  const start = (e: [string, T[]]) => eventStartMs(e[1][0]?.event);
  active.sort((a, b) => (start(a) ?? Infinity) - (start(b) ?? Infinity));
  archive.sort((a, b) => (start(b) ?? -Infinity) - (start(a) ?? -Infinity));
  return { active, archive };
}

/** Back from Stripe: poll every 3 s for up to 60 s. */
export const ORDER_POLL_MS = 3000;
export const ORDER_POLL_LIMIT_MS = 60000;

/** The just-paid order has been minted: a ticket of that Checkout Session
 *  (order_ref = session id). With no session id to look for, any ticket will
 *  do on the first load (the webhook may already have run), else more
 *  tickets than that first load had. */
export function orderArrived(tickets: TicketLike[], sessionId: string | null, baseline: number | null): boolean {
  if (sessionId) return tickets.some((t) => t.orderId === sessionId);
  return baseline == null ? tickets.length > 0 : tickets.length > baseline;
}
