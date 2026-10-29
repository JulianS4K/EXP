// Event report → Overview → Channels card (mig 20261029120000): where every ticket
// came from, the last full week and to date, with gross, the channel's fees,
// the Exos fee and net to the organizer. Same document as the Monday mail
// (exos_event_channel_report = that event's part of org-channel-report), read
// with the same parser, so the two agree. Owner / manager / finance; hidden
// when the database doesn't have it yet or the role can't read it.

import { useEffect, useState } from 'react';
import { Link } from 'react-router-dom';
import { Share2 } from 'lucide-react';
import { getEventChannelReport, type EventChannelReport } from '../lib/channelReportApi';
import {
  feeText, money, notReportedNote, sideCounts, totalsText, weekLabel, type EventChannels,
} from '../../supabase/functions/_shared/channelReport.ts';

/** The channel table (shared with /orgs/:id/channels). */
export function ChannelTable({ e }: { e: EventChannels }) {
  if (e.sales.length === 0) return <p className="text-sm text-slate-400">No sales yet.</p>;
  const th = 'py-2 pr-4 text-right';
  return (
    <div className="overflow-x-auto -mx-6 px-6">
      <table className="w-full text-sm">
        <thead>
          <tr className="text-left text-[10px] font-black text-slate-400 uppercase tracking-widest border-b border-slate-100">
            <th scope="col" className="py-2 pr-4">Channel</th>
            <th scope="col" className={th}>This week</th>
            <th scope="col" className={th}>To date</th>
            <th scope="col" className={th}>Gross</th>
            <th scope="col" className={th}>Channel fees</th>
            <th scope="col" className={th}>Exos fee</th>
            <th scope="col" className="py-2 text-right">Net to you</th>
          </tr>
        </thead>
        <tbody>
          {e.sales.map((r) => {
            const nr = (v: number | null) => (v === null ? 'text-slate-400 italic' : '');
            return (
              <tr key={`${r.channel}:${r.currency}`} className="border-b border-slate-50 last:border-0">
                <td className={`py-2 pr-4 ${r.channel === 'direct' ? 'text-slate-400 italic' : 'text-slate-700'} break-all`}>
                  {r.label}
                  {/* The key behind "Other" / a grouped row, [a-z0-9_-] only, as text. */}
                  {r.detail && <span className="text-slate-400"> ({r.detail})</span>}
                </td>
                <td className="py-2 pr-4 text-right tabular-nums">{r.week ? r.week.tickets : <span className="text-slate-300" title="This channel reports counts without dates">–</span>}</td>
                <td className="py-2 pr-4 text-right tabular-nums">{r.toDate.tickets}</td>
                <td className={`py-2 pr-4 text-right tabular-nums ${nr(r.toDate.grossCents)}`}>{money(r.toDate.grossCents, r.currency)}</td>
                <td className={`py-2 pr-4 text-right tabular-nums ${nr(r.toDate.feeCents)}`}>{feeText(r.toDate, r.fees, r.currency)}</td>
                <td className={`py-2 pr-4 text-right tabular-nums ${nr(r.toDate.exosFeeCents)}`}>{money(r.toDate.exosFeeCents, r.currency)}</td>
                <td className={`py-2 text-right tabular-nums ${nr(r.toDate.netCents)}`}>{money(r.toDate.netCents, r.currency)}</td>
              </tr>
            );
          })}
        </tbody>
      </table>
    </div>
  );
}

/** Totals, comps / imports and the "not reported" caveats under a table. */
export function ChannelNotes({ e }: { e: EventChannels }) {
  const side = sideCounts(e, 'toDate');
  const undated = e.sales.filter((r) => !r.dated).map((r) => r.label);
  const note = notReportedNote(e.totals.toDate);
  return (
    <div className="text-xs text-slate-500 space-y-1 mt-3">
      <p><span className="font-bold text-slate-700">This week:</span> {totalsText(e.totals.week)} · <span className="font-bold text-slate-700">To date:</span> {totalsText(e.totals.toDate)}</p>
      {(side.comps > 0 || side.attendees > 0) && (
        <p>
          Not sales (not in the totals): {[side.comps ? `${side.comps} comp${side.comps === 1 ? '' : 's'}` : '',
            side.attendees ? `${side.attendees} imported attendee${side.attendees === 1 ? '' : 's'}` : ''].filter(Boolean).join(', ')}.
        </p>
      )}
      {undated.length > 0 && <p>{undated.join(', ')}: counts only, without sale dates, so not in the week.</p>}
      {note && <p className="text-amber-700">{note}</p>}
    </div>
  );
}

export default function ChannelSalesPanel({ eventId, orgId, canView }: { eventId: string; orgId?: string | null; canView: boolean }) {
  const [data, setData] = useState<EventChannelReport | null>(null);

  useEffect(() => {
    if (!canView) return undefined;
    let cancelled = false;
    void getEventChannelReport(eventId).then((d) => {
      if (!cancelled) setData(d);
    });
    return () => {
      cancelled = true;
    };
  }, [eventId, canView]);

  if (!canView || !data) return null;
  const week = weekLabel(data.from, data.to);

  return (
    <section className="bg-white rounded-2xl p-6 shadow-sm mb-8" aria-labelledby="channels-title">
      <div className="flex flex-wrap items-start justify-between gap-3 mb-1">
        <div className="flex items-center gap-2">
          <Share2 className="w-4 h-4 text-slate-500" aria-hidden="true" />
          <h3 id="channels-title" className="text-sm font-bold text-slate-700">Channels</h3>
        </div>
        {orgId && (
          <Link to={`/orgs/${orgId}/channels`} className="text-[10px] font-black uppercase tracking-widest text-slate-500 hover:text-slate-800">
            Weekly report
          </Link>
        )}
      </div>
      <p className="text-xs text-slate-400 mb-4">
        Every ticket by where it sold: your Exos links (by tracking link, promo link, UTM tag or promoter), the box
        office, marketplaces, Eventbrite and Luma. “This week” is {week || 'the last full week'} (UTC), the same
        numbers as the Monday email. Fees are the channel’s own, as reported; where a channel doesn’t report them,
        the cell says so.
      </p>
      <ChannelTable e={data} />
      <ChannelNotes e={data} />
    </section>
  );
}
