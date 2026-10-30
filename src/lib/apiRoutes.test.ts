import { describe, expect, it } from 'vitest';
import { allowedMethods, apiPath, isSharedKeyPath, matchRoute, ROUTES } from '../../supabase/functions/_shared/api/routes.ts';
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
    expect(matchRoute('POST', '/events/abc/sales-counts/import')?.route.id).toBe('import-sales-counts');
    expect(matchRoute('PUT', '/sales-counts/x')?.route.id).toBe('update-sales-count');
    expect(matchRoute('GET', '/eventbrite-events/123')?.params).toEqual({ id: '123' });
    expect(matchRoute('POST', '/events')?.route.id).toBe('create-event');
    expect(matchRoute('PATCH', '/events/e1/ticket-types/t1')?.params).toEqual({ id: 'e1', tier: 't1' });
    expect(matchRoute('POST', '/orders/cs_1/refunds')?.route.id).toBe('create-refund');
    expect(matchRoute('GET', '/orders/cs_1/refunds')).toBeNull();
  });

  it('refuses unknown paths, other methods and malformed escapes', () => {
    expect(matchRoute('GET', '/events/abc/secrets')).toBeNull();
    expect(matchRoute('PUT', '/sales-counts')).toBeNull();
    expect(matchRoute('DELETE', '/events/x/sales-counts')).toBeNull();
    expect(matchRoute('DELETE', '/artists/x')).toBeNull();
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
    // Of the API-key routes only GET /me is reachable without a scope; the
    // shared-key routes (the public listing feed) take no scope at all.
    expect(ROUTES.filter((r) => r.auth === 'api_key' && r.scope === null).map((r) => r.id)).toEqual(['me']);
    expect(ROUTES.filter((r) => r.auth === 'shared_key').every((r) => r.scope === null && r.method === 'GET')).toBe(true);
    // Every write needs a write scope; every read a read scope (or org:admin).
    for (const r of ROUTES.filter((x) => x.auth === 'api_key' && x.scope)) {
      if (r.method === 'GET') expect(r.scope!.endsWith(':read') || r.scope === 'org:admin', r.id).toBe(true);
      else expect(r.scope!.endsWith(':write') || r.scope === 'org:admin', r.id).toBe(true);
    }
    // Money: only refunds:write refunds, and nothing else needs it.
    expect(ROUTES.filter((r) => r.scope === 'refunds:write').map((r) => r.id)).toEqual(['create-refund']);
    // Aliases are unique across the table and point at their own route only.
    const aliasKeys = ROUTES.flatMap((r) => (r.aliases ?? []).map((a) => `${r.method} ${a}`));
    expect(new Set(aliasKeys).size).toBe(aliasKeys.length);
    for (const r of ROUTES) {
      for (const a of r.aliases ?? []) {
        expect(a).toMatch(/^(\/([a-z][a-z0-9_-]*|:[a-z]+))+$/);
        expect(matchRoute(r.method, a.replace(/:[a-z]+/g, 'x'))?.route.id, a).toBe(r.id);
      }
    }
  });

  it('routes the artist, lineup, key and feed paths', () => {
    expect(matchRoute('POST', '/artists')?.route.id).toBe('create-artist');
    expect(matchRoute('PATCH', '/artists/a1')?.params).toEqual({ id: 'a1' });
    expect(matchRoute('POST', '/artists/a1/merge')?.route.id).toBe('merge-artist');
    expect(matchRoute('PUT', '/events/e1/lineup')?.route.id).toBe('set-lineup');
    expect(matchRoute('DELETE', '/listing-keys/k1')?.route.id).toBe('revoke-listing-key');
    expect(matchRoute('GET', apiPath('/functions/v1/exos-api/v1/public/events'))?.route.auth).toBe('shared_key');
    expect(matchRoute('GET', '/public/confirms/e1')?.route.id).toBe('public-get-confirm');
    expect(isSharedKeyPath('/public/events')).toBe(true);
    expect(isSharedKeyPath('/publicity')).toBe(false);
    expect(isSharedKeyPath('/events')).toBe(false);
  });

  it('routes the fan, tag and refund-request paths', () => {
    expect(matchRoute('GET', '/fans/lookup')?.route.id).toBe('lookup-fans');
    expect(matchRoute('GET', '/fans/f1')?.params).toEqual({ id: 'f1' });
    expect(matchRoute('POST', '/fans')?.route.id).toBe('create-fan');
    expect(matchRoute('PATCH', '/fans/f1')?.route.id).toBe('update-fan');
    expect(matchRoute('DELETE', '/fans/f1')?.route.id).toBe('discard-fan');
    expect(matchRoute('PUT', '/fans/f1')).toBeNull();
    expect(matchRoute('POST', '/tagged-items')?.route.scope).toBe('events:write');
    expect(matchRoute('GET', '/refund-requests')?.route.scope).toBe('orders:read');
    // Fan data is its own scope: orders:read doesn't reach it, fans:write covers fans:read.
    expect(hasScope(['orders:read'], 'fans:read')).toBe(false);
    expect(hasScope(['fans:write'], 'fans:read')).toBe(true);
    expect(hasScope(['read'], 'fans:read')).toBe(true);
    expect(hasScope(['read'], 'fans:write')).toBe(false);
  });
});

