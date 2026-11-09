// The money journal (mig 20261108100000, docs/journal.md): the chart, the
// trial balance, the journal CSV and the sales-tax report by jurisdiction.
// PURE (no Supabase import, so it unit-tests without a client); the reads
// live in ./journalApi.ts. Read-only: nothing here posts or changes an entry.

import type { CsvCell } from './csv';
import { centsToDecimal } from './settlement';

export type AccountType = 'asset' | 'liability' | 'revenue' | 'contra_revenue' | 'expense';

export interface JournalAccount {
  code: string;
  number: number;
  name: string;
  type: AccountType;
  normal: 'debit' | 'credit';
}

/** The chart, as exos_journal_accounts() returns it (journal.test.ts checks the SQL copy). */
export const JOURNAL_ACCOUNTS: readonly JournalAccount[] = [
  { code: 'stripe_clearing', number: 1000, name: 'Cash at Stripe / clearing', type: 'asset', normal: 'debit' },
  { code: 'paypal_receivable', number: 1010, name: 'PayPal balance due from Exos', type: 'asset', normal: 'debit' },
  { code: 'pos_cash_drawer', number: 1020, name: 'POS cash drawer', type: 'asset', normal: 'debit' },
  { code: 'marketplace_receivable', number: 1100, name: 'Marketplace receivable', type: 'asset', normal: 'debit' },
  { code: 'organizer_payable', number: 2000, name: 'Organizer payable (owed to Exos)', type: 'liability', normal: 'credit' },
  { code: 'sales_tax_payable', number: 2100, name: 'Sales tax payable', type: 'liability', normal: 'credit' },
  { code: 'promoter_commissions_payable', number: 2200, name: 'Promoter commissions payable', type: 'liability', normal: 'credit' },
  { code: 'gift_cards_outstanding', number: 2300, name: 'Gift cards outstanding', type: 'liability', normal: 'credit' },
  { code: 'tips_payable', number: 2400, name: 'Tips payable (POS)', type: 'liability', normal: 'credit' },
  { code: 'ticket_revenue', number: 4000, name: 'Ticket revenue (face)', type: 'revenue', normal: 'credit' },
  { code: 'buyer_fees', number: 4010, name: 'Buyer fees', type: 'revenue', normal: 'credit' },
  { code: 'pos_other_sales', number: 4020, name: 'Bar and merch sales (POS)', type: 'revenue', normal: 'credit' },
  { code: 'donations', number: 4030, name: 'Donations', type: 'revenue', normal: 'credit' },
  { code: 'refunds', number: 4900, name: 'Refunds', type: 'contra_revenue', normal: 'debit' },
  { code: 'exos_fee', number: 5000, name: 'Exos fee', type: 'expense', normal: 'debit' },
  { code: 'card_fees', number: 5010, name: 'Card processing fees', type: 'expense', normal: 'debit' },
  { code: 'disputes', number: 5020, name: 'Disputes', type: 'expense', normal: 'debit' },
  { code: 'promoter_commissions', number: 5030, name: 'Promoter commissions', type: 'expense', normal: 'debit' },
  { code: 'pos_paid_outs', number: 5040, name: 'Cash paid-outs (POS)', type: 'expense', normal: 'debit' },
];

const BY_CODE = new Map(JOURNAL_ACCOUNTS.map((a) => [a.code, a]));

export function accountOf(code: string): JournalAccount | undefined {
  return BY_CODE.get(code);
}

const int = (n: unknown): number => {
  const v = Number(n);
  return Number.isFinite(v) ? Math.trunc(v) : 0;
};

// ── Trial balance ────────────────────────────────────────────────────────

/** A row of exos_journal_trial_balance. */
export interface TrialBalanceRow {
  account: string;
  account_number: number;
  account_name: string;
  account_type: AccountType | string;
  currency: string;
  debit_cents: number | string;
  credit_cents: number | string;
  balance_cents: number | string;
  entries?: number | string;
}

export interface TrialBalanceLine {
  account: string;
  number: number;
  name: string;
  type: string;
  debitCents: number;
  creditCents: number;
  /** debit − credit */
  balanceCents: number;
  /** The balance on the account's normal side (positive = the usual way round). */
  normalCents: number;
}

export interface TrialBalance {
  currency: string;
  lines: TrialBalanceLine[];
  debitCents: number;
  creditCents: number;
  balanced: boolean;
  /** Revenue less refunds. */
  netRevenueCents: number;
  expenseCents: number;
  /** Net revenue less expenses: what the period made for the organizer. */
  netCents: number;
}

