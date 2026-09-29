// Buyer + organizer side of "refunds when the date changes" (mig 20260929150000).
//
// The rules are shared with exos-refund (supabase/functions/_shared/reschedule-refund.ts)
// and enforced in SQL. Money moves only through the exos-refund edge function
// (Stripe); releasing a free ticket is a plain RPC when signed in, or goes
// through the edge function with the mail link's token when signed out.

import { supabase } from './supabase';

export {
  qualifiesAsDateChange,
  defaultRefundDeadline,
  deadlineProblem,
  rescheduleEligibility,
  rescheduleRefundAmount,
  reasonText,
  RESCHEDULE_TOKEN_RE,
  type RescheduleKind,
  type RescheduleReason,
} from '../../supabase/functions/_shared/reschedule-refund.ts';

export interface RescheduleOffer {
  ticketId: string;
  eventId: string;
  eventName: string;
  timezone: string | null;
  tierName: string | null;
  kind: 'refund' | 'release' | 'marketplace' | 'none';
  ok: boolean;
  reason: string | null;
  amountCents: number;
  currency: string;
  refundDeadline: Date | null;
  oldStartsAt: Date | null;
  newStartsAt: Date | null;
  requestStatus: string | null;
  /** The viewer holds it (false: they paid for it, someone else has it). */
  mine: boolean;
}

const d = (v: unknown): Date | null => (v ? new Date(String(v)) : null);

/** Tickets the signed-in account holds or paid for, on events offering refunds after a date change. */
export async function listMyRescheduleOffers(): Promise<RescheduleOffer[]> {
  const { data, error } = await supabase.rpc('exos_my_reschedule_offers');
  if (error) {
    // Before the migration is applied the RPC doesn't exist: show nothing.
    console.warn('reschedule offers unavailable (non-fatal):', error.message);
    return [];
  }
  return ((data as any[]) ?? []).map((r) => ({
    ticketId: r.ticket_id,
    eventId: r.event_id,
    eventName: r.event_name ?? 'Event',
    timezone: r.timezone ?? null,
    tierName: r.tier_name ?? null,
    kind: r.kind,
    ok: !!r.ok,
    reason: r.reason ?? null,
    amountCents: Number(r.amount_cents) || 0,
    currency: r.currency || 'usd',
    refundDeadline: d(r.refund_deadline),
    oldStartsAt: d(r.old_starts_at),
    newStartsAt: d(r.new_starts_at),
    requestStatus: r.request_status ?? null,
    mine: !!r.mine,
  }));
}

export interface RescheduleResult {
  ticketId: string;
  ok: boolean;
  reason?: string;
  status?: string;
  amountCents?: number;
  existing?: boolean;
  error?: string;
}

async function invokeRefundFn(body: Record<string, unknown>): Promise<any> {
  const { data, error } = await supabase.functions.invoke('exos-refund', { body });
  if (error) {
    let payload: any = null;
    try {
      payload = await (error as { context?: Response }).context?.json();
    } catch {
      payload = null;
    }
    throw new Error(payload?.error || error.message || 'That didn’t work. Try again.');
  }
  return data;
}

function mapResults(data: any): RescheduleResult[] {
  return ((data?.results as any[]) ?? []).map((r) => ({
    ticketId: r.ticket_id,
    ok: !!r.ok,
    reason: r.reason,
    status: r.status,
    amountCents: r.amount_cents != null ? Number(r.amount_cents) : undefined,
    existing: r.existing,
    error: r.error,
  }));
}

/** Ask for refunds (signed in: ticket ids; signed out: the mail link's token). */
export async function requestRescheduleRefund(input: { ticketIds?: string[]; token?: string }): Promise<RescheduleResult[]> {
  return mapResults(await invokeRefundFn({
    action: 'reschedule_refund',
    ...(input.ticketIds?.length ? { ticket_ids: input.ticketIds } : {}),
    ...(input.token ? { token: input.token } : {}),
  }));
}

