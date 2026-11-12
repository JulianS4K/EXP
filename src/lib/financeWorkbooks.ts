// XLSX workbooks of the existing money reports (claude/exos-attendance-report):
// the event settlement, sales tax by jurisdiction and the org's journal. Each
// sheet is the same rows as its CSV (src/lib/settlement.ts, src/lib/journal.ts),
// with amounts as numbers in a 0.00 format instead of text. Pure (vitest:
// financeWorkbooks.test.ts); the buttons build them through saveXlsx.

// Types only from ./xlsx: the writer itself is loaded on the click (xlsxDownload.ts).
import type { XlsxSheet } from './xlsx';
import { SETTLEMENT_CSV_HEADER, centsToDecimal, type Settlement } from './settlement';
import {
  JOURNAL_CSV_HEADER, SALES_TAX_CSV_HEADER, salesTaxCsvRows, summarizeTrialBalance,
  type SalesTaxRow, type TrialBalanceRow,
} from './journal';
import type { CsvCell } from './csv';

const SETTLEMENT_MONEY = ['gross', 'tax', 'refunded', 'exos_fee', 'card_fee', 'organizer_net', 'organizer_net_after_refunds'];
const SALES_TAX_MONEY = ['taxable', 'tax_collected', 'tax_refunded', 'net_tax'];
const JOURNAL_MONEY = ['debit', 'credit'];

const money = (cents: number) => Number(centsToDecimal(cents));
const columnsNamed = (header: readonly string[], names: readonly string[]) =>
  names.map((n) => header.indexOf(n)).filter((i) => i >= 0);

/** Settlement: Summary (the Money section's totals) and Orders (the CSV's rows). */
export function settlementWorkbook(s: Settlement, orderRows: CsvCell[][]): XlsxSheet[] {
  const rows: CsvCell[][] = [
    ['Currency', s.currency],
    ['Exos orders', s.exos.orders],
    ['Exos tickets sold', s.exos.tickets ?? ''],
    ['Gross', money(s.exos.grossCents)],
    ['Tax (included)', money(s.exos.taxCents)],
    ['Refunds', money(s.exos.refundedCents)],
    ['Exos fee', money(s.exos.exosFeeCents)],
    [`Card fees (${s.exos.cardFeeBasis})`, money(s.exos.cardFeeCents)],
    ['Your net', money(s.exos.organizerNetCents)],
    ['Your net after refunds', money(s.exos.organizerNetAfterRefundsCents)],
    ['Marketplace orders', s.marketplace.orders],
    ['Marketplace tickets', s.marketplace.tickets],
    ['Marketplace net', money(s.marketplace.organizerNetCents)],
    ['Promoter commissions (accrued)', money(s.commissions.accruedCents)],
    ['Organizer net (all channels, after commissions)', money(s.organizerNetAfterCommissionsCents)],
  ];
  return [
    { name: 'Summary', header: ['Item', 'Amount'], rows },
    { name: 'Orders', header: [...SETTLEMENT_CSV_HEADER], rows: orderRows, moneyColumns: columnsNamed(SETTLEMENT_CSV_HEADER, SETTLEMENT_MONEY) },
  ];
}

/** One sales-tax sheet (by jurisdiction, rule and source). */
export function salesTaxSheet(rows: SalesTaxRow[]): XlsxSheet {
  return {
    name: 'Sales tax', header: [...SALES_TAX_CSV_HEADER], rows: salesTaxCsvRows(rows),
    moneyColumns: columnsNamed(SALES_TAX_CSV_HEADER, SALES_TAX_MONEY),
  };
}

/** The trial balance per currency, one row per account. */
export function trialBalanceSheet(tb: TrialBalanceRow[]): XlsxSheet {
  const header = ['currency', 'account_number', 'account', 'type', 'debit', 'credit', 'balance'];
  const rows: CsvCell[][] = [];
  for (const b of summarizeTrialBalance(tb)) {
    for (const l of b.lines) {
      rows.push([b.currency, l.number, l.name, l.type, money(l.debitCents), money(l.creditCents), money(l.balanceCents)]);
    }
    rows.push([b.currency, '', 'Total', '', money(b.debitCents), money(b.creditCents), money(b.debitCents - b.creditCents)]);
  }
  return { name: 'Trial balance', header, rows, moneyColumns: [4, 5, 6] };
}

/** The journal workbook: its lines (the CSV's rows), the trial balance and sales tax for the period. */
export function journalWorkbook(journalRows: CsvCell[][], tb: TrialBalanceRow[], tax: SalesTaxRow[]): XlsxSheet[] {
  return [
    { name: 'Journal', header: [...JOURNAL_CSV_HEADER], rows: journalRows, moneyColumns: columnsNamed(JOURNAL_CSV_HEADER, JOURNAL_MONEY) },
    trialBalanceSheet(tb),
    salesTaxSheet(tax),
  ];
}
