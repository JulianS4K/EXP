import { afterEach, describe, expect, it, vi } from 'vitest';
import {
  GOOGLE_CONSENT_DEFAULT,
  configuredCategories,
  configuredVendors,
  ga4EventName,
  googleConsent,
  isPixelRoute,
  pixelScopeAction,
  redditEvent,
  snapEvent,
  xEvent,
} from './pixels';

describe('pixelScopeAction', () => {
  it('keeps the same org', () => {
    expect(pixelScopeAction('org-a', 'org-a', true)).toBe('keep');
  });
  it('reloads when another org takes over after pixels loaded', () => {
    expect(pixelScopeAction('org-a', 'org-b', true)).toBe('reload');
  });
  it('reloads when leaving to an untracked page after pixels loaded', () => {
    expect(pixelScopeAction('org-a', null, true)).toBe('reload');
  });
  it('switches without reload while nothing is loaded yet', () => {
    expect(pixelScopeAction('org-a', 'org-b', false)).toBe('switch');
    expect(pixelScopeAction(null, 'org-a', false)).toBe('switch');
  });
  it('does nothing on an untracked page when no org was in scope', () => {
    expect(pixelScopeAction(null, null, false)).toBe('keep');
  });
});

describe('isPixelRoute', () => {
  it.each(['/', '/event/abc', '/e/slug', '/o/brand', '/organizer/x', '/embed/event/1', '/l/brand/dj-kay'])('tracks %s', (p) => {
    expect(isPixelRoute(p)).toBe(true);
  });
  it.each(['/checkin/1', '/ticket/1', '/wallet/pass/1', '/my-tickets', '/dashboard', '/orgs/1/settings', '/transfer/1', '/claim/1', '/profile'])(
    'never tracks %s',
    (p) => {
      expect(isPixelRoute(p)).toBe(false);
    },
  );
});

describe('vendor event mapping', () => {
  const purchase = { content_ids: ['ev1'], content_name: 'Late Night', value: 60, currency: 'USD', num_items: 2 };

  it('maps GA4 names', () => {
    expect(ga4EventName('InitiateCheckout')).toBe('begin_checkout');
    expect(ga4EventName('Purchase')).toBe('purchase');
  });

  it('maps Reddit events with conversionId', () => {
    expect(redditEvent('Purchase', purchase, 'cs_test_1')).toEqual(['Purchase', {
      products: [{ id: 'ev1', category: 'Tickets', name: 'Late Night' }],
      value: 60, currency: 'USD', itemCount: 2, conversionId: 'cs_test_1',
    }]);
    expect(redditEvent('InitiateCheckout', purchase)?.[0]).toBe('AddToCart');
    expect(redditEvent('ViewContent', { content_ids: ['ev1'] })).toEqual(['ViewContent', { products: [{ id: 'ev1', category: 'Tickets' }] }]);
    expect(redditEvent('PageView')).toBeNull();
  });

  it('maps Snap events with client_dedup_id (and transaction_id on PURCHASE)', () => {
    expect(snapEvent('Purchase', purchase, 'cs_test_1')).toEqual(['PURCHASE', {
      item_category: 'tickets', item_ids: ['ev1'], price: 60, currency: 'USD', number_items: 2,
      client_dedup_id: 'cs_test_1', transaction_id: 'cs_test_1',
    }]);
    const start = snapEvent('InitiateCheckout', purchase, 'ic_1');
    expect(start?.[0]).toBe('START_CHECKOUT');
    expect(start?.[1]).toMatchObject({ client_dedup_id: 'ic_1' });
    expect(start?.[1]).not.toHaveProperty('transaction_id');
    expect(snapEvent('ViewContent', { content_ids: ['ev1'] })?.[0]).toBe('VIEW_CONTENT');
  });

  it('maps X events only when the org set that event id, with conversion_id', () => {
    const cfg = { x: 'o8z6j', xPurchase: 'tw-o8z6j-o8z23' };
    expect(xEvent('Purchase', cfg, purchase, 'cs_test_1')).toEqual(['tw-o8z6j-o8z23', {
      value: 60, currency: 'USD',
      contents: [{ content_id: 'ev1', content_type: 'tickets', content_name: 'Late Night', num_items: 2 }],
      conversion_id: 'cs_test_1',
    }]);
    expect(xEvent('ViewContent', cfg, purchase)).toBeNull();
    expect(xEvent('Purchase', { x: 'other', xPurchase: 'tw-o8z6j-o8z23' }, purchase)).toBeNull();
    expect(xEvent('Purchase', { x: 'o8z6j', xPurchase: 'junk' }, purchase)).toBeNull();
  });

  it('builds Consent Mode v2 signals per category', () => {
    expect(googleConsent({ analytics: 'granted', advertising: 'denied' })).toEqual({
      ad_storage: 'denied', ad_user_data: 'denied', ad_personalization: 'denied', analytics_storage: 'granted',
    });
    expect(googleConsent({ analytics: 'unset', advertising: 'granted' })).toEqual({
      ad_storage: 'granted', ad_user_data: 'granted', ad_personalization: 'granted', analytics_storage: 'denied',
    });
    expect(GOOGLE_CONSENT_DEFAULT).toMatchObject({ ad_storage: 'denied', analytics_storage: 'denied', wait_for_update: 500 });
  });

  it('puts GA4 in analytics and every ad pixel in advertising; skips malformed new ids', () => {
    expect(configuredCategories({ ga4: 'G-ABC123' })).toEqual(['analytics']);
    expect(configuredCategories({ meta: '123456789012345', snap: 'bad' })).toEqual(['advertising']);
    expect(configuredVendors({ reddit: 'a2_abc123', snap: 'bad', x: 'o8z6j' })).toEqual(['reddit', 'x']);
    expect(configuredVendors(undefined)).toEqual([]);
  });
});

