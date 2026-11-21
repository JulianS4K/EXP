// Print placements (mig 20261121153700, docs/organizer-guide.md "Posters and
// flyers"): the spots an event's posters and flyers go ("Poster - Bedford
// Ave", "Flyer - Bar X"). Each gets its own QR code: the event's short link
// (/e/<slug>) tagged utm_source=qr, utm_medium=print, utm_content=<placement
// slug> (the scheme in _shared/marketing/utm.ts). Checkouts keep the tags, so
// the Sources report's "Placement / ad" breakdown shows what each spot sold,
// and the channel report counts them all under "Flyer / QR code".
//
// Pure: the RPC calls are in ./printPlacementsApi.ts.

import { tagUrl } from '../../supabase/functions/_shared/marketing/utm.ts';

export interface PrintPlacement {
  id: string;
  event_id: string;
  name: string;
  slug: string;
  created_at: string;
}

export const PRINT_SOURCE = 'qr';
export const PRINT_MEDIUM = 'print' as const;
export const PLACEMENT_NAME_MAX = 80;

/** A name as a slug, exactly as _exos_print_placement_slug makes it (before the -2, -3 for a clash). */
export function placementSlug(name: string): string {
  return name.toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-+|-+$/g, '').slice(0, 60).replace(/^-+|-+$/g, '');
}

/** The placement's tracked link: the event's short link with the print tags. */
export function placementUrl(eventUrl: string, slug: string): string {
  return tagUrl(eventUrl, { source: PRINT_SOURCE, medium: PRINT_MEDIUM, content: slug });
}

export interface SheetItem {
  id: string;
  name: string;
  slug: string;
  url: string;
}

/** The printable sheet: one labelled QR per placement, in the order they were added. */
export function placementSheet(eventUrl: string, placements: readonly PrintPlacement[]): SheetItem[] {
  return [...placements]
    .sort((a, b) => a.created_at.localeCompare(b.created_at) || a.slug.localeCompare(b.slug))
    .map((p) => ({ id: p.id, name: p.name, slug: p.slug, url: placementUrl(eventUrl, p.slug) }));
}

/** A name the RPC will take, or why not. */
export function placementNameError(name: string): string | null {
  const t = name.trim().replace(/\s+/g, ' ');
  if (!t) return 'Name the spot, e.g. Poster - Bedford Ave.';
  if (t.length > PLACEMENT_NAME_MAX) return `Up to ${PLACEMENT_NAME_MAX} characters.`;
  if (!placementSlug(t)) return 'The name needs a letter or a number.';
  return null;
}
