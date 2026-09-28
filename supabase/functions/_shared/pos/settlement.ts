// Venue POS: end-of-night settlement. PURE, integer cents. buildSettlement is
// the same math as public.exos_pos_settlement_summary (mig 20260929074000);
// src/lib/pos/settlement.test.ts and tests/exos/test_pos_scaffold.sql (P8)
// pin the same night, so the two can't drift silently.
//
//   gross per category  line totals (tax in, comps in) of PAID orders
//   tenders             cash / card / comp, tips apart (tips are staff money)
//   card ticket sales   per order floor(ticket gross x card / order total):
//                       a split order's card share is pro-rata
//   Exos fee            exosFeeCents(card ticket sales, bps): 3% half up, 0 in
//                       the org's free months (exos_org_fee_bps / exosFeeBpsAt).
//                       OPERATOR DECISION (docs/pos.md): the fee is charged on
//                       CARD TICKET sales only for now; bar, merch and cash
//                       are not charged. feeBase lets the operator widen it.
//   organizer net       cash + card - Exos fee (card processing comes off the
//                       Stripe payout; estimated separately below)
//   promoters           per promoter: ticket lines net of tax, paid share
//                       (floor(net x (cash + card) / total)); the commission
//                       is a hook (terms live in exos_promoters /
//                       exos_promoter_event_terms)
//   drawers             float, expected, counted, variance

import { exosFeeCents, stripeFeeCents, type CardFee } from '../platformFee.ts';
import type { PosCategory } from './totals.ts';
import type { PosOrderStatus } from './tabs.ts';
import type { PosTenderMethod } from './split.ts';
import type { DrawerReconciliation } from './drawer.ts';

export interface SettlementLine {
  category: PosCategory;
  quantity: number;
  totalCents: number;
  taxCents: number;
  promoterId?: string | null;
}

export interface SettlementPayment {
  method: PosTenderMethod;
  amountCents: number;
  tipCents?: number;
}

export interface SettlementOrder {
  id: string;
  status: PosOrderStatus;
  totalCents: number;
  lines: readonly SettlementLine[];
  payments: readonly SettlementPayment[];
}

export interface SettlementDrawer {
  status: 'open' | 'closed';
  openFloatCents: number;
  reconciliation?: Pick<DrawerReconciliation, 'expectedCents' | 'countedCents' | 'varianceCents'> | null;
}

/** A promoter's paid ticket base for the night. */
export interface PromoterBase {
  promoterId: string;
  tickets: number;
  baseCents: number;
}

/** Returns the commission (cents) owed on a promoter's base. */
export type PromoterSplitHook = (row: PromoterBase) => number;

/**
 * Stripe Terminal's standard US in-person rate: 2.7% + 5c (estimate; the real
 * fee comes from the Stripe balance transaction once the terminal is wired).
 */
export const STRIPE_TERMINAL_FEE: CardFee = { bps: 270, fixedCents: 5 };

export type FeeBase = 'card-tickets' | 'card-all' | 'all-sales';

export interface SettlementOptions {
  /** The org's Exos rate now (exosFeeBpsAt(fee_free_until, now)); 0 during its free months. */
  feeBps: number;
  /** What the Exos fee applies to. Default 'card-tickets' (operator decision pending). */
  feeBase?: FeeBase;
  promoterHook?: PromoterSplitHook;
  /** Card processing estimate per card tender (amount + tip). Default STRIPE_TERMINAL_FEE. */
  cardFee?: CardFee;
}

export interface SettlementReport {
  orders: number;
  openOrders: number;
  gross: Record<PosCategory, number> & { total: number };
  taxCents: number;
  tenders: Record<PosTenderMethod, number>;
  tips: { cash: number; card: number; total: number };
  cardTicketCents: number;
  feeBps: number;
  feeBase: FeeBase;
  feeBaseCents: number;
  exosFeeCents: number;
  organizerNetCents: number;
  cardProcessingEstimateCents: number;
  promoters: (PromoterBase & { commissionCents: number | null })[];
  drawers: { open: number; closed: number; floatCents: number; expectedCents: number; countedCents: number; varianceCents: number };
}

const share = (amount: number, num: number, den: number): number => (den > 0 ? Math.floor((amount * num) / den) : 0);

