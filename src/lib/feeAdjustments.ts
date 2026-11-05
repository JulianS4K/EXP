// Fee changes on a placed order (mig 20261107110000; DICE Adjustment). The log
// (exos_fee_adjustments) is append-only: a refund adds the buyer-fee part of
// the money returned, finance adds a manual change with a note, and nothing is
// ever edited or removed. Read through RLS (owner / manager / finance of the
// org); a manual change goes through exos_fee_adjustment_record, which checks
// the role, the note, the ticket and that the order's fees never go below zero.

import { supabase } from './supabase';

export type FeeAdjustmentReason = 'refund' | 'refund_reversed' | 'order_edit' | 'fee_rule' | 'manual';

export interface FeeAdjustment {
  id: string;
  sessionId: string;
  ticketId: string | null;
  reason: FeeAdjustmentReason;
  note: string | null;
  /** Signed integer cents: negative = fees went down. */
  feesChangeCents: number;
  currency: string;
  processedAt: Date | null;
}

export const FEE_REASON_LABEL: Record<FeeAdjustmentReason, string> = {
  refund: 'Refund',
  refund_reversed: 'Refund reversed',
  order_edit: 'Order change',
  fee_rule: 'Fee rule change',
  manual: 'Manual',
};

/** The largest manual change, either way, in cents (SQL: the same). */
export const MAX_MANUAL_CENTS = 10_000_000;

export function parseFeeAdjustment(r: Record<string, unknown>): FeeAdjustment {
  const reason = String(r.reason ?? 'manual') as FeeAdjustmentReason;
  return {
    id: String(r.id ?? ''),
    sessionId: String(r.session_id ?? ''),
    ticketId: typeof r.ticket_id === 'string' ? r.ticket_id : null,
    reason: reason in FEE_REASON_LABEL ? reason : 'manual',
    note: typeof r.note === 'string' && r.note ? r.note : null,
    feesChangeCents: Math.trunc(Number(r.fees_change_cents) || 0),
    currency: String(r.currency ?? 'usd'),
    processedAt: typeof r.processed_at === 'string' ? new Date(r.processed_at) : null,
  };
}

/** "-$1.50" / "+$0.25" / "+EUR 2.00": the sign always shown. */
export function formatFeeChange(cents: number, currency: string): string {
  const sign = cents < 0 ? '-' : '+';
  const v = (Math.abs(cents) / 100).toFixed(2);
  return currency.toLowerCase() === 'usd' ? `${sign}$${v}` : `${sign}${currency.toUpperCase()} ${v}`;
}

/** The order's net fee change (the sum of its rows). */
export function netFeeChange(rows: readonly FeeAdjustment[]): number {
  return rows.reduce((s, r) => s + r.feesChangeCents, 0);
}

/**
 * What finance typed ("-1.50", "2", "+0.25", "-$3") as signed cents, or null
 * when it isn't an amount (at most 2 decimals, not 0, within the limit).
 */
export function parseFeeInput(text: string): number | null {
  const m = /^\s*([+-])?\s*\$?\s*(\d{1,7})(?:\.(\d{1,2}))?\s*$/.exec(text);
  if (!m) return null;
  const cents = Number(m[2]) * 100 + Number((m[3] ?? '').padEnd(2, '0') || 0);
  const v = m[1] === '-' ? -cents : cents;
  if (v === 0 || Math.abs(v) > MAX_MANUAL_CENTS) return null;
  return v;
}

/** A key that makes a double click one adjustment. */
export function newAdjustmentKey(): string {
  const r = typeof crypto !== 'undefined' && 'randomUUID' in crypto ? crypto.randomUUID() : `${Date.now()}-${Math.random().toString(36).slice(2)}`;
  return `fee-adj:${r}`;
}

export async function listOrderFeeAdjustments(sessionId: string): Promise<FeeAdjustment[]> {
  const { data, error } = await supabase.from('exos_fee_adjustments')
    .select('id, session_id, ticket_id, reason, note, fees_change_cents, currency, processed_at')
    .eq('session_id', sessionId).order('processed_at', { ascending: true }).order('id');
  if (error) {
    // The migration isn't applied yet: no log to show.
    const code = (error as { code?: string }).code;
    if (code === '42P01' || code === 'PGRST205') return [];
    throw new Error(error.message || 'Could not load the fee changes.');
  }
  return ((data ?? []) as Record<string, unknown>[]).map(parseFeeAdjustment);
}

export async function recordFeeAdjustment(input: {
  sessionId: string; cents: number; note: string; ticketId?: string | null; key: string;
}): Promise<FeeAdjustment> {
  const { data, error } = await supabase.rpc('exos_fee_adjustment_record', {
    p_session_id: input.sessionId, p_fees_change_cents: input.cents, p_note: input.note,
    p_ticket_id: input.ticketId ?? null, p_idempotency_key: input.key,
  });
  if (error) throw new Error((error.message || 'Could not record the change.').replace(/^_?exos_\w+: /, ''));
  return parseFeeAdjustment((data ?? {}) as Record<string, unknown>);
}