/** Give back free / comp tickets (void, no money). */
export async function releaseForReschedule(input: { ticketIds?: string[]; token?: string }): Promise<RescheduleResult[]> {
  if (input.token) {
    return mapResults(await invokeRefundFn({ action: 'reschedule_release', token: input.token }));
  }
  const { data, error } = await supabase.rpc('exos_reschedule_release_mine', { p_ticket_ids: input.ticketIds ?? [] });
  if (error) throw error;
  return mapResults(data);
}

export interface RescheduleLinkInfo {
  kind: 'refund' | 'release';
  ok: boolean;
  reason: string | null;
  requestStatus: string | null;
  tierName: string | null;
  amountCents: number;
  currency: string;
  refundDeadline: Date | null;
  oldStartsAt: Date | null;
  newStartsAt: Date | null;
  event: { id: string; name: string; timezone: string | null; venueName: string | null } | null;
}

/** What a mail link is for (works signed out). */
export async function getRescheduleLinkInfo(token: string): Promise<RescheduleLinkInfo> {
  const r = await invokeRefundFn({ action: 'reschedule_info', token });
  return {
    kind: r.kind,
    ok: !!r.ok,
    reason: r.reason ?? null,
    requestStatus: r.request_status ?? null,
    tierName: r.tier_name ?? null,
    amountCents: Number(r.amount_cents) || 0,
    currency: r.currency || 'usd',
    refundDeadline: d(r.refund_deadline),
    oldStartsAt: d(r.old_starts_at),
    newStartsAt: d(r.new_starts_at),
    event: r.event
      ? { id: r.event.id, name: r.event.name ?? 'Event', timezone: r.event.timezone ?? null, venueName: r.event.venue_name ?? null }
      : null,
  };
}

export interface RescheduleSummaryRow {
  id: string;
  oldStartsAt: Date | null;
  newStartsAt: Date;
  reason: string | null;
  refundsOffered: boolean;
  refundDeadline: Date | null;
  qualifying: boolean;
  recipientCount: number;
  createdAt: Date;
}

export interface RescheduleSummary {
  latest: {
    rescheduleId: string;
    refundsOffered: boolean;
    refundDeadline: Date | null;
    open: boolean;
    refundsRequested: number;
    refundsSucceeded: number;
    refundedCents: number;
    inFlightCents: number;
    released: number;
    remainingEligible: number;
    currency: string;
  } | null;
  reschedules: RescheduleSummaryRow[];
}

/** Organizer (owner / manager / finance): history + what buyers did with the latest offer. */
export async function getRescheduleSummary(eventId: string): Promise<RescheduleSummary | null> {
  const { data, error } = await supabase.rpc('exos_event_reschedule_summary', { p_event_id: eventId });
  if (error) {
    console.warn('reschedule summary unavailable (non-fatal):', error.message);
    return null;
  }
  const s = data as any;
  const l = s?.latest;
  return {
    latest: l
      ? {
          rescheduleId: l.reschedule_id,
          refundsOffered: !!l.refunds_offered,
          refundDeadline: d(l.refund_deadline),
          open: !!l.open,
          refundsRequested: Number(l.refunds_requested) || 0,
          refundsSucceeded: Number(l.refunds_succeeded) || 0,
          refundedCents: Number(l.refunded_cents) || 0,
          inFlightCents: Number(l.in_flight_cents) || 0,
          released: Number(l.released) || 0,
          remainingEligible: Number(l.remaining_eligible) || 0,
          currency: l.currency || 'usd',
        }
      : null,
    reschedules: ((s?.reschedules as any[]) ?? []).map((r) => ({
      id: r.id,
      oldStartsAt: d(r.old_starts_at),
      newStartsAt: new Date(r.new_starts_at),
      reason: r.reason ?? null,
      refundsOffered: !!r.refunds_offered,
      refundDeadline: d(r.refund_deadline),
      qualifying: !!r.qualifying,
      recipientCount: Number(r.recipient_count) || 0,
      createdAt: new Date(r.created_at),
    })),
  };
}
