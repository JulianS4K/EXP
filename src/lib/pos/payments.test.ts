import { describe, expect, it } from 'vitest';
import {
  allocateTabPayment,
  applyTenders,
  cashChange,
  FakeTerminal,
  NotWiredTerminal,
  overTabLimit,
  PaymentsNotWiredError,
  poolTips,
  splitByGuest,
  splitEvenly,
  tabBalance,
  tipCents,
  tipPresets,
  validateTip,
} from './index';

describe('tips', () => {
  it('percent of the base, half up', () => {
    expect(tipCents(1760, 20)).toBe(352);
    expect(tipCents(1234, 18)).toBe(222); // 222.12
    expect(tipCents(1250, 18)).toBe(225);
    expect(tipCents(1025, 20)).toBe(205);
    expect(tipCents(0, 20)).toBe(0);
    expect(tipCents(1000, 0)).toBe(0);
  });

  it('presets tip the pre-tax subtotal by default, the total on request', () => {
    const amounts = { subtotalCents: 1600, totalCents: 1760 };
    expect(tipPresets(amounts)).toEqual([
      { percent: 18, tipCents: 288 }, { percent: 20, tipCents: 320 }, { percent: 22, tipCents: 352 },
    ]);
    expect(tipPresets(amounts, { base: 'total', percents: [20] })).toEqual([{ percent: 20, tipCents: 352 }]);
  });

  it('a typed tip is whole cents, not negative, not over 100% without a manager', () => {
    expect(validateTip(500, 1760)).toEqual({ ok: true, tipCents: 500 });
    expect(validateTip(-1, 1760)).toEqual({ ok: false, reason: 'negative' });
    expect(validateTip(1.5, 1760)).toEqual({ ok: false, reason: 'not-whole-cents' });
    expect(validateTip(1761, 1760)).toEqual({ ok: false, reason: 'too-large' });
  });

  it('pools tips by hours and always adds up to the cent', () => {
    const p = poolTips(1000, { ana: 5, ben: 3, cy: 1 });
    expect(p.ana + p.ben + p.cy).toBe(1000);
    expect(p).toEqual({ ana: 556, ben: 333, cy: 111 });
    expect(poolTips(1000, {})).toEqual({});
  });
});

describe('tabs', () => {
  const orders = [
    { id: 'o1', status: 'paid' as const, totalCents: 880, paidCents: 880, tipCents: 100 },
    { id: 'o2', status: 'open' as const, totalCents: 1760, paidCents: 500, tipCents: 0 },
    { id: 'o3', status: 'void' as const, totalCents: 999, paidCents: 0, tipCents: 0 },
    { id: 'o4', status: 'open' as const, totalCents: 0, paidCents: 0, tipCents: 0 },
    { id: 'o5', status: 'open' as const, totalCents: 880, paidCents: 0, tipCents: 0 },
  ];
  it('balance: void and empty orders do not count', () => {
    expect(tabBalance(orders)).toEqual({
      orders: 3, totalCents: 3520, paidCents: 1380, dueCents: 2140, tipCents: 100, canClose: false,
    });
    expect(tabBalance([orders[0], orders[3]]).canClose).toBe(true);
  });
  it('a tab payment covers the oldest open orders first', () => {
    expect(allocateTabPayment(orders, 1500)).toEqual([
      { orderId: 'o2', amountCents: 1260 }, { orderId: 'o5', amountCents: 240 },
    ]);
  });
  it('tab limit', () => {
    expect(overTabLimit({ dueCents: 4000 }, 1500, 5000)).toBe(true);
    expect(overTabLimit({ dueCents: 4000 }, 1000, 5000)).toBe(false);
    expect(overTabLimit({ dueCents: 4000 }, 99999, null)).toBe(false);
  });
});

