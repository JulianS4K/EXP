import { describe, expect, it } from 'vitest';
import {
  bearerToken,
  localDateTime,
  parseFeedRoute,
  parseOrderBody,
  parsePaging,
  parseSince,
  sha256Hex,
  shapeEventsPage,
  shapeOrder,
  shapeTickets,
  signWebhook,
  webhookBody,
} from '../../../supabase/functions/_shared/s4kFeed/feed';

const EV = '6c1e0000-0000-4000-8000-000000000001';
const TIER = '1f4b0000-0000-4000-8000-000000000002';
const ORDER = '9a9a0000-0000-4000-8000-000000000003';

describe('parseFeedRoute', () => {
  it('maps the paths', () => {
    expect(parseFeedRoute('/functions/v1/exos-s4k-feed/exos/events', 'GET')).toEqual({ kind: 'events' });
    expect(parseFeedRoute(`/exos-s4k-feed/exos/events/${EV.toUpperCase()}/tickets`, 'GET')).toEqual({ kind: 'tickets', eventId: EV });
    expect(parseFeedRoute(`/exos-s4k-feed/exos/events/${EV}/orders`, 'POST')).toEqual({ kind: 'order', eventId: EV });
    expect(parseFeedRoute(`/exos-s4k-feed/exos/orders/${ORDER}`, 'GET')).toEqual({ kind: 'orderGet', orderId: ORDER });
    expect(parseFeedRoute(`/exos-s4k-feed/exos/orders/${ORDER}/cancel`, 'POST')).toEqual({ kind: 'orderCancel', orderId: ORDER });
    expect(parseFeedRoute('/exos-s4k-feed/exos/status', 'GET')).toEqual({ kind: 'status' });
    expect(parseFeedRoute('/exos-s4k-feed/cron', 'POST')).toEqual({ kind: 'cron' });
  });
  it('refuses the rest', () => {
    expect(parseFeedRoute('/exos-s4k-feed/exos/events', 'POST')).toBeNull();
    expect(parseFeedRoute('/exos-s4k-feed/exos/events/not-a-uuid/tickets', 'GET')).toBeNull();
    expect(parseFeedRoute('/exos-s4k-feed/cron', 'GET')).toBeNull();
    expect(parseFeedRoute('/exos-s4k-feed/paciolan/events', 'GET')).toBeNull();
  });
});

describe('requests', () => {
  it('reads the token like the desk', () => {
    const h = (m: Record<string, string>) => (k: string) => m[k] ?? null;
    expect(bearerToken(h({ authorization: 'Bearer exf_abc' }))).toBe('exf_abc');
    expect(bearerToken(h({ authorization: 'bearer   exf_abc ' }))).toBe('exf_abc');
    expect(bearerToken(h({ 'x-api-key': 'exf_k' }))).toBe('exf_k');
    expect(bearerToken(h({}))).toBeNull();
  });
  it('parses updatedSince and paging', () => {
    expect(parseSince(null)).toEqual({ since: null });
    expect(parseSince('2026-09-28')).toEqual({ since: '2026-09-28T00:00:00.000Z' });
    expect(parseSince('2026-09-28T14:03:11Z')).toEqual({ since: '2026-09-28T14:03:11.000Z' });
    expect(parseSince('yesterday')).toHaveProperty('error');
    expect(parsePaging(null, null)).toEqual({ limit: 200, offset: 0 });
    expect(parsePaging('5000', '-3')).toEqual({ limit: 1000, offset: 0 });
  });
  it('validates an order body', () => {
    const ok = parseOrderBody({ ticketId: TIER, quantity: 2, externalRef: 'AQ-1', unitPrice: 30, marketplace: 'stubhub' }, null);
    expect(ok).toEqual({ ticketId: TIER, quantity: 2, externalRef: 'AQ-1', unitPrice: 30, marketplace: 'stubhub', buyerEmail: null });
    expect(parseOrderBody({ ticketId: TIER, quantity: 2, unitPrice: 30 }, 'AQ-9')).toMatchObject({ externalRef: 'AQ-9' });
    expect(parseOrderBody({ ticketId: TIER, quantity: 2, externalRef: 'A', unitPrice: 30 }, 'B')).toHaveProperty('error');
    expect(parseOrderBody({ ticketId: TIER, quantity: 0, externalRef: 'A', unitPrice: 30 }, null)).toHaveProperty('error');
    expect(parseOrderBody({ ticketId: TIER, quantity: 1.5, externalRef: 'A', unitPrice: 30 }, null)).toHaveProperty('error');
    expect(parseOrderBody({ ticketId: TIER, quantity: 1, externalRef: 'A' }, null)).toHaveProperty('error');
    expect(parseOrderBody({ ticketId: 'x', quantity: 1, externalRef: 'A', unitPrice: 1 }, null)).toHaveProperty('error');
    expect(parseOrderBody(null, null)).toHaveProperty('error');
  });
});

