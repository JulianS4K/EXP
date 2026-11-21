// Partiful kit (operator 2026-11-21, "Also partiful"; docs/organizer-guide.md
// "Discovery listings"). Partiful has no public API and its terms bar
// scraping and bots, so Exos never sends to or reads from it: the organizer
// makes the invite page on their own account from this kit and points guests
// to Exos checkout. Pure.
//
// The ticket link follows the Exos UTM scheme (_shared/marketing/utm.ts):
// utm_source=partiful, utm_medium=referral (a page on another site sending
// guests on, like partner sites), utm_campaign=discovery. The channel report
// counts it as "Partiful" (_exos_channel_key / _exos_channel_label, mig
// 20261121153700), and the Sources report shows partiful / referral.

import { submissionCopy, type CopyEventRow, type CopyTierRow } from '../../../supabase/functions/_shared/discovery/copy.ts';
import { eventPageUrl } from '../../../supabase/functions/_shared/googleEvents/feed.ts';
import { tagUrl } from '../../../supabase/functions/_shared/marketing/utm.ts';

export const PARTIFUL_CHANNEL = 'partiful';

export interface PartifulKitField { key: string; label: string; value: string }

export interface PartifulKit {
  title: string;
  ticketLink: string;
  image: string | null;
  fields: PartifulKitField[];
  /** Everything as one block, for pasting into Partiful's description. */
  text: string;
}

/** The Exos ticket link for a Partiful page. */
export function partifulTicketLink(appBase: string, e: Pick<CopyEventRow, 'id' | 'slug'>): string {
  return tagUrl(eventPageUrl(appBase, e), { source: PARTIFUL_CHANNEL, medium: 'referral', campaign: 'discovery' });
}

export function partifulKit(e: CopyEventRow, tiers: readonly CopyTierRow[], appBase: string, now: Date = new Date()): PartifulKit {
  const c = submissionCopy(e, tiers, PARTIFUL_CHANNEL, appBase, now);
  const ticketLink = partifulTicketLink(appBase, e);
  const where = [c.venue, c.address].filter(Boolean).join(', ');
  const description = [c.description, `Tickets${c.price ? ` (${c.price} all-in)` : ''}: ${ticketLink}`].filter(Boolean).join('\n\n');
  const fields: PartifulKitField[] = ([
    ['title', 'Title', c.title],
    ['when', 'Date and time', c.when],
    ['where', 'Venue', where],
    ['description', 'Description', description],
    ['ticketLink', 'Ticket link', ticketLink],
    ['image', 'Cover image URL', c.image ?? ''],
  ] as const).filter(([, , v]) => v !== '').map(([key, label, value]) => ({ key, label, value }));
  const text = [c.title, c.when, where, '', description].filter((l, i, a) => l !== '' || (i > 0 && a[i - 1] !== '')).join('\n').trim();
  return { title: c.title, ticketLink, image: c.image, fields, text };
}
