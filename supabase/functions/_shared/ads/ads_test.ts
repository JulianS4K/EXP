// The ads phase (mig 20261121190500), dry run only: payload shapes per
// platform, Reddit's email normalization, chunking, the allowlists (exactly
// the write paths; anything else refused), dry runs that never call fetch,
// the limits, the X sender and the insights stub. No network: every fetch
// here is a stub, and the dry-run tests count that it was never called.
import { assert, assertEquals, assertRejects, assertStringIncludes } from "jsr:@std/assert@1";
import { hashedIdentifiers, normalizeEmailReddit, sha256Hex, type HashedIdentifiers } from "../hashedIds.ts";
import { buildReddit, REDDIT_MAX_EVENTS, REDDIT_TRACKING_TYPE, redditBatches } from "../conversions/reddit.ts";
import { MAX_AGE_MS, type ConversionRow } from "../conversions/common.ts";
import { buildX } from "../conversions/x.ts";
import { buildConversionRequest, plannedOnly } from "../conversions/send.ts";
import { drainXRow } from "../conversions/xDrain.ts";
import { oauth1Header, parseXTokenSecret } from "../oauth1.ts";
import { buildAudience, googleMembers, metaRows, redditRows } from "./audience.ts";
import { adGeo, cityZips, AD_CITIES } from "./geo.ts";
import { boostConfig, planCampaign, type CampaignEventInput } from "./planner.ts";
import { ADS_WRITES_PINNED_OFF, planAudienceSync, planBoost } from "./run.ts";
import { createGatedHttp, GatedHttpRefused, type WriteRule } from "../channels/gatedHttp.ts";
import { memoryAuditSink } from "../channels/audit.ts";
import { memoryUsageCounter } from "../channels/usage.ts";
import { evaluateLimits, rulesFor } from "../channels/limits.ts";
import type { ChannelAdapter, ChannelCtx, OrgCredential } from "../channels/adapter.ts";
import { metaAdsAdapter, metaAdsHttp, META_ADS_WRITES } from "../channels/adapters/metaAds.ts";
import { redditAdsAdapter, redditAdsHttp, REDDIT_ADS_WRITES, REDDIT_AUDIENCE_WARNINGS } from "../channels/adapters/redditAds.ts";
import { googleCustomerMatchAdapter, googleCustomerMatchHttp, GOOGLE_CUSTOMER_MATCH_WRITES } from "../channels/adapters/googleCustomerMatch.ts";
import { xAdsAdapter, X_ADS_WRITES } from "../channels/adapters/xAds.ts";
import { ensureRegistry, ADAPTERS } from "../channels/registry.ts";
import { adapterProblems } from "../channels/adapter.ts";

const NOW = new Date("2026-11-21T12:00:00Z");
const ON = () => "on";
const OFF = () => undefined;

/** A fetch that records every call; `answer` builds the response. */
function stubFetch(answer: (url: string, init: RequestInit) => unknown = () => ({ id: "1" })) {
  const calls: Array<{ url: string; method: string; headers: Headers; body: any }> = [];
  const f = (async (input: RequestInfo | URL, init: RequestInit = {}) => {
    const url = String(input);
    calls.push({ url, method: init.method ?? "GET", headers: new Headers(init.headers), body: init.body ? JSON.parse(String(init.body)) : null });
    return new Response(JSON.stringify(answer(url, init)), { status: 200, headers: { "content-type": "application/json" } });
  }) as typeof fetch;
  return { f, calls };
}

const cred = (provider: string, config: Record<string, unknown>, secret: string | null = "TOKEN-secret-1234", writesEnabled = false): OrgCredential =>
  ({ provider, status: secret ? "connected" : "unverified", config, secret, writesEnabled, accountName: null, source: "store" });

type HttpOpts = { channel: string; base: string; writes: WriteRule[]; headers?: Record<string, string>; secrets?: readonly (string | null | undefined)[];
  standIn?: (m: any, p: string, b: unknown) => unknown; limits?: { platform?: string; scopeKey?: string } };

function ctxFor(o: HttpOpts, c: OrgCredential, f: typeof fetch, opts: { org?: boolean; env?: (k: string) => string | undefined; counter?: ReturnType<typeof memoryUsageCounter> } = {}) {
  const audit = memoryAuditSink();
  const http = createGatedHttp({ ...o, fetch: f, env: opts.env ?? OFF, orgWritesEnabled: opts.org ?? false, audit,
    limits: { ...(o.limits ?? {}), counter: opts.counter ?? memoryUsageCounter(() => NOW.getTime()) }, now: () => NOW });
  const ctx: ChannelCtx = { orgId: "org-1", creds: c, http, audit };
  return { ctx, audit };
}

/** Fake hashed members (no hashing cost): n people, every 3rd with a phone. */
function fakeMembers(n: number): HashedIdentifiers[] {
  return Array.from({ length: n }, (_, i) => {
    const h = (k: string) => k + i.toString(16).padStart(63, "0");
    return { em: h("e"), em_google: h("e"), em_reddit: h("e"), ...(i % 3 === 0 ? { ph: h("1"), ph_digits: h("2") } : {}) };
  });
}

