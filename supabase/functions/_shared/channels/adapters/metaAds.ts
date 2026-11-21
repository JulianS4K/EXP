// Meta (Facebook / Instagram) ads on the channel core (ads phase, mig
// 20261121190500): Custom Audiences (syncAudience), "Boost this event"
// (createCampaign) and an insights stub (readInsights). DRY RUN ONLY: every
// write is on the allowlist below and goes through ctx.http (GatedHttp); the
// org's switch is pinned off in exos-ads, EXOS_META_ADS_WRITES is off, and a
// campaign / ad set / ad is always created PAUSED.
//
// Credential: provider ads_meta_api in the store (a Marketing API token with
// ads_management for the org's ad account; the conversions token, ads_meta,
// can't manage audiences or campaigns). config: ad_account_id (digits, no
// act_), page_id (the Facebook Page the ads run as), pixel_id (else the
// conversions pixel), product_set_id (optional: the Exos catalog feed's
// product set, exos-catalog-feed). The token goes in the Authorization header.
//
//   POST /v25.0/act_<ad account>/customaudiences  {name, subtype: CUSTOM, customer_file_source: USER_PROVIDED_ONLY}
//   POST /v25.0/<audience id>/users                {payload: {schema: [EMAIL, PHONE], data}, session}  10,000 rows a request
//   POST /v25.0/act_<ad account>/campaigns         {objective: OUTCOME_SALES, status: PAUSED, special_ad_categories: []}
//   POST /v25.0/act_<ad account>/adsets            {campaign_id, status: PAUSED, daily_budget, promoted_object, targeting}
//   POST /v25.0/act_<ad account>/adcreatives       {object_story_spec: {page_id, link_data: {..., call_to_action: BUY_TICKETS}}}
//   POST /v25.0/act_<ad account>/ads               {adset_id, creative: {creative_id}, status: PAUSED}
//   GET  /v25.0/<campaign id>/insights             (readInsights, only with a connected credential)
//
// VERIFIED (well-known public Marketing API paths): the edges above, the
// EMAIL / PHONE schema with SHA-256 hex, OUTCOME_SALES, PAUSED, BUY_TICKETS.
// UNVERIFIED (Meta's docs were not readable from the build session): the
// Advantage+ sales specifics (advantage_audience, a campaign-level budget),
// a 10,000-row batch with `session`, `picture` on link_data, and the ~100
// matched people an audience needs. Check each with the ad account in
// Meta's test mode before the CLAUDE.md write exception is asked for.

import { caps, type ChannelAdapter, type ChannelCtx, type ExosEvent, type OrgCredential } from "../adapter.ts";
import type { WriteRule } from "../gatedHttp.ts";
import { META_GRAPH_VERSION } from "../../conversions/meta.ts";
import { chunk, hashedRowsSummary, META_SCHEMA, metaRows } from "../../ads/audience.ts";
import type { CampaignPlan } from "../../ads/planner.ts";
import type { HashedIdentifiers } from "../../hashedIds.ts";
import { cfgOr, createdId, newResult, plannedId, standInBy, write, type AdsResult } from "./adsCommon.ts";

export const META_ADS_BASE = "https://graph.facebook.com";
export const META_AUDIENCE_BATCH = 10_000;
const V = META_GRAPH_VERSION.replace(/\./g, "\\.");
const ACCT = "act_(?:[0-9]{1,20}|planned_account)";
const ID = "(?:[0-9]{1,20}|planned_[a-z_]{1,40})";

/** Exactly the writes the Meta adapter makes. */
export const META_ADS_WRITES: WriteRule[] = [
  { method: "POST", path: new RegExp(`^/${V}/${ACCT}/customaudiences$`) },
  { method: "POST", path: new RegExp(`^/${V}/${ID}/users$`) },
  { method: "POST", path: new RegExp(`^/${V}/${ACCT}/campaigns$`) },
  { method: "POST", path: new RegExp(`^/${V}/${ACCT}/adsets$`) },
  { method: "POST", path: new RegExp(`^/${V}/${ACCT}/adcreatives$`) },
  { method: "POST", path: new RegExp(`^/${V}/${ACCT}/ads$`) },
];

export const metaAdsStandIn = standInBy([
  [/\/customaudiences$/, "audience"], [/\/users$/, "users"], [/\/campaigns$/, "campaign"],
  [/\/adsets$/, "adset"], [/\/adcreatives$/, "creative"], [/\/ads$/, "ad"],
]);

