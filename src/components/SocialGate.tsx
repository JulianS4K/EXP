// The paused social features' pages (operator 2026-11-17, mig 20261117190000):
// a plain "not available" page unless the build sets VITE_EXOS_SOCIAL=on. The
// view inside is never rendered (or even loaded: it's lazy) while off.

import type { ReactNode } from 'react';
import { Link } from 'react-router-dom';
import { SOCIAL_OFF_TITLE, socialEnabled, type SocialFeature } from '../lib/socialFlag';

const BODY: Record<SocialFeature, string> = {
  split: 'Splitting an order with friends isn\'t offered right now. You can still send any ticket to a friend from My Tickets.',
  matched: 'Matched seats aren\'t offered right now.',
  chat: 'Group chats aren\'t offered right now. Your tickets are in My Tickets.',
};

export function SocialUnavailable({ feature }: { feature: SocialFeature }) {
  return (
    <div className="max-w-xl mx-auto px-4 py-10" data-testid="social-unavailable">
      <h1 className="disp text-3xl tracking-tight text-white mb-4">{SOCIAL_OFF_TITLE[feature]}</h1>
      <p className="type text-white/80 mb-6">{BODY[feature]}</p>
      <p className="flex flex-wrap gap-6">
        <Link to="/my-tickets" className="type text-sm text-white underline">My Tickets</Link>
        <Link to="/" className="type text-sm text-white underline">Browse events</Link>
      </p>
    </div>
  );
}

export default function SocialGate({ feature, children }: { feature: SocialFeature; children: ReactNode }) {
  return socialEnabled() ? <>{children}</> : <SocialUnavailable feature={feature} />;
}
