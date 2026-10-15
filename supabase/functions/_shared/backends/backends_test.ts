import { assertEquals } from "jsr:@std/assert@1";
import { cursorString, i18n, orderRows, parseCursor } from "./pretix.ts";
import { attendeeRow } from "./hievents.ts";
import { baseUrl, joinName } from "./rows.ts";
import { testProvider } from "./providers.ts";

Deno.test("pretix orders -> door rows", () => {
  const items = new Map([[7, "GA"]]);
  const rows = orderRows({
    code: "ABC12", status: "p", email: "buyer@x.com",
    positions: [
      { positionid: 1, item: 7, attendee_name: "Ana Lee", secret: "s1" },
      { positionid: 2, item: 7, attendee_name_parts: { given_name: "Bo", family_name: "Kim" }, secret: "s2", canceled: true },
    ],
  }, items);
  assertEquals(rows[0], { ref: "ABC12-1", code: "s1", name: "Ana Lee", email: "buyer@x.com", ticket: "GA", void: false });
  assertEquals(rows[1].void, true);
  assertEquals(rows[1].reason, "cancelled");
  assertEquals(rows[1].name, "Bo Kim");
  assertEquals(orderRows({ code: "X", status: "n", positions: [{ positionid: 1, secret: "z" }] }, items)[0].reason, "unpaid");
  assertEquals(orderRows({ code: "X", status: "c", positions: [{ positionid: 1 }] }, items)[0].reason, "cancelled");
  assertEquals(orderRows(null, items), []);
});

Deno.test("pretix cursor and names", () => {
  assertEquals(parseCursor("ms=2026-10-16T09:00:00Z|p=3"), { since: "2026-10-16T09:00:00Z", page: 3 });
  assertEquals(parseCursor(null), { since: null, page: 1 });
  assertEquals(parseCursor("ms=garbage|p=x"), { since: null, page: 1 });
  assertEquals(cursorString("2026-10-16T09:00:00Z", 2), "ms=2026-10-16T09:00:00Z|p=2");
  assertEquals(cursorString(null, 1), "");
  assertEquals(i18n({ de: "Eintritt" }), "Eintritt");
  assertEquals(i18n({ en: "GA", de: "x" }), "GA");
});

Deno.test("hi.events attendees -> door rows", () => {
  assertEquals(attendeeRow({ id: 9, public_id: "A-XYZ", first_name: "Cy", last_name: "Doe", email: "c@x.com", status: "ACTIVE" }),
    { ref: "9", code: "A-XYZ", name: "Cy Doe", email: "c@x.com", ticket: null, void: false });
  assertEquals(attendeeRow({ id: 10, status: "CANCELLED" })?.reason, "cancelled");
  assertEquals(attendeeRow({ id: 11, status: "AWAITING_PAYMENT" })?.reason, "unpaid");
  assertEquals(attendeeRow({}), null);
});

Deno.test("base urls and names", () => {
  assertEquals(baseUrl("https://tickets.example.com/"), "https://tickets.example.com");
  assertEquals(baseUrl("https://x.com/pretix/"), "https://x.com/pretix");
  assertEquals(baseUrl("http://x.com"), null);
  assertEquals(baseUrl("https://u:p@x.com"), null);
  assertEquals(baseUrl("https://x.com/?a=1"), null);
  assertEquals(joinName(" Ana ", "", "Lee"), "Ana Lee");
  assertEquals(joinName(), null);
});

Deno.test("provider tests are reads and refuse bad input before calling out", async () => {
  const calls: string[] = [];
  const f = ((url: string, init?: RequestInit) => {
    calls.push(`${init?.method} ${url}`);
    return Promise.resolve(new Response(JSON.stringify({ friendly_name: "Club" }), { status: 200, headers: { "content-type": "application/json" } }));
  }) as typeof fetch;
  const ok = async () => null;
  assertEquals((await testProvider(f, "twilio", { account_sid: "nope" }, "t", ok)).ok, false);
  assertEquals(calls.length, 0);
  const tw = await testProvider(f, "twilio", { account_sid: "AC" + "a".repeat(32) }, "t", ok);
  assertEquals(tw, { ok: true, name: "Club" });
  assertEquals((await testProvider(f, "pretix", { base_url: "http://x" }, "t", ok)).ok, false);
  assertEquals((await testProvider(f, "pretix", { base_url: "https://x.com" }, "t", async () => "private ip")).ok, false);
  assertEquals((await testProvider(f, "stubhub", {}, "t", ok)).ok, null);
  for (const c of calls) assertEquals(c.startsWith("GET "), true);
});
