// Profile → "Account & security": change email, set / change password,
// sign out here, sign out everywhere.
//
// Password changes work with the project's "Secure password change" setting
// on or off: when Supabase answers reauthentication_needed we call
// reauthenticate() (emails a code) and retry updateUser with that nonce.
// Email changes need a click on the link sent to the new address (and, with
// "Secure email change" on, the old one too) before they take effect.

import { useState, type FormEvent } from 'react';
import { useNavigate } from 'react-router-dom';
import { Loader2 } from 'lucide-react';
import { supabase } from '../lib/supabase';
import { useAuth } from '../context/AuthContext';
import { useToast } from '../context/ToastContext';
import { callbackUrl } from '../lib/authUrls';
import { checkPassword, cleanEmail, isValidEmail, mapAuthError } from '../lib/authRules';
import { useCooldown, RESEND_COOLDOWN_S } from '../hooks/useCooldown';
import { AuthField, AuthNotices, PasswordRules, authLinkButton } from './AuthFields';

const sectionTitle = 'disp text-xl tracking-tight uppercase mb-4';
const smallButton =
  'px-4 py-3 bg-brand-primary text-black disp text-lg uppercase tracking-wide hover:bg-white transition-colors disabled:opacity-50 inline-flex items-center justify-center min-w-[9rem]';
const ghostButton =
  'px-4 py-3 border border-white/20 type text-[11px] uppercase tracking-widest text-white/80 hover:border-brand-primary hover:text-brand-primary transition-colors disabled:opacity-50';

function Spinner({ label }: { label: string }) {
  return <Loader2 className="w-5 h-5 animate-spin" aria-label={label} />;
}

function ChangeEmail({ current }: { current: string }) {
  const [email, setEmail] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');
  const [info, setInfo] = useState('');

  const submit = async (e: FormEvent) => {
    e.preventDefault();
    setError('');
    setInfo('');
    if (!isValidEmail(email)) return setError('Enter a valid email address.');
    const next = cleanEmail(email);
    if (next === current.toLowerCase()) return setError("That's already your email.");
    setBusy(true);
    const { error: err } = await supabase.auth.updateUser({ email: next }, { emailRedirectTo: callbackUrl('/profile') });
    setBusy(false);
    if (err) {
      const mapped = mapAuthError(err);
      return setError(mapped.kind === 'email_taken' ? "That address can't be used for this account." : mapped.message);
    }
    setInfo(`Almost done. Open the confirmation link we sent to ${next}, and the one sent to ${current} if you get one. Your email changes once it's confirmed.`);
    setEmail('');
  };

  return (
    <form onSubmit={submit} className="space-y-4" noValidate aria-labelledby="acct-email-title">
      <h3 id="acct-email-title" className={sectionTitle}>Email</h3>
      <p className="type text-[12px] text-white/60">Signed in as <strong className="text-white">{current}</strong></p>
      <AuthNotices error={error} info={info} />
      <AuthField label="New email address" type="email" autoComplete="email" value={email} onChange={(e) => setEmail(e.target.value)} required />
      <button type="submit" disabled={busy} className={smallButton}>{busy ? <Spinner label="Saving" /> : 'Change email'}</button>
    </form>
  );
}

