// Store page content (mig 20260929120000) — PURE: the vocabularies and limits
// the database checks (_exos_store_content_ok and the column CHECKs), their
// labels, row parsers, and the form draft ↔ EventInput mapping shared by
// CreateEvent and EditEvent (src/components/StoreContentEditor.tsx). Keep the
// value lists in step with the migration.

import { mdToPlain, DESCRIPTION_MD_MAX, DESCRIPTION_PLAIN_MAX } from './richText';

export const SUMMARY_MAX = 160;
export { DESCRIPTION_MD_MAX };
export const LINEUP_MAX = 20;
export const LINEUP_NAME_MAX = 120;
export const LINEUP_BIO_MAX = 500;
export const FAQ_MAX = 20;
export const FAQ_Q_MAX = 200;
export const FAQ_A_MAX = 1000;
export const GALLERY_MAX = 12;
export const GALLERY_ALT_MAX = 200;
export const POLICY_NOTES_MAX = 1000;

export const LINEUP_ROLES = [
  { id: 'headliner', label: 'Headliner' },
  { id: 'support', label: 'Support' },
  { id: 'dj', label: 'DJ' },
  { id: 'host', label: 'Host' },
  { id: 'other', label: 'Other' },
] as const;
export type LineupRole = (typeof LINEUP_ROLES)[number]['id'];

export const MIN_AGES = [
  { id: 0, label: 'All ages' },
  { id: 16, label: '16+' },
  { id: 18, label: '18+' },
  { id: 21, label: '21+' },
] as const;
export type MinAge = (typeof MIN_AGES)[number]['id'];

export const REFUND_POLICIES = [
  { id: 'none', label: 'No refunds', text: 'All sales are final. No refunds.' },
  { id: 'until_7d', label: 'Up to 7 days before', text: 'Refunds available up to 7 days before the event.' },
  { id: 'until_24h', label: 'Up to 24 hours before', text: 'Refunds available up to 24 hours before the event.' },
  { id: 'until_start', label: 'Until the event starts', text: 'Refunds available until the event starts.' },
  { id: 'custom', label: 'Custom (describe in notes)', text: '' },
] as const;
export type RefundPolicy = (typeof REFUND_POLICIES)[number]['id'];

export interface LineupEntry {
  name: string;
  role: LineupRole;
  setAt?: string; // 'HH:MM', venue local time
  bio?: string;
}
export interface FaqEntry { q: string; a: string }
export interface GalleryImage { url: string; alt?: string }

