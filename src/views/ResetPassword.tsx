// /reset-password — where the "reset your password" email lands
// (resetPasswordForEmail redirectTo, built by authUrl('/reset-password')).
//
// The link signs the person in with a short-lived recovery session: supabase-js
// reads #access_token…&type=recovery (implicit flow, our default) or ?code=
// (PKCE) and fires PASSWORD_RECOVERY; ?token_hash= links are verified here.
// With that session they choose a new password (same rules as sign-up) and
// go back to where they started. A dead link (expired, already used, opened
// twice by a mail scanner) gets a "send a new link" form instead.

import { useEffect, useId, useState, type FormEvent } from 'react';
import { Link, useNavigate } from 'react-router-dom';
import { Loader2 } from 'lucide-react';
import { supabase } from '../lib/supabase';
import { useAuth } from '../context/AuthContext';
import { useToast } from '../context/ToastContext';
import { applyMeta } from '../lib/meta';
import { authUrl, authUrlParams, takeReturnPath } from '../lib/authUrls';
import { arrivalUrl, hasAuthParams, scrubAuthParams, settleAuthRedirect } from '../lib/authRedirect';
import { checkPassword, cleanEmail, isValidEmail, mapAuthError } from '../lib/authRules';
import { useCooldown, RESEND_COOLDOWN_S } from '../hooks/useCooldown';
import { AuthField, AuthNotices, PasswordRules, authLinkButton, authPrimaryButton } from '../components/AuthFields';
import { RESET_SENT_MESSAGE } from '../components/AuthModal';

type Stage = 'checking' | 'form' | 'invalid' | 'no-link';

