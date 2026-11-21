// Stripe's payouts from a connected account (supabase/functions/_shared/payouts/orgPayouts.ts, mig 20261111130000).
import { describe, expect, it } from 'vitest';
import { readFileSync } from 'node:fs';
import path from 'node:path';
import {
  connectedAccountId, orgPayoutRow, PAYOUT_LOOKBACK_DAYS, payoutCreatedRange, payoutsSyncEnabled,
} from '../../../supabase/functions/_shared/payouts/orgPayouts';

const T = 1_762_000_000; // unix seconds

describe('orgPayoutRow', () => {
  const po = { id: 'po_1AbC', object: 'payout', amount: 12345, currency: 'USD', status: 'paid', method: 'standard',
    automatic: true, failure_code: null, created: T, arrival_date: T + 86_400 };

  it('maps a Stripe payout', () => {
    expect(orgPayoutRow(po)).toEqual({
      id: 'po_1AbC', amount: 12345, currency: 'usd', status: 'paid', method: 'standard', automatic: true,
      failure_code: null, created: new Date(T * 1000).toISOString(), arrival_date: new Date((T + 86_400) * 1000).toISOString(),
    });
  });

  it('keeps a negative payout (a debit from the bank) and a failure code', () => {
    const r = orgPayoutRow({ ...po, amount: -500, status: 'failed', failure_code: 'account_closed', method: 'instant' });
    expect(r?.amount).toBe(-500);
    expect(r?.failure_code).toBe('account_closed');
    expect(r?.method).toBe('instant');
  });

  it('refuses anything that is not a usable payout', () => {
    expect(orgPayoutRow({ ...po, id: 'tr_1' })).toBeNull();
    expect(orgPayoutRow({ ...po, id: 'po_1; drop' })).toBeNull();
    expect(orgPayoutRow({ ...po, object: 'transfer' })).toBeNull();
    expect(orgPayoutRow({ ...po, amount: 12.5 })).toBeNull();
    expect(orgPayoutRow({ ...po, amount: '100' })).toBeNull();
    expect(orgPayoutRow({ ...po, currency: 'us' })).toBeNull();
    expect(orgPayoutRow({ ...po, status: 'reversed' })).toBeNull();
    expect(orgPayoutRow({ ...po, created: 0 })).toBeNull();
    expect(orgPayoutRow(null as never)).toBeNull();
  });

  it('drops a failure code it would not store, and defaults the method', () => {
    const r = orgPayoutRow({ ...po, failure_code: 'Bad Code!', method: undefined, automatic: 'yes', arrival_date: null });
    expect(r?.failure_code).toBeNull();
    expect(r?.method).toBe('standard');
    expect(r?.automatic).toBeNull();
    expect(r?.arrival_date).toBeNull();
  });
});

describe('connectedAccountId', () => {
  it('reads the org secrets shape', () => {
    expect(connectedAccountId({ connectedAccountId: 'acct_1Xy', chargesEnabled: true })).toBe('acct_1Xy');
    expect(connectedAccountId({ connectedAccountId: 'cus_1' })).toBeNull();
    expect(connectedAccountId({})).toBeNull();
    expect(connectedAccountId(null)).toBeNull();
  });
});

describe('payoutCreatedRange', () => {
  it('reaches back before the window so a payout is read until it settles', () => {
    const r = payoutCreatedRange('2026-11-06T00:00:00.000Z', '2026-11-09T00:00:00.000Z');
    expect(r.lt).toBe(Date.parse('2026-11-09T00:00:00.000Z') / 1000);
    expect(r.gte).toBe(Date.parse('2026-11-06T00:00:00.000Z') / 1000 - PAYOUT_LOOKBACK_DAYS * 86_400);
    expect(payoutCreatedRange('2026-11-06T00:00:00.000Z', '2026-11-09T00:00:00.000Z', 999).gte)
      .toBe(Date.parse('2026-11-06T00:00:00.000Z') / 1000 - 60 * 86_400);
  });
});

describe('payoutsSyncEnabled', () => {
  it('is on unless switched off', () => {
    expect(payoutsSyncEnabled(() => undefined)).toBe(true);
    expect(payoutsSyncEnabled(() => 'OFF')).toBe(false);
    expect(payoutsSyncEnabled(() => 'on')).toBe(true);
  });
});

describe('the reconcile function stays read-only at Stripe', () => {
  const fn = readFileSync(path.resolve(__dirname, '../../../supabase/functions/exos-reconcile-stripe/index.ts'), 'utf8');
  it('only lists', () => {
    const calls = [...fn.matchAll(/stripe\.([a-zA-Z]+)\.([a-zA-Z]+)\(/g)].map((m) => `${m[1]}.${m[2]}`);
    expect(calls.sort()).toEqual(['balanceTransactions.list', 'payouts.list']);
  });
});
