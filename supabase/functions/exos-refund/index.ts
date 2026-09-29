// exos-refund — organizer-initiated money refunds from the Exos UI.
//
// Auth: the caller's Supabase JWT (verified with auth.getUser). The org role
// (owner / manager / finance of the order's org) is checked in the database by
// exos_refund_claim, which the function calls with the service role and the
// verified user id. Scanner / content staff and strangers get 403.
//
// Actions (POST JSON):
//   { action: "refund", session_id, nonce, reason?,
//     items?: [{ ticket_id, amount_cents? }]   // per ticket; omitted amount = what's left on it
//     amount_cents?: int                        // order-level partial, not tied to tickets
//     whole_order?: true }                      // everything still refundable
//     -> { request_id, status, amount_cents, voided, stripe_refund_id }
//   { action: "cancel_event", event_id, nonce, reason?, after? }
//     Refunds every order on the event that still has money left, a batch at a
//     time (BATCH orders per call). The UI calls again with `after` = the
//     returned next_after until done. Each order's nonce is evc:<nonce>:<session>,
//     so re-sending a batch never refunds an order twice. Doesn't change the
//     event's status; the UI cancels the event first (owner / manager).
//   { action: "retry", request_id }
//     Re-sends a request left 'claimed' after Stripe didn't answer (same key).
//
// Buyer actions after a date change (mig 20260929150000; scope 'reschedule').
// Authorized by the buyer's JWT OR a mail-link token instead of an org role;
// no organizer step. The rules live in SQL (exos_request_reschedule_refund):
// only the person who paid, before the deadline, a ticket that is active, not
// checked in and paid through an Exos checkout. A token acts only on its own
// ticket and action.
//   { action: "reschedule_refund", ticket_ids?: uuid[], token? }
//     -> { results: [{ ticket_id, ok, reason? , status?, request_id?, amount_cents?, voided? }] }
//     One Stripe refund per ticket (reverse_transfer, refund_application_fee as
//     above), idempotency key exos_refund_<request id>; the request is unique
//     per ticket + reschedule, so a double click or a concurrent call reuses it.
//     Voids the ticket once the refund succeeds (exos_refund_finalize); the
//     refund-issued mail follows from the ledger row.
//   { action: "reschedule_release", ticket_ids?, token? }   free / comp: void, no money
//   { action: "reschedule_info", token }                    what a mail link is for
// These work signed out (the SPA sends the anon key) when a token is given.
// reschedule_release / reschedule_info don't need Stripe.
//
// Money flow per request (all guards in SQL, mig 20260926040000):
//   1. exos_refund_claim   — locks the order, checks the role, reserves the
//                            amount (can't exceed what's left; concurrent claims
//                            serialize on the order row).
//   2. stripe.refunds.create with idempotency key exos_refund_<request id>,
//      reverse_transfer + refund_application_fee (see _shared/organizer-refund.ts).
//   3. exos_refund_finalize — ledger row (same refund id the webhook records),
//                            voids tickets the refund covers in full.
//   A Stripe rejection finalizes 'failed' (reservation released). A network /
//   5xx error leaves the request 'claimed' and returns 502: retrying with the
//   same nonce reuses the request and key. stripe-webhook's charge.refunded
//   also finalizes by the refund's metadata.exos_refund_request_id, so a crash
//   between steps 2 and 3 still reconciles.
//
// Required secrets: STRIPE_SECRET_KEY, SUPABASE_URL, SUPABASE_ANON_KEY,
// SUPABASE_SERVICE_ROLE_KEY. Optional: EXOS_REFUND_KEEP_PLATFORM_FEE=true.
// Payments off (no STRIPE_SECRET_KEY) -> 503.
// Deploy with JWT verification ON (the default). Payment functions stay
// undeployed until the operator turns payments on (docs/payments-go-live.md).

