import { describe, expect, it } from 'vitest';
import {
  campaignActions, campaignStatus, compareCells, donationActions, donationKind, filterCampaigns, filterDonations,
  filterImportedCards, filterRecurring, givingPermissions, goalPercent, importBatches, majorCents, matchesSearch,
  nextSort, pageRows, parseGiftCardFile, recurringActions, sortRows,
  type CampaignRow, type DonationRow, type ImportedCardRow, type RecurringRow,
} from './givingTables';
import {
  campaignBody, GivingBodyError, importBody, offlineRefundBody, redemptionBody,
} from '../../supabase/functions/_shared/api/giving';
import { normalizeAnyGiftCardCode, normalizeExternalGiftCardCode } from '../../supabase/functions/_shared/commerce';

const camp = (o: Partial<CampaignRow> = {}): CampaignRow => ({
  id: 'c1', name: 'Roof', slug: 'roof', currency: 'usd', goal_cents: 10000, active: true, completed_at: null,
  starts_at: null, ends_at: null, created_at: '2026-10-01T00:00:00Z', raised_cents: 2500, donation_count: 1, ...o,
});
const don = (o: Partial<DonationRow> = {}): DonationRow => ({
  id: 'd1', campaign_id: 'c1', amount_cents: 1000, cover_fees_cents: 0, total_cents: 1000, refunded_cents: 0, currency: 'usd',
  method: 'check', status: 'received', donor_name: 'Pat', donor_email: 'pat@x.com', anonymous: false, session_id: null,
  recurring_id: null, receipt_number: 3, created_at: '2026-10-02T00:00:00Z', ...o,
});

describe('sorting, search and paging', () => {
  it('sorts numbers, text and dates, empty last both ways, stable', () => {
    const rows = [{ k: 'b', n: 2 }, { k: 'A', n: null }, { k: 'c', n: 10 }, { k: 'a', n: 2 }];
    expect(sortRows(rows, { key: 'n', dir: 'asc' }).map((r) => r.k)).toEqual(['b', 'a', 'c', 'A']);
    expect(sortRows(rows, { key: 'n', dir: 'desc' }).map((r) => r.k)).toEqual(['c', 'b', 'a', 'A']);
    expect(sortRows(rows, { key: 'k', dir: 'asc' }).map((r) => r.k)).toEqual(['A', 'a', 'b', 'c']);
    expect(compareCells('item 2', 'item 10')).toBeLessThan(0);
    expect(compareCells('2026-01-02', '2026-01-10')).toBeLessThan(0);
  });
  it('flips the direction on the same column', () => {
    expect(nextSort({ key: 'name', dir: 'asc' }, 'name')).toEqual({ key: 'name', dir: 'desc' });
    expect(nextSort({ key: 'name', dir: 'asc' }, 'created_at', 'desc')).toEqual({ key: 'created_at', dir: 'desc' });
  });
  it('matches every word in any field, without case', () => {
    expect(matchesSearch(['Pat Lee', 'pat@x.com'], 'lee PAT')).toBe(true);
    expect(matchesSearch(['Pat Lee', null], 'sam')).toBe(false);
    expect(matchesSearch([], '  ')).toBe(true);
  });
  it('pages and clamps', () => {
    const rows = Array.from({ length: 23 }, (_, i) => i);
    expect(pageRows(rows, 3, 10)).toMatchObject({ rows: [20, 21, 22], page: 3, pages: 3, from: 21, to: 23, total: 23 });
    expect(pageRows(rows, 9, 10).page).toBe(3);
    expect(pageRows([], 1, 10)).toMatchObject({ rows: [], pages: 1, from: 0, to: 0 });
  });
});

describe('roles', () => {
  it('mirrors the SQL wrappers', () => {
    expect(givingPermissions('owner')).toMatchObject({ editCampaigns: true, deleteDonations: true, importGiftCards: true });
    expect(givingPermissions('finance')).toEqual({
      read: true, editCampaigns: false, deleteDonations: false, refundDonations: true, cancelMonthly: true, importGiftCards: false,
    });
    expect(givingPermissions('scanner').read).toBe(false);
    expect(givingPermissions(null, true).importGiftCards).toBe(true);
  });
});

