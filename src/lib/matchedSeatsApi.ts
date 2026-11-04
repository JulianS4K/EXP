// RPC wrappers for matched seats (mig 20261031210000, docs/matched-seats.md).
// Staff go through exos_match_* (owner / manager checked in SQL); holders
// through exos_match_my_group & co.; "Match now" through the exos-match edge
// function. Nothing about a group's spot is readable before reveal time.

import { supabase } from './supabase';
import type { MatchConfig } from './matchedSeats';

// The edge function answers 403 / 409 with { error }; surface it.
async function invokeMatch(body: Record<string, unknown>): Promise<any> {
  const { data, error } = await supabase.functions.invoke('exos-match', { body });
  if (error) {
    let payload: any = null;
    try {
      payload = await (error as { context?: Response }).context?.json();
    } catch {
      payload = null;
    }
    throw new Error(payload?.error || error.message || 'Matching failed.');
  }
  return data;
}

function rpcError(error: { message?: string; code?: string }): Error {
  const e = new Error(String(error.message ?? 'Request failed').replace(/^exos_match_\w+: /, ''));
  (e as any).code = error.code;
  return e;
}

async function rpc<T = any>(fn: string, args: Record<string, unknown>): Promise<T> {
  const { data, error } = await supabase.rpc(fn, args);
  if (error) throw rpcError(error);
  return data as T;
}

// ---------------------------------------------------------------------------
// Public (event page)
// ---------------------------------------------------------------------------
export interface PublicMatchedTier {
  tierId: string;
  groupMin: number;
  groupTarget: number;
  groupMax: number;
  quizEnabled: boolean;
  quizTags: string[];
  quizLanguages: string[];
  matchAt: number | null;
  revealAt: number | null;
  spotCount: number;
  status: string;
}

let missing = false;   // migration not on this database: stop asking
export async function getPublicMatchedTiers(eventId: string): Promise<PublicMatchedTier[]> {
  if (missing) return [];
  const { data, error } = await supabase.rpc('exos_match_public', { p_event_id: eventId });
  if (error) {
    if (error.code === 'PGRST202' || error.code === '42883') missing = true;
    return [];
  }
  return ((data as any[]) ?? []).map((r) => ({
    tierId: r.tier_id,
    groupMin: r.group_min, groupTarget: r.group_target, groupMax: r.group_max,
    quizEnabled: !!r.quiz_enabled, quizTags: r.quiz_tags ?? [], quizLanguages: r.quiz_languages ?? [],
    matchAt: r.match_at ? Date.parse(r.match_at) : null,
    revealAt: r.reveal_at ? Date.parse(r.reveal_at) : null,
    spotCount: Number(r.spot_count) || 0,
    status: r.status,
  }));
}

// ---------------------------------------------------------------------------
// Holders
// ---------------------------------------------------------------------------
export const saveIntake = (tierId: string, answers: Record<string, unknown>) =>
  rpc('exos_match_save_intake', { p_tier_id: tierId, p_answers: answers });
export const setTicketAnswers = (ticketId: string, answers: Record<string, unknown>) =>
  rpc('exos_match_set_answers', { p_ticket_id: ticketId, p_answers: answers });
export const clearTicketAnswers = (ticketId: string) =>
  rpc('exos_match_clear_answers', { p_ticket_id: ticketId });

export interface GroupMember { id: string; firstName: string; isMe: boolean; picked: boolean; mutual: boolean }
export type MyGroup =
  | { state: 'not_matched' | 'not_holder' | 'removed' }
  | { state: 'waiting'; matchAt: number | null; revealAt: number | null; quizEnabled: boolean;
      quizTags: string[]; quizLanguages: string[]; answers: any }
  | { state: 'leftover'; reason: string; policy: string }
  | { state: 'matched'; revealAt: number | null; groupSize: number }
  | { state: 'revealed'; me: string; meetAt: number | null; afterEvent: boolean;
      spot: { name: string; address: string | null; details: string | null } | null; members: GroupMember[] };

