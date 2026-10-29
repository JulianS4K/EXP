// Exos Door: keep this event's door in step with an Eventbrite event
// (mig 20261013100000). New buyers show up at the door within a couple of
// minutes and refunded tickets stop working. Eventbrite is only read: no
// check-ins go back to it.
//
// Connecting (mig 20261029140000): "Connect Eventbrite" signs in on
// Eventbrite (exos-eventbrite-oauth) when this server has the OAuth app
// configured, and comes back here (?eventbrite=pick) with the event list
// open. The pasted private token stays: it is the only way when OAuth isn't
// configured, and a fallback under "Use a private token instead" when it is.

import { useCallback, useEffect, useRef, useState } from 'react';
import { Link2, Loader2, RefreshCw, Unlink } from 'lucide-react';
import EventbriteInventory from './EventbriteInventory';
import {
  connectEventbrite, disconnectEventbrite, eventbriteOAuthAvailable, fetchEventbriteStatus, linkEventbrite,
  listEventbriteEvents, startEventbriteConnect, syncEventbrite, syncSummaryText, unlinkEventbrite,
  type EventbriteEventChoice, type EventbriteStatus,
} from '../lib/door/eventbrite';
import { eventbriteErrorMessage, wantsEventbritePick } from '../lib/eventbriteConnect';

const TOKEN_HELP = 'https://www.eventbrite.com/platform/api-keys';

function ago(iso: string | null): string {
  if (!iso) return 'never';
  const s = Math.max(0, Math.round((Date.now() - Date.parse(iso)) / 1000));
  if (s < 60) return 'just now';
  if (s < 3600) return `${Math.round(s / 60)} min ago`;
  return new Date(iso).toLocaleString(undefined, { dateStyle: 'medium', timeStyle: 'short' });
}

