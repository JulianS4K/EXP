// The four ways to fund a promoter's commission (mig 20261104190000,
// docs/payouts.md "Commission methods"). Pure: exos-checkout, stripe-webhook,
// exos-refund (via refundRun / organizer-refund), exos-reconcile-checkouts and
// exos-promoter-payouts import it; vitest imports it too. No imports.
//
//   clawback       destination charge as before; at settle time the
//                  commission is reversed out of the organizer's transfers
//                  (the promoter wedge, promoterTransfers.ts).
//   split_at_sale  separate charges and transfers: the charge stays on the
//                  platform (no transfer_data) with a transfer_group per
//                  order; after the holdback Exos transfers the organizer's
//                  share and each promoter's commission with
//                  source_transaction = that charge.
//   platform_fee   destination charge whose application_fee_amount also
//                  carries the commission; after the holdback Exos transfers
//                  it to the promoter from the platform balance.
//   manual         the ledger only (the default).
//
// Checkout charges the destination way, byte for byte as before, unless a
// commission plan says otherwise; a plan is only asked for when one of the
// platform switches is on.

export type CommissionMethod = "clawback" | "split_at_sale" | "platform_fee" | "manual";
export type ChargeModel = "destination" | "split";

export const COMMISSION_METHODS: readonly CommissionMethod[] = ["clawback", "split_at_sale", "platform_fee", "manual"];

export interface CommissionEnv {
  /** EXOS_SPLIT_AT_SALE=on: split-at-sale checkouts and their transfers. */
  splitAtSale: boolean;
  /** EXOS_PLATFORM_FEE_COMMISSIONS=on: commissions inside the Exos fee, and their transfers. */
  platformFeeCommissions: boolean;
}

/** Each switch is on only when set to exactly "on" (default off). */
export function commissionEnv(env: (name: string) => string | undefined): CommissionEnv {
  return {
    splitAtSale: env("EXOS_SPLIT_AT_SALE") === "on",
    platformFeeCommissions: env("EXOS_PLATFORM_FEE_COMMISSIONS") === "on",
  };
}

/** Checkout asks the database for a plan only when a switch could change the charge. */
export function needsCommissionPlan(e: CommissionEnv): boolean {
  return e.splitAtSale || e.platformFeeCommissions;
}

/** What exos_commission_checkout_plan answers (and exos_record_commission_plan stores). */
export interface CommissionPlan {
  method: CommissionMethod;
  source: string;
  promoter_id: string | null;
  charge_model: ChargeModel;
  application_fee_cents: number;
  commission_fee_cents: number;
  quote: unknown[];
  transfer_group: string | null;
}

const intOr0 = (v: unknown) => (typeof v === "number" && Number.isInteger(v) && v >= 0 ? v : 0);

/**
 * A plan from the RPC, or null when it doesn't hold together (then checkout
 * charges the destination way as before). A split plan needs its transfer
 * group; only platform_fee carries a commission in the fee.
 */
export function parsePlan(x: unknown): CommissionPlan | null {
  if (!x || typeof x !== "object") return null;
  const o = x as Record<string, unknown>;
  const method = o.method as CommissionMethod;
  if (!COMMISSION_METHODS.includes(method)) return null;
  const charge = o.charge_model === "split" ? "split" : o.charge_model === "destination" ? "destination" : null;
  if (!charge || (charge === "split") !== (method === "split_at_sale")) return null;
  const group = typeof o.transfer_group === "string" && /^exos-order-[0-9a-f-]{36}$/.test(o.transfer_group) ? o.transfer_group : null;
  if (charge === "split" && !group) return null;
  const fee = intOr0(o.commission_fee_cents);
  if (method !== "platform_fee" && fee !== 0) return null;
  return {
    method, source: String(o.source ?? ""), promoter_id: typeof o.promoter_id === "string" ? o.promoter_id : null,
    charge_model: charge, application_fee_cents: intOr0(o.application_fee_cents), commission_fee_cents: fee,
    quote: Array.isArray(o.quote) ? o.quote : [], transfer_group: charge === "split" ? group : null,
  };
}

/** Does this plan charge differently from today's destination charge? */
export function planChangesCharge(p: CommissionPlan | null): boolean {
  return !!p && (p.charge_model === "split" || p.commission_fee_cents > 0);
}

/**
 * Stripe Checkout's payment_intent_data for the order.
 *   no plan / destination  { application_fee_amount: fee, transfer_data }  (unchanged)
 *   platform_fee           { application_fee_amount: fee + commission, transfer_data }
 *   split                  { transfer_group }  (the charge stays on the platform)
 */
export function paymentIntentData(
  p: CommissionPlan | null,
  base: { applicationFeeCents: number; destination: string },
): { application_fee_amount?: number; transfer_data?: { destination: string }; transfer_group?: string } {
  if (p && p.charge_model === "split" && p.transfer_group) return { transfer_group: p.transfer_group };
  const extra = p && p.method === "platform_fee" ? p.commission_fee_cents : 0;
  return { application_fee_amount: base.applicationFeeCents + extra, transfer_data: { destination: base.destination } };
}

