// Supabase calls for communities (mig 20261031200000). Every write is an RPC
// that re-checks the caller's role; see docs/communities.md.
import { supabase } from './supabase';
import type { PublicCommunity } from './communities';

async function rpc<T>(fn: string, args: Record<string, unknown> = {}): Promise<T> {
  const { data, error } = await supabase.rpc(fn, args);
  if (error) throw error;
  return data as T;
}

export const getPublicCommunity = (slug: string) => rpc<PublicCommunity | null>('exos_public_community', { p_slug: slug });

export interface DirectoryResult {
  cities: { city: string; key: string; count: number }[];
  total: number;
  items: {
    slug: string; name: string; tagline: string | null; banner_url: string | null; city: string | null; region: string | null;
    country: string | null; join_mode: string; member_count: number; next_event_at: string | null; org_name: string | null;
  }[];
}
export const listCommunities = (city: string | null, query: string | null, offset = 0) =>
  rpc<DirectoryResult>('exos_public_communities', { p_city: city, p_query: query, p_limit: 24, p_offset: offset });

export const joinCommunity = (id: string, email: boolean, sms: boolean, consent: string | null, inviteToken?: string | null) =>
  rpc<{ status: string }>('exos_community_join', {
    p_community_id: id, p_notify_email: email, p_notify_sms: sms, p_consent_text: consent, p_invite_token: inviteToken ?? null,
  });
export const leaveCommunity = (id: string) => rpc<boolean>('exos_community_leave', { p_community_id: id });
export const setCommunityNotify = (id: string, email: boolean, sms: boolean, consent: string | null) =>
  rpc('exos_community_set_notify', { p_community_id: id, p_email: email, p_sms: sms, p_consent_text: consent });
export const previewInvite = (token: string) =>
  rpc<{ kind: 'member' | 'host'; community: string; slug: string; valid: boolean; display_name?: string } | null>(
    'exos_community_invite_preview', { p_token: token });
export const acceptHostInvite = (token: string) => rpc<{ slug: string }>('exos_community_host_accept', { p_token: token });
export const reportPost = (postId: string, reason: string, note: string | null) =>
  rpc('exos_community_report', { p_post_id: postId, p_reason: reason, p_note: note });
export const writePost = (id: string, title: string | null, body: string, visibility: 'public' | 'members', notify: boolean) =>
  rpc<{ id: string; notify_note: string | null; notified: { emailed: number; texted: number } | null }>('exos_community_post', {
    p_community_id: id, p_title: title, p_body: body, p_visibility: visibility, p_notify: notify,
  });
export const proposeEvent = (id: string, name: string, startsAt: string, timezone: string | null, venue: string | null) =>
  rpc<string>('exos_community_host_create_event', {
    p_community_id: id, p_name: name, p_starts_at: startsAt, p_timezone: timezone, p_venue_name: venue,
  });

// Organizer
export const saveCommunity = (orgId: string, id: string | null, fields: Record<string, unknown>) =>
  rpc<Record<string, unknown>>('exos_community_save', { p_org_id: orgId, p_id: id, p_fields: fields });
export const communityAdmin = (id: string) => rpc<CommunityAdmin>('exos_community_admin', { p_community_id: id });
export const memberList = (id: string, status: string) =>
  rpc<{ user_id: string; email: string; status: string; notify_email: boolean; notify_sms: boolean; joined_at: string | null;
    requested_at: string; ban_reason: string | null }[]>('exos_community_member_list', { p_community_id: id, p_status: status });
export const decideRequest = (id: string, userId: string, approve: boolean) =>
  rpc('exos_community_decide', { p_community_id: id, p_user_id: userId, p_approve: approve });
export const removeMember = (id: string, userId: string, ban: boolean, reason: string | null) =>
  rpc('exos_community_remove_member', { p_community_id: id, p_user_id: userId, p_ban: ban, p_reason: reason });
export const unbanMember = (id: string, userId: string) => rpc('exos_community_unban', { p_community_id: id, p_user_id: userId });
export const createInvite = (id: string, email: string | null, maxUses: number) =>
  rpc<{ token: string; path: string }>('exos_community_invite', { p_community_id: id, p_email: email, p_max_uses: maxUses });
export const revokeInvite = (inviteId: string) => rpc('exos_community_revoke_invite', { p_invite_id: inviteId });
export const inviteHost = (id: string, email: string, name: string, hostOrgId: string | null) =>
  rpc<{ token: string; path: string }>('exos_community_host_invite', {
    p_community_id: id, p_email: email, p_display_name: name, p_host_org_id: hostOrgId,
  });
export const revokeHost = (hostId: string) => rpc('exos_community_host_revoke', { p_host_id: hostId });
export const addCommunityEvent = (id: string, eventId: string, membersOnly: boolean, earlyUntil: string | null,
  rule: 'community' | 'membership' | 'either', productIds: string[]) =>
  rpc('exos_community_add_event', {
    p_community_id: id, p_event_id: eventId, p_members_only: membersOnly, p_early_access_until: earlyUntil,
    p_access_rule: rule, p_membership_product_ids: productIds,
  });
export const removeCommunityEvent = (id: string, eventId: string) =>
  rpc('exos_community_remove_event', { p_community_id: id, p_event_id: eventId });
export const moderatePost = (postId: string, action: 'hide' | 'remove' | 'restore') =>
  rpc('exos_community_moderate_post', { p_post_id: postId, p_action: action });
export const resolveReport = (reportId: string, action: 'dismiss' | 'hide' | 'remove' | 'ban') =>
  rpc('exos_community_resolve_report', { p_report_id: reportId, p_action: action });
export const reviewReply = (replyId: string, approve: boolean) =>
  rpc('exos_community_review_reply', { p_reply_id: replyId, p_approve: approve });
export const blockRemote = (id: string, pattern: string, block = true) =>
  rpc<number>('exos_community_block_remote', { p_community_id: id, p_pattern: pattern, p_block: block });

export async function listOrgCommunities(orgId: string) {
  const { data, error } = await supabase.from('exos_communities').select('id, slug, name, status, visibility, join_mode')
    .eq('org_id', orgId).order('created_at');
  if (error) throw error;
  return (data ?? []) as { id: string; slug: string; name: string; status: string; visibility: string; join_mode: string }[];
}

export interface CommunityAdmin {
  community: Record<string, unknown> & { id: string; slug: string; name: string; join_mode: string; visibility: string;
    federation_enabled: boolean; status: string };
  counts: { members: number; pending: number; banned: number; email: number; sms: number; fediverse_followers: number };
  hosts: { id: string; email: string; display_name: string; status: string; expires_at: string; accepted_at: string | null }[];
  invites: { id: string; email: string | null; uses: number; max_uses: number; expires_at: string }[];
  events: { event_id: string; name: string; starts_at: string | null; status: string; members_only: boolean;
    early_access_until: string | null; access_rule: string; announced_at: string | null; announce_note: string | null; host: string | null }[];
  posts: { id: string; title: string | null; body: string; visibility: string; status: string; notified_at: string | null;
    notify_note: string | null; created_at: string; host: string | null; open_reports: number }[];
  reports: { id: string; post_id: string; reason: string; note: string | null; created_at: string; post_excerpt: string | null }[];
  remote_replies: { id: string; actor_name: string | null; actor_handle: string | null; actor_uri: string; content_text: string;
    url: string | null; received_at: string }[];
  blocks: string[];
}
