// /refund?t=<token> — the link in the "event-rescheduled" mail (mig 20260929150000).
// One link per ticket: "Get a refund" for a ticket this person paid for, or
// "Release my ticket" for a free / comp one. Works signed out: the 64-hex
// token alone says which ticket and which action, and the server (exos-refund
// → exos_request_reschedule_refund / exos_reschedule_release_svc) refuses it
// for any other ticket, after the deadline, or once the date changed again.
// Like /unsubscribe it takes a click, never acts on page load: mail scanners
// open links before the reader does.

import { useEffect, useState } from 'react';
import { Link } from 'react-router-dom';
import { applyMeta } from '../lib/meta';
import { formatInTz } from '../lib/datetime';
import { formatCents } from '../lib/refunds';
import {
  getRescheduleLinkInfo,
  requestRescheduleRefund,
  releaseForReschedule,
  reasonText,
  RESCHEDULE_TOKEN_RE,
  type RescheduleLinkInfo,
} from '../lib/rescheduleRefunds';

type State = 'loading' | 'ready' | 'busy' | 'done' | 'invalid' | 'error';

export default function RescheduleRefund() {
  const [token] = useState(() => {
    try { return new URLSearchParams(window.location.search).get('t') ?? ''; } catch { return ''; }
  });
  const [info, setInfo] = useState<RescheduleLinkInfo | null>(null);
  const [state, setState] = useState<State>(() => (RESCHEDULE_TOKEN_RE.test(token) ? 'loading' : 'invalid'));
  const [message, setMessage] = useState<string | null>(null);

  useEffect(() => {
    try { applyMeta({ title: 'Refund', description: 'Your options after a date change.' }); } catch { /* non-fatal */ }
  }, []);

  useEffect(() => {
    if (!RESCHEDULE_TOKEN_RE.test(token)) return undefined;
    let cancelled = false;
    getRescheduleLinkInfo(token)
      .then((i) => { if (!cancelled) { setInfo(i); setState('ready'); } })
      .catch(() => { if (!cancelled) setState('invalid'); });
    return () => { cancelled = true; };
  }, [token]);

  const act = async () => {
    if (!info) return;
    setState('busy');
    setMessage(null);
    try {
      const results = info.kind === 'refund'
        ? await requestRescheduleRefund({ token })
        : await releaseForReschedule({ token });
      const r = results[0];
      if (r && r.ok) {
        setState('done');
      } else {
        setMessage(r?.error || reasonText(r?.reason));
        setState('error');
      }
    } catch (e: any) {
      setMessage(e?.message || 'That didn’t work. Try again.');
      setState('error');
    }
  };

  const tz = info?.event?.timezone ?? undefined;
  const when = (d: Date | null) => (d ? formatInTz(d, tz, { dateStyle: 'full', timeStyle: 'short' }) : 'TBA');
  const inProgress = info?.requestStatus === 'claimed' || info?.requestStatus === 'pending';

  return (
    <div className="wall min-h-[70vh] flex flex-col items-center justify-center px-6 text-center">
      <div className="max-w-md">
        {state === 'invalid' ? (
          <p className="disp text-3xl md:text-4xl tracking-tight mb-4">This link isn't valid.</p>
        ) : state === 'loading' || !info ? (
          <p className="type text-brand-primary uppercase tracking-[0.3em] text-[12px] animate-pulse">Loading…</p>
        ) : state === 'done' ? (
          <>
            <p className="disp text-3xl md:text-4xl tracking-tight mb-4">
              {info.kind === 'refund' ? 'Your refund is on its way.' : 'Your ticket is released.'}
            </p>
            <p className="text-sm text-white/60 mb-6">
              {info.kind === 'refund'
                ? `${formatCents(info.amountCents, info.currency)} goes back to the card you paid with. It can take 5 to 10 days to show up. We'll email you when it's issued.`
                : 'Thanks for letting someone else have the spot.'}
            </p>
          </>
        ) : (
          <>
            <p className="type text-brand-primary uppercase tracking-widest text-[12px] mb-3">The date changed</p>
            <h1 className="disp text-3xl md:text-4xl tracking-tight mb-4">{info.event?.name ?? 'Your event'}</h1>
            <p className="text-sm text-white/60 mb-1">
              Was <span className="line-through">{when(info.oldStartsAt)}</span>
            </p>
            <p className="text-sm text-white mb-6">Now <strong>{when(info.newStartsAt)}</strong></p>
            {info.ok ? (
              <>
                <p className="text-sm text-white/70 mb-6">
                  {info.kind === 'refund'
                    ? <>Can't make it? Get <strong className="text-white">{formatCents(info.amountCents, info.currency)}</strong> back for your {info.tierName || 'ticket'} (tax included). It goes to the card you paid with, and the ticket stops working, also if you gave it to someone.</>
                    : <>Can't make it? Give your free {info.tierName || 'ticket'} back so someone else can come.</>}
                  {' '}You can do this until {when(info.refundDeadline)}.
                </p>
                <button
                  type="button"
                  onClick={act}
                  disabled={state === 'busy'}
                  className="px-6 py-3 rounded-full bg-brand-primary text-black text-xs font-black uppercase tracking-widest disabled:opacity-50"
                >
                  {state === 'busy' ? 'Working…' : info.kind === 'refund' ? 'Get a refund' : 'Release my ticket'}
                </button>
                {state === 'error' && message && (
                  <p role="alert" className="text-xs text-rose-400 mt-4">{message}</p>
                )}
              </>
            ) : (
              <p className="text-sm text-white/70">{reasonText(inProgress ? 'in-progress' : info.reason)}</p>
            )}
            <p className="text-xs text-white/50 mt-6">Keeping your ticket? There's nothing to do: it works for the new date.</p>
          </>
        )}
        <div className="mt-8">
          <Link to="/my-tickets" className="type text-[11px] uppercase tracking-widest text-brand-primary hover:underline">Your tickets</Link>
        </div>
      </div>
    </div>
  );
}
