// Stripe dispute -> the fields exos_record_dispute_event stores (mig
// 20261001101000). Pure, no imports (structural types only), so Deno
// (stripe-webhook) and vitest (src/lib/disputes.test.ts) both load it.
//
// What is kept: amounts, the dispute fee (from the dispute's own balance
// transactions), reason, status, the evidence deadline and whether evidence
// was submitted, the charge id, livemode. What is NOT kept: `evidence` (it
// carries the buyer's name, email, IP, billing / shipping address and
// uploaded files), `metadata`, and anything else not on the allowlist below.
// The SQL function re-applies the same allowlist to `raw`.

type Id = string | { id?: string | null } | null | undefined;

export interface BalanceTxnLike {
  id?: string | null;
  amount?: number | null;
  fee?: number | null;
  net?: number | null;
  type?: string | null;
  reporting_category?: string | null;
  created?: number | null;
}

export interface DisputeLike {
  id?: string | null;
  amount?: number | null;
  currency?: string | null;
  reason?: string | null;
  status?: string | null;
  created?: number | null;
  livemode?: boolean | null;
  is_charge_refundable?: boolean | null;
  network_reason_code?: string | null;
  charge?: Id;
  payment_intent?: Id;
  balance_transactions?: BalanceTxnLike[] | null;
  evidence_details?: {
    due_by?: number | null;
    has_evidence?: boolean | null;
    past_due?: boolean | null;
    submission_count?: number | null;
  } | null;
  payment_method_details?: { type?: string | null; card?: { brand?: string | null } | null } | null;
  // evidence, metadata: deliberately not read.
}

export interface DisputeFields {
  dispute_id: string;
  charge_id: string | null;
  payment_intent: string | null;
  amount_cents: number | null;
  currency: string;
  reason: string | null;
  status: string;
  /** Stripe's dispute fee net of any fee returned (sum of the dispute's balance-transaction fees, never below 0); null when Stripe sent no balance transactions yet. */
  fee_cents: number | null;
  evidence_due_by: string | null;
  evidence_submitted: boolean;
  livemode: boolean | null;
  raw: Record<string, unknown>;
}

// Stripe object ids: a short lowercase prefix, "_", then base62.
const STRIPE_ID = /^[a-z]{2,5}_[A-Za-z0-9]{1,200}$/;

function idOf(v: Id): string | null {
  const s = typeof v === "string" ? v : v && typeof v.id === "string" ? v.id : null;
  return s && STRIPE_ID.test(s) ? s : null;
}
function int(v: unknown): number | null {
  return typeof v === "number" && Number.isInteger(v) ? v : null;
}
function isoFromUnix(v: unknown): string | null {
  const n = int(v);
  return n != null && n > 0 ? new Date(n * 1000).toISOString() : null;
}
function shortText(v: unknown, max = 60): string | null {
  return typeof v === "string" && v.trim() !== "" ? v.trim().slice(0, max) : null;
}

/** True for a Stripe dispute id (dp_… / du_…). */
export function isDisputeId(v: unknown): v is string {
  return typeof v === "string" && /^(dp|du)_[A-Za-z0-9]{1,200}$/.test(v);
}

/** The dispute fee Stripe charged, net of any returned: sum of fees on the dispute's balance transactions, floored at 0. */
export function disputeFeeCents(txns: BalanceTxnLike[] | null | undefined): number | null {
  if (!Array.isArray(txns) || txns.length === 0) return null;
  let sum = 0;
  let seen = false;
  for (const t of txns) {
    const f = int(t?.fee);
    if (f == null) continue;
    sum += f;
    seen = true;
  }
  return seen ? Math.max(0, sum) : null;
}

/** Map a Stripe Dispute to exos_record_dispute_event's arguments. Throws only when the id or status is unusable. */
export function disputeFields(d: DisputeLike): DisputeFields {
  if (!isDisputeId(d.id)) throw new Error("dispute id missing or malformed");
  const status = typeof d.status === "string" ? d.status.trim().toLowerCase() : "";
  if (!/^[a-z_]{1,40}$/.test(status)) throw new Error("dispute status missing or malformed");
  const ed = d.evidence_details ?? null;
  const submissions = int(ed?.submission_count) ?? 0;
  const txns = Array.isArray(d.balance_transactions) ? d.balance_transactions : [];
  const raw: Record<string, unknown> = {
    id: d.id,
    object: "dispute",
    amount: int(d.amount),
    currency: shortText(d.currency, 10)?.toLowerCase() ?? null,
    reason: shortText(d.reason),
    status,
    created: int(d.created),
    livemode: typeof d.livemode === "boolean" ? d.livemode : null,
    is_charge_refundable: typeof d.is_charge_refundable === "boolean" ? d.is_charge_refundable : null,
    network_reason_code: shortText(d.network_reason_code, 20),
    charge: idOf(d.charge),
    payment_intent: idOf(d.payment_intent),
    evidence_details: ed
      ? {
        due_by: int(ed.due_by),
        has_evidence: ed.has_evidence === true,
        past_due: ed.past_due === true,
        submission_count: submissions,
      }
      : null,
    balance_transactions: txns.slice(0, 10).map((t) => ({
      id: idOf(t?.id),
      amount: int(t?.amount),
      fee: int(t?.fee),
      net: int(t?.net),
      type: shortText(t?.type, 40),
      reporting_category: shortText(t?.reporting_category, 40),
      created: int(t?.created),
    })),
    payment_method_type: shortText(d.payment_method_details?.type, 30),
    card_brand: shortText(d.payment_method_details?.card?.brand, 30),
  };
  return {
    dispute_id: d.id,
    charge_id: idOf(d.charge),
    payment_intent: idOf(d.payment_intent),
    amount_cents: int(d.amount),
    currency: (shortText(d.currency, 10) ?? "usd").toLowerCase(),
    reason: shortText(d.reason),
    status,
    fee_cents: disputeFeeCents(txns),
    evidence_due_by: isoFromUnix(ed?.due_by),
    // Submitted = Stripe counted a submission, or the dispute moved to review
    // (which only happens after evidence goes in). has_evidence alone is a draft.
    evidence_submitted: submissions > 0 || status === "under_review" || status === "warning_under_review",
    livemode: typeof d.livemode === "boolean" ? d.livemode : null,
    raw,
  };
}

/** Stripe dashboard page for a dispute (the platform account's; test-mode path when livemode is false). */
export function stripeDisputeUrl(disputeId: string, livemode: boolean | null | undefined = true): string | null {
  if (!isDisputeId(disputeId)) return null;
  return `https://dashboard.stripe.com/${livemode === false ? "test/" : ""}disputes/${disputeId}`;
}
