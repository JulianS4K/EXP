// /drop/confirm?t=<token> and /drop/leave?t=<token>: the links in the drop
// list mails (mig 20261118100000). Both take a click rather than firing on
// page load: mail scanners open links before the reader does, and a scanner
// must never confirm or remove anyone. Neither page shows anything about the
// person beyond the event's name.

import { useEffect, useState } from 'react';
import { Link, useLocation } from 'react-router-dom';
import { applyMeta } from '../lib/meta';
import { dropConfirmLink, dropLeaveLink, linkToken } from '../lib/dropList';

type State = 'idle' | 'busy' | 'done' | 'error';

export default function DropLink({ mode }: { mode: 'confirm' | 'leave' }) {
  const { search } = useLocation();
  const token = linkToken(search);
  const [state, setState] = useState<State>('idle');
  const [eventName, setEventName] = useState<string | null>(null);
  const [eventId, setEventId] = useState<string | null>(null);

  useEffect(() => {
    try {
      applyMeta(mode === 'confirm'
        ? { title: 'Confirm: notify me', description: 'Confirm to hear when tickets go on sale.' }
        : { title: 'Leave the list', description: 'Stop the on-sale email and text for this event.' });
    } catch { /* non-fatal */ }
  }, [mode]);

  const go = async () => {
    if (!token) return;
    setState('busy');
    try {
      if (mode === 'confirm') {
        const r = await dropConfirmLink(token);
        setEventName(r.eventName);
        setEventId(r.eventId);
        setState(r.ok ? 'done' : 'error');
      } else {
        const r = await dropLeaveLink(token);
        setEventName(r.eventName);
        setState(r.ok ? 'done' : 'error');
      }
    } catch {
      setState('error');
    }
  };

  const btn = 'px-6 py-3 rounded-full bg-brand-primary text-black text-xs font-black uppercase tracking-widest disabled:opacity-50';

  return (
    <div className="wall min-h-[70vh] flex flex-col items-center justify-center px-6 text-center">
      {!token ? (
        <h1 className="disp text-3xl md:text-4xl tracking-tight mb-4">This link isn't valid.</h1>
      ) : state === 'done' && mode === 'leave' ? (
        <>
          <h1 className="disp text-3xl md:text-4xl tracking-tight mb-4">You left the list.</h1>
          <p className="text-sm text-white/80 mb-6">No on-sale email or text for {eventName || 'this event'}.</p>
        </>
      ) : state === 'done' ? (
        <>
          <h1 className="disp text-3xl md:text-4xl tracking-tight mb-4">You're on the list.</h1>
          <p className="text-sm text-white/80 mb-6">
            We'll email you once when tickets for {eventName || 'this event'} go on sale.
          </p>
          {eventId && (
            <Link to={`/event/${eventId}`} className="type text-[11px] uppercase tracking-widest text-white underline">See the event</Link>
          )}
        </>
      ) : (
        <>
          <h1 className="disp text-3xl md:text-4xl tracking-tight mb-4">
            {mode === 'confirm' ? 'Tell you when tickets go on sale?' : 'Leave this list?'}
          </h1>
          <p className="text-sm text-white/80 mb-6">
            {mode === 'confirm'
              ? 'One click and you\'re on the list for one email at the on-sale. If you didn\'t ask, close this page: nothing happens.'
              : 'You won\'t get the on-sale email or text for this event.'}
          </p>
          <button type="button" onClick={() => void go()} disabled={state === 'busy'} className={btn}>
            {state === 'busy' ? 'One moment…' : mode === 'confirm' ? 'Confirm' : 'Leave the list'}
          </button>
          {state === 'error' && (
            <p className="text-xs text-rose-300 mt-4" role="alert">
              That didn't work. Confirm links last 7 days; sign up on the event page for a new one.
            </p>
          )}
        </>
      )}
      <Link to="/" className="type text-[11px] uppercase tracking-widest text-white hover:underline mt-8">Browse events</Link>
    </div>
  );
}
