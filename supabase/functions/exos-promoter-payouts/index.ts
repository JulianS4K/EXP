// exos-promoter-payouts — Stripe payouts to promoters (mig 20261102150000,
// docs/payouts.md "Promoter payouts").
//
//   POST /onboard { token, return_url, refresh_url }   promoter (kit token): a Stripe Express
//                                                       onboarding link for their payout account
//   POST /status  { token }                             promoter: refresh the account's state
//   POST /send    { payout_id }                         org owner / manager (JWT): fund + send a
//                                                       Stripe payout the settle created
//   POST /cancel  { payout_id }                         org owner / manager: cancel one that never
//                                                       went out (taken money goes back to the org).
//                                                       If a send was ever started, Stripe is asked
//                                                       first (transfer_group + metadata): a transfer
//                                                       found marks it sent and the cancel is refused
//
// Gates: the org owner's switch (exos_org_promoter_payouts.stripe_transfers)
// and EXOS_PROMOTER_TRANSFERS=on. Off = dry run: /send records 'dry_run' and
// moves nothing; onboarding works either way (it moves no money).
//
// Funding keeps destination charges: the settle planned which order transfers
// to the organizer the commission is taken back from (never more per order
// than its commission or what the organizer still holds from it); /send
// reverses those, then transfers the total to the promoter. Every Stripe call
// has a deterministic idempotency key (payout id + order), so a retry or a
// crash mid-way never moves money twice.
//
// Commission methods (mig 20261104190000, docs/payouts.md "Commission
// methods"): the Exos-made transfers for split at sale and commissions inside
// the Exos fee (exos_commission_transfers), with the same lease / fence /
// reconcile rules and timing as the clawback sends above.
//   POST /run       { org_id?, transfer_id? }  cron (X-Cron-Secret, every org)
//                                             or org owner / manager (JWT, their
//                                             org): plan what is past the
//                                             holdback, record missing charge
//                                             ids, then send what is due (at
//                                             most RUN_MAX_TRANSFERS, within
//                                             RUN_BUDGET_MS). transfer_id (JWT)
//                                             retries one, even after 5 failures.
//   POST /ct-cancel { transfer_id }           org owner / manager: cancel one that
//                                             never went out (Stripe is asked
//                                             first when a send was started)
// Money moves only with EXOS_SPLIT_AT_SALE=on (split transfers) /
// EXOS_PLATFORM_FEE_COMMISSIONS=on (fee transfers); otherwise dry runs.
// Secrets also: CRON_SECRET.
//
// Deploy with --no-verify-jwt (the promoter routes carry a kit token, not a
// JWT; /send and /cancel check the JWT themselves). Secrets: STRIPE_SECRET_KEY,
// SUPABASE_URL, SUPABASE_ANON_KEY, SUPABASE_SERVICE_ROLE_KEY,
// EXOS_REDIRECT_ORIGINS, EXOS_PROMOTER_TRANSFERS.

