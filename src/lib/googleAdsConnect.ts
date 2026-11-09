// Connect Google Ads (exos-oauth-google, mig 20260930102000) messages. The
// return from Google (?google_ads=finish&google_ads_state=…#google_ads_finish=…)
// is read by ./oauthReturn and confirmed in components/OAuthFinish.tsx
// (mig 20261029140000).

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
