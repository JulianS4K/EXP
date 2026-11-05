import { describe, expect, it } from 'vitest';
import {
  buyerLabel, checkOutSummary, DEFAULT_ORDER_TABLE, describeEdit, EditError, formatOrderAmount, orderActions,
  orderEditFields, orderPermissions, orderQuery, pageCount, pageRangeLabel, parseOrderEdit, parseOrderRow,
  parsePastedLine, parsePastedNames, previewInput, PreviewError, receiptEmail, statusLabel, ticketEditFields,
  ticketIdFrom, toggleSort, withFilter,
} from './orderDesk';

const TID = '2b9e4f1a-7c3d-4e5f-8a6b-0c1d2e3f4a5b';

describe('order edit bodies', () => {
  it('takes Opendate-wrapped or flat bodies, contact fields only', () => {
    expect(orderEditFields({ order: { first_name: ' Jane ', phone: '+1 555 0100' } }))
      .toEqual({ first_name: 'Jane', phone_number: '+1 555 0100' });
    expect(orderEditFields({ email: 'jane@example.com', notes: null, event_id: 'x' })).toEqual({ email: 'jane@example.com', notes: null });
  });

  it('refuses prices, quantities and anything else', () => {
    expect(() => orderEditFields({ amount_cents: 1 })).toThrow(/refund or reissue/);
    expect(() => orderEditFields({ order: { quantity: 3 } })).toThrow(EditError);
    expect(() => orderEditFields({ favourite_colour: 'blue' })).toThrow(/can't be changed/);
    expect(() => orderEditFields({})).toThrow(/nothing to change/);
    expect(() => orderEditFields({ email: 'nope' })).toThrow(/email/);
    expect(() => orderEditFields({ email: null })).toThrow(/email/);
    expect(() => orderEditFields({ phone_number: 'call me' })).toThrow(/phone/);
    expect(() => orderEditFields({ first_name: 'x'.repeat(61) })).toThrow(/60/);
    expect(() => orderEditFields({ notes: { a: 1 } })).toThrow(/string/);
  });

  it('ticket edits: the attendee only; check-in has its own route', () => {
    expect(ticketEditFields({ ticket: { attendee_name: 'Sam Ray' } })).toEqual({ attendee_name: 'Sam Ray' });
    expect(ticketEditFields({ first_name: 'Sam', last_name: 'Ray', barcode: 'x' })).toEqual({ first_name: 'Sam', last_name: 'Ray' });
    expect(() => ticketEditFields({ checked_in_at: 'now' })).toThrow(/check-in/);
    expect(() => ticketEditFields({ owner_id: 'u' })).toThrow(EditError);
    expect(() => ticketEditFields({})).toThrow(/nothing/);
  });

  it('receipt email is optional and validated', () => {
    expect(receiptEmail({})).toBeNull();
    expect(receiptEmail({ email: '' })).toBeNull();
    expect(receiptEmail({ email: ' a@b.co ' })).toBe('a@b.co');
    expect(() => receiptEmail({ email: 'a@' })).toThrow(EditError);
  });

  it('finds the ticket id in an id or a door code, never verifying anything', () => {
    expect(ticketIdFrom(TID.toUpperCase())).toBe(TID);
    expect(ticketIdFrom(`T-${TID}:owner:123:mac`)).toBe(TID);
    expect(ticketIdFrom('ABC123XYZ')).toBeNull();
    expect(ticketIdFrom('T-nope:1')).toBeNull();
  });
});

describe('guest-list preview input', () => {
  it('reads pasted lines: bullets, numbering and plus-ones', () => {
    expect(parsePastedLine('- Maya Chen +2')).toEqual({ name: 'Maya Chen', plus_ones: 2 });
    expect(parsePastedLine('2. Tessa (+1)')).toEqual({ name: 'Tessa', plus_ones: 1 });
    expect(parsePastedLine('Rob plus 3')).toEqual({ name: 'Rob', plus_ones: 3 });
    expect(parsePastedLine('• Ana x2,')).toEqual({ name: 'Ana', plus_ones: 2 });
    expect(parsePastedLine('Hey team:')).toBe('not_a_name');
    expect(parsePastedLine('Who is coming?')).toBe('not_a_name');
    expect(parsePastedLine('ana@example.com')).toBe('not_a_name');
    expect(parsePastedLine('please add these people to the list tonight')).toBe('too_long');
    expect(parsePastedLine('   ')).toBe('empty');
    expect(parsePastedLine('12)')).toBe('empty');
  });

  it('keeps the line numbers of what it skipped', () => {
    const r = parsePastedNames('Hi all!\n\nMaya Chen +2\nTessa\r\nThanks!');
    expect(r.rows).toEqual([{ name: 'Maya Chen', plus_ones: 2 }, { name: 'Tessa', plus_ones: 0 }]);
    expect(r.skipped.map((s) => [s.line, s.reason])).toEqual([[1, 'not_a_name'], [5, 'not_a_name']]);
  });

  it('takes exactly one of text, csv and rows', () => {
    expect(() => previewInput({})).toThrow(PreviewError);
    expect(() => previewInput({ text: 'a', csv: 'b' })).toThrow(/one of/);
    expect(() => previewInput({ text: 5 })).toThrow(/string/);
    expect(() => previewInput({ rows: 'x' })).toThrow(/list/);
    expect(() => previewInput({ csv: 'Name' })).toThrow(/no rows/);
  });

  it('reads a CSV with the Door import parser', () => {
    const r = previewInput({ csv: 'Attendee first name,Attendee last name,Email,Barcode #\nMaya,Chen,maya@x.com,123 456\nMaya,Chen,maya@x.com,123456\n,,z@x.com,' });
    expect(r.source).toBe('csv');
    expect(r.rows).toEqual([{ name: 'Maya Chen', email: 'maya@x.com', code: '123456', source: 'Import' }]);
    expect(r.plan).toEqual({ noName: 1, nameIsEmail: 0, repeatedCodes: 1, sharedCodes: 0, overLimit: 0 });
  });

  it('normalizes JSON rows', () => {
    const r = previewInput({ rows: [{ first_name: 'Maya', last_name: 'Chen', plus_ones: '2' }, { name: 'Bo', plus_ones: -1, email: 7 }, null] });
    expect(r.rows).toEqual([{ name: 'Maya Chen', plus_ones: 2 }, { name: 'Bo', email: '7' }, { name: '' }]);
  });
});

describe('orders table', () => {
  const row = parseOrderRow({ session_id: 'cs_1', event_id: 'e', event_name: 'Night', status: 'fulfilled', quantity: '2',
    amount_cents: 6000, currency: 'usd', buyer_email: 'jane@x.com', first_name: 'Jane', created_at: '2026-11-01T00:00:00Z', receipts_sent: 1 });

  it('parses and labels a row', () => {
    expect(row.quantity).toBe(2);
    expect(buyerLabel(row)).toBe('Jane');
    expect(buyerLabel({ firstName: null, lastName: null, email: 'a@x.com' })).toBe('a@x.com');
    expect(buyerLabel({ firstName: null, lastName: null, email: null })).toBe('Guest');
    expect(statusLabel('partially_refunded')).toBe('Part refunded');
    expect(statusLabel('weird')).toBe('weird');
    expect(formatOrderAmount(123456, 'usd')).toBe('$1,234.56');
    expect(formatOrderAmount(1250, 'eur')).toBe('EUR 12.50');
  });

  it('sorting, filtering and paging state', () => {
    const s1 = toggleSort({ ...DEFAULT_ORDER_TABLE, page: 3 }, 'created_at');
    expect([s1.sort, s1.desc, s1.page]).toEqual(['created_at', false, 1]);
    const s2 = toggleSort(s1, 'email');
    expect([s2.sort, s2.desc]).toEqual(['email', false]);
    expect(toggleSort(s2, 'email').desc).toBe(true);
    expect(toggleSort(s2, 'amount_cents').desc).toBe(true);
    expect(withFilter({ ...DEFAULT_ORDER_TABLE, page: 4 }, { status: 'refunded' })).toMatchObject({ status: 'refunded', page: 1 });
    expect(pageCount(0, 25)).toBe(1);
    expect(pageCount(51, 25)).toBe(3);
    expect(pageRangeLabel(2, 25, 51)).toBe('26-50 of 51');
    expect(pageRangeLabel(3, 25, 51)).toBe('51-51 of 51');
    expect(pageRangeLabel(1, 25, 0)).toBe('0 of 0');
    expect(orderQuery('o', { ...DEFAULT_ORDER_TABLE, search: '  jane ', page: 2 }))
      .toEqual({ p_org_id: 'o', p_search: 'jane', p_status: null, p_event_id: null, p_sort: 'created_at', p_desc: true, p_limit: 25, p_offset: 25 });
  });

  it('roles: writes hidden from finance and everyone else', () => {
    expect(orderPermissions('owner')).toEqual({ read: true, edit: true, resend: true, checkOut: true, history: true, receiptRules: true });
    expect(orderPermissions('manager').receiptRules).toBe(false);
    expect(orderPermissions('finance')).toEqual({ read: true, edit: false, resend: false, checkOut: false, history: false, receiptRules: false });
    expect(orderPermissions('scanner').read).toBe(false);
    expect(orderPermissions(null, true).receiptRules).toBe(true);
    expect(orderActions(row, orderPermissions('manager'))).toEqual(['edit', 'receipt', 'check_out', 'history']);
    expect(orderActions({ status: 'refunded' }, orderPermissions('owner'))).toEqual(['edit', 'receipt', 'history']);
    expect(orderActions({ status: 'failed' }, orderPermissions('owner'))).toEqual(['history']);
    expect(orderActions(row, orderPermissions('finance'))).toEqual([]);
  });

  it('describes the edit history', () => {
    expect(describeEdit(parseOrderEdit({ action: 'order.update', changes: {
      phone: { from: null, to: '+1' }, email: { from: 'a@x.com', to: 'b@x.com' } } })))
      .toBe('email: a@x.com → b@x.com; phone: (none) → +1');
    expect(describeEdit({ action: 'order.receipt', changes: { to: 'b@x.com', override: true } })).toBe('Receipt sent to b@x.com (another address)');
    expect(describeEdit({ action: 'order.check_out', changes: { checked_out: 1 } })).toBe('Checked out 1 ticket');
    expect(describeEdit({ action: 'ticket.update', changes: {} })).toBe('Ticket edited');
    expect(parseOrderEdit({ via_api: true }).viaApi).toBe(true);
  });

  it('summarizes a check-out', () => {
    expect(checkOutSummary({ checked_out: 2, results: [] })).toBe('Checked out 2 tickets.');
    expect(checkOutSummary({ checked_out: 0, results: [{ reason: 'exit-not-allowed' }] })).toMatch(/without re-entry/);
    expect(checkOutSummary({ checked_out: 0, results: [{ reason: 'not-inside' }] })).toMatch(/is inside/);
  });
});

describe('guest-list preview table', () => {
  it('filters by status in file order and explains each row', async () => {
    const { filterPreviewRows, previewStatusText } = await import('./orderDesk');
    const rows = [
      { row: 3, status: 'duplicate', reason: 'in_file' },
      { row: 1, status: 'ready', warnings: ['invalid_email'] },
      { row: 2, status: 'duplicate', reason: 'existing', existing_list_name: 'Friends' },
      { row: 4, status: 'too_many_plus_ones', reason: 'at most 5 plus-ones' },
    ];
    expect(filterPreviewRows(rows, '').map((r) => r.row)).toEqual([1, 2, 3, 4]);
    expect(filterPreviewRows(rows, 'duplicate').map((r) => r.row)).toEqual([2, 3]);
    expect(rows.map(previewStatusText)).toEqual([
      'Repeated in this import', 'Ready (email dropped: not valid)', 'Already on Friends', 'Too many plus-ones (at most 5 plus-ones)',
    ]);
  });
});
