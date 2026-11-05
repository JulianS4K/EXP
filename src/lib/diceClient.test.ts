// DICE import (mig 20261106100000): the read-only GraphQL client, the
// mapping of DICE nodes to Exos rows, the consent rule and the sync engine.
// DICE's real endpoint is never called: every request goes to a fake fetch.
// Fixtures use DICE's documented field names (Ticket Holders API reference).
import { describe, expect, it } from 'vitest';
import {
  ALLOWED_OPERATIONS, DICE_ENDPOINT, DiceWriteRefused, ENTITIES, ENTITY_ORDER, EVENTS_QUERY, MAX_PAGE_SIZE,
  MAX_RETRIES, ORDERS_QUERY, RETURNS_QUERY, TICKETS_QUERY, TRANSFERS_QUERY, VIEWER_QUERY, assertQueryOnly,
  backoffMs, diceDatetime, diceErrorMessage, diceQuery, isDiceTokenShaped, operationTypes, pageVariables,
  readPages, readViewer, whereSince, type Fetch,
} from '../../supabase/functions/_shared/dice/client.ts';
import {
  fansIn, isUpcomingEvent, mapEvent, mapFan, mapNodes, mapOrder, mapReturn, mapTicket, mapTransfer, marketingConsent,
  type OrderRow, type TicketRow,
} from '../../supabase/functions/_shared/dice/map.ts';
import {
  diceImportEnabled, diceSyncBodyProblem, runKind, runSync, type SyncStore,
} from '../../supabase/functions/_shared/dice/sync.ts';
import { connectOrg, dryRunOrg, syncOrg, type DiceDb } from '../../supabase/functions/_shared/dice/run.ts';

// ---- Fakes ----------------------------------------------------------------

type Call = { url: string; init?: RequestInit; body: { query: string; variables: Record<string, unknown> } };
type Reply = { status?: number; body?: unknown; headers?: Record<string, string>; throws?: Error };

function fakeFetch(replies: Array<Reply | ((c: Call) => Reply)>): { fetch: Fetch; calls: Call[] } {
  const calls: Call[] = [];
  const fetch: Fetch = async (input, init) => {
    const call: Call = { url: input, init, body: JSON.parse(String(init?.body ?? '{}')) };
    calls.push(call);
    const next = replies.length > 1 ? replies.shift()! : replies[0];
    const r = typeof next === 'function' ? next(call) : next;
    if (r.throws) throw r.throws;
    return new Response(JSON.stringify(r.body ?? {}), { status: r.status ?? 200, headers: r.headers });
  };
  return { fetch, calls };
}
const noSleep = async () => undefined;

// A page of a viewer connection, as DICE answers it.
const conn = (name: string, nodes: unknown[], endCursor: string | null, hasNextPage: boolean, totalCount = 99): Reply => ({
  body: { data: { viewer: { [name]: { totalCount, pageInfo: { endCursor, hasNextPage }, edges: nodes.map((node) => ({ node, cursor: 'c' })) } } } },
});

// ---- Fixtures (DICE field names) -------------------------------------------

const FAN_YES = { id: 'F1', firstName: 'Ada', lastName: 'Lovelace', email: 'ADA@Example.com ', dob: '1990-01-01', phoneNumber: '+447700900001', optInPartners: true };
const FAN_NO = { id: 'F2', firstName: 'Bo', lastName: 'Diddley', email: 'bo@example.com', phoneNumber: null, optInPartners: false };
const FAN_NULL = { id: 'F3', firstName: 'Cy', lastName: null, email: 'cy@example.com', optInPartners: null };
const FAN_STR = { id: 'F4', email: 'dee@example.com', optInPartners: 'true' };

