// GatedHttp (channel core, mig 20261121162400): the live / dry-run decision
// (org switch AND EXOS_<ID>_WRITES AND the allowlist), redaction, retries on
// reads only (_shared/retry.ts), credentials never in URLs, the limits
// (block / cap / warn) and the usage counters it spends.
import { assert, assertEquals, assertRejects, assertThrows } from "jsr:@std/assert@1";
import {
  assertNoSecretsInUrl, createGatedHttp, decideLive, GatedHttpRefused, redact, redactHeaders, writeFlagName,
  type GatedHttpOptions,
} from "./gatedHttp.ts";
import { memoryAuditSink, rpcAuditSink } from "./audit.ts";
import { memoryUsageCounter } from "./usage.ts";
import { writesLive } from "./model.ts";
import type { RetryPolicy } from "../retry.ts";

const SECRET = "sk_live_ABCDEF123456";
const NO_SLEEP: RetryPolicy = { maxRetries: 2, baseMs: 1, maxWaitMs: 5_000, sleep: async () => {}, random: () => 0 };

interface Call { url: string; method: string; headers: Record<string, string>; body: string | null }
function fakeFetch(answers: Array<{ status: number; body?: unknown; headers?: Record<string, string> } | Error>) {
  const calls: Call[] = [];
  const f = (async (input: RequestInfo | URL, init?: RequestInit) => {
    const h: Record<string, string> = {};
    new Headers(init?.headers ?? {}).forEach((v, k) => { h[k] = v; });
    calls.push({ url: String(input), method: init?.method ?? "GET", headers: h, body: (init?.body as string) ?? null });
    const a = answers.length > 1 ? answers.shift()! : answers[0];
    if (a instanceof Error) throw a;
    return new Response(a.body === undefined ? null : JSON.stringify(a.body), { status: a.status, headers: a.headers ?? {} });
  }) as typeof fetch;
  return { f, calls };
}

function opts(over: Partial<GatedHttpOptions> = {}): GatedHttpOptions {
  return {
    channel: "luma",
    base: "https://api.example.com",
    fetch: fakeFetch([{ status: 200, body: { id: "x1" } }]).f,
    env: () => undefined,
    orgWritesEnabled: false,
    writes: [{ method: "POST", path: /^\/v1\/event\/create$/ }, { method: "PUT", path: /^\/v1\/thing\/[a-z0-9]+$/, idempotent: true }],
    headers: { "x-luma-api-key": SECRET },
    secrets: [SECRET],
    audit: memoryAuditSink(),
    retry: NO_SLEEP,
    ...over,
  };
}

Deno.test("decideLive: a write needs the org switch AND the operator flag AND the allowlist", () => {
  const base = { channel: "luma", writes: [{ method: "POST" as const, path: /^\/v1\/event\/create$/ }] };
  const on = (k: string) => (k === "EXOS_LUMA_WRITES" ? "on" : undefined);
  assertEquals(writeFlagName("luma"), "EXOS_LUMA_WRITES");
  assertEquals(writeFlagName("google_events"), "EXOS_GOOGLE_EVENTS_WRITES");
  assert(decideLive({ ...base, env: on, orgWritesEnabled: true }, "POST", "/v1/event/create").live);
  assert(!decideLive({ ...base, env: on, orgWritesEnabled: false }, "POST", "/v1/event/create").live, "org off");
  assert(!decideLive({ ...base, env: () => undefined, orgWritesEnabled: true }, "POST", "/v1/event/create").live, "flag unset");
  assert(!decideLive({ ...base, env: () => "true", orgWritesEnabled: true }, "POST", "/v1/event/create").live, "only 'on' counts");
  assert(!decideLive({ ...base, env: on, orgWritesEnabled: "yes" }, "POST", "/v1/event/create").live, "only true counts");
  const d = decideLive({ ...base, env: on, orgWritesEnabled: true }, "POST", "/v1/event/delete");
  assert(!d.live && !d.allowed && d.reasons[0].includes("not on the luma allowlist"));
  assert(!decideLive({ ...base, env: on, orgWritesEnabled: true }, "PUT", "/v1/event/create").allowed, "method matters");
  assert(decideLive({ ...base, env: () => undefined, orgWritesEnabled: false }, "GET", "/v1/anything").live, "reads always go");
  // The same gate model.ts already has: reused, not duplicated.
  assertEquals(writesLive(true, "on"), true);
});

