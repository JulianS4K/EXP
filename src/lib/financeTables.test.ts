import { describe, expect, it } from 'vitest';
import {
  centsFromMajor, label, planLedgerImport, REVENUE_TYPE_LABEL, reportingRowsCsv, totalsByCurrency,
} from './financeTables';

describe('centsFromMajor', () => {
  it('is exact', () => {
    expect(centsFromMajor('4.80')).toBe(480);
    expect(centsFromMajor('-12')).toBe(-1200);
    expect(centsFromMajor('1,234.5')).toBe(123450);
    expect(centsFromMajor('$0.07')).toBe(7);
    expect(centsFromMajor('0.1')).toBe(10);
    expect(centsFromMajor('1.234')).toBeNull();
    expect(centsFromMajor('abc')).toBeNull();
    expect(centsFromMajor('')).toBeNull();
  });
});

describe('planLedgerImport', () => {
  it('reads a ledger export', () => {
    const csv = 'Source,Description,Amount,Tax,GL Code,Date,Source System,Line ID\n'
      + 'bar,"Bar, night",500.00,40.00,4100,2026-11-01T22:00:00Z,square,sq:1\n'
      + 'Gift Cards,Spend,-25,,,2026-11-01,,sq:2\n';
    const p = planLedgerImport(csv, { event_id: 'ev', source_system: 'Square' });
    expect(p.errors).toEqual([]);
    expect(p.rows).toEqual([
      { source: 'bar', amount_cents: 50000, tax_amount_cents: 4000, posted_at: '2026-11-01T22:00:00Z', source_system: 'square', source_line_id: 'sq:1',
        description: 'Bar, night', gl_code: '4100', event_id: 'ev' },
      { source: 'gift_cards', amount_cents: -2500, tax_amount_cents: 0, posted_at: '2026-11-01', source_system: 'square', source_line_id: 'sq:2',
        description: 'Spend', event_id: 'ev' },
    ]);
  });
  it('takes cents columns too', () => {
    const p = planLedgerImport('source,amount_cents,posted_at,source_system,source_line_id\nbar,480,2026-11-01,pos,1\n');
    expect(p.rows[0].amount_cents).toBe(480);
  });
  it('reports bad rows and missing columns', () => {
    expect(planLedgerImport('source,amount\nbar,1').errors.map((e) => e.error)).toEqual(['Missing column: posted_at.', 'Missing column: source_line_id.']);
    const p = planLedgerImport('source,amount,posted_at,source_system,source_line_id\nbar,1.234,2026-11-01,pos,1\nnope,1,2026-11-01,pos,2\nbar,1,soon,pos,3\nbar,1,2026-11-01,,4\nbar,2,2026-11-01,pos,5\n');
    expect(p.errors.map((e) => e.row)).toEqual([2, 3, 4, 5]);
    expect(p.rows).toHaveLength(1);
    expect(planLedgerImport('').errors[0].error).toMatch(/header/);
  });
  it('caps at 500', () => {
    const body = Array.from({ length: 501 }, (_, i) => `bar,1,2026-11-01,pos,${i}`).join('\n');
    const p = planLedgerImport(`source,amount,posted_at,source_system,source_line_id\n${body}\n`);
    expect(p.rows).toEqual([]);
    expect(p.errors[0].error).toMatch(/500/);
  });
});

describe('export and labels', () => {
  it('reporting rows as CSV, amounts in major units', () => {
    const csv = reportingRowsCsv([{
      occurred_at: '2026-11-01T00:00:00Z', event_id: 'e', source_type: 'refund', source_id: 'r1', revenue_type: 'refunds', currency: 'USD',
      amount_cents: -2005, payment_method: 'card', gl_code: '4000', description: '=cmd', imported: false,
    }], () => 'Show');
    expect(csv.split('\r\n')[1]).toBe("2026-11-01T00:00:00Z,Show,refund,r1,refunds,4000,USD,-20.05,card,no,'=cmd");
  });
  it('totals per currency', () => {
    expect(totalsByCurrency([{ currency: 'USD', amount_cents: 5 }, { currency: 'EUR', amount_cents: 1 }, { currency: 'USD', amount_cents: -2 }]))
      .toEqual([{ currency: 'EUR', cents: 1 }, { currency: 'USD', cents: 3 }]);
  });
  it('labels fall back to the raw value', () => {
    expect(label(REVENUE_TYPE_LABEL, 'bar')).toBe('Bar / F&B');
    expect(label(REVENUE_TYPE_LABEL, 'new_thing')).toBe('new_thing');
    expect(label(REVENUE_TYPE_LABEL, null)).toBe('');
  });
});
