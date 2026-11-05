// The offer and settlement documents as PDFs (docs/offers-settlements.md).
// Pure: the dashboard downloads them, the agent's and the settlement
// contacts' pages offer them, and exos-api serves them, from the same code.

import { createPdf } from './pdf.ts';
import { describeDeal, formatCents, settle, type SettlementInputs, type TermsJson } from './settlementModel.ts';

/** The offer fields a document needs (the agent's view has exactly these). */
export interface OfferDoc {
  title: string;
  status: string;
  org: { name: string } | null;
  artist_name: string;
  act_type?: string;
  dates: string[];
  currency: string;
  venue: { name: string; room?: string | null } | null;
  terms: TermsJson;
  budget?: { capacity: number; average_price_cents: number } | null;
  agent_name?: string | null;
  boilerplate?: string;
  expires_at?: string | null;
  sent_at?: string | null;
  response?: { action: string; name?: string | null; at?: string | null } | null;
}

const day = (d: string) => {
  const t = Date.parse(`${d}T12:00:00Z`);
  return Number.isFinite(t)
    ? new Date(t).toLocaleDateString('en-US', { weekday: 'short', month: 'long', day: 'numeric', year: 'numeric', timeZone: 'UTC' })
    : d;
};
const when = (iso?: string | null) => {
  if (!iso) return '';
  const t = Date.parse(iso);
  return Number.isFinite(t) ? new Date(t).toLocaleString('en-US', { dateStyle: 'medium', timeStyle: 'short', timeZone: 'UTC' }) + ' UTC' : '';
};

export function offerPdf(o: OfferDoc): Uint8Array {
  const pdf = createPdf({ title: `Offer: ${o.artist_name}`, author: o.org?.name });
  const cur = o.currency || 'USD';
  const t = o.terms ?? {};
  pdf.heading(o.title || 'Offer');
  pdf.paragraph(`${o.org?.name ?? ''}${o.org?.name ? ' · ' : ''}Offer to ${o.artist_name}${o.agent_name ? `, care of ${o.agent_name}` : ''}`, { gray: 0.35 });
  pdf.subheading('Show');
  pdf.row([['Dates'], [o.dates.length ? o.dates.map(day).join('; ') : 'To be confirmed']], [0.3, 0.7]);
  if (o.venue) pdf.row([['Venue'], [`${o.venue.name}${o.venue.room ? ` — ${o.venue.room}` : ''}`]], [0.3, 0.7]);
  if (o.act_type) pdf.row([['Billing'], [o.act_type.replace('_', '-')]], [0.3, 0.7]);
  if (o.budget && o.budget.capacity > 0) {
    pdf.row([['Capacity'], [String(o.budget.capacity)]], [0.3, 0.7]);
    if (o.budget.average_price_cents > 0) pdf.row([['Average ticket price'], [formatCents(o.budget.average_price_cents, cur)]], [0.3, 0.7]);
  }
  pdf.subheading('Terms');
  pdf.row([['Deal'], [describeDeal(t, cur)]], [0.3, 0.7]);
  if (t.expenses_cap_cents !== null && t.expenses_cap_cents !== undefined) {
    pdf.row([['Expenses cap'], [formatCents(t.expenses_cap_cents, cur)]], [0.3, 0.7]);
  }
  if (t.deal_type === 'plus' && t.promoter_profit_percent) {
    pdf.row([['Promoter profit'], [`${t.promoter_profit_percent}% of guarantee and expenses`]], [0.3, 0.7]);
  }
  for (const b of t.bonuses ?? []) pdf.row([['Bonus'], [`${formatCents(b.amount_cents, cur)} at ${b.sold} tickets sold`]], [0.3, 0.7]);
  if (t.merch_artist_percent !== null && t.merch_artist_percent !== undefined) {
    pdf.row([['Merchandise'], [`${t.merch_artist_percent}% of merch income to the artist`]], [0.3, 0.7]);
  }
  if (t.deposit_cents) {
    pdf.row([['Deposit'], [`${formatCents(t.deposit_cents, cur)}${t.deposit_due_on ? `, due ${day(t.deposit_due_on)}` : ''}`]], [0.3, 0.7]);
  }
  if (t.hospitality) pdf.row([['Hospitality'], [t.hospitality]], [0.3, 0.7]);
  if (t.rider) pdf.row([['Rider'], [t.rider]], [0.3, 0.7]);
  if (o.boilerplate) {
    pdf.subheading('Conditions');
    pdf.paragraph(o.boilerplate);
  }
  pdf.space(8);
  if (o.response) {
    pdf.paragraph(`${o.response.action === 'accept' ? 'Accepted' : 'Declined'}${o.response.name ? ` by ${o.response.name}` : ''}${o.response.at ? ` on ${when(o.response.at)}` : ''}.`, { bold: true });
  } else if (o.expires_at) {
    pdf.paragraph(`This offer expires ${when(o.expires_at)}.`, { gray: 0.35 });
  }
  return pdf.toBytes();
}

/**
 * The settlement document. includePromoterNet false is the version the
 * show's settlement contacts get (artist and venue lines, no house result).
 */
