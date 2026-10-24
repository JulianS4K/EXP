// GuestListDoor — the guest-list mode of Door check-in (mig 20260926050000).
//
// Search a name, check in the guest and any number of their plus-ones
// (partial arrivals add up; never past the party size). Works for scanners.
// Offline: the door download (exos_event_door_extras, cached by the parent)
// holds every guest; arrivals are checked against the door's times (doors,
// test window, cancelled) and the party, applied locally and queued with a
// client ref, the scan time and who checked them in. The parent page replays
// the queue whichever tab is open (lib/guestListsApi replayPendingArrivals).
// The server ignores a ref it has already seen, so a replay never counts
// twice; a replay the server refuses (someone else checked that party in
// meanwhile) is reported, not retried.

import { AccessNeedBadges } from './Accessibility';
import { useEffect, useMemo, useRef, useState } from 'react';
import { Ban, Camera, CameraOff, CheckCircle2, RefreshCw, ScanLine, Search, Users } from 'lucide-react';
import { codeIndex, isExosCode, matchImported } from '../lib/door/imports';
import {
  applyArrival,
  arrivalReasonText,
  countsByList,
  elsewhereText,
  enqueueArrival,
  guestGate,
  headsIn,
  mapElsewhere,
  partySize,
  remainingFor,
  searchGuests,
  voidedText,
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
import { isServerAnswer, withDeadline } from '../lib/door/net';
import type { DoorGate } from '../lib/door/decide';
import { doorAccessProblem, NOT_ASSIGNED_TEXT } from '../lib/door/scope';

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
  incomingCode,
  onIncomingHandled,
  pending,
  onPendingChange,
  gate,
  now,
  uid,
}: {
  eventId: string;
  isOffline: boolean;
  extras: DoorExtras | null;
  /** Persist a locally changed door download (parent caches it). */
  onExtrasChange: (next: DoorExtras) => void;
  /** Re-download from the server. */
  onSync: () => void;
  syncing: boolean;
  /** A code read by the ticket scanner that belongs to an imported guest. */
  incomingCode?: { text: string; at: number } | null;
  onIncomingHandled?: () => void;
  /** Arrivals waiting to upload (the parent keeps and replays the queue). */
  pending: PendingArrival[];
  onPendingChange: (next: PendingArrival[]) => void;
  /** The event's doors / test window (lib/door/roster doorGate). */
  gate: DoorGate;
  /** Server-corrected clock (lib/serverClock serverNow). */
  now: () => number;
  /** Who is checking guests in (stamped on queued arrivals). */
  uid: string;
}) {
  const { toast } = useToast();
  const [query, setQuery] = useState('');
  const [counts, setCounts] = useState<Record<string, number>>({});
  const [flash, setFlash] = useState<{ id: string; text: string; ok: boolean } | null>(null);
  const extrasRef = useRef(extras);
  extrasRef.current = extras;

  const guests = extras?.guests ?? [];
  const lists = extras?.lists ?? [];
  const listName = useMemo(() => Object.fromEntries(lists.map((l) => [l.id, l.name])), [lists]);
  const perList = useMemo(() => countsByList(guests, lists.map((l) => l.id)), [guests, lists]);
  const results = useMemo(() => searchGuests(guests, query, 40), [guests, query]);
  // Exos Door (mig 20261013090000): guests imported from another platform
  // carry its barcode; scan or type it (a USB / Bluetooth scanner types it
  // and presses Enter) to check that guest in.
  const byCode: Map<string, GuestEntry> = useMemo(() => codeIndex<GuestEntry>(guests), [guests]);
  const [code, setCode] = useState('');
  const [codeFlash, setCodeFlash] = useState<{ text: string; ok: boolean } | null>(null);
  const [cameraOn, setCameraOn] = useState(false);
  const lastReadRef = useRef<{ text: string; at: number } | null>(null);

  const persistPending = (q: PendingArrival[]) => {
    savePendingArrivals(eventId, q);
    onPendingChange(q);
  };

  const patchGuest = (id: string, fn: (e: GuestEntry) => GuestEntry) => {
    const cur = extrasRef.current;
    if (!cur) return;
    onExtrasChange({ ...cur, guests: cur.guests.map((g) => (g.id === id ? fn(g) : g)) });
  };

  const checkIn = async (g: GuestEntry, count: number) => {
    const local = applyArrival(g, count);
    if (!local.ok || !local.entry) {
      setFlash({
        id: g.id,
        text: local.reason === 'voided' ? voidedText(g)
          : local.reason === 'checked-in-elsewhere' ? elsewhereText(g)
          : arrivalReasonText(local.reason ?? 'bad-count', local.remaining),
        ok: false,
      });
      return;
    }
    const after = local.entry;
    const ref = newRef();
    const at = now();
    // Decided on this device (offline, or the server didn't answer): the
    // door's times apply here too. A test-window arrival is never queued
    // (replayed after doors it would count for real).
    const queueIt = () => {
      const door = guestGate(gate, at);
      if (door === 'test') {
        setFlash({ id: g.id, text: 'TEST: not checked in (test window before doors, checked on the saved list).', ok: true });
        return;
      }
      if (door !== 'ok') {
        setFlash({ id: g.id, text: arrivalReasonText(door), ok: false });
        return;
      }
      persistPending(enqueueArrival(loadPendingArrivals(eventId), { ref, entryId: g.id, count, at, uid }));
      patchGuest(g.id, () => after);
      setFlash({ id: g.id, text: `${count} in (offline, will sync)`, ok: true });
    };
    if (isOffline) return queueIt();
    try {
      // Time-boxed; on a timeout the arrival is queued with the same ref, so
      // if the first call did land, the replay counts once.
      const r = await withDeadline(() => guestCheckIn(eventId, g.id, count, ref));
      if (r.ok && r.reason === 'test-scan') {
        setFlash({ id: g.id, text: 'TEST: not checked in (test window before doors, nothing recorded).', ok: true });
        return;
      }
      if (r.ok) {
        patchGuest(g.id, (e) => ({ ...e, arrived: r.arrived ?? after.arrived, arrivedAt: e.arrivedAt ?? new Date().toISOString() }));
        setFlash({ id: g.id, text: `${count} in · ${r.arrived ?? after.arrived}/${r.party ?? partySize(g)}`, ok: true });
        setCounts((c) => ({ ...c, [g.id]: 1 }));
        return;
      }
      if (typeof r.arrived === 'number') patchGuest(g.id, (e) => ({ ...e, arrived: r.arrived! }));
      if (r.reason === 'voided') {
        // Voided since this device downloaded the lists.
        patchGuest(g.id, (e) => ({ ...e, voided: true }));
        setFlash({ id: g.id, text: voidedText(g), ok: false });
        return;
      }
      if (r.reason === 'checked-in-elsewhere') {
        // Checked in on the selling platform since this device downloaded the lists.
        const elsewhere = mapElsewhere(r.elsewhere) ?? { where: g.source || 'Eventbrite', at: null, method: null };
        patchGuest(g.id, (e) => ({ ...e, elsewhere }));
        setFlash({ id: g.id, text: elsewhereText({ ...g, elsewhere }), ok: false });
        return;
      }
      setFlash({ id: g.id, text: arrivalReasonText(r.reason, r.remaining), ok: false });
    } catch (err) {
      if (isServerAnswer(err)) {
        console.error('guest check-in refused by the server', err);
        setFlash({
          id: g.id,
          text: doorAccessProblem(err) === 'not-assigned'
            ? NOT_ASSIGNED_TEXT
            : 'The server refused this check-in for this account. Sign in again or ask a manager.',
          ok: false,
        });
        return;
      }
      console.error('guest check-in failed; queued for sync', err);
      queueIt();
    }
  };

  const checkInByCode = (raw: string) => {
    const text = raw.trim();
    if (!text) return;
    const last = lastReadRef.current;
    if (last && last.text === text && Date.now() - last.at < 3_000) return;
    lastReadRef.current = { text, at: Date.now() };
    if (isExosCode(text)) {
      setCodeFlash({ text: 'That is an Exos ticket: scan it in Tickets mode.', ok: false });
      return;
    }
    const g = matchImported<GuestEntry>(text, byCode);
    if (!g) {
      setCodeFlash({ text: `Not on the imported lists (${text.slice(0, 24)}). Search the name instead.`, ok: false });
      return;
    }
    setQuery(g.guestName);
    setCode('');
    if (g.voided) {
      setCodeFlash({ text: voidedText(g), ok: false });
      return;
    }
    if (remainingFor(g) === 0) {
      setCodeFlash({ text: g.elsewhere && g.arrived === 0 ? elsewhereText(g) : `${g.guestName}: already checked in.`, ok: false });
      return;
    }
    setCodeFlash({
      text: `${g.guestName}${g.ticketLabel ? ` · ${g.ticketLabel}` : ''}${g.source ? ` · ${g.source} ticket` : ''}`,
      ok: true,
    });
    void checkIn(g, 1);
  };
  const checkInByCodeRef = useRef(checkInByCode);
  checkInByCodeRef.current = checkInByCode;

  // The camera for imported barcodes (same library as the ticket scanner).
  // stop() throws unless the camera is already scanning, so a close during
  // start-up waits for start() to finish and stops it then.
  useEffect(() => {
    if (!cameraOn) return undefined;
    let stopped = false;
    let inst: { start: (...a: any[]) => Promise<unknown>; stop: () => Promise<void>; clear: () => void; isScanning: boolean } | null = null;
    const shut = async () => {
      if (!inst) return;
      try {
        if (inst.isScanning) await inst.stop();
        inst.clear();
      } catch {
        /* already stopped */
      }
    };
    void (async () => {
      try {
        const { Html5Qrcode } = await import('html5-qrcode');
        if (stopped) return;
        inst = new Html5Qrcode('guest-reader') as unknown as typeof inst;
        await inst!.start(
          { facingMode: 'environment' },
          { fps: 10, qrbox: (vw: number, vh: number) => { const m = Math.floor(Math.min(vw, vh) * 0.7); return { width: m, height: m }; } },
          (decoded: string) => checkInByCodeRef.current(decoded),
          () => {},
        );
        if (stopped) await shut();
      } catch (err) {
        if (stopped) return;
        console.error('guest camera failed', err);
        toast({ kind: 'error', message: 'Could not open the camera. Allow camera access, or type the code.' });
        setCameraOn(false);
      }
    })();
    return () => {
      stopped = true;
      void shut();
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [cameraOn]);

  const hasCodes = byCode.size > 0;

  useEffect(() => {
    if (!incomingCode) return;
    lastReadRef.current = null;
    checkInByCodeRef.current(incomingCode.text);
    // Handled once: switching tabs later must not replay it.
    onIncomingHandled?.();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [incomingCode?.at]);

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

      {hasCodes && (
        <div className="mb-4 rounded-2xl border border-slate-200 p-3">
          <form
            onSubmit={(e) => {
              e.preventDefault();
              lastReadRef.current = null;
              checkInByCode(code);
            }}
            className="flex gap-2"
          >
            <label htmlFor="guest-code" className="sr-only">Ticket code from another platform</label>
            <div className="relative flex-1">
              <ScanLine className="absolute left-3 top-1/2 -translate-y-1/2 text-slate-400 w-4 h-4" />
              <input
                id="guest-code"
                value={code}
                onChange={(e) => setCode(e.target.value)}
                placeholder="Scan or type a ticket code"
                autoComplete="off"
                className="w-full bg-slate-50 rounded-xl py-3 pl-9 pr-3 text-slate-900 font-mono text-sm focus:outline-none focus-visible:ring-2 focus-visible:ring-brand-primary/60"
              />
            </div>
            <button type="submit" className="px-3 py-2 bg-slate-900 text-white rounded-xl text-[10px] font-black uppercase tracking-widest">
              Check in
            </button>
            <button
              type="button"
              onClick={() => setCameraOn((v) => !v)}
              aria-label={cameraOn ? 'Close the camera' : 'Scan with the camera'}
              className="px-3 py-2 border border-slate-200 rounded-xl text-slate-600"
            >
              {cameraOn ? <CameraOff className="w-4 h-4" /> : <Camera className="w-4 h-4" />}
            </button>
          </form>
          {cameraOn && <div id="guest-reader" className="mt-3 overflow-hidden rounded-xl bg-black" />}
          {codeFlash && (
            <p role="status" className={`mt-2 text-[12px] font-bold ${codeFlash.ok ? 'text-emerald-600' : 'text-rose-500'}`}>
              {codeFlash.text}
            </p>
          )}
        </div>
      )}

      <div className="relative mb-4">
        <input
          type="search"
          autoFocus={!hasCodes}
          placeholder="Search a name…"
          value={query}
          onChange={(e) => setQuery(e.target.value)}
          className="w-full bg-slate-50 border-2 border-transparent rounded-2xl py-4 pl-12 pr-4 text-slate-900 focus:outline-none focus-visible:ring-2 focus-visible:ring-brand-primary/60 focus:border-tm-blue"
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
              <li key={g.id} className={`px-4 py-3 ${g.voided ? 'bg-rose-50/60' : left === 0 ? 'bg-emerald-50/40' : 'bg-white'}`}>
                <div className="flex items-center gap-3">
                  <span className="min-w-0 flex-1">
                    <span className="block font-bold text-slate-900 truncate">
                      {g.guestName}
                      {g.plusOnes > 0 && <span className="text-slate-500 font-medium"> +{g.plusOnes}</span>}
                    </span>
                    <span className="block text-[11px] text-slate-400 truncate">
                      {listName[g.listId] ?? 'Guest list'}
                      {g.ticketLabel ? ` · ${g.ticketLabel}` : ''}
                      {g.source ? ` · ${g.source}` : ''}
                      {g.note ? ` · ${g.note}` : ''}
                    </span>
                    {(g.accessNeeds?.length ?? 0) > 0 && (
                      <span className="block mt-1"><AccessNeedBadges needs={g.accessNeeds!} /></span>
                    )}
                  </span>
                  <span className="inline-flex items-center gap-1 text-[11px] font-bold text-slate-600 shrink-0">
                    <Users className="w-3.5 h-3.5" /> {headsIn(g)}/{partySize(g)}
                  </span>
                  {g.elsewhere && !g.voided && (
                    <span
                      className="text-[10px] font-black text-sky-700 uppercase tracking-widest shrink-0"
                      title={elsewhereText(g)}
                    >
                      In on {g.elsewhere.where}
                    </span>
                  )}
                  {g.voided ? (
                    <span className="inline-flex items-center gap-1 text-[10px] font-black text-rose-600 uppercase tracking-widest shrink-0">
                      <Ban className="w-4 h-4" /> {g.voidReason || 'Refunded'}
                    </span>
                  ) : left > 0 ? (
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