import Stripe from "https://esm.sh/stripe@16?target=deno";
import { createClient, type SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2";
import {
  type ClaimedRequest,
  isDefinitiveStripeRejection,
  NONCE_RE,
  organizerRefundIdempotencyKey,
  organizerRefundParams,
  requestStatusFromStripe,
} from "../_shared/organizer-refund.ts";
import { RESCHEDULE_TOKEN_RE } from "../_shared/reschedule-refund.ts";

const BATCH = 10;

type Claim = ClaimedRequest & {
  status: string;
  stripe_refund_id: string | null;
  existing: boolean;
  currency: string;
};

type Outcome = {
  session_id: string;
  request_id?: string;
  status: string;
  amount_cents?: number;
  voided?: number;
  stripe_refund_id?: string | null;
  error?: string;
};

Deno.serve(async (req: Request): Promise<Response> => {
  if (req.method !== "POST") return json({ error: "Method Not Allowed" }, 405);

  // Buyer actions (date change) take a different auth path; everything else
  // below is the organizer flow, unchanged.
  const raw = await req.text();
  // deno-lint-ignore no-explicit-any
  let parsed: any = undefined;
  try { parsed = JSON.parse(raw); } catch { /* handled per path */ }
  if (parsed && typeof parsed === "object" && typeof parsed.action === "string" && parsed.action.startsWith("reschedule_")) {
    return await rescheduleAction(req, parsed);
  }

  const stripeKey = Deno.env.get("STRIPE_SECRET_KEY");
  if (!stripeKey) return json({ error: "payments are switched off" }, 503);

  const authHeader = req.headers.get("Authorization") ?? "";
  const sbUser = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_ANON_KEY")!,
    { global: { headers: { Authorization: authHeader } } },
  );
  const { data: { user } } = await sbUser.auth.getUser();
  if (!user) return json({ error: "unauthorized" }, 401);

  // deno-lint-ignore no-explicit-any
  let p: any;
  try { p = JSON.parse(raw); } catch { return json({ error: "invalid JSON" }, 400); }
  if (!p || typeof p !== "object") return json({ error: "invalid body" }, 400);
  const nonce = typeof p.nonce === "string" ? p.nonce : "";
  if (p.action !== "retry" && !NONCE_RE.test(nonce)) return json({ error: "missing or bad nonce" }, 400);
  const reason = typeof p.reason === "string" ? p.reason.slice(0, 500) : null;

  const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
  const stripe = new Stripe(stripeKey, { httpClient: Stripe.createFetchHttpClient(), apiVersion: "2024-06-20" });
  const keepFee = Deno.env.get("EXOS_REFUND_KEEP_PLATFORM_FEE") === "true";

  if (p.action === "refund") {
    const sessionId = typeof p.session_id === "string" ? p.session_id : "";
    if (!sessionId) return json({ error: "missing session_id" }, 400);
    const items = Array.isArray(p.items) ? p.items : null;
    if (items && items.length > 100) return json({ error: "at most 100 tickets per refund" }, 400);
    const amount = p.amount_cents == null ? null : Number(p.amount_cents);
    if (amount != null && (!Number.isInteger(amount) || amount <= 0)) {
      return json({ error: "amount_cents must be a positive whole number" }, 400);
    }
    const { data, error } = await sb.rpc("exos_refund_claim", {
      p_actor: user.id,
      p_session_id: sessionId,
      p_nonce: nonce,
      p_items: items,
      p_amount_cents: amount,
      p_whole_order: p.whole_order === true,
      p_reason: reason,
      p_scope: null,
    });
    if (error) return claimError(error);
    const out = await refundClaim(sb, stripe, data as Claim, keepFee);
    const httpStatus = out.status === "claimed" ? 502 : out.status === "failed" ? 402 : 200;
    return json(out, httpStatus);
  }

  if (p.action === "cancel_event") {
    const eventId = typeof p.event_id === "string" ? p.event_id : "";
    if (!eventId) return json({ error: "missing event_id" }, 400);
    const after = typeof p.after === "string" && p.after ? p.after : null;
    const { data: rows, error } = await sb.rpc("exos_refund_event_orders_svc", {
      p_actor: user.id, p_event_id: eventId, p_after: after, p_limit: BATCH,
    });
    if (error) return claimError(error);
    const list = (rows ?? []) as { session_id: string; refundable_cents: number }[];
    const results: Outcome[] = [];
    for (const row of list) {
      const { data, error: cErr } = await sb.rpc("exos_refund_claim", {
        p_actor: user.id,
        p_session_id: row.session_id,
        p_nonce: `evc:${nonce}:${row.session_id}`.slice(0, 200),
        p_items: null,
        p_amount_cents: null,
        p_whole_order: true,
        p_reason: reason ?? "event cancelled",
        p_scope: "event_cancel",
      });
      if (cErr) {
        results.push({ session_id: row.session_id, status: "skipped", error: cErr.message });
        continue;
      }
      results.push(await refundClaim(sb, stripe, data as Claim, keepFee));
    }
    const nextAfter = list.length > 0 ? list[list.length - 1].session_id : after;
    return json({ results, next_after: nextAfter, done: list.length < BATCH });
  }

  if (p.action === "retry") {
    // A request left 'claimed' (Stripe didn't answer). Re-claiming with its own
    // nonce re-checks the caller's role and hands back the same request + key.
    const requestId = typeof p.request_id === "string" ? p.request_id : "";
    if (!requestId) return json({ error: "missing request_id" }, 400);
    const { data: row } = await sb.from("exos_refund_requests")
      .select("session_id, nonce").eq("id", requestId).maybeSingle();
    if (!row) return json({ error: "refund request not found" }, 404);
    const { data, error } = await sb.rpc("exos_refund_claim", {
      p_actor: user.id, p_session_id: row.session_id, p_nonce: row.nonce,
    });
    if (error) return claimError(error);
    const out = await refundClaim(sb, stripe, data as Claim, keepFee);
    return json(out, out.status === "claimed" ? 502 : out.status === "failed" ? 402 : 200);
  }

  return json({ error: "unknown action" }, 400);
});

