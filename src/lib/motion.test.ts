import { describe, expect, it } from 'vitest';
import { motionGate } from './motion';

describe('motionGate', () => {
  it('keeps the entrance and exit when reduced motion is off', () => {
    for (const pref of [false, null, undefined]) {
      const g = motionGate(pref);
      expect(g.reduce).toBe(false);
      expect(g.enter({ opacity: 0, x: 20 })).toEqual({ opacity: 0, x: 20 });
      expect(g.leave({ opacity: 0, x: -20 })).toEqual({ opacity: 0, x: -20 });
    }
  });

  it('drops the entrance (full opacity at once) and the exit when it is on', () => {
    const g = motionGate(true);
    expect(g.reduce).toBe(true);
    expect(g.enter({ opacity: 0 })).toBe(false);
    expect(g.enter({ scale: 0.9, opacity: 0 })).toBe(false);
    expect(g.leave({ opacity: 0 })).toBeUndefined();
  });
});
