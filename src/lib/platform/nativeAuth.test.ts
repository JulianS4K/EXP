// Sign-in buttons per place (browser / in-app browser / our app) and the
// native ID-token sign-in (nonce: hash to the provider, raw to Supabase).
import { webcrypto } from 'node:crypto';
import { createHash } from 'node:crypto';
import { describe, expect, it, vi } from 'vitest';
import { newNonce, providerPlan, signInWithNativeIdToken } from './nativeAuth';
import type { NativeAuthAdapter } from './adapters';

describe('providerPlan', () => {
  it('a browser: every provider by redirect, as today', () => {
    expect(providerPlan({ inApp: null, native: null })).toEqual({ google: 'oauth', apple: 'oauth', microsoft: 'oauth' });
  });

  it('an in-app browser: Apple only (Google refuses web views), as today', () => {
    expect(providerPlan({ inApp: 'instagram', native: null })).toEqual({ google: 'hidden', apple: 'oauth', microsoft: 'hidden' });
    expect(providerPlan({ inApp: 'webview', native: null }).google).toBe('hidden');
  });

  it('our app: the native sheets that are set up, never a redirect', () => {
    const ios = { platform: 'ios' as const };
    const android = { platform: 'android' as const };
    expect(providerPlan({ inApp: null, native: ios, nativeProviders: ['google', 'apple'] })).toEqual({ google: 'native', apple: 'native', microsoft: 'hidden' });
    expect(providerPlan({ inApp: null, native: android, nativeProviders: ['google'] })).toEqual({ google: 'native', apple: 'hidden', microsoft: 'hidden' });
    // Nothing set up: email only.
    expect(providerPlan({ inApp: null, native: ios })).toEqual({ google: 'hidden', apple: 'hidden', microsoft: 'hidden' });
    // App Store 4.8: no Google on iOS without Sign in with Apple next to it.
    expect(providerPlan({ inApp: null, native: ios, nativeProviders: ['google'] }).google).toBe('hidden');
  });
});

describe('signInWithNativeIdToken', () => {
  const crypto = webcrypto as unknown as Crypto;
  const sha = (s: string) => createHash('sha256').update(s).digest('hex');

  it('newNonce: 32 random bytes as hex, and its SHA-256', async () => {
    const n = await newNonce(crypto);
    expect(n.raw).toMatch(/^[0-9a-f]{64}$/);
    expect(n.hashed).toBe(sha(n.raw));
    expect((await newNonce(crypto)).raw).not.toBe(n.raw);
  });

  it('sends the hash to the provider and the raw nonce to Supabase', async () => {
    let asked = '';
    const adapter: NativeAuthAdapter = {
      providers: () => ['apple'],
      signIn: vi.fn(async (_p, { nonce }) => {
        asked = nonce;
        return { idToken: 'eyJ.id.token' };
      }),
    };
    const signInWithIdToken = vi.fn(async () => ({ error: null }));
    expect(await signInWithNativeIdToken({ signInWithIdToken }, adapter, 'apple', crypto)).toBe(true);
    const sent = (signInWithIdToken.mock.calls[0] as unknown[])[0] as { provider: string; token: string; nonce: string };
    expect(sent).toMatchObject({ provider: 'apple', token: 'eyJ.id.token' });
    expect(sha(sent.nonce)).toBe(asked);
  });

  it('a cancel is not an error; a Supabase refusal is', async () => {
    const cancelled: NativeAuthAdapter = { providers: () => ['google'], signIn: async () => null };
    const signInWithIdToken = vi.fn(async () => ({ error: null }));
    expect(await signInWithNativeIdToken({ signInWithIdToken }, cancelled, 'google', crypto)).toBe(false);
    expect(signInWithIdToken).not.toHaveBeenCalled();

    const ok: NativeAuthAdapter = { providers: () => ['google'], signIn: async () => ({ idToken: 't', accessToken: 'a' }) };
    const refused = vi.fn(async () => ({ error: new Error('Unacceptable audience in id_token') }));
    await expect(signInWithNativeIdToken({ signInWithIdToken: refused }, ok, 'google', crypto)).rejects.toThrow(/audience/);
    expect((refused.mock.calls[0] as unknown[])[0]).toMatchObject({ access_token: 'a' });

    const empty: NativeAuthAdapter = { providers: () => ['google'], signIn: async () => ({ idToken: '' }) };
    await expect(signInWithNativeIdToken({ signInWithIdToken }, empty, 'google', crypto)).rejects.toThrow(/ID token/);
  });
});
