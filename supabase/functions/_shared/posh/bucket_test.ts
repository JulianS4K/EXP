import { assertEquals, assertNotEquals } from "jsr:@std/assert@1";
import { callerNetwork, POSH_PER_MINUTE, POSH_UNKNOWN_PER_MINUTE, poshRateBucket } from "./bucket.ts";

const hdr = (h: Record<string, string>) => (name: string) => h[name] ?? null;
const HASH_A = "a".repeat(64);
const HASH_B = "b".repeat(64);

Deno.test("posh: a known hook is limited per URL", async () => {
  assertEquals(await poshRateBucket(HASH_A, true, hdr({ "cf-connecting-ip": "203.0.113.9" })), { bucket: `posh:${"a".repeat(40)}`, limit: POSH_PER_MINUTE });
});

Deno.test("posh: unknown tokens share their caller network's bucket, whatever the token", async () => {
  const one = await poshRateBucket(HASH_A, false, hdr({ "cf-connecting-ip": "203.0.113.9" }));
  const two = await poshRateBucket(HASH_B, false, hdr({ "cf-connecting-ip": "203.0.113.77" }));
  assertEquals(one, two);                                   // same /24, different tokens: one row
  assertEquals(one.limit, POSH_UNKNOWN_PER_MINUTE);
  assertEquals(one.bucket.startsWith("posh-unknown:"), true);
  assertEquals(one.bucket.includes("a".repeat(10)), false); // not keyed by the token
  const other = await poshRateBucket(HASH_A, false, hdr({ "cf-connecting-ip": "198.51.100.1" }));
  assertNotEquals(other.bucket, one.bucket);
  assertEquals(callerNetwork("2001:db8:abcd:12::1"), "2001:db8:abcd::/48");
  assertEquals(callerNetwork("unknown"), "unknown");
  // No IP header at all: one shared bucket, never skipped.
  const none = await poshRateBucket(HASH_B, false, hdr({}));
  assertEquals(none.bucket.length > 20, true);
});
