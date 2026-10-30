// Deal math for offers, settlements and profit and loss
// (docs/offers-settlements.md). Pure TypeScript with no imports: the
// dashboard (src/lib/dealMath.ts re-exports it), exos-api and vitest
// (src/lib/dealMath.test.ts) all run this one file.
//
// Every amount is an integer in minor units (cents). Percentages are 0..100.
// Each computed line is rounded half-up once.
//
// Deal types, per act (slot):
//   flat    the guarantee.
//   versus  the greater of the guarantee and percentage × (net box office
//           − expenses applied).
//   plus    the guarantee plus percentage × whatever net box office is left
//           above the split point (guarantee + expenses applied + promoter
//           profit, promoter profit = promoterProfitPercent × (guarantee +
//           expenses applied)).
//   door    percentage × net box office (no expenses), with the guarantee,
//           when set, as a floor.
// Expenses applied to a slot = the show's deal expenses (every expense line
// except the Talent category) + the guarantees of the OTHER slots (support
// costs), capped by the slot's expenses cap when it has one. Bonuses are
// cumulative: every threshold reached by paid tickets sold pays its amount.
// Merch: the slot gets merchArtistPercent of the merch income lines.
// Adjustments add (or, negative, subtract) after all that; a payout is
// never below 0.
//
// Pools (Opendate's offer pools, new here): slots that name a pool are paid
// a split of the pool's payout instead of their own deal. The pool's terms
// make one payout with the same rules (its support costs are the
// guarantees of the slots outside it), clamped to its floor and cap; each
// member with a poolShare gets that percentage of it, and members without
// one split what is left equally (any odd cents go to the first). Bonuses,
// merch, adjustments and deposits stay per member.

export const DEAL_TYPES = ['flat', 'versus', 'plus', 'door'] as const;
export type DealType = (typeof DEAL_TYPES)[number];

export const OFFER_STATUSES = ['draft', 'sent', 'accepted', 'declined', 'expired', 'cancelled'] as const;
export type OfferStatus = (typeof OFFER_STATUSES)[number];

/** Half-up to a whole minor unit (x ≥ 0 rounds .5 up; negatives mirror). */
export function roundHalfUp(x: number): number {
  if (!Number.isFinite(x)) return 0;
  const r = Math.floor(Math.abs(x) + 0.5 + 1e-9);
  return x < 0 ? -r : r;
}

/** A slot's deal terms in minor units. */
export interface DealTerms {
  dealType: DealType;
  guarantee: number;
  percentage: number;
  expensesCap: number | null;
  /** plus deals: promoter profit as a percentage of (guarantee + expenses applied). */
  promoterProfitPercent: number;
  /** Paid tickets sold → bonus amount. Cumulative. */
  bonuses: { sold: number; amount: number }[];
  /** Share of merch income lines that goes to this act; null = none. */
  merchArtistPercent: number | null;
  /** Deposit agreed (already paid when depositPaid). */
  deposit: number;
  depositPaid: boolean;
}

/** A pool's shared deal: the deal fields plus a payout floor and cap. */
export interface PoolTerms {
  dealType: DealType;
  guarantee: number;
  percentage: number;
  expensesCap: number | null;
  promoterProfitPercent: number;
  payoutCap: number | null;
  payoutFloor: number | null;
}

export interface PoolInput {
  poolId: string;
  terms: PoolTerms;
}

export interface SlotInput {
  slotId: string;
  name: string;
  terms: DealTerms;
  /** Sum of this slot's settlement adjustments (signed). */
  adjustments?: number;
  /** Paid from this pool instead of its own deal (when the pool is given). */
  poolId?: string | null;
  /** Percentage of the pool payout; null = an equal part of what is left. */
  poolShare?: number | null;
}

export interface DealInput {
  netBoxOffice: number;
  /** Paid tickets (comps excluded), including tickets sold elsewhere: drives bonuses. */
  paidSold: number;
  /** Expense lines in the acts' expense base (everything but Talent). */
  dealExpenses: number;
  merchIncome: number;
  slots: SlotInput[];
  pools?: PoolInput[];
}

export interface PoolResult {
  poolId: string;
  dealType: DealType;
  guarantee: number;
  percentage: number;
  supportCosts: number;
  expensesApplied: number;
  capped: boolean;
  splitPoint: number | null;
  percentageAmount: number;
  /** The deal's answer before the floor / cap. */
  base: number;
  /** After the floor and cap: what the members share. */
  payout: number;
  /** Paid to members (≤ payout; the rest stays with the house). */
  distributed: number;
}

