// Which checkout sessions are Exos's, and which ever reached Stripe. Pure, no
// imports, so Deno and vitest can both load it.
//
//   stripe-webhook             a checkout.session event for a session Exos has
//                              no row for (a payment link, another product on
//                              the same Stripe account) is acknowledged and
//                              ignored: a 500 makes Stripe retry it for days.
//   exos-reconcile-checkouts   a free order (free_<uuid>, amount 0) was never
//                              a Stripe session: nothing to look up or refund.

/** exos-checkout puts these on every Stripe session it creates. */
export function hasExosMetadata(metadata: Record<string, unknown> | null | undefined): boolean {
  return !!metadata && typeof metadata.exos_event_id === "string" && metadata.exos_event_id !== "";
}

/** A free order recorded by exos-checkout without Stripe (no money, no Stripe session). */
export function isFreeOrder(row: { session_id: string; amount_cents?: number | null }): boolean {
  return row.session_id.startsWith("free_") || (row.amount_cents != null && row.amount_cents <= 0);
}
