import { describe, expect, it } from 'vitest';
import { apiPath, matchRoute, ROUTES } from '../../supabase/functions/_shared/api/routes.ts';
import { effectiveScopes, hasScope, READ_SCOPES, SCOPES } from '../../supabase/functions/_shared/api/scopes.ts';
import { PagingError, pageEnvelope, parsePage } from '../../supabase/functions/_shared/api/paging.ts';

describe('apiPath', () => {
  it('strips the function prefix, /v1 and trailing slashes', () => {
    expect(apiPath('/functions/v1/exos-api/events')).toBe('/events');
    expect(apiPath('/functions/v1/exos-api/v1/events/')).toBe('/events');
    expect(apiPath('/exos-api')).toBe('/');
    expect(apiPath('/exos-api/v1')).toBe('/');
    expect(apiPath('/functions/v1/exos-api/v1x')).toBe('/v1x');
    expect(apiPath('/functions/v1/exos-apix/events')).toBe('/functions/v1/exos-apix/events');
  });
});

describe('matchRoute', () => {
  it('matches every documented path with its params', () => {
    const m = matchRoute('GET', '/events/abc/attendees');
    expect(m?.route.id).toBe('list-attendees');
    expect(m?.params).toEqual({ id: 'abc' });
    expect(matchRoute('GET', '/events')?.route.id).toBe('list-events');
    expect(matchRoute('GET', '/orders/cs_test_1')?.params).toEqual({ id: 'cs_test_1' });
    expect(matchRoute('get', '/me')?.route.id).toBe('me');
    expect(matchRoute('POST', '/events')?.route.id).toBe('create-event');
    expect(matchRoute('PATCH', '/events/e1/ticket-types/t1')?.params).toEqual({ id: 'e1', tier: 't1' });
    expect(matchRoute('POST', '/orders/cs_1/refunds')?.route.id).toBe('create-refund');
    expect(matchRoute('GET', '/orders/cs_1/refunds')).toBeNull();
  });

  it('refuses unknown paths, other methods and malformed escapes', () => {
    expect(matchRoute('GET', '/events/abc/secrets')).toBeNull();
    expect(matchRoute('PUT', '/events')).toBeNull();
    expect(matchRoute('DELETE', '/events/abc')).toBeNull();
    expect(matchRoute('HEAD', '/me')).toBeNull();
    expect(matchRoute('GET', '/events/%E0%A4%A')).toBeNull();
    expect(matchRoute('GET', '/')).toBeNull();
  });

  it('every route row is unique, scoped from the vocabulary and paths are well formed', () => {
    const ids = new Set(ROUTES.map((r) => r.id));
    expect(ids.size).toBe(ROUTES.length);
    const keys = new Set(ROUTES.map((r) => `${r.method} ${r.path}`));
    expect(keys.size).toBe(ROUTES.length);
    for (const r of ROUTES) {
      expect(r.path).toMatch(/^(\/([a-z-]+|:[a-z]+))+$/);
      if (r.scope !== null) expect(SCOPES).toContain(r.scope);
      expect(matchRoute(r.method, r.path.replace(/:[a-z]+/g, 'x'))?.route.id).toBe(r.id);
    }
    // Only GET /me is reachable without a scope.
    expect(ROUTES.filter((r) => r.scope === null).map((r) => r.id)).toEqual(['me']);
    // Reads need a :read scope (or none, /me); writes a :write scope or org:admin.
    for (const r of ROUTES) {
      if (r.method === 'GET') expect(r.scope === null || r.scope.endsWith(':read') || r.scope === 'org:admin', r.id).toBe(true);
      else expect(r.scope?.endsWith(':write') || r.scope === 'org:admin', r.id).toBe(true);
    }
    // Money: only refunds:write refunds, and nothing else needs it.
    expect(ROUTES.filter((r) => r.scope === 'refunds:write').map((r) => r.id)).toEqual(['create-refund']);
  });
});

describe('scopes', () => {
  it('legacy read covers every :read scope and nothing else', () => {
    for (const s of SCOPES) expect(hasScope(['read'], s)).toBe(s.endsWith(':read'));
    expect(effectiveScopes(['read'])).toEqual(READ_SCOPES);
  });

  it('a :write scope covers its own :read only', () => {
    expect(hasScope(['events:write'], 'events:read')).toBe(true);
    expect(hasScope(['events:write'], 'orders:read')).toBe(false);
    expect(hasScope(['events:read'], 'events:write')).toBe(false);
    expect(hasScope([], 'events:read')).toBe(false);
  });

  it('effective scopes keep vocabulary order', () => {
    expect(effectiveScopes(['tickets:read', 'events:write'])).toEqual(['events:read', 'events:write', 'tickets:read']);
  });
});

describe('paging', () => {
  const q = (s: string) => new URLSearchParams(s);

  it('defaults to page 1 of 50', () => {
    expect(parsePage(q(''))).toEqual({ page: 1, perPage: 50, from: 0, to: 49 });
    expect(parsePage(q('page=3&per_page=20'))).toEqual({ page: 3, perPage: 20, from: 40, to: 59 });
  });

  it('refuses out-of-range and non-integer values', () => {
    for (const bad of ['page=0', 'per_page=0', 'per_page=201', 'page=1.5', 'page=-1', 'per_page=abc', 'page=', 'page=99999999']) {
      expect(() => parsePage(q(bad)), bad).toThrow(PagingError);
    }
  });

  it('builds the envelope', () => {
    const p = parsePage(q('per_page=2'));
    expect(pageEnvelope(['a', 'b'], p, 5)).toEqual({ data: ['a', 'b'], meta: { page: 1, per_page: 2, total: 5, total_pages: 3 } });
    expect(pageEnvelope([], p, 0).meta.total_pages).toBe(1);
    expect(pageEnvelope(['a'], p, null).meta.total).toBe(1);
  });
});
