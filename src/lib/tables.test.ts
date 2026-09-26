import { describe, expect, it } from 'vitest';
import {
  BLANK_TABLE_DRAFT,
  admissionsForTier,
  depositPerPerson,
  indexTablesByTicket,
  labelTaken,
  mapDoorTable,
  normalizeTableLabel,
  rowToTableDraft,
  suggestNextLabel,
  tableDraftToRow,
  tableSummary,
  toCents,
  validateTableDraft,
} from './tables';

const draft = (p: Partial<typeof BLANK_TABLE_DRAFT>) => ({ ...BLANK_TABLE_DRAFT, isTable: true, ...p });

describe('tables model', () => {
  it('converts money to cents', () => {
    expect(toCents('')).toBeNull();
    expect(toCents('12.5')).toBe(1250);
    expect(toCents('1000')).toBe(100000);
    expect(Number.isNaN(toCents('-1') as number)).toBe(true);
    expect(Number.isNaN(toCents('abc') as number)).toBe(true);
  });

  it('validates a table draft', () => {
    expect(validateTableDraft(BLANK_TABLE_DRAFT, 'GA')).toBeNull();
    expect(validateTableDraft(draft({ partySize: '6' }), 'Booth')).toBeNull();
    expect(validateTableDraft(draft({ partySize: '' }), 'Booth')).toMatch(/party size/);
    expect(validateTableDraft(draft({ partySize: '51' }), 'Booth')).toMatch(/party size/);
    expect(validateTableDraft(draft({ partySize: '2.5' }), 'Booth')).toMatch(/party size/);
    expect(validateTableDraft(draft({ partySize: '6', minSpend: '-5' }), 'Booth')).toMatch(/minimum spend/);
    expect(validateTableDraft(draft({ partySize: '6', sectionLabel: 'x'.repeat(61) }), 'Booth')).toMatch(/section/);
  });

  it('round-trips a draft through the row shape', () => {
    const row = tableDraftToRow(draft({ partySize: '8', minSpend: '1500', sectionLabel: ' Mezz ' }));
    expect(row).toEqual({ kind: 'table', party_size: 8, min_spend_cents: 150000, section_label: 'Mezz' });
    expect(rowToTableDraft(row)).toEqual({ isTable: true, partySize: '8', minSpend: '1500', sectionLabel: 'Mezz' });
    expect(tableDraftToRow(BLANK_TABLE_DRAFT)).toEqual({ kind: 'standard', party_size: null, min_spend_cents: null, section_label: null });
    expect(rowToTableDraft({ kind: 'standard' })).toEqual(BLANK_TABLE_DRAFT);
    expect(rowToTableDraft(null)).toEqual(BLANK_TABLE_DRAFT);
  });

  it('counts admissions for the house total', () => {
    expect(admissionsForTier(10, BLANK_TABLE_DRAFT)).toBe(10);
    expect(admissionsForTier(5, draft({ partySize: '6' }))).toBe(30);
    expect(admissionsForTier(5, draft({ partySize: '' }))).toBe(5);
  });

  it('summarizes a table for buyers and the door', () => {
    expect(tableSummary({ partySize: 6, minSpendCents: 100000, sectionLabel: 'Mezzanine' })).toBe(
      'Table for 6 · $1,000 min spend · Mezzanine',
    );
    expect(tableSummary({ partySize: 4, minSpendCents: null, sectionLabel: null })).toBe('Table for 4');
    expect(tableSummary({ partySize: 4, minSpendCents: 12550, sectionLabel: null })).toBe('Table for 4 · $125.50 min spend');
    expect(depositPerPerson(300, 4)).toBe(75);
    expect(depositPerPerson(100, 3)).toBe(33.33);
  });

  it('normalizes and suggests labels', () => {
    expect(normalizeTableLabel('  Table   12 ')).toBe('Table 12');
    expect(normalizeTableLabel('   ')).toBeNull();
    expect(() => normalizeTableLabel('x'.repeat(41))).toThrow();
    expect(suggestNextLabel([])).toBe('Table 1');
    expect(suggestNextLabel(['Table 3', null, 'Booth 7', 'VIP'])).toBe('Table 8');
    expect(labelTaken('table 12', ['Table 12 '])).toBe(true);
    expect(labelTaken('Table 1', ['Table 12'])).toBe(false);
  });

  it('indexes door tables by ticket id', () => {
    const t = mapDoorTable({
      booking_id: 'b1', label: 'Table 12', tier_name: 'Booth', section_label: 'Floor',
      party_size: 2, min_spend_cents: 50000, ticket_ids: ['t1', 't2'],
    });
    const idx = indexTablesByTicket([t]);
    expect(idx.t1.label).toBe('Table 12');
    expect(idx.t2.minSpendCents).toBe(50000);
    expect(idx.t3).toBeUndefined();
  });
});