export interface SlotResult {
  slotId: string;
  name: string;
  dealType: DealType;
  guarantee: number;
  percentage: number;
  /** Other slots' guarantees counted as this slot's expenses. */
  supportCosts: number;
  /** Expenses applied after the cap. */
  expensesApplied: number;
  /** True when the cap cut the expense base. */
  capped: boolean;
  /** Net box office at which the percentage starts to pay; null for flat. */
  splitPoint: number | null;
  /** The percentage side of the deal (versus / door) or the overage share (plus). */
  percentageAmount: number;
  /** Guarantee, percentage or pool split, whichever the deal pays, before bonuses. */
  base: number;
  bonus: number;
  merch: number;
  adjustments: number;
  /** base + bonus + merch + adjustments (never below 0). */
  payout: number;
  depositPaid: number;
  /** payout − deposit already paid. */
  balanceDue: number;
  /** Set when the slot is paid from a pool. */
  poolId: string | null;
  /** The share of the pool payout this slot got, in percent (explicit or derived). */
  poolSharePercent: number | null;
}

const pct = (amount: number, percent: number) => roundHalfUp((Math.max(0, amount) * percent) / 100);
const int = (n: unknown) => (typeof n === 'number' && Number.isFinite(n) ? Math.round(n) : 0);
const nonNeg = (n: unknown) => Math.max(0, int(n));
const clampPct = (n: unknown) => Math.min(100, Math.max(0, typeof n === 'number' && Number.isFinite(n) ? n : 0));

/** The smallest x with x × percent / 100 ≥ amount (net box office for a percentage to reach a guarantee). */
function reachAt(amount: number, percent: number): number | null {
  if (percent <= 0) return null;
  return Math.ceil((amount * 100) / percent - 1e-9);
}

interface BaseResult {
  guarantee: number;
  percentage: number;
  expensesApplied: number;
  capped: boolean;
  splitPoint: number | null;
  percentageAmount: number;
  base: number;
}

/** One deal's base answer, given the net box office and its expense base. */
function dealBase(
  t: { dealType: DealType; guarantee: number; percentage: number; expensesCap: number | null; promoterProfitPercent: number },
  nbor: number,
  expenseBase: number,
): BaseResult {
  const guarantee = nonNeg(t.guarantee);
  const percentage = clampPct(t.percentage);
  const cap = t.expensesCap === null || t.expensesCap === undefined ? null : nonNeg(t.expensesCap);
  const expensesApplied = cap === null ? expenseBase : Math.min(expenseBase, cap);
  const capped = cap !== null && expenseBase > cap;
  let base = guarantee;
  let percentageAmount = 0;
  let splitPoint: number | null = null;
  switch (t.dealType) {
    case 'versus': {
      percentageAmount = pct(nbor - expensesApplied, percentage);
      base = Math.max(guarantee, percentageAmount);
      const reach = reachAt(guarantee, percentage);
      splitPoint = reach === null ? null : expensesApplied + reach;
      break;
    }
    case 'plus': {
      const profit = pct(guarantee + expensesApplied, clampPct(t.promoterProfitPercent));
      splitPoint = guarantee + expensesApplied + profit;
      percentageAmount = pct(nbor - splitPoint, percentage);
      base = guarantee + percentageAmount;
      break;
    }
    case 'door': {
      percentageAmount = pct(nbor, percentage);
      base = Math.max(guarantee, percentageAmount);
      splitPoint = guarantee > 0 ? reachAt(guarantee, percentage) : 0;
      break;
    }
    default:
      base = guarantee;
  }
  return { guarantee, percentage, expensesApplied, capped, splitPoint, percentageAmount, base };
}