let groupMissing = false;
export async function getMyGroup(ticketId: string): Promise<MyGroup> {
  if (groupMissing) return { state: 'not_matched' };
  const { data, error } = await supabase.rpc('exos_match_my_group', { p_ticket_id: ticketId });
  if (error) {
    if (error.code === 'PGRST202' || error.code === '42883') groupMissing = true;
    return { state: 'not_matched' };
  }
  const r = (data ?? {}) as any;
  const ms = (x: unknown) => (x ? Date.parse(String(x)) : null);
  switch (r.state) {
    case 'waiting':
      return { state: 'waiting', matchAt: ms(r.match_at), revealAt: ms(r.reveal_at), quizEnabled: !!r.quiz_enabled,
        quizTags: r.quiz_tags ?? [], quizLanguages: r.quiz_languages ?? [], answers: r.answers ?? null };
    case 'leftover':
      return { state: 'leftover', reason: r.reason, policy: r.policy };
    case 'matched':
      return { state: 'matched', revealAt: ms(r.reveal_at), groupSize: Number(r.group_size) || 0 };
    case 'revealed':
      return {
        state: 'revealed', me: r.me, meetAt: ms(r.meet_at), afterEvent: !!r.after_event,
        spot: r.spot ? { name: r.spot.name, address: r.spot.address ?? null, details: r.spot.details ?? null } : null,
        members: ((r.members as any[]) ?? []).map((m) => ({
          id: m.id, firstName: m.first_name, isMe: !!m.is_me, picked: !!m.picked, mutual: !!m.mutual,
        })),
      };
    case 'not_holder': case 'removed':
      return { state: r.state };
    default:
      return { state: 'not_matched' };
  }
}

export const pickMember = (ticketId: string, memberId: string, on: boolean) =>
  rpc<boolean>('exos_match_pick', { p_ticket_id: ticketId, p_member_id: memberId, p_on: on });
export const reportMember = (ticketId: string, memberId: string, reason: string, details: string) =>
  rpc('exos_match_report', { p_ticket_id: ticketId, p_member_id: memberId, p_reason: reason, p_details: details || null });
export const blockMember = (ticketId: string, memberId: string) =>
  rpc('exos_match_block', { p_ticket_id: ticketId, p_member_id: memberId });

// ---------------------------------------------------------------------------
// Staff
// ---------------------------------------------------------------------------
export interface StaffMember {
  id: string; ticketId: string; status: string; firstName: string; orderRef: string | null;
  removedReason: string | null; ageBand: string | null; language: string | null; tags: string[]; partyCode: string | null;
}
export interface StaffGroup {
  id: string; label: string; status: string; spotId: string | null; meetAt: number | null;
  score: number | null; members: StaffMember[];
}
export interface StaffSpot {
  id: string; name: string; address: string | null; details: string | null; meetAt: string | null;
  capacity: number; sortOrder: number; active: boolean;
}
export interface StaffLeftover {
  ticketId: string; reason: string; status: string; pricePaid: number; sessionId: string | null; firstName: string;
}
export interface StaffReport {
  id: string; groupId: string | null; memberId: string | null; reason: string; details: string | null;
  status: string; createdAt: number; memberFirstName: string | null;
}
export interface StaffView {
  config: MatchConfig & { matchAt: number | null; revealAt: number | null; seed: number | null };
  holders: number; answered: number;
  spots: StaffSpot[]; groups: StaffGroup[]; leftovers: StaffLeftover[]; reports: StaffReport[];
}

