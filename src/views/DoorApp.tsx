// Exos Door (/door): the first app of the Exos suite (docs/strategy.md
// "Apps"). A free door for any event: tickets sold on Exos, or on Eventbrite,
// Posh, DICE, Shotgun or RA (import their attendee CSV, mig 20261013090000;
// or keep an Eventbrite event in sync, mig 20261013100000).
// Scan barcodes or check in by name, on as many phones as you like, offline
// too. No fees: Exos charges only on tickets it sells.
//
// This page is the app's home: pick an organization, start a door-only event
// (a draft that never goes on sale), import attendees, open the scanner. It
// installs as its own home-screen app (public/door.webmanifest).

import { useEffect, useState } from 'react';
import { Link } from 'react-router-dom';
import { CalendarPlus, DoorOpen, FileUp, Loader2, RefreshCw, ScanLine, WifiOff } from 'lucide-react';
import { useAuth } from '../context/AuthContext';
import { useOrganization } from '../context/OrganizationContext';
import { createEvent, listOrgEvents } from '../lib/events';
import type { Event } from '../types';
import DoorImport from '../components/DoorImport';
import EventbriteSync from '../components/EventbriteSync';

const DOOR_ROLES = new Set(['owner', 'manager', 'scanner']);

function useDoorManifest() {
  useEffect(() => {
    const link = document.querySelector<HTMLLinkElement>('link[rel="manifest"]');
    if (!link) return undefined;
    const prev = link.href;
    link.href = `${(import.meta as { env?: { BASE_URL?: string } }).env?.BASE_URL ?? '/'}door.webmanifest`;
    const prevTitle = document.title;
    document.title = 'Exos Door · free door app for any event';
    return () => {
      link.href = prev;
      document.title = prevTitle;
    };
  }, []);
}

const localTz = () => {
  try {
    return Intl.DateTimeFormat().resolvedOptions().timeZone || 'America/New_York';
  } catch {
    return 'America/New_York';
  }
};

const startMs = (e: Event): number => {
  const d = e.date as unknown as { toMillis?: () => number } | null;
  return d?.toMillis ? d.toMillis() : 0;
};

