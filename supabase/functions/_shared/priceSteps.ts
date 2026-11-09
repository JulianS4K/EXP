// Price steps (mig 20261106130000, docs/price-steps.md): the TypeScript
// mirror of exos_tier_current_price. The SQL function is the authority (the
// storefront, the feeds, the APIs and exos-checkout all read it); this mirror
// is for the editor's preview and the buyer's "price goes up" line, and
// src/lib/priceSteps.test.ts runs the same cases
// (tests/exos/fixtures/price_steps_cases.json) as tests/exos/test_price_steps.sql,
// so the two can't drift. Pure: imported by Deno and vitest.
//
// Rules:
//   * steps are in sort order; the current one is the first that hasn't
//     ended. A step ends at its time (at >= ends_at), when its count is used
//     (tickets sold at it + live holds on it >= ends_after_count), or once
//     latched (sold_out_at <= at: its count sold). If all ended, the last.
//   * no steps: the type's own price ('base').
//   * the door channel ('door' | 'pos' | 'box_office') sells at the door
//     price when one is set ('door'), else like online.
//   * an order is priced at one step and capped at its remaining (the
//     boundary rule: CAP, see capToStep).

export interface PriceStepRow {
  id: string;
  name?: string | null;
  priceCents: number;
  endsAfterCount?: number | null;
  /** ISO time. */
  endsAt?: string | null;
  soldOutAt?: string | null;
  /** Tickets sold at this step + live holds on it. */
  used: number;
}

export interface TierPricing {
  basePriceCents: number;
  doorPriceCents?: number | null;
  /** In sort order. */
  steps: readonly PriceStepRow[];
}

export interface CurrentPrice {
  priceCents: number;
  source: 'base' | 'step' | 'door';
  stepId: string | null;
  stepName: string | null;
  /** 1-based. */
  stepIndex: number | null;
  stepCount: number | null;
  /** null: the step has no count end. */
  stepRemaining: number | null;
  stepEndsAt: string | null;
  nextPriceCents: number | null;
  nextStepName: string | null;
  doorPriceCents: number | null;
}

export function isDoorChannel(channel: string | null | undefined): boolean {
  return ['door', 'pos', 'box_office'].includes(String(channel ?? 'online').toLowerCase());
}

const t = (iso: string | null | undefined): number | null => {
  if (iso == null) return null;
  const n = Date.parse(iso);
  return Number.isNaN(n) ? null : n;
};

/** The price a ticket type sells at, at a time, on a channel. */
export function currentPriceStep(tier: TierPricing, at: Date = new Date(), channel = 'online'): CurrentPrice {
  const door = tier.doorPriceCents ?? null;
  const empty = {
    stepId: null, stepName: null, stepIndex: null, stepRemaining: null, stepEndsAt: null,
    nextPriceCents: null, nextStepName: null, doorPriceCents: door,
  };
  if (isDoorChannel(channel) && door != null) {
    return { ...empty, priceCents: door, source: 'door', stepCount: null };
  }
  const steps = tier.steps;
  if (steps.length === 0) {
    return { ...empty, priceCents: Math.max(Math.round(tier.basePriceCents), 0), source: 'base', stepCount: 0 };
  }
  const now = at.getTime();
  let i = 0;
  for (; i < steps.length; i++) {
    const s = steps[i];
    const endsAt = t(s.endsAt);
    const soldOut = t(s.soldOutAt);
    const ended = (endsAt != null && now >= endsAt)
      || (soldOut != null && soldOut <= now)
      || (s.endsAfterCount != null && s.used >= s.endsAfterCount);
    if (!ended) break;
  }
  if (i === steps.length) i = steps.length - 1;
  const cur = steps[i];
  const next = steps[i + 1] ?? null;
  return {
    priceCents: cur.priceCents,
    source: 'step',
    stepId: cur.id,
    stepName: cur.name ? cur.name : null,
    stepIndex: i + 1,
    stepCount: steps.length,
    stepRemaining: cur.endsAfterCount == null ? null : Math.max(cur.endsAfterCount - cur.used, 0),
    stepEndsAt: cur.endsAt ?? null,
    nextPriceCents: next ? next.priceCents : null,
    nextStepName: next?.name ? next.name : null,
    doorPriceCents: door,
  };
}

/** The SQL function's jsonb answer, as a CurrentPrice (null in, null out). */
export function fromSqlCurrentPrice(j: unknown): CurrentPrice | null {
  if (!j || typeof j !== 'object') return null;
  const o = j as Record<string, unknown>;
  const num = (v: unknown): number | null => (v == null || v === '' || Number.isNaN(Number(v)) ? null : Number(v));
  const str = (v: unknown): string | null => (typeof v === 'string' && v !== '' ? v : null);
  const source = o.source === 'step' || o.source === 'door' ? o.source : 'base';
  return {
    priceCents: num(o.price_cents) ?? 0,
    source,
    stepId: str(o.step_id),
    stepName: str(o.step_name),
    stepIndex: num(o.step_index),
    stepCount: num(o.step_count),
    stepRemaining: num(o.step_remaining),
    stepEndsAt: str(o.step_ends_at),
    nextPriceCents: num(o.next_price_cents),
    nextStepName: str(o.next_step_name),
    doorPriceCents: num(o.door_price_cents),
  };
}

/**
 * The boundary rule (CAP): an order is priced at one step and can't take more
 * than the step has left. Returns the quantity allowed at this price (the
 * whole order when the step has no count end).
 */
export function capToStep(quantity: number, cp: CurrentPrice | null, partySize = 1): number {
  if (!cp || cp.stepRemaining == null) return quantity;
  return Math.max(0, Math.min(quantity, Math.floor(cp.stepRemaining / Math.max(partySize, 1))));
}

/**
 * The buyer's line about the next price, or null: "Price goes up to $25 on
 * Dec 1 or after 37 more are sold". `money` formats cents, `date` an ISO
 * time. No fee lines: the amounts are whatever the caller passes (all-in).
 */
export function priceStepNudge(
  cp: CurrentPrice | null,
  money: (cents: number) => string,
  date: (iso: string) => string,
  nextAllInCents?: number | null,
): string | null {
  if (!cp || cp.source !== 'step' || cp.nextPriceCents == null) return null;
  const when: string[] = [];
  if (cp.stepEndsAt) when.push(`on ${date(cp.stepEndsAt)}`);
  if (cp.stepRemaining != null) {
    when.push(cp.stepRemaining <= 0 ? 'now' : `after ${cp.stepRemaining} more ${cp.stepRemaining === 1 ? 'is' : 'are'} sold`);
  }
  if (when.length === 0) return null;
  const amount = money(nextAllInCents ?? cp.nextPriceCents);
  const verb = cp.nextPriceCents >= cp.priceCents ? 'goes up' : 'changes';
  return `Price ${verb} to ${amount} ${when.join(' or ')}`;
}
