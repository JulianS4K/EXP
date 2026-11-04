// POS drawer recount (mig 20261104200000, exos_pos_recount_drawer). Pure:
// what the drawer report shows and whether the Recount button is offered.
// The SQL is the rule (owner / manager, closed, 7 days, 3 recounts, a reason,
// not after a final settlement).

export const MAX_RECOUNTS = 3;
export const RECOUNT_WINDOW_MS = 7 * 24 * 60 * 60 * 1000;

export interface DrawerRow {
  id: string;
  status: 'open' | 'closed';
  open_float_cents: number;
  expected_cents: number | null;
  counted_cents: number | null;
  variance_cents: number | null;
  closed_at: string | null;
  note?: string | null;
}

export interface RecountRow {
  id: string;
  session_id: string;
  recount_no: number;
  previous_counted_cents: number;
  previous_variance_cents: number;
  counted_cents: number;
  variance_cents: number;
  reason: string;
  created_at: string;
}

export type RecountBlock = 'role' | 'open' | 'window' | 'limit' | 'settled' | null;

/** Why a recount can't be offered (null = it can). */
export function recountBlock(
  d: Pick<DrawerRow, 'status' | 'closed_at'>, recounts: number, opts: { canAct: boolean; settled: boolean; now?: number },
): RecountBlock {
  if (!opts.canAct) return 'role';
  if (d.status !== 'closed' || !d.closed_at) return 'open';
  if (opts.settled) return 'settled';
  if (recounts >= MAX_RECOUNTS) return 'limit';
  const closed = Date.parse(d.closed_at);
  if (!Number.isFinite(closed) || (opts.now ?? Date.now()) - closed > RECOUNT_WINDOW_MS) return 'window';
  return null;
}

export const RECOUNT_BLOCK_TEXT: Record<Exclude<RecountBlock, null>, string> = {
  role: 'Owners and managers recount drawers.',
  open: 'Close the drawer first.',
  window: 'Drawers can be recounted for 7 days after closing.',
  limit: `Recounted ${MAX_RECOUNTS} times already.`,
  settled: 'The settlement is final.',
};

/** A typed amount ("123.45", "$1,000") in cents; null when it isn't one. */
export function parseCash(text: string): number | null {
  const t = text.trim().replace(/^\$/, '').replace(/,/g, '');
  if (!/^\d{1,7}(\.\d{1,2})?$/.test(t)) return null;
  const [whole, frac = ''] = t.split('.');
  return Number(whole) * 100 + Number((frac + '00').slice(0, 2));
}

/** The variance a recount would record, against the expected cash stored at close. */
export function recountVariance(expectedCents: number | null, countedCents: number): number | null {
  return expectedCents === null ? null : countedCents - expectedCents;
}

/** A reason the SQL takes (3-500 characters after trimming). */
export function validReason(text: string): boolean {
  const t = text.trim();
  return t.length >= 3 && t.length <= 500;
}

/** Recounts of one drawer, oldest first. */
export function recountsFor(rows: readonly RecountRow[], sessionId: string): RecountRow[] {
  return rows.filter((r) => r.session_id === sessionId).sort((a, b) => a.recount_no - b.recount_no);
}
