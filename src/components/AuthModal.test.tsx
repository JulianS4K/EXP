// @vitest-environment jsdom
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { act, cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react';
import { MemoryRouter } from 'react-router-dom';

const auth = vi.hoisted(() => ({
  signInWithPassword: vi.fn(),
  signUp: vi.fn(),
  resend: vi.fn(),
  signInWithOtp: vi.fn(),
  verifyOtp: vi.fn(),
  resetPasswordForEmail: vi.fn(),
  signInWithOAuth: vi.fn(),
}));
vi.mock('../lib/supabase', () => ({ supabase: { auth }, initialAuthUrl: '' }));

import AuthModal, { type AuthView } from './AuthModal';

const ok = { data: {}, error: null };

beforeEach(() => {
  localStorage.clear();
  Object.values(auth).forEach((fn) => fn.mockReset().mockResolvedValue(ok));
});
afterEach(() => {
  cleanup();
  vi.useRealTimers();
});

function open(view: AuthView = 'options', email = '') {
  return render(
    <MemoryRouter>
      <AuthModal isOpen onClose={vi.fn()} initialView={view} initialEmail={email} />
    </MemoryRouter>,
  );
}

const type = (label: RegExp | string, value: string) => fireEvent.change(screen.getByLabelText(label), { target: { value } });

describe('AuthModal: sign in', () => {
  it('labels fields with the right autocomplete hints and focuses email', () => {
    open('email-login');
    const email = screen.getByLabelText('Email Address');
    expect(email.getAttribute('autocomplete')).toBe('email');
    expect(screen.getByLabelText('Password').getAttribute('autocomplete')).toBe('current-password');
    expect(document.activeElement).toBe(email);
  });

  it('maps invalid credentials to a friendly alert', async () => {
    auth.signInWithPassword.mockResolvedValue({ data: {}, error: { code: 'invalid_credentials', status: 400, message: 'Invalid login credentials' } });
    open('email-login');
    type('Email Address', ' Fan@Example.com ');
    type('Password', 'whatever1');
    fireEvent.click(screen.getByRole('button', { name: 'Sign In' }));
    expect((await screen.findByRole('alert')).textContent).toMatch(/don't match/);
    expect(auth.signInWithPassword).toHaveBeenCalledWith({ email: 'fan@example.com', password: 'whatever1' });
    expect(screen.getByLabelText('Password').getAttribute('aria-invalid')).toBe('true');
  });

  it('offers to resend the confirmation when the email is unconfirmed', async () => {
    auth.signInWithPassword.mockResolvedValue({ data: {}, error: { code: 'email_not_confirmed', message: 'Email not confirmed' } });
    open('email-login');
    type('Email Address', 'fan@example.com');
    type('Password', 'whatever1');
    fireEvent.click(screen.getByRole('button', { name: 'Sign In' }));
    fireEvent.click(await screen.findByRole('button', { name: /resend confirmation email/i }));
    await waitFor(() => expect(auth.resend).toHaveBeenCalled());
    expect(auth.resend.mock.calls[0][0]).toMatchObject({ type: 'signup', email: 'fan@example.com' });
    expect((await screen.findByRole('status')).textContent).toMatch(/new link/);
  });

  it('shows the wait on rate limits', async () => {
    auth.signInWithPassword.mockResolvedValue({ data: {}, error: { status: 429, message: 'For security purposes, you can only request this after 17 seconds.' } });
    open('email-login');
    type('Email Address', 'fan@example.com');
    type('Password', 'whatever1');
    fireEvent.click(screen.getByRole('button', { name: 'Sign In' }));
    expect((await screen.findByRole('alert')).textContent).toMatch(/Wait 17 seconds/);
  });

  it('blocks a bad email before calling Supabase', () => {
    open('email-login');
    type('Email Address', 'nope');
    fireEvent.click(screen.getByRole('button', { name: 'Sign In' }));
    expect(screen.getByRole('alert').textContent).toMatch(/valid email/);
    expect(auth.signInWithPassword).not.toHaveBeenCalled();
  });
});

describe('AuthModal: email code', () => {
  it('sends a code, then verifies the 6 digits', async () => {
    open('code', 'fan@example.com');
    fireEvent.click(screen.getByRole('button', { name: /email me a code/i }));
    await waitFor(() => expect(auth.signInWithOtp).toHaveBeenCalled());
    const otpArgs = auth.signInWithOtp.mock.calls[0][0];
    expect(otpArgs.email).toBe('fan@example.com');
    expect(otpArgs.options.shouldCreateUser).toBe(true);
    expect(otpArgs.options.emailRedirectTo).toMatch(/\/auth\/callback/);

    const code = await screen.findByLabelText('6-digit code');
    expect(code.getAttribute('inputmode')).toBe('numeric');
    expect(code.getAttribute('autocomplete')).toBe('one-time-code');
    expect(document.activeElement).toBe(code);
    expect(screen.getByRole('button', { name: /send again \(\d+s\)/i }).hasAttribute('disabled')).toBe(true);

    fireEvent.change(code, { target: { value: '12 34 56' } });
    fireEvent.click(screen.getByRole('button', { name: 'Sign In' }));
    await waitFor(() => expect(auth.verifyOtp).toHaveBeenCalledWith({ email: 'fan@example.com', token: '123456', type: 'email' }));
  });

  it('says so when the code is wrong', async () => {
    auth.verifyOtp.mockResolvedValue({ data: {}, error: { code: 'otp_expired', status: 403, message: 'Token has expired or is invalid' } });
    open('code', 'fan@example.com');
    fireEvent.click(screen.getByRole('button', { name: /email me a code/i }));
    fireEvent.change(await screen.findByLabelText('6-digit code'), { target: { value: '000000' } });
    fireEvent.click(screen.getByRole('button', { name: 'Sign In' }));
    expect((await screen.findByRole('alert')).textContent).toMatch(/wrong or has expired/);
  });

  it('refuses a short code locally', async () => {
    open('code', 'fan@example.com');
    fireEvent.click(screen.getByRole('button', { name: /email me a code/i }));
    fireEvent.change(await screen.findByLabelText('6-digit code'), { target: { value: '123' } });
    fireEvent.click(screen.getByRole('button', { name: 'Sign In' }));
    expect(screen.getByRole('alert').textContent).toMatch(/6-digit/);
    expect(auth.verifyOtp).not.toHaveBeenCalled();
  });
});

describe('AuthModal: forgot password', () => {
  it.each([
    ['success', ok],
    ['a per-address rate limit', { data: {}, error: { status: 429, message: 'you can only request this after 30 seconds' } }],
    ['any other error', { data: {}, error: { status: 400, message: 'User not found' } }],
  ])('shows the same neutral message on %s', async (_label, reply) => {
    auth.resetPasswordForEmail.mockResolvedValue(reply);
    open('forgot');
    type('Email Address', 'Fan@Example.com');
    fireEvent.click(screen.getByRole('button', { name: /send reset link/i }));
    expect((await screen.findByRole('status')).textContent).toMatch(/If an account exists/);
    expect(screen.queryByRole('alert')).toBeNull();
    const [email, opts] = auth.resetPasswordForEmail.mock.calls[0];
    expect(email).toBe('fan@example.com');
    expect(opts.redirectTo).toMatch(/\/reset-password$/);
  });

  it('is reachable from the sign-in form', () => {
    open('email-login');
    fireEvent.click(screen.getByRole('button', { name: /forgot password/i }));
    expect(screen.getByRole('heading', { name: /reset password/i })).toBeTruthy();
  });
});

describe('AuthModal: sign up', () => {
  function fill(pw: string, confirm = pw) {
    type('Display Name', 'Fan');
    type('Email Address', 'fan@example.com');
    type('Password', pw);
    type('Confirm Password', confirm);
    fireEvent.click(screen.getByRole('button', { name: 'Create Account' }));
  }

  it('enforces the password rules and the confirmation', () => {
    open('email-signup');
    expect(screen.getByLabelText('Password').getAttribute('autocomplete')).toBe('new-password');
    fill('abcdefghij');
    expect(screen.getByRole('alert').textContent).toMatch(/mix/i);
    fill('Abcdefghij', 'Abcdefghik');
    expect(screen.getByRole('alert').textContent).toMatch(/don't match/);
    expect(auth.signUp).not.toHaveBeenCalled();
  });

  it('shows check-your-email with a 60s resend cooldown', async () => {
    vi.useFakeTimers({ shouldAdvanceTime: true });
    auth.signUp.mockResolvedValue({ data: { user: { id: 'u' }, session: null }, error: null });
    open('email-signup');
    fill('Correct-horse-9');
    await screen.findByRole('heading', { name: /check your email/i });
    expect(auth.signUp.mock.calls[0][0]).toMatchObject({ email: 'fan@example.com', options: { data: { display_name: 'Fan' } } });
    const resend = screen.getByRole('button', { name: /resend in 60s/i });
    expect(resend.hasAttribute('disabled')).toBe(true);
    await act(async () => { await vi.advanceTimersByTimeAsync(61_000); });
    const ready = screen.getByRole('button', { name: /^resend confirmation email$/i });
    expect(ready.hasAttribute('disabled')).toBe(false);
    fireEvent.click(ready);
    await waitFor(() => expect(auth.resend).toHaveBeenCalledWith(expect.objectContaining({ type: 'signup', email: 'fan@example.com' })));
  });

  it("keeps 'already registered' generic", async () => {
    auth.signUp.mockResolvedValue({ data: {}, error: { code: 'user_already_exists', status: 422, message: 'User already registered' } });
    open('email-signup');
    fill('Correct-horse-9');
    const alert = await screen.findByRole('alert');
    expect(alert.textContent).not.toMatch(/already registered/i);
    expect(alert.textContent).toMatch(/sign in or reset your password/);
  });
});
