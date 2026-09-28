// MyCalendarFeed — the signed-in fan's personal calendar feed: events from the
// organizers they follow plus the events they hold tickets for, as one
// subscribable calendar (docs/calendar.md). The link holds a secret token, so
// it's shown once when made; after that it can be replaced or turned off.

import { useEffect, useState } from 'react';
import { CalendarPlus } from 'lucide-react';
import { calendarFeedBase, myFeedLinks, type FeedLinks } from '../lib/calendar';
import { createMyFeedToken, myFeedStatus, revokeMyFeedToken } from '../lib/calendarFeedApi';
import SubscribeCalendar from './SubscribeCalendar';

export default function MyCalendarFeed({ className }: { className?: string }) {
  const [active, setActive] = useState<boolean | null>(null);
  const [links, setLinks] = useState<FeedLinks | null>(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    let cancelled = false;
    myFeedStatus()
      .then((s) => { if (!cancelled) setActive(s.active); })
      .catch(() => { if (!cancelled) setActive(false); });
    return () => { cancelled = true; };
  }, []);

  if (!calendarFeedBase()) return null;

  const make = async () => {
    if (active && !window.confirm('Make a new link? The old one stops working in every calendar that uses it.')) return;
    setBusy(true);
    setError(null);
    try {
      const token = await createMyFeedToken();
      setLinks(myFeedLinks(token));
      setActive(true);
    } catch {
      setError('Could not make a calendar link. Try again in a moment.');
    } finally {
      setBusy(false);
    }
  };

  const turnOff = async () => {
    if (!window.confirm('Turn off your calendar link? Calendars subscribed to it stop updating.')) return;
    setBusy(true);
    setError(null);
    try {
      await revokeMyFeedToken();
      setActive(false);
      setLinks(null);
    } catch {
      setError('Could not turn the link off. Try again in a moment.');
    } finally {
      setBusy(false);
    }
  };

  const btn = 'type text-[11px] uppercase tracking-widest text-white/60 hover:text-brand-primary transition-colors disabled:opacity-40';
  return (
    <section className={`border border-white/10 bg-white/5 p-5 ${className ?? ''}`} aria-labelledby="my-calendar-feed">
      <h2 id="my-calendar-feed" className="type text-[12px] text-brand-primary uppercase tracking-widest mb-2 flex items-center gap-3">
        <CalendarPlus className="w-4 h-4" /> my calendar feed
      </h2>
      <p className="type text-[12px] text-white/50 leading-relaxed mb-4 max-w-xl">
        One calendar with your tickets and every event from organizers you follow. It stays up to date in Google,
        Apple or Outlook Calendar. The link is private: anyone who has it can see these events.
      </p>
      {links ? (
        <SubscribeCalendar links={links} label="Add it to your calendar" className="mb-4" />
      ) : active ? (
        <p className="type text-[11px] text-white/40 mb-4">Your link is on. For security it is only shown when it's made; make a new one to see it again.</p>
      ) : null}
      <div className="flex flex-wrap gap-6">
        <button type="button" onClick={make} disabled={busy || active === null} className={btn}>
          {active ? 'make a new link' : 'get my calendar link'}
        </button>
        {active && (
          <button type="button" onClick={turnOff} disabled={busy} className={btn}>turn off</button>
        )}
      </div>
      {error && <p role="alert" className="type text-[11px] text-red-400 mt-3">{error}</p>}
    </section>
  );
}
