// Payment methods offered on a ticket checkout's Stripe page (exos-checkout).
//
// Only methods that confirm at once: the cart hold lasts the session's 30
// minutes + 10, and a payment that settles days later would land on seats that
// may be gone. Apple Pay and Google Pay come with "card".
//
// Link (Stripe's saved-wallet one-tap, the one that shows inside Instagram /
// Facebook in-app browsers where Apple Pay usually doesn't): Link pays with a
// saved card or, in the US, a bank account through Instant Bank Payments,
// which Stripe confirms instantly and guarantees (docs.stripe.com/payments/
// link/instant-bank-payments: "Payment confirmation: Instant"). Link would
// fall back to slow ACH only if "us_bank_account" were offered too ("If you've
// enabled ACH Direct Debit ... Link doesn't present Instant Bank Payments"),
// so that type, and every other delayed method, is never in this list.
//
// Platform switch EXOS_STRIPE_LINK: on unless set to "off".

export type CheckoutMethod = "card" | "link" | "cashapp";

/** Delayed-notification types Checkout must never offer on a ticket order. */
export const DELAYED_METHODS: readonly string[] = [
  "us_bank_account", "ach_debit", "acss_debit", "bacs_debit", "sepa_debit", "au_becs_debit",
  "customer_balance", "boleto", "oxxo", "konbini", "sofort",
];

export function linkEnabled(env: (k: string) => string | undefined): boolean {
  return (env("EXOS_STRIPE_LINK") ?? "").trim().toLowerCase() !== "off";
}

/** payment_method_types for checkout.sessions.create (API 2024-06-20). */
export function checkoutPaymentMethodTypes(o: { cashApp: boolean; link: boolean }): CheckoutMethod[] {
  const out: CheckoutMethod[] = ["card"];
  if (o.link) out.push("link");
  if (o.cashApp) out.push("cashapp");
  return out;
}

/**
 * Stripe refused one of the listed payment method types (e.g. Link switched
 * off in the platform's Dashboard). The caller retries once without Link, so a
 * Dashboard setting can never take checkout down.
 */
export function isPaymentMethodTypeRejection(e: unknown): boolean {
  if (!e || typeof e !== "object") return false;
  const x = e as { type?: unknown; param?: unknown; raw?: { param?: unknown } };
  const param = typeof x.param === "string" ? x.param : typeof x.raw?.param === "string" ? x.raw.param : "";
  return x.type === "StripeInvalidRequestError" && param.startsWith("payment_method_types");
}
