// From the settlement inputs the database gathers (_exos_settlement_inputs,
// mig 20261031100500) to a settlement, a per-show profit and loss and the
// org-wide P&L table. Pure TypeScript with no Deno or Supabase imports: the
// dashboard, the settlement contacts' page and exos-api all run it, so the
// numbers agree everywhere (docs/offers-settlements.md).

import {
  boxOffice, computeSettlement, paceEstimate, type BoxOffice, type DealTerms, type DealType, type PoolInput,
  type PoolTerms, type SettlementResult, type SlotInput, type ExosSales, type SoldElsewhereLine,
  MERCH_CATEGORY, TALENT_CATEGORY, VENUE_RENTAL_CATEGORY,
} from './dealMath.ts';

// ── The inputs, as the database returns them ─────────────────────────────

/** Deal terms as stored (_exos_deal_terms). */
export interface TermsJson {
  deal_type?: string;
  guarantee_cents?: number;
  percentage?: number;
  expenses_cap_cents?: number | null;
  promoter_profit_percent?: number;
  bonuses?: { sold: number; amount_cents: number }[];
  merch_artist_percent?: number | null;
  deposit_cents?: number;
  deposit_due_on?: string | null;
  hospitality?: string;
  rider?: string;
  payout_cap_cents?: number | null;
  payout_floor_cents?: number | null;
}

export interface ItemJson {
  id?: string;
  kind: 'income' | 'expense';
  label: string;
  category_id?: string | null;
  category_key: string | null;
  category_name: string | null;
  gl_code?: string | null;
  amount_cents: number;
  forecast_cents: number | null;
  estimate_cents: number | null;
  actual_cents: number | null;
  auto?: string | null;
  notes?: string;
}

export interface OfferJson {
  id: string;
  budget_id: string;
  artist_name: string;
  act_type?: string;
  status: string;
  currency?: string;
  terms: TermsJson;
  pool_share_percent: number | null;
}

export interface AdjustmentJson {
  id: string;
  offer_id: string | null;
  label: string;
  amount_cents: number;
  reason: string;
  by?: string | null;
  at?: string;
}

export interface BudgetLineJson {
  kind: 'income' | 'expense';
  label: string;
  category_id?: string | null;
  category_key: string | null;
  amount_cents: number;
}

export interface SettlementInputs {
  version: number;
  computed_at: string;
  event: {
    id: string; name: string; status: string; starts_at: string | null; timezone: string | null; currency: string;
    capacity: number; venue: { id: string; name: string; relationship: string } | null; venue_name: string | null;
    hold_id: string | null;
  };
  box_office: ExosSales;
  sold_elsewhere: { available: boolean; lines: SoldElsewhereLine[] };
  items: ItemJson[];
  offers: OfferJson[];
  pools: { budget_id: string; mode: 'independent' | 'pool'; terms: TermsJson }[];
  budget: {
    id: string; name: string; currency: string; capacity: number; average_price_cents: number;
    sell_through_percent: number; lines: BudgetLineJson[];
    offers: { id: string; artist_name: string; status: string; terms: TermsJson; pool_share_percent: number | null }[];
    pool: { mode: 'independent' | 'pool'; terms: TermsJson } | null;
  } | null;
  rental: { status: string; fee_cents: number; deposit_cents: number; currency: string } | null;
  promoter_mode: boolean;
  settlement: {
    adjustments: AdjustmentJson[];
    deposits_paid: Record<string, boolean>;
    venue_share_percent: number;
    venue_deposit_paid_cents: number;
  };
}

// ── Conversions ───────────────────────────────────────────────────────────

const num = (v: unknown): number => {
  const n = typeof v === 'string' ? Number(v) : v;
  return typeof n === 'number' && Number.isFinite(n) ? n : 0;
};
const optNum = (v: unknown): number | null => (v === null || v === undefined || v === '' ? null : num(v));
const DEALS: readonly string[] = ['flat', 'versus', 'plus', 'door'];
const dealType = (v: unknown): DealType => (DEALS.includes(String(v)) ? (v as DealType) : 'flat');

export function termsFromJson(t: TermsJson | null | undefined, depositPaid = false): DealTerms {
  const x = t ?? {};
  return {
    dealType: dealType(x.deal_type),
    guarantee: num(x.guarantee_cents),
    percentage: num(x.percentage),
    expensesCap: optNum(x.expenses_cap_cents),
    promoterProfitPercent: num(x.promoter_profit_percent),
    bonuses: (x.bonuses ?? []).map((b) => ({ sold: num(b.sold), amount: num(b.amount_cents) })),
    merchArtistPercent: optNum(x.merch_artist_percent),
    deposit: num(x.deposit_cents),
    depositPaid,
  };
}

