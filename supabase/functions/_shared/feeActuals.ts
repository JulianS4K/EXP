// What Stripe actually took on a checkout's charge, for exos_order_payments
// (mig 20260929131000, exos_record_payment_fees). stripe-webhook and
// exos-reconcile-checkouts retrieve the PaymentIntent with
// latest_charge.balance_transaction (and .transfer) expanded and hand the
// charge to feeActualsFromCharge. No imports (structural types only), so
// Deno and vitest can both load it.
//
// Destination charges: the charge lands on the platform, Stripe's fee is
// taken from the platform (balance_transaction.fee), and the organizer's
// share goes out as a transfer of amount - application_fee. So what Exos
// keeps on an order is application_fee - stripe_fee: that is net_cents.
//
// Currencies: the balance transaction is in the platform's settlement
// currency. An EUR charge on a USD platform lands converted (exchange_rate
// set) and its fee is in USD, so the fee is stored with its own currency
// (stripe_fee_currency) and the rate, and net_cents is in that currency (the
// application fee converted at the rate). mig 20261021160000.

type Id = string | { id?: string | null } | null | undefined;

export interface ChargeLike {
  id?: string | null;
  amount?: number | null;
  currency?: string | null;
  application_fee?: Id;
  application_fee_amount?: number | null;
  transfer?: Id;
  balance_transaction?: string | {
    id?: string | null;
    fee?: number | null;
    net?: number | null;
    currency?: string | null;
    exchange_rate?: number | null;
  } | null;
}

export interface FeeActuals {
  charge_id: string | null;
  balance_txn_id: string | null;
  stripe_fee_cents: number | null;
  /** The fee's currency (the balance transaction's), lower case; null if unknown. */
  stripe_fee_currency: string | null;
  /** Stripe's rate from the charge currency to stripe_fee_currency (null when none). */
  exchange_rate: number | null;
  application_fee_id: string | null;
  application_fee_cents: number | null;
  transfer_id: string | null;
  /** What the platform keeps: application fee - Stripe's fee, in stripe_fee_currency (null if unknown). */
  net_cents: number | null;
}

function idOf(v: Id): string | null {
  if (typeof v === "string") return v || null;
  return v && typeof v.id === "string" && v.id ? v.id : null;
}

function cents(v: unknown): number | null {
  return typeof v === "number" && Number.isInteger(v) ? v : null;
}

function currencyOf(v: unknown): string | null {
  return typeof v === "string" && /^[A-Za-z]{3}$/.test(v) ? v.toLowerCase() : null;
}

/**
 * Map a Stripe charge (balance_transaction expanded, or just its id) to the
 * fee columns. `fallbackApplicationFeeCents` is what checkout recorded, used
 * when the charge doesn't carry application_fee_amount.
 */
export function feeActualsFromCharge(
  charge: ChargeLike | null | undefined,
  fallbackApplicationFeeCents: number | null = null,
): FeeActuals {
  const bt = charge?.balance_transaction;
  const btObj = bt && typeof bt === "object" ? bt : null;
  const stripeFee = cents(btObj?.fee);
  const appFee = cents(charge?.application_fee_amount) ?? cents(fallbackApplicationFeeCents);
  const feeCur = currencyOf(btObj?.currency);
  const chargeCur = currencyOf(charge?.currency);
  const rate = typeof btObj?.exchange_rate === "number" && Number.isFinite(btObj.exchange_rate) && btObj.exchange_rate > 0
    ? btObj.exchange_rate
    : null;
  // The application fee is in the charge currency, Stripe's fee in the
  // settlement currency. Same currency: subtract. Converted: the application
  // fee at Stripe's rate first. Converted with no rate: unknown.
  const converted = feeCur !== null && chargeCur !== null && feeCur !== chargeCur;
  const appFeeInFeeCur = appFee == null ? null : !converted ? appFee : rate != null ? Math.round(appFee * rate) : null;
  return {
    charge_id: typeof charge?.id === "string" && charge.id ? charge.id : null,
    balance_txn_id: idOf(bt as Id),
    stripe_fee_cents: stripeFee,
    stripe_fee_currency: stripeFee != null ? feeCur : null,
    exchange_rate: rate,
    application_fee_id: idOf(charge?.application_fee),
    application_fee_cents: appFee,
    transfer_id: idOf(charge?.transfer),
    net_cents: appFeeInFeeCur != null && stripeFee != null ? appFeeInFeeCur - stripeFee : null,
  };
}

