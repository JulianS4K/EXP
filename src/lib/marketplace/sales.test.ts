import { describe, it, expect } from 'vitest';
import {
  normalizeStubHubSale,
  planDelivery,
  recordPayload,
  stubHubChannel,
  type MarketplaceChannel,
} from '.';

// A channel that can't take ticket links through its API.
const NO_LINKS: MarketplaceChannel = {
  id: 'vivid', label: 'Vivid Seats',
  capabilities: { findEvents: false, createEvent: false, listings: false, fulfilByUrls: false },
};

const T1 = '00000000-0000-4000-8000-000000000001';
const T2 = '00000000-0000-4000-8000-000000000002';

describe('recordPayload', () => {
  it('carries what exos_record_marketplace_order reads', () => {
    const sale = normalizeStubHubSale({
      id: 555, created_at: '2026-10-01T00:00:00Z', number_of_tickets: 2, status: 'Confirmed',
      proceeds: { amount: 90.5, currency_code: 'USD' }, external_listing_id: 'dist-1', confirm_by: '2026-10-02T00:00:00Z',
    });
    sale.buyerEmail = 'b@x.com';
    expect(recordPayload(sale, { id: 555 })).toEqual({
      channel: 'stubhub', external_order_id: '555', external_event_id: null, external_listing_id: 'dist-1',
      quantity: 2, sale_status: 'confirmed', buyer_email: 'b@x.com', currency: 'USD', proceeds: '90.50',
      confirm_by: '2026-10-02T00:00:00Z', sold_at: '2026-10-01T00:00:00Z', raw: { id: 555 },
    });
  });

  it('leaves out what the marketplace did not send', () => {
    const p = recordPayload(normalizeStubHubSale({ id: 1, status: 'Confirmed', number_of_tickets: 1 }));
    expect(p).not.toHaveProperty('proceeds');
    expect(p).not.toHaveProperty('confirm_by');
    expect(p).not.toHaveProperty('raw');
    expect(p.buyer_email).toBeNull();
  });
});

describe('planDelivery', () => {
  const order = { external_order_id: '555', quantity: 2, transfer_ids: [T1, T2] };

  it('plans StubHub URL delivery with one claim link per ticket under /bridge', () => {
    const plan = planDelivery(stubHubChannel(), order, 'https://vibepass-storefront-test.onrender.com/bridge');
    expect(plan.kind).toBe('planned');
    if (plan.kind !== 'planned') return;
    expect(plan.claim_urls).toEqual([
      `https://vibepass-storefront-test.onrender.com/bridge/claim/${T1}`,
      `https://vibepass-storefront-test.onrender.com/bridge/claim/${T2}`,
    ]);
    expect(plan.request).toMatchObject({
      channel: 'stubhub', endpoint: 'updateSale', method: 'PATCH', path: '/sales/555',
      body: { confirmed: true, eticket_urls: plan.claim_urls.map((url) => ({ url })) },
    });
  });

  it('hands a channel without link delivery to a human, links ready', () => {
    const plan = planDelivery(NO_LINKS, order, 'https://x.test/bridge');
    expect(plan).toMatchObject({ kind: 'manual', claim_urls: [`https://x.test/bridge/claim/${T1}`, `https://x.test/bridge/claim/${T2}`] });
    expect(plan.kind === 'manual' && plan.reason).toMatch(/by hand/);
  });

  it('needs the app URL to make links', () => {
    expect(planDelivery(stubHubChannel(), order, undefined)).toMatchObject({ kind: 'manual', claim_urls: [] });
    expect(() => planDelivery(stubHubChannel(), order, 'http://insecure.test')).toThrow(/https/);
  });
});
