// Promoter commissions — PURE math (mig 20260926020000). No Supabase import so
// it unit-tests without a client; the RPC wrappers live in ./promoters.ts.
//
// Everything is integer cents. Rounding: floor to the cent, same as the SQL
// (public.exos_pc_commission_cents / exos_pc_accrue_ticket). Keep the two in
// step: tests in commissions.test.ts pin the same cases as
// tests/exos/test_promoter_commissions.sql (C1, C2).

export interface CommissionTerms {
  /** Basis points of the base: 1000 = 10%. */
  rateBps: number;
  /** Flat amount per paid ticket, cents. */
  flatCents: number;
}

export const MAX_RATE_BPS = 10000;
export const MAX_FLAT_CENTS = 100000;

const int = (n: number) => (Number.isFinite(n) ? Math.trunc(n) : 0);

/** min(base, floor(base * bps / 10000) + flat); 0 when there's no base (comps, free). */
export function commissionCents(baseCents: number, rateBps: number, flatCents: number): number {
  const base = int(baseCents);
  if (base <= 0) return 0;
  const bps = Math.max(int(rateBps), 0);
  const flat = Math.max(int(flatCents), 0);
  return Math.min(base, Math.floor((base * bps) / 10000) + flat);
}

/** An event override replaces both parts of the promoter's default terms. */
export function effectiveTerms(defaults: CommissionTerms, override?: CommissionTerms | null): CommissionTerms & { source: 'promoter' | 'event' } {
  return override ? { ...override, source: 'event' } : { ...defaults, source: 'promoter' };
}

/**
 * What the org earns from one ticket of a Stripe order: the order total less
 * add-ons (at their pre-tax price) and all tax, split per ticket, floored.
 * Never more than the ticket's own paid price.
 */
export function ticketBaseCents(o: {
  amountCents: number;
  addonNetCents?: number;
  taxCents?: number | null;
  quantity: number;
  pricePaidCents: number;
}): number {
  const qty = int(o.quantity);
  if (qty <= 0) return 0;
  const net = Math.max(int(o.amountCents) - int(o.addonNetCents ?? 0) - int(o.taxCents ?? 0), 0);
  return Math.max(Math.min(Math.floor(net / qty), int(o.pricePaidCents)), 0);
}

/** "12.5" → 1250 bps. Empty → 0. Invalid or out of range → null. */
export function percentToBps(input: string): number | null {
  const s = input.trim().replace(/%$/, '').trim();
  if (s === '') return 0;
  if (!/^\d{1,3}(\.\d{1,2})?$/.test(s)) return null;
  const [whole, frac = ''] = s.split('.');
  const bps = Number(whole) * 100 + Number((frac + '00').slice(0, 2));
  return bps <= MAX_RATE_BPS ? bps : null;
}

/** 1250 → "12.5". */
export function bpsToPercent(bps: number): string {
  const b = Math.max(int(bps), 0);
  const whole = Math.floor(b / 100);
  const frac = b % 100;
  if (frac === 0) return String(whole);
  return `${whole}.${String(frac).padStart(2, '0').replace(/0$/, '')}`;
}

/** "1.50" / "$1.5" → 150 cents. Empty → 0. Invalid or out of range → null. */
export function moneyToCents(input: string): number | null {
  const s = input.trim().replace(/^\$/, '').trim();
  if (s === '') return 0;
  if (!/^\d{1,6}(\.\d{1,2})?$/.test(s)) return null;
  const [whole, frac = ''] = s.split('.');
  const cents = Number(whole) * 100 + Number((frac + '00').slice(0, 2));
  return cents <= MAX_FLAT_CENTS ? cents : null;
}

/** Short label for a promoter's terms: "10%", "$1.50 / ticket", "10% + $0.50 / ticket", "none". */
export function termsLabel(t: CommissionTerms, fmt: (cents: number) => string = (c) => `$${(c / 100).toFixed(2)}`): string {
  const parts: string[] = [];
  if (t.rateBps > 0) parts.push(`${bpsToPercent(t.rateBps)}%`);
  if (t.flatCents > 0) parts.push(`${fmt(t.flatCents)} / ticket`);
  return parts.length ? parts.join(' + ') : 'none';
}

export type CommissionStatus = 'accrued' | 'reversed' | 'paid';

export interface CommissionRow {
  id: string;
  currency: string;
  commissionCents: number;
  status: CommissionStatus;
  /** Set when the row was paid (and kept if it's reversed afterwards). */
  payoutId: string | null;
  /** Set once a later payout netted out a reversal of a paid row. */
  recoveredPayoutId: string | null;
}

export interface CommissionTotals {
  accrued: number;
  reversed: number;
  paid: number;
  /** Reversed after being paid and not yet netted from a payout. */
  clawback: number;
  /** accrued − clawback; negative means the promoter was overpaid. */
  owed: number;
}

