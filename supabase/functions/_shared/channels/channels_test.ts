import { assertEquals, assertRejects } from "jsr:@std/assert@1";
import { contentHash, makeIo, mirrorEvent, type StepRecord, textToHtml, utc, writesLive } from "./model.ts";
import { EB_WRITES, ebClassBody, ebStandIn, syncEventbrite } from "./eventbrite.ts";
import { assertCapacityOnly, planCapacity } from "../eventbrite/writer.ts";
import { capacityUpdate, LUMA_WRITES, lumaStandIn, lumaTicketCounts, lumaTicketNames, syncLuma } from "./luma.ts";

const PAYLOAD = {
  event: {
    id: "e1", name: "Mirror Night", status: "published", starts_at: "2026-11-01T23:00:00.000Z", ends_at: null,
    timezone: "America/New_York", currency: "usd", venue_name: "Blue Room",
    venue_address: { street: "1 Main St", city: "Brooklyn", region: "NY", postal: "11211", country: "US" },
    description: "Doors at 7.\n\nNo re-entry.", purchase_limits: { maxPerOrder: 4 },
  },
  tiers: [
    { id: "t1", name: "General Admission", price: 25, capacity: 100, free_now: 100, visibility: "public" },
    { id: "t2", name: "Guest list", price: 0, capacity: 20, free_now: 2, visibility: "hidden" },
    { id: "t3", name: "Table", price: 500, capacity: 4, free_now: 4, is_table: true },
  ],
  mirror: { mode: "create", external_id: null, external_meta: {}, last_hash: null, status: "pending" },
  maps: [],
};

function fakeFetch(routes: Record<string, (body: any) => any>, calls: { method: string; url: string; body: any }[]) {
  return ((url: string, init?: RequestInit) => {
    const body = init?.body ? JSON.parse(String(init.body)) : undefined;
    calls.push({ method: init?.method ?? "GET", url, body });
    const path = new URL(url).pathname + (new URL(url).search ? "?" : "");
    const key = Object.keys(routes).find((k) => (init?.method ?? "GET") + " " + path.replace(/\?$/, "") === k || url.includes(k));
    const out = key ? routes[key](body) : { error: "NOT_FOUND" };
    return Promise.resolve(new Response(JSON.stringify(out), { status: key ? 200 : 404, headers: { "content-type": "application/json" } }));
  }) as typeof fetch;
}

Deno.test("model: event and ticket types as the mirrors show them", async () => {
  const ev = mirrorEvent(PAYLOAD)!;
  assertEquals(ev.startUtc, "2026-11-01T23:00:00Z");
  assertEquals(ev.endUtc, "2026-11-02T02:00:00Z");     // no end: 3 hours
  assertEquals(ev.currency, "USD");
  assertEquals(ev.pack, 4);
  assertEquals(ev.venueQuery, "Blue Room, 1 Main St, Brooklyn, NY 11211, US");
  assertEquals(ev.tiers.map((t) => [t.priceCents, t.free, t.hidden, t.skip !== null]), [[2500, false, false, false], [0, true, true, false], [50000, false, false, true]]);
  assertEquals(mirrorEvent({ event: { id: "x", name: "", starts_at: "2026-01-01" } }), null);
  assertEquals(utc("nope"), "");
  assertEquals(textToHtml("a<b\nc\n\nd"), "<p>a&lt;b<br>c</p><p>d</p>");
  const h1 = await contentHash(ev);
  assertEquals(h1, await contentHash(mirrorEvent(PAYLOAD)!));
  const moved = mirrorEvent({ ...PAYLOAD, event: { ...PAYLOAD.event, name: "Moved" } })!;
  assertEquals(h1 === await contentHash(moved), false);
  // Sales alone don't change the hash.
  const sold = mirrorEvent({ ...PAYLOAD, tiers: [{ ...PAYLOAD.tiers[0], free_now: 10 }, PAYLOAD.tiers[1], PAYLOAD.tiers[2]] })!;
  assertEquals(h1, await contentHash(sold));
  assertEquals(writesLive(true, "on"), true);
  assertEquals(writesLive(true, "yes"), false);
  assertEquals(writesLive(false, "on"), false);
});

Deno.test("io: a dry run sends no POST; a POST outside the allowlist throws", async () => {
  const calls: any[] = [];
  const steps: StepRecord[] = [];
  const io = makeIo({ fetch: fakeFetch({}, calls), base: "https://x.test", headers: {}, live: false, allowed: [/^\/ok$/], steps, standIn: () => ({ id: "s" }) });
  const r = await io.req("POST", "/ok", { a: 1 });
  assertEquals(r.body, { id: "s" });
  assertEquals(calls.length, 0);
  assertEquals(steps[0].op, "planned");
  await assertRejects(() => io.req("POST", "/v1/events/cancel", {}), Error, "not an allowed write");
  assertEquals((await io.req("GET", "/../x")).error, "bad path");
});

