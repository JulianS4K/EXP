// exos-ads — the ads phase's planner (mig 20261121190500; docs/marketing-conversions.md
// "Ads"): plan an audience sync (Meta Custom Audiences, Google Customer Match
// through the Data Manager API, Reddit CUSTOMER_LIST) or a "Boost this event"
// campaign (Meta, Reddit) for an org, on the channel core.
//
// DRY RUN ONLY (operator 2026-11-21: "For the APIs build and keep read only
// till build is complete"). Every ad-platform write goes through GatedHttp on
// its adapter's explicit allowlist with the org's switch pinned off
// (_shared/ads/run.ts ADS_WRITES_PINNED_OFF), so nothing is sent whatever the
// flags say. What would be sent is recorded in exos_channel_audit (the
// organizer's "What we'd send", Org settings) and returned here. No call
// reaches an ad platform from this function: the dry run makes no reads
// either, and the Google access-token swap is not made.
//
// Routes (POST JSON, under /functions/v1/exos-ads), owner / manager (the
// context RPC checks the caller's role first):
//   /plan-audience  {org, channel: meta_ads | reddit_ads | google_customer_match,
//                    event?, name?, audience_id?}
//   /plan-campaign  {org, event, channels?: [meta_ads, reddit_ads], daily_budget_cents?}
// Deploy with --no-verify-jwt (CORS preflight; the JWT is checked here).
//
// Env: SUPABASE_URL, SUPABASE_ANON_KEY, SUPABASE_SERVICE_ROLE_KEY,
//      EXOS_REDIRECT_ORIGINS, EXOS_APP_BASE_URL (the event links),
//      EXOS_ADS_BOOST_PRICE_CENTS (what Exos charges for a boost; default 0).

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { redactError } from "../_shared/log.ts";
import { corsHeaders, json } from "../_shared/spaHttp.ts";
import {
  AUDIENCE_CHANNELS, CAMPAIGN_CHANNELS, planAudienceSync, planBoost,
  type AudienceChannel, type CampaignChannel, type RunDeps,
} from "../_shared/ads/run.ts";
import type { CampaignEventInput } from "../_shared/ads/planner.ts";

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

// A fetch that refuses everything: the dry run must never reach a platform.
// GatedHttp makes no request in a dry run; this makes sure of it.
const noNetwork = (async () => {
  throw new Error("exos-ads: no network in the dry run");
}) as unknown as typeof fetch;

Deno.serve(async (req: Request): Promise<Response> => {
  const url = new URL(req.url);
  const route = url.pathname.replace(/\/+$/, "").split("/").pop() ?? "";
  const cors = corsHeaders(req.headers.get("origin"), "POST, OPTIONS");
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: cors });
  if (req.method !== "POST") return json({ error: "method not allowed" }, 405, cors);

  const auth = req.headers.get("Authorization") ?? "";
  if (!/^Bearer\s+\S+/.test(auth)) return json({ error: "sign in first" }, 401, cors);
  const sbUser = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_ANON_KEY")!, {
    global: { headers: { Authorization: auth } },
  });
  const { data: who } = await sbUser.auth.getUser();
  if (!who.user) return json({ error: "sign in first" }, 401, cors);
  const body = await req.json().catch(() => ({}));
  const org = String(body?.org ?? "");
  const event = body?.event == null || body.event === "" ? null : String(body.event);
  if (!UUID.test(org)) return json({ error: "missing or bad org" }, 400, cors);
  if (event !== null && !UUID.test(event)) return json({ error: "bad event" }, 400, cors);

  // The caller's role (owner / manager) and the event's facts, as the caller.
  const ctxRes = await sbUser.rpc("exos_ads_campaign_context", { p_org_id: org, p_event_id: event });
  if (ctxRes.error) return rpcError(ctxRes.error, cors);
  const context = ctxRes.data as { event: CampaignEventInput | null; connected: Record<string, boolean> };

  const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
  const deps: RunDeps = {
    orgId: org,
    rpc: (fn, args) => sb.rpc(fn, args),
    env: (k) => Deno.env.get(k),
    fetch: noNetwork,
    appBase: (Deno.env.get("EXOS_APP_BASE_URL") ?? "").replace(/\/+$/, ""),
  };

  try {
    if (route === "plan-audience") {
      const channel = String(body?.channel ?? "") as AudienceChannel;
      if (!AUDIENCE_CHANNELS.includes(channel)) return json({ error: "meta_ads, reddit_ads or google_customer_match" }, 400, cors);
      const externalId = typeof body?.audience_id === "string" && /^[A-Za-z0-9_-]{1,64}$/.test(body.audience_id) ? body.audience_id : null;
      const name = typeof body?.name === "string" ? body.name.trim().slice(0, 100) || undefined : undefined;
      const out = await planAudienceSync(deps, { channel, eventId: event, actor: who.user.id, name, externalId });
      return json({ dry_run: true, connected: context.connected, ...out }, 200, cors);
    }

    if (route === "plan-campaign") {
      if (!context.event) return json({ error: "pick an event" }, 400, cors);
      const asked = Array.isArray(body?.channels) ? body.channels.map(String) : CAMPAIGN_CHANNELS;
      const channels = CAMPAIGN_CHANNELS.filter((c) => asked.includes(c)) as CampaignChannel[];
      if (!channels.length) return json({ error: "meta_ads or reddit_ads" }, 400, cors);
      const out = await planBoost(deps, { event: context.event, channels, dailyBudgetCents: body?.daily_budget_cents });
      return json({ dry_run: true, connected: context.connected, ...out }, 200, cors);
    }

    return json({ error: "not found" }, 404, cors);
  } catch (err) {
    const cause = (err as { cause?: { code?: string; message?: string } })?.cause;
    if (cause?.code) return rpcError(cause, cors);
    console.error("exos-ads: plan failed", redactError(err));
    return json({ error: "something went wrong" }, 500, cors);
  }
});

function rpcError(error: { code?: string; message?: string }, cors: Record<string, string>): Response {
  const msg = (error.message ?? "").replace(/^exos_\w+: /, "");
  if (error.code === "42501") return json({ error: msg || "Not allowed.", reason: "forbidden" }, 403, cors);
  if (error.code === "22023") return json({ error: msg, reason: "invalid" }, 400, cors);
  if (error.code === "P0001") return json({ error: msg, reason: "limit" }, 429, cors);
  console.error("exos-ads: rpc failed", redactError(error));
  return json({ error: "something went wrong" }, 500, cors);
}
