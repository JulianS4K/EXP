// Password rules and Supabase Auth error → friendly message mapping, shared by
// the sign-in modal, the embed sign-in, /reset-password and account settings.
//
// Password minimum: Supabase's project default is 6 characters. We ask for 8
// here, and docs/auth.md has the operator set the project's "Minimum password
// length" to 8 too so the API enforces the same floor. Keep the two in step.

export const PASSWORD_MIN_LENGTH = 8;
// bcrypt (what Supabase hashes with) ignores bytes past 72; the API rejects
// longer passwords outright.
export const PASSWORD_MAX_LENGTH = 72;

const EMAIL_RE = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;

export function cleanEmail(email: string): string {
  return email.trim().toLowerCase();
}

export function isValidEmail(email: string): boolean {
  return EMAIL_RE.test(cleanEmail(email)) && cleanEmail(email).length <= 254;
}

export interface PasswordCheck {
  ok: boolean;
  /** Human-readable problems, empty when ok. */
  problems: string[];
}

function charClasses(pw: string): number {
  let n = 0;
  if (/[a-z]/.test(pw)) n++;
  if (/[A-Z]/.test(pw)) n++;
  if (/[0-9]/.test(pw)) n++;
  if (/[^A-Za-z0-9]/.test(pw)) n++;
  return n;
}

/**
 * Client-side strength rules: at least 8 characters, at most 72 bytes, and
 * not all one kind of character (mix at least two of lowercase, uppercase,
 * digits, symbols). Also refuses the email itself or its local part.
 */
export function checkPassword(pw: string, opts: { email?: string } = {}): PasswordCheck {
  const problems: string[] = [];
  if (pw.length < PASSWORD_MIN_LENGTH) problems.push(`Use at least ${PASSWORD_MIN_LENGTH} characters.`);
  if (new TextEncoder().encode(pw).length > PASSWORD_MAX_LENGTH) problems.push(`Use at most ${PASSWORD_MAX_LENGTH} characters.`);
  if (pw.length > 0 && charClasses(pw) < 2) problems.push('Mix at least two of: lowercase, uppercase, numbers, symbols.');
  const email = opts.email ? cleanEmail(opts.email) : '';
  if (email && pw) {
    const lower = pw.toLowerCase();
    const local = email.split('@')[0];
    if (lower === email || (local.length >= 3 && lower === local)) problems.push("Don't use your email as your password.");
  }
  return { ok: problems.length === 0, problems };
}

export type AuthErrorKind =
  | 'invalid_credentials'
  | 'email_not_confirmed'
  | 'rate_limited'
  | 'otp_invalid'
  | 'link_invalid'
  | 'weak_password'
  | 'same_password'
  | 'reauth_needed'
  | 'reauth_invalid'
  | 'signup_blocked'
  | 'email_invalid'
  | 'email_taken'
  | 'session_missing'
  | 'disabled'
  | 'network'
  | 'unknown';

export interface FriendlyAuthError {
  kind: AuthErrorKind;
  message: string;
  /** Seconds to wait before retrying, when Supabase says. */
  retryAfter?: number;
}

type ErrLike = { code?: unknown; status?: unknown; message?: unknown; name?: unknown; reasons?: unknown } | null | undefined;

/** "you can only request this after 42 seconds" → 42. */
export function retryAfterSeconds(message: string): number | undefined {
  const m = /after (\d+) seconds?/i.exec(message);
  return m ? Number(m[1]) : undefined;
}

/**
 * Maps a supabase-js AuthError (or anything thrown) to a message that is safe
 * to show. Messages never confirm whether an account exists beyond what the
 * Supabase API itself already reveals for that call.
 */
