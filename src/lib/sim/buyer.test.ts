// Buyer mistake simulations, pure-logic side (claude/exos-sim-buyer). The SQL
// side is tests/exos/sim_buyer.sql (same SIM-BUYER numbers where they overlap).
import { describe, expect, it, vi } from 'vitest';

vi.mock('../../context/AuthContext', () => ({ useAuth: () => ({ user: null, openAuth: vi.fn() }) }));
vi.mock('../../context/ToastContext', () => ({ useToast: () => ({ toast: vi.fn() }) }));
vi.mock('../vouchers', () => ({ checkVoucher: vi.fn() }));

import { voucherErrorMessage } from '../../components/VoucherField';
import {
  GIFT_CARD_ALPHABET, giftCardApplied, giftCardCheckOk, makeGiftCardCode, normalizeAnyGiftCardCode,
} from '../../../supabase/functions/_shared/commerce.ts';
import { currentBucket, signBarcode, verifyBarcode } from '../barcode';
import { decideScan, parseDoorCode, type ScanDecisionInput } from '../door/decide';

describe('SIM-BUYER-19 promo code errors the buyer sees', () => {
  it('the throttle tells the buyer to wait, not to check the spelling (FIXED)', () => {
    const msg = voucherErrorMessage('too many attempts');
    expect(msg).toMatch(/wait 10 minutes/i);
    expect(msg).not.toMatch(/spelling/i);
  });
  it('wrong, expired and used-up codes keep their own copy', () => {
    expect(voucherErrorMessage('invalid code')).toMatch(/spelling/i);
    expect(voucherErrorMessage('expired')).toMatch(/expired/i);
    expect(voucherErrorMessage('already used')).toMatch(/already been used/i);
  });
});

describe('SIM-BUYER-15 gift card typos (client side, before checkout)', () => {
  const code = makeGiftCardCode(new Uint8Array([3, 14, 15, 92, 65, 35, 89, 79, 32, 38, 46, 26, 43, 38, 32]));
  it('every single-character typo fails the check character', () => {
    expect(giftCardCheckOk(code)).toBe(true);
    for (let i = 0; i < code.length; i++) {
      for (const ch of GIFT_CARD_ALPHABET) {
        if (ch === code[i]) continue;
        expect(giftCardCheckOk(code.slice(0, i) + ch + code.slice(i + 1))).toBe(false);
      }
    }
  });
  it('lower case, spaces and dashes are what the buyer typed, not a typo', () => {
    const typed = ` ${code.slice(0, 4).toLowerCase()} ${code.slice(4, 8)}-${code.slice(8)} `;
    expect(normalizeAnyGiftCardCode(typed)).toBe(code);
  });
  it('an imported short code is sent as typed (normalized), the server decides', () => {
    expect(normalizeAnyGiftCardCode('simb 77')).toBe('SIMB77');
    expect(normalizeAnyGiftCardCode('x1')).toBeNull();   // too short: refused before any request
  });
  it('a card smaller than the order leaves a chargeable card part; a tiny rest is not left under 0.50', () => {
    expect(giftCardApplied(2000, 5000)).toBe(2000);
    expect(giftCardApplied(2000, 1000)).toBe(1000);
    expect(giftCardApplied(2000, 1980)).toBe(1950);
  });
});

describe('SIM-BUYER-24 rotating QR screenshots (the door device)', () => {
  const TICKET = '11111111-2222-3333-4444-555555555555';
  const OWNER = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee';
  const SECRET = 'sim-buyer-secret';
  const NOW = Date.UTC(2026, 10, 4, 21, 0, 0);
  const base = (raw: string, verify: ScanDecisionInput['verify'], network: ScanDecisionInput['network'],
                entry: ScanDecisionInput['entry'] = { used: false }): ScanDecisionInput => ({
    code: parseDoorCode(raw, 'camera'), source: 'camera', eventId: 'e1', entry, verify, network,
    gate: { opensAt: NOW - 3_600_000, testUntil: null }, now: NOW, canOverride: false,
  });

  it('a three-minute-old screenshot is refused offline and online', async () => {
    const old = await signBarcode(TICKET, OWNER, SECRET, currentBucket(NOW - 180_000));
    const v = await verifyBarcode(old, SECRET, { now: NOW });
    expect(v.ok).toBe(false);
    expect(decideScan(base(old, v, 'offline'))).toMatchObject({ action: 'reject', reason: 'invalid-barcode' });
    expect(decideScan(base(old, v, 'online'))).toMatchObject({ action: 'reject', reason: 'invalid-barcode' });
  });

  it('a live code admits offline once; the queued scan makes the next copy "used"', async () => {
    const live = await signBarcode(TICKET, OWNER, SECRET, currentBucket(NOW));
    const v = await verifyBarcode(live, SECRET, { now: NOW });
    expect(decideScan(base(live, v, 'offline'))).toMatchObject({ action: 'admit', queue: true });
    expect(decideScan({ ...base(live, v, 'offline'), queued: true, now: NOW + 60_000 }))
      .toMatchObject({ action: 'reject', reason: 'used' });
  });

  it('SIM-BUYER-22 the sender, mid-transfer, is refused offline too', async () => {
    const live = await signBarcode(TICKET, OWNER, SECRET, currentBucket(NOW));
    const v = await verifyBarcode(live, SECRET, { now: NOW });
    expect(decideScan(base(live, v, 'offline', { used: false, pendingTransferId: 'tr1' })))
      .toMatchObject({ action: 'reject', reason: 'in-transfer' });
  });

  it('SIM-BUYER-23 offline after a claim the list did not see yet: the old holder still verifies (KNOWN, inherent to offline)', async () => {
    // The roster was saved before the claim rotated the secret. Online the
    // server refuses the old code (sim_buyer.sql SIM-BUYER-23); offline the
    // device can't know until its next roster delta. The new holder's code
    // fails the cached secret and is refused until the device reconnects.
    const oldHolder = await signBarcode(TICKET, OWNER, SECRET, currentBucket(NOW));
    expect(decideScan(base(oldHolder, await verifyBarcode(oldHolder, SECRET, { now: NOW }), 'offline')))
      .toMatchObject({ action: 'admit' });
    const NEW_OWNER = 'bbbbbbbb-bbbb-cccc-dddd-eeeeeeeeeeee';
    const newHolder = await signBarcode(TICKET, NEW_OWNER, 'rotated-at-claim', currentBucket(NOW));
    expect(decideScan(base(newHolder, await verifyBarcode(newHolder, SECRET, { now: NOW }), 'offline')))
      .toMatchObject({ action: 'reject', reason: 'invalid-barcode' });
    // Online the same mismatch goes to the server, which knows the new secret.
    expect(decideScan(base(newHolder, await verifyBarcode(newHolder, SECRET, { now: NOW }), 'online')))
      .toMatchObject({ action: 'ask-server' });
  });
});
