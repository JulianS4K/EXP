// The fan API (/v1/me/…, mig 20261105110000): the route -> action map, the
// scope each action needs (must equal _exos_api_me_action_scope in the
// migration), who may call it (user tokens only; an account token only these
// routes), the request bodies, and the user scopes' rules.

import { readFileSync } from 'node:fs';
import path from 'node:path';
import { describe, expect, it } from 'vitest';
import {
  gapSqlError, marketingView, ME_ACTION_SCOPE, ME_ROUTES, MeBodyError, meReadArgs, meRefusal, meWriteArgs,
  needsUserToken, walletRefusalStatus,
} from '../../supabase/functions/_shared/api/me.ts';
import { matchRoute, ROUTES } from '../../supabase/functions/_shared/api/routes.ts';
import {
  effectiveScopes, hasScope, isUserScope, KEY_SCOPES, READ_SCOPES, SCOPES, USER_SCOPES,
} from '../../supabase/functions/_shared/api/scopes.ts';
import { ORG_ROLES, ROLE_SCOPES } from '../../supabase/functions/_shared/api/credentials.ts';

const MIG = readFileSync(path.resolve(__dirname, '../../supabase/migrations/20261105110000_exos_fan_api.sql'), 'utf8');

/** _exos_api_me_action_scope's CASE as { action: scope }. */
function sqlActionScopes(): Record<string, string> {
  const fn = /FUNCTION public\._exos_api_me_action_scope[\s\S]*?\$\$;/.exec(MIG);
  if (!fn) throw new Error('_exos_api_me_action_scope not found');
  const out: Record<string, string> = {};
  for (const m of fn[0].matchAll(/WHEN p_action IN \(([\s\S]*?)\)\s*THEN '([a-z:]+)'/g)) {
    for (const a of m[1].matchAll(/'([^']+)'/g)) out[a[1]] = m[2];
  }
  return out;
}

const meRoutes = ROUTES.filter((r) => r.scope === 'me:read' || r.scope === 'me:write');

describe('fan API routes', () => {
  it('every me:* route is mapped, and every mapped route is a me:* route', () => {
    expect(meRoutes.map((r) => r.id).sort()).toEqual(Object.keys(ME_ROUTES).sort());
    expect(meRoutes.length).toBe(34);
  });

  it('a route needs the scope its action needs', () => {
    for (const r of meRoutes) expect(ME_ACTION_SCOPE[ME_ROUTES[r.id].action], r.id).toBe(r.scope);
  });

  it('ME_ACTION_SCOPE equals _exos_api_me_action_scope in the migration', () => {
    expect(sqlActionScopes()).toEqual({ ...ME_ACTION_SCOPE });
  });

  it('reads are GET with me:read, writes are not GET with me:write', () => {
    for (const r of meRoutes) expect(r.scope, r.id).toBe(r.method === 'GET' ? 'me:read' : 'me:write');
  });

  it('a route with a target has it in its path', () => {
    for (const r of meRoutes) {
      const t = ME_ROUTES[r.id].target;
      if (t) expect(r.path, r.id).toContain(`:${t}`);
    }
  });

  it("Opendate's /users/current/… paths answer", () => {
    expect(matchRoute('GET', '/users/current/tickets')?.route.id).toBe('list-my-tickets');
    expect(matchRoute('GET', '/users/current/season_passes/x/google_wallet_url')?.route.id).toBe('get-my-season-pass-google-wallet');
    expect(matchRoute('POST', '/me/orders/cs_1/ticket_transfers')?.route.id).toBe('create-my-order-transfers');
    expect(matchRoute('POST', '/personal_access_tokens')?.route.id).toBe('create-my-token');
    expect(matchRoute('GET', '/me/memberships')?.route.id).toBe('list-my-memberships'); // the user's organizations
  });
});

describe('who may call /v1/me', () => {
  it('an org API key never (it has no user)', () => {
    expect(meRefusal('api_key', false, 'list-my-tickets', 'me:read')).toMatch(/no user/);
    expect(meRefusal('api_key', false, 'list-events', 'events:read')).toBeNull();
  });

  it('personal and OAuth tokens may', () => {
    expect(meRefusal('pat', false, 'list-my-tickets', 'me:read')).toBeNull();
    expect(meRefusal('oauth', false, 'claim-transfer', 'me:write')).toBeNull();
  });

  it('an account token: /v1/me/…, GET /v1/me and revoking itself only', () => {
    expect(meRefusal('pat', true, 'list-my-orders', 'me:read')).toBeNull();
    expect(meRefusal('pat', true, 'me', null)).toBeNull();
    expect(meRefusal('pat', true, 'revoke-current-token', null)).toBeNull();
    expect(meRefusal('pat', true, 'list-events', 'events:read')).toMatch(/no organization/);
    expect(meRefusal('pat', true, 'list-my-memberships', null)).toMatch(/no organization/);
    expect(needsUserToken('me:write')).toBe(true);
    expect(needsUserToken(null)).toBe(false);
  });
});

describe('user scopes', () => {
  it('me:read / me:write are user scopes, never an org key\'s', () => {
    expect([...USER_SCOPES]).toEqual(['me:read', 'me:write']);
    expect(SCOPES.filter(isUserScope)).toEqual(['me:read', 'me:write']);
    expect(KEY_SCOPES.some(isUserScope)).toBe(false);
    expect(KEY_SCOPES.length).toBe(SCOPES.length - 2);
    expect(SCOPES[SCOPES.length - 1]).toBe('org:admin');
  });

  it('me:write covers me:read; the legacy read does not', () => {
    expect(hasScope(['me:write'], 'me:read')).toBe(true);
    expect(hasScope(['me:read'], 'me:write')).toBe(false);
    expect(hasScope(['read'], 'me:read')).toBe(false);
    expect(READ_SCOPES).not.toContain('me:read');
    expect(effectiveScopes(['read'])).not.toContain('me:read');
  });

  it('every role may give its own tokens me:*', () => {
    for (const r of ORG_ROLES) expect(ROLE_SCOPES[r], r).toEqual(expect.arrayContaining(['me:read', 'me:write']));
  });
});

