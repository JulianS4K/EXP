// "Add to Apple Wallet" / "Add to Google Wallet" for one ticket (docs/wallet.md).
//
// Renders nothing unless: the viewer holds the ticket and can still use it
// (active, not in transfer), the device suits that wallet (Apple on iPhone /
// iPad, Google on Android, both on a desktop), and exos-wallet says the wallet
// is set up (a once-per-session probe; 503 = not configured). Styling follows
// the official badges loosely: black, rounded, "Add to … Wallet" text. No
// external badge images (CSP).
//
// Inside an in-app browser (Instagram, Facebook, ...): a .pkpass never reaches
// Apple Wallet from there, so iOS gets the "open in Safari" escape instead of
// the button; Google's save link needs the Google account the app's browser
// doesn't have, so Android opens it in the real browser (an intent: link).

import { useEffect, useMemo, useState } from 'react';
import { Wallet } from 'lucide-react';
import { useAuth } from '../context/AuthContext';
import { useToast } from '../context/ToastContext';
import {
  detectWalletPlatform,
  unprobedWalletKinds,
  visibleWalletKinds,
  walletEligible,
  type WalletAvailability,
  type WalletKind,
  type WalletPlatform,
} from '../lib/walletButtons';
import {
  cachedWalletAvailability,
  fetchAddonPassApple,
  fetchAddonPassGoogleUrl,
  fetchApplePass,
  fetchGoogleSaveUrl,
  markWalletUnavailable,
  probeWallet,
  reissueAddonPassApple,
  reissueAddonPassGoogleUrl,
  reissueAddonPassOnly,
  WalletUnavailableError,
} from '../lib/walletApi';
import { androidOpenInBrowserUrl, currentInAppState, IN_APP_LABEL } from '../lib/inAppBrowser';
import { EscapeHatch } from './InAppBrowserBanner';

interface WalletTicket {
  id: string;
  status?: string | null;
  pendingTransferId?: string | null;
  ownerId?: string | null;
}

const LABEL: Record<WalletKind, string> = {
  apple: 'Add to Apple Wallet',
  google: 'Add to Google Wallet',
};

function currentPlatform() {
  if (typeof navigator === 'undefined') return 'desktop' as const;
  return detectWalletPlatform(navigator.userAgent, navigator.maxTouchPoints ?? 0);
}

/**
 * The wallets this device can use right now: the platform's kinds that the
 * session probe found set up. Probes (once per session) while `enabled`.
 */
