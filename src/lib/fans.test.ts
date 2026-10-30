// Fan profiles, tags, refund queue parsing and the fan CSV (mig 20261031120000).
import { describe, expect, it, vi } from 'vitest';

vi.mock('./supabase', () => ({ supabase: {} }));
import {
  EMAIL_LIST_LABEL, FANS_CSV_HEADER, fanName, fansCsvRows, parseFanDetail, parseFanRow, parseMyAskRow, parseOrgTag, parseQueueAsk,
} from './fans';
import { toCsv } from './csv';

describe('fans', () => {
  it('parses a list row', () => {
    const r = parseFanRow({
      id: 'f1', email: 'dana@x.com', first_name: 'Dana', has_account: true, orders_count: '3',
      last_order_at: '2026-10-04T14:01:02Z', email_list: 'subscribed', tags: [{ id: 't', name: 'VIP', color: '#aa00ff', tagged_item_id: 'i' }],
    });
    expect(r).toMatchObject({ id: 'f1', hasAccount: true, ordersCount: 3, emailList: 'subscribed', lastName: null });
    expect(r.tags).toEqual([{ id: 't', name: 'VIP', color: '#aa00ff', taggedItemId: 'i' }]);
    expect(parseFanRow({ id: 'f2', email_list: 'weird', orders_count: -2 })).toMatchObject({ emailList: 'none', ordersCount: 0 });
  });

  it('parses a profile with consent as read-only facts', () => {
    const d = parseFanDetail({
      id: 'f1', email: 'dana@x.com',
      stats: { orders: 2, tickets: 3, money: [{ currency: 'usd', paid_cents: 9000, refunded_cents: 1000, orders: 2 }] },
      consent: {
        email_list: { status: 'subscribed', since: '2026-06-02T08:00:00Z', source: 'signup_form:x' },
        follows_org: true, ad_consent: 'denied', marketing_mail_opt_out: false,
        sms: { status: 'subscribed', phone_hint: '…0100' },
      },
      orders: [{ session_id: 'cs_1', event_id: 'e', event_name: 'Show', amount_cents: 6000, status: 'fulfilled' }],
      signups: [{ form_id: 'x', form_name: 'Footer', sms_requested: true }],
    });
    expect(d.stats.money[0]).toEqual({ currency: 'usd', paidCents: 9000, refundedCents: 1000, orders: 2 });
    expect(d.consent).toMatchObject({ followsOrg: true, adConsent: 'denied', sms: { status: 'subscribed', phoneHint: '…0100' } });
    expect(d.consent.emailList.since?.toISOString()).toBe('2026-06-02T08:00:00.000Z');
    expect(d.orders[0]).toMatchObject({ sessionId: 'cs_1', amountCents: 6000 });
    expect(d.signups[0]).toMatchObject({ formName: 'Footer', smsRequested: true, confirmedAt: null });
    expect(parseFanDetail({}).consent).toMatchObject({ adConsent: null, sms: { status: 'none' }, emailList: { status: 'none' } });
  });

  it('names and labels', () => {
    expect(fanName({ firstName: 'Dana', lastName: null, email: 'd@x.com' })).toBe('Dana');
    expect(fanName({ firstName: null, lastName: null, email: 'd@x.com' })).toBe('d@x.com');
    expect(Object.keys(EMAIL_LIST_LABEL).sort()).toEqual(['none', 'pending', 'subscribed', 'unsubscribed']);
  });

  it('builds the export CSV with formula-looking text defused', () => {
    const rows = fansCsvRows([
      { email: 'dana@x.com', first_name: '=HYPERLINK("x")', last_name: 'Lee', has_account: true, source: 'order', orders_count: 2,
        email_list: 'subscribed', tags: ['VIP', 'Rock'], created_at: '2026-06-01T00:00:00Z' },
    ]);
    expect(rows[0]).toEqual(['dana@x.com', '=HYPERLINK("x")', 'Lee', 'yes', 'order', 2, '', '', 'subscribed', 'VIP; Rock', '2026-06-01T00:00:00Z']);
    const csv = toCsv(FANS_CSV_HEADER, rows);
    expect(csv.split('\r\n')[1]).toContain(`"'=HYPERLINK(""x"")"`);
    expect(fansCsvRows(null as unknown as unknown[])).toEqual([]);
  });
});

describe('tags and refund queue', () => {
  it('parses tags', () => {
    expect(parseOrgTag({ id: 't', name: 'VIP', scope: 'fan', items_count: 4 })).toEqual({
      id: 't', name: 'VIP', scope: 'fan', color: null, canonicalTagId: null, itemsCount: 4,
    });
    expect(parseOrgTag({ id: 't', scope: 'nope' }).scope).toBeNull();
  });
  it('parses queue rows and the fan\'s own asks', () => {
    const q = parseQueueAsk({ id: 'a', ticket_id: 't', event_name: 'Show', amount_cents: 3000, status: 'declined', checked_in: true });
    expect(q).toMatchObject({ askId: 'a', status: 'declined', checkedIn: true, amountCents: 3000 });
    expect(parseQueueAsk({ id: 'b' }).status).toBe('open');
    expect(parseMyAskRow({ ask_id: 'a', status: 'refunded', amount_cents: '2500' })).toMatchObject({ askId: 'a', status: 'refunded', amountCents: 2500 });
  });
});
