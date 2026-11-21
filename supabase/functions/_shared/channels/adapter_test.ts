// The ChannelAdapter registry (adapter.ts, registry.ts), the one credential
// read (credentials.ts), the pretix proof read on the core, and the shared
// hashed identifiers (hashedIds.ts); channel core mig 20261121162400.
import { assert, assertEquals, assertThrows } from "jsr:@std/assert@1";
import { adapterProblems, adaptersWith, caps, CAP_METHOD, getAdapter, listAdapters, registerAdapter, type ChannelAdapter } from "./adapter.ts";
import { ADAPTERS, ensureRegistry } from "./registry.ts";
import { loadCredential, parseCredential } from "./credentials.ts";
import { createGatedHttp } from "./gatedHttp.ts";
import { memoryAuditSink } from "./audit.ts";
import { hashedAudience, hashedIdentifiers, sha256Hex } from "../hashedIds.ts";
import { normalizeEmail as convNormalize, sha256Hex as convSha } from "../conversions/common.ts";

Deno.test("registry: every channel listed once, every core adapter implements exactly what it claims", () => {
  ensureRegistry();
  ensureRegistry();
  assertEquals(listAdapters().length, ADAPTERS.length);
  assertEquals(new Set(ADAPTERS.map((a) => a.id)).size, ADAPTERS.length);
  for (const a of ADAPTERS) assertEquals(adapterProblems(a), [], a.id);
  assertEquals(getAdapter("pretix")?.status, "core");
  assert(typeof getAdapter("pretix")?.testCredential === "function");
  assertEquals(getAdapter("pretix")?.writes, [], "pretix is read only");
  assert(adaptersWith("list").some((a) => a.id === "stubhub"));
  assert(adaptersWith("deliver").every((a) => a.caps.deliver.length > 0));
  assertEquals(Object.keys(CAP_METHOD).length, 16, "every capability flag maps to a method");
});

Deno.test("an adapter that claims a capability without its method (or the reverse) is refused", () => {
  const bad: ChannelAdapter = { id: "x_bad", label: "X", status: "core", caps: caps({ publishPost: true }) };
  assert(adapterProblems(bad)[0].includes("claims publishPost"));
  assertThrows(() => registerAdapter(bad));
  const extra: ChannelAdapter = { id: "x_extra", label: "X", status: "core", caps: caps({}), checkin: async () => null };
  assert(adapterProblems(extra)[0].includes("doesn't claim checkin"));
  const legacy: ChannelAdapter = { id: "x_legacy", label: "X", status: "legacy", caps: caps({ list: true }) };
  assertEquals(adapterProblems(legacy), [], "a legacy entry states caps only");
});

Deno.test("credentials: one RPC, parsed; the secret only where it belongs", async () => {
  const seen: Array<[string, Record<string, unknown>]> = [];
  const rpc = async (fn: string, args: Record<string, unknown>) => {
    seen.push([fn, args]);
    return { data: { provider: "pretix", status: "connected", config: { organizer: "demo" }, secret: "tok", writes_enabled: false, source: "store" }, error: null };
  };
  const c = await loadCredential(rpc, "org-1", "pretix");
  assertEquals(seen, [["exos_integration_secret", { p_org_id: "org-1", p_provider: "pretix" }]]);
  assertEquals([c?.secret, c?.config.organizer, c?.writesEnabled, c?.source], ["tok", "demo", false, "store"]);
  assertEquals(parseCredential(null), null);
  assertEquals(parseCredential({ provider: "dice", secret: "", source: "legacy:exos_dice_connections" })?.secret, null);
});

Deno.test("pretix on the core: the credential test is one audited GET, the token in a header and redacted", async () => {
  ensureRegistry();
  const calls: Array<{ url: string; auth: string | null }> = [];
  const f = (async (input: RequestInfo | URL, init?: RequestInit) => {
    calls.push({ url: String(input), auth: new Headers(init?.headers).get("authorization") });
    return new Response(JSON.stringify({ name: { en: "Demo Org" } }), { status: 200, headers: { "content-type": "application/json" } });
  }) as typeof fetch;
  const audit = memoryAuditSink();
  const a = getAdapter("pretix")!;
  const creds = { provider: "pretix", status: "connected", config: { base_url: "https://pretix.example.com", organizer: "demo" },
                  secret: "pretix-SECRET-token", writesEnabled: false, accountName: null, source: "store" };
  const http = createGatedHttp({ channel: "pretix", base: "https://pretix.example.com", fetch: f, env: () => "on",
                                 orgWritesEnabled: true, writes: a.writes ?? [], secrets: [creds.secret], audit });
  const r = await a.testCredential!({ orgId: "org-1", creds, http, audit });
  assertEquals(r, { ok: true, name: "Demo Org" });
  assertEquals(calls, [{ url: "https://pretix.example.com/api/v1/organizers/demo/", auth: "Token pretix-SECRET-token" }]);
  assertEquals(audit.steps.length, 1);
  assertEquals([audit.steps[0].method, audit.steps[0].live, audit.steps[0].path], ["GET", true, "/api/v1/organizers/demo/"]);
  assert(!JSON.stringify(audit.steps).includes("pretix-SECRET-token"));
  const none = await a.testCredential!({ orgId: "org-1", creds: { ...creds, secret: null }, http, audit });
  assertEquals(none.ok, false);
});

Deno.test("hashed identifiers: one builder, the same hashes the conversions use", async () => {
  const h = await hashedIdentifiers({ email: "  J.O.E@Gmail.com ", phone: "(212) 555-0100" });
  assertEquals(h.em, await sha256Hex("j.o.e@gmail.com"));
  assertEquals(h.em_google, await sha256Hex("joe@gmail.com"));
  assertEquals(h.ph, await sha256Hex("+12125550100"));
  assertEquals(h.ph_digits, await sha256Hex("12125550100"));
  assert(!JSON.stringify(h).includes("gmail"), "nothing raw comes back");
  assertEquals(await hashedIdentifiers({ email: "nope", phone: "12" }), {});
  assertEquals(convNormalize, (await import("../hashedIds.ts")).normalizeEmail, "conversions re-export the shared one");
  assertEquals(await convSha("abc"), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad");
  const aud = await hashedAudience([{ email: "a@x.com" }, { email: " A@x.com" }, { phone: "2125550100" }, {}, { email: "b@x.com" }]);
  assertEquals(aud.length, 3, "deduped by person, empty dropped");
});
