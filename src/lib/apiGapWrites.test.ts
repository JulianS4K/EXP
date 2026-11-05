// The organization writes of the Opendate gap list (mig 20261105110000,
// exos-api/gapWrites.ts): route -> action, the scope and the creator's roles
// each action needs (both must equal the migration's
// _exos_api_gap_action_scope / _exos_api_gap_action_roles), and the bodies.

import { readFileSync } from 'node:fs';
import path from 'node:path';
import { describe, expect, it } from 'vitest';
import {
  CANCEL_MEMBERSHIP_ROLES, feeRuleFields, GAP_ACTION_ROLES, GAP_ACTION_SCOPE, GAP_ACTIONS, GAP_CREATED, GapBodyError, gapArgs,
  gapTarget, giftCardQuote,
} from '../../supabase/functions/_shared/api/gapWrites.ts';
import { matchRoute, ROUTES } from '../../supabase/functions/_shared/api/routes.ts';

const MIG = readFileSync(path.resolve(__dirname, '../../supabase/migrations/20261105110000_exos_fan_api.sql'), 'utf8');
const U = '7a10c3e1-1c2d-4e3f-8a9b-0c1d2e3f4a5b';

function sqlCase(fn: string): string {
  const m = new RegExp(`FUNCTION public\\.${fn}[\\s\\S]*?\\$\\$;`).exec(MIG);
  if (!m) throw new Error(`${fn} not found`);
  return m[0];
}

describe('gap writes', () => {
  it('GAP_ACTION_SCOPE equals _exos_api_gap_action_scope', () => {
    const sql = sqlCase('_exos_api_gap_action_scope');
    const out: Record<string, string> = {};
    for (const m of sql.matchAll(/WHEN p_action (?:IN \(([\s\S]*?)\)|= '([^']+)')\s*THEN '([a-z:]+)'/g)) {
      for (const a of (m[1] ?? `'${m[2]}'`).matchAll(/'([^']+)'/g)) out[a[1]] = m[3];
    }
    expect(out).toEqual({ ...GAP_ACTION_SCOPE });
  });

  it('GAP_ACTION_ROLES equals _exos_api_gap_action_roles', () => {
    const sql = sqlCase('_exos_api_gap_action_roles');
    expect(sql).toContain("WHEN p_action IN ('api_key.create', 'api_key.revoke') THEN ARRAY['owner']");
    expect(sql).toContain("WHEN p_action = 'membership.scan' THEN ARRAY['owner', 'manager', 'scanner']");
    expect(sql).toContain("WHEN p_action = 'donation.offline' THEN ARRAY['owner', 'manager', 'finance']");
    expect(sql).toContain("THEN ARRAY['owner', 'manager']");
    for (const a of Object.keys(GAP_ACTION_SCOPE)) {
      const want = a.startsWith('api_key.') ? ['owner'] : a === 'membership.scan' ? ['owner', 'manager', 'scanner']
        : a === 'donation.offline' ? ['owner', 'manager', 'finance'] : ['owner', 'manager'];
      expect(GAP_ACTION_ROLES[a], a).toEqual(want);
    }
    expect(CANCEL_MEMBERSHIP_ROLES).toEqual(['owner', 'manager']);
  });

  it('each route needs its action\'s scope, and writes are org-key routes', () => {
    for (const [id, spec] of Object.entries(GAP_ACTIONS)) {
      const r = ROUTES.find((x) => x.id === id);
      expect(r, id).toBeDefined();
      expect(r!.scope, id).toBe(GAP_ACTION_SCOPE[spec.action]);
      expect(r!.auth).toBe('api_key');
      expect(r!.method).not.toBe('GET');
      if (spec.target) expect(r!.path, id).toContain(`:${spec.target}`);
    }
    for (const id of GAP_CREATED) expect(GAP_ACTIONS[id], id).toBeDefined();
  });

  it("Opendate's admin paths answer", () => {
    expect(matchRoute('POST', '/event_series')?.route.id).toBe('create-series');
    expect(matchRoute('DELETE', `/event_series/${U}/event_series_events/${U}`)?.route.id).toBe('detach-series-event');
    expect(matchRoute('PATCH', `/confirms/${U}/organizer_fee_components/${U}`)?.route.id).toBe('update-event-fee-rule');
    expect(matchRoute('POST', `/confirms/${U}/seat_reconciliation/release_orphans`)?.route.id).toBe('release-orphan-seats');
    expect(matchRoute('GET', '/api_keys')?.route.id).toBe('list-api-keys');
  });
});