Deno.test("eventbrite: creates venue, event, classes and publishes; classes Exos skips stay off", async () => {
  const calls: { method: string; url: string; body: any }[] = [];
  const f = fakeFetch({
    "GET /v3/users/me/organizations/": () => ({ organizations: [{ id: "42" }] }),
    "POST /v3/organizations/42/venues/": () => ({ id: "99" }),
    "POST /v3/organizations/42/events/": () => ({ id: "777", url: "https://www.eventbrite.com/e/777" }),
    "GET /v3/events/777/ticket_classes/": () => ({ ticket_classes: [] }),
    "POST /v3/events/777/ticket_classes/": (b) => ({ id: b.ticket_class.name === "General Admission" ? "5001" : "5002" }),
    "POST /v3/events/777/publish/": () => ({ published: true }),
  }, calls);
  const ev = mirrorEvent(PAYLOAD)!;
  const steps: StepRecord[] = [];
  const io = makeIo({ fetch: f, base: "https://www.eventbriteapi.com/v3", headers: { Authorization: "Bearer t" }, live: true, allowed: EB_WRITES, steps, standIn: ebStandIn });
  const r = await syncEventbrite(io, ev, PAYLOAD, steps, "h1");
  assertEquals(r.state, "synced");
  assertEquals(r.external_id, "777");
  assertEquals(r.external_meta, { organization_id: "42", venue_id: "99", venue_key: ev.venueQuery, published: true });
  assertEquals(r.tickets, [{ tier_id: "t1", external_ticket_id: "5001", name: "General Admission", created: true },
                           { tier_id: "t2", external_ticket_id: "5002", name: "Guest list", created: true }]);
  const ga = calls.find((c) => c.body?.ticket_class?.name === "General Admission")!.body.ticket_class;
  assertEquals(ga, { name: "General Admission", hidden: false, free: false, quantity_total: 96, cost: "USD,2500" });
  const gl = calls.find((c) => c.body?.ticket_class?.name === "Guest list")!.body.ticket_class;
  assertEquals([gl.free, gl.hidden, gl.quantity_total, gl.cost], [true, true, 1, undefined]);
  const evBody = calls.find((c) => c.url.endsWith("/organizations/42/events/"))!.body.event;
  assertEquals([evBody.start.utc, evBody.venue_id, evBody.currency], ["2026-11-01T23:00:00Z", "99", "USD"]);
  for (const c of calls.filter((x) => x.method === "POST")) assertEquals(EB_WRITES.some((re) => re.test(new URL(c.url).pathname.replace(/^\/v3/, ""))), true);
});

Deno.test("eventbrite: an unchanged mapped event sends nothing; an update leaves capacity alone; a dry run plans", async () => {
  const calls: any[] = [];
  const f = fakeFetch({ "POST /v3/events/777/": () => ({}), "POST /v3/events/777/ticket_classes/5001/": () => ({}),
                       "POST /v3/events/777/ticket_classes/5002/": () => ({}) }, calls);
  const ev = mirrorEvent(PAYLOAD)!;
  const hash = await contentHash(ev);
  const linked = { ...PAYLOAD, mirror: { mode: "create", external_id: "777", external_meta: { organization_id: "42", venue_id: "99", venue_key: ev.venueQuery, published: true }, last_hash: "old" },
                   maps: [{ tier_id: "t1", external_ticket_id: "5001" }, { tier_id: "t2", external_ticket_id: "5002" }] };
  const steps: StepRecord[] = [];
  const io = makeIo({ fetch: f, base: "https://www.eventbriteapi.com/v3", headers: {}, live: true, allowed: EB_WRITES, steps, standIn: ebStandIn });
  const r = await syncEventbrite(io, ev, linked, steps, hash);
  assertEquals(r.state, "synced");
  const upd = calls.find((c) => c.url.endsWith("/ticket_classes/5001/"))!.body.ticket_class;
  assertEquals("quantity_total" in upd || "capacity" in upd, false);
  assertEquals(ebClassBody(ev.tiers[0], ev, false), { ticket_class: { name: "General Admission", hidden: false, cost: "USD,2500" } });

  const calls2: any[] = [];
  const steps2: StepRecord[] = [];
  const dry = makeIo({ fetch: fakeFetch({ "GET /v3/users/me/organizations/": () => ({ organizations: [{ id: "42" }] }) }, calls2),
                       base: "https://www.eventbriteapi.com/v3", headers: {}, live: false, allowed: EB_WRITES, steps: steps2, standIn: ebStandIn });
  const d = await syncEventbrite(dry, ev, PAYLOAD, steps2, hash);
  assertEquals(d.state, "dry_run");
  assertEquals(d.external_id, undefined);
  assertEquals(calls2.filter((c) => c.method === "POST").length, 0);
  assertEquals(d.plan!.steps.map((s) => s.path), ["/organizations/42/venues/", "/organizations/42/events/", "/events/0/ticket_classes/", "/events/0/ticket_classes/", "/events/0/publish/"]);
});

