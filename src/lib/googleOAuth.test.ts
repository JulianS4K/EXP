import { describe, expect, it } from 'vitest';
import {
  buildCodeExchangeRequest, buildConsentUrl, buildRefreshRequest, createAccessTokenCache, DATA_MANAGER_SCOPE,
  GOOGLE_TOKEN_URL, googleOAuthConfig, hasDataManagerScope, isCallbackUrl, isStateShaped, newState,
  parseTokenResponse, postTokenRequest, returnAppUrl, scrub, settingsReturnUrl, stateHash, withBearer,
} from '../../supabase/functions/_shared/conversions/googleOAuth.ts';
import { ALLOWED_HOSTS } from '../../supabase/functions/_shared/conversions/common.ts';

const CB = 'https://p.supabase.co/functions/v1/exos-oauth-google/callback';
const CFG = { clientId: 'cid.apps.googleusercontent.com', clientSecret: 'GOCSPX-client-secret', redirectUri: CB };
const ORG = '0e000000-0000-4000-8000-000000000001';

const env = (m: Record<string, string>) => (k: string) => m[k];

describe('Google OAuth config', () => {
  it('needs the client id, secret and an https …/exos-oauth-google/callback redirect', () => {
    const full = { GOOGLE_OAUTH_CLIENT_ID: 'cid', GOOGLE_OAUTH_CLIENT_SECRET: 'sec', GOOGLE_OAUTH_REDIRECT_URI: CB };
    expect(googleOAuthConfig(env(full))).toEqual({ clientId: 'cid', clientSecret: 'sec', redirectUri: CB });
    expect(googleOAuthConfig(env({ ...full, GOOGLE_OAUTH_CLIENT_SECRET: '' }))).toBeNull();
    expect(googleOAuthConfig(env({ ...full, GOOGLE_OAUTH_REDIRECT_URI: '' }))).toBeNull();
    // The drain refreshes without a redirect URI.
    expect(googleOAuthConfig(env({ ...full, GOOGLE_OAUTH_REDIRECT_URI: '' }), false)).not.toBeNull();
    expect(googleOAuthConfig(env({}), false)).toBeNull();
  });

  it('accepts only a clean callback URL', () => {
    expect(isCallbackUrl(CB)).toBe(true);
    expect(isCallbackUrl('http://localhost:54321/functions/v1/exos-oauth-google/callback')).toBe(true);
    expect(isCallbackUrl('http://p.supabase.co/functions/v1/exos-oauth-google/callback')).toBe(false);
    expect(isCallbackUrl(`${CB}?x=1`)).toBe(false);
    expect(isCallbackUrl('https://p.supabase.co/functions/v1/exos-oauth-google/start')).toBe(false);
    expect(isCallbackUrl('https://u:p@p.supabase.co/functions/v1/exos-oauth-google/callback')).toBe(false);
  });

  it('sends the browser back only to an allow-listed EXOS_APP_URL', () => {
    expect(returnAppUrl('https://exos.example/bridge/', 'https://exos.example')).toBe('https://exos.example/bridge');
    expect(returnAppUrl('https://exos.example/bridge', 'https://other.example')).toBeNull();
    expect(returnAppUrl('https://exos.example/bridge', '')).toBeNull();
    expect(returnAppUrl('http://exos.example', 'http://exos.example')).toBeNull();
    expect(returnAppUrl(undefined, 'https://exos.example')).toBeNull();
  });

  it('builds the org settings return URL', () => {
    expect(settingsReturnUrl('https://exos.example/bridge/', ORG, { google_ads: 'finish', google_ads_state: 'abc' }))
      .toBe(`https://exos.example/bridge/orgs/${ORG}/settings?google_ads=finish&google_ads_state=abc`);
    expect(settingsReturnUrl('https://exos.example', null, { google_ads: 'error', reason: 'state' }))
      .toBe('https://exos.example/orgs?google_ads=error&reason=state');
    expect(settingsReturnUrl('https://exos.example', '../evil', { google_ads: 'error' }))
      .toBe('https://exos.example/orgs?google_ads=error');
  });
});

