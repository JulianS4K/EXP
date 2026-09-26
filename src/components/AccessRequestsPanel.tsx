// Organizer report: who asked for what (mig 20260926090000). Ticket holders
// set needs on their pass; guest-list needs are set by staff or the list's
// promoter. Hidden when the server doesn't have the feature yet.
import { useEffect, useState } from 'react';
import { Accessibility as AccessIcon, Download } from 'lucide-react';
import { listAccessRequests, type AccessRequest } from '../lib/accessibilityApi';
import { needLabel, ACCESS_NEEDS } from '../lib/accessibility';
import { AccessNeedBadges } from './Accessibility';
import { csvFileName, downloadCsv, toCsv } from '../lib/csv';

export default function AccessRequestsPanel({ eventId, eventTitle }: { eventId: string; eventTitle: string }) {
  const [rows, setRows] = useState<AccessRequest[] | null>(null);
  const [failed, setFailed] = useState(false);

  useEffect(() => {
    let alive = true;
    listAccessRequests(eventId)
      .then((r) => { if (alive) setRows(r); })
      .catch(() => { if (alive) setFailed(true); });
    return () => { alive = false; };
  }, [eventId]);

  if (failed) return null;

  const counts = ACCESS_NEEDS
    .map((n) => ({ id: n.id, n: (rows ?? []).filter((r) => r.needs.includes(n.id)).length }))
    .filter((c) => c.n > 0);

  const exportCsv = () => {
    downloadCsv(
      csvFileName(['access-requests', eventTitle]),
      toCsv(['name', 'from', 'ticket_or_list', 'needs', 'arrived'],
        (rows ?? []).map((r) => [r.name, r.source === 'ticket' ? 'ticket holder' : 'guest list', r.detail,
          r.needs.map(needLabel).join('; '), r.checkedIn ? 'yes' : 'no'])),
    );
  };

  return (
    <section className="bg-white rounded-2xl p-6 shadow-sm mb-6" aria-labelledby="access-requests-h">
      <div className="flex items-start justify-between gap-4 mb-1">
        <h3 id="access-requests-h" className="text-sm font-bold text-slate-700 flex items-center gap-2">
          <AccessIcon size={16} aria-hidden="true" /> Access requests
        </h3>
        {rows && rows.length > 0 && (
          <button type="button" onClick={exportCsv} className="inline-flex items-center gap-1.5 px-3 py-2 border border-slate-200 rounded text-[11px] font-bold uppercase tracking-widest text-slate-600 hover:bg-slate-50">
            <Download size={12} aria-hidden="true" /> CSV
          </button>
        )}
      </div>
      <p className="text-xs text-slate-500 mb-4">
        Needs your guests shared: from their pass, or added to a guest list by you or a promoter. Door staff see them at check-in.
      </p>
      {rows === null ? (
        <p className="text-xs text-slate-400">Loading…</p>
      ) : rows.length === 0 ? (
        <p className="text-xs text-slate-400">No one has asked for anything yet.</p>
      ) : (
        <>
          <p className="text-xs text-slate-600 mb-3">
            {counts.map((c) => `${c.n} × ${needLabel(c.id).toLowerCase()}`).join(' · ')}
          </p>
          <ul className="divide-y divide-slate-100">
            {rows.map((r) => (
              <li key={`${r.source}-${r.refId}`} className="py-3 flex flex-col sm:flex-row sm:items-center gap-2 sm:gap-4">
                <div className="min-w-0 sm:w-56 shrink-0">
                  <p className="text-sm font-bold text-slate-800 truncate">{r.name}</p>
                  <p className="text-[11px] text-slate-500 truncate">{r.source === 'ticket' ? r.detail || 'Ticket' : `Guest list · ${r.detail}`}{r.checkedIn ? ' · arrived' : ''}</p>
                </div>
                <AccessNeedBadges needs={r.needs} />
              </li>
            ))}
          </ul>
        </>
      )}
    </section>
  );
}
