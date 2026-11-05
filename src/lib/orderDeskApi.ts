// The Orders page's calls (mig 20261102140000). Every RPC checks the caller's
// role in the org itself; the page only hides what a role can't do.

import { supabase } from './supabase';
import { assertNotEmailName } from '../../supabase/functions/_shared/nameGuard.ts';
import {
  orderQuery, parseOrderEdit, parseOrderRow, type OrderEditRow, type OrderRow, type OrderTableState, type PreviewRow,
} from './orderDesk';
import { parseRecEvent, parseRecFan, type RecEvent, type RecFan } from './recommendations';

const msg = (e: { message?: string }) => new Error((e.message ?? 'Failed.').replace(/^_?exos_\w+: /, ''));
const int = (v: unknown) => Math.max(0, Math.trunc(Number(v) || 0));

async function call<T = any>(fn: string, args: Record<string, unknown>): Promise<T> {
  const { data, error } = await supabase.rpc(fn, args);
  if (error) throw msg(error);
  return data as T;
}

export async function listOrders(orgId: string, s: OrderTableState): Promise<{ total: number; rows: OrderRow[] }> {
  const d = await call('exos_org_orders', orderQuery(orgId, s));
  return { total: int(d?.total), rows: (Array.isArray(d?.rows) ? d.rows : []).map(parseOrderRow) };
}

export async function updateOrder(sessionId: string, fields: Record<string, string | null>) {
  assertNotEmailName(fields.first_name);
  assertNotEmailName(fields.last_name);
  return parseOrderRow(await call('exos_order_update', { p_session_id: sessionId, p_fields: fields }));
}

export async function sendReceipt(sessionId: string, email: string | null): Promise<{ to: string; resendsLeft: number }> {
  const d = await call('exos_order_send_receipt', { p_session_id: sessionId, p_email: email });
  return { to: String(d?.to ?? ''), resendsLeft: int(d?.resends_left_this_hour) };
}

export async function checkOutOrder(sessionId: string, reason: string | null) {
  return await call<{ checked_out: number; results: Array<{ reason?: string }> }>(
    'exos_order_check_out', { p_session_id: sessionId, p_list_id: null, p_reason: reason, p_device: 'dashboard' });
}

export async function updateTicketAttendee(ticketId: string, attendeeName: string | null) {
  assertNotEmailName(attendeeName);
  return await call('exos_ticket_update', { p_ticket_id: ticketId, p_fields: { attendee_name: attendeeName } });
}

export interface OrderTicket { id: string; tierName: string; attendeeName: string | null; status: string; inTransfer: boolean }

export async function orderTickets(sessionId: string): Promise<OrderTicket[]> {
  const d = await call('exos_order_tickets', { p_session_id: sessionId });
  return (Array.isArray(d) ? d : []).map((t: any) => ({
    id: String(t.id), tierName: t.tier_name ?? 'Ticket', attendeeName: t.attendee_name ?? null, status: String(t.status ?? ''),
    inTransfer: t.in_transfer === true,
  }));
}

export async function listOrderEdits(orgId: string, opts: { sessionId?: string; action?: string; limit?: number; offset?: number } = {}) {
  const d = await call('exos_order_edit_log', {
    p_org_id: orgId, p_session_id: opts.sessionId ?? null, p_action: opts.action || null,
    p_limit: opts.limit ?? 25, p_offset: opts.offset ?? 0,
  });
  return { total: int(d?.total), rows: (Array.isArray(d?.rows) ? d.rows : []).map(parseOrderEdit) as OrderEditRow[] };
}

export interface OrderSettings { receiptOverrideEmail: boolean; receiptResendsPerHour: number }

export async function getOrderSettings(orgId: string): Promise<OrderSettings> {
  const d = await call('exos_order_settings_get', { p_org_id: orgId });
  return { receiptOverrideEmail: d?.receipt_override_email === true, receiptResendsPerHour: int(d?.receipt_resends_per_hour) || 3 };
}

export async function saveOrderSettings(orgId: string, s: OrderSettings): Promise<OrderSettings> {
  const d = await call('exos_order_settings_save', {
    p_org_id: orgId, p_receipt_override_email: s.receiptOverrideEmail, p_receipt_resends_per_hour: s.receiptResendsPerHour,
  });
  return { receiptOverrideEmail: d?.receipt_override_email === true, receiptResendsPerHour: int(d?.receipt_resends_per_hour) || 3 };
}

export async function previewGuestList(eventId: string, listId: string | null, rows: PreviewRow[]) {
  return await call('exos_guest_list_preview', { p_event_id: eventId, p_list_id: listId, p_rows: rows });
}

export async function similarEvents(eventId: string, cross: boolean, limit: number, offset: number): Promise<{ total: number; rows: RecEvent[] }> {
  const d = await call('exos_event_similar_events', { p_event_id: eventId, p_cross: cross, p_limit: limit, p_offset: offset });
  return { total: int(d?.total), rows: (Array.isArray(d?.rows) ? d.rows : []).map(parseRecEvent) };
}

export async function fanRecommendations(eventId: string, limit: number, offset: number): Promise<{ total: number; rows: RecFan[] }> {
  const d = await call('exos_event_fan_recommendations', { p_event_id: eventId, p_limit: limit, p_offset: offset });
  return { total: int(d?.total), rows: (Array.isArray(d?.rows) ? d.rows : []).map(parseRecFan) };
}