Deno.test("dry run: nothing sent, the exact payload recorded (redacted), a stand-in back", async () => {
  const { f, calls } = fakeFetch([{ status: 200, body: {} }]);
  const audit = memoryAuditSink();
  const http = createGatedHttp(opts({ fetch: f, audit, env: (k) => (k === "EXOS_LUMA_WRITES" ? "on" : undefined), orgWritesEnabled: false,
    standIn: (_m, p) => ({ id: "stand-in", path: p }) }));
  const body = { name: "Show", api_key_echo: SECRET, nested: { note: `uses ${SECRET}` } };
  const r = await http.request("POST", "/v1/event/create", { body, op: "event.create" });
  assertEquals(calls.length, 0);
  assert(r.ok && r.planned && !r.live);
  assertEquals(r.body, { id: "stand-in", path: "/v1/event/create" });
  assertEquals(audit.steps.length, 1);
  const s = audit.steps[0];
  assertEquals([s.op, s.method, s.path, s.live], ["event.create", "POST", "/v1/event/create", false]);
  assertEquals((s.request?.body as any).name, "Show");
  assertEquals((s.request?.body as any).api_key_echo, "[redacted]");
  assertEquals((s.request?.body as any).nested.note, "uses [redacted]");
  assertEquals(s.request?.headers?.["x-luma-api-key"], "[redacted]");
  assert(!JSON.stringify(audit.steps).includes(SECRET), "no secret anywhere in the step");
  assert((s.response as any).reasons.some((x: string) => x.includes("switch is off")));
});

Deno.test("live: all three on, sent once (not retried), recorded live", async () => {
  const { f, calls } = fakeFetch([{ status: 503, body: { error: "busy" } }]);
  const audit = memoryAuditSink();
  const http = createGatedHttp(opts({ fetch: f, audit, env: (k) => (k === "EXOS_LUMA_WRITES" ? "on" : undefined), orgWritesEnabled: true }));
  assert(http.writesLive);
  const r = await http.request("POST", "/v1/event/create", { body: { name: "Show" } });
  assertEquals(calls.length, 1, "a POST is never re-sent");
  assertEquals(calls[0].headers["x-luma-api-key"], SECRET, "the credential goes in the header");
  assert(!calls[0].url.includes(SECRET));
  assert(r.live && !r.ok && r.status === 503);
  assertEquals(audit.steps[0].live, true);
  assertEquals(audit.steps[0].error, "HTTP_503");
});

Deno.test("an idempotent write rule may retry; a write off the allowlist is refused whatever the switches", async () => {
  const { f, calls } = fakeFetch([{ status: 502 }, { status: 200, body: { ok: true } }]);
  const audit = memoryAuditSink();
  const http = createGatedHttp(opts({ fetch: f, audit, env: () => "on", orgWritesEnabled: true }));
  const r = await http.request("PUT", "/v1/thing/abc", { body: { a: 1 } });
  assert(r.ok);
  assertEquals(calls.length, 2);
  await assertRejects(() => http.request("POST", "/v1/event/delete", { body: {} }), GatedHttpRefused, "not an allowed luma write");
  assertEquals(calls.length, 2, "nothing sent");
  assertEquals(audit.steps.at(-1)?.error, "NOT_ALLOWED");
});

