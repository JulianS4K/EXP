import { describe, it, expect, vi } from 'vitest';
import {
  SEATGEEK_ENDPOINTS,
  SEATGEEK_WRITE_ROADMAP,
  SeatGeekClient,
  SeatGeekWriter,
  SeatGeekWriteRefusedError,
  SeatGeekPlatformClient,
  allocationIdFromSellerListingId,
  confirmOrderForm,
  customerEmail,
  exosSellerListingId,
  groupSizes,
  isExosSellerListingId,
  normalizeSeatGeekOrder,
  parseSeatGeekNotification,
  routeSeatGeekNotification,
  verifySeatGeekWebhook,
  planSeatGeekListings,
  platformEventToCandidate,
  seatGeekChannel,
  transferFulfilmentForm,
  type SeatGeekAllocation,
  type SeatGeekWriteAuthorization,
} from '.';
import { planDelivery } from '..';

const ALLOC = '3f0c2a1e-8b5d-4c7a-9e21-0a1b2c3d4e5f';
const json = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status });

describe('endpoint policy', () => {
  it('tags every GET read, and the whole-inventory endpoints forbidden', () => {
    for (const [name, ep] of Object.entries(SEATGEEK_ENDPOINTS)) {
      if (ep.method === 'GET') expect(ep.access, name).toBe('read');
      else expect(ep.access, name).not.toBe('read');
    }
    expect(SEATGEEK_ENDPOINTS.syncListingsCsvPost.access).toBe('forbidden');
    expect(SEATGEEK_ENDPOINTS.syncListingsCsvPut.access).toBe('forbidden');
    expect(SEATGEEK_ENDPOINTS.purgeListings.access).toBe('forbidden');
  });

  it('only puts write endpoints on the roadmap', () => {
    for (const p of SEATGEEK_WRITE_ROADMAP) for (const e of p.endpoints) expect(SEATGEEK_ENDPOINTS[e].access).toBe('write');
  });
});

describe('SeatGeekClient', () => {
  it('sends GETs with the bearer token and builds the query', async () => {
    const fetch = vi.fn(async () => json({ orders: [], meta: {} }));
    const c = new SeatGeekClient({ token: () => 'tok', fetch, baseUrl: 'https://sg.test' });
    await c.listOrders({ start_date: new Date('2026-09-27T00:00:00Z'), page: 2, per_page: 50 });
    const [url, init] = fetch.mock.calls[0] as unknown as [string, RequestInit];
    expect(url).toBe('https://sg.test/orders?start_date=2026-09-27T00%3A00%3A00.000Z&page=2&per_page=50');
    expect(init.method).toBe('GET');
    expect((init.headers as Record<string, string>).Authorization).toBe('Bearer tok');
  });

  it('retries a transient 503 on a read', async () => {
    const fetch = vi.fn().mockResolvedValueOnce(new Response('', { status: 503 })).mockResolvedValueOnce(json({ email: 'A@x.com ' }));
    const c = new SeatGeekClient({ token: () => 'tok', fetch, sleep: async () => {} });
    expect(customerEmail(await c.getOrderCustomer('o1'))).toBe('a@x.com');
    expect(fetch).toHaveBeenCalledTimes(2);
  });
});

describe('listing ids', () => {
  it('fits 32 chars, round-trips the allocation id and rejects broker ids', () => {
    const id = exosSellerListingId(ALLOC, 2);
    expect(id).toMatch(/^ex[a-z2-7]{26}2$/);
    expect(exosSellerListingId(ALLOC, 9999).length).toBeLessThanOrEqual(32);
    expect(isExosSellerListingId(id)).toBe(true);
    expect(allocationIdFromSellerListingId(id)).toBe(ALLOC);
    expect(allocationIdFromSellerListingId(exosSellerListingId('ffffffff-ffff-ffff-ffff-ffffffffffff', 1))).toBe('ffffffff-ffff-ffff-ffff-ffffffffffff');
    for (const broker of ['abc1234', ALLOC, `x${id}`, id.slice(0, -1) + '0', '10002', '']) {
      expect(isExosSellerListingId(broker), broker).toBe(false);
      expect(allocationIdFromSellerListingId(broker)).toBeNull();
    }
  });

  it('splits an allocation into groups of at most max per order', () => {
    expect(groupSizes(10, 4)).toEqual([4, 4, 2]);
    expect(groupSizes(8, 4)).toEqual([4, 4]);
    expect(groupSizes(3, 4)).toEqual([3]);
    expect(groupSizes(5, null)).toEqual([5]);
    expect(groupSizes(0, 4)).toEqual([]);
  });
});

