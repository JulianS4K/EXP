// /embed/signup/:formId — an organizer's signup form on any website, loaded by
// public/embed.js from <div data-exos-signup="FORM_ID"> (or a plain iframe).
// Sends to the exos-signup function, which answers the same for every
// address; the fan then gets a confirm mail (double opt-in). Texts, when the
// form offers them, show the same consent words as the ticket page and are
// turned on from the confirm page, signed in. No payment on this page.
//
// Captcha hook: with VITE_EXOS_CAPTCHA_SITE_KEY set, a Cloudflare Turnstile
// widget is shown and its token sent along (exos-signup checks it when
// EXOS_SIGNUP_CAPTCHA_SECRET is set). Unset = no widget, no third-party script.

import { useEffect, useRef, useState, type FormEvent } from 'react';
import { useParams } from 'react-router-dom';
import { useEmbedHost, useEmbedResize } from '../hooks/useEmbedResize';
import {
  getPublicSignupForm, signupProblem, submitSignup, type PublicSignupForm, type SignupFields,
} from '../lib/signupForms';

const SITE_KEY = ((import.meta as any).env?.VITE_EXOS_CAPTCHA_SITE_KEY as string | undefined) ?? '';
const TURNSTILE_SRC = 'https://challenges.cloudflare.com/turnstile/v0/api.js?render=explicit';

declare global {
  interface Window {
    turnstile?: { render: (el: HTMLElement, o: Record<string, unknown>) => string; reset: (id?: string) => void };
  }
}

function Captcha({ onToken }: { onToken: (t: string | null) => void }) {
  const box = useRef<HTMLDivElement>(null);
  useEffect(() => {
    if (!SITE_KEY || !box.current) return undefined;
    let cancelled = false;
    const mount = () => {
      if (cancelled || !box.current || !window.turnstile) return;
      window.turnstile.render(box.current, {
        sitekey: SITE_KEY,
        callback: (t: string) => onToken(t),
        'expired-callback': () => onToken(null),
        'error-callback': () => onToken(null),
      });
    };
    if (window.turnstile) mount();
    else {
      const s = document.createElement('script');
      s.src = TURNSTILE_SRC;
      s.async = true;
      s.onload = mount;
      document.head.appendChild(s);
    }
    return () => { cancelled = true; };
  }, [onToken]);
  return SITE_KEY ? <div ref={box} className="mt-3" /> : null;
}

export default function EmbedSignup() {
  const { formId = '' } = useParams();
  const host = useEmbedHost();
  const root = useRef<HTMLDivElement>(null);
  useEmbedResize(host, root);
  const [form, setForm] = useState<PublicSignupForm | null | undefined>(undefined);
  const [f, setF] = useState<SignupFields>({ email: '', firstName: '', lastName: '', phone: '', wantsSms: false });
  const [honeypot, setHoneypot] = useState('');
  const [captcha, setCaptcha] = useState<string | null>(null);
  const [state, setState] = useState<'idle' | 'busy' | 'sent'>('idle');
  const [error, setError] = useState('');

  useEffect(() => {
    let alive = true;
    getPublicSignupForm(formId).then((x) => { if (alive) setForm(x); }).catch(() => { if (alive) setForm(null); });
    return () => { alive = false; };
  }, [formId]);

  const send = async (e: FormEvent) => {
    e.preventDefault();
    if (!form) return;
    const problem = signupProblem(f, form);
    if (problem) { setError(problem); return; }
    if (SITE_KEY && !captcha) { setError('Complete the check first.'); return; }
    setState('busy');
    setError('');
    try {
      await submitSignup(form.id, f, captcha, honeypot);
      setState('sent');
    } catch (err) {
      setError((err as Error).message);
      setState('idle');
    }
  };

  const input = 'w-full bg-white border border-slate-300 rounded px-3 py-2 text-sm text-slate-900';

  return (
    <div ref={root} className="bg-white text-slate-900 p-5 max-w-[480px]">
      {form === undefined ? (
        <p className="text-xs text-slate-400 uppercase tracking-widest animate-pulse">Loading…</p>
      ) : form === null ? (
        <p className="text-sm text-slate-500">This signup form isn't available.</p>
      ) : state === 'sent' ? (
        <div role="status">
          <p className="text-lg font-bold">Check your inbox</p>
          <p className="text-sm text-slate-600 mt-1">
            We sent a link to {f.email.trim()}. Click it to join {form.orgName}'s list{f.wantsSms ? ' (and turn on texts)' : ''}.
          </p>
        </div>
      ) : (
        <form onSubmit={(e) => void send(e)} noValidate>
          <h1 className="text-lg font-bold leading-tight">{form.title}</h1>
          {form.intro && <p className="text-sm text-slate-600 mt-1 whitespace-pre-line">{form.intro}</p>}
          <div className="mt-4 space-y-2">
            {form.askName && (
              <div className="flex gap-2">
                <input className={input} aria-label="First name" placeholder="First name" autoComplete="given-name" maxLength={60}
                  value={f.firstName} onChange={(e) => setF({ ...f, firstName: e.target.value })} />
                <input className={input} aria-label="Last name" placeholder="Last name" autoComplete="family-name" maxLength={60}
                  value={f.lastName} onChange={(e) => setF({ ...f, lastName: e.target.value })} />
              </div>
            )}
            <input className={input} type="email" required aria-label="Email" placeholder="Email" autoComplete="email" maxLength={254}
              value={f.email} onChange={(e) => setF({ ...f, email: e.target.value })} />
            {/* Honeypot: hidden from people; a bot that fills it gets the usual answer and nothing is saved. */}
            <input type="text" name="url" tabIndex={-1} autoComplete="off" aria-hidden="true" value={honeypot}
              onChange={(e) => setHoneypot(e.target.value)} style={{ position: 'absolute', left: '-10000px', width: 1, height: 1, opacity: 0 }} />
            {form.offerSms && (
              <div className="pt-1">
                <label className="flex items-start gap-2 text-[11px] text-slate-500 leading-relaxed">
                  <input type="checkbox" className="mt-0.5" checked={f.wantsSms} onChange={(e) => setF({ ...f, wantsSms: e.target.checked })} />
                  <span>{form.smsConsentText}</span>
                </label>
                {f.wantsSms && (
                  <input className={`${input} mt-2`} type="tel" inputMode="tel" aria-label="Mobile number" placeholder="+1 212 555 0100"
                    autoComplete="tel" maxLength={32} value={f.phone} onChange={(e) => setF({ ...f, phone: e.target.value })} />
                )}
              </div>
            )}
          </div>
          <Captcha onToken={setCaptcha} />
          {error && <p role="alert" className="text-xs text-rose-600 mt-2">{error}</p>}
          <button type="submit" disabled={state === 'busy'}
            className="mt-3 w-full bg-slate-900 text-white rounded px-4 py-2.5 text-sm font-bold disabled:opacity-50">
            {state === 'busy' ? 'Sending…' : form.buttonLabel}
          </button>
          <p className="text-[11px] text-slate-400 mt-2 leading-snug">
            {form.emailConsentText} We'll email you a link to confirm first.
          </p>
        </form>
      )}
    </div>
  );
}
