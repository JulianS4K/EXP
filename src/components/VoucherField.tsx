// Buyer voucher entry (pretix-style access token).
//
// A valid voucher may unlock a sold-out tier and/or pin a price. On a successful
// check we report the code + grant up to EventDetails, which then enables the
// buy button (even when sold out) and forwards the code to checkout.

import { useEffect, useRef, useState } from 'react';
import { Ticket, Check } from 'lucide-react';
import { checkVoucher } from '../lib/vouchers';
import { useToast } from '../context/ToastContext';

export interface AppliedVoucher {
  code: string;
  canBypass: boolean;
  /** Server-validated per-ticket price this voucher pins (null = normal price). */
  overridePrice: number | null;
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
  const [code, setCode] = useState(initialCode ?? '');
  const [busy, setBusy] = useState(false);
  const [appliedCode, setAppliedCode] = useState<string | null>(null);

  const apply = async (override?: string) => {
    const c = (override ?? code).trim();
    if (!c) return;
    setBusy(true);
    try {
      const res = await checkVoucher(eventId, c, email);
      if (!res.valid) {
        toast({ kind: 'error', message: voucherErrorMessage(res.reason) });
        setAppliedCode(null);
        onApplied(null);
        return;
      }
      setAppliedCode(c);
      onApplied({ code: c, canBypass: res.canBypass, overridePrice: res.overridePrice, restrictTierId: res.restrictTierId });
      toast({ kind: 'success', message: res.canBypass ? 'Voucher applied — you can buy this event.' : 'Voucher applied.' });
    } catch (e: any) {
      toast({ kind: 'error', message: e?.message || 'Could not check voucher.' });
    } finally {
      setBusy(false);
    }
  };

  const autoApplied = useRef(false);
  useEffect(() => {
    if (initialCode && !autoApplied.current) {
      autoApplied.current = true;
      void apply(initialCode);
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [initialCode]);

  if (appliedCode) {
    return (
      <div className="mb-4 flex items-center gap-2 text-brand-primary text-xs font-black uppercase tracking-widest">
        <Check className="w-4 h-4" />
        Voucher {appliedCode} applied
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
          placeholder="Voucher code"
          aria-label="Voucher code"
          className="w-full bg-black border-2 border-white/15 focus:border-brand-primary outline-none pl-9 pr-3 py-2 text-sm font-bold uppercase"
        />
      </div>
      <button
        type="button"
        disabled={busy || !code.trim()}
        onClick={() => apply()}
        className="px-4 py-2 border-2 border-white/20 hover:border-brand-primary text-white/70 hover:text-brand-primary text-[10px] font-black uppercase tracking-widest transition-all disabled:opacity-40"
      >
        {busy ? '…' : 'Apply'}
      </button>
    </div>
  );
}

/** Buyer-facing copy for exos_check_voucher's reason codes. */
export function voucherErrorMessage(reason: string | null): string {
  switch (reason) {
    case 'expired': return 'That code has expired.';
    case 'already used': return 'That code has already been used.';
    case 'reserved for another buyer': return 'That code is reserved for a different email. Sign in with the email it was sent to.';
    default: return "That code isn't valid for this event. Check the spelling and try again.";
  }
}
