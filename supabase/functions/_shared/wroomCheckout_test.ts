// Deno tests for exos-checkout's waiting-room attach / take-over and bind
// (_shared/wroomCheckout.ts): the database and Stripe are mocked.
import { assertEquals } from "jsr:@std/assert@1";
import { type AttachDeps, type StripeEnd, wroomAttach, wroomBindSession } from "./wroomCheckout.ts";

const ARGS = {
  p_event_id: "11111111-1111-4111-8111-111111111111", p_tier_id: "22222222-2222-4222-8222-222222222222",
  p_token: "a".repeat(64), p_buyer_uid: null, p_email: "buyer@x.com", p_attempt: "33333333-3333-4333-8333-333333333333",
};

function mock(answers: { data?: unknown; error?: { code?: string; message: string } }[], stripe: StripeEnd = "expired") {
  const log: string[] = [];
  let i = 0;
  const deps: AttachDeps = {
    rpc: (fn, args) => {
      log.push(`rpc ${fn} ${String(args.p_attempt)}`);
      const a = answers[Math.min(i++, answers.length - 1)];
      return Promise.resolve({ data: a.data ?? null, error: a.error ?? null });
    },
    expireStripe: (id) => {
      log.push(`expire ${id}`);
      return Promise.resolve(stripe);
    },
    markExpired: (id) => {
      log.push(`mark ${id}`);
      return Promise.resolve();
    },
    log: (m) => log.push(`log ${m}`),
  };
  return { deps, log };
}

Deno.test("attached, no turn needed, and the old boolean answer", async () => {
  assertEquals(await wroomAttach(mock([{ data: { attached: true } }]).deps, ARGS), { kind: "ok", attached: true });
  assertEquals(await wroomAttach(mock([{ data: { attached: false } }]).deps, ARGS), { kind: "ok", attached: false });
  assertEquals(await wroomAttach(mock([{ data: true }]).deps, ARGS), { kind: "ok", attached: true });
  assertEquals(await wroomAttach(mock([{ error: { code: "PGRST202", message: "x" } }]).deps, ARGS), { kind: "ok", attached: false });
});

Deno.test("refusals pass through; other errors are errors", async () => {
  for (const code of ["XWR01", "XWR02", "XWR03"] as const) {
    assertEquals(await wroomAttach(mock([{ error: { code, message: "x" } }]).deps, ARGS), { kind: "refused", code });
  }
  assertEquals((await wroomAttach(mock([{ error: { code: "57014", message: "timeout" } }]).deps, ARGS)).kind, "error");
});

Deno.test("the same buyer's open Stripe session: expired at Stripe, marked, attached again", async () => {
  const { deps, log } = mock([{ data: { takeover: "cs_test_old" } }, { data: { attached: true } }]);
  assertEquals(await wroomAttach(deps, ARGS), { kind: "ok", attached: true, tookOver: "cs_test_old" });
  assertEquals(log, [`rpc exos_wroom_attach ${ARGS.p_attempt}`, "expire cs_test_old", "mark cs_test_old",
    `rpc exos_wroom_attach ${ARGS.p_attempt}`]);
});

Deno.test("a session already complete, still open (paying) or unreachable keeps the turn: XWR02, nothing marked", async () => {
  for (const end of ["complete", "open", "unknown"] as StripeEnd[]) {
    const { deps, log } = mock([{ data: { takeover: "cs_test_old" } }], end);
    assertEquals(await wroomAttach(deps, ARGS), { kind: "refused", code: "XWR02" });
    assertEquals(log.some((l) => l.startsWith("mark")), false, end);
    assertEquals(log.filter((l) => l.startsWith("rpc")).length, 1, end);
  }
});

Deno.test("a second take-over in a row (another session meanwhile) is XWR02, not a loop", async () => {
  const { deps, log } = mock([{ data: { takeover: "cs_test_a" } }, { data: { takeover: "cs_test_b" } }]);
  assertEquals(await wroomAttach(deps, ARGS), { kind: "refused", code: "XWR02" });
  assertEquals(log.filter((l) => l.startsWith("expire")), ["expire cs_test_a"]);
});

Deno.test("a take-over id that isn't a Stripe session id is ignored", async () => {
  const { deps, log } = mock([{ data: { takeover: "pp_123", attached: false } }]);
  assertEquals(await wroomAttach(deps, ARGS), { kind: "ok", attached: false });
  assertEquals(log.some((l) => l.startsWith("expire")), false);
});

Deno.test("bind: true, false when not attached, one retry on an error, then false", async () => {
  const B = { p_event_id: ARGS.p_event_id, p_attempt: ARGS.p_attempt, p_session_id: "cs_x", p_buyer_uid: null, p_email: "b@x.com" };
  let n = 0;
  assertEquals(await wroomBindSession(() => Promise.resolve({ data: true, error: null }), B), true);
  assertEquals(await wroomBindSession(() => Promise.resolve({ data: false, error: null }), B), false);
  assertEquals(await wroomBindSession(() => Promise.resolve(++n === 1 ? { data: null, error: { message: "blip" } } : { data: true, error: null }), B), true);
  assertEquals(n, 2);
  n = 0;
  assertEquals(await wroomBindSession(() => { n++; return Promise.resolve({ data: null, error: { message: "down" } }); }, B), false);
  assertEquals(n, 2);
});
