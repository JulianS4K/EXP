import { describe, expect, it, vi } from 'vitest';

vi.mock('./supabase', () => ({ supabase: {} }));
import { cleanConfig, configError, parseBackend, parseBackendStatus, parseIntegration, providerInfo, refFromLink } from './integrations';

describe('integrations', () => {
  const pretix = providerInfo('pretix')!;
  const twilio = providerInfo('twilio')!;
  const he = providerInfo('hievents')!;

  it('checks the settings like the database does', () => {
    expect(configError(pretix, { base_url: 'https://pretix.eu', organizer: 'club' }, 'tok', false)).toBeNull();
    expect(configError(pretix, { base_url: 'http://pretix.eu', organizer: 'club' }, 'tok', false)).toMatch(/https/);
    expect(configError(pretix, { base_url: 'https://pretix.eu', organizer: 'my club' }, 'tok', false)).toMatch(/letters/);
    expect(configError(pretix, { base_url: 'https://pretix.eu', organizer: 'club' }, '', false)).toMatch(/api token/);
    expect(configError(pretix, { base_url: 'https://pretix.eu', organizer: 'club' }, '', true)).toBeNull();
    expect(configError(twilio, { account_sid: 'AC123', from: '+12125550100' }, 't', false)).toMatch(/SID/);
    expect(configError(he, { base_url: 'https://tickets.example.com' }, '', false)).toBeNull();
    expect(configError(providerInfo('telnyx')!, { from: '2125550100' }, 'k', false)).toMatch(/international/);
  });

  it('keeps only the provider\'s fields, trimmed', () => {
    expect(cleanConfig(pretix, { base_url: ' https://x.com/ ', organizer: 'club', api_token: 'leak' })).toEqual({ base_url: 'https://x.com', organizer: 'club' });
  });

  it('reads ids from pasted links', () => {
    expect(refFromLink('pretix', 'https://pretix.eu/club/spring26/')).toBe('spring26');
    expect(refFromLink('pretix', 'spring26')).toBe('spring26');
    expect(refFromLink('pretix', 'https://pretix.eu/club')).toBeNull();
    expect(refFromLink('hievents', 'https://app.example.com/check-in/cil_AbC123')).toBe('cil_AbC123');
    expect(refFromLink('hievents', 'not a link')).toBeNull();
    expect(refFromLink('luma', 'https://luma.com/event/manage/evt-AbC123xyz/guests')).toBe('evt-AbC123xyz');
    expect(refFromLink('luma', 'evt-AbC123xyz')).toBe('evt-AbC123xyz');
    expect(refFromLink('luma', 'https://luma.com/my-party')).toBe('my-party');
    expect(refFromLink('luma', 'https://example.com/my-party')).toBeNull();
    expect(refFromLink('luma', 'https://luma.com/user/someone')).toBeNull();
  });

  it('luma: an API key, no other fields; a backend that syncs to the door', () => {
    const lu = providerInfo('luma')!;
    expect(lu.group).toBe('backend');
    expect(configError(lu, {}, '', false)).toMatch(/api key/i);
    expect(configError(lu, {}, 'k', false)).toBeNull();
    expect(parseBackend('luma')).toBe('luma');
    expect(parseBackendStatus({ ticket_backend: 'luma', link: { provider: 'luma' } }).link?.provider).toBe('luma');
  });

  it('parses rows', () => {
    const r = parseIntegration({ provider: 'pretix', config: { organizer: 'club' }, secret_hint: '…1234', has_secret: true, status: 'weird' });
    expect(r).toMatchObject({ provider: 'pretix', hasSecret: true, status: 'unverified', config: { organizer: 'club' } });
    expect(parseBackend('pretix')).toBe('pretix');
    expect(parseBackend('nope')).toBe('exos');
    const s = parseBackendStatus({ ticket_backend: 'hievents', can_manage: true, connected: ['hievents'],
      link: { provider: 'hievents', synced_count: '12', last_ok_at: '2026-10-16T09:00:00Z' } });
    expect(s).toMatchObject({ ticketBackend: 'hievents', canManage: true, connected: ['hievents'] });
    expect(s.link?.syncedCount).toBe(12);
  });
});
