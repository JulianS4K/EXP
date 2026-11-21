import { describe, expect, it } from 'vitest';
import { readFileSync } from 'node:fs';
import path from 'node:path';
import {
  JOURNAL_ACCOUNTS, JOURNAL_CSV_HEADER, jurisdictionLabel, journalCsvRows, periodBounds, SALES_TAX_CSV_HEADER, salesTaxCsvRows,
  salesTaxTotals, sourceLabel, summarizeTrialBalance, taxRateLabel, unbalancedEntries, type JournalLineRow, type SalesTaxRow,
  type TrialBalanceRow,
} from './journal';
import { toCsv } from './csv';

// The chart and the account check were last redefined here; the source check in SRC_MIG.
const MIG = readFileSync(path.resolve(__dirname, '../../supabase/migrations/20261110100000_exos_journal_complete.sql'), 'utf8');
const SRC_MIG = readFileSync(path.resolve(__dirname, '../../supabase/migrations/20261111130000_exos_journal_payouts_tax.sql'), 'utf8');
const API = readFileSync(path.resolve(__dirname, '../../supabase/functions/exos-api/journal.ts'), 'utf8');

describe('the chart', () => {
  it('matches exos_journal_accounts() in the migration', () => {
    const rows = [...MIG.matchAll(/\('([a-z_]+)',\s+(\d{4}), '([^']+)',\s+'([a-z_]+)',\s+'(debit|credit)'\)/g)]
      .map((m) => ({ code: m[1], number: Number(m[2]), name: m[3], type: m[4], normal: m[5] }));
    expect(rows).toEqual(JOURNAL_ACCOUNTS.map((a) => ({ ...a })));
  });

  it('matches the account check and the API filter', () => {
    const ok = MIG.match(/SELECT p_code IN \(([^)]+)\)/)?.[1] ?? '';
    const sqlCodes = [...ok.matchAll(/'([a-z_]+)'/g)].map((m) => m[1]);
    expect(sqlCodes).toEqual(JOURNAL_ACCOUNTS.map((a) => a.code));
    const api = API.match(/JOURNAL_ACCOUNTS = \[([\s\S]*?)\] as const/)?.[1] ?? '';
    expect([...api.matchAll(/"([a-z_]+)"/g)].map((m) => m[1])).toEqual(JOURNAL_ACCOUNTS.map((a) => a.code));
  });

  it('matches the source check and the API source filter', () => {
    const chk = SRC_MIG.match(/exos_journal_entries_source_table_check CHECK \(source_table IN \(([^)]+)\)/)?.[1] ?? '';
    const sql = [...chk.matchAll(/'exos_([a-z_]+)'/g)].map((m) => m[1]);
    const api = API.match(/JOURNAL_SOURCES = \[([\s\S]*?)\] as const/)?.[1] ?? '';
    expect(sql.length).toBe(16);
    expect([...api.matchAll(/"([a-z_]+)"/g)].map((m) => m[1])).toEqual(sql);
    for (const t of sql) expect(sourceLabel(`exos_${t}`)).not.toBe(t.replace(/_/g, ' '));   // a label of its own
  });

  it('has unique codes and numbers, and normal sides that follow the type', () => {
    expect(new Set(JOURNAL_ACCOUNTS.map((a) => a.code)).size).toBe(JOURNAL_ACCOUNTS.length);
    expect(new Set(JOURNAL_ACCOUNTS.map((a) => a.number)).size).toBe(JOURNAL_ACCOUNTS.length);
    for (const a of JOURNAL_ACCOUNTS) {
      expect(a.normal).toBe(['asset', 'expense', 'contra_revenue'].includes(a.type) ? 'debit' : 'credit');
    }
  });
});

