import { readdirSync, readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { describe, expect, it, vi } from 'vitest';

vi.mock('./supabase', () => ({ supabase: {} }));
import {
  MATRIX_CAPABILITIES,
  MATRIX_ROLES,
  ROLE_CAPABILITIES,
  can,
  cannotReason,
  roleInOrg,
  type OrgCapability,
} from './orgRoles';
import { canSeeMoney } from './settlement';
import { canEditEvents, canManageOrg, canRunCheckIn } from './orgs';
import type { OrgRole } from '../types';

const ROOT = resolve(__dirname, '../..');
const MIG = resolve(ROOT, 'supabase/migrations');
const ORDER: OrgRole[] = ['owner', 'manager', 'finance', 'scanner', 'content'];
const norm = (list: string) =>
  [...new Set(list.split(',').map((r) => r.replace(/[\s']/g, '')).filter(Boolean))]
    .sort((a, b) => ORDER.indexOf(a as OrgRole) - ORDER.indexOf(b as OrgRole))
    .join(',');

// Every role list in the LATEST definition of each policy / function.
function roleListsByName(): Map<string, Set<string>> {
  const latest = new Map<string, Set<string>>();
  const files = readdirSync(MIG).filter((f) => f.includes('exos') && f.endsWith('.sql')).sort();
  const start = /CREATE\s+(?:OR\s+REPLACE\s+)?(?:FUNCTION|POLICY)\s+(?:public\.)?"?([a-z_0-9]+)/gi;
  const lists = /(?:ARRAY\s*\[|\bIN\s*\()\s*('(?:owner|manager|finance|scanner|content)'(?:\s*,\s*'[a-z]+')*)\s*[\])]/g;
  for (const f of files) {
    const text = readFileSync(resolve(MIG, f), 'utf8').replace(/::text/g, '');
    const marks = [...text.matchAll(start)];
    const inFile = new Map<string, Set<string>>();
    marks.forEach((m, i) => {
      const body = text.slice(m.index!, i + 1 < marks.length ? marks[i + 1].index : text.length);
      const set = inFile.get(m[1]) ?? new Set<string>();
      for (const l of body.matchAll(lists)) set.add(norm(l[1]));
      inFile.set(m[1], set);
    });
    for (const [name, set] of inFile) latest.set(name, set);
  }
  return latest;
}

describe('role table matches the migrations', () => {
  const sqlLists = roleListsByName();
  for (const [cap, rule] of Object.entries(ROLE_CAPABILITIES) as [OrgCapability, (typeof ROLE_CAPABILITIES)[OrgCapability]][]) {
    it(`${cap}: ${rule.roles.join(', ')}`, () => {
      const want = norm(rule.roles.join(','));
      for (const src of rule.sources) {
        if (src.kind === 'file') {
          expect(readFileSync(resolve(ROOT, src.path), 'utf8')).toContain(src.contains);
          continue;
        }
        const found = sqlLists.get(src.name);
        expect(found, `${src.name} not found in supabase/migrations`).toBeDefined();
        expect([...found!], src.name).toContain(want);
        if (src.only !== false) expect([...found!], `${src.name} has other role lists`).toEqual([want]);
      }
    });
  }
});

describe('role table', () => {
  it('content and scanner cannot create or edit events (RLS: owner / manager)', () => {
    expect(can('content', 'editEvents')).toBe(false);
    expect(can('scanner', 'editEvents')).toBe(false);
    expect(can('finance', 'editEvents')).toBe(false);
    expect(can('manager', 'editEvents')).toBe(true);
    expect(canEditEvents('content')).toBe(false);
    expect(canEditEvents('finance')).toBe(false);
  });
  it('announcements and promo links are owner / manager; managers see payouts', () => {
    expect(can('content', 'announce')).toBe(false);
    expect(can('content', 'promoCodes')).toBe(false);
    expect(can('manager', 'viewPayouts')).toBe(true);
    expect(can('finance', 'promoterPayouts')).toBe(true);
    expect(can('finance', 'promoters')).toBe(false);
    expect(can('finance', 'releaseSeat')).toBe(false);
    expect(can('finance', 'voidTicket')).toBe(true);
  });
  it('the older helpers agree with it', () => {
    for (const r of ORDER) {
      expect(canSeeMoney(r)).toBe(can(r, 'viewMoney'));
      expect(canRunCheckIn(r)).toBe(can(r, 'scan'));
      expect(canManageOrg(r)).toBe(can(r, 'members'));
    }
    expect(can(null, 'viewMoney', true)).toBe(true);
    expect(can(null, 'viewMoney')).toBe(false);
  });
  it('the matrix shows every capability once, in the five role columns', () => {
    expect(new Set(MATRIX_CAPABILITIES).size).toBe(Object.keys(ROLE_CAPABILITIES).length);
    expect(MATRIX_ROLES).toEqual(ORDER);
  });
  it('gates on the role in the page\'s org, not the active one', () => {
    const orgs = [
      { org: { id: 'A' }, membership: { role: 'finance' as OrgRole } },
      { org: { id: 'B' }, membership: { role: 'owner' as OrgRole } },
    ];
    // Active org A (finance); B's event report: the owner's buttons.
    expect(roleInOrg(orgs, 'B')).toBe('owner');
    expect(can(roleInOrg(orgs, 'B'), 'releaseSeat')).toBe(true);
    expect(can(roleInOrg(orgs, 'A'), 'releaseSeat')).toBe(false);
    expect(roleInOrg(orgs, 'C')).toBeNull();
    expect(roleInOrg(orgs, undefined)).toBeNull();
  });
  it('says why a button is off', () => {
    expect(cannotReason('editEvents')).toBe('Only owners and managers can create, edit or clone events.');
    expect(cannotReason('viewMoney')).toBe('Only owners, managers and finance can see sales and money.');
    expect(cannotReason('members')).toBe('Only owners can manage members.');
  });
});
