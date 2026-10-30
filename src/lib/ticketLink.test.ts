import { describe, expect, it } from 'vitest';
import { linkKeyFromHash, nextRefreshMs, stateMessage } from './ticketLink';

const K = 'Zm9yX2RvY3NfZXhhbXBsZV9vbmx5X25vdF9hX3JlYWxfa2V5';

describe('ticket links', () => {
  it('reads the key from the fragment only', () => {
    expect(K).toHaveLength(48);
    const k43 = K.slice(0, 43);
    expect(linkKeyFromHash(`#k=${k43}`)).toBe(k43);
    expect(linkKeyFromHash(`#wallet=apple&k=${k43}`)).toBe(k43);
    expect(linkKeyFromHash(`#k=${K}`)).toBeNull();
    expect(linkKeyFromHash('#k=short')).toBeNull();
    expect(linkKeyFromHash('')).toBeNull();
  });

  it('refreshes just after the code rotates', () => {
    expect(nextRefreshMs({ refresh_in_ms: 12_000 })).toBe(12_250);
    expect(nextRefreshMs({ refresh_in_ms: 0 })).toBe(2_000);
    expect(nextRefreshMs({ refresh_in_ms: 99_999 })).toBe(30_000);
    expect(nextRefreshMs({})).toBe(30_000);
  });

  it('explains states without a code', () => {
    expect(stateMessage('valid')).toBeNull();
    expect(stateMessage('checked_in')).toMatch(/Checked in/);
    expect(stateMessage('nonsense')).toMatch(/can't be shown/);
  });
});
