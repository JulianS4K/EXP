// exos-marketplace-sales — marketplace sales become Exos tickets
// (mig 20260926192000; the marketplace layer is _shared/marketplace).
//
// Two ways in:
//   * POST with x-cron-secret (pg_cron): poll.
//       StubHub   GET /sales/recentupdates (seller token, read-only)
//       SeatGeek  Terminal-2's seatgeek_orders (already pulled every 30 min)
//   * POST from StubHub's Sales webhook: Authorization must equal
//     STUBHUB_WEBHOOK_AUTHORIZATION (the value registered with the webhook).
//
// For each sale: exos_record_marketplace_order keeps it only if it sold from
// an Exos listing (the seller accounts also carry broker inventory);
// exos_fulfil_marketplace_order mints the tickets with a claim-by-email
// transfer to the buyer (or flags it for a human: oversold, no email, ...);
// then the delivery plan is stored: the marketplace call that would hand the
// buyer one claim link per ticket. DRY-RUN: nothing is sent to a
// marketplace (Hard Rule #2). The buyer can't claim until someone delivers
// the links (the plan), which is also why a minted ticket can't be scanned
// early: claiming rotates its barcode secret.
//
// Secrets: CRON_SECRET, SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY,
// EXOS_APP_BASE_URL (e.g. https://vibepass-storefront-test.onrender.com/bridge).
// StubHub (optional): STUBHUB_ENV, STUBHUB_CLIENT_ID, STUBHUB_CLIENT_SECRET,
// STUBHUB_REFRESH_TOKEN (seller login, read:sales + read:ticketholders),
// STUBHUB_WEBHOOK_AUTHORIZATION. Deploy with --no-verify-jwt (the webhook
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

const LOOKBACK_HOURS = 6;
const env = (k: string) => Deno.env.get(k);

Deno.serve(async (req: Request): Promise<Response> => {
  if (req.method !== "POST") return json({ error: "POST only" }, 405);
  const sb = createClient(env("SUPABASE_URL")!, env("SUPABASE_SERVICE_ROLE_KEY")!);
  const channels = channelsFromEnv(env);

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
      const out = await ingest(sb, channels.get("stubhub")!, [sale], stubhubClient(sb));
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
      const page = await sh.listSaleUpdates(since);
      result.stubhub = await ingest(sb, channels.get("stubhub")!, page._embedded?.items ?? [], sh);
    } else {
      result.stubhub = { skipped: "no StubHub seller credentials" };
    }

    result.seatgeek = await ingest(sb, channels.get("seatgeek")!, await seatGeekOrders(sb, since), undefined);
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

/** SeatGeek orders Terminal-2 pulled, on the listings Exos has on SeatGeek. */
async function seatGeekOrders(sb: SupabaseClient, since: Date): Promise<unknown[]> {
  const { data: listings, error } = await sb.from("exos_distribution_listings")
    .select("external_listing_id").eq("channel", "seatgeek").not("external_listing_id", "is", null);
  if (error) throw new Error(`read seatgeek listings: ${error.message}`);
  const ids = (listings ?? []).map((l) => l.external_listing_id as string);
  if (!ids.length) return [];
  const { data, error: oErr } = await sb.from("seatgeek_orders")
    .select("sg_order_id, status, sg_event_id, sg_listing_id, sale_quantity, payment_total, created_at_sg, sale_section, sale_row, last_status_at")
    .in("sg_listing_id", ids)
    .gte("last_status_at", since.toISOString())
    .limit(500);
  if (oErr) throw new Error(`read seatgeek_orders: ${oErr.message}`);
  return data ?? [];
}

async function ingest(sb: SupabaseClient, channel: MarketplaceChannel, raws: unknown[], sh: StubHubClient | undefined) {
  const counts = { seen: raws.length, exos: 0, fulfilled: 0, needs_attention: 0, cancelled: 0, errors: 0 };
  for (const raw of raws) {
    try {
      const sale: MarketplaceSale = channel.normalizeSale!(raw);
      // The buyer's email costs a call: only for sales on Exos listings, once.
      if (channel.id === "stubhub" && sh && !sale.buyerEmail && sale.externalListingId && await isExosListing(sb, "stubhub", sale.externalListingId)) {
        sale.buyerEmail = buyerEmail(await sh.listSaleTicketHolders(Number(sale.externalOrderId)));
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
      const { data: ful, error: fErr } = await sb.rpc("exos_fulfil_marketplace_order", { p_order_id: row.order_id });
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
