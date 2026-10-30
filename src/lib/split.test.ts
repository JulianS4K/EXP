// Split with friends (mig 20261031220000): share amounts and the pay links.
import { describe, expect, it, vi } from 'vitest';
vi.mock('./supabase', () => ({ supabase: {} }));
import {
  cashAppUrl, evenSplit, fallbackLine, friendMessage, friendShares, normalizeCashtag, normalizeVenmo, smsUrl, totalShares,
  venmoPayUrl,
} from './split';

describe('split amounts', () => {
  it('splits evenly to the cent, never losing or inventing one', () => {
    expect(evenSplit(6000, 3)).toEqual([2000, 2000, 2000]);
    expect(evenSplit(10000, 3)).toEqual([3334, 3333, 3333]);
    expect(evenSplit(1, 4)).toEqual([1, 0, 0, 0]);
    for (const [t, n] of [[9999, 7], [12345, 4], [100, 100], [0, 3]]) {
      const s = evenSplit(t, n);
      expect(s.reduce((a, b) => a + b, 0)).toBe(t);
      expect(Math.max(...s) - Math.min(...s)).toBeLessThanOrEqual(1);
    }
    expect(evenSplit(100, 0)).toEqual([]);
    expect(evenSplit(10.5, 2)).toEqual([]);
  });

  it("friends pay a ticket's share each; the host keeps the odd cents", () => {
    // $100.00 for 3 tickets, host keeps one: friends pay 33.33 each, host 33.34.
    expect(friendShares(10000, 3, 2)).toEqual([3333, 3333]);
    expect(friendShares(10000, 3, 3)).toEqual([3334, 3333, 3333]);
    expect(friendShares(10000, 3, 4)).toEqual([]);
    expect(totalShares(friendShares(10000, 3, 2).map((amountCents) => ({ amountCents })))).toBeLessThanOrEqual(10000);
  });
});

describe('pay links', () => {
  it('prefills Venmo with the amount and a note', () => {
    const u = new URL(venmoPayUrl('@host_venmo', 3333, 'EA Show ticket')!);
    expect(u.origin + u.pathname).toBe('https://venmo.com/host_venmo');
    expect(u.searchParams.get('txn')).toBe('pay');
    expect(u.searchParams.get('amount')).toBe('33.33');
    expect(u.searchParams.get('note')).toBe('EA Show ticket');
    expect(venmoPayUrl('bad handle!', 100, 'x')).toBeNull();
    expect(venmoPayUrl('host', 0, 'x')).toBeNull();
  });

  it('Cash App as the backup', () => {
    expect(cashAppUrl('$hostcash', 1500)).toBe('https://cash.app/$hostcash/15.00');
    expect(cashAppUrl('1bad', 1500)).toBeNull();
    expect(normalizeCashtag('$Host_1')).toBe('Host_1');
    expect(normalizeVenmo('@a')).toBeNull();
  });

  it('falls back to the handle and amount when a link stops prefilling', () => {
    expect(fallbackLine({ venmo: 'host', cashapp: 'hostcash', cents: 2000 })).toBe('$20.00 to Venmo @host or Cash App $hostcash');
    expect(fallbackLine({ cents: 2000 })).toBe('$20.00 to me');
  });

  it('one text per friend: ticket link first, then how to pay', () => {
    const m = friendMessage({ friendName: 'Ann Lee', eventTitle: 'EA Show', claimUrl: 'https://x/claim/1?k=2', cents: 2000, venmo: 'host', cashapp: 'hc' });
    const lines = m.split('\n');
    expect(lines[0]).toBe('Hey Ann! Your ticket for EA Show:');
    expect(lines[1]).toBe('https://x/claim/1?k=2');
    expect(lines[2]).toBe('Your share: $20.00 to Venmo @host or Cash App $hc.');
    expect(lines[3]).toMatch(/^Venmo: https:\/\/venmo\.com\/host\?txn=pay&amount=20\.00/);
    expect(lines[4]).toBe('Cash App: https://cash.app/$hc/20.00');
    // on_paid: no link yet.
    expect(friendMessage({ friendName: 'Bo', eventTitle: 'S', claimUrl: null, cents: 0 })).toContain("I'll send it");
  });

  it('opens the host\'s own messages app', () => {
    expect(smsUrl('+1 (212) 555-0100', 'hi & bye')).toBe('sms:+12125550100?&body=hi%20%26%20bye');
    expect(smsUrl(null, 'x')).toBe('sms:?&body=x');
  });
});
