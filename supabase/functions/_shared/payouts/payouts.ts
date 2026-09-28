// The organizer side of marketplace money (mig 20260929070000,
// docs/payouts.md). Pure: the edge function exos-payouts does the reads,
// the RPCs and the Stripe call.
//
//   tevoRemittanceFor   what TEvo reports it paid on an Exos order, as a
//                       remittance to record. Reported, not confirmed: TEvo
//                       marks an EvoPay payment "completed" when it's
//                       applied to the order, not when cash lands.
//   connectTransfer     the Stripe Connect transfer for a planned payout:
//                       platform balance -> the org's connected account.
//   payoutsMode         dry-run unless EXOS_PAYOUTS_LIVE is exactly "true".

import { summarizeTevoPayments, type ExosTevoPayment } from '../marketplace/tevo/payments.ts';

export type PayoutsMode = 'dry-run' | 'live';

export function payoutsMode(env: (name: string) => string | undefined): PayoutsMode {
  return env('EXOS_PAYOUTS_LIVE') === 'true' ? 'live' : 'dry-run';
}

export interface RemittanceInput {
  channel: string;
  external_id: string;
  amount: number;
  currency: string;
  source: 'marketplace_api' | 'statement' | 'manual';
  reference?: string;
  received_at?: string | null;
  allocations: Array<{ external_order_id: string; amount: number }>;
}

/**
 * A TEvo order's payments as a remittance for the Exos order: once TEvo has
 * settled payments on it (and no refund or unknown state), Exos is owed the
 * order's proceeds (the gross less TEvo's 3%). null = nothing to record yet.
 */
export function tevoRemittanceFor(
  order: { external_order_id: string; proceeds: number | string | null },
  payments: ReadonlyArray<ExosTevoPayment>,
): RemittanceInput | null {
  const proceeds = Number(order.proceeds);
  if (!Number.isFinite(proceeds) || proceeds <= 0) return null;
  const sum = summarizeTevoPayments(payments);
  if (sum.paid_cents <= 0 || sum.refunded_cents > 0 || sum.unknown_states.length) return null;
  const settled = payments.filter((p) => ['completed', 'captured'].includes((p.state ?? '').toLowerCase()) && !p.is_refund);
  const latest = settled.map((p) => p.updated_at ?? p.created_at).filter(Boolean).sort().pop() ?? null;
  return {
    channel: 'evo',
    external_id: `evo-order-${order.external_order_id}`,
    amount: Math.round(proceeds * 100) / 100,
    currency: 'USD',
    source: 'marketplace_api',
    reference: settled.map((p) => `payment ${p.payment_id}`).join(', ').slice(0, 200),
    received_at: latest,
    allocations: [{ external_order_id: order.external_order_id, amount: Math.round(proceeds * 100) / 100 }],
  };
}

export interface PlannedPayout {
  id: string;
  org_id: string;
  currency: string;
  amount: number | string;
  idempotency_key: string;
}

export interface ConnectTransfer {
  params: {
    amount: number;
    currency: string;
    destination: string;
    transfer_group: string;
    description: string;
    metadata: Record<string, string>;
  };
  idempotencyKey: string;
}

/** The Stripe transfer for a payout, in minor units. Throws on anything that isn't safe to send. */
export function connectTransfer(p: PlannedPayout, destination: string | null | undefined): ConnectTransfer {
  const cents = Math.round(Number(p.amount) * 100);
  if (!Number.isInteger(cents) || cents <= 0) throw new Error(`payout ${p.id}: amount must be positive`);
  if (!destination || !/^acct_[A-Za-z0-9]+$/.test(destination)) throw new Error(`payout ${p.id}: the org has no connected Stripe account`);
  if (!/^[A-Za-z]{3}$/.test(p.currency)) throw new Error(`payout ${p.id}: bad currency ${p.currency}`);
  return {
    params: {
      amount: cents,
      currency: p.currency.toLowerCase(),
      destination,
      transfer_group: `exos-payout-${p.id}`,
      description: 'Exos marketplace sales payout',
      metadata: { exos_payout_id: p.id, exos_org_id: p.org_id },
    },
    idempotencyKey: p.idempotency_key,
  };
}
