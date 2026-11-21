// Platform limits and quotas: the ONE table every channel adapter, the
// allocation and the recommendation logic read (channel core, mig
// 20261121162400; operator 2026-11-21: "platform limits built into the
// core"). Pure: no Deno or Node APIs, so the SPA (vitest, the allocation and
// "What we'd send" views) imports it as well.
//
// SINGLE SOURCE. The promotion work (discovery / catalog / PromoteEvent,
// built on a parallel branch) keeps a simpler warnings table for its
// listing suggestions; when the branches merge, point it at limitNotes() /
// PLATFORM_LIMITS here and delete its copy.
//
// Each platform has its own data table of rules: id, rule, scope, threshold,
// window, action, the reason shown to the organizer, and the source (URL and
// the date it was checked; null where the operator's brief is the only
// source so far, which `source.note` says). `kind` picks the check:
//   free_event           the event is free                       (Shotgun)
//   zero_price           the tier / listing is $0                 (resale)
//   free_must_be_public  free AND hidden / invite-only            (Google)
//   attendees_per_event  allocation over `threshold`              (Meetup)
//   active_events        upcoming events already at `threshold`   (AllEvents)
//   min_profile_age_days the account / profile is younger than   (Google Business
//                        `threshold` days (unknown = too young)   Profile posts)
//   usage                a counted metric over a rolling window   (Luma, LinkedIn,
//                        pretix, Ticket Tailor, Eventbrite, the Reddit Ads
//                        API's per-minute rates, Instagram's posts a
//                        day, Meetup's GraphQL points) read from
//                        exos_channel_usage (usage.ts)
// Actions: block refuses with the reason; cap trims (maxUnits) or makes the
// caller chunk (chunkToBudget); warn lets it through and records the warning.
// Where a plan or account level decides the number and Exos doesn't know it,
// the LOWER bound applies (Meetup Starter, Luma's new-calendar 15).

export type LimitAction = "block" | "warn" | "cap";
export type LimitWindow = "minute" | "quarter_hour" | "day" | "week" | "year";
export type LimitScope = "event" | "tier" | "org" | "account" | "calendar";
export type LimitKind =
  | "free_event" | "zero_price" | "free_must_be_public" | "attendees_per_event" | "active_events" | "min_profile_age_days" | "usage";

export interface LimitSource {
  url: string | null;
  /** YYYY-MM-DD the rule was last checked against the source. */
  checked: string | null;
  note?: string;
}

export interface LimitRule {
  id: string;
  platform: string;
  /** The platform's rule, in a few words. */
  rule: string;
  scope: LimitScope;
  threshold: number | null;
  window: LimitWindow | null;
  action: LimitAction;
  /** Shown to the organizer when the rule applies. */
  reason: string;
  source: LimitSource;
  kind: LimitKind;
  /** usage: the counted metric (exos_channel_usage.metric). */
  metric?: string;
  /** usage + warn: warn once live + this request reaches this share of the threshold (default 1). */
  warnAt?: number;
  /** usage: the threshold once the account is unlocked (Luma 500). */
  unlockedThreshold?: number;
  /** Applies on these plans, or when the plan is unknown (the lower bound). */
  plans?: readonly string[];
  /** usage: applies to the hosted service only (pretix.eu); unknown counts as hosted. */
  hostedOnly?: boolean;
  /** usage: also warn before ANY API-based mirror (Ticket Tailor counts API tickets). */
  warnOnApiMirror?: boolean;
  /** false: the number is unconfirmed (from search only). */
  verified?: boolean;
}

const BRIEF = (note = "operator brief 2026-11-21; source URL still to record"): LimitSource => ({ url: null, checked: null, note });

const resale = (platform: string, label: string): LimitRule => ({
  id: `${platform}_no_free_tiers`,
  platform,
  rule: "no $0 listings",
  scope: "tier",
  threshold: 0,
  window: null,
  action: "block",
  kind: "zero_price",
  reason: `${label} is a resale marketplace: a $0 ticket type is never offered there (StubHub International bans free events).`,
  source: BRIEF(),
});

const redditRate = (id: string, rule: string, threshold: number, window: LimitWindow, metric: string, reason: string): LimitRule => ({
  id, platform: "reddit", rule, scope: "account", threshold, window, action: "cap", kind: "usage", metric, reason,
  source: BRIEF("operator brief 2026-11-21 (ads phase): Reddit Ads API v3 rate limits; the unit of the audience limit (requests) unverified"),
});

