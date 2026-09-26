// GuestListDoor — the guest-list mode of Door check-in (mig 20260926050000).
//
// Search a name, check in the guest and any number of their plus-ones
// (partial arrivals add up; never past the party size). Works for scanners.
// Offline: the door download (exos_event_door_extras, cached by the parent)
// holds every guest; arrivals are applied locally and queued with a client
// ref, then replayed when the link returns. The server ignores a ref it has
// already seen, so a replay never counts twice; a replay the server refuses
// (someone else checked that party in meanwhile) is reported, not retried.

import { AccessNeedBadges } from './Accessibility';
import { useEffect, useMemo, useRef, useState } from 'react';
import { CheckCircle2, RefreshCw, Search, Users } from 'lucide-react';
import {
  applyArrival,
  arrivalReasonText,
  countsByList,
  dropFromQueue,
  enqueueArrival,
  partySize,
  remainingFor,
  searchGuests,
  type GuestEntry,
  type PendingArrival,
} from '../lib/guestLists';
import {
  guestCheckIn,
  loadPendingArrivals,
  savePendingArrivals,
  type DoorExtras,
} from '../lib/guestListsApi';
import { useToast } from '../context/ToastContext';

const newRef = () =>
  typeof crypto !== 'undefined' && 'randomUUID' in crypto
    ? crypto.randomUUID()
    : 'xxxxxxxx-xxxx-4xxx-8xxx-xxxxxxxxxxxx'.replace(/x/g, () => Math.floor(Math.random() * 16).toString(16));