const EVENT: CampaignEventInput = {
  id: "11111111-2222-4333-8444-555555555555", name: "Boost Night", slug: "boost-night", status: "published",
  starts_at: "2026-12-05T01:00:00Z", timezone: "America/New_York", currency: "USD", image_url: "https://img.example/boost.jpg",
  venue_name: "Hall", venue_address: { city: "Brooklyn", region: "NY" }, lat: 40.7181, lng: -73.9571, min_price_cents: 2500,
};
const PLAN = planCampaign(EVENT, boostConfig(OFF), { appBase: "https://exos.example", now: NOW });

// ---- Reddit: the conversions fixes ------------------------------------------

Deno.test("Reddit email normalization: lower case, +tag and local-part dots dropped on every domain; same hash as the SQL", async () => {
  assertEquals(normalizeEmailReddit(" J.o.e+tag@Example.com "), "joe@example.com");
  assertEquals(normalizeEmailReddit("first.last@gmail.com"), "firstlast@gmail.com");
  assertEquals(normalizeEmailReddit("a+b+c@x.com"), "a@x.com");
  assertEquals(normalizeEmailReddit("+tag@x.com"), null);
  assertEquals(normalizeEmailReddit("nope"), null);
  // tests/exos/test_ads.sql AD2 asserts the same constant for _exos_email_sha256_reddit.
  assertEquals(await sha256Hex(normalizeEmailReddit(" J.o.e+tag@Example.com ")!), "2481f36dfc515ca76451aaadf1399026942a01ee50c6d0a61988b43cef039bc2");
  const h = await hashedIdentifiers({ email: "J.o.e+tag@Example.com" });
  assertEquals(h.em_reddit, "2481f36dfc515ca76451aaadf1399026942a01ee50c6d0a61988b43cef039bc2");
  assertEquals(h.em, "c80b0350166dc95925839c9a933d146f114df43e24c5179cab83ede4431754c3", "the plain hash keeps the tag");
});

const row = (over: Partial<ConversionRow> = {}, payload: Partial<ConversionRow["payload"]> = {}): ConversionRow => ({
  id: "r1", platform: "reddit", event_name: "Purchase", event_id_dedupe: "cs_test_1", occurred_at: "2026-11-21T11:00:00Z",
  value_cents: 5000, currency: "usd",
  payload: { transaction_id: "cs_test_1", em: "a".repeat(64), em_reddit: "b".repeat(64), ad_ids: { rdt_cid: "rdt-1", twclid: "tw-1" }, quantity: 2,
             event: { id: "ev-1", slug: "s", name: "Show" }, ...payload },
  ...over,
});

Deno.test("Reddit CAPI: PURCHASE (UPPER_SNAKE), the Reddit hash, metadata.value, the v3 path, 1,000 a request, 7 days", () => {
  const r = buildReddit(row(), { config: { pixel_id: "a2_pix1" }, secret: "SECRET-1234" }, { appBase: "", now: NOW });
  assert(r.ok);
  if (!r.ok) return;
  assertEquals(r.request.url, "https://ads-api.reddit.com/api/v3/pixels/a2_pix1/conversion_events");
  const ev = (r.request.body as any).data.events[0];
  assertEquals(ev.type, { tracking_type: "PURCHASE" });
  assertEquals(ev.user.email, "b".repeat(64), "em_reddit, not em");
  assertEquals(ev.metadata, { conversion_id: "cs_test_1", currency: "USD", value: 50, item_count: 2 });
  const old = buildReddit(row({}, { em_reddit: undefined }), { config: { pixel_id: "a2_pix1" }, secret: "S" }, { appBase: "", now: NOW });
  assertEquals(old.ok && (old.request.body as any).data.events[0].user.email, "a".repeat(64), "a row queued before the migration sends em");
  assertEquals(Object.values(REDDIT_TRACKING_TYPE).every((t) => /^[A-Z_]+$/.test(t)), true);
  assertEquals(REDDIT_TRACKING_TYPE.PageVisit, "PAGE_VISIT");
  assertEquals(REDDIT_TRACKING_TYPE.AddToCart, "ADD_TO_CART");
  assertEquals(REDDIT_MAX_EVENTS, 1000);
  assertEquals(redditBatches(Array.from({ length: 2500 }, (_, i) => i)).map((b) => b.length), [1000, 1000, 500]);
  assertEquals(redditBatches([1, 2, 3], 5000).length, 1, "never above 1,000");
  assertEquals(MAX_AGE_MS.reddit, 7 * 86_400_000);
  const stale = buildReddit(row({ occurred_at: "2026-11-13T11:00:00Z" }), { config: { pixel_id: "a2_pix1" }, secret: "S" }, { appBase: "", now: NOW });
  assertEquals(stale.ok, false);
});

// ---- the audience builder ---------------------------------------------------

