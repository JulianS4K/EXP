// exos-payouts — pays organizers for their marketplace sales
// (mig 20260929070000, docs/payouts.md). Cron-called (x-cron-secret).
//
// Each run:
//   1. TEvo: for delivered Exos orders still awaiting the marketplace, read
//      the order's payments (GET only) and record what TEvo reports as a
//      remittance. Reported money isn't payable until someone confirms it
//      arrived (exos_confirm_remittance).
//   2. Plan payouts: exos_plan_org_payouts_report (organizer_net of payable
//      orders, less clawbacks; one open payout per org; a failed payout's
//      orders are re-planned). An org that errors is reported in
//      plan_errors and doesn't stop the others (mig 20261020120000).
//   3. Send planned payouts as Stripe Connect transfers from the platform
//      balance to each org's connected account. DRY-RUN unless
//      EXOS_PAYOUTS_LIVE=true: the run reports what it would send and moves
//      no money. A payout whose order was cancelled since planning is
//      cancelled (its orders are re-planned next run). A payout left in
//      'sending' for STALE_SENDING_MINUTES (a run died mid-send) is claimed
//      again and resent with the same idempotency key, after checking Stripe
//      for a transfer already made in its transfer group. A transfer Stripe
//      refused is marked failed; one that may have gone through (network,
//      5xx) stays 'sending' for that resend.
//
// Secrets: CRON_SECRET, SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY,
// STRIPE_SECRET_KEY (live only), TEVO_API_TOKEN / TEVO_API_SECRET / TEVO_ENV
// (optional). Nothing is ever written to a marketplace.