describe('shapes', () => {
  it('local date and time in the venue time zone', () => {
    expect(localDateTime('2026-11-08T02:00:00Z', 'America/New_York')).toEqual({ date: '2026-11-07', time: '21:00' });
    expect(localDateTime('2026-11-08T02:00:00Z', 'Not/AZone')).toEqual({ date: '2026-11-08', time: '02:00' });
    expect(localDateTime(null, 'UTC')).toEqual({ date: null, time: null });
  });
  it('call 1 in the desk shape', () => {
    const p = shapeEventsPage({
      generated_at: '2026-10-13T14:03:11.123Z', total: 1, limit: 200, offset: 0,
      events: [{
        event_id: EV, status: 'active', organizer: 'Bowl Presents', name: 'DJ Night', venue_name: 'Brooklyn Bowl',
        venue_address: { city: 'Brooklyn', region: 'NY' }, timezone: 'America/New_York',
        starts_at: '2026-11-08T02:00:00+00:00', doors_at: null, slug: 'dj-night',
        available: 412, total_capacity: 600, updated_at: '2026-10-13T13:58:40.5Z',
      }],
    }, '2026-10-13T00:00:00.000Z', 'https://exos.example/bridge');
    expect(p).toMatchObject({ generatedAt: '2026-10-13T14:03:11Z', updatedSince: '2026-10-13T00:00:00Z', count: 1, total: 1 });
    expect(p.events[0]).toMatchObject({
      eventId: EV, eventUid: EV, internalId: null, status: 'active', host: 'exos', name: 'DJ Night',
      venue: 'Brooklyn Bowl', city: 'Brooklyn', region: 'NY', date: '2026-11-07', time: '21:00', isAway: false,
      eventUrl: 'https://exos.example/bridge/e/dj-night',
      availability: { available: 412, totalCapacity: 600, pctAvailable: 68.7, soldOut: false, asOf: '2026-10-13T13:58:40Z' },
      updatedAt: '2026-10-13T13:58:40Z',
    });
  });
  it('call 2: one GA line per ticket type', () => {
    const t = shapeTickets({
      generated_at: '2026-10-13T14:03:11Z', event_id: EV, name: 'DJ Night', starts_at: '2026-11-08T02:00:00Z', timezone: 'America/New_York',
      tickets: [{ tier_id: TIER, name: 'General Admission', quantity: 404, max_per_order: 4, split: 'any', price: 30, net: 28.5, currency: 'USD' }],
    });
    expect(t).toMatchObject({ eventId: EV, date: '2026-11-07', asOf: '2026-10-13T14:03:11Z', count: 1, seats: 404 });
    expect(t.tickets[0]).toEqual({
      ticketId: TIER, level: '', section: 'GA', row: 'GA', seatFirst: null, seatLast: null, quantity: 404,
      maxContiguous: 4, split: 'any', priceLevel: TIER, priceLevelName: 'General Admission', price: 30, fees: 0,
      allInPrice: 30, netToOrganizer: 28.5, currency: 'USD', inventoryType: 'primary', inHandDate: '2026-11-07',
      delivery: 'mobile_transfer',
    });
  });
});

describe('orders', () => {
  const tix = [{ transfer_id: 'tr1', claim_key: 'k/1', internal_seat: 7, ticket_status: 'active' }];
  it('created is a 201 with claim links', () => {
    const r = shapeOrder({ result: 'created', order_id: ORDER, status: 'fulfilled' }, tix, 'https://exos.example/bridge');
    expect(r.status).toBe(201);
    expect(r.body).toEqual({
      orderId: ORDER, status: 'fulfilled', replayed: false,
      tickets: [{ seat: 'GA-0007', claimUrl: 'https://exos.example/bridge/claim/tr1?k=k%2F1', status: 'active' }],
    });
  });
  it('a replay is a 200', () => {
    expect(shapeOrder({ result: 'existing', order_id: ORDER, status: 'fulfilled' }, [], '').status).toBe(200);
  });
  it('a rejection is a 409, nothing taken', () => {
    const r = shapeOrder({ result: 'rejected', reason: 'sold_out', available: 3, price: 30 }, [], '');
    expect(r).toEqual({ status: 409, body: { error: 'not enough left', reason: 'sold_out', available: 3, price: 30 } });
    expect(shapeOrder({ result: 'rejected', reason: 'not_on_feed', available: 0, price: null }, [], '').status).toBe(404);
    expect(shapeOrder({ result: 'invalid', error: 'x' }, [], '').status).toBe(400);
    expect(shapeOrder({ result: 'unauthorized' }, [], '').status).toBe(401);
  });
});

describe('webhook', () => {
  it('coalesces events into one body', () => {
    const b = webhookBody([{ event_id: EV, status: 'active', available: 12, updated_at: '2026-10-13T13:58:40.5Z' }], new Date('2026-10-13T14:00:00Z'));
    expect(b).toEqual({ type: 'inventory.changed', generatedAt: '2026-10-13T14:00:00Z', events: [{ eventId: EV, status: 'active', available: 12, updatedAt: '2026-10-13T13:58:40Z' }] });
  });
  it('signs like exos-webhook-drain', async () => {
    // hex HMAC-SHA256(secret, `${ts}.${body}`), checked against Python's hmac.
    expect(await signWebhook('secret', 1700000000, '{}')).toBe('b8569b78799ff9e3cbff0fc2d63a33a2b57f3282abd07c37ae5e8e7d79a5f163');
    expect(await sha256Hex('abc')).toBe('ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad');
  });
});
