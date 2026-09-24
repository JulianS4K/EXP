import { describe, expect, it } from 'vitest';
import { androidOpenInBrowserUrl, detectInAppBrowser, isAndroid } from './inAppBrowser';

const UA = {
  igIos: 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148 Instagram 340.0.2.23.108 (iPhone15,2; iOS 17_5; en_US; en; scale=3.00; 1179x2556; 624443862)',
  igAndroid: 'Mozilla/5.0 (Linux; Android 14; Pixel 8 Build/AP2A; wv) AppleWebKit/537.36 (KHTML, like Gecko) Version/4.0 Chrome/126.0.6478.71 Mobile Safari/537.36 Instagram 338.0.0.40.95 Android',
  fbIos: 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148 [FBAN/FBIOS;FBAV/470.0.0.40.108;FBBV/620000000;FBDV/iPhone15,2;FBMD/iPhone;FBSN/iOS;FBSV/17.5;FBSS/3;FBLC/en_US;FBOP/5]',
  fbAndroid: 'Mozilla/5.0 (Linux; Android 14; SM-S918U Build/UP1A; wv) AppleWebKit/537.36 (KHTML, like Gecko) Version/4.0 Chrome/126.0.6478.71 Mobile Safari/537.36 [FB_IAB/FB4A;FBAV/471.0.0.35.80;]',
  messenger: 'Mozilla/5.0 (Linux; Android 14; wv) AppleWebKit/537.36 (KHTML, like Gecko) Version/4.0 Chrome/126.0 Mobile Safari/537.36 [FB_IAB/MESSENGER;FBAV/460.0.0.49.109;]',
  tiktok: 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148 musical_ly_35.0.0 JsSdk/2.0 NetType/WIFI Channel/App Store ByteLocale/en Region/US',
  safari: 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/604.1',
  chrome: 'Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.6478.71 Mobile Safari/537.36',
};

describe('detectInAppBrowser', () => {
  it.each([
    ['igIos', 'instagram'], ['igAndroid', 'instagram'], ['fbIos', 'facebook'], ['fbAndroid', 'facebook'],
    ['messenger', 'messenger'], ['tiktok', 'tiktok'],
  ] as const)('%s → %s', (k, app) => expect(detectInAppBrowser(UA[k])).toBe(app));

  it('treats real browsers as not in-app', () => {
    expect(detectInAppBrowser(UA.safari)).toBeNull();
    expect(detectInAppBrowser(UA.chrome)).toBeNull();
    expect(detectInAppBrowser('')).toBeNull();
    expect(detectInAppBrowser(undefined)).toBeNull();
  });
});

describe('isAndroid', () => {
  it('spots Android webviews', () => {
    expect(isAndroid(UA.igAndroid)).toBe(true);
    expect(isAndroid(UA.igIos)).toBe(false);
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
