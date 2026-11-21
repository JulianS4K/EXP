// The SQL audience check (exos_api_write: p_token_resource must be an Exos
// resource AND equal the token's own) only works if exos-api sends the URL the
// call reached, not the token's claimed resource (Applier #129 pass 2, X1a).
import { assertEquals } from "jsr:@std/assert@1";
import { tokenWriteArgs } from "./tokenWrite.ts";

const API = "https://abc.supabase.co/functions/v1/exos-api";

Deno.test("an OAuth token write sends exos-api's own URL as the resource", () => {
  const a = tokenWriteArgs({ idempotencyKey: "k", tokenHash: "h", credKind: "oauth", tokenOrg: null, callerResource: API },
    "event.create", null, { name: "x" });
  assertEquals(a.p_token_resource, API);
  assertEquals(a.p_key_id, null);
  assertEquals(a.p_source, "api");
});

Deno.test("a PAT write sends no resource", () => {
  const a = tokenWriteArgs({ idempotencyKey: null, tokenHash: "h", credKind: "pat", callerResource: API }, "event.publish", "e", {});
  assertEquals(a.p_token_resource, null);
});

Deno.test("index.ts passes the caller URL, never the token's resource", async () => {
  const src = await Deno.readTextFile(new URL("./index.ts", import.meta.url));
  assertEquals(/callerResource:\s*exosResources\(/.test(src), true);
  assertEquals(/(tokenResource|callerResource):\s*c\.cred\.(kind[^,]*)?resource/.test(src), false);
  assertEquals(src.includes("c.cred.resource ?? null : null"), false);
});