/** One trial balance per currency, accounts in chart order. */
export function summarizeTrialBalance(rows: TrialBalanceRow[]): TrialBalance[] {
  const byCur = new Map<string, TrialBalanceLine[]>();
  for (const r of rows ?? []) {
    const cur = (r.currency || 'USD').toUpperCase();
    const acct = accountOf(r.account);
    const debit = int(r.debit_cents);
    const credit = int(r.credit_cents);
    const balance = debit - credit;
    const normal = (acct?.normal ?? 'debit') === 'debit' ? balance : -balance;
    const list = byCur.get(cur) ?? [];
    list.push({
      account: r.account,
      number: acct?.number ?? int(r.account_number),
      name: acct?.name ?? r.account_name,
      type: acct?.type ?? String(r.account_type),
      debitCents: debit,
      creditCents: credit,
      balanceCents: balance,
      normalCents: normal,
    });
    byCur.set(cur, list);
  }
  return [...byCur.entries()]
    .sort(([a], [b]) => a.localeCompare(b))
    .map(([currency, lines]) => {
      lines.sort((a, b) => a.number - b.number);
      const debitCents = lines.reduce((s, l) => s + l.debitCents, 0);
      const creditCents = lines.reduce((s, l) => s + l.creditCents, 0);
      const netRevenueCents = -lines
        .filter((l) => l.type === 'revenue' || l.type === 'contra_revenue')
        .reduce((s, l) => s + l.balanceCents, 0);
      const expenseCents = lines.filter((l) => l.type === 'expense').reduce((s, l) => s + l.balanceCents, 0);
      return {
        currency, lines, debitCents, creditCents, balanced: debitCents === creditCents,
        netRevenueCents, expenseCents, netCents: netRevenueCents - expenseCents,
      };
    });
}

// ── Journal CSV ──────────────────────────────────────────────────────────

/** A row of exos_journal_rows (one journal line). */
export interface JournalLineRow {
  line_id: number | string;
  entry_id: string;
  entry_number: number | string;
  occurred_at: string;
  currency: string;
  source_table: string;
  source_id: string;
  kind: string;
  account: string;
  account_name?: string | null;
  debit_cents: number | string;
  credit_cents: number | string;
  memo?: string | null;
  line_no?: number;
}

const SOURCE_LABEL: Record<string, string> = {
  exos_checkout_sessions: 'Order',
  exos_order_refunds: 'Refund',
  exos_fee_adjustments: 'Fee change',
  exos_disputes: 'Dispute',
  exos_marketplace_orders: 'Marketplace order',
  exos_org_payout_lines: 'Marketplace payout',
  exos_promoter_commissions: 'Promoter commission',
  exos_pos_payments: 'Door sale',
  exos_pos_paid_outs: 'Door cash out',
};

export function sourceLabel(sourceTable: string): string {
  return SOURCE_LABEL[sourceTable] ?? sourceTable.replace(/^exos_/, '').replace(/_/g, ' ');
}

export const JOURNAL_CSV_HEADER = [
  'date', 'entry_id', 'entry_number', 'source', 'source_id', 'kind', 'account_number', 'account', 'debit', 'credit', 'currency', 'memo',
];

/** The journal CSV: one row per line, in entry order; amounts as 12.34. */
export function journalCsvRows(rows: JournalLineRow[]): CsvCell[][] {
  return [...(rows ?? [])]
    .sort((a, b) => (a.occurred_at ?? '').localeCompare(b.occurred_at ?? '')
      || int(a.entry_number) - int(b.entry_number) || int(a.line_no) - int(b.line_no))
    .map((r) => {
      const acct = accountOf(r.account);
      const debit = int(r.debit_cents);
      const credit = int(r.credit_cents);
      return [
        (r.occurred_at ?? '').slice(0, 10),
        r.entry_id,
        int(r.entry_number),
        sourceLabel(r.source_table),
        r.source_id,
        r.kind,
        acct?.number ?? '',
        acct?.name ?? r.account_name ?? r.account,
        debit ? centsToDecimal(debit) : '',
        credit ? centsToDecimal(credit) : '',
        (r.currency || '').toUpperCase(),
        r.memo ?? '',
      ];
    });
}

/** Entries whose lines don't sum to zero (should always be empty). */
export function unbalancedEntries(rows: JournalLineRow[]): { entryId: string; diffCents: number }[] {
  const sums = new Map<string, number>();
  for (const r of rows ?? []) sums.set(r.entry_id, (sums.get(r.entry_id) ?? 0) + int(r.debit_cents) - int(r.credit_cents));
  return [...sums.entries()].filter(([, d]) => d !== 0).map(([entryId, diffCents]) => ({ entryId, diffCents }));
}