describe('campaigns', () => {
  const mgr = givingPermissions('manager');
  it('status and actions follow the lifecycle', () => {
    expect(campaignStatus(camp({ active: false }))).toBe('draft');
    expect(campaignActions(camp({ active: false, donation_count: 0 }), mgr)).toEqual(['edit', 'activate', 'complete', 'delete']);
    expect(campaignActions(camp(), mgr)).toEqual(['edit', 'deactivate', 'complete']);
    expect(campaignActions(camp({ donation_count: 0 }), mgr, true)).not.toContain('delete');
    expect(campaignActions(camp({ completed_at: '2026-11-01T00:00:00Z', active: false }), mgr)).toEqual([]);
    expect(campaignActions(camp(), givingPermissions('finance'))).toEqual([]);
  });
  it('filters and reads the goal', () => {
    const rows = [camp(), camp({ id: 'c2', name: 'Bus', slug: 'bus', active: false })];
    expect(filterCampaigns(rows, { status: 'draft', search: '' }).map((c) => c.id)).toEqual(['c2']);
    expect(filterCampaigns(rows, { status: 'all', search: 'roo' }).map((c) => c.id)).toEqual(['c1']);
    expect(goalPercent(camp())).toBe(25);
    expect(goalPercent(camp({ goal_cents: 0 }))).toBeNull();
  });
});

describe('donations', () => {
  const owner = givingPermissions('owner');
  it('only an offline gift with no payment can be deleted; refunds while money is left', () => {
    expect(donationActions(don(), owner)).toEqual(['offline_refund', 'delete']);
    expect(donationActions(don({ method: 'card', session_id: 'cs_1' }), owner)).toEqual(['offline_refund']);
    expect(donationActions(don({ refunded_cents: 200 }), owner)).toEqual(['offline_refund']);
    expect(donationActions(don({ status: 'refunded', refunded_cents: 1000 }), owner)).toEqual([]);
    expect(donationActions(don(), givingPermissions('finance'))).toEqual(['offline_refund']);
    expect(donationActions(don(), givingPermissions('content'))).toEqual([]);
    expect(donationKind(don({ recurring_id: 'r1', method: 'card' }))).toBe('monthly');
  });
  it('filters by campaign, status, kind and donor', () => {
    const rows = [don(), don({ id: 'd2', refunded_cents: 100 }), don({ id: 'd3', status: 'refunded', campaign_id: 'c2' }),
      don({ id: 'd4', method: 'card', session_id: 'cs', donor_name: 'Sam' })];
    const all = { campaignId: 'all', status: 'all', kind: 'all', search: '' } as const;
    expect(filterDonations(rows, { ...all, status: 'partly_refunded' }).map((d) => d.id)).toEqual(['d2']);
    expect(filterDonations(rows, { ...all, campaignId: 'c2' }).map((d) => d.id)).toEqual(['d3']);
    expect(filterDonations(rows, { ...all, kind: 'online' }).map((d) => d.id)).toEqual(['d4']);
    expect(filterDonations(rows, { ...all, search: 'sam' }).map((d) => d.id)).toEqual(['d4']);
  });
});

describe('monthly gifts and imported cards', () => {
  const r = (o: Partial<RecurringRow>): RecurringRow => ({
    id: 'r', campaign_id: 'c1', amount_cents: 1000, cover_fees_cents: 0, currency: 'usd', status: 'active', donor_name: null,
    donor_email: 'a@x.com', current_period_end: null, last_paid_at: null, failed_payments: 0, cancel_requested_at: null,
    created_at: '2026-10-01', ...o,
  });
  it('cancel while it bills, for finance and up', () => {
    expect(recurringActions(r({}), givingPermissions('finance'))).toEqual(['cancel']);
    expect(recurringActions(r({ status: 'cancelled' }), givingPermissions('owner'))).toEqual([]);
    expect(recurringActions(r({}), givingPermissions('content'))).toEqual([]);
    expect(filterRecurring([r({}), r({ id: 'x', status: 'past_due' })], { campaignId: 'all', status: 'past_due', search: '' })).toHaveLength(1);
  });
  it('filters imported cards by state', () => {
    const c = (o: Partial<ImportedCardRow>): ImportedCardRow => ({
      id: 'g', last4: 'C123', currency: 'usd', initial_cents: 5000, balance_cents: 2500, status: 'active', external_source: 'gift_up',
      recipient_email: null, expires_at: null, created_at: '2026-10-01', ...o,
    });
    const rows = [c({}), c({ id: 's', balance_cents: 0 }), c({ id: 'e', expires_at: '2020-01-01' }), c({ id: 'v', status: 'voided' })];
    const f = { source: 'all', search: '' } as const;
    expect(filterImportedCards(rows, { ...f, state: 'with_balance' }).map((x) => x.id)).toEqual(['g']);
    expect(filterImportedCards(rows, { ...f, state: 'spent' }).map((x) => x.id)).toEqual(['s']);
    expect(filterImportedCards(rows, { ...f, state: 'expired' }).map((x) => x.id)).toEqual(['e']);
    expect(filterImportedCards(rows, { ...f, state: 'voided' }).map((x) => x.id)).toEqual(['v']);
  });
});

