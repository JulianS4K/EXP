import { describe, expect, it, vi } from 'vitest';

vi.mock('./supabase', () => ({ supabase: {} }));
import { consentText, finalBody, normalizePhone, parseOverview, segments } from './sms';

describe('sms', () => {
  it('consent text names the org, STOP and HELP (the SQL checks STOP)', () => {
    const t = consentText('SM Club');
    expect(t).toMatch(/SM Club/);
    expect(t).toMatch(/STOP/);
    expect(t).toMatch(/HELP/);
    expect(t.length).toBeLessThanOrEqual(600);
  });
  it('normalizes phones like the database', () => {
    expect(normalizePhone('(212) 555-0100')).toBe('+12125550100');
    expect(normalizePhone('1 212 555 0100')).toBe('+12125550100');
    expect(normalizePhone('+44 7700 900123')).toBe('+447700900123');
    expect(normalizePhone('555-0100')).toBeNull();
  });
  it('adds the sender and STOP, counts segments', () => {
    expect(finalBody('SM Club', ' Doors at 10 ')).toBe('SM Club: Doors at 10 Reply STOP to opt out.');
    expect(segments('a'.repeat(160))).toEqual({ count: 1, unicode: false });
    expect(segments('a'.repeat(161))).toEqual({ count: 2, unicode: false });
    expect(segments('🎉 '.repeat(30)).unicode).toBe(true);
  });
  it('parses the overview', () => {
    const o = parseOverview({ subscribers: '3', provider: 'twilio', campaigns: [{ id: 'c', audience: 'event_buyers', body: 'x', status: 'sent', send_after: '2026-10-16T13:00:00Z', created_at: '2026-10-16T12:00:00Z', queued: 2, dry_run: 2 }] });
    expect(o.subscribers).toBe(3);
    expect(o.campaigns[0]).toMatchObject({ audience: 'event_buyers', queued: 2, dryRun: 2 });
    const w = parseOverview({ campaigns: [{ id: 'w', audience: 'staff_report' }, { id: 'z', audience: 'weird' }] });
    expect(w.campaigns.map((c) => c.audience)).toEqual(['staff_report', 'org']);
  });
});