/** Extra Checkout metadata, only for orders charged a new way (none otherwise). */
export function checkoutChargeMetadata(p: CommissionPlan | null): Record<string, string> {
  if (!planChangesCharge(p)) return {};
  return p!.charge_model === "split"
    ? { exos_charge_model: "split", exos_commission_method: p!.method }
    : { exos_charge_model: "destination", exos_commission_method: p!.method, exos_commission_fee_cents: String(p!.commission_fee_cents) };
}

/** How an order was charged, from its Checkout metadata (absent: destination). */
export function chargeModelFromMetadata(md: Record<string, string> | null | undefined): ChargeModel {
  return md?.exos_charge_model === "split" ? "split" : "destination";
}

/**
 * The Connect flags for a refund.
 *   destination: pull the refunded share back from the organizer
 *     (reverse_transfer) and give back the fee in proportion
 *     (refund_application_fee; EXOS_REFUND_KEEP_PLATFORM_FEE may keep it,
 *     except when the fee carries a promoter commission: then it always
 *     goes back, or the organizer would pay a commission on a refund).
 *   split: neither; nothing has been transferred or taken as a fee on the
 *     charge itself. The shares are recomputed (refund before the
 *     transfer) or trued up (after it) in SQL.
 */
export function refundFlags(
  model: ChargeModel,
  opts: { keepPlatformFee?: boolean; commissionInFee?: boolean } = {},
): { reverse_transfer?: true; refund_application_fee?: boolean } {
  if (model === "split") return {};
  return { reverse_transfer: true, refund_application_fee: opts.commissionInFee ? true : !opts.keepPlatformFee };
}

// --- The money maths (mirrors the SQL; tests pin both) ---------------------

const int = (n: number) => (Number.isFinite(n) ? Math.trunc(n) : 0);

/**
 * A split order now (_exos_split_entitlement): net = charge - refunds (0 once
 * a dispute is lost); fee = the Exos fee less its refunded share (floor);
 * orgShare = net - fee - commission still standing, never below 0.
 */
export function splitShares(o: {
  amountCents: number; refundedCents: number; applicationFeeCents: number; commissionCents: number; lostDispute?: boolean;
}): { net: number; fee: number; commission: number; orgShare: number } {
  const amount = Math.max(int(o.amountCents), 0);
  const refunded = Math.min(Math.max(int(o.refundedCents), 0), amount);
  const lost = !!o.lostDispute;
  const net = lost ? 0 : amount - refunded;
  const appFee = Math.max(int(o.applicationFeeCents), 0);
  const fee = lost || amount === 0 ? 0 : appFee - Math.floor((appFee * refunded) / amount);
  const commission = Math.max(int(o.commissionCents), 0);
  return { net, fee, commission, orgShare: Math.max(net - fee - commission, 0) };
}

/**
 * What an organizer owes after their split share went out (the true-up):
 * the share planned less the share now. Negative: Exos owes them.
 */
export function trueUpCents(plannedShare: number, nowShare: number): number {
  return int(plannedShare) - int(nowShare);
}

/**
 * platform_fee: the commission the fee still holds for an order after
 * refunds (_exos_fee_plan_promoter). Stripe refunds that share of the
 * application fee; rounding up what went back keeps Exos from paying out
 * more than it holds.
 */
export function feeHeldCents(commissionFeeCents: number, amountCents: number, refundedCents: number, lostDispute = false): number {
  const fee = Math.max(int(commissionFeeCents), 0);
  const amount = Math.max(int(amountCents), 0);
  if (lostDispute || amount === 0) return 0;
  const refunded = Math.min(Math.max(int(refundedCents), 0), amount);
  return fee - Math.ceil((fee * refunded) / amount);
}

/** The application fee Stripe is asked for: the Exos fee plus any commission inside it. */
export function applicationFeeWithCommission(exosFeeCents: number, commissionCents: number): number {
  return Math.max(int(exosFeeCents), 0) + Math.max(int(commissionCents), 0);
}

/**
 * The organizer's next split transfer (_exos_split_plan_order): their share
 * less what they owe (never below 0), or plus what Exos owes them (at most
 * this order's fee, so the transfer still fits the charge). The rest carries
 * forward. owed > 0: the organizer owes Exos.
 */
export function netOrganizerShare(share: number, owed: number, feeCap: number): { amount: number; netted: number; carry: number } {
  const s = Math.max(int(share), 0);
  const d = int(owed);
  const take = d > 0 ? Math.min(d, s) : d < 0 ? -Math.min(-d, Math.max(int(feeCap), 0)) : 0;
  return { amount: s - take, netted: take, carry: d - take };
}

/**
 * A promoter's payout by Exos (_exos_ct_pay_promoter): whole netting lines,
 * oldest first, while they fit in what is payable (the commission less any
 * shortfall). Returns how many lines were applied and the amount sent.
 */
