// Organizer-controlled access (mig 20261104180000, docs/org-access.md):
// per-role API permissions, venue booking requests with event-scoped grants,
// and the partner presale setting. Shared by exos-api and the SPA.
//
// The SQL enforces all of it; this file mirrors the rules the UI explains
// and the request bodies exos-api checks before calling the SQL:
//   * ROLE_SCOPE_CEILING = exos_role_scope_ceiling(role)  (src/lib/orgAccess.test.ts)
//   * orgRoleScopes()     = _exos_org_role_scopes(org, role, for_key)
//   * GRANT_SCOPES        = exos_event_partner_grant_vocab()
//
// Pure TypeScript, imported by vitest.

import { ROLE_SCOPES, type OrgRole } from './credentials.ts';
import { SCOPES, type Scope } from './scopes.ts';

/** The org-configurable scopes: the vocabulary without user scopes (me:*). */
export const ORG_SCOPES: readonly Scope[] = SCOPES.filter((s) => !s.startsWith('me:'));

/** The roles whose API permissions the owner sets (the owner always has everything). */
export const CONFIGURABLE_ROLES = ['manager', 'finance', 'content', 'scanner'] as const;
export type ConfigurableRole = (typeof CONFIGURABLE_ROLES)[number];

/**
 * The most a role can ever be given, from its dashboard permissions. Must
 * equal exos_role_scope_ceiling() in its latest migration (20261109100000:
 * audit:read for the owner and finance only).
 */
export const ROLE_SCOPE_CEILING: Record<OrgRole, readonly Scope[]> = {
  owner: [
    'events:read', 'events:write', 'orders:read', 'refunds:write', 'fans:read', 'fans:write', 'tickets:read',
    'tickets:write', 'checkin:write', 'booking:read', 'booking:write', 'finance:read', 'finance:write', 'commerce:read',
    'commerce:write', 'webhooks:read', 'webhooks:write', 'audit:read', 'org:admin',
  ],
  manager: [
    'events:read', 'events:write', 'orders:read', 'refunds:write', 'fans:read', 'fans:write', 'tickets:read',
    'tickets:write', 'checkin:write', 'booking:read', 'booking:write', 'finance:read', 'finance:write', 'commerce:read',
    'commerce:write', 'webhooks:read', 'webhooks:write',
  ],
  finance: [
    'events:read', 'orders:read', 'refunds:write', 'fans:read', 'tickets:read', 'booking:read', 'finance:read',
    'finance:write', 'commerce:read', 'audit:read',
  ],
  content: ['events:read', 'events:write', 'booking:read'],
  scanner: ['events:read', 'tickets:read', 'checkin:write'],
};

export function isConfigurableRole(r: unknown): r is ConfigurableRole {
  return typeof r === 'string' && (CONFIGURABLE_ROLES as readonly string[]).includes(r);
}

/**
 * What a role's credentials may carry in an org: the owner's choice
 * (`configured`, null when none) inside the ceiling. With no choice, today's
 * rule per credential kind: a user token ROLE_SCOPES[role], an org API key
 * the ceiling. Org scopes only, in vocabulary order.
 */
export function orgRoleScopes(role: OrgRole, configured: readonly string[] | null, forKey = false): Scope[] {
  const ceiling = ROLE_SCOPE_CEILING[role];
  const base: readonly string[] = role !== 'owner' && configured !== null
    ? configured
    : forKey ? ceiling : ROLE_SCOPES[role];
  return ORG_SCOPES.filter((s) => ceiling.includes(s) && base.includes(s));
}

/** Why a set can't be saved for a role (the scope above its ceiling), or null. */
export function roleScopesProblem(role: string, scopes: readonly string[]): string | null {
  if (!isConfigurableRole(role)) return 'role must be manager, finance, content or scanner';
  for (const s of scopes) {
    if (!(ORG_SCOPES as readonly string[]).includes(s)) return `unknown scope ${s}`;
    if (!ROLE_SCOPE_CEILING[role].includes(s as Scope)) return `the ${role} role can never be given ${s}`;
  }
  return null;
}

