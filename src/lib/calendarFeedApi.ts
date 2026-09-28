// The personal calendar feed link (/me/<token>.ics; docs/calendar.md). The raw
// token only exists in the create response: the database keeps its hash, so
// the link can be shown once, then only rotated or turned off.

import { supabase } from './supabase';

export interface FeedTokenStatus {
  active: boolean;
  created_at?: string;
  last_used_at?: string | null;
}

export async function myFeedStatus(): Promise<FeedTokenStatus> {
  const { data, error } = await supabase.rpc('exos_calendar_feed_token_status');
  if (error) throw error;
  return (data as FeedTokenStatus) ?? { active: false };
}

/** A new feed token (the previous link stops working). */
export async function createMyFeedToken(): Promise<string> {
  const { data, error } = await supabase.rpc('exos_calendar_feed_token_create');
  if (error) throw error;
  return data as string;
}

export async function revokeMyFeedToken(): Promise<boolean> {
  const { data, error } = await supabase.rpc('exos_calendar_feed_token_revoke');
  if (error) throw error;
  return Boolean(data);
}
