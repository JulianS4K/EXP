// @vitest-environment jsdom
// Platform adapters: the web defaults keep today's browser behaviour; the
// native installer's registrations replace only what they name.
import { afterEach, describe, expect, it, vi } from 'vitest';
import { platform, registerPlatformAdapters, resetPlatformAdapters, WEB_ADAPTERS, webDurableStore } from './adapters';
import { appRouteForUrl, APP_LINK_ROUTES } from './deepLinks';
import { scanDeduper, scanFeedback } from './scanDedupe';
import { checkoutTarget, externalUrl } from './checkoutTarget';

afterEach(() => {
  resetPlatformAdapters();
  vi.restoreAllMocks();
  localStorage.clear();
});

describe('web defaults', () => {
  it('are what a browser page gets', () => {
    expect(platform()).toBe(WEB_ADAPTERS);
    expect(platform().scanner).toBeNull(); // the page's html5-qrcode
    expect(platform().nativeAuth).toBeNull(); // the OAuth redirect
    expect(platform().door).toBeNull();
    expect(platform().storage).toBe(webDurableStore);
  });

  it('walletAdd hands nothing over (WalletButtons keeps its browser path)', async () => {
    const apple = vi.fn(async () => new Blob());
    const google = vi.fn(async () => 'https://pay.google.com/gp/v/save/x');
    expect(await platform().walletAdd.deliver('apple', { apple, google })).toBe(false);
    expect(await platform().walletAdd.deliver('google', { apple, google })).toBe(false);
    expect(apple).not.toHaveBeenCalled();
    expect(google).not.toHaveBeenCalled();
  });

  it('storage is localStorage', async () => {
    expect(await webDurableStore.set('k', 'v')).toBe(true);
    expect(localStorage.getItem('k')).toBe('v');
    expect(await webDurableStore.get('k')).toBe('v');
    await webDurableStore.remove('k');
    expect(await webDurableStore.get('k')).toBeNull();
  });

  it('openExternal opens a new tab', async () => {
    const open = vi.spyOn(window, 'open').mockImplementation(() => null);
    await platform().openExternal('https://pay.example/x');
    expect(open).toHaveBeenCalledWith('https://pay.example/x', '_blank', 'noopener');
  });

  it('openCheckout is the same-tab redirect it always was', async () => {
    const loc = { href: 'https://exos.example/bridge/event/e1' };
    vi.stubGlobal('location', loc);
    try {
      await platform().openCheckout('https://checkout.stripe.com/c/pay/cs_test_1', { returnTo: '/my-tickets' });
      expect(loc.href).toBe('https://checkout.stripe.com/c/pay/cs_test_1');
    } finally {
      vi.unstubAllGlobals();
    }
  });
});

describe('registration', () => {
  it('replaces only what it names, and resets', async () => {
    const deliver = vi.fn(async () => true);
    registerPlatformAdapters({ walletAdd: { deliver } });
    expect(platform().walletAdd.deliver).toBe(deliver);
    expect(platform().storage).toBe(webDurableStore);
    resetPlatformAdapters();
    expect(platform()).toBe(WEB_ADAPTERS);
  });
});

