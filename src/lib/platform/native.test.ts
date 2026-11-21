// @vitest-environment jsdom
// The native app (apps/native, docs/native-apps.md): detection, the native
// build's flags, and the public links it builds.
import { afterEach, describe, expect, it, vi } from 'vitest';
import { appUaVersion, detectNativeApp, isNativeBuild, nativeBuildFlags, nativeWebBase } from './native';
import { readInAppState } from '../inAppBrowser';
import { appBaseUrl, authUrl, callbackUrl } from '../authUrls';

// Our own app's web views: Capacitor appends ExosApp/1 (capacitor.config.ts).
const APP_IOS = 'Mozilla/5.0 (iPhone; CPU iPhone OS 18_1 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148 ExosApp/1';
const APP_ANDROID = 'Mozilla/5.0 (Linux; Android 15; Pixel 9 Build/AP3A; wv) AppleWebKit/537.36 (KHTML, like Gecko) Version/4.0 Chrome/131.0.6778.39 Mobile Safari/537.36 ExosApp/1';
// The same web views without the token (someone else's app).
const WV_IOS = 'Mozilla/5.0 (iPhone; CPU iPhone OS 18_1 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148';
const WV_ANDROID = 'Mozilla/5.0 (Linux; Android 15; Pixel 9 Build/AP3A; wv) AppleWebKit/537.36 (KHTML, like Gecko) Version/4.0 Chrome/131.0.6778.39 Mobile Safari/537.36';
const SAFARI = 'Mozilla/5.0 (iPhone; CPU iPhone OS 18_1 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.1 Mobile/15E148 Safari/604.1';
const IG_IOS = 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148 Instagram 340.0.2.23.108 (iPhone15,2; iOS 17_5; en_US; en; scale=3.00; 1179x2556; 624443862)';

afterEach(() => vi.unstubAllEnvs());

const win = (ua: string, extra: Record<string, unknown> = {}) => ({ navigator: { userAgent: ua }, ...extra });
const bridge = { version: 1, canShare: async () => true, share: async () => 'shared' };

describe('detectNativeApp', () => {
  it('knows the app by its UA token', () => {
    expect(appUaVersion(APP_IOS)).toBe(1);
    expect(detectNativeApp(win(APP_IOS))).toEqual({ platform: 'ios' });
    expect(detectNativeApp(win(APP_ANDROID))).toEqual({ platform: 'android' });
  });

  it("knows it by Capacitor's own answer", () => {
    const cap = { isNativePlatform: () => true, getPlatform: () => 'android' };
    expect(detectNativeApp(win(WV_ANDROID, { Capacitor: cap }))).toEqual({ platform: 'android' });
    // Capacitor in a browser (the www/ bundle opened for debugging) is not the app.
    const web = { isNativePlatform: () => false, getPlatform: () => 'web' };
    expect(detectNativeApp(win(SAFARI, { Capacitor: web }))).toBeNull();
  });

  it('knows it by the ExosNative share bridge', () => {
    expect(detectNativeApp(win(WV_IOS, { ExosNative: bridge }))).toEqual({ platform: 'ios' });
    expect(detectNativeApp(win(WV_IOS, { ExosNative: { version: 2 } }))).toBeNull();
  });

  it('says no for browsers, in-app browsers and odd globals', () => {
    for (const ua of [SAFARI, IG_IOS, WV_IOS, WV_ANDROID, '']) expect(detectNativeApp(win(ua))).toBeNull();
    expect(detectNativeApp(undefined)).toBeNull();
    const broken = { isNativePlatform: () => { throw new Error('x'); } };
    expect(detectNativeApp(win(SAFARI, { Capacitor: broken }))).toBeNull();
    // A desktop UA can't claim the app with the token alone.
    expect(detectNativeApp(win('Mozilla/5.0 (X11; Linux x86_64) ExosApp/1'))).toBeNull();
  });
});