describe('planSeatGeekListings', () => {
  const base: SeatGeekAllocation = {
    id: ALLOC,
    requested_qty: 10,
    unit_price: 45,
    tier: { name: 'GA', price: 40 },
    event: {
      name: 'Late Night Jazz',
      starts_at: '2026-11-07T02:00:00Z',
      occurs_at_local: '2026-11-06T21:00:00-05:00',
      venue_name: 'Blue Room',
      venue_address: { city: 'Brooklyn' },
      currency: 'USD',
      purchase_limits: { maxPerOrder: 4 },
    },
  };

  it('plans one listing per max-per-order group, unlinked event as text', () => {
    const p = planSeatGeekListings(base);
    expect(p.listings.map((l) => l.body.quantity)).toEqual([4, 4, 2]);
    expect(p.per_order_cap).toBe(4);
    expect(p.listings[0].path).toBe(`/listings/single/${exosSellerListingId(ALLOC, 1)}`);
    expect(p.listings[2].body).toMatchObject({
      seller_listing_id: exosSellerListingId(ALLOC, 3),
      cost: 45,
      section: 'GA',
      row: 'GA',
      stock_type: 'mobile',
      is_edelivery: true,
      split_type: 'ANY',
      event: 'Late Night Jazz',
      event_date: '2026-11-06',
      event_time: '21:00:00',
      venue: 'Blue Room',
    });
    expect(p.listings[0].body.event_id).toBeUndefined();
    expect(p.unresolved.some((u) => u.startsWith('seat_from'))).toBe(true);
    expect(p.unresolved.some((u) => u.startsWith('event_id'))).toBe(true);
  });

  it('uses the linked SeatGeek event id instead of the text', () => {
    const p = planSeatGeekListings({ ...base, seatgeekEventId: '6123456' });
    // event / venue / date are required even with an event_id.
    expect(p.listings[0].body).toMatchObject({ event_id: 6123456, event: 'Late Night Jazz', venue: 'Blue Room' });
    expect(p.unresolved.some((u) => u.startsWith('event_id'))).toBe(false);
  });

  it('refuses what it cannot describe', () => {
    expect(() => planSeatGeekListings({ ...base, tier: null })).toThrow(/ticket type/);
    expect(() => planSeatGeekListings({ ...base, requested_qty: 0 })).toThrow(/nothing allocated/);
    expect(() => planSeatGeekListings({ ...base, event: { ...base.event!, currency: 'EUR' } })).toThrow(/USD/);
    expect(() => planSeatGeekListings({ ...base, seatgeekEventId: 'abc' })).toThrow(/not a SeatGeek event id/);
  });
});

describe('orders', () => {
  const order = {
    id: 'SG-1',
    status: 'confirmed',
    created: '2026-09-27T17:54:56Z',
    event: { seatgeek_event_id: 6123456, name: 'Late Night Jazz' },
    listing: { id: exosSellerListingId(ALLOC, 2), quantity: 3, section: 'GA', row: 'GA', price: 45 },
    subtotal: 135,
    fees: 13.5,
    total: 121.5,
  };

  it('normalizes an order back to its allocation', () => {
    expect(normalizeSeatGeekOrder(order)).toMatchObject({
      channel: 'seatgeek',
      externalOrderId: 'SG-1',
      externalEventId: '6123456',
      externalListingId: ALLOC,
      quantity: 3,
      status: 'confirmed',
      proceeds: { amount: 121.5, currency: 'USD' },
      buyerEmail: null,
    });
    expect(normalizeSeatGeekOrder({ ...order, status: 'void' }).status).toBe('cancelled');
    expect(normalizeSeatGeekOrder({ ...order, status: 'denied' }).status).toBe('cancelled');
    expect(normalizeSeatGeekOrder({ ...order, status: 'submitted' }).status).toBe('pending');
    // The guide's older order shape: item_id / quantity at the top.
    const legacy = { id: 'SG-2', status: 'confirmed', item_id: exosSellerListingId(ALLOC, 1), quantity: 2, total: 90 };
    expect(normalizeSeatGeekOrder(legacy)).toMatchObject({ externalListingId: ALLOC, quantity: 2 });
    expect(normalizeSeatGeekOrder({ ...order, status: 'weird' }).status).toBe('unknown');
    // A broker listing keeps its own id (and the record RPC ignores it).
    expect(normalizeSeatGeekOrder({ ...order, listing: { id: 'abc1234', quantity: 1 } }).externalListingId).toBe('abc1234');
    expect(() => normalizeSeatGeekOrder({})).toThrow();
  });

  it('plans delivery as PATCH /order with one claim link per ticket', () => {
    const plan = planDelivery(seatGeekChannel(), { external_order_id: 'SG-1', quantity: 2, transfer_ids: ['0b7f5d3a-1c2e-4f6a-8b9d-111111111111', '0b7f5d3a-1c2e-4f6a-8b9d-222222222222'] }, 'https://exos.test/bridge');
    expect(plan.kind).toBe('planned');
    if (plan.kind !== 'planned') return;
    expect(plan.request).toMatchObject({ channel: 'seatgeek', endpoint: 'updateOrder', method: 'PATCH', path: '/order' });
    const body = plan.request.body as { form: [string, string][]; unresolved: string[] };
    expect(body.form).toEqual([
      ['order_id', 'SG-1'], ['status', 'fulfilled'], ['delivery_method', 'electronic'], ['stock_type', 'mobile'],
      ['transfer_url', plan.claim_urls.join(',')],
    ]);
    expect(body.unresolved).toEqual([]);
  });

  it('checks the fulfilment form', () => {
    expect(confirmOrderForm(' SG-1 ')).toEqual([['order_id', 'SG-1'], ['status', 'confirmed']]);
    expect(() => transferFulfilmentForm({ orderId: 'SG-1', urls: ['https://a'], quantity: 2 })).toThrow(/1 transfer urls for 2/);
    expect(() => transferFulfilmentForm({ orderId: 'SG-1', urls: ['http://a'], quantity: 1 })).toThrow(/https/);
    expect(() => transferFulfilmentForm({ orderId: 'SG-1', urls: ['https://a', 'https://a'], quantity: 2 })).toThrow(/duplicate/);
    expect(() => transferFulfilmentForm({ orderId: 'SG-1', urls: ['https://a,b'], quantity: 1 })).toThrow(/comma/);
  });
});

