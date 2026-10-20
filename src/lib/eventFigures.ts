// One vocabulary for an event's numbers. The report header, Money, the sales
// chart and Attendance each count something slightly different (valid
// tickets vs tickets in paid orders, face value vs what was charged vs what
// was kept), so every figure carries one of these labels and its hint, and
// "Tickets sold" means the same thing everywhere it appears. Pure.

export type FigureKey =
  | 'ticketsSold'
  | 'ticketSales'
  | 'paidTickets'
  | 'gross'
  | 'salesAfterRefunds'
  | 'yourNet'
  | 'organizerNet';

export const FIGURES: Record<FigureKey, { label: string; hint: string }> = {
  ticketsSold: {
    label: 'Tickets sold',
    hint: 'Valid tickets: paid, free and comps. Voided and refunded tickets don’t count.',
  },
  ticketSales: {
    label: 'Ticket sales',
    hint: 'What the valid tickets sold for, tax included; no add-ons, before fees.',
  },
  paidTickets: {
    label: 'Tickets in paid orders',
    hint: 'Exos checkouts only, including tickets refunded later; no free tickets or comps.',
  },
  gross: {
    label: 'Gross charged',
    hint: 'Everything buyers paid at checkout: tickets, add-ons and tax, before refunds.',
  },
  salesAfterRefunds: {
    label: 'Sales after refunds',
    hint: 'Ticket sales + add-ons − partial refunds, before Exos and card fees.',
  },
  yourNet: {
    label: 'Your net',
    hint: 'Gross − application fee (Exos fee + card-fee estimate), before refunds.',
  },
  organizerNet: {
    label: 'Organizer net',
    hint: 'What you keep, all channels: after refunds, fees and lost disputes.',
  },
};

/**
 * A ticket that counts as sold: anything not voided (a refund in full voids
 * the ticket). Same rule as exos_event_analytics (status <> 'voided').
 */
export function isSoldTicket(t: { status?: string | null }): boolean {
  return t.status !== 'voided' && t.status !== 'cancelled';
}

/** Header figures from the report's ticket list. */
export function ticketFigures(tickets: { status?: string | null; pricePaid?: number | null }[]): {
  sold: number;
  sales: number;
  checkedIn: number;
} {
  const sold = tickets.filter(isSoldTicket);
  return {
    sold: sold.length,
    sales: sold.reduce((s, t) => s + (t.pricePaid || 0), 0),
    checkedIn: sold.filter((t) => t.status === 'used').length,
  };
}

export interface DayBucket {
  /** Start of the day, viewer's timezone. */
  date: Date;
  daily: number;
  cumulative: number;
}

type DatedTicket = { status?: string | null; purchaseDate?: { toDate?: () => Date } | null };

/** Local midnight of `d`. */
const dayStart = (d: Date) => new Date(d.getFullYear(), d.getMonth(), d.getDate());

/**
 * Sold tickets per day over the last `days` days (viewer's timezone), with a
 * running total. Voided tickets are left out, so the chart's total is the
 * header's "Tickets sold" whenever every sale falls inside the window.
 */
export function salesByDay(tickets: DatedTicket[], days: number, now: Date = new Date()): DayBucket[] {
  const today = dayStart(now);
  const out: DayBucket[] = [];
  for (let i = days - 1; i >= 0; i--) {
    const d = new Date(today);
    d.setDate(today.getDate() - i);
    out.push({ date: d, daily: 0, cumulative: 0 });
  }
  for (const t of tickets) {
    if (!isSoldTicket(t)) continue;
    const pd = t.purchaseDate?.toDate?.();
    if (!pd) continue;
    // round: a DST day is 23 or 25 hours long
    const diff = Math.round((today.getTime() - dayStart(pd).getTime()) / 86_400_000);
    if (diff < 0 || diff >= days) continue;
    out[days - 1 - diff].daily += 1;
  }
  let running = 0;
  for (const b of out) {
    running += b.daily;
    b.cumulative = running;
  }
  return out;
}

/** Days an event's full history needs: back to its first sale, 30 to 365. */
export function historyDays(tickets: DatedTicket[], now: Date = new Date()): number {
  let first = Infinity;
  for (const t of tickets) {
    if (!isSoldTicket(t)) continue;
    const ms = t.purchaseDate?.toDate?.()?.getTime();
    if (ms !== undefined && ms < first) first = ms;
  }
  if (!Number.isFinite(first)) return 30;
  const span = Math.round((dayStart(now).getTime() - dayStart(new Date(first)).getTime()) / 86_400_000) + 1;
  return Math.min(365, Math.max(30, span));
}
