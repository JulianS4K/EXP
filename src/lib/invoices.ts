// Invoices / receipts and credit notes (mig 20261001100000, docs/invoices.md).
// PURE: the document shape returned by exos_invoice_document /
// exos_credit_note_document, and the helpers the printable page renders
// with (tax lines per rate, totals, money and number formatting). The reads
// live in ./invoicesApi.ts.
//
// Every checkout price is all-in (tax included, no fees added), so a line's
// total already contains its tax; the tax lines say how much of the total
// was tax, per rate.

import { formatCents } from './refunds';

export interface InvoiceLine {
  kind: 'ticket' | 'addon' | string;
  name: string;
  quantity: number;
  unit_cents: number;
  total_cents: number;
  /** null on older orders (no price-disclosure record): only the invoice's total tax is known. */
  tax_cents: number | null;
  tax_included: boolean | null;
  tax_name: string | null;
  tax_rate: number | string | null;
}

export interface CreditNoteSummary {
  id: string;
  number: string;
  amount_cents: number;
  tax_cents: number;
  currency: string;
  reason: string | null;
  created_at: string;
}

export interface Seller {
  name: string | null;
  legal_name: string | null;
  legal_address: string | null;
  tax_id: string | null;
  invoice_footer: string | null;
}

export interface InvoiceDocument {
  invoice: {
    id: string;
    number: string;
    issued_at: string;
    currency: string;
    subtotal_cents: number;
    tax_cents: number;
    total_cents: number;
    status: string;
    session_id: string | null;
  };
  seller: Seller | null;
  buyer: { name: string | null; email: string | null };
  event: { id: string; name: string | null; starts_at: string | null; timezone: string | null; venue_name: string | null } | null;
  order: { session_id: string | null; paid_at: string | null; quantity: number | null };
  lines: InvoiceLine[];
  credit_notes: CreditNoteSummary[];
  viewer: 'buyer' | 'org';
  /** Present on exos_credit_note_document. */
  credit_note?: CreditNoteSummary;
}

export interface TaxLine {
  label: string;
  /** Percent, when the rule is known. */
  rate: number | null;
  cents: number;
}

const int = (n: unknown): number => {
  const v = Number(n);
  return Number.isFinite(v) ? Math.round(v) : 0;
};

/** Money as printed on the document ("$1,234.50", "€12.00"). */
export function formatMoney(cents: number | null | undefined, currency: string | null | undefined): string {
  return formatCents(int(cents), (currency || 'usd').toUpperCase());
}

/** A negative amount for credit notes: "−$12.00" (a real minus sign). */
export function formatCredit(cents: number, currency: string | null | undefined): string {
  return cents === 0 ? formatMoney(0, currency) : `−${formatMoney(Math.abs(cents), currency)}`;
}

/** "10%", "8.875%": a tax rate as the rule stores it (numeric may come back as a string). */
export function formatRate(rate: number | string | null | undefined): string | null {
  if (rate === null || rate === undefined || rate === '') return null;
  const n = Number(rate);
  if (!Number.isFinite(n)) return null;
  return `${Number(n.toFixed(4))}%`;
}

/**
 * Invoice / credit-note numbers as the database issues them: INV-000001 and
 * CN-000001. Anything else (a legacy value) is shown as it is, trimmed.
 */
export function formatDocNumber(n: string | null | undefined): string {
  const s = (n ?? '').trim();
  const m = s.match(/^(INV|CN)-?(\d+)$/i);
  return m ? `${m[1].toUpperCase()}-${m[2].padStart(6, '0')}` : s;
}

/** The document's heading. Exos sells to consumers: an order is a "Receipt". */
export function documentTitle(doc: Pick<InvoiceDocument, 'credit_note'>): 'Receipt' | 'Credit note' {
  return doc.credit_note ? 'Credit note' : 'Receipt';
}

/** Browser title while printing, so "Save as PDF" suggests a useful file name. */
export function documentFileName(doc: InvoiceDocument): string {
  const n = doc.credit_note ? doc.credit_note.number : doc.invoice.number;
  return `${doc.credit_note ? 'credit-note' : 'receipt'}-${formatDocNumber(n)}`;
}

/**
 * Tax per rate. Lines with a known rule are grouped by rule name and rate; if
 * the lines don't carry tax (older orders) or their sum doesn't match the
 * invoice's recorded tax, one "Tax" line with the invoice's tax is returned
 * instead, so the document never disagrees with the invoice. No tax → [].
 */
