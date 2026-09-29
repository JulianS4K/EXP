import { describe, expect, it } from 'vitest';
import { checkPassword, isValidEmail, mapAuthError, PASSWORD_MIN_LENGTH, retryAfterSeconds } from './authRules';

describe('checkPassword', () => {
  it('needs 8+ characters', () => {
    expect(PASSWORD_MIN_LENGTH).toBe(8);
    expect(checkPassword('Ab1').ok).toBe(false);
    expect(checkPassword('Abcdefg1').ok).toBe(true);
  });

  it.each(['abcdefghij', 'ABCDEFGHIJ', '1234567890', '!!!!!!!!!!'])('refuses all one class: %s', (pw) => {
    const r = checkPassword(pw);
    expect(r.ok).toBe(false);
    expect(r.problems.join(' ')).toMatch(/mix/i);
  });

  it.each(['correcthorse9', 'CorrectHorse', 'pass word!', 'ÉCOLE-école'])('accepts mixed: %s', (pw) => {
    expect(checkPassword(pw).ok).toBe(true);
  });

  it('caps at 72 bytes (bcrypt)', () => {
    expect(checkPassword('a1'.repeat(36)).ok).toBe(true);
    expect(checkPassword('a1'.repeat(37)).ok).toBe(false);
  });

  it('refuses the email or its local part', () => {
    expect(checkPassword('Fan@Example.com', { email: 'fan@example.com' }).ok).toBe(false);
    expect(checkPassword('Julian2026', { email: 'julian2026@example.com' }).ok).toBe(false);
    expect(checkPassword('Julian2027', { email: 'julian2026@example.com' }).ok).toBe(true);
  });
});

describe('isValidEmail', () => {
  it('accepts and trims', () => expect(isValidEmail('  Fan@Example.com ')).toBe(true));
  it.each(['', 'fan', 'fan@', 'fan@example', 'a b@c.d'])('refuses %j', (e) => expect(isValidEmail(e)).toBe(false));
});

describe('mapAuthError', () => {
  it('invalid credentials (code or legacy message)', () => {
    expect(mapAuthError({ code: 'invalid_credentials', status: 400, message: 'Invalid login credentials' }).kind).toBe('invalid_credentials');
    expect(mapAuthError({ message: 'Invalid login credentials' }).kind).toBe('invalid_credentials');
  });

  it('email not confirmed', () => {
    expect(mapAuthError({ code: 'email_not_confirmed', message: 'Email not confirmed' }).kind).toBe('email_not_confirmed');
  });

  it('rate limits, with the wait when Supabase gives one', () => {
    const r = mapAuthError({ code: 'over_email_send_rate_limit', status: 429, message: 'For security purposes, you can only request this after 42 seconds.' });
    expect(r).toMatchObject({ kind: 'rate_limited', retryAfter: 42 });
    expect(r.message).toMatch(/42 seconds/);
    expect(mapAuthError({ status: 429, message: 'Too many requests' })).toMatchObject({ kind: 'rate_limited', retryAfter: undefined });
    expect(retryAfterSeconds('after 1 second')).toBe(1);
  });

  it('bad or expired codes and links', () => {
    expect(mapAuthError({ code: 'otp_expired', message: 'Token has expired or is invalid' }).kind).toBe('otp_invalid');
    expect(mapAuthError({ code: 'flow_state_expired' }).kind).toBe('link_invalid');
  });

  it('password problems', () => {
    expect(mapAuthError({ code: 'weak_password', reasons: ['pwned'] }).message).toMatch(/breach/);
    expect(mapAuthError({ code: 'same_password' }).kind).toBe('same_password');
    expect(mapAuthError({ code: 'reauthentication_needed' }).kind).toBe('reauth_needed');
    expect(mapAuthError({ code: 'reauthentication_not_valid' }).kind).toBe('reauth_invalid');
  });

  it("'already registered' stays neutral", () => {
    const r = mapAuthError({ code: 'user_already_exists', message: 'User already registered' });
    expect(r.kind).toBe('email_taken');
    expect(r.message).not.toMatch(/already registered|exists/i);
  });

  it('session, network, disabled, unknown', () => {
    expect(mapAuthError({ name: 'AuthSessionMissingError', message: 'Auth session missing!' }).kind).toBe('session_missing');
    expect(mapAuthError({ name: 'AuthRetryableFetchError', message: 'Failed to fetch' }).kind).toBe('network');
    expect(mapAuthError({ code: 'otp_disabled', message: 'Signups not allowed for otp' }).kind).toBe('disabled');
    expect(mapAuthError(new Error('weird')).kind).toBe('unknown');
    expect(mapAuthError(null).kind).toBe('unknown');
    expect(mapAuthError('boom').message).not.toContain('boom');
  });
});