Deno.test("reads: always sent, retried on 429 / 5xx / network under the shared policy, not on 4xx", async () => {
  const { f, calls } = fakeFetch([{ status: 429, headers: { "retry-after": "0" } }, new TypeError("reset"), { status: 200, body: { id: 7, items: [1] } }]);
  const audit = memoryAuditSink();
  const http = createGatedHttp(opts({ fetch: f, audit }));
  const r = await http.get("/v1/event/get?id=evt-1");
  assert(r.ok && r.live);
  assertEquals(calls.length, 3);
  assertEquals(audit.steps.length, 1, "one step per request, with its final answer");
  assertEquals((audit.steps[0].response as any).id, "7");
  assertEquals((audit.steps[0].response as any).keys, ["id", "items"]);

  const two = fakeFetch([{ status: 404 }]);
  const r2 = await createGatedHttp(opts({ fetch: two.f })).get("/v1/missing");
  assertEquals([r2.ok, r2.status, two.calls.length], [false, 404, 1]);

  const many = fakeFetch([{ status: 500 }]);
  const r3 = await createGatedHttp(opts({ fetch: many.f })).get("/v1/flaky");
  assertEquals(many.calls.length, 3, "bounded: the first try + maxRetries");
  assertEquals(r3.error, "HTTP_500");

  // A guard's refusal (not a TypeError) is final.
  const ssrf = fakeFetch([new Error("ssrf: blocked")]);
  const r4 = await createGatedHttp(opts({ fetch: ssrf.f })).get("/v1/x");
  assertEquals([r4.error, ssrf.calls.length], ["REFUSED", 1]);
});

Deno.test("credentials never in URLs", async () => {
  assertThrows(() => assertNoSecretsInUrl(`https://x.test/a?k=${SECRET}`, [SECRET]), GatedHttpRefused);
  assertThrows(() => assertNoSecretsInUrl(`https://x.test/${encodeURIComponent("a b" + SECRET)}`, ["a b" + SECRET]), GatedHttpRefused);
  assertThrows(() => assertNoSecretsInUrl("https://x.test/a?api_key=zzz", []), GatedHttpRefused);
  assertThrows(() => assertNoSecretsInUrl("https://x.test/a?access_token=zzz", []), GatedHttpRefused);
  assertNoSecretsInUrl("https://x.test/a?page=2&event_id=evt-1", [SECRET]);
  const { f, calls } = fakeFetch([{ status: 200 }]);
  const http = createGatedHttp(opts({ fetch: f }));
  await assertRejects(() => http.get(`/v1/event/get?id=${SECRET}`), GatedHttpRefused);
  await assertRejects(() => http.get("/v1/event/get?token=abc"), GatedHttpRefused);
  await assertRejects(() => http.get("/../admin"), GatedHttpRefused);
  await assertRejects(() => http.get("//evil.test/x"), GatedHttpRefused);
  assertEquals(calls.length, 0);
  assertThrows(() => createGatedHttp(opts({ base: "http://api.example.com" })), GatedHttpRefused, "https URL");
  assertThrows(() => createGatedHttp(opts({ base: `https://api.example.com/${SECRET}` })), GatedHttpRefused);
});

Deno.test("redaction: secret headers, secret-named keys and every secret value", () => {
  assertEquals(redactHeaders({ Authorization: "Bearer x", Accept: "json", "X-Other": `v ${SECRET}` }, [SECRET]),
    { Authorization: "[redacted]", Accept: "json", "X-Other": "[redacted]" });
  assertEquals(redact({ a: [SECRET, { password: "p", ok: 1 }], client_secret: "c", n: 2 }, [SECRET]),
    { a: ["[redacted]", { password: "[redacted]", ok: 1 }], client_secret: "[redacted]", n: 2 });
  assertEquals(redact("short", ["ab"]), "short", "secrets under 4 characters are not used as patterns");
});

