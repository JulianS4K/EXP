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
//   * frames: the venue's Maps embed and the event page's YouTube / Vimeo
//     video only.
// Mirrors the web policy's choices (src/lib/hosting/headers.ts bridgeCsp).

export interface NativeCspInput {
  /** VITE_SUPABASE_URL. */
  supabaseUrl?: string;
  /** VITE_EXOS_WEB_URL (only its origin is used). */
  webUrl?: string;
}

// Only the Maps JavaScript API's own two hosts: a wildcard would also allow
// storage.googleapis.com / *.googleusercontent.com (anyone's uploaded .js) and
// *.google.com (JSONP endpoints). Maps' tiles and photos load as images
// (img-src https:), and its generated workers as blob: (worker-src).
const MAPS_SCRIPT = 'https://maps.googleapis.com https://maps.gstatic.com';
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
    `script-src 'self' ${MAPS_SCRIPT}`,
    "style-src 'self' 'unsafe-inline' https://fonts.googleapis.com",
    "font-src 'self' https://fonts.gstatic.com",
    "img-src 'self' data: blob: https:",
    `connect-src ${connect.join(' ')}`,
    // The venue map (VenueMap.tsx: www.google.com/maps/embed) and the event video.
    'frame-src https://www.google.com https://www.youtube-nocookie.com https://player.vimeo.com',
    "worker-src 'self' blob:",
    "manifest-src 'self'",
    "media-src 'self' blob: https:",
    "object-src 'none'",
    "base-uri 'self'",
    "form-action 'self'",
  ].join('; ');
}
