// Per-path security headers for the Exos SPA under /bridge/*.
//
// Ported from Terminal-2's server.py (SecurityHeadersMiddleware._bridge_csp),
// which served /bridge until Exos got its own host. Terminal-2 now reverse-
// proxies /bridge/* here and keeps any header we set (it only fills in
// missing ones), so this module is the single source of truth.
//
// Why the policy varies by page:
//   • Marketing pixels (Meta / GA4 / TikTok) only load on public listing
//     pages, behind the organizer's consent gate (src/lib/pixels.ts
//     isPixelRoute mirrors PIXEL_PREFIXES).
//   • The Google Maps JS API only loads where a map renders.
//   • The embed is meant to be framed by any venue's site; nothing else is.
//   • The door scanner needs the camera, so /bridge allows camera=(self).

const PIXEL_SCRIPT = ' https://connect.facebook.net https://www.googletagmanager.com https://analytics.tiktok.com';
const PIXEL_CONNECT =
  ' https://www.facebook.com https://*.google-analytics.com https://*.analytics.google.com' +
  ' https://www.googletagmanager.com https://analytics.tiktok.com';
const PIXEL_PREFIXES = ['/bridge/event/', '/bridge/e/', '/bridge/o/', '/bridge/organizer/', '/bridge/embed/event/'];

const MAPS_SCRIPT =
  ' https://*.googleapis.com https://*.gstatic.com https://*.google.com https://*.ggpht.com https://*.googleusercontent.com blob:';
const MAPS_CONNECT = ' https://*.googleapis.com https://*.google.com https://*.gstatic.com data: blob:';
const MAPS_PREFIXES = ['/bridge/event/', '/bridge/map'];

const startsWithAny = (path: string, prefixes: string[]) => prefixes.some((p) => path.startsWith(p));

export const isBridgePath = (path: string) => path === '/bridge' || path.startsWith('/bridge/');
export const isEmbedPath = (path: string) => path.startsWith('/bridge/embed/');

export function bridgeCsp(path: string): string {
  const pixels = path === '/bridge' || path === '/bridge/' || startsWithAny(path, PIXEL_PREFIXES);
  const maps = startsWithAny(path, MAPS_PREFIXES);
  const embed = isEmbedPath(path);
  return (
    "default-src 'self'; " +
    "script-src 'self' https://js.stripe.com" +
    (pixels ? PIXEL_SCRIPT : '') +
    (maps ? MAPS_SCRIPT : '') +
    '; ' +
    "style-src 'self' 'unsafe-inline' https://fonts.googleapis.com; " +
    "font-src 'self' https://fonts.gstatic.com; " +
    "img-src 'self' data: blob: https:; " +
    // checkout.stripe.com: Stripe Embedded Checkout (the /bridge/embed buy flow).
    "connect-src 'self' https://*.supabase.co wss://*.supabase.co https://api.stripe.com https://checkout.stripe.com" +
    (pixels ? PIXEL_CONNECT : '') +
    (maps ? MAPS_CONNECT : '') +
    '; ' +
    'frame-src https://js.stripe.com https://hooks.stripe.com https://checkout.stripe.com https://www.google.com; ' +
    (maps ? "worker-src 'self' blob:; " : "worker-src 'self'; ") +
    "manifest-src 'self'; " +
    (embed ? 'frame-ancestors *; ' : "frame-ancestors 'none'; ") +
    "base-uri 'self'; " +
    "form-action 'self'"
  );
}

/**
 * Headers for a response on `path`. /bridge pages get the page-specific CSP
 * and camera access; everything else (healthz, robots) gets the strict
 * defaults. X-Frame-Options can't say "any origin", so the embed relies on
 * frame-ancestors alone.
 */
export function securityHeaders(path: string, opts: { hsts: boolean }): Record<string, string> {
  const bridge = isBridgePath(path);
  const h: Record<string, string> = {
    'X-Content-Type-Options': 'nosniff',
    'Referrer-Policy': 'strict-origin-when-cross-origin',
    'Permissions-Policy': bridge ? 'geolocation=(), microphone=(), camera=(self)' : 'geolocation=(), microphone=(), camera=()',
    'Content-Security-Policy': bridge ? bridgeCsp(path) : "default-src 'none'; frame-ancestors 'none'",
  };
  if (!isEmbedPath(path)) h['X-Frame-Options'] = 'DENY';
  if (opts.hsts) h['Strict-Transport-Security'] = 'max-age=63072000; includeSubDomains';
  return h;
}
