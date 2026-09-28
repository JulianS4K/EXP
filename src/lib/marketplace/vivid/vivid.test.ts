import { describe, expect, it, vi } from 'vitest';
import {
  VIVID_ENDPOINTS,
  VIVID_WRITE_ROADMAP,
  VividClient,
  VividWriteRefusedError,
  VividWriter,
  normalizeVividOrder,
  ordersFromXml,
  parseXml,
  planVividListings,
  transferViaUrlForm,
  vividChannel,
  vividEventToCandidate,
  type VividAllocation,
  type VividWriteAuthorization,
} from '.';
import { exosListingId, planDelist, planDelivery, syncListings } from '..';

const ALLOC = '0f8fad5b-d9cb-469f-a165-70867728950e';
const TOKEN = 'tok-SECRET-123';
const base: VividAllocation = {
  id: ALLOC,
  requested_qty: 6,
  unit_price: 45,
  internal_seats: '{[1,7)}',
  tier: { name: 'GA', price: 40 },
  event: {
    name: 'Late Night Jazz', starts_at: '2026-11-07T02:00:00Z', occurs_at_local: '2026-11-06T21:00:00-05:00',
    venue_name: 'Blue Room', venue_address: { city: 'Brooklyn', region: 'NY', country: 'US' }, currency: 'USD', purchase_limits: { maxPerOrder: 4 },
  },
};
const AUTH: VividWriteAuthorization = { approvedBy: 'op', approvedAt: '2026-09-28T00:00:00Z', reference: 'test', endpoints: ['confirmOrder'] };

const ORDERS_XML = `<?xml version="1.0" encoding="UTF-8"?>
<orders>
  <order>
    <orderId>9001</orderId><orderToken>abc</orderToken>
    <brokerTicketId>${exosListingId(ALLOC, 2)}</brokerTicketId>
    <section>GA</section><row>GA</row>
    <seats><seat>5</seat><seat>6</seat></seats>
    <quantity>2</quantity><cost>41.25</cost>
    <event><![CDATA[Late Night Jazz & Friends]]></event>
    <orderDate>2026-10-01 12:00:00</orderDate>
    <status>UNCONFIRMED</status><productionId>4455667</productionId>
    <firstName>Pat</firstName><emailAddress> Fan@Example.com </emailAddress><mobilePhoneNumber>555</mobilePhoneNumber>
    <transferViaURL>true</transferViaURL>
  </order>
  <order><orderId>9002</orderId><brokerTicketId>BROKER-1</brokerTicketId><quantity>1</quantity><cost>10</cost><status>PENDING_SHIPMENT</status><notes>A &amp; B</notes></order>
</orders>`;

const xmlResponse = (s: string, status = 200) => new Response(s, { status, headers: { 'content-type': 'application/xml' } });

describe('endpoints', () => {
  it('forbids the v1 listing writes; the roadmap only holds writes', () => {
    const forbidden = Object.entries(VIVID_ENDPOINTS).filter(([, e]) => e.access === 'forbidden').map(([k]) => k).sort();
    expect(forbidden).toEqual(['deleteListingV1', 'updateListingV1']);
    for (const p of VIVID_WRITE_ROADMAP) for (const e of p.endpoints) expect(VIVID_ENDPOINTS[e].access).toBe('write');
  });
});

describe('xml', () => {
  it('reads orders whatever the wrapper, with seats, entities and CDATA', () => {
    const orders = ordersFromXml(parseXml(ORDERS_XML));
    expect(orders).toHaveLength(2);
    expect(orders[0]).toMatchObject({ orderId: 9001, quantity: 2, cost: 41.25, seats: ['5', '6'], event: 'Late Night Jazz & Friends', productionId: 4455667, transferViaURL: true });
    expect(orders[1]).toMatchObject({ orderId: 9002, notes: 'A & B', seats: [] });
    expect(ordersFromXml(parseXml('<order><orderId>7</orderId></order>'))[0].orderId).toBe(7);
    expect(() => parseXml('<a><b></a>')).toThrow();
    expect(() => parseXml('<a></a><b></b>')).toThrow(/more than one root/);
  });
});

