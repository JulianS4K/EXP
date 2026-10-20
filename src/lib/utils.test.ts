import { describe, it, expect, vi } from 'vitest';
import { errMessage, formatCurrency, handleFirestoreError, isOrgHandleTaken, OperationType, publicUrl } from './utils';

describe('formatCurrency', () => {
  it('formats known currencies with the en-US symbol', () => {
    expect(formatCurrency(25, 'USD')).toBe('$25.00');
    expect(formatCurrency(0, 'usd')).toBe('$0.00');
    expect(formatCurrency(1234.5, 'EUR')).toBe('€1,234.50');
    expect(formatCurrency(10)).toBe('$10.00');
  });

  it('falls back to a plain suffix on an unknown code instead of throwing', () => {
    expect(formatCurrency(12.345, 'NOPE')).toBe('12.35 NOPE');
  });
});

describe('publicUrl', () => {
  it('normalizes the leading slash and never produces a double slash', () => {
    const a = publicUrl('event/123');
    const b = publicUrl('/event/123');
    expect(a).toBe(b);
    expect(a.endsWith('/event/123')).toBe(true);
    expect(a).not.toMatch(/(^|[^:])\/\//);
  });
});

describe('errMessage', () => {
  // Supabase / PostgREST errors are plain objects, not Error instances.
  const pg = (message: string, code?: string, details?: string) => ({ message, code, details, hint: null });

  it('reads the message off a plain Supabase error and drops the RPC prefix', () => {
    expect(errMessage(pg('exos_create_org: organization limit reached (3 a day). Try again tomorrow, or contact support.', 'P0001')))
      .toBe('Organization limit reached (3 a day). Try again tomorrow, or contact support.');
    expect(errMessage(new Error('Provide a valid email address.'))).toBe('Provide a valid email address.');
    expect(errMessage('plain text')).toBe('Plain text');
  });

  it('maps a taken org handle to plain words', () => {
    const e = pg('duplicate key value violates unique constraint "exos_orgs_slug_key"', '23505', 'Key (slug)=(night-owls) already exists.');
    expect(isOrgHandleTaken(e)).toBe(true);
    expect(errMessage(e)).toBe('That handle is taken. Try a different one.');
    // An event's vanity URL is not an org handle.
    const ev = pg('duplicate key value violates unique constraint "exos_events_slug_key"', '23505', 'Key (slug)=(x) already exists.');
    expect(isOrgHandleTaken(ev)).toBe(false);
    expect(errMessage(ev)).toBe('That is already in use. Try a different one.');
  });

  it('falls back when there is nothing readable', () => {
    expect(errMessage({}, 'Fallback.')).toBe('Fallback.');
    expect(errMessage(null, 'Fallback.')).toBe('Fallback.');
    expect(errMessage(pg('Edge Function returned a non-2xx status code'), 'Fallback.')).toBe('Fallback.');
    expect(errMessage(pg('new row violates row-level security policy', '42501'))).toBe("You don't have permission to do that.");
  });

  it('handleFirestoreError shows the server reason, not a generic line', () => {
    const toast = vi.fn();
    const spy = vi.spyOn(console, 'error').mockImplementation(() => {});
    handleFirestoreError(pg('Tier capacity is below tickets sold', 'P0001'), OperationType.WRITE, 'events', toast);
    expect(toast).toHaveBeenCalledWith(expect.objectContaining({ kind: 'error', message: 'Tier capacity is below tickets sold' }));
    handleFirestoreError(pg('permission denied for table exos_events', '42501'), OperationType.WRITE, 'events', toast);
    expect(toast).toHaveBeenLastCalledWith(expect.objectContaining({ message: "You don't have permission to do that. Try signing in again." }));
    spy.mockRestore();
  });
});
