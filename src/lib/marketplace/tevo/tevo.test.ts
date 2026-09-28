import { createHmac } from 'node:crypto';
import { describe, expect, it, vi } from 'vitest';
import {
  TEVO_ENDPOINTS,
  TEVO_WRITE_ROADMAP,
  TevoClient,
  TevoError,
  TevoFulfilmentError,
  TevoWriteRefusedError,
  TevoWriter,
  evoChannel,
  exosListingRef,
  fraudGate,
  hmacSha256Base64,
  normalizeTevoOrder,
  orderKind,
  planTevoDelivery,
  shipmentRecipient,
  signatureBase,
  stripTevoOrder,
  toQueryString,
  type TevoOrder,
  type TevoWriteAuthorization,
} from '.';
import { exosListingId, planDelivery } from '..';

const ALLOC = '0f8fad5b-d9cb-469f-a165-70867728950e';
const LISTING = exosListingId(ALLOC, 1);
const CREDS = { token: 'tok-SECRET-123', secret: 'sec-SECRET-456' };
const AUTH: TevoWriteAuthorization = { approvedBy: 'op', approvedAt: '2026-09-28T00:00:00Z', reference: 'test', endpoints: ['acceptOrder'] };

const officeOrder = (over: Partial<TevoOrder> = {}): TevoOrder => ({
  id: 190840,
  oid: '61455-190840',
  state: 'pending',
  buyer: { type: 'Office', id: 6 },
  fraud_check_status: null,
  items: [{ id: 11, order_item_id: 22, quantity: 2, price: '45.00', ticket_group: { id: 999, section: 'GA', row: 'GA', external_notes: 'x', external_id: LISTING } }],
  created_at: '2026-09-28T12:00:00Z',
  event: { id: 1234, name: 'Late Night Jazz' },
  ...over,
});

describe('endpoints', () => {
  it('buying, etickets and physical delivery are never sendable', () => {
    for (const k of ['createOrder', 'addEtickets', 'finalizeEtickets', 'removeEtickets', 'deliverEtickets', 'bulkUpdateInventory', 'bulkDeleteInventory'] as const) {
      expect(TEVO_ENDPOINTS[k].access).toBe('forbidden');
    }
    expect(TEVO_ENDPOINTS.acceptOrder).toMatchObject({ method: 'POST', path: '/v9/orders/{order_id}/accept', access: 'write' });
    expect(TEVO_WRITE_ROADMAP.flatMap((p) => p.endpoints)).toEqual(['createInventory', 'updateInventory', 'deleteInventory', 'acceptOrder', 'updateShipment', 'completeShipment']);
  });
});

describe('signing', () => {
  it('signs "<METHOD> <host><path>?<query|body>" with HMAC-SHA256, base64', async () => {
    const base = signatureBase('get', 'https://api.sandbox.ticketevolution.com/', '/v9/orders', 'page=1&state=pending');
    expect(base).toBe('GET api.sandbox.ticketevolution.com/v9/orders?page=1&state=pending');
    const expected = createHmac('sha256', CREDS.secret).update(base).digest('base64');
    expect(await hmacSha256Base64(CREDS.secret, base)).toBe(expected);
  });

  it('sorts the query so the signed string and the URL agree', () => {
    expect(toQueryString({ state: 'pending', page: 2, empty: '', gone: undefined })).toBe('page=2&state=pending');
  });
});

describe('TevoClient (reads only)', () => {
  it('sends X-Token and a signature over exactly the URL it calls, and never leaks credentials', async () => {
    const calls: Array<{ url: string; init: RequestInit }> = [];
    const fetchImpl = vi.fn(async (url: string, init?: RequestInit) => {
      calls.push({ url, init: init! });
      return new Response(JSON.stringify({ orders: [officeOrder()] }), { status: 200 });
    });
    const c = new TevoClient({ credentials: () => CREDS, fetch: fetchImpl });
    const orders = await c.listOrders({ state: 'pending', page: 1 });
    expect(orders).toHaveLength(1);
    const { url, init } = calls[0];
    expect(url).toBe('https://api.sandbox.ticketevolution.com/v9/orders?page=1&state=pending');
    const h = init.headers as Record<string, string>;
    expect(h['X-Token']).toBe(CREDS.token);
    const expected = createHmac('sha256', CREDS.secret).update('GET api.sandbox.ticketevolution.com/v9/orders?page=1&state=pending').digest('base64');
    expect(h['X-Signature']).toBe(expected);
    expect(url).not.toContain(CREDS.secret);
  });

  it('redacts credentials echoed in an error and retries transient failures', async () => {
    let n = 0;
    const fetchImpl = vi.fn(async () => {
      n++;
      if (n === 1) return new Response('busy', { status: 503 });
      return new Response(JSON.stringify({ error: `bad token ${CREDS.token}` }), { status: 401 });
    });
    const c = new TevoClient({ credentials: () => CREDS, fetch: fetchImpl, sleep: async () => {} });
    const err = await c.getOrder(1).catch((e) => e);
    expect(err).toBeInstanceOf(TevoError);
    expect(String(err.message)).not.toContain(CREDS.token);
    expect(JSON.stringify(err.body)).not.toContain(CREDS.token);
    expect(fetchImpl).toHaveBeenCalledTimes(2);
  });
});

