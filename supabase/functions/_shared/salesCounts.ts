// Sales counts from other platforms (mig 20261030120000): the CSV column
// mapping and the per-ticket-type sums, shared by the event report's import
// (src/components/SalesCountsPanel.tsx via src/lib/salesCounts.ts) and exos-api
// (POST /v1/events/:id/sales-counts/import), so both read a file the same way.
// The database re-validates and re-sums what this produces
// (_exos_sales_count_tiers).
//
// A sales export is either one row per ticket type (DICE / RA summaries) or
// one row per order (Posh, Shotgun): rows are always ADDED UP per ticket type,
// so either shape gives the right totals, and importing the same file again
// gives the same numbers (the row is replaced, never incremented).
//
// Pure TypeScript, no imports: vitest and Deno both load it.

export const PLATFORMS = [
  'eventbrite', 'dice', 'ra', 'posh', 'shotgun', 'ticketmaster', 'axs', 'seetickets',
  'tixr', 'etix', 'partiful', 'luma', 'other',
] as const;
export type Platform = (typeof PLATFORMS)[number];

/** Same names the database stores as the entry's label. */
export const PLATFORM_LABELS: Record<Platform, string> = {
  eventbrite: 'Eventbrite',
  dice: 'DICE',
  ra: 'Resident Advisor',
  posh: 'Posh',
  shotgun: 'Shotgun',
  ticketmaster: 'Ticketmaster',
  axs: 'AXS',
  seetickets: 'See Tickets',
  tixr: 'Tixr',
  etix: 'Etix',
  partiful: 'Partiful',
  luma: 'Luma',
  other: 'Other platform',
};

export function isPlatform(s: unknown): s is Platform {
  return typeof s === 'string' && (PLATFORMS as readonly string[]).includes(s);
}

export const MAX_IMPORT_BYTES = 2 * 1024 * 1024;
export const MAX_IMPORT_ROWS = 2000;
export const MAX_TIERS = 50;
export const MAX_ENTRIES = 20;
export const NO_TIER = 'General';

export const SALES_FIELDS = ['tier', 'sold', 'gross', 'price', 'capacity', 'currency', 'event', 'status'] as const;
export type SalesField = (typeof SALES_FIELDS)[number];
/** Our field → the column index in the file. */
export type SalesMapping = Partial<Record<SalesField, number>>;

export const FIELD_LABELS: Record<SalesField, string> = {
  tier: 'Ticket type',
  sold: 'Tickets sold',
  gross: 'Gross (total)',
  price: 'Price (each)',
  capacity: 'Capacity',
  currency: 'Currency',
  event: 'Event',
  status: 'Order status',
};

