// Reserved seating on wallet passes (mig 20261030140000): Apple gets
// SECTION / ROW / SEAT fields, Google gets seatInfo with all three.
import { describe, expect, it } from 'vitest';
import { buildApplePassJson } from '../../../supabase/functions/_shared/wallet/apple.ts';
import { buildEventTicketObject } from '../../../supabase/functions/_shared/wallet/google.ts';
import { payload } from './fixtures';

// deno-lint-ignore no-explicit-any
type Json = any;
const ID = { passTypeIdentifier: 'pass.com.exos.test', teamIdentifier: 'ABCDE12345', webServiceURL: 'https://x.test/apple' };
const seated = () => {
  const p = payload();
  return payload({
    ticket: { ...p.ticket, section_label: null, seat: { section: 'Orchestra', row: 'C', number: '12', label: 'Orchestra · Row C · Seat 12' } },
  });
};

describe('seated wallet passes', () => {
  it('Apple: section, row and seat fields', () => {
    const pass: Json = buildApplePassJson(seated(), ID, 'tok_'.padEnd(43, 'x'));
    const aux = Object.fromEntries((pass.eventTicket.auxiliaryFields as Json[]).map((f) => [f.key, f.value]));
    expect(aux['seat-section']).toBe('Orchestra');
    expect(aux['seat-row']).toBe('C');
    expect(aux['seat-number']).toBe('12');
  });

  it('Google: seatInfo with section, row and seat', () => {
    const o: Json = buildEventTicketObject(seated(), '3388000000012345678');
    expect(o.seatInfo.section.defaultValue.value).toBe('Orchestra');
    expect(o.seatInfo.row.defaultValue.value).toBe('C');
    expect(o.seatInfo.seat.defaultValue.value).toBe('12');
  });

  it('general admission passes are unchanged', () => {
    const pass: Json = buildApplePassJson(payload(), ID, 'tok_'.padEnd(43, 'x'));
    expect((pass.eventTicket.auxiliaryFields as Json[]).some((f) => String(f.key).startsWith('seat-'))).toBe(false);
    expect((buildEventTicketObject(payload(), '3388000000012345678') as Json).seatInfo).toEqual({
      section: expect.anything(),
    });
  });
});
