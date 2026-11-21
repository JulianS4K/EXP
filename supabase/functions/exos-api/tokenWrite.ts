// claude/exos-mcp-writes (mig 20261119130000): exos_api_write's arguments for a
// personal or OAuth token write from exos-api. No imports, so it is unit-tested
// on its own (tokenWrite_test.ts).

export interface TokenWriteCtx {
  idempotencyKey: string | null;
  tokenHash?: string;
  credKind?: "api_key" | "pat" | "oauth";
  tokenOrg?: string | null;
  /** exos-api's own canonical URL (exosResources().api), never the token's resource. */
  callerResource?: string | null;
}

/** exos_api_write's arguments for a personal or OAuth token write. p_token_resource
 * is the caller's own URL (c.callerResource), so an OAuth token issued for
 * another resource (exos-mcp's, say) is refused in SQL. Exported for tests. */
export function tokenWriteArgs(
  c: TokenWriteCtx,
  action: string, target: string | null, args: Record<string, unknown>,
): Record<string, unknown> {
  return {
    p_key_id: null, p_action: action, p_target: target, p_args: args, p_idempotency_key: c.idempotencyKey,
    p_token_hash: c.tokenHash, p_token_kind: c.credKind, p_token_org: c.tokenOrg ?? null,
    p_source: "api", p_token_resource: c.credKind === "oauth" ? c.callerResource ?? null : null,
  };
}

