import { describe, expect, it } from 'vitest';
import { cartTotals, lineTotals, sellable, taxCents } from './index';
import { allInCents } from '../../../supabase/functions/_shared/pricing.ts';

describe('POS line totals and tax (same math as checkout and exos_pos_tg_line)', () => {
  it('exclusive tax is per unit, rounded, then x quantity (the all-in menu price)', () => {
    // Beer 8.00 + 10%: 8.80 each; 2 = 17.60, tax 1.60 (tests/exos/test_pos_scaffold.sql P4).
    expect(lineTotals({ category: 'bar', unitPriceCents: 800, quantity: 2, tax: { ratePercent: 10, priceIncludesTax: false } }))
      .toEqual({ netCents: 1600, taxCents: 160, totalCents: 1760 });
    // NYC 8.875% on 7.00: 62.125 -> 62 per unit; 3 = 21 + 1.86 tax.
    const l = lineTotals({ category: 'bar', unitPriceCents: 700, quantity: 3, tax: { ratePercent: 8.875, priceIncludesTax: false } });
    expect(l).toEqual({ netCents: 2100, taxCents: 186, totalCents: 2286 });
    expect(l.totalCents).toBe(allInCents(700, 8.875) * 3);
  });

  it('inclusive tax is extracted from the line total', () => {
    // GA 20.00 incl. 10%: 2 = 40.00, tax round(4000 x 10 / 110) = 364; 1 = 182.
    expect(lineTotals({ category: 'ticket', unitPriceCents: 2000, quantity: 2, tax: { ratePercent: 10, priceIncludesTax: true } }))
      .toEqual({ netCents: 3636, taxCents: 364, totalCents: 4000 });
    expect(lineTotals({ category: 'ticket', unitPriceCents: 2000, quantity: 1, tax: { ratePercent: 10, priceIncludesTax: true } }).taxCents)
      .toBe(182);
    expect(taxCents(4000, 10, true)).toBe(364);
    expect(taxCents(800, 10, false)).toBe(80);
    expect(taxCents(800, 0, false)).toBe(0);
  });

  it('untaxed and empty lines', () => {
    expect(lineTotals({ category: 'merch', unitPriceCents: 2500, quantity: 1 })).toEqual({ netCents: 2500, taxCents: 0, totalCents: 2500 });
    expect(lineTotals({ category: 'merch', unitPriceCents: 2500, quantity: 0 })).toEqual({ netCents: 0, taxCents: 0, totalCents: 0 });
  });

  it('cart totals add up and split by category', () => {
    const c = cartTotals([
      { category: 'ticket', unitPriceCents: 2000, quantity: 1, tax: { ratePercent: 10, priceIncludesTax: true } },
      { category: 'bar', unitPriceCents: 800, quantity: 1, tax: { ratePercent: 10, priceIncludesTax: false } },
      { category: 'merch', unitPriceCents: 2500, quantity: 1 },
    ]);
    expect(c.totalCents).toBe(2000 + 880 + 2500);
    expect(c.taxCents).toBe(182 + 80);
    expect(c.netCents + c.taxCents).toBe(c.totalCents);
    expect(c.byCategory).toEqual({ ticket: 2000, bar: 880, merch: 2500 });
  });

  it('refuses what the SQL refuses: inactive, 86d, out of stock', () => {
    expect(sellable({ active: true, is86d: false }, 5)).toEqual({ ok: true });
    expect(sellable({ active: false, is86d: false }, 1)).toEqual({ ok: false, reason: 'inactive' });
    expect(sellable({ active: true, is86d: true }, 1)).toEqual({ ok: false, reason: '86d' });
    expect(sellable({ active: true, is86d: false, inventoryCount: 1 }, 2)).toEqual({ ok: false, reason: 'sold-out' });
    expect(sellable({ active: true, is86d: false, inventoryCount: 2 }, 2)).toEqual({ ok: true });
  });
});