export function poolTermsFromJson(t: TermsJson | null | undefined): PoolTerms {
  const x = t ?? {};
  return {
    dealType: dealType(x.deal_type),
    guarantee: num(x.guarantee_cents),
    percentage: num(x.percentage),
    expensesCap: optNum(x.expenses_cap_cents),
    promoterProfitPercent: num(x.promoter_profit_percent),
    payoutCap: optNum(x.payout_cap_cents),
    payoutFloor: optNum(x.payout_floor_cents),
  };
}

/** What an item counts at in each P&L column. */
export function itemAt(i: ItemJson, column: 'forecast' | 'estimate' | 'actual'): number {
  if (column === 'actual') return num(i.actual_cents ?? i.amount_cents);
  if (column === 'estimate') return num(i.estimate_cents ?? i.actual_cents ?? i.amount_cents);
  return num(i.forecast_cents ?? i.amount_cents);
}

interface Money {
  expensesTotal: number;
  talentExpenses: number;
  rental: number;
  merchIncome: number;
  otherIncome: number;
}

function sumLines(lines: { kind: string; category_key: string | null; amount: number }[]): Money {
  const m: Money = { expensesTotal: 0, talentExpenses: 0, rental: 0, merchIncome: 0, otherIncome: 0 };
  for (const l of lines) {
    const a = Math.max(0, Math.round(l.amount));
    if (l.kind === 'expense') {
      m.expensesTotal += a;
      if (l.category_key === TALENT_CATEGORY) m.talentExpenses += a;
      if (l.category_key === VENUE_RENTAL_CATEGORY) m.rental += a;
    } else if (l.category_key === MERCH_CATEGORY) m.merchIncome += a;
    else m.otherIncome += a;
  }
  return m;
}

/** Acts (accepted offers in the show's currency) and pools in pool mode. */
function actsOf(
  offers: { id: string; artist_name: string; currency?: string; terms: TermsJson; pool_share_percent: number | null; budget_id?: string }[],
  pools: { budget_id: string; mode: string; terms: TermsJson }[],
  currency: string,
  depositsPaid: Record<string, boolean>,
  adjustments: AdjustmentJson[],
): { slots: SlotInput[]; pools: PoolInput[]; excluded: string[] } {
  const live = pools.filter((p) => p.mode === 'pool');
  const excluded: string[] = [];
  const slots: SlotInput[] = [];
  for (const o of offers) {
    if (o.currency && o.currency.toUpperCase() !== currency.toUpperCase()) {
      excluded.push(o.id);
      continue;
    }
    const pool = o.budget_id ? live.find((p) => p.budget_id === o.budget_id) : undefined;
    slots.push({
      slotId: o.id,
      name: o.artist_name,
      terms: termsFromJson(o.terms, depositsPaid[o.id] === true),
      adjustments: adjustments.filter((a) => a.offer_id === o.id).reduce((s, a) => s + num(a.amount_cents), 0),
      poolId: pool ? pool.budget_id : null,
      poolShare: o.pool_share_percent === null || o.pool_share_percent === undefined ? null : num(o.pool_share_percent),
    });
  }
  return {
    slots,
    pools: live.filter((p) => slots.some((s) => s.poolId === p.budget_id)).map((p) => ({ poolId: p.budget_id, terms: poolTermsFromJson(p.terms) })),
    excluded,
  };
}

// ── Settlement ────────────────────────────────────────────────────────────

export interface SettlementView {
  currency: string;
  boxOffice: BoxOffice;
  result: SettlementResult;
  /** Accepted offers in another currency (listed, not settled). */
  excludedOffers: string[];
  /** Adjustments not tied to an act on the show. */
  houseAdjustments: AdjustmentJson[];
}

