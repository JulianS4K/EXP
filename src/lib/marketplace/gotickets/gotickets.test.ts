import { describe, expect, it, vi } from 'vitest';
import {
  GOTICKETS_ENDPOINTS,
  GOTICKETS_WRITE_ROADMAP,
  GoTicketsClient,
  GoTicketsWriteRefusedError,
  GoTicketsWriter,
  goTicketsChannel,
  goTicketsTime,
  normalizeGoTicketsSale,
  parseGoTicketsWebhook,
  planGoTicketsListings,
  transferUrlFulfillment,
  verifyGoTicketsWebhookToken,
  type GoTicketsAllocation,
  type GoTicketsWriteAuthorization,
} from '.';
import { exosListingId, planDelist, syncListings } from '..';

const ALLOC = '0f8fad5b-d9cb-469f-a165-70867728950e';
const base: GoTicketsAllocation = {
  id: ALLOC,
  requested_qty: 6,
  unit_price: 45,
  internal_seats: '{[1,7)}',
  tier: { name: 'GA', price: 40 },
  event: {
    name: 'Late Night Jazz', starts_at: '2026-11-07T02:00:00Z', occurs_at_local: '2026-11-06T21:00:00-05:00',
    venue_name: 'Blue Room', venue_address: { city: 'Brooklyn' }, currency: 'USD', purchase_limits: { maxPerOrder: 4 },
  },
};
const AUTH: GoTicketsWriteAuthorization = { approvedBy: 'op', approvedAt: '2026-09-28T00:00:00Z', reference: 'test', endpoints: ['createListings'] };

describe('endpoints', () => {
  it('forbids what reaches listings Exos does not own', () => {
    const forbidden = Object.entries(GOTICKETS_ENDPOINTS).filter(([, e]) => e.access === 'forbidden').map(([k]) => k).sort();
    expect(forbidden).toEqual(['deleteListing', 'deleteListings', 'deleteListingsByEventId', 'postInventorySnapshot', 'updateListing', 'updateListings']);
    for (const p of GOTICKETS_WRITE_ROADMAP) for (const e of p.endpoints) expect(GOTICKETS_ENDPOINTS[e].access).toBe('write');
  });
});

describe('client', () => {
  it('sends the access headers, never the secret in a URL or error', async () => {
    const f = vi.fn(async (_url: string, init?: RequestInit) => {
      const h = init!.headers as Record<string, string>;
      expect(h['X-Api-Access-Id']).toBe('ID');
      expect(h['X-Api-Access-Secret']).toBe('SECRET');
      return new Response('{"message":"nope"}', { status: 400 });
    });
    const c = new GoTicketsClient({ credentials: () => ({ accessId: 'ID', accessSecret: 'SECRET' }), fetch: f, sleep: async () => {} });
    const err = await c.searchSales({ orderTimeFrom: new Date('2026-09-28T01:02:03Z') }).catch((e) => e as Error);
    expect(f.mock.calls[0][0]).toBe('https://sc.gotickets.com/rest/sales?orderTimeFrom=2026-09-28T01%3A02%3A03');
    expect(String(err)).toMatch(/GET \/rest\/sales -> 400: nope/);
    expect(String(err)).not.toContain('SECRET');
    expect(goTicketsTime(new Date('2026-01-02T03:04:05.678Z'))).toBe('2026-01-02T03:04:05');
  });
});

describe('listings', () => {
  it('plans the Exos blocks as GoTickets listings keyed by the Exos listing id', () => {
    const p = planGoTicketsListings({ ...base, seatgeekEventId: '6123456' });
    expect(p.listings.map((l) => [l.listing_id, l.seat_from, l.seat_thru])).toEqual([[exosListingId(ALLOC, 1), 1, 4], [exosListingId(ALLOC, 2), 5, 6]]);
    expect(p.listings[1].request).toMatchObject({ endpoint: 'createListings', method: 'POST', path: '/rest/listings' });
    expect(p.listings[1].request.body).toEqual({
      externalTicketId: exosListingId(ALLOC, 2), section: 'General Admission', row: 'GA', lowSeat: '5', highSeat: '6',
      notes: expect.stringContaining('Exos'), quantity: 2, instant: false, splitType: 'ANY', inHandDate: '2026-11-06',
      stockType: 'MOBILE_TICKETS', faceValue: 40, price: 45, eventName: 'Late Night Jazz', venueName: 'Blue Room',
      eventDateTime: '2026-11-07T02:00:00.000Z', seatgeekEventId: '6123456',
    });
    expect(() => planGoTicketsListings({ ...base, event: { ...base.event!, currency: 'EUR' } })).toThrow(/USD/);
  });

  it('syncs and delists by external id, 100 per request', () => {
    const live = planGoTicketsListings(base);
    expect(syncListings(live, null).action).toBe('create');
    const d = planDelist('gotickets', { listings: [...live.listings, { listing_id: 'broker-1' }] });
    expect(d?.requests).toEqual([{
      endpoint: 'deleteListingsByExternalIds', method: 'DELETE', path: '/rest/listings/external-id',
      body: [exosListingId(ALLOC, 1), exosListingId(ALLOC, 2)],
    }]);
  });
});

