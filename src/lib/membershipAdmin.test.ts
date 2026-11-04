import { describe, expect, it } from 'vitest';
import {
  attendeeChanges, canEditProduct, centsFromMajor, compareValues, EMPTY_PRODUCT_FORM, endOfDayIso, issueFields,
  memberActions, memberLockReason, membershipRoles, pageCount, productActions, productFields, productToForm,
  rangeLabel, sortIndicator, tablePage, toggleSort, type MemberRow,
} from './membershipAdmin';

describe('product lifecycle', () => {
  it('draft -> published <-> unpublished -> archived, archived final', () => {
    expect(productActions('draft')).toEqual(['publish', 'archive']);
    expect(productActions('published')).toEqual(['unpublish', 'archive']);
    expect(productActions('unpublished')).toEqual(['publish', 'archive']);
    expect(productActions('archived')).toEqual([]);
    expect(canEditProduct('archived')).toBe(false);
    expect(canEditProduct('draft')).toBe(true);
  });
  it('roles: owner / manager write, finance reads, the rest nothing', () => {
    expect(membershipRoles('owner')).toEqual({ canRead: true, canWrite: true, canImports: true });
    expect(membershipRoles('manager').canWrite).toBe(true);
    expect(membershipRoles('finance')).toEqual({ canRead: true, canWrite: false, canImports: false });
    expect(membershipRoles('scanner').canRead).toBe(false);
    expect(membershipRoles(null, true).canWrite).toBe(true);
  });
});

describe('member actions', () => {
  const m = (o: Partial<MemberRow> = {}): MemberRow => ({
    id: 'm', status: 'active', effective_status: 'active', stripe_billed: false, ended_reason: null,
    current_period_end: '2030-01-01T00:00:00Z', ...o,
  });
  it('a comp can be extended or cancelled, a cancelled one reactivated', () => {
    expect(memberActions(m())).toEqual(['edit', 'extend', 'cancel']);
    expect(memberActions(m({ status: 'cancelled', effective_status: 'cancelled' }))).toEqual(['edit', 'reactivate']);
    expect(memberActions(m({ effective_status: 'expired' }))).toEqual(['edit', 'reactivate']);
  });
  it('Stripe-billed, refunded and unclaimed gifts only take a rename', () => {
    expect(memberActions(m({ stripe_billed: true }))).toEqual(['edit']);
    expect(memberActions(m({ status: 'cancelled', ended_reason: 'refunded' }))).toEqual(['edit']);
    expect(memberActions(m({ status: 'pending', effective_status: 'pending' }))).toEqual(['edit']);
    expect(memberLockReason(m({ ended_reason: 'refunded' }))).toMatch(/Refunded/);
    expect(memberLockReason(m({ stripe_billed: true }))).toMatch(/Stripe/);
    expect(memberLockReason(m())).toBeNull();
  });
});

describe('tables', () => {
  const rows = [
    { id: 'a', name: 'Gold', price_cents: 1500, status: 'published', created_at: '2026-10-02' },
    { id: 'b', name: 'basic', price_cents: 500, status: 'draft', created_at: '2026-10-03' },
    { id: 'c', name: 'Annual', price_cents: null, status: 'archived', created_at: '2026-10-01' },
    { id: 'd', name: 'Annual', price_cents: 900, status: 'unpublished', created_at: null },
  ];
  it('sorts case-insensitively, nulls last both ways, tiebreak on id', () => {
    expect(tablePage(rows, { sort: { key: 'name', desc: false } }).rows.map((r) => r.id)).toEqual(['c', 'd', 'b', 'a']);
    expect(tablePage(rows, { sort: { key: 'price_cents', desc: false } }).rows.map((r) => r.id)).toEqual(['b', 'd', 'a', 'c']);
    expect(tablePage(rows, { sort: { key: 'price_cents', desc: true } }).rows.map((r) => r.id)).toEqual(['a', 'd', 'b', 'c']);
    expect(tablePage(rows, { sort: { key: 'created_at', desc: true } }).rows.map((r) => r.id)).toEqual(['b', 'a', 'c', 'd']);
  });
  it('filters, searches and pages', () => {
    const live = tablePage(rows, { filter: (r) => r.status !== 'archived', search: 'ann', searchIn: ['name'] });
    expect(live.rows.map((r) => r.id)).toEqual(['d']);
    const p2 = tablePage(rows, { sort: { key: 'name', desc: false }, perPage: 3, page: 2 });
    expect(p2).toMatchObject({ total: 4, page: 2, pages: 2 });
    expect(p2.rows.map((r) => r.id)).toEqual(['a']);
    expect(tablePage(rows, { perPage: 3, page: 9 }).page).toBe(2);
    expect(tablePage([], { perPage: 3 })).toMatchObject({ total: 0, pages: 1, page: 1 });
  });
  it('sort toggling, indicators, page maths', () => {
    expect(toggleSort({ key: 'name', desc: false }, 'name')).toEqual({ key: 'name', desc: true });
    expect(toggleSort({ key: 'name', desc: true }, 'created_at', ['created_at'])).toEqual({ key: 'created_at', desc: true });
    expect(toggleSort({ key: 'name', desc: true }, 'price')).toEqual({ key: 'price', desc: false });
    expect(sortIndicator({ key: 'name', desc: true }, 'name')).toBe('▼');
    expect(sortIndicator({ key: 'name', desc: true }, 'x')).toBe('');
    expect(pageCount(0, 50)).toBe(1);
    expect(pageCount(101, 50)).toBe(3);
    expect(rangeLabel(2, 25, 60)).toBe('26–50 of 60');
    expect(rangeLabel(3, 25, 60)).toBe('51–60 of 60');
    expect(rangeLabel(1, 25, 0)).toBe('0 of 0');
    expect(compareValues('item 2', 'Item 10')).toBeLessThan(0);
  });
});

