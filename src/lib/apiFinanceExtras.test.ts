// Partner API bodies and routes for brackets, ledger codes, imports,
// reporting rows and the cash summary (supabase/functions/_shared/api/
// financeExtras.ts, mig 20261102120000).

import { describe, expect, it } from 'vitest';
import {
  assignmentBody, bracketBody, cashRange, enumParam, importBody, isoParam, REVENUE_TYPES, revenueCodeBody,
} from '../../supabase/functions/_shared/api/financeExtras.ts';
import { matchRoute } from '../../supabase/functions/_shared/api/routes.ts';

const ID = '9a1b2c3d-4e5f-4a6b-8c7d-0e1f2a3b4c5d';

describe('bracketBody', () => {
  it('takes ours and Opendate\'s names, wrapped or not', () => {
    expect(bracketBody({ offer_id: ID, threshold: 2_000_000, percentage: 90 }, true)).toEqual({ offerId: ID, row: { threshold: 2_000_000, percentage: 90 } });
    expect(bracketBody({ v3_deal_bracket: { v3_offer_id: ID, deal_bracket_basis: 'ticket_count', threshold: '500', upside_percentage: '85.5' } }, true))
      .toEqual({ offerId: ID, row: { basis: 'tickets', threshold: 500, percentage: 85.5 } });
  });
  it('needs the offer, threshold and percentage to create', () => {
    expect(() => bracketBody({ threshold: 1, percentage: 1 }, true)).toThrow(/offer_id/);
    expect(() => bracketBody({ offer_id: ID, percentage: 1 }, true)).toThrow(/threshold/);
    expect(() => bracketBody({ offer_id: ID, threshold: 1 }, true)).toThrow(/percentage/);
  });
  it('refuses bad numbers, a move and an empty patch', () => {
    expect(() => bracketBody({ offer_id: ID, threshold: -1, percentage: 1 }, true)).toThrow(/threshold/);
    expect(() => bracketBody({ offer_id: ID, threshold: 1.5, percentage: 1 }, true)).toThrow(/threshold/);
    expect(() => bracketBody({ offer_id: ID, threshold: 1, percentage: 100.1 }, true)).toThrow(/percentage/);
    expect(() => bracketBody({ offer_id: ID, threshold: 1, percentage: 1.0005 }, true)).toThrow(/3 decimals/);
    expect(() => bracketBody({ offer_id: ID, threshold: 1, percentage: 1, basis: 'gross' }, true)).toThrow(/basis/);
    expect(() => bracketBody({ offer_id: ID }, false)).toThrow(/move/);
    expect(() => bracketBody({}, false)).toThrow(/Nothing/);
    expect(bracketBody({ percentage: 70 }, false)).toEqual({ offerId: null, row: { percentage: 70 } });
  });
});

describe('ledger-code bodies', () => {
  it('overrides: a revenue type and a code; a patch repoints only', () => {
    expect(assignmentBody({ general_ledger_code_assignment: { revenue_type: 'tax', general_ledger_code_id: ID } }, true))
      .toEqual({ revenue_type: 'tax', gl_code_id: ID });
    expect(() => assignmentBody({ revenue_type: 'nope', gl_code_id: ID }, true)).toThrow(/revenue_type/);
    expect(() => assignmentBody({ revenue_type: 'tax', gl_code_id: ID }, false)).toThrow(/repointed/);
    expect(() => assignmentBody({ revenue_type: 'tax' }, true)).toThrow(/gl_code_id/);
  });
  it('revenue codes: set or clear', () => {
    expect(revenueCodeBody('tickets', { gl_code_id: ID })).toEqual({ revenueType: 'tickets', glCodeId: ID });
    expect(revenueCodeBody('tickets', { gl_code_id: null })).toEqual({ revenueType: 'tickets', glCodeId: null });
    expect(() => revenueCodeBody('nope', { gl_code_id: ID })).toThrow(/revenue type/);
    expect(() => revenueCodeBody('tickets', {})).toThrow(/gl_code_id/);
    expect(REVENUE_TYPES).toContain('bar');
  });
});

describe('importBody', () => {
  it('takes entries, Opendate\'s key, or a bare list', () => {
    const row = { source: 'bar', amount_cents: 100 };
    expect(importBody({ entries: [row] })).toEqual([row]);
    expect(importBody({ imported_ledger_entries: [row] })).toEqual([row]);
    expect(importBody([row])).toEqual([row]);
  });
  it('caps the batch and wants cents', () => {
    expect(() => importBody({ entries: [] })).toThrow(/1 to 500/);
    expect(() => importBody({ entries: Array.from({ length: 501 }, () => ({})) })).toThrow(/500/);
    expect(() => importBody({ entries: ['x'] })).toThrow(/object/);
    expect(() => importBody({ entries: [{ amount: '4.80' }] })).toThrow(/amount_cents/);
  });
});

describe('query parameters', () => {
  it('cash summary window, ours or Opendate\'s', () => {
    expect(cashRange(new URLSearchParams('from=2026-10-01&to=2026-11-01T00:00:00Z'))).toEqual({ from: '2026-10-01', to: '2026-11-01T00:00:00Z' });
    expect(cashRange(new URLSearchParams('q[created_at_gt]=2026-06-15T00:00:00'))).toEqual({ from: '2026-06-15T00:00:00', to: null });
    expect(() => cashRange(new URLSearchParams('from=2026-11-02&to=2026-11-01'))).toThrow(/before/);
    expect(() => isoParam(new URLSearchParams('from=yesterday'), 'from')).toThrow(/ISO/);
  });
  it('enums', () => {
    expect(enumParam(new URLSearchParams('imported=true'), ['true', 'false'] as const, 'imported')).toBe('true');
    expect(() => enumParam(new URLSearchParams('source_type=x'), ['order'] as const, 'source_type')).toThrow(/order/);
  });
});

describe('routes', () => {
  it('answers Opendate\'s spellings', () => {
    expect(matchRoute('GET', '/v3_deal_brackets')?.route.id).toBe('list-deal-brackets');
    expect(matchRoute('PATCH', `/v3_deal_brackets/${ID}`)?.route.id).toBe('update-deal-bracket');
    expect(matchRoute('GET', `/confirms/${ID}/general_ledger_code_assignments`)?.route.id).toBe('list-gl-code-assignments');
    expect(matchRoute('DELETE', `/confirms/${ID}/general_ledger_code_assignments/${ID}`)?.route.id).toBe('delete-gl-code-assignment');
    expect(matchRoute('POST', `/confirms/${ID}/general_ledger_code_backfills`)?.route.id).toBe('backfill-gl-codes');
    expect(matchRoute('POST', '/imported_ledger_entries/bulk')?.route.id).toBe('import-ledger-entries');
    expect(matchRoute('GET', `/reporting_rows/${ID}`)?.route.id).toBe('get-reporting-row');
    expect(matchRoute('GET', `/confirms/${ID}/cash_summary`)?.route.id).toBe('get-cash-summary');
  });
  it('reads need :read, writes :write', () => {
    expect(matchRoute('GET', '/reporting-rows')?.route.scope).toBe('finance:read');
    expect(matchRoute('POST', '/deal-brackets')?.route.scope).toBe('booking:write');
    expect(matchRoute('PUT', '/gl-revenue-codes/tickets')?.route.scope).toBe('finance:write');
    expect(matchRoute('GET', `/events/${ID}/cash-summary`)?.route.scope).toBe('finance:read');
  });
});