import Stripe from "https://esm.sh/stripe@16?target=deno";
import { createClient, type SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2";
import { readCapped } from "../_shared/api/body.ts";
import { redactError } from "../_shared/log.ts";
import { isAllowedRedirect, parseRedirectOrigins } from "../_shared/redirects.ts";
import {
  claimAction, durably, findReturnTransfer, mayCallStripe, reconcileDecision, reversalKey, sendPlan, STRIPE_MAX_RETRIES,
  STRIPE_TIMEOUT_MS, stripeErrorText, timedFetch, transferKey, transfersMode,
  type ClaimAnswer, type StripeReversalLite, type StripeTransferLite,
} from "../_shared/payouts/promoterTransfers.ts";
import {
  commissionEnv, ctClaimAction, ctLive, ctReconcileDecision, ctTransferKey, ctTransferParams, RUN_BUDGET_MS, RUN_MAX_TRANSFERS,
  type CtClaim, type CtClaimAnswer,
} from "../_shared/payouts/commissionMethods.ts";
import { requireCronSecret } from "../_shared/cron-auth.ts";

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
let CORS: Record<string, string> = {};

Deno.serve(async (req: Request): Promise<Response> => {
  CORS = corsHeaders(req.headers.get("origin"));
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: CORS });
  if (req.method !== "POST") return json({ error: "method not allowed" }, 405);
  const route = new URL(req.url).pathname.replace(/\/+$/, "").split("/").pop() ?? "";
  const text = await readCapped(req, 4096);
  if (text === null) return json({ error: "request body is too large" }, 413);
  let body: Record<string, unknown>;
  try { body = JSON.parse(text || "{}"); } catch { return json({ error: "invalid JSON" }, 400); }

  const stripeKey = Deno.env.get("STRIPE_SECRET_KEY");
  if (!stripeKey) return json({ error: "payments are switched off" }, 503);
  // Every call is time-bounded (promoterTransfers.ts timing): that is what
  // makes a whole send provably shorter than its lease.
  const stripe = new Stripe(stripeKey, {
    httpClient: Stripe.createFetchHttpClient(), apiVersion: "2024-06-20",
    timeout: STRIPE_TIMEOUT_MS, maxNetworkRetries: STRIPE_MAX_RETRIES,
  });
  const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, {
    global: { fetch: timedFetch() },
  });

  try {
    if (route === "onboard" || route === "status") return await promoterRoute(route, body, stripe, sb);
    if (route === "run") {
      // The cron carries X-Cron-Secret; an organizer carries their JWT.
      let user: string | null = null;
      if (req.headers.get("x-cron-secret")) {
        const authErr = requireCronSecret(req);
        if (authErr) return authErr;
      } else {
        user = await caller(req);
        if (!user) return json({ error: "unauthorized" }, 401);
      }
      const orgId = body.org_id === undefined || body.org_id === null ? null : String(body.org_id);
      if (orgId !== null && !UUID.test(orgId)) return json({ error: "bad org_id" }, 400);
      if (user && !orgId) return json({ error: "org_id is required" }, 400);
      const one = body.transfer_id === undefined ? null : String(body.transfer_id);
      if (one !== null && (!UUID.test(one) || !user)) return json({ error: "bad transfer_id" }, 400);
      return await runCommissions(orgId, user, one, stripe, sb);
    }
    if (route === "ct-cancel") {
      const user = await caller(req);
      if (!user) return json({ error: "unauthorized" }, 401);
      const id = String(body.transfer_id ?? "");
      if (!UUID.test(id)) return json({ error: "transfer_id is required" }, 400);
      return await cancelCt(id, user, stripe, sb);
    }
    if (route === "send" || route === "cancel") {
      const user = await caller(req);
      if (!user) return json({ error: "unauthorized" }, 401);
      const id = String(body.payout_id ?? "");
      if (!UUID.test(id)) return json({ error: "payout_id is required" }, 400);
      return route === "send" ? await send(id, user, stripe, sb) : await cancel(id, user, stripe, sb);
    }
    return json({ error: "not found" }, 404);
  } catch (err) {
    console.error("exos-promoter-payouts failed", redactError(err));
    return json({ error: "something went wrong" }, 500);
  }
});

async function caller(req: Request): Promise<string | null> {
  const sbUser = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_ANON_KEY")!, {
    global: { headers: { Authorization: req.headers.get("Authorization") ?? "" } },
  });
  const { data: { user } } = await sbUser.auth.getUser();
  return user?.id ?? null;
}

