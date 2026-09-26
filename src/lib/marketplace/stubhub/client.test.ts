import { readdirSync, readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { describe, it, expect, vi } from 'vitest';
import {
  STUBHUB_ENVIRONMENTS,
  StubHubClient,
  StubHubError,
  UpstreamWriteForbiddenError,
  basicAuthHeader,
  clientCredentialsToken,
  refreshTokenSource,
  toQueryString,
} from './client';
import { DEFAULT_USER_AGENT, resolveHost } from './transport';
import { STUBHUB_ENDPOINTS, buildPath } from './endpoints';
import type { Page, Sale } from './types';

interface Call {
  url: string;
  init: RequestInit;
}

function fakeFetch(responses: Array<Response | (() => Response)>) {
  const calls: Call[] = [];
  const fn = vi.fn(async (url: string, init: RequestInit = {}) => {
    calls.push({ url, init });
    const next = responses.shift();
    if (!next) throw new Error(`unexpected fetch ${url}`);
    return typeof next === 'function' ? next() : next;
  });
  return { fn, calls };
}

const json = (body: unknown, status = 200, headers: Record<string, string> = {}) =>
  new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/hal+json', ...headers } });

function client(responses: Array<Response | (() => Response)>, extra: { sleep?: (ms: number) => Promise<void> } = {}) {
  const f = fakeFetch(responses);
  const c = new StubHubClient({
    baseUrl: 'https://api.example.test/',
    userAgent: 'exos-test/1',
    accessToken: () => 'tok',
    fetch: f.fn,
    sleep: extra.sleep ?? (async () => {}),
  });
  return { c, ...f };
}

describe('endpoint registry', () => {
  it('tags every mutating verb as write unless it is a documented lookup', () => {
    const lookups = new Set([
      'getEventsByIds',
      'mapEvent',
      'previewSellerListing',
      'previewSellerListingForRequestedEvent',
      'previewSellerListingUpdate',
      'getRequestedEventListingConstraints',
      'listListingPaymentMethods',
    ]);
    for (const [name, ep] of Object.entries(STUBHUB_ENDPOINTS)) {
      if (ep.method === 'GET') expect(ep.access, name).toBe('read');
      else if (lookups.has(name)) expect(ep.access, name).toBe('lookup');
      else expect(ep.access, name).toBe('write');
    }
  });

  it('matches the endpoints in the vendor reference (PDF text + OpenAPI) exactly', () => {
    const docs = resolve(__dirname, '../../../../docs/marketplace/stubhub');
    const documented = new Set<string>();
    for (const f of readdirSync(resolve(docs, 'text'))) {
      for (const m of readFileSync(resolve(docs, 'text', f), 'utf8').matchAll(/^(GET|POST|PUT|PATCH|DELETE) (\/\S+)$/gm)) {
        documented.add(`${m[1]} ${m[2].replace(/\{\w+\}/g, '{}')}`);
      }
    }
    for (const f of readdirSync(resolve(docs, 'openapi')).filter((x) => x.endsWith('.json'))) {
      const spec = JSON.parse(readFileSync(resolve(docs, 'openapi', f), 'utf8')) as { paths: Record<string, object> };
      for (const [path, ops] of Object.entries(spec.paths)) {
        for (const method of Object.keys(ops)) {
          if (/^(get|post|put|patch|delete)$/.test(method)) documented.add(`${method.toUpperCase()} ${path.replace(/\{\w+\}/g, '{}')}`);
        }
      }
    }
    // Param names differ in places ({ETicketId} vs {eticketId}); only the shape matters.
    const ours = Object.values(STUBHUB_ENDPOINTS).map((e) => `${e.method} ${e.path.replace(/\{\w+\}/g, '{}')}`);
    expect(new Set(ours).size).toBe(ours.length);
    expect([...new Set(ours)].sort()).toEqual([...documented].sort());
  });
});

describe('buildPath / toQueryString', () => {
  it('encodes path params and rejects missing ones', () => {
    expect(buildPath('/externalsellerlistings/{externalId}', { externalId: 'exos/1 2' })).toBe(
      '/externalsellerlistings/exos%2F1%202',
    );
    expect(() => buildPath('/sales/{saleId}', {})).toThrow(/saleId/);
  });

  it('drops empty values and serializes dates as ISO', () => {
    const qs = toQueryString({
      page: 2,
      q: '',
      sort: undefined,
      updated_since: new Date(Date.UTC(2026, 8, 1)),
      exclude_parking_passes: true,
    });
    expect(qs).toBe('?page=2&updated_since=2026-09-01T00%3A00%3A00.000Z&exclude_parking_passes=true');
    expect(toQueryString({})).toBe('');
  });
});

describe('StubHubClient', () => {
  it('sends a bearer GET to the right URL', async () => {
    const { c, calls } = client([json({ id: 7, name: 'Show', start_date: '2026-10-01T00:00:00Z' })]);
    const ev = await c.getEvent(7);
    expect(ev.id).toBe(7);
    expect(calls[0].url).toBe('https://api.example.test/catalog/events/7');
    expect(calls[0].init.method).toBe('GET');
    expect((calls[0].init.headers as Record<string, string>).Authorization).toBe('Bearer tok');
    expect((calls[0].init.headers as Record<string, string>)['User-Agent']).toBe('exos-test/1');
    expect(calls[0].init.body).toBeUndefined();
  });

  it('searches events by dateLocal and tolerates a non-JSON category response', async () => {
    const { c, calls } = client([json({ total_items: 0, page: 1, page_size: 0 }), new Response('not json')]);
    await c.searchEvents({ q: 'show', dateLocal: '2026-11-01' });
    expect(calls[0].url).toBe('https://api.example.test/catalog/events/search?q=show&dateLocal=2026-11-01');
    expect(await c.searchCategories('rock')).toBe('not json');
  });

  it('serves catalog at the host root and everything else under /v2', async () => {
    const { c, calls } = client([json({}), json({}), json({})]);
    await c.getVenue(1);
    await c.getSale(2);
    await c.getUser();
    expect(calls.map((x) => x.url)).toEqual([
      'https://api.example.test/catalog/venues/1',
      'https://api.example.test/v2/sales/2',
      'https://api.example.test/v2/user',
    ]);
  });

  it('sends lookup bodies as JSON (batch get uses event_ids)', async () => {
    const { c, calls } = client([json({ total_items: 0, page: 1, page_size: 0 })]);
    await c.getEventsByIds([1, 2]);
    expect(calls[0].init.method).toBe('PUT');
    expect(JSON.parse(calls[0].init.body as string)).toEqual({ event_ids: [1, 2] });
  });

  it('serializes Date fields in listing previews', async () => {
    const { c, calls } = client([json({ id: 0, created_at: '', number_of_tickets: 2 })]);
    await c.previewSellerListing(9, {
      number_of_tickets: 2,
      ticket_price: { amount: 50, currency_code: 'USD' },
      in_hand_at: new Date(Date.UTC(2026, 9, 1)),
    });
    expect(calls[0].url).toBe('https://api.example.test/v2/events/9/sellerlistingpreview');
    expect(JSON.parse(calls[0].init.body as string)).toMatchObject({ in_hand_at: '2026-10-01T00:00:00.000Z' });
  });

  it('exposes no write methods', () => {
    const methods = Object.getOwnPropertyNames(StubHubClient.prototype);
    for (const [name, ep] of Object.entries(STUBHUB_ENDPOINTS)) {
      if (ep.access === 'write') expect(methods, name).not.toContain(name);
    }
  });

  it('refuses a write endpoint before calling fetch', async () => {
    const { c, fn } = client([]);
    // Reach the private transport the way a careless future method would.
    const send = (c as unknown as { send: (n: string) => Promise<Response> }).send.bind(c);
    await expect(send('createSellerListing')).rejects.toBeInstanceOf(UpstreamWriteForbiddenError);
    await expect(send('rejectSale')).rejects.toBeInstanceOf(UpstreamWriteForbiddenError);
    expect(fn).not.toHaveBeenCalled();
  });

  it('retries 429 honoring Retry-After, then succeeds', async () => {
    const sleeps: number[] = [];
    const { c, fn } = client(
      [json({}, 429, { 'Retry-After': '3' }), json({ id: 1, created_at: '', number_of_tickets: 1, status: 'x' })],
      { sleep: async (ms) => void sleeps.push(ms) },
    );
    const sale = await c.getSale(1);
    expect(sale.id).toBe(1);
    expect(fn).toHaveBeenCalledTimes(2);
    expect(sleeps).toEqual([3000]);
  });

  it('gives up after maxRetries and surfaces the error body', async () => {
    const { c, fn } = client([
      json({}, 503),
      json({}, 503),
      json({ code: 'unavailable', message: 'try later' }, 503),
    ]);
    const err = await c.getSale(1).catch((e) => e);
    expect(err).toBeInstanceOf(StubHubError);
    expect(err.status).toBe(503);
    expect(err.body).toEqual({ code: 'unavailable', message: 'try later' });
    expect(err.message).toContain('try later');
    expect(fn).toHaveBeenCalledTimes(3);
  });

  it('does not retry a 404', async () => {
    const { c, fn } = client([new Response('nope', { status: 404 })]);
    const err = await c.getVenue(1).catch((e) => e);
    expect(err).toBeInstanceOf(StubHubError);
    expect(err.body).toBe('nope');
    expect(fn).toHaveBeenCalledTimes(1);
  });

  it('paginates until there is no next link', async () => {
    const page = (ids: number[], next: boolean): Page<Sale> => ({
      total_items: 3,
      page: null,
      page_size: 2,
      _links: next ? { next: { href: '/sales?page=2' } } : {},
      _embedded: { items: ids.map((id) => ({ id, created_at: '', number_of_tickets: 1, status: 'x' })) },
    });
    const { c, calls } = client([json(page([1, 2], true)), json(page([3], false))]);
    const ids: number[] = [];
    for await (const s of c.paginate((p) => c.listSales({ page: p, page_size: 2 }))) ids.push(s.id);
    expect(ids).toEqual([1, 2, 3]);
    expect(calls.map((x) => x.url)).toEqual([
      'https://api.example.test/v2/sales?page=1&page_size=2',
      'https://api.example.test/v2/sales?page=2&page_size=2',
    ]);
  });
});

describe('hosts', () => {
  it('resolves documented environments and rejects a /v2 base', () => {
    expect(resolveHost({ environment: 'production' })).toBe('https://api.stubhub.net');
    expect(resolveHost({ environment: 'sandbox' })).toBe('https://sandbox.api.stubhub.net');
    expect(resolveHost({ baseUrl: 'https://x.test/' })).toBe('https://x.test');
    expect(() => resolveHost({})).toThrow(/environment or baseUrl/);
    expect(() => resolveHost({ baseUrl: 'https://api.stubhub.net/v2' })).toThrow(/host only/);
    expect(STUBHUB_ENVIRONMENTS.sandbox.tokenUrl).toBe('https://sandbox.account.stubhub.com/oauth2/token');
  });

  it('sends a default User-Agent (StubHub rejects requests without one)', async () => {
    const fetchImpl = vi.fn(async () => json({ id: 1 }));
    await new StubHubClient({ environment: 'sandbox', accessToken: () => 't', fetch: fetchImpl }).getUser();
    const init = (fetchImpl.mock.calls[0] as unknown as [string, RequestInit])[1];
    expect((init.headers as Record<string, string>)['User-Agent']).toBe(DEFAULT_USER_AGENT);
  });
});

describe('basicAuthHeader', () => {
  it('URL-encodes id and secret before base64 (per the auth guide)', () => {
    expect(basicAuthHeader('id', 'se:cr et')).toBe(`Basic ${btoa('id:se%3Acr%20et')}`);
  });
});

describe('refreshTokenSource', () => {
  it('persists each rotated single-use refresh token before handing out the access token', async () => {
    let stored = 'r1';
    const saves: string[] = [];
    let t = 0;
    const { fn, calls } = fakeFetch([
      () => json({ access_token: 'a1', expires_in: 3600, refresh_token: 'r2' }),
      () => json({ access_token: 'a2', expires_in: 3600, refresh_token: 'r3' }),
    ]);
    const token = refreshTokenSource({
      tokenUrl: STUBHUB_ENVIRONMENTS.sandbox.tokenUrl,
      clientId: 'id',
      clientSecret: 'secret',
      scopes: ['read:sales', 'write:sales'],
      loadRefreshToken: () => stored,
      saveRefreshToken: (r) => {
        stored = r;
        saves.push(r);
      },
      fetch: fn,
      now: () => t,
    });
    expect(await token()).toBe('a1');
    expect(calls[0].init.body).toBe('grant_type=refresh_token&refresh_token=r1&scope=read%3Asales+write%3Asales');
    t += 3600_000;
    expect(await token()).toBe('a2');
    expect(calls[1].init.body).toContain('refresh_token=r2');
    expect(saves).toEqual(['r2', 'r3']);
  });

  it('refuses a response without a new refresh token', async () => {
    const { fn } = fakeFetch([() => json({ access_token: 'a1', expires_in: 3600 })]);
    const token = refreshTokenSource({
      tokenUrl: 'https://auth.example.test/token',
      clientId: 'id',
      clientSecret: 's',
      loadRefreshToken: () => 'r1',
      saveRefreshToken: () => {},
      fetch: fn,
    });
    await expect(token()).rejects.toThrow(/single-use/);
  });
});

describe('clientCredentialsToken', () => {
  it('fetches once, caches until 60s before expiry, then refreshes', async () => {
    let t = 1_000_000;
    const { fn, calls } = fakeFetch([
      () => json({ access_token: 'a', expires_in: 120 }),
      () => json({ access_token: 'b', expires_in: 120 }),
    ]);
    const token = clientCredentialsToken({
      tokenUrl: 'https://auth.example.test/token',
      clientId: 'id',
      clientSecret: 'secret',
      scopes: ['read:events'],
      fetch: fn,
      now: () => t,
    });
    const [x, y] = await Promise.all([token(), token()]);
    expect([x, y]).toEqual(['a', 'a']);
    expect(fn).toHaveBeenCalledTimes(1);
    expect((calls[0].init.headers as Record<string, string>).Authorization).toBe(`Basic ${btoa('id:secret')}`);
    expect(calls[0].init.body).toBe('grant_type=client_credentials&scope=read%3Aevents');

    t += 59_000;
    expect(await token()).toBe('a');
    t += 2_000; // past expires_in - 60s
    expect(await token()).toBe('b');
    expect(fn).toHaveBeenCalledTimes(2);
  });

  it('throws on a failed token request', async () => {
    const { fn } = fakeFetch([new Response('bad client', { status: 401 })]);
    const token = clientCredentialsToken({ tokenUrl: 'https://auth.example.test/token', clientId: 'x', clientSecret: 'y', fetch: fn });
    await expect(token()).rejects.toMatchObject({ status: 401 });
  });
});
