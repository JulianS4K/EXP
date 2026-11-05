// /rsvp/:eventId — RSVP with a name and a mobile number (mig 20261102150000,
// docs/organizer-guide.md "Phone RSVP"). No app, no account: a 6-digit code
// by text (or email when the organizer can't text), then the ticket link with
// the rotating QR. ?promoter=<code> credits the promoter, like ticket links.
// Sold out: the waitlist. The hidden "website" field is a honeypot.

import { useEffect, useMemo, useState, type FormEvent } from 'react';
// Checkout questions (mig 20261106110000), asked of every guest incl. plus-ones.
import CheckoutQuestionsForm from '../components/CheckoutQuestionsForm';
import { answersBody, draftProblems, EMPTY_DRAFT, hasQuestions, type AnswerDraft } from '../lib/checkoutQuestions';
import { Link, useNavigate, useParams, useSearchParams } from 'react-router-dom';
import { Smartphone } from 'lucide-react';
import { getPublicEvent } from '../lib/events';
import { applyMeta } from '../lib/meta';
import type { Event } from '../types';
import {
  codeSentText, normalizeRsvpPhone, rsvpErrorMessage, rsvpInfo, rsvpStart, rsvpVerify, ticketPathFromUrl, type RsvpInfo,
} from '../lib/phoneRsvp';
import { nameLooksLikeEmail } from '../../supabase/functions/_shared/nameGuard.ts';
import WaitlistCTA from '../components/WaitlistCTA';

const field = 'w-full bg-black border border-white/20 px-3 py-3 text-base text-white focus:outline-none focus-visible:ring-2 focus-visible:ring-brand-primary/60 focus:border-brand-primary';

