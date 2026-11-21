// Native Google / Apple sign-in for the auth modal (src/lib/platform/nativeAuth.ts):
// the OS's own sheet through @capgo/capacitor-social-login, which hands back
// an ID token; the SPA then calls supabase.auth.signInWithIdToken. No
// redirect and no Google page inside the web view (Google refuses those).
//
// Client ids are the operator's (docs/native-apps.md "Native sign-in"), read
// at build time. Not secrets, but nothing is hard-coded: a provider with no id
// is simply not offered.
//   VITE_EXOS_GOOGLE_WEB_CLIENT_ID   the Google "Web application" client
//                                    (Android needs it; Supabase's Google
//                                    provider lists it)
//   VITE_EXOS_GOOGLE_IOS_CLIENT_ID   the Google "iOS" client (iOS)
//   VITE_EXOS_APPLE_SIGN_IN=on       Sign in with Apple (iOS; the capability
//                                    is enabled on the App ID)

import { SocialLogin } from '@capgo/capacitor-social-login';
import type { NativeAuthAdapter, NativeIdProvider } from '../../../src/lib/platform/adapters';

type Env = {
  VITE_EXOS_GOOGLE_WEB_CLIENT_ID?: string;
  VITE_EXOS_GOOGLE_IOS_CLIENT_ID?: string;
  VITE_EXOS_APPLE_SIGN_IN?: string;
};

const CLIENT_ID = /^[0-9]+-[a-z0-9]+\.apps\.googleusercontent\.com$/;

export function socialLoginAdapter(platform: 'ios' | 'android', env: Env): NativeAuthAdapter | null {
  const web = (env.VITE_EXOS_GOOGLE_WEB_CLIENT_ID ?? '').trim();
  const ios = (env.VITE_EXOS_GOOGLE_IOS_CLIENT_ID ?? '').trim();
  const google = platform === 'ios' ? CLIENT_ID.test(ios) && CLIENT_ID.test(web) : CLIENT_ID.test(web);
  // Apple on Android is a web redirect through our own backend: not offered.
  const apple = platform === 'ios' && (env.VITE_EXOS_APPLE_SIGN_IN ?? '').trim().toLowerCase() === 'on';
  const providers: NativeIdProvider[] = [];
  if (google) providers.push('google');
  if (apple) providers.push('apple');
  if (providers.length === 0) return null;

  let ready: Promise<void> | null = null;
  const init = () =>
    (ready ??= SocialLogin.initialize({
      ...(google ? { google: { webClientId: web, ...(platform === 'ios' ? { iOSClientId: ios } : {}), mode: 'online' as const } } : {}),
      ...(apple ? { apple: { redirectUrl: '' } } : {}),
    }).catch((err: unknown) => {
      ready = null;
      throw err;
    }));

  const cancelled = (err: unknown) => /cancel/i.test(String((err as { message?: unknown })?.message ?? err));

  return {
    providers: () => [...providers],
    async signIn(provider, { nonce }) {
      if (!providers.includes(provider)) throw new Error(`${provider} sign-in isn't set up in this build.`);
      await init();
      try {
        if (provider === 'google') {
          const { result } = await SocialLogin.login({ provider: 'google', options: { nonce, scopes: ['email', 'profile'] } });
          const idToken = 'idToken' in result ? result.idToken : null;
          if (!idToken) throw new Error('Google did not return an ID token.');
          return { idToken };
        }
        const { result } = await SocialLogin.login({ provider: 'apple', options: { nonce, scopes: ['email', 'name'] } });
        if (!result.idToken) throw new Error('Apple did not return an ID token.');
        return { idToken: result.idToken };
      } catch (err) {
        if (cancelled(err)) return null;
        throw err;
      }
    },
  };
}
