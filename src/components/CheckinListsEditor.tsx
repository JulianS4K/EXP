// Organizer editor for check-in lists (mig 20260929140000): gates / areas,
// the ticket types each admits, an optional time window, and "Allow
// re-entry" (off unless turned on). Self-contained CRUD embedded in EditEvent
// next to the door settings; it saves on its own buttons, not the event form.
// Nothing here is required: an event with no lists admits every ticket once.

import { useEffect, useState } from 'react';
import { DoorOpen, Pencil, Plus, Trash2 } from 'lucide-react';
import { deleteCheckinList, listCheckinLists, saveCheckinList } from '../lib/checkinLists';
import { checkinListInputError, describeList, type CheckinListInput, type DoorCheckinList } from '../lib/door/lists';
import { getBrowserTimezone, utcToZonedWallClock, zonedWallClockToUtc } from '../lib/datetime';
import { useToast } from '../context/ToastContext';

interface TierOption { id: string; name: string }

interface Form {
  name: string;
  allTiers: boolean;
  tierIds: string[];
  allowReentry: boolean;
  /** datetime-local wall clock in the event's zone ('' = open-ended). */
  from: string;
  until: string;
}

const BLANK: Form = { name: '', allTiers: true, tierIds: [], allowReentry: false, from: '', until: '' };

const inputCls =
  'w-full bg-black border border-white/20 py-3 px-4 font-bold text-white focus:outline-none ' +
  'focus-visible:ring-2 focus-visible:ring-brand-primary/60 focus:border-brand-primary transition-colors';

