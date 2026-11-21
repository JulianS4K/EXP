// exos-reconcile-stripe — daily reconciliation of the platform Stripe account
// against the Exos ledger (mig 20261001101000; money audit section 4 #6).
//
// Auth: cron secret (x-cron-secret) via the shared requireCronSecret, like
// exos-reconcile-checkouts. READ-ONLY at Stripe: it lists the platform's
// balance transactions and the connected accounts' payouts, and nothing
// else. It never creates, updates or refunds anything there.
//
// Each run:
//   1. Lists the platform account's balance transactions created in the last
//      N days (body {"days": N}, else EXOS_RECONCILE_DAYS, else 3; at most 90),
//      paginated, with the source expanded so a charge / refund carries its
//      PaymentIntent.
//   2. Stores them in exos_stripe_balance_txns (upsert on the txn id: a re-run
//      rewrites the same rows).
//   3. Reads the matching Exos rows (payments and refunds created in the
//      window, plus any the Stripe rows point at; disputes by id) and diffs
//      them (_shared/reconcile.ts): Stripe charges / refunds / dispute
//      movements missing in Exos, Exos payments / refunds missing in Stripe,
//      amount, currency, fee and status mismatches.
//   4. Records the findings with exos_reconcile_stripe_record: issues are
//      upserted per (kind, key), open issues inside the checked window that
//      weren't found are resolved, and the day's run row is written. Running
//      twice on one day changes nothing but timestamps.
//   5. (mig 20261111130000) Lists each connected account's payouts to its
//      bank (GET /v1/payouts with the Stripe-Account header: a read on the
//      platform's own Connect relationship) created from 14 days before the
//      window, and records them per org with exos_stripe_org_payouts_record
//      (the account must be the org's own; upsert on the payout id; status
//      only moves forward). A paid payout posts Dr bank / Cr Stripe clearing
//      to the journal, reversed if it fails later. The platform's balance
//      transactions never carry these: a destination charge's money is paid
//      out from the connected account. EXOS_RECONCILE_PAYOUTS=off skips it.
//      A failure here is reported and never fails the reconciliation.
//
// Payments are off in prod (no STRIPE_SECRET_KEY): the function answers 503
// "payments are switched off" and touches nothing.
//
// Secrets: CRON_SECRET, STRIPE_SECRET_KEY, SUPABASE_URL +
// SUPABASE_SERVICE_ROLE_KEY (platform-injected). Optional EXOS_RECONCILE_DAYS,
// EXOS_RECONCILE_PAYOUTS (off).
// Deploy with --no-verify-jwt (cron-secret auth). NOT scheduled: the daily
// line is in docs/payouts.md (a cron change needs operator permission).

import Stripe from "https://esm.sh/stripe@16?target=deno";
import { createClient, SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2";
import { requireCronSecret } from "../_shared/cron-auth.ts";
import {
  connectedAccountId,
  type OrgPayoutRow,
  orgPayoutRow,
  payoutCreatedRange,
  payoutsSyncEnabled,
} from "../_shared/payouts/orgPayouts.ts";
import {
  type ExosDisputeRow,
  type ExosPaymentRow,
  type ExosRefundRow,
  reconcile,
  reconcileWindow,
  type StripeTxnRow,
  txnRow,
} from "../_shared/reconcile.ts";

const stripeKey = Deno.env.get("STRIPE_SECRET_KEY") ?? "";

// Bounds per run: stop listing after this many transactions (a longer window
// than a day's volume allows should be split), and leave time to write.
const MAX_TXNS = 20_000;
const LIST_BUDGET_MS = 90_000;
const PAGE = 1000;
const IN_CHUNK = 100;
// Exos rows this close to either end of the window aren't checked for a
// missing Stripe movement (a charge a second before the window, its row a
// second after), and only issues inside the checked window are resolved.
const MARGIN_MS = 60 * 60 * 1000;
// Connected accounts' payouts (step 5): bounded per account and per run.
const MAX_PAYOUTS_PER_ORG = 1000;
const PAYOUT_BUDGET_MS = 60_000;

const PAYMENT_COLS =
  "session_id, org_id, payment_intent, charge_id, balance_txn_id, amount_cents, currency, status, stripe_fee_cents, created_at";
const REFUND_COLS = "session_id, org_id, refund_id, amount_cents, currency, status, created_at";

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } });
}

function chunks<T>(xs: T[], n: number): T[][] {
  const out: T[][] = [];
  for (let i = 0; i < xs.length; i += n) out.push(xs.slice(i, i + n));
  return out;
}

// deno-lint-ignore no-explicit-any
type Query = any;

