import { describe, expect, it } from 'vitest';
import { FOLLOWER_COUNT_MIN, followerLabel } from './socialProof';
import { eventImageOr, FALLBACK_EVENT_IMAGE } from './fallbackImage';

describe('followerLabel', () => {
  it('hides counts below the threshold', () => {
    expect(FOLLOWER_COUNT_MIN).toBe(10);
    for (const n of [0, 1, 9, null, undefined, NaN, -5]) expect(followerLabel(n as number)).toBeNull();
  });
  it('shows counts from the threshold up', () => {
    expect(followerLabel(10, 'en-US')).toBe('10 followers');
    expect(followerLabel(1234, 'en-US')).toBe('1,234 followers');
  });
});

describe('fallback event image', () => {
  it('is a local data: SVG, never a third-party host', () => {
    expect(FALLBACK_EVENT_IMAGE.startsWith('data:image/svg+xml,')).toBe(true);
    expect(decodeURIComponent(FALLBACK_EVENT_IMAGE)).not.toMatch(/https?:\/\/(?!www\.w3\.org)/);
  });
  it('keeps the event image when there is one', () => {
    expect(eventImageOr('https://cdn.example/x.jpg')).toBe('https://cdn.example/x.jpg');
    expect(eventImageOr('')).toBe(FALLBACK_EVENT_IMAGE);
    expect(eventImageOr(null)).toBe(FALLBACK_EVENT_IMAGE);
  });
});
