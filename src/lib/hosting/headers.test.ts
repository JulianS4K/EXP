import { describe, it, expect } from 'vitest';
import { bridgeCsp, isBridgePath, securityHeaders } from './headers';

describe('bridgeCsp', () => {
  it('allows pixels only on public listing pages', () => {
    expect(bridgeCsp('/bridge/')).toContain('connect.facebook.net');
    expect(bridgeCsp('/bridge/o/nights')).toContain('analytics.tiktok.com');
    expect(bridgeCsp('/bridge/checkin/abc')).not.toContain('connect.facebook.net');
    expect(bridgeCsp('/bridge/my-tickets')).not.toContain('googletagmanager');
  });

  it('allows Google Maps only where a map renders', () => {
    expect(bridgeCsp('/bridge/map')).toContain('*.googleapis.com');
    expect(bridgeCsp('/bridge/map')).toContain("worker-src 'self' blob:");
    expect(bridgeCsp('/bridge/dashboard')).not.toContain('*.googleapis.com');
    expect(bridgeCsp('/bridge/dashboard')).toContain("worker-src 'self';");
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