/** Every row of a range-paged read; throws on a read error. */
async function readAll<T>(build: () => Query): Promise<T[]> {
  const out: T[] = [];
  for (let from = 0;; from += PAGE) {
    const { data, error } = await build().range(from, from + PAGE - 1);
    if (error) throw new Error(error.message ?? String(error));
    out.push(...((data ?? []) as T[]));
    if (!data || data.length < PAGE) return out;
  }
}

/** Rows where `col` is one of `ids`, in chunks. */
async function readIn<T>(sb: SupabaseClient, table: string, cols: string, col: string, ids: string[]): Promise<T[]> {
  const out: T[] = [];
  for (const c of chunks([...new Set(ids)], IN_CHUNK)) {
    const { data, error } = await sb.from(table).select(cols).in(col, c);
    if (error) throw new Error(`${table}.${col}: ${error.message}`);
    out.push(...((data ?? []) as T[]));
  }
  return out;
}

interface PayoutSyncStats {
  orgs: number;
  payouts: number;
  new: number;
  changed: number;
  skipped: number;
  failed_orgs: number;
  truncated: boolean;
  skipped_all?: boolean;
}

/**
 * Step 5: every connected account's payouts, read from Stripe (list only) and
 * recorded per org. Never throws: a failure is counted and logged.
 */
async function syncOrgPayouts(stripe: Stripe, sb: SupabaseClient, from: string, to: string): Promise<PayoutSyncStats> {
  const stats: PayoutSyncStats = { orgs: 0, payouts: 0, new: 0, changed: 0, skipped: 0, failed_orgs: 0, truncated: false };
  if (!payoutsSyncEnabled((k) => Deno.env.get(k))) return { ...stats, skipped_all: true };
  const started = Date.now();
  let orgs: { org_id: string; payments: unknown }[];
  try {
    orgs = await readAll<{ org_id: string; payments: unknown }>(() =>
      sb.from("exos_org_secrets").select("org_id, payments").not("payments", "is", null).order("org_id", { ascending: true })
    );
  } catch (e) {
    console.error("exos-reconcile-stripe: reading connected accounts failed", e);
    return { ...stats, failed_orgs: -1 };
  }
  const created = payoutCreatedRange(from, to);
  for (const o of orgs) {
    const acct = connectedAccountId(o.payments);
    if (!acct) continue;
    if (Date.now() - started > PAYOUT_BUDGET_MS) {
      stats.truncated = true;
      break;
    }
    stats.orgs++;
    try {
      // Read-only: the list call is the only Stripe request made for the account.
      const rows: OrgPayoutRow[] = [];
      const list = stripe.payouts.list({ created, limit: 100 }, { stripeAccount: acct });
      for await (const po of list) {
        const row = orgPayoutRow(po as unknown as Parameters<typeof orgPayoutRow>[0]);
        if (row) rows.push(row);
        if (rows.length >= MAX_PAYOUTS_PER_ORG) {
          stats.truncated = true;
          break;
        }
      }
      stats.payouts += rows.length;
      if (!rows.length) continue;
      const { data, error } = await sb.rpc("exos_stripe_org_payouts_record", {
        p_org_id: o.org_id,
        p_account_id: acct,
        p_payouts: rows,
      });
      if (error) throw new Error(error.message);
      const r = (data ?? {}) as { new?: number; changed?: number; skipped?: number };
      stats.new += r.new ?? 0;
      stats.changed += r.changed ?? 0;
      stats.skipped += r.skipped ?? 0;
    } catch (e) {
      stats.failed_orgs++;
      console.error(`exos-reconcile-stripe: payouts of org ${o.org_id} failed`, String((e as Error)?.message ?? e).slice(0, 300));
    }
  }
  return stats;
}

