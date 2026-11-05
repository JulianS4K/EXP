import { describe, expect, it, vi } from 'vitest';
vi.mock('./supabase', () => ({ supabase: {} }));
import { currentBucket, extractTicketIdFromAny, isAddonCode, normalizeCodePrefix, signAddonBarcode, signBarcode, verifyBarcode } from './barcode';
import { decideScan, parseDoorCode, type DoorCachedTicket, type ScanDecisionInput } from './door/decide';
import { addonListRefusal, describeList, listAdmitsTier, mapCheckinListRow, type DoorCheckinList } from './door/lists';
import { buildAddonRoster } from './door/roster';
import { parseAddonPasses } from './addonPasses';
import { doorKeysFromSecret } from '../../supabase/functions/_shared/doorKeys.ts';

// An add-on's own entry code (mig 20261107110000; DICE Extra.hasSeparateAccessBarcode).
const EVENT = 'eeeeeeee-0000-4000-8000-000000000001';
const PASS = 'aaaaaaaa-1111-4000-8000-000000000001';
const OWNER = 'bbbbbbbb-1111-4000-8000-000000000001';
const LOUNGE_ADDON = 'cccccccc-1111-4000-8000-000000000001';
const NOW = Date.UTC(2026, 10, 7, 21, 0, 0);
const HOUR = 3_600_000;

const list = (over: Partial<DoorCheckinList>): DoorCheckinList => ({
  id: 'l1', name: 'L', tierIds: null, allowReentry: false, validFrom: null, validUntil: null, sortOrder: 0, admits: 'tickets', addonIds: null, ...over,
});
const main = list({ id: 'main', name: 'Main door' });
const lounge = list({ id: 'lounge', name: 'VIP lounge', admits: 'addons', addonIds: [LOUNGE_ADDON] });
const anyAddon = list({ id: 'pickup', name: 'Pickup', admits: 'addons' });
const both = list({ id: 'both', name: 'Everything', admits: 'both' });

const pass: DoorCachedTicket = { used: false, voided: false, pendingTransferId: null, addon: true, addonId: LOUNGE_ADDON };
const ticket: DoorCachedTicket = { used: false, voided: false, pendingTransferId: null, tierId: 'tier-1' };

function input(code: string, entry: DoorCachedTicket, l: DoorCheckinList | null, over: Partial<ScanDecisionInput> = {}): ScanDecisionInput {
  return {
    code: parseDoorCode(code, 'camera'), source: 'camera', eventId: EVENT, entry, queued: false, verify: { ok: true },
    network: 'offline', gate: { opensAt: NOW - HOUR, testUntil: null }, now: NOW, canOverride: false, recent: null, list: l, ...over,
  };
}

describe('the code', () => {
  it('is the ticket scheme with an A- prefix, checked with the door keys', async () => {
    const bucket = currentBucket(NOW);
    const code = await signAddonBarcode(PASS, OWNER, 'pass-secret', bucket);
    expect(code.startsWith(`A-${PASS}:${OWNER}:${bucket}:`)).toBe(true);
    // The same MAC a ticket with that id and secret would get (one scheme).
    const t = await signBarcode(PASS, OWNER, 'pass-secret', bucket);
    expect(code.slice(2)).toBe(t.slice(2));
    const keys = await doorKeysFromSecret(PASS, OWNER, 'pass-secret', NOW);
    expect((await verifyBarcode(code, keys, { now: NOW })).ok).toBe(true);
    expect((await verifyBarcode(code.toLowerCase().slice(0, 2) + code.slice(2), keys, { now: NOW })).ok).toBe(true);
    const other = await doorKeysFromSecret(PASS, OWNER, 'another-secret', NOW);
    expect((await verifyBarcode(code, other, { now: NOW })).reason).toBe('signature-mismatch');
    expect((await verifyBarcode(code, keys, { now: NOW + 10 * 60_000 })).reason).toBe('bucket-expired');
  });
  it('parses as a code, never a typed override', () => {
    expect(isAddonCode(`a-${PASS}:x:1:y`)).toBe(true);
    expect(isAddonCode(`T-${PASS}:x:1:y`)).toBe(false);
    expect(normalizeCodePrefix('a-x')).toBe('A-x');
    expect(extractTicketIdFromAny(`A-${PASS}:x:1:y`)).toBe(PASS);
    const c = parseDoorCode(`A-${PASS}:${OWNER}:1:sig`, 'manual');
    expect(c.bare).toBe(false);
    expect(c.ticketId).toBe(PASS);
  });
});

