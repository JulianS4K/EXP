// Members → Waiting for approval (mig 20261104200000). With the org's
// "approve new members" switch on, a claimed invite leaves the person with no
// access until an owner (or a manager, for finance / content / scanner)
// approves. Each request shows the account that claimed it next to the
// address the invite was sent to, so a mistyped invite stands out. Hidden for
// other roles and before the migration.

import { useCallback, useEffect, useState } from 'react';
import { ShieldCheck, Check, X, AlertTriangle } from 'lucide-react';
import { useToast } from '../context/ToastContext';
import type { OrgRole } from '../types';
import { emailComparison, pendingHeadline, type PendingMember } from '../lib/inviteApproval';
import {
  approveMember, getInviteApproval, listPendingMembers, rejectMember, setInviteApproval,
} from '../lib/inviteApprovalApi';

export default function PendingApprovalsPanel({ orgId, viewerRole, onChange }: {
  orgId: string; viewerRole: OrgRole | null; onChange?: () => void;
}) {
  const { toast } = useToast();
  const [pending, setPending] = useState<PendingMember[] | null>(null);
  const [on, setOn] = useState<boolean | null>(null);
  const [busy, setBusy] = useState<string | null>(null);
  const isOwner = viewerRole === 'owner';

  const load = useCallback(() => {
    void listPendingMembers(orgId).then(setPending);
    void getInviteApproval(orgId).then(setOn);
  }, [orgId]);
  useEffect(load, [load]);

  if (pending === null && on === null) return null;

  const decide = async (p: PendingMember, approve: boolean) => {
    setBusy(p.user_id);
    try {
      if (approve) {
        await approveMember(orgId, p.user_id);
        toast({ kind: 'success', message: `${p.account_email ?? 'Member'} approved as ${p.role}.` });
      } else {
        const r = await rejectMember(orgId, p.user_id);
        toast({ kind: 'success', message: r.removed ? 'Rejected and removed.' : 'Rejected; they keep their current role.' });
      }
      load();
      onChange?.();
    } catch (e) {
      toast({ kind: 'error', message: e instanceof Error ? e.message : 'Could not update' });
    } finally {
      setBusy(null);
    }
  };

  const toggle = async () => {
    if (on === null) return;
    try {
      await setInviteApproval(orgId, !on);
      setOn(!on);
    } catch (e) {
      toast({ kind: 'error', message: e instanceof Error ? e.message : 'Could not update' });
    }
  };

  return (
    <div className="bg-white rounded-2xl border border-slate-200 shadow-sm p-6 mb-6">
      <div className="flex flex-wrap items-center justify-between gap-3 mb-3">
        <p className="text-[10px] font-black text-slate-400 uppercase tracking-widest flex items-center gap-2">
          <ShieldCheck size={14} /> Approve new members
        </p>
        {on !== null && (
          <label className={`flex items-center gap-2 text-xs font-bold ${isOwner ? 'text-slate-700' : 'text-slate-400'}`}>
            <input type="checkbox" checked={on} disabled={!isOwner} onChange={toggle} />
            Accepted invites wait for approval
          </label>
        )}
      </div>
      {on === false && (
        <p className="text-xs text-slate-500 mb-3">Off: whoever accepts an invite link joins at once, and you're emailed who it was.</p>
      )}
      {pending && pending.length === 0 && (
        <p className="text-xs text-slate-400">Nobody is waiting.</p>
      )}
      <ul className="space-y-3">
        {(pending ?? []).map((p) => {
          const cmp = emailComparison(p.invited_email, p.account_email);
          return (
            <li key={p.user_id} className="border border-slate-200 rounded-lg p-4 flex flex-col md:flex-row md:items-center gap-3">
              <div className="flex-1 min-w-0">
                <p className="font-bold text-sm text-slate-900 break-all">{pendingHeadline(p)}</p>
                <p className="text-[11px] text-slate-500 mt-1 break-all">
                  Account email: <span className="font-mono">{p.account_email ?? 'unknown'}</span>
                  {p.invited_email && <> · invite sent to <span className="font-mono">{p.invited_email}</span></>}
                </p>
                {cmp !== 'match' && cmp !== 'unknown' && (
                  <p className="text-[11px] font-bold text-amber-700 mt-1 flex items-center gap-1">
                    <AlertTriangle size={12} />
                    {cmp === 'typo'
                      ? 'Almost the address you invited: check for a typo before approving.'
                      : 'Not the address you invited: make sure you know this account.'}
                  </p>
                )}
                {!p.new_member && (
                  <p className="text-[11px] text-slate-500 mt-1">They keep their current access until you decide.</p>
                )}
              </div>
              {p.can_decide ? (
                <div className="flex gap-2 shrink-0">
                  <button type="button" disabled={busy === p.user_id} onClick={() => decide(p, true)}
                    className="inline-flex items-center gap-1 bg-tm-blue text-white px-4 py-2 rounded text-xs font-bold disabled:opacity-50">
                    <Check size={13} /> Approve
                  </button>
                  <button type="button" disabled={busy === p.user_id} onClick={() => decide(p, false)}
                    className="inline-flex items-center gap-1 border border-slate-200 text-slate-600 hover:text-rose-600 hover:border-rose-300 px-4 py-2 rounded text-xs font-bold disabled:opacity-50">
                    <X size={13} /> Reject
                  </button>
                </div>
              ) : (
                <span className="text-[11px] text-slate-400 shrink-0">An owner approves {p.role}s</span>
              )}
            </li>
          );
        })}
      </ul>
    </div>
  );
}
