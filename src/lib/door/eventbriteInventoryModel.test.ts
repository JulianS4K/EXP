import { describe, expect, it } from 'vitest';
import { mappingLine, parseInventoryStatus, type EbMapping } from './eventbriteInventoryModel';

const base: EbMapping = {
  ebTicketClassId: '101', ebTicketClassName: 'GA', tierId: 't1', ebSold: 10, ebCapacity: 50, targetCapacity: 96,
  pushedCapacity: null, pushedAt: null, plannedAt: null, oversold: 0, lastReadAt: '2026-10-13T20:00:00Z', lastError: null,
};

describe('parseInventoryStatus', () => {
  it('maps the RPC and drops malformed rows', () => {
    const s = parseInventoryStatus({
      linked: true, writes_enabled: false, can_switch: true,
      tiers: [{ id: 't1', name: 'GA', capacity: 100, sold: 10 }, { name: 'no id' }],
      mappings: [{ eb_ticket_class_id: '101', eb_ticket_class_name: 'GA', tier_id: 't1', eb_sold: 10, eb_capacity: 50,
                   target_capacity: 96, oversold: 2, last_read_at: 'x' }, { tier_id: 't1' }],
    });
    expect(s.linked && s.canSwitch && !s.writesEnabled).toBe(true);
    expect(s.tiers).toEqual([{ id: 't1', name: 'GA', capacity: 100, sold: 10 }]);
    expect(s.mappings).toHaveLength(1);
    expect(s.mappings[0]).toMatchObject({ ebTicketClassId: '101', tierId: 't1', targetCapacity: 96, oversold: 2, pushedCapacity: null });
    expect(parseInventoryStatus(null)).toEqual({ linked: false, writesEnabled: false, canSwitch: false, tiers: [], mappings: [] });
  });
});

describe('mappingLine', () => {
  it('says what would change while sending is off', () => {
    expect(mappingLine(base, false)).toBe('10 sold on Eventbrite · would set its capacity 50 → 96 (86 left; not sent: sending is off)');
  });
  it('says what it sets when on, and when it is in step', () => {
    expect(mappingLine(base, true)).toBe('10 sold on Eventbrite · setting its capacity to 96 (86 left)');
    expect(mappingLine({ ...base, ebCapacity: 96 }, true)).toBe('10 sold on Eventbrite · 86 left to sell there · in step');
  });
  it('shows the error, or waits for the first read', () => {
    expect(mappingLine({ ...base, lastError: 'ticket class not found on Eventbrite' }, true)).toBe('ticket class not found on Eventbrite');
    expect(mappingLine({ ...base, lastReadAt: null }, true)).toBe('Counts after the next sync.');
  });
});
