// A hold, opened from the booking calendar (docs/booking.md): pencil new
// nights, move a night up or down its line, clear nights, or convert one
// night into a draft event (then Edit Event opens). Every write goes through
// the exos_hold_* functions, which renumber the lines and promote the holds
// behind a cleared night. Owners and managers write; other staff read.

import { useMemo, useState, type FormEvent } from 'react';
import { useNavigate } from 'react-router-dom';
import { ArrowDown, ArrowUp, CalendarCheck, Plus, Trash2, X } from 'lucide-react';
import Dialog from '../Dialog';
import { useToast } from '../../context/ToastContext';
import { clearHold, convertHold, createHold, updateHold, type NewNight } from '../../lib/bookingApi';
import { createOffer } from '../../lib/offersApi';
import { lineFor, placeLabel, type Hold, type HoldPosition, type HoldRental, type Room, type Venue } from '../../lib/booking';
import { RelationshipBadge, field, label } from './VenueManager';

export type DrawerTarget = { kind: 'new'; date: string; venueId?: string; roomId?: string } | { kind: 'hold'; hold: Hold };

interface Props {
  canEdit: boolean;
  orgId: string;
  target: DrawerTarget;
  venues: Venue[];
  rooms: Room[];
  /** Every hold loaded for the month, to show each night's line. */
  holds: Hold[];
  onClose: (changed: boolean) => void;
}

const blankRental = (): HoldRental => ({ status: 'requested', fee: null, deposit: null, currency: 'USD', notes: '' });
const money = (s: string): number | null => (s.trim() === '' || !Number.isFinite(Number(s)) ? null : Math.max(0, Number(s)));

