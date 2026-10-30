// Booking on one event (docs/booking.md): its venue and room link, the day-of
// show schedule, staff notes and contacts. Mounted in Edit Event; the door
// page shows the schedule read-only (ShowScheduleList).
//
// The doors row and the event's doors time are one fact: the database moves
// one when the other changes (mig 20261030100000), and onDoorsChange keeps
// Edit Event's form in step so saving the form doesn't put the old time back.
// Notes and contacts are staff-only: RLS never returns them to door staff.

import { useCallback, useEffect, useMemo, useState, type FormEvent } from 'react';
import { Building2, Clock, NotebookPen, Pencil, Phone, Plus, Trash2, Users, X } from 'lucide-react';
import { supabase } from '../../lib/supabase';
import { useToast } from '../../context/ToastContext';
import {
  addNote, clearEventDoors, deleteContact, deleteNote, deleteShowActivity, listContacts, listNotes, listRooms,
  listShowActivities, listVenues, saveContact, saveShowActivity, setEventVenue, type ContactInput,
} from '../../lib/bookingApi';
import {
  CONTACT_ROLES, KIND_LABELS, SHOW_ACTIVITY_KINDS, activityProblem, placeLabel, withImpliedDoors,
  type ContactRole, type EventContact, type EventNote, type Room, type ShowActivity, type ShowActivityKind, type Venue,
} from '../../lib/booking';
import { formatInTz, utcToZonedWallClock, zonedWallClockToUtc, getBrowserTimezone } from '../../lib/datetime';
import { field, label } from './VenueManager';

interface EventRow {
  org_id: string;
  starts_at: string | null;
  doors_at: string | null;
  timezone: string | null;
  exos_venue_id: string | null;
  exos_room_id: string | null;
  hold_id: string | null;
}

async function loadEvent(eventId: string): Promise<EventRow | null> {
  const { data, error } = await supabase.from('exos_events')
    .select('org_id, starts_at, doors_at, timezone, exos_venue_id, exos_room_id, hold_id').eq('id', eventId).maybeSingle();
  if (error) throw error;
  return data as EventRow | null;
}

const timeOf = (iso: string, tz: string | null) => formatInTz(new Date(iso), tz ?? undefined, { hour: 'numeric', minute: '2-digit' });

/** The schedule as a read-only list (door page header, and the panel). */
export function ShowScheduleList({ rows, timezone, light = false }: { rows: ShowActivity[]; timezone: string | null; light?: boolean }) {
  if (rows.length === 0) return null;
  const strong = light ? 'text-slate-900' : 'text-white';
  const soft = light ? 'text-slate-500' : 'text-white/50';
  return (
    <ol className="space-y-1" aria-label="Show schedule">
      {rows.map((r) => (
        <li key={r.id} className="flex items-baseline gap-3 text-sm" data-testid={`schedule-row-${r.kind}`}>
          <span className={`type text-xs w-20 shrink-0 ${soft}`}>{timeOf(r.startsAt, timezone)}{r.endsAt ? `–${timeOf(r.endsAt, timezone)}` : ''}</span>
          <span className={`font-bold ${r.isSet ? strong : `${soft} italic`}`}>{r.name}</span>
          {!r.isSet ? <span className={`type text-[9px] uppercase tracking-widest ${soft}`}>tbc</span> : null}
          {r.notes ? <span className={`text-xs truncate ${soft}`}>{r.notes}</span> : null}
        </li>
      ))}
    </ol>
  );
}

