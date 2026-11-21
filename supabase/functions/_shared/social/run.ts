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

import type { ChannelAdapter, ChannelCtx, OrgCredential } from "../channels/adapter.ts";
import { createGatedHttp, type WriteRule } from "../channels/gatedHttp.ts";
import { memoryAuditSink, rpcAuditSink, teeSink, type AuditStep } from "../channels/audit.ts";
import { rpcUsageCounter, type UsageCounter } from "../channels/usage.ts";
import { loadCredential } from "../channels/credentials.ts";
import type { LimitFacts } from "../channels/limits.ts";
import type { AdsResult } from "../channels/adapters/adsCommon.ts";
import { instagramAdapter, instagramHttp } from "../channels/adapters/instagram.ts";
import { tiktokAdapter, tiktokHttp, tiktokPublish } from "../channels/adapters/tiktok.ts";
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

interface PlatformDef {
  adapter: ChannelAdapter;
  provider: string;
  /** A second store provider whose secret this one may borrow (GBP: the Google connection). */
  fallback?: string;
  http: (c: OrgCredential | null) => HttpOpts;
  facts?: (c: OrgCredential, now: Date) => LimitFacts;
  run: (ctx: ChannelCtx, ev: Record<string, unknown> & { id: string }, post: PlatformPost, extra: { attendees: number | null; audited: boolean }) => Promise<unknown>;
}

const DEFS: Record<SocialPlatform, PlatformDef> = {
  instagram: {
    adapter: instagramAdapter, provider: "ig_publish", http: instagramHttp,
    run: (ctx, ev, post) => instagramAdapter.publishPost!(ctx, ev, post),
  },
  tiktok: {
    adapter: tiktokAdapter, provider: "tiktok_publish", http: tiktokHttp,
    run: (ctx, ev, post, x) => tiktokPublish(x.audited)(ctx, ev, post),
  },
  meetup: {
    adapter: meetupAdapter, provider: "meetup", http: meetupHttp,
    facts: (c) => ({ plan: typeof c.config.plan === "string" ? c.config.plan.toLowerCase() : null }),
    run: (ctx, ev, post, x) => meetupAdapter.upsertEvent!(ctx, ev, { post, attendees: x.attendees }),
  },
  linkedin: {
    adapter: linkedinAdapter, provider: "linkedin", http: linkedinHttp,
    run: (ctx, ev, post) => linkedinAdapter.upsertEvent!(ctx, ev, { post }),
  },
  google_business: {
    adapter: googleBusinessAdapter, provider: "google_business", fallback: "ads_google_ads",
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
  /** Where the secret would come from (GBP borrowing the Google connection). */
  via?: string;
}

export interface PlatformPlan {
  platform: SocialPlatform;
  label: string;
  status: PlatformStatus;
  post: PlatformPost;
  result: AdsResult;
  steps: StepView[];
}

const NONE = (provider: string): OrgCredential =>
  ({ provider, status: "unverified", config: {}, secret: null, writesEnabled: false, accountName: null, source: "none" });

const usable = (c: OrgCredential | null) => !!c && !!c.secret && c.status !== "disabled";

async function credentialFor(d: RunDeps, def: PlatformDef): Promise<{ cred: OrgCredential; via?: string }> {
  const c = await loadCredential(d.rpc, d.orgId, def.provider).catch(() => null);
  if (usable(c) || !def.fallback) return { cred: c ?? NONE(def.provider) };
  const f = await loadCredential(d.rpc, d.orgId, def.fallback).catch(() => null);
  if (!usable(f)) return { cred: c ?? NONE(def.provider) };
  // The config (account, location, verified_at) stays this provider's; only the secret is borrowed.
  return { cred: { ...(c ?? NONE(def.provider)), secret: f!.secret, status: f!.status }, via: def.fallback };
}

/** Plan the chosen platforms' posts / listings for one event, from one post kit. */
export async function planSocial(d: RunDeps, req: {
  event: SocialEventInput & { id: string; capacity?: number | null };
  venueOrg: boolean;
  platforms?: readonly SocialPlatform[];
}): Promise<{ platforms: PlatformPlan[] }> {
  const now = d.now?.() ?? new Date();
  const asked = (req.platforms ?? SOCIAL_PLATFORMS).filter((p) => SOCIAL_PLATFORMS.includes(p));
  const audited = d.env("EXOS_TIKTOK_APP_AUDITED") === "on";
  const attendees = typeof req.event.capacity === "number" && req.event.capacity >= 0 ? req.event.capacity : null;
  const ev = { ...req.event, venue_org: req.venueOrg } as Record<string, unknown> & { id: string };
  const out: PlatformPlan[] = [];
  for (const platform of asked) {
    const def = DEFS[platform];
    const post = composePost(req.event, platform, { appBase: d.appBase, now });
    const { cred, via } = await credentialFor(d, def);
    const memory = memoryAuditSink();
    const audit = d.persistAudit === false ? memory : teeSink(memory, rpcAuditSink(d.rpc, d.orgId));
    const o = def.http(cred);
    const facts = def.facts?.(cred, now) ?? {};
    const http = createGatedHttp({
      channel: o.channel, base: o.base, writes: o.writes, headers: o.headers, secrets: o.secrets, standIn: o.standIn,
      fetch: d.fetch, env: d.env,
      orgWritesEnabled: SOCIAL_WRITES_PINNED_OFF ? false : cred.writesEnabled,
      audit,
      limits: { ...(o.limits ?? {}), facts, counter: d.counter ?? rpcUsageCounter(d.rpc, d.orgId) },
      eventId: req.event.id,
      now: d.now,
    });
    const ctx: ChannelCtx = { orgId: d.orgId, creds: cred, http, audit, facts };
    try {
      const result = await def.run(ctx, ev, post, { attendees, audited }) as AdsResult;
      const fam = familyOf(def.provider);
      out.push({
        platform, label: PLATFORM_LABEL[platform], post, result, steps: memory.steps.map(view),
        status: {
          connected: usable(cred), provider: def.provider, dryRun: !http.writesLive, app: fam,
          connect: fam ? VENDOR_APPS[fam].connect : "stub", ...(via ? { via } : {}),
        },
      });
    } finally {
      await audit.flush?.();
    }
  }
  return { platforms: out };
}
