// Platform adapters: the few things the native app (apps/native) does
// differently from a browser, behind one interface with WEB DEFAULTS. The web
// build never registers anything, so every caller keeps today's browser
// behaviour; the native build's installer (apps/native/src/install.ts,
// swapped in for ./install.web.ts by vite --mode native) registers the
// Capacitor-backed versions before React mounts. docs/native-apps.md.
//
//   scanner      the door camera. null = the page's own html5-qrcode scanner.
//   walletAdd    hand a pass to Apple / Google Wallet. Web: false (not
//                handled), so WalletButtons does what it does today.
//   storage      a small durable key-value store. Web: localStorage. Native:
//                Capacitor Preferences (UserDefaults / SharedPreferences),
//                which iOS doesn't evict like web view storage.
//   openExternal a page outside the app. Web: a new tab. Native: the in-app
//                browser sheet (SFSafariViewController / Custom Tabs).
//   openCheckout leave for Stripe's hosted Checkout. Web: same-tab redirect,
//                exactly as before. Native: the browser sheet (Apple Pay works
//                there, never in our web view), back to `returnTo` when it
//                closes. The app never hosts a card field (docs/pci.md).
//   nativeAuth   Google / Apple sign-in with the OS's own sheet, for
//                supabase.auth.signInWithIdToken (./nativeAuth.ts). null on
//                the web: the redirect flow stays.
//   door         keep the screen on and give scan feedback while the door is open.

export type WalletKindLike = 'apple' | 'google';

export interface PassSource {
  /** Apple: the .pkpass bytes (fetched on demand). */
  apple: () => Promise<Blob>;
  /** Google: the "save to Google Wallet" link (fetched on demand). */
  google: () => Promise<string>;
}

export interface WalletAdapter {
  /** true when the pass was handed over; false = not handled here (use the web path). */
  deliver(kind: WalletKindLike, source: PassSource): Promise<boolean>;
}

/** What the door's status shows after a read (OrganizerCheckIn's `status`). */
export type DoorScanStatus = 'idle' | 'searching' | 'success' | 'not-found' | 'already-used' | 'invalid-barcode' | 'needs-reason' | 'by-name';

export interface NativeScanSession {
  stop(): Promise<void>;
}

export interface ScannerAdapter {
  /** Open the camera and call onCode for each (deduplicated) read until stop().
   *  onClose: the person closed the camera from the native overlay. */
  start(opts: { onCode: (text: string) => void; onClose?: () => void }): Promise<NativeScanSession>;
  /** The door's answer to the last read (overlay colour, haptic). */
  showStatus?(status: DoorScanStatus): void;
}

export interface DurableStore {
  get(key: string): Promise<string | null>;
  set(key: string, value: string): Promise<boolean>;
  remove(key: string): Promise<void>;
}

export type NativeIdProvider = 'google' | 'apple';

export interface NativeIdToken {
  idToken: string;
  accessToken?: string;
}

export interface NativeAuthAdapter {
  /** The providers configured in this build (client ids set). */
  providers(): NativeIdProvider[];
  /** The OS sign-in sheet; `nonce` is the SHA-256 (hex) of the raw nonce. null = cancelled. */
  signIn(provider: NativeIdProvider, opts: { nonce: string }): Promise<NativeIdToken | null>;
  /** Drop what the plugin kept of that sign-in (the identity token, in UserDefaults / backups):
   *  the Supabase session is the app's login from then on. */
  forget?(provider: NativeIdProvider): Promise<void>;
}

export interface DoorAdapter {
  keepAwake(on: boolean): Promise<void>;
}

export interface PlatformAdapters {
  scanner: ScannerAdapter | null;
  walletAdd: WalletAdapter;
  storage: DurableStore;
  openExternal(url: string): Promise<void>;
  openCheckout(url: string, opts: { returnTo: string }): Promise<void>;
  nativeAuth: NativeAuthAdapter | null;
  door: DoorAdapter | null;
}

function webStorage(): Storage | null {
  try {
    return typeof localStorage !== 'undefined' ? localStorage : null;
  } catch {
    return null;
  }
}

export const webDurableStore: DurableStore = {
  async get(key) {
    try {
      return webStorage()?.getItem(key) ?? null;
    } catch {
      return null;
    }
  },
  async set(key, value) {
    const s = webStorage();
    if (!s) return false;
    try {
      s.setItem(key, value);
      return true;
    } catch {
      return false;
    }
  },
  async remove(key) {
    try {
      webStorage()?.removeItem(key);
    } catch {
      /* storage blocked */
    }
  },
};

/** Today's browser behaviour, unchanged. */
export const WEB_ADAPTERS: PlatformAdapters = {
  scanner: null,
  walletAdd: { deliver: async () => false },
  storage: webDurableStore,
  async openExternal(url) {
    if (typeof window !== 'undefined') window.open(url, '_blank', 'noopener');
  },
  async openCheckout(url) {
    if (typeof window !== 'undefined') window.location.href = url; // leave the SPA for Stripe-hosted checkout
  },
  nativeAuth: null,
  door: null,
};

let current: PlatformAdapters = WEB_ADAPTERS;

/** The adapters for this page (web defaults unless the native installer ran). */
export function platform(): PlatformAdapters {
  return current;
}

/** Native installer only (and tests): replace some adapters. */
export function registerPlatformAdapters(over: Partial<PlatformAdapters>): void {
  current = { ...current, ...over };
}

/** For tests: back to the web defaults. */
export function resetPlatformAdapters(): void {
  current = WEB_ADAPTERS;
}
