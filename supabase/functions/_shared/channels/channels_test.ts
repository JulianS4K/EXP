import { assertEquals, assertRejects } from "jsr:@std/assert@1";
import { contentHash, firstCapacity, makeIo, mirrorEvent, type StepRecord, type SyncHooks, textToHtml, utc, writesLive } from "./model.ts";
import { EB_WRITES, ebClassBody, ebFindCreated, ebStandIn, syncEventbrite } from "./eventbrite.ts";
import { capacityUpdate, LUMA_WRITES, lumaSlug, lumaStandIn, lumaTicketCounts, lumaTicketNames, syncLuma } from "./luma.ts";
import { lumaInventory } from "./lumaInventory.ts";

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
  // Created here: marked so, with the capacity each was created with (mig 20261121100000).
  assertEquals(r.tickets, [
    { tier_id: "t1", external_ticket_id: "5001", name: "General Admission", created: true, capacity: 96 },
    { tier_id: "t2", external_ticket_id: "5002", name: "Guest list", created: true, capacity: 1 },
  ]);
  // `capacity`, the spec's Ticket Class Create field (`quantity_total` is deprecated there).
  const ga = calls.find((c) => c.body?.ticket_class?.name === "General Admission")!.body.ticket_class;
  assertEquals(ga, { name: "General Admission", hidden: false, free: false, capacity: 96, cost: "USD,2500" });
  const gl = calls.find((c) => c.body?.ticket_class?.name === "Guest list")!.body.ticket_class;
  assertEquals([gl.free, gl.hidden, gl.capacity, gl.cost, "quantity_total" in gl], [true, true, 1, undefined, false]);
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

// ---- mig 20261121100000: channel risks -------------------------------------

const EB = "https://www.eventbriteapi.com/v3";
const LUMA = "https://public-api.luma.com";
const ebIo = (f: typeof fetch, steps: StepRecord[], live = true) =>
  makeIo({ fetch: f, base: EB, headers: {}, live, allowed: EB_WRITES, steps, standIn: ebStandIn, retry: { maxRetries: 2, baseMs: 1, maxWaitMs: 50, sleep: () => Promise.resolve() } });
const lumaIo = (f: typeof fetch, steps: StepRecord[], live = true) =>
  makeIo({ fetch: f, base: LUMA, headers: {}, live, allowed: LUMA_WRITES, steps, standIn: lumaStandIn, retry: { maxRetries: 2, baseMs: 1, maxWaitMs: 50, sleep: () => Promise.resolve() } });
const hooksThat = (answer: { ok: boolean; reason?: string; pending?: any }, seen: any[] = []): SyncHooks =>
  ({ beginCreate: (m) => { seen.push(m); return Promise.resolve(answer); } });

Deno.test("eventbrite: an adopted class on a linked event gets no update, so never a price", async () => {
  const calls: any[] = [];
  const f = fakeFetch({
    "POST /v3/events/888/": () => ({}),
    "GET /v3/events/888/ticket_classes/": () => ({ ticket_classes: [{ id: "6001", name: "General Admission" }] }),
    "POST /v3/events/888/ticket_classes/6002/": () => ({}),
  }, calls);
  const ev = mirrorEvent(PAYLOAD)!;
  const linked = {
    ...PAYLOAD,
    mirror: { mode: "link", external_id: "888", external_meta: { organization_id: "42", venue_id: "99", venue_key: ev.venueQuery, published: true }, last_hash: "old" },
    // t1: found by name on the organizer's event (adopted); t2: a class Exos created there earlier.
    maps: [{ tier_id: "t2", external_ticket_id: "6002", created: true }],
  };
  const steps: StepRecord[] = [];
  const r = await syncEventbrite(ebIo(f, steps), ev, linked, steps, "h2");
  assertEquals(r.state, "synced");
  const posts = calls.filter((c) => c.method === "POST").map((c) => new URL(c.url).pathname);
  assertEquals(posts.includes("/v3/events/888/ticket_classes/6001/"), false);     // adopted: nothing sent
  assertEquals(posts.includes("/v3/events/888/ticket_classes/6002/"), true);      // Exos's own: kept in step
  assertEquals(calls.some((c) => c.method === "POST" && c.body?.ticket_class?.cost && c.url.includes("/6001/")), false);
  assertEquals(r.tickets!.find((t) => t.tier_id === "t1"), { tier_id: "t1", external_ticket_id: "6001", name: "General Admission", created: false });
  // A mapping the organizer made (no created flag) on a linked event: not updated either.
  const calls2: any[] = [];
  const steps2: StepRecord[] = [];
  const f2 = fakeFetch({ "POST /v3/events/888/": () => ({}) }, calls2);
  await syncEventbrite(ebIo(f2, steps2), ev, { ...linked, maps: [{ tier_id: "t1", external_ticket_id: "6001" }, { tier_id: "t2", external_ticket_id: "6002" }] }, steps2, "h3");
  assertEquals(calls2.filter((c) => c.method === "POST" && c.url.includes("/ticket_classes/")).length, 0);
});

