// GuestListPanel — guest lists for one event (mig 20260926050000).
//
// Owner / manager make lists (their own, or one per promoter), set a head cap
// (guest + plus-ones) and the plus-one limit, and add / edit / remove names.
// Promoters fill their own list from their portal link. The door checks
// names in from Door check-in → Guest list, online or offline.
//
// "Counts toward capacity" is off by default: guest-list heads don't use
// ticket inventory. Turn it on for a list and its heads come out of the
// event's total capacity as names are added (and go back when removed).

import { GuestAccessEditor } from './Accessibility';
import { setGuestAccessNeeds } from '../lib/accessibilityApi';
import { useCallback, useEffect, useMemo, useState } from 'react';
import { ClipboardList, Plus, Trash2, UserPlus, X } from 'lucide-react';
import {
  addGuest,
  deleteGuestList,
  listGuestLists,
  removeGuest,
  updateGuest,
  upsertGuestList,
  type GuestList,
} from '../lib/guestListsApi';
import { capLeft, countsByList, partySize, validateGuestInput, type GuestEntry } from '../lib/guestLists';
import { listPromoters, type Promoter } from '../lib/promoters';
import { useToast } from '../context/ToastContext';
import type { Event } from '../types';

const inputCls = 'px-2 py-1.5 border border-slate-200 rounded text-sm bg-white';
const btnDark =
  'inline-flex items-center gap-1 px-3 py-1.5 bg-slate-900 hover:bg-slate-800 disabled:bg-slate-200 disabled:text-slate-400 text-white rounded text-[10px] font-black uppercase tracking-widest';
const cleanErr = (err: any, fallback: string) =>
  (err?.message || fallback).replace(/^exos(_[a-z_]+)?: /, '');

