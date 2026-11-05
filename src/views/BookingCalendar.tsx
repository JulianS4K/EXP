// /orgs/:orgId/calendar — the org's booking calendar (docs/booking.md).
//
// Month and list views of events and holds, filtered by venue and room. A
// hold night shows its level (H1, H2 …); a challenged date (more than one
// hold in the same room, or a hold against a booked show) is outlined in
// amber. Owners and managers click a day to pencil a hold and open a hold to
// move, release or convert it; content and finance staff read; door staff
// have no access (RLS returns them no holds).

import { useCallback, useEffect, useMemo, useState } from 'react';
import { Link, useParams } from 'react-router-dom';
import { ArrowLeft, CalendarDays, ChevronLeft, ChevronRight, List, Plus } from 'lucide-react';
import { useAuth } from '../context/AuthContext';
import { useToast } from '../context/ToastContext';
import { getOrganization, getUserRoleInOrg } from '../lib/orgs';
import { listCalendarEvents, listHolds, listRooms, listVenues } from '../lib/bookingApi';
import {
  buildCalendar, localDate, monthGrid, monthRange, placeLabel, shiftMonth,
  type CalendarEvent, type Hold, type Room, type Venue,
} from '../lib/booking';
import VenueManager, { RelationshipBadge, field } from '../components/booking/VenueManager';
import HoldDrawer, { type DrawerTarget } from '../components/booking/HoldDrawer';

const WEEKDAYS = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'];