/** Resolve within `ms` or throw, so a slow Stripe read can't hold a webhook response open. */
export function withTimeout<T>(p: Promise<T>, ms: number, label = "timeout"): Promise<T> {
  let timer: ReturnType<typeof setTimeout> | undefined;
  const t = new Promise<never>((_, reject) => {
    timer = setTimeout(() => reject(new Error(`${label} after ${ms}ms`)), ms);
  });
  return Promise.race([p, t]).finally(() => clearTimeout(timer));
}

/** How long the webhook waits on Stripe for the fee read before giving up (the reconcile sweep fills it later). */
export const FEE_READ_TIMEOUT_MS = 5000;

// The slices of the Stripe and Supabase clients recordFeeActuals uses, so
// both functions can pass their real clients and vitest can pass fakes.
export interface FeeStripe {
  paymentIntents: {
    retrieve(id: string, params: { expand: string[] }): Promise<{ latest_charge?: string | ChargeLike | null }>;
  };
}
type DbResult = { data: unknown; error: { message?: string; code?: string } | null };
export interface FeeDb {
  // deno-lint-ignore no-explicit-any
  from(table: string): any;
  rpc(fn: string, args: Record<string, unknown>): PromiseLike<DbResult>;
}

export type FeeRecordOutcome = "recorded" | "already" | "no_payment" | "no_charge" | "skipped" | "error";

/**
 * Best effort, never throws: read what Stripe actually took on the
 * PaymentIntent's latest charge (balance_transaction expanded) and store it on
 * the payment row (exos_record_payment_fees, mig 20260929131000). Skips a
 * payment whose fees are already recorded, so a webhook replay costs no
 * Stripe call. A Stripe or database failure is logged and leaves the columns
 * NULL for exos-reconcile-checkouts to fill.
 */
export async function recordFeeActuals(
  sb: FeeDb,
  stripe: FeeStripe,
  sessionId: string,
  paymentIntent: string,
  opts: { timeoutMs?: number; log?: (msg: string, err?: unknown) => void; force?: boolean } = {},
): Promise<FeeRecordOutcome> {
  const log = opts.log ?? ((msg: string, err?: unknown) => console.error(msg, err ?? ""));
  try {
    const { data: pay, error: payErr } = await sb.from("exos_order_payments")
      .select("fees_recorded_at").eq("payment_intent", paymentIntent).maybeSingle();
    if (payErr) {
      // Most likely mig 20260929131000 isn't applied yet: nothing to write to.
      log(`fee actuals: payment lookup failed for ${sessionId} (skipped)`, payErr);
      return "skipped";
    }
    if (!pay) return "no_payment";
    if ((pay as { fees_recorded_at?: string | null }).fees_recorded_at && !opts.force) return "already";

    const intent = await withTimeout(
      stripe.paymentIntents.retrieve(paymentIntent, { expand: ["latest_charge.balance_transaction"] }),
      opts.timeoutMs ?? FEE_READ_TIMEOUT_MS,
      "stripe fee read",
    );
    const charge = intent.latest_charge && typeof intent.latest_charge === "object" ? intent.latest_charge : null;
    if (!charge) {
      log(`fee actuals: no charge on ${paymentIntent} for ${sessionId} yet`);
      return "no_charge";
    }
    const { data: sess } = await sb.from("exos_checkout_sessions")
      .select("application_fee_cents").eq("session_id", sessionId).maybeSingle();
    const recorded = (sess as { application_fee_cents?: number | null } | null)?.application_fee_cents ?? null;
    const a = feeActualsFromCharge(charge, recorded);
    const { error } = await sb.rpc("exos_record_payment_fees", {
      p_payment_intent: paymentIntent,
      p_charge_id: a.charge_id,
      p_balance_txn_id: a.balance_txn_id,
      p_stripe_fee_cents: a.stripe_fee_cents,
      p_application_fee_id: a.application_fee_id,
      p_application_fee_cents: a.application_fee_cents,
      p_transfer_id: a.transfer_id,
      p_net_cents: a.net_cents,
    });
    if (error) {
      log(`fee actuals: record failed for ${sessionId}`, error);
      return "error";
    }
    // The fee's currency + rate (mig 20261021160000). Without that migration
    // the function isn't there: the fee is recorded, just without them.
    if (a.stripe_fee_currency !== null || a.exchange_rate !== null) {
      const { error: curErr } = await sb.rpc("exos_record_payment_fee_currency", {
        p_payment_intent: paymentIntent,
        p_stripe_fee_currency: a.stripe_fee_currency,
        p_exchange_rate: a.exchange_rate,
      });
      if (curErr) log(`fee actuals: fee currency not recorded for ${sessionId}`, curErr);
    }
    return "recorded";
  } catch (e) {
    log(`fee actuals: stripe read failed for ${sessionId} (left for reconcile)`, e);
    return "error";
  }
}