export default function GuestListPanel({ event, canManage }: { event: Event; canManage: boolean }) {
  const { toast } = useToast();
  const [lists, setLists] = useState<GuestList[] | null>(null);
  const [entries, setEntries] = useState<GuestEntry[]>([]);
  const [promoters, setPromoters] = useState<Promoter[]>([]);
  const [open, setOpen] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [creating, setCreating] = useState(false);
  const [form, setForm] = useState({ name: '', cap: '', maxPlusOnes: '3', promoterId: '', counts: false });

  const load = useCallback(async () => {
    try {
      const r = await listGuestLists(event.id);
      setLists(r.lists);
      setEntries(r.entries);
    } catch (err) {
      console.error('guest lists load failed:', err);
      setLists([]);
    }
  }, [event.id]);

  useEffect(() => {
    void load();
    if (canManage && event.orgId) listPromoters(event.orgId).then(setPromoters).catch(() => setPromoters([]));
  }, [load, canManage, event.orgId]);

  const counts = useMemo(() => countsByList(entries, (lists ?? []).map((l) => l.id)), [entries, lists]);
  const promoterName = (id: string | null) => promoters.find((p) => p.id === id)?.name ?? null;

  if (!canManage && (!lists || lists.length === 0)) return null;

  const createList = async () => {
    const cap = form.cap.trim() ? Number(form.cap) : null;
    if (!form.name.trim()) return toast({ kind: 'error', message: 'Name the list.' });
    if (cap !== null && (!Number.isInteger(cap) || cap < 1)) return toast({ kind: 'error', message: 'Cap must be a whole number.' });
    setBusy(true);
    try {
      const id = await upsertGuestList(event.id, {
        name: form.name.trim(),
        cap,
        maxPlusOnes: Math.max(0, Math.min(20, Number(form.maxPlusOnes) || 0)),
        promoterId: form.promoterId || null,
        countsTowardCapacity: form.counts,
      });
      setForm({ name: '', cap: '', maxPlusOnes: '3', promoterId: '', counts: false });
      setCreating(false);
      setOpen(id);
      await load();
    } catch (err) {
      toast({ kind: 'error', message: cleanErr(err, 'Could not create the list.') });
    } finally {
      setBusy(false);
    }
  };

  const setStatus = async (l: GuestList, status: 'open' | 'closed') => {
    setBusy(true);
    try {
      await upsertGuestList(event.id, {
        name: l.name, cap: l.cap, promoterId: l.promoterId, countsTowardCapacity: l.countsTowardCapacity,
        maxPlusOnes: l.maxPlusOnes, status, closesAt: l.closesAt,
      }, l.id);
      await load();
    } catch (err) {
      toast({ kind: 'error', message: cleanErr(err, 'Could not update the list.') });
    } finally {
      setBusy(false);
    }
  };

  const drop = async (l: GuestList) => {
    if (!window.confirm(`Delete "${l.name}" and its names?`)) return;
    setBusy(true);
    try {
      await deleteGuestList(l.id);
      await load();
    } catch (err) {
      toast({ kind: 'error', message: cleanErr(err, 'Could not delete the list.') });
    } finally {
      setBusy(false);
    }
  };

  return (
    <div className="bg-white rounded-2xl p-6 shadow-sm mb-6">
      <div className="flex items-center justify-between gap-2 mb-1">
        <div className="flex items-center gap-2">
          <ClipboardList className="w-4 h-4 text-slate-500" />
          <h3 className="text-sm font-bold text-slate-700">Guest lists</h3>
        </div>
        {canManage && !creating && (
          <button type="button" onClick={() => setCreating(true)} className={btnDark}>
            <Plus size={12} /> New list
          </button>
        )}
      </div>
      <p className="text-xs text-slate-400 mb-4">
        Names at the door, no ticket needed. Caps count the guest plus their plus-ones. Promoters add to their own
        list from their portal link. Guest lists don't use ticket inventory unless you say so.
      </p>

      {creating && (
        <div className="border border-slate-200 rounded-xl p-4 mb-4 space-y-3">
          <div className="flex flex-wrap gap-3 items-end">
            <label className="text-sm text-slate-700">
              <span className="block text-[10px] font-black text-slate-400 uppercase tracking-widest mb-1">Name</span>
              <input className={`${inputCls} w-48`} value={form.name} maxLength={80}
                onChange={(e) => setForm({ ...form, name: e.target.value })} placeholder="e.g. Nina's list" />
            </label>
            <label className="text-sm text-slate-700">
              <span className="block text-[10px] font-black text-slate-400 uppercase tracking-widest mb-1">Cap (people)</span>
              <input className={`${inputCls} w-24`} type="number" min={1} value={form.cap}
                onChange={(e) => setForm({ ...form, cap: e.target.value })} placeholder="none" />
            </label>
            <label className="text-sm text-slate-700">
              <span className="block text-[10px] font-black text-slate-400 uppercase tracking-widest mb-1">Max plus-ones</span>
              <input className={`${inputCls} w-20`} type="number" min={0} max={20} value={form.maxPlusOnes}
                onChange={(e) => setForm({ ...form, maxPlusOnes: e.target.value })} />
            </label>
            <label className="text-sm text-slate-700">
              <span className="block text-[10px] font-black text-slate-400 uppercase tracking-widest mb-1">Promoter</span>
              <select className={inputCls} value={form.promoterId} onChange={(e) => setForm({ ...form, promoterId: e.target.value })}>
                <option value="">None (my list)</option>
                {promoters.filter((p) => p.status === 'active').map((p) => (
                  <option key={p.id} value={p.id}>{p.name}</option>
                ))}
              </select>
            </label>
          </div>
          <label className="flex items-start gap-2 text-xs text-slate-600">
            <input type="checkbox" checked={form.counts} onChange={(e) => setForm({ ...form, counts: e.target.checked })} className="mt-0.5" />
            <span>Counts toward capacity: each name takes spots from the event's total, so tickets can't oversell the room. Can only change while the list is empty.</span>
          </label>
          <div className="flex gap-2">
            <button type="button" onClick={createList} disabled={busy} className={btnDark}>Create list</button>
            <button type="button" onClick={() => setCreating(false)} className="px-3 py-1.5 text-[10px] font-bold text-slate-500 uppercase tracking-widest">Cancel</button>
          </div>
        </div>
      )}

      {lists === null ? (
        <p className="text-xs text-slate-400">Loading…</p>
      ) : lists.length === 0 ? (
        <p className="text-xs text-slate-400 italic">No guest lists yet.</p>
      ) : (
        <ul className="divide-y divide-slate-100 border border-slate-100 rounded-xl">
          {lists.map((l) => {
            const c = counts[l.id] ?? { entries: 0, heads: 0, arrived: 0 };
            const mine = entries.filter((e) => e.listId === l.id);
            const owner = l.promoterId ? `Promoter: ${promoterName(l.promoterId) ?? 'promoter'}` : 'Staff list';
            return (
              <li key={l.id}>
                <button type="button" onClick={() => setOpen(open === l.id ? null : l.id)}
                  className="w-full flex items-center justify-between gap-3 px-4 py-3 text-left">
                  <span className="min-w-0">
                    <span className="block font-bold text-slate-800 truncate">
                      {l.name}{l.status === 'closed' && <span className="ml-2 text-[10px] text-slate-400 uppercase">closed</span>}
                    </span>
                    <span className="block text-[11px] text-slate-400">
                      {owner}{l.countsTowardCapacity ? ' · counts toward capacity' : ''}
                    </span>
                  </span>
                  <span className="text-xs text-slate-600 shrink-0">
                    {c.arrived}/{c.heads} in{l.cap != null ? ` · cap ${l.cap}` : ''}
                  </span>
                </button>
                {open === l.id && (
                  <div className="px-4 pb-4">
                    {canManage && (
                      <AddGuestRow list={l} entries={mine} onAdded={load} />
                    )}
                    <GuestRows list={l} entries={mine} canManage={canManage} onChanged={load} />
                    {canManage && (
                      <div className="flex gap-3 mt-3">
                        <button type="button" disabled={busy} onClick={() => setStatus(l, l.status === 'open' ? 'closed' : 'open')}
                          className="text-[10px] font-bold text-slate-500 hover:text-slate-900 uppercase tracking-widest">
                          {l.status === 'open' ? 'Close list' : 'Reopen list'}
                        </button>
                        <button type="button" disabled={busy} onClick={() => drop(l)}
                          className="text-[10px] font-bold text-rose-500 hover:text-rose-700 uppercase tracking-widest">
                          Delete list
                        </button>
                      </div>
                    )}
                  </div>
                )}
              </li>
            );
          })}
        </ul>
      )}
    </div>
  );
}

