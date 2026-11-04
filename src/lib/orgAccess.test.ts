// Organizer-controlled access (supabase/functions/_shared/api/orgAccess.ts)
// against the SQL that enforces it (mig 20261104180000): the role ceilings
// must equal exos_role_scope_ceiling(), the grant vocabulary
// exos_event_partner_grant_vocab(); plus the pure rules. docs/org-access.md.

import { readdirSync, readFileSync } from 'node:fs';
import path from 'node:path';
import { describe, expect, it } from 'vitest';
import { ORG_ROLES, ROLE_SCOPES } from '../../supabase/functions/_shared/api/credentials.ts';
import {
  cleanGrantScopes, cohostAllowed, CONFIGURABLE_ROLES, DEFAULT_GRANT_SCOPES, effectivePartnerPresale, GRANT_SCOPES,
  ORG_SCOPES, orgRoleScopes, ROLE_SCOPE_CEILING, roleScopesProblem, toggleScope, venueApprovalVenue, venueRequestBody,
} from '../../supabase/functions/_shared/api/orgAccess.ts';
import { matchRoute } from '../../supabase/functions/_shared/api/routes.ts';

const MIGRATIONS = path.resolve(__dirname, '../../supabase/migrations');

/** The body of the latest migration defining `marker`. */
function latest(marker: string): string {
  const hits = readdirSync(MIGRATIONS).filter((f) => f.endsWith('.sql')).sort()
    .map((f) => readFileSync(path.join(MIGRATIONS, f), 'utf8'))
    .filter((sql) => sql.includes(marker));
  if (!hits.length) throw new Error(`no migration defines ${marker}`);
  return hits[hits.length - 1];
}

function sqlCeilings(): Record<string, string[]> {
  const sql = latest('FUNCTION public.exos_role_scope_ceiling(p_role text)');
  const fn = /FUNCTION public\.exos_role_scope_ceiling\(p_role text\)[\s\S]*?SELECT CASE p_role([\s\S]*?)ELSE ARRAY/.exec(sql);
  if (!fn) throw new Error('exos_role_scope_ceiling() not found');
  const out: Record<string, string[]> = {};
  for (const m of fn[1].matchAll(/WHEN '([a-z]+)' THEN ARRAY\[([\s\S]*?)\]/g)) {
    out[m[1]] = [...m[2].matchAll(/'([^']+)'/g)].map((x) => x[1]);
  }
  return out;
}

describe('role API permissions', () => {
  it('ROLE_SCOPE_CEILING equals exos_role_scope_ceiling() in the migration', () => {
    const sql = sqlCeilings();
    expect(Object.keys(sql).sort()).toEqual([...ORG_ROLES].sort());
    for (const r of ORG_ROLES) expect(sql[r], r).toEqual([...ROLE_SCOPE_CEILING[r]]);
  });

  it('the owner\'s ceiling is every org scope; only the owner has org:admin', () => {
    expect([...ROLE_SCOPE_CEILING.owner]).toEqual([...ORG_SCOPES]);
    for (const r of CONFIGURABLE_ROLES) expect(ROLE_SCOPE_CEILING[r].includes('org:admin'), r).toBe(false);
  });

  it('dashboard limits: content never gets finance, refunds or orders; scanners stay at the door', () => {
    for (const s of ['finance:read', 'finance:write', 'refunds:write', 'orders:read'] as const) {
      expect(ROLE_SCOPE_CEILING.content.includes(s), s).toBe(false);
    }
    expect([...ROLE_SCOPE_CEILING.scanner]).toEqual(['events:read', 'tickets:read', 'checkin:write']);
    expect(ROLE_SCOPE_CEILING.finance.includes('refunds:write')).toBe(true);
    expect(ROLE_SCOPE_CEILING.finance.includes('events:write')).toBe(false);
  });

  it('today\'s token sets fit under the ceilings (they are the defaults)', () => {
    for (const r of ORG_ROLES) {
      for (const s of ROLE_SCOPES[r]) {
        if (s.startsWith('me:')) continue;
        expect(ROLE_SCOPE_CEILING[r].includes(s), `${r} ${s}`).toBe(true);
      }
    }
  });

  it('with no setting: tokens get the token default, keys the ceiling (as before)', () => {
    expect(orgRoleScopes('manager', null)).toEqual(ORG_SCOPES.filter((s) => ROLE_SCOPES.manager.includes(s)));
    expect(orgRoleScopes('manager', null, true)).toEqual([...ROLE_SCOPE_CEILING.manager]);
    expect(orgRoleScopes('finance', null, true).includes('refunds:write')).toBe(true);
    expect(orgRoleScopes('finance', null).includes('refunds:write')).toBe(false);
  });

  it('an owner\'s setting applies to keys and tokens alike, clipped to the ceiling', () => {
    const set = ['events:read', 'fans:read', 'org:admin'];
    expect(orgRoleScopes('manager', set)).toEqual(['events:read', 'fans:read']);
    expect(orgRoleScopes('manager', set, true)).toEqual(['events:read', 'fans:read']);
    expect(orgRoleScopes('content', ['events:read', 'finance:read'])).toEqual(['events:read']);
    // The owner's own set never changes.
    expect(orgRoleScopes('owner', ['events:read'], true)).toEqual([...ORG_SCOPES]);
  });

  it('explains a set that can\'t be saved', () => {
    expect(roleScopesProblem('content', ['finance:read'])).toMatch(/never be given finance:read/);
    expect(roleScopesProblem('scanner', ['events:write'])).toMatch(/never/);
    expect(roleScopesProblem('owner', ['events:read'])).toMatch(/role must be/);
    expect(roleScopesProblem('manager', ['nope:read'])).toMatch(/unknown scope/);
    expect(roleScopesProblem('finance', ['refunds:write', 'orders:read'])).toBeNull();
  });

  it('toggles a scope in vocabulary order', () => {
    expect(toggleScope(['orders:read'], 'events:read', true)).toEqual(['events:read', 'orders:read']);
    expect(toggleScope(['events:read', 'orders:read'], 'events:read', false)).toEqual(['orders:read']);
  });
});

