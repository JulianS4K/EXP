// SeatGeek Seller Direct webhook notifications (the "Webhook Notifications"
// guide). SeatGeek POSTs JSON to one configured URL with
// `Authorization: Bearer {token we chose}` and an envelope:
//   { metadata: { notification_type, seller_id, notification_id,
//                 notification_generated_at, schema_version: 1 },
//     data: [ ...items ] }   (always a list; batched notifications carry many)
// It needs a 2xx within 10 seconds, retries 3 times 1 second apart, then
// drops the notification; repeated failures trip a circuit breaker.
// Setup is by request to SeatGeek (URL, token, types, streaming/batching).
// Pure: parsing and routing only.

export const SEATGEEK_NOTIFICATION_TYPES = [
  'ping',
  'order.created',
  'order.retransfer',
  'order.fulfillment.error',
  'order.broken',
  'listing.event.inactive',
  'listing.visibility',
  'listing.normalization.status',
  'listing.normalization.status.changed',
] as const;
export type SeatGeekNotificationType = (typeof SEATGEEK_NOTIFICATION_TYPES)[number];

export interface SeatGeekNotification {
  metadata: {
    notification_type: string;
    seller_id?: number;
    notification_id: string;
    notification_generated_at?: string;
    schema_version: number;
  };
  data: unknown[];
}

/** Constant-time check of `Authorization: Bearer <token>` against our configured token. */
export function verifySeatGeekWebhook(header: string | null, expectedToken: string): boolean {
  if (!expectedToken) return false;
  const got = header ?? '';
  const want = `Bearer ${expectedToken}`;
  let diff = got.length ^ want.length;
  for (let i = 0; i < Math.max(got.length, want.length); i++) diff |= (got.charCodeAt(i) || 0) ^ (want.charCodeAt(i) || 0);
  return diff === 0;
}

export class SeatGeekWebhookError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'SeatGeekWebhookError';
  }
}

/**
 * Parse the envelope. Only schema_version 1 is understood (others are
 * ignored, as the guide asks). `data` is normalized to a list: the
 * order.fulfillment.error example sends a single object.
 */
export function parseSeatGeekNotification(body: unknown): SeatGeekNotification | null {
  const b = body as { metadata?: Record<string, unknown>; data?: unknown } | null;
  const m = b?.metadata;
  if (!m || typeof m.notification_type !== 'string' || typeof m.notification_id !== 'string') {
    throw new SeatGeekWebhookError('not a SeatGeek notification');
  }
  if (Number(m.schema_version) !== 1) return null;
  const data = Array.isArray(b!.data) ? b!.data : b!.data == null ? [] : [b!.data];
  return {
    metadata: {
      notification_type: m.notification_type,
      seller_id: typeof m.seller_id === 'number' ? m.seller_id : undefined,
      notification_id: m.notification_id,
      notification_generated_at: typeof m.notification_generated_at === 'string' ? m.notification_generated_at : undefined,
      schema_version: 1,
    },
    data,
  };
}

export type SeatGeekWebhookRoute =
  /** Orders to run through record + fulfil (order.created, order.broken as cancelled). */
  | { kind: 'orders'; orders: unknown[] }
  /** Needs a person: listing hidden / event inactive / fulfilment error / retransfer. */
  | { kind: 'attention'; items: unknown[] }
  | { kind: 'ignore' };

export function routeSeatGeekNotification(n: SeatGeekNotification): SeatGeekWebhookRoute {
  switch (n.metadata.notification_type) {
    case 'order.created':
      return { kind: 'orders', orders: n.data };
    case 'order.broken':
      // Terminal on SeatGeek's side: it can't be fulfilled any more.
      return { kind: 'orders', orders: n.data.map((o) => ({ ...(o as object), status: 'broken' })) };
    case 'order.retransfer':
    case 'order.fulfillment.error':
    case 'listing.event.inactive':
    case 'listing.visibility':
      return { kind: 'attention', items: n.data };
    default:
      // ping, normalization status (informational), unknown types
      return { kind: 'ignore' };
  }
}
