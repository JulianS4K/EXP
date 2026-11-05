// The operator decisions on the mistake simulations (mig 20261105100000): the
// pure TS halves. The SQL halves are the SIM-… scenarios in tests/exos/sim_*.sql.
import { describe, expect, it } from 'vitest';
import {
  CAPACITY_REQUIRED, capacityLeft, isClosedCapacity, isSellableCapacity, isSoldOut,
} from '../../../supabase/functions/_shared/capacity.ts';
import { NAME_IS_EMAIL, assertNotEmailName, nameError, nameLooksLikeEmail } from '../../../supabase/functions/_shared/nameGuard.ts';
import { looseDoorCode, normalizeDoorCode, planImport, detectColumns } from '../../../supabase/functions/_shared/guestImport.ts';
import { newProofToken, normalizeProofCode, proofErrorMessage, proofTokenHash } from '../../../supabase/functions/_shared/orderProof.ts';
import { EditError, orderEditFields, ticketEditFields } from '../../../supabase/functions/_shared/orderEdits.ts';
import { RsvpInputError, parseRsvpRequest } from '../../../supabase/functions/_shared/rsvp.ts';
import { exosLeft } from '../../../supabase/functions/_shared/catalog/feed.ts';
import { parseProofState } from '../../../supabase/functions/_shared/orderProof.ts';
import { buyableTiers, maxQuantity } from '../embed';

describe('SIM-ORG-3 no unlimited capacity', () => {
  it('capacity 0 is closed: nothing left, sold out', () => {
    expect(capacityLeft(0, 0)).toBe(0);
    expect(isClosedCapacity(0)).toBe(true);
    expect(isSoldOut(0, 0)).toBe(true);
    expect(capacityLeft(null, 0)).toBe(0);
    expect(capacityLeft(undefined, 0)).toBe(0);
  });
  it('a positive capacity sells down to 0, never below', () => {
    expect(capacityLeft(10, 3)).toBe(7);
    expect(capacityLeft(10, 12)).toBe(0);
    expect(capacityLeft('25', '5')).toBe(20);
    expect(isSoldOut(10, 10)).toBe(true);
    expect(isSoldOut(10, 9)).toBe(false);
  });
  it('a sellable ticket type needs a whole capacity of 1 or more', () => {
    for (const ok of [1, 100, '40', 1_000_000]) expect(isSellableCapacity(ok)).toBe(true);
    for (const bad of [0, -1, 1.5, '', ' ', 'ten', null, undefined, NaN, Infinity, 1_000_001]) expect(isSellableCapacity(bad)).toBe(false);
    expect(CAPACITY_REQUIRED).toContain('0 closes sales');
  });
  it('the feeds and the embed agree: a closed type is out of stock', () => {
    expect(exosLeft({ capacity: 0, sold: 0 })).toBe(0);
    expect(exosLeft({ capacity: 0, sold: 0, available: null })).toBe(0);
    expect(buyableTiers([{ id: 'c', price: 1, capacity: 0, sold: 0 }])).toEqual([]);
    expect(maxQuantity({ id: 'c', price: 1, capacity: 0, sold: 0 })).toBe(0);
  });
});

describe('SIM-ORG-14 names that are emails', () => {
  it('spots an email anywhere in a name', () => {
    for (const n of ['ana@example.com', ' Ana <ana@example.co.uk>', 'ANA.LEE+vip@Mail.Example.org']) expect(nameLooksLikeEmail(n)).toBe(true);
    for (const n of ['Ana Lee', 'Ana @ the bar', 'O\'Brien', 'a@b', '', null, 42]) expect(nameLooksLikeEmail(n)).toBe(false);
    expect(nameError('x@y.io')).toBe(NAME_IS_EMAIL);
    expect(nameError('Ana')).toBeNull();
    expect(() => assertNotEmailName('x@y.io')).toThrow(NAME_IS_EMAIL);
    expect(() => assertNotEmailName(null)).not.toThrow();
    expect(NAME_IS_EMAIL).toBe('name looks like an email; are your columns swapped?');
  });
  it('a guest import with swapped columns skips (and counts) those rows', () => {
    const t = [['Email', 'Name'], ['ana@x.com', 'Ana'], ['Bo', 'bo@x.com']];
    // The header says "Email" then "Name", but the second row is swapped.
    const p = planImport(t, detectColumns(t[0]), 'Other');
    expect(p.rows.map((r) => r.name)).toEqual(['Ana']);
    expect(p.nameIsEmail).toBe(1);
  });
  it('order and ticket edits refuse them before the round trip', () => {
    expect(() => orderEditFields({ first_name: 'ana@x.com' })).toThrow(EditError);
    expect(() => ticketEditFields({ attendee_name: 'Ana <ana@x.com>' })).toThrow(/columns swapped/);
    expect(ticketEditFields({ attendee_name: 'Ana Lee' })).toEqual({ attendee_name: 'Ana Lee' });
  });
  it('phone RSVP refuses them', () => {
    expect(() => parseRsvpRequest({ action: 'start', event_id: '00000000-0000-0000-0000-000000000001', name: 'ana@x.com', phone: '2125550100' }))
      .toThrow(RsvpInputError);
  });
});

describe('SIM-DOOR-9 imported codes without their punctuation', () => {
  it('looseDoorCode drops everything but letters and digits, upper case', () => {
    expect(looseDoorCode('EB-1234 5678')).toBe('EB12345678');
    expect(looseDoorCode('gst.abc/9')).toBe('GSTABC9');
    expect(looseDoorCode(' - ')).toBeNull();
    expect(looseDoorCode(null)).toBeNull();
    // The exact code keeps its punctuation (only whitespace goes).
    expect(normalizeDoorCode('eb-1234 5678')).toBe('EB-12345678');
  });
});

describe('SIM-BUYER-12/13 proof of email', () => {
  it('a 256-bit base64url token, hashed as the SQL checks it', async () => {
    const t = newProofToken();
    expect(t).toMatch(/^[A-Za-z0-9_-]{43}$/);
    expect(newProofToken()).not.toBe(t);
    // encode(digest(btrim(token), 'sha256'), 'hex') in _exos_proof_for
    expect(await proofTokenHash('abc')).toBe('ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad');
    expect(await proofTokenHash(' abc ')).toBe(await proofTokenHash('abc'));
  });
  it('codes: 6 digits, spaces and dashes ignored', () => {
    expect(normalizeProofCode(' 123 456 ')).toBe('123456');
    expect(normalizeProofCode('123-456')).toBe('123456');
    expect(normalizeProofCode('12345')).toBeNull();
    expect(normalizeProofCode('12a456')).toBeNull();
  });
  it('every answer has words', () => {
    for (const e of ['wrong_code', 'bad_code', 'locked', 'rate_limited', 'bad_phone', 'expired', 'cancelled', 'unknown', 'proven']) {
      expect(proofErrorMessage(e)).not.toBe(proofErrorMessage('???'));
    }
    expect(proofErrorMessage('wrong_code', { attempts_left: 1 })).toContain('1 try left');
  });
  it('the status keeps only claim links', () => {
    const s = parseProofState({
      status: 'proven', email: 'ab…@x.com', attempts_left: 5, attached: false,
      tickets: [{ ticket_id: 't1', path: '/claim/abc?k=1' }, { ticket_id: 't2', path: 'https://evil.example/' }],
    });
    expect(s.status).toBe('proven');
    expect(s.tickets).toEqual([{ ticket_id: 't1', path: '/claim/abc?k=1' }]);
    expect(parseProofState({ status: 'weird' }).status).toBe('unknown');
  });
});
