import { describe, it, expect } from 'vitest';
import { effectiveTierPrice as clientPrice } from './pricing';
import { effectiveTierPrice as serverPrice } from '../../supabase/functions/_shared/pricing.ts';

// The storefront shows clientPrice; exos-checkout charges serverPrice. They must
// agree for every schedule, or buyers are charged a price they weren't shown.

function rng(seed: number) {
  let x = seed >>> 0;
  return () => {
    x = (x * 1664525 + 1013904223) >>> 0;
    return x / 2 ** 32;
  };
}

const NOW = new Date('2026-09-24T12:00:00Z');

function randomSchedule(r: () => number): unknown {
  const pick = r();
  if (pick < 0.05) return null;
  if (pick < 0.1) return 'not-an-array';
  const n = Math.floor(r() * 6);
  return Array.from({ length: n }, () => {
    const kind = r();
    const offsetH = Math.floor((r() - 0.5) * 240);
    const startsAt = new Date(NOW.getTime() + offsetH * 3600_000).toISOString();
    if (kind < 0.08) return { startsAt: 'garbage', price: 10 };
    if (kind < 0.14) return { startsAt, price: -5 };
    if (kind < 0.2) return { startsAt, price: '12' };
    if (kind < 0.24) return null;
    return { startsAt, price: Math.round(r() * 20000) / 100 };
  });
}

describe('checkout price parity (client vs exos-checkout)', () => {
  it('agrees on 2,000 generated schedules, including malformed ones', () => {
    const r = rng(20260924);
    for (let i = 0; i < 2000; i++) {
      const base = Math.round(r() * 10000) / 100;
      const schedule = randomSchedule(r);
      expect(serverPrice(base, schedule, NOW), JSON.stringify({ base, schedule })).toBe(
        clientPrice(base, schedule, NOW),
      );
    }
  });

  it('treats a step starting exactly now as active on both sides', () => {
    const schedule = [{ startsAt: NOW.toISOString(), price: 42 }];
    expect(serverPrice(30, schedule, NOW)).toBe(42);
    expect(clientPrice(30, schedule, NOW)).toBe(42);
  });
});
