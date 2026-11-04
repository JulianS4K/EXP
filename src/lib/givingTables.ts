// Giving tables in the dashboard (/orgs/:orgId/giving, mig 20261102110000):
// the pure logic behind the campaign, donation, monthly-gift and imported
// gift card tables. Sorting, filtering, paging, which row actions a role
// sees, and the gift card import file. No Supabase imports (vitest:
// givingTables.test.ts). The SQL re-checks every role; hiding an action here
// is only so nobody is offered what they can't do.

import { parseCsv } from '../../supabase/functions/_shared/csvParse.ts';

export type OrgRole = 'owner' | 'manager' | 'finance' | 'content' | 'scanner' | string | null;
export type SortDir = 'asc' | 'desc';
export interface SortState<K extends string = string> { key: K; dir: SortDir }

const collator = new Intl.Collator(undefined, { sensitivity: 'base', numeric: true });

/** Compare two cell values: numbers and dates by value, text without case, empty last. */
export function compareCells(a: unknown, b: unknown): number {
  const ea = a === null || a === undefined || a === '';
  const eb = b === null || b === undefined || b === '';
  if (ea || eb) return ea === eb ? 0 : ea ? 1 : -1;
  if (typeof a === 'number' && typeof b === 'number') return a - b;
  if (typeof a === 'boolean' && typeof b === 'boolean') return Number(a) - Number(b);
  return collator.compare(String(a), String(b));
}

/** A stable sort by one column; empty cells stay last in either direction; ties keep their order. */
export function sortRows<T>(rows: readonly T[], sort: SortState, get: (row: T, key: string) => unknown = (r, k) => (r as Record<string, unknown>)[k]): T[] {
  return rows
    .map((row, i) => ({ row, i }))
    .sort((x, y) => {
      const a = get(x.row, sort.key);
      const b = get(y.row, sort.key);
      const empty = (v: unknown) => v === null || v === undefined || v === '';
      if (empty(a) || empty(b)) return compareCells(a, b) || x.i - y.i;
      const c = compareCells(a, b);
      return (sort.dir === 'asc' ? c : -c) || x.i - y.i;
    })
    .map((x) => x.row);
}

/** The next sort when a header is clicked: same column flips, a new one starts descending for numbers/dates. */
export function nextSort<K extends string>(cur: SortState<K>, key: K, firstDir: SortDir = 'asc'): SortState<K> {
  if (cur.key === key) return { key, dir: cur.dir === 'asc' ? 'desc' : 'asc' };
  return { key, dir: firstDir };
}

/** Case-insensitive match of every search word in any of the given fields. */
export function matchesSearch(fields: readonly unknown[], search: string): boolean {
  const words = search.toLowerCase().split(/\s+/).filter(Boolean);
  if (words.length === 0) return true;
  const hay = fields.filter((f) => f !== null && f !== undefined).map((f) => String(f).toLowerCase()).join(' ');
  return words.every((w) => hay.includes(w));
}

export interface PageSlice<T> { rows: T[]; page: number; pages: number; total: number; from: number; to: number }

/** One page of rows (1-based, clamped to the last page). */
export function pageRows<T>(rows: readonly T[], page: number, perPage: number): PageSlice<T> {
  const per = Math.max(1, Math.trunc(perPage) || 1);
  const total = rows.length;
  const pages = Math.max(1, Math.ceil(total / per));
  const p = Math.min(Math.max(1, Math.trunc(page) || 1), pages);
  const start = (p - 1) * per;
  const slice = rows.slice(start, start + per);
  return { rows: slice, page: p, pages, total, from: total === 0 ? 0 : start + 1, to: start + slice.length };
}

/** 1234 -> "$12.34" (or "12.34 EUR" for currencies Intl doesn't know). */
export function formatMoney(cents: number, currency = 'usd'): string {
  try {
    return new Intl.NumberFormat(undefined, { style: 'currency', currency: currency.toUpperCase() }).format(cents / 100);
  } catch {
    return `${(cents / 100).toFixed(2)} ${currency.toUpperCase()}`;
  }
}

