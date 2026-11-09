// Offer imports from a spreadsheet saved as CSV (docs/offers-settlements.md).
// The browser parses and maps the columns; exos_offer_import (mig
// 20261031100000) validates every row again and creates the drafts, a bad
// row reported, the others kept. Pure: tested in offerImport.test.ts.
//
// Columns (any order, case and spacing ignored; the first row is the header):
//   artist (or artist_name, act), title (or event, event_name), date / dates
//   (YYYY-MM-DD, several split by ";"), deal (flat | versus | plus | door),
//   guarantee, percentage, expenses_cap, promoter_profit, deposit (amounts in
//   major units: 1500 or 1,500.00), act_type, agent, agent_email,
//   agent_company, capacity, average_price, sell_through, group (rows with
//   the same group share one budget: a lineup), notes.

/** RFC 4180 CSV: quoted fields, doubled quotes, CRLF or LF. */
export function parseCsv(text: string): string[][] {
  const rows: string[][] = [];
  let row: string[] = [];
  let cell = '';
  let quoted = false;
  const src = text.replace(/^﻿/, '');
  for (let i = 0; i < src.length; i++) {
    const ch = src[i];
    if (quoted) {
      if (ch === '"') {
        if (src[i + 1] === '"') { cell += '"'; i++; } else quoted = false;
      } else cell += ch;
    } else if (ch === '"' && cell === '') quoted = true;
    else if (ch === ',') { row.push(cell); cell = ''; }
    else if (ch === '\n' || ch === '\r') {
      if (ch === '\r' && src[i + 1] === '\n') i++;
      row.push(cell); cell = '';
      if (row.some((c) => c.trim() !== '')) rows.push(row);
      row = [];
    } else cell += ch;
  }
  row.push(cell);
  if (row.some((c) => c.trim() !== '')) rows.push(row);
  return rows;
}

const COLUMNS: Record<string, string[]> = {
  artist_name: ['artist', 'artist_name', 'act', 'performer'],
  title: ['title', 'event', 'event_name', 'show'],
  dates: ['date', 'dates', 'show_date'],
  deal_type: ['deal', 'deal_type', 'type'],
  guarantee: ['guarantee', 'dollar_amount', 'fee'],
  percentage: ['percentage', 'percent', 'upside_percentage', 'split'],
  expenses_cap: ['expenses_cap', 'cap'],
  promoter_profit: ['promoter_profit', 'promoter_profit_percent'],
  deposit: ['deposit'],
  act_type: ['act_type', 'billing'],
  agent_name: ['agent', 'agent_name'],
  agent_email: ['agent_email', 'email'],
  agent_company: ['agent_company', 'agency'],
  capacity: ['capacity'],
  average_price: ['average_price', 'avg_price', 'ticket_price'],
  sell_through: ['sell_through', 'sell_through_percent'],
  group: ['group', 'lineup', 'budget'],
  notes: ['notes', 'note'],
};

const norm = (h: string) => h.trim().toLowerCase().replace(/[\s-]+/g, '_');

/** A major-unit amount ("1,500.00", "$1500") as cents, or an error. */
export function toCents(v: string): number | null {
  const s = v.trim().replace(/[$€£,\s]/g, '');
  if (!s) return null;
  if (!/^\d+(\.\d{1,2})?$/.test(s)) return Number.NaN;
  return Math.round(Number(s) * 100);
}

export interface ImportPlan {
  rows: Record<string, unknown>[];
  /** Problems found before sending (1-based data row numbers). */
  errors: { row: number; error: string }[];
  /** Header names that matched nothing (ignored). */
  ignored: string[];
}

export function planOfferImport(csv: string): ImportPlan {
  const table = parseCsv(csv);
  if (table.length < 2) return { rows: [], errors: [{ row: 0, error: 'The file needs a header row and at least one offer.' }], ignored: [] };
  const header = table[0].map(norm);
  const at: Record<string, number> = {};
  const ignored: string[] = [];
  header.forEach((h, i) => {
    const key = Object.keys(COLUMNS).find((k) => COLUMNS[k].includes(h));
    if (key && at[key] === undefined) at[key] = i;
    else if (h) ignored.push(table[0][i].trim());
  });
  const rows: Record<string, unknown>[] = [];
  const errors: ImportPlan['errors'] = [];
  if (at.artist_name === undefined) errors.push({ row: 0, error: 'No artist column.' });
  if (table.length - 1 > 200) errors.push({ row: 0, error: 'At most 200 offers per import.' });
  if (errors.length) return { rows, errors, ignored };

  table.slice(1).forEach((r, idx) => {
    const n = idx + 1;
    const get = (k: string) => (at[k] === undefined ? '' : (r[at[k]] ?? '').trim());
    const problems: string[] = [];
    const money = (k: string, label: string) => {
      const c = toCents(get(k));
      if (c !== null && Number.isNaN(c)) problems.push(`${label} is not an amount`);
      return c === null || Number.isNaN(c) ? undefined : c;
    };
    const pct = (k: string, label: string) => {
      const s = get(k).replace('%', '');
      if (!s) return undefined;
      const v = Number(s);
      if (!Number.isFinite(v) || v < 0 || v > 100) { problems.push(`${label} must be 0-100`); return undefined; }
      return v;
    };
    const terms: Record<string, unknown> = {};
    const deal = get('deal_type').toLowerCase();
    if (deal) terms.deal_type = deal;
    const g = money('guarantee', 'guarantee'); if (g !== undefined) terms.guarantee_cents = g;
    const p = pct('percentage', 'percentage'); if (p !== undefined) terms.percentage = p;
    const cap = money('expenses_cap', 'expenses cap'); if (cap !== undefined) terms.expenses_cap_cents = cap;
    const pp = pct('promoter_profit', 'promoter profit'); if (pp !== undefined) terms.promoter_profit_percent = pp;
    const dep = money('deposit', 'deposit'); if (dep !== undefined) terms.deposit_cents = dep;
    const dates = get('dates').split(/[;|]/).map((d) => d.trim()).filter(Boolean);
    if (dates.some((d) => !/^\d{4}-\d{2}-\d{2}$/.test(d))) problems.push('dates must be YYYY-MM-DD');
    const row: Record<string, unknown> = { artist_name: get('artist_name') };
    if (!row.artist_name) problems.push('no artist');
    if (get('title')) row.title = get('title');
    if (dates.length) row.dates = dates;
    if (Object.keys(terms).length) row.terms = terms;
    if (get('act_type')) row.act_type = get('act_type').toLowerCase().replace(/[\s-]+/g, '_');
    if (get('agent_name') || get('agent_email') || get('agent_company')) {
      row.agent = { name: get('agent_name') || null, email: get('agent_email') || null, company: get('agent_company') || null };
    }
    const budget: Record<string, unknown> = {};
    if (get('capacity')) {
      const c = Number(get('capacity').replace(/,/g, ''));
      if (!Number.isInteger(c) || c < 0) problems.push('capacity must be a whole number'); else budget.capacity = c;
    }
    const avg = money('average_price', 'average price'); if (avg !== undefined) budget.average_price_cents = avg;
    const st = pct('sell_through', 'sell-through'); if (st !== undefined) budget.sell_through_percent = st;
    if (Object.keys(budget).length) row.budget = budget;
    if (get('group')) row.group = get('group');
    if (get('notes')) row.notes = get('notes');
    if (problems.length) errors.push({ row: n, error: problems.join('; ') });
    else rows.push(row);
  });
  return { rows, errors, ignored };
}
