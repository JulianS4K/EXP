import { describe, expect, it, vi } from 'vitest';
import {
  GAMETIME_CSV_COLUMNS,
  GAMETIME_ENDPOINTS,
  GametimeClient,
  GametimeWriteRefusedError,
  GametimeWriter,
  gametimeChannel,
  gametimeDate,
  gametimeInventoryCsv,
  normalizeGametimeSale,
  parseGametimeSaleNotification,
  planGametimeListings,
  transferConfirmationForm,
  verifyGametimeWebhook,
  type GametimeAllocation,
  type GametimeWriteAuthorization,
} from '.';
import { exosListingId, planDelist, syncListings } from '..';

const ALLOC = '0f8fad5b-d9cb-469f-a165-70867728950e';
const AUTH: GametimeWriteAuthorization = {
  approvedBy: 'operator', approvedAt: '2026-09-27T00:00:00Z', reference: 'test', endpoints: ['editListing', 'confirmPurchase', 'uploadInventory'],
};

const base: GametimeAllocation = {
  id: ALLOC,
  requested_qty: 10,
  unit_price: 45,
  internal_seats: '{[1,11)}',
  tier: { name: 'GA', price: 40 },
  event: {
    name: 'Late Night Jazz, Vol. 2', starts_at: '2026-11-07T02:00:00Z', occurs_at_local: '2026-11-06T21:00:00-05:00',
    venue_name: 'Blue Room', venue_address: { city: 'Brooklyn' }, currency: 'USD', purchase_limits: { maxPerOrder: 4 },
  },
};

describe('endpoints', () => {
  it('reads only GET /purchases; the inventory file is its own kind', () => {
    const reads = Object.entries(GAMETIME_ENDPOINTS).filter(([, e]) => e.access === 'read').map(([k]) => k);
    expect(reads).toEqual(['listPurchases']);
    expect(GAMETIME_ENDPOINTS.uploadInventory.access).toBe('upload');
  });
});

describe('client', () => {
  it('sends the key as ?source= and never puts it in errors', async () => {
    const f = vi.fn(async (url: string) => {
      if (url.includes('order_number')) return new Response(JSON.stringify({ results: [{ id: 'GT1', status: 'unconfirmed' }] }));
      return new Response('nope', { status: 400 });
    });
    const c = new GametimeClient({ apiKey: () => 'SECRETKEY', fetch: f, sleep: async () => {} });
    expect(await c.getPurchase('GT1')).toMatchObject({ id: 'GT1' });
    expect(f.mock.calls[0][0]).toBe('https://api.gametime.co/v3/purchases?order_number=GT1&source=SECRETKEY');
    const err = await c.listPurchases({ completed: false }).catch((e) => e as Error);
    expect(String(err)).toMatch(/GET \/purchases -> 400/);
    expect(String(err)).not.toContain('SECRETKEY');
  });

  it('parses ISODate(...) timestamps', () => {
    expect(gametimeDate('ISODate(2015-01-09T18:08:30.357Z)')).toBe('2015-01-09T18:08:30.357Z');
    expect(gametimeDate('nonsense')).toBeNull();
  });
});

describe('inventory', () => {
  it('plans one listing per max-per-order block with internal seats, in Gametime CSV form', () => {
    const p = planGametimeListings(base);
    expect(p.listings.map((l) => [l.request.body.TicketID, l.request.body.SeatFrom, l.request.body.SeatThru, l.request.body.Quantity])).toEqual([
      [exosListingId(ALLOC, 1), '1', '4', '4'],
      [exosListingId(ALLOC, 2), '5', '8', '4'],
      [exosListingId(ALLOC, 3), '9', '10', '2'],
    ]);
    expect(p.listings[0].request.body).toMatchObject({
      Event: 'Late Night Jazz, Vol. 2', Venue: 'Blue Room', EventDate: '11/6/2026', EventTime: '9:00:00 PM', Row: 'GA', Section: 'GA',
      Cost: '45.00', FaceValue: '40.00', edelivery_ind: 'Y', Instant: 'N', Splittype: 'ANY', Stock: 'mobile_transfer', InHandDate: '2026-11-06',
    });
    expect(p.per_order_cap).toBe(4);
  });

  it('writes a CSV with Gametime’s columns, quoting commas, Exos ids only', () => {
    const p = planGametimeListings(base);
    const csv = gametimeInventoryCsv(p.listings.map((l) => l.request.body));
    const lines = csv.trim().split('\r\n');
    expect(lines[0]).toBe(GAMETIME_CSV_COLUMNS.join(','));
    expect(lines).toHaveLength(4);
    expect(lines[1]).toMatch(/^y,"Late Night Jazz, Vol\. 2",Blue Room,11\/6\/2026,9:00:00 PM,4,GA,GA,1,4,/);
    expect(() => gametimeInventoryCsv([{ ...p.listings[0].request.body, TicketID: '1732272492' }])).toThrow(/not an Exos listing id/);
  });

  it('refuses what it cannot describe', () => {
    expect(() => planGametimeListings({ ...base, internal_seats: '{[1,5)}' })).toThrow(/internal seat numbers/);
    expect(() => planGametimeListings({ ...base, event: { ...base.event!, currency: 'EUR' } })).toThrow(/USD/);
    expect(() => planGametimeListings({ ...base, event: { ...base.event!, occurs_at_local: null } })).toThrow(/time zone/);
  });

  it('syncs against what Gametime has, and delists Exos listings only', () => {
    const live = planGametimeListings(base);
    expect(syncListings(live, null).action).toBe('create');
    expect(syncListings(live, live).action).toBe('none');
    const next = planGametimeListings({ ...base, requested_qty: 8, internal_seats: '{[1,9)}', previous: live });
    expect(syncListings(next, live).ops.delete).toEqual([exosListingId(ALLOC, 3)]);
    const d = planDelist('gametime', { listings: [...live.listings, { listing_id: '1732272492' }] });
    expect(d?.requests).toHaveLength(3);
    expect(d?.requests[0]).toMatchObject({ method: 'DELETE', path: `/listings/${exosListingId(ALLOC, 1)}/delete` });
  });
});