export function settle(inp: SettlementInputs): SettlementView {
  const currency = (inp.event.currency || 'USD').toUpperCase();
  const bo = boxOffice(inp.box_office, inp.sold_elsewhere?.lines ?? [], currency);
  const m = sumLines((inp.items ?? []).map((i) => ({ kind: i.kind, category_key: i.category_key, amount: itemAt(i, 'actual') })));
  const adjustments = inp.settlement?.adjustments ?? [];
  const acts = actsOf(inp.offers ?? [], inp.pools ?? [], currency, inp.settlement?.deposits_paid ?? {}, adjustments);
  const actIds = new Set(acts.slots.map((s) => s.slotId));
  const house = adjustments.filter((a) => !a.offer_id || !actIds.has(a.offer_id));
  const result = computeSettlement({
    grossBoxOffice: bo.gross,
    deductions: bo.deductions,
    paidSold: bo.paidSold,
    expensesTotal: m.expensesTotal,
    talentExpenses: m.talentExpenses,
    otherIncome: m.otherIncome,
    merchIncome: m.merchIncome,
    slots: acts.slots,
    pools: acts.pools,
    houseAdjustments: house.reduce((s, a) => s + num(a.amount_cents), 0),
    venue: inp.promoter_mode
      ? { rentalFee: m.rental, sharePercent: num(inp.settlement?.venue_share_percent), depositPaid: num(inp.settlement?.venue_deposit_paid_cents) }
      : null,
  });
  return { currency, boxOffice: bo, result, excludedOffers: acts.excluded, houseAdjustments: house };
}

// ── Profit and loss ───────────────────────────────────────────────────────

export type PnlColumn = 'forecast' | 'estimate' | 'actual';
export const PNL_COLUMNS: readonly PnlColumn[] = ['forecast', 'estimate', 'actual'];

export interface PnlRow {
  key: string;
  label: string;
  section: 'revenue' | 'income' | 'expense' | 'payout' | 'result';
  forecast: number;
  estimate: number;
  actual: number;
}

export interface ShowPnl {
  currency: string;
  rows: PnlRow[];
  net: Record<PnlColumn, number>;
  /** Tickets behind each column. */
  sold: Record<PnlColumn, number>;
}

interface ColumnNumbers {
  gross: number;
  deductions: number;
  sold: number;
  lines: { kind: string; category_key: string | null; label: string; amount: number }[];
  result: SettlementResult;
}

/**
 * One show's P&L in three columns:
 *  - forecast: the budget (capacity × sell-through × average price, its
 *    lines, items with an explicit forecast in place of the budget lines of
 *    their category) and the deal math on it;
 *  - estimate: sales so far plus the current pace until the show (capped at
 *    capacity), items at estimate (else actual, else amount), budget lines
 *    for categories without items;
 *  - actual: the settlement (the snapshot when finalized, else live).
 */
