// Gametime's sales notification webhook: when a listing sells, Gametime POSTs
// JSON (money in cents) to the configured URL with an Authorization header
// (Basic or Bearer, whichever was set up). It doesn't block or change the
// order; a non-2xx is only investigated on Gametime's side. The body has no
// status and no buyer email, so exos-marketplace-sales reads the purchase
// (GET /purchases?order_number=) before acting, as Gametime's guide asks.

import type { GametimeSaleNotification } from './types.ts';

/** Constant-time check of the whole Authorization header against the configured value. */
export function verifyGametimeWebhook(header: string | null, expected: string): boolean {
  if (!expected) return false;
  const got = header ?? '';
  let diff = got.length ^ expected.length;
  for (let i = 0; i < Math.max(got.length, expected.length); i++) diff |= (got.charCodeAt(i) || 0) ^ (expected.charCodeAt(i) || 0);
  return diff === 0;
}

export class GametimeWebhookError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'GametimeWebhookError';
  }
}

export function parseGametimeSaleNotification(body: unknown): GametimeSaleNotification {
  const b = body as Record<string, unknown> | null;
  if (!b || typeof b !== 'object') throw new GametimeWebhookError('not a Gametime sale notification');
  const id = b.id == null ? '' : String(b.id).trim();
  const source = b.source_id == null ? '' : String(b.source_id).trim();
  const qty = Number(b.quantity);
  if (!id || !source || !Number.isInteger(qty) || qty < 1) throw new GametimeWebhookError('not a Gametime sale notification');
  const num = (v: unknown) => (typeof v === 'number' && Number.isFinite(v) ? v : typeof v === 'string' && /^\d+$/.test(v) ? Number(v) : undefined);
  const str = (v: unknown) => (typeof v === 'string' ? v : v == null ? undefined : String(v));
  return {
    id, source_id: source, quantity: qty,
    unit_price: num(b.unit_price), payout: num(b.payout),
    event_id: str(b.event_id), event_name: str(b.event_name), event_date: str(b.event_date), venue: str(b.venue),
    section: str(b.section), row: str(b.row), fulfill_type: str(b.fulfill_type), deal: str(b.deal),
  };
}