describe('SeatGeekWriter', () => {
  const AUTH: SeatGeekWriteAuthorization = {
    approvedBy: 'operator@example.test',
    approvedAt: '2026-10-01T00:00:00Z',
    reference: 'https://example.test/signoff',
    endpoints: ['createListing'],
  };
  const listing = { seller_listing_id: exosSellerListingId(ALLOC, 1), quantity: 2, cost: 45, section: 'GA' };
  const L1 = exosSellerListingId(ALLOC, 1);

  it('plans without fetching in dry-run', async () => {
    const onPlan = vi.fn();
    const w = new SeatGeekWriter({ onPlan });
    const r = await w.createListing(listing);
    expect(r).toEqual({ dryRun: true, planned: { endpoint: 'createListing', method: 'PUT', url: `/listings/single/${L1}`, body: listing } });
    const d = await w.deleteListings([listing.seller_listing_id]);
    expect(d.planned).toMatchObject({ endpoint: 'bulkDeleteListings', method: 'POST', url: '/listings/bulk-delete', body: { seller_listing_ids: [L1] } });
    expect(onPlan).toHaveBeenCalledTimes(2);
  });

  it('refuses broker listing ids, even in dry-run', () => {
    const w = new SeatGeekWriter();
    expect(() => w.deleteListings(['abc1234'])).toThrow(SeatGeekWriteRefusedError);
    expect(() => w.createListing({ ...listing, seller_listing_id: 'abc1234' })).toThrow(/not an Exos listing id/);
  });

  it('refuses a live writer without a valid authorization, and endpoints outside it', async () => {
    expect(() => new SeatGeekWriter({ mode: { mode: 'live', authorization: { ...AUTH, reference: '' } }, token: () => 't' })).toThrow(/reference/);
    expect(() => new SeatGeekWriter({ mode: { mode: 'live', authorization: { ...AUTH, endpoints: ['purgeListings' as never] } }, token: () => 't' })).toThrow(/not an allowed write/);
    const fetch = vi.fn(async () => json({ ok: true }));
    const w = new SeatGeekWriter({ mode: { mode: 'live', authorization: AUTH }, token: () => 't', fetch, baseUrl: 'https://sg.test' });
    await expect(w.deleteListings([listing.seller_listing_id])).rejects.toThrow(/authorization scope/);
    expect(fetch).not.toHaveBeenCalled();
    const r = await w.createListing(listing);
    expect(r.dryRun).toBe(false);
    expect(fetch).toHaveBeenCalledTimes(1);
  });

  it('sends a transfer fulfilment as multipart form data when authorized', async () => {
    const fetch = vi.fn(async () => json({ id: 'SG-1', status: 'fulfilled' }));
    const w = new SeatGeekWriter({ mode: { mode: 'live', authorization: { ...AUTH, endpoints: ['updateOrder'] } }, token: () => 't', authScheme: 'token', fetch, baseUrl: 'https://sg.test' });
    await w.fulfilWithTransferUrls({ orderId: 'SG-1', urls: ['https://a', 'https://b'], quantity: 2 });
    const [url, init] = fetch.mock.calls[0] as unknown as [string, RequestInit];
    expect(url).toBe('https://sg.test/order');
    expect(init.method).toBe('PATCH');
    expect((init.headers as Record<string, string>).Authorization).toBe('token t');
    const fd = init.body as FormData;
    expect(fd.get('transfer_url')).toBe('https://a,https://b');
    expect(fd.get('stock_type')).toBe('mobile');
  });

});