/** Pool results and slot results (input order) for one show. */
export function computeDealsWithPools(input: DealInput): { slots: SlotResult[]; pools: PoolResult[] } {
  const nbor = int(input.netBoxOffice);
  const dealExpenses = nonNeg(input.dealExpenses);
  const pools = new Map((input.pools ?? []).map((p) => [p.poolId, p]));
  const inPool = (s: SlotInput) => (s.poolId && pools.has(s.poolId) ? s.poolId : null);
  const independent = input.slots.filter((s) => !inPool(s));
  const usedPools = [...pools.values()].filter((p) => input.slots.some((s) => inPool(s) === p.poolId));
  const guaranteeTotal =
    independent.reduce((s, x) => s + nonNeg(x.terms.guarantee), 0) + usedPools.reduce((s, p) => s + nonNeg(p.terms.guarantee), 0);

  // Pools first: one payout each, then split among members.
  const poolResults: PoolResult[] = [];
  const memberPay = new Map<string, { base: number; share: number }>();
  for (const p of usedPools) {
    const t = p.terms;
    const supportCosts = guaranteeTotal - nonNeg(t.guarantee);
    const b = dealBase(t, nbor, dealExpenses + supportCosts);
    let payout = b.base;
    if (t.payoutFloor !== null && t.payoutFloor !== undefined) payout = Math.max(payout, nonNeg(t.payoutFloor));
    if (t.payoutCap !== null && t.payoutCap !== undefined) payout = Math.min(payout, nonNeg(t.payoutCap));
    const members = input.slots.filter((s) => inPool(s) === p.poolId);
    const explicit = members.filter((m) => m.poolShare !== null && m.poolShare !== undefined);
    const rest = members.filter((m) => m.poolShare === null || m.poolShare === undefined);
    const shareTotal = explicit.reduce((s, m) => s + clampPct(m.poolShare), 0);
    const scale = shareTotal > 100 ? 100 / shareTotal : 1;
    let given = 0;
    for (const m of explicit) {
      const share = clampPct(m.poolShare) * scale;
      const amount = pct(payout, share);
      given += amount;
      memberPay.set(m.slotId, { base: amount, share });
    }
    const left = Math.max(0, payout - given);
    if (rest.length) {
      const each = Math.floor(left / rest.length);
      let odd = left - each * rest.length;
      const restShare = Math.max(0, 100 - Math.min(100, shareTotal)) / rest.length;
      for (const m of rest) {
        const amount = each + (odd > 0 ? 1 : 0);
        if (odd > 0) odd--;
        given += amount;
        memberPay.set(m.slotId, { base: amount, share: Math.round(restShare * 1000) / 1000 });
      }
    }
    poolResults.push({
      poolId: p.poolId, dealType: t.dealType, guarantee: b.guarantee, percentage: b.percentage, supportCosts,
      expensesApplied: b.expensesApplied, capped: b.capped, splitPoint: b.splitPoint, percentageAmount: b.percentageAmount,
      base: b.base, payout, distributed: given,
    });
  }

  const slots = input.slots.map((slot): SlotResult => {
    const t = slot.terms;
    const poolId = inPool(slot);
    let core: BaseResult & { supportCosts: number };
    let poolSharePercent: number | null = null;
    if (poolId) {
      const pr = poolResults.find((x) => x.poolId === poolId)!;
      const pay = memberPay.get(slot.slotId) ?? { base: 0, share: 0 };
      poolSharePercent = pay.share;
      core = {
        guarantee: 0, percentage: pr.percentage, expensesApplied: pr.expensesApplied, capped: pr.capped,
        splitPoint: pr.splitPoint, percentageAmount: 0, base: pay.base, supportCosts: pr.supportCosts,
      };
    } else {
      const supportCosts = guaranteeTotal - nonNeg(t.guarantee);
      core = { ...dealBase(t, nbor, dealExpenses + supportCosts), supportCosts };
    }
    const bonus = (t.bonuses ?? [])
      .filter((b) => b.sold > 0 && input.paidSold >= b.sold)
      .reduce((s, b) => s + nonNeg(b.amount), 0);
    const merch = t.merchArtistPercent === null || t.merchArtistPercent === undefined ? 0 : pct(input.merchIncome, clampPct(t.merchArtistPercent));
    const adjustments = int(slot.adjustments ?? 0);
    const payout = Math.max(0, core.base + bonus + merch + adjustments);
    const depositPaid = t.depositPaid ? nonNeg(t.deposit) : 0;
    return {
      slotId: slot.slotId,
      name: slot.name,
      dealType: poolId ? (poolResults.find((x) => x.poolId === poolId)!.dealType) : t.dealType,
      guarantee: core.guarantee,
      percentage: core.percentage,
      supportCosts: core.supportCosts,
      expensesApplied: core.expensesApplied,
      capped: core.capped,
      splitPoint: core.splitPoint,
      percentageAmount: core.percentageAmount,
      base: core.base,
      bonus,
      merch,
      adjustments,
      payout,
      depositPaid,
      balanceDue: payout - depositPaid,
      poolId,
      poolSharePercent,
    };
  });
  return { slots, pools: poolResults };
}

/** Deal results, one per slot, in input order. */
export function computeDeals(input: DealInput): SlotResult[] {
  return computeDealsWithPools(input).slots;
}

