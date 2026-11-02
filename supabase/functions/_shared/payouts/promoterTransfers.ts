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
