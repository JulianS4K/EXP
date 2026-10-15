// Pure helpers for the website widgets (public/embed.js, /embed/org/:slug).
import type { Event } from '../types';

const ms = (e: Event): number => {
  const d = e.date as unknown as { toMillis?: () => number } | null;
  return d?.toMillis ? d.toMillis() : 0;
};

/** Upcoming (started under 6 hours ago is still "on"), soonest first, at most 50. */
export function upcomingForEmbed(events: Event[], now = Date.now()): Event[] {
  return events
    .filter((e) => ms(e) > now - 6 * 3600_000 && (e as { status?: string }).status !== 'cancelled')
    .sort((a, b) => ms(a) - ms(b))
    .slice(0, 50);
}

export function groupByMonth(events: Event[]): { key: string; label: string; events: Event[] }[] {
  const out: { key: string; label: string; events: Event[] }[] = [];
  for (const e of events) {
    const d = new Date(ms(e));
    const tz = e.timezone || undefined;
    let key: string;
    let label: string;
    try {
      key = d.toLocaleDateString('en-CA', { year: 'numeric', month: '2-digit', timeZone: tz });
      label = d.toLocaleDateString('en-US', { month: 'long', year: 'numeric', timeZone: tz });
    } catch {
      key = d.toISOString().slice(0, 7);
      label = key;
    }
    const g = out.find((x) => x.key === key);
    if (g) g.events.push(e);
    else out.push({ key, label, events: [e] });
  }
  return out;
}

/** The three snippets an organizer pastes on their own site. */
export function widgetSnippets(loaderUrl: string, orgSlug: string, eventId?: string): { label: string; html: string }[] {
  const s = `<script src="${loaderUrl}" async></script>`;
  const out = [
    { label: 'Event list', html: `<div data-exos-org="${orgSlug}"></div>\n${s}` },
    { label: 'Calendar', html: `<div data-exos-org="${orgSlug}" data-exos-layout="calendar"></div>\n${s}` },
  ];
  if (eventId) {
    out.push({ label: 'Buy button', html: `<a data-exos-button="${eventId}" data-exos-label="Get tickets"></a>\n${s}` });
    out.push({ label: 'Ticket box (checkout on your page)', html: `<div data-exos-event="${eventId}"></div>\n${s}` });
  }
  return out;
}

/** A safe CSS colour for the buy button (#rgb / #rrggbb), else null. */
export function buttonColor(raw: string | null | undefined): string | null {
  return raw && /^#([0-9a-fA-F]{3}|[0-9a-fA-F]{6})$/.test(raw) ? raw : null;
}
