// exos-s4k-feed — the S4K network feed (docs/marketplace/s4k-feed.md;
// mig 20261014100000). Exos inventory served the way S4K's Ticket Desk
// serves Paciolan, with the names changed, so S4K's consumer mirrors Exos
// like one more box office and lists it through Automatiq on S4K's accounts.
// Exos never calls a marketplace (Hard Rule #2).
//
// Auth: Authorization: Bearer exf_… (or X-API-Key). Only the SHA-256 of the
// token is stored (exos_feed_consumers); mint one with
// exos_feed_create_consumer (service role, operator).
//
//   GET  /exos/events[?updatedSince=&limit=&offset=]   call 1: events on the feed
//   GET  /exos/events/{eventId}/tickets                call 2: one GA line per ticket type
//   POST /exos/events/{eventId}/orders                 S4K buys to fill a marketplace sale
//        { ticketId, quantity, externalRef, unitPrice, marketplace?, buyerEmail? }
//        Idempotency-Key header = externalRef. 201 created (claim links),
//        200 replayed, 409 rejected (sold out / price moved / over max per
//        order): nothing is taken, and the rejection is logged.
//   GET  /exos/orders/{orderId}                        status + claim links
//   POST /exos/orders/{orderId}/cancel                 the marketplace cancelled: seats back
//   GET  /exos/status                                  freshness for a monitor
//   POST /cron                                         X-Cron-Secret: refresh the feed
//        state, then POST the webhook to each consumer with a URL
//
// Webhook (secondary to polling): one coalesced POST listing the events that
// moved, signed like exos-webhook-drain (X-Exos-Timestamp, X-Exos-Signature:
// sha256=<hex HMAC(secret, ts + "." + body)>, X-Exos-Delivery). A failed send
// keeps the cursor and backs off; the next success carries everything since.
// SSRF guard on the URL (https only, public addresses, no redirects).
//
// Rate limit: 120 calls a minute per token (exos_rate_hit). Responses are
// JSON with Cache-Control: no-store and open CORS, like the desk.
// Deploy with --no-verify-jwt (S4K sends its feed token, not a Supabase JWT).
// Secrets: SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, CRON_SECRET,
// EXOS_APP_BASE_URL (claim links and event pages).

import { createClient, type SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2";
import { requireCronSecret } from "../_shared/cron-auth.ts";
import { redactError } from "../_shared/log.ts";
import { urlIsBlocked } from "../_shared/ssrf.ts";
import {
  bearerToken,
  parseFeedRoute,
  parseOrderBody,
  parsePaging,
  parseSince,
  sha256Hex,
  shapeEventsPage,
  shapeOrder,
  shapeTickets,
  signWebhook,
  webhookBody,
  type EventsPage,
  type OrderRpc,
  type OrderTicketRow,
  type TicketsResult,
  type WebhookEvent,
} from "../_shared/s4kFeed/feed.ts";

const PER_MINUTE = 120;
const WEBHOOK_TIMEOUT_MS = 8000;

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "Authorization, X-API-Key, Content-Type, Idempotency-Key",
  "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
};

Deno.serve(async (req: Request): Promise<Response> => {
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: CORS });
  const url = new URL(req.url);
  const route = parseFeedRoute(url.pathname, req.method);
  if (!route) return json({ error: "not found: see /exos/events" }, 404);
  const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, {
    auth: { persistSession: false, autoRefreshToken: false },
  });

  if (route.kind === "cron") {
    const authErr = requireCronSecret(req);
    if (authErr) return authErr;
    try {
      return json(await runCron(sb));
    } catch (e) {
      console.error("exos-s4k-feed: cron failed", redactError(e));
      return json({ error: "cron failed" }, 500);
    }
  }

  const token = bearerToken((h) => req.headers.get(h));
  if (!token) return json({ error: "unauthorized", detail: "Send a valid token: Authorization: Bearer <token>" }, 401);
  const hash = await sha256Hex(token);
  const { data: allowed, error: rlErr } = await sb.rpc("exos_rate_hit", { p_bucket: `s4kfeed:${hash.slice(0, 16)}`, p_limit: PER_MINUTE });
  if (rlErr) {
    console.error("exos-s4k-feed: rate limiter error (refusing)", rlErr.message);
    return json({ error: "temporarily unavailable" }, 503, { "Retry-After": "30" });
  }
  if (allowed === false) return json({ error: "rate limit exceeded" }, 429, { "Retry-After": "60" });
  const appBase = (Deno.env.get("EXOS_APP_BASE_URL") ?? "").replace(/\/+$/, "");

  try {
    switch (route.kind) {
      case "events":
      case "status": {
        const since = parseSince(url.searchParams.get("updatedSince"));
        if ("error" in since) return json({ error: since.error }, 400);
        const paging = route.kind === "status" ? { limit: 1, offset: 0 } : parsePaging(url.searchParams.get("limit"), url.searchParams.get("offset"));
        const { data, error } = await sb.rpc("exos_feed_events_page", {
          p_token_hash: hash, p_since: route.kind === "status" ? null : since.since, p_limit: paging.limit, p_offset: paging.offset,
        });
        if (error) throw new Error(`events: ${error.message}`);
        if ((data as { error?: string })?.error === "unauthorized") return unauthorized();
        const page = shapeEventsPage(data as EventsPage, since.since, appBase);
        if (route.kind === "status") return json({ generatedAt: page.generatedAt, activeEvents: page.total, source: "exos" });
        return json(page);
      }
      case "tickets": {
        const { data, error } = await sb.rpc("exos_feed_event_tickets", { p_token_hash: hash, p_event_id: route.eventId });
        if (error) throw new Error(`tickets: ${error.message}`);
        if ((data as { error?: string } | null)?.error === "unauthorized") return unauthorized();
        if (!data) return json({ error: `No event on the feed for '${route.eventId}'.` }, 404);
        return json(shapeTickets(data as TicketsResult));
      }
      case "order": {
        let body: unknown;
        try {
          body = await req.json();
        } catch {
          return json({ error: "send a JSON body" }, 400);
        }
        const o = parseOrderBody(body, req.headers.get("idempotency-key"));
        if ("error" in o) return json({ error: o.error }, 400);
        const { data, error } = await sb.rpc("exos_feed_place_order", {
          p_token_hash: hash, p_event_id: route.eventId, p_tier_id: o.ticketId, p_quantity: o.quantity,
          p_external_ref: o.externalRef, p_marketplace: o.marketplace, p_unit_price: o.unitPrice,
          p_buyer_email: o.buyerEmail, p_app_base: appBase || null,
        });
        if (error) throw new Error(`order: ${error.message}`);
        return orderResponse(sb, hash, data as OrderRpc, appBase);
      }
      case "orderGet": {
        const { data, error } = await sb.rpc("exos_feed_order_status", { p_token_hash: hash, p_order_id: route.orderId });
        if (error) throw new Error(`order status: ${error.message}`);
        const r = data as { result: string };
        if (r.result === "not_found") return json({ error: "No order with that id." }, 404);
        return orderResponse(sb, hash, data as OrderRpc, appBase, true);
      }
      case "orderCancel": {
        const { data, error } = await sb.rpc("exos_feed_cancel_order", { p_token_hash: hash, p_order_id: route.orderId });
        if (error) throw new Error(`cancel: ${error.message}`);
        const r = data as { result: string; reason?: string; released?: number };
        if (r.result === "unauthorized") return unauthorized();
        if (r.result === "not_found") return json({ error: "No order with that id." }, 404);
        if (r.result === "refused") return json({ error: "can't cancel", reason: r.reason }, 409);
        return json({ orderId: route.orderId, status: "cancelled", released: r.released ?? 0 });
      }
    }
  } catch (e) {
    console.error("exos-s4k-feed: failed", route.kind, redactError(e));
    return json({ error: "something went wrong" }, 500);
  }
  return json({ error: "not found" }, 404);
});