// -- Settlement ----------------------------------------------------------------

export interface VenueTerms {
  /** Sum of the Venue rental expense lines (they are also in expensesTotal). */
  rentalFee: number;
  /** The venue's percentage of net box office, on top of the rental. */
  sharePercent: number;
  /** Rental deposit already paid to the venue. */
  depositPaid: number;
}

export interface SettlementInput {
  /** Face value of tickets sold, refunds excluded, tickets sold elsewhere included. */
  grossBoxOffice: number;
  /** Tax, fees and platform costs inside the price (and elsewhere's fees when known). */
  deductions: number;
  paidSold: number;
  /** Every expense line (Talent included). */
  expensesTotal: number;
  /** Expense lines in the Talent category: real costs, never in an act's expense base. */
  talentExpenses: number;
  /** Income lines other than merch. */
  otherIncome: number;
  merchIncome: number;
  slots: SlotInput[];
  pools?: PoolInput[];
  /** Adjustments not tied to an act (house side, signed). */
  houseAdjustments: number;
  /** Promoter mode (rented venue): what the venue is owed. */
  venue: VenueTerms | null;
}

export interface SettlementResult {
  grossBoxOffice: number;
  deductions: number;
  netBoxOffice: number;
  otherIncome: number;
  merchIncome: number;
  expensesTotal: number;
  dealExpenses: number;
  slots: SlotResult[];
  pools: PoolResult[];
  artistsTotal: number;
  venue: (VenueTerms & { share: number; total: number; balanceDue: number }) | null;
  houseAdjustments: number;
  /** What the promoter (or the venue, when it is its own room) keeps. */
  promoterNet: number;
}

export function computeSettlement(input: SettlementInput): SettlementResult {
  const gross = nonNeg(input.grossBoxOffice);
  const deductions = nonNeg(input.deductions);
  const netBoxOffice = gross - deductions;
  const expensesTotal = nonNeg(input.expensesTotal);
  const dealExpenses = Math.max(0, expensesTotal - nonNeg(input.talentExpenses));
  const deals = computeDealsWithPools({
    netBoxOffice,
    paidSold: input.paidSold,
    dealExpenses,
    merchIncome: input.merchIncome,
    slots: input.slots,
    pools: input.pools,
  });
  const artistsTotal = deals.slots.reduce((s, x) => s + x.payout, 0);
  let venue: SettlementResult['venue'] = null;
  if (input.venue) {
    const share = pct(netBoxOffice, clampPct(input.venue.sharePercent));
    const rentalFee = nonNeg(input.venue.rentalFee);
    const total = rentalFee + share;
    const depositPaid = nonNeg(input.venue.depositPaid);
    venue = { rentalFee, sharePercent: clampPct(input.venue.sharePercent), depositPaid, share, total, balanceDue: total - depositPaid };
  }
  const houseAdjustments = int(input.houseAdjustments);
  const otherIncome = nonNeg(input.otherIncome);
  const merchIncome = nonNeg(input.merchIncome);
  const promoterNet = netBoxOffice + otherIncome + merchIncome - expensesTotal - artistsTotal - (venue?.share ?? 0) + houseAdjustments;
  return {
    grossBoxOffice: gross,
    deductions,
    netBoxOffice,
    otherIncome,
    merchIncome,
    expensesTotal,
    dealExpenses,
    slots: deals.slots,
    pools: deals.pools,
    artistsTotal,
    venue,
    houseAdjustments,
    promoterNet,
  };
}

// -- Offer budget (forecast) ------------------------------------------------------

export interface BudgetInput {
  capacity: number;
  /** Average ticket price, minor units. */
  averagePrice: number;
  /** Share of capacity expected to sell, 0..100 (default 100). */
  sellThroughPercent?: number | null;
  /** Projected expense lines, minor units. */
  expenses: { amount: number; talent?: boolean }[];
  /** Projected income lines other than tickets (merch flagged). */
  income?: { amount: number; merch?: boolean }[];
  slots: SlotInput[];
  pools?: PoolInput[];
}

export interface BudgetResult {
  projectedSold: number;
  projectedGross: number;
  expensesTotal: number;
  slots: SlotResult[];
  pools: PoolResult[];
  artistsTotal: number;
  promoterNet: number;
  /** Paid tickets needed for promoter net ≥ 0; null when capacity is not enough. */
  breakEvenTickets: number | null;
  breakEvenGross: number | null;
}

