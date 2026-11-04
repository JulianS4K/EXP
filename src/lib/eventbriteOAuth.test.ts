import { describe, expect, it, vi } from 'vitest';
import {
  EB_AUTHORIZE_URL, EB_TOKEN_URL, buildAuthorizeUrl, buildCodeExchangeRequest, callbackErrorReason,
  eventbriteOAuthConfig, integrationsReturnUrl, isCallbackUrl, isStateShaped, newState, parseTokenResponse,
  postTokenRequest, returnAppUrl, stateHash,
} from '../../supabase/functions/_shared/eventbrite/oauth.ts';
import {
  authMethodLabel, eventPickPath, eventbriteErrorMessage, isEventbriteAuthorizeUrl, wantsEventbritePick,
} from './eventbriteConnect';
import { parseEventbriteOrgStatus, parseEventbriteStatus } from './door/eventbrite';

vi.mock('./supabase', () => ({ supabase: {} }));

const ORG = '11111111-2222-4333-8444-555555555555';
const EVT = '66666666-7777-4888-9999-aaaaaaaaaaaa';
const CB = 'https://proj.supabase.co/functions/v1/exos-eventbrite-oauth/callback';
const env = (m: Record<string, string>) => (k: string) => m[k];
const CFG = { clientId: 'APIKEY123', clientSecret: 'SECRET-xyz', redirectUri: CB };

describe('Eventbrite OAuth config', () => {
  it('is off without the client id or secret (the private-token path stays)', () => {
    expect(eventbriteOAuthConfig(env({ SUPABASE_URL: 'https://proj.supabase.co' }))).toBeNull();
    expect(eventbriteOAuthConfig(env({ EXOS_EVENTBRITE_CLIENT_ID: 'APIKEY123', SUPABASE_URL: 'https://proj.supabase.co' }))).toBeNull();
    expect(eventbriteOAuthConfig(env({ EXOS_EVENTBRITE_CLIENT_SECRET: 's', SUPABASE_URL: 'https://proj.supabase.co' }))).toBeNull();
  });

  it('defaults the redirect URI to this function under SUPABASE_URL', () => {
    expect(eventbriteOAuthConfig(env({
      EXOS_EVENTBRITE_CLIENT_ID: ' APIKEY123 ', EXOS_EVENTBRITE_CLIENT_SECRET: 'SECRET-xyz', SUPABASE_URL: 'https://proj.supabase.co/',
    }))).toEqual(CFG);
  });

  it('takes an explicit redirect URI only if it is this callback', () => {
    const base = { EXOS_EVENTBRITE_CLIENT_ID: 'APIKEY123', EXOS_EVENTBRITE_CLIENT_SECRET: 's', SUPABASE_URL: 'https://proj.supabase.co' };
    expect(eventbriteOAuthConfig(env({ ...base, EXOS_EVENTBRITE_REDIRECT_URI: 'https://evil.example/steal' }))).toBeNull();
    expect(eventbriteOAuthConfig(env({ ...base, EXOS_EVENTBRITE_REDIRECT_URI: 'https://x.example/functions/v1/exos-eventbrite-oauth/callback' }))?.redirectUri)
      .toBe('https://x.example/functions/v1/exos-eventbrite-oauth/callback');
    expect(eventbriteOAuthConfig(env({ ...base, EXOS_EVENTBRITE_CLIENT_ID: 'bad id!' }))).toBeNull();
  });

  it('checks the callback URL shape', () => {
    expect(isCallbackUrl(CB)).toBe(true);
    expect(isCallbackUrl('http://localhost:54321/functions/v1/exos-eventbrite-oauth/callback')).toBe(true);
    expect(isCallbackUrl('http://proj.supabase.co/functions/v1/exos-eventbrite-oauth/callback')).toBe(false);
    expect(isCallbackUrl(`${CB}?x=1`)).toBe(false);
    expect(isCallbackUrl(`${CB}#x`)).toBe(false);
    expect(isCallbackUrl('https://u:p@proj.supabase.co/functions/v1/exos-eventbrite-oauth/callback')).toBe(false);
    expect(isCallbackUrl('https://proj.supabase.co/functions/v1/exos-oauth-google/callback')).toBe(false);
    expect(isCallbackUrl('not a url')).toBe(false);
  });
});