describe('split payments', () => {
  it('splits evenly, extra cents to the first shares', () => {
    expect(splitEvenly(1000, 3)).toEqual([334, 333, 333]);
    expect(splitEvenly(2500, 2)).toEqual([1250, 1250]);
    expect(splitEvenly(1000, 0)).toEqual([]);
    expect(splitEvenly(7, 3).reduce((a, b) => a + b, 0)).toBe(7);
  });

  it('applies tenders like the SQL: cash + card = split, overpay refused', () => {
    const r = applyTenders(2500, [{ method: 'cash', amountCents: 1000 }, { method: 'card', amountCents: 1500, tipCents: 300 }]);
    expect(r).toEqual({
      ok: true,
      state: {
        totalCents: 2500, paidCents: 2500, remainingCents: 0, tipCents: 300, paid: true, method: 'split',
        byMethod: { cash: 1000, card: 1500, comp: 0 },
      },
    });
    const one = applyTenders(1760, [{ method: 'cash', amountCents: 1760, tipCents: 200 }]);
    expect(one.ok && one.state.method).toBe('cash');
    const half = applyTenders(2500, [{ method: 'cash', amountCents: 1000 }]);
    expect(half.ok && half.state).toMatchObject({ paid: false, remainingCents: 1500, method: null });
    expect(applyTenders(2500, [{ method: 'cash', amountCents: 1000 }, { method: 'card', amountCents: 1501 }]))
      .toEqual({ ok: false, reason: 'overpaid', index: 1 });
    expect(applyTenders(880, [{ method: 'comp', amountCents: 880, tipCents: 1 }])).toEqual({ ok: false, reason: 'comp-tip', index: 0 });
    expect(applyTenders(880, [{ method: 'cash', amountCents: 0 }])).toEqual({ ok: false, reason: 'bad-amount', index: 0 });
  });

  it('cash change', () => {
    expect(cashChange(2000, 1760)).toEqual({ applyCents: 1760, changeCents: 240, shortCents: 0 });
    expect(cashChange(1000, 1760)).toEqual({ applyCents: 1000, changeCents: 0, shortCents: 760 });
  });

  it('split by guest adds up to the order', () => {
    expect(splitByGuest([{ guest: 'a', totalCents: 880 }, { guest: 'b', totalCents: 880 }, { guest: 'a', totalCents: 2500 }]))
      .toEqual({ a: 3380, b: 880 });
  });
});

describe('payment terminal (no Stripe)', () => {
  it('FakeTerminal: scripted outcomes, idempotent per key, refunds bounded', async () => {
    const t = new FakeTerminal().script('declined');
    await expect(t.collect({ amountCents: 100, currency: 'usd', idempotencyKey: 'k0', orderId: 'o' }))
      .rejects.toThrow(/no reader/);
    await t.connect('tmr_FAKE');
    const declined = await t.collect({ amountCents: 1500, tipCents: 300, currency: 'usd', idempotencyKey: 'k1', orderId: 'b' });
    expect(declined).toEqual({ status: 'declined', amountCents: 0, tipCents: 0, declineCode: 'card_declined' });
    const ok = await t.collect({ amountCents: 1500, tipCents: 300, currency: 'usd', idempotencyKey: 'k2', orderId: 'b' });
    expect(ok).toEqual({ status: 'succeeded', terminalRef: 'fake_pi_000001', amountCents: 1500, tipCents: 300 });
    // Same key: same answer, no second charge.
    expect(await t.collect({ amountCents: 1500, tipCents: 300, currency: 'usd', idempotencyKey: 'k2', orderId: 'b' })).toEqual(ok);
    // The reference fits exos_pos_payments.terminal_ref.
    expect(ok.terminalRef).toMatch(/^[A-Za-z0-9_]{1,255}$/);
    expect((await t.refund('fake_pi_000001', 1000)).status).toBe('succeeded');
    expect((await t.refund('fake_pi_000001', 900)).status).toBe('failed'); // 1000 + 900 > 1800
    expect((await t.refund('fake_pi_nope', 1)).status).toBe('failed');
    expect(t.log.filter((l) => l.op === 'collect')).toHaveLength(4);
  });

  it('NotWiredTerminal refuses everything', async () => {
    const t = new NotWiredTerminal();
    await expect(t.connect()).rejects.toBeInstanceOf(PaymentsNotWiredError);
    await expect(t.collect()).rejects.toThrow(/not wired/);
  });
});
