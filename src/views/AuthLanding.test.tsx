// @vitest-environment jsdom
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react';
import type { ReactElement } from 'react';
import { MemoryRouter, Route, Routes } from 'react-router-dom';

const auth = vi.hoisted(() => ({
  getSession: vi.fn(),
  exchangeCodeForSession: vi.fn(),
  verifyOtp: vi.fn(),
  updateUser: vi.fn(),
  resetPasswordForEmail: vi.fn(),
  resend: vi.fn(),
}));
vi.mock('../lib/supabase', () => ({ supabase: { auth }, initialAuthUrl: '' }));

const authState = vi.hoisted(() => ({
  user: null as null | { email: string },
  passwordRecovery: false,
  endPasswordRecovery: vi.fn(),
  openAuth: vi.fn(),
}));
vi.mock('../context/AuthContext', () => ({ useAuth: () => authState }));
const toast = vi.hoisted(() => vi.fn());
vi.mock('../context/ToastContext', () => ({ useToast: () => ({ toast }) }));

import ResetPassword from './ResetPassword';
import AuthCallback from './AuthCallback';

const session = { access_token: 't', user: { id: 'u', email: 'fan@example.com' } };

function at(url: string) {
  window.history.replaceState(null, '', url);
}

function renderAt(path: string, el: ReactElement) {
  return render(
    <MemoryRouter initialEntries={[path]}>
      <Routes>
        <Route path={path.split('?')[0]} element={el} />
        <Route path="/" element={<p>home page</p>} />
        <Route path="/event/:id" element={<p>event page</p>} />
        <Route path="/reset-password" element={<p>reset page</p>} />
      </Routes>
    </MemoryRouter>,
  );
}

beforeEach(() => {
  localStorage.clear();
  Object.values(auth).forEach((fn) => fn.mockReset());
  auth.getSession.mockResolvedValue({ data: { session: null } });
  auth.resetPasswordForEmail.mockResolvedValue({ data: {}, error: null });
  auth.resend.mockResolvedValue({ data: {}, error: null });
  authState.user = null;
  authState.passwordRecovery = false;
  authState.endPasswordRecovery.mockReset();
  toast.mockReset();
});
afterEach(cleanup);

