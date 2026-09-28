import { describe, expect, it } from 'vitest';
import {
  artistDealCents,
  buildSettlement,
  commissionHook,
  countDenominations,
  reconcileDrawer,
  safeDropCents,
  type SettlementOrder,
} from './index';
import { exosFeeBpsAt } from '../../../supabase/functions/_shared/platformFee.ts';

// The same night as tests/exos/test_pos_scaffold.sql (P4-P8), so the TS and
// the SQL settlement can't drift apart.
const P = 'promoter-1';
const NIGHT: SettlementOrder[] = [
  { id: 'A', status: 'paid', totalCents: 1760,
    lines: [{ category: 'bar', quantity: 2, totalCents: 1760, taxCents: 160 }],
    payments: [{ method: 'cash', amountCents: 1760, tipCents: 200 }] },
  { id: 'B', status: 'paid', totalCents: 2500,
    lines: [{ category: 'merch', quantity: 1, totalCents: 2500, taxCents: 0 }],
    payments: [{ method: 'cash', amountCents: 1000 }, { method: 'card', amountCents: 1500, tipCents: 300 }] },
  { id: 'C', status: 'paid', totalCents: 4000,
    lines: [{ category: 'ticket', quantity: 2, totalCents: 4000, taxCents: 364, promoterId: P }],
    payments: [{ method: 'card', amountCents: 4000 }] },
  { id: 'D', status: 'paid', totalCents: 2880,
    lines: [{ category: 'ticket', quantity: 1, totalCents: 2000, taxCents: 182, promoterId: P },
            { category: 'bar', quantity: 1, totalCents: 880, taxCents: 80 }],
    payments: [{ method: 'comp', amountCents: 880 }, { method: 'card', amountCents: 2000 }] },
  { id: 'E', status: 'paid', totalCents: 880,
    lines: [{ category: 'bar', quantity: 1, totalCents: 880, taxCents: 80 }],
    payments: [{ method: 'cash', amountCents: 880 }] },
  { id: 'open', status: 'open', totalCents: 880,
    lines: [{ category: 'bar', quantity: 1, totalCents: 880, taxCents: 80 }], payments: [] },
  { id: 'void', status: 'void', totalCents: 0, lines: [], payments: [] },
];

describe('cash drawer reconciliation', () => {
  it('expected = float + cash taken (tips in); variance = counted - expected', () => {
    const counted = countDenominations({ 10000: 1, 2000: 1, 500: 1, 100: 4, 50: 1 });
    expect(counted).toBe(12950);
    const r = reconcileDrawer({
      openFloatCents: 10000,
      cashPayments: [{ amountCents: 1760, tipCents: 200 }, { amountCents: 1000 }],
      countedCents: counted,
    });
    expect(r).toEqual({ cashTakenCents: 2960, expectedCents: 12960, countedCents: 12950, varianceCents: -10, status: 'short' });
    expect(reconcileDrawer({ openFloatCents: 10000, cashPayments: [], countedCents: 10025 }).status).toBe('over');
    expect(reconcileDrawer({ openFloatCents: 10000, cashPayments: [], countedCents: 9990 }, 25).status).toBe('balanced');
    expect(reconcileDrawer({ openFloatCents: 10000, cashPayments: [{ amountCents: 500 }], paidOutCents: 300, countedCents: 10200 }))
      .toMatchObject({ expectedCents: 10200, varianceCents: 0, status: 'balanced' });
    expect(safeDropCents(12950, 10000)).toBe(2950);
  });

  it('refuses bad counts, like the SQL', () => {
    expect(() => countDenominations({ '0': 1 })).toThrow(/denomination/);
    expect(() => countDenominations({ '100': -1 })).toThrow(/count/);
    expect(() => countDenominations({ '100': 1.5 })).toThrow(/count/);
  });
});

