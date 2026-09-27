// exos-marketplace-sales — marketplace sales become Exos tickets
// (mig 20260926192000; the marketplace layer is _shared/marketplace).
//
// StubHub and SeatGeek. Ways in:
//   * POST with x-cron-secret (pg_cron): poll StubHub GET /sales/recentupdates
//     and SeatGeek GET /orders (seller tokens, read-only)
//   * POST from StubHub's Sales webhook: Authorization must equal
//     STUBHUB_WEBHOOK_AUTHORIZATION (the value registered with the webhook).
//   * POST from SeatGeek's Seller Direct webhook (X-Sellerdirect-* headers):
//     Authorization must be "Bearer SEATGEEK_WEBHOOK_TOKEN" (the token given
//     to SeatGeek at setup). order.created / order.broken go through the same
//     record + fulfil path; listing.visibility / listing.event.inactive are
//     noted on the allocation row for the organizer. SeatGeek wants a 2xx
//     within 10 seconds and retries only 3 times, so polling stays on as the
//     safety net.
//
// For each sale: exos_record_marketplace_order keeps it only if it sold from
// an Exos listing (the seller accounts also carry broker inventory);
// exos_fulfil_marketplace_order mints the tickets and issues them to the
// buyer as an Exos transfer (they're emailed claim links, and the transfer
// shows under their tickets when they sign in with that email), or flags the
// order for a human (oversold, no email, ...); then the delivery plan is
// stored: the marketplace call that would hand StubHub the same claim links.
// DRY-RUN for the marketplace side: nothing is sent to StubHub (Hard Rule #2).
// A minted ticket can't be scanned before it's claimed: claiming rotates its
// barcode secret.
//
// Secrets: CRON_SECRET, SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY,
// EXOS_APP_BASE_URL (e.g. https://vibepass-storefront-test.onrender.com/bridge).
// StubHub (optional): STUBHUB_ENV, STUBHUB_CLIENT_ID, STUBHUB_CLIENT_SECRET,
// STUBHUB_REFRESH_TOKEN (seller login, read:sales + read:ticketholders),
// STUBHUB_WEBHOOK_AUTHORIZATION. SeatGeek (optional): SEATGEEK_API_TOKEN
// (Seller Direct seller token; orders + customer reads), SEATGEEK_WEBHOOK_TOKEN.
// Deploy with --no-verify-jwt (the webhook
// and cron carry their own auth). Deploying is operator-gated.