function netAt(b: BudgetInput, sold: number, expensesTotal: number, talent: number): SettlementResult {
  const income = b.income ?? [];
  return computeSettlement({
    grossBoxOffice: sold * nonNeg(b.averagePrice),
    deductions: 0,
    paidSold: sold,
    expensesTotal,
    talentExpenses: talent,
    otherIncome: income.filter((x) => !x.merch).reduce((s, x) => s + nonNeg(x.amount), 0),
    merchIncome: income.filter((x) => x.merch).reduce((s, x) => s + nonNeg(x.amount), 0),
    slots: b.slots,
    pools: b.pools,
    houseAdjustments: 0,
    venue: null,
  });
}

export function projectBudget(b: BudgetInput): BudgetResult {
  const capacity = Math.max(0, Math.floor(b.capacity || 0));
  const sell = b.sellThroughPercent === undefined || b.sellThroughPercent === null ? 100 : clampPct(b.sellThroughPercent);
  const projectedSold = Math.floor((capacity * sell) / 100 + 1e-9);
  const expensesTotal = b.expenses.reduce((s, e) => s + nonNeg(e.amount), 0);
  const talent = b.expenses.filter((e) => e.talent).reduce((s, e) => s + nonNeg(e.amount), 0);
  const at = netAt(b, projectedSold, expensesTotal, talent);

  // Break-even: the fewest paid tickets with promoter net ≥ 0, searching
  // 0..capacity. Promoter net rises with sales for every deal type (an act's
  // percentage is below 100 %), except at bonus thresholds, so a binary
  // search finds a candidate and a short walk back settles it.
  let breakEvenTickets: number | null = null;
  if (netAt(b, capacity, expensesTotal, talent).promoterNet >= 0) {
    let lo = 0;
    let hi = capacity;
    while (lo < hi) {
      const mid = Math.floor((lo + hi) / 2);
      if (netAt(b, mid, expensesTotal, talent).promoterNet >= 0) hi = mid;
      else lo = mid + 1;
    }
    let n = lo;
    for (let i = 0; i < 50 && n > 0 && netAt(b, n - 1, expensesTotal, talent).promoterNet >= 0; i++) n--;
    breakEvenTickets = n;
  }
  return {
    projectedSold,
    projectedGross: at.grossBoxOffice,
    expensesTotal,
    slots: at.slots,
    pools: at.pools,
    artistsTotal: at.artistsTotal,
    promoterNet: at.promoterNet,
    breakEvenTickets,
    breakEvenGross: breakEvenTickets === null ? null : breakEvenTickets * nonNeg(b.averagePrice),
  };
}

// -- Sales pace (estimate) ------------------------------------------------------------

export interface PaceInput {
  /** Paid tickets sold so far. */
  sold: number;
  /** Gross so far, minor units. */
  gross: number;
  capacity: number;
  /** When selling started (first sale or on-sale), ms. */
  startedAt: number | null;
  /** Show start, ms. */
  eventAt: number | null;
  now: number;
  /** Price for the rest when nothing sold yet, minor units. */
  fallbackPrice?: number;
}

/** Sales at the current pace by show time, capped at capacity. */
export function paceEstimate(p: PaceInput): { estimatedSold: number; estimatedGross: number; perDay: number } {
  const DAY = 86_400_000;
  const sold = Math.max(0, Math.floor(p.sold));
  const gross = nonNeg(p.gross);
  if (!p.eventAt || p.eventAt <= p.now || !p.startedAt) {
    return { estimatedSold: sold, estimatedGross: gross, perDay: 0 };
  }
  const elapsedDays = Math.max(1, (p.now - p.startedAt) / DAY);
  const perDay = sold / elapsedDays;
  const daysLeft = (p.eventAt - p.now) / DAY;
  const cap = Math.max(sold, Math.floor(p.capacity || 0));
  const estimatedSold = Math.min(cap, sold + Math.round(perDay * daysLeft));
  const avg = sold > 0 ? gross / sold : Math.max(0, p.fallbackPrice ?? 0);
  return { estimatedSold, estimatedGross: gross + Math.round(avg * (estimatedSold - sold)), perDay: Math.round(perDay * 100) / 100 };
}

// -- Box office -----------------------------------------------------------------------

/** Exos sales as _exos_box_office returns them (minor units). */
export interface ExosSales {
  tiers: { tier_id: string | null; name: string; paid: number; comps: number; gross_cents: number }[];
  paid_sold: number;
  comps: number;
  sold_last_24h: number;
  first_sale_at: string | null;
  gross_cents: number;
  refunded_cents?: number;
  tax_cents: number;
  passed_on_fees_cents: number;
  absorbed_fees_cents: number;
  platform_fees_cents: number;
}

