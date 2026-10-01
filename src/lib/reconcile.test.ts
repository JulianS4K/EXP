// Daily Stripe reconciliation diff (supabase/functions/_shared/reconcile.ts, mig 20261001101000).
import { describe, it, expect } from 'vitest';
import {
  reconcile, reconcileWindow, txnRow, isDisputeTxn,
  type ExosPaymentRow, type ExosRefundRow, type StripeTxnRow,
} from '../../supabase/functions/_shared/reconcile.ts';

const FROM = '2026-09-27T00:00:00.000Z';
const TO = '2026-09-30T00:00:00.000Z';
const MID = '2026-09-28T12:00:00.000Z';

const txn = (over: Partial<StripeTxnRow>): StripeTxnRow => ({
  id: 'txn_x', type: 'charge', reporting_category: 'charge', amount_cents: 5000, fee_cents: 175, net_cents: 4825,
  currency: 'usd', source_id: 'ch_1', payment_intent: 'pi_1', status: 'available', created: MID, available_on: null, ...over,
});
const pay = (over: Partial<ExosPaymentRow>): ExosPaymentRow => ({
  session_id: 'cs_1', org_id: 'org1', payment_intent: 'pi_1', charge_id: 'ch_1', balance_txn_id: 'txn_c1',
  amount_cents: 5000, currency: 'usd', status: 'succeeded', stripe_fee_cents: 175, created_at: MID, ...over,
});
const ref = (over: Partial<ExosRefundRow>): ExosRefundRow => ({
  session_id: 'cs_1', org_id: 'org1', refund_id: 're_1', amount_cents: 1000, currency: 'usd', status: 'succeeded',
  created_at: MID, ...over,
});
const run = (txns: StripeTxnRow[], payments: ExosPaymentRow[] = [], refunds: ExosRefundRow[] = [], disputes = [] as { dispute_id: string; session_id: string | null; org_id: string | null }[]) =>
  reconcile({ txns, payments, refunds, disputes, from: FROM, to: TO });

describe('txnRow', () => {
  it('maps a balance transaction with an expanded source', () => {
    const r = txnRow({
      id: 'txn_1', type: 'charge', reporting_category: 'charge', amount: 5000, fee: 175, net: 4825, currency: 'USD',
      status: 'available', created: 1790000000, available_on: 1790100000,
      source: { id: 'ch_1', object: 'charge', payment_intent: 'pi_1' },
    });
    expect(r).toEqual({
      id: 'txn_1', type: 'charge', reporting_category: 'charge', amount_cents: 5000, fee_cents: 175, net_cents: 4825,
      currency: 'usd', source_id: 'ch_1', payment_intent: 'pi_1', status: 'available',
      created: new Date(1790000000 * 1000).toISOString(), available_on: new Date(1790100000 * 1000).toISOString(),
    });
  });
  it('keeps an unexpanded source id and drops unusable rows', () => {
    expect(txnRow({ id: 'txn_2', type: 'refund', amount: -100, created: 1790000000, source: 're_1' })?.source_id).toBe('re_1');
    expect(txnRow({ id: 'txn_2', type: 'refund', amount: -100, created: 1790000000, source: 're_1' })?.payment_intent).toBeNull();
    expect(txnRow({ id: 'bad id', created: 1790000000 })).toBeNull();
    expect(txnRow({ id: 'txn_3' })).toBeNull();
  });
  it('recognizes dispute movements', () => {
    expect(isDisputeTxn(txn({ type: 'adjustment', reporting_category: 'dispute', source_id: 'du_1' }))).toBe(true);
    expect(isDisputeTxn(txn({ type: 'adjustment', reporting_category: null, source_id: 'dp_1' }))).toBe(true);
    expect(isDisputeTxn(txn({ type: 'adjustment', reporting_category: 'other_adjustment', source_id: 'ia_1' }))).toBe(false);
  });
});

