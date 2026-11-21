import { describe, expect, it } from 'vitest';
import { journalWorkbook, salesTaxSheet, settlementWorkbook, trialBalanceSheet } from './financeWorkbooks';
import { SETTLEMENT_CSV_HEADER, summarizeSettlement } from './settlement';
import { JOURNAL_CSV_HEADER } from './journal';
import { buildXlsx } from './xlsx';

describe('finance workbooks', () => {
  it('settlement: Summary + Orders, amounts in money columns', () => {
    const s = summarizeSettlement({ orders: [], currency: 'usd' });
    const wb = settlementWorkbook(s, [['exos', 'cs_1', 'fulfilled', '2026-09-20', 'USD', 2, '40.00', '0.00', '0.00', '2.00', '1.46', 'estimate', '36.54', '36.54', 'pi_1', '', '']]);
    expect(wb.map((x) => x.name)).toEqual(['Summary', 'Orders']);
    expect(wb[0].rows).toContainEqual(['Gross', 0]);
    expect(wb[1].header).toEqual(SETTLEMENT_CSV_HEADER);
    const gross = SETTLEMENT_CSV_HEADER.indexOf('gross');
    expect(wb[1].moneyColumns).toContain(gross);
    expect(wb[1].moneyColumns).not.toContain(SETTLEMENT_CSV_HEADER.indexOf('tickets'));
    expect(buildXlsx(wb).length).toBeGreaterThan(500);
  });

  it('sales tax: the CSV rows, money columns named', () => {
    const sh = salesTaxSheet([{ country: 'US', region: 'NY', city: 'Brooklyn', postal_code: '11211', tax_name: 'NYC', rate_percent: '8.875',
      source: 'online', currency: 'usd', orders: 3, taxable_cents: 10000, tax_collected_cents: 888, tax_refunded_cents: 0, net_tax_cents: 888 }]);
    expect(sh.rows[0]).toEqual(['US', 'NY', 'Brooklyn', '11211', 'NYC', '8.875', 'online', 'USD', 3, '100.00', '8.88', '0.00', '8.88']);
    expect(sh.moneyColumns).toEqual([9, 10, 11, 12]);
  });

  it('journal: lines, trial balance with a total per currency, sales tax', () => {
    const tb = trialBalanceSheet([
      { account: 'stripe_clearing', account_number: 1010, account_name: 'Stripe clearing', account_type: 'asset', currency: 'usd',
        debit_cents: 5000, credit_cents: 0, balance_cents: 5000 },
      { account: 'ticket_revenue', account_number: 4000, account_name: 'Ticket revenue', account_type: 'revenue', currency: 'usd',
        debit_cents: 0, credit_cents: 5000, balance_cents: -5000 },
    ]);
    expect(tb.rows[tb.rows.length - 1]).toEqual(['USD', '', 'Total', '', 50, 50, 0]);
    expect(tb.rows).toHaveLength(3);
    const wb = journalWorkbook([['2026-11-01', 'je_1', 1, 'checkout_sessions', 'cs_1', 'sale', 1010, 'Stripe clearing', '50.00', '0.00', 'USD', '']], [], []);
    expect(wb.map((x) => x.name)).toEqual(['Journal', 'Trial balance', 'Sales tax']);
    expect(wb[0].moneyColumns).toEqual([JOURNAL_CSV_HEADER.indexOf('debit'), JOURNAL_CSV_HEADER.indexOf('credit')]);
  });
});