describe('summarizeTrialBalance', () => {
  const tb = (account: string, debit: number, credit: number, currency = 'usd'): TrialBalanceRow => ({
    account, account_number: 0, account_name: account, account_type: 'x', currency, debit_cents: debit, credit_cents: credit,
    balance_cents: debit - credit,
  });

  it('balances, orders by the chart and reads the normal side', () => {
    const [t] = summarizeTrialBalance([
      tb('ticket_revenue', 0, 9400), tb('stripe_clearing', 10000, 500), tb('exos_fee', 300, 0), tb('card_fees', 200, 0),
      tb('sales_tax_payable', 0, 800), tb('refunds', 1000, 0), tb('buyer_fees', 0, 300), tb('stripe_clearing', 0, 1000),
    ]);
    expect(t.currency).toBe('USD');
    expect(t.lines.map((l) => l.account)).toEqual([
      'stripe_clearing', 'stripe_clearing', 'sales_tax_payable', 'ticket_revenue', 'buyer_fees', 'refunds', 'exos_fee', 'card_fees',
    ]);
    expect(t.debitCents).toBe(11500);
    expect(t.creditCents).toBe(12000);
    expect(t.balanced).toBe(false);
    expect(t.lines.find((l) => l.account === 'ticket_revenue')?.normalCents).toBe(9400);
    expect(t.lines.find((l) => l.account === 'refunds')?.normalCents).toBe(1000);
    // Revenue 9400 + 300 − refunds 1000 = 8700; expenses 500.
    expect(t.netRevenueCents).toBe(8700);
    expect(t.expenseCents).toBe(500);
    expect(t.netCents).toBe(8200);
  });

  it('splits currencies and takes string cents (bigint from PostgREST)', () => {
    const out = summarizeTrialBalance([
      { ...tb('stripe_clearing', 0, 0, 'eur'), debit_cents: '500', credit_cents: '0' },
      { ...tb('ticket_revenue', 0, 0, 'eur'), debit_cents: '0', credit_cents: '500' },
      tb('pos_cash_drawer', 100, 0), tb('pos_other_sales', 0, 100),
    ]);
    expect(out.map((t) => [t.currency, t.balanced, t.debitCents])).toEqual([['EUR', true, 500], ['USD', true, 100]]);
  });

  it('is empty for no rows', () => {
    expect(summarizeTrialBalance([])).toEqual([]);
  });
});

describe('journal CSV', () => {
  const line = (entry: string, n: number, no: number, account: string, debit: number, credit: number, at = '2026-11-07T18:02:11Z'): JournalLineRow => ({
    line_id: `${entry}-${no}`, entry_id: entry, entry_number: n, occurred_at: at, currency: 'usd', source_table: 'exos_checkout_sessions',
    source_id: 'cs_1', kind: 'sale', account, debit_cents: debit, credit_cents: credit, memo: no === 1 ? '=HYPERLINK("x")' : null, line_no: no,
  });

  it('one row per line, in entry and line order, amounts as decimals', () => {
    const rows = journalCsvRows([
      line('e2', 8, 1, 'refunds', 1000, 0, '2026-11-08T10:00:00Z'),
      line('e1', 7, 2, 'ticket_revenue', 0, 9100),
      line('e1', 7, 1, 'stripe_clearing', 9100, 0),
    ]);
    expect(rows.map((r) => [r[1], r[6], r[8], r[9]])).toEqual([
      ['e1', 1000, '91.00', ''], ['e1', 4000, '', '91.00'], ['e2', 4900, '10.00', ''],
    ]);
    expect(rows[0][0]).toBe('2026-11-07');
    expect(rows[0][3]).toBe('Order');
    expect(rows[0][7]).toBe('Cash at Stripe / clearing');
    expect(rows[0][10]).toBe('USD');
    // The CSV helper neutralises a formula in the memo.
    expect(toCsv(JOURNAL_CSV_HEADER, rows).split('\r\n')[1]).toContain(`"'=HYPERLINK(""x"")"`);
    expect(JOURNAL_CSV_HEADER).toEqual(['date', 'entry_id', 'entry_number', 'source', 'source_id', 'kind', 'account_number', 'account',
      'debit', 'credit', 'currency', 'memo']);
  });

  it('finds unbalanced entries', () => {
    expect(unbalancedEntries([line('e1', 1, 1, 'stripe_clearing', 100, 0), line('e1', 1, 2, 'ticket_revenue', 0, 100)])).toEqual([]);
    expect(unbalancedEntries([line('e1', 1, 1, 'stripe_clearing', 100, 0), line('e1', 1, 2, 'ticket_revenue', 0, 99)]))
      .toEqual([{ entryId: 'e1', diffCents: 1 }]);
  });

  it('labels sources', () => {
    expect(sourceLabel('exos_order_refunds')).toBe('Refund');
    expect(sourceLabel('exos_pos_paid_outs')).toBe('Door cash out');
    expect(sourceLabel('exos_something_new')).toBe('something new');
  });
});

