// Stripe's payouts from an organizer's connected account to their bank (mig
// 20261111130000, docs/journal.md "Payouts"). exos-reconcile-stripe lists
// them with the Stripe-Account header (GET /v1/payouts: a read on the
// platform's own Connect relationship, never a write) and records them with
// exos_stripe_org_payouts_record; a paid payout posts Dr bank / Cr Stripe
// clearing. Pure; vitest imports it (src/lib/payouts/orgPayouts.test.ts).

/** What exos_stripe_org_payouts_record takes for one payout. */
export interface OrgPayoutRow {
  id: string;
  amount: number;
  currency: string;
  status: "pending" | "in_transit" | "paid" | "failed" | "canceled";
  method: "standard" | "instant";
  automatic: boolean | null;
  failure_code: string | null;
  created: string;
  arrival_date: string | null;
}

/** The fields of a Stripe Payout this reads. */
export interface PayoutLike {
  id?: unknown;
  object?: unknown;
  amount?: unknown;
  currency?: unknown;
  status?: unknown;
  method?: unknown;
  automatic?: unknown;
  failure_code?: unknown;
  created?: unknown;
  arrival_date?: unknown;
}

const STATUSES = new Set(["pending", "in_transit", "paid", "failed", "canceled"]);

function iso(unix: unknown): string | null {
  return typeof unix === "number" && Number.isFinite(unix) && unix > 0 ? new Date(Math.trunc(unix) * 1000).toISOString() : null;
}

/** One Stripe Payout as a row to record; null when it isn't one Exos can use. */
export function orgPayoutRow(p: PayoutLike): OrgPayoutRow | null {
  if (!p || typeof p !== "object") return null;
  if (typeof p.id !== "string" || !/^po_[A-Za-z0-9]{1,64}$/.test(p.id)) return null;
  if (p.object !== undefined && p.object !== "payout") return null;
  if (typeof p.amount !== "number" || !Number.isInteger(p.amount) || Math.abs(p.amount) > 100_000_000_000) return null;
  if (typeof p.currency !== "string" || !/^[a-zA-Z]{3}$/.test(p.currency)) return null;
  if (typeof p.status !== "string" || !STATUSES.has(p.status)) return null;
  const created = iso(p.created);
  if (!created) return null;
  const failure = typeof p.failure_code === "string" && /^[a-z0-9_]{1,60}$/.test(p.failure_code) ? p.failure_code : null;
  return {
    id: p.id,
    amount: p.amount,
    currency: p.currency.toLowerCase(),
    status: p.status as OrgPayoutRow["status"],
    method: p.method === "instant" ? "instant" : "standard",
    automatic: typeof p.automatic === "boolean" ? p.automatic : null,
    failure_code: failure,
    created,
    arrival_date: iso(p.arrival_date),
  };
}

/** The org's connected account id from exos_org_secrets.payments; null when there's none. */
export function connectedAccountId(payments: unknown): string | null {
  const id = payments && typeof payments === "object" ? (payments as { connectedAccountId?: unknown }).connectedAccountId : null;
  return typeof id === "string" && /^acct_[A-Za-z0-9]{1,64}$/.test(id) ? id : null;
}

/**
 * Payouts are listed from `lookbackDays` before the reconcile window: Stripe
 * marks a payout paid (or failed) days after it was created, so a payout is
 * read again until its status settles. Unix seconds, for `created`.
 */
export const PAYOUT_LOOKBACK_DAYS = 14;
export function payoutCreatedRange(fromIso: string, toIso: string, lookbackDays = PAYOUT_LOOKBACK_DAYS): { gte: number; lt: number } {
  const days = Number.isFinite(lookbackDays) ? Math.min(Math.max(Math.trunc(lookbackDays), 0), 60) : PAYOUT_LOOKBACK_DAYS;
  const from = Date.parse(fromIso) - days * 86_400_000;
  return { gte: Math.floor(from / 1000), lt: Math.floor(Date.parse(toIso) / 1000) };
}

/** EXOS_RECONCILE_PAYOUTS: anything but "off" lists the payouts (they are reads). */
export function payoutsSyncEnabled(env: (name: string) => string | undefined): boolean {
  return (env("EXOS_RECONCILE_PAYOUTS") ?? "").trim().toLowerCase() !== "off";
}
