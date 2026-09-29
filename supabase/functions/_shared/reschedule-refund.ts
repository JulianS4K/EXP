// Optional refunds when the organizer changes an event's date
// (mig 20260929150000). Pure and import-free, so exos-refund (Deno), the SPA
// (EditEvent, ReschedulePanel, My Tickets, the /refund page) and vitest
// (src/lib/rescheduleRefunds.test.ts) share one copy of the rules. The SQL in
// the migration is the authority; these mirror it for the UI:
//
//   * qualifiesAsDateChange   = exos_reschedule_qualifies
//   * defaultRefundDeadline   = exos_reschedule_default_deadline
//   * rescheduleEligibility   = the reason chain of _exos_resched_ticket_state
//                               plus _exos_resched_actor_ok
//
// Who may ask for a refund: the person who paid (the money goes back to their
// card). A ticket someone was given can only be refunded by the original
// buyer, and the refund voids it either way. Free and comp tickets can be
// released (voided, no money) by their holder. Marketplace tickets are
// refunded by the marketplace.

const HOUR = 3_600_000;
const DAY = 24 * HOUR;

/** More than this much of a move (either way) qualifies even on the same day. */
export const QUALIFYING_SHIFT_MS = 3 * HOUR;
/** Default window: this long after the change... */
export const DEFAULT_WINDOW_MS = 14 * DAY;
/** ...but closing this long before the new start. */
export const DEADLINE_LEAD_MS = DAY;

/** The mail link's bearer token: 256 bits as hex. */
export const RESCHEDULE_TOKEN_RE = /^[0-9a-f]{64}$/;

function zone(tz: string | null | undefined): string {
  const z = (tz ?? "").trim() || "UTC";
  try {
    new Intl.DateTimeFormat("en-US", { timeZone: z });
    return z;
  } catch {
    return "UTC";
  }
}

/** YYYY-MM-DD of an instant in a time zone. */
export function localDay(d: Date, tz: string | null | undefined): string {
  const p: Record<string, string> = {};
  for (const x of new Intl.DateTimeFormat("en-US", {
    timeZone: zone(tz), year: "numeric", month: "2-digit", day: "2-digit",
  }).formatToParts(d)) p[x.type] = x.value;
  return `${p.year}-${p.month}-${p.day}`;
}

function toDate(v: Date | string | number | null | undefined): Date | null {
  if (v === null || v === undefined || v === "") return null;
  const d = v instanceof Date ? v : new Date(v);
  return Number.isNaN(d.getTime()) ? null : d;
}

/**
 * A date change that asks "Offer refunds?": the event moves to another day in
 * its own time zone, or its start moves by more than 3 hours.
 */
export function qualifiesAsDateChange(
  oldStart: Date | string | number | null | undefined,
  newStart: Date | string | number | null | undefined,
  tz: string | null | undefined,
): boolean {
  const a = toDate(oldStart);
  const b = toDate(newStart);
  if (!a || !b) return false;
  return localDay(a, tz) !== localDay(b, tz) || Math.abs(b.getTime() - a.getTime()) > QUALIFYING_SHIFT_MS;
}

/**
 * The earlier of (change + 14 days) and (new start − 24 h). When that leaves
 * no time (the new start is under a day away), until the new start; null when
 * the new start isn't in the future.
 */
export function defaultRefundDeadline(
  changedAt: Date | string | number,
  newStart: Date | string | number | null | undefined,
): Date | null {
  const c = toDate(changedAt);
  const n = toDate(newStart);
  if (!c || !n) return null;
  const d = Math.min(c.getTime() + DEFAULT_WINDOW_MS, n.getTime() - DEADLINE_LEAD_MS);
  if (d > c.getTime()) return new Date(d);
  if (n.getTime() > c.getTime()) return n;
  return null;
}

/** Why a deadline the organizer typed can't be used, or null when it can. */
export function deadlineProblem(deadline: Date | null, newStart: Date | null, now: Date = new Date()): string | null {
  if (!deadline || Number.isNaN(deadline.getTime())) return "Pick a refund deadline.";
  if (deadline.getTime() <= now.getTime()) return "The refund deadline has to be in the future.";
  if (newStart && deadline.getTime() > newStart.getTime()) return "The refund deadline can't be after the new start.";
  return null;
}

export type RescheduleKind = "refund" | "release" | "marketplace" | "none";

export type RescheduleReason =
  | "no-reschedule" | "refunds-not-offered" | "event-cancelled" | "deadline-passed"
  | "voided" | "checked-in" | "not-active" | "bought-after-change"
  | "marketplace" | "not-exos-paid" | "in-transfer" | "table"
  | "in-progress" | "refunded" | "no-card-payment"
  | "not-buyer" | "not-holder" | "not-authorized" | "not-refundable" | "paid-ticket" | "link-superseded";

/** Marketplace channels (exos_marketplace_orders.channel, plus TEvo). */
export const MARKETPLACE_CHANNELS = new Set([
  "gotickets", "gametime", "stubhub", "seatgeek", "vivid", "tickpick", "evo", "tevo", "automatiq",
]);