/** Toggle one scope in a role's set, keeping vocabulary order (the settings table). */
export function toggleScope(scopes: readonly string[], scope: Scope, on: boolean): Scope[] {
  const set = new Set(scopes);
  if (on) set.add(scope);
  else set.delete(scope);
  return ORG_SCOPES.filter((s) => set.has(s));
}

// -- Venue requests and grants --------------------------------------------------------

/** What a venue org may let a promoter do on one event (refunds stay with the venue). */
export const GRANT_SCOPES = ['events:read', 'events:write', 'tickets:read', 'finance:read'] as const;
export type GrantScope = (typeof GRANT_SCOPES)[number];
export const DEFAULT_GRANT_SCOPES: readonly GrantScope[] = ['events:read', 'events:write', 'tickets:read'];

export const GRANT_SCOPE_INFO: Record<GrantScope, string> = {
  'events:read': 'See the event and its ticket types.',
  'events:write': 'Edit the event\'s name, description, summary, image and video.',
  'tickets:read': 'See tickets sold and checked in per ticket type (no attendee details).',
  'finance:read': 'See gross ticket revenue per ticket type.',
};

/** A grant's scopes as the SQL stores them (events:write brings events:read), or an error. */
export function cleanGrantScopes(raw: unknown): { ok: true; scopes: GrantScope[] } | { ok: false; error: string } {
  if (raw === undefined || raw === null) return { ok: true, scopes: [...DEFAULT_GRANT_SCOPES] };
  if (!Array.isArray(raw) || raw.some((s) => typeof s !== 'string')) return { ok: false, error: 'scopes must be a list of scope names' };
  const bad = raw.find((s) => !(GRANT_SCOPES as readonly string[]).includes(s));
  if (bad !== undefined) return { ok: false, error: `a promoter can be given only ${GRANT_SCOPES.join(', ')} on an event, not ${bad}` };
  const set = new Set<string>(raw);
  if (set.has('events:write')) set.add('events:read');
  const scopes = GRANT_SCOPES.filter((s) => set.has(s));
  if (!scopes.length) return { ok: false, error: 'give at least one scope (or revoke the grant)' };
  return { ok: true, scopes };
}

/** A route on a co-hosted event needs the scope in the caller's credential AND in the grant. */
export function cohostAllowed(credScopes: readonly string[], grantScopes: readonly string[], needed: GrantScope): boolean {
  const cred = credScopes.includes(needed) || (needed.endsWith(':read') && credScopes.includes(needed.replace(/:read$/, ':write')));
  return cred && grantScopes.includes(needed);
}

/** Money on a co-hosted event (gross): finance:read in the grant AND the credential. Same as the SQL. */
export function cohostMoneyAllowed(credScopes: readonly string[], grantScopes: readonly string[]): boolean {
  return cohostAllowed(credScopes, grantScopes, 'finance:read')
    || (grantScopes.includes('finance:read') && credScopes.includes('finance:write'));
}

export const VENUE_REQUEST_STATUSES = ['pending', 'approved', 'declined', 'withdrawn'] as const;

const DATE_RE = /^\d{4}-\d{2}-\d{2}$/;
const HM_RE = /^([01]\d|2[0-3]):[0-5]\d$/;
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export interface VenueRequestBody {
  venue_id: string;
  room_id?: string | null;
  date: string;
  start_time?: string | null;
  title: string;
  message?: string;
  expected_draw?: number | null;
}