async function orderResponse(sb: SupabaseClient, hash: string, r: OrderRpc, appBase: string, lookup = false): Promise<Response> {
  if (r.result === "unauthorized") return unauthorized();
  let tickets: OrderTicketRow[] = [];
  if (r.result === "created" || r.result === "existing") {
    const { data, error } = await sb.rpc("exos_feed_order_tickets", { p_token_hash: hash, p_order_id: r.order_id });
    if (error) throw new Error(`order tickets: ${error.message}`);
    tickets = (data ?? []) as OrderTicketRow[];
  }
  const out = shapeOrder(r, tickets, appBase);
  if (lookup && out.body && typeof out.body === "object") delete (out.body as { replayed?: boolean }).replayed;
  return json(out.body, out.status);
}

async function runCron(sb: SupabaseClient) {
  const { data: refreshed, error: rErr } = await sb.rpc("exos_feed_refresh", { p_event_id: null });
  if (rErr) throw new Error(`refresh: ${rErr.message}`);
  const { data: due, error: dErr } = await sb.rpc("exos_feed_webhook_due", { p_limit: 500 });
  if (dErr) throw new Error(`webhook due: ${dErr.message}`);
  let sent = 0, failed = 0;
  for (const w of (due ?? []) as Array<{ consumer_id: string; url: string; secret: string; cursor_to: string; cursor_id: string; events: WebhookEvent[] }>) {
    const err = await sendWebhook(w.url, w.secret, w.consumer_id, `${w.cursor_to}/${w.cursor_id}`, w.events);
    const { error: aErr } = await sb.rpc("exos_feed_webhook_ack", {
      p_consumer_id: w.consumer_id, p_cursor_to: w.cursor_to, p_cursor_id: w.cursor_id, p_ok: err === null, p_error: err,
    });
    if (aErr) console.error("exos-s4k-feed: webhook ack failed", aErr.message);
    if (err === null) sent++;
    else failed++;
  }
  return { refreshed: refreshed ?? 0, webhooks: { sent, failed } };
}

/** null on a 2xx, else a short reason (no URL, no secret). */
async function sendWebhook(target: string, secret: string, consumerId: string, batch: string, events: WebhookEvent[]): Promise<string | null> {
  const blocked = await urlIsBlocked(target);
  if (blocked) return `blocked: ${blocked}`;
  const body = JSON.stringify(webhookBody(events, new Date()));
  const ts = Math.floor(Date.now() / 1000);
  const sig = await signWebhook(secret, ts, body);
  try {
    const res = await fetch(target, {
      method: "POST",
      redirect: "manual",
      signal: AbortSignal.timeout(WEBHOOK_TIMEOUT_MS),
      headers: {
        "Content-Type": "application/json",
        "User-Agent": "Exos-Feed/1",
        "X-Exos-Timestamp": String(ts),
        "X-Exos-Signature": `sha256=${sig}`,
        "X-Exos-Delivery": `${consumerId}:${batch}`,
      },
      body,
    });
    await res.body?.cancel();
    return res.status >= 200 && res.status < 300 ? null : `HTTP ${res.status}`;
  } catch (e) {
    return e instanceof Error && e.name === "TimeoutError" ? "timeout" : "network error";
  }
}

function unauthorized(): Response {
  return json({ error: "unauthorized", detail: "Send a valid token: Authorization: Bearer <token>" }, 401);
}

function json(body: unknown, status = 200, extra: Record<string, string> = {}): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json; charset=utf-8", "Cache-Control": "no-store", ...CORS, ...extra },
  });
}
