import { assert, assertEquals, assertRejects } from "jsr:@std/assert@1";
import {
  allowedRequest, announcementBody, DISCORD_API, DISCORD_BOT_PERMISSIONS, DISCORD_HOSTS, DISCORD_TOKEN_URL, discordAppConfig,
  discordEvent, discordHash, type DiscordStep, escapeMarkdown, eventLocation, exchangeInstallCode, installUrl,
  coverDataUri, coverObject, type CallKind, type DiscordResult, errorKind, linkBroken,
  makeDiscordIo, postAnnouncement, redactDiscord, redactPath, scheduledEventBody, syncScheduledEvent, webhookPath, webhookUrlParts,
} from "./discord.ts";

const GUILD = "423456789012345671";
const OTHER_GUILD = "999999999999999999";
const HOOK = "223456789012345679";
const TOKEN = "T3" + "aB9_-x".repeat(11) + "Zq";
const BOT = "bot.token.value.abcdefghijklmnopqrstuvwxyz";
const APP = "https://tickets.example/bridge";

const ROW = {
  id: "0b6f2f4e-1111-4222-8333-944455556666", slug: "late-show", name: "Late Show @everyone", status: "published",
  starts_at: "2027-01-16T01:00:00+00:00", ends_at: null, timezone: "America/New_York",
  description: "Doors at 7.", image_url: "https://proj.supabase.co/storage/v1/object/public/e/cover.png",
  location_mode: "venue_record", venue_name: "Blue [Room](https://evil.example)", venue_location: "Brooklyn", city: "Brooklyn",
  org_name: "Blue Room Presents",
};

type Call = { method: string; url: string; headers: Record<string, string>; body: any };
function fakeFetch(answer: (c: Call) => { status: number; body?: unknown; headers?: Record<string, string> }, calls: Call[]) {
  return ((url: string, init?: RequestInit) => {
    const c: Call = {
      method: init?.method ?? "GET", url, headers: (init?.headers ?? {}) as Record<string, string>,
      body: typeof init?.body === "string" && init.body.startsWith("{") ? JSON.parse(init.body) : init?.body,
    };
    calls.push(c);
    const a = answer(c);
    return Promise.resolve(new Response(a.status === 204 ? null : JSON.stringify(a.body ?? {}),
      { status: a.status, headers: { "content-type": "application/json", ...(a.headers ?? {}) } }));
  }) as typeof fetch;
}

Deno.test("allowlist: only the org's own guild events and its own webhook", () => {
  const b = { guildId: GUILD, webhookId: HOOK };
  assertEquals(allowedRequest("POST", `/guilds/${GUILD}/scheduled-events`, b), "guild");
  assertEquals(allowedRequest("PATCH", `/guilds/${GUILD}/scheduled-events/523456789012345672`, b), "guild");
  assertEquals(allowedRequest("DELETE", `/guilds/${GUILD}/scheduled-events/523456789012345672`, b), "guild");
  assertEquals(allowedRequest("GET", `/guilds/${GUILD}/scheduled-events/523456789012345672`, b), "guild");
  assertEquals(allowedRequest("POST", `/webhooks/${HOOK}/${TOKEN}?wait=true&with_components=true`, b), "webhook");
  for (const [m, p] of [
    ["POST", `/guilds/${OTHER_GUILD}/scheduled-events`],                       // another server
    ["DELETE", `/guilds/${GUILD}/scheduled-events`],
    ["POST", `/webhooks/323456789012345670/${TOKEN}`],                         // another webhook
    ["POST", `/webhooks/${HOOK}/${TOKEN}/github`],
    ["POST", `/webhooks/${HOOK}/${TOKEN}?wait=true&thread_name=x`],
    ["PATCH", `/webhooks/${HOOK}/${TOKEN}/messages/1`],                        // edit a message
    ["POST", `/channels/123456789012345678/messages`],                        // a message
    ["POST", `/users/@me/channels`],                                           // a DM
    ["PUT", `/guilds/${GUILD}/members/123456789012345678/roles/123456789012345678`],
    ["PATCH", `/guilds/${GUILD}`],
    ["POST", `/guilds/${GUILD}/channels`],
    ["POST", `/oauth2/token`],
    ["POST", `/guilds/${GUILD}/scheduled-events/../channels`],
    ["POST", `/guilds/${GUILD}/scheduled-events?x=1`],
    ["GET", `/guilds/${GUILD}/members`],
  ] as const) {
    assertEquals(allowedRequest(m, p, b), null, `${m} ${p}`);
  }
  assertEquals(allowedRequest("POST", `/guilds/${GUILD}/scheduled-events`, { webhookId: HOOK }), null, "no guild linked");
  assertEquals(allowedRequest("POST", `/webhooks/${HOOK}/${TOKEN}`, { guildId: GUILD }), null, "no webhook set");
  assertEquals([...DISCORD_HOSTS], ["discord.com"]);
  assertEquals(DISCORD_API, "https://discord.com/api/v10");
  assertEquals(BigInt(DISCORD_BOT_PERMISSIONS), 1n << 44n);   // CREATE_EVENTS only
});

