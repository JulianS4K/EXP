// Offer, budget, finance and deal bodies for the partner API
// (supabase/functions/_shared/api/finance.ts). The SQL (migs 20261031100000 /
// 20261031100500, tests/exos/test_offers_settlements.sql) validates again.

import { describe, expect, it } from 'vitest';
import { BodyError } from '../../supabase/functions/_shared/api/booking.ts';
import {
  budgetLineBody, budgetPatch, categoryBody, cents, dealBody, financeItemBody, glCodeBody, offerBody, pnlRange, poolBody,
  settlementPatch, templateBody, ticketCountsBody, unwrapBody,
} from '../../supabase/functions/_shared/api/finance.ts';

const ID = '7d10a3e1-1c2d-4e3f-8a9b-0c1d2e3f4a5b';

describe('offer bodies', () => {
  it('takes the documented fields and never org_id, status or the token', () => {
    const b = offerBody({ artist_name: 'X', org_id: 'o', status: 'accepted', response_token_hash: 'h', terms: { deal_type: 'flat' } }, true);
    expect(b).toEqual({ artist_name: 'X', terms: { deal_type: 'flat' } });
  });

  it("reads Opendate's wrapped v3_offer body and its names", () => {
    const b = offerBody({ v3_offer: { event_name: 'Night', dollar_amount: 1500.5, upside_percentage: '85', v3_budget_id: ID, calendar_event_id: ID, pool_percentage: 40 } }, true);
    expect(b).toEqual({ title: 'Night', budget_id: ID, hold_id: ID, pool_share_percent: 40, terms: { guarantee_cents: 150050, percentage: 85 } });
    expect(() => offerBody({ dollar_amount: -1 }, true)).toThrow(BodyError);
  });

  it('a change needs something to change; budget and template only on create', () => {
    expect(() => offerBody({}, false)).toThrow(/Nothing/);
    expect(offerBody({ notes: 'x', template_id: ID, budget: {} }, false)).toEqual({ notes: 'x' });
  });
});

describe('templates, budgets, pools', () => {
  it('templates', () => {
    expect(templateBody({ name: ' Club ', currency: 'eur', expires_in_days: 7 }, false)).toEqual({ name: 'Club', currency: 'EUR', expires_in_days: 7 });
    expect(() => templateBody({ name: 'X', expires_in_days: 400 }, false)).toThrow(/365/);
    expect(() => templateBody({ name: 'X', terms: [] }, false)).toThrow(/terms/);
  });

  it('budgets and lines', () => {
    expect(budgetPatch({ capacity: '500', sell_through_percent: 80 })).toEqual({ capacity: 500, sell_through_percent: 80 });
    expect(() => budgetPatch({ sell_through_percent: 101 })).toThrow(/percentage/);
    expect(budgetLineBody({ name: 'Sound', amount_cents: 100 }, false)).toEqual({ label: 'Sound', kind: 'expense', amount_cents: 100 });
    expect(() => budgetLineBody({ label: 'X', amount_cents: 1.5 }, false)).toThrow(/cents/);
    expect(() => budgetLineBody({ label: 'X', kind: 'loss' }, false)).toThrow(/kind/);
  });

  it('pools', () => {
    expect(poolBody({ v3_offer_id: ID, mode: 'pool' }, true)).toEqual({ offerId: ID, budgetId: null, mode: 'pool', terms: null });
    expect(() => poolBody({}, true)).toThrow(/offer_id or budget_id/);
    expect(() => poolBody({ budget_id: ID, mode: 'shared' }, true)).toThrow(/mode/);
    expect(() => poolBody({}, false)).toThrow(/Nothing/);
  });
});

describe('finance bodies', () => {
  it('categories never take key or system; GL codes are shaped', () => {
    expect(categoryBody({ name: 'Security', kind: 'expense', key: 'talent', system: true }, false)).toEqual({ name: 'Security', kind: 'expense' });
    expect(glCodeBody({ code: '5100', name: 'Talent' }, false)).toEqual({ code: '5100', name: 'Talent' });
    expect(() => glCodeBody({ code: '51 00', name: 'X' }, false)).toThrow(/code/);
  });

  it('items never take auto; cents are whole and non-negative', () => {
    expect(financeItemBody({ finance_item: { name: 'Sound', actual_cents: null, auto: 'venue-rental' } }, false))
      .toEqual({ label: 'Sound', kind: 'expense', amount_cents: 0, actual_cents: null });
    expect(cents('12', 'x')).toBe(12);
    expect(() => cents(-1, 'x')).toThrow(BodyError);
  });

  it('deals: fundraising starts at identification', () => {
    expect(dealBody({ name: 'Gala', deal_type: 'fundraising', expected_close_on: '2026-12-01' }, false))
      .toEqual({ name: 'Gala', deal_type: 'fundraising', stage: 'identification', expected_close_on: '2026-12-01' });
    expect(() => dealBody({ name: 'X', probability: 120 }, false)).toThrow(/probability/);
  });

  it('settlement and ticket-count patches', () => {
    expect(settlementPatch({ adjustments: [], revision: 3, status: 'finalized' })).toEqual({ patch: { adjustments: [] }, revision: 3 });
    expect(() => settlementPatch({ revision: 1 })).toThrow(/Nothing/);
    expect(ticketCountsBody({ enabled: true, junk: 1 })).toEqual({ enabled: true });
  });

  it('P&L range: default 90 days, at most 366', () => {
    expect(pnlRange(new URLSearchParams(), '2026-11-01')).toEqual({ from: '2026-11-01', to: '2027-01-30' });
    expect(() => pnlRange(new URLSearchParams('from=2026-01-01&to=2027-06-01'), '2026-11-01')).toThrow(/366/);
    expect(() => pnlRange(new URLSearchParams('from=2026-02-30'), '2026-11-01')).toThrow(/YYYY-MM-DD/);
  });

  it('unwraps only objects', () => {
    expect(unwrapBody({ deal: { name: 'x' } }, 'deal')).toEqual({ name: 'x' });
    expect(() => unwrapBody([1])).toThrow(BodyError);
  });
});
