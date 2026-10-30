import { describe, expect, it } from 'vitest';
import {
  TimedEntryError, entryWindowStatus, freshSlotState, openDates, parseSlotId, parseTimedEntryConfig, planSlotRelease,
  planSlotSale, slotFromId, slotRemaining, slotsForDate, type SlotState, type TimedEntryConfig,
} from './timedEntry';

const iso = (ms: number) => new Date(ms).toISOString().replace('.000Z', 'Z');
const TIERS = ['adult', 'child', 'other'];
const raw = {
  tierIds: ['adult', 'child'],
  slotMinutes: 30,
  capacity: 10,
  tierCapacity: { child: 4 },
  entryWindowMinutes: 15,
  earlyEntryMinutes: 10,
  hours: { 1: [{ open: '10:00', close: '12:00' }], 6: [{ open: '09:00', close: '10:15' }, { open: '14:00', close: '15:00' }] },
  startDate: '2026-03-02',
  endDate: '2026-03-14',
  closedDates: ['2026-03-09'],
};
const config: TimedEntryConfig = { ...parseTimedEntryConfig(raw, TIERS), version: 1 };
const NY = 'America/New_York';

describe('slot generation', () => {
  it('cuts each weekday\'s hours into whole slots', () => {
    expect(slotsForDate(config, '2026-03-02', NY).map((s) => s.id)).toEqual(['20260302T1000', '20260302T1030', '20260302T1100', '20260302T1130']);
    expect(slotsForDate(config, '2026-03-07', NY).map((s) => s.time)).toEqual(['09:00', '09:30', '14:00', '14:30']);
    expect(slotsForDate(config, '2026-03-09', NY)).toHaveLength(0);
    expect(slotsForDate(config, '2026-03-03', NY)).toHaveLength(0);
    expect(openDates(config)).toEqual(['2026-03-02', '2026-03-07', '2026-03-14']);
  });

  it('resolves slot ids against the config in the event zone', () => {
    expect(iso(slotFromId(config, '20260314T0900', NY)!.startMs)).toBe('2026-03-14T13:00:00Z');
    expect(slotFromId(config, '20260302T1015', NY)).toBeNull();
    expect(slotFromId(config, '20260316T1000', NY)).toBeNull();
    expect(parseSlotId('20260302T1030')).toEqual({ date: '2026-03-02', time: '10:30' });
    expect(parseSlotId('2026-03-02')).toBeNull();
  });

  it('computes the entry window', () => {
    const s = slotFromId(config, '20260302T1000', 'UTC')!;
    const at = (hhmm: string) => Date.parse(`2026-03-02T${hhmm}:00Z`);
    expect(['09:45', '09:50', '10:00', '10:15', '10:16'].map((t) => entryWindowStatus(s, at(t)))).toEqual(['early', 'ok', 'ok', 'ok', 'late']);
    expect(iso(slotFromId({ ...config, entryWindowMinutes: null }, '20260302T1000', 'UTC')!.entryUntilMs)).toBe('2026-03-02T10:30:00Z');
  });
});

describe('parseTimedEntryConfig', () => {
  it('refuses what the database refuses', () => {
    const bad: unknown[] = [
      { ...raw, tierIds: ['nope'] },
      { ...raw, hours: { 1: [{ open: '10:00', close: '12:00' }, { open: '11:00', close: '13:00' }] } },
      { ...raw, hours: {} },
      { ...raw, slotMinutes: 5, hours: { 1: [{ open: '00:00', close: '24:00' }] } },
      { ...raw, tierCapacity: { other: 2 } },
      { ...raw, endDate: '2027-06-01' },
    ];
    for (const b of bad) expect(() => parseTimedEntryConfig(b, TIERS)).toThrow(TimedEntryError);
  });
});

describe('slot capacity', () => {
  it('plans sales and releases like the fulfillment counter', () => {
    let s: SlotState = freshSlotState(config);
    expect([slotRemaining(s), slotRemaining(s, 'child'), slotRemaining(s, 'adult')]).toEqual([10, 4, 10]);
    const p = planSlotSale(s, 'child', 4);
    expect(p.ok).toBe(true);
    if (p.ok) s = p.next;
    expect(planSlotSale(s, 'child', 1)).toEqual({ ok: false, remaining: 0, reason: 'slot_full' });
    expect(slotRemaining(s, 'adult')).toBe(6);
    s = planSlotRelease(s, 'child', 1);
    expect(slotRemaining(s, 'child')).toBe(1);
    expect(slotRemaining({ ...s, held: 7 }, 'adult')).toBe(0);
    expect(planSlotSale({ ...s, closed: true }, 'adult', 1)).toEqual({ ok: false, remaining: 0, reason: 'slot_closed' });
    expect(planSlotRelease(freshSlotState(config), 'adult', 3).sold).toBe(0);
  });

  // Buyers race for one slot against a serializable store (read, delay,
  // commit only if nothing changed, else retry), each running planSlotSale
  // as _exos_slot_commit does under the slot row lock.
  class SlotStore {
    version = 0;
    state: SlotState | null = null;
    oversold = false;
    async transact(fn: (s: SlotState) => { write: SlotState | null; result: string }): Promise<string> {
      for (let attempt = 0; attempt < 50; attempt++) {
        const seen = this.version;
        const read = this.state ?? freshSlotState(config);
        await new Promise((r) => setTimeout(r, Math.random() * 2));
        const { write, result } = fn(read);
        if (this.version !== seen) continue;
        if (write) {
          this.state = write;
          this.version++;
          if (write.sold + write.held > write.capacity) this.oversold = true;
          for (const [tier, n] of Object.entries(write.tierSold ?? {})) {
            const cap = write.tierCapacity?.[tier];
            if (typeof cap === 'number' && n > cap) this.oversold = true;
          }
        }
        return result;
      }
      return 'gave_up';
    }
  }
  const sell = (tier: string, qty: number) => (s: SlotState) => {
    const plan = planSlotSale(s, tier, qty);
    return plan.ok ? { write: plan.next, result: 'sold' } : { write: null, result: 'refunded' };
  };

  it('never oversells, and refunds give places back', async () => {
    for (let trial = 0; trial < 15; trial++) {
      const store = new SlotStore();
      const buyers = Array.from({ length: 14 }, (_, i) => ({ tier: i % 3 === 0 ? 'child' : 'adult', qty: 1 + (i % 2) }));
      const results = await Promise.all(buyers.map((b) => store.transact(sell(b.tier, b.qty))));
      const s = store.state!;
      expect(store.oversold).toBe(false);
      expect(results).not.toContain('gave_up');
      expect(s.sold).toBe(buyers.reduce((n, b, i) => n + (results[i] === 'sold' ? b.qty : 0), 0));
      expect(s.sold).toBeLessThanOrEqual(config.capacity);
      expect(s.sold).toBeGreaterThanOrEqual(config.capacity - 1);
      expect(s.tierSold?.child ?? 0).toBeLessThanOrEqual(4);
      const before = s.sold;
      await store.transact((st) => ({ write: planSlotRelease(st, 'adult', 2), result: 'ok' }));
      const late = await Promise.all([1, 2, 3].map(() => store.transact(sell('adult', 1))));
      expect(late.filter((r) => r === 'sold')).toHaveLength(Math.min(3, config.capacity - (before - 2)));
      expect(store.oversold).toBe(false);
    }
  });
});