export default function BookingCalendar() {
  const { orgId } = useParams();
  const { user, isAdmin } = useAuth();
  const { toast } = useToast();
  const today = localDate(new Date());
  const [cursor, setCursor] = useState(() => ({ y: Number(today.slice(0, 4)), m: Number(today.slice(5, 7)) - 1 }));
  const [view, setView] = useState<'month' | 'list'>('month');
  const [venueFilter, setVenueFilter] = useState('');
  const [roomFilter, setRoomFilter] = useState('');
  const [venues, setVenues] = useState<Venue[]>([]);
  const [rooms, setRooms] = useState<Room[]>([]);
  const [holds, setHolds] = useState<Hold[]>([]);
  const [events, setEvents] = useState<CalendarEvent[]>([]);
  const [orgName, setOrgName] = useState('');
  const [role, setRole] = useState<string | null | undefined>(undefined);
  const [loading, setLoading] = useState(true);
  const [drawer, setDrawer] = useState<DrawerTarget | null>(null);
  const [showVenues, setShowVenues] = useState(false);

  useEffect(() => {
    if (!orgId || !user?.uid) return;
    getOrganization(orgId).then((o) => setOrgName(o?.name ?? '')).catch(() => {});
    getUserRoleInOrg(orgId, user.uid).then(setRole).catch(() => setRole(null));
  }, [orgId, user?.uid]);

  const effectiveRole = isAdmin ? 'owner' : role;
  const canEdit = effectiveRole === 'owner' || effectiveRole === 'manager';
  const canView = canEdit || effectiveRole === 'content' || effectiveRole === 'finance';
  const range = monthRange(cursor.y, cursor.m);

  const load = useCallback(async () => {
    if (!orgId || !canView) return;
    try {
      const [vs, rs, hs, es] = await Promise.all([
        listVenues(orgId), listRooms(orgId), listHolds(orgId, range.from, range.to),
        listCalendarEvents(orgId, range.from, range.to),
      ]);
      setVenues(vs);
      setRooms(rs);
      setHolds(hs);
      setEvents(es);
      if (vs.length === 0) setShowVenues(true);
    } catch (e) {
      toast({ kind: 'error', message: (e as Error)?.message || 'Could not load the calendar.' });
    } finally {
      setLoading(false);
    }
  }, [orgId, canView, range.from, range.to, toast]);

  useEffect(() => { void load(); }, [load]);

  const venueById = useMemo(() => new Map(venues.map((v) => [v.id, v])), [venues]);
  const roomById = useMemo(() => new Map(rooms.map((r) => [r.id, r])), [rooms]);
  const where = (venueId: string | null, roomId: string | null) =>
    venueId ? placeLabel(venueById.get(venueId), roomId ? roomById.get(roomId) : null) : '';
  const days = useMemo(
    () => buildCalendar(holds, events, { venueId: venueFilter || undefined, roomId: roomFilter || undefined }),
    [holds, events, venueFilter, roomFilter],
  );

  if (!user) return <div className="max-w-3xl mx-auto p-20 text-center type text-white/50 uppercase tracking-widest text-xs">Sign in to see the booking calendar.</div>;
  if (role === undefined && !isAdmin) return <div className="max-w-3xl mx-auto p-20 text-center type text-white/40 uppercase tracking-widest text-xs">Loading…</div>;
  if (!canView) {
    return <div className="max-w-3xl mx-auto p-20 text-center text-sm text-white/60" role="alert">The booking calendar is for owners, managers, content and finance staff of this organization.</div>;
  }

  const monthLabel = new Intl.DateTimeFormat('en-US', { month: 'long', year: 'numeric', timeZone: 'UTC' }).format(new Date(Date.UTC(cursor.y, cursor.m, 1)));
  const openNew = (date: string) => {
    if (!canEdit || venues.length === 0) return;
    setDrawer({ kind: 'new', date, venueId: venueFilter || undefined, roomId: roomFilter || undefined });
  };
  const closeDrawer = (changed: boolean) => {
    setDrawer(null);
    if (changed) void load();
  };
  const sortedDays = [...days.entries()].filter(([d]) => d >= range.from && d <= range.to).sort(([a], [b]) => a.localeCompare(b));

  const eventChip = (e: CalendarEvent) => (
    <Link key={e.id} to={`/edit-event/${e.id}`} title={`${e.name} — ${where(e.venueId, e.roomId)}`}
      className={`block truncate text-[11px] font-bold px-1.5 py-1 border ${e.status === 'cancelled' ? 'border-white/10 text-white/30 line-through' : 'bg-brand-primary/15 text-brand-primary border-brand-primary/30 hover:border-brand-primary'}`}>
      {e.status === 'draft' ? 'Draft · ' : ''}{e.name}
    </Link>
  );

  return (
    <div className="max-w-7xl mx-auto px-4 py-12">
      <Link to={`/orgs/${orgId}/settings`} className="type flex items-center text-white/40 hover:text-brand-primary mb-8 uppercase tracking-widest text-[10px]">
        <ArrowLeft className="w-4 h-4 mr-2" /> Back to {orgName || 'the organization'}
      </Link>
      <div className="flex flex-wrap items-end justify-between gap-4 mb-6">
        <div>
          <h1 className="disp text-4xl uppercase tracking-wide text-white mb-2">Booking calendar</h1>
          <p className="text-sm text-white/60 max-w-2xl">
            Holds pencil a night before it's confirmed. H1 is first in line; when it's released, the next hold moves up.
            Convert a night to make it a draft event.
          </p>
        </div>
        <div className="flex gap-2">
          <button type="button" onClick={() => setShowVenues((s) => !s)} aria-expanded={showVenues}
            className="border border-white/20 px-4 py-2 text-xs font-black uppercase text-white hover:border-brand-primary">
            Venues ({venues.length})
          </button>
          {canEdit ? (
            <button type="button" onClick={() => openNew(today)} disabled={venues.length === 0}
              className="inline-flex items-center gap-1 bg-brand-primary text-black px-4 py-2 text-xs font-black uppercase disabled:opacity-40">
              <Plus className="w-4 h-4" aria-hidden="true" /> New hold
            </button>
          ) : null}
        </div>
      </div>

      {!loading && venues.length === 0 ? (
        <p className="mb-6 border-l-2 border-brand-primary pl-3 text-sm text-white/70">
          {canEdit ? 'Add a venue (and its rooms) first; holds are nights at a venue.' : 'No venues yet.'}
        </p>
      ) : null}
      {showVenues && orgId ? (
        <div className="mb-8">
          <VenueManager orgId={orgId} canEdit={canEdit} venues={venues} rooms={rooms} onChange={() => void load()} />
        </div>
      ) : null}

      <div className="bg-[#111] border border-white/10 p-4 mb-4 flex flex-col lg:flex-row lg:items-end gap-4">
        <div className="flex items-center gap-2">
          <button type="button" onClick={() => setCursor((c) => shiftMonth(c, -1))} className="p-2 border border-white/20 text-white" aria-label="Previous month"><ChevronLeft className="w-4 h-4" /></button>
          <p className="disp text-xl uppercase text-white min-w-44 text-center" aria-live="polite" data-testid="cal-month">{monthLabel}</p>
          <button type="button" onClick={() => setCursor((c) => shiftMonth(c, 1))} className="p-2 border border-white/20 text-white" aria-label="Next month"><ChevronRight className="w-4 h-4" /></button>
          <button type="button" onClick={() => setCursor({ y: Number(today.slice(0, 4)), m: Number(today.slice(5, 7)) - 1 })} className="px-2 text-[11px] font-black uppercase text-white/60 hover:text-white">Today</button>
        </div>
        <div className="grid grid-cols-2 gap-3 flex-1">
          <label className="space-y-1"><span className="type text-[10px] uppercase tracking-widest text-white/50">Venue</span>
            <select className={field} value={venueFilter} onChange={(e) => { setVenueFilter(e.target.value); setRoomFilter(''); }}>
              <option value="">All venues</option>
              {venues.map((v) => <option key={v.id} value={v.id}>{v.name}{v.relationship !== 'owned' ? ` (${v.relationship})` : ''}</option>)}
            </select>
          </label>
          <label className="space-y-1"><span className="type text-[10px] uppercase tracking-widest text-white/50">Room</span>
            <select className={field} value={roomFilter} disabled={!venueFilter} onChange={(e) => setRoomFilter(e.target.value)}>
              <option value="">All rooms</option>
              {rooms.filter((r) => r.venueId === venueFilter).map((r) => <option key={r.id} value={r.id}>{r.name}</option>)}
            </select>
          </label>
        </div>
        <div className="flex gap-2" role="group" aria-label="View">
          <button type="button" aria-pressed={view === 'month'} onClick={() => setView('month')} className={`inline-flex items-center gap-1 px-3 py-2 text-xs font-black uppercase ${view === 'month' ? 'bg-brand-primary text-black' : 'border border-white/20 text-white'}`}><CalendarDays className="w-4 h-4" aria-hidden="true" /> Month</button>
          <button type="button" aria-pressed={view === 'list'} onClick={() => setView('list')} className={`inline-flex items-center gap-1 px-3 py-2 text-xs font-black uppercase ${view === 'list' ? 'bg-brand-primary text-black' : 'border border-white/20 text-white'}`}><List className="w-4 h-4" aria-hidden="true" /> List</button>
        </div>
      </div>

      <div className="flex flex-wrap gap-4 mb-4 text-[11px] text-white/60" aria-label="Legend">
        <span className="inline-flex items-center gap-1.5"><span className="w-3 h-3 bg-brand-primary/40 border border-brand-primary" aria-hidden="true" />Event</span>
        <span className="inline-flex items-center gap-1.5"><span className="w-3 h-3 bg-green-500/20 border border-green-500/50" aria-hidden="true" />First hold (H1)</span>
        <span className="inline-flex items-center gap-1.5"><span className="w-3 h-3 bg-amber-500/20 border border-amber-500/50" aria-hidden="true" />Backup hold</span>
        <span className="inline-flex items-center gap-1.5"><span className="w-3 h-3 border-2 border-amber-400" aria-hidden="true" />Challenged date</span>
      </div>

      {view === 'month' ? (
        <div className="overflow-x-auto">
          <table className="w-full table-fixed border-collapse min-w-[640px]" data-testid="cal-grid">
            <caption className="sr-only">{monthLabel}</caption>
            <thead><tr>{WEEKDAYS.map((d) => <th key={d} scope="col" className="type text-[10px] uppercase tracking-widest text-white/50 py-2">{d}</th>)}</tr></thead>
            <tbody>
              {monthGrid(cursor.y, cursor.m).map((week, wi) => (
                <tr key={wi}>
                  {week.map((date, di) => {
                    if (!date) return <td key={di} className="border border-white/5 h-28" />;
                    const cell = days.get(date);
                    return (
                      <td key={di} data-testid={`cal-day-${date}`} data-challenged={cell?.challenged || undefined}
                        className={`align-top h-28 p-1 bg-[#111] border ${cell?.challenged ? 'border-amber-400 border-2' : 'border-white/10'}`}>
                        <div className="flex items-center justify-between mb-1">
                          <span className={`text-xs font-black ${date === today ? 'text-brand-primary' : 'text-white/60'}`}>{Number(date.slice(8))}</span>
                          {canEdit && venues.length > 0 ? (
                            <button type="button" onClick={() => openNew(date)} className="p-1 text-white/40 hover:text-brand-primary" aria-label={`Hold ${date}`}><Plus className="w-3.5 h-3.5" /></button>
                          ) : null}
                        </div>
                        <div className="space-y-1">
                          {(cell?.events ?? []).map(eventChip)}
                          {(cell?.nights ?? []).map(({ hold, pos }) => (
                            <button key={pos.id} type="button" onClick={() => setDrawer({ kind: 'hold', hold })}
                              title={`${hold.title} — ${where(pos.venueId, pos.roomId)}`}
                              aria-label={`Hold level ${pos.level}: ${hold.title}, ${date}`}
                              className={`w-full text-left truncate text-[11px] font-bold px-1.5 py-1 border ${pos.level === 1 ? 'bg-green-500/10 text-green-300 border-green-500/30' : 'bg-amber-500/10 text-amber-300 border-amber-500/30'}`}>
                              H{pos.level} {hold.title}
                            </button>
                          ))}
                        </div>
                      </td>
                    );
                  })}
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      ) : (
        <div className="bg-[#111] border border-white/10" data-testid="cal-list">
          {sortedDays.length === 0 ? <p className="p-6 text-sm text-white/60">Nothing booked or held this month.</p> : null}
          <ul className="divide-y divide-white/10">
            {sortedDays.flatMap(([date, cell]) => [
              ...cell.events.map((e) => (
                <li key={`e-${e.id}`} className="p-4 flex flex-wrap items-center gap-3">
                  <span className="font-black text-white w-28">{date}</span>
                  <span className="type text-[10px] uppercase tracking-widest text-brand-primary">{e.status === 'draft' ? 'Draft event' : e.status}</span>
                  <Link to={`/edit-event/${e.id}`} className="font-bold text-white hover:text-brand-primary">{e.name}</Link>
                  <span className="text-xs text-white/50">{where(e.venueId, e.roomId)}</span>
                </li>
              )),
              ...cell.nights.map(({ hold, pos, challenged }) => {
                const v = venueById.get(pos.venueId);
                return (
                  <li key={`h-${pos.id}`} className="p-4 flex flex-wrap items-center gap-3">
                    <span className="font-black text-white w-28">{date}</span>
                    <span className={`type text-xs font-black px-2 ${pos.level === 1 ? 'text-green-300' : 'text-amber-300'}`}>H{pos.level}</span>
                    {challenged ? <span className="type text-[10px] uppercase tracking-widest text-amber-300">Challenged</span> : null}
                    <button type="button" onClick={() => setDrawer({ kind: 'hold', hold })} className="font-bold text-white hover:text-brand-primary text-left">{hold.title}</button>
                    <span className="text-xs text-white/50">{where(pos.venueId, pos.roomId)}</span>
                    {v ? <RelationshipBadge venue={v} /> : null}
                  </li>
                );
              }),
            ])}
          </ul>
        </div>
      )}

      {drawer && orgId ? (
        <HoldDrawer orgId={orgId} canEdit={canEdit} target={drawer} venues={venues} rooms={rooms} holds={holds} onClose={closeDrawer} />
      ) : null}
    </div>
  );
}