export function nettedPayout(commissionCents: number, shortfallCents: number, linesOwed: number[]): {
  cap: number; netted: number; applied: number; amount: number;
} {
  const cap = Math.max(int(commissionCents) - Math.max(int(shortfallCents), 0), 0);
  let netted = 0;
  let applied = 0;
  for (const l of linesOwed) {
    const owed = Math.max(int(l), 0);
    if (netted + owed > cap) break;
    netted += owed;
    applied++;
  }
  return { cap, netted, applied, amount: cap - netted };
}

/** The ordered quote at checkout: one commission per ticket (what the fee collects). */
export function quoteTotal(quote: unknown[]): number {
  return quote.reduce<number>((n, q) => n + intOr0((q as { commission_cents?: unknown })?.commission_cents), 0);
}

// --- Exos-made transfers (exos_commission_transfers) -----------------------

export type CtKind = "split_org" | "split_promoter" | "fee_promoter";

/** What exos_ct_claim answers when ok. */
export interface CtClaim {
  id: string;
  lease_token: string;
  purpose: "send" | "reconcile" | "cancel";
  needs_reconcile?: boolean;
  kind: CtKind;
  org_id: string;
  promoter_id: string | null;
  session_id: string | null;
  payout_id: string | null;
  amount_cents: number;
  currency: string;
  destination: string | null;
  source_charge_id: string | null;
  transfer_group: string;
  stripe_transfer_id: string | null;
}

export type CtClaimAnswer = ({ ok: true } & CtClaim) | { ok: false; error: string };

/** One deterministic Stripe idempotency key per transfer row. */
export const ctTransferKey = (id: string) => `exos-ct:${id}`;

/** Money moves for a kind only with its platform switch on; otherwise a dry run. */
export function ctLive(kind: CtKind, e: CommissionEnv): boolean {
  return kind === "fee_promoter" ? e.platformFeeCommissions : e.splitAtSale;
}

/** What to do with a claim answer (same rules as promoterTransfers.claimAction). */
export function ctClaimAction(a: CtClaimAnswer): "proceed" | "reconcile_first" | { stop: string } {
  if ("error" in a) return a.error === "needs_reconcile" ? "reconcile_first" : { stop: a.error };
  if (!/^[0-9a-f-]{36}$/i.test(String(a.lease_token ?? ""))) return { stop: "no lease" };
  if (a.purpose !== "send" && a.needs_reconcile) return "reconcile_first";
  return "proceed";
}

/**
 * The Stripe transfer for a claimed row, or why not. A split transfer is
 * tied to its order's charge (source_transaction) and order group; a fee
 * transfer comes from the platform balance. Refuses, never "fixes".
 */
export function ctTransferParams(c: CtClaim):
  | { ok: true; params: { amount: number; currency: string; destination: string; transfer_group: string; source_transaction?: string; metadata: Record<string, string> } }
  | { ok: false; error: string } {
  const amount = Math.trunc(Number(c.amount_cents));
  if (!Number.isFinite(amount) || amount <= 0) return { ok: false, error: "nothing to send" };
  if (!c.destination || !/^acct_[A-Za-z0-9]{1,64}$/.test(c.destination)) return { ok: false, error: "no payout account" };
  if (!/^exos-[a-z]+-[0-9a-f-]{36}$/.test(c.transfer_group ?? "")) return { ok: false, error: "bad transfer group" };
  const split = c.kind === "split_org" || c.kind === "split_promoter";
  if (split && !/^(ch|py)_[A-Za-z0-9]{1,64}$/.test(c.source_charge_id ?? "")) return { ok: false, error: "no source charge" };
  const metadata: Record<string, string> = { exos_ct_id: c.id, exos_kind: c.kind, exos_org_id: c.org_id };
  if (c.promoter_id) metadata.exos_promoter_id = c.promoter_id;
  if (c.session_id) metadata.exos_session_id = c.session_id;
  if (c.payout_id) metadata.exos_promoter_payout_id = c.payout_id;
  return {
    ok: true,
    params: {
      amount, currency: (c.currency || "usd").toLowerCase(), destination: c.destination, transfer_group: c.transfer_group,
      ...(split ? { source_transaction: c.source_charge_id! } : {}),
      metadata,
    },
  };
}

/**
 * Before a retried send or a cancel: did Stripe already make this transfer?
 * Only one in the row's transfer group carrying its id and going to its
 * destination counts (an order's group also holds its other shares).
 */
export function ctReconcileDecision(
  c: Pick<CtClaim, "id" | "destination">,
  transfers: { id: string; destination?: string | null; metadata?: Record<string, string> | null }[],
): string | null {
  const t = transfers.find((x) => x.metadata?.exos_ct_id === c.id && !!c.destination && x.destination === c.destination
    && /^tr_[A-Za-z0-9]{1,64}$/.test(x.id));
  return t?.id ?? null;
}

/** How long one /run may keep starting transfers (each is bounded on its own). */
export const RUN_BUDGET_MS = 100_000;
/** At most this many transfers per /run. */
export const RUN_MAX_TRANSFERS = 10;
