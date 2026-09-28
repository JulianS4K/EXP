import { describe, expect, it } from 'vitest';
import { EXOS_FEE_BPS, exosFeeCents, organizerNetCents } from '../../supabase/functions/_shared/platformFee.ts';
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

  it('leaves the organizer the same net on Exos and on every marketplace', () => {
    const exosCheckout = organizerNetCents(4000);
    for (const ch of ['seatgeek', 'evo', 'vivid'] as const) {
      const payout = payoutCents(ch, netEqualListCents(ch, 4000), 1);
      expect(organizerNetCents(payout), ch).toBe(exosCheckout); // 38.80
    }
  });
});
