// Reddit ads on the channel core (ads phase, mig 20261121190500):
// CUSTOMER_LIST audiences (syncAudience), "Boost this event"
// (createCampaign) and an insights stub (readInsights). DRY RUN ONLY: every
// write is on the allowlist below and goes through ctx.http (GatedHttp); the
// org's switch is pinned off in exos-ads, EXOS_REDDIT_ADS_WRITES is off, and
// the campaign, ad group and ad are created PAUSED.
//
// Credential: provider ads_reddit_api in the store (a Reddit Ads API OAuth
// token; the conversions token, ads_reddit, can't manage campaigns).
// config: ad_account_id (a2_… / t2_…), profile_id (t2_…, the profile the
// structured post is made as), pixel_id (else the conversions pixel),
// funding_instrument_id (optional). Bearer token in the header.
//
//   POST  /api/v3/ad_accounts/<acct>/custom_audiences    {data: {name, type: CUSTOMER_LIST}}
//   PATCH /api/v3/custom_audiences/<id>/users            {data: {action_type: ADD, column_order: [EMAIL_SHA256], user_data}}  2,500 rows a request
//   POST  /api/v3/ad_accounts/<acct>/campaigns           {data: {objective: CONVERSIONS, configured_status: PAUSED}}
//   POST  /api/v3/ad_accounts/<acct>/ad_groups           {data: {campaign_id, configured_status: PAUSED, optimization_goal: PURCHASE,
//                                                          conversion_pixel_id, targeting: {geolocations, communities}}}
//   POST  /api/v3/profiles/<profile>/structured_posts/jobs  {data: {headline, post_type: IMAGE, content: [{media_url, destination_url, call_to_action: BUY_TICKETS}]}}
//   POST  /api/v3/ad_accounts/<acct>/ads                 {data: {ad_group_id, post_id, configured_status: PAUSED, click_url}}
// (/structured_posts/jobs, not the deprecated posts endpoint.)
//
// Facts shown as warnings (operator brief 2026-11-21): an audience needs
// 1,000+ matched users, takes up to 36 hours to process and expires after a
// year. Rate limits (limits.ts "reddit"): writes 200 a minute, reads 400,
// targeting 100, audience uploads 3,000 per 15 minutes; GatedHttp counts
// each request against its metric and a cap defers the rest.
//
// UNVERIFIED (Reddit's Ads API reference was not readable from the build
// session): every body shape below beyond the brief (the `data` envelope,
// bid_strategy / goal_type, the geolocation code format "US-<zip>", the
// structured post's fields and the job's answer, the insights read). The
// API has no radius, so geo is a ZIP / borough list (geo.ts).

import { caps, type ChannelAdapter, type ChannelCtx, type ExosEvent, type OrgCredential } from "../adapter.ts";
import type { WriteRule } from "../gatedHttp.ts";
import { chunk, hashedRowsSummary, redditRows } from "../../ads/audience.ts";
import type { CampaignPlan } from "../../ads/planner.ts";
import type { HashedIdentifiers } from "../../hashedIds.ts";
import { cfgOr, createdId, microsFromCents, newResult, plannedId, standInBy, write, type AdsResult } from "./adsCommon.ts";

export const REDDIT_ADS_BASE = "https://ads-api.reddit.com";
export const REDDIT_AUDIENCE_CHUNK = 2500;
export const REDDIT_MIN_MATCHED = 1000;
const ID = "[A-Za-z0-9_-]{1,64}";

/** Exactly the writes the Reddit adapter makes. */
export const REDDIT_ADS_WRITES: WriteRule[] = [
  { method: "POST", path: new RegExp(`^/api/v3/ad_accounts/${ID}/custom_audiences$`) },
  { method: "PATCH", path: new RegExp(`^/api/v3/custom_audiences/${ID}/users$`) },
  { method: "POST", path: new RegExp(`^/api/v3/ad_accounts/${ID}/campaigns$`) },
  { method: "POST", path: new RegExp(`^/api/v3/ad_accounts/${ID}/ad_groups$`) },
  { method: "POST", path: new RegExp(`^/api/v3/profiles/${ID}/structured_posts/jobs$`) },
  { method: "POST", path: new RegExp(`^/api/v3/ad_accounts/${ID}/ads$`) },
];

export const REDDIT_AUDIENCE_WARNINGS = [
  "Reddit needs at least 1,000 matched users before a custom audience can be used.",
  "Reddit takes up to 36 hours to process an uploaded list.",
  "A Reddit custom audience expires after a year: Exos would have to upload it again.",
] as const;

export const redditAdsStandIn = standInBy([
  [/\/custom_audiences$/, "audience"], [/\/users$/, "users"], [/\/campaigns$/, "campaign"],
  [/\/ad_groups$/, "ad_group"], [/\/structured_posts\/jobs$/, "post_job"], [/\/ads$/, "ad"],
], (id) => ({ data: { id, ...(id === "planned_post_job" ? { post_id: plannedId("post") } : {}) } }));

