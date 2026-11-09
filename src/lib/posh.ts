// Posh (mig 20261029150000): Posh orders arrive by webhook, Posh sells from a
// capped tier carved out of one Exos ticket type, and Posh buyers land on
// the door list. Exos never writes to Posh (it has no API for organizers).
// Pure parsing up top; the RPC calls below.

import { supabase } from './supabase';

export interface PoshLink { id: string; poshRef: string; poshLabel: string | null; eventId: string; eventName: string | null }
export interface PoshUnmatched {
  id: string; poshEventId: string | null; poshEventSlug: string | null; poshEventName: string | null;
  state: 'pending' | 'confirmed'; quantity: number; ticketLabel: string | null; receivedAt: Date | null;
}
export interface PoshStatus {
  connected: boolean;
  disabled: boolean;
  hint: string | null;
  lastReceivedAt: Date | null;
  lastOutcome: string | null;
  received: number;
  canManage: boolean;
  counts: { orders: number; confirmed: number; pending: number; unmatched: number; tickets: number; oversold: number };
  links: PoshLink[];
  unmatched: PoshUnmatched[];
}

export interface PoshCap {
  tierId: string; tierName: string | null; cap: number; soldInCap: number; remaining: number;
  oversold: number; oversoldUnacked: number; uncovered: number;
}
export interface PoshOrderRow {
  id: string; poshOrderId: string | null; state: 'pending' | 'confirmed' | 'cancelled'; quantity: number;
  ticketLabel: string | null; buyerName: string | null; buyerEmail: string | null; overQty: number;
  attention: string | null; receivedAt: Date | null;
}
export interface PoshEventStatus {
  connected: boolean;
  canManage: boolean;
  links: { id: string; poshRef: string }[];
  cap: PoshCap | null;
  sales: { confirmedOrders: number; confirmedTickets: number; pendingOrders: number; pendingTickets: number; uncountedOrders: number };
  orders: PoshOrderRow[];
}

const n = (v: unknown) => (Number.isFinite(Number(v)) ? Number(v) : 0);
const s = (v: unknown) => (typeof v === 'string' && v ? v : null);
const date = (v: unknown) => (typeof v === 'string' ? new Date(v) : null);

export function parsePoshStatus(d: any): PoshStatus {
  const c = d?.counts ?? {};
  return {
    connected: d?.connected === true,
    disabled: d?.status === 'disabled',
    hint: s(d?.hint),
    lastReceivedAt: date(d?.last_received_at),
    lastOutcome: s(d?.last_outcome),
    received: n(d?.received),
    canManage: d?.can_manage === true,
    counts: { orders: n(c.orders), confirmed: n(c.confirmed), pending: n(c.pending), unmatched: n(c.unmatched), tickets: n(c.tickets), oversold: n(c.oversold) },
    links: (Array.isArray(d?.links) ? d.links : []).map((l: any): PoshLink => ({
      id: String(l.id), poshRef: String(l.posh_ref ?? ''), poshLabel: s(l.posh_label), eventId: String(l.event_id), eventName: s(l.event_name),
    })),
    unmatched: (Array.isArray(d?.unmatched) ? d.unmatched : []).map((u: any): PoshUnmatched => ({
      id: String(u.id), poshEventId: s(u.posh_event_id), poshEventSlug: s(u.posh_event_slug), poshEventName: s(u.posh_event_name),
      state: u.state === 'pending' ? 'pending' : 'confirmed', quantity: n(u.quantity) || 1, ticketLabel: s(u.ticket_label),
      receivedAt: date(u.received_at),
    })),
  };
}

export function parsePoshEventStatus(d: any): PoshEventStatus {
  const c = d?.cap;
  const sales = d?.sales ?? {};
  return {
    connected: d?.connected === true,
    canManage: d?.can_manage === true,
    links: (Array.isArray(d?.links) ? d.links : []).map((l: any) => ({ id: String(l.id), poshRef: String(l.posh_ref ?? '') })),
    cap: c && typeof c === 'object' ? {
      tierId: String(c.tier_id), tierName: s(c.tier_name), cap: n(c.cap), soldInCap: n(c.sold_in_cap), remaining: n(c.remaining),
      oversold: n(c.oversold), oversoldUnacked: n(c.oversold_unacked), uncovered: n(c.uncovered),
    } : null,
    sales: {
      confirmedOrders: n(sales.confirmed_orders), confirmedTickets: n(sales.confirmed_tickets),
      pendingOrders: n(sales.pending_orders), pendingTickets: n(sales.pending_tickets), uncountedOrders: n(sales.uncounted_orders),
    },
    orders: (Array.isArray(d?.orders) ? d.orders : []).map((o: any): PoshOrderRow => ({
      id: String(o.id), poshOrderId: s(o.posh_order_id),
      state: o.state === 'pending' || o.state === 'cancelled' ? o.state : 'confirmed',
      quantity: n(o.quantity) || 1, ticketLabel: s(o.ticket_label), buyerName: s(o.buyer_name), buyerEmail: s(o.buyer_email),
      overQty: n(o.over_qty), attention: s(o.attention), receivedAt: date(o.received_at),
    })),
  };
}