Deno.test("eventbrite: a recorded create is looked up, not repeated", async () => {
  const ev = mirrorEvent(PAYLOAD)!;
  const pending = { at: "2026-11-01T00:00:00Z", first: "2026-11-01T00:00:00Z", name: ev.name, start: ev.startUtc };
  const payload = { ...PAYLOAD, mirror: { mode: "create", external_id: null, external_meta: { organization_id: "42", venue_id: "99", venue_key: ev.venueQuery, pending_create: pending }, last_hash: null } };
  const list = (events: any[]) => () => ({ events });
  const mine = { id: "777", name: { text: ev.name }, start: { utc: ev.startUtc }, created: "2026-11-01T00:00:05Z", url: "https://www.eventbrite.com/e/777" };

  // Found: no second create; the event is updated and kept.
  const calls: any[] = [];
  const steps: StepRecord[] = [];
  const seen: any[] = [];
  const f = fakeFetch({
    "GET /v3/organizations/42/events/": list([mine, { ...mine, id: "700", created: "2026-10-01T00:00:00Z" }, { ...mine, id: "701", name: { text: "Other" } }]),
    "POST /v3/events/777/": () => ({}),
    "GET /v3/events/777/ticket_classes/": () => ({ ticket_classes: [{ id: "5001", name: "General Admission" }, { id: "5002", name: "Guest list" }] }),
    "POST /v3/events/777/ticket_classes/5001/": () => ({}),
    "POST /v3/events/777/ticket_classes/5002/": () => ({}),
    "POST /v3/events/777/publish/": () => ({}),
  }, calls);
  const r = await syncEventbrite(ebIo(f, steps), ev, payload, steps, "h1", hooksThat({ ok: true }, seen));
  assertEquals(r.state, "synced");
  assertEquals(r.external_id, "777");
  assertEquals(seen.length, 0);                                              // no create begun
  assertEquals(calls.some((c) => c.method === "POST" && c.url.endsWith("/organizations/42/events/")), false);
  assertEquals("pending_create" in (r.external_meta ?? {}), false);
  const q = new URL(calls.find((c) => c.url.includes("/organizations/42/events/?"))!.url).searchParams;
  assertEquals([q.get("name_filter"), q.get("status"), q.get("order_by")], [ev.name, "all", "created_desc"]);
  // Its classes were made by Exos with the event: they count as created.
  assertEquals(r.tickets!.every((t) => t.created === true), true);

  // The lookup fails: nothing is created.
  const calls2: any[] = [];
  const f2 = fakeFetch({}, calls2);   // 404 on the list
  const r2 = await syncEventbrite(ebIo(f2, []), ev, payload, [], "h1", hooksThat({ ok: true }));
  assertEquals(r2.state, "error");
  assertEquals(calls2.filter((c) => c.method === "POST").length, 0);

  // Two candidates: the organizer picks.
  const calls3: any[] = [];
  const f3 = fakeFetch({ "GET /v3/organizations/42/events/": list([mine, { ...mine, id: "778" }]) }, calls3);
  const r3 = await syncEventbrite(ebIo(f3, []), ev, payload, [], "h1", hooksThat({ ok: true }));
  assertEquals(r3.state, "error");
  assertEquals(r3.error!.includes("link the right one"), true);
  assertEquals(calls3.filter((c) => c.method === "POST").length, 0);

  // None found, but the earlier create is still in flight: not sent again.
  const calls4: any[] = [];
  const f4 = fakeFetch({ "GET /v3/organizations/42/events/": list([]), "POST /v3/organizations/42/events/": () => ({ id: "999" }) }, calls4);
  const r4 = await syncEventbrite(ebIo(f4, []), ev, payload, [], "h1", hooksThat({ ok: false, reason: "in-flight" }));
  assertEquals(r4.state, "error");
  assertEquals(calls4.some((c) => c.method === "POST" && c.url.endsWith("/organizations/42/events/")), false);

  // None found and the create may go: recorded first, then sent once.
  const order: string[] = [];
  const calls5: any[] = [];
  const f5 = fakeFetch({ "GET /v3/organizations/42/events/": list([]), "POST /v3/organizations/42/events/": () => { order.push("create"); return { id: "999" }; },
                         "GET /v3/events/999/ticket_classes/": () => ({ ticket_classes: [] }), "POST /v3/events/999/ticket_classes/": () => ({ id: "5009" }),
                         "POST /v3/events/999/publish/": () => ({}) }, calls5);
  const hooks: SyncHooks = { beginCreate: (m) => { order.push(`begin ${m.name}|${m.start}`); return Promise.resolve({ ok: true }); } };
  const r5 = await syncEventbrite(ebIo(f5, []), ev, payload, [], "h1", hooks);
  assertEquals(r5.external_id, "999");
  assertEquals(order, [`begin ${ev.name}|${ev.startUtc}`, "create"]);
  // A dry run neither looks up nor begins.
  const seen6: any[] = [];
  const calls6: any[] = [];
  const d = await syncEventbrite(ebIo(fakeFetch({}, calls6), [], false), ev, payload, [], "h1", hooksThat({ ok: true }, seen6));
  assertEquals([d.state, seen6.length, calls6.length], ["dry_run", 0, 0]);
  // The matcher: same name, same start, created since the first try (less 5 minutes).
  const io7 = ebIo(fakeFetch({ "GET /v3/organizations/42/events/": list([{ ...mine, created: "2026-10-31T23:50:00Z" }, { ...mine, id: "1", start: { utc: "2026-11-02T00:00:00Z" } }]) }, []), []);
  assertEquals((await ebFindCreated(io7, "42", pending)).ids, []);
});

