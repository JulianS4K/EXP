// The ads phase's passes (mig 20261121190500), behind exos-ads: plan an
// audience sync or a "Boost this event" campaign for one org, on the
// channel core. Pure apart from the injected rpc / fetch, so the Deno tests
// drive a whole pass with stubs.
//
// DRY RUN, PINNED. Operator 2026-11-21: "For the APIs build and keep read
// only till build is complete". ADS_WRITES_PINNED_OFF hands GatedHttp an org
// switch of false whatever the org's row says, so every write below is a dry
// run even if an operator flag were turned on: nothing is sent, the exact
// payload (secrets redacted; hashed lists summarized) is recorded in
// exos_channel_audit (the organizer's "What we'd send") and returned. Going
// live needs this pin removed in a reviewed change AND the CLAUDE.md write
// exception for each platform (docs/marketing-conversions.md "Ads").

import type { ChannelAdapter, ChannelCtx, OrgCredential } from "../channels/adapter.ts";
import { createGatedHttp, type WriteRule } from "../channels/gatedHttp.ts";
import { memoryAuditSink, rpcAuditSink, teeSink, type AuditStep } from "../channels/audit.ts";
import { rpcUsageCounter, type UsageCounter } from "../channels/usage.ts";
import { loadCredential } from "../channels/credentials.ts";
import { metaAdsAdapter, metaAdsHttp } from "../channels/adapters/metaAds.ts";
import { redditAdsAdapter, redditAdsHttp } from "../channels/adapters/redditAds.ts";
import { googleCustomerMatchAdapter, googleCustomerMatchHttp } from "../channels/adapters/googleCustomerMatch.ts";
import type { AdsResult } from "../channels/adapters/adsCommon.ts";
import { buildAudience, type AudienceSourceRow, type BuiltAudience } from "./audience.ts";
import { boostConfig, planCampaign, type CampaignEventInput, type CampaignPlan } from "./planner.ts";

/** The build gate: every ad write stays a dry run (see the header). */
export const ADS_WRITES_PINNED_OFF = true;

export type AudienceChannel = "meta_ads" | "reddit_ads" | "google_customer_match";
export type CampaignChannel = "meta_ads" | "reddit_ads";
export const AUDIENCE_CHANNELS: readonly AudienceChannel[] = ["meta_ads", "reddit_ads", "google_customer_match"];
export const CAMPAIGN_CHANNELS: readonly CampaignChannel[] = ["meta_ads", "reddit_ads"];

type Rpc = (fn: string, args: Record<string, unknown>) => PromiseLike<{ data: unknown; error: unknown }>;

export interface RunDeps {
  orgId: string;
  /** Service-role rpc. */
  rpc: Rpc;
  env: (k: string) => string | undefined | null;
  fetch: typeof fetch;
  appBase: string;
  now?: () => Date;
  /** Tests: a memory counter; default the database's. */
  counter?: UsageCounter;
  /** Tests: false keeps steps out of the database. */
  persistAudit?: boolean;
}

interface ChannelDef {
  adapter: ChannelAdapter;
  provider: string;
  /** The conversions credential whose pixel the campaign falls back to. */
  pixelFrom?: string;
  http: (c: OrgCredential | null) => { channel: string; base: string; writes: WriteRule[]; headers?: Record<string, string>;
    secrets?: readonly (string | null | undefined)[]; standIn?: (m: any, p: string, b: unknown) => unknown;
    limits?: { platform?: string; scopeKey?: string } };
}

const CHANNELS: Record<AudienceChannel, ChannelDef> = {
  meta_ads: { adapter: metaAdsAdapter, provider: "ads_meta_api", pixelFrom: "ads_meta", http: metaAdsHttp },
  reddit_ads: { adapter: redditAdsAdapter, provider: "ads_reddit_api", pixelFrom: "ads_reddit", http: redditAdsHttp },
  google_customer_match: { adapter: googleCustomerMatchAdapter, provider: "ads_google_ads", http: (c) => googleCustomerMatchHttp(c, null) },
};

/** What the organizer sees of one recorded step (already redacted by GatedHttp). */
export interface StepView { op: string; method: string; path: string; live: boolean; body: unknown; error?: string; warnings?: string[] }
const view = (s: AuditStep): StepView => ({
  op: s.op, method: s.method, path: s.path, live: s.live, body: s.request?.body ?? null,
  ...(s.error ? { error: s.error } : {}), ...(s.warnings?.length ? { warnings: s.warnings.map((w) => w.reason) } : {}),
});