Deno.test("io: a refused request throws before fetch; a dry run sends nothing and hides the token", async () => {
  const calls: Call[] = [];
  const steps: DiscordStep[] = [];
  const io = makeDiscordIo({ fetch: fakeFetch(() => ({ status: 200 }), calls), live: false, bound: { guildId: GUILD, webhookId: HOOK }, botToken: BOT, steps });
  await assertRejects(() => io.req("POST", `/channels/123456789012345678/messages`, {}), Error, "not an allowed request");
  await assertRejects(() => io.req("DELETE", `/guilds/${OTHER_GUILD}/scheduled-events/523456789012345672`), Error, "not an allowed request");
  const err = await io.req("POST", `/webhooks/323456789012345670/${TOKEN}`, {}).catch((e) => String(e));
  assert(!String(err).includes(TOKEN), "the refusal hides the token");
  const r = await io.req("POST", webhookPath(HOOK, TOKEN), { a: 1 });
  assertEquals(r.ok, true);
  assertEquals(calls.length, 0);
  assertEquals(steps[0].op, "planned");
  assertEquals(steps[0].path, `/webhooks/${HOOK}/***?wait=true&with_components=true`);
  assert(!JSON.stringify(steps).includes(TOKEN));
});

Deno.test("io live: bot token only on guild routes; Discord's code, never its message; 429 retry_after", async () => {
  const calls: Call[] = [];
  const f = fakeFetch((c) => c.url.includes("/webhooks/")
    ? { status: 429, body: { message: `slow down ${TOKEN}`, retry_after: 12.4, global: false } }
    : { status: 400, body: { code: 50035, message: "Invalid Form Body: secret stuff" } }, calls);
  const steps: DiscordStep[] = [];
  const io = makeDiscordIo({ fetch: f, live: true, bound: { guildId: GUILD, webhookId: HOOK }, botToken: BOT, steps });
  const g = await io.req("POST", `/guilds/${GUILD}/scheduled-events`, { name: "x" });
  assertEquals(g.error, "DISCORD_50035");
  assertEquals(calls[0].headers.Authorization, `Bot ${BOT}`);
  assertEquals(calls[0].url, `https://discord.com/api/v10/guilds/${GUILD}/scheduled-events`);
  const w = await io.req("POST", webhookPath(HOOK, TOKEN), {});
  assertEquals([w.error, w.retryAfter], ["RATE_LIMITED", 13]);
  assertEquals(calls[1].headers.Authorization, undefined, "no bot token to a webhook");
  for (const c of calls) assertEquals(new URL(c.url).hostname, "discord.com");
  assert(!JSON.stringify(steps).includes(TOKEN) && !JSON.stringify(steps).includes("secret stuff"));
});

Deno.test("event: page URL, zone, venue; TBA has no venue; bad rows refused", () => {
  const ev = discordEvent(ROW, APP + "/")!;
  assertEquals(ev.url, `${APP}/e/late-show`);
  assertEquals(ev.startUtc, "2027-01-16T01:00:00Z");
  assertEquals(ev.endUtc, "2027-01-16T04:00:00Z");
  assertEquals(ev.venueLine, "Blue [Room](https://evil.example), Brooklyn");
  assertEquals(discordEvent({ ...ROW, location_mode: "tba" }, APP)!.venueLine, null);
  assertEquals(discordEvent({ ...ROW, image_url: "http://x/y.png" }, APP)!.imageUrl, null);
  assertEquals(discordEvent({ ...ROW, name: "" }, APP), null);
  assertEquals(discordEvent(ROW, "http://insecure"), null);
});

