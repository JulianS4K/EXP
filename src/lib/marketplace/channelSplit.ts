// RPCs for the auto split (mig 20261014090000); the model is ./channelSplitModel.

import { supabase } from '../supabase';
import { isMissingRpc } from '../door/net';
import { parseChannelSplit, type ChannelSplit, type SplitMode } from './channelSplitModel';

export { describeSplit, parseChannelSplit } from './channelSplitModel';
export type { ChannelSplit, SplitMode, SplitTier } from './channelSplitModel';

/** null when the migration isn't deployed. */
export async function fetchChannelSplit(eventId: string): Promise<ChannelSplit | null> {
  const { data, error } = await supabase.rpc('exos_channel_split_preview', { p_event_id: eventId });
  if (error) {
    if (isMissingRpc(error)) return null;
    throw error;
  }
  return parseChannelSplit(data);
}

export async function setChannelSplit(eventId: string, mode: SplitMode, reservePct?: number, taperHours?: number): Promise<ChannelSplit> {
  const { data, error } = await supabase.rpc('exos_set_channel_split', {
    p_event_id: eventId, p_mode: mode, p_reserve_pct: reservePct ?? null, p_taper_hours: taperHours ?? null,
  });
  if (error) throw error;
  return parseChannelSplit(data);
}