// ── Buyer: date-change refunds and releases ─────────────────────────────────

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

// deno-lint-ignore no-explicit-any
async function rescheduleAction(req: Request, p: any): Promise<Response> {
  const token = typeof p.token === "string" && p.token !== "" ? p.token : null;
  if (token !== null && !RESCHEDULE_TOKEN_RE.test(token)) return json({ error: "this link is not valid" }, 403);
  let ticketIds: string[] | null = null;
  if (p.ticket_ids != null) {
    if (!Array.isArray(p.ticket_ids) || p.ticket_ids.length === 0 || p.ticket_ids.length > 50
        || !p.ticket_ids.every((x: unknown) => typeof x === "string" && UUID_RE.test(x))) {
      return json({ error: "ticket_ids must be 1 to 50 ticket ids" }, 400);
    }
    ticketIds = p.ticket_ids;
  }

  const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);

  if (p.action === "reschedule_info") {
    if (!token) return json({ error: "missing token" }, 400);
    const { data, error } = await sb.rpc("exos_reschedule_link_info", { p_token: token });
    if (error) return claimError(error);
    if (!data) return json({ error: "this link is not valid" }, 404);
    return json(data);
  }

  // A signed-in buyer's JWT, when there is one (signed out, the SPA sends the
  // anon key and getUser finds no user).
  const sbUser = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_ANON_KEY")!,
    { global: { headers: { Authorization: req.headers.get("Authorization") ?? "" } } },
  );
  let userId: string | null = null;
  try {
    const { data: { user } } = await sbUser.auth.getUser();
    userId = user?.id ?? null;
  } catch { userId = null; }
  if (!userId && !token) return json({ error: "sign in, or use the link in your email" }, 401);
  if (!ticketIds && !token) return json({ error: "missing ticket_ids" }, 400);

  if (p.action === "reschedule_release") {
    const { data, error } = await sb.rpc("exos_reschedule_release_svc", {
      p_actor: userId, p_ticket_ids: ticketIds, p_token: token,
    });
    if (error) return claimError(error);
    return json(data);
  }

  if (p.action === "reschedule_refund") {
    const stripeKey = Deno.env.get("STRIPE_SECRET_KEY");
    if (!stripeKey) return json({ error: "payments are switched off" }, 503);
    const stripe = new Stripe(stripeKey, { httpClient: Stripe.createFetchHttpClient(), apiVersion: "2024-06-20" });
    const keepFee = Deno.env.get("EXOS_REFUND_KEEP_PLATFORM_FEE") === "true";
    const { data, error } = await sb.rpc("exos_request_reschedule_refund", {
      p_actor: userId, p_ticket_ids: ticketIds, p_token: token,
    });
    if (error) return claimError(error);
    const rows = ((data as { results?: unknown[] } | null)?.results ?? []) as {
      ticket_id: string; ok: boolean; reason?: string; claim?: Claim;
    }[];
    const results = [];
    for (const row of rows) {
      if (!row.ok || !row.claim) {
        results.push({ ticket_id: row.ticket_id, ok: false, reason: row.reason ?? "not-refundable" });
        continue;
      }
      const out = await refundClaim(sb, stripe, row.claim, keepFee);
      results.push({
        ticket_id: row.ticket_id,
        // 'claimed' = Stripe didn't answer: not done yet; asking again reuses the request and key.
        ok: out.status === "succeeded" || out.status === "pending",
        status: out.status,
        request_id: out.request_id,
        amount_cents: out.amount_cents,
        voided: out.voided,
        error: out.error,
      });
    }
    return json({ results });
  }

  return json({ error: "unknown action" }, 400);
}

