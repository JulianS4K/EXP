// Org settings: extra ways buyers can pay (mig 20261031220000).
//   * Venmo / PayPal: the buyer pays the Exos platform's PayPal account; Exos
//     owes the organizer their share and pays it out by hand (not automated).
//     The balance below is what's owed so far.
//   * Cash App Pay: through Stripe, next to cards, paid out like a card sale.
// Owners and managers switch them; finance sees them. Both also need the
// platform switch, so a toggle can be on and the button still hidden.

import { useEffect, useState } from 'react';
import { useToast } from '../context/ToastContext';
import {
  getOrgPaymentMethods, getPayPalBalances, saveOrgPaymentMethods, type OrgPaymentMethods, type PayPalBalance,
} from '../lib/paymentMethods';
import { formatCurrency } from '../lib/utils';

export default function PaymentMethodsPanel({ orgId, canEdit }: { orgId: string; canEdit: boolean }) {
  const { toast } = useToast();
  const [m, setM] = useState<OrgPaymentMethods | null>(null);
  const [bal, setBal] = useState<PayPalBalance[]>([]);
  const [saving, setSaving] = useState(false);

  useEffect(() => {
    let alive = true;
    void getOrgPaymentMethods(orgId).then((x) => alive && setM(x));
    void getPayPalBalances(orgId).then((x) => alive && setBal(x));
    return () => { alive = false; };
  }, [orgId]);

  const flip = async (key: keyof OrgPaymentMethods) => {
    if (!m) return;
    const next = { ...m, [key]: !m[key] };
    if (key === 'paypal' && next.paypal && !window.confirm(
      'Venmo / PayPal payments go to the Exos PayPal account. Exos pays you your share by hand, '
      + 'less the same fees as a card sale. Switch it on?',
    )) return;
    setSaving(true);
    try {
      await saveOrgPaymentMethods(orgId, next);
      setM(next);
    } catch (e) {
      toast({ kind: 'error', message: (e as Error).message });
    } finally {
      setSaving(false);
    }
  };

  if (!m) return null;
  const row = (key: keyof OrgPaymentMethods, title: string, note: string) => (
    <label className="flex items-start gap-3 py-2">
      <input type="checkbox" className="mt-1" checked={m[key]} disabled={!canEdit || saving} onChange={() => void flip(key)} />
      <span>
        <span className="block text-sm font-bold text-slate-800">{title}</span>
        <span className="block text-xs text-slate-400">{note}</span>
      </span>
    </label>
  );
  return (
    <div className="mt-4 pt-4 border-t border-slate-100">
      <p className="text-[10px] font-black uppercase tracking-widest text-slate-400 mb-1">More ways to pay</p>
      {row('paypal', 'Venmo / PayPal', 'Paid to the Exos PayPal account; Exos pays you out by hand.')}
      {row('cashapp', 'Cash App Pay', 'Through Stripe, next to cards (US dollars only).')}
      {bal.map((b) => (
        <p key={b.currency} className="text-xs text-slate-500 mt-2">
          PayPal balance owed to you: <strong>{formatCurrency(b.balanceCents / 100, b.currency)}</strong>
          {b.heldCents > 0 ? ` (plus ${formatCurrency(b.heldCents / 100, b.currency)} held by open disputes)` : ''}
          {b.remittedCents > 0 ? ` · ${formatCurrency(b.remittedCents / 100, b.currency)} paid out so far` : ''}
        </p>
      ))}
    </div>
  );
}
