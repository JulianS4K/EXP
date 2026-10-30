// /gift-cards/balance — check a gift card's balance (docs/gift-cards.md).
// Signed in or out; exos-commerce rate-limits lookups per account / network.

import { useState, type FormEvent } from 'react';
import { Gift } from 'lucide-react';
import { formatGiftCardCode, giftCardBalance, giftCardCheckOk, type GiftCardBalance as Balance } from '../lib/commerce';
import { formatCurrency } from '../lib/utils';

export default function GiftCardBalance() {
  const [code, setCode] = useState('');
  const [res, setRes] = useState<Balance | null>(null);
  const [err, setErr] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  const check = async (e: FormEvent) => {
    e.preventDefault();
    setErr(null); setRes(null);
    if (!giftCardCheckOk(code)) { setErr("That code doesn't look right: check for a typo."); return; }
    setBusy(true);
    try { setRes(await giftCardBalance(code)); } catch (x: any) { setErr(x?.message || 'Could not check that card.'); }
    finally { setBusy(false); }
  };

  return (
    <div className="max-w-md mx-auto px-4 py-16">
      <h1 className="text-2xl font-black mb-6 flex items-center gap-2"><Gift className="w-6 h-6" /> Gift card balance</h1>
      <form onSubmit={check} className="space-y-3">
        <label className="block text-sm" htmlFor="gc-code">Gift card code</label>
        <input id="gc-code" autoComplete="off" spellCheck={false} value={code} placeholder="XXXX-XXXX-XXXX-XXXX"
          onChange={(e) => setCode(e.target.value)} onBlur={() => giftCardCheckOk(code) && setCode(formatGiftCardCode(code))}
          className="w-full border px-3 py-2 font-mono tracking-widest uppercase" />
        <button disabled={busy} className="bg-brand-primary text-black px-4 py-2 font-bold disabled:opacity-40">Check balance</button>
      </form>
      {err && <p role="alert" className="mt-4 text-red-600">{err}</p>}
      {res && (
        <div className="mt-6 border p-4" aria-live="polite">
          <p className="text-sm text-slate-500">{res.org_name} gift card ending {res.last4}</p>
          <p className="text-3xl font-black">{formatCurrency(res.balance_cents / 100, res.currency)}</p>
          {res.expires_at && <p className="text-xs text-slate-500">Expires {res.expires_at.slice(0, 10)}</p>}
        </div>
      )}
    </div>
  );
}
