// The social posting / listing pass (mig 20261121203000), behind
// exos-social: plan "Post / list this event" on Instagram, TikTok, Meetup,
// LinkedIn and Google Business Profile for one org, on the channel core.
// Pure apart from the injected rpc / fetch, so the Deno tests drive a whole
// pass with stubs.
//
// DRY RUN, PINNED. Operator 2026-11-21: "For the APIs build and keep read
// only till build is complete". SOCIAL_WRITES_PINNED_OFF hands GatedHttp an
// org switch of false whatever the org's row says (the same pin as the ads
// phase's ADS_WRITES_PINNED_OFF), so every write below is a dry run even if
// an operator flag were turned on: nothing is sent, the exact payload
// (secrets redacted) is recorded in exos_channel_audit (the organizer's
// "What we'd send") and returned. A placeholder id (planned_<kind>: a
// stand-in answer, or a missing account id) is refused if it would ever be
// sent live (adsCommon.ts liveSafe). Going live needs this pin removed in a
// reviewed change AND the CLAUDE.md write exception for each platform
// (docs/social.md "Posting and listing APIs").
//
// PLAN, THEN A CONFIRMED PUBLISH (Applier review of #139). planSocial never
// sends, pin or no pin: GatedHttp gets an org switch of false for every plan.
// Each platform's plan carries `confirm`, a digest of exactly the requests it
// would send (method, path, redacted body). publishSocial takes one platform
// and that digest; it re-plans, refuses if anything changed, and only then
// could send (while SOCIAL_WRITES_PINNED_OFF it refuses with "pinned"). So
// nothing goes out in the pass that shows it, a LinkedIn event or a Business
// Profile post (live once sent) needs the organizer's confirm of the very
// payload, and Meetup's DRAFT is never published in the pass that creates it
// (publishing is its own plan: meetupDraftId).
//
// ONE CREDENTIAL EACH. A platform reads only its own store provider: Google
// Business Profile has its own google_business grant (apps.ts) and never
// borrows the Google Ads token.

import type { ChannelAdapter, ChannelCtx, OrgCredential } from "../channels/adapter.ts";
import { createGatedHttp, type WriteRule } from "../channels/gatedHttp.ts";
import { memoryAuditSink, rpcAuditSink, teeSink, type AuditStep } from "../channels/audit.ts";
import { rpcUsageCounter, type UsageCounter } from "../channels/usage.ts";
import { loadCredential } from "../channels/credentials.ts";
import type { LimitFacts } from "../channels/limits.ts";
import type { AdsResult } from "../channels/adapters/adsCommon.ts";
import { instagramAdapter, instagramHttp } from "../channels/adapters/instagram.ts";
import { tiktokAdapter, tiktokHttp, tiktokPublish, type TikTokChoices } from "../channels/adapters/tiktok.ts";
import { meetupAdapter, meetupHttp } from "../channels/adapters/meetup.ts";
import { linkedinAdapter, linkedinHttp } from "../channels/adapters/linkedin.ts";
import { googleBusinessAdapter, googleBusinessHttp, profileAgeDays } from "../channels/adapters/googleBusiness.ts";
import { composePost, PLATFORM_LABEL, SOCIAL_PLATFORMS, type PlatformPost, type SocialEventInput, type SocialPlatform } from "./postKit.ts";
import { familyOf, VENDOR_APPS, type VendorFamily } from "./apps.ts";

/** The build gate: every social / listing write stays a dry run (see the header). */
export const SOCIAL_WRITES_PINNED_OFF = true;

export { SOCIAL_PLATFORMS };

type Rpc = (fn: string, args: Record<string, unknown>) => PromiseLike<{ data: unknown; error: unknown }>;

export interface RunDeps {
  orgId: string;
  /** Service-role rpc. */
  rpc: Rpc;
  env: (k: string) => string | undefined | null;
  fetch: typeof fetch;
  appBase: string;
  now?: () => Date;
  counter?: UsageCounter;
  persistAudit?: boolean;
}

interface HttpOpts {
  channel: string; base: string; writes: WriteRule[]; headers?: Record<string, string>;
  secrets?: readonly (string | null | undefined)[]; standIn?: (m: any, p: string, b: unknown) => unknown;
  limits?: { platform?: string; scopeKey?: string };
}

interface RunExtra { attendees: number | null; audited: boolean; tiktok: TikTokChoices; meetupDraftId: string | null }