Deno.test("luma: a recorded create is found by its slug; the slug is sent with the create", async () => {
  const ev = mirrorEvent(PAYLOAD)!;
  const base = { ...PAYLOAD, mirror: { mode: "create", external_id: null, external_meta: {}, last_hash: null } };
  // First live create: begun with a slug, which goes in the create body.
  const calls: any[] = [];
  const seen: any[] = [];
  const f = fakeFetch({
    "POST /v1/events/create": () => ({ id: "evt-New12345" }),
    "/v1/events/ticket-types/list": () => ({ entries: [] }),
    "POST /v1/events/ticket-types/create": () => ({ id: "ttype-x" }),
    "/v1/events/get": () => ({ url: "https://luma.com/x" }),
  }, calls);
  const r = await syncLuma(lumaIo(f, []), ev, base, [], "h1",
    { beginCreate: (m) => { seen.push(m); return Promise.resolve({ ok: true, pending: { slug: m.slug } }); } }, () => 0.5);
  assertEquals(r.state, "synced");
  assertEquals(seen[0].slug, lumaSlug(ev.name, () => 0.5));
  assertEquals(calls.find((c) => c.url.endsWith("/v1/events/create")).body.slug, seen[0].slug);
  assertEquals(/^mirror-night-[a-z0-9]{8}$/.test(seen[0].slug), true);

  // A later pass with the create recorded: found by slug, not created again.
  const calls2: any[] = [];
  const f2 = fakeFetch({
    "/v1/entities/lookup": () => ({ entity: { type: "event", event: { id: "evt-New12345", slug: seen[0].slug } } }),
    "POST /v1/events/update": () => ({}),
    "/v1/events/ticket-types/list": () => ({ entries: [{ id: "ttype-ga", name: "General Admission" }, { id: "ttype-gl", name: "Guest list" }] }),
    "/v1/events/get": () => ({ url: "https://luma.com/x" }),
  }, calls2);
  const pendingPayload = { ...base, mirror: { ...base.mirror, external_meta: { pending_create: { at: "2026-11-01T00:00:00Z", slug: seen[0].slug } } } };
  const r2 = await syncLuma(lumaIo(f2, []), ev, pendingPayload, [], "h1", hooksThat({ ok: true }));
  assertEquals(r2.external_id, "evt-New12345");
  assertEquals(calls2.some((c) => c.url.endsWith("/v1/events/create")), false);
  assertEquals(new URL(calls2.find((c) => c.url.includes("/v1/entities/lookup")).url).searchParams.get("slug"), seen[0].slug);
  // Not found, the lease is gone: nothing sent.
  const calls3: any[] = [];
  const f3 = fakeFetch({ "/v1/entities/lookup": () => ({ entity: null }), "POST /v1/events/create": () => ({ id: "evt-Dup12345" }) }, calls3);
  const r3 = await syncLuma(lumaIo(f3, []), ev, pendingPayload, [], "h1", hooksThat({ ok: false, reason: "lease-lost" }));
  assertEquals(r3.state, "error");
  assertEquals(calls3.some((c) => c.url.endsWith("/v1/events/create")), false);
});