export default function HoldDrawer({ canEdit, orgId, target, venues, rooms, holds, onClose }: Props) {
  const navigate = useNavigate();
  const { toast } = useToast();
  const existing = target.kind === 'hold' ? target.hold : null;
  const [hold, setHold] = useState<Hold | null>(existing);
  const [changed, setChanged] = useState(false);
  const [busy, setBusy] = useState(false);
  const [title, setTitle] = useState(existing?.title ?? '');
  const [notes, setNotes] = useState(existing?.notes ?? '');
  const [rental, setRental] = useState<HoldRental | null>(existing?.rental ?? null);
  const firstVenue = target.kind === 'new' ? target.venueId ?? venues[0]?.id ?? '' : '';
  const [night, setNight] = useState<NewNight>({
    date: target.kind === 'new' ? target.date : '', venueId: firstVenue,
    roomId: target.kind === 'new' ? target.roomId ?? null : null, level: null, startTime: '20:00',
  });
  const [convertTime, setConvertTime] = useState<Record<string, string>>({});
  const [clearOthers, setClearOthers] = useState(false);

  const venueById = useMemo(() => new Map(venues.map((v) => [v.id, v])), [venues]);
  const roomById = useMemo(() => new Map(rooms.map((r) => [r.id, r])), [rooms]);
  const where = (p: { venueId: string; roomId: string | null }) => placeLabel(venueById.get(p.venueId), p.roomId ? roomById.get(p.roomId) : null);
  const nightVenue = venueById.get(night.venueId);
  const rentedVenue = (hold?.positions ?? []).some((p) => venueById.get(p.venueId)?.relationship !== 'owned')
    || (!!nightVenue && nightVenue.relationship !== 'owned');

  // The month's holds with this one swapped for its latest version.
  const allHolds = useMemo(() => (hold ? [...holds.filter((h) => h.id !== hold.id), hold] : holds), [holds, hold]);
  const active = (hold?.positions ?? []).filter((p) => p.status === 'active');
  const done = (hold?.positions ?? []).filter((p) => p.status !== 'active');

  const close = () => onClose(changed);
  const fail = (e: unknown, fallback: string) => toast({ kind: 'error', message: (e as Error)?.message || fallback });
  const after = (h: Hold, msg: string) => {
    setHold(h);
    setChanged(true);
    toast({ kind: 'success', message: msg });
  };
  const rentalPatch = () => (rentedVenue ? rental : undefined);

  const create = async (e: FormEvent) => {
    e.preventDefault();
    if (!title.trim()) return toast({ kind: 'error', message: 'Give the hold a title.' });
    if (!night.date || !night.venueId) return toast({ kind: 'error', message: 'Pick a date and a venue.' });
    setBusy(true);
    try {
      const h = await createHold(orgId, { title: title.trim(), notes, rental: rentalPatch() ?? null }, [night]);
      after(h, `Held at level ${h.positions[0]?.level ?? 1}.`);
    } catch (err) {
      fail(err, 'Could not create the hold.');
    } finally {
      setBusy(false);
    }
  };

  const saveDetails = async () => {
    if (!hold) return;
    setBusy(true);
    try {
      after(await updateHold(hold.id, { title: title.trim(), notes, ...(rentedVenue ? { rental } : {}) }), 'Saved.');
    } catch (err) {
      fail(err, 'Could not save the hold.');
    } finally {
      setBusy(false);
    }
  };

  const move = async (p: HoldPosition, level: number) => {
    if (!hold || level < 1) return;
    setBusy(true);
    try {
      const h = await updateHold(hold.id, {}, active.map((x) => (x.id === p.id ? { id: x.id, level } : { id: x.id })));
      after(h, `Moved to level ${h.positions.find((x) => x.id === p.id)?.level ?? level}.`);
    } catch (err) {
      fail(err, 'Could not move the hold.');
    } finally {
      setBusy(false);
    }
  };

  const addNight = async (e: FormEvent) => {
    e.preventDefault();
    if (!hold || !night.date || !night.venueId) return;
    setBusy(true);
    try {
      after(await updateHold(hold.id, {}, [...active.map((x) => ({ id: x.id })), night]), 'Night added.');
    } catch (err) {
      fail(err, 'Could not add the night.');
    } finally {
      setBusy(false);
    }
  };

  const clear = async (p?: HoldPosition) => {
    if (!hold) return;
    if (!p && !window.confirm('Release every night of this hold? The holds behind it move up.')) return;
    setBusy(true);
    try {
      after(await clearHold(hold.id, p ? [p.id] : undefined), p ? 'Night released; the holds behind it moved up.' : 'Hold released.');
    } catch (err) {
      fail(err, 'Could not clear the hold.');
    } finally {
      setBusy(false);
    }
  };

  // An offer from this hold: its nights, venue, room, first artist and (for a
  // rented room) a Venue rental budget line (docs/offers-settlements.md).
  const makeOffer = async () => {
    if (!hold) return;
    setBusy(true);
    try {
      const o = await createOffer(orgId, { hold_id: hold.id });
      navigate(`/orgs/${orgId}/offers/${o.id}`);
    } catch (err) {
      fail(err, 'Could not make the offer (an artist is needed: add one to the hold first).');
      setBusy(false);
    }
  };

  const convert = async (p: HoldPosition) => {
    if (!hold) return;
    setBusy(true);
    try {
      const out = await convertHold(hold.id, p.id, { time: convertTime[p.id] || p.startTime || '20:00', clearHoldsOnDay: clearOthers });
      toast({ kind: 'success', message: 'Draft event created. Finish it and publish when ready.' });
      onClose(true);
      navigate(`/edit-event/${out.eventId}`);
    } catch (err) {
      fail(err, 'Could not convert the night.');
      setBusy(false);
    }
  };

  const roomsOf = (venueId: string) => rooms.filter((r) => r.venueId === venueId);
  const nightFields = (
    <>
      <label className="space-y-1"><span className={label}>Date</span>
        <input type="date" className={field} value={night.date} onChange={(e) => setNight({ ...night, date: e.target.value })} required />
      </label>
      <label className="space-y-1"><span className={label}>Venue</span>
        <select className={field} value={night.venueId} onChange={(e) => setNight({ ...night, venueId: e.target.value, roomId: null })} required>
          {venues.map((v) => <option key={v.id} value={v.id}>{v.name}{v.relationship !== 'owned' ? ` (${v.relationship})` : ''}</option>)}
        </select>
      </label>
      <label className="space-y-1"><span className={label}>Room</span>
        <select className={field} value={night.roomId ?? ''} onChange={(e) => setNight({ ...night, roomId: e.target.value || null })}>
          <option value="">Whole venue</option>
          {roomsOf(night.venueId).map((r) => <option key={r.id} value={r.id}>{r.name}</option>)}
        </select>
      </label>
      <label className="space-y-1"><span className={label}>Level (blank = end of line)</span>
        <input className={field} inputMode="numeric" value={night.level ?? ''} onChange={(e) => setNight({ ...night, level: e.target.value ? Math.max(1, Math.min(50, Number(e.target.value) || 1)) : null })} />
      </label>
      <label className="space-y-1"><span className={label}>Show time</span>
        <input type="time" className={field} value={night.startTime ?? ''} onChange={(e) => setNight({ ...night, startTime: e.target.value })} />
      </label>
    </>
  );

  const rentalFields = rentedVenue && canEdit ? (
    <fieldset className="sm:col-span-2 grid gap-2 sm:grid-cols-4 border border-amber-400/20 p-3">
      <legend className={`${label} px-1`}>Rental terms</legend>
      {!rental ? (
        <button type="button" onClick={() => setRental(blankRental())} className="sm:col-span-4 text-left text-[11px] font-black uppercase text-brand-primary">+ Add rental terms</button>
      ) : (
        <>
          <select className={field} aria-label="Rental status" value={rental.status} onChange={(e) => setRental({ ...rental, status: e.target.value as HoldRental['status'] })}>
            <option value="requested">Requested</option><option value="confirmed">Confirmed</option><option value="declined">Declined</option>
          </select>
          <input className={field} aria-label="Rental fee" placeholder="Fee" inputMode="decimal" value={rental.fee ?? ''} onChange={(e) => setRental({ ...rental, fee: money(e.target.value) })} />
          <input className={field} aria-label="Deposit" placeholder="Deposit" inputMode="decimal" value={rental.deposit ?? ''} onChange={(e) => setRental({ ...rental, deposit: money(e.target.value) })} />
          <input className={field} aria-label="Currency" maxLength={3} value={rental.currency} onChange={(e) => setRental({ ...rental, currency: e.target.value.toUpperCase() })} />
          <input className={`${field} sm:col-span-3`} aria-label="Rental notes" placeholder="Notes" value={rental.notes} onChange={(e) => setRental({ ...rental, notes: e.target.value })} />
          <button type="button" onClick={() => setRental(null)} className="text-[11px] font-black uppercase text-white/50">Remove</button>
        </>
      )}
    </fieldset>
  ) : null;

  return (
    <Dialog open onClose={close} labelledBy="hold-drawer-title" dismissible={!busy} placement="sheet"
      className="w-full sm:max-w-2xl max-h-[90vh] overflow-y-auto bg-black border border-white/10 p-6">
      <div className="flex items-start justify-between gap-3 mb-4">
        <h2 id="hold-drawer-title" className="disp text-2xl uppercase tracking-wide text-white">
          {hold ? hold.title : 'New hold'}
          {hold ? <span className="type text-[10px] uppercase tracking-widest text-white/40 ml-3">{hold.status}</span> : null}
        </h2>
        <button type="button" onClick={close} className="p-2 text-white/50 hover:text-white" aria-label="Close"><X className="w-5 h-5" /></button>
      </div>

      {!hold ? (
        <form onSubmit={create} className="grid gap-3 sm:grid-cols-2">
          <label className="sm:col-span-2 space-y-1"><span className={label}>Title</span>
            <input className={field} value={title} onChange={(e) => setTitle(e.target.value)} maxLength={100} placeholder="Artist or show" autoFocus required />
          </label>
          {nightFields}
          <label className="sm:col-span-2 space-y-1"><span className={label}>Notes</span>
            <textarea className={field} rows={2} value={notes} onChange={(e) => setNotes(e.target.value)} maxLength={2000} />
          </label>
          {rentalFields}
          <button disabled={busy || !canEdit} className="sm:col-span-2 bg-brand-primary text-black px-4 py-2 text-sm font-black uppercase disabled:opacity-50">Hold this date</button>
        </form>
      ) : (
        <div className="space-y-6">
          {canEdit ? (
            <div className="grid gap-3 sm:grid-cols-2">
              <label className="sm:col-span-2 space-y-1"><span className={label}>Title</span>
                <input className={field} value={title} onChange={(e) => setTitle(e.target.value)} maxLength={100} />
              </label>
              <label className="sm:col-span-2 space-y-1"><span className={label}>Notes</span>
                <textarea className={field} rows={2} value={notes} onChange={(e) => setNotes(e.target.value)} maxLength={2000} />
              </label>
              {rentalFields}
              <button type="button" disabled={busy} onClick={saveDetails} className="sm:col-span-2 border border-white/20 px-4 py-2 text-xs font-black uppercase text-white hover:border-brand-primary disabled:opacity-50">Save details</button>
            </div>
          ) : hold.notes ? <p className="text-sm text-white/70 whitespace-pre-wrap">{hold.notes}</p> : null}

          <section aria-labelledby="hold-nights">
            <h3 id="hold-nights" className={`${label} mb-2`}>Nights held</h3>
            {active.length === 0 ? <p className="text-sm text-white/50">No night is held now.</p> : null}
            <ul className="space-y-2">
              {active.map((p) => {
                const line = lineFor(allHolds, p);
                const v = venueById.get(p.venueId);
                return (
                  <li key={p.id} className="border border-white/10 p-3" data-testid={`hold-night-${p.date}`}>
                    <div className="flex flex-wrap items-center gap-2">
                      <span className={`type text-xs font-black px-2 py-0.5 ${p.level === 1 ? 'bg-green-500/15 text-green-300' : 'bg-amber-500/15 text-amber-300'}`}>H{p.level}</span>
                      <span className="font-black text-white">{p.date}</span>
                      <span className="text-xs text-white/60">{where(p)}</span>
                      {v ? <RelationshipBadge venue={v} /> : null}
                      {p.isTarget ? <span className="type text-[9px] uppercase tracking-widest text-brand-primary">target</span> : null}
                      <span className="type text-[10px] text-white/40">{line.length > 1 ? `${line.length} holds that night` : 'only hold that night'}</span>
                      {canEdit ? (
                        <span className="ml-auto flex items-center gap-1">
                          <button type="button" disabled={busy || p.level === 1} onClick={() => move(p, p.level - 1)} className="p-2 text-white/50 hover:text-white disabled:opacity-30" aria-label={`Move up to level ${p.level - 1}`}><ArrowUp className="w-4 h-4" /></button>
                          <button type="button" disabled={busy || p.level >= line.length} onClick={() => move(p, p.level + 1)} className="p-2 text-white/50 hover:text-white disabled:opacity-30" aria-label={`Move down to level ${p.level + 1}`}><ArrowDown className="w-4 h-4" /></button>
                          <button type="button" disabled={busy} onClick={() => clear(p)} className="p-2 text-white/50 hover:text-red-400" aria-label={`Release ${p.date}`}><Trash2 className="w-4 h-4" /></button>
                        </span>
                      ) : null}
                    </div>
                    {line.length > 1 ? (
                      <ol className="mt-2 text-[11px] text-white/50 list-decimal list-inside">
                        {line.map((x) => <li key={x.pos.id} className={x.hold.id === hold.id ? 'text-white' : ''}>{x.hold.title}</li>)}
                      </ol>
                    ) : null}
                    {canEdit ? (
                      <div className="mt-3 flex flex-wrap items-end gap-2">
                        <label className="space-y-1"><span className={label}>Show time</span>
                          <input type="time" className={`${field} w-32`} value={convertTime[p.id] ?? p.startTime ?? '20:00'} onChange={(e) => setConvertTime({ ...convertTime, [p.id]: e.target.value })} />
                        </label>
                        <button type="button" disabled={busy} onClick={() => convert(p)} className="inline-flex items-center gap-1 bg-brand-primary text-black px-3 py-2 text-xs font-black uppercase disabled:opacity-50">
                          <CalendarCheck className="w-4 h-4" aria-hidden="true" /> Convert to event
                        </button>
                      </div>
                    ) : null}
                  </li>
                );
              })}
            </ul>
            {canEdit && active.length > 0 ? (
              <label className="mt-3 flex items-center gap-2 text-xs text-white/60">
                <input type="checkbox" checked={clearOthers} onChange={(e) => setClearOthers(e.target.checked)} />
                When converting, also release every other hold at that venue that date
              </label>
            ) : null}
          </section>

          {done.length ? (
            <section aria-labelledby="hold-done">
              <h3 id="hold-done" className={`${label} mb-2`}>Released and converted</h3>
              <ul className="text-xs text-white/50 space-y-1">
                {done.map((p) => (
                  <li key={p.id}>
                    {p.date} · {where(p)} · {p.status}
                    {p.eventId ? <button type="button" onClick={() => { onClose(changed); navigate(`/edit-event/${p.eventId}`); }} className="ml-2 text-brand-primary underline">open event</button> : null}
                  </li>
                ))}
              </ul>
            </section>
          ) : null}

          {canEdit && hold.status !== 'converted' ? (
            <form onSubmit={addNight} className="grid gap-3 sm:grid-cols-2 border-t border-white/10 pt-4" aria-label="Add a night">
              {nightFields}
              <button disabled={busy} className="sm:col-span-2 inline-flex items-center justify-center gap-1 border border-white/20 px-4 py-2 text-xs font-black uppercase text-white hover:border-brand-primary disabled:opacity-50">
                <Plus className="w-4 h-4" aria-hidden="true" /> Add night
              </button>
            </form>
          ) : null}

          {canEdit && active.length > 0 ? (
            <button type="button" disabled={busy} onClick={makeOffer} className="text-xs font-black uppercase text-brand-primary hover:underline mr-4">
              Make offer
            </button>
          ) : null}

          {canEdit && active.length > 0 ? (
            <button type="button" disabled={busy} onClick={() => clear()} className="text-xs font-black uppercase text-red-400 hover:text-red-300">Release the whole hold</button>
          ) : null}
        </div>
      )}
    </Dialog>
  );
}