// ── Sales tax by jurisdiction ────────────────────────────────────────────

/** A row of exos_sales_tax_report(...).rows. */
export interface SalesTaxRow {
  country: string | null;
  region: string | null;
  city: string | null;
  postal_code: string | null;
  tax_name: string | null;
  rate_percent: number | string | null;
  source: 'online' | 'pos' | string;
  currency: string;
  orders: number;
  taxable_cents: number;
  tax_collected_cents: number;
  tax_refunded_cents: number;
  net_tax_cents: number;
}

/** "Brooklyn, NY 11211, US"; "Location not set" when the venue has no address. */
export function jurisdictionLabel(r: Pick<SalesTaxRow, 'country' | 'region' | 'city' | 'postal_code'>): string {
  const regionPostal = [r.region, r.postal_code].filter(Boolean).join(' ');
  const parts = [r.city, regionPostal, r.country].filter((p) => p && String(p).trim());
  return parts.length ? parts.join(', ') : 'Location not set';
}

/** "NY sales tax (8.875%)", "8.875% (door)", "Rate not recorded". */
export function taxRateLabel(r: Pick<SalesTaxRow, 'tax_name' | 'rate_percent' | 'source'>): string {
  const rate = r.rate_percent === null || r.rate_percent === undefined || r.rate_percent === '' ? null : Number(r.rate_percent);
  const pct = rate === null || !Number.isFinite(rate) ? null : `${rate}%`;
  if (r.tax_name) return pct ? `${r.tax_name} (${pct})` : r.tax_name;
  if (pct) return r.source === 'pos' ? `${pct} (door)` : pct;
  return 'Rate not recorded';
}

export const SALES_TAX_CSV_HEADER = [
  'country', 'region', 'city', 'postal_code', 'tax_name', 'rate_percent', 'source', 'currency', 'orders',
  'taxable', 'tax_collected', 'tax_refunded', 'net_tax',
];

export function salesTaxCsvRows(rows: SalesTaxRow[]): CsvCell[][] {
  return (rows ?? []).map((r) => [
    r.country ?? '', r.region ?? '', r.city ?? '', r.postal_code ?? '', r.tax_name ?? '',
    r.rate_percent === null || r.rate_percent === undefined ? '' : String(r.rate_percent),
    r.source, (r.currency || '').toUpperCase(), int(r.orders),
    centsToDecimal(int(r.taxable_cents)), centsToDecimal(int(r.tax_collected_cents)),
    centsToDecimal(int(r.tax_refunded_cents)), centsToDecimal(int(r.net_tax_cents)),
  ]);
}

export interface SalesTaxTotal {
  currency: string;
  collectedCents: number;
  refundedCents: number;
  netCents: number;
}

export function salesTaxTotals(rows: SalesTaxRow[]): SalesTaxTotal[] {
  const m = new Map<string, SalesTaxTotal>();
  for (const r of rows ?? []) {
    const cur = (r.currency || 'USD').toUpperCase();
    const t = m.get(cur) ?? { currency: cur, collectedCents: 0, refundedCents: 0, netCents: 0 };
    t.collectedCents += int(r.tax_collected_cents);
    t.refundedCents += int(r.tax_refunded_cents);
    t.netCents += int(r.net_tax_cents);
    m.set(cur, t);
  }
  return [...m.values()].sort((a, b) => a.currency.localeCompare(b.currency));
}

// ── Periods ──────────────────────────────────────────────────────────────

/**
 * A period picked as two calendar days (YYYY-MM-DD, both inclusive) → the
 * ISO bounds the RPCs take (from inclusive, to exclusive: the day after
 * `toDay`), in UTC. Empty / malformed days are unbounded (null).
 */
export function periodBounds(fromDay: string, toDay: string): { from: string | null; to: string | null } {
  const ok = (d: string) => /^\d{4}-\d{2}-\d{2}$/.test(d) && !Number.isNaN(Date.parse(`${d}T00:00:00Z`));
  const from = ok(fromDay) ? `${fromDay}T00:00:00.000Z` : null;
  let to: string | null = null;
  if (ok(toDay)) {
    const t = new Date(`${toDay}T00:00:00Z`);
    t.setUTCDate(t.getUTCDate() + 1);
    to = t.toISOString();
  }
  return { from, to };
}
