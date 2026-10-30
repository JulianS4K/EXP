import { describe, expect, it } from 'vitest';
import { parseCsv } from '../../supabase/functions/_shared/csvParse.ts';
import {
  cleanLabel, eventValues, guessPlatform, parseAmount, planSalesImport, salesTotals,
  suggestSalesMapping, totalSold,
} from '../../supabase/functions/_shared/salesCounts.ts';

describe('parseAmount', () => {
  it('reads US, European and symbol-laden amounts', () => {
    expect([
      parseAmount('1,234'), parseAmount('$1,234.50'), parseAmount('€ 12,50'), parseAmount('1.234,56'),
      parseAmount('(12)'), parseAmount('-3'), parseAmount(''), parseAmount('abc'), parseAmount('£0.99'),
    ]).toEqual([1234, 1234.5, 12.5, 1234.56, -12, -3, null, null, 0.99]);
  });
});

describe('suggestSalesMapping', () => {
  it('maps common export headers', () => {
    expect(suggestSalesMapping(['Event Name', 'Ticket Type', 'Tickets Sold', 'Gross Sales', 'Capacity', 'Currency', 'Order Status']))
      .toEqual({ event: 0, tier: 1, sold: 2, gross: 3, capacity: 4, currency: 5, status: 6 });
    expect(suggestSalesMapping(['Order #', 'Ticket', 'Quantity', 'Price'])).toEqual({ tier: 1, sold: 2, price: 3 });
    expect(suggestSalesMapping(['foo', 'bar'])).toEqual({});
  });
});

describe('guessPlatform', () => {
  it('reads the file name', () => {
    expect(guessPlatform('DICE_sales_2026.csv')).toBe('dice');
    expect(guessPlatform('ra-tickets.csv')).toBe('ra');
    expect(guessPlatform('orders.csv')).toBe('other');
  });
});

describe('planSalesImport', () => {
  const table = parseCsv([
    'Event,Ticket Type,Sold,Gross,Capacity,Status',
    'Warehouse,Early,50,"1,000.00",50,paid',
    'Warehouse,GA,20,600,150,paid',
    'warehouse ,ga,10,300,100,paid',
    'Warehouse,GA,2,60,,Refunded',
    'Rooftop,GA,9,90,,paid',
  ].join('\n'));
  const mapping = suggestSalesMapping(table[0]);

  it('adds rows up per ticket type for the chosen event, skipping refunds', () => {
    const p = planSalesImport(table, mapping, { currency: 'usd', event: 'Warehouse' });
    expect(p.errors).toEqual([]);
    expect(p.tiers).toEqual([
      { name: 'Early', sold: 50, gross_cents: 100000, capacity: 50 },
      { name: 'GA', sold: 30, gross_cents: 90000, capacity: 150 },
    ]);
    expect([p.sold, p.grossCents, p.capacity, p.currency, p.rows, p.voided, p.otherEvents]).toEqual([80, 190000, 200, 'USD', 3, 1, 1]);
  });

  it('is deterministic: the same file gives the same plan (re-import is a no-op)', () => {
    const a = planSalesImport(table, mapping, { currency: 'USD', event: 'warehouse' });
    const b = planSalesImport(parseCsv(table.map((r) => r.map((c) => `"${c}"`).join(',')).join('\r\n')), mapping, { currency: 'USD', event: 'Warehouse' });
    expect(b.tiers).toEqual(a.tiers);
  });

  it('warns when an event column is mapped but no event is chosen', () => {
    const p = planSalesImport(table, mapping, { currency: 'USD' });
    expect(p.sold).toBe(89);
    expect(p.warnings.map((w) => w.field)).toContain('event');
    expect(eventValues(table, mapping)).toEqual(['Warehouse', 'Rooftop']);
  });

  it('uses price × sold without a gross column, and one total without a tier column', () => {
    const t = parseCsv('Order,Quantity,Price\n1,2,$15\n2,1,$15\n');
    const p = planSalesImport(t, suggestSalesMapping(t[0]), { currency: 'USD' });
    expect([p.sold, p.grossCents, p.tiers]).toEqual([3, 4500, []]);
  });

  it('reports bad cells with their line and refuses mixed currencies', () => {
    const t = parseCsv('Sold,Gross,Currency\n1.5,10,USD\n2,abc,USD\n1,1,EUR\n1,1,USD\n');
    const p = planSalesImport(t, suggestSalesMapping(t[0]), { currency: 'USD' });
    expect(p.errors.map((e) => [e.row, e.field])).toEqual([[2, 'sold'], [3, 'gross'], [0, 'currency']]);
  });

  it('needs a sold column, a currency and existing columns', () => {
    const t = parseCsv('a,b\n1,2\n');
    expect(planSalesImport(t, {}, { currency: 'USD' }).errors[0].field).toBe('sold');
    expect(planSalesImport(t, { sold: 5 }, { currency: 'USD' }).errors[0].message).toMatch(/not in the file/);
    expect(planSalesImport(t, { sold: 0 }, { currency: '' }).errors[0].field).toBe('currency');
  });

  it('caps rows and ticket types', () => {
    const many = parseCsv(`Sold\n${'1\n'.repeat(2001)}`);
    expect(planSalesImport(many, { sold: 0 }, { currency: 'USD' }).errors[0].message).toMatch(/2000/);
    const tiers = parseCsv(`Tier,Sold\n${Array.from({ length: 51 }, (_, i) => `T${i},1`).join('\n')}`);
    expect(planSalesImport(tiers, { tier: 0, sold: 1 }, { currency: 'USD' }).errors[0].field).toBe('tier');
  });
});

describe('labels and totals', () => {
  it('cleans manual labels', () => {
    expect(cleanLabel('  Box   office ')).toBe('Box office');
    expect(cleanLabel(' ')).toBeNull();
    expect(cleanLabel('x'.repeat(41))).toBeNull();
  });

  it('totals per currency, never mixed', () => {
    const rows = [
      { currency: 'USD', sold: 12, gross_cents: 24000 },
      { currency: 'usd', sold: 3, gross_cents: 600 },
      { currency: 'GBP', sold: 95, gross_cents: 235000 },
    ];
    expect(salesTotals(rows)).toEqual([
      { currency: 'GBP', sold: 95, grossCents: 235000 },
      { currency: 'USD', sold: 15, grossCents: 24600 },
    ]);
    expect(totalSold(rows)).toBe(110);
  });
});