Deno.test("audience builder: consent-filtered, hashed, deduped (a later row fills the phone); nothing raw", async () => {
  const b = await buildAudience([
    { email: "A@x.com", ad_consent: "granted" },
    { email: " a@x.com", phone: "2125550100", ad_consent: "granted" },
    { email: "b@x.com", ad_consent: "denied" },
    { email: "c@x.com" },
    { phone: "+44 20 7946 0958", ad_consent: "granted" },
    { email: "nope", ad_consent: "granted" },
  ]);
  assertEquals(b.counts, { rows: 6, noConsent: 2, noIdentifier: 1, duplicates: 1, members: 2, withEmail: 1, withPhone: 2 });
  assertEquals(b.members[0].em, await sha256Hex("a@x.com"));
  assertEquals(b.members[0].ph, await sha256Hex("+12125550100"));
  assert(!JSON.stringify(b).includes("@") && !JSON.stringify(b).includes("2125550100"), "nothing raw");
  assertEquals(metaRows(b.members)[0], [b.members[0].em!, b.members[0].ph_digits!]);
  assertEquals(metaRows(b.members)[1][0], "", "Meta: a missing value is empty");
  assertEquals(googleMembers(b.members)[0].userData.userIdentifiers, [{ emailAddress: b.members[0].em_google }, { phoneNumber: b.members[0].ph }]);
  assertEquals(redditRows(b.members), [[b.members[0].em_reddit!]], "Reddit: email only, Reddit's hash");
});

// ---- audience sync per platform ---------------------------------------------

Deno.test("Meta Custom Audiences: create + users in 10,000-row batches, schema EMAIL/PHONE; the audit holds no hash; no fetch", async () => {
  const { f, calls } = stubFetch();
  const { ctx, audit } = ctxFor(metaAdsHttp(cred("ads_meta_api", { ad_account_id: "123" })), cred("ads_meta_api", { ad_account_id: "123" }), f, { env: ON });
  const members = fakeMembers(10_001);
  const r = await metaAdsAdapter.syncAudience!(ctx, { id: "org-1:all", members }) as any;
  assertEquals(calls.length, 0, "a dry run never calls fetch");
  assertEquals(r.steps.map((s: any) => [s.method, s.path]), [
    ["POST", "/v25.0/act_123/customaudiences"], ["POST", "/v25.0/planned_audience/users"], ["POST", "/v25.0/planned_audience/users"],
  ]);
  assertEquals(audit.steps[0].request?.body, { name: "Exos fans and buyers", subtype: "CUSTOM",
    description: "Exos buyers and fans who agreed to advertising. Built by Exos.", customer_file_source: "USER_PROVIDED_ONLY" });
  const b1 = audit.steps[1].request?.body as any;
  assertEquals(b1.payload.schema, ["EMAIL", "PHONE"]);
  assertStringIncludes(b1.payload.data, "10000 hashed rows");
  assertEquals(b1.session, { session_id: b1.session.session_id, batch_seq: 1, last_batch_flag: false, estimated_num_total: 10_001 });
  assertEquals((audit.steps[2].request?.body as any).session.last_batch_flag, true);
  assert(!JSON.stringify(audit.steps).includes(members[5].em!), "no hash in the audit");
  assert(!JSON.stringify(audit.steps).includes("TOKEN-secret-1234"), "the token is redacted");
  assertEquals(audit.steps[0].request?.headers?.Authorization, "[redacted]");
});

Deno.test("Reddit CUSTOMER_LIST: 2,500-row PATCH chunks of EMAIL_SHA256; the 1,000 / 36 h / 1 year warnings; no fetch", async () => {
  const { f, calls } = stubFetch();
  const c = cred("ads_reddit_api", { ad_account_id: "a2_acct1" });
  const { ctx, audit } = ctxFor(redditAdsHttp(c), c, f, { env: ON });
  const r = await redditAdsAdapter.syncAudience!(ctx, { id: "org-1:all", members: fakeMembers(6000) }) as any;
  assertEquals(calls.length, 0);
  assertEquals(r.steps.map((s: any) => `${s.method} ${s.path}`), [
    "POST /api/v3/ad_accounts/a2_acct1/custom_audiences",
    "PATCH /api/v3/custom_audiences/planned_audience/users",
    "PATCH /api/v3/custom_audiences/planned_audience/users",
    "PATCH /api/v3/custom_audiences/planned_audience/users",
  ]);
  assertEquals(audit.steps[0].request?.body, { data: { name: "Exos fans and buyers", type: "CUSTOMER_LIST" } });
  const sizes = audit.steps.slice(1).map((s) => (s.request?.body as any).data.user_data);
  assertEquals(sizes, ["[2500 hashed rows (EMAIL_SHA256), not recorded]", "[2500 hashed rows (EMAIL_SHA256), not recorded]", "[1000 hashed rows (EMAIL_SHA256), not recorded]"]);
  assertEquals((audit.steps[1].request?.body as any).data.column_order, ["EMAIL_SHA256"]);
  for (const w of REDDIT_AUDIENCE_WARNINGS) assert(r.warnings.includes(w), w);
  const small = await redditAdsAdapter.syncAudience!(ctx, { id: "x", members: fakeMembers(40) }) as any;
  assert(small.warnings.some((w: string) => w.includes("Only 40 people") && w.includes("1,000")), "under 1,000: said so");
});