describe('writer', () => {
  it('plans in dry-run and refuses broker listings and GoTickets ids', async () => {
    const f = vi.fn();
    const w = new GoTicketsWriter({ fetch: f });
    const body = planGoTicketsListings(base).listings.map((l) => l.request.body);
    expect(await w.createListings(body)).toMatchObject({ dryRun: true, planned: { endpoint: 'createListings', url: '/rest/listings' } });
    expect(f).not.toHaveBeenCalled();
    expect(() => w.createListings([{ ...body[0], externalTicketId: 'TKT-1' }])).toThrow(GoTicketsWriteRefusedError);
    expect(() => w.updateListing({ ...body[0], id: 99 })).toThrow(/externalTicketId only/);
    expect(() => w.deleteListings(['broker-1'])).toThrow(/not an Exos listing id/);
    expect(() => w.createWebhook('SALE', 'http://insecure.test')).toThrow(/https/);
    const live = new GoTicketsWriter({ mode: { mode: 'live', authorization: AUTH }, credentials: () => ({ accessId: 'a', accessSecret: 'b' }), fetch: vi.fn() });
    await expect(live.confirmSale(1)).rejects.toThrow(/not in the authorization scope/);
  });
});

describe('sales', () => {
  const sale = {
    id: 777, sellerStatus: 'UNCONFIRMED', quantity: 2, externalTicketId: exosListingId(ALLOC, 2),
    customerEmailAddress: ' Fan@Example.com ', totalPayout: 88.5, createTime: '2026-10-01T12:00:00Z', event: { id: 42 },
  };

  it('normalizes a sale to its allocation and listing', () => {
    expect(normalizeGoTicketsSale(sale)).toMatchObject({
      channel: 'gotickets', externalOrderId: '777', externalEventId: '42', externalListingId: ALLOC,
      listingRef: exosListingId(ALLOC, 2), quantity: 2, status: 'pending', buyerEmail: 'fan@example.com',
      proceeds: { amount: 88.5, currency: 'USD' },
    });
    expect(normalizeGoTicketsSale({ ...sale, sellerStatus: 'PENDING_FULFILLMENT' }).status).toBe('confirmed');
    expect(normalizeGoTicketsSale({ ...sale, sellerStatus: 'COMPLETED' }).status).toBe('delivered');
    expect(normalizeGoTicketsSale({ ...sale, cancelReason: 'REJECTED' }).status).toBe('cancelled');
    expect(normalizeGoTicketsSale({ ...sale, sellerStatus: 'FRAUD_HOLD' }).status).toBe('unknown');
  });

  it('delivers by confirm, then fulfil with one claim link per ticket', () => {
    const urls = ['https://exos.test/claim/a', 'https://exos.test/claim/b'];
    const steps = goTicketsChannel().planFulfilByUrls!(normalizeGoTicketsSale(sale), urls);
    expect(steps.map((s) => [s.endpoint, s.path])).toEqual([['confirmSale', '/rest/sales/777/confirm'], ['fulfillSale', '/rest/sales/777/fulfill']]);
    expect(steps[1].body).toEqual({ method: 'SUBMIT_TRANSFER_URL', transferUrl: urls });
    expect(() => transferUrlFulfillment(['https://x.test/a b'], 1)).toThrow(/no spaces/);
  });

  it('webhooks: token in our URL, payload only names the sale to read back', () => {
    expect(verifyGoTicketsWebhookToken('t0k', 't0k')).toBe(true);
    expect(verifyGoTicketsWebhookToken('t0x', 't0k')).toBe(false);
    expect(verifyGoTicketsWebhookToken('', '')).toBe(false);
    expect(parseGoTicketsWebhook({ id: '777', type: 'SALE', quantity: 2 })).toMatchObject({ id: '777', type: 'SALE' });
    expect(() => parseGoTicketsWebhook({ id: 'x', type: 'SALE' })).toThrow();
  });
});