describe('client', () => {
  it('puts apiToken in the v1 query at send time only, and redacts it from errors', async () => {
    const f = vi.fn(async (url: string, init?: RequestInit) => {
      expect(url).toBe(`https://brokers.vividseats.com/webservices/v1/getOrders?status=UNCONFIRMED&apiToken=${TOKEN}`);
      expect((init!.headers as Record<string, string>)['Api-token']).toBeUndefined();
      expect((init!.headers as Record<string, string>)['X-Integrator-Token']).toBe('INT');
      return xmlResponse(`<response><success>false</success><message>bad token ${TOKEN}</message></response>`, 401);
    });
    const c = new VividClient({ credentials: () => ({ apiToken: TOKEN, integratorToken: 'INT' }), fetch: f, sleep: async () => {} });
    const err = (await c.getOrders('UNCONFIRMED').catch((e) => e)) as Error & { body: unknown };
    expect(String(err)).toMatch(/GET \/v1\/getOrders -> 401: bad token \[redacted\]/);
    expect(String(err)).not.toContain(TOKEN);
    expect(JSON.stringify(err.body)).not.toContain(TOKEN);
  });

  it('reads orders; a 200 with success=false is an error; an empty getOrder is null', async () => {
    const answers = [xmlResponse(ORDERS_XML), xmlResponse('<response><success>false</success><message>Invalid orderId</message></response>'), xmlResponse('<orders></orders>')];
    const c = new VividClient({ credentials: () => ({ apiToken: TOKEN }), fetch: vi.fn(async () => answers.shift()!), sleep: async () => {} });
    expect((await c.getOrders('UNCONFIRMED')).map((o) => o.orderId)).toEqual([9001, 9002]);
    await expect(c.getOrder(1)).rejects.toThrow(/getOrder failed: Invalid orderId/);
    expect(await c.getOrder(2)).toBeNull();
  });

  it('sends Api-token as a header on v2 and spaces event searches 5 seconds apart', async () => {
    let t = 0;
    const sleep = vi.fn(async (ms: number) => { t += ms; });
    const f = vi.fn(async (url: string, init?: RequestInit) => {
      expect(url).not.toContain(TOKEN);
      expect((init!.headers as Record<string, string>)['Api-token']).toBe(TOKEN);
      return new Response(JSON.stringify([{ eventId: 4455667, eventName: 'Late Night Jazz', eventDate: '2026-11-06T21:00:00', venue: { name: 'Blue Room', city: 'Brooklyn' }, webPath: '/x/4455667' }]));
    });
    const c = new VividClient({ credentials: () => ({ apiToken: TOKEN }), fetch: f, sleep, now: () => t });
    await c.searchEvents({ eventKeyword: 'Late Night Jazz' });
    t += 1_000;
    await c.searchEvents({ eventKeyword: 'Late Night Jazz' });
    expect(sleep).toHaveBeenCalledWith(4_000);
    await expect(c.searchEvents({ fromDate: '2026-11-06T00:00:00' })).rejects.toThrow(/together/);
  });
});

describe('listings', () => {
  it('plans the Exos blocks as Vivid listings: our ticketId, hidden internal seats, venue-local date', () => {
    const p = planVividListings({ ...base, vividProductionId: '4455667' });
    expect(p.listings.map((l) => [l.listing_id, l.seat_from, l.seat_thru])).toEqual([[exosListingId(ALLOC, 1), 1, 4], [exosListingId(ALLOC, 2), 5, 6]]);
    expect(p.listings[1].request).toMatchObject({ endpoint: 'createListing', method: 'POST', path: '/listings/v2/create' });
    expect(p.listings[1].request.body).toEqual({
      productionId: 4455667, ticketId: exosListingId(ALLOC, 2), quantity: 2, section: 'GA', row: 'GA', seatFrom: '5', seatThru: '6',
      hideSeats: true, notes: expect.stringContaining('Exos'), price: 45, faceValue: 40, priceCurrency: 'USD',
      splitType: 'ANY', stockType: 'ELECTRONIC', electronic: true, electronicTransfer: true, inHandDate: '2026-11-06T00:00:00',
      eventName: 'Late Night Jazz', venue: 'Blue Room', venueCity: 'Brooklyn', venueRegion: 'NY', venueCountryCode: 'US',
      eventDate: '2026-11-06T21:00:00',
    });
    expect(p.unresolved).toEqual([]);
    const unlinked = planVividListings(base);
    expect(unlinked.listings[0].request.body.productionId).toBeUndefined();
    expect(unlinked.unresolved[0]).toMatch(/mapping team/);
    expect(() => planVividListings({ ...base, event: { ...base.event!, currency: 'EUR' } })).toThrow(/USD/);
    expect(() => planVividListings({ ...base, event: { ...base.event!, occurs_at_local: null, timezone: null } })).toThrow(/venue-local start time/);
  });

  it('syncs, and delists by our ticketId one listing at a time', () => {
    const live = planVividListings(base);
    expect(syncListings(live, null).action).toBe('create');
    const d = planDelist('vivid', { listings: [...live.listings, { listing_id: 'broker-1' }] });
    expect(d?.requests).toEqual([1, 2].map((n) => ({
      endpoint: 'deleteListing', method: 'DELETE', path: `/listings/v2/delete?internalTicketId=${exosListingId(ALLOC, n)}`,
    })));
  });
});

