// Nightlife table packages (mig 20260926050000) — PURE model. A table tier's
// capacity and sold count are in TABLES; each table admits party_size people
// and mints that many tickets to the host in one order. The price is the
// deposit per table; the minimum spend is informational (buyer + door).
// No Supabase import so it unit-tests without a client (RPCs: ./tablesApi).

export type TierKind = 'standard' | 'table';

export const MAX_PARTY_SIZE = 50;
export const MAX_TABLE_LABEL = 40;
export const MAX_SECTION_LABEL = 60;

/** Editor draft: plain strings so empty inputs stay empty. minSpend is in major units. */
export interface TableTierDraft {
  isTable: boolean;
  partySize: string;
  minSpend: string;
  sectionLabel: string;
}

export const BLANK_TABLE_DRAFT: TableTierDraft = { isTable: false, partySize: '', minSpend: '', sectionLabel: '' };

/** The exos_ticket_tiers columns the editor writes. */
export interface TableTierRow {
  kind: TierKind;
  party_size: number | null;
  min_spend_cents: number | null;
  section_label: string | null;
}

export interface TableFacts {
  partySize: number;
  minSpendCents: number | null;
  sectionLabel: string | null;
}

/** "12.50" → 1250; blank → null; junk / negative → NaN. */
export function toCents(value: string): number | null {
  const s = (value ?? '').trim();
  if (s === '') return null;
  const n = Number(s);
  if (!Number.isFinite(n) || n < 0) return NaN;
  return Math.round(n * 100);
}

export function validateTableDraft(d: TableTierDraft, tierName: string): string | null {
  if (!d.isTable) return null;
  const p = Number(d.partySize);
  if (!Number.isInteger(p) || p < 1 || p > MAX_PARTY_SIZE) {
    return `Tier "${tierName}": party size must be a whole number from 1 to ${MAX_PARTY_SIZE}.`;
  }
  const c = toCents(d.minSpend);
  if (c !== null && (Number.isNaN(c) || c > 100_000_000)) {
    return `Tier "${tierName}": minimum spend must be a positive amount.`;
  }
  if (d.sectionLabel.trim().length > MAX_SECTION_LABEL) {
    return `Tier "${tierName}": keep the section under ${MAX_SECTION_LABEL} characters.`;
  }
  return null;
}

export function tableDraftToRow(d: TableTierDraft): TableTierRow {
  if (!d.isTable) return { kind: 'standard', party_size: null, min_spend_cents: null, section_label: null };
  const c = toCents(d.minSpend);
  return {
    kind: 'table',
    party_size: Number(d.partySize),
    min_spend_cents: c === null || Number.isNaN(c) ? null : c,
    section_label: d.sectionLabel.trim() || null,
  };
}

export function rowToTableDraft(row: Partial<TableTierRow> | null | undefined): TableTierDraft {
  if (!row || row.kind !== 'table') return { ...BLANK_TABLE_DRAFT };
  return {
    isTable: true,
    partySize: row.party_size != null ? String(row.party_size) : '',
    minSpend: row.min_spend_cents != null ? String(row.min_spend_cents / 100) : '',
    sectionLabel: row.section_label ?? '',
  };
}

/** Admissions a tier can put in the room: tables x party size (1 per ticket otherwise). */
export function admissionsForTier(capacity: number, d: TableTierDraft | null | undefined): number {
  const cap = Number(capacity) || 0;
  if (!d?.isTable) return cap;
  const p = Number(d.partySize);
  return cap * (Number.isInteger(p) && p > 0 ? p : 1);
}

export function formatCents(cents: number, currency = 'USD'): string {
  const code = (currency || 'USD').toUpperCase();
  const major = cents / 100;
  try {
    return new Intl.NumberFormat('en-US', {
      style: 'currency',
      currency: code,
      maximumFractionDigits: cents % 100 === 0 ? 0 : 2,
    }).format(major);
  } catch {
    return `${major.toFixed(2)} ${code}`;
  }
}

/** One line for buyers and the door: "Table for 6 · $1,000 min spend · Mezzanine". */
export function tableSummary(f: TableFacts, currency = 'USD'): string {
  const parts = [`Table for ${f.partySize}`];
  if (f.minSpendCents != null && f.minSpendCents > 0) parts.push(`${formatCents(f.minSpendCents, currency)} min spend`);
  if (f.sectionLabel) parts.push(f.sectionLabel);
  return parts.join(' · ');
}

/** Deposit per person, for the buyer's "that's $X each" line. */
export function depositPerPerson(pricePerTable: number, partySize: number): number {
  if (!(partySize > 0)) return pricePerTable;
  return Math.round((pricePerTable / partySize) * 100) / 100;
}

/** Trimmed label, or null to clear; throws on an over-long one. */
export function normalizeTableLabel(raw: string): string | null {
  const s = (raw ?? '').trim().replace(/\s+/g, ' ');
  if (!s) return null;
  if (s.length > MAX_TABLE_LABEL) throw new Error(`Keep the table name under ${MAX_TABLE_LABEL} characters.`);
  return s;
}

/** Next "Table N" after the highest number already used. */
export function suggestNextLabel(existing: (string | null | undefined)[]): string {
  let max = 0;
  for (const l of existing) {
    const m = /(\d+)\s*$/.exec(l ?? '');
    if (m) max = Math.max(max, Number(m[1]));
  }
  return `Table ${max + 1}`;
}

/** Case-insensitive duplicate check, mirroring the server's unique index. */
export function labelTaken(label: string, others: (string | null | undefined)[]): boolean {
  const k = label.trim().toLowerCase();
  return others.some((o) => (o ?? '').trim().toLowerCase() === k);
}

/** A table as the door downloads it (exos_event_door_extras). */
export interface DoorTable {
  bookingId: string;
  label: string | null;
  tierName: string | null;
  sectionLabel: string | null;
  partySize: number;
  minSpendCents: number | null;
  ticketIds: string[];
}

export function mapDoorTable(r: any): DoorTable {
  return {
    bookingId: String(r.booking_id),
    label: r.label ?? null,
    tierName: r.tier_name ?? null,
    sectionLabel: r.section_label ?? null,
    partySize: Number(r.party_size) || 1,
    minSpendCents: r.min_spend_cents != null ? Number(r.min_spend_cents) : null,
    ticketIds: Array.isArray(r.ticket_ids) ? r.ticket_ids.map(String) : [],
  };
}

export function indexTablesByTicket(tables: DoorTable[]): Record<string, DoorTable> {
  const out: Record<string, DoorTable> = {};
  for (const t of tables) for (const id of t.ticketIds) out[id] = t;
  return out;
}
