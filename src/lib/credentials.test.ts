// Developer-platform credentials (supabase/functions/_shared/api/credentials.ts)
// against the SQL that enforces them (mig 20261031130500): the role -> scope
// map must equal exos_role_token_scopes(), and the redirect URI rule
// _exos_redirect_uri_ok(). docs/developer-platform.md.

import { readFileSync } from 'node:fs';
import path from 'node:path';
import { describe, expect, it } from 'vitest';
import {
  type AuthorizeParse, basicCredentials, bearerKind, CHALLENGE_RE, ORG_ROLES, parseAuthorizeQuery, randomVerifier, redirectUriProblem,
  ROLE_SCOPES, s256, scopeList, scopesForRole, tokenKind, validState, validVerifier, withParams,
} from '../../supabase/functions/_shared/api/credentials.ts';
import { SCOPES } from '../../supabase/functions/_shared/api/scopes.ts';

const MIGRATION = path.resolve(__dirname, '../../supabase/migrations/20261031130500_exos_developer_platform.sql');

function sqlRoleScopes(): Record<string, string[]> {
  const sql = readFileSync(MIGRATION, 'utf8');
  const fn = /FUNCTION public\.exos_role_token_scopes\(p_role text\)[\s\S]*?SELECT CASE p_role([\s\S]*?)ELSE ARRAY/.exec(sql);
  if (!fn) throw new Error('exos_role_token_scopes() not found in the migration');
  const out: Record<string, string[]> = {};
  for (const m of fn[1].matchAll(/WHEN '([a-z]+)' THEN ARRAY\[([\s\S]*?)\]/g)) {
    out[m[1]] = [...m[2].matchAll(/'([^']+)'/g)].map((x) => x[1]);
  }
  return out;
}

describe('role scopes', () => {
  it('ROLE_SCOPES equals exos_role_token_scopes() in the migration', () => {
    const sql = sqlRoleScopes();
    expect(Object.keys(sql).sort()).toEqual([...ORG_ROLES].sort());
    for (const r of ORG_ROLES) expect(sql[r], r).toEqual([...ROLE_SCOPES[r]]);
  });

  it('owner has every scope; only the owner has org:admin and webhooks', () => {
    expect([...ROLE_SCOPES.owner]).toEqual([...SCOPES]);
    for (const r of ORG_ROLES.filter((x) => x !== 'owner')) {
      expect(ROLE_SCOPES[r].some((s) => s === 'org:admin' || s.startsWith('webhooks:')), r).toBe(false);
    }
  });

  it('narrows a token to the live role; a write the role lacks keeps its read', () => {
    expect(scopesForRole(['events:write', 'orders:read', 'org:admin'], 'owner')).toEqual(['events:read', 'events:write', 'orders:read', 'org:admin']);
    expect(scopesForRole(['events:write', 'orders:read', 'org:admin'], 'scanner')).toEqual(['events:read']);
    expect(scopesForRole(['tickets:write'], 'scanner')).toEqual(['tickets:read']);
    expect(scopesForRole(['events:read'], 'nobody')).toEqual([]);
    expect(scopesForRole(['events:read'], null)).toEqual([]);
  });
});

describe('token formats', () => {
  const b43 = 'A'.repeat(43);
  it('tells credentials apart by prefix and shape', () => {
    expect(tokenKind(`exos_pat_${b43}`)).toBe('pat');
    expect(tokenKind(`exos_oat_${b43}`)).toBe('access');
    expect(tokenKind(`exos_ort_${b43}`)).toBe('refresh');
    expect(tokenKind(`dk_live_${'0'.repeat(48)}`)).toBe('partner');
    expect(tokenKind(`exos_pat_${b43}x`)).toBeNull();
    expect(bearerKind(`exos_pat_${b43}`)).toBe('pat');
    expect(bearerKind(`exos_oat_${b43}`)).toBe('oauth');
    expect(bearerKind(`sk_live_${'a'.repeat(48)}`)).toBe('api_key');
    // A refresh token or partner key is not a bearer credential for the API.
    expect(bearerKind(`exos_ort_${b43}`)).toBeNull();
    expect(bearerKind(`dk_live_${'0'.repeat(48)}`)).toBeNull();
  });
});

