// Pure rules for the organizer's memberships tables (/orgs/:orgId/memberships,
// mig 20261102100000, docs/memberships.md): the product lifecycle and which
// row actions it allows, which member edits staff may make, table sorting /
// filtering / paging, and the forms' validation. The SQL re-checks all of it;
// this decides what the dashboard shows. Tested in membershipAdmin.test.ts.

export type ProductStatus = 'draft' | 'published' | 'unpublished' | 'archived';
export type ProductAction = 'publish' | 'unpublish' | 'archive';

export const PRODUCT_STATUSES: readonly ProductStatus[] = ['draft', 'published', 'unpublished', 'archived'];

export const PRODUCT_STATUS_LABEL: Record<ProductStatus, string> = {
  draft: 'Draft', published: 'On sale', unpublished: 'Off sale', archived: 'Archived',
};

/** The lifecycle moves from a status: draft -> published <-> unpublished -> archived (final). */
export function productActions(status: ProductStatus): ProductAction[] {
  switch (status) {
    case 'draft': return ['publish', 'archive'];
    case 'published': return ['unpublish', 'archive'];
    case 'unpublished': return ['publish', 'archive'];
    default: return [];
  }
}

export const canEditProduct = (status: ProductStatus): boolean => status !== 'archived';

/** Roles: owner / manager write; finance reads; others see nothing (RLS agrees). */
export function membershipRoles(role: string | null | undefined, isAdmin = false): { canRead: boolean; canWrite: boolean; canImports: boolean } {
  const r = isAdmin ? 'owner' : role ?? '';
  const canWrite = r === 'owner' || r === 'manager';
  return { canRead: canWrite || r === 'finance', canWrite, canImports: canWrite };
}

export interface MemberRow {
  id: string;
  status: string;
  effective_status: string;
  stripe_billed: boolean;
  ended_reason: string | null;
  current_period_end: string | null;
}

export type MemberAction = 'edit' | 'cancel' | 'reactivate' | 'extend';

/**
 * What staff may do to a membership: rename / notes always; status and dates
 * only when Stripe doesn't bill it, it isn't an unclaimed gift and it hasn't
 * ended for good (a refund is terminal).
 */
export function memberActions(m: MemberRow): MemberAction[] {
  const out: MemberAction[] = ['edit'];
  if (m.stripe_billed || m.ended_reason || m.status === 'pending') return out;
  if (m.effective_status === 'active' || m.effective_status === 'past_due') out.push('extend', 'cancel');
  else out.push('reactivate');
  return out;
}

/** Why a membership's status is locked, for the row's tooltip (null when it isn't). */
export function memberLockReason(m: MemberRow): string | null {
  if (m.ended_reason === 'refunded') return 'Refunded: ended for good.';
  if (m.ended_reason) return 'Ended for good.';
  if (m.stripe_billed) return 'Billed by Stripe: cancel it in Stripe.';
  if (m.status === 'pending') return 'Unclaimed gift.';
  return null;
}

export const MEMBER_STATUS_LABEL: Record<string, string> = {
  pending: 'Gift, unclaimed', active: 'Active', past_due: 'Past due', cancelled: 'Cancelled', expired: 'Expired',
};

// ── Tables ────────────────────────────────────────────────────────────────

export interface SortState<K extends string = string> {
  key: K;
  desc: boolean;
}

/** Click on a column header: the same column flips, another starts ascending (dates descending). */
export function toggleSort<K extends string>(cur: SortState<K>, key: K, descFirst: readonly K[] = []): SortState<K> {
  if (cur.key === key) return { key, desc: !cur.desc };
  return { key, desc: descFirst.includes(key) };
}

export function sortIndicator(cur: SortState, key: string): '' | '▲' | '▼' {
  return cur.key !== key ? '' : cur.desc ? '▼' : '▲';
}

/** Nulls last either way; strings case-insensitive; numbers and ISO dates in order. */
export function compareValues(a: unknown, b: unknown): number {
  const an = a === null || a === undefined || a === '';
  const bn = b === null || b === undefined || b === '';
  if (an || bn) return an === bn ? 0 : an ? 1 : -1;
  if (typeof a === 'number' && typeof b === 'number') return a - b;
  if (typeof a === 'boolean' && typeof b === 'boolean') return Number(a) - Number(b);
  return String(a).localeCompare(String(b), undefined, { sensitivity: 'base', numeric: true });
}

