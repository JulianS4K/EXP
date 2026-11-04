// Credentials of the developer platform (docs/developer-platform.md): token
// formats, the role -> scope map, PKCE, redirect URI rules and OAuth request
// parsing. Shared by exos-api, exos-mcp, exos-oauth and the SPA.
//
// The SQL side (mig 20261031130500) mints and checks every token; this file
// recognises them before any lookup, and mirrors two rules the SQL also
// enforces so the UI can explain them first:
//   * ROLE_SCOPES = exos_role_token_scopes(role)  (src/lib/credentials.test.ts)
//   * redirectUriProblem() = _exos_redirect_uri_ok()
//
// Pure TypeScript (Web Crypto only), imported by vitest.

import { SCOPES, type Scope } from './scopes.ts';

/** Every credential is a prefix plus 43 base64url characters (256 random bits). */
export const TOKEN_PREFIX = {
  api_key: 'sk_live_',
  pat: 'exos_pat_',
  access: 'exos_oat_',
  refresh: 'exos_ort_',
  code: 'exos_oac_',
  secret: 'exos_cs_',
  partner: 'dk_live_',
} as const;

const B43 = '[A-Za-z0-9_-]{43}';
export const TOKEN_RE = {
  api_key: /^sk_live_[0-9a-f]{48}$/,
  pat: new RegExp(`^exos_pat_${B43}$`),
  access: new RegExp(`^exos_oat_${B43}$`),
  refresh: new RegExp(`^exos_ort_${B43}$`),
  code: new RegExp(`^exos_oac_${B43}$`),
  secret: new RegExp(`^exos_cs_${B43}$`),
  partner: /^dk_live_[0-9a-f]{48}$/,
} as const;
export type TokenKind = keyof typeof TOKEN_RE;

export const CLIENT_ID_RE = /^exos_app_[0-9a-f]{24}$/;

/** Which kind a bearer string is, by its prefix and shape; null when none of ours. */
export function tokenKind(token: string): TokenKind | null {
  for (const k of Object.keys(TOKEN_RE) as TokenKind[]) if (TOKEN_RE[k].test(token)) return k;
  return null;
}

/**
 * What a bearer credential on exos-api / exos-mcp is: an org API key, a
 * personal access token, an OAuth access token, or nothing we accept there.
 * Org API keys of any shape go to the old lookup (older keys).
 */
export function bearerKind(token: string): 'api_key' | 'pat' | 'oauth' | null {
  if (TOKEN_RE.pat.test(token)) return 'pat';
  if (TOKEN_RE.access.test(token)) return 'oauth';
  if (token.startsWith('sk_live_') && token.length <= 128) return 'api_key';
  return null;
}

// -- Roles ---------------------------------------------------------------------

export const ORG_ROLES = ['owner', 'manager', 'finance', 'content', 'scanner'] as const;
export type OrgRole = (typeof ORG_ROLES)[number];

/** The most a user in each role can grant a token (owner-only: webhooks and org admin). */
export const ROLE_SCOPES: Record<OrgRole, readonly Scope[]> = {
  owner: SCOPES,
  manager: [
    'events:read', 'events:write', 'orders:read', 'tickets:read', 'tickets:write', 'checkin:write',
    'booking:read', 'booking:write', 'finance:read', 'finance:write', 'commerce:read', 'commerce:write',
  ],
  finance: ['events:read', 'orders:read', 'tickets:read', 'booking:read', 'finance:read', 'finance:write', 'commerce:read'],
  content: ['events:read', 'events:write', 'booking:read'],
  scanner: ['events:read', 'tickets:read', 'checkin:write'],
};

export const ROLE_INFO: Record<OrgRole, string> = {
  owner: 'Everything, including organization settings, members, webhooks and partner keys.',
  manager: 'Events, orders, tickets, the door, booking, finance and commerce. Not webhooks or organization settings.',
  finance: 'Reads events, orders, tickets and booking; manages finance.',
  content: 'Edits events and reads booking.',
  scanner: 'Reads events and tickets and checks people in.',
};

export function roleScopes(role: string | null | undefined): readonly Scope[] {
  return role && (ORG_ROLES as readonly string[]).includes(role) ? ROLE_SCOPES[role as OrgRole] : [];
}

/**
 * A token's scopes narrowed to what `role` may use, in vocabulary order: kept
 * when the role has it; a :write the role lacks still gives its :read.
 * Same as _exos_scopes_for_role in SQL.
 */
export function scopesForRole(scopes: readonly string[], role: string | null | undefined): Scope[] {
  const allowed = roleScopes(role);
  return SCOPES.filter((s) => allowed.includes(s)
    && (scopes.includes(s) || (s.endsWith(':read') && scopes.includes(s.replace(/:read$/, ':write')))));
}

// -- PKCE (RFC 7636) ----------------------------------------------------------------

const VERIFIER_RE = /^[A-Za-z0-9\-._~]{43,128}$/;
export const CHALLENGE_RE = /^[A-Za-z0-9_-]{43}$/;

export function validVerifier(v: unknown): v is string {
  return typeof v === 'string' && VERIFIER_RE.test(v);
}

export function base64Url(bytes: Uint8Array): string {
  let s = '';
  for (const b of bytes) s += String.fromCharCode(b);
  return btoa(s).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

/** base64url(SHA-256(verifier)): the S256 challenge. */
export async function s256(verifier: string): Promise<string> {
  return base64Url(new Uint8Array(await crypto.subtle.digest('SHA-256', new TextEncoder().encode(verifier))));
}

export async function sha256Hex(s: string): Promise<string> {
  const buf = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(s));
  return [...new Uint8Array(buf)].map((b) => b.toString(16).padStart(2, '0')).join('');
}

