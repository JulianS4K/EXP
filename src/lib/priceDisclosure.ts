// Price-disclosure export (mig 20260926070000): per checkout session, what the
// buyer was shown (face price, tax, buyer fee, all-in unit price, total) and
// what Stripe charged, so an organizer can prove all-in pricing under NY Arts
// & Cultural Affairs Law 25.07 and the FTC fee rule. Rows come from
// exos_price_disclosure_export (owner / manager / finance). Pure: no Supabase
// here, so it can be tested; PriceDisclosureExport.tsx does the fetch.

import type { CsvCell } from './csv';

/** One row of exos_price_disclosure_export: a line of one checkout session. */
export interface PriceDisclosureRow {
  session_id: string;
  session_status: string | null;
  shown_at: string;
  currency: string;
  line_no: number;
  kind: 'ticket' | 'addon' | string;
  item_name: string;
  quantity: number;
  face_unit_cents: number;
  tax_cents: number;
  tax_included: boolean;
  fee_cents: number;
  unit_all_in_cents: number;
  line_total_cents: number;
  total_shown_cents: number;
  charged_cents: number | null;
  charged_at: string | null;
  charge_mismatch: boolean;
}

export const PRICE_DISCLOSURE_HEADER = [
  'session_id', 'status', 'shown_at', 'currency', 'line', 'kind', 'item', 'quantity',
  'face_unit_price', 'tax', 'tax_included', 'buyer_fees', 'all_in_unit_price', 'line_total',
  'order_total_shown', 'amount_charged', 'charged_at', 'charged_matches_shown',
];

/** Integer cents to a plain decimal amount ("12.34", "-0.50"); '' for null. */
export function centsToAmount(cents: number | null | undefined): string {
  if (cents === null || cents === undefined || !Number.isFinite(cents)) return '';
  const n = Math.round(cents);
  const sign = n < 0 ? '-' : '';
  const abs = Math.abs(n);
  return `${sign}${Math.floor(abs / 100)}.${String(abs % 100).padStart(2, '0')}`;
}

// 'yes' / 'NO' / 'not charged yet'. Upper-case NO so a mismatch stands out
// when someone scans the sheet.
function matchCell(r: PriceDisclosureRow): string {
  if (r.charged_cents === null || r.charged_cents === undefined) return 'not charged yet';
  return r.charge_mismatch ? 'NO' : 'yes';
}

export function priceDisclosureCsvRows(rows: PriceDisclosureRow[]): CsvCell[][] {
  return rows.map((r) => [
    r.session_id,
    r.session_status ?? '',
    r.shown_at ? new Date(r.shown_at) : '',
    (r.currency ?? '').toUpperCase(),
    r.line_no,
    r.kind,
    r.item_name,
    r.quantity,
    centsToAmount(r.face_unit_cents),
    centsToAmount(r.tax_cents),
    r.tax_included ? 'included' : 'added',
    centsToAmount(r.fee_cents),
    centsToAmount(r.unit_all_in_cents),
    centsToAmount(r.line_total_cents),
    centsToAmount(r.total_shown_cents),
    centsToAmount(r.charged_cents),
    r.charged_at ? new Date(r.charged_at) : '',
    matchCell(r),
  ]);
}

export interface PriceDisclosureSummary {
  orders: number;
  charged: number;
  mismatches: number;
}

/** Order-level counts (rows are per line, so dedupe on session). */
export function summarizePriceDisclosure(rows: PriceDisclosureRow[]): PriceDisclosureSummary {
  const bySession = new Map<string, PriceDisclosureRow>();
  for (const r of rows) if (!bySession.has(r.session_id)) bySession.set(r.session_id, r);
  let charged = 0;
  let mismatches = 0;
  for (const r of bySession.values()) {
    if (r.charged_cents !== null && r.charged_cents !== undefined) charged++;
    if (r.charge_mismatch) mismatches++;
  }
  return { orders: bySession.size, charged, mismatches };
}
