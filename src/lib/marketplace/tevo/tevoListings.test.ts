import { describe, expect, it, vi } from 'vitest';
import {
  EXOS_TEVO_REMOTE_ID_MIN,
  TevoWriteRefusedError,
  TevoWriter,
  annotateTevoOrder,
  exosListingRef,
  isExosTevoRemoteId,
  normalizeTevoOrder,
  planTevoListings,
  tevoAwaitingFraudCheck,
  tevoRemoteIds,
  type TevoAllocation,
  type TevoOrder,
  type TevoWriteAuthorization,
} from '.';
import { exosListingId, planDelist, syncListings } from '..';

const ALLOC = '0f8fad5b-d9cb-469f-a165-70867728950e';
const L1 = exosListingId(ALLOC, 1);
const L2 = exosListingId(ALLOC, 2);
const R1 = EXOS_TEVO_REMOTE_ID_MIN + 41;
const R2 = EXOS_TEVO_REMOTE_ID_MIN + 42;
const CREDS = { token: 'tok-SECRET-123', secret: 'sec-SECRET-456' };

const A: TevoAllocation = {
  id: ALLOC,
  requested_qty: 6,
  unit_price: 45,
  internal_seats: '{[1,7)}',
  tier: { name: 'GA', price: 40 },
  event: {
    name: 'Late Night Jazz', starts_at: '2026-11-07T02:00:00Z', occurs_at_local: '2026-11-06T21:00:00-05:00',
    venue_name: 'Blue Room', venue_address: { city: 'Brooklyn', region: 'NY', country: 'US' }, currency: 'USD', purchase_limits: { maxPerOrder: 4 },
  },
  tevoEventId: '2204331',
  officeId: '1234',
  remoteIds: { [L1]: R1, [L2]: R2 },
};

describe('planTevoListings', () => {
  it('one TM_mobile ticket group per Exos listing, with its remote_id, seats and id in internal_notes', () => {
    const p = planTevoListings(A);
    expect(p.channel).toBe('evo');
    expect(p.unresolved).toEqual([]);
    expect(p.listings.map((l) => [l.listing_id, l.seat_from, l.seat_thru, l.quantity])).toEqual([[L1, 1, 4, 4], [L2, 5, 6, 2]]);
    expect(p.listings[0].request).toMatchObject({ endpoint: 'createInventory', method: 'POST', path: '/v9/inventory' });
    expect(p.listings[0].request.body).toEqual({
      inventory: {
        event: { id: 2204331, name: 'Late Night Jazz', occurs_at_date: '2026-11-06', occurs_at_time: '21:00' },
        office: { id: 1234 },
        ticket: {
          format: 'TM_mobile', price: 45, quantity: 4, remote_id: R1, row: 'GA', section: 'General Admission', type: 'EVENT',
          seats: [{ seat: 1 }, { seat: 2 }, { seat: 3 }, { seat: 4 }], split_type: 'ANY', in_hand: false, in_hand_on: '2026-11-06',
          face_value: 40, external_notes: expect.stringContaining('Exos'), internal_notes: L1,
        },
        venue: { name: 'Blue Room' },
      },
    });
  });

  it('says what is missing instead of guessing: event link, office, numbering', () => {
    const p = planTevoListings({ ...A, tevoEventId: null, officeId: null, remoteIds: {} });
    expect(p.unresolved.join('\n')).toMatch(/event\.id: link the event/);
    expect(p.unresolved.join('\n')).toMatch(/TEVO_OFFICE_ID/);
    expect(p.unresolved.filter((u) => u.startsWith('remote_id'))).toHaveLength(2);
    expect(p.listings[0].request.body.inventory.event.id).toBeUndefined();
    expect(p.listings[0].request.body.inventory.ticket.remote_id).toBe(0);
  });

  it('USD only', () => {
    expect(() => planTevoListings({ ...A, event: { ...A.event!, currency: 'EUR' } })).toThrow(/USD/);
  });

  it('a price change is a ticket-only patch; a sold-out block is deleted by TEvo id, one at a time', () => {
    const before = planTevoListings(A);
    const snapshot = { ...before, listings: before.listings.map((l, i) => ({ ...l, tevo_inventory_id: 880001 + i })) };
    const after = syncListings(planTevoListings({ ...A, unit_price: 50 }), snapshot);
    expect(after.action).toBe('update');
    expect(after.ops.update).toEqual([
      { listing_id: L1, patch: { inventory: { ticket: { price: 50 } } } },
      { listing_id: L2, patch: { inventory: { ticket: { price: 50 } } } },
    ]);
    // Listing 1 sold: seats 5-6 left, listing 2 stays, listing 1 goes.
    const sold = syncListings(planTevoListings({ ...A, requested_qty: 2, internal_seats: '{[5,7)}', previous: snapshot }), snapshot);
    expect(sold.ops.delete).toEqual([L1]);
    expect(planDelist('evo', snapshot)?.requests).toEqual([
      { endpoint: 'deleteInventory', method: 'DELETE', path: '/v9/inventory/880001' },
      { endpoint: 'deleteInventory', method: 'DELETE', path: '/v9/inventory/880002' },
    ]);
    // No TEvo id recorded: nothing addressable, a person takes it down.
    expect(planDelist('evo', before)?.requests[0].path).toMatch(/take it down by hand/);
  });
});

