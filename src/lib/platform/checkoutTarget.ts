// Where the native app sends a URL the server handed back for checkout
// (exos-checkout's Stripe URL, or our own page for a free order / a gift card
// that covered it all). Only two kinds are followed: an app-relative path, or
// a page of the public web app, opens in the app; any other https URL opens
// in the browser sheet. Everything else (javascript:, data:, http:, a
// protocol-relative //host, a loopback host) is refused, never navigated to.

export type CheckoutTarget = { kind: 'app'; route: string } | { kind: 'sheet'; url: string };

const SAFE_PATH = /^\/(?!\/)[^\\\u0000-\u001f\u007f]*$/;
const LOOPBACK = /^(localhost|.*\.localhost|127\.\d+\.\d+\.\d+|\[::1\]|0\.0\.0\.0)$/i;

export function checkoutTarget(url: unknown, webBase: string | null): CheckoutTarget | null {
  if (typeof url !== 'string' || url.length > 4096) return null;
  const s = url.trim();
  if (SAFE_PATH.test(s)) return { kind: 'app', route: s };
  if (webBase && s.startsWith(`${webBase}/`)) {
    const route = s.slice(webBase.length);
    return SAFE_PATH.test(route) ? { kind: 'app', route } : null;
  }
  let u: URL;
  try {
    u = new URL(s);
  } catch {
    return null;
  }
  if (u.protocol !== 'https:' || u.username || u.password || LOOPBACK.test(u.hostname)) return null;
  return { kind: 'sheet', url: u.toString() };
}

/** For openExternal: an app path is a page of the web app; only https leaves. */
export function externalUrl(url: string, webBase: string | null): string | null {
  const s = url.trim();
  let u: URL;
  try {
    u = new URL(webBase && SAFE_PATH.test(s) ? `${webBase}${s}` : s);
  } catch {
    return null;
  }
  if (u.protocol !== 'https:' || u.username || u.password || LOOPBACK.test(u.hostname)) return null;
  return u.toString();
}