const TICKET = {
  id: 'VGlja2V0OjEyMw==', code: 'QR-123-ABC', fullPrice: 1300, commission: 100, diceCommission: 100, total: 1500,
  fees: [{ category: 'BOOKING', promoter: 0, dice: 200 }],
  holder: FAN_YES, ticketType: { id: 'TT1', name: 'Early bird' }, seat: { name: 'A12' }, claimedAt: '2026-11-01T10:00:00',
  priceTier: { id: 'PT1', name: 'Tier 1' }, address: { line1: 'never asked for' },
  fanSurveyAnswers: [{ fanSurveyQuestion: { title: 'Postcode?' }, value: 'E1' }],
  extras: [{ id: 'X1', code: 'EXTRA-1', hasSeparateAccessBarcode: true, product: { id: 'P1', name: 'Parking' } }],
};
const EVENT = {
  id: 'RXZlbnQ6NDQ=', eventIdLive: 'live-44', name: 'Warehouse Night', state: 'APPROVED',
  announceDatetime: '2026-10-01T09:00:00Z', onSaleDatetime: '2026-10-02T09:00:00Z', offSaleDatetime: '2026-12-01T22:00:00Z',
  startDatetime: '2026-12-01T22:00:00Z', endDatetime: '2026-12-02T04:00:00Z', description: 'All night', hidden: false,
  totalTicketAllocationQty: 300, currency: 'gbp', url: 'https://dice.fm/event/warehouse-night', updatedAt: '2026-11-05T12:00:00Z',
  artists: [{ name: 'Artist A' }, { name: 'Artist B' }], genreTypes: ['Electronic'], genres: ['Techno', 'House'],
  images: [{ type: 'SQUARE', url: 'https://img.dice.fm/sq.jpg' }, { type: 'LANDSCAPE', url: 'https://img.dice.fm/ls.jpg' }, { type: 'BRAND', url: 'http://insecure' }],
  ticketTypes: [{
    id: 'TT1', name: 'Early bird', description: 'First 100', totalTicketAllocationQty: 100, archived: false, faceValue: 1300,
    price: 1500, doorSalesPrice: 2000, priceTierType: 'allocation',
    priceTiers: [{ id: 'PT1', name: 'Tier 1', allocation: 50, time: null, faceValue: 1300, price: 1500, doorSalesPrice: 2000 }],
    externalSkus: ['SKU-1'], ticketPoolId: 7,
  }],
  ticketPools: [{ id: 'POOL7', name: 'GA pool', allocation: 300 }],
  venues: [{
    id: 991, name: 'Corsica Studios', type: 'club', ageLimit: '18+', displayedAddress: '4/5 Elephant Rd', streetAddress: '4/5 Elephant Rd',
    city: 'London', state: null, region: 'Greater London', country: 'United Kingdom', postalCode: 'SE17 1LB', postOfficeBoxNumber: null,
    latitude: 51.49, longitude: -0.1, timezoneName: 'Europe/London', venueSpaces: [{ id: 1, name: 'Room 1' }],
  }],
  venueSpace: { id: 1, name: 'Room 1' },
  products: [{ id: 'P1', name: 'Parking', description: 'Car park', totalAllocationQty: 20, archived: false, faceValue: 500, externalSku: 'PARK' }],
  socialLinks: [{ url: 'https://link.dice.fm/AE6xPxPd7jb', campaign: 'ig', default: true }],
  promoters: ['Night Owl Promotions'],
};
const ORDER = {
  id: 'O1', purchasedAt: '2026-11-02T20:15:00Z', quantity: 2, salesChannel: 'INTERNET', fullPrice: 2600, commission: 200,
  diceCommission: 200, total: 3000, ipCity: 'London', ipCountry: 'United Kingdom', fees: [{ category: 'BOOKING', promoter: 0, dice: 400 }],
  event: { id: 'RXZlbnQ6NDQ=' }, fan: FAN_YES, tickets: [TICKET, { ...TICKET, id: 'T2', code: 'QR-2', holder: FAN_NO }],
  returns: [{ id: 'R1', ticketId: 'T2', returnedAt: '2026-11-03T10:00:00Z', reason: 'Can\'t make it' }],
  adjustments: [{ reason: 'fee refund', processedAt: '2026-11-04T10:00:00Z', ticket: { id: 'T2' }, feesChange: [{ category: 'BOOKING', promoter: 0, dice: -200 }] }],
  promoCode: 'EARLY', promoName: 'Early birds', promoDiscount: 300, promoType: 'discount',
};

// ---- The guard -------------------------------------------------------------

describe('read only: queries, never mutations or subscriptions', () => {
  it('allows only the query operation type', () => {
    expect([...ALLOWED_OPERATIONS]).toEqual(['query']);
  });
  it('every document the client sends is a query', () => {
    for (const q of [VIEWER_QUERY, EVENTS_QUERY, TICKETS_QUERY, ORDERS_QUERY, RETURNS_QUERY, TRANSFERS_QUERY]) {
      expect(() => assertQueryOnly(q)).not.toThrow();
      expect(operationTypes(q).filter((o) => o !== 'fragment')).toEqual(['query']);
    }
  });
  it('refuses mutations and subscriptions, alone or hidden after a query', () => {
    for (const doc of [
      'mutation { cancelOrder(id: 1) { id } }',
      'mutation M($id: ID!) { refund(id: $id) }',
      'subscription { ticketSold { id } }',
      'query A { viewer { id } } mutation B { x }',
      '{ viewer { id } }\nsubscription S { y }',
      '# a comment\nmutation{x}',
      '﻿  mutation { x }',
    ]) {
      expect(() => assertQueryOnly(doc), doc).toThrow(DiceWriteRefused);
      expect(() => assertQueryOnly(doc), doc).toThrow(/not allowed|unsupported/);
    }
  });
  it('is not fooled by keywords in comments, strings or field names', () => {
    expect(() => assertQueryOnly('# mutation { x }\nquery { viewer { id } }')).not.toThrow();
    expect(() => assertQueryOnly('{ node(id: "mutation { x }") { id } }')).not.toThrow();
    expect(() => assertQueryOnly('{ node(id: """\nsubscription { y }\n""") { id } }')).not.toThrow();
    expect(() => assertQueryOnly('query { viewer { mutation subscription } }')).not.toThrow();
    expect(operationTypes('{ a }')).toEqual(['query']);
  });
  it('refuses what it cannot read', () => {
    for (const doc of ['', 'query { a', 'query { a } }', 'type Query { a: Int }', 'schema { query: Q }', 'extend type X { y: Int }',
      'Mutation { x }', '{ node(id: "unterminated) { id } }', 'fragment F on Event { id }']) {
      expect(() => assertQueryOnly(doc), doc).toThrow(DiceWriteRefused);
    }
  });
  it('throws before anything is sent', async () => {
    const { fetch, calls } = fakeFetch([{ body: { data: {} } }]);
    await expect(diceQuery({ fetch, sleep: noSleep }, 'tok', 'mutation { x }')).rejects.toThrow(DiceWriteRefused);
    await expect(diceQuery({ fetch, sleep: noSleep }, 'tok', 'subscription { x }')).rejects.toThrow(DiceWriteRefused);
    expect(calls).toHaveLength(0);
  });
});

// ---- Requests ----------------------------------------------------------------

