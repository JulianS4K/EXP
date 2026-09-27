// Reads an event's marketplace rows (migs 20260926190000, 20260927030000):
// per marketplace, an event row (tier_id NULL) and an allocation row per
// ticket type. Org owners, managers and finance can read them (RLS); nobody
// writes them from the browser: the exos_events trigger queues,
// exos_set_channel_allocation allocates, exos-distribute plans.

import { supabase } from '../supabase';
import type { MarketplaceRow, StubHubDistributionRow } from './stubhubStatus';

export type AllocationChannel = 'stubhub' | 'seatgeek';

const COLS = 'channel, tier_id, status, error, external_event_id, planned_request, planned_listing, last_synced_at, requested_qty, internal_seats';

/** Every StubHub / SeatGeek row of the event. */
export async function getMarketplaceRows(eventId: string): Promise<MarketplaceRow[]> {
  const { data, error } = await supabase
    .from('exos_distribution_listings')
    .select(COLS)
    .eq('event_id', eventId)
    .in('channel', ['stubhub', 'seatgeek']);
  if (error) throw error;
  return (data ?? []) as MarketplaceRow[];
}

/** The event row for one marketplace (the StubHub event request / SeatGeek event). */
export async function getChannelDistribution(eventId: string, channel: AllocationChannel): Promise<StubHubDistributionRow | null> {
  const { data, error } = await supabase
    .from('exos_distribution_listings')
    .select(COLS)
    .eq('event_id', eventId)
    .eq('channel', channel)
    .is('tier_id', null)
    .maybeSingle();
  if (error) throw error;
  return (data as StubHubDistributionRow | null) ?? null;
}

export function getStubHubDistribution(eventId: string): Promise<StubHubDistributionRow | null> {
  return getChannelDistribution(eventId, 'stubhub');
}

/**
 * How many seats of one ticket type go to a marketplace
 * (exos_set_channel_allocation). Exos stops selling those seats at once; 0
 * takes the listing down and then gives them back. Refused when the seats
 * aren't free, the marketplace isn't ticked, or the event's overall cap is
 * tighter than its ticket types.
 */
export async function setChannelAllocation(eventId: string, channel: AllocationChannel, tierId: string, qty: number): Promise<number> {
  const { data, error } = await supabase.rpc('exos_set_channel_allocation', {
    p_event_id: eventId,
    p_channel: channel,
    p_tier_id: tierId,
    p_qty: qty,
  });
  if (error) throw error;
  return data as number;
}
