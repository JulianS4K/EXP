// An event's marketplace links (exos_channel_event_links, mig 20260926191000).
// Staff read them (RLS: owner/manager/finance) and decide review rows through
// exos_link_channel_event; exos-distribute fills them.

import { supabase } from '../supabase';

export interface LinkCandidate {
  external_event_id: string;
  name: string;
  starts_at: string | null;
  venue: string | null;
  url: string | null;
  score: number;
  reasons: string[];
}

export interface ChannelLink {
  channel: string;
  status: 'unmatched' | 'review' | 'linked' | 'created' | 'rejected';
  external_event_id: string | null;
  method: string | null;
  confidence: number | null;
  candidates: LinkCandidate[] | null;
  checked_at: string | null;
}

export async function getChannelLinks(eventId: string): Promise<ChannelLink[]> {
  const { data, error } = await supabase
    .from('exos_channel_event_links')
    .select('channel, status, external_event_id, method, confidence, candidates, checked_at')
    .eq('event_id', eventId)
    .order('channel');
  if (error) throw error;
  return (data ?? []) as ChannelLink[];
}

/** Link to a marketplace event, or `null` to say none of the candidates is this event. */
export async function linkChannelEvent(eventId: string, channel: string, externalEventId: string | null): Promise<string> {
  const { data, error } = await supabase.rpc('exos_link_channel_event', {
    p_event_id: eventId,
    p_channel: channel,
    p_external_event_id: externalEventId,
  });
  if (error) throw error;
  return data as string;
}

// Marketplace orders for an event (exos_marketplace_orders, mig 20260926192000).
export interface MarketplaceOrder {
  id: string;
  channel: string;
  external_order_id: string;
  quantity: number;
  status: 'received' | 'needs_attention' | 'fulfilled' | 'delivered' | 'cancelled';
  attention_reason: string | null;
  sold_at: string | null;
  delivery_plan: { kind: 'planned' | 'manual'; reason?: string; claim_urls: string[] } | null;
  buyer_email: string | null;
  /** Tickets minted for it; their pending transfers are what a resend covers. */
  transfer_ids: string[];
  handled_at: string | null;
  handled_note: string | null;
  links_resent_at: string | null;
}

export async function getMarketplaceOrders(eventId: string): Promise<MarketplaceOrder[]> {
  const { data, error } = await supabase
    .from('exos_marketplace_orders')
    .select('id, channel, external_order_id, quantity, status, attention_reason, sold_at, delivery_plan, buyer_email, transfer_ids, handled_at, handled_note, links_resent_at')
    .eq('event_id', eventId)
    .order('created_at', { ascending: false })
    .limit(50);
  if (error) throw error;
  return (data ?? []) as MarketplaceOrder[];
}

/**
 * Mail the order's buyer their claim links again, one per still-unclaimed
 * ticket (mig 20260929051000). Owner/manager; once per 10 minutes per order.
 * Resolves to the number of links sent.
 */
export async function resendMarketplaceClaimLinks(orderId: string): Promise<number> {
  const { data, error } = await supabase.rpc('exos_resend_marketplace_claim_links', { p_order_id: orderId });
  if (error) throw error;
  return data as number;
}

/** A person took care of an order that needed attention; Exos stops retrying it. */
export async function markMarketplaceOrderHandled(orderId: string, note: string | null): Promise<void> {
  const { error } = await supabase.rpc('exos_mark_marketplace_order_handled', { p_order_id: orderId, p_note: note });
  if (error) throw error;
}

/** What the organizer can do about one order, from its row. */
export function marketplaceOrderActions(o: Pick<MarketplaceOrder, 'status' | 'buyer_email' | 'transfer_ids' | 'handled_at'>): {
  resend: boolean;
  markHandled: boolean;
} {
  return {
    resend: !!o.buyer_email && (o.transfer_ids?.length ?? 0) > 0 && o.status !== 'cancelled',
    markHandled: o.status === 'needs_attention' && !o.handled_at,
  };
}

// Exos accounts holding more of an event's tickets than its max per account
// (exos_account_limit_flags, mig 20260926194000): flagged, never blocked.
// The org reviews them in its "Limit flags" tab.
export interface AccountLimitFlag {
  id: string;
  event_id: string;
  email: string | null;
  held: number;
  max_per_account: number;
  peak: number;
  promoter_codes: string[];
  first_flagged_at: string;
  reviewed_at: string | null;
  review_note: string | null;
  promoter_note: string | null;
  promoter_noted_by: string | null;
  exos_events: { name: string | null; starts_at: string | null } | null;
}

export async function getOrgLimitFlags(orgId: string): Promise<AccountLimitFlag[]> {
  const { data, error } = await supabase
    .from('exos_account_limit_flags')
    .select('id, event_id, email, held, max_per_account, peak, promoter_codes, first_flagged_at, reviewed_at, review_note, promoter_note, promoter_noted_by, exos_events(name, starts_at)')
    .eq('org_id', orgId)
    .order('reviewed_at', { ascending: true, nullsFirst: true })
    .order('last_seen_at', { ascending: false })
    .limit(500);
  if (error) throw error;
  return (data ?? []) as unknown as AccountLimitFlag[];
}

export async function reviewAccountLimitFlag(flagId: string, note: string | null): Promise<void> {
  const { error } = await supabase.rpc('exos_review_account_limit_flag', { p_flag_id: flagId, p_note: note });
  if (error) throw error;
}

// The promoter's view, by kit token (the portal has no login): flags for
// accounts that bought through their links, email masked.
export interface PromoterLimitFlag {
  id: string;
  event_id: string;
  event_name: string | null;
  starts_at: string | null;
  buyer: string | null;
  held: number;
  max_per_account: number;
  peak: number;
  from_you: number;
  reviewed: boolean;
  promoter_note: string | null;
}

export async function getPromoterLimitFlags(token: string): Promise<PromoterLimitFlag[]> {
  const { data, error } = await supabase.rpc('exos_promoter_limit_flags', { p_token: token });
  if (error) throw error;
  return (data ?? []) as PromoterLimitFlag[];
}

export async function notePromoterLimitFlag(token: string, flagId: string, note: string): Promise<void> {
  const { error } = await supabase.rpc('exos_promoter_note_limit_flag', { p_token: token, p_flag_id: flagId, p_note: note });
  if (error) throw error;
}
