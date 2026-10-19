import { describe, expect, it, vi } from 'vitest';

vi.mock('./supabase', () => ({ supabase: {} }));

import { CHANNELS, externalIdFrom, mirrorLine, normalizeChoice, parseChannelStatus, parseConnections } from './channels';

describe('channels', () => {
  it('offers Eventbrite; Luma stays hidden while it is switched off', () => {
    expect(CHANNELS).toEqual(['eventbrite']);
    expect(parseConnections({ eventbrite: true, luma: true, writes: { eventbrite: true } })).toMatchObject({ eventbrite: true, luma: false });
  });

  it('the primary platform also sells the event', () => {
    expect(normalizeChoice({ primary: 'eventbrite', also: [] })).toEqual({ primary: 'eventbrite', also: ['eventbrite'] });
    expect(normalizeChoice({ primary: 'exos', also: ['eventbrite', 'eventbrite'] })).toEqual({ primary: 'exos', also: ['eventbrite'] });
    // Luma off: neither primary nor also.
    expect(normalizeChoice({ primary: 'luma', also: ['luma'] })).toEqual({ primary: 'exos', also: [] });
  });

  it('reads Eventbrite and Luma ids from links', () => {
    expect(externalIdFrom('eventbrite', 'https://www.eventbrite.com/e/mirror-night-tickets-123456789012')).toBe('123456789012');
    expect(externalIdFrom('eventbrite', 'https://www.eventbrite.co.uk/e/123456789?aff=x')).toBe('123456789');
    expect(externalIdFrom('eventbrite', '777000111')).toBe('777000111');
    expect(externalIdFrom('eventbrite', 'https://example.com/e/x')).toBeNull();
    expect(externalIdFrom('luma', 'https://luma.com/event/manage/evt-AbC123xyz')).toBe('evt-AbC123xyz');
  });

  it('parses the status and says where each mirror stands', () => {
    const s = parseChannelStatus({
      primary_source: 'eventbrite', can_manage: true, connected: { eventbrite: true, luma: true }, writes: { eventbrite: false },
      mirrors: [
        { provider: 'eventbrite', mode: 'create', status: 'dry_run', in_step: false, plan_steps: 5, external_url: 'javascript:alert(1)' },
        { provider: 'luma', status: 'synced' },
      ],
    });
    expect(s.primary).toBe('eventbrite');
    expect(s.connected.luma).toBe(false);
    expect(s.mirrors.map((m) => m.provider)).toEqual(['eventbrite']);   // Luma hidden while off
    expect(s.mirrors[0].externalUrl).toBeNull();
    expect(mirrorLine(s.mirrors[0], false)).toMatch(/writes to Eventbrite are off \(5 changes planned\)/);
    expect(mirrorLine({ ...s.mirrors[0], status: 'synced', inStep: true }, true)).toBe('In step with Exos.');
    expect(mirrorLine({ ...s.mirrors[0], status: 'error', lastError: 'Eventbrite: nope' }, true)).toBe('Eventbrite: nope');
  });
});
