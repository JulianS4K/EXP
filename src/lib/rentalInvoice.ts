// Rental invoices (mig 20261102130000, docs/templates-inbound.md): the
// totals the database computes (_exos_rental_totals), for the editor's live
// preview, and which actions each status and role allow. Pure.
//
// line  = round(quantity x cost x (attendance when per head))
// subtotal - discount (capped at the subtotal) = taxable
// each tax / fee = round(taxable x rate / 100); total = taxable + taxes
// deposits = flat cents, or round(total x percent / 100)

export type CostType = 'fixed' | 'per_head';
export type RentalStatus = 'draft' | 'issued' | 'paid' | 'void';

export interface RentalItem {
  title: string;
  description?: string;
  category?: string;
  quantity?: number | string;
  cost_type?: CostType;
  cost_cents: number;
  position?: number;
}

export interface RentalDeposit {
  deposit_type: 'flat' | 'percent';
  value: number;
  due_date_type?: 'relative' | 'specific';
  relative_due_days?: number;
  specific_due_date?: string;
}

export interface RentalTaxFee {
  name: string;
  rate_percent: number | string;
  category?: string;
}

export interface RentalTotals {
  lines: number[];
  subtotal_cents: number;
  discount_cents: number;
  taxable_cents: number;
  taxes: { name: string; cents: number }[];
  tax_cents: number;
  total_cents: number;
  deposits_cents: number;
}

/** Half away from zero (Postgres round(numeric)); every amount here is >= 0. */
function round(n: number): number {
  return Math.sign(n) * Math.round(Math.abs(n) + Number.EPSILON * Math.abs(n));
}

export function lineTotal(item: RentalItem, attendance: number | null | undefined): number {
  const q = Number(item.quantity ?? 1);
  const heads = item.cost_type === 'per_head' ? Math.max(0, attendance ?? 0) : 1;
  if (!Number.isFinite(q) || !Number.isFinite(item.cost_cents)) return 0;
  return round(q * item.cost_cents * heads);
}

export function rentalTotals(
  items: readonly RentalItem[],
  attendance: number | null | undefined,
  discountCents: number | null | undefined,
  taxFees: readonly RentalTaxFee[] = [],
  deposits: readonly RentalDeposit[] = [],
): RentalTotals {
  const lines = items.map((i) => lineTotal(i, attendance));
  const subtotal = lines.reduce((s, x) => s + x, 0);
  const discount = Math.min(Math.max(0, discountCents ?? 0), subtotal);
  const taxable = subtotal - discount;
  const taxes = taxFees.map((t) => ({ name: t.name, cents: round((taxable * Number(t.rate_percent)) / 100) }));
  const tax = taxes.reduce((s, x) => s + x.cents, 0);
  const total = taxable + tax;
  const dep = deposits.reduce((s, d) => s + (d.deposit_type === 'percent' ? round((total * d.value) / 100) : d.value), 0);
  return {
    lines, subtotal_cents: subtotal, discount_cents: discount, taxable_cents: taxable, taxes, tax_cents: tax,
    total_cents: total, deposits_cents: dep,
  };
}

/** A deposit's due date: a fixed date, or N days before the rental date (null when unknown). */
export function depositDueDate(d: RentalDeposit, rentalDate: string | null | undefined): string | null {
  if (d.due_date_type === 'specific') return d.specific_due_date ?? null;
  if (!rentalDate || !/^\d{4}-\d{2}-\d{2}$/.test(rentalDate)) return null;
  const t = Date.parse(`${rentalDate}T00:00:00Z`) - (d.relative_due_days ?? 0) * 86_400_000;
  return new Date(t).toISOString().slice(0, 10);
}

export interface RentalActions {
  edit: boolean;
  delete: boolean;
  issue: boolean;
  pay: boolean;
  unpay: boolean;
  void: boolean;
}

/** What an invoice in `status` allows a member with `role` (owner / manager / finance write). */
export function rentalActions(status: RentalStatus, role: string | null | undefined, isAdmin = false): RentalActions {
  const can = isAdmin || role === 'owner' || role === 'manager' || role === 'finance';
  return {
    edit: can && status === 'draft',
    delete: can && status === 'draft',
    issue: can && status === 'draft',
    pay: can && status === 'issued',
    unpay: can && status === 'paid',
    void: can && (status === 'issued' || status === 'paid'),
  };
}

/** Owners and managers write rental templates; finance reads them. */
export function canWriteRentalTemplates(role: string | null | undefined, isAdmin = false): boolean {
  return isAdmin || role === 'owner' || role === 'manager';
}
