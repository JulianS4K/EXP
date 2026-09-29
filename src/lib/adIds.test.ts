import { beforeEach, describe, expect, it, vi } from 'vitest';
import {
  CLICK_ID_KEYS,
  browserIdsFromCookies,
  gaClientIdFromCookie,
  normalizeConsent,
  parseCookies,
  readAdIds,
  sanitizeClickId,
  sanitizeFbCookie,
  truncateUserAgent,
} from '../../supabase/functions/_shared/adIds.ts';

// Node test environment: a minimal in-memory sessionStorage.
const store = new Map<string, string>();
vi.stubGlobal('sessionStorage', {
  getItem: (k: string) => store.get(k) ?? null,
  setItem: (k: string, v: string) => void store.set(k, String(v)),
  removeItem: (k: string) => void store.delete(k),
  clear: () => store.clear(),
});

const consent = vi.hoisted(() => ({ state: 'unset' as 'granted' | 'denied' | 'unset' }));
vi.mock('./consent', () => ({ getConsent: () => consent.state }));

import { captureClickIds, checkoutAdIds, checkoutConsent, clickIdsFromSearch } from './adIds';

describe('sanitizeClickId', () => {
  it('keeps opaque [A-Za-z0-9._-] ids up to 256 chars', () => {
    expect(sanitizeClickId('Cj0KCQjw-abc_123.x')).toBe('Cj0KCQjw-abc_123.x');
    expect(sanitizeClickId('  abc  ')).toBe('abc');
    expect(sanitizeClickId('a'.repeat(256))).toHaveLength(256);
  });
  it.each([undefined, null, 42, '', ' ', 'a'.repeat(257), '<script>', 'a b', 'a"b', "a'b", 'a/b', 'ü'])(
    'drops %s',
    (v) => expect(sanitizeClickId(v)).toBeUndefined(),
  );
});

describe('readAdIds', () => {
  it('keeps every platform click id and drops unknown keys and bad values', () => {
    const src: Record<string, unknown> = {
      gclid: 'g1', gbraid: 'gb', wbraid: 'wb', ttclid: 'tt', rdt_cid: 'rd', ScCid: 'sc', twclid: 'tw',
      msclkid: 'ms', fbclid: 'IwAR0', evil: 'x', sccid: 'lowercase-is-not-snap',
    };
    expect(readAdIds((k) => src[k])).toEqual({
      gclid: 'g1', gbraid: 'gb', wbraid: 'wb', ttclid: 'tt', rdt_cid: 'rd', ScCid: 'sc', twclid: 'tw', msclkid: 'ms', fbclid: 'IwAR0',
    });
    expect(CLICK_ID_KEYS).toHaveLength(9);
    expect(readAdIds((k) => (k === 'gclid' ? 'bad value' : undefined))).toEqual({});
  });
  it('keeps browser ids only in their own shapes', () => {
    const src: Record<string, unknown> = { fbp: 'fb.1.1690000000000.123456789', fbc: 'fb.1.1690000000000.IwAR0', ga_client_id: '123.456' };
    expect(readAdIds((k) => src[k])).toEqual(src);
    expect(readAdIds((k) => ({ fbp: 'nope', fbc: 'fb.1.x.y', ga_client_id: 'GA1.1.1.2' } as Record<string, unknown>)[k])).toEqual({});
  });
});

describe('cookies', () => {
  it('parses a cookie string, first value wins', () => {
    expect(parseCookies('a=1; b=hello%20world; a=2; =x; c')).toEqual({ a: '1', b: 'hello world' });
    expect(parseCookies(undefined)).toEqual({});
  });
  it('reads _fbp, _fbc and the GA client id', () => {
    expect(browserIdsFromCookies('_ga=GA1.1.123456789.1690000000; _fbp=fb.1.1690000000000.987; _fbc=fb.1.1690000000000.IwAR0; x=y'))
      .toEqual({ ga_client_id: '123456789.1690000000', fbp: 'fb.1.1690000000000.987', fbc: 'fb.1.1690000000000.IwAR0' });
    expect(browserIdsFromCookies('_ga=junk; _fbp=<b>')).toEqual({});
  });
  it('takes the last two parts of a _ga cookie', () => {
    expect(gaClientIdFromCookie('GA1.2.111.222')).toBe('111.222');
    expect(gaClientIdFromCookie('111.222')).toBeUndefined();
    expect(gaClientIdFromCookie('GA1.2.abc.222')).toBeUndefined();
  });
  it('caps an _fbc cookie', () => {
    expect(sanitizeFbCookie(`fb.1.1690000000000.${'a'.repeat(256)}`)).toBeDefined();
    expect(sanitizeFbCookie(`fb.1.1690000000000.${'a'.repeat(257)}`)).toBeUndefined();
  });
});

describe('consent and user agent', () => {
  it('normalizes consent to granted / denied / unknown', () => {
    expect(normalizeConsent('granted')).toBe('granted');
    expect(normalizeConsent('denied')).toBe('denied');
    expect(normalizeConsent('unset')).toBe('unknown');
    expect(normalizeConsent(undefined)).toBe('unknown');
    expect(normalizeConsent('GRANTED')).toBe('unknown');
  });
  it('strips control characters and caps the user agent at 512', () => {
    expect(truncateUserAgent('Mozilla/5.0\n(X)\u0000')).toBe('Mozilla/5.0(X)');
    expect(truncateUserAgent('u'.repeat(600))).toHaveLength(512);
    expect(truncateUserAgent('   ')).toBeNull();
    expect(truncateUserAgent(null)).toBeNull();
  });
});

describe('client capture (lib/adIds)', () => {
  beforeEach(() => {
    sessionStorage.clear();
    consent.state = 'unset';
  });

  it('reads click ids off the URL, never UTM or browser ids', () => {
    expect(clickIdsFromSearch('?gclid=g1&utm_source=ig&fbp=fb.1.1.2&ttclid=t1')).toEqual({ gclid: 'g1', ttclid: 't1' });
  });

  it('keeps click ids for the visit (survives a sign-in round trip); a newer click wins', () => {
    captureClickIds('ev1', '?gclid=first&ttclid=t1');
    expect(captureClickIds('ev1', '')).toEqual({ gclid: 'first', ttclid: 't1' });
    expect(captureClickIds('ev1', '?gclid=second')).toEqual({ gclid: 'second', ttclid: 't1' });
    expect(captureClickIds('ev2', '')).toEqual({});
  });

  it('ignores a tampered stash', () => {
    sessionStorage.setItem('exos_adids:ev1', JSON.stringify({ gclid: '<x>', evil: 'y', fbp: 'fb.1.1.2' }));
    expect(captureClickIds('ev1', '')).toEqual({});
  });

  it('reads browser-id cookies only with consent', () => {
    captureClickIds('ev1', '?gclid=g1');
    const jar = '_fbp=fb.1.1690000000000.987; _ga=GA1.1.5.6';
    expect(checkoutAdIds('ev1', '', jar)).toEqual({ gclid: 'g1' });
    consent.state = 'denied';
    expect(checkoutAdIds('ev1', '', jar)).toEqual({ gclid: 'g1' });
    expect(checkoutConsent()).toBe('denied');
    consent.state = 'granted';
    expect(checkoutAdIds('ev1', '', jar)).toEqual({ gclid: 'g1', fbp: 'fb.1.1690000000000.987', ga_client_id: '5.6' });
    expect(checkoutConsent()).toBe('granted');
  });
});