describe('state', () => {
  it('is 256 random bits, base64url, and hashed to 64 hex', async () => {
    const a = newState(), b = newState();
    expect(isStateShaped(a)).toBe(true);
    expect(a).not.toBe(b);
    expect(await stateHash(a)).toMatch(/^[0-9a-f]{64}$/);
    expect(await stateHash(a)).toBe(await stateHash(a));
  });

  it('refuses anything else before a lookup', () => {
    for (const bad of [undefined, null, '', 'short', 'x'.repeat(44), 'a'.repeat(42) + '/', 42]) {
      expect(isStateShaped(bad)).toBe(false);
    }
  });
});

describe('consent URL and token requests', () => {
  it('asks for offline access to the Data Manager scope, consent every time', () => {
    const u = new URL(buildConsentUrl(CFG, 'S'.repeat(43)));
    expect(u.origin + u.pathname).toBe('https://accounts.google.com/o/oauth2/v2/auth');
    expect(Object.fromEntries(u.searchParams)).toEqual({
      client_id: CFG.clientId, redirect_uri: CB, response_type: 'code',
      scope: 'https://www.googleapis.com/auth/datamanager', access_type: 'offline', prompt: 'consent',
      state: 'S'.repeat(43),
    });
  });

  it('exchanges a code with the registered redirect URI (form body, never the URL)', () => {
    const r = buildCodeExchangeRequest(CFG, '4/0Acode');
    expect(r.url).toBe(GOOGLE_TOKEN_URL);
    expect(r.headers['content-type']).toBe('application/x-www-form-urlencoded');
    expect(Object.fromEntries(new URLSearchParams(r.body))).toEqual({
      grant_type: 'authorization_code', code: '4/0Acode', client_id: CFG.clientId,
      client_secret: CFG.clientSecret, redirect_uri: CB,
    });
    expect(r.url).not.toContain('secret');
  });

  it('refreshes with grant_type=refresh_token', () => {
    const r = buildRefreshRequest(CFG, '1//refresh-token');
    expect(Object.fromEntries(new URLSearchParams(r.body))).toEqual({
      grant_type: 'refresh_token', refresh_token: '1//refresh-token',
      client_id: CFG.clientId, client_secret: CFG.clientSecret,
    });
    expect(ALLOWED_HOSTS.has(new URL(r.url).hostname)).toBe(true);
  });

  it('sorts the token answer', () => {
    expect(parseTokenResponse(200, { access_token: 'ya29.x', expires_in: 3599, refresh_token: '1//r', scope: DATA_MANAGER_SCOPE }))
      .toEqual({ ok: true, accessToken: 'ya29.x', expiresInSec: 3599, refreshToken: '1//r', scope: DATA_MANAGER_SCOPE });
    expect(parseTokenResponse(200, { access_token: 'ya29.x' })).toMatchObject({ ok: true, refreshToken: null, expiresInSec: 3600 });
    expect(parseTokenResponse(200, {})).toMatchObject({ ok: false, kind: 'bad' });
    expect(parseTokenResponse(400, { error: 'invalid_grant', error_description: 'Token has been expired or revoked.' }))
      .toEqual({ ok: false, kind: 'revoked', error: 'token http 400 invalid_grant: Token has been expired or revoked.' });
    expect(parseTokenResponse(401, { error: 'invalid_client' })).toMatchObject({ ok: false, kind: 'config' });
    expect(parseTokenResponse(503, null)).toMatchObject({ ok: false, kind: 'retry' });
    expect(parseTokenResponse(429, {})).toMatchObject({ ok: false, kind: 'retry' });
    expect(parseTokenResponse(400, { error: 'invalid_request' })).toMatchObject({ ok: false, kind: 'bad' });
  });

  it('checks the granted scope', () => {
    expect(hasDataManagerScope(`openid ${DATA_MANAGER_SCOPE}`)).toBe(true);
    expect(hasDataManagerScope('https://www.googleapis.com/auth/adwords')).toBe(false);
    expect(hasDataManagerScope('')).toBe(false);
  });
});