// --- Promoter: their own Express account ------------------------------------
async function promoterRoute(route: string, body: Record<string, unknown>, stripe: Stripe, sb: SupabaseClient) {
  const token = String(body.token ?? "");
  if (!UUID.test(token)) return json({ error: "token is required" }, 400);
  const { data } = await sb.rpc("exos_promoter_by_token", { p_token: token });
  const p = data as { promoter_id: string; org_id: string; email: string | null; transfers_enabled: boolean;
                      stripe_account_id: string | null } | null;
  if (!p) return json({ error: "this promoter link isn't active" }, 404);
  if (!p.transfers_enabled) return json({ error: "this organizer pays promoters outside Exos" }, 409);

  if (route === "status") {
    if (!p.stripe_account_id) return json({ connected: false, ready: false });
    const acct = await stripe.accounts.retrieve(p.stripe_account_id);
    const ready = acct.capabilities?.transfers === "active";
    await sb.rpc("exos_record_promoter_stripe", {
      p_promoter_id: p.promoter_id, p_account_id: acct.id, p_details_submitted: !!acct.details_submitted,
      p_transfers_active: ready, p_payouts_enabled: !!acct.payouts_enabled,
    });
    return json({ connected: true, ready });
  }

  const returnUrl = String(body.return_url ?? "");
  const refreshUrl = String(body.refresh_url ?? "");
  const allowed = parseRedirectOrigins(Deno.env.get("EXOS_REDIRECT_ORIGINS"));
  if (allowed.length === 0) return json({ error: "server misconfigured: EXOS_REDIRECT_ORIGINS unset" }, 500);
  if (!isAllowedRedirect(returnUrl, allowed) || !isAllowedRedirect(refreshUrl, allowed)) {
    return json({ error: "redirect URL not allowed" }, 400);
  }
  let acctId = p.stripe_account_id;
  if (!acctId) {
    // One account per promoter even on a double click (Stripe dedupes the key for 24 h).
    const acct = await stripe.accounts.create(
      {
        type: "express",
        email: p.email ?? undefined,
        capabilities: { transfers: { requested: true } },
        business_type: "individual",
        metadata: { exos_promoter_id: p.promoter_id, exos_org_id: p.org_id },
      },
      { idempotencyKey: `exos-promoter-acct:${p.promoter_id}` },
    );
    acctId = acct.id;
    const { error } = await sb.rpc("exos_record_promoter_stripe", {
      p_promoter_id: p.promoter_id, p_account_id: acctId, p_details_submitted: false,
      p_transfers_active: false, p_payouts_enabled: false,
    });
    if (error) return json({ error: "could not save the payout account; try again" }, 500);
  }
  const link = await stripe.accountLinks.create({ account: acctId, refresh_url: refreshUrl, return_url: returnUrl, type: "account_onboarding" });
  return json({ url: link.url });
}

// --- Organizer: send / cancel ---------------------------------------------
// Every claim returns a lease token. A send re-checks it in SQL
// (exos_promoter_lease_ok) right before each Stripe call, and a cancel or
// reconcile claim replaces it, so a stale send can't move money after a
// cancel. The idempotency keys are per payout (and per order for reversals),
// not per attempt: within Stripe's 24 h window a repeat returns the first
// result; after it Stripe would create a new object, which is why any retry
// first reconciles (the SQL refuses a send until it has).

type Claimed = Extract<ClaimAnswer, { ok: true }>;

async function claim(sb: SupabaseClient, payoutId: string, user: string, purpose: "send" | "reconcile" | "cancel"): Promise<ClaimAnswer> {
  const { data, error } = await sb.rpc("exos_promoter_transfer_claim", { p_payout_id: payoutId, p_user: user, p_purpose: purpose });
  if (error) throw error;
  return data as ClaimAnswer;
}

// Ask Stripe what this payout already did and record it under the claim's lease.
async function reconcile(c: Claimed, stripe: Stripe, sb: SupabaseClient): Promise<"sent" | "reconciled"> {
  const transfers = await stripe.transfers.list({ transfer_group: `exos-promoter-payout-${c.payout_id}`, limit: 100 });
  const reversals: Record<string, StripeReversalLite[]> = {};
  for (const l of c.lines.filter((x) => x.status === "planned")) {
    const list = await stripe.transfers.listReversals(l.org_transfer_id, { limit: 100 });
    reversals[l.session_id] = list.data.map((r) => ({ id: r.id, metadata: (r.metadata ?? {}) as Record<string, string> }));
  }
  const d = reconcileDecision(c, transfers.data.map((t): StripeTransferLite => ({
    id: t.id, destination: typeof t.destination === "string" ? t.destination : t.destination?.id ?? null,
    metadata: (t.metadata ?? {}) as Record<string, string>,
  })), reversals);
  const { data, error } = await sb.rpc("exos_promoter_transfer_reconcile", {
    p_payout_id: c.payout_id, p_lease_token: c.lease_token, p_transfer_id: d.transferId, p_reversals: d.reversals,
  });
  if (error) throw error;
  for (const r of d.reversals) {
    const l = c.lines.find((x) => x.session_id === r.session_id);
    if (l) { l.status = "taken"; l.reversal_id = r.reversal_id; }
  }
  return data as "sent" | "reconciled";
}

async function leaseOk(sb: SupabaseClient, c: Claimed): Promise<boolean> {
  const { data, error } = await sb.rpc("exos_promoter_lease_ok", { p_payout_id: c.payout_id, p_lease_token: c.lease_token });
  return !error && data === true;
}

