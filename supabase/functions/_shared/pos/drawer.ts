// Venue POS: cash drawer reconciliation. PURE, integer cents. Same math as
// public.exos_pos_close_drawer (mig 20260929074000):
//   expected = open float + cash taken into the drawer (amount + cash tips)
//              - cash paid out of it (paid-outs are not in the SQL scaffold yet)
//   variance = counted - expected   (negative = short, positive = over)

/** US bills and coins, in cents. */
export const USD_DENOMINATIONS: readonly number[] = [10000, 5000, 2000, 1000, 500, 200, 100, 25, 10, 5, 1];

/** {"2000": 5, "100": 12} -> 11200. Throws on a bad denomination or count (same rule as the SQL). */
export function countDenominations(counts: Record<string, number>): number {
  let sum = 0;
  for (const [denom, count] of Object.entries(counts)) {
    if (!/^[1-9][0-9]{0,5}$/.test(denom)) throw new Error(`bad denomination: ${denom}`);
    if (!Number.isInteger(count) || count < 0 || count > 999999) throw new Error(`bad count for ${denom}: ${count}`);
    sum += Number(denom) * count;
  }
  return sum;
}

export interface DrawerInput {
  openFloatCents: number;
  cashPayments: readonly { amountCents: number; tipCents?: number }[];
  paidOutCents?: number;
  countedCents: number;
}

export interface DrawerReconciliation {
  cashTakenCents: number;
  expectedCents: number;
  countedCents: number;
  varianceCents: number;
  status: 'balanced' | 'over' | 'short';
}

/**
 * Reconcile at close. `toleranceCents` is how far off still counts as
 * balanced (OPERATOR DECISION, docs/pos.md; 0 = to the cent).
 */
export function reconcileDrawer(d: DrawerInput, toleranceCents = 0): DrawerReconciliation {
  const taken = d.cashPayments.reduce((s, p) => s + p.amountCents + (p.tipCents ?? 0), 0);
  const expected = d.openFloatCents + taken - (d.paidOutCents ?? 0);
  const variance = d.countedCents - expected;
  const status = Math.abs(variance) <= Math.max(toleranceCents, 0) ? 'balanced' : variance > 0 ? 'over' : 'short';
  return { cashTakenCents: taken, expectedCents: expected, countedCents: d.countedCents, varianceCents: variance, status };
}

/** How much to drop to the safe so the drawer goes back to its float. */
export function safeDropCents(countedCents: number, keepFloatCents: number): number {
  return Math.max(countedCents - keepFloatCents, 0);
}
