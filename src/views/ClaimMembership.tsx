// /membership/claim?token=… — claim a gifted membership (docs/memberships.md).
// Signed in; the term starts the day it's claimed.

import { useState } from 'react';
import { BadgeCheck } from 'lucide-react';
import { claimMembershipGift } from '../lib/commerce';
import { useAuth } from '../context/AuthContext';
import { publicUrl } from '../lib/utils';

export default function ClaimMembership() {
  const { user, signIn } = useAuth() as { user: unknown; signIn?: () => Promise<void> };
  const token = new URLSearchParams(window.location.search).get('token') ?? '';
  const [state, setState] = useState<'idle' | 'busy' | 'done'>('idle');
  const [err, setErr] = useState<string | null>(null);

  const claim = async () => {
    setState('busy'); setErr(null);
    try { await claimMembershipGift(token); setState('done'); }
    catch (x: any) { setErr(x?.message || 'Could not claim this gift.'); setState('idle'); }
  };

  return (
    <div className="max-w-md mx-auto px-4 py-16 text-center space-y-4">
      <h1 className="text-2xl font-black flex items-center justify-center gap-2"><BadgeCheck className="w-6 h-6" /> Your gift membership</h1>
      {!/^[0-9a-f]{64}$/.test(token) ? <p>This link isn't complete. Open it again from the email.</p>
        : state === 'done' ? (
          <p>It's yours. <a className="underline" href={publicUrl('me/memberships')}>See your membership</a>.</p>
        ) : !user ? (
          <button className="bg-brand-primary text-black px-4 py-2 font-black" onClick={() => signIn?.()}>Sign in to claim</button>
        ) : (
          <button disabled={state === 'busy'} className="bg-brand-primary text-black px-4 py-2 font-black disabled:opacity-40" onClick={claim}>Claim it</button>
        )}
      {err && <p role="alert" className="text-red-600">{err}</p>}
    </div>
  );
}
