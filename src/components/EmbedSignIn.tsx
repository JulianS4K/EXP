// Sign-in inside the venue-site iframe (/embed/event/:id). No popups and no
// redirects: OAuth providers refuse to render in a frame, and a magic link
// opens a new tab whose storage the (partitioned) iframe can't see. So the
// fan types their email, gets a one-time code by email, and types it here.
// supabase-js keeps the session in the iframe's own storage (in memory when
// the browser blocks third-party storage), which is enough for one checkout.
// Existing password accounts can use their password instead.
//
// Operator: the Supabase "Magic Link" and "Confirm signup" email templates
// must include {{ .Token }} for the code to reach the fan.

import { useState, type FormEvent } from 'react';
import { supabase } from '../lib/supabase';

type Mode = 'email' | 'code' | 'password';

export default function EmbedSignIn({ accent, onCancel }: { accent: string; onCancel: () => void }) {
  const [mode, setMode] = useState<Mode>('email');
  const [email, setEmail] = useState('');
  const [code, setCode] = useState('');
  const [password, setPassword] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');

  const cleanEmail = email.trim().toLowerCase();

  const sendCode = async (e?: FormEvent) => {
    e?.preventDefault();
    if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(cleanEmail)) {
      setError('Enter a valid email.');
      return;
    }
    setBusy(true);
    setError('');
    const { error: err } = await supabase.auth.signInWithOtp({
      email: cleanEmail,
      options: { shouldCreateUser: true },
    });
    setBusy(false);
    if (err) {
      setError(err.message || 'Could not send the code.');
      return;
    }
    setMode('code');
  };

  const verify = async (e: FormEvent) => {
    e.preventDefault();
    const token = code.replace(/\s/g, '');
    if (!/^\d{6,10}$/.test(token)) {
      setError('Enter the code from the email.');
      return;
    }
    setBusy(true);
    setError('');
    const { error: err } = await supabase.auth.verifyOtp({ email: cleanEmail, token, type: 'email' });
    setBusy(false);
    // Success: AuthContext picks up SIGNED_IN and the parent moves on.
    if (err) setError(err.message || 'That code did not work.');
  };

  const withPassword = async (e: FormEvent) => {
    e.preventDefault();
    setBusy(true);
    setError('');
    const { error: err } = await supabase.auth.signInWithPassword({ email: cleanEmail, password });
    setBusy(false);
    if (err) setError(err.message || 'Sign-in failed.');
  };

  const input = 'w-full bg-black border border-white/15 px-3 py-2.5 text-sm text-white placeholder-white/30 focus:outline-none focus:border-white/50';
  const button = 'disp block w-full py-3 text-lg tracking-wide text-center disabled:opacity-50';
  const link = 'type text-[10px] uppercase tracking-widest text-white/40 hover:text-white/70';

  return (
    <div className="space-y-3">
      <p className="type text-[11px] uppercase tracking-widest text-white/60">
        {mode === 'code' ? `Code sent to ${cleanEmail}` : 'Your email, for your tickets'}
      </p>

      {mode === 'email' && (
        <form onSubmit={sendCode} className="space-y-3">
          <input
            type="email" autoComplete="email" required value={email}
            onChange={(e) => setEmail(e.target.value)} placeholder="you@example.com" className={input}
          />
          <button type="submit" disabled={busy} className={button} style={{ background: accent, color: '#000' }}>
            {busy ? 'SENDING…' : 'EMAIL ME A CODE'}
          </button>
          <button type="button" onClick={() => { setError(''); setMode('password'); }} className={link}>
            Have a password? Sign in with it
          </button>
        </form>
      )}

      {mode === 'code' && (
        <form onSubmit={verify} className="space-y-3">
          <input
            inputMode="numeric" autoComplete="one-time-code" required value={code}
            onChange={(e) => setCode(e.target.value)} placeholder="123456" className={`${input} tracking-[0.4em]`}
          />
          <button type="submit" disabled={busy} className={button} style={{ background: accent, color: '#000' }}>
            {busy ? 'CHECKING…' : 'CONTINUE'}
          </button>
          <div className="flex justify-between">
            <button type="button" onClick={() => sendCode()} disabled={busy} className={link}>Send again</button>
            <button type="button" onClick={() => { setCode(''); setError(''); setMode('email'); }} className={link}>Change email</button>
          </div>
        </form>
      )}

      {mode === 'password' && (
        <form onSubmit={withPassword} className="space-y-3">
          <input
            type="email" autoComplete="email" required value={email}
            onChange={(e) => setEmail(e.target.value)} placeholder="you@example.com" className={input}
          />
          <input
            type="password" autoComplete="current-password" required value={password}
            onChange={(e) => setPassword(e.target.value)} placeholder="Password" className={input}
          />
          <button type="submit" disabled={busy} className={button} style={{ background: accent, color: '#000' }}>
            {busy ? 'SIGNING IN…' : 'SIGN IN'}
          </button>
          <button type="button" onClick={() => { setError(''); setMode('email'); }} className={link}>
            Use an email code instead
          </button>
        </form>
      )}

      {error && <p className="text-xs text-red-400" role="alert">{error}</p>}
      <button type="button" onClick={onCancel} className={link}>← Back</button>
    </div>
  );
}