/** GatedHttp options for this channel: the token in a header; the limits table "reddit", per ad account. */
export function redditAdsHttp(creds: OrgCredential | null) {
  const acct = typeof creds?.config.ad_account_id === "string" ? creds.config.ad_account_id : "";
  return {
    channel: "reddit_ads",
    base: REDDIT_ADS_BASE,
    writes: REDDIT_ADS_WRITES,
    headers: creds?.secret ? { Authorization: `Bearer ${creds.secret}` } : {},
    secrets: [creds?.secret],
    standIn: redditAdsStandIn,
    limits: { platform: "reddit", scopeKey: acct.slice(0, 64) },
  };
}

const ACCT_RE = /^(a2|t2)_[A-Za-z0-9]{1,40}$/;
const account = (ctx: ChannelCtx) => cfgOr(ctx.creds.config, "ad_account_id", ACCT_RE, "account");
const W = { metric: "writes", n: 1 };

async function syncAudience(ctx: ChannelCtx, audience: { id: string; name?: string; members: HashedIdentifiers[]; externalId?: string | null }): Promise<AdsResult> {
  const res = newResult("reddit_ads", ctx);
  const acct = account(ctx);
  if (!acct.set) res.warnings.push("Reddit Ads isn't connected: the ad account below is a placeholder.");
  const rows = redditRows(audience.members);
  if (rows.length < REDDIT_MIN_MATCHED) {
    res.warnings.push(`Only ${rows.length} ${rows.length === 1 ? "person has" : "people have"} an email on this list, and fewer will match: Reddit needs at least ${REDDIT_MIN_MATCHED.toLocaleString("en-US")} matched users before the audience can be used.`);
  }
  res.warnings.push(...REDDIT_AUDIENCE_WARNINGS);
  if (!rows.length) { res.stopped = "Nobody on the list has an email that can be uploaded."; return res; }
  let audId = audience.externalId && new RegExp(`^${ID}$`).test(audience.externalId) ? audience.externalId : null;
  if (!audId) {
    const r = await write(ctx, res, "POST", `/api/v3/ad_accounts/${acct.value}/custom_audiences`,
      { data: { name: (audience.name ?? "Exos fans and buyers").slice(0, 100), type: "CUSTOMER_LIST" } },
      { op: "audience.create", usage: W });
    audId = createdId(r, (b) => b?.data?.id);
    if (!audId) { res.stopped = r.error ?? "the audience wasn't created"; return res; }
  }
  res.ids.audience = audId;
  const chunks = chunk(rows, REDDIT_AUDIENCE_CHUNK);
  for (let i = 0; i < chunks.length; i++) {
    const r = await write(ctx, res, "PATCH", `/api/v3/custom_audiences/${audId}/users`,
      { data: { action_type: "ADD", column_order: ["EMAIL_SHA256"], user_data: chunks[i] } },
      { op: "audience.add_users", usage: { metric: "audience_uploads", n: 1 },
        auditBody: { data: { action_type: "ADD", column_order: ["EMAIL_SHA256"], user_data: hashedRowsSummary(chunks[i].length, ["EMAIL_SHA256"]) } } });
    if (!r.ok) {
      res.deferred = rows.length - i * REDDIT_AUDIENCE_CHUNK;
      res.stopped = r.error === "LIMIT_CAPPED"
        ? `Reddit's upload limit for these 15 minutes is used: ${res.deferred} rows wait for the next window.`
        : r.error ?? "upload refused";
      break;
    }
  }
  return res;
}

