// /orgs/:orgId/flags — the org's "Limit flags" tab (mig 20260926194000).
//
// Exos accounts holding more of an event's tickets than its max per account,
// usually from several marketplace orders (a marketplace can't enforce the
// limit, so Exos flags instead of blocking). The flag is on the account, once
// it holds the tickets; a sale alone never raises one. Owners and managers
// mark flags reviewed with a note; promoters whose links sold the tickets can
// leave a note from their portal.

import { useEffect, useMemo, useState } from 'react';
import { useNavigate, useParams } from 'react-router-dom';
import { ArrowLeft, Flag } from 'lucide-react';
import { useAuth } from '../context/AuthContext';
import { useToast } from '../context/ToastContext';
import { getUserRoleInOrg } from '../lib/orgs';
import { getOrgLimitFlags, reviewAccountLimitFlag, type AccountLimitFlag } from '../lib/marketplace/linksApi';

function when(iso: string | null | undefined): string {
  if (!iso) return '';
  const d = new Date(iso);
  return Number.isNaN(d.getTime()) ? '' : d.toLocaleDateString(undefined, { dateStyle: 'medium' });
}

export default function OrgLimitFlags() {
  const { orgId } = useParams();
  const navigate = useNavigate();
  const { user } = useAuth();
  const { toast } = useToast();
  const [flags, setFlags] = useState<AccountLimitFlag[] | null>(null);
  const [canReview, setCanReview] = useState(false);
  const [showReviewed, setShowReviewed] = useState(false);
  const [busy, setBusy] = useState<string | null>(null);

  const load = () => {
    if (!orgId) return;
    getOrgLimitFlags(orgId).then(setFlags).catch(() => setFlags([]));
  };
  useEffect(() => {
    if (!orgId) return;
    getOrgLimitFlags(orgId).then(setFlags).catch(() => setFlags([]));
    if (user?.uid) getUserRoleInOrg(orgId, user.uid).then((r) => setCanReview(r === 'owner' || r === 'manager')).catch(() => setCanReview(false));
  }, [orgId, user?.uid]);

  const open = useMemo(() => (flags ?? []).filter((f) => !f.reviewed_at), [flags]);
  const shown = showReviewed ? flags ?? [] : open;

  const review = async (f: AccountLimitFlag) => {
    const note = window.prompt(`Note on ${f.email ?? 'this account'} (optional)`, f.review_note ?? '');
    if (note === null) return;
    setBusy(f.id);
    try {
      await reviewAccountLimitFlag(f.id, note);
      load();
    } catch (err) {
      toast({ kind: 'error', message: err instanceof Error ? err.message : 'Could not save that.' });
    } finally {
      setBusy(null);
    }
  };

  if (!user) {
    return <div className="min-h-screen bg-tm-gray text-slate-500 text-center py-24 font-bold uppercase tracking-widest">Sign in required.</div>;
  }

  return (
    <div className="min-h-screen bg-tm-gray text-slate-900">
      <div className="max-w-5xl mx-auto px-4 py-10">
        <button onClick={() => navigate('/orgs')}
          className="flex items-center gap-1.5 text-slate-500 hover:text-slate-900 text-[10px] font-black uppercase tracking-widest mb-6 transition-colors">
          <ArrowLeft size={14} strokeWidth={2.5} /> All organizations
        </button>
        <div className="mb-8">
          <p className="text-[10px] font-black text-slate-400 uppercase tracking-widest mb-2">Review</p>
          <h1 className="text-3xl md:text-4xl font-bold tracking-tight">Limit flags</h1>
        </div>

        <div className="flex gap-6 border-b border-slate-200 mb-8">
          <button onClick={() => orgId && navigate(`/orgs/${orgId}/settings`)} className="pb-3 text-sm font-bold text-slate-400 hover:text-slate-600 transition-colors">General</button>
          <button onClick={() => orgId && navigate(`/orgs/${orgId}/members`)} className="pb-3 text-sm font-bold text-slate-400 hover:text-slate-600 transition-colors">Members</button>
          <button className="pb-3 text-sm font-bold text-slate-900 border-b-2 border-tm-blue -mb-px">Limit flags{open.length ? ` (${open.length})` : ''}</button>
          <span className="pb-3 text-sm font-bold text-slate-300 cursor-default">Billing</span>
        </div>

        <p className="text-sm text-slate-600 mb-6 max-w-prose">
          Accounts holding more tickets to one of your events than its max per account. This usually means several
          marketplace orders by one person, since marketplaces can't enforce your limit. Nothing was blocked: decide
          whether to act (contact them, void extras), then mark it reviewed.
        </p>

        <label className="flex items-center gap-2 text-xs font-bold text-slate-500 mb-4">
          <input type="checkbox" checked={showReviewed} onChange={(e) => setShowReviewed(e.target.checked)} /> Show reviewed
        </label>

        {flags === null ? (
          <p className="text-slate-400 text-sm">Loading…</p>
        ) : shown.length === 0 ? (
          <div className="bg-white rounded-2xl border border-slate-200 p-8 text-center text-slate-500 text-sm">
            <Flag className="w-5 h-5 mx-auto mb-2 text-slate-300" />
            {open.length === 0 ? 'No account is over its limit.' : 'Nothing here.'}
          </div>
        ) : (
          <ul className="space-y-3">
            {shown.map((f) => (
              <li key={f.id} className={`bg-white rounded-2xl border p-5 ${f.reviewed_at ? 'border-slate-200 opacity-70' : 'border-amber-300'}`}>
                <div className="flex flex-wrap items-start justify-between gap-3">
                  <div className="text-sm">
                    <p className="font-bold">{f.email ?? 'Account'}</p>
                    <p className="text-slate-600">
                      {f.exos_events?.name ?? 'Event'}{f.exos_events?.starts_at ? ` · ${when(f.exos_events.starts_at)}` : ''}
                    </p>
                    <p className="text-slate-600">
                      Holds <strong>{f.held}</strong> (limit {f.max_per_account}{f.peak > f.held ? `, most ${f.peak}` : ''}) · flagged {when(f.first_flagged_at)}
                    </p>
                    {f.promoter_codes.length > 0 && <p className="text-slate-500">Sold through: {f.promoter_codes.join(', ')}</p>}
                    {f.promoter_note && <p className="text-slate-700 mt-1">Promoter {f.promoter_noted_by}: “{f.promoter_note}”</p>}
                    {f.reviewed_at && <p className="text-slate-500 mt-1">Reviewed {when(f.reviewed_at)}{f.review_note ? `: ${f.review_note}` : ''}</p>}
                  </div>
                  {!f.reviewed_at && canReview && (
                    <button type="button" disabled={busy === f.id} onClick={() => review(f)}
                      className="px-4 py-2 rounded bg-slate-900 text-white text-xs font-bold disabled:opacity-50">
                      Mark reviewed
                    </button>
                  )}
                </div>
              </li>
            ))}
          </ul>
        )}
      </div>
    </div>
  );
}
