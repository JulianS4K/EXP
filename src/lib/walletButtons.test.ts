import { describe, expect, it } from 'vitest';
import {
  availabilityFromStatus,
  detectWalletPlatform,
  isGoogleSaveUrl,
  readWalletAvailability,
  unprobedWalletKinds,
  visibleWalletKinds,
  walletEligible,
  walletErrorMessage,
  walletKindsFor,
  writeWalletAvailability,
  WALLET_AVAILABILITY_KEY,
} from './walletButtons';

const UA = {
  iphone: 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/604.1',
  iphoneChrome: 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) CriOS/126.0.6478.54 Mobile/15E148 Safari/604.1',
  ipadDesktop: 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Safari/605.1.15',
  macSafari: 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Safari/605.1.15',
  android: 'Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Mobile Safari/537.36',
  windowsChrome: 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36',
};

function memoryStore(initial: Record<string, string> = {}) {
  const m = new Map(Object.entries(initial));
  return {
    getItem: (k: string) => m.get(k) ?? null,
    setItem: (k: string, v: string) => void m.set(k, v),
    raw: m,
  };
}

describe('detectWalletPlatform / walletKindsFor', () => {
  it('iPhone (Safari or Chrome) gets Apple only', () => {
    expect(detectWalletPlatform(UA.iphone)).toBe('ios');
    expect(detectWalletPlatform(UA.iphoneChrome)).toBe('ios');
    expect(walletKindsFor('ios')).toEqual(['apple']);
  });
  it('an iPad asking for the desktop site is still iOS (touch screen)', () => {
    expect(detectWalletPlatform(UA.ipadDesktop, 5)).toBe('ios');
  });
  it('Android gets Google only', () => {
    expect(detectWalletPlatform(UA.android, 5)).toBe('android');
    expect(walletKindsFor('android')).toEqual(['google']);
  });
  it('desktops (macOS Safari, Windows Chrome) get both', () => {
    expect(detectWalletPlatform(UA.macSafari, 0)).toBe('desktop');
    expect(detectWalletPlatform(UA.windowsChrome)).toBe('desktop');
    expect(detectWalletPlatform('')).toBe('desktop');
    expect(walletKindsFor('desktop')).toEqual(['apple', 'google']);
  });
});

describe('availabilityFromStatus', () => {
  it('503 means not configured', () => expect(availabilityFromStatus(503)).toBe(false));
  it('the probe answer 403 (and other 2xx/4xx) means configured', () => {
    for (const s of [200, 400, 401, 403, 409]) expect(availabilityFromStatus(s)).toBe(true);
  });
  it('network failures and other 5xx are unknown', () => {
    for (const s of [0, 500, 502, 504]) expect(availabilityFromStatus(s)).toBeNull();
  });
});

describe('session cache', () => {
  it('reads nothing from an empty, missing or malformed store', () => {
    expect(readWalletAvailability(null)).toEqual({});
    expect(readWalletAvailability(memoryStore())).toEqual({});
    expect(readWalletAvailability(memoryStore({ [WALLET_AVAILABILITY_KEY]: 'not json' }))).toEqual({});
    expect(readWalletAvailability(memoryStore({ [WALLET_AVAILABILITY_KEY]: '{"apple":"yes","google":false}' }))).toEqual({ google: false });
  });
  it('writes each kind without losing the other', () => {
    const s = memoryStore();
    writeWalletAvailability(s, 'apple', false);
    expect(writeWalletAvailability(s, 'google', true)).toEqual({ apple: false, google: true });
    expect(readWalletAvailability(s)).toEqual({ apple: false, google: true });
  });
  it('survives a store that throws', () => {
    const bad = { getItem: () => { throw new Error('blocked'); }, setItem: () => { throw new Error('blocked'); } };
    expect(readWalletAvailability(bad)).toEqual({});
    expect(writeWalletAvailability(bad, 'apple', true)).toEqual({ apple: true });
  });
});

describe('visibleWalletKinds / unprobedWalletKinds', () => {
  it('shows nothing until a probe says the wallet is set up', () => {
    expect(visibleWalletKinds('desktop', {})).toEqual([]);
    expect(unprobedWalletKinds('desktop', {})).toEqual(['apple', 'google']);
  });
  it('hides a wallet that answered 503, keeps the other', () => {
    const a = { apple: false, google: true };
    expect(visibleWalletKinds('desktop', a)).toEqual(['google']);
    expect(visibleWalletKinds('ios', a)).toEqual([]);
    expect(visibleWalletKinds('android', a)).toEqual(['google']);
    expect(unprobedWalletKinds('desktop', a)).toEqual([]);
  });
  it('only probes the platform\'s own wallets', () => {
    expect(unprobedWalletKinds('ios', { google: true })).toEqual(['apple']);
    expect(unprobedWalletKinds('android', { apple: false })).toEqual(['google']);
  });
});

describe('walletEligible', () => {
  const me = 'user-1';
  const base = { status: 'active', pendingTransferId: null, ownerId: me };
  it('an active ticket the viewer holds', () => expect(walletEligible(base, me)).toBe(true));
  it('not voided, used, in transfer, given away, or signed out', () => {
    expect(walletEligible({ ...base, status: 'voided' }, me)).toBe(false);
    expect(walletEligible({ ...base, status: 'used' }, me)).toBe(false);
    expect(walletEligible({ ...base, pendingTransferId: 'tr-1' }, me)).toBe(false);
    expect(walletEligible({ ...base, ownerId: 'someone-else' }, me)).toBe(false);
    expect(walletEligible(base, null)).toBe(false);
  });
});

describe('walletErrorMessage / isGoogleSaveUrl', () => {
  it('maps the 409 reasons to holder sentences', () => {
    expect(walletErrorMessage('in-transfer')).toMatch(/transfer/);
    expect(walletErrorMessage('not-active')).toMatch(/no longer/);
    expect(walletErrorMessage(undefined)).toMatch(/Try again/);
  });
  it('accepts only https://pay.google.com links', () => {
    expect(isGoogleSaveUrl('https://pay.google.com/gp/v/save/abc.def.ghi')).toBe(true);
    expect(isGoogleSaveUrl('http://pay.google.com/gp/v/save/x')).toBe(false);
    expect(isGoogleSaveUrl('https://pay.google.com.evil.example/x')).toBe(false);
    expect(isGoogleSaveUrl('javascript:alert(1)')).toBe(false);
    expect(isGoogleSaveUrl(null)).toBe(false);
  });
});
