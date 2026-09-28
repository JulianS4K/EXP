import { describe, expect, it } from 'vitest';
import { connectTransfer, payoutsMode, tevoRemittanceFor } from '../../../supabase/functions/_shared/payouts/payouts.ts';
import { normalizeTevoPayment } from '../marketplace/tevo';

const pay = (over: Record<string, unknown>) =>
  normalizeTevoPayment({ id: 18582737, order_link_id: 19196777, type: 'evopay', state: 'completed', amount: '32.48', updated_at: '2026-09-26T13:40:17Z', ...over });

describe('payouts mode', () => {
  it('is dry-run unless EXOS_PAYOUTS_LIVE is exactly "true"', () => {
    expect(payoutsMode(() => undefined)).toBe('dry-run');
    expect(payoutsMode(() => 'TRUE')).toBe('dry-run');
    expect(payoutsMode(() => '1')).toBe('dry-run');
    expect(payoutsMode((k) => (k === 'EXOS_PAYOUTS_LIVE' ? 'true' : undefined))).toBe('live');
  });
});

describe('TEvo remittance', () => {
  it('records the order proceeds (net of TEvo 3%) once TEvo has settled payments', () => {
    const r = tevoRemittanceFor({ external_order_id: '19196777', proceeds: '31.51' }, [pay({})]);
    expect(r).toEqual({
      channel: 'evo', external_id: 'evo-order-19196777', amount: 31.51, currency: 'USD', source: 'marketplace_api',
      reference: 'payment 18582737', received_at: '2026-09-26T13:40:17Z',
      allocations: [{ external_order_id: '19196777', amount: 31.51 }],
    });
  });

  it('records nothing while payments are pending, refunded, unknown, or the order has no proceeds', () => {
    expect(tevoRemittanceFor({ external_order_id: '1', proceeds: 31.51 }, [pay({ state: 'pending' })])).toBeNull();
    expect(tevoRemittanceFor({ external_order_id: '1', proceeds: 31.51 }, [pay({}), pay({ id: 2, is_refund: true, amount: '32.48' })])).toBeNull();
    expect(tevoRemittanceFor({ external_order_id: '1', proceeds: 31.51 }, [pay({ state: 'disputed' })])).toBeNull();
    expect(tevoRemittanceFor({ external_order_id: '1', proceeds: null }, [pay({})])).toBeNull();
    expect(tevoRemittanceFor({ external_order_id: '1', proceeds: 31.51 }, [])).toBeNull();
  });
});

describe('Connect transfer', () => {
  const p = { id: 'p1', org_id: 'o1', currency: 'USD', amount: '116.40', idempotency_key: 'exos-payout-p1' };

  it('pays the organizer in minor units, idempotently, tagged with the payout', () => {
    expect(connectTransfer(p, 'acct_1ABC')).toEqual({
      params: {
        amount: 11640, currency: 'usd', destination: 'acct_1ABC', transfer_group: 'exos-payout-p1',
        description: 'Exos marketplace sales payout', metadata: { exos_payout_id: 'p1', exos_org_id: 'o1' },
      },
      idempotencyKey: 'exos-payout-p1',
    });
  });

  it('refuses anything unsafe to send', () => {
    expect(() => connectTransfer(p, null)).toThrow(/connected Stripe account/);
    expect(() => connectTransfer(p, 'not-an-account')).toThrow(/connected Stripe account/);
    expect(() => connectTransfer({ ...p, amount: 0 }, 'acct_1ABC')).toThrow(/positive/);
    expect(() => connectTransfer({ ...p, currency: 'dollars' }, 'acct_1ABC')).toThrow(/currency/);
  });
});
