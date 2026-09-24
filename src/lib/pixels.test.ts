import { describe, expect, it } from 'vitest';
import { isPixelRoute, pixelScopeAction } from './pixels';

describe('pixelScopeAction', () => {
  it('keeps the same org', () => {
    expect(pixelScopeAction('org-a', 'org-a', true)).toBe('keep');
  });
  it('reloads when another org takes over after pixels loaded', () => {
    expect(pixelScopeAction('org-a', 'org-b', true)).toBe('reload');
  });
  it('reloads when leaving to an untracked page after pixels loaded', () => {
    expect(pixelScopeAction('org-a', null, true)).toBe('reload');
  });
  it('switches without reload while nothing is loaded yet', () => {
    expect(pixelScopeAction('org-a', 'org-b', false)).toBe('switch');
    expect(pixelScopeAction(null, 'org-a', false)).toBe('switch');
  });
  it('does nothing on an untracked page when no org was in scope', () => {
    expect(pixelScopeAction(null, null, false)).toBe('keep');
  });
});

describe('isPixelRoute', () => {
  it.each(['/', '/event/abc', '/e/slug', '/o/brand', '/organizer/x', '/embed/event/1'])('tracks %s', (p) => {
    expect(isPixelRoute(p)).toBe(true);
  });
  it.each(['/checkin/1', '/ticket/1', '/wallet/pass/1', '/my-tickets', '/dashboard', '/orgs/1/settings', '/transfer/1', '/claim/1', '/profile'])(
    'never tracks %s',
    (p) => {
      expect(isPixelRoute(p)).toBe(false);
    },
  );
});
