// deno test supabase/functions/_shared/mcp/discovery_test.ts
import { assert, assertEquals, assertMatch } from "jsr:@std/assert@1";
import {
  challenge, isOrganizerPath, mcpResource, newConfirmToken, ORGANIZER_SCOPES, protectedResource, tokenAudience,
} from "./discovery.ts";
import { CONFIRM_TOKEN_RE } from "./exosWriteTools.ts";
import { exosResources } from "../api/credentials.ts";

const SB = "https://abc.supabase.co/";
const MCP = "https://abc.supabase.co/functions/v1/exos-mcp/organizer";

Deno.test("the sign-in-required path", () => {
  assert(isOrganizerPath("/exos-mcp/organizer"));
  assert(isOrganizerPath("/functions/v1/exos-mcp/organizer/.well-known/oauth-protected-resource"));
  assert(!isOrganizerPath("/exos-mcp"));
  assert(!isOrganizerPath("/exos-mcp/organizers"));
});

Deno.test("one canonical resource: the organizer URL", () => {
  assertEquals(mcpResource(SB), MCP);
  assertEquals(exosResources(SB), { api: "https://abc.supabase.co/functions/v1/exos-api", mcp: MCP });
  const m = protectedResource(SB, undefined);
  assertEquals(m.resource, MCP);
  assertEquals(m.authorization_servers, ["https://abc.supabase.co/functions/v1/exos-oauth"]);
  assert(m.scopes_supported.includes("events:write"));
  assertEquals(protectedResource(SB, "https://auth.example.com").authorization_servers, ["https://auth.example.com"]);
});

Deno.test("the challenge points at the metadata and asks for the organizer scopes", () => {
  const c = challenge(SB);
  assert(c.startsWith(`Bearer realm="exos", resource_metadata="${MCP}/.well-known/oauth-protected-resource"`));
  assert(c.includes(`scope="${ORGANIZER_SCOPES.join(" ")}"`));
  assert(challenge(SB, "invalid_token").endsWith(', error="invalid_token"'));
});

Deno.test("an OAuth token's audience: exact, none (reads only) or another (refused)", () => {
  assertEquals(tokenAudience(MCP, SB), "ok");
  assertEquals(tokenAudience(null, SB), "none");
  assertEquals(tokenAudience("", SB), "none");
  assertEquals(tokenAudience(`${MCP}/`, SB), "other");
  assertEquals(tokenAudience("https://abc.supabase.co/functions/v1/exos-mcp", SB), "other");
  assertEquals(tokenAudience("https://abc.supabase.co/functions/v1/exos-api", SB), "other");
  assertEquals(tokenAudience("https://evil.example/mcp", SB), "other");
});

Deno.test("confirm tokens: the issued format, never the same twice", () => {
  const a = newConfirmToken();
  assertMatch(a, CONFIRM_TOKEN_RE);
  assert(a !== newConfirmToken());
});
