import { assertEquals } from "jsr:@std/assert@1";
import { SOCIAL_OFF, socialEnvOn, socialOffFromError, socialOffGate } from "./socialGate.ts";

Deno.test("EXOS_SOCIAL: only 'on' turns it on; unset is off", () => {
  for (const v of [undefined, null, "", "off", "true", "1", "yes"]) assertEquals(socialEnvOn(v), false, String(v));
  for (const v of ["on", "ON", " on "]) assertEquals(socialEnvOn(v), true, v);
});

Deno.test("the gate answers 403 social_off while off, nothing while on", () => {
  assertEquals(socialOffGate(undefined), { status: 403, body: { error: "This feature isn't available", reason: "social_off" } });
  assertEquals(socialOffGate("off")?.status, 403);
  assertEquals(socialOffGate("on"), null);
});

Deno.test("the SQL switch's XSOFF maps to the same 403; other errors don't", () => {
  assertEquals(socialOffFromError({ code: "XSOFF" }), { status: 403, body: { ...SOCIAL_OFF } });
  assertEquals(socialOffFromError({ code: "42501" }), null);
  assertEquals(socialOffFromError(null), null);
});

Deno.test("exos-match checks EXOS_SOCIAL before the JWT, the body or any RPC on /run", async () => {
  const src = await Deno.readTextFile(new URL("../exos-match/index.ts", import.meta.url));
  const run = src.indexOf('if (route === "run" || route === "exos-match") {');
  const gate = src.indexOf('socialOffGate(Deno.env.get("EXOS_SOCIAL"))', run);
  const auth = src.indexOf("auth.getUser()", run);
  const body = src.indexOf("readBody(req)", run);
  const rpc = src.indexOf("matchTier(", run);
  assertEquals(run > 0 && gate > run, true, "the gate is in /run");
  assertEquals(gate < auth && gate < body && gate < rpc, true, "the gate comes first");
  // The cron route has no gate: existing matched types keep being grouped.
  const cron = src.indexOf('if (route === "cron") {');
  assertEquals(src.slice(cron, run).includes("socialOffGate"), false, "the cron runs either way");
});
