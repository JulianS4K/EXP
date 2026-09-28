// A fetch that throws (DNS / TLS / reset) must not leak the request URL or a
// secret through the error: Deno's message includes the full URL, and
// Gametime (?source=) and Vivid v1 (apiToken=) put their keys in it.
import { describe, expect, it } from 'vitest';
import {
  MarketplaceNetworkError,
  guardedFetch,
  redactSecrets,
  safeErrorText,
  stripUrls,
} from '../../../supabase/functions/_shared/marketplace/netError.ts';
import { GametimeClient } from './gametime';
import { VividClient } from './vivid';
import { TevoClient } from './tevo';
import { GoTicketsClient } from './gotickets';
import { SeatGeekClient } from './seatgeek';
import { StubHubClient } from './stubhub';
import { goticketsWebhookToken, verifyGoTicketsWebhookToken } from './gotickets';

const SECRET = 'sEcReT-KeY_0123456789abcdef';

/** A fetch that throws the way Deno's does: the URL, secret and all, in the message. */
const leakyFetch = async (input: string): Promise<Response> => {
  throw new TypeError(`error sending request for url (${input}): client error (Connect): dns error; key=${SECRET}`);
};

async function thrown(p: Promise<unknown>): Promise<Error> {
  try {
    await p;
  } catch (e) {
    return e as Error;
  }
  throw new Error('expected a throw');
}

function assertClean(e: Error) {
  expect(e).toBeInstanceOf(MarketplaceNetworkError);
  const all = `${e.message}\n${e.stack ?? ''}\n${JSON.stringify(e)}\n${String((e as { cause?: unknown }).cause ?? '')}`;
  expect(all).not.toContain(SECRET);
  expect(all).not.toContain(encodeURIComponent(SECRET));
  expect(all).not.toMatch(/https?:\/\//);
  expect((e as { cause?: unknown }).cause).toBeUndefined();
}

describe('guardedFetch', () => {
  it('rethrows with the endpoint only', async () => {
    const e = await thrown(guardedFetch(leakyFetch, `https://x.test/v1/a?source=${SECRET}`, {}, 'x GET /v1/a', [SECRET]));
    assertClean(e);
    expect(e.message).toMatch(/^x GET \/v1\/a: network error/);
    expect((e as MarketplaceNetworkError).endpoint).toBe('x GET /v1/a');
  });

  it('passes a response through untouched (HTTP errors are not network errors)', async () => {
    const res = await guardedFetch(async () => new Response('nope', { status: 503 }), 'https://x.test', {}, 'x', []);
    expect(res.status).toBe(503);
  });

  it('redacts raw and URL-encoded secrets, and strips URLs', () => {
    const s = 'a/b+c=d==';
    expect(redactSecrets(`t=${encodeURIComponent(s)} and ${s}`, [s])).toBe('t=[redacted] and [redacted]');
    expect(stripUrls('failed (https://h.test/p?source=k) ok')).toBe('failed ([url]) ok');
    expect(safeErrorText(new Error(`boom ${SECRET}`), [SECRET])).toBe('Error: boom [redacted]');
  });
});

describe('each marketplace transport hides the URL and secrets on a network error', () => {
  const noSleep = async () => {};

  it('Gametime (?source= key)', async () => {
    const c = new GametimeClient({ apiKey: () => SECRET, fetch: leakyFetch, maxRetries: 0, sleep: noSleep });
    const e = await thrown(c.listPurchases({ completed: false }));
    assertClean(e);
    expect(e.message).toContain('gametime GET');
  });

  it('Vivid v1 (apiToken query parameter)', async () => {
    const c = new VividClient({ credentials: () => ({ apiToken: SECRET, integratorToken: `${SECRET}-int` }), fetch: leakyFetch, maxRetries: 0, sleep: noSleep, now: () => 0 });
    const e = await thrown(c.getOrders('UNCONFIRMED'));
    assertClean(e);
    expect(e.message).toContain('vivid GET');
  });

  it('Ticket Evolution', async () => {
    const c = new TevoClient({ credentials: () => ({ token: SECRET, secret: `${SECRET}-sig` }), fetch: leakyFetch, maxRetries: 0, sleep: noSleep });
    assertClean(await thrown(c.listOrders()));
  });

  it('GoTickets', async () => {
    const c = new GoTicketsClient({ credentials: () => ({ accessId: SECRET, accessSecret: `${SECRET}-2` }), fetch: leakyFetch, maxRetries: 0, sleep: noSleep });
    assertClean(await thrown(c.getSale(1)));
  });

  it('SeatGeek', async () => {
    const c = new SeatGeekClient({ token: () => SECRET, fetch: leakyFetch, maxRetries: 0, sleep: noSleep });
    assertClean(await thrown(c.getOrder('1')));
  });

  it('StubHub', async () => {
    const c = new StubHubClient({ environment: 'sandbox', accessToken: () => SECRET, fetch: leakyFetch, maxRetries: 0, sleep: noSleep });
    assertClean(await thrown(c.getSale(1)));
  });
});

describe('GoTickets webhook token: header first, query as fallback', () => {
  const url = (q = '') => new URL(`https://fn.test/exos-marketplace-sales?channel=gotickets${q}`);
  it('reads X-Exos-Webhook-Token', () => {
    expect(goticketsWebhookToken(new Headers({ 'X-Exos-Webhook-Token': 'hdr-tok' }), url('&token=q-tok'))).toBe('hdr-tok');
  });
  it('reads Authorization: Bearer', () => {
    expect(goticketsWebhookToken(new Headers({ Authorization: 'Bearer b-tok' }), url())).toBe('b-tok');
  });
  it('falls back to ?token=', () => {
    expect(goticketsWebhookToken(new Headers(), url('&token=q-tok'))).toBe('q-tok');
    expect(goticketsWebhookToken(new Headers(), url())).toBeNull();
  });
  it('verifies whichever it got', () => {
    expect(verifyGoTicketsWebhookToken(goticketsWebhookToken(new Headers({ 'x-exos-webhook-token': 'abc123' }), url()), 'abc123')).toBe(true);
    expect(verifyGoTicketsWebhookToken(goticketsWebhookToken(new Headers(), url()), 'abc123')).toBe(false);
  });
});