describe('Eventbrite OAuth state', () => {
  it('is 256 random bits, base64url, hashed for storage', async () => {
    const a = newState();
    const b = newState();
    expect(isStateShaped(a)).toBe(true);
    expect(a).not.toBe(b);
    expect(isStateShaped('short')).toBe(false);
    expect(isStateShaped(`${'A'.repeat(42)}+`)).toBe(false);
    expect(isStateShaped(null)).toBe(false);
    const h = await stateHash(a);
    expect(h).toMatch(/^[0-9a-f]{64}$/);
    expect(await stateHash(a)).toBe(h);
    // Known vector: SHA-256("abc").
    expect(await stateHash('abc')).toBe('ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad');
  });
});

describe('Eventbrite OAuth URLs', () => {
  it('builds the authorize URL with code flow, the client id, redirect URI and state only', () => {
    const u = new URL(buildAuthorizeUrl(CFG, 'S'.repeat(43)));
    expect(`${u.origin}${u.pathname}`).toBe(EB_AUTHORIZE_URL);
    expect(Object.fromEntries(u.searchParams)).toEqual({
      response_type: 'code', client_id: 'APIKEY123', redirect_uri: CB, state: 'S'.repeat(43),
    });
    expect(u.toString()).not.toContain('SECRET');
    expect(isEventbriteAuthorizeUrl(u.toString())).toBe(true);
    expect(isEventbriteAuthorizeUrl('https://evil.example/oauth/authorize?x')).toBe(false);
    expect(isEventbriteAuthorizeUrl('https://www.eventbrite.com.evil.example/oauth/authorize?x')).toBe(false);
  });

  it('returns only to EXOS_APP_URL when its origin is allow-listed (no open redirect)', () => {
    expect(returnAppUrl('https://exos.example/bridge/', 'https://exos.example')).toBe('https://exos.example/bridge');
    expect(returnAppUrl('https://exos.example/bridge', 'https://other.example')).toBeNull();
    expect(returnAppUrl('http://exos.example', 'http://exos.example')).toBeNull();
    expect(returnAppUrl('https://exos.example?x=1', 'https://exos.example')).toBeNull();
    expect(returnAppUrl(undefined, 'https://exos.example')).toBeNull();
  });

  it('goes back to the org settings page, or /orgs for a bad org id', () => {
    expect(integrationsReturnUrl('https://exos.example/bridge/', ORG, { eventbrite: 'finish', eventbrite_state: 'abc' }))
      .toBe(`https://exos.example/bridge/orgs/${ORG}/settings?eventbrite=finish&eventbrite_state=abc`);
    expect(integrationsReturnUrl('https://exos.example', '../../evil', { eventbrite: 'error', reason: 'state' }))
      .toBe('https://exos.example/orgs?eventbrite=error&reason=state');
    expect(integrationsReturnUrl('https://exos.example', null, {})).toBe('https://exos.example/orgs');
  });

  it('sorts a callback error', () => {
    expect(callbackErrorReason('access_denied')).toBe('denied');
    expect(callbackErrorReason('server_error')).toBe('eventbrite');
    expect(callbackErrorReason(null)).toBe('eventbrite');
  });
});

