import { beforeEach, describe, expect, it, vi } from 'vitest';
import {
  getConsent,
  getConsentState,
  hasConsent,
  onConsentChange,
  onOpenConsentSettings,
  openConsentSettings,
  parseStoredConsent,
  resolveConsent,
  setConsent,
  setConsentChoice,
} from './consent';

const store = new Map<string, string>();
vi.stubGlobal('localStorage', {
  getItem: (k: string) => store.get(k) ?? null,
  setItem: (k: string, v: string) => void store.set(k, String(v)),
  removeItem: (k: string) => void store.delete(k),
  clear: () => store.clear(),
});
const nav: { globalPrivacyControl?: unknown } = {};
vi.stubGlobal('navigator', nav);

describe('parseStoredConsent', () => {
  it('reads the two-category record', () => {
    expect(parseStoredConsent('{"analytics":"granted","advertising":"denied","at":"x"}', null))
      .toEqual({ analytics: 'granted', advertising: 'denied' });
  });
  it('maps the legacy single flag to both categories', () => {
    expect(parseStoredConsent(null, 'granted')).toEqual({ analytics: 'granted', advertising: 'granted' });
    expect(parseStoredConsent(null, 'denied')).toEqual({ analytics: 'denied', advertising: 'denied' });
    expect(parseStoredConsent(null, 'maybe')).toEqual({});
  });
  it('prefers v2 and ignores junk', () => {
    expect(parseStoredConsent('{"analytics":"denied"}', 'granted')).toEqual({ analytics: 'denied' });
    expect(parseStoredConsent('not json', 'denied')).toEqual({ analytics: 'denied', advertising: 'denied' });
    expect(parseStoredConsent('{"analytics":"yes"}', null)).toEqual({});
  });
});

describe('resolveConsent', () => {
  it('is unset until chosen', () => {
    expect(resolveConsent({}, false)).toEqual({ analytics: 'unset', advertising: 'unset', gpc: false, decided: false });
  });
  it('treats GPC as advertising denied, analytics untouched', () => {
    expect(resolveConsent({}, true)).toEqual({ analytics: 'unset', advertising: 'denied', gpc: true, decided: false });
  });
  it('lets an explicit opt-in override GPC', () => {
    expect(resolveConsent({ analytics: 'granted', advertising: 'granted' }, true).advertising).toBe('granted');
  });
});

describe('store', () => {
  beforeEach(() => {
    store.clear();
    delete nav.globalPrivacyControl;
  });

  it('keeps the legacy value working', () => {
    store.set('exos.consent.marketing.v1', 'granted');
    expect(getConsentState()).toMatchObject({ analytics: 'granted', advertising: 'granted', decided: true });
    expect(getConsent()).toBe('granted');
  });

  it('saves a split choice, drops the legacy key and notifies', () => {
    store.set('exos.consent.marketing.v1', 'granted');
    const seen: string[] = [];
    const off = onConsentChange((s) => seen.push(`${s.analytics}/${s.advertising}`));
    setConsentChoice({ analytics: true, advertising: false });
    off();
    expect(seen).toEqual(['granted/denied']);
    expect(store.has('exos.consent.marketing.v1')).toBe(false);
    expect(hasConsent('analytics')).toBe(true);
    expect(hasConsent('advertising')).toBe(false);
    expect(getConsent()).toBe('denied');
  });

  it('legacy setConsent decides both', () => {
    setConsent(false);
    expect(getConsentState()).toMatchObject({ analytics: 'denied', advertising: 'denied', decided: true });
  });

  it('honors GPC until the visitor opts in', () => {
    nav.globalPrivacyControl = true;
    expect(getConsentState().advertising).toBe('denied');
    setConsentChoice({ analytics: true, advertising: true });
    expect(getConsentState()).toMatchObject({ advertising: 'granted', gpc: true });
  });

  it('reopens the banner on request', () => {
    const fn = vi.fn();
    const off = onOpenConsentSettings(fn);
    openConsentSettings();
    off();
    openConsentSettings();
    expect(fn).toHaveBeenCalledTimes(1);
  });
});
