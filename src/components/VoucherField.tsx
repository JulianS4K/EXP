// Buyer voucher entry (pretix-style access token).
//
// A valid voucher may unlock a sold-out tier and/or pin a price. On a successful
// check we report the code + grant up to EventDetails, which then enables the
// buy button (even when sold out) and forwards the code to checkout.
//
// Guests apply ordinary promo codes too (mig 20261121143700): a signed-out
// buyer's code is checked by exos-checkout on the guest throttle (misses per
// network and per event, never on an account's budget). Codes the server keeps
// for accounts (a capacity-bypass offer, a hidden ticket type, one reserved to
// an email) answer 'sign in required': then the buyer is asked to sign in
// (the emailed 6-digit code keeps them on this page) and the code is applied
// as soon as they are.

import { useEffect, useRef, useState } from 'react';
import { Ticket, Check } from 'lucide-react';
import { checkGuestVoucher, checkVoucher } from '../lib/vouchers';
import { useToast } from '../context/ToastContext';
import { useAuth } from '../context/AuthContext';

export interface AppliedVoucher {
  code: string;
  canBypass: boolean;
  /** Server-validated per-ticket price this voucher pins (null = normal price). */
  overridePrice: number | null;
  /** Promo code: percent / amount off the scheduled price (null = none). */
  discountPercent?: number | null;
  discountAmount?: number | null;
  /** The only tier this voucher works for (null = any); it also unlocks that tier if hidden. */
  restrictTierId: string | null;
}

interface Props {
  eventId: string;
  email?: string | null;
  onApplied: (applied: AppliedVoucher | null) => void;
  /** A code from a checkout link; checked once on mount. */
  initialCode?: string;
}

export default function VoucherField({ eventId, email, onApplied, initialCode }: Props) {
  const { toast } = useToast();
  const { user, openAuth } = useAuth();
  const [code, setCode] = useState(initialCode ?? '');
  const [busy, setBusy] = useState(false);
  const [appliedCode, setAppliedCode] = useState<string | null>(null);
  // A code waiting for the buyer to sign in; applied once they have.
  const [pendingCode, setPendingCode] = useState<string | null>(null);

  // onLoad: a link's code, applied as the page opens: no sign-in prompt then.
  const apply = async (override?: string, onLoad = false) => {
    const c = (override ?? code).trim();
    if (!c) return;
    setBusy(true);
    try {
      const res = user ? await checkVoucher(eventId, c, email) : await checkGuestVoucher(eventId, c);
      if (!user && !res.valid && res.reason === 'sign in required') {
        // Kept for accounts by the server: sign in, then it applies.
        setPendingCode(c);
        if (!onLoad) {
          toast({ kind: 'info', message: 'Sign in to use this code.' });
          openAuth('code');
        }
        return;
      }
      if (!res.valid) {
        toast({ kind: 'error', message: voucherErrorMessage(res.reason) });
        setAppliedCode(null);
        onApplied(null);
        return;
      }
      setAppliedCode(c);
      onApplied({
        code: c, canBypass: res.canBypass, overridePrice: res.overridePrice, restrictTierId: res.restrictTierId,
        discountPercent: res.discountPercent, discountAmount: res.discountAmount,
      });
      toast({ kind: 'success', message: res.canBypass ? 'Code applied: you can buy this event.' : discountLabel(res) ? `Code applied: ${discountLabel(res)}.` : 'Code applied.' });
    } catch (e: any) {
      toast({ kind: 'error', message: e?.message || 'Could not check voucher.' });
    } finally {
      setBusy(false);
    }
  };

  // A code from a checkout link: applied on mount, signed in or not (a code
  // kept for accounts then waits until the buyer signs in).
  const autoApplied = useRef(false);
  useEffect(() => {
    if (initialCode && !autoApplied.current) {
      autoApplied.current = true;
      void apply(initialCode, true);
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [initialCode]);

  useEffect(() => {
    if (!user || !pendingCode || appliedCode) return;
    const c = pendingCode;
    setPendingCode(null);
    autoApplied.current = true;
    void apply(c);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [user?.uid]);

  if (appliedCode) {
    return (
      <div className="mb-4 flex items-center gap-2 text-brand-primary text-xs font-black uppercase tracking-widest">
        <Check className="w-4 h-4" />
        Code {appliedCode} applied
      </div>
    );
  }

  return (
    <div className="mb-4 flex items-center gap-2">
      <div className="relative flex-1">
        <Ticket className="absolute left-3 top-1/2 -translate-y-1/2 w-4 h-4 text-white/30" />
        <input
          value={code}
          onChange={(e) => setCode(e.target.value)}
          onKeyDown={(e) => { if (e.key === 'Enter') apply(); }}
          placeholder="Promo code"
          aria-label="Promo or access code"
          className="w-full bg-black border-2 border-white/15 focus:border-brand-primary outline-none focus-visible:ring-2 focus-visible:ring-brand-primary/60 pl-9 pr-3 py-2 text-sm font-bold uppercase"
        />
      </div>
      <button
        type="button"
        disabled={busy || !code.trim()}
        onClick={() => apply()}
        className="px-4 py-2 border-2 border-white/20 hover:border-brand-primary text-white/70 hover:text-brand-primary text-xs font-black uppercase tracking-widest transition-all disabled:opacity-40"
      >
        {busy ? '…' : 'Apply'}
      </button>
      {!user && pendingCode && (
        <span className="sr-only" role="status">Sign in to use the code {pendingCode}.</span>
      )}
    </div>
  );
}

/** "20% off" / "$5.00 off", or null for a code that doesn't discount. */
export function discountLabel(v: { discountPercent?: number | null; discountAmount?: number | null }): string | null {
  if (v.discountPercent != null && v.discountPercent > 0) return `${Number(v.discountPercent.toFixed(2))}% off`;
  if (v.discountAmount != null && v.discountAmount > 0) return `$${v.discountAmount.toFixed(2)} off`;
  return null;
}

/** Buyer-facing copy for exos_check_voucher's reason codes. */
export function voucherErrorMessage(reason: string | null): string {
  switch (reason) {
    case 'expired': return 'That code has expired.';
    case 'already used': return 'That code has already been used.';
    // The per-account throttle (10 misses / 10 min) answers this even for a
    // right code: "check the spelling" sent buyers retyping a correct code.
    case 'too many attempts': return 'Too many tries. Wait 10 minutes, then enter the code again.';
    case 'reserved for another buyer': return 'That code has already been claimed.';
    default: return "That code isn't valid for this event. Check the spelling and try again.";
  }
}