Deno.test("asFetch: reads on the base only, through the gate", async () => {
  const { f, calls } = fakeFetch([{ status: 200, body: { name: "Org" }, headers: { "content-type": "application/json" } }]);
  const audit = memoryAuditSink();
  const http = createGatedHttp(opts({ fetch: f, audit, base: "https://pretix.example.com" }));
  const fx = http.asFetch();
  const r = await fx("https://pretix.example.com/api/v1/organizers/demo/", { headers: { Authorization: `Token ${SECRET}` } });
  assertEquals(await r.json(), { name: "Org" });
  assertEquals(calls[0].headers.authorization, `Token ${SECRET}`);
  assertEquals(audit.steps[0].request?.headers?.authorization, "[redacted]");
  await assertRejects(() => fx("https://elsewhere.example.com/x"), GatedHttpRefused);
  await assertRejects(() => fx("https://pretix.example.com.evil.test/x"), GatedHttpRefused);
  await assertRejects(() => fx("https://pretix.example.com/x", { method: "POST" }), GatedHttpRefused);
});

Deno.test("limits: block refuses with the reason, nothing planned or sent", async () => {
  const { f, calls } = fakeFetch([{ status: 200 }]);
  const audit = memoryAuditSink();
  const http = createGatedHttp(opts({ channel: "shotgun", fetch: f, audit, env: () => "on", orgWritesEnabled: true,
    writes: [{ method: "POST", path: /^\/events$/ }], limits: { facts: { free: true } } }));
  const r = await http.request("POST", "/events", { body: { name: "Free night" } });
  assertEquals([r.ok, r.error, calls.length], [false, "LIMIT_BLOCKED", 0]);
  assertEquals(r.limit?.blocks[0].ruleId, "shotgun_free_exclusive");
  assertEquals(audit.steps[0].warnings?.[0].action, "block");
  // A paid event goes.
  const r2 = await http.request("POST", "/events", { body: { name: "Paid" }, facts: { free: false } });
  assert(r2.ok && r2.live);
  // Resale: a $0 tier is never offered.
  const s = createGatedHttp(opts({ channel: "stubhub", writes: [{ method: "POST", path: /^\/listings$/ }] }));
  assertEquals((await s.request("POST", "/listings", { body: {}, facts: { priceCents: 0 } })).error, "LIMIT_BLOCKED");
  assert((await s.request("POST", "/listings", { body: {}, facts: { priceCents: 2500 } })).ok);
});

