// GoTickets webhooks. Webhooks are created through the API (POST
// /rest/webhooks: a type and a target URL). GoTickets documents the payload
// (WebhookBasePayload: id, externalTicketId, section, row, payout,
// quantity, deliveryMethod, createTime, type) but no signature or auth
// header. So Exos registers a target URL carrying a secret token of its own
// (exos-marketplace-sales?channel=gotickets&token=…, GOTICKETS_WEBHOOK_TOKEN)
// and never acts on the payload itself: it reads the sale back from the API
// (GET /rest/sales/{id}) and records that.
//
// Where the token may arrive, in order of preference:
//   1. the `X-Exos-Webhook-Token` header (register the webhook with it when
//      GoTickets lets the target carry custom headers);
//   2. `Authorization: Bearer <token>`;
//   3. the `token` query parameter (the fallback for a bare target URL).
// Prefer a header: a query-string secret can end up in proxy and platform
// access logs. Exos itself never logs the request URL.

import type { GoTicketsWebhookPayload } from './types.ts';

/** Constant-time check of the token in the target URL. */
export function verifyGoTicketsWebhookToken(got: string | null, expected: string): boolean {
  if (!expected) return false;
  const g = got ?? '';
  let diff = g.length ^ expected.length;
  for (let i = 0; i < Math.max(g.length, expected.length); i++) diff |= (g.charCodeAt(i) || 0) ^ (expected.charCodeAt(i) || 0);
  return diff === 0;
}

export const GOTICKETS_WEBHOOK_TOKEN_HEADER = 'x-exos-webhook-token';

/** The webhook token from the request: header first, then the query string. */
export function goticketsWebhookToken(headers: Pick<Headers, 'get'>, url: URL): string | null {
  const h = headers.get(GOTICKETS_WEBHOOK_TOKEN_HEADER)?.trim();
  if (h) return h;
  const auth = headers.get('authorization')?.trim() ?? '';
  const m = /^Bearer\s+(.+)$/i.exec(auth);
  if (m) return m[1].trim();
  return url.searchParams.get('token');
}

export class GoTicketsWebhookError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'GoTicketsWebhookError';
  }
}

export function parseGoTicketsWebhook(body: unknown): GoTicketsWebhookPayload {
  const b = body as Record<string, unknown> | null;
  const id = b?.id == null ? '' : String(b.id).trim();
  const type = typeof b?.type === 'string' ? b.type : '';
  if (!id || !type || !/^\d+$/.test(id)) throw new GoTicketsWebhookError('not a GoTickets webhook');
  return {
    id,
    type,
    externalTicketId: typeof b!.externalTicketId === 'string' ? b!.externalTicketId : undefined,
    quantity: typeof b!.quantity === 'number' ? b!.quantity : undefined,
    payout: typeof b!.payout === 'number' ? b!.payout : undefined,
    createTime: typeof b!.createTime === 'string' ? b!.createTime : undefined,
  };
}

/** Webhook types that mean "read this sale again". */
export const GOTICKETS_SALE_WEBHOOKS = new Set(['SALE', 'ORDER_CANCELLED', 'PURCHASE_CONFIRMED', 'PURCHASE_FULFILLED', 'RETRANSFER', 'ORDER_EMAIL_ADDRESS_UPDATED', 'HOLD']);
