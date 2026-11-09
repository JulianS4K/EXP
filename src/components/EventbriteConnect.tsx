// Org settings → Integrations → Eventbrite (mig 20261029140000): the org's
// Eventbrite connection. "Connect Eventbrite" signs in on Eventbrite
// (exos-eventbrite-oauth) when this server has the OAuth app configured;
// otherwise the private token is pasted on an event's door page, as before.
// Eventbrite sends the browser back to the settings page, where OAuthFinish
// asks the user to confirm before anything is saved; a sign-in started from
// a door page then goes back to that event to pick the Eventbrite event. Exos only reads Eventbrite; nothing changes there
// unless the org also switches on the capacity sync.

import { useCallback, useEffect, useRef, useState } from 'react';
import { CheckCircle2, Loader2 } from 'lucide-react';
import { useToast } from '../context/ToastContext';
import {
  disconnectEventbrite, eventbriteOAuthAvailable, fetchEventbriteOrgStatus, startEventbriteConnect,
  type EventbriteOrgStatus,
} from '../lib/door/eventbrite';
import { authMethodLabel, eventbriteErrorMessage } from '../lib/eventbriteConnect';

const BTN = 'px-3 py-1.5 rounded text-[10px] font-black uppercase tracking-widest disabled:opacity-50';

function when(iso: string): string {
  return new Date(iso).toLocaleString(undefined, { dateStyle: 'medium', timeStyle: 'short' });
}

export default function EventbriteConnect({ orgId }: { orgId: string }) {
  const { toast } = useToast();
  const [status, setStatus] = useState<EventbriteOrgStatus | null | undefined>(undefined);
  const [oauth, setOauth] = useState(false);
  const [busy, setBusy] = useState<null | 'connect' | 'disconnect'>(null);
  const alive = useRef(true);

  const load = useCallback(async () => {
    try {
      const s = await fetchEventbriteOrgStatus(orgId);
      if (alive.current) setStatus(s);
    } catch {
      if (alive.current) setStatus(null);
    }
  }, [orgId]);

  useEffect(() => {
    alive.current = true;
    void load();
    void eventbriteOAuthAvailable().then((v) => { if (alive.current) setOauth(v); });
    return () => { alive.current = false; };
  }, [load]);

  const connect = async () => {
    setBusy('connect');
    try {
      window.location.assign(await startEventbriteConnect(orgId));
    } catch (e: any) {
      toast({ kind: 'error', message: eventbriteErrorMessage(e?.reason ?? 'unknown') });
      setBusy(null);
    }
  };

  const disconnect = async () => {
    if (!window.confirm('Disconnect Eventbrite for the whole organization? Every linked event stops syncing; attendees already at the door stay.')) return;
    setBusy('disconnect');
    try {
      await disconnectEventbrite(orgId);
      toast({ kind: 'success', message: 'Disconnected. Exos deleted its Eventbrite token.' });
      await load();
    } catch (e) {
      toast({ kind: 'error', message: (e as Error).message });
    } finally {
      setBusy(null);
    }
  };

  if (status === undefined) {
    return <li className="border border-slate-200 rounded-xl p-4 text-xs text-slate-400">Checking Eventbrite…</li>;
  }
  if (status === null) return null;  // not deployed, or no door role in this org

  return (
    <li className="border border-slate-200 rounded-xl p-4">
      <div className="flex flex-wrap items-start justify-between gap-2">
        <div className="min-w-0">
          <p className="text-sm font-bold text-slate-900">Eventbrite</p>
          <p className="text-[11px] text-slate-500 mt-0.5">
            Live attendee sync to the Exos door, and one shared ticket count if you switch it on per event.
            Exos reads your Eventbrite events and attendees.
          </p>
        </div>
        {status.connected && (
          <span className="inline-flex items-center gap-1 text-[10px] font-black uppercase tracking-widest rounded px-2 py-0.5 bg-emerald-50 text-emerald-700">
            <CheckCircle2 className="w-3 h-3" aria-hidden="true" /> Connected
          </span>
        )}
      </div>

      {status.connected ? (
        <p className="text-[11px] text-slate-500 mt-2">
          {status.accountName ? `${status.accountName} · ` : ''}{authMethodLabel(status.authMethod)}
          {status.connectedAt ? ` · since ${when(status.connectedAt)}` : ''}
          {` · ${status.linkedEvents} linked event${status.linkedEvents === 1 ? '' : 's'}`}.
          {' '}Link each Exos event to its Eventbrite event on the event’s door tab.
        </p>
      ) : (
        <p className="text-[11px] text-slate-500 mt-2">
          {oauth
            ? 'Sign in on Eventbrite and allow Exos. You never handle a token.'
            : 'Connect from an event’s door tab with your Eventbrite private token.'}
        </p>
      )}

      {status.canManage && (
        <div className="mt-3 flex flex-wrap gap-2">
          {oauth && (
            <button type="button" onClick={() => void connect()} disabled={busy !== null}
              className={`${BTN} ${status.connected ? 'border border-slate-200 text-slate-700' : 'bg-tm-blue text-white'} inline-flex items-center gap-1`}>
              {busy === 'connect' && <Loader2 className="w-3 h-3 animate-spin" aria-hidden="true" />}
              {status.connected ? 'Reconnect' : 'Connect Eventbrite'}
            </button>
          )}
          {status.connected && (
            <button type="button" onClick={() => void disconnect()} disabled={busy !== null}
              className={`${BTN} border border-rose-200 text-rose-600`}>
              Disconnect
            </button>
          )}
        </div>
      )}
      {!status.canManage && !status.connected && (
        <p className="text-[11px] text-slate-500 mt-2">Ask an owner or manager to connect Eventbrite.</p>
      )}

      {status.history.length > 0 && (
        <details className="mt-3">
          <summary className="text-[10px] font-black uppercase tracking-widest text-slate-400 cursor-pointer">History</summary>
          <ul className="mt-2 space-y-1 text-[11px] text-slate-500">
            {status.history.map((h, i) => (
              <li key={`${h.at}-${i}`}>
                {when(h.at)}: {h.action === 'connect' ? 'connected' : 'disconnected'}
                {h.accountName ? ` ${h.accountName}` : ''}
                {h.authMethod ? ` (${h.authMethod === 'oauth' ? 'Eventbrite sign-in' : 'private token'})` : ''}
                {h.byYou ? ' by you' : ''}
              </li>
            ))}
          </ul>
        </details>
      )}
    </li>
  );
}