// The social posting / listing phase (mig 20261121203000, docs/social.md
// "Posting and listing APIs"): numbers from the operator's brief, each
// still to check against the platform's docs before anything goes live.
const SOCIAL = (note: string): LimitSource => BRIEF(`operator brief 2026-11-21 (social phase): ${note}`);

/** One data table per platform. */
export const PLATFORM_LIMITS: Readonly<Record<string, readonly LimitRule[]>> = {
  shotgun: [{
    id: "shotgun_free_exclusive",
    platform: "shotgun",
    rule: "free events: 100% free, no parallel ticketing elsewhere",
    scope: "event",
    threshold: null,
    window: null,
    action: "block",
    kind: "free_event",
    reason: "Shotgun lists a free event only if it is 100% free there with no parallel ticketing elsewhere, so a free Exos event is not mirrored or listed on Shotgun.",
    source: { url: "https://support-pro.shotgun.live/hc/en-us/articles/33562373508498", checked: "2026-11-17", note: "Shotgun Pro help article 33562373508498" },
  }],
  meetup: [{
    id: "meetup_starter_attendees",
    platform: "meetup",
    rule: "Starter plan: 10 attendees per event",
    scope: "event",
    threshold: 10,
    window: null,
    action: "cap",
    kind: "attendees_per_event",
    plans: ["starter"],
    reason: "Meetup's Starter plan takes 10 attendees per event: the allocation is capped at 10. A Standard or Pro plan is needed for more.",
    source: BRIEF(),
  }, {
    id: "meetup_graphql_points",
    platform: "meetup",
    rule: "500 GraphQL points per 60 seconds",
    scope: "account",
    threshold: 500,
    window: "minute",
    action: "cap",
    kind: "usage",
    metric: "points",
    reason: "Meetup's API allows 500 points of GraphQL work per 60 seconds: the rest waits for the next minute.",
    source: SOCIAL("Meetup GraphQL rate limit; what each mutation costs in points is unverified (Exos counts an estimate)"),
  }],
  pretix: [{
    id: "pretix_hosted_free_tickets",
    platform: "pretix",
    rule: "hosted: 500 free tickets a year per account, then €0.50 each",
    scope: "account",
    threshold: 500,
    window: "year",
    action: "warn",
    kind: "usage",
    metric: "tickets",
    warnAt: 0.8,
    hostedOnly: true,
    reason: "pretix.eu includes 500 free tickets a year per account; after that each ticket costs €0.50.",
    source: BRIEF(),
  }],
  tickettailor: [{
    id: "tickettailor_api_tickets",
    platform: "tickettailor",
    rule: "5,000 free tickets a year; API-issued or imported tickets count 1 usage each, even at $0",
    scope: "account",
    threshold: 5000,
    window: "year",
    action: "warn",
    kind: "usage",
    metric: "tickets",
    warnAt: 0.8,
    warnOnApiMirror: true,
    reason: "Ticket Tailor counts every ticket issued through its API or imported as one usage, even at $0 (5,000 free a year): mirroring by API spends that allowance.",
    source: BRIEF(),
  }],
  allevents: [{
    id: "allevents_free_active_events",
    platform: "allevents",
    rule: "free plan: 5 active upcoming events",
    scope: "account",
    threshold: 5,
    window: null,
    action: "warn",
    kind: "active_events",
    plans: ["free"],
    reason: "AllEvents' free plan keeps 5 active upcoming events; another one needs a paid plan or an event to end first.",
    source: BRIEF(),
  }],
  stubhub: [resale("stubhub", "StubHub")],
  seatgeek: [resale("seatgeek", "SeatGeek")],
  vivid: [resale("vivid", "Vivid Seats")],
  tickpick: [resale("tickpick", "TickPick")],
  gametime: [resale("gametime", "Gametime")],
  gotickets: [resale("gotickets", "GoTickets")],
  evo: [resale("evo", "Ticket Evolution")],
  luma: [{
    id: "luma_weekly_sends",
    platform: "luma",
    rule: "15 sends a week on a new calendar, 500 once unlocked; adding guests counts; a bulk send over the limit fails entirely",
    scope: "calendar",
    threshold: 15,
    unlockedThreshold: 500,
    window: "week",
    action: "cap",
    kind: "usage",
    metric: "sends",
    reason: "Luma allows 15 sends a week on a new calendar (500 once unlocked), adding guests included, and a bulk send over the limit fails entirely: the work is split so no send goes over what is left this week.",
    source: BRIEF(),
  }],
  linkedin: [{
    id: "linkedin_weekly_invites",
    platform: "linkedin",
    rule: "1,000 invites a week across all events",
    scope: "account",
    threshold: 1000,
    window: "week",
    action: "cap",
    kind: "usage",
    metric: "invites",
    reason: "LinkedIn allows 1,000 event invites a week across all events: invites past that wait for next week.",
    source: BRIEF(),
  }],
  eventbrite: [{
    id: "eventbrite_daily_emails",
    platform: "eventbrite",
    rule: "about 250 emails a day",
    scope: "account",
    threshold: 250,
    window: "day",
    action: "warn",
    kind: "usage",
    metric: "emails",
    verified: false,
    reason: "Eventbrite appears to allow about 250 emails a day (unconfirmed: from search only).",
    source: BRIEF("operator brief 2026-11-21: from search only, unverified"),
  }],
  // Reddit Ads API v3 rate limits (ads phase, mig 20261121190500): per
  // account, rolling. GatedHttp counts a request against the metric its
  // caller names (usage): reddit_ads writes "writes" (an audience upload
  // counts "audience_uploads" instead), reads "reads", targeting look-ups
  // "targeting". A cap trims or defers the request; nothing is sent here
  // while the ads adapters are dry runs.
  reddit: [
    redditRate("reddit_writes", "200 write requests a minute", 200, "minute", "writes",
      "Reddit's Ads API takes 200 write requests a minute per account: the rest wait for the next minute."),
    redditRate("reddit_reads", "400 read requests a minute", 400, "minute", "reads",
      "Reddit's Ads API takes 400 read requests a minute per account: the rest wait for the next minute."),
    redditRate("reddit_targeting", "100 targeting requests a minute", 100, "minute", "targeting",
      "Reddit's Ads API takes 100 targeting look-ups a minute per account: the rest wait for the next minute."),
    redditRate("reddit_audience_uploads", "3,000 audience uploads per 15 minutes", 3000, "quarter_hour", "audience_uploads",
      "Reddit takes 3,000 custom-audience uploads per 15 minutes per account: the rest of the list waits for the next window."),
  ],
  instagram: [{
    id: "instagram_daily_posts",
    platform: "instagram",
    rule: "100 API-published posts per 24 hours",
    scope: "account",
    threshold: 100,
    window: "day",
    action: "cap",
    kind: "usage",
    metric: "posts",
    reason: "Instagram publishes at most 100 posts through the API per account in 24 hours: more wait for the next day.",
    source: SOCIAL("Instagram content publishing limit (GET /<ig-user>/content_publishing_limit reads the live number)"),
  }],
  tiktok: [{
    id: "tiktok_init_rate",
    platform: "tiktok",
    rule: "6 post-initialize requests a minute per user token",
    scope: "account",
    threshold: 6,
    window: "minute",
    action: "cap",
    kind: "usage",
    metric: "inits",
    verified: false,
    reason: "TikTok takes about 6 post requests a minute per connected account (unverified): the rest wait for the next minute.",
    source: SOCIAL("TikTok Content Posting API rate limit, from search only, unverified"),
  }, {
    id: "tiktok_daily_posts",
    platform: "tiktok",
    rule: "a daily cap on posts per creator",
    scope: "account",
    threshold: 15,
    window: "day",
    action: "warn",
    kind: "usage",
    metric: "posts",
    warnAt: 0.8,
    verified: false,
    reason: "TikTok caps how many posts a creator can make through the API each day (about 15; the creator_info answer says when it is reached; unverified).",
    source: SOCIAL("TikTok daily creator post cap, from search only, unverified"),
  }],
  google_business: [{
    id: "gbp_profile_age",
    platform: "google_business",
    rule: "a verified Business Profile at least 60 days old",
    scope: "account",
    threshold: 60,
    window: null,
    action: "block",
    kind: "min_profile_age_days",
    reason: "Google Business Profile event posts need a verified profile that has been verified for at least 60 days: until then, nothing is posted.",
    source: SOCIAL("GBP API access needs a verified profile 60+ days old (Google's access request form)"),
  }],
  google_events: [{
    id: "google_free_public",
    platform: "google_events",
    rule: "free events must be publicly bookable",
    scope: "event",
    threshold: null,
    window: null,
    action: "warn",
    kind: "free_must_be_public",
    reason: "Google shows a free event only if anyone can book it: this one is hidden or invite-only.",
    source: BRIEF(),
  }],
};

