// Commission methods: how a promoter's commission is funded (mig
// 20261104190000, docs/payouts.md "Commission methods", docs/organizer-guide.md).
// PURE: no Supabase import, so it unit-tests without a client; the RPC
// wrappers are in ./commissionMethodsApi.ts. The money maths the server uses
// lives in supabase/functions/_shared/payouts/commissionMethods.ts (pinned by
// commissionMethods.test.ts against the SQL).

export type CommissionMethod = 'clawback' | 'split_at_sale' | 'platform_fee' | 'manual';

export const METHODS: readonly CommissionMethod[] = ['manual', 'clawback', 'platform_fee', 'split_at_sale'];

export interface MethodInfo {
  label: string;
  /** One line for the picker. */
  short: string;
  /** What happens, in plain words. */
  how: string;
  /** What has to be true before it works. */
  needs: string[];
  /** Who pays a promoter's commission on a refunded sale, until netted. */
  paidBy: 'you' | 'Exos';
}

export const METHOD_INFO: Record<CommissionMethod, MethodInfo> = {
  manual: {
    label: 'Manual',
    short: 'You pay promoters yourself (Venmo, cash) and record it here.',
    how: 'Exos keeps the ledger: who sold what and what you owe. Nothing moves through Exos.',
    needs: [],
    paidBy: 'you',
  },
  clawback: {
    label: 'From your payouts',
    short: 'Exos takes the commission back from what Stripe paid you for those orders and sends it to the promoter.',
    how: 'Buyers pay you as usual. When you pay a promoter here, Exos reverses that much of your Stripe transfers for those orders and transfers it to their Stripe account.',
    needs: ['Stripe payouts to promoters turned on (owner)', 'The promoter has a Stripe payout account'],
    paidBy: 'you',
  },
  platform_fee: {
    label: 'Inside the Exos fee',
    short: 'The commission is added to the Exos fee on each order; Exos pays the promoter after the event.',
    how: 'Your Stripe dashboard shows a bigger application fee on these orders: it includes the promoter\'s commission, which Exos holds and transfers to them after the holdback. Refunds give the fee back in proportion.',
    needs: ['Turned on for Exos (platform switch)', 'The promoter has a Stripe payout account', 'Commission at most 30% of your net per ticket (more needs Exos approval)'],
    paidBy: 'Exos',
  },
  split_at_sale: {
    label: 'Split at sale',
    short: 'The buyer\'s payment lands with Exos; after the event Exos pays your share and each promoter\'s commission from it.',
    how: 'Each order is charged on the Exos account (separate charges and transfers). After the holdback Exos transfers your share and the promoter\'s commission from that order\'s charge. Exos handles disputes on these charges. A refund after your share was paid takes your part back from that payout first, and is refused if it can\'t.',
    needs: ['Turned on by the org owner and for Exos (platform switch)', 'Your Stripe account is an Express account', 'The promoter has a Stripe payout account', 'Commission at most 30% of your net per ticket (more needs Exos approval)'],
    paidBy: 'Exos',
  },
};

export const methodLabel = (m: string | null | undefined): string =>
  m && m in METHOD_INFO ? METHOD_INFO[m as CommissionMethod].label : 'Org default';

/** Most specific wins: promoter, then event (locked, else override), then org, then manual. Mirrors _exos_commission_resolve. */
export function resolveMethod(o: {
  promoter?: CommissionMethod | null; eventLocked?: CommissionMethod | null; event?: CommissionMethod | null; org?: CommissionMethod | null;
}): { method: CommissionMethod; source: 'promoter' | 'event_locked' | 'event' | 'org' | 'default' } {
  if (o.promoter) return { method: o.promoter, source: 'promoter' };
  if (o.eventLocked) return { method: o.eventLocked, source: 'event_locked' };
  if (o.event) return { method: o.event, source: 'event' };
  if (o.org) return { method: o.org, source: 'org' };
  return { method: 'manual', source: 'default' };
}

