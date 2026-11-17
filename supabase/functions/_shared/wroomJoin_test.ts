// Deno tests for exos-wroom-join (_shared/wroomJoin.ts): Cloudflare's
// siteverify and the database are mocked.
import { assertEquals } from "jsr:@std/assert@1";
import { handleWroomJoin, type WroomJoinDeps } from "./wroomJoin.ts";

const EV = "11111111-1111-4111-8111-111111111111";

function deps(opts: { secret?: string; verify?: unknown; rateOk?: boolean } = {}) {
  const calls: { fetch: string[]; rpc: { fn: string; args: Record<string, unknown> }[] } = { fetch: [], rpc: [] };
  const d: WroomJoinDeps = {
    env: (n) => (n === "TURNSTILE_SECRET_KEY" ? opts.secret ?? "sk" : n === "EXOS_GUEST_IP_SALT" ? "salt" : undefined),
    fetch: (url, init) => {
      calls.fetch.push(`${url} ${String(init.body)}`);
      return Promise.resolve(new Response(JSON.stringify("verify" in opts ? opts.verify : { success: true, action: "wroom" })));
    },
    rpc: (fn, args) => {
      calls.rpc.push({ fn, args });
      if (fn === "exos_rate_hit") return Promise.resolve({ data: opts.rateOk ?? true, error: null });
      return Promise.resolve({ data: { state: "waiting", token: "a".repeat(64), position: 7 }, error: null });
    },
  };
  return { d, calls };
}
const post = (body: unknown, headers: Record<string, string> = {}) =>
  new Request("https://x.test/exos-wroom-join", {
    method: "POST", body: JSON.stringify(body),
    headers: { "content-type": "application/json", "cf-connecting-ip": "203.0.113.9", ...headers },
  });

Deno.test("a passed check joins through the verified SQL with the platform's address headers", async () => {
  const { d, calls } = deps();
  const res = await handleWroomJoin(post({ event_id: EV, turnstile_token: "tok" }, { "x-forwarded-for": "1.1.1.1, 203.0.113.9" }), d);
  assertEquals(res.status, 200);
  assertEquals((await res.json()).state, "waiting");
  assertEquals(calls.fetch.length, 1);
  assertEquals(calls.fetch[0].startsWith("https://challenges.cloudflare.com/turnstile/v0/siteverify secret=sk&response=tok&remoteip=203.0.113.9"), true);
  const j = calls.rpc.find((c) => c.fn === "exos_wroom_join_verified")!;
  assertEquals(j.args, { p_event_id: EV, p_token: null,
    p_headers: { "cf-connecting-ip": "203.0.113.9", "x-forwarded-for": "1.1.1.1, 203.0.113.9" } });
  // The rate limit came first, before the external call.
  assertEquals(calls.rpc[0].fn, "exos_rate_hit");
});

Deno.test("a failed check (or another widget's action) never reaches SQL", async () => {
  for (const verify of [{ success: false }, { success: true, action: "signup" }, null]) {
    const { d, calls } = deps({ verify });
    const res = await handleWroomJoin(post({ event_id: EV, turnstile_token: "tok" }), d);
    assertEquals(res.status, 403);
    assertEquals((await res.json()).reason, "challenge_failed");
    assertEquals(calls.rpc.some((c) => c.fn === "exos_wroom_join_verified"), false);
  }
});

Deno.test("a missing token: 400, no siteverify, no join", async () => {
  const { d, calls } = deps();
  const res = await handleWroomJoin(post({ event_id: EV }), d);
  assertEquals(res.status, 400);
  assertEquals((await res.json()).reason, "challenge_required");
  assertEquals(calls.fetch.length, 0);
  assertEquals(calls.rpc.some((c) => c.fn === "exos_wroom_join_verified"), false);
});

Deno.test("no secret: 503; rate limited: 429 before siteverify; bad ids: 400", async () => {
  {
    const { d, calls } = deps({ secret: "" });
    const res = await handleWroomJoin(post({ event_id: EV, turnstile_token: "tok" }), d);
    assertEquals(res.status, 503);
    assertEquals(calls.fetch.length, 0);
  }
  {
    const { d, calls } = deps({ rateOk: false });
    const res = await handleWroomJoin(post({ event_id: EV, turnstile_token: "tok" }), d);
    assertEquals(res.status, 429);
    assertEquals(calls.fetch.length, 0);
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
