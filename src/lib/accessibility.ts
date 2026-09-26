// Accessible ticket options (mig 20260926090000) — PURE: the fixed
// vocabularies the database checks (_exos_access_needs_ok /
// _exos_accessibility_ok), their labels, and normalizers. Keep the value
// lists in step with the migration. RPC wrappers: ./accessibilityApi.

/** What a ticket holder or guest needs at the door. Categories only, no free
 *  text: this is disability data and we keep as little as serves the guest. */
export const ACCESS_NEEDS = [
  { id: 'wheelchair', label: 'Wheelchair space', short: 'Wheelchair' },
  { id: 'companion', label: 'Companion seat next to me', short: 'Companion' },
  { id: 'step_free', label: 'Step-free route (no stairs)', short: 'Step-free' },
  { id: 'seat', label: 'A seat (I can’t stand for long)', short: 'Seat' },
  { id: 'asl', label: 'Sign language (ASL) interpreter', short: 'ASL' },
  { id: 'hearing', label: 'Hearing support (captions, loop)', short: 'Hearing' },
  { id: 'vision', label: 'Low vision / blind support', short: 'Vision' },
  { id: 'service_animal', label: 'Coming with a service animal', short: 'Service animal' },
] as const;
export type AccessNeed = (typeof ACCESS_NEEDS)[number]['id'];

/** What the venue offers, shown on the event page. */
export const ACCESS_FEATURES = [
  { id: 'step_free', label: 'Step-free entry' },
  { id: 'wheelchair_spaces', label: 'Wheelchair spaces' },
  { id: 'seating', label: 'Seating available' },
  { id: 'accessible_restrooms', label: 'Accessible restrooms' },
  { id: 'accessible_parking', label: 'Accessible parking / drop-off' },
  { id: 'asl', label: 'ASL interpretation' },
  { id: 'captions', label: 'Captions' },
  { id: 'hearing_loop', label: 'Hearing loop' },
  { id: 'quiet_space', label: 'Quiet space' },
  { id: 'service_animals', label: 'Service animals welcome' },
] as const;
export type AccessFeature = (typeof ACCESS_FEATURES)[number]['id'];

export interface EventAccessibility {
  features?: AccessFeature[];
  notes?: string;
  contact?: string;
}

export const ACCESS_NOTES_MAX = 500;
export const ACCESS_CONTACT_MAX = 200;
export const ACCESSIBLE_NOTE_MAX = 140;

const NEED_IDS = new Set<string>(ACCESS_NEEDS.map((n) => n.id));
const FEATURE_IDS = new Set<string>(ACCESS_FEATURES.map((f) => f.id));

/** Known needs only, deduped and sorted (the order the server returns). */
export function normalizeNeeds(input: unknown): AccessNeed[] {
  if (!Array.isArray(input)) return [];
  return Array.from(new Set(input.filter((n): n is AccessNeed => typeof n === 'string' && NEED_IDS.has(n)))).sort();
}

export const needLabel = (id: string): string => ACCESS_NEEDS.find((n) => n.id === id)?.label ?? id;
export const needShort = (id: string): string => ACCESS_NEEDS.find((n) => n.id === id)?.short ?? id;
export const featureLabel = (id: string): string => ACCESS_FEATURES.find((f) => f.id === id)?.label ?? id;

/** Read an event's access info off a row, dropping anything unknown. */
export function parseAccessibility(raw: unknown): EventAccessibility {
  if (!raw || typeof raw !== 'object' || Array.isArray(raw)) return {};
  const r = raw as Record<string, unknown>;
  const out: EventAccessibility = {};
  if (Array.isArray(r.features)) {
    const f = Array.from(new Set(r.features.filter((x): x is AccessFeature => typeof x === 'string' && FEATURE_IDS.has(x))));
    if (f.length) out.features = f;
  }
  if (typeof r.notes === 'string' && r.notes.trim()) out.notes = r.notes.trim().slice(0, ACCESS_NOTES_MAX);
  if (typeof r.contact === 'string' && r.contact.trim()) out.contact = r.contact.trim().slice(0, ACCESS_CONTACT_MAX);
  return out;
}

/** The value to store: only set keys, trimmed and capped (passes the DB check). */
export function serializeAccessibility(a: EventAccessibility): EventAccessibility {
  return parseAccessibility(a);
}

export const hasAccessInfo = (a: EventAccessibility | undefined): boolean =>
  !!a && ((a.features?.length ?? 0) > 0 || !!a.notes || !!a.contact);

/** A contact that looks like an email becomes a mailto link; else plain text. */
export function contactHref(contact: string): string | null {
  const c = contact.trim();
  if (/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(c)) return `mailto:${c}`;
  if (/^\+?[0-9 ().-]{7,}$/.test(c)) return `tel:${c.replace(/[^0-9+]/g, '')}`;
  return null;
}
