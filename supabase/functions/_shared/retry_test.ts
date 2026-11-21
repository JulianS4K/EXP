import { assertEquals, assertRejects } from "jsr:@std/assert@1";
import { backoffMs, nextWait, retryableStatus, retryAfterMs, retryingGetFetch, type RetryPolicy } from "./retry.ts";
import { ebGet } from "./eventbrite/client.ts";
import { lumaGuestsPage } from "./backends/luma.ts";

const quick = (waits: number[]): RetryPolicy => ({ maxRetries: 2, baseMs: 10, maxWaitMs: 1000, random: () => 1, sleep: (ms) => { waits.push(ms); return Promise.resolve(); } });

Deno.test("retry: what is retried, and how long it waits", () => {
  assertEquals([429, 500, 503, 0].map((s) => retryableStatus(s)), [true, true, true, true]);
  assertEquals([400, 401, 404, 409].map((s) => retryableStatus(s)), [false, false, false, false]);
  assertEquals(retryableStatus(0, "TIMEOUT"), false);                 // a timeout already took the budget
  assertEquals(retryAfterMs("2"), 2000);
  assertEquals(retryAfterMs(new Date(Date.now() + 3000).toUTCString())! <= 3000, true);
  assertEquals(retryAfterMs("soon"), null);
  assertEquals(backoffMs(1, null, () => 0), 250);                     // DICE's numbers, unchanged
  assertEquals(backoffMs(20, null, () => 1), 30_000);
  assertEquals(backoffMs(1, "120", () => 0), 30_000);
  const p = quick([]);
  assertEquals(nextWait(1, 503, undefined, null, p), 10);
  assertEquals(nextWait(2, 503, undefined, null, p), 20);
  assertEquals(nextWait(3, 503, undefined, null, p), null);           // out of retries
  assertEquals(nextWait(1, 429, undefined, "0.5", p), 500);           // Retry-After honoured
  assertEquals(nextWait(1, 429, undefined, "60", p), null);           // longer than the limit: stop
  assertEquals(nextWait(1, 404, undefined, null, p), null);
});

Deno.test("retry: retryingGetFetch retries GET only, honours Retry-After, rethrows a refusal", async () => {
  const waits: number[] = [];
  let n = 0;
  const f = ((_u: string, init?: RequestInit) => {
    n++;
    if (init?.method === "POST") return Promise.resolve(new Response("", { status: 503 }));
    return Promise.resolve(n < 3 ? new Response("", { status: 429, headers: { "retry-after": "0.1" } }) : new Response("ok", { status: 200 }));
  }) as typeof fetch;
  const rf = retryingGetFetch(f, quick(waits));
  assertEquals((await rf("https://x.test/a", { method: "GET" })).status, 200);
  assertEquals([n, waits], [3, [100, 100]]);
  n = 0;
  assertEquals((await rf("https://x.test/a", { method: "POST", body: "{}" })).status, 503);
  assertEquals(n, 1);                                                  // a POST is sent once
  // A network error (TypeError) is retried; anything else (an SSRF refusal) is not.
  let k = 0;
  const net = (() => { k++; return k === 1 ? Promise.reject(new TypeError("reset")) : Promise.resolve(new Response("", { status: 200 })); }) as typeof fetch;
  assertEquals((await retryingGetFetch(net, quick([]))("https://x.test/")).status, 200);
  let j = 0;
  const refused = (() => { j++; return Promise.reject(new Error("blocked")); }) as typeof fetch;
  await assertRejects(() => retryingGetFetch(refused, quick([]))("https://x.test/"), Error, "blocked");
  assertEquals(j, 1);
  // Luma's backend reads take the wrapped fetch: a 503 then the page.
  let l = 0;
  const luma = (() => { l++; return Promise.resolve(l === 1 ? new Response("", { status: 503 }) : new Response(JSON.stringify({ entries: [], has_more: false }), { status: 200 })); }) as typeof fetch;
  assertEquals((await lumaGuestsPage(retryingGetFetch(luma, quick([])), "k", "evt-Abcd1234", null)).status, 200);
});

Deno.test("retry: ebGet retries a 429 / 5xx with backoff, not a 401", async () => {
  const waits: number[] = [];
  let n = 0;
  const f = (() => {
    n++;
    return Promise.resolve(n === 1 ? new Response(JSON.stringify({ error: "HIT_RATE_LIMIT" }), { status: 429, headers: { "retry-after": "1" } })
      : n === 2 ? new Response("{}", { status: 500 }) : new Response(JSON.stringify({ id: "1" }), { status: 200 }));
  });
  const r = await ebGet<{ id: string }>(f, "TOKEN1234", "/users/me/", {}, quick(waits));
  assertEquals([r.ok, r.body?.id, n], [true, "1", 3]);
  assertEquals(waits, [1000, 20]);
  let m = 0;
  const auth = (() => { m++; return Promise.resolve(new Response(JSON.stringify({ error: "INVALID_AUTH" }), { status: 401 })); });
  const a = await ebGet(auth, "TOKEN1234", "/users/me/", {}, quick([]));
  assertEquals([a.error, m], ["INVALID_AUTH", 1]);
});