describe('bodies', () => {
  it("fee rules take Opendate's organizer fee component", () => {
    expect(feeRuleFields({ organizer_fee_component: { name: 'Facility', calculation: 'flat', amount: '1.50', passed_to_buyer: true } }, 'create'))
      .toEqual({ name: 'Facility', calc: 'fixed', kind: 'passed_on', amount_cents: 150, percent: null });
    expect(feeRuleFields({ name: 'Svc', amount: 5 }, 'create')).toEqual({ name: 'Svc', percent: 5 }); // calc defaults to percent in SQL
    expect(() => feeRuleFields({ percent: 5 }, 'create')).toThrow(/name/);
    expect(() => feeRuleFields({}, 'update')).toThrow(/at least one/);
    expect(() => feeRuleFields({ name: 'x', org_id: U }, 'create')).toThrow(/read-only/);
    expect(() => feeRuleFields({ name: 'x', percent: 101 }, 'create')).toThrow(/0 to 100/);
  });

  it('API keys, series, seats, attendees, scans, gifts, gift cards, donations', () => {
    expect(gapArgs('create-api-key', { api_key: { name: ' CI ', scopes: 'orders:read events:read' } }, {}))
      .toEqual({ name: 'CI', scopes: ['orders:read', 'events:read'] });
    expect(() => gapArgs('create-api-key', { scopes: [] }, {})).toThrow(GapBodyError);
    expect(gapArgs('cancel-series', {}, {})).toEqual({ scope: 'series_only', reason: null });
    expect(() => gapArgs('cancel-series', { scope: 'everything' }, {})).toThrow(/scope/);
    expect(gapArgs('detach-series-event', {}, { id: U, eid: U })).toEqual({ event_id: U });
    expect(() => gapArgs('cancel-series-date', { date: '12/18' }, {})).toThrow(/YYYY-MM-DD/);
    expect(() => gapArgs('release-orphan-seats', { seat_ids: [] }, {})).toThrow(/1 to 500/);
    expect(gapArgs('import-migrated-attendees', { guest_list_id: U, migrated_attendees: [{ name: 'A' }] }, {}))
      .toEqual({ list_id: U, rows: [{ name: 'A' }] });
    expect(gapArgs('create-membership-scan', { membership_scan: { membership_token: U } }, {})).toEqual({ membership_id: U });
    expect(() => gapArgs('gift-membership', { to_email: 'no' }, {})).toThrow(/email/);
    expect(gapArgs('issue-gift-card', { amount: 25, recipient_email: 'a@x.com' }, {}))
      .toEqual({ recipient_email: 'a@x.com', payment_method: 'comp', amount_cents: 2500 });
    expect(() => gapArgs('issue-gift-card', { amount_cents: 50 }, {})).toThrow(/100/);
    expect(() => gapArgs('issue-gift-card', { amount_cents: 500, payment_method: 'crypto' }, {})).toThrow(/payment_method/);
    const d = gapArgs('create-donation', { donation: { giving_campaign_id: U, amount_cents: 500 } }, {});
    expect(d).toEqual({ amount_cents: 500, method: 'other', anonymous: false, campaign_id: U });
    expect(gapTarget('create-donation', {}, d)).toBe(U);
    expect(gapTarget('create-membership-scan', {}, { membership_id: U })).toBe(U);
    expect(gapTarget('update-series', { id: U }, {})).toBe(U);
    expect(gapTarget('create-series', {}, {})).toBeNull();
  });

  it('gift card quotes validate the amount and add no fee', () => {
    const fixed = { id: U, currency: 'usd', amount_type: 'fixed', amounts_cents: [2500, 5000], min_cents: null, max_cents: null, active: true };
    expect(giftCardQuote(fixed, null)).toEqual({ product_id: U, currency: 'usd', amount_cents: 2500, total_cents: 2500, fees_cents: 0 });
    expect(giftCardQuote(fixed, '3000')).toEqual({ error: 'amount_cents must be one of 2500, 5000' });
    const open = { ...fixed, amount_type: 'custom', amounts_cents: null, min_cents: 1000, max_cents: 20000 };
    expect(giftCardQuote(open, '15000')).toMatchObject({ amount_cents: 15000, total_cents: 15000 });
    expect(giftCardQuote(open, '50')).toEqual({ error: 'amount_cents must be from 1000 to 20000' });
    expect(giftCardQuote({ ...fixed, active: false }, null)).toEqual({ error: 'this gift card product is not on sale' });
    expect(giftCardQuote(fixed, '1e3')).toEqual({ error: 'amount_cents must be a whole number of cents' });
  });
});
