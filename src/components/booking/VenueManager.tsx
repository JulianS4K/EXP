// Venues and their rooms, on the booking calendar (docs/booking.md).
//
// A venue is the org's own, one it rents for its shows, or a partner's
// (promoter mode), with an optional booking contact. Owners and managers
// edit (RLS enforces it); other staff read. Deleting a venue or room that any
// hold night points at is refused by the database (the history stays).

import { useState, type FormEvent } from 'react';
import { Building2, Pencil, Plus, Trash2, X } from 'lucide-react';
import { useToast } from '../../context/ToastContext';
import { deleteRoom, deleteVenue, saveRoom, saveVenue, type RoomInput, type VenueInput } from '../../lib/bookingApi';
import { RELATIONSHIP_LABELS, type Room, type Venue, type VenueRelationship } from '../../lib/booking';
import { getBrowserTimezone, isValidTimezone } from '../../lib/datetime';

export const field =
  'bg-black border border-white/20 px-3 py-2 text-sm text-white w-full focus:outline-none focus-visible:ring-2 focus-visible:ring-brand-primary/60 focus:border-brand-primary';
export const label = 'type text-[10px] uppercase tracking-widest text-white/50';

export function RelationshipBadge({ venue }: { venue: Pick<Venue, 'relationship'> }) {
  if (venue.relationship === 'owned') return null;
  return (
    <span className="type text-[9px] uppercase tracking-widest px-1.5 py-0.5 border border-amber-400/40 text-amber-300">
      {RELATIONSHIP_LABELS[venue.relationship]}
    </span>
  );
}

const blankVenue = (): VenueInput => ({
  name: '', address: null, timezone: getBrowserTimezone(), capacity: null, website: '', permalink: '',
  relationship: 'owned', contactName: '', contactEmail: '', contactPhone: '', notes: '',
});

function toInput(v: Venue): VenueInput {
  return {
    name: v.name, address: v.address, timezone: v.timezone ?? '', capacity: v.capacity, website: v.website ?? '',
    permalink: v.permalink ?? '', relationship: v.relationship, contactName: v.contactName ?? '',
    contactEmail: v.contactEmail ?? '', contactPhone: v.contactPhone ?? '', notes: v.notes ?? '',
  };
}

const num = (s: string): number | null => (s.trim() === '' ? null : Math.max(0, Math.round(Number(s))) || 0);

interface Props {
  orgId: string;
  canEdit: boolean;
  venues: Venue[];
  rooms: Room[];
  onChange: () => void;
}