describe('booking routes', () => {
  it('matches the Opendate-style aliases', () => {
    expect(matchRoute('POST', '/holds/h1/convert_to_confirm')?.route.id).toBe('convert-hold');
    expect(matchRoute('POST', '/holds/h1/convert_to_event')?.params).toEqual({ id: 'h1' });
    expect(matchRoute('GET', '/venue_ownerships')?.route.id).toBe('list-venues');
    expect(matchRoute('DELETE', '/venue_ownerships/v1')?.route.id).toBe('delete-venue');
    expect(matchRoute('GET', '/confirms/e1/show_activities/a1')?.params).toEqual({ id: 'e1', aid: 'a1' });
    expect(matchRoute('PATCH', '/events/e1/show-activities/a1')?.route.id).toBe('update-show-activity');
    expect(matchRoute('GET', '/calendar_event_contacts/c1')?.route.id).toBe('get-contact');
    expect(matchRoute('PATCH', '/venues/v1/rooms/r1')?.params).toEqual({ vid: 'v1', id: 'r1' });
  });

  it('knows which methods a path answers (405 vs 404)', () => {
    expect(allowedMethods('/holds')).toEqual(['GET', 'POST']);
    expect(allowedMethods('/venues/v1')).toEqual(['GET', 'PATCH', 'DELETE']);
    expect(allowedMethods('/events')).toEqual(['GET', 'POST']);
    expect(allowedMethods('/nope')).toEqual([]);
    expect(matchRoute('PUT', '/holds/h1')).toBeNull();
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

describe('offers and finance routes', () => {
  it("answers Opendate's v3 and snake_case spellings", () => {
    expect(matchRoute('POST', '/v3_offers')?.route.id).toBe('create-offer');
    expect(matchRoute('POST', '/v3_offers/o1/send_offer')?.route.id).toBe('send-offer');
    expect(matchRoute('POST', '/v3_offers/o1/accept')?.params).toEqual({ id: 'o1' });
    expect(matchRoute('POST', '/v3_offer_templates/t1/apply_template')?.route.id).toBe('apply-offer-template');
    expect(matchRoute('PATCH', '/v3_budget_line_items/l1')?.route.id).toBe('update-budget-line');
    expect(matchRoute('GET', '/v3_offer_pools/p1')?.route.id).toBe('get-offer-pool');
    expect(matchRoute('POST', '/offer_imports')?.route.id).toBe('create-offer-import');
    expect(matchRoute('GET', '/confirms/e1/settlements/summary')?.route.id).toBe('get-settlement');
    expect(matchRoute('GET', '/confirms/e1/finance_items')?.route.id).toBe('list-finance-items');
    expect(matchRoute('PATCH', '/confirms/e1/finance_items/i1')?.params).toEqual({ eid: 'e1', id: 'i1' });
    expect(matchRoute('GET', '/general_ledger_codes')?.route.id).toBe('list-gl-codes');
  });

  it('keeps money behind the finance scopes and offers behind booking', () => {
    expect(matchRoute('GET', '/events/e1/settlement')?.route.scope).toBe('finance:read');
    expect(matchRoute('POST', '/events/e1/settlement/finalize')?.route.scope).toBe('finance:write');
    expect(matchRoute('GET', '/profit-and-loss')?.route.scope).toBe('finance:read');
    expect(matchRoute('POST', '/offers/o1/send')?.route.scope).toBe('booking:write');
    expect(allowedMethods('/events/e1/settlement')).toEqual(['GET', 'PATCH']);
    expect(allowedMethods('/offers/o1')).toEqual(['GET', 'PATCH', 'DELETE']);
  });
});
