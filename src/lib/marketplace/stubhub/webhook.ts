// StubHub webhook receiving: auth check, payload parsing, topic routing.
//
// StubHub's only delivery auth is the `authorization_header` string we set
// when registering the webhook, echoed back on every POST. The reference
// documents no HMAC or signature, so the receiver must compare that header
// in constant time and treat the payload as a hint: re-read the sale/listing
// through the client before acting on it.
//
// Topic names per the OpenAPI spec (webhooks.json x-webhooks): PascalCase in
// the payload ("Ping", "Sales", …), kebab-case as subscription keys
// ("provisional-sale", "sellerlisting-updates"). `normalizeTopic` accepts
// both and returns `unknown` for anything new. Each delivery also carries a
// unique delivery id (the spec gives no header name) usable for de-dup.

import type { CatalogEvent, HalLinks, Sale, SellerListing, Venue, Webhook } from './types';

export const STUBHUB_WEBHOOK_TOPICS = [
  'Sales',
  'ProvisionalSale',
  'CancelProvisionalSale',
  'SaleUpdates',
  'SellerListingUpdates',
  'ReTransferTicket',
  'Ping',
] as const;

export type StubHubWebhookTopic = (typeof STUBHUB_WEBHOOK_TOPICS)[number];

/** Documented `action` values for the update topics. */
export const STUBHUB_WEBHOOK_ACTIONS = {
  SaleUpdates: ['FailedBarcodeValidation'],
  SellerListingUpdates: ['FailedBarcodeValidation', 'ListingDeliverabilityExpired'],
} as const;

export interface StubHubWebhookPayload {
  topic: string | null;
  action: string | null;
  barcodes: unknown[] | null;
  _links?: HalLinks;
  _embedded?: {
    event?: CatalogEvent;
    sale?: Sale;
    seller_listing?: SellerListing;
    venue?: Venue;
    webhook?: Webhook;
  };
}

const squash = (s: string) => s.toLowerCase().replace(/[^a-z]/g, '').replace(/topic$/, '');
const TOPIC_BY_KEY = new Map(STUBHUB_WEBHOOK_TOPICS.map((t) => [squash(t), t]));

/** "Sales", "SalesTopic", "sales", "seller_listing_updates" → canonical name. */
export function normalizeTopic(raw: string | null | undefined): StubHubWebhookTopic | 'unknown' {
  if (!raw) return 'unknown';
  return TOPIC_BY_KEY.get(squash(raw)) ?? 'unknown';
}

/**
 * Constant-time comparison of the received Authorization header against the
 * value we registered. An empty `expected` never verifies (misconfiguration
 * must fail closed).
 */
export function verifyWebhookAuthorization(received: string | null | undefined, expected: string): boolean {
  if (!expected || received == null) return false;
  const enc = new TextEncoder();
  const a = enc.encode(received);
  const b = enc.encode(expected);
  let diff = a.length ^ b.length;
  for (let i = 0; i < b.length; i++) diff |= (a[i] ?? 0) ^ b[i];
  return diff === 0;
}

export class WebhookPayloadError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'WebhookPayloadError';
  }
}

/** Shape-checks a parsed JSON body. Throws WebhookPayloadError if it isn't a StubHub payload. */
export function parseWebhookPayload(body: unknown): StubHubWebhookPayload & { kind: StubHubWebhookTopic | 'unknown' } {
  if (!body || typeof body !== 'object' || Array.isArray(body)) {
    throw new WebhookPayloadError('stubhub webhook: body is not an object');
  }
  const b = body as Record<string, unknown>;
  const str = (k: string) => {
    const v = b[k];
    if (v !== undefined && v !== null && typeof v !== 'string') {
      throw new WebhookPayloadError(`stubhub webhook: "${k}" must be a string`);
    }
    return (v as string | null | undefined) ?? null;
  };
  const topic = str('topic');
  const action = str('action');
  if (b.barcodes != null && !Array.isArray(b.barcodes)) {
    throw new WebhookPayloadError('stubhub webhook: "barcodes" must be an array');
  }
  const embedded = b._embedded;
  if (embedded != null && (typeof embedded !== 'object' || Array.isArray(embedded))) {
    throw new WebhookPayloadError('stubhub webhook: "_embedded" must be an object');
  }
  return {
    topic,
    action,
    barcodes: (b.barcodes as unknown[] | null | undefined) ?? null,
    _links: b._links as HalLinks | undefined,
    _embedded: embedded as StubHubWebhookPayload['_embedded'],
    kind: normalizeTopic(topic),
  };
}
