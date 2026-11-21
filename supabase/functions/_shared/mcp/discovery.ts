// exos-mcp's OAuth discovery (docs/mcp.md "Sign in with OAuth"): RFC 9728
// protected-resource metadata, the WWW-Authenticate challenge that starts a
// connector's sign-in, the resource check on OAuth tokens (RFC 8707), and the
// write tools' confirm tokens. Pure (web crypto only), so Deno tests and
// vitest both import it.

/** The scopes the organizer tools use: what a connector asks for at sign-in. */
export const ORGANIZER_SCOPES = ['events:read', 'events:write', 'orders:read', 'tickets:read'] as const;

/** …/exos-mcp/organizer: the sign-in-required URL (no token = 401 + challenge). */
export function isOrganizerPath(pathname: string): boolean {
  return /\/exos-mcp\/organizer(?:\/|$)/.test(pathname);
}

/** The MCP URLs a token may name as its resource: the server and its sign-in-required twin. */
export function mcpResources(supabaseUrl: string): [string, string] {
  const base = `${supabaseUrl.replace(/\/+$/, '')}/functions/v1/exos-mcp`;
  return [base, `${base}/organizer`];
}

/** RFC 9728 metadata for the server (or its /organizer twin). */
export function protectedResource(supabaseUrl: string, issuer: string | undefined, organizer: boolean) {
  const base = supabaseUrl.replace(/\/+$/, '');
  return {
    resource: mcpResources(supabaseUrl)[organizer ? 1 : 0],
    authorization_servers: [issuer || `${base}/functions/v1/exos-oauth`],
    bearer_methods_supported: ['header'],
    scopes_supported: [...ORGANIZER_SCOPES],
    resource_name: 'Exos',
  };
}

/** The WWW-Authenticate value on a 401: where the metadata is, and what to ask for. */
export function challenge(supabaseUrl: string, organizer: boolean, error?: 'invalid_token'): string {
  return `Bearer realm="exos", resource_metadata="${mcpResources(supabaseUrl)[organizer ? 1 : 0]}/.well-known/oauth-protected-resource", ` +
    `scope="${ORGANIZER_SCOPES.join(' ')}"${error ? `, error="${error}"` : ''}`;
}

/** An OAuth token's `resource` (RFC 8707): none, or one of this server's URLs. */
export function tokenResourceOk(resource: string | null | undefined, supabaseUrl: string): boolean {
  if (!resource) return true;
  return (mcpResources(supabaseUrl) as string[]).includes(resource.replace(/\/+$/, ''));
}

/** A new confirm token for the write tools: exos_mcc_ + 32 random bytes, base64url. */
export function newConfirmToken(): string {
  const bytes = crypto.getRandomValues(new Uint8Array(32));
  return `exos_mcc_${btoa(String.fromCharCode(...bytes)).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '')}`;
}