describe('the app is not an in-app browser', () => {
  const storage = () => ({ setItem() {}, removeItem() {} });
  const state = (ua: string, extra: Record<string, unknown> = {}) =>
    readInAppState({ navigator: { userAgent: ua }, localStorage: storage(), sessionStorage: storage(), matchMedia: () => ({ matches: false }), ...extra });

  it('a bare web view still is one (Google hidden, open-in-browser banners)', () => {
    expect(state(WV_IOS).kind).toBe('webview');
    expect(state(WV_ANDROID).kind).toBe('webview');
  });

  it('our app is not, on either platform', () => {
    expect(state(APP_IOS)).toMatchObject({ kind: null, platform: 'ios' });
    expect(state(APP_ANDROID)).toMatchObject({ kind: null, platform: 'android' });
    expect(state(WV_ANDROID, { Capacitor: { isNativePlatform: () => true, getPlatform: () => 'android' } }).kind).toBeNull();
  });
});

describe('native build flags', () => {
  it('the web build keeps everything', () => {
    expect(nativeBuildFlags({ MODE: 'production' })).toEqual({ native: false, serviceWorker: true, pixels: true, groupChat: true, stripeJs: true });
    expect(isNativeBuild({ MODE: 'test' })).toBe(false);
  });

  it('the native build: no service worker, no pixels, no group chat, no Stripe.js', () => {
    expect(nativeBuildFlags({ MODE: 'native' })).toEqual({ native: true, serviceWorker: false, pixels: false, groupChat: false, stripeJs: false });
  });

  it('reads the real build mode by default', () => {
    expect(isNativeBuild()).toBe(false);
    vi.stubEnv('MODE', 'native');
    expect(isNativeBuild()).toBe(true);
  });

  it('the native build refuses Stripe.js (no card field in the app, docs/pci.md)', async () => {
    vi.stubEnv('MODE', 'native');
    const { getStripe } = await import('../stripe');
    await expect(getStripe()).rejects.toThrow(/hosted Checkout/);
  });
});

describe('links out of the app', () => {
  const NATIVE = { MODE: 'native', VITE_EXOS_WEB_URL: 'https://exos-web.onrender.com/bridge/', BASE_URL: '/' };

  it('nativeWebBase: https only, native build only', () => {
    expect(nativeWebBase(NATIVE)).toBe('https://exos-web.onrender.com/bridge');
    expect(nativeWebBase({ ...NATIVE, MODE: 'production' })).toBeNull();
    expect(nativeWebBase({ ...NATIVE, VITE_EXOS_WEB_URL: 'http://exos-web.onrender.com/bridge' })).toBeNull();
    expect(nativeWebBase({ ...NATIVE, VITE_EXOS_WEB_URL: 'https://u:p@exos.example' })).toBeNull();
    expect(nativeWebBase({ ...NATIVE, VITE_EXOS_WEB_URL: 'not a url' })).toBeNull();
    expect(nativeWebBase({ ...NATIVE, VITE_EXOS_WEB_URL: 'https://door.exos.example' })).toBe('https://door.exos.example');
  });

  it("auth mails and redirects go to the web app, never capacitor://localhost", () => {
    expect(appBaseUrl({ env: NATIVE })).toBe('https://exos-web.onrender.com/bridge');
    expect(authUrl('/reset-password', { env: NATIVE })).toBe('https://exos-web.onrender.com/bridge/reset-password');
    expect(callbackUrl('/door', { env: NATIVE })).toBe('https://exos-web.onrender.com/bridge/auth/callback?next=%2Fdoor');
    // The web build is unchanged: the page's own origin.
    expect(appBaseUrl({ origin: 'https://exos-web.onrender.com', env: { BASE_URL: '/bridge/' } })).toBe('https://exos-web.onrender.com/bridge');
  });

  it('publicUrl (Stripe success / cancel, shares) uses the web app in the native build', async () => {
    const { publicUrl } = await import('../utils');
    expect(publicUrl('my-tickets').startsWith(window.location.origin)).toBe(true);
    vi.stubEnv('MODE', 'native');
    vi.stubEnv('VITE_EXOS_WEB_URL', 'https://exos-web.onrender.com/bridge');
    expect(publicUrl('my-tickets?checkout=success')).toBe('https://exos-web.onrender.com/bridge/my-tickets?checkout=success');
    expect(publicUrl('/event/e1')).toBe('https://exos-web.onrender.com/bridge/event/e1');
  });
});