Deno.test("Reddit audience: the 3,000-per-15-minutes cap defers the rest (live usage), nothing sent", async () => {
  const { f, calls } = stubFetch();
  const c = cred("ads_reddit_api", { ad_account_id: "a2_acct1" });
  const counter = memoryUsageCounter(() => NOW.getTime());
  await counter.reserve({ platform: "reddit", scopeKey: "a2_acct1", metric: "audience_uploads", n: 3000, windowSeconds: 900, threshold: null, live: true });
  const { ctx } = ctxFor(redditAdsHttp(c), c, f, { env: ON, counter });
  const r = await redditAdsAdapter.syncAudience!(ctx, { id: "x", members: fakeMembers(3000), externalId: "aud_1" }) as any;
  assertEquals(calls.length, 0);
  assertEquals(r.steps.map((s: any) => s.error), ["LIMIT_CAPPED"]);
  assertEquals(r.deferred, 3000);
  assertStringIncludes(r.stopped, "15 minutes");
});

Deno.test("Google Customer Match: Data Manager audienceMembers:ingest (not the Ads API), 10,000 a request, consent + HEX; no fetch", async () => {
  const { f, calls } = stubFetch();
  const c = cred("ads_google_ads", { customer_id: "1234567890", login_customer_id: "9999999999" }, "refresh-token-SECRET");
  const { ctx, audit } = ctxFor(googleCustomerMatchHttp(c), c, f, { env: ON });
  const r = await googleCustomerMatchAdapter.syncAudience!(ctx, { id: "x", members: fakeMembers(10_500), externalId: "555" }) as any;
  assertEquals(calls.length, 0);
  assertEquals(r.steps.map((s: any) => `${s.method} ${s.path}`), ["POST /v1/audienceMembers:ingest", "POST /v1/audienceMembers:ingest"]);
  const b = audit.steps[0].request?.body as any;
  assertEquals(b.destinations, [{ operatingAccount: { accountType: "GOOGLE_ADS", accountId: "1234567890" },
    loginAccount: { accountType: "GOOGLE_ADS", accountId: "9999999999" }, productDestinationId: "555" }]);
  assertEquals([b.encoding, b.consent.adUserData, b.consent.adPersonalization], ["HEX", "CONSENT_GRANTED", "CONSENT_GRANTED"]);
  assertStringIncludes(b.audienceMembers, "10000 hashed rows");
  assert(!JSON.stringify(audit.steps).includes("refresh-token-SECRET"));
  assert(!JSON.stringify(googleCustomerMatchAdapter.writes).includes("googleads"), "never the Google Ads API");
});

// ---- Boost this event --------------------------------------------------------

Deno.test("planner: one plan (copy, link with UTM, PAUSED-able dates, $0 price and budget by default, geo, communities)", () => {
  assertEquals(PLAN.priceCents, 0, "free at first");
  assertEquals(boostConfig((k) => (k === "EXOS_ADS_BOOST_PRICE_CENTS" ? "1500" : undefined)).priceCents, 1500);
  assertEquals(PLAN.dailyBudgetCents, 0);
  assert(PLAN.warnings.some((w) => w.includes("$0")));
  assertEquals(PLAN.cta, "BUY_TICKETS");
  assertStringIncludes(PLAN.url!, "https://exos.example/e/boost-night?utm_source=exos&utm_medium=paid");
  assertStringIncludes(PLAN.body, "Tickets from $25.00");
  assertEquals(PLAN.geo.kind, "radius");
  assertEquals(PLAN.communities.includes("Brooklyn"), true);
  assertEquals(PLAN.blocked, null);
  const past = planCampaign({ ...EVENT, starts_at: "2026-11-01T00:00:00Z" }, boostConfig(OFF), { appBase: "", now: NOW });
  assertEquals(past.blocked, "The event has already started.");
  const noPin = adGeo({ venue_address: { city: "Queens" } });
  assertEquals(noPin.kind === "zips" && noPin.zips.length, cityZips(AD_CITIES[0]).zips.length);
  assertEquals(adGeo({ venue_address: { city: "Boston" } }).kind, "none");
});

Deno.test("Meta campaign: OUTCOME_SALES, campaign / ad set / ad PAUSED, radius geo, BUY_TICKETS, the pixel; no fetch", async () => {
  const { f, calls } = stubFetch();
  const c = cred("ads_meta_api", { ad_account_id: "123", page_id: "456", pixel_id: "123456789012345" });
  const { ctx, audit } = ctxFor(metaAdsHttp(c), c, f, { env: ON });
  const r = await metaAdsAdapter.createCampaign!(ctx, { id: EVENT.id }, PLAN as any) as any;
  assertEquals(calls.length, 0);
  assertEquals(r.steps.map((s: any) => s.path), ["/v25.0/act_123/campaigns", "/v25.0/act_123/adsets", "/v25.0/act_123/adcreatives", "/v25.0/act_123/ads"]);
  const [camp, adset, creative, ad] = audit.steps.map((s) => s.request?.body as any);
  assertEquals([camp.objective, camp.status], ["OUTCOME_SALES", "PAUSED"]);
  assertEquals([adset.status, adset.campaign_id, adset.daily_budget], ["PAUSED", "planned_campaign", 0]);
  assertEquals(adset.promoted_object, { pixel_id: "123456789012345", custom_event_type: "PURCHASE" });
  assertEquals(adset.targeting.geo_locations, { custom_locations: [{ latitude: 40.7181, longitude: -73.9571, radius: 10, distance_unit: "mile" }] });
  assertEquals(creative.object_story_spec.page_id, "456");
  assertEquals(creative.object_story_spec.link_data.call_to_action.type, "BUY_TICKETS");
  assertStringIncludes(creative.object_story_spec.link_data.link, "utm_source=meta");
  assertEquals(creative.object_story_spec.link_data.picture, "https://img.example/boost.jpg");
  assertEquals([ad.status, ad.adset_id, ad.creative.creative_id], ["PAUSED", "planned_adset", "planned_creative"]);
  // No pin: the city's ZIPs.
  const zipPlan = planCampaign({ ...EVENT, lat: null, lng: null }, boostConfig(OFF), { appBase: "https://exos.example", now: NOW });
  const z = memoryAuditSink();
  const ctx2 = { ...ctx, http: createGatedHttp({ ...metaAdsHttp(c), fetch: f, env: ON, orgWritesEnabled: false, audit: z }) };
  await metaAdsAdapter.createCampaign!(ctx2, { id: EVENT.id }, zipPlan as any);
  assertEquals((z.steps[1].request?.body as any).targeting.geo_locations.zips[0], { key: "US:10001" });
});