/** A booking request body's shape (the SQL checks the venue, dates and limits again). */
export function venueRequestBody(b: Record<string, unknown>): { ok: true; body: VenueRequestBody } | { ok: false; error: string } {
  const known = new Set(['venue_id', 'room_id', 'date', 'start_time', 'title', 'message', 'expected_draw']);
  const extra = Object.keys(b).find((k) => !known.has(k));
  if (extra) return { ok: false, error: `unknown field ${extra}` };
  if (typeof b.venue_id !== 'string' || !UUID_RE.test(b.venue_id)) return { ok: false, error: 'venue_id must be a venue id' };
  if (b.room_id !== undefined && b.room_id !== null && (typeof b.room_id !== 'string' || !UUID_RE.test(b.room_id))) {
    return { ok: false, error: 'room_id must be a room id' };
  }
  if (typeof b.date !== 'string' || !DATE_RE.test(b.date) || Number.isNaN(Date.parse(`${b.date}T00:00:00Z`))) {
    return { ok: false, error: 'date must be a date written YYYY-MM-DD' };
  }
  if (b.start_time !== undefined && b.start_time !== null && (typeof b.start_time !== 'string' || !HM_RE.test(b.start_time))) {
    return { ok: false, error: 'start_time must be HH:MM' };
  }
  if (typeof b.title !== 'string' || !b.title.trim() || b.title.trim().length > 100) {
    return { ok: false, error: 'title is required (at most 100 characters)' };
  }
  if (b.message !== undefined && b.message !== null && (typeof b.message !== 'string' || b.message.length > 2000)) {
    return { ok: false, error: 'message must be at most 2000 characters' };
  }
  if (b.expected_draw !== undefined && b.expected_draw !== null
      && (typeof b.expected_draw !== 'number' || !Number.isInteger(b.expected_draw) || b.expected_draw < 0 || b.expected_draw > 1_000_000)) {
    return { ok: false, error: 'expected_draw must be a whole number from 0' };
  }
  return { ok: true, body: b as unknown as VenueRequestBody };
}

/**
 * exos_venues columns an organization never writes through the API's venue
 * routes: `verified` is Exos staff's (exos_admin_set_venue_verified) and
 * `listed_venue_id` goes through PUT /v1/venues/:id/listed-venue. Dropped
 * from a venue row before it is written (the SQL refuses or clears them too).
 */
export const STAFF_VENUE_FIELDS = ['verified', 'listed_venue_id'] as const;

export function stripStaffVenueFields<T extends Record<string, unknown>>(row: T): T {
  const out = { ...row };
  for (const k of STAFF_VENUE_FIELDS) delete (out as Record<string, unknown>)[k];
  return out;
}

/** The fields a co-host may change on the venue's event. */
export const COHOST_EVENT_FIELDS = ['name', 'description', 'summary', 'description_md', 'image_url', 'video_url'] as const;

/**
 * venue_approval_required (the venue gate in SQL): the venue id the caller
 * should send a request for, or null when the message is something else.
 */
export function venueApprovalVenue(message: unknown): string | null {
  if (typeof message !== 'string' || !message.startsWith('venue_approval_required')) return null;
  const m = /venue_id ([0-9a-f-]{36})/i.exec(message);
  return m ? m[1] : '';
}

// -- Partner presale -------------------------------------------------------------------

export const PARTNER_PRESALE_MODES = ['block', 'allow'] as const;
export type PartnerPresaleMode = (typeof PARTNER_PRESALE_MODES)[number];

export function isPartnerPresaleMode(m: unknown): m is PartnerPresaleMode {
  return m === 'block' || m === 'allow';
}

/** The mode for an event: its override, else the org's, else block. Same as _exos_partner_presale_mode. */
export function effectivePartnerPresale(orgMode: string | null | undefined, eventMode: string | null | undefined): PartnerPresaleMode {
  if (isPartnerPresaleMode(eventMode)) return eventMode;
  if (isPartnerPresaleMode(orgMode)) return orgMode;
  return 'block';
}

export const PARTNER_PRESALE_INFO: Record<PartnerPresaleMode, string> = {
  block: 'Partners can\'t sell a ticket type while its member presale runs (members buy first on Exos).',
  allow: 'Partners can sell during the member presale too. Buyers on Exos itself still need a membership.',
};