Deno.test("luma inventory: each ack stores the steps of its own request", async () => {
  const acks: any[] = [];
  const db = {
    rpc(fn: string, args: Record<string, unknown>) {
      if (fn === "exos_luma_inventory_apply") {
        return Promise.resolve({ data: [{ luma_ticket_type_id: "ttype-ga", target_capacity: 40, skip_reason: null },
                                        { luma_ticket_type_id: "ttype-gl", target_capacity: 5, skip_reason: null }], error: null });
      }
      if (fn === "exos_luma_inventory_ack") acks.push(args);
      return Promise.resolve({ data: null, error: null });
    },
    from() {
      const q: any = { select: () => q, eq: () => q,
                       then: (ok: any) => ok({ data: [{ luma_ticket_type_id: "ttype-ga", luma_capacity: 50 }, { luma_ticket_type_id: "ttype-gl", luma_capacity: null }] }) };
      return q;
    },
  };
  const guests = () => ({ entries: [{ approval_status: "approved", event_tickets: [{ event_ticket_type_id: "ttype-ga" }] }], has_more: false });
  // A dry run: one planned step per ack.
  const steps: StepRecord[] = [{ op: "planned", method: "POST", path: "/v1/events/update" }];   // the details pass's
  const out = await lumaInventory(db, lumaIo(fakeFetch({ "/v1/events/guests/list": guests }, []), steps, false), steps, "e1", "evt-Old12345", false);
  assertEquals(out.ok, true);
  assertEquals(acks.length, 2);
  assertEquals(acks[0].p_plan.steps, [{ op: "planned", method: "POST", path: "/v1/events/ticket-types/update", body: { event_ticket_type_id: "ttype-ga", max_capacity: 40 } }]);
  assertEquals(acks[1].p_plan.steps.map((x: StepRecord) => x.body), [{ event_ticket_type_id: "ttype-gl", max_capacity: 5 }]);
  // Live: the sent step, with its outcome.
  acks.length = 0;
  const live: StepRecord[] = [];
  await lumaInventory(db, lumaIo(fakeFetch({ "/v1/events/guests/list": guests, "POST /v1/events/ticket-types/update": () => ({}) }, []), live, true), live, "e1", "evt-Old12345", true);
  assertEquals(acks[0].p_plan.steps.length, 1);
  assertEquals([acks[0].p_plan.steps[0].op, acks[0].p_plan.steps[0].ok, acks[0].p_sent], ["sent", true, true]);
});