describe('writer', () => {
  it('plans, never sends, in dry-run', async () => {
    const f = vi.fn();
    const w = new GametimeWriter({ fetch: f });
    const r = await w.editListing(exosListingId(ALLOC, 1), { quantity: 2, lots: [1, 2] });
    expect(r).toMatchObject({ dryRun: true, planned: { endpoint: 'editListing', method: 'POST', url: `/listings/${exosListingId(ALLOC, 1)}` } });
    expect(f).not.toHaveBeenCalled();
    expect(w.uploadInventory([]).planned.url).toBe('ftp://gtftp.gametime.co/inventory.csv');
  });

  it('refuses broker listings, bad lots, and the file on an account that may hold broker inventory', async () => {
    const w = new GametimeWriter();
    expect(() => w.deleteListing('1732272492')).toThrow(GametimeWriteRefusedError);
    expect(() => w.editListing(exosListingId(ALLOC, 1), { quantity: 2, lots: [3] })).toThrow(/lots/);
    const live = new GametimeWriter({ mode: { mode: 'live', authorization: AUTH }, apiKey: () => 'k', fetch: vi.fn() });
    expect(() => live.uploadInventory([])).toThrow(/dedicatedAccount/);
    const dedicated = new GametimeWriter({ mode: { mode: 'live', authorization: { ...AUTH, dedicatedAccount: true } }, apiKey: () => 'k', fetch: vi.fn() });
    expect(() => dedicated.uploadInventory([])).toThrow(/not built/);
    await expect(live.rejectPurchase('GT1')).rejects.toThrow(/not in the authorization scope/);
  });
});

describe('orders', () => {
  const purchase = {
    id: 'GT-100', status: 'unconfirmed', quantity: 2, listing_reference_id: exosListingId(ALLOC, 2), price: 9000,
    email: ' Buyer@Example.com ', delivery_type: 'mobile', event_id: 'E9', purchased_at: 'ISODate(2026-10-01T12:00:00Z)',
  };

  it('normalizes a purchase to its allocation', () => {
    expect(normalizeGametimeSale(purchase)).toMatchObject({
      channel: 'gametime', externalOrderId: 'GT-100', externalListingId: ALLOC, quantity: 2, status: 'pending',
      buyerEmail: 'buyer@example.com', createdAt: '2026-10-01T12:00:00.000Z', proceeds: null,
    });
    expect(normalizeGametimeSale({ ...purchase, status: 'unfulfilled' }).status).toBe('confirmed');
    expect(normalizeGametimeSale({ ...purchase, status: 'completed' }).status).toBe('delivered');
    expect(normalizeGametimeSale({ ...purchase, status: 'rejected' }).status).toBe('cancelled');
    expect(normalizeGametimeSale({ ...purchase, status: 'weird' }).status).toBe('unknown');
  });

  it('takes the payout from the sales notification', () => {
    const n = parseGametimeSaleNotification({ id: 'GT-100', source_id: exosListingId(ALLOC, 2), quantity: 2, unit_price: 5000, payout: 9000 });
    expect(normalizeGametimeSale(n)).toMatchObject({ status: 'pending', buyerEmail: null, proceeds: { amount: 90, currency: 'USD' } });
    expect(normalizeGametimeSale({ ...n, ...purchase }).proceeds).toEqual({ amount: 90, currency: 'USD' });
    expect(() => parseGametimeSaleNotification({ id: 'x' })).toThrow();
  });

  it('checks the webhook header in full', () => {
    expect(verifyGametimeWebhook('Bearer abc', 'Bearer abc')).toBe(true);
    expect(verifyGametimeWebhook('Bearer abd', 'Bearer abc')).toBe(false);
    expect(verifyGametimeWebhook('Bearer abc', '')).toBe(false);
  });

  it('delivers by confirming, then confirm_transfer with one claim link per ticket', () => {
    const urls = ['https://exos.test/claim/a', 'https://exos.test/claim/b'];
    const steps = gametimeChannel().planFulfilByUrls!(normalizeGametimeSale(purchase), urls, [7, 8]);
    expect(steps.map((s) => [s.endpoint, s.path])).toEqual([
      ['confirmPurchase', '/purchases/GT-100/confirm'],
      ['confirmTransfer', '/purchases/GT-100/confirm_transfer'],
    ]);
    // The tickets' internal seats go with the confirm.
    expect(steps[0].body).toEqual({ seats: ['7', '8'] });
    expect(transferConfirmationForm({ orderNumber: 'GT-100', urls, quantity: 2 })).toEqual([
      ['transfer_url[]', urls[0]], ['transfer_url[]', urls[1]], ['transfer_type', 'generic'],
    ]);
    expect(() => transferConfirmationForm({ orderNumber: 'GT-100', urls, quantity: 3 })).toThrow(/2 transfer urls for 3/);
  });
});
