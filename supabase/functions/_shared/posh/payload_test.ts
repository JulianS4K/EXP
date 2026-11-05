// The Posh payload parser (payload.ts). Posh's format isn't documented, so
// these shapes are GUESSES at what a webhook sender like Posh plausibly sends
// (flat snake_case, nested camelCase, a data envelope, a pending order, a
// form post, a body with almost nothing). They pin the parser's behavior,
// not Posh's.
import { assertEquals } from "jsr:@std/assert@1";
import { detectKind, extractOrder, parseBody, redact, route, sha256Hex } from "./payload.ts";

Deno.test("flat snake_case order", () => {
  const b = parseBody(JSON.stringify({
    type: "order_created", order_id: "64f1c2aa9b", event_id: "651a00ff", event_name: "Pool Party",
    event_url: "https://posh.vip/e/pool-party-2026", first_name: "Ada", last_name: "Lovelace", email: "ada@x.com",
    phone: "+15551234567", quantity: 2, total: "$50.00", currency: "USD", created_at: "2026-10-29T18:00:00Z",
    tickets: [{ ticket_name: "GA", code: "QR-1" }, { ticket_name: "GA", code: "QR-2" }],
  }), "application/json")!;
  assertEquals(detectKind(b), "order_created");
  assertEquals(extractOrder(b), {
    order_id: "64f1c2aa9b", event_id: "651a00ff", event_slug: "pool-party-2026", event_name: "Pool Party",
    quantity: 2, buyer_name: "Ada Lovelace", buyer_email: "ada@x.com", ticket_label: "GA", codes: ["QR-1", "QR-2"],
    total: 50, currency: "usd", created_at: "2026-10-29T18:00:00.000Z",
  });
});

Deno.test("nested camelCase in a data envelope", () => {
  const b = parseBody(JSON.stringify({
    event: "Order Created",
    data: {
      order: {
        _id: "ord_77", totalCents: 4500, createdAt: 1761760800,
        account: { firstName: "Bo", lastName: "D", email: "BO@x.com", phone: "555" },
        items: [{ ticketType: { name: "VIP" }, quantity: 3, barcodes: ["A1", "A2", "A3"] }],
      },
      event: { id: "ev9", slug: "drag-brunch", name: "Drag Brunch" },
    },
  }), "application/json; charset=utf-8")!;
  assertEquals(detectKind(b), "order_created");
  const o = extractOrder(b);
  assertEquals(o.order_id, "ord_77");
  assertEquals([o.event_id, o.event_slug, o.event_name], ["ev9", "drag-brunch", "Drag Brunch"]);
  assertEquals([o.buyer_name, o.buyer_email], ["Bo D", "BO@x.com"]);
  assertEquals([o.quantity, o.ticket_label, o.codes, o.total], [3, "VIP", ["A1", "A2", "A3"], 45]);
  assertEquals(o.created_at, "2025-10-29T18:00:00.000Z");
});

Deno.test("pending: by type, by status, by flag, by URL hint", () => {
  assertEquals(detectKind({ type: "pending_order.created", order: { id: "1" } }), "pending_order_created");
  assertEquals(detectKind({ webhookType: "Pending Order Created" }), "pending_order_created");
  assertEquals(detectKind({ order: { id: "1", status: "pending_approval" } }), "pending_order_created");
  assertEquals(detectKind({ order: { id: "1", requiresApproval: true } }), "pending_order_created");
  assertEquals(detectKind({ order: { id: "1", requiresApproval: true, approved: true } }), "order_created");
  assertEquals(detectKind({ order_id: "1" }, "pending"), "pending_order_created");
  // The payload's own word beats the hint.
  assertEquals(detectKind({ type: "order.created" }, "pending"), "order_created");
  // An event literally named "Pending Party" isn't a pending order.
  assertEquals(detectKind({ event: "Pending Party", order_id: "1" }), "order_created");
  assertEquals(detectKind({ event: "Pending Order Created" }), "pending_order_created");
});

