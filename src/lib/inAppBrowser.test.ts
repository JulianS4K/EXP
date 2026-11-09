// @vitest-environment jsdom
import { describe, expect, it, vi } from 'vitest';
import {
  androidOpenInBrowserUrl, applePayAvailable, copyText, detectInAppBrowser, detectInAppKind, escapeReasons,
  inAppPlatform, iosSafariUrl, isAndroid, isStandalone, menuSteps, openInBrowserPlan, readInAppState,
  storageWorks, withEscapeMarker, type InAppState,
} from './inAppBrowser';
import { inAppRecordFor, sanitizeInAppKind, sanitizeInAppRecord } from '../../supabase/functions/_shared/inAppBrowser.ts';

// Real-world shapes of each app's user agent (iOS and Android). The SQL
// mirror (_exos_in_app_browser_from_ua, tests/exos/test_ig_checkout.sql)
// checks the same strings.
export const UA = {
  igIos: 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148 Instagram 340.0.2.23.108 (iPhone15,2; iOS 17_5; en_US; en; scale=3.00; 1179x2556; 624443862)',
  igAndroid: 'Mozilla/5.0 (Linux; Android 14; Pixel 8 Build/AP2A; wv) AppleWebKit/537.36 (KHTML, like Gecko) Version/4.0 Chrome/126.0.6478.71 Mobile Safari/537.36 Instagram 338.0.0.40.95 Android',
  fbIos: 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148 [FBAN/FBIOS;FBAV/470.0.0.40.108;FBBV/620000000;FBDV/iPhone15,2;FBMD/iPhone;FBSN/iOS;FBSV/17.5;FBSS/3;FBLC/en_US;FBOP/5]',
  fbAndroid: 'Mozilla/5.0 (Linux; Android 14; SM-S918U Build/UP1A; wv) AppleWebKit/537.36 (KHTML, like Gecko) Version/4.0 Chrome/126.0.6478.71 Mobile Safari/537.36 [FB_IAB/FB4A;FBAV/471.0.0.35.80;]',
  messengerAndroid: 'Mozilla/5.0 (Linux; Android 14; wv) AppleWebKit/537.36 (KHTML, like Gecko) Version/4.0 Chrome/126.0 Mobile Safari/537.36 [FB_IAB/MESSENGER;FBAV/460.0.0.49.109;]',
  messengerOrca: 'Mozilla/5.0 (Linux; Android 13; Pixel 7 Build/TQ3A; wv) AppleWebKit/537.36 (KHTML, like Gecko) Version/4.0 Chrome/120.0 Mobile Safari/537.36 [FB_IAB/Orca-Android;FBAV/440.0.0.29.109;]',
  messengerIos: 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148 [FBAN/MessengerForiOS;FBAV/458.0.0.38.108;FBBV/600000000;FBDV/iPhone15,2;FBMD/iPhone;FBSN/iOS;FBSV/17.5;FBSS/3;FBLC/en_US;FBOP/5]',
  threadsIos: 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148 Barcelona 340.0.0.22.109 (iPhone15,2; iOS 17_5; en_US; en; scale=3.00; 1179x2556; 620000000)',
  threadsAndroid: 'Mozilla/5.0 (Linux; Android 14; Pixel 8 Build/AP2A; wv) AppleWebKit/537.36 (KHTML, like Gecko) Version/4.0 Chrome/126.0 Mobile Safari/537.36 Barcelona 340.0.0.22.109 Android (34/14; 420dpi; 1080x2400; Google; Pixel 8; shiba; shiba; en_US; 620000000)',
  tiktokIos: 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148 musical_ly_35.0.0 JsSdk/2.0 NetType/WIFI Channel/App Store ByteLocale/en Region/US',
  tiktokAndroid: 'Mozilla/5.0 (Linux; Android 14; SM-S918U Build/UP1A; wv) AppleWebKit/537.36 (KHTML, like Gecko) Version/4.0 Chrome/126.0.6478.71 Mobile Safari/537.36 trill_350003 JsSdk/1.0 NetType/WIFI Channel/googleplay AppName/musical_ly app_version/35.0.3 ByteLocale/en Region/US BytedanceWebview/d8a21c6',
  snapIos: 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148 Snapchat/13.0.0.40 (like Safari/8618.2.12.10.4, panda)',
  snapAndroid: 'Mozilla/5.0 (Linux; Android 14; SM-S918U Build/UP1A; wv) AppleWebKit/537.36 (KHTML, like Gecko) Version/4.0 Chrome/126.0 Mobile Safari/537.36 Snapchat/13.0.0.40 (SM-S918U; Android 14; gzip)',
  xIos: 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148 Twitter for iPhone/10.50',
  xAndroid: 'Mozilla/5.0 (Linux; Android 14; Pixel 8 Build/AP2A; wv) AppleWebKit/537.36 (KHTML, like Gecko) Version/4.0 Chrome/126.0 Mobile Safari/537.36 TwitterAndroid',
  linkedinIos: 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148 [LinkedInApp]/9.30.1234',
  linkedinAndroid: 'Mozilla/5.0 (Linux; Android 14; Pixel 8 Build/AP2A; wv) AppleWebKit/537.36 (KHTML, like Gecko) Version/4.0 Chrome/126.0 Mobile Safari/537.36 [LinkedInApp]/4.1.900',
  // Generic embedded browsers (no app token).
  androidWv: 'Mozilla/5.0 (Linux; Android 14; Pixel 8 Build/AP2A; wv) AppleWebKit/537.36 (KHTML, like Gecko) Version/4.0 Chrome/126.0 Mobile Safari/537.36',
  iosWk: 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148',
  // Real browsers.
  safari: 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/604.1',
  chromeIos: 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) CriOS/126.0.6478.54 Mobile/15E148 Safari/604.1',
  firefoxIos: 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) FxiOS/127.0 Mobile/15E148 Safari/605.1.15',
  chrome: 'Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.6478.71 Mobile Safari/537.36',
  samsung: 'Mozilla/5.0 (Linux; Android 14; SAMSUNG SM-S918U) AppleWebKit/537.36 (KHTML, like Gecko) SamsungBrowser/25.0 Chrome/121.0.0.0 Mobile Safari/537.36',
  desktopChrome: 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36',
  desktopSafari: 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Safari/605.1.15',
  firefox: 'Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:127.0) Gecko/20100101 Firefox/127.0',
  // Link-preview bots.
  fbBot: 'facebookexternalhit/1.1 (+http://www.facebook.com/externalhit_uatext.php)',
  twitterBot: 'Twitterbot/1.0',
  googlebot: 'Mozilla/5.0 (Linux; Android 6.0.1; Nexus 5X Build/MMB29P) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.6478.126 Mobile Safari/537.36 (compatible; Googlebot/2.1; +http://www.google.com/bot.html)',
};

