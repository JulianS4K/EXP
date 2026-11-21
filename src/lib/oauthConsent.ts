// The OAuth consent screen's scope list (src/views/OAuthAuthorize.tsx,
// docs/developer-platform.md): what the app could SEE and, listed apart, what
// it could CHANGE. Write scopes can be unticked one by one; the approval asks
// for what is left (exos_oauth_authorize_approve narrows it to the role).

/** A scope that changes something (every `:write`, and org admin). */
export function isWriteScope(s: string): boolean {
  return s.endsWith(':write') || s === 'org:admin';
}

/** The requested scopes, split into reads and writes, in the order asked. */
export function splitConsentScopes(scopes: readonly string[]): { reads: string[]; writes: string[] } {
  const reads: string[] = [];
  const writes: string[] = [];
  for (const s of scopes) (isWriteScope(s) ? writes : reads).push(s);
  return { reads, writes };
}

/**
 * The scope string to approve: every requested read, and the writes the person
 * left ticked. Only scopes the request named; empty when nothing is left.
 */
export function approvedScope(requested: readonly string[], unticked: ReadonlySet<string>): string {
  return requested.filter((s) => !isWriteScope(s) || !unticked.has(s)).join(' ');
}
