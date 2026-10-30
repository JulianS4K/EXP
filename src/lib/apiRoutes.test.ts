import { describe, expect, it } from 'vitest';
import { apiPath, isPartnerPath, matchRoute, methodsAt, ROUTES } from '../../supabase/functions/_shared/api/routes.ts';
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
  });

  it('refuses unknown paths, other methods and malformed escapes', () => {
    expect(matchRoute('GET', '/events/abc/secrets')).toBeNull();
    expect(matchRoute('POST', '/events')).toBeNull();
    expect(matchRoute('PATCH', '/public/orders')).toBeNull();
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
      expect(r.path).toMatch(/^(\/([a-z_-]+|:[a-z]+))+$/);
      if (r.scope !== null) expect(SCOPES).toContain(r.scope);
      expect(matchRoute(r.method, r.path.replace(/:[a-z]+/g, 'x'))?.route.id).toBe(r.id);
    }
    // Credential routes without a scope: who am I, the role list, and the
    // token's own memberships / revocation. Every other api_key route is scoped.
    expect(ROUTES.filter((r) => r.auth === 'api_key' && r.scope === null).map((r) => r.id))
      .toEqual(['me', 'list-team-roles', 'list-my-memberships', 'revoke-current-token']);
    // Every write route needs a :write scope or org:admin.
    for (const r of ROUTES.filter((x) => x.auth === 'api_key' && x.method !== 'GET' && x.scope !== null)) {
      expect(r.scope === 'org:admin' || r.scope!.endsWith(':write'), r.id).toBe(true);
    }
    // The partner contract lives under /public and only there.
    for (const r of ROUTES) expect(isPartnerPath(r.path), r.id).toBe(r.auth === 'partner_key');
  });

  it('answers the partner contract and its 405s', () => {
    expect(matchRoute('POST', '/public/confirms/e1/ticket_reservations/rsv_x/complete')?.route.id).toBe('public-complete-reservation');
    expect(matchRoute('PUT', '/public/confirms/e1/ticket_reservations/rsv_x')?.params).toEqual({ id: 'e1', token: 'rsv_x' });
    expect(matchRoute('POST', '/events/e1/organizer-reservations/build')?.route.id).toBe('build-organizer-reservation');
    expect(methodsAt('/public/confirms/e1/ticket_reservations/rsv_x')).toEqual(['GET', 'PUT', 'DELETE']);
    expect(methodsAt('/nope')).toEqual([]);
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
