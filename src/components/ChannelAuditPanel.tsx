// Org settings → "What we'd send" (channel core, mig 20261121162400): while
// a channel's writes are dry runs (the org's switch or the operator's flag
// is off), every write the channel core planned is listed here per channel
// with the exact payload it would have sent (secrets redacted), the limit
// warnings it met, and how much of each platform limit the plans would use.
// Owner / manager (RLS on exos_channel_audit); hidden when there is nothing.

import { useEffect, useState } from 'react';
import { Eye } from 'lucide-react';
import {
  channelLabel, fetchPlannedWrites, fetchUsageSummary, groupPlanned, payloadText, usageMeters,
  type ChannelAuditRow, type UsageSummaryRow,
} from '../lib/channelAudit';

function when(iso: string): string {
  const d = new Date(iso);
  return Number.isNaN(d.getTime()) ? iso : d.toLocaleString();
}

const ERROR_TEXT: Record<string, string> = {
  LIMIT_BLOCKED: 'Not planned: a platform rule refuses it',
  LIMIT_CAPPED: 'Not planned: over what the platform allows right now',
  NOT_ALLOWED: 'Refused: not a write Exos makes',
};

export default function ChannelAuditPanel({ orgId }: { orgId: string }) {
  const [rows, setRows] = useState<ChannelAuditRow[] | null>(null);
  const [usage, setUsage] = useState<UsageSummaryRow[]>([]);
  const [open, setOpen] = useState<string | null>(null);

  useEffect(() => {
    let alive = true;
    setRows(null);
    fetchPlannedWrites(orgId)
      .then((r) => { if (alive) setRows(r); })
      .catch((err) => { console.warn('channel audit unavailable', err); if (alive) setRows([]); });
    fetchUsageSummary(orgId)
      .then((u) => { if (alive) setUsage(u); })
      .catch(() => { if (alive) setUsage([]); });
    return () => { alive = false; };
  }, [orgId]);

  const groups = groupPlanned(rows ?? []);
  const meters = usageMeters(usage).filter((m) => m.planned > 0 || m.live > 0);
  if (!rows || (!groups.length && !meters.length)) return null;

  return (
    <section data-testid="channel-audit-panel" aria-labelledby="channel-audit-title"
      className="bg-white rounded-2xl border border-slate-200 shadow-sm p-6 md:p-8 space-y-5">
      <div className="flex items-center gap-2">
        <Eye className="w-4 h-4 text-slate-500" aria-hidden="true" />
        <h2 id="channel-audit-title" className="text-sm font-black text-slate-900 uppercase tracking-widest">What we&apos;d send</h2>
      </div>
      <p className="text-xs text-slate-600">
        Sending to these platforms is switched off, so nothing below was sent. This is what Exos would send once it is
        switched on (your switch and the operator&apos;s), with secrets hidden.
      </p>

      {meters.length > 0 && (
        <ul aria-label="Platform limits" className="space-y-1">
          {meters.map((m) => (
            <li key={`${m.ruleId}:${m.scope}`} className="text-[11px] text-slate-700">
              <span className="font-bold">{channelLabel(m.platform)}{m.scope ? ` (${m.scope})` : ''}:</span> {m.line}
            </li>
          ))}
        </ul>
      )}

      {groups.map((g) => (
        <div key={g.channel} className="space-y-2">
          <h3 className="text-xs font-black text-slate-700 uppercase tracking-widest">{g.label}</h3>
          <ul className="space-y-2">
            {g.rows.map((r) => {
              const id = `channel-audit-${r.id}`;
              return (
                <li key={r.id} data-testid="planned-write" className="border border-slate-200 rounded-lg p-3 space-y-1">
                  <div className="flex flex-wrap items-center gap-2 text-[11px]">
                    <span className="font-mono font-bold text-slate-900">{r.method}</span>
                    <span className="font-mono text-slate-700 break-all">{r.path}</span>
                    <span className="text-slate-500">{r.op}</span>
                    <span className="text-slate-500 ml-auto">{when(r.at)}</span>
                  </div>
                  {r.error && <p className="text-[11px] text-rose-800">{ERROR_TEXT[r.error] ?? r.error}</p>}
                  {(r.warnings ?? []).map((w, i) => (
                    <p key={i} role="note" className={`text-[11px] rounded px-2 py-1 ${w.action === 'block' ? 'text-rose-800 bg-rose-50' : 'text-amber-800 bg-amber-50'}`}>
                      {w.reason}
                    </p>
                  ))}
                  <button type="button" className="text-[11px] font-bold text-slate-700 underline"
                    aria-expanded={open === r.id} aria-controls={id}
                    onClick={() => setOpen(open === r.id ? null : r.id)}>
                    {open === r.id ? 'Hide the payload' : 'Show the payload'}
                  </button>
                  {open === r.id && (
                    <pre id={id} className="text-[10px] bg-slate-50 border border-slate-200 rounded p-2 overflow-x-auto whitespace-pre-wrap break-all">
                      {payloadText(r)}
                    </pre>
                  )}
                </li>
              );
            })}
          </ul>
        </div>
      ))}
    </section>
  );
}
