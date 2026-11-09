// In-app browsers (Instagram, Facebook, TikTok, ...), where most NYC promoters'
// buyers first land (docs/gtm-nyc.md, roadmap item 7a). What changes there:
//   * Google refuses OAuth inside embedded webviews ("disallowed_useragent"),
//     and Microsoft's flow is unreliable, so those buttons are hidden and email
//     sign-in is offered instead. Apple sign-in and Stripe Checkout both work.
//   * Popups and new tabs are swallowed, so checkout stays a same-tab redirect
//     and PayPal uses its redirect flow, not its popup buttons.
//   * Apple Pay doesn't show on Stripe Checkout inside Instagram / Facebook on
//     iOS, Google Pay rarely does in an Android WebView, and a .pkpass download
//     never reaches Apple Wallet. Buying by card works; for the rest the page
//     offers a way out to the system browser (openInBrowserPlan).
//   * Storage can be blocked (localStorage / sessionStorage throw), so the
//     buying path keeps its state in the URL and on the server.
//
// UA detection is shared with exos-checkout (_shared/inAppBrowser.ts); the
// probes here need a browser. Everything takes its inputs as arguments so it
// tests without a DOM, and nothing changes for a normal browser: every probe
// and link builder answers "not in-app" when unsure.

import {
  detectInAppApp, isAndroidUa, isAndroidWebViewUa, isIosUa, isIosWebViewUa, sanitizeInAppKind,
  type InAppApp, type InAppKind, type InAppRecord,
} from '../../supabase/functions/_shared/inAppBrowser.ts';

export type { InAppApp, InAppKind, InAppRecord };
export { IN_APP_APPS, IN_APP_RECORDS, sanitizeInAppKind, sanitizeInAppRecord } from '../../supabase/functions/_shared/inAppBrowser.ts';

/** The named app's in-app browser, from the user agent alone. */
export function detectInAppBrowser(userAgent: string | undefined | null): InAppApp | null {
  return detectInAppApp(userAgent);
}

export function isAndroid(userAgent: string | undefined | null): boolean {
  return isAndroidUa(userAgent);
}

export type InAppPlatform = 'ios' | 'android' | 'other';

export function inAppPlatform(userAgent: string | undefined | null): InAppPlatform {
  if (isIosUa(userAgent)) return 'ios';
  if (isAndroidUa(userAgent)) return 'android';
  return 'other';
}

/**
 * The in-app kind: a named app, else a generic webview (Android's "wv"
 * marker, or iOS WebKit without "Safari/" that isn't a home-screen web app).
 * `standalone` is the home-screen probe; unknown counts as not a webview.
 */
export function detectInAppKind(userAgent: string | undefined | null, probes: { standalone?: boolean } = {}): InAppKind | null {
  const app = detectInAppApp(userAgent);
  if (app) return app;
  if (isAndroidWebViewUa(userAgent)) return 'webview';
  if (isIosWebViewUa(userAgent) && probes.standalone === false) return 'webview';
  return null;
}

// Android: an intent: URL that asks the OS to open this https URL in the
// default browser, falling back to the same URL if nothing handles it.
export function androidOpenInBrowserUrl(url: string): string | null {
  let u: URL;
  try { u = new URL(url); } catch { return null; }
  if (u.protocol !== 'https:') return null;
  // The fragment can't sit before #Intent; the fallback URL keeps it.
  const rest = `${u.host}${u.pathname}${u.search}`;
  return `intent://${rest}#Intent;scheme=https;S.browser_fallback_url=${encodeURIComponent(url)};end`;
}

// iOS: Safari's x-safari-https: scheme. Some in-app browsers hand it to
// Safari, some ignore it, so the page always shows the menu steps too.
export function iosSafariUrl(url: string): string | null {
  let u: URL;
  try { u = new URL(url); } catch { return null; }
  if (u.protocol !== 'https:') return null;
  return `x-safari-https://${u.host}${u.pathname}${u.search}${u.hash}`;
}

export const IN_APP_LABEL: Record<InAppKind, string> = {
  instagram: 'Instagram',
  facebook: 'Facebook',
  messenger: 'Messenger',
  tiktok: 'TikTok',
  snapchat: 'Snapchat',
  threads: 'Threads',
  linkedin: 'LinkedIn',
  x: 'X',
  webview: 'this app',
};

/** Where the app hides "open in browser", in words. */
export function menuSteps(kind: InAppKind, platform: InAppPlatform): string {
  const browser = platform === 'ios' ? 'Safari' : 'your browser';
  switch (kind) {
    case 'instagram':
    case 'facebook':
      return `Tap ••• at the top right, then "Open in external browser".`;
    case 'tiktok':
      return `Tap ••• at the top right, then "Open in browser".`;
    case 'x':
      return `Tap the share icon or •••, then "Open in ${platform === 'ios' ? 'Safari' : 'browser'}".`;
    case 'webview':
      return `Copy the link and paste it into ${browser}.`;
    default:
      return `Tap ••• in the corner, then "Open in browser".`;
  }
}

/** Does this storage work? Touching it can throw (blocked cookies); a write can too. */
export function storageWorks(get: () => Storage | null | undefined): boolean {
  try {
    const s = get();
    if (!s) return false;
    const k = '__exos_probe__';
    s.setItem(k, '1');
    s.removeItem(k);
    return true;
  } catch {
    return false;
  }
}

/** Apple Pay on this page: true / false, or null where there's no Apple Pay API (not Apple, or an old webview). */
export function applePayAvailable(win: unknown): boolean | null {
  try {
    const session = (win as { ApplePaySession?: { canMakePayments?: () => boolean } } | undefined)?.ApplePaySession;
    if (!session || typeof session.canMakePayments !== 'function') return null;
    return session.canMakePayments() === true;
  } catch {
    return false;
  }
}

