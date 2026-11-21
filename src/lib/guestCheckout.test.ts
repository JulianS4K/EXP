import { describe, expect, it } from 'vitest';
import { clientIp, hashIp, networkOf, normalizeGuestEmail } from '../../supabase/functions/_shared/guest.ts';
import { guestCheckoutAllowed, isGuestEmail } from './guestCheckout';

describe('normalizeGuestEmail', () => {
  it('trims and lower-cases', () => {
    expect(normalizeGuestEmail('  Fan@Example.COM ')).toBe('fan@example.com');
  });
  it.each([undefined, null, 42, '', 'fan', 'fan@', 'fan@x', '@x.com', 'a b@x.com', `${'a'.repeat(250)}@x.com`])(
    'refuses %s',
    (v) => expect(normalizeGuestEmail(v)).toBeNull(),
  );
});

describe('clientIp', () => {
  const h = (m: Record<string, string>) => (k: string) => m[k] ?? null;
  it('trusts the platform, not the client: cf-connecting-ip, then x-real-ip', () => {
    expect(clientIp(h({ 'cf-connecting-ip': '198.51.100.2', 'x-forwarded-for': '6.6.6.6' }))).toBe('198.51.100.2');
    expect(clientIp(h({ 'x-real-ip': '2001:db8::1', 'x-forwarded-for': '6.6.6.6' }))).toBe('2001:db8::1');
  });
  it('takes the last forwarded hop (ours), never the first (the client\'s)', () => {
    expect(clientIp(h({ 'x-forwarded-for': ' 6.6.6.6 , 203.0.113.7' }))).toBe('203.0.113.7');
  });
  it('shares one bucket when nothing usable, instead of skipping the limit', () => {
    expect(clientIp(h({}))).toBe('unknown');
    expect(clientIp(h({ 'x-forwarded-for': 'x'.repeat(65) }))).toBe('unknown');
  });
});

describe('hashIp', () => {
  it('is a salted, stable hex digest that never contains the IP', async () => {
    const a = await hashIp('203.0.113.7', 's1');
    expect(a).toMatch(/^[0-9a-f]{64}$/);
    expect(a).toBe(await hashIp('203.0.113.7', 's1'));
    expect(a).not.toBe(await hashIp('203.0.113.7', 's2'));
    expect(a).not.toContain('203');
    expect(await hashIp(null, 's1')).toBeNull();
  });
});

// S2 (review of #132): a guest's limits are per network; an IPv6 client holds a
// whole /64, so its /64 is the unit (IPv4 stays the full address).
describe('networkOf / hashIp per network', () => {
  it('keeps IPv4 (and IPv4-mapped IPv6) as the address', () => {
    expect(networkOf('203.0.113.7')).toBe('203.0.113.7');
    expect(networkOf('::ffff:203.0.113.7')).toBe('203.0.113.7');
    expect(networkOf('unknown')).toBe('unknown');
  });
  it('reduces IPv6 to its /64, however it is written', () => {
    const n = 'v6:2001:db8:85a3:42';
    expect(networkOf('2001:db8:85a3:42::1')).toBe(n);
    expect(networkOf('2001:0db8:85a3:0042:ffff:ffff:ffff:fffe')).toBe(n);
    expect(networkOf('[2001:DB8:85A3:42::abcd]')).toBe(n);
    expect(networkOf('2001:db8:85a3:42:1:2:3:4%eth0')).toBe(n);
    expect(networkOf('2001:db8::1')).toBe('v6:2001:db8:0:0');
    expect(networkOf('::1')).toBe('v6:0:0:0:0');
    expect(networkOf('64:ff9b::192.0.2.33')).toBe('v6:64:ff9b:0:0');
    expect(networkOf('2001:db8:85a3:43::1')).not.toBe(n);
    // Not an address: unchanged (still hashed, still one bucket).
    expect(networkOf('1:2:3')).toBe('1:2:3');
    expect(networkOf('1::2::3')).toBe('1::2::3');
  });
  it('two /128s in one /64 share a bucket; another /64 does not', async () => {
    const a = await hashIp('2001:db8:85a3:42::1', 's');
    expect(a).toBe(await hashIp('2001:db8:85a3:42:dead:beef:0:7', 's'));
    expect(a).not.toBe(await hashIp('2001:db8:85a3:43::1', 's'));
    expect(await hashIp('198.51.100.1', 's')).not.toBe(await hashIp('198.51.100.2', 's'));
  });
});

describe('SPA guest rules', () => {
  it('isGuestEmail matches the server rule', () => {
    expect(isGuestEmail(' Fan@Example.com ')).toBe(true);
    expect(isGuestEmail('fan@x')).toBe(false);
  });
  it('guest checkout is on unless switched off', () => {
    expect(guestCheckoutAllowed(undefined)).toBe(true);
    expect(guestCheckoutAllowed({ maxPerOrder: 4 } as { guestCheckout?: boolean })).toBe(true);
    expect(guestCheckoutAllowed({ guestCheckout: true })).toBe(true);
    expect(guestCheckoutAllowed({ guestCheckout: false })).toBe(false);
  });
});