describe('request bodies', () => {
  const T = '7a10c3e1-1c2d-4e3f-8a9b-0c1d2e3f4a5b';

  it('transfers: items, or ticket_ids with one email (Opendate wrapper ok)', () => {
    expect(meWriteArgs('create-my-transfers', { items: [{ ticket_id: T, email: 'A@x.com', name: '  Al  ' }] }))
      .toEqual({ items: [{ ticket_id: T, email: 'a@x.com', name: 'Al' }] });
    expect(meWriteArgs('create-my-transfers', { ticket_transfer: { ticket_ids: [T, T], email: 'b@x.com' } }))
      .toEqual({ items: [{ ticket_id: T, email: 'b@x.com', name: null }] });
    expect(() => meWriteArgs('create-my-transfers', { ticket_ids: [T], email: 'nope' })).toThrow(MeBodyError);
    expect(() => meWriteArgs('create-my-transfers', { items: [{ ticket_id: 'x', email: 'a@x.com' }] })).toThrow(/ticket UUID/);
    expect(() => meWriteArgs('create-my-transfers', { items: [] })).toThrow(/1 to 50/);
  });

  it('order transfers and claims', () => {
    expect(meWriteArgs('create-my-order-transfers', { email: 'c@x.com' })).toEqual({ email: 'c@x.com', name: null });
    expect(meWriteArgs('claim-transfer', { claim_key: ' kq2V0x8vTn4b6rP1sYdZ3wA9 ' })).toEqual({ key: 'kq2V0x8vTn4b6rP1sYdZ3wA9' });
    expect(() => meWriteArgs('claim-transfer', {})).toThrow(/key/);
  });

  it('profile: only the display name; marketing: a boolean', () => {
    expect(meWriteArgs('update-my-profile', { user: { name: 'Sam  Lee' } })).toEqual({ display_name: 'Sam Lee' });
    expect(() => meWriteArgs('update-my-profile', { email: 'x@x.com' })).toThrow(/read-only/);
    expect(meWriteArgs('set-my-marketing-preferences', { subscribe_to_marketing_email: 'false' })).toEqual({ marketing_emails: false });
    expect(() => meWriteArgs('set-my-marketing-preferences', {})).toThrow(/required/);
    expect(marketingView({ marketing_emails: false })).toEqual({ marketing_emails: false });
    expect(marketingView(null)).toEqual({ marketing_emails: true });
  });

  it('refund requests', () => {
    expect(meWriteArgs('create-my-refund-request', { refund_request: { ticket_ids: T, reason: 'x' } }))
      .toEqual({ ticket_ids: [T], reason: 'x' });
    expect(meWriteArgs('create-my-order-refund-request', { notes: 'late' })).toEqual({ reason: 'late' });
    expect(() => meWriteArgs('create-my-refund-request', {})).toThrow(/ticket_ids/);
  });

  it('tokens: scopes, a known lifetime, nothing else', () => {
    expect(meWriteArgs('create-my-token', { scopes: 'me:read me:read', expires_days: '30' }))
      .toEqual({ name: 'Token', scopes: ['me:read'], expires_days: 30 });
    expect(meWriteArgs('create-my-token', { personal_access_token: { name: 'ci', scopes: ['me:read'], expires_days: null } }))
      .toEqual({ name: 'ci', scopes: ['me:read'], expires_days: null });
    expect(() => meWriteArgs('create-my-token', { scopes: ['me:read'], expires_days: 7 })).toThrow(/expires_days/);
    expect(() => meWriteArgs('create-my-token', { scopes: [] })).toThrow(/scopes/);
    expect(() => meWriteArgs('create-my-token', { scopes: ['me:read'], org_id: 'x' })).toThrow(/read-only/);
  });

  it('read filters', () => {
    expect(meReadArgs('list-my-tickets', new URLSearchParams('status=active'))).toEqual({ status: 'active' });
    expect(() => meReadArgs('list-my-tickets', new URLSearchParams('event_id=nope'))).toThrow(MeBodyError);
    expect(() => meReadArgs('list-my-tickets', new URLSearchParams('status=stolen'))).toThrow(MeBodyError);
    expect(meReadArgs('list-my-passes', new URLSearchParams('kind=flex'))).toEqual({ kind: 'flex' });
    expect(meReadArgs('list-my-orders', new URLSearchParams('status=active'))).toEqual({});
  });
});

describe('errors', () => {
  it('maps SQL states to statuses and strips the function name', () => {
    expect(gapSqlError({ code: 'P0002', message: 'exos_api_me: ticket not found' })).toEqual({ status: 404, message: 'ticket not found' });
    expect(gapSqlError({ code: '42501', message: 'exos_api_me: the token lacks the me:write scope' })?.status).toBe(403);
    expect(gapSqlError({ code: '54000', message: 'x' })?.status).toBe(429);
    expect(gapSqlError({ code: 'XX000', message: 'boom' })).toBeNull();
    expect(walletRefusalStatus('record_not_found')).toBe(404);
    expect(walletRefusalStatus('in-transfer')).toBe(409);
  });
});
