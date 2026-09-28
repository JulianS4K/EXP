// Venue POS: tips. PURE, integer cents. Tips are the staff's money: they are
// kept apart from sales (exos_pos_payments.tip_cents), never carry tax and
// never carry the Exos fee.
//
// Tip base (OPERATOR DECISION, docs/pos.md): the presets default to the
// pre-tax subtotal, the common US bar convention; pass base 'total' to tip on
// the all-in total instead.

export const DEFAULT_TIP_PERCENTS: readonly number[] = [18, 20, 22];

/** Largest tip the register accepts without a manager, as a percent of the base. */
export const MAX_TIP_PERCENT = 100;

/** percent of base, to the cent, half up. 20% of 17.60 = 3.52. */
export function tipCents(baseCents: number, percent: number): number {
  const base = Math.round(Number(baseCents) || 0);
  const pct = Number(percent) || 0;
  if (base <= 0 || pct <= 0) return 0;
  return Math.floor((base * pct + 50) / 100);
}

export interface TipPreset {
  percent: number;
  tipCents: number;
}

/** The buttons the guest sees: 18 / 20 / 22 % of the base. */
export function tipPresets(
  amounts: { subtotalCents: number; totalCents: number },
  opts: { base?: 'subtotal' | 'total'; percents?: readonly number[] } = {},
): TipPreset[] {
  const base = opts.base === 'total' ? amounts.totalCents : amounts.subtotalCents;
  return (opts.percents ?? DEFAULT_TIP_PERCENTS).map((percent) => ({ percent, tipCents: tipCents(base, percent) }));
}

/** A typed-in tip: whole cents, not negative, and not over MAX_TIP_PERCENT of the base. */
export function validateTip(
  tip: number,
  baseCents: number,
  maxPercent: number = MAX_TIP_PERCENT,
): { ok: true; tipCents: number } | { ok: false; reason: 'not-whole-cents' | 'negative' | 'too-large' } {
  if (!Number.isInteger(tip)) return { ok: false, reason: 'not-whole-cents' };
  if (tip < 0) return { ok: false, reason: 'negative' };
  if (tip > Math.floor((Math.max(baseCents, 0) * maxPercent) / 100)) return { ok: false, reason: 'too-large' };
  return { ok: true, tipCents: tip };
}

/**
 * Pool the night's tips across staff by hours worked (a common house rule;
 * the house's own rule is an operator decision). Remainders go to the
 * longest shifts first so the pool always adds up to the cent.
 */
export function poolTips(poolCents: number, hours: Record<string, number>): Record<string, number> {
  const entries = Object.entries(hours).filter(([, h]) => h > 0);
  const out: Record<string, number> = {};
  const pool = Math.max(Math.round(poolCents), 0);
  const totalHours = entries.reduce((s, [, h]) => s + h, 0);
  if (!entries.length || totalHours <= 0) return out;
  let given = 0;
  for (const [who, h] of entries) {
    out[who] = Math.floor((pool * h) / totalHours);
    given += out[who];
  }
  const order = [...entries].sort((a, b) => b[1] - a[1] || a[0].localeCompare(b[0]));
  for (let i = 0; given < pool; i = (i + 1) % order.length) {
    out[order[i][0]] += 1;
    given += 1;
  }
  return out;
}
