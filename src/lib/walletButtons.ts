// "Add to Apple Wallet" / "Add to Google Wallet" buttons: PURE helpers
// (docs/wallet.md). No Supabase import, so they unit-test without a client;
// the calls to exos-wallet live in ./walletApi.ts.
//
// Which buttons a device gets:
//   * iPhone / iPad (any browser: they all use WebKit and Apple Wallet) → Apple
//   * Android                                                          → Google
//   * anything else (a desktop browser, macOS Safari included)         → both
//
// Whether a wallet works at all: exos-wallet answers 503 "wallet not
// configured" until the operator adds that wallet's credentials. The SPA
// probes each kind once (a pass request for the nil ticket id: 503 when not
// configured, else 403 "not your ticket", which writes nothing) and keeps the
// answer for the browser session, so a device never shows a broken button.

export type WalletKind = 'apple' | 'google';
export type WalletPlatform = 'ios' | 'android' | 'desktop';

/** The ticket id the availability probe asks for: never a real ticket. */
export const PROBE_TICKET_ID = '00000000-0000-0000-0000-000000000000';

/** sessionStorage key for the per-session probe answers. */
export const WALLET_AVAILABILITY_KEY = 'exos.wallet.availability';

export function detectWalletPlatform(userAgent: string, maxTouchPoints = 0): WalletPlatform {
  const ua = userAgent || '';
  if (/iPhone|iPad|iPod/i.test(ua)) return 'ios';
  // iPadOS 13+ asks for the desktop site and says "Macintosh"; a touch screen
  // gives it away (no Mac has one).
  if (/Macintosh/i.test(ua) && maxTouchPoints > 1) return 'ios';
  if (/Android/i.test(ua)) return 'android';
  return 'desktop';
}

/** The wallets worth offering on a platform, in display order. */
export function walletKindsFor(platform: WalletPlatform): WalletKind[] {
  if (platform === 'ios') return ['apple'];
  if (platform === 'android') return ['google'];
  return ['apple', 'google'];
}

/**
 * What an exos-wallet answer says about a wallet being set up:
 *   503        → false (not configured: hide the button)
 *   2xx / 4xx  → true  (the function got past its configuration check)
 *   else       → null  (network error, 5xx other than 503: unknown, don't cache)
 */
export function availabilityFromStatus(status: number): boolean | null {
  if (status === 503) return false;
  if (status >= 200 && status < 500) return true;
  return null;
}

export type WalletAvailability = Partial<Record<WalletKind, boolean>>;

interface KeyValueStore {
  getItem(key: string): string | null;
  setItem(key: string, value: string): void;
}

/** The cached probe answers; {} when missing, unreadable or malformed. */
export function readWalletAvailability(store: KeyValueStore | null | undefined): WalletAvailability {
  if (!store) return {};
  try {
    const raw = store.getItem(WALLET_AVAILABILITY_KEY);
    if (!raw) return {};
    const parsed = JSON.parse(raw) as unknown;
    if (!parsed || typeof parsed !== 'object') return {};
    const out: WalletAvailability = {};
    for (const k of ['apple', 'google'] as const) {
      const v = (parsed as Record<string, unknown>)[k];
      if (typeof v === 'boolean') out[k] = v;
    }
    return out;
  } catch {
    return {};
  }
}

/** Remember one kind's answer (best effort: storage may be blocked). */
export function writeWalletAvailability(store: KeyValueStore | null | undefined, kind: WalletKind, ok: boolean): WalletAvailability {
  const next = { ...readWalletAvailability(store), [kind]: ok };
  try {
    store?.setItem(WALLET_AVAILABILITY_KEY, JSON.stringify(next));
  } catch {
    /* private mode / blocked storage: the probe just runs again next page */
  }
  return next;
}

/** Buttons to render: the platform's wallets that are known to be set up. */
export function visibleWalletKinds(platform: WalletPlatform, availability: WalletAvailability): WalletKind[] {
  return walletKindsFor(platform).filter((k) => availability[k] === true);
}

/** The platform's wallets nobody has probed yet this session. */
export function unprobedWalletKinds(platform: WalletPlatform, availability: WalletAvailability): WalletKind[] {
  return walletKindsFor(platform).filter((k) => availability[k] === undefined);
}

/**
 * A pass is offered only for a ticket this account holds and can still use:
 * active (not voided / used), not mid-transfer, and owned by the viewer (a
 * ticket given away has a new owner). exos_wallet_issue_pass checks the same.
 */
export function walletEligible(
  ticket: { status?: string | null; pendingTransferId?: string | null; ownerId?: string | null },
  viewerId: string | null | undefined,
): boolean {
  return !!viewerId && ticket.status === 'active' && !ticket.pendingTransferId && ticket.ownerId === viewerId;
}

/**
 * An add-on unit's own entry code (mig 20261108110000) gets wallet buttons
 * while it can still be used: active (not used, not refunded) and its code is
 * drawn for this account (exos_my_addon_passes lists the caller's own passes
 * only; exos_wallet_addon_pass checks the holder again).
 */
export function addonWalletEligible(pass: { status?: string | null; barcodeSecret?: string | null }): boolean {
  return pass.status === 'active' && !!pass.barcodeSecret;
}

/** How many add-on wallet reissues a holder gets in a rolling day (exos_wallet_addon_reissue). */
export const ADDON_REISSUES_PER_DAY = 5;

/**
 * "Reissue" is offered next to an add-on's wallet buttons once the unit is in
 * a wallet (exos_my_addon_passes' wallet_epoch, mig 20261111140000) and can
 * still be used: reissuing rotates the wallet code, so a pass never added has
 * nothing to rotate.
 */
export function addonReissueEligible(pass: { status?: string | null; barcodeSecret?: string | null; walletEpoch?: number | null }): boolean {
  return addonWalletEligible(pass) && typeof pass.walletEpoch === 'number' && pass.walletEpoch >= 1;
}

/** A holder-facing sentence for exos-wallet's 409 reasons and other errors. */
export function walletErrorMessage(reason: string | null | undefined): string {
  switch (reason) {
    case 'not-active':
      return 'This ticket can no longer be added to a wallet.';
    case 'in-transfer':
      return 'Cancel the transfer first, then add the ticket to your wallet.';
    case 'no-secret':
      return "This ticket isn't ready for a wallet yet. Try again in a minute.";
    case 'not your ticket':
      return 'Only the ticket holder can add it to a wallet.';
    case 'voided':
      return 'This add-on was refunded and can no longer be added to a wallet.';
    case 'not your add-on':
      return 'Only the add-on holder can add it to a wallet.';
    case 'rate-limited':
      return `You can reissue add-on wallet passes ${ADDON_REISSUES_PER_DAY} times a day. Try again tomorrow.`;
    case 'no-pass':
      return "This add-on isn't in a wallet yet, so there is nothing to reissue. Add it first.";
    case 'unauthorized':
      return 'Sign in again to add the ticket to your wallet.';
    default:
      return 'Could not create the wallet pass. Try again.';
  }
}

/** Google's save link must go to Google Pay's save page and nowhere else. */
export function isGoogleSaveUrl(url: unknown): url is string {
  if (typeof url !== 'string') return false;
  try {
    const u = new URL(url);
    return u.protocol === 'https:' && u.hostname === 'pay.google.com';
  } catch {
    return false;
  }
}
