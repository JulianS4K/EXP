// Venue POS: split payments (several tenders on one order, as pretix models
// payments per order). PURE, integer cents. The SQL side refuses a tender
// larger than what's left (exos_pos_tg_payment) and marks the order paid
// when the tenders cover it.

export type PosTenderMethod = 'cash' | 'card' | 'comp';

export interface PosTender {
  method: PosTenderMethod;
  /** Applied to the order, tip excluded. */
  amountCents: number;
  tipCents?: number;
}

/** 10.00 three ways = 3.34 + 3.33 + 3.33 (the first shares take the extra cents). */
export function splitEvenly(totalCents: number, ways: number): number[] {
  const n = Math.trunc(ways);
  const total = Math.max(Math.round(totalCents), 0);
  if (n <= 0) return [];
  const base = Math.floor(total / n);
  const extra = total - base * n;
  return Array.from({ length: n }, (_, i) => base + (i < extra ? 1 : 0));
}

export interface TenderState {
  totalCents: number;
  paidCents: number;
  remainingCents: number;
  tipCents: number;
  paid: boolean;
  /** 'cash' | 'card' | 'comp', or 'split' once more than one method paid. */
  method: PosTenderMethod | 'split' | null;
  byMethod: Record<PosTenderMethod, number>;
}

/**
 * Apply tenders in order. A tender larger than what's left is refused (the
 * register gives change for cash BEFORE recording: see cashChange).
 */
export function applyTenders(
  totalCents: number,
  tenders: readonly PosTender[],
): { ok: true; state: TenderState } | { ok: false; reason: 'overpaid' | 'bad-amount' | 'comp-tip'; index: number } {
  const byMethod: Record<PosTenderMethod, number> = { cash: 0, card: 0, comp: 0 };
  let paid = 0, tips = 0;
  const methods = new Set<PosTenderMethod>();
  for (let i = 0; i < tenders.length; i++) {
    const t = tenders[i];
    if (!Number.isInteger(t.amountCents) || t.amountCents <= 0) return { ok: false, reason: 'bad-amount', index: i };
    const tip = t.tipCents ?? 0;
    if (!Number.isInteger(tip) || tip < 0) return { ok: false, reason: 'bad-amount', index: i };
    if (t.method === 'comp' && tip > 0) return { ok: false, reason: 'comp-tip', index: i };
    if (t.amountCents > totalCents - paid) return { ok: false, reason: 'overpaid', index: i };
    paid += t.amountCents;
    tips += tip;
    byMethod[t.method] += t.amountCents;
    methods.add(t.method);
  }
  const done = totalCents > 0 && paid >= totalCents;
  return {
    ok: true,
    state: {
      totalCents, paidCents: paid, remainingCents: totalCents - paid, tipCents: tips, paid: done,
      method: done ? (methods.size === 1 ? [...methods][0] : 'split') : null,
      byMethod,
    },
  };
}

/** Cash handed over vs what's due: the change to give back, or what's still short. */
export function cashChange(tenderedCents: number, dueCents: number): { applyCents: number; changeCents: number; shortCents: number } {
  const tendered = Math.max(Math.round(tenderedCents), 0);
  const due = Math.max(Math.round(dueCents), 0);
  return {
    applyCents: Math.min(tendered, due),
    changeCents: Math.max(tendered - due, 0),
    shortCents: Math.max(due - tendered, 0),
  };
}

/**
 * Split an order by who had what: each guest pays their own lines. Lines are
 * { guest, totalCents }; returns the amount per guest (adds up to the order).
 */
export function splitByGuest(lines: readonly { guest: string; totalCents: number }[]): Record<string, number> {
  const out: Record<string, number> = {};
  for (const l of lines) out[l.guest] = (out[l.guest] ?? 0) + Math.max(Math.round(l.totalCents), 0);
  return out;
}