Deno.test("limits: cap refuses a send over what is left and counts live usage; warn goes through, recorded", async () => {
  const counter = memoryUsageCounter();
  const { f, calls } = fakeFetch([{ status: 200, body: { ok: true } }]);
  const audit = memoryAuditSink();
  const http = createGatedHttp(opts({ fetch: f, audit, env: () => "on", orgWritesEnabled: true,
    writes: [{ method: "POST", path: /^\/v1\/event\/add-guests$/ }], limits: { counter, scopeKey: "cal-1" } }));
  const send = (n: number) => http.request("POST", "/v1/event/add-guests", { body: { n }, usage: { metric: "sends", n } });
  assert((await send(10)).ok);
  const over = await send(6);
  assertEquals([over.ok, over.error, over.limit?.maxUnits], [false, "LIMIT_CAPPED", 5], "15 a week (the lower bound): 5 left");
  assertEquals(calls.length, 1, "the bulk send that would fail entirely is never sent");
  assert((await send(5)).ok);
  assertEquals((await counter.read({ platform: "luma", scopeKey: "cal-1", metric: "sends", windowSeconds: 7 * 86400 })).live, 15);
  // A refused send (4xx) gives its units back.
  const refusing = fakeFetch([{ status: 400, body: { error: "too many" } }]);
  const c2 = memoryUsageCounter();
  const h2 = createGatedHttp(opts({ fetch: refusing.f, env: () => "on", orgWritesEnabled: true,
    writes: [{ method: "POST", path: /^\/v1\/event\/add-guests$/ }], limits: { counter: c2, scopeKey: "cal-9" } }));
  await h2.request("POST", "/v1/event/add-guests", { body: {}, usage: { metric: "sends", n: 3 } });
  assertEquals((await c2.read({ platform: "luma", scopeKey: "cal-9", metric: "sends", windowSeconds: 0 })).live, 0);
  // Unlocked: 500.
  const h3 = createGatedHttp(opts({ fetch: fakeFetch([{ status: 200 }]).f, env: () => "on", orgWritesEnabled: true,
    writes: [{ method: "POST", path: /^\/v1\/event\/add-guests$/ }], limits: { counter: memoryUsageCounter(), facts: { accountLevel: "unlocked" } } }));
  assert((await h3.request("POST", "/v1/event/add-guests", { body: {}, usage: { metric: "sends", n: 200 } })).ok);
  // Warn (Eventbrite emails, 250 a day): over it still goes, with the warning recorded.
  const ec = memoryUsageCounter();
  const ea = memoryAuditSink();
  const eb = createGatedHttp(opts({ channel: "eventbrite", fetch: fakeFetch([{ status: 200 }]).f, audit: ea, env: () => "on", orgWritesEnabled: true,
    writes: [{ method: "POST", path: /^\/emails$/ }], limits: { counter: ec } }));
  await ec.reserve({ platform: "eventbrite", scopeKey: "", metric: "emails", n: 249, windowSeconds: 86400, threshold: null, live: true });
  const w = await eb.request("POST", "/emails", { body: {}, usage: { metric: "emails", n: 5 } });
  assert(w.ok && w.live);
  assertEquals(ea.steps[0].warnings?.[0].ruleId, "eventbrite_daily_emails");
  assertEquals((await ec.read({ platform: "eventbrite", scopeKey: "", metric: "emails", windowSeconds: 86400 })).live, 254);
});

Deno.test("dry-run usage is planned usage: apart from live, once per identical request", async () => {
  const counter = memoryUsageCounter();
  const http = createGatedHttp(opts({ writes: [{ method: "POST", path: /^\/v1\/event\/add-guests$/ }], limits: { counter, scopeKey: "cal-1" } }));
  const plan = (body: unknown, n: number) => http.request("POST", "/v1/event/add-guests", { body, usage: { metric: "sends", n } });
  assert((await plan({ g: [1, 2, 3] }, 3)).planned);
  await plan({ g: [1, 2, 3] }, 3);
  await plan({ g: [4] }, 1);
  const r = await counter.read({ platform: "luma", scopeKey: "cal-1", metric: "sends", windowSeconds: 7 * 86400 });
  assertEquals(r, { live: 0, planned: 4 });
  // A planned request over the cap is refused like a live one (the preview shows why).
  assertEquals((await plan({ g: "many" }, 16)).error, "LIMIT_CAPPED");
});

Deno.test("the database audit sink: writes always, reads only when asked, batched by 50", async () => {
  const calls: Array<{ fn: string; n: number }> = [];
  const rpc = async (fn: string, args: Record<string, unknown>) => {
    calls.push({ fn, n: (args.p_steps as unknown[]).length });
    return { data: (args.p_steps as unknown[]).length, error: null };
  };
  const sink = rpcAuditSink(rpc, "org-1");
  const http = createGatedHttp(opts({ audit: sink, fetch: fakeFetch([{ status: 200 }]).f }));
  await http.get("/v1/read");
  for (let i = 0; i < 51; i++) await http.request("POST", "/v1/event/create", { body: { i } });
  await sink.flush?.();
  assertEquals(calls.map((c) => c.n), [50, 1], "the read was not written");
  const reads = rpcAuditSink(rpc, "org-1", { reads: true });
  reads.record({ channel: "luma", op: "read", method: "GET", path: "/", live: true, at: new Date().toISOString() });
  await reads.flush?.();
  assertEquals(calls.at(-1)?.n, 1);
});
