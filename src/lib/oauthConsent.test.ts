import { describe, expect, it } from 'vitest';
import { approvedScope, isWriteScope, splitConsentScopes } from './oauthConsent';

describe('the OAuth consent scope list', () => {
  it('lists what the app could change apart from what it could see', () => {
    expect(splitConsentScopes(['events:read', 'events:write', 'orders:read', 'tickets:read', 'org:admin'])).toEqual({
      reads: ['events:read', 'orders:read', 'tickets:read'], writes: ['events:write', 'org:admin'],
    });
    expect(isWriteScope('refunds:write')).toBe(true);
    expect(isWriteScope('me:read')).toBe(false);
  });
  it('approves the reads and the writes left ticked, never more than was asked', () => {
    const asked = ['events:read', 'events:write', 'tickets:read'];
    expect(approvedScope(asked, new Set())).toBe('events:read events:write tickets:read');
    expect(approvedScope(asked, new Set(['events:write']))).toBe('events:read tickets:read');
    expect(approvedScope(asked, new Set(['finance:write']))).toBe('events:read events:write tickets:read');
    expect(approvedScope(['events:write'], new Set(['events:write']))).toBe('');
  });
});
