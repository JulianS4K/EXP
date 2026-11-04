import { describe, expect, it } from 'vitest';
import { parseCsv, planOfferImport, toCents } from './offerImport';

describe('parseCsv', () => {
  it('handles quotes, doubled quotes, CRLF and a BOM; drops blank lines', () => {
    expect(parseCsv('﻿a,b\r\n"x, y","say ""hi"""\n\n1,2')).toEqual([['a', 'b'], ['x, y', 'say "hi"'], ['1', '2']]);
  });
});

describe('toCents', () => {
  it('reads major units', () => {
    expect([toCents('1,500.00'), toCents('$25'), toCents(''), toCents('12.345')]).toEqual([150000, 2500, null, Number.NaN]);
  });
});

describe('planOfferImport', () => {
  const csv = [
    'Artist,Date,Deal,Guarantee,Percentage,Agent,Agent Email,Capacity,Average Price,Group,Billing,Mystery',
    'Fest One,2026-12-05,door,,70%,Ann,ann@x.example,800,30,fest,headliner,?',
    'Fest Two,2026-12-05;2026-12-06,flat,"1,000",,,,,,fest,support,',
    'Bad,12/05/2026,versus,lots,85,,,,,,,',
    ',2026-12-07,flat,100,,,,,,,,',
  ].join('\n');

  it('maps columns to offer bodies and reports bad rows', () => {
    const p = planOfferImport(csv);
    expect(p.ignored).toEqual(['Mystery']);
    expect(p.rows).toEqual([
      { artist_name: 'Fest One', dates: ['2026-12-05'], terms: { deal_type: 'door', percentage: 70 }, act_type: 'headliner',
        agent: { name: 'Ann', email: 'ann@x.example', company: null }, budget: { capacity: 800, average_price_cents: 3000 }, group: 'fest' },
      { artist_name: 'Fest Two', dates: ['2026-12-05', '2026-12-06'], terms: { deal_type: 'flat', guarantee_cents: 100000 }, act_type: 'support', group: 'fest' },
    ]);
    expect(p.errors.map((e) => e.row)).toEqual([3, 4]);
    expect(p.errors[0].error).toMatch(/guarantee is not an amount; dates must be YYYY-MM-DD/);
  });

  it('needs an artist column and at most 200 rows', () => {
    expect(planOfferImport('Name,Date\nx,2026-01-01').errors[0].error).toMatch(/artist/);
    expect(planOfferImport(`Artist\n${'a\n'.repeat(201)}`).errors[0].error).toMatch(/200/);
    expect(planOfferImport('Artist').errors[0].error).toMatch(/header/);
  });
});
