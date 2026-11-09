// Group chat for social groups (mig 20261031230000, docs/group-chat.md):
// in-app chat over Supabase Realtime, the masked SMS relay, and mutual
// contact reveal. Pure helpers first (tested), then the RPC wrappers.

import type { RealtimeChannel } from '@supabase/supabase-js';
import { supabase } from './supabase';
import { formatRelayBody, relayConsentText } from '../../supabase/functions/_shared/sms/relay.ts';

export { formatRelayBody, relayConsentText };

export const MAX_MESSAGE_CHARS = 1000;
export const MAX_MESSAGE_LINKS = 3;
const LINK = /(https?:\/\/|www\.)[^\s<>"']+/gi;

/** Why a draft can't be sent, or null when it can (the server checks the same). */
export function messageProblem(body: string): string | null {
  const t = body.trim();
  if (!t) return 'Type a message.';
  if (Array.from(t).length > MAX_MESSAGE_CHARS) return `At most ${MAX_MESSAGE_CHARS.toLocaleString('en-US')} characters.`;
  if ((t.match(/(https?:\/\/|www\.)/gi) ?? []).length > MAX_MESSAGE_LINKS) return `At most ${MAX_MESSAGE_LINKS} links.`;
  return null;
}

export type TextPart = { text: string } | { text: string; href: string };

/**
 * Split a message into text and links. Only http(s) and www. links become
 * links (www. gets https://); trailing punctuation stays text. Rendered with
 * rel="nofollow noopener noreferrer ugc", never as HTML.
 */
export function linkify(body: string): TextPart[] {
  const out: TextPart[] = [];
  let at = 0;
  for (const m of body.matchAll(LINK)) {
    let raw = m[0];
    const trail = /[.,!?;:)\]]+$/.exec(raw)?.[0] ?? '';
    if (trail) raw = raw.slice(0, -trail.length);
    const start = m.index ?? 0;
    if (start > at) out.push({ text: body.slice(at, start) });
    const href = raw.toLowerCase().startsWith('www.') ? `https://${raw}` : raw;
    let ok = false;
    try { ok = ['http:', 'https:'].includes(new URL(href).protocol); } catch { ok = false; }
    out.push(ok ? { text: raw, href } : { text: raw });
    at = start + raw.length;
  }
  if (at < body.length) out.push({ text: body.slice(at) });
  return out.length ? out : [{ text: body }];
}

export interface GroupMessage {
  id: string; groupId: string; senderId: string | null; senderName: string; body: string;
  source: 'app' | 'sms' | 'system'; createdAt: Date;
}

export function parseMessage(r: any): GroupMessage | null {
  if (!r?.id || !r?.group_id) return null;
  return {
    id: String(r.id), groupId: String(r.group_id), senderId: r.sender_id ?? null,
    senderName: String(r.sender_name ?? 'Member'), body: String(r.body ?? ''),
    source: r.source === 'sms' || r.source === 'system' ? r.source : 'app', createdAt: new Date(r.created_at),
  };
}

/** Oldest first, one row per id (Realtime and a refetch can deliver the same row). */
export function mergeMessages(a: GroupMessage[], b: GroupMessage[]): GroupMessage[] {
  const byId = new Map<string, GroupMessage>();
  for (const m of [...a, ...b]) byId.set(m.id, m);
  return [...byId.values()].sort((x, y) => x.createdAt.getTime() - y.createdAt.getTime() || x.id.localeCompare(y.id));
}

/** "Chat closes in 3 days" / "closes today" / "Chat closed", or null when it never closes. */
export function closesLabel(closesAt: Date | null, now = new Date()): string | null {
  if (!closesAt) return null;
  const ms = closesAt.getTime() - now.getTime();
  if (ms <= 0) return 'Chat closed';
  const days = Math.floor(ms / 86_400_000);
  if (days === 0) return 'Chat closes today';
  return `Chat closes in ${days} day${days === 1 ? '' : 's'}`;
}