export function showPnl(inp: SettlementInputs, now: number = Date.now()): ShowPnl {
  const view = settle(inp);
  const currency = view.currency;
  const items = inp.items ?? [];
  const budget = inp.budget && inp.budget.currency.toUpperCase() === currency ? inp.budget : null;
  const budgetLines = (budget?.lines ?? []).map((l) => ({ kind: l.kind, category_key: l.category_key, label: l.label, amount: num(l.amount_cents) }));
  const itemCats = new Set(items.map((i) => i.category_key ?? `label:${i.label}`));
  const settlementInfo = inp.settlement ?? { adjustments: [], deposits_paid: {}, venue_share_percent: 0, venue_deposit_paid_cents: 0 };

  // Forecast and estimate acts: the accepted offers, else the budget's open ones.
  const forecastOffers = (inp.offers?.length ? inp.offers : (budget?.offers ?? []).map((o) => ({ ...o, budget_id: budget!.id, currency })));
  const forecastPools = inp.offers?.length ? (inp.pools ?? []) : (budget?.pool ? [{ budget_id: budget.id, ...budget.pool }] : []);
  const acts = actsOf(forecastOffers, forecastPools, currency, {}, []);

  const run = (gross: number, deductions: number, sold: number, lines: ColumnNumbers['lines']): ColumnNumbers => {
    const m = sumLines(lines);
    const result = computeSettlement({
      grossBoxOffice: gross, deductions, paidSold: sold, expensesTotal: m.expensesTotal, talentExpenses: m.talentExpenses,
      otherIncome: m.otherIncome, merchIncome: m.merchIncome, slots: acts.slots, pools: acts.pools, houseAdjustments: 0,
      venue: inp.promoter_mode ? { rentalFee: m.rental, sharePercent: num(settlementInfo.venue_share_percent), depositPaid: 0 } : null,
    });
    return { gross, deductions, sold, lines, result };
  };

  // Forecast.
  const capacity = Math.max(0, Math.floor(num(budget?.capacity ?? inp.event.capacity)));
  const sell = budget ? Math.min(100, Math.max(0, num(budget.sell_through_percent))) : 100;
  const fSold = Math.floor((capacity * sell) / 100 + 1e-9);
  const fGross = fSold * num(budget?.average_price_cents ?? 0);
  const forecastedCats = new Set(items.filter((i) => i.forecast_cents !== null && i.forecast_cents !== undefined)
    .map((i) => i.category_key ?? `label:${i.label}`));
  const fLines = [
    ...budgetLines.filter((l) => !forecastedCats.has(l.category_key ?? `label:${l.label}`)),
    ...items.filter((i) => i.forecast_cents !== null && i.forecast_cents !== undefined)
      .map((i) => ({ kind: i.kind, category_key: i.category_key, label: i.category_name ?? i.label, amount: num(i.forecast_cents) })),
  ];
  const forecast = run(fGross, 0, fSold, fLines);

  // Estimate.
  const bo = view.boxOffice;
  const pace = paceEstimate({
    sold: bo.paidSold, gross: bo.gross, capacity: Math.max(capacity, num(inp.event.capacity)),
    startedAt: bo.firstSaleAt, eventAt: inp.event.starts_at ? Date.parse(inp.event.starts_at) : null, now,
    fallbackPrice: num(budget?.average_price_cents ?? 0),
  });
  const eDeductions = bo.gross > 0 ? Math.round((bo.deductions * pace.estimatedGross) / bo.gross) : 0;
  const eLines = [
    ...budgetLines.filter((l) => !itemCats.has(l.category_key ?? `label:${l.label}`)),
    ...items.map((i) => ({ kind: i.kind, category_key: i.category_key, label: i.category_name ?? i.label, amount: itemAt(i, 'estimate') })),
  ];
  const estimate = run(pace.estimatedGross, eDeductions, pace.estimatedSold, eLines);

  // Actual: the settlement itself.
  const aLines = items.map((i) => ({ kind: i.kind, category_key: i.category_key, label: i.category_name ?? i.label, amount: itemAt(i, 'actual') }));
  const actual: ColumnNumbers = { gross: bo.gross, deductions: bo.deductions, sold: bo.paidSold, lines: aLines, result: view.result };

  const cols: Record<PnlColumn, ColumnNumbers> = { forecast, estimate, actual };
  const rows: PnlRow[] = [];
  const row = (key: string, label: string, section: PnlRow['section'], f: (c: ColumnNumbers) => number) =>
    rows.push({ key, label, section, forecast: f(forecast), estimate: f(estimate), actual: f(actual) });
  row('gross', 'Gross box office', 'revenue', (c) => c.gross);
  row('deductions', 'Taxes and fees', 'revenue', (c) => -c.deductions);
  row('net_box_office', 'Net box office', 'revenue', (c) => c.gross - c.deductions);
  for (const kind of ['income', 'expense'] as const) {
    const labels = new Map<string, string>();
    for (const c of PNL_COLUMNS) {
      for (const l of cols[c].lines) if (l.kind === kind) labels.set(l.category_key ?? `label:${l.label}`, l.label);
    }
    for (const [key, label] of labels) {
      const sum = (c: ColumnNumbers) => c.lines.filter((l) => l.kind === kind && (l.category_key ?? `label:${l.label}`) === key)
        .reduce((s, l) => s + Math.max(0, Math.round(l.amount)), 0) * (kind === 'expense' ? -1 : 1);
      row(`${kind}:${key}`, label, kind, sum);
    }
  }
  row('artist_payouts', 'Artist payouts', 'payout', (c) => -c.result.artistsTotal);
  if (inp.promoter_mode) row('venue_share', 'Venue share', 'payout', (c) => -(c.result.venue?.share ?? 0));
  if (view.result.houseAdjustments) row('adjustments', 'Adjustments', 'payout', (c) => (c === actual ? c.result.houseAdjustments : 0));
  row('net', 'Net', 'result', (c) => c.result.promoterNet);
  return {
    currency,
    rows,
    net: { forecast: forecast.result.promoterNet, estimate: estimate.result.promoterNet, actual: view.result.promoterNet },
    sold: { forecast: fSold, estimate: pace.estimatedSold, actual: bo.paidSold },
  };
}

// ── Org-wide P&L ──────────────────────────────────────────────────────────

export interface OrgPnlShow {
  eventId: string;
  name: string;
  startsAt: string | null;
  currency: string;
  finalized: boolean;
  gross: number;
  expenses: number;
  payouts: number;
  net: Record<PnlColumn, number>;
}

export interface OrgPnl {
  shows: OrgPnlShow[];
  /** Per currency: never summed across currencies. */
  totals: { currency: string; shows: number; gross: number; expenses: number; payouts: number; net: Record<PnlColumn, number> }[];
}

