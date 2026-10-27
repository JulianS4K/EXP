// Organizer fee rules (mig 20261027100000, docs/fees.md): data access.
//
// Buyers: exos_public_fee_rules (anon) — the passed-on rules of published
// events, picked per tier / add-on with ./fees.ts and folded into the all-in
// price (./pricing.ts allInPrice). Organizers: exos_fee_rules +
// exos_event_fee_settings under RLS (owner / manager write, finance reads).

import { supabase } from './supabase';
import {
  PUBLIC_FEE_RULE_COLS, addonPassedOnFees, feeRulesByEvent, tierPassedOnFees,
  type FeeCalc, type FeeKind, type FeePer, type FeeRule,
} from './fees';

// --- Buyers -----------------------------------------------------------------

/**
 * Passed-on fee rules per event. Never throws: on a read error the prices show
 * without fees (logged), as they did before fee rules existed.
 */
export async function listPublicFeeRules(eventIds: string[]): Promise<Map<string, FeeRule[]>> {
  const ids = [...new Set(eventIds.filter(Boolean))];
  if (ids.length === 0) return new Map();
  try {
    const { data, error } = await supabase
      .from('exos_public_fee_rules')
      .select(PUBLIC_FEE_RULE_COLS)
      .in('event_id', ids)
      .order('rank', { ascending: true });
    if (error) throw error;
    return feeRulesByEvent(data ?? []);
  } catch (e) {
    console.warn('fee rules: could not load; prices shown without passed-on fees', e);
    return new Map();
  }
}

/** Raw tier rows (exos_public_tiers / exos_voucher_tier) with their passed-on fees attached as passed_on_fees. */
export function withTierFees<T extends { id?: unknown; event_id?: unknown }>(
  tiers: T[], rules: Map<string, FeeRule[]> | FeeRule[] | undefined,
): (T & { passed_on_fees: FeeRule[] })[] {
  return tiers.map((t) => {
    const list = Array.isArray(rules) ? rules : rules?.get(String(t.event_id)) ?? [];
    return { ...t, passed_on_fees: tierPassedOnFees(list, String(t.id)) };
  });
}

/** Raw add-on rows with their passed-on fees attached as passed_on_fees. */
export function withAddonFees<T extends { event_id?: unknown }>(
  addons: T[], rules: Map<string, FeeRule[]> | FeeRule[] | undefined,
): (T & { passed_on_fees: FeeRule[] })[] {
  return addons.map((a) => {
    const list = Array.isArray(rules) ? rules : rules?.get(String(a.event_id)) ?? [];
    return { ...a, passed_on_fees: addonPassedOnFees(list) };
  });
}

// --- Organizers ---------------------------------------------------------------

export interface FeeRuleRow {
  id: string;
  orgId: string;
  eventId: string | null;
  name: string;
  /** Who the money is for, for reports: 'org', 'venue', 'promoter', ... */
  recipient: string;
  kind: FeeKind;
  calc: FeeCalc;
  /** calc = percent: 0-100. */
  percent: number | null;
  /** calc = fixed: minor units. */
  amountCents: number | null;
  capCents: number | null;
  per: FeePer;
  taxable: boolean;
  appliesToAddons: boolean;
  /** Event rules only: the tiers it covers (null = all). */
  tierIds: string[] | null;
  active: boolean;
  sortOrder: number;
  createdAt: string;
}

export type FeeRuleInput = Omit<FeeRuleRow, 'id' | 'orgId' | 'eventId' | 'createdAt'>;

export interface EventFeeSettings {
  /** false = the event ignores every org rule. */
  inheritOrgRules: boolean;
  /** Org rules this event skips (when inheriting). */
  skippedOrgRuleIds: string[];
}

const COLS = 'id, org_id, event_id, name, recipient, kind, calc, percent, amount_cents, cap_cents, per, taxable, applies_to_addons, tier_ids, active, sort_order, created_at';

function mapRow(r: any): FeeRuleRow {
  return {
    id: r.id,
    orgId: r.org_id,
    eventId: r.event_id ?? null,
    name: r.name ?? '',
    recipient: r.recipient ?? 'org',
    kind: r.kind === 'absorbed' ? 'absorbed' : 'passed_on',
    calc: r.calc === 'percent' ? 'percent' : 'fixed',
    percent: r.percent == null ? null : Number(r.percent),
    amountCents: r.amount_cents == null ? null : Number(r.amount_cents),
    capCents: r.cap_cents == null ? null : Number(r.cap_cents),
    per: r.per === 'order' ? 'order' : 'ticket',
    taxable: r.taxable !== false,
    appliesToAddons: r.applies_to_addons === true,
    tierIds: Array.isArray(r.tier_ids) && r.tier_ids.length ? r.tier_ids.map(String) : null,
    active: r.active !== false,
    sortOrder: Number(r.sort_order) || 0,
    createdAt: r.created_at ?? '',
  };
}

/** The org's own rules (inherited by every event). RLS: owner / manager / finance. */
export async function listOrgFeeRules(orgId: string): Promise<FeeRuleRow[]> {
  const { data, error } = await supabase.from('exos_fee_rules').select(COLS)
    .eq('org_id', orgId).is('event_id', null)
    .order('sort_order', { ascending: true }).order('created_at', { ascending: true });
  if (error) throw error;
  return (data ?? []).map(mapRow);
}