Deno.test("eventbrite: cancel; refusal shown to the organizer", async () => {
  const ev = mirrorEvent({ ...PAYLOAD, event: { ...PAYLOAD.event, status: "cancelled" } })!;
  const p = { ...PAYLOAD, mirror: { external_id: "777", external_meta: { organization_id: "42" } } };
  const calls: any[] = [];
  const steps: StepRecord[] = [];
  const io = makeIo({ fetch: fakeFetch({}, calls), base: "https://www.eventbriteapi.com/v3", headers: {}, live: true, allowed: EB_WRITES, steps, standIn: ebStandIn });
  const r = await syncEventbrite(io, ev, p, steps, "h");
  assertEquals(r.state, "error");
  assertEquals(r.error!.includes("cancel or refund it on Eventbrite"), true);
  assertEquals(calls[0].url.endsWith("/events/777/cancel/"), true);
});

Deno.test("luma: creates the event with its ticket types, maps them, finds the URL", async () => {
  const calls: { method: string; url: string; body: any }[] = [];
  const f = fakeFetch({
    "POST /v1/events/create": () => ({ id: "evt-New12345" }),
    "/v1/events/ticket-types/list": () => ({ entries: [{ id: "ttype-ga", name: "General Admission" }, { id: "ttype-gl", name: "Guest list" }] }),
    "/v1/events/get": () => ({ id: "evt-New12345", url: "https://luma.com/mirror-night", access: "manage" }),
  }, calls);
  const ev = mirrorEvent(PAYLOAD)!;
  const steps: StepRecord[] = [];
  const io = makeIo({ fetch: f, base: "https://public-api.luma.com", headers: { "x-luma-api-key": "k" }, live: true, allowed: LUMA_WRITES, steps, standIn: lumaStandIn });
  const r = await syncLuma(io, ev, PAYLOAD, steps, "h1");
  assertEquals(r.state, "synced");
  assertEquals(r.external_id, "evt-New12345");
  assertEquals(r.external_url, "https://luma.com/mirror-night");
  assertEquals(r.tickets!.map((t) => t.external_ticket_id), ["ttype-ga", "ttype-gl"]);
  const create = calls.find((c) => c.url.endsWith("/v1/events/create"))!.body;
  assertEquals(create.geo_address_json, { type: "lookup", query: "Blue Room, 1 Main St, Brooklyn, NY 11211, US" });
  assertEquals(create.ticket_types[0], { name: "General Admission", type: "paid", is_hidden: false, cents: 2500, currency: "usd", max_capacity: 96 });
  assertEquals(create.ticket_types[1], { name: "Guest list", type: "free", is_hidden: true, max_capacity: 1 });
  assertEquals(create.ticket_types.length, 2);   // the table stays on Exos
  for (const c of calls) assertEquals((c.method === "POST") ? LUMA_WRITES.some((re) => re.test(new URL(c.url).pathname)) : true, true);
});

Deno.test("luma: cancel only closes registration; counts approved tickets; capacity and names", async () => {
  const ev = mirrorEvent({ ...PAYLOAD, event: { ...PAYLOAD.event, status: "cancelled" } })!;
  const calls: any[] = [];
  const steps: StepRecord[] = [];
  const io = makeIo({ fetch: fakeFetch({ "POST /v1/events/update": () => ({}) }, calls), base: "https://public-api.luma.com", headers: {}, live: true, allowed: LUMA_WRITES, steps, standIn: lumaStandIn });
  const r = await syncLuma(io, ev, { ...PAYLOAD, mirror: { external_id: "evt-Old12345", external_meta: {} } }, steps, "h");
  assertEquals(r.state, "synced");
  assertEquals(calls[0].body, { event_id: "evt-Old12345", registration_open: false });

  const pages = [
    { entries: [
      { approval_status: "approved", event_tickets: [{ event_ticket_type_id: "ttype-ga" }, { event_ticket_type_id: "ttype-ga" }] },
      { approval_status: "pending_approval", event_tickets: [{ event_ticket_type_id: "ttype-ga" }] },
    ], has_more: true, next_cursor: "c2" },
    { entries: [{ approval_status: "session", event_tickets: [{ event_ticket_type_id: "ttype-gl" }] }], has_more: false },
  ];
  const f = ((url: string) => Promise.resolve(new Response(JSON.stringify(pages[url.includes("pagination_cursor=c2") ? 1 : 0]), { status: 200 }))) as typeof fetch;
  const rio = makeIo({ fetch: f, base: "https://public-api.luma.com", headers: {}, live: false, allowed: LUMA_WRITES, steps: [], standIn: lumaStandIn });
  const c = await lumaTicketCounts(rio, "evt-Old12345");
  assertEquals(c.complete, true);
  assertEquals([...c.counts.entries()], [["ttype-ga", 2], ["ttype-gl", 1]]);

  assertEquals(capacityUpdate("ttype-ga", 96, 96), null);
  assertEquals(capacityUpdate("ttype-ga", 90, 96), { event_ticket_type_id: "ttype-ga", max_capacity: 90 });
  assertEquals(capacityUpdate("ttype-ga", null, 96), null);
  const names = lumaTicketNames([
    { id: "a", name: "A very long ticket name that goes past thirty" }, { id: "b", name: "A very long ticket name that goes past thirty" },
  ] as any);
  assertEquals([...names.values()].map((n) => n.length <= 30), [true, true]);
  assertEquals(names.get("a") === names.get("b"), false);
});

