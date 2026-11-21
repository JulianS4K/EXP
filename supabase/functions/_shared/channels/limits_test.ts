// Platform limits (limits.ts) and the usage counters (usage.ts), channel
// core mig 20261121162400: every action (block / cap / warn), the lower
// bound when a plan or level is unknown, chunking to the budget, and rolling
// windows.
import { assert, assertEquals } from "jsr:@std/assert@1";
import {
  allRules, chunkToBudget, evaluateLimits, limitNotes, meterLine, notesFor, PLATFORM_LIMITS, rulesFor, windowSeconds,
} from "./limits.ts";
import { memoryUsageCounter } from "./usage.ts";

Deno.test("the table: one data table per platform, every rule complete", () => {
  for (const p of ["shotgun", "meetup", "pretix", "tickettailor", "allevents", "stubhub", "seatgeek", "vivid", "tickpick",
                   "gametime", "gotickets", "evo", "luma", "linkedin", "eventbrite", "google_events"]) {
    assert(rulesFor(p).length > 0, `${p} has rules`);
  }
  const ids = new Set<string>();
  for (const r of allRules()) {
    assert(!ids.has(r.id), `unique id ${r.id}`);
    ids.add(r.id);
    assert(["block", "warn", "cap"].includes(r.action), r.id);
    assert(r.reason.length > 20 && r.rule.length > 5, r.id);
    assert(PLATFORM_LIMITS[r.platform]?.includes(r), `${r.id} sits in its platform's table`);
    // A source: a URL with the date it was checked, or a note saying where the rule came from.
    assert((r.source.url && /^https:\/\//.test(r.source.url) && /^\d{4}-\d{2}-\d{2}$/.test(r.source.checked ?? "")) || r.source.note, r.id);
    if (r.kind === "usage") assert(r.metric && r.window && r.threshold, `${r.id} counts a metric over a window`);
  }
  const shotgun = rulesFor("shotgun")[0];
  assertEquals([shotgun.source.url?.includes("33562373508498"), shotgun.source.checked], [true, "2026-11-17"]);
  assertEquals(rulesFor("eventbrite")[0].verified, false, "Eventbrite's number is unconfirmed");
});

Deno.test("block: Shotgun free events, $0 tiers on every resale marketplace", () => {
  const free = evaluateLimits("shotgun", { free: true });
  assertEquals([free.allowed, free.blocks[0]?.ruleId], [false, "shotgun_free_exclusive"]);
  assert(evaluateLimits("shotgun", { free: false }).allowed);
  for (const p of ["stubhub", "seatgeek", "vivid", "tickpick", "gametime", "gotickets", "evo"]) {
    assertEquals(evaluateLimits(p, { priceCents: 0 }).blocks.length, 1, p);
    assert(evaluateLimits(p, { priceCents: 1 }).allowed, p);
    assertEquals(evaluateLimits(p, { free: true }).blocks.length, 1, `${p}: a free event with no tier price`);
  }
  assertEquals(notesFor("stubhub", { priceCents: 0 })[0].action, "block");
});

Deno.test("cap: Meetup Starter 10 attendees (and unknown plan = Starter); Luma and LinkedIn budgets", () => {
  const m = evaluateLimits("meetup", { attendees: 40 }, {}, { metric: "attendees", n: 40 });
  assertEquals([m.allowed, m.maxUnits, m.caps[0]?.ruleId], [false, 10, "meetup_starter_attendees"]);
  assert(m.caps[0].reason.includes("Standard or Pro"), "the plan warning comes with the cap");
  assert(evaluateLimits("meetup", { attendees: 8 }, {}, { metric: "attendees", n: 8 }).allowed);
  assertEquals(evaluateLimits("meetup", { plan: "pro", attendees: 400 }).caps.length, 0, "a Pro plan has no cap");

  const luma = evaluateLimits("luma", {}, { sends: { live: 12, planned: 0 } }, { metric: "sends", n: 5 });
  assertEquals([luma.allowed, luma.maxUnits], [false, 3], "new calendar: 15 a week, 12 used");
  assertEquals(evaluateLimits("luma", { accountLevel: "unlocked" }, { sends: { live: 12, planned: 0 } }, { metric: "sends", n: 5 }).maxUnits, 488);
  assert(evaluateLimits("luma", {}, { sends: { live: 12, planned: 0 } }, { metric: "sends", n: 3 }).allowed);

  const li = evaluateLimits("linkedin", {}, { invites: { live: 990, planned: 0 } }, { metric: "invites", n: 20 });
  assertEquals([li.allowed, li.maxUnits], [false, 10]);
});

Deno.test("warn: pretix hosted at 80%, Ticket Tailor on any API mirror, AllEvents 5 events, Eventbrite emails, Google hidden free", () => {
  const p = (live: number, n = 0, hosted?: boolean) => evaluateLimits("pretix", { hosted }, { tickets: { live, planned: 0 } }, { metric: "tickets", n });
  assertEquals(p(399).warnings.length, 0);
  assertEquals(p(399, 1).warnings[0]?.ruleId, "pretix_hosted_free_tickets", "400 of 500 = 80%");
  assert(p(600, 10).allowed, "a warning never stops it");
  assertEquals(p(600, 10, false).warnings.length, 0, "self-hosted pretix has no allowance");

  const tt = evaluateLimits("tickettailor", { apiMirror: true }, { tickets: { live: 0, planned: 0 } }, { metric: "tickets", n: 1 });
  assertEquals(tt.warnings[0]?.ruleId, "tickettailor_api_tickets", "warned before any API-based mirror");
  assertEquals(evaluateLimits("tickettailor", { apiMirror: false }, { tickets: { live: 10, planned: 0 } }).warnings.length, 0);

  assertEquals(evaluateLimits("allevents", { activeUpcomingEvents: 5 }).warnings.length, 1);
  assertEquals(evaluateLimits("allevents", { activeUpcomingEvents: 4 }).warnings.length, 0);
  assertEquals(evaluateLimits("allevents", { activeUpcomingEvents: 9, plan: "pro" }).warnings.length, 0);

  assertEquals(evaluateLimits("eventbrite", {}, { emails: { live: 250, planned: 0 } }).warnings.length, 1);
  assertEquals(evaluateLimits("google_events", { free: true, hidden: true }).warnings[0]?.ruleId, "google_free_public");
  assertEquals(evaluateLimits("google_events", { free: true, inviteOnly: true }).warnings.length, 1);
  assertEquals(evaluateLimits("google_events", { free: true }).warnings.length, 0);
  assertEquals(evaluateLimits("nowhere", { free: true }).allowed, true, "no rules, no limits");
});

Deno.test("meters and notes: 'would use N of M'", () => {
  const v = evaluateLimits("luma", {}, { sends: { live: 10, planned: 2 } }, { metric: "sends", n: 4 });
  assertEquals(meterLine(v.meters[0]), "would use 14 of 15 sends this week (10 used, 2 planned)");
  const over = evaluateLimits("luma", {}, { sends: { live: 10, planned: 0 } }, { metric: "sends", n: 9 });
  const notes = limitNotes(over);
  assertEquals(notes[0].action, "cap");
  assert(notes[0].text.includes("Would use 19 of 15 sends this week"), notes[0].text);
});

Deno.test("chunkToBudget: no chunk over what is left; the rest waits", () => {
  const items = Array.from({ length: 12 }, (_, i) => i);
  assertEquals(chunkToBudget(items, 5), { chunks: [[0, 1, 2, 3, 4]], deferred: [5, 6, 7, 8, 9, 10, 11] });
  assertEquals(chunkToBudget(items, 7, 3).chunks, [[0, 1, 2], [3, 4, 5], [6]]);
  assertEquals(chunkToBudget(items, 0), { chunks: [], deferred: items });
  assertEquals(chunkToBudget(items, 50, 10).chunks.map((c) => c.length), [10, 2]);
});

Deno.test("counters: rolling day / week / year windows, live and planned apart, planned once per request", async () => {
  let t = Date.parse("2026-11-21T12:00:00Z");
  const c = memoryUsageCounter(() => t);
  const key = { platform: "luma", scopeKey: "cal-1", metric: "sends" };
  const week = { ...key, windowSeconds: windowSeconds("week") };
  assert((await c.reserve({ ...week, n: 10, threshold: 15, live: true })).ok);
  t += 3 * 86400_000;
  assert(!(await c.reserve({ ...week, n: 6, threshold: 15, live: true })).ok, "16 > 15 within the week");
  assert((await c.reserve({ ...week, n: 5, threshold: 15, live: true })).ok);
  t += 4 * 86400_000 + 1000; // the first 10 are now more than 7 days old
  assertEquals(await c.read(week), { live: 5, planned: 0 }, "the week rolls");
  assert((await c.reserve({ ...week, n: 10, threshold: 15, live: true })).ok);
  assertEquals((await c.read({ ...key, windowSeconds: windowSeconds("day") })).live, 10, "the last day");
  assertEquals((await c.read({ ...key, windowSeconds: windowSeconds("year") })).live, 25, "the year keeps them all");
  assertEquals((await c.read({ ...key, windowSeconds: 0 })).live, 25, "0 = all time");
  // Planned: apart from live, once per identical request, refreshed in its window.
  const p1 = await c.reserve({ ...week, n: 4, threshold: 15, live: false, dedupe: "aaaa000011112222" });
  await c.reserve({ ...week, n: 4, threshold: 15, live: false, dedupe: "aaaa000011112222" });
  assertEquals((await c.read(week)).planned, 4);
  assert(!p1.ok, "15 of 15 used this week: the plan is recorded but would not fit");
  assert(!(await c.reserve({ ...week, n: 6, threshold: 15, live: false, dedupe: "bbbb000011112222" })).ok);
  assertEquals(await c.read(week), { live: 15, planned: 10 });
  // Release gives a live reservation back.
  const r = await c.reserve({ ...key, windowSeconds: 0, n: 1, threshold: null, live: true });
  await c.release(r.id!);
  assertEquals((await c.read({ ...key, windowSeconds: 0 })).live, 25);
});