describe('deep links into the app', () => {
  const BASE = 'https://exos-web.onrender.com/bridge';

  it('opens the door routes on the web app host, with the query', () => {
    expect(appRouteForUrl(`${BASE}/door`, BASE)).toBe('/door');
    expect(appRouteForUrl(`${BASE}/checkin/e1?list=l2`, BASE)).toBe('/checkin/e1?list=l2');
    expect(appRouteForUrl(`${BASE}/my-tickets?checkout=success`, BASE)).toBe('/my-tickets?checkout=success');
    // The same host serving the app at its root (after the DNS split).
    expect(appRouteForUrl('https://exos-web.onrender.com/door', BASE)).toBe('/door');
    // A custom domain from VITE_EXOS_APP_LINK_HOSTS, root or /bridge.
    expect(appRouteForUrl('https://door.exos.example/checkin/e1', BASE, ['door.exos.example'])).toBe('/checkin/e1');
    expect(appRouteForUrl('https://door.exos.example/bridge/door', BASE, ['door.exos.example'])).toBe('/door');
  });

  it('ignores everything else', () => {
    expect(appRouteForUrl(`${BASE}/dashboard`, BASE)).toBeNull();
    expect(appRouteForUrl(`${BASE}/doorway`, BASE)).toBeNull();
    expect(appRouteForUrl('https://evil.example/bridge/door', BASE)).toBeNull();
    expect(appRouteForUrl('http://exos-web.onrender.com/bridge/door', BASE)).toBeNull();
    expect(appRouteForUrl('https://u:p@exos-web.onrender.com/bridge/door', BASE)).toBeNull();
    expect(appRouteForUrl('exos://door', BASE)).toBeNull();
    expect(appRouteForUrl('not a url', BASE)).toBeNull();
    expect(appRouteForUrl(`${BASE}/door`, null)).toBeNull();
  });

  it('claims the same routes the association files do', async () => {
    const { readFileSync } = await import('node:fs');
    const { resolve } = await import('node:path');
    const aasa = readFileSync(resolve(__dirname, '../../../apps/native/deep-links/apple-app-site-association.template.json'), 'utf8');
    const manifest = readFileSync(resolve(__dirname, '../../../apps/native/android/app/src/main/AndroidManifest.xml'), 'utf8');
    for (const r of APP_LINK_ROUTES) {
      expect(aasa).toContain(`"/${r.replace(/^\//, '').replace(/\/$/, '')}`);
      expect(manifest).toContain(`android:pathPrefix="${r}"`);
      expect(manifest).toContain(`android:pathPrefix="/bridge${r}"`);
      expect(aasa).toContain(`"/bridge/${r.replace(/^\//, '').replace(/\/$/, '')}`);
    }
  });
});

describe('scan dedupe and feedback', () => {
  it('one read per presentation; the next code passes at once', () => {
    let t = 0;
    const fresh = scanDeduper(2500, () => t);
    expect(fresh('T-a')).toBe(true);
    t = 100;
    expect(fresh('T-a')).toBe(false);
    t = 2000;
    expect(fresh('T-a')).toBe(false); // still in view: the window slides
    t = 4000;
    expect(fresh('T-a')).toBe(false);
    t = 7000;
    expect(fresh('T-a')).toBe(true); // shown again after a pause
    expect(fresh('T-b')).toBe(true);
    expect(fresh('  ')).toBe(false);
  });

  it('maps door statuses to feedback', () => {
    expect(scanFeedback('success')).toBe('success');
    expect(scanFeedback('already-used')).toBe('error');
    expect(scanFeedback('not-found')).toBe('error');
    expect(scanFeedback('invalid-barcode')).toBe('error');
    expect(scanFeedback('needs-reason')).toBe('attention');
    expect(scanFeedback('searching')).toBeNull();
    expect(scanFeedback('idle')).toBeNull();
  });
});

describe('checkout and external targets in the app', () => {
  const BASE = 'https://exos-web.onrender.com/bridge';

  it('opens our own pages in the app and Stripe in the sheet', () => {
    expect(checkoutTarget('/my-tickets?claimed=2', BASE)).toEqual({ kind: 'app', route: '/my-tickets?claimed=2' });
    expect(checkoutTarget(`${BASE}/my-tickets?checkout=success#pt=abc`, BASE)).toEqual({ kind: 'app', route: '/my-tickets?checkout=success#pt=abc' });
    expect(checkoutTarget('https://checkout.stripe.com/c/pay/cs_test_1#fid', BASE)).toEqual({ kind: 'sheet', url: 'https://checkout.stripe.com/c/pay/cs_test_1#fid' });
  });

  it('refuses every other scheme or shape', () => {
    for (const u of ['javascript:alert(1)', 'data:text/html,x', 'http://checkout.stripe.com/x', '//evil.example/x', '/\\evil.example',
      'https://u:p@checkout.stripe.com/', 'https://localhost/x', 'capacitor://localhost/x', `${BASE}//evil.example`, '', 42]) {
      expect(checkoutTarget(u, BASE)).toBeNull();
    }
  });

  it('openExternal: paths resolve on the web app; https only', () => {
    expect(externalUrl('/pay/paypal#c=1', BASE)).toBe(`${BASE}/pay/paypal#c=1`);
    expect(externalUrl(`${BASE}/pay/paypal`, BASE)).toBe(`${BASE}/pay/paypal`);
    expect(externalUrl('javascript:alert(1)', BASE)).toBeNull();
    expect(externalUrl('http://pay.example/', BASE)).toBeNull();
  });
});
