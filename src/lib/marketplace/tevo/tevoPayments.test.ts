import { describe, expect, it, vi } from 'vitest';
import {
  TEVO_ENDPOINTS,
  TevoClient,
  TevoWriteRefusedError,
  TevoWriter,
  normalizeTevoPayment,
  normalizeTevoPaymentStatus,
  summarizeTevoPayments,
  tevoAmountCents,
  tevoFeeCheck,
  tevoSellerFeeCents,
  TEVO_SELLER_FEE_BPS,
  type TevoWriteAuthorization,
} from '.';

const CREDS = { token: 'tok-SECRET-123', secret: 'sec-SECRET-456' };

describe('TEvo payments: read only', () => {
  it('moving money is never sendable, including the GETs that change state', () => {
    for (const k of ['createPayment', 'applyPayment', 'cancelPayment', 'refundPayment'] as const) {
      expect(TEVO_ENDPOINTS[k].access).toBe('forbidden');
    }
    expect(TEVO_ENDPOINTS.applyPayment.method).toBe('GET');
    expect(TEVO_ENDPOINTS.cancelPayment.method).toBe('GET');
    for (const k of ['listPayments', 'showPayment', 'paymentsStatus'] as const) expect(TEVO_ENDPOINTS[k]).toMatchObject({ method: 'GET', access: 'read' });
    const auth: TevoWriteAuthorization = { approvedBy: 'op', approvedAt: '2026-09-28T00:00:00Z', reference: 'test', endpoints: ['refundPayment' as never] };
    expect(() => new TevoWriter({ mode: { mode: 'live', authorization: auth }, credentials: () => CREDS })).toThrow(TevoWriteRefusedError);
  });

  it('lists an order\'s payments with a signed GET and the order id', async () => {
    const urls: string[] = [];
    const fetchImpl = vi.fn(async (url: string) => {
      urls.push(url);
      return new Response(JSON.stringify({ current_page: 1, payments: [{ id: 14806, order_link_id: 75155, type: 'cash', state: 'completed', amount: '15.0' }] }), { status: 200 });
    });
    const c = new TevoClient({ credentials: () => CREDS, fetch: fetchImpl });
    const ps = await c.listPayments(75155);
    expect(ps.map((p) => p.id)).toEqual([14806]);
    expect(urls[0]).toBe('https://api.sandbox.ticketevolution.com/v9/payments?order_id=75155');
    await expect(c.listPayments('75155&x=1')).rejects.toThrow(/order_id/);
    expect(fetchImpl).toHaveBeenCalledTimes(1);
  });
});

describe('TEvo payments: normalized', () => {
  it('parses amounts exactly', () => {
    expect(tevoAmountCents('15.0')).toBe(1500);
    expect(tevoAmountCents('299.0')).toBe(29900);
    expect(tevoAmountCents('1,299.5')).toBe(129950);
    expect(tevoAmountCents(0.1 + 0.2)).toBe(30);
    expect(tevoAmountCents('-20.00')).toBe(-2000);
    expect(tevoAmountCents('abc')).toBeNull();
    expect(tevoAmountCents(null)).toBeNull();
  });

  it('keeps ids, type, state and money; drops card, address checks and names', () => {
    const p = normalizeTevoPayment({
      id: 504536, order_link_id: 649766, type: 'credit_card', state: 'captured', amount: '299.0', is_refund: false,
      credit_card: { last_digits: '4242' }, avs_response: 'Y', cvv_response: 'M', avs_postal_code_response: 'M', performed_by: { name: 'Alice' },
      created_at: '2014-08-04T19:11:33Z', updated_at: '2014-08-04T19:11:33Z',
    });
    expect(p).toEqual({
      payment_id: '504536', order_id: '649766', type: 'credit_card', state: 'captured', amount_cents: 29900, is_refund: false,
      refunded_from_id: null, created_at: '2014-08-04T19:11:33Z', updated_at: '2014-08-04T19:11:33Z',
    });
    const s = normalizeTevoPaymentStatus({
      id: 30496, order_link_id: 96060, transaction_type: 'EvopayTransaction', transaction_state: 'pending',
      payment_amount: '128.0', buyer_name: 'Alice Smith', seller_name: 'Ticket King - WI', buyer_type: 'Client',
    });
    expect(s).toMatchObject({ payment_id: '30496', order_id: '96060', type: 'EvopayTransaction', state: 'pending', amount_cents: 12800 });
    expect(JSON.stringify(s)).not.toMatch(/Alice|Ticket King/);
  });

  it('sums what was actually paid: settled in, settled refunds out, pending apart', () => {
    const n = (over: Record<string, unknown>) => normalizeTevoPayment({ id: 1, amount: '100.00', state: 'completed', ...over });
    expect(summarizeTevoPayments([
      n({}), n({ state: 'captured', amount: '50' }), n({ is_refund: true, amount: '20.00' }), n({ state: 'pending', amount: '30' }),
      n({ state: 'cancelled', amount: '999' }), n({ state: 'disputed', amount: '5' }),
    ])).toEqual({ paid_cents: 13000, pending_cents: 3000, refunded_cents: 2000, unknown_states: ['disputed'] });
  });
});

describe("TEvo's seller fee: 3% of the order total, nearest cent, half up", () => {
  it('matches the five real S4K orders and the half-cent case', () => {
    expect(TEVO_SELLER_FEE_BPS).toBe(300);
    // [oid, total, fee] from TEvo (2026-09-26).
    const real: Array<[string, string, string]> = [
      ['8089940-19196777', '32.48', '0.97'],
      ['8090084-19197170', '957.6', '28.73'],
      ['8090220-19197528', '225.56', '6.77'],
      ['8090321-19197809', '464.96', '13.95'],
      ['8090482-19198241', '4.48', '0.13'],
    ];
    for (const [oid, total, fee] of real) {
      expect(tevoSellerFeeCents(tevoAmountCents(total)!), oid).toBe(tevoAmountCents(fee));
      expect(tevoFeeCheck({ total, fee }), oid).toMatchObject({ matches_standard: true, used_fee_cents: tevoAmountCents(fee) });
    }
    expect(tevoSellerFeeCents(2150)).toBe(65); // 0.645 -> 0.65
    expect(tevoSellerFeeCents(0)).toBe(0);
  });

  it('flags a fee that is not 3%, and falls back to 3% when the order has none', () => {
    expect(tevoFeeCheck({ total: '100.00', fee: '5.00' })).toEqual({
      total_cents: 10000, fee_cents: 500, expected_fee_cents: 300, used_fee_cents: 500, matches_standard: false,
    });
    expect(tevoFeeCheck({ total: '100.00' })).toMatchObject({ fee_cents: null, used_fee_cents: 300, matches_standard: true });
  });
});
