// Shared limits (pretix-style quotas, mig 20260702123030; DICE TicketPool). A
// quota caps the combined sales of the ticket types linked to it: "400
// standing, split across Early bird, GA and Door". Checkout, holds, comps,
// partner reservations and marketplace pools all respect it; a type sells only
// while every limit it is in has room (sharedAvailable). Organizers edit them
// here ("Shared limits" in the event editor); exos_event_quotas (mig
// 20260928060000) reads each one's sold / held / available. Writes go through
// the tables' RLS, and triggers keep a quota inside its event's org and ticket
// types. Since mig 20261106120000 a size is required (0 closes sales; there is
// no unlimited) and can't go below what's sold.

import { supabase } from './supabase';

export interface Quota {
  id: string;
  name: string;
  /** Required since mig 20261106120000; 0 closes sales. null only on an old row (a publish blocker). */
  size: number | null;
  closed: boolean;
  tierIds: string[];
  sold: number;
  held: number;
  /** null when unlimited. */
  available: number | null;
}

export interface QuotaInput {
  name: string;
  size: number;
  closed: boolean;
  tierIds: string[];
}

export async function listEventQuotas(eventId: string): Promise<Quota[]> {
  const { data, error } = await supabase.rpc('exos_event_quotas', { p_event_id: eventId });
  if (error) throw error;
  return ((data ?? []) as any[]).map((r) => ({
    id: r.id,
    name: r.name,
    size: r.size,
    closed: r.closed === true,
    tierIds: r.tier_ids ?? [],
    sold: Number(r.sold) || 0,
    held: Number(r.held) || 0,
    available: r.available == null ? null : Number(r.available),
  }));
}

/** Problems with a quota before it's saved, or null. */
export function quotaInputError(q: QuotaInput): string | null {
  if (!q.name.trim()) return 'Give the shared limit a name.';
  if (q.size == null || !Number.isInteger(q.size) || q.size < 0) return 'The limit must be a whole number, 0 or more (0 stops sales).';
  if (q.tierIds.length === 0) return 'Pick at least one ticket type.';
  return null;
}

/** Create (no id) or update a quota and set exactly these ticket types on it. */
export async function saveQuota(eventId: string, q: QuotaInput, id?: string): Promise<string> {
  const err = quotaInputError(q);
  if (err) throw new Error(err);
  // org_id is set from the event by a trigger; the value sent is overwritten.
  const row = { event_id: eventId, name: q.name.trim(), size: q.size, closed: q.closed };
  let quotaId = id;
  if (quotaId) {
    const { error } = await supabase.from('exos_quotas').update(row).eq('id', quotaId);
    if (error) throw error;
  } else {
    const { data: ev, error: evErr } = await supabase.from('exos_events').select('org_id').eq('id', eventId).single();
    if (evErr) throw evErr;
    const { data, error } = await supabase.from('exos_quotas').insert({ ...row, org_id: ev.org_id }).select('id').single();
    if (error) throw error;
    quotaId = data.id as string;
  }
  const { data: cur, error: curErr } = await supabase.from('exos_quota_tiers').select('tier_id').eq('quota_id', quotaId);
  if (curErr) throw curErr;
  const have = new Set((cur ?? []).map((r: { tier_id: string }) => r.tier_id));
  const want = new Set(q.tierIds);
  const add = [...want].filter((t) => !have.has(t)).map((tier_id) => ({ quota_id: quotaId, tier_id }));
  const drop = [...have].filter((t) => !want.has(t));
  if (add.length > 0) {
    const { error } = await supabase.from('exos_quota_tiers').insert(add);
    if (error) throw error;
  }
  if (drop.length > 0) {
    const { error } = await supabase.from('exos_quota_tiers').delete().eq('quota_id', quotaId).in('tier_id', drop);
    if (error) throw error;
  }
  return quotaId!;
}

export async function deleteQuota(id: string): Promise<void> {
  const { error } = await supabase.from('exos_quotas').delete().eq('id', id);
  if (error) throw error;
}

/**
 * What a ticket type can still sell: its own remaining, capped by every
 * shared limit it is in (a type sells only while each of them has room). The
 * SQL equivalent is exos_effective_available; sharedCapacity.test.ts runs the
 * same cases as tests/exos/test_shared_capacity.sql.
 */
export function sharedAvailable(typeRemaining: number, poolRemaining: readonly number[]): number {
  return Math.max(0, Math.min(typeRemaining, ...poolRemaining));
}

export interface CapacityType { key: string; capacity: number; sold: number; held?: number }
export interface CapacityPool { key: string; allocation: number; closed?: boolean; members: readonly string[] }

/** Every type's available count, given the types' counts and the pools. */
export function sharedAvailability(types: readonly CapacityType[], pools: readonly CapacityPool[]): Record<string, number> {
  const used = new Map(types.map((t) => [t.key, t.sold + (t.held ?? 0)]));
  const poolLeft = new Map(pools.map((p) => [p.key,
    p.closed || p.allocation <= 0 ? 0 : Math.max(0, p.allocation - p.members.reduce((n, k) => n + (used.get(k) ?? 0), 0))]));
  const out: Record<string, number> = {};
  for (const t of types) {
    const own = t.capacity <= 0 ? 0 : Math.max(0, t.capacity - t.sold - (t.held ?? 0));
    out[t.key] = sharedAvailable(own, pools.filter((p) => p.members.includes(t.key)).map((p) => poolLeft.get(p.key) ?? 0));
  }
  return out;
}
