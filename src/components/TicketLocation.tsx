// On the holder's ticket (mig 20261105130000, docs/promoter-events.md): where
// a secret-location or TBA event happens. Before the reveal it says when the
// address comes; after it, the place, the address, directions and a
// directions link. The address comes from exos_event_location (signed in) or
// exos_ticket_link_location (the live link's key), never from the event row.
// Renders nothing for an event at a venue (the ticket already shows it).

import { useEffect, useState } from 'react';
import { Lock, MapPin } from 'lucide-react';
import { holderLocation, isPromoterMode, parseLocationMode, type HolderLocation, type LocationMode } from '../lib/eventLocation';
import { getEventLocation, getTicketLinkLocation } from '../lib/eventLocationApi';

function when(iso: string, tz?: string | null): string {
  try {
    return new Date(iso).toLocaleString(undefined, {
      weekday: 'short', month: 'short', day: 'numeric', hour: 'numeric', minute: '2-digit', timeZone: tz || undefined,
    });
  } catch {
    return new Date(iso).toLocaleString();
  }
}

export default function TicketLocation({ eventId, ticketId, linkKey, mode, timezone, dark = true }: {
  eventId?: string;
  /** With linkKey: a live ticket link (no account). */
  ticketId?: string;
  linkKey?: string | null;
  /** The event's mode when known (skips the call for venue events). */
  mode?: LocationMode;
  timezone?: string | null;
  dark?: boolean;
}) {
  const [loc, setLoc] = useState<HolderLocation | null>(null);
  useEffect(() => {
    if (mode !== undefined && !isPromoterMode(mode)) return undefined;
    let alive = true;
    const load = ticketId && linkKey ? getTicketLinkLocation(ticketId, linkKey) : eventId ? getEventLocation(eventId) : Promise.resolve(null);
    load.then((v) => {
      if (!alive || !v) return;
      const m = parseLocationMode(v.location_mode);
      setLoc(m === 'secret_location' || m === 'tba' || m === 'unlisted_venue' ? holderLocation(v, (iso) => when(iso, timezone)) : null);
    }).catch(() => { if (alive) setLoc(null); });
    return () => { alive = false; };
  }, [eventId, ticketId, linkKey, mode, timezone]);
  if (!loc || loc.mode === 'unlisted_venue') return null;
  const box = dark ? 'border border-white/15 bg-black/40 text-white' : 'border border-slate-200 bg-white text-slate-900';
  const sub = dark ? 'text-white/60' : 'text-slate-500';
  const maps = loc.revealed && loc.detail
    ? `https://www.google.com/maps/search/?api=1&query=${encodeURIComponent(`${loc.title === 'The location' ? '' : `${loc.title}, `}${loc.detail}`)}`
    : null;
  return (
    <section aria-label="Location" className={`${box} p-5 space-y-1`}>
      <p className={`flex items-center gap-2 type text-[11px] uppercase tracking-widest ${sub}`}>
        {loc.revealed ? <MapPin className="w-3.5 h-3.5" aria-hidden="true" /> : <Lock className="w-3.5 h-3.5" aria-hidden="true" />}
        {loc.revealed ? 'The location' : loc.mode === 'tba' ? 'Location to be announced' : 'Secret location'}
      </p>
      {loc.revealed && <p className="font-bold text-lg">{loc.title}</p>}
      {loc.detail && <p className="text-sm">{loc.detail}</p>}
      {loc.directions && <p className={`text-sm ${sub}`}>{loc.directions}</p>}
      {loc.note && <p className={`text-xs ${sub}`}>{loc.note}</p>}
      {maps && <a href={maps} target="_blank" rel="noopener noreferrer" className="inline-block text-xs underline mt-1">Directions</a>}
    </section>
  );
}