export interface TableQuery<T> {
  search?: string;
  /** Fields the search box looks in. */
  searchIn?: (keyof T)[];
  filter?: (row: T) => boolean;
  sort?: SortState<Extract<keyof T, string>>;
  page?: number;
  perPage?: number;
}

export interface TablePage<T> {
  rows: T[];
  total: number;
  page: number;
  pages: number;
}

/** Filter, search, sort (stable, nulls last, tiebreak on id) and page a list in the browser. */
export function tablePage<T extends { id: string }>(all: readonly T[], q: TableQuery<T>): TablePage<T> {
  const needle = (q.search ?? '').trim().toLowerCase();
  let rows = all.filter((r) => (q.filter ? q.filter(r) : true));
  if (needle && q.searchIn?.length) {
    rows = rows.filter((r) => q.searchIn!.some((k) => String(r[k] ?? '').toLowerCase().includes(needle)));
  }
  if (q.sort) {
    const { key, desc } = q.sort;
    rows = [...rows].sort((a, b) => {
      const av = a[key]; const bv = b[key];
      const nullish = (v: unknown) => v === null || v === undefined || v === '';
      // Nulls stay last whichever way the column sorts.
      if (nullish(av) || nullish(bv)) return compareValues(av, bv) || a.id.localeCompare(b.id);
      const c = compareValues(av, bv);
      return (desc ? -c : c) || a.id.localeCompare(b.id);
    });
  }
  const perPage = Math.max(1, q.perPage ?? 25);
  const pages = Math.max(1, Math.ceil(rows.length / perPage));
  const page = Math.min(Math.max(1, q.page ?? 1), pages);
  return { rows: rows.slice((page - 1) * perPage, page * perPage), total: rows.length, page, pages };
}

/** Pages for a server-paged table. */
export const pageCount = (total: number, perPage: number): number => Math.max(1, Math.ceil(Math.max(0, total) / Math.max(1, perPage)));

/** "26–50 of 120" */
export function rangeLabel(page: number, perPage: number, total: number): string {
  if (total <= 0) return '0 of 0';
  const from = (page - 1) * perPage + 1;
  return `${Math.min(from, total)}–${Math.min(page * perPage, total)} of ${total}`;
}

// ── Forms ─────────────────────────────────────────────────────────────────

/** "12.50" -> 1250; blank / bad -> null. */
export function centsFromMajor(v: string): number | null {
  const t = v.trim().replace(/^\$/, '');
  if (!/^\d{1,7}(\.\d{1,2})?$/.test(t)) return null;
  const [w, f = ''] = t.split('.');
  return Number(w) * 100 + Number((f + '00').slice(0, 2));
}

export const majorFromCents = (c: number | null | undefined): string => (c == null ? '' : (c / 100).toFixed(2));

export interface ProductForm {
  name: string;
  description: string;
  price: string;
  billing: 'month' | 'year' | 'once';
  duration_days: string;
  discount_percent: string;
  presale: boolean;
  free_tickets_per_period: string;
  guest_allowance: string;
  household_seats: string;
  giftable: boolean;
}

export const EMPTY_PRODUCT_FORM: ProductForm = {
  name: '', description: '', price: '', billing: 'month', duration_days: '365', discount_percent: '10', presale: true,
  free_tickets_per_period: '0', guest_allowance: '0', household_seats: '0', giftable: true,
};

function intIn(v: string, lo: number, hi: number, what: string): number {
  const n = Number(v.trim() === '' ? NaN : v);
  if (!Number.isInteger(n) || n < lo || n > hi) throw new Error(`${what} must be a whole number from ${lo} to ${hi}.`);
  return n;
}

/**
 * The save RPC's fields from the form. On update only what changed is sent
 * (billing never: it is set once). Throws with a message for the form.
 */
