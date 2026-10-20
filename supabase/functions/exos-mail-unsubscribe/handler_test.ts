// deno test supabase/functions/exos-mail-unsubscribe/handler_test.ts
import { handleUnsubscribe } from "./handler.ts";
import { oneClickUnsubscribeUrl, renderMail } from "../_shared/mail-render.ts";

function check(cond: boolean, msg: string) {
  if (!cond) throw new Error(msg);
}

const T = "a".repeat(64);
const BASE = "https://proj.supabase.co/functions/v1/exos-mail-unsubscribe";

function deps(appUrl: string | null = "https://exos.example/bridge", fail = false) {
  const calls: string[] = [];
  return {
    calls,
    d: {
      appUrl,
      unsubscribe: (t: string) => {
        calls.push(t);
        return fail ? Promise.reject(new Error("db down")) : Promise.resolve();
      },
    },
  };
}

Deno.test("one-click POST unsubscribes", async () => {
  const { calls, d } = deps();
  const res = await handleUnsubscribe(new Request(`${BASE}?t=${T}`, {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded" },
    body: "List-Unsubscribe=One-Click",
  }), d);
  check(res.status === 200, `status ${res.status}`);
  check(calls.length === 1 && calls[0] === T, "rpc called with the token");
});

Deno.test("GET never unsubscribes: redirects to the app page", async () => {
  const { calls, d } = deps();
  const res = await handleUnsubscribe(new Request(`${BASE}?t=${T}`), d);
  check(res.status === 303, `status ${res.status}`);
  check(res.headers.get("location") === `https://exos.example/bridge/unsubscribe?t=${T}`, "location");
  check(calls.length === 0, "no unsubscribe on GET");
  const { calls: c2, d: d2 } = deps(null);
  const page = await handleUnsubscribe(new Request(`${BASE}?t=${T}`), d2);
  check(page.status === 200 && (await page.text()).includes('method="post"'), "form fallback without an app URL");
  check(c2.length === 0, "no unsubscribe on GET (fallback)");
});

Deno.test("bad tokens, other methods and database errors", async () => {
  const { calls, d } = deps();
  check((await handleUnsubscribe(new Request(`${BASE}?t=nope`, { method: "POST" }), d)).status === 400, "bad token");
  check((await handleUnsubscribe(new Request(BASE, { method: "POST" }), d)).status === 400, "no token");
  check((await handleUnsubscribe(new Request(`${BASE}?t=${T}`, { method: "PUT" }), d)).status === 405, "PUT");
  check(calls.length === 0, "nothing called");
  const { d: bad } = deps("https://exos.example", true);
  check((await handleUnsubscribe(new Request(`${BASE}?t=${T}`, { method: "POST" }), bad)).status === 503, "retryable on db error");
});

Deno.test("marketing mail carries List-Unsubscribe-Post pointing here", () => {
  const one = oneClickUnsubscribeUrl("https://proj.supabase.co/");
  check(one === BASE, `one-click url ${one}`);
  check(oneClickUnsubscribeUrl("http://proj.supabase.co") === null, "https only");
  const r = renderMail("<p>x</p>", `{{app_url}}/unsubscribe?t=${T}`, "https://exos.example", one);
  check("headers" in r, "rendered");
  if ("headers" in r) {
    check(r.headers["List-Unsubscribe"] === `<${BASE}?t=${T}>`, `header ${r.headers["List-Unsubscribe"]}`);
    check(r.headers["List-Unsubscribe-Post"] === "List-Unsubscribe=One-Click", "post header");
  }
});
