import { describe, expect, it, vi } from 'vitest';

vi.mock('./supabase', () => ({ supabase: {} }));
import { cantAskText, parseEventAsk, parseMyAsk, policyLine } from './refundAsks';

describe('refund asks', () => {
  it('parses the buyer rows', () => {
    const r = parseMyAsk({
      ticket_id: 't1', can_ask: true, reason: null, amount_cents: '3000', currency: 'usd',
      ask_until: '2026-11-13T19:00:00Z', refund_policy: 'until_7d', ask_id: null, ask_status: null, decline_note: null,
    });
    expect(r).toMatchObject({ ticketId: 't1', canAsk: true, amountCents: 3000, refundPolicy: 'until_7d', askStatus: null });
    expect(r.askUntil?.toISOString()).toBe('2026-11-13T19:00:00.000Z');
    expect(parseMyAsk({ ticket_id: 't2', ask_status: 'weird', amount_cents: -5 })).toMatchObject({ askStatus: null, amountCents: 0, canAsk: false });
  });

  it('parses the organizer rows', () => {
    const a = parseEventAsk({ ask_id: 'a1', ticket_id: 't1', status: 'declined', checked_in: true, amount_cents: 2500, created_at: '2026-10-15T00:00:00Z' });
    expect(a).toMatchObject({ askId: 'a1', status: 'declined', checkedIn: true, amountCents: 2500 });
    expect(parseEventAsk({ ask_id: 'a2', ticket_id: 't2' }).status).toBe('open');
  });

  it('says why a buyer can\'t ask, or nothing', () => {
    expect(cantAskText('no-refunds')).toMatch(/final/);
    expect(cantAskText('too-late', new Date('2026-11-13T19:00:00Z'))).toMatch(/closed/);
    expect(cantAskText('checked-in')).toMatch(/scanned/);
    expect(cantAskText('marketplace')).toMatch(/marketplace/);
    expect(cantAskText('not-buyer')).toBeNull();
    expect(cantAskText('not-exos-paid')).toBeNull();
    expect(cantAskText(null)).toBeNull();
  });

  it('policy line', () => {
    expect(policyLine('none', null)).toBe('All sales final.');
    expect(policyLine(null, new Date('2026-11-13T19:00:00Z'))).toMatch(/until .* The organizer decides\./);
  });
});
