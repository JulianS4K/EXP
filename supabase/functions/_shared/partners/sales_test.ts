import { assertEquals } from "jsr:@std/assert@1";
import { presentedPartnerKey } from "./sales.ts";

const hdr = (h: Record<string, string>) => (name: string) => h[name] ?? null;

Deno.test("partner key: a header wins over ?shared_key=, which still works alone", () => {
  const q = new URLSearchParams("shared_key=dk_live_query");
  assertEquals(presentedPartnerKey(q, hdr({ "x-shared-key": "dk_live_header" })), "dk_live_header");
  assertEquals(presentedPartnerKey(q, hdr({ authorization: "Bearer dk_live_bearer" })), "dk_live_bearer");
  assertEquals(presentedPartnerKey(q, hdr({})), "dk_live_query");
  assertEquals(presentedPartnerKey(new URLSearchParams(), hdr({})), "");
});