export function taxLines(lines: InvoiceLine[], invoiceTaxCents: number): TaxLine[] {
  const total = int(invoiceTaxCents);
  if (total <= 0) return [];
  const known = lines.every((l) => l.tax_cents !== null && l.tax_cents !== undefined);
  const sum = lines.reduce((n, l) => n + int(l.tax_cents), 0);
  if (!known || sum !== total) return [{ label: 'Tax', rate: null, cents: total }];
  const groups = new Map<string, TaxLine>();
  for (const l of lines) {
    const cents = int(l.tax_cents);
    if (cents === 0) continue;
    const rateNum = l.tax_rate === null || l.tax_rate === undefined || l.tax_rate === '' ? null : Number(l.tax_rate);
    const rate = rateNum !== null && Number.isFinite(rateNum) ? rateNum : null;
    const label = (l.tax_name || '').trim() || (rate !== null ? `Tax ${formatRate(rate)}` : 'Tax');
    const key = `${label}|${rate ?? ''}`;
    const g = groups.get(key) ?? { label, rate, cents: 0 };
    g.cents += cents;
    groups.set(key, g);
  }
  return [...groups.values()];
}

export interface DocumentTotals {
  /** Sum of the line totals (all-in). */
  linesCents: number;
  /** The invoice's recorded total; the lines are shown against it. */
  totalCents: number;
  taxCents: number;
  /** Total less tax. */
  netCents: number;
  creditedCents: number;
  creditedTaxCents: number;
  /** What the buyer paid, less every credit note. */
  balanceCents: number;
  /** The line totals don't add up to the invoice total (older orders, rounding). */
  linesMismatch: boolean;
}

export function documentTotals(doc: Pick<InvoiceDocument, 'invoice' | 'lines' | 'credit_notes'>): DocumentTotals {
  const totalCents = int(doc.invoice.total_cents);
  const taxCents = int(doc.invoice.tax_cents);
  const linesCents = doc.lines.reduce((n, l) => n + int(l.total_cents), 0);
  const creditedCents = doc.credit_notes.reduce((n, c) => n + int(c.amount_cents), 0);
  const creditedTaxCents = doc.credit_notes.reduce((n, c) => n + int(c.tax_cents), 0);
  return {
    linesCents,
    totalCents,
    taxCents,
    netCents: totalCents - taxCents,
    creditedCents,
    creditedTaxCents,
    balanceCents: totalCents - creditedCents,
    linesMismatch: doc.lines.length > 0 && linesCents !== totalCents,
  };
}

/** The status line under the heading. */
export function refundState(t: Pick<DocumentTotals, 'totalCents' | 'creditedCents'>): 'none' | 'partial' | 'full' {
  if (t.creditedCents <= 0) return 'none';
  return t.creditedCents >= t.totalCents ? 'full' : 'partial';
}

/** Seller address lines (the textarea's line breaks), blanks dropped. */
export function addressLines(address: string | null | undefined): string[] {
  return (address ?? '').split(/\r?\n/).map((s) => s.trim()).filter(Boolean);
}

export const invoicePath = (id: string) => `/invoice/${id}`;
export const creditNotePath = (id: string) => `/credit-note/${id}`;

// ── Org legal details (Settings → Legal & invoices) ─────────────────────

export interface OrgLegal {
  legal_name: string;
  legal_address: string;
  tax_id: string;
  invoice_footer: string;
}

export const LEGAL_LIMITS: Record<keyof OrgLegal, number> = {
  legal_name: 200,
  legal_address: 500,
  tax_id: 64,
  invoice_footer: 500,
};

/** Field errors (too long), keyed by field; empty object when savable. */
export function validateOrgLegal(v: OrgLegal): Partial<Record<keyof OrgLegal, string>> {
  const out: Partial<Record<keyof OrgLegal, string>> = {};
  for (const k of Object.keys(LEGAL_LIMITS) as (keyof OrgLegal)[]) {
    const len = (v[k] ?? '').trim().length;
    if (len > LEGAL_LIMITS[k]) out[k] = `At most ${LEGAL_LIMITS[k]} characters (now ${len}).`;
  }
  return out;
}

// ── Organizer money: invoice numbers per order ───────────────────────────

export interface EventInvoiceRow {
  id: string;
  number: string;
  session_id: string | null;
  total_cents: number;
  currency: string;
  issued_at: string;
  refunded_cents?: number | null;
}

/** session id → invoice, for the Money CSV and the per-order rows. */
export function invoicesBySession(rows: EventInvoiceRow[]): Map<string, EventInvoiceRow> {
  const m = new Map<string, EventInvoiceRow>();
  for (const r of rows) if (r.session_id) m.set(r.session_id, r);
  return m;
}
