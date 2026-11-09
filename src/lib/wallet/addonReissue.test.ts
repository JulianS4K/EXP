// claude/exos-api-leftovers (mig 20261111140000): reissuing an add-on wallet
// pass, and the reservation update's answers. SQL side:
// tests/exos/test_api_leftovers.sql AL1-AL4.
import { describe, expect, it, vi } from 'vitest';
vi.mock('../supabase', () => ({ supabase: {} }));
import { appleAddonWalletCode, googleTotpKey, totp } from '../../../supabase/functions/_shared/wallet/codes.ts';
import { addonDoorKeysFromSecret, verifyAddonWalletWithKeys } from '../../../supabase/functions/_shared/doorKeys.ts';
import { routeWallet } from '../../../supabase/functions/_shared/wallet/routes.ts';
import { reservationAnswersParam } from '../../../supabase/functions/_shared/partners/sales.ts';
import { verifyBarcode } from '../barcode';
import { parseAddonPasses } from '../addonPasses';
import { ADDON_REISSUES_PER_DAY, addonReissueEligible, walletErrorMessage } from '../walletButtons';

// The DL5 vectors (tests/exos/test_dice_leftovers.sql, src/lib/wallet/addonPass.test.ts).
const PASS = '11111111-2222-4333-8444-555555555555';
const OWNER = '66666666-7777-4888-8999-000000000000';
const SECRET = 'vector-secret';
const SQL_APPLE_3 = `A-${PASS}:${OWNER}:a3:rYCAPorA6t4ek-4LcOG5D7xjTJsvYFsdU5QpaAkwEI0`;
const STEP = 59_000_000;

describe('add-on wallet reissue: the door refuses the old epoch', () => {
  it('keys saved after a reissue refuse the old Apple and Google codes and take the new ones', async () => {
    const now = STEP * 30_000 + 5_000;
    const before = await addonDoorKeysFromSecret(PASS, OWNER, SECRET, now, 3);
    const after = await addonDoorKeysFromSecret(PASS, OWNER, SECRET, now, 4);
    const apple4 = await appleAddonWalletCode(PASS, OWNER, SECRET, 4);
    const google3 = `A-${PASS}:${OWNER}:g3:${await totp(await googleTotpKey(PASS, OWNER, SECRET, 3), STEP)}`;
    const google4 = `A-${PASS}:${OWNER}:g4:${await totp(await googleTotpKey(PASS, OWNER, SECRET, 4), STEP)}`;
    expect(apple4).not.toBe(SQL_APPLE_3);
    expect((await verifyAddonWalletWithKeys(SQL_APPLE_3, before)).ok).toBe(true);
    expect((await verifyAddonWalletWithKeys(SQL_APPLE_3, after)).ok).toBe(false);
    expect((await verifyAddonWalletWithKeys(google3, after, { now })).ok).toBe(false);
    expect((await verifyAddonWalletWithKeys(apple4, after)).ok).toBe(true);
    expect((await verifyAddonWalletWithKeys(google4, after, { now })).ok).toBe(true);
    // Through the scanner's own check.
    expect(await verifyBarcode(SQL_APPLE_3, after)).toMatchObject({ ok: false, reason: 'signature-mismatch', ticketId: PASS });
    expect(await verifyBarcode(apple4, after)).toMatchObject({ ok: true, ticketId: PASS, ownerId: OWNER });
  });

  it('routes POST /addon-reissue only', () => {
    expect(routeWallet('POST', '/functions/v1/exos-wallet/addon-reissue')).toEqual({ kind: 'addon-reissue' });
    expect(routeWallet('GET', '/functions/v1/exos-wallet/addon-reissue')).toEqual({ kind: 'not-found' });
    expect(routeWallet('POST', '/functions/v1/exos-wallet/addon-pass')).toEqual({ kind: 'addon-pass' });
  });

  it('is offered only for a usable unit that is in a wallet', () => {
    expect(addonReissueEligible({ status: 'active', barcodeSecret: 's', walletEpoch: 1 })).toBe(true);
    expect(addonReissueEligible({ status: 'active', barcodeSecret: 's', walletEpoch: null })).toBe(false);
    expect(addonReissueEligible({ status: 'used', barcodeSecret: 's', walletEpoch: 2 })).toBe(false);
    expect(addonReissueEligible({ status: 'voided', barcodeSecret: null, walletEpoch: 2 })).toBe(false);
    expect(addonReissueEligible({ status: 'active', barcodeSecret: 's', walletEpoch: 0 })).toBe(false);
  });

  it('reads the epoch from exos_my_addon_passes', () => {
    const p = parseAddonPasses([
      { id: 'a', event_id: 'e', addon_id: 'x', addon_name: 'Lounge', unit_index: 1, status: 'active', barcode_secret: 's', wallet_epoch: 2 },
      { id: 'b', event_id: 'e', addon_id: 'x', addon_name: 'Lounge', unit_index: 2, status: 'active', barcode_secret: 's', wallet_epoch: null },
      { id: 'c', event_id: 'e', addon_id: 'x', addon_name: 'Lounge', unit_index: 3, status: 'active', barcode_secret: 's', wallet_epoch: '3' },
    ]);
    expect(p.map((x) => x.walletEpoch)).toEqual([2, null, null]);
  });

  it('says why a reissue was refused', () => {
    expect(walletErrorMessage('rate-limited')).toContain(`${ADDON_REISSUES_PER_DAY} times a day`);
    expect(ADDON_REISSUES_PER_DAY).toBe(5);
    expect(walletErrorMessage('no-pass')).toMatch(/isn't in a wallet yet/);
    expect(walletErrorMessage('not your add-on')).toMatch(/Only the add-on holder/);
  });
});

describe('reservation update answers (PUT …/ticket_reservations/:token)', () => {
  it('takes answers wrapped, flat or as Rails-style form fields, as the reserve does', () => {
    const q = 'q-size';
    expect(reservationAnswersParam({ ticket_reservation: { first_name: 'Jane', answers: { tickets: [{ [q]: 'L' }] } } }, 'ticket_reservation'))
      .toEqual({ tickets: [{ [q]: 'L' }] });
    expect(reservationAnswersParam({ answers: { order: { c: 'Acme' } } }, 'ticket_reservation')).toEqual({ order: { c: 'Acme' } });
    // A form body gives tickets as { "0": …, "1": … }: a list in index order.
    expect(reservationAnswersParam({ ticket_reservation: { answers: { tickets: { 1: { [q]: 'S' }, 0: { [q]: 'L' } } } } }, 'ticket_reservation'))
      .toEqual({ tickets: [{ [q]: 'L' }, { [q]: 'S' }] });
    // No answers: an attendee-only update leaves the stored set alone.
    expect(reservationAnswersParam({ ticket_reservation: { first_name: 'Jane' } }, 'ticket_reservation')).toBeUndefined();
    expect(() => reservationAnswersParam({ answers: ['L'] }, 'ticket_reservation')).toThrow(/answers must be an object/);
  });
});