Deno.test("Reddit campaign: CONVERSIONS PAUSED -> ad group (ZIP geolocations, communities, conversion_pixel_id, PURCHASE) -> structured post (BUY_TICKETS) -> ad; no fetch", async () => {
  const { f, calls } = stubFetch();
  const c = cred("ads_reddit_api", { ad_account_id: "a2_acct1", profile_id: "t2_prof1", pixel_id: "a2_pix1" });
  const { ctx, audit } = ctxFor(redditAdsHttp(c), c, f, { env: ON });
  const r = await redditAdsAdapter.createCampaign!(ctx, { id: EVENT.id }, PLAN as any) as any;
  assertEquals(calls.length, 0);
  assertEquals(r.steps.map((s: any) => s.path), [
    "/api/v3/ad_accounts/a2_acct1/campaigns", "/api/v3/ad_accounts/a2_acct1/ad_groups",
    "/api/v3/profiles/t2_prof1/structured_posts/jobs", "/api/v3/ad_accounts/a2_acct1/ads",
  ]);
  const [camp, group, post, ad] = audit.steps.map((s) => (s.request?.body as any).data);
  assertEquals([camp.objective, camp.configured_status], ["CONVERSIONS", "PAUSED"]);
  assertEquals([group.configured_status, group.optimization_goal, group.conversion_pixel_id, group.campaign_id], ["PAUSED", "PURCHASE", "a2_pix1", "planned_campaign"]);
  assertEquals(group.targeting.geolocations[0], "US-10001");
  assertEquals(group.targeting.geolocations.length, cityZips(AD_CITIES[0]).zips.length, "a ZIP list, no radius");
  assertEquals(group.targeting.boroughs, ["Manhattan", "Brooklyn", "Queens", "The Bronx", "Staten Island"]);
  assertEquals(group.targeting.communities, AD_CITIES[0].communities);
  assertEquals([post.headline, post.content[0].call_to_action, post.content[0].media_url], ["Boost Night", "BUY_TICKETS", "https://img.example/boost.jpg"]);
  assertStringIncludes(post.content[0].destination_url, "utm_source=reddit");
  assertEquals([ad.configured_status, ad.ad_group_id, ad.post_id], ["PAUSED", "planned_ad_group", "planned_post"]);
  assert(!r.steps.some((s: any) => s.path.endsWith("/posts")), "not the deprecated posts endpoint");
});

Deno.test("Reddit rate limits in the table, and a write over 200 a minute is capped before anything is planned", async () => {
  const ids = rulesFor("reddit").map((r) => [r.id, r.threshold, r.window, r.metric]);
  assertEquals(ids, [
    ["reddit_writes", 200, "minute", "writes"], ["reddit_reads", 400, "minute", "reads"],
    ["reddit_targeting", 100, "minute", "targeting"], ["reddit_audience_uploads", 3000, "quarter_hour", "audience_uploads"],
  ]);
  assertEquals(evaluateLimits("reddit", {}, { writes: { live: 199, planned: 0 } }, { metric: "writes", n: 1 }).allowed, true);
  assertEquals(evaluateLimits("reddit", {}, { writes: { live: 200, planned: 0 } }, { metric: "writes", n: 1 }).allowed, false);
  const counter = memoryUsageCounter(() => NOW.getTime());
  await counter.reserve({ platform: "reddit", scopeKey: "a2_acct1", metric: "writes", n: 200, windowSeconds: 60, threshold: null, live: true });
  const { f, calls } = stubFetch();
  const c = cred("ads_reddit_api", { ad_account_id: "a2_acct1", profile_id: "t2_prof1", pixel_id: "a2_pix1" });
  const { ctx } = ctxFor(redditAdsHttp(c), c, f, { env: ON, counter });
  const r = await redditAdsAdapter.createCampaign!(ctx, { id: EVENT.id }, PLAN as any) as any;
  assertEquals(calls.length, 0);
  assertEquals(r.steps.map((s: any) => s.error), ["LIMIT_CAPPED"]);
  assertEquals(r.stopped, "LIMIT_CAPPED");
  // A minute later the window has rolled over.
  const later = memoryUsageCounter(() => NOW.getTime() + 61_000);
  assertEquals((await later.read({ platform: "reddit", scopeKey: "a2_acct1", metric: "writes", windowSeconds: 60 })).live, 0);
});

