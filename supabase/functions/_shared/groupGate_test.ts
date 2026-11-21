import { assertEquals } from "jsr:@std/assert@1";
import {
  type GateDeps, gateGroupClaim, GROUP_CLAIM_PER_NETWORK, GROUP_PAY_OFF, groupClaimBuckets, groupPayEnvOn, groupPayOffGate,
} from "./groupGate.ts";

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

Deno.test("a signed-in re-claim within 2 minutes gets the open page back, never a new one", async () => {
  const xg = { data: null, error: { code: "XG429", message: "your checkout for this seat is already open", details: "cs_test_open" } };
  const open = deps({ claim: xg, session: { status: "open", url: "https://checkout.stripe.com/c/pay/cs_test_open" } });
  assertEquals(await gateGroupClaim({ seat: SEAT, cover: null }, IP, open.d, { signedIn: true }), {
    status: 200, body: { url: "https://checkout.stripe.com/c/pay/cs_test_open", session_id: "cs_test_open", reused: true },
  });
  assertEquals(open.calls, ["rate group-claim", "rate group-seat", "claim", "stripe retrieve cs_test_open"]);
  const embed = deps({ claim: xg, session: { status: "open", client_secret: "cs_secret" } });
  const re = await gateGroupClaim({ seat: SEAT, cover: null }, IP, embed.d, { embedded: true, signedIn: true });
  assertEquals("status" in re && re.body.client_secret, "cs_secret");
  // Closed at Stripe, or no order attached yet (still being created): 429.
  const closed = deps({ claim: xg, session: { status: "expired", url: null } });
  assertEquals((await gateGroupClaim({ seat: SEAT, cover: null }, IP, closed.d, { signedIn: true }) as { status: number }).status, 429);
  const pending = deps({ claim: { data: null, error: { code: "XG429", message: "m", details: "" } } });
  assertEquals((await gateGroupClaim({ seat: SEAT, cover: null }, IP, pending.d) as { status: number }).status, 429);
  assertEquals(pending.calls.some((c) => c.startsWith("stripe")), false);
});

Deno.test("a guest re-claim never gets the open page back (security review)", async () => {
  const xg = { data: null, error: { code: "XG429", message: "your checkout for this seat is already open", details: "cs_test_open" } };
  const guest = deps({ claim: xg, session: { status: "open", url: "https://checkout.stripe.com/c/pay/cs_test_open", client_secret: "cs_secret" } });
  const r = await gateGroupClaim({ seat: SEAT, cover: null }, IP, guest.d);
  assertEquals("status" in r && r.status, 429);
  assertEquals("status" in r && (r.body.url ?? r.body.client_secret ?? null), null);
  assertEquals(guest.calls.some((c) => c.startsWith("stripe")), false, "no Stripe lookup for a guest");
  const embedGuest = deps({ claim: xg, session: { status: "open", client_secret: "cs_secret" } });
  const re = await gateGroupClaim({ seat: SEAT, cover: null }, IP, embedGuest.d, { embedded: true });
  assertEquals("status" in re && re.status, 429);
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

// ── Group pay v2 paused (operator 2026-11-09, mig 20261111120000) ──────────
const OFF = { status: 403 as const, body: { error: "Group pay isn't available", reason: "group_pay_off" } };

Deno.test("group pay off: EXOS_GROUP_PAY unset (or anything but on) refuses a seat or a cover with 403 group_pay_off", () => {
  for (const env of [undefined, null, "", "off", "true", "1", "yes", "onn"]) {
    assertEquals(groupPayEnvOn(env), false, `env ${env}`);
    assertEquals(groupPayOffGate({ group_seat: SEAT }, env), OFF, `seat, env ${env}`);
    assertEquals(groupPayOffGate({ group_cover: "c7e00000-0000-4000-8000-000000000001" }, env), OFF, `cover, env ${env}`);
    // A malformed or null group field is still a group body: refused, not read.
    assertEquals(groupPayOffGate({ group_seat: null }, env), OFF);
    assertEquals(groupPayOffGate({ group_seat: 42, group_cover: "x" }, env), OFF);
  }
  assertEquals(GROUP_PAY_OFF, OFF.body);
});

Deno.test("group pay off: an ordinary checkout body is never touched", () => {
  for (const env of [undefined, "on"]) {
    assertEquals(groupPayOffGate({}, env), null);
    assertEquals(groupPayOffGate({ event_id: "e", tier_id: "t", quantity: 2 } as Record<string, unknown>, env), null);
    assertEquals(groupPayOffGate(null, env), null);
  }
});

Deno.test("group pay off: EXOS_GROUP_PAY=on lets a group body through to the SQL switch", () => {
  for (const env of ["on", "ON", " on "]) {
    assertEquals(groupPayEnvOn(env), true);
    assertEquals(groupPayOffGate({ group_seat: SEAT }, env), null);
  }
});

Deno.test("group pay off: the SQL switch's XGOFF at the claim is a 403, never a Stripe call", async () => {
  const { d, calls } = deps({ claim: { data: null, error: { code: "XGOFF", message: "Group pay isn't available" } } });
  assertEquals(await gateGroupClaim({ seat: SEAT, cover: null }, IP, d, { signedIn: true }), OFF);
  assertEquals(calls.some((c) => c.startsWith("stripe")), false);
});

// exos-checkout itself (its handler can't be imported: Deno.serve at the top
// level): the env gate runs right after the body is parsed, and before the
// group context read, the rate gate, the claim and every Stripe call; the
// context's XGOFF is a 403 too. Needs --allow-read (CI's deno test step).
Deno.test("exos-checkout refuses a group body first, before any DB claim or Stripe call", async () => {
  const src = await Deno.readTextFile(new URL("../exos-checkout/index.ts", import.meta.url));
  const at = (needle: string) => {
    const i = src.indexOf(needle);
    if (i < 0) throw new Error(`exos-checkout no longer has: ${needle}`);
    return i;
  };
  const handler = at("Deno.serve(");
  const parsed = at("p = JSON.parse(raw)");
  const gate = at('groupPayOffGate(p, Deno.env.get("EXOS_GROUP_PAY"))');
  const refused = at("if (groupOff) return json(groupOff.body, groupOff.status);");
  assertEquals(handler < parsed && parsed < gate && gate < refused, true, "the gate right after the body is parsed");
  for (const later of ["await groupCheckout(p", "gateGroupClaim(group", 'sb.rpc("exos_group_claim"', 'sb.rpc("exos_rate_hit"',
                       'sb.rpc("exos_group_checkout_ctx"', "new Stripe("]) {
    // Every occurrence inside the handler comes after the gate (the helpers below it are called later).
    let i = src.indexOf(later, handler);
    assertEquals(i > 0, true, `exos-checkout no longer has: ${later}`);
    for (; i >= 0; i = src.indexOf(later, i + 1)) assertEquals(i > refused, true, `${later} before the group-pay-off gate`);
  }
  // Nothing between the handler's start and the gate reads the DB or calls Stripe.
  const head = src.slice(handler, refused);
  assertEquals(/\.rpc\(|\.from\(|new Stripe\(|stripe\./.test(head), false, "no DB or Stripe call before the gate");
  // The SQL switch: the context's XGOFF is the same 403.
  assertEquals(src.includes('if (error?.code === "XGOFF") return { error: { ...GROUP_PAY_OFF }, status: 403 };'), true);
});
