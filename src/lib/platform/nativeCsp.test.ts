// The native bundle's CSP (index.html <meta>, vite --mode native).
import { describe, expect, it } from 'vitest';
import { nativeCsp } from './nativeCsp';

const directive = (csp: string, name: string) => csp.split('; ').find((d) => d.startsWith(`${name} `)) ?? '';

describe('nativeCsp', () => {
  const csp = nativeCsp({ supabaseUrl: 'https://abc.supabase.co', webUrl: 'https://exos-web.onrender.com/bridge' });

  it('runs our own scripts and Maps only: no inline script, Stripe, pixels, PayPal or Turnstile', () => {
    const script = directive(csp, 'script-src');
    expect(script.startsWith("script-src 'self' ")).toBe(true);
    for (const banned of ["'unsafe-inline'", "'unsafe-eval'", 'stripe', 'facebook', 'googletagmanager', 'paypal', 'cloudflare', '*;', ' * ']) {
      expect(script).not.toContain(banned);
    }
    expect(csp).not.toContain('stripe.com');
    expect(directive(csp, 'object-src')).toBe("object-src 'none'");
    expect(directive(csp, 'base-uri')).toBe("base-uri 'self'");
  });

  it("connects to this project's Supabase (https + wss) and the web app's origin, not every Supabase project", () => {
    const connect = directive(csp, 'connect-src');
    expect(connect).toContain('https://abc.supabase.co');
    expect(connect).toContain('wss://abc.supabase.co');
    expect(connect).toContain('https://exos-web.onrender.com');
    expect(connect).not.toContain('*.supabase.co');
    expect(connect).not.toContain('/bridge');
  });

  it('frames the venue map and the event video only', () => {
    expect(directive(csp, 'frame-src')).toBe('frame-src https://www.google.com https://www.youtube-nocookie.com https://player.vimeo.com');
  });

  it('allows the Maps script hosts only: no wildcard Google host, no blob: script', () => {
    const script = directive(csp, 'script-src');
    expect(script).toBe("script-src 'self' https://maps.googleapis.com https://maps.gstatic.com");
    for (const banned of ['*.googleapis.com', '*.googleusercontent.com', '*.google.com', '*.gstatic.com', 'storage.googleapis.com', 'blob:', 'data:']) {
      expect(script).not.toContain(banned);
    }
    expect(directive(csp, 'worker-src')).toBe("worker-src 'self' blob:");
    expect(directive(csp, 'img-src')).toContain('https:');
  });

  it('drops a URL that is not plain https', () => {
    const bad = nativeCsp({ supabaseUrl: 'http://abc.supabase.co', webUrl: 'https://u:p@exos.example' });
    expect(directive(bad, 'connect-src')).not.toMatch(/abc\.supabase\.co|exos\.example/);
  });
});