// ---- the allowlists -------------------------------------------------------------

Deno.test("allowlists: every planned write matches its adapter's list, every rule is used, anything else is refused", async () => {
  const cases: Array<[ChannelAdapter, HttpOpts, OrgCredential, () => Promise<unknown>]> = [];
  const meta = cred("ads_meta_api", { ad_account_id: "123", page_id: "456", pixel_id: "123456789012345" });
  const reddit = cred("ads_reddit_api", { ad_account_id: "a2_acct1", profile_id: "t2_prof1", pixel_id: "a2_pix1" });
  const google = cred("ads_google_ads", { customer_id: "1234567890" });
  const used = new Map<WriteRule, number>();
  const all = [...META_ADS_WRITES, ...REDDIT_ADS_WRITES, ...GOOGLE_CUSTOMER_MATCH_WRITES];
  for (const [a, o, c, run] of [
    [metaAdsAdapter, metaAdsHttp(meta), meta, (ctx: ChannelCtx) => Promise.all([
      metaAdsAdapter.syncAudience!(ctx, { id: "x", members: fakeMembers(3) }), metaAdsAdapter.createCampaign!(ctx, { id: EVENT.id }, PLAN as any)])],
    [redditAdsAdapter, redditAdsHttp(reddit), reddit, (ctx: ChannelCtx) => Promise.all([
      redditAdsAdapter.syncAudience!(ctx, { id: "x", members: fakeMembers(3) }), redditAdsAdapter.createCampaign!(ctx, { id: EVENT.id }, PLAN as any)])],
    [googleCustomerMatchAdapter, googleCustomerMatchHttp(google), google, (ctx: ChannelCtx) => googleCustomerMatchAdapter.syncAudience!(ctx, { id: "x", members: fakeMembers(3) })],
  ] as Array<[ChannelAdapter, HttpOpts, OrgCredential, (ctx: ChannelCtx) => Promise<unknown>]>) {
    const { f } = stubFetch();
    const { ctx, audit } = ctxFor(o, c, f, { env: ON });
    await run(ctx);
    for (const s of audit.steps) {
      const hits = (a.writes ?? []).filter((w) => w.method === s.method && w.path.test(s.path));
      assertEquals(hits.length, 1, `${a.id}: ${s.method} ${s.path} matches one rule`);
      used.set(hits[0], (used.get(hits[0]) ?? 0) + 1);
    }
    // Off the list: refused (thrown), whatever the switches, and never sent.
    const live = ctxFor(o, c, f, { env: ON, org: true });
    await assertRejects(() => live.ctx.http.request("DELETE", s0(o)), GatedHttpRefused);
    await assertRejects(() => live.ctx.http.request("POST", "/v1/anything_else"), GatedHttpRefused);
    void cases;
  }
  for (const w of all) assert(used.has(w), `rule ${w.method} ${w.path} is used by a plan`);
  assertEquals(X_ADS_WRITES.length, 1);
  assert(X_ADS_WRITES[0].path.test("/12/measurement/conversions/o8z6j") && !X_ADS_WRITES[0].path.test("/12/accounts/abc/campaigns"));
  for (const a of [metaAdsAdapter, redditAdsAdapter, googleCustomerMatchAdapter, xAdsAdapter]) {
    assert((a.writes ?? []).every((w) => w.method !== "DELETE" && !w.idempotent), `${a.id}: no delete, nothing retried`);
  }
});
const s0 = (o: HttpOpts) => (o.channel === "meta_ads" ? "/v25.0/act_123/campaigns" : o.channel === "reddit_ads" ? "/api/v3/ad_accounts/a2_acct1/campaigns" : "/v1/audienceMembers:ingest");

Deno.test("registry: the four ad adapters are core, shaped right, and only the X sender sends conversions", () => {
  ensureRegistry();
  for (const id of ["meta_ads", "reddit_ads", "google_customer_match", "x_ads"]) {
    const a = ADAPTERS.find((x) => x.id === id)!;
    assertEquals([a.status, adapterProblems(a)], ["core", []], id);
  }
  assertEquals(metaAdsAdapter.caps.createCampaign && redditAdsAdapter.caps.createCampaign && !googleCustomerMatchAdapter.caps.createCampaign, true);
});

// ---- dry run, pinned -----------------------------------------------------------