const APPS = [
  ['igIos', 'instagram'], ['igAndroid', 'instagram'], ['fbIos', 'facebook'], ['fbAndroid', 'facebook'],
  ['messengerAndroid', 'messenger'], ['messengerOrca', 'messenger'], ['messengerIos', 'messenger'],
  ['threadsIos', 'threads'], ['threadsAndroid', 'threads'], ['tiktokIos', 'tiktok'], ['tiktokAndroid', 'tiktok'],
  ['snapIos', 'snapchat'], ['snapAndroid', 'snapchat'], ['xIos', 'x'], ['xAndroid', 'x'],
  ['linkedinIos', 'linkedin'], ['linkedinAndroid', 'linkedin'],
] as const;
const REAL = ['safari', 'chromeIos', 'firefoxIos', 'chrome', 'samsung', 'desktopChrome', 'desktopSafari', 'firefox'] as const;
const BOTS = ['fbBot', 'twitterBot', 'googlebot'] as const;

describe('detectInAppBrowser', () => {
  it.each(APPS)('%s → %s', (k, app) => expect(detectInAppBrowser(UA[k])).toBe(app));

  it.each([...REAL, ...BOTS])('%s is not an in-app browser', (k) => {
    expect(detectInAppBrowser(UA[k])).toBeNull();
    expect(detectInAppKind(UA[k], { standalone: false })).toBeNull();
  });

  it('handles empty input', () => {
    expect(detectInAppBrowser('')).toBeNull();
    expect(detectInAppBrowser(undefined)).toBeNull();
    expect(detectInAppBrowser(null)).toBeNull();
  });
});

describe('detectInAppKind', () => {
  it('names the app when the user agent does', () => {
    expect(detectInAppKind(UA.igIos)).toBe('instagram');
  });
  it('spots a plain Android WebView', () => {
    expect(detectInAppKind(UA.androidWv)).toBe('webview');
    expect(detectInAppKind(UA.chrome)).toBeNull();
  });
  it('calls an iOS view without Safari a webview only when it is not a home-screen app', () => {
    expect(detectInAppKind(UA.iosWk, { standalone: false })).toBe('webview');
    expect(detectInAppKind(UA.iosWk, { standalone: true })).toBeNull();
    // No probe: unknown, so no change for anyone.
    expect(detectInAppKind(UA.iosWk)).toBeNull();
  });
});

