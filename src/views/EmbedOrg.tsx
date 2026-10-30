// /embed/org/:slug: an organizer's upcoming events for any website (event list
// or month-by-month calendar), loaded by public/embed.js from
// <div data-exos-org="slug" data-exos-layout="list|calendar">. "Tickets" opens
// the event's own embed in the same frame, so checkout stays on the venue's page.

import { useEffect, useRef, useState } from 'react';
import { Link, useLocation, useParams } from 'react-router-dom';
import { Event, Organization } from '../types';
import { getPublicOrgBySlug } from '../lib/orgs';
import { listPublicEventsForOrg } from '../lib/events';
import { ThemeProvider } from '../context/ThemeContext';
import { formatInTz } from '../lib/datetime';
import { publicUrl } from '../lib/utils';
import { useEmbedHost, useEmbedResize } from '../hooks/useEmbedResize';
import { upcomingForEmbed, groupByMonth } from '../lib/embedWidgets';
import { getPublicLineups, lineupLine, type LineupSlot } from '../lib/artists';

export default function EmbedOrg() {
  const { slug } = useParams();
  const { search } = useLocation();
  const layout = new URLSearchParams(search).get('layout') === 'calendar' ? 'calendar' : 'list';
  const host = useEmbedHost();
  const root = useRef<HTMLDivElement>(null);
  useEmbedResize(host, root);
  const [org, setOrg] = useState<Organization | null>(null);
  const [events, setEvents] = useState<Event[] | null>(null);
  const [failed, setFailed] = useState(false);
  // Lineups (mig 20261030110000): one read for the whole list; names only.
  const [lineups, setLineups] = useState<Record<string, LineupSlot[]>>({});

  useEffect(() => {
    let alive = true;
    (async () => {
      try {
        const o = slug ? await getPublicOrgBySlug(slug) : null;
        if (!o) throw new Error('not found');
        const list = await listPublicEventsForOrg(o.id);
        const upcoming = upcomingForEmbed(list);
        if (alive) { setOrg(o); setEvents(upcoming); }
        const l = await getPublicLineups(upcoming.map((e) => e.id));
        if (alive) setLineups(l);
      } catch {
        if (alive) setFailed(true);
      }
    })();
    return () => { alive = false; };
  }, [slug]);

  const row = (e: Event) => (
    <li key={e.id} className="flex items-center gap-3 border-b border-white/10 py-3">
      <div className="min-w-0 flex-1">
        <p className="disp text-lg leading-tight text-white truncate">{e.title}</p>
        <p className="type text-[11px] text-white/60">
          {e.date ? formatInTz(e.date.toDate(), e.timezone, { weekday: 'short', month: 'short', day: 'numeric', hour: 'numeric', minute: '2-digit' }) : ''}
          {e.location ? ` · ${e.location}` : ''}
        </p>
        {(lineups[e.id]?.length || e.performers?.length) ? (
          <p data-testid="embed-org-lineup" className="type text-[11px] text-white/80 truncate">
            {lineups[e.id]?.length ? lineupLine(lineups[e.id]) : (e.performers ?? []).slice(0, 4).join(', ')}
          </p>
        ) : null}
      </div>
      {e.ticketBackend && e.ticketBackend !== 'exos' && e.externalTicketUrl ? (
        <a href={e.externalTicketUrl} target="_blank" rel="noopener noreferrer"
          className="disp shrink-0 bg-brand-primary text-black px-4 py-2 text-sm tracking-wide">Tickets</a>
      ) : (
        <Link to={`/embed/event/${e.id}${search}`} className="disp shrink-0 bg-brand-primary text-black px-4 py-2 text-sm tracking-wide">Tickets</Link>
      )}
    </li>
  );

  return (
    <div ref={root}>
      {failed ? (
        <div className="bg-black text-white/40 p-8 text-center type text-xs uppercase tracking-widest">Events unavailable.</div>
      ) : !events ? (
        <div className="bg-black text-white/40 p-8 text-center type text-[11px] uppercase tracking-[0.3em] animate-pulse">Loading…</div>
      ) : (
        <ThemeProvider org={org}>
          <div className="bg-black text-white p-4">
            {events.length === 0 && <p className="type text-xs text-white/50">No upcoming events.</p>}
            {layout === 'calendar' ? (
              groupByMonth(events).map((g) => (
                <section key={g.key} className="mb-4">
                  <h3 className="type text-[11px] uppercase tracking-widest text-brand-primary mb-1">{g.label}</h3>
                  <ul>{g.events.map(row)}</ul>
                </section>
              ))
            ) : (
              <ul>{events.map(row)}</ul>
            )}
            {org?.slug && (
              <a href={publicUrl(`o/${org.slug}`)}
                target="_blank" rel="noopener noreferrer" className="type block mt-3 text-[10px] uppercase tracking-widest text-white/40 hover:text-white">
                All {org.name} events ↗
              </a>
            )}
          </div>
        </ThemeProvider>
      )}
    </div>
  );
}
