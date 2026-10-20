// Paid checkout is switched on by building the bundle with the Stripe
// publishable key (docs/payments-go-live.md). Without it, buyers see paid
// tiers as "Coming soon" and only free tickets can be claimed.
export function paymentsEnabled(): boolean {
  return !!(import.meta as { env?: { VITE_STRIPE_PUBLISHABLE_KEY?: string } }).env?.VITE_STRIPE_PUBLISHABLE_KEY;
}

/**
 * Paid tiers on an org whose Stripe Connect can't take payments yet: buyers
 * would hit "payments not set up" at checkout. `ready` null = unknown (the
 * check failed or isn't deployed): don't warn on a guess.
 */
export function paidNeedsConnect(
  prices: Array<number | string | null | undefined>,
  ready: boolean | null,
  platformOn: boolean = paymentsEnabled(),
): boolean {
  return platformOn && ready === false && hasPaidPrice(prices);
}

/** True when any of these prices is above zero. */
export function hasPaidPrice(prices: Array<number | string | null | undefined>): boolean {
  return prices.some((p) => {
    const n = typeof p === 'number' ? p : parseFloat(p ?? '');
    return Number.isFinite(n) && n > 0;
  });
}