async function send(payoutId: string, user: string, stripe: Stripe, sb: SupabaseClient) {
  let a = await claim(sb, payoutId, user, "send");
  let act = claimAction(a);
  if (act === "reconcile_first") {
    // An earlier attempt never finished: look Stripe up before sending again.
    const r = await claim(sb, payoutId, user, "reconcile");
    const ra = claimAction(r);
    if (typeof ra === "object") return json({ error: ra.stop }, ra.stop === "not_found" ? 404 : 409);
    try {
      if ((await reconcile(r as Claimed, stripe, sb)) === "sent") return json({ status: "sent", reconciled: true });
    } catch (e) {
      return json({ status: "failed", error: `Couldn't check Stripe: ${stripeErrorText(e)}` }, 502);
    }
    a = await claim(sb, payoutId, user, "send");
    act = claimAction(a);
  }
  if (typeof act === "object") return json({ error: act.stop }, act.stop === "not_found" ? 404 : 409);
  if (act !== "proceed") return json({ error: "needs_reconcile" }, 409);
  const c = a as Claimed;
  const claimedAt = Date.now();
  const plan = sendPlan(c);
  if ("error" in plan) {
    await mark(sb, payoutId, "failed", null, plan.error, c.lease_token);
    return json({ status: "failed", error: plan.error }, 409);
  }
  if (transfersMode((k) => Deno.env.get(k)) === "dry-run") {
    await mark(sb, payoutId, "dry_run", null, null, c.lease_token);
    return json({ status: "dry_run", would_send: plan.transfer, would_reverse: plan.reverse.map((l) => ({ order: l.session_id, amount_cents: l.amount_cents })) });
  }
  const lost = () => json({ status: "stopped", error: "This payout was taken over (cancelled or timed out); nothing more was sent." }, 409);
  const fenced = async () => !mayCallStripe(Date.now() - claimedAt) || !(await leaseOk(sb, c));
  try {
    for (const line of plan.reverse) {
      if (await fenced()) return lost();
      const rev = await stripe.transfers.createReversal(
        line.org_transfer_id,
        { amount: line.amount_cents, metadata: { exos_promoter_payout_id: payoutId, exos_session_id: line.session_id } },
        { idempotencyKey: reversalKey(payoutId, line.session_id) },
      );
      const marked = await durably(async () => {
        const { data: ok, error: mErr } = await sb.rpc("exos_promoter_funding_mark", {
          p_payout_id: payoutId, p_session_id: line.session_id, p_status: "taken", p_reversal_id: rev.id,
        });
        return !mErr && ok === true;
      });
      if (!marked) {
        // The reversal happened but isn't recorded: stop and leave 'sending';
        // the next send or a cancel reconciles with Stripe first.
        console.error("exos-promoter-payouts: reversal not recorded", payoutId, line.session_id, rev.id);
        return json({ status: "sending", error: "Stripe moved money but Exos couldn't record it yet. Try Send again." }, 500);
      }
    }
    if (await fenced()) return lost();
    const tr = await stripe.transfers.create(
      {
        amount: plan.transfer.amount, currency: plan.transfer.currency, destination: plan.transfer.destination,
        transfer_group: `exos-promoter-payout-${payoutId}`,
        metadata: { exos_promoter_payout_id: payoutId, exos_org_id: c.org_id, exos_promoter_id: c.promoter_id },
      },
      { idempotencyKey: transferKey(payoutId) },
    );
    // The transfer exists at Stripe: the 'sent' mark must stick. If it can't
    // be written, answer an error and leave 'sending' (never 'failed').
    if (!(await durably(() => mark(sb, payoutId, "sent", tr.id)))) {
      console.error("exos-promoter-payouts: sent not recorded", payoutId, tr.id);
      return json({ status: "sending", transfer_id: tr.id, error: "Sent at Stripe, but not recorded yet. Try Send again." }, 500);
    }
    return json({ status: "sent", transfer_id: tr.id });
  } catch (e) {
    // The call may or may not have reached Stripe; the next send or cancel
    // reconciles before doing anything (send_started_at stays unreconciled).
    const msg = stripeErrorText(e);
    await mark(sb, payoutId, "failed", null, msg, c.lease_token);
    return json({ status: "failed", error: msg }, 502);
  }
}

