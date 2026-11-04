// Event report → Time slots: sold of capacity with a bar, live holds, checked
// in, gross and sales per ticket type, grouped by day (exos_event_slot_report,
// mig 20261030150000). Owners and managers change one slot's capacity or
// close it (exos_set_event_slot; never below what it sold). Renders nothing
// for an event without timed entry.

import { useCallback, useEffect, useState } from 'react';
import { CalendarClock } from 'lucide-react';
import { getSlotReport, setEventSlot } from '../lib/seriesTimedApi';
import { addDays } from '../lib/recurrence';
import { fillRatio, groupReport, type SlotReportDay } from '../lib/slots';
import { formatCurrency } from '../lib/utils';
import { useToast } from '../context/ToastContext';

export default function SlotReport({
  eventId, tiers, currency, canManage,
}: {
  eventId: string;
  tiers: { id: string; name: string }[];
  currency?: string;
  canManage: boolean;
}) {
  const { toast } = useToast();
  const today = new Date().toISOString().slice(0, 10);
  const [from, setFrom] = useState(today);
  const [to, setTo] = useState(addDays(today, 6));
  const [days, setDays] = useState<SlotReportDay[] | null>(null);
  const names = new Map(tiers.map((t) => [t.id, t.name]));

  const load = useCallback(async () => {
    try {
      setDays(groupReport(await getSlotReport(eventId, from, to)));
    } catch (err) {
      console.warn('slot report unavailable:', err);
      setDays(null);
    }
  }, [eventId, from, to]);
  useEffect(() => { void load(); }, [load]);

  if (!days) return null;
  if (days.length === 0 && from === today) return null;

  const change = async (slotId: string, c: { capacity?: number | null; closed?: boolean; reset?: boolean }) => {
    try {
      await setEventSlot(eventId, slotId, c);
      await load();
    } catch (err: any) {
      toast({ kind: 'error', message: err?.message || 'Could not change the slot.' });
    }
  };

  return (
    <div className="bg-white rounded-2xl p-6 shadow-sm mb-6">
      <div className="flex flex-wrap items-end justify-between gap-3 mb-4">
        <div className="flex items-center gap-2">
          <CalendarClock className="w-4 h-4 text-slate-500" />
          <h3 className="text-sm font-bold text-slate-700">Time slots</h3>
        </div>
        <div className="flex gap-2 text-xs">
          <label>From <input type="date" value={from} onChange={(e) => setFrom(e.target.value)} className="border border-slate-200 rounded px-1" /></label>
          <label>To <input type="date" value={to} onChange={(e) => setTo(e.target.value)} className="border border-slate-200 rounded px-1" /></label>
        </div>
      </div>
      {days.length === 0 && <p className="text-xs text-slate-400">No slots in these dates.</p>}
      {days.map((d) => (
        <div key={d.date} className="mb-4">
          <p className="text-xs font-bold text-slate-600 mb-1">
            {d.date} · {d.sold}/{d.capacity} sold · {d.checkedIn} in · {formatCurrency(d.gross, currency || 'USD')}
          </p>
          <table className="w-full text-xs">
            <tbody>
              {d.rows.map((r) => (
                <tr key={r.slotId} className="border-t border-slate-100">
                  <td className="py-1 w-14 font-mono">{r.time}</td>
                  <td className="py-1 w-40">
                    <div className="h-1.5 bg-slate-100 rounded"><div className="h-1.5 bg-[#026cdf] rounded" style={{ width: `${Math.round(fillRatio(r) * 100)}%` }} /></div>
                  </td>
                  <td className="py-1 px-2">{r.sold}/{r.capacity}{r.custom ? '*' : ''}{r.held ? ` (+${r.held} held)` : ''}{r.closed ? ' · closed' : ''}</td>
                  <td className="py-1 px-2">{r.checkedIn} in</td>
                  <td className="py-1 px-2">{formatCurrency(r.gross, currency || 'USD')}</td>
                  <td className="py-1 px-2 text-slate-400">
                    {Object.entries(r.tierSold).filter(([, n]) => Number(n) > 0).map(([k, n]) => `${names.get(k) ?? 'type'} ${n}`).join(' · ')}
                  </td>
                  {canManage && (
                    <td className="py-1 text-right whitespace-nowrap">
                      <button type="button" className="text-[#026cdf] mr-2" onClick={() => {
                        const v = window.prompt(`Places in ${r.time} (sold ${r.sold}); blank = back to the setting`, String(r.capacity));
                        if (v === null) return;
                        void change(r.slotId, v.trim() === '' ? { reset: true } : { capacity: Number(v) });
                      }}>Capacity</button>
                      <button type="button" className="text-[#026cdf]" onClick={() => void change(r.slotId, { closed: !r.closed })}>
                        {r.closed ? 'Open' : 'Close'}
                      </button>
                    </td>
                  )}
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      ))}
    </div>
  );
}
