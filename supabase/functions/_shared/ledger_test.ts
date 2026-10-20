// deno test supabase/functions/_shared/ledger_test.ts
// Ledger P1 fixes (mig 20261021160000; usage simulation 2026-10-19 round 2):
// the pure parts the edge functions use. src/lib/{feeActuals,reconcile}.test.ts
// cover the same modules under vitest.
import { hasExosMetadata, isFreeOrder } from "./checkoutSession.ts";
import { feeActualsFromCharge, recordFeeActuals, type FeeDb, type FeeStripe } from "./feeActuals.ts";
import { reconcile, sameAmount, type StripeTxnRow } from "./reconcile.ts";

function check(cond: boolean, msg: string) {
  if (!cond) throw new Error(msg);
}

Deno.test("stripe-webhook: only sessions exos-checkout created carry its metadata", () => {
  check(hasExosMetadata({ exos_event_id: "1ed9e000-0000-0000-0000-0000000000e2", exos_tier_id: "t" }), "exos session");
  check(!hasExosMetadata({}), "payment link (no metadata)");
  check(!hasExosMetadata(null), "null metadata");
  check(!hasExosMetadata({ exos_event_id: "" }), "empty event id");
});

Deno.test("exos-reconcile-checkouts: free orders never reached Stripe", () => {
  check(isFreeOrder({ session_id: "free_0b5f3c3e-1111-2222-3333-444444444444", amount_cents: 0 }), "free_ id");
  check(isFreeOrder({ session_id: "free_x" }), "free_ id without amount");
  check(isFreeOrder({ session_id: "cs_test_1", amount_cents: 0 }), "amount 0");
  check(!isFreeOrder({ session_id: "cs_test_1", amount_cents: 9000 }), "paid Stripe session");
});

Deno.test("fee actuals: an EUR charge on a USD platform keeps the fee's currency", async () => {
  const charge = {
    id: "ch_e1", amount: 4998, currency: "eur", application_fee_amount: 325, application_fee: "fee_e1", transfer: "tr_e1",
    balance_transaction: { id: "txn_e1", fee: 95, net: 5303, currency: "usd", exchange_rate: 1.08 },
  };
  const a = feeActualsFromCharge(charge);
  check(a.stripe_fee_cents === 95 && a.stripe_fee_currency === "usd" && a.exchange_rate === 1.08, JSON.stringify(a));
  check(a.net_cents === Math.round(325 * 1.08) - 95, `net in USD: ${a.net_cents}`);

  const calls: { fn: string; args: Record<string, unknown> }[] = [];
  const q = { select: () => q, eq: () => q, maybeSingle: () => Promise.resolve({ data: { fees_recorded_at: null, application_fee_cents: 325 }, error: null }) };
  const db: FeeDb = {
    from: () => q,
    rpc: (fn, args) => {
      calls.push({ fn, args });
      return Promise.resolve({ data: true, error: null });
    },
  };
  const stripe: FeeStripe = { paymentIntents: { retrieve: () => Promise.resolve({ latest_charge: charge }) } };
  check(await recordFeeActuals(db, stripe, "cs_e1", "pi_e1", { log: () => {} }) === "recorded", "recorded");
  check(calls.map((c) => c.fn).join() === "exos_record_payment_fees,exos_record_payment_fee_currency", JSON.stringify(calls));
  check(calls[1].args.p_stripe_fee_currency === "usd" && calls[1].args.p_exchange_rate === 1.08, JSON.stringify(calls[1]));
});

Deno.test("reconcile: a correctly recorded EUR order raises no issue (sim S6)", () => {
  const MID = "2026-10-19T12:00:00.000Z";
  const txn: StripeTxnRow = {
    id: "txn_e1", type: "charge", reporting_category: "charge", amount_cents: Math.round(4998 * 1.08), fee_cents: 95,
    net_cents: Math.round(4998 * 1.08) - 95, currency: "usd", source_id: "ch_e1", payment_intent: "pi_e1",
    status: "available", created: MID, available_on: null, exchange_rate: 1.08,
  };
  const out = reconcile({
    txns: [txn],
    payments: [{
      session_id: "cs_e1", org_id: "org", payment_intent: "pi_e1", charge_id: "ch_e1", balance_txn_id: "txn_e1",
      amount_cents: 4998, currency: "eur", status: "succeeded", stripe_fee_cents: 95, stripe_fee_currency: "usd", created_at: MID,
    }],
    refunds: [], disputes: [], from: "2026-10-18T00:00:00.000Z", to: "2026-10-20T00:00:00.000Z",
  });
  check(out.issues.length === 0, JSON.stringify(out.issues));
  check(!sameAmount(4998, "eur", { amount_cents: 5398, currency: "usd", exchange_rate: null }), "no rate: no match");
});
