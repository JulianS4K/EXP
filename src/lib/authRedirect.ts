// Finishing an auth redirect: the page a Supabase email link or OAuth
// provider sends someone back to (/auth/callback, /reset-password).
//
// The client (src/lib/supabase.ts) is flowType 'implicit' with
// detectSessionInUrl, so a normal link arrives as #access_token=…&type=…
// and supabase-js has already stored the session by the time getSession()
// resolves. What's left for us:
//   - errors Supabase puts in the URL (#error_code=otp_expired…), which the
//     client leaves alone;
//   - ?code= (PKCE: OAuth or a template switched to PKCE). supabase-js only
//     auto-exchanges it when this browser holds the code verifier, so we try
//     exchangeCodeForSession ourselves when no session came of it;
//   - ?token_hash=…&type=… (email templates that link straight to the app
//     with {{ .TokenHash }}), verified with verifyOtp;
//   - #message=… from the first leg of a secure email change.

import type { EmailOtpType } from '@supabase/supabase-js';
import { supabase, initialAuthUrl } from './supabase';
import { authUrlParams } from './authUrls';
import { mapAuthError, type FriendlyAuthError } from './authRules';

export type RedirectOutcome =
  | { status: 'session'; type: string | null }
  | { status: 'error'; error: FriendlyAuthError; code: string }
  | { status: 'notice'; message: 'email_change_pending'; signedIn: boolean }
  | { status: 'none' };

const LINK_DEAD: FriendlyAuthError = {
  kind: 'link_invalid',
  message: 'This link has expired or was already used. Ask for a new one below.',
};

const OTP_TYPES: EmailOtpType[] = ['signup', 'invite', 'magiclink', 'recovery', 'email_change', 'email'];

/**
 * The URL this page was opened with. initialAuthUrl is captured at startup,
 * before supabase-js clears the tokens; it only counts when the app booted on
 * this same path (not after an in-app navigation here).
 */
export function arrivalUrl(): string {
  if (typeof window === 'undefined') return '';
  try {
    if (initialAuthUrl && new URL(initialAuthUrl).pathname === window.location.pathname) return initialAuthUrl;
  } catch {
    /* fall through */
  }
  return window.location.href;
}

/** True when the URL carried any auth params (tokens, code, token_hash, type). */
export function hasAuthParams(params: Record<string, string>): boolean {
  return !!(params.access_token || params.code || params.token_hash || params.type || params.error_code || params.error);
}

function linkError(code: string, description: string): FriendlyAuthError {
  if (/otp_expired|flow_state|bad_code_verifier|access_denied/.test(code)) return LINK_DEAD;
  const mapped = mapAuthError({ code, message: description });
  return mapped.kind === 'otp_invalid' || mapped.kind === 'unknown' ? LINK_DEAD : mapped;
}

export async function settleAuthRedirect(href: string = arrivalUrl()): Promise<RedirectOutcome> {
  const p = authUrlParams(href);
  const type = p.type ?? null;

  if (p.error || p.error_code || p.error_description) {
    const code = p.error_code || p.error || 'unknown';
    return { status: 'error', code, error: linkError(code, p.error_description ?? '') };
  }

  if (p.token_hash && type && (OTP_TYPES as string[]).includes(type)) {
    const { error } = await supabase.auth.verifyOtp({ token_hash: p.token_hash, type: type as EmailOtpType });
    if (error) return { status: 'error', code: (error as { code?: string }).code ?? 'verify_failed', error: linkError((error as { code?: string }).code ?? '', error.message) };
    return { status: 'session', type };
  }

  const { data } = await supabase.auth.getSession();
  if (p.message) return { status: 'notice', message: 'email_change_pending', signedIn: !!data.session };
  if (data.session) return { status: 'session', type };

  if (p.code) {
    const { data: ex, error } = await supabase.auth.exchangeCodeForSession(p.code);
    if (error || !ex.session) {
      return { status: 'error', code: (error as { code?: string } | null)?.code ?? 'exchange_failed', error: LINK_DEAD };
    }
    // redirectType is set at runtime ('recovery' etc.) but missing from the public type.
    return { status: 'session', type: (ex as { redirectType?: string | null }).redirectType ?? type };
  }

  return { status: 'none' };
}

/** Drops auth params from the address bar once handled (nothing to re-run on reload). */
export function scrubAuthParams(): void {
  if (typeof window === 'undefined') return;
  try {
    const url = new URL(window.location.href);
    ['code', 'token_hash', 'type', 'error', 'error_code', 'error_description'].forEach((k) => url.searchParams.delete(k));
    if (url.hash.includes('=')) url.hash = '';
    window.history.replaceState(window.history.state, '', url.toString());
  } catch {
    /* ignore */
  }
}