/** Loads and shows an event's schedule read-only; renders nothing when empty or not allowed. */
export function EventScheduleReadOnly({ eventId, light = false }: { eventId: string; light?: boolean }) {
  const [rows, setRows] = useState<ShowActivity[]>([]);
  const [tz, setTz] = useState<string | null>(null);
  useEffect(() => {
    let live = true;
    Promise.all([loadEvent(eventId), listShowActivities(eventId)])
      .then(([ev, acts]) => {
        if (!live) return;
        setTz(ev?.timezone ?? null);
        setRows(withImpliedDoors(acts, eventId, ev?.doors_at));
      })
      .catch(() => { /* not allowed or not migrated yet: show nothing */ });
    return () => { live = false; };
  }, [eventId]);
  if (rows.length === 0) return null;
  return (
    <section className={light ? 'bg-white p-6 rounded-2xl border border-slate-200 shadow-sm' : 'bg-[#111] border border-white/10 p-4'} aria-labelledby="door-schedule">
      <h2 id="door-schedule" className={`type text-[10px] uppercase tracking-widest mb-2 flex items-center gap-2 ${light ? 'text-slate-500' : 'text-white/50'}`}><Clock className="w-3 h-3" aria-hidden="true" /> Show schedule</h2>
      <ShowScheduleList rows={rows} timezone={tz} light={light} />
    </section>
  );
}

interface Props {
  eventId: string;
  /** Owner / manager: may change the venue link. */
  canEditVenue: boolean;
  /** Owner / manager / content: may edit the schedule, notes and contacts. */
  canEdit: boolean;
  /** Shown as the author of notes written here. */
  authorName: string;
  /** The event's doors time changed through the schedule (ISO, or null). */
  onDoorsChange?: (iso: string | null) => void;
}

interface ActivityDraft {
  id?: string;
  kind: ShowActivityKind;
  name: string;
  start: string; // datetime-local in the event's zone
  end: string;
  notes: string;
  isSet: boolean;
}

const BLANK_CONTACT: ContactInput = { role: 'other', title: '', name: '', email: '', phone: '', company: '', notes: '' };