describe('orders', () => {
  it('tells a sale to TEvo from a sale to a Client', () => {
    expect(orderKind(officeOrder())).toBe('sale_to_tevo');
    expect(orderKind(officeOrder({ buyer: { type: 'Office', id: 7 } }))).toBe('unknown');
    expect(orderKind(officeOrder({ buyer: { type: 'Client', id: 55 } }))).toBe('sale_to_client');
  });

  it('holds a Client sale until Riskified approves it', () => {
    const client = (s: TevoOrder['fraud_check_status']) => officeOrder({ buyer: { type: 'Client', id: 55 }, fraud_check_status: s });
    expect(fraudGate(client(null))).toEqual({ ok: true });
    expect(fraudGate(client('approved'))).toEqual({ ok: true });
    expect(fraudGate(client('pending'))).toMatchObject({ ok: false, wait: true });
    expect(fraudGate(client('declined'))).toMatchObject({ ok: false, wait: false });
    expect(fraudGate(officeOrder({ buyer: { type: 'Office', id: 6 }, fraud_check_status: 'pending' }))).toEqual({ ok: true });
  });

  it('finds the Exos listing id on the ticket group, and nothing on a broker listing', () => {
    expect(exosListingRef(officeOrder().items![0])).toBe(LISTING);
    expect(exosListingRef({ ticket_group: { id: 5, external_id: 'BROKER-77' } })).toBeNull();
    expect(exosListingRef(undefined)).toBeNull();
  });

  it('stores orders without the buyer\'s or the shipment\'s personal details', () => {
    const o = officeOrder({
      buyer: { type: 'Client', id: 55, name: 'Moe Szyslak', email_address: { address: 'moe@example.com' } },
      shipments: [{ id: 78826, type: 'TMMobile', state: 'pending', ship_to_name: 'Moe Szyslak', email_address: { address: 'moe@example.com' } }],
    });
    const stored = JSON.stringify(stripTevoOrder(o));
    expect(stored).not.toContain('moe@example.com');
    expect(stored).not.toContain('Moe Szyslak');
    expect(stripTevoOrder(o)).toMatchObject({ id: 190840, buyer: { type: 'Client', id: 55 }, shipments: [{ id: 78826, type: 'TMMobile', state: 'pending' }] });
  });

  it('normalizes an order into a sale', () => {
    const s = normalizeTevoOrder(officeOrder());
    expect(s).toMatchObject({
      channel: 'evo', externalOrderId: '190840', externalEventId: '1234', externalListingId: ALLOC, listingRef: LISTING,
      quantity: 2, status: 'pending', buyerEmail: null, proceeds: { amount: 87.3, currency: 'USD' }, section: 'GA',
    });
    const c = normalizeTevoOrder(officeOrder({ state: 'accepted', buyer: { type: 'Client', id: 1, email_address: { address: ' Fan@X.com ' } }, fraud_check_status: 'pending' }));
    expect(c.status).toBe('pending');
    expect(c.buyerEmail).toBe('fan@x.com');
    expect(normalizeTevoOrder(officeOrder({ state: 'weird' })).status).toBe('unknown');
    expect(() => normalizeTevoOrder({ id: 'abc' })).toThrow();
  });
});

