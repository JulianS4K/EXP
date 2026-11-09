// Owner approval for staff invites (mig 20261104200000). Pure: the wording
// and checks the Members page and the invite page use. The rule itself is
// the SQL (exos_org_member_approve / _reject, _exos_member_decider).

import type { OrgRole } from '../types';

/** A claimed invite waiting for approval (exos_org_pending_members). */
export interface PendingMember {
  user_id: string;
  account_email: string | null;
  invited_email: string | null;
  role: OrgRole;
  current_role: OrgRole | null;
  new_member: boolean;
  email_matches: boolean | null;
  invited_by_email: string | null;
  invited_at: string | null;
  claimed_at: string | null;
  can_decide: boolean;
}

/** Roles a manager may approve; owners approve any. Mirrors _exos_member_decider. */
export const MANAGER_APPROVABLE: readonly OrgRole[] = ['finance', 'scanner', 'content'];

export function canDecide(viewer: OrgRole | null | undefined, requested: OrgRole, self = false): boolean {
  if (self || !viewer) return false;
  if (viewer === 'owner') return true;
  return viewer === 'manager' && MANAGER_APPROVABLE.includes(requested);
}

/** "sam@x.com accepted your invite as manager". */
export function pendingHeadline(p: Pick<PendingMember, 'account_email' | 'role' | 'current_role'>): string {
  const who = p.account_email ?? 'Someone';
  return p.current_role
    ? `${who} (already ${p.current_role}) accepted an invite as ${p.role}`
    : `${who} accepted your invite as ${p.role}`;
}

/** Edit distance, capped (only small distances matter here). */
function distance(a: string, b: string, cap = 3): number {
  if (Math.abs(a.length - b.length) > cap) return cap + 1;
  let prev = Array.from({ length: b.length + 1 }, (_, j) => j);
  for (let i = 1; i <= a.length; i++) {
    const cur = [i];
    for (let j = 1; j <= b.length; j++) {
      cur[j] = Math.min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] === b[j - 1] ? 0 : 1));
    }
    prev = cur;
  }
  return prev[b.length];
}

/**
 * How the claimer's account email compares with the address the invite went
 * to: 'match', 'typo' (one or two characters apart: the invite was probably
 * mistyped and reached someone else), or 'different' (another address: a
 * forwarded link, or a personal account).
 */
export function emailComparison(invited: string | null, account: string | null): 'match' | 'typo' | 'different' | 'unknown' {
  if (!invited || !account) return 'unknown';
  const a = invited.trim().toLowerCase();
  const b = account.trim().toLowerCase();
  if (a === b) return 'match';
  return distance(a, b) <= 2 ? 'typo' : 'different';
}

/** The invite page after a claim: the membership row the claimer can read. */
export function claimOutcome(row: { status?: string | null; pending_role?: string | null; disabled?: boolean | null } | null):
  'joined' | 'waiting' | 'unchanged' {
  if (!row) return 'unchanged';
  if (row.status === 'pending_approval' || row.pending_role) return 'waiting';
  return row.disabled ? 'unchanged' : 'joined';
}