export default function PhoneRsvp() {
  const { eventId = '' } = useParams();
  const [params] = useSearchParams();
  const navigate = useNavigate();
  const [event, setEvent] = useState<Event | null>(null);
  const [info, setInfo] = useState<RsvpInfo | null>(null);
  const [step, setStep] = useState<'form' | 'code' | 'done' | 'full'>('form');
  const [name, setName] = useState('');
  const [phone, setPhone] = useState('');
  const [email, setEmail] = useState('');
  const [plus, setPlus] = useState(0);
  const [website, setWebsite] = useState('');
  const [code, setCode] = useState('');
  const [rsvpId, setRsvpId] = useState('');
  const [sentTo, setSentTo] = useState('');
  const [channel, setChannel] = useState<'sms' | 'email'>('sms');
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [tickets, setTickets] = useState<string[]>([]);
  const [answerDraft, setAnswerDraft] = useState<AnswerDraft>(EMPTY_DRAFT);
  const [showAnswerErrors, setShowAnswerErrors] = useState(false);
  const promoter = useMemo(() => {
    const p = params.get('promoter') ?? '';
    return /^[A-Za-z0-9_-]{1,64}$/.test(p) ? p : null;
  }, [params]);

  useEffect(() => {
    try { applyMeta({ title: 'RSVP', description: 'RSVP with your phone number.', noindex: true }); } catch { /* non-fatal */ }
    if (!/^[0-9a-f-]{36}$/i.test(eventId)) return;
    getPublicEvent(eventId).then(setEvent).catch(() => setEvent(null));
    rsvpInfo(eventId).then((i) => { setInfo(i); if (i.reason === 'sold_out') setStep('full'); }).catch(() => setInfo(null));
  }, [eventId]);

  // The RSVP's ticket type, once per guest (the guest and each plus-one).
  const rsvpQuestions = info?.questions ?? [];
  const rsvpTiers = info?.tier_id ? Array.from({ length: plus + 1 }, () => info.tier_id as string) : [];
  const asksQuestions = rsvpTiers.length > 0 && hasQuestions(rsvpQuestions, rsvpTiers);
  const answerProblems = asksQuestions ? draftProblems(rsvpQuestions, rsvpTiers, answerDraft) : {};

  const start = async (e: FormEvent) => {
    e.preventDefault();
    setError(null);
    if (asksQuestions && Object.keys(answerProblems).length > 0) {
      setShowAnswerErrors(true);
      setError('Answer the organizer\'s questions first.');
      return;
    }
    if (!name.trim()) { setError(rsvpErrorMessage('bad_name')); return; }
    if (nameLooksLikeEmail(name)) { setError(rsvpErrorMessage('name_is_email')); return; }
    if (!normalizeRsvpPhone(phone)) { setError(rsvpErrorMessage('bad_phone')); return; }
    if (info && !info.sms && !email.trim()) { setError(rsvpErrorMessage('no_channel')); return; }
    setBusy(true);
    try {
      const r = await rsvpStart({
        eventId, name: name.trim(), phone, email: email.trim() || undefined, plusOnes: plus, promoter, website,
        answers: asksQuestions ? answersBody(rsvpQuestions, rsvpTiers, answerDraft) : undefined,
      });
      if (!r.ok && r.error === 'answers') {
        setShowAnswerErrors(true);
        setError('Check your answers to the organizer\'s questions.');
        return;
      }
      if (!r.ok) {
        if (r.error === 'sold_out') setStep('full');
        setError(rsvpErrorMessage(r.error, { max_plus_ones: r.max_plus_ones, seats_left: r.seats_left }));
        return;
      }
      setRsvpId(r.rsvp_id!); setSentTo(r.to ?? ''); setChannel(r.channel ?? 'sms'); setCode(''); setStep('code');
    } finally {
      setBusy(false);
    }
  };

  const verify = async (e: FormEvent) => {
    e.preventDefault();
    setError(null);
    if (!/^[0-9]{6}$/.test(code.trim())) { setError('Enter the 6-digit code.'); return; }
    setBusy(true);
    try {
      const v = await rsvpVerify(rsvpId, code.trim());
      if (!v.ok) {
        if (v.error === 'sold_out') setStep('full');
        if (v.error === 'locked' || v.error === 'expired') setStep('form');
        setError(rsvpErrorMessage(v.error, { attempts_left: v.attempts_left }));
        return;
      }
      const paths = (v.tickets ?? []).map((t) => ticketPathFromUrl(t.url)).filter((p): p is string => !!p);
      setTickets(paths);
      setStep('done');
      if (paths.length === 1) navigate(paths[0]);
    } finally {
      setBusy(false);
    }
  };

  const title = event?.title ?? 'This event';
  if (info && !info.ok && info.reason !== 'sold_out') {
    return (
      <div className="max-w-md mx-auto px-4 py-20 text-center">
        <p className="type text-white/50 uppercase tracking-widest text-[10px] mb-4">{rsvpErrorMessage(info.reason)}</p>
        <Link to={`/event/${eventId}`} className="text-brand-primary font-bold text-sm">See the event</Link>
      </div>
    );
  }

  return (
    <div className="max-w-md mx-auto px-4 py-12">
      <p className="type text-[10px] text-white/40 uppercase tracking-widest mb-2 flex items-center gap-2"><Smartphone className="w-3 h-3" /> RSVP</p>
      <h1 className="disp text-3xl uppercase tracking-wide text-white mb-1">{title}</h1>
      {info?.tier_name && <p className="text-sm text-white/60 mb-6">{info.tier_name} · free</p>}

      {error && <p role="alert" className="mb-4 text-sm text-rose-300">{error}</p>}

      {step === 'form' && (
        <form onSubmit={start} className="grid gap-3">
          <input className={field} placeholder="Your name" aria-label="Your name" autoComplete="name" maxLength={80} value={name} onChange={(e) => setName(e.target.value)} />
          <input className={field} placeholder="Mobile number" aria-label="Mobile number" type="tel" inputMode="tel" autoComplete="tel" maxLength={40} value={phone} onChange={(e) => setPhone(e.target.value)} />
          {(info && !info.sms) && (
            <input className={field} placeholder="Email (we'll send your code here)" aria-label="Email" type="email" autoComplete="email" value={email} onChange={(e) => setEmail(e.target.value)} />
          )}
          {(info?.max_plus_ones ?? 0) > 0 && (
            <label className="text-sm text-white/70 flex items-center gap-3">Bringing
              <select className="bg-black border border-white/20 px-2 py-2 text-white" value={plus} onChange={(e) => setPlus(Number(e.target.value))} aria-label="Plus-ones">
                {Array.from({ length: (info?.max_plus_ones ?? 0) + 1 }, (_, i) => <option key={i} value={i}>{i === 0 ? 'just me' : `+${i}`}</option>)}
              </select>
            </label>
          )}
          {asksQuestions && (
            <CheckoutQuestionsForm questions={rsvpQuestions} ticketTiers={rsvpTiers} value={answerDraft} onChange={setAnswerDraft}
              problems={answerProblems} showErrors={showAnswerErrors} ticketNames={[name]} />
          )}
          {/* Honeypot: hidden from people, filled by bots. */}
          <input type="text" name="website" tabIndex={-1} autoComplete="off" aria-hidden="true" value={website}
            onChange={(e) => setWebsite(e.target.value)} className="hidden" />
          <button disabled={busy} className="bg-brand-primary text-black px-4 py-3 text-sm font-black uppercase disabled:opacity-50">
            {info && !info.sms ? 'Email me a code' : 'Text me a code'}
          </button>
          <p className="text-[11px] text-white/40">
            We use your number to send your code and ticket, and so the organizer can check you in. One RSVP per number.
            Message and data rates may apply.
          </p>
        </form>
      )}

      {step === 'code' && (
        <form onSubmit={verify} className="grid gap-3">
          <p className="text-sm text-white/70">{codeSentText(channel, sentTo)}</p>
          <input className={`${field} tracking-[0.5em] text-center text-2xl`} inputMode="numeric" autoComplete="one-time-code" maxLength={6}
            aria-label="Code" value={code} onChange={(e) => setCode(e.target.value.replace(/[^0-9]/g, ''))} />
          <button disabled={busy} className="bg-brand-primary text-black px-4 py-3 text-sm font-black uppercase disabled:opacity-50">Get my ticket</button>
          <button type="button" onClick={() => { setStep('form'); setError(null); }} className="text-[11px] font-black uppercase text-white/50 hover:text-white">
            Wrong number? Start again
          </button>
        </form>
      )}

      {step === 'done' && (
        <div className="grid gap-3">
          <p className="text-sm text-white/80">You're in. Show your ticket at the door: its QR code changes every 30 seconds. We also sent the link{tickets.length > 1 ? 's' : ''} to you.</p>
          {tickets.map((p, i) => (
            <Link key={p} to={p} className="border border-white/20 px-4 py-3 text-sm font-black uppercase text-white hover:border-brand-primary">
              {i === 0 ? 'Open my ticket' : `Guest ${i} ticket (send it to them)`}
            </Link>
          ))}
        </div>
      )}

      {step === 'full' && (
        <div className="mt-2">
          <p className="text-sm text-white/70 mb-3">{rsvpErrorMessage('sold_out')}</p>
          <WaitlistCTA eventId={eventId} />
        </div>
      )}
    </div>
  );
}
