// Deno tests for _shared/corsOrigins.ts: the native app's origins
// (EXOS_CORS_EXTRA_ORIGINS) are allowed for CORS only, and every redirect /
// return-URL / Turnstile check still refuses them.
import { assert, assertEquals } from "jsr:@std/assert@1";
import { corsAllowedOrigins, NATIVE_APP_ORIGINS, parseCorsExtraOrigins } from "./corsOrigins.ts";
import { isAllowedEmbedReturn, isAllowedRedirect, parseRedirectOrigins } from "./redirects.ts";
import { allowedHosts, verifyAnswer } from "./wroomJoin.ts";

const WEB = "https://exos-web.onrender.com";
const EXTRA = "capacitor://localhost, https://localhost";

Deno.test("CORS allows the native origins when listed", () => {
  const cors = corsAllowedOrigins(WEB, EXTRA);
  assert(cors.includes(WEB));
  assert(cors.includes("capacitor://localhost"));
  assert(cors.includes("https://localhost"));
  assert(!cors.includes("http://localhost"));
  // Not listed: the web app only.
  assertEquals(corsAllowedOrigins(WEB, undefined), [WEB]);
});

Deno.test("only the exact native origins are kept: no wildcard, no other host", () => {
  assertEquals(
    parseCorsExtraOrigins("*, https://*.example.com, https://evil.example, capacitor://localhost/, http://localhost:8080, null, http://localhost"),
    ["http://localhost"],
  );
  assertEquals(parseCorsExtraOrigins(NATIVE_APP_ORIGINS.join(",")), [...NATIVE_APP_ORIGINS]);
  assertEquals(parseCorsExtraOrigins(""), []);
});

Deno.test("redirect, return-URL and Turnstile checks never see the CORS extras", () => {
  const env: Record<string, string> = { EXOS_REDIRECT_ORIGINS: WEB, EXOS_CORS_EXTRA_ORIGINS: EXTRA };
  const redirect = parseRedirectOrigins(env.EXOS_REDIRECT_ORIGINS);
  for (const url of ["https://localhost/my-tickets", "capacitor://localhost/my-tickets", "http://localhost/my-tickets"]) {
    assert(!isAllowedRedirect(url, redirect), url);
  }
  assert(!isAllowedEmbedReturn("https://localhost/embed/return", redirect));
  assert(isAllowedRedirect(`${WEB}/bridge/my-tickets`, redirect));
  // The waiting room's Turnstile hostnames.
  assertEquals(allowedHosts((n) => env[n]), ["exos-web.onrender.com"]);
});

Deno.test("loopback and non-https entries are ignored even when configured", () => {
  const env: Record<string, string> = {
    EXOS_REDIRECT_ORIGINS: `${WEB},https://localhost,http://localhost:3000,https://127.0.0.1,https://[::1],https://x.localhost,http://plain.example`,
    EXOS_APP_URL: "http://localhost:5173/bridge",
  };
  const redirect = parseRedirectOrigins(env.EXOS_REDIRECT_ORIGINS);
  for (const url of ["https://localhost/x", "http://localhost:3000/x", "https://127.0.0.1/x", "https://[::1]/x", "https://x.localhost/x", "http://plain.example/x"]) {
    assert(!isAllowedRedirect(url, redirect), url);
  }
  assert(!isAllowedEmbedReturn("https://localhost/embed/return", redirect));
  assertEquals(allowedHosts((n) => env[n]), ["exos-web.onrender.com"]);
  // The worst case: a web view's "localhost" answer, even with localhost on the list.
  const ok = { success: true, action: "wroom", hostname: "localhost" };
  assertEquals(verifyAnswer(ok, ["localhost", "exos-web.onrender.com"], () => {}), false);
  assertEquals(verifyAnswer({ ...ok, hostname: "127.0.0.1" }, ["127.0.0.1"], () => {}), false);
  assertEquals(verifyAnswer({ ...ok, hostname: "exos-web.onrender.com" }, ["exos-web.onrender.com"], () => {}), true);
});

Deno.test("no function reads EXOS_CORS_EXTRA_ORIGINS outside a CORS answer", async () => {
  const root = new URL("../", import.meta.url);
  const readers: string[] = [];
  for await (const dir of Deno.readDir(root)) {
    if (!dir.isDirectory) continue;
    for await (const f of Deno.readDir(new URL(`${dir.name}/`, root))) {
      if (!f.isFile || !f.name.endsWith(".ts") || f.name.endsWith("_test.ts")) continue;
      const src = await Deno.readTextFile(new URL(`${dir.name}/${f.name}`, root));
      if (!src.includes("EXOS_CORS_EXTRA_ORIGINS")) continue;
      if (dir.name === "_shared" && f.name === "corsOrigins.ts") continue;
      readers.push(`${dir.name}/${f.name}`);
      // Each use is the CORS line, inside corsHeaders, and nothing else.
      for (const line of src.split("\n").filter((l) => l.includes("EXOS_CORS_EXTRA_ORIGINS"))) {
        assert(/corsAllowedOrigins\(/.test(line), `${dir.name}/${f.name}: ${line.trim()}`);
      }
      const body = src.slice(src.indexOf("function corsHeaders("));
      assert(body.indexOf("EXOS_CORS_EXTRA_ORIGINS") < body.indexOf("\n}\n"), `${dir.name}/${f.name}: outside corsHeaders`);
    }
  }
  assertEquals(readers.sort(), [
    "exos-channel-sync/index.ts", "exos-dice-import/index.ts", "exos-discord/index.ts", "exos-event-import/index.ts",
    "exos-eventbrite-oauth/index.ts", "exos-eventbrite-sync/index.ts", "exos-instant-payouts/index.ts",
    "exos-integrations/index.ts", "exos-oauth-google/index.ts", "exos-promoter-payouts/index.ts",
  ]);
});