export function productFields(f: ProductForm, mode: 'create' | 'update', before?: Partial<Record<string, unknown>>): Record<string, unknown> {
  const name = f.name.trim();
  if (!name) throw new Error('Give the membership a name.');
  if (name.length > 120) throw new Error('The name is at most 120 characters.');
  const price = centsFromMajor(f.price);
  if (price === null || price < 50) throw new Error('Enter a price of at least 0.50.');
  const discount = Number(f.discount_percent.trim() === '' ? NaN : f.discount_percent);
  if (!Number.isFinite(discount) || discount < 0 || discount > 100) throw new Error('The discount is 0 to 100 percent.');
  const out: Record<string, unknown> = {
    name, description: f.description.trim() || null, price_cents: price,
    duration_days: intIn(f.duration_days, 1, 3660, 'The term in days'), discount_percent: discount, presale: f.presale,
    free_tickets_per_period: intIn(f.free_tickets_per_period, 0, 100, 'Free tickets'),
    guest_allowance: intIn(f.guest_allowance, 0, 20, 'Guests'), household_seats: intIn(f.household_seats, 0, 20, 'Household seats'),
    giftable: f.giftable,
  };
  if (mode === 'create') return { ...out, billing: f.billing };
  if (!before) return out;
  return Object.fromEntries(Object.entries(out).filter(([k, v]) => {
    const b = before[k];
    return k === 'discount_percent' ? Number(b) !== v : (b ?? null) !== v;
  }));
}

export function productToForm(p: Record<string, unknown>): ProductForm {
  const s = (v: unknown, d = '') => (v === null || v === undefined ? d : String(v));
  return {
    name: s(p.name), description: s(p.description), price: majorFromCents(p.price_cents as number),
    billing: (p.billing as ProductForm['billing']) ?? 'month', duration_days: s(p.duration_days, '365'),
    discount_percent: s(Number(p.discount_percent ?? 0)), presale: p.presale === true,
    free_tickets_per_period: s(p.free_tickets_per_period, '0'), guest_allowance: s(p.guest_allowance, '0'),
    household_seats: s(p.household_seats, '0'), giftable: p.giftable !== false,
  };
}

const EMAIL_RE = /^[^@\s]+@[^@\s]+\.[^@\s]+$/;

/** The issue RPC's fields: product, email, optional name / end date (YYYY-MM-DD) / notes. */
export function issueFields(f: { product_id: string; email: string; member_name: string; source: 'comp' | 'import'; expires_on: string; staff_notes: string }, today = new Date()): Record<string, unknown> {
  if (!f.product_id) throw new Error('Pick a membership.');
  const email = f.email.trim().toLowerCase();
  if (!EMAIL_RE.test(email)) throw new Error('Enter the member\'s email.');
  const out: Record<string, unknown> = { product_id: f.product_id, email, source: f.source };
  if (f.member_name.trim()) out.member_name = f.member_name.trim().slice(0, 120);
  if (f.staff_notes.trim()) out.staff_notes = f.staff_notes.trim().slice(0, 2000);
  if (f.expires_on) out.expires_at = endOfDayIso(f.expires_on, today);
  return out;
}

/** A date input's YYYY-MM-DD as the end of that day (UTC); must be after today. */
export function endOfDayIso(day: string, today = new Date()): string {
  if (!/^\d{4}-\d{2}-\d{2}$/.test(day)) throw new Error('Pick an end date.');
  const iso = `${day}T23:59:59Z`;
  if (Number.isNaN(Date.parse(iso)) || Date.parse(iso) <= today.getTime()) throw new Error('The end date must be in the future.');
  return iso;
}

/** Imported attendee edit: only the fields that changed. */
export function attendeeChanges(
  before: { guest_name: string; email: string | null; code: string | null; ticket_label: string | null; note: string | null },
  f: { guest_name: string; email: string; code: string; ticket_label: string; note: string },
): Record<string, unknown> {
  const out: Record<string, unknown> = {};
  const name = f.guest_name.trim();
  if (!name) throw new Error('The attendee needs a name.');
  if (name !== before.guest_name) out.guest_name = name;
  const norm = (v: string) => v.trim() || null;
  const email = norm(f.email)?.toLowerCase() ?? null;
  if (email !== (before.email ?? null)) out.email = email;
  // Codes compare as the door stores them (spaces removed, upper case).
  const code = f.code.replace(/\s/g, '').toUpperCase() || null;
  if (code !== (before.code ?? null)) out.code = code;
  if (norm(f.ticket_label) !== (before.ticket_label ?? null)) out.ticket_label = norm(f.ticket_label);
  if (norm(f.note) !== (before.note ?? null)) out.note = norm(f.note);
  return out;
}