export function buildSettlement(
  orders: readonly SettlementOrder[],
  drawers: readonly SettlementDrawer[],
  opts: SettlementOptions,
): SettlementReport {
  const gross = { ticket: 0, bar: 0, merch: 0, total: 0 };
  const tenders = { cash: 0, card: 0, comp: 0 };
  const tips = { cash: 0, card: 0, total: 0 };
  let tax = 0, paidOrders = 0, openOrders = 0, cardTicket = 0, cardAll = 0, processing = 0;
  const promo = new Map<string, PromoterBase>();
  const cardFee = opts.cardFee ?? STRIPE_TERMINAL_FEE;

  for (const o of orders) {
    if (o.status === 'open') openOrders += 1;
    if (o.status !== 'paid') continue;
    paidOrders += 1;
    const pay = { cash: 0, card: 0, comp: 0 };
    for (const p of o.payments) {
      pay[p.method] += p.amountCents;
      const tip = p.tipCents ?? 0;
      if (p.method === 'cash') tips.cash += tip;
      if (p.method === 'card') {
        tips.card += tip;
        processing += stripeFeeCents(p.amountCents + tip, cardFee);
      }
    }
    let ticketGross = 0;
    for (const l of o.lines) {
      gross[l.category] += l.totalCents;
      tax += l.taxCents;
      if (l.category === 'ticket') {
        ticketGross += l.totalCents;
        if (l.promoterId) {
          const row = promo.get(l.promoterId) ?? { promoterId: l.promoterId, tickets: 0, baseCents: 0 };
          row.tickets += l.quantity;
          row.baseCents += share(l.totalCents - l.taxCents, pay.cash + pay.card, o.totalCents);
          promo.set(l.promoterId, row);
        }
      }
    }
    cardTicket += share(ticketGross, pay.card, o.totalCents);
    cardAll += pay.card;
    tenders.cash += pay.cash;
    tenders.card += pay.card;
    tenders.comp += pay.comp;
  }
  gross.total = gross.ticket + gross.bar + gross.merch;
  tips.total = tips.cash + tips.card;

  const feeBase = opts.feeBase ?? 'card-tickets';
  const feeBaseCents = feeBase === 'card-tickets' ? cardTicket : feeBase === 'card-all' ? cardAll : tenders.cash + tenders.card;
  const fee = exosFeeCents(feeBaseCents, opts.feeBps);

  const d = { open: 0, closed: 0, floatCents: 0, expectedCents: 0, countedCents: 0, varianceCents: 0 };
  for (const dr of drawers) {
    if (dr.status === 'open') { d.open += 1; continue; }
    d.closed += 1;
    d.floatCents += dr.openFloatCents;
    d.expectedCents += dr.reconciliation?.expectedCents ?? 0;
    d.countedCents += dr.reconciliation?.countedCents ?? 0;
    d.varianceCents += dr.reconciliation?.varianceCents ?? 0;
  }

  return {
    orders: paidOrders,
    openOrders,
    gross,
    taxCents: tax,
    tenders,
    tips,
    cardTicketCents: cardTicket,
    feeBps: opts.feeBps,
    feeBase,
    feeBaseCents,
    exosFeeCents: fee,
    organizerNetCents: tenders.cash + tenders.card - fee,
    cardProcessingEstimateCents: processing,
    promoters: [...promo.values()]
      .sort((a, b) => a.promoterId.localeCompare(b.promoterId))
      .map((r) => ({ ...r, commissionCents: opts.promoterHook ? opts.promoterHook(r) : null })),
    drawers: d,
  };
}

/**
 * A promoter hook from commission terms (exos_promoters.commission_bps /
 * commission_flat_cents): min(base, floor(base x bps / 10000) + flat x tickets).
 * Same shape as src/lib/commissions.ts commissionCents, applied to the night's
 * total; the per-ticket accrual ledger for POS sales is a later migration.
 */
export function commissionHook(terms: Record<string, { rateBps: number; flatCents: number }>): PromoterSplitHook {
  return (row) => {
    const t = terms[row.promoterId];
    if (!t || row.baseCents <= 0) return 0;
    const bps = Math.max(Math.trunc(t.rateBps), 0);
    const flat = Math.max(Math.trunc(t.flatCents), 0);
    return Math.min(row.baseCents, Math.floor((row.baseCents * bps) / 10000) + flat * row.tickets);
  };
}

/**
 * Artist deal hook ("guarantee vs door split"): the artist gets the larger of
 * the guarantee and their share of the door after expenses. doorNetCents is
 * the ticket money the deal is on (usually ticket gross net of tax and fees);
 * both are an operator / promoter contract input, not computed here.
 */
export function artistDealCents(deal: { guaranteeCents: number; doorSplitBps: number; expensesCents?: number }, doorNetCents: number): {
  artistCents: number;
  basis: 'guarantee' | 'door-split';
} {
  const afterExpenses = Math.max(doorNetCents - (deal.expensesCents ?? 0), 0);
  const split = Math.floor((afterExpenses * Math.max(deal.doorSplitBps, 0)) / 10000);
  return split > deal.guaranteeCents
    ? { artistCents: split, basis: 'door-split' }
    : { artistCents: Math.max(deal.guaranteeCents, 0), basis: 'guarantee' };
}