/** Display a +E.164 US / CA number as +1 (212) 555-0100; anything else unchanged. */
export function formatPhone(e164: string | null | undefined): string {
  const m = /^\+1(\d{3})(\d{3})(\d{4})$/.exec(e164 ?? '');
  return m ? `+1 (${m[1]}) ${m[2]}-${m[3]}` : (e164 ?? '');
}

export interface GroupMember { userId: string; displayName: string; role: string; me: boolean; blocked: boolean }
export interface GroupState {
  id: string; orgId: string; eventId: string | null; title: string; kind: string;
  closesAt: Date | null; open: boolean; eventOver: boolean; relayEnabled: boolean;
  me: {
    userId: string; displayName: string; role: string; mutedUntil: Date | null; silencedUntil: Date | null;
    relayNumber: string | null; smsOn: boolean; smsPhoneHint: string | null; smsStopped: boolean;
  };
  members: GroupMember[];
}

const date = (v: unknown) => (v ? new Date(String(v)) : null);

export function parseState(d: any): GroupState {
  const me = d?.me ?? {};
  return {
    id: String(d?.id), orgId: String(d?.org_id), eventId: d?.event_id ?? null, title: String(d?.title ?? ''),
    kind: String(d?.kind ?? ''), closesAt: date(d?.closes_at), open: d?.open === true, eventOver: d?.event_over === true,
    relayEnabled: d?.relay_enabled === true,
    me: {
      userId: String(me.user_id ?? ''), displayName: String(me.display_name ?? ''), role: String(me.role ?? 'member'),
      mutedUntil: date(me.muted_until), silencedUntil: date(me.silenced_until), relayNumber: me.relay_number ?? null,
      smsOn: me.sms_on === true, smsPhoneHint: me.sms_phone_hint ?? null, smsStopped: me.sms_stopped === true,
    },
    members: (Array.isArray(d?.members) ? d.members : []).map((m: any) => ({
      userId: String(m.user_id), displayName: String(m.display_name ?? 'Member'), role: String(m.role ?? 'member'),
      me: m.me === true, blocked: m.blocked === true,
    })),
  };
}

export interface ContactReveal { userId: string; displayName: string; kind: 'phone' | 'instagram'; value: string }
export interface MyShare { kind: 'phone' | 'instagram'; toUser: string | null; toName: string | null; value: string }
export interface Contacts { eventOver: boolean; mine: MyShare[]; revealed: ContactReveal[] }

export function parseContacts(d: any): Contacts {
  const kind = (k: unknown) => (k === 'instagram' ? 'instagram' : 'phone') as 'phone' | 'instagram';
  return {
    eventOver: d?.event_over === true,
    mine: (Array.isArray(d?.mine) ? d.mine : []).map((s: any) => ({
      kind: kind(s.kind), toUser: s.to_user ?? null, toName: s.to_name ?? null, value: String(s.value ?? ''),
    })),
    revealed: (Array.isArray(d?.revealed) ? d.revealed : []).map((r: any) => ({
      userId: String(r.user_id), displayName: String(r.display_name ?? 'Member'), kind: kind(r.kind), value: String(r.value ?? ''),
    })),
  };
}

/** Where an Instagram handle points. */
export function instagramUrl(handle: string): string {
  return `https://www.instagram.com/${encodeURIComponent(handle.replace(/^@/, ''))}/`;
}

// ---------------------------------------------------------------------------
// RPCs
// ---------------------------------------------------------------------------
const msg = (e: { message?: string }) => new Error((e.message ?? 'Failed.').replace(/^exos_\w+: /, '').replace(/^exos_\w+: /, ''));

async function rpc<T>(name: string, args: Record<string, unknown> = {}): Promise<T> {
  const { data, error } = await supabase.rpc(name, args);
  if (error) throw msg(error);
  return data as T;
}

export interface MyGroup { id: string; title: string; kind: string; orgId: string; eventId: string | null; closesAt: Date | null; open: boolean; lastMessageAt: Date | null }

