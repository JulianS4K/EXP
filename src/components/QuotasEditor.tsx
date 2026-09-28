// Organizer quota editor: shared capacity across ticket types (lib/quotas.ts).
// Self-contained CRUD embedded in EditEvent next to Vouchers (light theme).
// Shrinking a quota below what's sold never cancels tickets; it only stops
// new sales until it has room again.

import { useEffect, useState } from 'react';
import { Layers, Plus, Trash2, Pencil } from 'lucide-react';
import { deleteQuota, listEventQuotas, quotaInputError, saveQuota, type Quota } from '../lib/quotas';
import { useToast } from '../context/ToastContext';

const inputCls =
  'w-full bg-slate-50 border-2 border-transparent rounded-2xl py-3 px-5 text-slate-900 font-bold ' +
  'focus:outline-none focus-visible:ring-2 focus-visible:ring-brand-primary/60 focus:border-brand-primary focus:bg-white transition-all shadow-inner';

interface TierOption { id: string; name: string }

const BLANK = { name: '', size: '', closed: false, tierIds: [] as string[] };

export default function QuotasEditor({ eventId, tiers = [] }: { eventId: string; tiers?: TierOption[] }) {
  const { toast } = useToast();
  const [rows, setRows] = useState<Quota[]>([]);
  const [loading, setLoading] = useState(true);
  const [busy, setBusy] = useState(false);
  const [editing, setEditing] = useState<string | null>(null);
  const [form, setForm] = useState(BLANK);

  const reload = async () => {
    try { setRows(await listEventQuotas(eventId)); }
    catch (e) { console.error('listEventQuotas failed:', e); }
    finally { setLoading(false); }
  };
  useEffect(() => { void reload(); /* eslint-disable-next-line */ }, [eventId]);

  const tierName = (id: string) => tiers.find((t) => t.id === id)?.name ?? 'a removed ticket type';
  const savedTiers = tiers.filter((t) => t.id);

  const startEdit = (q: Quota) => {
    setEditing(q.id);
    setForm({ name: q.name, size: q.size == null ? '' : String(q.size), closed: q.closed, tierIds: q.tierIds });
  };
  const reset = () => { setEditing(null); setForm(BLANK); };

  const save = async () => {
    const input = {
      name: form.name,
      size: form.size.trim() === '' ? null : Number(form.size),
      closed: form.closed,
      tierIds: form.tierIds,
    };
    const err = quotaInputError(input);
    if (err) { toast({ kind: 'error', message: err }); return; }
    const before = rows.find((r) => r.id === editing);
    setBusy(true);
    try {
      await saveQuota(eventId, input, editing ?? undefined);
      if (before && input.size != null && input.size < before.sold) {
        toast({ kind: 'info', message: `${before.sold} already sold, more than the new size. Nothing is cancelled; sales stop until there's room.` });
      } else {
        toast({ kind: 'success', message: editing ? 'Quota saved.' : 'Quota created.' });
      }
      reset();
      await reload();
    } catch (e: any) {
      toast({ kind: 'error', message: e?.message || 'Could not save the quota.' });
    } finally {
      setBusy(false);
    }
  };

  const remove = async (q: Quota) => {
    setBusy(true);
    try { await deleteQuota(q.id); if (editing === q.id) reset(); await reload(); }
    catch (e: any) { toast({ kind: 'error', message: e?.message || 'Could not delete the quota.' }); }
    finally { setBusy(false); }
  };

  if (loading) return null;

  return (
    <section className="bg-white p-10 rounded-[3rem] border border-slate-100 shadow-xl space-y-6">
      <div className="flex items-center space-x-3 mb-2">
        <Layers className="text-brand-primary w-5 h-5" />
        <h2 className="text-xs font-bold text-slate-400 uppercase tracking-widest leading-none">Shared capacity (quotas)</h2>
      </div>
      <p className="text-slate-400 text-xs font-bold -mt-2">
        Cap several ticket types together, e.g. 400 standing across Early bird, GA and Door: when Early bird sells, GA has
        fewer left. Each ticket type's own capacity still applies. Close a quota to pause its sales.
      </p>

      {rows.length > 0 && (
        <div className="space-y-2">
          {rows.map((q) => (
            <div key={q.id} className="flex items-center justify-between bg-slate-50 rounded-2xl px-5 py-3">
              <div className="min-w-0 pr-3">
                <p className="font-bold text-slate-900 text-sm truncate">
                  {q.name}{q.closed ? ' · closed' : ''}
                </p>
                <p className="text-slate-400 text-xs font-bold">
                  {q.sold} sold{q.held > 0 ? ` · ${q.held} in carts` : ''} ·{' '}
                  {q.size == null ? 'no cap' : `${q.available ?? 0} of ${q.size} left`} · {q.tierIds.map(tierName).join(', ')}
                </p>
              </div>
              <div className="flex items-center gap-3 shrink-0">
                <button type="button" onClick={() => startEdit(q)} className="text-slate-300 hover:text-slate-600" aria-label={`Edit ${q.name}`}>
                  <Pencil className="w-4 h-4" />
                </button>
                <button type="button" disabled={busy} onClick={() => void remove(q)} className="text-slate-300 hover:text-red-500" aria-label={`Delete ${q.name}`}>
                  <Trash2 className="w-4 h-4" />
                </button>
              </div>
            </div>
          ))}
        </div>
      )}

      {savedTiers.length === 0 ? (
        <p className="text-slate-400 text-xs font-bold">Save the event's ticket types first, then link them here.</p>
      ) : (
        <div className="grid grid-cols-2 gap-4">
          <input value={form.name} onChange={(e) => setForm({ ...form, name: e.target.value.slice(0, 80) })} placeholder="Name, e.g. Standing" aria-label="Quota name" className={inputCls} />
          <input value={form.size} onChange={(e) => setForm({ ...form, size: e.target.value })} type="number" min={0} step={1} placeholder="Size (blank = no cap)" aria-label="Quota size" className={inputCls} />
          <fieldset className="col-span-2 flex flex-wrap gap-3">
            <legend className="sr-only">Ticket types in this quota</legend>
            {savedTiers.map((t) => (
              <label key={t.id} className="flex items-center gap-2 text-xs font-bold text-slate-600 bg-slate-50 rounded-xl px-3 py-2">
                <input
                  type="checkbox"
                  checked={form.tierIds.includes(t.id)}
                  onChange={(e) => setForm({
                    ...form,
                    tierIds: e.target.checked ? [...form.tierIds, t.id] : form.tierIds.filter((x) => x !== t.id),
                  })}
                />
                {t.name}
              </label>
            ))}
          </fieldset>
          <label className="col-span-2 flex items-center gap-2 text-xs font-bold text-slate-500">
            <input type="checkbox" checked={form.closed} onChange={(e) => setForm({ ...form, closed: e.target.checked })} />
            Closed (no sales from this quota until reopened)
          </label>
        </div>
      )}
      {savedTiers.length > 0 && (
        <div className="flex gap-3">
          <button type="button" disabled={busy} onClick={() => void save()} className="flex-1 flex items-center justify-center space-x-2 bg-slate-900 hover:bg-slate-800 text-white py-3 rounded-2xl font-black uppercase tracking-tighter italic text-xs transition-all disabled:opacity-50">
            <Plus className="w-4 h-4" />
            <span>{busy ? 'Saving…' : editing ? 'Save quota' : 'Add quota'}</span>
          </button>
          {editing && (
            <button type="button" onClick={reset} className="px-6 py-3 rounded-2xl font-bold text-xs text-slate-500 bg-slate-100 hover:bg-slate-200">
              Cancel
            </button>
          )}
        </div>
      )}
    </section>
  );
}
