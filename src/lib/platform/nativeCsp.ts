// The Content-Security-Policy of the native app's bundle (vite --mode native
// puts it in index.html as a <meta http-equiv>; the app's local server sends
// no headers). As tight as the app allows, so an XSS in the web view reaches
// as little as possible, the native plugins included:
//   * scripts: our own files and Google Maps only. No inline script (Capacitor
//     adds its bridge as a document-start script, outside the CSP; very old
//     Android WebViews without that feature fall back to an inline injection,
//     which this blocks, and the app then runs with the web defaults), no
//     Stripe.js, no pixels, no PayPal, no Turnstile (each runs in the browser
//     sheet instead, docs/native-apps.md).
//   * network: this project's Supabase (https + realtime wss), the public web
//     app's origin, Sentry, Maps.
//   * frames: the event page's YouTube / Vimeo video only.
// Mirrors the web policy's choices (src/lib/hosting/headers.ts bridgeCsp).

export interface NativeCspInput {
  /** VITE_SUPABASE_URL. */
  supabaseUrl?: string;
  /** VITE_EXOS_WEB_URL (only its origin is used). */
  webUrl?: string;
}

const MAPS_SCRIPT = 'https://*.googleapis.com https://*.gstatic.com https://*.google.com https://*.ggpht.com https://*.googleusercontent.com';
const MAPS_CONNECT = 'https://*.googleapis.com https://*.google.com https://*.gstatic.com';

function httpsOrigin(raw: string | undefined): string | null {
  try {
    const u = new URL((raw ?? '').trim());
    return u.protocol === 'https:' && !u.username && !u.password ? u.origin : null;
  } catch {
    return null;
  }
}

export function nativeCsp(input: NativeCspInput): string {
  const supabase = httpsOrigin(input.supabaseUrl);
  const web = httpsOrigin(input.webUrl);
  const connect = ["'self'"];
  if (supabase) connect.push(supabase, supabase.replace(/^https:/, 'wss:'));
  if (web && web !== supabase) connect.push(web);
  connect.push('https://*.sentry.io', MAPS_CONNECT, 'data:', 'blob:');
  return [
    "default-src 'self'",
    // blob: for Maps' own generated scripts, as on the web (headers.ts MAPS_SCRIPT).
    `script-src 'self' ${MAPS_SCRIPT} blob:`,
    "style-src 'self' 'unsafe-inline' https://fonts.googleapis.com",
    "font-src 'self' https://fonts.gstatic.com",
    "img-src 'self' data: blob: https:",
    `connect-src ${connect.join(' ')}`,
    'frame-src https://www.youtube-nocookie.com https://player.vimeo.com',
    "worker-src 'self' blob:",
    "manifest-src 'self'",
    "media-src 'self' blob: https:",
    "object-src 'none'",
    "base-uri 'self'",
    "form-action 'self'",
  ].join('; ');
}