export async function myGroups(): Promise<MyGroup[]> {
  const d = await rpc<any[]>('exos_my_groups');
  return (d ?? []).map((g) => ({
    id: String(g.id), title: String(g.title ?? ''), kind: String(g.kind ?? ''), orgId: String(g.org_id),
    eventId: g.event_id ?? null, closesAt: date(g.closes_at), open: g.open === true, lastMessageAt: date(g.last_message_at),
  }));
}

export const groupState = async (groupId: string) => parseState(await rpc('exos_group_state', { p_group_id: groupId }));
export const joinGroup = (groupId: string) => rpc('exos_group_join', { p_group_id: groupId });
export const leaveGroup = (groupId: string) => rpc<boolean>('exos_group_leave', { p_group_id: groupId });
export const setMyName = (groupId: string, name: string) => rpc<string>('exos_group_set_name', { p_group_id: groupId, p_name: name });
export const muteGroup = (groupId: string, until: Date | null) =>
  rpc<boolean>('exos_group_mute', { p_group_id: groupId, p_until: until ? until.toISOString() : null });
export const blockMember = (groupId: string, userId: string, block = true) =>
  rpc<boolean>('exos_group_block', { p_group_id: groupId, p_user_id: userId, p_block: block });
export const reportMessage = (messageId: string, reason: string) =>
  rpc<{ reported: boolean; hidden: boolean }>('exos_group_report', { p_message_id: messageId, p_reason: reason });

/** Messages (RLS: members only), newest page first, returned oldest first. */
export async function listMessages(groupId: string, before?: Date, limit = 50): Promise<GroupMessage[]> {
  let q = supabase.from('exos_group_messages')
    .select('id, group_id, sender_id, sender_name, body, source, created_at')
    .eq('group_id', groupId).order('created_at', { ascending: false }).limit(limit);
  if (before) q = q.lt('created_at', before.toISOString());
  const { data, error } = await q;
  if (error) throw msg(error);
  return mergeMessages([], (data ?? []).map(parseMessage).filter((m): m is GroupMessage => m !== null));
}

export async function postMessage(groupId: string, body: string, clientRef: string) {
  return rpc<{ message_id: string; duplicate: boolean }>('exos_group_post', { p_group_id: groupId, p_body: body.trim(), p_client_ref: clientRef });
}

/**
 * New messages over Supabase Realtime (postgres_changes on exos_group_messages,
 * under the same members-only RLS). Callers also poll as a fallback.
 */
export function subscribeMessages(groupId: string, onMessage: (m: GroupMessage) => void): () => void {
  const channel: RealtimeChannel = supabase
    .channel(`exos-group:${groupId}`)
    .on('postgres_changes', { event: 'INSERT', schema: 'public', table: 'exos_group_messages', filter: `group_id=eq.${groupId}` },
      (payload) => {
        const m = parseMessage(payload.new);
        if (m) onMessage(m);
      })
    .subscribe();
  return () => { void supabase.removeChannel(channel); };
}

export async function smsOptIn(groupId: string, groupTitle: string, phone: string) {
  return rpc<{ sms_on: boolean; relay_number: string; phone_hint: string }>('exos_group_sms_opt_in', {
    p_group_id: groupId, p_phone: phone, p_consent_text: relayConsentText(groupTitle),
  });
}
export const smsOptOut = (groupId: string) => rpc<boolean>('exos_group_sms_opt_out', { p_group_id: groupId });

export const contacts = async (groupId: string) => parseContacts(await rpc('exos_group_contacts', { p_group_id: groupId }));
export const shareContact = (groupId: string, kind: 'phone' | 'instagram', toUser: string | null, value?: string) =>
  rpc('exos_group_share_contact', { p_group_id: groupId, p_kind: kind, p_to_user: toUser, p_value: value ?? null });
export const revokeContact = (groupId: string, kind: 'phone' | 'instagram', toUser: string | null) =>
  rpc<boolean>('exos_group_revoke_contact', { p_group_id: groupId, p_kind: kind, p_to_user: toUser });

