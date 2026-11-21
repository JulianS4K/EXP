// deno test supabase/functions/_shared/mcp/discovery_test.ts
import { assert, assertEquals, assertMatch } from "jsr:@std/assert@1";
import {
  challenge, isOrganizerPath, mcpResources, newConfirmToken, ORGANIZER_SCOPES, protectedResource, tokenResourceOk,
} from "./discovery.ts";
import { CONFIRM_TOKEN_RE } from "./exosWriteTools.ts";

const SB = "https://abc.supabase.co/";

Deno.test("the sign-in-required path", () => {
  assert(isOrganizerPath("/exos-mcp/organizer"));
  assert(isOrganizerPath("/functions/v1/exos-mcp/organizer/.well-known/oauth-protected-resource"));
  assert(!isOrganizerPath("/exos-mcp"));
  assert(!isOrganizerPath("/exos-mcp/organizers"));
});

Deno.test("protected-resource metadata names the right resource and the write scope", () => {
  assertEquals(mcpResources(SB), ["https://abc.supabase.co/functions/v1/exos-mcp", "https://abc.supabase.co/functions/v1/exos-mcp/organizer"]);
  const m = protectedResource(SB, undefined, true);
  assertEquals(m.resource, "https://abc.supabase.co/functions/v1/exos-mcp/organizer");
  assertEquals(m.authorization_servers, ["https://abc.supabase.co/functions/v1/exos-oauth"]);
  assert(m.scopes_supported.includes("events:write"));
  assertEquals(protectedResource(SB, "https://auth.example.com", false).authorization_servers, ["https://auth.example.com"]);
});

Deno.test("the challenge points at the metadata and asks for the organizer scopes", () => {
  const c = challenge(SB, true);
  assertMatch(c, /^Bearer realm="exos", resource_metadata="https:\/\/abc\.supabase\.co\/functions\/v1\/exos-mcp\/organizer\/\.well-known\/oauth-protected-resource"/);
  assert(c.includes(`scope="${ORGANIZER_SCOPES.join(" ")}"`));
  assert(challenge(SB, false, "invalid_token").endsWith(', error="invalid_token"'));
});

Deno.test("an OAuth token for another resource is not ours", () => {
  assert(tokenResourceOk(null, SB));
  assert(tokenResourceOk("https://abc.supabase.co/functions/v1/exos-mcp/", SB));
  assert(tokenResourceOk("https://abc.supabase.co/functions/v1/exos-mcp/organizer", SB));
  assert(!tokenResourceOk("https://abc.supabase.co/functions/v1/exos-api", SB));
  assert(!tokenResourceOk("https://evil.example.com/functions/v1/exos-mcp", SB));
});

Deno.test("confirm tokens: the issued format, never the same twice", () => {
  const a = newConfirmToken();
  assertMatch(a, CONFIRM_TOKEN_RE);
  assert(a !== newConfirmToken());
});
