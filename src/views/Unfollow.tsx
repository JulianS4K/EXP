// /unfollow?t=<token> — the unfollow link in "new event from <org>" mail (mig
// 20261111110000). Works signed out: the token names the follower and the
// org. One click, not on page load, because mail scanners open links before
// the reader does. Only that org is unfollowed; /unsubscribe stops every
// follow-up email.

import { useEffect, useState } from 'react';
import { Link } from 'react-router-dom';
import { applyMeta } from '../lib/meta';
import { unfollowByToken, unfollowToken } from '../lib/followers';

export default function Unfollow() {
  const [token] = useState(() => {
    try { return unfollowToken(new URLSearchParams(window.location.search).get('t')); } catch { return null; }
  });
  const [state, setState] = useState<'idle' | 'busy' | 'done' | 'error'>('idle');
  const [orgName, setOrgName] = useState<string | null>(null);

  useEffect(() => {
    try { applyMeta({ title: 'Unfollow', description: 'Stop following an organizer on Exos.', noindex: true }); } catch { /* non-fatal */ }
  }, []);

  const unfollow = async () => {
    if (!token) return;
    setState('busy');
    try {
      const r = await unfollowByToken(token);
      setOrgName(r.orgName);
      setState(r.ok ? 'done' : 'error');
    } catch (e) {
      console.error('Unfollow failed:', e);
      setState('error');
    }
  };

  return (
    <div className="wall min-h-[70vh] flex flex-col items-center justify-center px-6 text-center">
      {!token ? (
        <h1 className="disp text-3xl md:text-4xl tracking-tight mb-4">This unfollow link isn't valid.</h1>
      ) : state === 'done' ? (
        <>
          <h1 className="disp text-3xl md:text-4xl tracking-tight mb-4">
            {orgName ? `You've unfollowed ${orgName}.` : "You've unfollowed them."}
          </h1>
          <p className="text-sm text-white/60 mb-6">No more new-event emails from them. Your tickets aren't affected.</p>
        </>
      ) : (
        <>
          <h1 className="disp text-3xl md:text-4xl tracking-tight mb-4">Stop following this organizer?</h1>
          <p className="text-sm text-white/60 mb-6">You'll stop getting emails about their new events. You can follow them again from their page.</p>
          <button
            type="button"
            onClick={unfollow}
            disabled={state === 'busy'}
            className="px-6 py-3 rounded-full bg-brand-primary text-black text-xs font-black uppercase tracking-widest disabled:opacity-50"
          >
            {state === 'busy' ? 'Unfollowing…' : 'Unfollow'}
          </button>
          {state === 'error' && (
            <p className="text-xs text-rose-400 mt-4" role="alert">That didn't work. The link may be old; try the one in your latest email.</p>
          )}
        </>
      )}
      <p className="text-xs text-white/60 mt-6">
        To stop every follow-up email from Exos, use the unsubscribe link at the bottom of the email.
      </p>
      <Link to="/" className="type text-[11px] uppercase tracking-widest text-brand-primary hover:underline mt-8">Browse events</Link>
    </div>
  );
}