/** One line of tickets sold elsewhere (exos_sales_count_totals), per currency. */
export interface SoldElsewhereLine {
  currency: string;
  sold: number;
  gross_cents: number;
  entries?: number;
}

export interface BoxOffice {
  /** Exos gross + sold elsewhere in the show's currency. */
  gross: number;
  deductions: number;
  net: number;
  deductionLines: { tax: number; passedOnFees: number; absorbedFees: number; platformFees: number };
  /** Paid tickets (Exos + elsewhere in the show's currency). */
  paidSold: number;
  /** $0 tickets: comps, guest list. Attendance, not revenue. */
  comps: number;
  attendance: number;
  soldLast24h: number;
  byTier: { tierId: string; tierName: string; sold: number; comps: number; gross: number }[];
  elsewhere: { currency: string; sold: number; gross: number; included: boolean }[];
  /** Earliest sale, ms (sales pace). */
  firstSaleAt: number | null;
}

export function boxOffice(sales: ExosSales | null | undefined, elsewhere: SoldElsewhereLine[] | null | undefined, currency: string): BoxOffice {
  const s = sales ?? {
    tiers: [], paid_sold: 0, comps: 0, sold_last_24h: 0, first_sale_at: null, gross_cents: 0,
    tax_cents: 0, passed_on_fees_cents: 0, absorbed_fees_cents: 0, platform_fees_cents: 0,
  };
  const deductionLines = {
    tax: nonNeg(s.tax_cents), passedOnFees: nonNeg(s.passed_on_fees_cents),
    absorbedFees: nonNeg(s.absorbed_fees_cents), platformFees: nonNeg(s.platform_fees_cents),
  };
  let gross = nonNeg(s.gross_cents);
  let paidSold = nonNeg(s.paid_sold);
  const ext: BoxOffice['elsewhere'] = [];
  for (const e of elsewhere ?? []) {
    if (!e || typeof e !== 'object') continue;
    const cur = String(e.currency || '').toUpperCase();
    const included = cur === currency.toUpperCase();
    ext.push({ currency: cur, sold: nonNeg(e.sold), gross: nonNeg(e.gross_cents), included });
    if (!included) continue;
    gross += nonNeg(e.gross_cents);
    paidSold += nonNeg(e.sold);
  }
  const deductions = deductionLines.tax + deductionLines.passedOnFees + deductionLines.absorbedFees + deductionLines.platformFees;
  const comps = nonNeg(s.comps);
  const first = s.first_sale_at ? Date.parse(s.first_sale_at) : NaN;
  return {
    gross,
    deductions,
    net: gross - deductions,
    deductionLines,
    paidSold,
    comps,
    attendance: paidSold + comps,
    soldLast24h: nonNeg(s.sold_last_24h),
    byTier: (s.tiers ?? []).map((t) => ({
      tierId: t.tier_id ?? 'unknown', tierName: t.name || 'Tickets', sold: nonNeg(t.paid), comps: nonNeg(t.comps), gross: nonNeg(t.gross_cents),
    })).sort((a, b) => b.sold - a.sold || a.tierName.localeCompare(b.tierName)),
    elsewhere: ext,
    firstSaleAt: Number.isFinite(first) ? first : null,
  };
}

/** Default org finance categories (seeded by _exos_fin_seed). Keys are stable. */
export const DEFAULT_FINANCE_CATEGORIES: readonly { key: string; name: string; kind: 'income' | 'expense' | 'both'; system: boolean }[] = [
  { key: 'talent', name: 'Talent', kind: 'expense', system: true },
  { key: 'production', name: 'Production', kind: 'expense', system: false },
  { key: 'marketing', name: 'Marketing', kind: 'expense', system: false },
  { key: 'hospitality', name: 'Hospitality', kind: 'expense', system: false },
  { key: 'venue-rental', name: 'Venue rental', kind: 'expense', system: true },
  { key: 'staff', name: 'Staff', kind: 'expense', system: false },
  { key: 'bar-income', name: 'Bar/F&B income', kind: 'income', system: false },
  { key: 'merch-income', name: 'Merch income', kind: 'income', system: true },
  { key: 'other', name: 'Other', kind: 'both', system: true },
];

/** Category keys the math treats specially. */
export const TALENT_CATEGORY = 'talent';
export const VENUE_RENTAL_CATEGORY = 'venue-rental';
export const MERCH_CATEGORY = 'merch-income';