Deno.test("exos-ads passes: pinned dry run (even with the org's switch and every flag on), fetch never called, steps recorded", async () => {
  assertEquals(ADS_WRITES_PINNED_OFF, true, "the build gate");
  const { f, calls } = stubFetch();
  const rpcCalls: string[] = [];
  const store: Record<string, unknown> = {
    ads_meta_api: { provider: "ads_meta_api", status: "connected", config: { ad_account_id: "123", page_id: "456" }, secret: "meta-SECRET-tok", writes_enabled: true, source: "store" },
    ads_meta: { provider: "ads_meta", status: "connected", config: { pixel_id: "123456789012345" }, secret: "capi", writes_enabled: true, source: "store" },
    ads_reddit_api: null, ads_reddit: null,
  };
  const rpc = async (fn: string, args: Record<string, unknown>) => {
    rpcCalls.push(fn);
    if (fn === "exos_integration_secret") return { data: store[String(args.p_provider)] ?? null, error: null };
    if (fn === "exos_ads_audience_source") {
      return { data: { count: 2, rows: [{ email: "a@x.com", ad_consent: "granted" }, { email: "b@x.com", ad_consent: "granted" }] }, error: null };
    }
    if (fn === "exos_channel_audit_record") return { data: null, error: null };
    if (fn.startsWith("exos_channel_usage")) return { data: { ok: true, live: 0, planned: 0 }, error: null };
    return { data: null, error: { message: `unexpected ${fn}` } };
  };
  const deps = { orgId: "org-1", rpc, env: ON, fetch: f, appBase: "https://exos.example", now: () => NOW };
  const a = await planAudienceSync(deps, { channel: "meta_ads", actor: "u1" });
  assertEquals(a.audience.members, 2);
  assertEquals(a.result.planned, true);
  assertEquals(a.steps.every((s) => !s.live), true);
  const boost = await planBoost(deps, { event: EVENT, channels: ["meta_ads", "reddit_ads"], dailyBudgetCents: 2000 });
  assertEquals(calls.length, 0, "nothing reaches a platform");
  assertEquals(boost.plan.dailyBudgetCents, 2000);
  const meta = boost.channels.find((c) => c.channel === "meta_ads")!;
  assertEquals((meta.steps[1].body as any).promoted_object.pixel_id, "123456789012345", "the conversions pixel fills in");
  const reddit = boost.channels.find((c) => c.channel === "reddit_ads")!;
  assertEquals(reddit.result.connected, false);
  assert(reddit.result.warnings.some((w) => w.includes("isn't connected")));
  assertEquals((reddit.steps[0].path), "/api/v3/ad_accounts/planned_account/campaigns", "a not-connected plan uses a placeholder");
  assert(rpcCalls.includes("exos_channel_audit_record"), "the steps go to What we'd send");
  assert(!JSON.stringify(boost).includes("meta-SECRET-tok") && !JSON.stringify(a).includes("meta-SECRET-tok"));
});

Deno.test("the live path (stub fetch, both switches on) uses the returned ids; a placeholder is never sent live", async () => {
  let n = 0;
  const { f, calls } = stubFetch(() => ({ id: String(1000 + ++n) }));
  const c = cred("ads_meta_api", { ad_account_id: "123", page_id: "456", pixel_id: "123456789012345" });
  const { ctx } = ctxFor(metaAdsHttp(c), c, f, { env: ON, org: true });
  const r = await metaAdsAdapter.createCampaign!(ctx, { id: EVENT.id }, PLAN as any) as any;
  assertEquals(calls.length, 4);
  assertEquals(calls[1].body.campaign_id, "1001");
  assertEquals(calls[3].body, { name: calls[3].body.name, adset_id: "1002", creative: { creative_id: "1003" }, status: "PAUSED" });
  assertEquals(calls[0].headers.get("authorization"), "Bearer TOKEN-secret-1234");
  assertEquals(r.planned, false);
  const nc = cred("ads_meta_api", {}, "tok-1234");
  const bad = ctxFor(metaAdsHttp(nc), nc, f, { env: ON, org: true });
  await assertRejects(() => metaAdsAdapter.createCampaign!(bad.ctx, { id: EVENT.id }, PLAN as any), GatedHttpRefused, "placeholder");
  assertEquals(calls.length, 4, "the placeholder plan sent nothing");
});

// ---- insights -----------------------------------------------------------------

Deno.test("readInsights: reads nothing until a live credential exists", async () => {
  const { f, calls } = stubFetch(() => ({ data: [{ impressions: "120", clicks: "7", spend: "3.50" }] }));
  const none = cred("ads_meta_api", { ad_account_id: "123" }, null);
  assertEquals(await metaAdsAdapter.readInsights!(ctxFor(metaAdsHttp(none), none, f).ctx, "1001"), {});
  const rnone = cred("ads_reddit_api", { ad_account_id: "a2_acct1" }, null);
  assertEquals(await redditAdsAdapter.readInsights!(ctxFor(redditAdsHttp(rnone), rnone, f).ctx, "c1"), {});
  assertEquals(calls.length, 0);
  const live = cred("ads_meta_api", { ad_account_id: "123" });
  assertEquals(await metaAdsAdapter.readInsights!(ctxFor(metaAdsHttp(live), live, f).ctx, "1001"), { impressions: 120, clicks: 7, spend: 3.5 });
  assertEquals(calls.length, 1, "one stubbed GET, no network");
  // A counted read: over 400 a minute is capped before it goes out.
  const counter = memoryUsageCounter(() => NOW.getTime());
  await counter.reserve({ platform: "reddit", scopeKey: "a2_acct1", metric: "reads", n: 400, windowSeconds: 60, threshold: null, live: true });
  const rc = cred("ads_reddit_api", { ad_account_id: "a2_acct1" });
  assertEquals(await redditAdsAdapter.readInsights!(ctxFor(redditAdsHttp(rc), rc, f, { counter }).ctx, "c1"), {});
  assertEquals(calls.length, 1, "the capped read was not sent");
});

// ---- X conversions --------------------------------------------------------------

