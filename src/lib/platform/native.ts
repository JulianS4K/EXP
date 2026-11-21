// Is this page running inside the Exos native app (the Capacitor shell in
// apps/native, docs/native-apps.md)? And was this bundle built for it?
//
// Two different questions:
//   * RUNTIME: the app's web view. Its user agent looks like an in-app
//     browser (iOS WKWebView has no "Safari/", Android's has "; wv)"), so
//     lib/inAppBrowser would hide Google sign-in and the Wallet buttons and
//     show "open in your browser" banners. Inside our own app none of that is
//     right. Any one of these marks it: Capacitor's isNativePlatform(), the
//     UA token the shell appends (ExosApp/1, capacitor.config.ts), or the
//     window.ExosNative bridge (lib/nativeShare.ts).
//   * BUILD: `vite build --mode native` (the bundle the app ships). It has no
//     service worker, no ad pixels and no group chat, and its links point at
//     the public web app (VITE_EXOS_WEB_URL), not at capacitor://localhost.
//
// Everything takes its inputs as arguments so it tests without a DOM. A
// normal browser answers "not native" everywhere.

import { getNativeBridge } from '../nativeShare';

export type NativePlatform = 'ios' | 'android';

/** The token apps/native/capacitor.config.ts appends to the user agent. */
export const APP_UA_TOKEN = 'ExosApp';
const APP_UA_RE = /\bExosApp\/(\d+)\b/;

interface CapacitorLike {
  isNativePlatform?: () => boolean;
  getPlatform?: () => string;
}

interface WinLike {
  Capacitor?: CapacitorLike;
  ExosNative?: unknown;
  navigator?: { userAgent?: string };
}

function uaPlatform(ua: string): NativePlatform | null {
  if (/\b(?:iPhone|iPad|iPod)\b/.test(ua) || /\bMacintosh\b.*\bMobile\//.test(ua)) return 'ios';
  if (/\bAndroid\b/i.test(ua)) return 'android';
  return null;
}

/** The app's UA token version (ExosApp/1 → 1), or null. */
export function appUaVersion(userAgent: string | null | undefined): number | null {
  const m = userAgent ? APP_UA_RE.exec(userAgent) : null;
  return m ? Number(m[1]) : null;
}

/**
 * The native app this page runs in, or null (a browser, an in-app browser,
 * SSR). Unsure answers null: a web page never pretends to be the app.
 */
export function detectNativeApp(win: unknown): { platform: NativePlatform } | null {
  const w = win as WinLike | undefined;
  if (!w) return null;
  const ua = w.navigator?.userAgent ?? '';
  try {
    const cap = w.Capacitor;
    if (cap && typeof cap.isNativePlatform === 'function' && cap.isNativePlatform() === true) {
      const p = typeof cap.getPlatform === 'function' ? cap.getPlatform() : '';
      if (p === 'ios' || p === 'android') return { platform: p };
      const fromUa = uaPlatform(ua);
      if (fromUa) return { platform: fromUa };
    }
  } catch {
    /* a broken global: fall through to the other marks */
  }
  const platform = uaPlatform(ua);
  if (!platform) return null;
  if (appUaVersion(ua) !== null) return { platform };
  if (getNativeBridge(w as { ExosNative?: unknown })) return { platform };
  return null;
}

let cached: { platform: NativePlatform } | null | undefined;
/** This page's answer, read once (SSR: null). */
export function currentNativeApp(): { platform: NativePlatform } | null {
  if (typeof window === 'undefined') return null;
  if (cached === undefined) cached = detectNativeApp(window);
  return cached;
}
export function isNativeApp(): boolean {
  return currentNativeApp() !== null;
}
/** For tests: forget the cached answer. */
export function resetNativeAppCache(): void {
  cached = undefined;
}

// --- Build flags ---------------------------------------------------------------

export interface BuildEnv {
  MODE?: string;
  VITE_EXOS_WEB_URL?: string;
}

// `import.meta.env` spelled out (not cast): Vite and vitest (vi.stubEnv) both see it.
function viteEnv(): BuildEnv {
  return (import.meta.env ?? {}) as BuildEnv;
}

export interface NativeBuildFlags {
  /** Built with `vite build --mode native` (apps/native's bundle). */
  native: boolean;
  /** Register the service worker (offline shell). The app IS the offline shell. */
  serviceWorker: boolean;
  /** Load the org's ad pixels. Off in the app: server-side conversions only
   *  (docs/marketing-conversions.md), and no App Tracking Transparency prompt. */
  pixels: boolean;
  /** Group chat (/groups). Out of the app: App Store 1.2 user-generated content rules. */
  groupChat: boolean;
  /** Stripe.js on our page (Embedded Checkout). Never in the app: hosted Checkout only (docs/pci.md). */
  stripeJs: boolean;
}

export function nativeBuildFlags(env: BuildEnv = viteEnv()): NativeBuildFlags {
  const native = env.MODE === 'native';
  return { native, serviceWorker: !native, pixels: !native, groupChat: !native, stripeJs: !native };
}

export function isNativeBuild(env?: BuildEnv): boolean {
  return nativeBuildFlags(env).native;
}

/**
 * The public web app's base URL (https://host/bridge, no trailing slash) for
 * links that leave the app: Stripe's success / cancel pages, shared links,
 * the auth mails. Only the native build has one; null on the web (there the
 * page's own origin is right). Inside the app the origin is
 * capacitor://localhost (iOS) or https://localhost (Android), which no one
 * else can open.
 */
export function nativeWebBase(env: BuildEnv = viteEnv()): string | null {
  if (env.MODE !== 'native') return null;
  const raw = (env.VITE_EXOS_WEB_URL ?? '').trim().replace(/\/+$/, '');
  try {
    const u = new URL(raw);
    if (u.protocol !== 'https:' || u.username || u.password || u.search || u.hash) return null;
    return `${u.origin}${u.pathname.replace(/\/+$/, '')}`;
  } catch {
    return null;
  }
}