function AddGuestRow({ list, entries, onAdded }: { list: GuestList; entries: GuestEntry[]; onAdded: () => Promise<void> }) {
  const { toast } = useToast();
  const [g, setG] = useState({ guestName: '', plusOnes: 0, email: '', phone: '', note: '' });
  const [busy, setBusy] = useState(false);
  const left = capLeft(list.cap, entries);

  const submit = async () => {
    const err = validateGuestInput(g, { maxPlusOnes: list.maxPlusOnes, capLeft: left });
    if (err) return toast({ kind: 'error', message: err });
    setBusy(true);
    try {
      await addGuest(list.id, g);
      setG({ guestName: '', plusOnes: 0, email: '', phone: '', note: '' });
      await onAdded();
    } catch (e) {
      toast({ kind: 'error', message: cleanErr(e, 'Could not add the guest.') });
    } finally {
      setBusy(false);
    }
  };

  return (
    <div className="flex flex-wrap gap-2 items-end mb-3">
      <input className={`${inputCls} w-44`} placeholder="Guest name" maxLength={80} value={g.guestName}
        onChange={(e) => setG({ ...g, guestName: e.target.value })}
        onKeyDown={(e) => { if (e.key === 'Enter') void submit(); }} aria-label="Guest name" />
      <label className="text-[10px] font-black text-slate-400 uppercase tracking-widest">
        +
        <input className={`${inputCls} w-14 ml-1`} type="number" min={0} max={list.maxPlusOnes} value={g.plusOnes}
          onChange={(e) => setG({ ...g, plusOnes: Math.max(0, Number(e.target.value) || 0) })} aria-label="Plus-ones" />
      </label>
      <input className={`${inputCls} w-40`} placeholder="Email (optional)" value={g.email}
        onChange={(e) => setG({ ...g, email: e.target.value })} aria-label="Email" />
      <input className={`${inputCls} w-32`} placeholder="Phone (optional)" value={g.phone}
        onChange={(e) => setG({ ...g, phone: e.target.value })} aria-label="Phone" />
      <input className={`${inputCls} w-36`} placeholder="Note for the door" maxLength={200} value={g.note}
        onChange={(e) => setG({ ...g, note: e.target.value })} aria-label="Note" />
      <button type="button" onClick={submit} disabled={busy || (left !== null && left < 1)} className={btnDark}>
        <UserPlus size={12} /> Add
      </button>
      {left !== null && <span className="text-[11px] text-slate-400">{left} spot{left === 1 ? '' : 's'} left</span>}
    </div>
  );
}

