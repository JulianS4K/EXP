import { describe, it, expect, vi } from 'vitest';
import { StubHubClient } from '.';
import { STUBHUB_ENDPOINTS } from '.';
import { buildCreateListingRequest, buildRequestedEvent, buildRequestedEventListingRequest } from '.';
import {
  STUBHUB_WRITE_ROADMAP,
  StubHubWriter,
  WriteNotAuthorizedError,
  type PlannedWrite,
  type WriteAuthorization,
} from '.';

const REQ = buildCreateListingRequest(
  { id: 'row-1', channel: 'stubhub', requested_qty: 2, unit_price: 40 },
  { ticketType: 'ETicket', splitType: 'Any', section: 'GA', currency: 'USD' },
);

const AUTH: WriteAuthorization = {
  approvedBy: 'operator@example.test',
  approvedAt: '2026-10-01T00:00:00Z',
  reference: 'https://example.test/signoff',
  endpoints: ['createSellerListing'],
};

const json = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status });

function liveWriter(fetchImpl: (url: string, init?: RequestInit) => Promise<Response>, auth = AUTH, extra = {}) {
  return new StubHubWriter({
    mode: { mode: 'live', authorization: auth },
    baseUrl: 'https://api.example.test',
    accessToken: () => 'tok',
    fetch: fetchImpl,
    sleep: async () => {},
    ...extra,
  });
}

describe('write roadmap', () => {
  it('starts with listing creation, then sales, and only lists write endpoints once', () => {
    expect(STUBHUB_WRITE_ROADMAP[0].endpoints).toEqual([
      'createSellerListingForRequestedEvent',
      'createSellerEvent',
      'createSellerListing',
    ]);
    expect(STUBHUB_WRITE_ROADMAP[0].scopes).toContain('write:requestedevents');
    expect(STUBHUB_WRITE_ROADMAP[2].phase).toMatch(/Sale fulfilment/);
    const all = STUBHUB_WRITE_ROADMAP.flatMap((p) => p.endpoints);
    expect(new Set(all).size).toBe(all.length);
    for (const e of all) expect(STUBHUB_ENDPOINTS[e].access).toBe('write');
  });
});

describe('StubHubWriter dry-run (default)', () => {
  it('plans every write without touching the network', async () => {
    const plans: PlannedWrite[] = [];
    const w = new StubHubWriter({ onPlan: (p) => plans.push(p) });
    expect(w.isLive).toBe(false);

    const results = [
      await w.createSellerListing(123, REQ),
      await w.updateListing('row-1', { number_of_tickets: 1 }),
      await w.delistListing('row-1'),
      await w.confirmSale(9),
      await w.reportMobileTransfer(9, 'AXS', 'AXS-1'),
      await w.attachETickets(9, [5]),
      await w.deliverETicketUrls(9, ['https://exos.example.test/claim/0b6f1c2e-1111-4a2b-9c3d-000000000001'], 1),
      await w.rejectSale(9),
    ];
    expect(results.every((r) => r.dryRun)).toBe(true);
    expect(plans.map((p) => `${p.method} ${p.url}`)).toEqual([
      'POST /v2/events/123/sellerlistings',
      'PATCH /v2/externalsellerlistings/row-1',
      'DELETE /v2/externalsellerlistings/row-1',
      'PATCH /v2/sales/9',
      'PATCH /v2/sales/9',
      'PATCH /v2/sales/9',
      'PATCH /v2/sales/9',
      'DELETE /v2/sales/9',
    ]);
    expect(plans[0].body).toBe(REQ);
    expect(plans[4].body).toEqual({ confirmed: true, mobile_provider: 'AXS', transfer_confirmation_number: 'AXS-1' });
    expect(plans[6].body).toEqual({
      confirmed: true,
      eticket_urls: [{ url: 'https://exos.example.test/claim/0b6f1c2e-1111-4a2b-9c3d-000000000001' }],
    });
    expect('body' in plans[7]).toBe(false);
  });

  it('ignores credentials and a fetch passed in dry-run mode', async () => {
    const fetchImpl = vi.fn();
    const w = new StubHubWriter({ baseUrl: 'https://api.example.test', accessToken: () => 't', fetch: fetchImpl });
    await w.createSellerListing(1, REQ);
    expect(fetchImpl).not.toHaveBeenCalled();
  });
});

