// Organizer voucher manager (pretix-style access tokens).
//
// Self-contained CRUD embedded in EditEvent (light theme). Mints access codes
// that can unlock one ticket type (how a hidden presale tier is sold), bypass
// sold-out capacity, pin a price, and/or be reserved to one email. The code can
// be chosen ("PRESALE") and matches in any case. Distinct from discount codes.

import { useEffect, useState } from 'react';
import { Plus, Trash2, Ticket, Copy } from 'lucide-react';
import { issueVoucher, listVouchers, deleteVoucher, type Voucher } from '../lib/vouchers';
import { useToast } from '../context/ToastContext';

const inputCls =
  'w-full bg-slate-50 border-2 border-transparent rounded-2xl py-3 px-5 text-slate-900 font-bold ' +
  'focus:outline-none focus:border-brand-primary focus:bg-white transition-all shadow-inner';

interface TierOption { id: string; name: string; visibility?: string | null }

export default function VouchersEditor({ eventId, tiers = [] }: { eventId: string; tiers?: TierOption[] }) {
  const { toast } = useToast();
  const [rows, setRows] = useState<Voucher[]>([]);
  const [loading, setLoading] = useState(true);
  const [busy, setBusy] = useState(false);
  const [reservedEmail, setReservedEmail] = useState('');
  const [priceOverride, setPriceOverride] = useState('');
  const [comment, setComment] = useState('');
  const [code, setCode] = useState('');
  const [tierId, setTierId] = useState('');
  const [maxUses, setMaxUses] = useState('1');
  const [bypass, setBypass] = useState(true);

  const reload = async () => {
    try { setRows(await listVouchers(eventId)); }
    catch (e) { console.error('listVouchers failed:', e); }
    finally { setLoading(false); }
  };
  useEffect(() => { reload(); /* eslint-disable-next-line */ }, [eventId]);

  const generate = async () => {
    setBusy(true);
    try {
      const made = await issueVoucher({
        eventId,
        code: code.trim() || null,
        tierId: tierId || null,
        maxUses: Math.max(1, parseInt(maxUses, 10) || 1),
        reservedEmail: reservedEmail.trim() || null,
        bypassCapacity: bypass,
        priceOverride: priceOverride.trim() ? Math.max(0, parseFloat(priceOverride)) : null,
        comment: comment.trim() || null,
      });
      setReservedEmail(''); setPriceOverride(''); setComment(''); setCode(''); setTierId(''); setMaxUses('1'); setBypass(true);
      await reload();
      toast({ kind: 'success', message: `Voucher ${made} created.` });
    } catch (e: any) {
      toast({ kind: 'error', message: e?.message || 'Could not create voucher.' });
    } finally {
      setBusy(false);
    }
  };

  const copy = (text: string) =>
    navigator.clipboard.writeText(text)
      .then(() => toast({ kind: 'success', message: 'Code copied.' }))
      .catch(() => toast({ kind: 'error', message: 'Copy failed.' }));

  if (loading) return null;

  return (
    <section className="bg-white p-10 rounded-[3rem] border border-slate-100 shadow-xl space-y-6">
      <div className="flex items-center space-x-3 mb-2">
        <Ticket className="text-brand-primary w-5 h-5" />
        <h2 className="text-xs font-bold text-slate-400 uppercase tracking-widest leading-none">Vouchers</h2>
      </div>
      <p className="text-slate-400 text-xs font-bold -mt-2">
        Access codes. Lock one to a hidden ticket type to run a presale (buyers enter the code to see it), let holders buy even when sold out, pin a price, or reserve it to one email. Different from discount codes.
      </p>

      {rows.length > 0 && (
        <div className="space-y-2">
          {rows.map((v) => (
            <div key={v.id} className="flex items-center justify-between bg-slate-50 rounded-2xl px-5 py-3">
              <div className="min-w-0 pr-3">
                <p className="font-mono font-bold text-slate-900 text-sm truncate flex items-center gap-2">
                  {v.code}
                  <button type="button" onClick={() => copy(v.code)} className="text-slate-300 hover:text-slate-600" aria-label="Copy code">
                    <Copy className="w-3.5 h-3.5" />
                  </button>
                </p>
                <p className="text-slate-400 text-xs font-bold">
                  {v.usedCount}/{v.maxUses} used
                  {v.tierId ? ` · ${tiers.find((t) => t.id === v.tierId)?.name ?? 'one ticket type'}` : ''}
                  {v.bypassCapacity ? ' · bypass' : ''}
                  {v.priceOverride != null ? ` · $${Number(v.priceOverride).toFixed(2)}` : ''}
                  {v.reservedEmail ? ` · ${v.reservedEmail}` : ''}
                  {v.comment ? ` · ${v.comment}` : ''}
                </p>
              </div>
              <button type="button" onClick={() => deleteVoucher(v.id).then(reload)} className="text-slate-300 hover:text-red-500 shrink-0" aria-label={`Delete ${v.code}`}>
                <Trash2 className="w-4 h-4" />
              </button>
            </div>
          ))}
        </div>
      )}

      <div className="grid grid-cols-2 gap-4">
        <input value={code} onChange={(e) => setCode(e.target.value.toUpperCase().replace(/[^A-Z0-9_-]/g, '').slice(0, 32))} placeholder="Code, e.g. PRESALE (blank = random)" aria-label="Voucher code" className={inputCls} />
        <input value={maxUses} onChange={(e) => setMaxUses(e.target.value)} type="number" min={1} step={1} placeholder="Uses" aria-label="Number of uses" className={inputCls} />
        {tiers.length > 0 && (
          <select value={tierId} onChange={(e) => setTierId(e.target.value)} aria-label="Ticket type" className={`col-span-2 ${inputCls}`}>
            <option value="">Any ticket type</option>
            {tiers.filter((t) => t.id).map((t) => (
              <option key={t.id} value={t.id}>{t.name}{t.visibility === 'hidden' ? ' (hidden: presale)' : ''}</option>
            ))}
          </select>
        )}
        <label className="col-span-2 flex items-center gap-2 text-xs font-bold text-slate-500">
          <input type="checkbox" checked={bypass} onChange={(e) => setBypass(e.target.checked)} />
          Holders can buy even when sold out
        </label>
        <input value={reservedEmail} onChange={(e) => setReservedEmail(e.target.value)} placeholder="Reserve to email (optional)" className={`col-span-2 ${inputCls}`} />
        <input value={priceOverride} onChange={(e) => setPriceOverride(e.target.value)} type="number" min={0} step="0.01" placeholder="Price override $ (optional)" className={inputCls} />
        <input value={comment} onChange={(e) => setComment(e.target.value)} placeholder="Note (optional)" className={inputCls} />
      </div>
      <button type="button" disabled={busy} onClick={generate} className="w-full flex items-center justify-center space-x-2 bg-slate-900 hover:bg-slate-800 text-white py-3 rounded-2xl font-black uppercase tracking-tighter italic text-xs transition-all disabled:opacity-50">
        <Plus className="w-4 h-4" />
        <span>{busy ? 'Generating…' : 'Generate voucher'}</span>
      </button>
    </section>
  );
}
