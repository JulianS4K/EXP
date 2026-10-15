// Buyer refund requests (mig 20261015090000): the buyer asks, the organizer
// refunds (the usual exos-refund call, nonce 'ask:<id>') or declines. The
// rules live in SQL (_exos_refund_ask_state); this is the wording and the RPCs.

import { supabase } from './supabase';
import { refundOrder, type RefundOutcome } from './refundsApi';

export type AskStatus = 'open' | 'refunded' | 'declined' | 'withdrawn';

export interface MyRefundAsk {
  ticketId: string;
  canAsk: boolean;
  reason: string | null;
  amountCents: number;
  currency: string;
  askUntil: Date | null;
  refundPolicy: string | null;
  askId: string | null;
  askStatus: AskStatus | null;
  declineNote: string | null;
}

export interface EventRefundAsk {
  askId: string;
  ticketId: string;
  tierName: string;
  sessionId: string;
  buyerEmail: string;
  reason: string | null;
  amountCents: number;
  currency: string;
  status: AskStatus;
  declineNote: string | null;
  createdAt: Date;
  ticketStatus: string;
  checkedIn: boolean;
}

const date = (v: unknown): Date | null => {
  if (!v) return null;
  const d = new Date(String(v));
  return Number.isNaN(d.getTime()) ? null : d;
};
const status = (v: unknown): AskStatus | null =>
  v === 'open' || v === 'refunded' || v === 'declined' || v === 'withdrawn' ? v : null;

export function parseMyAsk(r: any): MyRefundAsk {
  return {
    ticketId: String(r.ticket_id),
    canAsk: r.can_ask === true,
    reason: r.reason ?? null,
    amountCents: Math.max(0, Number(r.amount_cents) || 0),
    currency: String(r.currency || 'usd'),
    askUntil: date(r.ask_until),
    refundPolicy: r.refund_policy ?? null,
    askId: r.ask_id ?? null,
    askStatus: status(r.ask_status),
    declineNote: r.decline_note ?? null,
  };
}

export function parseEventAsk(r: any): EventRefundAsk {
  return {
    askId: String(r.ask_id),
    ticketId: String(r.ticket_id),
    tierName: String(r.tier_name ?? ''),
    sessionId: String(r.session_id ?? ''),
    buyerEmail: String(r.buyer_email ?? ''),
    reason: r.reason ?? null,
    amountCents: Math.max(0, Number(r.amount_cents) || 0),
    currency: String(r.currency || 'usd'),
    status: status(r.status) ?? 'open',
    declineNote: r.decline_note ?? null,
    createdAt: date(r.created_at) ?? new Date(0),
    ticketStatus: String(r.ticket_status ?? ''),
    checkedIn: r.checked_in === true,
  };
}

/** Why the buyer can't ask, in their words (null: they can, or there's nothing to say). */
export function cantAskText(reason: string | null, askUntil?: Date | null): string | null {
  switch (reason) {
    case null:
    case undefined:
    case 'asked':
      return null;
    case 'no-refunds':
      return 'The organizer has said all sales are final for this event.';
    case 'too-late':
      return askUntil
        ? `Refund requests closed ${askUntil.toLocaleDateString(undefined, { month: 'short', day: 'numeric' })}.`
        : 'Refund requests have closed for this event.';
    case 'checked-in':
      return 'This ticket was already scanned at the door.';
    case 'refunded':
      return 'This ticket has already been refunded.';
    case 'voided':
      return 'This ticket is no longer valid.';
    case 'in-transfer':
      return 'This ticket is being transferred. Cancel the transfer to ask for a refund.';
    case 'event-cancelled':
      return 'The event was cancelled; refunds are sent automatically.';
    case 'marketplace':
      return 'Bought on a resale marketplace: ask the marketplace you bought it from.';
    case 'not-exos-paid':
    case 'not-buyer':
      return null;
    default:
      return null;
  }
}

/** One line on the organizer's refund policy, for the ticket page. */
export function policyLine(policy: string | null, askUntil: Date | null): string {
  if (policy === 'none') return 'All sales final.';
  if (!askUntil) return 'Ask the organizer for a refund.';
  const when = askUntil.toLocaleString(undefined, { month: 'short', day: 'numeric', hour: 'numeric', minute: '2-digit' });
  return `You can ask for a refund until ${when}. The organizer decides.`;
}

export async function fetchMyRefundAsks(eventId: string): Promise<MyRefundAsk[]> {
  const { data, error } = await supabase.rpc('exos_my_refund_asks', { p_event_id: eventId });
  if (error) throw error;
  return (Array.isArray(data) ? data : []).map(parseMyAsk);
}

export interface AskResult { ticketId: string; ok: boolean; reason?: string; askId?: string }

export async function askRefund(ticketIds: string[], reason: string): Promise<AskResult[]> {
  const { data, error } = await supabase.rpc('exos_ask_refund', { p_ticket_ids: ticketIds, p_reason: reason.trim() || null });
  if (error) throw new Error(error.message.replace(/^exos_ask_refund: /, ''));
  return (Array.isArray(data) ? data : []).map((r: any) => ({
    ticketId: String(r.ticket_id), ok: r.ok === true, reason: r.reason ?? undefined, askId: r.ask_id ?? undefined,
  }));
}

export async function withdrawRefundAsk(askId: string): Promise<boolean> {
  const { data, error } = await supabase.rpc('exos_withdraw_refund_ask', { p_ask_id: askId });
  if (error) throw error;
  return data === true;
}

export async function fetchEventRefundAsks(eventId: string): Promise<EventRefundAsk[]> {
  const { data, error } = await supabase.rpc('exos_event_refund_asks', { p_event_id: eventId });
  if (error) throw error;
  return (Array.isArray(data) ? data : []).map(parseEventAsk);
}

export async function declineRefundAsk(askId: string, note: string): Promise<boolean> {
  const { data, error } = await supabase.rpc('exos_decline_refund_ask', { p_ask_id: askId, p_note: note.trim() || null });
  if (error) throw new Error(error.message.replace(/^exos_decline_refund_ask: /, ''));
  return data === true;
}

/** Refund the ticket an ask is about. The nonce is the ask's, so a retry of
 *  this click never refunds twice; the ask closes when the refund succeeds. */
export function refundAsk(ask: Pick<EventRefundAsk, 'askId' | 'sessionId' | 'ticketId' | 'reason'>): Promise<RefundOutcome> {
  return refundOrder({
    sessionId: ask.sessionId,
    nonce: `ask:${ask.askId}`,
    reason: ask.reason ? `Buyer asked: ${ask.reason}`.slice(0, 500) : 'Buyer asked for a refund',
    items: [{ ticketId: ask.ticketId }],
  });
}
