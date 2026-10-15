import { describe, expect, it } from 'vitest';
import { domainRedirect, hostOnly, isPrimary, primaryHosts, ttlCache } from './domains';

describe('custom domains', () => {
  it('normalizes hosts', () => {
    expect(hostOnly('Tickets.WLHall.com:443')).toBe('tickets.wlhall.com');
    expect(hostOnly('localhost:3000')).toBe('localhost');
    expect(hostOnly('evil host')).toBeNull();
    expect(hostOnly(undefined)).toBeNull();
  });
  it('knows its own hosts', () => {
    const p = primaryHosts('https://exos-web.onrender.com', ['exos.live']);
    expect(isPrimary('exos-web.onrender.com', p)).toBe(true);
    expect(isPrimary('exos.live', p)).toBe(true);
    expect(isPrimary('anything.onrender.com', p)).toBe(true);
    expect(isPrimary('tickets.wlhall.com', p)).toBe(false);
  });
  it('sends only the root to the storefront', () => {
    expect(domainRedirect('/', 'wl-hall')).toBe('/bridge/o/wl-hall');
    expect(domainRedirect('/bridge/', 'wl-hall')).toBe('/bridge/o/wl-hall');
    expect(domainRedirect('/bridge/event/1', 'wl-hall')).toBeNull();
    expect(domainRedirect('/', null)).toBeNull();
    expect(domainRedirect('/', '../x')).toBeNull();
  });
  it('caches with a ttl', () => {
    const c = ttlCache<string | null>(1000, 2);
    c.set('a', 'x', 0);
    expect(c.get('a', 500)).toBe('x');
    expect(c.get('a', 1500)).toBeUndefined();
    c.set('b', null, 0); c.set('c', 'y', 0); c.set('d', 'z', 0);
    expect(c.get('b', 1)).toBeUndefined();
  });
});
