// Organizer refunds (money back through Stripe), seller side: types and the
// pure amount math the refund panel uses. Server calls are in refundsApi.ts.
// The server re-checks every amount and the caller's role (owner / manager /
// finance, mig 20260926040000); the math here only shapes the form and mirrors
// the SQL (exos_refund_ticket_state / exos_refund_claim) so the preview and the
// result agree.

export interface RefundOrder {
  sessionId: string;
  buyerEmail: string | null;
  createdAt: Date;
  status: string;
  amountCents: number;
  refundedCents: number;
  refundableCents: number;
  tickets: number;
  activeTickets: number;
  openRequests: number;
  currency: string;
}

export interface RefundTicket {
  ticketId: string;
  status: string;
  shareCents: number;
  refundedCents: number;
  refundableCents: number;
  tierName: string | null;
  attendeeName: string | null;
}

export interface RefundRequestRow {
  id: string;
  amountCents: number;
  status: 'claimed' | 'pending' | 'succeeded' | 'failed' | 'canceled';
  scope: string;
  reason: string | null;
  createdAt: Date;
  error: string | null;
}

export interface RefundPreview {
  sessionId: string;
  status: string;
  currency: string;
  amountCents: number;
  refundedCents: number;
  refundableCents: number;
  hasPayment: boolean;
  tickets: RefundTicket[];
  requests: RefundRequestRow[];
}

// ---------------------------------------------------------------------------
// Pure math (mirrors exos_refund_ticket_state / exos_refund_claim)
// ---------------------------------------------------------------------------

/** Ticket part of an order: amount paid minus the add-on lines, never below 0. */
export function ticketPoolCents(
  amountCents: number,
  addons: Array<{ quantity?: number; unit_price_cents?: number }> | null | undefined,
): number {
  const addonCents = (addons ?? []).reduce(
    (sum, a) => sum + (Math.trunc(a.quantity ?? 0) || 0) * (Math.trunc(a.unit_price_cents ?? 0) || 0),
    0,
  );
  return Math.max(amountCents - addonCents, 0);
}

/** Split a pool evenly in cents; leftover cents go to the first tickets. */
export function ticketShares(poolCents: number, n: number): number[] {
  if (n <= 0) return [];
  const pool = Math.max(Math.trunc(poolCents), 0);
  const base = Math.floor(pool / n);
  const extra = pool % n;
  return Array.from({ length: n }, (_, i) => base + (i < extra ? 1 : 0));
}

/** "12.34" / "12" / "$12.3" -> 1234 / 1200 / 1230. null when not a positive amount with at most 2 decimals. */
export function parseAmountToCents(input: string): number | null {
  const s = input.trim().replace(/^\$/, '').replace(/,/g, '');
  if (!/^\d+(\.\d{1,2})?$/.test(s)) return null;
  const [whole, frac = ''] = s.split('.');
  const cents = Number(whole) * 100 + Number((frac + '00').slice(0, 2));
  return Number.isSafeInteger(cents) && cents > 0 ? cents : null;
}

export interface TicketSelection {
  ticketId: string;
  /** undefined = everything left on the ticket */
  amountCents?: number;
}

export type PlanResult =
  | { ok: true; totalCents: number; voids: string[]; items: TicketSelection[] }
  | { ok: false; error: string };

/**
 * Validate a per-ticket refund against the preview: each amount must be
 * positive and at most what's left on that ticket, and the total at most
 * what's left on the order. `voids` = tickets the refund covers in full
 * (those get voided once Stripe accepts it).
 */
export function planTicketRefund(preview: Pick<RefundPreview, 'refundableCents' | 'tickets'>, picks: TicketSelection[]): PlanResult {
  if (picks.length === 0) return { ok: false, error: 'Pick at least one ticket.' };
  const byId = new Map(preview.tickets.map((t) => [t.ticketId, t]));
  const seen = new Set<string>();
  let total = 0;
  const voids: string[] = [];
  for (const p of picks) {
    const t = byId.get(p.ticketId);
    if (!t) return { ok: false, error: 'That ticket is not on this order.' };
    if (seen.has(p.ticketId)) return { ok: false, error: 'A ticket is listed twice.' };
    seen.add(p.ticketId);
    const left = Math.max(t.shareCents - t.refundedCents, 0);
    const amt = p.amountCents ?? left;
    if (!Number.isInteger(amt) || amt <= 0) {
      return { ok: false, error: left <= 0 ? 'A picked ticket has nothing left to refund.' : 'Amounts must be above zero.' };
    }
    if (amt > left) return { ok: false, error: `That's more than the ${formatCents(left)} left on a ticket.` };
    if (amt === left) voids.push(p.ticketId);
    total += amt;
  }
  if (total > preview.refundableCents) {
    return { ok: false, error: `That's more than the ${formatCents(preview.refundableCents)} left on this order.` };
  }
  return { ok: true, totalCents: total, voids, items: picks };
}

/** Validate an order-level amount (not tied to tickets). */
export function planOrderAmount(refundableCents: number, amountCents: number | null): PlanResult {
  if (amountCents == null || amountCents <= 0) return { ok: false, error: 'Enter an amount above zero.' };
  if (amountCents > refundableCents) {
    return { ok: false, error: `That's more than the ${formatCents(refundableCents)} left on this order.` };
  }
  return { ok: true, totalCents: amountCents, voids: [], items: [] };
}

export function formatCents(cents: number, currency = 'USD'): string {
  const code = (currency || 'USD').toUpperCase();
  try {
    return new Intl.NumberFormat('en-US', { style: 'currency', currency: code }).format(cents / 100);
  } catch {
    return `${(cents / 100).toFixed(2)} ${code}`;
  }
}

/** One nonce per confirmed click; a retry of that click reuses it. */
export function newRefundNonce(): string {
  const c = (globalThis as { crypto?: { randomUUID?: () => string } }).crypto;
  const id = c?.randomUUID ? c.randomUUID() : `${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 12)}`;
  return `ui-${id}`;
}