describe('gift card import file', () => {
  it('reads a Gift Up! style export', () => {
    const text = 'Code,Remaining Value,Initial Value,Expiry Date,Recipient Email\r\n'
      + 'GU-ABC123,"$1,250.50",2000,2027-12-31,sam@x.com\r\n'
      + 'GUZERO,0,10,,\r\n'
      + ',5,,,\r\n'
      + 'GUBAD1,lots,,,\r\n';
    const p = parseGiftCardFile(text);
    expect(p.cards).toEqual([{ code: 'GU-ABC123', balance_cents: 125050, initial_cents: 200000, expires_at: '2027-12-31', recipient_email: 'sam@x.com' }]);
    expect(p.errors.map((e) => e.line)).toEqual([3, 4, 5]);
  });
  it('takes cents columns and refuses a file without the columns', () => {
    expect(parseGiftCardFile('code,balance_cents\nX12345,700').cards).toEqual([{ code: 'X12345', balance_cents: 700 }]);
    expect(parseGiftCardFile('name,amount\na,1').errors[0].error).toMatch(/no code column/);
    expect(parseGiftCardFile('code').errors[0].error).toMatch(/header row/);
  });
  it('amounts and batches', () => {
    expect(majorCents('25')).toBe(2500);
    expect(majorCents('USD 10.5')).toBe(1050);
    expect(majorCents('1.234')).toBeNull();
    expect(importBatches(Array.from({ length: 1201 }, (_, i) => i)).map((b) => b.length)).toEqual([500, 500, 201]);
  });
  it('normalizes imported codes (and still knows Exos ones)', () => {
    expect(normalizeExternalGiftCardCode('gu-abc 123')).toBe('GUABC123');
    expect(normalizeExternalGiftCardCode('abc')).toBeNull();
    expect(normalizeAnyGiftCardCode('gu-abc-123')).toBe('GUABC123');
  });
});

describe('API bodies (exos-api giving routes)', () => {
  it('campaign: known fields only, Opendate spellings, wrapped or flat', () => {
    expect(campaignBody({ giving_campaign: { title: 'Roof', goal: '50.5', active: 'true' } })).toEqual({ name: 'Roof', goal_cents: 5050, active: true });
    expect(() => campaignBody({ colour: 'red' })).toThrow(GivingBodyError);
  });
  it('import: cents or major units, the cap, Gift Up! names', () => {
    const b = importBody({ giftcards: [{ code: 'A1B2C3', remaining_value: '12.00', initial_value: 20, expiry_date: '2027-01-01' }] });
    expect(b).toEqual({ source: 'gift_up', cards: [{ code: 'A1B2C3', balance_cents: 1200, initial_cents: 2000, expires_at: '2027-01-01' }] });
    expect(importBody({ source: 'Square', cards: [{ code: 'X', balance_cents: 'x' }] }).cards[0]).toEqual({ code: 'X', balance_cents: null });
    expect(() => importBody({ cards: [] })).toThrow(/non-empty/);
    expect(() => importBody({ cards: Array(501).fill({ code: 'A', balance_cents: 1 }) })).toThrow(/500/);
  });
  it('redemption and offline refund', () => {
    expect(redemptionBody({ gift_card_redemption: { gift_card_code: ' ABC ', amount: '15' } })).toEqual({ code: 'ABC', amountCents: 1500 });
    expect(() => redemptionBody({ amount_cents: 5 })).toThrow(/code/);
    expect(() => redemptionBody({ code: 'A', amount_cents: 0 })).toThrow(/positive/);
    expect(offlineRefundBody({ amount_cents: '300', method: 'cash' }, 'idem-key-1')).toEqual({ amount_cents: 300, reference: 'idem-key-1', method: 'cash' });
    expect(() => offlineRefundBody({ method: 'venmo' }, null)).toThrow(/method/);
    expect(() => offlineRefundBody({ reference: 'has space' }, null)).toThrow(/reference/);
  });
});