describe('StubHubWriter live mode gate', () => {
  it.each([
    [{ ...AUTH, approvedBy: ' ' }, /approvedBy/],
    [{ ...AUTH, reference: '' }, /reference/],
    [{ ...AUTH, approvedAt: 'yesterday' }, /approvedAt/],
    [{ ...AUTH, endpoints: [] }, /no endpoints/],
    [{ ...AUTH, endpoints: ['getSale'] as unknown as WriteAuthorization['endpoints'] }, /not a write endpoint/],
  ])('refuses an incomplete authorization %#', (auth, msg) => {
    expect(() => liveWriter(vi.fn(), auth)).toThrow(WriteNotAuthorizedError);
    expect(() => liveWriter(vi.fn(), auth)).toThrow(msg);
  });

  it('needs a host and token', () => {
    expect(() => new StubHubWriter({ mode: { mode: 'live', authorization: AUTH } })).toThrow(/environment/);
  });

  it('refuses endpoints outside the authorized scope before calling fetch', async () => {
    const fetchImpl = vi.fn();
    const w = liveWriter(fetchImpl);
    await expect(w.rejectSale(1)).rejects.toBeInstanceOf(WriteNotAuthorizedError);
    await expect(w.confirmSale(1)).rejects.toThrow(/authorization scope/);
    expect(fetchImpl).not.toHaveBeenCalled();
  });

  it('sends an authorized create', async () => {
    const fetchImpl = vi.fn(async () => json({ id: 77, created_at: '', number_of_tickets: 2 }, 201));
    const w = liveWriter(fetchImpl);
    const res = await w.createSellerListing(123, REQ);
    expect(res).toMatchObject({ dryRun: false, response: { id: 77 } });
    const [url, init] = fetchImpl.mock.calls[0] as unknown as [string, RequestInit];
    expect(url).toBe('https://api.example.test/v2/events/123/sellerlistings');
    expect(init.method).toBe('POST');
    expect(JSON.parse(init.body as string)).toEqual(REQ);
  });

  it('retries a throttled write but never a 5xx (a create may have landed)', async () => {
    const throttled = vi
      .fn()
      .mockResolvedValueOnce(json({}, 429))
      .mockResolvedValueOnce(json({ id: 1, created_at: '', number_of_tickets: 2 }, 201));
    await liveWriter(throttled).createSellerListing(1, REQ);
    expect(throttled).toHaveBeenCalledTimes(2);

    const failing = vi.fn(async () => json({ message: 'boom' }, 503));
    await expect(liveWriter(failing).createSellerListing(1, REQ)).rejects.toMatchObject({ status: 503 });
    expect(failing).toHaveBeenCalledTimes(1);
  });

  it('does not throw on a non-JSON success body (the write already happened)', async () => {
    const w = liveWriter(async () => new Response('Created', { status: 201 }));
    expect(await w.createSellerListing(1, REQ)).toMatchObject({ dryRun: false, response: 'Created' });
  });

  it('handles 204 No Content', async () => {
    const auth = { ...AUTH, endpoints: ['rejectSale'] as const };
    const w = liveWriter(async () => new Response(null, { status: 204 }), auth);
    expect(await w.rejectSale(5)).toMatchObject({ dryRun: false, response: null });
  });
});

describe('createOrAdoptListing', () => {
  const reader = (fetchImpl: (url: string) => Promise<Response>) =>
    new StubHubClient({ baseUrl: 'https://api.example.test', accessToken: () => 't', fetch: fetchImpl, sleep: async () => {} });

  it('adopts an existing listing with the same external_id instead of creating', async () => {
    const readFetch = vi.fn(async (_url: string) => json({ id: 55, external_id: 'row-1', created_at: '', number_of_tickets: 2 }));
    const writeFetch = vi.fn();
    const w = liveWriter(writeFetch, AUTH, { reader: reader(readFetch) });
    expect(await w.createOrAdoptListing(1, REQ)).toMatchObject({ adopted: true, listing: { id: 55 } });
    expect(readFetch.mock.calls[0][0]).toBe('https://api.example.test/v2/externalsellerlistings/row-1');
    expect(writeFetch).not.toHaveBeenCalled();
  });

  it('creates when the lookup 404s', async () => {
    const w = new StubHubWriter({ reader: reader(async () => new Response('', { status: 404 })) });
    expect(await w.createOrAdoptListing(1, REQ)).toMatchObject({ dryRun: true, planned: { method: 'POST' } });
  });

  it('surfaces other lookup failures rather than risking a duplicate', async () => {
    const w = new StubHubWriter({ reader: reader(async () => new Response('', { status: 403 })) });
    await expect(w.createOrAdoptListing(1, REQ)).rejects.toMatchObject({ status: 403 });
  });
});

describe('requested-event listings', () => {
  const REQ2 = buildRequestedEventListingRequest(
    { id: 'row-2', channel: 'stubhub', requested_qty: 2, unit_price: 40 },
    { ticketType: 'ETicket', splitType: 'Any', section: 'GA', currency: 'USD' },
    { name: 'Exos Show', startsAt: '2026-11-01T02:00:00Z', venueName: 'The Hall', venueCity: 'Austin', countryCode: 'US' },
  );

  it('plans POST /v2/sellerlistings with the event and venue as text', async () => {
    const res = await new StubHubWriter().createListingForRequestedEvent(REQ2);
    expect(res).toMatchObject({ dryRun: true, planned: { method: 'POST', url: '/v2/sellerlistings' } });
  });

  it('adopts an existing listing with the same external_id', async () => {
    const reader = new StubHubClient({
      environment: 'sandbox',
      accessToken: () => 't',
      fetch: async () => json({ id: 9, external_id: 'row-2', created_at: '', number_of_tickets: 2 }),
    });
    expect(await new StubHubWriter({ reader }).createOrAdoptRequestedEventListing(REQ2)).toMatchObject({
      adopted: true,
      listing: { id: 9 },
    });
  });

  it('live mode accepts an environment instead of a baseUrl', async () => {
    const fetchImpl = vi.fn(async () => json({ id: 1, created_at: '', number_of_tickets: 2 }, 201));
    const w = new StubHubWriter({
      mode: { mode: 'live', authorization: { ...AUTH, endpoints: ['createSellerListingForRequestedEvent'] } },
      environment: 'sandbox',
      accessToken: () => 't',
      fetch: fetchImpl,
    });
    await w.createListingForRequestedEvent(REQ2);
    expect((fetchImpl.mock.calls[0] as unknown as [string])[0]).toBe('https://sandbox.api.stubhub.net/v2/sellerlistings');
  });
});

describe('requestEvent', () => {
  it('plans PUT /v2/sellerevents with the requested-event body', async () => {
    const body = buildRequestedEvent({ name: 'Show', startsAt: '2026-11-01T00:00:00Z', venueName: 'Hall', venueCity: 'Austin' });
    expect(await new StubHubWriter().requestEvent(body)).toEqual({
      dryRun: true,
      planned: { endpoint: 'createSellerEvent', method: 'PUT', url: '/v2/sellerevents', body },
    });
  });
});
