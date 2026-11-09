import { assertEquals } from "jsr:@std/assert@1";
import { expireGroupPages, groupPageReason, type PageDb, type PageStripe } from "./groupPages.ts";

// A Stripe mock: each session's state; expire() works only on an open one,
// like Stripe's POST /v1/checkout/sessions/:id/expire.
function mockStripe(states: Record<string, string>, opts: { failRetrieve?: boolean } = {}) {
  const calls: string[] = [];
  const stripe: PageStripe = {
    checkout: {
      sessions: {
        expire(id: string) {
          calls.push(`expire ${id}`);
          if (states[id] !== "open") return Promise.reject(new Error("This Checkout Session is not in an expirable state"));
          states[id] = "expired";
          return Promise.resolve({ id, status: "expired" });
        },
        retrieve(id: string) {
          calls.push(`retrieve ${id}`);
          if (opts.failRetrieve) return Promise.reject(new Error("network"));
          return Promise.resolve({ id, status: states[id] ?? null });
        },
      },
    },
  };
  return { stripe, calls, states };
}

function mockDb(due: { session_id: string; why: string }[], opts: { failDue?: boolean } = {}) {
  const marked: string[] = [];
  const db: PageDb = {
    due(limit) {
      if (opts.failDue) return Promise.reject(new Error("db down"));
      return Promise.resolve(due.slice(0, limit));
    },
    markExpired(id, why) {
      marked.push(`${id}:${why}`);
      return Promise.resolve(true);
    },
  };
  return { db, marked };
}

Deno.test("expires each due open page at Stripe, then marks the order", async () => {
  const s = mockStripe({ cs_a: "open", cs_b: "open" });
  const d = mockDb([{ session_id: "cs_a", why: "deadline" }, { session_id: "cs_b", why: "seat_gone" }]);
  const out = await expireGroupPages(s.stripe, d.db);
  assertEquals(out, { due: 2, expired: 2, already_closed: 0, paid: 0, errors: 0 });
  assertEquals(s.calls, ["expire cs_a", "expire cs_b"]);
  assertEquals(d.marked, ["cs_a:deadline", "cs_b:seat_gone"]);
});

Deno.test("a page paid just before is left to the webhook and the auto-refund", async () => {
  const s = mockStripe({ cs_paid: "complete" });
  const d = mockDb([{ session_id: "cs_paid", why: "deadline" }]);
  const out = await expireGroupPages(s.stripe, d.db);
  assertEquals(out, { due: 1, expired: 0, already_closed: 0, paid: 1, errors: 0 });
  assertEquals(s.calls, ["expire cs_paid", "retrieve cs_paid"]);
  assertEquals(d.marked, [], "never marked: the payment's own path decides");
});

Deno.test("a page Stripe already closed is marked; errors are counted, never thrown", async () => {
  const s = mockStripe({ cs_gone: "expired", cs_odd: "open_weird" });
  const d = mockDb([{ session_id: "cs_gone", why: "cancelled" }, { session_id: "cs_odd", why: "deadline" }]);
  const logs: string[] = [];
  const out = await expireGroupPages(s.stripe, d.db, { log: (m) => logs.push(m) });
  assertEquals(out, { due: 2, expired: 0, already_closed: 1, paid: 0, errors: 1 });
  assertEquals(d.marked, ["cs_gone:cancelled"]);
  assertEquals(logs.length, 1);
});

Deno.test("PayPal orders and odd ids never reach Stripe; the batch limit holds", async () => {
  const s = mockStripe({ cs_1: "open", cs_2: "open", cs_3: "open" });
  const d = mockDb([
    { session_id: "pp_1", why: "deadline" }, { session_id: "cs_1", why: "deadline" },
    { session_id: "cs_bad id", why: "deadline" }, { session_id: "cs_2", why: "deadline" }, { session_id: "cs_3", why: "deadline" },
  ]);
  const out = await expireGroupPages(s.stripe, d.db, { limit: 4 });
  assertEquals(out.due, 2);
  assertEquals(s.calls, ["expire cs_1", "expire cs_2"]);
});

Deno.test("a failed due list or retrieve is an error count, not a crash", async () => {
  const bad = await expireGroupPages(mockStripe({}).stripe, mockDb([], { failDue: true }).db);
  assertEquals(bad, { due: 0, expired: 0, already_closed: 0, paid: 0, errors: 1 });
  const s = mockStripe({ cs_x: "complete" }, { failRetrieve: true });
  const out = await expireGroupPages(s.stripe, mockDb([{ session_id: "cs_x", why: "deadline" }]).db);
  assertEquals(out.errors, 1);
});

Deno.test("the recorded reason", () => {
  assertEquals(groupPageReason("deadline"), "group seat no longer held (deadline): checkout page closed");
  assertEquals(groupPageReason("<script>"), "group seat no longer held (seat_gone): checkout page closed");
});