import Stripe from "https://esm.sh/stripe@16?target=deno";
import { createClient, type SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2";
import { requireCronSecret } from "../_shared/cron-auth.ts";
import { redactError } from "../_shared/log.ts";
import { TevoClient } from "../_shared/marketplace/tevo/client.ts";
import { normalizeTevoPayment } from "../_shared/marketplace/tevo/payments.ts";
import {
  connectTransfer, payoutsMode, staleSendingCutoff, tevoRemittanceFor, transferRefused, type PlannedPayout,
} from "../_shared/payouts/payouts.ts";

const env = (k: string) => Deno.env.get(k);

Deno.serve(async (req: Request): Promise<Response> => {
  const authErr = requireCronSecret(req);
  if (authErr) return authErr;
  const sb = createClient(env("SUPABASE_URL")!, env("SUPABASE_SERVICE_ROLE_KEY")!);
  const mode = payoutsMode(env);
  const summary: Record<string, unknown> = { mode };
  try {
    summary.tevo = await ingestTevo(sb);
    const { data: plan, error: pErr } = await sb.rpc("exos_plan_org_payouts_report", { p_org: null });
    if (pErr) throw new Error(`plan payouts: ${pErr.message}`);
    const report = (plan ?? {}) as { planned?: unknown[]; errors?: unknown[] };
    summary.planned = report.planned ?? [];
    summary.plan_errors = report.errors ?? [];
    summary.send = await sendPlanned(sb, mode);
    return json(summary);
  } catch (e) {
    console.error("exos-payouts: failed", redactError(e));
    return json({ ...summary, error: "something went wrong" }, 500);
  }
});

async function ingestTevo(sb: SupabaseClient) {
  const token = env("TEVO_API_TOKEN")?.trim(), secret = env("TEVO_API_SECRET")?.trim();
  if (!token || !secret) return { skipped: "no TEVO_API_TOKEN / TEVO_API_SECRET" };
  const tevo = new TevoClient({ credentials: () => ({ token, secret }), environment: env("TEVO_ENV") === "production" ? "production" : "sandbox" });
  const { data, error } = await sb.from("exos_marketplace_order_money").select("external_order_id, proceeds")
    .eq("channel", "evo").eq("state", "awaiting_marketplace").limit(50);
  if (error) throw new Error(`orders awaiting TEvo: ${error.message}`);
  let recorded = 0, pending = 0, failed = 0;
  for (const o of (data ?? []) as Array<{ external_order_id: string; proceeds: number | null }>) {
    try {
      const payments = (await tevo.listPayments(o.external_order_id)).map(normalizeTevoPayment);
      const rem = tevoRemittanceFor(o, payments);
      if (!rem) { pending++; continue; }
      const { error: rErr } = await sb.rpc("exos_record_remittance", { p: rem });
      if (rErr) throw new Error(rErr.message);
      recorded++;
    } catch (e) {
      failed++;
      console.error("exos-payouts: TEvo payments for an order failed", redactError(e));
    }
  }
  return { checked: (data ?? []).length, recorded, pending, failed };
}

async function sendPlanned(sb: SupabaseClient, mode: "dry-run" | "live") {
  const { data, error } = await sb.from("exos_org_payouts").select("id, org_id, currency, amount, idempotency_key, status")
    .or(`status.eq.planned,and(status.eq.sending,updated_at.lt.${staleSendingCutoff(new Date())})`).limit(50);
  if (error) throw new Error(`planned payouts: ${error.message}`);
  const stripeKey = env("STRIPE_SECRET_KEY");
  const stripe = mode === "live" && stripeKey
    ? new Stripe(stripeKey, { httpClient: Stripe.createFetchHttpClient(), apiVersion: "2024-06-20" })
    : null;
  const out: Array<Record<string, unknown>> = [];
  for (const p of (data ?? []) as Array<PlannedPayout & { status: string }>) {
    const resend = p.status === "sending";
    // An order cancelled since planning: drop the payout; next run re-plans with a clawback or without it.
    // (Not a stuck send: its transfer may have gone out; a clawback follows once it's sent.)
    const { data: stale } = resend ? { data: [] } : await sb.from("exos_org_payout_lines").select("order_id, exos_marketplace_orders!inner(status, sale_status)")
      .eq("payout_id", p.id).eq("kind", "sale")
      .or("status.eq.cancelled,sale_status.eq.cancelled", { referencedTable: "exos_marketplace_orders" });
    if ((stale ?? []).length) {
      const { data: ok } = await sb.rpc("exos_cancel_org_payout", { p_id: p.id });
      out.push({ payout: p.id, action: ok ? "cancelled" : "skipped", reason: "an order was cancelled after planning" });
      continue;
    }
    const { data: sec } = await sb.from("exos_org_secrets").select("payments").eq("org_id", p.org_id).maybeSingle();
    const pay = ((sec as { payments?: { connectedAccountId?: string; payoutsEnabled?: boolean } } | null)?.payments) ?? {};
    let transfer;
    try {
      transfer = connectTransfer(p, pay.connectedAccountId);
      if (pay.payoutsEnabled === false) throw new Error(`payout ${p.id}: the org's Stripe account can't receive payouts yet`);
    } catch (e) {
      out.push({ payout: p.id, action: "held", reason: e instanceof Error ? e.message : String(e) });
      continue;
    }
    if (mode !== "live" || !stripe) {
      out.push({ payout: p.id, action: resend ? "would_resend" : "would_send", amount_minor: transfer.params.amount, currency: transfer.params.currency });
      continue;
    }
    // The claim: another run holding it (or a payout that moved on) means hands off.
    const { error: claimErr } = await sb.rpc("exos_mark_org_payout", { p_id: p.id, p_status: "sending" });
    if (claimErr) {
      out.push({ payout: p.id, action: "skipped", reason: claimErr.message.slice(0, 200) });
      continue;
    }
    try {
      // A stuck send may have reached Stripe (idempotency keys only last 24h): look before sending again.
      const prior = resend
        ? (await stripe.transfers.list({ transfer_group: transfer.params.transfer_group, limit: 1 })).data[0]
        : undefined;
      const t = prior ?? await stripe.transfers.create(transfer.params, { idempotencyKey: transfer.idempotencyKey });
      const { error: sentErr } = await sb.rpc("exos_mark_org_payout", { p_id: p.id, p_status: "sent", p_transfer_id: t.id });
      // Left 'sending': the next stale sweep finds this transfer by its group and marks it sent.
      if (sentErr) console.error("exos-payouts: transfer made but not recorded", p.id, t.id, sentErr.message);
      out.push({ payout: p.id, action: resend ? "resent" : "sent", transfer: t.id, ...(prior ? { found: true } : {}) });
    } catch (e) {
      const msg = redactError(e).slice(0, 300);
      if (transferRefused(e)) {
        await sb.rpc("exos_mark_org_payout", { p_id: p.id, p_status: "failed", p_error: msg });
        out.push({ payout: p.id, action: "failed", reason: msg });
      } else {
        out.push({ payout: p.id, action: "unknown", reason: msg, retry: "resent with the same key once the send is stale" });
      }
    }
  }
  return out;
}

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });
}
