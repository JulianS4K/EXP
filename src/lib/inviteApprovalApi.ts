// Owner approval for staff invites (mig 20261104200000): the signed-in RPCs
// behind Members → "Waiting for approval" and the org switch. The SQL checks
// the role (owner; manager for roles below manager).

import { supabase } from './supabase';
import type { PendingMember } from './inviteApproval';

/** Requests waiting in an org; null when the RPC isn't there or the role can't see it. */
export async function listPendingMembers(orgId: string): Promise<PendingMember[] | null> {
  const { data, error } = await supabase.rpc('exos_org_pending_members', { p_org_id: orgId });
  if (error) return null;
  return (data ?? []) as PendingMember[];
}

export async function approveMember(orgId: string, userId: string): Promise<void> {
  const { error } = await supabase.rpc('exos_org_member_approve', { p_org_id: orgId, p_user_id: userId });
  if (error) throw error;
}

export async function rejectMember(orgId: string, userId: string): Promise<{ removed: boolean }> {
  const { data, error } = await supabase.rpc('exos_org_member_reject', { p_org_id: orgId, p_user_id: userId });
  if (error) throw error;
  return { removed: Boolean((data as { removed?: boolean } | null)?.removed) };
}

/** The org's switch; null when the column isn't there yet. */
export async function getInviteApproval(orgId: string): Promise<boolean | null> {
  const { data, error } = await supabase.from('exos_orgs').select('invite_approval').eq('id', orgId).maybeSingle();
  if (error || !data) return null;
  return Boolean((data as { invite_approval?: boolean }).invite_approval);
}

export async function setInviteApproval(orgId: string, on: boolean): Promise<void> {
  const { error } = await supabase.rpc('exos_set_invite_approval', { p_org_id: orgId, p_on: on });
  if (error) throw error;
}

/** The caller's own membership (RLS lets a user read their own row). */
export async function myMembership(orgId: string, uid: string) {
  const { data, error } = await supabase.from('exos_org_memberships')
    .select('status, pending_role, disabled, role').eq('org_id', orgId).eq('user_id', uid).maybeSingle();
  if (error) return null;
  return data as { status?: string; pending_role?: string | null; disabled?: boolean; role?: string } | null;
}