async function credentialFor(d: RunDeps, def: ChannelDef): Promise<OrgCredential> {
  const c = await loadCredential(d.rpc, d.orgId, def.provider).catch(() => null);
  const cred: OrgCredential = c ?? { provider: def.provider, status: "unverified", config: {}, secret: null, writesEnabled: false, accountName: null, source: "none" };
  if (def.pixelFrom && typeof cred.config.pixel_id !== "string") {
    const px = await loadCredential(d.rpc, d.orgId, def.pixelFrom).catch(() => null);
    if (typeof px?.config.pixel_id === "string") cred.config = { ...cred.config, pixel_id: px.config.pixel_id };
  }
  return cred;
}

function makeCtx(d: RunDeps, def: ChannelDef, cred: OrgCredential, eventId?: string) {
  const memory = memoryAuditSink();
  const audit = d.persistAudit === false ? memory : teeSink(memory, rpcAuditSink(d.rpc, d.orgId));
  const o = def.http(cred);
  const http = createGatedHttp({
    channel: o.channel, base: o.base, writes: o.writes, headers: o.headers, secrets: o.secrets, standIn: o.standIn,
    fetch: d.fetch, env: d.env,
    orgWritesEnabled: ADS_WRITES_PINNED_OFF ? false : cred.writesEnabled,
    audit,
    limits: { ...(o.limits ?? {}), counter: d.counter ?? rpcUsageCounter(d.rpc, d.orgId) },
    ...(eventId ? { eventId } : {}),
    now: d.now,
  });
  const ctx: ChannelCtx = { orgId: d.orgId, creds: cred, http, audit };
  return { ctx, memory, audit };
}

export interface AudiencePlanOut {
  channel: AudienceChannel;
  audience: BuiltAudience["counts"];
  result: AdsResult;
  steps: StepView[];
}

/** Plan one platform's audience sync from the org's consenting fans and buyers. */
export async function planAudienceSync(d: RunDeps, req: {
  channel: AudienceChannel; eventId?: string | null; actor?: string | null; name?: string; externalId?: string | null;
}): Promise<AudiencePlanOut> {
  const def = CHANNELS[req.channel];
  const src = await d.rpc("exos_ads_audience_source", { p_org_id: d.orgId, p_event_id: req.eventId ?? null, p_actor: req.actor ?? null });
  if (src.error) throw Object.assign(new Error("audience source failed"), { cause: src.error });
  const rows = ((src.data as { rows?: AudienceSourceRow[] } | null)?.rows ?? []) as AudienceSourceRow[];
  const built = await buildAudience(rows);
  rows.length = 0; // the raw emails go no further
  const cred = await credentialFor(d, def);
  const { ctx, memory, audit } = makeCtx(d, def, cred, req.eventId ?? undefined);
  try {
    const result = await def.adapter.syncAudience!(ctx, {
      id: `${d.orgId}:${req.eventId ?? "all"}`, name: req.name, members: built.members, externalId: req.externalId ?? null,
    }) as AdsResult;
    return { channel: req.channel, audience: built.counts, result, steps: memory.steps.map(view) };
  } finally {
    await audit.flush?.();
  }
}

export interface CampaignPlanOut {
  plan: CampaignPlan;
  channels: Array<{ channel: CampaignChannel; result: AdsResult; steps: StepView[] }>;
}

/** Plan "Boost this event" on each platform: one shared plan, one adapter each. */
export async function planBoost(d: RunDeps, req: {
  event: CampaignEventInput; channels: readonly CampaignChannel[]; dailyBudgetCents?: unknown;
}): Promise<CampaignPlanOut> {
  const now = d.now?.() ?? new Date();
  const plan = planCampaign(req.event, boostConfig(d.env, { daily_budget_cents: req.dailyBudgetCents }), { appBase: d.appBase, now });
  const out: CampaignPlanOut = { plan, channels: [] };
  for (const ch of req.channels) {
    const def = CHANNELS[ch];
    const cred = await credentialFor(d, def);
    const { ctx, memory, audit } = makeCtx(d, def, cred, req.event.id);
    try {
      const result = await def.adapter.createCampaign!(ctx, req.event as never, plan as unknown as Record<string, unknown>) as AdsResult;
      out.channels.push({ channel: ch, result, steps: memory.steps.map(view) });
    } finally {
      await audit.flush?.();
    }
  }
  return out;
}
