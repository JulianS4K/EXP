// Communities (docs/communities.md, mig 20261031200000): pure helpers for the
// community page, the directory and the organizer panel. The rules live in
// SQL; these mirror them so the UI can explain before a round trip.

export type JoinMode = 'open' | 'approval' | 'invite';
export type MemberStatus = 'pending' | 'active' | 'banned' | 'removed' | 'left' | 'declined';

export interface PublicCommunity {
  id: string;
  slug: string;
  ap_name: string;
  name: string;
  tagline: string | null;
  about: string | null;
  banner_url: string | null;
  city: string | null;
  region: string | null;
  country: string | null;
  join_mode: JoinMode;
  visibility: 'public' | 'unlisted';
  federated: boolean;
  org: { id: string; name: string; slug: string } | null;
  member_count: number;
  hosts: { display_name: string; org: { name: string; slug: string } | null }[];
  upcoming: CommunityEvent[];
  past: CommunityEvent[];
  posts: CommunityPost[];
  me: {
    status?: MemberStatus;
    notify_email?: boolean;
    notify_sms?: boolean;
    host?: boolean;
    admin?: boolean;
    sms_subscribed?: boolean;
  } | null;
}

export interface CommunityEvent {
  id: string;
  name: string;
  slug: string | null;
  starts_at: string | null;
  timezone: string | null;
  venue_name: string | null;
  venue_location?: string | null;
  image_url: string | null;
  members_only?: boolean;
  early_access_until?: string | null;
}

export interface CommunityPost {
  id: string;
  title: string | null;
  body: string;
  visibility: 'public' | 'members';
  created_at: string;
  by: string | null;
  replies: { actor_name: string | null; actor_handle: string | null; content_text: string; url: string | null; received_at: string }[];
}

/** Same rule as the SQL CHECK: 3-40 of a-z 0-9 - _, no leading/trailing -/_, not reserved. */
export const RESERVED_SLUGS = ['new', 'admin', 'api', 'ap', 'inbox', 'settings', 'directory', 'communities', 'www', 'exos'];

export function slugProblem(raw: string): string | null {
  const s = raw.trim().toLowerCase();
  if (s.length < 3 || s.length > 40) return 'Use 3 to 40 characters.';
  if (!/^[a-z0-9][a-z0-9_-]*[a-z0-9]$/.test(s)) return 'Letters, numbers, - and _ only; start and end with a letter or number.';
  if (/^org[_-]/.test(s) || RESERVED_SLUGS.includes(s)) return 'That link name is reserved.';
  return null;
}

/** A link name suggested from the community name. */
export function suggestSlug(name: string): string {
  const s = name.toLowerCase().normalize('NFKD').replace(/[̀-ͯ]/g, '')
    .replace(/[^a-z0-9]+/g, '-').replace(/^-+|-+$/g, '').slice(0, 40).replace(/-+$/g, '');
  return s.length >= 3 ? s : `${s || 'community'}-club`.slice(0, 40);
}

/** ActivityPub name (WebFinger acct): slug with - as _. */
export function apName(slug: string): string {
  return slug.toLowerCase().replace(/-/g, '_');
}

/** How people on other servers find it: Mastodon @name@host, Lemmy !name@host. */
export function fediverseHandles(slug: string, host: string): { mastodon: string; lemmy: string } {
  const n = apName(slug);
  const h = host.replace(/^https?:\/\//, '').replace(/\/.*$/, '');
  return { mastodon: `@${n}@${h}`, lemmy: `!${n}@${h}` };
}

/** The consent text shown next to the channel boxes (stored with the join). */
export function consentText(communityName: string, email: boolean, sms: boolean): string {
  const ch = email && sms ? 'email and text' : sms ? 'text' : 'email';
  return `Send me ${ch} updates from ${communityName} when it adds an event or posts news. ` +
    `I can change or stop them on the community page any time${sms ? ', or reply STOP to a text' : ''}.`;
}

export type JoinAction =
  | { kind: 'join'; label: string }
  | { kind: 'request'; label: string }
  | { kind: 'invite_only'; label: string }
  | { kind: 'pending'; label: string }
  | { kind: 'member'; label: string }
  | { kind: 'banned'; label: string }
  | { kind: 'sign_in'; label: string };

/** What the join button says and does. */
export function joinAction(mode: JoinMode, status: MemberStatus | undefined, signedIn: boolean, hasInvite: boolean): JoinAction {
  if (status === 'active') return { kind: 'member', label: 'Joined' };
  if (status === 'pending') return { kind: 'pending', label: 'Request sent' };
  if (status === 'banned') return { kind: 'banned', label: "You can't join this community" };
  if (!signedIn) return { kind: 'sign_in', label: 'Sign in to join' };
  if (hasInvite) return { kind: 'join', label: 'Accept invite and join' };
  if (mode === 'invite') return { kind: 'invite_only', label: 'Invite only' };
  if (mode === 'approval') return { kind: 'request', label: 'Ask to join' };
  return { kind: 'join', label: 'Join' };
}

export const JOIN_MODE_LABEL: Record<JoinMode, string> = {
  open: 'Anyone can join',
  approval: 'You approve each request',
  invite: 'Invite only',
};

/** "exos_community_join: this community is invite only" → "This community is invite only." */
export function friendlyError(e: unknown): string {
  const raw = String((e as { message?: unknown })?.message ?? e ?? '').trim();
  const m = raw.replace(/^[a-z_]+:\s*/i, '');
  if (!m) return 'Something went wrong. Try again.';
  const s = m.charAt(0).toUpperCase() + m.slice(1);
  return /[.!?]$/.test(s) ? s : `${s}.`;
}

/** Bearer tokens from the invite links. */
export function inviteToken(search: string): { kind: 'member' | 'host'; token: string } | null {
  const q = new URLSearchParams(search);
  const m = q.get('invite');
  if (m && /^ecv_[0-9a-f]{64}$/.test(m)) return { kind: 'member', token: m };
  const h = q.get('host');
  if (h && /^ech_[0-9a-f]{64}$/.test(h)) return { kind: 'host', token: h };
  return null;
}

/** Early access still running → its end, else null. */
export function earlyAccessUntil(ev: Pick<CommunityEvent, 'early_access_until'>, now = new Date()): Date | null {
  if (!ev.early_access_until) return null;
  const d = new Date(ev.early_access_until);
  return Number.isNaN(d.getTime()) || d <= now ? null : d;
}

export function eventBadge(ev: CommunityEvent, now = new Date()): string | null {
  if (ev.members_only) return 'Members only';
  if (earlyAccessUntil(ev, now)) return 'Member early access';
  return null;
}

/** "Brooklyn, NY" / "Brooklyn" / "". */
export function placeLine(c: Pick<PublicCommunity, 'city' | 'region' | 'country'>): string {
  return [c.city, c.region].filter((x) => x && x.trim()).join(', ') || (c.country ?? '');
}

export function memberCountLabel(n: number): string {
  return `${n.toLocaleString('en-US')} member${n === 1 ? '' : 's'}`;
}

/** An event id from a pasted link (…/event/<uuid>) or a bare id. */
export function eventIdFromLink(raw: string): string | null {
  const m = raw.trim().match(/(?:^|\/event\/)([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})(?:[/?#]|$)/i);
  return m ? m[1].toLowerCase() : null;
}
