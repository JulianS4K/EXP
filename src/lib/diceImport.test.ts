// The "Import from DICE" card's pure helpers (mig 20261106100000).
import { describe, expect, it, vi } from 'vitest';
vi.mock('./supabase', () => ({ supabase: {} }));
import { cleanDiceToken, parseDiceStatus, parseSyncResult, previewText, syncStatusText } from './diceImport';

const STATUS = {
  connected: true, status: 'connected', account_name: 'Night Owl', connected_at: '2026-11-01T18:20:00Z', syncing: false,
  last_sync_at: '2026-11-05T11:58:00Z', last_ok_at: '2026-11-05T11:58:30Z', last_error: null, full_sync_done_at: '2026-11-01T18:24:00Z',
  cursors: { events: { since: '2026-11-05T11:58:00Z', resuming: false }, orders: { since: null, resuming: true } },
  imported: { events: 6, events_past: 41, ticket_types: 12, tickets: 900, door_entries: 610, returns: 3, orders: 700, fans: 650, fans_marketing_consent: 210 },
  can_manage: true, secret_id: 'never-used', token: 'never-used',
  runs: [{ id: 'r1', kind: 'incremental', trigger: 'cron', dry_run: false, status: 'ok', started_at: '2026-11-05T11:58:00Z', counts: { events: { read: 2, updated: 2, junk: 'x' } } }, { nope: 1 }],
};

describe('the DICE card', () => {
  it('parses the status, keeping only what it shows', () => {
    const s = parseDiceStatus(STATUS)!;
    expect(s).toMatchObject({ connected: true, status: 'connected', accountName: 'Night Owl', canManage: true, resuming: ['orders'] });
    expect(s.imported).toMatchObject({ events: 6, eventsPast: 41, doorEntries: 610, fans: 650, fansMarketingConsent: 210 });
    expect(s.runs).toEqual([{ id: 'r1', kind: 'incremental', trigger: 'cron', dryRun: false, status: 'ok', startedAt: '2026-11-05T11:58:00Z',
      finishedAt: null, counts: { events: { read: 2, updated: 2 } }, error: null }]);
    expect(JSON.stringify(s)).not.toContain('never-used');
    expect(parseDiceStatus(null)).toBeNull();
    expect(parseDiceStatus({ status: 'connected' })).toBeNull();
  });
  it('says where the sync is', () => {
    const now = new Date('2026-11-05T12:00:00Z');
    const s = parseDiceStatus(STATUS)!;
    expect(syncStatusText(s, now)).toBe('Last synced 2 min ago. Imported: 6 events (drafts), 610 ticket holders on the door, 650 fans (210 with marketing consent). More to read: the next sync continues.');
    expect(syncStatusText({ ...s, syncing: true }, now)).toMatch(/Syncing/);
    expect(syncStatusText({ ...s, status: 'error', lastError: 'DICE didn\'t accept the token.' }, now)).toBe('DICE didn\'t accept the token.');
    expect(syncStatusText({ ...s, connected: false, status: 'disconnected' }, now)).toMatch(/imported stays/);
    expect(syncStatusText({ ...s, lastSyncAt: null }, now)).toMatch(/preview, then import/);
  });
  it('words the dry run, consent included', () => {
    const r = parseSyncResult({
      dry_run: true, kind: 'full', result: 'partial',
      preview: { events_upcoming: 3, events_past: 10, ticket_types: 7, tickets: 200, fans: 150, fans_marketing_consent: 40, orders: 120, returns: 2, transfers: 1 },
      entities: { events: { total: 13, counts: {} }, tickets: { total: 5230, counts: {} }, orders: { total: 3920 } },
    });
    expect(r.totals).toEqual({ events: 13, tickets: 5230, orders: 3920 });
    expect(previewText(r)).toBe('Read 3 upcoming events and 10 past events of 13, 200 tickets of 5,230 and 120 orders of 3,920 (a first look: the import reads everything). '
      + '150 fans, of whom 40 opted in to partner marketing on DICE and would join your email list; the rest come in as ticket holders without marketing consent.');
    expect(previewText(parseSyncResult({ error: 'DICE didn\'t accept the token.' }))).toBe('DICE didn\'t accept the token.');
  });
  it('cleans a pasted token', () => {
    expect(cleanDiceToken('  tok_dice_0123456789abcdef \n')).toBe('tok_dice_0123456789abcdef');
    expect(cleanDiceToken('Bearer tok_dice_0123456789abcdef')).toBe('tok_dice_0123456789abcdef');
    expect(cleanDiceToken('short')).toBeNull();
    expect(cleanDiceToken('two words 0123456789abcdef')).toBeNull();
  });
});