describe('sales tax', () => {
  const row = (o: Partial<SalesTaxRow>): SalesTaxRow => ({
    country: 'US', region: 'NY', city: 'Brooklyn', postal_code: '11211', tax_name: 'NY sales tax', rate_percent: 8.875,
    source: 'online', currency: 'USD', orders: 2, taxable_cents: 8300, tax_collected_cents: 800, tax_refunded_cents: 266,
    net_tax_cents: 534, ...o,
  });

  it('labels jurisdictions and rates', () => {
    expect(jurisdictionLabel(row({}))).toBe('Brooklyn, NY 11211, US');
    expect(jurisdictionLabel(row({ city: null, postal_code: null }))).toBe('NY, US');
    expect(jurisdictionLabel(row({ country: null, region: null, city: null, postal_code: null }))).toBe('Location not set');
    expect(taxRateLabel(row({}))).toBe('NY sales tax (8.875%)');
    expect(taxRateLabel(row({ tax_name: null, source: 'pos' }))).toBe('8.875% (door)');
    expect(taxRateLabel(row({ tax_name: null, rate_percent: null }))).toBe('Rate not recorded');
    expect(taxRateLabel(row({ rate_percent: '6.625', tax_name: null }))).toBe('6.625%');
  });

  it('CSV rows and totals per currency', () => {
    const rows = [row({}), row({ region: 'NJ', tax_name: null, rate_percent: null, tax_collected_cents: 50, tax_refunded_cents: 0, net_tax_cents: 50 }),
      row({ currency: 'eur', tax_collected_cents: 100, tax_refunded_cents: 0, net_tax_cents: 100 })];
    const csv = salesTaxCsvRows(rows);
    expect(csv[0]).toEqual(['US', 'NY', 'Brooklyn', '11211', 'NY sales tax', '8.875', 'online', 'USD', 2, '83.00', '8.00', '2.66', '5.34']);
    expect(csv[1][4]).toBe('');
    expect(csv[1][5]).toBe('');
    expect(SALES_TAX_CSV_HEADER).toHaveLength(csv[0].length);
    expect(salesTaxTotals(rows)).toEqual([
      { currency: 'EUR', collectedCents: 100, refundedCents: 0, netCents: 100 },
      { currency: 'USD', collectedCents: 850, refundedCents: 266, netCents: 584 },
    ]);
  });
});

describe('periodBounds', () => {
  it('turns inclusive days into [from, to) in UTC', () => {
    expect(periodBounds('2026-11-01', '2026-11-30')).toEqual({ from: '2026-11-01T00:00:00.000Z', to: '2026-12-01T00:00:00.000Z' });
    expect(periodBounds('2026-12-31', '2026-12-31')).toEqual({ from: '2026-12-31T00:00:00.000Z', to: '2027-01-01T00:00:00.000Z' });
  });

  it('leaves an empty or bad day unbounded', () => {
    expect(periodBounds('', '')).toEqual({ from: null, to: null });
    expect(periodBounds('2026-13-01', 'nope')).toEqual({ from: null, to: null });
  });
});