/** Same buckets as exos_org_promoter_commissions / exos_promoter_earnings. */
export function summarize(rows: CommissionRow[]): CommissionTotals {
  const t = { accrued: 0, reversed: 0, paid: 0, clawback: 0, owed: 0 };
  for (const r of rows) {
    const c = int(r.commissionCents);
    if (r.status === 'accrued') t.accrued += c;
    else if (r.status === 'paid') t.paid += c;
    else {
      t.reversed += c;
      if (r.payoutId && !r.recoveredPayoutId) t.clawback += c;
    }
  }
  t.owed = t.accrued - t.clawback;
  return t;
}

/**
 * The amount a payout of the selected rows must record: their sum less
 * outstanding clawbacks. null when it can't be recorded (nothing selected, a
 * row that isn't accrued, mixed currencies, or clawbacks exceed the rows).
 */
export function payoutNetCents(selected: CommissionRow[], clawbackCents: number): number | null {
  if (selected.length === 0) return null;
  if (selected.some((r) => r.status !== 'accrued')) return null;
  if (new Set(selected.map((r) => r.currency.toLowerCase())).size !== 1) return null;
  const sum = selected.reduce((n, r) => n + int(r.commissionCents), 0);
  const net = sum - Math.max(int(clawbackCents), 0);
  return net >= 0 ? net : null;
}

const MONTHS = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

/** A payout's paid_on ("2026-09-20") as "Sep 20, 2026", with no timezone shift. */
export function formatDateOnly(iso: string): string {
  const m = /^(\d{4})-(\d{2})-(\d{2})/.exec(iso || '');
  if (!m) return iso || '';
  return `${MONTHS[Number(m[2]) - 1] ?? m[2]} ${Number(m[3])}, ${m[1]}`;
}

// --- Step terms + settling (mig 20261102150000) ------------------------------

/** One step on top of the base terms: after `after` tickets at an event, `rateBps` / `flatCents`. */
export interface StepTerms { after: number; rateBps: number; flatCents: number }

export interface TieredTerms extends CommissionTerms { step?: StepTerms | null }

/**
 * The terms for the n-th (1-based) non-reversed ticket of a promoter at an
 * event. Mirrors public._exos_pc_terms: the step applies once n > after.
 */
export function termsForOrdinal(t: TieredTerms, ordinal: number): CommissionTerms & { stepped: boolean } {
  const n = Math.max(int(ordinal), 1);
  if (t.step && int(t.step.after) >= 1 && n > int(t.step.after)) {
    return { rateBps: t.step.rateBps, flatCents: t.step.flatCents, stepped: true };
  }
  return { rateBps: t.rateBps, flatCents: t.flatCents, stepped: false };
}

/** What `count` tickets at one event earn in total at a flat base each (pricing preview). */
export function tieredTotalCents(t: TieredTerms, baseCents: number, count: number, alreadySold = 0): number {
  let sum = 0;
  for (let i = 1; i <= Math.max(int(count), 0); i++) {
    const x = termsForOrdinal(t, int(alreadySold) + i);
    sum += commissionCents(baseCents, x.rateBps, x.flatCents);
  }
  return sum;
}

/** The step from the RPC's columns, or null. */
export function stepFrom(after: number | null | undefined, rateBps: number | null | undefined, flatCents: number | null | undefined): StepTerms | null {
  if (after === null || after === undefined || int(after) < 1) return null;
  return { after: int(after), rateBps: int(rateBps ?? 0), flatCents: int(flatCents ?? 0) };
}

/** "10%, then 15% after 20 tickets" (per event). */
export function tieredLabel(t: TieredTerms, fmt?: (cents: number) => string): string {
  const base = termsLabel(t, fmt);
  if (!t.step) return base;
  return `${base}, then ${termsLabel(t.step, fmt)} after ${t.step.after} ticket${t.step.after === 1 ? '' : 's'}`;
}

/** A fresh idempotency key for one settle (kept across retries of the same click). */
export function newSettleKey(rand: () => string = () => globalThis.crypto.randomUUID()): string {
  return `settle-${rand().replace(/[^A-Za-z0-9_-]/g, '')}`.slice(0, 80);
}

export type TransferStatus = 'pending' | 'sending' | 'sent' | 'dry_run' | 'failed' | 'cancelled';

/** How a payout reads to the organizer. */
export function payoutStatusLabel(via: 'manual' | 'stripe', status: TransferStatus | null | undefined): string {
  if (via === 'manual') return 'Recorded';
  switch (status) {
    case 'sent': return 'Sent by Stripe';
    case 'pending': return 'Ready to send';
    case 'sending': return 'Sending…';
    case 'dry_run': return 'Dry run (nothing sent)';
    case 'failed': return 'Failed';
    case 'cancelled': return 'Cancelled';
    default: return 'Unknown';
  }
}

/** A Stripe payout the organizer can still send or cancel. */
export function canSendOrCancel(via: 'manual' | 'stripe', status: TransferStatus | null | undefined): boolean {
  return via === 'stripe' && (status === 'pending' || status === 'dry_run' || status === 'failed');
}