async function cancel(payoutId: string, user: string, stripe: Stripe, sb: SupabaseClient) {
  // A fenced state machine. The claim moves the payout to cancel_pending
  // (send refuses it from then on) and replaces any send's lease; a send
  // attempt still open is refused. Each later step is recorded before the
  // next Stripe call, so a retry resumes where the last run stopped.
  const a = await claim(sb, payoutId, user, "cancel");
  const act = claimAction(a);
  if (typeof act === "object") return json({ error: act.stop }, act.stop === "not_found" ? 404 : 409);
  const c = a as Claimed;
  const stop = async (msg: string, status = 502) => {
    // Leave it fenced (cancel_pending / return_pending) and let go of the lease.
    await sb.rpc("exos_promoter_lease_release", { p_payout_id: payoutId, p_lease_token: c.lease_token });
    return json({ status: "cancel_pending", error: msg }, status);
  };
  try {
    if (act === "reconcile_first" && (await reconcile(c, stripe, sb)) === "sent") {
      return json({ status: "sent", error: "Stripe had already sent this payout; it stays paid." }, 409);
    }
    const { data: rb, error: rbErr } = await sb.rpc("exos_promoter_return_begin", { p_payout_id: payoutId, p_lease_token: c.lease_token });
    if (rbErr) return await stop(`Couldn't record the return: ${rbErr.message}`, 500);
    const ret = rb as { key: string | null; amount_cents: number; currency: string; return_transfer_id: string | null };
    let returnId = ret.return_transfer_id;
    if (ret.amount_cents > 0 && !returnId) {
      // A retry may find the return an earlier run made (even past Stripe's
      // 24 h key window); only otherwise create it, with the recorded key.
      const group = await stripe.transfers.list({ transfer_group: `exos-promoter-payout-${payoutId}`, limit: 100 });
      returnId = findReturnTransfer(payoutId, group.data.map((t) => ({ id: t.id, metadata: (t.metadata ?? {}) as Record<string, string> })));
      if (!returnId) {
        const { data: sec } = await sb.from("exos_org_secrets").select("payments").eq("org_id", c.org_id).maybeSingle();
        const dest = (sec?.payments as { connectedAccountId?: string } | null)?.connectedAccountId;
        if (!dest) return await stop("The organizer has no connected account to return the money to.", 409);
        const tr = await stripe.transfers.create(
          { amount: ret.amount_cents, currency: (ret.currency || "usd").toLowerCase(), destination: dest,
            transfer_group: `exos-promoter-payout-${payoutId}`, metadata: { exos_promoter_payout_id: payoutId, exos_return: "1" } },
          { idempotencyKey: ret.key! },
        );
        returnId = tr.id;
      }
      const recorded = await durably(async () => {
        const { data: ok, error: e2 } = await sb.rpc("exos_promoter_return_done", {
          p_payout_id: payoutId, p_lease_token: c.lease_token, p_return_transfer_id: returnId,
        });
        return !e2 && ok === true;
      });
      if (!recorded) return await stop("The money went back to the organizer but Exos couldn't record it yet. Cancel again to finish.", 500);
    }
    const done = await durably(async () => {
      const { data: ok, error: e3 } = await sb.rpc("exos_promoter_payout_cancel", {
        p_payout_id: payoutId, p_lease_token: c.lease_token, p_return_transfer_id: returnId,
      });
      return !e3 && ok === true;
    });
    if (!done) return await stop("Couldn't finish the cancel. Cancel again to finish.", 500);
    return json({ status: "cancelled", returned_cents: ret.amount_cents });
  } catch (e) {
    return await stop(`Stripe: ${stripeErrorText(e)}. Cancel again to finish.`);
  }
}

// --- Commission methods: Exos-made transfers --------------------------------
// One row = one Stripe transfer with key exos-ct:<id>. Claim (lease token),
// re-check the lease right before the Stripe call, mark the outcome durably;
// a retry after a crash reconciles first (transfer_group + metadata
// exos_ct_id), so a transfer is never made twice.