export async function getStaffView(tierId: string): Promise<StaffView> {
  const v = await rpc<any>('exos_match_staff_view', { p_tier_id: tierId });
  const c = v.config ?? {};
  return {
    config: {
      tierId: c.tier_id, groupMin: c.group_min, groupTarget: c.group_target, groupMax: c.group_max,
      groupCount: c.group_count ?? null, matchHoursBefore: c.match_hours_before, revealHoursBefore: c.reveal_hours_before,
      undersubPolicy: c.undersub_policy, quizEnabled: !!c.quiz_enabled, quizTags: c.quiz_tags ?? [],
      quizLanguages: c.quiz_languages ?? [], retentionDays: c.retention_days, status: c.status,
      matchAt: c.match_at ? Date.parse(c.match_at) : null, revealAt: c.reveal_at ? Date.parse(c.reveal_at) : null,
      seed: c.seed ?? null,
    },
    holders: Number(v.holders) || 0,
    answered: Number(v.answered) || 0,
    spots: ((v.spots as any[]) ?? []).map((s) => ({
      id: s.id, name: s.name, address: s.address ?? null, details: s.details ?? null, meetAt: s.meet_at ?? null,
      capacity: s.capacity, sortOrder: s.sort_order, active: !!s.active,
    })),
    groups: ((v.groups as any[]) ?? []).map((g) => ({
      id: g.id, label: g.label, status: g.status, spotId: g.spot_id ?? null,
      meetAt: g.meet_at ? Date.parse(g.meet_at) : null, score: g.score == null ? null : Number(g.score),
      members: ((g.members as any[]) ?? []).map((m) => ({
        id: m.id, ticketId: m.ticket_id, status: m.status, firstName: m.first_name, orderRef: m.order_ref ?? null,
        removedReason: m.removed_reason ?? null, ageBand: m.age_band ?? null, language: m.language ?? null,
        tags: m.tags ?? [], partyCode: m.party_code ?? null,
      })),
    })),
    leftovers: ((v.leftovers as any[]) ?? []).map((l) => ({
      ticketId: l.ticket_id, reason: l.reason, status: l.status, pricePaid: Number(l.price_paid) || 0,
      sessionId: l.session_id ?? null, firstName: l.first_name,
    })),
    reports: ((v.reports as any[]) ?? []).map((r) => ({
      id: r.id, groupId: r.group_id ?? null, memberId: r.member_id ?? null, reason: r.reason, details: r.details ?? null,
      status: r.status, createdAt: Date.parse(r.created_at), memberFirstName: r.member_first_name ?? null,
    })),
  };
}

/** null when the tier isn't matched (the RPC refuses with 42501 then). */
export async function getStaffViewOrNull(tierId: string): Promise<StaffView | null> {
  try {
    return await getStaffView(tierId);
  } catch (e: any) {
    if (e?.code === '42501' || e?.code === 'PGRST202' || e?.code === '42883') return null;
    throw e;
  }
}

export const setMatchConfig = (tierId: string, body: Record<string, unknown>) =>
  rpc('exos_match_set_config', { p_tier_id: tierId, p_config: body });
export const upsertSpot = (tierId: string, spot: Record<string, unknown>) =>
  rpc<string>('exos_match_upsert_spot', { p_tier_id: tierId, p_spot: spot });
export const deleteSpot = (spotId: string) => rpc('exos_match_delete_spot', { p_spot_id: spotId });
export const moveMember = (groupId: string, memberId: string) =>
  rpc('exos_match_move', { p_group_id: groupId, p_member_id: memberId, p_ticket_id: null });
export const placeLeftover = (groupId: string, ticketId: string) =>
  rpc('exos_match_move', { p_group_id: groupId, p_member_id: null, p_ticket_id: ticketId });
export const swapMembers = (a: string, b: string) => rpc('exos_match_swap', { p_member_a: a, p_member_b: b });
export const removeMember = (memberId: string, reason: string, block: boolean) =>
  rpc('exos_match_remove_member', { p_member_id: memberId, p_reason: reason || null, p_block: block });
export const lockGroups = (tierId: string, locked: boolean) =>
  rpc<number>('exos_match_lock', { p_tier_id: tierId, p_locked: locked });
export const revealNow = (tierId: string) => rpc<number>('exos_match_reveal_now', { p_tier_id: tierId });
export const reviewReport = (reportId: string, status: string) =>
  rpc('exos_match_review_report', { p_report_id: reportId, p_status: status });

export async function matchNow(tierId: string, reshuffle = false):
  Promise<{ groups: number; placed: number; leftovers: number; seed: number; warnings: string[] }> {
  const r = await invokeMatch({ tier_id: tierId, reshuffle });
  return { groups: Number(r.groups) || 0, placed: Number(r.placed) || 0, leftovers: Number(r.leftovers) || 0,
    seed: Number(r.seed) || 0, warnings: Array.isArray(r.warnings) ? r.warnings : [] };
}