export function rulesFor(platform: string): readonly LimitRule[] {
  return PLATFORM_LIMITS[platform] ?? [];
}

/** Every rule, for docs and the tests. */
export function allRules(): LimitRule[] {
  return Object.values(PLATFORM_LIMITS).flat();
}

export const WINDOW_SECONDS: Record<LimitWindow, number> = { minute: 60, quarter_hour: 900, day: 86_400, week: 7 * 86_400, year: 365 * 86_400 };
export function windowSeconds(w: LimitWindow | null | undefined): number {
  return w ? WINDOW_SECONDS[w] : 0;
}

/** What the caller knows about the event / tier / account (unknown = undefined or null). */
export interface LimitFacts {
  /** Every ticket type is $0. */
  free?: boolean;
  /** The tier or listing being offered, in cents. */
  priceCents?: number | null;
  hidden?: boolean;
  inviteOnly?: boolean;
  /** The org's plan on the platform (lower case); null / undefined = unknown. */
  plan?: string | null;
  /** Luma: 'unlocked' raises the weekly sends; unknown = new. */
  accountLevel?: "new" | "unlocked" | null;
  /** pretix: false = self-hosted (no ticket allowance); unknown = hosted. */
  hosted?: boolean | null;
  /** The mirror issues tickets through the platform's API. */
  apiMirror?: boolean;
  activeUpcomingEvents?: number | null;
  /** The allocation being set for the event. */
  attendees?: number | null;
  /** Days since the profile / account was verified (Google Business Profile); unknown = too young. */
  profileAgeDays?: number | null;
}