Deno.test("eventbrite: a reused class is not marked created; one it adds is", async () => {
  const calls: any[] = [];
  const f = fakeFetch({
    "GET /v3/users/me/organizations/": () => ({ organizations: [{ id: "42" }] }),
    "POST /v3/organizations/42/venues/": () => ({ id: "99" }),
    "POST /v3/events/888/": () => ({}),
    "GET /v3/events/888/ticket_classes/": () => ({ ticket_classes: [{ id: "6001", name: "General Admission" }] }),
    "POST /v3/events/888/ticket_classes/6001/": () => ({}),
    "POST /v3/events/888/ticket_classes/": () => ({ id: "6002" }),
    "POST /v3/events/888/publish/": () => ({}),
  }, calls);
  const ev = mirrorEvent(PAYLOAD)!;
  const linked = { ...PAYLOAD, mirror: { mode: "link", external_id: "888", external_meta: {}, last_hash: null } };
  const steps: StepRecord[] = [];
  const io = makeIo({ fetch: f, base: "https://www.eventbriteapi.com/v3", headers: {}, live: true, allowed: EB_WRITES, steps, standIn: ebStandIn });
  const r = await syncEventbrite(io, ev, linked, steps, "h2");
  assertEquals(r.tickets, [{ tier_id: "t1", external_ticket_id: "6001", name: "General Admission" },
                           { tier_id: "t2", external_ticket_id: "6002", name: "Guest list", created: true }]);
});

Deno.test("eventbrite writer: a 0 count hides a class Exos created, shows it again later; others are left alone", () => {
  // Not Exos's class (or no state): 0 is never sent.
  assertEquals(planCapacity("555", "101", 292, 0), null);
  assertEquals(planCapacity("555", "101", 292, 0, { exosCreated: false }), null);
  // Exos's: hidden instead of a refused 0.
  const hide = planCapacity("555", "101", 292, 0, { exosCreated: true })!;
  assertEquals(hide.body, { ticket_class: { hidden: true } });
  assertEquals([hide.path, hide.to], ["/events/555/ticket_classes/101/", 0]);
  assertCapacityOnly(hide);
  // Already hidden: nothing to send.
  assertEquals(planCapacity("555", "101", 292, 0, { exosCreated: true, hiddenByCount: true }), null);
  // Seats again: the capacity, shown (even if the capacity didn't change).
  const show = planCapacity("555", "101", 12, 12, { exosCreated: true, hiddenByCount: true })!;
  assertEquals(show.body, { ticket_class: { capacity: 12, hidden: false } });
  assertCapacityOnly(show);
  // ...unless the organizer hid the Exos ticket type: capacity only.
  assertEquals(planCapacity("555", "101", 10, 12, { exosCreated: true, hiddenByCount: true, tierPublic: false })!.body,
               { ticket_class: { capacity: 12 } });
  assertEquals(planCapacity("555", "101", 12, 12, { exosCreated: true, hiddenByCount: true, tierPublic: false }), null);
  // A plain change as before.
  assertEquals(planCapacity("555", "101", 50, 96, { exosCreated: true })!.body, { ticket_class: { capacity: 96 } });
  // The guard: only those three shapes.
  const bad = [{ hidden: false }, { capacity: 0 }, { capacity: 5, hidden: true }, { hidden: true, name: "x" }, { capacity: 0, hidden: false }];
  for (const b of bad) {
    let threw = false;
    try {
      assertCapacityOnly({ ...hide, body: { ticket_class: b as any } });
    } catch {
      threw = true;
    }
    assertEquals(threw, true, JSON.stringify(b));
  }
});
