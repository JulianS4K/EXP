// /auth/callback — where email confirmation, the magic link in the sign-in
// code email, email-change links and OAuth providers send people back.
// Every such redirect is built by callbackUrl() (src/lib/authUrls.ts) with
// ?next=<the page they were on>; the same path is also kept in localStorage
// for links opened without it. Once the session is set we go there (only
// same-origin app paths are followed; anything else goes home).

import { useEffect, useId, useRef, useState, type FormEvent } from 'react';
import { Link, useNavigate } from 'react-router-dom';
import { Loader2 } from 'lucide-react';
import { supabase } from '../lib/supabase';
import { useAuth } from '../context/AuthContext';
import { useToast } from '../context/ToastContext';
import { applyMeta } from '../lib/meta';
import { authUrlParams, callbackUrl, takeReturnPath } from '../lib/authUrls';
import { arrivalUrl, scrubAuthParams, settleAuthRedirect } from '../lib/authRedirect';
import { cleanEmail, isValidEmail, mapAuthError } from '../lib/authRules';
import { useCooldown, RESEND_COOLDOWN_S } from '../hooks/useCooldown';
import { AuthField, AuthNotices, authLinkButton, authPrimaryButton } from '../components/AuthFields';

type Stage = 'working' | 'error' | 'email-change' | 'none';

const WELCOME: Record<string, string> = {
  signup: "Email confirmed. You're signed in.",
  email_change: 'Email address updated.',
  invite: "You're in. Welcome to Exos.",
};

export default function AuthCallback() {
  const { user, openAuth } = useAuth();
  const { toast } = useToast();
  const navigate = useNavigate();
  const [stage, setStage] = useState<Stage>('working');
  const [message, setMessage] = useState('');
  const [next, setNext] = useState<string | null>(null);
  const [email, setEmail] = useState('');
  const [error, setError] = useState('');
  const [info, setInfo] = useState('');
  const [busy, setBusy] = useState(false);
  const cooldown = useCooldown();
  const headingId = useId();
  const headingRef = useRef<HTMLHeadingElement>(null);

  useEffect(() => {
    try { applyMeta({ title: 'Signing in', description: 'Finishing sign-in.' }); } catch { /* non-fatal */ }
  }, []);

  useEffect(() => {
    let cancelled = false;
    const href = arrivalUrl();
    const nextParam = authUrlParams(href).next ?? null;
    setNext(nextParam);
    void settleAuthRedirect(href).then((out) => {
      if (cancelled) return;
      scrubAuthParams();
      if (out.status === 'session') {
        if (out.type === 'recovery') {
          navigate('/reset-password', { replace: true });
          return;
        }
        const welcome = out.type ? WELCOME[out.type] : undefined;
        if (welcome) toast({ kind: 'success', message: welcome });
        navigate(takeReturnPath(nextParam), { replace: true });
        return;
      }
      if (out.status === 'error') setMessage(out.error.message);
      setStage(out.status === 'notice' ? 'email-change' : out.status === 'error' ? 'error' : 'none');
    });
    return () => {
      cancelled = true;
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  useEffect(() => {
    if (stage !== 'working') headingRef.current?.focus();
  }, [stage]);

  // Signed in from the modal after a dead link: carry on to where they were.
  useEffect(() => {
    if (user && (stage === 'error' || stage === 'none')) navigate(takeReturnPath(next), { replace: true });
  }, [user, stage, next, navigate]);

  const resend = async (e: FormEvent) => {
    e.preventDefault();
    setError('');
    setInfo('');
    if (!isValidEmail(email)) return setError('Enter a valid email address.');
    if (cooldown.left > 0) return;
    setBusy(true);
    const { error: err } = await supabase.auth.resend({ type: 'signup', email: cleanEmail(email), options: { emailRedirectTo: callbackUrl(next) } });
    setBusy(false);
    if (err) {
      const mapped = mapAuthError(err);
      if (mapped.kind === 'rate_limited') cooldown.start(mapped.retryAfter ?? RESEND_COOLDOWN_S);
      return setError(mapped.message);
    }
    setInfo('If that address is waiting to be confirmed, a new link is on its way.');
    cooldown.start(RESEND_COOLDOWN_S);
  };

  const title =
    stage === 'working' ? 'Signing you in' : stage === 'email-change' ? 'One more step' : stage === 'error' ? 'Link expired' : 'Nothing to finish';

  return (
    <div className="wall min-h-[70vh] flex items-center justify-center px-4 py-16">
      <section aria-labelledby={headingId} className="w-full max-w-md bg-[#0e0e0e] border border-white/10 p-8 space-y-4">
        <h1 ref={headingRef} id={headingId} tabIndex={-1} className="disp text-3xl uppercase tracking-tight leading-none mb-2 focus:outline-none" style={{ transform: 'skewX(-4deg)' }}>
          {title}
        </h1>

        {stage === 'working' && (
          <p role="status" className="type text-[12px] uppercase tracking-widest text-white/60 flex items-center gap-3">
            <Loader2 className="w-4 h-4 animate-spin" aria-hidden="true" /> One moment…
          </p>
        )}

        {stage === 'email-change' && (
          <p role="status" className="type text-[13px] text-white/80 leading-relaxed">
            Confirmed on this address. Now open the link we sent to your other address to finish changing your email.
          </p>
        )}

        {stage === 'none' && (
          <p className="type text-[13px] text-white/70 leading-relaxed">
            This page finishes sign-in links. Open the latest link from your email, or sign in again.
          </p>
        )}

        {stage === 'error' && (
          <>
            <AuthNotices error={message} />
            <p className="type text-[12px] text-white/70 leading-relaxed">
              Confirming a new account? Send the confirmation email again. Otherwise, sign in with a code or your password.
            </p>
            <form onSubmit={resend} className="space-y-4" noValidate>
              <AuthNotices error={error} info={info} />
              <AuthField
                label="Email Address"
                type="email"
                autoComplete="email"
                value={email}
                onChange={(e) => setEmail(e.target.value)}
                required
              />
              <button type="submit" disabled={busy || cooldown.left > 0} className={authPrimaryButton}>
                {busy ? <Loader2 className="w-5 h-5 animate-spin" aria-label="Sending" /> : cooldown.left > 0 ? `Resend in ${cooldown.left}s` : 'Resend confirmation email'}
              </button>
            </form>
          </>
        )}

        {stage !== 'working' && (
          <div className="flex flex-wrap gap-x-6 gap-y-3 pt-2">
            <button type="button" onClick={() => openAuth('code', email)} className={authLinkButton}>Sign in with a code</button>
            <button type="button" onClick={() => openAuth('email-login', email)} className={authLinkButton}>Sign in with password</button>
            <Link to="/" className={authLinkButton}>Back to events</Link>
          </div>
        )}
      </section>
    </div>
  );
}
