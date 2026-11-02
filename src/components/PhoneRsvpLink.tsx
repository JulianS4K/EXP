// PhoneRsvpLink — "RSVP with your phone" on the event page when the organizer
// turned phone RSVP on (mig 20261102150000). Asks exos-rsvp only for events
// with a free ticket type; renders nothing otherwise. Carries ?promoter=.

import { useEffect, useState } from 'react';
import { Link, useSearchParams } from 'react-router-dom';
import { Smartphone } from 'lucide-react';
import { rsvpInfo } from '../lib/phoneRsvp';

export default function PhoneRsvpLink({ eventId, hasFreeTier }: { eventId: string; hasFreeTier: boolean }) {
  const [open, setOpen] = useState(false);
  const [params] = useSearchParams();
  useEffect(() => {
    if (!hasFreeTier) return undefined;
    let live = true;
    rsvpInfo(eventId).then((i) => { if (live) setOpen(!!i.ok); }).catch(() => {});
    return () => { live = false; };
  }, [eventId, hasFreeTier]);
  if (!open) return null;
  const promoter = params.get('promoter');
  const to = `/rsvp/${eventId}${promoter && /^[A-Za-z0-9_-]{1,64}$/.test(promoter) ? `?promoter=${encodeURIComponent(promoter)}` : ''}`;
  return (
    <Link to={to} className="mt-3 inline-flex items-center gap-2 border border-white/30 px-4 py-2 text-[11px] uppercase tracking-widest text-white hover:border-brand-primary hover:text-brand-primary">
      <Smartphone className="w-3 h-3" /> RSVP with your phone, no account
    </Link>
  );
}