export default function VenueManager({ orgId, canEdit, venues, rooms, onChange }: Props) {
  const { toast } = useToast();
  const [editing, setEditing] = useState<{ id?: string; input: VenueInput } | null>(venues.length === 0 && canEdit ? { input: blankVenue() } : null);
  const [roomDraft, setRoomDraft] = useState<{ venueId: string; id?: string; input: RoomInput } | null>(null);
  const [busy, setBusy] = useState(false);

  const fail = (e: unknown, fallback: string) => toast({ kind: 'error', message: (e as Error)?.message || fallback });

  const submitVenue = async (e: FormEvent) => {
    e.preventDefault();
    if (!editing) return;
    const v = editing.input;
    if (!v.name.trim()) return toast({ kind: 'error', message: 'Give the venue a name.' });
    if (v.timezone && !isValidTimezone(v.timezone)) return toast({ kind: 'error', message: 'Use a time zone like America/New_York.' });
    setBusy(true);
    try {
      await saveVenue(orgId, v, editing.id);
      toast({ kind: 'success', message: editing.id ? 'Venue saved.' : `Added ${v.name.trim()}. Add its rooms next.` });
      setEditing(null);
      onChange();
    } catch (err) {
      fail(err, 'Could not save the venue.');
    } finally {
      setBusy(false);
    }
  };

  const removeVenue = async (v: Venue) => {
    if (!window.confirm(`Delete ${v.name} and its rooms? Events keep their own venue name and address.`)) return;
    try {
      await deleteVenue(v.id);
      onChange();
    } catch (err) {
      fail(err, 'Could not delete the venue.');
    }
  };

  const submitRoom = async (e: FormEvent) => {
    e.preventDefault();
    if (!roomDraft) return;
    if (!roomDraft.input.name.trim()) return toast({ kind: 'error', message: 'Give the room a name.' });
    setBusy(true);
    try {
      await saveRoom(orgId, roomDraft.venueId, roomDraft.input, roomDraft.id);
      setRoomDraft(null);
      onChange();
    } catch (err) {
      fail(err, 'Could not save the room.');
    } finally {
      setBusy(false);
    }
  };

  const removeRoom = async (r: Room) => {
    if (!window.confirm(`Delete the room ${r.name}?`)) return;
    try {
      await deleteRoom(r.id);
      onChange();
    } catch (err) {
      fail(err, 'Could not delete the room.');
    }
  };

  const set = (patch: Partial<VenueInput>) => setEditing((s) => (s ? { ...s, input: { ...s.input, ...patch } } : s));
  const setAddr = (k: 'street' | 'city' | 'region' | 'country' | 'postal', value: string) =>
    setEditing((s) => {
      if (!s) return s;
      const next = { ...(s.input.address ?? {}), [k]: value };
      const empty = Object.values(next).every((x) => !x);
      return { ...s, input: { ...s.input, address: empty ? null : next } };
    });

  return (
    <section className="bg-[#111] border border-white/10 p-6 space-y-5" aria-labelledby="venues-heading">
      <div className="flex items-center justify-between gap-3">
        <h2 id="venues-heading" className="disp text-lg uppercase tracking-wide text-white flex items-center gap-2">
          <Building2 className="w-4 h-4 text-brand-primary" aria-hidden="true" /> Venues and rooms
        </h2>
        {canEdit && !editing ? (
          <button type="button" onClick={() => setEditing({ input: blankVenue() })} className="inline-flex items-center gap-1 text-[11px] font-black uppercase text-brand-primary">
            <Plus className="w-3 h-3" aria-hidden="true" /> Add venue
          </button>
        ) : null}
      </div>

      {editing ? (
        <form onSubmit={submitVenue} className="grid gap-3 sm:grid-cols-2 border border-white/10 p-4" aria-label={editing.id ? 'Edit venue' : 'New venue'}>
          <label className="sm:col-span-2 space-y-1"><span className={label}>Name</span>
            <input className={field} value={editing.input.name} onChange={(e) => set({ name: e.target.value })} required maxLength={100} autoFocus />
          </label>
          <label className="space-y-1"><span className={label}>Relationship</span>
            <select className={field} value={editing.input.relationship} onChange={(e) => set({ relationship: e.target.value as VenueRelationship })}>
              <option value="owned">Owned: our venue</option>
              <option value="rented">Rented: we rent it for our shows</option>
              <option value="partner">Partner: a partner's room we book</option>
            </select>
          </label>
          <label className="space-y-1"><span className={label}>Time zone</span>
            <input className={field} value={editing.input.timezone} onChange={(e) => set({ timezone: e.target.value })} placeholder="America/New_York" />
          </label>
          <label className="space-y-1"><span className={label}>Capacity</span>
            <input className={field} inputMode="numeric" value={editing.input.capacity ?? ''} onChange={(e) => set({ capacity: num(e.target.value) })} />
          </label>
          <label className="space-y-1"><span className={label}>Website (https)</span>
            <input className={field} type="url" value={editing.input.website} onChange={(e) => set({ website: e.target.value })} />
          </label>
          <label className="sm:col-span-2 space-y-1"><span className={label}>Street</span>
            <input className={field} value={editing.input.address?.street ?? ''} onChange={(e) => setAddr('street', e.target.value)} />
          </label>
          <label className="space-y-1"><span className={label}>City</span>
            <input className={field} value={editing.input.address?.city ?? ''} onChange={(e) => setAddr('city', e.target.value)} />
          </label>
          <label className="space-y-1"><span className={label}>Region / state</span>
            <input className={field} value={editing.input.address?.region ?? ''} onChange={(e) => setAddr('region', e.target.value)} />
          </label>
          <label className="space-y-1"><span className={label}>Postal code</span>
            <input className={field} value={editing.input.address?.postal ?? ''} onChange={(e) => setAddr('postal', e.target.value)} />
          </label>
          <label className="space-y-1"><span className={label}>Country</span>
            <input className={field} value={editing.input.address?.country ?? ''} onChange={(e) => setAddr('country', e.target.value)} />
          </label>
          {editing.input.relationship !== 'owned' ? (
            <fieldset className="sm:col-span-2 grid gap-3 sm:grid-cols-3">
              <legend className={`${label} mb-1`}>Booking contact (who you book it from)</legend>
              <input className={field} aria-label="Contact name" placeholder="Name" value={editing.input.contactName} onChange={(e) => set({ contactName: e.target.value })} />
              <input className={field} aria-label="Contact email" placeholder="Email" type="email" value={editing.input.contactEmail} onChange={(e) => set({ contactEmail: e.target.value })} />
              <input className={field} aria-label="Contact phone" placeholder="Phone" value={editing.input.contactPhone} onChange={(e) => set({ contactPhone: e.target.value })} />
            </fieldset>
          ) : null}
          <label className="space-y-1"><span className={label}>Permalink (optional)</span>
            <input className={field} value={editing.input.permalink} onChange={(e) => set({ permalink: e.target.value })} placeholder="made from the name" />
          </label>
          <label className="space-y-1"><span className={label}>Notes</span>
            <input className={field} value={editing.input.notes} onChange={(e) => set({ notes: e.target.value })} maxLength={2000} />
          </label>
          <div className="sm:col-span-2 flex gap-2">
            <button disabled={busy} className="bg-brand-primary text-black px-4 py-2 text-sm font-black uppercase disabled:opacity-50">{editing.id ? 'Save venue' : 'Add venue'}</button>
            <button type="button" onClick={() => setEditing(null)} className="px-4 py-2 text-sm font-black uppercase text-white/60 hover:text-white">Cancel</button>
          </div>
        </form>
      ) : null}

      {venues.length === 0 && !editing ? <p className="text-sm text-white/50">No venues yet.</p> : null}
      <ul className="space-y-3">
        {venues.map((v) => {
          const vr = rooms.filter((r) => r.venueId === v.id);
          return (
            <li key={v.id} className="border border-white/10 p-4" data-testid={`venue-${v.id}`}>
              <div className="flex flex-wrap items-center gap-2">
                <p className="font-black text-white">{v.name}</p>
                <RelationshipBadge venue={v} />
                <span className="type text-[10px] uppercase tracking-widest text-white/40">
                  {[v.address?.city, v.timezone, v.capacity != null ? `cap ${v.capacity}` : null].filter(Boolean).join(' · ')}
                </span>
                {canEdit ? (
                  <span className="ml-auto flex gap-1">
                    <button type="button" onClick={() => setEditing({ id: v.id, input: toInput(v) })} className="p-2 text-white/50 hover:text-white" aria-label={`Edit ${v.name}`}><Pencil className="w-4 h-4" /></button>
                    <button type="button" onClick={() => removeVenue(v)} className="p-2 text-white/50 hover:text-red-400" aria-label={`Delete ${v.name}`}><Trash2 className="w-4 h-4" /></button>
                  </span>
                ) : null}
              </div>
              {v.relationship !== 'owned' && (v.contactName || v.contactEmail || v.contactPhone) ? (
                <p className="text-xs text-white/50 mt-1">Book through {[v.contactName, v.contactEmail, v.contactPhone].filter(Boolean).join(' · ')}</p>
              ) : null}
              <ul className="mt-3 flex flex-wrap gap-2" aria-label={`Rooms of ${v.name}`}>
                {vr.map((r) => (
                  <li key={r.id} className="inline-flex items-center gap-1 border border-white/15 px-2 py-1 text-xs text-white/80">
                    {r.color ? <span className="w-2 h-2 inline-block" style={{ background: r.color }} aria-hidden="true" /> : null}
                    {r.name}{r.capacity != null ? <span className="text-white/40"> · {r.capacity}</span> : null}
                    {canEdit ? (
                      <>
                        <button type="button" onClick={() => setRoomDraft({ venueId: v.id, id: r.id, input: { name: r.name, capacity: r.capacity, color: r.color ?? '', notes: r.notes ?? '' } })} className="p-1 text-white/40 hover:text-white" aria-label={`Edit room ${r.name}`}><Pencil className="w-3 h-3" /></button>
                        <button type="button" onClick={() => removeRoom(r)} className="p-1 text-white/40 hover:text-red-400" aria-label={`Delete room ${r.name}`}><X className="w-3 h-3" /></button>
                      </>
                    ) : null}
                  </li>
                ))}
                {canEdit && roomDraft?.venueId !== v.id ? (
                  <li>
                    <button type="button" onClick={() => setRoomDraft({ venueId: v.id, input: { name: '', capacity: null, color: '', notes: '' } })} className="inline-flex items-center gap-1 text-[11px] font-black uppercase text-brand-primary px-2 py-1">
                      <Plus className="w-3 h-3" aria-hidden="true" /> Room
                    </button>
                  </li>
                ) : null}
              </ul>
              {roomDraft?.venueId === v.id ? (
                <form onSubmit={submitRoom} className="mt-3 grid gap-2 sm:grid-cols-5" aria-label={roomDraft.id ? 'Edit room' : `New room in ${v.name}`}>
                  <input className={`${field} sm:col-span-2`} placeholder="Room name" aria-label="Room name" value={roomDraft.input.name} autoFocus
                    onChange={(e) => setRoomDraft({ ...roomDraft, input: { ...roomDraft.input, name: e.target.value } })} />
                  <input className={field} placeholder="Capacity" aria-label="Room capacity" inputMode="numeric" value={roomDraft.input.capacity ?? ''}
                    onChange={(e) => setRoomDraft({ ...roomDraft, input: { ...roomDraft.input, capacity: num(e.target.value) } })} />
                  <input className={field} type="color" aria-label="Room colour" value={roomDraft.input.color || '#888888'}
                    onChange={(e) => setRoomDraft({ ...roomDraft, input: { ...roomDraft.input, color: e.target.value } })} />
                  <div className="flex gap-2">
                    <button disabled={busy} className="bg-brand-primary text-black px-3 py-2 text-xs font-black uppercase disabled:opacity-50">Save</button>
                    <button type="button" onClick={() => setRoomDraft(null)} className="px-2 text-xs font-black uppercase text-white/60">Cancel</button>
                  </div>
                </form>
              ) : null}
            </li>
          );
        })}
      </ul>
    </section>
  );
}
