// Google Business Profile event posts on the channel core (social phase, mig
// 20261121203000; docs/social.md "Posting and listing APIs"): publishPost as
// a localPost with topicType EVENT on a VENUE org's own verified profile.
// DRY RUN ONLY: the one write is on the allowlist below and goes through
// ctx.http (GatedHttp); exos-social pins the org's switch off and
// EXOS_GOOGLE_BUSINESS_WRITES is off.
//
//   POST https://mybusiness.googleapis.com/v4/accounts/<account>/locations/<location>/localPosts
//     {languageCode, summary, topicType: EVENT,
//      event: {title, schedule: {startDate, startTime, endDate, endTime}},
//      media: [{mediaFormat: PHOTO, sourceUrl}], callToAction: {actionType: BOOK, url}}
//
// WHO. Only an org that owns a venue (exos_venues, relationship 'owned'),
// with its Business Profile verified for 60 days or more (limits.ts
// "google_business", a block: unknown counts as too young). GBP has no
// draft: a post goes live once Google's review passes.
//
// ACCESS. The Business Profile APIs need Google's access request form
// (Google Business Profile API: "request access"; the project's quota is 0
// until Google approves). The credential is Business Profile's OWN: its own
// sign-in on the existing Google OAuth client with
// https://www.googleapis.com/auth/business.manage alone (not built;
// _shared/social/apps.ts), never the Google Ads connection, which never
// carries that scope. Provider google_business in the store (managed) holds
// config account_id, location_id, verified_at (YYYY-MM-DD) and its own
// refresh token. A live send would swap that refresh token for an access
// token;
// a dry run never calls Google, so the header holds a placeholder.
//
// VERIFIED (the v4 localPosts resource is the public, documented one): the
// path, topicType EVENT, event.schedule as Date + TimeOfDay, media
// PHOTO / sourceUrl, callToAction BOOK. UNVERIFIED (Google's docs were not
// readable from the build session): the 1,500-character summary, the
// 58-character event title, that a phone number in the text is rejected, and
// how long review takes.

import { caps, type ChannelAdapter, type ChannelCtx, type ExosEvent, type OrgCredential, type SocialPost } from "../adapter.ts";
import type { WriteRule } from "../gatedHttp.ts";
import type { PlatformPost } from "../../social/postKit.ts";
import { cfgOr, createdId, newResult, standInBy, write, type AdsResult } from "./adsCommon.ts";

export const GBP_BASE = "https://mybusiness.googleapis.com";
const ID = "(?:[0-9]{1,30}|planned_account|planned_location)";

/** Exactly the write the GBP adapter makes. */
export const GOOGLE_BUSINESS_WRITES: WriteRule[] = [
  { method: "POST", path: new RegExp(`^/v4/accounts/${ID}/locations/${ID}/localPosts$`) },
];

export const googleBusinessStandIn = standInBy([[/\/localPosts$/, "local_post"]], (id) => ({ name: `accounts/planned_account/locations/planned_location/localPosts/${id}` }));

/** GatedHttp options. `accessToken`: only for a live send; without one the header is a placeholder. */
export function googleBusinessHttp(creds: OrgCredential | null, accessToken?: string | null) {
  const loc = typeof creds?.config.location_id === "string" ? creds.config.location_id : "";
  return {
    channel: "google_business",
    base: GBP_BASE,
    writes: GOOGLE_BUSINESS_WRITES,
    headers: { Authorization: `Bearer ${accessToken ?? "<oauth access token>"}` },
    secrets: [creds?.secret, accessToken],
    standIn: googleBusinessStandIn,
    limits: { platform: "google_business", scopeKey: loc.slice(0, 64) },
  };
}

/** Days since verified_at (YYYY-MM-DD), or null when unknown. */
export function profileAgeDays(verifiedAt: unknown, now: Date): number | null {
  if (typeof verifiedAt !== "string" || !/^\d{4}-\d{2}-\d{2}/.test(verifiedAt)) return null;
  const t = Date.parse(verifiedAt.slice(0, 10) + "T00:00:00Z");
  return Number.isFinite(t) ? Math.floor((now.getTime() - t) / 86_400_000) : null;
}

/** {year, month, day} and {hours, minutes} in the event's zone. */
export function gbpDateTime(iso: string | null, tz: string): { date: Record<string, number>; time: Record<string, number> } | null {
  if (!iso) return null;
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return null;
  const p: Record<string, string> = {};
  try {
    for (const x of new Intl.DateTimeFormat("en-US", { timeZone: tz, year: "numeric", month: "2-digit", day: "2-digit", hour: "2-digit", minute: "2-digit", hourCycle: "h23" }).formatToParts(d)) p[x.type] = x.value;
  } catch {
    return null;
  }
  return { date: { year: +p.year, month: +p.month, day: +p.day }, time: { hours: +p.hour, minutes: +p.minute } };
}

async function publishPost(ctx: ChannelCtx, ev: ExosEvent, postIn: SocialPost): Promise<AdsResult> {
  const post = postIn as PlatformPost;
  const res = newResult("google_business", ctx);
  if (ev.venue_org !== true) {
    res.stopped = "Google Business Profile posts are for organizations that run their own venue (add it under Booking → Venues).";
    return res;
  }
  const account = cfgOr(ctx.creds.config, "account_id", /^[0-9]{1,30}$/, "account");
  const location = cfgOr(ctx.creds.config, "location_id", /^[0-9]{1,30}$/, "location");
  if (!res.connected || !account.set || !location.set) {
    res.warnings.push("Google Business Profile isn't connected: the profile below is a placeholder.");
  }
  res.warnings.push("Google Business Profile has no draft: the post would go live once Google's review passes.");
  const start = gbpDateTime(post.startsAt, post.timezone);
  if (!start) { res.stopped = "The event has no start time."; return res; }
  const end = gbpDateTime(post.endsAt, post.timezone) ?? start;
  const r = await write(ctx, res, "POST", `/v4/accounts/${account.value}/locations/${location.value}/localPosts`, {
    languageCode: "en-US",
    summary: post.text.slice(0, 1500),
    topicType: "EVENT",
    event: {
      title: (post.title ?? "").slice(0, 58),
      schedule: { startDate: start.date, startTime: start.time, endDate: end.date, endTime: end.time },
    },
    ...(post.imageUrl ? { media: [{ mediaFormat: "PHOTO", sourceUrl: post.imageUrl }] } : {}),
    ...(post.url ? { callToAction: { actionType: "BOOK", url: post.url } } : {}),
  }, { op: "post.local_post" });
  if (r.error === "LIMIT_BLOCKED") {
    res.stopped = r.limit?.blocks[0]?.reason ?? "blocked by Google's rules";
    return res;
  }
  const id = createdId(r, (b) => b?.name);
  if (id) res.ids.local_post = id;
  else res.stopped = r.error ?? "not posted";
  return res;
}

export const googleBusinessAdapter: ChannelAdapter = {
  id: "google_business",
  label: "Google Business Profile",
  status: "core",
  caps: caps({ role: "secondary", publishPost: true }),
  writes: GOOGLE_BUSINESS_WRITES,
  publishPost,
};
