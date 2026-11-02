// Stripe Instant Payouts for an organizer's connected account (mig
// 20261102150000, docs/payouts.md "Instant payouts"). Pure; vitest imports it.
//
// Off unless EXOS_INSTANT_PAYOUTS is exactly "on". Stripe charges the fee to
// the connected account's balance on top of the payout; Exos shows an
// estimate first (EXOS_INSTANT_PAYOUT_FEE_BPS, default 150 = 1.5%, with a
// minimum EXOS_INSTANT_PAYOUT_FEE_MIN_CENTS, default 50). Stripe's own number
// on the payout is the real one.

export interface InstantFeeConfig { bps: number; minCents: number }

export function instantEnabled(env: (name: string) => string | undefined): boolean {
  return env('EXOS_INSTANT_PAYOUTS') === 'on';
}

export function instantFeeConfig(env: (name: string) => string | undefined): InstantFeeConfig {
  const num = (v: string | undefined) => (v === undefined || v.trim() === '' ? NaN : Number(v));
  const bps = num(env('EXOS_INSTANT_PAYOUT_FEE_BPS'));
  const min = num(env('EXOS_INSTANT_PAYOUT_FEE_MIN_CENTS'));
  return {
    bps: Number.isInteger(bps) && bps >= 0 && bps <= 1000 ? bps : 150,
    minCents: Number.isInteger(min) && min >= 0 && min <= 10000 ? min : 50,
  };
}

/** The fee estimate for an instant payout of `amount` cents, rounded up. */
export function instantFeeCents(amount: number, cfg: InstantFeeConfig): number {
  const a = Math.trunc(Number(amount));
  if (!Number.isFinite(a) || a <= 0) return 0;
  return Math.max(cfg.minCents, Math.ceil((a * cfg.bps) / 10000));
}

/** The largest payout whose amount + fee fits in `available` cents (0 if none). */
export function maxInstantPayout(available: number, cfg: InstantFeeConfig): number {
  const av = Math.trunc(Number(available));
  if (!Number.isFinite(av) || av <= cfg.minCents) return 0;
  // amount + max(min, ceil(amount * bps / 10000)) <= av
  let amount = Math.floor((av * 10000) / (10000 + cfg.bps));
  while (amount > 0 && amount + instantFeeCents(amount, cfg) > av) amount--;
  return Math.max(amount, 0);
}

export interface InstantBalance { currency: string; amount_cents: number }

/** Stripe's balance.instant_available, normalized (positive amounts only). */
export function instantAvailable(balance: { instant_available?: Array<{ amount?: number; currency?: string }> } | null): InstantBalance[] {
  return (balance?.instant_available ?? [])
    .map((b) => ({ currency: String(b.currency ?? '').toLowerCase(), amount_cents: Math.trunc(Number(b.amount ?? 0)) }))
    .filter((b) => /^[a-z]{3}$/.test(b.currency) && b.amount_cents > 0);
}

/** Validate a send request against the quote rules. */
export function checkInstantRequest(
  req: { amount_cents: unknown; currency: unknown; idempotency_key: unknown },
  available: InstantBalance[],
  cfg: InstantFeeConfig,
): { ok: true; amount: number; currency: string; fee: number; key: string } | { ok: false; error: string } {
  const amount = Number(req.amount_cents);
  const currency = String(req.currency ?? '').toLowerCase();
  const key = String(req.idempotency_key ?? '');
  if (!/^[A-Za-z0-9_-]{8,80}$/.test(key)) return { ok: false, error: 'idempotency_key must be 8-80 letters, digits, - or _' };
  if (!Number.isInteger(amount) || amount < 100) return { ok: false, error: 'amount must be at least 100 cents' };
  const bal = available.find((b) => b.currency === currency);
  if (!bal) return { ok: false, error: 'no instant balance in that currency' };
  if (amount > maxInstantPayout(bal.amount_cents, cfg)) return { ok: false, error: 'more than the instant balance allows after the fee' };
  return { ok: true, amount, currency, fee: instantFeeCents(amount, cfg), key };
}
