// In-app browsers (Instagram, Facebook, TikTok, ...), where most NYC promoters'
// buyers first land (docs/gtm-nyc.md). What changes there:
//   * Google refuses OAuth inside embedded webviews ("disallowed_useragent"),
//     and Microsoft's flow is unreliable, so those buttons are hidden and email
//     sign-in is offered instead. Apple sign-in and Stripe Checkout both work.
//   * Popups and new tabs are swallowed, so checkout stays a same-tab redirect.
//   * Wallet buttons (Apple Pay) may not show; the buyer can reopen the page in
//     the system browser. Android can do that with an intent: URL; iOS has no
//     reliable programmatic escape, so the page explains the "..." menu instead.

export type InAppApp = 'instagram' | 'facebook' | 'messenger' | 'tiktok' | 'snapchat' | 'threads' | 'linkedin' | 'x';

const PATTERNS: [InAppApp, RegExp][] = [
  ['instagram', /\bInstagram\b/i],
  ['threads', /\bBarcelona\b|\bThreads\b/],
  ['messenger', /\bFB_IAB\/MESSENGER\b|\bFBAN\/Messenger|\bMessengerForiOS/i],
  ['facebook', /\bFBAN\/|\bFBAV\/|\bFB_IAB\b|\bFBIOS\b/],
  ['tiktok', /musical_ly|\bBytedanceWebview\b|\bTikTok\b/i],
  ['snapchat', /\bSnapchat\b/i],
  ['linkedin', /\bLinkedInApp\b/i],
  ['x', /\bTwitter(?:Android)?\b/],
];

export function detectInAppBrowser(userAgent: string | undefined | null): InAppApp | null {
  if (!userAgent) return null;
  for (const [app, re] of PATTERNS) if (re.test(userAgent)) return app;
  return null;
}

export function isAndroid(userAgent: string | undefined | null): boolean {
  return !!userAgent && /\bAndroid\b/i.test(userAgent);
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

export const IN_APP_LABEL: Record<InAppApp, string> = {
  instagram: 'Instagram',
  facebook: 'Facebook',
  messenger: 'Messenger',
  tiktok: 'TikTok',
  snapchat: 'Snapchat',
  threads: 'Threads',
  linkedin: 'LinkedIn',
  x: 'X',
};

// The current page's in-app browser, or null in a normal browser / SSR.
export function currentInAppBrowser(): InAppApp | null {
  if (typeof navigator === 'undefined') return null;
  return detectInAppBrowser(navigator.userAgent);
}
