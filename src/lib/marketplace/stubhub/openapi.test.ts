// Checks our hand-written shapes against StubHub's published OpenAPI specs
// (docs/marketplace/stubhub/openapi/, from viagogo/stubhub-api-docs). If
// StubHub renames or drops a field we send, this fails before a live call.
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { describe, it, expect } from 'vitest';
import { MOBILE_TRANSFER_PROVIDERS, attachETicketsRequest, eticketUrlsRequest, mobileTransferRequest } from '.';
import { SPLIT_TYPES, buildRequestedEvent, buildRequestedEventListingRequest } from '.';
import { STUBHUB_WEBHOOK_TOPICS, normalizeTopic } from '.';

type Schema = { properties?: Record<string, { description?: string }>; required?: string[] };
type Spec = { components: { schemas: Record<string, Schema> }; 'x-webhooks'?: Record<string, { post: { summary: string } }> };

const load = (name: string) =>
  JSON.parse(readFileSync(resolve(__dirname, `../../../../docs/marketplace/stubhub/openapi/${name}.json`), 'utf8')) as Spec;
const inventory = load('inventory');
const sales = load('sales');
const webhooks = load('webhooks');
const props = (spec: Spec, name: string) => Object.keys(spec.components.schemas[name].properties ?? {});

describe('StubHub OpenAPI conformance', () => {
  it('requested-event listing body only uses documented fields and has the required ones', () => {
    const req = buildRequestedEventListingRequest(
      { id: 'row', channel: 'stubhub', requested_qty: 2, unit_price: 50 },
      { ticketType: 'ETicket', splitType: 'Any', section: 'GA', row: 'A', seatFrom: '1', seatTo: '2', currency: 'USD', faceValue: 45, inHandAt: '2026-10-01T00:00:00Z', instantDelivery: true, notes: 'n' },
      { name: 'Show', startsAt: '2026-11-01T00:00:00Z', venueName: 'Hall', venueCity: 'Austin', venueStateProvince: 'TX', countryCode: 'US' },
    );
    const schema = inventory.components.schemas.PostRequestedEventSellerListingRequest;
    expect(Object.keys(req).filter((k) => !props(inventory, 'PostRequestedEventSellerListingRequest').includes(k))).toEqual([]);
    for (const r of schema.required ?? []) expect(req, r).toHaveProperty(r);
    expect(Object.keys(req.seating).filter((k) => !props(inventory, 'SeatingRequest').includes(k))).toEqual([]);
    expect(Object.keys(req.event).filter((k) => !props(inventory, 'EventRequest').includes(k))).toEqual([]);
    expect(Object.keys(req.venue).filter((k) => !props(inventory, 'VenueRequest').includes(k))).toEqual([]);
    expect(Object.keys(req.ticket_price!).filter((k) => !props(inventory, 'Money').includes(k))).toEqual([]);
  });

  it('the requested-event body matches PutRequestedEventRequest (sellerevents + listingconstraints)', () => {
    const body = buildRequestedEvent({ name: 'Show', startsAt: '2026-11-01T00:00:00Z', venueName: 'Hall', venueCity: 'Austin', countryCode: 'US' });
    expect(Object.keys(body).filter((k) => !props(inventory, 'PutRequestedEventRequest').includes(k))).toEqual([]);
    expect(Object.keys(body.country!).filter((k) => !props(inventory, 'CountryRequest').includes(k))).toEqual([]);
  });

  it('split types match the SplitType schema', () => {
    const desc = inventory.components.schemas.SplitType.properties!.type.description!;
    expect(desc).toContain(`Can be ${SPLIT_TYPES.slice(0, -1).join(', ')}, or ${SPLIT_TYPES.at(-1)}.`);
  });

  it('sale PATCH bodies only use PatchSaleRequest fields', () => {
    const allowed = props(sales, 'PatchSaleRequest');
    const bodies = [
      eticketUrlsRequest(['https://exos.example.test/claim/0b6f1c2e-1111-4a2b-9c3d-000000000001'], 1),
      mobileTransferRequest('AXS', 'X-1'),
      attachETicketsRequest([1]),
    ];
    for (const b of bodies) expect(Object.keys(b).filter((k) => !allowed.includes(k))).toEqual([]);
    expect(props(sales, 'ETicketUrlRequest')).toContain('url');
  });

  it('mobile providers match the documented list', () => {
    const desc = sales.components.schemas.PatchSaleRequest.properties!.mobile_provider.description!;
    const listed = desc.split(':')[1].split(/,\s*/).map((s) => s.trim()).filter(Boolean);
    expect([...MOBILE_TRANSFER_PROVIDERS]).toEqual(listed);
  });

  it('ticket holders expose email_address', () => {
    expect(props(sales, 'TicketHolder')).toContain('email_address');
  });

  it('every webhook topic normalizes, in both spellings', () => {
    const hooks = webhooks['x-webhooks']!;
    for (const [key, { post }] of Object.entries(hooks)) {
      expect(normalizeTopic(key), key).toBe(post.summary);
      expect(normalizeTopic(post.summary), post.summary).toBe(post.summary);
    }
    expect(Object.values(hooks).map((h) => h.post.summary).sort()).toEqual([...STUBHUB_WEBHOOK_TOPICS].sort());
  });
});

describe('StubHub OpenAPI query params', () => {
  type Op = { parameters?: Array<{ name: string; in: string }> };
  const catalog = JSON.parse(
    readFileSync(resolve(__dirname, '../../../../docs/marketplace/stubhub/openapi/catalog.json'), 'utf8'),
  ) as { paths: Record<string, { get?: Op }> };
  const query = (path: string) => (catalog.paths[path].get?.parameters ?? []).filter((p) => p.in === 'query').map((p) => p.name);

  it('event search takes q and dateLocal', () => {
    expect(query('/catalog/events/search')).toEqual(expect.arrayContaining(['q', 'dateLocal']));
  });
});