describe('venue requests and grants', () => {
  it('GRANT_SCOPES equals exos_event_partner_grant_vocab(); refunds are never shared', () => {
    const sql = latest('FUNCTION public.exos_event_partner_grant_vocab()');
    const fn = /FUNCTION public\.exos_event_partner_grant_vocab\(\)[\s\S]*?SELECT ARRAY\[([\s\S]*?)\]/.exec(sql);
    expect([...fn![1].matchAll(/'([^']+)'/g)].map((m) => m[1])).toEqual([...GRANT_SCOPES]);
    expect((GRANT_SCOPES as readonly string[]).includes('refunds:write')).toBe(false);
  });

  it('cleans grant scopes like the SQL', () => {
    expect(cleanGrantScopes(undefined)).toEqual({ ok: true, scopes: [...DEFAULT_GRANT_SCOPES] });
    expect(cleanGrantScopes(['tickets:read', 'events:write'])).toEqual({ ok: true, scopes: ['events:read', 'events:write', 'tickets:read'] });
    expect(cleanGrantScopes(['refunds:write']).ok).toBe(false);
    expect(cleanGrantScopes([]).ok).toBe(false);
    expect(cleanGrantScopes('events:read').ok).toBe(false);
  });

  it('a co-host route needs the scope in the credential AND the grant', () => {
    expect(cohostAllowed(['events:write'], ['events:read'], 'events:read')).toBe(true);
    expect(cohostAllowed(['events:read'], ['events:write'], 'events:write')).toBe(false);
    expect(cohostAllowed(['events:write'], ['events:read'], 'events:write')).toBe(false);
    expect(cohostAllowed(['tickets:read'], ['tickets:read', 'finance:read'], 'tickets:read')).toBe(true);
  });

  it('checks a request body\'s shape', () => {
    const ok = { venue_id: '7a10c3e1-1c2d-4e3f-8a9b-0c1d2e3f4a5b', date: '2026-12-12', title: 'Night' };
    expect(venueRequestBody(ok).ok).toBe(true);
    expect(venueRequestBody({ ...ok, start_time: '21:00', expected_draw: 250, room_id: null }).ok).toBe(true);
    expect(venueRequestBody({ ...ok, venue_id: 'x' }).ok).toBe(false);
    expect(venueRequestBody({ ...ok, date: '12/12/2026' }).ok).toBe(false);
    expect(venueRequestBody({ ...ok, start_time: '25:00' }).ok).toBe(false);
    expect(venueRequestBody({ ...ok, title: ' ' }).ok).toBe(false);
    expect(venueRequestBody({ ...ok, expected_draw: 1.5 }).ok).toBe(false);
    expect(venueRequestBody({ ...ok, price: 10 }).ok).toBe(false);
  });

  it('reads the venue out of the gate\'s refusal', () => {
    expect(venueApprovalVenue('venue_approval_required: this venue is run by another organization on Exos; send it a booking request (POST /v1/venue-requests with venue_id 7a10c3e1-1c2d-4e3f-8a9b-0c1d2e3f4a5b)'))
      .toBe('7a10c3e1-1c2d-4e3f-8a9b-0c1d2e3f4a5b');
    expect(venueApprovalVenue('exos_events: venue not found in this organization')).toBeNull();
    expect(venueApprovalVenue(undefined)).toBeNull();
  });

  it('routes: requests and grants are booking scopes; co-hosted events their own', () => {
    expect(matchRoute('POST', '/venue-requests')?.route.scope).toBe('booking:write');
    expect(matchRoute('POST', '/venue-requests/r1/approve')?.route.id).toBe('approve-venue-request');
    expect(matchRoute('DELETE', '/partner-grants/g1')?.route.id).toBe('revoke-partner-grant');
    expect(matchRoute('PATCH', '/cohosted-events/e1')?.route.scope).toBe('events:write');
    expect(matchRoute('GET', '/cohosted-events/e1/sales')?.route.scope).toBe('tickets:read');
    expect(matchRoute('PUT', '/role-api-scopes/finance')?.route.scope).toBe('org:admin');
    expect(matchRoute('PUT', '/events/e1/partner-presale')?.route.id).toBe('update-event-partner-presale');
    expect(matchRoute('PUT', '/partner-presale')?.route.scope).toBe('org:admin');
  });
});

describe('partner presale', () => {
  it('the event overrides the org; block by default', () => {
    expect(effectivePartnerPresale(null, null)).toBe('block');
    expect(effectivePartnerPresale('allow', null)).toBe('allow');
    expect(effectivePartnerPresale('allow', 'block')).toBe('block');
    expect(effectivePartnerPresale('block', 'allow')).toBe('allow');
    expect(effectivePartnerPresale('maybe', 'inherit')).toBe('block');
  });
});
