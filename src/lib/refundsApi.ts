// Organizer refunds: calls to the exos-refund edge function and the read RPCs
// from mig 20260926040000 (exos_event_refund_orders, exos_refund_preview).
// Pure math and types live in refunds.ts.

import { supabase } from './supabase';
import type { RefundOrder, RefundPreview, TicketSelection } from './refunds';

// Server calls

export async function listRefundOrders(eventId: string): Promise<RefundOrder[]> {
  const { data, error } = await supabase.rpc('exos_event_refund_orders', { p_event_id: eventId });
  if (error) throw error;
  return ((data as any[]) ?? []).map((r) => ({
    sessionId: r.session_id,
    buyerEmail: r.buyer_email ?? null,
    createdAt: r.created_at ? new Date(r.created_at) : new Date(0),
    status: r.status,
    amountCents: Number(r.amount_cents) || 0,
    refundedCents: Number(r.refunded_cents) || 0,
    refundableCents: Number(r.refundable_cents) || 0,
    tickets: Number(r.tickets) || 0,
    activeTickets: Number(r.active_tickets) || 0,
    openRequests: Number(r.open_requests) || 0,
    currency: (r.currency || 'usd').toUpperCase(),
  }));
}

export async function getRefundPreview(sessionId: string): Promise<RefundPreview> {
  const { data, error } = await supabase.rpc('exos_refund_preview', { p_session_id: sessionId });
  if (error) throw error;
  const p = (data ?? {}) as any;
  return {
    sessionId: p.session_id,
    status: p.status,
    currency: (p.currency || 'usd').toUpperCase(),
    amountCents: Number(p.amount_cents) || 0,
    refundedCents: Number(p.refunded_cents) || 0,
    refundableCents: Number(p.refundable_cents) || 0,
    hasPayment: !!p.has_payment,
    tickets: ((p.tickets as any[]) ?? []).map((t) => ({
      ticketId: t.ticket_id,
      status: t.status,
      shareCents: Number(t.share_cents) || 0,
      refundedCents: Number(t.refunded_cents) || 0,
      refundableCents: Number(t.refundable_cents) || 0,
      tierName: t.tier_name ?? null,
      attendeeName: t.attendee_name ?? null,
    })),
    requests: ((p.requests as any[]) ?? []).map((r) => ({
      id: r.id,
      amountCents: Number(r.amount_cents) || 0,
      status: r.status,
      scope: r.scope,
      reason: r.reason ?? null,
      createdAt: r.created_at ? new Date(r.created_at) : new Date(0),
      error: r.error ?? null,
    })),
  };
}

export interface RefundOutcome {
  sessionId: string;
  requestId?: string;
  status: string;
  amountCents?: number;
  voided?: number;
  error?: string;
}

// The edge function answers 402 (Stripe refused) / 409 (over the limit) /
// 502 (Stripe didn't answer) with a JSON body; surface its message.
async function invokeRefund(body: Record<string, unknown>): Promise<any> {
  const { data, error } = await supabase.functions.invoke('exos-refund', { body });
  if (error) {
    let payload: any = null;
    try {
      payload = await (error as { context?: Response }).context?.json();
    } catch {
      payload = null;
    }
    if (payload && payload.request_id) return payload; // an outcome (failed / claimed)
    throw new Error(payload?.error || error.message || 'Refund failed.');
  }
  return data;
}

function mapOutcome(o: any): RefundOutcome {
  return {
    sessionId: o.session_id,
    requestId: o.request_id,
    status: o.status,
    amountCents: o.amount_cents != null ? Number(o.amount_cents) : undefined,
    voided: o.voided != null ? Number(o.voided) : undefined,
    error: o.error,
  };
}

export async function refundOrder(input: {
  sessionId: string;
  nonce: string;
  reason?: string;
  items?: TicketSelection[];
  amountCents?: number;
  wholeOrder?: boolean;
}): Promise<RefundOutcome> {
  const out = await invokeRefund({
    action: 'refund',
    session_id: input.sessionId,
    nonce: input.nonce,
    reason: input.reason || undefined,
    items: input.items?.map((i) => ({ ticket_id: i.ticketId, amount_cents: i.amountCents ?? null })),
    amount_cents: input.amountCents,
    whole_order: input.wholeOrder === true ? true : undefined,
  });
  return mapOutcome(out);
}

export async function retryRefund(requestId: string): Promise<RefundOutcome> {
  return mapOutcome(await invokeRefund({ action: 'retry', request_id: requestId }));
}

/** One batch of the "refund everyone" run; call again with nextAfter until done. */
export async function refundEventBatch(input: {
  eventId: string;
  nonce: string;
  reason?: string;
  after?: string | null;
}): Promise<{ results: RefundOutcome[]; nextAfter: string | null; done: boolean }> {
  const out = await invokeRefund({
    action: 'cancel_event',
    event_id: input.eventId,
    nonce: input.nonce,
    reason: input.reason || undefined,
    after: input.after ?? undefined,
  });
  return {
    results: ((out?.results as any[]) ?? []).map(mapOutcome),
    nextAfter: out?.next_after ?? null,
    done: out?.done !== false,
  };
}
