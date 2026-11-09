// Publish blockers: what stops an event from going live (mig 20261031110000).
// The list comes from SQL (_exos_event_publish_blockers), the same one the
// partner API's GET /v1/events/:id/publish-blockers and POST .../publish use;
// publishing goes through exos_publish_event, which refuses while there are
// any. Nothing here decides a blocker: it fetches, publishes and formats.

import { supabase } from './supabase';

export type PublishBlockerCode =
  | 'event_cancelled' | 'missing_name' | 'missing_start' | 'starts_in_past' | 'ends_before_start'
  | 'doors_after_start' | 'missing_timezone' | 'missing_venue' | 'no_ticket_types' | 'stripe_not_connected'
  | 'not_found';

export interface PublishBlocker {
  code: PublishBlockerCode | string;
  field: string | null;
  message: string;
}

export interface PublishResult {
  published: boolean;
  status: string;
  blockers: PublishBlocker[];
}

/** Keeps only well-formed blockers (the RPC answers jsonb). */
export function parseBlockers(raw: unknown): PublishBlocker[] {
  if (!Array.isArray(raw)) return [];
  return raw
    .filter((b): b is Record<string, unknown> => !!b && typeof b === 'object' && typeof (b as any).code === 'string')
    .map((b) => ({
      code: String(b.code),
      field: typeof b.field === 'string' ? b.field : null,
      message: typeof b.message === 'string' && b.message ? b.message : String(b.code).replace(/_/g, ' '),
    }));
}

/** One line for a toast: "Add a venue. Add at least one ticket type." */
export function blockersSentence(blockers: PublishBlocker[]): string {
  return blockers.map((b) => b.message.trim().replace(/[.]?$/, '.')).join(' ');
}

/** The blockers of a saved event (owner / manager / content). */
export async function getPublishBlockers(eventId: string): Promise<PublishBlocker[]> {
  const { data, error } = await supabase.rpc('exos_event_publish_blockers', { p_event_id: eventId });
  if (error) throw error;
  return parseBlockers(data);
}

/** Publish a saved event (owner / manager); refused with the blockers while there are any. */
export async function publishEvent(eventId: string): Promise<PublishResult> {
  const { data, error } = await supabase.rpc('exos_publish_event', { p_event_id: eventId });
  if (error) throw error;
  const d = (data ?? {}) as Record<string, unknown>;
  return { published: d.published === true, status: String(d.status ?? ''), blockers: parseBlockers(d.blockers) };
}
