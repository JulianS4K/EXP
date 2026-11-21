// Exos Door: the Capacitor shell around the bundled Exos SPA (docs/native-apps.md).
//
// The SPA is BUNDLED (webDir), never loaded from a remote server.url: App
// Store 4.7.2 / 2.5.2 forbid an app whose code is fetched at run time, and a
// bundled build keeps the door working with no network at all.
//
// The app id and name are placeholders the operator sets before the first
// store upload (the id can't change after that): docs/native-apps.md
// "Operator steps".
import type { CapacitorConfig } from '@capacitor/cli';

const config: CapacitorConfig = {
  appId: 'com.exos.door',
  appName: 'Exos Door',
  // vite build --mode native writes here (root vite.config.ts).
  webDir: 'www',
  // The SPA reads this token to know it runs inside the app, not an in-app
  // browser (src/lib/platform/native.ts). Bump it with the bridge contract.
  appendUserAgent: 'ExosApp/1',
  // No remote server.url, no cleartext: everything the app shows is in www/.
  // Requests to Supabase / the Exos API are ordinary HTTPS fetches; any
  // top-level navigation off the app's own origin (Stripe Checkout, Google
  // Wallet, a link out) opens outside the web view (the SPA uses the
  // in-app browser sheet for those, src/lib/platform/adapters.ts).
  server: {
    androidScheme: 'https',
    cleartext: false,
  },
  ios: {
    contentInset: 'never',
    // WKWebView: no link previews on long-press at the door.
    allowsLinkPreview: false,
  },
  android: {
    allowMixedContent: false,
    // Debugging the web view needs a debug build (chrome://inspect).
    webContentsDebuggingEnabled: false,
  },
  plugins: {
    // Only Google and Apple are compiled in (no Facebook SDK, no Twitter).
    // Client ids are not secrets but they ARE the operator's: they are read
    // at build time from VITE_EXOS_GOOGLE_* (apps/native/src/auth.ts).
    SocialLogin: {
      providers: { google: true, apple: true, facebook: false, twitter: false },
      logLevel: 1,
    },
  },
};

export default config;