export interface RescheduleTicketFacts {
  /** The event's latest reschedule, if any. */
  reschedule: { createdAt: Date; refundsOffered: boolean; refundDeadline: Date | null } | null;
  eventCancelled: boolean;
  ticketStatus: "active" | "used" | "voided" | string;
  checkedIn: boolean;
  /** When the ticket's order was placed (session created_at, else the ticket's). */
  boughtAt: Date;
  channelSource: string;
  /** Paid through an Exos checkout with money on it (session amount > 0). */
  paidViaExos: boolean;
  pricePaid: number;
  isTable: boolean;
  /** In a transfer the holder started (not a platform parking for a claim). */
  inTransfer: boolean;
  /** A refund for this ticket + reschedule is already claimed / pending / done. */
  requestStatus?: "claimed" | "pending" | "succeeded" | "failed" | "canceled" | null;
  /** Money still refundable on the ticket (its share) and the order. */
  shareLeftCents?: number;
  orderLeftCents?: number;
  hasCardPayment?: boolean;
  /** Who is asking. */
  requesterIsPayer: boolean;
  requesterIsHolder: boolean;
}

export interface RescheduleEligibility {
  ok: boolean;
  kind: RescheduleKind;
  reason: RescheduleReason | null;
}

export function rescheduleKind(f: Pick<RescheduleTicketFacts, "channelSource" | "paidViaExos" | "pricePaid">): RescheduleKind {
  if (MARKETPLACE_CHANNELS.has(f.channelSource)) return "marketplace";
  if (f.paidViaExos) return "refund";
  if (f.channelSource === "comp" || !(f.pricePaid > 0)) return "release";
  return "none";
}

/** What a ticket can get after a date change, for the person asking, now. */
export function rescheduleEligibility(f: RescheduleTicketFacts, now: Date = new Date()): RescheduleEligibility {
  const kind = rescheduleKind(f);
  const no = (reason: RescheduleReason): RescheduleEligibility => ({ ok: false, kind, reason });
  const r = f.reschedule;
  if (!r) return no("no-reschedule");
  if (!r.refundsOffered) return no("refunds-not-offered");
  if (f.eventCancelled) return no("event-cancelled");
  if (!r.refundDeadline || now.getTime() >= r.refundDeadline.getTime()) return no("deadline-passed");
  if (f.ticketStatus === "voided") return no("voided");
  if (f.ticketStatus === "used" || f.checkedIn) return no("checked-in");
  if (f.ticketStatus !== "active") return no("not-active");
  if (f.boughtAt.getTime() > r.createdAt.getTime()) return no("bought-after-change");
  if (kind === "marketplace") return no("marketplace");
  if (kind === "none") return no("not-exos-paid");
  if (f.inTransfer) return no("in-transfer");
  if (kind === "release") {
    if (f.isTable) return no("table");
    return f.requesterIsHolder ? { ok: true, kind, reason: null } : no("not-holder");
  }
  if (f.requestStatus === "claimed" || f.requestStatus === "pending") return no("in-progress");
  if (f.requestStatus === "succeeded" || (f.shareLeftCents ?? 1) <= 0 || (f.orderLeftCents ?? 1) <= 0) return no("refunded");
  if (f.hasCardPayment === false) return no("no-card-payment");
  return f.requesterIsPayer ? { ok: true, kind, reason: null } : no("not-buyer");
}

/**
 * What one ticket's refund is: its share of the ticket part of the order, and
 * — only when no other ticket of the order has money left — everything still
 * refundable on the order (add-ons included). Mirrors the SQL.
 */
export function rescheduleRefundAmount(shareLeftCents: number, orderLeftCents: number, otherTicketsLeftCents: number): number {
  const share = Math.max(0, Math.round(shareLeftCents));
  const left = Math.max(0, Math.round(orderLeftCents));
  return otherTicketsLeftCents <= 0 ? left : Math.min(share, left);
}

const REASON_TEXT: Record<RescheduleReason, string> = {
  "no-reschedule": "This event's date hasn't changed.",
  "refunds-not-offered": "The organizer isn't offering refunds for this date change.",
  "event-cancelled": "The event was cancelled; the organizer handles refunds.",
  "deadline-passed": "The deadline to ask for a refund has passed.",
  "voided": "This ticket is no longer valid.",
  "checked-in": "This ticket was already used at the door.",
  "not-active": "This ticket can't be refunded right now.",
  "bought-after-change": "This ticket was bought after the date changed.",
  "marketplace": "You bought this ticket on a resale marketplace. Ask the marketplace for a refund.",
  "not-exos-paid": "This ticket wasn't paid on Exos. Ask the organizer.",
  "in-transfer": "This ticket is being transferred. Cancel the transfer first.",
  "table": "This ticket is part of a table. Ask the organizer.",
  "in-progress": "Your refund is on its way.",
  "refunded": "This ticket has already been refunded.",
  "no-card-payment": "We can't find the card payment for this order. Ask the organizer.",
  "not-buyer": "Someone else paid for this ticket. The refund goes back to their card, so only they can ask for it.",
  "not-holder": "Only the person holding this ticket can release it.",
  "not-authorized": "This ticket isn't yours to refund.",
  "not-refundable": "This ticket was free, so there's no money to refund. You can release it instead.",
  "paid-ticket": "This ticket was paid for. Ask for a refund instead.",
  "link-superseded": "The date changed again, so this link no longer works. Check your latest email.",
};

/** Plain-language reason for the buyer. */
export function reasonText(reason: string | null | undefined): string {
  return (reason && Object.prototype.hasOwnProperty.call(REASON_TEXT, reason))
    ? REASON_TEXT[reason as RescheduleReason]
    : "This ticket can't be refunded right now.";
}
