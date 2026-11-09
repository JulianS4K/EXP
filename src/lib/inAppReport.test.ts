import { describe, expect, it, vi } from 'vitest';
vi.mock('./supabase', () => ({ supabase: {} }));
import { parseInAppReport, pct, summarizeInApp } from './inAppReport';

// What exos_event_in_app_report answers (tests/exos/test_ig_checkout.sql IG5).
const RAW = {
  currency: 'usd',
  rows: [
    { in_app_browser: 'instagram', escaped_from: null, started: 4, paid: 2, tickets: 3, gross_cents: 7500 },
    { in_app_browser: 'none', escaped_from: null, started: 2, paid: 1, tickets: 1, gross_cents: 2500 },
    { in_app_browser: 'none', escaped_from: 'instagram', started: 1, paid: 1, tickets: 2, gross_cents: 5000 },
    { in_app_browser: 'facebook', escaped_from: null, started: 1, paid: 1, tickets: 4, gross_cents: 10000 },
    { in_app_browser: null, escaped_from: null, started: 1, paid: 1, tickets: 1, gross_cents: 2500 },
    { in_app_browser: 'Bogus', escaped_from: '<x>', started: '2', paid: 0, tickets: 0, gross_cents: 0 },
  ],
};

describe('summarizeInApp', () => {
  const { rows, currency } = parseInAppReport(RAW);
  const s = summarizeInApp(rows, currency);

  it('one line per app, escapes and browsers apart, apps first', () => {
    expect(s.lines.map((l) => [l.label, l.started, l.paid])).toEqual([
      ['Instagram app', 4, 2],
      ['Facebook app', 1, 1],
      ['Browser, opened from Instagram', 1, 1],
      ['Browser', 2, 1],
      ['Not recorded', 3, 1],
    ]);
    expect(s.lines[0].conversion).toBe(0.5);
    expect(currency).toBe('USD');
  });

  it('compares in-app conversion with the browser (escapes count as browser)', () => {
    expect(s.inApp).toEqual({ started: 5, paid: 3, conversion: 0.6 });
    expect(s.browser.started).toBe(3);
    expect(s.browser.conversion).toBeCloseTo(2 / 3);
    expect(s.ratio).toBeCloseTo(0.9);
    // Instagram + Facebook + the Instagram escape over all paid gross.
    expect(s.inAppGrossShare).toBeCloseTo(22500 / 27500);
  });

  it('copes with nothing', () => {
    const e = summarizeInApp([]);
    expect(e.lines).toEqual([]);
    expect(e.ratio).toBeNull();
    expect(e.inAppGrossShare).toBeNull();
    expect(pct(null)).toBe('–');
    expect(pct(0.904)).toBe('90%');
    expect(parseInAppReport(null)).toEqual({ rows: [], currency: 'USD' });
  });
});
