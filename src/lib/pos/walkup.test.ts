import { describe, expect, it } from 'vitest';
import {
  buildSettlement, CARD_POLL_GIVE_UP_MS, cardStateDone, cardStateText, changeDue, doorQuestions, drawerCashCents,
  missingAnswersText, paidOutProblem, quickCash, reconcileDrawer, reverseOption, walkupMissingRequired, walkupQuote,
  WALKUP_VOID_WINDOW_HOURS, type DoorQuestion, type SettlementOrder,
} from './index';

// The same numbers as tests/exos/test_pos_walkup.sql (W2, W5, W7).
describe('walk-up price and tenders', () => {
  it('prices at the door price, tax per unit like checkout', () => {
    expect(walkupQuote({ unitCents: 2500, quantity: 2 })).toEqual(
      { unitTotalCents: 2500, totalCents: 5000, taxCents: 0, compCents: 0, cashDueCents: 5000 });
    // Early bird $15 + 10% exclusive: 16.50 each.
    expect(walkupQuote({ unitCents: 1500, quantity: 2, tax: { ratePercent: 10, priceIncludesTax: false } }))
      .toMatchObject({ unitTotalCents: 1650, totalCents: 3300, taxCents: 300 });
    // Inclusive: the price already has it.
    expect(walkupQuote({ unitCents: 2200, quantity: 3, tax: { ratePercent: 10, priceIncludesTax: true } }))
      .toMatchObject({ unitTotalCents: 2200, totalCents: 6600, taxCents: 600 });
  });

  it('comps cover whole tickets; cash is the rest', () => {
    expect(walkupQuote({ unitCents: 2500, quantity: 2, compQuantity: 1 })).toMatchObject({ compCents: 2500, cashDueCents: 2500 });
    expect(walkupQuote({ unitCents: 2500, quantity: 1, compQuantity: 1 })).toMatchObject({ compCents: 2500, cashDueCents: 0 });
    expect(walkupQuote({ unitCents: 2500, quantity: 1, compQuantity: 5 }).cashDueCents).toBe(0);
    expect(walkupQuote({ unitCents: 0, quantity: 2 })).toMatchObject({ totalCents: 0, cashDueCents: 0 });
  });

  it('change and quick-cash buttons', () => {
    expect(changeDue(2750, 4000)).toEqual({ changeCents: 1250, shortCents: 0 });
    expect(changeDue(2750, 2000)).toEqual({ changeCents: 0, shortCents: 750 });
    expect(quickCash(2750)).toEqual([2750, 3000, 4000, 5000]);
    expect(quickCash(2000)).toEqual([2000, 5000, 10000]);
    expect(quickCash(0)).toEqual([]);
  });
});

describe('void, refund, override', () => {
  const now = Date.parse('2026-11-07T23:00:00Z');
  const sale = { status: 'paid' as const, createdAt: '2026-11-07T21:00:00Z', scanned: 0, rungByMe: true, role: 'scanner' as const, now };
  it('the seller voids the same night before a scan', () => {
    expect(reverseOption(sale)).toEqual({ kind: 'void' });
    expect(reverseOption({ ...sale, rungByMe: false })).toEqual({ kind: 'none', reason: 'not-yours' });
    expect(reverseOption({ ...sale, rungByMe: false, role: 'manager' })).toEqual({ kind: 'void' });
  });
  it('after a scan or the window: a manager refund (override after a scan)', () => {
    expect(reverseOption({ ...sale, scanned: 1 })).toEqual({ kind: 'none', reason: 'needs-manager' });
    expect(reverseOption({ ...sale, scanned: 1, role: 'owner' })).toEqual({ kind: 'refund', override: true });
    const late = { ...sale, createdAt: now - (WALKUP_VOID_WINDOW_HOURS + 1) * 3_600_000 };
    expect(reverseOption(late)).toEqual({ kind: 'none', reason: 'needs-manager' });
    expect(reverseOption({ ...late, role: 'manager' })).toEqual({ kind: 'refund', override: false });
  });
  it('pending sales are cancelled; done sales are done', () => {
    expect(reverseOption({ ...sale, status: 'pending' })).toEqual({ kind: 'cancel' });
    expect(reverseOption({ ...sale, status: 'void' })).toEqual({ kind: 'none', reason: 'done' });
  });
});

describe('drawer with paid-outs', () => {
  it('voided cash went out as a paid-out; the drawer still balances', () => {
    // $100 float, two cash sales of 50.00 and 25.00, the 50.00 voided, a 10.00 paid-out.
    const cash = drawerCashCents({ openFloatCents: 10000, cashInCents: 7500, paidOutCents: 5000 + 1000 });
    expect(cash).toBe(11500);
    expect(reconcileDrawer({ openFloatCents: 10000, cashPayments: [{ amountCents: 5000 }, { amountCents: 2500 }],
      paidOutCents: 6000, countedCents: 11500 })).toMatchObject({ expectedCents: 11500, status: 'balanced' });
    expect(paidOutProblem(1000, cash, 'ice for the bar')).toBeNull();
    expect(paidOutProblem(20000, cash, 'too much')).toBe('too-much');
    expect(paidOutProblem(100, cash, 'x')).toBe('reason');
    expect(paidOutProblem(10.5, cash, 'half cent')).toBe('amount');
  });
});