export default function DoorApp() {
  useDoorManifest();
  const { user, openAuthModal } = useAuth();
  const { orgs, activeOrg, activeRole, setActiveOrg, loading: orgsLoading } = useOrganization();
  const [events, setEvents] = useState<Event[] | null>(null);
  const [loadError, setLoadError] = useState(false);
  // The panel open under one event: the CSV import or the Eventbrite sync.
  const [open, setOpen] = useState<{ id: string; kind: 'import' | 'eventbrite' } | null>(null);
  const [form, setForm] = useState({ name: '', date: '', venue: '' });
  const [creating, setCreating] = useState(false);
  const [createError, setCreateError] = useState<string | null>(null);
  const [tick, setTick] = useState(0);

  const orgId = activeOrg?.id ?? null;
  const canManage = activeRole === 'owner' || activeRole === 'manager';

  useEffect(() => {
    // Another organization: never show the last one's events meanwhile.
    setEvents(null);
    setOpen(null);
    if (!orgId) return undefined;
    let alive = true;
    setLoadError(false);
    listOrgEvents(orgId)
      .then((list) => {
        if (!alive) return;
        const soon = Date.now() - 2 * 86_400_000;
        setEvents(list.filter((e) => e.status !== 'cancelled' && (startMs(e) === 0 || startMs(e) >= soon)));
      })
      .catch((err) => {
        console.warn('door events unavailable', err);
        if (alive) setLoadError(true);
      });
    return () => {
      alive = false;
    };
  }, [orgId, tick]);
  // A refresh after creating an event keeps the list on screen.

  const create = async () => {
    if (!orgId || !form.name.trim() || !form.date) return;
    setCreating(true);
    setCreateError(null);
    try {
      const startsAt = new Date(form.date).toISOString();
      const { eventId } = await createEvent({
        orgId,
        name: form.name.trim().slice(0, 120),
        status: 'draft',
        startsAt,
        doorsAt: startsAt,
        timezone: localTz(),
        venueName: form.venue.trim() || undefined,
        totalTickets: 0,
      });
      setForm({ name: '', date: '', venue: '' });
      setOpen({ id: eventId, kind: 'import' });
      setTick((t) => t + 1);
    } catch (err) {
      console.error('door event create failed', err);
      setCreateError('Could not create the event. Only owners and managers can.');
    } finally {
      setCreating(false);
    }
  };

  return (
    <div className="min-h-screen bg-slate-50 text-slate-900">
      <div className="max-w-3xl mx-auto px-4 py-10 space-y-8">
        <header className="space-y-3">
          <p className="text-[11px] font-black uppercase tracking-[0.3em] text-slate-400">Exos · Door</p>
          <h1 className="text-3xl md:text-4xl font-black tracking-tight">The free door app for any event.</h1>
          <p className="text-slate-600 max-w-xl">
            Scan tickets sold on Exos, Eventbrite, Posh, DICE, Shotgun or RA. Check guests in by name. Works offline,
            on as many phones as you have staff. No fees, ever: Exos only charges on tickets it sells.
          </p>
          <ul className="grid grid-cols-1 sm:grid-cols-3 gap-3 pt-2">
            {[
              { icon: <ScanLine className="w-4 h-4" />, t: 'Any barcode', d: 'Import the attendee CSV and scan their codes.' },
              { icon: <WifiOff className="w-4 h-4" />, t: 'Offline', d: 'Keeps working when the venue Wi-Fi dies.' },
              { icon: <DoorOpen className="w-4 h-4" />, t: 'Every door', d: 'Staff phones sync; no double entry.' },
            ].map((f) => (
              <li key={f.t} className="bg-white rounded-2xl p-4 border border-slate-100">
                <span className="flex items-center gap-2 font-bold text-sm">{f.icon} {f.t}</span>
                <span className="block text-xs text-slate-500 mt-1">{f.d}</span>
              </li>
            ))}
          </ul>
        </header>

        {!user ? (
          <section className="bg-white rounded-2xl p-6 border border-slate-100 text-center space-y-3">
            <p className="text-sm text-slate-600">Sign in to set up your door. It takes a minute and costs nothing.</p>
            <button type="button" onClick={openAuthModal}
              className="px-5 py-3 bg-slate-900 text-white rounded-xl text-[11px] font-black uppercase tracking-widest">
              Sign in or create an account
            </button>
          </section>
        ) : orgsLoading ? (
          <p className="text-sm text-slate-400 flex items-center gap-2"><Loader2 className="w-4 h-4 animate-spin" /> Loading…</p>
        ) : orgs.length === 0 ? (
          <section className="bg-white rounded-2xl p-6 border border-slate-100 space-y-3">
            <p className="text-sm text-slate-600">First, name your venue, promoter or party. Your door staff join it.</p>
            <Link to="/orgs/new"
              className="inline-block px-5 py-3 bg-slate-900 text-white rounded-xl text-[11px] font-black uppercase tracking-widest">
              Create your organization (free)
            </Link>
          </section>
        ) : (
          <>
            {orgs.length > 1 && (
              <label className="block text-xs text-slate-600">
                <span className="block font-bold mb-1">Organization</span>
                <select value={orgId ?? ''} onChange={(e) => setActiveOrg(e.target.value)}
                  className="border border-slate-200 rounded-lg px-3 py-2 bg-white text-sm">
                  {orgs.map((o) => <option key={o.org.id} value={o.org.id}>{o.org.name}</option>)}
                </select>
              </label>
            )}

            {activeRole && !DOOR_ROLES.has(activeRole) && (
              <p className="text-sm text-amber-700 bg-amber-50 rounded-xl p-3">
                Your role in this organization can't work the door. Ask an owner to make you door staff.
              </p>
            )}

            <section aria-labelledby="door-events" className="space-y-3">
              <h2 id="door-events" className="text-sm font-black uppercase tracking-widest text-slate-500">Your doors</h2>
              {loadError && <p className="text-sm text-rose-500">Events didn't load. Try again.</p>}
              {events && events.length === 0 && (
                <p className="text-sm text-slate-500">No upcoming events yet. Start one below.</p>
              )}
              <ul className="space-y-3">
                {(events ?? []).map((e) => (
                  <li key={e.id} className="bg-white rounded-2xl border border-slate-100 p-4 space-y-3">
                    <div className="flex flex-wrap items-center gap-3">
                      <span className="flex-1 min-w-0">
                        <span className="block font-bold truncate">{e.title}</span>
                        <span className="block text-xs text-slate-500">
                          {startMs(e) ? new Date(startMs(e)).toLocaleString(undefined, { dateStyle: 'medium', timeStyle: 'short' }) : 'No date'}
                          {e.status === 'draft' ? ' · door only' : ''}
                        </span>
                      </span>
                      {canManage && (
                        <button type="button" aria-expanded={open?.id === e.id && open.kind === 'import'}
                          onClick={() => setOpen(open?.id === e.id && open.kind === 'import' ? null : { id: e.id, kind: 'import' })}
                          className="inline-flex items-center gap-1.5 px-3 py-2 border border-slate-200 rounded-lg text-[11px] font-bold text-slate-700">
                          <FileUp className="w-3.5 h-3.5" /> Import CSV
                        </button>
                      )}
                      {activeRole && DOOR_ROLES.has(activeRole) && (
                        <button type="button" aria-expanded={open?.id === e.id && open.kind === 'eventbrite'}
                          onClick={() => setOpen(open?.id === e.id && open.kind === 'eventbrite' ? null : { id: e.id, kind: 'eventbrite' })}
                          className="inline-flex items-center gap-1.5 px-3 py-2 border border-slate-200 rounded-lg text-[11px] font-bold text-slate-700">
                          <RefreshCw className="w-3.5 h-3.5" /> Eventbrite sync
                        </button>
                      )}
                      <Link to={`/checkin/${e.id}`}
                        className="inline-flex items-center gap-1.5 px-3 py-2 bg-slate-900 text-white rounded-lg text-[11px] font-black uppercase tracking-widest">
                        <ScanLine className="w-3.5 h-3.5" /> Open door
                      </Link>
                    </div>
                    {open?.id === e.id && open.kind === 'import' && canManage && (
                      <div className="border-t border-slate-100 pt-3">
                        <DoorImport eventId={e.id} />
                      </div>
                    )}
                    {open?.id === e.id && open.kind === 'eventbrite' && orgId && (
                      <div className="border-t border-slate-100 pt-3">
                        <EventbriteSync eventId={e.id} orgId={orgId} />
                      </div>
                    )}
                  </li>
                ))}
              </ul>
            </section>

            {canManage && (
              <section aria-labelledby="door-new" className="bg-white rounded-2xl border border-slate-100 p-5 space-y-3">
                <h2 id="door-new" className="text-sm font-bold flex items-center gap-2">
                  <CalendarPlus className="w-4 h-4" /> New door for an event sold elsewhere
                </h2>
                <p className="text-xs text-slate-500">
                  Creates a door-only event: it never goes on sale on Exos. Import the attendees next, or link it to
                  the Eventbrite event to keep them in sync.
                </p>
                <div className="grid grid-cols-1 sm:grid-cols-3 gap-3">
                  <label className="text-xs text-slate-600 sm:col-span-3">
                    <span className="block font-bold mb-1">Event name</span>
                    <input value={form.name} maxLength={120} onChange={(e) => setForm({ ...form, name: e.target.value })}
                      className="w-full border border-slate-200 rounded-lg px-3 py-2 text-sm" />
                  </label>
                  <label className="text-xs text-slate-600 sm:col-span-2">
                    <span className="block font-bold mb-1">Doors open</span>
                    <input type="datetime-local" value={form.date} onChange={(e) => setForm({ ...form, date: e.target.value })}
                      className="w-full border border-slate-200 rounded-lg px-3 py-2 text-sm" />
                  </label>
                  <label className="text-xs text-slate-600">
                    <span className="block font-bold mb-1">Venue (optional)</span>
                    <input value={form.venue} maxLength={120} onChange={(e) => setForm({ ...form, venue: e.target.value })}
                      className="w-full border border-slate-200 rounded-lg px-3 py-2 text-sm" />
                  </label>
                </div>
                <button type="button" onClick={() => void create()} disabled={creating || !form.name.trim() || !form.date}
                  className="inline-flex items-center gap-2 px-4 py-2 bg-slate-900 text-white rounded-lg text-[11px] font-black uppercase tracking-widest disabled:opacity-50">
                  {creating && <Loader2 className="w-3 h-3 animate-spin" />} Create door
                </button>
                {createError && <p role="alert" className="text-xs text-rose-500">{createError}</p>}
              </section>
            )}
          </>
        )}

        <footer className="text-xs text-slate-400 pt-6 border-t border-slate-200">
          Part of Exos: Door is free. Selling tickets on Exos costs a fee per ticket sold, nothing else.
        </footer>
      </div>
    </div>
  );
}
