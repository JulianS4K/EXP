// "Notify me when tickets go on sale" (drop list, mig 20261118100000) on the
// event page while every public ticket type opens later. Signed in with a
// confirmed email: one click, plus an optional text with its own checkbox and
// consent words. Everyone else: an email, then the confirm link or the
// 6-digit code from the mail, typed here (only this browser's code works).
// The guest answer is always "check your email", whether or not the address
// is already on the list. Sold out stays the existing waitlist.

import { useEffect, useId, useState } from 'react';
import { Bell, Check } from 'lucide-react';
import { useAuth } from '../context/AuthContext';
import type { Attribution } from '../lib/attribution';
import {
  cleanCode, dropConfirmCode, dropJoin, dropLeaveMine, dropSignup, dropSource, getDropStatus, type DropStatus,
} from '../lib/dropList';

interface Props {
  eventId: string;
  timezone?: string | null;
  attribution?: Attribution | null;
}

type Step = 'form' | 'check_email' | 'joined';

function when(d: Date | null, tz?: string | null): string | null {
  if (!d) return null;
  try {
    return d.toLocaleString(undefined, { dateStyle: 'medium', timeStyle: 'short', timeZone: tz || undefined });
  } catch {
    return d.toLocaleString();
  }
}

export default function DropListCTA({ eventId, timezone, attribution }: Props) {
  const { user, openAuthModal } = useAuth();
  const [status, setStatus] = useState<DropStatus | null>(null);
  const [step, setStep] = useState<Step>('form');
  const [email, setEmail] = useState('');
  const [wantsSms, setWantsSms] = useState(false);
  const [phone, setPhone] = useState('');
  const [code, setCode] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [note, setNote] = useState<string | null>(null);
  const ids = { email: useId(), phone: useId(), sms: useId(), code: useId(), consent: useId(), smsConsent: useId() };
  const confirmed = !!user?.emailVerified;

  useEffect(() => {
    let live = true;
    getDropStatus(eventId)
      .then((s) => {
        if (!live) return;
        setStatus(s);
        if (s.joined) setStep('joined');
      })
      .catch(() => { if (live) setStatus(null); });
    return () => { live = false; };
  }, [eventId, user?.uid]);

  if (!status?.open) return null;
  const onSale = when(status.onSaleAt, timezone);

  const join = async () => {
    setBusy(true); setError(null);
    try {
      const s = await dropJoin(eventId, { sms: wantsSms, phone, source: dropSource(attribution) });
      setStatus(s);
      setStep('joined');
    } catch (e) {
      setError((e as Error).message || 'That didn\'t work. Try again.');
    } finally {
      setBusy(false);
    }
  };

  const signup = async () => {
    const trimmed = email.trim();
    if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(trimmed)) { setError('Enter a valid email address.'); return; }
    setBusy(true); setError(null);
    try {
      await dropSignup(eventId, trimmed, dropSource(attribution));
      setStep('check_email');
    } catch (e) {
      setError((e as Error).message || 'That didn\'t work. Try again.');
    } finally {
      setBusy(false);
    }
  };

  const confirmCode = async () => {
    const c = cleanCode(code);
    if (!c) { setError('Enter the 6 digits from the email.'); return; }
    setBusy(true); setError(null);
    try {
      if (await dropConfirmCode(eventId, c)) {
        setStep('joined');
        setNote('You\'re on the list.');
      } else {
        setError('That code didn\'t work. Use the newest email, or its Confirm link.');
      }
    } catch (e) {
      setError((e as Error).message || 'That didn\'t work. Try again.');
    } finally {
      setBusy(false);
    }
  };

  const leave = async () => {
    setBusy(true); setError(null);
    try {
      await dropLeaveMine(eventId);
      setStatus({ ...status, joined: false, sms: false, phoneHint: null });
      setStep('form');
      setNote('You left the list.');
    } catch (e) {
      setError((e as Error).message || 'That didn\'t work. Try again.');
    } finally {
      setBusy(false);
    }
  };

  const btn = 'w-full inline-flex items-center justify-center gap-2 bg-brand-primary px-4 py-3 text-xs font-black uppercase tracking-widest text-black disabled:opacity-60';
  const input = 'w-full border border-white/30 bg-black/40 px-3 py-2 text-sm text-white placeholder:text-white/60 focus:border-brand-primary focus:outline-none';

  return (
    <section aria-labelledby={`${ids.email}-h`} data-drop-list className="mt-4 border border-white/20 p-4">
      <h3 id={`${ids.email}-h`} className="type flex items-center gap-2 text-[11px] uppercase tracking-widest text-white">
        <Bell className="h-3 w-3" aria-hidden="true" /> Notify me when tickets go on sale
      </h3>
      {onSale && <p className="type mt-1 text-[11px] text-white/70">On sale {onSale}.</p>}
      {status.listPresale && step !== 'joined' && (
        <p className="type mt-1 text-[11px] text-white/80">The list gets early access before the public on-sale.</p>
      )}

      {step === 'joined' ? (
        <div className="mt-3 space-y-2">
          <p className="flex items-center gap-2 text-sm text-white" role="status">
            <Check className="h-4 w-4" aria-hidden="true" /> You're on the list. We'll email you once when tickets go on sale
            {status.sms && status.phoneHint ? ` and text ${status.phoneHint}` : ''}.
          </p>
          {user && (
            <button type="button" onClick={() => void leave()} disabled={busy}
              className="type text-[11px] uppercase tracking-widest text-white/80 underline hover:text-white disabled:opacity-60">
              Leave the list
            </button>
          )}
        </div>
      ) : step === 'check_email' ? (
        <div className="mt-3 space-y-2">
          <p className="text-sm text-white" role="status">
            Check your email. Click Confirm in it, or type its 6-digit code here.
          </p>
          <label htmlFor={ids.code} className="type block text-[11px] uppercase tracking-widest text-white/80">Code from the email</label>
          <input id={ids.code} inputMode="numeric" autoComplete="one-time-code" maxLength={7} value={code}
            onChange={(e) => setCode(e.target.value)} className={input} />
          <button type="button" onClick={() => void confirmCode()} disabled={busy} className={btn}>Confirm</button>
        </div>
      ) : user && confirmed ? (
        <div className="mt-3 space-y-3">
          <p id={ids.consent} className="text-[11px] leading-relaxed text-white/80">{status.emailConsentText}</p>
          <div className="flex items-start gap-2">
            <input id={ids.sms} type="checkbox" checked={wantsSms} onChange={(e) => setWantsSms(e.target.checked)}
              aria-describedby={ids.smsConsent} className="mt-1" />
            <label htmlFor={ids.sms} className="text-sm text-white">Also text me (optional)</label>
          </div>
          {wantsSms && (
            <>
              <label htmlFor={ids.phone} className="type block text-[11px] uppercase tracking-widest text-white/80">Mobile number</label>
              <input id={ids.phone} type="tel" autoComplete="tel" value={phone} onChange={(e) => setPhone(e.target.value)}
                placeholder="+1 212 555 0100" className={input} />
            </>
          )}
          <p id={ids.smsConsent} className={wantsSms ? 'text-[11px] leading-relaxed text-white/80' : 'sr-only'}>{status.smsConsentText}</p>
          <button type="button" onClick={() => void join()} disabled={busy || (wantsSms && !phone.trim())}
            aria-describedby={ids.consent} className={btn}>
            <Bell className="h-3 w-3" aria-hidden="true" /> Notify me
          </button>
        </div>
      ) : (
        <form className="mt-3 space-y-3" onSubmit={(e) => { e.preventDefault(); void signup(); }}>
          <label htmlFor={ids.email} className="type block text-[11px] uppercase tracking-widest text-white/80">Email</label>
          <input id={ids.email} type="email" autoComplete="email" required value={email}
            onChange={(e) => setEmail(e.target.value)} aria-describedby={ids.consent} className={input} />
          <p id={ids.consent} className="text-[11px] leading-relaxed text-white/80">{status.emailConsentText}</p>
          <button type="submit" disabled={busy} className={btn}>
            <Bell className="h-3 w-3" aria-hidden="true" /> Notify me
          </button>
          {!user && (
            <p className="text-[11px] text-white/70">
              Want a text too? <button type="button" onClick={() => openAuthModal()} className="underline hover:text-white">Sign in</button> first.
            </p>
          )}
        </form>
      )}

      <div aria-live="polite">
        {error && <p className="mt-2 text-xs text-rose-300">{error}</p>}
        {!error && note && step !== 'joined' && <p className="mt-2 text-xs text-white/80">{note}</p>}
      </div>
    </section>
  );
}
