// TableAssignmentsPanel — sold tables for one event (mig 20260926050000).
// Owner / manager give each booking its table number ("Table 12"); the door
// then sees that label and the minimum spend on every ticket of the party.
// Finance sees the list read-only. Free tables can be cancelled whole here;
// a paid table is refunded from the attendee list instead.

import { useCallback, useEffect, useState } from 'react';
import { Armchair, RefreshCw } from 'lucide-react';
import { assignTable, cancelTableBooking, listEventTables, type EventTable } from '../lib/tablesApi';
import { formatCents, labelTaken, normalizeTableLabel, suggestNextLabel } from '../lib/tables';
import { useToast } from '../context/ToastContext';
import type { Event } from '../types';

export default function TableAssignmentsPanel({
  event,
  canManage,
}: {
  event: Event;
  /** owner / manager: may label and cancel. Others see the list read-only. */
  canManage: boolean;
}) {
  const { toast } = useToast();
  const [rows, setRows] = useState<EventTable[] | null>(null);
  const [drafts, setDrafts] = useState<Record<string, string>>({});
  const [busy, setBusy] = useState<string | null>(null);
  const [denied, setDenied] = useState(false);
  const currency = event.currency || 'USD';

  const load = useCallback(async () => {
    try {
      const r = await listEventTables(event.id);
      setRows(r);
      setDrafts(Object.fromEntries(r.map((t) => [t.bookingId, t.label ?? ''])));
    } catch (err: any) {
      if (err?.code === '42501') setDenied(true);
      else console.error('exos_event_tables failed:', err);
      setRows([]);
    }
  }, [event.id]);

  useEffect(() => {
    void load();
  }, [load]);

  if (denied) return null;
  if (rows && rows.length === 0) return null; // no table tiers sold yet

  const active = (rows ?? []).filter((t) => t.status === 'active');
  const unassigned = active.filter((t) => !t.label).length;

  const save = async (t: EventTable) => {
    let label: string | null;
    try {
      label = normalizeTableLabel(drafts[t.bookingId] ?? '');
    } catch (e: any) {
      toast({ kind: 'error', message: e.message });
      return;
    }
    if (label && labelTaken(label, active.filter((o) => o.bookingId !== t.bookingId).map((o) => o.label))) {
      toast({ kind: 'error', message: `${label} is already assigned.` });
      return;
    }
    setBusy(t.bookingId);
    try {
      await assignTable(t.bookingId, label);
      toast({ kind: 'success', message: label ? `Assigned ${label}.` : 'Table cleared.' });
      await load();
    } catch (err: any) {
      toast({ kind: 'error', message: err?.message?.replace(/^exos_assign_table: /, '') || 'Could not assign the table.' });
    } finally {
      setBusy(null);
    }
  };

  const cancel = async (t: EventTable) => {
    if (!window.confirm(`Cancel this table? Its ${t.tickets} ticket(s) stop working and the table goes back on sale.`)) return;
    setBusy(t.bookingId);
    try {
      const n = await cancelTableBooking(t.bookingId);
      toast({ kind: 'success', message: `Table cancelled, ${n} ticket(s) voided.` });
      await load();
    } catch (err: any) {
      toast({ kind: 'error', message: err?.message?.replace(/^exos_cancel_table_booking: /, '') || 'Could not cancel the table.' });
    } finally {
      setBusy(null);
    }
  };

  return (
    <div className="bg-white rounded-2xl p-6 shadow-sm mb-6">
      <div className="flex items-center justify-between gap-2 mb-1">
        <div className="flex items-center gap-2">
          <Armchair className="w-4 h-4 text-slate-500" />
          <h3 className="text-sm font-bold text-slate-700">Tables</h3>
        </div>
        <button
          type="button"
          onClick={() => void load()}
          className="text-slate-400 hover:text-slate-700"
          aria-label="Refresh tables"
        >
          <RefreshCw className="w-4 h-4" />
        </button>
      </div>
      <p className="text-xs text-slate-400 mb-4">
        {active.length} table{active.length === 1 ? '' : 's'} sold
        {unassigned > 0 ? `, ${unassigned} without a table number` : ''}. The door sees the table number and minimum spend on every ticket.
      </p>

      {rows === null ? (
        <p className="text-xs text-slate-400">Loading…</p>
      ) : (
        <div className="overflow-x-auto">
          <table className="w-full text-sm">
            <thead>
              <tr className="text-left text-[10px] font-black text-slate-400 uppercase tracking-widest border-b border-slate-100">
                <th className="py-2 font-black">Host</th>
                <th className="py-2 font-black">Package</th>
                <th className="py-2 font-black text-right">In</th>
                <th className="py-2 font-black">Table</th>
                <th className="py-2" />
              </tr>
            </thead>
            <tbody>
              {rows.map((t) => {
                const off = t.status === 'cancelled';
                return (
                  <tr key={t.bookingId} className={`border-b border-slate-50 last:border-b-0 ${off ? 'opacity-40' : ''}`}>
                    <td className="py-2 text-slate-700">
                      <span className="block font-bold">{t.hostName || t.hostEmail || 'Guest'}</span>
                      {t.hostName && t.hostEmail && <span className="block text-[11px] text-slate-400">{t.hostEmail}</span>}
                    </td>
                    <td className="py-2 text-slate-600 text-xs">
                      {t.tierName} · {t.partySize} people
                      {t.minSpendCents ? ` · ${formatCents(t.minSpendCents, currency)} min` : ''}
                      {t.sectionLabel ? ` · ${t.sectionLabel}` : ''}
                      {off && <span className="block text-[10px] uppercase tracking-widest">cancelled</span>}
                    </td>
                    <td className="py-2 text-right text-slate-700 text-xs">
                      {t.checkedIn}/{t.tickets}
                    </td>
                    <td className="py-2">
                      {canManage && !off ? (
                        <input
                          type="text"
                          value={drafts[t.bookingId] ?? ''}
                          maxLength={40}
                          placeholder={suggestNextLabel(active.map((o) => o.label))}
                          disabled={busy === t.bookingId}
                          onChange={(e) => setDrafts((d) => ({ ...d, [t.bookingId]: e.target.value }))}
                          onKeyDown={(e) => {
                            if (e.key === 'Enter') void save(t);
                          }}
                          className="w-28 px-2 py-1 border border-slate-200 rounded text-sm"
                          aria-label="Table number"
                        />
                      ) : (
                        <span className="text-slate-700 font-bold">{t.label || '—'}</span>
                      )}
                    </td>
                    <td className="py-2 text-right whitespace-nowrap">
                      {canManage && !off && (
                        <>
                          <button
                            type="button"
                            onClick={() => void save(t)}
                            disabled={busy === t.bookingId || (drafts[t.bookingId] ?? '') === (t.label ?? '')}
                            className="px-3 py-1 bg-slate-900 disabled:bg-slate-200 disabled:text-slate-400 text-white rounded text-[10px] font-black uppercase tracking-widest"
                          >
                            Save
                          </button>
                          <button
                            type="button"
                            onClick={() => void cancel(t)}
                            disabled={busy === t.bookingId}
                            className="ml-2 px-2 py-1 text-[10px] font-bold text-rose-500 hover:text-rose-700 uppercase tracking-widest"
                          >
                            Cancel
                          </button>
                        </>
                      )}
                    </td>
                  </tr>
                );
              })}
            </tbody>
          </table>
        </div>
      )}
    </div>
  );
}
