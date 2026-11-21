// The social posting / listing phase (mig 20261121203000), dry run only:
// the post kit, each adapter's payload shape, the allowlists (exactly the
// write paths, Meetup's pinned GraphQL documents; anything else refused), the
// build pin, the limits (Instagram 100 a day, Meetup points and Starter 10,
// TikTok's init rate, Business Profile's 60 days), stand-in ids never sent
// live, and dry runs that never call fetch. No network: every fetch here is
// a stub, and the dry-run tests count that it was never called.
import { assert, assertEquals, assertRejects, assertStringIncludes } from "jsr:@std/assert@1";
import { adTextProblems, composePost, composePostKit, contactInfoProblems, SECRET_VENUE_LINE, SOCIAL_PLATFORMS, type SocialEventInput } from "./postKit.ts";
import { planSocial, SOCIAL_WRITES_PINNED_OFF, type RunDeps } from "./run.ts";
import { appConfigured, familyOf, VENDOR_APPS } from "./apps.ts";
import { bodyAllowed, createGatedHttp, GatedHttpRefused, type WriteRule } from "../channels/gatedHttp.ts";
import { memoryAuditSink } from "../channels/audit.ts";
import { memoryUsageCounter, type UsageCounter } from "../channels/usage.ts";
import { evaluateLimits, rulesFor } from "../channels/limits.ts";
import { adapterProblems, type ChannelAdapter, type ChannelCtx, type OrgCredential } from "../channels/adapter.ts";
import { ADAPTERS, ensureRegistry } from "../channels/registry.ts";
import { instagramAdapter, instagramHttp, INSTAGRAM_WRITES } from "../channels/adapters/instagram.ts";
import { TIKTOK_SELF_ONLY_WARNING, tiktokHttp, tiktokPrivacy, tiktokPublish, TIKTOK_WRITES } from "../channels/adapters/tiktok.ts";
import {
  MEETUP_CREATE_EVENT, MEETUP_EDIT_EVENT, meetupAdapter, meetupBodyAllowed, meetupDuration, meetupHttp, meetupLocal, MEETUP_WRITES,
} from "../channels/adapters/meetup.ts";
import { linkedinAdapter, linkedinHttp, LINKEDIN_WRITES } from "../channels/adapters/linkedin.ts";
import { gbpDateTime, googleBusinessAdapter, googleBusinessHttp, GOOGLE_BUSINESS_WRITES, profileAgeDays } from "../channels/adapters/googleBusiness.ts";

const NOW = new Date("2026-11-21T12:00:00Z");
const APP = "https://exos.example";
const SECRET = "tok-SOCIAL-secret-123456";

const EVENT: SocialEventInput & { id: string; capacity: number } = {
  id: "5c100000-0000-0000-0000-0000000000e1",
  slug: "post-night",
  name: "Post Night",
  status: "published",
  starts_at: "2026-12-04T02:00:00Z", // Thu Dec 3, 9:00 PM in New York
  ends_at: "2026-12-04T05:30:00Z",
  timezone: "America/New_York",
  currency: "USD",
  venue_name: "Social Hall",
  venue_address: { street: "1 Main St", city: "Brooklyn", region: "NY", postal: "11211", country: "US" },
  image_url: "https://img.example/post.jpg",
  description: "Two rooms of music. More at https://example.com/info and say hi at hello@socialhall.com.",
  location_open: true,
  tiers: [{ price: 25, capacity: 100, sold: 0 }],
  capacity: 120,
};

interface Seen { calls: number }
function stubFetch(): { f: typeof fetch; seen: Seen } {
  const seen = { calls: 0 };
  const f = (async () => {
    seen.calls++;
    return new Response(JSON.stringify({ id: "999" }), { status: 200 });
  }) as unknown as typeof fetch;
  return { f, seen };
}

const cred = (provider: string, config: Record<string, unknown>, secret: string | null = SECRET, writesEnabled = true): OrgCredential =>
  ({ provider, status: "connected", config, secret, writesEnabled, accountName: null, source: "store" });

