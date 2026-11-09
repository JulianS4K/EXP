// Price steps (mig 20261106130000, docs/price-steps.md; DICE PriceTier): one
// ticket type moving through prices on its own ("Early bird $20 for the
// first 100 or until Dec 1, then $25, then $30") plus a door price. The
// current step is computed in SQL (exos_tier_current_price); the storefront
// reads its price from exos_public_tiers.price and the step from
// exos_public_price_steps. The pure logic lives in
// supabase/functions/_shared/priceSteps.ts (same cases as the SQL harness).

import { supabase } from './supabase';
import {
  type CurrentPrice, capToStep, currentPriceStep, fromSqlCurrentPrice, isDoorChannel, priceStepNudge,
} from '../../supabase/functions/_shared/priceSteps.ts';

export { type CurrentPrice, capToStep, currentPriceStep, fromSqlCurrentPrice, isDoorChannel, priceStepNudge };

/** A step as the editor holds it. Money in cents. */
export interface PriceStepInput {
  id?: string;
  name: string;
  priceCents: number;
  endsAfterCount: number | null;
  /** ISO time, or null. */
  endsAt: string | null;
}

export interface PriceStep extends PriceStepInput {
  id: string;
  soldOutAt: string | null;
  sold: number;
  held: number;
}

export interface TierPriceSteps {
  doorPriceCents: number | null;
  current: CurrentPrice | null;
  steps: PriceStep[];
}

function fromSql(j: any): TierPriceSteps {
  return {
    doorPriceCents: j?.door_price_cents == null ? null : Number(j.door_price_cents),
    current: fromSqlCurrentPrice(j?.current),
    steps: ((j?.steps ?? []) as any[]).map((s) => ({
      id: s.id,
      name: s.name ?? '',
      priceCents: Number(s.price_cents) || 0,
      endsAfterCount: s.ends_after_count == null ? null : Number(s.ends_after_count),
      endsAt: s.ends_at ?? null,
      soldOutAt: s.sold_out_at ?? null,
      sold: Number(s.sold) || 0,
      held: Number(s.held) || 0,
    })),
  };
}

/** Problems with a list of steps before it's saved (the SQL checks them again), or null. */
export function priceStepsError(steps: readonly PriceStepInput[]): string | null {
  if (steps.length > 20) return 'At most 20 price steps.';
  let prevAt: number | null = null;
  for (let i = 0; i < steps.length; i++) {
    const s = steps[i];
    const n = i + 1;
    if (!Number.isInteger(s.priceCents) || s.priceCents < 0) return `Step ${n}: the price must be 0 or more.`;
    if (s.endsAfterCount != null && (!Number.isInteger(s.endsAfterCount) || s.endsAfterCount < 1)) {
      return `Step ${n}: the number sold must be a whole number, 1 or more.`;
    }
    const at = s.endsAt ? Date.parse(s.endsAt) : null;
    if (s.endsAt && Number.isNaN(at)) return `Step ${n}: pick a valid end date.`;
    const last = i === steps.length - 1;
    if (!last && s.endsAfterCount == null && at == null) return `Step ${n}: give it an end (a number sold, a date, or both).`;
    if (last && (s.endsAfterCount != null || at != null)) return 'The last step is the final price: it has no end.';
    if (at != null) {
      if (prevAt != null && at < prevAt) return `Step ${n}: it ends before an earlier step.`;
      prevAt = at;
    }
  }
  return null;
}

/** The body exos_set_price_steps takes. */
export function priceStepsPayload(steps: readonly PriceStepInput[]): Record<string, unknown>[] {
  return steps.map((s) => ({
    ...(s.id ? { id: s.id } : {}),
    name: s.name.trim(),
    price_cents: s.priceCents,
    ends_after_count: s.endsAfterCount,
    ends_at: s.endsAt,
  }));
}

/** A ticket type's steps with what each sold (org staff). */
export async function getPriceSteps(tierId: string): Promise<TierPriceSteps> {
  const { data, error } = await supabase.rpc('exos_tier_price_steps', { p_tier_id: tierId });
  if (error) throw error;
  return fromSql(data);
}

/** Replace a ticket type's steps (and, when given, its door price). Owner / manager. */
export async function savePriceSteps(
  tierId: string,
  steps: readonly PriceStepInput[],
  door?: { cents: number | null },
): Promise<TierPriceSteps> {
  const err = priceStepsError(steps);
  if (err) throw new Error(err);
  const { data, error } = await supabase.rpc('exos_set_price_steps', {
    p_tier_id: tierId,
    p_steps: priceStepsPayload(steps),
    p_door_price_cents: door ? door.cents : null,
    p_set_door: door !== undefined,
  });
  if (error) throw error;
  return fromSql(data);
}

/** The buyer's view: each public type's current step and door price (null before the migration). */
export async function listPublicPriceSteps(eventId: string): Promise<Record<string, { step: CurrentPrice | null; doorPriceCents: number | null }>> {
  const { data, error } = await supabase.from('exos_public_price_steps').select('tier_id, price_step, door_price_cents').eq('event_id', eventId);
  if (error) return {};
  const out: Record<string, { step: CurrentPrice | null; doorPriceCents: number | null }> = {};
  for (const r of (data ?? []) as any[]) {
    out[r.tier_id] = { step: fromSqlCurrentPrice(r.price_step), doorPriceCents: r.door_price_cents == null ? null : Number(r.door_price_cents) };
  }
  return out;
}
