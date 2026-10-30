// The organizer's resale opt-in (mig 20261029090000): events over the free
// tier (max capacity over 150) are resold only after an owner or manager opts
// in for that event, having read the text below. The server records who,
// when, this text's version and the event's max capacity, and revokes it if
// the max capacity drops to 150 or less.

import { supabase } from '../supabase';
import { isMissingRpc } from '../door/net';

/** Bump with the text, and SQL _exos_resale_consent_version() with it. */
export const RESALE_CONSENT_VERSION = '2026-10-29';

export const RESALE_CONSENT_TEXT: readonly string[] = [
  'I allow Exos to list this event\'s tickets on resale marketplaces (StubHub, SeatGeek, Vivid Seats, Gametime, '
    + 'TickPick, GoTickets, Ticket Evolution) and on the S4K network, at the prices I set and with the seats I give '
    + 'each one. Marketplaces add their own fees for buyers; the Exos fee applies to those sales as to any other.',
  'Every sale comes off the same count as my own checkout, so nothing oversells.',
  'I can withdraw this at any time: listings come down and their unsold seats come back to my checkout. If the '
    + 'event\'s max capacity drops to the free tier (150 or less) this consent ends and I have to give it again.',
];

export interface SalesRules {
  maxCapacity: number;
  capacityBounded: boolean;
  freeTierMaxCapacity: number;
  freeTier: boolean;
  consentRequired: boolean;
  consentVersion: string;
  consent: { givenAt: string; givenByEmail: string | null; version: string; maxCapacityAtConsent: number } | null;
  lastRevoked: { revokedAt: string; reason: 'withdrawn' | 'capacity_dropped' } | null;
  resaleUnlocked: boolean;
  lockedReason: string | null;
  canManage: boolean;
}

const num = (v: unknown, d = 0) => (typeof v === 'number' && Number.isFinite(v) ? v : d);

export function parseSalesRules(raw: unknown): SalesRules | null {
  if (!raw || typeof raw !== 'object') return null;
  const r = raw as Record<string, unknown>;
  const c = r.consent as Record<string, unknown> | null | undefined;
  const l = r.last_revoked as Record<string, unknown> | null | undefined;
  return {
    maxCapacity: num(r.max_capacity),
    capacityBounded: r.capacity_bounded === true,
    freeTierMaxCapacity: num(r.free_tier_max_capacity, 150),
    freeTier: r.free_tier === true,
    consentRequired: r.consent_required !== false,
    consentVersion: typeof r.consent_version === 'string' ? r.consent_version : '',
    consent: c && typeof c === 'object' ? {
      givenAt: String(c.given_at ?? ''),
      givenByEmail: typeof c.given_by_email === 'string' ? c.given_by_email : null,
      version: String(c.version ?? ''),
      maxCapacityAtConsent: num(c.max_capacity_at_consent),
    } : null,
    lastRevoked: l && typeof l === 'object' ? {
      revokedAt: String(l.revoked_at ?? ''),
      reason: l.reason === 'capacity_dropped' ? 'capacity_dropped' : 'withdrawn',
    } : null,
    resaleUnlocked: r.resale_unlocked === true,
    lockedReason: typeof r.locked_reason === 'string' ? r.locked_reason : null,
    canManage: r.can_manage === true,
  };
}

/** What the panel shows: one line on where the event stands. */
export function salesRulesLine(r: SalesRules): string {
  if (r.freeTier) {
    return `Free tier: a max capacity of ${r.maxCapacity} (${r.freeTierMaxCapacity} or less). No Exos fee, and it is never listed on resale marketplaces or S4K.`;
  }
  if (r.maxCapacity <= r.freeTierMaxCapacity) {
    return `Resale needs a max capacity over ${r.freeTierMaxCapacity}. This event's capped ticket types add up to ${r.maxCapacity}; give every ticket type a cap or set an overall cap.`;
  }
  if (r.resaleUnlocked && r.consent) return 'Resale is on for this event.';
  if (r.resaleUnlocked) return 'Resale is available for this event.';
  if (r.lastRevoked?.reason === 'capacity_dropped') {
    return `Resale is off: the max capacity dropped to the free tier, which ended the earlier opt-in. It is ${r.maxCapacity} now; opt in again to resell.`;
  }
  return 'Resale is off until you opt in below.';
}

/** null before mig 20261029090000. */
export async function fetchSalesRules(eventId: string): Promise<SalesRules | null> {
  const { data, error } = await supabase.rpc('exos_event_sales_rules', { p_event_id: eventId });
  if (error) {
    if (isMissingRpc(error)) return null;
    throw error;
  }
  return parseSalesRules(data);
}

export async function setResaleConsent(eventId: string, on: boolean): Promise<SalesRules | null> {
  const { data, error } = await supabase.rpc('exos_set_resale_consent', {
    p_event_id: eventId, p_on: on, p_consent_version: on ? RESALE_CONSENT_VERSION : null,
  });
  if (error) throw error;
  return parseSalesRules(data);
}
