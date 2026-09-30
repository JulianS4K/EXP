import { describe, it, expect } from 'vitest';
import { bridgeCsp, isBridgePath, securityHeaders } from './headers';

describe('bridgeCsp', () => {
  it('allows pixels only on public listing pages', () => {
    expect(bridgeCsp('/bridge/')).toContain('connect.facebook.net');
    expect(bridgeCsp('/bridge/o/nights')).toContain('analytics.tiktok.com');
    expect(bridgeCsp('/bridge/checkin/abc')).not.toContain('connect.facebook.net');
    expect(bridgeCsp('/bridge/my-tickets')).not.toContain('googletagmanager');
    expect(bridgeCsp('/bridge/l/bk-nights/dj-kay')).toContain('connect.facebook.net');
  });

  it('allows the Reddit, Snap and X pixels wherever the other pixels load', () => {
    const vendorHosts = [
      'https://www.redditstatic.com', 'https://alb.reddit.com', 'https://pixel-config.reddit.com',
      'https://sc-static.net', 'https://tr.snapchat.com',
      'https://static.ads-twitter.com', 'https://analytics.twitter.com', 'https://t.co',
    ];
    const pages: [string, string?][] = [
      ['/bridge/event/1'], ['/bridge/l/bk-nights/dj-kay'],
      ['/bridge/my-tickets', '?checkout=success&session_id=cs_test_a1B2c3D4e5'],
    ];
    for (const [path, search] of pages) {
      const csp = bridgeCsp(path, search);
      for (const h of vendorHosts) expect(csp).toContain(h);
      // Loaders are scripts; event endpoints are connect-only.
      expect(csp.split('; ').find((d) => d.startsWith('script-src'))).toContain('https://sc-static.net');
      expect(csp.split('; ').find((d) => d.startsWith('script-src'))).not.toContain('https://tr.snapchat.com');
    }
    for (const path of ['/bridge/checkin/abc', '/bridge/my-tickets', '/bridge/dashboard']) {
      for (const h of vendorHosts) expect(bridgeCsp(path)).not.toContain(h);
    }
  });

  it('allows pixels on the Stripe return so the paid Purchase fires', () => {
    expect(bridgeCsp('/bridge/my-tickets', '?checkout=success&session_id=cs_test_a1B2c3D4e5')).toContain('connect.facebook.net');
    expect(bridgeCsp('/bridge/my-tickets', '?checkout=success&guest=1&session_id=cs_live_a1B2c3D4e5')).toContain('analytics.tiktok.com');
    // Not without a Stripe session id, and not on any other page.
    expect(bridgeCsp('/bridge/my-tickets', '?checkout=success')).not.toContain('connect.facebook.net');
    expect(bridgeCsp('/bridge/my-tickets', '?session_id=cs_test_a1B2c3D4e5')).not.toContain('connect.facebook.net');
    expect(bridgeCsp('/bridge/dashboard', '?checkout=success&session_id=cs_test_a1B2c3D4e5')).not.toContain('connect.facebook.net');
  });

  it('allows Google Maps only where a map renders', () => {
    expect(bridgeCsp('/bridge/map')).toContain('*.googleapis.com');
    expect(bridgeCsp('/bridge/map')).toContain("worker-src 'self' blob:");
    expect(bridgeCsp('/bridge/dashboard')).not.toContain('*.googleapis.com');
    expect(bridgeCsp('/bridge/dashboard')).toContain("worker-src 'self';");
  });

  it('frames the organizer video only on the event page, privacy-enhanced hosts only', () => {
    for (const path of ['/bridge/event/1', '/bridge/e/late-night']) {
      expect(bridgeCsp(path)).toContain('frame-src https://js.stripe.com https://hooks.stripe.com https://checkout.stripe.com https://www.google.com https://www.youtube-nocookie.com https://player.vimeo.com;');
    }
    for (const path of ['/bridge/', '/bridge/dashboard', '/bridge/embed/event/1', '/bridge/o/nights']) {
      expect(bridgeCsp(path)).not.toContain('youtube-nocookie');
      expect(bridgeCsp(path)).not.toContain('player.vimeo.com');
    }
    expect(bridgeCsp('/bridge/event/1')).not.toContain('https://www.youtube.com');
  });

  it('lets only the embed be framed', () => {
    expect(bridgeCsp('/bridge/embed/event/1')).toContain('frame-ancestors *;');
    expect(bridgeCsp('/bridge/event/1')).toContain("frame-ancestors 'none';");
  });

  it('always allows Stripe, Supabase realtime and fonts', () => {
    const csp = bridgeCsp('/bridge/checkout');
    for (const s of ['https://js.stripe.com', 'wss://*.supabase.co', 'https://fonts.gstatic.com', 'https://checkout.stripe.com']) {
      expect(csp).toContain(s);
    }
  });
});

describe('securityHeaders', () => {
  it('gives /bridge the camera (door scanner) and denies framing except the embed', () => {
    const page = securityHeaders('/bridge/checkin/e1', { hsts: true });
    expect(page['Permissions-Policy']).toContain('camera=(self)');
    expect(page['X-Frame-Options']).toBe('DENY');
    expect(page['Strict-Transport-Security']).toContain('max-age=');
    const embed = securityHeaders('/bridge/embed/event/e1', { hsts: false });
    expect(embed['X-Frame-Options']).toBeUndefined();
    expect(embed['Strict-Transport-Security']).toBeUndefined();
  });

  it('keeps non-app paths locked down', () => {
    const h = securityHeaders('/healthz', { hsts: false });
    expect(h['Permissions-Policy']).toContain('camera=()');
    expect(h['Content-Security-Policy']).toBe("default-src 'none'; frame-ancestors 'none'");
  });

  it('recognises bridge paths', () => {
    expect(isBridgePath('/bridge')).toBe(true);
    expect(isBridgePath('/bridge/x')).toBe(true);
    expect(isBridgePath('/bridgework')).toBe(false);
  });
});