/** GatedHttp options for this channel (the token in a header only). */
export function metaAdsHttp(creds: OrgCredential | null) {
  return {
    channel: "meta_ads",
    base: META_ADS_BASE,
    writes: META_ADS_WRITES,
    headers: creds?.secret ? { Authorization: `Bearer ${creds.secret}` } : {},
    secrets: [creds?.secret],
    standIn: metaAdsStandIn,
  };
}

const p = (path: string) => `/${META_GRAPH_VERSION}${path}`;
const account = (ctx: ChannelCtx) => cfgOr(ctx.creds.config, "ad_account_id", /^[0-9]{1,20}$/, "account");

/** A numeric session id for a multi-batch upload, stable per audience. */
function sessionId(seed: string): number {
  let h = 0;
  for (const ch of seed) h = (h * 31 + ch.charCodeAt(0)) % 2_147_483_647;
  return h || 1;
}

async function syncAudience(ctx: ChannelCtx, audience: { id: string; name?: string; members: HashedIdentifiers[]; externalId?: string | null }): Promise<AdsResult> {
  const res = newResult("meta_ads", ctx);
  const acct = account(ctx);
  if (!acct.set) res.warnings.push("Meta Ads isn't connected: the ad account below is a placeholder.");
  const rows = metaRows(audience.members);
  res.warnings.push("Meta needs about 100 matched people before a custom audience can be used (unverified).");
  if (!rows.length) {
    res.stopped = "Nobody on the list: no one has granted advertising consent yet.";
    return res;
  }
  let audId = audience.externalId && /^[0-9]{1,20}$/.test(audience.externalId) ? audience.externalId : null;
  if (!audId) {
    const r = await write(ctx, res, "POST", p(`/act_${acct.value}/customaudiences`), {
      name: (audience.name ?? "Exos fans and buyers").slice(0, 100),
      subtype: "CUSTOM",
      description: "Exos buyers and fans who agreed to advertising. Built by Exos.",
      customer_file_source: "USER_PROVIDED_ONLY",
    }, { op: "audience.create" });
    audId = createdId(r, (b) => b?.id);
    if (!audId) { res.stopped = r.error ?? "the audience wasn't created"; return res; }
  }
  res.ids.audience = audId;
  const batches = chunk(rows, META_AUDIENCE_BATCH);
  const session = sessionId(audience.id);
  for (let i = 0; i < batches.length; i++) {
    const sess = { session_id: session, batch_seq: i + 1, last_batch_flag: i === batches.length - 1, estimated_num_total: rows.length };
    const r = await write(ctx, res, "POST", p(`/${audId}/users`),
      { payload: { schema: META_SCHEMA, data: batches[i] }, session: sess },
      { op: "audience.add_users", auditBody: { payload: { schema: META_SCHEMA, data: hashedRowsSummary(batches[i].length, META_SCHEMA) }, session: sess } });
    if (!r.ok) { res.stopped = r.error ?? "upload refused"; res.deferred = rows.length - i * META_AUDIENCE_BATCH; break; }
  }
  return res;
}