// ── Roles ────────────────────────────────────────────────────────────────────
/** Who may do what (mirrors the SQL wrappers in mig 20261102110000). */
export function givingPermissions(role: OrgRole, isAdmin = false) {
  const mgr = isAdmin || role === 'owner' || role === 'manager';
  const fin = mgr || role === 'finance';
  return {
    read: fin,
    editCampaigns: mgr,
    deleteDonations: mgr,
    refundDonations: fin,
    cancelMonthly: fin,
    importGiftCards: mgr,
  };
}
export type GivingPermissions = ReturnType<typeof givingPermissions>;

// ── Campaigns ──────────────────────────────────────────────────────────────────
export type CampaignStatus = 'draft' | 'active' | 'completed';
export interface CampaignRow {
  id: string;
  name: string;
  slug: string;
  currency: string;
  goal_cents: number;
  active: boolean;
  completed_at: string | null;
  starts_at: string | null;
  ends_at: string | null;
  created_at: string;
  raised_cents: number;
  donation_count: number;
  checkout_add_on?: boolean;
  description?: string | null;
  tax_receipt_text?: string | null;
}

export function campaignStatus(c: Pick<CampaignRow, 'active' | 'completed_at'>): CampaignStatus {
  return c.completed_at ? 'completed' : c.active ? 'active' : 'draft';
}

export type CampaignAction = 'edit' | 'activate' | 'deactivate' | 'complete' | 'delete';

/** Row actions on a campaign: by status and role. Delete only when it has no gifts at all. */
export function campaignActions(c: CampaignRow, perms: GivingPermissions, hasMonthly = false): CampaignAction[] {
  if (!perms.editCampaigns) return [];
  const st = campaignStatus(c);
  const out: CampaignAction[] = [];
  if (st !== 'completed') out.push('edit');
  if (st === 'draft') out.push('activate');
  if (st === 'active') out.push('deactivate');
  if (st !== 'completed') out.push('complete');
  if (c.donation_count === 0 && !hasMonthly) out.push('delete');
  return out;
}

export interface CampaignFilter { status: CampaignStatus | 'all'; search: string }
export function filterCampaigns(rows: readonly CampaignRow[], f: CampaignFilter): CampaignRow[] {
  return rows.filter((c) => (f.status === 'all' || campaignStatus(c) === f.status) && matchesSearch([c.name, c.slug], f.search));
}

/** Percent of the goal raised (null without a goal), capped at 999. */
export function goalPercent(c: Pick<CampaignRow, 'goal_cents' | 'raised_cents'>): number | null {
  if (!c.goal_cents) return null;
  return Math.min(999, Math.floor((c.raised_cents / c.goal_cents) * 100));
}

// ── Donations ──────────────────────────────────────────────────────────────────
export interface DonationRow {
  id: string;
  campaign_id: string;
  amount_cents: number;
  cover_fees_cents: number;
  total_cents: number;
  refunded_cents: number;
  currency: string;
  method: string;
  status: 'received' | 'refunded';
  donor_name: string | null;
  donor_email: string | null;
  anonymous: boolean;
  session_id: string | null;
  recurring_id: string | null;
  payment_intent?: string | null;
  receipt_number: number | null;
  created_at: string;
}

const OFFLINE = new Set(['cash', 'check', 'other']);

/** A gift recorded by hand with no payment behind it (the only kind that can be deleted). */
export function isOfflineDonation(d: DonationRow): boolean {
  return OFFLINE.has(d.method) && !d.session_id && !d.recurring_id && !d.payment_intent;
}

export function donationLeftCents(d: Pick<DonationRow, 'total_cents' | 'refunded_cents'>): number {
  return Math.max(0, d.total_cents - (d.refunded_cents ?? 0));
}

export type DonationAction = 'offline_refund' | 'delete';
export function donationActions(d: DonationRow, perms: GivingPermissions): DonationAction[] {
  const out: DonationAction[] = [];
  if (perms.refundDonations && d.status === 'received' && donationLeftCents(d) > 0) out.push('offline_refund');
  if (perms.deleteDonations && isOfflineDonation(d) && d.status === 'received' && !d.refunded_cents) out.push('delete');
  return out;
}

