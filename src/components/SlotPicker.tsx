// Event page: pick a date, then a time slot, for a ticket type sold by time
// slot (docs/series-timed-entry.md). A month calendar of open days with what
// is left for the chosen type, then that day's slots. Reads the published
// availability (exos_public_event_slots: live holds count as taken); the
// checkout re-checks and holds the places (exos_attach_hold_slot).

import { useEffect, useMemo, useState } from 'react';
import { ChevronLeft, ChevronRight, Loader2 } from 'lucide-react';
import { getPublicSlots, type PublicTimedEntry } from '../lib/seriesTimedApi';
import { openDates } from '../lib/timedEntry';
import { monthGrid, monthRange, shiftMonth, slotLabel, slotLeftFor, summarizeDays, type PublicSlot } from '../lib/slots';

const WEEK = ['S', 'M', 'T', 'W', 'T', 'F', 'S'];

export default function SlotPicker({
  eventId, config, tierId, quantity, value, onChange,
}: {
  eventId: string;
  config: PublicTimedEntry;
  tierId: string;
  quantity: number;
  value: string | null;
  onChange: (slotId: string | null) => void;
}) {
  const today = new Date().toISOString().slice(0, 10);
  const days = useMemo(() => openDates(config).filter((d) => d >= today), [config, today]);
  const first = days[0] ?? config.startDate;
  const [month, setMonth] = useState(() => ({ year: Number(first.slice(0, 4)), month: Number(first.slice(5, 7)) }));
  const [slots, setSlots] = useState<PublicSlot[]>([]);
  const [loading, setLoading] = useState(false);
  const [date, setDate] = useState<string | null>(value ? `${value.slice(0, 4)}-${value.slice(4, 6)}-${value.slice(6, 8)}` : null);

  useEffect(() => {
    const range = monthRange(month.year, month.month, today > config.startDate ? today : config.startDate, config.endDate);
    if (!range) { setSlots([]); return undefined; }
    let live = true;
    setLoading(true);
    getPublicSlots(eventId, range.from, range.to)
      .then((rows) => { if (live) setSlots(rows); })
      .catch((err) => { console.error('getPublicSlots failed:', err); if (live) setSlots([]); })
      .finally(() => { if (live) setLoading(false); });
    return () => { live = false; };
  }, [eventId, month, config.startDate, config.endDate, config.version, today]);

  const summary = useMemo(() => new Map(summarizeDays(slots, tierId, quantity).map((d) => [d.date, d])), [slots, tierId, quantity]);
  const daySlots = slots.filter((s) => s.date === date);
  // A picked slot that no longer fits the quantity / type is dropped.
  useEffect(() => {
    if (!value) return;
    const s = slots.find((x) => x.slotId === value);
    if (s && slotLeftFor(s, tierId) < quantity) onChange(null);
  }, [slots, value, tierId, quantity, onChange]);

  const canPrev = `${month.year}-${String(month.month).padStart(2, '0')}` > (days[0] ?? config.startDate).slice(0, 7);
  const canNext = `${month.year}-${String(month.month).padStart(2, '0')}` < config.endDate.slice(0, 7);
  const label = new Date(Date.UTC(month.year, month.month - 1, 1)).toLocaleDateString(undefined, { month: 'long', year: 'numeric', timeZone: 'UTC' });

  if (days.length === 0) {
    return <p className="type text-[11px] text-white/60 mb-6">No dates are open for this ticket type.</p>;
  }

  return (
    <div className="mb-8" aria-label="Pick a date and time">
      <p className="type text-[11px] text-white/60 uppercase tracking-widest mb-3">Pick a date</p>
      <div className="border border-white/10 p-3">
        <div className="flex items-center justify-between mb-2">
          <button type="button" aria-label="Previous month" disabled={!canPrev}
            onClick={() => setMonth((m) => shiftMonth(m.year, m.month, -1))}
            className="p-1 text-white/70 disabled:opacity-30"><ChevronLeft className="w-4 h-4" /></button>
          <span className="type text-xs text-white">{label}</span>
          <button type="button" aria-label="Next month" disabled={!canNext}
            onClick={() => setMonth((m) => shiftMonth(m.year, m.month, 1))}
            className="p-1 text-white/70 disabled:opacity-30"><ChevronRight className="w-4 h-4" /></button>
        </div>
        <div className="grid grid-cols-7 gap-1 text-center">
          {WEEK.map((w, i) => <span key={i} className="type text-[10px] text-white/40">{w}</span>)}
          {monthGrid(month.year, month.month).flat().map((d, i) => {
            if (!d) return <span key={i} />;
            const s = summary.get(d);
            const open = !!s && s.open > 0;
            return (
              <button key={d} type="button" disabled={!open} onClick={() => { setDate(d); onChange(null); }}
                aria-pressed={date === d}
                title={s ? `${s.left} left` : undefined}
                className={`py-1.5 text-xs border ${date === d ? 'border-brand-primary bg-brand-primary/10 text-white'
                  : open ? 'border-white/10 text-white hover:border-white/40' : 'border-transparent text-white/25'}`}>
                {Number(d.slice(8))}
              </button>
            );
          })}
        </div>
        {loading && <p className="type text-[11px] text-white/50 mt-2 flex items-center gap-1"><Loader2 className="w-3 h-3 animate-spin" /> Checking times…</p>}
      </div>

      {date && (
        <div className="mt-4">
          <p className="type text-[11px] text-white/60 uppercase tracking-widest mb-2">Pick a time</p>
          <div className="grid grid-cols-2 sm:grid-cols-3 gap-2">
            {daySlots.map((s) => {
              const left = slotLeftFor(s, tierId);
              const ok = left >= quantity;
              return (
                <button key={s.slotId} type="button" disabled={!ok} onClick={() => onChange(s.slotId)}
                  aria-pressed={value === s.slotId}
                  className={`p-2 text-left border ${value === s.slotId ? 'border-brand-primary bg-brand-primary/10'
                    : ok ? 'border-white/10 hover:border-white/40' : 'border-white/5 opacity-40'}`}>
                  <span className="block text-sm text-white">{slotLabel(s.time, config.slotMinutes)}</span>
                  <span className="type block text-[10px] text-white/50">
                    {s.closed ? 'Closed' : s.ended ? 'Ended' : left === 0 ? 'Full' : `${left} left`}
                  </span>
                </button>
              );
            })}
          </div>
          {config.entryWindowMinutes != null && (
            <p className="type text-[11px] text-white/50 mt-2">
              Arrive {config.earlyEntryMinutes > 0 ? `from ${config.earlyEntryMinutes} min before ` : 'from '}your time; entry closes {config.entryWindowMinutes} min after it starts.
            </p>
          )}
        </div>
      )}
    </div>
  );
}
