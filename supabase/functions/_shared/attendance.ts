// How people attend an event (mig 20261005090000: exos_events.format), as
// schema.org wants it. One source for the SPA's JSON-LD (src/lib/meta.ts),
// the crawler previews (src/lib/hosting/seo.ts) and the Google events feed,
// so they can't disagree. The virtual location is always the public event
// page, never the private join link.

export type AttendanceFormat = 'in_person' | 'online' | 'hybrid';

export function parseAttendanceFormat(v: unknown): AttendanceFormat {
  return v === 'online' || v === 'hybrid' ? v : 'in_person';
}

export function attendanceModeUrl(f: AttendanceFormat): string {
  if (f === 'online') return 'https://schema.org/OnlineEventAttendanceMode';
  if (f === 'hybrid') return 'https://schema.org/MixedEventAttendanceMode';
  return 'https://schema.org/OfflineEventAttendanceMode';
}

/** schema.org `location`: the Place, a VirtualLocation, or both (hybrid). */
export function schemaLocation(
  f: AttendanceFormat,
  place: Record<string, unknown> | null,
  pageUrl: string,
): Record<string, unknown> | Array<Record<string, unknown>> | undefined {
  const virtual = { '@type': 'VirtualLocation', url: pageUrl };
  if (f === 'online') return virtual;
  if (f === 'hybrid') return place ? [place, virtual] : virtual;
  return place ?? undefined;
}
