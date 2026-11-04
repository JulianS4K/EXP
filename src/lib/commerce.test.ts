import { describe, expect, it, vi } from 'vitest';

vi.mock('./supabase', () => ({ supabase: {} }));

import {
  GIFT_CARD_ALPHABET, campaignProgress, giftCardOrderFee, coverFeesCents, donationsCsv, formatGiftCardCode, giftCardApplied,
  giftCardCheckOk, majorToCents, makeGiftCardCode, memberPriceApplies, memberUnitCents, membershipStatusFromStripe,
  normalizeGiftCardCode, parseDonationCents, passCovers, passCreditsLeft, roundUpDonationCents,
} from './commerce';

describe('gift card codes', () => {
  it('shares its fixed vectors with tests/exos/test_gift_cards_giving.sql', () => {
    expect(giftCardCheckOk('ABCD-EFGH-JKLM-NPQ9')).toBe(true);
    expect(giftCardCheckOk('2222-2222-2222-222S')).toBe(true);
    expect(giftCardCheckOk('ABCD-EFGH-JKLM-NPQ8')).toBe(false);
  });

  it('generated codes pass and every single-character typo fails', () => {
    for (let n = 0; n < 300; n++) {
      const bytes = new Uint8Array(15);
      for (let i = 0; i < 15; i++) bytes[i] = Math.floor(Math.random() * 256);
      const c = makeGiftCardCode(bytes);
      expect(c).toMatch(/^[ABCDEFGHJKLMNPQRSTUVWXYZ23456789]{16}$/);
      expect(giftCardCheckOk(c)).toBe(true);
      if (n < 10) {
        for (let j = 0; j < 16; j++) {
          const k = (GIFT_CARD_ALPHABET.indexOf(c[j]) + 1 + (n % 31)) % 32;
          const bad = c.slice(0, j) + GIFT_CARD_ALPHABET[k] + c.slice(j + 1);
          expect(giftCardCheckOk(bad)).toBe(false);
        }
      }
    }
  });

  it('normalizes and formats', () => {
    expect(normalizeGiftCardCode(' abcd-efgh jklm-npq9 ')).toBe('ABCDEFGHJKLMNPQ9');
    expect(normalizeGiftCardCode('ABCD-EFGH-JKLM-NPQ0')).toBeNull(); // 0 isn't in the alphabet
    expect(normalizeGiftCardCode(42)).toBeNull();
    expect(formatGiftCardCode('abcdefghjklmnpq9')).toBe('ABCD-EFGH-JKLM-NPQ9');
    expect(() => makeGiftCardCode(new Uint8Array(3))).toThrow();
  });
});

describe('giftCardApplied', () => {
  it('pays all when the balance covers it', () => {
    expect(giftCardApplied(8000, 10000)).toBe(8000);
    expect(giftCardApplied(8000, 8000)).toBe(8000);
  });
  it('leaves a chargeable rest (at least 0.50)', () => {
    expect(giftCardApplied(8000, 5000)).toBe(5000);
    expect(giftCardApplied(8000, 7990)).toBe(7950);
    expect(giftCardApplied(8000, 7950)).toBe(7950);
    expect(giftCardApplied(40, 30)).toBe(0);
  });
  it('nothing to apply', () => {
    expect(giftCardApplied(0, 5000)).toBe(0);
    expect(giftCardApplied(5000, 0)).toBe(0);
    expect(giftCardApplied(5000, -1)).toBe(0);
  });
  it('the card charge is always 0 or a valid Stripe amount', () => {
    for (let t = 1; t < 3000; t += 7) {
      for (const b of [0, 1, 49, 50, 51, 999, 2999, 5000]) {
        const a = giftCardApplied(t, b);
        const rest = t - a;
        expect(a).toBeGreaterThanOrEqual(0);
        expect(a).toBeLessThanOrEqual(Math.min(t, Math.max(b, 0)));
        if (a > 0) expect(rest === 0 || rest >= 50).toBe(true);
      }
    }
  });
});

