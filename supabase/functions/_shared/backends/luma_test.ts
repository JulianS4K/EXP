import { assertEquals } from "jsr:@std/assert@1";
import { guestRow, lumaGuestsPage, lumaKey } from "./luma.ts";
import { testProvider } from "./providers.ts";

Deno.test("luma check-in link -> guest key", () => {
  assertEquals(lumaKey("https://luma.com/check-in/evt-AbC123?pk=g-Xy7Zq9Lm"), "g-Xy7Zq9Lm");
  assertEquals(lumaKey("https://lu.ma/check-in/evt-AbC123?pk=g-Xy7Zq9Lm&x=1"), "g-Xy7Zq9Lm");
  assertEquals(lumaKey("g-Xy7Zq9Lm"), "g-Xy7Zq9Lm");
  assertEquals(lumaKey("https://luma.com/check-in/evt-AbC123"), null);
  assertEquals(lumaKey(""), null);
  assertEquals(lumaKey(42), null);
});

Deno.test("luma guests -> door rows", () => {
  const ana = guestRow({
    api_id: "gst-1",
    guest: {
      api_id: "gst-1", approval_status: "approved", user_name: "Ana Lee", user_email: "ana@x.com",
      check_in_qr_code: "https://luma.com/check-in/evt-AbC123?pk=g-AnaKey12",
      event_tickets: [{ name: "GA" }, { name: "GA" }, { name: "GA", is_canceled: true }],
    },
  });
  assertEquals(ana, { ref: "gst-1", code: "g-AnaKey12", name: "Ana Lee", email: "ana@x.com", ticket: "GA ×2", void: false });
  const wait = guestRow({ api_id: "gst-2", approval_status: "waitlist", user_first_name: "Bo", user_last_name: "Kim" });
  assertEquals(wait?.void, true);
  assertEquals(wait?.reason, "waitlist");
  assertEquals(wait?.name, "Bo Kim");
  assertEquals(wait?.code, null);
  assertEquals(guestRow({ guest: { api_id: "gst-3", approval_status: "declined" } })?.reason, "declined");
  assertEquals(guestRow({ guest: { api_id: "gst-4", approval_status: "something_new" } })?.reason, "not approved");
  assertEquals(guestRow({ guest: { api_id: "bad id!" } }), null);
  assertEquals(guestRow(null), null);
});

Deno.test("luma reads are GETs with the key header, paged by cursor", async () => {
  const calls: { url: string; init?: RequestInit }[] = [];
  const pages = [
    { entries: [{ guest: { api_id: "gst-1", approval_status: "approved" } }], has_more: true, next_cursor: "c2" },
    { entries: [{ guest: { api_id: "gst-2", approval_status: "approved" } }], has_more: false, next_cursor: null },
  ];
  const f = ((url: string, init?: RequestInit) => {
    calls.push({ url, init });
    const body = url.includes("get-guests") ? pages[url.includes("pagination_cursor=c2") ? 1 : 0] : { user: { name: "My Calendar" } };
    return Promise.resolve(new Response(JSON.stringify(body), { status: 200, headers: { "content-type": "application/json" } }));
  }) as typeof fetch;
  const p1 = await lumaGuestsPage(f, "k1", "evt-AbC123", null);
  assertEquals(p1.next, "c2");
  assertEquals(p1.rows.length, 1);
  const p2 = await lumaGuestsPage(f, "k1", "evt-AbC123", p1.next);
  assertEquals(p2.next, null);
  const ok = async () => null;
  assertEquals((await testProvider(f, "luma", {}, null, ok)).ok, false);
  assertEquals(await testProvider(f, "luma", {}, "k1", ok), { ok: true, name: "My Calendar" });
  for (const c of calls) {
    assertEquals(c.init?.method, "GET");
    assertEquals((c.init?.headers as Record<string, string>)["x-luma-api-key"], "k1");
    assertEquals(c.url.startsWith("https://public-api.luma.com/v1/"), true);
  }
  const fail = (() => Promise.resolve(new Response("{}", { status: 401 }))) as unknown as typeof fetch;
  assertEquals((await lumaGuestsPage(fail, "k", "evt-AbC123", null)).status, 401);
  assertEquals((await testProvider(fail, "luma", {}, "k", ok)).ok, false);
});
