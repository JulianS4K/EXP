// Reads behind the organizer money screens (event "Money" tab, org Payouts
// page). Read-only; RLS keeps every read to org owner / manager / finance.
// The math is in ./settlement.ts. A view that doesn't exist yet (an older
// schema) comes back as `null` from the primary read, and the screens hide.

import { supabase } from './supabase';
import { fetchAllPages } from './door/roster';
import type {
  CommissionMoneyRow,
  DisputeMoneyRow,
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
// exos_order_fee_details (mig 20261021160000), beside exos_order_money.
const ORDER_FEE_COLS = 'session_id, card_fee_charged_cents, stripe_fee_currency, refunded_fee_kept_cents';

const MARKETPLACE_MONEY_COLS =
  'order_id, channel, external_order_id, quantity, currency, proceeds, exos_fee, organizer_net, state';

export interface EventMoneyData {
  orders: OrderMoneyRow[];
  marketplace: MarketplaceMoneyRow[];
  commissions: CommissionMoneyRow[];
  /** Chargebacks on the event (mig 20261001101000); [] before it. */
  disputes: DisputeMoneyRow[];
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

  type FeeRow = Pick<OrderMoneyRow, 'session_id' | 'card_fee_charged_cents' | 'stripe_fee_currency' | 'refunded_fee_kept_cents'>;
  const [quantities, marketplace, commissions, disputes, fees] = await Promise.all([
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
    readAll<DisputeMoneyRow & { id: string }>(
      (from, to) => supabase.from('exos_disputes')
        .select('id, session_id, status, amount_cents, fee_cents, recovery_status, recovery_candidate_cents, created_at')
        .eq('event_id', eventId).range(from, to),
      (r) => r.id,
    ),
    // Optional (an older schema has no such view): the card fee is then
    // application fee - Exos fee from the order row, and refunds are taken
    // as having returned the fee (the default).
    readAll<FeeRow>(
      (from, to) => supabase.from('exos_order_fee_details').select(ORDER_FEE_COLS).eq('event_id', eventId).range(from, to),
      (r) => r.session_id,
    ),
  ]);

  const qty = new Map((quantities ?? []).map((q) => [q.session_id, q.quantity]));
  const fee = new Map((fees ?? []).map((f) => [f.session_id, f]));
  return {
    orders: orders.map((o) => {
      const f = fee.get(o.session_id);
      return {
        ...o,
        quantity: qty.has(o.session_id) ? qty.get(o.session_id) ?? null : null,
        ...(f ? { card_fee_charged_cents: f.card_fee_charged_cents, stripe_fee_currency: f.stripe_fee_currency, refunded_fee_kept_cents: f.refunded_fee_kept_cents } : {}),
      };
    }),
    marketplace: marketplace ?? [],
    commissions: commissions ?? [],
    disputes: disputes ?? [],
  };
}

/**
 * The org's fee-free end date (exos_org_billing, owner / manager / finance by
 * RLS). undefined = couldn't read it (other roles, older schema); null = no row.
 */
export async function getOrgFeeFreeUntil(orgId: string): Promise<string | null | undefined> {
  try {
    const { data, error } = await supabase.from('exos_org_billing').select('fee_free_until').eq('org_id', orgId).maybeSingle();
    if (error) throw error;
    return (data as { fee_free_until: string | null } | null)?.fee_free_until ?? null;
  } catch (e) {
    console.warn('fee terms unavailable (non-fatal):', (e as { message?: string })?.message ?? e);
    return undefined;
  }
}

export interface CheckoutReminderStats {
  enabled: boolean;
  sent: number;
  recovered: number;
  recoveredCents: number;
}

/** Abandoned-checkout reminders for one event (mig 20261021120000); null when unavailable. */
export async function getCheckoutReminderStats(eventId: string): Promise<CheckoutReminderStats | null> {
  try {
    const { data, error } = await supabase.rpc('exos_event_checkout_reminder_stats', { p_event_id: eventId });
    if (error) throw error;
    const j = (data ?? {}) as Record<string, unknown>;
    return {
      enabled: j.enabled !== false,
      sent: Number(j.sent) || 0,
      recovered: Number(j.recovered) || 0,
      recoveredCents: Number(j.recovered_cents) || 0,
    };
  } catch (e) {
    console.warn('checkout reminder stats unavailable (non-fatal):', (e as { message?: string })?.message ?? e);
    return null;
  }
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