describe('platform helpers', () => {
  it('spots Android and iOS', () => {
    expect(isAndroid(UA.igAndroid)).toBe(true);
    expect(isAndroid(UA.igIos)).toBe(false);
    expect(inAppPlatform(UA.igIos)).toBe('ios');
    expect(inAppPlatform(UA.fbAndroid)).toBe('android');
    expect(inAppPlatform(UA.desktopChrome)).toBe('other');
  });
});

describe('androidOpenInBrowserUrl', () => {
  it('builds an intent URL with a fallback', () => {
    expect(androidOpenInBrowserUrl('https://exos.example/bridge/event/1?ref=ig#tix')).toBe(
      'intent://exos.example/bridge/event/1?ref=ig#Intent;scheme=https;S.browser_fallback_url=' +
        encodeURIComponent('https://exos.example/bridge/event/1?ref=ig#tix') + ';end',
    );
  });
  it('refuses non-https and junk', () => {
    expect(androidOpenInBrowserUrl('http://exos.example/')).toBeNull();
    expect(androidOpenInBrowserUrl('javascript:alert(1)')).toBeNull();
    expect(androidOpenInBrowserUrl('not a url')).toBeNull();
  });
});

describe('iosSafariUrl', () => {
  it('swaps the scheme and keeps path, query and fragment', () => {
    expect(iosSafariUrl('https://exos.example/bridge/event/1?a=b#k=1')).toBe('x-safari-https://exos.example/bridge/event/1?a=b#k=1');
  });
  it('refuses anything but https', () => {
    expect(iosSafariUrl('http://exos.example/')).toBeNull();
    expect(iosSafariUrl('javascript:alert(1)')).toBeNull();
    expect(iosSafariUrl('')).toBeNull();
  });
});

describe('withEscapeMarker', () => {
  it('adds iab_from once', () => {
    expect(withEscapeMarker('https://x.test/e?utm_source=instagram', 'instagram')).toBe('https://x.test/e?utm_source=instagram&iab_from=instagram');
    expect(withEscapeMarker('https://x.test/e?iab_from=facebook', 'instagram')).toBe('https://x.test/e?iab_from=facebook');
  });
  it('leaves junk alone', () => {
    expect(withEscapeMarker('nope', 'instagram')).toBe('nope');
  });
});

const state = (over: Partial<InAppState>): InAppState => ({
  kind: 'instagram', platform: 'ios', storage: { local: true, session: true }, applePay: null, ...over,
});

describe('escapeReasons', () => {
  it('is empty in a real browser, whatever else is true', () => {
    expect(escapeReasons(state({ kind: null, storage: { local: false, session: false } }))).toEqual([]);
  });
  it('iOS in-app: Apple Pay, unless the page can show it', () => {
    expect(escapeReasons(state({}))).toEqual(['apple_pay']);
    expect(escapeReasons(state({ applePay: true }))).toEqual([]);
  });
  it('Android in-app: Google Pay; blocked storage on top', () => {
    expect(escapeReasons(state({ platform: 'android', storage: { local: false, session: true } }))).toEqual(['google_pay', 'storage']);
  });
});

describe('openInBrowserPlan', () => {
  const url = 'https://exos.example/bridge/event/1?utm_source=instagram';
  it('nothing outside in-app browsers', () => {
    expect(openInBrowserPlan(url, { kind: null, platform: 'ios' })).toBeNull();
  });
  it('Android: an intent link carrying the escape marker', () => {
    const p = openInBrowserPlan(url, { kind: 'facebook', platform: 'android' })!;
    expect(p.method).toBe('intent');
    expect(p.url).toBe(url + '&iab_from=facebook');
    expect(p.href).toBe(androidOpenInBrowserUrl(p.url));
    expect(p.steps).toMatch(/Open in external browser/);
  });
  it('iOS: x-safari-https plus the menu steps', () => {
    const p = openInBrowserPlan(url, { kind: 'instagram', platform: 'ios' })!;
    expect(p.method).toBe('x-safari');
    expect(p.href).toBe('x-safari-https://exos.example/bridge/event/1?utm_source=instagram&iab_from=instagram');
    expect(p.steps).toBe(menuSteps('instagram', 'ios'));
  });
  it('a URL it cannot rewrite still gets the steps', () => {
    const p = openInBrowserPlan('http://localhost:4174/bridge/event/1', { kind: 'tiktok', platform: 'ios' })!;
    expect(p.href).toBeNull();
    expect(p.method).toBe('none');
    expect(p.steps).toMatch(/Open in browser/);
  });
});

