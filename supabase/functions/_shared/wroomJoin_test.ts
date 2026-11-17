// Deno tests for exos-wroom-join (_shared/wroomJoin.ts): Cloudflare's
// siteverify and the database are mocked.
import { assertEquals } from "jsr:@std/assert@1";
import { allowedHosts, handleWroomJoin, verifyAnswer, type WroomJoinDeps } from "./wroomJoin.ts";

const EV = "11111111-1111-4111-8111-111111111111";
const ENV: Record<string, string> = { TURNSTILE_SECRET_KEY: "sk", EXOS_APP_BASE_URL: "https://tickets.example.com/bridge" };

function deps(opts: { env?: Record<string, string>; verify?: unknown; gate?: unknown } = {}) {
  const calls: { fetch: string[]; rpc: { fn: string; args: Record<string, unknown> }[]; logs: string[] } = { fetch: [], rpc: [], logs: [] };
  const env = opts.env ?? ENV;
  const d: WroomJoinDeps = {
    env: (n) => env[n],
    fetch: (url, init) => {
      calls.fetch.push(`${url} ${String(init.body)}`);
      return Promise.resolve(new Response(JSON.stringify("verify" in opts ? opts.verify
        : { success: true, action: "wroom", hostname: "tickets.example.com" })));
    },
    rpc: (fn, args) => {
      calls.rpc.push({ fn, args });
      if (fn === "exos_wroom_verify_gate") return Promise.resolve({ data: "gate" in opts ? opts.gate : { ok: true, ip: "203.0.113.9" }, error: null });
      return Promise.resolve({ data: { state: "waiting", token: "a".repeat(64), position: 7 }, error: null });
    },
    log: (m) => calls.logs.push(m),
  };
  return { d, calls };
}
const post = (body: unknown, headers: Record<string, string> = {}) =>
  new Request("https://x.test/exos-wroom-join", {
    method: "POST", body: JSON.stringify(body),
    headers: { "content-type": "application/json", "cf-connecting-ip": "203.0.113.9", ...headers },
  });

Deno.test("a passed check joins through the verified SQL with the platform's address headers only", async () => {
  const { d, calls } = deps();
  const res = await handleWroomJoin(post({ event_id: EV, turnstile_token: "tok" },
    { "x-forwarded-for": "1.1.1.1, 203.0.113.9", "x-real-ip": "6.6.6.6" }), d);
  assertEquals(res.status, 200);
  assertEquals((await res.json()).state, "waiting");
  // The address (and its rate limit) come from SQL first, before the external call.
  assertEquals(calls.rpc[0], { fn: "exos_wroom_verify_gate",
    args: { p_headers: { "cf-connecting-ip": "203.0.113.9", "x-forwarded-for": "1.1.1.1, 203.0.113.9" } } });
  assertEquals(calls.fetch.length, 1);
  assertEquals(calls.fetch[0], "https://challenges.cloudflare.com/turnstile/v0/siteverify secret=sk&response=tok&remoteip=203.0.113.9");
  const j = calls.rpc.find((c) => c.fn === "exos_wroom_join_verified")!;
  assertEquals(j.args.p_headers, { "cf-connecting-ip": "203.0.113.9", "x-forwarded-for": "1.1.1.1, 203.0.113.9" });
  assertEquals(JSON.stringify(calls.rpc).includes("6.6.6.6"), false); // x-real-ip is never used
});

Deno.test("no client address (SQL says no_ip): 503, no siteverify, never a place in 'unknown'", async () => {
  const { d, calls } = deps({ gate: { ok: false, reason: "no_ip" } });
  const res = await handleWroomJoin(post({ event_id: EV, turnstile_token: "tok" }), d);
  assertEquals(res.status, 503);
  assertEquals(calls.fetch.length, 0);
  assertEquals(calls.rpc.some((c) => c.fn === "exos_wroom_join_verified"), false);
});

Deno.test("rate limited (SQL's IPv6 /64 bucket): 429 before siteverify", async () => {
  const { d, calls } = deps({ gate: { ok: false, reason: "busy" } });
  const res = await handleWroomJoin(post({ event_id: EV, turnstile_token: "tok" }, { "cf-connecting-ip": "2001:db8:1:2::77" }), d);
  assertEquals(res.status, 429);
  assertEquals(calls.fetch.length, 0);
  assertEquals((calls.rpc[0].args.p_headers as Record<string, string>)["cf-connecting-ip"], "2001:db8:1:2::77");
});

Deno.test("siteverify: failure, a missing or other action, another hostname never reach SQL", async () => {
  for (const verify of [{ success: false }, { success: true, hostname: "tickets.example.com" },
                        { success: true, action: "signup", hostname: "tickets.example.com" },
                        { success: true, action: "wroom", hostname: "evil.example.net" }, null]) {
    const { d, calls } = deps({ verify });
    const res = await handleWroomJoin(post({ event_id: EV, turnstile_token: "tok" }), d);
    assertEquals(res.status, 403, JSON.stringify(verify));
    assertEquals((await res.json()).reason, "challenge_failed");
    assertEquals(calls.rpc.some((c) => c.fn === "exos_wroom_join_verified"), false);
  }
});

Deno.test("hostnames come from the app URLs and redirect origins; none configured: accepted, logged once", () => {
  assertEquals(allowedHosts((n) => ({ EXOS_APP_BASE_URL: "https://a.example.com/bridge", EXOS_APP_URL: "https://b.example.com",
    EXOS_REDIRECT_ORIGINS: "https://c.example.com, https://a.example.com" } as Record<string, string>)[n]).sort(),
    ["a.example.com", "b.example.com", "c.example.com"]);
  const logs: string[] = [];
  assertEquals(verifyAnswer({ success: true, action: "wroom", hostname: "x.example" }, [], (m) => logs.push(m)), true);
  assertEquals(verifyAnswer({ success: true, action: "wroom", hostname: "y.example" }, [], (m) => logs.push(m)), true);
  assertEquals(logs.length, 1);
  assertEquals(verifyAnswer({ success: true, action: "wroom" }, ["a.example.com"]), false);
});

Deno.test("a missing token: 400, no siteverify, no join; no secret: 503 first; bad ids: 400", async () => {
  {
    const { d, calls } = deps();
    const res = await handleWroomJoin(post({ event_id: EV }), d);
    assertEquals(res.status, 400);
    assertEquals((await res.json()).reason, "challenge_required");
    assertEquals(calls.fetch.length, 0);
    assertEquals(calls.rpc.some((c) => c.fn === "exos_wroom_join_verified"), false);
  }
  {
    const { d, calls } = deps({ env: {} });
    const res = await handleWroomJoin(post({ event_id: EV, turnstile_token: "tok" }), d);
    assertEquals(res.status, 503);
    assertEquals(calls.fetch.length + calls.rpc.length, 0);
  }
  for (const body of [{ event_id: "AAAAAAAA-1111-4111-8111-111111111111", turnstile_token: "t" }, { event_id: `{${EV}}`, turnstile_token: "t" }]) {
    const { d, calls } = deps();
    assertEquals((await handleWroomJoin(post(body), d)).status, 400);
    assertEquals(calls.rpc.length, 0);
  }
  const { d } = deps();
  assertEquals((await handleWroomJoin(new Request("https://x.test/", { method: "GET" }), d)).status, 405);
  assertEquals((await handleWroomJoin(new Request("https://x.test/", { method: "OPTIONS" }), d)).status, 204);
});