export function settlementPdf(inp: SettlementInputs, opts: { orgName?: string; includePromoterNet: boolean; finalizedAt?: string | null }): Uint8Array {
  const v = settle(inp);
  const r = v.result;
  const cur = v.currency;
  const m = (c: number) => formatCents(c, cur);
  const pdf = createPdf({ title: `Settlement: ${inp.event.name}`, author: opts.orgName });
  pdf.heading(`Settlement — ${inp.event.name}`);
  pdf.paragraph([opts.orgName, inp.event.starts_at ? when(inp.event.starts_at) : null, inp.event.venue?.name ?? inp.event.venue_name]
    .filter(Boolean).join(' · '), { gray: 0.35 });
  pdf.paragraph(opts.finalizedAt ? `Finalized ${when(opts.finalizedAt)}` : 'Draft — live numbers, not final', { size: 9, gray: 0.35 });

  pdf.subheading('Box office');
  pdf.table(['Ticket type', 'Sold', 'Comps', 'Gross'],
    v.boxOffice.byTier.map((t) => [t.tierName, String(t.sold), String(t.comps), m(t.gross)]), [0.46, 0.14, 0.14, 0.26], [1, 2, 3]);
  for (const e of v.boxOffice.elsewhere) {
    pdf.row([[`Sold elsewhere (${e.currency})${e.included ? '' : ' — not counted'}`], [String(e.sold), { align: 'right' }], [''], [formatCents(e.gross, e.currency), { align: 'right' }]],
      [0.46, 0.14, 0.14, 0.26], { rule: true });
  }
  const dl = v.boxOffice.deductionLines;
  pdf.row([['Gross box office', { bold: true }], [m(r.grossBoxOffice), { align: 'right', bold: true }]], [0.74, 0.26]);
  if (dl.tax) pdf.row([['Tax'], [m(-dl.tax), { align: 'right' }]], [0.74, 0.26]);
  if (dl.passedOnFees) pdf.row([['Fees paid by buyers'], [m(-dl.passedOnFees), { align: 'right' }]], [0.74, 0.26]);
  if (dl.absorbedFees) pdf.row([['Fees absorbed'], [m(-dl.absorbedFees), { align: 'right' }]], [0.74, 0.26]);
  if (dl.platformFees) pdf.row([['Ticketing and card fees'], [m(-dl.platformFees), { align: 'right' }]], [0.74, 0.26]);
  pdf.row([['Net box office', { bold: true }], [m(r.netBoxOffice), { align: 'right', bold: true }]], [0.74, 0.26], { rule: true });
  pdf.paragraph(`${v.boxOffice.paidSold} paid tickets, ${v.boxOffice.comps} comps.`, { size: 9, gray: 0.35 });

  const expenses = (inp.items ?? []).filter((i) => i.kind === 'expense');
  if (expenses.length) {
    pdf.subheading('Expenses');
    pdf.table(['Item', 'Category', 'Amount'],
      expenses.map((i) => [i.label, i.category_name ?? '', m(i.actual_cents ?? i.amount_cents)]), [0.5, 0.24, 0.26], [2]);
    pdf.row([['Total expenses', { bold: true }], [m(r.expensesTotal), { align: 'right', bold: true }]], [0.74, 0.26]);
  }

  pdf.subheading('Artists');
  if (!r.slots.length) pdf.paragraph('No accepted offers on this show.', { gray: 0.35 });
  for (const s of r.slots) {
    pdf.paragraph(s.name, { bold: true });
    const lines: [string, number][] = [];
    if (s.poolId) lines.push([`Pool share (${s.poolSharePercent ?? 0}%)`, s.base]);
    else {
      if (s.guarantee) lines.push(['Guarantee', s.guarantee]);
      if (s.dealType !== 'flat') lines.push([`${s.percentage}% ${s.dealType === 'plus' ? 'above the split point' : s.dealType === 'door' ? 'of net box office' : 'of net after expenses'}`, s.percentageAmount]);
      if (s.dealType !== 'flat' && s.dealType !== 'door') lines.push([`Expenses applied${s.capped ? ' (capped)' : ''}`, s.expensesApplied]);
      lines.push(['Deal pays', s.base]);
    }
    if (s.bonus) lines.push(['Bonuses', s.bonus]);
    if (s.merch) lines.push(['Merchandise', s.merch]);
    if (s.adjustments) lines.push(['Adjustments', s.adjustments]);
    lines.push(['Payout', s.payout]);
    if (s.depositPaid) lines.push(['Deposit paid', -s.depositPaid]);
    lines.push(['Balance due', s.balanceDue]);
    for (const [label, amount] of lines) {
      const strong = label === 'Payout' || label === 'Balance due';
      pdf.row([[label, { bold: strong }], [m(amount), { align: 'right', bold: strong }]], [0.74, 0.26]);
    }
    pdf.space(4);
  }

  if (r.venue) {
    pdf.subheading('Venue');
    pdf.row([['Rental'], [m(r.venue.rentalFee), { align: 'right' }]], [0.74, 0.26]);
    if (r.venue.sharePercent) pdf.row([[`${r.venue.sharePercent}% of net box office`], [m(r.venue.share), { align: 'right' }]], [0.74, 0.26]);
    pdf.row([['Owed to the venue', { bold: true }], [m(r.venue.total), { align: 'right', bold: true }]], [0.74, 0.26]);
    if (r.venue.depositPaid) pdf.row([['Rental deposit paid'], [m(-r.venue.depositPaid), { align: 'right' }]], [0.74, 0.26]);
    pdf.row([['Balance due to the venue', { bold: true }], [m(r.venue.balanceDue), { align: 'right', bold: true }]], [0.74, 0.26]);
  }

  if (opts.includePromoterNet) {
    pdf.subheading('Result');
    if (r.otherIncome) pdf.row([['Other income'], [m(r.otherIncome), { align: 'right' }]], [0.74, 0.26]);
    if (r.merchIncome) pdf.row([['Merch income'], [m(r.merchIncome), { align: 'right' }]], [0.74, 0.26]);
    for (const a of v.houseAdjustments) pdf.row([[`${a.label} (${a.reason})`], [m(a.amount_cents), { align: 'right' }]], [0.74, 0.26]);
    pdf.row([['Promoter net', { bold: true }], [m(r.promoterNet), { align: 'right', bold: true }]], [0.74, 0.26], { rule: true });
  }
  return pdf.toBytes();
}