Deno.test("announcement: one embed, a Get tickets link, no mentions, the event's zone, escaped venue", () => {
  const ev = discordEvent(ROW, APP)!;
  const b = announcementBody(ev, "publish");
  assertEquals(b.allowed_mentions, { parse: [] });
  assertEquals(b.embeds.length, 1);
  const e = b.embeds[0] as any;
  assertEquals(e.title, "Late Show @everyone");
  assertEquals(e.url, `${APP}/e/late-show`);
  assertEquals(e.image, { url: ROW.image_url });
  assertEquals(e.footer, { text: "Blue Room Presents" });
  // 01:00 UTC on the 16th is 8 PM on the 15th in New York.
  assert(e.description.includes("Fri, Jan 15, 2027, 8:00 PM EST"), e.description);
  assert(e.description.includes("<t:1800061200:R>"));
  assert(e.description.includes("Blue \\[Room\\]\\(https://evil.example\\)"), "masked link escaped");
  assertEquals(b.components, [{ type: 1, components: [{ type: 2, style: 5, label: "Get tickets", url: `${APP}/e/late-show` }] }]);
  assert(!("content" in b), "no content: nothing to ping");
  assert((announcementBody(ev, "reminder").embeds[0] as any).description.startsWith("**Coming up soon.**"));
  assertEquals(escapeMarkdown("<@&1> **x**"), "\\<\\@&1\\> \\*\\*x\\*\\*");
});

Deno.test("post: dry run plans only; sent keeps the message id; a 5xx is not retried; 404 asks for a new URL", async () => {
  const ev = discordEvent(ROW, APP)!;
  const calls: Call[] = [];
  let steps: DiscordStep[] = [];
  const dry = makeDiscordIo({ fetch: fakeFetch(() => ({ status: 200 }), calls), live: false, bound: { webhookId: HOOK }, steps });
  const d = await postAnnouncement(dry, ev, "publish", HOOK, TOKEN, steps);
  assertEquals([d.state, calls.length], ["dry_run", 0]);
  assertEquals((d.plan.steps[0].body as any).allowed_mentions, { parse: [] });
  for (const [status, body, want] of [
    [200, { id: "723456789012345675" }, "sent"], [503, {}, "error"], [404, { code: 10015 }, "error"],
  ] as const) {
    steps = [];
    const io = makeDiscordIo({ fetch: fakeFetch(() => ({ status, body }), calls), live: true, bound: { webhookId: HOOK }, steps });
    const r = await postAnnouncement(io, ev, "publish", HOOK, TOKEN, steps);
    assertEquals(r.state, want);
    if (want === "sent") assertEquals(r.messageId, "723456789012345675");
    if (status === 404) assert(r.error!.includes("paste a new one"));
    assert(!JSON.stringify(r).includes(TOKEN));
  }
  const last = calls[calls.length - 1];
  assertEquals(last.url, `https://discord.com/api/v10/webhooks/${HOOK}/${TOKEN}?wait=true&with_components=true`);
  assertEquals(last.body.allowed_mentions, { parse: [] });
});

Deno.test("scheduled event: EXTERNAL, guild only, end time, location = the event page", () => {
  const ev = discordEvent(ROW, APP)!;
  const b = scheduledEventBody(ev, "data:image/png;base64,AAAA");
  assertEquals([b.entity_type, b.privacy_level, b.channel_id], [3, 2, null]);
  assertEquals(b.entity_metadata, { location: `${APP}/e/late-show` });
  assertEquals([b.scheduled_start_time, b.scheduled_end_time], ["2027-01-16T01:00:00Z", "2027-01-16T04:00:00Z"]);
  assert(b.description.startsWith(`Get tickets: ${APP}/e/late-show`));
  assertEquals(b.image, "data:image/png;base64,AAAA");
  const long = discordEvent({ ...ROW, slug: "x".repeat(120) }, APP)!;
  assertEquals(eventLocation(long), `${APP}/event/${ROW.id}`);
  assert(scheduledEventBody(discordEvent({ ...ROW, name: "n".repeat(300), description: "d".repeat(3000) }, APP)!).name.length <= 100);
});