import { createClient, type SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2";
import { requireCronSecret } from "../_shared/cron-auth.ts";
import type { MarketplaceChannel, MarketplaceSale } from "../_shared/marketplace/channel.ts";
import { channelsFromEnv } from "../_shared/marketplace/channels.ts";
import { planDelivery, recordPayload } from "../_shared/marketplace/sales.ts";
import { StubHubClient, refreshTokenSource } from "../_shared/marketplace/stubhub/client.ts";
import { buyerEmail } from "../_shared/marketplace/stubhub/fulfilment.ts";
import { STUBHUB_ENVIRONMENTS } from "../_shared/marketplace/stubhub/transport.ts";
import { parseWebhookPayload, verifyWebhookAuthorization } from "../_shared/marketplace/stubhub/webhook.ts";
import type { Sale } from "../_shared/marketplace/stubhub/types.ts";
import { SeatGeekClient, customerEmail } from "../_shared/marketplace/seatgeek/client.ts";
import type { SeatGeekOrder } from "../_shared/marketplace/seatgeek/types.ts";
import { allocationIdFromSellerListingId } from "../_shared/marketplace/seatgeek/listingPlan.ts";
import {
  parseSeatGeekNotification,
  routeSeatGeekNotification,
  verifySeatGeekWebhook,
} from "../_shared/marketplace/seatgeek/webhook.ts";

const LOOKBACK_HOURS = 6;
const env = (k: string) => Deno.env.get(k);

Deno.serve(async (req: Request): Promise<Response> => {
  if (req.method !== "POST") return json({ error: "POST only" }, 405);
  const sb = createClient(env("SUPABASE_URL")!, env("SUPABASE_SERVICE_ROLE_KEY")!);
  const channels = channelsFromEnv(env);

  // SeatGeek webhook (its own bearer token, no cron secret).
  if (!req.headers.get("x-cron-secret") && req.headers.get("x-sellerdirect-notification-type")) {
    const token = env("SEATGEEK_WEBHOOK_TOKEN") ?? "";
    if (!verifySeatGeekWebhook(req.headers.get("authorization"), token)) return json({ error: "unauthorized" }, 401);
    try {
      const n = parseSeatGeekNotification(await req.json());
      if (!n) return json({ ignored: "schema version" });
      const route = routeSeatGeekNotification(n);
      console.log("exos-marketplace-sales: SeatGeek notification", n.metadata.notification_type, n.metadata.notification_id, n.data.length);
      if (route.kind === "orders") {
        const sg = seatgeekClient();
        const out = await ingest(sb, channels.get("seatgeek")!, route.orders,
          sg ? async (s) => customerEmail(await sg.getOrderCustomer(s.externalOrderId)) : undefined);
        return json(out);
      }
      if (route.kind === "attention") return json({ noted: await noteSeatGeekListingIssues(sb, n.metadata.notification_type, route.items) });
      return json({ ignored: n.metadata.notification_type });
    } catch (e) {
      console.error("exos-marketplace-sales: SeatGeek webhook failed", e);
      // 500 so SeatGeek retries; ingest is idempotent per order.
      return json({ error: String(e) }, 500);
    }
  }

  // StubHub webhook (its own auth header, no cron secret).
  const webhookAuth = env("STUBHUB_WEBHOOK_AUTHORIZATION");
  if (!req.headers.get("x-cron-secret") && webhookAuth) {
    if (!verifyWebhookAuthorization(req.headers.get("authorization"), webhookAuth)) {
      return json({ error: "unauthorized" }, 401);
    }
    try {
      const payload = parseWebhookPayload(await req.json());
      const sale = payload._embedded?.sale;
      if (payload.kind !== "Sales" || !sale) return json({ ignored: payload.kind });
      const sh = stubhubClient(sb);
      const out = await ingest(sb, channels.get("stubhub")!, [sale], stubhubBuyerEmail(sh));
      return json(out);
    } catch (e) {
      console.error("exos-marketplace-sales: webhook failed", e);
      // 500 so StubHub retries; ingest is idempotent per sale.
      return json({ error: String(e) }, 500);
    }
  }

  const authErr = requireCronSecret(req);
  if (authErr) return authErr;
  try {
    const since = new Date(Date.now() - LOOKBACK_HOURS * 3_600_000);
    const result: Record<string, unknown> = {};

    const sh = stubhubClient(sb);
    if (sh) {
      result.stubhub = await ingest(sb, channels.get("stubhub")!, await allSaleUpdates(sh, since), stubhubBuyerEmail(sh));
    } else {
      result.stubhub = { skipped: "no StubHub seller credentials" };
    }

    const sg = seatgeekClient();
    if (sg) {
      const orders = await allSeatGeekOrders(sg, since);
      const seen = new Set(orders.map((o) => String(o.id)));
      orders.push(...await recheckSeatGeekOrders(sb, sg, seen));
      result.seatgeek = await ingest(sb, channels.get("seatgeek")!, orders,
        async (s) => customerEmail(await sg.getOrderCustomer(s.externalOrderId)));
    } else {
      result.seatgeek = { skipped: "no SeatGeek seller token" };
    }
    return json(result);
  } catch (e) {
    console.error("exos-marketplace-sales failed", e);
    return json({ error: String(e) }, 500);
  }
});

// Seller-side StubHub access. The refresh token is single-use: the current one
// lives in exos_marketplace_credentials (STUBHUB_REFRESH_TOKEN only seeds it).
function stubhubClient(sb: SupabaseClient): StubHubClient | undefined {
  const id = env("STUBHUB_CLIENT_ID"), secret = env("STUBHUB_CLIENT_SECRET"), seed = env("STUBHUB_REFRESH_TOKEN");
  if (!id || !secret || !seed) return undefined;
  const e = env("STUBHUB_ENV") === "production" ? "production" : "sandbox";
  return new StubHubClient({
    environment: e,
    accessToken: refreshTokenSource({
      tokenUrl: STUBHUB_ENVIRONMENTS[e].tokenUrl,
      clientId: id,
      clientSecret: secret,
      loadRefreshToken: async () => {
        const { data } = await sb.from("exos_marketplace_credentials").select("refresh_token").eq("channel", "stubhub").maybeSingle();
        return (data?.refresh_token as string | undefined) || seed;
      },
      saveRefreshToken: async (token: string) => {
        const { error } = await sb.from("exos_marketplace_credentials")
          .upsert({ channel: "stubhub", refresh_token: token, updated_at: new Date().toISOString() });
        if (error) console.error("exos-marketplace-sales: rotated StubHub refresh token NOT saved", error.message);
      },
    }),
  });
}

function seatgeekClient(): SeatGeekClient | undefined {
  const token = env("SEATGEEK_API_TOKEN")?.trim();
  return token ? new SeatGeekClient({ token: () => token }) : undefined;
}

// The buyer's email costs a call, so it's fetched only for sales on Exos
// listings (see ingest).
type EmailLookup = ((sale: MarketplaceSale) => Promise<string | null>) | undefined;
function stubhubBuyerEmail(sh: StubHubClient | undefined): EmailLookup {
  return sh ? async (s) => buyerEmail(await sh.listSaleTicketHolders(Number(s.externalOrderId))) : undefined;
}

// SeatGeek orders placed since `since`, every page (the account carries
// broker orders too). GET /orders filters on when an order was PLACED, so a
// cancellation of an older order isn't seen here; that stays for a human.
const SG_PER_PAGE = 200;
async function allSeatGeekOrders(sg: SeatGeekClient, since: Date): Promise<SeatGeekOrder[]> {
  const out: SeatGeekOrder[] = [];
  for (let page = 1; page <= MAX_PAGES; page++) {
    const res = await sg.listOrders({ start_date: since, page, per_page: SG_PER_PAGE });
    const orders = res.orders ?? [];
    out.push(...orders);
    const total = res.meta?.total ?? null;
    if (orders.length < SG_PER_PAGE || (total != null && out.length >= total)) return out;
  }
  console.error(`exos-marketplace-sales: stopped after ${MAX_PAGES} pages of SeatGeek orders`);
  return out;
}

// listing.visibility / listing.event.inactive: say on the allocation row why
// SeatGeek isn't showing it (the event editor shows planned_listing errors).
// Other attention types (order.retransfer, order.fulfillment.error) are logged.
async function noteSeatGeekListingIssues(sb: SupabaseClient, type: string, items: unknown[]): Promise<number> {
  let noted = 0;
  for (const raw of items) {
    const it = raw as { seller_listing_id?: string; hidden_reason_code?: string; hidden_reason_description?: string; reason?: string; event_name?: string };
    const alloc = allocationIdFromSellerListingId(it.seller_listing_id);
    if (!alloc) {
      console.warn("exos-marketplace-sales: SeatGeek", type, JSON.stringify(raw).slice(0, 500));
      continue;
    }
    const why = type === "listing.visibility"
      ? `SeatGeek is hiding listing ${it.seller_listing_id}: ${it.hidden_reason_description ?? it.hidden_reason_code ?? "no reason given"}`
      : `SeatGeek event inactive for listing ${it.seller_listing_id}: ${it.reason ?? "unknown"}`;
    const { error } = await sb.from("exos_distribution_listings")
      .update({ error: why.slice(0, 500), updated_at: new Date().toISOString() })
      .eq("id", alloc).eq("channel", "seatgeek");
    if (error) console.error("exos-marketplace-sales: SeatGeek listing issue not stored", alloc, error.message);
    else noted++;
  }
  return noted;
}

// Orders Exos already has, re-read one by one (GET /order), oldest check
// first, so a later status change (a cancellation) still reaches
// exos_record_marketplace_order. A few per run.
const SG_RECHECK_PER_RUN = 50;
async function recheckSeatGeekOrders(sb: SupabaseClient, sg: SeatGeekClient, skip: Set<string>): Promise<SeatGeekOrder[]> {
  const { data, error } = await sb.from("exos_marketplace_orders")
    .select("external_order_id")
    .eq("channel", "seatgeek")
    .in("status", ["received", "fulfilled", "needs_attention"])
    .gt("created_at", new Date(Date.now() - 60 * 86_400_000).toISOString())
    .order("updated_at", { ascending: true })
    .limit(SG_RECHECK_PER_RUN);
  if (error) {
    console.error("exos-marketplace-sales: SeatGeek recheck list failed", error.message);
    return [];
  }
  const out: SeatGeekOrder[] = [];
  for (const r of (data ?? []) as Array<{ external_order_id: string }>) {
    if (skip.has(r.external_order_id)) continue;
    try {
      out.push(await sg.getOrder(r.external_order_id));
    } catch (e) {
      console.error("exos-marketplace-sales: SeatGeek order recheck failed", r.external_order_id, String(e));
    }
  }
  return out;
}

// Every page: the seller account also carries broker sales, so Exos's can be
// anywhere in the list.
const PAGE_SIZE = 100;
const MAX_PAGES = 50;
async function allSaleUpdates(sh: StubHubClient, since: Date): Promise<Sale[]> {
  const out: Sale[] = [];
  for (let page = 1; page <= MAX_PAGES; page++) {
    const res = await sh.listSaleUpdates(since, { page, page_size: PAGE_SIZE });
    const items = res._embedded?.items ?? [];
    out.push(...items);
    const total = res.total_items ?? null;
    if (items.length < PAGE_SIZE || (total != null && out.length >= total)) return out;
  }
  console.error(`exos-marketplace-sales: stopped after ${MAX_PAGES} pages of StubHub sale updates`);
  return out;
}

async function ingest(sb: SupabaseClient, channel: MarketplaceChannel, raws: unknown[], lookupEmail: EmailLookup) {
  const counts = { seen: raws.length, exos: 0, fulfilled: 0, needs_attention: 0, cancelled: 0, errors: 0 };
  for (const raw of raws) {
    try {
      const sale: MarketplaceSale = channel.normalizeSale!(raw);
      // The buyer's email costs a call: only for sales on Exos listings, once.
      if (lookupEmail && !sale.buyerEmail && sale.externalListingId && await isExosListing(sb, channel.id, sale.externalListingId)) {
        sale.buyerEmail = await lookupEmail(sale);
      }
      const { data: rec, error: rErr } = await sb.rpc("exos_record_marketplace_order", {
        p_sale: recordPayload(sale, channel.id === "stubhub" ? stripStubHubSale(raw as Sale) : raw),
      });
      if (rErr) throw new Error(`record: ${rErr.message}`);
      const row = (rec as Array<{ order_id: string; status: string }> | null)?.[0];
      if (!row) continue; // not an Exos listing
      counts.exos++;
      if (row.status !== "received") {
        if (row.status === "cancelled") counts.cancelled++;
        continue;
      }
      const { data: ful, error: fErr } = await sb.rpc("exos_fulfil_marketplace_order", {
        p_order_id: row.order_id,
        p_app_base: env("EXOS_APP_BASE_URL") ?? null,
      });
      if (fErr) throw new Error(`fulfil: ${fErr.message}`);
      const f = (ful as Array<{ status: string; transfer_ids: string[]; reason: string | null }>)[0];
      if (f.status === "fulfilled") {
        counts.fulfilled++;
        const plan = planDelivery(channel, { external_order_id: sale.externalOrderId, quantity: sale.quantity, transfer_ids: f.transfer_ids }, env("EXOS_APP_BASE_URL"));
        const { error: pErr } = await sb.from("exos_marketplace_orders")
          .update({ delivery_plan: plan, updated_at: new Date().toISOString() }).eq("id", row.order_id);
        if (pErr) console.error("exos-marketplace-sales: delivery plan not stored", row.order_id, pErr.message);
      } else if (f.status === "needs_attention") {
        counts.needs_attention++;
      } else if (f.status === "cancelled") {
        counts.cancelled++;
      }
    } catch (e) {
      counts.errors++;
      console.error("exos-marketplace-sales: sale failed", channel.id, String(e));
    }
  }
  return counts;
}

async function isExosListing(sb: SupabaseClient, channel: string, listingId: string): Promise<boolean> {
  const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(listingId);
  const q = sb.from("exos_distribution_listings").select("id", { count: "exact", head: true }).eq("channel", channel);
  const { count } = uuid
    ? await q.or(`id.eq.${listingId},external_listing_id.eq.${listingId}`)
    : await q.eq("external_listing_id", listingId);
  return (count ?? 0) > 0;
}

/** The sale minus barcodes and ticket-holder identity: kept for audit, not for PII. */
function stripStubHubSale(s: Sale): unknown {
  const { barcodes: _b, _embedded, ...rest } = s ?? ({} as Sale);
  return { ...rest, event_id: _embedded?.event?.id ?? null };
}

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } });
}
