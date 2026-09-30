// "Connect Google Ads" return handling (exos-oauth-google, mig 20260930102000).
// Pure, so vitest covers it; the fetch calls are in ./adCredentials.
//
// Google sends the browser back to /orgs/<org>/settings with either
//   ?google_ads=finish&google_ads_state=<state>  → POST /finish with the JWT
//   ?google_ads=error&reason=<why>               → a toast
// (?google_ads=connected is accepted too, for a direct link.)

export type GoogleAdsReturn =
  | { kind: 'finish'; state: string }
  | { kind: 'connected' }
  | { kind: 'error'; reason: string };

const STATE_RE = /^[A-Za-z0-9_-]{43}$/;

export function readGoogleAdsReturn(search: string): GoogleAdsReturn | null {
  const q = new URLSearchParams(search);
  const v = q.get('google_ads');
  if (v === 'finish') {
    const state = q.get('google_ads_state') ?? '';
    return STATE_RE.test(state) ? { kind: 'finish', state } : { kind: 'error', reason: 'state' };
  }
  if (v === 'connected') return { kind: 'connected' };
  if (v === 'error') return { kind: 'error', reason: (q.get('reason') ?? 'unknown').replace(/[^a-z_]/g, '').slice(0, 20) || 'unknown' };
  return null;
}

/** The query string with the Google Ads return params removed ('' or '?…'). */
export function stripGoogleAdsReturn(search: string): string {
  const q = new URLSearchParams(search);
  for (const k of ['google_ads', 'google_ads_state', 'reason']) q.delete(k);
  const s = q.toString();
  return s ? `?${s}` : '';
}

export function googleAdsErrorMessage(reason: string): string {
  switch (reason) {
    case 'denied': return 'Google Ads wasn’t connected: access was declined on Google’s page.';
    case 'expired':
    case 'state': return 'That Google sign-in expired or was already used. Click Connect Google Ads again.';
    case 'scope': return 'Google didn’t grant access to conversion uploads. Connect again and allow it.';
    case 'no_refresh': return 'Google didn’t return a long-lived token. Remove Exos under your Google account’s third-party access, then connect again.';
    case 'auth': return 'Sign in to Exos in this browser, then connect Google Ads again.';
    case 'forbidden': return 'Only owners and managers can connect Google Ads.';
    case 'not_configured': return 'Google Ads connection isn’t set up on this Exos server yet.';
    default: return 'Could not connect Google Ads. Try again.';
  }
}