function GuestRows({
  list, entries, canManage, onChanged,
}: { list: GuestList; entries: GuestEntry[]; canManage: boolean; onChanged: () => Promise<void> }) {
  const { toast } = useToast();
  const [editing, setEditing] = useState<string | null>(null);
  const [plus, setPlus] = useState(0);

  if (entries.length === 0) return <p className="text-[11px] text-slate-400 italic">No names yet.</p>;

  const savePlus = async (e: GuestEntry) => {
    const err = validateGuestInput({ guestName: e.guestName, plusOnes: plus }, {
      maxPlusOnes: list.maxPlusOnes, capLeft: capLeft(list.cap, entries), currentHeads: partySize(e),
    });
    if (err) return toast({ kind: 'error', message: err });
    try {
      await updateGuest(e.id, { guestName: e.guestName, plusOnes: plus, email: e.email ?? '', phone: e.phone ?? '', note: e.note ?? '' });
      setEditing(null);
      await onChanged();
    } catch (x) {
      toast({ kind: 'error', message: cleanErr(x, 'Could not update the guest.') });
    }
  };

  const remove = async (e: GuestEntry) => {
    try {
      await removeGuest(e.id);
      await onChanged();
    } catch (x) {
      toast({ kind: 'error', message: cleanErr(x, 'Could not remove the guest.') });
    }
  };

  return (
    <ul className="divide-y divide-slate-50">
      {entries.map((e) => (
        <li key={e.id} className="flex items-center gap-3 py-2 text-sm">
          <span className="min-w-0 flex-1">
            <span className="font-bold text-slate-800">{e.guestName}</span>
            {e.plusOnes > 0 && <span className="text-slate-500"> +{e.plusOnes}</span>}
            {(e.email || e.phone || e.note) && (
              <span className="block text-[11px] text-slate-400 truncate">
                {[e.email, e.phone, e.note].filter(Boolean).join(' · ')}
              </span>
            )}
            <GuestAccessEditor
              entryId={e.id}
              guestName={e.guestName}
              needs={e.accessNeeds ?? []}
              canEdit={canManage}
              onSave={async (n) => {
                try {
                  await setGuestAccessNeeds(e.id, n);
                  await onChanged();
                } catch (x) {
                  toast({ kind: 'error', message: cleanErr(x, 'Could not save access needs.') });
                  throw x;
                }
              }}
            />
          </span>
          <span className={`text-[10px] font-bold uppercase tracking-widest ${e.arrived > 0 ? 'text-emerald-600' : 'text-slate-300'}`}>
            {e.arrived}/{partySize(e)} in
          </span>
          {canManage && editing === e.id ? (
            <span className="inline-flex items-center gap-1">
              +<input type="number" min={0} max={list.maxPlusOnes} value={plus} className={`${inputCls} w-14`}
                onChange={(x) => setPlus(Math.max(0, Number(x.target.value) || 0))} aria-label="Plus-ones" />
              <button type="button" onClick={() => savePlus(e)} className={btnDark}>Save</button>
              <button type="button" onClick={() => setEditing(null)} aria-label="Cancel edit"><X size={14} className="text-slate-400" /></button>
            </span>
          ) : canManage ? (
            <span className="inline-flex items-center gap-2">
              <button type="button" onClick={() => { setEditing(e.id); setPlus(e.plusOnes); }}
                className="text-[10px] font-bold text-slate-500 hover:text-slate-900 uppercase tracking-widest">Edit</button>
              <button type="button" onClick={() => remove(e)} disabled={e.arrived > 0} aria-label={`Remove ${e.guestName}`}
                className="text-rose-400 hover:text-rose-600 disabled:opacity-30">
                <Trash2 size={14} />
              </button>
            </span>
          ) : null}
        </li>
      ))}
    </ul>
  );
}