type HttpOpts = ReturnType<typeof instagramHttp>;
function ctxFor(o: { channel: string; base: string; writes: WriteRule[]; headers?: Record<string, string>; secrets?: readonly (string | null | undefined)[];
  standIn?: (m: any, p: string, b: unknown) => unknown; limits?: { platform?: string; scopeKey?: string } } | HttpOpts,
  creds: OrgCredential, opt: { live?: boolean; counter?: UsageCounter; facts?: Record<string, unknown>; fetch?: typeof fetch } = {}) {
  const audit = memoryAuditSink();
  const { f, seen } = stubFetch();
  const http = createGatedHttp({
    channel: o.channel, base: o.base, writes: o.writes, headers: o.headers, secrets: o.secrets, standIn: o.standIn,
    fetch: opt.fetch ?? f, env: () => (opt.live ? "on" : undefined), orgWritesEnabled: opt.live === true, audit,
    limits: { ...(o.limits ?? {}), counter: opt.counter ?? memoryUsageCounter(() => NOW.getTime()), facts: opt.facts ?? {} },
    now: () => NOW,
  });
  const ctx: ChannelCtx = { orgId: "org-1", creds, http, audit };
  return { ctx, audit, seen };
}

const post = (p: Parameters<typeof composePost>[1], ev = EVENT) => composePost(ev, p, { appBase: APP, now: NOW });

// ---- the post kit ------------------------------------------------------------