export default function EventBookingPanels({ eventId, canEditVenue, canEdit, authorName, onDoorsChange }: Props) {
  const { toast } = useToast();
  const [ev, setEv] = useState<EventRow | null>(null);
  const [venues, setVenues] = useState<Venue[]>([]);
  const [rooms, setRooms] = useState<Room[]>([]);
  const [acts, setActs] = useState<ShowActivity[]>([]);
  const [notes, setNotes] = useState<EventNote[]>([]);
  const [contacts, setContacts] = useState<EventContact[]>([]);
  const [draft, setDraft] = useState<ActivityDraft | null>(null);
  const [noteText, setNoteText] = useState('');
  const [contact, setContact] = useState<{ id?: string; input: ContactInput } | null>(null);
  const [busy, setBusy] = useState(false);
  const [unavailable, setUnavailable] = useState(false);

  const tz = ev?.timezone || getBrowserTimezone();
  const fail = useCallback((e: unknown, fallback: string) => toast({ kind: 'error', message: (e as Error)?.message || fallback }), [toast]);

  const load = useCallback(async () => {
    try {
      const row = await loadEvent(eventId);
      if (!row) return null;
      setEv(row);
      const [vs, rs, as, ns, cs] = await Promise.all([
        listVenues(row.org_id), listRooms(row.org_id), listShowActivities(eventId), listNotes(eventId), listContacts(eventId),
      ]);
      setVenues(vs);
      setRooms(rs);
      setActs(as);
      setNotes(ns);
      setContacts(cs);
      return row;
    } catch {
      // Booking tables not there yet (or no access): hide the panels.
      setUnavailable(true);
      return null;
    }
  }, [eventId]);

  useEffect(() => { void load(); }, [load]);

  const schedule = useMemo(() => withImpliedDoors(acts, eventId, ev?.doors_at), [acts, eventId, ev?.doors_at]);
  if (unavailable || !ev) return null;

  const reloadDoors = async (before: string | null) => {
    const row = await load();
    if (row && row.doors_at !== before) onDoorsChange?.(row.doors_at);
  };

  const pickVenue = async (venueId: string, roomId: string | null) => {
    setBusy(true);
    try {
      await setEventVenue(eventId, venueId || null, roomId);
      await load();
    } catch (e) {
      fail(e, 'Could not link the venue.');
    } finally {
      setBusy(false);
    }
  };

  const editRow = (r?: ShowActivity) => setDraft(r
    ? { id: r.implied ? undefined : r.id, kind: r.kind, name: r.name, start: utcToZonedWallClock(new Date(r.startsAt), tz), end: r.endsAt ? utcToZonedWallClock(new Date(r.endsAt), tz) : '', notes: r.notes, isSet: r.isSet }
    : { kind: 'load_in', name: '', start: ev.starts_at ? utcToZonedWallClock(new Date(ev.starts_at), tz) : '', end: '', notes: '', isSet: true });

  const saveRow = async (e: FormEvent) => {
    e.preventDefault();
    if (!draft) return;
    const startsAt = draft.start ? zonedWallClockToUtc(draft.start, tz)?.toISOString() ?? null : null;
    const endsAt = draft.end ? zonedWallClockToUtc(draft.end, tz)?.toISOString() ?? null : null;
    const problem = activityProblem({ kind: draft.kind, startsAt, endsAt }, {
      eventStartsAt: ev.starts_at,
      hasOtherDoors: acts.some((a) => a.kind === 'doors' && a.id !== draft.id),
    });
    if (problem) return toast({ kind: 'error', message: problem });
    setBusy(true);
    try {
      await saveShowActivity(eventId, ev.org_id, {
        kind: draft.kind, name: draft.name.trim() || KIND_LABELS[draft.kind], startsAt: startsAt!, endsAt, notes: draft.notes,
        isSet: draft.isSet, showInAdvance: true,
      }, draft.id);
      setDraft(null);
      await reloadDoors(ev.doors_at);
    } catch (err) {
      fail(err, 'Could not save the row.');
    } finally {
      setBusy(false);
    }
  };

  const removeRow = async (r: ShowActivity) => {
    setBusy(true);
    try {
      if (r.implied) await clearEventDoors(eventId);
      else await deleteShowActivity(r.id);
      await reloadDoors(ev.doors_at);
    } catch (err) {
      fail(err, 'Could not delete the row.');
    } finally {
      setBusy(false);
    }
  };

  const postNote = async (e: FormEvent) => {
    e.preventDefault();
    if (!noteText.trim()) return;
    setBusy(true);
    try {
      await addNote(eventId, ev.org_id, noteText, authorName);
      setNoteText('');
      setNotes(await listNotes(eventId));
    } catch (err) {
      fail(err, 'Could not add the note.');
    } finally {
      setBusy(false);
    }
  };

  const removeNote = async (n: EventNote) => {
    try {
      await deleteNote(n.id);
      setNotes(await listNotes(eventId));
    } catch (err) {
      fail(err, 'Could not delete the note.');
    }
  };

  const submitContact = async (e: FormEvent) => {
    e.preventDefault();
    if (!contact) return;
    if (!contact.input.name.trim()) return toast({ kind: 'error', message: 'Give the contact a name.' });
    setBusy(true);
    try {
      await saveContact(eventId, ev.org_id, contact.input, contact.id);
      setContact(null);
      setContacts(await listContacts(eventId));
    } catch (err) {
      fail(err, 'Could not save the contact.');
    } finally {
      setBusy(false);
    }
  };

  const removeContact = async (c: EventContact) => {
    try {
      await deleteContact(c.id);
      setContacts(await listContacts(eventId));
    } catch (err) {
      fail(err, 'Could not delete the contact.');
    }
  };

  const venue = venues.find((v) => v.id === ev.exos_venue_id);
  const room = rooms.find((r) => r.id === ev.exos_room_id);

  return (
    <section className="bg-[#111] border border-white/10 p-6 md:p-8 space-y-8" aria-labelledby="booking-panels">
      <div className="flex items-center space-x-3">
        <Building2 className="text-brand-primary w-5 h-5" aria-hidden="true" />
        <h2 id="booking-panels" className="disp text-lg uppercase tracking-wide text-white leading-none">Booking and show day</h2>
      </div>

      {/* Venue link */}
      <div className="space-y-2">
        <p className={label}>Booked venue</p>
        {venues.length === 0 ? (
          <p className="text-xs text-white/50">No venues yet: add them on the booking calendar.</p>
        ) : canEditVenue ? (
          <div className="grid gap-2 sm:grid-cols-2">
            <select className={field} aria-label="Booked venue" value={ev.exos_venue_id ?? ''} disabled={busy}
              onChange={(e) => void pickVenue(e.target.value, null)}>
              <option value="">Not linked (venue typed above)</option>
              {venues.map((v) => <option key={v.id} value={v.id}>{v.name}{v.relationship !== 'owned' ? ` (${v.relationship})` : ''}</option>)}
            </select>
            <select className={field} aria-label="Booked room" value={ev.exos_room_id ?? ''} disabled={busy || !ev.exos_venue_id}
              onChange={(e) => void pickVenue(ev.exos_venue_id ?? '', e.target.value || null)}>
              <option value="">Whole venue</option>
              {rooms.filter((r) => r.venueId === ev.exos_venue_id).map((r) => <option key={r.id} value={r.id}>{r.name}</option>)}
            </select>
          </div>
        ) : (
          <p className="text-sm text-white">{venue ? placeLabel(venue, room) : 'Not linked'}</p>
        )}
        <p className="text-[11px] text-white/40">Linking puts the show on the booking calendar, so holds in that room that night show as challenged. The venue name and address on the event page stay as typed above.</p>
      </div>

      {/* Show schedule */}
      <div className="space-y-3">
        <div className="flex items-center justify-between">
          <p className={`${label} flex items-center gap-2`}><Clock className="w-3 h-3" aria-hidden="true" /> Show schedule</p>
          {canEdit && !draft ? (
            <button type="button" onClick={() => editRow()} className="inline-flex items-center gap-1 text-[11px] font-black uppercase text-brand-primary"><Plus className="w-3 h-3" aria-hidden="true" /> Add row</button>
          ) : null}
        </div>
        {schedule.length === 0 && !draft ? <p className="text-xs text-white/50">No schedule yet. Load in, soundcheck, doors, sets and curfew go here; the door team sees it.</p> : null}
        <ul className="space-y-1" data-testid="show-schedule">
          {schedule.map((r) => (
            <li key={r.id} className="flex flex-wrap items-center gap-3 border border-white/10 px-3 py-2" data-testid={`schedule-row-${r.kind}`}>
              <span className="type text-xs text-white/70 w-24">{timeOf(r.startsAt, ev.timezone)}{r.endsAt ? `–${timeOf(r.endsAt, ev.timezone)}` : ''}</span>
              <span className={`font-bold ${r.isSet ? 'text-white' : 'text-white/50 italic'}`}>{r.name}</span>
              <span className="type text-[9px] uppercase tracking-widest text-white/40">{KIND_LABELS[r.kind]}{r.implied ? ' · from doors open' : ''}{!r.isSet ? ' · tbc' : ''}</span>
              {r.notes ? <span className="text-xs text-white/50">{r.notes}</span> : null}
              {canEdit ? (
                <span className="ml-auto flex gap-1">
                  <button type="button" onClick={() => editRow(r)} className="p-1 text-white/40 hover:text-white" aria-label={`Edit ${r.name}`}><Pencil className="w-3.5 h-3.5" /></button>
                  <button type="button" onClick={() => removeRow(r)} disabled={busy} className="p-1 text-white/40 hover:text-red-400" aria-label={`Delete ${r.name}`}><Trash2 className="w-3.5 h-3.5" /></button>
                </span>
              ) : null}
            </li>
          ))}
        </ul>
        {draft ? (
          <form onSubmit={saveRow} className="grid gap-2 sm:grid-cols-6 border border-white/10 p-3" aria-label="Schedule row">
            <select className={field} aria-label="Kind" value={draft.kind} onChange={(e) => setDraft({ ...draft, kind: e.target.value as ShowActivityKind })}>
              {SHOW_ACTIVITY_KINDS.map((k) => <option key={k} value={k}>{KIND_LABELS[k]}</option>)}
            </select>
            <input className={`${field} sm:col-span-2`} aria-label="Name" placeholder={KIND_LABELS[draft.kind]} value={draft.name} onChange={(e) => setDraft({ ...draft, name: e.target.value })} maxLength={80} />
            <input className={field} type="datetime-local" aria-label="Starts" value={draft.start} onChange={(e) => setDraft({ ...draft, start: e.target.value })} required />
            <input className={field} type="datetime-local" aria-label="Ends (optional)" value={draft.end} onChange={(e) => setDraft({ ...draft, end: e.target.value })} />
            <label className="flex items-center gap-2 text-xs text-white/60"><input type="checkbox" checked={!draft.isSet} onChange={(e) => setDraft({ ...draft, isSet: !e.target.checked })} /> Time tbc</label>
            <input className={`${field} sm:col-span-4`} aria-label="Notes" placeholder="Notes" value={draft.notes} onChange={(e) => setDraft({ ...draft, notes: e.target.value })} maxLength={500} />
            <div className="sm:col-span-2 flex gap-2">
              <button disabled={busy} className="bg-brand-primary text-black px-3 py-2 text-xs font-black uppercase disabled:opacity-50">Save</button>
              <button type="button" onClick={() => setDraft(null)} className="px-2 text-xs font-black uppercase text-white/60">Cancel</button>
            </div>
            {draft.kind === 'doors' ? <p className="sm:col-span-6 text-[11px] text-white/40">The doors row is the event's doors-open time: saving it moves doors open too.</p> : null}
          </form>
        ) : null}
      </div>

      {/* Notes */}
      <div className="space-y-3">
        <p className={`${label} flex items-center gap-2`}><NotebookPen className="w-3 h-3" aria-hidden="true" /> Staff notes <span className="normal-case tracking-normal text-white/30">(never shown to door staff or the public)</span></p>
        {notes.length === 0 ? <p className="text-xs text-white/50">No notes yet.</p> : null}
        <ul className="space-y-2">
          {notes.map((n) => (
            <li key={n.id} className="border border-white/10 px-3 py-2">
              <p className="text-sm text-white whitespace-pre-wrap">{n.body}</p>
              <p className="type text-[10px] uppercase tracking-widest text-white/40 mt-1 flex items-center gap-2">
                {n.authorName || 'Staff'} · {formatInTz(new Date(n.createdAt), ev.timezone ?? undefined)}
                {canEdit ? <button type="button" onClick={() => removeNote(n)} className="ml-auto text-white/40 hover:text-red-400" aria-label="Delete note"><X className="w-3 h-3" /></button> : null}
              </p>
            </li>
          ))}
        </ul>
        {canEdit ? (
          <form onSubmit={postNote} className="flex gap-2">
            <textarea className={field} rows={2} aria-label="New note" placeholder="Settlement in the office after the show…" value={noteText} onChange={(e) => setNoteText(e.target.value)} maxLength={5000} />
            <button disabled={busy || !noteText.trim()} className="bg-brand-primary text-black px-3 py-2 text-xs font-black uppercase disabled:opacity-50 self-start">Add</button>
          </form>
        ) : null}
      </div>

      {/* Contacts */}
      <div className="space-y-3">
        <div className="flex items-center justify-between">
          <p className={`${label} flex items-center gap-2`}><Users className="w-3 h-3" aria-hidden="true" /> Contacts</p>
          {canEdit && !contact ? (
            <button type="button" onClick={() => setContact({ input: { ...BLANK_CONTACT } })} className="inline-flex items-center gap-1 text-[11px] font-black uppercase text-brand-primary"><Plus className="w-3 h-3" aria-hidden="true" /> Add contact</button>
          ) : null}
        </div>
        {contacts.length === 0 && !contact ? <p className="text-xs text-white/50">No contacts yet: the agent, tour manager, production and settlement contacts for this show.</p> : null}
        <ul className="grid gap-2 sm:grid-cols-2">
          {contacts.map((c) => (
            <li key={c.id} className="border border-white/10 px-3 py-2 text-sm">
              <p className="font-bold text-white flex items-center gap-2">
                {c.name}
                <span className="type text-[9px] uppercase tracking-widest text-white/40">{c.title || c.role}</span>
                {canEdit ? (
                  <span className="ml-auto flex gap-1">
                    <button type="button" onClick={() => setContact({ id: c.id, input: { role: c.role, title: c.title ?? '', name: c.name, email: c.email ?? '', phone: c.phone ?? '', company: c.company ?? '', notes: c.notes } })} className="p-1 text-white/40 hover:text-white" aria-label={`Edit ${c.name}`}><Pencil className="w-3 h-3" /></button>
                    <button type="button" onClick={() => removeContact(c)} className="p-1 text-white/40 hover:text-red-400" aria-label={`Delete ${c.name}`}><Trash2 className="w-3 h-3" /></button>
                  </span>
                ) : null}
              </p>
              <p className="text-xs text-white/60">{[c.company, c.email].filter(Boolean).join(' · ')}</p>
              {c.phone ? <p className="text-xs text-white/60 flex items-center gap-1"><Phone className="w-3 h-3" aria-hidden="true" /> {c.phone}</p> : null}
              {c.notes ? <p className="text-xs text-white/40 mt-1">{c.notes}</p> : null}
            </li>
          ))}
        </ul>
        {contact ? (
          <form onSubmit={submitContact} className="grid gap-2 sm:grid-cols-3 border border-white/10 p-3" aria-label="Contact">
            <select className={field} aria-label="Role" value={contact.input.role} onChange={(e) => setContact({ ...contact, input: { ...contact.input, role: e.target.value as ContactRole } })}>
              {CONTACT_ROLES.map((r) => <option key={r} value={r}>{r[0].toUpperCase() + r.slice(1)}</option>)}
            </select>
            <input className={field} aria-label="Name" placeholder="Name" value={contact.input.name} onChange={(e) => setContact({ ...contact, input: { ...contact.input, name: e.target.value } })} required maxLength={100} />
            <input className={field} aria-label="Title" placeholder="Title (e.g. Tour manager)" value={contact.input.title} onChange={(e) => setContact({ ...contact, input: { ...contact.input, title: e.target.value } })} maxLength={80} />
            <input className={field} aria-label="Email" placeholder="Email" type="email" value={contact.input.email} onChange={(e) => setContact({ ...contact, input: { ...contact.input, email: e.target.value } })} />
            <input className={field} aria-label="Phone" placeholder="Phone" value={contact.input.phone} onChange={(e) => setContact({ ...contact, input: { ...contact.input, phone: e.target.value } })} maxLength={40} />
            <input className={field} aria-label="Company" placeholder="Company" value={contact.input.company} onChange={(e) => setContact({ ...contact, input: { ...contact.input, company: e.target.value } })} maxLength={100} />
            <input className={`${field} sm:col-span-2`} aria-label="Contact notes" placeholder="Notes" value={contact.input.notes} onChange={(e) => setContact({ ...contact, input: { ...contact.input, notes: e.target.value } })} maxLength={500} />
            <div className="flex gap-2">
              <button disabled={busy} className="bg-brand-primary text-black px-3 py-2 text-xs font-black uppercase disabled:opacity-50">Save</button>
              <button type="button" onClick={() => setContact(null)} className="px-2 text-xs font-black uppercase text-white/60">Cancel</button>
            </div>
          </form>
        ) : null}
      </div>
    </section>
  );
}
