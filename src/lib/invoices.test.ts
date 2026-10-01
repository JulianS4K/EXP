import { describe, expect, it } from 'vitest';
import {
  addressLines,
  documentFileName,
  documentTitle,
  documentTotals,
  formatCredit,
  formatDocNumber,
  formatMoney,
  formatRate,
  invoicesBySession,
  refundState,
  taxLines,
  validateOrgLegal,
  type InvoiceDocument,
  type InvoiceLine,
} from './invoices';

const line = (o: Partial<InvoiceLine> = {}): InvoiceLine => ({
  kind: 'ticket', name: 'GA', quantity: 2, unit_cents: 5000, total_cents: 10000,
  tax_cents: 1000, tax_included: true, tax_name: 'Sales tax 10%', tax_rate: 10, ...o,
});

const doc = (o: Partial<InvoiceDocument> = {}): InvoiceDocument => ({
  invoice: {
    id: 'inv1', number: 'INV-000001', issued_at: '2026-09-30T12:00:00Z', currency: 'usd',
    subtotal_cents: 10000, tax_cents: 1000, total_cents: 11000, status: 'issued', session_id: 'cs_1',
  },
  seller: { name: 'FA Org', legal_name: 'FA Events LLC', legal_address: '1 Main St\nBrooklyn', tax_id: 'EIN 1', invoice_footer: null },
  buyer: { name: null, email: 'fan@example.com' },
  event: null,
  order: { session_id: 'cs_1', paid_at: null, quantity: 2 },
  lines: [line(), line({ kind: 'addon', name: 'Poster', quantity: 1, unit_cents: 1000, total_cents: 1000, tax_cents: 0, tax_name: null, tax_rate: null })],
  credit_notes: [],
  viewer: 'buyer',
  ...o,
});

describe('formatting', () => {
  it('money in the invoice currency', () => {
    expect(formatMoney(123450, 'usd')).toBe('$1,234.50');
    expect(formatMoney(1200, 'EUR')).toBe('€12.00');
    expect(formatMoney(null, null)).toBe('$0.00');
  });
  it('credits with a minus sign', () => {
    expect(formatCredit(3333, 'usd')).toBe('−$33.33');
    expect(formatCredit(-3333, 'usd')).toBe('−$33.33');
    expect(formatCredit(0, 'usd')).toBe('$0.00');
  });
  it('tax rates', () => {
    expect(formatRate(10)).toBe('10%');
    expect(formatRate('8.875')).toBe('8.875%');
    expect(formatRate(null)).toBeNull();
    expect(formatRate('x')).toBeNull();
  });
  it('document numbers', () => {
    expect(formatDocNumber('INV-000001')).toBe('INV-000001');
    expect(formatDocNumber('cn-42')).toBe('CN-000042');
    expect(formatDocNumber('INV-1234567')).toBe('INV-1234567');
    expect(formatDocNumber(' legacy 7 ')).toBe('legacy 7');
    expect(formatDocNumber(null)).toBe('');
  });
  it('titles and file names: a receipt, or a credit note', () => {
    expect(documentTitle(doc())).toBe('Receipt');
    const cn = { id: 'c1', number: 'CN-000003', amount_cents: 100, tax_cents: 0, currency: 'usd', reason: null, created_at: '' };
    expect(documentTitle(doc({ credit_note: cn }))).toBe('Credit note');
    expect(documentFileName(doc())).toBe('receipt-INV-000001');
    expect(documentFileName(doc({ credit_note: cn }))).toBe('credit-note-CN-000003');
  });
  it('address lines', () => {
    expect(addressLines('1 Main St\r\n\n  Brooklyn, NY ')).toEqual(['1 Main St', 'Brooklyn, NY']);
    expect(addressLines(null)).toEqual([]);
  });
});

describe('taxLines', () => {
  it('groups tax per rule', () => {
    const lines = [
      line({ tax_cents: 600 }),
      line({ name: 'VIP', tax_cents: 300 }),
      line({ kind: 'addon', name: 'Drink', tax_cents: 100, tax_name: 'Liquor 20%', tax_rate: '20' }),
    ];
    expect(taxLines(lines, 1000)).toEqual([
      { label: 'Sales tax 10%', rate: 10, cents: 900 },
      { label: 'Liquor 20%', rate: 20, cents: 100 },
    ]);
  });
  it('names an unnamed rule by its rate', () => {
    expect(taxLines([line({ tax_name: null, tax_rate: 8.875, tax_cents: 89 })], 89)).toEqual([{ label: 'Tax 8.875%', rate: 8.875, cents: 89 }]);
  });
  it('falls back to the invoice tax when lines have none or disagree', () => {
    expect(taxLines([line({ tax_cents: null })], 500)).toEqual([{ label: 'Tax', rate: null, cents: 500 }]);
    expect(taxLines([line({ tax_cents: 999 })], 1000)).toEqual([{ label: 'Tax', rate: null, cents: 1000 }]);
  });
  it('no tax, no lines', () => {
    expect(taxLines([line({ tax_cents: 0 })], 0)).toEqual([]);
  });
});

describe('documentTotals', () => {
  it('totals, net and the balance after credit notes', () => {
    const t = documentTotals(doc({
      credit_notes: [
        { id: 'c1', number: 'CN-000001', amount_cents: 3333, tax_cents: 303, currency: 'usd', reason: null, created_at: '' },
      ],
    }));
    expect(t).toEqual({
      linesCents: 11000, totalCents: 11000, taxCents: 1000, netCents: 10000,
      creditedCents: 3333, creditedTaxCents: 303, balanceCents: 7667, linesMismatch: false,
    });
    expect(refundState(t)).toBe('partial');
  });
  it('flags lines that do not add up; refund state', () => {
    const t = documentTotals(doc({ lines: [line({ total_cents: 9000 })] }));
    expect(t.linesMismatch).toBe(true);
    expect(refundState(t)).toBe('none');
    expect(refundState({ totalCents: 100, creditedCents: 100 })).toBe('full');
  });
});

describe('org legal + money helpers', () => {
  it('validates lengths', () => {
    expect(validateOrgLegal({ legal_name: 'A', legal_address: '', tax_id: '', invoice_footer: '' })).toEqual({});
    const e = validateOrgLegal({ legal_name: 'A', legal_address: '', tax_id: 'x'.repeat(65), invoice_footer: 'y'.repeat(501) });
    expect(Object.keys(e).sort()).toEqual(['invoice_footer', 'tax_id']);
  });
  it('indexes invoices by session', () => {
    const m = invoicesBySession([
      { id: 'i1', number: 'INV-000001', session_id: 'cs_1', total_cents: 1, currency: 'usd', issued_at: '' },
      { id: 'i2', number: 'INV-000002', session_id: null, total_cents: 1, currency: 'usd', issued_at: '' },
    ]);
    expect([...m.keys()]).toEqual(['cs_1']);
  });
});