describe('giftCardOrderFee (platform fee on the gift card part)', () => {
  const card = { bps: 290, fixedCents: 30 };
  it('without a gift card it is the usual checkout fee', async () => {
    const { checkoutFeeSplit } = await import('../../supabase/functions/_shared/platformFee.ts');
    const f = giftCardOrderFee(4000, 0, false, { bps: 300, card });
    expect(f.applicationFeeCents).toBe(checkoutFeeSplit(4000, { bps: 300, card }).applicationFeeCents);
    expect(f.owedCents).toBe(0);
  });
  it('an online Stripe card already paid the Exos fee: only the card charge pays', () => {
    const f = giftCardOrderFee(3000, 5000, true, { bps: 300, card });
    expect(f.giftExosFeeCents).toBe(0);
    expect(f.applicationFeeCents).toBe(90 + 117); // 3% + 2.9% + 30c of 30.00
    expect(f.owedCents).toBe(0);
  });
  it('a box-office / comp card owes the Exos fee on its part, on the combined amount', () => {
    const f = giftCardOrderFee(3000, 5000, false, { bps: 300, card });
    expect(f.giftExosFeeCents).toBe(240 - 90); // 3% of 80.00 minus 3% of 30.00
    expect(f.applicationFeeCents).toBe(90 + 117 + 150);
    expect(f.exosFeeCents).toBe(240);
    expect(f.owedCents).toBe(0);
  });
  it('more than the charge can carry is recorded as owed; a full gift order owes it all', () => {
    const small = giftCardOrderFee(100, 50000, false, { bps: 300, card });
    expect(small.applicationFeeCents).toBeLessThanOrEqual(100);
    expect(small.owedCents).toBeGreaterThan(0);
    const full = giftCardOrderFee(0, 8000, false, { bps: 300, card });
    expect(full.applicationFeeCents).toBe(0);
    expect(full.owedCents).toBe(240);
    expect(giftCardOrderFee(0, 8000, true, { bps: 300, card }).owedCents).toBe(0);
  });
  it('the fee-free window (bps 0) owes nothing', () => {
    expect(giftCardOrderFee(0, 8000, false, { bps: 0, card }).owedCents).toBe(0);
  });
  it('nothing is lost: collected + owed = the charge\'s own Exos fee + the gift part\'s, and Stripe never gets more than the charge', async () => {
    const { checkoutFeeSplit } = await import('../../supabase/functions/_shared/platformFee.ts');
    for (const [c, g] of [[0, 1999], [50, 5000], [1234, 999], [99999, 1], [3000, 0], [60, 60]]) {
      const f = giftCardOrderFee(c, g, false, { bps: 300, card });
      const base = checkoutFeeSplit(c, { bps: 300, card });
      expect(f.exosFeeCents + f.owedCents).toBe(base.exosFeeCents + f.giftExosFeeCents);
      expect(f.giftExosFeeCents).toBe(Math.floor(((c + g) * 300 + 5000) / 10000) - Math.floor((c * 300 + 5000) / 10000));
      expect(f.applicationFeeCents).toBeLessThanOrEqual(c);
      expect(f.applicationFeeCents).toBe(f.exosFeeCents + f.cardFeeEstCents);
    }
  });
});

describe('giving maths', () => {
  it('parses donation amounts', () => {
    expect(parseDonationCents(2500)).toBe(2500);
    expect(parseDonationCents('2500')).toBe(2500);
    expect(parseDonationCents(99)).toBeNull();
    expect(parseDonationCents(25.5)).toBeNull();
    expect(parseDonationCents(10_000_001)).toBeNull();
    expect(parseDonationCents(null)).toBeNull();
  });
  it('major units to cents without float drift', () => {
    expect(majorToCents('25')).toBe(2500);
    expect(majorToCents('19.99')).toBe(1999);
    expect(majorToCents('0.1')).toBe(10);
    expect(majorToCents('1.005')).toBeNull();
    expect(majorToCents('-5')).toBeNull();
  });
  it('cover fees round half up', () => {
    expect(coverFeesCents(2500, 300)).toBe(75);
    expect(coverFeesCents(1999, 300)).toBe(60); // 59.97
    expect(coverFeesCents(50, 300)).toBe(2); // 1.5 -> 2
    expect(coverFeesCents(0, 300)).toBe(0);
  });
  it('round up to the next whole unit, or the next 5 when whole', () => {
    expect(roundUpDonationCents(4311)).toBe(89);
    expect(roundUpDonationCents(4300)).toBe(200);
    expect(roundUpDonationCents(4500)).toBe(500);
    expect(roundUpDonationCents(0)).toBe(0);
  });
  it('campaign progress', () => {
    expect(campaignProgress(500, 1000)).toBe(0.5);
    expect(campaignProgress(5000, 1000)).toBe(1);
    expect(campaignProgress(5000, 0)).toBe(0);
  });
  it('donations CSV escapes formula cells', () => {
    const csv = donationsCsv([{
      created_at: '2026-10-30T00:00:00Z', campaign: 'Roof', amount_cents: 2500, cover_fees_cents: 75, total_cents: 2575,
      currency: 'usd', method: 'card', donor_name: '=HYPERLINK("x")', donor_email: 'a@x.com', anonymous: false,
      session_id: null, status: 'received', note: null, receipt_number: 3,
    }]);
    expect(csv.split('\r\n')[1]).toBe(`2026-10-30T00:00:00Z,Roof,25.00,0.75,25.75,USD,card,"'=HYPERLINK(""x"")",a@x.com,false,,received,,3`);
  });
});