describe('PKCE', () => {
  it('S256 matches RFC 7636 appendix B', async () => {
    expect(await s256('dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk')).toBe('E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM');
  });

  it('validates verifiers and challenges', async () => {
    const v = randomVerifier();
    expect(validVerifier(v)).toBe(true);
    expect(CHALLENGE_RE.test(await s256(v))).toBe(true);
    expect(validVerifier('short')).toBe(false);
    expect(validVerifier('x'.repeat(129))).toBe(false);
    expect(validVerifier('has space' + 'x'.repeat(40))).toBe(false);
  });
});

describe('redirect URIs (same rule as _exos_redirect_uri_ok)', () => {
  it('allows https and loopback http', () => {
    for (const ok of ['https://app.example/cb', 'https://app.example:8443/oauth/cb?x=1', 'http://localhost:8765/cb',
      'http://127.0.0.1/cb', 'http://[::1]:9/cb', 'https://claude.ai/api/mcp/auth_callback']) {
      expect(redirectUriProblem(ok), ok).toBeNull();
    }
  });

  it('refuses everything else', () => {
    for (const bad of ['http://app.example/cb', 'https://a.example/cb#frag', 'https://*.example/cb', 'https://u:p@a.example/cb',
      'ftp://a.example', 'https://a.example/ cb', '', 'x'.repeat(501), 'javascript:alert(1)', 'http://localhost.evil.com/cb']) {
      expect(redirectUriProblem(bad), bad).not.toBeNull();
    }
  });

  it('keeps the redirect URI\'s own query when adding parameters', () => {
    expect(withParams('https://a.example/cb?x=1', { code: 'c', state: 's t', error: undefined }))
      .toBe('https://a.example/cb?x=1&code=c&state=s+t');
  });
});

describe('request parsing', () => {
  it('reads HTTP Basic client credentials', () => {
    expect(basicCredentials(`Basic ${btoa('exos_app_1:exos_cs_x%2By')}`)).toEqual({ id: 'exos_app_1', secret: 'exos_cs_x+y' });
    expect(basicCredentials('Bearer abc')).toBeNull();
    expect(basicCredentials(`Basic ${btoa('nocolon')}`)).toBeNull();
  });

  it('scope lists and state', () => {
    expect(scopeList('events:read  orders:read')).toEqual(['events:read', 'orders:read']);
    expect(scopeList(undefined)).toBeNull();
    expect(validState('abc-123')).toBe(true);
    expect(validState('a\u0000b')).toBe(false);
    expect(validState('x'.repeat(501))).toBe(false);
  });

  it('checks an authorization request before asking the database', () => {
    const client = 'exos_app_0123456789abcdef01234567';
    const q = (s: string) => new URLSearchParams(s);
    const good = parseAuthorizeQuery(q(`response_type=code&client_id=${client}&redirect_uri=https://a.example/cb&scope=events:read&state=xyz&code_challenge=${'A'.repeat(43)}&code_challenge_method=S256`));
    expect(good.ok && (good as Extract<AuthorizeParse, { ok: true }>).req.scope).toBe('events:read');
    const fail = (s: string) => {
      const r = parseAuthorizeQuery(q(s));
      if (r.ok) throw new Error(`accepted: ${s}`);
      return r as Extract<AuthorizeParse, { ok: false }>;
    };
    expect(fail('response_type=code&client_id=bad&redirect_uri=https://a.example/cb').redirect).toBe(false);
    expect(fail(`response_type=code&client_id=${client}&redirect_uri=http://evil.example/cb`).error).toBe('invalid_redirect_uri');
    const plain = fail(`response_type=code&client_id=${client}&redirect_uri=https://a.example/cb&code_challenge=abc&code_challenge_method=plain`);
    expect([plain.redirect, plain.error]).toEqual([true, 'invalid_request']);
    expect(fail(`response_type=token&client_id=${client}&redirect_uri=https://a.example/cb`).error).toBe('unsupported_response_type');
  });
});