describe('postTokenRequest', () => {
  it('refuses a host outside the allow-list', async () => {
    let called = false;
    const r = await postTokenRequest({ ...buildRefreshRequest(CFG, 'rt'), url: 'https://evil.example/token' },
      async () => { called = true; return new Response('{}'); });
    expect(called).toBe(false);
    expect(r).toMatchObject({ ok: false, kind: 'config' });
  });

  it('treats a network failure as a retry', async () => {
    const r = await postTokenRequest(buildRefreshRequest(CFG, 'rt'), async () => { throw new Error('boom 1//rt'); });
    expect(r).toEqual({ ok: false, kind: 'retry', error: 'token request failed' });
  });
});

describe('drain access-token cache', () => {
  it('refreshes once per org per run and reuses the token', async () => {
    const calls: string[] = [];
    const fetchFn = async (_u: string, init: RequestInit) => {
      calls.push(String(init.body));
      return new Response(JSON.stringify({ access_token: `ya29.${calls.length}`, expires_in: 3600 }), { status: 200 });
    };
    const get = createAccessTokenCache(CFG, fetchFn);
    expect(await get('org-a', '1//a')).toEqual({ ok: true, accessToken: 'ya29.1' });
    expect(await get('org-a', '1//a')).toEqual({ ok: true, accessToken: 'ya29.1' });
    expect(await get('org-b', '1//b')).toEqual({ ok: true, accessToken: 'ya29.2' });
    expect(calls).toHaveLength(2);
    expect(calls[0]).toContain('grant_type=refresh_token');
  });

  it('refreshes again once the token is about to expire', async () => {
    let t = 0, n = 0;
    const get = createAccessTokenCache(CFG, async () => {
      n++;
      return new Response(JSON.stringify({ access_token: `ya29.${n}`, expires_in: 120 }), { status: 200 });
    }, () => t);
    expect(await get('o', 'r1234')).toEqual({ ok: true, accessToken: 'ya29.1' });
    t = 30_000;
    expect(await get('o', 'r1234')).toEqual({ ok: true, accessToken: 'ya29.1' });
    t = 61_000; // 120 s minus the 60 s slack
    expect(await get('o', 'r1234')).toEqual({ ok: true, accessToken: 'ya29.2' });
  });

  it('caches a revoked token as a failure and keeps secrets out of the error', async () => {
    let n = 0;
    const get = createAccessTokenCache(CFG, async () => {
      n++;
      return new Response(JSON.stringify({ error: 'invalid_grant', error_description: 'bad 1//dead-token for GOCSPX-client-secret' }), { status: 400 });
    });
    const r = await get('o', '1//dead-token');
    expect(r).toMatchObject({ ok: false, kind: 'revoked' });
    const err = (r as { error: string }).error;
    expect(err).not.toContain('1//dead-token');
    expect(err).not.toContain('GOCSPX-client-secret');
    await get('o', '1//dead-token');
    expect(n).toBe(1);
  });

  it('puts the access token in the Authorization header only', () => {
    const req = { method: 'POST' as const, url: 'https://datamanager.googleapis.com/v1/events:ingest',
      headers: { 'content-type': 'application/json', Authorization: 'Bearer <oauth access token>' }, body: { a: 1 } };
    const out = withBearer(req, 'ya29.live');
    expect(out.headers.Authorization).toBe('Bearer ya29.live');
    expect(req.headers.Authorization).toBe('Bearer <oauth access token>');
    expect(out.body).toEqual({ a: 1 });
    expect(scrub('x ya29.live y', ['ya29.live', null])).toBe('x [redacted] y');
  });
});