export default function GuestListDoor({
  eventId,
  isOffline,
  extras,
  onExtrasChange,
  onSync,
  syncing,
}: {
  eventId: string;
  isOffline: boolean;
  extras: DoorExtras | null;
  /** Persist a locally changed door download (parent caches it). */
  onExtrasChange: (next: DoorExtras) => void;
  /** Re-download from the server. */
  onSync: () => void;
  syncing: boolean;
}) {
  const { toast } = useToast();
  const [query, setQuery] = useState('');
  const [pending, setPending] = useState<PendingArrival[]>(() => loadPendingArrivals(eventId));
  const [counts, setCounts] = useState<Record<string, number>>({});
  const [flash, setFlash] = useState<{ id: string; text: string; ok: boolean } | null>(null);
  const [replaying, setReplaying] = useState(false);
  const extrasRef = useRef(extras);
  extrasRef.current = extras;

  const guests = extras?.guests ?? [];
  const lists = extras?.lists ?? [];
  const listName = useMemo(() => Object.fromEntries(lists.map((l) => [l.id, l.name])), [lists]);
  const perList = useMemo(() => countsByList(guests, lists.map((l) => l.id)), [guests, lists]);
  const results = useMemo(() => searchGuests(guests, query, 40), [guests, query]);

  const persistPending = (q: PendingArrival[]) => {
    setPending(q);
    savePendingArrivals(eventId, q);
  };

  const patchGuest = (id: string, fn: (e: GuestEntry) => GuestEntry) => {
    const cur = extrasRef.current;
    if (!cur) return;
    onExtrasChange({ ...cur, guests: cur.guests.map((g) => (g.id === id ? fn(g) : g)) });
  };

  // Replay queued arrivals once the link is back.
  useEffect(() => {
    if (isOffline || pending.length === 0 || replaying) return undefined;
    let cancelled = false;
    (async () => {
      setReplaying(true);
      const done: string[] = [];
      const refused: string[] = [];
      for (const p of pending) {
        try {
          const r = await guestCheckIn(eventId, p.entryId, p.count, p.ref, 'offline-sync');
          done.push(p.ref);
          if (!r.ok) refused.push(r.reason);
        } catch {
          /* still offline for this call — keep it queued */
        }
      }
      if (cancelled) return;
      persistPending(dropFromQueue(loadPendingArrivals(eventId), done));
      setReplaying(false);
      if (refused.length > 0) {
        toast({
          kind: 'error',
          message: `${refused.length} guest arrival(s) recorded offline were refused on sync (${[...new Set(refused)].join(', ')}). Re-sync to see the latest counts.`,
        });
      }
      if (done.length > 0) onSync();
    })();
    return () => {
      cancelled = true;
    };
  }, [isOffline, pending.length]);

  const checkIn = async (g: GuestEntry, count: number) => {
    const local = applyArrival(g, count);
    if (!local.ok || !local.entry) {
      setFlash({ id: g.id, text: arrivalReasonText(local.reason ?? 'bad-count', local.remaining), ok: false });
      return;
    }
    const after = local.entry;
    const ref = newRef();
    const queueIt = () => {
      persistPending(enqueueArrival(loadPendingArrivals(eventId), { ref, entryId: g.id, count, at: Date.now() }));
      patchGuest(g.id, () => after);
      setFlash({ id: g.id, text: `${count} in (offline, will sync)`, ok: true });
    };
    if (isOffline) return queueIt();
    try {
      const r = await guestCheckIn(eventId, g.id, count, ref);
      if (r.ok && r.reason === 'test-scan') {
        setFlash({ id: g.id, text: 'Test check-in OK (not recorded before doors).', ok: true });
        return;
      }
      if (r.ok) {
        patchGuest(g.id, (e) => ({ ...e, arrived: r.arrived ?? after.arrived, arrivedAt: e.arrivedAt ?? new Date().toISOString() }));
        setFlash({ id: g.id, text: `${count} in · ${r.arrived ?? after.arrived}/${r.party ?? partySize(g)}`, ok: true });
        setCounts((c) => ({ ...c, [g.id]: 1 }));
        return;
      }
      if (typeof r.arrived === 'number') patchGuest(g.id, (e) => ({ ...e, arrived: r.arrived! }));
      setFlash({ id: g.id, text: arrivalReasonText(r.reason, r.remaining), ok: false });
    } catch (err) {
      console.error('guest check-in failed; queued for sync', err);
      queueIt();
    }
  };

  if (!extras) {
    return (
      <div className="py-10 text-center">
        <p className="text-sm text-slate-500 mb-4">Download the guest lists to check names in (works offline after).</p>
        <button type="button" onClick={onSync} disabled={syncing || isOffline}
          className="inline-flex items-center gap-2 px-4 py-2 bg-slate-900 text-white rounded text-[10px] font-black uppercase tracking-widest disabled:opacity-50">
          <RefreshCw className={`w-3 h-3 ${syncing ? 'animate-spin' : ''}`} /> Download lists
        </button>
      </div>
    );
  }

  return (
    <div>
      {pending.length > 0 && (
        <p className="mb-3 text-[11px] font-bold text-amber-700 uppercase tracking-widest bg-amber-50 border border-amber-200 rounded-lg px-3 py-2">
          {pending.length} guest arrival{pending.length === 1 ? '' : 's'} waiting to sync
        </p>
      )}

      {lists.length > 0 && (
        <div className="flex flex-wrap gap-2 mb-4">
          {lists.map((l) => {
            const c = perList[l.id] ?? { heads: 0, arrived: 0 };
            return (
              <span key={l.id} className="px-3 py-1.5 bg-slate-50 border border-slate-200 rounded-full text-[11px] text-slate-600">
                <strong className="text-slate-800">{l.name}</strong> {c.arrived}/{c.heads}
                {l.cap != null ? ` · cap ${l.cap}` : ''}
              </span>
            );
          })}
        </div>
      )}

      <div className="relative mb-4">
        <input
          type="search"
          autoFocus
          placeholder="Search a name…"
          value={query}
          onChange={(e) => setQuery(e.target.value)}
          className="w-full bg-slate-50 border-2 border-transparent rounded-2xl py-4 pl-12 pr-4 text-slate-900 focus:outline-none focus:border-tm-blue"
          aria-label="Search guest list"
        />
        <Search className="absolute left-5 top-1/2 -translate-y-1/2 text-slate-400 w-5 h-5" />
      </div>

      {guests.length === 0 ? (
        <p className="text-xs text-slate-400 font-bold uppercase tracking-widest py-6 text-center">No names on any list.</p>
      ) : results.length === 0 ? (
        <p className="text-xs text-slate-400 font-bold uppercase tracking-widest py-6 text-center">No match. Check the spelling or ask which list.</p>
      ) : (
        <ul className="divide-y divide-slate-100 border border-slate-100 rounded-2xl overflow-hidden">
          {results.map((g) => {
            const left = remainingFor(g);
            const n = Math.min(counts[g.id] ?? left, left) || 1;
            return (
              <li key={g.id} className={`px-4 py-3 ${left === 0 ? 'bg-emerald-50/40' : 'bg-white'}`}>
                <div className="flex items-center gap-3">
                  <span className="min-w-0 flex-1">
                    <span className="block font-bold text-slate-900 truncate">
                      {g.guestName}
                      {g.plusOnes > 0 && <span className="text-slate-500 font-medium"> +{g.plusOnes}</span>}
                    </span>
                    <span className="block text-[11px] text-slate-400 truncate">
                      {listName[g.listId] ?? 'Guest list'}{g.note ? ` · ${g.note}` : ''}
                    </span>
                    {(g.accessNeeds?.length ?? 0) > 0 && (
                      <span className="block mt-1"><AccessNeedBadges needs={g.accessNeeds!} /></span>
                    )}
                  </span>
                  <span className="inline-flex items-center gap-1 text-[11px] font-bold text-slate-600 shrink-0">
                    <Users className="w-3.5 h-3.5" /> {g.arrived}/{partySize(g)}
                  </span>
                  {left > 0 ? (
                    <span className="inline-flex items-center gap-2 shrink-0">
                      {left > 1 && (
                        <select
                          value={n}
                          onChange={(e) => setCounts((c) => ({ ...c, [g.id]: Number(e.target.value) }))}
                          className="px-2 py-1.5 border border-slate-200 rounded text-sm bg-white"
                          aria-label={`How many of ${g.guestName}'s party`}
                        >
                          {Array.from({ length: left }, (_, i) => i + 1).map((k) => (
                            <option key={k} value={k}>{k}</option>
                          ))}
                        </select>
                      )}
                      <button
                        type="button"
                        onClick={() => void checkIn(g, n)}
                        className="px-3 py-2 bg-slate-900 hover:bg-black text-white rounded-xl text-[10px] font-black uppercase tracking-widest"
                      >
                        Check in
                      </button>
                    </span>
                  ) : (
                    <span className="inline-flex items-center gap-1 text-[10px] font-black text-emerald-600 uppercase tracking-widest shrink-0">
                      <CheckCircle2 className="w-4 h-4" /> All in
                    </span>
                  )}
                </div>
                {flash?.id === g.id && (
                  <p className={`mt-2 text-[11px] font-bold ${flash.ok ? 'text-emerald-600' : 'text-rose-500'}`}>{flash.text}</p>
                )}
              </li>
            );
          })}
        </ul>
      )}
    </div>
  );
}