export function useAvailableWallets(enabled: boolean) {
  const platform = useMemo(currentPlatform, []);
  const [availability, setAvailability] = useState<WalletAvailability>(() => cachedWalletAvailability());

  useEffect(() => {
    if (!enabled) return undefined;
    const todo = unprobedWalletKinds(platform, availability);
    if (todo.length === 0) return undefined;
    let alive = true;
    void Promise.all(todo.map((k) => probeWallet(k))).then(() => {
      if (alive) setAvailability(cachedWalletAvailability());
    });
    return () => {
      alive = false;
    };
    // Probe once per mount; answers land in the session cache.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [enabled, platform]);

  return {
    platform,
    kinds: enabled ? visibleWalletKinds(platform, availability) : [],
    markUnavailable: (kind: WalletKind) => setAvailability(markWalletUnavailable(kind)),
  };
}

/**
 * Hand a pass to the wallet: Apple's .pkpass bytes (iOS: Safari opens a
 * .pkpass it navigates to in Wallet; elsewhere it downloads), Google's save
 * link (an Android in-app browser hands it to the real browser).
 */
async function deliverPass(
  kind: WalletKind, platform: WalletPlatform, inApp: string | null | undefined,
  apple: () => Promise<Blob>, google: () => Promise<string>, fileName: string,
): Promise<void> {
  if (kind === 'apple') {
    const url = URL.createObjectURL(await apple());
    if (platform === 'ios') {
      window.location.assign(url);
    } else {
      const a = document.createElement('a');
      a.href = url;
      a.download = fileName;
      document.body.appendChild(a);
      a.click();
      a.remove();
    }
    setTimeout(() => URL.revokeObjectURL(url), 60_000);
    return;
  }
  const saveUrl = await google();
  window.location.assign((inApp && platform === 'android' ? androidOpenInBrowserUrl(saveUrl) : null) ?? saveUrl);
}

/**
 * "Add to … Wallet" for one add-on unit with its own entry code
 * (POST /exos-wallet/addon-pass, docs/wallet.md "Add-on passes"). The card
 * passes the wallets the session probe found set up (useAvailableWallets), so
 * the buttons stay hidden exactly when the ticket's do. Inside an iOS in-app
 * browser Apple's button is left out: the ticket's "open in Safari" escape on
 * the same page covers it.
 */
export function AddonWalletButtons({ passId, name, kinds, platform, onUnavailable, canReissue = false }: {
  passId: string;
  /** The add-on as the holder sees it ("VIP lounge · 1 of 2"): part of each button's name. */
  name: string;
  kinds: WalletKind[];
  platform: WalletPlatform;
  onUnavailable: (kind: WalletKind) => void;
  /** The unit is in a wallet (addonReissueEligible): offer "Reissue" (mig 20261111140000). */
  canReissue?: boolean;
}) {
  const { toast } = useToast();
  const [busy, setBusy] = useState<WalletKind | 'reissue' | null>(null);
  const [confirming, setConfirming] = useState(false);
  const [inApp] = useState(currentInAppState);
  const shown = kinds.filter((k) => !(k === 'apple' && inApp.kind && platform === 'ios'));
  if (shown.length === 0) return null;
  const fail = (kind: WalletKind | null, err: unknown) => {
    if (err instanceof WalletUnavailableError && kind) {
      onUnavailable(kind);
      toast({ kind: 'warn', message: `${kind === 'apple' ? 'Apple' : 'Google'} Wallet isn't available right now.` });
    } else {
      toast({ kind: 'error', message: err instanceof Error ? err.message : 'Could not create the wallet pass.' });
    }
  };
  const add = async (kind: WalletKind) => {
    setBusy(kind);
    try {
      await deliverPass(kind, platform, inApp.kind, () => fetchAddonPassApple(passId), () => fetchAddonPassGoogleUrl(passId),
        `exos-addon-${passId.slice(0, 8)}.pkpass`);
    } catch (err) {
      fail(kind, err);
    } finally {
      setBusy(null);
    }
  };
  // "My pass leaked": a new code for this add-on; the old wallet code stops
  // working at the door. One wallet on this device: the new pass goes straight
  // to it. Both (a desktop): rotate only, then the holder adds it again.
  const reissue = async () => {
    setBusy('reissue');
    const only = shown.length === 1 ? shown[0] : null;
    try {
      if (only) {
        await deliverPass(only, platform, inApp.kind, () => reissueAddonPassApple(passId), () => reissueAddonPassGoogleUrl(passId),
          `exos-addon-${passId.slice(0, 8)}.pkpass`);
        toast({ kind: 'success', message: 'Reissued: the old wallet code no longer works.' });
      } else {
        await reissueAddonPassOnly(passId);
        toast({ kind: 'success', message: 'Reissued: the old wallet code no longer works. Add the new pass to your wallet.' });
      }
      setConfirming(false);
    } catch (err) {
      fail(only, err);
    } finally {
      setBusy(null);
    }
  };
  return (
    <div className="flex flex-col items-center gap-2">
      <div className="flex flex-wrap justify-center gap-2" data-testid="addon-wallet-buttons">
        {shown.map((kind) => (
          <button
            key={kind}
            type="button"
            onClick={() => void add(kind)}
            disabled={busy !== null}
            aria-label={`${LABEL[kind]}: ${name}`}
            className="inline-flex items-center justify-center gap-2 rounded-lg bg-black text-white border border-white/30 hover:border-white font-semibold transition-colors disabled:opacity-50 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-brand-primary px-3 py-2 text-xs"
          >
            <Wallet className="w-3.5 h-3.5" aria-hidden="true" />
            {busy === kind ? 'Preparing…' : LABEL[kind]}
          </button>
        ))}
      </div>
      {canReissue && (confirming ? (
        <div className="flex flex-wrap items-center justify-center gap-2 text-[11px]" role="group" aria-label={`Reissue wallet pass: ${name}`}>
          <span className="type text-white/70">The old wallet code for this add-on will stop working.</span>
          <button
            type="button"
            onClick={() => void reissue()}
            disabled={busy !== null}
            className="type underline text-white hover:text-brand-primary disabled:opacity-50 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-brand-primary"
          >
            {busy === 'reissue' ? 'Reissuing…' : 'Reissue now'}
          </button>
          <button
            type="button"
            onClick={() => setConfirming(false)}
            disabled={busy !== null}
            className="type underline text-white/60 hover:text-white disabled:opacity-50 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-brand-primary"
          >
            Cancel
          </button>
        </div>
      ) : (
        <button
          type="button"
          onClick={() => setConfirming(true)}
          disabled={busy !== null}
          aria-label={`Reissue wallet pass: ${name}`}
          className="type text-[11px] underline text-white/60 hover:text-white disabled:opacity-50 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-brand-primary"
        >
          Reissue
        </button>
      ))}
    </div>
  );
}

export default function WalletButtons({ ticket, compact = false, className = '' }: {
  ticket: WalletTicket;
  /** Smaller buttons for lists (My Tickets). */
  compact?: boolean;
  className?: string;
}) {
  const { user } = useAuth();
  const { toast } = useToast();
  const [busy, setBusy] = useState<WalletKind | null>(null);
  const { platform, kinds, markUnavailable } = useAvailableWallets(walletEligible(ticket, user?.uid));
  const [inApp] = useState(currentInAppState);
  if (kinds.length === 0) return null;
  if (inApp.kind && platform === 'ios' && kinds.includes('apple')) {
    return (
      <EscapeHatch
        state={inApp}
        reasons={[]}
        lead={`Apple Wallet can't add tickets from inside ${IN_APP_LABEL[inApp.kind]}. Open this page in Safari, sign in with the same email, then tap Add to Apple Wallet.`}
        className={`type text-[11px] text-white/70 border border-white/10 p-3 ${className}`}
      />
    );
  }

  const add = async (kind: WalletKind) => {
    setBusy(kind);
    try {
      await deliverPass(kind, platform, inApp.kind, () => fetchApplePass(ticket.id), () => fetchGoogleSaveUrl(ticket.id),
        `exos-ticket-${ticket.id.slice(0, 8)}.pkpass`);
    } catch (err) {
      if (err instanceof WalletUnavailableError) {
        markUnavailable(kind);
        toast({ kind: 'warn', message: `${kind === 'apple' ? 'Apple' : 'Google'} Wallet isn't available right now.` });
      } else {
        toast({ kind: 'error', message: err instanceof Error ? err.message : 'Could not create the wallet pass.' });
      }
    } finally {
      setBusy(null);
    }
  };

  return (
    <div className={`flex flex-wrap gap-2 ${className}`}>
      {kinds.map((kind) => (
        <button
          key={kind}
          type="button"
          onClick={() => void add(kind)}
          disabled={busy !== null}
          className={`inline-flex items-center justify-center gap-2 rounded-lg bg-black text-white border border-white/30 hover:border-white font-semibold transition-colors disabled:opacity-50 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-brand-primary ${compact ? 'px-3 py-2 text-xs' : 'flex-1 min-w-[12rem] px-4 py-3 text-sm'}`}
        >
          <Wallet className={compact ? 'w-3.5 h-3.5' : 'w-4 h-4'} aria-hidden="true" />
          {busy === kind ? 'Preparing…' : LABEL[kind]}
        </button>
      ))}
    </div>
  );
}
