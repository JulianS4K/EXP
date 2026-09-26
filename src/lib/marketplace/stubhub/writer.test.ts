import { describe, it, expect, vi } from 'vitest';
import { StubHubClient } from './client';
import { STUBHUB_ENDPOINTS } from './endpoints';
import { buildCreateListingRequest } from './listing';
import {
  STUBHUB_WRITE_ROADMAP,
  StubHubWriter,
  WriteNotAuthorizedError,
  type PlannedWrite,
  type WriteAuthorization,
} from './writer';

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
    expect(STUBHUB_WRITE_ROADMAP[0].endpoints).toEqual(['createSellerListing']);
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
      'POST /events/123/sellerlistings',
      'PATCH /externalsellerlistings/row-1',
      'DELETE /externalsellerlistings/row-1',
      'PATCH /sales/9',
      'PATCH /sales/9',
      'PATCH /sales/9',
      'PATCH /sales/9',
      'DELETE /sales/9',
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
    expect(() => new StubHubWriter({ mode: { mode: 'live', authorization: AUTH } })).toThrow(/baseUrl/);
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
    expect(url).toBe('https://api.example.test/events/123/sellerlistings');
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
    expect(readFetch.mock.calls[0][0]).toBe('https://api.example.test/externalsellerlistings/row-1');
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
