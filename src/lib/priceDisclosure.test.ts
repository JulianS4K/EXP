import { describe, it, expect } from 'vitest';
import {
  centsToAmount, priceDisclosureCsvRows, summarizePriceDisclosure,
  PRICE_DISCLOSURE_HEADER, type PriceDisclosureRow,
} from './priceDisclosure';
import { toCsv } from './csv';

const base: PriceDisclosureRow = {
  session_id: 'cs_1', session_status: 'fulfilled', shown_at: '2026-09-26T10:00:00Z', currency: 'usd',
  line_no: 1, kind: 'ticket', item_name: 'GA', quantity: 2,
  face_unit_cents: 4000, tax_cents: 670, tax_included: false, fee_cents: 0,
  unit_all_in_cents: 4335, line_total_cents: 8670, total_shown_cents: 9670,
  charged_cents: 9670, charged_at: '2026-09-26T10:03:00Z', charge_mismatch: false,
};

describe('centsToAmount', () => {
  it('formats integer cents as a plain decimal', () => {
    expect(centsToAmount(0)).toBe('0.00');
    expect(centsToAmount(5)).toBe('0.05');
    expect(centsToAmount(4335)).toBe('43.35');
    expect(centsToAmount(-50)).toBe('-0.50');
    expect(centsToAmount(123456)).toBe('1234.56');
  });
  it('blanks missing values', () => {
    expect(centsToAmount(null)).toBe('');
    expect(centsToAmount(undefined)).toBe('');
    expect(centsToAmount(Number.NaN)).toBe('');
  });
});

describe('priceDisclosureCsvRows', () => {
  it('maps one line to one row in header order', () => {
    const [row] = priceDisclosureCsvRows([base]);
    expect(row).toHaveLength(PRICE_DISCLOSURE_HEADER.length);
    expect(row.slice(0, 2)).toEqual(['cs_1', 'fulfilled']);
    expect(row[2]).toEqual(new Date('2026-09-26T10:00:00Z'));
    expect(row.slice(3, 16)).toEqual([
      'USD', 1, 'ticket', 'GA', 2, '40.00', '6.70', 'added', '0.00', '43.35', '86.70', '96.70', '96.70',
    ]);
    expect(row[17]).toBe('yes');
  });

  it('flags a mismatch and an order not charged yet', () => {
    const rows = priceDisclosureCsvRows([
      { ...base, charged_cents: 9900, charge_mismatch: true },
      { ...base, session_id: 'cs_2', charged_cents: null, charged_at: null, tax_included: true },
    ]);
    expect(rows[0][15]).toBe('99.00');
    expect(rows[0][17]).toBe('NO');
    expect(rows[1][10]).toBe('included');
    expect(rows[1][15]).toBe('');
    expect(rows[1][16]).toBe('');
    expect(rows[1][17]).toBe('not charged yet');
  });

  it('neutralises formula-looking item names through csv.ts', () => {
    const csv = toCsv(PRICE_DISCLOSURE_HEADER, priceDisclosureCsvRows([{ ...base, item_name: '=HYPERLINK("x")' }]));
    expect(csv).toContain(`"'=HYPERLINK(""x"")"`);
  });
});

describe('summarizePriceDisclosure', () => {
  it('counts orders, not lines', () => {
    const s = summarizePriceDisclosure([
      base,
      { ...base, line_no: 2, kind: 'addon', item_name: 'Parking' },
      { ...base, session_id: 'cs_2', charged_cents: 100, charge_mismatch: true },
      { ...base, session_id: 'cs_3', charged_cents: null, charge_mismatch: false },
    ]);
    expect(s).toEqual({ orders: 3, charged: 2, mismatches: 1 });
  });
  it('handles no rows', () => {
    expect(summarizePriceDisclosure([])).toEqual({ orders: 0, charged: 0, mismatches: 0 });
  });
});