describe('loading per consent category', () => {
  type Win = Record<string, any>;
  let win: Win;
  let scripts: string[];
  const store = new Map<string, string>();

  async function fresh(consent: { analytics: boolean; advertising: boolean } | null) {
    vi.resetModules();
    store.clear();
    if (consent) {
      store.set('exos.consent.v2', JSON.stringify({
        analytics: consent.analytics ? 'granted' : 'denied',
        advertising: consent.advertising ? 'granted' : 'denied',
      }));
    }
    scripts = [];
    win = { location: { pathname: '/event/ev1', reload: vi.fn() } };
    vi.stubGlobal('window', win);
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
    const pixels = await import('./pixels');
    const consentMod = await import('./consent');
    return { pixels, consentMod };
  }

  const ALL = {
    meta: '123456789012345', ga4: 'G-ABC123', tiktok: 'C4ABCDEFGHIJKLMNOPQR',
    reddit: 'a2_abc123', snap: '1a2b3c4d-5e6f-7a8b-9c0d-1e2f3a4b5c6d', x: 'o8z6j', xPurchase: 'tw-o8z6j-o8z23',
  };
  const gtagCalls = () => (win.dataLayer ?? []).map((a: ArrayLike<unknown>) => Array.from(a));

  afterEach(() => {
    vi.unstubAllGlobals();
  });

  it('loads nothing before a choice, then only the granted category, replaying queued events', async () => {
    const { pixels, consentMod } = await fresh(null);
    pixels.initOrgPixels('org1', ALL);
    pixels.trackPixelEvent('ViewContent', { content_ids: ['ev1'] });
    expect(scripts).toEqual([]);

    consentMod.setConsentChoice({ analytics: true, advertising: false });
    expect(scripts).toEqual(['https://www.googletagmanager.com/gtag/js?id=G-ABC123']);
    expect(win.fbq).toBeUndefined();
    const calls = gtagCalls();
    // Consent Mode default first, then the update, then the tag.
    expect(calls[0]).toEqual(['consent', 'default', { ...pixels.GOOGLE_CONSENT_DEFAULT }]);
    expect(calls[1]).toEqual(['consent', 'update', {
      ad_storage: 'denied', ad_user_data: 'denied', ad_personalization: 'denied', analytics_storage: 'granted',
    }]);
    expect(calls.some((c: unknown[]) => c[0] === 'event' && c[1] === 'viewcontent')).toBe(true);

    consentMod.setConsentChoice({ analytics: true, advertising: true });
    expect(scripts).toEqual(expect.arrayContaining([
      'https://connect.facebook.net/en_US/fbevents.js',
      'https://www.redditstatic.com/ads/pixel.js',
      'https://sc-static.net/scevent.min.js',
      'https://static.ads-twitter.com/uwt.js',
    ]));
    // The queued ViewContent reached the ad pixels once, GA4 not again.
    expect(win.rdt.callQueue.map((a: unknown[]) => Array.from(a))).toEqual([
      ['init', 'a2_abc123'], ['track', 'PageVisit'], ['track', 'ViewContent', { products: [{ id: 'ev1', category: 'Tickets' }] }],
    ]);
    expect(win.snaptr.queue.map((a: unknown[]) => Array.from(a))[1]).toEqual(['track', 'PAGE_VIEW']);
    expect(win.twq.queue.map((a: unknown[]) => Array.from(a))).toEqual([['config', 'o8z6j']]);
    expect(gtagCalls().filter((c: unknown[]) => c[0] === 'event' && c[1] === 'viewcontent')).toHaveLength(1);
    expect(gtagCalls().at(-1)).toEqual(['consent', 'update', {
      ad_storage: 'granted', ad_user_data: 'granted', ad_personalization: 'granted', analytics_storage: 'granted',
    }]);

    pixels.trackPixelEvent('Purchase', { content_ids: ['ev1'], value: 10, currency: 'USD', num_items: 1 }, 'cs_test_1');
    expect(Array.from(win.twq.queue.at(-1))).toEqual(['event', 'tw-o8z6j-o8z23', expect.objectContaining({ conversion_id: 'cs_test_1' })]);
    expect(Array.from(win.snaptr.queue.at(-1))).toEqual(['track', 'PURCHASE', expect.objectContaining({ client_dedup_id: 'cs_test_1' })]);
  });

  it('loads only the ad pixels with advertising consent alone', async () => {
    const { pixels } = await fresh({ analytics: false, advertising: true });
    pixels.initOrgPixels('org1', ALL);
    expect(scripts).not.toContain('https://www.googletagmanager.com/gtag/js?id=G-ABC123');
    expect(win.gtag).toBeUndefined();
    expect(scripts).toContain('https://connect.facebook.net/en_US/fbevents.js');
    expect(pixels.pixelsLive()).toBe(true);
  });

  it('reloads when a loaded category is withdrawn', async () => {
    vi.useFakeTimers();
    try {
      const { pixels, consentMod } = await fresh({ analytics: true, advertising: true });
      pixels.initOrgPixels('org1', { meta: '123456789012345' });
      consentMod.setConsentChoice({ analytics: true, advertising: false });
      expect(pixels.pixelsLive()).toBe(false);
      vi.advanceTimersByTime(1000);
      expect(win.location.reload).toHaveBeenCalled();
    } finally {
      vi.useRealTimers();
    }
  });
});