describe('delivery plan', () => {
  const urls = (n: number) => Array.from({ length: n }, (_, i) => `https://exos.example/bridge/claim/${'00000000-0000-4000-8000-00000000000' + i}`);

  it('one ticket: accept, TMMobileLink, complete with the claim link', () => {
    const p = planTevoDelivery({ orderId: 190840, quantity: 1, claimUrls: urls(1), reviewerId: 2487, seats: [7] });
    expect(p.map((r) => r.endpoint)).toEqual(['acceptOrder', 'updateShipment', 'completeShipment']);
    expect(p[0]).toMatchObject({ method: 'POST', path: '/v9/orders/190840/accept', body: { reviewer_id: 2487, seats: [7] } });
    expect(p[1].body).toEqual({ mobile_transfer_type: 'TMMobileLink' });
    expect(p[2].body).toEqual({ tm_mobile_link: urls(1)[0] });
  });

  it('several tickets: the email route (one link per shipment only)', () => {
    const p = planTevoDelivery({ orderId: '190840', quantity: 3, claimUrls: urls(3), reviewerId: 2487 });
    expect(p[1].body).toEqual({ mobile_transfer_type: 'TMMobile' });
    expect(p[2].body).toEqual({});
  });

  it('refuses a bad plan', () => {
    expect(() => planTevoDelivery({ orderId: 1, quantity: 2, claimUrls: urls(1), reviewerId: 1 })).toThrow(TevoFulfilmentError);
    expect(() => planTevoDelivery({ orderId: 1, quantity: 1, claimUrls: ['http://x/claim/1'], reviewerId: 1 })).toThrow(/https/);
    expect(() => planTevoDelivery({ orderId: 1, quantity: 1, claimUrls: urls(1), reviewerId: null })).toThrow(/TEVO_REVIEWER_ID/);
    expect(() => planTevoDelivery({ orderId: 'x1', quantity: 1, claimUrls: urls(1), reviewerId: 1 })).toThrow(/order id/);
  });

  it('reads the recipient TEvo names for an email transfer', () => {
    expect(shipmentRecipient({ ship_to_name: 'Moe Szyslak', email_address: { address: 'Moe.Szyslak@example.com' } })).toEqual({ email: 'moe.szyslak@example.com', name: 'Moe Szyslak' });
    expect(shipmentRecipient({})).toBeNull();
  });

  it('plugs into the shared delivery planner', () => {
    const plan = planDelivery(evoChannel({ reviewerId: 2487 }), { external_order_id: '190840', quantity: 1, transfer_ids: ['00000000-0000-4000-8000-000000000001'] }, 'https://exos.example/bridge');
    expect(plan.kind).toBe('planned');
  });
});

describe('TevoWriter', () => {
  it('dry-run by default: plans, never calls fetch, holds no credentials', async () => {
    const fetchImpl = vi.fn();
    const w = new TevoWriter({ fetch: fetchImpl, credentials: () => CREDS });
    const r = await w.acceptOrder(officeOrder(), { reviewer_id: 2487, seats: [1, 2] });
    expect(r).toMatchObject({ dryRun: true, planned: { endpoint: 'acceptOrder', method: 'POST', url: '/v9/orders/190840/accept', body: { reviewer_id: 2487, seats: [1, 2] } } });
    expect(JSON.stringify(r)).not.toContain(CREDS.token);
    expect(fetchImpl).not.toHaveBeenCalled();
    expect(w.isLive).toBe(false);
  });

  it('refuses broker orders, pending fraud checks and non-mobile delivery', () => {
    const w = new TevoWriter();
    const broker = officeOrder({ items: [{ id: 1, quantity: 1, ticket_group: { id: 1, external_id: 'BROKER-1' } }] });
    expect(() => w.acceptOrder(broker, { reviewer_id: 1 })).toThrow(TevoWriteRefusedError);
    const pending = officeOrder({ buyer: { type: 'Client', id: 9 }, fraud_check_status: 'pending' });
    expect(() => w.acceptOrder(pending, { reviewer_id: 1 })).toThrow(/Riskified/);
    expect(() => w.updateShipment(1, { mobile_transfer_type: 'Eticket' as never })).toThrow(/mobile transfer/);
    expect(() => w.completeShipment(1, { tm_mobile_link: 'http://insecure' })).toThrow(/https/);
  });

  it('live needs a valid authorization and stays inside its scope', async () => {
    expect(() => new TevoWriter({ mode: { mode: 'live', authorization: { ...AUTH, approvedBy: '' } }, credentials: () => CREDS })).toThrow(TevoWriteRefusedError);
    expect(() => new TevoWriter({ mode: { mode: 'live', authorization: { ...AUTH, endpoints: ['createOrder' as never] } }, credentials: () => CREDS })).toThrow(/not an allowed write/);
    const fetchImpl = vi.fn(async () => new Response(JSON.stringify({ id: 190840, state: 'accepted' }), { status: 200 }));
    const w = new TevoWriter({ mode: { mode: 'live', authorization: AUTH }, credentials: () => CREDS, fetch: fetchImpl });
    await expect(w.updateShipment(78817, { mobile_transfer_type: 'TMMobileLink' })).rejects.toThrow(/authorization scope/);
    const r = await w.acceptOrder(officeOrder(), { reviewer_id: 2487 });
    expect(r.dryRun).toBe(false);
    expect(fetchImpl).toHaveBeenCalledTimes(1);
  });
});