interface PlatformDef {
  adapter: ChannelAdapter;
  /** The one store provider this platform reads (never another's). */
  provider: string;
  http: (c: OrgCredential | null) => HttpOpts;
  facts?: (c: OrgCredential, now: Date) => LimitFacts;
  run: (ctx: ChannelCtx, ev: Record<string, unknown> & { id: string }, post: PlatformPost, extra: RunExtra) => Promise<unknown>;
}

const DEFS: Record<SocialPlatform, PlatformDef> = {
  instagram: {
    adapter: instagramAdapter, provider: "ig_publish", http: instagramHttp,
    run: (ctx, ev, post) => instagramAdapter.publishPost!(ctx, ev, post),
  },
  tiktok: {
    adapter: tiktokAdapter, provider: "tiktok_publish", http: tiktokHttp,
    run: (ctx, ev, post, x) => tiktokPublish(x.audited, x.tiktok)(ctx, ev, post),
  },
  meetup: {
    adapter: meetupAdapter, provider: "meetup", http: meetupHttp,
    facts: (c) => ({ plan: typeof c.config.plan === "string" ? c.config.plan.toLowerCase() : null }),
    run: (ctx, ev, post, x) => meetupAdapter.upsertEvent!(ctx, ev, { post, attendees: x.attendees, publishDraftId: x.meetupDraftId }),
  },
  linkedin: {
    adapter: linkedinAdapter, provider: "linkedin", http: linkedinHttp,
    run: (ctx, ev, post) => linkedinAdapter.upsertEvent!(ctx, ev, { post }),
  },
  google_business: {
    adapter: googleBusinessAdapter, provider: "google_business",
    http: (c) => googleBusinessHttp(c, null),
    facts: (c, now) => ({ profileAgeDays: profileAgeDays(c.config.verified_at, now) }),
    run: (ctx, ev, post) => googleBusinessAdapter.publishPost!(ctx, ev, post),
  },
};

export interface StepView { op: string; method: string; path: string; live: boolean; body: unknown; error?: string; warnings?: string[] }
const view = (s: AuditStep): StepView => ({
  op: s.op, method: s.method, path: s.path, live: s.live, body: s.request?.body ?? null,
  ...(s.error ? { error: s.error } : {}), ...(s.warnings?.length ? { warnings: s.warnings.map((w) => w.reason) } : {}),
});

export interface PlatformStatus {
  /** The org has this platform's credential (a secret saved, not disabled). */
  connected: boolean;
  provider: string;
  /** Always true while the build pin is in. */
  dryRun: boolean;
  app: VendorFamily | null;
  /** The vendor app's connect flow: stub until built. */
  connect: "built" | "stub";
}

export interface PlatformPlan {
  platform: SocialPlatform;
  label: string;
  status: PlatformStatus;
  post: PlatformPost;
  result: AdsResult;
  steps: StepView[];
  /** Digest of exactly what a publish would send; null when the plan stopped or sends nothing. publishSocial needs it. */
  confirm: string | null;
}

export interface PlanRequest {
  event: SocialEventInput & { id: string; capacity?: number | null };
  venueOrg: boolean;
  platforms?: readonly SocialPlatform[];
  /** The creator's TikTok choices (privacy, interactions, disclosure, consent); nothing defaults on. */
  tiktok?: TikTokChoices;
  /** Meetup: publish this draft (reviewed on Meetup) instead of creating one. */
  meetupDraftId?: string | null;
}

const NONE = (provider: string): OrgCredential =>
  ({ provider, status: "unverified", config: {}, secret: null, writesEnabled: false, accountName: null, source: "none" });

const usable = (c: OrgCredential | null) => !!c && !!c.secret && c.status !== "disabled";

async function credentialFor(d: RunDeps, def: PlatformDef): Promise<OrgCredential> {
  return (await loadCredential(d.rpc, d.orgId, def.provider).catch(() => null)) ?? NONE(def.provider);
}

/** JSON with keys sorted at every level (the confirm digest's input). */
function stableJson(v: unknown): string {
  if (Array.isArray(v)) return `[${v.map(stableJson).join(",")}]`;
  if (v && typeof v === "object") {
    return `{${Object.keys(v as Record<string, unknown>).sort().map((k) => `${JSON.stringify(k)}:${stableJson((v as Record<string, unknown>)[k])}`).join(",")}}`;
  }
  return JSON.stringify(v ?? null);
}