describe('member price and passes', () => {
  it('member discount half up once', () => {
    expect(memberUnitCents(2000, 10)).toBe(1800);
    expect(memberUnitCents(1999, 10)).toBe(1799); // 199.9 -> 200 off
    expect(memberUnitCents(1995, 10)).toBe(1795); // 199.5 -> 200 off
    expect(memberUnitCents(1000, 0)).toBe(1000);
    expect(memberUnitCents(1000, 100)).toBe(0);
    expect(memberUnitCents(0, 50)).toBe(0);
    expect(memberUnitCents(1000, 12.5)).toBe(875);
  });
  it('the docs example: $25 -> 20% promo -> 10% member = $18', () => {
    expect(memberUnitCents(2000, 10)).toBe(1800);
  });
  it('member price covers 1 + guests tickets', () => {
    expect(memberPriceApplies(1, 0)).toBe(true);
    expect(memberPriceApplies(2, 0)).toBe(false);
    expect(memberPriceApplies(3, 2)).toBe(true);
    expect(memberPriceApplies(0, 2)).toBe(false);
  });
  it('pass eligibility', () => {
    const ev = { id: 'e1', starts_at: '2026-11-15T20:00:00Z' };
    expect(passCovers({ event_ids: ['e1'] }, ev, 't1')).toBe(true);
    expect(passCovers({ event_ids: ['e2'] }, ev, 't1')).toBe(false);
    expect(passCovers({ date_from: '2026-11-01T00:00:00Z', date_to: '2026-12-01T00:00:00Z' }, ev, 't1')).toBe(true);
    expect(passCovers({ date_from: '2026-12-01T00:00:00Z' }, ev, 't1')).toBe(false);
    expect(passCovers({ date_to: '2026-11-15T20:00:00Z' }, ev, 't1')).toBe(false);
    expect(passCovers({ event_ids: ['e1'], tier_ids: ['t2'] }, ev, 't1')).toBe(false);
    expect(passCovers({}, { id: 'e1', starts_at: null }, 't1')).toBe(false);
    expect(passCreditsLeft(5, 2)).toBe(3);
    expect(passCreditsLeft(null, 99)).toBeNull();
    expect(passCreditsLeft(2, 5)).toBe(0);
  });
  it('Stripe subscription status mapping', () => {
    expect(membershipStatusFromStripe('trialing')).toBe('active');
    expect(membershipStatusFromStripe('unpaid')).toBe('past_due');
    expect(membershipStatusFromStripe('canceled')).toBe('cancelled');
    expect(membershipStatusFromStripe('incomplete_expired')).toBe('expired');
    expect(membershipStatusFromStripe('incomplete')).toBeNull();
  });
});

describe('request body cap (exos-commerce, exos-checkout)', () => {
  it('reads a small body and refuses an oversized one, declared or streamed', async () => {
    const { readCapped } = await import('../../supabase/functions/_shared/api/body.ts');
    expect(await readCapped(new Request('https://x.test', { method: 'POST', body: '{"a":1}' }), 100)).toBe('{"a":1}');
    expect(await readCapped(new Request('https://x.test', { method: 'POST', body: 'x'.repeat(101) }), 100)).toBeNull();
    const stream = new ReadableStream({ pull(c) { c.enqueue(new Uint8Array(64)); } }); // endless, no length
    expect(await readCapped(new Request('https://x.test', { method: 'POST', body: stream, duplex: 'half' } as RequestInit), 1000)).toBeNull();
  });
});
