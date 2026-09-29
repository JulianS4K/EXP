import { describe, expect, it } from 'vitest';
import {
  EXOS_FEE_BPS,
  STRIPE_CARD_FEE,
  checkoutApplicationFeeCents,
  checkoutFeeSplit,
  exosFeeBpsAt,
  isFeeFreeAt,
  exosFeeCents,
  FEE_FREE_MONTHS,
  organizerNetCents,
  stripeFeeCents,
} from '../../supabase/functions/_shared/platformFee.ts';
import { netEqualListCents, payoutCents } from './marketplace';

describe('the Exos fee: 3% of every transaction, paid by the organizer', () => {
  it('is 3%, to the cent, half up', () => {
    expect(EXOS_FEE_BPS).toBe(300);
    expect(exosFeeCents(4000)).toBe(120);
    expect(exosFeeCents(2150)).toBe(65); // 64.5 rounds up
    expect(exosFeeCents(8001)).toBe(240); // 240.03
    expect(exosFeeCents(0)).toBe(0);
    expect(organizerNetCents(4000)).toBe(3880);
  });

  it('on an Exos checkout, carries Stripe\'s card fee so Exos nets 3%', () => {
    expect(STRIPE_CARD_FEE).toEqual({ bps: 290, fixedCents: 30 });
    expect(stripeFeeCents(4000)).toBe(146); // 1.16 + 0.30
    expect(checkoutApplicationFeeCents(4000)).toBe(266); // organizer gets 37.34
    for (const amount of [500, 2000, 4000, 12345, 100000]) {
      const appFee = checkoutApplicationFeeCents(amount);
      expect(appFee - stripeFeeCents(amount), `${amount}`).toBe(exosFeeCents(amount)); // Exos keeps exactly 3%
    }
    expect(checkoutApplicationFeeCents(0)).toBe(0); // free orders: no fee, no charge
    expect(checkoutApplicationFeeCents(20)).toBe(20); // never more than the order
    expect(checkoutApplicationFeeCents(4000, { card: { bps: 0, fixedCents: 0 } })).toBe(120);
  });

  it('is free for the first 6 months (card processing still applies at checkout)', () => {
    expect(FEE_FREE_MONTHS).toBe(6);
    const now = new Date('2026-12-01T00:00:00Z');
    expect(exosFeeBpsAt('2027-04-01T00:00:00Z', now)).toBe(0);
    expect(exosFeeBpsAt('2026-11-30T00:00:00Z', now)).toBe(300);
    expect(exosFeeBpsAt(null, now)).toBe(300);
    expect(exosFeeBpsAt('not a date', now)).toBe(300);
    // Free months: the application fee is just Stripe's card fee, so Exos nets 0 and loses nothing.
    expect(checkoutApplicationFeeCents(4000, { bps: exosFeeBpsAt('2027-04-01T00:00:00Z', now) })).toBe(146);
  });

  it('on a marketplace sale, 3% of the payout is already net (the marketplace charged the card)', () => {
    for (const ch of ['seatgeek', 'evo', 'vivid'] as const) {
      const payout = payoutCents(ch, netEqualListCents(ch, 4000), 1);
      expect(organizerNetCents(payout), ch).toBe(3880);
    }
  });
});

describe('checkoutFeeSplit: the application fee, broken down for the order record', () => {
  it('splits a 40.00 order into 1.20 Exos + 1.46 card fee = 2.66', () => {
    expect(checkoutFeeSplit(4000)).toEqual({ applicationFeeCents: 266, exosFeeCents: 120, cardFeeEstCents: 146, feeBps: 300 });
  });

  it('is card fee only in the fee-free window', () => {
    expect(checkoutFeeSplit(4000, { bps: 0 })).toEqual({ applicationFeeCents: 146, exosFeeCents: 0, cardFeeEstCents: 146, feeBps: 0 });
  });

  it('always matches what Stripe is told, and the parts add up', () => {
    const cards = [STRIPE_CARD_FEE, { bps: 340, fixedCents: 30 }, { bps: 0, fixedCents: 0 }];
    for (const amount of [0, 1, 25, 30, 31, 99, 100, 1005, 4000, 10094, 123457, 999999]) {
      for (const bps of [0, 150, 300, 1000]) {
        for (const card of cards) {
          const s = checkoutFeeSplit(amount, { bps, card });
          expect(s.applicationFeeCents).toBe(checkoutApplicationFeeCents(amount, { bps, card }));
          expect(s.exosFeeCents + s.cardFeeEstCents).toBe(s.applicationFeeCents);
          expect(s.exosFeeCents).toBeGreaterThanOrEqual(0);
          expect(s.applicationFeeCents).toBeLessThanOrEqual(Math.max(amount, 0));
        }
      }
    }
  });

  it('covers the card fee first when the order cap bites', () => {
    // 0.31: 3% = 1c, card = 1c + 30c = 31c -> capped at 31, all of it card fee.
    expect(checkoutFeeSplit(31)).toEqual({ applicationFeeCents: 31, exosFeeCents: 0, cardFeeEstCents: 31, feeBps: 300 });
    expect(checkoutFeeSplit(20)).toEqual({ applicationFeeCents: 20, exosFeeCents: 0, cardFeeEstCents: 20, feeBps: 300 });
  });

  it('knows the fee-free window', () => {
    const now = new Date('2026-09-29T12:00:00Z');
    expect(isFeeFreeAt('2027-03-29T00:00:00Z', now)).toBe(true);
    expect(isFeeFreeAt('2026-09-01T00:00:00Z', now)).toBe(false);
    expect(isFeeFreeAt(null, now)).toBe(false);
    expect(isFeeFreeAt('not a date', now)).toBe(false);
  });
});