Deno.test("sync: create, update on change, cancel, delete when unticked, gone on 404; dry run sends nothing", async () => {
  const ev = discordEvent(ROW, APP)!;
  const hash = await discordHash(ev);
  const noImage = () => Promise.resolve(null);
  const calls: Call[] = [];
  const answer = (c: Call) => c.method === "POST" ? { status: 200, body: { id: "523456789012345672" } }
    : c.method === "DELETE" ? { status: 204 } : { status: 200, body: { id: "523456789012345672" } };
  const live = (steps: DiscordStep[]) =>
    makeDiscordIo({ fetch: fakeFetch(answer, calls), live: true, bound: { guildId: GUILD }, botToken: BOT, steps });
  let steps: DiscordStep[] = [];
  let r = await syncScheduledEvent(live(steps), ev, GUILD, { show: true, external_id: null, last_hash: null }, hash, steps, noImage);
  assertEquals([r.state, r.external_id, r.guild_id], ["synced", "523456789012345672", GUILD]);
  assertEquals(calls.at(-1)!.method, "POST");
  // Unchanged: no request.
  const n = calls.length;
  steps = [];
  r = await syncScheduledEvent(live(steps), ev, GUILD, { show: true, external_id: "523456789012345672", last_hash: hash, status: "synced" }, hash, steps, noImage);
  assertEquals([r.state, calls.length], ["synced", n]);
  // Changed: PATCH.
  steps = [];
  r = await syncScheduledEvent(live(steps), ev, GUILD, { show: true, external_id: "523456789012345672", last_hash: "old", status: "synced" }, hash, steps, noImage);
  assertEquals([r.state, calls.at(-1)!.method], ["synced", "PATCH"]);
  // Cancelled in Exos: status 4.
  steps = [];
  r = await syncScheduledEvent(live(steps), { ...ev, status: "cancelled" }, GUILD, { show: true, external_id: "523456789012345672", last_hash: hash }, hash, steps, noImage);
  assertEquals([r.state, r.external_id, calls.at(-1)!.method, calls.at(-1)!.body], ["synced", null, "PATCH", { status: 4 }]);
  // Unticked: DELETE.
  steps = [];
  r = await syncScheduledEvent(live(steps), ev, GUILD, { show: false, external_id: "523456789012345672", last_hash: hash }, hash, steps, noImage);
  assertEquals([r.state, r.external_id, calls.at(-1)!.method], ["synced", null, "DELETE"]);
  // Deleted in Discord: gone.
  const goneCalls: Call[] = [];
  steps = [];
  const io404 = makeDiscordIo({ fetch: fakeFetch(() => ({ status: 404, body: { code: 10070 } }), goneCalls), live: true, bound: { guildId: GUILD }, botToken: BOT, steps });
  r = await syncScheduledEvent(io404, ev, GUILD, { show: true, external_id: "523456789012345672", last_hash: "old", status: "synced" }, hash, steps, noImage);
  assertEquals([r.state, r.gone], ["error", true]);
  // 429: retry after Discord's wait.
  steps = [];
  const io429 = makeDiscordIo({ fetch: fakeFetch(() => ({ status: 429, body: { retry_after: 3 } }), []), live: true, bound: { guildId: GUILD }, botToken: BOT, steps });
  r = await syncScheduledEvent(io429, ev, GUILD, { show: true, external_id: null, last_hash: null }, hash, steps, noImage);
  assertEquals([r.state, r.retry_seconds], ["retry", 3]);
  // Dry run: the plan, nothing sent.
  const dryCalls: Call[] = [];
  steps = [];
  const dry = makeDiscordIo({ fetch: fakeFetch(answer, dryCalls), live: false, bound: { guildId: GUILD }, botToken: BOT, steps });
  r = await syncScheduledEvent(dry, ev, GUILD, { show: true, external_id: null, last_hash: null }, hash, steps, noImage);
  assertEquals([r.state, dryCalls.length, steps[0].op, steps[0].method], ["dry_run", 0, "planned", "POST"]);
  // The guild it's bound to is the only one it touches.
  await assertRejects(() => syncScheduledEvent(dry, ev, OTHER_GUILD, { show: true, external_id: null, last_hash: null }, hash, [], noImage),
    Error, "not an allowed request");
  // Over: nothing made.
  steps = [];
  r = await syncScheduledEvent(live(steps), ev, GUILD, { show: true, external_id: null, last_hash: null }, hash, steps, noImage, Date.parse("2027-02-01"));
  assertEquals([r.state, r.external_id, steps.length], ["synced", null, 0]);
});

