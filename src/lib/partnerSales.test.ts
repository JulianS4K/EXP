// Partner contract parsing (supabase/functions/_shared/partners/sales.ts):
// Opendate's nested JSON and Rails form bodies, attendee fields, order
// filters and paging. docs/partner-sales.md.

import { describe, expect, it } from 'vitest';
import {
  opendatePage, orderFilters, ParamError, parseOrderItems, presentedPartnerKey, railsFormBody, reservationAttrs,
  unwrapParams,
} from '../../supabase/functions/_shared/partners/sales.ts';

const T1 = '8c1d2e3f-4a5b-4c6d-8e7f-9a0b1c2d3e4f';
const T2 = '9d2e3f4a-5b6c-4d7e-8f9a-0b1c2d3e4f5a';

describe('bodies', () => {
  it('decodes Rails-style nested form fields', () => {
    const body = railsFormBody(
      `ticket_reservation[order_items_attributes][0][ticket_type_id]=${T1}&ticket_reservation[order_items_attributes][0][quantity]=2` +
      `&ticket_reservation[order_items_attributes][1][ticket_type_id]=${T2}&ticket_reservation[order_items_attributes][1][quantity]=1` +
      '&ticket_reservation[cash_paid]=54.00&ticket_reservation[stubhub_transaction_id]=SH-1',
    );
    const p = unwrapParams(body, 'ticket_reservation');
    expect(parseOrderItems(p.order_items_attributes)).toEqual([
      { ticket_type_id: T1, quantity: 2 }, { ticket_type_id: T2, quantity: 1 },
    ]);
    expect(reservationAttrs(p)).toEqual({ external_id: 'SH-1', cash_paid_cents: 5400 });
  });

  it('numbers [] lists itself', () => {
    const body = railsFormBody(`comp[order_items_attributes][][ticket_type_id]=${T1}&comp[order_items_attributes][][quantity]=1` +
      `&comp[order_items_attributes][][ticket_type_id]=${T2}&comp[order_items_attributes][][quantity]=3`);
    expect(parseOrderItems(unwrapParams(body, 'comp').order_items_attributes)).toEqual([
      { ticket_type_id: T1, quantity: 1 }, { ticket_type_id: T2, quantity: 3 },
    ]);
  });

  it('drops prototype keys and over-deep or odd keys', () => {
    const body = railsFormBody('__proto__[polluted]=1&a[constructor][prototype][x]=1&a[b][c][d][e][f][g]=1&ok=1&bad key=1');
    expect(({} as Record<string, unknown>).polluted).toBeUndefined();
    expect(body).toEqual({ ok: '1' });
  });

  it('takes flat JSON as well as wrapped', () => {
    const flat = { order_items_attributes: [{ ticket_type_id: T1, quantity: '4' }], email: 'A@B.co' };
    expect(parseOrderItems(unwrapParams(flat, 'ticket_reservation').order_items_attributes)).toEqual([{ ticket_type_id: T1, quantity: 4 }]);
    expect(reservationAttrs(flat)).toEqual({ email: 'a@b.co' });
  });
});

describe('order items', () => {
  it('refuses bad lines', () => {
    for (const bad of [undefined, [], [{ ticket_type_id: 'x', quantity: 1 }], [{ ticket_type_id: T1, quantity: 0 }],
      [{ ticket_type_id: T1, quantity: 101 }], [{ ticket_type_id: T1, quantity: 1.5 }],
      Array.from({ length: 11 }, () => ({ ticket_type_id: T1, quantity: 1 }))]) {
      expect(() => parseOrderItems(bad), JSON.stringify(bad)).toThrow(ParamError);
    }
  });
});

describe('attendee fields', () => {
  it('validates and normalizes', () => {
    expect(reservationAttrs({ first_name: ' Jane ', last_name: 'Buyer', email: ' Jane@Example.com ', should_send_ticket_email: 'true' }))
      .toEqual({ first_name: 'Jane', last_name: 'Buyer', email: 'jane@example.com', should_send_ticket_email: true });
    expect(reservationAttrs({ email: '', stubhub_transaction_id: '' })).toEqual({ email: null, external_id: null });
    expect(reservationAttrs({ comp_reason: 'Radio' })).toEqual({ comp_reason: 'Radio' });
    expect(() => reservationAttrs({ email: 'nope' })).toThrow(ParamError);
    expect(() => reservationAttrs({ first_name: 'x'.repeat(61) })).toThrow(ParamError);
    expect(() => reservationAttrs({ should_send_ticket_email: 'maybe' })).toThrow(ParamError);
    expect(() => reservationAttrs({ cash_paid: -1 })).toThrow(ParamError);
    expect(() => reservationAttrs({ stubhub_transaction_id: 'has space' })).toThrow(ParamError);
  });
});

describe('orders list', () => {
  const q = (s: string) => new URLSearchParams(s);

  it('reads Opendate filters', () => {
    expect(orderFilters(q(`q[calendar_event_id_eq]=${T1}&q[email_eq]=J@X.co&q[stubhub_transaction_id_eq]=SH-1&q[updated_at_gteq]=2026-10-30`)))
      .toEqual({ event_id: T1, email: 'j@x.co', external_id: 'SH-1', updated_gte: '2026-10-30T00:00:00.000Z' });
    expect(() => orderFilters(q('q[created_at_gteq]=yesterday'))).toThrow(ParamError);
    expect(() => orderFilters(q('q[calendar_event_id_eq]=42'))).toThrow(ParamError);
  });

  it('pages 25 by default, at most 250', () => {
    expect(opendatePage(q(''))).toEqual({ page: 1, perPage: 25 });
    expect(opendatePage(q('page=3&per_page=1000'))).toEqual({ page: 3, perPage: 250 });
    expect(() => opendatePage(q('page=0'))).toThrow(ParamError);
  });
});

describe('the partner key', () => {
  const headers = (h: Record<string, string>) => (name: string) => h[name] ?? null;
  it('comes from the query, X-Shared-Key or a bearer header', () => {
    expect(presentedPartnerKey(new URLSearchParams('shared_key=dk_live_a'), headers({}))).toBe('dk_live_a');
    expect(presentedPartnerKey(new URLSearchParams(), headers({ 'x-shared-key': ' dk_live_b ' }))).toBe('dk_live_b');
    expect(presentedPartnerKey(new URLSearchParams(), headers({ authorization: 'Bearer dk_live_c' }))).toBe('dk_live_c');
    expect(presentedPartnerKey(new URLSearchParams(), headers({}))).toBe('');
  });
});
