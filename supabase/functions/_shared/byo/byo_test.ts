// The own-account marketplaces (mig 20261121214500), dry run only: the
// adapters replay exos-distribute's planned listings (creates, StubHub /
// SeatGeek updates, deletes and delists by sync.ts planDelist) through
// GatedHttp on explicit allowlists, with the org's credential; $0 is never
// listed; the build pin holds with every flag on; nothing reaches fetch. No
// network: every fetch here is a stub that counts calls.
import { assert, assertEquals, assertRejects, assertStringIncludes } from "jsr:@std/assert@1";
import { planByo, BYO_WRITES_PINNED_OFF, BYO_CHANNELS, type ByoRunDeps, type ByoViewChannel } from "./run.ts";
import { BYO_ADAPTERS, BYO_DEFS, byoHttp } from "../channels/adapters/byoMarketplace.ts";
import { createGatedHttp, GatedHttpRefused } from "../channels/gatedHttp.ts";
import { memoryAuditSink } from "../channels/audit.ts";
import { memoryUsageCounter } from "../channels/usage.ts";
import { adapterProblems, type OrgCredential } from "../channels/adapter.ts";
import { ADAPTERS, ensureRegistry } from "../channels/registry.ts";
import { exosListingId } from "../marketplace/listingIds.ts";

const NOW = new Date("2026-11-21T12:00:00Z");
const SECRET = "tok-BYO-secret-1234567890";
const ALLOC = "b4000000-0000-4000-8000-0000000000a1";
const L1 = exosListingId(ALLOC, 1);
const L2 = exosListingId(ALLOC, 2);
const L3 = exosListingId(ALLOC, 3);

function stubFetch() {
  const seen = { calls: 0 };
  const f = (async () => {
    seen.calls++;
    return new Response("{}", { status: 200 });
  }) as unknown as typeof fetch;
  return { f, seen };
}

const store = (provider: string, secret: string | null = SECRET) =>
  ({ provider, status: "connected", config: {}, secret, writes_enabled: true, account_name: "Org seller", source: "store" });

function deps(creds: Record<string, unknown>): ByoRunDeps & { fetchCalls: () => number } {
  const { f, seen } = stubFetch();
  return {
    orgId: "org-1",
    rpc: async (fn, args) => fn === "exos_integration_secret" ? { data: creds[String(args.p_provider)] ?? null, error: null } : { data: null, error: null },
    env: () => "on", // every operator flag on: the pin still holds
    fetch: f,
    now: () => NOW,
    counter: memoryUsageCounter(() => NOW.getTime()),
    persistAudit: false,
    fetchCalls: () => seen.calls,
  };
}

const planned = (path: string, method = "POST") => ({
  channel: "stubhub",
  listings: [
    { listing_id: L1, seat_from: 1, seat_thru: 4, quantity: 4, unit_price: 42.11, request: { endpoint: "createSellerListing", method, path, body: { external_id: L1, quantity: 4, price: 42.11 } } },
    { listing_id: L2, seat_from: 5, seat_thru: 8, quantity: 4, unit_price: 42.11, request: { endpoint: "createSellerListing", method, path, body: { external_id: L2, quantity: 4, price: 42.11 } } },
  ],
  per_order_cap: 4,
  unresolved: [],
});

const tier = (over: Record<string, unknown> = {}) => ({
  tier_id: "t1", name: "GA", price: 40, capacity: 200, allocated: 20, held: 8, sold: 0, min_pct: 0, status: "pending",
  account: "own", listed: false, planned_listing: planned("/events/123456/sellerlistings"), ...over,
});

const chan = (channel: string, tiers: unknown[], over: Partial<ByoViewChannel> = {}): ByoViewChannel => ({
  channel, provider: channel === "evo" ? "tevo" : channel, own: true, pct: 10, min_pct: 0, connected: true, network_ticked: false,
  tiers: tiers as ByoViewChannel["tiers"], ...over,
});

