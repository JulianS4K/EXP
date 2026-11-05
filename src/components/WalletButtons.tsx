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
} from '../lib/walletButtons';
import {
  cachedWalletAvailability,
  fetchApplePass,
  fetchGoogleSaveUrl,
  markWalletUnavailable,
  probeWallet,
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
      if (kind === 'apple') {
        const blob = await fetchApplePass(ticket.id);
        const url = URL.createObjectURL(blob);
        if (platform === 'ios') {
          // Safari hands a .pkpass it navigates to straight to Wallet.
          window.location.assign(url);
        } else {
          const a = document.createElement('a');
          a.href = url;
          a.download = `exos-ticket-${ticket.id.slice(0, 8)}.pkpass`;
          document.body.appendChild(a);
          a.click();
          a.remove();
        }
        setTimeout(() => URL.revokeObjectURL(url), 60_000);
      } else {
        const saveUrl = await fetchGoogleSaveUrl(ticket.id);
        // In an Android in-app browser, hand the save link to the real browser.
        window.location.assign((inApp.kind && platform === 'android' ? androidOpenInBrowserUrl(saveUrl) : null) ?? saveUrl);
      }
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
