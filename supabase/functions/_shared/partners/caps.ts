// Per-partner caps (mig 20261104200000, docs/partner-sales.md "Caps"): the
// most tickets one distribution partner may hold + sell, per ticket type or
// across the event. The SQL (_exos_partner_caps_set, _exos_partner_cap_check)
// is the rule; this is the request shape exos-api sends it and the numbers
// the dashboard shows.
//
// Pure TypeScript, imported by vitest (src/lib/partnerCaps.test.ts) and the SPA.

import { RequestError } from '../api/request.ts';

export const MAX_PARTNER_CAP = 100_000;
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

/** One cap as the SQL takes it. tier_id null = the whole event; max_tickets null = remove. */
export interface PartnerCapInput {
  partner_id: string;
  tier_id: string | null;
  max_tickets: number | null;
}

/** A cap as the SQL answers it (_exos_partner_caps_json). */
export interface PartnerCap {
  partner_id: string;
  partner_label: string;
  tier_id: string | null;
  tier_name: string | null;
  max_tickets: number;
  used: number;
  left: number;
  updated_at?: string;
}

/**
 * PUT /v1/events/:id/partner-caps body items: { partner_id, ticket_type_id
 * (or tier_id; absent / null = the event), max_tickets (0-100000, or null to
 * remove) }. 400 on anything else, before the database is asked.
 */
export function normalizePartnerCaps(raw: unknown[]): PartnerCapInput[] {
  if (raw.length === 0 || raw.length > 200) throw new RequestError(400, 'caps must list 1-200 caps.');
  return raw.map((item, i) => {
    if (!item || typeof item !== 'object' || Array.isArray(item)) {
      throw new RequestError(400, `caps[${i}] must be an object { partner_id, ticket_type_id?, max_tickets }.`);
    }
    const o = item as Record<string, unknown>;
    const partner = o.partner_id;
    if (typeof partner !== 'string' || !UUID_RE.test(partner)) {
      throw new RequestError(400, `caps[${i}].partner_id must be a partner id.`);
    }
    const tierRaw = o.ticket_type_id !== undefined ? o.ticket_type_id : o.tier_id;
    if (tierRaw !== undefined && tierRaw !== null && (typeof tierRaw !== 'string' || !UUID_RE.test(tierRaw))) {
      throw new RequestError(400, `caps[${i}].ticket_type_id must be a ticket type id, or null for the whole event.`);
    }
    if (!('max_tickets' in o)) {
      throw new RequestError(400, `caps[${i}].max_tickets is required (a whole number, or null to remove the cap).`);
    }
    const max = o.max_tickets;
    if (max !== null && (typeof max !== 'number' || !Number.isInteger(max) || max < 0 || max > MAX_PARTNER_CAP)) {
      throw new RequestError(400, `caps[${i}].max_tickets must be a whole number from 0 to ${MAX_PARTNER_CAP}, or null.`);
    }
    return { partner_id: partner.toLowerCase(), tier_id: typeof tierRaw === 'string' ? tierRaw.toLowerCase() : null, max_tickets: max as number | null };
  });
}

/**
 * The dashboard's cap field: '' removes the cap (null); otherwise a whole
 * number 0-100000. Returns undefined for anything else (keep the field red).
 */
export function parseCapField(text: string): number | null | undefined {
  const t = text.trim();
  if (t === '') return null;
  if (!/^\d{1,6}$/.test(t)) return undefined;
  const n = Number(t);
  return n <= MAX_PARTNER_CAP ? n : undefined;
}

/** "3 of 10 left" style line for a cap. */
export function capSummary(c: Pick<PartnerCap, 'max_tickets' | 'used' | 'left'>): string {
  if (c.max_tickets === 0) return 'stopped (cap 0)';
  if (c.left === 0) return `cap reached (${c.used} of ${c.max_tickets})`;
  return `${c.left} of ${c.max_tickets} left`;
}

/** The cap row for a partner and ticket type (null tier = the event cap). */
export function findCap(caps: readonly PartnerCap[], partnerId: string, tierId: string | null): PartnerCap | undefined {
  return caps.find((c) => c.partner_id === partnerId && (c.tier_id ?? null) === tierId);
}
