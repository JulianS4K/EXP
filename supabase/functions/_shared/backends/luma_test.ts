import { assertEquals } from "jsr:@std/assert@1";
import { guestRow, lumaEvent, lumaGuestsPage, lumaKey } from "./luma.ts";
import { testProvider } from "./providers.ts";

const json = (body: unknown, status = 200) =>
  Promise.resolve(new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } }));

Deno.test("luma check-in link -> guest key", () => {
  assertEquals(lumaKey("https://luma.com/check-in/evt-AbC123?pk=g-Xy7Zq9Lm"), "g-Xy7Zq9Lm");
  assertEquals(lumaKey("https://lu.ma/check-in/evt-AbC123?pk=g-Xy7Zq9Lm&x=1"), "g-Xy7Zq9Lm");
  assertEquals(lumaKey("g-Xy7Zq9Lm"), "g-Xy7Zq9Lm");
  assertEquals(lumaKey("https://luma.com/check-in/evt-AbC123"), null);
  assertEquals(lumaKey(""), null);
  assertEquals(lumaKey(42), null);
});

Deno.test("luma Guest (openapi schema) -> door row", () => {
  const ana = guestRow({
    id: "gst-1", user_id: "usr-1", approval_status: "approved", user_name: "Ana Lee", user_first_name: "Ana",
    user_last_name: "Lee", user_email: "ana@x.com", check_in_qr_code: "https://luma.com/check-in/evt-AbC123?pk=g-AnaKey12",
    event_tickets: [
      { id: "tkt-1", name: "GA", amount: 2500, checked_in_at: null, event_ticket_type_id: "ttype-1", is_captured: true },
      { id: "tkt-2", name: "GA", amount: 2500, checked_in_at: null, event_ticket_type_id: "ttype-1", is_captured: true },
    ],
  });
  assertEquals(ana, { ref: "gst-1", code: "g-AnaKey12", name: "Ana Lee", email: "ana@x.com", ticket: "GA ×2", void: false });
  const wait = guestRow({ id: "gst-2", approval_status: "waitlist", user_name: null, user_first_name: "Bo", user_last_name: "Kim", event_tickets: [] });
  assertEquals(wait?.void, true);
  assertEquals(wait?.reason, "waitlist");
  assertEquals(wait?.name, "Bo Kim");
  assertEquals(wait?.code, null);
  assertEquals(wait?.ticket, null);
  assertEquals(guestRow({ id: "gst-3", approval_status: "session" })?.void, false);
  assertEquals(guestRow({ id: "gst-4", approval_status: "declined" })?.reason, "declined");
  assertEquals(guestRow({ id: "gst-5", approval_status: "something_new" })?.reason, "not approved");
  assertEquals(guestRow({ id: "bad id!" }), null);
  assertEquals(guestRow(null), null);
});

Deno.test("luma reads: GETs with the key header, paths from the spec, cursor paging", async () => {
  const calls: { url: string; init?: RequestInit }[] = [];
  const f = ((url: string, init?: RequestInit) => {
    calls.push({ url, init });
    const u = new URL(url);
    if (u.pathname === "/v1/calendars/get") return json({ id: "cal-1", name: "My Calendar" });
    if (u.pathname === "/v1/entities/lookup") {
      return json({ entity: u.searchParams.get("slug") === "my-party" ? { type: "event", event: { id: "evt-AbC123", name: "Party" } } : null });
    }
    if (u.pathname === "/v1/events/get") {
      return json(u.searchParams.get("event_id") === "evt-AbC123" ? { id: "evt-AbC123", name: "Party", access: "manage" } : { id: "evt-View99", name: "Other", access: "view" });
    }
    if (u.pathname === "/v1/events/guests/list") {
      return json(u.searchParams.get("pagination_cursor") === "c2"
        ? { entries: [{ id: "gst-2", approval_status: "approved" }], has_more: false }
        : { entries: [{ id: "gst-1", approval_status: "approved" }], has_more: true, next_cursor: "c2" });
    }
    return json({}, 404);
  }) as typeof fetch;

  const p1 = await lumaGuestsPage(f, "k1", "evt-AbC123", null);
  assertEquals(p1.next, "c2");
  assertEquals(p1.rows.map((r) => r.ref), ["gst-1"]);
  const p2 = await lumaGuestsPage(f, "k1", "evt-AbC123", p1.next);
  assertEquals(p2.next, null);
  assertEquals(p2.rows.map((r) => r.ref), ["gst-2"]);

  assertEquals(await lumaEvent(f, "k1", "evt-AbC123"), { ok: true, id: "evt-AbC123", name: "Party" });
  assertEquals(await lumaEvent(f, "k1", "my-party"), { ok: true, id: "evt-AbC123", name: "Party" });
  assertEquals((await lumaEvent(f, "k1", "no-such-slug")).ok, false);
  assertEquals((await lumaEvent(f, "k1", "evt-View99")).ok, false);

  const ok = async () => null;
  assertEquals((await testProvider(f, "luma", {}, null, ok)).ok, false);
  assertEquals(await testProvider(f, "luma", {}, "k1", ok), { ok: true, name: "My Calendar" });

  for (const c of calls) {
    assertEquals(c.init?.method, "GET");
    assertEquals((c.init?.headers as Record<string, string>)["x-luma-api-key"], "k1");
    assertEquals(c.url.startsWith("https://public-api.luma.com/v1/"), true);
  }
  const fail = (() => json({}, 401)) as unknown as typeof fetch;
  assertEquals((await lumaGuestsPage(fail, "k", "evt-AbC123", null)).status, 401);
  assertEquals((await testProvider(fail, "luma", {}, "k", ok)).ok, false);
});