Deno.test("io: GETs retry 429 / 5xx and honour Retry-After; POSTs are sent once", async () => {
  const waits: number[] = [];
  let n = 0;
  const flaky = ((_u: string, init?: RequestInit) => {
    n++;
    if ((init?.method ?? "GET") === "POST") return Promise.resolve(new Response("{}", { status: 503 }));
    if (n === 1) return Promise.resolve(new Response("{}", { status: 429, headers: { "retry-after": "0.02" } }));
    if (n === 2) return Promise.resolve(new Response("{}", { status: 502 }));
    return Promise.resolve(new Response(JSON.stringify({ ok: 1 }), { status: 200 }));
  }) as typeof fetch;
  const steps: StepRecord[] = [];
  const io = makeIo({ fetch: flaky, base: EB, headers: {}, live: true, allowed: EB_WRITES, steps, standIn: ebStandIn,
                      retry: { maxRetries: 2, baseMs: 4, maxWaitMs: 1000, sleep: (ms) => { waits.push(ms); return Promise.resolve(); }, random: () => 1 } });
  const g = await io.req("GET", "/users/me/");
  assertEquals([g.ok, n], [true, 3]);
  assertEquals(waits, [20, 8]);                       // Retry-After 0.02 s, then backoff 4 * 2
  n = 0;
  const p = await io.req("POST", "/events/1/publish/");
  assertEquals([p.ok, p.status, n], [false, 503, 1]);  // never re-sent
  // A Retry-After beyond the limit stops: the next pass retries.
  let m = 0;
  const slow = (() => { m++; return Promise.resolve(new Response("{}", { status: 429, headers: { "retry-after": "120" } })); }) as typeof fetch;
  const io2 = makeIo({ fetch: slow, base: EB, headers: {}, live: true, allowed: EB_WRITES, steps: [], standIn: ebStandIn,
                       retry: { maxRetries: 2, baseMs: 4, maxWaitMs: 1000, sleep: () => Promise.resolve() } });
  assertEquals([(await io2.req("GET", "/users/me/")).status, m], [429, 1]);
  // A 4xx isn't retried.
  let k = 0;
  const bad = (() => { k++; return Promise.resolve(new Response("{}", { status: 400 })); }) as typeof fetch;
  const io3 = makeIo({ fetch: bad, base: EB, headers: {}, live: true, allowed: EB_WRITES, steps: [], standIn: ebStandIn, retry: { maxRetries: 2, baseMs: 1, maxWaitMs: 10, sleep: () => Promise.resolve() } });
  assertEquals([(await io3.req("GET", "/users/me/")).status, k], [400, 1]);
});

Deno.test("model: the first capacity follows the other platform's share", () => {
  const ev = mirrorEvent({ ...PAYLOAD, tiers: [{ ...PAYLOAD.tiers[0], share_cap: 30 }, { ...PAYLOAD.tiers[1], share_cap: 0 }] })!;
  assertEquals(firstCapacity(ev.tiers[0], ev.pack), 30);     // 100 - 4 = 96, capped at 30
  assertEquals(firstCapacity(ev.tiers[1], ev.pack), 1);      // never 0 (Eventbrite refuses it)
  assertEquals(firstCapacity(mirrorEvent(PAYLOAD)!.tiers[0], 4), 96);   // no cap sent: as before
});
