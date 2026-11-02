// Stripe payouts to promoters (mig 20261102150000, docs/payouts.md
// "Promoter payouts"). Pure: exos-promoter-payouts does the RPCs and the
// Stripe calls; vitest imports this file.
//
// The commission is funded from the organizer's own Stripe money: each order
// was paid to the organizer by a destination-charge transfer, so the job
// reverses part of those transfers (the funding lines the settle planned, at
// most the commission of that order and at most what the organizer still
// holds from it) and then transfers the total to the promoter's Express
// account. Every call carries a deterministic idempotency key, so a crashed
// or repeated send never moves money twice.

export type TransfersMode = 'dry-run' | 'live';

/** Money moves only with EXOS_PROMOTER_TRANSFERS exactly "on". */
export function transfersMode(env: (name: string) => string | undefined): TransfersMode {
  return env('EXOS_PROMOTER_TRANSFERS') === 'on' ? 'live' : 'dry-run';
}

export interface FundingLine {
  session_id: string;
  org_transfer_id: string;
  amount_cents: number;
  status: 'planned' | 'taken' | 'returned' | 'released';
  reversal_id: string | null;
}

export interface TransferClaim {
  payout_id: string;
  org_id: string;
  promoter_id: string;
  amount_cents: number;
  currency: string;
  destination: string | null;
  stripe_transfer_id: string | null;
  lines: FundingLine[];
}

export const reversalKey = (payoutId: string, sessionId: string) => `exos-pcf:${payoutId}:${sessionId}`;
export const transferKey = (payoutId: string) => `exos-pct:${payoutId}`;
export const returnKey = (payoutId: string) => `exos-pcr:${payoutId}`;

/**
 * What a send must do next, or why it can't. Refuses (never "fixes") a claim
 * whose lines don't add up to the payout, or that has no destination.
 */
export function sendPlan(c: TransferClaim):
  | { ok: true; reverse: FundingLine[]; transfer: { amount: number; currency: string; destination: string } }
  | { ok: false; error: string } {
  const amount = Math.trunc(Number(c.amount_cents));
  if (!Number.isFinite(amount) || amount <= 0) return { ok: false, error: 'nothing to send' };
  if (!c.destination || !/^acct_[A-Za-z0-9]{1,64}$/.test(c.destination)) return { ok: false, error: 'promoter has no payout account' };
  const live = c.lines.filter((l) => l.status === 'planned' || l.status === 'taken');
  const funded = live.reduce((n, l) => n + Math.trunc(Number(l.amount_cents)), 0);
  if (funded !== amount) return { ok: false, error: `funding ${funded} does not equal the payout ${amount}` };
  if (live.some((l) => !/^tr_[A-Za-z0-9]{1,64}$/.test(l.org_transfer_id) || l.amount_cents <= 0)) {
    return { ok: false, error: 'bad funding line' };
  }
  return {
    ok: true,
    reverse: live.filter((l) => l.status === 'planned'),
    transfer: { amount, currency: (c.currency || 'usd').toLowerCase(), destination: c.destination },
  };
}

/** On cancel: the amount already taken from the organizer, to send back. */
export function amountToReturn(lines: FundingLine[]): number {
  return lines.filter((l) => l.status === 'taken').reduce((n, l) => n + Math.trunc(Number(l.amount_cents)), 0);
}

/** A Stripe error as a short line for the ledger (no request ids or keys). */
export function stripeErrorText(e: unknown): string {
  const any = e as { code?: string; message?: string; type?: string } | null;
  const msg = String(any?.message ?? 'Stripe error').replace(/(sk|rk)_(live|test)_[A-Za-z0-9]+/g, '[key]');
  return `${any?.code ? `${any.code}: ` : ''}${msg}`.slice(0, 300);
}

export interface StripeTransferLite { id: string; destination?: string | null; metadata?: Record<string, string> | null }
export interface StripeReversalLite { id: string; metadata?: Record<string, string> | null }

/**
 * Before a payout whose send was started may be cancelled: what Stripe really
 * did. `transfers` are the transfers in the payout's transfer_group;
 * `reversals` the reversals listed on each funding line's order transfer.
 * The promoter transfer counts only if it went to the promoter's account and
 * carries this payout's id (the organizer-return transfer doesn't count).
 * A found transfer means the money went out: mark it sent, never cancel.
 */
export function reconcileDecision(
  c: Pick<TransferClaim, 'payout_id' | 'destination' | 'lines'>,
  transfers: StripeTransferLite[],
  reversals: Record<string, StripeReversalLite[]>,
): { action: 'mark_sent' | 'allow_cancel'; transferId: string | null; reversals: { session_id: string; reversal_id: string }[] } {
  const ours = (m?: Record<string, string> | null) => m?.exos_promoter_payout_id === c.payout_id;
  const tr = transfers.find((t) => ours(t.metadata) && t.metadata?.exos_return !== '1'
    && !!c.destination && t.destination === c.destination && /^tr_[A-Za-z0-9]{1,64}$/.test(t.id));
  const found: { session_id: string; reversal_id: string }[] = [];
  for (const l of c.lines) {
    if (l.status !== 'planned') continue;
    const r = (reversals[l.session_id] ?? []).find((x) => ours(x.metadata) && x.metadata?.exos_session_id === l.session_id
      && /^trr_[A-Za-z0-9]{1,64}$/.test(x.id));
    if (r) found.push({ session_id: l.session_id, reversal_id: r.id });
  }
  return { action: tr ? 'mark_sent' : 'allow_cancel', transferId: tr?.id ?? null, reversals: found };
}

/** Retry a ledger write a few times; true once it reports success. */
export async function durably(write: () => Promise<boolean>, tries = 3, waitMs = 250): Promise<boolean> {
  for (let i = 0; i < tries; i++) {
    try { if (await write()) return true; } catch { /* retry */ }
    if (i < tries - 1) await new Promise((r) => setTimeout(r, waitMs * (i + 1)));
  }
  return false;
}

export type ClaimAnswer =
  | ({ ok: true; purpose: 'send' | 'reconcile' | 'cancel'; lease_token: string; attempt?: number; needs_reconcile?: boolean } & TransferClaim)
  | { ok: false; error: string };

/**
 * What to do with an exos_promoter_transfer_claim answer. A send whose earlier
 * attempt was never reconciled, or a cancel after a started send, must look
 * Stripe up first (reconcileDecision); anything else refused stops.
 */
export function claimAction(a: ClaimAnswer): 'proceed' | 'reconcile_first' | { stop: string } {
  if ('error' in a) return a.error === 'needs_reconcile' ? 'reconcile_first' : { stop: a.error };
  if (!/^[0-9a-f-]{36}$/i.test(String(a.lease_token ?? ''))) return { stop: 'no lease' };
  if (a.purpose !== 'send' && a.needs_reconcile) return 'reconcile_first';
  return 'proceed';
}
