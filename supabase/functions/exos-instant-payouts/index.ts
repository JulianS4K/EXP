// exos-instant-payouts — Stripe Instant Payouts from an organizer's connected
// account (mig 20261102150000, docs/payouts.md "Instant payouts"). Org OWNER.
//
//   POST /quote { org_id }                                        what can go out now, and the fee
//   POST /send  { org_id, amount_cents, currency, idempotency_key } request it
//
// Exos checkout money already lands on the organizer's connected account
// (destination charges) and Stripe pays it out on the account's schedule.
// This only asks Stripe to pay part of that balance to the account's debit
// card or bank now, where Stripe offers it (instant_available > 0). Nothing
// about the charge or the destination model changes.
//
// Off unless EXOS_INSTANT_PAYOUTS=on (quote answers { enabled: false }). The
// fee estimate is EXOS_INSTANT_PAYOUT_FEE_BPS / _MIN_CENTS (default 1.5%,
// min 50c); Stripe's own fee on the payout is the real one. Every request is
// recorded first (exos_instant_payout_begin: idempotent per key, 5 a day),
// and the payout is created with the same idempotency key.
//
// Deploy with --no-verify-jwt (CORS preflight; the JWT is checked here, and
// only the SPA's origins, EXOS_REDIRECT_ORIGINS, get CORS). Secrets: STRIPE_SECRET_KEY, SUPABASE_URL,
// SUPABASE_ANON_KEY, SUPABASE_SERVICE_ROLE_KEY, EXOS_INSTANT_PAYOUTS.

import Stripe from "https://esm.sh/stripe@16?target=deno";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { readCapped } from "../_shared/api/body.ts";
import { redactError } from "../_shared/log.ts";
import { parseRedirectOrigins } from "../_shared/redirects.ts";
import {
  checkInstantRequest, instantAvailable, instantEnabled, instantFeeCents, instantFeeConfig, maxInstantPayout,
} from "../_shared/payouts/instant.ts";
import { STRIPE_MAX_RETRIES, STRIPE_TIMEOUT_MS, stripeErrorText, timedFetch } from "../_shared/payouts/promoterTransfers.ts";

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

let CORS: Record<string, string> = {};

Deno.serve(async (req: Request): Promise<Response> => {
  CORS = corsHeaders(req.headers.get("origin"));
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: CORS });
  if (req.method !== "POST") return json({ error: "method not allowed" }, 405);
  const route = new URL(req.url).pathname.replace(/\/+$/, "").split("/").pop() ?? "";
  const text = await readCapped(req, 2048);
  if (text === null) return json({ error: "request body is too large" }, 413);
  let body: Record<string, unknown>;
  try { body = JSON.parse(text || "{}"); } catch { return json({ error: "invalid JSON" }, 400); }
  const env = (k: string) => Deno.env.get(k);
  const cfg = instantFeeConfig(env);
  if (!instantEnabled(env)) return json({ enabled: false, fee_bps: cfg.bps, fee_min_cents: cfg.minCents });

  const stripeKey = env("STRIPE_SECRET_KEY");
  if (!stripeKey) return json({ enabled: false, error: "payments are switched off" }, 503);

  const sbUser = createClient(env("SUPABASE_URL")!, env("SUPABASE_ANON_KEY")!, {
    global: { headers: { Authorization: req.headers.get("Authorization") ?? "" } },
  });
  const { data: { user } } = await sbUser.auth.getUser();
  if (!user) return json({ error: "unauthorized" }, 401);
  const orgId = String(body.org_id ?? "");
  if (!UUID.test(orgId)) return json({ error: "org_id is required" }, 400);

  const sb = createClient(env("SUPABASE_URL")!, env("SUPABASE_SERVICE_ROLE_KEY")!, { global: { fetch: timedFetch() } });
  const { data: mem } = await sb.from("exos_org_memberships").select("role, disabled").eq("org_id", orgId).eq("user_id", user.id).maybeSingle();
  if (!mem || mem.disabled || mem.role !== "owner") return json({ error: "forbidden: org owner only" }, 403);
  const { data: sec } = await sb.from("exos_org_secrets").select("payments").eq("org_id", orgId).maybeSingle();
  const acct = (sec?.payments as { connectedAccountId?: string } | null)?.connectedAccountId;
  if (!acct) return json({ enabled: true, eligible: false, reason: "Connect Stripe first (Settings, Payments)." });

  // Bounded calls (same constants as exos-promoter-payouts).
  const stripe = new Stripe(stripeKey, {
    httpClient: Stripe.createFetchHttpClient(), apiVersion: "2024-06-20",
    timeout: STRIPE_TIMEOUT_MS, maxNetworkRetries: STRIPE_MAX_RETRIES,
  });
  try {
    const balance = await stripe.balance.retrieve({ stripeAccount: acct });
    const available = instantAvailable(balance as unknown as { instant_available?: Array<{ amount?: number; currency?: string }> });

    if (route === "quote") {
      return json({
        enabled: true, eligible: available.length > 0,
        reason: available.length ? null : "Stripe has no instant balance for this account right now (it needs an eligible debit card or bank, and settled funds).",
        fee_bps: cfg.bps, fee_min_cents: cfg.minCents,
        balances: available.map((b) => {
          const max = maxInstantPayout(b.amount_cents, cfg);
          return { currency: b.currency, instant_available_cents: b.amount_cents, max_payout_cents: max, fee_at_max_cents: instantFeeCents(max, cfg) };
        }),
      });
    }
    if (route !== "send") return json({ error: "not found" }, 404);

    const chk = checkInstantRequest(
      { amount_cents: body.amount_cents, currency: body.currency, idempotency_key: body.idempotency_key }, available, cfg);
    if ("error" in chk) return json({ error: chk.error }, 422);
    const { data: begun, error } = await sb.rpc("exos_instant_payout_begin", {
      p_org_id: orgId, p_user: user.id, p_amount_cents: chk.amount, p_currency: chk.currency,
      p_fee_estimate_cents: chk.fee, p_idempotency_key: chk.key,
    });
    if (error) throw error;
    const b = begun as { ok: boolean; error?: string; id?: string; replayed?: boolean; status?: string; stripe_payout_id?: string };
    if (!b.ok) return json({ error: b.error }, b.error === "daily_limit" ? 429 : 409);
    if (b.replayed && b.status === "sent") return json({ status: "sent", payout_id: b.stripe_payout_id, fee_estimate_cents: chk.fee });
    try {
      const po = await stripe.payouts.create(
        { amount: chk.amount, currency: chk.currency, method: "instant", metadata: { exos_org_id: orgId, exos_instant_id: b.id! } },
        { stripeAccount: acct, idempotencyKey: `exos-instant:${orgId}:${chk.key}` },
      );
      await sb.rpc("exos_instant_payout_mark", { p_id: b.id, p_status: "sent", p_payout_id: po.id });
      return json({ status: "sent", payout_id: po.id, arrival_date: po.arrival_date, fee_estimate_cents: chk.fee });
    } catch (e) {
      const msg = stripeErrorText(e);
      await sb.rpc("exos_instant_payout_mark", { p_id: b.id, p_status: "failed", p_error: msg });
      return json({ status: "failed", error: msg }, 502);
    }
  } catch (err) {
    console.error("exos-instant-payouts failed", redactError(err));
    return json({ error: "Stripe didn't answer; try again" }, 502);
  }
});

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
