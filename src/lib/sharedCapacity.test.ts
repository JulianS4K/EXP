import { describe, it, expect, vi } from 'vitest';
vi.mock('./supabase', () => ({ supabase: {} }));
import { readFileSync } from 'node:fs';
import path from 'node:path';
import { quotaInputError, sharedAvailability, sharedAvailable } from './quotas';

// The same cases tests/exos/test_shared_capacity.sql (SC1) runs against
// exos_effective_available.
const CASES = JSON.parse(readFileSync(path.resolve(__dirname, '../../tests/exos/fixtures/shared_capacity_cases.json'), 'utf8')).cases as any[];

describe('shared capacity: TS / SQL parity (shared cases)', () => {
  it('has the cases', () => expect(CASES.length).toBeGreaterThanOrEqual(8));
  for (const c of CASES) {
    it(c.name, () => {
      expect(sharedAvailability(c.types, c.pools)).toEqual(c.expect);
    });
  }
});

describe('shared capacity: rules', () => {
  it('min of the type and every pool', () => {
    expect(sharedAvailable(10, [5, 2])).toBe(2);
    expect(sharedAvailable(3, [])).toBe(3);
    expect(sharedAvailable(4, [0])).toBe(0);
  });
  it('no unlimited limit; 0 closes', () => {
    expect(quotaInputError({ name: 'Room', size: null as unknown as number, closed: false, tierIds: ['a'] })).toMatch(/0 or more/);
    expect(quotaInputError({ name: 'Room', size: -1, closed: false, tierIds: ['a'] })).toMatch(/0 or more/);
    expect(quotaInputError({ name: 'Room', size: 0, closed: false, tierIds: ['a'] })).toBeNull();
    expect(quotaInputError({ name: 'Room', size: 500, closed: false, tierIds: [] })).toMatch(/ticket type/);
  });
});
