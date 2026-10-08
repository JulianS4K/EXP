// Online / hybrid events, "what to bring" and per-event noindex
// (mig 20261005090000). Pure draft model shared by CreateEvent and
// EditEvent; the RPC wrappers live in onlineEventsApi.ts.

export type EventFormat = 'in_person' | 'online' | 'hybrid';

export const EVENT_FORMATS: Array<{ id: EventFormat; label: string; hint: string }> = [
  { id: 'in_person', label: 'In person', hint: 'At a venue' },
  { id: 'online', label: 'Online', hint: 'A stream or video call' },
  { id: 'hybrid', label: 'Hybrid', hint: 'At a venue and online' },
];

export const WHAT_TO_BRING_MAX = 500;
export const JOIN_URL_MAX = 1000;
export const JOIN_NOTE_MAX = 500;

// "Show the join link to ticket holders ..." (minutes before the start).
// '' = as soon as they have a ticket.
export const REVEAL_OPTIONS: Array<{ id: string; label: string }> = [
  { id: '', label: 'As soon as they have a ticket' },
  { id: '1440', label: '1 day before' },
  { id: '120', label: '2 hours before' },
  { id: '60', label: '1 hour before' },
  { id: '15', label: '15 minutes before' },
  { id: '0', label: 'At the start time' },
];

export function parseEventFormat(v: unknown): EventFormat {
  return v === 'online' || v === 'hybrid' ? v : 'in_person';
}

export function formatLabel(f: EventFormat | undefined): string | null {
  if (f === 'online') return 'Online';
  if (f === 'hybrid') return 'In person + online';
  return null;
}

export const isOnline = (f: EventFormat | undefined): boolean => f === 'online' || f === 'hybrid';

// Only https links: the same rule the database enforces.
export function isJoinUrl(s: string): boolean {
  const t = s.trim();
  return t.length > 0 && t.length <= JOIN_URL_MAX && /^https:\/\/[^\s"<>]+$/.test(t);
}

export interface OnlineDraft {
  format: EventFormat;
  whatToBring: string;
  noindex: boolean;
  joinUrl: string;
  joinNote: string;
  reveal: string; // one of REVEAL_OPTIONS ids
}

export function blankOnline(): OnlineDraft {
  return { format: 'in_person', whatToBring: '', noindex: false, joinUrl: '', joinNote: '', reveal: '' };
}

export function onlineFromEvent(
  ev: { format?: EventFormat; whatToBring?: string; noindex?: boolean },
  link?: { joinUrl: string; joinNote: string | null; revealMinutes: number | null } | null,
): OnlineDraft {
  return {
    format: ev.format ?? 'in_person',
    whatToBring: ev.whatToBring ?? '',
    noindex: ev.noindex ?? false,
    joinUrl: link?.joinUrl ?? '',
    joinNote: link?.joinNote ?? '',
    reveal: link?.revealMinutes == null ? '' : String(link.revealMinutes),
  };
}

/** A draft restored from localStorage (older drafts have none). */
export function coerceOnlineDraft(raw: unknown): OnlineDraft {
  const r = (raw && typeof raw === 'object' ? raw : {}) as Record<string, unknown>;
  const str = (v: unknown) => (typeof v === 'string' ? v : '');
  const reveal = str(r.reveal);
  return {
    format: parseEventFormat(r.format),
    whatToBring: str(r.whatToBring),
    noindex: r.noindex === true,
    joinUrl: str(r.joinUrl),
    joinNote: str(r.joinNote),
    reveal: REVEAL_OPTIONS.some((o) => o.id === reveal) ? reveal : '',
  };
}

/** First problem with the draft, or null. */
export function validateOnline(d: OnlineDraft): string | null {
  if (d.whatToBring.length > WHAT_TO_BRING_MAX) return `"What to bring" is limited to ${WHAT_TO_BRING_MAX} characters.`;
  if (isOnline(d.format) && d.joinUrl.trim() && !isJoinUrl(d.joinUrl)) {
    return 'The join link must start with https://';
  }
  if (d.joinNote.length > JOIN_NOTE_MAX) return `The join note is limited to ${JOIN_NOTE_MAX} characters.`;
  return null;
}

/** Event-row columns (the join link is saved separately, see joinLinkFor). */
export function onlineToInput(d: OnlineDraft): { format: EventFormat; whatToBring: string | null; noindex: boolean } {
  return { format: d.format, whatToBring: d.whatToBring.trim() || null, noindex: d.noindex };
}

/**
 * What to send to exos_set_event_online, or null to leave the saved link
 * alone: an in-person event keeps it (the access RPC hands nothing out for
 * in-person events), so switching back to online restores it.
 */
export function joinLinkFor(d: OnlineDraft): { url: string; note: string | null; revealMinutes: number | null } | null {
  if (!isOnline(d.format)) return null;
  const n = d.reveal === '' ? null : Number(d.reveal);
  return {
    url: d.joinUrl.trim(),
    note: d.joinNote.trim() || null,
    revealMinutes: n !== null && Number.isFinite(n) ? n : null,
  };
}

/** Whether a venue is still required by the event form. */
export const needsVenue = (f: EventFormat): boolean => f !== 'online';
