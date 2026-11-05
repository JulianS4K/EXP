// In-app browsers (Instagram, Facebook, TikTok, ...) from the user agent.
// Shared by the SPA (src/lib/inAppBrowser.ts adds the browser-only capability
// probes and the "open in your browser" links) and exos-checkout (which
// records the kind on the checkout session, mig 20261105140000), so both
// classify a buyer the same way. No imports, so Deno and vitest both load it.
//
// The SQL backfill / insert trigger in that migration
// (_exos_in_app_browser_from_ua) mirrors PATTERNS below: keep them in step
// (tests/exos/test_ig_checkout.sql runs the same user agents as the vitest).

export const IN_APP_APPS = ["instagram", "facebook", "messenger", "threads", "tiktok", "snapchat", "x", "linkedin"] as const;
export type InAppApp = typeof IN_APP_APPS[number];

/** An app we know by name, or 'webview': some other app's embedded browser. */
export type InAppKind = InAppApp | "webview";

/** What a checkout session records: the kind, or 'none' for a real browser. */
export type InAppRecord = InAppKind | "none";
export const IN_APP_RECORDS: readonly InAppRecord[] = [...IN_APP_APPS, "webview", "none"];

// Order matters: Threads ships as "Barcelona" and Messenger carries Facebook's
// FBAN / FB_IAB tokens, so both are tried before Facebook.
const PATTERNS: [InAppApp, RegExp][] = [
  ["threads", /\bBarcelona\b|\bThreads\b/],
  ["instagram", /\bInstagram\b/i],
  ["messenger", /\bFB_IAB\/(?:MESSENGER|Orca-Android)\b|\bFBAN\/Messenger|\bMessengerForiOS|\bMessengerLite/i],
  ["facebook", /\bFBAN\/|\bFBAV\/|\bFB_IAB\b|\bFBIOS\b|\bFB4A\b/],
  ["tiktok", /musical_ly|\bBytedanceWebview\b|\bTikTok\b|\btrill_\d/i],
  ["snapchat", /\bSnapchat\b/i],
  ["linkedin", /\bLinkedInApp\b/i],
  // "Twitter for iPhone", "TwitterAndroid"; not the Twitterbot crawler.
  ["x", /\bTwitter(?:Android)?\b/],
];

/** The app whose in-app browser this is, or null (a real browser, a crawler, unknown). */
export function detectInAppApp(userAgent: string | null | undefined): InAppApp | null {
  if (!userAgent) return null;
  // Every in-app browser is a WebKit / Blink page view. Requiring it keeps
  // link-preview bots (facebookexternalhit, Twitterbot, TikTok's fetcher) out.
  if (!/\bAppleWebKit\//.test(userAgent)) return null;
  for (const [app, re] of PATTERNS) if (re.test(userAgent)) return app;
  return null;
}

export function isAndroidUa(userAgent: string | null | undefined): boolean {
  return !!userAgent && /\bAndroid\b/i.test(userAgent);
}

export function isIosUa(userAgent: string | null | undefined): boolean {
  return !!userAgent && /\b(?:iPhone|iPad|iPod)\b/.test(userAgent);
}

/** Android's WebView marks itself "; wv)". Chrome and Custom Tabs don't. */
export function isAndroidWebViewUa(userAgent: string | null | undefined): boolean {
  return isAndroidUa(userAgent) && /;\s*wv\)/.test(userAgent!);
}

/**
 * iOS WKWebView: WebKit without the "Safari/" token. Every iOS browser
 * (Safari, Chrome, Firefox, Edge) sends that token; embedded views and
 * home-screen web apps don't, so the SPA rules the home-screen case out with
 * a probe (navigator.standalone) before calling it a webview.
 */
export function isIosWebViewUa(userAgent: string | null | undefined): boolean {
  return isIosUa(userAgent) && /\bAppleWebKit\//.test(userAgent!) && !/\bSafari\//.test(userAgent!);
}

export function sanitizeInAppRecord(v: unknown): InAppRecord | undefined {
  return typeof v === "string" && (IN_APP_RECORDS as readonly string[]).includes(v) ? (v as InAppRecord) : undefined;
}

/** The kind for an escape-hatch marker (?iab_from=): a kind, never 'none'. */
export function sanitizeInAppKind(v: unknown): InAppKind | undefined {
  const r = sanitizeInAppRecord(v);
  return r && r !== "none" ? r : undefined;
}

/**
 * What exos-checkout records. The named app from the request's user agent
 * wins; then the page's own answer (it can also probe, e.g. an iOS webview
 * with no app token); then an Android WebView marker; else a real browser.
 */
export function inAppRecordFor(userAgent: string | null | undefined, clientHint: unknown): InAppRecord {
  const app = detectInAppApp(userAgent);
  if (app) return app;
  const hint = sanitizeInAppKind(clientHint);
  if (hint) return hint;
  if (isAndroidWebViewUa(userAgent)) return "webview";
  return "none";
}
