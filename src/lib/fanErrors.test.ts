import { describe, expect, it } from 'vitest';
import { fanError, fanMessage, stripExosPrefix } from './fanErrors';

describe('fan error messages', () => {
  it('strips exos_* prefixes', () => {
    expect(stripExosPrefix('exos_create_hold: event not on sale')).toBe('event not on sale');
    expect(stripExosPrefix('exos: exceeds max per order (5 requested, limit 4)')).toBe('exceeds max per order (5 requested, limit 4)');
    expect(stripExosPrefix('exos-checkout: exos_claim_free_tickets: x')).toBe('x');
    expect(stripExosPrefix('plain words')).toBe('plain words');
  });

  it('maps the common reasons to fan copy', () => {
    expect(fanMessage('exos_claim_free_tickets: tier sold out', 'f')).toMatch(/^Sold out/);
    expect(fanMessage('exos_create_hold: not enough tickets available', 'f')).toMatch(/Not enough tickets left/);
    expect(fanMessage('exos_create_guest_hold: sales have ended for this tier', 'f')).toBe('Sales for this ticket type have ended.');
    expect(fanMessage('exos_claim_free_tickets: sales have ended', 'f')).toBe('Sales for this ticket type have ended.');
    expect(fanMessage('exos_create_hold: sales have not started for this tier', 'f')).toMatch(/haven't opened yet/);
    expect(fanMessage('exos: exceeds max per account (hold 4, +2 would exceed limit 4)', 'f'))
      .toBe('You can have up to 4 tickets for this event and you already have 4.');
    expect(fanMessage('exos: exceeds max per account (hold 0, +6 would exceed limit 4)', 'f'))
      .toBe('You can have up to 4 tickets for this event.');
    expect(fanMessage('exos: exceeds max per order (5 requested, limit 4)', 'f')).toBe('You can get up to 4 tickets per order.');
    expect(fanMessage('exos_claim_free_tickets: tier not available', 'f')).toMatch(/If you have a code, apply it first/);
    expect(fanMessage('voucher already used', 'f')).toBe('That code has already been used.');
    expect(fanMessage("exos_claim_free_tickets: that code doesn't cover 3 tickets", 'f')).toMatch(/doesn't cover that many/);
    expect(fanMessage('exos_claim_free_tickets: confirm your email before claiming tickets', 'f')).toMatch(/Confirm your email/);
  });

  it('never shows transport errors; keeps unknown reasons, prefix-free', () => {
    expect(fanMessage('Edge Function returned a non-2xx status code', 'Could not start checkout.')).toBe('Could not start checkout.');
    expect(fanMessage('', 'fallback')).toBe('fallback');
    expect(fanMessage(null, 'fallback')).toBe('fallback');
    expect(fanMessage('exos_create_guest_hold: too many checkouts from this network, try again in a few minutes', 'f'))
      .toBe('Too many checkouts from this network, try again in a few minutes');
    expect(fanMessage('add-on "Poster" is sold out', 'f')).toBe('Add-on "Poster" is sold out');
  });

  it('reads thrown errors of any shape', () => {
    expect(fanError(new Error('exos_create_hold: event not on sale'), 'f')).toBe('This event isn\'t on sale right now.');
    expect(fanError({ message: 'exos_claim_free_tickets: tier sold out', code: '23514' }, 'f')).toMatch(/^Sold out/);
    expect(fanError(undefined, 'f')).toBe('f');
  });
});
