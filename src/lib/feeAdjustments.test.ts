import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { describe, expect, it, vi } from 'vitest';
vi.mock('./supabase', () => ({ supabase: {} }));
import {
  FEE_REASON_LABEL, MAX_MANUAL_CENTS, formatFeeChange, netFeeChange, newAdjustmentKey, parseFeeAdjustment, parseFeeInput,
} from './feeAdjustments';

const migration = readFileSync(resolve(__dirname, '../../supabase/migrations/20261107110000_exos_dice_gaps_6.sql'), 'utf8');

describe('fee changes (mig 20261107110000)', () => {
  it('every reason the table allows has a label, and no other', () => {
    const m = /exos_fee_adjustments_reason_chk CHECK \(reason IN \(([^)]*)\)\)/.exec(migration)!;
    const sql = m[1].match(/'([a-z_]+)'/g)!.map((x) => x.slice(1, -1));
    expect(Object.keys(FEE_REASON_LABEL).sort()).toEqual([...sql].sort());
  });
  it('the manual limit is the SQL one', () => {
    expect(migration).toContain(`abs(p_cents) > ${MAX_MANUAL_CENTS}`);
  });
  it('reads typed amounts as signed cents', () => {
    expect(parseFeeInput('-1.50')).toBe(-150);
    expect(parseFeeInput('2')).toBe(200);
    expect(parseFeeInput('+0.25')).toBe(25);
    expect(parseFeeInput(' -$3 ')).toBe(-300);
    expect(parseFeeInput('0.5')).toBe(50);
    for (const bad of ['', '0', '0.00', '1.234', 'abc', '--1', '100000.01', '1,50']) expect(parseFeeInput(bad)).toBeNull();
  });
  it('formats with the sign', () => {
    expect(formatFeeChange(-150, 'usd')).toBe('-$1.50');
    expect(formatFeeChange(25, 'usd')).toBe('+$0.25');
    expect(formatFeeChange(-200, 'eur')).toBe('-EUR 2.00');
  });
  it('parses rows and sums them', () => {
    const rows = [
      parseFeeAdjustment({ id: 'a', session_id: 's', reason: 'refund', fees_change_cents: -100, currency: 'usd', processed_at: '2026-11-07T10:00:00Z' }),
      parseFeeAdjustment({ id: 'b', session_id: 's', reason: 'refund_reversed', fees_change_cents: '40', note: 'bank', ticket_id: 't1' }),
      parseFeeAdjustment({ id: 'c', session_id: 's', reason: 'something-new', fees_change_cents: -5 }),
    ];
    expect(rows[0].processedAt?.toISOString()).toBe('2026-11-07T10:00:00.000Z');
    expect(rows[1]).toMatchObject({ feesChangeCents: 40, note: 'bank', ticketId: 't1', reason: 'refund_reversed' });
    expect(rows[2].reason).toBe('manual');
    expect(netFeeChange(rows)).toBe(-65);
  });
  it('idempotency keys fit the SQL rule', () => {
    const k = newAdjustmentKey();
    expect(k).toMatch(/^[A-Za-z0-9:_.-]{8,200}$/);
    expect(newAdjustmentKey()).not.toBe(k);
  });
});
