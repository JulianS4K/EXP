// @vitest-environment jsdom
// The SPA inside the native app (apps/native, docs/native-apps.md): sign-in
// uses the OS sheets (never a redirect out of the app), and the native build
// has no group chat.
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react';
import { MemoryRouter } from 'react-router-dom';

const h = vi.hoisted(() => ({
  native: null as null | { platform: 'ios' | 'android' },
  auth: { signInWithOAuth: vi.fn(), signInWithIdToken: vi.fn() },
}));
vi.mock('../lib/supabase', () => ({ supabase: { auth: h.auth }, initialAuthUrl: '' }));
vi.mock('../lib/platform/native', async (orig) => {
  const real = await orig<typeof import('../lib/platform/native')>();
  return { ...real, currentNativeApp: () => h.native, isNativeApp: () => h.native !== null };
});
vi.mock('../lib/inAppBrowser', async (orig) => {
  const real = await orig<typeof import('../lib/inAppBrowser')>();
  return { ...real, currentInAppBrowser: () => null };
});

import AuthModal from './AuthModal';
import SocialGate from './SocialGate';
import { registerPlatformAdapters, resetPlatformAdapters, type NativeAuthAdapter } from '../lib/platform/adapters';

const openModal = (onClose = vi.fn()) =>
  render(
    <MemoryRouter>
      <AuthModal isOpen onClose={onClose} />
    </MemoryRouter>,
  );

beforeEach(() => {
  h.native = null;
  h.auth.signInWithOAuth.mockReset().mockResolvedValue({ data: {}, error: null });
  h.auth.signInWithIdToken.mockReset().mockResolvedValue({ data: {}, error: null });
});
afterEach(() => {
  cleanup();
  resetPlatformAdapters();
  vi.unstubAllEnvs();
});

describe('sign-in in the native app', () => {
  it('a browser keeps the three redirect buttons', () => {
    openModal();
    for (const name of [/Google/, /Apple/, /Microsoft/]) expect(screen.getByRole('button', { name })).toBeTruthy();
  });

  it('the app shows the native Google and Apple sheets, no Microsoft, and never redirects', async () => {
    h.native = { platform: 'ios' };
    const signIn = vi.fn<NativeAuthAdapter['signIn']>(async () => ({ idToken: 'id.token' }));
    registerPlatformAdapters({ nativeAuth: { providers: () => ['google', 'apple'], signIn } });
    const onClose = vi.fn();
    openModal(onClose);
    expect(screen.queryByRole('button', { name: /Microsoft/ })).toBeNull();
    expect(screen.queryByText(/doesn't work inside/)).toBeNull();
    fireEvent.click(screen.getByRole('button', { name: /Continue with Google/ }));
    await waitFor(() => expect(onClose).toHaveBeenCalled());
    expect(signIn).toHaveBeenCalledWith('google', { nonce: expect.stringMatching(/^[0-9a-f]{64}$/) });
    expect(h.auth.signInWithIdToken).toHaveBeenCalledWith(expect.objectContaining({ provider: 'google', token: 'id.token' }));
    expect(h.auth.signInWithOAuth).not.toHaveBeenCalled();
  });

  it('the app without native sign-in set up offers email only', () => {
    h.native = { platform: 'android' };
    openModal();
    for (const name of [/Google/, /Apple/, /Microsoft/]) expect(screen.queryByRole('button', { name })).toBeNull();
  });
});

describe('group chat in the native build', () => {
  it('stays out of the app even when the social features are on', () => {
    vi.stubEnv('VITE_EXOS_SOCIAL', 'on');
    vi.stubEnv('MODE', 'native');
    render(
      <MemoryRouter>
        <SocialGate feature="chat"><p>chat room</p></SocialGate>
        <SocialGate feature="split"><p>split page</p></SocialGate>
      </MemoryRouter>,
    );
    expect(screen.queryByText('chat room')).toBeNull();
    expect(screen.getByText("Group chat isn't available")).toBeTruthy();
    expect(screen.getByText('split page')).toBeTruthy();
  });

  it('the web build with social on still has it', () => {
    vi.stubEnv('VITE_EXOS_SOCIAL', 'on');
    render(
      <MemoryRouter>
        <SocialGate feature="chat"><p>chat room</p></SocialGate>
      </MemoryRouter>,
    );
    expect(screen.getByText('chat room')).toBeTruthy();
  });
});