describe('forms', () => {
  it('prices in major units', () => {
    expect(centsFromMajor('12.5')).toBe(1250);
    expect(centsFromMajor('$9.99')).toBe(999);
    expect(centsFromMajor('10')).toBe(1000);
    expect(centsFromMajor('1.234')).toBeNull();
    expect(centsFromMajor('')).toBeNull();
  });
  it('product fields: create carries billing, update only the changes', () => {
    const f = { ...EMPTY_PRODUCT_FORM, name: ' Gold ', price: '15' };
    expect(productFields(f, 'create')).toMatchObject({ name: 'Gold', price_cents: 1500, billing: 'month', discount_percent: 10 });
    const before = { name: 'Gold', description: null, price_cents: 1500, duration_days: 365, discount_percent: '10.000', presale: true,
      free_tickets_per_period: 0, guest_allowance: 0, household_seats: 0, giftable: true, billing: 'month' };
    expect(productFields(productToForm(before), 'update', before)).toEqual({});
    expect(productFields({ ...productToForm(before), price: '18' }, 'update', before)).toEqual({ price_cents: 1800 });
    expect(() => productFields({ ...f, price: '0.10' }, 'create')).toThrow(/at least/);
    expect(() => productFields({ ...f, name: ' ' }, 'create')).toThrow(/name/);
    expect(() => productFields({ ...f, guest_allowance: '50' }, 'create')).toThrow(/Guests/);
    expect(() => productFields({ ...f, discount_percent: '120' }, 'create')).toThrow(/discount/);
  });
  it('issue fields', () => {
    const today = new Date('2026-11-02T12:00:00Z');
    expect(issueFields({ product_id: 'p', email: ' A@B.co ', member_name: '', source: 'import', expires_on: '2027-01-31', staff_notes: '' }, today))
      .toEqual({ product_id: 'p', email: 'a@b.co', source: 'import', expires_at: '2027-01-31T23:59:59Z' });
    expect(() => issueFields({ product_id: '', email: 'a@b.co', member_name: '', source: 'comp', expires_on: '', staff_notes: '' })).toThrow(/Pick/);
    expect(() => issueFields({ product_id: 'p', email: 'nope', member_name: '', source: 'comp', expires_on: '', staff_notes: '' })).toThrow(/email/);
    expect(() => endOfDayIso('2026-11-01', today)).toThrow(/future/);
  });
  it('attendee changes: only what changed, codes as the door stores them', () => {
    const before = { guest_name: 'Ann', email: 'ann@x.com', code: 'POSH-1', ticket_label: 'GA', note: null };
    expect(attendeeChanges(before, { guest_name: 'Ann', email: 'ANN@x.com', code: 'posh-1', ticket_label: 'GA', note: '' })).toEqual({});
    expect(attendeeChanges(before, { guest_name: 'Ann Lee', email: '', code: 'posh 2', ticket_label: 'VIP', note: 'late' }))
      .toEqual({ guest_name: 'Ann Lee', email: null, code: 'POSH2', ticket_label: 'VIP', note: 'late' });
    expect(() => attendeeChanges(before, { guest_name: ' ', email: '', code: '', ticket_label: '', note: '' })).toThrow(/name/);
  });
});