/** Changing a sold event's method needs the "future sales only" confirmation. */
export function needsFutureOnlyConfirm(ev: { sold: boolean; effective: CommissionMethod }, next: CommissionMethod): boolean {
  return ev.sold && ev.effective !== next;
}

/** "0".."30" → days; anything else → null. */
export function parseHoldbackDays(input: string): number | null {
  const s = input.trim();
  if (!/^\d{1,2}$/.test(s)) return null;
  const n = Number(s);
  return n >= 0 && n <= 30 ? n : null;
}

export const holdbackText = (days: number): string =>
  days === 0 ? 'Payable as soon as the event ends.' : `Payable ${days} day${days === 1 ? '' : 's'} after the event ends (the refund window).`;

export interface PromoterBalance {
  promoterId: string; name: string; code: string; currency: string; accountReady: boolean;
  heldCents: number; heldUntil: string | null; payableByYouCents: number; payableByExosCents: number;
  processingCents: number; paidCents: number; nettingOwedToYouCents: number; nettingOwedToExosCents: number;
  nettingSince: string | null; nettingOverdue: boolean; balanceCents: number;
}

const n = (v: unknown) => (typeof v === 'number' && Number.isFinite(v) ? Math.trunc(v) : Number(v) || 0);

export function normalizeBalances(raw: unknown): { promoters: PromoterBalance[]; organizer: { currency: string; owedToExosCents: number; since: string | null; overdue: boolean; overCap: boolean }[]; alertDays: number } {
  const r = (raw ?? {}) as Record<string, any>;
  return {
    alertDays: n(r.netting_alert_days) || 30,
    promoters: (Array.isArray(r.promoters) ? r.promoters : []).map((p: any) => ({
      promoterId: String(p.promoter_id), name: String(p.name ?? ''), code: String(p.code ?? ''), currency: String(p.currency ?? 'usd'),
      accountReady: !!p.account_ready, heldCents: n(p.held_cents), heldUntil: p.held_until ?? null,
      payableByYouCents: n(p.payable_by_you_cents), payableByExosCents: n(p.payable_by_exos_cents),
      processingCents: n(p.processing_cents), paidCents: n(p.paid_cents),
      nettingOwedToYouCents: n(p.netting_owed_to_you_cents), nettingOwedToExosCents: n(p.netting_owed_to_exos_cents),
      nettingSince: p.netting_since ?? null, nettingOverdue: !!p.netting_overdue, balanceCents: n(p.balance_cents),
    })),
    organizer: (Array.isArray(r.organizer) ? r.organizer : []).map((o: any) => ({
      currency: String(o.currency ?? 'usd'), owedToExosCents: n(o.owed_to_exos_cents), since: o.since ?? null, overdue: !!o.overdue, overCap: !!o.over_cap,
    })),
  };
}

/** One line about a promoter's netting, or null when nothing is owed back. */
export function nettingLine(b: Pick<PromoterBalance, 'nettingOwedToYouCents' | 'nettingOwedToExosCents' | 'nettingOverdue'>, money: (c: number) => string): string | null {
  const parts: string[] = [];
  if (b.nettingOwedToYouCents > 0) parts.push(`${money(b.nettingOwedToYouCents)} owed back to you`);
  if (b.nettingOwedToExosCents > 0) parts.push(`${money(b.nettingOwedToExosCents)} owed back to Exos`);
  if (parts.length === 0) return null;
  return `${parts.join(' and ')} for sales refunded after payout${b.nettingOverdue ? ' (overdue: no new commission to take it from)' : ', taken off their next commission'}.`;
}

export const transferStatusLabel = (s: string): string =>
  ({ planned: 'Queued', sending: 'Sending', sent: 'Sent', dry_run: 'Test run (switch off)', failed: 'Failed', cancelled: 'Cancelled', netted: 'Netted' } as Record<string, string>)[s] ?? s;

export const transferKindLabel = (k: string): string =>
  ({ split_org: 'Your share', split_promoter: 'Promoter (split)', fee_promoter: 'Promoter (Exos fee)' } as Record<string, string>)[k] ?? k;