// Steps 2 + 3 for one claimed request. Never throws.
// deno-lint-ignore no-explicit-any
async function refundClaim(sb: SupabaseClient<any, any, any>, stripe: Stripe, c: Claim, keepFee: boolean): Promise<Outcome> {
  const base = { session_id: c.session_id, request_id: c.request_id, amount_cents: c.amount_cents };
  // A retried nonce whose request already has Stripe's answer: nothing to do.
  if (c.existing && c.status !== "claimed") {
    return { ...base, status: c.status, voided: 0, stripe_refund_id: c.stripe_refund_id };
  }

  let refund: Stripe.Refund | null = null;
  try {
    // A claimed request from an earlier attempt may already have a refund
    // (idempotency keys expire after 24h): look for it before creating one.
    if (c.existing) {
      for await (const rf of stripe.refunds.list({ payment_intent: c.payment_intent, limit: 100 })) {
        if (rf.metadata?.exos_refund_request_id === c.request_id) { refund = rf; break; }
      }
    }
    refund ??= await stripe.refunds.create(
      organizerRefundParams(c, keepFee),
      { idempotencyKey: organizerRefundIdempotencyKey(c.request_id) },
    );
  } catch (e) {
    const msg = (e as Error).message ?? "stripe error";
    if (isDefinitiveStripeRejection(e)) {
      const { error } = await sb.rpc("exos_refund_finalize", {
        p_request_id: c.request_id, p_stripe_refund_id: null, p_status: "failed", p_error: msg,
      });
      if (error) console.error(`exos-refund: finalize(failed) ${c.request_id}`, error);
      return { ...base, status: "failed", error: msg };
    }
    console.error(`exos-refund: stripe refund for ${c.request_id} not confirmed`, e);
    return { ...base, status: "claimed", error: "Stripe didn't answer; try again (it won't refund twice)" };
  }

  const status = requestStatusFromStripe(refund.status);
  const { data, error } = await sb.rpc("exos_refund_finalize", {
    p_request_id: c.request_id,
    p_stripe_refund_id: refund.id,
    p_status: status,
    p_error: refund.failure_reason ?? null,
  });
  if (error) {
    // The refund exists; stripe-webhook's charge.refunded finalizes it by metadata.
    console.error(`exos-refund: finalize ${c.request_id} (refund ${refund.id}) failed`, error);
    return { ...base, status, stripe_refund_id: refund.id, error: "refund sent; bookkeeping will catch up" };
  }
  const f = data as { voided?: number } | null;
  return { ...base, status, voided: f?.voided ?? 0, stripe_refund_id: refund.id };
}

function claimError(error: { code?: string; message?: string }): Response {
  const msg = (error.message ?? "refund refused").replace(/^exos_refund_[a-z_]+: /, "");
  if (error.code === "42501") return json({ error: msg }, 403);
  if (error.code === "P0002") return json({ error: msg }, 404);
  if (error.code === "22023") return json({ error: msg }, 409);
  console.error("exos-refund: rpc error", error);
  return json({ error: "could not start the refund" }, 500);
}

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } });
}
