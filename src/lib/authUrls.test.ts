// @vitest-environment jsdom
import { beforeEach, describe, expect, it } from 'vitest';
import {
  appBaseUrl,
  authUrl,
  authUrlParams,
  callbackUrl,
  normalizeBase,
  rememberReturnPath,
  sanitizeReturnPath,
  takeReturnPath,
} from './authUrls';

const bridge = { BASE_URL: '/bridge/' };

describe('appBaseUrl / authUrl', () => {
  it.each([
    ['https://exos-web.onrender.com', 'https://exos-web.onrender.com/bridge'],
    ['https://vibepass-storefront-test.onrender.com', 'https://vibepass-storefront-test.onrender.com/bridge'],
    ['http://localhost:3000', 'http://localhost:3000/bridge'],
  ])('uses the current origin %s + the vite base', (origin, want) => {
    expect(appBaseUrl({ origin, env: bridge })).toBe(want);
    expect(authUrl('/reset-password', { origin, env: bridge })).toBe(`${want}/reset-password`);
  });

  it('falls back to VITE_APP_URL, with or without the base', () => {
    expect(appBaseUrl({ origin: null, env: { ...bridge, VITE_APP_URL: 'https://app.example/' } })).toBe('https://app.example/bridge');
    expect(appBaseUrl({ origin: null, env: { ...bridge, VITE_APP_URL: 'https://app.example/bridge' } })).toBe('https://app.example/bridge');
    expect(appBaseUrl({ origin: 'capacitor://localhost', env: { ...bridge, VITE_APP_URL: 'https://app.example' } })).toBe('https://app.example/bridge');
  });

  it('works at the root base too', () => {
    expect(authUrl('auth/callback', { origin: 'https://x.test', env: { BASE_URL: '/' } })).toBe('https://x.test/auth/callback');
    expect(normalizeBase('/')).toBe('');
    expect(normalizeBase('bridge/')).toBe('/bridge');
  });

  it('callbackUrl carries a clean ?next=', () => {
    const opts = { origin: 'https://x.test', env: bridge };
    expect(callbackUrl('/event/1?tier=2', opts)).toBe('https://x.test/bridge/auth/callback?next=%2Fevent%2F1%3Ftier%3D2');
    expect(callbackUrl('/', opts)).toBe('https://x.test/bridge/auth/callback');
    expect(callbackUrl('https://evil.example/', opts)).toBe('https://x.test/bridge/auth/callback');
  });
});

describe('sanitizeReturnPath', () => {
  it.each([
    ['/event/1', '/event/1'],
    ['/claim/abc?k=xyz', '/claim/abc?k=xyz'],
    ['/bridge/my-tickets', '/my-tickets'],
    ['/bridge', '/'],
    ['/profile#account', '/profile'],
    ['/a/../b', '/b'],
  ])('keeps %s as %s', (raw, want) => expect(sanitizeReturnPath(raw, '/bridge/')).toBe(want));

  it.each([
    'https://evil.example/',
    '//evil.example/x',
    '/\\evil.example',
    '\\\\evil.example',
    'javascript:alert(1)',
    'event/1',
    '/x\u0000y',
    '/x\ny',
    '',
    '   ',
    '/auth/callback?next=/x',
    '/bridge/reset-password',
    '/' + 'a'.repeat(600),
  ])('refuses %j', (raw) => expect(sanitizeReturnPath(raw, '/bridge/')).toBeNull());

  it('refuses non-strings', () => {
    expect(sanitizeReturnPath(undefined)).toBeNull();
    expect(sanitizeReturnPath({ path: '/x' })).toBeNull();
  });
});

describe('remember / take return path', () => {
  beforeEach(() => localStorage.clear());

  it('round-trips once, and ?next= wins', () => {
    rememberReturnPath('/event/9');
    expect(takeReturnPath(null)).toBe('/event/9');
    expect(takeReturnPath(null)).toBe('/');
    rememberReturnPath('/event/9');
    expect(takeReturnPath('/my-tickets')).toBe('/my-tickets');
  });

  it('ignores stale, junk and unsafe values', () => {
    localStorage.setItem('exos.authReturn', JSON.stringify({ path: '/event/1', at: 0 }));
    expect(takeReturnPath(null, 10 * 24 * 3600 * 1000)).toBe('/');
    localStorage.setItem('exos.authReturn', '{nope');
    expect(takeReturnPath(null)).toBe('/');
    localStorage.setItem('exos.authReturn', JSON.stringify({ path: '//evil.example', at: Date.now() }));
    expect(takeReturnPath('https://evil.example')).toBe('/');
  });
});

describe('authUrlParams', () => {
  it('reads the query and a token-style hash', () => {
    expect(authUrlParams('https://x.test/bridge/reset-password?code=abc#error=access_denied&error_code=otp_expired')).toEqual({
      code: 'abc',
      error: 'access_denied',
      error_code: 'otp_expired',
    });
  });

  it('ignores a plain anchor hash and junk', () => {
    expect(authUrlParams('https://x.test/profile#account')).toEqual({});
    expect(authUrlParams('not a url')).toEqual({});
  });
});