describe('lists', () => {
  it('admits', () => {
    expect(mapCheckinListRow({ id: 'x', name: 'x', admits: 'addons', addon_ids: [LOUNGE_ADDON] })).toMatchObject({ admits: 'addons', addonIds: [LOUNGE_ADDON] });
    expect(mapCheckinListRow({ id: 'x', name: 'x', addon_ids: [LOUNGE_ADDON] })).toMatchObject({ admits: 'tickets', addonIds: null });
    expect(mapCheckinListRow({ id: 'x', name: 'x', admits: 'nonsense' }).admits).toBe('tickets');
    expect(listAdmitsTier(lounge, 'tier-1')).toBe(false);
    expect(listAdmitsTier(both, 'tier-1')).toBe(true);
    expect(addonListRefusal(null, LOUNGE_ADDON)).toBe('tickets-only-list');
    expect(addonListRefusal(main, LOUNGE_ADDON)).toBe('tickets-only-list');
    expect(addonListRefusal(lounge, 'other-addon')).toBe('wrong-list');
    expect(addonListRefusal(lounge, LOUNGE_ADDON)).toBeNull();
    expect(addonListRefusal(anyAddon, null)).toBeNull();
    expect(describeList(lounge, () => 'GA', () => 'Lounge')).toBe('Add-on codes only (Lounge) · no re-entry');
  });
});

describe('the door decides offline like the server', () => {
  const CODE = `A-${PASS}:${OWNER}:1:sig`;
  const TCODE = `T-${PASS}:${OWNER}:1:sig`;
  it('an add-on code at its list is admitted', () => {
    expect(decideScan(input(CODE, pass, lounge))).toMatchObject({ action: 'admit', queue: true });
    expect(decideScan(input(CODE, pass, anyAddon))).toMatchObject({ action: 'admit' });
    expect(decideScan(input(CODE, pass, both))).toMatchObject({ action: 'admit' });
  });
  it('refused at a ticket list, with no list, and at another add-on\'s list', () => {
    expect(decideScan(input(CODE, pass, main))).toMatchObject({ action: 'reject', reason: 'tickets-only-list' });
    expect(decideScan(input(CODE, pass, null))).toMatchObject({ action: 'reject', reason: 'tickets-only-list' });
    expect(decideScan(input(CODE, { ...pass, addonId: 'other' }, lounge))).toMatchObject({ action: 'reject', reason: 'wrong-list' });
    expect(decideScan(input(CODE, { ...pass, used: true }, lounge))).toMatchObject({ action: 'reject', reason: 'used' });
    expect(decideScan(input(CODE, { ...pass, voided: true }, lounge))).toMatchObject({ action: 'reject', reason: 'voided' });
  });
  it('a ticket at an add-on-only list is refused; at "both" it is in', () => {
    expect(decideScan(input(TCODE, ticket, lounge))).toMatchObject({ action: 'reject', reason: 'addon-only-list' });
    expect(decideScan(input(TCODE, ticket, both))).toMatchObject({ action: 'admit' });
    expect(decideScan(input(TCODE, ticket, main))).toMatchObject({ action: 'admit' });
  });
  it('online, the server decides', () => {
    expect(decideScan(input(CODE, pass, main, { network: 'online' }))).toMatchObject({ action: 'ask-server', ticketId: PASS });
    expect(decideScan(input(CODE, undefined as unknown as DoorCachedTicket, lounge, { network: 'online', entry: null, verify: null })))
      .toMatchObject({ action: 'ask-server', ticketId: PASS });
  });
});

describe('the saved list and the holder', () => {
  it('buildAddonRoster: door keys, never a secret; voided and used kept', () => {
    const r = buildAddonRoster([
      { id: PASS, addon_id: LOUNGE_ADDON, addon_name: 'VIP lounge', owner_id: OWNER, status: 'used', door_keys: { d: { '20399': 'k' } }, list_state: { pickup: 'entry' } },
      { id: 'p2', addon_id: null, addon_name: null, owner_id: OWNER, status: 'voided', door_keys: { d: {} } },
      { nope: true },
    ]);
    expect(Object.keys(r)).toEqual([PASS, 'p2']);
    expect(r[PASS]).toMatchObject({ addon: true, addonId: LOUNGE_ADDON, used: true, name: 'VIP lounge', lists: { pickup: 'entry' } });
    expect(r[PASS].doorKeys?.d).toEqual({ '20399': 'k' });
    expect(r.p2).toMatchObject({ voided: true, addonId: null, name: 'Add-on' });
    expect(buildAddonRoster(null)).toEqual({});
  });
  it('parseAddonPasses numbers each add-on\'s units', () => {
    const p = parseAddonPasses([
      { id: 'a', event_id: 'e', addon_id: 'x', addon_name: 'Lounge', unit_index: 1, status: 'active', barcode_secret: 's1' },
      { id: 'b', event_id: 'e', addon_id: 'x', addon_name: 'Lounge', unit_index: 2, status: 'voided', barcode_secret: null },
      { id: 'c', event_id: 'e', addon_id: 'y', addon_name: 'Merch', unit_index: 1, status: 'used', barcode_secret: 's3' },
    ]);
    expect(p.map((x) => [x.id, x.unitIndex, x.unitCount, x.status])).toEqual([['a', 1, 2, 'active'], ['b', 2, 2, 'voided'], ['c', 1, 1, 'used']]);
    expect(p[1].barcodeSecret).toBeNull();
    expect(parseAddonPasses('nope')).toEqual([]);
  });
});
