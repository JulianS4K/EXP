// Paid checkout is switched on by building the bundle with the Stripe
// publishable key (docs/payments-go-live.md). Without it, buyers see paid
// tiers as "Coming soon" and only free tickets can be claimed.
export function paymentsEnabled(): boolean {
  return !!(import.meta as { env?: { VITE_STRIPE_PUBLISHABLE_KEY?: string } }).env?.VITE_STRIPE_PUBLISHABLE_KEY;
}

/** True when any of these prices is above zero. */
export function hasPaidPrice(prices: Array<number | string | null | undefined>): boolean {
  return prices.some((p) => {
    const n = typeof p === 'number' ? p : parseFloat(p ?? '');
    return Number.isFinite(n) && n > 0;
  });
}
