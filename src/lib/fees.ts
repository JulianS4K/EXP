// Organizer fee rules (mig 20261027100000, docs/fees.md): the pure maths.
//
// PURE, no imports, so Deno (exos-checkout, the feeds) and vitest load it.
// src/lib/fees.ts is an identical copy; src/lib/fees.test.ts checks they agree.
// The SQL mirror is public.exos_fee_unit_cents / exos_all_in_unit_cents.
//
// A rule is passed_on (the buyer pays it, INSIDE the all-in price: no fee line
// at checkout) or absorbed (the organizer pays it; the buyer price doesn't
// change). Passed-on rules are per ticket (and per add-on unit when the rule
// says so); per-order rules are absorbed only (a unit price can't carry them).
//
// Money is in minor units (cents). Rounding: a percent fee is half-up to a
// whole cent, per unit, with integer arithmetic (the rule's percent has at
// most 3 decimals), so the storefront, checkout and Postgres agree exactly.
// Fees never apply to a $0 unit (a free ticket stays free).

export type FeeCalc = "percent" | "fixed";
export type FeeKind = "passed_on" | "absorbed";
export type FeePer = "ticket" | "order";

/** A fee as it sits inside a unit price (one passed-on rule). */
export interface UnitFee {
  id?: string;
  name?: string;
  calc: FeeCalc | string;
  /** calc = percent: 0-100 (3 decimals). */
  percent?: number | string | null;
  /** calc = fixed: minor units. */
  amount_cents?: number | string | null;
  /** Optional ceiling on a percent fee, minor units. */
  cap_cents?: number | string | null;
  /** Tax is charged on this fee (default true). */
  taxable?: boolean | null;
}

/** A full rule: exos_public_fee_rules (passed on) or exos_effective_fee_rules (all). */
export interface FeeRule extends UnitFee {
  rule_id?: string;
  event_id?: string;
  rank?: number;
  kind: FeeKind | string;
  per: FeePer | string;
  recipient?: string | null;
  applies_to_addons?: boolean | null;
  tier_ids?: string[] | null;
}

/** One priced fee line for an order (stored in exos_checkout_fee_snapshots.lines). */
export interface FeeLine {
  rule_id: string | null;
  name: string;
  kind: FeeKind;
  recipient: string;
  calc: FeeCalc;
  percent: number | null;
  per: FeePer;
  item_kind: "ticket" | "addon" | "order";
  item_id: string | null;
  unit_cents: number;
  quantity: number;
  amount_cents: number;
  taxable: boolean;
}

const num = (v: unknown): number => {
  const n = typeof v === "string" ? Number(v) : (v as number);
  return typeof n === "number" && Number.isFinite(n) ? n : NaN;
};

/** One unit's fee for one rule, in cents. Never negative; 0 on a $0 unit. */
export function feeUnitCents(unitCents: number, fee: UnitFee | null | undefined): number {
  const unit = Math.round(num(unitCents));
  if (!fee || !(unit > 0)) return 0;
  if (fee.calc === "percent") {
    const p = num(fee.percent);
    if (!(p > 0)) return 0;
    const milli = Math.round(Math.min(p, 100) * 1000); // percent x 1000, exact
    let amt = Math.floor((unit * milli + 50_000) / 100_000); // half-up to a cent
    const cap = num(fee.cap_cents);
    if (fee.cap_cents !== null && fee.cap_cents !== undefined && fee.cap_cents !== "" && cap >= 0) {
      amt = Math.min(amt, Math.round(cap));
    }
    return amt;
  }
  if (fee.calc === "fixed") {
    const a = Math.round(num(fee.amount_cents));
    return a > 0 ? a : 0;
  }
  return 0;
}

/** A unit's passed-on fees: the total and the part tax applies to. */
export function unitFeeTotals(unitCents: number, fees: readonly UnitFee[] | null | undefined): { total: number; taxable: number } {
  let total = 0;
  let taxable = 0;
  for (const f of fees ?? []) {
    const a = feeUnitCents(unitCents, f);
    total += a;
    if (f.taxable !== false) taxable += a;
  }
  return { total, taxable };
}

/** Lenient read of a list of unit fees (a tier's passedOnFees, or jsonb from SQL). */
export function parseUnitFees(raw: unknown): UnitFee[] {
  if (!Array.isArray(raw)) return [];
  return raw.filter((f): f is UnitFee =>
    !!f && typeof f === "object" && ((f as UnitFee).calc === "percent" || (f as UnitFee).calc === "fixed"));
}

const RULE_KINDS = ["passed_on", "absorbed"];
const RULE_PERS = ["ticket", "order"];

/**
 * Lenient read of fee-rule rows: exos_public_fee_rules (the storefront and
 * the feeds, anon) or exos_effective_fee_rules (exos-checkout, service role).
 * Rows that aren't a usable rule are dropped; the order (rank) is kept.
 */
export function parseFeeRules(raw: unknown): FeeRule[] {
  if (!Array.isArray(raw)) return [];
  const out: FeeRule[] = [];
  for (const r of raw) {
    if (!r || typeof r !== "object") continue;
    const x = r as Record<string, unknown>;
    if ((x.calc !== "percent" && x.calc !== "fixed") || !RULE_KINDS.includes(String(x.kind)) ||
        !RULE_PERS.includes(String(x.per))) continue;
    const id = typeof x.rule_id === "string" ? x.rule_id : typeof x.id === "string" ? x.id : undefined;
    out.push({
      ...(x as unknown as FeeRule),
      id,
      rule_id: id,
      tier_ids: Array.isArray(x.tier_ids) ? (x.tier_ids as unknown[]).map(String) : null,
    });
  }
  return out;
}

