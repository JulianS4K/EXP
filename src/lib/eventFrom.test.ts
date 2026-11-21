import { describe, expect, it } from 'vitest';
import { Timestamp } from './timestamp';
import { pageFrom } from './eventFrom';
import { eventFrom, eventLine, fromLabel } from '../../supabase/functions/_shared/eventStrings.ts';
import { priceAndAvailability } from '../../supabase/functions/_shared/catalog/feed.ts';
import { eventSummary, eventTags } from './hosting/seo';

const now = new Date('2026-11-21T12:00:00Z');
const ts = (iso: string) => Timestamp.fromDate(new Date(iso));
const tier = (o: Record<string, unknown>) => ({ id: 't', name: 'GA', description: '', price: 20, capacity: 100, sold: 0, ...o });

describe('one "from" price for the page, the crawler card and the feed', () => {
  it('skips a sold-out early bird (was the crawler card\'s lowest-of-all)', () => {
    const page = [tier({ id: 'eb', price: 10, capacity: 50, sold: 50 }), tier({ id: 'ga', price: 20 })];
    expect(pageFrom(page as never, {}, now)).toMatchObject({ cents: 2000, availability: 'in stock' });
    const rows = [
      { id: 'eb', event_id: 'e', price: 10, capacity: 50, sold: 50, sales_start: null, sales_end: null },
      { id: 'ga', event_id: 'e', price: 20, capacity: 100, sold: 0, sales_start: null, sales_end: null },
    ];
    expect(priceAndAvailability({ total_tickets: 0, tickets_sold: 0 }, rows, now)?.cents).toBe(2000);
    const s = eventSummary({ id: 'e', name: 'Show', starts_at: '2026-12-04T22:00:00' }, rows, null, now)!;
    expect(s.fromCents).toBe(2000);
    expect(s.from).toBe('$20');
  });

  it('a tier not yet on sale counts as a presale price; all sold out is out of stock', () => {
    const later = [tier({ price: 15, salesStart: ts('2026-12-01T00:00:00Z') })];
    expect(pageFrom(later as never, {}, now)).toMatchObject({ cents: 1500, availability: 'preorder' });
    const gone = [tier({ price: 15, capacity: 10, sold: 10 })];
    expect(pageFrom(gone as never, {}, now)?.availability).toBe('out of stock');
    expect(pageFrom([], {}, now)).toBeNull();
  });

  it('is all-in: exclusive tax and passed-on fees included', () => {
    const t = [tier({ price: 20, exclusiveTaxPercent: 10, passedOnFees: [{ name: 'Facility', calc: 'fixed', amount_cents: 200, percent: 0, cap_cents: null, taxable: false, per: 'ticket', kind: 'fee' }] })];
    const r = pageFrom(t as never, {}, now)!;
    expect(r.cents).toBeGreaterThan(2000);
    expect(eventFrom([{ price: 20, exclusive_tax_percent: 10, capacity: 5, sold: 0 }], now)?.cents).toBe(2200);
  });

  it('the card line is the shared formatter', () => {
    expect(fromLabel(0, 'USD')).toBe('Free');
    expect(fromLabel(2550, 'USD')).toBe('from $25.50 all-in');
    expect(eventLine({ date: 'Fri Dec 4 · 10 PM', venue: 'Elsewhere', fromCents: 2500, currency: 'USD' }))
      .toBe('Fri Dec 4 · 10 PM · Elsewhere · from $25 all-in');
    const s = eventSummary({ id: 'e', name: 'Show', starts_at: '2026-12-04T22:00:00', venue_name: 'Elsewhere' },
      [{ price: 25, capacity: 10, sold: 0 } as never], null, now)!;
    expect(eventTags(s, 'https://x/e', 'https://x/bridge/icon-512.png')).toContain('Fri Dec 4 · 10 PM · Elsewhere · from $25 all-in');
  });
});
