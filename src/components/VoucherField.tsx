// Buyer voucher entry (pretix-style access token).
//
// A valid voucher may unlock a sold-out tier and/or pin a price. On a successful
// check we report the code + grant up to EventDetails, which then enables the
// buy button (even when sold out) and forwards the code to checkout.
//
// Codes need an account (mig 20260929080000): a signed-out buyer who taps
// Apply, or arrives on a link carrying a code, is asked to sign in (the
// emailed 6-digit code keeps them on this page) and the code is applied as
// soon as they are. This keeps code guessing on the per-account throttle.

import { useEffect, useRef, useState } from 'react';
import { Ticket, Check } from 'lucide-react';
import { checkVoucher } from '../lib/vouchers';
import { useToast } from '../context/ToastContext';
import { useAuth } from '../context/AuthContext';
import { useT } from '../context/LanguageContext';
import { translate, type DictKey } from '../lib/i18n/dict';

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
  const t = useT();
  const { user, openAuth } = useAuth();
  const [code, setCode] = useState(initialCode ?? '');
  const [busy, setBusy] = useState(false);
  const [appliedCode, setAppliedCode] = useState<string | null>(null);
  // A code waiting for the buyer to sign in; applied once they have.
  const [pendingCode, setPendingCode] = useState<string | null>(null);

  const apply = async (override?: string) => {
    const c = (override ?? code).trim();
    if (!c) return;
    if (!user) {
      setPendingCode(c);
      openAuth('code');
      return;
    }
    setBusy(true);
    try {
      const res = await checkVoucher(eventId, c, email);
      if (!res.valid) {
        toast({ kind: 'error', message: t(voucherErrorKey(res.reason)) });
        setAppliedCode(null);
        onApplied(null);
        return;
      }
      setAppliedCode(c);
      onApplied({
        code: c, canBypass: res.canBypass, overridePrice: res.overridePrice, restrictTierId: res.restrictTierId,
        discountPercent: res.discountPercent, discountAmount: res.discountAmount,
      });
      toast({ kind: 'success', message: res.canBypass ? t('checkout.promoAppliedBypass') : discountLabel(res) ? t('checkout.promoAppliedWith', { discount: discountLabel(res)! }) : t('checkout.promoApplied') });
    } catch (e: any) {
      toast({ kind: 'error', message: e?.message || t('checkout.promoCheckFailed') });
    } finally {
      setBusy(false);
    }
  };

  // A code from a checkout link: applied on mount when signed in; otherwise it
  // waits in the field until the buyer signs in (no sign-in prompt on load).
  const autoApplied = useRef(false);
  useEffect(() => {
    if (initialCode && !autoApplied.current) {
      if (!user) { setPendingCode(initialCode.trim()); return; }
      autoApplied.current = true;
      void apply(initialCode);
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
        {t('checkout.promoCodeApplied', { code: appliedCode })}
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
          placeholder={t('checkout.promoPlaceholder')}
          aria-label={t('checkout.promoLabel')}
          className="w-full bg-black border-2 border-white/15 focus:border-brand-primary outline-none focus-visible:ring-2 focus-visible:ring-brand-primary/60 pl-9 pr-3 py-2 text-sm font-bold uppercase"
        />
      </div>
      <button
        type="button"
        disabled={busy || !code.trim()}
        onClick={() => apply()}
        className="px-4 py-2 border-2 border-white/20 hover:border-brand-primary text-white/70 hover:text-brand-primary text-[10px] font-black uppercase tracking-widest transition-all disabled:opacity-40"
      >
        {busy ? '…' : user ? t('checkout.promoApply') : t('checkout.promoSignIn')}
      </button>
      {!user && pendingCode && (
        <span className="sr-only" role="status">{t('checkout.promoSignInFor', { code: pendingCode })}</span>
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

/** Buyer-facing copy for exos_check_voucher's reason codes (English). */
export function voucherErrorMessage(reason: string | null): string {
  return translate('en', voucherErrorKey(reason));
}

/** The dictionary key for exos_check_voucher's reason codes (lib/i18n). */
export function voucherErrorKey(reason: string | null): DictKey {
  switch (reason) {
    case 'expired': return 'checkout.promoExpired';
    case 'already used': return 'checkout.promoUsed';
    // The per-account throttle (10 misses / 10 min) answers this even for a
    // right code: "check the spelling" sent buyers retyping a correct code.
    case 'too many attempts': return 'checkout.promoTooMany';
    case 'reserved for another buyer': return 'checkout.promoClaimed';
    default: return 'checkout.promoInvalid';
  }
}