/** A home-screen web app (iOS navigator.standalone, or display-mode standalone). */
export function isStandalone(win: unknown): boolean {
  try {
    const w = win as { navigator?: { standalone?: boolean }; matchMedia?: (q: string) => { matches: boolean } } | undefined;
    if (w?.navigator?.standalone === true) return true;
    return typeof w?.matchMedia === 'function' && w.matchMedia('(display-mode: standalone)').matches;
  } catch {
    return false;
  }
}

export interface InAppState {
  kind: InAppKind | null;
  platform: InAppPlatform;
  /** localStorage / sessionStorage usable (false: blocked). */
  storage: { local: boolean; session: boolean };
  /** Apple Pay can show on this page (null: no Apple Pay API here). */
  applePay: boolean | null;
}

const NOT_IN_APP: InAppState = { kind: null, platform: 'other', storage: { local: true, session: true }, applePay: null };

/** Read the page's state. `win` is the window (tests pass a stand-in). */
export function readInAppState(win: unknown): InAppState {
  const w = win as (Window & typeof globalThis) | undefined;
  if (!w || !w.navigator) return NOT_IN_APP;
  const ua = w.navigator.userAgent;
  return {
    kind: detectInAppKind(ua, { standalone: isStandalone(w) }),
    platform: inAppPlatform(ua),
    storage: { local: storageWorks(() => w.localStorage), session: storageWorks(() => w.sessionStorage) },
    applePay: applePayAvailable(w),
  };
}

let cached: InAppState | null = null;
/** This page's state, read once (SSR / no window: not in-app). */
export function currentInAppState(): InAppState {
  if (typeof window === 'undefined') return NOT_IN_APP;
  cached ??= readInAppState(window);
  return cached;
}
/** For tests: forget the cached state. */
export function resetInAppStateCache(): void { cached = null; }

// The current page's in-app kind, or null in a normal browser / SSR.
export function currentInAppBrowser(): InAppKind | null {
  return currentInAppState().kind;
}

/** What a checkout started on this page sends exos-checkout as its hint. */
export function currentInAppRecord(): InAppRecord {
  return currentInAppState().kind ?? 'none';
}

export type EscapeReason = 'apple_pay' | 'google_pay' | 'wallet' | 'storage';

/** Why this page would be better in the system browser. Empty outside in-app browsers. */
export function escapeReasons(state: InAppState): EscapeReason[] {
  if (!state.kind) return [];
  const out: EscapeReason[] = [];
  if (state.platform === 'ios' && state.applePay !== true) out.push('apple_pay');
  if (state.platform === 'android') out.push('google_pay');
  if (!state.storage.local || !state.storage.session) out.push('storage');
  return out;
}

export interface EscapePlan {
  /** A link that may open the system browser directly (intent: / x-safari-https:), or null. */
  href: string | null;
  method: 'intent' | 'x-safari' | 'none';
  /** The app's own menu path, always shown (the link may be ignored). */
  steps: string;
  /** The plain https URL to copy. */
  url: string;
}

/** How to get from this in-app browser to the system one, for `url`. */
export function openInBrowserPlan(url: string, state: Pick<InAppState, 'kind' | 'platform'>): EscapePlan | null {
  if (!state.kind) return null;
  const marked = withEscapeMarker(url, state.kind);
  const steps = menuSteps(state.kind, state.platform);
  if (state.platform === 'android') {
    const href = androidOpenInBrowserUrl(marked);
    return { href, method: href ? 'intent' : 'none', steps, url: marked };
  }
  if (state.platform === 'ios') {
    const href = iosSafariUrl(marked);
    return { href, method: href ? 'x-safari' : 'none', steps, url: marked };
  }
  return { href: null, method: 'none', steps, url: marked };
}

/**
 * Tag a URL with the in-app browser it's leaving (?iab_from=instagram), so a
 * sale finished in the system browser still counts as Instagram traffic
 * (attribution.iab_from, _shared/attribution.ts).
 */
export function withEscapeMarker(url: string, kind: InAppKind): string {
  let u: URL;
  try { u = new URL(url); } catch { return url; }
  if (!u.searchParams.has('iab_from') && sanitizeInAppKind(kind)) u.searchParams.set('iab_from', kind);
  return u.toString();
}

interface ClipboardDeps {
  clipboard?: { writeText(text: string): Promise<void> } | null;
  doc?: Document | null;
}

/**
 * Copy text. The async clipboard API is often missing or refused in in-app
 * browsers; a selected, off-screen textarea plus execCommand('copy') still
 * works in most of them. False when both fail (show the link to copy by hand).
 */
export async function copyText(text: string, deps: ClipboardDeps = {}): Promise<boolean> {
  const clipboard = deps.clipboard !== undefined ? deps.clipboard
    : (typeof navigator !== 'undefined' ? navigator.clipboard : null);
  try {
    if (clipboard && typeof clipboard.writeText === 'function') {
      await clipboard.writeText(text);
      return true;
    }
  } catch { /* refused: try the old way */ }
  const doc = deps.doc !== undefined ? deps.doc : (typeof document !== 'undefined' ? document : null);
  if (!doc?.body) return false;
  const ta = doc.createElement('textarea');
  ta.value = text;
  ta.setAttribute('readonly', '');
  ta.style.position = 'fixed';
  ta.style.top = '-1000px';
  ta.style.opacity = '0';
  doc.body.appendChild(ta);
  try {
    ta.select();
    ta.setSelectionRange(0, text.length);
    return doc.execCommand('copy') === true;
  } catch {
    return false;
  } finally {
    ta.remove();
  }
}