describe('remote_id on orders', () => {
  const order = (remote: unknown): TevoOrder => ({
    id: 190850, state: 'pending', buyer: { type: 'Office', id: 6 },
    items: [{ id: 1, quantity: 2, price: '45.00', ticket_group: { id: 77, section: 'GA', row: 'GA', remote_id: remote as number } }],
  });

  it('only numbers in the Exos range count', () => {
    expect(isExosTevoRemoteId(R1)).toBe(true);
    expect(isExosTevoRemoteId(String(R1))).toBe(true);
    expect(isExosTevoRemoteId(12345)).toBe(false);
    expect(isExosTevoRemoteId(2 ** 31)).toBe(false);
    expect(tevoRemoteIds([order(R2), order(99), order(R2)])).toEqual([R2]);
  });

  it('maps a sale back to its Exos listing and allocation; broker groups stay broker', () => {
    const map = new Map([[R2, L2]]);
    const mine = annotateTevoOrder(order(R2), map);
    expect(exosListingRef(mine.items![0])).toBe(L2);
    expect(normalizeTevoOrder(mine)).toMatchObject({ listingRef: L2, externalListingId: ALLOC, quantity: 2 });
    const broker = annotateTevoOrder(order(555), map);
    expect(exosListingRef(broker.items![0])).toBeNull();
    // An Exos-range number Exos never issued isn't mapped either.
    expect(exosListingRef(annotateTevoOrder(order(R1), map).items![0])).toBeNull();
  });
});