describe('Platform event search', () => {
  it('searches one local date and maps events to candidates', async () => {
    const fetch = vi.fn(async () => json({ events: [{ id: 6123456, title: 'Late Night Jazz', datetime_local: '2026-11-06T21:00:00', datetime_utc: '2026-11-07T02:00:00', url: 'https://seatgeek.com/e', venue: { name: 'Blue Room', city: 'Brooklyn' } }] }));
    const p = new SeatGeekPlatformClient('cid', { fetch });
    const ch = seatGeekChannel(p);
    expect(ch.capabilities).toMatchObject({ findEvents: true, createEvent: false, displayQuantityCap: false });
    const found = await ch.findEvents!({ id: 'e1', name: 'Late Night Jazz', startsAt: '2026-11-07T02:00:00Z', occursAtLocal: '2026-11-06T21:00:00-05:00', venueName: 'Blue Room' });
    const url = new URL((fetch.mock.calls[0] as unknown as [string])[0]);
    expect(url.pathname).toBe('/2/events');
    expect(url.searchParams.get('datetime_local.gte')).toBe('2026-11-06T00:00:00');
    expect(url.searchParams.get('client_id')).toBe('cid');
    expect(found).toEqual([platformEventToCandidate({ id: 6123456, title: 'Late Night Jazz', datetime_local: '2026-11-06T21:00:00', datetime_utc: '2026-11-07T02:00:00', url: 'https://seatgeek.com/e', venue: { name: 'Blue Room', city: 'Brooklyn' } })]);
    expect(found[0].startsAt).toBe('2026-11-07T02:00:00Z');
  });
});

describe('webhooks', () => {
  const env = (type: string, data: unknown, version = 1) => ({
    metadata: { notification_type: type, seller_id: 456, notification_id: 'n-1', notification_generated_at: '2025-06-06T19:06:09', schema_version: version },
    data,
  });

  it('checks the bearer token in constant time', () => {
    expect(verifySeatGeekWebhook('Bearer s3cret', 's3cret')).toBe(true);
    expect(verifySeatGeekWebhook('Bearer s3cre', 's3cret')).toBe(false);
    expect(verifySeatGeekWebhook(null, 's3cret')).toBe(false);
    expect(verifySeatGeekWebhook('Bearer ', '')).toBe(false);
  });

  it('parses batched envelopes, ignores unknown schema versions, lists single objects', () => {
    expect(parseSeatGeekNotification(env('ping', [{ ping: 'a' }, { ping: 'b' }]))!.data).toHaveLength(2);
    expect(parseSeatGeekNotification(env('ping', [], 2))).toBeNull();
    expect(parseSeatGeekNotification(env('order.fulfillment.error', { order: { order_id: 'x' }, tokens: [] }))!.data).toHaveLength(1);
    expect(() => parseSeatGeekNotification({ data: [] })).toThrow();
  });

  it('routes orders, marks broken orders cancelled, and flags listing problems', () => {
    const o = { id: 'SG-9', status: 'pending', listing: { id: exosSellerListingId(ALLOC, 1), quantity: 1 }, total: 40 };
    const created = routeSeatGeekNotification(parseSeatGeekNotification(env('order.created', [o]))!);
    expect(created).toEqual({ kind: 'orders', orders: [o] });
    const broken = routeSeatGeekNotification(parseSeatGeekNotification(env('order.broken', [o]))!);
    expect(broken.kind).toBe('orders');
    if (broken.kind === 'orders') expect(normalizeSeatGeekOrder(broken.orders[0]).status).toBe('cancelled');
    expect(routeSeatGeekNotification(parseSeatGeekNotification(env('listing.visibility', [{ seller_listing_id: 'x', hidden_reason_code: 'no_seats' }]))!).kind).toBe('attention');
    expect(routeSeatGeekNotification(parseSeatGeekNotification(env('ping', [{ ping: 'hi' }]))!).kind).toBe('ignore');
  });
});