async function runCommissions(orgId: string | null, user: string | null, one: string | null, stripe: Stripe, sb: SupabaseClient) {
  const started = Date.now();
  const out = { planned: 0, charges: 0, sent: 0, dry_run: 0, failed: 0, skipped: 0, results: [] as unknown[] };
  if (user) {
    // An organizer runs their own org only (the claim re-checks per transfer).
    const { data: m } = await sb.from("exos_org_memberships").select("role").eq("org_id", orgId!).eq("user_id", user)
      .in("role", ["owner", "manager"]).not("disabled", "is", true).maybeSingle();
    if (!m) return json({ error: "not_found" }, 404);
  }
  if (!one) {
    const { data: plan, error: pErr } = await sb.rpc("exos_commission_plan_due", { p_org_id: orgId, p_limit: 25 });
    if (pErr) throw pErr;
    const p = plan as { planned?: number; needs_charge?: { session_id: string; payment_intent: string }[] } | null;
    out.planned = p?.planned ?? 0;
    // Split orders whose charge id the webhook didn't record yet: read it.
    for (const n of p?.needs_charge ?? []) {
      if (Date.now() - started > RUN_BUDGET_MS / 4) break;
      try {
        const pi = await stripe.paymentIntents.retrieve(n.payment_intent);
        const ch = typeof pi.latest_charge === "string" ? pi.latest_charge : pi.latest_charge?.id ?? null;
        if (ch) {
          const { data: ok } = await sb.rpc("exos_commission_record_charge", {
            p_session_id: n.session_id, p_payment_intent: n.payment_intent, p_charge_id: ch,
          });
          if (ok === true) out.charges++;
        }
      } catch (e) {
        console.error("exos-promoter-payouts: charge lookup failed", n.session_id, stripeErrorText(e));
      }
    }
  }
  let ids: string[] = [];
  if (one) ids = [one];
  else {
    const { data: due, error: dErr } = await sb.rpc("exos_ct_due", { p_org_id: orgId, p_limit: RUN_MAX_TRANSFERS });
    if (dErr) throw dErr;
    ids = ((due ?? []) as unknown[]).map((x) => String(typeof x === "object" && x !== null ? Object.values(x)[0] : x));
  }
  for (const id of ids.slice(0, RUN_MAX_TRANSFERS)) {
    // Each send is bounded on its own; stop starting new ones near the budget.
    if (Date.now() - started > RUN_BUDGET_MS) { out.skipped++; continue; }
    const r = await sendCt(id, user, stripe, sb);
    out.results.push({ id, ...r });
    if (r.status === "sent") out.sent++;
    else if (r.status === "dry_run") out.dry_run++;
    else if (r.status === "failed") out.failed++;
    else out.skipped++;
  }
  return json(out);
}

async function ctClaim(sb: SupabaseClient, id: string, user: string | null, purpose: "send" | "reconcile" | "cancel"): Promise<CtClaimAnswer> {
  const { data, error } = await sb.rpc("exos_ct_claim", { p_id: id, p_purpose: purpose, p_user: user });
  if (error) throw error;
  return data as CtClaimAnswer;
}

// Look Stripe up for this row (under a reconcile or cancel lease).
async function ctReconcile(c: CtClaim, stripe: Stripe, sb: SupabaseClient): Promise<"sent" | "reconciled"> {
  const list = await stripe.transfers.list({ transfer_group: c.transfer_group, limit: 100 });
  const found = ctReconcileDecision(c, list.data.map((t) => ({
    id: t.id, destination: typeof t.destination === "string" ? t.destination : t.destination?.id ?? null,
    metadata: (t.metadata ?? {}) as Record<string, string>,
  })));
  const { data, error } = await sb.rpc("exos_ct_reconcile", { p_id: c.id, p_lease_token: c.lease_token, p_transfer_id: found });
  if (error) throw error;
  return data as "sent" | "reconciled";
}

async function ctMark(
  sb: SupabaseClient, id: string, status: "sent" | "dry_run" | "failed",
  transferId: string | null = null, err: string | null = null, leaseToken: string | null = null,
): Promise<boolean> {
  const { data, error } = await sb.rpc("exos_ct_mark", {
    p_id: id, p_status: status, p_transfer_id: transferId, p_error: err, p_lease_token: leaseToken,
  });
  if (error) console.error("exos-promoter-payouts: ct mark failed", id, status, redactError(error));
  return !error && data === true;
}