/** Fee-rule rows grouped by event_id (one query for a page of events). */
export function feeRulesByEvent(raw: unknown): Map<string, FeeRule[]> {
  const by = new Map<string, FeeRule[]>();
  if (!Array.isArray(raw)) return by;
  for (const r of raw) {
    const ev = r && typeof r === "object" ? (r as { event_id?: unknown }).event_id : undefined;
    if (typeof ev !== "string") continue;
    const [rule] = parseFeeRules([r]);
    if (!rule) continue;
    const list = by.get(ev) ?? [];
    list.push(rule);
    by.set(ev, list);
  }
  return by;
}

/** Columns of exos_public_fee_rules the price functions use. */
export const PUBLIC_FEE_RULE_COLS =
  "event_id, id, name, kind, per, calc, percent, amount_cents, cap_cents, taxable, applies_to_addons, tier_ids, rank";

/** Tier rows with their passed-on fees attached as passed_on_fees (rules grouped by event). */
export function attachTierFees<T extends { id?: unknown; event_id?: unknown }>(
  tiers: readonly T[], byEvent: Map<string, FeeRule[]>,
): (T & { passed_on_fees: FeeRule[] })[] {
  return tiers.map((t) => ({ ...t, passed_on_fees: tierPassedOnFees(byEvent.get(String(t.event_id)) ?? [], String(t.id)) }));
}

/** Passed-on per-ticket rules for one tier: the fees inside its all-in price. */
export function tierPassedOnFees(rules: readonly FeeRule[], tierId: string): FeeRule[] {
  return rules.filter((r) => r.kind === "passed_on" && r.per === "ticket" &&
    (!Array.isArray(r.tier_ids) || r.tier_ids.length === 0 || r.tier_ids.includes(tierId)));
}

/** Passed-on rules for add-ons: the fees inside an add-on's all-in price. */
export function addonPassedOnFees(rules: readonly FeeRule[]): FeeRule[] {
  return rules.filter((r) => r.kind === "passed_on" && r.per === "ticket" && r.applies_to_addons === true);
}

export interface OrderFeeInput {
  tierId: string;
  /** Per-ticket price after any code, before fees and tax (cents). */
  ticketUnitCents: number;
  quantity: number;
  addons: { id: string; unitCents: number; quantity: number }[];
}

/**
 * Every fee line of an order, passed on and absorbed. The passed-on per-unit
 * amounts are exactly feeUnitCents (what the all-in price folded in); absorbed
 * per-ticket rules work the same way, and an absorbed per-order rule is
 * charged once on the tickets (plus the add-ons when the rule covers them).
 */
export function orderFeeLines(rules: readonly FeeRule[], o: OrderFeeInput): FeeLine[] {
  const out: FeeLine[] = [];
  const qty = Math.max(0, Math.floor(o.quantity));
  for (const r of rules) {
    if (r.kind !== "passed_on" && r.kind !== "absorbed") continue;
    if (r.calc !== "percent" && r.calc !== "fixed") continue;
    if (Array.isArray(r.tier_ids) && r.tier_ids.length > 0 && !r.tier_ids.includes(o.tierId)) continue;
    const base = {
      rule_id: r.rule_id ?? r.id ?? null,
      name: String(r.name ?? "Fee").slice(0, 60),
      kind: r.kind as FeeKind,
      recipient: String(r.recipient ?? "org").slice(0, 40),
      calc: r.calc as FeeCalc,
      percent: r.calc === "percent" ? num(r.percent) : null,
      taxable: r.kind === "passed_on" && r.taxable !== false,
    };
    if (r.per === "ticket") {
      const t = feeUnitCents(o.ticketUnitCents, r);
      if (t > 0 && qty > 0) {
        out.push({ ...base, per: "ticket", item_kind: "ticket", item_id: o.tierId, unit_cents: t, quantity: qty, amount_cents: t * qty });
      }
      if (r.applies_to_addons === true) {
        for (const a of o.addons) {
          const u = feeUnitCents(a.unitCents, r);
          if (u > 0 && a.quantity > 0) {
            out.push({ ...base, per: "ticket", item_kind: "addon", item_id: a.id, unit_cents: u, quantity: a.quantity, amount_cents: u * a.quantity });
          }
        }
      }
    } else if (r.per === "order" && r.kind === "absorbed") {
      let orderBase = Math.max(0, Math.round(o.ticketUnitCents)) * qty;
      if (r.applies_to_addons === true) {
        for (const a of o.addons) orderBase += Math.max(0, Math.round(a.unitCents)) * Math.max(0, a.quantity);
      }
      const amt = feeUnitCents(orderBase, r);
      if (amt > 0) {
        out.push({ ...base, per: "order", item_kind: "order", item_id: null, unit_cents: amt, quantity: 1, amount_cents: amt });
      }
    }
  }
  return out;
}

/** Totals of an order's fee lines. */
export function feeTotals(lines: readonly FeeLine[]): { passedOn: number; absorbed: number } {
  let passedOn = 0;
  let absorbed = 0;
  for (const l of lines) {
    if (l.kind === "passed_on") passedOn += l.amount_cents;
    else absorbed += l.amount_cents;
  }
  return { passedOn, absorbed };
}
