// The Stripe client as stripeTerminal.ts's TerminalStripe (mig 20261107130000).
// Deno only (exos-pos, stripe-webhook): the flows themselves are tested in
// vitest against fakes of the same interface.

import Stripe from "https://esm.sh/stripe@16?target=deno";
import type { IntentLike, ReaderActionLike, TerminalStripe } from "./stripeTerminal.ts";

/** A Stripe client for the card-at-the-door calls: 15 s per call, no automatic retries (the flows retry by key). */
export function posStripe(key: string): Stripe {
  return new Stripe(key, {
    httpClient: Stripe.createFetchHttpClient(),
    apiVersion: "2024-06-20",
    timeout: 15_000,
    maxNetworkRetries: 0,
  });
}

export function terminalStripe(stripe: Stripe): TerminalStripe {
  const pi = (p: Promise<Stripe.PaymentIntent>) => p as unknown as Promise<IntentLike>;
  return {
    createPaymentIntent: (params, o) =>
      pi(stripe.paymentIntents.create(params as unknown as Stripe.PaymentIntentCreateParams, { idempotencyKey: o.idempotencyKey })),
    retrievePaymentIntent: (id) => pi(stripe.paymentIntents.retrieve(id)),
    capturePaymentIntent: (id, o) => pi(stripe.paymentIntents.capture(id, {}, { idempotencyKey: o.idempotencyKey })),
    cancelPaymentIntent: (id) => pi(stripe.paymentIntents.cancel(id)),
    processPaymentIntent: async (readerId, paymentIntent) =>
      await stripe.terminal.readers.processPaymentIntent(readerId, { payment_intent: paymentIntent }) as unknown as Record<string, unknown>,
    cancelReaderAction: async (readerId) => await stripe.terminal.readers.cancelAction(readerId) as unknown as Record<string, unknown>,
    retrieveReader: async (readerId) => {
      const r = await stripe.terminal.readers.retrieve(readerId);
      if ((r as { deleted?: boolean }).deleted) return { id: readerId, action: null };
      return { id: r.id, action: ((r as Stripe.Terminal.Reader).action ?? null) as unknown as ReaderActionLike | null };
    },
    createRefund: async (params, o) => {
      const r = await stripe.refunds.create(params as Stripe.RefundCreateParams, { idempotencyKey: o.idempotencyKey });
      return { id: r.id, status: r.status, failure_reason: r.failure_reason ?? null };
    },
  };
}