describe('reconcile', () => {
  it('a clean day has no issues', () => {
    const { issues, stats } = run(
      [txn({ id: 'txn_c1' }), txn({ id: 'txn_r1', type: 'refund', reporting_category: 'refund', amount_cents: -1000, fee_cents: 0, source_id: 're_1' }),
        txn({ id: 'txn_t1', type: 'transfer', reporting_category: 'transfer', amount_cents: -4500, source_id: 'tr_1' }),
        txn({ id: 'txn_d1', type: 'adjustment', reporting_category: 'dispute', amount_cents: -5000, fee_cents: 1500, source_id: 'du_1' })],
      [pay({})], [ref({})], [{ dispute_id: 'du_1', session_id: 'cs_1', org_id: 'org1' }],
    );
    expect(issues).toEqual([]);
    expect(stats).toMatchObject({ txns: 4, charges: 1, refunds: 1, disputes: 1, other: 1, matched_payments: 1, matched_refunds: 1, matched_disputes: 1, issues: 0 });
  });

  it('matches a payment by charge id, balance transaction id or PaymentIntent', () => {
    expect(run([txn({ id: 'txn_c1', source_id: 'ch_9', payment_intent: null })], [pay({})]).issues).toEqual([]);
    expect(run([txn({ id: 'txn_zz', payment_intent: null })], [pay({ balance_txn_id: null })]).issues).toEqual([]);
    expect(run([txn({ id: 'txn_zz', source_id: 'ch_new' })], [pay({ charge_id: null, balance_txn_id: null })]).issues).toEqual([]);
  });

  it('Stripe charge with no Exos payment', () => {
    const { issues } = run([txn({ id: 'txn_o', source_id: 'ch_orphan', payment_intent: 'pi_orphan', amount_cents: 900 })]);
    expect(issues).toEqual([{
      kind: 'stripe_payment_missing', key: 'ch_orphan', stripe_id: 'ch_orphan', session_id: null, org_id: null, occurred_at: MID,
      detail: { txn: 'txn_o', type: 'charge', amount_cents: 900, fee_cents: 175, currency: 'usd', payment_intent: 'pi_orphan' },
    }]);
  });

  it('amount, currency, fee and status mismatches', () => {
    const { issues } = run([txn({ id: 'txn_c1', amount_cents: 5100, fee_cents: 180 })], [pay({ status: 'processing' })]);
    expect(issues.map((i) => i.kind)).toEqual(['amount_mismatch', 'fee_mismatch', 'payment_status_mismatch']);
    const amount = issues.find((i) => i.kind === 'amount_mismatch')!;
    expect(amount).toMatchObject({ key: 'ch_1', session_id: 'cs_1', org_id: 'org1' });
    expect(amount.detail).toEqual({ txn: 'txn_c1', stripe_amount_cents: 5100, stripe_currency: 'usd', exos_amount_cents: 5000, exos_currency: 'usd' });
    expect(run([txn({ id: 'txn_c1', currency: 'eur' })], [pay({})]).issues.map((i) => i.kind)).toEqual(['amount_mismatch']);
  });

  it('no fee recorded yet is not a fee mismatch', () => {
    expect(run([txn({ id: 'txn_c1', fee_cents: 999 })], [pay({ stripe_fee_cents: null })]).issues).toEqual([]);
  });

  it('Exos payment with no Stripe charge, only inside the checked window', () => {
    const { issues } = run([], [
      pay({ session_id: 'cs_in', payment_intent: 'pi_in', charge_id: null }),
      pay({ session_id: 'cs_edge', payment_intent: 'pi_edge', created_at: '2026-09-27T00:30:00.000Z' }),  // inside the 1 h margin
      pay({ session_id: 'cs_late', payment_intent: 'pi_late', created_at: '2026-09-29T23:30:00.000Z' }),   // inside the end margin
      pay({ session_id: 'cs_free', payment_intent: null, amount_cents: 0 }),
      pay({ session_id: 'cs_fail', payment_intent: 'pi_fail', status: 'failed' }),
    ]);
    expect(issues).toEqual([{
      kind: 'exos_payment_missing', key: 'pi_in', stripe_id: 'pi_in', session_id: 'cs_in', org_id: 'org1', occurred_at: MID,
      detail: { amount_cents: 5000, currency: 'usd', charge_id: null },
    }]);
  });

  it('refunds: missing either side, amount mismatch', () => {
    const { issues } = run(
      [txn({ id: 'txn_r1', type: 'refund', amount_cents: -1500, fee_cents: 0, source_id: 're_1' }),
        txn({ id: 'txn_r2', type: 'payment_refund', amount_cents: -700, fee_cents: 0, source_id: 're_2', payment_intent: 'pi_1' })],
      [pay({})],
      [ref({}), ref({ refund_id: 're_3', created_at: MID }), ref({ refund_id: 're_4', status: 'pending' })],
    );
    expect(issues.map((i) => [i.kind, i.key])).toEqual([
      ['exos_refund_missing', 're_3'],
      ['exos_payment_missing', 'pi_1'],
      ['refund_amount_mismatch', 're_1'],
      ['stripe_refund_missing', 're_2'],
    ].sort((a, b) => a[0].localeCompare(b[0]) || a[1].localeCompare(b[1])));
    expect(issues.find((i) => i.key === 're_2')).toMatchObject({ session_id: 'cs_1', org_id: 'org1', detail: { amount_cents: 700 } });
  });

  it('dispute money with no Exos dispute row, once per dispute', () => {
    const { issues } = run([
      txn({ id: 'txn_d1', type: 'adjustment', reporting_category: 'dispute', amount_cents: -5000, fee_cents: 1500, source_id: 'du_9' }),
      txn({ id: 'txn_d2', type: 'adjustment', reporting_category: 'dispute_reversal', amount_cents: 5000, fee_cents: 0, source_id: 'du_9' }),
    ]);
    expect(issues).toHaveLength(1);
    expect(issues[0]).toMatchObject({ kind: 'stripe_dispute_missing', key: 'du_9', stripe_id: 'du_9', org_id: null });
  });

  it('output is sorted and counted by kind', () => {
    const { issues, stats } = run([txn({ id: 't1', source_id: 'ch_b' }), txn({ id: 't2', source_id: 'ch_a' })]);
    expect(issues.map((i) => i.key)).toEqual(['ch_a', 'ch_b']);
    expect(stats.by_kind).toEqual({ stripe_payment_missing: 2 });
    expect(stats.issues).toBe(2);
  });
});

describe('reconcileWindow', () => {
  it('last N days, clamped to 1..90', () => {
    const now = new Date('2026-09-30T06:00:00Z');
    expect(reconcileWindow(now, 3)).toEqual({ from: '2026-09-27T06:00:00.000Z', to: '2026-09-30T06:00:00.000Z' });
    expect(reconcileWindow(now, 0).from).toBe('2026-09-29T06:00:00.000Z');
    expect(reconcileWindow(now, 1000).from).toBe(new Date(now.getTime() - 90 * 86_400_000).toISOString());
  });
});
