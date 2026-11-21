// exos-mcp's OAuth discovery (docs/mcp.md "Sign in with OAuth"): RFC 9728
// protected-resource metadata, the WWW-Authenticate challenge that starts a
// connector's sign-in, the audience check on OAuth tokens (RFC 8707), and the
// write tools' confirm tokens. Pure (web crypto only), so Deno tests and
// vitest both import it.
//
// exos-mcp's ONE canonical resource is its organizer URL
// (…/functions/v1/exos-mcp/organizer, exosResources().mcp). An OAuth token is
// for exos-mcp only when its resource is exactly that; a token that named no
// resource may read, never write; any other resource is refused.

import { exosResources } from '../api/credentials.ts';

/** The scopes the organizer tools use: what a connector asks for at sign-in. */
export const ORGANIZER_SCOPES = ['events:read', 'events:write', 'orders:read', 'tickets:read'] as const;

/** …/exos-mcp/organizer: the sign-in-required URL (no token = 401 + challenge). */
export function isOrganizerPath(pathname: string): boolean {
  return /\/exos-mcp\/organizer(?:\/|$)/.test(pathname);
}

/** exos-mcp's canonical resource URL. */
export function mcpResource(supabaseUrl: string): string {
  return exosResources(supabaseUrl).mcp;
}

/** RFC 9728 metadata, served at the canonical resource's well-known path only. */
export function protectedResource(supabaseUrl: string, issuer: string | undefined) {
  const base = supabaseUrl.replace(/\/+$/, '');
  return {
    resource: mcpResource(supabaseUrl),
    authorization_servers: [issuer || `${base}/functions/v1/exos-oauth`],
    bearer_methods_supported: ['header'],
    scopes_supported: [...ORGANIZER_SCOPES],
    resource_name: 'Exos',
  };
}

/** The WWW-Authenticate value on a 401: where the metadata is, and what to ask for. */
export function challenge(supabaseUrl: string, error?: 'invalid_token'): string {
  return `Bearer realm="exos", resource_metadata="${mcpResource(supabaseUrl)}/.well-known/oauth-protected-resource", ` +
    `scope="${ORGANIZER_SCOPES.join(' ')}"${error ? `, error="${error}"` : ''}`;
}

/**
 * An OAuth token's audience: `ok` (issued for exos-mcp exactly: reads and
 * writes), `none` (named no resource: reads only), `other` (refused).
 */
export function tokenAudience(resource: string | null | undefined, supabaseUrl: string): 'ok' | 'none' | 'other' {
  if (resource === null || resource === undefined || resource === '') return 'none';
  return resource === mcpResource(supabaseUrl) ? 'ok' : 'other';
}

/** A new confirm token for the write tools: exos_mcc_ + 32 random bytes, base64url. */
export function newConfirmToken(): string {
  const bytes = crypto.getRandomValues(new Uint8Array(32));
  return `exos_mcc_${btoa(String.fromCharCode(...bytes)).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '')}`;
}