async function createCampaign(ctx: ChannelCtx, _ev: ExosEvent, campaign: Record<string, unknown>): Promise<AdsResult> {
  const plan = campaign as unknown as CampaignPlan;
  const res = newResult("meta_ads", ctx);
  res.warnings.push(...plan.warnings);
  if (plan.blocked) { res.stopped = plan.blocked; return res; }
  const acct = account(ctx);
  const page = cfgOr(ctx.creds.config, "page_id", /^[0-9]{1,20}$/, "page");
  const pixel = cfgOr(ctx.creds.config, "pixel_id", /^[0-9]{5,20}$/, "pixel");
  if (!acct.set) res.warnings.push("Meta Ads isn't connected: the ad account below is a placeholder.");
  if (!page.set) res.warnings.push("Meta needs the Facebook Page the ads run as (page_id).");
  if (!pixel.set) res.warnings.push("Meta optimizes for purchases with the org's pixel: add the Meta pixel under Ads & conversions.");
  const productSet = typeof ctx.creds.config.product_set_id === "string" && /^[0-9]{1,20}$/.test(ctx.creds.config.product_set_id)
    ? ctx.creds.config.product_set_id : null;
  const link = plan.url ? plan.url.replace("utm_source=exos", "utm_source=meta") : null;

  const c = await write(ctx, res, "POST", p(`/act_${acct.value}/campaigns`), {
    name: plan.name,
    objective: "OUTCOME_SALES",
    status: "PAUSED",
    special_ad_categories: [],
    buying_type: "AUCTION",
  }, { op: "campaign.create" });
  const campaignId = createdId(c, (b) => b?.id);
  if (!campaignId) { res.stopped = c.error ?? "the campaign wasn't created"; return res; }
  res.ids.campaign = campaignId;

  const g = plan.geo;
  const geo_locations = g.kind === "radius"
    ? { custom_locations: [{ latitude: g.lat, longitude: g.lng, radius: g.miles, distance_unit: "mile" }] }
    : g.kind === "zips" ? { zips: g.zips.map((z) => ({ key: `US:${z}` })) } : { countries: ["US"] };
  const a = await write(ctx, res, "POST", p(`/act_${acct.value}/adsets`), {
    name: `${plan.name} · ad set`.slice(0, 100),
    campaign_id: campaignId,
    status: "PAUSED",
    billing_event: "IMPRESSIONS",
    optimization_goal: "OFFSITE_CONVERSIONS",
    bid_strategy: "LOWEST_COST_WITHOUT_CAP",
    daily_budget: plan.dailyBudgetCents,
    start_time: plan.startTime,
    ...(plan.endTime ? { end_time: plan.endTime } : {}),
    promoted_object: { pixel_id: pixel.value, custom_event_type: "PURCHASE", ...(productSet ? { product_set_id: productSet } : {}) },
    targeting: { geo_locations, age_min: 18, targeting_automation: { advantage_audience: 1 } },
  }, { op: "adset.create" });
  const adsetId = createdId(a, (b) => b?.id);
  if (!adsetId) { res.stopped = a.error ?? "the ad set wasn't created"; return res; }
  res.ids.adset = adsetId;

  const cr = await write(ctx, res, "POST", p(`/act_${acct.value}/adcreatives`), {
    name: `${plan.name} · creative`.slice(0, 100),
    object_story_spec: {
      page_id: page.value,
      link_data: {
        link: link ?? plannedId("link"),
        message: plan.body,
        name: plan.headline,
        ...(plan.imageUrl ? { picture: plan.imageUrl } : {}),
        call_to_action: { type: plan.cta, value: { link: link ?? plannedId("link") } },
      },
    },
  }, { op: "creative.create" });
  const creativeId = createdId(cr, (b) => b?.id);
  if (!creativeId) { res.stopped = cr.error ?? "the creative wasn't created"; return res; }
  res.ids.creative = creativeId;

  const ad = await write(ctx, res, "POST", p(`/act_${acct.value}/ads`), {
    name: `${plan.name} · ad`.slice(0, 100),
    adset_id: adsetId,
    creative: { creative_id: creativeId },
    status: "PAUSED",
  }, { op: "ad.create" });
  const adId = createdId(ad, (b) => b?.id);
  if (adId) res.ids.ad = adId;
  else res.stopped = ad.error ?? "the ad wasn't created";
  return res;
}

/** Reads nothing until a live credential exists; then one GET of the campaign's insights (unverified fields). */
async function readInsights(ctx: ChannelCtx, ref: string): Promise<Record<string, number>> {
  if (!ctx.creds.secret || ctx.creds.status !== "connected" || !/^[0-9]{1,20}$/.test(ref)) return {};
  const r = await ctx.http.get(p(`/${ref}/insights?fields=impressions,clicks,spend`), { op: "insights.read" });
  const row = r.ok && Array.isArray(r.body?.data) ? r.body.data[0] ?? {} : {};
  const out: Record<string, number> = {};
  for (const k of ["impressions", "clicks", "spend"]) {
    const n = Number(row[k]);
    if (Number.isFinite(n)) out[k] = n;
  }
  return out;
}

export const metaAdsAdapter: ChannelAdapter = {
  id: "meta_ads",
  label: "Meta Ads",
  status: "core",
  caps: caps({ role: "secondary", syncAudience: true, createCampaign: true, readInsights: true }),
  writes: META_ADS_WRITES,
  syncAudience,
  createCampaign,
  readInsights,
};