export default function ResetPassword() {
  const { user, passwordRecovery, endPasswordRecovery } = useAuth();
  const { toast } = useToast();
  const navigate = useNavigate();
  const [stage, setStage] = useState<Stage>('checking');
  const [linkError, setLinkError] = useState('');
  const [password, setPassword] = useState('');
  const [confirm, setConfirm] = useState('');
  const [email, setEmail] = useState('');
  const [error, setError] = useState('');
  const [info, setInfo] = useState('');
  const [busy, setBusy] = useState(false);
  const cooldown = useCooldown();
  const headingId = useId();
  const errorId = `${headingId}-error`;

  useEffect(() => {
    try { applyMeta({ title: 'Reset password', description: 'Choose a new password.' }); } catch { /* non-fatal */ }
  }, []);

  useEffect(() => {
    let cancelled = false;
    const href = arrivalUrl();
    const fromLink = hasAuthParams(authUrlParams(href));
    void settleAuthRedirect(href).then((out) => {
      if (cancelled) return;
      scrubAuthParams();
      if (out.status === 'error') {
        setLinkError(out.error.message);
        setStage('invalid');
      } else if (out.status === 'session' && (fromLink || out.type === 'recovery')) {
        setStage('form');
      } else {
        // Signed in without a recovery link, or no session at all: only
        // passwordRecovery (checked below) can still open the form.
        setStage('no-link');
      }
    });
    return () => {
      cancelled = true;
    };
  }, []);

  // PASSWORD_RECOVERY can arrive after the check above (the context sets it).
  useEffect(() => {
    if (passwordRecovery && user && stage === 'no-link') setStage('form');
  }, [passwordRecovery, user, stage]);

  const save = async (e: FormEvent) => {
    e.preventDefault();
    setError('');
    const check = checkPassword(password, { email: user?.email ?? undefined });
    if (!check.ok) return setError(check.problems.join(' '));
    if (password !== confirm) return setError("The two passwords don't match.");
    setBusy(true);
    const { error: err } = await supabase.auth.updateUser({ password });
    setBusy(false);
    if (err) {
      const mapped = mapAuthError(err);
      if (mapped.kind === 'session_missing') {
        setLinkError('This reset link has expired. Ask for a new one below.');
        setStage('invalid');
        return;
      }
      return setError(mapped.message);
    }
    endPasswordRecovery();
    toast({ kind: 'success', message: "Password updated. You're signed in." });
    navigate(takeReturnPath(), { replace: true });
  };

  const sendNewLink = async (e: FormEvent) => {
    e.preventDefault();
    setError('');
    setInfo('');
    if (!isValidEmail(email)) return setError('Enter a valid email address.');
    if (cooldown.left > 0) return;
    setBusy(true);
    const { error: err } = await supabase.auth.resetPasswordForEmail(cleanEmail(email), { redirectTo: authUrl('/reset-password') });
    setBusy(false);
    if (err && mapAuthError(err).kind === 'network') return setError(mapAuthError(err).message);
    setInfo(RESET_SENT_MESSAGE);
    cooldown.start(RESEND_COOLDOWN_S);
  };

  return (
    <div className="wall min-h-[70vh] flex items-center justify-center px-4 py-16">
      <section aria-labelledby={headingId} className="w-full max-w-md bg-[#0e0e0e] border border-white/10 p-8">
        <h1 id={headingId} tabIndex={-1} className="disp text-3xl uppercase tracking-tight leading-none mb-6" style={{ transform: 'skewX(-4deg)' }}>
          {stage === 'form' ? 'Choose a new password' : 'Reset password'}
        </h1>

        {stage === 'checking' && (
          <p role="status" className="type text-[12px] uppercase tracking-widest text-white/60 flex items-center gap-3">
            <Loader2 className="w-4 h-4 animate-spin" aria-hidden="true" /> Checking your link…
          </p>
        )}

        {stage === 'form' && (
          <form onSubmit={save} className="space-y-4" noValidate>
            <AuthNotices error={error} errorId={errorId} />
            {user?.email && (
              <p className="type text-[12px] text-white/60">For <strong className="text-white">{user.email}</strong></p>
            )}
            {/* Lets password managers file the new password under the right account. */}
            <input type="email" autoComplete="username" value={user?.email ?? ''} readOnly hidden />
            <AuthField
              label="New password"
              type="password"
              autoComplete="new-password"
              value={password}
              onChange={(e) => setPassword(e.target.value)}
              required
              autoFocus
              invalid={!!error}
              errorId={errorId}
              hint={<PasswordRules password={password} email={user?.email ?? undefined} />}
            />
            <AuthField
              label="Confirm new password"
              type="password"
              autoComplete="new-password"
              value={confirm}
              onChange={(e) => setConfirm(e.target.value)}
              required
              invalid={!!confirm && confirm !== password}
            />
            <button type="submit" disabled={busy} className={authPrimaryButton}>
              {busy ? <Loader2 className="w-5 h-5 animate-spin" aria-label="Saving" /> : 'Save password'}
            </button>
          </form>
        )}

        {(stage === 'invalid' || stage === 'no-link') && (
          <div className="space-y-4">
            <AuthNotices error={stage === 'invalid' ? linkError : error} info={info} errorId={errorId} />
            {stage === 'no-link' && user ? (
              <p className="type text-[12px] text-white/70 leading-relaxed">
                You're signed in. Change your password from{' '}
                <Link to="/profile#account" className="text-brand-primary underline">your account settings</Link>.
              </p>
            ) : (
              <form onSubmit={sendNewLink} className="space-y-4" noValidate>
                {stage === 'no-link' && (
                  <p className="type text-[12px] text-white/70 leading-relaxed">
                    Open the link from your reset email again, or send yourself a new one.
                  </p>
                )}
                {stage === 'invalid' && error && <p role="alert" className="type text-[12px] text-brand-accent">{error}</p>}
                <AuthField
                  label="Email Address"
                  type="email"
                  autoComplete="email"
                  value={email}
                  onChange={(e) => setEmail(e.target.value)}
                  required
                  autoFocus
                />
                <button type="submit" disabled={busy || cooldown.left > 0} className={authPrimaryButton}>
                  {busy ? <Loader2 className="w-5 h-5 animate-spin" aria-label="Sending" /> : cooldown.left > 0 ? `Send again in ${cooldown.left}s` : 'Send a new link'}
                </button>
              </form>
            )}
            <Link to="/" className={`${authLinkButton} inline-block`}>Back to events</Link>
          </div>
        )}
      </section>
    </div>
  );
}
