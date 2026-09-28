import { afterEach, describe, it, expect } from 'vitest';
import {
  describeSkew,
  estimateOffset,
  getClockOffset,
  resetClockOffset,
  secondsLeftInWindow,
  serverNow,
  setClockOffset,
  skewMinutes,
} from './serverClock';
import { currentBucket } from './barcode';

const NOW = Date.UTC(2026, 8, 28, 22, 0, 0); // on a 30s boundary

afterEach(() => resetClockOffset());

describe('estimateOffset', () => {
  it('uses the midpoint of the round trip', () => {
    // Device clock 5 minutes slow: sent at t, server says t + 5min + 100ms, back at t + 200ms.
    expect(estimateOffset(NOW, NOW + 300_000 + 100, NOW + 200)).toBe(300_000);
  });
  it('rejects slow or nonsense round trips', () => {
    expect(estimateOffset(NOW, NOW, NOW + 20_000)).toBeNull();
    expect(estimateOffset(NOW, NOW, NOW - 1)).toBeNull();
    expect(estimateOffset(NOW, Number.NaN, NOW + 10)).toBeNull();
  });
});

describe('serverNow', () => {
  it('ignores noise and applies real offsets', () => {
    setClockOffset(800);
    expect(getClockOffset()).toBe(0);
    setClockOffset(-240_000);
    expect(serverNow(NOW)).toBe(NOW - 240_000);
    setClockOffset(null);
    expect(getClockOffset()).toBe(-240_000);
  });

  it('a slow phone signs for the server window', () => {
    // Phone 4 minutes slow: without the offset its bucket is 8 windows behind.
    const phone = NOW - 240_000;
    expect(currentBucket(NOW) - currentBucket(phone)).toBe(8);
    setClockOffset(estimateOffset(phone, NOW + 50, phone + 100));
    expect(currentBucket(serverNow(phone))).toBe(currentBucket(NOW));
  });

  it('counts the window down on the server clock', () => {
    expect(secondsLeftInWindow(NOW)).toBe(30);
    expect(secondsLeftInWindow(NOW + 29_500)).toBe(1);
    setClockOffset(10_000);
    expect(secondsLeftInWindow(NOW)).toBe(20);
  });
});

describe('describeSkew', () => {
  it('says fast for a code from the future and old for one from the past', () => {
    const b = currentBucket(NOW);
    expect(skewMinutes(b + 10, NOW)).toBe(5);
    expect(describeSkew(b + 10, NOW)).toMatch(/about 5 min fast/);
    expect(describeSkew(b - 20, NOW)).toMatch(/about 10 min old/);
    expect(skewMinutes(b - 3, NOW)).toBe(2);
    expect(skewMinutes(b, NOW)).toBe(1);
  });
});
