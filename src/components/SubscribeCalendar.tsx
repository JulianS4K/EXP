// SubscribeCalendar — "subscribe to this calendar" for an organizer or venue
// feed (supabase/functions/exos-calendar; docs/calendar.md). Unlike "add to
// calendar", a subscription keeps updating: new dates appear, changes and
// cancellations follow. Renders nothing when the feed base isn't configured.

import { useState } from 'react';
import { CalendarPlus, Copy, ExternalLink, Check } from 'lucide-react';
import type { FeedLinks } from '../lib/calendar';

interface Props {
  links: FeedLinks | null;
  label?: string;
  className?: string;
  /** Accent colour for the icon (storefronts pass the org colour). */
  accent?: string;
}

export default function SubscribeCalendar({ links, label = 'Subscribe to calendar', className, accent }: Props) {
  const [open, setOpen] = useState(false);
  const [copied, setCopied] = useState(false);
  if (!links) return null;

  const copy = async () => {
    try {
      await navigator.clipboard.writeText(links.https);
      setCopied(true);
      setTimeout(() => setCopied(false), 2000);
    } catch {
      /* clipboard blocked: the URL is shown below to copy by hand */
    }
  };

  const row = 'flex items-center text-white/50 hover:text-brand-primary transition-colors text-left';
  return (
    <div className={className}>
      <button
        type="button"
        onClick={() => setOpen((o) => !o)}
        aria-expanded={open}
        className="flex items-center hover:text-brand-primary transition-colors text-left type text-[11px] uppercase tracking-widest text-white/60"
      >
        <CalendarPlus className={`w-4 h-4 mr-3 ${accent ? '' : 'text-brand-primary'}`} style={accent ? { color: accent } : undefined} />
        {label}
      </button>
      {open && (
        <div className="mt-3 ml-7 flex flex-col space-y-3 type text-[11px] uppercase tracking-widest">
          <a href={links.webcal} className={row}>
            <ExternalLink className="w-3.5 h-3.5 mr-3" />
            Apple Calendar / Outlook
          </a>
          <a href={links.google} target="_blank" rel="noopener noreferrer" className={row}>
            <ExternalLink className="w-3.5 h-3.5 mr-3" />
            Google Calendar
          </a>
          <button type="button" onClick={copy} className={row}>
            {copied ? <Check className="w-3.5 h-3.5 mr-3" /> : <Copy className="w-3.5 h-3.5 mr-3" />}
            {copied ? 'Copied' : 'Copy calendar link'}
          </button>
          <p className="normal-case tracking-normal text-[11px] text-white/35 leading-relaxed max-w-xs">
            Google Calendar: Other calendars → + → From URL, then paste the link. Outlook: Add calendar →
            Subscribe from web. Your calendar app checks for changes every few hours.
          </p>
          <code className="normal-case tracking-normal text-[10px] text-white/30 break-all select-all">{links.https}</code>
        </div>
      )}
    </div>
  );
}