describe('TevoWriter inventory', () => {
  const body = () => structuredClone(planTevoListings(A).listings[0].request.body);
  const ref = { inventory_id: 880001, listing_id: L1, remote_id: R1 };
  const AUTH: TevoWriteAuthorization = { approvedBy: 'op', approvedAt: '2026-09-28T00:00:00Z', reference: 'test', endpoints: ['createInventory'] };

  it('dry-run plans create / update / delete by id and never calls fetch', async () => {
    const fetchImpl = vi.fn();
    const w = new TevoWriter({ fetch: fetchImpl, credentials: () => CREDS, officeId: 1234 });
    expect(await w.createInventory(body())).toMatchObject({ dryRun: true, planned: { endpoint: 'createInventory', method: 'POST', url: '/v9/inventory' } });
    expect(await w.updateInventory(ref, { inventory: { ticket: { price: 50 } } }))
      .toMatchObject({ dryRun: true, planned: { method: 'PATCH', url: '/v9/inventory/880001', body: { inventory: { ticket: { price: 50 } } } } });
    expect(await w.deleteInventory(ref)).toMatchObject({ dryRun: true, planned: { method: 'DELETE', url: '/v9/inventory/880001' } });
    expect(fetchImpl).not.toHaveBeenCalled();
  });

  it('refuses anything that is not an Exos listing in the Exos office, as a mobile transfer', () => {
    const w = new TevoWriter({ officeId: 1234 });
    const bad = (f: (b: ReturnType<typeof body>) => void) => { const b = body(); f(b); return () => w.createInventory(b); };
    expect(bad((b) => { b.inventory.ticket.internal_notes = 'broker note'; })).toThrow(/Exos listing id/);
    expect(bad((b) => { b.inventory.ticket.remote_id = 42; })).toThrow(/remote_id/);
    expect(bad((b) => { b.inventory.office = { id: 999 }; })).toThrow(/configured office/);
    expect(bad((b) => { delete b.inventory.event.id; })).toThrow(/link the event/);
    expect(bad((b) => { b.inventory.ticket.format = 'Eticket'; })).toThrow(/mobile transfers only/);
    expect(bad((b) => { b.inventory.ticket.quantity = 3; })).toThrow(/one per ticket/);
    expect(bad((b) => { b.inventory.ticket.price = 2_000_000; })).toThrow(/price/);
    expect(() => new TevoWriter().createInventory(body())).toThrow(/TEVO_OFFICE_ID/);
    expect(() => w.deleteInventory({ ...ref, listing_id: 'BROKER-1' })).toThrow(TevoWriteRefusedError);
    expect(() => w.deleteInventory({ ...ref, remote_id: 7 })).toThrow(/remote_id/);
    expect(() => w.updateInventory(ref, { inventory: { ticket: { remote_id: R2 } as never } })).toThrow(/fixed once listed/);
    expect(() => w.updateInventory(ref, { inventory: { event: { id: 1 } } as never })).toThrow(/only ticket fields/);
    expect(() => w.updateInventory(ref, { inventory: { ticket: { quantity: 2, seats: [{ seat: 1 }] } } })).toThrow(/one per ticket/);
  });

  it('bulk endpoints are not writable even with an authorization', () => {
    expect(() => new TevoWriter({ mode: { mode: 'live', authorization: { ...AUTH, endpoints: ['bulkDeleteInventory' as never] } }, credentials: () => CREDS }))
      .toThrow(/not an allowed write/);
  });

  it('live create sends a signed PATCH-free POST and returns TEvo id', async () => {
    const fetchImpl = vi.fn(async () => new Response(JSON.stringify({ inventory: { id: 880001 } }), { status: 201 }));
    const w = new TevoWriter({ mode: { mode: 'live', authorization: AUTH }, credentials: () => CREDS, fetch: fetchImpl, officeId: 1234 });
    const r = await w.createInventory(body());
    expect(r.dryRun).toBe(false);
    expect(r.dryRun === false && r.response.inventory?.id).toBe(880001);
    const [url, init] = fetchImpl.mock.calls[0] as unknown as [string, RequestInit];
    expect(url).toBe('https://api.sandbox.ticketevolution.com/v9/inventory');
    expect(init.method).toBe('POST');
    expect(JSON.parse(String(init.body)).inventory.ticket.remote_id).toBe(R1);
    await expect(w.deleteInventory(ref)).rejects.toThrow(/authorization scope/);
  });
});

describe('fraud gate before issuing', () => {
  const client = (fraud: unknown): TevoOrder => ({
    id: 190900, state: 'pending', buyer: { type: 'Client', id: 9 }, fraud_check_status: fraud as never,
    items: [{ id: 1, quantity: 1, price: '45.00', ticket_group: { id: 7, remote_id: R1, exos_listing_id: L1 } }],
  });
  it('holds a Client sale while Riskified is pending, and a declined one is a cancellation', () => {
    expect(tevoAwaitingFraudCheck(client('pending'))).toBe(true);
    expect(tevoAwaitingFraudCheck(client('approved'))).toBe(false);
    expect(tevoAwaitingFraudCheck(client(null))).toBe(false);
    expect(normalizeTevoOrder(client('declined')).status).toBe('cancelled');
    expect(normalizeTevoOrder(client('approved')).status).toBe('pending');
    // A sale to TEvo itself is never screened.
    expect(tevoAwaitingFraudCheck({ ...client('pending'), buyer: { type: 'Office', id: 6 } })).toBe(false);
  });
});