describe('writer', () => {
  it('plans in dry-run and refuses broker listings and unverified Vivid ids', async () => {
    const f = vi.fn();
    const w = new VividWriter({ fetch: f });
    const body = planVividListings(base).listings[0].request.body;
    expect(await w.createListing(body)).toMatchObject({ dryRun: true, planned: { endpoint: 'createListing', method: 'POST', url: '/listings/v2/create' } });
    expect(await w.deleteListing(body.ticketId)).toMatchObject({ planned: { url: `/listings/v2/delete?internalTicketId=${body.ticketId}` } });
    expect(f).not.toHaveBeenCalled();
    expect(() => w.createListing({ ...body, ticketId: 'TKT-1' })).toThrow(VividWriteRefusedError);
    expect(() => w.createListing({ ...body, id: 5 })).toThrow(/no Vivid id/);
    expect(() => w.deleteListing('12345')).toThrow(/not an Exos listing id/);
    expect(() => w.updateListing(body, { ...body, id: 77, ticketId: 'broker-9' })).toThrow(/read back by the same ticketId/);
    expect(await w.updateListing(body, { ...body, id: 77 })).toMatchObject({ planned: { endpoint: 'updateListing', body: { id: 77, ticketId: body.ticketId } } });
  });

  it('live: only the authorized endpoints; the token goes in the form, never in the plan', async () => {
    const f = vi.fn(async (_url: string, init?: RequestInit) => {
      expect(String(init!.body)).toContain(`apiToken=${TOKEN}`);
      return xmlResponse('<response><success>true</success><message>ok</message></response>');
    });
    const w = new VividWriter({ mode: { mode: 'live', authorization: AUTH }, credentials: () => ({ apiToken: TOKEN }), fetch: f });
    const r = await w.confirmOrder({ orderId: '9001', seatNumbers: '5,6' });
    expect(r).toMatchObject({ dryRun: false, planned: { url: '/v1/confirmOrder', body: { orderId: '9001', seatNumbers: '5,6' } }, response: { success: 'true' } });
    expect(JSON.stringify(r.planned)).not.toContain(TOKEN);
    await expect(w.rejectOrder(9001)).rejects.toThrow(/not in the authorization scope/);
  });
});

describe('sales', () => {
  const [order] = ordersFromXml(parseXml(ORDERS_XML));

  it('normalizes an order to its allocation and listing; cost is per ticket', () => {
    expect(normalizeVividOrder(order)).toMatchObject({
      channel: 'vivid', externalOrderId: '9001', externalEventId: '4455667', externalListingId: ALLOC,
      listingRef: exosListingId(ALLOC, 2), quantity: 2, status: 'pending', buyerEmail: 'fan@example.com',
      proceeds: { amount: 82.5, currency: 'USD' }, createdAt: '2026-10-01 12:00:00',
    });
    expect(normalizeVividOrder({ ...order, status: 'PENDING_SHIPMENT' }).status).toBe('confirmed');
    expect(normalizeVividOrder({ ...order, status: 'COMPLETED' }).status).toBe('delivered');
    expect(normalizeVividOrder({ ...order, status: 'VERIFICATION' }).status).toBe('unknown');
    expect(normalizeVividOrder({ ...order, brokerTicketId: 'BROKER-1' }).externalListingId).toBe('BROKER-1');
    expect(() => normalizeVividOrder({ orderId: 'x' })).toThrow();
  });

  it('delivers by confirm (with the internal seats), then transfer via URL with one claim link per ticket', () => {
    const plan = planDelivery(vividChannel(), { external_order_id: '9001', quantity: 2, transfer_ids: ['11111111-1111-4111-8111-111111111111', '22222222-2222-4222-8222-222222222222'], seats: [5, 6] }, 'https://exos.test');
    expect(plan.kind).toBe('planned');
    if (plan.kind !== 'planned') return;
    expect(plan.steps.map((s) => [s.endpoint, s.path])).toEqual([['confirmOrder', '/v1/confirmOrder'], ['transferOrderViaURL', '/v1/transferOrderViaURL']]);
    expect(plan.steps[0].body).toEqual({ orderId: '9001', seatNumbers: '5,6' });
    expect(plan.steps[1].body).toEqual({ orderId: '9001', transferURLList: plan.claim_urls, transferSource: 'Exos', transferSourceURL: 'https://exos.test' });
    expect(() => transferViaUrlForm('9001', ['https://x.test/a'], 2)).toThrow(/1 transfer urls for 2/);
    expect(() => transferViaUrlForm('abc', ['https://x.test/a'], 1)).toThrow(/order id/);
  });

  it('links events by name and the local day; eventDate is venue-local', async () => {
    const search = vi.fn(async () => [{ eventId: 4455667, eventName: 'Late Night Jazz', eventDate: '2026-11-06T21:00:00-05:00', venue: { name: 'Blue Room', city: 'Brooklyn' } }]);
    const ch = vividChannel({ searchEvents: search } as unknown as VividClient);
    const found = await ch.findEvents!({ id: 'e', name: 'Late Night Jazz', startsAt: '2026-11-07T02:00:00Z', occursAtLocal: '2026-11-06T21:00:00-05:00', venueName: 'Blue Room' });
    expect(search).toHaveBeenCalledWith({ eventKeyword: 'Late Night Jazz', fromDate: '2026-11-06T00:00:00', toDate: '2026-11-06T23:59:59' });
    expect(found[0]).toMatchObject({ channel: 'vivid', externalEventId: '4455667', startsAt: null, startsLocal: '2026-11-06T21:00:00', venueCity: 'Brooklyn' });
    expect(vividEventToCandidate({ eventId: 1, webPath: 'a/b' }).url).toBe('https://www.vividseats.com/a/b');
  });
});
