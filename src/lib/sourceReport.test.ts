import { describe, expect, it } from 'vitest';
import {
  DIRECT_LABEL,
  SOURCES_CSV_HEADER,
  adPlatformOf,
  sourceKeyOf,
  sourcesCsvRows,
  summarizeSources,
  type SourceSessionRow,
} from './sourceReport';

let n = 0;
const row = (over: Partial<SourceSessionRow>): SourceSessionRow => ({
  session_id: `cs_${++n}`,
  status: 'fulfilled',
  quantity: 1,
  amount_cents: 1000,
  currency: 'usd',
  ...over,
});

describe('adPlatformOf', () => {
  it.each([
    [{ gclid: 'g' }, 'Google'], [{ gbraid: 'g' }, 'Google'], [{ wbraid: 'g' }, 'Google'],
    [{ fbclid: 'f' }, 'Meta'], [{ fbc: 'fb.1.1.x' }, 'Meta'], [{ ttclid: 't' }, 'TikTok'],
    [{ rdt_cid: 'r' }, 'Reddit'], [{ ScCid: 's' }, 'Snap'], [{ twclid: 'x' }, 'X'], [{ msclkid: 'm' }, 'Microsoft'],
  ] as [Record<string, unknown>, string][])('%o → %s', (ids, platform) => {
    expect(adPlatformOf(ids)).toBe(platform);
  });
  it('ignores browser ids that are not clicks, and empty values', () => {
    expect(adPlatformOf({ fbp: 'fb.1.1.2', ga_client_id: '1.2', gclid: '  ' })).toBeNull();
    expect(adPlatformOf(null)).toBeNull();
  });
  it('falls back to fbclid kept in attribution (before ad_ids existed)', () => {
    expect(adPlatformOf(null, { fbclid: 'IwAR' })).toBe('Meta');
  });
  it('breaks a tie in a fixed order', () => {
    expect(adPlatformOf({ ttclid: 't', gclid: 'g' })).toBe('Google');
  });
});

describe('sourceKeyOf', () => {
  it('lower-cases UTM and prefers the promoter column', () => {
    expect(sourceKeyOf(row({
      promoter_id: 'dj-kay',
      attribution: { utm_source: ' Instagram ', utm_medium: 'Paid_Social', utm_campaign: 'Launch', promoter: 'other' },
      ad_ids: { fbclid: 'x' },
    }))).toEqual({ source: 'instagram', medium: 'paid_social', campaign: 'launch', promoter: 'dj-kay', platform: 'Meta' });
    expect(sourceKeyOf(row({ attribution: { promoter: 'p1' } })).promoter).toBe('p1');
  });
});

describe('summarizeSources', () => {
  const sessions = [
    row({ attribution: { utm_source: 'instagram', utm_medium: 'paid_social', utm_campaign: 'launch' }, ad_ids: { fbclid: 'a' }, quantity: 2, amount_cents: 5000 }),
    row({ attribution: { utm_source: 'Instagram', utm_medium: 'paid_social', utm_campaign: 'launch' }, ad_ids: { fbclid: 'b' }, quantity: 1, amount_cents: 2500, status: 'refunded' }),
    row({ attribution: { utm_source: 'google', utm_medium: 'cpc' }, ad_ids: { gclid: 'g' }, amount_cents: 3000 }),
    row({ promoter_id: 'dj-kay', quantity: 3, amount_cents: 9000, status: 'partially_refunded' }),
    row({ amount_cents: 1000 }),
    row({ attribution: null, ad_ids: null, amount_cents: 1000 }),
    row({ status: 'pending', amount_cents: 99999 }),
    row({ status: 'expired', attribution: { utm_source: 'x' } }),
  ];

  it('groups every part together, direct last, sorted by gross', () => {
    const s = summarizeSources(sessions);
    expect(s.orders).toBe(6);
    expect(s.tickets).toBe(9);
    expect(s.grossCents).toBe(21500);
    expect(s.attributedOrders).toBe(4);
    expect(s.currency).toBe('USD');
    expect(s.mixedCurrencies).toBe(false);
    expect(s.rows.map((r) => [r.label, r.orders, r.tickets, r.grossCents, r.refundedOrders])).toEqual([
      ['promoter dj-kay', 1, 3, 9000, 0],
      ['instagram / paid_social · launch · Meta', 2, 3, 7500, 1],
      ['google / cpc · Google', 1, 1, 3000, 0],
      [DIRECT_LABEL, 2, 2, 2000, 0],
    ]);
    expect(s.rows.at(-1)!.direct).toBe(true);
  });

  it('breaks down by one dimension', () => {
    expect(summarizeSources(sessions, 'platform').rows.map((r) => [r.label, r.orders])).toEqual([
      ['Meta', 2], ['Google', 1], ['No ad click id', 3],
    ]);
    expect(summarizeSources(sessions, 'promoter').rows.map((r) => [r.label, r.orders])).toEqual([
      ['promoter dj-kay', 1], ['No promoter', 5],
    ]);
    expect(summarizeSources(sessions, 'source').rows.map((r) => r.label)).toEqual([
      'instagram / paid_social', 'google / cpc', 'No UTM source',
    ]);
    expect(summarizeSources(sessions, 'campaign').rows.map((r) => r.label)).toEqual(['launch', 'No campaign']);
  });

  it('flags mixed currencies and handles nothing sold', () => {
    const s = summarizeSources([row({ currency: 'usd' }), row({ currency: 'eur' })], 'all', 'gbp');
    expect(s.mixedCurrencies).toBe(true);
    expect(s.currency).toBe('GBP');
    const empty = summarizeSources([], 'all', 'usd');
    expect(empty).toMatchObject({ rows: [], orders: 0, grossCents: 0, currency: 'USD' });
  });

  it('exports CSV rows matching the header', () => {
    const s = summarizeSources(sessions);
    const rows = sourcesCsvRows(s);
    expect(rows.every((r) => r.length === SOURCES_CSV_HEADER.length)).toBe(true);
    expect(rows[1]).toEqual(['instagram', 'paid_social', 'launch', '', 'Meta', 2, 3, '75.00', 1, 'USD']);
    expect(rows.at(-1)).toEqual([DIRECT_LABEL, '', '', '', '', 2, 2, '20.00', 0, 'USD']);
  });
});