Deno.serve(async (req: Request): Promise<Response> => {
  if (req.method !== "POST") return new Response("Method Not Allowed", { status: 405 });
  const authErr = requireCronSecret(req);
  if (authErr) return authErr;
  if (!stripeKey) return json({ error: "payments are switched off" }, 503);

  let days = Number(Deno.env.get("EXOS_RECONCILE_DAYS") ?? 3);
  try {
    const body = await req.json();
    if (body && typeof body.days === "number") days = body.days;
  } catch {
    // no body: defaults
  }
  const now = new Date();
  const { from, to } = reconcileWindow(now, days);
  const runDay = now.toISOString().slice(0, 10);

  const stripe = new Stripe(stripeKey, { httpClient: Stripe.createFetchHttpClient(), apiVersion: "2024-06-20" });
  const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);

  // 1. Stripe (read-only): the window's balance transactions.
  const txns: StripeTxnRow[] = [];
  let truncated = false;
  const started = Date.now();
  try {
    const list = stripe.balanceTransactions.list({
      created: { gte: Math.floor(Date.parse(from) / 1000), lt: Math.floor(Date.parse(to) / 1000) },
      limit: 100,
      expand: ["data.source"],
    });
    for await (const bt of list) {
      const row = txnRow(bt as unknown as Parameters<typeof txnRow>[0]);
      if (row) txns.push(row);
      if (txns.length >= MAX_TXNS || Date.now() - started > LIST_BUDGET_MS) {
        truncated = true;
        break;
      }
    }
  } catch (e) {
    console.error("exos-reconcile-stripe: listing balance transactions failed", e);
    return json({ error: "stripe read failed", listed: txns.length }, 502);
  }

  try {
    // 2. Snapshot.
    const snapshotAt = now.toISOString();
    for (const c of chunks(txns, 500)) {
      const { error } = await sb.from("exos_stripe_balance_txns")
        .upsert(c.map((t) => ({ ...t, snapshot_at: snapshotAt })), { onConflict: "id" });
      if (error) throw new Error(`snapshot: ${error.message}`);
    }
    // 5. The connected accounts' payouts (independent of the diff below).
    const payouts = await syncOrgPayouts(stripe, sb, from, to);

    if (truncated) {
      // An incomplete list would report Exos rows as missing in Stripe and
      // resolve issues that aren't fixed: store what was read, record nothing.
      console.error(`exos-reconcile-stripe: stopped at ${txns.length} transactions; run with fewer days`);
      return json({ ok: false, truncated: true, txns: txns.length, window: { from, to }, payouts }, 200);
    }

    // 3. Exos rows: the window's, plus whatever the Stripe rows point at.
    const chargeIds = txns.filter((t) => t.type === "charge" || t.type === "payment").map((t) => t.source_id)
      .filter((x): x is string => !!x);
    const pis = txns.map((t) => t.payment_intent).filter((x): x is string => !!x);
    const refundIds = txns.filter((t) => t.type === "refund" || t.type === "payment_refund").map((t) => t.source_id)
      .filter((x): x is string => !!x);
    const disputeIds = txns.map((t) => t.source_id).filter((x): x is string => !!x && /^(dp|du)_/.test(x));

    const [winPayments, winRefunds, payByCharge, payByPi, refById, disputes] = await Promise.all([
      readAll<ExosPaymentRow>(() =>
        sb.from("exos_order_payments").select(PAYMENT_COLS).eq("provider", "stripe")
          .gte("created_at", from).lt("created_at", to).order("created_at", { ascending: true })
      ),
      readAll<ExosRefundRow>(() =>
        sb.from("exos_order_refunds").select(REFUND_COLS).eq("provider", "stripe")
          .gte("created_at", from).lt("created_at", to).order("created_at", { ascending: true })
      ),
      readIn<ExosPaymentRow>(sb, "exos_order_payments", PAYMENT_COLS, "charge_id", chargeIds),
      readIn<ExosPaymentRow>(sb, "exos_order_payments", PAYMENT_COLS, "payment_intent", pis),
      readIn<ExosRefundRow>(sb, "exos_order_refunds", REFUND_COLS, "refund_id", refundIds),
      readIn<ExosDisputeRow>(sb, "exos_disputes", "dispute_id, session_id, org_id", "dispute_id", disputeIds),
    ]);
    const payments = new Map<string, ExosPaymentRow>();
    for (const p of [...winPayments, ...payByCharge, ...payByPi]) payments.set(`${p.session_id}|${p.payment_intent ?? p.charge_id ?? ""}`, p);
    const refunds = new Map<string, ExosRefundRow>();
    for (const r of [...winRefunds, ...refById]) refunds.set(r.refund_id ?? `${r.session_id}|${r.created_at}`, r);

    // 4. Diff + record.
    const { issues, stats } = reconcile({
      txns, payments: [...payments.values()], refunds: [...refunds.values()], disputes, from, to, marginMs: MARGIN_MS,
    });
    const checkFrom = new Date(Date.parse(from) + MARGIN_MS).toISOString();
    const checkTo = new Date(Date.parse(to) - MARGIN_MS).toISOString();
    const { data: recorded, error: recErr } = await sb.rpc("exos_reconcile_stripe_record", {
      p_run_day: runDay,
      p_from: checkFrom,
      p_to: checkTo,
      p_issues: issues,
      p_stats: { ...stats, window_from: from, window_to: to },
    });
    if (recErr) throw new Error(`record: ${recErr.message}`);

    return json({ ok: true, run_day: runDay, window: { from, to }, stats, recorded, payouts });
  } catch (e) {
    console.error("exos-reconcile-stripe: run failed", e);
    return json({ error: "reconcile failed", detail: String((e as Error)?.message ?? e).slice(0, 300) }, 500);
  }
});