Deno.test("OAuth 1.0a: the published HMAC-SHA1 test vector", async () => {
  const h = await oauth1Header("POST", "https://api.twitter.com/1.1/statuses/update.json?include_entities=true", {
    consumerKey: "xvz1evFS4wEEPTGEFPHBog", consumerSecret: "kAcSOqF21Fu85e7zjz7ZN2U4ZRhfV3WpwPAoE3Z7kBw",
    token: "370773112-GmHxMAgYyLbNEtIKZeRNFsMKPR9EyMZeS9weJAEb", tokenSecret: "LswwdoUaIvS8ltyTt5jkRh4J50vUPVVHtR2YPi5kE",
  }, { nonce: "kYjzVBB8Y0ZFabxSWbWovY3uYSQ2pTgmZeNu2VS4cg", timestamp: 1318622958, formBody: [["status", "Hello Ladies + Gentlemen, a signed OAuth request!"]] });
  assertStringIncludes(h, 'oauth_signature="hCtSmYh%2BiHYCEqBWrE7C7hYmtUk%3D"');
  assertEquals(parseXTokenSecret('{"token":"t","token_secret":"s"}'), { token: "t", tokenSecret: "s" });
  assertEquals(parseXTokenSecret("plain"), null);
});

const XCRED = cred("ads_x", { pixel_id: "o8z6j", event_id: "tw-o8z6j-o8z6k" }, '{"token":"x-tok-1234","token_secret":"x-tsec-5678"}', true);
const XROW = { ...row({ platform: "x" }), org_id: "org-1" };

Deno.test("X conversions: the request shape (twclid + hashed_email, conversion_id = the session id); planned only without the app keys", () => {
  const r = buildX(XROW, { config: { pixel_id: "o8z6j", event_id: "tw-o8z6j-o8z6k" }, secret: "s" }, { appBase: "", now: NOW });
  assert(r.ok);
  if (!r.ok) return;
  assertEquals(r.request.url, "https://ads-api.x.com/12/measurement/conversions/o8z6j");
  assertEquals((r.request.body as any).conversions[0], {
    conversion_time: "2026-11-21T11:00:00.000Z", event_id: "tw-o8z6j-o8z6k", identifiers: [{ twclid: "tw-1" }, { hashed_email: "a".repeat(64) }],
    number_items: 2, price_currency: "USD", value: 50, conversion_id: "cs_test_1", description: "Show",
  });
  assertEquals(buildX(XROW, { config: { pixel_id: "o8z6j", event_id: "tw-other-o8z6k" }, secret: "s" }, { appBase: "", now: NOW }).ok, false, "the event belongs to the pixel");
  assertEquals(buildConversionRequest(XROW, { config: { pixel_id: "o8z6j", event_id: "tw-o8z6j-o8z6k" }, secret: "s" }, { appBase: "", now: NOW }).ok, true, "the host is allowed");
  assertEquals([plannedOnly("x"), plannedOnly("x", { xConfigured: true })], [true, false]);
});

Deno.test("X drain step: dry run unless EXOS_CONVERSIONS_LIVE, the app keys AND the x_ads GatedHttp switches; signed only then", async () => {
  const ctx = { appBase: "", now: NOW };
  const app = { consumerKey: "ck-1234", consumerSecret: "cs-SECRET-9999" };
  const { f, calls } = stubFetch(() => ({ data: { conversions_processed: 1 } }));
  const d = (over: Partial<Parameters<typeof drainXRow>[2]>) => ({ live: false, app: null, env: OFF, fetch: f, ctx, ...over });
  const a = await drainXRow(XROW, XCRED, d({}));
  assertEquals([a.result, "error" in a && a.error], ["skipped", "dry-run: EXOS_CONVERSIONS_LIVE is not true"]);
  assert(a.result === "skipped" && a.planned && !JSON.stringify(a.planned).includes("x-tsec-5678"), "planned, no token");
  assertEquals((await drainXRow(XROW, XCRED, d({ live: true }))).result, "skipped", "no app keys: planned only");
  const b = await drainXRow(XROW, XCRED, d({ live: true, app }));
  assertEquals([b.result, "error" in b && b.error.startsWith("dry-run: the x_ads writes are off")], ["skipped", true]);
  assertEquals((await drainXRow(XROW, { ...XCRED, writesEnabled: false }, d({ live: true, app, env: ON }))).result, "skipped", "the org's switch off");
  assertEquals(calls.length, 0, "nothing sent so far");
  const audit = memoryAuditSink();
  const c = await drainXRow(XROW, XCRED, d({ live: true, app, env: ON, audit }));
  assertEquals(c.result, "sent");
  assertEquals(calls.length, 1);
  assertEquals(calls[0].url, "https://ads-api.x.com/12/measurement/conversions/o8z6j");
  assertStringIncludes(calls[0].headers.get("authorization")!, 'oauth_consumer_key="ck-1234"');
  assertStringIncludes(calls[0].headers.get("authorization")!, 'oauth_token="x-tok-1234"');
  assertEquals(calls[0].body.conversions[0].conversion_id, "cs_test_1");
  const rec = JSON.stringify(audit.steps);
  assert(!rec.includes("x-tok-1234") && !rec.includes("x-tsec-5678") && !rec.includes("cs-SECRET-9999"), "the audit holds no key");
  assertEquals((await drainXRow(XROW, null, d({ live: true, app, env: ON }))).result, "skipped", "not connected");
});