export interface UsageReading { live: number; planned: number }
/** By metric. */
export type UsageReadings = Record<string, UsageReading>;
export interface LimitRequest { metric: string; n: number }

export interface LimitHit {
  ruleId: string;
  platform: string;
  action: LimitAction;
  rule: string;
  reason: string;
  threshold: number | null;
  source: LimitSource;
  /** usage: live in the window, planned (dry run) in the window, what is left, this request. */
  used?: number;
  planned?: number;
  remaining?: number;
  would?: number;
}

/** A counted rule's standing, for "would use N of M". */
export interface LimitMeter {
  ruleId: string;
  platform: string;
  metric: string;
  window: LimitWindow | null;
  threshold: number;
  live: number;
  planned: number;
  would: number;
}

export interface LimitVerdict {
  /** No block, and the request (if any) fits under maxUnits. */
  allowed: boolean;
  blocks: LimitHit[];
  caps: LimitHit[];
  warnings: LimitHit[];
  /** The most units this request may use (cap rules), or null for no cap. */
  maxUnits: number | null;
  meters: LimitMeter[];
}

const appliesToPlan = (r: LimitRule, plan: string | null | undefined) =>
  !r.plans || plan === null || plan === undefined || plan === "" || r.plans.includes(plan.toLowerCase());

/** The threshold that applies: Luma's unlocked level only when known. */
export function thresholdFor(r: LimitRule, facts: LimitFacts): number | null {
  if (r.unlockedThreshold !== undefined && facts.accountLevel === "unlocked") return r.unlockedThreshold;
  return r.threshold;
}

function hit(r: LimitRule, extra: Partial<LimitHit> = {}): LimitHit {
  return { ruleId: r.id, platform: r.platform, action: r.action, rule: r.rule, reason: r.reason, threshold: r.threshold, source: r.source, ...extra };
}

/**
 * Every rule of the platform against the facts, the usage readings (by
 * metric, in each rule's window) and the request about to be planned or
 * sent. Pure.
 */