describe('ResetPassword', () => {
  it('explains an expired link and sends a new one', async () => {
    at('/reset-password#error=access_denied&error_code=otp_expired&error_description=Email+link+is+invalid+or+has+expired');
    renderAt('/reset-password', <ResetPassword />);
    expect((await screen.findByRole('alert')).textContent).toMatch(/expired or was already used/);
    fireEvent.change(screen.getByLabelText('Email Address'), { target: { value: 'Fan@Example.com' } });
    fireEvent.click(screen.getByRole('button', { name: /send a new link/i }));
    expect((await screen.findByRole('status')).textContent).toMatch(/If an account exists/);
    expect(auth.resetPasswordForEmail.mock.calls[0][0]).toBe('fan@example.com');
    expect(auth.resetPasswordForEmail.mock.calls[0][1].redirectTo).toMatch(/\/reset-password$/);
  });

  it('exchanges a PKCE ?code= and saves a new password', async () => {
    at('/reset-password?code=abc');
    auth.exchangeCodeForSession.mockResolvedValue({ data: { session, redirectType: 'recovery' }, error: null });
    auth.updateUser.mockResolvedValue({ data: {}, error: null });
    authState.user = { email: 'fan@example.com' };
    renderAt('/reset-password', <ResetPassword />);

    const pw = await screen.findByLabelText('New password');
    expect(auth.exchangeCodeForSession).toHaveBeenCalledWith('abc');
    expect(pw.getAttribute('autocomplete')).toBe('new-password');
    expect(window.location.search).toBe(''); // code scrubbed from the address bar

    fireEvent.change(pw, { target: { value: 'short' } });
    fireEvent.change(screen.getByLabelText('Confirm new password'), { target: { value: 'short' } });
    fireEvent.click(screen.getByRole('button', { name: /save password/i }));
    expect(screen.getByRole('alert').textContent).toMatch(/at least 8/);
    expect(auth.updateUser).not.toHaveBeenCalled();

    fireEvent.change(pw, { target: { value: 'Correct-horse-9' } });
    fireEvent.change(screen.getByLabelText('Confirm new password'), { target: { value: 'Correct-horse-9' } });
    fireEvent.click(screen.getByRole('button', { name: /save password/i }));
    await screen.findByText('home page');
    expect(auth.updateUser).toHaveBeenCalledWith({ password: 'Correct-horse-9' });
    expect(authState.endPasswordRecovery).toHaveBeenCalled();
    expect(toast).toHaveBeenCalledWith(expect.objectContaining({ kind: 'success' }));
  });

  it('accepts the implicit-flow session supabase-js already stored', async () => {
    at('/reset-password');
    auth.getSession.mockResolvedValue({ data: { session } });
    authState.user = { email: 'fan@example.com' };
    authState.passwordRecovery = true;
    renderAt('/reset-password', <ResetPassword />);
    expect(await screen.findByLabelText('New password')).toBeTruthy();
  });

  it('a used ?code= gets the send-a-new-link form', async () => {
    at('/reset-password?code=used');
    auth.exchangeCodeForSession.mockResolvedValue({ data: { session: null }, error: { code: 'flow_state_not_found', message: 'invalid flow state' } });
    renderAt('/reset-password', <ResetPassword />);
    expect((await screen.findByRole('alert')).textContent).toMatch(/expired or was already used/);
    expect(screen.getByRole('button', { name: /send a new link/i })).toBeTruthy();
  });

  it('a signed-in visit without a link points to account settings', async () => {
    at('/reset-password');
    auth.getSession.mockResolvedValue({ data: { session } });
    authState.user = { email: 'fan@example.com' };
    renderAt('/reset-password', <ResetPassword />);
    expect(await screen.findByRole('link', { name: /account settings/i })).toBeTruthy();
    expect(screen.queryByLabelText('New password')).toBeNull();
  });
});

describe('AuthCallback', () => {
  it('returns to ?next= once the session is set', async () => {
    at('/auth/callback?next=%2Fevent%2F7');
    auth.getSession.mockResolvedValue({ data: { session } });
    renderAt('/auth/callback', <AuthCallback />);
    expect(await screen.findByText('event page')).toBeTruthy();
  });

  it('never follows an off-site next', async () => {
    at('/auth/callback?next=https%3A%2F%2Fevil.example%2F');
    auth.getSession.mockResolvedValue({ data: { session } });
    renderAt('/auth/callback', <AuthCallback />);
    expect(await screen.findByText('home page')).toBeTruthy();
  });

  it('sends a recovery token_hash link to /reset-password', async () => {
    at('/auth/callback?token_hash=h&type=recovery');
    auth.verifyOtp.mockResolvedValue({ data: { session }, error: null });
    renderAt('/auth/callback', <AuthCallback />);
    expect(await screen.findByText('reset page')).toBeTruthy();
    expect(auth.verifyOtp).toHaveBeenCalledWith({ token_hash: 'h', type: 'recovery' });
  });

  it('an expired confirmation link offers a resend', async () => {
    at('/auth/callback#error=access_denied&error_code=otp_expired&error_description=expired');
    renderAt('/auth/callback', <AuthCallback />);
    expect((await screen.findByRole('alert')).textContent).toMatch(/expired/);
    fireEvent.change(screen.getByLabelText('Email Address'), { target: { value: 'fan@example.com' } });
    fireEvent.click(screen.getByRole('button', { name: /resend confirmation email/i }));
    await waitFor(() => expect(auth.resend).toHaveBeenCalledWith(expect.objectContaining({ type: 'signup', email: 'fan@example.com' })));
  });

  it('first leg of an email change asks for the other address', async () => {
    at('/auth/callback#message=Confirmation+link+accepted');
    renderAt('/auth/callback', <AuthCallback />);
    expect((await screen.findByText(/open the link we sent to your other address/)).getAttribute('role')).toBe('status');
  });
});