// Organizer side ------------------------------------------------------------
export interface OrgGroup {
  id: string; title: string; kind: string; eventId: string | null; joinPolicy: string; closeAfterDays: number;
  dailySmsCap: number; relayEnabled: boolean; closesAt: Date | null; open: boolean; members: number; smsMembers: number;
  smsSegments24h: number; openReports: number;
}

export async function orgGroups(orgId: string): Promise<OrgGroup[]> {
  const d = await rpc<any[]>('exos_org_groups', { p_org_id: orgId });
  return (d ?? []).map((g) => ({
    id: String(g.id), title: String(g.title ?? ''), kind: String(g.kind ?? ''), eventId: g.event_id ?? null,
    joinPolicy: String(g.join_policy ?? 'invite'), closeAfterDays: Number(g.close_after_days) || 0,
    dailySmsCap: Number(g.daily_sms_cap) || 0, relayEnabled: g.relay_enabled === true, closesAt: date(g.closes_at),
    open: g.open === true, members: Number(g.members) || 0, smsMembers: Number(g.sms_members) || 0,
    smsSegments24h: Number(g.sms_segments_24h) || 0, openReports: Number(g.open_reports) || 0,
  }));
}

/** Every group belongs to one of the org's events (event_id is required). */
export const createGroup = (orgId: string, title: string, kind: string, eventId: string, closeAfterDays: number, dailySmsCap: number) =>
  rpc<string>('exos_group_create', {
    p_org_id: orgId, p_title: title, p_kind: kind, p_event_id: eventId, p_join_policy: null,
    p_close_after_days: closeAfterDays, p_daily_sms_cap: dailySmsCap,
  });

export const updateGroupSettings = (groupId: string, s: { title?: string; closeAfterDays?: number; dailySmsCap?: number; relayEnabled?: boolean }) =>
  rpc('exos_group_update_settings', {
    p_group_id: groupId, p_title: s.title ?? null, p_close_after_days: s.closeAfterDays ?? null,
    p_daily_sms_cap: s.dailySmsCap ?? null, p_relay_enabled: s.relayEnabled ?? null,
  });

export interface OpenReport { id: string; groupId: string; groupTitle: string; messageId: string; senderName: string; body: string; hidden: boolean; reason: string; createdAt: Date }

/** Open reports with the reported text. Logged as a moderation review. */
export async function openReports(orgId: string): Promise<OpenReport[]> {
  const d = await rpc<any[]>('exos_group_reports_open', { p_org_id: orgId });
  return (d ?? []).map((r) => ({
    id: String(r.id), groupId: String(r.group_id), groupTitle: String(r.group_title ?? ''), messageId: String(r.message_id),
    senderName: String(r.sender_name ?? ''), body: String(r.body ?? ''), hidden: r.hidden === true, reason: String(r.reason ?? ''),
    createdAt: new Date(r.created_at),
  }));
}

export interface ModerationRow { id: string; senderId: string | null; senderName: string; body: string; createdAt: Date; hidden: boolean; reports: number }

/** A group's messages for moderation (hidden included). Needs a reason; logged. */
export async function moderationRead(groupId: string, reason: string): Promise<ModerationRow[]> {
  const d = await rpc<any[]>('exos_group_moderation_read', { p_group_id: groupId, p_reason: reason });
  return (d ?? []).map((m) => ({
    id: String(m.id), senderId: m.sender_id ?? null, senderName: String(m.sender_name ?? ''), body: String(m.body ?? ''),
    createdAt: new Date(m.created_at), hidden: !!m.hidden_at, reports: Number(m.reports) || 0,
  }));
}

export const moderate = (groupId: string, action: string, reason: string, messageId?: string | null, userId?: string | null, hours?: number) =>
  rpc<boolean>('exos_group_moderate', {
    p_group_id: groupId, p_action: action, p_reason: reason, p_message_id: messageId ?? null, p_user_id: userId ?? null, p_hours: hours ?? 24,
  });