export function evaluateLimits(
  platform: string, facts: LimitFacts = {}, usage: UsageReadings = {}, request?: LimitRequest | null,
): LimitVerdict {
  const v: LimitVerdict = { allowed: true, blocks: [], caps: [], warnings: [], maxUnits: null, meters: [] };
  const lower = (n: number) => { v.maxUnits = v.maxUnits === null ? n : Math.min(v.maxUnits, n); };
  const push = (h: LimitHit) => (h.action === "block" ? v.blocks : h.action === "cap" ? v.caps : v.warnings).push(h);
  for (const r of rulesFor(platform)) {
    if (!appliesToPlan(r, facts.plan)) continue;
    switch (r.kind) {
      case "free_event":
        if (facts.free === true) push(hit(r));
        break;
      case "zero_price":
        if (facts.priceCents === 0 || ((facts.priceCents === undefined || facts.priceCents === null) && facts.free === true)) push(hit(r));
        break;
      case "free_must_be_public":
        if (facts.free === true && (facts.hidden === true || facts.inviteOnly === true)) push(hit(r));
        break;
      case "attendees_per_event": {
        const t = r.threshold ?? 0;
        // Only an attendee count (or no request: a view) is trimmed by it.
        if (!request || request.metric === "attendees") lower(t);
        if (facts.attendees === undefined || facts.attendees === null || facts.attendees > t) {
          push(hit(r, { remaining: t, would: facts.attendees ?? undefined }));
        }
        break;
      }
      case "min_profile_age_days": {
        const t = r.threshold ?? 0;
        const age = facts.profileAgeDays;
        if (age === undefined || age === null || !Number.isFinite(age) || age < t) push(hit(r, { used: age ?? undefined, remaining: t }));
        break;
      }
      case "active_events": {
        const t = r.threshold ?? 0;
        if ((facts.activeUpcomingEvents ?? 0) >= t) push(hit(r, { used: facts.activeUpcomingEvents ?? 0, remaining: 0 }));
        break;
      }
      case "usage": {
        if (r.hostedOnly && facts.hosted === false) break;
        const t = thresholdFor(r, facts);
        if (t === null || !r.metric) break;
        const u = usage[r.metric] ?? { live: 0, planned: 0 };
        const n = request && request.metric === r.metric ? Math.max(0, request.n) : 0;
        const remaining = Math.max(t - u.live, 0);
        v.meters.push({ ruleId: r.id, platform: r.platform, metric: r.metric, window: r.window, threshold: t, live: u.live, planned: u.planned, would: n });
        const extra = { threshold: t, used: u.live, planned: u.planned, remaining, would: n };
        if (r.action === "cap") {
          // A budget trims only a request in its own metric (or a view with none).
          if (!request || request.metric === r.metric) lower(remaining);
          if (n > remaining || (n === 0 && remaining === 0)) push(hit(r, extra));
        } else if (r.action === "block") {
          if (u.live + n > t) push(hit(r, extra));
        } else {
          const at = Math.ceil(t * (r.warnAt ?? 1));
          if (u.live + n >= at) push(hit(r, extra));
          else if (r.warnOnApiMirror && facts.apiMirror === true) push(hit(r, extra));
        }
        break;
      }
    }
  }
  v.allowed = v.blocks.length === 0 && (!request || v.maxUnits === null || request.n <= v.maxUnits);
  return v;
}

/**
 * Split work so no single send goes over what is left: at most `remaining`
 * items in all, in chunks of at most `maxPerChunk` (default: remaining).
 * What doesn't fit is deferred to the next window.
 */
export function chunkToBudget<T>(items: readonly T[], remaining: number, maxPerChunk?: number): { chunks: T[][]; deferred: T[] } {
  const budget = Math.max(0, Math.floor(remaining));
  const size = Math.max(1, Math.floor(Math.min(maxPerChunk ?? budget, budget) || 1));
  const take = items.slice(0, budget);
  const chunks: T[][] = [];
  for (let i = 0; i < take.length; i += size) chunks.push(take.slice(i, i + size));
  return { chunks, deferred: items.slice(take.length) };
}

const WINDOW_WORD: Record<LimitWindow, string> = {
  minute: "this minute", quarter_hour: "in these 15 minutes", day: "today", week: "this week", year: "this year",
};

/** "would use 4 of 15 sends this week (10 used, 2 planned)". */
export function meterLine(m: LimitMeter): string {
  const when = m.window ? ` ${WINDOW_WORD[m.window]}` : "";
  const total = m.live + m.would;
  const parts = [`${m.live} used`];
  if (m.planned > 0) parts.push(`${m.planned} planned`);
  return `would use ${total} of ${m.threshold} ${m.metric}${when} (${parts.join(", ")})`;
}

/** One line per thing to show the organizer, most serious first. */
export interface LimitNote { action: LimitAction; ruleId: string; platform: string; text: string; source: LimitSource }

export function limitNotes(verdict: LimitVerdict): LimitNote[] {
  const meter = (h: LimitHit) => verdict.meters.find((m) => m.ruleId === h.ruleId);
  const line = (h: LimitHit): LimitNote => {
    const m = meter(h);
    return { action: h.action, ruleId: h.ruleId, platform: h.platform, text: m ? `${h.reason} ${capitalize(meterLine(m))}.` : h.reason, source: h.source };
  };
  return [...verdict.blocks.map(line), ...verdict.caps.map(line), ...verdict.warnings.map(line)];
}

/** Shortcut for views: the notes for a platform and the facts they have. */
export function notesFor(platform: string, facts: LimitFacts = {}, usage: UsageReadings = {}): LimitNote[] {
  return limitNotes(evaluateLimits(platform, facts, usage));
}

function capitalize(s: string): string {
  return s ? s[0].toUpperCase() + s.slice(1) : s;
}