/** The URL to paste into Posh. `token` is only known right after connecting / rotating. */
export function poshWebhookUrl(supabaseUrl: string, token: string): string {
  const base = supabaseUrl.replace(/\/+$/, '');
  return base && /^[0-9a-f]{64}$/.test(token) ? `${base}/functions/v1/exos-posh-webhook/${token}` : '';
}

/** How an unmatched order names its Posh event, for the list. */
export function unmatchedLabel(u: PoshUnmatched): string {
  return u.poshEventName ?? u.poshEventSlug ?? (u.poshEventId ? `Posh event ${u.poshEventId}` : 'No event named in the webhook');
}

/** One line about the cap for the event's channel area. */
export function capLine(c: PoshCap | null): string {
  if (!c) return 'No Posh cap yet: set how many tickets Posh may sell, then set the same number on Posh.';
  const base = `Posh may sell ${c.cap} ${c.tierName ? `${c.tierName} ` : ''}ticket${c.cap === 1 ? '' : 's'}: ${c.soldInCap} sold, ${c.remaining} left.`;
  return c.oversold > 0 ? `${base} ${c.oversold} sold past the cap.` : base;
}

// ── Calls ───────────────────────────────────────────────────────────────

const env = (import.meta as { env?: Record<string, string | undefined> }).env ?? {};
const rpcMsg = (e: { message?: string }) => new Error((e.message ?? 'Not saved.').replace(/^exos_\w+: /, ''));

export function supabaseUrl(): string {
  return env.VITE_SUPABASE_URL ?? '';
}

export async function fetchPoshStatus(orgId: string): Promise<PoshStatus> {
  const { data, error } = await supabase.rpc('exos_posh_status', { p_org_id: orgId });
  if (error) throw rpcMsg(error);
  return parsePoshStatus(data);
}

/** Create or rotate the webhook. Returns the URL once. */
export async function connectPosh(orgId: string): Promise<{ url: string; rotated: boolean }> {
  const { data, error } = await supabase.rpc('exos_posh_connect', { p_org_id: orgId });
  if (error) throw rpcMsg(error);
  return { url: poshWebhookUrl(supabaseUrl(), String(data?.token ?? '')), rotated: data?.rotated === true };
}

export async function disconnectPosh(orgId: string): Promise<void> {
  const { error } = await supabase.rpc('exos_posh_disconnect', { p_org_id: orgId });
  if (error) throw rpcMsg(error);
}

export async function linkPoshEvent(orgId: string, poshRef: string, eventId: string): Promise<{ ordersMatched: number }> {
  const { data, error } = await supabase.rpc('exos_posh_link_event', { p_org_id: orgId, p_posh_ref: poshRef, p_event_id: eventId, p_label: null });
  if (error) throw rpcMsg(error);
  return { ordersMatched: n(data?.orders_matched) };
}

export async function unlinkPoshEvent(linkId: string): Promise<void> {
  const { error } = await supabase.rpc('exos_posh_unlink_event', { p_link_id: linkId });
  if (error) throw rpcMsg(error);
}

export async function assignPoshOrder(orderId: string, eventId: string): Promise<{ ordersMatched: number }> {
  const { data, error } = await supabase.rpc('exos_posh_assign_order', { p_order_id: orderId, p_event_id: eventId });
  if (error) throw rpcMsg(error);
  return { ordersMatched: n(data?.orders_matched) };
}

export async function fetchPoshEventStatus(eventId: string): Promise<PoshEventStatus> {
  const { data, error } = await supabase.rpc('exos_posh_event_status', { p_event_id: eventId });
  if (error) throw rpcMsg(error);
  return parsePoshEventStatus(data);
}

export async function setPoshCap(eventId: string, tierId: string, cap: number): Promise<void> {
  const { error } = await supabase.rpc('exos_posh_set_cap', { p_event_id: eventId, p_tier_id: tierId, p_cap: cap });
  if (error) throw rpcMsg(error);
}

export async function ackPoshOversell(eventId: string): Promise<void> {
  const { error } = await supabase.rpc('exos_posh_ack_oversell', { p_event_id: eventId });
  if (error) throw rpcMsg(error);
}

export async function cancelPoshOrder(orderId: string): Promise<void> {
  const { error } = await supabase.rpc('exos_posh_cancel_order', { p_order_id: orderId });
  if (error) throw rpcMsg(error);
}

/** The org's events, newest first, for the link / assign pickers. */
export async function fetchOrgEvents(orgId: string): Promise<{ id: string; name: string }[]> {
  const { data, error } = await supabase.from('exos_events').select('id, name, starts_at').eq('org_id', orgId)
    .neq('status', 'cancelled').order('starts_at', { ascending: false }).limit(100);
  if (error) throw rpcMsg(error);
  return (data ?? []).map((e: any) => ({ id: String(e.id), name: String(e.name ?? 'Untitled event') }));
}

/** The event's ticket types, for the cap picker. */
export async function fetchEventTiers(eventId: string): Promise<{ id: string; name: string; capacity: number }[]> {
  const { data, error } = await supabase.from('exos_ticket_tiers').select('id, name, capacity, kind')
    .eq('event_id', eventId).order('sort_order', { ascending: true });
  if (error) throw rpcMsg(error);
  return (data ?? []).filter((t: any) => t.kind !== 'table' && n(t.capacity) > 0)
    .map((t: any) => ({ id: String(t.id), name: String(t.name ?? 'Ticket'), capacity: n(t.capacity) }));
}
