// AttendeeLookup — find anyone on the event, whichever platform sold the
// ticket, in Eventbrite's status words (exos_attendee_lookup, mig
// 20261014120000). Owner / manager only; hidden when the database doesn't
// have the RPC yet.

import { useEffect, useState } from 'react';
import { Search } from 'lucide-react';
import { STATUS_WORDS, checkedInOnText, statusLabel, type LookupResult, type StatusWord } from '../lib/attendeeLookup';
import { lookupAttendees } from '../lib/attendeeLookupApi';

const CHIP: Record<StatusWord, string> = {
  Attending: 'bg-slate-100 text-slate-700',
  'Checked In': 'bg-emerald-50 text-emerald-700',
  'Not Attending': 'bg-rose-50 text-rose-700',
  Transferred: 'bg-sky-50 text-sky-700',
};

export default function AttendeeLookup({ eventId, canView }: { eventId: string; canView: boolean }) {
  const [query, setQuery] = useState('');
  const [status, setStatus] = useState<StatusWord | null>(null);
  const [result, setResult] = useState<LookupResult | null>(null);
  const [state, setState] = useState<'loading' | 'ready' | 'hidden' | 'error'>('loading');

  useEffect(() => {
    if (!canView) return undefined;
    let alive = true;
    // Typing: wait a moment so each key isn't a request.
    const t = setTimeout(() => {
      lookupAttendees(eventId, query, status)
        .then((r) => {
          if (!alive) return;
          setResult(r);
          setState(r ? 'ready' : 'hidden');
        })
        .catch((err) => {
          console.warn('attendee lookup failed', err);
          if (alive) setState('error');
        });
    }, query ? 300 : 0);
    return () => {
      alive = false;
      clearTimeout(t);
    };
  }, [eventId, query, status, canView]);

  if (!canView || state === 'hidden') return null;

  return (
    <div className="bg-white rounded-2xl p-6 shadow-sm mb-6">
      <h3 className="text-sm font-bold text-slate-700 mb-1">Find an attendee</h3>
      <p className="text-xs text-slate-400 mb-4">
        Exos tickets, Eventbrite attendees and every guest list, in Eventbrite's words, so a status reads the same
        whichever platform sold the ticket.
      </p>
      <label htmlFor="attendee-lookup" className="sr-only">Name, email, order or barcode</label>
      <div className="relative mb-3">
        <Search className="w-4 h-4 text-slate-400 absolute left-3 top-1/2 -translate-y-1/2" aria-hidden />
        <input
          id="attendee-lookup"
          value={query}
          onChange={(e) => setQuery(e.target.value)}
          placeholder="Name, email, order or barcode"
          className="w-full pl-9 pr-3 py-2 border border-slate-200 rounded-xl text-sm"
        />
      </div>
      <div className="flex flex-wrap gap-2 mb-4" role="group" aria-label="Filter by status">
        <button
          type="button"
          onClick={() => setStatus(null)}
          aria-pressed={status === null}
          className={`px-3 py-1 rounded-full text-[11px] font-bold ${status === null ? 'bg-slate-900 text-white' : 'bg-slate-100 text-slate-600'}`}
        >
          All
        </button>
        {STATUS_WORDS.map((w) => (
          <button
            key={w}
            type="button"
            onClick={() => setStatus(status === w ? null : w)}
            aria-pressed={status === w}
            className={`px-3 py-1 rounded-full text-[11px] font-bold ${status === w ? 'bg-slate-900 text-white' : CHIP[w]}`}
          >
            {w} {result ? `· ${result.counts[w] ?? 0}` : ''}
          </button>
        ))}
      </div>
      {state === 'error' && <p className="text-xs text-rose-500">Couldn't load attendees. Try again in a minute.</p>}
      {state === 'loading' && !result && <p className="text-xs text-slate-400">Loading…</p>}
      {result && result.rows.length === 0 && <p className="text-xs text-slate-400">Nobody matches.</p>}
      {result && result.rows.length > 0 && (
        <div className="overflow-x-auto">
          <table className="w-full text-sm">
            <thead>
              <tr className="text-left text-[10px] uppercase tracking-widest text-slate-400">
                <th className="py-2 pr-3 font-bold">Name</th>
                <th className="py-2 pr-3 font-bold">Ticket</th>
                <th className="py-2 pr-3 font-bold">Sold on</th>
                <th className="py-2 pr-3 font-bold">Status</th>
                <th className="py-2 font-bold">Detail</th>
              </tr>
            </thead>
            <tbody className="divide-y divide-slate-100">
              {result.rows.map((r, i) => (
                <tr key={`${r.channel}:${r.ref}:${i}`}>
                  <td className="py-2 pr-3">
                    <span className="block font-semibold text-slate-900">{r.name}</span>
                    {r.email && r.email !== r.name && <span className="block text-[11px] text-slate-400">{r.email}</span>}
                  </td>
                  <td className="py-2 pr-3 text-slate-600">{r.ticket ?? '—'}</td>
                  <td className="py-2 pr-3 text-slate-600">{r.source}</td>
                  <td className="py-2 pr-3">
                    <span className={`px-2 py-0.5 rounded-full text-[11px] font-bold ${r.status ? CHIP[r.status] : 'bg-slate-100 text-slate-500'}`}>
                      {statusLabel(r)}
                    </span>
                  </td>
                  <td className="py-2 text-[11px] text-slate-500">
                    {r.checkedInOn ? `In ${checkedInOnText(r.checkedInOn)}` : r.detail ?? ''}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
    </div>
  );
}