export function mapAuthError(err: unknown): FriendlyAuthError {
  const e = (err && typeof err === 'object' ? err : { message: String(err ?? '') }) as ErrLike;
  const code = typeof e?.code === 'string' ? e.code : '';
  const status = typeof e?.status === 'number' ? e.status : 0;
  const msg = typeof e?.message === 'string' ? e.message : '';
  const name = typeof e?.name === 'string' ? e.name : '';
  const has = (re: RegExp) => re.test(msg);

  if (code === 'invalid_credentials' || has(/invalid login credentials/i)) {
    return { kind: 'invalid_credentials', message: "That email and password don't match. Try again, reset your password, or sign in with an email code." };
  }
  if (code === 'email_not_confirmed' || has(/email not confirmed/i)) {
    return { kind: 'email_not_confirmed', message: 'Confirm your email first. Open the link we sent you, or send it again.' };
  }
  if (status === 429 || /rate_limit/.test(code) || has(/rate limit|only request this after|too many/i)) {
    const retryAfter = retryAfterSeconds(msg);
    return {
      kind: 'rate_limited',
      retryAfter,
      message: retryAfter ? `Too many tries. Wait ${retryAfter} seconds, then try again.` : 'Too many tries. Wait a minute, then try again.',
    };
  }
  if (code === 'otp_expired' || has(/token has expired|otp.*(expired|invalid)|invalid.*otp/i)) {
    return { kind: 'otp_invalid', message: "That code is wrong or has expired. Check the newest email, or send a new code." };
  }
  if (code === 'flow_state_expired' || code === 'flow_state_not_found' || code === 'bad_code_verifier' || has(/code verifier|flow state|invalid.*(grant|link)|link is invalid/i)) {
    return { kind: 'link_invalid', message: 'This link has expired or was already used. Ask for a new one.' };
  }
  if (code === 'weak_password' || has(/password should|weak password/i)) {
    const reasons = Array.isArray(e?.reasons) ? (e!.reasons as string[]) : [];
    const extra = reasons.includes('pwned') ? ' It appears in a known data breach; pick a different one.' : '';
    return { kind: 'weak_password', message: `That password is too weak. Use at least ${PASSWORD_MIN_LENGTH} characters with a mix of letters, numbers or symbols.${extra}` };
  }
  if (code === 'same_password' || has(/different from the old password/i)) {
    return { kind: 'same_password', message: 'Choose a password different from your current one.' };
  }
  if (code === 'reauthentication_needed' || has(/requires reauthentication/i)) {
    return { kind: 'reauth_needed', message: 'For security, confirm it’s you: we emailed you a code.' };
  }
  if (code === 'reauthentication_not_valid' || has(/nonce/i)) {
    return { kind: 'reauth_invalid', message: 'That verification code is wrong or has expired. Send a new one.' };
  }
  // Only returned when email confirmations are off; Supabase already says so
  // in that setup. Keep it neutral anyway.
  if (code === 'user_already_exists' || code === 'email_exists' || has(/already (been )?registered|already exists/i)) {
    return { kind: 'email_taken', message: "We couldn't use that email here. If you already have an account, sign in or reset your password." };
  }
  if (code === 'signup_disabled' || code === 'otp_disabled' || code === 'email_provider_disabled' || has(/signups not allowed|provider is disabled|logins are disabled/i)) {
    return { kind: 'disabled', message: "That sign-in method isn't available right now. Try another one." };
  }
  if (code === 'email_address_invalid' || code === 'email_address_not_authorized' || has(/invalid.*email|email.*invalid|unable to validate email/i)) {
    return { kind: 'email_invalid', message: 'Enter a valid email address.' };
  }
  if (code === 'session_not_found' || code === 'session_expired' || code === 'refresh_token_not_found' || name === 'AuthSessionMissingError' || has(/session missing|not logged in/i)) {
    return { kind: 'session_missing', message: 'Your session has ended. Sign in again.' };
  }
  if (name === 'AuthRetryableFetchError' || has(/failed to fetch|network|load failed/i)) {
    return { kind: 'network', message: "Can't reach the server. Check your connection and try again." };
  }
  return { kind: 'unknown', message: 'Something went wrong. Try again in a moment.' };
}
