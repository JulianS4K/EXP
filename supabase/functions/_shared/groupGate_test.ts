import { assertEquals } from "jsr:@std/assert@1";
import { type GateDeps, gateGroupClaim, GROUP_CLAIM_PER_NETWORK, groupClaimBuckets } from "./groupGate.ts";

const SEAT = "ab".repeat(16);
const IP = "f".repeat(64);

// Records every call in order; `limits` says which buckets are over.
function deps(opts: {
  over?: string[];
  claim?: { data: unknown; error: { code?: string; message?: string; details?: string | null } | null };
  session?: { status?: string; url?: string | null; client_secret?: string | null } | null;
  rateThrows?: boolean;
} = {}) {
  const calls: string[] = [];
  const d: GateDeps = {
    rateHit(bucket) {
      calls.push(`rate ${bucket.split(":")[0]}`);
      if (opts.rateThrows) return Promise.reject(new Error("db"));
      return Promise.resolve(!(opts.over ?? []).some((p) => bucket.startsWith(p)));
    },
    claim() {
      calls.push("claim");
      return Promise.resolve(opts.claim ?? { data: "hold-1", error: null });
    },
    openSession(id) {
      calls.push(`stripe retrieve ${id}`);
      return Promise.resolve(opts.session ?? null);
    },
    reason: (code) => `r:${code}`,
  };
  return { d, calls };
}

Deno.test("the rate limits run before the claim, and the claim before any Stripe call", async () => {
  const { d, calls } = deps();
  assertEquals(await gateGroupClaim({ seat: SEAT, cover: null }, IP, d), { hold: "hold-1" });
  assertEquals(calls, ["rate group-claim", "rate group-seat", "claim"]);
});

Deno.test("over a limit: 429, no claim, no Stripe", async () => {
  for (const over of ["group-claim", "group-seat"]) {
    const { d, calls } = deps({ over: [over] });
    const r = await gateGroupClaim({ seat: SEAT, cover: null }, IP, d);
    assertEquals("status" in r && r.status, 429);
    assertEquals(calls.includes("claim"), false);
    assertEquals(calls.some((c) => c.startsWith("stripe")), false);
  }
  const { d, calls } = deps({ rateThrows: true });
  const r = await gateGroupClaim({ seat: SEAT, cover: null }, IP, d);
  assertEquals("status" in r && r.status, 503, "fails closed");
  assertEquals(calls, ["rate group-claim"]);
});

Deno.test("a re-claim within 2 minutes gets the open page back, never a new one", async () => {
  const xg = { data: null, error: { code: "XG429", message: "your checkout for this seat is already open", details: "cs_test_open" } };
  const open = deps({ claim: xg, session: { status: "open", url: "https://checkout.stripe.com/c/pay/cs_test_open" } });
  assertEquals(await gateGroupClaim({ seat: SEAT, cover: null }, IP, open.d), {
    status: 200, body: { url: "https://checkout.stripe.com/c/pay/cs_test_open", session_id: "cs_test_open", reused: true },
  });
  assertEquals(open.calls, ["rate group-claim", "rate group-seat", "claim", "stripe retrieve cs_test_open"]);
  const embed = deps({ claim: xg, session: { status: "open", client_secret: "cs_secret" } });
  const re = await gateGroupClaim({ seat: SEAT, cover: null }, IP, embed.d, { embedded: true });
  assertEquals("status" in re && re.body.client_secret, "cs_secret");
  // Closed at Stripe, or no order attached yet (still being created): 429.
  const closed = deps({ claim: xg, session: { status: "expired", url: null } });
  assertEquals((await gateGroupClaim({ seat: SEAT, cover: null }, IP, closed.d) as { status: number }).status, 429);
  const pending = deps({ claim: { data: null, error: { code: "XG429", message: "m", details: "" } } });
  assertEquals((await gateGroupClaim({ seat: SEAT, cover: null }, IP, pending.d) as { status: number }).status, 429);
  assertEquals(pending.calls.some((c) => c.startsWith("stripe")), false);
});

Deno.test("other claim errors keep exos-checkout's reasons", async () => {
  const { d } = deps({ claim: { data: null, error: { code: "XG409", message: "seat already taken" } } });
  assertEquals(await gateGroupClaim({ seat: SEAT, cover: null }, IP, d), {
    status: 409, body: { error: "seat already taken", reason: "r:XG409" },
  });
});

Deno.test("buckets: per seat and network, per seat; within exos_rate_hit's 200 characters", () => {
  const b = groupClaimBuckets({ seat: SEAT, cover: null }, IP);
  assertEquals(b.map((x) => x.bucket), [`group-claim:${SEAT}:${IP}`, `group-seat:${SEAT}`]);
  assertEquals(b[0].limit, GROUP_CLAIM_PER_NETWORK);
  const c = groupClaimBuckets({ seat: null, cover: "c7e00000-0000-4000-8000-000000000001" }, "x".repeat(500));
  assertEquals(c.every((x) => x.bucket.length <= 200), true);
});
