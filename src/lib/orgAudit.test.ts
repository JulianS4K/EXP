// The org audit log's TS helpers (claude/exos-org-audit, mig 20261109100000):
// the action groups against _exos_audit_group() in the migration, the actor
// headers exos-api sends, the API row, and the Activity page's labels and CSV.

import { readdirSync, readFileSync } from 'node:fs';
import path from 'node:path';
import { describe, expect, it } from 'vitest';
import {
  actorHeaders, apiAuditRow, AUDIT_GROUP_NAMES, AUDIT_GROUPS, auditGroup, groupPrefixes,
} from '../../supabase/functions/_shared/api/audit.ts';
import { ROUTES } from '../../supabase/functions/_shared/api/routes.ts';
import { ROLE_SCOPES } from '../../supabase/functions/_shared/api/credentials.ts';
import { ROLE_SCOPE_CEILING } from '../../supabase/functions/_shared/api/orgAccess.ts';
import { hasScope } from '../../supabase/functions/_shared/api/scopes.ts';
import {
  actionLabel, actorText, amountLabel, AUDIT_CSV_HEADER, auditArgs, auditCsv, changeSummary, type AuditRow,
} from './orgAudit';

const MIGRATIONS = path.resolve(__dirname, '../../supabase/migrations');

/** _exos_audit_group(): prefix → group, from its latest definition. */
function sqlGroups(): Record<string, string> {
  const hits = readdirSync(MIGRATIONS).filter((f) => f.endsWith('.sql')).sort()
    .map((f) => readFileSync(path.join(MIGRATIONS, f), 'utf8'))
    .filter((s) => s.includes('FUNCTION public._exos_audit_group(p_action text)'));
  const sql = hits[hits.length - 1];
  const fn = /FUNCTION public\._exos_audit_group\(p_action text\)[\s\S]*?SELECT CASE([\s\S]*?)ELSE 'other'/.exec(sql ?? '');
  if (!fn) throw new Error('_exos_audit_group() not found');
  const out: Record<string, string> = {};
  for (const m of fn[1].matchAll(/WHEN '([a-z_]+)' THEN '([a-z]+)'/g)) out[m[1]] = m[2];
  return out;
}

const row = (over: Partial<AuditRow> = {}): AuditRow => ({
  id: 7, at: '2026-11-09T15:04:22Z', event_id: null, event_name: null, actor_uid: 'u1', actor_kind: 'user', actor_ref: null,
  actor_role: 'owner', actor_label: 'oa@x.com', action: 'tier.update', group: 'inventory', entity_type: 'tier', entity_id: 't1',
  changes: { price: [40, 45] }, amount_cents: null, currency: null, reason: null, source: 'dashboard', request_id: null, ...over,
});

describe('audit groups', () => {
  it('AUDIT_GROUPS equals _exos_audit_group() in the migration', () => {
    const sql = sqlGroups();
    const ts: Record<string, string> = {};
    for (const g of AUDIT_GROUP_NAMES) for (const p of AUDIT_GROUPS[g]) ts[p] = g;
    expect(ts).toEqual(sql);
  });

  it('names the group of an action, other for an unknown one', () => {
    expect(auditGroup('refund.issue')).toBe('money');
    expect(auditGroup('refund_ask.decline')).toBe('money');
    expect(auditGroup('role_scopes.set')).toBe('access');
    expect(auditGroup('export.run')).toBe('data');
    expect(auditGroup('event.publish')).toBe('inventory');
    expect(auditGroup('nope.x')).toBe('other');
    expect(groupPrefixes('data')).toEqual(['export.']);
  });
});

describe('actor headers', () => {
  it('names an API key by its id, never anything else', () => {
    expect(actorHeaders({ kind: 'api_key', id: '5d4c3b2a-1f0e-4d9c-8b7a-6f5e4d3c2b1a' }, 'req-1')).toEqual({
      'x-exos-actor': 'api_key:5d4c3b2a-1f0e-4d9c-8b7a-6f5e4d3c2b1a', 'x-exos-request-id': 'req-1',
    });
  });

  it('a personal token and an OAuth app carry their user', () => {
    const uid = '2b3c4d5e-6f70-4a81-92a3-b4c5d6e7f809';
    expect(actorHeaders({ kind: 'pat', id: 'p1', userId: uid }, 'r')['x-exos-actor']).toBe('pat:p1');
    const o = actorHeaders({ kind: 'oauth', id: 't1', userId: uid, clientId: 'exos_ci_abc' }, 'r');
    expect(o['x-exos-actor']).toBe('oauth_app:exos_ci_abc');
    expect(o['x-exos-actor-uid']).toBe(uid);
  });

  it('drops anything that is not a plain id', () => {
    expect(actorHeaders({ kind: 'api_key', id: 'x,y;z' }, 'bad id!')).toEqual({});
    expect(actorHeaders({ kind: 'oauth', id: 't', clientId: null }, 'r')['x-exos-actor']).toBeUndefined();
  });
});

