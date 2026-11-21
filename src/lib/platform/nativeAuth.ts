// Which sign-in buttons the auth modal shows, and how each one signs in.
//
//   oauth   the redirect flow (supabase.auth.signInWithOAuth), as on the web.
//   native  the OS's own Google / Apple sheet in the native app, then
//           supabase.auth.signInWithIdToken (no redirect, no web view login).
//   hidden  not offered here.
//
// Google refuses OAuth inside embedded web views ("disallowed_useragent") and
// Microsoft's flow is unreliable there, so an in-app browser (Instagram, ...)
// hides both; Apple's works. Inside OUR app a redirect would leave the app
// for Safari / Chrome and the session would land there, not in the app, so
// every provider is either native or hidden. Email (password or a 6-digit
// code) works everywhere. App Store 4.8: Google is only offered in the app
// alongside Sign in with Apple, so a build with a Google client id and no
// Apple sign-in hides Google on iOS too.

import type { NativeAuthAdapter, NativeIdProvider } from './adapters';

export type ProviderMode = 'oauth' | 'native' | 'hidden';
export type SignInProvider = 'google' | 'apple' | 'microsoft';
export type ProviderPlan = Record<SignInProvider, ProviderMode>;

export function providerPlan(opts: {
  /** lib/inAppBrowser's kind (null in a real browser and in our app). */
  inApp: string | null;
  native: { platform: 'ios' | 'android' } | null;
  nativeProviders?: readonly NativeIdProvider[];
}): ProviderPlan {
  if (opts.native) {
    const has = new Set(opts.nativeProviders ?? []);
    const apple: ProviderMode = has.has('apple') ? 'native' : 'hidden';
    let google: ProviderMode = has.has('google') ? 'native' : 'hidden';
    if (opts.native.platform === 'ios' && apple === 'hidden') google = 'hidden';
    return { google, apple, microsoft: 'hidden' };
  }
  if (opts.inApp) return { google: 'hidden', apple: 'oauth', microsoft: 'hidden' };
  return { google: 'oauth', apple: 'oauth', microsoft: 'oauth' };
}

function hex(bytes: ArrayBuffer): string {
  return [...new Uint8Array(bytes)].map((b) => b.toString(16).padStart(2, '0')).join('');
}

/** A fresh raw nonce and its SHA-256 (hex): the provider gets the hash, Supabase the raw value. */
export async function newNonce(crypto: Crypto = globalThis.crypto): Promise<{ raw: string; hashed: string }> {
  const bytes = new Uint8Array(32);
  crypto.getRandomValues(bytes);
  const raw = hex(bytes.buffer);
  const hashed = hex(await crypto.subtle.digest('SHA-256', new TextEncoder().encode(raw)));
  return { raw, hashed };
}

interface IdTokenAuth {
  signInWithIdToken(credentials: {
    provider: NativeIdProvider;
    token: string;
    nonce?: string;
    access_token?: string;
  }): Promise<{ error: unknown }>;
}

/**
 * Sign in with the OS's Google / Apple sheet. false = the person cancelled.
 * Throws the provider's or Supabase's error otherwise. The Supabase project's
 * Google / Apple provider must list the app's client ids (docs/native-apps.md).
 */
export async function signInWithNativeIdToken(
  auth: IdTokenAuth,
  adapter: NativeAuthAdapter,
  provider: NativeIdProvider,
  crypto?: Crypto,
): Promise<boolean> {
  const nonce = await newNonce(crypto);
  const got = await adapter.signIn(provider, { nonce: nonce.hashed });
  if (!got) return false;
  if (!got.idToken) throw new Error(`${provider === 'apple' ? 'Apple' : 'Google'} did not return an ID token.`);
  const { error } = await auth.signInWithIdToken({
    provider,
    token: got.idToken,
    nonce: nonce.raw,
    ...(got.accessToken ? { access_token: got.accessToken } : {}),
  });
  if (error) throw error;
  return true;
}
