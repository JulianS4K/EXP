// schema.org EventSeries JSON-LD for a public collection page (each event a
// subEvent with its start, end, place and offer). Pure; collectionLd.test.ts.

import type { PublicCollection } from './seriesTimedApi';

export function collectionJsonLd(c: PublicCollection, origin: string): Record<string, unknown> {
  return {
    '@context': 'https://schema.org',
    '@type': 'EventSeries',
    name: c.name,
    ...(c.description ? { description: c.description } : {}),
    ...(c.image_url ? { image: c.image_url } : {}),
    url: `${origin}/c/${encodeURIComponent(c.org.slug)}/${encodeURIComponent(c.slug)}`,
    organizer: { '@type': 'Organization', name: c.org.name },
    subEvent: c.events.map((e) => ({
      '@type': 'Event',
      name: e.name,
      startDate: e.starts_at,
      ...(e.ends_at ? { endDate: e.ends_at } : {}),
      eventStatus: 'https://schema.org/EventScheduled',
      url: `${origin}/event/${e.id}`,
      ...(e.image_url ? { image: e.image_url } : {}),
      ...(e.venue_name ? { location: { '@type': 'Place', name: e.venue_name, ...(e.venue_location ? { address: e.venue_location } : {}) } } : {}),
      ...(e.from_price != null ? {
        offers: {
          '@type': 'Offer', price: Number(e.from_price), priceCurrency: (e.currency || 'USD').toUpperCase(),
          availability: e.sold_out ? 'https://schema.org/SoldOut' : 'https://schema.org/InStock',
          url: `${origin}/event/${e.id}`,
        },
      } : {}),
    })),
  };
}
