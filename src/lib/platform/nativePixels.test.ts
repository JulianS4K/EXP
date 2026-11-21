// The native app's build loads no ad pixels, even with consent granted
// (server-side conversions only, docs/native-apps.md). The web build is
// unchanged (src/lib/pixels.test.ts covers it).
import { afterEach, describe, expect, it, vi } from 'vitest';

describe('pixels in the native build', () => {
  let scripts: string[] = [];

  async function load(mode: string) {
    vi.resetModules();
    vi.stubEnv('MODE', mode);
    const store = new Map([['exos.consent.v2', JSON.stringify({ analytics: 'granted', advertising: 'granted' })]]);
    scripts = [];
    vi.stubGlobal('window', { location: { pathname: '/event/ev1', reload: vi.fn() } });
    vi.stubGlobal('document', {
      createElement: () => ({}),
      head: { appendChild: (s: { src: string }) => void scripts.push(s.src) },
    });
    vi.stubGlobal('localStorage', {
      getItem: (k: string) => store.get(k) ?? null,
      setItem: (k: string, v: string) => void store.set(k, v),
      removeItem: (k: string) => void store.delete(k),
    });
    vi.stubGlobal('navigator', {});
    return import('../pixels');
  }

  afterEach(() => {
    vi.unstubAllGlobals();
    vi.unstubAllEnvs();
  });

  it('the web build loads the org pixel once consent is granted', async () => {
    const pixels = await load('production');
    pixels.initOrgPixels('org1', { meta: '123456789012345' });
    expect(scripts).toContain('https://connect.facebook.net/en_US/fbevents.js');
  });

  it('the native build loads none, and reports nothing', async () => {
    const pixels = await load('native');
    pixels.initOrgPixels('org1', { meta: '123456789012345', ga4: 'G-ABC123' });
    pixels.initOrgPixelsForPurchase('org1', { meta: '123456789012345' });
    pixels.trackPixelEvent('Purchase', { value: 10, currency: 'USD' }, 'cs_1');
    expect(scripts).toEqual([]);
    expect(pixels.pixelsLive()).toBe(false);
  });
});
