// Chargebacks on the organizer money screens (event Money, org Payouts):
// row shape and display helpers (pure; the read is ./disputesApi.ts).
// exos_disputes (mig 20261001101000) is written by stripe-webhook only.

export interface DisputeRow {
  id: string;
  event_id: string | null;
  session_id: string | null;
  dispute_id: string;
  amount_cents: number | null;
  fee_cents: number | null;
  currency: string;
  reason: string | null;
  status: string;
  evidence_due_by: string | null;
  evidence_submitted: boolean;
  livemode: boolean | null;
  created_at: string;
  closed_at: string | null;
  recovery_status: string;
  recovery_candidate_cents: number | null;
  event?: { name: string | null } | null;
}

export const DISPUTE_COLS =
  'id, event_id, session_id, dispute_id, amount_cents, fee_cents, currency, reason, status, evidence_due_by, ' +
  'evidence_submitted, livemode, created_at, closed_at, recovery_status, recovery_candidate_cents';

const CLOSED = new Set(['won', 'lost', 'warning_closed']);

export function isOpenDispute(status: string): boolean {
  return !CLOSED.has(status);
}

export function disputeStatusLabel(status: string): string {
  switch (status) {
    case 'warning_needs_response': return 'Inquiry: needs response';
    case 'warning_under_review': return 'Inquiry: under review';
    case 'warning_closed': return 'Inquiry closed';
    case 'needs_response': return 'Needs response';
    case 'under_review': return 'Under review';
    case 'won': return 'Won';
    case 'lost': return 'Lost';
    default: return status.replace(/_/g, ' ');
  }
}

export function disputeReasonLabel(reason: string | null): string {
  if (!reason) return '—';
  const r = reason.replace(/_/g, ' ');
  return r.charAt(0).toUpperCase() + r.slice(1);
}

/** "Due Oct 15 (in 5 days)", "Overdue since Oct 15", or '' once closed / submitted / no deadline. */
export function disputeDueLabel(d: Pick<DisputeRow, 'status' | 'evidence_due_by' | 'evidence_submitted'>, now = new Date()): string {
  if (!d.evidence_due_by || !isOpenDispute(d.status) || d.evidence_submitted) return '';
  const due = new Date(d.evidence_due_by);
  if (Number.isNaN(due.getTime())) return '';
  const day = due.toLocaleDateString('en-US', { month: 'short', day: 'numeric', timeZone: 'UTC' });
  const ms = due.getTime() - now.getTime();
  if (ms < 0) return `Overdue since ${day}`;
  const days = Math.floor(ms / 86_400_000);
  return `Due ${day} (${days === 0 ? 'today' : `in ${days} day${days === 1 ? '' : 's'}`})`;
}

/** Stripe's dashboard page for the dispute (the Exos platform account's). */
export function stripeDisputeLink(d: Pick<DisputeRow, 'dispute_id' | 'livemode'>): string | null {
  if (!/^(dp|du)_[A-Za-z0-9]{1,200}$/.test(d.dispute_id)) return null;
  return `https://dashboard.stripe.com/${d.livemode === false ? 'test/' : ''}disputes/${d.dispute_id}`;
}

export interface DisputeSummary {
  open: number;
  openCents: number;
  lost: number;
  lostCents: number;
  feesCents: number;
  won: number;
}

export function summarizeDisputes(rows: DisputeRow[]): DisputeSummary {
  const s: DisputeSummary = { open: 0, openCents: 0, lost: 0, lostCents: 0, feesCents: 0, won: 0 };
  for (const d of rows) {
    const amt = d.amount_cents ?? 0;
    if (isOpenDispute(d.status)) { s.open++; s.openCents += amt; }
    if (d.status === 'lost') { s.lost++; s.lostCents += amt; }
    if (d.status === 'won') s.won++;
    s.feesCents += d.fee_cents ?? 0;
  }
  return s;
}