const ROLE_IDS = new Set<string>(LINEUP_ROLES.map((r) => r.id));
const POLICY_IDS = new Set<string>(REFUND_POLICIES.map((p) => p.id));
const AGE_IDS = new Set<number>(MIN_AGES.map((a) => a.id));
const SET_AT_RE = /^([01]\d|2[0-3]):[0-5]\d$/;
// Same pattern as exos_events_video_url_chk.
const VIDEO_RE = /^https:\/\/(www\.|m\.)?(youtube\.com|youtu\.be|vimeo\.com)\/[^\s"<>]*$/;
const GALLERY_URL_RE = /^https:\/\/[^\s"<>]+$/;

export const refundPolicyLabel = (id: string): string => REFUND_POLICIES.find((p) => p.id === id)?.label ?? id;
export const refundPolicyText = (id: string): string => REFUND_POLICIES.find((p) => p.id === id)?.text ?? '';
export const roleLabel = (id: string): string => LINEUP_ROLES.find((r) => r.id === id)?.label ?? id;
export const ageLabel = (age: number): string => (age > 0 ? `${age}+` : 'All ages');

const str = (v: unknown): string => (typeof v === 'string' ? v : '');

// --- Row parsers (lenient: unknown shapes drop out) ------------------------

export function parseLineup(raw: unknown): LineupEntry[] {
  if (!Array.isArray(raw)) return [];
  return raw
    .filter((e) => e && typeof e === 'object' && str(e.name).trim())
    .map((e) => ({
      name: str(e.name),
      role: (ROLE_IDS.has(e.role) ? e.role : 'other') as LineupRole,
      ...(str(e.set_at) ? { setAt: str(e.set_at) } : {}),
      ...(str(e.bio) ? { bio: str(e.bio) } : {}),
    }));
}

export function parseFaq(raw: unknown): FaqEntry[] {
  if (!Array.isArray(raw)) return [];
  return raw
    .filter((e) => e && typeof e === 'object' && str(e.q).trim() && str(e.a).trim())
    .map((e) => ({ q: str(e.q), a: str(e.a) }));
}

export function parseGallery(raw: unknown): GalleryImage[] {
  if (!Array.isArray(raw)) return [];
  return raw
    .filter((e) => e && typeof e === 'object' && GALLERY_URL_RE.test(str(e.url)))
    .map((e) => ({ url: str(e.url), ...(str(e.alt) ? { alt: str(e.alt) } : {}) }));
}

export function parseMinAge(raw: unknown): MinAge | null {
  const n = typeof raw === 'number' ? raw : typeof raw === 'string' && raw !== '' ? Number(raw) : NaN;
  return AGE_IDS.has(n) ? (n as MinAge) : null;
}

export function parseRefundPolicy(raw: unknown): RefundPolicy | null {
  return typeof raw === 'string' && POLICY_IDS.has(raw) ? (raw as RefundPolicy) : null;
}

export const isVideoUrl = (url: string): boolean => url.length <= 500 && VIDEO_RE.test(url);

/**
 * Privacy-enhanced embed URL for a YouTube or Vimeo link, or null. Only
 * youtube-nocookie.com and player.vimeo.com, which the CSP frame-src allows
 * on event pages (src/lib/hosting/headers.ts).
 */
export function videoEmbedUrl(url: string | null | undefined): string | null {
  if (!url || !isVideoUrl(url)) return null;
  let u: URL;
  try { u = new URL(url); } catch { return null; }
  const host = u.hostname.replace(/^(www|m)\./, '');
  const idOk = (id: string | null | undefined) => (id && /^[\w-]{6,20}$/.test(id) ? id : null);
  if (host === 'youtu.be') {
    const id = idOk(u.pathname.slice(1).split('/')[0]);
    return id ? `https://www.youtube-nocookie.com/embed/${id}` : null;
  }
  if (host === 'youtube.com') {
    const parts = u.pathname.split('/').filter(Boolean);
    const id = idOk(parts[0] === 'watch' ? u.searchParams.get('v')
      : ['embed', 'shorts', 'live', 'v'].includes(parts[0]) ? parts[1] : null);
    return id ? `https://www.youtube-nocookie.com/embed/${id}` : null;
  }
  if (host === 'vimeo.com') {
    const id = u.pathname.split('/').filter(Boolean).find((p) => /^\d{5,12}$/.test(p));
    return id ? `https://player.vimeo.com/video/${id}?dnt=1` : null;
  }
  return null;
}

// --- Form draft --------------------------------------------------------------

/** What the editor holds. Strings for selects so "not set" is ''. */
export interface StoreDraft {
  summary: string;
  descriptionMd: string;
  lineup: LineupEntry[];
  faq: FaqEntry[];
  gallery: GalleryImage[];
  videoUrl: string;
  minAge: '' | `${MinAge}`;
  refundPolicy: '' | RefundPolicy;
  policyNotes: string;
}

export const blankStore = (): StoreDraft => ({
  summary: '', descriptionMd: '', lineup: [], faq: [], gallery: [],
  videoUrl: '', minAge: '', refundPolicy: '', policyNotes: '',
});

/**
 * Draft from a loaded event. An event that predates the markdown field
 * starts its "About" from the plain description (plain text is valid
 * markdown), so the organizer edits one text, not two.
 */
export function storeFromEvent(ev: {
  description?: string; summary?: string; descriptionMd?: string; lineup?: LineupEntry[]; faq?: FaqEntry[];
  gallery?: GalleryImage[]; videoUrl?: string; minAge?: MinAge | null; refundPolicy?: RefundPolicy | null; policyNotes?: string;
}): StoreDraft {
  return {
    summary: ev.summary ?? '',
    descriptionMd: ev.descriptionMd || ev.description || '',
    lineup: (ev.lineup ?? []).map((e) => ({ ...e })),
    faq: (ev.faq ?? []).map((e) => ({ ...e })),
    gallery: (ev.gallery ?? []).map((e) => ({ ...e })),
    videoUrl: ev.videoUrl ?? '',
    minAge: ev.minAge == null ? '' : (String(ev.minAge) as StoreDraft['minAge']),
    refundPolicy: ev.refundPolicy ?? '',
    policyNotes: ev.policyNotes ?? '',
  };
}

/** A restored localStorage draft may be from an older build: fill the gaps. */
export function coerceStoreDraft(raw: unknown): StoreDraft {
  const r = (raw && typeof raw === 'object' ? raw : {}) as Record<string, unknown>;
  const age = parseMinAge(r.minAge);
  return {
    summary: str(r.summary),
    descriptionMd: str(r.descriptionMd),
    lineup: Array.isArray(r.lineup) ? (r.lineup as LineupEntry[]).filter((e) => e && typeof e === 'object') : [],
    faq: Array.isArray(r.faq) ? (r.faq as FaqEntry[]).filter((e) => e && typeof e === 'object') : [],
    gallery: Array.isArray(r.gallery) ? (r.gallery as GalleryImage[]).filter((e) => e && typeof e === 'object') : [],
    videoUrl: str(r.videoUrl),
    minAge: age == null ? '' : (String(age) as StoreDraft['minAge']),
    refundPolicy: parseRefundPolicy(r.refundPolicy) ?? '',
    policyNotes: str(r.policyNotes),
  };
}

/** Client-side check mirroring the database's; null when the draft saves. */
export function validateStore(d: StoreDraft): string | null {
  if (d.summary.trim().length > SUMMARY_MAX) return `Summary must be ${SUMMARY_MAX} characters or fewer.`;
  if (d.descriptionMd.length > DESCRIPTION_MD_MAX) return `About must be ${DESCRIPTION_MD_MAX} characters or fewer.`;
  const lineup = d.lineup.filter((e) => e.name.trim());
  if (lineup.length > LINEUP_MAX) return `List at most ${LINEUP_MAX} acts in the lineup.`;
  for (const e of lineup) {
    if (e.name.trim().length > LINEUP_NAME_MAX) return `Lineup names must be ${LINEUP_NAME_MAX} characters or fewer.`;
    if (e.setAt && !SET_AT_RE.test(e.setAt)) return `Set time for ${e.name.trim()} must look like 22:30.`;
    if ((e.bio ?? '').trim().length > LINEUP_BIO_MAX) return `Bio for ${e.name.trim()} must be ${LINEUP_BIO_MAX} characters or fewer.`;
  }
  const faq = d.faq.filter((e) => e.q.trim() || e.a.trim());
  if (faq.length > FAQ_MAX) return `Add at most ${FAQ_MAX} FAQ entries.`;
  for (const e of faq) {
    if (!e.q.trim() || !e.a.trim()) return 'Each FAQ entry needs a question and an answer.';
    if (e.q.trim().length > FAQ_Q_MAX) return `FAQ questions must be ${FAQ_Q_MAX} characters or fewer.`;
    if (e.a.trim().length > FAQ_A_MAX) return `FAQ answers must be ${FAQ_A_MAX} characters or fewer.`;
  }
  const gallery = d.gallery.filter((g) => g.url.trim());
  if (gallery.length > GALLERY_MAX) return `Add at most ${GALLERY_MAX} gallery images.`;
  for (const g of gallery) {
    if (!GALLERY_URL_RE.test(g.url.trim()) || g.url.trim().length > 2048) return 'Gallery images need an https:// link.';
    if ((g.alt ?? '').trim().length > GALLERY_ALT_MAX) return `Image descriptions must be ${GALLERY_ALT_MAX} characters or fewer.`;
  }
  if (d.videoUrl.trim() && !isVideoUrl(d.videoUrl.trim())) return 'Video must be a YouTube or Vimeo https:// link.';
  if (d.policyNotes.trim().length > POLICY_NOTES_MAX) return `Good-to-know notes must be ${POLICY_NOTES_MAX} characters or fewer.`;
  return null;
}

/**
 * The EventInput fields for a draft. Clears are explicit (null / []) because
 * updateEvent skips undefined. `description` is the plain fallback every
 * legacy reader uses, derived from the markdown.
 */
export function storeToInput(d: StoreDraft) {
  const md = d.descriptionMd.trim();
  return {
    description: md ? mdToPlain(md).slice(0, DESCRIPTION_PLAIN_MAX) : '',
    summary: d.summary.trim() || null,
    descriptionMd: md || null,
    lineup: d.lineup
      .filter((e) => e.name.trim())
      .map((e) => ({
        name: e.name.trim(),
        role: e.role,
        ...(e.setAt ? { set_at: e.setAt } : {}),
        ...(e.bio?.trim() ? { bio: e.bio.trim() } : {}),
      })),
    faq: d.faq.filter((e) => e.q.trim() && e.a.trim()).map((e) => ({ q: e.q.trim(), a: e.a.trim() })),
    gallery: d.gallery
      .filter((g) => g.url.trim())
      .map((g) => ({ url: g.url.trim(), ...(g.alt?.trim() ? { alt: g.alt.trim() } : {}) })),
    videoUrl: d.videoUrl.trim() || null,
    minAge: d.minAge === '' ? null : (Number(d.minAge) as MinAge),
    refundPolicy: d.refundPolicy || null,
    policyNotes: d.policyNotes.trim() || null,
  };
}