Deno.test("post kit: one composer, every platform, from the discovery strings", () => {
  const kit = composePostKit(EVENT, { appBase: APP, now: NOW });
  assertEquals(kit.map((k) => k.platform), [...SOCIAL_PLATFORMS]);
  for (const k of kit) {
    assertEquals(k.imageUrl, "https://img.example/post.jpg", k.platform);
    assertEquals([k.startsAt, k.timezone], [EVENT.starts_at, "America/New_York"]);
  }
  const ig = post("instagram");
  assertEquals(ig.url, null, "no link on Instagram");
  assert(!/https?:\/\//.test(ig.text), "no link in the caption");
  assert(ig.text.endsWith("Tickets: link in bio."));
  assertStringIncludes(ig.text, "Thu, Dec 3, 2026, 9:00 PM");
  assertStringIncludes(ig.text, "Social Hall, 1 Main St, Brooklyn, NY 11211, US");
  assert(ig.warnings.some((w) => w.includes("Links in the description were left out")));
  assert(ig.text.length <= 2200);

  const tt = post("tiktok");
  assertEquals(tt.url, null);
  assert(tt.warnings.some((w) => w.includes("has a link")), "TikTok: a URL in the text is warned about");
  assert(tt.warnings.some((w) => w.includes("an email address")), "TikTok: contact details warned about");
  assert(tt.warnings.some((w) => w.includes("QR code")), "TikTok: the creative rule");
  assert(tt.title.length <= 90);

  for (const p of ["meetup", "linkedin"] as const) {
    const k = post(p);
    assertEquals(k.url, `${APP}/e/post-night?utm_source=${p}&utm_medium=listing&utm_campaign=discovery`);
    assertStringIncludes(k.text, `Get tickets: ${k.url}`);
    assertStringIncludes(k.text, "Tickets: $25.00 (all-in)");
  }
  const g = post("google_business");
  assert(g.text.length <= 1500 && !g.text.includes("\n"));
  assertEquals(g.url, `${APP}/e/post-night?utm_source=google_business&utm_medium=listing&utm_campaign=discovery`);
});

Deno.test("post kit: a secret location is never posted", () => {
  const secret = { ...EVENT, location_open: false };
  for (const k of composePostKit(secret, { appBase: APP, now: NOW })) {
    assert(!k.text.includes("1 Main St") && !k.text.includes("Social Hall"), k.platform);
    assertEquals([k.venue, k.address], ["", ""], k.platform);
    assert(k.warnings.some((w) => w.includes("secret or TBA")), k.platform);
  }
  assertStringIncludes(post("instagram", secret).text, SECRET_VENUE_LINE);
});

Deno.test("post kit: TikTok ad-text rules and contact details", () => {
  assertEquals(adTextProblems("Doors at 9"), []);
  assertEquals(adTextProblems("See https://x.co #party with @dj"), ["a link", "an @ mention", "a hashtag"]);
  assertEquals(contactInfoProblems("call 212 555 0100 or a@b.com"), ["an email address", "a phone number"]);
  const noImg = post("instagram", { ...EVENT, image_url: null });
  assert(noImg.warnings.some((w) => w.includes("need an image")));
  const png = post("instagram", { ...EVENT, image_url: "https://img.example/a.png" });
  assert(png.warnings.some((w) => w.includes("JPEG")));
  const draft = post("meetup", { ...EVENT, status: "draft" });
  assert(draft.warnings.some((w) => w.includes("isn't published")));
});

// ---- the registry and the allowlists ------------------------------------------

Deno.test("registry: the five social adapters are core, shape-checked, each with its own allowlist", () => {
  ensureRegistry();
  const ids = ["instagram", "tiktok", "meetup", "linkedin", "google_business"];
  for (const id of ids) {
    const a = ADAPTERS.find((x) => x.id === id) as ChannelAdapter;
    assert(a, id);
    assertEquals([a.status, adapterProblems(a)], ["core", []], id);
    assert((a.writes ?? []).length > 0 && a.writes!.every((w) => w.method === "POST"), `${id}: POSTs only, no DELETE / PATCH`);
  }
  assertEquals(INSTAGRAM_WRITES.length, 2);
  assertEquals(TIKTOK_WRITES.length, 3);
  assertEquals(MEETUP_WRITES.length, 1);
  assertEquals(LINKEDIN_WRITES.length, 1);
  assertEquals(GOOGLE_BUSINESS_WRITES.length, 1);
  assert(meetupAdapter.caps.createEvent && meetupAdapter.caps.list && linkedinAdapter.caps.createEvent);
  assert(instagramAdapter.caps.publishPost && googleBusinessAdapter.caps.publishPost);
});

Deno.test("allowlists: exactly the write paths; anything else is refused whatever the switches", async () => {
  const cases: Array<[ReturnType<typeof instagramHttp>, string, string]> = [
    [instagramHttp(cred("ig_publish", { ig_user_id: "1784" })) as never, "POST", "/v25.0/1784/comments"],
    [instagramHttp(cred("ig_publish", { ig_user_id: "1784" })) as never, "DELETE", "/v25.0/1784"],
    [tiktokHttp(cred("tiktok_publish", {})) as never, "POST", "/v2/video/delete/"],
    [linkedinHttp(cred("linkedin", {})) as never, "POST", "/rest/posts"],
    [linkedinHttp(cred("linkedin", {})) as never, "DELETE", "/rest/events/123"],
    [googleBusinessHttp(cred("google_business", {})) as never, "PATCH", "/v4/accounts/1/locations/2/localPosts/3"],
    [meetupHttp(cred("meetup", {})) as never, "POST", "/gql2"],
  ];
  for (const [o, m, path] of cases) {
    const { ctx, seen, audit } = ctxFor(o, cred("x", {}), { live: true });
    await assertRejects(() => ctx.http.request(m as never, path, { body: {} }), GatedHttpRefused, undefined, `${m} ${path}`);
    assertEquals(seen.calls, 0);
    assertEquals(audit.steps[0].error, "NOT_ALLOWED");
  }
});

Deno.test("Meetup: one GraphQL path, only the two pinned documents; a create only as a DRAFT", async () => {
  const create = { query: MEETUP_CREATE_EVENT, variables: { input: { groupUrlname: "g", title: "t", publishStatus: "DRAFT" } } };
  assert(meetupBodyAllowed(create));
  assert(!meetupBodyAllowed({ ...create, variables: { input: { ...create.variables.input, publishStatus: "PUBLISHED" } } }), "create must be a draft");
  assert(!meetupBodyAllowed({ ...create, variables: { input: { ...create.variables.input, hosts: ["x"] } } }), "no other keys");
  assert(meetupBodyAllowed({ query: MEETUP_EDIT_EVENT, variables: { input: { eventId: "1", publishStatus: "PUBLISHED" } } }));
  assert(!meetupBodyAllowed({ query: MEETUP_EDIT_EVENT, variables: { input: { eventId: "1", publishStatus: "CANCELLED" } } }), "no cancel");
  assert(!meetupBodyAllowed({ query: MEETUP_EDIT_EVENT, variables: { input: { eventId: "1", title: "new" } } }), "edit keys pinned");
  assert(!meetupBodyAllowed({ query: "mutation { deleteEvent(input: {eventId: \"1\"}) { success } }", variables: { input: {} } }));
  assert(!meetupBodyAllowed({ query: "query { self { id } }", variables: { input: {} } }));
  assert(!meetupBodyAllowed({ ...create, operationName: "x" }), "no extra top-level keys");
  assert(!bodyAllowed(MEETUP_WRITES, "POST", "/gql", { query: "mutation { deleteGroup }" }));
  const { ctx, seen, audit } = ctxFor(meetupHttp(cred("meetup", {})), cred("meetup", {}), { live: true });
  await assertRejects(() => ctx.http.request("POST", "/gql", { body: { query: "mutation { deleteEvent }", variables: { input: {} } } }), GatedHttpRefused);
  assertEquals([seen.calls, audit.steps[0].error], [0, "NOT_ALLOWED"]);
});

Deno.test("GatedHttp body checks: a rule without one still passes; a throwing check refuses", () => {
  const rules: WriteRule[] = [{ method: "POST", path: /^\/a$/, body: () => { throw new Error("x"); } }];
  assert(!bodyAllowed(rules, "POST", "/a", {}));
  assert(bodyAllowed([...rules, { method: "POST", path: /^\/a$/ }], "POST", "/a", {}));
  assert(!bodyAllowed(rules, "POST", "/b", {}), "no rule for the path");
});

// ---- payloads, dry run --------------------------------------------------------

Deno.test("Instagram: container then media_publish, the caption with no link, counted once; nothing sent", async () => {
  const c = cred("ig_publish", { ig_user_id: "17841400000000001" });
  const { ctx, seen, audit } = ctxFor(instagramHttp(c), c);
  const r = await instagramAdapter.publishPost!(ctx, { id: EVENT.id }, post("instagram")) as any;
  assertEquals(seen.calls, 0, "a dry run never calls fetch");
  assertEquals(r.steps.map((s: any) => `${s.method} ${s.path}`), [
    "POST /v25.0/17841400000000001/media", "POST /v25.0/17841400000000001/media_publish"]);
  assert(r.planned && r.steps.every((s: any) => s.planned));
  const [cont, pub] = audit.steps;
  assertEquals((cont.request!.body as any).image_url, "https://img.example/post.jpg");
  assert(!(cont.request!.body as any).caption.includes("http"));
  assertEquals((pub.request!.body as any).creation_id, "planned_ig_container");
  assert(!JSON.stringify(audit.steps).includes(SECRET), "the token is redacted");
  const reel = await instagramAdapter.publishPost!(ctxFor(instagramHttp(c), c).ctx, { id: EVENT.id }, { ...post("instagram"), videoUrl: "https://v.example/r.mp4" }) as any;
  assertEquals(reel.steps.length, 2);
  const linked = await instagramAdapter.publishPost!(ctx, { id: EVENT.id }, { ...post("instagram"), text: "go to https://x.co" }) as any;
  assertStringIncludes(linked.stopped, "can't carry one");
});

Deno.test("Instagram: 100 posts a day; the 101st is capped, nothing sent", async () => {
  const c = cred("ig_publish", { ig_user_id: "1784" });
  const counter = memoryUsageCounter(() => NOW.getTime());
  for (let i = 0; i < 100; i++) await counter.reserve({ platform: "instagram", scopeKey: "1784", metric: "posts", n: 1, windowSeconds: 86_400, threshold: 100, live: true });
  const { ctx, seen } = ctxFor(instagramHttp(c), c, { counter });
  const r = await instagramAdapter.publishPost!(ctx, { id: EVENT.id }, post("instagram")) as any;
  assertEquals(seen.calls, 0);
  assertEquals(r.steps[1].error, "LIMIT_CAPPED");
  assertStringIncludes(r.stopped, "100 posts a day");
  assertEquals(rulesFor("instagram")[0].threshold, 100);
});

Deno.test("TikTok: Direct Post is SELF_ONLY until the app is audited; the init counted; nothing sent", async () => {
  const c = cred("tiktok_publish", { open_id: "open-1" });
  const { ctx, seen, audit } = ctxFor(tiktokHttp(c), c);
  const r = await tiktokPublish(false)(ctx, { id: EVENT.id }, post("tiktok")) as any;
  assertEquals(seen.calls, 0);
  assert(r.warnings.includes(TIKTOK_SELF_ONLY_WARNING));
  assertEquals(r.steps.map((s: any) => s.path), ["/v2/post/publish/creator_info/query/", "/v2/post/publish/content/init/"]);
  const init = audit.steps[1].request!.body as any;
  assertEquals([init.post_info.privacy_level, init.post_mode, init.media_type, init.source_info.source],
    ["SELF_ONLY", "DIRECT_POST", "PHOTO", "PULL_FROM_URL"]);
  assertEquals(init.source_info.photo_images, ["https://img.example/post.jpg"]);
  const audited = await tiktokPublish(true)(ctxFor(tiktokHttp(c), c).ctx, { id: EVENT.id }, post("tiktok")) as any;
  assert(!audited.warnings.includes(TIKTOK_SELF_ONLY_WARNING));
  assertEquals(tiktokPrivacy(true, ["SELF_ONLY", "PUBLIC_TO_EVERYONE"]), "PUBLIC_TO_EVERYONE");
  assertEquals(tiktokPrivacy(false, ["PUBLIC_TO_EVERYONE"]), "SELF_ONLY");
  assertEquals(tiktokPrivacy(true, ["SELF_ONLY"]), "SELF_ONLY", "the dry-run stand-in offers SELF_ONLY only");
  const video = await tiktokPublish(false)(ctxFor(tiktokHttp(c), c).ctx, { id: EVENT.id }, { ...post("tiktok"), videoUrl: "https://v.example/a.mp4" }) as any;
  assertEquals(video.steps[1].path, "/v2/post/publish/video/init/");
});

Deno.test("TikTok: 6 inits a minute; the 7th is capped", async () => {
  const c = cred("tiktok_publish", { open_id: "open-1" });
  const counter = memoryUsageCounter(() => NOW.getTime());
  for (let i = 0; i < 6; i++) await counter.reserve({ platform: "tiktok", scopeKey: "open-1", metric: "inits", n: 1, windowSeconds: 60, threshold: 6, live: true });
  const r = await tiktokPublish(false)(ctxFor(tiktokHttp(c), c, { counter }).ctx, { id: EVENT.id }, post("tiktok")) as any;
  assertEquals(r.steps[1].error, "LIMIT_CAPPED");
});

Deno.test("Meetup: createEvent as a DRAFT then editEvent to PUBLISHED; Starter caps the RSVPs at 10; points counted", async () => {
  const c = cred("meetup", { group_urlname: "social-hall-nyc", plan: "starter", pro_network: "exos-pro" });
  const counter = memoryUsageCounter(() => NOW.getTime());
  const { ctx, seen, audit } = ctxFor(meetupHttp(c), c, { counter });
  const r = await meetupAdapter.upsertEvent!(ctx, { id: EVENT.id }, { post: post("meetup"), attendees: 120 }) as any;
  assertEquals(seen.calls, 0);
  assertEquals(r.steps.map((s: any) => s.op), ["event.create_draft", "event.publish"]);
  const [create, publish] = audit.steps.map((s) => s.request!.body as any);
  assertEquals(create.query, MEETUP_CREATE_EVENT);
  assertEquals([create.variables.input.publishStatus, create.variables.input.groupUrlname, create.variables.input.rsvpSettings],
    ["DRAFT", "social-hall-nyc", { rsvpLimit: 10 }]);
  assertEquals([create.variables.input.startDateTime, create.variables.input.duration], ["2026-12-03T21:00", "PT3H30M"]);
  assertEquals(publish.variables.input, { eventId: "planned_meetup_event", publishStatus: "PUBLISHED" });
  assert(r.warnings.some((w: string) => w.includes("10 attendees")));
  const used = await counter.read({ platform: "meetup", scopeKey: "social-hall-nyc", metric: "points", windowSeconds: 60 });
  assertEquals(used, { live: 0, planned: 20 }, "two mutations planned at 10 points each");
  // Pro: no cap.
  const pro = cred("meetup", { group_urlname: "g", plan: "pro", pro_network: "exos-pro" });
  const rp = await meetupAdapter.upsertEvent!(ctxFor(meetupHttp(pro), pro).ctx, { id: EVENT.id }, { post: post("meetup"), attendees: 120 }) as any;
  assert(!rp.warnings.some((w: string) => w.includes("10 attendees")));
  // The allocation on an existing event.
  const al = await meetupAdapter.planListings!(ctxFor(meetupHttp(c), c).ctx, { eventId: "312345", attendees: 40 }, null) as any;
  assertEquals(al.steps.map((s: any) => s.op), ["event.allocation"]);
  assertEquals([meetupLocal("2026-07-01T00:00:00Z", "America/New_York"), meetupDuration(null, null)], ["2026-06-30T20:00", "PT2H"]);
});

Deno.test("Meetup: 500 points a minute; past them the mutation is capped", async () => {
  const c = cred("meetup", { group_urlname: "g", plan: "pro", pro_network: "p" });
  const counter = memoryUsageCounter(() => NOW.getTime());
  await counter.reserve({ platform: "meetup", scopeKey: "g", metric: "points", n: 495, windowSeconds: 60, threshold: 500, live: true });
  const r = await meetupAdapter.upsertEvent!(ctxFor(meetupHttp(c), c, { counter }).ctx, { id: EVENT.id }, { post: post("meetup"), attendees: 50 }) as any;
  assertEquals(r.steps[0].error, "LIMIT_CAPPED");
  // The Starter attendee cap doesn't trim a points request (a budget trims only its own metric).
  const v = evaluateLimits("meetup", { plan: "starter", attendees: 40 }, { points: { live: 0, planned: 0 } }, { metric: "points", n: 20 });
  assert(v.allowed && v.maxUnits === 500, `points not trimmed to 10, got ${v.maxUnits}`);
});

Deno.test("LinkedIn: POST /rest/events for an organization page only; invites shown, none sent", async () => {
  const c = cred("linkedin", { organization_id: "5551234" });
  const { ctx, seen, audit } = ctxFor(linkedinHttp(c), c);
  const r = await linkedinAdapter.upsertEvent!(ctx, { id: EVENT.id }, { post: post("linkedin") }) as any;
  assertEquals(seen.calls, 0);
  const b = audit.steps[0].request!.body as any;
  assertEquals([b.organizer, b.eventFormat, b.startsAt, b.externalUrl],
    ["urn:li:organization:5551234", "IN_PERSON", Date.parse(EVENT.starts_at!), post("linkedin").url]);
  assertEquals(b.name, { localized: { en_US: "Post Night" } });
  assertEquals(audit.steps[0].request!.headers!["LinkedIn-Version"], "202511");
  assert(r.warnings.some((w: string) => w.includes("1,000 event invites a week") && w.includes("no invites")));
  const member = cred("linkedin", { organizer_urn: "urn:li:person:abc" });
  const m = await linkedinAdapter.upsertEvent!(ctxFor(linkedinHttp(member), member).ctx, { id: EVENT.id }, { post: post("linkedin") }) as any;
  assertStringIncludes(m.stopped, "organization page");
  assertEquals(m.steps.length, 0);
});

Deno.test("Google Business Profile: an EVENT localPost for a venue org with a 60-day-old profile", async () => {
  const c = cred("google_business", { account_id: "1122334455", location_id: "9988776655", verified_at: "2026-08-01" });
  const ok = ctxFor(googleBusinessHttp(c), c, { facts: { profileAgeDays: profileAgeDays("2026-08-01", NOW) } });
  const r = await googleBusinessAdapter.publishPost!(ok.ctx, { id: EVENT.id, venue_org: true }, post("google_business")) as any;
  assertEquals(ok.seen.calls, 0);
  assertEquals(r.steps.map((s: any) => s.path), ["/v4/accounts/1122334455/locations/9988776655/localPosts"]);
  const b = ok.audit.steps[0].request!.body as any;
  assertEquals([b.topicType, b.callToAction.actionType, b.media[0].mediaFormat], ["EVENT", "BOOK", "PHOTO"]);
  assertEquals(b.event.schedule.startDate, { year: 2026, month: 12, day: 3 });
  assertEquals(b.event.schedule.startTime, { hours: 21, minutes: 0 });
  assertEquals(b.event.schedule.endTime, { hours: 0, minutes: 30 });
  for (const age of [30, null]) {
    const young = ctxFor(googleBusinessHttp(c), c, { facts: { profileAgeDays: age } });
    const y = await googleBusinessAdapter.publishPost!(young.ctx, { id: EVENT.id, venue_org: true }, post("google_business")) as any;
    assertEquals(y.steps[0].error, "LIMIT_BLOCKED", `age ${age}`);
    assertStringIncludes(y.stopped, "60 days");
  }
  const notVenue = await googleBusinessAdapter.publishPost!(ok.ctx, { id: EVENT.id, venue_org: false }, post("google_business")) as any;
  assertStringIncludes(notVenue.stopped, "run their own venue");
  assertEquals([profileAgeDays("2026-09-22", NOW), profileAgeDays("nope", NOW)], [60, null]);
  assertEquals(gbpDateTime(null, "UTC"), null);
});

// ---- live safety ----------------------------------------------------------------

Deno.test("stand-in and placeholder ids are refused if they would ever be sent live", async () => {
  // Writes live (both switches on, a stub fetch): a missing account id is a placeholder, refused before fetch.
  const noId = cred("ig_publish", {});
  const live = ctxFor(instagramHttp(noId), noId, { live: true });
  await assertRejects(() => instagramAdapter.publishPost!(live.ctx, { id: EVENT.id }, post("instagram")) as Promise<unknown>, GatedHttpRefused, "placeholder");
  assertEquals(live.seen.calls, 0);
  const li = cred("linkedin", {});
  const l = ctxFor(linkedinHttp(li), li, { live: true });
  await assertRejects(() => linkedinAdapter.upsertEvent!(l.ctx, { id: EVENT.id }, { post: post("linkedin") }) as Promise<unknown>, GatedHttpRefused);
  const g = cred("google_business", {});
  const gl = ctxFor(googleBusinessHttp(g), g, { live: true, facts: { profileAgeDays: 90 } });
  await assertRejects(() => googleBusinessAdapter.publishPost!(gl.ctx, { id: EVENT.id, venue_org: true }, post("google_business")) as Promise<unknown>, GatedHttpRefused);
  assertEquals(gl.seen.calls, 0);
});

// ---- the pass ---------------------------------------------------------------------

function deps(over: Partial<RunDeps> = {}, creds: Record<string, unknown> = {}): RunDeps & { fetchCalls: () => number } {
  const { f, seen } = stubFetch();
  return {
    orgId: "org-1",
    rpc: async (fn, args) => fn === "exos_integration_secret" ? { data: creds[String(args.p_provider)] ?? null, error: null } : { data: null, error: null },
    env: () => "on", // every operator flag on, and the app "audited": the pin still holds
    fetch: f,
    appBase: APP,
    now: () => NOW,
    counter: memoryUsageCounter(() => NOW.getTime()),
    persistAudit: false,
    fetchCalls: () => seen.calls,
    ...over,
  };
}

const row = (provider: string, config: Record<string, unknown>, secret: string | null = SECRET) =>
  ({ provider, status: "connected", config, secret, writes_enabled: true, source: "store" });

Deno.test("the pass: pinned off, every platform planned from one kit, nothing sent even with every flag on", async () => {
  assertEquals(SOCIAL_WRITES_PINNED_OFF, true);
  const d = deps({}, {
    ig_publish: row("ig_publish", { ig_user_id: "1784" }),
    tiktok_publish: row("tiktok_publish", { open_id: "o1" }),
    meetup: row("meetup", { group_urlname: "g", plan: "starter", pro_network: "p" }),
    linkedin: row("linkedin", { organization_id: "5551234" }),
    google_business: row("google_business", { account_id: "1", location_id: "2", verified_at: "2026-01-01" }, null),
    ads_google_ads: row("ads_google_ads", { customer_id: "1234567890" }, "google-refresh"),
  });
  const out = await planSocial(d, { event: EVENT, venueOrg: true });
  assertEquals(d.fetchCalls(), 0, "no request reaches a platform");
  assertEquals(out.platforms.map((p) => p.platform), [...SOCIAL_PLATFORMS]);
  for (const p of out.platforms) {
    assert(p.status.dryRun && p.status.connected, p.platform);
    assert(p.steps.length > 0 && p.steps.every((s) => !s.live), `${p.platform}: every step a plan`);
    assert(!JSON.stringify(p).includes(SECRET) && !JSON.stringify(p).includes("google-refresh"), `${p.platform}: no secret`);
  }
  const gbp = out.platforms.find((p) => p.platform === "google_business")!;
  assertEquals(gbp.status.via, "ads_google_ads", "Business Profile borrows the Google connection");
  assertEquals(gbp.status.app, "google");
  assertEquals(out.platforms.find((p) => p.platform === "instagram")!.status.app, "meta");
  const tt = out.platforms.find((p) => p.platform === "tiktok")!;
  assert(!tt.result.warnings.includes(TIKTOK_SELF_ONLY_WARNING), "EXOS_TIKTOK_APP_AUDITED=on drops the warning");
  assertEquals((tt.steps[1].body as any).post_info.privacy_level, "SELF_ONLY", "still private: creator_info is a stand-in");
});

Deno.test("the pass: nothing connected plans with placeholders and says so; one platform only", async () => {
  const d = deps({ env: () => undefined });
  const out = await planSocial(d, { event: EVENT, venueOrg: false, platforms: ["instagram", "google_business"] });
  assertEquals(out.platforms.map((p) => p.platform), ["instagram", "google_business"]);
  const ig = out.platforms[0];
  assert(!ig.status.connected && ig.result.warnings.some((w) => w.includes("isn't connected")));
  assertEquals(ig.steps[0].path, "/v25.0/planned_account/media");
  assertStringIncludes(out.platforms[1].result.stopped!, "run their own venue");
  assertEquals(d.fetchCalls(), 0);
});

// ---- the vendor apps ----------------------------------------------------------------

Deno.test("one OAuth app per vendor family; every social provider has exactly one", () => {
  const providers = Object.values(VENDOR_APPS).flatMap((a) => a.providers);
  assertEquals(new Set(providers).size, providers.length);
  assertEquals(["ig_publish", "ads_meta_api"].map(familyOf), ["meta", "meta"]);
  assertEquals(["google_business", "ads_google_ads"].map(familyOf), ["google", "google"]);
  assertEquals(["linkedin", "tiktok_publish", "meetup", "nope"].map(familyOf), ["linkedin", "tiktok", "meetup", null]);
  assert(Object.values(VENDOR_APPS).every((a) => a.connect === "stub"), "no connect flow built in this phase");
  assert(VENDOR_APPS.meta.scopes.includes("instagram_content_publish"));
  assert(VENDOR_APPS.google.scopes.includes("https://www.googleapis.com/auth/business.manage"));
  assertEquals(VENDOR_APPS.google.env.id, "GOOGLE_OAUTH_CLIENT_ID", "the existing Google client");
  assertEquals([appConfigured("tiktok", () => " "), appConfigured("tiktok", () => "abc")], [false, true]);
});
