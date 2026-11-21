import { describe, expect, it } from 'vitest';
import { isAllowedRedirect, parseRedirectOrigins } from '../../supabase/functions/_shared/redirects.ts';

const allowed = parseRedirectOrigins(' https://exos.example/ , http://localhost:3000,,');

describe('parseRedirectOrigins', () => {
  it('trims, drops trailing slashes and empties', () => {
    expect(allowed).toEqual(['https://exos.example', 'http://localhost:3000']);
    expect(parseRedirectOrigins(undefined)).toEqual([]);
  });
});

describe('isAllowedRedirect', () => {
  it.each([
    'https://exos.example/bridge/my-tickets?checkout=success',
    'https://exos.example/bridge/event/1',
  ])('allows %s', (u) => expect(isAllowedRedirect(u, allowed)).toBe(true));

  it.each([
    'https://evil.example/bridge/my-tickets',
    'https://exos.example.evil.example/',
    'https://exos.example@evil.example/',
    'https://user:pw@exos.example/',
    'http://exos.example/bridge/',
    'javascript:alert(1)',
    '//evil.example/',
    '/bridge/my-tickets',
    'https://exos.example:8443/',
    '',
    // Loopback is never a target, even configured (another app can listen there).
    'http://localhost:3000/bridge/orgs/1/settings',
  ])('refuses %s', (u) => expect(isAllowedRedirect(u, allowed)).toBe(false));

  it('refuses non-strings and oversized URLs', () => {
    expect(isAllowedRedirect(undefined, allowed)).toBe(false);
    expect(isAllowedRedirect('https://exos.example/' + 'a'.repeat(2100), allowed)).toBe(false);
  });

  it('ignores a configured loopback or non-https origin', () => {
    const lo = parseRedirectOrigins('https://localhost,https://127.0.0.1,https://[::1],https://door.localhost,http://exos.example,capacitor://localhost');
    for (const u of ['https://localhost/x', 'https://127.0.0.1/x', 'https://[::1]/x', 'https://door.localhost/x', 'http://exos.example/x', 'capacitor://localhost/x']) {
      expect(isAllowedRedirect(u, lo)).toBe(false);
    }
  });

  it('refuses everything when nothing is configured', () => {
    expect(isAllowedRedirect('https://exos.example/', [])).toBe(false);
  });
});