export default function EventbriteSync({ eventId, orgId, onSynced }: { eventId: string; orgId: string; onSynced?: () => void }) {
  const [status, setStatus] = useState<EventbriteStatus | null | undefined>(undefined);
  const [token, setToken] = useState('');
  const [choices, setChoices] = useState<EventbriteEventChoice[] | null>(null);
  const [pick, setPick] = useState('');
  const [busy, setBusy] = useState<string | null>(null);
  const [note, setNote] = useState<{ text: string; ok: boolean } | null>(null);
  const [oauth, setOauth] = useState(false);
  const [showToken, setShowToken] = useState(false);
  /** Opened from "Connect Eventbrite" (?eventbrite=pick): list the events once. */
  const autoPick = useRef(typeof window !== 'undefined' && wantsEventbritePick(window.location.search));

  useEffect(() => {
    let live = true;
    void eventbriteOAuthAvailable().then((v) => { if (live) setOauth(v); });
    return () => { live = false; };
  }, []);

  const load = useCallback(async () => {
    try {
      setStatus(await fetchEventbriteStatus(eventId));
    } catch (err) {
      console.warn('eventbrite status unavailable', err);
      setStatus(null);
    }
  }, [eventId]);

  useEffect(() => {
    setStatus(undefined);
    setChoices(null);
    setNote(null);
    void load();
    const t = setInterval(() => void load(), 60_000);
    return () => clearInterval(t);
  }, [load]);

  const run = async (what: string, fn: () => Promise<string | void>) => {
    setBusy(what);
    setNote(null);
    try {
      const text = await fn();
      if (text) setNote({ text, ok: true });
    } catch (err) {
      setNote({ text: (err as Error)?.message || 'Something went wrong.', ok: false });
    } finally {
      setBusy(null);
      void load();
    }
  };

  const showEvents = () => run('events', async () => {
    const list = await listEventbriteEvents(orgId);
    setChoices(list);
    setPick(list[0]?.id ?? '');
    return list.length === 0 ? 'No upcoming events on this Eventbrite account.' : undefined;
  });

  // Back from "Connect Eventbrite": open the event list once.
  useEffect(() => {
    if (!autoPick.current || !status?.connected || status.link || !status.canManage || choices !== null) return;
    autoPick.current = false;
    void showEvents();
    // eslint-disable-next-line
  }, [status]);

  const connectWithEventbrite = async () => {
    setBusy('oauth');
    setNote(null);
    try {
      window.location.assign(await startEventbriteConnect(orgId, eventId));
    } catch (err: any) {
      setNote({ text: eventbriteErrorMessage(err?.reason ?? 'unknown'), ok: false });
      setBusy(null);
    }
  };

  if (status === undefined) {
    return <p className="text-xs text-slate-400 flex items-center gap-2"><Loader2 className="w-3 h-3 animate-spin" /> Checking Eventbrite…</p>;
  }
  if (status === null) {
    return <p className="text-xs text-slate-400">Eventbrite sync isn't available yet. Import a CSV export instead.</p>;
  }

  const btn = 'inline-flex items-center gap-1.5 px-3 py-2 rounded-lg text-[11px] font-bold disabled:opacity-50';
  const link = status.link;

  return (
    <section aria-labelledby={`eb-${eventId}`} className="space-y-3">
      <div>
        <h3 id={`eb-${eventId}`} className="text-sm font-bold text-slate-800">Live sync from Eventbrite</h3>
        <p className="text-xs text-slate-500 mt-1">
          New Eventbrite buyers reach the door within a couple of minutes, and refunded or cancelled tickets stop
          working. Exos reads your attendees; it changes nothing on Eventbrite unless you share a ticket's count below.
        </p>
      </div>

      {!status.connected && !status.canManage && (
        <p className="text-xs text-slate-600">Ask an owner or manager to connect Eventbrite.</p>
      )}

      {!status.connected && status.canManage && oauth && (
        <div className="space-y-2">
          <button type="button" disabled={busy !== null} onClick={() => void connectWithEventbrite()}
            className={`${btn} bg-slate-900 text-white`}>
            {busy === 'oauth' && <Loader2 className="w-3 h-3 animate-spin" />} Connect Eventbrite
          </button>
          <p className="text-[11px] text-slate-500">
            You sign in on Eventbrite and allow Exos, then come back here to pick the event. Exos only reads your
            events and attendees.
          </p>
          {!showToken && (
            <button type="button" onClick={() => setShowToken(true)} className="text-[11px] text-slate-400 underline">
              Use a private token instead
            </button>
          )}
        </div>
      )}

      {!status.connected && status.canManage && (!oauth || showToken) && (
        <form
          className="space-y-2"
          onSubmit={(e) => {
            e.preventDefault();
            void run('connect', async () => {
              const r = await connectEventbrite(orgId, token.trim());
              setToken('');
              return `Connected to ${r.account_name ?? 'Eventbrite'}.`;
            });
          }}
        >
          <label className="block text-xs text-slate-600">
            <span className="block font-bold mb-1">Eventbrite private token</span>
            <input
              type="password"
              autoComplete="off"
              value={token}
              onChange={(e) => setToken(e.target.value)}
              className="w-full border border-slate-200 rounded-lg px-3 py-2 text-sm font-mono"
              placeholder="Paste it here"
            />
          </label>
          <p className="text-[11px] text-slate-500">
            On Eventbrite: Account settings → Developer links → API keys, then copy the{' '}
            <a href={TOKEN_HELP} target="_blank" rel="noreferrer noopener" className="underline">private token</a>.
            It is stored encrypted and only used to read your attendee list.
          </p>
          <button type="submit" disabled={busy !== null || token.trim().length < 8}
            className={`${btn} ${oauth ? 'border border-slate-200 text-slate-700' : 'bg-slate-900 text-white'}`}>
            {busy === 'connect' && <Loader2 className="w-3 h-3 animate-spin" />} {oauth ? 'Connect with the token' : 'Connect Eventbrite'}
          </button>
        </form>
      )}

      {status.connected && !link && (
        <div className="space-y-2">
          <p className="text-xs text-slate-600">
            Connected to <strong>{status.accountName ?? 'Eventbrite'}</strong>.
            {status.canManage ? ' Pick the Eventbrite event this door is for.' : ' An owner or manager links the event.'}
          </p>
          {status.canManage && (choices === null ? (
            <button type="button" disabled={busy !== null}
              onClick={() => void showEvents()}
              className={`${btn} border border-slate-200 text-slate-700`}>
              {busy === 'events' && <Loader2 className="w-3 h-3 animate-spin" />} Show my Eventbrite events
            </button>
          ) : choices.length > 0 && (
            <div className="flex flex-wrap gap-2 items-end">
              <label className="text-xs text-slate-600 flex-1 min-w-[12rem]">
                <span className="block font-bold mb-1">Eventbrite event</span>
                <select value={pick} onChange={(e) => setPick(e.target.value)}
                  className="w-full border border-slate-200 rounded-lg px-2 py-2 bg-white text-sm">
                  {choices.map((c) => (
                    <option key={c.id} value={c.id}>
                      {c.name}{c.start ? ` · ${new Date(c.start).toLocaleDateString(undefined, { dateStyle: 'medium' })}` : ''}
                    </option>
                  ))}
                </select>
              </label>
              <button type="button" disabled={busy !== null || !pick}
                onClick={() => void run('link', async () => {
                  const r = await linkEventbrite(eventId, pick);
                  onSynced?.();
                  return `Linked. ${syncSummaryText(r.sync)}`;
                })}
                className={`${btn} bg-slate-900 text-white`}>
                {busy === 'link' ? <Loader2 className="w-3 h-3 animate-spin" /> : <Link2 className="w-3.5 h-3.5" />} Link and sync
              </button>
            </div>
          ))}
        </div>
      )}

      {link && (
        <div className="rounded-xl bg-slate-50 p-3 space-y-2 text-xs text-slate-600">
          <p>
            Linked to <strong className="text-slate-900">{link.ebEventName ?? `Eventbrite event ${link.ebEventId}`}</strong>
            {status.accountName ? ` (${status.accountName})` : ''}.
          </p>
          <p>
            {link.attendees} attendee{link.attendees === 1 ? '' : 's'} at the door
            {link.voided > 0 ? ` · ${link.voided} refunded or cancelled` : ''}
            {link.checkedInOnEventbrite > 0 ? ` · ${link.checkedInOnEventbrite} checked in on Eventbrite's app` : ''}
            {' '}· last synced {ago(link.lastOkAt)}
            {link.syncing ? ' · syncing now' : ''}
          </p>
          {link.lastError && <p className="text-rose-500">{link.lastError}</p>}
          {link.rowErrors > 0 && (
            <p className="text-amber-700">
              {link.rowErrors} attendee{link.rowErrors === 1 ? '' : 's'} couldn't be added (a barcode already on another
              guest?). Exos keeps retrying.
            </p>
          )}
          {status.canManage && <EventbriteInventory eventId={eventId} orgId={orgId} />}
          <div className="flex flex-wrap gap-2">
            <button type="button" disabled={busy !== null}
              onClick={() => void run('sync', async () => {
                const r = await syncEventbrite(eventId);
                onSynced?.();
                return syncSummaryText(r.sync);
              })}
              className={`${btn} bg-slate-900 text-white`}>
              <RefreshCw className={`w-3.5 h-3.5 ${busy === 'sync' ? 'animate-spin' : ''}`} /> Sync now
            </button>
            {status.canManage && (
              <button type="button" disabled={busy !== null}
                onClick={() => {
                  if (!window.confirm('Stop syncing this event? Attendees already at the door stay.')) return;
                  void run('unlink', async () => {
                    await unlinkEventbrite(eventId);
                    setChoices(null);
                    return 'Unlinked. Attendees already imported stay on the door.';
                  });
                }}
                className={`${btn} border border-slate-200 text-slate-700`}>
                <Unlink className="w-3.5 h-3.5" /> Unlink
              </button>
            )}
          </div>
        </div>
      )}

      {status.connected && status.canManage && (
        <button type="button" disabled={busy !== null}
          onClick={() => {
            if (!window.confirm('Disconnect Eventbrite for the whole organization? Every linked event stops syncing.')) return;
            void run('disconnect', async () => {
              await disconnectEventbrite(orgId);
              setChoices(null);
              return 'Disconnected. The token was deleted.';
            });
          }}
          className="text-[11px] text-slate-400 underline disabled:opacity-50">
          Disconnect Eventbrite
        </button>
      )}

      {note && <p role={note.ok ? 'status' : 'alert'} className={`text-xs ${note.ok ? 'text-emerald-700' : 'text-rose-500'}`}>{note.text}</p>}
    </section>
  );
}