describe('end-of-night settlement (same numbers as exos_pos_settlement_summary)', () => {
  const drawers = [{ status: 'closed' as const, openFloatCents: 10000,
    reconciliation: { expectedCents: 12960, countedCents: 12950, varianceCents: -10 } }];

  it('tickets + bar + merch, cash vs card, Exos fee on card ticket sales', () => {
    const s = buildSettlement(NIGHT, drawers, { feeBps: 300 });
    expect(s.orders).toBe(5);
    expect(s.openOrders).toBe(1);
    expect(s.gross).toEqual({ ticket: 6000, bar: 3520, merch: 2500, total: 12020 });
    expect(s.taxCents).toBe(866);
    expect(s.tenders).toEqual({ cash: 3640, card: 7500, comp: 880 });
    expect(s.tenders.cash + s.tenders.card + s.tenders.comp).toBe(s.gross.total);
    expect(s.tips).toEqual({ cash: 200, card: 300, total: 500 });
    // C 4000 + D floor(2000 x 2000 / 2880) = 1388.
    expect(s.cardTicketCents).toBe(5388);
    expect(s.feeBase).toBe('card-tickets');
    expect(s.exosFeeCents).toBe(162); // 3% of 53.88 = 1.6164, half up
    expect(s.organizerNetCents).toBe(3640 + 7500 - 162);
    // Stripe Terminal estimate (2.7% half up + 5c): B 1800 -> 54, C 4000 -> 113, D 2000 -> 59.
    expect(s.cardProcessingEstimateCents).toBe(226);
    expect(s.promoters).toEqual([{ promoterId: P, tickets: 3, baseCents: 4898, commissionCents: null }]);
    expect(s.drawers).toEqual({ open: 0, closed: 1, floatCents: 10000, expectedCents: 12960, countedCents: 12950, varianceCents: -10 });
  });

  it('no Exos fee during the org\'s free months', () => {
    const now = new Date('2026-10-01T00:00:00Z');
    const bps = exosFeeBpsAt('2027-03-01T00:00:00Z', now);
    const s = buildSettlement(NIGHT, drawers, { feeBps: bps });
    expect(bps).toBe(0);
    expect(s.exosFeeCents).toBe(0);
    expect(s.organizerNetCents).toBe(11140);
    expect(exosFeeBpsAt('2026-09-01T00:00:00Z', now)).toBe(300);
  });

  it('the fee base is an operator decision: card-all or all-sales', () => {
    expect(buildSettlement(NIGHT, [], { feeBps: 300, feeBase: 'card-all' })).toMatchObject({ feeBaseCents: 7500, exosFeeCents: 225 });
    expect(buildSettlement(NIGHT, [], { feeBps: 300, feeBase: 'all-sales' })).toMatchObject({ feeBaseCents: 11140, exosFeeCents: 334 });
  });

  it('promoter split hook: commission on the paid base', () => {
    const s = buildSettlement(NIGHT, [], { feeBps: 300, promoterHook: commissionHook({ [P]: { rateBps: 1000, flatCents: 50 } }) });
    // floor(4898 x 10%) = 489 + 3 tickets x 50 = 639.
    expect(s.promoters[0].commissionCents).toBe(639);
    const capped = buildSettlement(NIGHT, [], { feeBps: 300, promoterHook: commissionHook({ [P]: { rateBps: 0, flatCents: 100000 } }) });
    expect(capped.promoters[0].commissionCents).toBe(4898);
    expect(buildSettlement(NIGHT, [], { feeBps: 300, promoterHook: commissionHook({}) }).promoters[0].commissionCents).toBe(0);
  });

  it('an empty night settles to zero', () => {
    const s = buildSettlement([], [], { feeBps: 300 });
    expect(s).toMatchObject({ orders: 0, exosFeeCents: 0, organizerNetCents: 0, promoters: [] });
  });
});

describe('artist deal hook (guarantee vs door split)', () => {
  it('pays the larger of the guarantee and the split after expenses', () => {
    expect(artistDealCents({ guaranteeCents: 50000, doorSplitBps: 8000, expensesCents: 20000 }, 100000))
      .toEqual({ artistCents: 64000, basis: 'door-split' });
    expect(artistDealCents({ guaranteeCents: 50000, doorSplitBps: 8000, expensesCents: 20000 }, 60000))
      .toEqual({ artistCents: 50000, basis: 'guarantee' });
  });
});
