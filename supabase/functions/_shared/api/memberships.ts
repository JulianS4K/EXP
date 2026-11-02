// Request bodies of the membership, membership-product and imported-attendee
// write routes (mig 20261102100000, docs/memberships.md): Exos's own field
// names, plus the Opendate spellings mapped onto them, so a client written
// against Opendate's API works with few changes. The SQL refuses anything
// unknown, so a typo is an error, never silently ignored; only the Opendate
// keys that have no Exos meaning (listed below) are dropped here.
//
// Pure TypeScript, imported by vitest (src/lib/apiMemberships.test.ts).

type Body = Record<string, unknown>;

/** Opendate-style bodies wrap the fields ({ membership_product: { … } }); both forms work. */
export function unwrapBody(body: Body, wrapper: string): Body {
  const inner = body[wrapper];
  return inner && typeof inner === 'object' && !Array.isArray(inner) ? { ...(inner as Body) } : { ...body };
}

/** Thrown for a body the route can't take (answered 400). */
export class BodyFieldError extends Error {}

// Opendate keys with no Exos counterpart: venues (an Exos product belongs to
// the organization), the team (the key's org), benefit rows (Exos benefits
// are the product's fields), ticketing-time prices.
const PRODUCT_DROP = [
  'team_id', 'billing_venue_ownership_id', 'venue_ownership_ids', 'membership_product_benefits_attributes',
  'ticketing_annual_amount_cents', 'ticketing_monthly_amount_cents',
];

/**
 * A membership product's fields. Opendate's default_monthly_amount_cents /
 * default_annual_amount_cents become price_cents + billing (one price per
 * product in Exos: send one of them). On update billing can't change, so the
 * Opendate amounts only set the price there.
 */
export function membershipProductFields(body: Body, mode: 'create' | 'update'): Body {
  const f = unwrapBody(body, 'membership_product');
  for (const k of PRODUCT_DROP) delete f[k];
  const monthly = f.default_monthly_amount_cents;
  const annual = f.default_annual_amount_cents;
  delete f.default_monthly_amount_cents;
  delete f.default_annual_amount_cents;
  const m = positive(monthly);
  const a = positive(annual);
  if (m !== null && a !== null) {
    throw new BodyFieldError('an Exos membership product has one price: send default_monthly_amount_cents or default_annual_amount_cents, not both (or price_cents with billing).');
  }
  if ((m !== null || a !== null) && f.price_cents === undefined) {
    f.price_cents = m ?? a;
    if (mode === 'create' && f.billing === undefined) f.billing = m !== null ? 'month' : 'year';
  }
  if ('status' in f) throw new BodyFieldError('status is changed with /publish, /unpublish and /archive.');
  return f;
}

function positive(v: unknown): number | null {
  const n = typeof v === 'string' && v.trim() !== '' ? Number(v) : v;
  return typeof n === 'number' && Number.isFinite(n) && n > 0 ? n : null;
}

function joinName(f: Body, first: string, last: string): string | undefined {
  if (!(first in f) && !(last in f)) return undefined;
  const parts = [f[first], f[last]].filter((x) => typeof x === 'string' && x.trim()).map((x) => (x as string).trim());
  delete f[first];
  delete f[last];
  return parts.join(' ');
}

const MEMBERSHIP_DROP = ['team_id', 'phone_number', 'import_metadata', 'skip_welcome_email', 'idempotency_key'];

/**
 * POST /memberships: { product_id, email, member_name?, source?, expires_at?,
 * staff_notes? }. Opendate: first_name + last_name -> member_name,
 * rebilling_date -> expires_at, notes -> staff_notes; a body
 * idempotency_key is returned for use as the Idempotency-Key.
 */
export function membershipIssueFields(body: Body): { fields: Body; idempotencyKey: string | null } {
  const f = unwrapBody(body, 'membership');
  const idem = typeof f.idempotency_key === 'string' ? f.idempotency_key : null;
  if ('membership_product_price_id' in f && !('product_id' in f)) {
    throw new BodyFieldError('send product_id (the membership product\'s id): Exos products have one price, with no price ids.');
  }
  for (const k of MEMBERSHIP_DROP) delete f[k];
  const name = joinName(f, 'first_name', 'last_name');
  if (name !== undefined && f.member_name === undefined) f.member_name = name;
  moveKey(f, 'rebilling_date', 'expires_at');
  moveKey(f, 'notes', 'staff_notes');
  return { fields: f, idempotencyKey: idem };
}

/** PATCH /memberships/:id: { member_name?, staff_notes?, status?, expires_at? } (+ Opendate names). */
export function membershipUpdateFields(body: Body): Body {
  const f = unwrapBody(body, 'membership');
  for (const k of MEMBERSHIP_DROP) delete f[k];
  const name = joinName(f, 'first_name', 'last_name');
  if (name !== undefined && f.member_name === undefined) f.member_name = name;
  moveKey(f, 'current_period_end', 'expires_at');
  moveKey(f, 'notes', 'staff_notes');
  return f;
}

/**
 * PATCH /migrated-attendees/:id: { guest_name?, email?, phone?, plus_ones?,
 * note?, code?, ticket_label?, source? }. Opendate: first_name + last_name ->
 * guest_name, barcode -> code.
 */
export function importedAttendeeFields(body: Body): Body {
  const f = unwrapBody(body, 'migrated_attendee');
  delete f.team_id;
  const name = joinName(f, 'first_name', 'last_name');
  if (name !== undefined && f.guest_name === undefined) f.guest_name = name;
  moveKey(f, 'barcode', 'code');
  return f;
}

function moveKey(f: Body, from: string, to: string): void {
  if (from in f) {
    if (!(to in f)) f[to] = f[from];
    delete f[from];
  }
}

/** The lifecycle actions, as the route ids name them. */
export const PRODUCT_ACTIONS = { 'publish-membership-product': 'publish', 'unpublish-membership-product': 'unpublish', 'archive-membership-product': 'archive' } as const;
