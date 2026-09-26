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
}

export async function getMarketplaceOrders(eventId: string): Promise<MarketplaceOrder[]> {
  const { data, error } = await supabase
    .from('exos_marketplace_orders')
    .select('id, channel, external_order_id, quantity, status, attention_reason, sold_at, delivery_plan')
    .eq('event_id', eventId)
    .order('created_at', { ascending: false })
    .limit(50);
  if (error) throw error;
  return (data ?? []) as MarketplaceOrder[];
}