Deno.test("registry: the four own-account adapters are core, shape-checked, list + delist only", () => {
  ensureRegistry();
  for (const a of BYO_ADAPTERS) {
    assertEquals(adapterProblems(a), [], a.id);
    assert(ADAPTERS.includes(a), `${a.id} registered`);
    assertEquals(a.status, "core");
    assert(a.caps.list && a.caps.delist && !a.caps.createEvent && !a.caps.publishPost, a.id);
  }
  assertEquals(BYO_ADAPTERS.map((a) => a.id), BYO_CHANNELS.map((c) => `byo_${c}`));
});

Deno.test("allowlists: exactly the listing writes; anything else is refused whatever the switches", async () => {
  const cases: Array<[typeof BYO_CHANNELS[number], string, string]> = [
    ["stubhub", "POST", "/sales/123/confirm"],
    ["stubhub", "PATCH", "/sellerlistings/123"],          // by StubHub's id: never (only our external id)
    ["stubhub", "DELETE", "/externalsellerlistings/broker-listing-9"], // not an Exos listing id
    ["seatgeek", "PATCH", "/order"],
    ["seatgeek", "DELETE", "/listings"],
    ["vivid", "POST", "/v1/confirmOrder"],
    ["vivid", "PUT", "/listings/v2/update"],
    ["evo", "POST", "/v9/orders"],
    ["evo", "PATCH", "/v9/inventory/123"],
  ];
  for (const [c, m, path] of cases) {
    const o = byoHttp(c, null);
    const { f, seen } = stubFetch();
    const audit = memoryAuditSink();
    const http = createGatedHttp({ ...o, fetch: f, env: () => "on", orgWritesEnabled: true, audit, now: () => NOW });
    await assertRejects(() => http.request(m as never, path, { body: {} }), GatedHttpRefused, undefined, `${c} ${m} ${path}`);
    assertEquals(seen.calls, 0);
    assertEquals(audit.steps[0].error, "NOT_ALLOWED", `${c} ${m} ${path}`);
  }
});

Deno.test("the pass: pinned off; StubHub creates replayed from the plan with the org's credential; nothing sent", async () => {
  assertEquals(BYO_WRITES_PINNED_OFF, true);
  const d = deps({ stubhub: store("stubhub") });
  const out = await planByo(d, { eventId: "e1", channels: [chan("stubhub", [tier()])] });
  assertEquals(d.fetchCalls(), 0, "no request reaches a marketplace");
  const sh = out.channels[0];
  assert(sh.dryRun && sh.connected, "dry run, connected");
  assertEquals(sh.steps.map((s) => `${s.method} ${s.path}`), ["POST /events/123456/sellerlistings", "POST /events/123456/sellerlistings"]);
  assert(sh.steps.every((s) => !s.live && s.op === "listing.create"));
  assertEquals((sh.steps[0].body as any).external_id, L1);
  assert(!JSON.stringify(out).includes(SECRET), "the secret never appears");
});

Deno.test("updates and deletes: StubHub PATCH / DELETE by our external id; SeatGeek PATCH and bulk delete", async () => {
  const ops = { create: [], update: [{ listing_id: L1, patch: { price: 45 } }], delete: [L3] };
  const snapshot = { listings: [{ listing_id: L1 }, { listing_id: L3 }] };
  const d = deps({ stubhub: store("stubhub"), seatgeek: store("seatgeek") });
  const out = await planByo(d, { eventId: "e1", channels: [
    chan("stubhub", [tier({ planned_listing: { ...planned("/events/1/sellerlistings"), ops }, listed_snapshot: snapshot })]),
    chan("seatgeek", [tier({ planned_listing: { ...planned(`/listings/single/${L1}`, "PUT"), ops }, listed_snapshot: snapshot })]),
  ] });
  assertEquals(d.fetchCalls(), 0);
  assertEquals(out.channels[0].steps.map((s) => `${s.method} ${s.path}`),
    [`PATCH /externalsellerlistings/${L1}`, `DELETE /externalsellerlistings/${L3}`]);
  assertEquals(out.channels[0].steps[0].body, { price: 45 });
  assertEquals(out.channels[1].steps.map((s) => `${s.method} ${s.path}`), [`PATCH /listings/single/${L1}`, "POST /listings/bulk-delete"]);
  assertEquals(out.channels[1].steps[1].body, { seller_listing_ids: [L3] });
});