describe('the walk-up fee setting', () => {
  // Cash walk-ups at the door: default no Exos fee; 'all-tickets' charges them.
  const DOOR: SettlementOrder[] = [
    { id: 'w1', status: 'paid', totalCents: 5000, lines: [{ category: 'ticket', quantity: 2, totalCents: 5000, taxCents: 0 }],
      payments: [{ method: 'cash', amountCents: 5000 }] },
    { id: 'w2', status: 'paid', totalCents: 5000, lines: [{ category: 'ticket', quantity: 2, totalCents: 5000, taxCents: 0 }],
      payments: [{ method: 'cash', amountCents: 2500 }, { method: 'comp', amountCents: 2500 }] },
    { id: 'w3', status: 'void', totalCents: 2500, lines: [{ category: 'ticket', quantity: 1, totalCents: 2500, taxCents: 0 }],
      payments: [] },
  ];
  it('defaults to card tickets only (what the scaffold settlement does)', () => {
    const s = buildSettlement(DOOR, [], { feeBps: 300 });
    expect(s).toMatchObject({ feeBase: 'card-tickets', cashTicketCents: 7500, cardTicketCents: 0, exosFeeCents: 0, organizerNetCents: 7500 });
  });
  it('all-tickets charges cash ticket sales too', () => {
    const s = buildSettlement(DOOR, [], { feeBps: 300, feeBase: 'all-tickets' });
    expect(s).toMatchObject({ feeBaseCents: 7500, exosFeeCents: 225, organizerNetCents: 7275 });
  });
});

describe('card at the door (screen text)', () => {
  it('says what is happening and when to stop polling', () => {
    expect(cardStateText('waiting')).toMatch(/reader/);
    expect(cardStateText('declined', 'insufficient_funds')).toBe('Declined (insufficient funds): nothing was charged.');
    expect(cardStateText('declined')).toBe('Declined: nothing was charged.');
    expect(cardStateDone('waiting')).toBe(false);
    expect(cardStateDone('starting')).toBe(false);
    for (const s of ['succeeded', 'declined', 'canceled', 'refunded'] as const) expect(cardStateDone(s)).toBe(true);
    expect(CARD_POLL_GIVE_UP_MS).toBeGreaterThan(5 * 60_000);
  });
});

// Checkout questions at the door (mig 20261108110000; tests/exos/test_dice_leftovers.sql DL1).
describe('walk-up checkout questions', () => {
  const company: DoorQuestion = { id: 'q-co', label: 'Company', kind: 'text', required: true, scope: 'order' };
  const size: DoorQuestion = { id: 'q-size', label: 'Size', kind: 'single_choice', options: ['S', 'M', 'L'], required: true, scope: 'ticket' };
  const allergy: DoorQuestion = { id: 'q-al', label: 'Allergy?', kind: 'checkbox', required: false, scope: 'ticket' };
  const which: DoorQuestion = {
    id: 'q-which', label: 'Which allergy', kind: 'text', required: true, scope: 'ticket', parent_question_id: 'q-al', parent_values: ['true'],
  };
  const band: DoorQuestion = { id: 'q-band', label: 'Wristband colour', kind: 'text', required: true, scope: 'ticket', hidden: true };
  const qs = [company, size, allergy, which, band];
  const two = ['tier', 'tier'];

  it('lists the required answers missing, per order and per ticket', () => {
    expect(walkupMissingRequired(qs, two, {}).map((m) => [m.label, m.ticket])).toEqual([
      ['Company', null], ['Size', 1], ['Size', 2],
    ]);
    expect(walkupMissingRequired(qs, two, { order: { 'q-co': 'Acme' }, tickets: [{ 'q-size': 'M' }] }))
      .toEqual([{ question_id: 'q-size', label: 'Size', ticket: 2 }]);
  });
  it('a "show only if" question is required only when shown', () => {
    const base = { order: { 'q-co': 'Acme' }, tickets: [{ 'q-size': 'M', 'q-al': true }, { 'q-size': 'L' }] };
    expect(walkupMissingRequired(qs, two, base)).toEqual([{ question_id: 'q-which', label: 'Which allergy', ticket: 1 }]);
    expect(walkupMissingRequired(qs, two, { ...base, tickets: [{ ...base.tickets[0], 'q-which': 'Peanuts' }, base.tickets[1]] })).toEqual([]);
  });
  it('a question hidden from checkout is never required at the door', () => {
    expect(doorQuestions([band])[0].required).toBe(false);
    expect(doorQuestions([size])[0]).toBe(size);
    expect(walkupMissingRequired([band], ['tier'], {})).toEqual([]);
  });
  it('nothing to ask: nothing missing', () => {
    expect(walkupMissingRequired([], two, {})).toEqual([]);
    expect(walkupMissingRequired(qs, [], {})).toEqual([]);
  });
  it('says what is missing in one line', () => {
    expect(missingAnswersText([])).toBe('');
    expect(missingAnswersText([{ question_id: 'a', label: 'Company', ticket: null }])).toBe('1 required answer missing: Company');
    expect(missingAnswersText(walkupMissingRequired(qs, ['t', 't', 't'], {})))
      .toBe('4 required answers missing: Company, Size (ticket 1), Size (ticket 2) and 1 more');
  });
});
