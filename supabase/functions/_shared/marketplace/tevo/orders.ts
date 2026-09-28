// Ticket Evolution orders: which kind, whether it may be accepted, and which
// Exos listing it sold from. Pure.
//
// Two kinds (HOWTO: Automate TEvo Order Processing):
//   * a sale to TEvo: buyer.type = Office and buyer.id = 6 (most sales);
//   * a sale to a Client of a TEvo-powered site: buyer.type = Client. Those
//     may be screened by Riskified: fraud_check_status null = not screened,
//     pending = wait (a fraud_response_received webhook follows each
//     update), approved = go. Nothing is accepted before that.
//
// The account can carry broker orders; only items whose ticket group
// carries an Exos listing id ("ex…", ../listingIds.ts) are Exos's. Which
// ticket-group field holds it depends on how the listing is sent to TEvo
// (not documented yet), so every string field of the ticket group is checked.

import { isExosListingId } from '../listingIds.ts';
import type { TevoOrder, TevoOrderItem } from './types.ts';

export const TEVO_OFFICE_BUYER_ID = 6;

export type TevoOrderKind = 'sale_to_tevo' | 'sale_to_client' | 'unknown';

export function orderKind(o: TevoOrder): TevoOrderKind {
  const t = String(o.buyer?.type ?? '');
  if (t === 'Office' && Number(o.buyer?.id) === TEVO_OFFICE_BUYER_ID) return 'sale_to_tevo';
  if (t === 'Client') return 'sale_to_client';
  return 'unknown';
}

export type TevoFraudGate = { ok: true } | { ok: false; wait: boolean; reason: string };

/** May this order be accepted now? Only Client sales are screened. */
export function fraudGate(o: TevoOrder): TevoFraudGate {
  const kind = orderKind(o);
  if (kind === 'unknown') return { ok: false, wait: false, reason: 'not a sale to TEvo or to a Client' };
  if (kind === 'sale_to_tevo') return { ok: true };
  const s = o.fraud_check_status ?? null;
  if (s === null) return { ok: true };
  if (s === 'approved') return { ok: true };
  if (s === 'pending') return { ok: false, wait: true, reason: 'waiting for the Riskified fraud check' };
  return { ok: false, wait: false, reason: `fraud check ${String(s)}` };
}

/** The Exos listing id on an item's ticket group, or null (a broker listing). */
export function exosListingRef(item: TevoOrderItem | undefined): string | null {
  const tg = item?.ticket_group;
  if (!tg || typeof tg !== 'object') return null;
  for (const v of Object.values(tg)) {
    if (typeof v === 'string' && isExosListingId(v.trim())) return v.trim();
  }
  return null;
}

/** The buyer's email on a Client sale (TEvo's own purchases carry none), lower-cased, or null. */
export function orderEmail(o: TevoOrder): string | null {
  const e = o.buyer?.email_address;
  const s = String(typeof e === 'object' && e ? e.address ?? '' : e ?? '').trim().toLowerCase();
  return s && s.includes('@') ? s : null;
}

/**
 * An order as Exos stores it (exos_marketplace_orders.raw): the buyer's and
 * the shipments' personal details dropped, ids and money kept.
 */
export function stripTevoOrder(o: TevoOrder): unknown {
  if (!o || typeof o !== 'object') return o;
  const { buyer, shipments, ...rest } = o;
  return {
    ...rest,
    buyer: buyer ? { type: buyer.type, id: buyer.id } : undefined,
    shipments: Array.isArray(shipments) ? shipments.map((s) => ({ id: s.id, type: s.type, state: s.state })) : undefined,
  };
}