/** One event's own rules. */
export async function listEventFeeRules(eventId: string): Promise<FeeRuleRow[]> {
  const { data, error } = await supabase.from('exos_fee_rules').select(COLS)
    .eq('event_id', eventId)
    .order('sort_order', { ascending: true }).order('created_at', { ascending: true });
  if (error) throw error;
  return (data ?? []).map(mapRow);
}

/** Problems with a rule before it's saved ([] = fine). The database re-checks. */
export function feeRuleProblems(r: Pick<FeeRuleInput, 'name' | 'kind' | 'calc' | 'percent' | 'amountCents' | 'capCents' | 'per' | 'recipient'>): string[] {
  const out: string[] = [];
  if (!r.name.trim() || r.name.trim().length > 60) out.push('Give the fee a name (up to 60 characters).');
  if (!r.recipient.trim() || r.recipient.trim().length > 40) out.push('Say who the fee is for (up to 40 characters).');
  if (r.calc === 'percent') {
    if (r.percent == null || !(r.percent > 0) || r.percent > 100) out.push('A percentage fee needs a rate between 0 and 100.');
  } else if (r.amountCents == null || !(r.amountCents > 0) || r.amountCents > 10_000_000) {
    out.push('A fixed fee needs an amount above zero.');
  }
  if (r.capCents != null && (r.calc !== 'percent' || r.capCents < 0)) out.push('Only a percentage fee can have a cap.');
  if (r.per === 'order' && r.kind === 'passed_on') {
    out.push('A per-order fee can\'t be passed on: every price buyers see is all-in per ticket. Absorb it, or make it per ticket.');
  }
  return out;
}

function toDb(input: FeeRuleInput) {
  return {
    name: input.name.trim(),
    recipient: input.recipient.trim().toLowerCase() || 'org',
    kind: input.kind,
    calc: input.calc,
    percent: input.calc === 'percent' ? input.percent : null,
    amount_cents: input.calc === 'fixed' ? input.amountCents : null,
    cap_cents: input.calc === 'percent' ? input.capCents : null,
    per: input.per,
    taxable: input.taxable,
    applies_to_addons: input.appliesToAddons,
    tier_ids: input.tierIds && input.tierIds.length ? input.tierIds : null,
    active: input.active,
    sort_order: input.sortOrder,
  };
}

/** Create (no id) or update a rule; org level when eventId is null. */
export async function saveFeeRule(orgId: string, eventId: string | null, input: FeeRuleInput, id?: string): Promise<void> {
  const problems = feeRuleProblems(input);
  if (problems.length) throw new Error(problems[0]);
  const row = toDb(input);
  if (!eventId) row.tier_ids = null;
  const { error } = id
    ? await supabase.from('exos_fee_rules').update(row).eq('id', id)
    : await supabase.from('exos_fee_rules').insert({ ...row, org_id: orgId, event_id: eventId });
  if (error) throw error;
}

export async function deleteFeeRule(id: string): Promise<void> {
  const { error } = await supabase.from('exos_fee_rules').delete().eq('id', id);
  if (error) throw error;
}

export async function getEventFeeSettings(eventId: string): Promise<EventFeeSettings> {
  const { data, error } = await supabase.from('exos_event_fee_settings')
    .select('inherit_org_rules, skipped_org_rule_ids').eq('event_id', eventId).maybeSingle();
  if (error) throw error;
  return {
    inheritOrgRules: data?.inherit_org_rules !== false,
    skippedOrgRuleIds: Array.isArray(data?.skipped_org_rule_ids) ? data.skipped_org_rule_ids.map(String) : [],
  };
}

export async function saveEventFeeSettings(eventId: string, orgId: string, s: EventFeeSettings): Promise<void> {
  const { error } = await supabase.from('exos_event_fee_settings').upsert({
    event_id: eventId, org_id: orgId,
    inherit_org_rules: s.inheritOrgRules,
    skipped_org_rule_ids: [...new Set(s.skippedOrgRuleIds)].slice(0, 100),
  }, { onConflict: 'event_id' });
  if (error) throw error;
}

/** Most rules in effect per event (exos_effective_fee_rules). */
export const MAX_EFFECTIVE_RULES = 10;

/**
 * The rules in effect for an event, as exos_effective_fee_rules computes them:
 * the org's active rules (unless the event opted out of all or some), then the
 * event's own active rules, at most 10. For the editor's "buyers will see"
 * preview; checkout always reads the database.
 */
export function effectiveFeeRules(orgRules: FeeRuleRow[], eventRules: FeeRuleRow[], s: EventFeeSettings): FeeRule[] {
  const order = (a: FeeRuleRow, b: FeeRuleRow) =>
    a.sortOrder - b.sortOrder || a.createdAt.localeCompare(b.createdAt) || a.id.localeCompare(b.id);
  const org = s.inheritOrgRules
    ? orgRules.filter((r) => r.active && !s.skippedOrgRuleIds.includes(r.id)).sort(order)
    : [];
  const own = eventRules.filter((r) => r.active).sort(order);
  return [...org, ...own].slice(0, MAX_EFFECTIVE_RULES).map((r) => ({
    id: r.id, rule_id: r.id, name: r.name, kind: r.kind, per: r.per, calc: r.calc,
    percent: r.percent, amount_cents: r.amountCents, cap_cents: r.capCents, taxable: r.taxable,
    recipient: r.recipient, applies_to_addons: r.appliesToAddons, tier_ids: r.tierIds,
  }));
}