export function orgPnl(list: { event_id: string; finalized: boolean; inputs: SettlementInputs | null }[], now: number = Date.now()): OrgPnl {
  const shows: OrgPnlShow[] = [];
  for (const s of list) {
    if (!s.inputs) continue;
    const p = showPnl(s.inputs, now);
    const v = settle(s.inputs);
    shows.push({
      eventId: s.event_id, name: s.inputs.event.name, startsAt: s.inputs.event.starts_at, currency: p.currency,
      finalized: s.finalized, gross: v.result.grossBoxOffice, expenses: v.result.expensesTotal,
      payouts: v.result.artistsTotal + (v.result.venue?.share ?? 0), net: p.net,
    });
  }
  const by = new Map<string, OrgPnl['totals'][number]>();
  for (const s of shows) {
    const t = by.get(s.currency) ?? { currency: s.currency, shows: 0, gross: 0, expenses: 0, payouts: 0, net: { forecast: 0, estimate: 0, actual: 0 } };
    t.shows += 1;
    t.gross += s.gross;
    t.expenses += s.expenses;
    t.payouts += s.payouts;
    for (const c of PNL_COLUMNS) t.net[c] += s.net[c];
    by.set(s.currency, t);
  }
  return { shows, totals: [...by.values()].sort((a, b) => a.currency.localeCompare(b.currency)) };
}

const csvCell = (v: unknown): string => {
  let s = v === null || v === undefined ? '' : String(v);
  // Spreadsheet formula injection: a leading = + - @ (or tab / CR) is text.
  if (/^[=+\-@\t\r]/.test(s) && !/^-?\d+(\.\d+)?$/.test(s)) s = `'${s}`;
  return /[",\n\r]/.test(s) ? `"${s.replace(/"/g, '""')}"` : s;
};
const major = (cents: number) => (Math.round(cents) / 100).toFixed(2);

/** The org-wide P&L as CSV (amounts in major units, one currency per row). */
export function orgPnlCsv(p: OrgPnl): string {
  const head = ['event_id', 'show', 'starts_at', 'currency', 'finalized', 'gross', 'expenses', 'payouts', 'net_forecast', 'net_estimate', 'net_actual'];
  const lines = [head.join(',')];
  for (const s of p.shows) {
    lines.push([s.eventId, s.name, s.startsAt ?? '', s.currency, s.finalized ? 'yes' : 'no', major(s.gross), major(s.expenses),
      major(s.payouts), major(s.net.forecast), major(s.net.estimate), major(s.net.actual)].map(csvCell).join(','));
  }
  for (const t of p.totals) {
    lines.push(['', `Total (${t.shows} show${t.shows === 1 ? '' : 's'})`, '', t.currency, '', major(t.gross), major(t.expenses), major(t.payouts),
      major(t.net.forecast), major(t.net.estimate), major(t.net.actual)].map(csvCell).join(','));
  }
  return lines.join('\r\n') + '\r\n';
}

/** One show's P&L as CSV. */
export function showPnlCsv(p: ShowPnl): string {
  const lines = [['line', 'section', 'currency', 'forecast', 'estimate', 'actual'].join(',')];
  for (const r of p.rows) lines.push([r.label, r.section, p.currency, major(r.forecast), major(r.estimate), major(r.actual)].map(csvCell).join(','));
  return lines.join('\r\n') + '\r\n';
}

/** "$1,234.56" (falls back to "1234.56 XYZ" for an unknown currency). */
export function formatCents(cents: number, currency: string): string {
  const cur = (currency || 'USD').toUpperCase();
  try {
    return new Intl.NumberFormat('en-US', { style: 'currency', currency: cur }).format(Math.round(cents) / 100);
  } catch {
    return `${(Math.round(cents) / 100).toFixed(2)} ${cur}`;
  }
}

/** A one-line description of a deal, e.g. "$1,000.00 vs 85% of net after expenses". */
export function describeDeal(t: TermsJson, currency: string): string {
  const g = formatCents(num(t.guarantee_cents), currency);
  const p = `${num(t.percentage)}%`;
  switch (dealType(t.deal_type)) {
    case 'versus': return `${g} versus ${p} of net after expenses`;
    case 'plus': return `${g} plus ${p} of net above the split point`;
    case 'door': return num(t.guarantee_cents) > 0 ? `${p} of net box office, ${g} minimum` : `${p} of net box office`;
    default: return `${g} flat`;
  }
}
