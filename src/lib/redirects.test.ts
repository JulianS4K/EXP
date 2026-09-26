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
    'http://localhost:3000/bridge/orgs/1/settings',
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
  ])('refuses %s', (u) => expect(isAllowedRedirect(u, allowed)).toBe(false));

  it('refuses non-strings and oversized URLs', () => {
    expect(isAllowedRedirect(undefined, allowed)).toBe(false);
    expect(isAllowedRedirect('https://exos.example/' + 'a'.repeat(2100), allowed)).toBe(false);
  });

  it('refuses everything when nothing is configured', () => {
    expect(isAllowedRedirect('https://exos.example/', [])).toBe(false);
  });
});