describe('multi-item orders', () => {
  const ALLOC2 = '7c9e6679-7425-40de-944b-e07fc1f90ae7';
  const LISTING2 = exosListingId(ALLOC2, 1);
  const item = (id: number, qty: number, ext: string, price = '45.00') =>
    ({ id, order_item_id: id + 100, quantity: qty, price, ticket_group: { id: id + 1000, section: 'GA', row: 'GA', external_id: ext } });

  it('items from one Exos listing: summed and fulfilled as usual', () => {
    const s = normalizeTevoOrder(officeOrder({ state: 'accepted', items: [item(1, 2, LISTING), item(2, 3, LISTING)] }));
    expect(s).toMatchObject({ status: 'confirmed', quantity: 5, externalListingId: ALLOC, note: null, proceeds: { amount: 218.25 } }); // 225 less the standard 3%
  });

  it('items from different Exos listings: never the whole quantity from the first one', () => {
    const s = normalizeTevoOrder(officeOrder({ state: 'accepted', items: [item(1, 2, LISTING), item(2, 3, LISTING2)] }));
    expect(s.status).toBe('unknown');
    expect(s.note).toMatch(/2 different Exos listings/);
    expect(s.note).toContain(LISTING2);
  });

  it('a cancelled multi-listing order is still a cancellation', () => {
    const s = normalizeTevoOrder(officeOrder({ state: 'cancelled', items: [item(1, 2, LISTING), item(2, 3, LISTING2)] }));
    expect(s.status).toBe('cancelled');
    expect(s.note).toBeNull();
  });

  it("proceeds are net of TEvo's seller fee (order 8089940-19196777: 32.48 - 0.97 = 31.51)", () => {
    const one = normalizeTevoOrder(officeOrder({ state: 'completed', total: '32.48', fee: '0.97', service_fee: '0.0', items: [item(1, 1, LISTING, '32.48')] }));
    expect(one.proceeds).toEqual({ amount: 31.51, currency: 'USD' });
    // No fee field on the order: the standard 3% (90.00 -> 2.70).
    expect(normalizeTevoOrder(officeOrder({ items: [item(1, 2, LISTING, '45.00')] })).proceeds).toEqual({ amount: 87.3, currency: 'USD' });
    // Shared with broker items: Exos bears its price share of the fee (2 x 45 of 6 x 45 -> 1/3 of 3.00).
    const mixed = normalizeTevoOrder(officeOrder({ state: 'accepted', fee: '3.00', items: [item(1, 4, 'BROKER-9'), item(2, 2, LISTING)] }));
    expect(mixed.proceeds).toEqual({ amount: 89, currency: 'USD' });
    // A fee TEvo reports is used as reported, even 0.
    expect(normalizeTevoOrder(officeOrder({ fee: '0.0', items: [item(1, 2, LISTING, '45.00')] })).proceeds).toEqual({ amount: 90, currency: 'USD' });
  });

  it('Exos items next to broker items: only the Exos quantity counts, and a person delivers it', () => {
    const s = normalizeTevoOrder(officeOrder({ state: 'accepted', items: [item(1, 4, 'BROKER-9'), item(2, 2, LISTING)] }));
    expect(s).toMatchObject({ status: 'unknown', quantity: 2, externalListingId: ALLOC });
    expect(s.note).toMatch(/broker items/);
  });

  it('the writer refuses to accept a multi-listing order', () => {
    const w = new TevoWriter();
    expect(() => w.acceptOrder(officeOrder({ items: [item(1, 2, LISTING), item(2, 1, LISTING2)] }), { reviewer_id: 1 })).toThrow(/several Exos listings/);
  });
});
