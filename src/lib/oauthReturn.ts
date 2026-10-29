// Coming back from an OAuth sign-in (Connect Google Ads: exos-oauth-google;
// Connect Eventbrite: exos-eventbrite-oauth; mig 20261029140000). Pure, so
// vitest covers it (oauthReturn.test.ts); the screen is
// components/OAuthFinish.tsx, mounted by the org settings page.
//
// The provider sends the browser back to /orgs/<org>/settings with
//   ?<p>=finish&<p>_state=<state>#<p>_finish=<finish token>
//   ?<p>=error&reason=<why>
// for <p> = google_ads | eventbrite. The finish token is in the FRAGMENT so
// no server sees it. The page:
//   1. reads both, then removes them from the address bar at once (the token
//      is kept in memory only, never shown, logged or sent anywhere but
//      /finish);
//   2. shows which organization the account will be connected to, with a
//      Confirm button: nothing is sent on page load;
//   3. on Confirm, POSTs { state, finish } to /finish with the user's JWT.
// /finish refuses a sign-in started by another Exos account (the
// account-linking attack), and the page then says nothing was connected.

export type OAuthProvider = 'google_ads' | 'eventbrite';

export type OAuthReturn =
  | { provider: OAuthProvider; kind: 'finish'; state: string; finish: string }
  | { provider: OAuthProvider; kind: 'error'; reason: string };

const TOKEN_RE = /^[A-Za-z0-9_-]{43}$/;
const PROVIDERS: OAuthProvider[] = ['google_ads', 'eventbrite'];

export const providerLabel = (p: OAuthProvider): string => (p === 'google_ads' ? 'Google Ads' : 'Eventbrite');

function cleanReason(v: string | null): string {
  return (v ?? 'unknown').replace(/[^a-z_]/g, '').slice(0, 20) || 'unknown';
}

/** The return in this URL, or null. `hash` is location.hash ('#…' or ''). */
export function readOAuthReturn(search: string, hash: string): OAuthReturn | null {
  const q = new URLSearchParams(search);
  const h = new URLSearchParams((hash ?? '').replace(/^#/, ''));
  for (const provider of PROVIDERS) {
    const v = q.get(provider);
    if (v === 'finish') {
      const state = q.get(`${provider}_state`) ?? '';
      const finish = h.get(`${provider}_finish`) ?? '';
      if (!TOKEN_RE.test(state)) return { provider, kind: 'error', reason: 'state' };
      if (!TOKEN_RE.test(finish)) return { provider, kind: 'error', reason: 'token' };
      return { provider, kind: 'finish', state, finish };
    }
    if (v === 'error') return { provider, kind: 'error', reason: cleanReason(q.get('reason')) };
  }
  return null;
}

/** The query string without the OAuth return params ('' or '?…'). The hash is dropped by the caller. */
export function stripOAuthReturn(search: string): string {
  const q = new URLSearchParams(search);
  if (!PROVIDERS.some((p) => q.has(p))) return search && search !== '?' ? search : '';
  for (const p of PROVIDERS) {
    q.delete(p);
    q.delete(`${p}_state`);
  }
  q.delete('reason');
  const s = q.toString();
  return s ? `?${s}` : '';
}

/** The finish hash params removed from a location.hash ('' or '#…'). */
export function stripOAuthHash(hash: string): string {
  const h = new URLSearchParams((hash ?? '').replace(/^#/, ''));
  for (const p of PROVIDERS) h.delete(`${p}_finish`);
  const s = h.toString();
  return s ? `#${s}` : '';
}

// ---- the confirm step ---------------------------------------------------------

export type FinishStep =
  | { step: 'confirm'; provider: OAuthProvider; state: string; finish: string }
  | { step: 'sending'; provider: OAuthProvider; state: string; finish: string }
  | { step: 'done'; provider: OAuthProvider }
  | { step: 'refused'; provider: OAuthProvider; reason: string }
  | { step: 'cancelled'; provider: OAuthProvider };

export type FinishAction =
  | { type: 'confirm' }
  | { type: 'cancel' }
  | { type: 'ok' }
  | { type: 'refused'; reason: string };

/** Where a return starts: a finish waits for Confirm, never sends by itself. */
export function initialStep(ret: OAuthReturn, orgVisible: boolean): FinishStep {
  if (ret.kind === 'error') return { step: 'refused', provider: ret.provider, reason: ret.reason };
  // The org isn't one this user can see: the sign-in wasn't started from this
  // account. Say so without sending the token anywhere.
  if (!orgVisible) return { step: 'refused', provider: ret.provider, reason: 'other_user' };
  return { step: 'confirm', provider: ret.provider, state: ret.state, finish: ret.finish };
}

export function finishReducer(s: FinishStep, a: FinishAction): FinishStep {
  switch (a.type) {
    case 'confirm':
      return s.step === 'confirm' ? { ...s, step: 'sending' } : s;
    case 'cancel':
      return s.step === 'confirm' ? { step: 'cancelled', provider: s.provider } : s;
    case 'ok':
      return s.step === 'sending' ? { step: 'done', provider: s.provider } : s;
    case 'refused':
      return s.step === 'sending' ? { step: 'refused', provider: s.provider, reason: a.reason } : s;
  }
}

/** The /finish body, only from the sending step. */
export function finishBody(s: FinishStep): { state: string; finish: string } | null {
  return s.step === 'sending' ? { state: s.state, finish: s.finish } : null;
}

export function confirmPrompt(provider: OAuthProvider, orgName: string): string {
  return `Connect the ${providerLabel(provider)} account you just signed in with to ${orgName}?`;
}

/** What the page says when nothing was connected. Never includes the state or token. */
export function refusalMessage(provider: OAuthProvider, reason: string): string {
  const label = providerLabel(provider);
  switch (reason) {
    case 'other_user':
      return `This ${label} sign-in was started by another Exos account, so nothing was connected. ` +
        `If someone sent you a link to connect your ${label} account, don't use it. To connect it to your own ` +
        `organization, start from your organization's settings.`;
    case 'token':
      return `This ${label} sign-in can only be finished in the browser that came back from ${label}, so nothing ` +
        `was connected. Click Connect ${label} again.`;
    case 'denied':
      return `${label} wasn't connected: access was declined on ${label}'s page.`;
    case 'expired':
    case 'state':
      return `That ${label} sign-in expired or was already used, so nothing was connected. Click Connect ${label} again.`;
    case 'auth':
      return `Sign in to Exos in this browser, then connect ${label} again.`;
    case 'forbidden':
      return `Only owners and managers can connect ${label}. Nothing was connected.`;
    case 'not_configured':
      return `Connecting ${label} isn't set up on this Exos server yet.`;
    case 'scope':
      return 'Google didn’t grant access to conversion uploads. Connect again and allow it.';
    case 'no_refresh':
      return 'Google didn’t return a long-lived token. Remove Exos under your Google account’s third-party access, then connect again.';
    case 'config':
      return `The Exos app on ${label} isn't set up right. Tell your Exos admin.`;
    default:
      return `Could not connect ${label}, and nothing was connected. Try again.`;
  }
}