const SB = "https://proj.supabase.co";
const COVER = `${SB}/storage/v1/object/public/exos-media/event-images/0b6f2f4e-1111-4222-8333-944455556666/1c6f2f4e-1111-4222-8333-944455556666.png`;
const PNG = new Uint8Array([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);

Deno.test("cover: only our own storage object, read with the service client; never an HTTP fetch", async () => {
  const reads: string[] = [];
  const load = (bucket: string, path: string, max: number) => { reads.push(`${bucket}/${path}:${max}`); return Promise.resolve(PNG); };
  assertEquals(await coverDataUri(load, COVER, SB), "data:image/png;base64,iVBORw0KGgo=");
  assertEquals(reads, [`exos-media/event-images/0b6f2f4e-1111-4222-8333-944455556666/1c6f2f4e-1111-4222-8333-944455556666.png:${4 * 1024 * 1024}`]);
  for (const bad of [
    "https://cdn.example/a.png",                                         // foreign host
    "https://10.0.0.1/storage/v1/object/public/exos-media/event-images/x/y.png",
    COVER.replace("https://proj.supabase.co", "https://proj.supabase.co.evil.example"), // look-alike host (a rebinding name)
    COVER.replace("https://", "http://"),
    COVER.replace("https://", "https://u:p@"),
    COVER + "?download=1",
    COVER.replace("/public/exos-media/", "/public/other-bucket/"),
    COVER.replace("/object/public/", "/object/authenticated/"),
    COVER.replace("event-images/", "event-images/../org-logos/"),
    COVER.replace("event-images/", "event-images%2F"),
    `${SB}/storage/v1/object/public/exos-media/org-logos/0b6f2f4e-1111-4222-8333-944455556666/logo-1.png`,
    null,
  ]) {
    assertEquals(coverObject(bad, SB), null, String(bad));
  }
  const n = reads.length;
  assertEquals(await coverDataUri(load, "https://cdn.example/a.png", SB), null);
  assertEquals(reads.length, n, "a foreign URL reads nothing");
  // Not an image, too big, unreadable: no image.
  assertEquals(await coverDataUri(() => Promise.resolve(new TextEncoder().encode("<svg/>")), COVER, SB), null);
  assertEquals(await coverDataUri(() => Promise.resolve(new Uint8Array(4 * 1024 * 1024 + 1)), COVER, SB), null);
  assertEquals(await coverDataUri(() => Promise.reject(new Error("x")), COVER, SB), null);
  // A dry run never reads the cover (and never fetches anything).
  const ev = discordEvent({ ...ROW, image_url: COVER }, APP)!;
  let asked = 0;
  const calls: Call[] = [];
  const steps: DiscordStep[] = [];
  const dry = makeDiscordIo({ fetch: fakeFetch(() => ({ status: 200 }), calls), live: false, bound: { guildId: GUILD }, botToken: BOT, steps });
  const r = await syncScheduledEvent(dry, ev, GUILD, { show: true, external_id: null, last_hash: null }, await discordHash(ev), steps,
    () => { asked++; return Promise.resolve("data:image/png;base64,AAAA"); });
  assertEquals([r.state, asked, calls.length], ["dry_run", 0, 0]);
  assert(!("image" in (steps[0].body as any)), "no image in the dry-run plan");
});

Deno.test("breaker: the gate stops calls before fetch; refusals are reported with code, scope and global", async () => {
  const calls: Call[] = [];
  const reported: [CallKind, DiscordResult][] = [];
  const hooks = (ok: boolean) => ({
    gate: (_k: CallKind) => Promise.resolve(ok ? { ok: true } : { ok: false, reason: "breaker", retryAfter: 600 }),
    report: (k: CallKind, r: DiscordResult) => { reported.push([k, r]); return Promise.resolve(); },
  });
  // Gate closed: nothing sent, safe to retry.
  let steps: DiscordStep[] = [];
  const shut = makeDiscordIo({ fetch: fakeFetch(() => ({ status: 200 }), calls), live: true, bound: { guildId: GUILD, webhookId: HOOK }, botToken: BOT, steps, hooks: hooks(false) });
  const g = await shut.req("POST", `/guilds/${GUILD}/scheduled-events`, {});
  assertEquals([g.ok, g.error, g.notSent, g.retryAfter, calls.length], [false, "DISCORD_PAUSED", true, 600, 0]);
  // The org's own pause: refused before fetch, retried after it.
  const orgShut = makeDiscordIo({ fetch: fakeFetch(() => ({ status: 200 }), calls), live: true, bound: { webhookId: HOOK }, steps: [],
    hooks: { gate: () => Promise.resolve({ ok: false, reason: "org_paused", retryAfter: 1800 }) } });
  const op = await postAnnouncement(orgShut, discordEvent(ROW, APP)!, "publish", HOOK, TOKEN, []);
  assertEquals([op.state, op.retrySeconds, calls.length], ["retry", 1800, 0]);
  // 401 on the bot: reported as bot (SQL trips the breaker); the pass says so.
  steps = [];
  const ev = discordEvent(ROW, APP)!;
  const io401 = makeDiscordIo({ fetch: fakeFetch(() => ({ status: 401, body: { code: 0, message: "401: Unauthorized" } }), calls), live: true,
    bound: { guildId: GUILD }, botToken: BOT, steps, hooks: hooks(true) });
  let r = await syncScheduledEvent(io401, ev, GUILD, { show: true, external_id: null, last_hash: null }, "h", steps, () => Promise.resolve(null));
  assertEquals([r.state, reported.at(-1)![0], reported.at(-1)![1].status], ["error", "bot", 401]);
  assert(r.error!.includes("paused"));
  // 403 missing access: the link is broken (the guild named so SQL marks that link).
  steps = [];
  const io403 = makeDiscordIo({ fetch: fakeFetch(() => ({ status: 403, body: { code: 50001 } }), calls), live: true,
    bound: { guildId: GUILD }, botToken: BOT, steps, hooks: hooks(true) });
  r = await syncScheduledEvent(io403, ev, GUILD, { show: true, external_id: null, last_hash: null }, "h", steps, () => Promise.resolve(null));
  assertEquals([r.state, r.link_broken, r.guild_id], ["error", true, GUILD]);
  // Unknown guild on an update is a broken link, not a deleted event.
  steps = [];
  const io10004 = makeDiscordIo({ fetch: fakeFetch(() => ({ status: 404, body: { code: 10004 } }), calls), live: true,
    bound: { guildId: GUILD }, botToken: BOT, steps, hooks: hooks(true) });
  r = await syncScheduledEvent(io10004, ev, GUILD, { show: true, external_id: "523456789012345672", last_hash: "old", status: "synced" }, "h", steps, () => Promise.resolve(null));
  assertEquals([r.link_broken, r.gone], [true, undefined]);
  // A global 429 (header) is reported as global, and the pass retries after it.
  steps = [];
  const io429 = makeDiscordIo({ fetch: fakeFetch(() => ({ status: 429, body: { retry_after: 7.2, global: false }, headers: { "x-ratelimit-global": "true", "x-ratelimit-scope": "global" } }), calls),
    live: true, bound: { guildId: GUILD }, botToken: BOT, steps, hooks: hooks(true) });
  r = await syncScheduledEvent(io429, ev, GUILD, { show: true, external_id: null, last_hash: null }, "h", steps, () => Promise.resolve(null));
  const last = reported.at(-1)![1];
  assertEquals([r.state, r.retry_seconds, last.global, last.scope, last.error], ["retry", 8, true, "global", "RATE_LIMITED_GLOBAL"]);
  assertEquals(linkBroken({ ok: false, status: 403, body: null, code: 50013 }), true);
  assertEquals(linkBroken({ ok: false, status: 403, body: null, code: 50035 }), false);
});

Deno.test("post: retried only when nothing can have been posted; a refused webhook is marked broken", async () => {
  const ev = discordEvent(ROW, APP)!;
  const run = async (f: typeof fetch) => {
    const steps: DiscordStep[] = [];
    const io = makeDiscordIo({ fetch: f, live: true, bound: { webhookId: HOOK }, steps });
    return await postAnnouncement(io, ev, "publish", HOOK, TOKEN, steps);
  };
  const ans = (status: number, body: unknown = {}) => fakeFetch(() => ({ status, body }), []);
  assertEquals((await run(ans(429, { retry_after: 2 }))).state, "retry");
  for (const st of [500, 502, 503]) {
    const r = await run(ans(st));
    assertEquals(r.state, "error", `HTTP ${st}`);
    assert(r.error!.includes("check the channel"));
  }
  const timeout = (() => Promise.reject(Object.assign(new Error("aborted"), { name: "AbortError" }))) as typeof fetch;
  assertEquals((await run(timeout)).state, "error");
  const refused = (() => Promise.reject(new TypeError("error sending request: error trying to connect: tcp connect error: Connection refused"))) as typeof fetch;
  assertEquals((await run(refused)).state, "retry");
  const reset = (() => Promise.reject(new TypeError("connection reset by peer"))) as typeof fetch;
  assertEquals((await run(reset)).state, "error");
  for (const [st, body] of [[404, { code: 10015 }], [401, {}], [403, {}]] as const) {
    const r = await run(ans(st, body));
    assertEquals([r.state, r.webhookBroken], ["error", true], `HTTP ${st}`);
  }
  assertEquals([errorKind(new TypeError("dns error: failed to lookup address")), errorKind(new Error("x"))], ["CONNECT", "NETWORK"]);
});

Deno.test("install: bot scope, CREATE_EVENTS only, the server from the token response, never the redirect's hint", async () => {
  const env = (m: Record<string, string>) => (k: string) => m[k];
  assertEquals(discordAppConfig(env({ DISCORD_APPLICATION_ID: "123456789012345678" })), null);
  const cfg = discordAppConfig(env({
    DISCORD_APPLICATION_ID: "123456789012345678", DISCORD_CLIENT_SECRET: "sec", DISCORD_BOT_TOKEN: BOT, SUPABASE_URL: "https://p.supabase.co",
  }))!;
  assertEquals(cfg.redirectUri, "https://p.supabase.co/functions/v1/exos-discord/callback");
  const u = new URL(installUrl(cfg, "S".repeat(43)));
  assertEquals(u.origin + u.pathname, "https://discord.com/oauth2/authorize");
  assertEquals([u.searchParams.get("scope"), u.searchParams.get("permissions"), u.searchParams.get("response_type")],
    ["bot", "17592186044416", "code"]);
  const calls: Call[] = [];
  const f = fakeFetch(() => ({ status: 200, body: { access_token: "user-token", guild: { id: GUILD, name: "Blue Room Discord" } } }), calls);
  assertEquals(await exchangeInstallCode(f, cfg, "code-abcdef12"), { guildId: GUILD, guildName: "Blue Room Discord" });
  assertEquals([calls[0].url, calls[0].method], [DISCORD_TOKEN_URL, "POST"]);
  assert(String(calls[0].body).includes("grant_type=authorization_code"));
  const noGuild = fakeFetch(() => ({ status: 200, body: { access_token: "t" } }), []);
  assertEquals(await exchangeInstallCode(noGuild, cfg, "code-abcdef12"), { error: "no_guild" });
  assertEquals(await exchangeInstallCode(fakeFetch(() => ({ status: 401, body: {} }), []), cfg, "code-abcdef12"), { error: "config" });
  assertEquals(await exchangeInstallCode(f, cfg, "bad code"), { error: "code" });
});

Deno.test("webhook URL hint parse and redaction match the SQL", () => {
  assertEquals(webhookUrlParts(`https://discordapp.com/api/v10/webhooks/${HOOK}/${TOKEN}`), { webhookId: HOOK, token: TOKEN });
  for (const bad of [`https://ptb.discord.com/api/webhooks/${HOOK}/${TOKEN}`, `https://discord.com/api/webhooks/${HOOK}/${TOKEN}?x=1`,
                     `http://discord.com/api/webhooks/${HOOK}/${TOKEN}`, `https://discord.com.evil.example/api/webhooks/${HOOK}/${TOKEN}`]) {
    assertEquals(webhookUrlParts(bad), null, bad);
  }
  assertEquals(redactPath(`/webhooks/${HOOK}/${TOKEN}?wait=true`), `/webhooks/${HOOK}/***?wait=true`);
  const text = redactDiscord(`failed https://discord.com/api/webhooks/${HOOK}/${TOKEN} with Bot ${BOT}`, [TOKEN]);
  assert(!text.includes(TOKEN) && !text.includes(BOT), text);
});