export default function CheckinListsEditor({
  eventId,
  tiers = [],
  timezone,
}: {
  eventId: string;
  tiers?: TierOption[];
  timezone?: string;
}) {
  const { toast } = useToast();
  // null = the database has no lists yet (migration not applied): hidden.
  const [rows, setRows] = useState<DoorCheckinList[] | null>(null);
  const [loaded, setLoaded] = useState(false);
  const [busy, setBusy] = useState(false);
  const [editing, setEditing] = useState<string | null>(null);
  const [open, setOpen] = useState(false);
  const [form, setForm] = useState<Form>(BLANK);
  const tz = timezone || getBrowserTimezone();

  const reload = async () => {
    try {
      setRows(await listCheckinLists(eventId));
    } catch (e) {
      console.error('listCheckinLists failed:', e);
    } finally {
      setLoaded(true);
    }
  };
  useEffect(() => { void reload(); /* eslint-disable-next-line react-hooks/exhaustive-deps */ }, [eventId]);

  if (!loaded || rows === null) return null;

  const tierName = (id: string) => tiers.find((t) => t.id === id)?.name ?? 'a removed ticket type';
  const toIso = (wall: string) => (wall ? zonedWallClockToUtc(wall, tz)?.toISOString() ?? null : null);
  const toWall = (iso: string | null) => (iso ? utcToZonedWallClock(new Date(iso), tz) : '');

  const input = (): CheckinListInput => ({
    name: form.name,
    tierIds: form.allTiers ? null : form.tierIds,
    allowReentry: form.allowReentry,
    validFrom: toIso(form.from),
    validUntil: toIso(form.until),
  });

  const startNew = () => { setEditing(null); setForm(BLANK); setOpen(true); };
  const startEdit = (l: DoorCheckinList) => {
    setEditing(l.id);
    setForm({
      name: l.name,
      allTiers: !l.tierIds,
      tierIds: l.tierIds ?? [],
      allowReentry: l.allowReentry,
      from: toWall(l.validFrom),
      until: toWall(l.validUntil),
    });
    setOpen(true);
  };
  const reset = () => { setEditing(null); setForm(BLANK); setOpen(false); };

  const save = async () => {
    const i = input();
    const err = checkinListInputError(i);
    if (err) { toast({ kind: 'error', message: err }); return; }
    setBusy(true);
    try {
      const order = editing ? undefined : rows.reduce((m, r) => Math.max(m, r.sortOrder + 1), 0);
      await saveCheckinList(eventId, i, editing ?? undefined, order);
      toast({ kind: 'success', message: editing ? 'Check-in list saved.' : 'Check-in list added.' });
      reset();
      await reload();
    } catch (e: any) {
      toast({ kind: 'error', message: e?.message || 'Could not save the check-in list.' });
    } finally {
      setBusy(false);
    }
  };

  const remove = async (l: DoorCheckinList) => {
    if (typeof window !== 'undefined' && !window.confirm(`Delete the list "${l.name}"? Past check-ins stay in the scan report.`)) return;
    setBusy(true);
    try {
      await deleteCheckinList(l.id);
      if (editing === l.id) reset();
      await reload();
    } catch (e: any) {
      toast({ kind: 'error', message: e?.message || 'Could not delete the check-in list.' });
    } finally {
      setBusy(false);
    }
  };

  return (
    <div className="space-y-3 max-w-xl" aria-labelledby="checkin-lists-title">
      <div className="flex items-center gap-2 ml-1">
        <DoorOpen className="w-4 h-4 text-brand-primary" aria-hidden="true" />
        <h3 id="checkin-lists-title" className="type text-[11px] text-white/60 uppercase tracking-widest">Check-in lists</h3>
      </div>
      <p className="text-sm text-white/60 ml-1">
        Optional. Split the door into gates or areas (a VIP deck, a late entrance) that admit some ticket types, maybe only at
        certain times. Re-entry is off unless you turn it on for a list; then staff scan people out and back in.
        {rows.length === 0 ? ' With no lists, every ticket gets in once, at any door.' : ''}
      </p>

      {rows.length > 0 && (
        <ul className="space-y-2">
          {rows.map((l) => (
            <li key={l.id} className="flex items-center justify-between border border-white/10 px-4 py-3">
              <div className="min-w-0 pr-3">
                <p className="font-bold text-white text-sm truncate">{l.name}</p>
                <p className="text-white/50 text-xs">
                  {describeList(l, tierName)}
                  {l.validFrom || l.validUntil
                    ? ` · ${l.validFrom ? `from ${toWall(l.validFrom).replace('T', ' ')}` : ''}${l.validFrom && l.validUntil ? ' ' : ''}${
                        l.validUntil ? `until ${toWall(l.validUntil).replace('T', ' ')}` : ''
                      }`
                    : ''}
                </p>
              </div>
              <div className="flex items-center gap-3 shrink-0">
                <button type="button" onClick={() => startEdit(l)} className="text-white/40 hover:text-white" aria-label={`Edit ${l.name}`}>
                  <Pencil className="w-4 h-4" />
                </button>
                <button type="button" disabled={busy} onClick={() => void remove(l)} className="text-white/40 hover:text-red-400" aria-label={`Delete ${l.name}`}>
                  <Trash2 className="w-4 h-4" />
                </button>
              </div>
            </li>
          ))}
        </ul>
      )}

      {!open ? (
        <button
          type="button"
          onClick={startNew}
          className="flex items-center gap-2 px-4 py-3 border border-white/20 text-white text-[11px] font-black uppercase tracking-widest hover:border-brand-primary"
        >
          <Plus className="w-4 h-4" aria-hidden="true" /> Add a check-in list
        </button>
      ) : (
        <div className="border border-white/20 p-4 space-y-4">
          <div className="space-y-1">
            <label htmlFor="cl-name" className="type text-[10px] text-white/60 uppercase tracking-widest">Name</label>
            <input
              id="cl-name"
              value={form.name}
              onChange={(e) => setForm({ ...form, name: e.target.value.slice(0, 60) })}
              placeholder="e.g. Main door, VIP deck"
              // Inside the event form: Enter saves the list, not the event.
              onKeyDown={(e) => { if (e.key === 'Enter') { e.preventDefault(); void save(); } }}
              className={inputCls}
            />
          </div>
          <fieldset className="space-y-2">
            <legend className="type text-[10px] text-white/60 uppercase tracking-widest mb-1">Ticket types</legend>
            <label className="flex items-center gap-2 text-sm text-white">
              <input type="checkbox" checked={form.allTiers} onChange={(e) => setForm({ ...form, allTiers: e.target.checked })} />
              All ticket types
            </label>
            {!form.allTiers && (
              tiers.length === 0 ? (
                <p className="text-xs text-white/50">Save the event's ticket types first, then pick them here.</p>
              ) : (
                <div className="flex flex-wrap gap-2">
                  {tiers.map((t) => (
                    <label key={t.id} className="flex items-center gap-2 text-xs font-bold text-white/80 border border-white/10 px-3 py-2">
                      <input
                        type="checkbox"
                        checked={form.tierIds.includes(t.id)}
                        onChange={(e) =>
                          setForm({
                            ...form,
                            tierIds: e.target.checked ? [...form.tierIds, t.id] : form.tierIds.filter((x) => x !== t.id),
                          })
                        }
                      />
                      {t.name}
                    </label>
                  ))}
                </div>
              )
            )}
          </fieldset>
          <label className="flex items-start gap-2 text-sm text-white">
            <input
              type="checkbox"
              className="mt-1"
              checked={form.allowReentry}
              onChange={(e) => setForm({ ...form, allowReentry: e.target.checked })}
            />
            <span>
              Allow re-entry
              <span className="block text-xs text-white/50">
                Off by default. When on, door staff scan people out when they leave and back in when they return; a second
                entry without an exit is refused.
              </span>
            </span>
          </label>
          <div className="grid grid-cols-1 md:grid-cols-2 gap-3">
            <div className="space-y-1">
              <label htmlFor="cl-from" className="type text-[10px] text-white/60 uppercase tracking-widest">Opens (optional)</label>
              <input id="cl-from" type="datetime-local" value={form.from} onChange={(e) => setForm({ ...form, from: e.target.value })} className={inputCls} />
            </div>
            <div className="space-y-1">
              <label htmlFor="cl-until" className="type text-[10px] text-white/60 uppercase tracking-widest">Closes (optional)</label>
              <input id="cl-until" type="datetime-local" value={form.until} onChange={(e) => setForm({ ...form, until: e.target.value })} className={inputCls} />
            </div>
          </div>
          <p className="text-xs text-white/40">Times are in the event's time zone ({tz}). Exits are allowed outside the window.</p>
          <div className="flex gap-3">
            <button
              type="button"
              disabled={busy}
              onClick={() => void save()}
              className="flex-1 px-4 py-3 bg-brand-primary text-black text-[11px] font-black uppercase tracking-widest disabled:opacity-50"
            >
              {busy ? 'Saving…' : editing ? 'Save list' : 'Add list'}
            </button>
            <button type="button" onClick={reset} className="px-4 py-3 border border-white/20 text-white/70 text-[11px] font-black uppercase tracking-widest">
              Cancel
            </button>
          </div>
        </div>
      )}
    </div>
  );
}
