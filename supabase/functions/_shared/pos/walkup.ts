// Venue POS: walk-up ticket sales at the door (mig 20261107100000,
// docs/pos.md "Walk-up sales"). PURE, integer cents, so the exos-pos edge
// function (Deno) and the door app (src/lib/pos, vitest) share one copy.
//
// The database is the authority (exos_pos_walkup_sell prices, reserves and
// mints); these mirror its rules so the Sell tab can show the total, the
// change and what a sale still allows before it asks:
//   price    the door channel's unit price (door_price_cents, else the
//            current step) with the ticket type's tax, per unit like checkout
//            (lineTotals, the same math as the SQL line trigger)
//   tenders  comps cover whole tickets (comp quantity x the unit total); cash
//            is the rest. A card pays the whole sale on a Stripe Terminal
//            reader (mig 20261107130000; no comps in a card sale).
//   void     same night (12 hours) and before any scan: the seller or an
//            owner / manager. After that: a refund, owner / manager; after a
//            scan only with their override.

import { lineTotals, type PosTaxRule } from './totals.ts';

/** How long after the sale a void is allowed ("same night"). Same as the SQL. */
export const WALKUP_VOID_WINDOW_HOURS = 12;

/** The answer to a card tender at the door while card at the door is off (EXOS_POS_CARD) or has no reader. */
export const WALKUP_CARD_MESSAGE = "Card at the door isn't connected yet: take cash, or comp it.";

// Card at the door (mig 20261107130000): the Sell tab polls the sale while the
// guest is at the reader. The reservation is 5 minutes; stop asking a little
// after it (the server cancels anything the reader didn't finish).
export const CARD_POLL_MS = 2000;
export const CARD_POLL_GIVE_UP_MS = 6 * 60_000;

export type CardSaleState = 'starting' | 'waiting' | 'succeeded' | 'declined' | 'canceled' | 'refunded';

/** What the door screen says while a card sale is under way, and after. */
export function cardStateText(state: CardSaleState, declineCode?: string | null): string {
  switch (state) {
    case 'starting': return 'Sending to the reader…';
    case 'waiting': return 'Tap, insert or swipe on the reader.';
    case 'succeeded': return 'Paid.';
    case 'refunded': return "The card was charged but the tickets couldn't be issued: it was refunded in full.";
    case 'canceled': return 'Cancelled: nothing was charged.';
    case 'declined': return declineCode ? `Declined (${declineCode.replace(/_/g, ' ')}): nothing was charged.` : 'Declined: nothing was charged.';
  }
}

/** A finished card sale (stop polling). */
export function cardStateDone(state: CardSaleState): boolean {
  return state === 'succeeded' || state === 'declined' || state === 'canceled' || state === 'refunded';
}

export type WalkupTender = 'cash' | 'comp' | 'card';

export interface WalkupQuoteInput {
  /** The door channel's unit price, before exclusive tax. */
  unitCents: number;
  tax?: PosTaxRule | null;
  quantity: number;
  /** Tickets comped (0..quantity). */
  compQuantity?: number;
}

export interface WalkupQuote {
  /** What one ticket costs the guest (tax in). */
  unitTotalCents: number;
  totalCents: number;
  taxCents: number;
  compCents: number;
  cashDueCents: number;
}

/** 2 GA at $25 + 10% (exclusive), one comped: total 55.00, comp 27.50, cash 27.50. */
export function walkupQuote(q: WalkupQuoteInput): WalkupQuote {
  const qty = Math.max(Math.trunc(Number(q.quantity) || 0), 0);
  const comp = Math.min(Math.max(Math.trunc(Number(q.compQuantity) || 0), 0), qty);
  const line = lineTotals({ category: 'ticket', unitPriceCents: q.unitCents, quantity: qty, tax: q.tax ?? null });
  const unitTotal = qty > 0 ? line.totalCents / qty : lineTotals({ category: 'ticket', unitPriceCents: q.unitCents, quantity: 1, tax: q.tax ?? null }).totalCents;
  const compCents = unitTotal * comp;
  return { unitTotalCents: unitTotal, totalCents: line.totalCents, taxCents: line.taxCents, compCents, cashDueCents: line.totalCents - compCents };
}

/** Cash handed over vs due: the change to give, or how much is still short. */
export function changeDue(dueCents: number, receivedCents: number): { changeCents: number; shortCents: number } {
  const due = Math.max(Math.round(dueCents) || 0, 0);
  const got = Math.max(Math.round(receivedCents) || 0, 0);
  return got >= due ? { changeCents: got - due, shortCents: 0 } : { changeCents: 0, shortCents: due - got };
}

/** Quick-cash buttons: the exact amount, then the next round bills above it. */
export function quickCash(dueCents: number): number[] {
  const due = Math.max(Math.round(dueCents) || 0, 0);
  if (due === 0) return [];
  const out = new Set<number>([due]);
  for (const step of [500, 1000, 2000, 5000, 10000]) {
    const up = Math.ceil(due / step) * step;
    if (up > due) out.add(up);
    if (out.size >= 4) break;
  }
  return [...out].sort((a, b) => a - b);
}

export type DoorRole = 'owner' | 'manager' | 'scanner';

export interface ReverseInput {
  status: 'pending' | 'paid' | 'void' | 'refunded';
  createdAt: string | number | Date;
  /** Tickets of the sale already scanned in. */
  scanned: number;
  rungByMe: boolean;
  role: DoorRole;
  now?: number;
}

export type ReverseOption =
  | { kind: 'void' }
  | { kind: 'cancel' }
  | { kind: 'refund'; override: boolean }
  | { kind: 'none'; reason: 'done' | 'not-yours' | 'needs-manager' };

/** What this member can do to a sale now (the SQL decides; this drives the buttons). */
export function reverseOption(o: ReverseInput): ReverseOption {
  const manager = o.role === 'owner' || o.role === 'manager';
  if (o.status === 'void' || o.status === 'refunded') return { kind: 'none', reason: 'done' };
  if (o.status === 'pending') return o.rungByMe || manager ? { kind: 'cancel' } : { kind: 'none', reason: 'not-yours' };
  const ageMs = (o.now ?? Date.now()) - new Date(o.createdAt).getTime();
  const sameNight = ageMs <= WALKUP_VOID_WINDOW_HOURS * 3_600_000;
  if (sameNight && o.scanned === 0 && (o.rungByMe || manager)) return { kind: 'void' };
  if (manager) return { kind: 'refund', override: o.scanned > 0 };
  return { kind: 'none', reason: sameNight && o.scanned === 0 ? 'not-yours' : 'needs-manager' };
}

/** A drawer's cash now: float + cash in (refunded sales too) + cash gift cards - paid-outs. */
export function drawerCashCents(d: { openFloatCents: number; cashInCents: number; giftCardCents?: number; paidOutCents?: number }): number {
  return d.openFloatCents + d.cashInCents + (d.giftCardCents ?? 0) - (d.paidOutCents ?? 0);
}

/** A paid-out the SQL would take: whole cents, at most what the drawer holds, a reason of 3-300 characters. */
export function paidOutProblem(amountCents: number, drawerCents: number, reason: string): 'amount' | 'too-much' | 'reason' | null {
  if (!Number.isInteger(amountCents) || amountCents < 1 || amountCents > 10_000_000) return 'amount';
  if (amountCents > drawerCents) return 'too-much';
  const r = reason.trim().length;
  if (r < 3 || r > 300) return 'reason';
  return null;
}