Deno.test("almost nothing: no id, no event, no tickets", () => {
  const b = parseBody('{"name":"Cy","email":"not-an-email"}', null)!;
  assertEquals(detectKind(b), "order_created");
  assertEquals(extractOrder(b), { codes: [] });
});

Deno.test("a bare id at the top level is not an order id; an order object's is", () => {
  assertEquals(extractOrder({ id: "evt_delivery_1", event_name: "X" }).order_id, undefined);
  assertEquals(extractOrder({ id: "evt_delivery_1", order: { id: "o-5" } }).order_id, "o-5");
  assertEquals(extractOrder({ order_id: "bad id with spaces" }).order_id, undefined);
});

Deno.test("form post with a JSON payload field, and plain fields", () => {
  const inner = JSON.stringify({ orderNumber: "P-100", eventSlug: "derby-night", ticketCount: "4", buyerEmail: "z@x.com" });
  const b = parseBody(new URLSearchParams({ payload: inner }).toString(), "application/x-www-form-urlencoded")!;
  assertEquals(extractOrder(b), { order_id: "P-100", event_slug: "derby-night", quantity: 4, buyer_email: "z@x.com", codes: [] });
  const f = parseBody("order_id=9&event_name=Comedy+Hour&quantity=1", "application/x-www-form-urlencoded")!;
  assertEquals(extractOrder(f), { order_id: "9", event_name: "Comedy Hour", quantity: 1, codes: [] });
  assertEquals(parseBody("not json", "application/json"), null);
  assertEquals(parseBody("[]", null), null);
});

Deno.test("quantity: explicit, from items, from codes; clamped", () => {
  assertEquals(extractOrder({ order_id: "1", tickets: [{ name: "GA", quantity: 2 }, { name: "VIP" }] }).quantity, 3);
  assertEquals(extractOrder({ order_id: "1", ticket_codes: ["a", "b", "a"] }).codes, ["a", "b"]);
  assertEquals(extractOrder({ order_id: "1", ticket_codes: ["a", "b"] }).quantity, 2);
  assertEquals(extractOrder({ order_id: "1", quantity: 500 }).quantity, undefined);
  assertEquals(extractOrder({ order_id: "1", tickets: [{ name: "GA" }, { name: "VIP" }] }).ticket_label, "GA, VIP");
});

Deno.test("redact keeps name + email, drops phone / address / answers", () => {
  const r = redact({
    email: "a@x.com", name: "Ada", phone: "555", order: { billing_address: { street: "1 Main" }, email_address: "a@x.com",
      answers: [{ q: "Instagram?", a: "@ada" }], tickets: [{ code: "Q1" }] },
  });
  assertEquals(r, {
    email: "a@x.com", name: "Ada", phone: "[removed]",
    order: { billing_address: "[removed]", email_address: "a@x.com", answers: "[removed]", tickets: [{ code: "Q1" }] },
  });
});

Deno.test("routes", () => {
  const t = "a".repeat(64);
  assertEquals(route(`/functions/v1/exos-posh-webhook/${t}`), { kind: "hook", token: t, hint: null });
  assertEquals(route(`/exos-posh-webhook/${t}/pending`), { kind: "hook", token: t, hint: "pending" });
  assertEquals(route(`/exos-posh-webhook/${t}/other`), null);
  assertEquals(route(`/exos-posh-webhook/${"a".repeat(63)}`), null);
  assertEquals(route(`/exos-posh-webhook/replay/0b1c2d3e-0000-4000-8000-000000000001`),
    { kind: "replay", logId: "0b1c2d3e-0000-4000-8000-000000000001" });
  assertEquals(route(`/exos-posh-webhook`), null);
});

Deno.test("sha256Hex matches Postgres encode(sha256(...), 'hex')", async () => {
  assertEquals(await sha256Hex("abc"), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad");
});