describe('probes', () => {
  it('storageWorks: false when the getter or a write throws', () => {
    const ok = { setItem: vi.fn(), removeItem: vi.fn() } as unknown as Storage;
    expect(storageWorks(() => ok)).toBe(true);
    expect(storageWorks(() => { throw new DOMException('denied', 'SecurityError'); })).toBe(false);
    expect(storageWorks(() => ({ setItem: () => { throw new Error('quota'); }, removeItem: vi.fn() }) as unknown as Storage)).toBe(false);
    expect(storageWorks(() => null)).toBe(false);
  });
  it('applePayAvailable: null without the API, else what it says', () => {
    expect(applePayAvailable({})).toBeNull();
    expect(applePayAvailable({ ApplePaySession: { canMakePayments: () => true } })).toBe(true);
    expect(applePayAvailable({ ApplePaySession: { canMakePayments: () => false } })).toBe(false);
    expect(applePayAvailable({ ApplePaySession: { canMakePayments: () => { throw new Error('insecure'); } } })).toBe(false);
  });
  it('isStandalone', () => {
    expect(isStandalone({ navigator: { standalone: true } })).toBe(true);
    expect(isStandalone({ navigator: {}, matchMedia: () => ({ matches: true }) })).toBe(true);
    expect(isStandalone({ navigator: {}, matchMedia: () => ({ matches: false }) })).toBe(false);
    expect(isStandalone(undefined)).toBe(false);
  });
  it('readInAppState puts them together', () => {
    const blocked = () => { throw new DOMException('denied', 'SecurityError'); };
    const win = {
      navigator: { userAgent: UA.igIos },
      matchMedia: () => ({ matches: false }),
      get localStorage() { return blocked(); },
      get sessionStorage() { return blocked(); },
    };
    expect(readInAppState(win)).toEqual({ kind: 'instagram', platform: 'ios', storage: { local: false, session: false }, applePay: null });
    expect(readInAppState(undefined).kind).toBeNull();
  });
});

describe('copyText', () => {
  it('uses the clipboard API when it works', async () => {
    const writeText = vi.fn().mockResolvedValue(undefined);
    expect(await copyText('hi', { clipboard: { writeText }, doc: null })).toBe(true);
    expect(writeText).toHaveBeenCalledWith('hi');
  });
  it('falls back to execCommand when the API is refused', async () => {
    const writeText = vi.fn().mockRejectedValue(new Error('NotAllowedError'));
    const execCommand = vi.fn().mockReturnValue(true);
    Object.defineProperty(document, 'execCommand', { value: execCommand, configurable: true });
    expect(await copyText('https://x.test', { clipboard: { writeText } })).toBe(true);
    expect(execCommand).toHaveBeenCalledWith('copy');
    expect(document.querySelector('textarea')).toBeNull();
  });
  it('false when nothing works', async () => {
    expect(await copyText('x', { clipboard: null, doc: null })).toBe(false);
  });
});

describe('inAppRecordFor (exos-checkout)', () => {
  it('the user agent wins', () => {
    expect(inAppRecordFor(UA.igIos, 'none')).toBe('instagram');
    expect(inAppRecordFor(UA.fbAndroid, 'tiktok')).toBe('facebook');
  });
  it('then the page hint, then an Android WebView, else none', () => {
    expect(inAppRecordFor(UA.iosWk, 'webview')).toBe('webview');
    expect(inAppRecordFor(UA.androidWv, undefined)).toBe('webview');
    expect(inAppRecordFor(UA.safari, 'nonsense')).toBe('none');
    expect(inAppRecordFor(null, undefined)).toBe('none');
  });
  it('sanitizers accept the list only', () => {
    expect(sanitizeInAppRecord('none')).toBe('none');
    expect(sanitizeInAppRecord('Instagram')).toBeUndefined();
    expect(sanitizeInAppKind('none')).toBeUndefined();
    expect(sanitizeInAppKind('threads')).toBe('threads');
  });
});
