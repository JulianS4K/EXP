import { describe, expect, it } from 'vitest';
import {
  feeActualsFromCharge,
  recordFeeActuals,
  withTimeout,
  type ChargeLike,
  type FeeDb,
  type FeeStripe,
} from '../../supabase/functions/_shared/feeActuals.ts';

const CHARGE: ChargeLike = {
  id: 'ch_1',
  amount: 4000,
  application_fee: 'fee_1',
  application_fee_amount: 266,
  transfer: 'tr_1',
  balance_transaction: { id: 'txn_1', fee: 146, net: 3854 },
};

describe('feeActualsFromCharge', () => {
  it('maps a destination charge: Stripe fee, platform net = application fee - Stripe fee', () => {
    expect(feeActualsFromCharge(CHARGE)).toEqual({
      charge_id: 'ch_1',
      balance_txn_id: 'txn_1',
      stripe_fee_cents: 146,
      application_fee_id: 'fee_1',
      application_fee_cents: 266,
      transfer_id: 'tr_1',
      net_cents: 120,
    });
  });

  it('accepts expanded objects and bare ids', () => {
    const a = feeActualsFromCharge({ ...CHARGE, transfer: { id: 'tr_2' }, application_fee: { id: 'fee_2' }, balance_transaction: 'txn_2' });
    expect(a).toMatchObject({ transfer_id: 'tr_2', application_fee_id: 'fee_2', balance_txn_id: 'txn_2', stripe_fee_cents: null, net_cents: null });
  });

  it('falls back to the fee checkout recorded', () => {
    expect(feeActualsFromCharge({ ...CHARGE, application_fee_amount: null }, 250)).toMatchObject({ application_fee_cents: 250, net_cents: 104 });
  });

  it('leaves unknowns null', () => {
    expect(feeActualsFromCharge(null)).toEqual({
      charge_id: null, balance_txn_id: null, stripe_fee_cents: null, application_fee_id: null,
      application_fee_cents: null, transfer_id: null, net_cents: null,
    });
  });
});

// A tiny fake of the supabase-js query builder: .from(t).select().eq().maybeSingle().
function fakeDb(opts: {
  payment?: { fees_recorded_at: string | null } | null;
  paymentError?: { message: string; code?: string };
  sessionFee?: number | null;
  rpcError?: { message: string };
}) {
  const rpcCalls: { fn: string; args: Record<string, unknown> }[] = [];
  const db: FeeDb = {
    from(table: string) {
      const q = {
        select: () => q,
        eq: () => q,
        maybeSingle: async () => {
          if (table === 'exos_order_payments') {
            return opts.paymentError ? { data: null, error: opts.paymentError } : { data: opts.payment ?? null, error: null };
          }
          return { data: { application_fee_cents: opts.sessionFee ?? null }, error: null };
        },
      };
      return q;
    },
    rpc(fn: string, args: Record<string, unknown>) {
      rpcCalls.push({ fn, args });
      return Promise.resolve({ data: true, error: opts.rpcError ?? null });
    },
  };
  return { db, rpcCalls };
}

function fakeStripe(result: () => Promise<{ latest_charge?: string | ChargeLike | null }>) {
  const calls: { id: string; params: { expand: string[] } }[] = [];
  const stripe: FeeStripe = {
    paymentIntents: {
      retrieve: (id, params) => {
        calls.push({ id, params });
        return result();
      },
    },
  };
  return { stripe, calls };
}

const quiet = { log: () => {} };

describe('recordFeeActuals (webhook + reconcile)', () => {
  it('reads the latest charge with its balance transaction and records it', async () => {
    const { db, rpcCalls } = fakeDb({ payment: { fees_recorded_at: null }, sessionFee: 266 });
    const { stripe, calls } = fakeStripe(async () => ({ latest_charge: CHARGE }));
    await expect(recordFeeActuals(db, stripe, 'cs_1', 'pi_1', quiet)).resolves.toBe('recorded');
    expect(calls).toEqual([{ id: 'pi_1', params: { expand: ['latest_charge.balance_transaction'] } }]);
    expect(rpcCalls).toEqual([{
      fn: 'exos_record_payment_fees',
      args: {
        p_payment_intent: 'pi_1', p_charge_id: 'ch_1', p_balance_txn_id: 'txn_1', p_stripe_fee_cents: 146,
        p_application_fee_id: 'fee_1', p_application_fee_cents: 266, p_transfer_id: 'tr_1', p_net_cents: 120,
      },
    }]);
  });

  it('makes no Stripe call on a replay once recorded', async () => {
    const { db, rpcCalls } = fakeDb({ payment: { fees_recorded_at: '2026-09-29T00:00:00Z' } });
    const { stripe, calls } = fakeStripe(async () => ({ latest_charge: CHARGE }));
    await expect(recordFeeActuals(db, stripe, 'cs_1', 'pi_1', quiet)).resolves.toBe('already');
    expect(calls).toHaveLength(0);
    expect(rpcCalls).toHaveLength(0);
  });

  it('never throws when Stripe fails: logs and leaves it for reconcile', async () => {
    const { db, rpcCalls } = fakeDb({ payment: { fees_recorded_at: null } });
    const { stripe } = fakeStripe(async () => { throw new Error('stripe down'); });
    const logged: string[] = [];
    await expect(recordFeeActuals(db, stripe, 'cs_1', 'pi_1', { log: (m) => logged.push(m) })).resolves.toBe('error');
    expect(rpcCalls).toHaveLength(0);
    expect(logged[0]).toMatch(/left for reconcile/);
  });

  it('gives up on a slow Stripe read instead of holding the webhook', async () => {
    const { db } = fakeDb({ payment: { fees_recorded_at: null } });
    const { stripe } = fakeStripe(() => new Promise(() => {}));
    await expect(recordFeeActuals(db, stripe, 'cs_1', 'pi_1', { ...quiet, timeoutMs: 10 })).resolves.toBe('error');
  });

  it('skips before the migration (no fee columns) and when there is no payment row or charge', async () => {
    const { stripe, calls } = fakeStripe(async () => ({ latest_charge: null }));
    expect(await recordFeeActuals(fakeDb({ paymentError: { message: 'column does not exist', code: '42703' } }).db, stripe, 'cs', 'pi', quiet)).toBe('skipped');
    expect(await recordFeeActuals(fakeDb({ payment: null }).db, stripe, 'cs', 'pi', quiet)).toBe('no_payment');
    expect(calls).toHaveLength(0);
    expect(await recordFeeActuals(fakeDb({ payment: { fees_recorded_at: null } }).db, stripe, 'cs', 'pi', quiet)).toBe('no_charge');
  });

  it('reports a failed database write without throwing', async () => {
    const { db } = fakeDb({ payment: { fees_recorded_at: null }, rpcError: { message: 'boom' } });
    const { stripe } = fakeStripe(async () => ({ latest_charge: CHARGE }));
    await expect(recordFeeActuals(db, stripe, 'cs_1', 'pi_1', quiet)).resolves.toBe('error');
  });
});

describe('withTimeout', () => {
  it('passes a fast result through and rejects a slow one', async () => {
    await expect(withTimeout(Promise.resolve(7), 50)).resolves.toBe(7);
    await expect(withTimeout(new Promise(() => {}), 5, 'slow')).rejects.toThrow('slow after 5ms');
  });
});
