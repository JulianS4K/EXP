// /orgs/:orgId/activity — the org audit log (claude/exos-org-audit, mig
// 20261109100000): who changed inventory, money and access, and every export,
// newest first; filters by event, member, action group and dates; CSV (which
// itself records an export.run). Owner / manager / finance (and platform
// admins); the SQL checks the role, anyone else gets the notice.

import { useCallback, useEffect, useState } from 'react';
import { Link, useParams } from 'react-router-dom';
import { ArrowLeft, Download } from 'lucide-react';
import { useAuth } from '../context/AuthContext';
import { useToast } from '../context/ToastContext';
import { getOrganization, getUserRoleInOrg } from '../lib/orgs';
import { listOrgEvents } from '../lib/financeExtrasApi';
import { csvFileName, downloadCsv } from '../lib/csv';
import {
  actionLabel, actorText, amountLabel, AUDIT_GROUP_NAMES, auditCsv, changeSummary, GROUP_LABEL, sourceLabel,
  type AuditFilters, type AuditGroup, type AuditRow,
} from '../lib/orgAudit';
import { allOrgAudit, listOrgAudit, logExport } from '../lib/orgAuditApi';
import { BTN, FLD, LABEL, Section } from '../components/finance/ui';

const PAGE = 100;

export default function OrgActivity() {
  const { orgId } = useParams();
  const { user, isAdmin } = useAuth();
  const { toast } = useToast();
  const [role, setRole] = useState<string | null | undefined>(undefined);
  const [orgName, setOrgName] = useState('');
  const [events, setEvents] = useState<{ id: string; name: string }[]>([]);
  const [actors, setActors] = useState<{ uid: string; label: string }[]>([]);
  const [filters, setFilters] = useState<AuditFilters>({});
  const [rows, setRows] = useState<AuditRow[]>([]);
  const [next, setNext] = useState<number | null>(null);
  const [loading, setLoading] = useState(false);
  const [busy, setBusy] = useState(false);

  useEffect(() => {
    if (!orgId || !user?.uid) return;
    getOrganization(orgId).then((o) => setOrgName(o?.name ?? '')).catch(() => {});
    getUserRoleInOrg(orgId, user.uid).then(setRole).catch(() => setRole(null));
  }, [orgId, user?.uid]);
  const effectiveRole = isAdmin ? 'owner' : role;
  const canView = effectiveRole === 'owner' || effectiveRole === 'manager' || effectiveRole === 'finance';

  const fail = useCallback((e: unknown) => toast({ kind: 'error', message: (e as Error).message }), [toast]);
  useEffect(() => {
    if (!orgId || !canView) return;
    listOrgEvents(orgId).then(setEvents).catch(() => setEvents([]));
  }, [orgId, canView]);
  const load = useCallback(async () => {
    if (!orgId || !canView) return;
    setLoading(true);
    try {
      const p = await listOrgAudit(orgId, filters, null, PAGE);
      setRows(p.rows); setNext(p.nextBefore);
      if (p.actors.length) setActors(p.actors);
    } catch (e) { fail(e); } finally { setLoading(false); }
  }, [orgId, canView, filters, fail]);
  useEffect(() => { load(); }, [load]);

  if (role === undefined && !isAdmin) return <div className="p-8 text-sm text-slate-500">Loading…</div>;
  if (!canView || !orgId) return <div className="p-8 text-sm text-slate-500">Activity is for owners, managers and finance staff.</div>;

  const more = async () => {
    if (next === null) return;
    setBusy(true);
    try {
      const p = await listOrgAudit(orgId, filters, next, PAGE);
      setRows((r) => [...r, ...p.rows]); setNext(p.nextBefore);
    } catch (e) { fail(e); } finally { setBusy(false); }
  };
  const exportCsv = async () => {
    setBusy(true);
    try {
      const all = await allOrgAudit(orgId, filters);
      downloadCsv(csvFileName(['activity', orgName]), auditCsv(all));
      await logExport(orgId, 'audit', all.length, filters.eventId ?? null);
      toast({ kind: 'success', message: `Exported ${all.length} row${all.length === 1 ? '' : 's'}.` });
    } catch (e) { fail(e); } finally { setBusy(false); }
  };
  const set = (patch: Partial<AuditFilters>) => setFilters((f) => ({ ...f, ...patch }));

  return (
    <div className="max-w-6xl mx-auto px-4 py-8">
      <Link to={`/orgs/${orgId}/settings`} className="inline-flex items-center gap-1 text-xs text-slate-500 hover:text-slate-900 mb-4"><ArrowLeft size={14} /> Settings</Link>
      <h1 className="text-2xl font-black text-slate-900 mb-1">Activity</h1>
      <p className="text-sm text-slate-500 mb-6">
        {orgName} · who changed events, ticket types, codes, holds, money and access, and every export. Rows are never edited
        or deleted. Card numbers, buyer emails and phones are never recorded.
      </p>
      <Section title="Audit log" action={<button className={`${BTN} inline-flex items-center gap-1`} disabled={busy || !rows.length} onClick={exportCsv}>
        <Download size={12} /> Export CSV</button>}>
        <div className="flex flex-wrap gap-2 items-end mb-4">
          <label><span className={LABEL}>Event</span>
            <select className={FLD} value={filters.eventId ?? ''} onChange={(e) => set({ eventId: e.target.value || null })}>
              <option value="">All events</option>
              {events.map((e) => <option key={e.id} value={e.id}>{e.name}</option>)}
            </select></label>
          <label><span className={LABEL}>Who</span>
            <select className={FLD} value={filters.actorUid ?? ''} onChange={(e) => set({ actorUid: e.target.value || null })}>
              <option value="">Anyone</option>
              {actors.map((a) => <option key={a.uid} value={a.uid}>{a.label}</option>)}
            </select></label>
          <label><span className={LABEL}>Kind</span>
            <select className={FLD} value={filters.group ?? ''} onChange={(e) => set({ group: (e.target.value || null) as AuditGroup | null })}>
              <option value="">Everything</option>
              {AUDIT_GROUP_NAMES.map((g) => <option key={g} value={g}>{GROUP_LABEL[g]}</option>)}
            </select></label>
          <label><span className={LABEL}>From</span>
            <input type="date" className={FLD} value={filters.from ?? ''} onChange={(e) => set({ from: e.target.value || null })} /></label>
          <label><span className={LABEL}>To</span>
            <input type="date" className={FLD} value={filters.to ?? ''} onChange={(e) => set({ to: e.target.value || null })} /></label>
        </div>
        <div className="overflow-x-auto">
          <table className="w-full text-sm" aria-label="Audit log">
            <thead>
              <tr className="text-left text-[10px] font-black uppercase tracking-widest text-slate-500 border-b border-slate-200">
                <th scope="col" className="py-2 pr-3">When</th>
                <th scope="col" className="py-2 pr-3">Who</th>
                <th scope="col" className="py-2 pr-3">What</th>
                <th scope="col" className="py-2 pr-3">Details</th>
                <th scope="col" className="py-2 pr-3">From</th>
              </tr>
            </thead>
            <tbody>
              {rows.map((r) => (
                <tr key={r.id} className="border-b border-slate-100 align-top">
                  <td className="py-2 pr-3 whitespace-nowrap text-slate-600">{new Date(r.at).toLocaleString()}</td>
                  <td className="py-2 pr-3">{actorText(r)}</td>
                  <td className="py-2 pr-3">
                    <div className="font-bold text-slate-900">{actionLabel(r.action)}</div>
                    {r.event_name && <div className="text-xs text-slate-500">{r.event_name}</div>}
                  </td>
                  <td className="py-2 pr-3 text-slate-700">
                    {[amountLabel(r.amount_cents, r.currency), changeSummary(r.changes), r.reason ? `“${r.reason}”` : '']
                      .filter(Boolean).join(' · ')}
                  </td>
                  <td className="py-2 pr-3 whitespace-nowrap text-slate-600">{sourceLabel(r.source)}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
        {!loading && rows.length === 0 && <p className="text-sm text-slate-500 py-6">Nothing recorded for these filters.</p>}
        {next !== null && <button className={`${BTN} mt-4`} disabled={busy} onClick={more}>Load older</button>}
      </Section>
    </div>
  );
}
