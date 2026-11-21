// The native app's platform installer. vite --mode native aliases
// '@exos/platform-install' (src/main.tsx) to this file, so it runs once,
// before React mounts, and registers the Capacitor-backed adapters
// (src/lib/platform/adapters.ts). Plugin imports resolve from
// apps/native/node_modules: none of this is in the web build.
//
// Opened in a plain browser (debugging the www/ bundle), Capacitor reports
// "web" and nothing is registered: the web defaults stand.

import { Capacitor, registerPlugin } from '@capacitor/core';
import { App } from '@capacitor/app';
import { Browser } from '@capacitor/browser';
import { Preferences } from '@capacitor/preferences';
import { KeepAwake } from '@capacitor-community/keep-awake';
import { registerPlatformAdapters, type DurableStore, type WalletAdapter } from '../../../src/lib/platform/adapters';
import { appRouteForUrl } from '../../../src/lib/platform/deepLinks';
import { nativeWebBase } from '../../../src/lib/platform/native';
import { mlkitScanner } from './scanner';
import { socialLoginAdapter } from './auth';

type Env = {
  VITE_EXOS_WEB_URL?: string;
  VITE_EXOS_APP_LINK_HOSTS?: string;
  VITE_EXOS_GOOGLE_WEB_CLIENT_ID?: string;
  VITE_EXOS_GOOGLE_IOS_CLIENT_ID?: string;
  VITE_EXOS_APPLE_SIGN_IN?: string;
  MODE?: string;
};

const env = (import.meta.env ?? {}) as Env;

/** Where the app opens: the door (it is Exos Door). */
const START_ROUTE = '/door';

const preferencesStore: DurableStore = {
  async get(key) {
    return (await Preferences.get({ key })).value;
  },
  async set(key, value) {
    try {
      await Preferences.set({ key, value });
      return true;
    } catch {
      return false;
    }
  },
  async remove(key) {
    await Preferences.remove({ key }).catch(() => {});
  },
};

interface ExosWalletPlugin {
  canAddPasses(): Promise<{ value: boolean }>;
  addPass(opts: { data: string }): Promise<{ shown: boolean }>;
}
// The app's own iOS plugin (ios/App/App/ExosWalletPlugin.swift).
const ExosWallet = registerPlugin<ExosWalletPlugin>('ExosWallet');

async function blobToBase64(blob: Blob): Promise<string> {
  const bytes = new Uint8Array(await blob.arrayBuffer());
  let bin = '';
  for (let i = 0; i < bytes.length; i += 0x8000) bin += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
  return btoa(bin);
}

function walletAdapter(platform: 'ios' | 'android'): WalletAdapter {
  return {
    async deliver(kind, source) {
      if (kind === 'google') {
        // The save link in Custom Tabs / Safari View, where the Google account is.
        await Browser.open({ url: await source.google() });
        return true;
      }
      if (platform !== 'ios') return false;
      if (!Capacitor.isPluginAvailable('ExosWallet')) throw new Error('Apple Wallet needs the latest version of the app.');
      await ExosWallet.addPass({ data: await blobToBase64(await source.apple()) });
      return true;
    },
  };
}

function isExternalHttps(url: string): boolean {
  try {
    const u = new URL(url, window.location.href);
    return u.protocol === 'https:' && u.origin !== window.location.origin;
  } catch {
    return false;
  }
}

export function installPlatform(): void {
  if (!Capacitor.isNativePlatform()) return;
  const platform = Capacitor.getPlatform() === 'ios' ? 'ios' : 'android';
  const webBase = nativeWebBase(env);
  const linkHosts = (env.VITE_EXOS_APP_LINK_HOSTS ?? '').split(',').map((h) => h.trim()).filter(Boolean);

  // Exos Door opens on the door, not the buyer home page.
  if (window.location.pathname === '/' && !window.location.search) window.history.replaceState(null, '', START_ROUTE);

  // Coming back from the browser sheet (checkout) goes to this route, once.
  let returnTo: string | null = null;
  void Browser.addListener('browserFinished', () => {
    const to = returnTo;
    returnTo = null;
    if (to) window.location.assign(to);
  });

  // Universal Links / App Links (apps/native/deep-links): only the routes the
  // app claims, only on its own hosts (src/lib/platform/deepLinks.ts).
  void App.addListener('appUrlOpen', ({ url }) => {
    const route = appRouteForUrl(url, webBase, linkHosts);
    if (!route) return;
    returnTo = null;
    void Browser.close().catch(() => {});
    window.location.assign(route);
  });

  registerPlatformAdapters({
    scanner: mlkitScanner(),
    walletAdd: walletAdapter(platform),
    storage: preferencesStore,
    async openExternal(url) {
      const abs = new URL(url, webBase ?? window.location.href).toString();
      await Browser.open({ url: abs });
    },
    async openCheckout(url, opts) {
      // One of our own pages (a free order, a gift card that covered it
      // all): stay in the app, on its own copy of the page.
      if (webBase && url.startsWith(`${webBase}/`)) {
        window.location.assign(url.slice(webBase.length));
        return;
      }
      if (!isExternalHttps(url)) {
        window.location.assign(url);
        return;
      }
      // Stripe's hosted Checkout in the browser sheet: Apple Pay / Google Pay
      // work there, and no card field ever loads in the app (docs/pci.md).
      returnTo = opts.returnTo;
      await Browser.open({ url, presentationStyle: 'fullscreen' });
    },
    nativeAuth: socialLoginAdapter(platform, env),
    door: {
      async keepAwake(on) {
        if (on) await KeepAwake.keepAwake();
        else await KeepAwake.allowSleep();
      },
    },
  });
}