function ChangePassword({ email }: { email: string }) {
  const { toast } = useToast();
  const [password, setPassword] = useState('');
  const [confirm, setConfirm] = useState('');
  const [nonce, setNonce] = useState('');
  const [needNonce, setNeedNonce] = useState(false);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');
  const [info, setInfo] = useState('');
  const cooldown = useCooldown();

  const sendNonce = async () => {
    const { error: err } = await supabase.auth.reauthenticate();
    if (err) {
      const mapped = mapAuthError(err);
      if (mapped.kind === 'rate_limited') cooldown.start(mapped.retryAfter ?? RESEND_COOLDOWN_S);
      setError(mapped.message);
      return false;
    }
    cooldown.start(RESEND_COOLDOWN_S);
    setInfo(`For security, we emailed a code to ${email}. Enter it below to save your new password.`);
    return true;
  };

  const submit = async (e: FormEvent) => {
    e.preventDefault();
    setError('');
    setInfo('');
    const check = checkPassword(password, { email });
    if (!check.ok) return setError(check.problems.join(' '));
    if (password !== confirm) return setError("The two passwords don't match.");
    const code = nonce.replace(/\s/g, '');
    if (needNonce && !/^\d{6,10}$/.test(code)) return setError('Enter the code from the email.');
    setBusy(true);
    const { error: err } = await supabase.auth.updateUser(needNonce ? { password, nonce: code } : { password });
    if (err) {
      const mapped = mapAuthError(err);
      if (mapped.kind === 'reauth_needed') {
        // Secure password change is on and this session isn't recent enough.
        const sent = await sendNonce();
        setNeedNonce(sent);
        setBusy(false);
        return;
      }
      setBusy(false);
      return setError(mapped.message);
    }
    setBusy(false);
    setPassword('');
    setConfirm('');
    setNonce('');
    setNeedNonce(false);
    toast({ kind: 'success', message: 'Password saved.' });
  };

  return (
    <form onSubmit={submit} className="space-y-4" noValidate aria-labelledby="acct-pw-title">
      <h3 id="acct-pw-title" className={sectionTitle}>Password</h3>
      <p className="type text-[12px] text-white/60">
        Signed up with Google, Apple, Microsoft or an email code? Set a password here to sign in with it too.
      </p>
      <AuthNotices error={error} info={info} />
      {/* Lets password managers file the new password under this account. */}
      <input type="email" autoComplete="username" value={email} readOnly hidden />
      <AuthField
        label="New password"
        type="password"
        autoComplete="new-password"
        value={password}
        onChange={(e) => setPassword(e.target.value)}
        required
        hint={<PasswordRules password={password} email={email} />}
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
      {needNonce && (
        <AuthField
          label="Verification code"
          type="text"
          inputMode="numeric"
          autoComplete="one-time-code"
          pattern="[0-9]*"
          maxLength={10}
          value={nonce}
          onChange={(e) => setNonce(e.target.value.replace(/[^\d]/g, ''))}
          required
          autoFocus
          className="tracking-[0.4em]"
        />
      )}
      <div className="flex flex-wrap items-center gap-4">
        <button type="submit" disabled={busy} className={smallButton}>{busy ? <Spinner label="Saving" /> : 'Save password'}</button>
        {needNonce && (
          <button type="button" onClick={() => void sendNonce()} disabled={cooldown.left > 0} className={authLinkButton}>
            {cooldown.left > 0 ? `Send a new code (${cooldown.left}s)` : 'Send a new code'}
          </button>
        )}
      </div>
    </form>
  );
}

function Sessions() {
  const { logout, logoutEverywhere } = useAuth();
  const { toast } = useToast();
  const navigate = useNavigate();
  const [confirming, setConfirming] = useState(false);
  const [busy, setBusy] = useState(false);

  const here = async () => {
    setBusy(true);
    await logout();
    navigate('/');
  };

  const everywhere = async () => {
    setBusy(true);
    const ok = await logoutEverywhere();
    toast(
      ok
        ? { kind: 'success', message: 'Signed out on all your devices.' }
        : { kind: 'error', message: "Signed out here, but we couldn't reach your other devices. Try again after signing in." },
    );
    navigate('/');
  };

  return (
    <div className="space-y-4" aria-labelledby="acct-sessions-title" role="group">
      <h3 id="acct-sessions-title" className={sectionTitle}>Sessions</h3>
      <p className="type text-[12px] text-white/60">
        Lost a phone or used a shared computer? Signing out everywhere ends every session, including this one.
      </p>
      <div className="flex flex-wrap gap-3">
        <button type="button" onClick={here} disabled={busy} className={ghostButton}>Sign out</button>
        {!confirming ? (
          <button type="button" onClick={() => setConfirming(true)} disabled={busy} className={ghostButton}>Sign out of all devices</button>
        ) : (
          <>
            <button type="button" onClick={everywhere} disabled={busy} autoFocus className="px-4 py-3 bg-brand-accent text-black type text-[11px] uppercase tracking-widest disabled:opacity-50">
              {busy ? 'Signing out…' : 'Yes, sign out everywhere'}
            </button>
            <button type="button" onClick={() => setConfirming(false)} disabled={busy} className={ghostButton}>Cancel</button>
          </>
        )}
      </div>
    </div>
  );
}

export default function AccountSecurityPanel() {
  const { user } = useAuth();
  if (!user) return null;
  const email = user.email ?? '';
  return (
    <section id="account" aria-labelledby="acct-title" className="bg-[#111] border border-white/10 p-8 space-y-10 scroll-mt-24">
      <h2 id="acct-title" className="disp text-2xl md:text-3xl tracking-tight uppercase" style={{ transform: 'skewX(-4deg)' }}>
        Account &amp; Security
      </h2>
      {email && <ChangeEmail current={email} />}
      <div className="border-t border-white/10 pt-8">
        <ChangePassword email={email} />
      </div>
      <div className="border-t border-white/10 pt-8">
        <Sessions />
      </div>
    </section>
  );
}
