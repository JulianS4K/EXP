// Reads behind the organizer money screens (event "Money" tab, org Payouts
// page). Read-only; RLS keeps every read to org owner / manager / finance.
// The math is in ./settlement.ts. A view that doesn't exist yet (an older
// schema) comes back as `null` from the primary read, and the screens hide.

import { supabase } from './supabase';
import { fetchAllPages } from './door/roster';
import type {
  CommissionMoneyRow,
  MarketplaceMoneyRow,
  OrderMoneyRow,
  PayoutLineRow,
  PayoutRow,
} from './settlement';

const PAGE = 1000;

const ORDER_MONEY_COLS =
  'session_id, status, currency, created_at, fulfilled_at, gross_cents, tax_cents, application_fee_cents, ' +
  'exos_fee_cents, card_fee_est_cents, card_fee_actual_cents, fee_free, organizer_net_cents, refunded_cents, ' +
  'payment_intent, transfer_id';

const MARKETPLACE_MONEY_COLS =
  'order_id, channel, external_order_id, quantity, currency, proceeds, exos_fee, organizer_net, state';

export interface EventMoneyData {
  orders: OrderMoneyRow[];
  marketplace: MarketplaceMoneyRow[];
  commissions: CommissionMoneyRow[];
}

/** Read a range-paged table; `null` if the read fails (missing view, no access). */
async function readAll<T>(read: (from: number, to: number) => PromiseLike<{ data: unknown; error: unknown }>, key: (r: T) => string): Promise<T[] | null> {
  try {
    return await fetchAllPages<T>(async (from, to) => {
      const { data, error } = await read(from, to);
      if (error) throw error;
      return (data as T[] | null) ?? [];
    }, key, PAGE);
  } catch (e) {
    console.warn('money read unavailable (non-fatal):', (e as { message?: string })?.message ?? e);
    return null;
  }
}

/**
 * Everything the event settlement needs, or null when exos_order_money can't
 * be read (not on this schema yet, or the caller isn't finance-capable). The
 * other sources are optional: missing → empty.
 */
export async function getEventMoney(eventId: string): Promise<EventMoneyData | null> {
  const orders = await readAll<OrderMoneyRow>(
    (from, to) => supabase.from('exos_order_money').select(ORDER_MONEY_COLS).eq('event_id', eventId).order('created_at', { ascending: true }).range(from, to),
    (r) => r.session_id,
  );
  if (orders === null) return null;

  const [quantities, marketplace, commissions] = await Promise.all([
    readAll<{ session_id: string; quantity: number | null }>(
      (from, to) => supabase.from('exos_checkout_sessions').select('session_id, quantity').eq('event_id', eventId).in('status', ['fulfilled', 'partially_refunded', 'refunded']).range(from, to),
      (r) => r.session_id,
    ),
    readAll<MarketplaceMoneyRow>(
      (from, to) => supabase.from('exos_marketplace_order_money').select(MARKETPLACE_MONEY_COLS).eq('event_id', eventId).range(from, to),
      (r) => r.order_id,
    ),
    readAll<CommissionMoneyRow & { id: string }>(
      (from, to) => supabase.from('exos_promoter_commissions').select('id, status, commission_cents, currency').eq('event_id', eventId).range(from, to),
      (r) => r.id,
    ),
  ]);

  const qty = new Map((quantities ?? []).map((q) => [q.session_id, q.quantity]));
  return {
    orders: orders.map((o) => ({ ...o, quantity: qty.has(o.session_id) ? qty.get(o.session_id) ?? null : null })),
    marketplace: marketplace ?? [],
    commissions: commissions ?? [],
  };
}

export interface OrgPayoutsData {
  payouts: PayoutRow[];
  lines: PayoutLineRow[];
}

/** The org's marketplace payouts and their lines; null when unreadable. */
export async function getOrgPayouts(orgId: string): Promise<OrgPayoutsData | null> {
  const payouts = await readAll<PayoutRow>(
    (from, to) => supabase.from('exos_org_payouts')
      .select('id, currency, amount, status, stripe_transfer_id, error, created_at, updated_at, sent_at')
      .eq('org_id', orgId).order('created_at', { ascending: false }).range(from, to),
    (r) => r.id,
  );
  if (payouts === null) return null;
  if (payouts.length === 0) return { payouts, lines: [] };

  // Lines with their marketplace order and event; plain lines if the embed fails.
  const embedded = await readAll<any>(
    (from, to) => supabase.from('exos_org_payout_lines')
      .select('id, payout_id, order_id, kind, amount, created_at, order:exos_marketplace_orders(channel, external_order_id, event_id, event:exos_events(name))')
      .eq('org_id', orgId).range(from, to),
    (r) => r.id,
  );
  const rows = embedded ?? (await readAll<any>(
    (from, to) => supabase.from('exos_org_payout_lines').select('id, payout_id, order_id, kind, amount, created_at').eq('org_id', orgId).range(from, to),
    (r) => r.id,
  )) ?? [];
  const lines: PayoutLineRow[] = rows.map((r: any) => ({
    id: r.id,
    payout_id: r.payout_id,
    order_id: r.order_id,
    kind: r.kind,
    amount: r.amount,
    created_at: r.created_at ?? null,
    channel: r.order?.channel ?? null,
    external_order_id: r.order?.external_order_id ?? null,
    event_id: r.order?.event_id ?? null,
    event_name: r.order?.event?.name ?? null,
  }));
  return { payouts, lines };
}