export type DonationKind = 'offline' | 'online' | 'monthly';
export function donationKind(d: DonationRow): DonationKind {
  if (d.recurring_id) return 'monthly';
  return isOfflineDonation(d) ? 'offline' : 'online';
}

export interface DonationFilter { campaignId: string | 'all'; status: 'all' | 'received' | 'refunded' | 'partly_refunded'; kind: DonationKind | 'all'; search: string }
export function filterDonations(rows: readonly DonationRow[], f: DonationFilter): DonationRow[] {
  return rows.filter((d) => {
    if (f.campaignId !== 'all' && d.campaign_id !== f.campaignId) return false;
    if (f.status === 'received' && d.status !== 'received') return false;
    if (f.status === 'refunded' && d.status !== 'refunded') return false;
    if (f.status === 'partly_refunded' && !(d.status === 'received' && d.refunded_cents > 0)) return false;
    if (f.kind !== 'all' && donationKind(d) !== f.kind) return false;
    return matchesSearch([d.donor_name, d.donor_email, d.receipt_number, d.method], f.search);
  });
}

// ── Monthly gifts ────────────────────────────────────────────────────────────────
export interface RecurringRow {
  id: string;
  campaign_id: string;
  amount_cents: number;
  cover_fees_cents: number;
  currency: string;
  status: 'pending' | 'active' | 'past_due' | 'cancelled' | 'ended';
  donor_name: string | null;
  donor_email: string;
  current_period_end: string | null;
  last_paid_at: string | null;
  failed_payments: number;
  cancel_requested_at: string | null;
  created_at: string;
}

/** Cancel is offered while it still bills (or a cancel didn't finish in Stripe). */
export function recurringActions(r: RecurringRow, perms: GivingPermissions): 'cancel'[] {
  return perms.cancelMonthly && ['pending', 'active', 'past_due'].includes(r.status) ? ['cancel'] : [];
}

export interface RecurringFilter { campaignId: string | 'all'; status: RecurringRow['status'] | 'all'; search: string }
export function filterRecurring(rows: readonly RecurringRow[], f: RecurringFilter): RecurringRow[] {
  return rows.filter((r) => (f.campaignId === 'all' || r.campaign_id === f.campaignId)
    && (f.status === 'all' || r.status === f.status) && matchesSearch([r.donor_name, r.donor_email], f.search));
}

// ── Imported gift cards ──────────────────────────────────────────────────────────
export interface ImportedCardRow {
  id: string;
  last4: string;
  currency: string;
  initial_cents: number;
  balance_cents: number;
  status: 'active' | 'voided';
  external_source: string | null;
  recipient_email: string | null;
  expires_at: string | null;
  created_at: string;
}
export interface ImportedCardFilter { source: string | 'all'; state: 'all' | 'with_balance' | 'spent' | 'voided' | 'expired'; search: string }
export function filterImportedCards(rows: readonly ImportedCardRow[], f: ImportedCardFilter, now = Date.now()): ImportedCardRow[] {
  return rows.filter((c) => {
    if (f.source !== 'all' && c.external_source !== f.source) return false;
    const expired = !!c.expires_at && Date.parse(c.expires_at) < now;
    if (f.state === 'voided' && c.status !== 'voided') return false;
    if (f.state === 'expired' && !expired) return false;
    if (f.state === 'with_balance' && !(c.status === 'active' && !expired && c.balance_cents > 0)) return false;
    if (f.state === 'spent' && !(c.status === 'active' && c.balance_cents === 0)) return false;
    return matchesSearch([c.last4, c.recipient_email, c.external_source], f.search);
  });
}

export const IMPORT_BATCH = 500;

export interface ImportCard {
  code: string;
  balance_cents: number;
  initial_cents?: number;
  currency?: string;
  expires_at?: string;
  recipient_email?: string;
  recipient_name?: string;
}
export interface ImportParse { cards: ImportCard[]; errors: { line: number; error: string }[] }