/** sha256 hex of the org, event, platform and every request the plan would send. */
export async function confirmDigest(orgId: string, eventId: string, platform: SocialPlatform, steps: readonly StepView[]): Promise<string> {
  const text = stableJson({ org: orgId, event: eventId, platform, steps: steps.map((s) => ({ method: s.method, path: s.path, body: s.body })) });
  const h = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text));
  return Array.from(new Uint8Array(h), (b) => b.toString(16).padStart(2, "0")).join("");
}

/** One platform's pass. sendAllowed false: a plan (nothing can be sent, whatever the switches say). */
async function runPlatform(d: RunDeps, req: PlanRequest, platform: SocialPlatform, sendAllowed: boolean): Promise<PlatformPlan> {
  const now = d.now?.() ?? new Date();
  const audited = d.env("EXOS_TIKTOK_APP_AUDITED") === "on";
  const attendees = typeof req.event.capacity === "number" && req.event.capacity >= 0 ? req.event.capacity : null;
  const ev = { ...req.event, venue_org: req.venueOrg } as Record<string, unknown> & { id: string };
  const def = DEFS[platform];
  const post = composePost(req.event, platform, { appBase: d.appBase, now });
  const cred = await credentialFor(d, def);
  const memory = memoryAuditSink();
  const audit = d.persistAudit === false ? memory : teeSink(memory, rpcAuditSink(d.rpc, d.orgId));
  const o = def.http(cred);
  const facts = def.facts?.(cred, now) ?? {};
  const http = createGatedHttp({
    channel: o.channel, base: o.base, writes: o.writes, headers: o.headers, secrets: o.secrets, standIn: o.standIn,
    fetch: d.fetch, env: d.env,
    orgWritesEnabled: sendAllowed && !SOCIAL_WRITES_PINNED_OFF ? cred.writesEnabled : false,
    audit,
    limits: { ...(o.limits ?? {}), facts, counter: d.counter ?? rpcUsageCounter(d.rpc, d.orgId) },
    eventId: req.event.id,
    now: d.now,
  });
  const ctx: ChannelCtx = { orgId: d.orgId, creds: cred, http, audit, facts };
  try {
    const result = await def.run(ctx, ev, post, {
      attendees, audited, tiktok: req.tiktok ?? {},
      meetupDraftId: typeof req.meetupDraftId === "string" ? req.meetupDraftId : null,
    }) as AdsResult;
    const fam = familyOf(def.provider);
    const steps = memory.steps.map(view);
    const sends = steps.some((s) => !/creator_info/.test(s.path));
    return {
      platform, label: PLATFORM_LABEL[platform], post, result, steps,
      confirm: !result.stopped && sends ? await confirmDigest(d.orgId, req.event.id, platform, steps) : null,
      status: {
        connected: usable(cred), provider: def.provider, dryRun: !http.writesLive, app: fam,
        connect: fam ? VENDOR_APPS[fam].connect : "stub",
      },
    };
  } finally {
    await audit.flush?.();
  }
}

/** Plan the chosen platforms' posts / listings for one event, from one post kit. Never sends. */
export async function planSocial(d: RunDeps, req: PlanRequest): Promise<{ platforms: PlatformPlan[] }> {
  const asked = (req.platforms ?? SOCIAL_PLATFORMS).filter((p) => SOCIAL_PLATFORMS.includes(p));
  const out: PlatformPlan[] = [];
  for (const platform of asked) out.push(await runPlatform(d, req, platform, false));
  return { platforms: out };
}

export type PublishOutcome =
  | { published: false; reason: "no_confirm" | "changed" | "stopped" | "pinned"; plan: PlatformPlan }
  | { published: true; plan: PlatformPlan; result: PlatformPlan };

/**
 * Publish one platform's plan, only with the confirm digest the organizer
 * saw: re-planned first, refused if it changed or stopped. While
 * SOCIAL_WRITES_PINNED_OFF, every publish ends at "pinned" (nothing sent).
 */
export async function publishSocial(d: RunDeps, req: PlanRequest & { platform: SocialPlatform; confirm: string }): Promise<PublishOutcome> {
  const plan = await runPlatform({ ...d, persistAudit: false }, req, req.platform, false);
  if (!/^[0-9a-f]{64}$/.test(req.confirm ?? "")) return { published: false, reason: "no_confirm", plan };
  if (!plan.confirm) return { published: false, reason: "stopped", plan };
  if (plan.confirm !== req.confirm) return { published: false, reason: "changed", plan };
  if (SOCIAL_WRITES_PINNED_OFF) return { published: false, reason: "pinned", plan };
  const result = await runPlatform(d, req, req.platform, true);
  return { published: true, plan, result };
}
