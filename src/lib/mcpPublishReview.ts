// The publish review page (src/views/McpPublishReview.tsx, mig 20261119130000,
// docs/mcp.md "Writes"): an AI assistant's publish_event never publishes; the
// person opens /orgs/<org>/events/<id>/publish-review?request=<id>, signed in
// as the credential's user, checks the event as it is now and clicks Publish.
// The SQL (exos_mcp_publish_review / _approve) checks who, the org role, the
// expiry and that the event is still what the assistant previewed.

import { supabase } from './supabase';

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export interface PublishReview {
  request: { id: string; status: string; expires_at: string; created_at: string; via: 'api_key' | 'pat' | 'oauth'; app: string | null };
  state: {
    event: { id: string; name: string; status: string; starts_at: string | null; timezone: string | null; currency: string; venue_name: string | null; total_tickets: number | null };
    ticket_types: Array<{ id: string; name: string; price: number | string; capacity: number; sales_start: string | null; sales_end: string | null }>;
    blockers: Array<{ code: string; message: string }>;
  } | null;
  fee: { free_tier: boolean; max_capacity: number | null; free_tier_max_capacity: number } | null;
  unchanged: boolean;
}

export type ApproveAnswer = { ok: boolean; status: string; event_id: string; blockers?: Array<{ code: string; message: string }> };

/** The request id from the page's query (?request=…), or null. */
export function requestIdFrom(search: string): string | null {
  const v = new URLSearchParams(search).get('request');
  return v && UUID_RE.test(v) ? v : null;
}

/** Who asked, in words. */
export function viaLabel(r: PublishReview['request']): string {
  if (r.via === 'oauth') return r.app ? `${r.app} (an app you connected)` : 'an app you connected';
  if (r.via === 'pat') return 'your personal access token';
  return 'an API key you created';
}

/** Why Publish is off, or null when the person may publish. */
export function publishBlockedReason(v: PublishReview, now: Date = new Date()): string | null {
  if (v.request.status !== 'pending') return `This request is ${v.request.status}. Ask the assistant for a new one.`;
  if (Date.parse(v.request.expires_at) <= now.getTime()) return 'This link expired. Ask the assistant for a new one.';
  if (!v.state) return 'The event is gone.';
  if (v.state.event.status !== 'draft') return `The event is ${v.state.event.status}.`;
  if (!v.unchanged) return 'The event changed after the assistant showed you its summary. Ask it for a new review link.';
  if (v.state.blockers.length) return v.state.blockers.map((b) => b.message).join(' ');
  return null;
}

/** What an approval answer means, in words. */
export function approveMessage(a: ApproveAnswer): string {
  switch (a.status) {
    case 'published': return 'Published. The event is public and on sale per its sale windows.';
    case 'changed': return 'Not published: the event changed after the assistant\'s summary. Ask it for a new review link.';
    case 'expired': return 'Not published: this link expired. Ask the assistant for a new one.';
    case 'blocked': return `Not published: ${(a.blockers ?? []).map((b) => b.message).join(' ') || 'something blocks publishing.'}`;
    default: return `Not published: this request is ${a.status}.`;
  }
}

export async function fetchPublishReview(requestId: string): Promise<PublishReview> {
  const { data, error } = await supabase.rpc('exos_mcp_publish_review', { p_request: requestId });
  if (error) throw error;
  return data as PublishReview;
}

export async function approvePublish(requestId: string): Promise<ApproveAnswer> {
  const { data, error } = await supabase.rpc('exos_mcp_publish_approve', { p_request: requestId });
  if (error) throw error;
  return data as ApproveAnswer;
}