describe('Eventbrite token exchange', () => {
  it('builds the form POST to the token URL', () => {
    const r = buildCodeExchangeRequest(CFG, 'CODE1234');
    expect(r.url).toBe(EB_TOKEN_URL);
    expect(r.method).toBe('POST');
    expect(r.headers['content-type']).toBe('application/x-www-form-urlencoded');
    expect(Object.fromEntries(new URLSearchParams(r.body))).toEqual({
      grant_type: 'authorization_code', client_id: 'APIKEY123', client_secret: 'SECRET-xyz', code: 'CODE1234', redirect_uri: CB,
    });
  });

  it('parses the answer without leaking anything', () => {
    expect(parseTokenResponse(200, { access_token: 'ABCDEFGH1234', token_type: 'bearer' })).toEqual({ ok: true, accessToken: 'ABCDEFGH1234' });
    expect(parseTokenResponse(200, { access_token: 'has space 1234' })).toMatchObject({ ok: false, kind: 'bad' });
    expect(parseTokenResponse(200, {})).toMatchObject({ ok: false, kind: 'bad' });
    expect(parseTokenResponse(200, { error: 'invalid_grant' })).toMatchObject({ ok: false, kind: 'denied' });
    expect(parseTokenResponse(400, { error: 'invalid_grant', error_description: 'code SECRETCODE expired' }))
      .toEqual({ ok: false, kind: 'denied', error: 'token http 400 invalid_grant' });
    expect(parseTokenResponse(401, { error: 'invalid_client' })).toMatchObject({ kind: 'config' });
    expect(parseTokenResponse(400, { error: 'redirect_uri_mismatch' })).toMatchObject({ kind: 'config' });
    expect(parseTokenResponse(503, null)).toMatchObject({ kind: 'retry' });
    expect(parseTokenResponse(429, null)).toMatchObject({ kind: 'retry' });
    expect(parseTokenResponse(400, { error: 'weird' })).toMatchObject({ kind: 'bad' });
  });

  it('posts only to the token URL', async () => {
    const fetchFn = vi.fn(async () => new Response(JSON.stringify({ access_token: 'TOKEN12345678' }), { status: 200 }));
    expect(await postTokenRequest(buildCodeExchangeRequest(CFG, 'CODE1234'), fetchFn)).toEqual({ ok: true, accessToken: 'TOKEN12345678' });
    expect(fetchFn).toHaveBeenCalledTimes(1);
    const [u, init] = fetchFn.mock.calls[0] as unknown as [string, RequestInit];
    expect(u).toBe(EB_TOKEN_URL);
    expect(init.method).toBe('POST');
    expect(init.redirect).toBe('manual');

    const other = vi.fn();
    const r = await postTokenRequest({ ...buildCodeExchangeRequest(CFG, 'CODE1234'), url: 'https://evil.example/oauth/token' }, other);
    expect(r).toMatchObject({ ok: false, kind: 'config' });
    expect(other).not.toHaveBeenCalled();
  });

  it('treats network trouble as a retry', async () => {
    const r = await postTokenRequest(buildCodeExchangeRequest(CFG, 'CODE1234'), async () => { throw new TypeError('down'); });
    expect(r).toEqual({ ok: false, kind: 'retry', error: 'token request failed' });
  });
});

describe('Connect Eventbrite return (SPA)', () => {
  it('goes back to the event only for an event id', () => {
    expect(eventPickPath(EVT)).toBe(`/dashboard/event/${EVT}?tab=door&eventbrite=pick`);
    expect(eventPickPath('//evil.example')).toBeNull();
    expect(eventPickPath(null)).toBeNull();
    expect(wantsEventbritePick('?tab=door&eventbrite=pick')).toBe(true);
    expect(wantsEventbritePick('?tab=door')).toBe(false);
  });

  it('has words for each reason and method', () => {
    expect(eventbriteErrorMessage('denied')).toMatch(/declined/);
    expect(eventbriteErrorMessage('not_configured')).toMatch(/private token/);
    expect(eventbriteErrorMessage('???')).toMatch(/Try again/);
    expect(authMethodLabel('oauth')).toMatch(/sign-in/);
    expect(authMethodLabel('private_token')).toMatch(/private token/);
    expect(authMethodLabel(null)).toBe('Not connected');
  });
});

describe('Eventbrite status parsing', () => {
  it('reads how the account is connected', () => {
    expect(parseEventbriteStatus({ connected: true, auth_method: 'oauth' }).authMethod).toBe('oauth');
    expect(parseEventbriteStatus({ connected: true }).authMethod).toBeNull();
    expect(parseEventbriteStatus({ connected: true, auth_method: 'magic' }).authMethod).toBeNull();
  });

  it('reads the org status and its history', () => {
    const s = parseEventbriteOrgStatus({
      can_manage: true, connected: true, account_name: 'Blue Room', auth_method: 'oauth', connected_at: '2026-10-29T10:00:00Z',
      linked_events: 2,
      history: [
        { action: 'connect', auth_method: 'oauth', account_name: 'Blue Room', at: '2026-10-29T10:00:00Z', by_you: true },
        { action: 'rm -rf', at: '2026-10-28T10:00:00Z' },
        { action: 'disconnect', auth_method: 'private_token', account_name: null, at: '2026-10-28T09:00:00Z' },
      ],
    });
    expect(s).toMatchObject({ canManage: true, connected: true, accountName: 'Blue Room', authMethod: 'oauth', linkedEvents: 2 });
    expect(s.history).toEqual([
      { action: 'connect', authMethod: 'oauth', accountName: 'Blue Room', at: '2026-10-29T10:00:00Z', byYou: true },
      { action: 'disconnect', authMethod: 'private_token', accountName: null, at: '2026-10-28T09:00:00Z', byYou: false },
    ]);
    expect(parseEventbriteOrgStatus(null)).toMatchObject({ connected: false, history: [] });
  });
});
