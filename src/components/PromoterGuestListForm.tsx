// PromoterGuestListForm — a promoter's own guest lists on their portal page
// (/p/:token, mig 20260926050000). The token is the secret: they see and fill
// only the lists the organizer gave them, up to each list's cap, until the
// list closes. Names already checked in can't be removed.

import { useAccessColumns } from '../hooks/useAccessColumns';
import { GuestAccessEditor } from './Accessibility';
import { promoterSetGuestAccessNeeds } from '../lib/accessibilityApi';
import { useCallback, useEffect, useState } from 'react';
import { ClipboardList, Trash2, UserPlus } from 'lucide-react';
import {
  getPromoterGuestLists,
  promoterAddGuest,
  promoterRemoveGuest,
  type PromoterGuestList,
} from '../lib/guestListsApi';
import { validateGuestInput } from '../lib/guestLists';
import { useToast } from '../context/ToastContext';

const inputCls = 'bg-black border border-white/20 py-2 px-3 text-white text-sm focus:outline-none focus:border-brand-primary';

export default function PromoterGuestListForm({ token }: { token: string }) {
  const [lists, setLists] = useState<PromoterGuestList[] | null>(null);

  const load = useCallback(async () => {
    try {
      setLists(await getPromoterGuestLists(token));
    } catch {
      setLists([]);
    }
  }, [token]);

  useEffect(() => {
    void load();
  }, [load]);

  if (!lists || lists.length === 0) return null;

  return (
    <div className="space-y-3 mb-8">
      <p className="type text-[10px] uppercase tracking-widest text-brand-primary">Your guest lists</p>
      {lists.map((l) => (
        <div key={l.listId}>
          <ListCard token={token} list={l} onChanged={load} />
        </div>
      ))}
    </div>
  );
}

function ListCard({ token, list, onChanged }: { token: string; list: PromoterGuestList; onChanged: () => Promise<void> }) {
  const { toast } = useToast();
  const [name, setName] = useState('');
  const [plus, setPlus] = useState(0);
  const [busy, setBusy] = useState(false);
  const accessOk = useAccessColumns();
  const left = list.cap != null ? Math.max(0, list.cap - list.heads) : null;
  const when = list.startsAt ? new Date(list.startsAt).toLocaleDateString(undefined, { month: 'short', day: 'numeric' }) : '';

  const add = async () => {
    const err = validateGuestInput({ guestName: name, plusOnes: plus }, { maxPlusOnes: list.maxPlusOnes, capLeft: left });
    if (err) return toast({ kind: 'error', message: err });
    setBusy(true);
    try {
      await promoterAddGuest(token, list.listId, { guestName: name.trim(), plusOnes: plus });
      setName('');
      setPlus(0);
      await onChanged();
    } catch (e: any) {
      toast({ kind: 'error', message: (e?.message || 'Could not add the name.').replace(/^exos: /, '') });
    } finally {
      setBusy(false);
    }
  };

  const remove = async (id: string) => {
    try {
      await promoterRemoveGuest(token, id);
      await onChanged();
    } catch (e: any) {
      toast({ kind: 'error', message: (e?.message || 'Could not remove the name.').replace(/^exos: /, '') });
    }
  };

  return (
    <section className="bg-[#111] border border-white/10 p-5">
      <div className="flex items-center justify-between gap-3 mb-3">
        <span className="flex items-center gap-2 min-w-0">
          <ClipboardList className="w-4 h-4 text-brand-primary shrink-0" />
          <span className="font-black text-white truncate">{list.eventName}</span>
          <span className="type text-[10px] text-white/40 uppercase tracking-widest shrink-0">{when}</span>
        </span>
        <span className="type text-[10px] uppercase tracking-widest text-white/60 shrink-0">
          {list.name} · {list.heads}{list.cap != null ? `/${list.cap}` : ''} people
        </span>
      </div>

      {list.open ? (
        <div className="flex flex-wrap gap-2 items-center mb-3">
          <input
            className={`${inputCls} flex-1 min-w-[10rem]`}
            placeholder="Guest name"
            maxLength={80}
            value={name}
            onChange={(e) => setName(e.target.value)}
            onKeyDown={(e) => { if (e.key === 'Enter') void add(); }}
            aria-label="Guest name"
          />
          {list.maxPlusOnes > 0 && (
            <label className="type text-[10px] text-white/50 uppercase tracking-widest">
              +
              <input
                type="number"
                min={0}
                max={list.maxPlusOnes}
                className={`${inputCls} w-16 ml-1`}
                value={plus}
                onChange={(e) => setPlus(Math.max(0, Math.min(list.maxPlusOnes, Number(e.target.value) || 0)))}
                aria-label="Plus-ones"
              />
            </label>
          )}
          <button
            type="button"
            onClick={add}
            disabled={busy || (left !== null && left < 1)}
            className="inline-flex items-center gap-1 px-3 py-2 bg-brand-primary text-black font-black text-[10px] uppercase tracking-widest disabled:opacity-40"
          >
            <UserPlus size={12} /> Add
          </button>
          {left !== null && <span className="type text-[10px] text-white/40 uppercase tracking-widest">{left} left</span>}
        </div>
      ) : (
        <p className="type text-[10px] text-white/40 uppercase tracking-widest mb-3">This list is closed.</p>
      )}

      {list.entries.length === 0 ? (
        <p className="text-[11px] text-white/40 italic">No names yet.</p>
      ) : (
        <ul className="divide-y divide-white/5">
          {list.entries.map((e) => (
            <li key={e.id} className="flex items-start justify-between gap-3 py-2 text-sm">
              <span className="text-white min-w-0">
                {e.guestName}
                {e.plusOnes > 0 && <span className="text-white/50"> +{e.plusOnes}</span>}
                <GuestAccessEditor
                  entryId={e.id}
                  guestName={e.guestName}
                  needs={e.accessNeeds}
                  canEdit={list.open && accessOk}
                  theme="dark"
                  onSave={async (n) => {
                    try {
                      await promoterSetGuestAccessNeeds(token, e.id, n);
                      await onChanged();
                    } catch (x: any) {
                      toast({ kind: 'error', message: (x?.message || 'Could not save access needs.').replace(/^exos: /, '') });
                      throw x;
                    }
                  }}
                />
              </span>
              {e.arrived > 0 ? (
                <span className="type text-[10px] uppercase tracking-widest text-brand-primary">{e.arrived} in</span>
              ) : list.open ? (
                <button type="button" onClick={() => remove(e.id)} aria-label={`Remove ${e.guestName}`} className="text-white/30 hover:text-brand-accent">
                  <Trash2 size={14} />
                </button>
              ) : null}
            </li>
          ))}
        </ul>
      )}
    </section>
  );
}