describe('GET /v1/audit', () => {
  it('is one read route, audit:read, held by owner and finance by default', () => {
    const r = ROUTES.find((x) => x.id === 'list-audit');
    expect(r).toMatchObject({ method: 'GET', path: '/audit', scope: 'audit:read', paged: true });
    expect(ROLE_SCOPES.owner.includes('audit:read')).toBe(true);
    expect(ROLE_SCOPES.finance.includes('audit:read')).toBe(true);
    for (const role of ['manager', 'content', 'scanner'] as const) {
      expect(ROLE_SCOPES[role].includes('audit:read'), role).toBe(false);
      expect(ROLE_SCOPE_CEILING[role].includes('audit:read'), role).toBe(false);
    }
    expect(hasScope(['finance:read'], 'audit:read')).toBe(false);
  });

  it('shapes a row: the actor, the entity, numbers as numbers', () => {
    const a = apiAuditRow({
      id: '88213', at: 't', event_id: null, actor_uid: 'u', actor_kind: 'api_key', actor_ref: 'k', actor_role: 'finance',
      action: 'refund.issue', entity_type: 'order', entity_id: 'cs_1', changes: { scope: [null, 'order'] },
      amount_cents: '1500', currency: 'USD', reason: null, source: 'api', request_id: 'r',
    });
    expect(a).toMatchObject({
      id: 88213, group: 'money', entity: { type: 'order', id: 'cs_1' },
      actor: { kind: 'api_key', user_id: 'u', ref: 'k', role: 'finance' }, amount_cents: 1500,
    });
    expect(Object.keys(a)).not.toContain('key_hash');
  });
});

describe('the Activity page', () => {
  it('labels actions, changes, amounts and actors', () => {
    expect(actionLabel('refund_ask.decline')).toBe('Refund ask: decline');
    expect(changeSummary({ price: [40, 45], scope: [null, 'order'], scopes: [null, ['events:read', 'tickets:read']] }))
      .toBe('price 40 → 45; scope order; scopes events:read, tickets:read');
    expect(changeSummary({ description: ['(12 characters)', '(80 characters)'] })).toBe('description (12 characters) → (80 characters)');
    expect(amountLabel(1500, 'USD')).toBe('$15.00');
    expect(amountLabel(null, 'USD')).toBe('');
    expect(actorText(row())).toBe('oa@x.com (owner)');
    expect(actorText(row({ actor_kind: 'oauth_app', actor_role: 'finance' }))).toBe('oa@x.com via an app (finance)');
    expect(actorText(row({ actor_label: 'Exos support', actor_role: 'platform_admin' }))).toBe('Exos support');
  });

  it('turns day filters into a half-open range', () => {
    const a = auditArgs('o', { from: '2026-11-01', to: '2026-11-01', group: 'money' }, null, 100);
    expect(new Date(a.p_to as string).getTime() - new Date(a.p_from as string).getTime()).toBe(86_400_000);
    expect(a).toMatchObject({ p_org_id: 'o', p_group: 'money', p_event_id: null, p_actor_uid: null, p_before: null, p_limit: 100 });
    expect(auditArgs('o', { from: 'not a day' }, 5, 1).p_from).toBeNull();
  });

  it('builds the CSV with every column and a defused formula', () => {
    const csv = auditCsv([row({ reason: '=HYPERLINK("x")' })]);
    const [head, line] = csv.split('\r\n');
    expect(head).toBe(AUDIT_CSV_HEADER.join(','));
    expect(line).toContain('tier.update');
    expect(line).toContain(`"{""price"":[40,45]}"`);
    expect(line).toContain(`"'=HYPERLINK(""x"")"`);
  });
});
