// /unsubscribe?t=<token> — the link at the bottom of "finish your order"
// reminder mail (mig 20260926060000). Works signed out: the token alone
// identifies the account. It takes a click rather than firing on page load,
// because mail scanners open links before the reader does. Only reminders are
// turned off; tickets, transfers and event changes still arrive.

import { useEffect, useState } from 'react';
import { Link } from 'react-router-dom';
import { supabase } from '../lib/supabase';
import { applyMeta } from '../lib/meta';

const TOKEN_RE = /^[0-9a-f]{64}$/;

export default function MailUnsubscribe() {
  const [token] = useState(() => {
    try { return new URLSearchParams(window.location.search).get('t') ?? ''; } catch { return ''; }
  });
  const [state, setState] = useState<'idle' | 'busy' | 'done' | 'error'>('idle');

  useEffect(() => {
    try { applyMeta({ title: 'Unsubscribe', description: 'Stop reminder emails.' }); } catch { /* non-fatal */ }
  }, []);

  const valid = TOKEN_RE.test(token);

  const unsubscribe = async () => {
    setState('busy');
    try {
      const { data, error } = await supabase.rpc('exos_mail_unsubscribe', { p_token: token });
      setState(!error && data === true ? 'done' : 'error');
    } catch (e) {
      console.error('Unsubscribe failed:', e);
      setState('error');
    }
  };

  return (
    <div className="wall min-h-[70vh] flex flex-col items-center justify-center px-6 text-center">
      {!valid ? (
        <p className="disp text-3xl md:text-4xl tracking-tight mb-4">This unsubscribe link isn't valid.</p>
      ) : state === 'done' ? (
        <>
          <p className="disp text-3xl md:text-4xl tracking-tight mb-4">You're unsubscribed.</p>
          <p className="text-sm text-white/60 mb-6">No more reminder emails. You'll still get your tickets and updates about events you're going to.</p>
        </>
      ) : (
        <>
          <p className="disp text-3xl md:text-4xl tracking-tight mb-4">Stop reminder emails?</p>
          <p className="text-sm text-white/60 mb-6">We'll stop emailing you about orders you didn't finish. Tickets and event updates still arrive.</p>
          <button
            type="button"
            onClick={unsubscribe}
            disabled={state === 'busy'}
            className="px-6 py-3 rounded-full bg-brand-primary text-white text-xs font-black uppercase tracking-widest disabled:opacity-50"
          >
            {state === 'busy' ? 'Unsubscribing…' : 'Unsubscribe'}
          </button>
          {state === 'error' && (
            <p className="text-xs text-rose-400 mt-4">That didn't work. The link may be old; try the one in your latest email.</p>
          )}
        </>
      )}
      <Link to="/" className="type text-[11px] uppercase tracking-widest text-brand-primary hover:underline mt-8">Browse events</Link>
    </div>
  );
}
