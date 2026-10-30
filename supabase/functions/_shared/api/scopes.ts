// Scopes for the partner API (exos-api). docs/api-reference.md.
//
// An org API key carries a list of scopes (exos_api_keys.scopes). Each route
// in ./routes.ts names the one scope it needs; a request whose key lacks it
// gets 403 with WWW-Authenticate: Bearer error="insufficient_scope".
//
//   * `read` is the legacy scope every key created before 2026-10-27 has (the
//     column default). It covers every `:read` scope and nothing else, which is
//     exactly what those keys could do.
//   * A `:write` scope covers the `:read` scope of the same resource.
//
// The vocabulary is the same as the Firebase build's (PR #1, server/apiScopes.ts)
// so keys can be narrowed now for areas whose routes arrive later (booking,
// finance, commerce). The SQL side validates against the same list
// (exos_api_scope_names(), mig 20261027090000); src/lib/apiScopes.test.ts
// checks the two agree.
//
// Pure TypeScript with no Deno or Supabase imports, so vitest can import it.

export const SCOPES = [
  'events:read',
  'events:write',
  'orders:read',
  'fans:read',
  'fans:write',
  'tickets:read',
  'tickets:write',
  'checkin:write',
  'booking:read',
  'booking:write',
  'finance:read',
  'finance:write',
  'commerce:read',
  'commerce:write',
  'webhooks:read',
  'webhooks:write',
  'org:admin',
] as const;

export type Scope = (typeof SCOPES)[number];

/** The scope keys created before scopes existed carry. */
export const LEGACY_READ = 'read';

/** What each scope lets a key do; shown when creating a key and on /developers. */
export const SCOPE_INFO: Record<Scope, { label: string; description: string }> = {
  'events:read': { label: 'Read events', description: 'Events, ticket types, add-ons and promo codes.' },
  'events:write': { label: 'Manage events', description: 'Create and edit events, ticket types, add-ons and promo codes.' },
  'orders:read': { label: 'Read orders', description: 'Orders with buyer email and amounts, invoices, refunds, refund requests and the waitlist.' },
  'fans:read': { label: 'Read fans', description: 'Fan profiles (contact, order history, consent shown read-only), tags on fans and signup forms.' },
  'fans:write': { label: 'Manage fans', description: 'Add, rename and remove fan contacts and tag fans. Never changes a fan\'s consent.' },
  'tickets:read': { label: 'Read tickets', description: 'Attendees (never the barcode secret), check-ins, check-in lists and guest lists.' },
  'tickets:write': { label: 'Manage tickets', description: 'Transfer tickets, add guest-list entries and comps.' },
  'checkin:write': { label: 'Check in', description: 'Check tickets in and out, and door settings.' },
  'booking:read': { label: 'Read booking', description: 'Venues, rooms, holds, offers and show schedules.' },
  'booking:write': { label: 'Manage booking', description: 'Create and change holds, offers, venues and show schedules.' },
  'finance:read': { label: 'Read finance', description: 'Settlements, finance items, profit and loss, ticket counts.' },
  'finance:write': { label: 'Manage finance', description: 'Finance items, settlement adjustments, ticket-count emails.' },
  'commerce:read': { label: 'Read memberships and gift cards', description: 'Membership, pass, gift-card and giving products and records.' },
  'commerce:write': { label: 'Manage memberships and gift cards', description: 'Create and change those products and issue gift cards.' },
  'webhooks:read': { label: 'Read webhooks', description: 'Webhook endpoints and the event types they receive (never the signing secret).' },
  'webhooks:write': { label: 'Manage webhooks', description: 'Add, change and remove webhook endpoints.' },
  'org:admin': { label: 'Organization admin', description: 'Organization settings and members.' },
};

export function isScope(s: unknown): s is Scope {
  return typeof s === 'string' && (SCOPES as readonly string[]).includes(s);
}

/** Every `:read` scope: what the legacy `read` scope stands for. */
export const READ_SCOPES: readonly Scope[] = SCOPES.filter((s) => s.endsWith(':read'));

/**
 * `granted` (a key's stored scopes) covers `needed`. The legacy `read` covers
 * every `:read`; a `:write` covers the `:read` of the same resource.
 */
export function hasScope(granted: readonly string[], needed: Scope): boolean {
  if (granted.includes(needed)) return true;
  if (needed.endsWith(':read')) {
    if (granted.includes(LEGACY_READ)) return true;
    return granted.includes(needed.replace(/:read$/, ':write'));
  }
  return false;
}

/** The scopes a key effectively has, in SCOPES order (for GET /me and the UI). */
export function effectiveScopes(granted: readonly string[]): Scope[] {
  return SCOPES.filter((s) => hasScope(granted, s));
}