const norm = (h: string) => h.toLowerCase().replace(/[^a-z0-9#]+/g, ' ').trim();

// Header names, most specific first.
const SYNONYMS: Record<SalesField, string[]> = {
  tier: ['ticket type', 'ticket tier', 'tier', 'ticket name', 'ticket class', 'price level', 'ticket', 'type', 'product'],
  sold: ['tickets sold', 'quantity sold', 'qty sold', 'sold', 'number of tickets', 'tickets', 'quantity', 'qty', 'count'],
  gross: ['gross sales', 'gross revenue', 'gross', 'revenue', 'total paid', 'amount paid', 'sales total', 'total', 'amount', 'face value total'],
  price: ['ticket price', 'unit price', 'face value', 'price'],
  capacity: ['capacity', 'allocation', 'total tickets', 'inventory', 'quantity total', 'cap'],
  currency: ['currency', 'currency code', 'ccy', 'cur'],
  event: ['event name', 'event title', 'event', 'show', 'show name', 'event id'],
  status: ['order status', 'status', 'payment status', 'ticket status'],
};

/** Best guess of which column holds what, from the header row. */
export function suggestSalesMapping(header: string[]): SalesMapping {
  const h = header.map(norm);
  const used = new Set<number>();
  const out: SalesMapping = {};
  for (const field of SALES_FIELDS) {
    for (const name of SYNONYMS[field]) {
      const i = h.findIndex((x, idx) => !used.has(idx) && x === name);
      if (i >= 0) {
        out[field] = i;
        used.add(i);
        break;
      }
    }
  }
  return out;
}

/** Best guess at the platform from the file name. */
export function guessPlatform(fileName: string): Platform {
  const f = fileName.toLowerCase();
  if (f.includes('eventbrite')) return 'eventbrite';
  if (f.includes('dice')) return 'dice';
  if (f.includes('resident') || /(^|[^a-z])ra([^a-z]|$)/.test(f)) return 'ra';
  if (f.includes('posh')) return 'posh';
  if (f.includes('shotgun')) return 'shotgun';
  if (f.includes('ticketmaster')) return 'ticketmaster';
  if (f.includes('axs')) return 'axs';
  if (f.includes('seetickets') || f.includes('see tickets')) return 'seetickets';
  if (f.includes('tixr')) return 'tixr';
  if (f.includes('etix')) return 'etix';
  if (f.includes('partiful')) return 'partiful';
  if (f.includes('luma')) return 'luma';
  return 'other';
}

/** "1,234", "$1,234.50", "1.234,50", "€ 12,50", "(12)" → a number, or null. */
export function parseAmount(raw: string | undefined | null): number | null {
  if (raw === undefined || raw === null) return null;
  let s = String(raw).trim();
  if (!s) return null;
  const negative = /^\(.*\)$/.test(s) || /^-/.test(s.replace(/^[^0-9-]+/, ''));
  s = s.replace(/[^0-9.,]/g, '');
  if (!s || !/[0-9]/.test(s)) return null;
  const lastComma = s.lastIndexOf(',');
  const lastDot = s.lastIndexOf('.');
  if (lastComma >= 0 && lastDot >= 0) {
    s = lastComma > lastDot ? s.replace(/\./g, '').replace(',', '.') : s.replace(/,/g, '');
  } else if (lastComma >= 0) {
    // "12,50" is a decimal; "1,234" is thousands.
    s = /,\d{1,2}$/.test(s) && (s.match(/,/g) ?? []).length === 1 ? s.replace(',', '.') : s.replace(/,/g, '');
  } else if ((s.match(/\./g) ?? []).length > 1) {
    s = s.replace(/\./g, '');
  }
  const n = Number(s);
  if (!Number.isFinite(n)) return null;
  return negative ? -n : n;
}

/** Major units → minor units (cents), rounded. */
export function toCents(major: number): number {
  return Math.round(major * 100);
}

/** Rows whose status says the sale didn't stand are left out. */
const VOID_STATUS = /refund|cancel|void|declin|fail|chargeback|revok/i;

export interface SalesTier {
  name: string;
  sold: number;
  gross_cents: number;
  capacity: number | null;
}

export interface SalesIssue {
  /** 1-based line in the file (the header is line 1). */
  row: number;
  field?: SalesField;
  message: string;
}

export interface SalesPlan {
  tiers: SalesTier[];
  sold: number;
  grossCents: number;
  capacity: number | null;
  currency: string;
  /** Data rows counted. */
  rows: number;
  /** Rows of other events (event column + filter). */
  otherEvents: number;
  /** Rows left out for a refunded / cancelled status. */
  voided: number;
  errors: SalesIssue[];
  warnings: SalesIssue[];
}

export interface SalesPlanOptions {
  /** The import's currency (3 letters), used when there is no currency column or a cell is empty. */
  currency: string;
  /** With an event column: only rows whose event cell equals this (trimmed, any case). */
  event?: string | null;
}

/** Distinct values of the event column (for "which event in this file is this one"). */
export function eventValues(table: string[][], mapping: SalesMapping): string[] {
  const i = mapping.event;
  if (i === undefined) return [];
  const seen = new Map<string, string>();
  for (const r of table.slice(1)) {
    const v = (r[i] ?? '').trim();
    if (v && !seen.has(v.toLowerCase())) seen.set(v.toLowerCase(), v);
  }
  return [...seen.values()];
}

/**
 * Parsed CSV (header first) + mapping → per-ticket-type sums. Nothing is
 * imported while `errors` is non-empty.
 */
export function planSalesImport(table: string[][], mapping: SalesMapping, opts: SalesPlanOptions): SalesPlan {
  const errors: SalesIssue[] = [];
  const warnings: SalesIssue[] = [];
  const defaultCurrency = (opts.currency || '').trim().toUpperCase();
  const plan: SalesPlan = {
    tiers: [], sold: 0, grossCents: 0, capacity: null, currency: defaultCurrency,
    rows: 0, otherEvents: 0, voided: 0, errors, warnings,
  };
  if (!/^[A-Z]{3}$/.test(defaultCurrency)) errors.push({ row: 0, field: 'currency', message: 'Choose the currency (a 3-letter code).' });
  const header = table[0] ?? [];
  for (const [field, idx] of Object.entries(mapping) as [SalesField, number | undefined][]) {
    if (idx !== undefined && (idx < 0 || idx >= header.length)) {
      errors.push({ row: 1, field, message: `${FIELD_LABELS[field]}: that column is not in the file.` });
    }
  }
  if (mapping.sold === undefined) errors.push({ row: 1, field: 'sold', message: 'Pick the column with the number of tickets sold.' });
  if (table.length < 2) errors.push({ row: 1, message: 'The file has no data rows.' });
  if (table.length - 1 > MAX_IMPORT_ROWS) {
    errors.push({ row: MAX_IMPORT_ROWS + 2, message: `More than ${MAX_IMPORT_ROWS} rows; split the file.` });
  }
  if (errors.length) return plan;

  const filter = (opts.event ?? '').trim().toLowerCase();
  const byTier = new Map<string, SalesTier>();
  const currencies = new Set<string>();
  const cell = (r: string[], f: SalesField) => {
    const i = mapping[f];
    return i === undefined ? '' : (r[i] ?? '').trim();
  };

  table.slice(1).forEach((r, k) => {
    const line = k + 2;
    if (mapping.event !== undefined && filter && cell(r, 'event').toLowerCase() !== filter) {
      plan.otherEvents++;
      return;
    }
    const status = cell(r, 'status');
    if (status && VOID_STATUS.test(status)) {
      plan.voided++;
      return;
    }
    const soldRaw = cell(r, 'sold');
    const sold = soldRaw === '' ? 0 : parseAmount(soldRaw);
    if (sold === null || !Number.isInteger(sold) || sold < 0 || sold > 10_000_000) {
      errors.push({ row: line, field: 'sold', message: `"${soldRaw}" is not a whole number of tickets.` });
      return;
    }
    let grossCents = 0;
    const grossRaw = cell(r, 'gross');
    const priceRaw = cell(r, 'price');
    if (grossRaw !== '') {
      const g = parseAmount(grossRaw);
      if (g === null || g < 0) {
        errors.push({ row: line, field: 'gross', message: `"${grossRaw}" is not an amount.` });
        return;
      }
      grossCents = toCents(g);
    } else if (priceRaw !== '') {
      const p = parseAmount(priceRaw);
      if (p === null || p < 0) {
        errors.push({ row: line, field: 'price', message: `"${priceRaw}" is not a price.` });
        return;
      }
      grossCents = toCents(p) * sold;
    }
    let capacity: number | null = null;
    const capRaw = cell(r, 'capacity');
    if (capRaw !== '') {
      const c = parseAmount(capRaw);
      if (c === null || !Number.isInteger(c) || c < 0 || c > 10_000_000) {
        errors.push({ row: line, field: 'capacity', message: `"${capRaw}" is not a whole number.` });
        return;
      }
      capacity = c;
    }
    const curRaw = cell(r, 'currency').toUpperCase();
    if (curRaw && !/^[A-Z]{3}$/.test(curRaw)) {
      errors.push({ row: line, field: 'currency', message: `"${curRaw}" is not a 3-letter currency code.` });
      return;
    }
    currencies.add(curRaw || defaultCurrency);

    const name = (cell(r, 'tier').replace(/\s+/g, ' ') || NO_TIER).slice(0, 80);
    const key = name.toLowerCase();
    const t = byTier.get(key) ?? { name, sold: 0, gross_cents: 0, capacity: null };
    t.sold += sold;
    t.gross_cents += grossCents;
    if (capacity !== null) t.capacity = t.capacity === null ? capacity : Math.max(t.capacity, capacity);
    byTier.set(key, t);
    plan.rows++;
  });

  if (currencies.size > 1) {
    errors.push({ row: 0, field: 'currency', message: `The file mixes currencies (${[...currencies].join(', ')}); import one currency at a time.` });
  } else if (currencies.size === 1) {
    plan.currency = [...currencies][0];
  }
  if (byTier.size > MAX_TIERS) errors.push({ row: 0, field: 'tier', message: `More than ${MAX_TIERS} ticket types.` });
  if (plan.rows === 0 && !errors.length) {
    errors.push({ row: 0, message: plan.otherEvents ? 'No rows for the chosen event.' : 'No rows to import.' });
  }
  if (mapping.gross === undefined && mapping.price === undefined) {
    warnings.push({ row: 0, field: 'gross', message: 'No amount column: the gross will be 0.' });
  }
  if (mapping.event !== undefined && !filter) {
    warnings.push({ row: 0, field: 'event', message: 'Every event in the file is added up; choose the event to import only its rows.' });
  }

  plan.tiers = [...byTier.values()];
  plan.sold = plan.tiers.reduce((n, t) => n + t.sold, 0);
  plan.grossCents = plan.tiers.reduce((n, t) => n + t.gross_cents, 0);
  plan.capacity = plan.tiers.length > 0 && plan.tiers.every((t) => t.capacity !== null)
    ? plan.tiers.reduce((n, t) => n + (t.capacity ?? 0), 0)
    : null;
  // A file without a ticket type column is one total, not one "General" type.
  if (plan.tiers.length === 1 && plan.tiers[0].name === NO_TIER && mapping.tier === undefined) plan.tiers = [];
  return plan;
}

/** A manual count's label: trimmed, spaces collapsed; null when invalid (1-40 characters). */
export function cleanLabel(raw: unknown): string | null {
  const label = typeof raw === 'string' ? raw.trim().replace(/\s+/g, ' ') : '';
  if (!label || label.length > 40 || /[\u0000-\u001f\u007f]/.test(label)) return null;
  return label;
}

export interface SalesCountRow {
  id: string;
  event_id: string;
  kind: 'manual' | 'import';
  platform: string | null;
  label: string;
  sold: number;
  gross_cents: number;
  currency: string;
  capacity: number | null;
  tiers: SalesTier[];
  note: string | null;
  file_name?: string | null;
  row_count?: number | null;
  updated_at: string;
}

export interface SalesTotal {
  currency: string;
  sold: number;
  grossCents: number;
}

/** Totals per currency (amounts in different currencies are never added). */
export function salesTotals(rows: Pick<SalesCountRow, 'currency' | 'sold' | 'gross_cents'>[]): SalesTotal[] {
  const by = new Map<string, SalesTotal>();
  for (const r of rows) {
    const cur = (r.currency || 'USD').toUpperCase();
    const t = by.get(cur) ?? { currency: cur, sold: 0, grossCents: 0 };
    t.sold += Number(r.sold) || 0;
    t.grossCents += Number(r.gross_cents) || 0;
    by.set(cur, t);
  }
  return [...by.values()].sort((a, b) => b.sold - a.sold || a.currency.localeCompare(b.currency));
}

/** Tickets sold elsewhere, all currencies (a count can be added across currencies). */
export function totalSold(rows: Pick<SalesCountRow, 'sold'>[]): number {
  return rows.reduce((n, r) => n + (Number(r.sold) || 0), 0);
}
