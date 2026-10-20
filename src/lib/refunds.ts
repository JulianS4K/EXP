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

/** One page of an event's paid orders (exos_event_refund_orders_page, mig 20261021120000). */
export interface RefundOrderPage {
  orders: RefundOrder[];
  /** Orders matching the search (all of them with no search). */
  matches: number;
  /** Every paid order of the event, and what's still refundable across them. */
  totalOrders: number;
  totalRefundableCents: number;
}

export const REFUND_PAGE_SIZE = 50;

/**
 * The same page cut client-side, for a database without the page RPC (the
 * old read returns the newest 500). Substring match on email or order id,
 * case-insensitive, like the server.
 */
export function pageRefundOrders(all: RefundOrder[], search: string, offset: number, limit = REFUND_PAGE_SIZE): RefundOrderPage {
  const q = search.trim().toLowerCase();
  const matched = q
    ? all.filter((o) => (o.buyerEmail ?? '').toLowerCase().includes(q) || o.sessionId.toLowerCase().includes(q))
    : all;
  const from = Math.max(0, Math.trunc(offset) || 0);
  return {
    orders: matched.slice(from, from + limit),
    matches: matched.length,
    totalOrders: all.length,
    totalRefundableCents: all.reduce((s, o) => s + o.refundableCents, 0),
  };
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

export type ParsedAmount = { ok: true; cents: number } | { ok: false; error: string };

const CURRENCY_SIGN = /^[$€£¥₹]\s*|\s*[$€£¥₹]$/g;

/**
 * Read a typed amount in either decimal style: "12.50" and "12,50" are both
 * 12.50; "1,234.56" and "1.234,56" are both 1234.56. With one kind of
 * separator used once, 1-2 digits after it make it the decimal mark; exactly 3
 * ("1,234" / "1.234") could be either, so it's refused rather than guessed.
 * Thousands may also be grouped with a space or "'". A currency sign or the
 * order's currency code ("€", "EUR") at either end is ignored.
 */
export function parseAmount(input: string, currency?: string): ParsedAmount {
  const bad: ParsedAmount = { ok: false, error: 'Enter an amount like 12.50.' };
  let s = input.trim().replace(/[\s  ]+/g, ' ').replace(CURRENCY_SIGN, '');
  const code = (currency || '').trim();
  if (/^[a-z]{3}$/i.test(code)) s = s.replace(new RegExp(`^${code}\\s*|\\s*${code}$`, 'gi'), '');
  s = s.replace(CURRENCY_SIGN, '').trim();
  if (!/^\d[\d.,' ]*$/.test(s)) return bad;

  let whole = s;
  let frac = '';
  const last = Math.max(s.lastIndexOf('.'), s.lastIndexOf(','));
  if (last >= 0) {
    const mark = s[last];
    const other = mark === '.' ? ',' : '.';
    const tail = s.slice(last + 1);
    const once = s.indexOf(mark) === last;
    if (s.includes(other)) {
      // Both kinds: the last one is the decimal mark, the other groups thousands.
      if (!once || !/^\d{1,2}$/.test(tail)) return bad;
      whole = s.slice(0, last);
      frac = tail;
    } else if (once && /^\d{1,2}$/.test(tail)) {
      whole = s.slice(0, last);
      frac = tail;
    } else if (once && /^\d{3}$/.test(tail)) {
      return { ok: false, error: `"${s}" is ambiguous: type ${s.slice(0, last)}${tail} without the separator, or use 2 decimals.` };
    }
    // Otherwise the same mark repeats ("1,234,567"), so it only groups thousands.
  }
  // One grouping mark, between groups of exactly three digits.
  if (!/^\d+$/.test(whole) && !/^\d{1,3}(?:([.,' ])\d{3})(?:\1\d{3})*$/.test(whole)) return bad;
  const cents = Number(whole.replace(/\D/g, '')) * 100 + Number((frac + '00').slice(0, 2));
  if (!Number.isSafeInteger(cents)) return bad;
  if (cents <= 0) return { ok: false, error: 'Enter an amount above zero.' };
  return { ok: true, cents };
}

/** parseAmount as cents; null when it isn't a clear positive amount. */
export function parseAmountToCents(input: string, currency?: string): number | null {
  const r = parseAmount(input, currency);
  return r.ok ? r.cents : null;
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
export function planTicketRefund(
  preview: Pick<RefundPreview, 'refundableCents' | 'tickets'> & { currency?: string },
  picks: TicketSelection[],
): PlanResult {
  const cur = preview.currency;
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
    if (amt > left) return { ok: false, error: `That's more than the ${formatCents(left, cur)} left on a ticket.` };
    if (amt === left) voids.push(p.ticketId);
    total += amt;
  }
  if (total > preview.refundableCents) {
    return { ok: false, error: `That's more than the ${formatCents(preview.refundableCents, cur)} left on this order.` };
  }
  return { ok: true, totalCents: total, voids, items: picks };
}

/** Validate an order-level amount (not tied to tickets). */
export function planOrderAmount(refundableCents: number, amountCents: number | null, currency?: string): PlanResult {
  if (amountCents == null || amountCents <= 0) return { ok: false, error: 'Enter an amount above zero.' };
  if (amountCents > refundableCents) {
    return { ok: false, error: `That's more than the ${formatCents(refundableCents, currency)} left on this order.` };
  }
  return { ok: true, totalCents: amountCents, voids: [], items: [] };
}

export type TicketBadge = 'active' | 'used' | 'released' | 'refunded' | 'voided';

/** Event-report status badge. A void alone is not a refund: "refunded" only
 *  when a succeeded refund covers the ticket (listRefundedTicketIds). */
export function ticketBadge(t: { status: string; releasedAt?: unknown }, refunded: boolean): TicketBadge {
  if (t.status === 'voided') return t.releasedAt ? 'released' : refunded ? 'refunded' : 'voided';
  if (t.status === 'used') return 'used';
  return 'active';
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