Deno.test("Vivid Seats / Ticket Evolution: Vivid delists and warns a live change; TEvo plans nothing until its own office id is planned", async () => {
  const ops = { create: [], update: [{ listing_id: L1, patch: { price: 45 } }], delete: [] };
  const d = deps({ vivid: store("vivid"), tevo: store("tevo") });
  const out = await planByo(d, { eventId: "e1", channels: [
    chan("vivid", [tier({ planned_listing: { ...planned("/listings/v2/create"), ops } }),
                   tier({ tier_id: "t2", name: "VIP", status: "delisting", listed_snapshot: { listings: [{ listing_id: L2 }] } })]),
    chan("evo", [tier({ status: "delisting", listed_snapshot: { listings: [{ listing_id: L2, tevo_inventory_id: 777 }] } })]),
  ] });
  assertEquals(d.fetchCalls(), 0);
  const vivid = out.channels[0];
  assert(vivid.result.warnings.some((w) => w.includes("isn't built yet")), "the Vivid update is warned");
  assertEquals(vivid.steps.map((s) => `${s.method} ${s.path}`), [`DELETE /listings/v2/delete?internalTicketId=${L2}`]);
  // TEvo: Exos's office is in the plan, so nothing is planned for an own account yet.
  assertEquals(out.channels[1].steps.length, 0);
  assert(out.channels[1].result.warnings.some((w) => w.includes("office id")), "the TEvo gap is said");
});

Deno.test("limits: a $0 ticket type or listing is never planned (every resale marketplace blocks zero_price)", async () => {
  const d = deps({ stubhub: store("stubhub") });
  const free = planned("/events/1/sellerlistings");
  free.listings[1].unit_price = 0;
  const out = await planByo(d, { eventId: "e1", channels: [chan("stubhub", [
    tier({ tier_id: "t0", name: "Free", price: 0 }),
    tier({ planned_listing: free }),
    tier({ tier_id: "tx", name: "Tables", skip: "table ticket type" }),
  ])] });
  const sh = out.channels[0];
  assertEquals(sh.steps.length, 1, "only the priced listing");
  assert(sh.result.warnings.some((w) => w.startsWith("Free:") && w.includes("$0")), "the $0 type is said why");
  assert(sh.result.warnings.some((w) => w.includes("a $0 listing is never offered")), "the $0 listing too");
  assert(sh.result.warnings.some((w) => w.startsWith("Tables:")), "a skipped type is listed");
});

Deno.test("not connected, not planned yet, off: says so; a channel at 0% or not own is skipped", async () => {
  const d = deps({});
  const out = await planByo(d, { eventId: "e1", channels: [
    chan("stubhub", [tier(), tier({ tier_id: "t2", name: "VIP", planned_listing: null })]),
    chan("seatgeek", [tier()], { pct: 0 }),
    chan("vivid", [tier()], { own: false }),
    chan("gametime", [tier()]),
  ] });
  assertEquals(out.channels.map((c) => c.channel), ["stubhub"]);
  const sh = out.channels[0];
  assert(!sh.connected);
  assertStringIncludes(sh.result.warnings.join("\n"), "isn't connected");
  assertStringIncludes(sh.result.warnings.join("\n"), "VIP: not planned yet");
  assertEquals(d.fetchCalls(), 0);
});

Deno.test("each marketplace's credential provider is the org's own store row", () => {
  assertEquals(Object.fromEntries(BYO_CHANNELS.map((c) => [c, BYO_DEFS[c].provider])),
    { stubhub: "stubhub", seatgeek: "seatgeek", vivid: "vivid", evo: "tevo" });
  const c: OrgCredential = { provider: "stubhub", status: "connected", config: {}, secret: SECRET, writesEnabled: true, accountName: null, source: "store" };
  assertEquals(byoHttp("stubhub", c).headers, { Authorization: `Bearer ${SECRET}` });
  assertEquals(byoHttp("stubhub", c).channel, "byo_stubhub", "EXOS_BYO_STUBHUB_WRITES, separate from the network's flags");
});
