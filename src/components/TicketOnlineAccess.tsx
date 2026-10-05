// On the holder's ticket (mig 20261005090000): the private join link for an
// online / hybrid event, from exos_event_online_access (holders and staff
// only; the link is never on the event row), plus the organizer's "what to
// bring". Renders nothing when there's neither.

import { useEffect, useState } from 'react';
import { ExternalLink, Video } from 'lucide-react';
import { getOnlineAccess, type OnlineAccess } from '../lib/onlineEventsApi';
import { isOnline, type EventFormat } from '../lib/onlineEvents';

function when(ms: number): string {
  return new Date(ms).toLocaleString(undefined, {
    weekday: 'short', month: 'short', day: 'numeric', hour: 'numeric', minute: '2-digit',
  });
}

export default function TicketOnlineAccess({
  eventId, format, whatToBring,
}: { eventId: string; format?: EventFormat; whatToBring?: string }) {
  const online = isOnline(format);
  const [access, setAccess] = useState<OnlineAccess | null>(null);

  useEffect(() => {
    if (!online) return undefined;
    let alive = true;
    setAccess(null);
    getOnlineAccess(eventId)
      .then((a) => { if (alive) setAccess(a); })
      .catch(() => { if (alive) setAccess(null); });
    return () => { alive = false; };
  }, [eventId, online]);

  // When the link is held back, fetch again once it's due (tab left open).
  useEffect(() => {
    if (access?.state !== 'later' || !access.availableAt) return undefined;
    const wait = access.availableAt - Date.now() + 2000;
    if (wait > 24 * 3600 * 1000) return undefined;
    const t = setTimeout(() => {
      getOnlineAccess(eventId).then(setAccess).catch(() => undefined);
    }, Math.max(wait, 1000));
    return () => clearTimeout(t);
  }, [access, eventId]);

  const bring = whatToBring?.trim();
  const showJoin = online && access && access.state !== 'none' && access.state !== 'not_holder';
  if (!bring && !showJoin) return null;

  return (
    <section className="border border-white/10 bg-white/[0.03] p-5 mb-10 space-y-4" aria-label="Joining and what to bring">
      {showJoin && access && (
        <div>
          <h3 className="type text-[11px] uppercase tracking-widest text-white/70 flex items-center gap-2">
            <Video className="w-4 h-4 text-brand-primary" aria-hidden="true" /> Join online
          </h3>
          {access.state === 'ready' && access.joinUrl && (
            <>
              <a
                href={access.joinUrl}
                target="_blank"
                rel="noopener noreferrer nofollow"
                className="disp mt-3 inline-flex items-center gap-2 bg-brand-primary text-black px-6 py-2.5 text-base tracking-wide"
              >
                Join the event <ExternalLink className="w-4 h-4" aria-hidden="true" />
              </a>
              <p className="type text-[11px] text-white/40 mt-2">Just for you. Please don't share this link.</p>
            </>
          )}
          {access.state === 'later' && (
            <p className="type text-sm text-white/70 mt-2">
              The join link appears here {access.availableAt ? `on ${when(access.availableAt)}` : 'before the start'}.
            </p>
          )}
          {access.state === 'cancelled' && (
            <p className="type text-sm text-white/70 mt-2">This event was cancelled.</p>
          )}
          {access.joinNote && access.state !== 'cancelled' && (
            <p className="type text-sm text-white/70 mt-2 whitespace-pre-line">{access.joinNote}</p>
          )}
        </div>
      )}
      {bring && (
        <div>
          <h3 className="type text-[11px] uppercase tracking-widest text-white/70">What to bring</h3>
          <p className="type text-sm text-white/80 mt-1 whitespace-pre-line">{bring}</p>
        </div>
      )}
    </section>
  );
}