describe('requests', () => {
  it('POSTs the query to the one fixed endpoint with the token in the header only', async () => {
    const { fetch, calls } = fakeFetch([{ body: { data: { viewer: { id: '4', name: 'Night Owl' } } } }]);
    const r = await readViewer({ fetch, sleep: noSleep }, 'tok_dice_0123456789abcdef');
    expect(r.ok).toBe(true);
    expect(r.data).toEqual({ id: '4', name: 'Night Owl' });
    expect(calls).toHaveLength(1);
    expect(calls[0].url).toBe(DICE_ENDPOINT);
    expect(DICE_ENDPOINT).toBe('https://partners-endpoint.dice.fm/graphql');
    expect(calls[0].init?.method).toBe('POST');
    expect(calls[0].init?.redirect).toBe('error');
    expect((calls[0].init?.headers as Record<string, string>).Authorization).toBe('Bearer tok_dice_0123456789abcdef');
    expect(calls[0].url).not.toContain('tok_dice');
    expect(calls[0].body.query).toBe(VIEWER_QUERY);
    expect(calls[0].init?.signal).toBeInstanceOf(AbortSignal);
  });
  it('builds page variables: first at most 50, after and where only when set', () => {
    expect(pageVariables(500, null, null)).toEqual({ first: MAX_PAGE_SIZE });
    expect(pageVariables(0, null, null)).toEqual({ first: 50 });
    expect(pageVariables(10, 'cur', { updatedAt: { gte: 'x' } })).toEqual({ first: 10, after: 'cur', where: { updatedAt: { gte: 'x' } } });
  });
  it('filters incremental passes by the documented date fields, minus five minutes', () => {
    expect(ENTITIES.events.since).toBe('updatedAt');
    expect(ENTITIES.orders.since).toBe('purchasedAt');
    expect(ENTITIES.returns.since).toBe('returnedAt');
    expect(ENTITIES.transfers.since).toBe('transferredAt');
    expect(whereSince('orders', '2026-11-05T10:00:00.000Z')).toEqual({ purchasedAt: { gte: '2026-11-05T09:55:00Z' } });
    expect(whereSince('events', null)).toBeNull();
    expect(whereSince('tickets', '2026-11-05T10:00:00Z')).toBeNull(); // TicketWhereInput has no date filter
    expect(diceDatetime(new Date('2026-01-02T03:04:05.678Z'))).toBe('2026-01-02T03:04:05Z');
  });
  it('asks for the documented connections and fields', () => {
    expect(EVENTS_QUERY).toMatch(/viewer \{ events\(first: \$first, after: \$after, where: \$where\)/);
    expect(TICKETS_QUERY).toMatch(/tickets\(first: \$first/);
    expect(ORDERS_QUERY).toMatch(/orders\(first: \$first/);
    expect(RETURNS_QUERY).toMatch(/returns\(first: \$first/);
    expect(TRANSFERS_QUERY).toMatch(/ticketTransfers\(first: \$first/);
    for (const f of ['ticketTypes', 'venues', 'artists', 'genres', 'priceTiers', 'ticketPools', 'totalTicketAllocationQty']) expect(EVENTS_QUERY).toContain(f);
    for (const f of ['holder', 'ticketType', 'claimedAt', 'fanSurveyAnswers', 'optInPartners', 'code']) expect(TICKETS_QUERY).toContain(f);
    for (const f of ['fan', 'tickets', 'purchasedAt', 'total', 'ipCountry', 'ipCity', 'promoCode', 'adjustments']) expect(ORDERS_QUERY).toContain(f);
    for (const f of ['totalCount', 'endCursor', 'hasNextPage']) expect(ORDERS_QUERY).toContain(f);
    // Never asked for: birthdays and postal addresses.
    for (const q of [TICKETS_QUERY, ORDERS_QUERY, TRANSFERS_QUERY]) {
      expect(q).not.toMatch(/\bdob\b/);
      expect(q).not.toMatch(/\baddress\b/);
    }
  });
  it('keeps GraphQL errors that came with data as warnings', async () => {
    const { fetch } = fakeFetch([{ body: { data: { viewer: { id: 1, name: null } }, errors: [{ message: 'eventIdLive: restricted' }] } }]);
    const r = await readViewer({ fetch, sleep: noSleep }, 'tok');
    expect(r.ok).toBe(true);
    expect(r.warnings).toEqual(['eventIdLive: restricted']);
  });
  it('treats a GraphQL auth error without data as a refused token', async () => {
    const { fetch } = fakeFetch([{ body: { data: null, errors: [{ message: 'Unauthorized' }] } }]);
    const r = await readViewer({ fetch, sleep: noSleep }, 'tok');
    expect(r).toMatchObject({ ok: false, status: 401, error: 'HTTP_401' });
    expect(diceErrorMessage(r)).toMatch(/Generate a new API token in MIO/);
  });
  it('checks the token shape', () => {
    expect(isDiceTokenShaped('tok_dice_0123456789abcdef')).toBe(true);
    expect(isDiceTokenShaped('eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.abc-_=')).toBe(true);
    expect(isDiceTokenShaped('short')).toBe(false);
    expect(isDiceTokenShaped('has spaces in it 0123456')).toBe(false);
    expect(isDiceTokenShaped(42)).toBe(false);
  });
});

// ---- Retry and backoff ------------------------------------------------------------

describe('retry and backoff', () => {
  it('retries a 429, honouring Retry-After', async () => {
    const waits: number[] = [];
    const { fetch, calls } = fakeFetch([
      { status: 429, body: { errors: [] }, headers: { 'retry-after': '3' } },
      { body: { data: { viewer: { id: '4' } } } },
    ]);
    const r = await readViewer({ fetch, sleep: async (ms) => { waits.push(ms); } }, 'tok');
    expect(r.ok).toBe(true);
    expect(r.attempts).toBe(2);
    expect(calls).toHaveLength(2);
    expect(waits).toEqual([3000]);
  });
  it('retries 5xx and network errors with growing waits, then gives up', async () => {
    const waits: number[] = [];
    const { fetch, calls } = fakeFetch([{ status: 503, body: {} }]);
    const r = await diceQuery({ fetch, sleep: async (ms) => { waits.push(ms); }, random: () => 1 }, 'tok', VIEWER_QUERY);
    expect(r).toMatchObject({ ok: false, status: 503, error: 'HTTP_503', attempts: MAX_RETRIES + 1 });
    expect(calls).toHaveLength(MAX_RETRIES + 1);
    expect(waits).toEqual([500, 1000, 2000, 4000]);
    const net = fakeFetch([{ throws: new TypeError('connection reset') }, { body: { data: { viewer: { id: 'x' } } } }]);
    const r2 = await readViewer({ fetch: net.fetch, sleep: noSleep }, 'tok');
    expect(r2.ok).toBe(true);
    expect(net.calls).toHaveLength(2);
  });
  it('does not retry a 400 or a 401', async () => {
    for (const status of [400, 401, 403]) {
      const { fetch, calls } = fakeFetch([{ status, body: {} }]);
      const r = await diceQuery({ fetch, sleep: noSleep }, 'tok', VIEWER_QUERY);
      expect(r.ok).toBe(false);
      expect(calls).toHaveLength(1);
    }
  });
  it('a timeout is a retryable failure', async () => {
    const abort = Object.assign(new Error('aborted'), { name: 'AbortError' });
    const { fetch, calls } = fakeFetch([{ throws: abort }]);
    const r = await diceQuery({ fetch, sleep: noSleep, maxRetries: 1 }, 'tok', VIEWER_QUERY);
    expect(r).toMatchObject({ ok: false, error: 'TIMEOUT', attempts: 2 });
    expect(calls).toHaveLength(2);
    expect(diceErrorMessage(r)).toMatch(/too long/);
  });
  it('backoff: exponential with jitter, capped, Retry-After as seconds or a date', () => {
    expect(backoffMs(1, null, () => 0)).toBe(250);
    expect(backoffMs(1, null, () => 1)).toBe(500);
    expect(backoffMs(3, null, () => 1)).toBe(2000);
    expect(backoffMs(20, null, () => 1)).toBe(30_000);
    expect(backoffMs(1, '120', () => 0)).toBe(30_000);
    expect(backoffMs(1, new Date(Date.now() + 2000).toUTCString(), () => 0)).toBeLessThanOrEqual(2000);
  });
});

// ---- Pagination --------------------------------------------------------------------

describe('pagination', () => {
  it('follows endCursor until hasNextPage is false', async () => {
    const { fetch, calls } = fakeFetch([
      conn('events', [EVENT], 'c1', true),
      conn('events', [{ ...EVENT, id: 'E2' }], 'c2', true),
      conn('events', [{ ...EVENT, id: 'E3' }], 'c3', false),
    ]);
    const seen: string[] = [];
    const r = await readPages({ fetch, sleep: noSleep }, 'tok', 'events', { after: null, since: null }, { maxPages: 10, maxRows: 1000 },
      (p) => { seen.push(...p.nodes.map((n) => String(n.id))); });
    expect(r).toMatchObject({ done: true, pages: 3, rows: 3, after: null });
    expect(seen).toEqual(['RXZlbnQ6NDQ=', 'E2', 'E3']);
    expect(calls.map((c) => c.body.variables.after ?? null)).toEqual([null, 'c1', 'c2']);
    expect(calls.every((c) => c.body.variables.first === 50)).toBe(true);
  });
  it('resumes from a saved cursor with the incremental filter', async () => {
    const { fetch, calls } = fakeFetch([conn('orders', [], null, false)]);
    await readPages({ fetch, sleep: noSleep }, 'tok', 'orders', { after: 'saved', since: '2026-11-05T10:00:00Z' }, { maxPages: 1, maxRows: 50 }, () => {});
    expect(calls[0].body.variables).toEqual({ first: 50, after: 'saved', where: { purchasedAt: { gte: '2026-11-05T09:55:00Z' } } });
  });
  it('stops at the page cap, the row cap and the deadline, keeping the cursor', async () => {
    // DICE answers at most `first` rows.
    const page = (i: number, first: number) => conn('tickets', Array.from({ length: first }, (_, k) => ({ id: `T${i}-${k}` })), `c${i}`, true);
    let n = 0;
    const many = fakeFetch([(c) => page(++n, Number(c.body.variables.first))]);
    const byPages = await readPages({ fetch: many.fetch, sleep: noSleep }, 'tok', 'tickets', { after: null, since: null }, { maxPages: 2, maxRows: 10_000 }, () => {});
    expect(byPages).toMatchObject({ done: false, pages: 2, capped: 'pages', after: 'c2' });
    n = 0;
    const byRows = await readPages({ fetch: many.fetch, sleep: noSleep }, 'tok', 'tickets', { after: null, since: null }, { maxPages: 99, maxRows: 120 }, () => {});
    expect(byRows).toMatchObject({ done: false, capped: 'rows', rows: 120 });
    expect(many.calls.at(-1)!.body.variables.first).toBe(20); // never asks for more rows than are left
    let t = 0;
    const byTime = await readPages({ fetch: many.fetch, sleep: noSleep }, 'tok', 'tickets', { after: 'x', since: null },
      { maxPages: 99, maxRows: 10_000, deadline: 2, now: () => t++ }, () => {});
    expect(byTime).toMatchObject({ done: false, capped: 'time', pages: 2 });
  });
  it('stops when DICE says there is more but repeats the cursor', async () => {
    const { fetch, calls } = fakeFetch([conn('returns', [{ id: 'R1' }], 'same', true)]);
    const r = await readPages({ fetch, sleep: noSleep }, 'tok', 'returns', { after: 'same', since: null }, { maxPages: 10, maxRows: 100 }, () => {});
    expect(r.error?.error).toBe('BAD_CURSOR');
    expect(calls).toHaveLength(1);
  });
  it('reports an HTTP failure without throwing', async () => {
    const { fetch } = fakeFetch([{ status: 401, body: {} }]);
    const r = await readPages({ fetch, sleep: noSleep }, 'tok', 'events', { after: null, since: null }, { maxPages: 1, maxRows: 50 }, () => {});
    expect(r).toMatchObject({ done: false, pages: 0, error: { status: 401, error: 'HTTP_401' } });
  });
});

// ---- Mapping -------------------------------------------------------------------------

describe('mapping DICE nodes to Exos rows', () => {
  it('maps an event with every field asked for', () => {
    const e = mapEvent(EVENT)!;
    expect(e).toMatchObject({
      dice_id: 'RXZlbnQ6NDQ=', live_id: 'live-44', name: 'Warehouse Night', state: 'APPROVED',
      starts_at: '2026-12-01T22:00:00.000Z', ends_at: '2026-12-02T04:00:00.000Z', on_sale_at: '2026-10-02T09:00:00.000Z',
      off_sale_at: '2026-12-01T22:00:00.000Z', announce_at: '2026-10-01T09:00:00.000Z', description: 'All night', hidden: false,
      allocation: 300, currency: 'GBP', url: 'https://dice.fm/event/warehouse-night', updated_at: '2026-11-05T12:00:00.000Z',
      artists: ['Artist A', 'Artist B'], genres: ['Techno', 'House'], genre_types: ['Electronic'],
      image_url: 'https://img.dice.fm/ls.jpg', promoters: ['Night Owl Promotions'],
      venue_space: { dice_id: '1', name: 'Room 1' },
    });
    expect(e.images).toHaveLength(2); // the http:// one is dropped
    expect(e.ticket_types[0]).toEqual({
      dice_id: 'TT1', name: 'Early bird', description: 'First 100', allocation: 100, archived: false, face_value_cents: 1300,
      price_cents: 1500, door_price_cents: 2000, price_tier_type: 'allocation',
      price_tiers: [{ dice_id: 'PT1', name: 'Tier 1', allocation: 50, time: null, face_value_cents: 1300, price_cents: 1500, door_price_cents: 2000 }],
      external_skus: ['SKU-1'], ticket_pool_id: '7',
    });
    expect(e.ticket_pools).toEqual([{ dice_id: 'POOL7', name: 'GA pool', allocation: 300 }]);
    expect(e.venue).toMatchObject({
      dice_id: '991', name: 'Corsica Studios', type: 'club', age_limit: '18+', street: '4/5 Elephant Rd', city: 'London',
      region: 'Greater London', country: 'United Kingdom', postal: 'SE17 1LB', latitude: 51.49, longitude: -0.1,
      timezone: 'Europe/London', spaces: [{ dice_id: '1', name: 'Room 1' }],
    });
    expect(e.products[0]).toEqual({ dice_id: 'P1', name: 'Parking', description: 'Car park', allocation: 20, archived: false, face_value_cents: 500, external_sku: 'PARK' });
    expect(e.social_links).toEqual([{ url: 'https://link.dice.fm/AE6xPxPd7jb', campaign: 'ig', default: true }]);
  });
  it('maps a ticket: code, holder, type, money in cents, survey answers, extras', () => {
    const t = mapTicket(TICKET)!;
    expect(t).toEqual({
      dice_id: 'VGlja2V0OjEyMw==', code: 'QR-123-ABC',
      holder: { dice_id: 'F1', email: 'ada@example.com', first_name: 'Ada', last_name: 'Lovelace', phone: '+447700900001', opt_in_partners: true },
      ticket_type_id: 'TT1', ticket_type_name: 'Early bird', claimed_at: '2026-11-01T10:00:00.000Z',
      full_price_cents: 1300, commission_cents: 100, dice_commission_cents: 100, total_cents: 1500,
      fees: [{ category: 'BOOKING', promoter_cents: 0, dice_cents: 200 }], seat: 'A12', price_tier: { dice_id: 'PT1', name: 'Tier 1' },
      survey_answers: [{ question: 'Postcode?', value: 'E1' }],
      extras: [{ dice_id: 'X1', code: 'EXTRA-1', separate_barcode: true, product: 'Parking' }],
      dice_event_id: null,
    });
    expect(JSON.stringify(t)).not.toContain('never asked for'); // no address, no birthday
    expect(JSON.stringify(t)).not.toContain('1990');
  });
  it('maps an order with its event, buyer, tickets, returns, adjustments and promo', () => {
    const o = mapOrder(ORDER)!;
    expect(o).toMatchObject({
      dice_id: 'O1', purchased_at: '2026-11-02T20:15:00.000Z', quantity: 2, sales_channel: 'INTERNET', full_price_cents: 2600,
      commission_cents: 200, dice_commission_cents: 200, total_cents: 3000, ip_city: 'London', ip_country: 'United Kingdom',
      dice_event_id: 'RXZlbnQ6NDQ=', promo_code: 'EARLY', promo_name: 'Early birds', promo_discount_cents: 300, promo_type: 'discount',
    });
    expect(o.fan?.email).toBe('ada@example.com');
    expect(o.tickets.map((t) => [t.dice_id, t.dice_event_id])).toEqual([['VGlja2V0OjEyMw==', 'RXZlbnQ6NDQ='], ['T2', 'RXZlbnQ6NDQ=']]);
    expect(o.returns).toEqual([{ dice_id: 'R1', ticket_id: 'T2', order_id: 'O1', returned_at: '2026-11-03T10:00:00.000Z', reason: 'Can\'t make it' }]);
    expect(o.adjustments[0]).toEqual({ reason: 'fee refund', processed_at: '2026-11-04T10:00:00.000Z', ticket_id: 'T2', fees_change: [{ category: 'BOOKING', promoter_cents: 0, dice_cents: -200 }] });
  });
  it('maps returns and transfers', () => {
    expect(mapReturn({ id: 'R9', ticket: { id: 'T9' }, order: { id: 'O9' }, returnedAt: '2026-11-03T10:00:00', reason: 'x' }))
      .toEqual({ dice_id: 'R9', ticket_id: 'T9', order_id: 'O9', returned_at: '2026-11-03T10:00:00.000Z', reason: 'x' });
    const tr = mapTransfer({ id: 'X1', transferredAt: '2026-11-04T00:00:00Z', tickets: [TICKET], orders: [{ id: 'O1' }] })!;
    expect(tr.tickets[0].holder?.email).toBe('ada@example.com');
    expect(tr.order_ids).toEqual(['O1']);
  });
  it('drops what is the wrong type instead of failing the page', () => {
    expect(mapTicket({ code: 'no id' })).toBeNull();
    expect(mapEvent(null)).toBeNull();
    const t = mapTicket({ id: 5, code: 12345, fullPrice: '13.00', total: 1.5, holder: { email: 'not-an-email' }, ticketType: 'x' })!;
    expect(t).toMatchObject({ dice_id: '5', code: '12345', full_price_cents: null, total_cents: null, ticket_type_id: null });
    expect(t.holder?.email).toBeNull();
    expect(mapEvent({ id: 'E', state: 'WHATEVER', currency: 'pounds', url: 'javascript:alert(1)' })).toMatchObject({ state: null, currency: null, url: null });
    expect(mapNodes('returns', [{ id: 'R1', ticketId: 'T1' }, 'junk', null])).toHaveLength(1);
  });
  it('decides which DICE events become Exos events', () => {
    const now = new Date('2026-11-05T12:00:00Z');
    expect(isUpcomingEvent({ state: 'APPROVED', starts_at: '2026-12-01T22:00:00Z', ends_at: null }, now)).toBe(true);
    expect(isUpcomingEvent({ state: 'APPROVED', starts_at: '2026-11-04T20:00:00Z', ends_at: '2026-11-05T02:00:00Z' }, now)).toBe(true); // within a day
    expect(isUpcomingEvent({ state: 'APPROVED', starts_at: '2026-10-01T20:00:00Z', ends_at: null }, now)).toBe(false);
    expect(isUpcomingEvent({ state: 'CANCELLED', starts_at: '2026-12-01T22:00:00Z', ends_at: null }, now)).toBe(false);
    expect(isUpcomingEvent({ state: 'ARCHIVED', starts_at: '2026-12-01T22:00:00Z', ends_at: null }, now)).toBe(false);
    expect(isUpcomingEvent({ state: 'DRAFT', starts_at: null, ends_at: null }, now)).toBe(true);
  });
});

// ---- The consent rule ----------------------------------------------------------------

describe('marketing consent only when optInPartners is true', () => {
  it('is true for the boolean true and nothing else', () => {
    expect(marketingConsent(mapFan(FAN_YES))).toBe(true);
    expect(marketingConsent(mapFan(FAN_NO))).toBe(false);
    expect(marketingConsent(mapFan(FAN_NULL))).toBe(false);
    expect(marketingConsent(mapFan(FAN_STR))).toBe(false);
    expect(marketingConsent(mapFan({ id: 'F5', email: 'e@x.com' }))).toBe(false);
    expect(marketingConsent(mapFan({ id: 'F6', email: 'f@x.com', optInPartners: 1 }))).toBe(false);
    expect(marketingConsent(null)).toBe(false);
    expect(marketingConsent({ opt_in_partners: 'true' })).toBe(false);
  });
  it('hands the SQL the exact DICE value', () => {
    expect(mapFan(FAN_YES)!.opt_in_partners).toBe(true);
    expect(mapFan(FAN_NO)!.opt_in_partners).toBe(false);
    expect(mapFan(FAN_NULL)!.opt_in_partners).toBeNull();
    expect(mapFan(FAN_STR)!.opt_in_partners).toBeNull();
  });
  it('a dry run counts consent only for opted-in fans', async () => {
    const tickets = [TICKET, { ...TICKET, id: 'T2', holder: FAN_NO }, { ...TICKET, id: 'T3', holder: FAN_NULL }, { ...TICKET, id: 'T4', holder: FAN_STR }];
    const { fetch } = fakeFetch([(c) => {
      const name = c.body.query.match(/viewer \{ (\w+)\(/)![1];
      return conn(name, name === 'tickets' ? tickets : name === 'events' ? [EVENT] : [], null, false, 4);
    }]);
    const fixedNow = new Date('2026-11-05T12:00:00Z').getTime();
    const r = await runSync({ fetch, sleep: noSleep }, 'tok', {}, null, { maxPagesPerEntity: 2, maxRowsPerRun: 500, deadline: fixedNow + 10_000 },
      () => fixedNow);
    expect(r.dry_run).toBe(true);
    expect(r.preview).toMatchObject({ events_upcoming: 1, ticket_types: 1, tickets: 4, fans: 4, fans_marketing_consent: 1 });
    const fans = fansIn('tickets', mapNodes('tickets', tickets));
    expect(fans.filter(marketingConsent).map((f) => f.email)).toEqual(['ada@example.com']);
  });
});

// ---- The sync engine ----------------------------------------------------------------

describe('a sync run', () => {
  const answering = (pages: Record<string, unknown[][]>) => {
    const left = Object.fromEntries(Object.entries(pages).map(([k, v]) => [k, [...v]]));
    return fakeFetch([(c) => {
      const name = c.body.query.match(/viewer \{ (\w+)\(/)![1];
      const queue = left[name] ?? [];
      const nodes = queue.shift() ?? [];
      return conn(name, nodes, queue.length ? `${name}-${queue.length}` : null, queue.length > 0, 10);
    }]);
  };
  const recorder = () => {
    const writes: Array<{ entity: string; rows: number; after: string | null; done: boolean }> = [];
    const store: SyncStore = {
      async apply(entity, rows, page) {
        writes.push({ entity, rows: rows.length, after: page.after, done: page.done });
        return { read: rows.length };
      },
    };
    return { writes, store };
  };

  it('a full first run reads events, then tickets, orders, returns and transfers, writing each page with its cursor', async () => {
    const { fetch } = answering({ events: [[EVENT], [{ ...EVENT, id: 'E2' }]], tickets: [[TICKET]], orders: [[ORDER]], returns: [[]], ticketTransfers: [[]] });
    const { writes, store } = recorder();
    const r = await runSync({ fetch, sleep: noSleep }, 'tok', {}, store, { maxPagesPerEntity: 10, maxRowsPerRun: 1000, deadline: Date.now() + 10_000 });
    expect(r).toMatchObject({ status: 'ok', kind: 'full', dry_run: false });
    expect(writes).toEqual([
      { entity: 'events', rows: 1, after: 'events-1', done: false },
      { entity: 'events', rows: 1, after: null, done: true },
      { entity: 'tickets', rows: 1, after: null, done: true },
      { entity: 'orders', rows: 1, after: null, done: true },
      { entity: 'returns', rows: 0, after: null, done: true },
      { entity: 'transfers', rows: 0, after: null, done: true },
    ]);
    expect(ENTITY_ORDER).toEqual(['events', 'tickets', 'orders', 'returns', 'transfers']);
  });
  it('an incremental run skips the tickets connection and filters by date', async () => {
    const since = '2026-11-05T10:00:00Z';
    const cursors = Object.fromEntries(ENTITY_ORDER.map((e) => [e, { since, after: null, pass_started_at: null }]));
    expect(runKind(cursors)).toBe('incremental');
    const { fetch, calls } = answering({});
    const { writes, store } = recorder();
    const r = await runSync({ fetch, sleep: noSleep }, 'tok', cursors, store, { maxPagesPerEntity: 10, maxRowsPerRun: 1000, deadline: Date.now() + 10_000 });
    expect(r.entities.tickets?.skipped).toMatch(/orders and transfers/);
    expect(writes.map((w) => w.entity)).toEqual(['events', 'orders', 'returns', 'transfers']);
    expect(calls.map((c) => Object.keys((c.body.variables.where ?? {}) as object)[0])).toEqual(['updatedAt', 'purchasedAt', 'returnedAt', 'transferredAt']);
  });
  it('stops at a capped entity, waits for events, and never writes on a dry run', async () => {
    const { fetch } = answering({ events: [[EVENT], [EVENT], [EVENT]] });
    const { writes, store } = recorder();
    const r = await runSync({ fetch, sleep: noSleep }, 'tok', {}, store, { maxPagesPerEntity: 2, maxRowsPerRun: 1000, deadline: Date.now() + 10_000 });
    expect(r.status).toBe('partial');
    expect(r.entities.events).toMatchObject({ done: false, capped: 'pages' });
    expect(writes.every((w) => w.entity === 'events')).toBe(true);
    const r2 = await runSync({ fetch, sleep: noSleep }, 'tok', { events: { since: null, after: 'x', pass_started_at: '2026-11-05T00:00:00Z' } }, null,
      { maxPagesPerEntity: 1, maxRowsPerRun: 1000, deadline: Date.now() + 10_000 });
    expect(r2.dry_run).toBe(true);
    expect(r2.preview).toBeDefined();
  });
  it('an error from DICE ends the run as an error', async () => {
    const { fetch } = fakeFetch([{ status: 401, body: {} }]);
    const { writes, store } = recorder();
    const r = await runSync({ fetch, sleep: noSleep }, 'tok', {}, store, { maxPagesPerEntity: 10, maxRowsPerRun: 1000, deadline: Date.now() + 10_000 });
    expect(r).toMatchObject({ status: 'error', error: { entity: 'events', status: 401 } });
    expect(writes).toHaveLength(0);
  });
  it('maps orders for the store with the event id on each ticket', async () => {
    const { fetch } = answering({ events: [[]], tickets: [[]], orders: [[ORDER]], returns: [[]], ticketTransfers: [[]] });
    const seen: OrderRow[] = [];
    const store: SyncStore = { async apply(entity, rows) { if (entity === 'orders') seen.push(...(rows as OrderRow[])); return {}; } };
    await runSync({ fetch, sleep: noSleep }, 'tok', {}, store, { maxPagesPerEntity: 10, maxRowsPerRun: 1000, deadline: Date.now() + 10_000 });
    expect(seen[0].tickets.every((t: TicketRow) => t.dice_event_id === 'RXZlbnQ6NDQ=')).toBe(true);
  });
});

describe('the switch and the API body', () => {
  it('is off unless EXOS_DICE_IMPORT is on', () => {
    expect(diceImportEnabled(() => undefined)).toBe(false);
    expect(diceImportEnabled(() => 'off')).toBe(false);
    expect(diceImportEnabled(() => 'true')).toBe(false);
    expect(diceImportEnabled(() => ' ON ')).toBe(true);
  });
  it('POST /v1/dice-import/sync takes dry_run only', () => {
    expect(diceSyncBodyProblem({})).toBeNull();
    expect(diceSyncBodyProblem({ dry_run: true })).toBeNull();
    expect(diceSyncBodyProblem({ dry_run: 'yes' })).toMatch(/true or false/);
    expect(diceSyncBodyProblem({ token: 'x' })).toMatch(/unknown field token/);
  });
});

// ---- Role and limit first, DICE second (_shared/dice/run.ts) ---------------

describe('the database gates every DICE request', () => {
  type Log = string[];
  const fakeDb = (answers: Record<string, { data?: unknown; error?: { code: string; message?: string } }>, log: Log): DiceDb => ({
    async rpc(fn) {
      log.push(`rpc:${fn}`);
      const a = answers[fn] ?? { data: null };
      return { data: a.data ?? null, error: a.error ?? null };
    },
  });
  const spyFetch = (log: Log) => {
    const { fetch, calls } = fakeFetch([(c) => {
      log.push('fetch');
      const name = c.body.query.match(/viewer \{ (\w+)\(/)?.[1];
      return name ? conn(name, [], null, false, 0) : { body: { data: { viewer: { id: 'v1', name: 'Night Owl' } } } };
    }]);
    return { fetch, calls };
  };
  const TOKEN = 'tok_dice_0123456789abcdef';
  const refusals = [
    { code: '42501', status: 403, reason: 'forbidden' },
    { code: '54000', status: 429, reason: 'rate_limited' },
    { code: '55000', status: 409, reason: 'busy' },
    { code: '22023', status: 409, reason: 'not_connected' },
  ];

  it('connect: a refused role or limit never reaches DICE', async () => {
    for (const r of refusals.slice(0, 2)) {
      const log: Log = [];
      const { fetch, calls } = spyFetch(log);
      const out = await connectOrg(fakeDb({ exos_dice_connect_begin: { error: { code: r.code } } }, log), { fetch, sleep: noSleep }, 'org', 'user', TOKEN);
      expect(out).toMatchObject({ ok: false, status: r.status, reason: r.reason });
      expect(calls).toHaveLength(0);
      expect(log).toEqual(['rpc:exos_dice_connect_begin']);
    }
  });
  it('connect: a token of the wrong shape reaches neither the database nor DICE', async () => {
    const log: Log = [];
    const { fetch, calls } = spyFetch(log);
    const out = await connectOrg(fakeDb({}, log), { fetch, sleep: noSleep }, 'org', 'user', 'short');
    expect(out).toMatchObject({ ok: false, status: 400, reason: 'bad_token' });
    expect(calls).toHaveLength(0);
    expect(log).toEqual([]);
  });
  it('connect: allowed, the gate comes first, then DICE, then the store', async () => {
    const log: Log = [];
    const { fetch, calls } = spyFetch(log);
    const out = await connectOrg(fakeDb({ exos_dice_connect: { data: { connected: true, account_name: 'Night Owl' } } }, log),
      { fetch, sleep: noSleep }, 'org', 'user', TOKEN);
    expect(out).toMatchObject({ ok: true, status: 200, connected: true, account_name: 'Night Owl' });
    expect(log).toEqual(['rpc:exos_dice_connect_begin', 'fetch', 'rpc:exos_dice_connect']);
    expect(calls[0].body.query).toBe(VIEWER_QUERY);
  });
  it('sync: a refused claim never reaches DICE', async () => {
    for (const r of refusals) {
      const log: Log = [];
      const { fetch, calls } = spyFetch(log);
      const out = await syncOrg(fakeDb({ exos_dice_sync_claim: { error: { code: r.code } } }, log), { fetch, sleep: noSleep }, 'org', 'user', 'api');
      expect(out).toMatchObject({ ok: false, status: r.status, reason: r.reason });
      expect(calls).toHaveLength(0);
    }
  });
  it('dry run: a refused reservation never reaches DICE', async () => {
    for (const r of refusals) {
      const log: Log = [];
      const { fetch, calls } = spyFetch(log);
      const out = await dryRunOrg(fakeDb({ exos_dice_dry_run_begin: { error: { code: r.code } } }, log), { fetch, sleep: noSleep }, 'org', 'user', 'dashboard');
      expect(out).toMatchObject({ ok: false, status: r.status, reason: r.reason });
      expect(calls).toHaveLength(0);
      expect(log).toEqual(['rpc:exos_dice_dry_run_begin']);
    }
  });
  it('dry run: reserved before the first read, reported on that row after the last', async () => {
    const log: Log = [];
    const { fetch } = spyFetch(log);
    const out = await dryRunOrg(fakeDb({
      exos_dice_dry_run_begin: { data: [{ run_id: 'run-1', token: TOKEN, cursors: {} }] },
      exos_dice_dry_run_finish: { data: { ok: true } },
    }, log), { fetch, sleep: noSleep }, 'org', 'user', 'dashboard');
    expect(out).toMatchObject({ ok: true, dry_run: true, run_id: 'run-1' });
    expect(log[0]).toBe('rpc:exos_dice_dry_run_begin');
    expect(log.at(-1)).toBe('rpc:exos_dice_dry_run_finish');
    expect(log.filter((x) => x === 'fetch').length).toBeGreaterThan(0);
    expect(log.slice(1, -1).every((x) => x === 'fetch')).toBe(true);
  });
  it('sync: claimed first, then DICE, then finish', async () => {
    const log: Log = [];
    const { fetch } = spyFetch(log);
    const out = await syncOrg(fakeDb({
      exos_dice_sync_claim: { data: [{ org_id: 'org', token: TOKEN, cursors: {}, lease_id: 'l1', run_id: 'r1', kind: 'full' }] },
      exos_dice_apply: { data: { read: 0 } },
    }, log), { fetch, sleep: noSleep }, 'org', 'user', 'dashboard');
    expect(out).toMatchObject({ ok: true, run_id: 'r1' });
    expect(log[0]).toBe('rpc:exos_dice_sync_claim');
    expect(log[1]).toBe('fetch');
    expect(log.at(-1)).toBe('rpc:exos_dice_sync_finish');
  });
});