const HEADERS: Record<string, keyof ImportCard | 'balance' | 'initial'> = {
  code: 'code', 'gift card code': 'code', 'gift_card_code': 'code', 'card code': 'code',
  balance_cents: 'balance_cents', balance: 'balance', 'remaining value': 'balance', remaining_value: 'balance', 'remaining balance': 'balance',
  initial_cents: 'initial_cents', 'initial value': 'initial', initial_value: 'initial', value: 'initial', 'original value': 'initial',
  currency: 'currency', expires_at: 'expires_at', 'expiry date': 'expires_at', expiry_date: 'expires_at', expires: 'expires_at',
  recipient_email: 'recipient_email', 'recipient email': 'recipient_email', email: 'recipient_email',
  recipient_name: 'recipient_name', 'recipient name': 'recipient_name', name: 'recipient_name',
};

/** "25", "$25.00", "1,250.5" -> cents; null if it isn't an amount. A comma is only a thousands separator:
 *  "25,00" (a decimal comma, e.g. a European export) is refused, not read as 2500. */
export function majorCents(v: string): number | null {
  let t = v.trim().replace(/^[^\d-]+/, '');
  if (t.includes(',')) {
    if (!/^\d{1,3}(,\d{3})+(\.\d{1,2})?$/.test(t)) return null;
    t = t.replace(/,/g, '');
  }
  if (!/^\d{1,9}(\.\d{1,2})?$/.test(t)) return null;
  const [a, b = ''] = t.split('.');
  return Number(a) * 100 + Number((b + '00').slice(0, 2));
}

/**
 * A gift card export (Gift Up!'s CSV or any file with a code and a balance
 * column) to import rows. Balances in a "balance" / "remaining value" column
 * are major units; a balance_cents column is cents. Rows without a code or
 * a positive balance are listed as errors, not sent.
 */
export function parseGiftCardFile(text: string): ImportParse {
  const table = parseCsv(text).filter((r) => r.some((c) => c.trim() !== ''));
  const out: ImportParse = { cards: [], errors: [] };
  if (table.length < 2) {
    out.errors.push({ line: 1, error: 'the file needs a header row and at least one card' });
    return out;
  }
  const cols = table[0].map((h) => HEADERS[h.trim().toLowerCase()] ?? null);
  if (!cols.includes('code')) out.errors.push({ line: 1, error: 'no code column (code, gift card code)' });
  if (!cols.includes('balance') && !cols.includes('balance_cents')) out.errors.push({ line: 1, error: 'no balance column (balance, remaining value, balance_cents)' });
  if (out.errors.length) return out;
  table.slice(1).forEach((r, i) => {
    const line = i + 2;
    const card: Partial<ImportCard> = {};
    let bad: string | null = null;
    cols.forEach((k, j) => {
      const v = (r[j] ?? '').trim();
      if (!k || v === '') return;
      if (k === 'balance' || k === 'initial') {
        const c = majorCents(v);
        if (c === null) bad = `"${v}" isn't an amount`;
        else if (k === 'balance') card.balance_cents = c; else card.initial_cents = c;
      } else if (k === 'balance_cents' || k === 'initial_cents') {
        if (!/^\d{1,9}$/.test(v)) bad = `"${v}" isn't whole cents`;
        else card[k] = Number(v);
      } else {
        (card as Record<string, string>)[k] = v;
      }
    });
    if (!bad && !card.code) bad = 'no code';
    if (!bad && !(card.balance_cents && card.balance_cents > 0)) bad = 'no balance left (nothing to import)';
    if (bad) out.errors.push({ line, error: bad });
    else out.cards.push(card as ImportCard);
  });
  return out;
}

/** Split into batches the API takes (500 a call). */
export function importBatches<T>(cards: readonly T[], size = IMPORT_BATCH): T[][] {
  const out: T[][] = [];
  for (let i = 0; i < cards.length; i += size) out.push(cards.slice(i, i + size));
  return out;
}
