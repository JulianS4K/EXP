import { describe, it, expect } from 'vitest';
import { allocationCellStatus, gametimeStatus, poolLine, seatGeekStatus, stubHubStatus, type StubHubDistributionRow } from './stubhubStatus';

const EV = { stubhubTicked: true, published: true, primaryMarketOnly: false };
const row = (p: Partial<StubHubDistributionRow>): StubHubDistributionRow => ({
  status: 'pending', error: null, external_event_id: null, planned_request: null, last_synced_at: null, ...p,
});

describe('stubHubStatus', () => {
  it('says nothing when StubHub is not ticked', () => {
    expect(stubHubStatus(null, { ...EV, stubhubTicked: false })).toBeNull();
  });

  it('explains what happens before a row exists', () => {
    expect(stubHubStatus(null, { ...EV, published: false })?.text).toMatch(/when you publish/);
    expect(stubHubStatus(null, EV)?.text).toMatch(/Save to queue/);
    expect(stubHubStatus(null, { ...EV, primaryMarketOnly: true })?.text).toMatch(/Primary market only/);
  });

  it('describes the queue states', () => {
    expect(stubHubStatus(row({}), EV)).toEqual({ tone: 'info', text: 'Queued: Exos is preparing the StubHub event request.' });
    const planned = stubHubStatus(row({
      status: 'planned',
      planned_request: { body: { event: { name: 'Late Night Jazz' }, venue: { name: 'Blue Room', city: 'Brooklyn' } } },
    }), EV);
    expect(planned?.text).toBe(
      "StubHub event request ready for Late Night Jazz at Blue Room, Brooklyn. Not sent yet: StubHub selling isn't switched on.",
    );
    expect(stubHubStatus(row({ status: 'planned' }), EV)?.text).toMatch(/^StubHub event request ready\. Not sent/);
    const failed = stubHubStatus(row({ status: 'failed', error: 'venue city is required: add the venue address to the event' }), EV);
    expect(failed?.tone).toBe('warn');
    expect(failed?.text).toMatch(/venue city is required/);
  });

  it('says when the event is already on StubHub (linked, nothing to create)', () => {
    const s = stubHubStatus(row({ status: 'planned', planned_request: { linked: true, external_event_id: '104857' } }), EV);
    expect(s).toEqual({ tone: 'ok', text: 'Already on StubHub (event 104857): no new event needed.' });
  });

  it('shows the StubHub event once it exists, even if StubHub was unticked since', () => {
    const s = stubHubStatus(row({ status: 'listed', external_event_id: '104857' }), { ...EV, stubhubTicked: false });
    expect(s).toEqual({ tone: 'ok', text: 'On StubHub (event 104857).' });
  });
});

describe('seatGeekStatus', () => {
  const ev = { ticked: true, published: true, primaryMarketOnly: false };
  it('says which SeatGeek event the listings attach to', () => {
    expect(seatGeekStatus(null, { ...ev, ticked: false })).toBeNull();
    expect(seatGeekStatus(null, { ...ev, published: false })?.text).toMatch(/when you publish/);
    expect(seatGeekStatus(row({ status: 'planned', planned_request: { linked: true, external_event_id: '6123456' } }), ev))
      .toEqual({ tone: 'ok', text: 'SeatGeek listings attach to SeatGeek event 6123456.' });
    expect(seatGeekStatus(row({ status: 'planned', planned_request: { linked: false } }), ev)?.text).toMatch(/event name and venue/);
    expect(seatGeekStatus(row({ status: 'failed', error: 'SeatGeek may already have this event' }), ev)?.tone).toBe('warn');
  });
});

describe('allocationCellStatus', () => {
  const alloc = (p: Partial<StubHubDistributionRow>) => row({ tier_id: 't1', requested_qty: 10, ...p });
  it('describes a cell of the grid', () => {
    expect(allocationCellStatus(null, 'seatgeek')).toBeNull();
    expect(allocationCellStatus(alloc({ status: 'delisted', requested_qty: 0 }), 'seatgeek')).toBeNull();
    expect(allocationCellStatus(alloc({}), 'seatgeek')?.text).toMatch(/listed once the event is published/);
    expect(allocationCellStatus(alloc({ planned_listing: { action: 'create', listings: [{}, {}, {}] } }), 'seatgeek')?.text)
      .toBe("3 listings ready. Not sent yet: SeatGeek selling isn't switched on.");
    expect(allocationCellStatus(alloc({ planned_listing: { action: 'create', listings: [{}, {}] } }), 'stubhub')?.text).toMatch(/^2 listings ready/);
    expect(allocationCellStatus(alloc({ planned_listing: { error: 'the ticket type has no price' } }), 'stubhub'))
      .toEqual({ tone: 'warn', text: 'the ticket type has no price' });
    expect(allocationCellStatus(alloc({ status: 'delisting' }), 'stubhub')?.text).toMatch(/Coming off StubHub/);
    expect(allocationCellStatus(alloc({ status: 'listed', planned_listing: { action: 'update', ops: { update: [{}], delete: [{}] } } }), 'seatgeek')?.text)
      .toBe('On SeatGeek; 2 changes to send.');
  });
});

describe('gametimeStatus', () => {
  const ev = { ticked: true, published: true, primaryMarketOnly: false };
  it('explains Gametime', () => {
    expect(gametimeStatus(null, { ...ev, ticked: false })).toBeNull();
    expect(gametimeStatus(null, { ...ev, published: false })?.text).toMatch(/when you publish/);
    expect(gametimeStatus(row({ status: 'planned' }), ev)?.text).toMatch(/event name, venue and date/);
    expect(gametimeStatus(row({ status: 'failed', error: 'x' }), ev)).toEqual({ tone: 'warn', text: 'x' });
    expect(allocationCellStatus(row({ tier_id: 't', requested_qty: 4, planned_listing: { action: 'create', listings: [{}] } }), 'gametime')?.text)
      .toBe("1 listing ready. Not sent yet: Gametime selling isn't switched on.");
  });
});

describe('poolLine', () => {
  it('says what a marketplace holds, its cap and what it sold', () => {
    expect(poolLine(null)).toBeNull();
    expect(poolLine(row({ tier_id: 't', requested_qty: 4, sell_cap: 10, sold_qty: 2, list_qty: 4 })))
      .toBe('Holding 4 now, up to 10 in total, 2 sold.');
    expect(poolLine(row({ tier_id: 't', requested_qty: 0, sell_cap: 10, sold_qty: 6, list_qty: 0 })))
      .toBe('Holding 0 now, up to 10 in total, 6 sold, none free right now.');
    expect(poolLine(row({ tier_id: 't', status: 'listed', requested_qty: 4, sell_cap: 1, list_qty: 1 })))
      .toBe('Holding 4 now, up to 1 in total, 3 back to Exos once the marketplace takes the lower number.');
    expect(poolLine(row({ tier_id: 't', status: 'delisted', requested_qty: 0, sell_cap: 0 }))).toBeNull();
  });
});