/** A random verifier / state for clients (and the tests). */
export function randomVerifier(): string {
  return base64Url(crypto.getRandomValues(new Uint8Array(32)));
}

// -- Redirect URIs ---------------------------------------------------------------------

export const MAX_REDIRECT_URIS = 10;

/** Why a redirect URI can't be registered, or null. Mirrors _exos_redirect_uri_ok. */
export function redirectUriProblem(raw: unknown): string | null {
  if (typeof raw !== 'string' || !raw || raw.length > 500) return 'must be a URL of at most 500 characters';
  if (/\s/.test(raw)) return 'must not contain spaces';
  if (raw.includes('#')) return 'must not contain a fragment';
  if (raw.includes('*')) return 'must not contain wildcards';
  const https = /^https:\/\/[A-Za-z0-9.-]+(:[0-9]{1,5})?(\/[^?#]*)?(\?[^#]*)?$/.test(raw);
  const loopback = /^http:\/\/(localhost|127\.0\.0\.1|\[::1\])(:[0-9]{1,5})?(\/[^?#]*)?(\?[^#]*)?$/.test(raw);
  if (https || loopback) return null;
  if (/^https?:\/\/[^/]*@/.test(raw)) return 'must not contain credentials';
  return 'must be https (http is allowed only for localhost)';
}

/** Append OAuth response parameters to a redirect URI (keeps its own query). */
export function withParams(redirectUri: string, params: Record<string, string | undefined | null>): string {
  const u = new URL(redirectUri);
  for (const [k, v] of Object.entries(params)) if (v !== undefined && v !== null && v !== '') u.searchParams.set(k, v);
  return u.toString();
}

/** `state` is echoed back verbatim: printable ASCII, at most 500 characters. */
export function validState(state: unknown): boolean {
  return state === undefined || state === null || state === ''
    || (typeof state === 'string' && state.length <= 500 && /^[\x20-\x7E]+$/.test(state));
}

/** client_id / client_secret from HTTP Basic (RFC 6749 2.3.1, form-encoded parts). */
export function basicCredentials(header: string | null | undefined): { id: string; secret: string } | null {
  const m = /^Basic ([A-Za-z0-9+/=]+)$/i.exec(header ?? '');
  if (!m) return null;
  let decoded: string;
  try {
    decoded = atob(m[1]);
  } catch {
    return null;
  }
  const i = decoded.indexOf(':');
  if (i < 0) return null;
  try {
    return { id: decodeURIComponent(decoded.slice(0, i).replace(/\+/g, ' ')), secret: decodeURIComponent(decoded.slice(i + 1).replace(/\+/g, ' ')) };
  } catch {
    return null;
  }
}

/** The scope parameter as a list (space separated), or null when absent. */
export function scopeList(raw: unknown): string[] | null {
  if (raw === undefined || raw === null || raw === '') return null;
  if (typeof raw !== 'string') return [];
  return raw.split(/\s+/).filter(Boolean);
}

/** Parameters of an authorization request the consent page acts on. */
export interface AuthorizeRequest {
  clientId: string;
  redirectUri: string;
  scope: string;
  state: string;
  codeChallenge: string | null;
  codeChallengeMethod: string | null;
  resource: string | null;
}

export type AuthorizeParse =
  | { ok: true; req: AuthorizeRequest }
  /** `redirect`: the error may go back to the app (client and redirect URI look sane). */
  | { ok: false; error: string; description: string; redirect: boolean };

/**
 * Shape checks of /oauth/authorize's query, before the SQL checks the app.
 * Unsupported response types and PKCE methods go back to the app; a missing
 * client or redirect URI is shown on the page.
 */
export function parseAuthorizeQuery(q: URLSearchParams): AuthorizeParse {
  const clientId = q.get('client_id') ?? '';
  const redirectUri = q.get('redirect_uri') ?? '';
  if (!CLIENT_ID_RE.test(clientId)) return { ok: false, error: 'invalid_client', description: 'Unknown app.', redirect: false };
  if (redirectUriProblem(redirectUri)) {
    return { ok: false, error: 'invalid_redirect_uri', description: 'The redirect URI is not valid.', redirect: false };
  }
  const state = q.get('state') ?? '';
  if (!validState(state)) return { ok: false, error: 'invalid_request', description: 'state is not valid.', redirect: false };
  if (q.get('response_type') !== 'code') {
    return { ok: false, error: 'unsupported_response_type', description: 'Only response_type=code is supported.', redirect: true };
  }
  const challenge = q.get('code_challenge');
  const method = q.get('code_challenge_method');
  if (challenge !== null || method !== null) {
    if ((method ?? 'plain') !== 'S256') {
      return { ok: false, error: 'invalid_request', description: 'code_challenge_method must be S256.', redirect: true };
    }
    if (!challenge || !CHALLENGE_RE.test(challenge)) {
      return { ok: false, error: 'invalid_request', description: 'code_challenge must be a base64url SHA-256.', redirect: true };
    }
  }
  const resource = q.get('resource');
  if (resource !== null && (!/^https:\/\//.test(resource) || resource.length > 500)) {
    return { ok: false, error: 'invalid_target', description: 'resource must be an https URL.', redirect: true };
  }
  return {
    ok: true,
    req: {
      clientId, redirectUri, state, scope: (q.get('scope') ?? '').trim(),
      codeChallenge: challenge, codeChallengeMethod: method, resource,
    },
  };
}