async function createCampaign(ctx: ChannelCtx, _ev: ExosEvent, campaign: Record<string, unknown>): Promise<AdsResult> {
  const plan = campaign as unknown as CampaignPlan;
  const res = newResult("reddit_ads", ctx);
  res.warnings.push(...plan.warnings);
  if (plan.blocked) { res.stopped = plan.blocked; return res; }
  const acct = account(ctx);
  const profile = cfgOr(ctx.creds.config, "profile_id", /^t2_[A-Za-z0-9]{1,40}$/, "profile");
  const pixel = cfgOr(ctx.creds.config, "pixel_id", ACCT_RE, "pixel");
  if (!acct.set) res.warnings.push("Reddit Ads isn't connected: the ad account below is a placeholder.");
  if (!profile.set) res.warnings.push("Reddit needs the profile the ad's post is made as (profile_id).");
  if (!pixel.set) res.warnings.push("Reddit requires a conversion pixel for a CONVERSIONS campaign: add the Reddit pixel under Ads & conversions.");
  const funding = typeof ctx.creds.config.funding_instrument_id === "string" && /^[A-Za-z0-9_-]{1,64}$/.test(ctx.creds.config.funding_instrument_id)
    ? ctx.creds.config.funding_instrument_id : null;
  const link = plan.url ? plan.url.replace("utm_source=exos", "utm_source=reddit") : null;

  const c = await write(ctx, res, "POST", `/api/v3/ad_accounts/${acct.value}/campaigns`, {
    data: { name: plan.name, objective: "CONVERSIONS", configured_status: "PAUSED", ...(funding ? { funding_instrument_id: funding } : {}) },
  }, { op: "campaign.create", usage: W });
  const campaignId = createdId(c, (b) => b?.data?.id);
  if (!campaignId) { res.stopped = c.error ?? "the campaign wasn't created"; return res; }
  res.ids.campaign = campaignId;

  const g = plan.geo;
  // No radius on Reddit: ZIP lists (a radius plan's city ZIPs), else the country.
  const zips = g.kind === "none" ? [] : g.zips;
  const geolocations = zips.length ? zips.map((z) => `US-${z}`) : ["US"];
  const ag = await write(ctx, res, "POST", `/api/v3/ad_accounts/${acct.value}/ad_groups`, {
    data: {
      campaign_id: campaignId,
      name: `${plan.name} · ad group`.slice(0, 100),
      configured_status: "PAUSED",
      bid_strategy: "MAXIMIZE_VOLUME",
      goal_type: "DAILY_SPEND",
      goal_value: microsFromCents(plan.dailyBudgetCents),
      start_time: plan.startTime,
      ...(plan.endTime ? { end_time: plan.endTime } : {}),
      optimization_goal: "PURCHASE",
      conversion_pixel_id: pixel.value,
      targeting: {
        geolocations,
        ...(g.kind !== "none" && g.boroughs.length ? { boroughs: g.boroughs } : {}),
        ...(plan.communities.length ? { communities: plan.communities } : {}),
      },
    },
  }, { op: "ad_group.create", usage: W });
  const adGroupId = createdId(ag, (b) => b?.data?.id);
  if (!adGroupId) { res.stopped = ag.error ?? "the ad group wasn't created"; return res; }
  res.ids.ad_group = adGroupId;

  const post = await write(ctx, res, "POST", `/api/v3/profiles/${profile.value}/structured_posts/jobs`, {
    data: {
      headline: plan.headline,
      post_type: "IMAGE",
      allow_comments: false,
      content: [{
        ...(plan.imageUrl ? { media_url: plan.imageUrl } : {}),
        destination_url: link ?? plannedId("link"),
        call_to_action: plan.cta,
      }],
    },
  }, { op: "post.create", usage: W });
  const jobId = createdId(post, (b) => b?.data?.id);
  let postId = createdId(post, (b) => b?.data?.post_id);
  if (!jobId) { res.stopped = post.error ?? "the post wasn't created"; return res; }
  res.ids.post_job = jobId;
  if (!postId && !post.planned) {
    // Live only: the job answers with the post once it is made (unverified shape).
    const j = await ctx.http.get(`/api/v3/profiles/${profile.value}/structured_posts/jobs/${encodeURIComponent(jobId)}`,
      { op: "post.job_read", usage: { metric: "reads", n: 1 } });
    postId = createdId(j, (b) => b?.data?.post_id);
    if (!postId) { res.stopped = "Reddit is still making the post: plan again in a minute."; return res; }
  }
  res.ids.post = postId!;

  const ad = await write(ctx, res, "POST", `/api/v3/ad_accounts/${acct.value}/ads`, {
    data: { ad_group_id: adGroupId, name: `${plan.name} · ad`.slice(0, 100), configured_status: "PAUSED", post_id: postId, click_url: link ?? plannedId("link") },
  }, { op: "ad.create", usage: W });
  const adId = createdId(ad, (b) => b?.data?.id);
  if (adId) res.ids.ad = adId;
  else res.stopped = ad.error ?? "the ad wasn't created";
  return res;
}

/** Reads nothing until a live credential exists; then one counted GET (unverified endpoint and fields). */
async function readInsights(ctx: ChannelCtx, ref: string): Promise<Record<string, number>> {
  const acct = account(ctx);
  if (!ctx.creds.secret || ctx.creds.status !== "connected" || !acct.set || !new RegExp(`^${ID}$`).test(ref)) return {};
  const r = await ctx.http.get(`/api/v3/ad_accounts/${acct.value}/campaigns/${ref}`, { op: "insights.read", usage: { metric: "reads", n: 1 } });
  const d = r.ok ? (r.body?.data ?? {}) : {};
  const out: Record<string, number> = {};
  for (const k of ["impressions", "clicks", "spend"]) {
    const n = Number(d[k]);
    if (Number.isFinite(n)) out[k] = n;
  }
  return out;
}

export const redditAdsAdapter: ChannelAdapter = {
  id: "reddit_ads",
  label: "Reddit Ads",
  status: "core",
  caps: caps({ role: "secondary", syncAudience: true, createCampaign: true, readInsights: true }),
  writes: REDDIT_ADS_WRITES,
  syncAudience,
  createCampaign,
  readInsights,
};
