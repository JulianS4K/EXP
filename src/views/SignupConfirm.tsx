// /signup/confirm?t=<token> — the link in a signup form's confirm mail
// (double opt-in, mig 20261031120000) — and /signup/unsubscribe?t=<token>.
// Both take a click rather than firing on page load: mail scanners open links
// before the reader does, and a scanner must never put anyone on a list.
// Neither page shows anything about the fan beyond the organizer's name.
// When the signup asked for texts too, the fan turns them on here, signed in
// (the same rule as the ticket-page opt-in: a stranger can't sign up a number).

import { useEffect, useState } from 'react';
import { Link, useLocation } from 'react-router-dom';
import { applyMeta } from '../lib/meta';
import { useAuth } from '../context/AuthContext';
import { confirmSignup, confirmSignupSms, signupToken, unsubscribeSignup } from '../lib/signupForms';

type State = 'idle' | 'busy' | 'done' | 'error';

export default function SignupConfirm({ mode }: { mode: 'confirm' | 'unsubscribe' }) {
  const { search } = useLocation();
  const token = signupToken(search);
  const { user, openAuthModal } = useAuth();
  const [state, setState] = useState<State>('idle');
  const [orgName, setOrgName] = useState('');
  const [smsPending, setSmsPending] = useState(false);
  const [smsState, setSmsState] = useState<State>('idle');
  const [smsHint, setSmsHint] = useState('');
  const [smsError, setSmsError] = useState('');

  useEffect(() => {
    try {
      applyMeta(mode === 'confirm'
        ? { title: 'Confirm your signup', description: 'Confirm to join the list.' }
        : { title: 'Unsubscribe', description: 'Leave this organizer\'s email list.' });
    } catch { /* non-fatal */ }
  }, [mode]);

  const go = async () => {
    if (!token) return;
    setState('busy');
    try {
      if (mode === 'confirm') {
        const r = await confirmSignup(token);
        setOrgName(r.orgName);
        setSmsPending(r.smsPending);
        setState(r.ok ? 'done' : 'error');
      } else {
        const r = await unsubscribeSignup(token);
        setOrgName(r.orgName);
        setState(r.ok ? 'done' : 'error');
      }
    } catch {
      setState('error');
    }
  };

  const turnOnTexts = async () => {
    if (!token) return;
    setSmsState('busy');
    setSmsError('');
    try {
      setSmsHint(await confirmSignupSms(token));
      setSmsState('done');
    } catch (e) {
      setSmsError((e as Error).message || 'That didn\'t work.');
      setSmsState('error');
    }
  };

  const btn = 'px-6 py-3 rounded-full bg-brand-primary text-white text-xs font-black uppercase tracking-widest disabled:opacity-50';

  return (
    <div className="wall min-h-[70vh] flex flex-col items-center justify-center px-6 text-center">
      {!token ? (
        <p className="disp text-3xl md:text-4xl tracking-tight mb-4">This link isn't valid.</p>
      ) : state === 'done' && mode === 'unsubscribe' ? (
        <>
          <p className="disp text-3xl md:text-4xl tracking-tight mb-4">You're off the list.</p>
          <p className="text-sm text-white/60 mb-6">No more emails from {orgName || 'this organizer'}'s list. Tickets and receipts still arrive.</p>
        </>
      ) : state === 'done' ? (
        <>
          <p className="disp text-3xl md:text-4xl tracking-tight mb-4">You're on the list.</p>
          <p className="text-sm text-white/60 mb-6">{orgName || 'The organizer'} will email you about new events. Every email has an unsubscribe link.</p>
          {smsPending && smsState !== 'done' && (
            <div className="border border-white/15 p-4 max-w-md">
              <p className="text-sm text-white/80 mb-3">You also asked for texts. Sign in to turn them on for the number you gave.</p>
              {user ? (
                <button type="button" className={btn} disabled={smsState === 'busy'} onClick={() => void turnOnTexts()}>
                  {smsState === 'busy' ? 'Turning on…' : 'Turn on texts'}
                </button>
              ) : (
                <button type="button" className={btn} onClick={() => openAuthModal()}>Sign in</button>
              )}
              {smsState === 'error' && <p className="text-xs text-rose-400 mt-3">{smsError}</p>}
            </div>
          )}
          {smsState === 'done' && (
            <p className="text-sm text-white/60">Texts on for {smsHint}. Reply STOP to any of them to stop.</p>
          )}
        </>
      ) : (
        <>
          <p className="disp text-3xl md:text-4xl tracking-tight mb-4">
            {mode === 'confirm' ? 'Confirm your signup?' : 'Leave this email list?'}
          </p>
          <p className="text-sm text-white/60 mb-6">
            {mode === 'confirm'
              ? 'One click and you\'re on the organizer\'s list. If you didn\'t sign up, close this page: nothing happens.'
              : 'You\'ll stop getting this organizer\'s list emails. Tickets, receipts and event changes still arrive.'}
          </p>
          <button type="button" onClick={() => void go()} disabled={state === 'busy'} className={btn}>
            {state === 'busy' ? 'One moment…' : mode === 'confirm' ? 'Confirm' : 'Unsubscribe'}
          </button>
          {state === 'error' && (
            <p className="text-xs text-rose-400 mt-4">That didn't work. Confirm links last 7 days; sign up again for a new one.</p>
          )}
        </>
      )}
      <Link to="/" className="type text-[11px] uppercase tracking-widest text-brand-primary hover:underline mt-8">Browse events</Link>
    </div>
  );
}