async function sendCt(id: string, user: string | null, stripe: Stripe, sb: SupabaseClient): Promise<{ status: string; error?: string; transfer_id?: string }> {
  try {
    let a = await ctClaim(sb, id, user, "send");
    let act = ctClaimAction(a);
    if (act === "reconcile_first") {
      const r = await ctClaim(sb, id, user, "reconcile");
      const ra = ctClaimAction(r);
      if (typeof ra === "object") return { status: "skipped", error: ra.stop };
      if ((await ctReconcile(r as Extract<CtClaimAnswer, { ok: true }>, stripe, sb)) === "sent") return { status: "sent" };
      a = await ctClaim(sb, id, user, "send");
      act = ctClaimAction(a);
    }
    if (typeof act === "object") return { status: "skipped", error: act.stop };
    if (act !== "proceed") return { status: "skipped", error: "needs_reconcile" };
    const c = a as Extract<CtClaimAnswer, { ok: true }>;
    const claimedAt = Date.now();
    const plan = ctTransferParams(c);
    if ("error" in plan) {
      await ctMark(sb, id, "failed", null, plan.error, c.lease_token);
      return { status: "failed", error: plan.error };
    }
    if (!ctLive(c.kind, commissionEnv((k) => Deno.env.get(k)))) {
      await ctMark(sb, id, "dry_run", null, null, c.lease_token);
      return { status: "dry_run" };
    }
    // Fence: the lease must still be ours, with time left for the call.
    const { data: held } = await sb.rpc("exos_ct_lease_ok", { p_id: id, p_lease_token: c.lease_token });
    if (!mayCallStripe(Date.now() - claimedAt) || held !== true) {
      return { status: "skipped", error: "taken over (cancelled or timed out); nothing was sent" };
    }
    try {
      const tr = await stripe.transfers.create(plan.params, { idempotencyKey: ctTransferKey(id) });
      // The transfer exists at Stripe: 'sent' must stick. If it can't be
      // written, leave 'sending'; the next run reconciles first.
      if (!(await durably(() => ctMark(sb, id, "sent", tr.id)))) {
        console.error("exos-promoter-payouts: ct sent not recorded", id, tr.id);
        return { status: "sending", transfer_id: tr.id, error: "sent at Stripe, not recorded yet" };
      }
      return { status: "sent", transfer_id: tr.id };
    } catch (e) {
      // It may or may not have reached Stripe: the next send reconciles first.
      const msg = stripeErrorText(e);
      await ctMark(sb, id, "failed", null, msg, c.lease_token);
      return { status: "failed", error: msg };
    }
  } catch (e) {
    console.error("exos-promoter-payouts: ct send failed", id, redactError(e));
    return { status: "skipped", error: "something went wrong" };
  }
}

async function cancelCt(id: string, user: string, stripe: Stripe, sb: SupabaseClient) {
  const a = await ctClaim(sb, id, user, "cancel");
  const act = ctClaimAction(a);
  if (typeof act === "object") return json({ error: act.stop }, act.stop === "not_found" ? 404 : 409);
  const c = a as Extract<CtClaimAnswer, { ok: true }>;
  const stop = async (msg: string, status = 502) => {
    await sb.rpc("exos_ct_lease_release", { p_id: id, p_lease_token: c.lease_token });
    return json({ status: "not_cancelled", error: msg }, status);
  };
  try {
    if (act === "reconcile_first" && (await ctReconcile(c, stripe, sb)) === "sent") {
      return json({ status: "sent", error: "Stripe had already sent this transfer; it stays paid." }, 409);
    }
    const done = await durably(async () => {
      const { data: ok, error } = await sb.rpc("exos_ct_cancel", { p_id: id, p_lease_token: c.lease_token });
      if (error) throw error;
      return ok === true;
    });
    if (!done) return await stop("Couldn't cancel it. Try again.", 409);
    return json({ status: "cancelled" });
  } catch (e) {
    return await stop(`Stripe: ${stripeErrorText(e)}. Try again.`);
  }
}

async function mark(
  sb: SupabaseClient, id: string, status: "sent" | "dry_run" | "failed",
  transferId: string | null = null, err: string | null = null, leaseToken: string | null = null,
): Promise<boolean> {
  const { data, error } = await sb.rpc("exos_promoter_transfer_mark", {
    p_payout_id: id, p_status: status, p_transfer_id: transferId, p_error: err, p_lease_token: leaseToken,
  });
  if (error) console.error("exos-promoter-payouts: mark failed", id, status, redactError(error));
  return !error && data === true;
}

function corsHeaders(origin: string | null): Record<string, string> {
  const allowed = parseRedirectOrigins(Deno.env.get("EXOS_REDIRECT_ORIGINS"));
  if (!origin || !allowed.includes(origin)) return { vary: "Origin" };
  return {
    "access-control-allow-origin": origin,
    "access-control-allow-methods": "POST, OPTIONS",
    "access-control-allow-headers": "authorization, apikey, content-type, x-client-info",
    "access-control-max-age": "600",
    vary: "Origin",
  };
}

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), { status, headers: { ...CORS, "content-type": "application/json", "cache-control": "no-store" } });
}
